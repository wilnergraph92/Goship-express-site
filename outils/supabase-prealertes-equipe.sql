-- =============================================================================
-- Goship Express — l'équipe modifie ou supprime une pré-alerte (16/11/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce fichier
-- AJOUTE deux fonctions et resserre deux règles d'accès de la table prealertes.
-- Il ne change aucune donnée, aucune colonne, aucune fonction existante, et se
-- relance autant de fois qu'on veut.
--
-- Ordre d'installation : le dernier de la chaîne (outils/migrations.txt), après
-- supabase-battement.sql.
--
-- Pourquoi : demande du CEO du 16/11/2026 (« Dans le tableau de bord, dans l'onglet
-- pré-alerte, ajoute l'option supprimer, modifier, dans chaque pré-alerte »). Un client
-- se trompe de numéro, de magasin ou annonce deux fois le même achat ; l'équipe ne
-- pouvait que lire.
--
-- Les règles, toutes ici (la page ne décide de rien) :
--   modifier_prealerte(pré-alerte, champs, motif)   shipments.edit (administrateur,
--       gérant, employé) ; seulement une pré-alerte EN ATTENTE ; magasin, contenu,
--       numéro de suivi, valeur, mode ; mêmes contrôles qu'à la création
--       (creer_prealerte, supabase-mobile.sql) : magasin et contenu obligatoires, numéro
--       lisible, pas déjà annoncé par ce client, pas déjà arrivé dans un de ses colis ;
--       motif facultatif. Un numéro changé détache l'ancien suivi du transporteur et en
--       ouvre un nouveau si le suivi automatique des pré-alertes est allumé, comme pour
--       une nouvelle pré-alerte (supabase-synchro-suivi.sql, suivre_prealerte), sans
--       jamais faire échouer la modification.
--   supprimer_prealerte(pré-alerte, motif)          shipments.delete (administrateur) ;
--       motif obligatoire (5 caractères au moins) ; refusée pour une pré-alerte déjà
--       reçue (elle est rattachée à un colis : c'est son historique). La ligne est
--       effacée, comme quand le client la supprime lui-même dans l'application, et le
--       journal d'audit en garde une copie complète avec le motif.
--   Chaque modification et chaque suppression est journalisée (journal_audit :
--   prealerte.modification, prealerte.suppression) : qui, quand, avant, après, motif.
--
-- Les règles d'accès de la table : jusqu'ici, un compte de l'équipe (shipments.edit)
-- pouvait aussi modifier ou effacer une pré-alerte directement, sans contrôle ni trace.
-- Le tableau de bord ne s'en est jamais servi. Ces deux chemins sont fermés : l'équipe
-- passe par les deux fonctions ci-dessus. Le client garde les siens tels quels
-- (l'application mobile modifie et supprime ses propres pré-alertes en direct).
--
-- Ce que ce fichier ne fait pas : aucun statut ni événement de colis, aucune
-- notification, rien dans l'espace client ni l'application : une pré-alerte modifiée
-- s'y affiche modifiée, une pré-alerte supprimée y disparaît.
--
-- Contenu :
--    1. garde : la chaîne est-elle à jour ?
--    2. prealerte_publique(ligne) : la forme rendue à la page
--    3. modifier_prealerte(pré-alerte, champs, motif)
--    4. supprimer_prealerte(pré-alerte, motif)
--    5. règles d'accès : le client seul en direct
--    6. droits
--    7. contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regprocedure('public.battement()') is null
     or to_regprocedure('public.creer_prealerte(uuid, text, text, text, numeric, text)') is null
     or to_regprocedure('public.suivi_externe_ouvrir(text, text, text)') is null
     or to_regprocedure('public.auditer(text, text, text, jsonb, jsonb)') is null then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt), jusqu''à supabase-battement.sql, puis ce fichier.';
  end if;
end;
$garde$;


-- 2. La forme rendue à la page -------------------------------------------------------
-- Les champs que le tableau de bord lit déjà (API.admin.prealertes), sans rien du client.
create or replace function public.prealerte_publique(p public.prealertes)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('id', p.id, 'client_id', p.client_id, 'magasin', p.magasin,
                            'description', p.description, 'suivi_transporteur', p.suivi_transporteur,
                            'valeur_usd', p.valeur_usd, 'service', p.service, 'statut', p.statut,
                            'colis_id', p.colis_id, 'cree_le', p.cree_le)
$$;


-- 3. Modifier une pré-alerte en attente ------------------------------------------------
-- p_champs : seules les clés présentes changent — magasin, description,
-- suivi_transporteur, valeur_usd (null = pas de valeur), service.
create or replace function public.modifier_prealerte(p_prealerte uuid, p_champs jsonb, p_motif text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_avant   public.prealertes;
  v_apres   public.prealertes;
  v_champs  jsonb := coalesce(p_champs, '{}'::jsonb);
  v_magasin text;
  v_desc    text;
  v_suivi   text;
  v_valeur  numeric;
  v_service text;
  v_numero  text;
  v_diff_av jsonb := '{}'::jsonb;
  v_diff_ap jsonb := '{}'::jsonb;
  v_cle     text;
  v_suivi_id uuid;
begin
  perform public.exiger_permission('shipments.edit');
  if jsonb_typeof(v_champs) <> 'object' then
    perform public.erreur_metier('INVALID_INPUT', 'Données incomplètes.');
  end if;

  select * into v_avant from public.prealertes where id = p_prealerte for update;
  if not found then
    perform public.erreur_metier('PREALERT_NOT_FOUND', 'Cette pré-alerte n''existe plus : rechargez la liste.');
  end if;
  if v_avant.statut <> 'attente' then
    perform public.erreur_metier('PREALERT_NOT_PENDING',
      'Cette pré-alerte n''est plus en attente : elle ne se modifie plus.');
  end if;

  -- Les valeurs voulues : celles d'avant, sauf les clés envoyées
  v_magasin := left(trim(case when v_champs ? 'magasin' then coalesce(v_champs ->> 'magasin', '') else v_avant.magasin end), 80);
  v_desc    := left(trim(case when v_champs ? 'description' then coalesce(v_champs ->> 'description', '') else v_avant.description end), 300);
  -- Même mise en forme qu'à la création : majuscules, sans espaces
  v_suivi   := upper(regexp_replace(case when v_champs ? 'suivi_transporteur'
                                         then coalesce(v_champs ->> 'suivi_transporteur', '')
                                         else v_avant.suivi_transporteur end, '\s', '', 'g'));
  v_service := coalesce(nullif(trim(case when v_champs ? 'service' then v_champs ->> 'service' else v_avant.service end), ''), 'aerien');
  if v_champs ? 'valeur_usd' then
    if jsonb_typeof(v_champs -> 'valeur_usd') = 'null' or nullif(trim(v_champs ->> 'valeur_usd'), '') is null then
      v_valeur := null;
    elsif (v_champs ->> 'valeur_usd') ~ '^\s*-?[0-9]+(\.[0-9]+)?\s*$' then
      v_valeur := round((v_champs ->> 'valeur_usd')::numeric, 2);
    else
      perform public.erreur_metier('INVALID_VALUE', 'La valeur doit être comprise entre 0 et 100 000 $.');
    end if;
  else
    v_valeur := v_avant.valeur_usd;
  end if;

  -- Les contrôles de creer_prealerte
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
  if v_valeur is not null and (v_valeur < 0 or v_valeur > 100000) then
    perform public.erreur_metier('INVALID_VALUE', 'La valeur doit être comprise entre 0 et 100 000 $.');
  end if;
  if v_service not in ('aerien', 'maritime', 'terrestre') then
    perform public.erreur_metier('INVALID_SERVICE', 'Service inconnu.');
  end if;
  if v_suivi <> '' and v_suivi is distinct from upper(v_avant.suivi_transporteur) then
    if exists (select 1 from public.prealertes
                where client_id = v_avant.client_id and statut = 'attente' and id <> v_avant.id
                  and upper(trim(suivi_transporteur)) = v_suivi) then
      perform public.erreur_metier('PREALERT_DUPLICATE',
        'Ce numéro de suivi est déjà annoncé par ce client dans une autre pré-alerte.');
    end if;
    select numero into v_numero from public.colis
     where client_id = v_avant.client_id and suivi_transporteur <> '' and upper(suivi_transporteur) = v_suivi
     limit 1;
    if v_numero is not null then
      perform public.erreur_metier('PREALERT_ALREADY_RECEIVED',
        'Ce colis est déjà arrivé : c''est le colis ' || v_numero || '.');
    end if;
  end if;
  if p_motif is not null and length(btrim(p_motif)) > 300 then
    perform public.erreur_metier('INVALID_INPUT', 'Motif trop long (300 caractères au plus).');
  end if;

  -- Ce qui change vraiment
  foreach v_cle in array array['magasin', 'description', 'suivi_transporteur', 'valeur_usd', 'service'] loop
    if (case v_cle
          when 'magasin' then v_magasin is distinct from v_avant.magasin
          when 'description' then v_desc is distinct from v_avant.description
          when 'suivi_transporteur' then v_suivi is distinct from v_avant.suivi_transporteur
          when 'valeur_usd' then v_valeur is distinct from v_avant.valeur_usd
          else v_service is distinct from v_avant.service end) then
      v_diff_av := v_diff_av || jsonb_build_object(v_cle, to_jsonb(v_avant) -> v_cle);
      v_diff_ap := v_diff_ap || jsonb_build_object(v_cle, case v_cle
          when 'magasin' then to_jsonb(v_magasin) when 'description' then to_jsonb(v_desc)
          when 'suivi_transporteur' then to_jsonb(v_suivi) when 'valeur_usd' then to_jsonb(v_valeur)
          else to_jsonb(v_service) end);
    end if;
  end loop;
  if v_diff_ap = '{}'::jsonb then
    return public.prealerte_publique(v_avant) || jsonb_build_object('deja', true);
  end if;

  update public.prealertes
     set magasin = v_magasin, description = v_desc, suivi_transporteur = v_suivi,
         valeur_usd = v_valeur, service = v_service,
         -- Un autre numéro : l'ancien suivi du transporteur ne parle plus de cet achat
         suivi_externe_id = case when v_diff_ap ? 'suivi_transporteur' then null else suivi_externe_id end
   where id = v_avant.id
  returning * into v_apres;

  perform set_config('goship.motif', left(btrim(coalesce(p_motif, '')), 300), true);
  perform public.auditer('prealerte.modification', 'prealerte', v_avant.id::text, v_diff_av, v_diff_ap);

  -- Le nouveau numéro, suivi comme celui d'une nouvelle pré-alerte (suivre_prealerte) :
  -- seulement si l'interrupteur est allumé, jamais d'échec de la modification
  if v_diff_ap ? 'suivi_transporteur' and v_suivi <> ''
     and exists (select 1 from public.fournisseurs_suivi where (actif or essai) and suivre_prealertes) then
    begin
      v_suivi_id := public.suivi_externe_ouvrir(v_suivi, null, 'prealerte');
      if v_suivi_id is not null then
        update public.prealertes set suivi_externe_id = v_suivi_id where id = v_apres.id and suivi_externe_id is null;
      end if;
    exception when others then
      begin
        insert into public.suivis_externes_journal (operation, resultat, code_erreur)
        values ('prealerte', 'erreur', left('SQLSTATE_' || sqlstate, 60));
      exception when others then
        null;
      end;
    end;
  end if;

  return public.prealerte_publique(v_apres) || jsonb_build_object('deja', false);
end;
$$;


-- 4. Supprimer une pré-alerte --------------------------------------------------------
create or replace function public.supprimer_prealerte(p_prealerte uuid, p_motif text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ligne  public.prealertes;
  v_numero text;
begin
  perform public.exiger_permission('shipments.delete');
  if length(btrim(coalesce(p_motif, ''))) < 5 then
    perform public.erreur_metier('REASON_REQUIRED', 'Indiquez un motif (5 caractères au moins).');
  end if;

  select * into v_ligne from public.prealertes where id = p_prealerte for update;
  if not found then
    perform public.erreur_metier('PREALERT_NOT_FOUND', 'Cette pré-alerte n''existe plus : rechargez la liste.');
  end if;
  if v_ligne.statut = 'recu' then
    select numero into v_numero from public.colis where id = v_ligne.colis_id;
    perform public.erreur_metier('PREALERT_RECEIVED',
      'Cette pré-alerte est rattachée au colis ' || coalesce(v_numero, 'reçu') || ' : elle ne se supprime pas.');
  end if;

  perform set_config('goship.motif', left(btrim(p_motif), 300), true);
  perform public.auditer('prealerte.suppression', 'prealerte', v_ligne.id::text, to_jsonb(v_ligne), null);
  delete from public.prealertes where id = v_ligne.id;
  return jsonb_build_object('id', v_ligne.id, 'supprimee', true);
end;
$$;


-- 5. Règles d'accès : le client seul en direct ------------------------------------------
-- Avant : « client_id = moi OU peut('shipments.edit') ». L'équipe passe désormais par les
-- fonctions ci-dessus ; le client garde exactement ses droits (application mobile).
drop policy if exists prealertes_modification on public.prealertes;
create policy prealertes_modification on public.prealertes
  for update to authenticated
  using (client_id = (select auth.uid()))
  with check (client_id = (select auth.uid()));

drop policy if exists prealertes_suppression on public.prealertes;
create policy prealertes_suppression on public.prealertes
  for delete to authenticated
  using (client_id = (select auth.uid()));


-- 6. Droits --------------------------------------------------------------------------
revoke execute on function public.prealerte_publique(public.prealertes) from public, anon, authenticated;
revoke execute on function public.modifier_prealerte(uuid, jsonb, text) from public, anon;
revoke execute on function public.supprimer_prealerte(uuid, text) from public, anon;
grant execute on function public.modifier_prealerte(uuid, jsonb, text) to authenticated;
grant execute on function public.supprimer_prealerte(uuid, text) to authenticated;


-- 7. Contrôle ------------------------------------------------------------------------
-- fonctions : 2 ; ouvertes_aux_visiteurs : false ; regles_equipe : 0 (plus aucune règle
-- de modification ou de suppression ne passe par peut())
select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname in ('modifier_prealerte', 'supprimer_prealerte')) as fonctions,
       (has_function_privilege('anon', 'public.modifier_prealerte(uuid, jsonb, text)', 'execute')
        or has_function_privilege('anon', 'public.supprimer_prealerte(uuid, text)', 'execute')) as ouvertes_aux_visiteurs,
       (select count(*) from pg_policies
         where schemaname = 'public' and tablename = 'prealertes' and cmd in ('UPDATE', 'DELETE')
           and (coalesce(qual, '') ~ 'peut' or coalesce(with_check, '') ~ 'peut')) as regles_equipe;
