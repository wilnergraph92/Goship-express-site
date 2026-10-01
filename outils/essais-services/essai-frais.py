# -*- coding: utf-8 -*-
"""Éprouve les frais de service au regroupement et à l'encaissement
(outils/supabase-frais-service.sql).

Même base jetable et mêmes rôles SQL que essai-services.py, avec toute la chaîne de
outils/migrations.txt. On installe d'abord la chaîne SANS ce fichier, on y crée une
facture à l'ancienne (frais de 10 $ dès l'enregistrement), puis on installe le
fichier deux fois : cette facture ne doit pas bouger d'un centime. Ensuite, les
sept scénarios de la demande :
  1. enregistrer un colis : frais 0 ;
  2. regrouper des colis : frais sur une ligne à part, total juste ;
  3. regrouper puis « Encaisser → Non » : aucun frais ajouté ;
  4. regrouper puis « Encaisser → Oui » : frais ajoutés, une fois ;
  5. frais déjà appliqués au regroupement, puis encaissement : pas de double frais ;
  6. ajouter un colis à une facture existante : total recalculé, frais une fois ;
  7. le même colis deux fois : refusé ;
puis les refus (factures payées, annulées, montants), les permissions des quatre
rôles, la recherche de colis, la sortie d'un regroupement et le rapport d'anomalies.

Depuis la racine du site :

    python3 outils/essais-services/essai-frais.py
"""
import importlib.util
import json
import os
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
# Pas de dossier __pycache__ à côté des essais : il partirait en ligne avec le site.
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location('essai_analytics', os.path.join(ICI, 'essai-analytics.py'))
A = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(A)
S = A.S

RACINE = S.RACINE
OUTILS = os.path.join(RACINE, 'outils')
ADMIN, GERANT, EMPLOYE, MARIE, JEAN = A.ADMIN, A.GERANT, A.EMPLOYE, A.MARIE, A.JEAN
verifier, jsonq, un = S.verifier, S.jsonq, S.un
REFUS = 'PERMISSION_DENIED'
CHAINE = [l.strip() for l in open(os.path.join(OUTILS, 'migrations.txt'), encoding='utf-8')
          if l.strip() and not l.startswith('#')]
FICHIER = 'supabase-frais-service.sql'


def q(v):
    return 'null' if v is None else "'%s'" % str(v).replace("'", "''")


def js(d):
    return "'%s'::jsonb" % json.dumps(d).replace("'", "''")


def ids(liste):
    return "array[%s]::uuid[]" % ','.join(q(i) for i in liste)


def colis(db, poids, client=MARIE, description='Colis', facturer=True, suivi=''):
    r = S.creer(db, ADMIN, {'client_id': client, 'description': description, 'poids_lb': poids, 'service': 'aerien',
                            'pays_destination': 'HT', 'destination': 'Jacmel', 'suivi_transporteur': suivi},
                facturer=facturer)
    return r['colis'], r['facture']


def regrouper(db, factures, colis_ids, frais, cle=None, compte=ADMIN):
    return jsonq(db, compte, "select public.regrouper(%s, %s, %s, %s);"
                 % (ids(factures), ids(colis_ids), 'true' if frais else 'false', q(cle)))


def encaisser(db, facture, montant, frais, cle=None, compte=ADMIN, brut=False):
    texte = ("select public.encaisser_facture('%s', %s, %s, %s);"
             % (facture, js({'montant_usd': montant, 'moyen': 'especes'}), 'true' if frais else 'false', q(cle)))
    return texte if brut else jsonq(db, compte, texte)


def frais(db, facture, appliquer, compte=ADMIN, brut=False):
    texte = "select public.changer_frais_service('%s', %s);" % (facture, 'true' if appliquer else 'false')
    return texte if brut else jsonq(db, compte, texte)


def etat(db, facture):
    """total frais payé solde état statut, tel que la base le calcule"""
    return un(db, "select montant_usd || ' ' || frais_service_usd || ' ' || to_char(public.paye_usd(f), 'FM999990.00') || ' ' || "
                  "public.solde_usd(f) || ' ' || public.etat_paiement(f) || ' ' || statut "
                  "from factures f where id = '%s';" % facture)


def code(db, compte, texte):
    return db.erreur(compte, texte)


def main():
    db = S.Base()
    db.sql(S.DOUBLURES)

    print('A. Installation : la chaîne, puis ce fichier deux fois ; rien ne bouge')
    for f in CHAINE[:CHAINE.index(FICHIER)]:
        db.fichier(os.path.join(OUTILS, f))
    A.comptes(db)
    _, ancienne = colis(db, 4, description='Avant le changement')
    verifier('à l\'ancienne : la facture d\'un colis de 4 lb porte 10 $ de frais (30 $)',
             (ancienne['montant_usd'], ancienne['frais_service_usd']), (30, 10))
    photo = ("select string_agg(numero || ':' || montant_usd || ':' || frais_service_usd || ':' || statut, ',' "
             "order by numero) from factures;")
    avant = un(db, photo)
    for _ in range(2):
        db.fichier(os.path.join(OUTILS, FICHIER))
    verifier('installé deux fois : aucune erreur', 'oui', 'oui')
    verifier('la facture d\'avant n\'a pas bougé d\'un centime', un(db, photo), avant)
    verifier('contrôle de fin de fichier : 4 | faux | 0',
             un(db, "select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace "
                    "where n.nspname = 'public' and p.proname in ('changer_frais_service', 'encaisser_facture', "
                    "'regrouper', 'colis_a_regrouper')) || '|' || (select coalesce(bool_or(has_function_privilege("
                    "'anon', p.oid, 'execute')), false) from pg_proc p join pg_namespace n on n.oid = p.pronamespace "
                    "where n.nspname = 'public' and p.proname in ('changer_frais_service', 'encaisser_facture', "
                    "'regrouper', 'colis_a_regrouper', 'frais_service_interne'));"), '4|false')

    print('\n1. Enregistrer un colis : aucun frais de service')
    c1, f1 = colis(db, 4, description='Chaussures')
    verifier('colis de 4 lb : prix 20 $', c1['prix_usd'], 20)
    verifier('sa facture : 20 $, frais 0, à payer', (f1['montant_usd'], f1['frais_service_usd'], f1['statut']),
             (20, 0, 'a_payer'))
    verifier('une seule ligne, au prix du colis', [l['montant_usd'] for l in f1['facture_lignes']], [20])
    sans, _ = colis(db, 2, description='Sans facture', facturer=False)
    fc = jsonq(db, ADMIN, "select public.facturer_colis('%s');" % sans['id'])['facture']
    verifier('facturer un colis à part : 10 $, frais 0', (fc['montant_usd'], fc['frais_service_usd']), (10, 0))
    verifier('l\'aperçu de la base donne toujours les frais de la maison (10 $) à part',
             [jsonq(db, ADMIN, "select public.calculer_facture(%s);" % ids([c1['id']]))[k]
              for k in ('sous_total', 'frais_service', 'total')], [20, 10, 30])

    print('\n2. Regrouper plusieurs colis : frais sur une ligne à part, total juste')
    ca, fa = colis(db, 4, description='A')
    cb, fb = colis(db, 3, description='B')
    cc, fcc = colis(db, 6, description='C')
    g = regrouper(db, [fa['id'], fb['id'], fcc['id']], [], True, 'reg-1')
    gf = g['facture']
    verifier('20 + 15 + 30 = 65 $ de colis, 10 $ de frais une fois, total 75 $',
             (sorted(l['montant_usd'] for l in gf['facture_lignes']), gf['frais_service_usd'], gf['montant_usd']),
             ([15, 20, 30], 10, 75))
    verifier('les trois anciennes : annulées, remplacées par la nouvelle',
             un(db, "select count(*) from factures where statut = 'annulee' and remplacee_par = '%s';" % gf['id']), '3')
    verifier('rejouée avec la même clé : la même facture, rien de refait',
             (regrouper(db, [fa['id'], fb['id'], fcc['id']], [], True, 'reg-1')['deja'],
              un(db, "select count(*) from factures where cle_idempotence = 'reg-1';")), (True, '1'))
    cd, fd = colis(db, 2, description='D')
    ce, fe = colis(db, 2, description='E')
    g2 = regrouper(db, [fd['id'], fe['id']], [], False)['facture']
    verifier('regroupées sans frais : 10 + 10 = 20 $, frais 0', (g2['montant_usd'], g2['frais_service_usd']), (20, 0))
    verifier('totaux de la base : colis 20, frais 0, total 20, payé 0, solde 20',
             etat(db, g2['id']), '20.00 0.00 0.00 20.00 a_payer a_payer')

    print('\n3. Regrouper puis « Encaisser → Non » : aucun frais ajouté')
    r3 = encaisser(db, g2['id'], 20, False)
    verifier('20 $ encaissés, frais 0, facture payée', etat(db, g2['id']), '20.00 0.00 20.00 0.00 payee payee')
    verifier('frais_ajoutes : non', r3['frais_ajoutes'], False)

    print('\n4. Regrouper puis « Encaisser → Oui » : frais ajoutés une fois')
    cf, ff = colis(db, 2, description='F')
    cg, fg = colis(db, 2, description='G')
    g4 = regrouper(db, [ff['id'], fg['id']], [], False)['facture']
    trop = encaisser(db, g4['id'], 40, True, brut=True)
    verifier('Oui, mais un montant au-delà du nouveau solde (40 > 30) : refusé', code(db, ADMIN, trop), 'OVERPAYMENT')
    verifier('… et les frais ne restent pas ajoutés (tout ou rien)', etat(db, g4['id']),
             '20.00 0.00 0.00 20.00 a_payer a_payer')
    r4 = encaisser(db, g4['id'], 30, True, 'enc-4')
    verifier('Oui : 20 + 10 = 30 $ encaissés, facture payée', etat(db, g4['id']), '30.00 10.00 30.00 0.00 payee payee')
    verifier('frais_ajoutes : oui', r4['frais_ajoutes'], True)
    verifier('rejoué (même clé) : le même paiement, pas de second frais',
             (encaisser(db, g4['id'], 30, True, 'enc-4')['deja'], etat(db, g4['id'])),
             (True, '30.00 10.00 30.00 0.00 payee payee'))

    print('\n5. Frais appliqués au regroupement, puis encaissement : pas de double frais')
    ch, fh = colis(db, 4, description='H')
    ci, fi = colis(db, 3, description='I')
    g5 = regrouper(db, [fh['id'], fi['id']], [], True)['facture']
    verifier('regroupée : 20 + 15 + 10 = 45 $', (g5['montant_usd'], g5['frais_service_usd']), (45, 10))
    r5 = encaisser(db, g5['id'], 20, True)
    verifier('Oui sur une facture qui a déjà ses frais : 45 $ restent 45 $, acompte de 20 $',
             etat(db, g5['id']), '45.00 10.00 20.00 25.00 partielle a_payer')
    verifier('frais_ajoutes : non (déjà inclus)', r5['frais_ajoutes'], False)
    encaisser(db, g5['id'], 25, True)
    verifier('le reste (25 $), encore avec Oui : soldée, frais toujours 10 $', etat(db, g5['id']),
             '45.00 10.00 45.00 0.00 payee payee')
    verifier('changer_frais_service « appliquer » sur une facture qui les a : rien ne change (deja)',
             frais(db, g5['id'], True)['deja'], True)

    print('\n6. Ajouter un colis à une facture existante : recalculée, frais une fois')
    cj, fj = colis(db, 4, description='J')
    ck, fk = colis(db, 2, description='K')
    base6 = regrouper(db, [fj['id'], fk['id']], [], True)['facture']
    verifier('la facture existante : 20 + 10 + 10 de frais = 40 $', base6['montant_usd'], 40)
    cl, fl = colis(db, 6, description='L (avec sa facture)')
    cm, _ = colis(db, 3, description='M (sans facture)', facturer=False)
    g6 = regrouper(db, [base6['id']], [cl['id'], cm['id']], True, 'ajout-6')['facture']
    verifier('+ L (30 $, sa facture entre avec lui) + M (15 $, sans facture) : 4 lignes, 75 + 10 = 85 $',
             (len(g6['facture_lignes']), g6['montant_usd'], g6['frais_service_usd']), (4, 85, 10))
    verifier('la facture existante et celle de L : annulées, renvoyées à la nouvelle',
             un(db, "select string_agg(numero, ',' order by numero) = '%s' from factures where remplacee_par = '%s';"
                % (','.join(sorted([base6['numero'], fl['numero']])), g6['id'])), 't')
    verifier('M est sur la nouvelle facture, une seule fois',
             un(db, "select count(*) from facture_lignes l join factures f on f.id = l.facture_id "
                    "where l.colis_id = '%s' and f.statut <> 'annulee';" % cm['id']), '1')
    cn, fn = colis(db, 2, description='N')
    encaisser(db, fn['id'], 5, False)
    verifier('un colis sur une facture qui a reçu un paiement : refusé',
             code(db, ADMIN, "select public.regrouper(%s, %s, true);" % (ids([g6['id']]), ids([cn['id']]))),
             'INVOICE_ALREADY_EXISTS')
    verifier('un colis sur une facture payée (la 3) : refusé',
             code(db, ADMIN, "select public.regrouper(%s, %s, true);" % (ids([g6['id']]), ids([cd['id']]))),
             'INVOICE_ALREADY_EXISTS')
    co_, _ = colis(db, 2, client=JEAN, description='Chez Jean', facturer=False)
    verifier('un colis d\'un autre client : refusé',
             code(db, ADMIN, "select public.regrouper(%s, %s, true);" % (ids([g6['id']]), ids([co_['id']]))),
             'INVOICE_CLIENT_MISMATCH')
    verifier('rien n\'a bougé après ces refus', etat(db, g6['id']), '85.00 10.00 0.00 85.00 a_payer a_payer')
    cp, _ = colis(db, 2, description='P (sans facture)', facturer=False)
    cq, _ = colis(db, 2, description='Q (sans facture)', facturer=False)
    g6b = regrouper(db, [], [cp['id'], cq['id']], False)['facture']
    verifier('deux colis sans facture, sans frais : une facture de 20 $', (g6b['montant_usd'], g6b['frais_service_usd']),
             (20, 0))

    print('\n7. Le même colis deux fois : bloqué')
    verifier('la facture et un de ses propres colis : rien à ajouter (refusé)',
             code(db, ADMIN, "select public.regrouper(%s, %s, true);"
                  % (ids([g6['id']]), ids([g6['facture_lignes'][0]['colis_id']]))), 'INVALID_INPUT')
    cr, fr = colis(db, 2, description='R')
    cs, fs = colis(db, 2, description='S')
    g7 = regrouper(db, [fr['id'], fs['id']], [cr['id'], cr['id']], True)['facture']
    verifier('R choisi deux fois en plus de sa facture : une seule ligne pour R (2 lignes, 30 $)',
             (len(g7['facture_lignes']), g7['montant_usd']), (2, 30))
    verifier('refacturer un colis déjà sur une facture active : refusé',
             code(db, ADMIN, "select public.creer_facture('%s', %s, %s);" % (MARIE, ids([cr['id']]), js({'frais_service': True}))),
             'INVOICE_ALREADY_EXISTS')
    verifier('aucune facture active ne porte deux fois le même colis',
             un(db, "select count(*) from (select l.colis_id from facture_lignes l join factures f on f.id = l.facture_id "
                    "where f.statut <> 'annulee' group by l.colis_id having count(*) > 1) x;"), '0')

    print('\n8. Ajouter ou retirer les frais depuis la fiche')
    ct, ft = colis(db, 4, description='T')
    frais(db, ft['id'], True)
    verifier('appliquer : 20 + 10 = 30 $', etat(db, ft['id']), '30.00 10.00 0.00 30.00 a_payer a_payer')
    verifier('appliquer encore : deja, toujours 30 $', (frais(db, ft['id'], True)['deja'], etat(db, ft['id'])),
             (True, '30.00 10.00 0.00 30.00 a_payer a_payer'))
    encaisser(db, ft['id'], 25, False)
    verifier('retirer après un acompte de 25 $ : le total (20 $) passerait sous le payé, refusé',
             code(db, ADMIN, frais(db, ft['id'], False, brut=True)), 'INVALID_AMOUNT')
    cu, fu = colis(db, 4, description='U')
    frais(db, fu['id'], True)
    encaisser(db, fu['id'], 20, False)
    frais(db, fu['id'], False)
    verifier('retirer après un acompte de 20 $ : total 20 $, soldée d\'elle-même', etat(db, fu['id']),
             '20.00 0.00 20.00 0.00 payee payee')
    verifier('une facture payée : ses frais ne changent plus',
             code(db, ADMIN, frais(db, fu['id'], True, brut=True)), 'INVOICE_ALREADY_PAID')
    verifier('une facture annulée : refusé', code(db, ADMIN, frais(db, fa['id'], True, brut=True)), 'INVOICE_CANCELLED')
    verifier('écrire les frais dans la table, même en administrateur : refusé',
             code(db, ADMIN, "update factures set frais_service_usd = 0 where id = '%s';" % ft['id']), 'INVOICE_LOCKED')
    verifier('journal : frais appliqués et retirés',
             un(db, "select count(*) filter (where action = 'facture.frais_appliques') || '|' || "
                    "count(*) filter (where action = 'facture.frais_retires') from journal_audit;"), '3|1')

    print('\n9. Sortir un colis d\'un regroupement : les frais ne se doublent pas')
    cv, fv = colis(db, 4, description='V')
    cw, fw = colis(db, 3, description='W')
    cx, fx = colis(db, 2, description='X')
    g9 = regrouper(db, [fv['id'], fw['id'], fx['id']], [], True)['facture']
    verifier('regroupées avec frais : 20 + 15 + 10 + 10 = 55 $', g9['montant_usd'], 55)
    so = jsonq(db, ADMIN, "select public.sortir_du_regroupement('%s', %s, 'sortie-9');" % (g9['id'], ids([cv['id']])))
    verifier('le colis sorti : 20 $, sans frais', (so['facture']['montant_usd'], so['facture']['frais_service_usd']), (20, 0))
    verifier('le reste garde les frais : 15 + 10 + 10 = 35 $', (so['reste']['montant_usd'], so['reste']['frais_service_usd']),
             (35, 10))
    verifier('au total, 55 $ comme avant (aucun frais ajouté)', so['facture']['montant_usd'] + so['reste']['montant_usd'], 55)
    cy, fy = colis(db, 2, description='Y')
    cz, fz = colis(db, 2, description='Z')
    g9b = regrouper(db, [fy['id'], fz['id']], [], False)['facture']
    so2 = jsonq(db, ADMIN, "select public.sortir_du_regroupement('%s', %s);" % (g9b['id'], ids([cy['id']])))
    verifier('un regroupement sans frais : aucune des deux n\'en reçoit',
             (so2['facture']['frais_service_usd'], so2['reste']['frais_service_usd']), (0, 0))

    print('\n10. L\'ancien chemin (regrouper_factures) : frais une fois, comme toujours')
    c10a, f10a = colis(db, 2, description='10a')
    c10b, f10b = colis(db, 2, description='10b')
    old = jsonq(db, ADMIN, "select public.regrouper_factures(%s);" % ids([f10a['id'], f10b['id']]))['facture']
    verifier('10 + 10 + 10 de frais = 30 $', (old['montant_usd'], old['frais_service_usd']), (30, 10))
    verifier('une seule facture : refusé comme avant',
             code(db, ADMIN, "select public.regrouper_factures(%s);" % ids([old['id']])), 'INVALID_INPUT')

    print('\n11. Les colis qu\'on peut ajouter (colis_a_regrouper)')
    c11a, f11a = colis(db, 2, description='Baskets', suivi='1Z999AA10123456784')
    c11b, _ = colis(db, 2, description='Casque', facturer=False)
    liste = jsonq(db, ADMIN, "select public.colis_a_regrouper('%s');" % MARIE)
    nums = [x['numero'] for x in liste]
    verifier('les colis libres et ceux d\'une facture regroupable y sont',
             (c11a['numero'] in nums, c11b['numero'] in nums), (True, True))
    verifier('pas ceux d\'une facture payée (3), ni d\'une facture qui a reçu un paiement (N)',
             (cd['numero'] in nums, cn['numero'] in nums), (False, False))
    verifier('pas ceux d\'un autre client', co_['numero'] in nums, False)
    un11 = [x for x in liste if x['numero'] == c11a['numero']][0]
    verifier('chacun avec sa facture (numéro, total, nombre de colis) ou null',
             (un11['facture']['numero'], un11['facture']['nb_colis'],
              [x for x in liste if x['numero'] == c11b['numero']][0]['facture']), (f11a['numero'], 1, None))
    verifier('recherche par suivi du vendeur',
             [x['numero'] for x in jsonq(db, ADMIN, "select public.colis_a_regrouper('%s', '456784');" % MARIE)],
             [c11a['numero']])
    verifier('recherche par contenu, sans les colis déjà dans la fenêtre',
             jsonq(db, ADMIN, "select public.colis_a_regrouper('%s', 'casque', %s);" % (MARIE, ids([c11b['id']]))), [])

    print('\n12. Les permissions, vérifiées par la base')
    enc = encaisser(db, f11a['id'], 5, True, brut=True)
    for nom, sql in (('regrouper', "select public.regrouper(%s, %s, true);" % (ids([f11a['id']]), ids([c11b['id']]))),
                     ('encaisser_facture (Oui)', enc),
                     ('changer_frais_service', frais(db, f11a['id'], True, brut=True)),
                     ('colis_a_regrouper', "select public.colis_a_regrouper('%s');" % MARIE)):
        verifier('%s : employée et client refusés' % nom, (code(db, EMPLOYE, sql), code(db, MARIE, sql)), (REFUS, REFUS))
        verifier('%s : visiteur refusé' % nom, 'permission denied' in code(db, None, sql), True)
    verifier('gérant : encaisser avec les frais, permis', code(db, GERANT, enc), 'aucune')
    verifier('… frais ajoutés une fois : 10 + 10 = 20 $, 5 $ payés', etat(db, f11a['id']),
             '20.00 10.00 5.00 15.00 partielle a_payer')

    print('\n13. Le rapport d\'anomalies')
    anomalies = jsonq(db, ADMIN, "select public.rapport_anomalies_facturation();")
    types = sorted(set(a['type'] for a in anomalies))
    verifier('aucune erreur (totaux, doublons, payés)', [a for a in anomalies if a['gravite'] == 'erreur'], [])
    verifier('les factures sans frais ne sont plus signalées', 'frais_absents' in types, False)

    ok = sum(1 for r in S.RESULTATS if r)
    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), ok))
    sys.exit(0 if ok == len(S.RESULTATS) else 1)


if __name__ == '__main__':
    main()
