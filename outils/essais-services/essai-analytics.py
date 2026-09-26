# -*- coding: utf-8 -*-
"""Éprouve les Analytics (Phase 8, outils/supabase-analytics.sql).

Même base jetable et mêmes rôles SQL que essai-services.py. Un jeu de données
contrôlé — des dates posées à la minute près — permet de vérifier chaque
chiffre : volumes, statuts, délais tirés des événements, facturé et encaissé,
créances reconstituées, tarif historique, clients, routes, scanner, qualité ;
puis les permissions, les frontières de dates (23 h 59, minuit, fin de mois,
fin d'année), la cohérence avec le tableau de bord et le volume.

Depuis la racine du site :

    python3 outils/essais-services/essai-analytics.py
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
_spec = importlib.util.spec_from_file_location('essai_services', os.path.join(ICI, 'essai-services.py'))
S = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(S)

RACINE, TRAVAIL = S.RACINE, S.TRAVAIL
ADMIN, MARIE, JEAN = S.ADMIN, S.MARIE, S.JEAN
GERANT = 'bbbbbbbb-0000-0000-0000-00000000000b'
EMPLOYE = 'cccccccc-0000-0000-0000-00000000000c'
CARO = '33333333-3333-3333-3333-333333333333'
verifier, jsonq, creer, statut, un = S.verifier, S.jsonq, S.creer, S.statut, S.un

# La version publiée avant la Phase 8
AVANT = os.environ.get('GOSHIP_AVANT', '4d0fac0')
FICHIERS = ('supabase.sql', 'supabase-facturation.sql', 'supabase-services.sql', 'supabase-evenements.sql',
            'supabase-scanner.sql', 'supabase-finances.sql', 'supabase-tableau-de-bord.sql')
NOUVEAUX = [os.path.join(RACINE, 'outils', f) for f in FICHIERS + ('supabase-analytics.sql',)]
REFUS = 'PERMISSION_DENIED'
MODULES = ("analytics_synthese('30j')", "analytics_serie('30j')", "analytics_operations('30j')",
           "analytics_clients('30j')", "analytics_finances('30j')", "analytics_routes('30j')",
           "analytics_scanner('30j')", "analytics_qualite()")


def fichier_git(nom):
    texte = subprocess.run(['git', '-C', RACINE, 'show', '%s:outils/%s' % (AVANT, nom)],
                           capture_output=True, text=True, check=True).stdout
    chemin = os.path.join(TRAVAIL, 'avant-' + nom)
    open(chemin, 'w', encoding='utf-8').write(texte)
    return chemin


def js(d):
    return "'%s'::jsonb" % json.dumps(d).replace("'", "''")


def q(t):
    return 'null' if t is None else "'%s'" % str(t).replace("'", "''")


def code(db, compte, texte):
    return S.Base.erreur(db, compte, texte)


def appel(db, fonction, periode='30j', debut=None, fin=None, extra='', compte=ADMIN):
    return jsonq(db, compte, "select public.%s(%s, %s, %s%s);" % (fonction, q(periode), q(debut), q(fin), extra))


def nulls(valeur, chemin=''):
    """Les chemins où une réponse porte NaN, Infinity ou une chaîne « undefined »."""
    trouves = []
    if isinstance(valeur, dict):
        for k, v in valeur.items():
            trouves += nulls(v, chemin + '.' + k)
    elif isinstance(valeur, list):
        for i, v in enumerate(valeur):
            trouves += nulls(v, chemin + '[%d]' % i)
    elif isinstance(valeur, float) and (valeur != valeur or valeur in (float('inf'), float('-inf'))):
        trouves.append(chemin)
    elif isinstance(valeur, str) and valeur.lower() in ('nan', 'infinity', '-infinity', 'undefined'):
        trouves.append(chemin)
    return trouves


def cles(valeur, chemin=''):
    if isinstance(valeur, dict):
        sortie = []
        for k in sorted(valeur):
            sortie.append(chemin + k)
            sortie += cles(valeur[k], chemin + k + '.')
        return sortie
    if isinstance(valeur, list) and valeur:
        return cles(valeur[0], chemin + '[].')
    return []


def comptes(db):
    for uid, email, nom, tel in ((ADMIN, 'equipe@goship.test', 'Ada Admin', ''),
                                 (GERANT, 'gerant@goship.test', 'Gaël Gérant', ''),
                                 (EMPLOYE, 'employe@goship.test', 'Emma Employée', ''),
                                 (MARIE, 'marie@exemple.com', 'Marie-Ange Dorvil', '+509 3712 4580'),
                                 (JEAN, 'jean@exemple.com', 'Jean Pierre', '+509 4420 1187'),
                                 (CARO, 'carolina@exemple.com', 'Carolina Méndez', '+1 809 555 0147')):
        db.sql("""insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
                  values ('%s', '%s', now(), '{"nom_complet":"%s","pays":"HT","telephone":"%s"}'::jsonb);"""
               % (uid, email, nom, tel))
    db.sql("select public.definir_admin('equipe@goship.test');")
    jsonq(db, ADMIN, "select public.changer_role('gerant@goship.test', 'gerant');")
    jsonq(db, ADMIN, "select public.changer_role('employe@goship.test', 'employe');")


def dater_colis(db, colis_id, reception, evenements):
    """Pose la réception et les dates des événements d'un colis, comme si le temps avait passé.
    evenements : {statut: 'AAAA-MM-JJ HH:MI'} (heure de Santo Domingo)."""
    sql = ["alter table colis disable trigger user;", "alter table colis_historique disable trigger user;",
           "update colis set recu_le = '%s'::timestamp at time zone 'America/Santo_Domingo' where id = '%s';"
           % (reception, colis_id),
           "update colis_historique set cree_le = '%s'::timestamp at time zone 'America/Santo_Domingo' "
           "where colis_id = '%s' and statut_precedent is null;" % (reception, colis_id)]
    for st, quand in evenements.items():
        sql.append("update colis_historique set cree_le = '%s'::timestamp at time zone 'America/Santo_Domingo' "
                   "where colis_id = '%s' and statut = '%s' and statut_precedent is distinct from '%s';"
                   % (quand, colis_id, st, st))
    sql += ["alter table colis enable trigger user;", "alter table colis_historique enable trigger user;"]
    db.sql('\n'.join(sql))


def dater(db, table, colonne, identifiant, quand):
    db.sql("alter table %s disable trigger user; update %s set %s = '%s'::timestamp at time zone "
           "'America/Santo_Domingo' where id = '%s'; alter table %s enable trigger user;"
           % (table, table, colonne, quand, identifiant, table))


def main():
    base = {'client_id': MARIE, 'description': 'Chaussures', 'poids_lb': 4, 'service': 'aerien',
            'pays_destination': 'HT', 'destination': 'Pétion-Ville'}

    print('A. Migration depuis la version publiée (%s)' % AVANT)
    db = S.Base()
    db.sql(S.DOUBLURES)
    for nom in FICHIERS:
        db.fichier(fichier_git(nom))
    comptes(db)
    creer(db, ADMIN, dict(base, description='Avant la Phase 8'))
    photo = ("select (select string_agg(numero || ':' || statut || ':' || prix_usd, '|' order by numero) from colis) || '#' ||"
             " (select string_agg(numero || ':' || montant_usd || ':' || statut, '|' order by numero) from factures) || '#' ||"
             " (select count(*) from colis_historique);")
    avant = un(db, photo)
    for f in NOUVEAUX + NOUVEAUX[::-1] + NOUVEAUX:
        db.fichier(f)
    verifier('les huit fichiers s\'installent par-dessus, trois fois, dans le désordre', 'oui', 'oui')
    verifier('aucune donnée n\'a bougé', un(db, photo), avant)
    verifier('contrôle de fin de fichier : 15 | 0 | vrai',
             un(db, "select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace "
                    "where n.nspname = 'public' and p.proname in ('bornes_analytics', 'comparer_valeurs', 'jour_sd', "
                    "'evenements_de_statut', 'analytics_mesures', 'creances_au', 'statistiques_durees', "
                    "'analytics_synthese', 'analytics_serie', 'analytics_operations', 'analytics_clients', "
                    "'analytics_finances', 'analytics_routes', 'analytics_scanner', 'analytics_qualite')) || '|' || "
                    "(select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' "
                    "and p.proname like 'analytics\\_%' and has_function_privilege('anon', p.oid, 'execute')) || '|' || "
                    "(select public.creances_au(now()) = coalesce(sum(public.solde_usd(f)), 0) from public.factures f);"),
             '15|0|true')

    print('\nB. Les permissions : reports.view, rien d\'autre')
    for m in MODULES:
        nom = m.split('(')[0]
        verifier('%s : administrateur et gérant' % nom,
                 (code(db, ADMIN, 'select public.%s;' % m), code(db, GERANT, 'select public.%s;' % m)), ('aucune', 'aucune'))
        verifier('%s : employée, client refusés' % nom,
                 (code(db, EMPLOYE, 'select public.%s;' % m), code(db, MARIE, 'select public.%s;' % m)), (REFUS, REFUS))
        verifier('%s : visiteur refusé' % nom, 'permission denied' in code(db, None, 'select public.%s;' % m), True)
    for f in ("analytics_mesures(now() - interval '1 day', now())", "creances_au(now())", "bornes_analytics('7j')",
              "evenements_de_statut(now() - interval '1 day', now())", "comparer_valeurs(1, 2)"):
        verifier('outil interne fermé, même à l\'administrateur (%s)' % f.split('(')[0],
                 'permission denied' in code(db, ADMIN, 'select * from public.%s;' % f), True)
    libres = un(db, "select coalesce(string_agg(p.proname, ',' order by p.proname), '') from pg_proc p "
                    "join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prosecdef "
                    "and p.prorettype <> 'trigger'::regtype and has_function_privilege('authenticated', p.oid, 'execute') "
                    "and p.prosrc !~ '(exiger_permission|peut\\(|auth\\.uid\\(\\))';")
    verifier('aucune fonction ouverte sans contrôle (hors suivi public)', libres, 'evenement_corrige,suivre_colis')
    verifier('RLS toujours active sur toutes les tables',
             un(db, "select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace "
                    "where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;"), '0')

    print('\nC. Les périodes et leur précédente (jours de Santo Domingo)')
    jour = un(db, "select public.aujourdhui();")
    for p in ('aujourdhui', '7j', '30j', 'mois', 'mois_precedent', 'annee'):
        verifier('« %s » : les jours du tableau de bord' % p,
                 un(db, "select jour_debut || ' ' || jour_fin from public.bornes_analytics('%s');" % p),
                 un(db, "select jour_debut || ' ' || jour_fin from public.bornes_periode('%s');" % p))
    b = lambda p, d=None, f=None: un(db, "select jour_debut || ' ' || jour_fin || ' | ' || prec_jour_debut || ' ' || prec_jour_fin "
                                         "from public.bornes_analytics(%s, %s, %s);" % (q(p), q(d) if d else 'null', q(f) if f else 'null'))
    verifier('aujourd\'hui ↔ hier', b('aujourdhui').split(' | ')[1],
             un(db, "select (public.aujourdhui() - 1) || ' ' || (public.aujourdhui() - 1);"))
    verifier('7 jours ↔ les 7 d\'avant', un(db, "select (prec_jour_fin - prec_jour_debut + 1) || ' ' || (jour_debut - prec_jour_fin) "
                                                "from public.bornes_analytics('7j');"), '7 1')
    verifier('personnalisée 10/03 → 20/03 ↔ 28/02 → 09/03', b('personnalise', '2026-03-10', '2026-03-20').split(' | ')[1],
             '2026-02-27 2026-03-09')
    verifier('ce mois (au 25) ↔ le mois précédent du 1er au 25',
             b('personnalise', '2026-09-01', '2026-09-25').split(' | ')[0], '2026-09-01 2026-09-25')
    verifier('mois : même jour du mois précédent',
             un(db, "select prec_jour_debut = (jour_debut - interval '1 month')::date and "
                    "prec_jour_fin = least((jour_fin - interval '1 month')::date, jour_debut - 1) "
                    "from public.bornes_analytics('mois');"), 't')
    verifier('mois précédent ↔ le mois d\'avant, entier',
             un(db, "select extract(day from prec_jour_debut) || ' ' || (prec_jour_fin + 1 = jour_debut) "
                    "from public.bornes_analytics('mois_precedent');"), '1 true')
    verifier('cette année ↔ l\'année précédente aux mêmes dates',
             un(db, "select prec_jour_debut = (jour_debut - interval '1 year')::date and "
                    "prec_jour_fin = (jour_fin - interval '1 year')::date from public.bornes_analytics('annee');"), 't')
    for p, mois in (('3m', 3), ('6m', 6), ('12m', 12)):
        verifier('%s : de J − %d mois + 1 à aujourd\'hui' % (p, mois),
                 un(db, "select jour_debut = (public.aujourdhui() - interval '%d months')::date + 1 and jour_fin = public.aujourdhui() "
                        "from public.bornes_analytics('%s');" % (mois, p)), 't')
    for (p, d, f), attendu in ((('personnalise', '2026-09-10', '2026-09-01'), 'INVALID_PERIOD'),
                               (('personnalise', '2020-01-01', '2026-09-01'), 'INVALID_PERIOD'),
                               (('personnalise', None, '2026-09-01'), 'INVALID_PERIOD'),
                               (('hier', None, None), 'INVALID_PERIOD')):
        verifier('période refusée : %s %s → %s' % (p, d, f), code(db, ADMIN, "select public.analytics_synthese(%s, %s, %s);"
                                                                   % (q(p), q(d), q(f))), attendu)
    verifier('découpage inconnu : refusé', code(db, ADMIN, "select public.analytics_serie('7j', null, null, 'heure');"),
             'INVALID_INPUT')

    print('\nD. Un jeu contrôlé : 10 colis en mars 2026')
    db = S.Base()
    db.sql(S.DOUBLURES)
    for f in NOUVEAUX:
        db.fichier(f)
    comptes(db)
    MARS = ('personnalise', '2026-03-01', '2026-03-31')
    FEV = ('personnalise', '2026-02-01', '2026-02-28')
    ids = []
    # 4 restent reçus, 2 embarqués, 2 disponibles, 2 livrés ; tous reçus le 2 mars à 8 h
    parcours = [[]] * 4 + [['embarque']] * 2 + [['embarque', 'distribution', 'succursale', 'disponible']] * 2 + \
               [['embarque', 'distribution', 'succursale', 'disponible', 'livre']] * 2
    for k, etapes in enumerate(parcours):
        c = creer(db, ADMIN, dict(base, client_id=[MARIE, JEAN, CARO][k % 3], description='Mars %d' % k,
                                  pays_destination='DO' if k % 3 == 2 else 'HT', service='maritime' if k == 9 else 'aerien',
                                  destination='Santiago' if k % 3 == 2 else 'Pétion-Ville'))['colis']
        ids.append(c['id'])
        for e in etapes:
            statut(db, ADMIN, [c['id']], e, 'Pétion-Ville' if e == 'disponible' else 'Miami')
        # Reçu le 2 mars 8 h ; embarqué le 3 à 8 h (+24 h) ; disponible le 5 à 8 h (+48 h) ; livré le 6 à 8 h (+24 h)
        dater_colis(db, c['id'], '2026-03-02 08:00', {'embarque': '2026-03-03 08:00', 'distribution': '2026-03-04 08:00',
                                                       'succursale': '2026-03-04 20:00', 'disponible': '2026-03-05 08:00',
                                                       'livre': '2026-03-06 08:00'})
    db.sql("alter table factures disable trigger user; update factures set cree_le = "
           "'2026-03-02 09:00'::timestamp at time zone 'America/Santo_Domingo'; alter table factures enable trigger user;")
    s = appel(db, 'analytics_synthese', *MARS)
    m = s['mesures']
    verifier('reçus en mars : 10', m['recus']['actuel'], 10)
    verifier('embarqués (expédiés) : 6, disponibles : 4, livrés : 2',
             (m['expedies']['actuel'], m['disponibles']['actuel'], m['livres']['actuel']), (6, 4, 2))
    verifier('statuts maintenant : 4 reçus, 2 embarqués, 2 disponibles, 2 livrés, total 10',
             (s['maintenant']['statuts']['recu'], s['maintenant']['statuts']['embarque'], s['maintenant']['statuts']['disponible'],
              s['maintenant']['statuts']['livre'], s['maintenant']['total']), (4, 2, 2, 2, 10))
    verifier('février : rien, et donc aucun pourcentage (pas d\'Infinity)',
             (m['recus']['precedent'], m['recus']['variation_pct'], m['recus']['tendance']), (0, None, 'hausse'))
    verifier('poids : 40 lb, poids moyen 4 lb', (m['poids']['actuel'], s['moyennes']['poids_moyen']), (40, 4))
    verifier('facturé en mars : 10 factures de 30 $', (m['factures_emises']['actuel'], m['facture']['actuel']), (10, 300))
    verifier('aucun NaN, Infinity ni undefined', nulls(s), [])
    f = appel(db, 'analytics_synthese', *FEV)
    verifier('vu de février : mars n\'existe pas encore (0 reçu)', f['mesures']['recus']['actuel'], 0)

    print('\nE. Les événements : délais et transitions')
    o = appel(db, 'analytics_operations', *MARS)
    d = o['durees']
    verifier('Reçu → Embarqué : 6 colis, 24 h', (d['reception_expedition']['nombre'], d['reception_expedition']['mediane_h']), (6, 24))
    verifier('Embarqué → Disponible : 4 colis, 48 h', (d['expedition_disponible']['nombre'], d['expedition_disponible']['moyenne_h']), (4, 48))
    verifier('Disponible → Livré : 2 colis, 24 h', (d['disponible_livraison']['nombre'], d['disponible_livraison']['maximum_h']), (2, 24))
    verifier('Reçu → Livré (total) : 2 colis, 96 h', (d['reception_livraison']['nombre'], d['reception_livraison']['minimum_h']), (2, 96))
    tr = {(t['de'], t['vers']): t for t in o['transitions']}
    verifier('transitions : Reçu → Embarqué × 6, en 24 h', (tr[('recu', 'embarque')]['nombre'], tr[('recu', 'embarque')]['mediane_h']), (6, 24))
    verifier('… Succursale → Disponible × 4, en 12 h',
             (tr[('succursale', 'disponible')]['nombre'], tr[('succursale', 'disponible')]['moyenne_h']), (4, 12))
    verifier('… Disponible → Livré × 2', tr[('disponible', 'livre')]['nombre'], 2)
    verifier('livraison : 2 livrés, cohorte 10 reçus, taux 20 %',
             (o['livraison']['livres'], o['livraison']['cohorte_recus'], o['livraison']['taux_cohorte']), (2, 10, 20))
    verifier('les 8 colis en cours : sans événement depuis plus de 7 jours',
             (o['sans_mouvement']['actifs'], o['sans_mouvement']['plus_de_7j']), (8, 8))
    verifier('aucune correction en mars', o['anomalies']['corrections'], 0)
    # Un colis livré par erreur, corrigé : sa livraison ne compte plus, la correction est une anomalie
    statut(db, ADMIN, [ids[8]], 'disponible', 'Pétion-Ville', motif='Livré par erreur')
    db.sql("alter table colis_historique disable trigger user; update colis_historique set cree_le = "
           "'2026-03-07 08:00'::timestamp at time zone 'America/Santo_Domingo' where type_evenement = 'CORRECTION'; "
           "alter table colis_historique enable trigger user;")
    o = appel(db, 'analytics_operations', *MARS)
    verifier('livraison corrigée : 1 livré, 1 correction, 1 retour en arrière',
             (o['livraison']['livres'], o['anomalies']['corrections'], o['durees']['reception_livraison']['nombre']), (1, 1, 1))
    verifier('le livré du tableau de bord suit la même règle',
             appel(db, 'analytics_synthese', *MARS)['mesures']['livres']['actuel'], 1)
    # Valeur extrême : un colis reçu le 1er mars, livré le 30 : gardé, et signalé
    x = creer(db, ADMIN, dict(base, description='Très long'))['colis']
    for e in ('embarque', 'distribution', 'succursale', 'disponible', 'livre'):
        statut(db, ADMIN, [x['id']], e, 'Pétion-Ville' if e == 'disponible' else 'Miami')
    dater_colis(db, x['id'], '2026-03-01 08:00', {'embarque': '2026-03-02 08:00', 'distribution': '2026-03-10 08:00',
                                                   'succursale': '2026-03-20 08:00', 'disponible': '2026-03-28 08:00',
                                                   'livre': '2026-03-30 08:00'})
    for k in range(4):
        y = creer(db, ADMIN, dict(base, description='Normal %d' % k))['colis']
        statut(db, ADMIN, [y['id']], 'embarque', 'Miami')
        dater_colis(db, y['id'], '2026-03-10 08:00', {'embarque': '2026-03-11 08:00'})
    o = appel(db, 'analytics_operations', *MARS)
    re = o['durees']['reception_expedition']
    verifier('valeur extrême gardée : maximum 24 h, et comptée à part (0 ici)', (re['nombre'], re['maximum_h']), (11, 24))
    rl = o['durees']['reception_livraison']
    verifier('Reçu → Livré : 29 jours gardés dans le maximum', (rl['nombre'], rl['maximum_h']), (2, 696))
    # Action requise : entrée le 12 mars, sortie le 14 : 48 h, note gardée telle quelle
    z = creer(db, ADMIN, dict(base, client_id=JEAN, description='Adresse'))['colis']
    statut(db, ADMIN, [z['id']], 'incident', 'Miami', note='Adresse incomplète')
    statut(db, ADMIN, [z['id']], 'recu', 'Miami')
    db.sql("alter table colis_historique disable trigger user;"
           "update colis_historique set cree_le = '2026-03-12 10:00'::timestamp at time zone 'America/Santo_Domingo' "
           "where colis_id = '%s' and statut = 'incident';"
           "update colis_historique set cree_le = '2026-03-14 10:00'::timestamp at time zone 'America/Santo_Domingo' "
           "where colis_id = '%s' and statut_precedent = 'incident';"
           "alter table colis_historique enable trigger user;" % (z['id'], z['id']))
    ar = appel(db, 'analytics_operations', *MARS)['action_requise']
    verifier('action requise : 1 entrée, 1 client, épisode de 48 h',
             (ar['entrees']['actuel'], ar['clients'], ar['duree_episodes']['moyenne_h']), (1, 1, 48))
    verifier('… la note la plus fréquente, sans cause inventée',
             (ar['notes'][0]['note'], ar['cause_structuree']), ('Adresse incomplète', False))

    print('\nF. Les finances : facturé, encaissé, solde')
    fa = jsonq(db, ADMIN, "select public.creer_facture('%s', null, %s);" % (CARO, js({'montant_usd': 75})))['facture']
    dater(db, 'factures', 'cree_le', fa['id'], '2026-03-15 10:00')
    p1 = jsonq(db, ADMIN, "select public.enregistrer_paiement('%s', %s);" % (fa['id'], js({'montant_usd': 25, 'moyen': 'especes', 'paye_le': '2026-03-16T10:00:00-04:00'})))
    fin = appel(db, 'analytics_finances', *MARS)
    verifier('facture de 75 $ payée 25 : facturé + 75, encaissé 25, reste 50 sur elle',
             (fin['facture']['actuel'] - 300, fin['encaisse']['actuel'], fin['reste']['actuel'] - 300), (75, 25, 50))
    jsonq(db, ADMIN, "select public.enregistrer_paiement('%s', %s);" % (fa['id'], js({'montant_usd': 50, 'moyen': 'moncash', 'paye_le': '2026-03-20T10:00:00-04:00'})))
    fin = appel(db, 'analytics_finances', *MARS)
    verifier('… puis 50 : encaissé 75, reste 0 sur elle', (fin['encaisse']['actuel'], fin['reste']['actuel'] - 300), (75, 0))
    verifier('encaissé par moyen : espèces 25, MonCash 50',
             sorted((x['moyen'], x['montant']) for x in fin['par_moyen']), [('especes', 25), ('moncash', 50)])
    verifier('créances maintenant = somme des solde_usd',
             fin['creances']['total'], float(un(db, "select sum(public.solde_usd(f)) from factures f;")))
    verifier('… = « à encaisser » du tableau de bord', fin['creances']['total'],
             jsonq(db, ADMIN, "select public.vue_generale('30j');")['facturation']['a_encaisser'])
    verifier('créances au 15 mars 12 h (après la facture, avant le paiement) : 300 + 75',
             float(un(db, "select public.creances_au('2026-03-15 12:00'::timestamp at time zone 'America/Santo_Domingo');")), 375)
    verifier('créances au 17 mars : − 25', float(un(db, "select public.creances_au('2026-03-17 00:00'::timestamp at time zone 'America/Santo_Domingo');")), 350)
    se = appel(db, 'analytics_serie', *MARS, extra=", 'jour'")
    jours = {c['jour']: c for c in se['cases']}
    verifier('série : 31 jours, facture du 15 et encaissé du 16', (len(se['cases']), jours['2026-03-15']['facture'], jours['2026-03-16']['encaisse']), (31, 75, 25))
    verifier('série : dû en fin de 15, 16, 20', (jours['2026-03-15']['creances_fin'], jours['2026-03-16']['creances_fin'],
                                               jours['2026-03-20']['creances_fin']), (375, 350, 300))
    verifier('série : la somme des jours = le total (reçus, facturé, encaissé)',
             (sum(c['recus'] for c in se['cases']), sum(c['facture'] for c in se['cases']), sum(c['encaisse'] for c in se['cases'])),
             (appel(db, 'analytics_synthese', *MARS)['mesures']['recus']['actuel'], fin['facture']['actuel'], fin['encaisse']['actuel']))
    sm = appel(db, 'analytics_serie', *MARS, extra=", 'semaine'")
    verifier('par semaine (du lundi) : première case le lundi 23 février, commencée le 1er mars',
             (sm['cases'][0]['jour'], sm['cases'][0]['debut']), ('2026-02-23', '2026-03-01'))
    mo = appel(db, 'analytics_serie', 'personnalise', '2026-01-01', '2026-03-31', ", 'mois'")
    verifier('par mois : 3 cases, et mars porte les colis de mars', ([c['jour'] for c in mo['cases']], mo['cases'][2]['recus']),
             (['2026-01-01', '2026-02-01', '2026-03-01'], appel(db, 'analytics_synthese', *MARS)['mesures']['recus']['actuel']))
    verifier('dépenses, dettes, résultat : non suivis, sans chiffre',
             (fin['depenses'], fin['dettes'], fin['resultat']), ({'suivi': False}, {'suivi': False}, {'suivi': False}))
    # Une facture en retard, une non échue : âge et échéances réels
    ret = jsonq(db, ADMIN, "select public.creer_facture('%s', null, %s);" % (JEAN, js({'montant_usd': 12})))['facture']['id']
    db.comme(ADMIN, "update factures set echeance_le = public.aujourdhui() - 1 where id = '%s';" % ret)
    fin = appel(db, 'analytics_finances', *MARS)
    verifier('une facture échue : en retard, 12 $', (fin['creances']['en_retard'], fin['creances']['montant_en_retard']), (1, 12))
    verifier('âge des créances : les quatre tranches font le total',
             (sum(t['factures'] for t in fin['creances']['age']), round(sum(t['montant'] for t in fin['creances']['age']), 2)),
             (fin['creances']['factures'], fin['creances']['total']))

    print('\nG. Le tarif historique : 3 $/lb reste 3 $/lb')
    ancien = creer(db, ADMIN, dict(base, client_id=JEAN, description='Ancien tarif', tarif_lb_usd=3, poids_lb=10))
    ligne = ancien['facture']['id']
    dater(db, 'factures', 'cree_le', ligne, '2026-03-25 10:00')
    avant = appel(db, 'analytics_finances', *MARS)['facture']['actuel']
    verifier('colis à 3 $/lb : 30 $ + 10 $ de frais', ancien['facture']['montant_usd'], 40)
    nouveau = creer(db, ADMIN, dict(base, client_id=JEAN, description='Nouveau tarif', tarif_lb_usd=4, poids_lb=10))
    verifier('le suivant à 4 $/lb : 40 $ + 10 $', nouveau['facture']['montant_usd'], 50)
    jsonq(db, ADMIN, "select public.modifier_colis('%s', '{\"tarif_lb_usd\":4}'::jsonb);" % ancien['colis']['id'])
    verifier('le tarif de l\'ancien colis change après coup : sa facture et les analytics de mars, non',
             (float(un(db, "select montant_usd from factures where id = '%s';" % ligne)),
              appel(db, 'analytics_finances', *MARS)['facture']['actuel']), (40, avant))

    print('\nH. Frontières de dates (Santo Domingo)')
    for quand, jour_attendu in (('2026-03-31T23:59:00-04:00', 'mars'), ('2026-04-01T00:00:00-04:00', 'avril'),
                                ('2025-12-31T23:59:00-04:00', '2025'), ('2026-01-01T00:00:00-04:00', '2026')):
        fb = jsonq(db, ADMIN, "select public.creer_facture('%s', null, %s);" % (MARIE, js({'montant_usd': 1})))['facture']['id']
        jsonq(db, ADMIN, "select public.enregistrer_paiement('%s', %s);" % (fb, js({'montant_usd': 1, 'moyen': 'especes', 'paye_le': quand})))
    enc = lambda d, f: appel(db, 'analytics_finances', 'personnalise', d, f)['encaisse']['actuel']
    verifier('payé le 31 mars à 23 h 59 : en mars ; le 1er avril à minuit : en avril',
             (enc('2026-03-31', '2026-03-31') - 0, enc('2026-04-01', '2026-04-01')), (1, 1))
    verifier('31 décembre 23 h 59 : en 2025 ; 1er janvier minuit : en 2026',
             (enc('2025-12-31', '2025-12-31'), enc('2026-01-01', '2026-01-01')), (1, 1))
    verifier('mars entier : les paiements de mars seulement (25 + 50 + 1)', enc('2026-03-01', '2026-03-31'), 76)

    print('\nI. Clients, routes, scanner, qualité')
    cl = appel(db, 'analytics_clients', *MARS)
    verifier('clients actifs en mars : 3 (un colis reçu au moins), inactifs 0',
             (cl['actifs']['actuel'], cl['inactifs'], cl['total_fin']), (3, 0, 3))
    verifier('segments : définitions affichées, clients comptés une fois',
             (sum(x['clients'] for x in cl['segments']), cl['segments'][0]['definition']), (3, '1 colis sur la période'))
    verifier('colis par client actif = colis reçus ÷ actifs', cl['colis_par_client_actif'],
             round(appel(db, 'analytics_synthese', *MARS)['mesures']['recus']['actuel'] / 3, 2))
    tri = [x['colis'] for x in appel(db, 'analytics_clients', *MARS, extra=", 'colis'")['lignes']]
    verifier('triés par colis, décroissant', tri, sorted(tri, reverse=True))
    verifier('par solde, une page de 1', len(appel(db, 'analytics_clients', *MARS, extra=", 'solde', 1, 0")['lignes']), 1)
    verifier('tri inconnu : refusé', code(db, ADMIN, "select public.analytics_clients('30j', null, null, 'age');"), 'INVALID_INPUT')
    ro = appel(db, 'analytics_routes', *MARS)
    routes = {(r['pays'], r['service']): r for r in ro['routes']}
    verifier('routes réelles seulement : Miami → HT aérien, HT maritime, DO aérien', sorted(routes), [('DO', 'aerien'), ('HT', 'aerien'), ('HT', 'maritime')])
    verifier('une seule origine, dite telle quelle', (ro['origine'], ro['origines_distinctes']), ('Miami (Medley), FL', 1))
    verifier('DO aérien : 3 colis, 12 lb, 60 $ de transport facturé', (routes[('DO', 'aerien')]['colis'], routes[('DO', 'aerien')]['poids'],
                                                                      routes[('DO', 'aerien')]['facture']), (3, 12, 60))
    verifier('villes : Santiago (3) parmi les destinations', {v['ville']: v['colis'] for v in ro['villes']}.get('Santiago'), 3)
    sc = appel(db, 'analytics_scanner', 'aujourdhui')
    verifier('aucun scan : 0, et les échecs non suivis', (sc['total']['actuel'], sc['echecs_suivis']), (0, False))
    for qui, num in ((EMPLOYE, 'GSE-1001-HT'), (GERANT, 'GSE-1002-HT'), (EMPLOYE, 'GSE-1004-HT')):
        jsonq(db, qui, "select public.scanner_operation('%s', 'COLIS_INSPECTE', 'Miami (Medley), FL');" % num)
    sc = appel(db, 'analytics_scanner', 'aujourdhui')
    verifier('3 opérations, 3 colis, 1 lieu', (sc['total']['actuel'], sc['colis'], sc['par_lieu'][0]['nombre']), (3, 3, 3))
    verifier('par compte : ordre alphabétique, jamais un classement',
             [x['nom'] for x in sc['par_compte']], ['Emma Employée', 'Gaël Gérant'])
    verifier('= le tableau de bord, même jour', sc['total']['actuel'],
             jsonq(db, ADMIN, "select public.vue_generale('aujourdhui');")['scanner']['periode'])
    ql = jsonq(db, ADMIN, "select public.analytics_qualite();")
    ind = {i['code']: i for i in ql['indicateurs']}
    verifier('qualité : tous les colis ont leur réception', ind['colis_historique_complet']['ok'], ind['colis_historique_complet']['total'])
    verifier('qualité : statuts cohérents avec le dernier événement', ind['colis_historique_coherent']['ok'], ind['colis_historique_coherent']['total'])
    db.sql("alter table colis disable trigger user; insert into colis (numero, client_id, description) "
           "values ('GSE-9999-HT', '%s', 'Sans événement'); alter table colis enable trigger user;" % MARIE)
    db.sql("alter table colis_historique disable trigger user; insert into colis_historique (colis_id, statut) "
           "select id, 'livre' from colis where numero = 'GSE-1001-HT'; alter table colis_historique enable trigger user;")
    an = {a['code']: a['nombre'] for a in jsonq(db, ADMIN, "select public.analytics_qualite();")['anomalies']}
    verifier('un colis sans événement : signalé, pas caché', an['colis_sans_evenement'], 1)
    verifier('un événement sans compte (écrit hors du moteur) : signalé', an['evenements_sans_auteur'], 1)
    verifier('… et l\'historique de GSE-1001-HT devient incohérent', an['colis_statut_incoherent'], 1)
    verifier('le rapport de facturation de la Phase 5, repris par type',
             all('type' in x and 'nombre' in x for x in jsonq(db, ADMIN, "select public.analytics_qualite();")['facturation']), True)

    print('\nJ. Cohérence avec le tableau de bord')
    v = jsonq(db, ADMIN, "select public.vue_generale('30j');")
    s = appel(db, 'analytics_synthese', '30j')
    verifier('30 jours : reçus, livrés, facturé, encaissé identiques',
             (s['mesures']['recus']['actuel'], s['mesures']['livres']['actuel'], s['mesures']['facture']['actuel'],
              s['mesures']['encaisse']['actuel']),
             (v['colis']['recus_periode'], v['colis']['livres_periode'], v['facturation']['facture_periode'],
              v['facturation']['encaisse_periode']))
    verifier('les huit statuts de maintenant identiques', s['maintenant']['statuts'], v['colis']['statuts'])
    verifier('les créances de fin de période = « à encaisser »', s['creances_fin']['actuel'], v['facturation']['a_encaisser'])
    verifier('aucune réponse avec NaN / Infinity / undefined',
             [m for m in MODULES if nulls(jsonq(db, ADMIN, 'select public.%s;' % m))], [])

    print('\nK. Volume : 10 000 colis, 100 000 événements, 5 000 factures')
    db.sql("alter table colis disable trigger user; alter table colis_historique disable trigger user;"
           "alter table factures disable trigger user; alter table paiements disable trigger user;"
           "insert into colis (numero, client_id, description, poids_lb, prix_usd, statut, recu_le, pays_destination, service, destination) "
           "select 'GSE-' || (60000 + g) || '-HT', (array['%s','%s','%s'])[1 + g %% 3]::uuid, 'Masse', 1 + g %% 9, 5 * (1 + g %% 9), "
           "(array['recu','embarque','disponible','livre'])[1 + g %% 4], now() - (g %% 360) * interval '1 day', "
           "(array['HT','DO','US'])[1 + g %% 3], (array['aerien','maritime'])[1 + g %% 2], (array['Jacmel','Cap-Haïtien','Santiago'])[1 + g %% 3] "
           "from generate_series(1, 10000) g;"
           "insert into colis_historique (colis_id, statut, statut_precedent, type_evenement, auteur_id, metadonnees, cree_le) "
           "select c.id, s.statut, s.prec, s.type, '%s', case when k %% 2 = 0 then '{\"source\":\"scanner\"}'::jsonb else '{}'::jsonb end, "
           "c.recu_le + k * interval '9 hours' from colis c, generate_series(1, 10) k, "
           "lateral (select (array['recu','emballe','embarque','distribution','succursale','disponible','livre','livre','livre','livre'])[k] as statut, "
           "(array[null,'recu','emballe','embarque','distribution','succursale','disponible','livre','livre','livre'])[k] as prec, "
           "(array['COLIS_RECU','COLIS_EMBALLE','COLIS_EXPEDIE','COLIS_ARRIVE','COLIS_TRANSFERE','COLIS_DISPONIBLE','COLIS_LIVRE','MISE_A_JOUR','MISE_A_JOUR','MISE_A_JOUR'])[k] as type) s "
           "where c.description = 'Masse';"
           "insert into factures (numero, client_id, montant_usd, frais_service_usd, statut, cree_le) "
           "select 'M-' || g, (array['%s','%s','%s'])[1 + g %% 3]::uuid, 20 + g %% 30, 10, 'a_payer', now() - (g %% 360) * interval '1 day' "
           "from generate_series(1, 5000) g;"
           "insert into paiements (facture_id, client_id, montant_usd, moyen, paye_le) "
           "select id, client_id, 5, 'especes', least(cree_le + interval '2 days', now()) from factures where numero like 'M-%%';"
           "alter table colis enable trigger user; alter table colis_historique enable trigger user;"
           "alter table factures enable trigger user; alter table paiements enable trigger user; analyze;"
           % (MARIE, JEAN, CARO, ADMIN, MARIE, JEAN, CARO))
    verifier('volume en place', un(db, "select (select count(*) from colis) >= 10000 and (select count(*) from colis_historique) >= 100000;"), 't')
    for m in ("analytics_synthese('12m')", "analytics_serie('12m', null, null, 'jour')", "analytics_serie('12m', null, null, 'semaine')",
              "analytics_operations('12m')", "analytics_clients('12m')", "analytics_finances('12m')", "analytics_routes('12m')",
              "analytics_scanner('12m')", "analytics_qualite()"):
        debut = time.time()
        r = jsonq(db, ADMIN, 'select public.%s;' % m)
        duree = time.time() - debut
        verifier('%s : %.2f s (< 3 s), sans NaN' % (m, duree), duree < 3 and not nulls(r), True)
    s = appel(db, 'analytics_synthese', '12m')
    verifier('12 mois : les reçus = count(*) de la table', s['mesures']['recus']['actuel'],
             int(un(db, "select count(*) from colis where recu_le >= (select debut from public.bornes_analytics('12m')) "
                        "and recu_le < (select fin from public.bornes_analytics('12m'));")))
    se = appel(db, 'analytics_serie', '12m', extra=", 'mois'")
    verifier('12 mois par mois : la somme des cases = le total', sum(c['recus'] for c in se['cases']), s['mesures']['recus']['actuel'])
    verifier('les créances reconstituées finissent sur « à encaisser »', se['cases'][-1]['creances_fin'],
             jsonq(db, ADMIN, "select public.vue_generale('30j');")['facturation']['a_encaisser'])

    print('\nL. La démonstration a la même forme')
    # Une « action requise » avec sa note, pour que chaque liste ait de quoi montrer sa forme
    statut(db, ADMIN, [un(db, "select id from colis where numero = 'GSE-1004-HT';")], 'incident', 'Miami', note='Essai de forme')
    demo = json.loads(subprocess.run(['node', os.path.join(ICI, 'essai-analytics.js'), '--formes'],
                                     capture_output=True, text=True, check=True).stdout)
    for nom, sql in (('synthese', "analytics_synthese('30j')"), ('serie', "analytics_serie('30j')"),
                     ('operations', "analytics_operations('30j')"), ('clients', "analytics_clients('30j')"),
                     ('finances', "analytics_finances('30j')"), ('routes', "analytics_routes('30j')"),
                     ('scanner', "analytics_scanner('30j')"), ('qualite', 'analytics_qualite()')):
        forme = set(cles(jsonq(db, ADMIN, 'select public.%s;' % sql)))
        verifier('%s : mêmes clés côté démo' % nom, sorted(set(demo[nom]) ^ forme), [])
    periodes = json.loads(subprocess.run(['node', os.path.join(ICI, 'essai-analytics.js'), '--periodes'],
                                         capture_output=True, text=True, check=True).stdout)
    for p, jours in periodes.items():
        verifier('période « %s » : mêmes jours, même précédente' % p, jours,
                 un(db, "select jour_debut || ' ' || jour_fin || ' ' || prec_jour_debut || ' ' || prec_jour_fin "
                        "from public.bornes_analytics('%s');" % p).split())

    n = sum(S.RESULTATS)
    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), n))
    sys.exit(0 if n == len(S.RESULTATS) else 1)


if __name__ == '__main__':
    main()
