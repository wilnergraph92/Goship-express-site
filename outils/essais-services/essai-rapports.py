# -*- coding: utf-8 -*-
"""Éprouve les rapports (onglet « Rapport », outils/supabase-rapports.sql).

Même base jetable et mêmes rôles SQL que essai-services.py, avec toute la chaîne
de outils/migrations.txt. Un jeu de données de mars 2026, posé à la minute près
(heures de Santo Domingo), permet de vérifier chaque chiffre : colis par statut,
factures payées, impayées, annulées, regroupées et supprimées, paiements annulés,
clients, étapes, activité ; puis les permissions des quatre rôles, les périodes,
les filtres, la pagination, le journal des rapports, et qu'une suppression de
rapport ne touche à aucune autre donnée.

Depuis la racine du site :

    python3 outils/essais-services/essai-rapports.py
"""
import importlib.util
import json
import os
import subprocess
import sys
import time

ICI = os.path.dirname(os.path.abspath(__file__))
# Pas de dossier __pycache__ à côté des essais : il partirait en ligne avec le site.
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location('essai_analytics', os.path.join(ICI, 'essai-analytics.py'))
A = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(A)
S = A.S

RACINE, TRAVAIL = S.RACINE, S.TRAVAIL
OUTILS = os.path.join(RACINE, 'outils')
ADMIN, GERANT, EMPLOYE, MARIE, JEAN, CARO = A.ADMIN, A.GERANT, A.EMPLOYE, A.MARIE, A.JEAN, A.CARO
DORA = '44444444-4444-4444-4444-444444444444'
verifier, jsonq, un, js, dater = S.verifier, S.jsonq, S.un, A.js, A.dater
REFUS = 'PERMISSION_DENIED'
CHAINE = [l.strip() for l in open(os.path.join(OUTILS, 'migrations.txt'), encoding='utf-8')
          if l.strip() and not l.startswith('#')]
# La version publiée avant les rapports (fixe : en CI, HEAD est déjà cette branche)
AVANT = os.environ.get('GOSHIP_AVANT', '5f45410')
MARS = {'periode': 'personnalise', 'debut': '2026-03-01', 'fin': '2026-03-31'}
PHOTO = ("select (select count(*) from colis) || '|' || (select count(*) from factures) || '|' || "
         "(select count(*) from facture_lignes) || '|' || (select count(*) from paiements) || '|' || "
         "(select count(*) from clients) || '|' || (select count(*) from colis_historique) || '|' || "
         "(select coalesce(sum(montant_usd), 0) from factures) || '|' || (select coalesce(sum(montant_usd), 0) from paiements);")


def code(db, compte, texte):
    return S.Base.erreur(db, compte, texte)


def donnees(db, params, compte=ADMIN):
    return jsonq(db, compte, 'select public.rapport_donnees(%s);' % js(params))


def fichier_git(nom, version=AVANT):
    texte = subprocess.run(['git', '-C', RACINE, 'show', '%s:outils/%s' % (version, nom)],
                           capture_output=True, text=True, check=True).stdout
    chemin = os.path.join(TRAVAIL, 'publie-' + nom)
    open(chemin, 'w', encoding='utf-8').write(texte)
    return chemin


def installer(db):
    for f in CHAINE:
        db.fichier(os.path.join(OUTILS, f))


def sd(quand):
    return "'%s'::timestamp at time zone 'America/Santo_Domingo'" % quand


def poser_colis(db, reception, statuts, client=MARIE, description='Colis'):
    """Un colis reçu à `reception` (heure de Santo Domingo), mené par `statuts`, ses
    étapes datées d'une minute en une minute après la réception, sa création au journal
    à la même heure."""
    c = S.creer(db, ADMIN, {'client_id': client, 'description': description, 'poids_lb': 2, 'service': 'aerien',
                            'pays_destination': 'HT', 'destination': 'Jacmel'}, facturer=False)['colis']
    for st in statuts:
        S.statut(db, ADMIN, [c['id']], st, 'Pétion-Ville' if st == 'disponible' else 'Miami')
    db.sql("alter table colis disable trigger user; alter table colis_historique disable trigger user;"
           "update colis set recu_le = %s where id = '%s';"
           "update colis_historique h set cree_le = %s + (x.n - 1) * interval '1 minute' "
           "  from (select id, row_number() over (order by id) as n from colis_historique where colis_id = '%s') x "
           "  where h.id = x.id;"
           "update journal_audit set cree_le = %s where entite = 'colis' and entite_id = '%s';"
           "alter table colis enable trigger user; alter table colis_historique enable trigger user;"
           % (sd(reception), c['id'], sd(reception), c['id'], sd(reception), c['id']))
    return c


def facture(db, client, montant, quand, colis=None):
    if colis:
        # Avec les frais de service, comme un regroupement qui les applique
        # (supabase-frais-service.sql : sans cette demande, une facture de colis n'en a pas)
        f = jsonq(db, ADMIN, "select public.creer_facture('%s', array['%s']::uuid[], %s);"
                  % (client, "','".join(colis), js({'frais_service': True})))['facture']
    else:
        f = jsonq(db, ADMIN, "select public.creer_facture('%s', null, %s);" % (client, js({'montant_usd': montant})))['facture']
    dater(db, 'factures', 'cree_le', f['id'], quand)
    db.sql("update journal_audit set cree_le = %s where entite = 'facture' and entite_id = '%s';" % (sd(quand), f['id']))
    return f


def payer(db, f, montant, moyen, quand):
    return jsonq(db, ADMIN, "select public.enregistrer_paiement('%s', %s);"
                 % (f['id'], js({'montant_usd': montant, 'moyen': moyen, 'paye_le': quand + ':00-04:00'})))


def main():
    print('A. Installation : la chaîne complète, rejouable, et la garde des permissions (depuis %s)' % AVANT)
    db = S.Base()
    db.sql(S.DOUBLURES)
    # La version publiée (sans les permissions des rapports) : ce fichier refuse de s'installer.
    # Seulement les fichiers d'avant lui : ceux qui le suivent n'existaient pas encore.
    for f in CHAINE[:CHAINE.index('supabase-rapports.sql')]:
        db.fichier(fichier_git(f))
    A.comptes(db)
    S.creer(db, ADMIN, {'client_id': MARIE, 'description': 'Avant les rapports', 'poids_lb': 3, 'service': 'aerien',
                        'pays_destination': 'HT', 'destination': 'Jacmel'})
    avant = un(db, PHOTO)
    sortie = db._psql(db.su, S.BASE, open(os.path.join(OUTILS, 'supabase-rapports.sql'), encoding='utf-8').read(),
                      echec_permis=True)
    verifier('sur la version publiée : arrêt, « relancez outils/supabase.sql »',
             'relancez outils/supabase.sql' in sortie, True)
    verifier('… et rien n\'est créé', un(db, "select to_regclass('public.rapports') is null;"), 't')
    installer(db)
    installer(db)
    verifier('toute la chaîne par-dessus, deux fois : aucune erreur', 'oui', 'oui')
    verifier('aucune donnée n\'a bougé', un(db, PHOTO), avant)
    verifier('contrôle de fin de fichier : 5 | 0 | vrai | vrai',
             un(db, "select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace "
                    "where n.nspname = 'public' and p.proname in ('creer_rapport', 'modifier_rapport', 'supprimer_rapport', "
                    "'liste_rapports', 'rapport_donnees')) || '|' || (select count(*) from pg_proc p join pg_namespace n "
                    "on n.oid = p.pronamespace where n.nspname = 'public' and p.proname like '%rapport%' "
                    "and has_function_privilege('anon', p.oid, 'execute')) || '|' || "
                    "(not has_table_privilege('authenticated', 'public.rapports', 'select')) || '|' || "
                    "(select count(*) = 1 from pg_trigger where tgname = 'journaliser_rapport');"),
             '5|0|true|true')
    verifier('les permissions : administrateur (4), gérant (2), employé et client (0)',
             [un(db, "select count(*) from unnest(public.permissions_du_role('%s')) p where p like 'reports.%%';" % r)
              for r in ('admin', 'gerant', 'employe', 'client')], ['4', '2', '0', '0'])
    verifier('gérant : voir et créer, ni modifier ni supprimer',
             un(db, "select string_agg(p, ',' order by p) from unnest(public.permissions_du_role('gerant')) p "
                    "where p like 'reports.%';"), 'reports.create,reports.view')

    print('\nB. Les permissions, vérifiées par la base')
    lire = "select public.rapport_donnees(%s);" % js(MARS)
    liste = "select public.liste_rapports();"
    for nom, sql in (('rapport_donnees', lire), ('liste_rapports', liste)):
        verifier('%s : administrateur et gérant' % nom, (code(db, ADMIN, sql), code(db, GERANT, sql)), ('aucune', 'aucune'))
        verifier('%s : employée et client refusés' % nom, (code(db, EMPLOYE, sql), code(db, MARIE, sql)), (REFUS, REFUS))
        verifier('%s : visiteur refusé' % nom, 'permission denied' in code(db, None, sql), True)
    nouveau = js(dict(MARS, nom='Mars', type='complet'))
    creer = "select public.creer_rapport(%s);" % nouveau
    verifier('créer : employée et client refusés', (code(db, EMPLOYE, creer), code(db, MARIE, creer)), (REFUS, REFUS))
    verifier('créer : visiteur refusé', 'permission denied' in code(db, None, creer), True)
    rg = jsonq(db, GERANT, creer)
    verifier('créer : le gérant peut ; créé par lui, rôle gérant',
             (rg['cree_par_nom'], rg['role_createur'], rg['debut'], rg['fin']), ('Gaël Gérant', 'gerant', '2026-03-01', '2026-03-31'))
    modif = "select public.modifier_rapport('%s', %s);" % (rg['id'], js(dict(MARS, nom='Mars modifié')))
    suppr = "select public.supprimer_rapport('%s');" % rg['id']
    verifier('modifier : le gérant est refusé, même son propre rapport', code(db, GERANT, modif), REFUS)
    verifier('supprimer : le gérant est refusé, même son propre rapport', code(db, GERANT, suppr), REFUS)
    verifier('modifier, supprimer : employée refusée', (code(db, EMPLOYE, modif), code(db, EMPLOYE, suppr)), (REFUS, REFUS))
    verifier('… et le rapport est intact', un(db, "select nom from rapports where id = '%s';" % rg['id']), 'Mars')
    for texte in ("select * from public.rapports;", "insert into public.rapports (nom, type, periode, debut, fin, sections) "
                  "values ('x', 'complet', 'journalier', '2026-01-01', '2026-01-01', '{colis}');",
                  "delete from public.rapports;", "update public.rapports set nom = 'x';"):
        verifier('table fermée, même à l\'administrateur : %s' % texte.split()[0],
                 'permission denied' in code(db, ADMIN, texte), True)
    for f in ("rapport_bornes('mensuel')", "rapport_filtres('{}')", "nom_compte('%s')" % ADMIN,
              "rapport_sections(null, 'complet')", "rapport_statuts('livre')"):
        verifier('aide fermée, même à l\'administrateur (%s)' % f.split('(')[0],
                 'permission denied' in code(db, ADMIN, 'select * from public.%s;' % f), True)

    print('\nC. Les périodes (jours de Santo Domingo, inclus)')
    def bornes(p, d=None, f=None):
        return un(db, "select debut || ' ' || fin from public.rapport_bornes(%s, %s, %s);"
                      % (A.q(p), ("'%s'" % d) if d else 'null', ("'%s'" % f) if f else 'null'))
    verifier('aujourd\'hui : le jour de Santo Domingo', bornes('aujourdhui'),
             un(db, "select public.aujourdhui() || ' ' || public.aujourdhui();"))
    verifier('journalier : le jour choisi', bornes('journalier', '2026-03-17'), '2026-03-17 2026-03-17')
    verifier('hebdomadaire : du lundi au dimanche (mer. 18/03 → 16–22)', bornes('hebdomadaire', '2026-03-18'),
             '2026-03-16 2026-03-22')
    verifier('hebdomadaire : un dimanche reste dans sa semaine', bornes('hebdomadaire', '2026-03-22'), '2026-03-16 2026-03-22')
    verifier('mensuel : février d\'une année bissextile (29 jours)', bornes('mensuel', '2028-02-10'), '2028-02-01 2028-02-29')
    verifier('trimestriel : août → juillet à septembre', bornes('trimestriel', '2026-08-10'), '2026-07-01 2026-09-30')
    verifier('annuel : l\'année entière', bornes('annuel', '2026-06-01'), '2026-01-01 2026-12-31')
    verifier('personnalisée : les dates choisies', bornes('personnalise', '2026-09-01', '2026-09-30'), '2026-09-01 2026-09-30')
    verifier('mensuel sans date : le mois en cours', bornes('mensuel'),
             un(db, "select date_trunc('month', public.aujourdhui())::date || ' ' || "
                    "(date_trunc('month', public.aujourdhui()) + interval '1 month - 1 day')::date;"))
    for titre, params, attendu in (
            ('début après la fin', {'periode': 'personnalise', 'debut': '2026-09-30', 'fin': '2026-09-01'},
             'La date de début doit être antérieure à la date de fin.'),
            ('dates absentes', {'periode': 'personnalise'}, 'Choisissez une date de début et une date de fin.'),
            ('plus de trois ans', {'periode': 'personnalise', 'debut': '2020-01-01', 'fin': '2026-01-01'},
             'Une période de trois ans au plus.'),
            ('date impossible', {'periode': 'journalier', 'debut': '2026-02-30'}, 'Date impossible : 2026-02-30.'),
            ('date illisible', {'periode': 'journalier', 'debut': '17/03/2026'}, 'Date illisible : 17/03/2026.'),
            ('période inconnue', {'periode': 'semestriel'}, 'Période inconnue : semestriel.')):
        sortie = db.comme(ADMIN, 'select public.rapport_donnees(%s);' % js(params), echec_permis=True)
        verifier('refus : %s' % titre, ('INVALID_PERIOD' in sortie, attendu in sortie), (True, True))

    print('\nD. Ce qu\'un rapport refuse d\'enregistrer')
    for titre, champs, attendu in (
            ('sans nom', {'nom': '  '}, 'INVALID_INPUT'),
            ('nom de 121 caractères', {'nom': 'x' * 121}, 'INVALID_INPUT'),
            ('type inconnu', {'type': 'secret'}, 'INVALID_INPUT'),
            ('filtre inconnu', {'filtres': {'pays': 'HT'}}, 'INVALID_INPUT'),
            ('statut de colis inconnu', {'filtres': {'statut_colis': 'annule'}}, 'INVALID_INPUT'),
            ('état de facture inconnu', {'filtres': {'etat_facture': 'perdue'}}, 'INVALID_INPUT'),
            ('donnée inconnue', {'sections': ['colis', 'salaires']}, 'INVALID_INPUT'),
            ('période à l\'envers', {'debut': '2026-03-31', 'fin': '2026-03-01'}, 'INVALID_PERIOD')):
        verifier('refus : %s' % titre,
                 code(db, ADMIN, "select public.creer_rapport(%s);" % js(dict(dict(MARS, nom='Essai'), **champs))), attendu)
    r = jsonq(db, ADMIN, "select public.creer_rapport(%s);" % js(dict(MARS, nom='  Factures  ', type='factures')))
    verifier('type « factures » sans données choisies : finances + factures ; nom sans espaces',
             (r['sections'], r['nom']), (['finances', 'factures'], 'Factures'))
    r = jsonq(db, ADMIN, "select public.creer_rapport(%s);"
              % js(dict(MARS, nom='Ordre', sections=['activite', 'colis', 'colis', 'finances'])))
    verifier('données choisies : dédoublonnées, dans l\'ordre du rapport', r['sections'], ['finances', 'colis', 'activite'])
    r = jsonq(db, ADMIN, "select public.creer_rapport(%s);"
              % js({'nom': 'Semaine', 'periode': 'hebdomadaire', 'debut': '2026-03-18', 'filtres': {'statut_colis': '', 'etat_facture': 'PAYEE'}}))
    verifier('hebdomadaire enregistré en dates ; filtre vide retiré, casse ignorée',
             (r['debut'], r['fin'], r['filtres']), ('2026-03-16', '2026-03-22', {'etat_facture': 'payee'}))
    verifier('une période passée est « close », le mois en cours « en cours »',
             (r['statut'], jsonq(db, ADMIN, "select public.creer_rapport(%s);"
                                 % js({'nom': 'Ce mois', 'periode': 'mensuel'}))['statut']), ('clos', 'en_cours'))

    print('\nE. Un mois de données : les colis')
    dater(db, 'clients', 'cree_le', MARIE, '2026-03-02 09:00')
    a1 = poser_colis(db, '2026-03-01 00:00', [])                                   # reçu (attente)
    a2 = poser_colis(db, '2026-03-03 10:00', ['emballe'])                          # attente
    a3 = poser_colis(db, '2026-03-31 23:59', [])                                   # attente, dernière minute
    t1 = poser_colis(db, '2026-03-05 10:00', ['emballe', 'embarque'], client=JEAN)  # transit
    d1 = poser_colis(db, '2026-03-06 10:00', ['emballe', 'embarque', 'distribution', 'succursale', 'disponible'])
    l1 = poser_colis(db, '2026-03-07 10:00', ['emballe', 'embarque', 'distribution', 'succursale', 'disponible', 'livre'],
                     client=JEAN)
    i1 = poser_colis(db, '2026-03-08 10:00', ['incident'])
    poser_colis(db, '2026-04-01 00:00', [], description='Avril')                    # hors période
    poser_colis(db, '2026-02-28 23:59', [], description='Février')                  # hors période
    parti = poser_colis(db, '2026-03-09 10:00', [], description='À supprimer')
    db.comme(ADMIN, "delete from colis where id = '%s';" % parti['id'])
    db.sql("update journal_audit set cree_le = %s where action = 'colis.suppression' and entite_id = '%s';"
           % (sd('2026-03-10 10:00'), parti['id']))
    m = donnees(db, MARS)
    c = m['statistiques']['colis']
    verifier('7 colis reçus en mars (minuit du 1er et 23 h 59 du 31 compris)', c['total'], 7)
    verifier('par statut : 3 en attente, 1 en transit, 1 disponible, 1 livré, 1 action requise',
             (c['attente'], c['transit'], c['disponible'], c['livre'], c['incident']), (3, 1, 1, 1, 1))
    verifier('1 colis supprimé pendant la période (journal), à part',
             (c['supprimes'], m['donnees']['colis']['total']), (1, 7))
    verifier('= reçus d\'Analytics pour les mêmes jours', c['total'],
             json.loads(un(db, "select public.analytics_mesures(%s, %s) ->> 'recus';" % (sd('2026-03-01 00:00'), sd('2026-04-01 00:00')))))
    lignes = m['donnees']['colis']['lignes']
    verifier('lignes : dans l\'ordre de réception, du 1er au 31', [x['numero'] for x in lignes][0::6],
             [a1['numero'], a3['numero']])
    ll = [x for x in lignes if x['numero'] == l1['numero']][0]
    verifier('colis livré : client, date de livraison, créé par, poids, statut',
             (ll['client_nom'], ll['livre_le'] is not None, ll['cree_par'], ll['poids_lb'], ll['statut']),
             ('Jean Pierre', True, 'Ada Admin', 2, 'livre'))
    verifier('colis non livré : pas de date de livraison', [x['livre_le'] for x in lignes if x['numero'] == a1['numero']], [None])
    f = donnees(db, dict(MARS, filtres={'statut_colis': 'attente'}))
    verifier('filtre « en attente » : 3 colis, 3 lignes, statuts reçu/emballé',
             (f['statistiques']['colis']['total'], len(f['donnees']['colis']['lignes']),
              sorted(set(x['statut'] for x in f['donnees']['colis']['lignes']))), (3, 3, ['emballe', 'recu']))
    verifier('filtre « en attente » : le colis supprimé (reçu) compte', f['statistiques']['colis']['supprimes'], 1)
    f = donnees(db, dict(MARS, filtres={'statut_colis': 'livre'}))
    verifier('filtre « livré » : 1 colis, aucun supprimé', (f['statistiques']['colis']['total'],
                                                          f['statistiques']['colis']['supprimes']), (1, 0))
    ev = m['statistiques']['evenements']
    verifier('étapes de mars = celles de la table pour ces colis', ev['total'],
             int(un(db, "select count(*) from colis_historique where cree_le >= %s and cree_le < %s;"
                        % (sd('2026-03-01 00:00'), sd('2026-04-01 00:00')))))
    verifier('1 livraison', ev['livraisons'], 1)
    # Une livraison corrigée : marquée annulée, la correction comptée
    S.statut(db, ADMIN, [l1['id']], 'disponible', 'Pétion-Ville', motif='Livré par erreur')
    db.sql("alter table colis_historique disable trigger user; update colis_historique set cree_le = %s "
           "where type_evenement = 'CORRECTION'; alter table colis_historique enable trigger user;" % sd('2026-03-07 12:00'))
    m = donnees(db, dict(MARS, sections=['evenements'], limite=500))
    corr = [x for x in m['donnees']['evenements']['lignes'] if x['type_evenement'] == 'CORRECTION']
    annulee = [x for x in m['donnees']['evenements']['lignes'] if x['numero'] == l1['numero'] and x['statut'] == 'livre']
    verifier('correction : une ligne CORRECTION, la livraison marquée annulée',
             (len(corr), m['statistiques']['evenements']['corrections'], annulee[0]['annule']), (1, 1, True))
    verifier('… et le colis n\'a plus de date de livraison',
             [x['livre_le'] for x in donnees(db, MARS)['donnees']['colis']['lignes'] if x['numero'] == l1['numero']], [None])

    print('\nF. Les factures : payées, impayées, annulées, regroupées, supprimées')
    f1 = facture(db, MARIE, 100, '2026-03-04 09:00')
    f2 = facture(db, JEAN, 80, '2026-03-05 09:00')
    f3 = facture(db, MARIE, 50, '2026-03-06 09:00')
    f4 = facture(db, JEAN, 40, '2026-03-07 09:00')
    # Deux factures de colis (2 lb à 5 $ + 10 $ de frais : 20 $ chacune), que l'on regroupe
    f5 = facture(db, MARIE, None, '2026-03-08 09:00', colis=[a1['id']])
    f6 = facture(db, MARIE, None, '2026-03-09 09:00', colis=[a2['id']])
    facture(db, JEAN, 999, '2026-04-02 09:00')                                     # hors période
    payer(db, f1, 100, 'especes', '2026-03-05T10:00')
    payer(db, f2, 30, 'moncash', '2026-03-06T10:00')
    p3 = payer(db, f3, 10, 'especes', '2026-03-07T10:00')
    jsonq(db, ADMIN, "select public.annuler_paiement('%s', 'Saisi par erreur');" % p3['paiement']['id'])
    db.sql("alter table paiements disable trigger user; update paiements set annule_le = %s where annule_le is not null;"
           "alter table paiements enable trigger user;" % sd('2026-03-07 11:00'))
    jsonq(db, ADMIN, "select public.annuler_facture('%s', 'Doublon');" % f4['id'])
    f7 = jsonq(db, ADMIN, "select public.regrouper_factures(array['%s', '%s']::uuid[]);" % (f5['id'], f6['id']))
    f7 = f7.get('facture') or f7
    dater(db, 'factures', 'cree_le', f7['id'], '2026-03-20 09:00')
    n7 = float(f7['montant_usd'])
    verifier('les deux factures de colis : 20 $ chacune ; regroupées en une de %g $' % n7,
             (float(f5['montant_usd']), float(f6['montant_usd']), n7 > 0), (20, 20, True))
    # Un client parti : son compte supprimé emporte sa facture, que le journal garde
    db.sql("""insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
              values ('%s', 'dora@exemple.com', now(), '{"nom_complet":"Dora Partie","pays":"HT"}'::jsonb);""" % DORA)
    f8 = facture(db, DORA, 60, '2026-03-21 09:00')
    db.sql("delete from auth.users where id = '%s';" % DORA)
    db.sql("update journal_audit set cree_le = %s where action in ('facture.suppression', 'client.suppression') "
           "and entite_id in ('%s', '%s');" % (sd('2026-03-25 10:00'), f8['id'], DORA))
    m = donnees(db, MARS)
    fa = m['statistiques']['factures']
    verifier('7 factures émises en mars (la supprimée à part)', fa['total'], 7)
    verifier('payées 1, impayées 3 (dont 1 partielle), annulées 3 (dont 2 regroupées), supprimées 1',
             (fa['payees'], fa['impayees'], fa['partielles'], fa['annulees'], fa['regroupees'], fa['supprimees']),
             (1, 3, 1, 3, 2, 1))
    verifier('facturé (hors annulées) = payé 130 + impayé',
             (fa['montant_facture'], fa['montant_paye'], fa['montant_impaye']), (230 + n7, 130, 100 + n7))
    verifier('annulé 80, supprimé 60 : jamais dans le facturé', (fa['montant_annule'], fa['montant_supprime']), (80, 60))
    mes = json.loads(un(db, "select public.analytics_mesures(%s, %s);" % (sd('2026-03-01 00:00'), sd('2026-04-01 00:00'))))
    verifier('= Analytics : facturé, reste, encaissé', (fa['montant_facture'], fa['montant_impaye'],
                                                      m['statistiques']['paiements']['encaisse']),
             (mes['facture'], mes['reste'], mes['encaisse']))
    pa = m['statistiques']['paiements']
    verifier('paiements : 2 valides (130 $), 1 annulé (10 $)',
             (pa['nombre'], pa['encaisse'], pa['annules'], pa['montant_annule']), (2, 130, 1, 10))
    verifier('par moyen : espèces 100, MonCash 30', sorted((x['moyen'], x['montant']) for x in pa['par_moyen']),
             [('especes', 100), ('moncash', 30)])
    verifier('restait dû à la fin de mars = la somme des soldes de ce jour-là',
             pa['creances_fin'], float(un(db, "select public.creances_au(%s);" % sd('2026-04-01 00:00'))))
    lf = {x['numero']: x for x in m['donnees']['factures']['lignes']}
    verifier('lignes : état, payé, solde de chacune',
             [(lf[x['numero']]['etat'], lf[x['numero']]['paye'], lf[x['numero']]['solde']) for x in (f1, f2, f3, f4)],
             [('payee', 100, 0), ('partielle', 30, 50), ('a_payer', 0, 50), ('annulee', 0, 0)])
    verifier('regroupées : « remplacée par » le numéro de la nouvelle', lf[f5['numero']]['remplacee_par'], f7['numero'])
    verifier('annulée : motif gardé', lf[f4['numero']]['motif_annulation'], 'Doublon')
    sup = m['donnees']['factures']['supprimees']
    verifier('supprimée : son numéro et son montant, lus dans le journal',
             (sup['total'], sup['lignes'][0]['numero'], sup['lignes'][0]['montant_usd']), (1, f8['numero'], 60))
    for etat, attendu in (('payee', (1, 100, 100, 0, 0, 0)), ('impayee', (3, 130 + n7, 30, 100 + n7, 0, 0)),
                          ('annulee', (3, 0, 0, 0, 80, 0)), ('supprimee', (0, 0, 0, 0, 0, 1))):
        g = donnees(db, dict(MARS, filtres={'etat_facture': etat}))
        s = g['statistiques']['factures']
        verifier('filtre « %s » : total, facturé, payé, impayé, annulé, supprimées' % etat,
                 (s['total'], s['montant_facture'], s['montant_paye'], s['montant_impaye'], s['montant_annule'],
                  s['supprimees']), attendu)
        verifier('filtre « %s » : autant de lignes que le total' % etat,
                 len(g['donnees']['factures']['lignes']), s['total'])
    lp = m['donnees']['paiements']['lignes']
    verifier('lignes de paiements : 3, l\'annulé marqué, saisi par l\'administrateur',
             (len(lp), sum(1 for x in lp if x['annule_le']), set(x['saisi_par'] for x in lp)), (3, 1, {'Ada Admin'}))

    print('\nG. Les clients et l\'activité')
    cl = m['statistiques']['clients']
    verifier('clients : 1 nouveau (Marie), 2 actifs (Marie, Jean)', (cl['nouveaux'], cl['actifs']), (1, 2))
    lc = {x['nom']: x for x in m['donnees']['clients']['lignes']}
    verifier('lignes : Marie et Jean seulement (le compte supprimé n\'y est plus)', sorted(lc), ['Jean Pierre', 'Marie-Ange Dorvil'])
    verifier('Marie : nouvelle, 5 colis, facturé %g, payé 100' % (150 + n7),
             (lc['Marie-Ange Dorvil']['nouveau'], lc['Marie-Ange Dorvil']['colis'], lc['Marie-Ange Dorvil']['facture'],
              lc['Marie-Ange Dorvil']['paye']), (True, 5, 150 + n7, 100))
    # Une ligne du journal que seul audit_logs.view peut lire (réglage des notifications)
    db.sql("insert into journal_audit (auteur_id, action, entite, entite_id, cree_le) values "
           "('%s', 'notification.regle', 'notification', 'x', %s);" % (ADMIN, sd('2026-03-26 10:00')))
    ad = donnees(db, dict(MARS, sections=['activite'], limite=2000))
    ge = donnees(db, dict(MARS, sections=['activite'], limite=2000), compte=GERANT)
    verifier('activité : le gérant voit tout sauf la ligne des réglages',
             ad['donnees']['activite']['total'] - ge['donnees']['activite']['total'], 1)
    verifier('… statistiques et lignes disent la même chose',
             (ad['statistiques']['activite']['total'], ge['statistiques']['activite']['total']),
             (ad['donnees']['activite']['total'], ge['donnees']['activite']['total']))
    act = {x['action'] for x in ad['donnees']['activite']['lignes']}
    verifier('activité : créations, statuts, suppressions, paiements, annulations',
             {'colis.creation', 'colis.suppression', 'facture.creation', 'facture.suppression', 'client.suppression',
              'notification.regle'} <= act, True)
    sf = [x for x in ad['donnees']['activite']['lignes'] if x['action'] == 'facture.suppression'][0]
    verifier('suppression de facture : référence = son numéro, montant dans « avant »',
             (sf['reference'], sf['avant']['montant_usd']), (f8['numero'], 60))
    verifier('les suppressions se comptent à part', ad['statistiques']['activite']['suppressions'],
             sum(1 for x in ad['donnees']['activite']['lignes'] if x['action'].endswith('.suppression')))

    print('\nH. Pages de lignes et parties seules')
    tout = donnees(db, dict(MARS, sections=['colis'], limite=100))['donnees']['colis']['lignes']
    page = donnees(db, dict(MARS, sections=['colis'], limite=2, decalage=2))
    verifier('limite 2, décalage 2 : les lignes 3 et 4, total entier',
             ([x['numero'] for x in page['donnees']['colis']['lignes']], page['donnees']['colis']['total']),
             ([x['numero'] for x in tout[2:4]], 7))
    seule = donnees(db, dict(MARS, section='factures', limite=1, decalage=1))
    verifier('une seule partie : pas de statistiques, seulement ses lignes',
             ('statistiques' in seule, sorted(seule['donnees']), len(seule['donnees']['factures']['lignes'])),
             (False, ['factures'], 1))
    verifier('une partie hors du rapport est refusée',
             code(db, ADMIN, 'select public.rapport_donnees(%s);' % js(dict(MARS, sections=['colis'], section='factures'))),
             'INVALID_INPUT')
    verifier('limite bornée à 2 000', donnees(db, dict(MARS, sections=['colis'], limite=99999))['limite'], 2000)
    verifier('seules les parties demandées sont lues', sorted(donnees(db, dict(MARS, type='paiements'))['donnees']),
             ['paiements'])
    vide = donnees(db, {'periode': 'journalier', 'debut': '2025-01-01'})
    verifier('un jour sans rien : zéros partout, listes vides',
             (vide['statistiques']['colis']['total'], vide['statistiques']['factures']['montant_facture'],
              sum(v['total'] for v in vide['donnees'].values())), (0, 0, 0))

    print('\nI. Enregistrer, modifier, supprimer : le journal, et rien d\'autre')
    r = jsonq(db, ADMIN, "select public.creer_rapport(%s);" % js(dict(MARS, nom='Rapport mensuel - Mars 2026')))
    j = json.loads(un(db, "select json_build_object('action', action, 'auteur', auteur_id, 'nom', apres ->> 'nom') "
                          "from journal_audit where entite = 'rapport' and entite_id = '%s';" % r['id']))
    verifier('création au journal : action, auteur, nom', (j['action'], j['auteur'], j['nom']),
             ('rapport.creation', ADMIN, 'Rapport mensuel - Mars 2026'))
    time.sleep(0.01)
    r2 = jsonq(db, ADMIN, "select public.modifier_rapport('%s', %s);"
               % (r['id'], js({'nom': 'Rapport trimestriel', 'periode': 'trimestriel', 'debut': '2026-02-01',
                               'filtres': {'etat_facture': 'impayee'}, 'sections': ['factures']})))
    verifier('modifié : nouvelles dates, filtres, parties ; créé par inchangé ; modifié le posé',
             (r2['debut'], r2['fin'], r2['filtres'], r2['sections'], r2['cree_par_nom'], r2['modifie_le'] is not None,
              r2['modifie_par_nom']),
             ('2026-01-01', '2026-03-31', {'etat_facture': 'impayee'}, ['factures'], 'Ada Admin', True, 'Ada Admin'))
    j = json.loads(un(db, "select json_build_object('avant', avant ->> 'nom', 'apres', apres ->> 'nom') from journal_audit "
                          "where action = 'rapport.modification' and entite_id = '%s';" % r['id']))
    verifier('modification au journal : avant, après', (j['avant'], j['apres']), ('Rapport mensuel - Mars 2026', 'Rapport trimestriel'))
    verifier('modifier un rapport qui n\'existe pas : NOT_FOUND',
             code(db, ADMIN, "select public.modifier_rapport(gen_random_uuid(), %s);" % js(dict(MARS, nom='x'))), 'NOT_FOUND')
    photo = un(db, PHOTO)
    journal = int(un(db, "select count(*) from journal_audit;"))
    ok = jsonq(db, ADMIN, "select public.supprimer_rapport('%s');" % r['id'])
    verifier('supprimé par l\'administrateur', (ok['supprime'], un(db, "select count(*) from rapports where id = '%s';" % r['id'])),
             (True, '0'))
    verifier('colis, factures, lignes, paiements, clients, étapes, montants : inchangés', un(db, PHOTO), photo)
    verifier('le journal garde une ligne de plus : le rapport supprimé, tout entier',
             (int(un(db, "select count(*) from journal_audit;")) - journal,
              un(db, "select avant ->> 'nom' || '|' || (avant ->> 'debut') from journal_audit "
                     "where action = 'rapport.suppression' and entite_id = '%s';" % r['id'])),
             (1, 'Rapport trimestriel|2026-01-01'))
    verifier('supprimer deux fois : NOT_FOUND', code(db, ADMIN, "select public.supprimer_rapport('%s');" % r['id']), 'NOT_FOUND')
    verifier('les données d\'un mois se lisent toujours pareil après la suppression',
             donnees(db, MARS)['statistiques']['factures'], m['statistiques']['factures'])
    li = jsonq(db, GERANT, "select public.liste_rapports();")
    verifier('liste : les plus récents d\'abord', li['lignes'][0]['cree_le'] >= li['lignes'][-1]['cree_le'], True)
    verifier('liste : recherche sur le nom, sans casse',
             [x['nom'] for x in jsonq(db, GERANT, "select public.liste_rapports('SEMAINE');")['lignes']], ['Semaine'])
    verifier('liste : total et page', (li['total'], len(jsonq(db, GERANT, "select public.liste_rapports(null, 2, 0);")['lignes'])),
             (int(un(db, "select count(*) from rapports;")), 2))

    print('\nJ. La copie démo (api.js) : même forme, mêmes jours')
    def sans_variable(liste):
        # « avant » / « après » d'une ligne du journal et le compte par entité n'ont pas de clés fixes
        return [c for c in liste if not c.startswith(('donnees.activite.lignes.[].avant.', 'donnees.activite.lignes.[].apres.',
                                                      'statistiques.activite.par_entite.'))]
    demo = json.loads(subprocess.run(['node', os.path.join(ICI, 'essai-rapports.js'), '--formes'],
                                     capture_output=True, text=True, check=True).stdout)
    r = jsonq(db, ADMIN, "select public.creer_rapport(%s);" % js(dict(MARS, nom='Forme')))
    verifier('un rapport : mêmes clés des deux côtés', A.cles(r), demo['rapport'])
    verifier('la liste : mêmes clés', A.cles(jsonq(db, ADMIN, "select public.liste_rapports();")), demo['liste'])
    base = sans_variable(A.cles(donnees(db, dict(MARS, limite=500))))
    verifier('les données d\'un rapport complet : mêmes clés (%d)' % len(base), base, sans_variable(demo['donnees']))
    bornes_demo = json.loads(subprocess.run(['node', os.path.join(ICI, 'essai-rapports.js'), '--bornes'],
                                            capture_output=True, text=True, check=True).stdout)
    for (cas, jours) in bornes_demo:
        verifier('période %s : mêmes jours' % ' '.join(cas), bornes(*cas), jours)

    print('\nK. Le volume : 3 000 colis dans un mois')
    db.sql("alter table colis disable trigger user;"
           "insert into colis (numero, client_id, description, poids_lb, statut, recu_le, pays_destination, destination) "
           "select 'GSE-V' || g, '%s', 'Volume', 1, 'recu', %s + g * interval '10 minutes', 'HT', 'Jacmel' "
           "from generate_series(1, 3000) g;"
           "alter table colis enable trigger user;" % (MARIE, sd('2026-05-01 00:00')))
    debut = time.time()
    v = donnees(db, {'periode': 'mensuel', 'debut': '2026-05-15'})
    duree = time.time() - debut
    verifier('3 000 colis comptés par la base, 50 lignes envoyées',
             (v['statistiques']['colis']['total'], len(v['donnees']['colis']['lignes'])), (3000, 50))
    verifier('réponse en moins de 3 secondes (%.2f s)' % duree, duree < 3, True)
    v = donnees(db, {'periode': 'mensuel', 'debut': '2026-05-15', 'sections': ['colis'], 'limite': 2000})
    verifier('pour le PDF : 2 000 lignes au plus', len(v['donnees']['colis']['lignes']), 2000)

    n = sum(S.RESULTATS)
    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), n))
    sys.exit(0 if n == len(S.RESULTATS) else 1)


if __name__ == '__main__':
    main()
