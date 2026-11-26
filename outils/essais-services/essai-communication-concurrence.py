#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Essais de CONCURRENCE du Communication Center (plan des candidates, §4 : E-01, E-03,
E-07, E-09 ; questions Q2, Q5, Q6 et Q7 de la revue).

Le banc principal (essai-communication-center.py) éprouve chaque chemin seul. Ici,
plusieurs sessions PostgreSQL réelles agissent EN MÊME TEMPS sur la même base :

  E-01  trois portes de sortie ouvertes, puis une demande d'arrêt, puis une
        confirmation : la demande passe sans attendre, la confirmation attend la
        fin des portes, aucune nouvelle porte ne s'ouvre après la demande ;
  E-03  durée de chaque appel de l'arrêt sous charge, comparée aux délais des rôles
        relevés en production (anon 3 s, authenticated 8 s) ;
  Q5    demandes de code WhatsApp simultanées pour un même compte (une seule demande
        ouverte, aucun doublon) et pour deux comptes (deux demandes, deux codes) ;
  E-07  le même STOP reçu deux fois en même temps (un seul enregistrement, un seul
        retrait) ;
  E-09  changement du numéro d'un compte consentant : le consentement ne suit pas.

Base PostgreSQL locale jetable (pgserver), données synthétiques, aucun réseau, aucun
fournisseur. Ces essais ne remplacent pas un ordonnanceur d'entrelacements
(isolationtester) : ils forcent les cas critiques par des sessions réellement
simultanées et des pauses (pg_sleep) tenues à l'intérieur des transactions.
"""
import importlib.util
import os
import subprocess
import sys
import threading
import time

ICI = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location('banc_cc', os.path.join(ICI, 'essai-communication-center.py'))
C = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(C)
S = C.S
verifier = C.verifier


def session_parallele(db, sql):
    """Une vraie session psql indépendante, lancée en arrière-plan."""
    return subprocess.Popen([str(S.PSQL), '-U', db.su, '-h', db.socket, '-d', S.BASE,
                             '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-c', sql],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def attendre_sessions_en_pause(db, nombre, delai=10):
    limite = time.time() + delai
    while time.time() < limite:
        n = int(db.sql("select count(*) from pg_catalog.pg_stat_activity "
                       "where datname = current_database() and pid <> pg_catalog.pg_backend_pid() "
                       "and wait_event = 'PgSleep';").splitlines()[-1].strip())
        if n >= nombre:
            return True
        time.sleep(0.05)
    return False


def chrono(fonction):
    debut = time.monotonic()
    resultat = fonction()
    return resultat, time.monotonic() - debut


def etat_arret(db):
    return db.sql("select etat from public.communication_arret where id is true;").splitlines()[-1].strip()


def tester_e01_e03_portes_et_arret(db):
    print('\nE-01 / E-03 — trois portes ouvertes, demande puis confirmation d’arrêt')
    portes = [session_parallele(db, "begin; "
                                    "select public.communication_autoriser_sortie('envoi','email'); "
                                    "select pg_sleep(4); commit;") for _ in range(3)]
    verifier('trois portes de sortie tenues en même temps', attendre_sessions_en_pause(db, 3), True)

    demande, duree_demande = chrono(lambda: C.service_json(
        db, "select public.communication_demander_arret('arrêt concurrent de test');"))
    verifier('E-01 : la demande d’arrêt aboutit sans attendre les portes ouvertes',
             (demande.get('etat'), duree_demande < 1.5), ('STOP_REQUESTED', True))
    verifier('E-03 : demande sous le délai du rôle anon (3 s), portes ouvertes', duree_demande < 3, True)

    nouvelle_porte = db.sql("select public.communication_autoriser_sortie('envoi','email') is not null;")
    verifier('E-01 : aucune nouvelle porte ne s’ouvre après la demande',
             nouvelle_porte.splitlines()[-1].strip(), 't')

    attente, duree_attente = chrono(lambda: C.service_json(db, "select public.communication_confirmer_arret();"))
    verifier('E-01 : la confirmation attend la fin des portes (STOP_PENDING)',
             (attente.get('etat'), attente.get('raison')), ('STOP_PENDING', 'VERROU_NON_OBTENU'))
    verifier('E-03 : confirmation sous charge sous le délai du rôle authenticated (8 s)',
             duree_attente < 8, True)
    verifier('E-01 : la demande reste écrite pendant l’attente', etat_arret(db), 'arret_demande')

    sorties = [p.communicate(timeout=20) + (p.returncode,) for p in portes]
    verifier('E-01 : les trois portes déjà ouvertes terminent sans erreur ni interblocage',
             [r[2] for r in sorties], [0, 0, 0])

    finale, duree_finale = chrono(lambda: C.service_json(db, "select public.communication_confirmer_arret();"))
    verifier('E-01 : après la fin des portes, l’arrêt est confirmé',
             finale.get('etat'), 'STOP_CONFIRMED')
    verifier('E-03 : confirmation finale sous 3 s', duree_finale < 3, True)
    print('       durées mesurées : demande %.3f s ; confirmation en attente %.3f s ; finale %.3f s'
          % (duree_demande, duree_attente, duree_finale))

    # Dix confirmations simultanées sur un arrêt déjà confirmé : même réponse, aucun écart.
    reponses, erreurs = [], []
    barriere = threading.Barrier(10)

    def confirmer():
        try:
            barriere.wait()
            reponses.append(C.service_json(db, "select public.communication_confirmer_arret();").get('etat'))
        except BaseException as erreur:
            erreurs.append(str(erreur)[:120])
    fils = [threading.Thread(target=confirmer) for _ in range(10)]
    for f in fils: f.start()
    for f in fils: f.join(20)
    verifier('dix confirmations simultanées : toutes STOP_CONFIRMED, aucune erreur',
             (sorted(set(reponses)), len(reponses), erreurs), (['STOP_CONFIRMED'], 10, []))

    # Levée par l'Admin, pour les essais suivants (version affichée exigée).
    version = C.rpc_json(db.comme(C.ADMIN, 'select public.communication_c10_arret_etat();'))['version']
    levee = C.rpc_json(db.comme(C.ADMIN, "select public.communication_c10_arret_lever("
                                         "'reprise après essai de concurrence', %d);" % version))
    verifier('levée de l’arrêt après l’essai', levee.get('etat'), 'actif')


def tester_course_demande_levee(db):
    print('\nCourse entre une demande d’arrêt et une levée (version attendue)')
    C.service_json(db, "select public.communication_demander_arret('arrêt pour la course');")
    C.service_json(db, "select public.communication_confirmer_arret();")
    version = C.rpc_json(db.comme(C.ADMIN, 'select public.communication_c10_arret_etat();'))['version']
    # Une nouvelle demande arrive APRÈS l'affichage, AVANT la levée : la levée doit échouer.
    C.service_json(db, "select public.communication_demander_arret('nouvelle demande pendant la levée');")
    verifier('levée refusée si une demande est arrivée depuis l’affichage',
             db.erreur(C.ADMIN, "select public.communication_c10_arret_lever("
                                "'reprise avec une version périmée', %d);" % version),
             'STOP_STATE_CHANGED')
    verifier('l’arrêt reste en place', etat_arret(db) in ('arret_demande', 'arret_confirme'), True)

    # Levée et demande lancées EXACTEMENT en même temps, avec la bonne version.
    C.service_json(db, "select public.communication_confirmer_arret();")
    version = C.rpc_json(db.comme(C.ADMIN, 'select public.communication_c10_arret_etat();'))['version']
    barriere = threading.Barrier(2)
    resultats = {}

    def lever():
        barriere.wait()
        resultats['levee'] = db.comme(C.ADMIN, "select public.communication_c10_arret_lever("
                                               "'reprise concurrente de test', %d);" % version, echec_permis=True)

    def demander():
        barriere.wait()
        resultats['demande'] = C.service_sql(db, "select public.communication_demander_arret("
                                                 "'demande concurrente de test');", echec_permis=True)
    fils = [threading.Thread(target=lever), threading.Thread(target=demander)]
    for f in fils: f.start()
    for f in fils: f.join(20)
    etat = etat_arret(db)
    # Invariant : une demande validée n'est jamais effacée par une levée concurrente.
    # Soit la levée passe d'abord (puis la demande remet l'arrêt), soit la levée échoue.
    verifier('course levée / demande : la demande n’est jamais perdue',
             etat in ('arret_demande', 'arret_confirme'), True)
    C.service_json(db, "select public.communication_confirmer_arret();")
    version = C.rpc_json(db.comme(C.ADMIN, 'select public.communication_c10_arret_etat();'))['version']
    db.comme(C.ADMIN, "select public.communication_c10_arret_lever('reprise finale de la course', %d);" % version)
    verifier('levée finale', etat_arret(db), 'actif')


def tester_q5_demandes_simultanees(db):
    print('\nQ5 — demandes de code WhatsApp simultanées')
    C.configurer_consentement_test(db)
    C.installer_aides_test_consentement(db)
    db.sql("""
      update public.communication_consentement_reglages
         set expiration_secondes = 120, maximum_tentatives = 2, portee_tentatives = 'demande',
             fenetre_tentatives_secondes = 3600, fenetre_demandes_secondes = 3600,
             maximum_demandes_compte = 10, maximum_demandes_contact = 10,
             maj_le = clock_timestamp()
       where id is true;
    """)
    reponses, erreurs = [], []
    barriere = threading.Barrier(8)

    def demander(compte):
        try:
            barriere.wait()
            reponses.append((compte, C.rpc_json(db.comme(
                compte, "select public.communication_consentement_demander_whatsapp('fixture-synthetique-v1', 'fr');"))))
        except BaseException as erreur:
            erreurs.append(str(erreur)[:160])
    fils = [threading.Thread(target=demander, args=(C.CLIENT,)) for _ in range(8)]
    for f in fils: f.start()
    for f in fils: f.join(30)
    identifiants = {r.get('demande_id') for _, r in reponses}
    verifier('8 demandes simultanées du même compte : aucune erreur',
             (len(reponses), erreurs), (8, []))
    verifier('8 demandes simultanées : une seule demande ouverte, partagée par toutes',
             (len(identifiants), db.sql("select count(*) from public.communication_confirmations_whatsapp "
                                        "where client_id = '%s';" % C.CLIENT).splitlines()[-1].strip()),
             (1, '1'))

    reponses.clear(); erreurs.clear()
    barriere = threading.Barrier(8)
    fils = [threading.Thread(target=demander, args=(compte,))
            for compte in (C.CLIENT2, C.CLIENT3) for _ in range(4)]
    for f in fils: f.start()
    for f in fils: f.join(30)
    verifier('deux comptes en même temps : aucune erreur', (len(reponses), erreurs), (8, []))
    verifier('deux comptes : une demande chacun, deux empreintes de code distinctes',
             db.sql("select count(*) || '|' || count(distinct code_empreinte) "
                    "from public.communication_confirmations_whatsapp "
                    "where client_id in ('%s','%s');" % (C.CLIENT2, C.CLIENT3)).splitlines()[-1].strip(),
             '2|2')


def tester_e09_changement_numero(db):
    print('\nE-09 — changement du numéro d’un compte consentant')
    demande = C.rpc_json(db.comme(C.CLIENT4, "select public.communication_consentement_demander_whatsapp("
                                             "'fixture-synthetique-v1', 'fr');"))
    confirme = C.rpc_json(db.sql("select public.test_communication_confirmer_code('%s', %d, false, false);"
                                 % (C.CLIENT4, demande['demande_id'])))
    avant = C.rpc_json(db.comme(C.CLIENT4, 'select public.communication_consentement_etat_whatsapp();'))
    verifier('consentement confirmé avant le changement de numéro',
             (confirme.get('ok'), avant.get('etat'), avant.get('actif')), (True, 'confirme', True))
    db.sql("update public.clients set telephone = '7865550199' where id = '%s';" % C.CLIENT4)
    apres = C.rpc_json(db.comme(C.CLIENT4, 'select public.communication_consentement_etat_whatsapp();'))
    verifier('E-09 : le consentement ne suit pas le nouveau numéro', apres.get('actif'), False)
    verifier('E-09 : aucune demande ouverte ne survit au changement',
             db.sql("select count(*) from public.communication_confirmations_whatsapp "
                    "where client_id = '%s' and etat = 'en_attente';" % C.CLIENT4).splitlines()[-1].strip(), '0')


def tester_e07_stop_double(db):
    print('\nE-07 — le même STOP reçu deux fois en même temps')
    db.sql("insert into vault.decrypted_secrets(name,decrypted_secret) "
           "values ('communication_cle_webhook','synthetic-webhook-secret') "
           "on conflict(name) do update set decrypted_secret=excluded.decrypted_secret;")
    db.sql('grant communication_worker to authenticator;')
    empreinte = C.preparer_consentements_stop(db)
    reponses, erreurs = [], []
    barriere = threading.Barrier(2)

    def recevoir():
        try:
            barriere.wait()
            reponses.append(C.recevoir_p08(db, 'meta:concurrence-stop-double', '+17865550105')[1])
        except BaseException as erreur:
            erreurs.append(str(erreur)[:160])
    fils = [threading.Thread(target=recevoir) for _ in range(2)]
    for f in fils: f.start()
    for f in fils: f.join(20)
    verifier('deux réceptions simultanées du même STOP : aucune erreur',
             (len(reponses), erreurs), (2, []))
    verifier('un seul enregistrement, l’autre reconnu comme rejeu',
             (sorted(bool(r.get('rejeu')) for r in reponses),
              db.sql("select count(*) from public.communication_evenements_fournisseur "
                     "where evenement_id = '%s';" % C.identifiant_evenement_p08(db, 'meta:concurrence-stop-double'))
              .splitlines()[-1].strip()),
             ([False, True], '1'))

    resultats, erreurs = [], []
    barriere = threading.Barrier(2)

    def travailler():
        try:
            barriere.wait()
            resultats.append(C.appeler_worker_p08(db))
        except BaseException as erreur:
            erreurs.append(str(erreur)[:160])
    fils = [threading.Thread(target=travailler) for _ in range(2)]
    for f in fils: f.start()
    for f in fils: f.join(20)
    verifier('deux travailleurs simultanés : aucune erreur', (len(resultats), erreurs), (2, []))
    verifier('le STOP est appliqué une seule fois (une suppression, deux consentements retirés)',
             (db.sql("select count(*) from public.communication_contact_suppressions "
                     "where cible_empreinte = '%s' and leve_le is null;" % empreinte).splitlines()[-1].strip(),
              db.sql("select count(*) from public.communication_consentements_clients "
                     "where client_id in ('%s','%s') and etat = 'retire';" % (C.CLIENT5, C.CLIENT6))
              .splitlines()[-1].strip()),
             ('1', '2'))


def main():
    print('Communication Center — essais de concurrence, PostgreSQL local jetable, données synthétiques')
    S.BASE = 'goship_communication_concurrence'
    db = None
    try:
        db = C.installer_base_neuve(inclure_s1=True)
        C.preparer_comptes(db)
        tester_e01_e03_portes_et_arret(db)
        tester_course_demande_levee(db)
        tester_q5_demandes_simultanees(db)
        tester_e09_changement_numero(db)
        tester_e07_stop_double(db)
    finally:
        if db is not None:
            db._psql(db.su, 'postgres', 'drop database if exists %s with (force);' % S.BASE, echec_permis=True)
        for serveur in reversed(C.SERVEURS):
            try:
                serveur.cleanup()
            except Exception:
                pass
        C.shutil.rmtree(S.TRAVAIL, ignore_errors=True)
        C.shutil.rmtree(C.RUNTIME_PG, ignore_errors=True)
    total, reussis = len(S.RESULTATS), sum(S.RESULTATS)
    print('\nRésultat : %d/%d vérifications réussies.' % (reussis, total))
    sys.exit(0 if total and reussis == total else 1)


if __name__ == '__main__':
    main()
