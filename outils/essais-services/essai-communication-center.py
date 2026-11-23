#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Éprouve les migrations candidates du Communication Center sur PostgreSQL jetable."""
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid

sys.dont_write_bytecode = True
ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.normpath(os.path.join(ICI, '..', '..'))
OUTILS = os.path.join(RACINE, 'outils')
CANDIDATES = os.path.join(OUTILS, 'migrations-candidates')
FICHIERS_CANDIDATS = (
    os.path.join(CANDIDATES, '001-communication-foundation.sql'),
    os.path.join(CANDIDATES, '002-communication-supervision.sql'),
    os.path.join(CANDIDATES, '003-communication-consentements.sql'),
    os.path.join(CANDIDATES, '004-communication-transactionnelle.sql'),
    os.path.join(CANDIDATES, '005-communication-adaptateurs-canaux.sql'),
    os.path.join(CANDIDATES, '006-communication-p08-worker.sql'),
    os.path.join(CANDIDATES, '007-communication-interface-operations.sql'),
    os.path.join(CANDIDATES, '008-communication-campagnes-marketing.sql'),
    os.path.join(CANDIDATES, '010-communication-arret-administration.sql'),
)
FICHIER_CANDIDATE_S1 = os.path.join(CANDIDATES, '009-communication-identite-edge.sql')
# Les réglages décidés s'appliquent à part : les essais de consentement vérifient
# d'abord le refus fermé quand aucun réglage n'est fixé.
FICHIER_CANDIDATE_REGLAGES = os.path.join(CANDIDATES, '011-communication-reglages-decides.sql')

spec = importlib.util.spec_from_file_location(
    'essai_services', os.path.join(ICI, 'essai-services.py'))
S = importlib.util.module_from_spec(spec)
spec.loader.exec_module(S)

# Chaque exécution a son propre cluster jetable ; le paquet n'a donc pas à inspecter
# ni arrêter les autres processus PostgreSQL de la machine.
# Dossier temporaire du système (pas un chemin propre au Mac : la CI tourne sous Linux)
DOSSIER_C6 = os.path.join(tempfile.gettempdir(), 'goship-c6-validation')
S.TRAVAIL = os.path.join(DOSSIER_C6, 'db-' + uuid.uuid4().hex)
os.makedirs(S.TRAVAIL, exist_ok=True)
import psutil
psutil.process_iter = lambda *args, **kwargs: ()

# pgserver choisit normalement un répertoire runtime utilisateur hors du bac à sable.
# Pour ce banc, tous ses sockets, verrous et fichiers restent sous le chemin temporaire
# explicitement autorisé pour les bases locales jetables C6.
from pgserver.postgres_server import PostgresServer

RUNTIME_PG = pathlib.Path(DOSSIER_C6) / ('runtime-' + uuid.uuid4().hex)
RUNTIME_PG.mkdir(parents=True, exist_ok=True)
PostgresServer.runtime_path = RUNTIME_PG
PostgresServer.lock_path = RUNTIME_PG / '.lockfile'
PostgresServer._lock = PostgresServer.fasteners.InterProcessLock(PostgresServer.lock_path)
_GET_SERVER = __import__('pgserver').get_server
SERVEURS = []


def serveur_jetable(pgdata):
    serveur = _GET_SERVER(pgdata, cleanup_mode='delete')
    if serveur not in SERVEURS:
        SERVEURS.append(serveur)
    return serveur


__import__('pgserver').get_server = serveur_jetable

ADMIN = 'aaaaaaaa-0000-0000-0000-00000000000a'
MANAGER = 'bbbbbbbb-0000-0000-0000-00000000000b'
EMPLOYEE = 'cccccccc-0000-0000-0000-00000000000c'
CLIENT = 'dddddddd-0000-0000-0000-00000000000d'
CLIENT2 = 'dddddddd-0000-0000-0000-00000000000e'
CLIENT3 = 'dddddddd-0000-0000-0000-00000000000f'
CLIENT4 = 'dddddddd-0000-0000-0000-000000000010'
CLIENT5 = 'dddddddd-0000-0000-0000-000000000011'
CLIENT6 = 'dddddddd-0000-0000-0000-000000000012'
CLIENT7 = 'dddddddd-0000-0000-0000-000000000013'
CLIENT8 = 'dddddddd-0000-0000-0000-000000000014'
CLIENT9 = 'dddddddd-0000-0000-0000-000000000015'
CLIENT10 = 'dddddddd-0000-0000-0000-000000000016'
CLIENT11 = 'dddddddd-0000-0000-0000-000000000017'
CLIENT12 = 'dddddddd-0000-0000-0000-000000000018'
CLIENT13 = 'dddddddd-0000-0000-0000-000000000019'
EMAILS = (
    (ADMIN, 'admin@goship.test', 'Administrateur synthétique'),
    (MANAGER, 'manager@goship.test', 'Gestionnaire synthétique'),
    (EMPLOYEE, 'employee@goship.test', 'Employé synthétique'),
    (CLIENT, 'client@goship.test', 'Client synthétique'),
    (CLIENT2, 'client2@goship.test', 'Second client synthétique'),
    (CLIENT3, 'client3@goship.test', 'Troisième client synthétique'),
    (CLIENT4, 'client4@goship.test', 'Quatrième client synthétique'),
    (CLIENT5, 'client5@goship.test', 'Cinquième client synthétique'),
    (CLIENT6, 'client6@goship.test', 'Sixième client synthétique'),
    (CLIENT7, 'client7@goship.test', 'Septième client synthétique'),
    (CLIENT8, 'client8@goship.test', 'Huitième client synthétique'),
    (CLIENT9, 'client9@goship.test', 'Neuvième client synthétique'),
    (CLIENT10, 'client10@goship.test', 'Dixième client synthétique'),
    (CLIENT11, 'client11@goship.test', 'Onzième client synthétique'),
    (CLIENT12, 'client12@goship.test', 'Douzième client synthétique'),
    (CLIENT13, 'client13@goship.test', 'Treizième client synthétique'),
)

# La chaîne officielle sans les candidates : depuis C11, elles la ferment, mais ce banc
# les applique lui-même (avec des réglages d'essai intercalés avant la 004) et
# éprouve certaines séparément (011, 010).
CHAINE = [
    line.strip()
    for line in open(os.path.join(OUTILS, 'migrations.txt'), encoding='utf-8')
    if line.strip() and not line.startswith('#') and not line.startswith('migrations-candidates/')
]
DROITS_SUPABASE = """
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
"""
SENTINEL = 'synthetic-private-event-payload'


def verifier(titre, obtenu, attendu):
    ok = obtenu == attendu
    print('  %s %s' % ('OK  ' if ok else 'RATÉ', titre))
    if not ok:
        print('       obtenu : %r ; attendu : %r' % (obtenu, attendu))
    S.RESULTATS.append(ok)
    return ok


def installer_doublures_crypto_test(db):
    # pgserver ne fournit pas pgcrypto. Ces fonctions factices servent uniquement à exercer
    # le contrôle de flux, le format et les permissions ; elles ne testent aucune propriété crypto.
    db.sql("""
      create or replace function extensions.gen_random_bytes(p_taille integer)
      returns bytea language sql volatile set search_path = '' as $$
        select substring(decode(replace(gen_random_uuid()::text, '-', ''), 'hex') from 1 for p_taille)
      $$;
      create or replace function extensions.digest(p_texte text, p_type text)
      returns bytea language sql immutable set search_path = '' as $$
        select decode(md5(p_texte) || md5('fixture:' || p_texte), 'hex')
      $$;
      create or replace function extensions.hmac(p_texte text, p_cle text, p_type text)
      returns bytea language sql immutable set search_path = '' as $$
        select decode(md5(p_cle || ':' || p_texte) || md5('fixture:' || p_cle || ':' || p_texte), 'hex')
      $$;
    """)


def appliquer_candidate(db, chemin):
    # La directive CREATE EXTENSION ne peut s'exécuter dans pgserver, dont le paquet n'embarque
    # pas le module pgcrypto. Le reste du SQL est appliqué tel quel avec les doublures ci-dessus.
    texte = pathlib.Path(chemin).read_text(encoding='utf-8')
    texte = texte.replace('create extension if not exists pgcrypto with schema extensions;', '')
    copie = pathlib.Path(S.TRAVAIL, os.path.basename(chemin))
    copie.write_text(texte, encoding='utf-8')
    db.fichier(str(copie))


def installer_base_neuve(inclure_s1=False):
    db = S.Base()
    db.sql(S.DOUBLURES)
    db.sql(DROITS_SUPABASE)
    for nom in CHAINE:
        db.fichier(os.path.join(OUTILS, nom))
    installer_doublures_crypto_test(db)
    for chemin in FICHIERS_CANDIDATS:
        if os.path.basename(chemin) == '004-communication-transactionnelle.sql':
            # Les modèles versionnés copient les canaux au moment de leur
            # création ; l'adaptateur synthétique du banc utilise l'e-mail.
            db.sql("update public.notification_regles set canaux = array['email','push','whatsapp']::text[] "
                   "where type in ('shipment_received', 'shipment_shipped', 'action_required', "
                   "'action_resolved', 'shipment_available', 'shipment_delivered');")
        appliquer_candidate(db, chemin)
    if inclure_s1:
        appliquer_candidate(db, FICHIER_CANDIDATE_S1)
    return db


def tester_identite_edge(db, numero_base):
    print('\nIdentité PostgREST S-1 — base neuve %d' % numero_base)
    db.sql("""
      create or replace function public.test_communication_edge_identite(
        p_role text, p_claims jsonb, p_issuer text, p_audience text, p_ttl text)
      returns boolean language plpgsql volatile set search_path = '' as $test$
      begin
        perform pg_catalog.set_config('app.communication_jwt_issuer', coalesce(p_issuer, ''), true);
        perform pg_catalog.set_config('app.communication_jwt_audience', coalesce(p_audience, ''), true);
        perform pg_catalog.set_config('app.communication_jwt_max_ttl_seconds', coalesce(p_ttl, ''), true);
        perform pg_catalog.set_config('request.jwt.claims', coalesce(p_claims, '{}'::jsonb)::text, true);
        return communication_edge.communication_edge_identite_valide(p_role);
      end
      $test$;
    """)

    attributs = db.sql("""
      select count(*) = 2 and bool_and(
        not rolcanlogin and not rolinherit and not rolsuper and not rolcreatedb
        and not rolcreaterole and not rolreplication and not rolbypassrls)
        from pg_catalog.pg_roles
       where rolname in ('communication_webhook', 'communication_worker');
    """).splitlines()[-1].strip()
    verifier('rôles dédiés avec attributs explicitement restreints', attributs, 't')

    memberships = db.sql("""
      with dedicated as (
        select oid from pg_catalog.pg_roles
         where rolname in ('communication_webhook', 'communication_worker')
      ), auth as (
        select oid from pg_catalog.pg_roles where rolname = 'authenticator'
      )
      select (select count(*) from dedicated) = 2
         and (select bool_and(pg_catalog.pg_has_role('authenticator', oid, 'MEMBER')) from dedicated)
         and not exists (
           select 1 from pg_catalog.pg_auth_members m
            where (m.member in (select oid from dedicated) or m.roleid in (select oid from dedicated))
              and not (m.member = (select oid from auth) and m.roleid in (select oid from dedicated)));
    """).splitlines()[-1].strip()
    verifier('authenticator est le seul membre parent autorisé', memberships, 't')

    privileges = db.sql("""
      select has_function_privilege('communication_webhook',
               'communication_edge.communication_edge_webhook_recevoir_evenement(text,text,text)', 'execute')
         and has_function_privilege('communication_webhook',
               'communication_edge.communication_edge_webhook_recevoir_statut_transactionnel(text,text,text)', 'execute')
         and not has_function_privilege('communication_webhook',
               'communication_edge.communication_edge_worker_code_whatsapp_pour_envoi(bigint,uuid)', 'execute')
         and has_function_privilege('communication_worker',
               'communication_edge.communication_edge_worker_reserver_confirmation_whatsapp(uuid)', 'execute')
         and not has_function_privilege('communication_worker',
               'communication_edge.communication_edge_worker_reclamer_confirmation_whatsapp(bigint,uuid)', 'execute')
         and has_function_privilege('communication_worker',
               'communication_edge.communication_edge_worker_code_whatsapp_pour_envoi(bigint,uuid)', 'execute')
         and not has_function_privilege('communication_worker',
               'communication_edge.communication_edge_webhook_recevoir_evenement(text,text,text)', 'execute')
         and not has_function_privilege('service_role',
               'public.communication_code_whatsapp_pour_envoi(bigint)', 'execute')
         and not has_function_privilege('communication_worker',
               'public.communication_code_whatsapp_pour_envoi(bigint)', 'execute')
         and not has_table_privilege('communication_worker',
               'public.communication_confirmations_whatsapp', 'select')
         and not has_table_privilege('communication_worker',
               'vault.decrypted_secrets', 'select')
         and not has_table_privilege('communication_worker',
               'vault.secrets', 'select')
         and not has_schema_privilege('communication_worker', 'vault', 'usage')
         and not has_schema_privilege('communication_worker', 'public', 'usage')
         and has_schema_privilege('communication_worker', 'communication_edge', 'usage')
         and has_schema_privilege('anon', 'public', 'usage')
         and has_schema_privilege('authenticated', 'public', 'usage')
         and has_schema_privilege('service_role', 'public', 'usage');
    """).splitlines()[-1].strip()
    verifier('RPC distinctes, anciens accès révoqués et aucune lecture directe des données ou de Vault',
             privileges, 't')

    allowed = db.sql("""
      select count(*) = 0
        from pg_catalog.pg_proc p
        join pg_catalog.pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'communication_edge'
         and ((has_function_privilege('communication_webhook', p.oid, 'execute')
               and p.proname not in ('communication_edge_webhook_recevoir_statut_transactionnel',
                                     'communication_edge_webhook_recevoir_evenement'))
           or (has_function_privilege('communication_worker', p.oid, 'execute')
               and p.proname not in ('communication_edge_worker_traiter_evenements_prioritaires',
                                     'communication_edge_worker_expo_recus_a_reconcilier',
                                     'communication_edge_worker_expo_enregistrer_recus',
                                     'communication_edge_worker_traiter_notifications',
                                     'communication_edge_worker_reserver_confirmation_whatsapp',
                                     'communication_edge_worker_contexte_confirmation_whatsapp',
                                     'communication_edge_worker_code_whatsapp_pour_envoi',
                                     'communication_edge_worker_debut_confirmation_whatsapp',
                                     'communication_edge_worker_terminer_confirmation_whatsapp',
                                     'communication_edge_worker_recuperer_confirmations_whatsapp')));
    """).splitlines()[-1].strip()
    verifier('aucun RPC public supplémentaire accordé aux deux rôles', allowed, 't')

    claims_valides = (
        "jsonb_build_object('role','communication_worker','iss','issuer-test','aud','audience-test',"
        "'iat',floor(extract(epoch from clock_timestamp()))::bigint,'nbf',floor(extract(epoch from clock_timestamp()))::bigint,"
        "'exp',floor(extract(epoch from clock_timestamp()))::bigint+60,'jti','synthetic-worker-jti-0001')"
    )
    identite_valide = db.sql(
        "select public.test_communication_edge_identite('communication_worker', %s, "
        "'issuer-test', 'audience-test', '300');" % claims_valides
    ).splitlines()[-1].strip()
    verifier('claims worker exacts acceptés dans le contrôle SQL local', identite_valide, 't')

    role_incorrect = db.sql(
        "select public.test_communication_edge_identite('communication_worker', "
        "jsonb_build_object('role','communication_webhook','iss','issuer-test','aud','audience-test',"
        "'iat',floor(extract(epoch from clock_timestamp()))::bigint,'nbf',floor(extract(epoch from clock_timestamp()))::bigint,"
        "'exp',floor(extract(epoch from clock_timestamp()))::bigint+60,'jti','synthetic-worker-jti-0002'),"
        "'issuer-test','audience-test','300');"
    ).splitlines()[-1].strip()
    issuer_incorrect = db.sql(
        "select public.test_communication_edge_identite('communication_worker', %s, "
        "'wrong-issuer', 'audience-test', '300');" % claims_valides
    ).splitlines()[-1].strip()
    audience_incorrect = db.sql(
        "select public.test_communication_edge_identite('communication_worker', %s, "
        "'issuer-test', 'wrong-audience', '300');" % claims_valides
    ).splitlines()[-1].strip()
    expired = db.sql(
        "select public.test_communication_edge_identite('communication_worker', "
        "jsonb_build_object('role','communication_worker','iss','issuer-test','aud','audience-test',"
        "'iat',floor(extract(epoch from clock_timestamp()))::bigint-120,'nbf',floor(extract(epoch from clock_timestamp()))::bigint-120,"
        "'exp',floor(extract(epoch from clock_timestamp()))::bigint-1,'jti','synthetic-worker-jti-0003'),"
        "'issuer-test','audience-test','300');"
    ).splitlines()[-1].strip()
    future_nbf = db.sql(
        "select public.test_communication_edge_identite('communication_worker', "
        "jsonb_build_object('role','communication_worker','iss','issuer-test','aud','audience-test',"
        "'iat',floor(extract(epoch from clock_timestamp()))::bigint,'nbf',floor(extract(epoch from clock_timestamp()))::bigint+120,"
        "'exp',floor(extract(epoch from clock_timestamp()))::bigint+180,'jti','synthetic-worker-jti-0004'),"
        "'issuer-test','audience-test','300');"
    ).splitlines()[-1].strip()
    ttl_incorrect = db.sql(
        "select public.test_communication_edge_identite('communication_worker', %s, "
        "'issuer-test', 'audience-test', '30');" % claims_valides
    ).splitlines()[-1].strip()
    ttl_nan = db.sql(
        "select public.test_communication_edge_identite('communication_worker', %s, "
        "'issuer-test', 'audience-test', 'NaN');" % claims_valides
    ).splitlines()[-1].strip()
    claims_nan = db.sql(
        "select public.test_communication_edge_identite('communication_worker', "
        "jsonb_build_object('role','communication_worker','iss','issuer-test','aud','audience-test',"
        "'iat','NaN','nbf',floor(extract(epoch from clock_timestamp()))::bigint,"
        "'exp',floor(extract(epoch from clock_timestamp()))::bigint+60,'jti','synthetic-worker-jti-0005'),"
        "'issuer-test','audience-test','300');"
    ).splitlines()[-1].strip()
    verifier('role, issuer, audience, expiration, nbf et TTL invalides refusés',
             (role_incorrect, issuer_incorrect, audience_incorrect, expired, future_nbf,
              ttl_incorrect, ttl_nan, claims_nan),
             ('f', 'f', 'f', 'f', 'f', 'f', 'f', 'f'))

    # Les claims sont injectés uniquement dans cette base jetable afin de tester
    # la séparation ACL/PostgreSQL ; cela ne simule pas la vérification JWT PostgREST.
    maintenant = int(time.time())
    claims_worker = json.dumps({
        'role': 'communication_worker', 'iss': 'issuer-test', 'aud': 'audience-test',
        'iat': maintenant, 'nbf': maintenant, 'exp': maintenant + 60,
        'jti': 'synthetic-worker-jti-cross-role'
    }, separators=(',', ':')).replace("'", "''")
    webhook_denied = db._psql('authenticator', S.BASE, """
      set role communication_webhook;
      set app.communication_jwt_issuer = 'issuer-test';
      set app.communication_jwt_audience = 'audience-test';
      set app.communication_jwt_max_ttl_seconds = '300';
      set local request.jwt.claims = '%s';
      select communication_edge.communication_edge_webhook_recevoir_evenement('meta', '{}', 'invalid');
    """ % claims_worker, echec_permis=True)
    verifier('un claim worker ne permet aucune RPC du rôle webhook',
             'PERMISSION_DENIED' in webhook_denied, True)

    wrong_rpc = db._psql('authenticator', S.BASE, """
      set role communication_webhook;
      select communication_edge.communication_edge_worker_code_whatsapp_pour_envoi(
        1, '11111111-1111-4111-8111-111111111111'::uuid);
    """, echec_permis=True)
    verifier('le rôle webhook ne peut pas appeler le getter worker',
             'permission denied for function communication_edge_worker_code_whatsapp_pour_envoi'
             in wrong_rpc, True)


def communication_worker_sql(db, requete, jti):
    return communication_edge_role_sql(db, 'communication_worker', requete, jti)


def communication_edge_role_sql(db, role, requete, jti):
    if role not in ('communication_worker', 'communication_webhook'):
        raise ValueError('Rôle de test non autorisé')
    maintenant = int(time.time())
    claims = json.dumps({
        'role': role,
        'iss': 'issuer-test',
        'aud': 'audience-test',
        'iat': maintenant,
        'nbf': maintenant,
        'exp': maintenant + 60,
        'jti': jti
    }, separators=(',', ':'))
    claims_sql = claims.replace("'", "''")
    return db._psql('authenticator', S.BASE, """
      begin;
      set local role %s;
      set local app.communication_jwt_issuer = 'issuer-test';
      set local app.communication_jwt_audience = 'audience-test';
      set local app.communication_jwt_max_ttl_seconds = '300';
      set local app.communication_confirmation_claim_seconds = '60';
      set local request.jwt.claims = '%s';
      %s
      commit;
    """ % (role, claims_sql, requete), echec_permis=True)


def tester_c72_recuperation_code(db, numero_base):
    print('\nParcours C7.3 de confirmation WhatsApp — base neuve %d' % numero_base)
    preparer_comptes(db)
    configurer_consentement_test(db)
    installer_aides_test_consentement(db)
    db.sql("""
      update public.communication_consentement_reglages
         set expiration_secondes = 600,
             maximum_tentatives = 5,
             portee_tentatives = 'demande',
             fenetre_tentatives_secondes = 3600,
             fenetre_demandes_secondes = 3600,
             maximum_demandes_compte = 10,
             maximum_demandes_contact = 10,
             politique_contact_partage = 'bloquer'
       where id is true;
    """)

    db.sql("""
      create or replace function public.test_confirmation_outbox_failure()
      returns trigger language plpgsql set search_path = '' as $test$
      begin
        if new.communication_confirmation_demande_id is not null then
          raise exception 'TEST_OUTBOX_FAILURE';
        end if;
        return new;
      end
      $test$;
      create trigger test_confirmation_outbox_failure
        before insert on public.notification_envois
        for each row execute function public.test_confirmation_outbox_failure();
    """)
    echec_atomique = db.erreur(
        CLIENT5,
        "select public.communication_consentement_demander_whatsapp('fixture-synthetique-v1', 'fr');")
    etat_rollback = db.sql("""
      select not exists (select 1 from public.communication_consentements_clients
                          where client_id = '%s')
         and not exists (select 1 from public.communication_confirmations_whatsapp
                          where client_id = '%s')
         and not exists (select 1 from public.communication_consentement_historique
                          where client_id = '%s')
         and not exists (select 1 from vault.decrypted_secrets
                          where name like 'goship-confirmation-%%');
    """ % (CLIENT5, CLIENT5, CLIENT5)).splitlines()[-1].strip()
    verifier('échec de création de tâche annule toute la demande et le secret',
             (echec_atomique, etat_rollback), ('TEST_OUTBOX_FAILURE', 't'))
    db.sql("drop trigger test_confirmation_outbox_failure on public.notification_envois; "
           "drop function public.test_confirmation_outbox_failure();")

    demande = rpc_json(db.comme(
        CLIENT,
        "select public.communication_consentement_demander_whatsapp('fixture-synthetique-v1', 'fr');"))
    demande_id = demande.get('demande_id')
    verifier('demande de confirmation synthétique créée',
             (demande.get('etat'), isinstance(demande_id, int)), ('en_attente', True))
    envoi_id = int(db.sql("select id from public.notification_envois "
                          "where communication_confirmation_demande_id = %d;" % demande_id)
                   .splitlines()[-1].strip())
    outbox_saine = db.sql("""
      select count(*) = 1 and bool_and(
        e.canal = 'whatsapp' and e.statut = 'confirmation'
        and e.cible = 'confirmation:' || d.id::text
        and n.client_id = d.client_id and n.canal = 'whatsapp'
        and n.type = 'confirmation_whatsapp' and n.donnees = '{}'::jsonb
        and e.communication_confirmation_demande_id = d.id)
        and not exists (select 1 from information_schema.columns
                         where table_schema = 'public' and table_name = 'notification_envois'
                           and column_name in ('code', 'code_clair', 'telephone'))
      from public.notification_envois e
      join public.notifications n on n.id = e.notification_id
      join public.communication_confirmations_whatsapp d
        on d.id = e.communication_confirmation_demande_id
      where d.id = %d;
    """ % demande_id).splitlines()[-1].strip()
    verifier('tâche créée atomiquement avec références seules et sans code ni contact', outbox_saine, 't')

    rejouee = rpc_json(db.comme(
        CLIENT,
        "select public.communication_consentement_demander_whatsapp('fixture-synthetique-v1', 'fr');"))
    verifier('rejeu de la demande conserve son identifiant et une seule tâche',
             (rejouee.get('demande_id'),
              db.sql("select count(*) from public.notification_envois "
                     "where communication_confirmation_demande_id = %d;" % demande_id)
              .splitlines()[-1].strip()), (demande_id, '1'))

    revendications = [
        ('11111111-1111-4111-8111-111111111111', 'synthetic-worker-jti-claim-001'),
        ('22222222-2222-4222-8222-222222222222', 'synthetic-worker-jti-claim-002')
    ]
    sorties = [None, None]

    def tenter_claim(index):
        claim_id, jti = revendications[index]
        sorties[index] = communication_worker_sql(
            db,
            "select communication_edge.communication_edge_worker_reserver_confirmation_whatsapp('%s'::uuid);"
            % claim_id,
            jti)

    travailleurs = [threading.Thread(target=tenter_claim, args=(index,)) for index in range(2)]
    for travailleur in travailleurs:
        travailleur.start()
    for travailleur in travailleurs:
        travailleur.join()
    resultats_claim = []
    for sortie in sorties:
        try:
            resultats_claim.append(rpc_json(sortie))
        except (json.JSONDecodeError, IndexError):
            # Les sorties de ce test ne contiennent que des identifiants synthétiques
            # et des erreurs SQL ; le code Vault n'est jamais sélectionné ici.
            print('  sortie de réservation concurrente illisible : %r' % sortie)
            raise
    verifier('deux travailleurs concurrents obtiennent exactement une réservation',
             sorted(resultat.get('claimed') for resultat in resultats_claim), [False, True])

    gagnant = next(i for i, resultat in enumerate(resultats_claim) if resultat.get('claimed'))
    claim_id, jti = revendications[gagnant]
    envoi_reserve = resultats_claim[gagnant].get('envoi_id')
    replay = rpc_json(communication_worker_sql(
        db,
        "select communication_edge.communication_edge_worker_reserver_confirmation_whatsapp('%s'::uuid);"
        % claim_id,
        'synthetic-worker-jti-replay-001'))
    verifier('une réservation active ne peut pas être réattribuée', replay.get('claimed'), False)
    verifier('le claim vise la tâche atomiquement créée', envoi_reserve, envoi_id)

    autre_claim = revendications[1 - gagnant][0]
    getter_concurrent_denied = communication_worker_sql(
        db,
        "select communication_edge.communication_edge_worker_code_whatsapp_pour_envoi(%d, '%s'::uuid) is null;"
        % (envoi_id, autre_claim),
        'synthetic-worker-jti-denied-001').splitlines()[-1].strip()
    verifier('un autre claim ne récupère pas le code de la tâche réservée',
             getter_concurrent_denied, 't')

    contexte = rpc_json(communication_worker_sql(
        db,
        "select communication_edge.communication_edge_worker_contexte_confirmation_whatsapp(%d, '%s'::uuid);"
        % (envoi_id, claim_id), 'synthetic-worker-jti-context-001'))
    verifier('contexte worker lié au bon compte et au contact courant',
             (re.match(r'^\+?[0-9]{5,20}$', contexte.get('destinataire', '')) is not None,
              contexte.get('langue'), set(contexte)), (True, 'fr', {'destinataire', 'langue'}))

    mauvais_compte = communication_worker_sql(
        db,
        "select communication_edge.communication_edge_worker_contexte_confirmation_whatsapp(%d, '%s'::uuid) is null;"
        % (envoi_id + 900000, claim_id), 'synthetic-worker-jti-cross-task-001').splitlines()[-1].strip()
    verifier('une autre tâche ne peut pas réutiliser le claim', mauvais_compte, 't')

    code_output = communication_worker_sql(db, """
      select communication_edge.communication_edge_worker_code_whatsapp_pour_envoi(%d, '%s'::uuid)
             ~ '^[0-9]{6}$';
    """ % (envoi_id, claim_id), 'synthetic-worker-jti-read-001')
    code_correct = code_output.splitlines()[-1].strip()
    code_error = next((ligne.split(':', 1)[1].strip() for ligne in code_output.splitlines()
                       if ligne.startswith('ERROR:')), None)
    verifier('le getter retourne un code lié à la tâche sans l’afficher dans la sortie du test',
             (code_correct, code_error), ('t', None))

    webhook_getter = communication_edge_role_sql(
        db, 'communication_webhook',
        "select communication_edge.communication_edge_worker_code_whatsapp_pour_envoi(%d, '%s'::uuid);"
        % (envoi_id, claim_id), 'synthetic-webhook-jti-code-denied')
    verifier('un JWT du rôle webhook ne peut pas récupérer le code',
             'permission denied for function communication_edge_worker_code_whatsapp_pour_envoi'
             in webhook_getter, True)

    code_audit = db.sql("""
      select count(*) = 1
         and bool_and(action = 'code_lu' and worker_jti = 'synthetic-worker-jti-read-001')
        from public.communication_confirmation_code_audit
       where notification_envoi_id = %d and action = 'code_lu';
    """ % envoi_id).splitlines()[-1].strip()
    audit_sans_code = db.sql("""
      select not exists (
        select 1 from information_schema.columns
         where table_schema = 'public' and table_name = 'communication_confirmation_code_audit'
           and column_name ~ '(code|secret|telephone|cible)');
    """).splitlines()[-1].strip()
    verifier('accès audité par jti sans stocker le code ni une donnée de contact',
             (code_audit, audit_sans_code), ('t', 't'))

    debut = rpc_json(communication_worker_sql(
        db,
        "select communication_edge.communication_edge_worker_debut_confirmation_whatsapp(%d, '%s'::uuid);"
        % (envoi_id, claim_id), 'synthetic-worker-jti-start-001'))
    second_debut = rpc_json(communication_worker_sql(
        db,
        "select communication_edge.communication_edge_worker_debut_confirmation_whatsapp(%d, '%s'::uuid);"
        % (envoi_id, claim_id), 'synthetic-worker-jti-start-replay-001'))
    verifier('un seul démarrage durable de transmission est permis',
             (debut.get('started'), second_debut.get('started'),
              db.sql("select statut from public.notification_envois where id = %d;" % envoi_id)
              .splitlines()[-1].strip()), (True, False, 'envoi'))

    resultat_accepte = rpc_json(communication_worker_sql(
        db,
        "select communication_edge.communication_edge_worker_terminer_confirmation_whatsapp(%d, '%s'::uuid, "
        "'accepte', 'wamid.synthetic-c73-001', null);" % (envoi_id, claim_id),
        'synthetic-worker-jti-accepted-001'))
    etat_accepte = db.sql("select statut || '|' || coalesce(message_id, '') from public.notification_envois "
                          "where id = %d;" % envoi_id).splitlines()[-1].strip()
    verifier('acceptation simulée et référence fournisseur enregistrées',
             (resultat_accepte.get('recorded'), resultat_accepte.get('status'), etat_accepte),
             (True, 'envoye', 'envoye|wamid.synthetic-c73-001'))
    verifier('le secret reste disponible jusqu’à la confirmation client',
             db.sql("select code_secret_id is not null from public.communication_confirmations_whatsapp "
                    "where id = %d;" % demande_id).splitlines()[-1].strip(), 't')

    resultat_confirmation = rpc_json(db.sql(
        "select public.test_communication_confirmer_code('%s', %d, false, false);" % (CLIENT, demande_id)))
    verifier('confirmation client clôt le secret après l’envoi accepté',
             (resultat_confirmation.get('ok'),
              db.sql("select count(*) from vault.decrypted_secrets where name like 'goship-confirmation-%%';")
              .splitlines()[-1].strip()), (True, '0'))

    demande_temp = rpc_json(db.comme(
        CLIENT2,
        "select public.communication_consentement_demander_whatsapp('fixture-synthetique-v1', 'fr');"))
    id_temp = demande_temp.get('demande_id')
    envoi_temp = int(db.sql("select id from public.notification_envois "
                            "where communication_confirmation_demande_id = %d;" % id_temp)
                     .splitlines()[-1].strip())
    code_autre_compte = communication_worker_sql(
        db,
        "select communication_edge.communication_edge_worker_code_whatsapp_pour_envoi(%d, '%s'::uuid) is null;"
        % (envoi_temp, claim_id), 'synthetic-worker-jti-cross-account-code')
    verifier('le claim d’un compte ne peut pas lire le code d’un autre compte',
             code_autre_compte.splitlines()[-1].strip(), 't')
    claim_temp = '44444444-4444-4444-8444-444444444444'
    reserve_temp = rpc_json(communication_worker_sql(
        db,
        "select communication_edge.communication_edge_worker_reserver_confirmation_whatsapp('%s'::uuid);"
        % claim_temp, 'synthetic-worker-jti-temp-claim'))
    debut_temp = rpc_json(communication_worker_sql(
        db,
        "select communication_edge.communication_edge_worker_debut_confirmation_whatsapp(%d, '%s'::uuid);"
        % (envoi_temp, claim_temp), 'synthetic-worker-jti-temp-start'))
    temporaire = rpc_json(communication_worker_sql(
        db,
        "select communication_edge.communication_edge_worker_terminer_confirmation_whatsapp(%d, '%s'::uuid, "
        "'temporaire', null, 'LIMITE_DEBIT');" % (envoi_temp, claim_temp),
        'synthetic-worker-jti-temp-result'))
    statut_temp = db.sql("select statut || '|' || (communication_confirmation_started_le is null)::text "
                         "from public.notification_envois where id = %d;" % envoi_temp)
    verifier('refus temporaire connu avant acceptation planifie une reprise bornée',
             (reserve_temp.get('claimed'), debut_temp.get('started'), temporaire.get('status'),
              statut_temp.splitlines()[-1].strip()), (True, True, 'confirmation', 'confirmation|true'))

    db.sql("update public.notification_envois set prochain_essai_le = clock_timestamp() - interval '1 second' "
           "where id = %d;" % envoi_temp)
    claim_definitif = '55555555-5555-4555-8555-555555555555'
    reserve_definitif = rpc_json(communication_worker_sql(
        db,
        "select communication_edge.communication_edge_worker_reserver_confirmation_whatsapp('%s'::uuid);"
        % claim_definitif, 'synthetic-worker-jti-def-claim'))
    communication_worker_sql(
        db,
        "select communication_edge.communication_edge_worker_debut_confirmation_whatsapp(%d, '%s'::uuid);"
        % (envoi_temp, claim_definitif), 'synthetic-worker-jti-def-start')
    definitif = rpc_json(communication_worker_sql(
        db,
        "select communication_edge.communication_edge_worker_terminer_confirmation_whatsapp(%d, '%s'::uuid, "
        "'definitif', null, 'REFUS_FOURNISSEUR');" % (envoi_temp, claim_definitif),
        'synthetic-worker-jti-def-result'))
    verifier('refus définitif clôt la tâche sans répétition',
             (reserve_definitif.get('claimed'), definitif.get('status'),
              db.sql("select statut from public.notification_envois where id = %d;" % envoi_temp)
              .splitlines()[-1].strip()), (True, 'echec', 'echec'))

    demande_incertaine = rpc_json(db.comme(
        CLIENT3,
        "select public.communication_consentement_demander_whatsapp('fixture-synthetique-v1', 'fr');"))
    id_incertain = demande_incertaine.get('demande_id')
    envoi_incertain = int(db.sql("select id from public.notification_envois "
                                 "where communication_confirmation_demande_id = %d;" % id_incertain)
                          .splitlines()[-1].strip())
    claim_incertain = '66666666-6666-4666-8666-666666666666'
    rpc_json(communication_worker_sql(
        db,
        "select communication_edge.communication_edge_worker_reserver_confirmation_whatsapp('%s'::uuid);"
        % claim_incertain, 'synthetic-worker-jti-uncertain-claim'))
    communication_worker_sql(
        db,
        "select communication_edge.communication_edge_worker_debut_confirmation_whatsapp(%d, '%s'::uuid);"
        % (envoi_incertain, claim_incertain), 'synthetic-worker-jti-uncertain-start')
    db.sql("update public.notification_envois set communication_confirmation_claim_expire_le = "
           "clock_timestamp() - interval '1 second' where id = %d;" % envoi_incertain)
    recuperation = rpc_json(communication_worker_sql(
        db,
        "select communication_edge.communication_edge_worker_recuperer_confirmations_whatsapp(10);",
        'synthetic-worker-jti-recovery'))
    verifier('crash après début de transmission devient incertain sans reprise',
             (recuperation.get('recovered'),
              db.sql("select statut from public.notification_envois where id = %d;" % envoi_incertain)
              .splitlines()[-1].strip()), (1, 'incertain'))
    aucune_reprise = rpc_json(communication_worker_sql(
        db,
        "select communication_edge.communication_edge_worker_reserver_confirmation_whatsapp('%s'::uuid);"
        % '77777777-7777-4777-8777-777777777777', 'synthetic-worker-jti-no-retry'))
    verifier('une sortie incertaine ne redevient jamais éligible automatiquement',
             aucune_reprise.get('claimed'), False)

    demande_crash = rpc_json(db.comme(
        CLIENT4,
        "select public.communication_consentement_demander_whatsapp('fixture-synthetique-v1', 'fr');"))
    id_crash = demande_crash.get('demande_id')
    envoi_crash = int(db.sql("select id from public.notification_envois "
                             "where communication_confirmation_demande_id = %d;" % id_crash)
                      .splitlines()[-1].strip())
    claim_avant = '88888888-8888-4888-8888-888888888888'
    rpc_json(communication_worker_sql(
        db,
        "select communication_edge.communication_edge_worker_reserver_confirmation_whatsapp('%s'::uuid);"
        % claim_avant, 'synthetic-worker-jti-before-crash'))
    db.sql("update public.notification_envois set communication_confirmation_claim_expire_le = "
           "clock_timestamp() - interval '1 second' where id = %d;" % envoi_crash)
    claim_apres = rpc_json(communication_worker_sql(
        db,
        "select communication_edge.communication_edge_worker_reserver_confirmation_whatsapp('%s'::uuid);"
        % '99999999-9999-4999-8999-999999999999', 'synthetic-worker-jti-before-retry'))
    verifier('crash avant transmission peut être repris avec un nouveau claim',
             (claim_apres.get('claimed'), claim_apres.get('envoi_id'),
              db.sql("select statut || '|' || (communication_confirmation_started_le is null)::text "
                     "from public.notification_envois where id = %d;" % envoi_crash)
              .splitlines()[-1].strip()), (True, envoi_crash, 'confirmation|true'))

    invalide = communication_worker_sql(
        db,
        "select communication_edge.communication_edge_worker_code_whatsapp_pour_envoi(%d, '%s'::uuid) is null;"
        % (envoi_crash, '33333333-3333-4333-8333-333333333333'),
        'synthetic-worker-jti-expired-claim').splitlines()[-1].strip()
    db.sql("update public.communication_confirmations_whatsapp "
           "set expire_le = clock_timestamp() - interval '1 second' where id = %d;" % id_crash)
    expire = communication_worker_sql(
        db,
        "select communication_edge.communication_edge_worker_code_whatsapp_pour_envoi(%d, '%s'::uuid) is null;"
        % (envoi_crash, '99999999-9999-4999-8999-999999999999'),
        'synthetic-worker-jti-expired-request').splitlines()[-1].strip()
    verifier('claim inconnu et demande expirée refusés', (invalide, expire), ('t', 't'))

    demande_bail = rpc_json(db.comme(
        CLIENT6,
        "select public.communication_consentement_demander_whatsapp('fixture-synthetique-v1', 'fr');"))
    id_bail = demande_bail.get('demande_id')
    envoi_bail = int(db.sql("select id from public.notification_envois "
                            "where communication_confirmation_demande_id = %d;" % id_bail)
                     .splitlines()[-1].strip())
    claim_bail = 'aaaaaaaa-1111-4111-8111-111111111111'
    rpc_json(communication_worker_sql(
        db,
        "select communication_edge.communication_edge_worker_reserver_confirmation_whatsapp('%s'::uuid);"
        % claim_bail, 'synthetic-worker-jti-expired-lease-claim'))
    db.sql("update public.notification_envois set communication_confirmation_claim_expire_le = "
           "clock_timestamp() - interval '1 second' where id = %d;" % envoi_bail)
    bail_expire = communication_worker_sql(
        db,
        "select communication_edge.communication_edge_worker_code_whatsapp_pour_envoi(%d, '%s'::uuid) is null;"
        % (envoi_bail, claim_bail), 'synthetic-worker-jti-expired-lease').splitlines()[-1].strip()
    verifier('un claim expiré ne peut pas récupérer le code', bail_expire, 't')

    ancien_getter = db._psql('authenticator', S.BASE, """
      set role service_role;
      select public.communication_code_whatsapp_pour_envoi(%d);
    """ % demande_id, echec_permis=True)
    verifier('service_role ne peut plus appeler l’ancien getter',
             'permission denied for function communication_code_whatsapp_pour_envoi'
             in ancien_getter, True)

    # Correction du 23/11/2026 : le début d'une transmission de code passe par la
    # porte P-07. Après une demande d'arrêt validée, aucune transmission ne commence.
    demande_arret = rpc_json(db.comme(
        CLIENT5,
        "select public.communication_consentement_demander_whatsapp('fixture-synthetique-v1', 'fr');"))
    verifier('demande de confirmation préparée avant l’arrêt', demande_arret.get('ok'), True)
    claim_arret = 'bbbbbbbb-2222-4222-8222-222222222222'
    reserve_arret = rpc_json(communication_worker_sql(
        db,
        "select communication_edge.communication_edge_worker_reserver_confirmation_whatsapp('%s'::uuid);"
        % claim_arret, 'synthetic-worker-jti-stop-claim'))
    envoi_arret = reserve_arret.get('envoi_id')
    arret = service_json(db, "select public.communication_demander_arret('arrêt local du parcours C7.3');")
    debut_arret = rpc_json(communication_worker_sql(
        db,
        "select communication_edge.communication_edge_worker_debut_confirmation_whatsapp(%d, '%s'::uuid);"
        % (envoi_arret, claim_arret), 'synthetic-worker-jti-stop-start'))
    statut_arret = db.sql("select statut || '|' || (communication_confirmation_started_le is null)::text "
                          "from public.notification_envois where id = %d;" % envoi_arret)
    verifier('aucune transmission de code ne commence après la demande d’arrêt',
             (reserve_arret.get('claimed'), arret.get('etat'), debut_arret.get('started'),
              debut_arret.get('raison'), statut_arret.splitlines()[-1].strip()),
             (True, 'STOP_REQUESTED', False, 'ARRET_URGENCE', 'confirmation|true'))


def preparer_comptes(db):
    for uid, email, nom in EMAILS:
        db.sql(
            "insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) "
            "values ('%s', '%s', now(), '{\"nom_complet\":\"%s\"}'::jsonb);"
            % (uid, email, nom.replace("'", "''")))
    db.sql("select public.definir_admin('admin@goship.test');")
    for email, role in (('manager@goship.test', 'gerant'),
                        ('employee@goship.test', 'employe'),
                        ('client@goship.test', 'client'),
                        ('client2@goship.test', 'client'),
                        ('client3@goship.test', 'client'),
                        ('client4@goship.test', 'client'),
                        ('client5@goship.test', 'client'),
                        ('client6@goship.test', 'client'),
                        ('client7@goship.test', 'client'),
                        ('client8@goship.test', 'client'),
                        ('client9@goship.test', 'client'),
                        ('client10@goship.test', 'client'),
                        ('client11@goship.test', 'client'),
                        ('client12@goship.test', 'client'),
                        ('client13@goship.test', 'client')):
        db.comme(ADMIN, "select public.changer_role('%s', '%s');" % (email, role))

    # Profils et contacts entièrement synthétiques ; aucun numéro réel n'est utilisé.
    db.sql("""
      update public.clients set telephone = '7865550101', pays = 'US' where id = '%s';
      update public.clients set telephone = '7865550102', pays = 'US' where id = '%s';
      update public.clients set telephone = '7865550103', pays = 'US' where id = '%s';
      update public.clients set telephone = '7865550104', pays = 'US' where id = '%s';
      update public.clients set telephone = '7865550105', pays = 'US' where id = '%s';
      update public.clients set telephone = '7865550106', pays = 'US' where id = '%s';
    """ % (CLIENT, CLIENT2, CLIENT3, CLIENT4, CLIENT5, CLIENT6))


def peupler_evenements(db):
    db.sql("""
      insert into public.communication_evenements_fournisseur
        (fournisseur, evenement_id, type, message_id, reference, code)
      values
        ('meta', 'synthetic-event-1', 'delivered', '%s-message-1', '%s-reference-1', '200'),
        ('brevo', 'synthetic-event-2', 'inbound', '%s-message-2', '%s-reference-2', '202'),
        ('resend', 'synthetic-event-3', 'failed', '%s-message-3', '%s-reference-3', '500');
      insert into public.communication_evenements_traitement (evenement_id, etat, priorite, classe)
      select id, 'a_traiter', 2, 'autre'
        from public.communication_evenements_fournisseur where evenement_id = 'synthetic-event-1';
      insert into public.communication_evenements_traitement
        (evenement_id, etat, priorite, classe, dernier_code, resultat)
      select id, 'echec', 1, 'stop', 'XX000', '%s'
        from public.communication_evenements_fournisseur where evenement_id = 'synthetic-event-2';
      insert into public.communication_evenements_traitement
        (evenement_id, etat, priorite, classe, traite_le)
      select id, 'traite', 2, 'autre', now()
        from public.communication_evenements_fournisseur where evenement_id = 'synthetic-event-3';
    """ % (SENTINEL, SENTINEL, SENTINEL, SENTINEL, SENTINEL, SENTINEL, SENTINEL))


def tester_permissions_et_reponse(db, numero_base):
    print('\nBase neuve %d' % numero_base)
    preparer_comptes(db)
    peupler_evenements(db)
    verifier('événement fournisseur dédupliqué par fournisseur et identifiant',
             db.erreur('sql', "insert into public.communication_evenements_fournisseur "
                       "(fournisseur, evenement_id, type) values ('meta', 'synthetic-event-1', 'delivered');")
             .startswith('duplicate key value violates unique constraint'), True)

    donnees_admin = S.jsonq(db, ADMIN, 'select public.sante_communications();')
    donnees_manager = S.jsonq(db, MANAGER, 'select public.sante_communications();')
    verifier('admin et manager lisent la supervision',
             isinstance(donnees_admin, dict) and isinstance(donnees_manager, dict), True)
    verifier('rôles employé et client refusés',
             (db.erreur(EMPLOYEE, 'select public.sante_communications();'),
              db.erreur(CLIENT, 'select public.sante_communications();')),
             ('PERMISSION_DENIED', 'PERMISSION_DENIED'))
    verifier('visiteur anonyme refusé',
             db.erreur(None, 'select public.sante_communications();').startswith('permission denied'), True)

    mesures = donnees_admin.get('evenements', {}) if isinstance(donnees_admin, dict) else {}
    verifier('agrégats exacts des retours synthétiques',
             (mesures.get('recus_conserves'), mesures.get('a_traiter'), mesures.get('en_cours'),
              mesures.get('en_cours_mesurable'), mesures.get('traites_conserves'),
              mesures.get('echec'), mesures.get('echec_prioritaires')),
             (3, 1, None, False, 1, 1, 1))
    verifier('état d’arrêt initial explicite', donnees_admin.get('arret'), {'etat': 'actif'})
    verifier('réponse et champs limités à la liste blanche',
             set(donnees_admin), {'evenements', 'envois', 'arret', 'travailleur'})
    # Décision A (23/11/2026) : la supervision lit l'outbox unique notification_envois.
    attendus_envois = json.loads(db.sql("""
      select json_build_object(
        'disponible', true,
        'en_attente', count(*) filter (where statut in ('attente', 'confirmation')),
        'en_cours', count(*) filter (where statut = 'envoi'),
        'envoyes', count(*) filter (where statut = 'envoye'),
        'livres', count(*) filter (where statut = 'livre'),
        'echecs', count(*) filter (where statut = 'echec'),
        'incertains', count(*) filter (where statut = 'incertain'),
        'annules', count(*) filter (where statut = 'annule'))
      from public.notification_envois;
    """).splitlines()[-1].strip())
    verifier('envois lus dans l’outbox unique, statuts réels',
             donnees_admin.get('envois'), attendus_envois)
    verifier('réponse sans identifiant ni contenu d’événement',
             SENTINEL not in json.dumps(donnees_admin, ensure_ascii=False), True)
    verifier('état pg_cron absent déclaré non mesurable',
             donnees_admin.get('travailleur', {}).get('tables_disponibles'), False)


    prive = db.sql("""
      select not has_table_privilege('anon', 'public.communication_arret', 'select')
         and not has_table_privilege('authenticated', 'public.communication_arret', 'update')
         and not has_table_privilege('service_role', 'public.communication_evenements_fournisseur', 'select')
         and not has_table_privilege('authenticated', 'public.communication_evenements_traitement', 'select')
         and not has_sequence_privilege('anon', 'public.communication_evenements_fournisseur_id_seq', 'usage')
         and has_function_privilege('authenticated', 'public.sante_communications()', 'execute')
         and not has_function_privilege('anon', 'public.sante_communications()', 'execute')
         and not has_function_privilege('service_role', 'public.sante_communications()', 'execute');
    """).splitlines()[-1].strip()
    verifier('droits directs révoqués et RPC limité à authenticated', prive, 't')
    securite_definitions = db.sql("""
      select p.prosecdef
         and exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%')
         and (select bool_and(relrowsecurity)
              from pg_catalog.pg_class
              where oid in ('public.communication_arret'::regclass,
                            'public.communication_evenements_fournisseur'::regclass,
                            'public.communication_evenements_traitement'::regclass))
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'sante_communications';
    """).splitlines()[-1].strip()
    verifier('RPC SECURITY DEFINER à search_path fixé et RLS active', securite_definitions, 't')
    verifier('code de confirmation limité à six chiffres',
             db.erreur('sql', "update public.communication_evenements_traitement "
                       "set code_confirmation = '1234' where evenement_id = "
                       "(select id from public.communication_evenements_fournisseur "
                       "where evenement_id = 'synthetic-event-1');").startswith('new row for relation'), True)
    verifier('lecture directe des tables refusée',
             db.erreur(ADMIN, 'select count(*) from public.communication_evenements_fournisseur;').startswith('permission denied'),
             True)
    verifier('modification directe du Kill Switch refusée',
             db.erreur(ADMIN, "update public.communication_arret set etat = 'actif' where id is true;").startswith('permission denied'),
             True)
    verifier('suppression de la ligne du Kill Switch bloquée',
             db.erreur('sql', 'delete from public.communication_arret where id is true;'),
             'COMMUNICATION_STOP_STATE_REQUIRED')
    verifier('TRUNCATE de la ligne du Kill Switch bloqué',
             db.erreur('sql', 'truncate table public.communication_arret;'),
             'COMMUNICATION_STOP_STATE_REQUIRED')

    verifier('retour fournisseur immuable contre UPDATE',
             db.erreur('sql', "update public.communication_evenements_fournisseur set code = 'x' where evenement_id = 'synthetic-event-1';"),
             'COMMUNICATION_EVENT_IMMUTABLE')
    verifier('retour fournisseur immuable contre DELETE',
             db.erreur('sql', "delete from public.communication_evenements_fournisseur where evenement_id = 'synthetic-event-1';"),
             'COMMUNICATION_EVENT_IMMUTABLE')
    verifier('TRUNCATE isolé refusé par la relation de file',
             db.erreur('sql', 'truncate table public.communication_evenements_fournisseur;').startswith(
                 'cannot truncate a table referenced in a foreign key constraint'), True)
    truncate_conjoint = db.erreur(
        'sql', 'truncate table public.communication_evenements_fournisseur, '
               'public.communication_evenements_traitement;')
    evenements_apres_truncate = db.sql(
        'select (select count(*) from public.communication_evenements_fournisseur)::text || \'|\' || '
        '(select count(*) from public.communication_evenements_traitement)::text;')
    verifier('TRUNCATE conjoint refusé sans effacer événements ni traitement',
             (truncate_conjoint == 'COMMUNICATION_EVENT_IMMUTABLE' or
              truncate_conjoint.startswith('cannot truncate a table referenced in a foreign key constraint'),
              evenements_apres_truncate.splitlines()[-1].strip()),
             (True, '3|3'))

    chemin_api = pathlib.Path(RACINE, 'assets/js/api.js').read_text(encoding='utf-8')
    verifier('API Supabase appelle le RPC de supervision',
             "rpc('sante_communications')" in chemin_api, True)
    js_path = pathlib.Path(RACINE, 'assets/js/communications.js')
    script = r"""
      const fs = require('fs');
      const vm = require('vm');
      const contexte = { window: {} };
      vm.runInNewContext(fs.readFileSync(process.argv[1], 'utf8'), contexte);
      const raw = JSON.parse(fs.readFileSync(0, 'utf8'));
      process.stdout.write(JSON.stringify(contexte.window.GoshipCommunications.modeliserSante(raw)));
    """
    if not shutil.which('node'):
        verifier('adaptateur JavaScript local disponible', False, True)
    else:
        resultat = subprocess.run(
            ['node', '-e', script, str(js_path)],
            input=json.dumps(donnees_admin), text=True, capture_output=True, check=False)
        modele = json.loads(resultat.stdout) if resultat.returncode == 0 else None
        verifier('modèle de la vue reçoit les mesures du RPC local',
                 (resultat.returncode, (modele or {}).get('mesures', {}).get('recus')),
                 (0, 3))


def installer_aides_test_consentement(db):
    # Ces aides vivent uniquement dans la base jetable. Elles manipulent le code en mémoire
    # pour les assertions sans jamais le retourner au processus ni l'écrire dans les sorties.
    db.sql("""
      create or replace function public.test_communication_confirmer_code(
        p_acteur uuid, p_demande bigint, p_faux boolean default false, p_rejouer boolean default false)
      returns jsonb language plpgsql security definer set search_path = '' as $test$
      declare
        v_code text;
        v_premier jsonb;
        v_second jsonb;
      begin
        perform set_config('request.jwt.claims',
          jsonb_build_object('sub', p_acteur::text, 'role', 'service_role')::text, true);
        select s.decrypted_secret into v_code
          from public.communication_confirmations_whatsapp d
          join vault.decrypted_secrets s on s.id = d.code_secret_id
         where d.id = p_demande;
        if p_faux and v_code is not null then
          v_code := left(v_code, 5) || (((right(v_code, 1)::integer + 1) % 10)::text);
        end if;
        perform set_config('request.jwt.claims',
          jsonb_build_object('sub', p_acteur::text, 'role', 'authenticated')::text, true);
        v_premier := public.communication_consentement_confirmer_whatsapp(v_code);
        if not p_rejouer then
          return v_premier;
        end if;
        v_second := public.communication_consentement_confirmer_whatsapp(v_code);
        return jsonb_build_object('premier', v_premier, 'second', v_second);
      end
      $test$;
      create or replace function public.test_communication_code_format(p_acteur uuid, p_demande bigint)
      returns boolean language plpgsql security definer set search_path = '' as $test$
      declare
        v_code text;
      begin
        perform set_config('request.jwt.claims',
          jsonb_build_object('sub', p_acteur::text, 'role', 'service_role')::text, true);
        select s.decrypted_secret into v_code
          from public.communication_confirmations_whatsapp d
          join vault.decrypted_secrets s on s.id = d.code_secret_id
         where d.id = p_demande;
        return v_code ~ '^[0-9]{6}$';
      end
      $test$;
    """)


def configurer_consentement_test(db):
    db.sql("""
      insert into vault.decrypted_secrets (name, decrypted_secret)
      values ('communication_poivre', encode(extensions.gen_random_bytes(32), 'hex'))
      on conflict (name) do update set decrypted_secret = excluded.decrypted_secret;
      insert into public.communication_consentement_textes
        (version, canal, langue, texte, empreinte, statut, atteste_le, reference_attestation)
      values ('fixture-synthetique-v1', 'whatsapp', 'fr', 'Texte synthétique réservé aux essais locaux',
              encode(extensions.digest('Texte synthétique réservé aux essais locaux', 'sha256'), 'hex'),
              'atteste_juridique', clock_timestamp(), 'fixture-locale-sans-validite-juridique')
      on conflict (version, canal, langue) do nothing;
    """)


def rpc_json(sortie):
    return json.loads(sortie.strip().splitlines()[-1])


def tester_consentements(db, numero_base):
    print('\nConsentement et confirmations WhatsApp — base neuve %d' % numero_base)
    configurer_consentement_test(db)
    installer_aides_test_consentement(db)

    # Aucun délai, seuil ou modèle de numéro partagé n'est implicitement activé.
    erreur_configuration = db.erreur(
        CLIENT,
        "select public.communication_consentement_demander_whatsapp('fixture-synthetique-v1', 'fr');")
    verifier('configuration métier non renseignée refusée par défaut',
             erreur_configuration, 'POLICY_UNCONFIGURED')
    verifier('échec de configuration sans consentement ni demande créée',
             db.sql('select (select count(*) from public.communication_consentements_clients) = 0 '
                    'and (select count(*) from public.communication_confirmations_whatsapp) = 0;').splitlines()[-1].strip(),
             't')

    # Valeurs synthétiques locales uniquement ; elles ne deviennent pas des règles GoShip.
    db.sql("""
      update public.communication_consentement_reglages
         set expiration_secondes = 120,
             maximum_tentatives = 2,
             portee_tentatives = 'demande',
             fenetre_tentatives_secondes = 3600,
             fenetre_demandes_secondes = 3600,
             maximum_demandes_compte = 10,
             maximum_demandes_contact = 10,
             politique_contact_partage = null,
             maj_le = clock_timestamp()
       where id is true;
    """)

    demande = rpc_json(db.comme(
        CLIENT,
        "select public.communication_consentement_demander_whatsapp('fixture-synthetique-v1', 'fr');"))
    identifiant = demande.get('demande_id')
    verifier('création de demande liée au compte réel',
             (demande.get('ok'), demande.get('etat'), demande.get('canal'), demande.get('finalite'),
              isinstance(identifiant, int)),
             (True, 'en_attente', 'whatsapp', 'marketing', True))
    verifier('RPC de demande ne retourne jamais le code ni le numéro',
             any(cle in demande for cle in ('code', 'code_whatsapp', 'telephone', 'numero', 'cible_empreinte')),
             False)

    reponse_rejouee = rpc_json(db.comme(
        CLIENT,
        "select public.communication_consentement_demander_whatsapp('fixture-synthetique-v1', 'fr');"))
    verifier('double demande réutilise la demande ouverte sans doublon',
             (reponse_rejouee.get('demande_id'), reponse_rejouee.get('demande_reutilisee'),
              db.sql('select count(*) from public.communication_confirmations_whatsapp;').splitlines()[-1].strip()),
             (identifiant, True, '1'))

    stockage_code = db.sql("select code_secret_id is not null from public.communication_confirmations_whatsapp "
                           "where id = %d;" % identifiant).splitlines()[-1].strip()
    code_format = db.sql("select public.test_communication_code_format('%s', %d);" % (CLIENT, identifiant))
    stockage_code = (stockage_code, code_format.splitlines()[-1].strip())
    verifier('code six chiffres conservé derrière une référence Vault hors du RPC client', stockage_code, ('t', 't'))

    # Le code correct de la première demande est présenté au second compte en mémoire côté DB.
    reponse_autre_compte = rpc_json(db.sql(
        "select public.test_communication_confirmer_code('%s', %d, false, false);" % (CLIENT2, identifiant)))
    verifier('un autre compte ne peut pas confirmer la demande', reponse_autre_compte.get('ok'), False)
    verifier('refus intercompte ne consomme pas la demande d’origine',
             db.sql("select etat from public.communication_confirmations_whatsapp where id = %d;" % identifiant)
             .splitlines()[-1].strip(), 'en_attente')

    resultat_double = rpc_json(db.sql(
        "select public.test_communication_confirmer_code('%s', %d, false, true);" % (CLIENT, identifiant)))
    premier = resultat_double.get('premier', {})
    second = resultat_double.get('second', {})
    verifier('confirmation correcte et rejeu idempotent',
             (premier.get('ok'), second.get('ok'), second.get('deja_confirme')),
             (True, True, True))
    verifier('secret de confirmation supprimé après validation',
             db.sql("select count(*) from vault.decrypted_secrets where name like 'goship-confirmation-%';")
             .splitlines()[-1].strip(), '0')
    etat_client = rpc_json(db.comme(CLIENT, 'select public.communication_consentement_etat_whatsapp();'))
    etat_autre = rpc_json(db.comme(CLIENT2, 'select public.communication_consentement_etat_whatsapp();'))
    verifier('lecture d’état isolée par compte',
             (etat_client.get('etat'), etat_client.get('actif'), etat_autre.get('etat'), etat_autre.get('actif')),
             ('confirme', True, 'aucun', False))
    verifier('RPC d’état sans code, empreinte ou contact brut',
             any(cle in etat_client for cle in ('code', 'cible_empreinte', 'telephone', 'numero')), False)

    verifier('retrait de consentement traçable',
             rpc_json(db.comme(CLIENT, 'select public.communication_consentement_retirer_whatsapp();')).get('etat'),
             'retire')
    verifier('historique séparé contient demande, confirmation et retrait',
             tuple(db.sql("select string_agg(action, ',' order by id) from public.communication_consentement_historique "
                          "where client_id = '%s';" % CLIENT).splitlines()[-1].strip().split(',')),
             ('demande', 'confirme', 'retrait'))

    demande_invalide = rpc_json(db.comme(
        CLIENT2,
        "select public.communication_consentement_demander_whatsapp('fixture-synthetique-v1', 'fr');"))
    id_invalide = demande_invalide.get('demande_id')
    faux_un = rpc_json(db.sql(
        "select public.test_communication_confirmer_code('%s', %d, true, false);" % (CLIENT2, id_invalide)))
    faux_deux = rpc_json(db.sql(
        "select public.test_communication_confirmer_code('%s', %d, true, false);" % (CLIENT2, id_invalide)))
    verifier('code incorrect refusé et limite synthétique appliquée',
             (faux_un.get('ok'), faux_deux.get('ok'), faux_deux.get('bloque'),
              db.sql('select etat from public.communication_confirmations_whatsapp where id = %d;' % id_invalide)
              .splitlines()[-1].strip()),
             (False, False, True, 'bloque'))
    verifier('secret de confirmation supprimé après blocage',
             db.sql("select count(*) from vault.decrypted_secrets where name like 'goship-confirmation-%';")
             .splitlines()[-1].strip(), '0')

    demande_tempo = rpc_json(db.comme(
        CLIENT3,
        "select public.communication_consentement_demander_whatsapp('fixture-synthetique-v1', 'fr');"))
    id_tempo = demande_tempo.get('demande_id')
    db.sql("update public.communication_confirmations_whatsapp set expire_le = clock_timestamp() - interval '1 second' "
           "where id = %d;" % id_tempo)
    resultat_expire = rpc_json(db.comme(
        CLIENT3,
        "select public.communication_consentement_confirmer_whatsapp(lpad(floor(random() * 1000000)::integer::text, 6, '0'));"))
    verifier('code expiré refusé et état expiré enregistré',
             (resultat_expire.get('ok'),
              db.sql('select etat from public.communication_confirmations_whatsapp where id = %d;' % id_tempo)
              .splitlines()[-1].strip()),
             (False, 'expire'))
    verifier('secret de confirmation supprimé après expiration',
             db.sql("select count(*) from vault.decrypted_secrets where name like 'goship-confirmation-%';")
             .splitlines()[-1].strip(), '0')

    demande_refus = rpc_json(db.comme(
        CLIENT3,
        "select public.communication_consentement_demander_whatsapp('fixture-synthetique-v1', 'fr');"))
    verifier('refus explicite de la demande',
             rpc_json(db.comme(CLIENT3, 'select public.communication_consentement_refuser_whatsapp();')).get('etat'),
             'refuse')
    verifier('secret de confirmation supprimé après refus',
             db.sql("select count(*) from vault.decrypted_secrets where name like 'goship-confirmation-%';")
             .splitlines()[-1].strip(), '0')

    db.sql("update public.clients set telephone = '7865550101', pays = 'US' where id = '%s';" % CLIENT2)
    partage = db.erreur(
        CLIENT2,
        "select public.communication_consentement_demander_whatsapp('fixture-synthetique-v1', 'fr');")
    verifier('numéro partagé bloqué tant que la politique CEO est absente',
             partage, 'SHARED_TARGET_POLICY_REQUIRED')

    db.sql("update public.communication_consentement_reglages set maximum_demandes_compte = 1 where id is true;")
    demande_limitee = rpc_json(db.comme(
        CLIENT4,
        "select public.communication_consentement_demander_whatsapp('fixture-synthetique-v1', 'fr');"))
    db.comme(CLIENT4, 'select public.communication_consentement_refuser_whatsapp();')
    erreur_repete = db.erreur(
        CLIENT4,
        "select public.communication_consentement_demander_whatsapp('fixture-synthetique-v1', 'fr');")
    verifier('limite de demandes répétées testée avec valeur synthétique',
             (isinstance(demande_limitee.get('demande_id'), int), erreur_repete),
             (True, 'REQUEST_RATE_LIMITED'))
    db.sql("update public.communication_consentement_reglages set maximum_demandes_compte = 10 where id is true;")
    demande_purge = rpc_json(db.comme(
        CLIENT4,
        "select public.communication_consentement_demander_whatsapp('fixture-synthetique-v1', 'fr');"))
    db.sql("delete from public.clients where id = '%s';" % CLIENT4)
    verifier('effacement du compte supprime le secret en attente et anonymise les preuves',
             (isinstance(demande_purge.get('demande_id'), int),
              db.sql("select (select count(*) from vault.decrypted_secrets where name like 'goship-confirmation-%') = 0 "
                    "and (select count(*) from public.communication_consentement_historique "
                    "where client_id is null and consentement_id is null and demande_id is null) >= 1;")
              .splitlines()[-1].strip()),
             (True, 't'))
    verifier('indice d’unicité des codes ouverts par empreinte présent',
             db.sql("select to_regclass('public.communication_confirmations_whatsapp_code_contact_idx') is not null;")
             .splitlines()[-1].strip(), 't')
    verifier('texte attesté immuable après approbation',
             db.erreur('sql', "update public.communication_consentement_textes set texte = 'altéré' "
                       "where version = 'fixture-synthetique-v1';"),
             'COMMUNICATION_CONSENT_TEXT_IMMUTABLE')

    verifier('tables de consentement et confirmations inaccessibles directement',
             (db.erreur(CLIENT, 'select count(*) from public.communication_consentements_clients;').startswith('permission denied'),
              db.erreur(CLIENT, 'select count(*) from public.communication_confirmations_whatsapp;').startswith('permission denied'),
              db.erreur(CLIENT, 'select count(*) from public.communication_consentement_historique;').startswith('permission denied')),
             (True, True, True))
    verifier('rôle équipe sans fonction de consentement et visiteur anonyme refusés',
             (db.erreur(EMPLOYEE, "select public.communication_consentement_demander_whatsapp('fixture-synthetique-v1', 'fr');"),
              db.erreur(None, "select public.communication_consentement_demander_whatsapp('fixture-synthetique-v1', 'fr');")),
             ('PERMISSION_DENIED', 'permission denied for function communication_consentement_demander_whatsapp'))

    privileges = db.sql("""
      select has_function_privilege('authenticated', 'public.communication_consentement_demander_whatsapp(text,text,text)', 'execute')
         and not has_function_privilege('anon', 'public.communication_consentement_demander_whatsapp(text,text,text)', 'execute')
         and not has_function_privilege('service_role', 'public.communication_code_whatsapp_pour_envoi(bigint)', 'execute')
         and not has_function_privilege('authenticated', 'public.communication_code_whatsapp_pour_envoi(bigint)', 'execute')
         and not has_table_privilege('service_role', 'public.communication_confirmations_whatsapp', 'select');
    """).splitlines()[-1].strip()
    verifier('permissions client et récupération privée par tâche séparées', privileges, 't')
    securite = db.sql("""
      select bool_and(p.prosecdef and exists (
               select 1 from unnest(p.proconfig) c where c like 'search_path=%'))
        from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and p.proname in ('communication_consentement_demander_whatsapp',
                           'communication_consentement_etat_whatsapp',
                           'communication_consentement_confirmer_whatsapp',
                           'communication_consentement_refuser_whatsapp',
                           'communication_consentement_retirer_whatsapp',
                           'communication_code_whatsapp_pour_envoi');
    """).splitlines()[-1].strip()
    verifier('RPC SECURITY DEFINER à search_path explicite', securite, 't')
    rls = db.sql("""
      select bool_and(c.relrowsecurity)
        from pg_catalog.pg_class c
       where c.oid in ('public.communication_consentements_clients'::regclass,
                       'public.communication_confirmations_whatsapp'::regclass,
                       'public.communication_consentement_historique'::regclass,
                       'public.communication_confirmation_tentatives'::regclass);
    """).splitlines()[-1].strip()
    verifier('RLS activée sur l’état, les demandes, l’historique et les tentatives', rls, 't')

    verifier('historique append-only contre UPDATE et DELETE',
             (db.erreur('sql', "update public.communication_consentement_historique set action = 'demande';"),
              db.erreur('sql', 'delete from public.communication_consentement_historique;')),
             ('COMMUNICATION_CONSENT_HISTORY_IMMUTABLE', 'COMMUNICATION_CONSENT_HISTORY_IMMUTABLE'))
    verifier('tentatives append-only contre UPDATE et DELETE',
             (db.erreur('sql', "update public.communication_confirmation_tentatives set resultat = 'rejeu';"),
              db.erreur('sql', 'delete from public.communication_confirmation_tentatives;')),
             ('COMMUNICATION_CONFIRMATION_ATTEMPTS_IMMUTABLE', 'COMMUNICATION_CONFIRMATION_ATTEMPTS_IMMUTABLE'))

    champs = db.sql("""
      select not exists (
        select 1 from information_schema.columns
         where table_schema = 'public' and table_name = 'communication_confirmations_whatsapp'
           and column_name in ('code', 'code_clair', 'telephone', 'numero'))
         and exists (select 1 from information_schema.columns
                      where table_schema = 'public' and table_name = 'communication_confirmations_whatsapp'
                        and column_name = 'code_secret_id' and data_type = 'uuid');
    """).splitlines()[-1].strip()
    verifier('aucun code en clair ni contact brut dans la table de demandes', champs, 't')

    verifier('historique et journal de tentatives sans champ code ni contact brut',
             db.sql("select not exists (select 1 from information_schema.columns "
                    "where table_schema='public' and table_name in "
                    "('communication_consentement_historique','communication_confirmation_tentatives') "
                    "and column_name in ('code','code_clair','telephone','numero')); ")
             .splitlines()[-1].strip(), 't')


def tester_transactionnel(db, numero_base):
    print('\nÉvénements et envois transactionnels — base neuve %d' % numero_base)

    # Ces valeurs restent dans le PostgreSQL jetable. Elles ne correspondent à
    # aucun compte fournisseur et ne sont jamais imprimées dans les résultats.
    db.sql("""
      insert into vault.decrypted_secrets (name, decrypted_secret) values
        ('email_cle_api', 'fixture-locale-sans-validite'),
        ('email_expediteur', 'no-reply@goship.test'),
        ('email_fournisseur', 'brevo'),
        ('whatsapp_jeton', 'synthetic-whatsapp-token-not-valid'),
        ('whatsapp_numero_id', 'synthetic-phone-number-id'),
        ('whatsapp_version', 'v23.0')
      on conflict (name) do update set decrypted_secret = excluded.decrypted_secret;
      update public.notification_regles
         set canaux = array['email']::text[]
       where type in ('shipment_received', 'shipment_shipped', 'action_required',
                      'action_resolved', 'shipment_available', 'shipment_delivered');
    """)

    cree = S.creer(db, ADMIN, {
        'client_id': CLIENT,
        'description': 'Colis synthétique pour l’essai transactionnel',
        'expediteur': 'Fixture locale',
        'poids_lb': 1,
        'service': 'aerien',
        'lieu': 'Miami (Medley), FL',
        'pays_destination': 'DO',
        'destination': 'Santo Domingo',
    }, cle='c2-evenement-%d' % numero_base, facturer=False)
    colis = (cree or {}).get('colis') or {}
    colis_id = colis.get('id')
    verifier('création par le service métier GoShip', bool(colis_id), True)
    if not colis_id:
        return

    transitions = (
        ('embarque', 'Miami', ''),
        ('incident', 'Miami', 'Action requise'),
        ('embarque', 'Miami', 'Action résolue'),
        ('disponible', 'Santo Domingo', ''),
        ('livre', 'Santo Domingo', ''),
    )
    transitions_ok = True
    for statut, lieu, note in transitions:
        resultat = S.statut(db, ADMIN, [colis_id], statut, lieu, note)
        modifies = (resultat or {}).get('modifies')
        verifier('transition métier %s enregistrée' % statut, modifies, 1)
        transitions_ok = transitions_ok and modifies == 1
    if not transitions_ok:
        return

    types_attendus = ('shipment_received', 'shipment_shipped', 'action_required',
                      'action_resolved', 'shipment_available', 'shipment_delivered')
    types_observes = db.sql(
        "select coalesce(string_agg(n.type, ',' order by h.id), '') "
        "from public.notifications n join public.colis_historique h on h.id = n.historique_id "
        "where n.colis_id = '%s' and n.client_id = '%s' and n.canal = 'app';" %
        (colis_id, CLIENT)).splitlines()[-1].strip()
    verifier('un événement GoShip réel par étape attendue',
             tuple(types_observes.split(',')) if types_observes else (), types_attendus)

    nombre_outbox = db.sql(
        "select count(*) from public.communication_transactionnelle_outbox o "
        "join public.notifications n on n.id = o.notification_id "
        "where n.colis_id = '%s';" % colis_id).splitlines()[-1].strip()
    verifier('outbox liée aux six événements et au colis existant', nombre_outbox, '6')

    lignes = rpc_json(db.comme(ADMIN, 'select public.communication_lister_outbox_transactionnel(500);'))
    lignes_colis = [ligne for ligne in (lignes or []) if ligne.get('notification_id') in {
        int(v) for v in db.sql("select id from public.notifications where colis_id = '%s';" % colis_id)
        .splitlines() if v.strip().isdigit()
    }]
    cles = [ligne.get('cle_idempotence') for ligne in lignes_colis]
    verifier('version, langue, source et clés d’idempotence présents',
             (len(lignes_colis), all(ligne.get('modele_version') == 1 for ligne in lignes_colis),
              all(ligne.get('modele_langue') == 'fr' for ligne in lignes_colis),
              all(ligne.get('source_evenement_type') == 'colis_historique'
                  and ligne.get('source_evenement_id') for ligne in lignes_colis),
              len(set(cles)) == 6),
             (6, True, True, True, True))
    champs_sensibles = {'cible', 'client_id', 'colis_id', 'erreur', 'telephone', 'email'}
    verifier('supervision sans destinataire, contenu d’erreur libre ni identifiants client/colis',
             any(champs_sensibles.intersection(ligne) for ligne in lignes_colis), False)

    notification_id = int(db.sql(
        "select id from public.notifications where colis_id = '%s' "
        "and type = 'shipment_received' and canal = 'app' limit 1;" % colis_id)
        .splitlines()[-1].strip())
    apercu = rpc_json(db.comme(
        ADMIN, 'select public.communication_previsualiser_transactionnelle(%d, \'fr\');' % notification_id))
    verifier('prévisualisation locale du modèle versionné',
             (apercu.get('type'), apercu.get('version'), apercu.get('langue'),
              bool((apercu.get('modele') or {}).get('titre'))),
             ('shipment_received', 1, 'fr', True))
    verifier('employé et client sans permission de supervision refusés',
             (db.erreur(EMPLOYEE, 'select public.communication_lister_outbox_transactionnel(10);'),
              db.erreur(CLIENT, 'select public.communication_previsualiser_transactionnelle(%d, \'fr\');'
                        % notification_id)),
             ('PERMISSION_DENIED', 'PERMISSION_DENIED'))
    verifier('variable obligatoire absente refusée par le rendu',
             db.erreur('sql', "select public.communication_rendre_modele_transactionnel("
                       "'shipment_received', 'fr', '{}'::jsonb, 1);"),
             'COMMUNICATION_TEMPLATE_VARIABLE_REQUIRED')

    doublon = db.sql(
        "select public.creer_notification(n.type, n.client_id, n.cle, n.colis_id, n.facture_id, "
        "n.paiement_id, n.historique_id, n.donnees) is null "
        "from public.notifications n where n.id = %d;" % notification_id).splitlines()[-1].strip()
    nombre_apres_doublon = db.sql(
        "select count(*) from public.communication_transactionnelle_outbox o "
        "join public.notifications n on n.id = o.notification_id where n.colis_id = '%s';" % colis_id
    ).splitlines()[-1].strip()
    verifier('rejeu du même événement sans notification ni transmission dupliquée',
             (doublon, nombre_apres_doublon), ('t', '6'))
    verifier('aucun consentement marketing créé par les événements transactionnels',
             db.sql("select count(*) from public.communication_consentements_clients "
                    "where client_id = '%s';" % CLIENT).splitlines()[-1].strip(), '0')

    ids = {}
    for type_notification in types_attendus:
        resultat = db.sql(
            "select e.id from public.notification_envois e "
            "join public.notifications n on n.id = e.notification_id "
            "where n.colis_id = '%s' and n.type = '%s' and e.canal = 'email';" %
            (colis_id, type_notification)).splitlines()
        if resultat and resultat[-1].strip().isdigit():
            ids[type_notification] = int(resultat[-1].strip())
    verifier('file transactionnelle issue des règles et préférences existantes', len(ids), 6)
    if len(ids) != 6:
        return

    notification_recue_id = int(db.sql(
        'select notification_id from public.notification_envois where id = %d;' % ids['shipment_received']
    ).splitlines()[-1].strip())
    appareil_test = 'eeeeeeee-0000-0000-0000-000000000001'
    db.sql("insert into public.appareils (id,client_id,jeton,plateforme,langue) "
           "values ('%s','%s','ExponentPushToken[synthetic-local-only]','ios','fr');"
           % (appareil_test, CLIENT))
    db.sql("""
      insert into public.notification_envois
        (notification_id, canal, cible, appareil_id, fournisseur, statut, priorite)
      values (%d, 'push', 'appareil:%s', '%s', 'expo', 'annule', 'normale'),
             (%d, 'whatsapp', 'synthetic-whatsapp', null, 'meta', 'annule', 'normale'),
             (%d, 'email', 'synthetic-resend', null, 'resend', 'annule', 'normale');
    """ % (notification_recue_id, appareil_test, appareil_test,
           notification_recue_id, notification_recue_id))
    extra_ids = {}
    for cible in ('appareil:' + appareil_test, 'synthetic-whatsapp', 'synthetic-resend'):
        extra_ids[cible] = int(db.sql(
            "select id from public.notification_envois where notification_id=%d and cible='%s';"
            % (notification_recue_id, cible)).splitlines()[-1].strip())
    db.sql("update public.notification_envois set statut='annule', code_erreur='C3_FIXTURE' "
           "where id in (%s);" % ','.join(str(v) for v in list(ids.values()) + list(extra_ids.values())))

    # Le net.http_post de cette base est une doublure SQL qui ne sort jamais du processus.
    # L'expéditeur historique lui transmet les corps réellement générés par GoShip.
    contrats_sortants = (
        (ids['shipment_received'], 'Brevo',
         "url='https://api.brevo.com/v3/smtp/email' and headers ? 'api-key' "
         "and body ? 'sender' and body ? 'to' and body ? 'subject' "
         "and body ? 'htmlContent' and body ? 'textContent'"),
        (extra_ids['synthetic-resend'], 'Resend',
         "url='https://api.resend.com/emails' and headers ? 'Authorization' "
         "and body ? 'from' and body ? 'to' and body ? 'subject' and body ? 'html' and body ? 'text'"),
        (extra_ids['appareil:' + appareil_test], 'Expo',
         "url='https://exp.host/--/api/v2/push/send' and jsonb_typeof(body)='array' "
         "and body->0 ? 'to' and body->0 ? 'title' and body->0 ? 'data'"),
        (extra_ids['synthetic-whatsapp'], 'Meta WhatsApp',
         "url='https://graph.facebook.com/v23.0/synthetic-phone-number-id/messages' "
         "and headers ? 'Authorization' and body->>'messaging_product'='whatsapp' "
         "and body->>'type'='template' and body->'template' ? 'components'"),
    )
    for envoi_id, nom, condition in contrats_sortants:
        fournisseur_email = 'resend' if nom == 'Resend' else 'brevo'
        db.sql("update vault.decrypted_secrets set decrypted_secret='%s' "
               "where name='email_fournisseur';" % fournisseur_email)
        db.sql("update public.notification_envois set statut='attente', code_erreur=null, "
               "prochain_essai_le=now() where id=%d;" % envoi_id)
        db.sql('select public.traiter_notifications(1);')
        requete = db.sql("select requete from public.notification_envois where id=%d;" % envoi_id)
        requete = requete.splitlines()[-1].strip()
        contrat_valide = db.sql("select %s from net.envois where id=%s;" % (condition, requete))
        verifier('contrat sortant historique capturé localement pour %s' % nom,
                 contrat_valide.splitlines()[-1].strip(), 't')
        db.sql("update public.notification_envois set statut='annule', requete=null, "
               "verrouille_le=null, code_erreur='C3_FIXTURE_CAPTUREE' where id=%d;" % envoi_id)

    format_email = db.sql("select public.communication_adresse_courriel_valide('fixture@goship.test')::text "
                          "|| '|' || public.communication_adresse_courriel_valide('invalid-synthetic-address')::text;")
    verifier('validation syntaxique email sans exposer le destinataire',
             format_email.splitlines()[-1].strip(), 'true|false')
    nombre_requetes_avant = db.sql('select count(*) from net.envois;').splitlines()[-1].strip()
    db.sql("update public.clients set email='invalid-synthetic-address' where id='%s';" % CLIENT)
    db.sql("update public.notification_envois set statut='attente', code_erreur=null, "
           "prochain_essai_le=now() where id=%d;" % ids['action_required'])
    db.sql('select public.traiter_notifications(1);')
    resultat_email_invalide = db.sql("select statut || '|' || code_erreur "
        "from public.notification_envois where id=%d;" % ids['action_required']).splitlines()[-1].strip()
    nombre_requetes_apres = db.sql('select count(*) from net.envois;').splitlines()[-1].strip()
    db.sql("update public.clients set email='client@goship.test' where id='%s';" % CLIENT)
    verifier('adresse email invalide écartée avant la requête fournisseur',
             (resultat_email_invalide, nombre_requetes_avant, nombre_requetes_apres),
             ('annule|SANS_DESTINATAIRE', nombre_requetes_avant, nombre_requetes_avant))

    # L'adaptateur remplace le point d'envoi uniquement dans cette base jetable.
    # Son URL locale n'est pas routable vers un fournisseur.
    db.sql("""
      create or replace function public.communication_expedier_envoi_sans_porte(
        p_envoi public.notification_envois)
      returns bigint language plpgsql security definer set search_path = '' as $local$
      declare v_requete bigint;
      begin
        perform pg_catalog.pg_sleep(case
          when pg_catalog.current_setting('goship.test_p07_hold', true) = 'true' then 6
          else 0.3 end);
        insert into net.envois (url, headers, body)
        values ('local://goship-test-adapter', '{}'::jsonb,
                jsonb_build_object('notification_envoi_id', p_envoi.id, 'canal', p_envoi.canal))
        returning id into v_requete;
        return v_requete;
      end
      $local$;
    """)

    succes_id = ids['shipment_received']
    db.sql("update public.notification_envois set statut = 'attente', code_erreur = null, "
           "prochain_essai_le = now() where id = %d;" % succes_id)
    sorties = []
    erreurs = []
    barriere = threading.Barrier(2)

    def lancer_travailleur():
        try:
            barriere.wait(timeout=10)
            sorties.append(db.sql('select public.traiter_notifications(1);'))
        except Exception as erreur:
            erreurs.append(type(erreur).__name__)

    travailleurs = [threading.Thread(target=lancer_travailleur) for _ in range(2)]
    for travailleur in travailleurs:
        travailleur.start()
    for travailleur in travailleurs:
        travailleur.join(15)
    requetes_succes = db.sql(
        "select count(*) from net.envois where body ->> 'notification_envoi_id' = '%d';" % succes_id
    ).splitlines()[-1].strip()
    verifier('deux travailleurs concurrents ne préparent qu’une transmission',
             (len(sorties), erreurs, requetes_succes), (2, [], '1'))
    requete = db.sql(
        "select requete from public.notification_envois where id = %d;" % succes_id
    ).splitlines()[-1].strip()
    db.sql("insert into net._http_response (id, status_code, content, error_msg) "
           "values (%s, 200, '{\"id\":\"local-accepted\"}', null);" % requete)
    db.sql('select public.traiter_notifications(1);')
    verifier('réponse locale positive enregistrée comme acceptée',
             db.sql("select statut from public.notification_envois where id = %d;" % succes_id)
             .splitlines()[-1].strip(), 'envoye')

    temporaire_id = ids['shipment_available']
    db.sql("update public.notification_envois set statut = 'attente', code_erreur = null, "
           "prochain_essai_le = now() where id = %d;" % temporaire_id)
    db.sql('select public.traiter_notifications(1);')
    requete_429 = db.sql(
        "select requete from public.notification_envois where id = %d;" % temporaire_id
    ).splitlines()[-1].strip()
    db.sql("insert into net._http_response (id, status_code, content, error_msg) "
           "values (%s, 429, '{\"error\":\"local-rate-limit\"}', null);" % requete_429)
    db.sql('select public.traiter_notifications(1);')
    etat_429 = db.sql("select statut || '|' || code_erreur from public.notification_envois where id = %d;"
                      % temporaire_id).splitlines()[-1].strip()
    verifier('erreur temporaire programmée pour reprise', etat_429, 'attente|LIMITE_DEBIT')
    db.sql("update public.notification_envois set prochain_essai_le = now() where id = %d;" % temporaire_id)
    db.sql('select public.traiter_notifications(1);')
    requete_reprise = db.sql(
        "select requete from public.notification_envois where id = %d;" % temporaire_id
    ).splitlines()[-1].strip()
    db.sql("insert into net._http_response (id, status_code, content, error_msg) "
           "values (%s, 200, '{\"id\":\"local-retry-accepted\"}', null);" % requete_reprise)
    db.sql('select public.traiter_notifications(1);')
    verifier('reprise temporaire acceptée une seule fois après deux tentatives',
             db.sql("select statut || '|' || tentative from public.notification_envois where id = %d;"
                    % temporaire_id).splitlines()[-1].strip(), 'envoye|2')

    definitif_id = ids['action_required']
    db.sql("update public.notification_envois set statut = 'attente', code_erreur = null, "
           "prochain_essai_le = now() where id = %d;" % definitif_id)
    db.sql('select public.traiter_notifications(1);')
    requete_400 = db.sql(
        "select requete from public.notification_envois where id = %d;" % definitif_id
    ).splitlines()[-1].strip()
    db.sql("insert into net._http_response (id, status_code, content, error_msg) "
           "values (%s, 400, '{}', null);" % requete_400)
    db.sql('select public.traiter_notifications(1);')
    verifier('rejet définitif clos sans reprise',
             db.sql("select statut || '|' || tentative from public.notification_envois where id = %d;"
                    % definitif_id).splitlines()[-1].strip(), 'echec|1')

    incertain_id = ids['action_resolved']
    db.sql("update public.notification_envois set statut = 'attente', code_erreur = null, "
           "prochain_essai_le = now() where id = %d;" % incertain_id)
    db.sql('select public.traiter_notifications(1);')
    db.sql("update public.notification_envois set verrouille_le = now() - interval '11 minutes' "
           "where id = %d;" % incertain_id)
    db.sql('select public.traiter_notifications(1);')
    compte_avant = db.sql(
        "select count(*) from net.envois where body ->> 'notification_envoi_id' = '%d';" % incertain_id
    ).splitlines()[-1].strip()
    db.sql('select public.traiter_notifications(1);')
    compte_apres = db.sql(
        "select count(*) from net.envois where body ->> 'notification_envoi_id' = '%d';" % incertain_id
    ).splitlines()[-1].strip()
    # Décision K (CEO, 23/11/2026) : le silence du fournisseur d'une notification
    # transactionnelle est un échec temporaire, réessayé comme dans le moteur officiel.
    verifier('décision K : un silence de 10 min est réessayé (attente, RESEAU), pas avant l\'heure',
             (db.sql("select statut || '|' || code_erreur || '|' || tentative "
                     "from public.notification_envois where id = %d;"
                     % incertain_id).splitlines()[-1].strip(), compte_avant, compte_apres),
             ('attente|RESEAU|1', '1', '1'))
    db.sql("update public.notification_envois set prochain_essai_le = now() where id = %d;" % incertain_id)
    db.sql('select public.traiter_notifications(1);')
    requete_k = db.sql("select requete from public.notification_envois where id = %d;"
                       % incertain_id).splitlines()[-1].strip()
    db.sql("insert into net._http_response (id, status_code, content, error_msg) "
           "values (%s, 503, 'Service Unavailable', null);" % requete_k)
    db.sql('select public.traiter_notifications(1);')
    verifier('décision K : 2e essai envoyé, puis 503 reprogrammé (attente, HTTP_503)',
             (db.sql("select statut || '|' || code_erreur || '|' || tentative "
                     "from public.notification_envois where id = %d;"
                     % incertain_id).splitlines()[-1].strip(),
              db.sql("select count(*) from net.envois where body ->> 'notification_envoi_id' = '%d';"
                     % incertain_id).splitlines()[-1].strip()),
             ('attente|HTTP_503|2', '2'))
    db.sql("update public.notification_envois set prochain_essai_le = now() where id = %d;" % incertain_id)
    db.sql('select public.traiter_notifications(1);')
    requete_k = db.sql("select requete from public.notification_envois where id = %d;"
                       % incertain_id).splitlines()[-1].strip()
    db.sql("insert into net._http_response (id, status_code, content, error_msg) "
           "values (%s, null, null, 'Timeout of 5000 ms reached');" % requete_k)
    db.sql('select public.traiter_notifications(1);')
    verifier('décision K : au 3e essai, délai dépassé = abandon, jamais d\'essai infini',
             db.sql("select statut || '|' || code_erreur || '|' || tentative "
                    "from public.notification_envois where id = %d;"
                    % incertain_id).splitlines()[-1].strip(), 'echec|ABANDON_RESEAU|3')

    presence_porte = db.sql(
        "select to_regprocedure('public.communication_autoriser_sortie(text,text)') is not null;"
    ).splitlines()[-1].strip()
    verifier('porte P-07 disponible pour synchroniser le travailleur transactionnel', presence_porte, 't')

    return ids


def service_sql(db, texte, echec_permis=False):
    return db._psql('authenticator', S.BASE, 'set role service_role;\n' + texte, echec_permis)


def service_json(db, texte):
    sortie = service_sql(db, texte)
    lignes = [ligne.strip() for ligne in sortie.splitlines() if ligne.strip().startswith('{')]
    if not lignes:
        raise SystemExit('La fonction de contrôle locale n’a pas retourné son état JSON.')
    return json.loads(lignes[-1])


def compter_envois_locaux(db, envoi_id):
    return db.sql("select count(*) from net.envois where body ->> 'notification_envoi_id' = '%d';"
                  % envoi_id).splitlines()[-1].strip()


def tester_p07(db, numero_base, ids):
    print('\nP-07 — synchronisation Kill Switch — base neuve %d' % numero_base)
    if not ids:
        verifier('identifiants transactionnels disponibles pour P-07', False, True)
        return

    droits = db.sql("select not has_function_privilege('authenticated', "
                    "'public.communication_autoriser_sortie(text,text)', 'execute') "
                    "and not has_function_privilege('service_role', "
                    "'public.communication_autoriser_sortie(text,text)', 'execute');")
    verifier('porte interne non appelable par les rôles applicatifs',
             droits.splitlines()[-1].strip(), 't')

    autorisation = db.sql("with a as materialized ("
                          "select public.communication_autoriser_sortie('envoi','email') as raison) "
                          "select raison is null and "
                          "public.communication_sortie_autorisee('envoi','email') from a;")
    verifier('sortie email autorisée quand le Kill Switch est actif',
             autorisation.splitlines()[-1].strip(), 't')

    # Le même marqueur ne doit pas autoriser deux appels à l'adaptateur.
    double_id = ids['shipment_shipped']
    avant_double = compter_envois_locaux(db, double_id)
    db.sql("""
      do $p07$
      declare e public.notification_envois; v_raison text;
      begin
        select * into e from public.notification_envois where id = %d;
        v_raison := public.communication_autoriser_sortie('envoi', e.canal);
        if v_raison is not null then raise exception 'P07_INITIAL_GATE'; end if;
        perform public.expedier_envoi(e);
        begin
          perform public.expedier_envoi(e);
          raise exception 'P07_DOUBLE_OUTPUT_ALLOWED';
        exception when sqlstate '55000' then
          if sqlerrm <> 'COMMUNICATION_OUTPUT_BLOCKED' then raise; end if;
        end;
      end
      $p07$;
    """ % double_id)
    verifier('une autorisation transactionnelle ne peut être consommée deux fois',
             compter_envois_locaux(db, double_id), str(int(avant_double) + 1))

    # Injecter une attente uniquement dans l'adaptateur local. Le travailleur
    # tient N0 partagé et le verrou de la ligne d'outbox pendant ce délai.
    hold_id = ids['shipment_delivered']
    db.sql("update public.notification_envois set statut = 'attente', code_erreur = null, "
           "prochain_essai_le = now() where id = %d;" % hold_id)
    erreurs = []
    sorties = []

    def envoyer_sous_verrou():
        try:
            sorties.append(service_sql(db, "begin; "
                "select pg_catalog.set_config('goship.test_p07_hold','true',true); "
                "select public.traiter_notifications(1); commit;"))
        except Exception as erreur:
            erreurs.append(type(erreur).__name__)

    travailleur = threading.Thread(target=envoyer_sous_verrou)
    travailleur.start()
    en_pause = False
    limite = time.time() + 8
    while time.time() < limite:
        etat = db.sql("select exists (select 1 from pg_catalog.pg_stat_activity "
                      "where datname = current_database() and pid <> pg_catalog.pg_backend_pid() "
                      "and wait_event = 'PgSleep');").splitlines()[-1].strip()
        if etat == 't':
            en_pause = True
            break
        time.sleep(0.05)
    verifier('travailleur bloqué dans l’adaptateur local sous N0', en_pause, True)
    if not en_pause:
        travailleur.join(8)
        return

    debut_demande = time.monotonic()
    demande = service_json(db, "select public.communication_demander_arret('arrêt local de test');")
    duree_demande = time.monotonic() - debut_demande
    verifier('demande d’arrêt persistée sans attendre le verrou N0',
             (demande.get('etat'), duree_demande < 1.5), ('STOP_REQUESTED', True))

    confirmation_concurrente = service_json(db, "select public.communication_confirmer_arret();")
    verifier('confirmation concurrente reste en attente sous N0',
             (confirmation_concurrente.get('etat'), confirmation_concurrente.get('raison')),
             ('STOP_PENDING', 'VERROU_NON_OBTENU'))
    durable = db.sql("select etat || '|' || (demande_le is not null)::text "
                     "from public.communication_arret where id is true;")
    verifier('échec de confirmation ne supprime pas la demande validée',
             durable.splitlines()[-1].strip(), 'arret_demande|true')

    travailleur.join(10)
    verifier('envoi déjà autorisé termine sans deadlock',
             (not travailleur.is_alive(), erreurs), (True, []))
    verifier('adaptateur local a préparé une seule requête pour l’envoi concurrent',
             compter_envois_locaux(db, hold_id), '1')
    statut_envoi = db.sql("select statut from public.notification_envois where id = %d;" % hold_id)
    verifier('transmission autorisée avant l’arrêt reste suivie dans l’outbox',
             statut_envoi.splitlines()[-1].strip(), 'envoi')

    confirmation = service_json(db, "select public.communication_confirmer_arret();")
    verifier('fermeture durable conservée pendant les reprises avec envois en cours',
             (confirmation.get('etat'), confirmation.get('raison'),
              db.sql("select autorisations_closes_le is not null from public.communication_arret "
                     "where id is true;").splitlines()[-1].strip()),
             ('STOP_PENDING', 'TRANSMISSIONS_EN_COURS', 't'))

    requete = db.sql("select requete from public.notification_envois where id = %d;" % hold_id)
    requete = requete.splitlines()[-1].strip()
    db.sql("insert into net._http_response (id, status_code, content, error_msg) "
           "values (%s, 200, '{\"id\":\"local-p07-accepted\"}', null);" % requete)
    sorties_avant_reponse = compter_envois_locaux(db, hold_id)
    service_sql(db, 'select public.traiter_notifications(1);')
    verifier('traitement de la réponse ne déclenche aucune nouvelle sortie',
             (db.sql("select statut from public.notification_envois where id = %d;" % hold_id)
              .splitlines()[-1].strip(), compter_envois_locaux(db, hold_id)),
             ('envoye', sorties_avant_reponse))

    incertain_id = ids['action_resolved']
    # Depuis la décision K, un silence ou une 5xx est réessayé : la ligne a été
    # abandonnée plus haut. On la place dans le cas qui reste incertain (réponse 2xx
    # sans identifiant de message), fixture synthétique comme sa résolution plus bas.
    db.sql("update public.notification_envois set statut = 'incertain', "
           "code_erreur = 'REPONSE_INCOMPLETE', maj_le = now() where id = %d;" % incertain_id)
    attente_incertain = service_json(db, "select public.communication_confirmer_arret();")
    verifier('état incertain bloque une confirmation d’arrêt prématurée',
             (attente_incertain.get('etat'), attente_incertain.get('raison'),
              db.sql("select statut from public.notification_envois where id = %d;" % incertain_id)
              .splitlines()[-1].strip()),
             ('STOP_PENDING', 'TRANSMISSIONS_EN_COURS', 'incertain'))

    # Résolution synthétique de la fixture incertaine, sans simuler une action UI.
    db.sql("update public.notification_envois set statut = 'echec', "
           "code_erreur = 'ESSAI_RECONCILIE_LOCALEMENT', maj_le = now() where id = %d;" % incertain_id)
    finale = service_json(db, "select public.communication_confirmer_arret();")
    etat_final = db.sql("select etat || '|' || (autorisations_closes_le is not null)::text "
                        "|| '|' || (confirme_le >= autorisations_closes_le)::text "
                        "from public.communication_arret where id is true;")
    verifier('arrêt confirmé après résolution de toutes les transmissions',
             (finale.get('etat'), etat_final.splitlines()[-1].strip()),
             ('STOP_CONFIRMED', 'arret_confirme|true|true'))
    repetee = service_json(db, "select public.communication_confirmer_arret();")
    verifier('confirmation répétée idempotente', repetee.get('etat'), 'STOP_CONFIRMED')

    post_stop_id = ids['shipment_shipped']
    db.sql("update public.notification_envois set statut = 'attente', code_erreur = null, "
           "prochain_essai_le = now() where id = %d;" % post_stop_id)
    avant_stop = compter_envois_locaux(db, post_stop_id)
    service_sql(db, 'select public.traiter_notifications(1);')
    verifier('nouvelle sortie refusée après confirmation sans appel adaptateur',
             (db.sql("select statut from public.notification_envois where id = %d;" % post_stop_id)
              .splitlines()[-1].strip(), compter_envois_locaux(db, post_stop_id)),
             ('attente', avant_stop))


def tester_adaptateurs_et_callbacks(db, numero_base):
    print('\nAdaptateurs de canaux et retours P-08 — base neuve %d' % numero_base)

    notification_id = int(db.sql(
        "select notification_id from public.notification_envois e "
        "join public.notifications n on n.id = e.notification_id "
        "where n.type = 'shipment_shipped' and e.canal = 'email' limit 1;"
    ).splitlines()[-1].strip())
    email_brevo_id = int(db.sql(
        "select e.id from public.notification_envois e join public.notifications n on n.id=e.notification_id "
        "where n.type='shipment_shipped' and e.canal='email' limit 1;"
    ).splitlines()[-1].strip())
    db.sql("update public.notification_envois set statut='annule', code_erreur='C3_FIXTURE' where id=%d;"
           % email_brevo_id)
    db.sql("""
      insert into public.notification_envois
        (notification_id, canal, cible, fournisseur, statut, priorite)
      values (%d, 'push', 'synthetic-device', 'expo', 'annule', 'normale'),
             (%d, 'whatsapp', 'synthetic-whatsapp', 'meta', 'annule', 'normale'),
             (%d, 'email', 'synthetic-resend-destination', 'resend', 'annule', 'normale');
    """ % (notification_id, notification_id, notification_id))
    push_id, whatsapp_id, resend_id = [int(v) for v in db.sql(
        "select id from public.notification_envois where notification_id=%d "
        "and cible in ('synthetic-device','synthetic-whatsapp','synthetic-resend-destination') "
        "order by case canal when 'push' then 1 when 'whatsapp' then 2 else 3 end;" % notification_id
    ).splitlines() if v.strip().isdigit()]

    # Couvrir les vrais contrats de réponse déjà employés par les trois chemins historiques.
    reponses = (
        (email_brevo_id, 'email', '{"messageId":"fixture-brevo-message-id"}', 'fixture-brevo-message-id'),
        (push_id, 'push', '{"data":[{"status":"ok","id":"fixture-expo-ticket-id"}]}',
         'fixture-expo-ticket-id'),
        (whatsapp_id, 'whatsapp', '{"messages":[{"id":"fixture-meta-message-id"}]}',
         'fixture-meta-message-id'),
        (resend_id, 'email', '{"id":"fixture-resend-message-id"}', 'fixture-resend-message-id'),
    )
    db.sql("update public.notification_envois set statut='annule', code_erreur='C3_FIXTURE' "
           "where id in (%s);" % ','.join(str(item[0]) for item in reponses))
    for envoi_id, canal, contenu, message_id in reponses:
        db.sql("update public.notification_envois set statut='attente', code_erreur=null, "
               "prochain_essai_le=now() where id=%d;" % envoi_id)
        db.sql('select public.traiter_notifications(1);')
        requete = db.sql("select requete from public.notification_envois where id=%d;" % envoi_id)
        requete = requete.splitlines()[-1].strip()
        db.sql("insert into net._http_response(id,status_code,content,error_msg) "
               "values (%s,200,$c3$%s$c3$,null);" % (requete, contenu))
        db.sql('select public.traiter_notifications(1);')
        observe = db.sql("select statut || '|' || coalesce(message_id,'') "
                         "from public.notification_envois where id=%d;" % envoi_id)
        verifier('réponse acceptée et identifiant corrélé pour %s' % canal,
                 observe.splitlines()[-1].strip(), 'envoye|' + message_id)
        verifier('une seule requête locale pour le canal %s' % canal,
                 compter_envois_locaux(db, envoi_id), '1')

    classes = (
        ("select public.communication_normaliser_reponse_canal('email',200,'{\"messageId\":\"id\"}',null);",
         'accepte'),
        ("select public.communication_normaliser_reponse_canal('email',400,'{}',null);", 'refuse'),
        ("select public.communication_normaliser_reponse_canal('email',401,'{}',null);", 'definitif'),
        ("select public.communication_normaliser_reponse_canal('push',200,"
         "'{\"data\":[{\"status\":\"error\",\"details\":{\"error\":\"MessageRateExceeded\"}}]}',null);",
         'temporaire'),
        ("select public.communication_normaliser_reponse_canal('push',200,"
         "'{\"data\":[{\"status\":\"error\",\"details\":{\"error\":\"DeviceNotRegistered\"}}]}',null);",
         'definitif'),
        ("select public.communication_normaliser_reponse_canal('whatsapp',503,'{}',null);", 'incertain'),
        ("select public.communication_normaliser_reponse_canal('email',200,'{}','synthetic-private-error');",
         'incertain'),
    )
    for requete, attendu in classes:
        resultat = rpc_json(db.sql(requete))
        verifier('classification de réponse fournisseur %s' % attendu,
                 resultat.get('classe'), attendu)
    sans_fuite = rpc_json(db.sql(
        "select public.communication_normaliser_reponse_canal('email',200,'{}',"
        "'synthetic-private-error');"))
    verifier('erreur libre absente du résultat normalisé',
             'synthetic-private-error' in json.dumps(sans_fuite), False)

    # Le RPC P-08 reçoit une enveloppe déjà normalisée. Les clés restent synthétiques
    # et exclusivement dans la base locale ; le rôle application n'a pas accès au RPC.
    db.sql("insert into vault.decrypted_secrets(name,decrypted_secret) "
           "values ('communication_cle_webhook','synthetic-webhook-secret') "
           "on conflict(name) do update set decrypted_secret=excluded.decrypted_secret;")
    privileges = db.sql("select has_function_privilege('communication_webhook', "
        "'public.communication_recevoir_statut_transactionnel(text,text,text)', 'execute') "
        "and not has_function_privilege('service_role', "
        "'public.communication_recevoir_statut_transactionnel(text,text,text)', 'execute') "
        "and not has_function_privilege('anon', "
        "'public.communication_recevoir_statut_transactionnel(text,text,text)', 'execute') "
        "and (select rolcanlogin=false from pg_catalog.pg_roles where rolname='communication_webhook');")
    verifier('réception de callback réservée au rôle dédié sans connexion',
             privileges.splitlines()[-1].strip(), 't')
    # Le banc doit pouvoir jouer l'appel Edge sans accorder ce rôle dans la candidate.
    # Cette appartenance n'existe que dans la base jetable de test.
    db.sql('grant communication_webhook to authenticator;')

    def recevoir(fournisseur, charge, signature=None):
        if signature is None:
            signature = db.sql(
                "select encode(extensions.hmac('%s:' || $c3$%s$c3$, "
                "'synthetic-webhook-secret','sha256'),'hex');" % (fournisseur, charge)
            ).splitlines()[-1].strip()
        sortie = db._psql('authenticator', S.BASE,
            "set role communication_webhook;\n"
            "select public.communication_recevoir_statut_transactionnel('%s',$c3$%s$c3$,'%s');"
            % (fournisseur, charge, signature))
        return rpc_json(sortie)

    callbacks = (
        ('meta', 'delivered', 'fixture-meta-message-id', 'meta:fixture-delivered-1'),
        ('brevo', 'delivered', 'fixture-brevo-message-id', 'brevo:fixture-delivered-1'),
        ('resend', 'delivered', 'fixture-resend-message-id', 'resend:fixture-delivered-1'),
    )
    charges = []
    for fournisseur, statut, message_id, event_id in callbacks:
        charge = json.dumps({
            'id': event_id, 'type': statut, 'message_id': message_id,
            'survenu_le': '2026-11-21T12:00:00Z'
        }, separators=(',', ':'))
        charges.append((fournisseur, charge))
        verifier('callback %s reçu durablement' % fournisseur,
                 recevoir(fournisseur, charge).get('enregistre'), True)
    for _ in callbacks:
        db.sql('select public.traiter_notifications(1);')
    statuts_livres = db.sql("select count(*) from public.notification_envois "
        "where message_id in ('fixture-meta-message-id','fixture-brevo-message-id',"
        "'fixture-resend-message-id') and statut='livre';").splitlines()[-1].strip()
    verifier('callbacks P-08 Meta, Brevo et Resend rapprochés du même historique',
             statuts_livres, '3')
    historique = rpc_json(db.comme(MANAGER,
        "select public.communication_c5_historique(null,null,'email','livre','shipment_shipped','',0,20);"))
    lignes_livrees = [ligne for ligne in historique.get('lignes', [])
                      if ligne.get('type') == 'shipment_shipped' and ligne.get('statut') == 'livre']
    verifier('événement GoShip, adaptateur, callback et historique Dashboard intégrés',
             (historique.get('total', 0) >= 1, len(lignes_livrees) >= 1,
              all('message_id' not in ligne and 'cible' not in ligne for ligne in lignes_livrees)),
             (True, True, True))

    meta_charge = json.dumps({
        'id': 'meta:fixture-sent-late', 'type': 'sent',
        'message_id': 'fixture-meta-message-id', 'survenu_le': '2026-11-21T12:01:00Z'
    }, separators=(',', ':'))
    verifier('callback désordonné reçu', recevoir('meta', meta_charge).get('enregistre'), True)
    db.sql('select public.traiter_notifications(1);')
    verifier('statut livré ne recule pas sur un callback sent tardif',
             db.sql("select statut from public.notification_envois "
                    "where message_id='fixture-meta-message-id';").splitlines()[-1].strip(), 'livre')
    event_count = db.sql("select count(*) from public.communication_evenements_fournisseur "
                         "where evenement_id like '%fixture-%';").splitlines()[-1].strip()
    replay = recevoir(callbacks[0][0], charges[0][1])
    verifier('callback répété dédupliqué sans nouvelle ligne',
             (replay.get('rejeu'), db.sql("select count(*) from public.communication_evenements_fournisseur "
                                           "where evenement_id like '%fixture-%';").splitlines()[-1].strip()),
             (True, event_count))
    refus = recevoir('meta', meta_charge, '0' * 64)
    verifier('signature interne invalide refusée sans stockage', refus.get('ok'), False)
    entree = json.dumps({'id': 'meta:inbound-fixture', 'type': 'inbound',
                         'message_id': 'fixture-inbound', 'survenu_le': '2026-11-21T12:02:00Z'},
                        separators=(',', ':'))
    verifier('les messages entrants STOP restent hors du pont transactionnel',
             recevoir('meta', entree).get('format'), True)


def recevoir_p08(db, identifiant, telephone, texte='STOP'):
    charge = json.dumps({
        'id': identifiant, 'type': 'inbound', 'telephone': telephone,
        'texte': texte, 'bouton': None, 'survenu_le': '2026-11-22T12:00:00Z'
    }, separators=(',', ':'))
    signature = db.sql(
        "select encode(extensions.hmac('meta:' || $c41$%s$c41$, "
        "'synthetic-webhook-secret','sha256'),'hex');" % charge
    ).splitlines()[-1].strip()
    resultat = communication_edge_role_sql(
        db, 'communication_webhook',
        "select communication_edge.communication_edge_webhook_recevoir_evenement("
        "'meta',$c41$%s$c41$,'%s');" % (charge, signature),
        'synthetic-webhook-jti-p08')
    return charge, rpc_json(resultat)


def identifiant_evenement_p08(db, identifiant):
    # Lit le résultat de la fonction digest réellement installée dans ce banc.
    # La doublure crypto de pgserver n'est pas une preuve cryptographique.
    valeur = identifiant.replace("'", "''")
    return (db.sql("select 'in:' || encode(extensions.digest('%s','sha256'),'hex');" % valeur)
            .splitlines()[-1].strip())


def appeler_worker_p08(db, sql_prefix=''):
    resultat = communication_edge_role_sql(
        db, 'communication_worker',
        "%s\nselect communication_edge.communication_edge_worker_traiter_evenements_prioritaires(50);"
        % sql_prefix,
        'synthetic-worker-jti-p08')
    return rpc_json(resultat)


def preparer_consentements_stop(db):
    empreinte = db.sql(
        "select public.communication_consentement_empreinte("
        "public.communication_consentement_cible('%s'::uuid));" % CLIENT5
    ).splitlines()[-1].strip()
    db.sql("""
      do $c41$
      declare
        v_client uuid;
        v_consentement bigint;
        v_secret uuid;
        v_demande bigint;
        v_empreinte text := public.communication_consentement_empreinte(
          public.communication_consentement_cible('%s'::uuid));
      begin
        foreach v_client in array array['%s'::uuid, '%s'::uuid] loop
          insert into public.communication_consentements_clients
            (client_id, canal, finalite, etat, cible_empreinte, texte_version, texte_empreinte,
             langue, source, demande_le, confirme_le)
          values (v_client, 'whatsapp', 'marketing', 'confirme', v_empreinte,
                  'fixture-synthetique-v1', repeat('a', 64), 'fr', 'compte_web', now(), now())
          on conflict (client_id, canal, finalite) do update
            set etat = 'confirme', cible_empreinte = excluded.cible_empreinte,
                texte_version = excluded.texte_version, texte_empreinte = excluded.texte_empreinte,
                langue = excluded.langue, demande_le = now(), confirme_le = now(), retire_le = null
          returning id into v_consentement;
          v_secret := vault.create_secret('synthetic-open-code', 'goship-c41-' || v_client::text);
          insert into public.communication_confirmations_whatsapp
            (consentement_id, client_id, cible_empreinte, code_empreinte, code_secret_id,
             etat, expire_le, maximum_tentatives, portee_tentatives, fenetre_tentatives_secondes)
          values (v_consentement, v_client, v_empreinte,
                  case when v_client = '%s'::uuid then repeat('b', 64) else repeat('c', 64) end,
                  v_secret, 'en_attente', now() + interval '1 hour', 5, 'contact', 3600)
          returning id into v_demande;
          update public.communication_consentements_clients
             set demande_id = v_demande where id = v_consentement;
        end loop;
      end
      $c41$;
    """ % (CLIENT5, CLIENT5, CLIENT6, CLIENT5))
    return empreinte


def tester_p09_classification(db, numero_base):
    print('\nP-09 — classification STOP des messages entrants — base neuve %d' % numero_base)
    # Cas fixés par la correction P-09 (revue finale RF-03) : les formulations courtes
    # de désinscription retirent ; une simple mention dans un message plus long, non.
    cas = [
        ('STOP', None, 'stop'), ('stop', None, 'stop'), ('  Stop!  ', None, 'stop'),
        ('Stop please', None, 'stop'), ('STOP STOP', None, 'stop'),
        ('Arrêter les promotions', None, 'stop'), ('arrêtez', None, 'stop'),
        ('Désabonner', None, 'stop'), ('Je veux me désabonner', None, 'ambigu'),
        ('UNSUBSCRIBE', None, 'stop'), ('Baja', None, 'stop'), ('No más', None, 'stop'),
        ('Kanpe', None, 'stop'), ('Sispann voye mesaj', None, 'stop'),
        ('Fin', None, 'stop'), ('Arrêt', None, 'stop'),
        ("mon colis s'est arrêté", None, 'autre'), ('Arrêt de bus', None, 'autre'),
        ('Cancel my order', None, 'autre'), ('Where is my package?', None, 'autre'),
        ('Merci, bien reçu', None, 'autre'), ('', None, 'autre'), (None, None, 'autre'),
        ('Pouvez-vous dire au livreur de ne pas stop chez le voisin ?', None, 'ambigu'),
        (None, 'STOP', 'stop'), ('Bonjour', 'unsubscribe', 'stop'), (None, 'OTHER', 'autre'),
    ]
    obtenus = []
    for texte, bouton, _ in cas:
        litteral_texte = 'null' if texte is None else '$p09$%s$p09$' % texte
        litteral_bouton = 'null' if bouton is None else "'%s'" % bouton
        obtenus.append(db.sql("select public.communication_classer_entrant(%s, %s);"
                              % (litteral_texte, litteral_bouton)).splitlines()[-1].strip())
    for (texte, bouton, attendu), obtenu in zip(cas, obtenus):
        verifier('P-09 classe %r / bouton %r' % (texte, bouton), obtenu, attendu)

    verifier('P-09 classification interne : aucun rôle d’API ne peut l’appeler',
             db.sql("select bool_or(has_function_privilege(r, "
                    "'public.communication_classer_entrant(text,text)', 'execute')) "
                    "from unnest(array['anon','authenticated','service_role']) r;")
             .splitlines()[-1].strip(), 'f')

    # Bout en bout : la classe est calculée à la réception, le texte n'est pas gardé.
    attendus = [('meta:p09-stop-please', 'Stop please', 'stop', '1'),
                ('meta:p09-arreter', 'Arrêter les promotions', 'stop', '1'),
                ('meta:p09-colis', "mon colis s'est arrêté", 'autre', '2'),
                ('meta:p09-mention', 'Le livreur a dit stop au portail hier soir', 'ambigu', '2')]
    for identifiant, texte, classe, priorite in attendus:
        _, reception = recevoir_p08(db, identifiant, '+17865550199', texte)
        ligne = db.sql("select q.classe || '|' || q.priorite from public.communication_evenements_traitement q "
                       "join public.communication_evenements_fournisseur e on e.id=q.evenement_id "
                       "where e.evenement_id='%s';" % identifiant_evenement_p08(db, identifiant)
                       ).splitlines()[-1].strip()
        verifier('P-09 réception %r : classe et priorité enregistrées' % texte,
                 (reception.get('ok'), ligne), (True, '%s|%s' % (classe, priorite)))
    verifier('P-09 aucun texte de message conservé en base',
             db.sql("select count(*) from public.communication_evenements_fournisseur "
                    "where evenement_id like 'in:%' and (coalesce(message_id,'') ilike '%stop%' "
                    "or coalesce(code,'') ilike '%arr%');").splitlines()[-1].strip(), '0')
    # Isole les scénarios suivants : ces événements de test sont marqués traités
    # (un événement traité ne garde ni empreinte ni code, contrainte de la table).
    db.sql("update public.communication_evenements_traitement q set etat='traite', traite_le=now(), "
           "cible_empreinte=null, code_confirmation=null "
           "from public.communication_evenements_fournisseur e where e.id=q.evenement_id "
           "and e.evenement_id in (%s);" % ','.join(
               "'%s'" % identifiant_evenement_p08(db, i) for i, _, _, _ in attendus))


def tester_p08_worker_et_recus(db, numero_base):
    print('\nP-08 atomique, STOP, reprise et reçus Expo — base neuve %d' % numero_base)
    db.sql('grant communication_worker to authenticator;')
    # La fixture de supervision contient un incident prioritaire sans rapport
    # avec ce scénario. Le marquer traité isole le test sans acquitter un incident réel.
    db.sql("update public.communication_evenements_traitement q set etat='traite', traite_le=now() "
           "from public.communication_evenements_fournisseur e "
           "where e.id=q.evenement_id and e.evenement_id='synthetic-event-2';")
    empreinte = preparer_consentements_stop(db)
    secret_ids = db.sql("select count(*) from vault.decrypted_secrets "
                        "where name like 'goship-c41-%';").splitlines()[-1].strip()
    verifier('fixtures synthétiques créées pour deux comptes partageant le contact',
             secret_ids, '2')

    charge, reception = recevoir_p08(db, 'meta:c41-stop-partage-1', '+17865550105')
    verifier('webhook P-08 accepté et file créée par la même RPC',
             (reception.get('ok'), reception.get('enregistre'),
              db.sql("select count(*) from public.communication_evenements_traitement q "
                     "join public.communication_evenements_fournisseur e on e.id=q.evenement_id "
                     "where e.evenement_id='in:' || encode(extensions.digest('meta:c41-stop-partage-1','sha256'),'hex');")
              .splitlines()[-1].strip()),
             (True, True, '1'))
    verifier('empreinte du webhook identique au contact des comptes concernés',
             db.sql("select q.cible_empreinte = c.cible_empreinte from "
                    "public.communication_evenements_traitement q "
                    "join public.communication_evenements_fournisseur e on e.id=q.evenement_id "
                    "join public.communication_consentements_clients c on c.client_id='%s' "
                    "where e.evenement_id='%s';" %
                    (CLIENT5, identifiant_evenement_p08(db, 'meta:c41-stop-partage-1')))
             .splitlines()[-1].strip(), 't')
    stop = appeler_worker_p08(db)
    verifier('STOP traité avant la file transactionnelle',
             (stop.get('ok'), stop.get('traites'), stop.get('prioritaire_en_attente')),
             (True, 1, 0))
    verifier('STOP retire les deux consentements du contact partagé',
             db.sql("select count(*) from public.communication_consentements_clients "
                    "where client_id in ('%s','%s') and etat='retire' and cible_empreinte='%s';"
                    % (CLIENT5, CLIENT6, empreinte)).splitlines()[-1].strip(), '2')
    verifier('STOP annule les confirmations ouvertes et supprime les secrets associés',
             db.sql("select count(*) from public.communication_confirmations_whatsapp d "
                    "join public.communication_consentements_clients c on c.id=d.consentement_id "
                    "where c.client_id in ('%s','%s') and d.etat='annule' and d.code_secret_id is null;"
                    % (CLIENT5, CLIENT6)).splitlines()[-1].strip(), '2')
    verifier('suppression par empreinte unique et historique de retrait append-only',
             (db.sql("select count(*) from public.communication_contact_suppressions "
                     "where canal='whatsapp' and cible_empreinte='%s' and leve_le is null;" % empreinte)
              .splitlines()[-1].strip(),
              db.sql("select count(*) from public.communication_consentement_historique "
                     "where source='whatsapp_stop' and action='retrait' and cible_empreinte='%s';" % empreinte)
              .splitlines()[-1].strip()), ('1', '2'))
    verifier('charge, téléphone et texte ne sont pas persistés en clair',
             (db.sql("select count(*) from public.communication_evenements_fournisseur "
                     "where message_id='+17865550105' or reference='STOP' or code='STOP';")
              .splitlines()[-1].strip(),
              db.sql("select count(*) from public.communication_evenements_fournisseur "
                     "where evenement_id='in:meta:c41-stop-partage-1';")
              .splitlines()[-1].strip()), ('0', '0'))
    evenement_hash = identifiant_evenement_p08(db, 'meta:c41-stop-partage-1')
    verifier('identifiant entrant remplacé en base et non conservé en clair',
             db.sql("select evenement_id from public.communication_evenements_fournisseur "
                    "where evenement_id='%s';" % evenement_hash).splitlines()[-1].strip(), evenement_hash)
    replay = recevoir_p08(db, 'meta:c41-stop-partage-1', '+17865550105')[1]
    verifier('rejeu P-08 idempotent sans nouveau travail',
             (replay.get('rejeu'), db.sql("select count(*) from public.communication_evenements_traitement_historique "
                    "where evenement_id=(select id from public.communication_evenements_fournisseur "
                    "where evenement_id='%s');" % evenement_hash).splitlines()[-1].strip()),
             (True, '2'))

    # Deux traitements lancés simultanément sur le même contact sont sérialisés
    # par N3/N3b puis SKIP LOCKED ; aucun effet de retrait n'est dupliqué.
    recevoir_p08(db, 'meta:c41-stop-partage-2', '+17865550105')
    barriere = threading.Barrier(2)
    resultats_concurrents = []
    erreurs_concurrentes = []

    def travailleur_concurrent():
        try:
            barriere.wait()
            resultats_concurrents.append(appeler_worker_p08(db))
        except Exception as erreur:
            erreurs_concurrentes.append(str(erreur))

    threads = [threading.Thread(target=travailleur_concurrent) for _ in range(2)]
    for thread in threads: thread.start()
    for thread in threads: thread.join(10)
    verifier('deux workers concurrents terminent sans double effet',
             (len(resultats_concurrents), erreurs_concurrentes,
              db.sql("select count(*) from public.communication_contact_suppressions "
                     "where cible_empreinte='%s' and leve_le is null;" % empreinte).splitlines()[-1].strip()),
             (2, [], '1'))

    # Simule une interruption après l'insertion de suppression et la purge du
    # secret, mais avant la mise à jour du consentement : le sous-bloc doit annuler
    # ces effets, conserver la file, puis permettre une reprise après retrait du défaut.
    db.sql("update public.communication_contact_suppressions set leve_le=now() "
           "where cible_empreinte='%s' and leve_le is null;" % empreinte)
    preparer_consentements_stop(db)
    id_secret_reprise = db.sql("select d.code_secret_id from public.communication_confirmations_whatsapp d "
                               "join public.communication_consentements_clients c on c.id=d.consentement_id "
                               "where c.client_id='%s' and d.etat='en_attente' limit 1;" % CLIENT5).splitlines()[-1].strip()
    db.sql("""
      create or replace function public.test_c41_interrompre_stop()
      returns trigger language plpgsql set search_path = '' as $test$
      begin
        if current_setting('goship.c41_fail_stop', true) = 'oui' then
          raise exception using errcode = '40001', message = 'synthetic-interruption';
        end if;
        return new;
      end
      $test$;
      create trigger test_c41_interrompre_stop before update of etat
        on public.communication_consentements_clients for each row
        execute function public.test_c41_interrompre_stop();
    """)
    _, interruption = recevoir_p08(db, 'meta:c41-stop-recovery', '+17865550105')
    reessai = appeler_worker_p08(db, "set local goship.c41_fail_stop = 'oui';")
    evenement_reprise = identifiant_evenement_p08(db, 'meta:c41-stop-recovery')
    etat_reprise = db.sql("select q.etat || '|' || q.tentatives::text || '|' || "
        "(q.prochain_essai_le > now())::text from public.communication_evenements_traitement q "
        "join public.communication_evenements_fournisseur e on e.id=q.evenement_id "
        "where e.evenement_id='%s';" % evenement_reprise).splitlines()[-1].strip()
    verifier('interruption annule les effets et planifie une reprise',
             (interruption.get('enregistre'), reessai.get('echecs'), etat_reprise,
              db.sql("select count(*) from vault.decrypted_secrets where id='%s';"
                     % id_secret_reprise).splitlines()[-1].strip(),
              db.sql("select count(*) from public.communication_consentements_clients "
                     "where client_id in ('%s','%s') and etat='confirme';" % (CLIENT5, CLIENT6))
              .splitlines()[-1].strip(),
              db.sql("select count(*) from public.communication_contact_suppressions "
                     "where cible_empreinte='%s' and leve_le is null;" % empreinte)
              .splitlines()[-1].strip()),
             (True, 1, 'a_traiter|1|true', '1', '2', '0'))
    db.sql("drop trigger test_c41_interrompre_stop on public.communication_consentements_clients; "
           "drop function public.test_c41_interrompre_stop(); update public.communication_evenements_traitement q "
           "set prochain_essai_le=now() from public.communication_evenements_fournisseur e "
           "where e.id=q.evenement_id and e.evenement_id='%s';" % evenement_reprise)
    reprise = appeler_worker_p08(db)
    verifier('événement interrompu repris une fois après correction',
             (reprise.get('prioritaire_en_attente'),
              db.sql("select etat || '|' || resultat from public.communication_evenements_traitement q "
                     "join public.communication_evenements_fournisseur e on e.id=q.evenement_id "
                     "where e.evenement_id='%s';" % evenement_reprise).splitlines()[-1].strip()),
             (0, 'traite|STOP_APPLIQUE'))

    # La réservation SQL ne traverse pas d'appel RPC : la transaction garde la
    # ligne ; un worker concurrent la saute, et l'annulation la rend immédiatement.
    recevoir_p08(db, 'meta:c41-stop-skip-locked', '+17865550105')
    id_verrouille = (db.sql("select id from public.communication_evenements_fournisseur "
        "where evenement_id='%s';" % identifiant_evenement_p08(db, 'meta:c41-stop-skip-locked'))
        .splitlines()[-1].strip())
    sql_verrou = ("set application_name='goship_c41_lock_holder'; begin; "
        "select 1 from public.communication_evenements_traitement where evenement_id=%s for update; "
        "select pg_sleep(2); commit;" % id_verrouille)
    verrou = subprocess.Popen([str(S.PSQL), '-U', db.su, '-h', db.socket, '-d', S.BASE,
        '-v', 'ON_ERROR_STOP=1', '-X', '-q', '-t', '-A', '-c', sql_verrou],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    attendu = False
    for _ in range(80):
        if (db.sql("select count(*) from pg_catalog.pg_stat_activity "
                   "where application_name='goship_c41_lock_holder' and wait_event='PgSleep';")
                .splitlines()[-1].strip() == '1'):
            attendu = True
            break
        time.sleep(0.025)
    pendant_verrou = appeler_worker_p08(db)
    verrou.communicate(timeout=5)
    verifier('SKIP LOCKED ne double-traite pas une ligne réservée par un autre worker',
             (attendu, pendant_verrou.get('prioritaire_en_attente'),
              db.sql("select etat from public.communication_evenements_traitement where evenement_id=%s;"
                     % id_verrouille).splitlines()[-1].strip()),
             (True, 1, 'a_traiter'))
    apres_verrou = appeler_worker_p08(db)
    verifier('la ligne redevient traitable après libération transactionnelle',
             (apres_verrou.get('prioritaire_en_attente'),
              db.sql("select etat from public.communication_evenements_traitement where evenement_id=%s;"
                     % id_verrouille).splitlines()[-1].strip()), (0, 'traite'))

    # Ticket synthétique dans notification_envois : l'outbox reste l'unique source.
    notification = db.sql("select e.notification_id from public.notification_envois e "
        "join public.notifications n on n.id=e.notification_id where n.type='shipment_shipped' limit 1;")
    notification = int(notification.splitlines()[-1].strip())
    ticket = '123e4567-e89b-42d3-a456-426614174099'
    envoi = int(db.sql("insert into public.notification_envois "
        "(notification_id, canal, cible, fournisseur, statut, priorite, message_id, envoye_le) "
        "values (%d,'push','synthetic-expo-c41','expo','envoye','normale','%s',now()-interval '20 minutes') "
        "returning id;" % (notification, ticket)).splitlines()[-1].strip())
    liste = rpc_json(communication_edge_role_sql(
        db, 'communication_worker',
        "select communication_edge.communication_edge_worker_expo_recus_a_reconcilier(10);",
        'synthetic-worker-jti-expo-list'))
    tickets = liste.get('tickets')
    verifier('RPC Expo ne renvoie que le ticket attendu sans destinataire',
             (len(tickets or []), (tickets or [{}])[0].get('id'),
              isinstance((tickets or [{}])[0].get('accepted_at'), str),
              set((tickets or [{}])[0])),
             (1, ticket, True, {'id', 'accepted_at'}))

    enregistrement = rpc_json(communication_edge_role_sql(
        db, 'communication_worker',
        "select communication_edge.communication_edge_worker_expo_enregistrer_recus("
        "'[{\"ticket_id\":\"%s\",\"state\":\"handoff_confirmed\"}]'::jsonb);" % ticket,
        'synthetic-worker-jti-expo-save'))
    verifier('reçu Expo enregistré dans la même ligne d’outbox',
             (enregistrement.get('ok'), enregistrement.get('mis_a_jour'),
              db.sql("select statut || '|' || expo_recu_etat from public.notification_envois "
                     "where id=%d;" % envoi).splitlines()[-1].strip(),
              db.sql("select count(*) from public.communication_expo_recus_historique "
                     "where notification_envoi_id=%d and etat='handoff_confirmed';" % envoi)
              .splitlines()[-1].strip()),
             (True, 1, 'envoye|handoff_confirmed', '1'))
    repetition = rpc_json(communication_edge_role_sql(
        db, 'communication_worker',
        "select communication_edge.communication_edge_worker_expo_enregistrer_recus("
        "'[{\"ticket_id\":\"%s\",\"state\":\"handoff_confirmed\"}]'::jsonb);" % ticket,
        'synthetic-worker-jti-expo-replay'))
    verifier('rejeu du même reçu Expo idempotent', repetition.get('mis_a_jour'), 0)
    transition = rpc_json(communication_edge_role_sql(
        db, 'communication_worker',
        "select communication_edge.communication_edge_worker_expo_enregistrer_recus("
        "'[{\"ticket_id\":\"%s\",\"state\":\"failed\","
        "\"code\":\"DEVICE_NOT_REGISTERED\"}]'::jsonb);" % ticket,
        'synthetic-worker-jti-expo-transition'))
    verifier('transition Expo contradictoire refusée sans modifier l’historique',
             (transition.get('ok'), transition.get('transition_invalide'),
              db.sql("select expo_recu_etat || '|' || coalesce(expo_recu_code, '') "
                     "from public.notification_envois "
                     "where id=%d;" % envoi).splitlines()[-1].strip(),
              db.sql("select count(*) from public.communication_expo_recus_historique "
                     "where notification_envoi_id=%d;" % envoi).splitlines()[-1].strip()),
             (False, True, 'handoff_confirmed|', '1'))

    worker_droits = db.sql("select "
        "has_function_privilege('communication_worker', "
        "'communication_edge.communication_edge_worker_traiter_evenements_prioritaires(integer)', 'execute') "
        "and not has_function_privilege('communication_worker', "
        "'public.communication_traiter_evenements_prioritaires(integer)', 'execute') "
        "and not has_function_privilege('authenticated', "
        "'public.communication_traiter_evenements_prioritaires(integer)', 'execute') "
        "and not has_function_privilege('service_role', "
        "'public.communication_traiter_evenements_prioritaires(integer)', 'execute');")
    verifier('RPC worker limitée au rôle technique dédié', worker_droits.splitlines()[-1].strip(), 't')
    verifier('rôle client ne lit pas les files P-08',
             db.erreur(CLIENT, 'select count(*) from public.communication_evenements_traitement;')
             .startswith('permission denied'), True)


def tester_c5_interface(db, numero_base, ids_transactionnels):
    print('\nInterface opérationnelle C5 et permissions — base neuve %d' % numero_base)

    sante = rpc_json(db.comme(ADMIN, 'select public.communication_c5_sante();'))
    verifier('santé C5 conserve les mesures réelles sans inventer de compteur',
             (isinstance(sante.get('evenements'), dict), isinstance(sante.get('envois'), dict),
              isinstance(sante.get('activite'), dict), isinstance(sante.get('alertes'), list)),
             (True, True, True, True))
    verifier('Manager autorisé à consulter la vue générale',
             isinstance(rpc_json(db.comme(MANAGER, 'select public.communication_c5_sante();')), dict), True)
    verifier('Employee et Client refusés par la vue générale',
             (db.erreur(EMPLOYEE, 'select public.communication_c5_sante();'),
              db.erreur(CLIENT, 'select public.communication_c5_sante();')),
             ('PERMISSION_DENIED', 'PERMISSION_DENIED'))

    historique = rpc_json(db.comme(ADMIN,
        "select public.communication_c5_historique(null,null,'email','annule','shipment_received','',0,20);"))
    verifier('historique filtré et paginé à partir de la file GoShip',
             (historique.get('total', 0) >= 1, historique.get('page'), historique.get('par_page'),
              isinstance(historique.get('lignes'), list),
              all(l.get('canal') == 'email' and l.get('statut') == 'annule'
                  and l.get('type') == 'shipment_received' for l in historique.get('lignes', []))),
             (True, 0, 20, True, True))
    texte_historique = json.dumps(historique, ensure_ascii=False)
    verifier('historique expurgé des cibles, erreurs libres et charges',
             any(sensible in texte_historique for sensible in
                 ('synthetic-resend', 'synthetic-whatsapp', 'no-reply@goship.test',
                  'cible', 'destinataire', 'client_id', 'colis_id', 'erreur')),
             False)
    verifier('Manager autorisé à lire l’historique filtré',
             isinstance(rpc_json(db.comme(MANAGER,
                 "select public.communication_c5_historique(null,null,'email',null,null,'',0,5);")), dict), True)
    verifier('Employee et Client ne lisent pas l’historique',
             (db.erreur(EMPLOYEE, "select public.communication_c5_historique(null,null,null,null,null,'',0,5);"),
              db.erreur(CLIENT, "select public.communication_c5_historique(null,null,null,null,null,'',0,5);")),
             ('PERMISSION_DENIED', 'PERMISSION_DENIED'))

    modeles = rpc_json(db.comme(ADMIN, 'select public.communication_c5_modeles_lister();'))
    verifier('catalogue de modèles et quatre langues réellement installés',
             ('shipment_received' in [x.get('type') for x in modeles.get('types', [])],
              len([x for x in modeles.get('modeles', [])
                   if x.get('type') == 'shipment_received' and x.get('version') == 1]),
              modeles.get('variables_autorisees')),
             (True, 4, ['numero', 'facture', 'montant']))

    notification_id = int(db.sql(
        "select notification_id from public.notification_envois where id=%d;" %
        ids_transactionnels['shipment_received']).splitlines()[-1].strip())
    apercu = rpc_json(db.comme(ADMIN,
        "select public.communication_c5_previsualiser_brouillon(%d,'shipment_received','fr',"
        "'Aperçu {{numero}}','Colis {{numero}}');"
        % notification_id))
    verifier('aperçu C5 rendu depuis une notification et un colis GoShip existants',
             (apercu.get('type'), apercu.get('langue'), '{{numero}}' not in apercu.get('message', ''),
              apercu.get('message', '').startswith('Colis ')),
             ('shipment_received', 'fr', True, True))
    verifier('prévisualisation refuse une variable absente des données réelles',
             db.erreur(ADMIN,
                 "select public.communication_c5_previsualiser_brouillon(%d,'shipment_received','fr',"
                 "'Aperçu','{{facture}}');"
                 % notification_id), 'COMMUNICATION_TEMPLATE_VARIABLE_MISSING')
    verifier('prévisualisation refuse un type de notification différent',
             db.erreur(ADMIN,
                 "select public.communication_c5_previsualiser_brouillon(%d,'invoice_paid','fr',"
                 "'Aperçu','Texte');" % notification_id),
             'COMMUNICATION_NOTIFICATION_TYPE_MISMATCH')

    traductions = [
        {'langue': 'fr', 'titre': 'Colis reçu', 'message': 'Votre colis est arrivé.'},
        {'langue': 'en', 'titre': 'Package received', 'message': 'Your package has arrived.'},
        {'langue': 'es', 'titre': 'Paquete recibido', 'message': 'Su paquete ha llegado.'},
        {'langue': 'ht', 'titre': 'Koli resevwa', 'message': 'Koli ou rive.'},
    ]
    traductions_sql = json.dumps(traductions, ensure_ascii=False).replace("'", "''")
    nouvelle = rpc_json(db.comme(ADMIN,
        "select public.communication_c5_modele_nouvelle_version('shipment_received',"
        "'%s'::jsonb,'{}'::text[],array['email']::text[],null);" % traductions_sql))
    verifier('création Admin d’une version complète et immuable en quatre langues',
             (nouvelle.get('version'), nouvelle.get('langues'),
              db.sql("select count(*) from public.communication_modeles_transactionnels "
                     "where type='shipment_received' and version=2;").splitlines()[-1].strip()),
             (2, ['en', 'es', 'fr', 'ht'], '4'))
    verifier('Manager ne peut pas créer ni versionner un modèle',
             db.erreur(MANAGER,
                 "select public.communication_c5_modele_nouvelle_version('shipment_received',"
                 "'%s'::jsonb,'{}'::text[],array['email']::text[],null);" % traductions_sql),
             'PERMISSION_DENIED')
    traductions_mismatch = [dict(ligne) for ligne in traductions]
    traductions_mismatch[0]['message'] = 'Votre colis {{numero}} est arrivé.'
    mismatch_sql = json.dumps(traductions_mismatch, ensure_ascii=False).replace("'", "''")
    verifier('variables incohérentes entre traductions refusées côté serveur',
             db.erreur(ADMIN,
                 "select public.communication_c5_modele_nouvelle_version('shipment_received',"
                 "'%s'::jsonb,array['numero']::text[],array['email']::text[],null);" % mismatch_sql),
             'COMMUNICATION_TEMPLATE_VARIABLES_MISMATCH')
    verifier('versions historiques protégées contre UPDATE et DELETE',
             (db.erreur('sql', "update public.communication_modeles_transactionnels set titre='modifié' "
                               "where type='shipment_received' and version=1 and langue='fr';"),
              db.erreur('sql', "delete from public.communication_modeles_transactionnels "
                               "where type='shipment_received' and version=1 and langue='fr';")),
             ('COMMUNICATION_TEMPLATE_IMMUTABLE', 'COMMUNICATION_TEMPLATE_IMMUTABLE'))

    consentements = rpc_json(db.comme(ADMIN, 'select public.communication_c5_consentements_lister(500);'))
    consentements_json = json.dumps(consentements, ensure_ascii=False)
    verifier('consentements Admin consultables avec états et historique',
             (len(consentements.get('lignes', [])) > 0,
              all(not any(k in ligne for k in ('telephone', 'cible_empreinte', 'code',
                                                'code_secret_id', 'texte_version'))
                  for ligne in consentements.get('lignes', []))),
             (True, True))
    verifier('coordonnées et codes de confirmation absents des résultats C5',
             any(sensible in consentements_json for sensible in
                 ('7865550105', 'synthetic-open-code', 'cible_empreinte', 'code_secret_id')),
             False)
    verifier('Manager, Employee et Client ne consultent pas les consentements marketing',
             tuple(db.erreur(role, 'select public.communication_c5_consentements_lister(10);')
                   for role in (MANAGER, EMPLOYEE, CLIENT)),
             ('PERMISSION_DENIED', 'PERMISSION_DENIED', 'PERMISSION_DENIED'))

    # L'événement est entièrement synthétique et créé dans la base jetable.
    event_id = int(db.sql(
        "insert into public.communication_evenements_fournisseur "
        "(fournisseur, evenement_id, type, code) values "
        "('meta','synthetic-c5-retry-%d','inbound','200') returning id;" % numero_base
    ).splitlines()[-1].strip())
    db.sql("insert into public.communication_evenements_traitement "
           "(evenement_id, etat, priorite, classe, tentatives, dernier_code, resultat) "
           "values (%d,'echec',1,'stop',3,'A_REVOIR','A_REVOIR');" % event_id)
    reprise = rpc_json(db.comme(ADMIN,
        'select public.communication_c5_evenement_reprendre(%d);' % event_id))
    verifier('reprise Admin limitée à un STOP entrant idempotent avec audit',
             (reprise.get('ok'), reprise.get('reprise_idempotente'),
              db.sql("select etat from public.communication_evenements_traitement where evenement_id=%d;"
                     % event_id).splitlines()[-1].strip(),
              db.sql("select count(*) from public.communication_interface_audit "
                     "where action='evenement_repris' and reference=%d;" % event_id)
              .splitlines()[-1].strip()),
             (True, True, 'a_traiter', '1'))
    verifier('Manager ne peut pas reprendre les événements',
             db.erreur(MANAGER,
                 'select public.communication_c5_evenement_reprendre(%d);' % event_id),
             'PERMISSION_DENIED')

    non_sur_id = int(db.sql(
        "insert into public.communication_evenements_fournisseur "
        "(fournisseur, evenement_id, type, code) values "
        "('meta','synthetic-c5-unsafe-%d','complaint','200') returning id;" % numero_base
    ).splitlines()[-1].strip())
    db.sql("insert into public.communication_evenements_traitement "
           "(evenement_id, etat, priorite, classe, tentatives, dernier_code, resultat) "
           "values (%d,'echec',1,'autre',2,'A_REVOIR','A_REVOIR');" % non_sur_id)
    verifier('plainte et événement non-STOP ne peuvent pas être repris',
             db.erreur(ADMIN,
                 'select public.communication_c5_evenement_reprendre(%d);' % non_sur_id),
             'COMMUNICATION_EVENT_RETRY_NOT_SAFE')
    db.sql("update public.notification_envois set statut='incertain', code_erreur='RESULTAT_INCERTAIN' "
           "where id=%d;" % ids_transactionnels['shipment_received'])
    file = rpc_json(db.comme(ADMIN, 'select public.communication_c5_file_lister(200);'))
    sortie_incertaine = next((x for x in file.get('envois', [])
                              if x.get('envoi_id') == ids_transactionnels['shipment_received']), {})
    verifier('transmission incertaine visible sans action de relance',
             (sortie_incertaine.get('statut'), 'reprise_possible' not in sortie_incertaine),
             ('incertain', True))
    verifier('Manager peut lire la file sans droit de reprise',
             (isinstance(rpc_json(db.comme(MANAGER,
                   'select public.communication_c5_file_lister(20);')), dict),
              db.erreur(MANAGER,
                   'select public.communication_c5_evenement_reprendre(%d);' % non_sur_id)),
             (True, 'PERMISSION_DENIED'))


def preparer_audience_c6(db):
    # Données synthétiques locales : sept comptes, dont deux partagent un contact.
    db.sql("""
      update public.clients set pays='DO', langue='es', ville='Santo Domingo', telephone='7865550701', cree_le=now()-interval '120 days' where id='%s';
      update public.clients set pays='DO', langue='es', ville='Santo Domingo', telephone='7865550702', cree_le=now()-interval '90 days' where id='%s';
      update public.clients set pays='DO', langue='es', ville='Santo Domingo', telephone='7865550703', cree_le=now()-interval '80 days' where id='%s';
      update public.clients set pays='DO', langue='es', ville='Santo Domingo', telephone='7865550704', cree_le=now()-interval '70 days' where id='%s';
      update public.clients set pays='US', langue='es', ville='Santo Domingo', telephone='7865550701', cree_le=now()-interval '60 days' where id='%s';
      update public.clients set pays='DO', langue='es', ville='Santo Domingo', telephone='7865550706', cree_le=now()-interval '50 days' where id='%s';
      update public.clients set pays='DO', langue='es', ville='Santo Domingo', telephone='7865550707', cree_le=now()-interval '40 days' where id='%s';
      insert into public.colis (numero,client_id,description,expediteur,poids_lb,destination,pays_destination,recu_le) values
        ('C6-SYNTHETIC-7','%s','Fixture colis marketing','Fixture local',1,'Santo Domingo','DO',now()-interval '5 days'),
        ('C6-SYNTHETIC-12','%s','Fixture colis marketing','Fixture local',1,'Santo Domingo','DO',now()-interval '2 days');
      insert into public.prealertes (client_id,suivi_transporteur,statut)
        values ('%s','C6-SYNTHETIC-TRACK','attente');
    """ % (CLIENT7, CLIENT8, CLIENT9, CLIENT10, CLIENT11, CLIENT12, CLIENT13,
           CLIENT7, CLIENT12, CLIENT7))

    for client, etat in ((CLIENT7, 'confirme'), (CLIENT9, 'retire'),
                         (CLIENT10, 'confirme'), (CLIENT12, 'confirme'),
                         (CLIENT13, 'confirme')):
        empreinte = db.sql(
            "select public.communication_consentement_empreinte("
            "public.communication_consentement_cible('%s'::uuid));" % client
        ).splitlines()[-1].strip()
        db.sql("""
          insert into public.communication_consentements_clients
            (client_id,canal,finalite,etat,cible_empreinte,texte_version,texte_empreinte,
             langue,source,demande_le,confirme_le,retire_le)
          values ('%s','whatsapp','marketing','%s','%s','c6-synthetic-v1',repeat('a',64),
                  'es','compte_web',now(),case when '%s'='confirme' then now() end,
                  case when '%s'='retire' then now() end);
        """ % (client, etat, empreinte, etat, etat))
    empreinte_stop = db.sql(
        "select public.communication_consentement_empreinte("
        "public.communication_consentement_cible('%s'::uuid));" % CLIENT10
    ).splitlines()[-1].strip()
    db.sql("insert into public.communication_contact_suppressions "
           "(canal,cible_empreinte,raison,evenement_id) "
           "values ('whatsapp','%s','stop',999999);" % empreinte_stop)


def tester_c6_campagnes(db, numero_base):
    print('\nCampagnes marketing C6 — base neuve %d' % numero_base)
    preparer_audience_c6(db)
    avant = tuple(db.sql(q).splitlines()[-1].strip() for q in (
        'select count(*) from public.notification_envois',
        'select count(*) from net.envois',
        'select count(*) from public.communication_transactionnelle_outbox'))

    criteres = {'mode': 'and', 'regles': [
        {'champ': 'pays', 'operateur': 'est', 'valeur': 'DO'},
        {'champ': 'langue', 'operateur': 'est', 'valeur': 'es'}]}
    jcriteres = json.dumps(criteres, ensure_ascii=False).replace("'", "''")
    segment = S.jsonq(db, MANAGER,
        "select public.communication_campagne_segment_enregistrer(null,'C6 DO Spanish','','%s'::jsonb);" % jcriteres)
    sid = segment.get('id')
    verifier('segment dynamique sauvegardé', isinstance(sid, int), True)
    verifier('SQL arbitraire dans les critères refusé',
        db.erreur(MANAGER, "select public.communication_campagne_segment_enregistrer(null,'x','',"
        "'{\"mode\":\"and\",\"regles\":[{\"champ\":\"sql\",\"operateur\":\"est\",\"valeur\":\"x\"}]}'::jsonb);"),
        'COMMUNICATION_SEGMENT_CRITERIA_INVALID')
    verifier('critères colis et pré-alertes reliés aux tables GoShip',
        (db.sql("select public.communication_campagne_critere_correspond('%s',"
                "'{\"mode\":\"and\",\"regles\":[{\"champ\":\"a_des_colis\",\"operateur\":\"est\",\"valeur\":true}]}'::jsonb);" % CLIENT12).splitlines()[-1].strip(),
         db.sql("select public.communication_campagne_critere_correspond('%s',"
                "'{\"mode\":\"and\",\"regles\":[{\"champ\":\"a_des_prealertes\",\"operateur\":\"est\",\"valeur\":true}]}'::jsonb);" % CLIENT7).splitlines()[-1].strip()),
        ('t','t'))

    traductions = {l: {'titre': 'GoShip offer', 'message': 'Discover our services.'}
                   for l in ('fr','en','es','ht')}
    jtraductions = json.dumps(traductions, ensure_ascii=False).replace("'", "''")
    traductions_v2 = {
        'fr': {'titre': 'Offre GoShip mise à jour', 'message': 'Découvrez nos services mis à jour.'},
        'en': {'titre': 'Updated GoShip offer', 'message': 'Discover our updated services.'},
        'es': {'titre': 'Oferta GoShip actualizada', 'message': 'Descubra nuestros servicios actualizados.'},
        'ht': {'titre': 'Òf GoShip ajou', 'message': 'Dekouvri sèvis nou yo ki ajou.'},
    }
    jtraductions_v2 = json.dumps(traductions_v2, ensure_ascii=False).replace("'", "''")
    modele_email = S.jsonq(db, MANAGER,
        "select public.communication_campagne_modele_version_creer('c6-offre','email','%s'::jsonb);" % jtraductions)
    modele_whatsapp = S.jsonq(db, MANAGER,
        "select public.communication_campagne_modele_version_creer('c6-offre','whatsapp','%s'::jsonb);" % jtraductions)
    email_v2 = S.jsonq(db, MANAGER,
        "select public.communication_campagne_modele_version_creer('c6-offre','email','%s'::jsonb);" % jtraductions_v2)
    verifier('modèles quatre langues versionnés et append-only',
        (modele_email.get('version'),modele_whatsapp.get('version'),email_v2.get('version'),
         db.erreur('sql', 'update public.communication_campagne_modeles_marketing set version=9 where id=%d;' % modele_email['id'])),
        (1,1,2,'COMMUNICATION_CAMPAIGN_HISTORY_IMMUTABLE'))
    verifier('tables marketing non lisibles directement et rôles limités',
        (db.erreur(MANAGER,'select count(*) from public.communication_campagnes_marketing;').startswith('permission denied'),
         db.erreur(EMPLOYEE,'select public.communication_campagnes_lister(10);'),
         db.erreur(CLIENT,'select public.communication_campagnes_lister(10);')),
        (True,'PERMISSION_DENIED','PERMISSION_DENIED'))

    modeles = json.dumps([
        {'canal':'email','id':modele_email['id'],'version':1},
        {'canal':'whatsapp','id':modele_whatsapp['id'],'version':1}]).replace("'", "''")
    modeles_v2 = json.dumps([
        {'canal':'email','id':email_v2['id'],'version':2},
        {'canal':'whatsapp','id':modele_whatsapp['id'],'version':1}]).replace("'", "''")
    modele_choisi = next(x for x in S.jsonq(db, MANAGER,
        "select public.communication_campagne_modeles_lister('email');")['modeles']
        if x.get('id') == email_v2['id'])
    verifier('catalogue retourne le contenu versionné exact pour l’aperçu de campagne',
        (modele_choisi.get('version'), modele_choisi.get('traductions', {}).get('es')),
        (2, traductions_v2['es']))
    campagne = S.jsonq(db, MANAGER,
        "select public.communication_campagne_enregistrer(null,'C6 synthétique','','Essai local',"
        "array['email','whatsapp']::text[],'es',%d,null,'%s'::jsonb,null,null,null,null,null,"
        "timestamp '2030-01-15 14:00:00','America/Santo_Domingo');" % (sid, modeles))
    cid = campagne.get('id')
    verifier('campagne créée comme brouillon', (campagne.get('revision'),campagne.get('etat')), (1,'draft'))
    apercu = S.jsonq(db, MANAGER, 'select public.communication_campagne_apercu(%d);' % cid)
    canal = {x['canal']:x for x in apercu.get('canaux',[])}
    motifs = canal['whatsapp']['motifs_exclusion']
    verifier('audience agrégée sans téléphone, identifiant client ou empreinte',
        (apercu.get('total_audience'), any(x in json.dumps(apercu) for x in
         (CLIENT7,CLIENT8,CLIENT9,CLIENT10,CLIENT12,CLIENT13,'7865550701','cible_empreinte','empreinte_interne'))),
        (6,False))
    verifier('consentement propre au canal, ambiguïté partagée et STOP exclus',
        (canal['email']['eligibles'],canal['email']['motifs_exclusion'].get('consentement_non_verifiable'),
         canal['whatsapp']['eligibles'],motifs.get('contact_partage_ambigu'),
         motifs.get('sans_consentement'),motifs.get('consentement_retire'),motifs.get('suppression_active')),
        (0,6,2,1,1,1,1))
    ligne = S.jsonq(db, MANAGER,'select public.communication_campagnes_lister(10);')['campagnes'][0]
    verifier('aucun budget, quota ou coût inventé',
        (ligne.get('limites_configurees'),ligne.get('cout_estime_usd'),ligne.get('cout_reel_usd')),
        (False,None,None))
    verifier('Manager soumet mais ne peut approuver',
        (S.jsonq(db,MANAGER,'select public.communication_campagne_soumettre(%d);'%cid).get('etat'),
         db.erreur(MANAGER,'select public.communication_campagne_approuver(%d);'%cid)),
        ('pending_approval','PERMISSION_DENIED'))

    db.sql("update public.communication_consentements_clients set etat='retire',retire_le=now() "
           "where client_id='%s' and canal='whatsapp' and finalite='marketing';" % CLIENT12)
    verifier('changement audience bloque l’approbation Admin',
        db.erreur(ADMIN,'select public.communication_campagne_approuver(%d);'%cid),
        'COMMUNICATION_CAMPAIGN_AUDIENCE_CHANGED')
    apercu2 = S.jsonq(db,MANAGER,'select public.communication_campagne_apercu(%d);'%cid)
    verifier('l’aperçu invalide la soumission et recalcule',
        (db.sql('select etat from public.communication_campagnes_marketing where id=%d;'%cid).splitlines()[-1].strip(),
         {x['canal']:x['eligibles'] for x in apercu2['canaux']}['whatsapp']),('draft',1))
    db.sql("update public.communication_consentements_clients set etat='confirme',confirme_le=now(),retire_le=null "
           "where client_id='%s' and canal='whatsapp' and finalite='marketing';" % CLIENT12)
    S.jsonq(db,MANAGER,'select public.communication_campagne_apercu(%d);'%cid)
    S.jsonq(db,MANAGER,'select public.communication_campagne_soumettre(%d);'%cid)
    S.jsonq(db,ADMIN,'select public.communication_campagne_approuver(%d);'%cid)
    verifier('planification bloquée tant que budget, plafond et quotas manquent',
        db.erreur(ADMIN,'select public.communication_campagne_planifier(%d);'%cid),
        'COMMUNICATION_CAMPAIGN_LIMITS_REQUIRED')

    revision_contenu = S.jsonq(db, MANAGER,
        "select public.communication_campagne_enregistrer(%d,'C6 synthétique','','Essai local',"
        "array['email','whatsapp']::text[],'es',%d,null,'%s'::jsonb,null,null,null,null,null,"
        "timestamp '2030-01-15 14:00:00','America/Santo_Domingo');" % (cid,sid,modeles_v2))
    verifier('changement de modèle après approbation crée une révision sans approbation héritée',
        (revision_contenu.get('revision'), revision_contenu.get('etat'),
         db.sql('select revision_approuvee_id is null from public.communication_campagnes_marketing where id=%d;'%cid).splitlines()[-1].strip()),
        (2,'draft','t'))
    S.jsonq(db,MANAGER,'select public.communication_campagne_apercu(%d);'%cid)
    S.jsonq(db,MANAGER,'select public.communication_campagne_soumettre(%d);'%cid)
    S.jsonq(db,ADMIN,'select public.communication_campagne_approuver(%d);'%cid)
    verifier('révision de contenu sans budget reste non planifiable',
        db.erreur(ADMIN,'select public.communication_campagne_planifier(%d);'%cid),
        'COMMUNICATION_CAMPAIGN_LIMITS_REQUIRED')

    revisee = S.jsonq(db,MANAGER,
        "select public.communication_campagne_enregistrer(%d,'C6 synthétique','','Essai local',"
        "array['email','whatsapp']::text[],'es',%d,null,'%s'::jsonb,100,100,"
        "'{\"email\":100,\"whatsapp\":1}'::jsonb,100,120,"
        "timestamp '2030-01-15 14:00:00','America/Santo_Domingo');" % (cid,sid,modeles_v2))
    verifier('édition après approbation crée une nouvelle révision draft',
        (revisee.get('revision'),revisee.get('etat'),
         db.sql('select revision_approuvee_id is null from public.communication_campagnes_marketing where id=%d;'%cid).splitlines()[-1].strip()),
        (3,'draft','t'))
    apercu_limites = S.jsonq(db,MANAGER,'select public.communication_campagne_apercu(%d);'%cid)
    verifier('aperçu signale les quotas et estimations au-dessus des limites',
        set(x.get('type') for x in apercu_limites.get('alertes_limites',[])),
        {'quota_depasse','budget_prevu_depasse','plafond_depasse'})
    S.jsonq(db,MANAGER,'select public.communication_campagne_soumettre(%d);'%cid)
    S.jsonq(db,ADMIN,'select public.communication_campagne_approuver(%d);'%cid)
    verifier('planification bloquée quand un quota ou le plafond est dépassé',
        db.erreur(ADMIN,'select public.communication_campagne_planifier(%d);'%cid),
        'COMMUNICATION_CAMPAIGN_LIMIT_EXCEEDED')

    revisee3 = S.jsonq(db,MANAGER,
        "select public.communication_campagne_enregistrer(%d,'C6 synthétique','','Essai local',"
        "array['email','whatsapp']::text[],'es',%d,null,'%s'::jsonb,100,100,"
        "'{\"email\":100,\"whatsapp\":2}'::jsonb,100,120,"
        "timestamp '2030-01-15 14:00:00','America/Santo_Domingo');" % (cid,sid,modeles))
    verifier('augmentation de quota crée une nouvelle révision',
        (revisee3.get('revision'),revisee3.get('etat')),(4,'draft'))
    apercu_plafond = S.jsonq(db,MANAGER,'select public.communication_campagne_apercu(%d);'%cid)
    verifier('l’alerte de plafond persiste après correction du quota',
        set(x.get('type') for x in apercu_plafond.get('alertes_limites',[])),
        {'budget_prevu_depasse','plafond_depasse'})
    S.jsonq(db,MANAGER,'select public.communication_campagne_soumettre(%d);'%cid)
    S.jsonq(db,ADMIN,'select public.communication_campagne_approuver(%d);'%cid)
    verifier('coût estimé supérieur au plafond bloque encore la planification',
        db.erreur(ADMIN,'select public.communication_campagne_planifier(%d);'%cid),
        'COMMUNICATION_CAMPAIGN_LIMIT_EXCEEDED')

    revisee4 = S.jsonq(db,MANAGER,
        "select public.communication_campagne_enregistrer(%d,'C6 synthétique','','Essai local',"
        "array['email','whatsapp']::text[],'es',%d,null,'%s'::jsonb,100,100,"
        "'{\"email\":100,\"whatsapp\":2}'::jsonb,100,50,"
        "timestamp '2030-01-15 14:00:00','America/Santo_Domingo');" % (cid,sid,modeles))
    verifier('révision au-dessous des limites enregistrée',
        (revisee4.get('revision'),revisee4.get('etat')),(5,'draft'))
    apercu_ok = S.jsonq(db,MANAGER,'select public.communication_campagne_apercu(%d);'%cid)
    verifier('aucune alerte lorsque quotas et estimation respectent les limites',
        apercu_ok.get('alertes_limites'),[])
    S.jsonq(db,MANAGER,'select public.communication_campagne_soumettre(%d);'%cid)
    S.jsonq(db,ADMIN,'select public.communication_campagne_approuver(%d);'%cid)
    plan = S.jsonq(db,ADMIN,'select public.communication_campagne_planifier(%d);'%cid)
    verifier('planification enregistrée par Admin sans transmission',
        (plan.get('etat'),plan.get('fuseau_horaire'),plan.get('transmission_active')),
        ('scheduled','America/Santo_Domingo',False))
    verifier('planification répétée refusée',
        db.erreur(ADMIN,'select public.communication_campagne_planifier(%d);'%cid),
        'COMMUNICATION_CAMPAIGN_ALREADY_SCHEDULED')

    copie = S.jsonq(db,MANAGER,'select public.communication_campagne_dupliquer(%d);'%cid)
    copie_id = copie.get('id')
    verifier('duplication sans évaluations ni approbations héritées',
        (copie.get('etat'),copie.get('historique_copie'),copie.get('transmissions_copiees'),
         db.sql('select count(*) from public.communication_campagne_evaluations_marketing where campagne_id=%d;'%copie_id).splitlines()[-1].strip(),
         db.sql('select count(*) from public.communication_campagne_approbations_marketing where campagne_id=%d;'%copie_id).splitlines()[-1].strip()),
        ('draft',False,False,'0','0'))
    journal = S.jsonq(db,MANAGER,'select public.communication_campagne_journal(%d,100);'%cid)
    verifier('journal contient la planification',
        any(x.get('action')=='scheduled' for x in journal.get('lignes',[])),True)
    copie_apercu = S.jsonq(db,MANAGER,'select public.communication_campagne_apercu(%d);'%copie_id)
    verifier('copie préparée à partir de l’audience synthétique',
        copie_apercu.get('total_audience'),6)
    S.jsonq(db,MANAGER,'select public.communication_campagne_soumettre(%d);'%copie_id)
    verifier('Manager ne peut ni refuser ni approuver une campagne',
        (db.erreur(MANAGER,"select public.communication_campagne_refuser(%d,'motif de test');"%copie_id),
         db.erreur(MANAGER,'select public.communication_campagne_approuver(%d);'%copie_id)),
        ('PERMISSION_DENIED','PERMISSION_DENIED'))
    verifier('Admin doit fournir un motif de refus',
        db.erreur(ADMIN,"select public.communication_campagne_refuser(%d,'   ');"%copie_id),
        'COMMUNICATION_CAMPAIGN_REJECTION_REASON_REQUIRED')
    refus = S.jsonq(db,ADMIN,
        "select public.communication_campagne_refuser(%d,'Refus de test local');"%copie_id)
    etat_refus = db.sql('select etat || \'|\' || motif_refus from public.communication_campagnes_marketing where id=%d;'%copie_id).splitlines()[-1].strip()
    journal_refus = S.jsonq(db,MANAGER,
        'select public.communication_campagne_journal(%d,100);'%copie_id)
    verifier('refus Admin consigné, révisable et visible dans le journal',
        (refus.get('etat'), etat_refus,
         any(x.get('action')=='rejected' for x in journal_refus.get('lignes',[]))),
        ('draft','draft|Refus de test local',True))
    S.jsonq(db,ADMIN,'select public.communication_campagne_annuler(%d);'%copie_id)
    verifier('annulation Admin persistée',
        db.sql('select etat from public.communication_campagnes_marketing where id=%d;'%copie_id).splitlines()[-1].strip(),
        'cancelled')
    verifier('aucun RPC worker ou expéditeur C6',
        db.sql("select count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace "
               "where n.nspname='public' and p.proname ~ 'campagne.*(envoyer|expedier|worker)';").splitlines()[-1].strip(),
        '0')
    apres = tuple(db.sql(q).splitlines()[-1].strip() for q in (
        'select count(*) from public.notification_envois',
        'select count(*) from net.envois',
        'select count(*) from public.communication_transactionnelle_outbox'))
    verifier('aucun nouvel envoi, appel réseau ou ajout à l’outbox transactionnelle', apres, avant)


def tester_c10_arret_admin(db, numero_base):
    # Lancé en dernier : P-07 a laissé l'arrêt confirmé, ce qui permet d'éprouver la
    # levée, puis un nouveau cycle demande → confirmation par les RPC de l'Admin.
    print('\nC10 — arrêt d’urgence côté Admin — base neuve %d' % numero_base)
    fonctions = ('public.communication_c10_arret_etat()',
                 'public.communication_c10_arret_demander(text)',
                 'public.communication_c10_arret_confirmer()',
                 'public.communication_c10_arret_lever(text,bigint)')
    droits = db.sql("select bool_and(not has_function_privilege('anon', f, 'execute') "
                    "and has_function_privilege('authenticated', f, 'execute') "
                    "and not has_function_privilege('service_role', f, 'execute')) "
                    "from unnest(array['%s']::text[]) f;" % "','".join(fonctions))
    verifier('RPC C10 appelables par authenticated seulement', droits.splitlines()[-1].strip(), 't')
    verifier('table d’arrêt toujours fermée en écriture directe',
             db.erreur(ADMIN, "update public.communication_arret set etat = 'actif' "
                              "where id is true;").startswith('permission denied'), True)

    etat_manager = rpc_json(db.comme(MANAGER, 'select public.communication_c10_arret_etat();'))
    verifier('Gérant voit l’état sans pouvoir gérer',
             (etat_manager.get('etat'), etat_manager.get('peut_gerer')), ('arret_confirme', False))
    verifier('Gérant ne peut pas lever l’arrêt',
             db.erreur(MANAGER, "select public.communication_c10_arret_lever("
                                "'reprise demandée par le gérant', %d);" % etat_manager['version']),
             'PERMISSION_DENIED')
    verifier('Employé ne peut pas demander l’arrêt',
             db.erreur(EMPLOYEE, "select public.communication_c10_arret_demander('motif valide');"),
             'PERMISSION_DENIED')
    verifier('Employé ne voit pas l’état de supervision',
             db.erreur(EMPLOYEE, 'select public.communication_c10_arret_etat();'), 'PERMISSION_DENIED')

    etat = rpc_json(db.comme(ADMIN, 'select public.communication_c10_arret_etat();'))
    version = etat['version']
    verifier('Admin voit l’arrêt confirmé et peut le gérer',
             (etat.get('etat'), etat.get('peut_gerer')), ('arret_confirme', True))
    verifier('levée refusée sans motif suffisant',
             db.erreur(ADMIN, "select public.communication_c10_arret_lever('court', %d);" % version),
             'REASON_REQUIRED')
    verifier('levée refusée si l’état a changé depuis l’affichage',
             db.erreur(ADMIN, "select public.communication_c10_arret_lever("
                              "'reprise après vérification locale', %d);" % (version - 1)),
             'STOP_STATE_CHANGED')
    verifier('levée refusée laisse l’arrêt confirmé',
             db.sql("select etat from public.communication_arret where id is true;")
             .splitlines()[-1].strip(), 'arret_confirme')

    levee = rpc_json(db.comme(ADMIN, "select public.communication_c10_arret_lever("
                                     "'reprise après vérification locale', %d);" % version))
    verifier('levée par l’Admin rétablit les sorties', (levee.get('etat'), levee.get('version')),
             ('actif', version + 1))
    trace = db.sql("select (leve_par = '%s')::text || '|' || (motif_levee is not null)::text "
                   "|| '|' || (autorisations_closes_le is null and confirme_le is null)::text "
                   "from public.communication_arret where id is true;" % ADMIN)
    verifier('levée tracée sur la ligne d’arrêt', trace.splitlines()[-1].strip(), 'true|true|true')
    audit = db.sql("select count(*) from public.journal_audit where action = 'communication.arret_leve' "
                   "and auteur_id = '%s' and motif <> '';" % ADMIN)
    verifier('levée inscrite au journal d’audit avec son motif', audit.splitlines()[-1].strip(), '1')
    verifier('seconde levée refusée : aucun arrêt en cours',
             db.erreur(ADMIN, "select public.communication_c10_arret_lever("
                              "'reprise après vérification locale', %d);" % (version + 1)),
             'INVALID_TRANSITION')
    porte = db.sql("with a as materialized (select public.communication_autoriser_sortie('envoi','email') r) "
                   "select coalesce(r, 'AUTORISEE') from a;")
    verifier('porte des sorties de nouveau ouverte après la levée',
             porte.splitlines()[-1].strip(), 'AUTORISEE')

    verifier('demande refusée sans motif',
             db.erreur(ADMIN, "select public.communication_c10_arret_demander('ok');"),
             'REASON_REQUIRED')
    version_avant_demande = rpc_json(db.comme(ADMIN, 'select public.communication_c10_arret_etat();'))['version']
    demande = rpc_json(db.comme(ADMIN, "select public.communication_c10_arret_demander("
                                       "'arrêt local par l’Admin');"))
    verifier('demande de l’Admin acceptée', demande.get('etat'), 'STOP_REQUESTED')
    demandeur = db.sql("select (demande_par = '%s')::text || '|' || etat from public.communication_arret "
                       "where id is true;" % ADMIN)
    verifier('demande attribuée à l’Admin et durable', demandeur.splitlines()[-1].strip(), 'true|arret_demande')
    verifier('demande inscrite au journal d’audit',
             db.sql("select count(*) from public.journal_audit where action = 'communication.arret_demande' "
                    "and auteur_id = '%s';" % ADMIN).splitlines()[-1].strip(), '1')
    porte = db.sql("with a as materialized (select public.communication_autoriser_sortie('envoi','email') r) "
                   "select coalesce(r, 'AUTORISEE') from a;")
    verifier('porte fermée dès la demande validée', porte.splitlines()[-1].strip(), 'ARRET_URGENCE')
    verifier('levée avec la version d’avant la demande refusée',
             db.erreur(ADMIN, "select public.communication_c10_arret_lever("
                              "'reprise sur un écran périmé', %d);" % version_avant_demande),
             'STOP_STATE_CHANGED')

    en_cours = int(db.sql("select count(*) from public.notification_envois "
                          "where statut in ('envoi', 'incertain');").splitlines()[-1].strip())
    confirmation = rpc_json(db.comme(ADMIN, 'select public.communication_c10_arret_confirmer();'))
    attendu = ('STOP_CONFIRMED', None) if en_cours == 0 else ('STOP_PENDING', 'TRANSMISSIONS_EN_COURS')
    verifier('confirmation de l’Admin suit les transmissions en cours (%d)' % en_cours,
             (confirmation.get('etat'), confirmation.get('raison')), attendu)
    verifier('Gérant ne peut pas confirmer l’arrêt',
             db.erreur(MANAGER, 'select public.communication_c10_arret_confirmer();'), 'PERMISSION_DENIED')

    # Résolution synthétique des transmissions restantes (comme en P-07), puis la
    # relance de l'écran doit aboutir à l'arrêt confirmé.
    db.sql("update public.notification_envois set statut = 'echec', "
           "code_erreur = 'ESSAI_RECONCILIE_LOCALEMENT', maj_le = now() "
           "where statut in ('envoi', 'incertain');")
    relance = rpc_json(db.comme(ADMIN, 'select public.communication_c10_arret_confirmer();'))
    verifier('relance de la confirmation par l’Admin aboutit à l’arrêt confirmé',
             (relance.get('etat'), db.sql("select etat from public.communication_arret where id is true;")
              .splitlines()[-1].strip()), ('STOP_CONFIRMED', 'arret_confirme'))
    porte = db.sql("with a as materialized (select public.communication_autoriser_sortie('envoi','email') r) "
                   "select coalesce(r, 'AUTORISEE') from a;")
    verifier('porte toujours fermée après la confirmation', porte.splitlines()[-1].strip(), 'ARRET_URGENCE')


def tester_c9_reglages_et_alertes(db, numero_base):
    # Lancé après C10 : l'arrêt est alors confirmé, ce qui permet de construire
    # l'alerte « arrêt demandé mais non confirmé ».
    print('\nC9 — réglages décidés, supervision et alertes — base neuve %d' % numero_base)
    colonnes = ('expiration_secondes', 'maximum_tentatives', 'portee_tentatives',
                'fenetre_tentatives_secondes', 'fenetre_demandes_secondes',
                'maximum_demandes_compte', 'maximum_demandes_contact', 'politique_contact_partage')
    lire = ("select concat_ws('|', %s) from public.communication_consentement_reglages "
            "where id is true;" % ', '.join(colonnes))
    decides = '3600|5|contact|3600|86400|3|3|bloquer'

    db.sql("update public.communication_consentement_reglages set %s where id is true;"
           % ', '.join('%s = null' % c for c in colonnes))
    verifier('réglages remis à blanc : demande refusée fermée',
             db.erreur(CLIENT7, "select public.communication_consentement_demander_whatsapp("
                                "'fixture-synthetique-v1', 'fr');"), 'POLICY_UNCONFIGURED')
    appliquer_candidate(db, FICHIER_CANDIDATE_REGLAGES)
    verifier('réglages décidés installés (H2, H3)', db.sql(lire).splitlines()[-1].strip(), decides)
    appliquer_candidate(db, FICHIER_CANDIDATE_REGLAGES)
    verifier('réglages décidés rejouables sans changement', db.sql(lire).splitlines()[-1].strip(), decides)
    db.sql("update public.communication_consentement_reglages set maximum_demandes_compte = 7, "
           "expiration_secondes = null where id is true;")
    appliquer_candidate(db, FICHIER_CANDIDATE_REGLAGES)
    verifier('un réglage déjà fixé par l’Admin est conservé',
             db.sql(lire).splitlines()[-1].strip(), '3600|5|contact|3600|86400|7|3|bloquer')
    verifier('la politique n’est plus refusée faute de réglage',
             db.erreur(CLIENT7, "select public.communication_consentement_demander_whatsapp("
                                "'fixture-synthetique-v1', 'fr');") != 'POLICY_UNCONFIGURED', True)

    sante = rpc_json(db.comme(ADMIN, 'select public.communication_c5_sante();'))
    attendus = json.loads(db.sql("""
      select json_build_object(
        'en_cours', count(*) filter (where statut = 'envoi'),
        'incertains', count(*) filter (where statut = 'incertain'),
        'en_attente', count(*) filter (where statut in ('attente', 'confirmation')))
      from public.notification_envois;
    """).splitlines()[-1].strip())
    envois = sante.get('envois', {})
    verifier('supervision : transmissions en cours, incertaines et en attente exactes',
             {k: envois.get(k) for k in attendus}, attendus)

    # Alerte de retard : un retour non traité depuis plus de 10 min.
    retards_avant = int(db.sql("select count(*) from public.communication_evenements_traitement "
                               "where etat = 'a_traiter';").splitlines()[-1].strip())
    if retards_avant == 0:
        evenement = db.sql("""
          insert into public.communication_evenements_fournisseur (fournisseur, evenement_id, type)
          values ('meta', 'c9-retard-synthetique', 'delivered') returning id;
        """).splitlines()[0].strip()
        db.sql("insert into public.communication_evenements_traitement (evenement_id) values (%s);" % evenement)
    db.sql("update public.communication_evenements_traitement set cree_le = clock_timestamp() - "
           "interval '11 minutes' where etat = 'a_traiter';")
    retards = int(db.sql("select count(*) from public.communication_evenements_traitement "
                         "where etat = 'a_traiter';").splitlines()[-1].strip())

    # Alerte d'arrêt non confirmé : levée, nouvelle demande, puis demande vieillie de 3 min.
    etat = rpc_json(db.comme(ADMIN, 'select public.communication_c10_arret_etat();'))
    if etat.get('etat') != 'actif':
        rpc_json(db.comme(ADMIN, "select public.communication_c10_arret_lever("
                                 "'reprise pour l’essai des alertes', %d);" % etat['version']))
    rpc_json(db.comme(ADMIN, "select public.communication_c10_arret_demander('arrêt pour l’essai des alertes');"))
    db.sql("update public.communication_arret set demande_le = clock_timestamp() - interval '3 minutes', "
           "derniere_demande_le = clock_timestamp() - interval '3 minutes' where id is true;")

    alertes = rpc_json(db.comme(ADMIN, 'select public.communication_c5_sante();')).get('alertes', [])
    par_code = dict((a.get('code'), a) for a in alertes)
    verifier('alerte de retour en attente depuis plus de 10 min',
             par_code.get('EVENEMENTS_EN_RETARD', {}).get('compte'), retards)
    verifier('alerte d’arrêt demandé mais non confirmé depuis plus de 2 min',
             (par_code.get('ARRET_NON_CONFIRME', {}).get('compte'),
              par_code.get('ARRET_NON_CONFIRME', {}).get('depuis') is not None), (1, True))
    db.sql("update public.communication_arret set demande_le = clock_timestamp(), "
           "derniere_demande_le = clock_timestamp() where id is true;")
    alertes = rpc_json(db.comme(ADMIN, 'select public.communication_c5_sante();')).get('alertes', [])
    verifier('pas d’alerte d’arrêt dans les 2 premières minutes',
             'ARRET_NON_CONFIRME' in [a.get('code') for a in alertes], False)
    verifier('alertes visibles au Gérant, refusées à l’Employé',
             (isinstance(rpc_json(db.comme(MANAGER, 'select public.communication_c5_sante();'))
                         .get('alertes'), list),
              db.erreur(EMPLOYEE, 'select public.communication_c5_sante();')),
             (True, 'PERMISSION_DENIED'))

    # Une ligne d'un canal qu'aucun adaptateur ne sert (« sms ») ne peut pas entrer
    # dans l'outbox pour une notification à modèle : le déclencheur de 004 la refuse.
    # Le travailleur annule en plus une telle ligne au lieu de bloquer le lot
    # (garde-fou pour les notifications sans modèle).
    refus_sms = db.erreur('sql', """
      insert into public.notification_envois (notification_id, canal, cible, statut, priorite)
      select n.id, 'sms', 'c9-sms', 'attente', 'haute'
        from public.notifications n where n.categorie = 'colis' order by n.id limit 1;
    """)
    verifier('outbox : canal sans adaptateur refusé pour une notification à modèle',
             refus_sms, 'COMMUNICATION_TEMPLATE_CHANNEL_UNSUPPORTED')

    # Correction du 23/11/2026 : texte_notification (004) lit de nouveau les modèles
    # modifiables de l'équipe (notification_modeles), dont les anniversaires.
    anniversaire = rpc_json(db.sql(
        "select public.texte_notification('birthday', 'fr', '{\"prenom\":\"Fixture\"}'::jsonb);"))
    attendu_titre = db.sql("select public.rendre_notification(titre, '{\"prenom\":\"Fixture\"}'::jsonb) "
                           "from public.notification_modeles "
                           "where type = 'birthday' and langue = 'fr';").splitlines()[-1].strip()
    verifier('modèle d’anniversaire de l’équipe rendu, jamais un message vide',
             (anniversaire.get('titre') == attendu_titre, bool(anniversaire.get('message'))), (True, True))


def tester_c11_rejeu_chaine(db, numero_base):
    """C11 : la chaîne rejouée sur une base existante enveloppe les versions les plus récentes.

    004 et 005 renomment l'adaptateur officiel (expedier_envoi) et le travailleur de 004
    (traiter_notifications) en fonctions intérieures, puis les enveloppent. Au rejeu, les
    fichiers officiels réécrivent ces fonctions : ce sont ces versions-là, et non celles du
    premier passage, qui doivent devenir les fonctions intérieures.
    """
    print('\nC11 — rejeu de la chaîne sur une base existante (base %d)' % numero_base)
    interieures = (
        ('communication_expedier_envoi_sans_porte', 'public.notification_envois', 'p_envoi', 'bigint',
         "select -1::bigint /* PERIME */"),
        ('communication_traiter_notifications_sans_callbacks', 'integer default null', 'p_lot', 'jsonb',
         "select '{\"perime\": true}'::jsonb /* PERIME */"),
    )
    empreinte = lambda nom: db.sql(
        "select md5(prosrc) from pg_proc where proname = '%s';" % nom).splitlines()[-1].strip()

    def corps_source(chemins, signature):
        # Le corps de la dernière définition de la fonction dans ces fichiers, tel que
        # PostgreSQL le range dans prosrc (entre les délimiteurs, sans eux).
        for chemin in reversed(chemins):
            texte = open(chemin, encoding='utf-8').read()
            debut = texte.rfind('create or replace function ' + signature)
            if debut < 0:
                continue
            ouverture = re.search(r'\bas (\$[a-z_]*\$)', texte[debut:])
            delimiteur = ouverture.group(1)
            corps_debut = debut + ouverture.end()
            return texte[corps_debut:texte.index(delimiteur, corps_debut)]
        raise SystemExit('définition introuvable : ' + signature)

    officiels = [os.path.join(OUTILS, f) for f in CHAINE]
    attendu = {
        # L'adaptateur officiel le plus récent de la chaîne
        'communication_expedier_envoi_sans_porte': hashlib.md5(corps_source(
            officiels, 'public.expedier_envoi(').encode('utf-8')).hexdigest(),
        # Le travailleur verrouillé de 004
        'communication_traiter_notifications_sans_callbacks': hashlib.md5(corps_source(
            [os.path.join(CANDIDATES, '004-communication-transactionnelle.sql')],
            'public.traiter_notifications(').encode('utf-8')).hexdigest(),
    }
    avant = {nom: empreinte(nom) for nom, *_ in interieures}
    for nom, type_arg, arg, retour, corps in interieures:
        db.sql("create or replace function public.%s(%s %s) returns %s language sql "
               "security definer set search_path = '' as $$ %s $$;" % (nom, arg, type_arg, retour, corps))
    verifier('fonctions intérieures marquées périmées avant le rejeu',
             [empreinte(nom) != avant[nom] for nom, *_ in interieures], [True, True])

    depart = CHAINE.index('supabase-notifications.sql')
    for nom in CHAINE[depart:]:
        db.fichier(os.path.join(OUTILS, nom))
    for chemin in FICHIERS_CANDIDATS:
        appliquer_candidate(db, chemin)
    appliquer_candidate(db, FICHIER_CANDIDATE_S1)
    appliquer_candidate(db, FICHIER_CANDIDATE_REGLAGES)

    verifier('rejeu : les fonctions intérieures sont exactement les versions les plus récentes '
             '(adaptateur de supabase-lieu-reception.sql, travailleur de 004)',
             [empreinte(nom) == attendu[nom] for nom, *_ in interieures], [True, True])
    corps = lambda nom: db.sql("select prosrc from pg_proc where proname = '%s';" % nom)
    verifier('rejeu : expedier_envoi reste l\'enveloppe soumise à la porte P-07',
             ('communication_expedier_envoi_sans_porte' in corps('expedier_envoi'),
              'communication_sortie_autorisee' in corps('expedier_envoi')), (True, True))
    verifier('rejeu : traiter_notifications enveloppe le travailleur verrouillé de 004',
             ('communication_traiter_notifications_sans_callbacks' in corps('traiter_notifications'),
              'communication_verrou_interrupteurs' in corps('communication_traiter_notifications_sans_callbacks')),
             (True, True))
    verifier('rejeu : une seule fonction intérieure de chaque sorte',
             db.sql("select count(*) filter (where proname = 'communication_expedier_envoi_sans_porte') || '|' || "
                    "count(*) filter (where proname = 'communication_traiter_notifications_sans_callbacks') "
                    "from pg_proc;").splitlines()[-1].strip(), '1|1')
    verifier('rejeu : fonctions intérieures et texte_notification fermées aux visiteurs et aux comptes',
             db.sql("select bool_or(has_function_privilege(r, p.oid, 'execute'))::text from pg_proc p, "
                    "unnest(array['anon', 'authenticated']) r where p.proname in "
                    "('communication_expedier_envoi_sans_porte', 'communication_traiter_notifications_sans_callbacks', "
                    "'texte_notification');").splitlines()[-1].strip(), 'false')
    service_sql(db, 'select public.traiter_notifications(1);')
    verifier('rejeu : le travailleur tourne toujours sans erreur', True, True)


def main():
    arguments = sys.argv[1:]
    if arguments not in ([], ['--s1-only']):
        raise SystemExit('Usage : essai-communication-center.py [--s1-only]')
    s1_only = arguments == ['--s1-only']
    if len(CHAINE) != 39:
        raise SystemExit('La chaîne locale attendue compte 39 fichiers ; constat : %d.' % len(CHAINE))
    if any(not os.path.isfile(path) for path in FICHIERS_CANDIDATS + (FICHIER_CANDIDATE_S1,)):
        raise SystemExit('Une migration candidate est absente.')

    if s1_only:
        print('Communication Center S-1 — PostgreSQL local jetable, données synthétiques uniquement')
    else:
        print('Communication Center — PostgreSQL local jetable, données synthétiques uniquement')
    try:
        for numero in (1, 2):
            # Chaque base est créée à neuf dans le cluster temporaire de cette exécution.
            S.BASE = 'goship_communication_c41_%d' % numero
            db = None
            try:
                db = installer_base_neuve(inclure_s1=s1_only)
                if s1_only:
                    # C7.2 ne relance pas les suites C1–C7 : seule la candidate S-1
                    # est réappliquée pour vérifier sa rejouabilité.
                    appliquer_candidate(db, FICHIER_CANDIDATE_S1)
                    verifier('candidate S-1 rejouée sans erreur (base %d)' % numero, True, True)
                    tester_identite_edge(db, numero)
                    tester_c72_recuperation_code(db, numero)
                    continue

                # Le mode complet historique rejoue les candidates avant sa suite.
                for chemin in FICHIERS_CANDIDATS:
                    appliquer_candidate(db, chemin)
                verifier('candidates rejouées sans erreur (base %d)' % numero, True, True)
                tester_permissions_et_reponse(db, numero)
                ids_transactionnels = tester_transactionnel(db, numero)
                tester_adaptateurs_et_callbacks(db, numero)
                tester_p07(db, numero, ids_transactionnels)
                appliquer_candidate(db, FICHIER_CANDIDATE_S1)
                appliquer_candidate(db, FICHIER_CANDIDATE_S1)
                verifier('candidate S-1 appliquée et rejouée avant le producteur C7.3', True, True)
                tester_identite_edge(db, numero)
                tester_consentements(db, numero)
                tester_p08_worker_et_recus(db, numero)
                tester_p09_classification(db, numero)
                tester_c5_interface(db, numero, ids_transactionnels)
                tester_c6_campagnes(db, numero)
                tester_c10_arret_admin(db, numero)
                tester_c9_reglages_et_alertes(db, numero)
                tester_c11_rejeu_chaine(db, numero)
            finally:
                if db is not None:
                    db._psql(db.su, 'postgres',
                             'drop database if exists %s with (force);' % S.BASE,
                             echec_permis=True)

        if not s1_only:
            # Les tests Edge utilisent WebCrypto réel et des transports simulés ; aucune
            # fonction distante, aucun RPC Supabase et aucune API fournisseur n'est appelé.
            edge_tests = os.path.join(ICI, 'essai-communication-edge.mjs')
            node = shutil.which('node')
            if not node or not os.path.isfile(edge_tests):
                raise SystemExit('Node.js et essai-communication-edge.mjs sont requis pour C4.1.')
            print('\nCommunication Center — vérifications locales Edge et travailleurs')
            subprocess.run([node, '--test', edge_tests], cwd=RACINE, check=True)
            interface_tests = os.path.join(ICI, 'essai-communication-interface.mjs')
            if not os.path.isfile(interface_tests):
                raise SystemExit('essai-communication-interface.mjs est requis pour C5.')
            print('\nCommunication Center — tests locaux de l’interface C5')
            subprocess.run([node, '--test', interface_tests], cwd=RACINE, check=True)

        total = len(S.RESULTATS)
        reussites = sum(1 for resultat in S.RESULTATS if resultat)
        print('\nRésultat : %d/%d vérifications réussies.' % (reussites, total))
        if reussites != total:
            raise SystemExit(1)
    finally:
        erreurs_nettoyage = []
        for serveur in reversed(SERVEURS):
            try:
                serveur.cleanup()
            except Exception as erreur:
                erreurs_nettoyage.append(type(erreur).__name__)
        shutil.rmtree(S.TRAVAIL, ignore_errors=True)
        shutil.rmtree(RUNTIME_PG, ignore_errors=True)
        if erreurs_nettoyage:
            print('AVERTISSEMENT : nettoyage PostgreSQL incomplet (%s).' % ', '.join(erreurs_nettoyage))


if __name__ == '__main__':
    main()
