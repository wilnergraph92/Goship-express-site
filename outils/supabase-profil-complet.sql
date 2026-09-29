-- =============================================================================
-- Goship Express — un profil complet avant la première pré-alerte (29/09/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce fichier
-- AJOUTE une fonction et un déclencheur. Il ne change aucune donnée existante, et
-- peut être relancé autant de fois qu'on veut.
--
-- Ordre d'installation : le dernier de la chaîne (outils/migrations.txt), après
-- supabase-connexion.sql.
--
-- Pourquoi : un compte ouvert avec Google n'a ni téléphone, ni pays, ni ville
-- (Google ne les donne pas). Le site et l'application les demandent dès la
-- connexion, mais un client peut fermer le formulaire. Or une pré-alerte annonce
-- un colis que l'équipe devra remettre : sans téléphone ni ville, elle ne peut ni
-- prévenir le client, ni savoir où le livrer. La base refuse donc une nouvelle
-- pré-alerte tant que le profil du client n'a pas son nom, son téléphone, son pays
-- et sa ville — les mêmes champs que le bandeau « Complétez votre profil » du site
-- et la carte de l'application.
--
-- La règle est un déclencheur sur prealertes, pas un test dans creer_prealerte :
-- les versions de l'application déjà installées écrivent encore directement dans
-- la table (supabase-mobile.sql), et elles doivent être tenues par la même règle.
-- Une pré-alerte déjà enregistrée n'est pas touchée ; creer_prealerte rejouée
-- avec la même clé rend toujours la ligne déjà faite (aucune insertion, aucun refus).
--
-- Contenu :
--    1. garde : la chaîne est-elle à jour ?
--    2. profil_complet
--    3. le déclencheur exiger_profil_prealerte
--    4. contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regprocedure('public.nom_depuis_metadonnees(jsonb)') is null
     or to_regprocedure('public.creer_prealerte(uuid, text, text, text, numeric, text)') is null
     or to_regprocedure('public.erreur_metier(text, text)') is null then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt), puis ce fichier.';
  end if;
end;
$garde$;


-- 2. Le profil est-il complet ? ---------------------------------------------------------
-- Nom, téléphone, pays et ville remplis (des espaces ne comptent pas). Un client
-- inconnu n'a pas de profil complet.
create or replace function public.profil_complet(p_client uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select trim(coalesce(c.nom_complet, '')) <> ''
       and trim(coalesce(c.telephone, '')) <> ''
       and trim(coalesce(c.pays, '')) <> ''
       and trim(coalesce(c.ville, '')) <> ''
      from public.clients c
     where c.id = p_client), false);
$$;


-- 3. Pas de pré-alerte sans profil complet --------------------------------------------------
create or replace function public.exiger_profil_prealerte()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.profil_complet(new.client_id) then
    perform public.erreur_metier('PROFILE_INCOMPLETE',
      'Complétez votre profil (téléphone, pays et ville) avant d''annoncer un achat : nous en avons besoin pour vous remettre le colis.');
  end if;
  return new;
end;
$$;

drop trigger if exists exiger_profil_prealerte on public.prealertes;
create trigger exiger_profil_prealerte
  before insert on public.prealertes
  for each row execute function public.exiger_profil_prealerte();

-- Des outils du déclencheur : aucun compte n'a à les appeler.
revoke execute on function public.profil_complet(uuid) from public, anon, authenticated;
revoke execute on function public.exiger_profil_prealerte() from public, anon, authenticated;


-- 4. Contrôle ---------------------------------------------------------------------------------
-- fonctions : 2 ; ouvertes_aux_visiteurs : false ; declencheur : 1.
select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('profil_complet', 'exiger_profil_prealerte'))                  as fonctions,
       (select coalesce(bool_or(has_function_privilege('anon', p.oid, 'execute')), false)
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('profil_complet', 'exiger_profil_prealerte'))                  as ouvertes_aux_visiteurs,
       (select count(*) from pg_trigger
        where tgname = 'exiger_profil_prealerte' and not tgisinternal)                       as declencheur;
