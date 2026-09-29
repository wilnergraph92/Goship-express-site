-- =============================================================================
-- Goship Express — se connecter avec Google (29/09/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce fichier
-- AJOUTE une fonction et remplace le déclencheur qui crée le profil d'un nouveau
-- compte. Il ne change aucune donnée existante, et peut être relancé autant de
-- fois qu'on veut.
--
-- Ordre d'installation : le dernier de la chaîne (outils/migrations.txt), après
-- supabase-regroupement.sql.
--
-- Pourquoi : un client inscrit par le formulaire envoie son nom sous
-- « nom_complet ». Un client qui s'inscrit avec Google (ou, plus tard, Apple)
-- n'envoie rien : c'est le fournisseur qui remplit les informations du compte,
-- sous ses propres noms (« full_name », « name », « given_name » + « family_name »,
-- « locale »). Sans ce fichier, son profil naîtrait sans nom — et l'e-mail
-- « Votre adresse en Floride » lui donnerait une adresse sans son nom, alors que
-- les boutiques en ont besoin sur le colis.
--
-- Le reste n'a pas besoin de changer :
--   - le code client, les e-mails de bienvenue : les mêmes déclencheurs, qu'un
--     compte Google naisse confirmé ou soit confirmé juste après ;
--   - « Supprimer mon compte » (supabase-compte.sql) efface déjà les identités
--     (auth.identities) : le lien Google disparaît avec le compte ;
--   - un client déjà inscrit par e-mail qui se connecte avec Google (même adresse,
--     vérifiée par Google) retrouve son compte : c'est Supabase qui relie les deux.
-- Pays, ville, adresse et téléphone ne viennent jamais de Google : le site et
-- l'application les demandent à la première connexion (« Compléter mon profil »).
--
-- Contenu :
--    1. garde : la chaîne est-elle à jour ?
--    2. nom_depuis_metadonnees, langue_depuis_metadonnees
--    3. creer_profil_client (remplace celui de supabase.sql)
--    4. contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regprocedure('public.nouveau_code_client()') is null
     or to_regprocedure('public.supprimer_mon_compte(text)') is null
     or to_regprocedure('public.sortir_du_regroupement(uuid, uuid[], text)') is null then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt), puis ce fichier.';
  end if;
end;
$garde$;


-- 2. Le nom et la langue, d'où qu'ils viennent ------------------------------------------
-- Dans l'ordre : le formulaire du site ou de l'application (nom_complet), puis ce
-- qu'envoient Google et Apple. Rien du tout : une chaîne vide, que le client
-- remplira dans « Compléter mon profil ».
create or replace function public.nom_depuis_metadonnees(p_meta jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select left(coalesce(
    nullif(trim(p_meta ->> 'nom_complet'), ''),
    nullif(trim(p_meta ->> 'full_name'), ''),
    nullif(trim(p_meta ->> 'name'), ''),
    nullif(trim(concat_ws(' ', nullif(trim(p_meta ->> 'given_name'), ''),
                               nullif(trim(p_meta ->> 'family_name'), ''))), ''),
    ''), 120);
$$;

-- La langue choisie dans le formulaire, sinon celle du compte Google (« fr »,
-- « es-419 », « en-US »…), sinon le français. Seules les quatre langues du site.
create or replace function public.langue_depuis_metadonnees(p_meta jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_meta ->> 'langue' in ('fr', 'en', 'es', 'ht') then p_meta ->> 'langue'
    when lower(left(coalesce(p_meta ->> 'locale', ''), 2)) in ('fr', 'en', 'es', 'ht')
      then lower(left(p_meta ->> 'locale', 2))
    else 'fr'
  end;
$$;

-- Des outils du déclencheur : aucun compte n'a à les appeler.
revoke execute on function public.nom_depuis_metadonnees(jsonb) from public, anon, authenticated;
revoke execute on function public.langue_depuis_metadonnees(jsonb) from public, anon, authenticated;


-- 3. Le profil d'un nouveau compte ------------------------------------------------------
-- Le même que celui de supabase.sql (partie 3), sauf le nom et la langue.
create or replace function public.creer_profil_client()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
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
  return new;
end;
$$;

drop trigger if exists creer_profil_client on auth.users;
create trigger creer_profil_client
  after insert on auth.users
  for each row execute function public.creer_profil_client();


-- 4. Contrôle ---------------------------------------------------------------------------------
-- fonctions : 2 ; ouvertes_aux_visiteurs : false ; profil_google : true.
select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('nom_depuis_metadonnees', 'langue_depuis_metadonnees'))       as fonctions,
       (select coalesce(bool_or(has_function_privilege('anon', p.oid, 'execute')), false)
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('nom_depuis_metadonnees', 'langue_depuis_metadonnees'))       as ouvertes_aux_visiteurs,
       (select prosrc like '%nom_depuis_metadonnees%' from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'creer_profil_client')                 as profil_google;
