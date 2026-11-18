-- =============================================================================
-- BROUILLON — PHASE 1 DU CENTRE DE COMMUNICATION — NE PAS EXÉCUTER
-- =============================================================================
-- Ce fichier est un BROUILLON de conception, rangé dans docs/ (jamais publié, jamais
-- dans outils/migrations.txt). Il n'a été exécuté sur AUCUNE base, même jetable :
-- la Phase 1 n'autorise aucune exécution. La garde ci-dessous arrête tout de suite
-- une exécution par erreur (le SQL Editor envoie le fichier en une transaction :
-- rien de ce qui suit ne serait appliqué).
--
-- En Phase 2 (après accord écrit du CEO), il deviendra outils/supabase-communications-fondation.sql,
-- 40e de la chaîne, avec la garde habituelle « base incomplète » à la place de celle-ci,
-- et sera éprouvé sur une base jetable (essai-communications.py) avant toute production.
-- =============================================================================
do $brouillon$
begin
  raise exception 'BROUILLON NON APPROUVÉ (Phase 1 du Centre de communication) : ne pas exécuter.';
end;
$brouillon$;

-- =============================================================================
-- Goship Express — le Centre de communication, fondation (brouillon du 18/11/2026)
--
-- Ce que pose ce fichier, sans rien changer à l'existant :
--   1. les permissions communications.* (copie de permissions_du_role + 7 permissions) ;
--   2. les réglages du Centre, tous nés ÉTEINTS (aucune campagne ne peut partir) ;
--   3. le consentement commercial : textes versionnés (approbation juridique exigée avant
--      tout recueil) et registre IMMUABLE des accords et des retraits ;
--   4. la liste de suppression (désinscription, STOP, rebond définitif, plainte) ;
--   5. la liste des destinataires d'essai, la seule qui reçoive en mode « essai » ;
--   6. les tarifs des fournisseurs et les compteurs de dépense du jour (plafonds) ;
--   7. la protection du quota Brevo des e-mails d'authentification et transactionnels.
--
-- Ce qu'il ne touche PAS : notifications, notification_envois, notification_regles,
-- notification_preferences, expedier_envoi, traiter_notifications, mon_resume,
-- messages_recents — le moteur transactionnel et les contrats de l'application mobile
-- restent tels quels. Le consentement commercial n'est JAMAIS déduit de
-- notification_preferences (transactionnel), et inversement.
-- =============================================================================


-- 1. Les permissions ---------------------------------------------------------------
-- supabase.sql fait foi : cette fonction y sera recopiée mot pour mot en Phase 2, avec
-- PERMISSIONS_DES_ROLES (api.js), et essai-permissions.py comparera les copies.
-- Les sept permissions du Centre :
--   communications.view      voir le Centre, l'historique, les statistiques, les dépenses
--   communications.create    brouillons de campagnes, de modèles et de segments ; soumettre,
--                            retirer, programmer ; annuler ce qui n'est pas encore approuvé
--   communications.test      envoyer un essai, aux seuls destinataires d'essai
--   communications.pause     mettre en pause une campagne programmée ou en cours
--   communications.approve   approuver ou refuser campagnes et modèles ; reprendre ;
--                            annuler une campagne approuvée
--   communications.manage    réglages, interrupteurs, plafonds, tarifs, destinataires
--                            d'essai, textes de consentement, levée d'une suppression
--   communications.consents  lire l'historique de consentement d'un client et noter un
--                            RETRAIT qu'il demande (jamais un accord à sa place)
-- Gérant : view, create, test, pause, consents (décision D-D : l'approbation est réservée
-- à l'administrateur). Employé et client : aucune. La double authentification (aal2)
-- s'applique d'elle-même : ce sont des permissions de l'équipe (supabase-double-auth.sql).
create or replace function public.permissions_du_role(p_role text)
returns text[]
language sql
immutable
set search_path = ''
as $$
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
      'tracking.view', 'tracking.manage',
      'communications.view', 'communications.create', 'communications.test', 'communications.pause',
      'communications.approve', 'communications.manage', 'communications.consents']
    when 'gerant' then array[
      'clients.view', 'clients.create', 'clients.edit',
      'shipments.view', 'shipments.create', 'shipments.edit',
      'shipments.scan', 'shipments.change_status', 'shipments.correct', 'shipments.view_history',
      'invoices.view', 'invoices.create', 'invoices.edit', 'invoices.cancel',
      'payments.view', 'payments.create', 'payments.cancel',
      'reports.view', 'reports.create',
      'users.view',
      'birthdays.view', 'programs.view',
      'tracking.view',
      'communications.view', 'communications.create', 'communications.test', 'communications.pause',
      'communications.consents']
    when 'employe' then array[
      'clients.view', 'clients.create',
      'shipments.view', 'shipments.create', 'shipments.edit',
      'shipments.scan', 'shipments.change_status', 'shipments.view_history',
      'invoices.view', 'payments.view',
      'tracking.view']
    when 'client' then array[
      'clients.view:own', 'clients.edit:own',
      'shipments.view:own', 'shipments.view_history:own',
      'invoices.view:own', 'payments.view:own']
    else array[]::text[]
  end
$$;


-- 2. Les réglages du Centre ----------------------------------------------------------
-- Une seule ligne. Tout naît éteint ou à zéro : sans un administrateur qui allume, règle
-- et vérifie, aucune campagne ne part. Les plafonds à 0 bloquent (ils ne veulent pas dire
-- « illimité »). Les deux réglages « en attente du CEO » (adresse postale, adresse de Miami
-- validée) bloquent ce qui en dépend tant qu'ils sont vides (décisions D-G et D-H).
create table if not exists public.communication_reglages (
  id                        boolean primary key default true check (id),
  campagnes_actives         boolean not null default false,   -- interrupteur général du commercial
  mode                      text not null default 'essai' check (mode in ('essai', 'production')),
  email_actif               boolean not null default false,
  whatsapp_actif            boolean not null default false,
  -- Plafonds GLOBAUX du jour (jour civil de Santo Domingo), indépendants des campagnes
  plafond_jour_usd          numeric(10, 2) not null default 0 check (plafond_jour_usd >= 0),
  plafond_jour_messages     integer not null default 0 check (plafond_jour_messages >= 0),
  -- Quota Brevo : ce que l'abonnement vérifié permet, et ce qui reste toujours réservé à
  -- l'authentification (confirmation, mot de passe) et aux e-mails transactionnels
  brevo_quota_jour          integer check (brevo_quota_jour is null or brevo_quota_jour > 0),
  brevo_quota_mois          integer check (brevo_quota_mois is null or brevo_quota_mois > 0),
  brevo_reserve_jour        integer not null default 150 check (brevo_reserve_jour >= 0),
  brevo_quota_verifie_le    timestamptz,                      -- date de la vérification (D-C)
  brevo_quota_verifie_par   uuid,
  -- Débit et fenêtres d'envoi (heure locale du destinataire)
  lot_par_minute            integer not null default 20 check (lot_par_minute between 1 and 200),
  heure_debut               integer not null default 9  check (heure_debut between 0 and 23),
  heure_fin                 integer not null default 19 check (heure_fin between 1 and 24),
  frequence_max_jour        integer not null default 1 check (frequence_max_jour between 1 and 5),
  frequence_max_semaine     integer not null default 2 check (frequence_max_semaine between 1 and 14),
  -- Le moteur transactionnel passe toujours d'abord : au-delà de ce retard, le commercial attend
  attente_transactionnel_max integer not null default 50 check (attente_transactionnel_max >= 0),
  -- Quatre yeux : un administrateur peut-il approuver une campagne qu'il a créée ? (D-D, à confirmer)
  quatre_yeux               boolean not null default false,
  -- En attente du CEO : sans eux, l'e-mail commercial ne part pas (D-G) et la variable
  -- {{adresse_miami}} est refusée (D-H)
  adresse_postale           text check (adresse_postale is null or length(adresse_postale) between 10 and 300),
  adresse_postale_validee_par uuid,
  adresse_miami_validee     boolean not null default false,
  maj_le                    timestamptz not null default now(),
  maj_par                   uuid,
  check (heure_debut < heure_fin)
);
insert into public.communication_reglages (id) values (true) on conflict (id) do nothing;
alter table public.communication_reglages enable row level security;
revoke all on public.communication_reglages from anon, authenticated;


-- 3. Les petites aides ---------------------------------------------------------------
-- Le jour civil de l'entreprise (comme les rapports et les anniversaires).
create or replace function public.communication_jour(p_quand timestamptz default now())
returns date
language sql
stable
set search_path = ''
as $$
  select (p_quand at time zone 'America/Santo_Domingo')::date
$$;

-- L'empreinte d'une adresse ou d'un numéro : ce que gardent la preuve de consentement et la
-- liste de suppression, sans l'adresse elle-même. SHA-256 avec un préfixe fixe (pas de sel
-- secret : un sel perdu à la restauration rendrait la liste de suppression inutilisable).
-- Limite assumée : un numéro de téléphone se retrouve par force brute ; la table clients le
-- contient déjà en clair, l'empreinte ne protège donc rien de plus, elle sert à garder une
-- suppression APRÈS l'effacement du compte.
create or replace function public.communication_empreinte(p_canal text, p_valeur text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when coalesce(trim(p_valeur), '') = '' then null
    when p_canal = 'email' then encode(extensions.digest('goship-communication:email:' || lower(trim(p_valeur)), 'sha256'), 'hex')
    else encode(extensions.digest('goship-communication:tel:' || regexp_replace(p_valeur, '\D', '', 'g'), 'sha256'), 'hex')
  end
$$;

-- La cible actuelle d'un client sur un canal (l'adresse ou le numéro international).
create or replace function public.communication_cible(p_client uuid, p_canal text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case p_canal
           when 'email' then nullif(trim(c.email), '')
           when 'whatsapp' then nullif(public.telephone_international(c.telephone, c.pays), '')
         end
  from public.clients c where c.id = p_client
$$;

-- Le pays de tarification d'un numéro WhatsApp : c'est l'indicatif qui compte chez Meta.
-- +509 : Haïti ; +1 et indicatif régional 809, 829, 849 : République dominicaine ; autre +1 :
-- États-Unis (et Canada, traités comme les États-Unis, prudence). Inconnu : null (refusé).
create or replace function public.communication_pays_numero(p_numero text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_numero ~ '^509\d{8}$' then 'HT'
    when p_numero ~ '^1(809|829|849)\d{7}$' then 'DO'
    when p_numero ~ '^1\d{10}$' then 'US'
    else null
  end
$$;


-- 4. Le consentement commercial -------------------------------------------------------
-- 4.1 Les textes présentés au client, versionnés. Un texte n'est utilisable qu'APPROUVÉ par
-- le conseil juridique : l'administrateur note la référence de l'avis (nom, date). La base ne
-- peut pas vérifier l'avis lui-même ; elle rend l'étape obligatoire, visible et journalisée.
-- Tant qu'aucun texte n'est approuvé pour une langue et un canal, le recueil est fermé.
create table if not exists public.communication_textes_consentement (
  version            text not null check (version ~ '^[0-9]{4}-[0-9]{2}-[a-z0-9-]{1,20}$'),
  canal              text not null check (canal in ('email', 'whatsapp')),
  langue             text not null check (langue in ('fr', 'en', 'es', 'ht')),
  texte              text not null check (length(texte) between 20 and 2000),
  empreinte          text not null,                          -- SHA-256 du texte exact
  statut             text not null default 'brouillon'
                     check (statut in ('brouillon', 'approuve_juridique', 'retire')),
  reference_juridique text check (reference_juridique is null or length(reference_juridique) between 5 and 300),
  approuve_par       uuid,
  approuve_le        timestamptz,
  cree_le            timestamptz not null default now(),
  primary key (version, canal, langue),
  check (statut <> 'approuve_juridique' or (reference_juridique is not null and approuve_par is not null))
);
alter table public.communication_textes_consentement enable row level security;
revoke all on public.communication_textes_consentement from anon, authenticated;

-- 4.2 Le registre des consentements : une ligne par accord ou par retrait, JAMAIS modifiée
-- ni effacée (preuve). Pas de clé étrangère vers clients : la ligne doit survivre à
-- l'effacement d'un compte (comme journal_audit). L'empreinte de la cible dit QUELLE adresse
-- a consenti : si le client change d'e-mail ou de numéro, l'ancien accord ne vaut pas pour
-- le nouveau (il doit consentir à nouveau).
create table if not exists public.communication_consentements (
  id               bigint generated always as identity primary key,
  client_id        uuid not null,
  canal            text not null check (canal in ('email', 'whatsapp')),
  finalite         text not null default 'marketing' check (finalite = 'marketing'),
  action           text not null check (action in ('accorde', 'retire')),
  source           text not null check (source in (
                     'compte_web', 'application',                    -- le client lui-même
                     'lien_desinscription', 'whatsapp_stop',         -- retrait par le message
                     'equipe_sur_demande',                           -- retrait demandé à l'équipe
                     'plainte', 'suppression_compte', 'cible_changee')),
  texte_version    text,
  texte_empreinte  text,
  langue           text,
  cible_empreinte  text,
  contexte         jsonb not null default '{}'::jsonb,  -- page ou version de l'application, rien de plus
  auteur_id        uuid,                                -- le client, ou le membre de l'équipe
  motif            text check (motif is null or length(motif) <= 300),
  cree_le          timestamptz not null default now(),
  check (action <> 'accorde' or (texte_version is not null and texte_empreinte is not null and cible_empreinte is not null)),
  check (action <> 'accorde' or source in ('compte_web', 'application'))   -- l'équipe n'accorde jamais
);
create index if not exists communication_consentements_client_idx
  on public.communication_consentements (client_id, canal, cree_le desc, id desc);
alter table public.communication_consentements enable row level security;
revoke all on public.communication_consentements from anon, authenticated;

-- Immuable, même depuis le SQL Editor (comme journal_audit et colis_historique).
create or replace function public.communication_immuable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'IMMUTABLE_RECORD' using
    detail = 'Cette ligne est une preuve : elle ne se modifie ni ne s''efface. Ajoutez une ligne (retrait, correction).',
    hint = 'goship';
end;
$$;
drop trigger if exists communication_consentements_immuable on public.communication_consentements;
create trigger communication_consentements_immuable
  before update or delete on public.communication_consentements
  for each row execute function public.communication_immuable();

-- L'état actuel : le dernier mouvement, et seulement s'il porte sur la cible ACTUELLE.
create or replace function public.communication_consentement_actuel(p_client uuid, p_canal text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select k.action = 'accorde'
           and k.cible_empreinte = public.communication_empreinte(p_canal, public.communication_cible(p_client, p_canal))
      from public.communication_consentements k
     where k.client_id = p_client and k.canal = p_canal
     order by k.cree_le desc, k.id desc
     limit 1), false)
$$;


-- 5. La liste de suppression -----------------------------------------------------------
-- Une cible supprimée ne reçoit plus AUCUN message commercial, quel que soit le compte qui
-- la porte. Lever une suppression (administrateur, motif) ne rend PAS le consentement : le
-- client doit consentir à nouveau.
create table if not exists public.communication_suppressions (
  id               bigint generated always as identity primary key,
  canal            text not null check (canal in ('email', 'whatsapp')),
  cible_empreinte  text not null,
  client_id        uuid,
  raison           text not null check (raison in ('desinscription', 'stop', 'rebond_definitif',
                                                    'plainte', 'numero_invalide', 'manuel')),
  source           text not null default '',
  auteur_id        uuid,
  cree_le          timestamptz not null default now(),
  leve_le          timestamptz,
  leve_par         uuid,
  motif_levee      text check (motif_levee is null or length(motif_levee) between 5 and 300)
);
create unique index if not exists communication_suppressions_active_idx
  on public.communication_suppressions (canal, cible_empreinte) where leve_le is null;
alter table public.communication_suppressions enable row level security;
revoke all on public.communication_suppressions from anon, authenticated;

create or replace function public.communication_supprimee(p_canal text, p_cible text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.communication_suppressions s
                  where s.canal = p_canal and s.leve_le is null
                    and s.cible_empreinte = public.communication_empreinte(p_canal, p_cible))
$$;


-- 6. Les destinataires d'essai -----------------------------------------------------------
-- La SEULE liste qui reçoit en mode « essai », et la seule qui reçoit un « envoi d'essai »
-- quel que soit le mode. Vérifiée par la base à la constitution de l'audience ET juste avant
-- chaque envoi. N'y entrent qu'un compte de l'équipe, ou un client qui a consenti sur ce canal.
create table if not exists public.communication_destinataires_essai (
  client_id   uuid not null references public.clients (id) on delete cascade,
  canal       text not null check (canal in ('email', 'whatsapp')),
  actif       boolean not null default true,
  motif       text not null check (length(motif) between 5 and 300),
  ajoute_par  uuid not null,
  ajoute_le   timestamptz not null default now(),
  primary key (client_id, canal)
);
alter table public.communication_destinataires_essai enable row level security;
revoke all on public.communication_destinataires_essai from anon, authenticated;

create or replace function public.communication_est_essai(p_client uuid, p_canal text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.communication_destinataires_essai d
                  where d.client_id = p_client and d.canal = p_canal and d.actif)
$$;


-- 7. Tarifs et dépenses ------------------------------------------------------------------
-- 7.1 Le prix estimé d'un message, par fournisseur, canal, catégorie et pays. Une ligne
-- non VÉRIFIÉE par l'administrateur (sur la grille officielle du fournisseur) bloque le
-- lancement d'une campagne qui en a besoin. Les valeurs ci-dessous sont des estimations
-- publiques relevées le 18/11/2026 : verifie = false.
create table if not exists public.communication_tarifs (
  fournisseur   text not null check (fournisseur in ('meta', 'brevo', 'resend')),
  canal         text not null check (canal in ('email', 'whatsapp')),
  categorie     text not null check (categorie in ('marketing', 'utility', 'email')),
  pays          text not null check (pays in ('HT', 'DO', 'US', '*')),
  prix_usd      numeric(10, 5) not null check (prix_usd >= 0),
  autorise      boolean not null default true,  -- false : envoi interdit (ex. pause de Meta vers les numéros US)
  source        text not null default '',
  verifie       boolean not null default false,
  verifie_par   uuid,
  verifie_le    timestamptz,
  primary key (fournisseur, canal, categorie, pays)
);
insert into public.communication_tarifs (fournisseur, canal, categorie, pays, prix_usd, autorise, source) values
  ('meta',  'whatsapp', 'marketing', 'HT', 0.0740, true,  'Estimation publique « Rest of Latin America », 01/10/2026 — à vérifier'),
  ('meta',  'whatsapp', 'marketing', 'DO', 0.0740, true,  'Estimation publique « Rest of Latin America », 01/10/2026 — à vérifier ; pause US possible sur +1'),
  ('meta',  'whatsapp', 'marketing', 'US', 0.0250, false, 'Meta ne livre pas le marketing aux numéros US depuis le 01/04/2025 (à vérifier)'),
  ('meta',  'whatsapp', 'utility',   'HT', 0.0113, true,  'Estimation publique — à vérifier'),
  ('meta',  'whatsapp', 'utility',   'DO', 0.0113, true,  'Estimation publique — à vérifier'),
  ('meta',  'whatsapp', 'utility',   'US', 0.0040, true,  'Estimation publique — à vérifier'),
  ('brevo', 'email',    'email',     '*',  0.0000, true,  'Compté en nombre d''e-mails (quota), pas en dollars')
on conflict do nothing;
alter table public.communication_tarifs enable row level security;
revoke all on public.communication_tarifs from anon, authenticated;

-- 7.2 Les compteurs du jour : une ligne par jour, fournisseur et canal, prise SOUS VERROU
-- avant chaque appel (jamais après) : deux travailleurs ne dépassent jamais un plafond.
create table if not exists public.communication_depenses_jour (
  jour        date not null,
  fournisseur text not null,
  canal       text not null,
  messages    integer not null default 0 check (messages >= 0),
  cout_usd    numeric(12, 5) not null default 0 check (cout_usd >= 0),
  primary key (jour, fournisseur, canal)
);
alter table public.communication_depenses_jour enable row level security;
revoke all on public.communication_depenses_jour from anon, authenticated;


-- 8. Le quota Brevo : ce que le commercial peut encore utiliser aujourd'hui ---------------
-- Brevo compte ensemble TOUS les e-mails du compte : authentification de Supabase (SMTP),
-- e-mails de bienvenue, moteur transactionnel et, demain, le commercial. Le commercial ne
-- prend que ce qui reste APRÈS la réserve : quota − réserve − déjà envoyé aujourd'hui.
-- Les e-mails d'authentification sont estimés par les dates d'envoi d'auth.users (une par
-- compte et par type : une borne basse) — d'où la réserve, qui couvre aussi les inscriptions
-- de la fin de journée. Quota non vérifié (null) : 0, l'e-mail commercial reste fermé.
-- Mesure du 18/11/2026 (production, 60 jours) : 93 e-mails le jour le plus chargé, moins de
-- 25 d'habitude ; une inscription = 3 e-mails (confirmation + bienvenue + adresse).
create or replace function public.communication_brevo_disponible()
returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  r public.communication_reglages;
  v_debut timestamptz := (public.communication_jour() :: timestamp) at time zone 'America/Santo_Domingo';
  v_debut_mois timestamptz := (date_trunc('month', public.communication_jour()) :: timestamp) at time zone 'America/Santo_Domingo';
  v_auth integer;
  v_transactionnel integer;
  v_commercial integer;
  v_commercial_mois integer;
  v_jour integer;
begin
  select * into r from public.communication_reglages;
  if r.brevo_quota_jour is null and r.brevo_quota_mois is null then
    return 0;
  end if;
  select count(*) into v_auth from (
    select confirmation_sent_at t from auth.users union all
    select recovery_sent_at from auth.users union all
    select email_change_sent_at from auth.users union all
    select reauthentication_sent_at from auth.users) a where a.t >= v_debut;
  select (select count(*) from public.notification_envois e
           where e.canal = 'email' and e.statut in ('envoi', 'envoye', 'livre', 'echec')
             and coalesce(e.envoye_le, e.maj_le) >= v_debut)
       + (select count(*) from public.notifications n
           where n.canal = 'email' and n.envoye_le >= v_debut)
    into v_transactionnel;
  select coalesce(sum(messages), 0) into v_commercial
    from public.communication_depenses_jour where jour = public.communication_jour() and canal = 'email';
  v_jour := case when r.brevo_quota_jour is null then 2147483647
                 else r.brevo_quota_jour - r.brevo_reserve_jour - v_auth - v_transactionnel - v_commercial end;
  if r.brevo_quota_mois is not null then
    select coalesce(sum(messages), 0) into v_commercial_mois
      from public.communication_depenses_jour where jour >= public.communication_jour(v_debut_mois) and canal = 'email';
    -- Au mois, on garde la même réserve chaque jour restant : prudence
    v_jour := least(v_jour, r.brevo_quota_mois - v_commercial_mois
                    - r.brevo_reserve_jour * (extract(day from (date_trunc('month', now()) + interval '1 month' - now()))::integer + 1));
  end if;
  return greatest(v_jour, 0);
end;
$$;


-- 9. Droits -------------------------------------------------------------------------------
-- Rien de ce fichier n'est ouvert à une page : les fonctions d'écran (réglages, consentement,
-- liste d'essai) sont dans les brouillons suivants, chacune sous sa permission.
revoke execute on function public.communication_jour(timestamptz) from public, anon, authenticated;
revoke execute on function public.communication_empreinte(text, text) from public, anon, authenticated;
revoke execute on function public.communication_cible(uuid, text) from public, anon, authenticated;
revoke execute on function public.communication_pays_numero(text) from public, anon, authenticated;
revoke execute on function public.communication_immuable() from public, anon, authenticated;
revoke execute on function public.communication_consentement_actuel(uuid, text) from public, anon, authenticated;
revoke execute on function public.communication_supprimee(text, text) from public, anon, authenticated;
revoke execute on function public.communication_est_essai(uuid, text) from public, anon, authenticated;
revoke execute on function public.communication_brevo_disponible() from public, anon, authenticated;
