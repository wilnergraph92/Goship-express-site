-- =============================================================================
-- Goship Express — Application mobile (Phase 10, 26/09/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce
-- fichier AJOUTE une colonne facultative, deux index et une fonction. Il ne
-- supprime rien, ne change aucune donnée ni aucune règle existante, et peut
-- être relancé autant de fois qu'on veut.
--
-- Ordre d'installation : supabase.sql, supabase-facturation.sql,
-- supabase-services.sql, supabase-evenements.sql, supabase-scanner.sql,
-- supabase-finances.sql, supabase-tableau-de-bord.sql, supabase-analytics.sql,
-- puis ce fichier.
--
-- L'application mobile (dépôt goship-express-app) lit tout le reste avec les
-- fonctions et les règles qui existent déjà, comme l'espace client du site :
-- ses colis (table colis, filtrée par les règles de sécurité), leurs étapes
-- publiques (colis_historique), son résumé (mon_resume), ses factures, ses
-- paiements et son solde (mes_factures), le suivi (suivre_colis), son rôle
-- (mes_permissions), son téléphone (enregistrer_appareil). Rien de tout cela
-- n'est recopié dans l'application.
--
-- Ce fichier n'ajoute que ce qui manquait pour qu'une pré-alerte envoyée
-- depuis un téléphone soit sûre :
--    1. une seule pré-alerte par envoi, même si la requête part deux fois
--       (double appui, réseau lent, nouvel essai après un délai dépassé) ;
--    2. une validation par la base, pas seulement par l'écran ;
--    3. le refus d'un doublon (même numéro de suivi déjà annoncé, ou colis
--       déjà arrivé) ;
--    4. un index pour la liste paginée des colis d'un client.
--
-- Compatibilité : l'ancien chemin (insert direct dans prealertes, règles de
-- sécurité inchangées) reste ouvert, pour que les versions déjà installées de
-- l'application continuent de fonctionner, et qu'un retour à la version
-- précédente de l'application reste possible.
--
-- Permission : shipments.view — un client annonce SES colis (shipments.view:own),
-- la pré-alerte est toujours à son nom (auth.uid()), jamais à celui d'un autre.
-- =============================================================================


-- 1. Index -------------------------------------------------------------------------
-- La liste « Mes colis » : les colis d'un client, du plus récent au plus ancien,
-- page par page.
create index if not exists colis_client_maj_idx on public.colis (client_id, maj_le desc);


-- 2. La clé d'envoi ----------------------------------------------------------------
-- Tirée au hasard par l'application pour chaque pré-alerte qu'elle envoie, et
-- renvoyée telle quelle si la requête est répétée : la base reconnaît alors
-- l'envoi et ne crée rien de plus. Vide pour les pré-alertes d'avant.
alter table public.prealertes add column if not exists cle_envoi uuid;
create unique index if not exists prealertes_cle_envoi_idx
  on public.prealertes (client_id, cle_envoi) where cle_envoi is not null;


-- 3. Créer une pré-alerte ----------------------------------------------------------
-- Rend la pré-alerte (id, magasin, description, suivi_transporteur, valeur_usd,
-- service, statut, cree_le) et « deja » : vrai si c'est la répétition d'un
-- envoi déjà enregistré. Erreurs (message = code, detail = phrase, hint = goship) :
--   PERMISSION_DENIED            personne de connecté, ou compte sans shipments.view
--   PREALERT_STORE_REQUIRED      magasin vide
--   PREALERT_DESCRIPTION_REQUIRED contenu vide
--   INVALID_TRACKING             numéro de suivi illisible
--   INVALID_VALUE                valeur négative ou absurde
--   INVALID_SERVICE              service inconnu
--   PREALERT_DUPLICATE           ce numéro de suivi est déjà annoncé et attendu
--   PREALERT_ALREADY_RECEIVED    un colis de ce client porte déjà ce numéro
--   TOO_MANY_PREALERTS           60 pré-alertes en attente : la limite existante
create or replace function public.creer_prealerte(p_cle uuid,
                                                  p_magasin text,
                                                  p_description text,
                                                  p_suivi text default '',
                                                  p_valeur numeric default null,
                                                  p_service text default 'aerien')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_moi      uuid := auth.uid();
  v_magasin  text := left(trim(coalesce(p_magasin, '')), 80);
  v_desc     text := left(trim(coalesce(p_description, '')), 300);
  -- Même mise en forme que le déclencheur borner_prealerte : majuscules, sans
  -- espaces (un numéro recopié à la main en porte souvent)
  v_suivi    text := upper(regexp_replace(coalesce(p_suivi, ''), '\s', '', 'g'));
  v_service  text := coalesce(nullif(trim(p_service), ''), 'aerien');
  v_ligne    public.prealertes;
  v_numero   text;
  v_deja     boolean := false;
begin
  if v_moi is null then
    perform public.erreur_metier('PERMISSION_DENIED', 'Connectez-vous pour annoncer un achat.');
  end if;
  perform public.exiger_permission('shipments.view', v_moi);

  -- Un seul envoi à la fois pour ce client : deux requêtes simultanées (la
  -- même répétée, ou deux avec le même numéro) passent l'une après l'autre
  perform pg_advisory_xact_lock(hashtext('goship-prealerte:' || v_moi::text));

  -- La même requête, répétée : on rend ce qui a déjà été enregistré
  if p_cle is not null then
    select * into v_ligne from public.prealertes where client_id = v_moi and cle_envoi = p_cle;
    if found then
      v_deja := true;
    end if;
  end if;

  if not v_deja then
    if v_magasin = '' then
      perform public.erreur_metier('PREALERT_STORE_REQUIRED', 'Indiquez le magasin.');
    end if;
    if v_desc = '' then
      perform public.erreur_metier('PREALERT_DESCRIPTION_REQUIRED', 'Indiquez le contenu du colis.');
    end if;
    if v_suivi <> '' and v_suivi !~ '^[A-Z0-9-]{6,60}$' then
      perform public.erreur_metier('INVALID_TRACKING',
        'Numéro de suivi illisible : lettres et chiffres seulement, de 6 à 60.');
    end if;
    if p_valeur is not null and (p_valeur < 0 or p_valeur > 100000) then
      perform public.erreur_metier('INVALID_VALUE', 'La valeur doit être comprise entre 0 et 100 000 $.');
    end if;
    if v_service not in ('aerien', 'maritime', 'terrestre') then
      perform public.erreur_metier('INVALID_SERVICE', 'Service inconnu.');
    end if;

    if v_suivi <> '' then
      if exists (select 1 from public.prealertes
                  where client_id = v_moi and statut = 'attente'
                    and upper(trim(suivi_transporteur)) = v_suivi) then
        perform public.erreur_metier('PREALERT_DUPLICATE',
          'Ce numéro de suivi est déjà annoncé : la pré-alerte est dans votre liste.');
      end if;
      select numero into v_numero from public.colis
       where client_id = v_moi and suivi_transporteur <> '' and upper(suivi_transporteur) = v_suivi
       limit 1;
      if v_numero is not null then
        perform public.erreur_metier('PREALERT_ALREADY_RECEIVED',
          'Ce colis est déjà arrivé : c''est le colis ' || v_numero || '.');
      end if;
    end if;

    if (select count(*) from public.prealertes where client_id = v_moi and statut = 'attente') >= 60 then
      perform public.erreur_metier('TOO_MANY_PREALERTS',
        'Vous avez déjà 60 pré-alertes en attente : supprimez celles qui ne servent plus.');
    end if;

    insert into public.prealertes (client_id, magasin, description, suivi_transporteur, valeur_usd, service, cle_envoi)
    values (v_moi, v_magasin, v_desc, v_suivi, round(p_valeur, 2), v_service, p_cle)
    returning * into v_ligne;
  end if;

  return jsonb_build_object(
    'id', v_ligne.id, 'magasin', v_ligne.magasin, 'description', v_ligne.description,
    'suivi_transporteur', v_ligne.suivi_transporteur, 'valeur_usd', v_ligne.valeur_usd,
    'service', v_ligne.service, 'statut', v_ligne.statut, 'cree_le', v_ligne.cree_le,
    'deja', v_deja);
end;
$$;

revoke execute on function public.creer_prealerte(uuid, text, text, text, numeric, text) from public, anon;
grant execute on function public.creer_prealerte(uuid, text, text, text, numeric, text) to authenticated;


-- Contrôle ---------------------------------------------------------------------------------
-- fonction : 1 ; ouverte_aux_visiteurs : false ; index_sur_2 : 2 ; colonne : 1.
select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'creer_prealerte')                     as fonction,
       (select bool_or(has_function_privilege('anon', p.oid, 'execute'))
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'creer_prealerte')                     as ouverte_aux_visiteurs,
       (select count(*) from pg_indexes
        where schemaname = 'public' and indexname in ('colis_client_maj_idx', 'prealertes_cle_envoi_idx'))
                                                                                          as index_sur_2,
       (select count(*) from information_schema.columns
        where table_schema = 'public' and table_name = 'prealertes' and column_name = 'cle_envoi')
                                                                                          as colonne;
