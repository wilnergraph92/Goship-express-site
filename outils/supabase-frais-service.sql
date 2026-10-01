-- =============================================================================
-- Goship Express — les frais de service au regroupement et à l'encaissement (30/09/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce fichier
-- remplace des fonctions et en AJOUTE. Il ne change aucune donnée existante — une
-- facture déjà émise garde ses frais, qu'elle en ait ou non — et peut être relancé
-- autant de fois qu'on veut.
--
-- Ordre d'installation : le dernier de la chaîne (outils/migrations.txt), après
-- supabase-profil-complet.sql. Il remplace des fonctions de supabase-services.sql,
-- supabase-finances.sql et supabase-regroupement.sql : relancer l'un de ceux-là
-- impose de relancer ce fichier ensuite (la règle de la chaîne).
--
-- La nouvelle règle :
--   - enregistrer un colis : sa facture naît SANS frais de service (0 $) ;
--   - regrouper : la nouvelle facture reçoit les frais de service si on le demande
--     (une ligne à part, frais_service_usd), jamais dans le prix d'un colis ;
--   - encaisser : on choisit d'ajouter les frais (oui / non) ; déjà appliqués, ils
--     ne s'ajoutent pas une seconde fois ;
--   - le montant des frais reste celui de la maison (tarifs() : 10 $), rien d'autre.
--
-- L'état des frais d'une facture est la colonne qui existe déjà :
-- frais_service_usd = 0 (pas appliqués) ou > 0 (appliqués, et leur montant). Le
-- total (montant_usd), le payé et le solde suivent, comme avant. Aucune colonne
-- n'est ajoutée.
--
-- Une facture émise ne reçoit toujours ni colis ni ligne (verrou_facture_ligne) :
-- « ajouter un colis » à une facture, c'est la regrouper avec ce colis — elle est
-- annulée et une nouvelle la remplace, avec son renvoi (remplacee_par).
--
-- Contenu :
--    1. garde : la chaîne est-elle à jour ?
--    2. facturer_colis_interne : la facture d'un colis, sans frais
--    3. creer_facture : les frais seulement si on les demande
--    4. regles_facture : les frais et le total changent par les fonctions de ce fichier
--    5. frais_service_interne, changer_frais_service : appliquer ou retirer les frais
--    6. encaisser_facture : les frais (oui / non) et le paiement, ensemble
--    7. regrouper : des factures et des colis, avec ou sans frais
--    8. regrouper_factures : l'ancien chemin, par regrouper
--    9. colis_a_regrouper : les colis qu'on peut ajouter à un regroupement
--   10. sortir_du_regroupement : les frais restent sur la facture qui garde le regroupement
--   11. rapport d'anomalies : une facture sans frais n'est plus une anomalie
--   12. droits
--   13. contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regprocedure('public.sortir_du_regroupement(uuid, uuid[], text)') is null
     or to_regprocedure('public.regrouper_factures(uuid[], text)') is null
     or to_regprocedure('public.enregistrer_paiement(uuid, jsonb, text)') is null
     or to_regprocedure('public.recalculer_facture(uuid)') is null
     or to_regprocedure('public.profil_complet(uuid)') is null then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt), puis ce fichier.';
  end if;
end;
$garde$;


-- 2. La facture d'un colis, sans frais -------------------------------------------------
-- Appelée par creer_colis (enregistrement) et facturer_colis : le prix du colis,
-- rien de plus. Les frais viendront au regroupement ou à l'encaissement.
create or replace function public.facturer_colis_interne(p_colis uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.colis;
  v_existante uuid;
  v_facture uuid;
  v_prix numeric;
begin
  select * into c from public.colis where id = p_colis for update;
  if not found then
    perform public.erreur_metier('SHIPMENT_NOT_FOUND', 'Aucun colis avec cet identifiant.');
  end if;
  if c.client_id is null then
    perform public.erreur_metier('CLIENT_NOT_FOUND', 'Ce colis n''a plus de client : impossible de le facturer.');
  end if;

  select l.facture_id into v_existante
    from public.facture_lignes l join public.factures f on f.id = l.facture_id
   where l.colis_id = c.id and f.statut <> 'annulee'
   order by f.cree_le desc limit 1;
  if v_existante is not null then
    return jsonb_build_object('facture', public.facture_json(v_existante), 'deja', true);
  end if;

  v_prix := coalesce(c.prix_usd, public.prix_transport(c.poids_lb, c.tarif_lb_usd));
  insert into public.factures (client_id, montant_usd, frais_service_usd, montant_paye_usd, statut)
  values (c.client_id, v_prix, 0, 0, 'a_payer')
  returning id into v_facture;
  insert into public.facture_lignes (facture_id, colis_id, libelle, montant_usd, quantite, poids_lb)
  values (v_facture, c.id, coalesce(nullif(c.description, ''), 'Transport'), v_prix, 1, c.poids_lb);

  raise log 'goship facture creee colis=% facture=%', c.numero, v_facture;
  return jsonb_build_object('facture', public.facture_json(v_facture), 'deja', false);
end;
$$;


-- 3. creer_facture : les frais seulement si on les demande ------------------------------
-- p_champs.frais_service = true : les frais de la maison, une fois, sur une facture
-- de colis. Absent ou false : aucun frais (ils pourront s'ajouter à l'encaissement).
-- Une facture d'un montant libre (sans colis) n'en porte jamais à sa création.
create or replace function public.creer_facture(p_client uuid, p_colis uuid[], p_champs jsonb default '{}',
                                                p_cle text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v jsonb := coalesce(p_champs, '{}'::jsonb);
  v_cle text := nullif(trim(coalesce(p_cle, '')), '');
  v_ids uuid[];
  c public.colis;
  v_existante public.factures;
  v_autre text;
  v_total numeric := 0;
  v_frais numeric := 0;
  v_montant numeric;
  v_paye numeric;
  v_echeance date;
  v_facture uuid;
begin
  perform public.exiger_permission('invoices.create');
  if not exists (select 1 from public.clients where id = p_client and role = 'client') then
    perform public.erreur_metier('CLIENT_NOT_FOUND', 'Aucun client avec cet identifiant.');
  end if;
  if v_cle is not null then
    perform pg_advisory_xact_lock(hashtextextended('goship-creer-facture:' || v_cle, 0));
    select * into v_existante from public.factures where cle_idempotence = v_cle;
    if found then
      if v_existante.client_id <> p_client then
        perform public.erreur_metier('DUPLICATE_OPERATION', 'Cette requête a déjà servi pour un autre client.');
      end if;
      return jsonb_build_object('facture', public.facture_json(v_existante.id), 'deja', true);
    end if;
  end if;

  select array_agg(distinct i) into v_ids from unnest(coalesce(p_colis, '{}')) i where i is not null;
  if v_ids is not null then
    if array_length(v_ids, 1) > 200 then
      perform public.erreur_metier('INVALID_INPUT', 'Au plus 200 colis par facture.');
    end if;
    if (select count(*) from public.colis where id = any (v_ids)) <> array_length(v_ids, 1) then
      perform public.erreur_metier('SHIPMENT_NOT_FOUND', 'Un colis choisi n''existe plus.');
    end if;
    for c in select * from public.colis where id = any (v_ids) order by id for update loop
      if c.client_id is distinct from p_client then
        perform public.erreur_metier('INVOICE_CLIENT_MISMATCH',
          'Le colis ' || c.numero || ' appartient à un autre client : une facture n''en regroupe qu''un seul.');
      end if;
      select f.numero into v_autre
        from public.facture_lignes l join public.factures f on f.id = l.facture_id
       where l.colis_id = c.id and f.statut <> 'annulee' limit 1;
      if v_autre is not null then
        perform public.erreur_metier('INVOICE_ALREADY_EXISTS',
          'Le colis ' || c.numero || ' est déjà sur la facture ' || v_autre || '.');
      end if;
      v_total := v_total + coalesce(c.prix_usd, public.prix_transport(c.poids_lb, c.tarif_lb_usd));
    end loop;
    if v -> 'frais_service' = 'true'::jsonb then
      v_frais := (public.tarifs() ->> 'frais_service')::numeric;
    end if;
    v_montant := v_total + v_frais;
  else
    v_montant := public.lire_nombre(v -> 'montant_usd', 'INVALID_AMOUNT', 'Montant illisible.');
    if v_montant is null or v_montant < 0 then
      perform public.erreur_metier('INVALID_AMOUNT', 'Indiquez le montant de la facture.');
    end if;
    v_montant := round(v_montant, 2);
  end if;

  v_paye := coalesce(public.lire_nombre(v -> 'montant_paye_usd', 'INVALID_AMOUNT', 'Montant payé illisible.'), 0);
  if v_paye < 0 then
    perform public.erreur_metier('INVALID_AMOUNT', 'Le montant payé ne peut pas être négatif.');
  end if;
  v_paye := least(round(v_paye, 2), v_montant);
  begin
    v_echeance := nullif(v ->> 'echeance_le', '')::date;
  exception when others then
    perform public.erreur_metier('INVALID_DATE', 'Date d''échéance illisible.');
  end;

  insert into public.factures (client_id, montant_usd, frais_service_usd, montant_paye_usd, statut, payee_le,
                               echeance_le, lien_paiement, note, cle_idempotence)
  values (p_client, v_montant, v_frais, v_paye,
          case when v_montant > 0 and v_paye >= v_montant then 'payee' else 'a_payer' end,
          case when v_montant > 0 and v_paye >= v_montant then now() end,
          v_echeance,
          left(trim(coalesce(v ->> 'lien_paiement', '')), 500),
          left(trim(coalesce(v ->> 'note', '')), 500),
          v_cle)
  returning id into v_facture;

  if v_ids is not null then
    insert into public.facture_lignes (facture_id, colis_id, libelle, montant_usd, quantite, poids_lb)
    select v_facture, co.id, coalesce(nullif(co.description, ''), 'Transport'),
           coalesce(co.prix_usd, public.prix_transport(co.poids_lb, co.tarif_lb_usd)), 1, co.poids_lb
      from public.colis co where co.id = any (v_ids)
     order by co.recu_le, co.id;
  end if;

  return jsonb_build_object('facture', public.facture_json(v_facture), 'deja', false);
end;
$$;


-- 4. regles_facture -------------------------------------------------------------------
-- Comme avant (supabase-services.sql), à une exception : les frais et le total
-- d'une facture de colis changent quand une fonction des finances le fait
-- (contexte_finances : frais_service_interne ci-dessous). Une page qui écrirait
-- dans la table reste refusée.
create or replace function public.regles_facture()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_autre text;
begin
  if new.frais_service_usd is distinct from old.frais_service_usd and not public.contexte_finances() then
    perform public.erreur_metier('INVOICE_LOCKED',
      'Les frais de service s''ajoutent ou se retirent par « Encaisser » ou la fiche de la facture.');
  end if;
  if new.client_id is distinct from old.client_id then
    perform public.erreur_metier('INVOICE_LOCKED', 'Une facture émise ne change pas de client.');
  end if;
  if new.montant_usd is distinct from old.montant_usd and not public.contexte_finances()
     and exists (select 1 from public.facture_lignes where facture_id = new.id and colis_id is not null) then
    perform public.erreur_metier('INVOICE_LOCKED',
      'Le total d''une facture de colis est celui de ses colis et de ses frais : il ne se modifie pas.');
  end if;
  if (new.montant_paye_usd is distinct from old.montant_paye_usd
      or new.montant_usd is distinct from old.montant_usd)
     and new.montant_paye_usd > new.montant_usd then
    perform public.erreur_metier('INVALID_AMOUNT', 'Le montant payé dépasse le total de la facture.');
  end if;
  -- Une facture annulée qu'on réactive ne doit pas doubler une facture émise
  -- entre-temps pour les mêmes colis.
  if old.statut = 'annulee' and new.statut <> 'annulee' then
    select f.numero into v_autre
      from public.facture_lignes l
      join public.facture_lignes a on a.colis_id = l.colis_id and a.facture_id <> l.facture_id
      join public.factures f on f.id = a.facture_id and f.statut <> 'annulee'
     where l.facture_id = new.id and l.colis_id is not null
     limit 1;
    if v_autre is not null then
      perform public.erreur_metier('INVOICE_ALREADY_EXISTS',
        'Un colis de cette facture a été refacturé depuis (facture ' || v_autre || ').');
    end if;
  end if;
  return new;
end;
$$;


-- 5. Appliquer ou retirer les frais d'une facture ------------------------------------------
-- Le corps, sans vérification de permission (appelé par changer_frais_service et
-- encaisser_facture, qui vérifient chacune la leur). Sous le verrou de la facture :
--   appliquer, frais déjà là  → rien ne change (deja), JAMAIS une seconde fois ;
--   retirer, pas de frais     → rien ne change (deja) ;
--   sinon, frais_service_usd et montant_usd changent ensemble, puis le payé, le
--   statut et le solde sont recalculés depuis les paiements (recalculer_facture).
-- Refusé : une facture annulée ou déjà payée ; retirer des frais sous ce qui est
-- déjà payé.
create or replace function public.frais_service_interne(p_facture uuid, p_appliquer boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  f public.factures;
  v_frais numeric := (public.tarifs() ->> 'frais_service')::numeric;
  v_paye numeric;
  v_nouveau numeric;
  v_avant text := coalesce(current_setting('goship.finances', true), '');
begin
  if p_appliquer is null then
    perform public.erreur_metier('INVALID_INPUT', 'Indiquez s''il faut ajouter ou retirer les frais de service.');
  end if;
  select * into f from public.factures where id = p_facture for update;
  if not found then
    perform public.erreur_metier('INVOICE_NOT_FOUND', 'Aucune facture avec cet identifiant.');
  end if;
  if (p_appliquer and f.frais_service_usd > 0) or (not p_appliquer and f.frais_service_usd = 0) then
    return jsonb_build_object('facture', public.facture_complete(f.id), 'deja', true);
  end if;
  if f.statut = 'annulee' then
    perform public.erreur_metier('INVOICE_CANCELLED',
      'La facture ' || f.numero || ' est annulée : ses frais de service ne changent plus.');
  end if;
  if f.statut = 'payee' then
    perform public.erreur_metier('INVOICE_ALREADY_PAID',
      'La facture ' || f.numero || ' est déjà entièrement payée : ses frais de service ne changent plus.');
  end if;

  if p_appliquer then
    v_nouveau := f.montant_usd + v_frais;
  else
    v_frais := 0;
    v_nouveau := f.montant_usd - f.frais_service_usd;
    select coalesce(sum(montant_usd), 0) into v_paye
      from public.paiements where facture_id = f.id and annule_le is null;
    if v_nouveau < v_paye then
      perform public.erreur_metier('INVALID_AMOUNT',
        'La facture ' || f.numero || ' a déjà reçu ' || to_char(v_paye, 'FM999999990.00') ||
        ' $ : sans les frais, son total serait inférieur à ce qui est payé.');
    end if;
  end if;

  perform set_config('goship.finances', 'on', true);
  update public.factures set frais_service_usd = v_frais, montant_usd = v_nouveau where id = f.id;
  perform set_config('goship.finances', v_avant, true);
  perform public.recalculer_facture(f.id);

  perform public.auditer(case when p_appliquer then 'facture.frais_appliques' else 'facture.frais_retires' end,
                         'facture', f.id::text,
                         jsonb_build_object('numero', f.numero, 'frais_service_usd', f.frais_service_usd,
                                            'montant_usd', f.montant_usd),
                         jsonb_build_object('frais_service_usd', v_frais, 'montant_usd', v_nouveau));
  return jsonb_build_object('facture', public.facture_complete(f.id), 'deja', false);
end;
$$;

-- Depuis la fiche d'une facture : ajouter ou retirer ses frais (invoices.edit).
-- Réponse : { facture, deja }.
create or replace function public.changer_frais_service(p_facture uuid, p_appliquer boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('invoices.edit');
  return public.frais_service_interne(p_facture, p_appliquer);
end;
$$;


-- 6. Encaisser : les frais (oui / non) et le paiement, ensemble ------------------------------
--   p_frais = true  : les frais sont ajoutés s'ils ne le sont pas encore (jamais deux
--                     fois), puis le paiement est enregistré ;
--   p_frais = false : le paiement seul, sans rien ajouter.
-- Une seule transaction : si le paiement est refusé (montant au-delà du solde…),
-- les frais ne restent pas ajoutés. La même clé renvoyée (double clic, réseau
-- coupé) rend le paiement déjà enregistré sans rien refaire.
-- Réponse : celle d'enregistrer_paiement, plus frais_ajoutes (vrai si CET appel les
-- a ajoutés).
create or replace function public.encaisser_facture(p_facture uuid, p_paiement jsonb, p_frais boolean,
                                                    p_cle text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cle text := nullif(trim(coalesce(p_cle, '')), '');
  v_frais jsonb;
begin
  perform public.exiger_permission('payments.create');
  if v_cle is not null and exists (select 1 from public.paiements where cle_idempotence = v_cle) then
    return public.enregistrer_paiement(p_facture, p_paiement, v_cle) || jsonb_build_object('frais_ajoutes', false);
  end if;
  if coalesce(p_frais, false) then
    perform public.exiger_permission('invoices.edit');
    v_frais := public.frais_service_interne(p_facture, true);
  end if;
  return public.enregistrer_paiement(p_facture, p_paiement, v_cle)
         || jsonb_build_object('frais_ajoutes', coalesce(v_frais ->> 'deja', 'true') = 'false');
end;
$$;


-- 7. Regrouper des factures et des colis ----------------------------------------------------
--   p_factures : des factures de colis d'un même client, à payer, sans paiement ;
--   p_colis    : des colis de ce client à ajouter. Un colis sans facture active
--                entre tel quel ; un colis déjà sur une facture regroupable fait
--                entrer toute sa facture ; sur une facture payée ou qui a reçu un
--                paiement, il est refusé ;
--   p_frais    : la nouvelle facture reçoit les frais de service (une fois), ou non.
-- Il faut au moins deux choses à réunir (factures et colis sans facture). Les
-- factures réunies sont annulées, avec leur motif et un renvoi vers la nouvelle,
-- qui passe par creer_facture : prix des colis tels qu'inscrits sur eux. Un colis
-- n'y figure jamais deux fois. Tout se fait dans la même transaction.
-- Réponse : { facture, annulees, deja }.
create or replace function public.regrouper(p_factures uuid[], p_colis uuid[], p_frais boolean,
                                            p_cle text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cle text := nullif(trim(coalesce(p_cle, '')), '');
  v_ids uuid[];
  v_libres uuid[] := '{}';
  f public.factures;
  c public.colis;
  v_facture_du_colis public.factures;
  v_client uuid;
  v_colis uuid[] := '{}';
  v_echeance date;
  v_numeros text[] := '{}';
  v_existante uuid;
  v_nouvelle uuid;
  v_motif text;
  r jsonb;
  v_avant text := coalesce(current_setting('goship.finances', true), '');
begin
  perform public.exiger_permission('invoices.create');
  perform public.exiger_permission('invoices.cancel');
  if p_frais is null then
    perform public.erreur_metier('INVALID_INPUT', 'Indiquez si la facture reçoit les frais de service.');
  end if;
  if v_cle is not null then
    perform pg_advisory_xact_lock(hashtextextended('goship-creer-facture:' || v_cle, 0));
    select id into v_existante from public.factures where cle_idempotence = v_cle;
    if found then
      return jsonb_build_object(
        'facture', public.facture_complete(v_existante),
        'annulees', coalesce((select jsonb_agg(numero order by numero) from public.factures
                              where remplacee_par = v_existante), '[]'::jsonb),
        'deja', true);
    end if;
  end if;

  select array_agg(distinct i order by i) into v_ids from unnest(coalesce(p_factures, '{}')) i where i is not null;
  v_ids := coalesce(v_ids, '{}');
  if (select count(*) from public.factures where id = any (v_ids)) <> coalesce(array_length(v_ids, 1), 0) then
    perform public.erreur_metier('INVOICE_NOT_FOUND', 'Une des factures choisies n''existe plus.');
  end if;

  -- Les colis ajoutés : sans facture, ils entrent seuls ; sur une facture, elle entre
  if (select count(distinct i) from unnest(coalesce(p_colis, '{}')) i where i is not null) > 200 then
    perform public.erreur_metier('INVALID_INPUT', 'Au plus 200 colis par facture.');
  end if;
  for c in select * from public.colis
            where id in (select distinct i from unnest(coalesce(p_colis, '{}')) i where i is not null)
            order by id for update loop
    select fa.* into v_facture_du_colis
      from public.facture_lignes l join public.factures fa on fa.id = l.facture_id
     where l.colis_id = c.id and fa.statut <> 'annulee'
     order by fa.cree_le desc limit 1;
    if v_facture_du_colis.id is null then
      v_libres := v_libres || c.id;
    elsif not (v_facture_du_colis.id = any (v_ids)) then
      if v_facture_du_colis.statut <> 'a_payer'
         or exists (select 1 from public.paiements where facture_id = v_facture_du_colis.id and annule_le is null) then
        perform public.erreur_metier('INVOICE_ALREADY_EXISTS',
          'Le colis ' || c.numero || ' est sur la facture ' || v_facture_du_colis.numero ||
          case when v_facture_du_colis.statut = 'payee' then ', déjà payée' else ', qui a déjà reçu un paiement' end ||
          ' : il ne peut pas être ajouté.');
      end if;
      v_ids := v_ids || v_facture_du_colis.id;
    end if;
    v_facture_du_colis := null;
  end loop;
  if (select count(*) from public.colis
       where id in (select distinct i from unnest(coalesce(p_colis, '{}')) i where i is not null))
     <> (select count(distinct i) from unnest(coalesce(p_colis, '{}')) i where i is not null) then
    perform public.erreur_metier('SHIPMENT_NOT_FOUND', 'Un colis choisi n''existe plus.');
  end if;

  if coalesce(array_length(v_ids, 1), 0) + coalesce(array_length(v_libres, 1), 0) < 2 then
    perform public.erreur_metier('INVALID_INPUT',
      'Choisissez au moins deux factures, ou une facture et un colis à ajouter.');
  end if;
  if coalesce(array_length(v_ids, 1), 0) > 50 then
    perform public.erreur_metier('INVALID_INPUT', 'Au plus 50 factures par regroupement.');
  end if;

  for f in select * from public.factures where id = any (v_ids) order by id for update loop
    if v_client is null then
      v_client := f.client_id;
    elsif f.client_id <> v_client then
      perform public.erreur_metier('INVOICE_CLIENT_MISMATCH',
        'Les factures choisies appartiennent à plusieurs clients : on ne regroupe que celles d''un seul.');
    end if;
    if f.statut <> 'a_payer' then
      perform public.erreur_metier('INVOICE_NOT_GROUPABLE',
        'La facture ' || f.numero || ' est ' || case when f.statut = 'payee' then 'payée' else 'annulée' end ||
        ' : elle ne se regroupe pas.');
    end if;
    if exists (select 1 from public.paiements where facture_id = f.id and annule_le is null) then
      perform public.erreur_metier('INVOICE_HAS_PAYMENTS',
        'La facture ' || f.numero || ' a déjà reçu un paiement : elle ne se regroupe pas.');
    end if;
    if not exists (select 1 from public.facture_lignes where facture_id = f.id)
       or exists (select 1 from public.facture_lignes where facture_id = f.id and colis_id is null) then
      perform public.erreur_metier('INVOICE_NOT_GROUPABLE',
        'La facture ' || f.numero || ' n''est pas une facture de colis : elle ne se regroupe pas.');
    end if;
    v_colis := v_colis || array(select colis_id from public.facture_lignes where facture_id = f.id);
    v_echeance := least(v_echeance, f.echeance_le);
    v_numeros := v_numeros || f.numero;
  end loop;

  for c in select * from public.colis where id = any (v_libres) order by id loop
    if v_client is null then
      v_client := c.client_id;
    elsif c.client_id is distinct from v_client then
      perform public.erreur_metier('INVOICE_CLIENT_MISMATCH',
        'Le colis ' || c.numero || ' appartient à un autre client : une facture n''en regroupe qu''un seul.');
    end if;
  end loop;
  if v_client is null then
    perform public.erreur_metier('CLIENT_NOT_FOUND', 'Ce colis n''a plus de client : impossible de le facturer.');
  end if;
  v_colis := array(select distinct i from unnest(v_colis || v_libres) i);

  if array_length(v_numeros, 1) > 0 then
    v_motif := 'Regroupement des factures ' || array_to_string(v_numeros, ', ');
    perform set_config('goship.finances', 'on', true);
    update public.factures
       set statut = 'annulee', annulee_le = now(), annulee_par = auth.uid(), motif_annulation = v_motif
     where id = any (v_ids);
    perform set_config('goship.finances', v_avant, true);
  end if;

  r := public.creer_facture(v_client, v_colis,
                            jsonb_build_object('echeance_le', v_echeance, 'frais_service', p_frais), v_cle);
  v_nouvelle := (r -> 'facture' ->> 'id')::uuid;

  if array_length(v_ids, 1) > 0 then
    perform set_config('goship.finances', 'on', true);
    update public.factures set remplacee_par = v_nouvelle where id = any (v_ids);
    perform set_config('goship.finances', v_avant, true);
  end if;

  perform public.auditer('facture.regroupement', 'facture', v_nouvelle::text,
                         jsonb_build_object('factures', to_jsonb(v_numeros),
                                            'colis_ajoutes', (select coalesce(jsonb_agg(numero order by numero), '[]'::jsonb)
                                                              from public.colis where id = any (v_libres))),
                         jsonb_build_object('numero', r -> 'facture' ->> 'numero',
                                            'montant_usd', r -> 'facture' -> 'montant_usd',
                                            'frais_service_usd', r -> 'facture' -> 'frais_service_usd'));
  return jsonb_build_object('facture', public.facture_complete(v_nouvelle), 'annulees', to_jsonb(v_numeros),
                            'deja', false);
end;
$$;


-- 8. regrouper_factures : l'ancien chemin ----------------------------------------------------
-- Gardé pour les pages déjà ouvertes : le même regroupement, par regrouper, avec
-- les frais comme il les a toujours mis (une fois).
create or replace function public.regrouper_factures(p_factures uuid[], p_cle text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(array_length(p_factures, 1), 0) < 2 then
    perform public.exiger_permission('invoices.create');
    perform public.erreur_metier('INVALID_INPUT', 'Choisissez au moins deux factures à regrouper.');
  end if;
  return public.regrouper(p_factures, '{}', true, p_cle);
end;
$$;


-- 9. Les colis qu'on peut ajouter à un regroupement ---------------------------------------------
-- Ceux du client, qui ne sont sur aucune facture active, ou sur une facture de colis
-- à payer sans paiement (elle entrera avec eux). p_exclure : ceux déjà dans la
-- fenêtre. p_recherche : numéro, contenu, magasin, suivi du vendeur, destination
-- ou numéro de facture. Au plus 50, les plus récents d'abord.
-- Réponse : [{ colis_id, numero, description, expediteur, suivi_transporteur,
--              destination, poids_lb, prix_usd, statut, recu_le,
--              facture: null | { id, numero, montant_usd, frais_service_usd, nb_colis } }]
create or replace function public.colis_a_regrouper(p_client uuid, p_recherche text default '',
                                                    p_exclure uuid[] default '{}')
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_texte text := lower(trim(coalesce(p_recherche, '')));
  r jsonb;
begin
  perform public.exiger_permission('invoices.create');
  perform public.exiger_permission('shipments.view');
  with actives as (
    select distinct on (l.colis_id) l.colis_id, fa.*
      from public.facture_lignes l join public.factures fa on fa.id = l.facture_id
     where fa.statut <> 'annulee'
     order by l.colis_id, fa.cree_le desc
  ), candidats as (
    select co.*, a.id as f_id, a.numero as f_numero, a.montant_usd as f_montant, a.frais_service_usd as f_frais,
           (select count(*) from public.facture_lignes x where x.facture_id = a.id) as f_nb
      from public.colis co
      left join actives a on a.colis_id = co.id
     where co.client_id = p_client
       and not (co.id = any (coalesce(p_exclure, '{}')))
       and (a.id is null
            or (a.statut = 'a_payer'
                and not exists (select 1 from public.paiements p where p.facture_id = a.id and p.annule_le is null)
                and not exists (select 1 from public.facture_lignes x where x.facture_id = a.id and x.colis_id is null)))
       and (v_texte = ''
            or lower(co.numero) like '%' || v_texte || '%'
            or lower(coalesce(co.description, '')) like '%' || v_texte || '%'
            or lower(coalesce(co.expediteur, '')) like '%' || v_texte || '%'
            or lower(coalesce(co.suivi_transporteur, '')) like '%' || v_texte || '%'
            or lower(coalesce(co.destination, '')) like '%' || v_texte || '%'
            or lower(coalesce(a.numero, '')) like '%' || v_texte || '%')
     order by co.recu_le desc, co.id
     limit 50
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'colis_id', c.id, 'numero', c.numero, 'description', c.description, 'expediteur', c.expediteur,
           'suivi_transporteur', c.suivi_transporteur, 'destination', c.destination, 'poids_lb', c.poids_lb,
           'prix_usd', coalesce(c.prix_usd, public.prix_transport(c.poids_lb, c.tarif_lb_usd)),
           'statut', c.statut, 'recu_le', c.recu_le,
           'facture', case when c.f_id is null then null
                           else jsonb_build_object('id', c.f_id, 'numero', c.f_numero, 'montant_usd', c.f_montant,
                                                   'frais_service_usd', c.f_frais, 'nb_colis', c.f_nb) end)
           order by c.recu_le desc, c.id), '[]'::jsonb)
    into r
    from candidats c;
  return r;
end;
$$;


-- 10. sortir_du_regroupement ------------------------------------------------------------------
-- Comme avant (supabase-regroupement.sql), sauf les frais : la facture qui garde le
-- regroupement garde ses frais s'il en avait ; celle des colis sortis naît sans
-- frais (ils s'ajouteront à l'encaissement si on le veut). Sortir un colis ne
-- rajoute donc plus de frais de lui-même.
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
  v_sortie := (public.creer_facture(f.client_id, v_sortis, v_champs || jsonb_build_object('frais_service', false),
                                    v_cle) -> 'facture' ->> 'id')::uuid;
  v_restante := (public.creer_facture(f.client_id, v_reste,
                                      v_champs || jsonb_build_object('frais_service', f.frais_service_usd > 0),
                                      v_cle || ':reste') -> 'facture' ->> 'id')::uuid;

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


-- 11. Le rapport d'anomalies ------------------------------------------------------------------
-- Comme avant (supabase-finances.sql), sauf « frais_absents » : une facture sans
-- frais est désormais normale (ils s'ajoutent au regroupement ou à l'encaissement).
-- Seules sont encore signalées celles de la semaine où les frais étaient dus dès
-- l'enregistrement (du 22/09/2026 à ce changement, le 30/09/2026).
create or replace function public.rapport_anomalies_facturation()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  r jsonb;
begin
  if auth.uid() is not null then
    perform public.exiger_permission('reports.view');
  end if;
  with lignes as (
    select l.facture_id, count(*) as nb, count(l.colis_id) as nb_colis, sum(l.montant_usd) as total
    from public.facture_lignes l group by l.facture_id
  ), payes as (
    select p.facture_id, sum(p.montant_usd) as paye
    from public.paiements p where p.annule_le is null group by p.facture_id
  ), a as (
    select 'colis_facture_deux_fois' as type, 'erreur' as gravite, f.id as facture_id, f.numero,
           'Le colis ' || co.numero || ' est aussi sur la facture ' ||
           (select string_agg(f2.numero, ', ') from public.facture_lignes l2
              join public.factures f2 on f2.id = l2.facture_id
             where l2.colis_id = l.colis_id and f2.id <> f.id and f2.statut <> 'annulee') || '.' as detail
    from public.facture_lignes l
    join public.factures f on f.id = l.facture_id and f.statut <> 'annulee'
    join public.colis co on co.id = l.colis_id
    where exists (select 1 from public.facture_lignes l2 join public.factures f2 on f2.id = l2.facture_id
                  where l2.colis_id = l.colis_id and f2.id <> f.id and f2.statut <> 'annulee')
    union all
    select 'client_different', 'erreur', f.id, f.numero,
           'Le colis ' || co.numero || ' appartient à un autre client.'
    from public.facture_lignes l
    join public.factures f on f.id = l.facture_id
    join public.colis co on co.id = l.colis_id
    where co.client_id is distinct from f.client_id
    union all
    select 'total_incoherent', 'erreur', f.id, f.numero,
           'Total ' || f.montant_usd || ' $ ; lignes ' || li.total || ' $ + frais ' || f.frais_service_usd ||
           ' $ = ' || (li.total + f.frais_service_usd) || ' $.'
    from public.factures f join lignes li on li.facture_id = f.id
    where f.statut <> 'annulee' and li.nb_colis > 0 and f.montant_usd <> li.total + f.frais_service_usd
    union all
    select 'paye_depasse_total', 'erreur', f.id, f.numero,
           'Payé ' || coalesce(pa.paye, 0) || ' $ pour un total de ' || f.montant_usd || ' $.'
    from public.factures f left join payes pa on pa.facture_id = f.id
    where coalesce(pa.paye, 0) > f.montant_usd or f.montant_paye_usd > f.montant_usd
    union all
    select 'paye_different_paiements', 'erreur', f.id, f.numero,
           'La facture indique ' || f.montant_paye_usd || ' $ payés, ses paiements font ' ||
           coalesce(pa.paye, 0) || ' $.'
    from public.factures f left join payes pa on pa.facture_id = f.id
    where f.montant_paye_usd <> coalesce(pa.paye, 0)
    union all
    select 'statut_incoherent', 'attention', f.id, f.numero,
           case when f.statut = 'payee' then 'Marquée payée, mais il reste ' ||
                     (f.montant_usd - coalesce(pa.paye, 0)) || ' $ à payer.'
                else 'Marquée à payer, mais entièrement payée.' end
    from public.factures f left join payes pa on pa.facture_id = f.id
    where (f.statut = 'payee' and coalesce(pa.paye, 0) < f.montant_usd)
       or (f.statut = 'a_payer' and f.montant_usd > 0 and coalesce(pa.paye, 0) >= f.montant_usd)
    union all
    select 'paiement_sur_facture_annulee', 'attention', f.id, f.numero,
           pa.paye || ' $ encaissés sur une facture annulée : à rembourser ou à reporter.'
    from public.factures f join payes pa on pa.facture_id = f.id
    where f.statut = 'annulee' and pa.paye > 0
    union all
    select 'frais_absents', 'info', f.id, f.numero,
           'Facture de colis du ' || to_char(f.cree_le, 'DD/MM/YYYY') || ' sans frais de service.'
    from public.factures f join lignes li on li.facture_id = f.id
    where f.statut <> 'annulee' and li.nb_colis > 0 and f.frais_service_usd = 0
      and f.cree_le >= timestamptz '2026-09-22 00:00:00-04'
      and f.cree_le < timestamptz '2026-09-30 00:00:00-04'
    union all
    select 'ligne_sans_colis', 'info', f.id, f.numero,
           'La ligne « ' || l.libelle || ' » (' || l.montant_usd || ' $) n''a plus de colis.'
    from public.facture_lignes l join public.factures f on f.id = l.facture_id
    where l.colis_id is null
    union all
    select 'prix_colis_change', 'info', f.id, f.numero,
           'Le colis ' || co.numero || ' vaut aujourd''hui ' || co.prix_usd || ' $ ; la facture garde ' ||
           l.montant_usd || ' $.'
    from public.facture_lignes l
    join public.factures f on f.id = l.facture_id and f.statut <> 'annulee'
    join public.colis co on co.id = l.colis_id
    where co.prix_usd is not null and co.prix_usd <> l.montant_usd
    union all
    select 'colis_sans_facture', 'info', null, co.numero,
           'Le colis ' || co.numero || ' n''est sur aucune facture active.'
    from public.colis co
    where co.client_id is not null
      and not exists (select 1 from public.facture_lignes l join public.factures f on f.id = l.facture_id
                      where l.colis_id = co.id and f.statut <> 'annulee')
  )
  select coalesce(jsonb_agg(jsonb_build_object('type', a.type, 'gravite', a.gravite, 'facture_id', a.facture_id,
                                               'numero', a.numero, 'detail', a.detail)
                            order by case a.gravite when 'erreur' then 0 when 'attention' then 1 else 2 end,
                                     a.type, a.numero), '[]'::jsonb)
    into r
    from a;
  return r;
end;
$$;


-- 12. Droits ---------------------------------------------------------------------------
-- Le corps des frais n'est ouvert à personne ; les fonctions de service aux comptes
-- connectés, chacune vérifiant sa permission.
revoke execute on function public.facturer_colis_interne(uuid) from public, anon, authenticated;
revoke execute on function public.regles_facture() from public, anon, authenticated;
revoke execute on function public.frais_service_interne(uuid, boolean) from public, anon, authenticated;
revoke execute on function public.creer_facture(uuid, uuid[], jsonb, text) from public, anon;
revoke execute on function public.changer_frais_service(uuid, boolean) from public, anon;
revoke execute on function public.encaisser_facture(uuid, jsonb, boolean, text) from public, anon;
revoke execute on function public.regrouper(uuid[], uuid[], boolean, text) from public, anon;
revoke execute on function public.regrouper_factures(uuid[], text) from public, anon;
revoke execute on function public.colis_a_regrouper(uuid, text, uuid[]) from public, anon;
revoke execute on function public.sortir_du_regroupement(uuid, uuid[], text) from public, anon;
revoke execute on function public.rapport_anomalies_facturation() from public, anon;
grant execute on function public.creer_facture(uuid, uuid[], jsonb, text) to authenticated;
grant execute on function public.changer_frais_service(uuid, boolean) to authenticated;
grant execute on function public.encaisser_facture(uuid, jsonb, boolean, text) to authenticated;
grant execute on function public.regrouper(uuid[], uuid[], boolean, text) to authenticated;
grant execute on function public.regrouper_factures(uuid[], text) to authenticated;
grant execute on function public.colis_a_regrouper(uuid, text, uuid[]) to authenticated;
grant execute on function public.sortir_du_regroupement(uuid, uuid[], text) to authenticated;
grant execute on function public.rapport_anomalies_facturation() to authenticated;


-- 13. Contrôle ---------------------------------------------------------------------------------
-- fonctions : 4 ; ouvertes_aux_visiteurs : false ; frais_a_l_enregistrement : 0.
select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('changer_frais_service', 'encaisser_facture', 'regrouper', 'colis_a_regrouper')) as fonctions,
       (select coalesce(bool_or(has_function_privilege('anon', p.oid, 'execute')), false)
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('changer_frais_service', 'encaisser_facture', 'regrouper', 'colis_a_regrouper',
                            'frais_service_interne'))                                                   as ouvertes_aux_visiteurs,
       (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'facturer_colis_interne'
          and pg_get_functiondef(p.oid) like '%tarifs()%')                                              as frais_a_l_enregistrement;
