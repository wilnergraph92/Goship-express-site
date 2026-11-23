-- CANDIDATE LOCALE — consentement marketing et confirmation WhatsApp.
-- En fin de outils/migrations.txt depuis le 23/11/2026 (étape C11) : essais locaux et CI
-- seulement. Ne pas appliquer à une base distante (critère C14 de docs/production/go-no-go.md).
-- Dépend des migrations officielles (clients, auth.uid, lire_reglage,
-- telephone_international, pgcrypto dans extensions, Vault) et des candidates 001–002.
-- Les choix CEO encore ouverts n'ont volontairement aucune valeur par défaut.

begin;

create extension if not exists pgcrypto with schema extensions;

do $garde$
begin
  if to_regclass('public.clients') is null
     or to_regprocedure('auth.uid()') is null
     or to_regprocedure('public.lire_reglage(text)') is null
     or to_regprocedure('public.telephone_international(text,text)') is null
     or to_regprocedure('extensions.gen_random_bytes(integer)') is null
     or to_regprocedure('extensions.digest(text,text)') is null
     or to_regclass('vault.secrets') is null
     or to_regclass('vault.decrypted_secrets') is null
     or not exists (
       select 1
       from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'vault'
         and p.proname = 'create_secret'
         and p.proargtypes[0] = 'text'::regtype
         and p.proargtypes[1] = 'text'::regtype
         and p.pronargdefaults >= p.pronargs - 2
     ) then
    raise exception 'COMMUNICATION_CONSENT_DEPENDENCY_MISSING';
  end if;
  if not exists (select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'extensions' and p.proname = 'hmac') then
    raise exception 'COMMUNICATION_CONSENT_HMAC_UNAVAILABLE';
  end if;
end
$garde$;

-- Les seuils restent NULL tant qu'une décision métier ne les a pas fixés.
-- Cette candidate ne contient donc aucun quota ou délai métier implicite.
create table if not exists public.communication_consentement_reglages (
  id                              boolean primary key default true check (id),
  expiration_secondes             integer check (expiration_secondes is null or expiration_secondes > 0),
  maximum_tentatives               integer check (maximum_tentatives is null or maximum_tentatives > 0),
  portee_tentatives                text check (portee_tentatives is null or portee_tentatives in ('demande', 'contact')),
  fenetre_tentatives_secondes      integer check (fenetre_tentatives_secondes is null or fenetre_tentatives_secondes > 0),
  fenetre_demandes_secondes        integer check (fenetre_demandes_secondes is null or fenetre_demandes_secondes > 0),
  maximum_demandes_compte          integer check (maximum_demandes_compte is null or maximum_demandes_compte > 0),
  maximum_demandes_contact         integer check (maximum_demandes_contact is null or maximum_demandes_contact > 0),
  politique_contact_partage        text check (politique_contact_partage is null or politique_contact_partage in ('bloquer', 'comptes_distincts')),
  maj_le                           timestamptz not null default clock_timestamp()
);

insert into public.communication_consentement_reglages (id)
values (true)
on conflict (id) do nothing;

-- Les textes réellement affichés sont versionnés. Seul un texte attesté peut ouvrir
-- une demande ; aucune copie de texte juridique ou de consentement n'est inventée ici.
-- Cette candidate ne traite que le consentement marketing ; les préférences de messages
-- transactionnels restent dans leur modèle existant.
create table if not exists public.communication_consentement_textes (
  version       text not null check (length(version) between 1 and 80),
  canal         text not null check (canal = 'whatsapp'),
  langue        text not null check (langue in ('fr', 'en', 'es', 'ht')),
  texte         text not null check (length(texte) > 0),
  empreinte     text not null check (empreinte = encode(extensions.digest(texte, 'sha256'), 'hex')),
  statut        text not null default 'brouillon' check (statut in ('brouillon', 'atteste_juridique')),
  cree_le       timestamptz not null default clock_timestamp(),
  atteste_le    timestamptz,
  reference_attestation text,
  primary key (version, canal, langue),
  check ((statut = 'brouillon' and atteste_le is null and reference_attestation is null)
      or (statut = 'atteste_juridique' and atteste_le is not null
          and nullif(btrim(reference_attestation), '') is not null))
);

create or replace function public.communication_consentement_proteger_textes()
returns trigger
language plpgsql
set search_path = ''
as $fonction$
begin
  if tg_op = 'TRUNCATE' then
    raise exception 'COMMUNICATION_CONSENT_TEXT_IMMUTABLE';
  end if;
  if tg_op = 'DELETE' then
    if old.statut = 'atteste_juridique' then
      raise exception 'COMMUNICATION_CONSENT_TEXT_IMMUTABLE';
    end if;
    return old;
  end if;
  if old.statut = 'atteste_juridique' then
    raise exception 'COMMUNICATION_CONSENT_TEXT_IMMUTABLE';
  end if;
  return new;
end
$fonction$;

drop trigger if exists communication_consentement_textes_immuables on public.communication_consentement_textes;
create trigger communication_consentement_textes_immuables
  before update or delete on public.communication_consentement_textes
  for each row execute function public.communication_consentement_proteger_textes();
drop trigger if exists communication_consentement_textes_truncate_interdit on public.communication_consentement_textes;
create trigger communication_consentement_textes_truncate_interdit
  before truncate on public.communication_consentement_textes
  for each statement execute function public.communication_consentement_proteger_textes();

create table if not exists public.communication_consentements_clients (
  id                 bigint generated always as identity primary key,
  client_id          uuid not null references public.clients(id) on delete cascade,
  canal              text not null check (canal = 'whatsapp'),
  finalite           text not null default 'marketing' check (finalite = 'marketing'),
  etat               text not null check (etat in ('aucun', 'en_attente', 'confirme', 'refuse', 'retire', 'expire', 'bloque', 'invalide')),
  cible_empreinte    text,
  texte_version      text,
  texte_empreinte    text,
  langue             text check (langue is null or langue in ('fr', 'en', 'es', 'ht')),
  source             text check (source is null or source in ('compte_web', 'application', 'changement_contact')),
  demande_id         bigint,
  demande_le         timestamptz,
  confirme_le        timestamptz,
  retire_le          timestamptz,
  maj_le             timestamptz not null default clock_timestamp(),
  unique (client_id, canal, finalite),
  check (etat not in ('en_attente', 'confirme') or
         (cible_empreinte is not null and texte_version is not null and texte_empreinte is not null and langue is not null)),
  check (etat <> 'confirme' or confirme_le is not null),
  check (etat <> 'retire' or retire_le is not null)
);

create table if not exists public.communication_confirmations_whatsapp (
  id                          bigint generated always as identity primary key,
  consentement_id             bigint not null references public.communication_consentements_clients(id) on delete cascade,
  client_id                   uuid not null references public.clients(id) on delete cascade,
  canal                       text not null default 'whatsapp' check (canal = 'whatsapp'),
  cible_empreinte             text not null,
  code_empreinte              text not null,
  code_secret_id              uuid,
  etat                        text not null default 'en_attente'
                              check (etat in ('en_attente', 'confirme', 'refuse', 'expire', 'bloque', 'annule')),
  expire_le                   timestamptz not null,
  maximum_tentatives          integer not null check (maximum_tentatives > 0),
  portee_tentatives           text not null check (portee_tentatives in ('demande', 'contact')),
  fenetre_tentatives_secondes integer not null check (fenetre_tentatives_secondes > 0),
  cree_le                     timestamptz not null default clock_timestamp(),
  confirme_le                 timestamptz,
  termine_le                  timestamptz,
  check ((etat = 'en_attente' and code_secret_id is not null)
      or (etat <> 'en_attente' and code_secret_id is null)),
  check (etat <> 'confirme' or confirme_le is not null)
);

do $liaison$
begin
  if not exists (select 1 from pg_catalog.pg_constraint
                  where conrelid = 'public.communication_consentements_clients'::regclass
                    and conname = 'communication_consentements_clients_demande_fk') then
    alter table public.communication_consentements_clients
      add constraint communication_consentements_clients_demande_fk
      foreign key (demande_id) references public.communication_confirmations_whatsapp(id) on delete set null;
  end if;
end
$liaison$;

create unique index if not exists communication_confirmations_whatsapp_une_ouverte_par_compte_idx
  on public.communication_confirmations_whatsapp (client_id)
  where etat = 'en_attente';

create unique index if not exists communication_confirmations_whatsapp_code_contact_idx
  on public.communication_confirmations_whatsapp (cible_empreinte, code_empreinte)
  where etat = 'en_attente';

create index if not exists communication_confirmations_whatsapp_compte_idx
  on public.communication_confirmations_whatsapp (client_id, cree_le desc);

create or replace function public.communication_confirmation_supprimer_secret_vault()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fonction$
begin
  if old.code_secret_id is not null then
    delete from vault.secrets where id = old.code_secret_id;
  end if;
  return old;
end
$fonction$;

drop trigger if exists communication_confirmation_supprimer_secret_vault on public.communication_confirmations_whatsapp;
create trigger communication_confirmation_supprimer_secret_vault
  before delete on public.communication_confirmations_whatsapp
  for each row execute function public.communication_confirmation_supprimer_secret_vault();

create table if not exists public.communication_consentement_historique (
  id                 bigint generated always as identity primary key,
  consentement_id    bigint references public.communication_consentements_clients(id) on delete set null,
  demande_id         bigint references public.communication_confirmations_whatsapp(id) on delete set null,
  client_id          uuid references public.clients(id) on delete set null,
  canal              text not null check (canal = 'whatsapp'),
  finalite           text not null default 'marketing' check (finalite = 'marketing'),
  action             text not null check (action in ('demande', 'confirme', 'refus', 'retrait', 'expire', 'bloque', 'annule', 'invalide')),
  source             text not null check (source in ('compte_web', 'application', 'confirmation_whatsapp', 'changement_contact')),
  cible_empreinte    text,
  texte_version      text,
  texte_empreinte    text,
  langue             text check (langue is null or langue in ('fr', 'en', 'es', 'ht')),
  cree_le            timestamptz not null default clock_timestamp(),
  contexte           jsonb not null default '{}'::jsonb
);

create index if not exists communication_consentement_historique_compte_idx
  on public.communication_consentement_historique (client_id, canal, cree_le desc, id desc);

create table if not exists public.communication_confirmation_tentatives (
  id                 bigint generated always as identity primary key,
  demande_id         bigint references public.communication_confirmations_whatsapp(id) on delete set null,
  client_id          uuid references public.clients(id) on delete set null,
  cible_empreinte    text not null,
  resultat           text not null check (resultat in ('code_invalide', 'code_valide', 'expire', 'rejeu')),
  cree_le            timestamptz not null default clock_timestamp()
);

create index if not exists communication_confirmation_tentatives_contact_idx
  on public.communication_confirmation_tentatives (cible_empreinte, cree_le desc)
  where resultat = 'code_invalide';

create or replace function public.communication_consentement_proteger_historique()
returns trigger
language plpgsql
set search_path = ''
as $fonction$
begin
  if tg_op = 'DELETE' or tg_op = 'TRUNCATE' then
    raise exception 'COMMUNICATION_CONSENT_HISTORY_IMMUTABLE';
  end if;

  -- L'anonymisation par les FK ON DELETE SET NULL est la seule mise à jour permise.
  -- Elle ne peut venir que d'une action référentielle imbriquée, jamais d'un client SQL.
  if pg_trigger_depth() > 1
     and to_jsonb(new) - 'client_id' - 'consentement_id' - 'demande_id'
         = to_jsonb(old) - 'client_id' - 'consentement_id' - 'demande_id'
     and ((old.client_id is not null and new.client_id is null)
       or (old.consentement_id is not null and new.consentement_id is null)
       or (old.demande_id is not null and new.demande_id is null)) then
    return new;
  end if;
  raise exception 'COMMUNICATION_CONSENT_HISTORY_IMMUTABLE';
end
$fonction$;

create or replace function public.communication_consentement_proteger_tentatives()
returns trigger
language plpgsql
set search_path = ''
as $fonction$
begin
  if tg_op = 'DELETE' or tg_op = 'TRUNCATE' then
    raise exception 'COMMUNICATION_CONFIRMATION_ATTEMPTS_IMMUTABLE';
  end if;
  if pg_trigger_depth() > 1
     and to_jsonb(new) - 'client_id' - 'demande_id'
         = to_jsonb(old) - 'client_id' - 'demande_id'
     and ((old.client_id is not null and new.client_id is null)
       or (old.demande_id is not null and new.demande_id is null)) then
    return new;
  end if;
  raise exception 'COMMUNICATION_CONFIRMATION_ATTEMPTS_IMMUTABLE';
end
$fonction$;

drop trigger if exists communication_consentement_historique_immuable on public.communication_consentement_historique;
create trigger communication_consentement_historique_immuable
  before update or delete on public.communication_consentement_historique
  for each row execute function public.communication_consentement_proteger_historique();
drop trigger if exists communication_consentement_historique_truncate_interdit on public.communication_consentement_historique;
create trigger communication_consentement_historique_truncate_interdit
  before truncate on public.communication_consentement_historique
  for each statement execute function public.communication_consentement_proteger_historique();

drop trigger if exists communication_confirmation_tentatives_immuables on public.communication_confirmation_tentatives;
create trigger communication_confirmation_tentatives_immuables
  before update or delete on public.communication_confirmation_tentatives
  for each row execute function public.communication_consentement_proteger_tentatives();
drop trigger if exists communication_confirmation_tentatives_truncate_interdit on public.communication_confirmation_tentatives;
create trigger communication_confirmation_tentatives_truncate_interdit
  before truncate on public.communication_confirmation_tentatives
  for each statement execute function public.communication_consentement_proteger_tentatives();

create or replace function public.communication_consentement_cible(p_client uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $fonction$
  select nullif(public.telephone_international(c.telephone, c.pays), '')
    from public.clients c where c.id = p_client and c.role = 'client'
$fonction$;

create or replace function public.communication_consentement_empreinte(p_cible text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare
  v_poivre text := public.lire_reglage('communication_poivre');
begin
  if length(coalesce(v_poivre, '')) < 32 or coalesce(p_cible, '') = '' then
    return null;
  end if;
  return encode(extensions.hmac('goship:communication:whatsapp:v1:' || p_cible, v_poivre, 'sha256'), 'hex');
end
$fonction$;

create or replace function public.communication_consentement_demander_whatsapp(p_version text, p_langue text,
                                                                                p_source text default 'compte_web')
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'
as $fonction$
declare
  v_client uuid := auth.uid();
  v_cible text;
  v_empreinte text;
  v_poivre text;
  v_code text;
  v_code_empreinte text;
  v_secret_id uuid;
  v_octets bytea;
  v_tirage bigint;
  v_demande_id bigint;
  v_consentement_id bigint;
  v_tentative integer;
  v_nb_shared integer;
  v_param public.communication_consentement_reglages;
  v_texte public.communication_consentement_textes;
  v_etat public.communication_consentements_clients;
begin
  if v_client is null or not exists (select 1 from public.clients where id = v_client and role = 'client') then
    raise exception 'PERMISSION_DENIED';
  end if;
  if p_source not in ('compte_web', 'application') then
    raise exception 'INVALID_INPUT';
  end if;

  select * into v_param from public.communication_consentement_reglages where id is true;
  if not found or v_param.expiration_secondes is null or v_param.maximum_tentatives is null
     or v_param.portee_tentatives is null or v_param.fenetre_tentatives_secondes is null
     or v_param.fenetre_demandes_secondes is null or v_param.maximum_demandes_compte is null
     or v_param.maximum_demandes_contact is null then
    raise exception 'POLICY_UNCONFIGURED';
  end if;

  select * into v_texte from public.communication_consentement_textes
   where version = p_version and canal = 'whatsapp' and langue = p_langue and statut = 'atteste_juridique';
  if not found then
    raise exception 'CONSENT_TEXT_NOT_APPROVED';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('goship:consent-account:' || v_client::text, 0));
  v_cible := public.communication_consentement_cible(v_client);
  v_empreinte := public.communication_consentement_empreinte(v_cible);
  v_poivre := public.lire_reglage('communication_poivre');
  if v_cible is null or v_empreinte is null or length(coalesce(v_poivre, '')) < 32 then
    raise exception 'SECURE_CONFIGURATION_UNAVAILABLE';
  end if;

  -- Ordre stable : compte puis empreinte du contact, avant toute ligne métier.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('goship:whatsapp:' || v_empreinte, 0));

  select count(*) into v_nb_shared
    from public.clients c
   where c.role = 'client' and c.id <> v_client
     and public.communication_consentement_empreinte(
           nullif(public.telephone_international(c.telephone, c.pays), '')) = v_empreinte;
  if v_nb_shared > 0 then
    if v_param.politique_contact_partage is null then
      raise exception 'SHARED_TARGET_POLICY_REQUIRED';
    elsif v_param.politique_contact_partage = 'bloquer' then
      raise exception 'SHARED_TARGET_BLOCKED';
    end if;
  end if;

  select * into v_etat from public.communication_consentements_clients
   where client_id = v_client and canal = 'whatsapp' and finalite = 'marketing';
  if found and v_etat.etat = 'confirme' and v_etat.cible_empreinte = v_empreinte then
    return jsonb_build_object('ok', true, 'etat', 'confirme', 'deja_confirme', true);
  end if;
  if found and v_etat.etat = 'en_attente' and v_etat.cible_empreinte = v_empreinte
     and exists (select 1 from public.communication_confirmations_whatsapp
                  where id = v_etat.demande_id and etat = 'en_attente'
                    and expire_le > clock_timestamp()) then
    -- La candidate S-1 attache la tâche de confirmation dans la même
    -- transaction. Son identifiant stable empêche un rejeu de créer un doublon.
    perform communication_edge.communication_edge_confirmation_creer_tache_whatsapp(
      v_etat.demande_id, v_client);
    return jsonb_build_object('ok', true, 'etat', 'en_attente', 'demande_id', v_etat.demande_id,
                              'demande_reutilisee', true);
  end if;

  if found and v_etat.etat = 'en_attente' and v_etat.cible_empreinte = v_empreinte
     and exists (select 1 from public.communication_confirmations_whatsapp
                  where id = v_etat.demande_id and etat = 'en_attente'
                    and expire_le <= clock_timestamp()) then
    delete from vault.secrets
     where id = (select code_secret_id from public.communication_confirmations_whatsapp where id = v_etat.demande_id);
    update public.communication_confirmations_whatsapp
       set etat = 'expire', code_secret_id = null, termine_le = clock_timestamp()
     where id = v_etat.demande_id and etat = 'en_attente';
    update public.communication_consentements_clients
       set etat = 'expire', maj_le = clock_timestamp()
     where id = v_etat.id;
    insert into public.communication_consentement_historique
      (consentement_id, demande_id, client_id, canal, action, source, cible_empreinte,
       texte_version, texte_empreinte, langue)
    values (v_etat.id, v_etat.demande_id, v_client, 'whatsapp', 'expire', 'confirmation_whatsapp', v_empreinte,
            v_etat.texte_version, v_etat.texte_empreinte, v_etat.langue);
  end if;

  if (select count(*) from public.communication_confirmations_whatsapp
       where client_id = v_client and cree_le > clock_timestamp() - make_interval(secs => v_param.fenetre_demandes_secondes))
       >= v_param.maximum_demandes_compte
     or (select count(*) from public.communication_confirmations_whatsapp
          where cible_empreinte = v_empreinte
            and cree_le > clock_timestamp() - make_interval(secs => v_param.fenetre_demandes_secondes))
       >= v_param.maximum_demandes_contact then
    raise exception 'REQUEST_RATE_LIMITED';
  end if;

  if found and v_etat.etat in ('confirme', 'en_attente') and v_etat.cible_empreinte is distinct from v_empreinte then
    insert into public.communication_consentement_historique
      (consentement_id, client_id, canal, action, source, cible_empreinte,
       texte_version, texte_empreinte, langue, contexte)
    values (v_etat.id, v_client, 'whatsapp', 'invalide', 'changement_contact', v_etat.cible_empreinte,
            v_etat.texte_version, v_etat.texte_empreinte, v_etat.langue,
            jsonb_build_object('raison', 'contact_modifie'));
    delete from vault.secrets
     where id = (select code_secret_id from public.communication_confirmations_whatsapp
                  where id = v_etat.demande_id and etat = 'en_attente');
    update public.communication_confirmations_whatsapp
       set etat = 'annule', code_secret_id = null, termine_le = clock_timestamp()
     where id = v_etat.demande_id and etat = 'en_attente';
  end if;

  insert into public.communication_consentements_clients
    (client_id, canal, finalite, etat, cible_empreinte, texte_version, texte_empreinte,
     langue, source, demande_le, confirme_le, retire_le)
  values (v_client, 'whatsapp', 'marketing', 'en_attente', v_empreinte, v_texte.version,
          v_texte.empreinte, v_texte.langue, p_source, clock_timestamp(), null, null)
  on conflict (client_id, canal, finalite) do update
    set etat = 'en_attente', cible_empreinte = excluded.cible_empreinte,
        texte_version = excluded.texte_version, texte_empreinte = excluded.texte_empreinte,
        langue = excluded.langue, source = excluded.source, demande_le = excluded.demande_le,
        confirme_le = null, retire_le = null, maj_le = clock_timestamp()
  returning id into v_consentement_id;

  for v_tentative in 1..20 loop
    v_octets := extensions.gen_random_bytes(4);
    v_tirage := get_byte(v_octets, 0)::bigint * 16777216
              + get_byte(v_octets, 1)::bigint * 65536
              + get_byte(v_octets, 2)::bigint * 256
              + get_byte(v_octets, 3)::bigint;
    continue when v_tirage >= 4294000000;
    v_code := lpad((v_tirage % 1000000)::text, 6, '0');
    v_code_empreinte := encode(extensions.hmac('goship:communication:confirmation:v1:' || v_empreinte || ':' || v_code,
                                               v_poivre, 'sha256'), 'hex');
    begin
      v_secret_id := vault.create_secret(v_code, 'goship-confirmation-' || gen_random_uuid()::text);
      insert into public.communication_confirmations_whatsapp
        (consentement_id, client_id, cible_empreinte, code_empreinte, code_secret_id, etat,
         expire_le, maximum_tentatives, portee_tentatives, fenetre_tentatives_secondes)
      values (v_consentement_id, v_client, v_empreinte, v_code_empreinte, v_secret_id, 'en_attente',
              clock_timestamp() + make_interval(secs => v_param.expiration_secondes),
              v_param.maximum_tentatives, v_param.portee_tentatives, v_param.fenetre_tentatives_secondes)
      returning id into v_demande_id;
      exit;
    exception when unique_violation then
      v_demande_id := null;
      v_secret_id := null;
    end;
  end loop;
  if v_demande_id is null then
    raise exception 'CODE_ALLOCATION_UNAVAILABLE';
  end if;

  update public.communication_consentements_clients set demande_id = v_demande_id, maj_le = clock_timestamp()
   where id = v_consentement_id;
  insert into public.communication_consentement_historique
    (consentement_id, demande_id, client_id, canal, action, source, cible_empreinte,
     texte_version, texte_empreinte, langue)
  values (v_consentement_id, v_demande_id, v_client, 'whatsapp', 'demande', p_source,
          v_empreinte, v_texte.version, v_texte.empreinte, v_texte.langue);

  -- La demande, le secret Vault, l'historique et la tâche d'outbox sont validés
  -- ou annulés ensemble. Aucun code ni téléphone n'est copié dans l'outbox.
  perform communication_edge.communication_edge_confirmation_creer_tache_whatsapp(
    v_demande_id, v_client);

  return jsonb_build_object('ok', true, 'etat', 'en_attente', 'canal', 'whatsapp',
                            'finalite', 'marketing', 'demande_id', v_demande_id);
end
$fonction$;

create or replace function public.communication_consentement_etat_whatsapp()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare
  v_client uuid := auth.uid();
  v_cible text;
  v_empreinte text;
  v_etat public.communication_consentements_clients;
begin
  if v_client is null or not exists (select 1 from public.clients where id = v_client and role = 'client') then
    raise exception 'PERMISSION_DENIED';
  end if;
  v_cible := public.communication_consentement_cible(v_client);
  v_empreinte := public.communication_consentement_empreinte(v_cible);
  select * into v_etat from public.communication_consentements_clients
   where client_id = v_client and canal = 'whatsapp' and finalite = 'marketing';
  if not found then
    return jsonb_build_object('etat', 'aucun', 'actif', false);
  end if;
  return jsonb_build_object('etat', v_etat.etat,
                            'actif', v_etat.etat = 'confirme' and v_etat.cible_empreinte = v_empreinte,
                            'canal', v_etat.canal, 'finalite', v_etat.finalite,
                            'demande_le', v_etat.demande_le, 'confirme_le', v_etat.confirme_le,
                            'retire_le', v_etat.retire_le);
end
$fonction$;

create or replace function public.communication_consentement_confirmer_whatsapp(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'
as $fonction$
declare
  v_client uuid := auth.uid();
  v_cible text;
  v_empreinte text;
  v_poivre text;
  v_code_empreinte text;
  v_demande public.communication_confirmations_whatsapp;
  v_echecs integer;
  v_reponse boolean := false;
begin
  if v_client is null or not exists (select 1 from public.clients where id = v_client and role = 'client') then
    raise exception 'PERMISSION_DENIED';
  end if;
  if coalesce(p_code, '') !~ '^[0-9]{6}$' then
    return jsonb_build_object('ok', false);
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('goship:consent-account:' || v_client::text, 0));
  v_cible := public.communication_consentement_cible(v_client);
  v_empreinte := public.communication_consentement_empreinte(v_cible);
  v_poivre := public.lire_reglage('communication_poivre');
  if v_empreinte is null or length(coalesce(v_poivre, '')) < 32 then
    return jsonb_build_object('ok', false);
  end if;
  v_code_empreinte := encode(extensions.hmac('goship:communication:confirmation:v1:' || v_empreinte || ':' || p_code,
                                             v_poivre, 'sha256'), 'hex');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('goship:whatsapp:' || v_empreinte, 0));

  select * into v_demande from public.communication_confirmations_whatsapp
   where client_id = v_client and cible_empreinte = v_empreinte and etat = 'en_attente'
   order by cree_le desc, id desc limit 1 for update;
  if not found then
    -- Rejouer exactement le code déjà consommé est idempotent et n'ajoute pas de preuve.
    if exists (select 1 from public.communication_confirmations_whatsapp
                where client_id = v_client and cible_empreinte = v_empreinte
                  and etat = 'confirme' and code_empreinte = v_code_empreinte) then
      return jsonb_build_object('ok', true, 'deja_confirme', true);
    end if;
    return jsonb_build_object('ok', false);
  end if;

  if v_demande.expire_le <= clock_timestamp() then
    delete from vault.secrets where id = v_demande.code_secret_id;
    update public.communication_confirmations_whatsapp
       set etat = 'expire', code_secret_id = null, termine_le = clock_timestamp()
     where id = v_demande.id;
    update public.communication_consentements_clients
       set etat = 'expire', maj_le = clock_timestamp()
     where id = v_demande.consentement_id and etat = 'en_attente';
    insert into public.communication_confirmation_tentatives
      (demande_id, client_id, cible_empreinte, resultat)
    values (v_demande.id, v_client, v_empreinte, 'expire');
    insert into public.communication_consentement_historique
      (consentement_id, demande_id, client_id, canal, action, source, cible_empreinte,
       texte_version, texte_empreinte, langue)
    select c.id, v_demande.id, v_client, 'whatsapp', 'expire', 'confirmation_whatsapp', v_empreinte,
           c.texte_version, c.texte_empreinte, c.langue
      from public.communication_consentements_clients c where c.id = v_demande.consentement_id;
    return jsonb_build_object('ok', false);
  end if;

  if v_demande.code_empreinte <> v_code_empreinte then
    insert into public.communication_confirmation_tentatives
      (demande_id, client_id, cible_empreinte, resultat)
    values (v_demande.id, v_client, v_empreinte, 'code_invalide');
    select count(*) into v_echecs
      from public.communication_confirmation_tentatives t
     where t.resultat = 'code_invalide'
       and t.cree_le > clock_timestamp() - make_interval(secs => v_demande.fenetre_tentatives_secondes)
       and ((v_demande.portee_tentatives = 'demande' and t.demande_id = v_demande.id)
         or (v_demande.portee_tentatives = 'contact' and t.cible_empreinte = v_empreinte));
    if v_echecs >= v_demande.maximum_tentatives then
      delete from vault.secrets where id = v_demande.code_secret_id;
      update public.communication_confirmations_whatsapp
         set etat = 'bloque', code_secret_id = null, termine_le = clock_timestamp()
       where id = v_demande.id;
      update public.communication_consentements_clients
         set etat = 'bloque', maj_le = clock_timestamp()
       where id = v_demande.consentement_id and etat = 'en_attente';
      insert into public.communication_consentement_historique
        (consentement_id, demande_id, client_id, canal, action, source, cible_empreinte,
         texte_version, texte_empreinte, langue)
      select c.id, v_demande.id, v_client, 'whatsapp', 'bloque', 'confirmation_whatsapp', v_empreinte,
             c.texte_version, c.texte_empreinte, c.langue
        from public.communication_consentements_clients c where c.id = v_demande.consentement_id;
      v_reponse := true;
    end if;
    return jsonb_build_object('ok', false, 'bloque', v_reponse);
  end if;

  insert into public.communication_confirmation_tentatives
    (demande_id, client_id, cible_empreinte, resultat)
  values (v_demande.id, v_client, v_empreinte, 'code_valide');
  delete from vault.secrets where id = v_demande.code_secret_id;
  update public.communication_confirmations_whatsapp
     set etat = 'confirme', code_secret_id = null, confirme_le = clock_timestamp(), termine_le = clock_timestamp()
   where id = v_demande.id;
  update public.communication_consentements_clients
     set etat = 'confirme', confirme_le = clock_timestamp(), maj_le = clock_timestamp()
   where id = v_demande.consentement_id and client_id = v_client;
  insert into public.communication_consentement_historique
    (consentement_id, demande_id, client_id, canal, action, source, cible_empreinte,
     texte_version, texte_empreinte, langue)
  select c.id, v_demande.id, v_client, 'whatsapp', 'confirme', 'confirmation_whatsapp',
         v_empreinte, c.texte_version, c.texte_empreinte, c.langue
    from public.communication_consentements_clients c where c.id = v_demande.consentement_id;
  return jsonb_build_object('ok', true, 'etat', 'confirme');
end
$fonction$;

create or replace function public.communication_consentement_refuser_whatsapp(p_source text default 'compte_web')
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'
as $fonction$
declare
  v_client uuid := auth.uid();
  v_demande public.communication_confirmations_whatsapp;
begin
  if v_client is null or not exists (select 1 from public.clients where id = v_client and role = 'client') then
    raise exception 'PERMISSION_DENIED';
  end if;
  if p_source not in ('compte_web', 'application') then
    raise exception 'INVALID_INPUT';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('goship:consent-account:' || v_client::text, 0));
  select * into v_demande from public.communication_confirmations_whatsapp
   where client_id = v_client and etat = 'en_attente'
   order by cree_le desc, id desc limit 1;
  if not found then
    return jsonb_build_object('ok', true, 'deja_termine', true);
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('goship:whatsapp:' || v_demande.cible_empreinte, 0));
  select * into v_demande from public.communication_confirmations_whatsapp
   where id = v_demande.id and client_id = v_client and etat = 'en_attente' for update;
  if not found then
    return jsonb_build_object('ok', true, 'deja_termine', true);
  end if;
  delete from vault.secrets where id = v_demande.code_secret_id;
  update public.communication_confirmations_whatsapp
     set etat = 'refuse', code_secret_id = null, termine_le = clock_timestamp()
   where id = v_demande.id;
  update public.communication_consentements_clients
     set etat = 'refuse', maj_le = clock_timestamp()
   where id = v_demande.consentement_id and client_id = v_client;
  insert into public.communication_consentement_historique
    (consentement_id, demande_id, client_id, canal, action, source, cible_empreinte,
     texte_version, texte_empreinte, langue)
  select c.id, v_demande.id, v_client, 'whatsapp', 'refus', p_source, v_demande.cible_empreinte,
         c.texte_version, c.texte_empreinte, c.langue
    from public.communication_consentements_clients c where c.id = v_demande.consentement_id;
  return jsonb_build_object('ok', true, 'etat', 'refuse');
end
$fonction$;

create or replace function public.communication_consentement_retirer_whatsapp(p_source text default 'compte_web')
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'
as $fonction$
declare
  v_client uuid := auth.uid();
  v_empreinte text;
  v_etat public.communication_consentements_clients;
begin
  if v_client is null or not exists (select 1 from public.clients where id = v_client and role = 'client') then
    raise exception 'PERMISSION_DENIED';
  end if;
  if p_source not in ('compte_web', 'application') then
    raise exception 'INVALID_INPUT';
  end if;
  select * into v_etat from public.communication_consentements_clients
   where client_id = v_client and canal = 'whatsapp' and finalite = 'marketing';
  if not found then
    return jsonb_build_object('ok', true, 'deja_retire', true);
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('goship:consent-account:' || v_client::text, 0));
  select * into v_etat from public.communication_consentements_clients
   where client_id = v_client and canal = 'whatsapp' and finalite = 'marketing';
  if not found then
    return jsonb_build_object('ok', true, 'deja_retire', true);
  end if;
  v_empreinte := v_etat.cible_empreinte;
  if v_empreinte is not null then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('goship:whatsapp:' || v_empreinte, 0));
  else
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('goship:whatsapp:client:' || v_client::text, 0));
  end if;
  select * into v_etat from public.communication_consentements_clients
   where client_id = v_client and canal = 'whatsapp' and finalite = 'marketing' for update;
  if not found then
    return jsonb_build_object('ok', true, 'deja_retire', true);
  end if;
  if v_etat.etat = 'retire' then
    return jsonb_build_object('ok', true, 'deja_retire', true);
  end if;
  delete from vault.secrets
   where id in (select code_secret_id from public.communication_confirmations_whatsapp
                 where client_id = v_client and etat = 'en_attente' and code_secret_id is not null);
  update public.communication_confirmations_whatsapp
     set etat = 'annule', code_secret_id = null, termine_le = clock_timestamp()
   where client_id = v_client and etat = 'en_attente';
  update public.communication_consentements_clients
     set etat = 'retire', retire_le = clock_timestamp(), maj_le = clock_timestamp()
   where id = v_etat.id;
  insert into public.communication_consentement_historique
    (consentement_id, demande_id, client_id, canal, action, source, cible_empreinte,
     texte_version, texte_empreinte, langue)
  values (v_etat.id, v_etat.demande_id, v_client, 'whatsapp', 'retrait', p_source,
          v_etat.cible_empreinte, v_etat.texte_version, v_etat.texte_empreinte, v_etat.langue);
  return jsonb_build_object('ok', true, 'etat', 'retire');
end
$fonction$;

-- Seul un backend authentifié avec le rôle service_role peut récupérer le code déchiffré
-- pour une remise future autorisée. Cette fonction n'envoie aucun message.
create or replace function public.communication_code_whatsapp_pour_envoi(p_demande_id bigint)
returns text
language plpgsql
security definer
set search_path = ''
as $fonction$
declare
  v_demande public.communication_confirmations_whatsapp;
  v_code text;
  v_role text := current_setting('request.jwt.claims', true)::jsonb ->> 'role';
begin
  if v_role is distinct from 'service_role' then
    raise exception 'PERMISSION_DENIED';
  end if;
  select * into v_demande from public.communication_confirmations_whatsapp
   where id = p_demande_id and etat = 'en_attente' and expire_le > clock_timestamp();
  if not found then
    return null;
  end if;
  if public.communication_consentement_empreinte(public.communication_consentement_cible(v_demande.client_id))
       is distinct from v_demande.cible_empreinte then
    return null;
  end if;
  select d.decrypted_secret into v_code
    from vault.decrypted_secrets d where d.id = v_demande.code_secret_id;
  return v_code;
end
$fonction$;

alter table public.communication_consentement_reglages enable row level security;
alter table public.communication_consentement_textes enable row level security;
alter table public.communication_consentements_clients enable row level security;
alter table public.communication_confirmations_whatsapp enable row level security;
alter table public.communication_consentement_historique enable row level security;
alter table public.communication_confirmation_tentatives enable row level security;

revoke all on public.communication_consentement_reglages,
  public.communication_consentement_textes,
  public.communication_consentements_clients,
  public.communication_confirmations_whatsapp,
  public.communication_consentement_historique,
  public.communication_confirmation_tentatives
  from public, anon, authenticated, service_role;

revoke all on function public.communication_consentement_proteger_historique(),
  public.communication_consentement_proteger_tentatives(),
  public.communication_consentement_proteger_textes(),
  public.communication_confirmation_supprimer_secret_vault(),
  public.communication_consentement_cible(uuid),
  public.communication_consentement_empreinte(text),
  public.communication_consentement_demander_whatsapp(text,text,text),
  public.communication_consentement_etat_whatsapp(),
  public.communication_consentement_confirmer_whatsapp(text),
  public.communication_consentement_refuser_whatsapp(text),
  public.communication_consentement_retirer_whatsapp(text),
  public.communication_code_whatsapp_pour_envoi(bigint)
  from public, anon, authenticated, service_role;

grant execute on function public.communication_consentement_demander_whatsapp(text,text,text),
  public.communication_consentement_etat_whatsapp(),
  public.communication_consentement_confirmer_whatsapp(text),
  public.communication_consentement_refuser_whatsapp(text),
  public.communication_consentement_retirer_whatsapp(text)
  to authenticated;
grant execute on function public.communication_code_whatsapp_pour_envoi(bigint) to service_role;

do $sequences$
declare
  v_nom text;
begin
  foreach v_nom in array array[
    pg_catalog.pg_get_serial_sequence('public.communication_consentements_clients', 'id'),
    pg_catalog.pg_get_serial_sequence('public.communication_confirmations_whatsapp', 'id'),
    pg_catalog.pg_get_serial_sequence('public.communication_consentement_historique', 'id'),
    pg_catalog.pg_get_serial_sequence('public.communication_confirmation_tentatives', 'id')
  ] loop
    if v_nom is not null then
      execute pg_catalog.format('revoke all on sequence %s from public, anon, authenticated, service_role', v_nom);
    end if;
  end loop;
end
$sequences$;

commit;
