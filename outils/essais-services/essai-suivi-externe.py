# -*- coding: utf-8 -*-
"""Le suivi externe, Phase 1 du suivi universel (outils/supabase-suivi-externe.sql).

Même base jetable que essai-services.py (jamais la vraie base). On installe la chaîne
officielle SANS ce fichier, on y met des données (colis, événements, pré-alertes,
factures, paiement), puis on pose la migration — trois fois — et on vérifie ce que
le dossier de conception validé le 12/11/2026 promet :

  A. elle s'installe et se relance sans rien changer aux données existantes ;
  B. ses quatre tables sont fermées (client, employé, visiteur : rien en direct) ;
  C. ses lectures demandent tracking.view et ne montrent jamais de clé ;
  D. la correspondance des statuts : un statut inconnu n'est jamais « DELIVERED » ;
  E. ses contraintes : un fournisseur actif est « VERIFIED », numéros et statuts bornés ;
  F. événements et journal immuables, sans doublon ;
  G. le suivi GoShip ne bouge pas, même pour un « DELIVERED » du transporteur ;
  H. l'application mobile : pré-alertes créées et lues comme avant ;
  I. les permissions : trois copies identiques de la matrice, bons rôles.

    python3 outils/essais-services/essai-suivi-externe.py
"""
import importlib.util
import json
import os
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location('essai_services', os.path.join(ICI, 'essai-services.py'))
S = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(S)

RACINE = S.RACINE
ADMIN, MARIE, JEAN = S.ADMIN, S.MARIE, S.JEAN
EMPLOYE = 'cccccccc-0000-0000-0000-00000000000c'
GERANT = 'ffffffff-0000-0000-0000-00000000000f'
verifier, jsonq, creer, un = S.verifier, S.jsonq, S.creer, S.un

CHAINE = [l.strip() for l in open(os.path.join(RACINE, 'outils', 'migrations.txt'), encoding='utf-8')
          if l.strip() and not l.startswith('#')]
NOUVEAU = 'supabase-suivi-externe.sql'
TABLES = ('fournisseurs_suivi', 'suivis_externes', 'suivis_externes_evenements', 'suivis_externes_journal')


def chemin(f):
    return os.path.join(RACINE, 'outils', f)


def empreintes(db):
    """Chaque table publique existante : nombre de lignes et empreinte du contenu, sans la colonne ajoutée."""
    tables = un(db, "select string_agg(relname, ' ' order by relname) from pg_class c join pg_namespace n "
                    "on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r';").split()
    res = {}
    for t in tables:
        if t in TABLES:
            continue
        res[t] = un(db, "select count(*) || ':' || md5(coalesce(string_agg((to_jsonb(x) - 'suivi_externe_id')::text, '|' "
                        "order by (to_jsonb(x) - 'suivi_externe_id')::text), '')) from public.%s x;" % t)
    return res


def suivi_interne(db):
    """Le suivi GoShip : chaque colis (statut, lieu, date) et tout son historique."""
    return (un(db, "select md5(coalesce(string_agg(id || ':' || statut || ':' || lieu || ':' || maj_le, '|' order by id), '')) "
                   "from public.colis;"),
            un(db, "select md5(coalesce(string_agg(h::text, '|' order by h.id), '')) from public.colis_historique h;"))


def refus(db, compte, texte):
    """Le premier mot du refus : « permission » (droits SQL), un code métier, ou « aucune »."""
    e = db.erreur(compte, texte)
    return 'permission' if e.startswith('permission denied') else e


def definition(fichier, debut='create or replace function public.permissions_du_role(p_role text)'):
    t = open(chemin(fichier), encoding='utf-8').read()
    i = t.index(debut)
    return t[i:t.index('$$;', i) + 3]


def main():
    db = S.Base()
    db.sql(S.DOUBLURES)
    print('A. Installation par-dessus une base en service')
    # Ce fichier éprouvé à sa place dans la chaîne : la Phase 2 (supabase-moteur-suivi.sql)
    # vient après lui et a son propre banc (essai-moteur-suivi.py)
    verifier('ce fichier est dans la chaîne officielle, après supabase-suivi-courriels.sql',
             CHAINE[CHAINE.index(NOUVEAU) - 1] if NOUVEAU in CHAINE else None, 'supabase-suivi-courriels.sql')
    for f in CHAINE[:CHAINE.index(NOUVEAU)]:
        db.fichier(chemin(f))
    for uid, email, nom in ((ADMIN, 'equipe@goship.test', 'Ada Admin'), (EMPLOYE, 'employe@goship.test', 'Emma Employée'),
                            (GERANT, 'gerant@goship.test', 'Gaston Gérant'), (MARIE, 'marie@exemple.com', 'Marie-Ange Dorvil'),
                            (JEAN, 'jean@exemple.com', 'Jean Pierre')):
        db.sql("""insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
                  values ('%s', '%s', now(), '{"nom_complet":"%s","pays":"HT","ville":"Pétion-Ville",
                          "telephone":"+509 3000 0000"}'::jsonb);""" % (uid, email, nom))
    db.sql("select public.definir_admin('equipe@goship.test');")
    jsonq(db, ADMIN, "select public.changer_role('employe@goship.test', 'employe');")
    jsonq(db, ADMIN, "select public.changer_role('gerant@goship.test', 'gerant');")
    base = {'description': 'Chaussures', 'poids_lb': 4, 'service': 'aerien', 'pays_destination': 'HT',
            'destination': 'Pétion-Ville', 'expediteur': 'Amazon', 'lieu': 'Miami (Medley), FL'}
    c1 = creer(db, ADMIN, dict(base, client_id=MARIE, suivi_transporteur='1Z999AA10123456784'))
    creer(db, ADMIN, dict(base, client_id=JEAN, suivi_transporteur='TBA312345678901'))
    jsonq(db, ADMIN, "select public.executer_operation('%s', 'COLIS_EMBALLE', null, null, '{}'::jsonb, null, null, null, null);"
          % c1['colis']['id'])
    jsonq(db, ADMIN, "select public.enregistrer_paiement('%s', '{\"montant_usd\": 5, \"moyen\": \"especes\"}'::jsonb);"
          % c1['facture']['id'])
    db.comme(MARIE, "select public.creer_prealerte(null, 'Walmart', 'Mixeur', '9400111899223399887764', 45, 'aerien');")
    avant = empreintes(db)
    interne_avant = suivi_interne(db)
    for _ in range(3):
        db.fichier(chemin(NOUVEAU))
    verifier('la migration s\'installe, puis se relance deux fois sans erreur', 'oui', 'oui')
    verifier('aucune donnée existante n\'a changé (%d tables comparées)' % len(avant), empreintes(db), avant)
    verifier('le contrôle de fin de fichier : 4 | 1 | 0 | false | true',
             un(db, "select (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace "
                    "where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity and c.relname in %s) || '|' || "
                    "(select count(*) from information_schema.columns where table_schema = 'public' and "
                    "table_name = 'prealertes' and column_name = 'suivi_externe_id') || '|' || "
                    "(select count(*) from public.fournisseurs_suivi where actif) || '|' || "
                    "(has_function_privilege('anon', 'public.suivi_externe(text)', 'execute') or "
                    "has_function_privilege('anon', 'public.etat_fournisseurs_suivi()', 'execute')) || '|' || "
                    "('tracking.view' = any (public.permissions_du_role('employe')));" % (TABLES,)),
             '4|1|0|false|true')
    verifier('les fournisseurs naissent éteints : 17TRACK et AfterShip, DISABLED',
             un(db, "select string_agg(code || ':' || conformite || ':' || actif, ' ' order by code) from public.fournisseurs_suivi;"),
             '17track:DISABLED:false aftership:DISABLED:false')
    verifier('la colonne de la pré-alerte existe et reste vide',
             un(db, "select count(*) || '/' || count(suivi_externe_id) from public.prealertes;"), '1/0')
    texte_migration = open(chemin(NOUVEAU), encoding='utf-8').read()
    verifier('aucune tâche planifiée ni appel extérieur dans le fichier (cron, pg_net)',
             [m for m in ('cron.schedule', 'net.http_', 'http_post', 'http_get') if m in texte_migration], [])

    print('\nB. Tables fermées : rien en direct, pour personne')
    for t in TABLES:
        for nom, qui in (('client', MARIE), ('employé', EMPLOYE), ('visiteur', None)):
            verifier('%s : %s ne lit pas' % (t, nom), refus(db, qui, 'select count(*) from public.%s;' % t), 'permission')
    verifier('un employé n\'écrit pas non plus',
             refus(db, EMPLOYE, "insert into public.suivis_externes (numero) values ('TEST1234');"), 'permission')

    print('\nC. Les lectures : tracking.view, et jamais de clé')
    db.sql("insert into public.suivis_externes (numero, transporteur, transporteur_source, statut, statut_original) "
           "values ('  1z 999 aa1 0123456784 ', 'ups', 'numero', 'IN_TRANSIT', 'InTransit');")
    verifier('le numéro est rangé en majuscules, sans espaces',
             un(db, "select numero from public.suivis_externes;"), '1Z999AA10123456784')
    sid = un(db, "select id from public.suivis_externes;")
    db.sql("insert into public.suivis_externes_evenements (suivi_id, survenu_le, statut, statut_original, lieu, empreinte) values "
           "('%s', '2026-11-10 10:00+00', 'INFO_RECEIVED', 'InfoReceived', 'Atlanta, GA', 'empreinte-001'),"
           "('%s', '2026-11-11 09:00+00', 'IN_TRANSIT', 'InTransit', 'Miami, FL', 'empreinte-002');" % (sid, sid))
    r = jsonq(db, EMPLOYE, "select public.suivi_externe('1z999aa10123456784');")
    verifier('employé : le suivi d\'un numéro, quelle que soit sa casse', (r or {}).get('numero'), '1Z999AA10123456784')
    verifier('… ses événements, du plus récent au plus ancien', [e['lieu'] for e in r['evenements']], ['Miami, FL', 'Atlanta, GA'])
    verifier('… aucune donnée client dans la réponse',
             sorted(k for k in r if k not in ('evenements',)) == sorted(
                 ['id', 'numero', 'transporteur', 'transporteur_source', 'fournisseur', 'etat', 'statut', 'statut_original',
                  'sous_statut', 'dernier_lieu', 'dernier_evenement_le', 'livraison_estimee_le', 'code_resultat',
                  'derniere_synchro_le', 'prochaine_synchro_le', 'cree_le', 'maj_le']), True)
    verifier('numéro inconnu : rien', jsonq(db, GERANT, "select public.suivi_externe('TBA000000000000');"), None)
    verifier('numéro trop court : rien, sans erreur', jsonq(db, ADMIN, "select public.suivi_externe('AB');"), None)
    verifier('client : refusé', refus(db, MARIE, "select public.suivi_externe('1Z999AA10123456784');"), 'PERMISSION_DENIED')
    verifier('visiteur : refusé', refus(db, None, "select public.suivi_externe('1Z999AA10123456784');"), 'permission')
    f = jsonq(db, EMPLOYE, "select public.etat_fournisseurs_suivi();")
    verifier('les fournisseurs : deux, sans aucun champ de clé',
             [sorted(x.keys()) for x in f], [['actif', 'code', 'conformite', 'maj_le', 'nom', 'note', 'plafond_mensuel']] * 2)
    verifier('client : l\'état des fournisseurs refusé', refus(db, MARIE, "select public.etat_fournisseurs_suivi();"),
             'PERMISSION_DENIED')
    for fn in ("public.normaliser_numero_suivi('x')", "public.statut_suivi_normalise('17track', 'Delivered')"):
        verifier('aide fermée aux comptes : %s' % fn.split('(')[0], refus(db, EMPLOYE, 'select %s;' % fn), 'permission')

    print('\nD. La correspondance des statuts (17TRACK v2.4)')
    cas = [('NotFound', None, 'NOT_FOUND'), ('InfoReceived', None, 'INFO_RECEIVED'),
           ('InTransit', 'InTransit_PickedUp', 'IN_TRANSIT'), ('InTransit', 'InTransit_CustomsReleased', 'IN_TRANSIT'),
           ('InTransit', 'InTransit_CustomsProcessing', 'CUSTOMS'),
           ('InTransit', 'InTransit_CustomsRequiringInformation', 'CUSTOMS'), ('Expired', None, 'EXPIRED'),
           ('AvailableForPickup', None, 'AVAILABLE_FOR_PICKUP'), ('OutForDelivery', None, 'OUT_FOR_DELIVERY'),
           ('DeliveryFailure', 'DeliveryFailure_NoBody', 'FAILED_ATTEMPT'), ('Delivered', 'Delivered_Other', 'DELIVERED'),
           ('Exception', 'Exception_Returning', 'RETURNED'), ('Exception', 'Exception_Returned', 'RETURNED'),
           ('Exception', 'Exception_Lost', 'EXCEPTION'), ('Exception', None, 'EXCEPTION')]
    for st, sous, attendu in cas:
        obtenu = un(db, "select coalesce(public.statut_suivi_normalise('17track', '%s', %s), 'VIDE');"
                        % (st, "'%s'" % sous if sous else 'null'))
        verifier('%s%s → %s' % (st, ' · ' + sous if sous else '', attendu), obtenu, attendu)
    for st, sous in (('Livre', None), ('delivered', None), ('', None), (None, None), ('InTransitX', 'InTransit_PickedUp')):
        verifier('statut inconnu %r : non reconnu (jamais DELIVERED)' % (st,),
                 un(db, "select coalesce(public.statut_suivi_normalise('17track', %s, null), 'VIDE');"
                        % ("'%s'" % st if st is not None else 'null')), 'VIDE')
    verifier('un autre fournisseur, pas encore décrit : non reconnu',
             un(db, "select coalesce(public.statut_suivi_normalise('aftership', 'Delivered', null), 'VIDE');"), 'VIDE')

    print('\nE. Les contraintes')
    verifier('activer un fournisseur DISABLED : refusé',
             'violates check constraint' in db.sql("update public.fournisseurs_suivi set actif = true where code = '17track';",
                                                   echec_permis=True), True)
    verifier('… même PENDING_VERIFICATION : refusé',
             'violates check constraint' in db.sql("update public.fournisseurs_suivi set conformite = 'PENDING_VERIFICATION', "
                                                   "actif = true where code = '17track';", echec_permis=True), True)
    verifier('VERIFIED puis actif : accepté (puis remis éteint)',
             db.sql("update public.fournisseurs_suivi set conformite = 'VERIFIED', actif = true where code = '17track'; "
                    "update public.fournisseurs_suivi set actif = false, conformite = 'DISABLED' where code = '17track'; "
                    "select count(*) from public.fournisseurs_suivi where actif;").splitlines()[-1], '0')
    verifier('statut hors des 12 : refusé',
             'violates check constraint' in db.sql("update public.suivis_externes set statut = 'LIVRE';", echec_permis=True), True)
    verifier('numéro illisible : refusé',
             'violates check constraint' in db.sql("insert into public.suivis_externes (numero) values ('A B$C');",
                                                   echec_permis=True), True)
    verifier('le même numéro deux fois : refusé (un seul suivi par numéro)',
             'duplicate key' in db.sql("insert into public.suivis_externes (numero) values ('1z999aa10123456784');",
                                       echec_permis=True), True)

    print('\nF. Immuables, sans doublon')
    verifier('modifier un événement : refusé, même depuis le SQL Editor',
             refus(db, 'sql', "update public.suivis_externes_evenements set lieu = 'Ailleurs';"), 'EVENT_IMMUTABLE')
    verifier('effacer un événement : refusé',
             refus(db, 'sql', "delete from public.suivis_externes_evenements;"), 'EVENT_IMMUTABLE')
    verifier('le même événement reçu deux fois : rangé une seule fois',
             db.sql("insert into public.suivis_externes_evenements (suivi_id, survenu_le, empreinte) "
                    "values ('%s', now(), 'empreinte-002') on conflict do nothing returning id;" % sid).strip(), '')
    db.sql("insert into public.suivis_externes_journal (suivi_id, fournisseur, operation, resultat, code_http, duree_ms) "
           "values ('%s', '17track', 'gettrackinfo', 'ok', 200, 420);" % sid)
    verifier('modifier le journal des appels : refusé',
             refus(db, 'sql', "update public.suivis_externes_journal set resultat = 'erreur';"), 'EVENT_IMMUTABLE')
    verifier('effacer un suivi qui a des événements : refusé',
             'violates foreign key' in db.sql("delete from public.suivis_externes where id = '%s';" % sid, echec_permis=True),
             True)

    print('\nG. Le suivi GoShip ne bouge pas')
    db.sql("insert into public.suivis_externes (numero, statut, statut_original) values ('9400111899223399887764', 'DELIVERED', 'Delivered');")
    sid2 = un(db, "select id from public.suivis_externes where numero = '9400111899223399887764';")
    db.sql("insert into public.suivis_externes_evenements (suivi_id, survenu_le, statut, statut_original, empreinte) "
           "values ('%s', now(), 'DELIVERED', 'Delivered', 'livre-001');" % sid2)
    db.sql("update public.prealertes set suivi_externe_id = '%s' where suivi_transporteur = '9400111899223399887764';" % sid2)
    verifier('un « DELIVERED » du transporteur, relié à une pré-alerte : statuts et historique des colis intacts',
             suivi_interne(db), interne_avant)
    verifier('les nouvelles tables n\'ont que leurs propres déclencheurs (rangement, immuabilité)',
             un(db, "select string_agg(distinct tgname, ' ' order by tgname) from pg_trigger t join pg_class c on c.oid = t.tgrelid "
                    "where c.relname in %s and not t.tgisinternal;" % (TABLES,)), 'ranger_suivi_externe suivi_externe_immuable')
    texte = open(chemin(NOUVEAU), encoding='utf-8').read().lower()
    verifier('le fichier n\'écrit nulle part dans colis ni colis_historique',
             [m for m in ('update public.colis', 'insert into public.colis', 'delete from public.colis') if m in texte], [])

    print('\nH. L\'application mobile : comme avant')
    r = jsonq(db, JEAN, "select public.creer_prealerte(null, 'Target', 'Jouets', 'TBA999999999999', 20, 'aerien');")
    verifier('creer_prealerte : sa réponse a la même forme qu\'avant (la colonne nouvelle n\'y est pas)',
             'suivi_externe_id' in (r or {}), False)
    verifier('… et la pré-alerte créée a la colonne nouvelle vide',
             un(db, "select count(*) from public.prealertes where suivi_transporteur = 'TBA999999999999' "
                    "and suivi_externe_id is null;"), '1')
    db.comme(JEAN, "insert into public.prealertes (client_id, magasin, description, suivi_transporteur) "
                   "values ('%s', 'eBay', 'Montre', 'EBAY12345678');" % JEAN)
    verifier('l\'insert direct des anciennes versions marche encore',
             un(db, "select count(*) from public.prealertes where client_id = '%s';" % JEAN), '2')
    verifier('la liste de l\'application (colonnes nommées) se lit comme avant',
             db.comme(JEAN, "select count(*) from (select id, magasin, description, suivi_transporteur, valeur_usd, service, "
                            "statut, cree_le from public.prealertes order by cree_le desc) p;").splitlines()[-1], '2')
    verifier('un client ne peut pas remplir la colonne nouvelle',
             refus(db, JEAN, "update public.prealertes set suivi_externe_id = '%s';" % sid2), 'permission')
    verifier('un client ne voit que ses pré-alertes',
             db.comme(MARIE, "select count(*) from public.prealertes;").splitlines()[-1], '1')

    print('\nI. Les permissions')
    verifier('la copie de ce fichier est celle de supabase.sql', definition(NOUVEAU), definition('supabase.sql'))
    verifier('la copie de supabase-naissance.sql aussi', definition('supabase-naissance.sql'), definition('supabase.sql'))
    for role, attendu in (('admin', 'tt'), ('gerant', 'tf'), ('employe', 'tf'), ('client', 'ff')):
        verifier('%s : tracking.view / tracking.manage' % role,
                 un(db, "select ('tracking.view' = any (public.permissions_du_role('%s')))::text || "
                        "('tracking.manage' = any (public.permissions_du_role('%s')))::text;" % (role, role))
                 .replace('true', 't').replace('false', 'f'), attendu)
    verifier('mes_permissions d\'un employé contient tracking.view',
             'tracking.view' in (jsonq(db, EMPLOYE, "select public.mes_permissions();") or {}).get('permissions', []), True)

    n = sum(S.RESULTATS)
    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), n))
    sys.exit(0 if n == len(S.RESULTATS) else 1)


if __name__ == '__main__':
    main()
