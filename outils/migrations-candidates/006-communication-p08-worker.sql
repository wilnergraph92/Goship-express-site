-- C4.1 — worker P-08, réception générique et reçus Expo.
-- En fin de outils/migrations.txt depuis le 23/11/2026 (étape C11) : essais locaux et CI
-- seulement. Ne pas appliquer à une base distante (critère C14 de docs/production/go-no-go.md).
-- Un lot est traité dans une seule transaction RPC : SKIP LOCKED protège la
-- réservation pendant que ses effets métier et son état final sont atomiques.
-- Aucun appel fournisseur n'est fait par ces fonctions.

begin;

do $garde$
begin
  if pg_catalog.to_regclass('public.communication_evenements_fournisseur') is null
     or pg_catalog.to_regclass('public.communication_evenements_traitement') is null
     or pg_catalog.to_regclass('public.communication_consentements_clients') is null
     or pg_catalog.to_regclass('public.communication_confirmations_whatsapp') is null
     or pg_catalog.to_regclass('public.communication_consentement_historique') is null
     or pg_catalog.to_regclass('public.notification_envois') is null
     or pg_catalog.to_regprocedure('public.communication_consentement_empreinte(text)') is null
     or pg_catalog.to_regprocedure('public.lire_reglage(text)') is null
     or pg_catalog.to_regprocedure('extensions.hmac(text,text,text)') is null
     or not exists (select 1 from pg_catalog.pg_roles where rolname = 'communication_webhook') then
    raise exception 'COMMUNICATION_P08_DEPENDENCY_MISSING';
  end if;
end
$garde$;

do $role$
begin
  if not exists (select 1 from pg_catalog.pg_roles where rolname = 'communication_worker') then
    create role communication_worker nologin noinherit nobypassrls;
  end if;
end
$role$;
grant usage on schema public to communication_worker;

create table if not exists public.communication_evenements_traitement_historique (
  id          bigint generated always as identity primary key,
  evenement_id bigint not null
              references public.communication_evenements_traitement(evenement_id) on delete restrict,
  ancien_etat text,
  nouvel_etat text not null,
  tentatives  integer not null,
  code        text,
  resultat    text,
  cree_le     timestamptz not null default clock_timestamp()
);
alter table public.communication_evenements_traitement_historique enable row level security;
revoke all on public.communication_evenements_traitement_historique
  from public, anon, authenticated, service_role;

create or replace function public.communication_p08_journaliser_transition()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fonction$
begin
  if tg_op = 'INSERT'
     or old.etat is distinct from new.etat
     or old.tentatives is distinct from new.tentatives
     or old.dernier_code is distinct from new.dernier_code
     or old.resultat is distinct from new.resultat then
    insert into public.communication_evenements_traitement_historique
      (evenement_id, ancien_etat, nouvel_etat, tentatives, code, resultat)
    values (new.evenement_id, case when tg_op = 'INSERT' then null else old.etat end,
            new.etat, new.tentatives, new.dernier_code, new.resultat);
  end if;
  return new;
end
$fonction$;
drop trigger if exists communication_p08_transition_historique
  on public.communication_evenements_traitement;
create trigger communication_p08_transition_historique
  after insert or update of etat, tentatives, dernier_code, resultat
  on public.communication_evenements_traitement
  for each row execute function public.communication_p08_journaliser_transition();
revoke all on function public.communication_p08_journaliser_transition()
  from public, anon, authenticated, service_role;

-- Une opposition STOP est liée à l'empreinte du contact, même lorsqu'aucun
-- compte GoShip n'avait encore de ligne de consentement au moment du message.
create table if not exists public.communication_contact_suppressions (
  id                       bigint generated always as identity primary key,
  canal                    text not null check (canal = 'whatsapp'),
  cible_empreinte          text not null check (cible_empreinte ~ '^[0-9a-f]{64}$'),
  raison                   text not null check (raison = 'stop'),
  evenement_id             bigint not null,
  cree_le                  timestamptz not null default clock_timestamp(),
  leve_le                  timestamptz,
  levee_par_consentement_id bigint references public.communication_consentements_clients(id) on delete set null,
  unique (id, canal, cible_empreinte)
);
create unique index if not exists communication_contact_suppressions_actives_idx
  on public.communication_contact_suppressions (canal, cible_empreinte)
  where leve_le is null;
alter table public.communication_contact_suppressions enable row level security;
revoke all on public.communication_contact_suppressions from public, anon, authenticated, service_role;

-- Le code de provenance distingue le retrait reçu par WhatsApp d'une action
-- effectuée dans le compte ou l'application.
do $source_check$
declare
  v_contrainte text;
begin
  for v_contrainte in
    select c.conname
      from pg_catalog.pg_constraint c
     where c.conrelid = 'public.communication_consentement_historique'::regclass
       and c.contype = 'c'
       and pg_catalog.pg_get_constraintdef(c.oid) ilike '%source%'
  loop
    execute pg_catalog.format(
      'alter table public.communication_consentement_historique drop constraint %I', v_contrainte);
  end loop;
  if not exists (select 1 from pg_catalog.pg_constraint
                  where conrelid = 'public.communication_consentement_historique'::regclass
                    and conname = 'communication_consentement_historique_source_c41_check') then
    alter table public.communication_consentement_historique
      add constraint communication_consentement_historique_source_c41_check
      check (source in ('compte_web', 'application', 'confirmation_whatsapp',
                        'changement_contact', 'whatsapp_stop', 'desabonnement_courriel',
                        'opposition_equipe'));
  end if;
end
$source_check$;

create or replace function public.communication_p08_lever_suppression_confirmation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fonction$
begin
  if new.etat = 'confirme' and old.etat is distinct from 'confirme'
     and new.canal = 'whatsapp' and new.finalite = 'marketing'
     and new.cible_empreinte is not null then
    update public.communication_contact_suppressions
       set leve_le = clock_timestamp(), levee_par_consentement_id = new.id
     where canal = 'whatsapp' and cible_empreinte = new.cible_empreinte and leve_le is null;
  end if;
  return new;
end
$fonction$;
drop trigger if exists communication_p08_lever_suppression_confirmation
  on public.communication_consentements_clients;
create trigger communication_p08_lever_suppression_confirmation
  after update of etat on public.communication_consentements_clients
  for each row execute function public.communication_p08_lever_suppression_confirmation();
revoke all on function public.communication_p08_lever_suppression_confirmation()
  from public, anon, authenticated, service_role;

-- P-09 (correction D5 approuvée par la CEO le 20/11/2026, reportée dans la candidate
-- le 23/11/2026) : la CLASSE d'un message entrant, calculée à la réception, sans
-- jamais garder son texte. Avant, seul le message exact « STOP » désabonnait :
-- « Stop please » ou « Arrêter les messages » étaient ignorés (revue finale RF-03).
-- Règles, listes À FAIRE VALIDER par le juriste :
--   1. un bouton de désinscription (charge structurée) : toujours « stop » ;
--   2. le message ENTIER est un mot ou une phrase d'arrêt de la liste fermée ;
--   3. le PREMIER mot est un verbe d'arrêt sans ambiguïté et le message compte
--      5 mots au plus (« Stop please », « Arrêter les promotions ») ;
--   4. un mot d'arrêt ailleurs dans un message plus long : « ambigu », rien n'est
--      retiré (une simple mention ne désabonne jamais), compté pour revue humaine.
-- ARRET, END, FIN, CANCEL, QUIT ne comptent que SEULS : « Arrêt de bus » ou
-- « Cancel my order » ne désabonnent pas.
create or replace function public.communication_classer_entrant(p_texte text, p_bouton text default null)
returns text
language sql
immutable
set search_path = ''
as $fonction$
  with m as (
    select pg_catalog.btrim(pg_catalog.regexp_replace(pg_catalog.regexp_replace(
             pg_catalog.upper(pg_catalog.translate(coalesce(p_texte, ''),
               'ÀÂÄÁÉÈÊËÎÏÍÔÖÓÙÛÜÚÇÑàâäáéèêëîïíôöóùûüúçñ',
               'AAAAEEEEIIIOOOUUUUCNaaaaeeeeiiiooouuuucn')),
             '[^A-Z0-9 ]', ' ', 'g'), ' +', ' ', 'g')) t,
           pg_catalog.upper(pg_catalog.btrim(coalesce(p_bouton, ''))) b
  ), n as (
    select m.t, m.b, pg_catalog.string_to_array(nullif(m.t, ''), ' ') mots from m
  )
  select case
    when n.b in ('STOP', 'UNSUBSCRIBE', 'OPT_OUT', 'OPTOUT', 'MARKETING_OPT_OUT') then 'stop'
    when n.t in ('STOP', 'STOP STOP', 'STOP ALL', 'STOP PLEASE', 'PLEASE STOP', 'ARRET', 'ARRETER', 'ARRETEZ',
                 'DESABONNER', 'DESINSCRIRE', 'UNSUBSCRIBE', 'CANCEL', 'QUIT', 'END', 'FIN', 'REVOKE',
                 'OPT OUT', 'OPTOUT', 'BAJA', 'PARAR', 'DETENER', 'CANCELAR', 'NO MAS', 'NO MAS MENSAJES',
                 'KANPE', 'SISPANN', 'DEZABONE') then 'stop'
    when n.mots[1] in ('STOP', 'ARRETER', 'ARRETEZ', 'DESABONNER', 'DESABONNEZ', 'DESINSCRIRE', 'DESINSCRIVEZ',
                       'UNSUBSCRIBE', 'OPTOUT', 'REVOKE', 'BAJA', 'DETENER', 'DESUSCRIBIR', 'KANPE', 'SISPANN',
                       'DEZABONE')
         and coalesce(pg_catalog.array_length(n.mots, 1), 0) <= 5 then 'stop'
    when n.mots && array['STOP', 'ARRETER', 'ARRETEZ', 'DESABONNER', 'DESINSCRIRE', 'UNSUBSCRIBE', 'OPTOUT',
                         'REVOKE', 'BAJA', 'KANPE', 'SISPANN', 'DEZABONE'] then 'ambigu'
    else 'autre'
  end
  from n
$fonction$;
-- Fonction interne : seule la réception des retours (SECURITY DEFINER) l'appelle.
revoke all on function public.communication_classer_entrant(text, text)
  from public, anon, authenticated, service_role;

-- Le webhook ne conserve jamais téléphone ou texte : seulement l'empreinte de
-- contact nécessaire au traitement STOP et un identifiant de rejeu non réversible.
create or replace function public.communication_recevoir_evenement(
  p_fournisseur text, p_charge text, p_signature text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $fonction$
declare
  v_charge jsonb;
  v_type text;
  v_id text;
  v_message_id text;
  v_code text;
  v_survenu timestamptz;
  v_cible text;
  v_empreinte text;
  v_classe text := 'autre';
  v_priorite smallint := 2;
  v_evenement bigint;
  v_cle text;
  v_id_stocke text;
begin
  if p_fournisseur is null or p_fournisseur not in ('meta', 'brevo', 'resend')
     or p_charge is null or pg_catalog.length(p_charge) > 20000
     or coalesce(p_signature, '') !~ '^[0-9a-f]{64}$' then
    return pg_catalog.jsonb_build_object('ok', false);
  end if;
  begin
    v_charge := p_charge::jsonb;
    v_survenu := nullif(v_charge ->> 'survenu_le', '')::timestamptz;
  exception when others then
    return pg_catalog.jsonb_build_object('ok', false, 'format', true);
  end;
  if pg_catalog.jsonb_typeof(v_charge) <> 'object' then
    return pg_catalog.jsonb_build_object('ok', false, 'format', true);
  end if;

  v_type := v_charge ->> 'type';
  v_id := v_charge ->> 'id';
  v_message_id := v_charge ->> 'message_id';
  v_code := v_charge ->> 'code';
  if coalesce(v_id, '') = '' or pg_catalog.length(v_id) > 200
     or v_type not in ('inbound', 'complaint', 'unsubscribe', 'soft_bounce') then
    return pg_catalog.jsonb_build_object('ok', false, 'format', true);
  end if;
  if v_type = 'inbound' then
    if p_fournisseur <> 'meta' or coalesce(v_charge ->> 'telephone', '') !~ '^\+?[0-9]{5,20}$' then
      return pg_catalog.jsonb_build_object('ok', false, 'format', true);
    end if;
    -- Le consentement GoShip conserve le téléphone international en chiffres
    -- seuls. Appliquer exactement cette normalisation avant l'empreinte évite
    -- que « +1… » et « 1… » deviennent deux identités de contact distinctes.
    v_cible := pg_catalog.regexp_replace(v_charge ->> 'telephone', '[^0-9]', '', 'g');
    v_empreinte := public.communication_consentement_empreinte(v_cible);
    if v_empreinte is null then
      raise exception 'COMMUNICATION_CONTACT_FINGERPRINT_UNAVAILABLE';
    end if;
    -- P-09 : classe calculée ici (le texte n'est jamais gardé) ; seul « stop » retire
    v_classe := public.communication_classer_entrant(v_charge ->> 'texte', v_charge ->> 'bouton');
    if v_classe = 'stop' then
      v_priorite := 1;
    end if;
    v_id_stocke := 'in:' || pg_catalog.encode(extensions.digest(v_id, 'sha256'), 'hex');
    v_message_id := null;
  else
    if coalesce(v_message_id, '') = '' or pg_catalog.length(v_message_id) > 200
       or (v_code is not null and v_code !~ '^[A-Za-z0-9_-]{1,60}$')
       or v_survenu is null or v_survenu > pg_catalog.now() + interval '5 minutes' then
      return pg_catalog.jsonb_build_object('ok', false, 'format', true);
    end if;
    v_classe := 'ambigu';
    if v_type in ('complaint', 'unsubscribe') then v_priorite := 1; end if;
    if v_id !~ '^[A-Za-z0-9:_./-]{1,200}$' then
      return pg_catalog.jsonb_build_object('ok', false, 'format', true);
    end if;
    v_id_stocke := v_id;
  end if;

  v_cle := public.lire_reglage('communication_cle_webhook');
  if coalesce(v_cle, '') = ''
     or p_signature <> pg_catalog.encode(
       extensions.hmac(p_fournisseur || ':' || p_charge, v_cle, 'sha256'), 'hex') then
    return pg_catalog.jsonb_build_object('ok', false);
  end if;
  perform pg_catalog.set_config('synchronous_commit', 'on', true);

  insert into public.communication_evenements_fournisseur
    (fournisseur, evenement_id, type, message_id, code, survenu_le)
  values (p_fournisseur, v_id_stocke, v_type, left(v_message_id, 200), left(v_code, 60), v_survenu)
  on conflict (fournisseur, evenement_id) do nothing
  returning id into v_evenement;
  if v_evenement is null then
    return pg_catalog.jsonb_build_object('ok', true, 'rejeu', true);
  end if;
  insert into public.communication_evenements_traitement
    (evenement_id, etat, priorite, classe, cible_empreinte)
  values (v_evenement, 'a_traiter', v_priorite, v_classe, v_empreinte);
  return pg_catalog.jsonb_build_object('ok', true, 'enregistre', true, 'traite', false);
end
$fonction$;

-- Le préverrouillage N3/N3b précède le verrou N3c de la ligne de file. Le même
-- appel RPC conserve SKIP LOCKED, effets P-09 et état final dans une transaction.
create or replace function public.communication_traiter_evenement(p_evenement bigint)
returns text
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'
as $fonction$
declare
  v_file public.communication_evenements_traitement;
  v_evenement public.communication_evenements_fournisseur;
  v_client uuid;
  v_consentement record;
  v_demande record;
begin
  select * into v_file from public.communication_evenements_traitement
   where evenement_id = p_evenement;
  if not found or v_file.etat <> 'a_traiter' then return 'DEJA_TRAITE'; end if;
  select * into v_evenement from public.communication_evenements_fournisseur
   where id = p_evenement;
  if not found then return 'EVENEMENT_ABSENT'; end if;

  if v_evenement.type = 'inbound' and v_file.classe = 'stop'
     and v_file.cible_empreinte is not null then
    for v_client in
      select c.id from public.clients c
       where c.role = 'client'
         and public.communication_consentement_empreinte(
               nullif(public.telephone_international(c.telephone, c.pays), '')) = v_file.cible_empreinte
       order by c.id
    loop
      perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended('goship:consent-account:' || v_client::text, 0));
    end loop;
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('goship:whatsapp:' || v_file.cible_empreinte, 0));
  end if;

  select * into v_file from public.communication_evenements_traitement
   where evenement_id = p_evenement for update skip locked;
  if not found then return 'DEJA_PRIS'; end if;
  if v_file.etat <> 'a_traiter' then return 'DEJA_TRAITE'; end if;
  select * into v_evenement from public.communication_evenements_fournisseur
   where id = p_evenement;

  if v_evenement.type = 'inbound' and v_file.classe = 'stop'
     and v_file.cible_empreinte is not null then
    insert into public.communication_contact_suppressions
      (canal, cible_empreinte, raison, evenement_id)
    values ('whatsapp', v_file.cible_empreinte, 'stop', p_evenement)
    on conflict (canal, cible_empreinte) where leve_le is null do nothing;

    for v_demande in
      select d.id, d.code_secret_id
        from public.communication_confirmations_whatsapp d
       where d.cible_empreinte = v_file.cible_empreinte and d.etat = 'en_attente'
       order by d.client_id, d.id for update
    loop
      delete from vault.secrets where id = v_demande.code_secret_id;
      update public.communication_confirmations_whatsapp
         set etat = 'annule', code_secret_id = null, termine_le = clock_timestamp()
       where id = v_demande.id and etat = 'en_attente';
    end loop;

    for v_consentement in
      select c.* from public.communication_consentements_clients c
       where c.canal = 'whatsapp' and c.finalite = 'marketing'
         and c.cible_empreinte = v_file.cible_empreinte
         and c.etat in ('en_attente', 'confirme')
       order by c.client_id, c.id for update
    loop
      update public.communication_consentements_clients
         set etat = 'retire', retire_le = clock_timestamp(), maj_le = clock_timestamp()
       where id = v_consentement.id;
      insert into public.communication_consentement_historique
        (consentement_id, demande_id, client_id, canal, finalite, action, source,
         cible_empreinte, texte_version, texte_empreinte, langue)
      values (v_consentement.id, v_consentement.demande_id, v_consentement.client_id,
              'whatsapp', 'marketing', 'retrait', 'whatsapp_stop',
              v_consentement.cible_empreinte, v_consentement.texte_version,
              v_consentement.texte_empreinte, v_consentement.langue);
    end loop;

    update public.communication_evenements_traitement
       set etat = 'traite', traite_le = clock_timestamp(), resultat = 'STOP_APPLIQUE',
           cible_empreinte = null, code_confirmation = null
     where evenement_id = p_evenement;
    return 'STOP_APPLIQUE';
  elsif v_evenement.type in ('complaint', 'unsubscribe') then
    -- Les candidates présentes ne définissent pas le rapprochement d'un retour
    -- marketing Email avec une identité GoShip. Garder la priorité bloquante.
    update public.communication_evenements_traitement
       set etat = 'echec', tentatives = tentatives + 1,
           dernier_code = 'P0901', resultat = 'CORRELATION_REQUISE'
     where evenement_id = p_evenement;
    return 'CORRELATION_REQUISE';
  else
    update public.communication_evenements_traitement
       set etat = 'traite', traite_le = clock_timestamp(),
           resultat = case when v_evenement.type = 'inbound'
                           then 'ENTRANT_SANS_ACTION_AUTOMATIQUE'
                           else 'RETOUR_INFORMATIF' end,
           cible_empreinte = null, code_confirmation = null
     where evenement_id = p_evenement;
    return 'TRAITE_SANS_EFFET';
  end if;
end
$fonction$;

create or replace function public.communication_traiter_evenements_prioritaires(p_limite integer default 50)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'
as $fonction$
declare
  v_evenement bigint;
  v_resultat text;
  v_traites integer := 0;
  v_echecs integer := 0;
  v_sqlstate text;
  v_attente integer;
begin
  for v_evenement in
    select q.evenement_id
      from public.communication_evenements_traitement q
      join public.communication_evenements_fournisseur e on e.id = q.evenement_id
     where q.etat = 'a_traiter'
       and q.prochain_essai_le <= clock_timestamp()
       and e.type not in ('sent', 'delivered', 'read', 'failed', 'hard_bounce', 'blocked')
     order by q.priorite, q.cree_le, q.evenement_id
     limit least(greatest(coalesce(p_limite, 50), 1), 50)
  loop
    begin
      v_resultat := public.communication_traiter_evenement(v_evenement);
      if v_resultat = 'CORRELATION_REQUISE' then
        v_echecs := v_echecs + 1;
      elsif v_resultat in ('STOP_APPLIQUE', 'TRAITE_SANS_EFFET') then
        v_traites := v_traites + 1;
      end if;
    exception
      when lock_not_available or deadlock_detected or serialization_failure or query_canceled then
        get stacked diagnostics v_sqlstate = returned_sqlstate;
        update public.communication_evenements_traitement
           set tentatives = tentatives + 1,
               dernier_code = v_sqlstate,
               etat = case when tentatives + 1 >= 5 then 'echec' else 'a_traiter' end,
               prochain_essai_le = clock_timestamp() +
                 make_interval(mins => case tentatives + 1 when 1 then 1 when 2 then 2
                                         when 3 then 5 else 15 end),
               resultat = case when tentatives + 1 >= 5 then 'LIMITE_TENTATIVES' else 'REESSAI' end
         where evenement_id = v_evenement and etat = 'a_traiter';
        v_echecs := v_echecs + 1;
      when others then
        get stacked diagnostics v_sqlstate = returned_sqlstate;
        update public.communication_evenements_traitement
           set tentatives = tentatives + 1, dernier_code = v_sqlstate,
               etat = 'echec', resultat = 'A_REVOIR'
         where evenement_id = v_evenement and etat = 'a_traiter';
        v_echecs := v_echecs + 1;
    end;
  end loop;
  select count(*)::integer into v_attente
    from public.communication_evenements_traitement
   where priorite = 1 and etat <> 'traite';
  return pg_catalog.jsonb_build_object('ok', true, 'traites', v_traites,
    'echecs', v_echecs, 'prioritaire_en_attente', v_attente);
end
$fonction$;

-- Expo conserve le ticket dans notification_envois.message_id. Ces colonnes
-- enrichissent l'unique outbox ; elles ne créent pas une seconde file.
alter table public.notification_envois
  add column if not exists expo_recu_etat text
    check (expo_recu_etat is null or expo_recu_etat in ('handoff_confirmed', 'failed', 'expired')),
  add column if not exists expo_recu_code text
    check (expo_recu_code is null or expo_recu_code in ('DEVICE_NOT_REGISTERED', 'EXPO_RECEIPT_ERROR')),
  add column if not exists expo_recu_le timestamptz;

create table if not exists public.communication_expo_recus_historique (
  id                    bigint generated always as identity primary key,
  notification_envoi_id bigint not null references public.notification_envois(id) on delete cascade,
  etat                  text not null check (etat in ('handoff_confirmed', 'failed', 'expired')),
  code                  text check (code is null or code in ('DEVICE_NOT_REGISTERED', 'EXPO_RECEIPT_ERROR')),
  cree_le               timestamptz not null default clock_timestamp(),
  unique (notification_envoi_id, etat)
);
alter table public.communication_expo_recus_historique enable row level security;
revoke all on public.communication_expo_recus_historique from public, anon, authenticated, service_role;

create or replace function public.communication_expo_recus_a_reconcilier(p_limite integer default 100)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fonction$
  select pg_catalog.jsonb_build_object('tickets', coalesce(
    (select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
       'id', e.message_id, 'accepted_at', e.envoye_le) order by e.envoye_le, e.id)
       from (select n.id, n.message_id, n.envoye_le
               from public.notification_envois n
              where n.canal = 'push' and n.fournisseur = 'expo' and n.statut = 'envoye'
                and n.message_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                and n.envoye_le <= clock_timestamp() - interval '15 minutes'
                and n.expo_recu_etat is null
              order by n.envoye_le, n.id
              limit least(greatest(coalesce(p_limite, 100), 1), 200)) e), '[]'::jsonb));
$fonction$;

create or replace function public.communication_expo_enregistrer_recus(p_resultats jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'
as $fonction$
declare
  v_resultat jsonb;
  v_ticket text;
  v_etat text;
  v_code text;
  v_envoi bigint;
  v_actuel text;
  v_mis_a_jour integer := 0;
begin
  if pg_catalog.jsonb_typeof(p_resultats) is distinct from 'array'
     or pg_catalog.jsonb_array_length(p_resultats) > 200 then
    return pg_catalog.jsonb_build_object('ok', false, 'format', true);
  end if;
  for v_resultat in select value from pg_catalog.jsonb_array_elements(p_resultats)
  loop
    v_ticket := v_resultat ->> 'ticket_id';
    v_etat := v_resultat ->> 'state';
    v_code := v_resultat ->> 'code';
    if coalesce(v_ticket, '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or coalesce(v_etat, '') not in ('pending', 'handoff_confirmed', 'failed', 'expired')
       or (v_code is not null and v_code not in ('DEVICE_NOT_REGISTERED', 'EXPO_RECEIPT_ERROR')) then
      return pg_catalog.jsonb_build_object('ok', false, 'format', true);
    end if;
    if v_etat = 'pending' then continue; end if;

    select n.id, n.expo_recu_etat into v_envoi, v_actuel
      from public.notification_envois n
     where n.canal = 'push' and n.fournisseur = 'expo' and n.statut = 'envoye'
       and n.message_id = v_ticket
     for update;
    if not found then
      return pg_catalog.jsonb_build_object('ok', false, 'ticket_inconnu', true);
    end if;
    if v_actuel is not null then
      if v_actuel <> v_etat then
        return pg_catalog.jsonb_build_object('ok', false, 'transition_invalide', true);
      end if;
      continue;
    end if;

    update public.notification_envois
       set expo_recu_etat = v_etat, expo_recu_code = v_code, expo_recu_le = clock_timestamp()
     where id = v_envoi;
    insert into public.communication_expo_recus_historique
      (notification_envoi_id, etat, code)
    values (v_envoi, v_etat, v_code)
    on conflict (notification_envoi_id, etat) do nothing;
    v_mis_a_jour := v_mis_a_jour + 1;
  end loop;
  return pg_catalog.jsonb_build_object('ok', true, 'mis_a_jour', v_mis_a_jour);
end
$fonction$;

create or replace function public.communication_worker_traiter_notifications(p_limite integer default 50)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fonction$
begin
  return public.traiter_notifications(least(greatest(coalesce(p_limite, 50), 1), 50));
end
$fonction$;

revoke all on function public.communication_recevoir_evenement(text,text,text),
  public.communication_traiter_evenement(bigint),
  public.communication_traiter_evenements_prioritaires(integer),
  public.communication_expo_recus_a_reconcilier(integer),
  public.communication_expo_enregistrer_recus(jsonb),
  public.communication_worker_traiter_notifications(integer)
  from public, anon, authenticated, service_role;
grant execute on function public.communication_recevoir_evenement(text,text,text)
  to communication_webhook;
grant execute on function public.communication_traiter_evenements_prioritaires(integer),
  public.communication_expo_recus_a_reconcilier(integer),
  public.communication_expo_enregistrer_recus(jsonb),
  public.communication_worker_traiter_notifications(integer)
  to communication_worker;

commit;
