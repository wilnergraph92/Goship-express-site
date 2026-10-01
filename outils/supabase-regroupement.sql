-- =============================================================================
-- Goship Express — Sortir des colis d'une facture regroupée (28/09/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce fichier
-- AJOUTE une fonction. Il ne supprime rien, ne change aucune donnée existante,
-- et peut être relancé autant de fois qu'on veut.
--
-- Ordre d'installation : le dernier de la chaîne (outils/migrations.txt), après
-- supabase-compte.sql.
--
-- Le regroupement (regrouper_factures, supabase-finances.sql) réunit plusieurs
-- factures d'un client en une seule. Il arrive ensuite qu'un client veuille payer
-- un seul de ces colis tout de suite, ou qu'un colis doive repartir sur sa propre
-- facture. sortir_du_regroupement fait le chemin inverse, pour les colis choisis,
-- avec les règles de toujours (une facture ne se modifie pas, elle s'annule et une
-- autre la remplace) :
--   - la facture regroupée est annulée, avec son motif ;
--   - les colis choisis passent sur une nouvelle facture ;
--   - les autres, sur une seconde nouvelle facture, que la facture annulée désigne
--     comme sa remplaçante (remplacee_par) : le regroupement continue sans eux.
-- Les deux nouvelles passent par creer_facture : prix des colis tels qu'inscrits
-- sur eux, frais de service une fois PAR FACTURE — sortir un colis rajoute donc
-- ses frais de service, que le regroupement avait fait économiser. L'échéance et
-- la note de la facture regroupée sont reprises ; pas son lien de paiement, qui
-- porte son montant (PayPal) : le tableau de bord en pose un neuf sur chacune.
--
-- Refusé (et rien n'est changé), comme pour regrouper :
--   - une facture payée, annulée, ou qui a reçu un paiement (il a une vie comptable :
--     on n'en déplace pas les colis) ;
--   - une facture qui n'est pas une facture de colis ;
--   - aucun colis choisi, un colis qui n'est pas sur cette facture, ou tous ses
--     colis (il en faut au moins un qui reste : sinon, c'est annuler la facture).
--
-- Encaisser un seul colis d'un regroupement = le sortir, puis enregistrer le
-- paiement sur sa nouvelle facture (enregistrer_paiement, comme toujours).
--
-- Contenu :
--    1. garde : la chaîne est-elle à jour ?
--    2. sortir_du_regroupement
--    3. contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regprocedure('public.regrouper_factures(uuid[], text)') is null
     or to_regprocedure('public.creer_facture(uuid, uuid[], jsonb, text)') is null
     or to_regprocedure('public.facture_complete(uuid)') is null then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt), puis ce fichier.';
  end if;
end;
$garde$;


-- 2. sortir_du_regroupement ----------------------------------------------------------
--   p_facture : la facture regroupée
--   p_colis   : les colis qui en sortent (sur leur propre facture)
--   p_cle     : identifie la demande ; renvoyée (double clic, réseau coupé), elle rend
--               les factures déjà créées sans rien refaire
-- Réponse : { facture (celle des colis sortis), reste (celle des autres),
--             annulee (numéro de la facture regroupée), deja }
create or replace function public.sortir_du_regroupement(p_facture uuid, p_colis uuid[], p_cle text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cle text := nullif(trim(coalesce(p_cle, '')), '');
  f public.factures;
  v_tous uuid[];
  v_sortis uuid[];
  v_reste uuid[];
  v_numeros text;
  v_champs jsonb;
  v_sortie uuid;
  v_restante uuid;
  v_avant text := coalesce(current_setting('goship.finances', true), '');
begin
  perform public.exiger_permission('invoices.create');
  perform public.exiger_permission('invoices.cancel');
  if v_cle is not null then
    perform pg_advisory_xact_lock(hashtextextended('goship-creer-facture:' || v_cle, 0));
    select id into v_sortie from public.factures where cle_idempotence = v_cle;
    if found then
      select id into v_restante from public.factures where cle_idempotence = v_cle || ':reste';
      return jsonb_build_object(
        'facture', public.facture_complete(v_sortie),
        'reste', case when v_restante is not null then public.facture_complete(v_restante) end,
        'annulee', (select numero from public.factures where id = p_facture),
        'deja', true);
    end if;
  end if;

  select * into f from public.factures where id = p_facture for update;
  if not found then
    perform public.erreur_metier('INVOICE_NOT_FOUND', 'Aucune facture avec cet identifiant.');
  end if;
  if f.statut <> 'a_payer' then
    perform public.erreur_metier('INVOICE_NOT_GROUPABLE',
      'La facture ' || f.numero || ' est ' || case when f.statut = 'payee' then 'payée' else 'annulée' end ||
      ' : ses colis ne se déplacent plus.');
  end if;
  if exists (select 1 from public.paiements where facture_id = f.id and annule_le is null) then
    perform public.erreur_metier('INVOICE_HAS_PAYMENTS',
      'La facture ' || f.numero || ' a déjà reçu un paiement : ses colis ne se déplacent plus.');
  end if;
  if not exists (select 1 from public.facture_lignes where facture_id = f.id)
     or exists (select 1 from public.facture_lignes where facture_id = f.id and colis_id is null) then
    perform public.erreur_metier('INVOICE_NOT_GROUPABLE',
      'La facture ' || f.numero || ' n''est pas une facture de colis.');
  end if;

  select array_agg(colis_id order by colis_id) into v_tous from public.facture_lignes where facture_id = f.id;
  select array_agg(distinct i order by i) into v_sortis from unnest(coalesce(p_colis, '{}')) i where i is not null;
  if v_sortis is null then
    perform public.erreur_metier('INVALID_INPUT', 'Choisissez le colis qui sort de la facture.');
  end if;
  if not (v_sortis <@ v_tous) then
    perform public.erreur_metier('INVALID_INPUT',
      'Un colis choisi n''est pas sur la facture ' || f.numero || '.');
  end if;
  select array_agg(i order by i) into v_reste from unnest(v_tous) i where not (i = any (v_sortis));
  if v_reste is null then
    perform public.erreur_metier('INVALID_INPUT',
      'Tous les colis de la facture ' || f.numero || ' sont choisis : il doit en rester au moins un. '
      || 'Pour tout défaire, annulez la facture.');
  end if;

  select string_agg(c.numero, ', ' order by c.numero) into v_numeros from public.colis c where c.id = any (v_sortis);
  perform set_config('goship.finances', 'on', true);
  update public.factures
     set statut = 'annulee', annulee_le = now(), annulee_par = auth.uid(),
         motif_annulation = 'Sortie du regroupement : ' || v_numeros
   where id = f.id;
  perform set_config('goship.finances', v_avant, true);

  v_champs := jsonb_build_object('echeance_le', f.echeance_le, 'note', f.note);
  v_sortie := (public.creer_facture(f.client_id, v_sortis, v_champs, v_cle) -> 'facture' ->> 'id')::uuid;
  v_restante := (public.creer_facture(f.client_id, v_reste, v_champs, v_cle || ':reste') -> 'facture' ->> 'id')::uuid;

  perform set_config('goship.finances', 'on', true);
  update public.factures set remplacee_par = v_restante where id = f.id;
  perform set_config('goship.finances', v_avant, true);

  perform public.auditer('facture.sortie_regroupement', 'facture', f.id::text,
                         jsonb_build_object('numero', f.numero, 'montant_usd', f.montant_usd),
                         jsonb_build_object('colis', v_numeros,
                                            'facture', (select numero from public.factures where id = v_sortie),
                                            'reste', (select numero from public.factures where id = v_restante)));
  return jsonb_build_object('facture', public.facture_complete(v_sortie), 'reste', public.facture_complete(v_restante),
                            'annulee', f.numero, 'deja', false);
end;
$$;

revoke execute on function public.sortir_du_regroupement(uuid, uuid[], text) from public, anon;
grant execute on function public.sortir_du_regroupement(uuid, uuid[], text) to authenticated;


-- 3. Contrôle ---------------------------------------------------------------------------------
-- fonction : 1 ; ouverte_aux_visiteurs : false.
select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'sortir_du_regroupement')               as fonction,
       (select bool_or(has_function_privilege('anon', p.oid, 'execute'))
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'sortir_du_regroupement')               as ouverte_aux_visiteurs;
