# -*- coding: utf-8 -*-
"""Éprouve les finances côté base (outils/supabase-finances.sql).

Même base jetable et mêmes rôles que essai-services.py. On installe d'abord
la base TELLE QU'ELLE EST PUBLIÉE (les fichiers de la version en ligne, lus
dans Git), on y crée des factures à l'ancienne — marquées payées, à moitié
payées, annulées, sans frais —, puis on installe la nouvelle version
par-dessus : les anciennes factures ne doivent pas bouger d'un centime.
Ensuite, les paiements : partiels, multiples, en trop, en double, en même
temps, annulés ; les annulations, le regroupement, les droits, le rapport
d'anomalies.

Depuis la racine du site :

    python3 outils/essais-services/essai-finances.py
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
verifier, jsonq, colis, creer, statut, un = S.verifier, S.jsonq, S.colis, S.creer, S.statut, S.un
PAUL = '33333333-3333-3333-3333-333333333333'

# La version publiée avant la Phase 5 : c'est elle qui tourne chez Supabase.
AVANT = os.environ.get('GOSHIP_AVANT', '97f53f0')
FICHIERS = ('supabase.sql', 'supabase-facturation.sql', 'supabase-services.sql', 'supabase-evenements.sql',
            'supabase-scanner.sql')
NOUVEAUX = [os.path.join(RACINE, 'outils', f) for f in FICHIERS + ('supabase-finances.sql',)]


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


def payer(montant, moyen='especes', reference='', paye_le=None, note=''):
    d = {'montant_usd': montant, 'moyen': moyen, 'reference': reference, 'note': note}
    if paye_le:
        d['paye_le'] = paye_le
    return d


def paiement(db, compte, facture, d, cle=None, brut=False):
    texte = "select public.enregistrer_paiement('%s', %s, %s);" % (facture, js(d), q(cle))
    return texte if brut else jsonq(db, compte, texte)


def erreur(db, compte, texte):
    return db.erreur(compte, texte)


def facture_de(db, colis_id):
    return un(db, "select f.id from factures f join facture_lignes l on l.facture_id = f.id "
                  "where l.colis_id = '%s' and f.statut <> 'annulee';" % colis_id)


def etat(db, facture):
    """total payé solde état statut, tel que la base le calcule"""
    return un(db, "select montant_usd || ' ' || public.paye_usd(f) || ' ' || public.solde_usd(f) || ' ' || "
                  "public.etat_paiement(f) || ' ' || statut from factures f where id = '%s';" % facture)


def main():
    db = S.Base()
    db.sql(S.DOUBLURES)
    base = {'client_id': MARIE, 'description': 'Chaussures', 'poids_lb': 4, 'service': 'aerien',
            'pays_destination': 'HT', 'destination': 'Pétion-Ville'}

    print('A. Migration depuis la version publiée (%s)' % AVANT)
    for nom in FICHIERS:
        db.fichier(fichier_git(nom))
    for uid, email, nom in ((ADMIN, 'equipe@goship.test', 'Équipe'), (ADMIN2, 'equipe2@goship.test', 'Équipe 2'),
                            (MARIE, 'marie@exemple.com', 'Marie-Ange Dorvil'), (JEAN, 'jean@exemple.com', 'Jean'),
                            (PAUL, 'paul@exemple.com', 'Paul')):
        db.sql("""insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
                  values ('%s', '%s', now(), '{"nom_complet":"%s","pays":"HT"}'::jsonb);""" % (uid, email, nom))
    db.sql("select public.definir_admin('equipe@goship.test'); select public.definir_admin('equipe2@goship.test');")

    # La facture de 31 $ : 4,2 lb × 5 $ + 10 $ de frais, payée par PayPal à l'ancienne
    h31 = creer(db, ADMIN, dict(base, description='Colis à 31 $', poids_lb=4.2))
    f31 = h31['facture']['id']
    db.comme(ADMIN, "update factures set statut = 'payee', montant_paye_usd = 31, moyen = 'paypal' "
                    "where id = '%s';" % f31)
    # À moitié payée, sans moyen noté
    hp = creer(db, ADMIN, dict(base, description='Acompte', poids_lb=6))
    fp = hp['facture']['id']
    db.comme(ADMIN, "update factures set montant_paye_usd = 12.50 where id = '%s';" % fp)
    # Annulée, avec de l'argent dessus (une anomalie à signaler, pas à effacer)
    ha = creer(db, ADMIN, dict(base, description='Annulée payée', poids_lb=2))
    fa_ = ha['facture']['id']
    db.comme(ADMIN, "update factures set montant_paye_usd = 5, statut = 'annulee' where id = '%s';" % fa_)
    # D'avant le 22/09/2026 : sans frais de service, voulu
    db.sql("""insert into factures (numero, client_id, montant_usd, frais_service_usd, statut, montant_paye_usd,
                                    moyen, cree_le, payee_le)
              values ('FAC-2026-0003', '%s', 40, 0, 'payee', 40, 'moncash', '2026-08-02', '2026-08-05');""" % MARIE)
    # Montant libre, sans colis, à payer
    libre = jsonq(db, ADMIN, "select public.creer_facture('%s', null, %s);"
                  % (JEAN, js({'montant_usd': 18, 'note': 'Emballage'})))['facture']['id']
    photo = ("select string_agg(numero || ':' || montant_usd || ':' || frais_service_usd || ':' || montant_paye_usd"
             " || ':' || statut || ':' || moyen || ':' || coalesce(payee_le::text, '-') || ':' || cree_le, '|'"
             " order by numero) from factures;")
    avant = un(db, photo)
    avant_lignes = un(db, "select string_agg(facture_id || ':' || coalesce(colis_id::text, '-') || ':' || montant_usd,"
                          " '|' order by id) from facture_lignes;")

    for f in NOUVEAUX:
        db.fichier(f)
    for f in NOUVEAUX[::-1] + NOUVEAUX:
        db.fichier(f)
    controle = un(db, open(NOUVEAUX[-1], encoding='utf-8').read().split('-- Contrôle ---')[1].split('\n', 1)[1])
    verifier('installée par-dessus, relancée dans le désordre : contrôle', controle, '9|6|0|4')
    verifier('aucune facture n\'a bougé : total, frais, payé, statut, moyen, dates', un(db, photo), avant)
    verifier('aucune ligne non plus', un(db, "select string_agg(facture_id || ':' || coalesce(colis_id::text, '-') || "
                                             "':' || montant_usd, '|' order by id) from facture_lignes;"), avant_lignes)
    verifier('chaque montant payé est devenu UN paiement repris (4 factures)',
             un(db, "select string_agg(f.numero || '=' || p.montant_usd || ' ' || p.moyen, ',' order by p.montant_usd) "
                    "from paiements p join factures f on f.id = p.facture_id where p.origine = 'reprise';"),
             un(db, "select string_agg(numero || '=' || montant_paye_usd || ' ' || "
                    "case when moyen = '' then 'autre' else moyen end, ',' order by montant_paye_usd) "
                    "from factures where montant_paye_usd > 0;"))
    verifier('le paiement repris est daté du jour où la facture a été payée',
             un(db, "select (p.paye_le = f.payee_le)::text from paiements p join factures f on f.id = p.facture_id "
                    "where f.numero = 'FAC-2026-0003';"), 'true')
    verifier('relancer le fichier ne reprend rien deux fois',
             un(db, "select count(*) from paiements where origine = 'reprise';"), '4')

    print('\nB. La facture historique de 31 $')
    verifier('base : total 31, payé 31, solde 0, payée', etat(db, f31), '31.00 31.00 0.00 payee payee')
    mf = [f for f in jsonq(db, MARIE, "select public.mes_factures();") if f['id'] == f31][0]
    verifier('espace client : 31 $, payé 31 $, solde 0, payée',
             (mf['montant_usd'], mf['paye_usd'], mf['solde_usd'], mf['etat'], mf['moyen']),
             (31, 31, 0, 'payee', 'paypal'))
    verifier('… et ses lignes : 21 $, 4,2 lb, 5 $/lb (tarif recopié, le calcul retombe juste)',
             [(l['montant_usd'], l['poids_lb'], l['tarif_lb_usd']) for l in mf['lignes']], [(21, 4.2, 5)])
    verifier('… et son paiement, repris', [(p['montant_usd'], p['moyen']) for p in mf['paiements']], [(31, 'paypal')])
    fc = jsonq(db, 'sql', "select public.facture_complete('%s');" % f31)
    verifier('tableau de bord : les mêmes chiffres',
             (fc['montant_usd'], fc['frais_service_usd'], fc['paye_usd'], fc['solde_usd'], fc['etat_paiement']),
             (31, 10, 31, 0, 'payee'))
    # Ce que l'écran et le papier en font : API.outils.totauxFacture (api.js),
    # nourri des réponses de la base telles quelles
    totaux = json.loads(subprocess.run(['node', os.path.join(ICI, 'essai-finances.js'), '--totaux'],
                                       input=json.dumps([mf, fc]), capture_output=True, text=True,
                                       check=True).stdout)
    verifier('écran et papier (api.js), espace client comme tableau de bord : 21 + 10 = 31, soldée',
             [(t_['colis'], t_['frais'], t_['grandTotal'], t_['paye'], t_['balance'], t_['etat']) for t_ in totaux],
             [(21, 10, 31, 31, 0, 'payee')] * 2)
    verifier('ancienne facture sans frais : 40 $, payée, rien à signaler pour ses frais',
             (etat(db, un(db, "select id from factures where numero = 'FAC-2026-0003';")),
              un(db, "select count(*) from jsonb_array_elements(public.rapport_anomalies_facturation()) a "
                     "where a->>'numero' = 'FAC-2026-0003';")), ('40.00 40.00 0.00 payee payee', '0'))
    verifier('à moitié payée à l\'ancienne : partielle', etat(db, fp), '40.00 12.50 27.50 partielle a_payer')

    print('\nC. Tarifs : le prix est arrêté sur le colis et sur la ligne')
    t = creer(db, ADMIN, dict(base, description='Tarif spécial', poids_lb=10, tarif_lb_usd=2.5))
    ft = t['facture']['id']
    verifier('10 lb × 2,50 $ = 25 $ ; facture 35 $', (t['colis']['prix_usd'], t['facture']['montant_usd']), (25, 35))
    verifier('la ligne garde son tarif : 2,50 $/lb',
             un(db, "select tarif_lb_usd || ' ' || montant_usd from facture_lignes where facture_id = '%s';" % ft),
             '2.50 25.00')
    db.sql("""create or replace function public.tarifs() returns jsonb language sql immutable set search_path = ''
              as $$ select jsonb_build_object('par_livre', 3, 'frais_service', 10) $$;""")
    jsonq(db, ADMIN, "select public.modifier_colis('%s', %s);" % (t['colis']['id'], js({'description': 'Renommé'})))
    verifier('le tarif par défaut passe à 3 $ : l\'ancien colis reste à 25 $',
             un(db, "select prix_usd || ' ' || tarif_lb_usd from colis where id = '%s';" % t['colis']['id']),
             '25.00 2.50')
    verifier('… sa facture reste à 35 $, sa ligne à 25 $', etat(db, ft).split()[0] + ' ' +
             un(db, "select montant_usd from facture_lignes where facture_id = '%s';" % ft), '35.00 25.00')
    n = creer(db, ADMIN, dict(base, description='Nouveau tarif', poids_lb=10))
    verifier('un nouveau colis prend le nouveau tarif : 10 × 3 = 30 $, facture 40 $',
             (n['colis']['tarif_lb_usd'], n['colis']['prix_usd'], n['facture']['montant_usd']), (3, 30, 40))
    db.fichier(os.path.join(RACINE, 'outils', 'supabase-services.sql'))   # tarifs() d'origine
    for f in NOUVEAUX[3:]:
        db.fichier(f)
    verifier('tarifs remis : 5 $/lb', un(db, "select public.tarifs() ->> 'par_livre';"), '5')

    print('\nD. Regroupement : 20 + 15 + 30 + 10 = 75 $')
    c3 = [creer(db, ADMIN, dict(base, description='Groupe %d' % p, poids_lb=p), facturer=False)['colis']['id']
          for p in (4, 3, 6)]
    calc = jsonq(db, ADMIN, "select public.calculer_facture(array['%s']::uuid[]);" % "','".join(c3))
    verifier('aperçu (calculer_facture) : 65 + 10 = 75, rien de créé',
             (calc['sous_total'], calc['frais_service'], calc['total'],
              un(db, "select count(*) from facture_lignes where colis_id in ('%s');" % "','".join(c3))),
             (65, 10, 75, '0'))
    g = jsonq(db, ADMIN, "select public.creer_facture('%s', array['%s']::uuid[], '{}', 'groupe-1');"
              % (MARIE, "','".join(c3)))['facture']
    verifier('une facture, trois lignes, frais une seule fois : 75 $',
             (g['montant_usd'], g['frais_service_usd'], sorted(l['montant_usd'] for l in g['facture_lignes'])),
             (75, 10, [15, 20, 30]))
    fg = g['id']
    # Trois colis facturés un par un (30 + 25 + 40 = 95 $), puis regroupés
    r3 = [creer(db, ADMIN, dict(base, description='Séparé %d' % p, poids_lb=p)) for p in (4, 3, 6)]
    ids3 = [r['facture']['id'] for r in r3]
    verifier('séparément : 30 + 25 + 40 = 95 $', sum(r['facture']['montant_usd'] for r in r3), 95)
    rg = jsonq(db, ADMIN, "select public.regrouper_factures(array['%s']::uuid[], 'regroupe-1');" % "','".join(ids3))
    verifier('regroupées : 75 $ (les frais comptés une fois), à payer',
             (rg['facture']['montant_usd'], rg['facture']['frais_service_usd'], rg['facture']['etat_paiement'],
              len(rg['facture']['facture_lignes'])), (75, 10, 'a_payer', 3))
    verifier('les trois anciennes : annulées, avec motif, pointant vers la nouvelle',
             un(db, "select string_agg(distinct statut || ':' || (remplacee_par = '%s') || ':' || "
                    "(motif_annulation like 'Regroupement des factures %%'), ',') from factures where id in ('%s');"
                    % (rg['facture']['id'], "','".join(ids3))), 'annulee:true:true')
    rg2 = jsonq(db, ADMIN, "select public.regrouper_factures(array['%s']::uuid[], 'regroupe-1');" % "','".join(ids3))
    verifier('même demande renvoyée : même facture, rien de refait',
             (rg2['deja'], rg2['facture']['id'], len(rg2['annulees'])), (True, rg['facture']['id'], 3))
    x1 = creer(db, ADMIN, dict(base, description='Payé', poids_lb=1))['facture']['id']
    x2 = creer(db, ADMIN, dict(base, description='Pas payé', poids_lb=1))['facture']['id']
    x3 = creer(db, ADMIN, dict(base, client_id=JEAN, description='Autre client', poids_lb=1))['facture']['id']
    paiement(db, ADMIN, x1, payer(5))
    reg = "select public.regrouper_factures(array['%s']::uuid[]);"
    verifier('une facture qui a reçu un paiement ne se regroupe pas', erreur(db, ADMIN, reg % ("%s','%s" % (x1, x2))),
             'INVOICE_HAS_PAYMENTS')
    verifier('deux clients : refusé', erreur(db, ADMIN, reg % ("%s','%s" % (x2, x3))), 'INVOICE_CLIENT_MISMATCH')
    verifier('une seule facture : refusé', erreur(db, ADMIN, reg % x2), 'INVALID_INPUT')
    verifier('une facture sans colis : refusé', erreur(db, ADMIN, reg % ("%s','%s" % (x3, libre))),
             'INVOICE_NOT_GROUPABLE')
    verifier('une facture annulée : refusé', erreur(db, ADMIN, reg % ("%s','%s" % (x2, ids3[0]))),
             'INVOICE_NOT_GROUPABLE')
    verifier('un client ne regroupe rien', erreur(db, MARIE, reg % ("%s','%s" % (x2, fg))), 'PERMISSION_DENIED')
    verifier('refus : rien n\'a été annulé', un(db, "select statut from factures where id = '%s';" % x2), 'a_payer')

    print('\nE. Paiements : partiel, multiples, en trop')
    p1 = paiement(db, ADMIN, fg, payer(25, 'moncash', 'MC-001', paye_le='2026-09-20T10:00:00-04:00'), cle='p-1')
    verifier('25 $ sur 75 $ : payé 25, solde 50, partielle, toujours « à payer »',
             (etat(db, fg), p1['facture']['solde_usd'], p1['deja']), ('75.00 25.00 50.00 partielle a_payer', 50, False))
    verifier('le paiement : montant, moyen, référence, auteur, origine',
             (p1['paiement']['montant_usd'], p1['paiement']['moyen'], p1['paiement']['reference'],
              p1['paiement']['cree_par'], p1['paiement']['origine']), (25, 'moncash', 'MC-001', ADMIN, 'saisie'))
    paiement(db, ADMIN, fg, payer(20, 'especes', paye_le='2026-09-22T10:00:00-04:00'))
    verifier('+ 20 $ : payé 45, solde 30', etat(db, fg), '75.00 45.00 30.00 partielle a_payer')
    verifier('80 $ sur une facture de 75 $ (solde 30) : refusé', erreur(db, ADMIN, paiement(db, ADMIN, fg, payer(80), brut=True)),
             'OVERPAYMENT')
    verifier('31 $ pour un solde de 30 $ : refusé', erreur(db, ADMIN, paiement(db, ADMIN, fg, payer(31), brut=True)),
             'OVERPAYMENT')
    verifier('refusé : le solde n\'a pas bougé', etat(db, fg), '75.00 45.00 30.00 partielle a_payer')
    p3 = paiement(db, ADMIN, fg, payer('30,00', 'banque', 'VIR-77', paye_le='2026-09-24T15:00:00-04:00'))
    verifier('+ 30 $ (virgule acceptée) : payé 75, solde 0, payée',
             etat(db, fg), '75.00 75.00 0.00 payee payee')
    verifier('payée le jour du dernier paiement, par son moyen',
             un(db, "select (payee_le = '2026-09-24T15:00:00-04:00'::timestamptz) || ' ' || moyen "
                    "from factures where id = '%s';" % fg), 'true banque')
    verifier('trois paiements, le payé de la facture est leur somme',
             un(db, "select count(*) || ' ' || sum(montant_usd) || ' ' || (select montant_paye_usd from factures "
                    "where id = '%s') from paiements where facture_id = '%s';" % (fg, fg)), '3 75.00 75.00')
    verifier('facture payée : un paiement de plus est refusé',
             erreur(db, ADMIN, paiement(db, ADMIN, fg, payer(1), brut=True)), 'INVOICE_ALREADY_PAID')
    verifier('montant nul', erreur(db, ADMIN, paiement(db, ADMIN, x2, payer(0), brut=True)), 'INVALID_AMOUNT')
    verifier('montant négatif', erreur(db, ADMIN, paiement(db, ADMIN, x2, payer(-5), brut=True)), 'INVALID_AMOUNT')
    verifier('montant illisible', erreur(db, ADMIN, paiement(db, ADMIN, x2, payer('abc'), brut=True)), 'INVALID_AMOUNT')
    verifier('moyen inconnu', erreur(db, ADMIN, paiement(db, ADMIN, x2, payer(1, 'bitcoin'), brut=True)),
             'INVALID_PAYMENT_METHOD')
    verifier('date dans le futur', erreur(db, ADMIN, paiement(db, ADMIN, x2, payer(1, paye_le='2099-01-01'), brut=True)),
             'INVALID_DATE')
    verifier('facture inconnue', erreur(db, ADMIN, "select public.enregistrer_paiement("
                                                     "'00000000-0000-0000-0000-000000000000', %s);" % js(payer(1))),
             'INVOICE_NOT_FOUND')

    print('\nF. Double paiement')
    y = creer(db, ADMIN, dict(base, description='Double', poids_lb=13))['facture']['id']    # 75 $
    a = paiement(db, ADMIN, y, payer(25, 'paypal', 'PP-1'), cle='double')
    b = paiement(db, ADMIN, y, payer(25, 'paypal', 'PP-1'), cle='double')
    verifier('double clic (même clé) : le même paiement, pas un second',
             (b['deja'], b['paiement']['id'] == a['paiement']['id'], etat(db, y)),
             (True, True, '75.00 25.00 50.00 partielle a_payer'))
    verifier('même référence PayPal saisie deux fois : refusé',
             erreur(db, ADMIN, paiement(db, ADMIN, y, payer(25, 'paypal', 'pp-1'), cle='autre', brut=True)),
             'DUPLICATE_PAYMENT')
    verifier('la même clé pour une autre facture : refusé',
             erreur(db, ADMIN, paiement(db, ADMIN, x2, payer(1), cle='double', brut=True)), 'DUPLICATE_OPERATION')

    print('\nG. Concurrence : 50 $ + 50 $ sur une facture de 75 $')
    z = creer(db, ADMIN, dict(base, description='Course', poids_lb=13))['facture']['id']
    sorties = {}

    def lancer(nom, compte, texte, pause=0):
        time.sleep(pause)
        sorties[nom] = db.comme(compte, texte, echec_permis=True)

    lent = "begin; %s select pg_sleep(1); commit;" % paiement(db, ADMIN, z, payer(50, 'especes'), brut=True)
    rapide = paiement(db, ADMIN2, z, payer(50, 'banque'), brut=True)
    t1 = threading.Thread(target=lancer, args=('A', ADMIN, lent))
    t2 = threading.Thread(target=lancer, args=('B', ADMIN2, rapide, 0.3))
    t1.start(); t2.start(); t1.join(); t2.join()
    verifier('le second attend le premier, puis est refusé', ('ERROR' in sorties['A'], 'OVERPAYMENT' in sorties['B']),
             (False, True))
    verifier('un seul paiement : payé 50, solde 25', etat(db, z), '75.00 50.00 25.00 partielle a_payer')
    cle = "begin; %s select pg_sleep(1); commit;" % paiement(db, ADMIN, x2, payer(3), cle='meme', brut=True)
    t1 = threading.Thread(target=lancer, args=('C', ADMIN, cle))
    t2 = threading.Thread(target=lancer, args=('D', ADMIN2, cle, 0.3))
    t1.start(); t2.start(); t1.join(); t2.join()
    verifier('même paiement envoyé deux fois en même temps : un seul',
             un(db, "select count(*) from paiements where facture_id = '%s';" % x2), '1')

    print('\nH. Corriger : annuler un paiement, avec son motif')
    ids = un(db, "select string_agg(id::text, ',' order by cree_le) from paiements where facture_id = '%s';" % fg).split(',')
    verifier('sans motif : refusé', erreur(db, ADMIN, "select public.annuler_paiement('%s', '  ');" % ids[1]),
             'REASON_REQUIRED')
    an = jsonq(db, ADMIN, "select public.annuler_paiement('%s', 'Billet refusé à la banque');" % ids[1])
    verifier('les 20 $ annulés : payé 55, solde 20, la facture redevient à payer',
             (etat(db, fg), an['facture']['solde_usd']), ('75.00 55.00 20.00 partielle a_payer', 20))
    verifier('… et n\'est plus datée « payée »', un(db, "select coalesce(payee_le::text, 'vide') from factures "
                                                       "where id = '%s';" % fg), 'vide')
    verifier('le paiement reste, barré : date, auteur, motif',
             un(db, "select (annule_le is not null) || ' ' || annule_par || ' ' || motif_annulation from paiements "
                    "where id = '%s';" % ids[1]), 'true %s Billet refusé à la banque' % ADMIN)
    verifier('annulé deux fois : rien de plus', jsonq(db, ADMIN, "select public.annuler_paiement('%s', 'x');" % ids[1])['deja'],
             True)
    paiement(db, ADMIN, fg, payer(20, 'natcash', 'NC-9', note='Remplace le billet refusé'))
    verifier('le bon paiement saisi : de nouveau payée', etat(db, fg), '75.00 75.00 0.00 payee payee')
    verifier('le client voit trois paiements, pas celui annulé',
             [p['montant_usd'] for p in [f for f in jsonq(db, MARIE, "select public.mes_factures();")
                                         if f['id'] == fg][0]['paiements']], [25, 30, 20])
    verifier('modifier un paiement : même l\'équipe n\'a pas le droit d\'écrire dans la table',
             'permission denied' in erreur(db, ADMIN, "update paiements set montant_usd = 1 where id = '%s';" % ids[0]),
             True)
    verifier('… ni le SQL Editor : un paiement ne se modifie pas',
             erreur(db, 'sql', "update paiements set montant_usd = 1 where id = '%s';" % ids[0]), 'PAYMENT_LOCKED')
    verifier('… ne se supprime pas', erreur(db, 'sql', "delete from paiements where id = '%s';" % ids[0]),
             'PAYMENT_LOCKED')
    verifier('… et une annulation ne se défait pas',
             erreur(db, 'sql', "update paiements set annule_le = null where id = '%s';" % ids[1]), 'PAYMENT_LOCKED')

    print('\nI. La facture elle-même : plus rien d\'écrit à la main')
    v = creer(db, ADMIN, dict(base, description='Garde', poids_lb=2))['facture']['id']    # 20 $
    for titre, sql, code in (
            ('« Marquer payée » à l\'ancienne', "update factures set statut = 'payee' where id = '%s';", 'PAYMENT_REQUIRED'),
            ('écrire le montant payé', "update factures set montant_paye_usd = 20 where id = '%s';", 'PAYMENT_REQUIRED'),
            ('écrire le moyen', "update factures set moyen = 'paypal' where id = '%s';", 'PAYMENT_REQUIRED'),
            ('annuler sans motif, par la table', "update factures set statut = 'annulee' where id = '%s';", 'INVOICE_LOCKED'),
            ('changer son numéro', "update factures set numero = 'X-1' where id = '%s';", 'INVOICE_LOCKED'),
            ('changer son total (facture de colis)', "update factures set montant_usd = 1 where id = '%s';", 'INVOICE_LOCKED'),
            ('la supprimer', "delete from factures where id = '%s';", 'INVOICE_DELETE_FORBIDDEN'),
            ('lui retirer une ligne', "delete from facture_lignes where facture_id = '%s';", 'INVOICE_LOCKED'),
            ('changer une ligne', "update facture_lignes set libelle = 'x' where facture_id = '%s';", 'INVOICE_LOCKED')):
        verifier('refusé : ' + titre, erreur(db, ADMIN, sql % v), code)
    autre = creer(db, ADMIN, dict(base, description='Intrus', poids_lb=1), facturer=False)['colis']['id']
    verifier('refusé : ajouter un colis à une facture déjà émise',
             erreur(db, ADMIN, "insert into facture_lignes (facture_id, colis_id) values ('%s', '%s');" % (v, autre)),
             'INVOICE_LOCKED')
    db.comme(ADMIN, "update factures set note = 'Merci', echeance_le = '2026-10-01', "
                    "lien_paiement = 'https://paypal.test/x' where id = '%s';" % v)
    verifier('permis : échéance, note, lien de paiement',
             un(db, "select note || ' ' || echeance_le || ' ' || lien_paiement from factures where id = '%s';" % v),
             'Merci 2026-10-01 https://paypal.test/x')
    paiement(db, ADMIN, libre, payer(8))
    verifier('facture libre : son total se change, jamais sous le payé',
             erreur(db, ADMIN, "update factures set montant_usd = 5 where id = '%s';" % libre), 'INVALID_AMOUNT')
    db.comme(ADMIN, "update factures set montant_usd = 8 where id = '%s';" % libre)
    verifier('ramenée à ce qui est payé : elle devient payée', etat(db, libre), '8.00 8.00 0.00 payee payee')
    cp = jsonq(db, ADMIN, "select public.creer_facture('%s', null, %s);"
               % (JEAN, js({'montant_usd': 50, 'montant_paye_usd': 20})))['facture']['id']
    verifier('payée en partie à la création : un paiement « à la création »',
             (etat(db, cp), un(db, "select origine || ' ' || montant_usd from paiements where facture_id = '%s';" % cp)),
             ('50.00 20.00 30.00 partielle a_payer', 'creation 20.00'))

    print('\nJ. Annuler une facture, au lieu de la supprimer')
    verifier('une facture qui a reçu de l\'argent : refusé',
             erreur(db, ADMIN, "select public.annuler_facture('%s', 'Erreur');" % z), 'INVOICE_HAS_PAYMENTS')
    verifier('sans motif : refusé', erreur(db, ADMIN, "select public.annuler_facture('%s', '');" % v), 'REASON_REQUIRED')
    col_v = un(db, "select colis_id from facture_lignes where facture_id = '%s';" % v)
    num_v = un(db, "select numero from factures where id = '%s';" % v)
    af = jsonq(db, ADMIN, "select public.annuler_facture('%s', 'Mauvais client');" % v)['facture']
    verifier('annulée : statut, date, auteur, motif, solde 0',
             (af['statut'], af['annulee_le'] is not None, af['annulee_par'], af['motif_annulation'], af['solde_usd'],
              af['etat_paiement']), ('annulee', True, ADMIN, 'Mauvais client', 0, 'annulee'))
    verifier('annulée deux fois : rien de plus',
             jsonq(db, ADMIN, "select public.annuler_facture('%s', 'x');" % v)['deja'], True)
    verifier('un paiement sur une facture annulée : refusé',
             erreur(db, ADMIN, paiement(db, ADMIN, v, payer(1), brut=True)), 'INVOICE_CANCELLED')
    verifier('une facture annulée ne se modifie plus',
             erreur(db, ADMIN, "update factures set note = 'x' where id = '%s';" % v), 'INVOICE_LOCKED')
    nf = jsonq(db, ADMIN, "select public.facturer_colis('%s');" % col_v)['facture']
    verifier('son colis se refacture, sous un autre numéro', (nf['numero'] != num_v, nf['montant_usd']), (True, 20))

    print('\nK. Les numéros ne servent qu\'une fois')
    hp_ = creer(db, ADMIN, dict(base, client_id=PAUL, description='Paul', poids_lb=1))['facture']
    paiement(db, ADMIN, hp_['id'], payer(5))
    db.sql("delete from auth.users where id = '%s';" % PAUL)
    verifier('le compte d\'un client disparaît : ses factures et paiements avec lui',
             un(db, "select count(*) from factures where client_id = '%s';" % PAUL), '0')
    verifier('… mais son numéro reste réservé', un(db, "select count(*) from factures_numeros where numero = '%s';"
                                                   % hp_['numero']), '1')
    db.sql("insert into factures (numero, client_id, montant_usd) values ('%s', '%s', 1);" % (hp_['numero'], JEAN))
    verifier('un numéro tiré qui a déjà servi est remplacé par un neuf',
             un(db, "select count(*) from factures where numero = '%s';" % hp_['numero']), '0')
    verifier('un numéro imposé qui a déjà servi est refusé',
             erreur(db, 'sql', "insert into factures (numero, client_id, montant_usd) values ('FAC-2026-0003', '%s', 1);"
                    % JEAN), 'INVOICE_NUMBER_USED')

    print('\nL. Chacun ne voit que ses factures et ses paiements (RLS)')
    verifier('Marie : ses paiements seulement',
             un(db, "set role authenticated; set request.jwt.claims = '{\"sub\":\"%s\"}'; "
                    "select count(distinct client_id) || ' ' || bool_and(client_id = '%s') from paiements;"
                    % (MARIE, MARIE)), '1 true')
    verifier('Jean : pas un paiement de Marie',
             un(db, "set role authenticated; set request.jwt.claims = '{\"sub\":\"%s\"}'; "
                    "select count(*) from paiements where client_id = '%s';" % (JEAN, MARIE)), '0')
    verifier('Jean : pas une facture de Marie dans les siennes',
             all(f['id'] != fg for f in jsonq(db, JEAN, "select public.mes_factures();")), True)
    verifier('Jean : le solde d\'une facture de Marie lui est invisible',
             un(db, "set role authenticated; set request.jwt.claims = '{\"sub\":\"%s\"}'; "
                    "select count(*) from factures where id = '%s';" % (JEAN, fg)), '0')
    for nom, sql in (('enregistrer un paiement', paiement(db, MARIE, fg, payer(1), brut=True)),
                     ('annuler un paiement', "select public.annuler_paiement('%s', 'x');" % ids[0]),
                     ('annuler une facture', "select public.annuler_facture('%s', 'x');" % fg),
                     ('calculer', "select public.calculer_facture(array['%s']::uuid[]);" % c3[0]),
                     ('le résumé de facturation', "select public.resume_facturation();"),
                     ('le rapport d\'anomalies', "select public.rapport_anomalies_facturation();")):
        verifier('un client ne peut pas : ' + nom, erreur(db, MARIE, sql), 'PERMISSION_DENIED')
    verifier('un client n\'écrit pas dans la table des paiements',
             'permission denied' in erreur(db, MARIE, "insert into paiements (facture_id, client_id, montant_usd, moyen) "
                                                      "values ('%s', '%s', 1, 'especes');" % (fg, MARIE)), True)
    verifier('un visiteur n\'appelle aucune fonction de paiement',
             un(db, "select bool_or(has_function_privilege('anon', p.oid, 'execute'))::text from pg_proc p "
                    "join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname in "
                    "('enregistrer_paiement','annuler_paiement','annuler_facture','regrouper_factures',"
                    "'resume_facturation','rapport_anomalies_facturation','mes_factures','solde_usd');"), 'false')
    verifier('… ni ne lit les paiements', 'permission denied' in erreur(db, None, "select * from paiements;"), True)
    verifier('sécurité active sur les nouvelles tables',
             un(db, "select string_agg(relname || ':' || relrowsecurity, ',' order by relname) from pg_class "
                    "where relname in ('paiements', 'factures_numeros', 'evenements_facturation');"),
             'evenements_facturation:true,factures_numeros:true,paiements:true')
    verifier('toute fonction « security definer » a son search_path',
             un(db, "select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace "
                    "where n.nspname = 'public' and p.prosecdef and not exists "
                    "(select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%');"), '0')

    print('\nM. En retard, et le résumé de l\'onglet Factures')
    r1 = creer(db, ADMIN, dict(base, description='Échue', poids_lb=2))['facture']['id']
    r2 = creer(db, ADMIN, dict(base, description='Échue payée', poids_lb=2))['facture']['id']
    r3 = creer(db, ADMIN, dict(base, description='Due aujourd\'hui', poids_lb=2))['facture']['id']
    db.comme(ADMIN, "update factures set echeance_le = public.aujourdhui() - 1 where id in ('%s', '%s');" % (r1, r2))
    db.comme(ADMIN, "update factures set echeance_le = public.aujourdhui() where id = '%s';" % r3)
    paiement(db, ADMIN, r2, payer(20))
    paiement(db, ADMIN, r1, payer(5))
    verifier('échue et pas soldée : en retard (même en partie payée)', etat(db, r1).split()[3], 'en_retard')
    verifier('échue mais payée : payée', etat(db, r2).split()[3], 'payee')
    verifier('due aujourd\'hui : pas encore en retard', etat(db, r3).split()[3], 'a_payer')
    res = jsonq(db, ADMIN, "select public.resume_facturation();")
    attendu = un(db, "select sum(public.solde_usd(f)) from factures f where statut <> 'annulee';")
    verifier('à encaisser = somme des soldes', float(res['a_encaisser']) == float(attendu), True)
    verifier('en retard : 1 facture, 15 $', (res['en_retard'], res['montant_en_retard']), (1, 15))
    verifier('encaissé ce mois : les paiements valides du mois',
             float(res['encaisse_mois']) == float(un(db, "select sum(montant_usd) from paiements where annule_le is null "
                                                         "and paye_le >= date_trunc('month', now() at time zone "
                                                         "'America/Santo_Domingo') at time zone 'America/Santo_Domingo';")),
             True)

    print('\nN. Le scanner et les statuts ne touchent pas à la facture')
    sc = creer(db, ADMIN, dict(base, description='Scanné', poids_lb=5, suivi_transporteur='SCAN-FIN-1'))
    fs = sc['facture']['id']
    paiement(db, ADMIN, fs, payer(10))
    avant_s = un(db, photo)
    jsonq(db, ADMIN, "select public.scanner_operation('SCAN-FIN-1', 'COLIS_EXPEDIE', 'Miami', null, '{}', 'k-s1', null, null);")
    jsonq(db, ADMIN, "select public.scanner_operation('SCAN-FIN-1', 'COLIS_ARRIVE', 'Port-au-Prince', null, '{}', 'k-s2', null, null);")
    statut(db, ADMIN, [sc['colis']['id']], 'disponible', 'Pétion-Ville')
    statut(db, ADMIN, [sc['colis']['id']], 'livre', 'Pétion-Ville')
    verifier('expédié, arrivé, disponible, livré : factures identiques', un(db, photo), avant_s)
    verifier('… la sienne toujours partielle', etat(db, fs), '35.00 10.00 25.00 partielle a_payer')

    print('\nO. Traçabilité : journal et événements de facturation')
    verifier('journal : enregistrements, annulations, reprise, regroupement, annulation de facture',
             un(db, "select string_agg(distinct action, ',' order by action) from journal_audit "
                    "where action like 'paiement.%' or action in ('facture.annulation', 'facture.regroupement');"),
             'facture.annulation,facture.regroupement,paiement.annulation,paiement.enregistrement,paiement.reprise')
    verifier('journal d\'une annulation : qui, et le motif',
             un(db, "select auteur_id || ' ' || (apres ->> 'motif') from journal_audit "
                    "where action = 'paiement.annulation' limit 1;"), '%s Billet refusé à la banque' % ADMIN)
    verifier('file d\'événements prête pour les notifications (rien d\'envoyé)',
             un(db, "select string_agg(distinct type, ',' order by type) || ' ' || count(*) filter (where traite_le is not null)"
                    " from evenements_facturation;"),
             'FACTURE_ANNULEE,FACTURE_CREEE,FACTURE_PAYEE,PAIEMENT_ANNULE,PAIEMENT_ENREGISTRE 0')
    verifier('la reprise n\'a pas inventé d\'événements',
             un(db, "select count(*) from evenements_facturation e join paiements p on p.id = e.paiement_id "
                    "where p.origine = 'reprise';"), '0')
    verifier('un client ne lit ni le journal ni la file',
             un(db, "set role authenticated; set request.jwt.claims = '{\"sub\":\"%s\"}'; "
                    "select (select count(*) from journal_audit) + (select count(*) from evenements_facturation);"
                    % MARIE), '0')

    print('\nP. Rapport d\'anomalies : il signale, il ne corrige rien')
    col_r = un(db, "select colis_id from facture_lignes where facture_id = '%s';" % r3)
    jsonq(db, ADMIN, "select public.modifier_colis('%s', %s);" % (col_r, js({'poids_lb': 3})))
    db.sql("select set_config('goship.finances', 'on', false); "
           "update factures set montant_paye_usd = 7 where id = '%s';" % x2)
    tout = un(db, photo) + un(db, "select string_agg(id || ':' || coalesce(annule_le::text, '-'), '|' order by id) "
                                  "from paiements;")
    rap = jsonq(db, ADMIN, "select public.rapport_anomalies_facturation();")
    types = {}
    for a_ in rap:
        types.setdefault(a_['type'], []).append(a_['numero'])
    num = lambda i: un(db, "select numero from factures where id = '%s';" % i)
    verifier('payé inscrit ≠ somme des paiements : signalé (erreur)', num(x2) in types.get('paye_different_paiements', []),
             True)
    verifier('argent sur une facture annulée (reprise) : signalé', num(fa_) in types.get('paiement_sur_facture_annulee', []),
             True)
    verifier('colis repesé après sa facture : signalé pour info', num(r3) in types.get('prix_colis_change', []), True)
    verifier('aucun doublon, aucun total faux, aucun colis chez un autre client',
             [t_ for t_ in ('colis_facture_deux_fois', 'total_incoherent', 'client_different') if t_ in types], [])
    verifier('les anciennes factures sans frais ne sont pas signalées', 'frais_absents' in types, False)
    verifier('le rapport n\'a rien modifié',
             un(db, photo) + un(db, "select string_agg(id || ':' || coalesce(annule_le::text, '-'), '|' order by id) "
                                    "from paiements;"), tout)
    db.sql("select set_config('goship.finances', 'on', false); "
           "update factures set montant_paye_usd = 3 where id = '%s';" % x2)

    print('\nQ. Volume')
    db.sql("""insert into factures (client_id, montant_usd, frais_service_usd, echeance_le)
              select '%s', 20 + (i %% 50), 10, current_date - (i %% 30) from generate_series(1, 3000) i;""" % MARIE)
    debut = time.time()
    jsonq(db, ADMIN, "select public.resume_facturation();")
    duree = time.time() - debut
    verifier('3 000 factures de plus : le résumé en moins d\'une seconde (%.2f s)' % duree, duree < 1, True)
    debut = time.time()
    jsonq(db, ADMIN, "select public.rapport_anomalies_facturation();")
    duree = time.time() - debut
    verifier('… le rapport d\'anomalies en moins de deux (%.2f s)' % duree, duree < 2, True)

    print('\nR. Les deux côtés d\'accord')
    api = open(os.path.join(RACINE, 'assets', 'js', 'api.js'), encoding='utf-8').read()
    moyens_js = api.split('var MOYENS_PAIEMENT = [')[1].split(']')[0]
    verifier('mêmes moyens de paiement dans la base et dans api.js',
             [m.strip().strip("'") for m in moyens_js.split(',')],
             json.loads(un(db, "select to_json(public.moyens_paiement());")))

    n = sum(S.RESULTATS)
    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), n))
    sys.exit(0 if n == len(S.RESULTATS) else 1)


if __name__ == '__main__':
    main()
