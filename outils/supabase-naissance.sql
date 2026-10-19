-- =============================================================================
-- Goship Express — la date de naissance, obligatoire à l'inscription (19/10/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce fichier
-- AJOUTE une table, un réglage et des fonctions, et REMPLACE la fonction qui crée
-- le profil d'un nouveau compte. Il ne change aucune donnée existante, ne bloque
-- aucun compte déjà ouvert, et peut être relancé autant de fois qu'on veut.
--
-- Ordre d'installation : le dernier de la chaîne (outils/migrations.txt), après
-- supabase-corrections.sql.
--
-- Pourquoi une table à part, et pas une colonne de « clients » : la date de
-- naissance est une donnée personnelle sensible, et la table « clients » est lue
-- par toute l'équipe (permission clients.view) et recopiée, champ par champ, dans
-- le journal d'audit. Une colonne de plus s'y retrouverait. Ici, la table
-- profils_naissance n'a AUCUNE règle de lecture directe : ni un client, ni un
-- employé, ni le site ne la lisent. Chacun passe par une fonction qui dit qui a
-- le droit de quoi :
--   · le client lit et déclare SA date (ma_naissance, definir_ma_naissance) ;
--   · l'équipe n'y accède que par les fonctions des anniversaires, sous une
--     permission à part (birthdays.view, supabase-anniversaires.sql).
-- Le journal d'audit note qu'une date a été déclarée ou corrigée, jamais laquelle.
--
-- Format : un vrai type « date » (jour civil, sans heure ni fuseau) : la date
-- saisie est celle qui est lue, le jour ne glisse jamais d'un fuseau à l'autre.
-- Les fonctions reçoivent du texte « AAAA-MM-JJ » et le vérifient elles-mêmes :
-- jamais de conversion par une page.
--
-- Règles (côté base, donc pour le site, l'application et tout appel direct) :
--   · une inscription par e-mail et mot de passe SANS date de naissance valide est
--     refusée (BIRTHDATE_REQUIRED, INVALID_BIRTHDATE) : aucun compte n'est créé ;
--   · une date dans le futur, avant 1900 ou qui n'existe pas (30 février) est
--     refusée ; « futur » se mesure au jour de Santo Domingo, réglable ;
--   · une connexion avec Google ou Apple n'envoie pas de date : le compte est créé
--     sans, et le client est invité à la compléter (bandeau du site, carte de
--     l'application). Aucune date inventée n'est jamais enregistrée ;
--   · un client déclare sa date UNE fois. Pour la changer, il écrit à l'équipe,
--     qui la corrige avec un motif, journalisé (supabase-anniversaires.sql) :
--     sans cela, chacun pourrait refaire son « anniversaire » quand il veut ;
--   · quand un client supprime son compte, sa date de naissance est effacée.
--
-- Les comptes existants ne sont pas touchés : sans date, ils continuent de
-- fonctionner, et profil_complet (pré-alertes) ne l'exige pas.
--
-- Contenu :
--    1. garde : la chaîne est-elle à jour ?
--    2. les permissions et l'adresse de la série (copie de supabase.sql)
--    3. le réglage : fuseau horaire de l'entreprise
--    4. la table profils_naissance
--    5. valider_date_naissance
--    6. ma_naissance, definir_ma_naissance
--    7. le profil d'un nouveau compte (REMPLACE creer_profil_client)
--    8. effacement à la suppression du compte
--    9. droits
--   10. contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regprocedure('public.creer_profil_client()') is null
     or to_regprocedure('public.nom_depuis_metadonnees(jsonb)') is null
     or to_regprocedure('public.langue_depuis_metadonnees(jsonb)') is null
     or to_regprocedure('public.erreur_metier(text, text)') is null
     or to_regprocedure('public.auditer(text, text, text, jsonb, jsonb)') is null
     or to_regprocedure('public.supprimer_mon_compte(text)') is null then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt), puis ce fichier.';
  end if;
end;
$garde$;


-- 2. Les permissions et l'adresse de cette série ------------------------------------------------
-- Les permissions birthdays.*, programs.* et points.adjust (anniversaires, fidélité, campagnes) et
-- l'adresse de réception « ABX-46780 » sont écrites dans supabase.sql, qui fait foi. Ces deux
-- fonctions sont répétées ici, mot pour mot, pour qu'on n'ait à installer QUE les fichiers de
-- cette série (et non toute la chaîne) sur une base déjà à jour : essai-programmes.py vérifie
-- que les deux copies sont identiques.
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
      'birthdays.view', 'birthdays.manage', 'programs.view', 'programs.manage', 'points.adjust']
    when 'gerant' then array[
      'clients.view', 'clients.create', 'clients.edit',
      'shipments.view', 'shipments.create', 'shipments.edit',
      'shipments.scan', 'shipments.change_status', 'shipments.correct', 'shipments.view_history',
      'invoices.view', 'invoices.create', 'invoices.edit', 'invoices.cancel',
      'payments.view', 'payments.create', 'payments.cancel',
      'reports.view', 'reports.create',
      'users.view',
      'birthdays.view', 'programs.view']
    when 'employe' then array[
      'clients.view', 'clients.create',
      'shipments.view', 'shipments.create', 'shipments.edit',
      'shipments.scan', 'shipments.change_status', 'shipments.view_history',
      'invoices.view', 'payments.view']
    when 'client' then array[
      'clients.view:own', 'clients.edit:own',
      'shipments.view:own', 'shipments.view_history:own',
      'invoices.view:own', 'payments.view:own']
    else array[]::text[]
  end
$$;

create or replace function public.adresse_miami()
returns jsonb
language sql
immutable
set search_path = ''
as $fn$
  select jsonb_build_object(
    'ligne1', '8140 NW 74th Ave Unit 3',
    'ligne2', 'ABX-46780',
    'ville', 'Medley',
    'etat', 'Florida',
    'zip', '33166',
    'pays', 'United States',
    'telephone', '786 525-2944')
$fn$;


-- 3. Le fuseau horaire de l'entreprise ----------------------------------------------------
-- Une seule ligne, lue par tout ce qui compte en « jours » pour les programmes :
-- « aujourd'hui », l'heure d'un message d'anniversaire. Les fichiers suivants
-- (anniversaires, fidélité) y ajoutent leurs colonnes. Le fuseau se change par
-- une fonction réservée à l'administration, qui le vérifie contre la liste de
-- PostgreSQL (pg_timezone_names) : un nom inconnu n'est jamais enregistré.
create table if not exists public.programme_reglages (
  id     boolean primary key default true check (id),
  fuseau text not null default 'America/Santo_Domingo'
);
insert into public.programme_reglages (id) values (true) on conflict (id) do nothing;

alter table public.programme_reglages enable row level security;
revoke all on public.programme_reglages from anon, authenticated;

-- Le jour civil d'aujourd'hui chez Goship Express (et non en UTC, où il change à 20 h
-- à Santo Domingo). Un fuseau illisible retombe sur Santo Domingo plutôt que de
-- casser un programme.
create or replace function public.aujourdhui_entreprise()
returns date
language plpgsql
stable
set search_path = ''
as $$
declare
  v_fuseau text;
begin
  select fuseau into v_fuseau from public.programme_reglages where id;
  begin
    return (now() at time zone coalesce(v_fuseau, 'America/Santo_Domingo'))::date;
  exception when others then
    return (now() at time zone 'America/Santo_Domingo')::date;
  end;
end;
$$;


-- 4. La table ------------------------------------------------------------------------------
create table if not exists public.profils_naissance (
  client_id       uuid primary key references public.clients (id) on delete cascade,
  date_naissance  date not null,
  declaree_le     timestamptz not null default now(),
  corrigee_le     timestamptz
);

alter table public.profils_naissance enable row level security;
-- Aucune règle de lecture ni d'écriture : seules les fonctions ci-dessous (et celles
-- des anniversaires) touchent cette table.
revoke all on public.profils_naissance from anon, authenticated;


-- 5. Valider une date de naissance --------------------------------------------------------
-- Texte « AAAA-MM-JJ » strict (le format d'un champ <input type="date">). Rend la
-- date, ou refuse avec un code et une phrase que les pages affichent telle quelle.
create or replace function public.valider_date_naissance(p_texte text)
returns date
language plpgsql
stable
set search_path = ''
as $$
declare
  v_texte text := trim(coalesce(p_texte, ''));
  v_date  date;
begin
  if v_texte = '' then
    perform public.erreur_metier('BIRTHDATE_REQUIRED', 'Indiquez votre date de naissance.');
  end if;
  if v_texte !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    perform public.erreur_metier('INVALID_BIRTHDATE', 'La date de naissance n''est pas valide. Écrivez-la sous la forme jour / mois / année.');
  end if;
  begin
    v_date := v_texte::date;   -- refuse le 30 février, le mois 13…
  exception when others then
    perform public.erreur_metier('INVALID_BIRTHDATE', 'Cette date n''existe pas. Vérifiez le jour, le mois et l''année.');
  end;
  if v_date > public.aujourdhui_entreprise() then
    perform public.erreur_metier('INVALID_BIRTHDATE', 'La date de naissance ne peut pas être dans le futur.');
  end if;
  if v_date < date '1900-01-01' then
    perform public.erreur_metier('INVALID_BIRTHDATE', 'Cette date de naissance est trop ancienne. Vérifiez l''année.');
  end if;
  return v_date;
end;
$$;


-- 6. Le client et sa propre date --------------------------------------------------------------
-- Le compte connecté, et lui seul : aucun paramètre ne désigne un autre compte.
create or replace function public.ma_naissance()
returns date
language sql
stable
security definer
set search_path = ''
as $$
  select n.date_naissance from public.profils_naissance n where n.client_id = auth.uid()
$$;

create or replace function public.definir_ma_naissance(p_date text)
returns date
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_moi  uuid := auth.uid();
  v_date date;
begin
  if v_moi is null or not exists (select 1 from public.clients c where c.id = v_moi and c.supprime_le is null) then
    perform public.erreur_metier('PERMISSION_DENIED', 'Connectez-vous pour compléter votre profil.');
  end if;
  v_date := public.valider_date_naissance(p_date);

  -- Une seule déclaration : deux appels simultanés ne peuvent pas en faire deux
  insert into public.profils_naissance (client_id, date_naissance) values (v_moi, v_date)
  on conflict (client_id) do nothing;
  if not found then
    -- Déjà déclarée : la même date rejouée est sans effet, une autre est refusée
    if (select n.date_naissance from public.profils_naissance n where n.client_id = v_moi) = v_date then
      return v_date;
    end if;
    perform public.erreur_metier('BIRTHDATE_LOCKED',
      'Votre date de naissance est déjà enregistrée. Pour la corriger, écrivez-nous : notre équipe s''en occupera.');
  end if;

  perform public.auditer('client.naissance_declaree', 'client', v_moi::text, null,
                         jsonb_build_object('declaree', true));
  return v_date;
end;
$$;


-- 7. Le profil d'un nouveau compte --------------------------------------------------------------
-- Le même que celui de supabase-connexion.sql, plus la date de naissance :
--   · e-mail et mot de passe (le formulaire du site, de l'application) : la date est
--     OBLIGATOIRE et vérifiée ici. Sans elle, l'inscription échoue et aucun compte
--     n'existe : le site et l'application vérifient avant, la base vérifie toujours ;
--   · Google, Apple : pas de date (ils ne la donnent pas) ; si l'application en envoie
--     une valide, elle est gardée, sinon le compte est créé sans et complété plus tard.
-- Le fournisseur se lit dans raw_app_meta_data, que le client ne peut pas écrire
-- (raw_user_meta_data, lui, vient du formulaire : on n'y lit jamais le fournisseur).
create or replace function public.creer_profil_client()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_fournisseur text := coalesce(nullif(new.raw_app_meta_data ->> 'provider', ''), 'email');
  v_date date;
begin
  if v_fournisseur = 'email' then
    v_date := public.valider_date_naissance(m ->> 'date_naissance');
  elsif coalesce(m ->> 'date_naissance', '') <> '' then
    begin
      v_date := public.valider_date_naissance(m ->> 'date_naissance');
    exception when others then
      v_date := null;   -- une date illisible venue d'un tiers n'est pas gardée
    end;
  end if;

  insert into public.clients (id, code, nom_complet, pays, region, ville, adresse, telephone, email, langue)
  values (
    new.id,
    public.nouveau_code_client(),
    public.nom_depuis_metadonnees(m),
    left(upper(trim(coalesce(m ->> 'pays', ''))), 2),
    left(trim(coalesce(m ->> 'region', '')), 80),
    left(trim(coalesce(m ->> 'ville', '')), 80),
    left(trim(coalesce(m ->> 'adresse', '')), 200),
    left(trim(coalesce(m ->> 'telephone', '')), 40),
    coalesce(new.email, ''),
    public.langue_depuis_metadonnees(m)
  )
  on conflict (id) do nothing;

  if v_date is not null then
    insert into public.profils_naissance (client_id, date_naissance) values (new.id, v_date)
    on conflict (client_id) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists creer_profil_client on auth.users;
create trigger creer_profil_client
  after insert on auth.users
  for each row execute function public.creer_profil_client();


-- 8. Effacement à la suppression du compte ----------------------------------------------------
-- supprimer_mon_compte garde la ligne « clients » (rendue anonyme) pour les colis et les
-- factures : la date de naissance, elle, n'a plus de raison d'être gardée.
create or replace function public.effacer_naissance_compte_supprime()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.profils_naissance where client_id = new.id;
  return null;
end;
$$;

drop trigger if exists effacer_naissance on public.clients;
create trigger effacer_naissance
  after update of supprime_le on public.clients
  for each row when (new.supprime_le is not null and old.supprime_le is null)
  execute function public.effacer_naissance_compte_supprime();


-- 9. Droits ---------------------------------------------------------------------------------------
revoke execute on function public.aujourdhui_entreprise() from public, anon, authenticated;
revoke execute on function public.valider_date_naissance(text) from public, anon, authenticated;
revoke execute on function public.creer_profil_client() from public, anon, authenticated;
revoke execute on function public.effacer_naissance_compte_supprime() from public, anon, authenticated;
revoke execute on function public.ma_naissance() from public, anon;
revoke execute on function public.definir_ma_naissance(text) from public, anon;
grant execute on function public.ma_naissance() to authenticated;
grant execute on function public.definir_ma_naissance(text) to authenticated;


-- 10. Contrôle ---------------------------------------------------------------------------------------
-- tables : 2 ; ouvertes_aux_visiteurs : false ; table_fermee : true ; declencheurs : 2.
select (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relname in ('profils_naissance', 'programme_reglages')) as tables,
       (select coalesce(bool_or(has_function_privilege('anon', p.oid, 'execute')), false)
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('ma_naissance', 'definir_ma_naissance', 'valider_date_naissance')) as ouvertes_aux_visiteurs,
       not has_table_privilege('authenticated', 'public.profils_naissance', 'select')           as table_fermee,
       (select count(*) from pg_trigger
        where tgname in ('creer_profil_client', 'effacer_naissance') and not tgisinternal)      as declencheurs;
