# -*- coding: utf-8 -*-
"""Éprouve la lecture des accusés de réception des push (outils/supabase-accuses.sql).

Même base jetable et même fausse pg_net que essai-notifications.py, avec toute la chaîne de
outils/migrations.txt. On installe d'abord la chaîne SANS ce fichier, on envoie des push « à
l'ancienne », puis on installe le fichier DEUX fois. Expo n'est jamais appelé : l'essai écrit
lui-même ses réponses dans net._http_response, comme le ferait pg_net. Ensuite :
  A. les push envoyés avant l'installation ne sont jamais lus ni changés ;
  B. un push accepté il y a plus de 15 minutes est demandé à Expo (getReceipts), par lot ;
     un push plus récent attend ;
  C. accusé « ok » → « livre » ; DeviceNotRegistered → « echec » et le téléphone est oublié,
     sans recopier le message d'Expo (il cite l'identifiant du téléphone) ; les autres
     téléphones restent ; un accusé pas encore prêt est redemandé ;
  D. Expo indisponible, réponse illisible, pas de réponse : rien ne change, c'est redemandé ;
  E. au-delà de 24 heures sans accusé : clos sans changer le statut ;
  F. relancer le fichier ne change aucune donnée, et rien n'est ouvert aux comptes ni aux
     visiteurs ; le moteur des notifications continue d'envoyer.

Depuis la racine du site :

    python3 outils/essais-services/essai-accuses.py
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
NOUVEAU = 'supabase-accuses.sql'
CHAINE = list(N.FICHIERS)


def un(db, texte):
    return N.un(db, texte)


def installer_sans_nouveau():
    db = S.Base()
    db.sql(S.DOUBLURES)
    assert NOUVEAU in CHAINE, "%s n'est pas dans outils/migrations.txt" % NOUVEAU
    for f in CHAINE[:CHAINE.index(NOUVEAU)]:
        db.fichier(os.path.join(OUTILS, f))
    for uid, email, nom, langue, tel in N.COMPTES:
        db.sql("""insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
                  values ('%s', '%s', now(), '{"nom_complet":"%s","pays":"HT","ville":"Pétion-Ville"}'::jsonb);"""
               % (uid, email, nom))
        db.sql("update public.clients set langue = '%s', telephone = '%s' where id = '%s';" % (langue, tel, uid))
    db.sql("select public.definir_admin('equipe@goship.test');")
    return db


def push_acceptes(db, colis_id, prefixe):
    """Le travailleur envoie les push du colis, Expo les accepte (un ticket chacun).
    Rend [(id de l'envoi, ticket)], dans l'ordre."""
    N.travailler(db)
    lignes = db.sql("select e.id from notification_envois e join notifications n on n.id = e.notification_id "
                    "where n.colis_id = '%s' and e.canal = 'push' and e.statut = 'envoi' order by e.id;" % colis_id)
    ids = [l.strip() for l in lignes.splitlines() if l.strip().isdigit()]
    resultat = []
    for k, envoi in enumerate(ids):
        ticket = '%s-%d' % (prefixe, k + 1)
        N.repondre(db, envoi, 200, json.dumps({'data': [{'status': 'ok', 'id': ticket}]}))
        resultat.append((envoi, ticket))
    N.travailler(db)
    return resultat


def statut(db, envoi):
    return un(db, "select statut || '|' || coalesce(code_erreur, '') || '|' || (accuse_requete is not null)::text || '|' "
                  "|| (accuse_le is not null)::text from notification_envois where id = %s;" % envoi)


def lire(db):
    return S.jsonq(db, 'sql', 'select public.lire_accuses_push();')


def derniere_demande(db):
    """(url, ids) de la dernière requête partie vers Expo."""
    ligne = un(db, "select url || '|' || coalesce(body ->> 'ids', '') from net.envois order by id desc limit 1;")
    url, _, ids = ligne.partition('|')
    return url, (json.loads(ids) if ids else [])


def repondre_accuses(db, envoi, code, contenu, erreur=None):
    """La réponse d'Expo à la demande d'accusés en cours pour cet envoi."""
    db.sql("insert into net._http_response (id, status_code, content, error_msg) "
           "select accuse_requete, %s, %s, %s from notification_envois where id = %s;"
           % ('null' if code is None else code, N.q(contenu), N.q(erreur), envoi))


def main():
    db = installer_sans_nouveau()

    print("A0. Installation : la chaîne, des push « à l'ancienne », puis le fichier deux fois")
    db.comme(MARIE, "select public.enregistrer_appareil('ExponentPushToken[marie-iphone]', 'ios', 'fr');")
    db.comme(MARIE, "select public.enregistrer_appareil('ExponentPushToken[marie-android]', 'android', 'fr');")
    db.comme(JEAN, "select public.enregistrer_appareil('ExponentPushToken[jean-android]', 'android', 'ht');")
    ancien = N.creer(db, ADMIN, dict(N.BASE_COLIS, client_id=MARIE, suivi_transporteur='TBAACCUSE0001'))['colis']['id']
    anciens = push_acceptes(db, ancien, 'ancien')
    verifier("avant le fichier : deux push acceptés par Expo pour Marie",
             [un(db, "select statut from notification_envois where id = %s;" % e) for e, _ in anciens],
             ['envoye', 'envoye'])
    # Bien avant toute date d'installation que l'essai simulera plus bas (jusqu'à trois jours)
    db.sql("update notification_envois set envoye_le = now() - interval '4 days', maj_le = now() - interval '4 days' "
           "where id in (%s);" % ','.join(e for e, _ in anciens))
    for _ in range(2):
        db.fichier(os.path.join(OUTILS, NOUVEAU))
    controle = open(os.path.join(OUTILS, NOUVEAU), encoding='utf-8').read().split('-- 6. Contrôle')[1]
    requete = controle[controle.index('select '):].strip().rstrip(';')
    verifier("installé deux fois ; contrôle : 3 colonnes, 1 fonction, fermée, pas de tâche sans pg_cron",
             db.sql('select colonnes, fonction, ouverte_aux_visiteurs, tache from (' + requete + ') x;').splitlines()[-1],
             '3|1|f|0')
    verifier("accuses_depuis posé à l'installation",
             un(db, "select (accuses_depuis > now() - interval '5 minutes')::text from notification_moteur;"), 'true')

    print("\nA. Les push d'avant l'installation ne sont jamais lus ni changés")
    r = lire(db)
    verifier("premier passage : aucune demande à Expo", r['demandes'], 0)
    verifier("les deux anciens push : toujours « envoye », jamais demandés",
             [statut(db, e) for e, _ in anciens], ['envoye||false|false', 'envoye||false|false'])
    # L'installation « il y a deux heures » : les push de la suite sont après elle
    db.sql("update notification_moteur set accuses_depuis = now() - interval '2 hours';")

    print("\nB. Les push acceptés il y a plus de 15 minutes sont demandés à Expo, par lot")
    colis_m = N.creer(db, ADMIN, dict(N.BASE_COLIS, client_id=MARIE, suivi_transporteur='TBAACCUSE0002'))['colis']['id']
    colis_j = N.creer(db, ADMIN, dict(N.BASE_COLIS, client_id=JEAN, suivi_transporteur='TBAACCUSE0003'))['colis']['id']
    marie = push_acceptes(db, colis_m, 'marie')
    jean = push_acceptes(db, colis_j, 'jean')
    verifier("trois push acceptés (deux téléphones de Marie, un de Jean)", len(marie) + len(jean), 3)
    db.sql("update notification_envois set envoye_le = now() - interval '30 minutes', maj_le = now() - interval '30 minutes' "
           "where id in (%s);" % ','.join(e for e, _ in marie + jean))
    recent = N.creer(db, ADMIN, dict(N.BASE_COLIS, client_id=JEAN, suivi_transporteur='TBAACCUSE0004'))['colis']['id']
    (e_recent, t_recent), = push_acceptes(db, recent, 'recent')
    db.sql("update notification_envois set envoye_le = now() - interval '5 minutes', maj_le = now() - interval '5 minutes' "
           "where id = %s;" % e_recent)
    r = lire(db)
    url, ids = derniere_demande(db)
    verifier("une seule requête, vers getReceipts d'Expo", (r['demandes'], url),
             (3, 'https://exp.host/--/api/v2/push/getReceipts'))
    verifier("elle porte les trois tickets, pas celui d'il y a 5 minutes",
             sorted(ids), sorted(t for _, t in marie + jean))
    verifier("en attendant la réponse : toujours « envoye », demande en cours",
             statut(db, marie[0][0]), 'envoye||true|false')
    verifier("un second passage ne redemande pas les mêmes", lire(db)['demandes'], 0)

    print("\nC. Les accusés : ok → livré, DeviceNotRegistered → échec et téléphone oublié")
    (m1, t1), (m2, t2) = marie
    (j1, tj), = jean
    appareil_m2 = un(db, "select appareil_id from notification_envois where id = %s;" % m2)
    reponse = {'data': {
        t1: {'status': 'ok'},
        t2: {'status': 'error', 'message': '"ExponentPushToken[marie-android]" is not a registered push notification recipient',
             'details': {'error': 'DeviceNotRegistered'}},
        # le ticket de Jean manque : accusé pas encore prêt chez Expo
    }}
    repondre_accuses(db, m1, 200, json.dumps(reponse))
    r = lire(db)
    verifier("le passage compte : 1 livré, 1 échec, 1 téléphone oublié",
             (r['livres'], r['echecs'], r['telephones_oublies']), (1, 1, 1))
    verifier("ok → « livre », date de remise posée",
             (statut(db, m1), un(db, "select (livre_le is not null)::text from notification_envois where id = %s;" % m1)),
             ('livre||false|true', 'true'))
    verifier("DeviceNotRegistered → « echec » avec le code d'Expo", statut(db, m2), 'echec|DeviceNotRegistered|false|true')
    verifier("le message d'Expo n'est pas recopié (il cite l'identifiant du téléphone)",
             un(db, "select (position('ExponentPushToken' in coalesce(erreur, '')) = 0)::text from notification_envois where id = %s;" % m2),
             'true')
    verifier("le téléphone désinstallé est oublié", un(db, "select count(*) from appareils where id = '%s';" % appareil_m2), '0')
    verifier("l'autre téléphone de Marie et celui de Jean restent",
             un(db, "select string_agg(jeton, ',' order by jeton) from appareils;"),
             'ExponentPushToken[jean-android],ExponentPushToken[marie-iphone]')
    verifier("Jean : accusé pas encore prêt → toujours « envoye », à redemander", statut(db, j1), 'envoye||false|false')
    verifier("pas redemandé dans la même minute : Expo n'aurait pas eu le temps", lire(db)['demandes'], 0)
    db.sql("update notification_envois set maj_le = now() - interval '5 minutes' where id = %s;" % j1)
    r = lire(db)
    verifier("passage suivant : seul le push de Jean est redemandé", (r['demandes'], derniere_demande(db)[1]), (1, [tj]))
    verifier("un accusé déjà lu ne change plus : relire ne refait rien",
             (statut(db, m1), statut(db, m2)), ('livre||false|true', 'echec|DeviceNotRegistered|false|true'))

    print("\nD. Expo indisponible, réponse illisible, pas de réponse : rien ne change, c'est redemandé")
    for titre, code, contenu, erreur in (("Expo en panne (503)", 503, 'Service Unavailable', None),
                                         ("réponse illisible", 200, 'pas du json', None),
                                         ("réseau coupé", None, None, 'Timeout of 5000 ms reached')):
        repondre_accuses(db, j1, code, contenu, erreur)
        lire(db)
        verifier(titre + " : statut inchangé, rien de perdu", statut(db, j1), 'envoye||false|false')
        db.sql("update notification_envois set maj_le = now() - interval '5 minutes' where id = %s;" % j1)
        lire(db)
        verifier(titre + " : redemandé au passage suivant", statut(db, j1), 'envoye||true|false')
    db.sql("update notification_envois set maj_le = now() - interval '11 minutes' where id = %s;" % j1)
    requete_j1 = un(db, "select accuse_requete from notification_envois where id = %s;" % j1)
    db.sql("delete from net._http_response where id = %s;" % requete_j1)
    lire(db)
    verifier("aucune réponse depuis 10 minutes : la demande est abandonnée", statut(db, j1), 'envoye||false|false')
    db.sql("update notification_envois set maj_le = now() - interval '5 minutes' where id = %s;" % j1)
    lire(db)
    verifier("… et refaite au passage suivant (nouvelle requête)",
             un(db, "select (accuse_requete is not null and accuse_requete <> %s)::text from notification_envois where id = %s;"
                    % (requete_j1, j1)), 'true')

    print("\nE. Au-delà de 24 heures sans accusé : clos sans changer le statut")
    db.sql("update notification_moteur set accuses_depuis = now() - interval '3 days';")
    db.sql("update notification_envois set envoye_le = now() - interval '25 hours' where id = %s;" % j1)
    repondre_accuses(db, j1, 200, json.dumps({'data': {}}))
    r = lire(db)
    verifier("toujours pas d'accusé après 24 h : clos, statut « envoye » gardé", statut(db, j1), 'envoye||false|true')
    verifier("le passage le compte comme clos sans accusé", r['clos_sans_accuse'] >= 1, True)
    verifier("les anciens push d'avant l'installation, eux, sont restés intacts",
             [statut(db, e) for e, _ in anciens], ['envoye||false|false', 'envoye||false|false'])
    db.sql("update notification_moteur set accuses_depuis = now() - interval '2 hours';")

    print("\nF. Relancer le fichier, droits, moteur des notifications")
    avant = db.sql("select md5(string_agg(id || statut || coalesce(code_erreur, '') || coalesce(accuse_le::text, ''), ',' order by id)) "
                   "|| (select accuses_depuis::text from notification_moteur) from notification_envois;").splitlines()[-1]
    db.fichier(os.path.join(OUTILS, NOUVEAU))
    apres = db.sql("select md5(string_agg(id || statut || coalesce(code_erreur, '') || coalesce(accuse_le::text, ''), ',' order by id)) "
                   "|| (select accuses_depuis::text from notification_moteur) from notification_envois;").splitlines()[-1]
    verifier("relancer le fichier ne change ni les envois ni la date d'installation", apres, avant)
    verifier("un visiteur ne peut pas l'appeler", db.erreur(None, 'select public.lire_accuses_push();')[:17], 'permission denied')
    verifier("un client non plus", db.erreur(MARIE, 'select public.lire_accuses_push();')[:17], 'permission denied')
    verifier("un administrateur non plus (seule la tâche planifiée l'appelle)",
             db.erreur(ADMIN, 'select public.lire_accuses_push();')[:17], 'permission denied')
    nouveau = N.creer(db, ADMIN, dict(N.BASE_COLIS, client_id=MARIE, suivi_transporteur='TBAACCUSE0005'))['colis']['id']
    N.travailler(db)
    verifier("le moteur envoie toujours : le push du nouveau colis part vers le téléphone restant",
             un(db, "select count(*) from notification_envois e join notifications n on n.id = e.notification_id "
                    "where n.colis_id = '%s' and e.canal = 'push' and e.statut = 'envoi';" % nouveau), '1')

    print()
    print('%d vérifications, %d réussies.' % (len(S.RESULTATS), sum(S.RESULTATS)))
    sys.exit(0 if all(S.RESULTATS) else 1)


if __name__ == '__main__':
    main()
