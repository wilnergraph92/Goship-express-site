-- =============================================================================
-- Goship Express — les factures dans l'espace client, et l'adresse du client
-- sur les étiquettes d'expédition (22/09/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier > Run. Sans risque : aucune donnée n'est supprimée, et le script peut
-- être relancé autant de fois qu'on veut.
--
-- Ce fichier est déjà inclus dans outils/supabase.sql (partie 15) : si vous
-- relancez le fichier complet, vous n'avez pas besoin de celui-ci.
--
-- Trois choses :
--   1. les colis emportent l'adresse complète de leur client, pour l'imprimer
--      sur l'étiquette d'expédition ;
--   2. le client peut lire ses propres factures depuis « Mon compte » ;
--   3. une facture marquée payée s'affiche aussitôt chez le client, sans qu'il
--      ait à recharger la page.
-- =============================================================================


-- 1. L'adresse du client sur l'étiquette --------------------------------------
-- La vue servait au tableau de bord, qui n'affiche que la ville. L'étiquette
-- d'expédition, elle, a besoin de l'adresse et de la région : sans elles, le
-- livreur n'a que le nom d'une ville.
--
-- « security_invoker = true » : la vue n'ouvre aucune porte. Elle montre à
-- chacun ce que les règles de sécurité (RLS) lui montreraient déjà — ses
-- propres colis pour un client, tous pour l'équipe.
drop view if exists public.colis_details;
create view public.colis_details
with (security_invoker = true) as
  select c.*,
         cl.code        as code_client,
         cl.nom_complet as nom_client,
         cl.telephone   as telephone_client,
         cl.email       as email_client,
         cl.adresse     as adresse_client,
         cl.region      as region_client,
         cl.ville       as ville_client,
         cl.pays        as pays_client,
         cl.langue      as langue_client
  from public.colis c
  left join public.clients cl on cl.id = c.client_id;

revoke all on public.colis_details from anon;
grant select on public.colis_details to authenticated, service_role;


-- 2. Les factures du client ---------------------------------------------------
-- Appelée par « Mon compte » (assets/js/api.js, mesFactures).
--
-- Volontairement **sans** security definer : la fonction s'exécute avec les
-- droits de celui qui l'appelle, donc les règles de sécurité des tables
-- s'appliquent malgré tout. Le filtre « client_id = auth.uid() » dit la même
-- chose une seconde fois : même une erreur d'écriture ici ne laisserait
-- personne lire les factures d'un autre.
create or replace function public.mes_factures()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(f order by f.cree_le desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
             'id',            fa.id,
             'numero',        fa.numero,
             'montant_usd',   fa.montant_usd,
             'statut',        fa.statut,
             'note',          fa.note,
             'lien_paiement', fa.lien_paiement,
             'moyen',         fa.moyen,
             'echeance_le',   fa.echeance_le,
             'cree_le',       fa.cree_le,
             'payee_le',      fa.payee_le,
             'lignes',        coalesce((
               select jsonb_agg(jsonb_build_object(
                        'libelle',     l.libelle,
                        'montant_usd', l.montant_usd,
                        'colis',       co.numero) order by l.id)
               from public.facture_lignes l
               left join public.colis co on co.id = l.colis_id
               where l.facture_id = fa.id), '[]'::jsonb)) as f,
           fa.cree_le
    from public.factures fa
    where fa.client_id = (select auth.uid())
  ) f
$$;

revoke execute on function public.mes_factures() from public, anon;
grant execute on function public.mes_factures() to authenticated;


-- 3. Les factures en direct ---------------------------------------------------
-- « Payée » cochée dans le tableau de bord, et la facture change d'état chez le
-- client dans la seconde. Les règles de sécurité s'appliquent aussi à ces
-- messages : chacun ne reçoit que les changements de ses propres factures.
do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'factures') then
    alter publication supabase_realtime add table public.factures;
  end if;
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'facture_lignes') then
    alter publication supabase_realtime add table public.facture_lignes;
  end if;
exception
  when undefined_object then
    raise notice 'Publication supabase_realtime absente : factures sans mise à jour en direct.';
end $$;


-- Contrôle : ce que la vue et la fonction montrent maintenant
select (select count(*) from information_schema.columns
        where table_schema = 'public' and table_name = 'colis_details'
          and column_name in ('adresse_client', 'region_client'))            as colonnes_adresse_sur_2,
       (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'mes_factures')           as fonction_mes_factures,
       (select count(*) from pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public'
          and tablename in ('factures', 'facture_lignes'))                   as factures_en_direct_sur_2;
