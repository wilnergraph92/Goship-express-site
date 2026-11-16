-- =============================================================================
-- Goship Express — la double authentification de l'équipe (lot 1 du contrôle qualité, 16/11/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce fichier
-- AJOUTE une petite table de réglage (fermée), quatre fonctions, et redéfinit
-- peut() et est_admin() avec une condition de plus. Aucune donnée n'est touchée,
-- aucune permission ajoutée ni retirée, et il se relance autant de fois qu'on veut.
--
-- Ordre d'installation : le dernier de la chaîne (outils/migrations.txt), après
-- supabase-supervision-suivi.sql. Relancer supabase.sql (qui définit peut) impose de
-- relancer celui-ci après, comme toute la chaîne.
--
-- Pourquoi : le contrôle qualité du 16/11/2026 a trouvé les trois comptes
-- administrateurs protégés par un mot de passe seul. Un mot de passe volé ouvrait
-- tout : clients, factures, paiements, rôles. Décision du CEO (« Approuvé, lancer
-- les trois lots ») : double authentification par code à 6 chiffres (TOTP : Google
-- Authenticator, Microsoft Authenticator, 1Password…), les administrateurs d'abord.
--
-- Comment : c'est Supabase Auth qui inscrit l'appareil et vérifie le code
-- (auth.mfa_factors ; le jeton d'une session dont le code a été donné porte
-- « aal » = « aal2 »). Gratuit, inclus dans l'offre actuelle. Ce fichier n'y ajoute
-- que la RÈGLE, dans la base, là où vivent toutes les autres :
--
--    un compte de l'équipe qui a activé la double authentification n'a plus aucune
--    permission de l'équipe tant que sa session n'a pas donné le code.
--
-- Un mot de passe volé ne suffit donc plus, même en appelant la base sans passer par
-- le tableau de bord. Les permissions « :own » d'un client (ses colis, ses factures)
-- ne sont pas concernées : l'espace client et l'application mobile ne changent pas.
--
-- Puis, sur décision du CEO, quand chacun a activé la sienne : regler_double_auth(true,
-- motif) la rend OBLIGATOIRE pour toute l'équipe (un compte de l'équipe sans appareil
-- inscrit n'a plus aucune permission de l'équipe, il doit d'abord en inscrire un).
-- Éteint à l'installation.
--
-- Téléphone perdu : le propriétaire du projet supprime l'appareil dans Supabase >
-- Authentication > Users > (le compte) > « Multi-factor authentication » ; le compte
-- se reconnecte avec son mot de passe et inscrit son nouveau téléphone. Voir
-- docs/production/double-authentification.md.
--
-- Contenu :
--    1. garde : la chaîne est-elle à jour ?
--    2. double_auth_reglage : le réglage « obligatoire » (table fermée, une ligne)
--    3. session_double_auth_ok() : la session courante a-t-elle le droit d'agir ?
--    4. peut() et est_admin() : la même règle qu'avant, plus cette condition
--    5. ma_double_auth() : ce que la page doit demander (code, inscription)
--    6. double_auth_equipe() : qui, dans l'équipe, a activé la sienne
--    7. regler_double_auth(obligatoire, motif)
--    8. droits
--    9. contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regprocedure('public.supervision_suivi(jsonb, integer)') is null
     or to_regprocedure('public.permissions_du_role(text)') is null
     or to_regprocedure('public.auditer(text, text, text, jsonb, jsonb)') is null then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt), jusqu''à supabase-supervision-suivi.sql, puis ce fichier.';
  end if;
end;
$garde$;


-- 2. Le réglage -------------------------------------------------------------------
-- Une seule ligne (id = true). Une table et non un secret du coffre (lire_reglage) :
-- peut() la lit à chaque vérification, et une lecture du coffre déchiffre.
create table if not exists public.double_auth_reglage (
  id           boolean primary key default true check (id),
  obligatoire  boolean not null default false,
  modifie_le   timestamptz not null default now(),
  modifie_par  uuid
);
insert into public.double_auth_reglage (id) values (true) on conflict (id) do nothing;
-- Fermée : aucune règle, aucune lecture ni écriture directe. regler_double_auth seule.
alter table public.double_auth_reglage enable row level security;
revoke all on public.double_auth_reglage from public, anon, authenticated;


-- 3. La session courante a-t-elle le droit d'agir pour l'équipe ? ----------------
-- Vrai si la session a donné le code (aal2) ; sinon, vrai seulement si le compte n'a
-- aucun appareil vérifié ET que la double authentification n'est pas obligatoire.
-- Ouverte à personne : peut() et est_admin() l'appellent avec leurs propres droits.
-- « aal » est lu dans le jeton comme auth.uid() lit « sub » : request.jwt.claims.
create or replace function public.session_double_auth_ok()
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_jeton text := nullif(current_setting('request.jwt.claims', true), '');
begin
  if v_jeton is not null and (v_jeton::jsonb ->> 'aal') = 'aal2' then
    return true;
  end if;
  if exists (select 1 from public.double_auth_reglage where obligatoire) then
    return false;
  end if;
  -- Une base sans le schéma de Supabase Auth (essais anciens) : rien à vérifier
  if to_regclass('auth.mfa_factors') is null then
    return true;
  end if;
  return not exists (select 1 from auth.mfa_factors f
                      where f.user_id = auth.uid() and f.status::text = 'verified');
end;
$$;


-- 4. peut() et est_admin() --------------------------------------------------------
-- Recopie de supabase.sql (partie 4), une seule différence : une permission de
-- l'équipe (sans « :own ») demande en plus session_double_auth_ok(). Les permissions
-- « :own » d'un client ne changent pas.
create or replace function public.peut(p_action text, p_proprietaire uuid default null)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select (p_action = any (public.permissions_du_role(c.role)) and public.session_double_auth_ok())
           or (p_proprietaire is not null and p_proprietaire = c.id
               and (p_action || ':own') = any (public.permissions_du_role(c.role)))
    from public.clients c
    where c.id = auth.uid()), false)
$$;

-- Gardée pour l'application mobile et les anciennes pages (aucune règle RLS ne s'en
-- sert) : même condition, pour qu'aucune porte ne reste ouverte sans le code.
create or replace function public.est_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.clients where id = auth.uid() and role = 'admin')
         and public.session_double_auth_ok()
$$;


-- 5. Ce que la page doit demander --------------------------------------------------
-- equipe      le compte a des permissions de l'équipe (sans « :own »)
-- active      au moins un appareil vérifié
-- session     « aal1 » (mot de passe seul) ou « aal2 » (code donné)
-- code_requis la base refuse cette session pour l'équipe : demander le code (ou, si
--             aucun appareil et obligatoire, en faire inscrire un)
-- obligatoire le réglage de la section 7
-- appareils   nombre d'appareils vérifiés
create or replace function public.ma_double_auth()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role text;
  v_equipe boolean := false;
  v_appareils integer := 0;
  v_jeton text := nullif(current_setting('request.jwt.claims', true), '');
begin
  select c.role into v_role from public.clients c where c.id = auth.uid();
  if v_role is not null then
    select exists (select 1 from unnest(public.permissions_du_role(v_role)) p where p not like '%:own')
      into v_equipe;
  end if;
  if to_regclass('auth.mfa_factors') is not null and auth.uid() is not null then
    select count(*) into v_appareils from auth.mfa_factors f
     where f.user_id = auth.uid() and f.status::text = 'verified';
  end if;
  return jsonb_build_object(
    'equipe', v_equipe,
    'active', v_appareils > 0,
    'appareils', v_appareils,
    'session', coalesce(v_jeton::jsonb ->> 'aal', 'aal1'),
    'obligatoire', exists (select 1 from public.double_auth_reglage where obligatoire),
    'code_requis', v_equipe and not public.session_double_auth_ok());
end;
$$;


-- 6. Qui, dans l'équipe, a activé la sienne ---------------------------------------
-- Pour l'onglet Équipe (users.view) : rien d'autre qu'un oui / non et un nombre
-- d'appareils, jamais un secret ni le nom d'un appareil.
create or replace function public.double_auth_equipe()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_liste jsonb;
begin
  perform public.exiger_permission('users.view');
  if to_regclass('auth.mfa_factors') is null then
    select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'appareils', 0) order by c.id), '[]'::jsonb)
      into v_liste from public.clients c
     where exists (select 1 from unnest(public.permissions_du_role(c.role)) p where p not like '%:own');
  else
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', c.id,
             'appareils', (select count(*) from auth.mfa_factors f
                            where f.user_id = c.id and f.status::text = 'verified')) order by c.id), '[]'::jsonb)
      into v_liste
      from public.clients c
     where exists (select 1 from unnest(public.permissions_du_role(c.role)) p where p not like '%:own');
  end if;
  return jsonb_build_object(
    'obligatoire', exists (select 1 from public.double_auth_reglage where obligatoire),
    'comptes', v_liste);
end;
$$;


-- 7. Rendre la double authentification obligatoire pour l'équipe ------------------
-- settings.manage (administrateur), motif d'au moins 5 caractères, journalisé. Seul un
-- administrateur qui a lui-même donné son code (aal2) peut changer ce réglage : un
-- mot de passe volé ne peut pas l'éteindre, et personne ne l'allume sans appareil.
create or replace function public.regler_double_auth(p_obligatoire boolean, p_motif text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_avant boolean;
  v_jeton text := nullif(current_setting('request.jwt.claims', true), '');
begin
  perform public.exiger_permission('settings.manage');
  if v_jeton is null or (v_jeton::jsonb ->> 'aal') is distinct from 'aal2' then
    perform public.erreur_metier('MFA_REQUIRED',
      'Donnez d''abord le code de votre application d''authentification.');
  end if;
  if p_obligatoire is null then
    perform public.erreur_metier('INVALID_VALUE', 'Choisissez oui ou non.');
  end if;
  if length(btrim(coalesce(p_motif, ''))) < 5 then
    perform public.erreur_metier('REASON_REQUIRED', 'Indiquez un motif (5 caractères au moins).');
  end if;
  select obligatoire into v_avant from public.double_auth_reglage where id for update;
  if v_avant is not distinct from p_obligatoire then
    return jsonb_build_object('obligatoire', p_obligatoire, 'deja', true);
  end if;
  update public.double_auth_reglage
     set obligatoire = p_obligatoire, modifie_le = now(), modifie_par = auth.uid()
   where id;
  perform set_config('goship.motif', left(btrim(p_motif), 300), true);
  perform public.auditer('double_auth.reglage', 'double_auth', 'equipe',
                         jsonb_build_object('obligatoire', v_avant),
                         jsonb_build_object('obligatoire', p_obligatoire));
  return jsonb_build_object('obligatoire', p_obligatoire, 'deja', false);
end;
$$;


-- 8. Droits --------------------------------------------------------------------------
revoke execute on function public.session_double_auth_ok() from public, anon, authenticated;
revoke execute on function public.ma_double_auth() from public, anon;
revoke execute on function public.double_auth_equipe() from public, anon;
revoke execute on function public.regler_double_auth(boolean, text) from public, anon;
grant execute on function public.ma_double_auth() to authenticated;
grant execute on function public.double_auth_equipe() to authenticated;
grant execute on function public.regler_double_auth(boolean, text) to authenticated;
-- peut() et est_admin() gardent leurs droits (create or replace ne les change pas) ;
-- reposés ici pour qu'une relance seule de ce fichier ne dépende de rien.
revoke execute on function public.peut(text, uuid) from public, anon;
revoke execute on function public.est_admin() from public, anon;
grant execute on function public.peut(text, uuid) to authenticated;
grant execute on function public.est_admin() to authenticated;


-- 9. Contrôle ------------------------------------------------------------------------
-- fonctions : 4 ; obligatoire : false (à l'installation) ; ouvertes_aux_visiteurs : false ;
-- peut_verifie : true
select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname in ('session_double_auth_ok', 'ma_double_auth', 'double_auth_equipe',
                             'regler_double_auth')) as fonctions,
       (select obligatoire from public.double_auth_reglage where id) as obligatoire,
       (has_function_privilege('anon', 'public.ma_double_auth()', 'execute')
        or has_function_privilege('anon', 'public.double_auth_equipe()', 'execute')
        or has_function_privilege('anon', 'public.regler_double_auth(boolean, text)', 'execute')
        or has_function_privilege('authenticated', 'public.session_double_auth_ok()', 'execute'))
         as ouvertes_aux_visiteurs,
       (select pg_get_functiondef('public.peut(text, uuid)'::regprocedure) like '%session_double_auth_ok%')
         as peut_verifie;
