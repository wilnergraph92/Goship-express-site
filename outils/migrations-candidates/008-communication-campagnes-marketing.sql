-- C6 — campagnes marketing, segments, approbations et planification sans envoi.
-- En fin de outils/migrations.txt depuis le 23/11/2026 (étape C11) : essais locaux et CI
-- seulement. Ne pas appliquer à une base distante (critère C14 de docs/production/go-no-go.md).
-- Les consentements WhatsApp existants sont réutilisés. Les autres canaux restent
-- inéligibles tant qu'une source de consentement propre au canal n'existe pas.

begin;

do $garde$
begin
  if pg_catalog.to_regclass('public.clients') is null
     or pg_catalog.to_regclass('public.colis') is null
     or pg_catalog.to_regclass('public.prealertes') is null
     or pg_catalog.to_regclass('public.communication_consentements_clients') is null
     or pg_catalog.to_regclass('public.communication_contact_suppressions') is null
     or pg_catalog.to_regprocedure('public.communication_consentement_cible(uuid)') is null
     or pg_catalog.to_regprocedure('public.communication_consentement_empreinte(text)') is null
     or pg_catalog.to_regprocedure('public.exiger_permission(text,uuid)') is null then
    raise exception 'COMMUNICATION_C6_DEPENDENCY_MISSING';
  end if;
end
$garde$;

-- C6 ajoute seulement les droits de préparation et d'approbation. Aucun rôle
-- n'obtient de permission de transmission marketing.
create or replace function public.permissions_du_role(p_role text)
returns text[]
language sql
immutable
set search_path = ''
as $fonction$
  select case p_role
    when 'admin' then array[
      'clients.view', 'clients.create', 'clients.edit',
      'shipments.view', 'shipments.create', 'shipments.edit', 'shipments.delete',
      'shipments.scan', 'shipments.change_status', 'shipments.correct', 'shipments.view_history',
      'invoices.view', 'invoices.create', 'invoices.edit', 'invoices.cancel',
      'payments.view', 'payments.create', 'payments.cancel',
      'reports.view', 'reports.create', 'reports.edit', 'reports.delete',
      'users.view', 'roles.manage', 'settings.manage', 'audit_logs.view',
      'birthdays.view', 'birthdays.manage', 'programs.view', 'programs.manage', 'points.adjust',
      'tracking.view', 'tracking.manage', 'communications.view',
      'communications.templates.manage', 'communications.consents.view',
      'communications.queue.retry', 'communications.campaigns.view',
      'communications.campaigns.manage', 'communications.campaigns.approve']
    when 'gerant' then array[
      'clients.view', 'clients.create', 'clients.edit',
      'shipments.view', 'shipments.create', 'shipments.edit',
      'shipments.scan', 'shipments.change_status', 'shipments.correct', 'shipments.view_history',
      'invoices.view', 'invoices.create', 'invoices.edit', 'invoices.cancel',
      'payments.view', 'payments.create', 'payments.cancel',
      'reports.view', 'reports.create', 'users.view',
      'birthdays.view', 'programs.view', 'tracking.view', 'communications.view',
      'communications.campaigns.view', 'communications.campaigns.manage']
    when 'employe' then array[
      'clients.view', 'clients.create',
      'shipments.view', 'shipments.create', 'shipments.edit',
      'shipments.scan', 'shipments.change_status', 'shipments.view_history',
      'invoices.view', 'payments.view', 'tracking.view']
    when 'client' then array[
      'clients.view:own', 'clients.edit:own',
      'shipments.view:own', 'shipments.view_history:own',
      'invoices.view:own', 'payments.view:own']
    else array[]::text[]
  end
$fonction$;

create table if not exists public.communication_campagne_segments_marketing (
  id             bigint generated always as identity primary key,
  nom            text not null check (length(btrim(nom)) between 1 and 120),
  description    text not null default '' check (length(description) <= 500),
  criteres       jsonb not null,
  cree_par       uuid not null references public.clients(id) on delete restrict,
  modifie_par    uuid not null references public.clients(id) on delete restrict,
  cree_le        timestamptz not null default clock_timestamp(),
  maj_le         timestamptz not null default clock_timestamp()
);

create table if not exists public.communication_campagne_modeles_marketing (
  id             bigint generated always as identity primary key,
  cle            text not null check (cle ~ '^[a-z][a-z0-9_-]{1,79}$'),
  canal          text not null check (canal in ('email', 'whatsapp', 'push')),
  version        integer not null check (version > 0),
  traductions    jsonb not null,
  cree_par       uuid not null references public.clients(id) on delete restrict,
  cree_le        timestamptz not null default clock_timestamp(),
  unique (cle, canal, version)
);

create table if not exists public.communication_campagnes_marketing (
  id                            bigint generated always as identity primary key,
  etat                          text not null default 'draft'
                                check (etat in ('draft', 'pending_approval', 'approved',
                                                'scheduled', 'cancelled', 'completed')),
  revision_courante             integer not null default 0 check (revision_courante >= 0),
  revision_courante_id           bigint,
  cree_par                       uuid not null references public.clients(id) on delete restrict,
  modifie_par                    uuid not null references public.clients(id) on delete restrict,
  soumise_par                    uuid references public.clients(id) on delete restrict,
  soumise_le                     timestamptz,
  empreinte_audience_soumise      text,
  approuvee_par                  uuid references public.clients(id) on delete restrict,
  approuvee_le                   timestamptz,
  revision_approuvee_id          bigint,
  empreinte_audience_approuvee    text,
  motif_refus                    text,
  planifiee_pour                 timestamptz,
  fuseau_planification            text,
  cree_le                        timestamptz not null default clock_timestamp(),
  maj_le                         timestamptz not null default clock_timestamp(),
  check ((soumise_le is null) = (soumise_par is null)),
  check ((approuvee_le is null) = (approuvee_par is null)),
  check ((approuvee_le is null) = (revision_approuvee_id is null)),
  check ((approuvee_le is null) = (empreinte_audience_approuvee is null)),
  check ((planifiee_pour is null) = (fuseau_planification is null)),
  check (etat <> 'pending_approval' or (soumise_le is not null and empreinte_audience_soumise is not null)),
  check (etat not in ('approved', 'scheduled') or
         (approuvee_le is not null and approuvee_par is not null
          and revision_approuvee_id is not null and empreinte_audience_approuvee is not null)),
  check (etat <> 'scheduled' or planifiee_pour is not null)
);

create table if not exists public.communication_campagne_revisions_marketing (
  id                         bigint generated always as identity primary key,
  campagne_id                bigint not null references public.communication_campagnes_marketing(id) on delete restrict,
  revision                   integer not null check (revision > 0),
  nom                        text not null check (length(btrim(nom)) between 1 and 160),
  description                text not null default '' check (length(description) <= 1200),
  objectif                   text not null check (length(btrim(objectif)) between 1 and 240),
  canaux                     text[] not null check (cardinality(canaux) between 1 and 3),
  langue                     text not null check (langue in ('fr', 'en', 'es', 'ht')),
  segment_id                 bigint references public.communication_campagne_segments_marketing(id) on delete restrict,
  criteres_audience          jsonb not null,
  modeles                    jsonb not null,
  budget_prevu_usd           numeric(12,2) check (budget_prevu_usd is null or budget_prevu_usd >= 0),
  plafond_depenses_usd        numeric(12,2) check (plafond_depenses_usd is null or plafond_depenses_usd >= 0),
  quotas_par_canal            jsonb,
  volume_cible               integer check (volume_cible is null or volume_cible > 0),
  cout_estime_usd             numeric(12,4) check (cout_estime_usd is null or cout_estime_usd >= 0),
  planifie_local              timestamp without time zone,
  fuseau_horaire              text,
  cree_par                    uuid not null references public.clients(id) on delete restrict,
  cree_le                     timestamptz not null default clock_timestamp(),
  unique (campagne_id, revision),
  check ((planifie_local is null) = (fuseau_horaire is null)),
  check (quotas_par_canal is null or pg_catalog.jsonb_typeof(quotas_par_canal) = 'object')
);

alter table public.communication_campagnes_marketing
  drop constraint if exists communication_campagnes_revision_courante_fk;
alter table public.communication_campagnes_marketing
  add constraint communication_campagnes_revision_courante_fk
  foreign key (revision_courante_id)
  references public.communication_campagne_revisions_marketing(id) on delete restrict;
alter table public.communication_campagnes_marketing
  drop constraint if exists communication_campagnes_revision_approuvee_fk;
alter table public.communication_campagnes_marketing
  add constraint communication_campagnes_revision_approuvee_fk
  foreign key (revision_approuvee_id)
  references public.communication_campagne_revisions_marketing(id) on delete restrict;

create table if not exists public.communication_campagne_evaluations_marketing (
  id                  bigint generated always as identity primary key,
  campagne_id         bigint not null references public.communication_campagnes_marketing(id) on delete restrict,
  revision_id         bigint not null references public.communication_campagne_revisions_marketing(id) on delete restrict,
  total_audience      bigint not null check (total_audience >= 0),
  resultat            jsonb not null,
  empreinte           text not null check (empreinte ~ '^[0-9a-f]{64}$'),
  evalue_par          uuid not null references public.clients(id) on delete restrict,
  evalue_le           timestamptz not null default clock_timestamp()
);

create table if not exists public.communication_campagne_approbations_marketing (
  id                  bigint generated always as identity primary key,
  campagne_id         bigint not null references public.communication_campagnes_marketing(id) on delete restrict,
  revision_id         bigint not null references public.communication_campagne_revisions_marketing(id) on delete restrict,
  action              text not null check (action in ('approved', 'rejected')),
  approbateur         uuid not null references public.clients(id) on delete restrict,
  empreinte_audience  text not null check (empreinte_audience ~ '^[0-9a-f]{64}$'),
  motif_refus         text check (motif_refus is null or length(btrim(motif_refus)) between 1 and 500),
  cree_le             timestamptz not null default clock_timestamp(),
  check ((action = 'rejected') = (motif_refus is not null))
);

create table if not exists public.communication_campagne_audit_marketing (
  id                  bigint generated always as identity primary key,
  campagne_id         bigint references public.communication_campagnes_marketing(id) on delete restrict,
  revision_id         bigint references public.communication_campagne_revisions_marketing(id) on delete restrict,
  segment_id          bigint references public.communication_campagne_segments_marketing(id) on delete restrict,
  modele_id           bigint references public.communication_campagne_modeles_marketing(id) on delete restrict,
  action              text not null check (action in (
                        'created', 'revision_saved', 'revision_duplicated', 'segment_saved',
                        'model_version_created', 'audience_previewed', 'audience_invalidated',
                        'submitted', 'approved', 'rejected', 'scheduled', 'cancelled')),
  acteur              uuid not null references public.clients(id) on delete restrict,
  details             jsonb not null default '{}'::jsonb,
  cree_le             timestamptz not null default clock_timestamp(),
  check (num_nonnulls(campagne_id, segment_id, modele_id) = 1)
);

create index if not exists communication_campagne_revision_idx
  on public.communication_campagne_revisions_marketing (campagne_id, revision desc);
create index if not exists communication_campagne_audit_idx
  on public.communication_campagne_audit_marketing (campagne_id, cree_le desc, id desc);
create index if not exists communication_campagne_evaluations_idx
  on public.communication_campagne_evaluations_marketing (campagne_id, revision_id, evalue_le desc);
create index if not exists communication_campagne_approbations_idx
  on public.communication_campagne_approbations_marketing (campagne_id, revision_id, cree_le desc);

alter table public.communication_campagne_segments_marketing enable row level security;
alter table public.communication_campagne_modeles_marketing enable row level security;
alter table public.communication_campagnes_marketing enable row level security;
alter table public.communication_campagne_revisions_marketing enable row level security;
alter table public.communication_campagne_evaluations_marketing enable row level security;
alter table public.communication_campagne_approbations_marketing enable row level security;
alter table public.communication_campagne_audit_marketing enable row level security;
revoke all on public.communication_campagne_segments_marketing,
  public.communication_campagne_modeles_marketing,
  public.communication_campagnes_marketing,
  public.communication_campagne_revisions_marketing,
  public.communication_campagne_evaluations_marketing,
  public.communication_campagne_approbations_marketing,
  public.communication_campagne_audit_marketing
  from public, anon, authenticated, service_role;

create or replace function public.communication_campagne_immuable()
returns trigger
language plpgsql
set search_path = ''
as $fonction$
begin
  raise exception 'COMMUNICATION_CAMPAIGN_HISTORY_IMMUTABLE' using errcode = '55000';
end
$fonction$;

drop trigger if exists communication_campagne_revisions_immuables
  on public.communication_campagne_revisions_marketing;
create trigger communication_campagne_revisions_immuables
  before update or delete on public.communication_campagne_revisions_marketing
  for each row execute function public.communication_campagne_immuable();
drop trigger if exists communication_campagne_revisions_truncate_interdit
  on public.communication_campagne_revisions_marketing;
create trigger communication_campagne_revisions_truncate_interdit
  before truncate on public.communication_campagne_revisions_marketing
  for each statement execute function public.communication_campagne_immuable();
drop trigger if exists communication_campagne_modeles_immuables
  on public.communication_campagne_modeles_marketing;
create trigger communication_campagne_modeles_immuables
  before update or delete on public.communication_campagne_modeles_marketing
  for each row execute function public.communication_campagne_immuable();
drop trigger if exists communication_campagne_modeles_truncate_interdit
  on public.communication_campagne_modeles_marketing;
create trigger communication_campagne_modeles_truncate_interdit
  before truncate on public.communication_campagne_modeles_marketing
  for each statement execute function public.communication_campagne_immuable();
drop trigger if exists communication_campagne_audit_immuable
  on public.communication_campagne_audit_marketing;
create trigger communication_campagne_audit_immuable
  before update or delete on public.communication_campagne_audit_marketing
  for each row execute function public.communication_campagne_immuable();
drop trigger if exists communication_campagne_audit_truncate_interdit
  on public.communication_campagne_audit_marketing;
create trigger communication_campagne_audit_truncate_interdit
  before truncate on public.communication_campagne_audit_marketing
  for each statement execute function public.communication_campagne_immuable();
drop trigger if exists communication_campagne_evaluations_immuables
  on public.communication_campagne_evaluations_marketing;
create trigger communication_campagne_evaluations_immuables
  before update or delete on public.communication_campagne_evaluations_marketing
  for each row execute function public.communication_campagne_immuable();
drop trigger if exists communication_campagne_evaluations_truncate_interdit
  on public.communication_campagne_evaluations_marketing;
create trigger communication_campagne_evaluations_truncate_interdit
  before truncate on public.communication_campagne_evaluations_marketing
  for each statement execute function public.communication_campagne_immuable();
drop trigger if exists communication_campagne_approbations_immuables
  on public.communication_campagne_approbations_marketing;
create trigger communication_campagne_approbations_immuables
  before update or delete on public.communication_campagne_approbations_marketing
  for each row execute function public.communication_campagne_immuable();
drop trigger if exists communication_campagne_approbations_truncate_interdit
  on public.communication_campagne_approbations_marketing;
create trigger communication_campagne_approbations_truncate_interdit
  before truncate on public.communication_campagne_approbations_marketing
  for each statement execute function public.communication_campagne_immuable();

create or replace function public.communication_campagne_criteres_valider(p_criteres jsonb)
returns boolean
language plpgsql
immutable
security definer
set search_path = ''
as $fonction$
declare
  v_regle jsonb;
  v_champ text;
  v_operateur text;
  v_valeur jsonb;
  v_nb integer;
begin
  if p_criteres is null or pg_catalog.jsonb_typeof(p_criteres) <> 'object'
     or (p_criteres - 'mode' - 'regles') <> '{}'::jsonb
     or p_criteres ->> 'mode' not in ('and', 'or')
     or pg_catalog.jsonb_typeof(p_criteres -> 'regles') <> 'array' then
    raise exception 'COMMUNICATION_SEGMENT_CRITERIA_INVALID';
  end if;
  v_nb := pg_catalog.jsonb_array_length(p_criteres -> 'regles');
  if v_nb < 1 or v_nb > 10 then raise exception 'COMMUNICATION_SEGMENT_CRITERIA_INVALID'; end if;

  for v_regle in select element from pg_catalog.jsonb_array_elements(p_criteres -> 'regles') as x(element)
  loop
    if pg_catalog.jsonb_typeof(v_regle) <> 'object'
       or (v_regle - 'champ' - 'operateur' - 'valeur') <> '{}'::jsonb then
      raise exception 'COMMUNICATION_SEGMENT_CRITERIA_INVALID';
    end if;
    v_champ := v_regle ->> 'champ';
    v_operateur := v_regle ->> 'operateur';
    v_valeur := v_regle -> 'valeur';
    if v_champ is null or v_operateur is null or v_valeur is null then
      raise exception 'COMMUNICATION_SEGMENT_CRITERIA_INVALID';
    end if;

    if v_champ = 'pays' then
      if v_operateur not in ('est', 'n_est_pas') or pg_catalog.jsonb_typeof(v_valeur) <> 'string'
         or v_valeur #>> '{}' not in ('US', 'DO', 'HT') then
        raise exception 'COMMUNICATION_SEGMENT_CRITERIA_INVALID';
      end if;
    elsif v_champ = 'langue' then
      if v_operateur <> 'est' or pg_catalog.jsonb_typeof(v_valeur) <> 'string'
         or v_valeur #>> '{}' not in ('fr', 'en', 'es', 'ht') then
        raise exception 'COMMUNICATION_SEGMENT_CRITERIA_INVALID';
      end if;
    elsif v_champ = 'inscrit_depuis_jours' then
      if v_operateur not in ('au_moins', 'au_plus') or pg_catalog.jsonb_typeof(v_valeur) <> 'number'
         or (v_valeur #>> '{}') !~ '^[0-9]{1,4}$'
         or (v_valeur #>> '{}')::integer not between 0 and 3650 then
        raise exception 'COMMUNICATION_SEGMENT_CRITERIA_INVALID';
      end if;
    elsif v_champ in ('a_des_colis', 'a_des_prealertes') then
      if v_operateur <> 'est' or pg_catalog.jsonb_typeof(v_valeur) <> 'boolean' then
        raise exception 'COMMUNICATION_SEGMENT_CRITERIA_INVALID';
      end if;
    elsif v_champ = 'activite_colis_jours' then
      if v_operateur <> 'dans_les_jours' or pg_catalog.jsonb_typeof(v_valeur) <> 'number'
         or (v_valeur #>> '{}') !~ '^[0-9]{1,4}$'
         or (v_valeur #>> '{}')::integer not between 1 and 3650 then
        raise exception 'COMMUNICATION_SEGMENT_CRITERIA_INVALID';
      end if;
    else
      raise exception 'COMMUNICATION_SEGMENT_CRITERIA_INVALID';
    end if;
  end loop;

  if exists (
    select x.element ->> 'champ'
      from pg_catalog.jsonb_array_elements(p_criteres -> 'regles') as x(element)
     group by x.element ->> 'champ' having count(*) > 1
  ) then
    raise exception 'COMMUNICATION_SEGMENT_CRITERIA_DUPLICATE_FIELD';
  end if;
  return true;
end
$fonction$;

create or replace function public.communication_campagne_critere_correspond(
  p_client uuid, p_criteres jsonb)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare
  v_client public.clients;
  v_regle jsonb;
  v_champ text;
  v_operateur text;
  v_valeur jsonb;
  v_match boolean;
  v_resultat boolean;
  v_mode text := p_criteres ->> 'mode';
begin
  select * into v_client from public.clients c
   where c.id = p_client and c.role = 'client';
  if not found then return false; end if;

  if v_mode = 'and' then v_resultat := true;
  else v_resultat := false;
  end if;

  for v_regle in select element from pg_catalog.jsonb_array_elements(p_criteres -> 'regles') as x(element)
  loop
    v_champ := v_regle ->> 'champ';
    v_operateur := v_regle ->> 'operateur';
    v_valeur := v_regle -> 'valeur';
    v_match := false;

    if v_champ = 'pays' then
      v_match := case v_operateur
        when 'est' then v_client.pays = (v_valeur #>> '{}')
        when 'n_est_pas' then v_client.pays <> (v_valeur #>> '{}')
        else false end;
    elsif v_champ = 'langue' then
      v_match := v_client.langue = (v_valeur #>> '{}');
    elsif v_champ = 'inscrit_depuis_jours' then
      v_match := case v_operateur
        when 'au_moins' then v_client.cree_le <= clock_timestamp() - pg_catalog.make_interval(days => (v_valeur #>> '{}')::integer)
        when 'au_plus' then v_client.cree_le > clock_timestamp() - pg_catalog.make_interval(days => (v_valeur #>> '{}')::integer)
        else false end;
    elsif v_champ = 'a_des_colis' then
      v_match := exists (select 1 from public.colis c where c.client_id = p_client)
                 = (v_valeur #>> '{}')::boolean;
    elsif v_champ = 'a_des_prealertes' then
      v_match := exists (select 1 from public.prealertes p
                          where p.client_id = p_client and p.statut <> 'annulee')
                 = (v_valeur #>> '{}')::boolean;
    elsif v_champ = 'activite_colis_jours' then
      v_match := exists (select 1 from public.colis c
                          where c.client_id = p_client
                            and c.recu_le >= clock_timestamp() - pg_catalog.make_interval(days => (v_valeur #>> '{}')::integer));
    end if;

    if v_mode = 'and' then
      v_resultat := v_resultat and coalesce(v_match, false);
      if not v_resultat then return false; end if;
    else
      v_resultat := v_resultat or coalesce(v_match, false);
      if v_resultat then return true; end if;
    end if;
  end loop;
  return v_resultat;
end
$fonction$;

create or replace function public.communication_campagne_modeles_valider(
  p_canaux text[], p_modeles jsonb)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare
  v_item jsonb;
  v_canal text;
  v_id bigint;
  v_version integer;
  v_total integer;
  v_distincts integer;
begin
  if p_modeles is null or pg_catalog.jsonb_typeof(p_modeles) <> 'array' then
    raise exception 'COMMUNICATION_CAMPAIGN_MODELS_REQUIRED';
  end if;
  select count(*), count(distinct element ->> 'canal')
    into v_total, v_distincts
    from pg_catalog.jsonb_array_elements(p_modeles) as x(element);
  if v_total <> cardinality(p_canaux) or v_distincts <> v_total then
    raise exception 'COMMUNICATION_CAMPAIGN_MODELS_MISMATCH';
  end if;

  for v_item in select element from pg_catalog.jsonb_array_elements(p_modeles) as x(element)
  loop
    if pg_catalog.jsonb_typeof(v_item) <> 'object'
       or (v_item - 'canal' - 'id' - 'version') <> '{}'::jsonb
       or (v_item ->> 'canal') not in ('email', 'whatsapp', 'push')
       or (v_item ->> 'id') !~ '^[0-9]{1,18}$'
       or (v_item ->> 'version') !~ '^[0-9]{1,9}$' then
      raise exception 'COMMUNICATION_CAMPAIGN_MODELS_INVALID';
    end if;
    v_canal := v_item ->> 'canal';
    v_id := (v_item ->> 'id')::bigint;
    v_version := (v_item ->> 'version')::integer;
    if not (v_canal = any(p_canaux)) or not exists (
      select 1 from public.communication_campagne_modeles_marketing m
       where m.id = v_id and m.version = v_version and m.canal = v_canal
    ) then
      raise exception 'COMMUNICATION_CAMPAIGN_MODEL_CHANNEL_MISMATCH';
    end if;
  end loop;

  foreach v_canal in array p_canaux loop
    if (select count(*) from pg_catalog.jsonb_array_elements(p_modeles) as x(element)
         where element ->> 'canal' = v_canal) <> 1 then
      raise exception 'COMMUNICATION_CAMPAIGN_MODELS_MISMATCH';
    end if;
  end loop;
  return true;
end
$fonction$;

create or replace function public.communication_campagne_calculer_audience(p_revision bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare
  v_revision public.communication_campagne_revisions_marketing;
  v_total bigint;
  v_hash_population text;
  v_canal text;
  v_eligible bigint;
  v_motifs jsonb;
  v_hash_eligibles text;
  v_canaux jsonb := '[]'::jsonb;
  v_hash_canaux jsonb := '[]'::jsonb;
  v_empreinte text;
  v_limites_configurees boolean;
  v_alertes_limites jsonb := '[]'::jsonb;
  v_quota bigint;
begin
  select * into v_revision from public.communication_campagne_revisions_marketing r
   where r.id = p_revision;
  if not found then raise exception 'COMMUNICATION_CAMPAIGN_REVISION_NOT_FOUND'; end if;
  perform public.communication_campagne_criteres_valider(v_revision.criteres_audience);
  perform public.communication_campagne_modeles_valider(v_revision.canaux, v_revision.modeles);

  select count(*), encode(extensions.digest(
           coalesce(pg_catalog.string_agg(c.id::text, ',' order by c.id), ''), 'sha256'), 'hex')
    into v_total, v_hash_population
    from public.clients c
   where c.role = 'client'
     and public.communication_campagne_critere_correspond(c.id, v_revision.criteres_audience);

  foreach v_canal in array v_revision.canaux loop
    if v_canal <> 'whatsapp' then
      v_eligible := 0;
      v_motifs := case when v_total = 0 then '{}'::jsonb
        else pg_catalog.jsonb_build_object('consentement_non_verifiable', v_total) end;
      v_hash_eligibles := encode(extensions.digest('', 'sha256'), 'hex');
    else
      with population as materialized (
        select c.id,
               public.communication_consentement_empreinte(
                 public.communication_consentement_cible(c.id)) as empreinte
          from public.clients c
         where c.role = 'client'
           and public.communication_campagne_critere_correspond(c.id, v_revision.criteres_audience)
      ), contacts as materialized (
        select q.empreinte, count(*)::bigint as comptes
          from (
            select public.communication_consentement_empreinte(
                     public.communication_consentement_cible(c.id)) as empreinte
              from public.clients c
             where c.role = 'client'
          ) q
         where q.empreinte is not null
         group by q.empreinte
      ), classes as (
        select p.id,
          case
            when p.empreinte is null then 'contact_non_verifiable'
            when coalesce(cc.comptes, 0) > 1 then 'contact_partage_ambigu'
            when exists (select 1 from public.communication_contact_suppressions s
                          where s.canal = 'whatsapp' and s.cible_empreinte = p.empreinte
                            and s.leve_le is null) then 'suppression_active'
            when consent.id is null then 'sans_consentement'
            when consent.etat = 'retire' then 'consentement_retire'
            when consent.etat = 'expire' then 'consentement_expire'
            when consent.etat <> 'confirme' then 'consentement_non_confirme'
            when consent.cible_empreinte is distinct from p.empreinte then 'contact_modifie'
            when consent.confirme_le is null then 'consentement_invalide'
            else null
          end as motif
          from population p
          left join contacts cc on cc.empreinte = p.empreinte
          left join public.communication_consentements_clients consent
            on consent.client_id = p.id and consent.canal = 'whatsapp'
           and consent.finalite = 'marketing'
      )
      select count(*) filter (where x.motif is null),
             coalesce((select pg_catalog.jsonb_object_agg(r.motif, r.nombre)
                         from (select motif, count(*)::bigint as nombre from classes
                                where motif is not null group by motif) r), '{}'::jsonb),
             encode(extensions.digest(
               coalesce(pg_catalog.string_agg(x.id::text, ',' order by x.id)
                          filter (where x.motif is null), ''), 'sha256'), 'hex')
        into v_eligible, v_motifs, v_hash_eligibles
        from classes x;
    end if;

    v_canaux := v_canaux || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'canal', v_canal, 'total', v_total, 'eligibles', v_eligible,
      'exclus', v_total - v_eligible, 'motifs_exclusion', v_motifs,
      'modele_compatible', true));
    v_hash_canaux := v_hash_canaux || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('canal', v_canal, 'empreinte_eligibles', v_hash_eligibles));
  end loop;

  v_empreinte := encode(extensions.digest(
    v_revision.criteres_audience::text || '|' || v_hash_population || '|' || v_hash_canaux::text,
    'sha256'), 'hex');
  v_limites_configurees := v_revision.budget_prevu_usd is not null
    and v_revision.plafond_depenses_usd is not null
    and v_revision.quotas_par_canal is not null
    and (select count(*) from pg_catalog.jsonb_object_keys(v_revision.quotas_par_canal))
        = cardinality(v_revision.canaux)
    and not exists (
      select 1 from unnest(v_revision.canaux) as x(canal)
       where not (v_revision.quotas_par_canal ? x.canal));

  if v_revision.quotas_par_canal is not null then
    foreach v_canal in array v_revision.canaux loop
      v_quota := nullif(v_revision.quotas_par_canal ->> v_canal, '')::bigint;
      select (x.element ->> 'eligibles')::bigint into v_eligible
        from pg_catalog.jsonb_array_elements(v_canaux) as x(element)
       where x.element ->> 'canal' = v_canal;
      if v_quota is not null and v_eligible > v_quota then
        v_alertes_limites := v_alertes_limites || pg_catalog.jsonb_build_array(
          pg_catalog.jsonb_build_object('type', 'quota_depasse', 'canal', v_canal,
            'eligibles', v_eligible, 'quota', v_quota));
      end if;
    end loop;
  end if;
  if v_revision.cout_estime_usd is not null and v_revision.budget_prevu_usd is not null
     and v_revision.cout_estime_usd > v_revision.budget_prevu_usd then
    v_alertes_limites := v_alertes_limites || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('type', 'budget_prevu_depasse'));
  end if;
  if v_revision.cout_estime_usd is not null and v_revision.plafond_depenses_usd is not null
     and v_revision.cout_estime_usd > v_revision.plafond_depenses_usd then
    v_alertes_limites := v_alertes_limites || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('type', 'plafond_depasse'));
  end if;

  return pg_catalog.jsonb_build_object(
    'total_audience', v_total, 'canaux', v_canaux,
    'alertes_limites', v_alertes_limites,
    'limites_configurees', v_limites_configurees,
    'budget_prevu_usd', v_revision.budget_prevu_usd,
    'plafond_depenses_usd', v_revision.plafond_depenses_usd,
    'cout_estime_usd', v_revision.cout_estime_usd,
    'cout_reel_usd', null, 'cout_reel_disponible', false,
    'transmission_active', false,
    'empreinte_interne', v_empreinte);
end
$fonction$;

create or replace function public.communication_campagne_segment_enregistrer(
  p_id bigint, p_nom text, p_description text, p_criteres jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fonction$
declare
  v_id bigint;
  v_acteur uuid := auth.uid();
begin
  perform public.exiger_permission('communications.campaigns.manage');
  if p_nom is null or length(btrim(p_nom)) not between 1 and 120
     or length(coalesce(p_description, '')) > 500 then
    raise exception 'COMMUNICATION_SEGMENT_INPUT_INVALID';
  end if;
  perform public.communication_campagne_criteres_valider(p_criteres);

  if p_id is null then
    insert into public.communication_campagne_segments_marketing
      (nom, description, criteres, cree_par, modifie_par)
    values (btrim(p_nom), coalesce(p_description, ''), p_criteres, v_acteur, v_acteur)
    returning id into v_id;
  else
    perform 1 from public.communication_campagne_segments_marketing
     where id = p_id for update;
    if not found then raise exception 'COMMUNICATION_SEGMENT_NOT_FOUND'; end if;
    update public.communication_campagne_segments_marketing
       set nom = btrim(p_nom), description = coalesce(p_description, ''),
           criteres = p_criteres, modifie_par = v_acteur, maj_le = clock_timestamp()
     where id = p_id returning id into v_id;
  end if;

  insert into public.communication_campagne_audit_marketing
    (segment_id, action, acteur, details)
  values (v_id, 'segment_saved', v_acteur,
          pg_catalog.jsonb_build_object('criteres', p_criteres));
  return pg_catalog.jsonb_build_object('id', v_id, 'nom', btrim(p_nom));
end
$fonction$;

create or replace function public.communication_campagne_segments_lister()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare v_segments jsonb;
begin
  perform public.exiger_permission('communications.campaigns.manage');
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'id', s.id, 'nom', s.nom, 'description', s.description,
    'criteres', s.criteres, 'cree_le', s.cree_le, 'maj_le', s.maj_le)
    order by s.maj_le desc, s.id desc), '[]'::jsonb)
    into v_segments from public.communication_campagne_segments_marketing s;
  return pg_catalog.jsonb_build_object('segments', v_segments);
end
$fonction$;

create or replace function public.communication_campagne_modele_version_creer(
  p_cle text, p_canal text, p_traductions jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'
as $fonction$
declare
  v_version integer;
  v_id bigint;
  v_ligne record;
  v_titre text;
  v_message text;
  v_langues text[];
  v_acteur uuid := auth.uid();
begin
  perform public.exiger_permission('communications.campaigns.manage');
  if p_cle is null or p_cle !~ '^[a-z][a-z0-9_-]{1,79}$'
     or p_canal not in ('email', 'whatsapp', 'push')
     or p_traductions is null or pg_catalog.jsonb_typeof(p_traductions) <> 'object'
     or (select count(*) from pg_catalog.jsonb_object_keys(p_traductions)) <> 4
     or (p_traductions - 'fr' - 'en' - 'es' - 'ht') <> '{}'::jsonb then
    raise exception 'COMMUNICATION_CAMPAIGN_MODEL_INVALID';
  end if;
  select pg_catalog.array_agg(k.langue order by k.langue)
    into v_langues from pg_catalog.jsonb_object_keys(p_traductions) as k(langue);
  if v_langues is distinct from array['en', 'es', 'fr', 'ht']::text[] then
    raise exception 'COMMUNICATION_CAMPAIGN_MODEL_LANGUAGES_REQUIRED';
  end if;

  for v_ligne in select key as langue, value as contenu
                   from pg_catalog.jsonb_each(p_traductions)
  loop
    if pg_catalog.jsonb_typeof(v_ligne.contenu) <> 'object'
       or (v_ligne.contenu - 'titre' - 'message') <> '{}'::jsonb then
      raise exception 'COMMUNICATION_CAMPAIGN_MODEL_INVALID';
    end if;
    v_titre := v_ligne.contenu ->> 'titre';
    v_message := v_ligne.contenu ->> 'message';
    if v_titre is null or length(v_titre) not between 1 and 300
       or v_message is null or length(v_message) not between 1 and 3000
       or (v_titre || v_message) ~ '<[^>]*>'
       or pg_catalog.strpos(v_titre || v_message, '{{') > 0
       or pg_catalog.strpos(v_titre || v_message, '}}') > 0 then
      raise exception 'COMMUNICATION_CAMPAIGN_MODEL_CONTENT_INVALID';
    end if;
  end loop;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('goship:c6:model:' || p_canal || ':' || p_cle, 0));
  select coalesce(max(m.version), 0) + 1 into v_version
    from public.communication_campagne_modeles_marketing m
   where m.cle = p_cle and m.canal = p_canal;
  insert into public.communication_campagne_modeles_marketing
    (cle, canal, version, traductions, cree_par)
  values (p_cle, p_canal, v_version, p_traductions, v_acteur)
  returning id into v_id;
  insert into public.communication_campagne_audit_marketing
    (modele_id, action, acteur, details)
  values (v_id, 'model_version_created', v_acteur,
          pg_catalog.jsonb_build_object('canal', p_canal, 'version', v_version));
  return pg_catalog.jsonb_build_object('id', v_id, 'cle', p_cle,
    'canal', p_canal, 'version', v_version);
end
$fonction$;

create or replace function public.communication_campagne_modeles_lister(p_canal text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare v_modeles jsonb;
begin
  perform public.exiger_permission('communications.campaigns.manage');
  if p_canal is not null and p_canal not in ('email', 'whatsapp', 'push') then
    raise exception 'COMMUNICATION_CAMPAIGN_CHANNEL_INVALID';
  end if;
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'id', m.id, 'cle', m.cle, 'canal', m.canal, 'version', m.version,
    'traductions', m.traductions, 'cree_le', m.cree_le)
    order by m.cle, m.canal, m.version desc), '[]'::jsonb)
    into v_modeles from public.communication_campagne_modeles_marketing m
   where p_canal is null or m.canal = p_canal;
  return pg_catalog.jsonb_build_object('modeles', v_modeles);
end
$fonction$;

create or replace function public.communication_campagne_enregistrer(
  p_campagne bigint, p_nom text, p_description text, p_objectif text,
  p_canaux text[], p_langue text, p_segment bigint, p_criteres jsonb,
  p_modeles jsonb, p_budget_prevu_usd numeric, p_plafond_depenses_usd numeric,
  p_quotas_par_canal jsonb, p_volume_cible integer, p_cout_estime_usd numeric,
  p_planifie_local timestamp without time zone, p_fuseau_horaire text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'
as $fonction$
declare
  v_acteur uuid := auth.uid();
  v_campagne public.communication_campagnes_marketing;
  v_segment public.communication_campagne_segments_marketing;
  v_criteres jsonb;
  v_id bigint;
  v_revision_id bigint;
  v_revision integer;
  v_canal text;
  v_quota text;
begin
  perform public.exiger_permission('communications.campaigns.manage');
  if p_nom is null or length(btrim(p_nom)) not between 1 and 160
     or length(coalesce(p_description, '')) > 1200
     or p_objectif is null or length(btrim(p_objectif)) not between 1 and 240
     or p_canaux is null or cardinality(p_canaux) not between 1 and 3
     or cardinality(array_remove(p_canaux, null)) <> cardinality(p_canaux)
     or cardinality(p_canaux) <> (select count(distinct x) from unnest(p_canaux) as u(x))
     or not (p_canaux <@ array['email', 'whatsapp', 'push']::text[])
     or p_langue not in ('fr', 'en', 'es', 'ht')
     or p_budget_prevu_usd < 0 or p_plafond_depenses_usd < 0
     or p_volume_cible <= 0 or p_cout_estime_usd < 0 then
    raise exception 'COMMUNICATION_CAMPAIGN_INPUT_INVALID';
  end if;
  if (p_planifie_local is null) <> (p_fuseau_horaire is null) then
    raise exception 'COMMUNICATION_CAMPAIGN_SCHEDULE_TIMEZONE_REQUIRED';
  end if;
  if p_fuseau_horaire is not null and not exists (
    select 1 from pg_catalog.pg_timezone_names z where z.name = p_fuseau_horaire
  ) then
    raise exception 'COMMUNICATION_CAMPAIGN_TIMEZONE_INVALID';
  end if;
  if p_quotas_par_canal is not null then
    if pg_catalog.jsonb_typeof(p_quotas_par_canal) <> 'object'
       or exists (select 1 from pg_catalog.jsonb_object_keys(p_quotas_par_canal) k(canal)
                   where not (k.canal = any(p_canaux))) then
      raise exception 'COMMUNICATION_CAMPAIGN_QUOTA_INVALID';
    end if;
    for v_canal, v_quota in
      select x.canal, x.quota
        from pg_catalog.jsonb_each_text(p_quotas_par_canal) as x(canal, quota)
    loop
      if v_quota !~ '^[0-9]{1,9}$' or v_quota::integer < 1 then
        raise exception 'COMMUNICATION_CAMPAIGN_QUOTA_INVALID';
      end if;
    end loop;
  end if;

  if p_segment is not null then
    select * into v_segment from public.communication_campagne_segments_marketing s
     where s.id = p_segment;
    if not found then raise exception 'COMMUNICATION_SEGMENT_NOT_FOUND'; end if;
    if p_criteres is not null and p_criteres <> v_segment.criteres then
      raise exception 'COMMUNICATION_SEGMENT_SNAPSHOT_MISMATCH';
    end if;
    v_criteres := v_segment.criteres;
  else
    v_criteres := p_criteres;
  end if;
  perform public.communication_campagne_criteres_valider(v_criteres);
  perform public.communication_campagne_modeles_valider(p_canaux, p_modeles);

  if p_campagne is null then
    insert into public.communication_campagnes_marketing (cree_par, modifie_par)
    values (v_acteur, v_acteur) returning id into v_id;
    v_revision := 1;
  else
    select * into v_campagne from public.communication_campagnes_marketing c
     where c.id = p_campagne for update;
    if not found then raise exception 'COMMUNICATION_CAMPAIGN_NOT_FOUND'; end if;
    if v_campagne.etat in ('cancelled', 'completed') then
      raise exception 'COMMUNICATION_CAMPAIGN_TERMINAL_STATE';
    end if;
    v_id := v_campagne.id;
    v_revision := v_campagne.revision_courante + 1;
  end if;

  insert into public.communication_campagne_revisions_marketing
    (campagne_id, revision, nom, description, objectif, canaux, langue,
     segment_id, criteres_audience, modeles, budget_prevu_usd,
     plafond_depenses_usd, quotas_par_canal, volume_cible, cout_estime_usd,
     planifie_local, fuseau_horaire, cree_par)
  values (v_id, v_revision, btrim(p_nom), coalesce(p_description, ''), btrim(p_objectif),
          p_canaux, p_langue, p_segment, v_criteres, p_modeles, p_budget_prevu_usd,
          p_plafond_depenses_usd, p_quotas_par_canal, p_volume_cible, p_cout_estime_usd,
          p_planifie_local, p_fuseau_horaire, v_acteur)
  returning id into v_revision_id;

  if p_campagne is null then
    insert into public.communication_campagne_audit_marketing
      (campagne_id, revision_id, action, acteur, details)
    values (v_id, v_revision_id, 'created', v_acteur, '{}'::jsonb);
  else
    insert into public.communication_campagne_audit_marketing
      (campagne_id, revision_id, action, acteur, details)
    values (v_id, v_revision_id, 'revision_saved', v_acteur,
            pg_catalog.jsonb_build_object('ancienne_revision', v_campagne.revision_courante,
              'ancienne_etat', v_campagne.etat,
              'planification_invalidee', v_campagne.etat = 'scheduled'));
  end if;

  update public.communication_campagnes_marketing
     set etat = 'draft', revision_courante = v_revision,
         revision_courante_id = v_revision_id, modifie_par = v_acteur,
         soumise_par = null, soumise_le = null, empreinte_audience_soumise = null,
         approuvee_par = null, approuvee_le = null, revision_approuvee_id = null,
         empreinte_audience_approuvee = null, motif_refus = null,
         planifiee_pour = null, fuseau_planification = null, maj_le = clock_timestamp()
   where id = v_id;

  return pg_catalog.jsonb_build_object('id', v_id, 'revision_id', v_revision_id,
    'revision', v_revision, 'etat', 'draft');
end
$fonction$;

create or replace function public.communication_campagne_dupliquer(p_campagne bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fonction$
declare
  v_source public.communication_campagne_revisions_marketing;
  v_nouvelle jsonb;
  v_id bigint;
  v_revision_id bigint;
  v_acteur uuid := auth.uid();
begin
  perform public.exiger_permission('communications.campaigns.manage');
  select r.* into v_source
    from public.communication_campagnes_marketing c
    join public.communication_campagne_revisions_marketing r on r.id = c.revision_courante_id
   where c.id = p_campagne;
  if not found then raise exception 'COMMUNICATION_CAMPAIGN_NOT_FOUND'; end if;
  insert into public.communication_campagnes_marketing (cree_par, modifie_par)
  values (v_acteur, v_acteur) returning id into v_id;
  insert into public.communication_campagne_revisions_marketing
    (campagne_id, revision, nom, description, objectif, canaux, langue,
     segment_id, criteres_audience, modeles, budget_prevu_usd,
     plafond_depenses_usd, quotas_par_canal, volume_cible, cout_estime_usd,
     planifie_local, fuseau_horaire, cree_par)
  values (v_id, 1, left(v_source.nom || ' — copie', 160), v_source.description,
          v_source.objectif, v_source.canaux, v_source.langue, v_source.segment_id,
          v_source.criteres_audience, v_source.modeles, v_source.budget_prevu_usd,
          v_source.plafond_depenses_usd, v_source.quotas_par_canal, v_source.volume_cible,
          v_source.cout_estime_usd, null, null, v_acteur)
  returning id into v_revision_id;
  update public.communication_campagnes_marketing
     set revision_courante = 1, revision_courante_id = v_revision_id,
         maj_le = clock_timestamp() where id = v_id;
  insert into public.communication_campagne_audit_marketing
    (campagne_id, revision_id, action, acteur, details)
  values (v_id, v_revision_id, 'revision_duplicated', v_acteur,
          pg_catalog.jsonb_build_object('campagne_source', p_campagne,
            'historique_copie', false, 'transmissions_copiees', false));
  return pg_catalog.jsonb_build_object('id', v_id, 'revision_id', v_revision_id,
    'revision', 1, 'etat', 'draft', 'historique_copie', false,
    'transmissions_copiees', false);
end
$fonction$;

create or replace function public.communication_campagne_apercu(p_campagne bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fonction$
declare
  v_campagne public.communication_campagnes_marketing;
  v_resultat jsonb;
  v_empreinte text;
  v_total bigint;
  v_acteur uuid := auth.uid();
begin
  perform public.exiger_permission('communications.campaigns.manage');
  select * into v_campagne from public.communication_campagnes_marketing c
   where c.id = p_campagne for update;
  if not found or v_campagne.revision_courante_id is null then
    raise exception 'COMMUNICATION_CAMPAIGN_NOT_FOUND';
  end if;
  v_resultat := public.communication_campagne_calculer_audience(v_campagne.revision_courante_id);
  v_empreinte := v_resultat ->> 'empreinte_interne';
  v_total := (v_resultat ->> 'total_audience')::bigint;

  if v_campagne.etat in ('pending_approval', 'approved', 'scheduled')
     and v_campagne.empreinte_audience_soumise is distinct from v_empreinte then
    update public.communication_campagnes_marketing
       set etat = 'draft', soumise_par = null, soumise_le = null,
           empreinte_audience_soumise = null, approuvee_par = null,
           approuvee_le = null, revision_approuvee_id = null,
           empreinte_audience_approuvee = null, planifiee_pour = null,
           fuseau_planification = null, maj_le = clock_timestamp()
     where id = p_campagne;
    insert into public.communication_campagne_audit_marketing
      (campagne_id, revision_id, action, acteur, details)
    values (p_campagne, v_campagne.revision_courante_id, 'audience_invalidated', v_acteur,
            pg_catalog.jsonb_build_object('raison', 'audience_modifiee'));
  end if;

  insert into public.communication_campagne_evaluations_marketing
    (campagne_id, revision_id, total_audience, resultat, empreinte, evalue_par)
  values (p_campagne, v_campagne.revision_courante_id, v_total,
          v_resultat - 'empreinte_interne', v_empreinte, v_acteur);
  insert into public.communication_campagne_audit_marketing
    (campagne_id, revision_id, action, acteur, details)
  values (p_campagne, v_campagne.revision_courante_id, 'audience_previewed', v_acteur,
          pg_catalog.jsonb_build_object('total', v_total,
            'empreinte', left(v_empreinte, 12)));
  return v_resultat - 'empreinte_interne';
end
$fonction$;

create or replace function public.communication_campagnes_lister(p_limite integer default 100)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare v_campagnes jsonb;
begin
  perform public.exiger_permission('communications.campaigns.view');
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'id', c.id, 'etat', c.etat, 'revision', c.revision_courante,
    'revision_id', c.revision_courante_id, 'nom', r.nom, 'description', r.description,
    'objectif', r.objectif, 'canaux', r.canaux, 'langue', r.langue,
    'segment_id', r.segment_id, 'criteres_audience', r.criteres_audience,
    'modeles', r.modeles, 'budget_prevu_usd', r.budget_prevu_usd,
    'plafond_depenses_usd', r.plafond_depenses_usd,
    'quotas_par_canal', r.quotas_par_canal, 'volume_cible', r.volume_cible,
    'cout_estime_usd', r.cout_estime_usd, 'cout_reel_usd', null,
    'limites_configurees', (r.budget_prevu_usd is not null
      and r.plafond_depenses_usd is not null and r.quotas_par_canal is not null
      and (select count(*) from pg_catalog.jsonb_object_keys(r.quotas_par_canal))
          = cardinality(r.canaux)),
    'planifie_local', r.planifie_local, 'fuseau_horaire', r.fuseau_horaire,
    'cree_par', c.cree_par, 'modifie_par', c.modifie_par,
    'soumise_par', c.soumise_par, 'soumise_le', c.soumise_le,
    'approuvee_par', c.approuvee_par, 'approuvee_le', c.approuvee_le,
    'revision_approuvee', c.revision_approuvee_id,
    'motif_refus', c.motif_refus, 'planifiee_pour', c.planifiee_pour,
    'fuseau_planification', c.fuseau_planification,
    'cree_le', c.cree_le, 'maj_le', c.maj_le)
    order by c.maj_le desc, c.id desc), '[]'::jsonb)
    into v_campagnes
    from (select * from public.communication_campagnes_marketing
           order by maj_le desc, id desc limit least(greatest(coalesce(p_limite, 100), 1), 200)) c
    left join public.communication_campagne_revisions_marketing r
      on r.id = c.revision_courante_id;
  return pg_catalog.jsonb_build_object('campagnes', v_campagnes,
    'transmission_active', false, 'cout_reel_disponible', false);
end
$fonction$;

create or replace function public.communication_campagne_soumettre(p_campagne bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'
as $fonction$
declare
  v_campagne public.communication_campagnes_marketing;
  v_evaluation public.communication_campagne_evaluations_marketing;
  v_empreinte text;
  v_acteur uuid := auth.uid();
begin
  perform public.exiger_permission('communications.campaigns.manage');
  select * into v_campagne from public.communication_campagnes_marketing c
   where c.id = p_campagne for update;
  if not found then raise exception 'COMMUNICATION_CAMPAIGN_NOT_FOUND'; end if;
  if v_campagne.etat <> 'draft' then raise exception 'COMMUNICATION_CAMPAIGN_STATE_INVALID'; end if;
  select * into v_evaluation from public.communication_campagne_evaluations_marketing e
   where e.revision_id = v_campagne.revision_courante_id
   order by e.evalue_le desc, e.id desc limit 1;
  if not found then raise exception 'COMMUNICATION_CAMPAIGN_PREVIEW_REQUIRED'; end if;
  v_empreinte := public.communication_campagne_calculer_audience(v_campagne.revision_courante_id)
                   ->> 'empreinte_interne';
  if v_evaluation.empreinte is distinct from v_empreinte then
    raise exception 'COMMUNICATION_CAMPAIGN_AUDIENCE_CHANGED';
  end if;
  update public.communication_campagnes_marketing
     set etat = 'pending_approval', soumise_par = v_acteur,
         soumise_le = clock_timestamp(), empreinte_audience_soumise = v_empreinte,
         motif_refus = null, maj_le = clock_timestamp()
   where id = p_campagne;
  insert into public.communication_campagne_audit_marketing
    (campagne_id, revision_id, action, acteur, details)
  values (p_campagne, v_campagne.revision_courante_id, 'submitted', v_acteur,
          pg_catalog.jsonb_build_object('empreinte_audience', left(v_empreinte, 12)));
  return pg_catalog.jsonb_build_object('id', p_campagne,
    'revision', v_campagne.revision_courante, 'etat', 'pending_approval');
end
$fonction$;

create or replace function public.communication_campagne_approuver(p_campagne bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'
as $fonction$
declare
  v_campagne public.communication_campagnes_marketing;
  v_empreinte text;
  v_acteur uuid := auth.uid();
begin
  perform public.exiger_permission('communications.campaigns.approve');
  select * into v_campagne from public.communication_campagnes_marketing c
   where c.id = p_campagne for update;
  if not found then raise exception 'COMMUNICATION_CAMPAIGN_NOT_FOUND'; end if;
  if v_campagne.etat <> 'pending_approval' then
    raise exception 'COMMUNICATION_CAMPAIGN_STATE_INVALID';
  end if;
  v_empreinte := public.communication_campagne_calculer_audience(v_campagne.revision_courante_id)
                   ->> 'empreinte_interne';
  if v_campagne.empreinte_audience_soumise is distinct from v_empreinte then
    raise exception 'COMMUNICATION_CAMPAIGN_AUDIENCE_CHANGED';
  end if;
  update public.communication_campagnes_marketing
     set etat = 'approved', approuvee_par = v_acteur,
         approuvee_le = clock_timestamp(), revision_approuvee_id = revision_courante_id,
         empreinte_audience_approuvee = v_empreinte, motif_refus = null,
         maj_le = clock_timestamp()
   where id = p_campagne;
  insert into public.communication_campagne_approbations_marketing
    (campagne_id, revision_id, action, approbateur, empreinte_audience)
  values (p_campagne, v_campagne.revision_courante_id, 'approved', v_acteur, v_empreinte);
  insert into public.communication_campagne_audit_marketing
    (campagne_id, revision_id, action, acteur, details)
  values (p_campagne, v_campagne.revision_courante_id, 'approved', v_acteur,
          pg_catalog.jsonb_build_object('empreinte_audience', left(v_empreinte, 12)));
  return pg_catalog.jsonb_build_object('id', p_campagne,
    'revision', v_campagne.revision_courante, 'etat', 'approved');
end
$fonction$;

create or replace function public.communication_campagne_refuser(p_campagne bigint, p_motif text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'
as $fonction$
declare
  v_campagne public.communication_campagnes_marketing;
  v_empreinte text;
  v_acteur uuid := auth.uid();
begin
  perform public.exiger_permission('communications.campaigns.approve');
  select * into v_campagne from public.communication_campagnes_marketing c
   where c.id = p_campagne for update;
  if not found then raise exception 'COMMUNICATION_CAMPAIGN_NOT_FOUND'; end if;
  if v_campagne.etat <> 'pending_approval' then
    raise exception 'COMMUNICATION_CAMPAIGN_STATE_INVALID';
  end if;
  if p_motif is null or length(btrim(p_motif)) not between 1 and 500 then
    raise exception 'COMMUNICATION_CAMPAIGN_REJECTION_REASON_REQUIRED';
  end if;
  v_empreinte := coalesce(v_campagne.empreinte_audience_soumise,
    encode(extensions.digest('', 'sha256'), 'hex'));
  insert into public.communication_campagne_approbations_marketing
    (campagne_id, revision_id, action, approbateur, empreinte_audience, motif_refus)
  values (p_campagne, v_campagne.revision_courante_id, 'rejected', v_acteur,
          v_empreinte, btrim(p_motif));
  update public.communication_campagnes_marketing
     set etat = 'draft', motif_refus = btrim(p_motif),
         soumise_par = null, soumise_le = null, empreinte_audience_soumise = null,
         maj_le = clock_timestamp()
   where id = p_campagne;
  insert into public.communication_campagne_audit_marketing
    (campagne_id, revision_id, action, acteur, details)
  values (p_campagne, v_campagne.revision_courante_id, 'rejected', v_acteur,
          pg_catalog.jsonb_build_object('decision', 'rejected'));
  return pg_catalog.jsonb_build_object('id', p_campagne,
    'revision', v_campagne.revision_courante, 'etat', 'draft', 'motif_refus', btrim(p_motif));
end
$fonction$;

create or replace function public.communication_campagne_planifier(p_campagne bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'
as $fonction$
declare
  v_campagne public.communication_campagnes_marketing;
  v_revision public.communication_campagne_revisions_marketing;
  v_audience jsonb;
  v_horaire timestamptz;
  v_empreinte text;
  v_limite_bloquante boolean;
  v_acteur uuid := auth.uid();
begin
  perform public.exiger_permission('communications.campaigns.approve');
  select * into v_campagne from public.communication_campagnes_marketing c
   where c.id = p_campagne for update;
  if not found then raise exception 'COMMUNICATION_CAMPAIGN_NOT_FOUND'; end if;
  if v_campagne.etat = 'scheduled' then raise exception 'COMMUNICATION_CAMPAIGN_ALREADY_SCHEDULED'; end if;
  if v_campagne.etat <> 'approved'
     or v_campagne.revision_approuvee_id is distinct from v_campagne.revision_courante_id then
    raise exception 'COMMUNICATION_CAMPAIGN_APPROVAL_REQUIRED';
  end if;
  select * into v_revision from public.communication_campagne_revisions_marketing r
   where r.id = v_campagne.revision_courante_id;
  if v_revision.planifie_local is null or v_revision.fuseau_horaire is null then
    raise exception 'COMMUNICATION_CAMPAIGN_SCHEDULE_REQUIRED';
  end if;
  if not (v_revision.budget_prevu_usd is not null
          and v_revision.plafond_depenses_usd is not null
          and v_revision.quotas_par_canal is not null
          and (select count(*) from pg_catalog.jsonb_object_keys(v_revision.quotas_par_canal))
              = cardinality(v_revision.canaux)
          and not exists (
            select 1 from unnest(v_revision.canaux) as x(canal)
             where not (v_revision.quotas_par_canal ? x.canal)
          )) then
    raise exception 'COMMUNICATION_CAMPAIGN_LIMITS_REQUIRED';
  end if;
  if not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = v_revision.fuseau_horaire) then
    raise exception 'COMMUNICATION_CAMPAIGN_TIMEZONE_INVALID';
  end if;
  v_horaire := v_revision.planifie_local at time zone v_revision.fuseau_horaire;
  if v_horaire <= clock_timestamp() then raise exception 'COMMUNICATION_CAMPAIGN_SCHEDULE_PAST'; end if;
  v_audience := public.communication_campagne_calculer_audience(v_revision.id);
  v_empreinte := v_audience ->> 'empreinte_interne';
  if v_empreinte is distinct from v_campagne.empreinte_audience_approuvee then
    raise exception 'COMMUNICATION_CAMPAIGN_AUDIENCE_CHANGED';
  end if;
  select exists (
    select 1 from pg_catalog.jsonb_array_elements(v_audience -> 'alertes_limites') as x(element)
     where x.element ->> 'type' in ('quota_depasse', 'plafond_depasse')
  ) into v_limite_bloquante;
  if v_limite_bloquante then
    raise exception 'COMMUNICATION_CAMPAIGN_LIMIT_EXCEEDED';
  end if;
  update public.communication_campagnes_marketing
     set etat = 'scheduled', planifiee_pour = v_horaire,
         fuseau_planification = v_revision.fuseau_horaire, maj_le = clock_timestamp()
   where id = p_campagne;
  insert into public.communication_campagne_audit_marketing
    (campagne_id, revision_id, action, acteur, details)
  values (p_campagne, v_revision.id, 'scheduled', v_acteur,
          pg_catalog.jsonb_build_object('planifiee_pour', v_horaire,
            'fuseau', v_revision.fuseau_horaire,
            'transmission_active', false));
  return pg_catalog.jsonb_build_object('id', p_campagne, 'etat', 'scheduled',
    'planifiee_pour', v_horaire, 'fuseau_horaire', v_revision.fuseau_horaire,
    'transmission_active', false);
end
$fonction$;

create or replace function public.communication_campagne_annuler(p_campagne bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'
as $fonction$
declare
  v_campagne public.communication_campagnes_marketing;
  v_acteur uuid := auth.uid();
begin
  perform public.exiger_permission('communications.campaigns.approve');
  select * into v_campagne from public.communication_campagnes_marketing c
   where c.id = p_campagne for update;
  if not found then raise exception 'COMMUNICATION_CAMPAIGN_NOT_FOUND'; end if;
  if v_campagne.etat in ('cancelled', 'completed') then
    raise exception 'COMMUNICATION_CAMPAIGN_TERMINAL_STATE';
  end if;
  update public.communication_campagnes_marketing
     set etat = 'cancelled', maj_le = clock_timestamp()
   where id = p_campagne;
  insert into public.communication_campagne_audit_marketing
    (campagne_id, revision_id, action, acteur, details)
  values (p_campagne, v_campagne.revision_courante_id, 'cancelled', v_acteur,
          pg_catalog.jsonb_build_object('etat_precedent', v_campagne.etat));
  return pg_catalog.jsonb_build_object('id', p_campagne, 'etat', 'cancelled');
end
$fonction$;

create or replace function public.communication_campagne_journal(p_campagne bigint, p_limite integer default 100)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare v_lignes jsonb;
begin
  perform public.exiger_permission('communications.campaigns.view');
  if not exists (select 1 from public.communication_campagnes_marketing c where c.id = p_campagne) then
    raise exception 'COMMUNICATION_CAMPAIGN_NOT_FOUND';
  end if;
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'action', a.action, 'revision_id', a.revision_id, 'acteur', a.acteur,
    'cree_le', a.cree_le, 'details', a.details,
    'motif_refus', (select x.motif_refus
       from public.communication_campagne_approbations_marketing x
      where x.campagne_id = a.campagne_id and x.revision_id = a.revision_id
        and x.action = 'rejected' order by x.id desc limit 1))
    order by a.cree_le desc, a.id desc), '[]'::jsonb)
    into v_lignes from (
      select * from public.communication_campagne_audit_marketing a
       where a.campagne_id = p_campagne
       order by a.cree_le desc, a.id desc
       limit least(greatest(coalesce(p_limite, 100), 1), 200)
    ) a;
  return pg_catalog.jsonb_build_object('lignes', v_lignes);
end
$fonction$;

-- Aucun RPC de transmission ou worker marketing n'est défini dans C6.
-- Les tables restent privées : toutes les écritures passent par les RPC contrôlés.
revoke all on function public.communication_campagne_immuable(),
  public.communication_campagne_criteres_valider(jsonb),
  public.communication_campagne_critere_correspond(uuid,jsonb),
  public.communication_campagne_modeles_valider(text[],jsonb),
  public.communication_campagne_calculer_audience(bigint),
  public.communication_campagne_segment_enregistrer(bigint,text,text,jsonb),
  public.communication_campagne_segments_lister(),
  public.communication_campagne_modele_version_creer(text,text,jsonb),
  public.communication_campagne_modeles_lister(text),
  public.communication_campagne_enregistrer(bigint,text,text,text,text[],text,bigint,jsonb,jsonb,numeric,numeric,jsonb,integer,numeric,timestamp without time zone,text),
  public.communication_campagne_dupliquer(bigint),
  public.communication_campagne_apercu(bigint),
  public.communication_campagnes_lister(integer),
  public.communication_campagne_soumettre(bigint),
  public.communication_campagne_approuver(bigint),
  public.communication_campagne_refuser(bigint,text),
  public.communication_campagne_planifier(bigint),
  public.communication_campagne_annuler(bigint),
  public.communication_campagne_journal(bigint,integer)
  from public, anon, service_role;
grant execute on function public.communication_campagne_segment_enregistrer(bigint,text,text,jsonb),
  public.communication_campagne_segments_lister(),
  public.communication_campagne_modele_version_creer(text,text,jsonb),
  public.communication_campagne_modeles_lister(text),
  public.communication_campagne_enregistrer(bigint,text,text,text,text[],text,bigint,jsonb,jsonb,numeric,numeric,jsonb,integer,numeric,timestamp without time zone,text),
  public.communication_campagne_dupliquer(bigint),
  public.communication_campagne_apercu(bigint),
  public.communication_campagnes_lister(integer),
  public.communication_campagne_soumettre(bigint),
  public.communication_campagne_approuver(bigint),
  public.communication_campagne_refuser(bigint,text),
  public.communication_campagne_planifier(bigint),
  public.communication_campagne_annuler(bigint),
  public.communication_campagne_journal(bigint,integer)
  to authenticated;

do $sequences$
declare v_nom text;
begin
  foreach v_nom in array array[
    pg_catalog.pg_get_serial_sequence('public.communication_campagne_segments_marketing', 'id'),
    pg_catalog.pg_get_serial_sequence('public.communication_campagne_modeles_marketing', 'id'),
    pg_catalog.pg_get_serial_sequence('public.communication_campagnes_marketing', 'id'),
    pg_catalog.pg_get_serial_sequence('public.communication_campagne_revisions_marketing', 'id'),
    pg_catalog.pg_get_serial_sequence('public.communication_campagne_evaluations_marketing', 'id'),
    pg_catalog.pg_get_serial_sequence('public.communication_campagne_approbations_marketing', 'id'),
    pg_catalog.pg_get_serial_sequence('public.communication_campagne_audit_marketing', 'id')
  ] loop
    if v_nom is not null then
      execute pg_catalog.format('revoke all on sequence %s from public, anon, authenticated, service_role', v_nom);
    end if;
  end loop;
end
$sequences$;

commit;
