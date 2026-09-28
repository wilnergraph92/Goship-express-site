-- =============================================================================
-- Goship Express — Supprimer mon compte (application mobile, 28/09/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce fichier
-- AJOUTE une colonne vide (clients.supprime_le) et une fonction. Il ne supprime
-- rien, ne change aucune donnée existante, et peut être relancé autant de fois
-- qu'on veut.
--
-- Ordre d'installation : le dernier de la chaîne (outils/migrations.txt), après
-- supabase-rapports.sql.
--
-- Pourquoi on ne SUPPRIME pas la ligne du compte : clients.id suit auth.users
-- (on delete cascade), et factures, paiements, pré-alertes, notifications suivent
-- clients de la même façon. Effacer le compte d'Authentication effacerait donc les
-- factures et les paiements d'un client, que la comptabilité doit garder et qu'aucun
-- chemin ne supprime (supabase-finances.sql). La suppression demandée par le client
-- fait donc, dans une seule transaction :
--   - son profil perd tout ce qui le désigne (nom, e-mail, téléphone, adresse,
--     ville, région) et reçoit la date de suppression ; son code client reste, parce
--     qu'il est imprimé sur des étiquettes et des factures déjà remises ;
--   - ses pré-alertes encore en attente (magasin, contenu, suivi) sont effacées,
--     et les téléphones enregistrés pour ses notifications aussi ;
--   - son compte de connexion (auth.users) perd son e-mail, son mot de passe et
--     ses informations, est bloqué pour toujours, et ses sessions sont fermées :
--     personne ne peut plus s'y connecter, et l'adresse e-mail redevient libre
--     pour une nouvelle inscription ;
--   - le journal d'audit le note (client.suppression_demandee).
-- Ses colis, factures et paiements restent, rattachés au profil vidé.
--
-- Refusé (et rien n'est changé) :
--   - à un compte de l'équipe (toute permission sur les clients des autres) : il se
--     ferme depuis le tableau de bord ;
--   - tant qu'un colis n'est pas livré (en route, à retirer, action requise) ;
--   - tant qu'une facture a un solde à payer ;
--   - sans le mot de confirmation SUPPRIMER (un appel parti par erreur ne fait rien).
--
-- Contenu :
--    1. garde : la chaîne est-elle à jour ?
--    2. la colonne supprime_le
--    3. supprimer_mon_compte
--    4. contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regprocedure('public.auditer(text, text, text, jsonb, jsonb)') is null
     or to_regprocedure('public.solde_usd(public.factures)') is null
     or to_regprocedure('public.peut(text, uuid)') is null
     or to_regclass('public.appareils') is null then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt), puis ce fichier.';
  end if;
end;
$garde$;


-- 2. La date de suppression ----------------------------------------------------------
alter table public.clients add column if not exists supprime_le timestamptz;
comment on column public.clients.supprime_le is
  'Date à laquelle le client a supprimé son compte (supprimer_mon_compte) ; null = compte actif';


-- 3. supprimer_mon_compte ------------------------------------------------------------
-- Le compte connecté, et lui seul : aucun paramètre ne désigne un autre compte.
create or replace function public.supprimer_mon_compte(p_confirmation text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_moi    uuid := auth.uid();
  v_client public.clients;
  v_colis  integer;
  v_solde  numeric;
begin
  if v_moi is null then
    perform public.erreur_metier('PERMISSION_DENIED', 'Connectez-vous pour supprimer votre compte.');
  end if;
  if coalesce(p_confirmation, '') <> 'SUPPRIMER' then
    perform public.erreur_metier('CONFIRMATION_REQUIRED', 'La suppression du compte doit être confirmée.');
  end if;

  select * into v_client from public.clients where id = v_moi for update;
  if not found or v_client.supprime_le is not null then
    perform public.erreur_metier('ACCOUNT_ALREADY_DELETED', 'Ce compte a déjà été supprimé.');
  end if;
  if public.peut('clients.view') then
    perform public.erreur_metier('STAFF_ACCOUNT',
      'Un compte de l''équipe ne se supprime pas depuis l''application : un administrateur le ferme depuis le tableau de bord.');
  end if;
  if not public.peut('clients.edit', v_moi) then
    perform public.erreur_metier('PERMISSION_DENIED', 'Ce compte ne peut pas être supprimé d''ici.');
  end if;

  select count(*) into v_colis from public.colis where client_id = v_moi and statut <> 'livre';
  if v_colis > 0 then
    perform public.erreur_metier('ACCOUNT_HAS_SHIPMENTS',
      'Vous avez encore des colis en route ou à retirer. Votre compte pourra être supprimé quand ils vous auront été remis.');
  end if;
  select coalesce(sum(public.solde_usd(f)), 0) into v_solde
    from public.factures f where f.client_id = v_moi and f.statut <> 'annulee';
  if v_solde > 0 then
    perform public.erreur_metier('ACCOUNT_HAS_BALANCE',
      'Une facture reste à payer. Votre compte pourra être supprimé une fois le solde réglé.');
  end if;

  -- Ce qui n'a de sens que pour un compte actif
  delete from public.appareils where client_id = v_moi;
  delete from public.prealertes where client_id = v_moi and statut = 'attente';

  -- Le profil : plus rien qui désigne la personne. Le code client reste.
  update public.clients
     set nom_complet = 'Compte supprimé', email = '', telephone = '', adresse = '',
         ville = '', region = '', supprime_le = now()
   where id = v_moi;

  -- Le compte de connexion : bloqué, sans e-mail ni mot de passe, sessions fermées.
  -- L'adresse d'origine redevient libre pour une nouvelle inscription.
  update auth.users
     set email = 'supprime-' || v_moi::text || '@goship.invalid',
         encrypted_password = '',
         phone = null,
         raw_user_meta_data = '{}'::jsonb,
         banned_until = 'infinity'::timestamptz
   where id = v_moi;
  delete from auth.identities where user_id = v_moi;
  delete from auth.sessions where user_id = v_moi;
  delete from auth.refresh_tokens where user_id = v_moi::text;

  perform public.auditer('client.suppression_demandee', 'client', v_moi::text,
                         jsonb_build_object('code', v_client.code),
                         jsonb_build_object('supprime_le', now()));

  return jsonb_build_object('supprime', true, 'code', v_client.code);
end;
$$;

revoke execute on function public.supprimer_mon_compte(text) from public, anon;
grant execute on function public.supprimer_mon_compte(text) to authenticated;


-- 4. Contrôle ---------------------------------------------------------------------------------
-- fonction : 1 ; ouverte_aux_visiteurs : false ; colonne : 1.
select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'supprimer_mon_compte')                as fonction,
       (select bool_or(has_function_privilege('anon', p.oid, 'execute'))
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'supprimer_mon_compte')                as ouverte_aux_visiteurs,
       (select count(*) from information_schema.columns
        where table_schema = 'public' and table_name = 'clients' and column_name = 'supprime_le')
                                                                                          as colonne;
