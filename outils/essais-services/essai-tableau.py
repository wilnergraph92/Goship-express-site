# -*- coding: utf-8 -*-
"""Éprouve le tableau de bord opérationnel (Phase 7, outils/supabase-tableau-de-bord.sql).

Même base jetable et mêmes rôles SQL que essai-services.py. On vérifie que
chaque chiffre du tableau de bord est celui des tables, quel que soit le
volume ; que chaque rôle ne reçoit que les parties que ses permissions
ouvrent ; que les périodes se comptent en jours de Santo Domingo ; qu'un scan
se voit aussitôt dans les chiffres ; que la recherche rapide trouve par les
index et ne liste jamais tout.

Depuis la racine du site :

    python3 outils/essais-services/essai-tableau.py
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
ADMIN, MARIE, JEAN = S.ADMIN, S.MARIE, S.JEAN
GERANT = 'bbbbbbbb-0000-0000-0000-00000000000b'
EMPLOYE = 'cccccccc-0000-0000-0000-00000000000c'
CARO = '33333333-3333-3333-3333-333333333333'
verifier, jsonq, creer, statut, un = S.verifier, S.jsonq, S.creer, S.statut, S.un

# La version publiée avant la Phase 7
AVANT = os.environ.get('GOSHIP_AVANT', '0013d13')
FICHIERS = ('supabase.sql', 'supabase-facturation.sql', 'supabase-services.sql', 'supabase-evenements.sql',
            'supabase-scanner.sql', 'supabase-finances.sql')
NOUVEAUX = [os.path.join(RACINE, 'outils', f) for f in FICHIERS + ('supabase-tableau-de-bord.sql',)]
REFUS = 'PERMISSION_DENIED'
SECTIONS = ['activite', 'alertes', 'clients', 'colis', 'facturation', 'genere_le', 'jours_sans_mouvement',
            'paiements_recents', 'periode', 'scanner']


def fichier_git(nom):
    texte = subprocess.run(['git', '-C', RACINE, 'show', '%s:outils/%s' % (AVANT, nom)],
                           capture_output=True, text=True, check=True).stdout
    chemin = os.path.join(TRAVAIL, 'avant-' + nom)
    open(chemin, 'w', encoding='utf-8').write(texte)
    return chemin


def js(d):
    return "'%s'::jsonb" % json.dumps(d).replace("'", "''")


def q(t):
    return "'%s'" % t.replace("'", "''")


def vue(db, compte=ADMIN, periode='30j', debut=None, fin=None, jours=7):
    return jsonq(db, compte, "select public.vue_generale(%s, %s, %s, %d);"
                 % (q(periode), q(debut) if debut else 'null', q(fin) if fin else 'null', jours))


def cherche(db, texte, compte=ADMIN):
    return jsonq(db, compte, "select public.recherche_rapide(%s);" % q(texte))


def code(db, compte, texte):
    return S.Base.erreur(db, compte, texte)


def nulls(valeur, chemin=''):
    """Les chemins où la vue générale rend null : seuls « dernier » (aucun scan) est permis."""
    trouves = []
    if isinstance(valeur, dict):
        for k, v in valeur.items():
            trouves += nulls(v, chemin + '.' + k)
    elif isinstance(valeur, list):
        for i, v in enumerate(valeur[:3]):
            trouves += nulls(v, chemin + '[%d]' % i)
    elif valeur is None:
        trouves.append(chemin)
    return trouves


def cles(valeur, chemin=''):
    """La forme d'une réponse : ses clés, récursivement (listes : le premier élément)."""
    if isinstance(valeur, dict):
        sortie = []
        for k in sorted(valeur):
            sortie.append(chemin + k)
            # Le contenu libre (précisions d'un événement, statuts d'un client) varie d'une ligne à l'autre
            if k == 'metadonnees' or (k == 'statuts' and '[]' in chemin):
                continue
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


def main():
    base = {'client_id': MARIE, 'description': 'Chaussures', 'poids_lb': 4, 'service': 'aerien',
            'pays_destination': 'HT', 'destination': 'Pétion-Ville'}

    print('A. Une base vide : des zéros, jamais rien d\'inventé')
    db = S.Base()
    db.sql(S.DOUBLURES)
    for f in NOUVEAUX:
        db.fichier(f)
    comptes(db)
    v = vue(db)
    verifier('toutes les parties pour l\'administrateur', sorted(v), SECTIONS)
    verifier('0 colis, 0 reçu, 0 livré, 0 sans mouvement',
             [v['colis'][k] for k in ('total', 'actifs', 'recus_periode', 'livres_periode', 'sans_mouvement')],
             [0, 0, 0, 0, 0])
    verifier('les huit statuts, tous à 0', v['colis']['statuts'],
             {s: 0 for s in ('recu', 'emballe', 'embarque', 'distribution', 'succursale', 'disponible', 'livre', 'incident')})
    verifier('0 facturé, 0 encaissé, 0 à encaisser',
             [v['facturation'][k] for k in ('facture_periode', 'encaisse_periode', 'a_encaisser')], [0, 0, 0])
    verifier('30 jours dans la courbe, tous à zéro',
             (len(v['colis']['par_jour']), sum(j['recus'] + j['livres'] for j in v['colis']['par_jour'])), (30, 0))
    verifier('aucune alerte', v['alertes'], [])
    verifier('aucun scan, aucune activité, aucun paiement',
             (v['scanner']['periode'], v['scanner']['dernier'], v['activite'], v['paiements_recents']), (0, None, [], []))
    verifier('aucune valeur vide ailleurs que « dernier scan »', nulls(v), ['.scanner.dernier'])
    verifier('les scans échoués ne sont pas suivis : dit tel quel', v['scanner']['echecs_suivis'], False)
    verifier('les dépenses et dettes n\'existent pas : aucune case',
             [k for k in ('depenses', 'dettes', 'resultat') if k in v['facturation']], [])
    r = cherche(db, 'GSE-1001')
    verifier('recherche dans une base vide : trois listes vides', (r['colis'], r['clients'], r['factures']), ([], [], []))
    verifier('mon résumé (client sans rien)', jsonq(db, MARIE, "select public.mon_resume();")['factures']['solde_usd'], 0)
    forme_vide = cles(v)

    print('\nB. Migration depuis la version publiée (%s)' % AVANT)
    db = S.Base()
    db.sql(S.DOUBLURES)
    for nom in FICHIERS:
        db.fichier(fichier_git(nom))
    comptes(db)
    c1 = creer(db, ADMIN, dict(base, description='Colis de Marie', suivi_transporteur='TBA304918577000'))
    creer(db, ADMIN, dict(base, client_id=JEAN, description='Colis de Jean'))
    photo = ("select (select string_agg(numero || ':' || statut || ':' || prix_usd, '|' order by numero) from colis) || '#' ||"
             " (select string_agg(numero || ':' || montant_usd || ':' || statut, '|' order by numero) from factures) || '#' ||"
             " (select count(*) from colis_historique) || '#' || (select string_agg(id || role, '|' order by id) from clients);")
    avant = un(db, photo)
    for f in NOUVEAUX + NOUVEAUX[::-1] + NOUVEAUX:
        db.fichier(f)
    verifier('les sept fichiers s\'installent par-dessus, trois fois, dans le désordre', 'oui', 'oui')
    verifier('aucune donnée n\'a bougé', un(db, photo), avant)
    verifier('contrôle de fin de fichier : 12 | 8 | 0',
             un(db, "select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace "
                    "where n.nspname = 'public' and p.proname in ('bornes_periode', 'tableau_colis', 'tableau_clients', "
                    "'tableau_facturation', 'tableau_scanner', 'tableau_activite', 'tableau_paiements', 'vue_generale', "
                    "'colis_a_traiter', 'recherche_rapide', 'clients_soldes', 'mon_resume')) || '|' || "
                    "(select count(*) from pg_indexes where indexname like any (array['colis_numero_debut_idx', "
                    "'factures_numero_debut_idx', 'clients_nom_mots_idx', 'clients_telephone_fin_idx', "
                    "'clients_email_debut_idx', 'clients_inscription_idx', 'colis_historique_scanner_idx', "
                    "'factures_creation_idx']));"), '12|8')
    verifier('même forme de réponse, base vide ou non', cles(vue(db)) == forme_vide or
             set(forme_vide) <= set(cles(vue(db))), True)

    print('\nC. Chaque rôle, sa part')
    attendu = {
        ADMIN: SECTIONS,
        GERANT: SECTIONS,
        EMPLOYE: [s for s in SECTIONS if s != 'facturation'],
    }
    for qui, nom in ((ADMIN, 'administrateur'), (GERANT, 'gérant'), (EMPLOYE, 'employée')):
        verifier('%s : %s' % (nom, 'tout' if qui != EMPLOYE else 'tout sauf la facturation'),
                 sorted(vue(db, qui)), attendu[qui])
    verifier('employée : aucune alerte de facturation (reports.view)',
             [a['code'] for a in vue(db, EMPLOYE)['alertes'] if a['code'] == 'factures_en_retard'], [])
    for texte, nom in (("select public.vue_generale();", 'vue générale'),
                       ("select public.colis_a_traiter('action_requise');", 'colis à traiter'),
                       ("select public.recherche_rapide('GSE-1001-HT');", 'recherche rapide'),
                       ("select public.clients_soldes();", 'clients et soldes')):
        verifier('client → %s : refusé' % nom, code(db, MARIE, texte), REFUS)
        verifier('visiteur → %s : refusé' % nom, 'permission denied' in code(db, None, texte), True)
    for f in ("tableau_colis(now(), now(), current_date, current_date, 7)", "tableau_facturation(now(), now(), current_date, current_date)",
              "tableau_paiements(5)", "tableau_activite(5)", "bornes_periode('7j')"):
        verifier('une partie appelée seule, même par l\'administrateur : fermée (%s)' % f.split('(')[0],
                 'permission denied' in code(db, ADMIN, 'select public.%s;' % f), True)
    libres = un(db, "select coalesce(string_agg(p.proname, ',' order by p.proname), '') from pg_proc p "
                    "join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prosecdef "
                    "and p.prorettype <> 'trigger'::regtype and has_function_privilege('authenticated', p.oid, 'execute') "
                    "and p.prosrc !~ '(exiger_permission|peut\\(|auth\\.uid\\(\\))';")
    verifier('toujours aucune fonction ouverte sans contrôle (hors suivi public)', libres, 'evenement_corrige,suivre_colis')
    verifier('toute fonction « security definer » a son search_path',
             un(db, "select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace "
                    "where n.nspname = 'public' and p.prosecdef and not exists "
                    "(select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%');"), '0')
    verifier('RLS toujours active sur toutes les tables',
             un(db, "select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace "
                    "where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;"), '0')
    m = jsonq(db, MARIE, "select public.mon_resume();")
    verifier('mon résumé : Marie voit ses colis et sa facture, pas ceux de Jean',
             (m['colis']['en_cours'], m['factures']['nombre'], m['factures']['solde_usd']), (1, 1, 30))
    verifier('mon résumé : un visiteur est refusé', 'PERMISSION_DENIED' in code(db, None, "select public.mon_resume();")
             or 'permission denied' in code(db, None, "select public.mon_resume();"), True)
    db.sql("insert into notifications (colis_id, canal, evenement, destinataire) values ('%s', 'email', 'recu', 'marie@exemple.com');"
           % c1['colis']['id'])
    db.sql("insert into notifications (client_id, canal, evenement, destinataire) values ('%s', 'email', 'bienvenue', 'x');" % MARIE)
    db.sql("insert into notifications (client_id, colis_id, canal, evenement, destinataire) values ('%s', '%s', 'push', 'maj', 'x');"
           % (MARIE, c1['colis']['id']))
    db.sql("insert into notifications (client_id, canal, evenement, destinataire) values ('%s', 'email', 'bienvenue', 'x');" % JEAN)
    n = jsonq(db, MARIE, "select public.mon_resume();")['notifications']
    verifier('ses messages : trois, sans doublon, sans ceux de Jean',
             sorted(x['evenement'] for x in n), ['bienvenue', 'maj', 'recu'])
    verifier('… avec le numéro du colis quand il y en a un',
             sorted(x['numero'] or '-' for x in n), ['-', 'GSE-1001-HT', 'GSE-1001-HT'])
    verifier('… sans l\'adresse ni le numéro où ils sont partis', 'destinataire' in json.dumps(n), False)

    print('\nD. Les périodes, en jours de Santo Domingo')
    jour = un(db, "select public.aujourdhui();")
    bornes = {}
    for p in ('aujourdhui', '7j', '30j', 'mois', 'mois_precedent', 'annee'):
        bornes[p] = un(db, "select jour_debut || ' ' || jour_fin || ' ' || (debut at time zone 'America/Santo_Domingo')::time "
                           "from public.bornes_periode('%s');" % p)
    y, mo, d = (int(x) for x in jour.split('-'))
    verifier('aujourd\'hui : de minuit à minuit, heure de Santo Domingo', bornes['aujourdhui'], '%s %s 00:00:00' % (jour, jour))
    verifier('ce mois : depuis le 1er', bornes['mois'].split()[0], '%04d-%02d-01' % (y, mo))
    verifier('cette année : depuis le 1er janvier', bornes['annee'].split()[0], '%04d-01-01' % y)
    pm = (y, mo - 1) if mo > 1 else (y - 1, 12)
    verifier('mois précédent : du 1er au dernier jour', bornes['mois_precedent'].split()[0], '%04d-%02d-01' % pm)
    verifier('… qui finit la veille du 1er de ce mois',
             un(db, "select jour_fin + 1 = date_trunc('month', public.aujourdhui())::date from public.bornes_periode('mois_precedent');"), 't')
    verifier('7 jours et 30 jours : aujourd\'hui compris',
             (len(vue(db, periode='7j')['colis']['par_jour']), len(vue(db, periode='30j')['colis']['par_jour'])), (7, 30))
    for (p, debut, fin), attendu in ((('personnalise', '2026-09-10', '2026-09-01'), 'INVALID_PERIOD'),
                                     (('personnalise', '2025-01-01', '2026-09-01'), 'INVALID_PERIOD'),
                                     (('personnalise', None, '2026-09-01'), 'INVALID_PERIOD'),
                                     (('hier', None, None), 'INVALID_PERIOD')):
        verifier('période refusée : %s %s→%s' % (p, debut, fin),
                 code(db, ADMIN, "select public.vue_generale(%s, %s, %s);" % (q(p), q(debut) if debut else 'null',
                                                                               q(fin) if fin else 'null')), attendu)
    verifier('jours sans mouvement hors de 1 à 365 : refusé',
             code(db, ADMIN, "select public.vue_generale('7j', null, null, 0);"), 'INVALID_INPUT')
    # Un paiement à 23 h 30 à Santo Domingo : 3 h 30 UTC le lendemain. Il compte pour son jour, pas pour le suivant.
    fj = jsonq(db, ADMIN, "select public.creer_facture('%s', null, %s);" % (CARO, js({'montant_usd': 40})))['facture']['id']
    jsonq(db, ADMIN, "select public.enregistrer_paiement('%s', %s);"
          % (fj, js({'montant_usd': 15, 'moyen': 'especes', 'paye_le': '2026-09-10T23:30:00-04:00'})))
    le10 = vue(db, periode='personnalise', debut='2026-09-10', fin='2026-09-10')['facturation']
    le11 = vue(db, periode='personnalise', debut='2026-09-11', fin='2026-09-11')['facturation']
    verifier('payé le 10 à 23 h 30 (le 11 en UTC) : compté le 10', (le10['encaisse_periode'], le11['encaisse_periode']), (15, 0))
    verifier('… et dans la courbe du 10', le10['par_jour'], [{'jour': '2026-09-10', 'facture': 0, 'encaisse': 15}])
    jsonq(db, ADMIN, "select public.annuler_paiement(id, 'Essai de fuseau') from paiements where facture_id = '%s';" % fj)
    jsonq(db, ADMIN, "select public.annuler_facture('%s', 'Essai de fuseau');" % fj)

    print('\nE. Les finances : facturé = payé + solde, à chaque étape')

    def fin():
        return vue(db)['facturation']

    avant = fin()
    f = jsonq(db, ADMIN, "select public.creer_facture('%s', null, %s);" % (CARO, js({'montant_usd': 75})))['facture']
    verifier('une facture de 75 $ pour Carolina', f['montant_usd'], 75)
    etapes = []
    for paiement in (None, 25, 50):
        if paiement:
            jsonq(db, ADMIN, "select public.enregistrer_paiement('%s', %s);"
                  % (f['id'], js({'montant_usd': paiement, 'moyen': 'especes'})))
        x = fin()
        c = jsonq(db, ADMIN, "select public.clients_soldes('carolina');")['lignes'][0]
        m = jsonq(db, CARO, "select public.mon_resume();")['factures']
        r = [z for z in cherche(db, f['numero'])['factures'] if z['id'] == f['id']][0]
        etapes.append({
            'solde': round(x['a_encaisser'] - avant['a_encaisser'], 2),
            'encaisse': round(x['encaisse_periode'] - avant['encaisse_periode'], 2),
            'identite': round(x['facture_periode'] - x['paye_sur_periode'] - x['solde_sur_periode'], 2),
            'client': (c['facture_usd'], c['paye_usd'], c['solde_usd']),
            'espace': (m['facture_usd'], m['paye_usd'], m['solde_usd']),
            'recherche': (r['paye_usd'], r['solde_usd'], r['etat'])})
    verifier('75 $ : solde +75, rien encaissé', (etapes[0]['solde'], etapes[0]['encaisse']), (75, 0))
    verifier('… payé 25 : solde +50, encaissé 25', (etapes[1]['solde'], etapes[1]['encaisse']), (50, 25))
    verifier('… payé 50 de plus : solde 0, encaissé 75', (etapes[2]['solde'], etapes[2]['encaisse']), (0, 75))
    verifier('facturé − payé − solde = 0 à chaque étape', [e['identite'] for e in etapes], [0, 0, 0])
    verifier('onglet Clients : 75/0/75 → 75/25/50 → 75/75/0', [e['client'] for e in etapes],
             [(75, 0, 75), (75, 25, 50), (75, 75, 0)])
    verifier('espace client : les mêmes chiffres', [e['espace'] for e in etapes], [(75, 0, 75), (75, 25, 50), (75, 75, 0)])
    verifier('recherche rapide : à payer → partielle → PAYÉE', [e['recherche'] for e in etapes],
             [(0, 75, 'a_payer'), (25, 50, 'partielle'), (75, 0, 'payee')])
    verifier('états : les mêmes que etat_paiement, facture par facture',
             fin()['etats'],
             json.loads(un(db, "select jsonb_build_object('a_payer', count(*) filter (where e = 'a_payer'), "
                               "'partielle', count(*) filter (where e = 'partielle'), 'en_retard', count(*) filter (where e = 'en_retard'), "
                               "'payee', count(*) filter (where e = 'payee'), 'annulee', count(*) filter (where e = 'annulee')) "
                               "from (select public.etat_paiement(f) e from factures f) x;")))
    verifier('à encaisser = somme des solde_usd', fin()['a_encaisser'],
             float(un(db, "select sum(public.solde_usd(f)) from factures f;")))
    # En retard : l'échéance d'hier, un solde → alerte, et le montant
    g = jsonq(db, ADMIN, "select public.creer_facture('%s', null, %s);" % (JEAN, js({'montant_usd': 12})))['facture']['id']
    db.comme(ADMIN, "update factures set echeance_le = public.aujourdhui() - 1 where id = '%s';" % g)
    x = fin()
    verifier('une facture échue : en retard, 12 $', (x['etats']['en_retard'], x['montant_en_retard']), (1, 12))
    verifier('… et son alerte', [a['nombre'] for a in vue(db)['alertes'] if a['code'] == 'factures_en_retard'], [1])
    jsonq(db, ADMIN, "select public.annuler_facture('%s', 'Erreur de saisie');" % g)
    x = fin()
    verifier('annulée : plus en retard, plus dans le facturé', (x['etats']['en_retard'], x['montant_en_retard']), (0, 0))
    verifier('clients avec un solde : Marie et Jean (colis), pas Carolina (payé)',
             fin()['clients_avec_solde'], 2)
    p = vue(db)['paiements_recents']
    verifier('paiements récents : les 50 $ puis les 25 $ de Carolina, sans le paiement annulé',
             [(z['montant_usd'], z['client']['nom_complet']) for z in p[:2]],
             [(50, 'Carolina Méndez'), (25, 'Carolina Méndez')])

    print('\nF. Un scan → un événement → le statut → le tableau de bord')
    avant = vue(db, EMPLOYE)
    numero = c1['colis']['numero']
    r = jsonq(db, EMPLOYE, "select public.scanner_operation(%s, 'COLIS_EMBALLE', 'Miami (Medley), FL');" % q(numero))
    verifier('l\'employée scanne « Emballé »', r['code'], 'OK')
    apres = vue(db, EMPLOYE)
    verifier('scans aujourd\'hui et sur la période : +1',
             (apres['scanner']['aujourdhui'] - avant['scanner']['aujourdhui'],
              apres['scanner']['periode'] - avant['scanner']['periode']), (1, 1))
    verifier('reçus −1, emballés +1',
             (apres['colis']['statuts']['recu'] - avant['colis']['statuts']['recu'],
              apres['colis']['statuts']['emballe'] - avant['colis']['statuts']['emballe']), (-1, 1))
    verifier('dernier scan : ce colis, par Emma',
             (apres['scanner']['dernier']['numero'], apres['scanner']['dernier']['auteur']), (numero, 'Emma Employée'))
    verifier('par employée et par opération',
             (apres['scanner']['par_employe'][0]['nom'], apres['scanner']['par_operation'][0]['libelle']),
             ('Emma Employée', 'Emballé'))
    verifier('activité récente : en tête, source scanner',
             (apres['activite'][0]['numero'], apres['activite'][0]['source'], apres['activite'][0]['libelle']),
             (numero, 'scanner', 'Emballé'))
    verifier('recherche : le colis dit « emballé » et son dernier événement',
             (cherche(db, numero)['colis'][0]['statut'], cherche(db, numero)['colis'][0]['dernier_evenement']['type_evenement']),
             ('emballe', 'COLIS_EMBALLE'))
    # Le même scan, deux postes, au même instant : un seul événement
    sorties = {}

    def lancer(nom, compte, texte, pause=0):
        time.sleep(pause)
        sorties[nom] = db.comme(compte, texte, echec_permis=True)

    avant = vue(db)['scanner']['periode']
    lent = "begin; select public.scanner_operation(%s, 'COLIS_EXPEDIE'); select pg_sleep(1); commit;" % q(numero)
    vite = "select public.scanner_operation(%s, 'COLIS_EXPEDIE');" % q(numero)
    t1 = threading.Thread(target=lancer, args=('A', EMPLOYE, lent))
    t2 = threading.Thread(target=lancer, args=('B', ADMIN, vite, 0.3))
    t1.start(); t2.start(); t1.join(); t2.join()
    verifier('deux scans simultanés : le second attend, puis « déjà fait »',
             'ALREADY_IN_TARGET_STATE' in sorties['B'] or 'STATUS_CONFLICT' in sorties['B'], True)
    verifier('… un seul événement compté', vue(db)['scanner']['periode'] - avant, 1)
    verifier('… et le colis compté une fois, « embarqué »',
             (vue(db)['colis']['statuts']['embarque'], un(db, "select statut from colis where numero = '%s';" % numero)),
             (1, 'embarque'))
    # Jusqu'à la livraison, puis une correction : la livraison annulée ne compte plus
    idc = c1['colis']['id']
    for s, lieu in (('distribution', 'Port-au-Prince'), ('succursale', 'Pétion-Ville'), ('disponible', 'Pétion-Ville'),
                    ('livre', 'Pétion-Ville')):
        statut(db, ADMIN, [idc], s, lieu)
    verifier('livré : +1 dans les livraisons de la période', vue(db)['colis']['livres_periode'], 1)
    statut(db, ADMIN, [idc], 'disponible', 'Pétion-Ville', motif='Livré par erreur')
    verifier('livraison corrigée (retour « disponible ») : 0', vue(db)['colis']['livres_periode'], 0)
    statut(db, ADMIN, [idc], 'livre', 'Pétion-Ville')
    verifier('relivré : 1, pas 2', vue(db)['colis']['livres_periode'], 1)

    print('\nG. Les colis à traiter')
    cj = [x for x in json.loads(un(db, "select json_agg(id) from colis where client_id = '%s';" % JEAN))][0]
    statut(db, ADMIN, [cj], 'incident', 'Miami', note='Adresse incomplète : rappeler le client')
    a = jsonq(db, EMPLOYE, "select public.colis_a_traiter('action_requise');")
    verifier('action requise : le colis de Jean, et pourquoi',
             (a['total'], a['lignes'][0]['client']['nom_complet'], a['lignes'][0]['action']['note']),
             (1, 'Jean Pierre', 'Adresse incomplète : rappeler le client'))
    verifier('… et son alerte « critique »',
             [(x['code'], x['gravite']) for x in vue(db)['alertes'] if x['code'] == 'action_requise'],
             [('action_requise', 'critique')])
    vieux = creer(db, ADMIN, dict(base, description='Oublié'))['colis']
    db.sql("alter table colis_historique disable trigger user;"
           "update colis_historique set cree_le = now() - interval '10 days' where colis_id = '%s';"
           "alter table colis_historique enable trigger user;"
           "update colis set recu_le = now() - interval '10 days' where id = '%s';" % (vieux['id'], vieux['id']))
    s7 = jsonq(db, ADMIN, "select public.colis_a_traiter('sans_mouvement', 7);")
    verifier('sans mouvement depuis 7 jours : le colis oublié, 10 jours',
             [(z['numero'], z['jours']) for z in s7['lignes']], [(vieux['numero'], 10)])
    verifier('… depuis 30 jours : aucun', jsonq(db, ADMIN, "select public.colis_a_traiter('sans_mouvement', 30);")['total'], 0)
    verifier('le chiffre de la vue générale suit le réglage',
             (vue(db, jours=7)['colis']['sans_mouvement'], vue(db, jours=30)['colis']['sans_mouvement']), (1, 0))
    verifier('liste inconnue : refusée', code(db, ADMIN, "select public.colis_a_traiter('tout');"), 'INVALID_INPUT')

    print('\nH. La recherche rapide')
    mc = un(db, "select code from clients where id = '%s';" % MARIE)
    fm = un(db, "select numero from factures where client_id = '%s' and statut <> 'annulee' limit 1;" % MARIE)
    cas = [
        ('numéro exact', numero, 'colis', numero),
        ('numéro en minuscules', numero.lower(), 'colis', numero),
        ('début de numéro', 'GSE-100', 'colis', numero),
        ('QR de l\'étiquette (lien)', 'https://www.goshipexpress.com/index.html?suivi=' + numero, 'colis', numero),
        ('suivi du vendeur', 'TBA304918577000', 'colis', numero),
        ('code client', mc, 'clients', 'Marie-Ange Dorvil'),
        ('code client, chiffres seuls', mc[4:], 'clients', 'Marie-Ange Dorvil'),
        ('un mot du nom', 'dorvil', 'clients', 'Marie-Ange Dorvil'),
        ('début de mot', 'Dorv', 'clients', 'Marie-Ange Dorvil'),
        ('nom composé', 'marie ange', 'clients', 'Marie-Ange Dorvil'),
        ('accent', 'méndez', 'clients', 'Carolina Méndez'),
        ('fin du téléphone', '4580', 'clients', 'Marie-Ange Dorvil'),
        ('téléphone complet', '+509 3712-4580', 'clients', 'Marie-Ange Dorvil'),
        ('début de l\'e-mail', 'jean@', 'clients', 'Jean Pierre'),
        ('n° de facture', fm, 'factures', fm),
    ]
    for titre, texte, partie, attendu in cas:
        r = cherche(db, texte)[partie]
        trouve = [x.get('numero') if partie != 'clients' else x['nom_complet'] for x in r]
        verifier('%s « %s »' % (titre, texte[:28]), attendu in trouve, True)
    r = cherche(db, numero)['colis'][0]
    verifier('un colis trouvé : client, destination, poids, statut, facture, solde',
             sorted(k for k in ('client', 'destination', 'poids_lb', 'statut', 'dernier_evenement', 'facture')
                    if r.get(k) is not None) + [('solde_usd' in r['facture'])],
             ['client', 'dernier_evenement', 'destination', 'facture', 'poids_lb', 'statut', True])
    for texte in ('%', '_', '%%%%', 'a', '', "'; delete from colis; --", 'GSE-%'):
        r = cherche(db, texte)
        verifier('« %s » ne liste pas tout' % texte, len(r['colis']) + len(r['clients']) + len(r['factures']), 0)
    verifier('les colis sont toujours là', un(db, "select count(*) > 0 from colis;"), 't')
    verifier('au plus 25 réponses par partie, même demandé 1000',
             len(jsonq(db, ADMIN, "select public.recherche_rapide('GSE', 1000);")['colis']) <= 25, True)

    print('\nI. Les clients et leurs soldes')
    t = jsonq(db, ADMIN, "select public.clients_soldes(null, 'solde');")
    soldes = [z['solde_usd'] for z in t['lignes']]
    verifier('triés par solde, du plus grand au plus petit', soldes, sorted(soldes, reverse=True))
    verifier('le total est celui des clients, pas de la page',
             (t['total'], jsonq(db, ADMIN, "select public.clients_soldes(null, 'nom', 'tous', 1);")['total']), (3, 3))
    verifier('une page de 1, puis la suivante',
             [z['nom_complet'] for z in jsonq(db, ADMIN, "select public.clients_soldes(null, 'nom', 'tous', 1, 1);")['lignes']],
             ['Jean Pierre'])
    verifier('avec un solde seulement', sorted(z['nom_complet'] for z in
             jsonq(db, ADMIN, "select public.clients_soldes(null, 'recent', 'avec_solde');")['lignes']),
             ['Jean Pierre', 'Marie-Ange Dorvil'])
    verifier('le solde d\'un client = somme des solde_usd de ses factures',
             [z['solde_usd'] for z in t['lignes'] if z['id'] == MARIE][0],
             float(un(db, "select sum(public.solde_usd(f)) from factures f where client_id = '%s';" % MARIE)))
    verifier('ses statuts en cours, comptés par la base',
             [z['statuts'] for z in t['lignes'] if z['id'] == JEAN][0], {'incident': 1})
    verifier('tri inconnu : refusé', code(db, ADMIN, "select public.clients_soldes(null, 'hasard');"), 'INVALID_INPUT')
    verifier('recherche « %% » : prise à la lettre',
             jsonq(db, ADMIN, "select public.clients_soldes('%');")['total'], 0)

    print('\nJ. Volume : 1, 100, 1 000 colis')
    for n_total in (100, 1000):
        deja = int(un(db, "select count(*) from colis;"))
        db.comme(ADMIN, "select public.creer_colis(jsonb_build_object('client_id', '%s', 'description', 'Vrac ' || g, "
                        "'poids_lb', 1 + g %% 7), null, true) from generate_series(1, %d) g;" % (CARO, n_total - deja))
        v = vue(db)
        verifier('%d colis : le total est celui de la table' % n_total, v['colis']['total'],
                 int(un(db, "select count(*) from colis;")))
        verifier('%d colis : les huit statuts font le total' % n_total, sum(v['colis']['statuts'].values()), v['colis']['total'])
        verifier('%d colis : chaque statut = count(*) de la table' % n_total, v['colis']['statuts'],
                 json.loads(un(db, "select jsonb_object_agg(s, (select count(*) from colis where statut = s)) "
                                   "from unnest(array['recu','emballe','embarque','distribution','succursale','disponible',"
                                   "'livre','incident']) s;")))
        verifier('%d colis : facturé = payé + solde' % n_total,
                 round(v['facturation']['facture_periode'] - v['facturation']['paye_sur_periode']
                       - v['facturation']['solde_sur_periode'], 2), 0)
        verifier('%d colis : Carolina, colis comptés par la base (pas de plafond)' % n_total,
                 [z['colis_en_cours'] for z in jsonq(db, ADMIN, "select public.clients_soldes('carolina');")['lignes']][0],
                 int(un(db, "select count(*) from colis where client_id = '%s' and statut <> 'livre';" % CARO)))
    # Au-delà : 5 000 colis et autant d'événements, insérés d'un coup
    db.sql("alter table colis disable trigger user;"
           "insert into colis (numero, client_id, description, poids_lb, statut, recu_le) "
           "select 'GSE-' || (50000 + g) || '-HT', '%s', 'Masse', 2, "
           "(array['recu','emballe','embarque','livre'])[1 + g %% 4], now() - (g %% 60) * interval '1 day' "
           "from generate_series(1, 5000) g;"
           "alter table colis enable trigger user;"
           "alter table colis_historique disable trigger user;"
           "insert into colis_historique (colis_id, statut, type_evenement, metadonnees, cree_le) "
           "select id, statut, 'COLIS_EMBALLE', '{\"source\":\"scanner\"}', recu_le from colis where description = 'Masse';"
           "alter table colis_historique enable trigger user; analyze;" % CARO)
    total = int(un(db, "select count(*) from colis;"))
    debut = time.time()
    for _ in range(3):
        v = vue(db, periode='annee')
    duree = (time.time() - debut) / 3
    verifier('%d colis : la vue générale juste…' % total, (v['colis']['total'], sum(v['colis']['statuts'].values())),
             (total, total))
    verifier('… et rapide (< 0,5 s, psql compris) : %.2f s' % duree, duree < 0.5, True)
    verifier('%d colis : la recherche d\'un numéro, rapide' % total,
             cherche(db, 'GSE-54999-HT')['colis'][0]['numero'], 'GSE-54999-HT')
    plans = {
        'numéro, début': "select id from colis where numero like 'GSE-5499%';",
        'nom, mots': "select id from clients where to_tsvector('simple', coalesce(nom_complet, '')) @@ to_tsquery('simple', 'dorv:*');",
        'téléphone, fin': "select id from clients where reverse(regexp_replace(coalesce(telephone, ''), '[^0-9]', '', 'g')) like '0854%';",
        'e-mail, début': "select id from clients where lower(email) like 'jean@%';",
        'facture, début': "select id from factures where numero like '2026-%';",
        'scans par date': "select count(*) from colis_historique where (metadonnees ->> 'source') = 'scanner' and cree_le > now() - interval '1 day';",
    }
    for titre, requete in plans.items():
        plan = db.sql("set enable_seqscan = off; explain " + requete)
        verifier('index utilisable : %s' % titre, 'Index' in plan or 'Bitmap' in plan, True)

    print('\nK. La démonstration a la même forme')
    demo = json.loads(subprocess.run(['node', os.path.join(ICI, 'essai-tableau.js'), '--formes'],
                                     capture_output=True, text=True, check=True).stdout)
    for nom, sql in (('vue générale', "select public.vue_generale('30j');"),
                     ('colis à traiter', "select public.colis_a_traiter('action_requise');"),
                     ('recherche rapide', "select public.recherche_rapide(%s);" % q(numero)),
                     ('clients et soldes', "select public.clients_soldes();")):
        forme = set(cles(jsonq(db, ADMIN, sql)))
        manque = sorted(set(demo[nom]) ^ forme)
        verifier('%s : mêmes clés côté démo' % nom, manque, [])
    forme = set(cles(jsonq(db, MARIE, "select public.mon_resume();")))
    verifier('mon résumé : mêmes clés côté démo', sorted(set(demo['mon résumé']) ^ forme), [])
    periodes = json.loads(subprocess.run(['node', os.path.join(ICI, 'essai-tableau.js'), '--periodes'],
                                         capture_output=True, text=True, check=True).stdout)
    for p, (d1, d2) in periodes.items():
        verifier('période « %s » : mêmes jours' % p, [d1, d2],
                 un(db, "select jour_debut || ' ' || jour_fin from public.bornes_periode('%s');" % p).split())

    n = sum(S.RESULTATS)
    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), n))
    sys.exit(0 if n == len(S.RESULTATS) else 1)


if __name__ == '__main__':
    main()
