-- =============================================================================
-- Goship Express — les index des clés étrangères (lot confort du contrôle qualité, 16/11/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce fichier
-- n'AJOUTE que six index. Il ne change aucune table, aucune donnée, aucune règle,
-- aucune fonction, et se relance autant de fois qu'on veut.
--
-- Ordre d'installation : le dernier de la chaîne (outils/migrations.txt), après
-- supabase-prealertes-equipe.sql.
--
-- Pourquoi : les avis de Supabase (Advisors > Performance, « Unindexed foreign keys »)
-- signalent six clés étrangères sans index. Effacer ou modifier la ligne qu'elles
-- désignent (une facture, un colis, un fournisseur, un suivi) oblige la base à parcourir
-- toute la table qui y renvoie. Sans effet au volume d'aujourd'hui ; utile quand le
-- journal des appels du suivi externe et les factures grandiront.
--
-- Ce que ce fichier ne fait pas :
--    - il ne retire aucun index, même ceux que Supabase dit « jamais utilisés » : la base
--      est jeune, la plupart serviront (recherche par téléphone, filtres, relectures) ;
--    - il ne déplace pas l'extension pg_net hors du schéma public (avis « Extension in
--      public ») : pg_net ne se déplace pas, il faudrait la supprimer et la recréer, ce qui
--      couperait les e-mails, les notifications et le suivi des transporteurs ;
--    - il ne fusionne pas les deux règles de lecture des notifications (avis « Multiple
--      permissive policies ») : elles ne sont pas redondantes, l'une sert le client (ses
--      notifications de l'application), l'autre l'équipe.
--
-- Contenu :
--    1. garde : la chaîne est-elle à jour ?
--    2. les six index
--    3. contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regprocedure('public.modifier_prealerte(uuid, jsonb, text)') is null then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt), jusqu''à supabase-prealertes-equipe.sql, puis ce fichier.';
  end if;
end;
$garde$;


-- 2. Les six index ----------------------------------------------------------------
-- Une facture regroupée désigne celle qui la remplace (regroupement, sortie de colis)
create index if not exists factures_remplacee_par_idx on public.factures (remplacee_par);
-- Une pré-alerte reçue désigne son colis (rapprocher_prealerte)
create index if not exists prealertes_colis_idx on public.prealertes (colis_id);
-- Le fournisseur de chaque suivi externe, de ses événements et de son journal d'appels
create index if not exists suivis_externes_fournisseur_idx on public.suivis_externes (fournisseur);
create index if not exists suivis_externes_evenements_fournisseur_idx on public.suivis_externes_evenements (fournisseur);
create index if not exists suivis_externes_journal_fournisseur_idx on public.suivis_externes_journal (fournisseur);
-- Le journal des appels faits pour un seul numéro (fiche d'un suivi, supervision)
create index if not exists suivis_externes_journal_suivi_idx on public.suivis_externes_journal (suivi_id);


-- 3. Contrôle ------------------------------------------------------------------------
-- index : 6 ; cles_sans_index : 0 (les clés étrangères du schéma public sans index qui
-- commence par leurs colonnes)
select (select count(*) from pg_indexes where schemaname = 'public' and indexname in (
          'factures_remplacee_par_idx', 'prealertes_colis_idx', 'suivis_externes_fournisseur_idx',
          'suivis_externes_evenements_fournisseur_idx', 'suivis_externes_journal_fournisseur_idx',
          'suivis_externes_journal_suivi_idx')) as index,
       (select count(*) from pg_constraint c
         where c.contype = 'f' and c.connamespace = 'public'::regnamespace
           and not exists (select 1 from pg_index i
                            where i.indrelid = c.conrelid
                              and (i.indkey::int2[])[0:cardinality(c.conkey) - 1] = c.conkey)) as cles_sans_index;
