-- =============================================================================
-- Goship Express — le suivi externe : la fondation de données (Phase 1, 12/11/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce fichier
-- AJOUTE quatre tables vides et fermées, une colonne vide à « prealertes », deux
-- permissions et quatre fonctions. Il ne change aucune donnée existante, n'appelle
-- aucun service extérieur, ne crée aucune tâche planifiée, et peut être relancé
-- autant de fois qu'on veut.
--
-- Ordre d'installation : le dernier de la chaîne (outils/migrations.txt), après
-- supabase-suivi-courriels.sql.
--
-- Pourquoi : un client annonce des achats dont le numéro de suivi est celui d'un
-- transporteur (UPS, USPS, Amazon Logistics…). Pour lui montrer où en est ce carton
-- AVANT son arrivée à Miami, la base doit pouvoir ranger ce que dit un fournisseur
-- de suivi (17TRACK, AfterShip…). Ce fichier ne prépare que les tiroirs : c'est la
-- Phase 2 qui les remplira, et seulement après la décision écrite du CEO sur le
-- fournisseur. Validé par le CEO le 12/11/2026 (dossier de conception de la Phase 1).
--
-- Règles, et pourquoi :
--    · Le suivi externe vit À CÔTÉ du suivi GoShip. Aucune clé, aucun déclencheur,
--      aucune fonction de ce fichier ne touche colis.statut ni colis_historique :
--      un « DELIVERED » du transporteur veut dire « livré à notre dépôt », jamais
--      « reçu » ni « livré au client ». executer_operation reste la seule porte.
--    · Aucune donnée client dans ces tables : un même numéro annoncé par deux
--      clients n'a qu'un suivi. Le lien vers le client passe par la pré-alerte.
--    · Les quatre tables sont fermées (RLS sans aucune règle pour les comptes) :
--      on ne les lit que par les fonctions de la partie 6, qui demandent la
--      permission tracking.view. Les clients n'y ont pas accès (Phase 4).
--    · Un statut que la correspondance ne connaît pas reste VIDE (« non
--      reconnu ») : jamais « DELIVERED » par défaut.
--    · Les événements d'un transporteur et le journal des appels ne se modifient ni
--      ne s'effacent, comme colis_historique.
--    · La clé d'un fournisseur n'est JAMAIS dans une table : elle ira dans le
--      coffre (Vault, definir_reglage), comme celles de Brevo et de WhatsApp.
--    · Les fournisseurs naissent désactivés (« DISABLED ») ; la base refuse d'en
--      activer un qui n'est pas « VERIFIED ».
--
-- Contenu :
--    1. garde : la chaîne est-elle à jour ?
--    2. les permissions tracking.view et tracking.manage
--    3. les fournisseurs de suivi
--    4. les suivis externes, leurs événements, le journal des appels
--    5. la colonne prealertes.suivi_externe_id
--    6. les fonctions
--    7. droits
--    8. contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regclass('public.prealertes') is null
     or to_regprocedure('public.exiger_permission(text, uuid)') is null
     or to_regprocedure('public.erreur_metier(text, text)') is null
     or to_regprocedure('public.lire_suivi_courriels(integer)') is null then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt), jusqu''à supabase-suivi-courriels.sql, puis ce fichier.';
  end if;
end;
$garde$;


-- 2. Les permissions ----------------------------------------------------------------
-- tracking.view (administrateur, gérant, employé) et tracking.manage (administrateur)
-- sont écrites dans supabase.sql, qui fait foi. La fonction est répétée ici, mot pour
-- mot, pour qu'on n'ait à installer QUE ce fichier sur une base déjà à jour :
-- essai-suivi-externe.py vérifie que les copies sont identiques.
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
      'tracking.view', 'tracking.manage']
    when 'gerant' then array[
      'clients.view', 'clients.create', 'clients.edit',
      'shipments.view', 'shipments.create', 'shipments.edit',
      'shipments.scan', 'shipments.change_status', 'shipments.correct', 'shipments.view_history',
      'invoices.view', 'invoices.create', 'invoices.edit', 'invoices.cancel',
      'payments.view', 'payments.create', 'payments.cancel',
      'reports.view', 'reports.create',
      'users.view',
      'birthdays.view', 'programs.view',
      'tracking.view']
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


-- 3. Les fournisseurs de suivi --------------------------------------------------------
-- Une ligne par fournisseur. La conformité suit le cahier des charges (USPS, droits
-- d'affichage, contrat) : VERIFIED, PENDING_VERIFICATION, NOT_AUTHORIZED, DISABLED.
-- Un fournisseur actif est forcément VERIFIED : la contrainte le garantit, quel que
-- soit le chemin d'écriture.
create table if not exists public.fournisseurs_suivi (
  code             text primary key check (code ~ '^[a-z0-9_]{2,30}$'),
  nom              text not null check (length(nom) between 1 and 60),
  conformite       text not null default 'DISABLED'
                   check (conformite in ('VERIFIED', 'PENDING_VERIFICATION', 'NOT_AUTHORIZED', 'DISABLED')),
  actif            boolean not null default false,
  plafond_mensuel  integer check (plafond_mensuel is null or plafond_mensuel >= 0),
  note             text not null default '' check (length(note) <= 500),
  maj_le           timestamptz not null default now(),
  constraint fournisseur_actif_verifie check (not actif or conformite = 'VERIFIED')
);

-- Les deux fournisseurs évalués en Phase 0, éteints. Relancer ce fichier ne change
-- pas une ligne déjà réglée.
insert into public.fournisseurs_suivi (code, nom)
values ('17track', '17TRACK'), ('aftership', 'AfterShip')
on conflict (code) do nothing;


-- 4. Les suivis externes ------------------------------------------------------------
-- Un numéro de suivi d'un transporteur, et ce qu'on en sait. Aucune donnée client.
create table if not exists public.suivis_externes (
  id                    uuid primary key default gen_random_uuid(),
  -- Majuscules, sans espaces, comme creer_prealerte et regles_colis le rangent
  numero                text not null unique check (numero ~ '^[A-Z0-9-]{4,60}$'),
  transporteur          text check (transporteur is null or transporteur ~ '^[a-z0-9_-]{2,40}$'),
  -- D'où vient le transporteur : la forme du numéro, le fournisseur, ou l'équipe
  transporteur_source   text check (transporteur_source in ('numero', 'fournisseur', 'equipe')),
  fournisseur           text references public.fournisseurs_suivi (code),
  -- La synchronisation avec le fournisseur (Phase 2) ; « en_attente » tant qu'aucune
  etat                  text not null default 'en_attente'
                        check (etat in ('en_attente', 'actif', 'arrete', 'erreur')),
  -- Le statut normalisé (statut_suivi_normalise, vide si inconnu) et ce que le
  -- fournisseur a dit, tel quel
  statut                text check (statut in ('PENDING', 'INFO_RECEIVED', 'IN_TRANSIT', 'CUSTOMS', 'OUT_FOR_DELIVERY',
                                               'AVAILABLE_FOR_PICKUP', 'DELIVERED', 'FAILED_ATTEMPT', 'EXCEPTION',
                                               'RETURNED', 'EXPIRED', 'NOT_FOUND')),
  statut_original       text check (length(statut_original) <= 80),
  sous_statut           text check (length(sous_statut) <= 80),
  dernier_lieu          text check (length(dernier_lieu) <= 120),
  dernier_evenement_le  timestamptz,
  -- Seulement si le fournisseur la donne : GoShip n'estime jamais une date
  livraison_estimee_le  date,
  -- Les codes de résultat du cahier des charges (section 9)
  code_resultat         text check (code_resultat in ('INVALID_TRACKING', 'PENDING_FIRST_SCAN', 'CARRIER_UNKNOWN',
                                                      'PROVIDER_UNAVAILABLE', 'UNSUPPORTED_TRACKING',
                                                      'AMAZON_TBA_LIMITATION', 'ORDER_NUMBER_DETECTED',
                                                      'TRACKING_EXPIRED')),
  derniere_synchro_le   timestamptz,
  prochaine_synchro_le  timestamptz,
  cree_le               timestamptz not null default now(),
  maj_le                timestamptz not null default now()
);

create index if not exists suivis_externes_synchro_idx
  on public.suivis_externes (etat, prochaine_synchro_le);

-- Les événements d'un transporteur. L'empreinte (calculée par qui les range, en
-- Phase 2) est unique par suivi : le même événement reçu deux fois — webhook
-- rejoué, interrogation répétée — ne s'enregistre qu'une fois.
create table if not exists public.suivis_externes_evenements (
  id               bigint generated always as identity primary key,
  suivi_id         uuid not null references public.suivis_externes (id) on delete restrict,
  survenu_le       timestamptz not null,
  statut           text check (statut in ('PENDING', 'INFO_RECEIVED', 'IN_TRANSIT', 'CUSTOMS', 'OUT_FOR_DELIVERY',
                                          'AVAILABLE_FOR_PICKUP', 'DELIVERED', 'FAILED_ATTEMPT', 'EXCEPTION',
                                          'RETURNED', 'EXPIRED', 'NOT_FOUND')),
  statut_original  text not null default '' check (length(statut_original) <= 80),
  sous_statut      text not null default '' check (length(sous_statut) <= 80),
  description      text not null default '' check (length(description) <= 300),
  lieu             text not null default '' check (length(lieu) <= 120),
  pays             text check (pays is null or pays ~ '^[A-Z]{2}$'),
  fournisseur      text references public.fournisseurs_suivi (code),
  empreinte        text not null check (length(empreinte) between 8 and 128),
  recu_le          timestamptz not null default now(),
  constraint suivis_externes_evenements_unique unique (suivi_id, empreinte)
);

create index if not exists suivis_externes_evenements_suivi_idx
  on public.suivis_externes_evenements (suivi_id, survenu_le desc);

-- Chaque appel à un fournisseur (Phase 2) : de quoi surveiller les erreurs, la
-- latence et le quota. Ni clé, ni réponse brute, ni donnée client.
create table if not exists public.suivis_externes_journal (
  id             bigint generated always as identity primary key,
  suivi_id       uuid references public.suivis_externes (id) on delete restrict,
  fournisseur    text references public.fournisseurs_suivi (code),
  operation      text not null check (operation ~ '^[a-z_]{2,40}$'),
  resultat       text not null check (resultat in ('ok', 'erreur', 'quota', 'refus', 'delai')),
  code_http      integer check (code_http is null or code_http between 100 and 599),
  code_erreur    text check (length(code_erreur) <= 60),
  duree_ms       integer check (duree_ms is null or duree_ms >= 0),
  quota_restant  integer,
  cree_le        timestamptz not null default now()
);

create index if not exists suivis_externes_journal_date_idx
  on public.suivis_externes_journal (cree_le desc);

-- Le numéro toujours rangé de la même façon, et la date de mise à jour tenue
create or replace function public.ranger_suivi_externe()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.numero := public.normaliser_numero_suivi(new.numero);
  new.maj_le := now();
  return new;
end;
$$;

-- Ni modification ni effacement : un événement d'un transporteur, un appel passé
-- sont des faits. Même depuis le SQL Editor.
create or replace function public.suivi_externe_immuable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform public.erreur_metier('EVENT_IMMUTABLE',
    'Un événement de suivi externe ou une ligne du journal des appels ne se modifie ni ne s''efface.');
  return null;
end;
$$;

drop trigger if exists suivi_externe_immuable on public.suivis_externes_evenements;
create trigger suivi_externe_immuable
  before update or delete on public.suivis_externes_evenements
  for each row execute function public.suivi_externe_immuable();

drop trigger if exists suivi_externe_immuable on public.suivis_externes_journal;
create trigger suivi_externe_immuable
  before update or delete on public.suivis_externes_journal
  for each row execute function public.suivi_externe_immuable();


-- 5. La colonne de la pré-alerte ------------------------------------------------------
-- Vide pour l'instant : la Phase 2 y reliera une pré-alerte à son suivi externe. Les
-- versions installées de l'application lisent des colonnes nommées et écrivent par
-- creer_prealerte (ou les colonnes que l'insert direct leur ouvre) : elles ne voient
-- aucune différence. Un client ne peut pas la remplir : ses droits d'écriture sur
-- prealertes sont limités à ses propres champs (supabase.sql, 13.3).
alter table public.prealertes add column if not exists suivi_externe_id uuid references public.suivis_externes (id) on delete set null;

create index if not exists prealertes_suivi_externe_idx
  on public.prealertes (suivi_externe_id) where suivi_externe_id is not null;


-- 6. Les fonctions ---------------------------------------------------------------------

-- Un numéro de suivi tel que la base le range : majuscules, sans espaces (la même
-- règle que creer_prealerte).
create or replace function public.normaliser_numero_suivi(p_numero text)
returns text
language sql
immutable
set search_path = ''
as $$
  select upper(regexp_replace(coalesce(p_numero, ''), '\s', '', 'g'))
$$;

-- Le statut d'un fournisseur → l'un des 12 statuts du cahier des charges, ou NULL
-- (« non reconnu ») : jamais DELIVERED par défaut. 17TRACK v2.4 (documentation lue le
-- 11/11/2026) ; un autre fournisseur, tant qu'il n'est pas décrit ici, donne NULL.
-- PENDING n'est pas un statut de fournisseur : c'est GoShip qui le pose (numéro
-- enregistré, aucune réponse encore).
create or replace function public.statut_suivi_normalise(p_fournisseur text, p_statut text, p_sous_statut text default null)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when lower(coalesce(p_fournisseur, '')) <> '17track' then null
    when p_statut = 'NotFound' then 'NOT_FOUND'
    when p_statut = 'InfoReceived' then 'INFO_RECEIVED'
    when p_statut = 'InTransit'
         and p_sous_statut in ('InTransit_CustomsProcessing', 'InTransit_CustomsRequiringInformation') then 'CUSTOMS'
    when p_statut = 'InTransit' then 'IN_TRANSIT'
    when p_statut = 'Expired' then 'EXPIRED'
    when p_statut = 'AvailableForPickup' then 'AVAILABLE_FOR_PICKUP'
    when p_statut = 'OutForDelivery' then 'OUT_FOR_DELIVERY'
    when p_statut = 'DeliveryFailure' then 'FAILED_ATTEMPT'
    when p_statut = 'Delivered' then 'DELIVERED'
    when p_statut = 'Exception'
         and p_sous_statut in ('Exception_Returning', 'Exception_Returned') then 'RETURNED'
    when p_statut = 'Exception' then 'EXCEPTION'
    else null
  end
$$;

drop trigger if exists ranger_suivi_externe on public.suivis_externes;
create trigger ranger_suivi_externe
  before insert or update on public.suivis_externes
  for each row execute function public.ranger_suivi_externe();

-- Le suivi externe d'un numéro et ses événements (du plus récent au plus ancien),
-- ou NULL. Pour l'équipe seulement (tracking.view) ; aucune donnée client.
create or replace function public.suivi_externe(p_numero text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_numero text := public.normaliser_numero_suivi(p_numero);
  v_suivi  public.suivis_externes;
begin
  perform public.exiger_permission('tracking.view');
  if length(v_numero) < 4 or length(v_numero) > 60 then
    return null;
  end if;
  select * into v_suivi from public.suivis_externes where numero = v_numero;
  if not found then
    return null;
  end if;
  return to_jsonb(v_suivi) || jsonb_build_object('evenements', coalesce((
    select jsonb_agg(jsonb_build_object(
             'survenu_le', e.survenu_le, 'statut', e.statut, 'statut_original', e.statut_original,
             'sous_statut', e.sous_statut, 'description', e.description, 'lieu', e.lieu, 'pays', e.pays,
             'fournisseur', e.fournisseur)
           order by e.survenu_le desc, e.id desc)
      from public.suivis_externes_evenements e
     where e.suivi_id = v_suivi.id), '[]'::jsonb));
end;
$$;

-- Les fournisseurs de suivi : conformité, activation, plafond. Jamais de clé : il
-- n'y en a pas dans la table.
create or replace function public.etat_fournisseurs_suivi()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('tracking.view');
  return coalesce((
    select jsonb_agg(jsonb_build_object('code', f.code, 'nom', f.nom, 'conformite', f.conformite,
                                        'actif', f.actif, 'plafond_mensuel', f.plafond_mensuel,
                                        'note', f.note, 'maj_le', f.maj_le)
                     order by f.code)
      from public.fournisseurs_suivi f), '[]'::jsonb);
end;
$$;


-- 7. Droits --------------------------------------------------------------------------
-- Tables fermées : RLS activée, aucune règle pour les comptes ni les visiteurs ; on
-- les lit par les fonctions de la partie 6. Seul le rôle de service (les tâches de
-- la Phase 2) y écrit.
alter table public.fournisseurs_suivi enable row level security;
alter table public.suivis_externes enable row level security;
alter table public.suivis_externes_evenements enable row level security;
alter table public.suivis_externes_journal enable row level security;

revoke all on public.fournisseurs_suivi, public.suivis_externes, public.suivis_externes_evenements,
              public.suivis_externes_journal from public, anon, authenticated;
grant select, insert, update, delete on public.fournisseurs_suivi, public.suivis_externes,
              public.suivis_externes_evenements, public.suivis_externes_journal to service_role;

-- Les aides ne sont ouvertes à personne ; les lectures, aux comptes connectés (la
-- fonction vérifie elle-même tracking.view).
revoke execute on function public.normaliser_numero_suivi(text) from public, anon, authenticated;
revoke execute on function public.statut_suivi_normalise(text, text, text) from public, anon, authenticated;
revoke execute on function public.ranger_suivi_externe() from public, anon, authenticated;
revoke execute on function public.suivi_externe_immuable() from public, anon, authenticated;
revoke execute on function public.suivi_externe(text) from public, anon;
revoke execute on function public.etat_fournisseurs_suivi() from public, anon;
grant execute on function public.suivi_externe(text) to authenticated;
-- Les tâches de la Phase 2 (rôle de service) rangent les numéros et les statuts par ces aides
grant execute on function public.normaliser_numero_suivi(text) to service_role;
grant execute on function public.statut_suivi_normalise(text, text, text) to service_role;
grant execute on function public.etat_fournisseurs_suivi() to authenticated;


-- 8. Contrôle ----------------------------------------------------------------------------
-- tables : 4 ; colonne : 1 ; fournisseurs_actifs : 0 ; ouverte_aux_visiteurs : false ;
-- employe_tracking_view : true
select (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
           and c.relname in ('fournisseurs_suivi', 'suivis_externes', 'suivis_externes_evenements',
                             'suivis_externes_journal')) as tables,
       (select count(*) from information_schema.columns
         where table_schema = 'public' and table_name = 'prealertes' and column_name = 'suivi_externe_id') as colonne,
       (select count(*) from public.fournisseurs_suivi where actif) as fournisseurs_actifs,
       has_function_privilege('anon', 'public.suivi_externe(text)', 'execute')
         or has_function_privilege('anon', 'public.etat_fournisseurs_suivi()', 'execute') as ouverte_aux_visiteurs,
       'tracking.view' = any (public.permissions_du_role('employe')) as employe_tracking_view;
