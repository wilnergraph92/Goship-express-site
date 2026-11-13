# -*- coding: utf-8 -*-
"""La supervision du suivi externe, Phase 6 du suivi universel (outils/supabase-supervision-suivi.sql).

Même base jetable et même fausse pg_net que essai-moteur-suivi.py : 17TRACK n'est jamais appelé.
On installe la chaîne SANS ce fichier, des clientes annoncent leurs achats, le moteur les suit, on
pose la migration trois fois, puis :

  A. installation par-dessus une base en service, sans changer une donnée ;
  B. les droits, rôle par rôle : administrateur, gérant, employé lisent ; cliente et visiteur, rien ;
     seul l'administrateur pilote le moteur ;
  C. « à surveiller » : livré depuis plus de 3 jours sans réception, colis reçu chez un autre client,
     incident, numéro refusé, 30 jours sans nouvelles — et rien de plus ;
  D. la liste : filtres, recherche, pages de 50, chaque nombre égal à un comptage SQL direct ;
  E. la fiche d'un suivi : chronologie, journal des appels, achats, colis ; jamais une requête ;
  F. piloter : motif obligatoire, arrêter, reprendre, plafond ; journalisé ; refusé hors administrateur ;
  G. lire n'écrit rien ; aucun statut de colis, aucun historique ne bouge.

    python3 outils/essais-services/essai-supervision-suivi.py
"""
import importlib.util
import json
import os
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location('essai_synchro', os.path.join(ICI, 'essai-synchro-suivi.py'))
Y = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(Y)
M, S = Y.M, Y.S

ADMIN, MARIE, JEAN, EMPLOYE, GERANT = M.ADMIN, M.MARIE, M.JEAN, M.EMPLOYE, M.GERANT
verifier, jsonq, creer, un, q = S.verifier, S.jsonq, S.creer, S.un, M.q
CHAINE = M.CHAINE
NOUVEAU = 'supabase-supervision-suivi.sql'
travailler, repondre, requete_de = M.travailler, M.repondre, M.requete_de
accepte, tourner, prealerte = M.accepte, Y.tourner, Y.prealerte
BASE_COLIS = {'description': 'Robe', 'poids_lb': 2, 'service': 'aerien', 'pays_destination': 'HT',
              'destination': 'Pétion-Ville', 'expediteur': 'Shein', 'lieu': 'Miami (Medley), FL'}


def supervision(db, compte, filtres=None, page=1):
    return jsonq(db, compte, "select public.supervision_suivi(%s::jsonb, %d);" % (q(json.dumps(filtres or {})), page))


def ident(db, numero):
    return un(db, "select id from suivis_externes where numero = %s;" % q(numero))


def code_de(db, client):
    return un(db, "select code from clients where id = '%s';" % client)


def main():
    db = S.Base()
    db.sql(S.DOUBLURES)

    print('A. Installation par-dessus une base en service')
    verifier('ce fichier est dans la chaîne officielle, après supabase-alertes-suivi.sql',
             CHAINE[CHAINE.index(NOUVEAU) - 1] if NOUVEAU in CHAINE else None, 'supabase-alertes-suivi.sql')
    for f in CHAINE[:CHAINE.index(NOUVEAU)]:
        db.fichier(M.chemin(f))
    for uid, email, nom in ((ADMIN, 'equipe@goship.test', 'Ada Admin'), (EMPLOYE, 'employe@goship.test', 'Emma Employée'),
                            (GERANT, 'gerant@goship.test', 'Gaston Gérant'), (MARIE, 'marie@exemple.com', 'Marie-Ange Dorvil'),
                            (JEAN, 'jean@exemple.com', 'Jean Pierre')):
        db.sql("""insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
                  values ('%s', '%s', now(), '{"nom_complet":"%s","pays":"HT","ville":"Pétion-Ville",
                          "telephone":"+509 3000 0000","langue":"fr"}'::jsonb);""" % (uid, email, nom))
    db.sql("select public.definir_admin('equipe@goship.test');")
    jsonq(db, ADMIN, "select public.changer_role('employe@goship.test', 'employe');")
    jsonq(db, ADMIN, "select public.changer_role('gerant@goship.test', 'gerant');")
    db.sql("select public.definir_reglage('suivi_17track_cle', 'cle-essai-17track');")
    jsonq(db, ADMIN, "select public.regler_fournisseur_suivi('17track', '{\"conformite\": \"PENDING_VERIFICATION\", "
                     "\"essai\": true, \"plafond_essai\": 30, \"marge_quota\": 20, \"suivre_prealertes\": true, "
                     "\"plafond_mensuel\": 30}');")
    achats = (('GFUS01000000000301', MARIE, 'Shein'), ('GFUS01000000000301', JEAN, 'Ebay'),
              ('GFUS01000000000302', MARIE, 'Temu'), ('SWX000000000000303', MARIE, 'Nike'),
              ('GFUS01000000000304', JEAN, 'Zara'), ('SWX000000000000305', JEAN, 'Adidas'),
              ('GFUS01000000000306', MARIE, 'Apple'), ('GFUS01000000000307', MARIE, 'H&M'))
    for numero, client, magasin in achats:
        prealerte(db, client, numero, magasin)
    tourner(db)
    numeros = sorted({a[0] for a in achats})
    repondre(db, requete_de(db, numeros[0]), 200, {'code': 0, 'data': {
        'accepted': [accepte(n, 100996 if n.startswith('GF') else 101228, 3) for n in numeros if n != 'GFUS01000000000304'],
        'rejected': [M.rejete('GFUS01000000000304', -18010012, 'Invalid number.')]}})
    travailler(db)
    verifier('avant la migration : 7 suivis ouverts par les pré-alertes, dont un numéro refusé',
             un(db, "select count(*) || ':' || count(*) filter (where code_resultat = 'INVALID_TRACKING') "
                    "|| ':' || count(*) filter (where origine = 'prealerte') from suivis_externes;"), '7:1:7')
    # Les états que le moteur aurait rangés : livré il y a 4 jours, livré hier, incident, 31 jours de silence
    db.sql("""update suivis_externes set statut = 'DELIVERED', livre_vu_le = now() - interval '4 days',
                     dernier_evenement_le = now() - interval '4 days', dernier_lieu = 'Doral, FL, US'
               where numero in ('GFUS01000000000301', 'GFUS01000000000307');
              update suivis_externes set statut = 'DELIVERED', livre_vu_le = now() - interval '1 day',
                     dernier_evenement_le = now() - interval '1 day' where numero = 'GFUS01000000000302';
              update suivis_externes set statut = 'EXCEPTION', dernier_evenement_le = now() - interval '2 days'
               where numero = 'SWX000000000000303';
              update suivis_externes set statut = 'IN_TRANSIT', dernier_evenement_le = now() - interval '31 days'
               where numero = 'SWX000000000000305';
              update suivis_externes set statut = 'IN_TRANSIT', dernier_evenement_le = now() - interval '2 days'
               where numero = 'GFUS01000000000306';""")
    id301 = ident(db, 'GFUS01000000000301')
    for i, (quand, statut, desc) in enumerate((("now() - interval '6 days'", 'IN_TRANSIT', 'Departed'),
                                                ("now() - interval '4 days'", 'DELIVERED', 'Delivered, front door'))):
        db.sql("insert into suivis_externes_evenements (suivi_id, survenu_le, statut, description, lieu, empreinte) "
               "values ('%s', %s, '%s', '%s', 'Doral, FL, US', 'empreinte-essai-%d');" % (id301, quand, statut, desc, i))
    # Un appel au fournisseur pour ce seul numéro (une relecture) : le moteur le rattache au suivi
    db.sql("insert into suivis_externes_journal (suivi_id, fournisseur, operation, resultat, code_http, duree_ms) "
           "values ('%s', '17track', 'lecture', 'ok', 200, 412);" % id301)
    # Le colis de H&M arrive chez Marie (rapprochement existant) ; celui d'Apple arrive… chez Jean
    creer(db, ADMIN, dict(BASE_COLIS, client_id=MARIE, suivi_transporteur='GFUS01000000000307'))
    creer(db, ADMIN, dict(BASE_COLIS, client_id=JEAN, suivi_transporteur='GFUS01000000000306'))
    # De quoi remplir deux pages : 55 suivis ouverts par l'équipe, sans achat
    db.sql("insert into suivis_externes (numero, etat, origine, cree_le) select 'LOT' || lpad(g::text, 9, '0'), "
           "'en_attente', 'equipe', now() - make_interval(hours => g) from generate_series(1, 55) g;")
    HIST = "select md5(coalesce(string_agg(h::text, '|' order by h.id), '')) from colis_historique h;"
    COLIS = "select md5(string_agg(id || statut, ',' order by id)) from colis;"
    hist_avant, colis_avant = un(db, HIST), un(db, COLIS)
    avant = M.empreintes(db)
    for _ in range(3):
        db.fichier(M.chemin(NOUVEAU))
    verifier('la migration s\'installe, puis se relance deux fois sans erreur', 'oui', 'oui')
    verifier('aucune donnée existante n\'a changé (%d tables)' % len(avant), M.empreintes(db), avant)
    verifier('le contrôle de fin de fichier : 3 | 1 | false',
             un(db, "select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace "
                    "where n.nspname = 'public' and p.proname in ('supervision_suivi', 'fiche_suivi_externe', "
                    "'piloter_suivi_externe')) || '|' || (select count(*) from pg_indexes where schemaname = 'public' "
                    "and indexname = 'prealertes_suivi_externe_idx') || '|' || "
                    "has_function_privilege('anon', 'public.supervision_suivi(jsonb, integer)', 'execute');"),
             '3|1|false')

    print('\nB. Les droits, rôle par rôle')
    for nom, compte in (('administrateur', ADMIN), ('gérant', GERANT), ('employé', EMPLOYE)):
        r = supervision(db, compte)
        verifier('%s : lit la supervision (noms des clients compris)' % nom,
                 [isinstance(r, dict), r.get('noms'), r.get('peut_piloter')], [True, True, compte == ADMIN])
        verifier('%s : ouvre la fiche d\'un suivi' % nom,
                 (jsonq(db, compte, "select public.fiche_suivi_externe('%s');" % id301) or {}).get('suivi', {}).get('numero'),
                 'GFUS01000000000301')
    verifier('cliente : la supervision lui est refusée',
             db.erreur(MARIE, "select public.supervision_suivi();"), 'PERMISSION_DENIED')
    verifier('cliente : la fiche lui est refusée',
             db.erreur(MARIE, "select public.fiche_suivi_externe('%s');" % id301), 'PERMISSION_DENIED')
    verifier('visiteur : aucune des trois fonctions ne lui est ouverte',
             all('permission denied' in db.erreur(None, t) for t in (
                 "select public.supervision_suivi();", "select public.fiche_suivi_externe('%s');" % id301,
                 "select public.piloter_suivi_externe('17track', 'arreter', 'essai visiteur');")), True)
    for nom, compte in (('gérant', GERANT), ('employé', EMPLOYE), ('cliente', MARIE)):
        verifier('%s : ne pilote pas le moteur' % nom,
                 db.erreur(compte, "select public.piloter_suivi_externe('17track', 'arreter', 'je veux arrêter');"),
                 'PERMISSION_DENIED')

    print('\nC. À surveiller')
    r = supervision(db, EMPLOYE)
    cas = r['a_surveiller']['cas']
    vus = [(c['raison'], c['achat']['numero_suivi'], c['achat']['magasin']) for c in cas]
    verifier('les cas, dans l\'ordre : livré non reçu (2), autre client, incident, refusé, silence', vus, [
        ('LIVRE_NON_RECU', 'GFUS01000000000301', 'Shein'), ('LIVRE_NON_RECU', 'GFUS01000000000301', 'Ebay'),
        ('AUTRE_CLIENT', 'GFUS01000000000306', 'Apple'), ('INCIDENT', 'SWX000000000000303', 'Nike'),
        ('NUMERO_REFUSE', 'GFUS01000000000304', 'Zara'), ('SILENCE', 'SWX000000000000305', 'Adidas')])
    verifier('les compteurs disent la même chose',
             r['a_surveiller']['compteurs'], {'total': 6, 'LIVRE_NON_RECU': 2, 'AUTRE_CLIENT': 1, 'INCIDENT': 1,
                                              'NUMERO_REFUSE': 1, 'SILENCE': 1})
    verifier('livré hier (moins de 3 jours) : pas encore à surveiller ; reçu chez Marie : plus rien à surveiller',
             [n for _r, n, _m in vus if n in ('GFUS01000000000302', 'GFUS01000000000307')], [])
    autre = [c for c in cas if c['raison'] == 'AUTRE_CLIENT'][0]
    verifier('autre client : l\'achat de Marie et le colis reçu chez Jean, chacun avec son client',
             [autre['achat']['client']['code'], autre['colis']['client']['code'], bool(autre['colis']['numero'])],
             [code_de(db, MARIE), code_de(db, JEAN), True])
    verifier('… et la pré-alerte de Marie attend toujours : rien n\'est rapproché tout seul',
             un(db, "select statut from prealertes where suivi_transporteur = 'GFUS01000000000306';"), 'attente')
    livre = cas[0]
    verifier('livré non reçu : le transporteur, son nom, le dernier lieu, la date',
             [livre['suivi']['transporteur'], livre['suivi']['transporteur_nom'], livre['suivi']['statut'],
              livre['suivi']['dernier_lieu'], bool(livre['depuis'])], ['gofo', 'GOFO', 'DELIVERED', 'Doral, FL, US', True])
    verifier('les seuils sont dits : 3 jours, 30 jours', r['seuils'], {'livre_jours': 3, 'silence_jours': 30})
    verifier('la santé vient des fonctions existantes, telles quelles',
             [r['sante'] == jsonq(db, EMPLOYE, 'select public.sante_suivi_externe();'),
              r['alertes'] == jsonq(db, EMPLOYE, 'select public.etat_alertes_suivi();'),
              r['fournisseurs'] == jsonq(db, EMPLOYE, 'select public.etat_fournisseurs_suivi();')], [True, True, True])

    print('\nD. La liste des suivis')
    verifier('62 suivis, 2 pages, 50 sur la première, 12 sur la seconde',
             [r['total'], r['pages'], len(r['suivis']), len(supervision(db, EMPLOYE, page=2)['suivis'])], [62, 2, 50, 12])
    deux = r['suivis'] + supervision(db, EMPLOYE, page=2)['suivis']
    verifier('aucun suivi en double ni oublié d\'une page à l\'autre', len({s['id'] for s in deux}), 62)
    verifier('les plus récents d\'abord', [s['cree_le'] for s in deux] == sorted([s['cree_le'] for s in deux], reverse=True), True)
    for titre, filtres, sql in (
            ('statut DELIVERED', {'statut': 'DELIVERED'}, "statut = 'DELIVERED'"),
            ('pas encore de statut (AUCUN)', {'statut': 'AUCUN'}, 'statut is null'),
            ('état en attente', {'etat': 'en_attente'}, "etat = 'en_attente'"),
            ('transporteur SwiftX', {'transporteur': 'swiftx'}, "transporteur = 'swiftx'"),
            ('suivis terminés', {'suivi': 'termine'}, 'fin_motif is not null')):
        verifier('filtre %s : comme un comptage SQL direct' % titre,
                 supervision(db, EMPLOYE, filtres)['total'], int(un(db, 'select count(*) from suivis_externes where %s;' % sql)))
    verifier('une valeur de filtre inconnue est ignorée', supervision(db, EMPLOYE, {'statut': 'LIVRE', 'etat': 'x'})['total'], 62)
    verifier('recherche d\'un numéro tapé avec des espaces',
             [s['numero'] for s in supervision(db, EMPLOYE, {'recherche': 'gfus 0100 0000 0003 01'})['suivis']],
             ['GFUS01000000000301'])
    verifier('recherche d\'un magasin', [s['numero'] for s in supervision(db, EMPLOYE, {'recherche': 'nike'})['suivis']],
             ['SWX000000000000303'])
    verifier('recherche du code d\'un client : ses suivis seulement',
             sorted(s['numero'] for s in supervision(db, EMPLOYE, {'recherche': code_de(db, JEAN)})['suivis']),
             ['GFUS01000000000301', 'GFUS01000000000304', 'SWX000000000000305'])
    ligne = [s for s in deux if s['numero'] == 'GFUS01000000000301'][0]
    verifier('une ligne : achats, clients, événements, transporteur',
             [ligne['achats'], sorted(ligne['clients']), ligne['evenements'], ligne['transporteur_nom']],
             [2, sorted([code_de(db, MARIE), code_de(db, JEAN)]), 2, 'GOFO'])
    verifier('le colis arrivé est nommé sur la ligne de son suivi',
             bool([s for s in deux if s['numero'] == 'GFUS01000000000307'][0]['colis']), True)

    print('\nE. La fiche d\'un suivi')
    f = jsonq(db, EMPLOYE, "select public.fiche_suivi_externe('%s');" % id301)
    verifier('la chronologie, du plus récent au plus ancien',
             [e['statut'] for e in f['evenements']], ['DELIVERED', 'IN_TRANSIT'])
    verifier('le journal des appels faits pour ce seul numéro (un appel groupé n\'est à aucun suivi)',
             [[(j['operation'], j['resultat'], j['code_http']) for j in f['journal']], sorted(f['journal'][0].keys())],
             [[('lecture', 'ok', 200)], ['code_erreur', 'code_http', 'cree_le', 'duree_ms', 'operation', 'resultat']])
    verifier('les deux achats qui portent ce numéro, avec leur client',
             sorted((a['magasin'], a['client']['code']) for a in f['achats']),
             sorted([('Shein', code_de(db, MARIE)), ('Ebay', code_de(db, JEAN))]))
    verifier('jamais la requête, la clé ni l\'identifiant d\'un appel',
             [k for k in ('requete', 'cle', 'quota_requete', 'demande_par') if k in json.dumps(f)], [])
    verifier('un suivi inconnu : rien', jsonq(db, EMPLOYE, "select public.fiche_suivi_externe("
                                                          "'00000000-0000-4000-8000-000000000000');"), None)

    print('\nF. Piloter le moteur (administrateur)')
    etat = "select actif || '|' || essai || '|' || coalesce(plafond_mensuel::text, '-') from fournisseurs_suivi where code = '17track';"
    verifier('sans motif : refusé', db.erreur(ADMIN, "select public.piloter_suivi_externe('17track', 'arreter', 'non');"),
             'REASON_REQUIRED')
    verifier('action inconnue : refusée',
             db.erreur(ADMIN, "select public.piloter_suivi_externe('17track', 'supprimer', 'motif valable');"), 'INVALID_ACTION')
    jsonq(db, ADMIN, "select public.piloter_suivi_externe('17track', 'arreter', 'Essai : quota à surveiller');")
    verifier('arrêter : ni actif ni en essai', un(db, etat), 'false|false|30')
    verifier('… journalisé avec son motif',
             un(db, "select action || ':' || motif from journal_audit where action = 'fournisseur_suivi.reglage' "
                    "order by id desc limit 1;"), 'fournisseur_suivi.reglage:Essai : quota à surveiller')
    verifier('arrêter deux fois : refusé',
             db.erreur(ADMIN, "select public.piloter_suivi_externe('17track', 'arreter', 'encore une fois');"), 'PROVIDER_STOPPED')
    jsonq(db, ADMIN, "select public.piloter_suivi_externe('17track', 'reprendre', 'Reprise après vérification');")
    verifier('reprendre un fournisseur en cours de vérification : en essai, jamais actif', un(db, etat), 'false|true|30')
    jsonq(db, ADMIN, "select public.piloter_suivi_externe('17track', 'plafond', 'Plus de pré-alertes ce mois', 45);")
    verifier('plafond mensuel : 45', un(db, etat), 'false|true|45')
    verifier('plafond 0 : refusé',
             db.erreur(ADMIN, "select public.piloter_suivi_externe('17track', 'plafond', 'plafond nul', 0);"), 'INVALID_CAP')
    db.sql("update fournisseurs_suivi set conformite = 'VERIFIED', actif = true, essai = false where code = '17track';")
    jsonq(db, ADMIN, "select public.piloter_suivi_externe('17track', 'arreter', 'Arrêt pour maintenance');")
    jsonq(db, ADMIN, "select public.piloter_suivi_externe('17track', 'reprendre', 'Fin de la maintenance');")
    verifier('reprendre un fournisseur VERIFIED : actif', un(db, etat), 'true|false|45')
    verifier('fournisseur inconnu : refusé',
             db.erreur(ADMIN, "select public.piloter_suivi_externe('inconnu', 'arreter', 'motif valable');"), 'PROVIDER_UNKNOWN')

    print('\nG. Lire n\'écrit rien ; les colis n\'ont pas bougé')
    avant = M.empreintes(db)
    for compte in (ADMIN, GERANT, EMPLOYE):
        supervision(db, compte, {'recherche': 'shein'})
        jsonq(db, compte, "select public.fiche_suivi_externe('%s');" % id301)
    verifier('aucune table n\'a changé après les lectures des trois rôles', M.empreintes(db), avant)
    verifier('l\'historique des colis n\'a pas bougé depuis l\'installation', un(db, HIST), hist_avant)
    verifier('les statuts des colis non plus', un(db, COLIS), colis_avant)

    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), sum(S.RESULTATS)))
    sys.exit(0 if all(S.RESULTATS) else 1)


if __name__ == '__main__':
    main()
