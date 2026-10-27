# -*- coding: utf-8 -*-
"""Éprouve le suivi des e-mails chez Brevo (outils/supabase-suivi-courriels.sql).

Même base jetable et même fausse pg_net que essai-notifications.py, avec toute la chaîne de
outils/migrations.txt. On installe d'abord la chaîne SANS ce fichier, on envoie des e-mails « à
l'ancienne », puis on installe le fichier DEUX fois. Brevo n'est jamais appelé : l'essai écrit
lui-même ses réponses dans net._http_response, comme le ferait pg_net. Ensuite :
  A. les e-mails envoyés avant l'installation ne sont jamais lus ni changés ;
  B. un e-mail accepté il y a plus de 2 minutes est demandé à Brevo (une requête par e-mail) ;
     un plus récent attend ; sans clé Brevo, rien n'est demandé ;
  C. « delivered » → « livre » ; refus de l'expéditeur (la panne du 26/10), adresse
     inexistante, invalide, bloquée → « echec » avec son code, sans recopier le texte de
     Brevo ; rien de définitif → redemandé plus tard, de moins en moins souvent ;
  D. Brevo indisponible, clé refusée, réponse illisible, pas de réponse : rien ne change,
     c'est redemandé ;
  E. au-delà de 72 heures sans réponse définitive : clos sans changer le statut ;
  F. la lecture des accusés des push ne touche pas aux e-mails (et inversement), un autre
     fournisseur n'est pas suivi ; relancer le fichier ne change aucune donnée ; rien n'est
     ouvert aux comptes ni aux visiteurs.

Depuis la racine du site :

    python3 outils/essais-services/essai-suivi-courriels.py
"""
import importlib.util
import json
import os
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
# Pas de dossier __pycache__ à côté des essais : il partirait en ligne avec le site.
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location('essai_notifications', os.path.join(ICI, 'essai-notifications.py'))
N = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(N)
S = N.S

RACINE = S.RACINE
OUTILS = os.path.join(RACINE, 'outils')
ADMIN, MARIE, JEAN = N.ADMIN, N.MARIE, N.JEAN
verifier = S.verifier
NOUVEAU = 'supabase-suivi-courriels.sql'
CHAINE = list(N.FICHIERS)
EVENEMENTS = 'https://api.brevo.com/v3/smtp/statistics/events'

# pg_net sait aussi faire des GET ; la doublure commune n'a que http_post.
HTTP_GET = """
create or replace function net.http_get(url text, params jsonb default '{}'::jsonb,
                                        headers jsonb default '{}'::jsonb, timeout_milliseconds integer default 5000)
returns bigint language sql as $$
  insert into net.envois (url, headers, body) values (url, headers, params) returning id
$$;
"""


def un(db, texte):
    return N.un(db, texte)


def installer_sans_nouveau():
    db = S.Base()
    db.sql(S.DOUBLURES)
    db.sql(HTTP_GET)
    assert NOUVEAU in CHAINE, "%s n'est pas dans outils/migrations.txt" % NOUVEAU
    for f in CHAINE[:CHAINE.index(NOUVEAU)]:
        db.fichier(os.path.join(OUTILS, f))
    for uid, email, nom, langue, tel in N.COMPTES:
        db.sql("""insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
                  values ('%s', '%s', now(), '{"nom_complet":"%s","pays":"HT","ville":"Pétion-Ville"}'::jsonb);"""
               % (uid, email, nom))
        db.sql("update public.clients set langue = '%s', telephone = '%s' where id = '%s';" % (langue, tel, uid))
    db.sql("select public.definir_admin('equipe@goship.test');")
    db.sql("select public.definir_reglage('email_cle_api', 'xkeysib-essai-cle-secrete');"
           "select public.definir_reglage('email_expediteur', 'infos@goship.test');")
    return db


COMPTEUR = [0]


def courriel_accepte(db, client, envoye_il_y_a=None):
    """Un colis pour ce client : son e-mail part, Brevo l'accepte (201 + messageId).
    Rend (id de l'envoi, messageId). envoye_il_y_a : intervalle SQL pour vieillir l'envoi."""
    COMPTEUR[0] += 1
    colis = N.creer(db, ADMIN, dict(N.BASE_COLIS, client_id=client,
                                    suivi_transporteur='TBASUIVI%04d' % COMPTEUR[0]))['colis']['id']
    N.travailler(db)
    envoi = un(db, "select e.id from notification_envois e join notifications n on n.id = e.notification_id "
                   "where n.colis_id = '%s' and e.canal = 'email' and e.statut = 'envoi';" % colis)
    assert envoi.isdigit(), "pas d'e-mail parti pour le colis %s" % colis
    message = '<2026102706%02d.%d@smtp-relay.mailin.fr>' % (COMPTEUR[0], 97064413100 + COMPTEUR[0])
    N.repondre(db, envoi, 201, json.dumps({'messageId': message}))
    N.travailler(db)
    if envoye_il_y_a:
        vieillir(db, envoi, envoye_il_y_a)
    return envoi, message


def vieillir(db, envoi, intervalle):
    db.sql("update notification_envois set envoye_le = now() - interval '%s', maj_le = now() - interval '%s' "
           "where id = %s;" % (intervalle, intervalle, envoi))


def attendre(db, envoi, intervalle):
    """Le temps passe depuis la dernière demande (maj_le)."""
    db.sql("update notification_envois set maj_le = now() - interval '%s' where id = %s;" % (intervalle, envoi))


def statut(db, envoi):
    return un(db, "select statut || '|' || coalesce(code_erreur, '') || '|' || (suivi_requete is not null)::text || '|' "
                  "|| (accuse_le is not null)::text from notification_envois where id = %s;" % envoi)


def lire(db):
    return S.jsonq(db, 'sql', 'select public.lire_suivi_courriels();')


def demandes(db, depuis):
    """[(url, messageId, clé)] des requêtes parties après net.envois.id = depuis."""
    lignes = db.sql("select url || '|' || coalesce(body ->> 'messageId', '') || '|' || coalesce(headers ->> 'api-key', '') "
                    "from net.envois where id > %s order by id;" % depuis).splitlines()
    return [tuple(l.split('|')) for l in lignes if l.strip()]


def dernier_envoi_net(db):
    return int(un(db, 'select coalesce(max(id), 0) from net.envois;') or 0)


def repondre_brevo(db, envoi, code, contenu, erreur=None):
    """La réponse de Brevo à la demande en cours pour cet e-mail."""
    db.sql("insert into net._http_response (id, status_code, content, error_msg) "
           "select suivi_requete, %s, %s, %s from notification_envois where id = %s;"
           % ('null' if code is None else code, N.q(contenu), N.q(erreur), envoi))


def evenements(message, *types, raison=None):
    lignes = []
    for t in types:
        ev = {'email': 'marie@exemple.com', 'date': '2026-10-27T02:21:00.996-04:00', 'messageId': message,
              'event': t, 'subject': 'Colis reçu — GSE-0001', 'from': 'infos@goship.test'}
        if raison and t not in ('requests', 'delivered'):
            ev['reason'] = raison
        lignes.append(ev)
    return json.dumps({'events': lignes})


def main():
    db = installer_sans_nouveau()

    print("A0. Installation : la chaîne, des e-mails « à l'ancienne », puis le fichier deux fois")
    anciens = [courriel_accepte(db, MARIE), courriel_accepte(db, JEAN)]
    verifier("avant le fichier : deux e-mails acceptés par Brevo",
             [un(db, "select statut from notification_envois where id = %s;" % e) for e, _ in anciens],
             ['envoye', 'envoye'])
    # Bien avant toute date d'installation que l'essai simulera plus bas (jusqu'à quatre jours)
    for e, _ in anciens:
        vieillir(db, e, '5 days')
    for _ in range(2):
        db.fichier(os.path.join(OUTILS, NOUVEAU))
    controle = open(os.path.join(OUTILS, NOUVEAU), encoding='utf-8').read().split('-- 6. Contrôle')[1]
    requete = controle[controle.index('select '):].strip().rstrip(';')
    verifier("installé deux fois ; contrôle : 2 colonnes, 1 fonction, fermée, pas de tâche sans pg_cron",
             db.sql('select colonnes, fonction, ouverte_aux_visiteurs, tache from (' + requete + ') x;').splitlines()[-1],
             '2|1|f|0')
    verifier("suivi_courriels_depuis posé à l'installation",
             un(db, "select (suivi_courriels_depuis > now() - interval '5 minutes')::text from notification_moteur;"), 'true')

    print("\nA. Les e-mails d'avant l'installation ne sont jamais lus ni changés")
    r = lire(db)
    verifier("premier passage : aucune demande à Brevo", r['demandes'], 0)
    verifier("les deux anciens e-mails : toujours « envoye », jamais demandés",
             [statut(db, e) for e, _ in anciens], ['envoye||false|false', 'envoye||false|false'])
    # L'installation « il y a deux heures » : les e-mails de la suite sont après elle
    db.sql("update notification_moteur set suivi_courriels_depuis = now() - interval '2 hours';")

    print("\nB. Les e-mails acceptés il y a plus de 2 minutes sont demandés à Brevo")
    livre = courriel_accepte(db, MARIE, '3 minutes')
    expediteur = courriel_accepte(db, JEAN, '3 minutes')
    inexistant = courriel_accepte(db, MARIE, '4 minutes')
    invalide = courriel_accepte(db, JEAN, '4 minutes')
    bloque = courriel_accepte(db, MARIE, '5 minutes')
    suspens = courriel_accepte(db, JEAN, '5 minutes')
    recent = courriel_accepte(db, MARIE, '30 seconds')
    suivis = [livre, expediteur, inexistant, invalide, bloque, suspens]
    db.sql("select public.definir_reglage('email_cle_api', '');")
    depart = dernier_envoi_net(db)
    verifier("sans clé Brevo : rien n'est demandé", (lire(db)['demandes'], demandes(db, depart)), (0, []))
    db.sql("select public.definir_reglage('email_cle_api', 'xkeysib-essai-cle-secrete');")
    r = lire(db)
    parties = demandes(db, depart)
    verifier("six demandes, toutes vers les événements de Brevo, avec la clé",
             (r['demandes'], sorted(set((u, c) for u, _, c in parties))),
             (6, [(EVENEMENTS, 'xkeysib-essai-cle-secrete')]))
    verifier("une par e-mail, par son messageId ; pas celui d'il y a 30 secondes",
             sorted(m for _, m, _ in parties), sorted(m for _, m in suivis))
    verifier("en attendant la réponse : toujours « envoye », demande en cours",
             statut(db, livre[0]), 'envoye||true|false')
    verifier("un second passage ne redemande pas les mêmes", lire(db)['demandes'], 0)

    print("\nC. Les réponses : livré, refusé (et pourquoi), ou rien de définitif")
    raison = 'Sending has been rejected because the sender you used infos@goship.test is not valid. ' \
             'Validate your sender or authenticate your domain'
    repondre_brevo(db, livre[0], 200, evenements(livre[1], 'requests', 'delivered', 'opened'))
    repondre_brevo(db, expediteur[0], 200, evenements(expediteur[1], 'requests', 'error', raison=raison))
    repondre_brevo(db, inexistant[0], 200, evenements(inexistant[1], 'requests', 'hardBounces',
                                                     raison='550 5.1.1 marie@exemple.com: user unknown'))
    repondre_brevo(db, invalide[0], 200, evenements(invalide[1], 'invalid'))
    repondre_brevo(db, bloque[0], 200, evenements(bloque[1], 'requests', 'blocked'))
    repondre_brevo(db, suspens[0], 200, evenements(suspens[1], 'requests', 'softBounces', 'deferred'))
    r = lire(db)
    verifier("le passage compte : 6 réponses, 1 livré, 4 échecs, 1 en attente",
             (r['reponses_lues'], r['livres'], r['echecs'], r['en_attente']), (6, 1, 4, 1))
    verifier("delivered → « livre », date de remise posée",
             (statut(db, livre[0]), un(db, "select (livre_le is not null)::text from notification_envois where id = %s;" % livre[0])),
             ('livre||false|true', 'true'))
    verifier("expéditeur non validé (la panne du 26/10) → « echec » BREVO_EXPEDITEUR",
             statut(db, expediteur[0]), 'echec|BREVO_EXPEDITEUR|false|true')
    verifier("… avec une explication en français, pas le texte de Brevo",
             un(db, "select erreur from notification_envois where id = %s;" % expediteur[0]),
             "Refusé par Brevo : adresse d'expédition non validée")
    verifier("adresse inexistante → ADRESSE_INEXISTANTE", statut(db, inexistant[0]), 'echec|ADRESSE_INEXISTANTE|false|true')
    verifier("le texte du rejet n'est pas recopié (il cite l'adresse du client)",
             un(db, "select (position('exemple.com' in coalesce(erreur, '')) = 0)::text from notification_envois where id = %s;"
                    % inexistant[0]), 'true')
    verifier("adresse invalide → ADRESSE_INVALIDE", statut(db, invalide[0]), 'echec|ADRESSE_INVALIDE|false|true')
    verifier("adresse bloquée → ADRESSE_BLOQUEE", statut(db, bloque[0]), 'echec|ADRESSE_BLOQUEE|false|true')
    verifier("rejet temporaire et retard → toujours « envoye », à redemander", statut(db, suspens[0]), 'envoye||false|false')
    verifier("pas redemandé dans la même minute", lire(db)['demandes'], 0)
    attendre(db, suspens[0], '3 minutes')
    depart = dernier_envoi_net(db)
    r = lire(db)
    verifier("quelques minutes plus tard : seul l'e-mail en suspens est redemandé",
             (r['demandes'], [m for _, m, _ in demandes(db, depart)]), (1, [suspens[1]]))
    repondre_brevo(db, suspens[0], 200, evenements(suspens[1], 'requests', 'softBounces', 'deferred', 'delivered'))
    lire(db)
    verifier("Brevo finit par le remettre → « livre »", statut(db, suspens[0]), 'livre||false|true')
    verifier("un suivi terminé ne change plus : relire ne refait rien",
             [statut(db, e) for e, _ in (livre, expediteur, inexistant)],
             ['livre||false|true', 'echec|BREVO_EXPEDITEUR|false|true', 'echec|ADRESSE_INEXISTANTE|false|true'])
    # L'installation « hier » : un e-mail de 6 heures est après elle
    db.sql("update notification_moteur set suivi_courriels_depuis = now() - interval '1 day';")
    vieux = courriel_accepte(db, MARIE, '6 hours')
    verifier("un e-mail de 6 h jamais suivi est demandé tout de suite",
             (lire(db)['demandes'], statut(db, vieux[0])), (1, 'envoye||true|false'))
    repondre_brevo(db, vieux[0], 200, json.dumps({}))
    lire(db)
    attendre(db, vieux[0], '30 minutes')
    verifier("Brevo n'a encore rien (réponse {}) : un e-mail de 6 h attend une heure avant d'être redemandé",
             (statut(db, vieux[0]), lire(db)['demandes']), ('envoye||false|false', 0))
    attendre(db, vieux[0], '61 minutes')
    verifier("… et l'est passé l'heure", lire(db)['demandes'], 1)

    print("\nD. Brevo indisponible, clé refusée, réponse illisible, pas de réponse : rien ne change")
    for titre, code, contenu, erreur in (("Brevo en panne (503)", 503, 'Service Unavailable', None),
                                         ("clé refusée (401)", 401, '{"code":"unauthorized","message":"Key not found"}', None),
                                         ("réponse illisible", 200, 'pas du json', None),
                                         ("réseau coupé", None, None, 'Timeout of 5000 ms reached')):
        repondre_brevo(db, vieux[0], code, contenu, erreur)
        lire(db)
        verifier(titre + " : statut inchangé, rien de perdu", statut(db, vieux[0]), 'envoye||false|false')
        attendre(db, vieux[0], '61 minutes')
        lire(db)
        verifier(titre + " : redemandé plus tard", statut(db, vieux[0]), 'envoye||true|false')
    requete_vieux = un(db, "select suivi_requete from notification_envois where id = %s;" % vieux[0])
    attendre(db, vieux[0], '11 minutes')
    db.sql("delete from net._http_response where id = %s;" % requete_vieux)
    lire(db)
    verifier("aucune réponse depuis 10 minutes : la demande est abandonnée", statut(db, vieux[0]), 'envoye||false|false')
    attendre(db, vieux[0], '61 minutes')
    lire(db)
    verifier("… et refaite plus tard (nouvelle requête)",
             un(db, "select (suivi_requete is not null and suivi_requete <> %s)::text from notification_envois where id = %s;"
                    % (requete_vieux, vieux[0])), 'true')

    print("\nE. Au-delà de 72 heures sans réponse définitive : clos sans changer le statut")
    db.sql("update notification_moteur set suivi_courriels_depuis = now() - interval '4 days';")
    db.sql("update notification_envois set envoye_le = now() - interval '73 hours' where id = %s;" % vieux[0])
    repondre_brevo(db, vieux[0], 200, evenements(vieux[1], 'requests', 'deferred'))
    r = lire(db)
    verifier("toujours rien de définitif après 72 h : clos, statut « envoye » gardé", statut(db, vieux[0]), 'envoye||false|true')
    verifier("le passage le compte comme clos", r['clos_sans_suivi'] >= 1, True)
    oublie = courriel_accepte(db, JEAN, '73 hours')
    r = lire(db)
    verifier("un e-mail de plus de 72 h jamais demandé (tâche arrêtée) : clos sans demande",
             (statut(db, oublie[0]), r['demandes']), ('envoye||false|true', 0))
    verifier("les anciens e-mails d'avant l'installation, eux, sont restés intacts",
             [statut(db, e) for e, _ in anciens], ['envoye||false|false', 'envoye||false|false'])
    db.sql("update notification_moteur set suivi_courriels_depuis = now() - interval '2 hours';")

    print("\nF. Push et e-mails ne se mêlent pas ; autre fournisseur ; relance ; droits")
    db.sql("update notification_moteur set accuses_depuis = now() - interval '2 hours';")
    db.comme(MARIE, "select public.enregistrer_appareil('ExponentPushToken[marie-iphone]', 'ios', 'fr');")
    colis_p = N.creer(db, ADMIN, dict(N.BASE_COLIS, client_id=MARIE, suivi_transporteur='TBASUIVI9001'))['colis']['id']
    N.travailler(db)
    push = un(db, "select e.id from notification_envois e join notifications n on n.id = e.notification_id "
                  "where n.colis_id = '%s' and e.canal = 'push';" % colis_p)
    courriel = un(db, "select e.id from notification_envois e join notifications n on n.id = e.notification_id "
                      "where n.colis_id = '%s' and e.canal = 'email';" % colis_p)
    N.repondre(db, push, 200, json.dumps({'data': [{'status': 'ok', 'id': 'ticket-marie'}]}))
    N.repondre(db, courriel, 201, json.dumps({'messageId': '<melange@smtp-relay.mailin.fr>'}))
    N.travailler(db)
    for e in (push, courriel):
        vieillir(db, e, '20 minutes')
    S.jsonq(db, 'sql', 'select public.lire_accuses_push();')
    lire(db)
    verifier("chaque tâche a fait sa demande : un accusé Expo pour le push, un suivi Brevo pour l'e-mail",
             un(db, "select (select (accuse_requete is not null and suivi_requete is null)::text from notification_envois where id = %s) "
                    "|| '|' || (select (suivi_requete is not null and accuse_requete is null)::text from notification_envois where id = %s);"
                    % (push, courriel)), 'true|true')
    attendre(db, courriel, '11 minutes')
    db.sql("update notification_envois set maj_le = now() - interval '11 minutes' where id = %s;" % push)
    S.jsonq(db, 'sql', 'select public.lire_accuses_push();')
    verifier("la lecture des accusés des push ne touche pas à la demande de l'e-mail",
             statut(db, courriel), 'envoye||true|false')
    repondre_brevo(db, courriel, 200, evenements('<melange@smtp-relay.mailin.fr>', 'requests', 'delivered'))
    lire(db)
    verifier("… que le suivi des e-mails lit ensuite normalement", statut(db, courriel), 'livre||false|true')
    db.sql("update notification_envois set fournisseur = 'resend' where id = %s;" % oublie[0])
    resend = courriel_accepte(db, JEAN, '10 minutes')
    db.sql("update notification_envois set fournisseur = 'resend' where id = %s;" % resend[0])
    depart = dernier_envoi_net(db)
    lire(db)
    verifier("un e-mail parti par un autre fournisseur (Resend) n'est pas demandé à Brevo",
             (statut(db, resend[0]), demandes(db, depart)), ('envoye||false|false', []))

    avant = db.sql("select md5(string_agg(id || statut || coalesce(code_erreur, '') || coalesce(accuse_le::text, ''), ',' order by id)) "
                   "|| (select suivi_courriels_depuis::text from notification_moteur) from notification_envois;").splitlines()[-1]
    db.fichier(os.path.join(OUTILS, NOUVEAU))
    apres = db.sql("select md5(string_agg(id || statut || coalesce(code_erreur, '') || coalesce(accuse_le::text, ''), ',' order by id)) "
                   "|| (select suivi_courriels_depuis::text from notification_moteur) from notification_envois;").splitlines()[-1]
    verifier("relancer le fichier ne change ni les envois ni la date d'installation", apres, avant)
    verifier("un visiteur ne peut pas l'appeler", db.erreur(None, 'select public.lire_suivi_courriels();')[:17], 'permission denied')
    verifier("un client non plus", db.erreur(MARIE, 'select public.lire_suivi_courriels();')[:17], 'permission denied')
    verifier("un administrateur non plus (seule la tâche planifiée l'appelle)",
             db.erreur(ADMIN, 'select public.lire_suivi_courriels();')[:17], 'permission denied')
    nouveau = N.creer(db, ADMIN, dict(N.BASE_COLIS, client_id=JEAN, suivi_transporteur='TBASUIVI9002'))['colis']['id']
    N.travailler(db)
    verifier("le moteur envoie toujours : l'e-mail du nouveau colis part vers Brevo",
             un(db, "select count(*) from notification_envois e join notifications n on n.id = e.notification_id "
                    "where n.colis_id = '%s' and e.canal = 'email' and e.statut = 'envoi';" % nouveau), '1')

    print()
    print('%d vérifications, %d réussies.' % (len(S.RESULTATS), sum(S.RESULTATS)))
    sys.exit(0 if all(S.RESULTATS) else 1)


if __name__ == '__main__':
    main()
