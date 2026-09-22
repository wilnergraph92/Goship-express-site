-- =============================================================================
-- Goship Express — facturation automatique des colis (22/09/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier > Run. Sans risque : aucune donnée n'est supprimée, aucune colonne
-- existante n'est modifiée, et le script peut être relancé autant de fois
-- qu'on veut.
--
-- Ce que ce fichier ajoute :
--   1. le prix et le tarif appliqué sur chaque colis ;
--   2. les frais de service et le montant déjà payé sur chaque facture ;
--   3. la quantité et le poids sur chaque ligne de facture ;
--   4. la mise à jour de « mes_factures » pour que le client voie sa balance.
--
-- Pourquoi stocker le prix plutôt que le recalculer : une facture déjà remise
-- au client ne doit jamais changer de montant parce qu'on a modifié le tarif
-- six mois plus tard. Le tarif appliqué reste donc écrit sur le colis.
-- =============================================================================


-- 1. Le prix du colis ---------------------------------------------------------
alter table public.colis add column if not exists prix_usd      numeric(10, 2);
alter table public.colis add column if not exists tarif_lb_usd  numeric(10, 2);

comment on column public.colis.prix_usd     is 'Prix du transport : poids_lb x tarif_lb_usd';
comment on column public.colis.tarif_lb_usd is 'Tarif appliqué à ce colis, en dollars par livre (5 par défaut)';

-- Colis déjà enregistrés : on calcule leur prix au tarif de 5 $/lb, sans
-- toucher à ceux qui en auraient déjà un.
update public.colis
   set tarif_lb_usd = coalesce(tarif_lb_usd, 5),
       prix_usd     = coalesce(prix_usd, round(coalesce(poids_lb, 0) * 5, 2))
 where prix_usd is null or tarif_lb_usd is null;


-- 2. Les frais de service et les paiements sur la facture ---------------------
-- Par défaut zéro, et non dix : les factures déjà émises gardent ainsi leur
-- total au centime près, et relancer ce script ne peut jamais effacer les
-- frais d'une facture récente. C'est le tableau de bord qui inscrit les 10 $
-- sur chaque facture qu'il crée.
alter table public.factures add column if not exists frais_service_usd numeric(10, 2) not null default 0;
alter table public.factures add column if not exists montant_paye_usd  numeric(10, 2) not null default 0
  check (montant_paye_usd >= 0);

comment on column public.factures.frais_service_usd is 'Frais de service fixes, une seule fois par facture';
comment on column public.factures.montant_paye_usd  is 'Total déjà encaissé ; la balance est montant_usd - montant_paye_usd';

-- Une facture déjà marquée payée est considérée réglée en entier : sans cela
-- elle afficherait une balance égale à son total.
update public.factures
   set montant_paye_usd = montant_usd
 where statut = 'payee' and montant_paye_usd = 0;

-- 3. Le détail de chaque ligne ------------------------------------------------
alter table public.facture_lignes add column if not exists quantite integer      not null default 1 check (quantite > 0);
alter table public.facture_lignes add column if not exists poids_lb numeric(8, 2) check (poids_lb is null or poids_lb >= 0);

comment on column public.facture_lignes.quantite is 'Nombre de colis sur la ligne (1 en pratique)';
comment on column public.facture_lignes.poids_lb is 'Poids facturé, recopié du colis au moment de la facture';


-- 4. Ce que le client voit dans « Mon compte » --------------------------------
-- Même fonction qu'avant, enrichie des nouveaux champs. Toujours sans
-- « security definer » : les règles de sécurité des tables s'appliquent, et le
-- filtre sur auth.uid() dit la même chose une seconde fois.
create or replace function public.mes_factures()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(f order by f.cree_le desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
             'id',                fa.id,
             'numero',            fa.numero,
             'montant_usd',       fa.montant_usd,
             'frais_service_usd', fa.frais_service_usd,
             'montant_paye_usd',  fa.montant_paye_usd,
             'statut',            fa.statut,
             'note',              fa.note,
             'lien_paiement',     fa.lien_paiement,
             'moyen',             fa.moyen,
             'echeance_le',       fa.echeance_le,
             'cree_le',           fa.cree_le,
             'payee_le',          fa.payee_le,
             'lignes',            coalesce((
               select jsonb_agg(jsonb_build_object(
                        'libelle',     l.libelle,
                        'montant_usd', l.montant_usd,
                        'quantite',    l.quantite,
                        'poids_lb',    l.poids_lb,
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


-- Contrôle : les colonnes sont-elles toutes en place ?
select (select count(*) from information_schema.columns
        where table_schema = 'public' and table_name = 'colis'
          and column_name in ('prix_usd', 'tarif_lb_usd'))                     as colonnes_colis_sur_2,
       (select count(*) from information_schema.columns
        where table_schema = 'public' and table_name = 'factures'
          and column_name in ('frais_service_usd', 'montant_paye_usd'))        as colonnes_factures_sur_2,
       (select count(*) from information_schema.columns
        where table_schema = 'public' and table_name = 'facture_lignes'
          and column_name in ('quantite', 'poids_lb'))                         as colonnes_lignes_sur_2,
       (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'mes_factures')             as fonction_mes_factures;
