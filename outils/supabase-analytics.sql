-- =============================================================================
-- Goship Express — Analytics (Phase 8, 26/09/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce
-- fichier n'ajoute que des fonctions de LECTURE et deux index. Il ne crée
-- aucune table, ne touche à aucune donnée, ne change aucune règle, et peut
-- être relancé autant de fois qu'on veut.
--
-- Ordre d'installation : supabase.sql, supabase-facturation.sql,
-- supabase-services.sql, supabase-evenements.sql, supabase-scanner.sql,
-- supabase-finances.sql, supabase-tableau-de-bord.sql, puis ce fichier.
-- Après une mise à jour de l'un d'eux, relancez aussi celui-ci.
--
-- Le tableau de bord (Phase 7) dit ce qui se passe maintenant ; Analytics dit
-- ce qui s'est passé, comment cela évolue, et compare une période à la
-- précédente. Mêmes définitions que le tableau de bord pour les mêmes
-- chiffres (reçus, livrés, facturé, encaissé…), mêmes jours de Santo Domingo.
--
-- Sources : colis (le colis, sa réception à Miami — recu_le —, son prix et
-- son tarif arrêtés à l'enregistrement), colis_historique (les événements du
-- moteur de la Phase 3 : statut avant et après, auteur, lieu, source,
-- corrections), clients, factures, facture_lignes et paiements (Phase 5).
-- Rien n'est recalculé : un montant est celui de la facture, un prix celui du
-- colis, un tarif celui de la ligne — un changement de tarif ne modifie aucun
-- chiffre passé.
--
-- Ce que la base ne connaît pas n'a pas de chiffre : dépenses, dettes et
-- résultat (non suivis) ; scans refusés ou illisibles (non enregistrés) ;
-- origine des colis (un seul entrepôt, Miami, aucune colonne) ; cause
-- structurée d'une « action requise » (la note est un texte libre).
--
-- Permission : reports.view (administrateur, gérant), celle des chiffres de
-- la facturation depuis la Phase 6. Aucune permission nouvelle. Un employé,
-- un client ou un visiteur est refusé.
--
-- Contenu :
--    1. index
--    2. périodes et comparaison
--    3. mesures d'une période (les définitions)
--    4. synthèse et séries
--    5. opérations : transitions, délais, colis sans mouvement, action requise
--    6. clients
--    7. finances et créances
--    8. routes et destinations
--    9. scanner
--   10. qualité des données
--   11. droits et contrôle
-- =============================================================================


-- 1. Index -----------------------------------------------------------------------
-- Les annulations (paiements, factures) datées : pour reconstituer le montant
-- dû à n'importe quelle date passée sans parcourir toutes les lignes.
create index if not exists paiements_annulation_idx on public.paiements (annule_le) where annule_le is not null;
create index if not exists factures_annulation_idx on public.factures (annulee_le) where statut = 'annulee';


-- 2. Périodes et comparaison -----------------------------------------------------
-- Une période nommée → ses jours (Santo Domingo, inclus) et ses instants (fin
-- exclue), et la période précédente à laquelle la comparer :
--   aujourdhui       → hier
--   7j, 30j, 3m, 6m, 12m, personnalise
--                    → autant de jours, juste avant
--   mois (du 1er à aujourd'hui) → le mois précédent, du 1er au même jour
--   mois_precedent   → le mois d'avant
--   annee (du 1er janvier à aujourd'hui) → l'année précédente, même dates
-- Les codes communs au tableau de bord donnent exactement ses jours
-- (bornes_periode) : mêmes chiffres pour la même période.
create or replace function public.bornes_analytics(p_periode text, p_debut date default null, p_fin date default null)
returns table (code text, jour_debut date, jour_fin date, debut timestamptz, fin timestamptz,
               prec_jour_debut date, prec_jour_fin date, prec_debut timestamptz, prec_fin timestamptz)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_code text := lower(trim(coalesce(p_periode, '')));
  v_jour date := public.aujourdhui();
  d1 date;
  d2 date;
  p1 date;
  p2 date;
begin
  if v_code = '' then
    v_code := '30j';
  end if;
  case v_code
    when 'aujourdhui' then d1 := v_jour; d2 := v_jour;
    when '7j' then d1 := v_jour - 6; d2 := v_jour;
    when '30j' then d1 := v_jour - 29; d2 := v_jour;
    when 'mois' then d1 := date_trunc('month', v_jour)::date; d2 := v_jour;
    when 'mois_precedent' then
      d1 := (date_trunc('month', v_jour) - interval '1 month')::date;
      d2 := (date_trunc('month', v_jour) - interval '1 day')::date;
    when '3m' then d1 := (v_jour - interval '3 months')::date + 1; d2 := v_jour;
    when '6m' then d1 := (v_jour - interval '6 months')::date + 1; d2 := v_jour;
    when '12m' then d1 := (v_jour - interval '12 months')::date + 1; d2 := v_jour;
    when 'annee' then d1 := date_trunc('year', v_jour)::date; d2 := v_jour;
    when 'personnalise' then
      if p_debut is null or p_fin is null then
        perform public.erreur_metier('INVALID_PERIOD', 'Choisissez une date de début et une date de fin.');
      end if;
      if p_fin < p_debut then
        perform public.erreur_metier('INVALID_PERIOD', 'La date de fin est avant la date de début.');
      end if;
      if p_fin - p_debut > 1095 then
        perform public.erreur_metier('INVALID_PERIOD', 'Une période de trois ans au plus.');
      end if;
      d1 := p_debut; d2 := p_fin;
    else
      perform public.erreur_metier('INVALID_PERIOD', 'Période inconnue : ' || left(v_code, 30) || '.');
  end case;
  case v_code
    when 'mois' then
      p1 := (d1 - interval '1 month')::date;
      p2 := least((d2 - interval '1 month')::date, d1 - 1);
    when 'mois_precedent' then
      p1 := (d1 - interval '1 month')::date;
      p2 := d1 - 1;
    when 'annee' then
      p1 := (d1 - interval '1 year')::date;
      p2 := (d2 - interval '1 year')::date;
    else
      p1 := d1 - (d2 - d1 + 1);
      p2 := d1 - 1;
  end case;
  return query select v_code, d1, d2,
                      d1::timestamp at time zone 'America/Santo_Domingo',
                      (d2 + 1)::timestamp at time zone 'America/Santo_Domingo',
                      p1, p2,
                      p1::timestamp at time zone 'America/Santo_Domingo',
                      (p2 + 1)::timestamp at time zone 'America/Santo_Domingo';
end;
$$;

-- Deux valeurs → la comparaison affichée. Une valeur précédente nulle n'a pas
-- de pourcentage (variation_pct : null) : ni « Infinity », ni « NaN ».
-- Tendance : hausse, baisse ou stable (égalité exacte) ; aucune explication.
create or replace function public.comparer_valeurs(p_actuel numeric, p_precedent numeric)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'actuel', a, 'precedent', b, 'ecart', a - b,
    'variation_pct', case when b = 0 then null else round((a - b) / abs(b) * 100, 1) end,
    'tendance', case when a > b then 'hausse' when a < b then 'baisse' else 'stable' end)
  from (select coalesce(p_actuel, 0) as a, coalesce(p_precedent, 0) as b) x
$$;

-- Le jour de Santo Domingo d'un instant
create or replace function public.jour_sd(p_instant timestamptz)
returns date
language sql
immutable
set search_path = ''
as $$
  select (p_instant at time zone 'America/Santo_Domingo')::date
$$;

-- Les événements de statut qui comptent : venus d'un autre statut, et
-- qu'aucune correction n'a annulés (même règle que le tableau de bord).
create or replace function public.evenements_de_statut(p_debut timestamptz, p_fin timestamptz)
returns table (id bigint, colis_id uuid, de text, vers text, type_evenement text, auteur_id uuid, lieu text,
               note text, cree_le timestamptz)
language sql
stable
set search_path = ''
as $$
  select h.id, h.colis_id, h.statut_precedent, h.statut, h.type_evenement, h.auteur_id, h.lieu, h.note, h.cree_le
  from public.colis_historique h
  where h.cree_le >= p_debut and h.cree_le < p_fin
    and h.statut_precedent is distinct from h.statut
    and not exists (select 1 from public.colis_historique x where x.corrige_id = h.id)
$$;


-- 3. Les mesures d'une période : LES définitions ------------------------------------
--   recus           colis dont la réception à Miami (recu_le) tombe dans la période
--   expedies        colis passés à « Embarqué » (COLIS_EXPEDIE) pendant la période
--   disponibles     colis passés à « Disponible » pendant la période
--   livres          colis passés à « Livré » pendant la période
--   actions_requises colis passés à « Action requise » pendant la période
--                   (chacun une fois, sans les étapes annulées par une correction)
--   facture         total des factures émises pendant la période, hors annulées
--   encaisse        paiements valides reçus pendant la période
--   reste           ce qui reste dû aujourd'hui sur les factures de la période
--   nouveaux_clients comptes clients créés pendant la période
--   scans           opérations enregistrées au poste de scan pendant la période
create or replace function public.analytics_mesures(p_debut timestamptz, p_fin timestamptz)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with ev as (
    select e.vers, count(distinct e.colis_id) as n
    from public.evenements_de_statut(p_debut, p_fin) e
    where e.vers in ('embarque', 'disponible', 'livre', 'incident')
    group by e.vers
  ), co as (
    select count(*) as n, coalesce(sum(poids_lb), 0) as poids, count(poids_lb) as pesees,
           coalesce(sum(prix_usd), 0) as prix, count(prix_usd) as prixes
    from public.colis where recu_le >= p_debut and recu_le < p_fin
  ), pa as (
    select p.facture_id, sum(p.montant_usd) as paye
    from public.paiements p where p.annule_le is null group by p.facture_id
  ), fa as (
    select count(*) as n, coalesce(sum(f.montant_usd), 0) as montant,
           coalesce(sum(case when f.statut = 'annulee' then 0 else greatest(f.montant_usd - coalesce(pa.paye, 0), 0) end), 0) as reste
    from public.factures f left join pa on pa.facture_id = f.id
    where f.statut <> 'annulee' and f.cree_le >= p_debut and f.cree_le < p_fin
  ), en as (
    select count(*) as n, coalesce(sum(montant_usd), 0) as montant
    from public.paiements where annule_le is null and paye_le >= p_debut and paye_le < p_fin
  )
  select jsonb_build_object(
    'recus', co.n,
    'poids', co.poids,
    'poids_moyen', case when co.pesees > 0 then round(co.poids / co.pesees, 2) end,
    'prix_moyen', case when co.prixes > 0 then round(co.prix / co.prixes, 2) end,
    'expedies', coalesce((select n from ev where vers = 'embarque'), 0),
    'disponibles', coalesce((select n from ev where vers = 'disponible'), 0),
    'livres', coalesce((select n from ev where vers = 'livre'), 0),
    'actions_requises', coalesce((select n from ev where vers = 'incident'), 0),
    'nouveaux_clients', (select count(*) from public.clients
                         where role = 'client' and cree_le >= p_debut and cree_le < p_fin),
    'factures_emises', fa.n,
    'facture', fa.montant,
    'reste', fa.reste,
    'revenu_moyen_facture', case when fa.n > 0 then round(fa.montant / fa.n, 2) end,
    'paiements', en.n,
    'encaisse', en.montant,
    'scans', (select count(*) from public.colis_historique h
              where (h.metadonnees ->> 'source') = 'scanner' and h.cree_le >= p_debut and h.cree_le < p_fin))
  from co, fa, en
$$;

-- Ce qui restait dû à un instant donné : factures émises avant, moins celles
-- annulées avant, moins les paiements reçus avant, plus ceux annulés avant. Une
-- facture qui a reçu de l'argent ne s'annule ni ne se regroupe (Phase 5) : ce
-- total vaut donc, à chaque date, la somme des soldes de ce jour-là.
-- Maintenant, il vaut exactement « à encaisser » du tableau de bord.
create or replace function public.creances_au(p_instant timestamptz)
returns numeric
language sql
stable
set search_path = ''
as $$
  select coalesce((select sum(montant_usd) from public.factures where cree_le < p_instant), 0)
       - coalesce((select sum(montant_usd) from public.factures
                   where statut = 'annulee' and coalesce(annulee_le, cree_le) < p_instant), 0)
       - coalesce((select sum(montant_usd) from public.paiements where paye_le < p_instant), 0)
       + coalesce((select sum(montant_usd) from public.paiements
                   where annule_le is not null and annule_le < p_instant and paye_le < p_instant), 0)
$$;


-- 4. Synthèse et séries ---------------------------------------------------------------
create or replace function public.analytics_synthese(p_periode text default '30j', p_debut date default null,
                                                     p_fin date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  p record;
  a jsonb;
  b jsonb;
  k text;
  cmp jsonb := '{}'::jsonb;
begin
  perform public.exiger_permission('reports.view');
  select * into p from public.bornes_analytics(p_periode, p_debut, p_fin);
  a := public.analytics_mesures(p.debut, p.fin);
  b := public.analytics_mesures(p.prec_debut, p.prec_fin);
  foreach k in array array['recus', 'poids', 'expedies', 'disponibles', 'livres', 'actions_requises',
                           'nouveaux_clients', 'factures_emises', 'facture', 'reste', 'paiements', 'encaisse', 'scans'] loop
    cmp := cmp || jsonb_build_object(k, public.comparer_valeurs((a ->> k)::numeric, (b ->> k)::numeric));
  end loop;
  return jsonb_build_object(
    'periode', jsonb_build_object('code', p.code, 'debut', p.jour_debut, 'fin', p.jour_fin,
                                  'jours', p.jour_fin - p.jour_debut + 1,
                                  'precedente', jsonb_build_object('debut', p.prec_jour_debut, 'fin', p.prec_jour_fin),
                                  'fuseau', 'America/Santo_Domingo'),
    'genere_le', now(),
    'mesures', cmp,
    'moyennes', jsonb_build_object('poids_moyen', a -> 'poids_moyen', 'prix_moyen', a -> 'prix_moyen',
                                   'revenu_moyen_facture', a -> 'revenu_moyen_facture'),
    -- Ce qui se compare d'une fin de période à l'autre
    'clients_total', public.comparer_valeurs(
                       (select count(*) from public.clients where role = 'client' and cree_le < p.fin),
                       (select count(*) from public.clients where role = 'client' and cree_le < p.prec_fin)),
    'creances_fin', public.comparer_valeurs(public.creances_au(least(p.fin, now())), public.creances_au(p.prec_fin)),
    -- Le stock, maintenant (les mêmes chiffres que le tableau de bord)
    'maintenant', (select jsonb_build_object(
                     'total', count(*), 'actifs', count(*) filter (where statut <> 'livre'),
                     'statuts', jsonb_build_object(
                       'recu', count(*) filter (where statut = 'recu'),
                       'emballe', count(*) filter (where statut = 'emballe'),
                       'embarque', count(*) filter (where statut = 'embarque'),
                       'distribution', count(*) filter (where statut = 'distribution'),
                       'succursale', count(*) filter (where statut = 'succursale'),
                       'disponible', count(*) filter (where statut = 'disponible'),
                       'livre', count(*) filter (where statut = 'livre'),
                       'incident', count(*) filter (where statut = 'incident')))
                   from public.colis));
end;
$$;

-- La même période découpée par jour, semaine (du lundi) ou mois. Chaque case
-- porte ses propres jours (la première et la dernière peuvent être partielles).
-- Pour chaque case : colis reçus et leur poids, expédiés, livrés, factures
-- émises et leur montant, encaissé, opérations de scan, et le montant dû à la
-- fin de la case. Un colis livré compte le jour de sa (première) livraison de
-- la période, comme dans le tableau de bord : la somme des cases vaut le total.
create or replace function public.analytics_serie(p_periode text default '30j', p_debut date default null,
                                                  p_fin date default null, p_granularite text default 'jour')
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  p record;
  v_g text := lower(coalesce(nullif(trim(p_granularite), ''), 'jour'));
  r jsonb;
begin
  perform public.exiger_permission('reports.view');
  if v_g not in ('jour', 'semaine', 'mois') then
    perform public.erreur_metier('INVALID_INPUT', 'Découpage inconnu : ' || left(v_g, 20) || '.');
  end if;
  select * into p from public.bornes_analytics(p_periode, p_debut, p_fin);
  with jours as (
    select j::date as jour,
           case v_g when 'jour' then j::date
                    when 'semaine' then date_trunc('week', j)::date
                    else date_trunc('month', j)::date end as cle
    from generate_series(p.jour_debut, p.jour_fin, interval '1 day') j
  ), cases as (
    select cle, min(jour) as debut, max(jour) as fin from jours group by cle
  ), recus as (
    select j.cle, count(*) as n, coalesce(sum(c.poids_lb), 0) as poids
    from public.colis c join jours j on j.jour = public.jour_sd(c.recu_le)
    where c.recu_le >= p.debut and c.recu_le < p.fin group by j.cle
  ), etapes as (
    -- Un colis compte le jour de sa première arrivée de la période à l'étape
    select j.cle, x.vers, count(*) as n
    from (select e.vers, e.colis_id, min(public.jour_sd(e.cree_le)) as jour
          from public.evenements_de_statut(p.debut, p.fin) e
          where e.vers in ('embarque', 'livre') group by e.vers, e.colis_id) x
    join jours j on j.jour = x.jour group by j.cle, x.vers
  ), factures as (
    select j.cle, count(*) as n, sum(f.montant_usd) as montant
    from public.factures f join jours j on j.jour = public.jour_sd(f.cree_le)
    where f.statut <> 'annulee' and f.cree_le >= p.debut and f.cree_le < p.fin group by j.cle
  ), paiements as (
    select j.cle, sum(x.montant_usd) as montant
    from public.paiements x join jours j on j.jour = public.jour_sd(x.paye_le)
    where x.annule_le is null and x.paye_le >= p.debut and x.paye_le < p.fin group by j.cle
  ), scans as (
    select j.cle, count(*) as n
    from public.colis_historique h join jours j on j.jour = public.jour_sd(h.cree_le)
    where (h.metadonnees ->> 'source') = 'scanner' and h.cree_le >= p.debut and h.cree_le < p.fin group by j.cle
  ), deltas as (
    select public.jour_sd(cree_le) as jour, montant_usd as d from public.factures where cree_le < p.fin
    union all
    select public.jour_sd(coalesce(annulee_le, cree_le)), -montant_usd from public.factures
     where statut = 'annulee' and coalesce(annulee_le, cree_le) < p.fin
    union all
    select public.jour_sd(paye_le), -montant_usd from public.paiements where paye_le < p.fin
    union all
    select public.jour_sd(annule_le), montant_usd from public.paiements
     where annule_le is not null and annule_le < p.fin and paye_le < p.fin
  ), cumul as materialized (
    select jour, sum(sum(d)) over (order by jour) as du from deltas group by jour
  ), lignes as (
    select c.cle, c.debut, c.fin,
           coalesce(r.n, 0) as recus, coalesce(r.poids, 0) as poids,
           coalesce(ex.n, 0) as expedies, coalesce(lv.n, 0) as livres,
           coalesce(f.n, 0) as factures, coalesce(f.montant, 0) as facture,
           coalesce(pa.montant, 0) as encaisse, coalesce(sc.n, 0) as scans,
           coalesce((select du from cumul u where u.jour <= c.fin order by u.jour desc limit 1), 0) as du
    from cases c
    left join recus r on r.cle = c.cle
    left join etapes ex on ex.cle = c.cle and ex.vers = 'embarque'
    left join etapes lv on lv.cle = c.cle and lv.vers = 'livre'
    left join factures f on f.cle = c.cle
    left join paiements pa on pa.cle = c.cle
    left join scans sc on sc.cle = c.cle
  )
  select jsonb_build_object(
    'periode', jsonb_build_object('code', p.code, 'debut', p.jour_debut, 'fin', p.jour_fin),
    'granularite', v_g,
    'cases', coalesce(jsonb_agg(jsonb_build_object(
               'jour', l.cle, 'debut', l.debut, 'fin', l.fin, 'recus', l.recus, 'poids', l.poids,
               'expedies', l.expedies, 'livres', l.livres, 'factures', l.factures, 'facture', l.facture,
               'encaisse', l.encaisse, 'scans', l.scans, 'creances_fin', l.du) order by l.cle), '[]'::jsonb))
    into r
  from lignes l;
  return r;
end;
$$;


-- 5. Opérations ------------------------------------------------------------------------
-- Durées en heures, tirées des événements (jamais de la date de modification
-- du colis). Le départ d'un colis est sa réception à Miami (recu_le : la date
-- et l'heure saisies à l'arrivée) ; chaque étape suivante est la première
-- arrivée, non annulée par une correction, au statut concerné.
--   reception_expedition   Reçu → Embarqué        (entrepôt de Miami)
--   expedition_disponible  Embarqué → Disponible  (acheminement, distribution)
--   disponible_livraison   Disponible → Livré     (retrait par le client)
--   reception_livraison    Reçu → Livré           (total)
-- Une étape compte dans la période où elle s'achève. Les valeurs extrêmes
-- restent dans les chiffres (moyenne, maximum) et sont comptées à part
-- (au-delà de Q3 + 1,5 × l'écart interquartile) ; une durée négative (date de
-- réception saisie après l'événement) est comptée à part, hors statistiques.
create or replace function public.statistiques_durees(p_durees double precision[])
returns jsonb
language sql
immutable
set search_path = ''
as $$
  with v as (select unnest(p_durees) as d), ok as (select d from v where d >= 0), q as (
    select count(*) as n, avg(d) as moyenne, min(d) as minimum, max(d) as maximum,
           percentile_cont(0.5) within group (order by d) as mediane,
           percentile_cont(0.25) within group (order by d) as q1,
           percentile_cont(0.75) within group (order by d) as q3,
           percentile_cont(0.9) within group (order by d) as p90
    from ok
  )
  select jsonb_build_object(
    'nombre', q.n,
    'moyenne_h', round(q.moyenne::numeric, 1), 'mediane_h', round(q.mediane::numeric, 1),
    'minimum_h', round(q.minimum::numeric, 1), 'maximum_h', round(q.maximum::numeric, 1),
    'p90_h', round(q.p90::numeric, 1),
    'extremes', (select count(*) from ok where q.n >= 4 and d > q.q3 + 1.5 * (q.q3 - q.q1)),
    'negatives', (select count(*) from v where d < 0))
  from q
$$;

create or replace function public.analytics_operations(p_periode text default '30j', p_debut date default null,
                                                       p_fin date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  p record;
  r jsonb;
begin
  perform public.exiger_permission('reports.view');
  select * into p from public.bornes_analytics(p_periode, p_debut, p_fin);
  with arrivees as materialized (
    select e.colis_id,
           min(e.cree_le) filter (where e.vers = 'embarque') as embarque,
           min(e.cree_le) filter (where e.vers = 'disponible') as disponible,
           min(e.cree_le) filter (where e.vers = 'livre') as livre
    from public.evenements_de_statut('-infinity', 'infinity') e
    where e.vers in ('embarque', 'disponible', 'livre')
    group by e.colis_id
  ), etapes as (
    select x.etape, x.depart, x.arrivee
    from arrivees a join public.colis c on c.id = a.colis_id,
         lateral (values ('reception_expedition', c.recu_le, a.embarque),
                         ('expedition_disponible', a.embarque, a.disponible),
                         ('disponible_livraison', a.disponible, a.livre),
                         ('reception_livraison', c.recu_le, a.livre)) x(etape, depart, arrivee)
    where x.depart is not null and x.arrivee is not null
  ), durees as (
    select etape, array_agg(extract(epoch from arrivee - depart) / 3600.0) as d
    from etapes where arrivee >= p.debut and arrivee < p.fin group by etape
  ), chaine as materialized (
    -- Tous les changements de statut, colis par colis, avec le précédent : le
    -- colis était dans le statut qu'il quitte depuis ce changement-là — ou,
    -- quand le précédent est sa création, depuis sa réception à Miami.
    select e.id, e.colis_id, e.de, e.vers, e.type_evenement, e.cree_le,
           lag(e.cree_le) over w as avant, lag(e.de) over w as de_avant
    from public.evenements_de_statut('-infinity', 'infinity') e
    window w as (partition by e.colis_id order by e.cree_le, e.id)
  ), changements as (
    select ch.de, ch.vers, ch.cree_le, ch.type_evenement,
           case when ch.avant is null or ch.de_avant is null then c.recu_le else ch.avant end as depuis
    from chaine ch join public.colis c on c.id = ch.colis_id
    where ch.cree_le >= p.debut and ch.cree_le < p.fin
      and ch.de is not null and ch.type_evenement is distinct from 'CORRECTION'
  ), actives as (
    select c.id, now() - coalesce((select max(h.cree_le) from public.colis_historique h where h.colis_id = c.id), c.recu_le) as age
    from public.colis c where c.statut <> 'livre'
  ), cohorte as (
    select count(*) as recus, count(*) filter (where statut = 'livre') as livres
    from public.colis where recu_le >= p.debut and recu_le < p.fin
  ), cohorte_prec as (
    select count(*) as recus, count(*) filter (where statut = 'livre') as livres
    from public.colis where recu_le >= p.prec_debut and recu_le < p.prec_fin
  ), incidents as (
    select e.id, e.colis_id, e.cree_le, nullif(trim(e.note), '') as note
    from public.evenements_de_statut(p.debut, p.fin) e where e.vers = 'incident'
  ), sorties as (
    -- Les épisodes « action requise » terminés pendant la période : de l'entrée
    -- dans l'état (le changement précédent) à la sortie
    select extract(epoch from ch.cree_le - ch.avant) / 3600.0 as d
    from chaine ch
    where ch.de = 'incident' and ch.avant is not null and ch.cree_le >= p.debut and ch.cree_le < p.fin
  )
  select jsonb_build_object(
    'periode', jsonb_build_object('code', p.code, 'debut', p.jour_debut, 'fin', p.jour_fin),
    'durees', jsonb_build_object(
      'reception_expedition', public.statistiques_durees(coalesce((select d from durees where etape = 'reception_expedition'), '{}')),
      'expedition_disponible', public.statistiques_durees(coalesce((select d from durees where etape = 'expedition_disponible'), '{}')),
      'disponible_livraison', public.statistiques_durees(coalesce((select d from durees where etape = 'disponible_livraison'), '{}')),
      'reception_livraison', public.statistiques_durees(coalesce((select d from durees where etape = 'reception_livraison'), '{}'))),
    'transitions', coalesce((
      select jsonb_agg(jsonb_build_object('de', de, 'vers', vers, 'nombre', n, 'moyenne_h', round(m::numeric, 1),
                                          'mediane_h', round(med::numeric, 1)) order by n desc, de, vers)
      from (select de, vers, count(*) as n, avg(extract(epoch from cree_le - depuis) / 3600.0) as m,
                   percentile_cont(0.5) within group (order by extract(epoch from cree_le - depuis) / 3600.0) as med
            from changements group by de, vers) t), '[]'::jsonb),
    'anomalies', jsonb_build_object(
      'corrections', (select count(*) from public.colis_historique h
                      where h.type_evenement = 'CORRECTION' and h.cree_le >= p.debut and h.cree_le < p.fin),
      'retours_en_arriere', (select count(*) from changements
                             where array_position(array['recu','emballe','embarque','distribution','succursale','disponible','livre'], vers)
                                 < array_position(array['recu','emballe','embarque','distribution','succursale','disponible','livre'], de))),
    'sans_mouvement', (select jsonb_build_object(
                         'moins_24h', count(*) filter (where age < interval '24 hours'),
                         'de_24_a_48h', count(*) filter (where age >= interval '24 hours' and age < interval '48 hours'),
                         'de_48_a_72h', count(*) filter (where age >= interval '48 hours' and age < interval '72 hours'),
                         'de_72h_a_7j', count(*) filter (where age >= interval '72 hours' and age < interval '7 days'),
                         'plus_de_7j', count(*) filter (where age >= interval '7 days'),
                         'actifs', count(*))
                       from actives),
    'livraison', (select jsonb_build_object(
                    'livres', (public.analytics_mesures(p.debut, p.fin) ->> 'livres')::int,
                    'cohorte_recus', c.recus, 'cohorte_livres', c.livres,
                    'taux_cohorte', case when c.recus > 0 then round(c.livres * 100.0 / c.recus, 1) end,
                    'taux_cohorte_precedente', case when cp.recus > 0 then round(cp.livres * 100.0 / cp.recus, 1) end)
                  from cohorte c, cohorte_prec cp),
    'action_requise', jsonb_build_object(
      'entrees', public.comparer_valeurs((select count(distinct colis_id) from incidents),
                   (select count(distinct e.colis_id) from public.evenements_de_statut(p.prec_debut, p.prec_fin) e where e.vers = 'incident')),
      'en_cours', (select count(*) from public.colis where statut = 'incident'),
      'duree_episodes', public.statistiques_durees(coalesce((select array_agg(d) from sorties), '{}')),
      'clients', (select count(distinct c.client_id) from incidents i join public.colis c on c.id = i.colis_id),
      'par_destination', coalesce((select jsonb_agg(jsonb_build_object('pays', pays, 'nombre', n) order by n desc, pays)
                                   from (select c.pays_destination as pays, count(distinct i.colis_id) as n
                                         from incidents i join public.colis c on c.id = i.colis_id group by 1) x), '[]'::jsonb),
      'notes', coalesce((select jsonb_agg(jsonb_build_object('note', note, 'nombre', n) order by n desc, note)
                         from (select note, count(*) as n from incidents where note is not null
                               group by note order by count(*) desc, note limit 5) x), '[]'::jsonb),
      'cause_structuree', false))
    into r;
  return r;
end;
$$;


-- 6. Clients ----------------------------------------------------------------------------
--   actif        au moins un colis reçu pendant la période
--   inactif      inscrit avant la fin de la période, sans colis reçu pendant
--   segments     parmi les actifs, selon le nombre de colis reçus : 1 colis ;
--                2 à 4 ; 5 et plus. Des seuils fixes, affichés tels quels.
-- La liste : les clients qui ont reçu un colis, une facture ou payé pendant la
-- période, triés par colis, poids, facturé, payé ou solde.
create or replace function public.analytics_clients(p_periode text default '30j', p_debut date default null,
                                                    p_fin date default null, p_tri text default 'colis',
                                                    p_limite integer default 25, p_decalage integer default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  p record;
  v_tri text := lower(coalesce(nullif(trim(p_tri), ''), 'colis'));
  v_limite integer := least(greatest(coalesce(p_limite, 25), 1), 100);
  v_decalage integer := greatest(coalesce(p_decalage, 0), 0);
  r jsonb;
begin
  perform public.exiger_permission('reports.view');
  if v_tri not in ('colis', 'poids', 'facture', 'paye', 'solde') then
    perform public.erreur_metier('INVALID_INPUT', 'Tri inconnu : ' || left(v_tri, 30) || '.');
  end if;
  select * into p from public.bornes_analytics(p_periode, p_debut, p_fin);
  with co as (
    select client_id, count(*) as n, coalesce(sum(poids_lb), 0) as poids, max(recu_le) as dernier
    from public.colis where client_id is not null and recu_le >= p.debut and recu_le < p.fin group by client_id
  ), co_prec as (
    select client_id, count(*) as n from public.colis
    where client_id is not null and recu_le >= p.prec_debut and recu_le < p.prec_fin group by client_id
  ), fa as (
    select client_id, sum(montant_usd) as montant from public.factures
    where statut <> 'annulee' and cree_le >= p.debut and cree_le < p.fin group by client_id
  ), pa as (
    select client_id, sum(montant_usd) as montant, max(paye_le) as dernier from public.paiements
    where annule_le is null and paye_le >= p.debut and paye_le < p.fin group by client_id
  ), paye_fa as (
    select facture_id, sum(montant_usd) as paye from public.paiements where annule_le is null group by facture_id
  ), so as (
    select f.client_id, sum(greatest(f.montant_usd - coalesce(x.paye, 0), 0)) as solde
    from public.factures f left join paye_fa x on x.facture_id = f.id
    where f.statut <> 'annulee' group by f.client_id
  ), liste as (
    select cl.id, cl.code, cl.nom_complet, cl.ville, cl.pays,
           coalesce(co.n, 0) as colis, coalesce(co.poids, 0) as poids, coalesce(fa.montant, 0) as facture,
           coalesce(pa.montant, 0) as paye, coalesce(so.solde, 0) as solde,
           greatest(co.dernier, pa.dernier) as derniere_activite
    from public.clients cl
    left join co on co.client_id = cl.id left join fa on fa.client_id = cl.id
    left join pa on pa.client_id = cl.id left join so on so.client_id = cl.id
    where cl.role = 'client' and (co.n is not null or fa.montant is not null or pa.montant is not null)
  ), rangs as (
    select l.*, row_number() over (order by
             case v_tri when 'colis' then l.colis when 'poids' then l.poids when 'facture' then l.facture
                        when 'paye' then l.paye else l.solde end desc, l.nom_complet, l.id) as rang
    from liste l
  )
  select jsonb_build_object(
    'periode', jsonb_build_object('code', p.code, 'debut', p.jour_debut, 'fin', p.jour_fin),
    -- Inscrits à la fin de la période : créés avant, ou actifs pendant (une date de
    -- réception saisie avant la création du compte ne doit pas rendre « inactifs » négatif)
    'total_fin', (select count(*) from public.clients cl
                  where cl.role = 'client' and (cl.cree_le < p.fin or exists (select 1 from co where co.client_id = cl.id))),
    'nouveaux', public.comparer_valeurs(
                  (select count(*) from public.clients where role = 'client' and cree_le >= p.debut and cree_le < p.fin),
                  (select count(*) from public.clients where role = 'client' and cree_le >= p.prec_debut and cree_le < p.prec_fin)),
    'actifs', public.comparer_valeurs((select count(*) from co), (select count(*) from co_prec)),
    'inactifs', (select count(*) from public.clients cl
                 where cl.role = 'client' and cl.cree_le < p.fin
                   and not exists (select 1 from co where co.client_id = cl.id)),
    'colis_par_client_actif', (select case when count(*) > 0 then round(sum(n)::numeric / count(*), 2) end from co),
    'segments', jsonb_build_array(
      jsonb_build_object('segment', 'petite', 'definition', '1 colis sur la période',
                         'clients', (select count(*) from co where n = 1),
                         'colis', (select coalesce(sum(n), 0) from co where n = 1)),
      jsonb_build_object('segment', 'moyenne', 'definition', '2 à 4 colis sur la période',
                         'clients', (select count(*) from co where n between 2 and 4),
                         'colis', (select coalesce(sum(n), 0) from co where n between 2 and 4)),
      jsonb_build_object('segment', 'forte', 'definition', '5 colis ou plus sur la période',
                         'clients', (select count(*) from co where n >= 5),
                         'colis', (select coalesce(sum(n), 0) from co where n >= 5))),
    'tri', v_tri,
    'total_liste', (select count(*) from liste),
    'lignes', coalesce((select jsonb_agg(jsonb_build_object(
                'id', id, 'code', code, 'nom_complet', nom_complet, 'ville', ville, 'pays', pays,
                'colis', colis, 'poids', poids, 'facture', facture, 'paye', paye, 'solde', solde,
                'derniere_activite', derniere_activite) order by rang)
              from rangs where rang > v_decalage and rang <= v_decalage + v_limite), '[]'::jsonb))
    into r;
  return r;
end;
$$;


-- 7. Finances et créances ----------------------------------------------------------------
--   facturé     factures émises pendant la période, hors annulées (montant
--               arrêté à la création : un changement de tarif ne le touche pas)
--   encaissé    paiements valides reçus pendant la période — l'argent entré,
--               à ne pas confondre avec le facturé
--   reste       ce qui reste dû aujourd'hui sur les factures de la période
--   créances    tout ce qui reste dû, maintenant ; « au » d'une date :
--               reconstitué à partir des factures et des paiements datés
--   âge         jours écoulés depuis l'émission de chaque facture ouverte
--   retard      échéance dépassée et solde > 0 (etat_paiement)
-- Dépenses, dettes et résultat : non suivis par le système.
create or replace function public.analytics_finances(p_periode text default '30j', p_debut date default null,
                                                     p_fin date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  p record;
  a jsonb;
  b jsonb;
  r jsonb;
begin
  perform public.exiger_permission('reports.view');
  select * into p from public.bornes_analytics(p_periode, p_debut, p_fin);
  a := public.analytics_mesures(p.debut, p.fin);
  b := public.analytics_mesures(p.prec_debut, p.prec_fin);
  with pa as (
    select facture_id, sum(montant_usd) as paye from public.paiements where annule_le is null group by facture_id
  ), ouvertes as (
    select f.id, f.cree_le, f.echeance_le, f.montant_usd, coalesce(pa.paye, 0) as paye,
           greatest(f.montant_usd - coalesce(pa.paye, 0), 0) as solde
    from public.factures f left join pa on pa.facture_id = f.id
    where f.statut <> 'annulee' and f.montant_usd - coalesce(pa.paye, 0) > 0
  ), periode as (
    select f.frais_service_usd, f.montant_usd from public.factures f
    where f.statut <> 'annulee' and f.cree_le >= p.debut and f.cree_le < p.fin
  )
  select jsonb_build_object(
    'periode', jsonb_build_object('code', p.code, 'debut', p.jour_debut, 'fin', p.jour_fin),
    'facture', public.comparer_valeurs((a ->> 'facture')::numeric, (b ->> 'facture')::numeric),
    'encaisse', public.comparer_valeurs((a ->> 'encaisse')::numeric, (b ->> 'encaisse')::numeric),
    'reste', public.comparer_valeurs((a ->> 'reste')::numeric, (b ->> 'reste')::numeric),
    'factures_emises', public.comparer_valeurs((a ->> 'factures_emises')::numeric, (b ->> 'factures_emises')::numeric),
    'frais_service', (select coalesce(sum(frais_service_usd), 0) from periode),
    'transport', (select coalesce(sum(montant_usd - frais_service_usd), 0) from periode),
    'par_moyen', coalesce((select jsonb_agg(jsonb_build_object('moyen', moyen, 'nombre', n, 'montant', m) order by m desc, moyen)
                           from (select moyen, count(*) as n, sum(montant_usd) as m from public.paiements
                                 where annule_le is null and paye_le >= p.debut and paye_le < p.fin group by moyen) x), '[]'::jsonb),
    'creances', (select jsonb_build_object(
                   'total', coalesce(sum(solde), 0),
                   'factures', count(*),
                   'impayees', count(*) filter (where paye = 0),
                   'partielles', count(*) filter (where paye > 0),
                   'en_retard', count(*) filter (where echeance_le < public.aujourdhui()),
                   'montant_en_retard', coalesce(sum(solde) filter (where echeance_le < public.aujourdhui()), 0),
                   'non_echues', count(*) filter (where echeance_le >= public.aujourdhui()),
                   'sans_echeance', count(*) filter (where echeance_le is null),
                   'age', jsonb_build_array(
                     jsonb_build_object('tranche', '0_30', 'factures', count(*) filter (where public.aujourdhui() - public.jour_sd(cree_le) <= 30),
                                        'montant', coalesce(sum(solde) filter (where public.aujourdhui() - public.jour_sd(cree_le) <= 30), 0)),
                     jsonb_build_object('tranche', '31_60', 'factures', count(*) filter (where public.aujourdhui() - public.jour_sd(cree_le) between 31 and 60),
                                        'montant', coalesce(sum(solde) filter (where public.aujourdhui() - public.jour_sd(cree_le) between 31 and 60), 0)),
                     jsonb_build_object('tranche', '61_90', 'factures', count(*) filter (where public.aujourdhui() - public.jour_sd(cree_le) between 61 and 90),
                                        'montant', coalesce(sum(solde) filter (where public.aujourdhui() - public.jour_sd(cree_le) between 61 and 90), 0)),
                     jsonb_build_object('tranche', '90_plus', 'factures', count(*) filter (where public.aujourdhui() - public.jour_sd(cree_le) > 90),
                                        'montant', coalesce(sum(solde) filter (where public.aujourdhui() - public.jour_sd(cree_le) > 90), 0))))
                 from ouvertes),
    'creances_fin', public.comparer_valeurs(public.creances_au(least(p.fin, now())), public.creances_au(p.prec_fin)),
    'depenses', jsonb_build_object('suivi', false),
    'dettes', jsonb_build_object('suivi', false),
    'resultat', jsonb_build_object('suivi', false))
    into r;
  return r;
end;
$$;


-- 8. Routes et destinations --------------------------------------------------------------
-- Une route : l'entrepôt de Miami (seule origine : aucun colis n'en a d'autre,
-- la base n'a pas de colonne « origine ») → le pays de destination, par
-- service (aérien, maritime, terrestre). Seules les routes réellement
-- utilisées apparaissent. Pour les colis reçus pendant la période :
--   colis, poids, facturé (leurs lignes sur des factures non annulées : le
--   transport de ces colis, sans les frais de service, qui sont par facture),
--   livrés maintenant et taux (livrés ÷ reçus), délai moyen Reçu → Livré.
-- Les villes : la destination saisie, telle quelle (espaces et casse ignorés).
create or replace function public.analytics_routes(p_periode text default '30j', p_debut date default null,
                                                   p_fin date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  p record;
  r jsonb;
begin
  perform public.exiger_permission('reports.view');
  select * into p from public.bornes_analytics(p_periode, p_debut, p_fin);
  with periode as (
    select c.id, c.pays_destination, c.service, c.poids_lb, c.statut, c.recu_le,
           nullif(lower(trim(c.destination)), '') as ville
    from public.colis c where c.recu_le >= p.debut and c.recu_le < p.fin
  ), livraisons as (
    select e.colis_id, min(e.cree_le) as t
    from public.evenements_de_statut(p.debut, 'infinity') e
    where e.vers = 'livre' and e.colis_id in (select id from periode) group by e.colis_id
  ), lignes as (
    select l.colis_id, sum(l.montant_usd) as montant
    from public.facture_lignes l join public.factures f on f.id = l.facture_id
    where f.statut <> 'annulee' and l.colis_id in (select id from periode) group by l.colis_id
  ), co as (
    select pe.*, li.montant as facture, extract(epoch from lv.t - pe.recu_le) / 3600.0 as delai
    from periode pe left join livraisons lv on lv.colis_id = pe.id left join lignes li on li.colis_id = pe.id
  ), co_prec as (
    select pays_destination, service, nullif(lower(trim(destination)), '') as ville
    from public.colis where recu_le >= p.prec_debut and recu_le < p.prec_fin
  )
  select jsonb_build_object(
    'periode', jsonb_build_object('code', p.code, 'debut', p.jour_debut, 'fin', p.jour_fin),
    'origine', 'Miami (Medley), FL',
    'origines_distinctes', 1,
    'routes', coalesce((select jsonb_agg(jsonb_build_object(
                'pays', x.pays_destination, 'service', x.service, 'colis', x.n, 'poids', x.poids,
                'facture', x.facture, 'livres', x.livres,
                'taux_livre', case when x.n > 0 then round(x.livres * 100.0 / x.n, 1) end,
                'delai_moyen_h', round(x.delai::numeric, 1),
                'colis_precedents', (select count(*) from co_prec cp
                                     where cp.pays_destination = x.pays_destination and cp.service = x.service))
              order by x.n desc, x.pays_destination, x.service)
            from (select pays_destination, service, count(*) as n, coalesce(sum(poids_lb), 0) as poids,
                         coalesce(sum(facture), 0) as facture, count(*) filter (where statut = 'livre') as livres,
                         avg(delai) filter (where delai >= 0) as delai
                  from co group by pays_destination, service) x), '[]'::jsonb),
    'pays', coalesce((select jsonb_agg(jsonb_build_object('pays', x.pays_destination, 'colis', x.n,
                                                          'colis_precedents', x.np) order by x.n desc, x.pays_destination)
                      from (select coalesce(a.pays_destination, b.pays_destination) as pays_destination,
                                   coalesce(a.n, 0) as n, coalesce(b.n, 0) as np
                            from (select pays_destination, count(*) as n from co group by 1) a
                            full join (select pays_destination, count(*) as n from co_prec group by 1) b
                              on b.pays_destination = a.pays_destination) x), '[]'::jsonb),
    'villes', coalesce((select jsonb_agg(jsonb_build_object('ville', x.nom, 'pays', x.pays_destination, 'colis', x.n,
                                                            'colis_precedents', x.np) order by x.n desc, x.nom)
                        from (select v.nom, v.pays_destination, v.n,
                                     (select count(*) from co_prec cp where cp.ville = v.ville
                                        and cp.pays_destination = v.pays_destination) as np
                              from (select ville, pays_destination, count(*) as n,
                                           min(initcap(ville)) as nom
                                    from co where ville is not null group by ville, pays_destination
                                    order by count(*) desc, ville limit 10) v) x), '[]'::jsonb),
    'sans_ville', (select count(*) from co where ville is null))
    into r;
  return r;
end;
$$;


-- 9. Le poste de scan --------------------------------------------------------------------
-- Les opérations enregistrées au scanner (événements de source « scanner »).
-- Les scans refusés ou illisibles, et les consultations, n'écrivent rien : ils
-- ne sont pas comptés (echecs_suivis : false). Par compte : dans l'ordre
-- alphabétique, jamais en classement. Intervalle : entre deux opérations
-- successives d'un même compte, le même jour.
create or replace function public.analytics_scanner(p_periode text default '30j', p_debut date default null,
                                                    p_fin date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  p record;
  r jsonb;
begin
  perform public.exiger_permission('reports.view');
  select * into p from public.bornes_analytics(p_periode, p_debut, p_fin);
  with s as materialized (
    select h.id, h.auteur_id, h.type_evenement, h.cree_le, nullif(trim(h.lieu), '') as lieu
    from public.colis_historique h
    where (h.metadonnees ->> 'source') = 'scanner' and h.cree_le >= p.debut and h.cree_le < p.fin
  ), ecarts as (
    select extract(epoch from cree_le - lag(cree_le) over (partition by auteur_id, public.jour_sd(cree_le)
                                                           order by cree_le, id)) / 60.0 as minutes
    from s
  )
  select jsonb_build_object(
    'periode', jsonb_build_object('code', p.code, 'debut', p.jour_debut, 'fin', p.jour_fin),
    'total', public.comparer_valeurs((select count(*) from s),
               (select count(*) from public.colis_historique h where (h.metadonnees ->> 'source') = 'scanner'
                  and h.cree_le >= p.prec_debut and h.cree_le < p.prec_fin)),
    'colis', (select count(distinct h.colis_id) from public.colis_historique h
              where (h.metadonnees ->> 'source') = 'scanner' and h.cree_le >= p.debut and h.cree_le < p.fin),
    'jours_actifs', (select count(distinct public.jour_sd(cree_le)) from s),
    'echecs_suivis', false,
    'par_operation', coalesce((select jsonb_agg(jsonb_build_object(
                        'type', type_evenement,
                        'libelle', coalesce(public.types_evenement() -> type_evenement ->> 'libelle', type_evenement),
                        'nombre', n) order by n desc, type_evenement)
                      from (select type_evenement, count(*) as n from s group by 1) x), '[]'::jsonb),
    'par_compte', coalesce((select jsonb_agg(jsonb_build_object(
                     'nom', coalesce(nullif(cl.nom_complet, ''), cl.email, 'Compte supprimé'), 'role', cl.role,
                     'operations', x.n, 'jours', x.jours) order by coalesce(nullif(cl.nom_complet, ''), cl.email), x.auteur_id)
                   from (select auteur_id, count(*) as n, count(distinct public.jour_sd(cree_le)) as jours
                         from s group by auteur_id) x
                   left join public.clients cl on cl.id = x.auteur_id), '[]'::jsonb),
    'par_lieu', coalesce((select jsonb_agg(jsonb_build_object('lieu', coalesce(lieu, ''), 'nombre', n) order by n desc, lieu)
                          from (select lieu, count(*) as n from s group by lieu) x), '[]'::jsonb),
    'intervalle_minutes', (select jsonb_build_object(
                             'nombre', count(minutes),
                             'mediane', round((percentile_cont(0.5) within group (order by minutes))::numeric, 1),
                             'moyenne', round(avg(minutes)::numeric, 1))
                           from ecarts where minutes is not null))
    into r;
  return r;
end;
$$;


-- 10. Qualité des données ----------------------------------------------------------------
-- Ce qui manque ou ne concorde pas, sur toute la base (pas de période). Rien
-- n'est corrigé ni caché : chaque chiffre dit combien de lignes sont en cause.
--   historique complet   le colis a un événement de réception (statut « Reçu »)
--   historique cohérent  son statut est celui de son dernier événement non annulé
--   événement attribué   l'événement porte le compte qui l'a fait (les
--                        événements d'avant la Phase 3 n'en ont pas)
--   facture liée         son client existe
--   paiement lié         sa facture existe et appartient au même client
-- S'y ajoute le rapport d'anomalies de facturation de la Phase 5, par type.
create or replace function public.analytics_qualite()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  r jsonb;
begin
  perform public.exiger_permission('reports.view');
  with dernier as (
    select distinct on (h.colis_id) h.colis_id, h.statut
    from public.colis_historique h
    where not exists (select 1 from public.colis_historique x where x.corrige_id = h.id)
    order by h.colis_id, h.cree_le desc, h.id desc
  ), co as (
    select c.id, c.statut, c.client_id, c.poids_lb,
           exists (select 1 from public.colis_historique h where h.colis_id = c.id) as a_evenement,
           exists (select 1 from public.colis_historique h where h.colis_id = c.id and h.statut = 'recu') as a_reception,
           (select d.statut from dernier d where d.colis_id = c.id) as statut_evenement,
           exists (select 1 from public.facture_lignes l join public.factures f on f.id = l.facture_id
                   where l.colis_id = c.id and f.statut <> 'annulee') as facture
    from public.colis c
  ), anomalies as (
    select a ->> 'type' as type, a ->> 'gravite' as gravite
    from jsonb_array_elements(public.rapport_anomalies_facturation()) a
  )
  select jsonb_build_object(
    'genere_le', now(),
    'indicateurs', jsonb_build_array(
      jsonb_build_object('code', 'colis_historique_complet', 'libelle', 'Colis avec un événement de réception',
                         'ok', (select count(*) from co where a_reception), 'total', (select count(*) from co)),
      jsonb_build_object('code', 'colis_historique_coherent', 'libelle', 'Colis dont le statut est celui du dernier événement',
                         'ok', (select count(*) from co where statut_evenement = statut), 'total', (select count(*) from co where a_evenement)),
      jsonb_build_object('code', 'evenements_attribues', 'libelle', 'Événements avec le compte qui les a faits',
                         'ok', (select count(*) from public.colis_historique where auteur_id is not null),
                         'total', (select count(*) from public.colis_historique)),
      jsonb_build_object('code', 'factures_liees', 'libelle', 'Factures liées à un client existant',
                         'ok', (select count(*) from public.factures f join public.clients cl on cl.id = f.client_id),
                         'total', (select count(*) from public.factures)),
      jsonb_build_object('code', 'paiements_lies', 'libelle', 'Paiements liés à une facture du même client',
                         'ok', (select count(*) from public.paiements p join public.factures f on f.id = p.facture_id
                                where f.client_id = p.client_id),
                         'total', (select count(*) from public.paiements))),
    'anomalies', jsonb_build_array(
      jsonb_build_object('code', 'colis_sans_evenement', 'libelle', 'Colis sans aucun événement',
                         'nombre', (select count(*) from co where not a_evenement)),
      jsonb_build_object('code', 'colis_statut_incoherent', 'libelle', 'Colis dont le statut diffère du dernier événement',
                         'nombre', (select count(*) from co where a_evenement and statut_evenement is distinct from statut)),
      jsonb_build_object('code', 'colis_sans_client', 'libelle', 'Colis sans client (compte supprimé)',
                         'nombre', (select count(*) from co where client_id is null)),
      jsonb_build_object('code', 'colis_sans_poids', 'libelle', 'Colis sans poids (prix non calculable)',
                         'nombre', (select count(*) from co where poids_lb is null)),
      jsonb_build_object('code', 'colis_sans_facture', 'libelle', 'Colis d''un client sur aucune facture active',
                         'nombre', (select count(*) from co where client_id is not null and not facture)),
      jsonb_build_object('code', 'evenements_sans_auteur', 'libelle', 'Événements sans compte (antérieurs à la Phase 3)',
                         'nombre', (select count(*) from public.colis_historique where auteur_id is null)),
      jsonb_build_object('code', 'factures_sans_client', 'libelle', 'Factures sans client existant',
                         'nombre', (select count(*) from public.factures f
                                    where not exists (select 1 from public.clients cl where cl.id = f.client_id))),
      jsonb_build_object('code', 'paiements_sans_facture', 'libelle', 'Paiements sans facture, ou d''un autre client',
                         'nombre', (select count(*) from public.paiements p
                                    where not exists (select 1 from public.factures f
                                                      where f.id = p.facture_id and f.client_id = p.client_id)))),
    'facturation', coalesce((select jsonb_agg(jsonb_build_object('type', type, 'gravite', gravite, 'nombre', n)
                                              order by case gravite when 'erreur' then 0 when 'attention' then 1 else 2 end, n desc, type)
                             from (select type, gravite, count(*) as n from anomalies group by type, gravite) x), '[]'::jsonb))
    into r;
  return r;
end;
$$;


-- 11. Droits -------------------------------------------------------------------------------
-- Les outils internes ne s'appellent pas seuls ; les analytics demandent
-- reports.view, vérifiée par chaque fonction.
revoke execute on function public.bornes_analytics(text, date, date) from public, anon, authenticated;
revoke execute on function public.comparer_valeurs(numeric, numeric) from public, anon, authenticated;
revoke execute on function public.jour_sd(timestamptz) from public, anon, authenticated;
revoke execute on function public.evenements_de_statut(timestamptz, timestamptz) from public, anon, authenticated;
revoke execute on function public.analytics_mesures(timestamptz, timestamptz) from public, anon, authenticated;
revoke execute on function public.creances_au(timestamptz) from public, anon, authenticated;
revoke execute on function public.statistiques_durees(double precision[]) from public, anon, authenticated;

revoke execute on function public.analytics_synthese(text, date, date) from public, anon;
revoke execute on function public.analytics_serie(text, date, date, text) from public, anon;
revoke execute on function public.analytics_operations(text, date, date) from public, anon;
revoke execute on function public.analytics_clients(text, date, date, text, integer, integer) from public, anon;
revoke execute on function public.analytics_finances(text, date, date) from public, anon;
revoke execute on function public.analytics_routes(text, date, date) from public, anon;
revoke execute on function public.analytics_scanner(text, date, date) from public, anon;
revoke execute on function public.analytics_qualite() from public, anon;
grant execute on function public.analytics_synthese(text, date, date) to authenticated;
grant execute on function public.analytics_serie(text, date, date, text) to authenticated;
grant execute on function public.analytics_operations(text, date, date) to authenticated;
grant execute on function public.analytics_clients(text, date, date, text, integer, integer) to authenticated;
grant execute on function public.analytics_finances(text, date, date) to authenticated;
grant execute on function public.analytics_routes(text, date, date) to authenticated;
grant execute on function public.analytics_scanner(text, date, date) to authenticated;
grant execute on function public.analytics_qualite() to authenticated;


-- Contrôle ---------------------------------------------------------------------------------
-- analytics_sur_15 : 15 ; ouvertes_aux_visiteurs : 0 ; creances_egales : true
-- (le montant dû reconstitué à cet instant vaut la somme des soldes).
select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('bornes_analytics', 'comparer_valeurs', 'jour_sd', 'evenements_de_statut',
                            'analytics_mesures', 'creances_au', 'statistiques_durees', 'analytics_synthese',
                            'analytics_serie', 'analytics_operations', 'analytics_clients', 'analytics_finances',
                            'analytics_routes', 'analytics_scanner', 'analytics_qualite'))           as analytics_sur_15,
       (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname like 'analytics\_%'
          and has_function_privilege('anon', p.oid, 'execute'))                                    as ouvertes_aux_visiteurs,
       (select public.creances_au(now()) = coalesce(sum(public.solde_usd(f)), 0)
        from public.factures f)                                                                     as creances_egales;
