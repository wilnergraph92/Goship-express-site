-- =============================================================================
-- Goship Express — le tableau de bord opérationnel (Phase 7, 26/09/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce
-- fichier n'ajoute que des fonctions de LECTURE et des index. Il ne crée
-- aucune table, ne touche à aucune donnée, ne change aucune règle, et peut
-- être relancé autant de fois qu'on veut.
--
-- Ordre d'installation : supabase.sql, supabase-facturation.sql,
-- supabase-services.sql, supabase-evenements.sql, supabase-scanner.sql,
-- supabase-finances.sql, puis ce fichier. Après une mise à jour de l'un
-- d'eux, relancez aussi celui-ci.
--
-- Pourquoi dans la base : les chiffres d'un tableau de bord doivent être
-- justes quel que soit le nombre de colis. Les faire dans la page voulait dire
-- télécharger des centaines de lignes pour les additionner (l'ancien « résumé
-- par client » s'arrêtait à 500 colis et 1 000 factures, et se trompait
-- au-delà). Ici, chaque chiffre est UNE requête, sur les vraies tables, avec
-- les mêmes règles que le reste : le solde est celui de solde_usd, l'état
-- celui de etat_paiement, un statut est l'un des huit, un scan est un
-- événement écrit par le moteur.
--
-- Rien n'est inventé : une donnée que la base ne connaît pas n'a pas de
-- chiffre. Les dépenses, les dettes et le résultat ne sont pas suivis ; les
-- scans échoués (code illisible, colis introuvable) ne sont pas enregistrés —
-- seules les opérations réussies deviennent des événements. Ces cases-là
-- n'existent donc pas, plutôt que d'afficher un zéro trompeur.
--
-- Les permissions sont celles de la Phase 6, sans en ajouter une seule :
--   vue_generale     shipments.view pour entrer ; chaque partie a la sienne :
--                    clients (clients.view), facturation (reports.view),
--                    scanner et activité (shipments.view_history),
--                    paiements récents (payments.view)
--   colis_a_traiter  shipments.view
--   recherche_rapide shipments.view ; clients et factures selon clients.view
--                    et invoices.view ; soldes selon invoices.view
--   clients_soldes   clients.view ; montants selon invoices.view
--   mon_resume       le compte connecté, sur ses propres données
--
-- Les périodes se comptent en jours de Santo Domingo (America/Santo_Domingo),
-- comme les échéances : « aujourd'hui » commence à minuit là-bas, pas à
-- minuit UTC.
--
-- Contenu :
--    1. index de recherche et de comptage
--    2. les périodes
--    3. la vue générale et ses parties
--    4. les colis à traiter : action requise, sans mouvement
--    5. la recherche rapide
--    6. les clients et leurs soldes
--    7. l'espace client : mon résumé
--    8. droits et contrôle
-- =============================================================================


-- 1. Index ------------------------------------------------------------------------
-- Tous sans effet s'ils existent déjà. Aucun ne change une donnée ; ils
-- rendent les recherches et les comptes rapides sur de gros volumes.

-- Un numéro de colis ou de facture tapé en partie (« GSE-10 », « 2026-09 ») :
-- text_pattern_ops permet à LIKE 'début%' d'utiliser l'index.
create index if not exists colis_numero_debut_idx on public.colis (numero text_pattern_ops);
create index if not exists factures_numero_debut_idx on public.factures (numero text_pattern_ops);
-- Un nom de client, mot par mot (« dorvil » trouve « Marie-Ange Dorvil »)
create index if not exists clients_nom_mots_idx on public.clients
  using gin (to_tsvector('simple', coalesce(nom_complet, '')));
-- Un téléphone par ses derniers chiffres (« 4580 » trouve « +509 3712 4580 ») :
-- les chiffres à l'envers, pour que « se termine par » devienne « commence par ».
create index if not exists clients_telephone_fin_idx on public.clients
  (reverse(regexp_replace(coalesce(telephone, ''), '[^0-9]', '', 'g')) text_pattern_ops);
create index if not exists clients_email_debut_idx on public.clients (lower(email) text_pattern_ops);
create index if not exists clients_inscription_idx on public.clients (cree_le) where role = 'client';
-- Les opérations faites au poste de scan (source « scanner »), par date
create index if not exists colis_historique_scanner_idx on public.colis_historique (cree_le)
  where (metadonnees ->> 'source') = 'scanner';
create index if not exists factures_creation_idx on public.factures (cree_le);


-- 2. Les périodes -----------------------------------------------------------------
-- Une période nommée → ses bornes. debut et fin sont des instants (fin
-- exclue), jour_debut et jour_fin des jours de Santo Domingo (inclus).
--   aujourdhui, 7j, 30j (aujourd'hui compris), mois (depuis le 1er),
--   mois_precedent, annee (depuis le 1er janvier), personnalise (p_debut à
--   p_fin inclus, 367 jours au plus).
create or replace function public.bornes_periode(p_periode text, p_debut date default null, p_fin date default null)
returns table (code text, jour_debut date, jour_fin date, debut timestamptz, fin timestamptz)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_code text := lower(trim(coalesce(p_periode, '')));
  v_jour date := public.aujourdhui();
  d1 date;
  d2 date;
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
    when 'annee' then d1 := date_trunc('year', v_jour)::date; d2 := v_jour;
    when 'personnalise' then
      if p_debut is null or p_fin is null then
        perform public.erreur_metier('INVALID_PERIOD', 'Choisissez une date de début et une date de fin.');
      end if;
      if p_fin < p_debut then
        perform public.erreur_metier('INVALID_PERIOD', 'La date de fin est avant la date de début.');
      end if;
      if p_fin - p_debut > 366 then
        perform public.erreur_metier('INVALID_PERIOD', 'Une période de 367 jours au plus.');
      end if;
      d1 := p_debut; d2 := p_fin;
    else
      perform public.erreur_metier('INVALID_PERIOD', 'Période inconnue : ' || left(v_code, 30) || '.');
  end case;
  return query select v_code, d1, d2,
                      d1::timestamp at time zone 'America/Santo_Domingo',
                      (d2 + 1)::timestamp at time zone 'America/Santo_Domingo';
end;
$$;


-- 3. La vue générale --------------------------------------------------------------
-- Chaque partie est une fonction à elle, appelée par vue_generale seulement
-- (elles ne vérifient pas les permissions : vue_generale le fait avant de
-- les appeler, et elles ne sont ouvertes à aucun compte).

-- Les colis : l'état du stock maintenant (les huit statuts, sans filtre de
-- date), et ce qui s'est passé pendant la période (reçus, livrés).
--   livrés : un événement « livré » écrit pendant la période, venu d'un autre
--   statut et qu'aucune correction n'a annulé ; un colis ne compte qu'une fois.
--   sans mouvement : pas encore livré, et aucun événement depuis p_jours jours.
create or replace function public.tableau_colis(p_debut timestamptz, p_fin timestamptz, p_jour_debut date,
                                                p_jour_fin date, p_jours integer)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with stock as (
    select count(*) as total,
           count(*) filter (where statut <> 'livre') as actifs,
           count(*) filter (where statut = 'recu') as recu,
           count(*) filter (where statut = 'emballe') as emballe,
           count(*) filter (where statut = 'embarque') as embarque,
           count(*) filter (where statut = 'distribution') as distribution,
           count(*) filter (where statut = 'succursale') as succursale,
           count(*) filter (where statut = 'disponible') as disponible,
           count(*) filter (where statut = 'livre') as livre,
           count(*) filter (where statut = 'incident') as incident,
           count(*) filter (where recu_le >= p_debut and recu_le < p_fin) as recus_periode,
           coalesce(sum(poids_lb) filter (where recu_le >= p_debut and recu_le < p_fin), 0) as poids_periode
    from public.colis
  ), livraisons as materialized (
    select h.colis_id, min((h.cree_le at time zone 'America/Santo_Domingo')::date) as jour
    from public.colis_historique h
    where h.statut = 'livre' and h.statut_precedent is distinct from 'livre'
      and h.cree_le >= p_debut and h.cree_le < p_fin
      and not exists (select 1 from public.colis_historique x where x.corrige_id = h.id)
    group by h.colis_id
  ), receptions as (
    select (recu_le at time zone 'America/Santo_Domingo')::date as jour, count(*) as n
    from public.colis where recu_le >= p_debut and recu_le < p_fin
    group by 1
  ), immobiles as (
    select count(*) as n
    from public.colis c
    where c.statut <> 'livre'
      and coalesce((select max(h.cree_le) from public.colis_historique h where h.colis_id = c.id), c.recu_le)
          < now() - make_interval(days => p_jours)
  )
  select jsonb_build_object(
    'total', s.total,
    'actifs', s.actifs,
    'statuts', jsonb_build_object('recu', s.recu, 'emballe', s.emballe, 'embarque', s.embarque,
                                  'distribution', s.distribution, 'succursale', s.succursale,
                                  'disponible', s.disponible, 'livre', s.livre, 'incident', s.incident),
    'action_requise', s.incident,
    'sans_mouvement', (select n from immobiles),
    'recus_periode', s.recus_periode,
    'poids_periode', s.poids_periode,
    'livres_periode', (select count(*) from livraisons),
    'par_jour', (select coalesce(jsonb_agg(jsonb_build_object(
                          'jour', j.jour,
                          'recus', coalesce(r.n, 0),
                          'livres', coalesce(l.n, 0)) order by j.jour), '[]'::jsonb)
                 from (select generate_series(p_jour_debut, p_jour_fin, interval '1 day')::date as jour) j
                 left join receptions r on r.jour = j.jour
                 left join (select jour, count(*) as n from livraisons group by jour) l on l.jour = j.jour))
  from stock s
$$;

-- Les clients : inscrits, nouveaux pendant la période, avec des colis en cours
create or replace function public.tableau_clients(p_debut timestamptz, p_fin timestamptz)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'total', (select count(*) from public.clients where role = 'client'),
    'nouveaux_periode', (select count(*) from public.clients
                         where role = 'client' and cree_le >= p_debut and cree_le < p_fin),
    'avec_colis_en_cours', (select count(distinct co.client_id) from public.colis co
                            join public.clients cl on cl.id = co.client_id and cl.role = 'client'
                            where co.statut <> 'livre'))
$$;

-- La facturation. Mêmes règles que solde_usd et etat_paiement, en une seule
-- agrégation des paiements (comme resume_facturation) :
--   facturé    total des factures émises pendant la période, hors annulées
--   payé/solde ce qui a été payé sur CES factures et ce qu'il en reste :
--              facturé = payé + solde, toujours
--   encaissé   l'argent reçu pendant la période, quelle que soit la facture
--   à encaisser, états : toutes les factures, maintenant
create or replace function public.tableau_facturation(p_debut timestamptz, p_fin timestamptz, p_jour_debut date,
                                                      p_jour_fin date)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with pa as (
    select facture_id, sum(montant_usd) as paye
    from public.paiements where annule_le is null group by facture_id
  ), f as (
    select fa.client_id, fa.statut, fa.montant_usd, fa.echeance_le, fa.cree_le,
           coalesce(pa.paye, 0) as paye,
           case when fa.statut = 'annulee' then 0
                else greatest(fa.montant_usd - coalesce(pa.paye, 0), 0) end as solde
    from public.factures fa left join pa on pa.facture_id = fa.id
  ), e as (
    select f.*,
           case when statut = 'annulee' then 'annulee'
                when solde <= 0 then 'payee'
                when echeance_le is not null and echeance_le < public.aujourdhui() then 'en_retard'
                when paye > 0 then 'partielle'
                else 'a_payer' end as etat,
           cree_le >= p_debut and cree_le < p_fin as dans_periode
    from f
  ), encaissements as (
    select (paye_le at time zone 'America/Santo_Domingo')::date as jour, sum(montant_usd) as montant, count(*) as n
    from public.paiements
    where annule_le is null and paye_le >= p_debut and paye_le < p_fin
    group by 1
  ), emissions as (
    select (cree_le at time zone 'America/Santo_Domingo')::date as jour, sum(montant_usd) as montant
    from public.factures
    where statut <> 'annulee' and cree_le >= p_debut and cree_le < p_fin
    group by 1
  )
  select jsonb_build_object(
    'emises_periode',    count(*) filter (where dans_periode and statut <> 'annulee'),
    'facture_periode',   coalesce(sum(montant_usd) filter (where dans_periode and statut <> 'annulee'), 0),
    'paye_sur_periode',  coalesce(sum(paye) filter (where dans_periode and statut <> 'annulee'), 0),
    'solde_sur_periode', coalesce(sum(solde) filter (where dans_periode and statut <> 'annulee'), 0),
    'annulees_periode',  count(*) filter (where dans_periode and statut = 'annulee'),
    'encaisse_periode',  (select coalesce(sum(montant), 0) from encaissements),
    'paiements_periode', (select coalesce(sum(n), 0) from encaissements),
    'a_encaisser',       coalesce(sum(solde), 0),
    'ouvertes',          count(*) filter (where solde > 0),
    'montant_en_retard', coalesce(sum(solde) filter (where etat = 'en_retard'), 0),
    'clients_avec_solde', count(distinct client_id) filter (where solde > 0),
    'etats', jsonb_build_object(
               'a_payer',   count(*) filter (where etat = 'a_payer'),
               'partielle', count(*) filter (where etat = 'partielle'),
               'en_retard', count(*) filter (where etat = 'en_retard'),
               'payee',     count(*) filter (where etat = 'payee'),
               'annulee',   count(*) filter (where etat = 'annulee')),
    'par_jour', (select coalesce(jsonb_agg(jsonb_build_object(
                          'jour', j.jour,
                          'facture', coalesce(m.montant, 0),
                          'encaisse', coalesce(x.montant, 0))
                        order by j.jour), '[]'::jsonb)
                 from (select generate_series(p_jour_debut, p_jour_fin, interval '1 day')::date as jour) j
                 left join emissions m on m.jour = j.jour
                 left join encaissements x on x.jour = j.jour))
  from e
$$;

-- Le poste de scan : les opérations qu'il a écrites (événements de source
-- « scanner »). Une consultation sans opération, un double scan déjà fait ou
-- un code introuvable n'écrivent rien : ils ne comptent pas, et la base ne
-- tient pas de liste des scans échoués (echecs_suivis : false).
create or replace function public.tableau_scanner(p_debut timestamptz, p_fin timestamptz, p_jour_debut date,
                                                  p_jour_fin date)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with s as materialized (
    select h.id, h.auteur_id, h.type_evenement, h.cree_le
    from public.colis_historique h
    where (h.metadonnees ->> 'source') = 'scanner' and h.cree_le >= p_debut and h.cree_le < p_fin
  ), jours as (
    select (cree_le at time zone 'America/Santo_Domingo')::date as jour, count(*) as n from s group by 1
  )
  select jsonb_build_object(
    'aujourdhui', (select count(*) from public.colis_historique h
                   where (h.metadonnees ->> 'source') = 'scanner'
                     and h.cree_le >= public.aujourdhui()::timestamp at time zone 'America/Santo_Domingo'),
    'periode', (select count(*) from s),
    'echecs_suivis', false,
    'dernier', (select public.evenement_json(h.id) || jsonb_build_object('numero', co.numero)
                from public.colis_historique h join public.colis co on co.id = h.colis_id
                where (h.metadonnees ->> 'source') = 'scanner'
                order by h.cree_le desc, h.id desc limit 1),
    'par_employe', (select coalesce(jsonb_agg(jsonb_build_object(
                             'auteur_id', x.auteur_id,
                             'nom', coalesce(nullif(cl.nom_complet, ''), cl.email, 'Compte supprimé'),
                             'role', cl.role, 'nombre', x.n) order by x.n desc, cl.nom_complet), '[]'::jsonb)
                    from (select auteur_id, count(*) as n from s group by auteur_id) x
                    left join public.clients cl on cl.id = x.auteur_id),
    'par_operation', (select coalesce(jsonb_agg(jsonb_build_object(
                               'type', x.type_evenement,
                               'libelle', coalesce(public.types_evenement() -> x.type_evenement ->> 'libelle',
                                                   x.type_evenement),
                               'nombre', x.n) order by x.n desc, x.type_evenement), '[]'::jsonb)
                      from (select type_evenement, count(*) as n from s group by type_evenement) x),
    'par_jour', (select coalesce(jsonb_agg(jsonb_build_object(
                          'jour', j.jour,
                          'nombre', coalesce(x.n, 0))
                        order by j.jour), '[]'::jsonb)
                 from (select generate_series(p_jour_debut, p_jour_fin, interval '1 day')::date as jour) j
                 left join jours x on x.jour = j.jour))
$$;

-- L'activité récente : les derniers événements, toutes sources confondues
-- (formulaire, scanner, corrections), les plus récents d'abord
create or replace function public.tableau_activite(p_limite integer)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(public.evenement_json(d.id)
                            || jsonb_build_object('numero', d.numero, 'client', d.client,
                                                  'libelle', public.types_evenement() -> d.type_evenement ->> 'libelle',
                                                  'source', coalesce(d.metadonnees ->> 'source', ''))
                            order by d.cree_le desc, d.id desc), '[]'::jsonb)
  from (select h.id, h.cree_le, h.type_evenement, h.metadonnees, co.numero,
               (select cl.code from public.clients cl where cl.id = co.client_id) as client
        from public.colis_historique h join public.colis co on co.id = h.colis_id
        order by h.cree_le desc, h.id desc
        limit p_limite) d
$$;

-- Les derniers paiements reçus (les annulés n'y sont pas)
create or replace function public.tableau_paiements(p_limite integer)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'montant_usd', p.montant_usd, 'moyen', p.moyen, 'paye_le', p.paye_le,
           'facture_id', p.facture_id, 'facture', f.numero,
           'client', jsonb_build_object('code', cl.code, 'nom_complet', cl.nom_complet))
         order by p.paye_le desc, p.cree_le desc), '[]'::jsonb)
  from (select * from public.paiements where annule_le is null
        order by paye_le desc, cree_le desc limit p_limite) p
  join public.factures f on f.id = p.facture_id
  left join public.clients cl on cl.id = p.client_id
$$;

-- La vue générale : une période → tout ce que le compte a le droit de voir.
-- p_jours : au-delà de combien de jours sans événement un colis en cours est
-- « sans mouvement » (7 par défaut, de 1 à 365).
create or replace function public.vue_generale(p_periode text default '30j', p_debut date default null,
                                               p_fin date default null, p_jours integer default 7)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  p record;
  v_jours integer := coalesce(p_jours, 7);
  r jsonb;
  v_colis jsonb;
  v_factures jsonb;
  v_alertes jsonb := '[]'::jsonb;
  v_sans_facture bigint;
begin
  perform public.exiger_permission('shipments.view');
  if v_jours < 1 or v_jours > 365 then
    perform public.erreur_metier('INVALID_INPUT', 'Le nombre de jours sans mouvement va de 1 à 365.');
  end if;
  select * into p from public.bornes_periode(p_periode, p_debut, p_fin);

  v_colis := public.tableau_colis(p.debut, p.fin, p.jour_debut, p.jour_fin, v_jours);
  r := jsonb_build_object(
    'periode', jsonb_build_object('code', p.code, 'debut', p.jour_debut, 'fin', p.jour_fin,
                                  'jours', p.jour_fin - p.jour_debut + 1, 'fuseau', 'America/Santo_Domingo'),
    'jours_sans_mouvement', v_jours,
    'genere_le', now(),
    'colis', v_colis);

  if public.peut('clients.view') then
    r := r || jsonb_build_object('clients', public.tableau_clients(p.debut, p.fin));
  end if;
  if public.peut('reports.view') then
    v_factures := public.tableau_facturation(p.debut, p.fin, p.jour_debut, p.jour_fin);
    r := r || jsonb_build_object('facturation', v_factures);
  end if;
  if public.peut('shipments.view_history') then
    r := r || jsonb_build_object('scanner', public.tableau_scanner(p.debut, p.fin, p.jour_debut, p.jour_fin),
                                 'activite', public.tableau_activite(12));
  end if;
  if public.peut('payments.view') then
    r := r || jsonb_build_object('paiements_recents', public.tableau_paiements(8));
  end if;

  -- Les alertes : des règles de la maison, rien d'autre. Aucune règle
  -- déclenchée → une liste vide, que la page dit « Aucune alerte critique ».
  if (v_colis ->> 'action_requise')::bigint > 0 then
    v_alertes := v_alertes || jsonb_build_object('code', 'action_requise', 'gravite', 'critique',
      'nombre', (v_colis ->> 'action_requise')::bigint,
      'message', (v_colis ->> 'action_requise') || ' colis en « action requise » : le client ou l''équipe doit agir.');
  end if;
  if (v_colis ->> 'sans_mouvement')::bigint > 0 then
    v_alertes := v_alertes || jsonb_build_object('code', 'sans_mouvement', 'gravite', 'attention',
      'nombre', (v_colis ->> 'sans_mouvement')::bigint,
      'message', (v_colis ->> 'sans_mouvement') || ' colis en cours sans aucun événement depuis ' || v_jours
                 || ' jours ou plus.');
  end if;
  if v_factures is not null and (v_factures -> 'etats' ->> 'en_retard')::bigint > 0 then
    v_alertes := v_alertes || jsonb_build_object('code', 'factures_en_retard', 'gravite', 'attention',
      'nombre', (v_factures -> 'etats' ->> 'en_retard')::bigint,
      'message', (v_factures -> 'etats' ->> 'en_retard') || ' facture(s) échue(s) non soldée(s) : '
                 || replace(to_char((v_factures ->> 'montant_en_retard')::numeric, 'FM999999990.00'), '.', ',')
                 || ' $ en retard.');
  end if;
  -- Un colis avec un client doit être sur une facture active (creer_colis
  -- l'y met) : un colis qui n'y est pas ne sera jamais payé.
  if public.peut('invoices.view') then
    select count(*) into v_sans_facture
    from public.colis c
    where c.client_id is not null
      and not exists (select 1 from public.facture_lignes l join public.factures f on f.id = l.facture_id
                      where l.colis_id = c.id and f.statut <> 'annulee');
    if v_sans_facture > 0 then
      v_alertes := v_alertes || jsonb_build_object('code', 'colis_sans_facture', 'gravite', 'info',
        'nombre', v_sans_facture,
        'message', v_sans_facture || ' colis sur aucune facture active.');
    end if;
  end if;
  return r || jsonb_build_object('alertes', v_alertes);
end;
$$;


-- 4. Les colis à traiter ----------------------------------------------------------
-- Deux listes, paginées :
--   action_requise  les colis au statut « action requise », avec l'événement
--                   qui les y a mis (sa note dit pourquoi)
--   sans_mouvement  les colis en cours sans aucun événement depuis p_jours
--                   jours ou plus
-- Les plus anciens d'abord : ce sont eux qui attendent depuis le plus longtemps.
create or replace function public.colis_a_traiter(p_liste text, p_jours integer default 7, p_limite integer default 25,
                                                  p_decalage integer default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_liste text := lower(trim(coalesce(p_liste, '')));
  v_jours integer := coalesce(p_jours, 7);
  v_limite integer := least(greatest(coalesce(p_limite, 25), 1), 100);
  v_decalage integer := greatest(coalesce(p_decalage, 0), 0);
  v_historique boolean := public.peut('shipments.view_history');
  r jsonb;
begin
  perform public.exiger_permission('shipments.view');
  if v_liste not in ('action_requise', 'sans_mouvement') then
    perform public.erreur_metier('INVALID_INPUT', 'Liste inconnue : ' || left(v_liste, 30) || '.');
  end if;
  if v_jours < 1 or v_jours > 365 then
    perform public.erreur_metier('INVALID_INPUT', 'Le nombre de jours sans mouvement va de 1 à 365.');
  end if;
  with base as (
    select c.id, c.numero, c.client_id, c.statut, c.lieu, c.note, c.destination, c.pays_destination, c.poids_lb,
           c.description, c.recu_le, c.maj_le,
           d.id as dernier_id, coalesce(d.cree_le, c.recu_le) as mouvement,
           (select max(h.id) from public.colis_historique h
             where v_liste = 'action_requise' and h.colis_id = c.id and h.statut = 'incident'
               and not exists (select 1 from public.colis_historique x where x.corrige_id = h.id)) as action_id
    from public.colis c
    left join lateral (select h.id, h.cree_le from public.colis_historique h where h.colis_id = c.id
                       order by h.cree_le desc, h.id desc limit 1) d on true
    where case when v_liste = 'action_requise' then c.statut = 'incident' else c.statut <> 'livre' end
  ), choisis as (
    select b.*, coalesce((select h.cree_le from public.colis_historique h where h.id = b.action_id), b.mouvement) as depuis
    from base b
    where v_liste = 'action_requise' or b.mouvement < now() - make_interval(days => v_jours)
  ), page as (
    select * from choisis order by depuis, numero limit v_limite offset v_decalage
  )
  select jsonb_build_object(
    'liste', v_liste, 'jours', v_jours,
    'total', (select count(*) from choisis),
    'lignes', coalesce((select jsonb_agg(jsonb_build_object(
                'id', pg.id, 'numero', pg.numero, 'statut', pg.statut, 'lieu', pg.lieu, 'note', pg.note,
                'description', pg.description, 'destination', pg.destination,
                'pays_destination', pg.pays_destination, 'poids_lb', pg.poids_lb, 'recu_le', pg.recu_le,
                'maj_le', pg.maj_le, 'depuis', pg.depuis, 'dernier_mouvement', pg.mouvement,
                'jours', floor(extract(epoch from now() - pg.depuis) / 86400)::integer,
                'client', case when cl.id is null then null else jsonb_build_object(
                            'id', cl.id, 'code', cl.code, 'nom_complet', cl.nom_complet, 'telephone', cl.telephone) end,
                'dernier_evenement', case when v_historique then public.evenement_json(pg.dernier_id) end,
                'action', case when v_historique and pg.action_id is not null then public.evenement_json(pg.action_id) end)
              order by pg.depuis, pg.numero)
            from page pg left join public.clients cl on cl.id = pg.client_id), '[]'::jsonb))
    into r;
  return r;
end;
$$;


-- 5. La recherche rapide ----------------------------------------------------------
-- Un texte → les colis, les clients et les factures qui y répondent, chacun
-- par ses index :
--   colis     numéro exact ou son début (GSE-10…), suivi du vendeur exact,
--             code-barres (c'est le numéro) ou QR de l'étiquette (un lien
--             …index.html?suivi=GSE-…, dont on garde le numéro)
--   clients   code GSE, mots du nom (début de mot), derniers chiffres du
--             téléphone (4 au moins), début de l'e-mail
--   factures  numéro exact ou son début
-- Chaque partie n'apparaît que si le compte a la permission de la lire.
create or replace function public.recherche_rapide(p_texte text, p_limite integer default 8)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_brut text := left(trim(coalesce(p_texte, '')), 200);
  v_ref text;
  v_maj text;
  v_debut text;
  v_chiffres text;
  v_code text;
  v_mots text;
  v_requete tsquery;
  v_limite integer := least(greatest(coalesce(p_limite, 8), 1), 25);
  v_finances boolean := public.peut('invoices.view');
  v_historique boolean := public.peut('shipments.view_history');
  r jsonb;
begin
  perform public.exiger_permission('shipments.view');
  v_ref := trim(coalesce(substring(v_brut from '[?&]suivi=([A-Za-z0-9-]+)'), v_brut));
  r := jsonb_build_object('texte', v_brut, 'reference', v_ref);
  if length(v_ref) < 2 then
    return r || jsonb_build_object('colis', '[]'::jsonb)
             || case when public.peut('clients.view') then jsonb_build_object('clients', '[]'::jsonb) else '{}' end
             || case when v_finances then jsonb_build_object('factures', '[]'::jsonb) else '{}' end;
  end if;
  v_maj := upper(v_ref);
  -- Les jokers de LIKE tapés tels quels ne sont que des caractères
  v_debut := replace(replace(replace(v_maj, '\', '\\'), '%', '\%'), '_', '\_');
  v_chiffres := regexp_replace(v_ref, '[^0-9]', '', 'g');
  if length(v_chiffres) >= 4 and v_ref ~* '^(gse)?[\s-]*[0-9]+$' then
    v_code := 'GSE-' || v_chiffres;
  end if;
  if v_ref ~ '[[:alpha:]]' then
    select string_agg(m || ':*', ' & ') into v_mots
    from regexp_split_to_table(lower(v_ref), '[^[:alnum:]]+') m where m <> '';
    if v_mots is not null then
      v_requete := to_tsquery('simple', v_mots);
    end if;
  end if;

  r := r || jsonb_build_object('colis', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', c.id, 'numero', c.numero, 'suivi_transporteur', c.suivi_transporteur,
             'description', c.description, 'statut', c.statut, 'lieu', c.lieu, 'destination', c.destination,
             'pays_destination', c.pays_destination, 'service', c.service, 'poids_lb', c.poids_lb,
             'recu_le', c.recu_le, 'maj_le', c.maj_le, 'exact', c.exact,
             'prix_usd', case when v_finances then c.prix_usd end,
             'client', case when cl.id is null then null else jsonb_build_object(
                         'id', cl.id, 'code', cl.code, 'nom_complet', cl.nom_complet, 'telephone', cl.telephone) end,
             'dernier_evenement', case when v_historique then (
                 select public.evenement_json(h.id) from public.colis_historique h where h.colis_id = c.id
                 order by h.cree_le desc, h.id desc limit 1) end,
             'facture', case when v_finances then (
                 select jsonb_build_object('id', f.id, 'numero', f.numero, 'montant_usd', f.montant_usd,
                                           'paye_usd', public.paye_usd(f), 'solde_usd', public.solde_usd(f),
                                           'etat', public.etat_paiement(f))
                 from public.facture_lignes l join public.factures f on f.id = l.facture_id
                 where l.colis_id = c.id and f.statut <> 'annulee' order by f.cree_le desc limit 1) end)
           order by c.exact desc, c.maj_le desc)
    from (select co.*, (co.numero = v_maj or co.suivi_transporteur in (v_ref, v_maj)) as exact
          from public.colis co
          where co.numero = v_maj
             or co.suivi_transporteur in (v_ref, v_maj)
             or co.numero like v_debut || '%'
             or (v_code is not null and co.numero like v_code || '-%')
          order by (co.numero = v_maj or co.suivi_transporteur in (v_ref, v_maj)) desc, co.maj_le desc
          limit v_limite) c
    left join public.clients cl on cl.id = c.client_id), '[]'::jsonb));

  if public.peut('clients.view') then
    r := r || jsonb_build_object('clients', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', cl.id, 'code', cl.code, 'nom_complet', cl.nom_complet, 'telephone', cl.telephone,
               'email', cl.email, 'ville', cl.ville, 'pays', cl.pays,
               'colis_en_cours', (select count(*) from public.colis co where co.client_id = cl.id and co.statut <> 'livre'),
               'solde_usd', case when v_finances then (
                   select coalesce(sum(public.solde_usd(f)), 0) from public.factures f
                   where f.client_id = cl.id and f.statut <> 'annulee') end)
             order by cl.nom_complet)
      from (select * from public.clients c2
            where c2.role = 'client'
              and (c2.code = v_code
                   or (v_requete is not null and to_tsvector('simple', coalesce(c2.nom_complet, '')) @@ v_requete)
                   or (length(v_chiffres) >= 4 and v_ref !~ '[[:alpha:]]'
                       and reverse(regexp_replace(coalesce(c2.telephone, ''), '[^0-9]', '', 'g'))
                           like reverse(v_chiffres) || '%')
                   or (length(v_ref) >= 3 and v_ref !~ '\s'
                       and lower(c2.email) like lower(v_debut) || '%'))
            order by c2.code = v_code desc, c2.nom_complet
            limit v_limite) cl), '[]'::jsonb));
  end if;

  if v_finances then
    r := r || jsonb_build_object('factures', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', f.id, 'numero', f.numero, 'cree_le', f.cree_le, 'montant_usd', f.montant_usd,
               'paye_usd', public.paye_usd(f), 'solde_usd', public.solde_usd(f), 'etat', public.etat_paiement(f),
               'client', jsonb_build_object('code', cl.code, 'nom_complet', cl.nom_complet))
             order by f.numero = v_maj desc, f.cree_le desc)
      from (select * from public.factures fa
            where v_chiffres <> '' and (fa.numero = v_maj or fa.numero like v_debut || '%')
            order by fa.numero = v_maj desc, fa.cree_le desc limit v_limite) f
      left join public.clients cl on cl.id = f.client_id), '[]'::jsonb));
  end if;
  return r;
end;
$$;


-- 6. Les clients et leurs soldes --------------------------------------------------
-- L'onglet Clients : une page de clients, triée et filtrée par la base, avec
-- leurs colis en cours et leurs montants. Remplace l'ancien résumé fait dans
-- la page (limité à 500 colis et 1 000 factures).
--   p_tri    recent (inscription), nom, solde, activite (dernier colis mis à
--            jour), colis (nombre en cours)
--   p_filtre tous, avec_solde, avec_colis
-- Les montants (facturé, payé, solde) ne sont rendus qu'avec invoices.view ;
-- sans elle, trier ou filtrer par solde est refusé plutôt que de révéler un
-- ordre fondé sur des montants cachés.
create or replace function public.clients_soldes(p_recherche text default null, p_tri text default 'recent',
                                                 p_filtre text default 'tous', p_limite integer default 50,
                                                 p_decalage integer default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_recherche text := left(trim(coalesce(p_recherche, '')), 80);
  v_motif text;
  v_tri text := lower(coalesce(nullif(trim(p_tri), ''), 'recent'));
  v_filtre text := lower(coalesce(nullif(trim(p_filtre), ''), 'tous'));
  v_limite integer := least(greatest(coalesce(p_limite, 50), 1), 100);
  v_decalage integer := greatest(coalesce(p_decalage, 0), 0);
  v_finances boolean := public.peut('invoices.view');
  r jsonb;
begin
  perform public.exiger_permission('clients.view');
  if v_tri not in ('recent', 'nom', 'solde', 'activite', 'colis') then
    perform public.erreur_metier('INVALID_INPUT', 'Tri inconnu : ' || left(v_tri, 30) || '.');
  end if;
  if v_filtre not in ('tous', 'avec_solde', 'avec_colis') then
    perform public.erreur_metier('INVALID_INPUT', 'Filtre inconnu : ' || left(v_filtre, 30) || '.');
  end if;
  if not v_finances and (v_tri = 'solde' or v_filtre = 'avec_solde') then
    perform public.exiger_permission('invoices.view');
  end if;
  v_motif := '%' || replace(replace(replace(v_recherche, '\', '\\'), '%', '\%'), '_', '\_') || '%';

  with cl as (
    select c.* from public.clients c
    where c.role = 'client'
      and (v_recherche = '' or c.code ilike v_motif or c.nom_complet ilike v_motif or c.telephone ilike v_motif
           or c.email ilike v_motif or c.ville ilike v_motif or c.region ilike v_motif)
  ), co as (
    select co.client_id,
           count(*) filter (where co.statut <> 'livre') as en_cours,
           count(*) as total,
           coalesce(sum(co.poids_lb) filter (where co.statut <> 'livre'), 0) as poids,
           max(co.maj_le) as activite
    from public.colis co where co.client_id in (select id from cl)
    group by co.client_id
  ), pa as (
    select p.facture_id, sum(p.montant_usd) as paye
    from public.paiements p where p.annule_le is null and p.client_id in (select id from cl)
    group by p.facture_id
  ), fa as (
    select f.client_id, sum(f.montant_usd) as facture, sum(coalesce(pa.paye, 0)) as paye,
           sum(greatest(f.montant_usd - coalesce(pa.paye, 0), 0)) as solde,
           count(*) filter (where f.montant_usd - coalesce(pa.paye, 0) > 0) as ouvertes
    from public.factures f left join pa on pa.facture_id = f.id
    where f.statut <> 'annulee' and f.client_id in (select id from cl)
    group by f.client_id
  ), tout as (
    select cl.id, cl.code, cl.nom_complet, cl.telephone, cl.email, cl.ville, cl.region, cl.pays, cl.cree_le,
           coalesce(co.en_cours, 0) as en_cours, coalesce(co.total, 0) as total_colis, coalesce(co.poids, 0) as poids,
           co.activite, coalesce(fa.facture, 0) as facture, coalesce(fa.paye, 0) as paye,
           coalesce(fa.solde, 0) as solde, coalesce(fa.ouvertes, 0) as ouvertes
    from cl left join co on co.client_id = cl.id left join fa on fa.client_id = cl.id
    where v_filtre = 'tous'
       or (v_filtre = 'avec_solde' and coalesce(fa.solde, 0) > 0)
       or (v_filtre = 'avec_colis' and coalesce(co.en_cours, 0) > 0)
  ), page as (
    select t.*, row_number() over (order by
             case when v_tri = 'solde' then t.solde end desc nulls last,
             case when v_tri = 'colis' then t.en_cours end desc nulls last,
             case when v_tri = 'activite' then t.activite end desc nulls last,
             case when v_tri = 'nom' then lower(t.nom_complet) end asc,
             t.cree_le desc, t.id) as rang
    from tout t
  )
  select jsonb_build_object(
    'total', (select count(*) from tout),
    'finances', v_finances,
    'lignes', coalesce((select jsonb_agg(jsonb_build_object(
                'id', p.id, 'code', p.code, 'nom_complet', p.nom_complet, 'telephone', p.telephone,
                'email', p.email, 'ville', p.ville, 'region', p.region, 'pays', p.pays, 'cree_le', p.cree_le,
                'colis_en_cours', p.en_cours, 'colis_total', p.total_colis, 'poids_en_cours', p.poids,
                'derniere_activite', p.activite,
                'statuts', (select coalesce(jsonb_object_agg(s.statut, s.n), '{}'::jsonb)
                            from (select statut, count(*) as n from public.colis
                                  where client_id = p.id and statut <> 'livre' group by statut) s),
                'facture_usd', case when v_finances then p.facture end,
                'paye_usd', case when v_finances then p.paye end,
                'solde_usd', case when v_finances then p.solde end,
                'factures_ouvertes', case when v_finances then p.ouvertes end)
              order by p.rang)
            from page p where p.rang > v_decalage and p.rang <= v_decalage + v_limite), '[]'::jsonb))
    into r;
  return r;
end;
$$;


-- 7. L'espace client : mon résumé -------------------------------------------------
-- Le compte connecté, sur ses propres données et rien d'autre : ses colis
-- comptés par état, le total de ses factures, ce qu'il a payé, ce qu'il doit
-- encore, et les derniers messages que Goship Express lui a envoyés (e-mail,
-- WhatsApp, notification du téléphone). Mêmes chiffres que ceux de ses
-- factures (solde_usd, etat_paiement).
create or replace function public.mon_resume()
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
    perform public.erreur_metier('PERMISSION_DENIED', 'Connectez-vous pour voir votre compte.');
  end if;
  perform public.exiger_permission('clients.view', v_moi);
  return jsonb_build_object(
    'colis', (select jsonb_build_object(
                'en_cours', count(*) filter (where statut <> 'livre'),
                'livres', count(*) filter (where statut = 'livre'),
                'disponibles', count(*) filter (where statut = 'disponible'),
                'action_requise', count(*) filter (where statut = 'incident'))
              from public.colis where client_id = v_moi),
    'factures', case when public.peut('invoices.view', v_moi) then (
      with f as (
        select fa.montant_usd, fa.echeance_le, public.paye_usd(fa) as paye, public.solde_usd(fa) as solde,
               public.etat_paiement(fa) as etat
        from public.factures fa where fa.client_id = v_moi and fa.statut <> 'annulee'
      )
      select jsonb_build_object(
        'nombre', count(*),
        'facture_usd', coalesce(sum(montant_usd), 0),
        'paye_usd', coalesce(sum(paye), 0),
        'solde_usd', coalesce(sum(solde), 0),
        'ouvertes', count(*) filter (where solde > 0),
        'en_retard', count(*) filter (where etat = 'en_retard'),
        'montant_en_retard', coalesce(sum(solde) filter (where etat = 'en_retard'), 0),
        'prochaine_echeance', min(echeance_le) filter (where solde > 0 and echeance_le >= public.aujourdhui()))
      from f) end,
    'notifications', case when public.peut('shipments.view', v_moi) then (
      select coalesce(jsonb_agg(jsonb_build_object('canal', n.canal, 'evenement', n.evenement,
                                                   'envoye_le', n.envoye_le, 'numero', n.numero)
                                order by n.envoye_le desc), '[]'::jsonb)
      from (select x.canal, x.evenement, x.envoye_le, x.numero from (
              select n1.canal, n1.evenement, n1.envoye_le, co.numero
              from public.notifications n1 left join public.colis co on co.id = n1.colis_id
              where n1.client_id = v_moi
              union all
              select n2.canal, n2.evenement, n2.envoye_le, co.numero
              from public.colis co join public.notifications n2 on n2.colis_id = co.id
              where co.client_id = v_moi and n2.client_id is distinct from v_moi) x
            order by x.envoye_le desc limit 10) n) end);
end;
$$;


-- 8. Droits -----------------------------------------------------------------------
-- Les parties de la vue générale ne s'appellent pas seules : elles ne
-- vérifient pas les permissions, vue_generale le fait pour elles.
revoke execute on function public.bornes_periode(text, date, date) from public, anon, authenticated;
revoke execute on function public.tableau_colis(timestamptz, timestamptz, date, date, integer) from public, anon, authenticated;
revoke execute on function public.tableau_clients(timestamptz, timestamptz) from public, anon, authenticated;
revoke execute on function public.tableau_facturation(timestamptz, timestamptz, date, date) from public, anon, authenticated;
revoke execute on function public.tableau_scanner(timestamptz, timestamptz, date, date) from public, anon, authenticated;
revoke execute on function public.tableau_activite(integer) from public, anon, authenticated;
revoke execute on function public.tableau_paiements(integer) from public, anon, authenticated;

revoke execute on function public.vue_generale(text, date, date, integer) from public, anon;
revoke execute on function public.colis_a_traiter(text, integer, integer, integer) from public, anon;
revoke execute on function public.recherche_rapide(text, integer) from public, anon;
revoke execute on function public.clients_soldes(text, text, text, integer, integer) from public, anon;
revoke execute on function public.mon_resume() from public, anon;
grant execute on function public.vue_generale(text, date, date, integer) to authenticated;
grant execute on function public.colis_a_traiter(text, integer, integer, integer) to authenticated;
grant execute on function public.recherche_rapide(text, integer) to authenticated;
grant execute on function public.clients_soldes(text, text, text, integer, integer) to authenticated;
grant execute on function public.mon_resume() to authenticated;


-- Contrôle -------------------------------------------------------------------------
-- tableau_sur_12 : 12 (les fonctions de ce fichier) ; index_sur_8 : 8 ;
-- ouvertes_aux_visiteurs : 0 (aucune ne s'appelle sans être connecté).
select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('bornes_periode', 'tableau_colis', 'tableau_clients', 'tableau_facturation',
                            'tableau_scanner', 'tableau_activite', 'tableau_paiements', 'vue_generale',
                            'colis_a_traiter', 'recherche_rapide', 'clients_soldes', 'mon_resume'))
                                                                                          as tableau_sur_12,
       (select count(*) from pg_indexes
        where schemaname = 'public'
          and indexname in ('colis_numero_debut_idx', 'factures_numero_debut_idx', 'clients_nom_mots_idx',
                            'clients_telephone_fin_idx', 'clients_email_debut_idx', 'clients_inscription_idx',
                            'colis_historique_scanner_idx', 'factures_creation_idx'))    as index_sur_8,
       (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('vue_generale', 'colis_a_traiter', 'recherche_rapide', 'clients_soldes', 'mon_resume')
          and has_function_privilege('anon', p.oid, 'execute'))                           as ouvertes_aux_visiteurs;
