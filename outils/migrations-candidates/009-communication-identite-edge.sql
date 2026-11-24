-- Candidate uniquement : identité PostgREST limitée aux Edge Functions du Communication Center.
-- En fin de outils/migrations.txt depuis le 23/11/2026 (étape C11) : essais locaux et CI
-- seulement. Ne pas appliquer à une base distante (critère C14 de docs/production/go-no-go.md).
begin;

-- Deux façons d'appliquer cette candidate :
--   * par le rôle postgres lui-même (non superutilisateur, CREATEROLE) : c'est le seul
--     possible sur Supabase hébergé, où le client n'a pas de superutilisateur ;
--   * par une session superutilisateur (bancs locaux) : elle agit sous `set role postgres`
--     et n'utilise ses droits que pour accorder les rôles dédiés à authenticator.
-- Tout autre rôle est refusé.
do $contexte_execution$
begin
  if not exists (
    select 1 from pg_catalog.pg_roles
     where rolname = session_user and (rolsuper or (rolname = 'postgres' and rolcreaterole))
  ) then
    raise exception 'COMMUNICATION_IDENTITY_REQUIRES_POSTGRES_OR_SUPERUSER_SESSION';
  end if;
end
$contexte_execution$;

-- Les objets applicatifs restent possédés par le rôle non-superutilisateur postgres.
set role postgres;

do $prerequis$
begin
  if pg_catalog.to_regclass('public.communication_confirmations_whatsapp') is null
     or pg_catalog.to_regclass('public.notification_envois') is null
     or pg_catalog.to_regclass('public.notifications') is null then
    raise exception 'COMMUNICATION_CONFIRMATION_TASK_PREREQUISITES_MISSING';
  end if;
end
$prerequis$;

create schema if not exists communication_edge;
do $schema_proprietaire$
begin
  if not exists (
    select 1 from pg_catalog.pg_namespace n
     where n.nspname = 'communication_edge'
       and n.nspowner = (select oid from pg_catalog.pg_roles where rolname = current_user)
  ) then
    raise exception 'COMMUNICATION_EDGE_SCHEMA_OWNER_UNEXPECTED';
  end if;
end
$schema_proprietaire$;
revoke all on schema communication_edge from public, anon, authenticated, service_role;

-- Le code WhatsApp est rattaché à une tâche de l'outbox existante ; cette
-- candidate ne crée ni deuxième file ni tâche d'envoi réelle.
alter table public.notification_envois
  add column if not exists communication_confirmation_demande_id bigint,
  add column if not exists communication_confirmation_claim_id uuid,
  add column if not exists communication_confirmation_claim_expire_le timestamptz,
  add column if not exists communication_confirmation_started_le timestamptz;

do $liaison_envoi$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint
     where conrelid = 'public.notification_envois'::regclass
       and conname = 'notification_envois_confirmation_demande_fk'
  ) then
    alter table public.notification_envois
      add constraint notification_envois_confirmation_demande_fk
      foreign key (communication_confirmation_demande_id)
      references public.communication_confirmations_whatsapp(id) on delete cascade;
  end if;
end
$liaison_envoi$;

create unique index if not exists notification_envois_confirmation_demande_uidx
  on public.notification_envois (communication_confirmation_demande_id)
  where communication_confirmation_demande_id is not null;

alter table public.notification_envois
  drop constraint if exists notification_envois_statut_check;
alter table public.notification_envois
  add constraint notification_envois_statut_check
  check (statut in ('attente', 'envoi', 'envoye', 'livre', 'echec', 'annule', 'incertain', 'confirmation'));

create table if not exists public.communication_confirmation_code_audit (
  id                       bigint generated always as identity primary key,
  notification_envoi_id    bigint references public.notification_envois(id) on delete set null,
  demande_id               bigint references public.communication_confirmations_whatsapp(id) on delete set null,
  action                   text not null,
  worker_jti               text not null,
  cree_le                  timestamptz not null default clock_timestamp()
);
alter table public.communication_confirmation_code_audit
  drop constraint if exists communication_confirmation_code_audit_action_check;
alter table public.communication_confirmation_code_audit
  add constraint communication_confirmation_code_audit_action_check
  check (action in ('tache_reclamee', 'code_lu', 'transmission_commencee',
                    'resultat_enregistre', 'transmission_incertaine'));
create index if not exists communication_confirmation_code_audit_tache_idx
  on public.communication_confirmation_code_audit (notification_envoi_id, cree_le desc);
alter table public.communication_confirmation_code_audit enable row level security;
revoke all on public.communication_confirmation_code_audit
  from public, anon, authenticated, service_role;


do $roles$
declare
  v_role text;
  v_oid oid;
  v_authenticator oid;
  v_schema text;
begin
  select oid into v_authenticator
    from pg_catalog.pg_roles where rolname = 'authenticator';
  if v_authenticator is null then
    raise exception 'COMMUNICATION_AUTHENTICATOR_ROLE_MISSING';
  end if;

  foreach v_role in array array['communication_webhook', 'communication_worker'] loop
    if not exists (select 1 from pg_catalog.pg_roles where rolname = v_role) then
      execute pg_catalog.format('create role %I nologin noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls', v_role);
    end if;

    select oid into v_oid from pg_catalog.pg_roles where rolname = v_role;
    -- Memberships entrants autorisés, et eux seuls :
    --   * authenticator, sans ADMIN OPTION : il permet à PostgREST de faire SET ROLE ;
    --   * postgres avec ADMIN OPTION, sans INHERIT ni SET : c'est le membership que
    --     PostgreSQL 16 et suivants donnent au rôle CREATEROLE non superutilisateur qui a
    --     créé le rôle (postgres chez Supabase, candidates 005 et 006). Il ne donne aucun
    --     droit du rôle à postgres ; il lui permet seulement d'accorder le rôle, ce qui
    --     rend cette candidate applicable sans superutilisateur. postgres possède déjà
    --     toutes les fonctions que ces rôles appellent : il n'en tire aucun droit nouveau.
    --     (Chez Supabase, postgres est de toute façon membre d'authenticator, avec INHERIT
    --     et SET : il atteint déjà ces rôles par lui, comme anon, authenticated et
    --     service_role. Constaté sur l'image Supabase PostgreSQL 17.4 le 24/11/2026.)
    -- Les memberships sortants donneraient au rôle des droits hérités : tous refusés.
    if exists (
      select 1 from pg_catalog.pg_auth_members
       where member = v_oid
    ) or exists (
      select 1 from pg_catalog.pg_auth_members a
       where a.roleid = v_oid
         and a.member <> v_authenticator
         and not (a.member = (select oid from pg_catalog.pg_roles where rolname = 'postgres')
                  and a.admin_option and not a.inherit_option and not a.set_option)
    ) then
      raise exception 'COMMUNICATION_ROLE_HAS_UNAPPROVED_MEMBERSHIP:%', v_role;
    end if;
    if exists (
      select 1 from pg_catalog.pg_auth_members
       where roleid = v_oid and member = v_authenticator and admin_option
    ) then
      raise exception 'COMMUNICATION_ROLE_AUTHENTICATOR_ADMIN_OPTION_UNSAFE:%', v_role;
    end if;
    if exists (
      select 1 from pg_catalog.pg_shdepend d
       where d.refclassid = 'pg_catalog.pg_authid'::regclass
         and d.refobjid = v_oid and d.deptype = 'o'
    ) then
      raise exception 'COMMUNICATION_ROLE_OWNS_OBJECTS:%', v_role;
    end if;

    if exists (
      select 1 from pg_catalog.pg_roles r
       where r.oid = v_oid and (r.rolcanlogin or r.rolinherit or r.rolcreatedb
         or r.rolcreaterole or r.rolreplication or r.rolbypassrls)
    ) then
      if exists (
        select 1 from pg_catalog.pg_roles r where r.oid = v_oid and r.rolsuper
      ) then
        raise exception 'COMMUNICATION_ROLE_SUPERUSER_UNSAFE:%', v_role;
      end if;
      -- NOSUPERUSER est vérifié plus bas, mais sa réécriture exige un superuser
      -- même si le rôle est déjà non-superuser. Ne modifier que les attributs
      -- qu'un rôle CREATEROLE peut corriger ; une élévation préexistante échoue fermé.
      execute pg_catalog.format(
        'alter role %I nologin noinherit nocreatedb nocreaterole noreplication nobypassrls',
        v_role
      );
    end if;
  end loop;

  -- Les rôles dédiés ne conservent aucun privilège direct dans un schéma applicatif.
  for v_schema in
    select nspname from pg_catalog.pg_namespace
     where nspname in ('public', 'communication_edge')
  loop
    execute pg_catalog.format(
      'revoke all privileges on schema %I from communication_webhook, communication_worker', v_schema);
    execute pg_catalog.format(
      'revoke all privileges on all tables in schema %I from communication_webhook, communication_worker', v_schema);
    execute pg_catalog.format(
      'revoke all privileges on all sequences in schema %I from communication_webhook, communication_worker', v_schema);
    execute pg_catalog.format(
      'revoke all privileges on all functions in schema %I from communication_webhook, communication_worker', v_schema);
  end loop;
end
$roles$;

revoke all on public.communication_confirmation_code_audit
  from communication_webhook, communication_worker;

-- Empêcher tout privilège de public hérité par PUBLIC. Les rôles API GoShip gardent
-- leurs droits explicites ; les rôles techniques n'accèdent qu'au schéma dédié.
revoke all on schema public from public;
grant usage on schema public to anon, authenticated, service_role;
revoke all on schema communication_edge from public, anon, authenticated, service_role;
grant usage on schema communication_edge to communication_webhook, communication_worker;

-- Ces valeurs doivent être configurées pour le rôle authenticator dans chaque environnement.
-- En leur absence, toutes les RPC Edge échouent fermé. Elles ne contiennent aucun secret.
create or replace function communication_edge.communication_edge_identite_valide(p_role text)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $fonction$
declare
  v_claims jsonb;
  v_issuer text := current_setting('app.communication_jwt_issuer', true);
  v_audience text := current_setting('app.communication_jwt_audience', true);
  v_ttl_setting text := current_setting('app.communication_jwt_max_ttl_seconds', true);
  v_ttl_max numeric;
  v_iat_text text;
  v_nbf_text text;
  v_exp_text text;
  v_jti text;
  v_iat numeric;
  v_nbf numeric;
  v_exp numeric;
  v_now numeric := extract(epoch from clock_timestamp());
  v_audience_ok boolean := false;
begin
  if p_role not in ('communication_webhook', 'communication_worker')
     or coalesce(v_issuer, '') = '' or coalesce(v_audience, '') = ''
     or coalesce(v_ttl_setting, '') !~ '^[0-9]{1,9}$' then
    return false;
  end if;
  begin
    v_ttl_max := v_ttl_setting::numeric;
    v_claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
    v_iat_text := v_claims ->> 'iat';
    v_nbf_text := v_claims ->> 'nbf';
    v_exp_text := v_claims ->> 'exp';
    v_jti := v_claims ->> 'jti';
    if coalesce(v_iat_text, '') !~ '^[0-9]{1,16}$'
       or coalesce(v_nbf_text, '') !~ '^[0-9]{1,16}$'
       or coalesce(v_exp_text, '') !~ '^[0-9]{1,16}$' then
      return false;
    end if;
    v_iat := v_iat_text::numeric;
    v_nbf := v_nbf_text::numeric;
    v_exp := v_exp_text::numeric;
  exception when others then
    return false;
  end;
  if v_claims is null
     or v_ttl_max <= 0
     or jsonb_typeof(v_claims -> 'iat') is distinct from 'number'
     or jsonb_typeof(v_claims -> 'nbf') is distinct from 'number'
     or jsonb_typeof(v_claims -> 'exp') is distinct from 'number'
     or jsonb_typeof(v_claims -> 'jti') is distinct from 'string'
     or pg_catalog.length(v_jti) not between 16 and 200
     or v_claims ->> 'role' is distinct from p_role
     or v_claims ->> 'iss' is distinct from v_issuer
     or v_iat is null or v_nbf is null or v_exp is null
     or v_iat > v_now + 30 or v_nbf > v_now + 30
     or v_exp <= v_now or v_exp <= v_iat
     or v_nbf > v_exp or v_exp - v_iat > v_ttl_max then
    return false;
  end if;
  if jsonb_typeof(v_claims -> 'aud') = 'string' then
    v_audience_ok := v_claims ->> 'aud' = v_audience;
  elsif jsonb_typeof(v_claims -> 'aud') = 'array' then
    select exists (
      select 1 from jsonb_array_elements_text(v_claims -> 'aud') as a(value)
       where a.value = v_audience
    ) into v_audience_ok;
  end if;
  return v_audience_ok;
end
$fonction$;

-- Producteur idempotent appelé par la RPC de consentement, dans sa transaction.
-- La notification est invisible dans le canal client ; l'outbox ne conserve ni
-- code, ni téléphone, ni contenu de message.
create or replace function communication_edge.communication_edge_confirmation_creer_tache_whatsapp(
  p_demande_id bigint, p_client_id uuid
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $fonction$
declare
  v_demande public.communication_confirmations_whatsapp;
  v_notification_id bigint;
  v_envoi_id bigint;
  v_cle text;
begin
  select * into v_demande
    from public.communication_confirmations_whatsapp d
   where d.id = p_demande_id and d.client_id = p_client_id
   for update;
  if not found or v_demande.etat is distinct from 'en_attente'
     or v_demande.expire_le <= pg_catalog.clock_timestamp()
     or v_demande.code_secret_id is null then
    raise exception 'COMMUNICATION_CONFIRMATION_TASK_UNAVAILABLE';
  end if;

  select e.id into v_envoi_id
    from public.notification_envois e
   where e.communication_confirmation_demande_id = p_demande_id;
  if found then
    return;
  end if;

  v_cle := 'confirmation_whatsapp:' || p_demande_id::text;
  insert into public.notifications
    (client_id, canal, evenement, destinataire, type, categorie, priorite, cle, donnees)
  values
    (p_client_id, 'whatsapp', 'confirmation_whatsapp', 'whatsapp',
     'confirmation_whatsapp', 'compte', 'haute', v_cle, '{}'::jsonb)
  on conflict (cle) where cle is not null do nothing
  returning id into v_notification_id;

  if v_notification_id is null then
    select n.id into v_notification_id
      from public.notifications n
     where n.cle = v_cle and n.client_id = p_client_id
       and n.canal = 'whatsapp' and n.type = 'confirmation_whatsapp'
       and n.donnees = '{}'::jsonb;
    if v_notification_id is null then
      raise exception 'COMMUNICATION_CONFIRMATION_IDEMPOTENCY_CONFLICT';
    end if;
  end if;

  insert into public.notification_envois
    (notification_id, canal, cible, fournisseur, statut, priorite,
     communication_confirmation_demande_id)
  values
    (v_notification_id, 'whatsapp', 'confirmation:' || p_demande_id::text,
     'meta', 'confirmation', 'haute', p_demande_id)
  on conflict do nothing
  returning id into v_envoi_id;

  if v_envoi_id is null then
    select e.id into v_envoi_id
      from public.notification_envois e
     where e.communication_confirmation_demande_id = p_demande_id
       and e.notification_id = v_notification_id and e.canal = 'whatsapp';
    if v_envoi_id is null then
      raise exception 'COMMUNICATION_CONFIRMATION_TASK_CREATION_FAILED';
    end if;
  end if;
end
$fonction$;

create or replace function communication_edge.communication_edge_worker_reclamer_confirmation_whatsapp(
  p_envoi_id bigint, p_claim_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $fonction$
declare
  v_client uuid;
  v_empreinte text;
  v_demande public.communication_confirmations_whatsapp;
  v_envoi public.notification_envois;
  v_jti text;
  v_lease_text text := current_setting('app.communication_confirmation_claim_seconds', true);
  v_lease_seconds integer;
begin
  if not communication_edge.communication_edge_identite_valide('communication_worker') then
    raise exception 'PERMISSION_DENIED';
  end if;
  v_jti := current_setting('request.jwt.claims', true)::jsonb ->> 'jti';
  if p_envoi_id is null or p_claim_id is null
     or coalesce(v_lease_text, '') !~ '^[1-9][0-9]{0,2}$' then
    raise exception 'COMMUNICATION_CONFIRMATION_TASK_UNAVAILABLE';
  end if;
  v_lease_seconds := v_lease_text::integer;
  if v_lease_seconds > 600 then
    raise exception 'COMMUNICATION_CONFIRMATION_TASK_UNAVAILABLE';
  end if;

  -- Première lecture sans verrou : l'ordre obligatoire est N3 compte, N3
  -- empreinte, demande de confirmation, puis tâche de l'outbox.
  select d.client_id, d.cible_empreinte into v_client, v_empreinte
    from public.notification_envois e
    join public.notifications n on n.id = e.notification_id
    join public.communication_confirmations_whatsapp d
      on d.id = e.communication_confirmation_demande_id
   where e.id = p_envoi_id and e.canal = 'whatsapp' and e.statut = 'confirmation'
     and n.client_id = d.client_id;
  if not found then
    return pg_catalog.jsonb_build_object('ok', true, 'claimed', false);
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('goship:consent-account:' || v_client::text, 0));
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('goship:whatsapp:' || v_empreinte, 0));

  select * into v_demande
    from public.communication_confirmations_whatsapp d
   where d.id = (select e.communication_confirmation_demande_id
                   from public.notification_envois e where e.id = p_envoi_id)
   for update;
  if not found or v_demande.client_id is distinct from v_client
     or v_demande.etat is distinct from 'en_attente'
     or v_demande.expire_le <= pg_catalog.clock_timestamp()
     or v_demande.code_secret_id is null
     or public.communication_consentement_empreinte(
          public.communication_consentement_cible(v_client)) is distinct from v_demande.cible_empreinte then
    return pg_catalog.jsonb_build_object('ok', true, 'claimed', false);
  end if;

  select * into v_envoi from public.notification_envois e
   where e.id = p_envoi_id
     and e.communication_confirmation_demande_id = v_demande.id
     and e.canal = 'whatsapp' and e.statut = 'confirmation'
   for update;
  if not found then
    return pg_catalog.jsonb_build_object('ok', true, 'claimed', false);
  end if;

  if v_envoi.communication_confirmation_claim_id is not null
     and v_envoi.communication_confirmation_claim_expire_le > pg_catalog.clock_timestamp()
     and v_envoi.communication_confirmation_claim_id is distinct from p_claim_id then
    return pg_catalog.jsonb_build_object('ok', true, 'claimed', false);
  end if;
  if v_envoi.communication_confirmation_claim_id = p_claim_id
     and v_envoi.communication_confirmation_claim_expire_le <= pg_catalog.clock_timestamp() then
    -- Un identifiant expiré ne peut pas être rejoué pour reprendre une tâche.
    return pg_catalog.jsonb_build_object('ok', true, 'claimed', false);
  end if;

  update public.notification_envois
     set communication_confirmation_claim_id = p_claim_id,
         communication_confirmation_claim_expire_le = case
           when communication_confirmation_claim_id = p_claim_id
            and communication_confirmation_claim_expire_le > pg_catalog.clock_timestamp()
             then communication_confirmation_claim_expire_le
           else pg_catalog.clock_timestamp() + pg_catalog.make_interval(secs => v_lease_seconds)
         end,
         maj_le = pg_catalog.clock_timestamp()
   where id = p_envoi_id;

  insert into public.communication_confirmation_code_audit
    (notification_envoi_id, demande_id, action, worker_jti)
  values (p_envoi_id, v_demande.id, 'tache_reclamee', v_jti);

  return pg_catalog.jsonb_build_object(
    'ok', true, 'claimed', true, 'envoi_id', p_envoi_id,
    'claim_id', p_claim_id,
    'expire_le', (select communication_confirmation_claim_expire_le
                    from public.notification_envois where id = p_envoi_id));
end
$fonction$;

create or replace function communication_edge.communication_edge_worker_reserver_confirmation_whatsapp(
  p_claim_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $fonction$
declare
  v_envoi_id bigint;
begin
  if not communication_edge.communication_edge_identite_valide('communication_worker') then
    raise exception 'PERMISSION_DENIED';
  end if;
  if p_claim_id is null then
    return pg_catalog.jsonb_build_object('ok', true, 'claimed', false);
  end if;

  -- Cette sélection n'acquiert aucun verrou métier. La RPC de réservation
  -- réévalue ensuite la tâche sous l'ordre N3 compte, N3 contact, demande, outbox.
  select e.id into v_envoi_id
    from public.notification_envois e
    join public.communication_confirmations_whatsapp d
      on d.id = e.communication_confirmation_demande_id
    join public.notifications n on n.id = e.notification_id
   where e.canal = 'whatsapp' and e.statut = 'confirmation'
     and e.prochain_essai_le <= pg_catalog.clock_timestamp()
     and (e.communication_confirmation_claim_id is null
       or e.communication_confirmation_claim_expire_le <= pg_catalog.clock_timestamp())
     and e.communication_confirmation_started_le is null
     and d.etat = 'en_attente' and d.expire_le > pg_catalog.clock_timestamp()
     and d.code_secret_id is not null and n.client_id = d.client_id
   order by (e.priorite = 'haute') desc, e.prochain_essai_le, e.id
   limit 1;
  if v_envoi_id is null then
    return pg_catalog.jsonb_build_object('ok', true, 'claimed', false);
  end if;
  return communication_edge.communication_edge_worker_reclamer_confirmation_whatsapp(
    v_envoi_id, p_claim_id);
end
$fonction$;

create or replace function communication_edge.communication_edge_worker_contexte_confirmation_whatsapp(
  p_envoi_id bigint, p_claim_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $fonction$
declare
  v_client uuid;
  v_empreinte text;
  v_demande public.communication_confirmations_whatsapp;
  v_envoi public.notification_envois;
  v_cible text;
  v_langue text;
begin
  if not communication_edge.communication_edge_identite_valide('communication_worker') then
    raise exception 'PERMISSION_DENIED';
  end if;
  if p_envoi_id is null or p_claim_id is null then
    return null;
  end if;

  select d.client_id, d.cible_empreinte into v_client, v_empreinte
    from public.notification_envois e
    join public.notifications n on n.id = e.notification_id
    join public.communication_confirmations_whatsapp d
      on d.id = e.communication_confirmation_demande_id
   where e.id = p_envoi_id and e.canal = 'whatsapp'
     and n.client_id = d.client_id;
  if not found then
    return null;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('goship:consent-account:' || v_client::text, 0));
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('goship:whatsapp:' || v_empreinte, 0));

  select * into v_demande
    from public.communication_confirmations_whatsapp d
   where d.id = (select e.communication_confirmation_demande_id
                   from public.notification_envois e where e.id = p_envoi_id)
   for update;
  if not found or v_demande.client_id is distinct from v_client
     or v_demande.etat is distinct from 'en_attente'
     or v_demande.expire_le <= pg_catalog.clock_timestamp()
     or v_demande.code_secret_id is null
     or public.communication_consentement_empreinte(
          public.communication_consentement_cible(v_client)) is distinct from v_demande.cible_empreinte then
    return null;
  end if;

  select * into v_envoi from public.notification_envois e
   where e.id = p_envoi_id
     and e.communication_confirmation_demande_id = v_demande.id
     and e.canal = 'whatsapp' and e.statut = 'confirmation'
     and e.communication_confirmation_started_le is null
     and e.communication_confirmation_claim_id = p_claim_id
     and e.communication_confirmation_claim_expire_le > pg_catalog.clock_timestamp()
   for update;
  if not found then
    return null;
  end if;

  v_cible := public.communication_consentement_cible(v_client);
  select public.langue_notification(c.langue) into v_langue
    from public.clients c where c.id = v_client and c.role = 'client';
  if coalesce(v_cible, '') !~ '^[+]?[0-9]{5,20}$' or v_langue is null then
    return null;
  end if;
  return pg_catalog.jsonb_build_object('destinataire', v_cible, 'langue', v_langue);
end
$fonction$;

create or replace function communication_edge.communication_edge_worker_code_whatsapp_pour_envoi(
  p_envoi_id bigint, p_claim_id uuid
)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $fonction$
declare
  v_client uuid;
  v_empreinte text;
  v_demande public.communication_confirmations_whatsapp;
  v_envoi public.notification_envois;
  v_jti text;
  v_code text;
begin
  if not communication_edge.communication_edge_identite_valide('communication_worker') then
    raise exception 'PERMISSION_DENIED';
  end if;
  v_jti := current_setting('request.jwt.claims', true)::jsonb ->> 'jti';
  if p_envoi_id is null or p_claim_id is null then
    return null;
  end if;

  select d.client_id, d.cible_empreinte into v_client, v_empreinte
    from public.notification_envois e
    join public.notifications n on n.id = e.notification_id
    join public.communication_confirmations_whatsapp d
      on d.id = e.communication_confirmation_demande_id
   where e.id = p_envoi_id and e.canal = 'whatsapp' and e.statut = 'confirmation'
     and n.client_id = d.client_id;
  if not found then
    return null;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('goship:consent-account:' || v_client::text, 0));
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('goship:whatsapp:' || v_empreinte, 0));

  select * into v_demande
    from public.communication_confirmations_whatsapp d
   where d.id = (select e.communication_confirmation_demande_id
                   from public.notification_envois e where e.id = p_envoi_id)
   for update;
  if not found or v_demande.client_id is distinct from v_client
     or v_demande.etat is distinct from 'en_attente'
     or v_demande.expire_le <= pg_catalog.clock_timestamp()
     or v_demande.code_secret_id is null
     or public.communication_consentement_empreinte(
          public.communication_consentement_cible(v_client)) is distinct from v_demande.cible_empreinte then
    return null;
  end if;

  select * into v_envoi from public.notification_envois e
   where e.id = p_envoi_id
     and e.communication_confirmation_demande_id = v_demande.id
     and e.canal = 'whatsapp' and e.statut = 'confirmation'
   for update;
  if not found or v_envoi.communication_confirmation_claim_id is distinct from p_claim_id
     or v_envoi.communication_confirmation_claim_expire_le <= pg_catalog.clock_timestamp() then
    return null;
  end if;

  select d.decrypted_secret into v_code
    from vault.decrypted_secrets d where d.id = v_demande.code_secret_id;
  if v_code is null then
    return null;
  end if;

  insert into public.communication_confirmation_code_audit
    (notification_envoi_id, demande_id, action, worker_jti)
  values (p_envoi_id, v_demande.id, 'code_lu', v_jti);
  return v_code;
end
$fonction$;

create or replace function communication_edge.communication_edge_worker_debut_confirmation_whatsapp(
  p_envoi_id bigint, p_claim_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $fonction$
declare
  v_client uuid;
  v_empreinte text;
  v_demande public.communication_confirmations_whatsapp;
  v_envoi public.notification_envois;
  v_jti text;
  v_raison text;
begin
  if not communication_edge.communication_edge_identite_valide('communication_worker') then
    raise exception 'PERMISSION_DENIED';
  end if;
  v_jti := current_setting('request.jwt.claims', true)::jsonb ->> 'jti';
  select d.client_id, d.cible_empreinte into v_client, v_empreinte
    from public.notification_envois e
    join public.notifications n on n.id = e.notification_id
    join public.communication_confirmations_whatsapp d
      on d.id = e.communication_confirmation_demande_id
   where e.id = p_envoi_id and e.canal = 'whatsapp' and n.client_id = d.client_id;
  if not found then
    return pg_catalog.jsonb_build_object('ok', true, 'started', false);
  end if;

  -- Porte P-07, avant tout autre verrou : N0 partagé, puis verrous du compte et
  -- du contact, puis lignes. L'Edge transmet le code APRÈS le COMMIT de cet
  -- appel. Le N0 partagé tenu jusqu'au COMMIT et le statut « envoi » écrit ici
  -- garantissent qu'une confirmation d'arrêt attend la fin de cette transmission,
  -- et qu'aucune transmission ne commence après la fermeture des sorties
  -- (correction du 23/11/2026 : ce chemin contournait l'arrêt d'urgence).
  v_raison := public.communication_autoriser_sortie('envoi', 'whatsapp');
  if v_raison is not null then
    return pg_catalog.jsonb_build_object('ok', true, 'started', false, 'raison', v_raison);
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('goship:consent-account:' || v_client::text, 0));
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('goship:whatsapp:' || v_empreinte, 0));
  select * into v_demande from public.communication_confirmations_whatsapp d
   where d.id = (select e.communication_confirmation_demande_id
                   from public.notification_envois e where e.id = p_envoi_id)
   for update;
  if not found or v_demande.etat is distinct from 'en_attente'
     or v_demande.expire_le <= pg_catalog.clock_timestamp()
     or v_demande.code_secret_id is null
     or public.communication_consentement_empreinte(
          public.communication_consentement_cible(v_client)) is distinct from v_demande.cible_empreinte then
    return pg_catalog.jsonb_build_object('ok', true, 'started', false);
  end if;

  select * into v_envoi from public.notification_envois e
   where e.id = p_envoi_id and e.communication_confirmation_demande_id = v_demande.id
     and e.statut = 'confirmation' and e.communication_confirmation_started_le is null
     and e.communication_confirmation_claim_id = p_claim_id
     and e.communication_confirmation_claim_expire_le > pg_catalog.clock_timestamp()
   for update;
  if not found then
    return pg_catalog.jsonb_build_object('ok', true, 'started', false);
  end if;

  update public.notification_envois
     set statut = 'envoi',
         tentative = tentative + 1,
         verrouille_le = pg_catalog.clock_timestamp(),
         communication_confirmation_started_le = pg_catalog.clock_timestamp(),
         maj_le = pg_catalog.clock_timestamp()
   where id = p_envoi_id;
  insert into public.communication_confirmation_code_audit
    (notification_envoi_id, demande_id, action, worker_jti)
  values (p_envoi_id, v_demande.id, 'transmission_commencee', v_jti);
  return pg_catalog.jsonb_build_object('ok', true, 'started', true);
end
$fonction$;

create or replace function communication_edge.communication_edge_worker_terminer_confirmation_whatsapp(
  p_envoi_id bigint, p_claim_id uuid, p_resultat text,
  p_message_id text default null, p_code_erreur text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $fonction$
declare
  v_client uuid;
  v_empreinte text;
  v_demande public.communication_confirmations_whatsapp;
  v_envoi public.notification_envois;
  v_statut text;
  v_maj_code text;
  v_jti text;
  v_tentatives_max integer := (select tentatives_max from public.notification_moteur where id is true);
  v_contact_valide boolean;
begin
  if not communication_edge.communication_edge_identite_valide('communication_worker') then
    raise exception 'PERMISSION_DENIED';
  end if;
  v_jti := current_setting('request.jwt.claims', true)::jsonb ->> 'jti';
  if p_envoi_id is null or p_claim_id is null
     or p_resultat not in ('accepte', 'definitif', 'temporaire', 'incertain')
     or (p_message_id is not null and p_message_id !~ '^[A-Za-z0-9_.:-]{1,200}$')
     or (p_code_erreur is not null and p_code_erreur not in (
           'LIMITE_DEBIT', 'REFUS_FOURNISSEUR', 'RESULTAT_INCERTAIN',
           'DESTINATAIRE_INVALIDE', 'MODELE_INDISPONIBLE', 'ERREUR_FOURNISSEUR'))
     or (p_resultat = 'accepte' and p_message_id is null)
     or (p_resultat <> 'accepte' and p_message_id is not null) then
    raise exception 'COMMUNICATION_CONFIRMATION_RESULT_INVALID';
  end if;

  select d.client_id, d.cible_empreinte into v_client, v_empreinte
    from public.notification_envois e
    join public.notifications n on n.id = e.notification_id
    join public.communication_confirmations_whatsapp d
      on d.id = e.communication_confirmation_demande_id
   where e.id = p_envoi_id and e.canal = 'whatsapp' and n.client_id = d.client_id;
  if not found then
    return pg_catalog.jsonb_build_object('ok', true, 'recorded', false);
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('goship:consent-account:' || v_client::text, 0));
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('goship:whatsapp:' || v_empreinte, 0));
  select * into v_demande from public.communication_confirmations_whatsapp d
   where d.id = (select e.communication_confirmation_demande_id
                   from public.notification_envois e where e.id = p_envoi_id)
   for update;
  select * into v_envoi from public.notification_envois e
   where e.id = p_envoi_id and e.communication_confirmation_demande_id = v_demande.id
     and e.statut = 'envoi' and e.communication_confirmation_started_le is not null
     and e.communication_confirmation_claim_id = p_claim_id
   for update;
  if not found then
    return pg_catalog.jsonb_build_object('ok', true, 'recorded', false);
  end if;

  v_contact_valide := v_demande.etat = 'en_attente'
    and v_demande.expire_le > pg_catalog.clock_timestamp()
    and v_demande.code_secret_id is not null
    and public.communication_consentement_empreinte(
          public.communication_consentement_cible(v_client)) = v_demande.cible_empreinte;

  if p_resultat = 'accepte' and v_contact_valide then
    v_statut := 'envoye';
    v_maj_code := null;
  elsif p_resultat = 'accepte' then
    -- La transmission a peut-être réussi, mais la demande/contact a changé :
    -- conserver l'incertitude et interdire toute reprise automatique.
    v_statut := 'incertain';
    v_maj_code := 'RESULTAT_INCERTAIN';
  elsif p_resultat = 'incertain' then
    v_statut := 'incertain';
    v_maj_code := 'RESULTAT_INCERTAIN';
  elsif p_resultat = 'definitif' then
    v_statut := 'echec';
    v_maj_code := coalesce(p_code_erreur, 'ERREUR_FOURNISSEUR');
  elsif v_contact_valide and v_envoi.tentative < coalesce(v_tentatives_max, 0) then
    v_statut := 'confirmation';
    v_maj_code := coalesce(p_code_erreur, 'LIMITE_DEBIT');
  else
    v_statut := 'echec';
    v_maj_code := coalesce(p_code_erreur, 'LIMITE_DEBIT');
  end if;

  update public.notification_envois
     set statut = v_statut,
         message_id = case when p_resultat = 'accepte' then p_message_id else message_id end,
         envoye_le = case when v_statut = 'envoye' then pg_catalog.clock_timestamp() else envoye_le end,
         code_erreur = v_maj_code,
         erreur = null,
         verrouille_le = null,
         communication_confirmation_claim_id = null,
         communication_confirmation_claim_expire_le = null,
         communication_confirmation_started_le = case
           when v_statut = 'confirmation' then null else communication_confirmation_started_le end,
         prochain_essai_le = case
           when v_statut = 'confirmation' then pg_catalog.clock_timestamp() + interval '30 seconds'
           else prochain_essai_le end,
         maj_le = pg_catalog.clock_timestamp()
   where id = p_envoi_id;

  insert into public.communication_confirmation_code_audit
    (notification_envoi_id, demande_id, action, worker_jti)
  values (p_envoi_id, v_demande.id,
          case when v_statut = 'incertain' then 'transmission_incertaine' else 'resultat_enregistre' end,
          v_jti);
  return pg_catalog.jsonb_build_object('ok', true, 'recorded', true, 'status', v_statut);
end
$fonction$;

create or replace function communication_edge.communication_edge_worker_recuperer_confirmations_whatsapp(
  p_limite integer default 50
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $fonction$
declare
  v_jti text;
  v_envoi public.notification_envois;
  v_nombre integer := 0;
  v_limite integer := least(greatest(coalesce(p_limite, 50), 1), 200);
begin
  if not communication_edge.communication_edge_identite_valide('communication_worker') then
    raise exception 'PERMISSION_DENIED';
  end if;
  v_jti := current_setting('request.jwt.claims', true)::jsonb ->> 'jti';
  for v_envoi in
    select e.* from public.notification_envois e
     where e.communication_confirmation_demande_id is not null
       and e.statut = 'envoi' and e.communication_confirmation_started_le is not null
       and e.communication_confirmation_claim_expire_le <= pg_catalog.clock_timestamp()
     order by e.communication_confirmation_claim_expire_le, e.id
     limit v_limite
     for update skip locked
  loop
    update public.notification_envois
       set statut = 'incertain', code_erreur = 'RESULTAT_INCERTAIN', erreur = null,
           verrouille_le = null, communication_confirmation_claim_id = null,
           communication_confirmation_claim_expire_le = null,
           maj_le = pg_catalog.clock_timestamp()
     where id = v_envoi.id;
    insert into public.communication_confirmation_code_audit
      (notification_envoi_id, demande_id, action, worker_jti)
    values (v_envoi.id, v_envoi.communication_confirmation_demande_id,
            'transmission_incertaine', v_jti);
    v_nombre := v_nombre + 1;
  end loop;
  return pg_catalog.jsonb_build_object('ok', true, 'recovered', v_nombre);
end
$fonction$;

create or replace function communication_edge.communication_edge_webhook_recevoir_statut_transactionnel(
  p_fournisseur text, p_charge text, p_signature text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fonction$
begin
  if not communication_edge.communication_edge_identite_valide('communication_webhook') then
    raise exception 'PERMISSION_DENIED';
  end if;
  return public.communication_recevoir_statut_transactionnel(p_fournisseur, p_charge, p_signature);
end
$fonction$;

create or replace function communication_edge.communication_edge_webhook_recevoir_evenement(
  p_fournisseur text, p_charge text, p_signature text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fonction$
begin
  if not communication_edge.communication_edge_identite_valide('communication_webhook') then
    raise exception 'PERMISSION_DENIED';
  end if;
  return public.communication_recevoir_evenement(p_fournisseur, p_charge, p_signature);
end
$fonction$;

create or replace function communication_edge.communication_edge_worker_traiter_evenements_prioritaires(p_limite integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fonction$
begin
  if not communication_edge.communication_edge_identite_valide('communication_worker') then
    raise exception 'PERMISSION_DENIED';
  end if;
  return public.communication_traiter_evenements_prioritaires(p_limite);
end
$fonction$;

create or replace function communication_edge.communication_edge_worker_expo_recus_a_reconcilier(p_limite integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fonction$
begin
  if not communication_edge.communication_edge_identite_valide('communication_worker') then
    raise exception 'PERMISSION_DENIED';
  end if;
  return public.communication_expo_recus_a_reconcilier(p_limite);
end
$fonction$;

create or replace function communication_edge.communication_edge_worker_expo_enregistrer_recus(p_resultats jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fonction$
begin
  if not communication_edge.communication_edge_identite_valide('communication_worker') then
    raise exception 'PERMISSION_DENIED';
  end if;
  return public.communication_expo_enregistrer_recus(p_resultats);
end
$fonction$;

create or replace function communication_edge.communication_edge_worker_traiter_notifications(p_limite integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fonction$
begin
  if not communication_edge.communication_edge_identite_valide('communication_worker') then
    raise exception 'PERMISSION_DENIED';
  end if;
  return public.communication_worker_traiter_notifications(p_limite);
end
$fonction$;

-- Supprimer l'ancien chemin privilégié. Le worker ne peut lire un code qu'à
-- travers une tâche WhatsApp explicitement liée à la demande.
revoke all on function public.communication_code_whatsapp_pour_envoi(bigint)
  from public, anon, authenticated, service_role, communication_webhook, communication_worker;
revoke all on function public.communication_recevoir_statut_transactionnel(text,text,text)
  from communication_webhook, communication_worker;
revoke all on function public.communication_recevoir_evenement(text,text,text)
  from communication_webhook, communication_worker;
revoke all on function public.communication_traiter_evenements_prioritaires(integer),
  public.communication_expo_recus_a_reconcilier(integer),
  public.communication_expo_enregistrer_recus(jsonb),
  public.communication_worker_traiter_notifications(integer)
  from communication_webhook, communication_worker;

revoke all on function communication_edge.communication_edge_identite_valide(text),
  communication_edge.communication_edge_confirmation_creer_tache_whatsapp(bigint,uuid),
  communication_edge.communication_edge_webhook_recevoir_statut_transactionnel(text,text,text),
  communication_edge.communication_edge_webhook_recevoir_evenement(text,text,text),
  communication_edge.communication_edge_worker_traiter_evenements_prioritaires(integer),
  communication_edge.communication_edge_worker_expo_recus_a_reconcilier(integer),
  communication_edge.communication_edge_worker_expo_enregistrer_recus(jsonb),
  communication_edge.communication_edge_worker_traiter_notifications(integer),
  communication_edge.communication_edge_worker_reclamer_confirmation_whatsapp(bigint,uuid),
  communication_edge.communication_edge_worker_reserver_confirmation_whatsapp(uuid),
  communication_edge.communication_edge_worker_contexte_confirmation_whatsapp(bigint,uuid),
  communication_edge.communication_edge_worker_code_whatsapp_pour_envoi(bigint,uuid),
  communication_edge.communication_edge_worker_debut_confirmation_whatsapp(bigint,uuid),
  communication_edge.communication_edge_worker_terminer_confirmation_whatsapp(bigint,uuid,text,text,text),
  communication_edge.communication_edge_worker_recuperer_confirmations_whatsapp(integer)
  from public, anon, authenticated, service_role, communication_webhook, communication_worker;

grant execute on function communication_edge.communication_edge_webhook_recevoir_statut_transactionnel(text,text,text),
  communication_edge.communication_edge_webhook_recevoir_evenement(text,text,text)
  to communication_webhook;
grant execute on function communication_edge.communication_edge_worker_traiter_evenements_prioritaires(integer),
  communication_edge.communication_edge_worker_expo_recus_a_reconcilier(integer),
  communication_edge.communication_edge_worker_expo_enregistrer_recus(jsonb),
  communication_edge.communication_edge_worker_traiter_notifications(integer),
  communication_edge.communication_edge_worker_reserver_confirmation_whatsapp(uuid),
  communication_edge.communication_edge_worker_contexte_confirmation_whatsapp(bigint,uuid),
  communication_edge.communication_edge_worker_code_whatsapp_pour_envoi(bigint,uuid),
  communication_edge.communication_edge_worker_debut_confirmation_whatsapp(bigint,uuid),
  communication_edge.communication_edge_worker_terminer_confirmation_whatsapp(bigint,uuid,text,text,text),
  communication_edge.communication_edge_worker_recuperer_confirmations_whatsapp(integer)
  to communication_worker;

-- Membership de PostgREST sur les rôles dédiés. Par postgres (Supabase hébergé), grâce
-- à l'ADMIN OPTION de créateur décrite plus haut ; par la session superutilisateur
-- (bancs locaux) sinon. Si postgres n'a pas cette ADMIN OPTION (rôles créés par un
-- superutilisateur) et que la session n'est pas superutilisateur, l'instruction échoue :
-- la candidate s'arrête sans rien laisser à moitié.
reset role;
grant communication_webhook, communication_worker to authenticator;
set role postgres;

do $verification$
declare
  v_role text;
  v_oid oid;
  v_public_functions text[];
begin
  if not pg_catalog.has_schema_privilege('anon', 'public', 'usage')
     or not pg_catalog.has_schema_privilege('authenticated', 'public', 'usage')
     or not pg_catalog.has_schema_privilege('service_role', 'public', 'usage') then
    raise exception 'COMMUNICATION_PUBLIC_SCHEMA_API_ACCESS_MISSING';
  end if;

  foreach v_role in array array['communication_webhook', 'communication_worker'] loop
    select oid into v_oid from pg_catalog.pg_roles where rolname = v_role;
    if exists (
      select 1 from pg_catalog.pg_roles r
       where r.oid = v_oid and (r.rolcanlogin or r.rolinherit or r.rolsuper or r.rolcreatedb
         or r.rolcreaterole or r.rolreplication or r.rolbypassrls)
    ) then
      raise exception 'COMMUNICATION_ROLE_ATTRIBUTES_UNSAFE:%', v_role;
    end if;
    if not pg_catalog.pg_has_role('authenticator', v_oid, 'MEMBER') then
      raise exception 'COMMUNICATION_ROLE_AUTHENTICATOR_MEMBERSHIP_MISSING:%', v_role;
    end if;
    if pg_catalog.has_schema_privilege(v_role, 'public', 'usage')
       or not pg_catalog.has_schema_privilege(v_role, 'communication_edge', 'usage')
       or exists (
         select 1 from pg_catalog.pg_namespace n
          where n.nspname <> 'information_schema' and n.nspname !~ '^pg_'
            and n.nspname <> 'communication_edge'
            -- Supabase donne l'USAGE public sur `net`; ce schéma doit rester
            -- absent de l'allowlist PostgREST qui ne publie que les RPC Edge.
            and n.nspname <> 'net'
            and pg_catalog.has_schema_privilege(v_role, n.nspname, 'usage')
       ) then
      raise exception 'COMMUNICATION_ROLE_SCHEMA_PRIVILEGES_UNEXPECTED:%', v_role;
    end if;
    if pg_catalog.has_table_privilege(v_role, 'public.communication_confirmations_whatsapp', 'select')
       or pg_catalog.has_table_privilege(v_role, 'vault.decrypted_secrets', 'select') then
      raise exception 'COMMUNICATION_ROLE_DIRECT_DATA_ACCESS:%', v_role;
    end if;
    select array_agg(p.proname order by p.proname) into v_public_functions
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'communication_edge'
       and pg_catalog.has_function_privilege(v_role, p.oid, 'execute')
       and not (
         (v_role = 'communication_webhook' and p.proname in (
           'communication_edge_webhook_recevoir_statut_transactionnel',
           'communication_edge_webhook_recevoir_evenement'))
         or
         (v_role = 'communication_worker' and p.proname in (
           'communication_edge_worker_traiter_evenements_prioritaires',
           'communication_edge_worker_expo_recus_a_reconcilier',
           'communication_edge_worker_expo_enregistrer_recus',
           'communication_edge_worker_traiter_notifications',
           'communication_edge_worker_reserver_confirmation_whatsapp',
           'communication_edge_worker_contexte_confirmation_whatsapp',
           'communication_edge_worker_code_whatsapp_pour_envoi',
           'communication_edge_worker_debut_confirmation_whatsapp',
           'communication_edge_worker_terminer_confirmation_whatsapp',
           'communication_edge_worker_recuperer_confirmations_whatsapp'))
       );
    if coalesce(array_length(v_public_functions, 1), 0) > 0 then
      raise exception 'COMMUNICATION_ROLE_EXTRA_RPC_PRIVILEGES:%:%', v_role, v_public_functions;
    end if;
  end loop;
end
$verification$;

commit;
