-- =============================================================================
-- Goship Express — le sexe et le document d'identité, demandés à l'inscription (19/10/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce fichier
-- AJOUTE deux colonnes vides à « clients », deux petites fonctions, un déclencheur,
-- et REMPLACE la fonction qui crée le profil d'un nouveau compte. Il ne change
-- aucune donnée existante, ne bloque aucun compte déjà ouvert, et peut être relancé
-- autant de fois qu'on veut.
--
-- Ordre d'installation : le dernier de la chaîne (outils/migrations.txt), après
-- supabase-courriel-reseaux.sql. Ne pas relancer supabase-naissance.sql après lui :
-- il remettrait l'ancienne création de profil (sans sexe ni document).
--
-- Ce que le formulaire d'inscription du site demande de plus :
--    · Sexe      : Masculin (M) ou Féminin (F)
--    · Document  : Passeport (passeport) ou Cédula (cedula)
-- Seul le TYPE du document est gardé, jamais son numéro.
--
-- Règles :
--    · Les deux colonnes sont facultatives côté base : l'application mobile déjà installée
--      n'envoie rien de tout cela et son inscription doit continuer de marcher ; une
--      connexion avec Google ou Apple n'en envoie pas non plus. C'est le formulaire du
--      site qui les rend obligatoires.
--    · Une valeur inconnue (ni M/F, ni passeport/cedula) n'est pas gardée : la colonne reste
--      vide, l'inscription n'est pas refusée pour si peu. Les colonnes ont aussi une contrainte :
--      aucun autre chemin d'écriture ne peut y mettre autre chose.
--    · Un client ne les modifie pas lui-même (la liste des colonnes qu'il peut écrire, dans
--      supabase.sql, ne les contient pas) ; l'équipe les lit avec la fiche du client
--      (clients.view), comme le reste de son profil.
--    · Quand un client supprime son compte, les deux valeurs sont effacées.
--
-- Contenu :
--    1. garde : la chaîne est-elle à jour ?
--    2. les colonnes
--    3. lire_sexe, lire_type_document
--    4. le profil d'un nouveau compte (REMPLACE celui de supabase-naissance.sql)
--    5. effacement à la suppression du compte
--    6. droits
--    7. contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regprocedure('public.creer_profil_client()') is null
     or to_regprocedure('public.valider_date_naissance(text)') is null
     or to_regprocedure('public.nom_depuis_metadonnees(jsonb)') is null
     or to_regprocedure('public.langue_depuis_metadonnees(jsonb)') is null
     or to_regprocedure('public.nouveau_code_client()') is null
     or to_regclass('public.profils_naissance') is null then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt), puis ce fichier.';
  end if;
end;
$garde$;


-- 2. Les colonnes --------------------------------------------------------------------
alter table public.clients add column if not exists sexe text;
alter table public.clients add column if not exists type_document text;

do $contraintes$
begin
  if not exists (select 1 from pg_constraint where conname = 'clients_sexe_valide') then
    alter table public.clients add constraint clients_sexe_valide check (sexe is null or sexe in ('M', 'F'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'clients_type_document_valide') then
    alter table public.clients add constraint clients_type_document_valide
      check (type_document is null or type_document in ('passeport', 'cedula'));
  end if;
end;
$contraintes$;

comment on column public.clients.sexe is 'M (masculin) ou F (féminin), demandé à l''inscription ; vide si non donné.';
comment on column public.clients.type_document is 'Type du document d''identité : passeport ou cedula (jamais son numéro) ; vide si non donné.';


-- 3. Lire ce que le formulaire envoie ------------------------------------------------------
-- Des codes (M/F, passeport/cedula), mais aussi les mots qu'une autre page pourrait envoyer.
-- Tout le reste donne null : pas de valeur inventée, pas d'inscription refusée.
create or replace function public.lire_sexe(p_valeur text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case translate(lower(trim(coalesce(p_valeur, ''))), 'éèê', 'eee')
           when 'm' then 'M' when 'masculin' then 'M' when 'masculino' then 'M' when 'male' then 'M' when 'gason' then 'M'
           when 'f' then 'F' when 'feminin' then 'F' when 'femenino' then 'F' when 'female' then 'F' when 'fi' then 'F'
         end
$$;

create or replace function public.lire_type_document(p_valeur text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case translate(lower(trim(coalesce(p_valeur, ''))), 'éèê', 'eee')
           when 'passeport' then 'passeport' when 'passport' then 'passeport' when 'pasaporte' then 'passeport' when 'paspo' then 'passeport'
           when 'cedula' then 'cedula'
         end
$$;


-- 4. Le profil d'un nouveau compte ---------------------------------------------------------
-- Celui de supabase-naissance.sql (date de naissance obligatoire pour une inscription par
-- e-mail), avec le sexe et le type de document en plus, lus par lire_sexe et lire_type_document.
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

  insert into public.clients (id, code, nom_complet, pays, region, ville, adresse, telephone, email, langue, sexe, type_document)
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
    public.langue_depuis_metadonnees(m),
    public.lire_sexe(m ->> 'sexe'),
    public.lire_type_document(m ->> 'type_document')
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


-- 5. Effacement à la suppression du compte --------------------------------------------------
-- supprimer_mon_compte garde la ligne « clients » (rendue anonyme) pour les colis et les
-- factures : le sexe et le document n'ont plus de raison d'être gardés.
create or replace function public.effacer_identite_compte_supprime()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.sexe := null;
  new.type_document := null;
  return new;
end;
$$;

drop trigger if exists effacer_identite on public.clients;
create trigger effacer_identite
  before update of supprime_le on public.clients
  for each row when (new.supprime_le is not null and old.supprime_le is null)
          execute function public.effacer_identite_compte_supprime();


-- 6. Droits ----------------------------------------------------------------------------------
revoke execute on function public.lire_sexe(text) from public, anon, authenticated;
revoke execute on function public.lire_type_document(text) from public, anon, authenticated;
revoke execute on function public.creer_profil_client() from public, anon, authenticated;
revoke execute on function public.effacer_identite_compte_supprime() from public, anon, authenticated;


-- 7. Contrôle -------------------------------------------------------------------------------------
-- colonnes : 2 ; fonctions : 2 ; ouvertes_aux_visiteurs : false ; profil_a_jour : true.
select (select count(*) from information_schema.columns
         where table_schema = 'public' and table_name = 'clients' and column_name in ('sexe', 'type_document')) as colonnes,
       (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname in ('lire_sexe', 'lire_type_document')) as fonctions,
       (select coalesce(bool_or(has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute')), false)
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname in ('lire_sexe', 'lire_type_document', 'creer_profil_client', 'effacer_identite_compte_supprime')) as ouvertes_aux_visiteurs,
       position('lire_type_document' in pg_get_functiondef('public.creer_profil_client()'::regprocedure)) > 0 as profil_a_jour;
