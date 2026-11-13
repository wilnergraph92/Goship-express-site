# -*- coding: utf-8 -*-
"""Les notifications des transporteurs, Phase 5 du suivi universel (outils/supabase-alertes-suivi.sql).

Même base jetable et même fausse pg_net que essai-moteur-suivi.py : 17TRACK n'est jamais appelé,
l'essai écrit lui-même ses réponses. On installe la chaîne SANS ce fichier, des clientes annoncent
leurs achats, le moteur les suit, puis on pose la migration trois fois :

  A. installation par-dessus une base en service, sans changer une donnée ; règles ÉTEINTES ;
  B. éteintes : un « livré » du transporteur ne notifie personne ;
  C. allumées : « livré » notifie chaque cliente qui attend cet achat, une fois, dans sa langue,
     avec le nom de l'achat ; push vers son téléphone ; « en route » ne notifie pas ;
  D. jamais deux fois : le même événement relu, un statut qui revient, un incident après l'autre ;
  E. les trois cas : incident, numéro refusé ; une pré-alerte reçue ou annulée n'est pas prévenue ;
  F. la préférence « colis » coupée sur le téléphone : la notification reste dans les messages,
     le push n'est pas envoyé ; un fournisseur pas VERIFIED et en service : rien ;
  G. le moteur de suivi n'échoue jamais, même quand la notification bute ;
  H. la lecture de l'équipe, les messages du compte, rien d'ouvert aux visiteurs, le suivi GoShip intact.

    python3 outils/essais-services/essai-alertes-suivi.py
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
NOUVEAU = 'supabase-alertes-suivi.sql'
travailler, repondre, requete_de = M.travailler, M.repondre, M.requete_de
accepte, info, ev, tourner, prealerte = M.accepte, M.info, M.ev, Y.tourner, Y.prealerte
TYPES = "('carrier_delivered', 'carrier_issue', 'carrier_invalid')"


def notifs(db, client=None):
    """Les notifications des transporteurs : type:client:nom de l'achat, dans l'ordre."""
    filtre = " and client_id = '%s'" % client if client else ''
    return un(db, "select coalesce(string_agg(type || ':' || (select split_part(email, '@', 1) from clients c "
                  "where c.id = n.client_id) || ':' || coalesce(donnees ->> 'numero', ''), ' | ' order by id), '-') "
                  "from notifications n where type in %s%s;" % (TYPES, filtre))


def statut(db, numero, valeur, code=None):
    """Le moteur range un nouveau statut (comme suivi17_ranger)."""
    db.sql("update suivis_externes set statut = %s%s where numero = %s;"
           % ('null' if valeur is None else q(valeur), ', code_resultat = %s' % q(code) if code else '', q(numero)))


def allumer(db, actif=True):
    for t in ('carrier_delivered', 'carrier_issue', 'carrier_invalid'):
        jsonq(db, ADMIN, "select public.modifier_regle_notification('%s', %s, array['push']);"
                         % (t, 'true' if actif else 'false'))


def main():
    db = S.Base()
    db.sql(S.DOUBLURES)

    print('A. Installation par-dessus une base en service')
    verifier('ce fichier est dans la chaîne officielle, après supabase-mes-suivis.sql',
             CHAINE[CHAINE.index(NOUVEAU) - 1] if NOUVEAU in CHAINE else None, 'supabase-mes-suivis.sql')
    for f in CHAINE[:CHAINE.index(NOUVEAU)]:
        db.fichier(M.chemin(f))
    for uid, email, nom, langue in ((ADMIN, 'equipe@goship.test', 'Ada Admin', 'fr'),
                                    (EMPLOYE, 'employe@goship.test', 'Emma Employée', 'fr'),
                                    (GERANT, 'gerant@goship.test', 'Gaston Gérant', 'fr'),
                                    (MARIE, 'marie@exemple.com', 'Marie-Ange Dorvil', 'ht'),
                                    (JEAN, 'jean@exemple.com', 'Jean Pierre', 'es')):
        db.sql("""insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
                  values ('%s', '%s', now(), '{"nom_complet":"%s","pays":"HT","ville":"Pétion-Ville",
                          "telephone":"+509 3000 0000","langue":"%s"}'::jsonb);""" % (uid, email, nom, langue))
    db.sql("update clients set langue = 'ht' where id = '%s'; update clients set langue = 'es' where id = '%s';"
           % (MARIE, JEAN))
    db.sql("select public.definir_admin('equipe@goship.test');")
    jsonq(db, ADMIN, "select public.changer_role('employe@goship.test', 'employe');")
    db.sql("select public.definir_reglage('suivi_17track_cle', 'cle-essai-17track');")
    jsonq(db, ADMIN, "select public.regler_fournisseur_suivi('17track', '{\"conformite\": \"PENDING_VERIFICATION\", "
                     "\"essai\": true, \"plafond_essai\": 30, \"marge_quota\": 20, \"suivre_prealertes\": true, "
                     "\"plafond_mensuel\": 30}');")
    # Le téléphone de Marie ; Jean n'en a pas
    db.comme(MARIE, "select public.enregistrer_appareil('ExponentPushToken[essai-marie]', 'android', 'ht');")
    # Trois achats suivis : GOFO (Marie et Jean), SwiftX (Marie), un numéro que le transporteur refusera
    prealerte(db, MARIE, 'GFUS01000000000201', 'Shein')
    prealerte(db, JEAN, 'GFUS01000000000201', 'Ebay')
    prealerte(db, MARIE, 'SWX000000000000202', 'Nike')
    prealerte(db, MARIE, 'GFUS01000000000203', 'Temu')
    tourner(db)
    repondre(db, requete_de(db, 'GFUS01000000000201'), 200, {'code': 0, 'data': {
        'accepted': [accepte('GFUS01000000000201', 100996, 3), accepte('SWX000000000000202', 101228, 3)],
        'rejected': [M.rejete('GFUS01000000000203', -18010012, 'Invalid number.')]}})
    travailler(db)
    db.sql("update suivis_externes set prochaine_synchro_le = now() - interval '1 second' where etape = 'lecture';")
    tourner(db)
    repondre(db, requete_de(db, 'GFUS01000000000201'), 200, {'code': 0, 'data': {'accepted': [
        info('GFUS01000000000201', 100996, 'InTransit', 'InTransit_Other',
             [ev('2026-11-11T09:00:00Z', 'Arrived at sort facility', 'Doral, FL, US', 'InTransit_Arrival')]),
        info('SWX000000000000202', 101228, 'InTransit', 'InTransit_Other',
             [ev('2026-11-11T08:00:00Z', 'Departed', 'Ontario, CA, US', 'InTransit_Departure')])], 'rejected': []}})
    travailler(db)
    verifier('avant la migration : deux suivis en route, un numéro refusé, aucune notification de transporteur',
             [un(db, "select string_agg(numero || ':' || coalesce(statut, code_resultat, '-'), ' ' order by numero) "
                     "from suivis_externes;"), un(db, "select count(*) from notifications where type like 'carrier%';")],
             ['GFUS01000000000201:IN_TRANSIT GFUS01000000000203:INVALID_TRACKING SWX000000000000202:IN_TRANSIT', '0'])
    REGLES = ("select count(*) || ':' || md5(string_agg(type || actif || canaux::text, ',' order by type)) "
              "from notification_regles where source <> 'suivi_externe';")
    regles_avant = un(db, REGLES)
    HIST = "select md5(coalesce(string_agg(h::text, '|' order by h.id), '')) from colis_historique h where h.id <= %s;"
    hist_max = un(db, "select coalesce(max(id), 0) from colis_historique;")
    hist_avant = un(db, HIST % hist_max)
    avant = M.empreintes(db, sauf=('notification_regles', 'notification_modeles'))
    for _ in range(3):
        db.fichier(M.chemin(NOUVEAU))
    verifier('la migration s\'installe, puis se relance deux fois sans erreur', 'oui', 'oui')
    verifier('aucune donnée existante n\'a changé (%d tables)' % len(avant),
             M.empreintes(db, sauf=('notification_regles', 'notification_modeles')), avant)
    verifier('le contrôle de fin de fichier : 3 | 0 | 12 | 1 | false',
             un(db, "select (select count(*) from notification_regles where source = 'suivi_externe') || '|' || "
                    "(select count(*) from notification_regles where source = 'suivi_externe' and actif) || '|' || "
                    "(select count(*) from notification_modeles where type in %s) || '|' || "
                    "(select count(*) from pg_trigger where tgname = 'notifier_suivi_externe' and not tgisinternal) "
                    "|| '|' || has_function_privilege('anon', 'public.etat_alertes_suivi()', 'execute');" % TYPES),
             '3|0|12|1|false')
    verifier('les règles d\'avant gardent leur état (13 règles, mêmes canaux)',
             un(db, REGLES), regles_avant)
    # Le fournisseur passe VERIFIED et en service (étape 3 de la Phase 4)
    db.sql("update fournisseurs_suivi set conformite = 'VERIFIED', actif = true, essai = false where code = '17track';")

    print('\nB. Éteintes : personne n\'est prévenu')
    statut(db, 'GFUS01000000000201', 'DELIVERED')
    verifier('« livré » avec les règles éteintes : aucune notification', notifs(db), '-')
    statut(db, 'GFUS01000000000201', 'IN_TRANSIT')

    print('\nC. Allumées : « livré » prévient chaque cliente qui attend l\'achat')
    allumer(db)
    statut(db, 'SWX000000000000202', 'OUT_FOR_DELIVERY')
    verifier('« en livraison » ne notifie pas (pas un cas retenu)', notifs(db), '-')
    statut(db, 'GFUS01000000000201', 'DELIVERED')
    verifier('Marie et Jean, chacun pour son achat : carrier_delivered, avec le nom de l\'achat',
             notifs(db), 'carrier_delivered:marie:Shein — Robe | carrier_delivered:jean:Ebay — Robe')
    textes = json.loads(un(db, "select jsonb_object_agg(c.langue, public.texte_notification(n.type, c.langue, n.donnees)) "
                               "from notifications n join clients c on c.id = n.client_id "
                               "where n.type = 'carrier_delivered';"))
    verifier('le texte dans la langue de chacune, avec l\'achat',
             [textes['ht']['titre'], textes['ht']['message'], textes['es']['titre']],
             ['Transpòtè a livre l',
              'Transpòtè a livre acha ou Shein — Robe. N ap fè w konnen depi depo nou an Miami resevwa l.',
              'Entregado por la transportista'])
    verifier('un push vers le téléphone de Marie (attente) ; Jean, sans téléphone : envoi annulé, rien ne part',
             un(db, "select string_agg(split_part(c.email, '@', 1) || ':' || coalesce(e.canal || '/' || e.statut, 'app'), "
                    "' ' order by c.email) from notifications n join clients c on c.id = n.client_id "
                    "left join notification_envois e on e.notification_id = n.id and e.canal = 'push' "
                    "where n.type = 'carrier_delivered';"), 'jean:push/annule marie:push/attente')
    verifier('aucune donnée du colis ni de facture : la notification ne pointe que sur l\'achat',
             un(db, "select bool_and(colis_id is null and facture_id is null and donnees ? 'prealerte_id') "
                    "from notifications where type like 'carrier%';"), 't')

    print('\nD. Jamais deux fois')
    statut(db, 'GFUS01000000000201', 'DELIVERED')
    db.sql("update suivis_externes set derniere_synchro_le = now() where numero = 'GFUS01000000000201';")
    statut(db, 'GFUS01000000000201', 'IN_TRANSIT')
    statut(db, 'GFUS01000000000201', 'DELIVERED')
    verifier('relu, revenu en route puis livré à nouveau : toujours une seule par cliente',
             un(db, "select count(*) from notifications where type = 'carrier_delivered';"), '2')
    statut(db, 'SWX000000000000202', 'EXCEPTION')
    statut(db, 'SWX000000000000202', 'FAILED_ATTEMPT')
    statut(db, 'SWX000000000000202', 'RETURNED')
    verifier('trois incidents de suite sur le même achat : une seule notification d\'incident',
             notifs(db, MARIE), 'carrier_delivered:marie:Shein — Robe | carrier_issue:marie:Nike — Robe')

    print('\nE. Le numéro refusé ; reçu ou annulé, personne')
    db.sql("update suivis_externes set code_resultat = null where numero = 'GFUS01000000000203';")
    statut(db, 'GFUS01000000000203', None, 'INVALID_TRACKING')
    verifier('numéro refusé : carrier_invalid pour Marie',
             un(db, "select count(*) from notifications where type = 'carrier_invalid' and client_id = '%s';" % MARIE), '1')
    prealerte(db, MARIE, 'GFUS01000000000204', 'Zara')
    prealerte(db, JEAN, 'GFUS01000000000205', 'Gap')
    db.sql("update prealertes set statut = 'annulee' where suivi_transporteur = 'GFUS01000000000204';")
    base = {'description': 'Pantalon', 'poids_lb': 2, 'service': 'aerien', 'pays_destination': 'HT',
            'destination': 'Pétion-Ville', 'expediteur': 'Gap', 'lieu': 'Miami (Medley), FL'}
    creer(db, ADMIN, dict(base, client_id=JEAN, suivi_transporteur='GFUS01000000000205'))
    n0 = un(db, "select count(*) from notifications where type like 'carrier%';")
    for numero in ('GFUS01000000000204', 'GFUS01000000000205'):
        statut(db, numero, 'DELIVERED')
    verifier('une pré-alerte annulée, une déjà reçue à Miami : aucune notification',
             un(db, "select count(*) from notifications where type like 'carrier%';"), n0)

    print('\nF. Préférence coupée ; fournisseur pas en service')
    jsonq(db, MARIE, "select public.regler_preference_notification('colis', 'push', false);")
    prealerte(db, MARIE, 'GFUS01000000000206', 'Asos')
    statut(db, 'GFUS01000000000206', 'EXCEPTION')
    verifier('push coupé pour les colis : la notification est dans les messages, le push est annulé',
             un(db, "select n.type || ':' || coalesce(e.statut, '-') from notifications n "
                    "left join notification_envois e on e.notification_id = n.id and e.canal = 'push' "
                    "where n.donnees ->> 'numero' like 'Asos%';"), 'carrier_issue:annule')
    db.sql("update fournisseurs_suivi set actif = false, essai = true where code = '17track';")
    prealerte(db, JEAN, 'GFUS01000000000207', 'Puma')
    statut(db, 'GFUS01000000000207', 'DELIVERED')
    verifier('fournisseur en essai (pas en service) : aucune notification',
             un(db, "select count(*) from notifications where donnees ->> 'numero' like 'Puma%';"), '0')
    db.sql("update fournisseurs_suivi set actif = true, essai = false where code = '17track';")

    print('\nG. Le moteur de suivi n\'échoue jamais')
    prealerte(db, JEAN, 'GFUS01000000000208', 'Levis')
    db.sql("alter table notifications add constraint essai_panne check (type <> 'carrier_issue') not valid;")
    sortie = db.sql("update suivis_externes set statut = 'EXCEPTION' where numero = 'GFUS01000000000208' "
                    "returning statut;", echec_permis=True)
    db.sql("alter table notifications drop constraint essai_panne;")
    verifier('la notification bute : le statut est quand même rangé, l\'erreur va au journal (code seul)',
             ['EXCEPTION' in sortie and 'ERROR' not in sortie,
              un(db, "select resultat || ':' || code_erreur from suivis_externes_journal "
                     "where operation = 'notification' order by id desc limit 1;")],
             [True, 'erreur:SQLSTATE_23514'])

    print('\nH. Lecture de l\'équipe, messages du compte, fermé aux autres')
    etat = jsonq(db, ADMIN, "select public.etat_alertes_suivi();")
    verifier('etat_alertes_suivi : trois règles allumées, les compteurs, l\'erreur du jour',
             [[(r['type'], r['actif']) for r in etat['regles']], etat['notifications'], etat['erreurs_24h']],
             [[('carrier_delivered', True), ('carrier_invalid', True), ('carrier_issue', True)],
              {'carrier_delivered': 2, 'carrier_invalid': 1, 'carrier_issue': 2}, 1])
    verifier('cliente : etat_alertes_suivi refusé ; visiteur : refusé',
             ['permission' in db.erreur(MARIE, 'select public.etat_alertes_suivi();').lower() or
              'PERMISSION' in db.erreur(MARIE, 'select public.etat_alertes_suivi();'),
              'permission denied' in db.erreur(None, 'select public.etat_alertes_suivi();')], [True, True])
    # Les messages du compte ne montrent une notification que si son push est parti (règle du moteur)
    db.sql("update notification_envois e set statut = 'envoye', envoye_le = now() from notifications n "
           "where n.id = e.notification_id and n.type like 'carrier%%' and n.client_id = '%s' and e.statut = 'attente';"
           % MARIE)
    r = jsonq(db, MARIE, "select public.mon_resume();")
    verifier('les messages du compte de Marie (mon_resume) montrent ses notifications de transporteur',
             sorted({(m['evenement'], m['numero']) for m in r['notifications'] if m['evenement'].startswith('carrier')}),
             [('carrier_delivered', 'Shein — Robe'), ('carrier_invalid', 'Temu — Robe'), ('carrier_issue', 'Nike — Robe')])
    verifier('Marie ne voit rien de Jean', any('Ebay' in json.dumps(m) or 'Levis' in json.dumps(m)
                                              for m in r['notifications']), False)
    verifier('aucune fonction ouverte aux visiteurs',
             un(db, "select has_function_privilege('anon', 'public.notifier_suivi_externe()', 'execute') or "
                    "has_function_privilege('anon', 'public.etat_alertes_suivi()', 'execute');"), 'f')
    verifier('l\'historique GoShip d\'avant : aucune ligne touchée par le moteur ni les notifications',
             un(db, HIST % hist_max), hist_avant)

    ok = sum(S.RESULTATS)
    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), ok))
    sys.exit(0 if ok == len(S.RESULTATS) else 1)


if __name__ == '__main__':
    main()
