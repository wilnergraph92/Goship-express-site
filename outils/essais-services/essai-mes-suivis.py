# -*- coding: utf-8 -*-
"""« Mes colis en route », Phase 4 du suivi universel (outils/supabase-mes-suivis.sql).

Même base jetable et même fausse pg_net que essai-moteur-suivi.py : 17TRACK n'est jamais appelé,
l'essai écrit lui-même ses réponses. On installe la chaîne SANS ce fichier, des clientes annoncent
leurs achats (creer_prealerte, comme l'application), le moteur des Phases 2 et 3 les suit, puis on
pose la migration trois fois et on lit mes_suivis_externes() sous chaque compte :

  A. installation par-dessus une base en service, sans changer une donnée ;
  B. la porte : un fournisseur en essai (pas VERIFIED) ne montre RIEN aux clients ; VERIFIED et en
     service, la carte reçoit le statut, le transporteur, la chronologie — jamais d'adresse ;
  C. chacun ses achats : deux clientes avec le même numéro voient le même suivi, jamais l'autre ;
  D. les messages : pas de numéro, numéro de commande, USPS exclu, pas encore inscrit, refusé ;
  E. arrivé à Miami : la carte nomme le colis GoShip, puis disparaît après 14 jours ; une annulée
     n'apparaît pas ;
  F. fermé : visiteur refusé, tables du suivi toujours illisibles, application mobile inchangée,
     suivi GoShip intact.

    python3 outils/essais-services/essai-mes-suivis.py
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
NOUVEAU = 'supabase-mes-suivis.sql'
travailler, repondre, requete_de = M.travailler, M.repondre, M.requete_de
accepte, info, ev, tourner, prealerte = M.accepte, M.info, M.ev, Y.tourner, Y.prealerte


def mes(db, compte):
    """Ce que lit la page « Mon compte » : la réponse de mes_suivis_externes(), sous ce compte."""
    return jsonq(db, compte, "select public.mes_suivis_externes();")


def achat(r, numero):
    return next((a for a in r['achats'] if a['numero_suivi'] == numero), None)


def resume(r):
    return ' '.join('%s:%s' % (a['numero_suivi'] or '-', a['message'] or (a['suivi'] or {}).get('statut') or '-')
                    for a in r['achats'])


def main():
    db = S.Base()
    db.sql(S.DOUBLURES)

    print('A. Installation par-dessus une base en service')
    verifier('ce fichier est dans la chaîne officielle, après supabase-synchro-suivi.sql',
             CHAINE[CHAINE.index(NOUVEAU) - 1] if NOUVEAU in CHAINE else None, 'supabase-synchro-suivi.sql')
    for f in CHAINE[:CHAINE.index(NOUVEAU)]:
        db.fichier(M.chemin(f))
    for uid, email, nom in ((ADMIN, 'equipe@goship.test', 'Ada Admin'), (EMPLOYE, 'employe@goship.test', 'Emma Employée'),
                            (GERANT, 'gerant@goship.test', 'Gaston Gérant'), (MARIE, 'marie@exemple.com', 'Marie-Ange Dorvil'),
                            (JEAN, 'jean@exemple.com', 'Jean Pierre')):
        db.sql("""insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
                  values ('%s', '%s', now(), '{"nom_complet":"%s","pays":"HT","ville":"Pétion-Ville",
                          "telephone":"+509 3000 0000"}'::jsonb);""" % (uid, email, nom))
    db.sql("select public.definir_admin('equipe@goship.test');")
    jsonq(db, ADMIN, "select public.changer_role('employe@goship.test', 'employe');")
    db.sql("select public.definir_reglage('suivi_17track_cle', 'cle-essai-17track');")
    # Comme en production aujourd'hui : 17TRACK en essai, pas encore VERIFIED ; les pré-alertes suivies
    jsonq(db, ADMIN, "select public.regler_fournisseur_suivi('17track', '{\"conformite\": \"PENDING_VERIFICATION\", "
                     "\"essai\": true, \"plafond_essai\": 30, \"marge_quota\": 20, \"suivre_prealertes\": true, "
                     "\"plafond_mensuel\": 30}');")
    # Marie : un achat GOFO (le même numéro que Jean), un USPS, un numéro de commande, un sans numéro
    prealerte(db, MARIE, 'GFUS01000000000101', 'Shein')
    prealerte(db, MARIE, '9400100000000000000013', 'Walmart')
    prealerte(db, MARIE, '112-1234567-1234567', 'Amazon')
    prealerte(db, MARIE, '', 'Temu')
    prealerte(db, JEAN, 'GFUS01000000000101', 'Ebay')
    # Le moteur les inscrit et les lit (faux 17TRACK), comme en production
    tourner(db)
    repondre(db, requete_de(db, 'GFUS01000000000101'), 200, {'code': 0, 'data': {
        'accepted': [accepte('GFUS01000000000101', 100996, 3)], 'rejected': []}})
    travailler(db)
    db.sql("update suivis_externes set prochaine_synchro_le = now() - interval '1 second' where etape = 'lecture';")
    tourner(db)
    repondre(db, requete_de(db, 'GFUS01000000000101'), 200, {'code': 0, 'data': {'accepted': [
        info('GFUS01000000000101', 100996, 'InTransit', 'InTransit_Other', [
            ev('2026-11-11T09:00:00Z', 'Arrived at sort facility', 'Doral, FL, US', 'InTransit_Arrival'),
            ev('2026-11-10T10:00:00Z', 'Picked up', 'Ontario, CA, US', 'InTransit_PickedUp')],
             edd={'source': 'Official', 'from': '2026-11-14T00:00:00Z', 'to': '2026-11-14T00:00:00Z'})],
        'rejected': []}})
    travailler(db)
    verifier('avant la migration : un suivi lu (en route), deux numéros écartés par le moteur',
             un(db, "select string_agg(numero || ':' || etat || ':' || coalesce(statut, coalesce(code_resultat, '-')), ' ' "
                    "order by numero) from suivis_externes;"),
             '112-1234567-1234567:arrete:ORDER_NUMBER_DETECTED 9400100000000000000013:arrete:UNSUPPORTED_TRACKING '
             'GFUS01000000000101:actif:IN_TRANSIT')
    verifier('une seule fiche de suivi pour les deux pré-alertes du même numéro',
             un(db, "select count(distinct suivi_externe_id) || '/' || count(*) from prealertes "
                    "where suivi_transporteur = 'GFUS01000000000101';"), '1/2')
    interne = M.suivi_interne(db)
    forme_mobile = sorted(prealerte(db, JEAN, 'GFUS01000000000100', 'Nike').keys())
    db.sql("update prealertes set statut = 'annulee' where suivi_transporteur = 'GFUS01000000000100';")
    avant = M.empreintes(db)
    for _ in range(3):
        db.fichier(M.chemin(NOUVEAU))
    verifier('la migration s\'installe, puis se relance deux fois sans erreur', 'oui', 'oui')
    verifier('aucune donnée n\'a changé (%d tables)' % len(avant), M.empreintes(db), avant)
    verifier('le suivi GoShip : colis, historique, notifications identiques', M.suivi_interne(db), interne)
    verifier('le contrôle de fin de fichier : 1 | false | true',
             un(db, "select (select count(*) from pg_proc where proname = 'mes_suivis_externes' and pronamespace = "
                    "'public'::regnamespace) || '|' || has_function_privilege('anon', 'public.mes_suivis_externes()', "
                    "'execute') || '|' || not exists (select 1 from pg_policies where schemaname = 'public' and tablename in "
                    "('suivis_externes', 'suivis_externes_evenements', 'suivis_externes_journal', 'fournisseurs_suivi'));"),
             '1|false|true')

    print('\nB. La porte : rien ne sort d\'un fournisseur pas VERIFIED')
    r = mes(db, MARIE)
    verifier('fournisseur en essai : 4 cartes, aucune ne reçoit le suivi du transporteur',
             [len(r['achats']), [a['suivi'] for a in r['achats']]], [4, [None] * 4])
    verifier('… et chacune son message (jamais un statut du transporteur)', resume(r),
             '-:NO_TRACKING 112-1234567-1234567:ORDER_NUMBER_DETECTED '
             '9400100000000000000013:UNSUPPORTED_TRACKING GFUS01000000000101:UNSUPPORTED_TRACKING')
    db.sql("update fournisseurs_suivi set conformite = 'VERIFIED', actif = true, essai = false where code = '17track';")
    r = mes(db, MARIE)
    a = achat(r, 'GFUS01000000000101')
    verifier('VERIFIED et en service : la carte reçoit le statut, plus de message',
             [a['message'], a['suivi']['statut'], a['suivi']['transporteur'], a['suivi']['transporteur_nom']],
             [None, 'IN_TRANSIT', 'gofo', 'GOFO'])
    verifier('dernier lieu, date prévue par le transporteur, date de lecture, en cours',
             [a['suivi']['dernier_lieu'], a['suivi']['livraison_estimee_le'], a['suivi']['mis_a_jour_le'] is not None,
              a['suivi']['termine']], ['Doral, FL, US', '2026-11-14', True, False])
    verifier('la chronologie : du plus récent au plus ancien, texte d\'origine',
             [(e['description'], e['lieu'], e['statut'], e['pays']) for e in a['suivi']['evenements']],
             [('Arrived at sort facility', 'Doral, FL, US', 'IN_TRANSIT', 'US'),
              ('Picked up', 'Ontario, CA, US', 'IN_TRANSIT', 'US')])
    texte = json.dumps(r, ensure_ascii=False)
    verifier('aucune adresse du destinataire, aucun code postal, aucune clé interne',
             [M.RUE in texte, '33122' in texte, 'empreinte' in texte, 'requete' in texte, 'fournisseur' in texte],
             [False] * 5)
    verifier('les autres cartes : mêmes messages qu\'avant (nos propres constats)', resume(r),
             '-:NO_TRACKING 112-1234567-1234567:ORDER_NUMBER_DETECTED '
             '9400100000000000000013:UNSUPPORTED_TRACKING GFUS01000000000101:IN_TRANSIT')
    verifier('les champs de la pré-alerte, tels que la cliente les a saisis',
             [a['magasin'], a['description'], a['service'], float(a['valeur_usd']), a['statut'], a['colis']],
             ['Shein', 'Robe', 'aerien', 25.0, 'attente', None])

    print('\nC. Chacun ses achats')
    rj = mes(db, JEAN)
    verifier('Jean : une carte, la sienne (Ebay), avec le même suivi du transporteur',
             [len(rj['achats']), rj['achats'][0]['magasin'], rj['achats'][0]['suivi']['statut'],
              len(rj['achats'][0]['suivi']['evenements'])], [1, 'Ebay', 'IN_TRANSIT', 2])
    tj = json.dumps(rj, ensure_ascii=False)
    verifier('… sans rien de Marie : ni son nom, ni ses magasins, ni ses pré-alertes',
             ['Marie' in tj, 'Shein' in tj, 'Walmart' in tj, MARIE in tj,
              any(x['id'] in tj for x in r['achats'])], [False] * 5)
    verifier('et Marie ne voit rien de Jean', ['Jean' in texte, 'Ebay' in texte, JEAN in texte], [False] * 3)
    verifier('un compte de l\'équipe sans pré-alerte : aucune carte (pas celles des clients)',
             [len(mes(db, EMPLOYE)['achats']), len(mes(db, ADMIN)['achats'])], [0, 0])

    print('\nD. Les messages du moteur')
    prealerte(db, MARIE, 'GFUS01000000000102', 'Target')
    a = achat(mes(db, MARIE), 'GFUS01000000000102')
    verifier('pas encore inscrit : la carte reçoit un suivi vide, sans message',
             [a['message'], a['suivi']['statut'], a['suivi']['evenements']], [None, None, []])
    tourner(db)
    repondre(db, requete_de(db, 'GFUS01000000000102'), 200, {'code': 0, 'data': {
        'accepted': [], 'rejected': [M.rejete('GFUS01000000000102', -18010012, 'Invalid number.')]}})
    travailler(db)
    a = achat(mes(db, MARIE), 'GFUS01000000000102')
    verifier('refusé par le transporteur : INVALID_TRACKING', [a['message'], a['suivi']['termine'] is not None],
             ['INVALID_TRACKING', True])
    db.sql("insert into suivis_externes_evenements (suivi_id, survenu_le, description, empreinte) "
           "select s.id, now() - (g || ' minutes')::interval, 'Scan ' || g, 'empreinte-essai-' || g "
           "from suivis_externes s, generate_series(1, 105) g where s.numero = 'GFUS01000000000101';")
    verifier('la chronologie : 100 événements au plus',
             len(achat(mes(db, MARIE), 'GFUS01000000000101')['suivi']['evenements']), 100)
    db.sql("update fournisseurs_suivi set actif = false where code = '17track';")
    verifier('fournisseur éteint : plus rien du transporteur, plus d\'INVALID_TRACKING non plus',
             [achat(mes(db, MARIE), n)['suivi'] is None for n in ('GFUS01000000000101', 'GFUS01000000000102')] +
             [achat(mes(db, MARIE), 'GFUS01000000000102')['message']], [True, True, 'UNSUPPORTED_TRACKING'])
    db.sql("update fournisseurs_suivi set actif = true where code = '17track';")

    print('\nE. Arrivé à Miami, annulé')
    base = {'description': 'Robe', 'poids_lb': 2, 'service': 'aerien', 'pays_destination': 'HT',
            'destination': 'Pétion-Ville', 'expediteur': 'Shein', 'lieu': 'Miami (Medley), FL'}
    colis = creer(db, ADMIN, dict(base, client_id=MARIE, suivi_transporteur='GFUS01000000000101'))
    numero = colis.get('numero') or un(db, "select numero from colis where suivi_transporteur = 'GFUS01000000000101';")
    r = mes(db, MARIE)
    a = achat(r, 'GFUS01000000000101')
    verifier('la pré-alerte de Marie est reçue : la carte nomme son colis GoShip, sans suivi externe',
             [a['statut'], a['colis'], a['suivi'], a['message']], ['recu', {'numero': numero}, None, None])
    verifier('les cartes en attente passent devant les arrivées', r['achats'][-1]['statut'], 'recu')
    b = achat(mes(db, JEAN), 'GFUS01000000000101')
    verifier('Jean, même numéro : toujours en attente, jamais le colis de Marie',
             [b['statut'], b['colis'], numero in json.dumps(b)], ['attente', None, False])
    # La date d'un colis est verrouillée (déclencheur) : le banc la recule, déclencheurs levés le temps d'un update
    db.sql("set session_replication_role = replica; update colis set cree_le = now() - interval '15 days' "
           "where suivi_transporteur = 'GFUS01000000000101';")
    verifier('arrivé depuis plus de 14 jours : la carte disparaît',
             achat(mes(db, MARIE), 'GFUS01000000000101'), None)
    db.sql("update prealertes set statut = 'annulee' where suivi_transporteur = 'GFUS01000000000102';")
    verifier('une pré-alerte annulée n\'apparaît pas', achat(mes(db, MARIE), 'GFUS01000000000102'), None)

    print('\nF. Fermé ; rien d\'autre ne bouge')
    verifier('visiteur : refusé', 'permission denied' in db.erreur(None, 'select public.mes_suivis_externes();'), True)
    verifier('cliente : les tables du suivi restent illisibles',
             all('permission denied' in db.erreur(MARIE, 'select count(*) from public.%s;' % t)
                 for t in ('suivis_externes', 'suivis_externes_evenements', 'fournisseurs_suivi')), True)
    p = jsonq(db, MARIE, "select public.creer_prealerte('7a1e3b52-0000-4000-8000-000000000033', 'Nike', 'Baskets', "
                         "'GFUS01000000000103', 80, 'aerien');")
    verifier('application mobile : creer_prealerte rend la même forme qu\'avant', sorted(p.keys()), forme_mobile)
    db.comme(MARIE, "insert into public.prealertes (magasin, description, suivi_transporteur) "
                    "values ('Zara', 'Veste', 'GFUS01000000000104');")
    verifier('… et l\'insertion directe des anciennes versions marche toujours',
             achat(mes(db, MARIE), 'GFUS01000000000104')['magasin'], 'Zara')
    verifier('aucune écriture : relire la page ne change aucune table',
             (lambda e: [mes(db, MARIE), mes(db, JEAN), M.empreintes(db) == e][-1])(M.empreintes(db)), True)

    ok = sum(S.RESULTATS)
    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), ok))
    sys.exit(0 if ok == len(S.RESULTATS) else 1)


if __name__ == '__main__':
    main()
