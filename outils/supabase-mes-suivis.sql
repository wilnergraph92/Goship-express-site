-- =============================================================================
-- Goship Express — « Mes colis en route » : le suivi du transporteur vu par le client
-- (Phase 4 du suivi universel, 12/11/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce fichier
-- AJOUTE une seule fonction de lecture. Il n'écrit rien, ne change aucune fonction
-- existante ni aucune donnée, n'ouvre aucune table, et peut être relancé autant de
-- fois qu'on veut.
--
-- Ordre d'installation : le dernier de la chaîne (outils/migrations.txt), après
-- supabase-synchro-suivi.sql.
--
-- Pourquoi : les Phases 2 et 3 suivent un carton chez son transporteur, jusqu'à Miami.
-- Le client, lui, n'en voyait rien. Dossier de conception validé par le CEO le
-- 12/11/2026 :
--    · le client CONNECTÉ voit ses propres achats annoncés (ses pré-alertes) et, pour
--      chacun, où en est son transporteur ; la page publique de suivi ne montre rien
--      d'externe ;
--    · la lecture part de SES pré-alertes (prealertes.client_id = auth.uid()) et ne
--      suit que le lien posé par le moteur (prealertes.suivi_externe_id). Deux clients
--      qui ont annoncé le même numéro voient chacun le suivi du transporteur, jamais
--      que l'autre l'a annoncé ;
--    · RIEN ne sort d'un fournisseur qui n'est pas VERIFIED et en service (actif) :
--      un fournisseur en essai ne montre rien aux clients (règle de la Phase 2). Tant
--      que 17TRACK n'a pas confirmé par écrit le droit d'afficher, la carte dit
--      seulement que le suivi n'est pas encore disponible ;
--    · aucune donnée du destinataire : le moteur n'en a jamais rangé.
--
-- Le client ne voit jamais un code : la page traduit « message » et « statut » en
-- phrases (compte.js). Le texte d'origine du transporteur reste dans la chronologie.
--
-- Règles inchangées : aucune écriture, aucun lien avec colis.statut ni colis_historique ;
-- creer_prealerte, la table prealertes et ce que lit l'application mobile ne changent pas ;
-- aucune permission nouvelle ; rien d'ouvert aux visiteurs.
--
-- Contenu :
--    1. garde : la chaîne est-elle à jour ?
--    2. la lecture : mes_suivis_externes()
--    3. droits
--    4. contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regprocedure('public.planifier_suivis_externes()') is null
     or to_regprocedure('public.creer_prealerte(uuid, text, text, text, numeric, text)') is null then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt), jusqu''à supabase-synchro-suivi.sql, puis ce fichier.';
  end if;
end;
$garde$;


-- 2. La lecture -------------------------------------------------------------------
-- Les achats annoncés par le client connecté : ceux qui attendent (pas encore à Miami) et
-- ceux arrivés depuis 14 jours (la carte mène alors au colis GoShip). Les annulés n'y sont
-- pas. Forme de la réponse (l'application mobile la lira en Phase 5 : elle ne change plus) :
--   { "achats": [ {
--       id, magasin, description, service, valeur_usd, statut ('attente' | 'recu'), cree_le,
--       numero_suivi            le numéro tel que le client l'a annoncé,
--       colis                   { numero } quand le colis est arrivé, sinon null,
--       message                 un code (NO_TRACKING, ORDER_NUMBER_DETECTED, UNSUPPORTED_TRACKING,
--                               INVALID_TRACKING, PENDING_FIRST_SCAN, CARRIER_UNKNOWN,
--                               AMAZON_TBA_LIMITATION, PROVIDER_UNAVAILABLE, TRACKING_EXPIRED) ou null,
--       suivi                   null, ou ce qu'en dit le transporteur :
--         { transporteur, transporteur_nom, statut, dernier_lieu, dernier_evenement_le,
--           livraison_estimee_le, mis_a_jour_le, termine,
--           evenements: [ { survenu_le, statut, description, lieu, pays } ] }   (100 au plus)
--   } ] }
create or replace function public.mes_suivis_externes()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_moi uuid := auth.uid();
begin
  if v_moi is null then
    perform public.erreur_metier('PERMISSION_DENIED', 'Connectez-vous pour voir vos colis en route.');
  end if;
  perform public.exiger_permission('shipments.view', v_moi);

  return jsonb_build_object('achats', coalesce((
    select jsonb_agg(a.achat order by a.ordre desc, a.cree_le desc)
      from (
        select p.cree_le,
               -- Ceux qui attendent d'abord, les arrivés ensuite
               case when p.statut = 'attente' then 1 else 0 end as ordre,
               jsonb_build_object(
                 'id', p.id,
                 'magasin', p.magasin,
                 'description', p.description,
                 'service', p.service,
                 'valeur_usd', p.valeur_usd,
                 'statut', p.statut,
                 'cree_le', p.cree_le,
                 'numero_suivi', p.suivi_transporteur,
                 -- Le colis GoShip, seulement s'il est bien à ce client
                 'colis', (select jsonb_build_object('numero', c.numero)
                             from public.colis c
                            where p.statut = 'recu' and c.id = p.colis_id and c.client_id = v_moi),
                 'message', case
                   when p.statut = 'recu' then null
                   when coalesce(p.suivi_transporteur, '') = '' then 'NO_TRACKING'
                   when public.nature_numero(p.suivi_transporteur) = 'commande_amazon' then 'ORDER_NUMBER_DETECTED'
                   when v.id is not null then v.code_resultat
                   -- Un suivi relié mais pas montrable : seuls nos propres constats (numéro de
                   -- commande, transporteur exclu) passent ; le reste vient du fournisseur
                   when s.code_resultat in ('ORDER_NUMBER_DETECTED', 'UNSUPPORTED_TRACKING') then s.code_resultat
                   else 'UNSUPPORTED_TRACKING'
                 end,
                 'suivi', case when p.statut = 'attente' and v.id is not null then jsonb_build_object(
                   'transporteur', v.transporteur,
                   -- Le nom seulement pour un transporteur que la liste connaît ; sinon la page
                   -- dit « transporteur non identifié »
                   'transporteur_nom', (select t.nom from public.transporteurs_connus() t where t.code = v.transporteur),
                   'statut', v.statut,
                   'dernier_lieu', v.dernier_lieu,
                   'dernier_evenement_le', v.dernier_evenement_le,
                   -- Seulement si le transporteur la donne : jamais une estimation de GoShip
                   'livraison_estimee_le', v.livraison_estimee_le,
                   'mis_a_jour_le', v.derniere_synchro_le,
                   'termine', v.fin_motif is not null,
                   'evenements', coalesce((
                     select jsonb_agg(jsonb_build_object('survenu_le', e.survenu_le, 'statut', e.statut,
                                                         'description', e.description, 'lieu', e.lieu,
                                                         'pays', e.pays)
                                      order by e.survenu_le desc, e.id desc)
                       from (select * from public.suivis_externes_evenements e
                              where e.suivi_id = v.id
                              order by e.survenu_le desc, e.id desc
                              limit 100) e), '[]'::jsonb)) end
               ) as achat
          from public.prealertes p
          left join public.suivis_externes s on s.id = p.suivi_externe_id
          -- Le suivi montrable : celui d'un fournisseur VERIFIED et en service
          left join public.suivis_externes v
                 on v.id = s.id
                and exists (select 1 from public.fournisseurs_suivi f
                             where f.code = s.fournisseur and f.actif and f.conformite = 'VERIFIED')
         where p.client_id = v_moi
           and (p.statut = 'attente'
                -- Arrivé : la date de réception est celle du colis GoShip
                or (p.statut = 'recu'
                    and coalesce((select c.cree_le from public.colis c where c.id = p.colis_id), p.cree_le)
                        > now() - interval '14 days'))
         order by p.cree_le desc
         limit 100
      ) a), '[]'::jsonb));
end;
$$;


-- 3. Droits --------------------------------------------------------------------------
revoke execute on function public.mes_suivis_externes() from public, anon;
grant execute on function public.mes_suivis_externes() to authenticated;


-- 4. Contrôle ------------------------------------------------------------------------
-- fonction : 1 ; ouverte_aux_visiteurs : false ; tables_fermees : true (aucune règle de
-- lecture sur les tables du suivi externe)
select (select count(*) from pg_proc where proname = 'mes_suivis_externes'
          and pronamespace = 'public'::regnamespace) as fonction,
       has_function_privilege('anon', 'public.mes_suivis_externes()', 'execute') as ouverte_aux_visiteurs,
       not exists (select 1 from pg_policies where schemaname = 'public'
                    and tablename in ('suivis_externes', 'suivis_externes_evenements', 'suivis_externes_journal',
                                      'fournisseurs_suivi')) as tables_fermees;
