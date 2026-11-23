-- CANDIDATE LOCALE — Communication Center.
-- Hors de outils/migrations.txt. Ne pas appliquer à une base distante.
-- Dépend de la chaîne officielle actuelle et de ses rôles Supabase.
-- Cette candidate isole des structures durables sans exécuter les drafts 40–43.

begin;

create table if not exists public.communication_arret (
  id                       boolean primary key default true check (id),
  etat                     text not null default 'actif'
                           check (etat in ('actif', 'arret_demande', 'arret_confirme')),
  demande_le               timestamptz,
  demande_par              uuid,
  derniere_demande_le      timestamptz,
  motif                    text check (motif is null or length(motif) between 5 and 300),
  autorisations_closes_le  timestamptz,
  confirme_le              timestamptz,
  tentatives               integer not null default 0 check (tentatives >= 0),
  derniere_tentative_le    timestamptz,
  derniere_raison          text,
  leve_le                  timestamptz,
  leve_par                 uuid,
  motif_levee              text check (motif_levee is null or length(motif_levee) between 10 and 300),
  maj_le                   timestamptz not null default now(),
  version                  bigint not null default 0 check (version >= 0),
  check (etat = 'actif' or (demande_le is not null and motif is not null)),
  check (etat <> 'actif' or (autorisations_closes_le is null and confirme_le is null)),
  check (etat <> 'arret_confirme' or
         (autorisations_closes_le is not null and confirme_le is not null
          and confirme_le >= autorisations_closes_le
          and autorisations_closes_le >= demande_le))
);

insert into public.communication_arret (id)
values (true)
on conflict (id) do nothing;

-- N0 : verrou consultatif de transaction partagé par la porte de sortie et
-- exclusif par la confirmation d'arrêt. L'ordre reste N0 puis N0a (la ligne
-- communication_arret) ; la demande prend N0a seule et ne peut donc pas
-- attendre une transmission déjà autorisée.
create or replace function public.communication_verrou_interrupteurs(p_exclusif boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $fonction$
begin
  if p_exclusif then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('goship-communication:interrupteurs', 0));
  else
    perform pg_catalog.pg_advisory_xact_lock_shared(
      pg_catalog.hashtextextended('goship-communication:interrupteurs', 0));
  end if;
end;
$fonction$;

-- Porte unique des sorties du travailleur transactionnel. La lecture de l'état
-- vient après N0 et exige READ COMMITTED pour observer toute demande déjà
-- validée. Le verrou partagé reste détenu jusqu'au COMMIT de la transmission.
create or replace function public.communication_autoriser_sortie(p_nature text, p_canal text)
returns text
language plpgsql
security definer
set search_path = ''
as $fonction$
declare
  v_etat text;
begin
  if pg_catalog.current_setting('transaction_isolation') <> 'read committed' then
    raise exception 'ISOLATION_NON_SUPPORTEE' using errcode = '25001';
  end if;

  -- Une transaction ne peut autoriser qu'une seule transmission. Le wrapper
  -- consomme le marqueur avant l'appel à l'adaptateur historique ; cela évite
  -- qu'un second appel interne réutilise une autorisation encore présente.
  if coalesce(pg_catalog.current_setting('goship.sortie_consommee', true), '') =
     pg_catalog.txid_current()::text then
    return 'SORTIE_DEJA_CONSOMMEE';
  end if;

  perform public.communication_verrou_interrupteurs(false); -- N0 partagé.
  select a.etat into v_etat
    from public.communication_arret a
   where a.id is true;
  if not found then
    return 'ARRET_INDISPONIBLE';
  end if;
  if v_etat is distinct from 'actif' then
    return 'ARRET_URGENCE';
  end if;
  if p_nature is distinct from 'envoi' then
    return 'NATURE_NON_AUTORISEE';
  end if;
  if p_canal is null or p_canal not in ('push', 'email', 'whatsapp') then
    return 'CANAL_NON_AUTORISE';
  end if;

  perform pg_catalog.set_config(
    'goship.sortie_autorisee',
    pg_catalog.txid_current()::text || ':' || p_nature || ':' || p_canal,
    true);
  return null;
end;
$fonction$;

-- La fonction d'adaptation ne transmet que dans la transaction qui a obtenu
-- l'autorisation explicite pour ce canal.
create or replace function public.communication_sortie_autorisee(p_nature text, p_canal text)
returns boolean
language sql
volatile
set search_path = ''
as $fonction$
  select coalesce(pg_catalog.current_setting('goship.sortie_autorisee', true), '') =
         pg_catalog.txid_current()::text || ':' || p_nature || ':' || p_canal
     and coalesce(pg_catalog.current_setting('goship.sortie_consommee', true), '') <>
         pg_catalog.txid_current()::text
$fonction$;

-- Demande durable dans un appel distinct de la confirmation. Le client doit
-- attendre le COMMIT de cet appel avant de lancer le constat.
create or replace function public.communication_demander_arret(p_motif text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fonction$
declare
  a public.communication_arret;
  v_trouve boolean;
  v_maintenant timestamptz := pg_catalog.clock_timestamp();
begin
  if pg_catalog.length(pg_catalog.btrim(coalesce(p_motif, ''))) < 5 then
    raise exception 'REASON_REQUIRED' using errcode = '22023';
  end if;
  perform pg_catalog.set_config('synchronous_commit', 'on', true);
  perform pg_catalog.set_config('lock_timeout', '5s', true);

  begin
    select * into a from public.communication_arret where id is true for update;
    v_trouve := found;
  exception when lock_not_available then
    return pg_catalog.jsonb_build_object('etat', 'STOP_NOT_CONFIRMED',
      'raison', 'ARRET_CONCURRENT_EN_COURS');
  end;
  if not v_trouve then
    raise exception 'ARRET_LIGNE_ABSENTE';
  end if;

  if a.etat = 'actif' then
    update public.communication_arret
       set etat = 'arret_demande',
           demande_le = v_maintenant,
           demande_par = auth.uid(),
           derniere_demande_le = v_maintenant,
           motif = pg_catalog.left(pg_catalog.btrim(p_motif), 300),
           autorisations_closes_le = null,
           confirme_le = null,
           tentatives = 0,
           derniere_tentative_le = null,
           derniere_raison = null,
           leve_le = null,
           leve_par = null,
           motif_levee = null,
           version = version + 1,
           maj_le = v_maintenant
     where id is true;
  else
    update public.communication_arret
       set derniere_demande_le = v_maintenant,
           version = version + 1,
           maj_le = v_maintenant
     where id is true;
  end if;

  return pg_catalog.jsonb_build_object(
    'etat', case when a.etat = 'arret_confirme' then 'STOP_CONFIRMED' else 'STOP_REQUESTED' end,
    'version', (select version from public.communication_arret where id is true),
    'suite', 'communication_confirmer_arret');
end;
$fonction$;

-- Confirmation distincte : N0 exclusif, puis N0a. Une autorisation déjà
-- validée conserve N0 partagé jusqu'à son COMMIT. Après fermeture, les envois
-- en attente restent en file mais sont refusés par la porte. Les états envoi
-- et incertain ne sont pas déclarés terminés : une réponse tardive reste
-- possible, et le système attend une résolution avant STOP_CONFIRMED.
create or replace function public.communication_confirmer_arret()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fonction$
declare
  a public.communication_arret;
  v_trouve boolean;
  v_closes timestamptz;
  v_transmissions bigint;
begin
  if pg_catalog.current_setting('transaction_isolation') <> 'read committed' then
    raise exception 'ISOLATION_NON_SUPPORTEE' using errcode = '25001';
  end if;
  perform pg_catalog.set_config('synchronous_commit', 'on', true);
  perform pg_catalog.set_config('lock_timeout', '3s', true);

  begin
    perform public.communication_verrou_interrupteurs(true); -- N0 exclusif.
  exception when lock_not_available then
    return pg_catalog.jsonb_build_object('etat', 'STOP_PENDING',
      'raison', 'VERROU_NON_OBTENU');
  end;

  perform pg_catalog.set_config('lock_timeout', '2s', true);
  begin
    select * into a from public.communication_arret where id is true for update;
    v_trouve := found;
  exception when lock_not_available then
    return pg_catalog.jsonb_build_object('etat', 'STOP_PENDING',
      'raison', 'ARRET_CONCURRENT_EN_COURS');
  end;
  if not v_trouve then
    raise exception 'ARRET_LIGNE_ABSENTE';
  end if;
  if a.etat = 'actif' then
    return pg_catalog.jsonb_build_object('etat', 'STOP_NOT_REQUESTED', 'version', a.version);
  end if;
  if a.etat = 'arret_confirme' then
    return pg_catalog.jsonb_build_object('etat', 'STOP_CONFIRMED',
      'confirme_le', a.confirme_le, 'version', a.version);
  end if;

  v_closes := a.autorisations_closes_le;
  if v_closes is null then
    v_closes := greatest(pg_catalog.clock_timestamp(), a.demande_le);
    update public.communication_arret
       set autorisations_closes_le = v_closes,
           version = version + 1,
           maj_le = pg_catalog.clock_timestamp()
     where id is true;
  end if;

  if pg_catalog.to_regclass('public.notification_envois') is null then
    update public.communication_arret
       set tentatives = tentatives + 1,
           derniere_tentative_le = pg_catalog.clock_timestamp(),
           derniere_raison = 'OUTBOX_INDISPONIBLE',
           maj_le = pg_catalog.clock_timestamp()
     where id is true;
    return pg_catalog.jsonb_build_object('etat', 'STOP_PENDING',
      'raison', 'OUTBOX_INDISPONIBLE', 'demande_le', a.demande_le);
  end if;

  execute 'select count(*) from public.notification_envois where statut in (''envoi'', ''incertain'')'
     into v_transmissions;
  if v_transmissions > 0 then
    update public.communication_arret
       set tentatives = tentatives + 1,
           derniere_tentative_le = pg_catalog.clock_timestamp(),
           derniere_raison = 'TRANSMISSIONS_EN_COURS',
           maj_le = pg_catalog.clock_timestamp()
     where id is true;
    return pg_catalog.jsonb_build_object('etat', 'STOP_PENDING',
      'raison', 'TRANSMISSIONS_EN_COURS',
      'transmissions_en_cours', v_transmissions, 'demande_le', a.demande_le);
  end if;

  update public.communication_arret
     set etat = 'arret_confirme',
         confirme_le = greatest(pg_catalog.clock_timestamp(), v_closes),
         tentatives = tentatives + 1,
         derniere_tentative_le = pg_catalog.clock_timestamp(),
         derniere_raison = null,
         version = version + 1,
         maj_le = pg_catalog.clock_timestamp()
   where id is true;
  return pg_catalog.jsonb_build_object(
    'etat', 'STOP_CONFIRMED',
    'confirme_le', (select confirme_le from public.communication_arret where id is true),
    'version', (select version from public.communication_arret where id is true));
end;
$fonction$;

create table if not exists public.communication_evenements_fournisseur (
  id             bigint generated always as identity primary key,
  fournisseur    text not null check (fournisseur in ('meta', 'brevo', 'resend')),
  evenement_id   text not null,
  type           text not null,
  message_id     text,
  reference      text,
  envoi_id       bigint,
  code           text,
  survenu_le     timestamptz,
  recu_le        timestamptz not null default now(),
  unique (fournisseur, evenement_id)
);

create index if not exists communication_evenements_envoi_idx
  on public.communication_evenements_fournisseur (envoi_id)
  where envoi_id is not null;

create table if not exists public.communication_evenements_traitement (
  evenement_id      bigint primary key
                    references public.communication_evenements_fournisseur (id) on delete restrict,
  etat              text not null default 'a_traiter'
                    check (etat in ('a_traiter', 'traite', 'echec')),
  priorite          smallint not null default 2 check (priorite in (1, 2)),
  classe            text check (classe is null or classe in ('stop', 'confirmation', 'ambigu', 'autre')),
  cible_empreinte   text,
  code_confirmation text check (code_confirmation is null or code_confirmation ~ '^[0-9]{6}$'),
  tentatives        integer not null default 0 check (tentatives >= 0),
  prochain_essai_le timestamptz not null default now(),
  dernier_code      text,
  resultat          text,
  cree_le           timestamptz not null default now(),
  traite_le         timestamptz,
  check (etat <> 'traite' or (cible_empreinte is null and code_confirmation is null))
);

create index if not exists communication_evenements_a_traiter_idx
  on public.communication_evenements_traitement (priorite, evenement_id)
  where etat = 'a_traiter';
create index if not exists communication_evenements_echec_idx
  on public.communication_evenements_traitement (priorite)
  where etat = 'echec';

create or replace function public.communication_candidate_proteger_arret()
returns trigger
language plpgsql
set search_path = ''
as $fonction$
begin
  raise exception 'COMMUNICATION_STOP_STATE_REQUIRED' using errcode = '55000';
end;
$fonction$;

create or replace function public.communication_candidate_immuable_evenement()
returns trigger
language plpgsql
set search_path = ''
as $fonction$
begin
  raise exception 'COMMUNICATION_EVENT_IMMUTABLE' using errcode = '55000';
end;
$fonction$;

drop trigger if exists communication_arret_permanent on public.communication_arret;
create trigger communication_arret_permanent
  before delete or truncate on public.communication_arret
  for each statement execute function public.communication_candidate_proteger_arret();

drop trigger if exists communication_evenements_immuables on public.communication_evenements_fournisseur;
create trigger communication_evenements_immuables
  before update or delete on public.communication_evenements_fournisseur
  for each row execute function public.communication_candidate_immuable_evenement();
drop trigger if exists communication_evenements_truncate_interdit on public.communication_evenements_fournisseur;
create trigger communication_evenements_truncate_interdit
  before truncate on public.communication_evenements_fournisseur
  for each statement execute function public.communication_candidate_immuable_evenement();

alter table public.communication_arret enable row level security;
alter table public.communication_evenements_fournisseur enable row level security;
alter table public.communication_evenements_traitement enable row level security;

revoke all on table public.communication_arret,
  public.communication_evenements_fournisseur,
  public.communication_evenements_traitement
  from public, anon, authenticated, service_role;
revoke all on function public.communication_candidate_proteger_arret(),
  public.communication_candidate_immuable_evenement()
  from public, anon, authenticated, service_role;
revoke all on function public.communication_verrou_interrupteurs(boolean),
  public.communication_autoriser_sortie(text, text),
  public.communication_sortie_autorisee(text, text),
  public.communication_demander_arret(text),
  public.communication_confirmer_arret()
  from public, anon, authenticated, service_role;
grant execute on function public.communication_demander_arret(text),
  public.communication_confirmer_arret() to service_role;

do $sequences$
declare
  v_sequence text;
begin
  foreach v_sequence in array array[
    pg_catalog.pg_get_serial_sequence('public.communication_evenements_fournisseur', 'id')
  ] loop
    if v_sequence is not null then
      execute pg_catalog.format(
        'revoke all on sequence %s from public, anon, authenticated, service_role',
        v_sequence);
    end if;
  end loop;
end;
$sequences$;

commit;
