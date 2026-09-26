# -*- coding: utf-8 -*-
"""Éprouve les rôles, les permissions et l'isolation des clients (Phase 6).

Même base jetable et mêmes rôles SQL que essai-services.py. On installe
d'abord la base TELLE QU'ELLE EST PUBLIÉE (fichiers lus dans Git), on y crée
des comptes et des données, puis la nouvelle version par-dessus : personne
ne doit changer de rôle, aucune donnée ne doit bouger. Ensuite, chaque rôle —
administrateur, gérant, employé, client, visiteur — tente chaque action, par
les fonctions ET directement dans les tables, comme le ferait quelqu'un qui
contourne les pages. On attend un refus net partout où le rôle n'a pas la
permission.

Depuis la racine du site :

    python3 outils/essais-services/essai-permissions.py
"""
import importlib.util
import json
import os
import subprocess
import sys
import threading
import time

ICI = os.path.dirname(os.path.abspath(__file__))
# Pas de dossier __pycache__ à côté des essais : il partirait en ligne avec le site.
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location('essai_services', os.path.join(ICI, 'essai-services.py'))
S = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(S)

RACINE, TRAVAIL = S.RACINE, S.TRAVAIL
ADMIN, ADMIN2, MARIE, JEAN = S.ADMIN, S.ADMIN2, S.MARIE, S.JEAN
GERANT = 'bbbbbbbb-0000-0000-0000-00000000000b'
EMPLOYE = 'cccccccc-0000-0000-0000-00000000000c'
PIRATE = 'dddddddd-0000-0000-0000-00000000000d'
verifier, jsonq, colis, creer, statut, un = S.verifier, S.jsonq, S.colis, S.creer, S.statut, S.un

# La version publiée avant la Phase 6
AVANT = os.environ.get('GOSHIP_AVANT', 'e2d2106')
FICHIERS = ('supabase.sql', 'supabase-facturation.sql', 'supabase-services.sql', 'supabase-evenements.sql',
            'supabase-scanner.sql', 'supabase-finances.sql')
NOUVEAUX = [os.path.join(RACINE, 'outils', f) for f in FICHIERS]
REFUS = 'PERMISSION_DENIED'


def fichier_git(nom):
    texte = subprocess.run(['git', '-C', RACINE, 'show', '%s:outils/%s' % (AVANT, nom)],
                           capture_output=True, text=True, check=True).stdout
    chemin = os.path.join(TRAVAIL, 'avant-' + nom)
    open(chemin, 'w', encoding='utf-8').write(texte)
    return chemin


def q(v):
    return 'null' if v is None else "'%s'" % str(v).replace("'", "''")


def js(d):
    return "'%s'::jsonb" % json.dumps(d).replace("'", "''")


def code(db, compte, texte):
    """Le code du refus (PERMISSION_DENIED, « permission denied… »), ou « aucune »."""
    return S.Base.erreur(db, compte, texte)


def lignes(db, compte, texte):
    """Combien de lignes une modification a réellement touchées (0 = la règle a filtré)."""
    sortie = db.comme(compte, texte, echec_permis=True)
    for l in sortie.splitlines():
        if l.startswith('ERROR:'):
            return l.split(':', 1)[1].strip()
    return sortie.splitlines()[-1].strip() if sortie.strip() else ''


def compter(db, compte, table, condition='true'):
    sortie = db.comme(compte, 'select count(*) from %s where %s;' % (table, condition), echec_permis=True)
    for l in sortie.splitlines():
        if l.startswith('ERROR:'):
            return l.split(':', 1)[1].strip()[:40]
    return sortie.splitlines()[-1].strip()


def main():
    db = S.Base()
    db.sql(S.DOUBLURES)
    base = {'client_id': MARIE, 'description': 'Chaussures', 'poids_lb': 4, 'service': 'aerien',
            'pays_destination': 'HT', 'destination': 'Pétion-Ville'}

    print('A. Migration depuis la version publiée (%s)' % AVANT)
    for nom in FICHIERS:
        db.fichier(fichier_git(nom))
    comptes = ((ADMIN, 'equipe@goship.test', 'Ada Admin'), (ADMIN2, 'equipe2@goship.test', 'Alix Admin'),
               (GERANT, 'gerant@goship.test', 'Gaël Gérant'), (EMPLOYE, 'employe@goship.test', 'Emma Employée'),
               (MARIE, 'marie@exemple.com', 'Marie-Ange Dorvil'), (JEAN, 'jean@exemple.com', 'Jean Pierre'))
    for uid, email, nom in comptes:
        db.sql("""insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
                  values ('%s', '%s', now(), '{"nom_complet":"%s","pays":"HT"}'::jsonb);""" % (uid, email, nom))
    db.sql("select public.definir_admin('equipe@goship.test'); select public.definir_admin('equipe2@goship.test');")
    cm = creer(db, ADMIN, dict(base, description='Colis de Marie', suivi_transporteur='MARIE-1'))
    cj = creer(db, ADMIN, dict(base, client_id=JEAN, description='Colis de Jean', suivi_transporteur='JEAN-1'))
    jsonq(db, ADMIN, "select public.enregistrer_paiement('%s', %s);"
          % (cj['facture']['id'], js({'montant_usd': 5, 'moyen': 'especes'})))
    db.sql("insert into public.prealertes (client_id, magasin, description, suivi_transporteur) "
           "values ('%s', 'Amazon', 'Livre', 'PRE-JEAN');" % JEAN)
    photo = ("select (select string_agg(id || ':' || role || ':' || coalesce(code, '-'), '|' order by id) from clients) || '#' ||"
             " (select string_agg(numero || ':' || statut || ':' || prix_usd, '|' order by numero) from colis) || '#' ||"
             " (select string_agg(numero || ':' || montant_usd || ':' || montant_paye_usd || ':' || statut, '|' order by numero)"
             "  from factures) || '#' || (select string_agg(montant_usd::text, '|' order by id) from paiements);")
    avant = un(db, photo)
    for f in NOUVEAUX + NOUVEAUX[::-1] + NOUVEAUX:
        db.fichier(f)
    verifier('les six fichiers s\'installent par-dessus, trois fois, dans le désordre', 'oui', 'oui')
    verifier('personne n\'a changé de rôle, aucune donnée n\'a bougé', un(db, photo), avant)
    verifier('les administrateurs d\'avant gardent tout', db.comme(ADMIN, "select public.peut('roles.manage');"), 't')
    verifier('plus aucune règle de sécurité ne dépend de « est_admin »',
             un(db, "select count(*) from pg_policies where coalesce(qual, '') ~ 'est_admin' "
                    "or coalesce(with_check, '') ~ 'est_admin';"), '0')
    verifier('les rôles possibles : client, employe, gerant, admin',
             un(db, "select pg_get_constraintdef(oid) ~ 'employe' and pg_get_constraintdef(oid) ~ 'gerant' "
                    "from pg_constraint where conname = 'clients_role_check';"), 't')

    print('\nB. Donner un rôle (onglet Équipe) — et l\'audit')
    r = jsonq(db, ADMIN, "select public.changer_role('gerant@goship.test', 'gerant');")
    verifier('l\'administrateur nomme un gérant', (r['ancien_role'], r['nouveau_role'], r['deja']), ('client', 'gerant', False))
    jsonq(db, ADMIN, "select public.changer_role('%s', 'employe');" % EMPLOYE)
    verifier('… et une employée (par identifiant)', un(db, "select role from clients where id = '%s';" % EMPLOYE), 'employe')
    verifier('même rôle redonné : rien de plus', jsonq(db, ADMIN, "select public.changer_role('employe@goship.test', 'employe');")['deja'],
             True)
    verifier('journal : qui, sur quel compte, ancien et nouveau rôle',
             un(db, "select auteur_id || ' ' || entite_id || ' ' || (avant ->> 'role') || '→' || (apres ->> 'role') "
                    "from journal_audit where action = 'utilisateur.role' and entite_id = '%s';" % GERANT),
             '%s %s client→gerant' % (ADMIN, GERANT))
    verifier('rôle inconnu : refusé', code(db, ADMIN, "select public.changer_role('%s', 'superadmin');" % MARIE), 'INVALID_ROLE')
    verifier('compte inconnu : refusé', code(db, ADMIN, "select public.changer_role('personne@x.test', 'employe');"),
             'USER_NOT_FOUND')
    verifier('l\'administrateur ne change pas son propre rôle',
             code(db, ADMIN, "select public.changer_role('%s', 'client');" % ADMIN), 'SELF_ROLE_CHANGE')
    for qui, nom in ((GERANT, 'le gérant'), (EMPLOYE, 'l\'employée'), (MARIE, 'un client')):
        verifier(nom + ' ne donne aucun rôle',
                 code(db, qui, "select public.changer_role('%s', 'admin');" % JEAN), REFUS)
    verifier('le gérant ne se donne pas le rôle admin',
             code(db, GERANT, "select public.changer_role('%s', 'admin');" % GERANT), REFUS)
    verifier('l\'équipe : visible du gérant et de l\'administrateur',
             (len(jsonq(db, GERANT, "select public.equipe();")), len(jsonq(db, ADMIN, "select public.equipe();"))), (4, 4))
    verifier('… pas de l\'employée ni d\'un client',
             (code(db, EMPLOYE, "select public.equipe();"), code(db, MARIE, "select public.equipe();")), (REFUS, REFUS))

    print('\nC. Élévation de privilèges : toutes refusées')
    for qui, nom in ((EMPLOYE, 'employée'), (MARIE, 'client'), (GERANT, 'gérant')):
        verifier('%s → « update clients set role = admin » sur son compte' % nom,
                 'permission denied' in code(db, qui, "update clients set role = 'admin' where id = '%s';" % qui), True)
    verifier('client → changer son identifiant',
             'permission denied' in code(db, MARIE, "update clients set id = '%s' where id = '%s';" % (PIRATE, MARIE)), True)
    verifier('client → changer son code client',
             'permission denied' in code(db, MARIE, "update clients set code = 'GSE-0001' where id = '%s';" % MARIE), True)
    verifier('client → modifier le profil d\'un autre : aucune ligne',
             lignes(db, MARIE, "with m as (update clients set nom_complet = 'x' where id = '%s' returning 1) "
                               "select count(*) from m;" % JEAN), '0')
    verifier('employée → modifier la fiche d\'un client : aucune ligne (clients.edit)',
             lignes(db, EMPLOYE, "with m as (update clients set nom_complet = 'x' where id = '%s' returning 1) "
                                 "select count(*) from m;" % JEAN), '0')
    verifier('gérant → modifier la fiche d\'un client : permis',
             lignes(db, GERANT, "with m as (update clients set ville = 'Jacmel' where id = '%s' returning 1) "
                                "select count(*) from m;" % JEAN), '1')
    verifier('gérant → modifier la fiche d\'un collègue : aucune ligne',
             lignes(db, GERANT, "with m as (update clients set nom_complet = 'x' where id = '%s' returning 1) "
                                "select count(*) from m;" % EMPLOYE), '0')
    # Seconde barrière : même si un droit sur la colonne « role » était rouvert par erreur
    db.sql("grant update (role) on public.clients to authenticated;")
    verifier('droit rouvert par erreur : le déclencheur refuse quand même',
             code(db, EMPLOYE, "update clients set role = 'admin' where id = '%s';" % EMPLOYE), REFUS)
    db.sql("revoke update (role) on public.clients from authenticated;")
    db.sql("""insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
              values ('%s', 'pirate@x.test', now(), '{"nom_complet":"P","role":"admin"}'::jsonb);""" % PIRATE)
    verifier('inscription avec « role: admin » dans ses données : reste client',
             un(db, "select role from clients where id = '%s';" % PIRATE), 'client')
    verifier('personne de connecté : aucune permission',
             db.comme(None, "select public.peut('shipments.view');", echec_permis=True).splitlines()[-1][:40] != 't', True)
    sorties = {}

    def lancer(nom, compte, texte, pause=0):
        time.sleep(pause)
        sorties[nom] = db.comme(compte, texte, echec_permis=True)

    t1 = threading.Thread(target=lancer, args=('A', ADMIN, "begin; select public.changer_role('%s', 'client'); "
                                                         "select pg_sleep(1); commit;" % ADMIN2))
    t2 = threading.Thread(target=lancer, args=('B', ADMIN2, "select public.changer_role('%s', 'client');" % ADMIN, 0.3))
    t1.start(); t2.start(); t1.join(); t2.join()
    verifier('deux administrateurs se rétrogradent l\'un l\'autre au même instant : le dernier reste',
             (un(db, "select count(*) from clients where role = 'admin';"),
              'LAST_ADMIN' in sorties['B'] or 'PERMISSION_DENIED' in sorties['B']), ('1', True))
    jsonq(db, ADMIN, "select public.changer_role('%s', 'admin');" % ADMIN2)

    print('\nD. La matrice : chaque rôle face à chaque action')
    nouveau = dict(base, description='Nouveau colis')
    tests = [
        # (action, SQL, admin, gérant, employé, client)
        ('enregistrer un colis', "select public.creer_colis(%s);" % colis(nouveau), 'aucune', 'aucune', 'aucune', REFUS),
        ('… avec un tarif particulier', "select public.creer_colis(%s);" % colis(dict(nouveau, tarif_lb_usd=2)),
         'aucune', 'aucune', REFUS, REFUS),
        ('modifier un colis', "select public.modifier_colis('%s', %s);" % (cm['colis']['id'], js({'destination': 'Léogâne'})),
         'aucune', 'aucune', 'aucune', REFUS),
        ('changer un statut', "select public.changer_statut_colis(array['%s']::uuid[], 'emballe', 'Miami');" % cm['colis']['id'],
         'aucune', 'aucune', 'aucune', REFUS),
        ('scanner un code', "select public.scanner_colis('MARIE-1');", 'aucune', 'aucune', 'aucune', REFUS),
        ('opération au scanner', "select public.scanner_operation('MARIE-1', 'COLIS_INSPECTE', 'Miami', null, '{}', null, null, null);",
         'aucune', 'aucune', 'aucune', REFUS),
        ('historique interne', "select public.historique_colis('%s');" % cj['colis']['id'], 'aucune', 'aucune', 'aucune', REFUS),
        ('facturer un colis', "select public.facturer_colis('%s');" % cm['colis']['id'], 'aucune', 'aucune', REFUS, REFUS),
        ('créer une facture', "select public.creer_facture('%s', null, %s);" % (JEAN, js({'montant_usd': 3})),
         'aucune', 'aucune', REFUS, REFUS),
        ('résumé de la facturation', "select public.resume_facturation();", 'aucune', 'aucune', REFUS, REFUS),
        ('rapport d\'anomalies', "select public.rapport_anomalies_facturation();", 'aucune', 'aucune', REFUS, REFUS),
        ('aperçu de facture', "select public.calculer_facture(array['%s']::uuid[]);" % cm['colis']['id'],
         'aucune', 'aucune', 'aucune', REFUS),
        ('prévenir le client par e-mail', "select public.envoyer_email_client('%s', 'disponible', 'x', '<p>x</p>', 'x');"
         % cm['colis']['id'], 'aucune', 'aucune', 'aucune', REFUS),
        ('chiffres du tableau de bord', "select public.statistiques_admin();", 'aucune', 'aucune', 'aucune', REFUS),
        ('voir l\'équipe', "select public.equipe();", 'aucune', 'aucune', REFUS, REFUS),
        ('renvoyer les e-mails de bienvenue', "select public.renvoyer_courriels_bienvenue('%s');"
         % un(db, "select code from clients where id = '%s';" % JEAN), 'aucune', REFUS, REFUS, REFUS),
    ]
    verifier('changer le tarif d\'un colis (une valeur par rôle) : admin / gérant / employé / client',
             [code(db, qui, "select public.modifier_colis('%s', %s);" % (cm['colis']['id'], js({'tarif_lb_usd': t})))
              for qui, t in ((ADMIN, 3), (GERANT, 4), (EMPLOYE, 6), (MARIE, 7))], ['aucune', 'aucune', REFUS, REFUS])
    for titre, sql, *attendus in tests:
        obtenus = []
        for qui in (ADMIN, GERANT, EMPLOYE, MARIE):
            obtenus.append(code(db, qui, sql))
        verifier(titre + ' : admin / gérant / employé / client', obtenus, attendus)

    fp = creer(db, EMPLOYE, dict(base, description='Colis de l\'employée'))
    verifier('le colis de l\'employée naît avec sa facture (sans invoices.create)',
             (fp['facture'] is not None, fp['facture']['montant_usd']), (True, 30))
    lien = "select public.definir_lien_paiement('%s', 'https://paypal.test/%s');"
    verifier('… elle pose son premier lien de paiement', code(db, EMPLOYE, lien % (fp['facture']['id'], 'a')), 'aucune')
    verifier('… mais n\'y retouche plus', code(db, EMPLOYE, lien % (fp['facture']['id'], 'b')), REFUS)
    verifier('un lien qui n\'est pas https:// : refusé', code(db, ADMIN, "select public.definir_lien_paiement('%s', "
                                                                         "'javascript:alert(1)');" % fp['facture']['id']),
             'INVALID_INPUT')
    verifier('un client ne pose aucun lien', code(db, MARIE, lien % (fp['facture']['id'], 'c')), REFUS)
    fid = cm['facture']['id']
    paye = "select public.enregistrer_paiement('%s', %s);" % (fid, js({'montant_usd': 1, 'moyen': 'especes'}))
    verifier('encaisser : admin et gérant, pas l\'employée ni le client',
             [code(db, qui, paye) for qui in (ADMIN, GERANT, EMPLOYE, MARIE)], ['aucune', 'aucune', REFUS, REFUS])
    pid = un(db, "select id from paiements where facture_id = '%s' order by cree_le limit 1;" % fid)
    verifier('annuler un paiement : l\'employée et le client ne peuvent pas',
             [code(db, qui, "select public.annuler_paiement('%s', 'x');" % pid) for qui in (EMPLOYE, MARIE)], [REFUS, REFUS])
    verifier('… le gérant, si', code(db, GERANT, "select public.annuler_paiement('%s', 'Erreur de saisie');" % pid), 'aucune')
    fx = creer(db, ADMIN, dict(base, description='À annuler'))['facture']['id']
    verifier('annuler une facture : l\'employée et le client ne peuvent pas',
             [code(db, qui, "select public.annuler_facture('%s', 'x');" % fx) for qui in (EMPLOYE, MARIE)], [REFUS, REFUS])
    verifier('… le gérant, si', code(db, GERANT, "select public.annuler_facture('%s', 'Doublon');" % fx), 'aucune')
    g = [creer(db, ADMIN, dict(base, description='G%d' % k))['facture']['id'] for k in (1, 2)]
    verifier('regrouper : refusé à l\'employée', code(db, EMPLOYE, "select public.regrouper_factures(array['%s','%s']::uuid[]);"
                                                               % tuple(g)), REFUS)
    verifier('corriger une étape : refusé à l\'employée (shipments.correct), rien de changé',
             (code(db, EMPLOYE, "select public.changer_statut_colis(array['%s']::uuid[], 'recu', '', '', null, 'Erreur');"
                   % cm['colis']['id']), un(db, "select statut from colis where id = '%s';" % cm['colis']['id'])),
             (REFUS, 'emballe'))
    corr = jsonq(db, GERANT, "select public.changer_statut_colis(array['%s']::uuid[], 'recu', '', '', null, 'Erreur');"
                 % cm['colis']['id'])
    verifier('… le gérant corrige', corr['modifies'], 1)

    print('\nE. Directement dans les tables, en contournant les fonctions')
    verifier('employée : supprimer un colis → aucune ligne (shipments.delete)',
             lignes(db, EMPLOYE, "with m as (delete from colis where id = '%s' returning 1) select count(*) from m;"
                    % fp['colis']['id']), '0')
    verifier('employée : changer un tarif dans la table → refusé',
             code(db, EMPLOYE, "update colis set tarif_lb_usd = 0 where id = '%s';" % fp['colis']['id']), REFUS)
    verifier('employée : changer un statut dans la table → refusé (moteur d\'événements)',
             code(db, EMPLOYE, "update colis set statut = 'livre' where id = '%s';" % fp['colis']['id']) != 'aucune', True)
    verifier('employée : modifier une facture dans la table → aucune ligne (invoices.edit)',
             lignes(db, EMPLOYE, "with m as (update factures set note = 'x' where id = '%s' returning 1) "
                                 "select count(*) from m;" % fid), '0')
    verifier('employée : créer une facture dans la table → refusé (invoices.create)',
             'row-level security' in code(db, EMPLOYE, "insert into factures (client_id, montant_usd) values ('%s', 1);" % JEAN),
             True)
    verifier('personne ne supprime une facture ni un paiement',
             [code(db, ADMIN, "delete from %s where true;" % t)[:17] for t in ('factures', 'facture_lignes', 'paiements')],
             ['permission denied'] * 3)
    verifier('gérant : modifier la note d\'une facture → permis',
             lignes(db, GERANT, "with m as (update factures set note = 'Merci' where id = '%s' returning 1) "
                                "select count(*) from m;" % fid), '1')
    verifier('journal d\'audit : administrateur seulement',
             [compter(db, qui, 'journal_audit') != '0' for qui in (ADMIN, GERANT, EMPLOYE, MARIE)], [True, False, False, False])
    verifier('file des événements de facturation : administrateur seulement',
             [compter(db, qui, 'evenements_facturation') != '0' for qui in (ADMIN, GERANT, EMPLOYE, MARIE)],
             [True, False, False, False])
    verifier('fiches : l\'employée voit les clients, pas l\'équipe',
             (compter(db, EMPLOYE, 'clients', "role = 'client'") != '0',
              compter(db, EMPLOYE, 'clients', "role <> 'client' and id <> '%s'" % EMPLOYE)), (True, '0'))

    print('\nF. Isolation des clients, table par table')
    tables = [('colis', 'client_id'), ('colis_details', 'client_id'), ('factures', 'client_id'),
              ('paiements', 'client_id'), ('prealertes', 'client_id'), ('appareils', 'client_id'),
              ('clients', 'id')]
    for table, col in tables:
        verifier('%s : Marie ne voit que les siens' % table,
                 (compter(db, MARIE, table, "%s <> '%s'" % (col, MARIE)),
                  compter(db, MARIE, table, "%s = '%s'" % (col, JEAN))), ('0', '0'))
    verifier('colis_historique : aucune étape d\'un colis de Jean',
             compter(db, MARIE, 'colis_historique', "colis_id = '%s'" % cj['colis']['id']), '0')
    verifier('facture_lignes : aucune ligne d\'une facture de Jean',
             compter(db, MARIE, 'facture_lignes', "facture_id = '%s'" % cj['facture']['id']), '0')
    verifier('notifications, journal, numéros, événements : rien',
             [compter(db, MARIE, t) for t in ('notifications', 'journal_audit', 'factures_numeros', 'evenements_facturation')],
             ['0', '0', '0', '0'])
    verifier('Marie voit bien ses propres colis, factures et paiements',
             [compter(db, MARIE, t, "client_id = '%s'" % MARIE) != '0' for t in ('colis', 'factures')], [True, True])
    for titre, sql in (
            ('modifier un colis de Jean', "update colis set description = 'x' where id = '%s'" % cj['colis']['id']),
            ('supprimer un colis de Jean', "delete from colis where id = '%s'" % cj['colis']['id']),
            ('modifier une facture de Jean', "update factures set note = 'x' where id = '%s'" % cj['facture']['id']),
            ('modifier une pré-alerte de Jean', "update prealertes set magasin = 'x' where client_id = '%s'" % JEAN),
            ('supprimer une pré-alerte de Jean', "delete from prealertes where client_id = '%s'" % JEAN)):
        verifier('Marie → %s : aucune ligne' % titre,
                 lignes(db, MARIE, "with m as (%s returning 1) select count(*) from m;" % sql), '0')
    verifier('Marie → une pré-alerte au nom de Jean : refusé',
             'row-level security' in code(db, MARIE, "insert into prealertes (client_id, magasin, description) "
                                                     "values ('%s', 'x', 'y');" % JEAN), True)
    verifier('Marie → l\'historique d\'un colis de Jean par la fonction : refusé',
             code(db, MARIE, "select public.historique_colis('%s');" % cj['colis']['id']), REFUS)
    verifier('Marie → retrouver un colis de Jean par son numéro : refusé',
             code(db, MARIE, "select public.trouver_colis('JEAN-1');"), REFUS)
    verifier('Marie → ses factures : aucune de Jean',
             all(f['id'] != cj['facture']['id'] for f in jsonq(db, MARIE, "select public.mes_factures();")), True)
    verifier('Marie → mes_permissions : client, hors équipe',
             (lambda m: (m['role'], m['equipe'], 'shipments.view:own' in m['permissions']))(
                 jsonq(db, MARIE, "select public.mes_permissions();")), ('client', False, True))
    verifier('suivi public : numéro connu, ni nom ni prix',
             sorted(jsonq(db, None, "select public.suivre_colis('JEAN-1');").keys()) ==
             sorted(jsonq(db, None, "select public.suivre_colis('MARIE-1');").keys())
             and 'nom_complet' not in json.dumps(jsonq(db, None, "select public.suivre_colis('JEAN-1');")), True)

    print('\nG. Le visiteur non connecté')
    for table in ('clients', 'colis', 'colis_historique', 'factures', 'facture_lignes', 'paiements', 'notifications',
                  'prealertes', 'appareils', 'journal_audit', 'evenements_facturation', 'factures_numeros'):
        verifier('visiteur → %s : refusé' % table, 'permission denied' in code(db, None, 'select * from %s;' % table), True)
    ouvertes = un(db, "select string_agg(p.proname, ',' order by p.proname) from pg_proc p "
                      "join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind = 'f' "
                      "and p.prorettype <> 'trigger'::regtype and has_function_privilege('anon', p.oid, 'execute');")
    verifier('visiteur : seules les fonctions publiques du suivi et des e-mails',
             ouvertes, 'adresse_miami,courriels_compte_textes,html_echappe,suivre_colis')

    print('\nH. Toute fonction qui agit avec les droits de la base vérifie une permission')
    libres = un(db, "select coalesce(string_agg(p.proname, ',' order by p.proname), '') from pg_proc p "
                    "join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prosecdef "
                    "and p.prorettype <> 'trigger'::regtype and has_function_privilege('authenticated', p.oid, 'execute') "
                    "and p.prosrc !~ '(exiger_permission|peut\\(|auth\\.uid\\(\\))';")
    verifier('aucune fonction ouverte sans contrôle, hors le suivi public et evenement_corrige (oui/non)',
             libres, 'evenement_corrige,suivre_colis')
    verifier('toute fonction « security definer » a son search_path',
             un(db, "select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace "
                    "where n.nspname = 'public' and p.prosecdef and not exists "
                    "(select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%');"), '0')
    verifier('sécurité active sur toutes les tables',
             un(db, "select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace "
                    "where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;"), '0')

    print('\nI. Les deux côtés d\'accord')
    matrice = json.loads(subprocess.run(['node', os.path.join(ICI, 'essai-permissions.js'), '--matrice'],
                                        capture_output=True, text=True, check=True).stdout)
    for role in ('admin', 'gerant', 'employe', 'client'):
        verifier('permissions « %s » : api.js = base' % role, sorted(matrice[role]),
                 sorted(json.loads(un(db, "select to_json(public.permissions_du_role('%s'));" % role))))
    verifier('un rôle inconnu n\'a rien', un(db, "select cardinality(public.permissions_du_role('pirate'));"), '0')

    n = sum(S.RESULTATS)
    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), n))
    sys.exit(0 if n == len(S.RESULTATS) else 1)


if __name__ == '__main__':
    main()
