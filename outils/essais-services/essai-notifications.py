# -*- coding: utf-8 -*-
"""Les notifications (Phase 11) : événement → règle → notification → envois → statut.

Même base jetable que essai-services.py (jamais la vraie base), avec toutes les
migrations dans l'ordre du README. Les fournisseurs (Expo, Brevo, Meta) ne sont
jamais appelés : la doublure de pg_net garde chaque requête (net.envois), et
l'essai écrit lui-même la « réponse du fournisseur » dans net._http_response,
comme le ferait pg_net — réussite, refus, panne, silence.

    python3 outils/essais-services/essai-notifications.py

Voir LISEZ-MOI.md.
"""
import importlib.util
import json
import os
import sys
import threading
import time

ICI = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location('essai_services', os.path.join(ICI, 'essai-services.py'))
S = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(S)

RACINE = S.RACINE
ADMIN, MARIE, JEAN = S.ADMIN, S.MARIE, S.JEAN
EMPLOYE = 'cccccccc-0000-0000-0000-00000000000c'
GERANT = 'dddddddd-0000-0000-0000-00000000000d'
verifier, jsonq, creer = S.verifier, S.jsonq, S.creer


def un(db, texte):
    """La dernière ligne du résultat — la requête n'est exécutée qu'une fois (S.un l'exécute deux)."""
    sortie = db.sql(texte)
    lignes = [l for l in sortie.splitlines() if l.strip()]
    return lignes[-1].strip() if lignes else ''

FICHIERS = ('supabase.sql', 'supabase-facturation.sql', 'supabase-services.sql', 'supabase-evenements.sql',
            'supabase-scanner.sql', 'supabase-finances.sql', 'supabase-tableau-de-bord.sql',
            'supabase-analytics.sql', 'supabase-mobile.sql', 'supabase-notifications.sql')

COMPTES = (
    (MARIE, 'marie@exemple.com', 'Marie-Ange Dorvil', 'fr', '37011122'),
    (JEAN, 'jean@exemple.com', 'Jean Pierre', 'ht', '37033344'),
    (EMPLOYE, 'employe@goship.test', 'Emma Employée', 'fr', ''),
    (GERANT, 'gerant@goship.test', 'Gary Gérant', 'fr', ''),
    (ADMIN, 'equipe@goship.test', 'Ada Admin', 'fr', ''),
)
BASE_COLIS = {'description': 'Chaussures', 'poids_lb': 4, 'service': 'aerien', 'pays_destination': 'HT',
              'destination': 'Pétion-Ville', 'expediteur': 'Amazon'}


def q(v):
    return 'null' if v is None else "'%s'" % str(v).replace("'", "''")


def op(db, compte, id_colis, type_, lieu=None, note=None, motif=None, cible=None, cle=None):
    return jsonq(db, compte, "select public.executer_operation('%s', %s, %s, %s, '{}'::jsonb, %s, null, %s, %s);"
                 % (id_colis, q(type_), q(lieu), q(note), q(cle), q(cible), q(motif)))


def nombre(db, texte):
    return int(un(db, texte) or 0)


def installer():
    db = S.Base()
    db.sql(S.DOUBLURES)
    for f in FICHIERS:
        db.fichier(os.path.join(RACINE, 'outils', f))
    for uid, email, nom, langue, tel in COMPTES:
        db.sql("""insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
                  values ('%s', '%s', now(), '{"nom_complet":"%s","pays":"HT","ville":"Pétion-Ville"}'::jsonb);"""
               % (uid, email, nom))
        db.sql("update public.clients set langue = '%s', telephone = '%s' where id = '%s';" % (langue, tel, uid))
    db.sql("select public.definir_admin('equipe@goship.test');")
    jsonq(db, ADMIN, "select public.changer_role('employe@goship.test', 'employe');")
    jsonq(db, ADMIN, "select public.changer_role('gerant@goship.test', 'gerant');")
    return db


def envois(db, notification):
    """{canal: (statut, code)} des envois d'une notification (un téléphone suffit ici)."""
    lignes = db.sql("select canal || '|' || statut || '|' || coalesce(code_erreur, '') from notification_envois "
                    "where notification_id = %s order by id;" % notification).splitlines()
    return {l.split('|')[0]: (l.split('|')[1], l.split('|')[2]) for l in lignes if l.strip()}


def repondre(db, envoi, code, contenu, erreur=None):
    """Ce que pg_net écrirait après la réponse (ou le silence) du fournisseur."""
    db.sql("insert into net._http_response (id, status_code, content, error_msg) "
           "select requete, %s, %s, %s from notification_envois where id = %s;"
           % ('null' if code is None else code, q(contenu), q(erreur), envoi))


def travailler(db, lot=None):
    return jsonq(db, 'sql', 'select public.traiter_notifications(%s);' % ('null' if lot is None else lot))


def main():
    db = installer()

    print('A. Installation')
    db.fichier(os.path.join(RACINE, 'outils', 'supabase-notifications.sql'))
    db.fichier(os.path.join(RACINE, 'outils', 'supabase-notifications.sql'))
    fin = open(os.path.join(RACINE, 'outils', 'supabase-notifications.sql')).read().split('-- 16. Contrôle')[1]
    requete = fin[fin.index('select (select count(*) from public.notification_regles)'):].strip().rstrip(';')
    controle = db.sql('select regles, declencheurs, ancien_push, ouvertes_aux_visiteurs from (' + requete + ') x;')
    verifier('rejouable ; contrôle : 13 règles, 2 déclencheurs, ancien push retiré, rien aux visiteurs',
             controle.splitlines()[-1], '13|2|0|f')
    db.sql("update notification_regles set actif = false where type = 'shipment_packed';")
    db.fichier(os.path.join(RACINE, 'outils', 'supabase-notifications.sql'))
    verifier('relancer la migration garde une règle coupée par l\'équipe',
             un(db, "select actif from notification_regles where type = 'shipment_packed';"), 'f')
    db.sql("update notification_regles set actif = true where type = 'shipment_packed';")

    print('B. Un colis, ses étapes, ses notifications')
    db.comme(MARIE, "select public.enregistrer_appareil('ExponentPushToken[marie-iphone]', 'ios', 'fr');")
    db.comme(MARIE, "select public.enregistrer_appareil('ExponentPushToken[marie-android]', 'android', 'fr');")
    r = creer(db, ADMIN, dict(BASE_COLIS, client_id=MARIE, suivi_transporteur='TBANOTIF0001'))
    c1 = r['colis']['id']
    n_recu = un(db, "select id from notifications where colis_id = '%s' and type = 'shipment_received';" % c1)
    verifier('colis enregistré → « shipment_received » dans l\'espace de Marie', n_recu != '', True)
    verifier('un envoi par téléphone (2), e-mail et WhatsApp annulés : canaux non configurés',
             [nombre(db, "select count(*) from notification_envois where notification_id = %s and canal = 'push' "
                         "and statut = 'attente';" % n_recu), envois(db, n_recu).get('email'), envois(db, n_recu).get('whatsapp')],
             [2, ('annule', 'NON_CONFIGURE'), ('annule', 'NON_CONFIGURE')])
    for t, lieu in (('COLIS_EMBALLE', None), ('COLIS_INSPECTE', None), ('COLIS_EXPEDIE', None),
                    ('COLIS_ARRIVE', 'Port-au-Prince'), ('COLIS_TRANSFERE', 'Jacmel'),
                    ('COLIS_DISPONIBLE', 'Agence de Jacmel'), ('COLIS_LIVRE', None)):
        op(db, ADMIN, c1, t, lieu=lieu)
    verifier('chaque étape publique notifie une fois ; l\'inspection interne, jamais',
             db.sql("select string_agg(type, ',' order by id) from notifications where colis_id = '%s' and canal = 'app';" % c1),
             'shipment_received,shipment_packed,shipment_shipped,shipment_arrived,shipment_transferred,'
             'shipment_available,shipment_delivered')
    verifier('« disponible » est prioritaire',
             un(db, "select priorite from notifications where colis_id = '%s' and type = 'shipment_available';" % c1), 'haute')
    r2 = creer(db, ADMIN, dict(BASE_COLIS, client_id=MARIE, suivi_transporteur='TBANOTIF0002'))
    c2 = r2['colis']['id']
    op(db, ADMIN, c2, 'ACTION_REQUISE', note='Adresse incomplète')
    op(db, ADMIN, c2, 'ACTION_RESOLUE', note='Adresse complétée')
    op(db, ADMIN, c2, 'COLIS_EMBALLE')
    op(db, ADMIN, c2, 'CORRECTION', motif='Emballé par erreur')
    verifier('action requise (prioritaire), résolue ; une correction ne notifie pas',
             db.sql("select string_agg(type || ':' || priorite, ',' order by id) from notifications "
                    "where colis_id = '%s' and canal = 'app';" % c2),
             'shipment_received:normale,action_required:haute,action_resolved:normale,shipment_packed:normale')
    avant = nombre(db, "select count(*) from notifications where colis_id = '%s';" % c2)
    op(db, ADMIN, c2, 'ACTION_REQUISE', cle='rejeu-1')
    op(db, ADMIN, c2, 'ACTION_REQUISE', cle='rejeu-1')
    verifier('la même opération rejouée (même clé) : une seule notification',
             nombre(db, "select count(*) from notifications where colis_id = '%s';" % c2) - avant, 1)
    db.sql("update notification_regles set actif = false where type = 'shipment_packed';")
    r3 = creer(db, ADMIN, dict(BASE_COLIS, client_id=JEAN, suivi_transporteur='TBANOTIF0003'))
    c3 = r3['colis']['id']
    op(db, ADMIN, c3, 'COLIS_EMBALLE')
    verifier('règle coupée : aucune notification, l\'étape est bien enregistrée',
             [nombre(db, "select count(*) from notifications where colis_id = '%s' and type = 'shipment_packed';" % c3),
              un(db, "select statut from colis where id = '%s';" % c3)], [0, 'emballe'])
    db.sql("update notification_regles set actif = true where type = 'shipment_packed';")

    print('C. Idempotence')
    cle = "'essai:double'"
    appel = ("select public.creer_notification('shipment_shipped', '%s', %s, '%s', null, null, null, "
             "'{\"numero\":\"GSE-X\"}'::jsonb);" % (MARIE, cle, c1))
    premier, second = un(db, appel), un(db, appel)
    verifier('même clé deux fois : une notification, la seconde répond « déjà traitée » (vide)',
             [premier != '', second, nombre(db, "select count(*) from notifications where cle = %s;" % cle)], [True, '', 1])
    resultats = []
    fils = [threading.Thread(target=lambda: resultats.append(un(db, appel.replace('essai:double', 'essai:concurrent'))))
            for _ in range(6)]
    [f.start() for f in fils]
    [f.join() for f in fils]
    verifier('six traitements simultanés du même événement : une notification, des envois cohérents',
             [nombre(db, "select count(*) from notifications where cle = 'essai:concurrent';"),
              nombre(db, "select count(*) from notification_envois e join notifications n on n.id = e.notification_id "
                         "where n.cle = 'essai:concurrent' and e.canal = 'push';")], [1, 2])

    print('D. Factures et paiements')
    f1 = r['facture']['id']
    verifier('facture créée → « invoice_created », événement de facturation marqué traité',
             [nombre(db, "select count(*) from notifications where facture_id = '%s' and type = 'invoice_created';" % f1),
              un(db, "select count(*) filter (where traite_le is null) from evenements_facturation;")], [1, '0'])
    total = float(un(db, "select montant_usd from factures where id = '%s';" % f1))
    for _ in range(2):
        jsonq(db, ADMIN, "select public.enregistrer_paiement('%s', '{\"montant_usd\": 5, \"moyen\": \"moncash\"}'::jsonb, "
                         "'pay-1');" % f1)
    verifier('paiement partiel (envoyé deux fois, même clé) : une notification, montant de la base',
             db.sql("select string_agg(type || ':' || (donnees->>'montant_usd'), ',') from notifications "
                    "where facture_id = '%s' and type = 'payment_received';" % f1), 'payment_received:5.00')
    jsonq(db, ADMIN, "select public.enregistrer_paiement('%s', '{\"montant_usd\": %s, \"moyen\": \"especes\"}'::jsonb);"
          % (f1, round(total - 5, 2)))
    verifier('le paiement qui solde : « facture payée » seulement (pas deux messages)',
             db.sql("select string_agg(type, ',' order by id) from notifications where facture_id = '%s';" % f1),
             'invoice_created,payment_received,invoice_paid')
    verifier('facture et paiement : texte neutre sur l\'écran verrouillé (règle sensible)',
             un(db, "select sensible from notification_regles where type = 'payment_received';"), 't')

    print('E. Le travailleur : fournisseurs, réponses, nouveaux essais')
    db.sql("select public.definir_reglage('email_cle_api', 'xkeysib-essai-cle-secrete');"
           "select public.definir_reglage('email_expediteur', 'notifications@goship.test');"
           "select public.definir_reglage('whatsapp_jeton', 'EAAG-essai-jeton-secret');"
           "select public.definir_reglage('whatsapp_numero_id', '1234567890');"
           "select public.definir_reglage('site_url', 'https://goship.example/');")
    r4 = creer(db, ADMIN, dict(BASE_COLIS, client_id=MARIE, suivi_transporteur='TBANOTIF0004'))
    c4 = r4['colis']['id']
    for t in ('COLIS_EMBALLE', 'COLIS_EXPEDIE', 'COLIS_ARRIVE'):
        op(db, ADMIN, c4, t, lieu='Port-au-Prince')
    db.sql("delete from notification_envois; delete from net.envois;")  # ne regarder que « disponible »
    op(db, ADMIN, c4, 'COLIS_DISPONIBLE', lieu='Agence de Jacmel')
    n_dispo = un(db, "select id from notifications where colis_id = '%s' and type = 'shipment_available';" % c4)
    verifier('canaux configurés : téléphone (2), e-mail et WhatsApp en attente',
             [nombre(db, "select count(*) from notification_envois where notification_id = %s and statut = 'attente';" % n_dispo),
              sorted(envois(db, n_dispo).keys())], [4, ['email', 'push', 'whatsapp']])
    bilan = travailler(db)
    verifier('un passage : tout est remis au fournisseur, rien encore « envoyé »',
             [bilan['envoyes'] >= 4, nombre(db, "select count(*) from notification_envois where notification_id = %s "
                                               "and statut = 'envoi';" % n_dispo)], [True, 4])
    corps = json.loads(un(db, "select body from net.envois where url like '%%exp.host%%' order by id desc limit 1;"))
    verifier('téléphone : titre et texte dans la langue de Marie, lien vers le colis',
             [corps[0]['title'], corps[0]['data'].get('colis_id') is not None, corps[0]['priority']],
             ['Colis disponible', True, 'high'])
    courriel = json.loads(un(db, "select body from net.envois where url like '%%brevo%%' order by id desc limit 1;"))
    verifier('e-mail : sujet traduit, lien officiel, texte brut de secours',
             [courriel['subject'].startswith('Colis disponible — GSE-'),
              'https://goship.example/mon-compte.html' in courriel['htmlContent'],
              'Bonjour Marie-Ange' in courriel['textContent']], [True, True, True])
    wa = json.loads(un(db, "select body from net.envois where url like '%%graph.facebook%%' order by id desc limit 1;"))
    verifier('WhatsApp : modèle approuvé « colis_disponible », quatre paramètres',
             [wa['template']['name'], len(wa['template']['components'][0]['parameters'])], ['colis_disponible', 4])
    push1, push2 = db.sql("select id from notification_envois where notification_id = %s and canal = 'push' order by id;"
                          % n_dispo).split()
    email = un(db, "select id from notification_envois where notification_id = %s and canal = 'email';" % n_dispo)
    wha = un(db, "select id from notification_envois where notification_id = %s and canal = 'whatsapp';" % n_dispo)
    repondre(db, push1, 200, '{"data":[{"status":"ok","id":"ticket-1"}]}')
    repondre(db, push2, 200, '{"data":[{"status":"error","message":"not registered","details":{"error":"DeviceNotRegistered"}}]}')
    repondre(db, email, 400, '{"code":"invalid_parameter","message":"email is not valid"}')
    repondre(db, wha, 503, 'Service Unavailable')
    travailler(db)
    etat = lambda i: db.sql("select statut || '|' || coalesce(code_erreur, '') || '|' || tentative from notification_envois "
                            "where id = %s;" % i).strip()
    verifier('multi-canal, états indépendants : téléphone envoyé, e-mail refusé, WhatsApp à réessayer',
             [etat(push1), etat(email), etat(wha)], ['envoye||1', 'echec|HTTP_400|1', 'attente|HTTP_503|1'])
    verifier('« envoyé » garde l\'identifiant du fournisseur, jamais « livré » sans preuve',
             db.sql("select message_id || '|' || (livre_le is null) from notification_envois where id = %s;" % push1).strip(),
             'ticket-1|true')
    verifier('téléphone inconnu d\'Expo : envoi en échec, téléphone oublié',
             [etat(push2), nombre(db, "select count(*) from appareils where jeton = 'ExponentPushToken[marie-android]';")],
             ['echec|DeviceNotRegistered|1', 0])
    delai = float(un(db, "select extract(epoch from prochain_essai_le - now()) from notification_envois where id = %s;" % wha))
    verifier('nouvel essai WhatsApp dans ~30 s, pas avant', 20 < delai <= 31, True)
    travailler(db)
    verifier('un passage trop tôt ne renvoie rien', etat(wha), 'attente|HTTP_503|1')
    db.sql("update notification_envois set prochain_essai_le = now() - interval '1 second' where id = %s;" % wha)
    travailler(db)
    repondre(db, wha, 429, 'Too Many Requests')
    travailler(db)
    delai = float(un(db, "select extract(epoch from prochain_essai_le - now()) from notification_envois where id = %s;" % wha))
    verifier('2e essai, limite de débit (429) : nouvel essai dans ~2 min', [etat(wha), 100 < delai <= 121],
             ['attente|HTTP_429|2', True])
    db.sql("update notification_envois set prochain_essai_le = now() - interval '1 second' where id = %s;" % wha)
    travailler(db)
    repondre(db, wha, None, None, 'Timeout of 5000 ms reached')
    travailler(db)
    verifier('3e essai, délai dépassé : abandon, jamais d\'essai infini', etat(wha), 'echec|ABANDON_RESEAU|3')
    db.sql("update notification_envois set prochain_essai_le = now() - interval '1 second' where id = %s;" % wha)
    travailler(db)
    verifier('trois requêtes WhatsApp au total, pas une de plus',
             nombre(db, "select count(*) from net.envois where url like '%%graph.facebook%%';"), 3)
    # Reprise après panne : le fournisseur revient
    r5 = creer(db, ADMIN, dict(BASE_COLIS, client_id=MARIE, suivi_transporteur='TBANOTIF0005'))
    n5 = un(db, "select id from notifications where colis_id = '%s' and type = 'shipment_received';" % r5['colis']['id'])
    e5 = un(db, "select id from notification_envois where notification_id = %s and canal = 'email';" % n5)
    travailler(db)
    repondre(db, e5, 502, 'Bad gateway')
    travailler(db)
    db.sql("update notification_envois set prochain_essai_le = now() where id = %s;" % e5)
    travailler(db)
    repondre(db, e5, 201, '{"messageId":"<brevo-42@smtp>"}')
    travailler(db)
    verifier('panne (502) puis reprise : envoyé au 2e essai, identifiant du fournisseur gardé',
             [etat(e5), un(db, "select message_id from notification_envois where id = %s;" % e5)],
             ['envoye||2', '<brevo-42@smtp>'])
    # Le fournisseur ne répond jamais
    r6 = creer(db, ADMIN, dict(BASE_COLIS, client_id=MARIE, suivi_transporteur='TBANOTIF0006'))
    n6 = un(db, "select id from notifications where colis_id = '%s' and type = 'shipment_received';" % r6['colis']['id'])
    e6 = un(db, "select id from notification_envois where notification_id = %s and canal = 'email';" % n6)
    travailler(db)
    db.sql("update notification_envois set verrouille_le = now() - interval '11 minutes' where id = %s;" % e6)
    travailler(db)
    verifier('silence du fournisseur (10 min) : compté comme un échec temporaire', etat(e6), 'attente|RESEAU|1')

    print('F. Une panne ne bloque jamais l\'opération métier')
    db.sql("alter function net.http_post(text, jsonb, jsonb, jsonb, integer) rename to http_post_ok;"
           "create function net.http_post(url text, body jsonb default '{}'::jsonb, params jsonb default '{}'::jsonb, "
           "headers jsonb default '{}'::jsonb, timeout_milliseconds integer default 5000) returns bigint "
           "language plpgsql as $$ begin raise exception 'pg_net en panne'; end $$;")
    r7 = creer(db, ADMIN, dict(BASE_COLIS, client_id=MARIE, suivi_transporteur='TBANOTIF0007'))
    n7 = un(db, "select id from notifications where colis_id = '%s';" % r7['colis']['id'])
    bilan = travailler(db)
    verifier('pg_net en panne : colis créé, notification créée, envois clos avec leur raison',
             [r7['colis']['numero'].startswith('GSE-'), n7 != '', envois(db, n7)['email'][0]], [True, True, 'echec'])
    db.sql("drop function net.http_post(text, jsonb, jsonb, jsonb, integer);"
           "alter function net.http_post_ok(text, jsonb, jsonb, jsonb, integer) rename to http_post;")
    db.sql("create or replace function public.planifier_envois(p_notification bigint, p_client uuid, p_categorie text, "
           "p_type text, p_priorite text, p_canaux text[]) returns void "
           "language plpgsql as $$ begin raise exception 'moteur cassé'; end $$;")
    r8 = creer(db, ADMIN, dict(BASE_COLIS, client_id=MARIE, suivi_transporteur='TBANOTIF0008'))
    verifier('moteur de notifications cassé : le colis est quand même enregistré, sans notification',
             [r8['colis']['numero'].startswith('GSE-'),
              nombre(db, "select count(*) from notifications where colis_id = '%s';" % r8['colis']['id'])], [True, 0])
    db.fichier(os.path.join(RACINE, 'outils', 'supabase-notifications.sql'))

    print('G. Préférences du client')
    verifier('par défaut, tout est actif', jsonq(db, MARIE, 'select public.mes_preferences_notifications();')
             ['preferences'][0], {'categorie': 'colis', 'push': True, 'email': True, 'whatsapp': True, 'sms': True})
    db.comme(MARIE, "select public.regler_preference_notification('colis', 'email', false);")
    r9 = creer(db, ADMIN, dict(BASE_COLIS, client_id=MARIE, suivi_transporteur='TBANOTIF0009'))
    n9 = un(db, "select id from notifications where colis_id = '%s';" % r9['colis']['id'])
    verifier('e-mail coupé pour les colis : envoi annulé (PREFERENCE), notification dans l\'espace quand même',
             [envois(db, n9)['email'], n9 != ''], [('annule', 'PREFERENCE'), True])
    verifier('le réglage est journalisé', nombre(db, "select count(*) from journal_audit where action = 'notification.preference' "
                                                     "and entite_id = '%s';" % MARIE), 1)
    verifier('réglage inconnu refusé', db.erreur(MARIE, "select public.regler_preference_notification('marketing', 'email', false);"),
             'INVALID_PREFERENCE')
    verifier('canaux : téléphone et e-mail configurés, SMS non (aucun fournisseur)',
             {k: v['configure'] for k, v in jsonq(db, MARIE, 'select public.mes_preferences_notifications();')['canaux'].items()},
             {'push': True, 'email': True, 'whatsapp': True, 'sms': False})

    print('H. Le client : ses notifications, et seulement les siennes')
    m = jsonq(db, MARIE, 'select public.mes_notifications();')
    j = jsonq(db, JEAN, 'select public.mes_notifications();')
    verifier('Marie ne voit que les siennes ; Jean que les siennes',
             [all(e['numero'] is None or e['numero'] != r3['colis']['numero'] for e in m['elements']),
              all(e['numero'] == r3['colis']['numero'] for e in j['elements'] if e['numero'])], [True, True])
    verifier('texte dans la langue du compte (Jean : créole)', j['elements'][-1]['titre'], 'Koli resevwa')
    verifier('… ou dans celle de l\'écran',
             jsonq(db, JEAN, "select public.mes_notifications('toutes', 0, 20, 'en');")['elements'][-1]['titre'],
             'Package received')
    verifier('badge : nombre de non lues donné par la base',
             [m['non_lues'] == m['total'], int(un(db, "select count(*) from notifications where client_id = '%s' and canal = 'app';"
                                                   % MARIE)) == m['total']], [True, True])
    fac = jsonq(db, MARIE, "select public.mes_notifications('factures');")
    verifier('filtre « factures »', sorted({e['categorie'] for e in fac['elements']}), ['factures'])
    verifier('message de paiement : montant mis en forme par la base',
             [e['message'] for e in jsonq(db, MARIE, "select public.mes_notifications('paiements');")['elements']],
             ['Votre paiement de 5,00 $ sur la facture %s a été enregistré.' % r['facture']['numero']])
    ids_jean = db.sql("select array_agg(id) from notifications where client_id = '%s' and canal = 'app';" % JEAN).strip()
    verifier('Marie ne peut pas marquer « lu » les notifications de Jean',
             un(db, "set role authenticated; set request.jwt.claims = '{\"sub\":\"%s\"}'; "
                    "select public.marquer_notifications_lues('%s');" % (MARIE, ids_jean)), '0')
    une = m['elements'][0]['id']
    verifier('marquer une notification lue', un(db, "set role authenticated; set request.jwt.claims = '{\"sub\":\"%s\"}'; "
                                                    "select public.marquer_notifications_lues(array[%s]::bigint[]);" % (MARIE, une)), '1')
    db.comme(MARIE, 'select public.marquer_notifications_lues();')
    verifier('tout marquer lu : badge à zéro', un(db, "set role authenticated; set request.jwt.claims = '{\"sub\":\"%s\"}'; "
                                                      "select public.notifications_non_lues();" % MARIE), '0')
    verifier('Jean garde ses non lues', int(un(db, "set role authenticated; set request.jwt.claims = '{\"sub\":\"%s\"}'; "
                                                   "select public.notifications_non_lues();" % JEAN)) > 0, True)
    verifier('lecture directe de la table : ses lignes seulement (règle de sécurité)',
             un(db, "set role authenticated; set request.jwt.claims = '{\"sub\":\"%s\"}'; "
                    "select count(*) filter (where client_id <> '%s') from notifications;" % (MARIE, MARIE)), '0')
    for titre, texte in (('modifier une notification en direct', "update notifications set lu_le = null where client_id = '%s';" % JEAN),
                         ('créer une notification en direct', "insert into notifications (client_id, canal, evenement) "
                                                              "values ('%s', 'app', 'x');" % MARIE),
                         ('lire les envois', 'select count(*) from notification_envois;'),
                         ('lire les règles', 'select count(*) from notification_regles;'),
                         ('lire les préférences en direct', 'select count(*) from notification_preferences;'),
                         ('déclencher un message', "select public.creer_notification('test', '%s', 'x', null, null, null, "
                                                   "null, '{}'::jsonb, array['email']);" % JEAN),
                         ('lancer le travailleur', 'select public.traiter_notifications();'),
                         ('envoyer un e-mail au HTML de son choix', "select public.envoyer_email_client('%s', 'x', 's', '<b>', 't');" % c1),
                         ('voir le centre des envois', 'select public.centre_notifications();'),
                         ('changer une règle', "select public.modifier_regle_notification('invoice_paid', false, '{}');")):
        err = db.erreur(MARIE, texte)
        verifier('client : %s → refusé' % titre, err != 'aucune' and ('denied' in err or 'PERMISSION' in err or 'REFUS' in err
                                                                    or err.startswith('permission')), True)
    for texte in ('select public.mes_notifications();', 'select public.notifications_non_lues();',
                  'select public.marquer_notifications_lues();', 'select public.mes_preferences_notifications();',
                  'select count(*) from notifications;'):
        verifier('visiteur : %s → refusé' % texte.split('(')[0].replace('select public.', '').replace('select ', ''),
                 db.erreur(None, texte) != 'aucune', True)

    print('I. L\'équipe : permissions de la Phase 6')
    for compte, nom, voit, modifie in ((EMPLOYE, 'employé', False, False), (GERANT, 'gérant', True, False),
                                       (ADMIN, 'administrateur', True, True)):
        vus = [db.erreur(compte, 'select public.centre_notifications();') == 'aucune',
               db.erreur(compte, 'select public.regles_notifications();') == 'aucune']
        change = [db.erreur(compte, "select public.modifier_regle_notification('action_resolved', true, '{push}');") == 'aucune',
                  db.erreur(compte, "select public.tester_notification('push');") == 'aucune']
        verifier('%s : voir envois et règles %s, changer une règle et tester %s' % (nom, 'oui' if voit else 'non',
                                                                                   'oui' if modifie else 'non'),
                 [vus, change], [[voit, voit], [modifie, modifie]])
    verifier('essai : une fois par minute au plus', db.erreur(ADMIN, "select public.tester_notification('push');"),
             'TOO_MANY_TESTS')
    verifier('essai : vers le compte de l\'administrateur seulement',
             db.sql("select string_agg(distinct client_id::text, ',') from notifications where type = 'test';").strip(), ADMIN)
    verifier('règle modifiée et essai journalisés',
             [nombre(db, "select count(*) from journal_audit where action = 'notification.regle';") >= 1,
              nombre(db, "select count(*) from journal_audit where action = 'notification.test';")], [True, 1])
    verifier('canaux inconnus refusés',
             db.erreur(ADMIN, "select public.modifier_regle_notification('invoice_paid', true, '{fax}');"), 'INVALID_RULE')
    centre = jsonq(db, ADMIN, 'select public.centre_notifications();')
    regles = jsonq(db, GERANT, 'select public.regles_notifications();')
    tout = json.dumps([centre, regles, jsonq(db, MARIE, 'select public.mes_preferences_notifications();')])
    verifier('aucune clé de fournisseur dans les réponses (configuré : oui / non)',
             [s in tout for s in ('xkeysib', 'EAAG', '1234567890')] + [regles['canaux']['email'], regles['modifiable']],
             [False, False, False, True, False])
    verifier('centre : totaux par statut et par canal, taux d\'échec',
             [set(centre['par_canal'].keys()) >= {'push', 'email', 'whatsapp'},
              centre['par_canal']['whatsapp']['echec'] >= 1, centre['par_canal']['push']['taux_echec'] is not None],
             [True, True, True])
    suivi = jsonq(db, GERANT, 'select public.suivi_notification(%s);' % n_dispo)
    verifier('« pourquoi n\'a-t-il rien reçu ? » : événement → notification → envois',
             [suivi['evenement']['type'], suivi['notification']['type'],
              sorted({(e['canal'], e['statut']) for e in suivi['envois']})],
             ['COLIS_DISPONIBLE', 'shipment_available',
              [('email', 'echec'), ('push', 'echec'), ('push', 'envoye'), ('whatsapp', 'echec')]])
    verifier('fiche colis du tableau de bord : les envois du colis',
             len(jsonq(db, EMPLOYE, "select public.envois_colis('%s');" % c4)) >= 4, True)

    print('J. Rappels « facture en retard »')
    db.sql("update notification_moteur set actives_depuis = now() - interval '10 days';")
    r10 = creer(db, ADMIN, dict(BASE_COLIS, client_id=JEAN, suivi_transporteur='TBANOTIF0010'))
    r11 = creer(db, ADMIN, dict(BASE_COLIS, client_id=JEAN, suivi_transporteur='TBANOTIF0011'))
    r12 = creer(db, ADMIN, dict(BASE_COLIS, client_id=JEAN, suivi_transporteur='TBANOTIF0012'))
    db.sql("update factures set echeance_le = public.aujourdhui() - 3 where id = '%s';" % r10['facture']['id'])
    db.sql("update factures set echeance_le = public.aujourdhui() - 30 where id = '%s';" % r11['facture']['id'])
    db.sql("update factures set echeance_le = null where id = '%s';" % r12['facture']['id'])
    premier = jsonq(db, 'sql', 'select public.notifications_quotidiennes();')
    second = jsonq(db, 'sql', 'select public.notifications_quotidiennes();')
    verifier('une facture échue après la mise en service : un rappel, une seule fois',
             [premier['rappels'], second['rappels'],
              nombre(db, "select count(*) from notifications where type = 'invoice_overdue' and facture_id = '%s';"
                     % r10['facture']['id'])], [1, 0, 1])
    verifier('échéance d\'avant la mise en service, ou sans échéance : aucun rappel',
             nombre(db, "select count(*) from notifications where type = 'invoice_overdue' and facture_id in ('%s', '%s');"
                    % (r11['facture']['id'], r12['facture']['id'])), 0)

    print('K. Modèles, liens, données sensibles')
    db.comme(MARIE, "select public.regler_preference_notification('colis', 'email', true);")  # l'e-mail revient
    verifier('variable inconnue effacée, jamais interprétée',
             un(db, "select public.rendre_notification('A {{numero}} {{mot_de_passe}} B', '{\"numero\":\"GSE-1\"}');"), 'A GSE-1  B')
    db.sql("delete from notification_envois; delete from net.envois;")
    nid = un(db, "select public.creer_notification('shipment_received', '%s', 'essai:xss', null, null, null, null, "
                 "'{\"numero\":\"<script>alert(1)</script>\"}'::jsonb);" % MARIE)
    travailler(db)
    html = un(db, "select body->>'htmlContent' from net.envois where url like '%%brevo%%' order by id desc limit 1;") or ''
    verifier('e-mail : contenu échappé (aucun <script> ne passe)',
             ['<script>' in html, '&lt;script&gt;' in html], [False, True])
    db.sql("select public.definir_reglage('site_url', 'javascript:alert(1)');")
    db.sql("delete from notification_envois; delete from net.envois;")
    un(db, "select public.creer_notification('shipment_received', '%s', 'essai:lien', null, null, null, null, "
           "'{\"numero\":\"GSE-2\"}'::jsonb);" % MARIE)
    travailler(db)
    html = un(db, "select body->>'htmlContent' from net.envois where url like '%%brevo%%' order by id desc limit 1;") or ''
    verifier('adresse du site non officielle (javascript:) : e-mail parti, sans aucun lien',
             [html != '', 'javascript' in html, 'mon-compte.html' in html], [True, False, False])
    db.sql("select public.definir_reglage('site_url', 'https://goship.example/');")
    db.sql("delete from notification_envois; delete from net.envois;")
    un(db, "select public.creer_notification('payment_received', '%s', 'essai:sensible', null, '%s', null, null, "
           "'{\"facture\":\"F-1\",\"montant_usd\":4250}'::jsonb);" % (MARIE, r['facture']['id']))
    travailler(db)
    push = json.loads(un(db, "select body from net.envois where url like '%%exp.host%%' order by id desc limit 1;"))[0]
    verifier('écran verrouillé : ni montant ni numéro de facture', [push['title'], push['body']],
             ['GoShip Express', 'Une mise à jour concernant votre compte est disponible.'])
    verifier('… lien vers la facture, et vers l\'onglet Factures pour les versions installées',
             [push['data'].get('facture_id') == r['facture']['id'], push['data'].get('route')], [True, '/(onglets)/factures'])
    verifier('les envois ne gardent ni jeton, ni adresse, ni numéro (seulement une cible)',
             db.sql("select count(*) from notification_envois where cible like '%%@%%' or cible like '%%Token%%' "
                    "or cible ~ '[0-9]{8}';").strip(), '0')

    print('L. Les applications déjà installées (mon_resume)')
    db.sql("update notification_envois set statut = 'envoye', envoye_le = now() where canal = 'push';")
    messages = jsonq(db, MARIE, 'select public.mon_resume();')['notifications']
    verifier('mon_resume garde sa forme : canal, évènement, date, numéro',
             sorted(messages[0].keys()), ['canal', 'envoye_le', 'evenement', 'numero'])
    verifier('… sans les notifications « app » (inconnues des versions installées)',
             any(x['canal'] == 'app' for x in messages), False)

    print('M. Volume')
    db.sql("delete from notification_envois; delete from net.envois;")
    t = time.time()
    db.sql("""insert into notifications (client_id, canal, evenement, destinataire, type, categorie, cle, donnees)
              select '%s', 'app', 'shipment_shipped', '', 'shipment_shipped', 'colis', 'volume:' || g,
                     jsonb_build_object('numero', 'GSE-V' || g) from generate_series(1, 1000) g;
              insert into notification_envois (notification_id, canal, cible, fournisseur)
              select n.id, 'push', 'appareil:' || k, 'expo' from notifications n, generate_series(1, 10) k
               where n.cle like 'volume:%%';""" % MARIE)
    verifier('1 000 notifications, 10 000 envois en file', nombre(db, "select count(*) from notification_envois "
                                                                       "where statut = 'attente';"), 10000)
    db.sql("update notification_envois set appareil_id = (select id from appareils where client_id = '%s' limit 1);" % MARIE)
    fils = [threading.Thread(target=lambda: travailler(db, 500)) for _ in range(4)]
    t = time.time()
    [f.start() for f in fils]
    [f.join() for f in fils]
    duree = time.time() - t
    verifier('quatre travailleurs en même temps : 2 000 envois pris, aucun deux fois',
             [nombre(db, "select count(*) from notification_envois where statut = 'envoi';"),
              nombre(db, "select count(*) from (select requete from notification_envois where requete is not null "
                         "group by requete having count(*) > 1) x;"),
              nombre(db, 'select count(*) from net.envois;')], [2000, 0, 2000])
    print('       (4 × 500 envois en %.1f s)' % duree)
    t = time.time()
    jsonq(db, ADMIN, 'select public.centre_notifications();')
    jsonq(db, MARIE, 'select public.mes_notifications();')
    verifier('centre des envois et liste du client, sur 10 000 envois : moins de 2 s', time.time() - t < 2, True)

    print()
    print('%d vérifications, %d réussies.' % (len(S.RESULTATS), sum(S.RESULTATS)))
    sys.exit(0 if all(S.RESULTATS) else 1)


if __name__ == '__main__':
    main()
