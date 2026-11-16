# -*- coding: utf-8 -*-
"""Le battement de cœur de la base vers Healthchecks.io (outils/supabase-battement.sql, lot 1).

Base jetable et fausse pg_net, comme les autres bancs : Healthchecks n'est jamais appelé, on lit
ce que la base AURAIT envoyé (net.envois). pg_cron est représenté par ses deux tables (cron.job,
cron.job_run_details), pour éprouver la lecture des tâches en échec.

  A. installation par-dessus une base en service, sans changer une donnée ;
  B. sans adresse, ou avec une adresse qui n'est pas celle de Healthchecks : rien ne part ;
  C. tout va bien : un appel à l'adresse, avec l'état (aucune donnée de client) ;
  D. la file des notifications en retard, ou une tâche « goship-… » en échec : un appel à /fail,
     avec la raison ; une tâche en échec il y a plus de 35 minutes ne compte plus ;
  E. personne d'autre que la tâche planifiée (et le SQL Editor) ne l'appelle ;
  F. la chaîne officielle connaît le fichier.

    python3 outils/essais-services/essai-battement.py
"""
import importlib.util
import json
import os
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location('essai_moteur', os.path.join(ICI, 'essai-moteur-suivi.py'))
M = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(M)
S = M.S

ADMIN, MARIE = S.ADMIN, M.MARIE
verifier, un = S.verifier, S.un
CHAINE = M.CHAINE
NOUVEAU = 'supabase-battement.sql'
HC = 'https://hc-ping.com/0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0'

# Les deux tables de pg_cron que battement() lit
DOUBLURE_CRON = """
create schema if not exists cron;
create table if not exists cron.job (jobid bigint primary key, jobname text);
create table if not exists cron.job_run_details (runid bigint generated always as identity primary key,
  jobid bigint, status text, start_time timestamptz);
insert into cron.job values (1, 'goship-notifications'), (2, 'goship-suivi-externe'), (3, 'goship-battement'),
                            (4, 'autre-tache');
"""


def battement(db):
    return json.loads(un(db, "select public.battement();"))


def dernier_envoi(db):
    ligne = un(db, "select coalesce((select json_build_object('url', url, 'body', body)::text "
                   "from net.envois order by id desc limit 1), 'null');")
    return json.loads(ligne)


def envois(db):
    return int(un(db, "select count(*) from net.envois;"))


def main():
    db = S.Base()
    db.sql(S.DOUBLURES)

    print('A. Installation par-dessus une base en service')
    verifier('ce fichier est dans la chaîne officielle, après supabase-double-auth.sql',
             CHAINE[CHAINE.index(NOUVEAU) - 1] if NOUVEAU in CHAINE else None, 'supabase-double-auth.sql')
    for f in CHAINE[:CHAINE.index(NOUVEAU)]:
        db.fichier(M.chemin(f))
    db.sql("""insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
              values ('%s', 'equipe@goship.test', now(), '{"nom_complet":"Ada Admin","pays":"HT"}'::jsonb),
                     ('%s', 'marie@exemple.com', now(), '{"nom_complet":"Marie-Ange Dorvil","pays":"HT"}'::jsonb);"""
           % (ADMIN, MARIE))
    db.sql("select public.definir_admin('equipe@goship.test');")
    # Les tables de pg_cron après la chaîne : posées avant, elles réveilleraient le contrôle
    # d'une migration plus ancienne qui ne tourne que chez Supabase
    db.sql(DOUBLURE_CRON)
    photo = M.empreintes(db)
    for _ in range(3):
        sortie = db.fichier(M.chemin(NOUVEAU))
    verifier('le fichier s\'installe trois fois de suite', 'oui', 'oui')
    verifier('contrôle : 1 fonction | fermée | la tâche (doublure de cron.job) | adresse pas posée',
             [l for l in sortie.splitlines() if '|' in l][-1].replace(' ', ''), '1|f|1|f')
    verifier('aucune table n\'a changé', M.empreintes(db), photo)

    print('\nB. Sans adresse, ou une adresse étrangère : rien ne part')
    avant = envois(db)
    verifier('sans adresse : « non_configure »', battement(db), {'envoye': False, 'raison': 'non_configure'})
    for mauvaise in ('http://hc-ping.com/abc', 'https://exemple.org/hc-ping.com/abc', 'https://hc-ping.com.exemple.org/abc',
                     'https://hc-ping.com/abc?x=1'):
        db.sql("select public.definir_reglage('battement_url', '%s');" % mauvaise)
        verifier('adresse refusée : %s' % mauvaise, battement(db)['raison'], 'adresse_refusee')
    verifier('… et aucun appel n\'est parti', envois(db), avant)

    print('\nC. Tout va bien : un appel à l\'adresse')
    db.sql("select public.definir_reglage('battement_url', '%s/');" % HC)
    r = battement(db)
    e = dernier_envoi(db)
    verifier('envoyé, « prêt »', (r['envoye'], r['pret']), (True, True))
    verifier('à l\'adresse du contrôle (barre finale retirée)', e['url'], HC)
    verifier('le corps : l\'état, rien d\'autre', sorted(e['body']), ['heure', 'notifications', 'pret', 'taches_en_echec'])
    verifier('aucune donnée de client dans le corps',
             any(x in json.dumps(e['body']) for x in ('marie', 'Marie', 'equipe@', MARIE)), False)

    print('\nD. Quelque chose cloche : /fail, avec la raison')
    db.sql("insert into cron.job_run_details (jobid, status, start_time) values "
           "(2, 'failed', now() - interval '5 minutes'), (1, 'succeeded', now() - interval '1 minute'), "
           "(4, 'failed', now() - interval '2 minutes'), (3, 'failed', now() - interval '2 minutes');")
    r = battement(db)
    e = dernier_envoi(db)
    verifier('une tâche de GoShip en échec : /fail', e['url'], HC + '/fail')
    verifier('… qui la nomme (ni les tâches étrangères, ni le battement lui-même)', e['body']['taches_en_echec'],
             ['goship-suivi-externe'])
    db.sql("update cron.job_run_details set start_time = now() - interval '40 minutes' where jobid = 2;")
    battement(db)
    verifier('l\'échec a plus de 35 minutes : de nouveau « prêt »', dernier_envoi(db)['url'], HC)
    # La file des notifications en retard (sante() : un envoi « attente » vieux de plus de 15 minutes)
    if un(db, "select to_regclass('public.notification_envois') is not null;") == 't':
        S.creer(db, ADMIN, {'client_id': MARIE, 'description': 'Robe', 'poids_lb': 2, 'service': 'aerien',
                            'pays_destination': 'HT', 'destination': 'Pétion-Ville', 'lieu': 'Miami (Medley), FL'})
        db.sql("update notification_envois set statut = 'attente', prochain_essai_le = now() - interval '20 minutes' "
               "where id = (select min(id) from notification_envois);")
        battement(db)
        e = dernier_envoi(db)
        verifier('la file des notifications en retard : /fail', (e['url'], e['body']['notifications']),
                 (HC + '/fail', 'en_retard'))
        verifier('… sans l\'adresse de la cliente en attente', 'marie@exemple.com' in json.dumps(e['body']), False)

    print('\nE. Personne d\'autre ne l\'appelle')
    verifier('un compte connecté : refusé', db.erreur(ADMIN, "select public.battement();"),
             'permission denied for function battement')
    verifier('un visiteur : refusé', db.erreur(None, "select public.battement();"), 'permission denied for function battement')
    verifier('l\'adresse reste dans le coffre (aucune lecture directe)',
             db.erreur(ADMIN, "select public.lire_reglage('battement_url');"), 'permission denied for function lire_reglage')

    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), sum(S.RESULTATS)))
    sys.exit(0 if all(S.RESULTATS) else 1)


if __name__ == '__main__':
    main()
