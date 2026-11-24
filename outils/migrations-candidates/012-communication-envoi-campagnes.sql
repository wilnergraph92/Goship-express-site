-- C12 — Envoi des campagnes marketing par l'outbox unique, sous la porte de l'arrêt d'urgence.
-- Candidate uniquement : essais locaux et CI seulement. Ne pas appliquer à une base distante
-- (critère C14 de docs/production/go-no-go.md). Écrite le 24/11/2026 sur autorisation écrite
-- de la CEO (construction sur bases jetables, sans production ni fournisseur réel).
--
-- Ce qui part, et comment :
--   1. Une campagne approuvée et planifiée (008) devient « sending » à son heure.
--      communication_campagnes_lancer() la met en file : une ligne par destinataire et par
--      canal dans communication_campagne_destinataires, puis une notification et une ligne
--      notification_envois (statut « attente ») pour chaque destinataire retenu.
--   2. Le travailleur EXISTANT (traiter_notifications) transmet ces lignes comme les autres :
--      même porte P-07, même arrêt d'urgence, même confirmation d'arrêt qui compte les
--      lignes en cours. Aucun second travailleur, aucun second chemin réseau.
--   3. Au moment de transmettre, tout est revérifié : campagne non annulée, consentement
--      toujours confirmé pour le même contact, aucun STOP ni suppression. Sinon la ligne est
--      annulée avec un code MARKETING_* et rien ne part.
--
-- Règles :
--   * P-05 — sans doublon : un même contact (empreinte) ne reçoit qu'un message par campagne
--     et par canal, même s'il apparaît sous plusieurs comptes ;
--   * N-01 — fréquence : au plus N messages marketing par contact et par canal sur une
--     fenêtre glissante. N et la fenêtre sont des réglages SANS valeur par défaut : tant que
--     l'Admin ne les a pas posés, aucune campagne ne part (elle reste planifiée) ;
--   * quota : au plus le quota par canal de la révision approuvée ;
--   * numéro partagé (D2, « bloquer ») et toutes les exclusions de l'audience (008) ;
--   * aucun nouvel essai après un résultat incertain (5xx, silence) : un message marketing
--     reçu deux fois est une gêne pour le client, pas un service (décision K limitée au
--     transactionnel) ;
--   * e-mail : consentement marketing propre au canal, donné par le client connecté depuis son
--     compte (adresse confirmée, texte attesté), retirable depuis le compte ou par le lien de
--     désinscription présent dans CHAQUE e-mail marketing (et l'en-tête List-Unsubscribe).
--     Sans adresse officielle du site en https, aucun e-mail marketing ne part (pas de lien) ;
--   * push : inéligible (aucune source de consentement propre au canal) ;
--   * l'aperçu d'audience de 008 (ce que l'Admin approuve) et l'envoi utilisent la même règle
--     d'éligibilité, communication_campagne_motif_exclusion_calc ;
--   * WhatsApp : modèle approuvé par Meta, nommé par le réglage `whatsapp_modele_marketing`
--     (deux paramètres : prénom, texte de la campagne). Sans ce réglage, la ligne est
--     annulée (NON_CONFIGURE). Le modèle doit contenir la mention « Répondez STOP » : le STOP
--     est reconnu par P-08/P-09 (006).
--
-- Verrous (COMMUNICATION_CENTER_VERROUS_CANDIDATES.md) : le lancement prend la ligne de la
-- campagne (V3), puis, par contact et dans l'ordre croissant des empreintes, un verrou
-- consultatif propre au marketing `goship:marketing-frequence:<canal>:<empreinte>` (V3b),
-- puis crée des lignes neuves (V4). Il ne prend jamais V0, V1 ni V2. La transmission suit le
-- chemin existant du travailleur (V0 partagé, puis V4).

begin;

do $garde$
begin
  if pg_catalog.to_regclass('public.communication_campagnes_marketing') is null
     or pg_catalog.to_regclass('public.notification_envois') is null
     or pg_catalog.to_regclass('public.communication_consentements_clients') is null
     or pg_catalog.to_regprocedure('public.communication_expedier_envoi_sans_porte(public.notification_envois)') is null
     or pg_catalog.to_regprocedure('public.communication_campagne_critere_correspond(uuid,jsonb)') is null then
    raise exception 'COMMUNICATION_C12_DEPENDENCY_MISSING';
  end if;
end
$garde$;

-- 1. États et journal de la campagne --------------------------------------------
alter table public.communication_campagnes_marketing
  drop constraint if exists communication_campagnes_marketing_etat_check;
alter table public.communication_campagnes_marketing
  add constraint communication_campagnes_marketing_etat_check
  check (etat in ('draft', 'pending_approval', 'approved', 'scheduled', 'sending',
                  'cancelled', 'completed'));
alter table public.communication_campagnes_marketing
  add column if not exists envoi_commence_le timestamptz,
  add column if not exists envoi_termine_le timestamptz;

alter table public.communication_campagne_audit_marketing
  drop constraint if exists communication_campagne_audit_marketing_action_check;
alter table public.communication_campagne_audit_marketing
  add constraint communication_campagne_audit_marketing_action_check
  check (action in (
    'created', 'revision_saved', 'revision_duplicated', 'segment_saved',
    'model_version_created', 'audience_previewed', 'audience_invalidated',
    'submitted', 'approved', 'rejected', 'scheduled', 'cancelled',
    'sending_started', 'sending_completed', 'marketing_settings_changed'));

-- 2. Réglages de fréquence (N-01) : aucune valeur par défaut --------------------
create table if not exists public.communication_marketing_reglages (
  id                      boolean primary key default true check (id),
  frequence_max           integer check (frequence_max is null or frequence_max between 1 and 50),
  frequence_fenetre_heures integer check (frequence_fenetre_heures is null
                                          or frequence_fenetre_heures between 1 and 2160),
  maj_par                 uuid references public.clients(id) on delete set null,
  maj_le                  timestamptz not null default clock_timestamp()
);
insert into public.communication_marketing_reglages (id) values (true) on conflict (id) do nothing;
alter table public.communication_marketing_reglages enable row level security;
revoke all on public.communication_marketing_reglages from public, anon, authenticated, service_role;

-- 3. Destinataires d'une campagne (ni numéro ni adresse : l'empreinte seulement) ---
create table if not exists public.communication_campagne_destinataires (
  id                bigint generated always as identity primary key,
  campagne_id       bigint not null references public.communication_campagnes_marketing(id) on delete restrict,
  revision_id       bigint not null references public.communication_campagne_revisions_marketing(id) on delete restrict,
  client_id         uuid not null references public.clients(id) on delete cascade,
  canal             text not null check (canal in ('email', 'whatsapp', 'push')),
  cible_empreinte   text,
  etat              text not null check (etat in ('en_file', 'exclu')),
  motif_exclusion   text check (motif_exclusion is null or motif_exclusion ~ '^[a-z_]{1,60}$'),
  envoi_id          bigint,
  cree_le           timestamptz not null default clock_timestamp(),
  check ((etat = 'exclu') = (motif_exclusion is not null)),
  check (etat <> 'en_file' or cible_empreinte is not null)
);
-- P-05 : un seul message par contact, par campagne et par canal.
create unique index if not exists communication_campagne_destinataires_unique_idx
  on public.communication_campagne_destinataires (campagne_id, canal, cible_empreinte)
  where etat = 'en_file';
-- N-01 : comptage par contact sur la fenêtre.
create index if not exists communication_campagne_destinataires_frequence_idx
  on public.communication_campagne_destinataires (canal, cible_empreinte, cree_le)
  where etat = 'en_file';
create index if not exists communication_campagne_destinataires_campagne_idx
  on public.communication_campagne_destinataires (campagne_id, canal, etat);
alter table public.communication_campagne_destinataires enable row level security;
revoke all on public.communication_campagne_destinataires from public, anon, authenticated, service_role;

-- Lien de la ligne d'outbox vers son destinataire marketing (sans clé étrangère :
-- aucun FOR KEY SHARE implicite sur le chemin du travailleur, voir Q3).
alter table public.notification_envois
  add column if not exists communication_campagne_destinataire_id bigint;
create index if not exists notification_envois_campagne_destinataire_idx
  on public.notification_envois (communication_campagne_destinataire_id)
  where communication_campagne_destinataire_id is not null;

-- 3 bis. Le consentement marketing par e-mail --------------------------------------
-- Les tables de 003 et 006 n'acceptaient que WhatsApp. Elles acceptent désormais l'e-mail ;
-- les codes de confirmation restent propres à WhatsApp.
do $canaux$
declare
  v record;
begin
  for v in select * from (values
      ('communication_consentements_clients', 'communication_consentements_clients_canal_check',
       'check (canal in (''whatsapp'', ''email''))'),
      ('communication_consentement_textes', 'communication_consentement_textes_canal_check',
       'check (canal in (''whatsapp'', ''email''))'),
      ('communication_consentement_historique', 'communication_consentement_historique_canal_check',
       'check (canal in (''whatsapp'', ''email''))'),
      ('communication_contact_suppressions', 'communication_contact_suppressions_canal_check',
       'check (canal in (''whatsapp'', ''email''))'),
      ('communication_contact_suppressions', 'communication_contact_suppressions_raison_check',
       'check (raison in (''stop'', ''desabonnement''))')) as x(tab, nom, def)
  loop
    execute pg_catalog.format('alter table public.%I drop constraint if exists %I', v.tab, v.nom);
    execute pg_catalog.format('alter table public.%I add constraint %I %s', v.tab, v.nom, v.def);
  end loop;
end
$canaux$;

-- Empreinte d'une adresse e-mail : même poivre que les numéros, préfixe distinct. Aucune
-- adresse n'est gardée dans les tables du Centre de communication.
create or replace function public.communication_courriel_empreinte(p_client uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare
  v_email text;
  v_poivre text := public.lire_reglage('communication_poivre');
begin
  select pg_catalog.lower(pg_catalog.btrim(c.email)) into v_email
    from public.clients c where c.id = p_client and c.role = 'client';
  if length(coalesce(v_poivre, '')) < 32 or not public.communication_adresse_courriel_valide(v_email) then
    return null;
  end if;
  return encode(extensions.hmac('goship:communication:email:v1:' || v_email, v_poivre, 'sha256'), 'hex');
end
$fonction$;

create or replace function public.communication_campagne_empreinte(p_client uuid, p_canal text)
returns text
language sql
stable
security definer
set search_path = ''
as $fonction$
  select case p_canal
    when 'whatsapp' then public.communication_consentement_empreinte(
                           public.communication_consentement_cible(p_client))
    when 'email' then public.communication_courriel_empreinte(p_client)
    else null
  end
$fonction$;

-- 4. Éligibilité d'un client à un canal marketing --------------------------------
-- Mêmes règles que le calcul d'audience de 008 (classes identiques). Renvoie null si le
-- client est éligible, sinon le motif d'exclusion.
-- Version de calcul : l'empreinte du contact et le nombre de comptes qui la partagent sont
-- fournis par l'appelant (le lancement les calcule une seule fois pour toute l'audience).
create or replace function public.communication_campagne_motif_exclusion_calc(
  p_client uuid, p_canal text, p_empreinte text, p_comptes bigint)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare
  v_consent public.communication_consentements_clients;
begin
  if p_canal not in ('whatsapp', 'email') then
    return 'consentement_non_verifiable';
  end if;
  if p_empreinte is null then
    return 'contact_non_verifiable';
  end if;
  if coalesce(p_comptes, 0) > 1 then
    return 'contact_partage_ambigu';
  end if;
  if exists (select 1 from public.communication_contact_suppressions s
              where s.canal = p_canal and s.cible_empreinte = p_empreinte
                and s.leve_le is null) then
    return 'suppression_active';
  end if;
  select * into v_consent
    from public.communication_consentements_clients k
   where k.client_id = p_client and k.canal = p_canal and k.finalite = 'marketing';
  if not found then return 'sans_consentement'; end if;
  if v_consent.etat = 'retire' then return 'consentement_retire'; end if;
  if v_consent.etat = 'expire' then return 'consentement_expire'; end if;
  if v_consent.etat <> 'confirme' then return 'consentement_non_confirme'; end if;
  if v_consent.cible_empreinte is distinct from p_empreinte then return 'contact_modifie'; end if;
  if v_consent.confirme_le is null then return 'consentement_invalide'; end if;
  return null;
end
$fonction$;

-- Version pour un seul client (revérification au moment de transmettre).
create or replace function public.communication_campagne_motif_exclusion(p_client uuid, p_canal text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare
  v_empreinte text;
  v_comptes bigint;
begin
  if not exists (select 1 from public.clients c where c.id = p_client and c.role = 'client') then
    return 'compte_inexistant';
  end if;
  v_empreinte := public.communication_campagne_empreinte(p_client, p_canal);
  if v_empreinte is not null then
    select count(*) into v_comptes
      from public.clients c
     where c.role = 'client'
       and public.communication_campagne_empreinte(c.id, p_canal) = v_empreinte;
  end if;
  return public.communication_campagne_motif_exclusion_calc(p_client, p_canal, v_empreinte, v_comptes);
end
$fonction$;

-- 5. Réglages : lecture et modification par l'Admin --------------------------------
create or replace function public.communication_marketing_reglages_lire()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare
  v public.communication_marketing_reglages;
begin
  perform public.exiger_permission('communications.campaigns.view');
  select * into v from public.communication_marketing_reglages where id is true;
  return pg_catalog.jsonb_build_object(
    'frequence_max', v.frequence_max,
    'frequence_fenetre_heures', v.frequence_fenetre_heures,
    'configure', v.frequence_max is not null and v.frequence_fenetre_heures is not null,
    'maj_le', v.maj_le);
end
$fonction$;

create or replace function public.communication_marketing_reglages_definir(
  p_frequence_max integer, p_fenetre_heures integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'
as $fonction$
declare
  v_acteur uuid := auth.uid();
begin
  perform public.exiger_permission('settings.manage');
  if p_frequence_max is null or p_frequence_max not between 1 and 50
     or p_fenetre_heures is null or p_fenetre_heures not between 1 and 2160 then
    raise exception 'COMMUNICATION_MARKETING_SETTINGS_INVALID';
  end if;
  update public.communication_marketing_reglages
     set frequence_max = p_frequence_max, frequence_fenetre_heures = p_fenetre_heures,
         maj_par = v_acteur, maj_le = clock_timestamp()
   where id is true;
  return public.communication_marketing_reglages_lire();
end
$fonction$;

-- 5 bis. Consentement e-mail du client, et désinscription par le lien -----------------
-- Jeton de désinscription : HMAC de l'identifiant du destinataire, impossible à deviner,
-- sans donnée personnelle dans le lien.
create or replace function public.communication_desabonnement_jeton(p_destinataire bigint)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare
  v_poivre text := public.lire_reglage('communication_poivre');
begin
  if length(coalesce(v_poivre, '')) < 32 or p_destinataire is null then
    raise exception 'NON_CONFIGURE';
  end if;
  return encode(extensions.hmac('goship:desabonnement:v1:' || p_destinataire::text, v_poivre, 'sha256'), 'hex');
end
$fonction$;

-- Ouvert aux visiteurs : le lien de l'e-mail suffit, sans connexion. Réponse identique que
-- le jeton soit bon ou non, hormis « ok », et jamais de donnée du client.
create or replace function public.communication_desabonner_courriel(p_destinataire bigint, p_jeton text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'
as $fonction$
declare
  v_dest public.communication_campagne_destinataires;
  v_consent public.communication_consentements_clients;
begin
  if p_destinataire is null or coalesce(p_jeton, '') !~ '^[0-9a-f]{64}$'
     or p_jeton <> public.communication_desabonnement_jeton(p_destinataire) then
    return pg_catalog.jsonb_build_object('ok', false);
  end if;
  select * into v_dest from public.communication_campagne_destinataires d
   where d.id = p_destinataire and d.canal = 'email';
  if not found or v_dest.cible_empreinte is null then
    return pg_catalog.jsonb_build_object('ok', false);
  end if;
  -- V1 (compte) puis V2 (contact), comme les autres chemins du consentement.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('goship:consent-account:' || v_dest.client_id::text, 0));
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('goship:email:' || v_dest.cible_empreinte, 0));
  insert into public.communication_contact_suppressions (canal, cible_empreinte, raison, evenement_id)
  values ('email', v_dest.cible_empreinte, 'desabonnement', v_dest.id)
  on conflict (canal, cible_empreinte) where leve_le is null do nothing;
  select * into v_consent from public.communication_consentements_clients k
   where k.client_id = v_dest.client_id and k.canal = 'email' and k.finalite = 'marketing'
   for update;
  if found and v_consent.etat <> 'retire' then
    update public.communication_consentements_clients
       set etat = 'retire', retire_le = clock_timestamp(), maj_le = clock_timestamp()
     where id = v_consent.id;
    insert into public.communication_consentement_historique
      (consentement_id, client_id, canal, action, source, cible_empreinte, texte_version, texte_empreinte, langue)
    values (v_consent.id, v_dest.client_id, 'email', 'retrait', 'desabonnement_courriel',
            v_dest.cible_empreinte, v_consent.texte_version, v_consent.texte_empreinte, v_consent.langue);
  end if;
  return pg_catalog.jsonb_build_object('ok', true);
end
$fonction$;

create or replace function public.communication_consentement_courriel_etat()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare
  v_moi uuid := auth.uid();
  v_consent public.communication_consentements_clients;
  v_empreinte text;
begin
  if v_moi is null or not exists (select 1 from public.clients c where c.id = v_moi and c.role = 'client') then
    raise exception 'PERMISSION_DENIED';
  end if;
  select * into v_consent from public.communication_consentements_clients k
   where k.client_id = v_moi and k.canal = 'email' and k.finalite = 'marketing';
  v_empreinte := public.communication_courriel_empreinte(v_moi);
  return pg_catalog.jsonb_build_object(
    'etat', coalesce(v_consent.etat, 'aucun'),
    'actif', found and v_consent.etat = 'confirme' and v_consent.cible_empreinte = v_empreinte,
    'adresse_valide', v_empreinte is not null);
end
$fonction$;

create or replace function public.communication_consentement_courriel_accorder(p_texte_version text, p_langue text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'
as $fonction$
declare
  v_moi uuid := auth.uid();
  v_texte public.communication_consentement_textes;
  v_empreinte text;
  v_id bigint;
begin
  if v_moi is null or not exists (select 1 from public.clients c where c.id = v_moi and c.role = 'client') then
    raise exception 'PERMISSION_DENIED';
  end if;
  -- L'adresse doit avoir été confirmée par le client (lien de confirmation du compte).
  if not exists (select 1 from auth.users u where u.id = v_moi and u.email_confirmed_at is not null) then
    raise exception 'EMAIL_NOT_CONFIRMED';
  end if;
  v_empreinte := public.communication_courriel_empreinte(v_moi);
  if v_empreinte is null then
    raise exception 'CONTACT_UNAVAILABLE';
  end if;
  select * into v_texte from public.communication_consentement_textes t
   where t.version = p_texte_version and t.canal = 'email' and t.langue = p_langue
     and t.statut = 'atteste_juridique';
  if not found then
    raise exception 'CONSENT_TEXT_NOT_APPROVED';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('goship:consent-account:' || v_moi::text, 0));
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('goship:email:' || v_empreinte, 0));
  insert into public.communication_consentements_clients
    (client_id, canal, finalite, etat, cible_empreinte, texte_version, texte_empreinte,
     langue, source, demande_le, confirme_le, retire_le)
  values (v_moi, 'email', 'marketing', 'confirme', v_empreinte, v_texte.version, v_texte.empreinte,
          p_langue, 'compte_web', clock_timestamp(), clock_timestamp(), null)
  on conflict (client_id, canal, finalite) do update
    set etat = 'confirme', cible_empreinte = excluded.cible_empreinte,
        texte_version = excluded.texte_version, texte_empreinte = excluded.texte_empreinte,
        langue = excluded.langue, source = 'compte_web', demande_le = excluded.demande_le,
        confirme_le = excluded.confirme_le, retire_le = null, maj_le = clock_timestamp()
  returning id into v_id;
  -- Un nouvel accord explicite du titulaire lève sa désinscription précédente.
  update public.communication_contact_suppressions
     set leve_le = clock_timestamp(), levee_par_consentement_id = v_id
   where canal = 'email' and cible_empreinte = v_empreinte and leve_le is null;
  insert into public.communication_consentement_historique
    (consentement_id, client_id, canal, action, source, cible_empreinte, texte_version, texte_empreinte, langue)
  values (v_id, v_moi, 'email', 'confirme', 'compte_web', v_empreinte, v_texte.version, v_texte.empreinte, p_langue);
  return public.communication_consentement_courriel_etat();
end
$fonction$;

create or replace function public.communication_consentement_courriel_retirer()
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'
as $fonction$
declare
  v_moi uuid := auth.uid();
  v_consent public.communication_consentements_clients;
begin
  if v_moi is null or not exists (select 1 from public.clients c where c.id = v_moi and c.role = 'client') then
    raise exception 'PERMISSION_DENIED';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('goship:consent-account:' || v_moi::text, 0));
  select * into v_consent from public.communication_consentements_clients k
   where k.client_id = v_moi and k.canal = 'email' and k.finalite = 'marketing' for update;
  if found and v_consent.etat <> 'retire' then
    update public.communication_consentements_clients
       set etat = 'retire', retire_le = clock_timestamp(), maj_le = clock_timestamp()
     where id = v_consent.id;
    insert into public.communication_consentement_historique
      (consentement_id, client_id, canal, action, source, cible_empreinte, texte_version, texte_empreinte, langue)
    values (v_consent.id, v_moi, 'email', 'retrait', 'compte_web', v_consent.cible_empreinte,
            v_consent.texte_version, v_consent.texte_empreinte, v_consent.langue);
  end if;
  return public.communication_consentement_courriel_etat();
end
$fonction$;

-- 5 ter. L'aperçu d'audience (008) suit la même règle que l'envoi ----------------------
-- Ce que l'Admin voit et approuve est exactement ce qui partira : mêmes motifs, mêmes
-- empreintes par canal. La forme du résultat ne change pas.
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
    with tous as materialized (
      select c.id, public.communication_campagne_empreinte(c.id, v_canal) as empreinte
        from public.clients c where c.role = 'client'
    ), partages as materialized (
      select t.empreinte, count(*)::bigint as comptes
        from tous t where t.empreinte is not null group by t.empreinte
    ), classes as (
      select t.id, public.communication_campagne_motif_exclusion_calc(t.id, v_canal, t.empreinte, ps.comptes) as motif
        from tous t
        left join partages ps on ps.empreinte = t.empreinte
       where public.communication_campagne_critere_correspond(t.id, v_revision.criteres_audience)
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
    'transmission_active', true,
    'empreinte_interne', v_empreinte);
end
$fonction$;

-- 6. Mise en file des campagnes arrivées à leur heure ------------------------------
create or replace function public.communication_campagnes_lancer(p_lot integer default 5)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'
as $fonction$
declare
  v_reg public.communication_marketing_reglages;
  v_campagne public.communication_campagnes_marketing;
  v_revision public.communication_campagne_revisions_marketing;
  v_canal text;
  v_quota bigint;
  v_en_file bigint;
  v_total_en_file bigint;
  r record;
  v_motif text;
  v_dest_id bigint;
  v_notification_id bigint;
  v_envoi_id bigint;
  v_lancees integer := 0;
  v_en_attente_reglage integer := 0;
  v_mises_en_file bigint := 0;
  v_exclues bigint := 0;
  v_terminees integer := 0;
  v_acteur uuid;
begin
  select * into v_reg from public.communication_marketing_reglages where id is true;

  for v_campagne in
    select c.* from public.communication_campagnes_marketing c
     where c.etat = 'scheduled' and c.planifiee_pour <= clock_timestamp()
     order by c.planifiee_pour, c.id
     limit greatest(coalesce(p_lot, 5), 1)
     for update of c skip locked
  loop
    -- N-01 non réglée : rien ne part, la campagne reste planifiée.
    if v_reg.frequence_max is null or v_reg.frequence_fenetre_heures is null then
      v_en_attente_reglage := v_en_attente_reglage + 1;
      continue;
    end if;
    select * into v_revision from public.communication_campagne_revisions_marketing rv
     where rv.id = v_campagne.revision_approuvee_id;
    if not found then
      raise exception 'COMMUNICATION_CAMPAIGN_REVISION_NOT_FOUND';
    end if;
    v_acteur := v_campagne.approuvee_par;
    update public.communication_campagnes_marketing
       set etat = 'sending', envoi_commence_le = clock_timestamp(), maj_le = clock_timestamp()
     where id = v_campagne.id;
    v_total_en_file := 0;

    foreach v_canal in array v_revision.canaux loop
      v_quota := nullif(v_revision.quotas_par_canal ->> v_canal, '')::bigint;
      v_en_file := 0;
      -- Ordre croissant des empreintes : deux lancements simultanés prennent les verrous
      -- V3b dans le même ordre (aucun cycle).
      for r in
        with tous as materialized (
          select c.id, public.communication_campagne_empreinte(c.id, v_canal) as empreinte
            from public.clients c
           where c.role = 'client'
        ), partages as materialized (
          select t.empreinte, count(*)::bigint as comptes
            from tous t where t.empreinte is not null group by t.empreinte
        )
        select t.id, t.empreinte, ps.comptes
          from tous t
          left join partages ps on ps.empreinte = t.empreinte
         where public.communication_campagne_critere_correspond(t.id, v_revision.criteres_audience)
         order by t.empreinte nulls last, t.id
      loop
        v_motif := public.communication_campagne_motif_exclusion_calc(r.id, v_canal, r.empreinte, r.comptes);
        if v_motif is null then
          perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
            'goship:marketing-frequence:' || v_canal || ':' || r.empreinte, 0));
          if exists (select 1 from public.communication_campagne_destinataires d
                      where d.campagne_id = v_campagne.id and d.canal = v_canal
                        and d.cible_empreinte = r.empreinte and d.etat = 'en_file') then
            v_motif := 'doublon_contact';
          elsif (select count(*) from public.communication_campagne_destinataires d
                  where d.canal = v_canal and d.cible_empreinte = r.empreinte
                    and d.etat = 'en_file'
                    and d.cree_le > clock_timestamp()
                                    - pg_catalog.make_interval(hours => v_reg.frequence_fenetre_heures))
                >= v_reg.frequence_max then
            v_motif := 'frequence';
          elsif v_quota is not null and v_en_file >= v_quota then
            v_motif := 'quota';
          end if;
        end if;

        if v_motif is not null then
          insert into public.communication_campagne_destinataires
            (campagne_id, revision_id, client_id, canal, cible_empreinte, etat, motif_exclusion)
          values (v_campagne.id, v_revision.id, r.id, v_canal, r.empreinte, 'exclu', v_motif);
          v_exclues := v_exclues + 1;
          continue;
        end if;

        insert into public.communication_campagne_destinataires
          (campagne_id, revision_id, client_id, canal, cible_empreinte, etat)
        values (v_campagne.id, v_revision.id, r.id, v_canal, r.empreinte, 'en_file')
        returning id into v_dest_id;

        insert into public.notifications
          (client_id, canal, evenement, destinataire, type, categorie, priorite, cle, donnees)
        values (r.id, v_canal, 'campagne_marketing', v_canal, 'campagne_marketing', 'marketing',
                'normale', 'campagne:' || v_dest_id::text,
                pg_catalog.jsonb_build_object('campagne_id', v_campagne.id,
                  'revision_id', v_revision.id, 'destinataire_id', v_dest_id))
        returning id into v_notification_id;

        insert into public.notification_envois
          (notification_id, canal, cible, fournisseur, statut, priorite,
           communication_campagne_destinataire_id)
        values (v_notification_id, v_canal, v_canal,
                case v_canal when 'whatsapp' then 'meta' else '' end,
                'attente', 'normale', v_dest_id)
        returning id into v_envoi_id;

        update public.communication_campagne_destinataires
           set envoi_id = v_envoi_id where id = v_dest_id;
        v_en_file := v_en_file + 1;
        v_mises_en_file := v_mises_en_file + 1;
      end loop;
      v_total_en_file := v_total_en_file + v_en_file;
    end loop;

    insert into public.communication_campagne_audit_marketing
      (campagne_id, revision_id, action, acteur, details)
    values (v_campagne.id, v_revision.id, 'sending_started', v_acteur,
            pg_catalog.jsonb_build_object('mis_en_file', v_total_en_file));
    v_lancees := v_lancees + 1;
  end loop;

  -- Clôture : une campagne en cours dont aucune ligne n'est plus en attente ni en
  -- transmission est terminée.
  for v_campagne in
    select c.* from public.communication_campagnes_marketing c
     where c.etat = 'sending'
       and not exists (
         select 1 from public.communication_campagne_destinataires d
           join public.notification_envois e on e.id = d.envoi_id
          where d.campagne_id = c.id and e.statut in ('attente', 'envoi'))
     for update of c skip locked
  loop
    update public.communication_campagnes_marketing
       set etat = 'completed', envoi_termine_le = clock_timestamp(), maj_le = clock_timestamp()
     where id = v_campagne.id;
    insert into public.communication_campagne_audit_marketing
      (campagne_id, revision_id, action, acteur, details)
    values (v_campagne.id, v_campagne.revision_approuvee_id, 'sending_completed',
            v_campagne.approuvee_par, '{}'::jsonb);
    v_terminees := v_terminees + 1;
  end loop;

  return pg_catalog.jsonb_build_object(
    'lancees', v_lancees, 'en_attente_reglage', v_en_attente_reglage,
    'mises_en_file', v_mises_en_file, 'exclues', v_exclues, 'terminees', v_terminees);
end
$fonction$;

-- 7. Annulation d'une campagne en cours : ses lignes encore en attente sont annulées ---
-- (V3 campagne, puis V4 en SKIP LOCKED : une ligne tenue par le travailleur sera de
-- toute façon refusée par la revérification au moment de transmettre.)
create or replace function public.communication_campagne_annulation_envois()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fonction$
begin
  if new.etat = 'cancelled' and old.etat is distinct from 'cancelled' then
    update public.notification_envois e
       set statut = 'annule', code_erreur = 'MARKETING_CAMPAGNE_ANNULEE', maj_le = clock_timestamp()
     where e.id in (
       select q.id from public.notification_envois q
         join public.communication_campagne_destinataires d on d.envoi_id = q.id
        where d.campagne_id = new.id and q.statut = 'attente'
        for update of q skip locked);
  end if;
  return new;
end
$fonction$;
drop trigger if exists communication_campagne_annulation_envois
  on public.communication_campagnes_marketing;
create trigger communication_campagne_annulation_envois
  after update of etat on public.communication_campagnes_marketing
  for each row execute function public.communication_campagne_annulation_envois();

-- 8. Adaptateur marketing (appelé par expedier_envoi, après la porte) --------------
create or replace function public.communication_campagne_expedier_sans_porte(p_envoi public.notification_envois)
returns bigint
language plpgsql
security definer
set search_path = ''
as $fonction$
declare
  v_dest public.communication_campagne_destinataires;
  v_campagne public.communication_campagnes_marketing;
  v_revision public.communication_campagne_revisions_marketing;
  v_modele_ref jsonb;
  v_traductions jsonb;
  v_client public.clients;
  v_langue text;
  v_texte jsonb;
  v_corps text;
  v_motif text;
  v_modele_meta text;
  v_telephone text;
  v_requete bigint;
  v_site text;
  v_lien_desabo text;
  v_mots jsonb;
  v_prenom text;
  v_html text;
  v_texte_brut text;
  v_cle text;
  v_expediteur text;
  v_nom_expediteur text;
  v_entetes jsonb;
begin
  select * into v_dest from public.communication_campagne_destinataires d
   where d.id = p_envoi.communication_campagne_destinataire_id;
  if not found or v_dest.etat <> 'en_file' then
    raise exception 'MARKETING_DESTINATAIRE_INCONNU';
  end if;
  select * into v_campagne from public.communication_campagnes_marketing c
   where c.id = v_dest.campagne_id;
  if v_campagne.etat <> 'sending' then
    raise exception 'MARKETING_CAMPAGNE_ANNULEE';
  end if;
  -- Revérification au moment de transmettre : consentement, STOP, contact, partage.
  v_motif := public.communication_campagne_motif_exclusion(v_dest.client_id, p_envoi.canal);
  if v_motif is null
     and public.communication_campagne_empreinte(v_dest.client_id, p_envoi.canal)
         is distinct from v_dest.cible_empreinte then
    v_motif := 'contact_modifie';
  end if;
  if v_motif is not null then
    raise exception '%', 'MARKETING_' || pg_catalog.upper(v_motif);
  end if;

  select * into v_revision from public.communication_campagne_revisions_marketing rv
   where rv.id = v_dest.revision_id;
  select x.element into v_modele_ref
    from pg_catalog.jsonb_array_elements(v_revision.modeles) as x(element)
   where x.element ->> 'canal' = p_envoi.canal;
  select m.traductions into v_traductions
    from public.communication_campagne_modeles_marketing m
   where m.id = (v_modele_ref ->> 'id')::bigint;
  select * into v_client from public.clients c where c.id = v_dest.client_id;
  v_langue := public.langue_notification(v_client.langue);
  v_texte := coalesce(v_traductions -> v_langue, v_traductions -> v_revision.langue, v_traductions -> 'fr');

  if p_envoi.canal = 'whatsapp' then
    if not public.canal_configure('whatsapp') then
      raise exception 'NON_CONFIGURE';
    end if;
    v_modele_meta := public.lire_reglage('whatsapp_modele_marketing');
    if coalesce(v_modele_meta, '') !~ '^[a-z0-9_]{1,255}$' then
      raise exception 'NON_CONFIGURE';
    end if;
    v_telephone := public.telephone_international(v_client.telephone, v_client.pays);
    if coalesce(v_telephone, '') = '' then
      raise exception 'SANS_DESTINATAIRE';
    end if;
    -- Meta refuse sauts de ligne, tabulations et plus de quatre espaces dans un paramètre.
    v_corps := left(pg_catalog.regexp_replace(
                 (v_texte ->> 'titre') || ' — ' || (v_texte ->> 'message'), '\s+', ' ', 'g'), 1024);
    select net.http_post(
      url := 'https://graph.facebook.com/' || coalesce(nullif(public.lire_reglage('whatsapp_version'), ''), 'v23.0') ||
             '/' || public.lire_reglage('whatsapp_numero_id') || '/messages',
      headers := pg_catalog.jsonb_build_object('Authorization', 'Bearer ' || public.lire_reglage('whatsapp_jeton'),
                                               'Content-Type', 'application/json'),
      body := pg_catalog.jsonb_build_object(
        'messaging_product', 'whatsapp', 'to', v_telephone, 'type', 'template',
        'template', pg_catalog.jsonb_build_object(
          'name', v_modele_meta,
          'language', pg_catalog.jsonb_build_object('code',
            case v_langue when 'en' then 'en_US' when 'es' then 'es' else 'fr' end),
          'components', pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
            'type', 'body', 'parameters', pg_catalog.jsonb_build_array(
              pg_catalog.jsonb_build_object('type', 'text',
                'text', coalesce(nullif(split_part(coalesce(v_client.nom_complet, ''), ' ', 1), ''), '—')),
              pg_catalog.jsonb_build_object('type', 'text', 'text', v_corps))))))
    ) into v_requete;
    return v_requete;
  end if;

  if p_envoi.canal = 'email' then
    if not public.canal_configure('email') then
      raise exception 'NON_CONFIGURE';
    end if;
    v_site := coalesce(public.lire_reglage('site_url'), '');
    -- Sans adresse officielle en https, aucun lien de désinscription : rien ne part.
    if v_site !~ '^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~/-]*)?$' then
      raise exception 'NON_CONFIGURE';
    end if;
    if not public.communication_adresse_courriel_valide(v_client.email) then
      raise exception 'SANS_DESTINATAIRE';
    end if;
    v_lien_desabo := pg_catalog.regexp_replace(v_site, '/?$', '/') || 'desabonnement.html?d='
      || v_dest.id::text || '&j=' || public.communication_desabonnement_jeton(v_dest.id);
    v_mots := case v_langue
      when 'en' then pg_catalog.jsonb_build_object('salut', 'Hello', 'desabo',
        'You receive this message because you agreed to GoShip Express offers. Unsubscribe:')
      when 'es' then pg_catalog.jsonb_build_object('salut', 'Hola', 'desabo',
        'Recibe este mensaje porque aceptó las ofertas de GoShip Express. Darse de baja:')
      when 'ht' then pg_catalog.jsonb_build_object('salut', 'Bonjou', 'desabo',
        'Ou resevwa mesaj sa a paske ou te dakò pou resevwa òf GoShip Express. Dezabone:')
      else pg_catalog.jsonb_build_object('salut', 'Bonjour', 'desabo',
        'Vous recevez ce message parce que vous avez accepté les offres de GoShip Express. Se désabonner :')
    end;
    v_prenom := coalesce(nullif(split_part(coalesce(v_client.nom_complet, ''), ' ', 1), ''), '');
    v_html := public.courriel_gabarit(v_langue, v_texte ->> 'titre',
      pg_catalog.btrim((v_mots ->> 'salut') || ' ' || v_prenom) || ',',
      '<p style="margin:0;font-size:16px;line-height:1.6">' || public.html_echappe(v_texte ->> 'message') || '</p>'
      || '<p style="margin:24px 0 0;font-size:12px;line-height:1.5;color:#6b7280">'
      || public.html_echappe(v_mots ->> 'desabo') || ' <a href="' || public.html_echappe(v_lien_desabo)
      || '" style="color:#6b7280">' || public.html_echappe(v_lien_desabo) || '</a></p>',
      '', '', '');
    v_texte_brut := pg_catalog.btrim((v_mots ->> 'salut') || ' ' || v_prenom) || E',\n\n'
      || (v_texte ->> 'message') || E'\n\n' || (v_mots ->> 'desabo') || ' ' || v_lien_desabo
      || E'\n\n— Goship Express';
    v_cle := public.lire_reglage('email_cle_api');
    v_expediteur := public.lire_reglage('email_expediteur');
    v_nom_expediteur := coalesce(nullif(public.lire_reglage('email_nom'), ''), 'Goship Express');
    v_entetes := pg_catalog.jsonb_build_object('List-Unsubscribe', '<' || v_lien_desabo || '>');
    if coalesce(nullif(public.lire_reglage('email_fournisseur'), ''), 'brevo') = 'resend' then
      select net.http_post(
        url := 'https://api.resend.com/emails',
        headers := pg_catalog.jsonb_build_object('Authorization', 'Bearer ' || v_cle, 'Content-Type', 'application/json'),
        body := pg_catalog.jsonb_build_object('from', v_nom_expediteur || ' <' || v_expediteur || '>',
          'to', pg_catalog.jsonb_build_array(v_client.email), 'subject', v_texte ->> 'titre',
          'html', v_html, 'text', v_texte_brut, 'headers', v_entetes)
      ) into v_requete;
    else
      select net.http_post(
        url := 'https://api.brevo.com/v3/smtp/email',
        headers := pg_catalog.jsonb_build_object('api-key', v_cle, 'Content-Type', 'application/json',
                                                 'Accept', 'application/json'),
        body := pg_catalog.jsonb_build_object(
          'sender', pg_catalog.jsonb_build_object('name', v_nom_expediteur, 'email', v_expediteur),
          'to', pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('email', v_client.email,
                                                                           'name', coalesce(v_client.nom_complet, ''))),
          'subject', v_texte ->> 'titre', 'htmlContent', v_html, 'textContent', v_texte_brut,
          'headers', v_entetes)
      ) into v_requete;
    end if;
    return v_requete;
  end if;

  -- Push marketing : aucune source de consentement propre au canal.
  raise exception 'MARKETING_CONSENTEMENT_NON_VERIFIABLE';
end
$fonction$;

-- 9. Le wrapper d'envoi : version de 005, plus l'aiguillage marketing ---------------
-- Le wrapper garde l'appel de communication_expedier_envoi_sans_porte : la candidate 004
-- le reconnaît ainsi au rejeu de la chaîne et ne le renomme pas.
create or replace function public.expedier_envoi(p_envoi public.notification_envois)
returns bigint
language plpgsql
security definer
set search_path = ''
as $fonction$
declare
  v_email text;
  v_raison text;
begin
  if p_envoi.canal = 'email' then
    select c.email into v_email
      from public.notifications n
      join public.clients c on c.id = n.client_id
     where n.id = p_envoi.notification_id;
    if not found or not public.communication_adresse_courriel_valide(v_email) then
      raise exception 'SANS_DESTINATAIRE';
    end if;
  end if;

  if not public.communication_sortie_autorisee('envoi', p_envoi.canal) then
    v_raison := public.communication_autoriser_sortie('envoi', p_envoi.canal);
  end if;
  if v_raison is not null then
    raise exception 'COMMUNICATION_OUTPUT_BLOCKED'
      using errcode = '55000', detail = v_raison;
  end if;
  if not public.communication_sortie_autorisee('envoi', p_envoi.canal) then
    raise exception 'COMMUNICATION_GATE_REQUIRED' using errcode = '55000';
  end if;
  perform pg_catalog.set_config('goship.sortie_autorisee', '', true);
  perform pg_catalog.set_config('goship.sortie_consommee', pg_catalog.txid_current()::text, true);
  if p_envoi.communication_campagne_destinataire_id is not null then
    return public.communication_campagne_expedier_sans_porte(p_envoi);
  end if;
  return public.communication_expedier_envoi_sans_porte(p_envoi);
end;
$fonction$;

-- 10. Suivi d'une campagne pour l'Admin (comptages seulement, aucune donnée de client) --
create or replace function public.communication_campagne_suivi(p_campagne bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare
  v_campagne public.communication_campagnes_marketing;
begin
  perform public.exiger_permission('communications.campaigns.view');
  select * into v_campagne from public.communication_campagnes_marketing c where c.id = p_campagne;
  if not found then raise exception 'COMMUNICATION_CAMPAIGN_NOT_FOUND'; end if;
  return pg_catalog.jsonb_build_object(
    'id', v_campagne.id, 'etat', v_campagne.etat,
    'planifiee_pour', v_campagne.planifiee_pour,
    'envoi_commence_le', v_campagne.envoi_commence_le,
    'envoi_termine_le', v_campagne.envoi_termine_le,
    'mis_en_file', (select count(*) from public.communication_campagne_destinataires d
                     where d.campagne_id = p_campagne and d.etat = 'en_file'),
    'exclus', coalesce((select pg_catalog.jsonb_object_agg(x.motif_exclusion, x.n)
                          from (select d.motif_exclusion, count(*) as n
                                  from public.communication_campagne_destinataires d
                                 where d.campagne_id = p_campagne and d.etat = 'exclu'
                                 group by d.motif_exclusion) x), '{}'::jsonb),
    'transmission', coalesce((select pg_catalog.jsonb_object_agg(x.statut, x.n)
                                from (select e.statut, count(*) as n
                                        from public.communication_campagne_destinataires d
                                        join public.notification_envois e on e.id = d.envoi_id
                                       where d.campagne_id = p_campagne
                                       group by e.statut) x), '{}'::jsonb),
    'annulations', coalesce((select pg_catalog.jsonb_object_agg(x.code_erreur, x.n)
                               from (select e.code_erreur, count(*) as n
                                       from public.communication_campagne_destinataires d
                                       join public.notification_envois e on e.id = d.envoi_id
                                      where d.campagne_id = p_campagne and e.statut = 'annule'
                                      group by e.code_erreur) x), '{}'::jsonb));
end
$fonction$;

-- 11. Tâche planifiée (si pg_cron existe) : la mise en file chaque minute. La transmission
-- reste celle du travailleur existant.
do $cron$
begin
  if exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'goship-campagnes-marketing';
    perform cron.schedule('goship-campagnes-marketing', '* * * * *',
                          'select public.communication_campagnes_lancer(5)');
  end if;
end
$cron$;

-- 12. Droits ------------------------------------------------------------------------
revoke all on function public.communication_courriel_empreinte(uuid),
  public.communication_campagne_empreinte(uuid, text),
  public.communication_desabonnement_jeton(bigint),
  public.communication_desabonner_courriel(bigint, text),
  public.communication_consentement_courriel_etat(),
  public.communication_consentement_courriel_accorder(text, text),
  public.communication_consentement_courriel_retirer(),
  public.communication_campagne_calculer_audience(bigint),
  public.communication_campagne_motif_exclusion(uuid, text),
  public.communication_campagne_motif_exclusion_calc(uuid, text, text, bigint),
  public.communication_campagnes_lancer(integer),
  public.communication_campagne_annulation_envois(),
  public.communication_campagne_expedier_sans_porte(public.notification_envois),
  public.expedier_envoi(public.notification_envois),
  public.communication_marketing_reglages_lire(),
  public.communication_marketing_reglages_definir(integer, integer),
  public.communication_campagne_suivi(bigint)
  from public, anon, authenticated, service_role;
-- Le lien de désinscription marche sans connexion.
grant execute on function public.communication_desabonner_courriel(bigint, text) to anon, authenticated;
grant execute on function public.communication_consentement_courriel_etat(),
  public.communication_consentement_courriel_accorder(text, text),
  public.communication_consentement_courriel_retirer()
  to authenticated;
grant execute on function public.communication_marketing_reglages_lire(),
  public.communication_marketing_reglages_definir(integer, integer),
  public.communication_campagne_suivi(bigint)
  to authenticated;

do $sequences$
declare v_nom text;
begin
  v_nom := pg_catalog.pg_get_serial_sequence('public.communication_campagne_destinataires', 'id');
  if v_nom is not null then
    execute pg_catalog.format('revoke all on sequence %s from public, anon, authenticated, service_role', v_nom);
  end if;
end
$sequences$;

commit;
