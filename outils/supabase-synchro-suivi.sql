-- =============================================================================
-- Goship Express — la synchronisation du suivi externe (Phase 3 du suivi universel, 12/11/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce fichier
-- AJOUTE quatre colonnes, des fonctions et un déclencheur, et en remplace cinq de la
-- Phase 2 (le travailleur, demander_suivi_externe, regler_fournisseur_suivi,
-- etat_fournisseurs_suivi, la liste des transporteurs). Il ne change aucune donnée
-- existante, hormis le nom de transporteur des suivis rangés sous un code 17TRACK que
-- la liste connaît désormais, et peut être relancé autant de fois qu'on veut.
--
-- Ordre d'installation : le dernier de la chaîne (outils/migrations.txt), après
-- supabase-moteur-suivi.sql.
--
-- Pourquoi : en Phase 2, un suivi était inscrit puis lu une fois ; lu aujourd'hui, il
-- restait figé. Chez 17TRACK, LIRE un suivi ne coûte rien (étape B du 12/11/2026 : quota
-- inchangé) ; seule l'inscription d'un numéro compte. Ce fichier relit donc les suivis en
-- cours, sans dépenser, jusqu'à leur fin. Dossier de conception validé par le CEO le
-- 12/11/2026 :
--    · en route, en livraison, incident…   relu toutes les 6 h (17TRACK lui-même ne
--                                           relit le transporteur que toutes les 6 à 12 h) ;
--    · sans premier scan                    relu toutes les 12 h ;
--    · livré par le transporteur            relu une dernière fois 24 h après, puis fin ;
--    · arrivé à Miami (un colis GoShip      fin aussitôt : notre suivi prend le relais ;
--      porte ce numéro)                     un suivi pas encore inscrit ne l'est jamais ;
--    · 30 jours sans nouvel événement       fin, TRACKING_EXPIRED.
--    Pas de webhook (décision du CEO) : la relecture couvre rejeu, doublons, réessais.
--
-- Les pré-alertes suivies automatiquement : un client annonce un achat, son numéro est
-- demandé au moteur comme le ferait l'équipe. Interrupteur suivre_prealertes, ÉTEINT à
-- l'installation ; plafond mensuel (plafond_mensuel) : au-delà, les numéros des
-- pré-alertes attendent le mois suivant sans rien coûter. Le déclencheur ne fait JAMAIS
-- échouer une pré-alerte (l'application mobile installée n'en voit rien) : une erreur
-- va au journal des appels, la pré-alerte est enregistrée comme avant.
--
-- Règles inchangées : aucun lien d'écriture avec les colis, leur historique ou les
-- notifications (« arrivé à Miami » ne fait que LIRE colis.suivi_transporteur) ; rien
-- d'affiché aux clients (Phase 4) ; aucune permission nouvelle ; rien d'ouvert aux
-- visiteurs.
--
-- Contenu :
--    1. garde : la chaîne est-elle à jour ?
--    2. les colonnes
--    3. les transporteurs (SwiftX, SpeedX, YWE) et les suivis rangés sous leur code
--    4. ouvrir un suivi (une seule écriture, pour l'équipe et pour les pré-alertes)
--    5. planifier : relectures et fins
--    6. le travailleur (remplace celui de la Phase 2)
--    7. les pré-alertes : le déclencheur
--    8. réglages et lectures : regler_fournisseur_suivi, etat_fournisseurs_suivi,
--       sante_suivi_externe
--    9. droits
--   10. contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regprocedure('public.traiter_suivis_externes(integer)') is null
     or to_regprocedure('public.suivi17_reponse(bigint, text)') is null
     or to_regclass('public.prealertes') is null then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt), jusqu''à supabase-moteur-suivi.sql, puis ce fichier.';
  end if;
end;
$garde$;


-- 2. Les colonnes -------------------------------------------------------------------
-- L'interrupteur des pré-alertes (éteint) ; le plafond mensuel existe depuis la Phase 1
alter table public.fournisseurs_suivi add column if not exists suivre_prealertes boolean not null default false;
-- D'où vient la demande (l'équipe, une pré-alerte), pourquoi le suivi s'est arrêté, et
-- quand on l'a vu livré pour la première fois (la dernière lecture vient 24 h après)
alter table public.suivis_externes add column if not exists origine text not null default 'equipe';
alter table public.suivis_externes add column if not exists fin_motif text;
alter table public.suivis_externes add column if not exists livre_vu_le timestamptz;

do $contraintes$
begin
  if not exists (select 1 from pg_constraint where conname = 'suivi_externe_synchro_borne') then
    alter table public.suivis_externes add constraint suivi_externe_synchro_borne
      check (origine in ('equipe', 'prealerte')
             and (fin_motif is null or fin_motif in ('LIVRE', 'ARRIVE_MIAMI', 'SILENCE_30J', 'TERMINE')));
  end if;
end
$contraintes$;

-- Les suivis à relire, par date de prochaine lecture
create index if not exists suivis_externes_relecture_idx
  on public.suivis_externes (prochaine_synchro_le) where etape = 'lecture';
create index if not exists suivis_externes_origine_idx
  on public.suivis_externes (origine, inscription_demandee_le);


-- 3. Les transporteurs ------------------------------------------------------------------
-- La liste de la Phase 2, plus les trois livreurs que l'essai réel du 12/11/2026 a trouvés
-- à Miami : SwiftX (101228), SpeedX (190844), YWE (191278).
create or replace function public.transporteurs_connus()
returns table (code text, nom text, code_17track integer)
language sql
immutable
set search_path = ''
as $$
  values ('ups', 'UPS', 100002), ('usps', 'USPS', 21051), ('fedex', 'FedEx', 100003),
         ('dhl', 'DHL Express', 100001), ('dhl_ecommerce', 'DHL eCommerce US', 7047),
         ('ontrac', 'OnTrac', 100049), ('lasership', 'LaserShip', 100052),
         ('amazon', 'Amazon Logistics', null::integer), ('amazon_shipping', 'Amazon Shipping', 101392),
         ('yunexpress', 'YunExpress', 190008), ('yanwen', 'Yanwen', 190012), ('cainiao', 'Cainiao', 190271),
         ('4px', '4PX', 190094), ('jt', 'J&T', 100295), ('gofo', 'GOFO', 100996),
         ('swiftx', 'SwiftX', 101228), ('speedx', 'SpeedX', 190844), ('ywe', 'YWE', 191278)
$$;

-- Les suivis déjà rangés sous « 17track-<code> » d'un transporteur que la liste nomme
-- désormais prennent son nom. Une relance ne change plus rien.
update public.suivis_externes
   set transporteur = public.suivi17_transporteur(transporteur_fournisseur)
 where transporteur like '17track-%'
   and transporteur_fournisseur is not null
   and public.suivi17_transporteur(transporteur_fournisseur) not like '17track-%';


-- 4. Ouvrir un suivi ---------------------------------------------------------------------
-- La seule écriture d'un nouveau suivi, pour l'équipe (demander_suivi_externe) comme pour
-- les pré-alertes (déclencheur) : les mêmes règles des deux côtés. Rend l'id du suivi
-- (nouveau ou déjà là), ou NULL quand le numéro n'est pas un suivi de transporteur que
-- 17TRACK accepte (hors limites, colis GoShip). Rien n'est appelé ici.
create or replace function public.suivi_externe_ouvrir(p_numero text, p_transporteur text, p_origine text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_numero text := public.normaliser_numero_suivi(p_numero);
  v_nature text := public.nature_numero(p_numero);
  v_fournisseur public.fournisseurs_suivi;
  v_exclus text[];
  v_transporteur text;
  v_id uuid;
begin
  if v_numero !~ '^[A-Z0-9-]{5,50}$' or v_nature = 'goship' then
    return null;
  end if;
  select id into v_id from public.suivis_externes where numero = v_numero;
  if found then
    return v_id;
  end if;
  select * into v_fournisseur from public.fournisseurs_suivi where actif or essai limit 1;
  v_exclus := coalesce(v_fournisseur.transporteurs_exclus, array['usps']);
  v_transporteur := coalesce(p_transporteur, public.detecter_transporteur(v_numero));
  insert into public.suivis_externes
    (numero, numero_original, transporteur, transporteur_source, fournisseur, etat, etape, code_resultat,
     derniere_erreur, demande_par, origine)
  values (v_numero, left(btrim(coalesce(p_numero, '')), 120), v_transporteur,
          case when p_transporteur is not null then 'equipe' when v_transporteur is not null then 'numero' end,
          v_fournisseur.code,
          case when v_nature = 'commande_amazon' or v_transporteur = any (v_exclus) then 'arrete' else 'en_attente' end,
          case when v_nature = 'commande_amazon' or v_transporteur = any (v_exclus) then 'fini' else 'inscription' end,
          case when v_nature = 'commande_amazon' then 'ORDER_NUMBER_DETECTED'
               when v_transporteur = any (v_exclus) then 'UNSUPPORTED_TRACKING' end,
          case when coalesce(v_nature, '') <> 'commande_amazon' and v_transporteur = any (v_exclus)
               then 'TRANSPORTEUR_EXCLU' end,
          -- Qui a demandé : un compte de l'équipe ; jamais le client d'une pré-alerte
          case when p_origine = 'equipe' then auth.uid() end,
          p_origine)
  on conflict (numero) do nothing
  returning id into v_id;
  if v_id is null then
    select id into v_id from public.suivis_externes where numero = v_numero;
  end if;
  return v_id;
end;
$$;

-- Demander le suivi d'un numéro (même forme et mêmes règles qu'en Phase 2 ; le nouveau
-- suivi passe par suivi_externe_ouvrir)
create or replace function public.demander_suivi_externe(p_numero text, p_transporteur text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_numero text := public.normaliser_numero_suivi(p_numero);
  v_nature text := public.nature_numero(p_numero);
  v_fournisseur public.fournisseurs_suivi;
  v_exclus text[];
  s public.suivis_externes;
begin
  perform public.exiger_permission('tracking.manage');
  if v_numero = '' then
    perform public.erreur_metier('TRACKING_REQUIRED', 'Entrez le numéro de suivi fourni par le transporteur.');
  end if;
  if p_transporteur is not null
     and not exists (select 1 from public.transporteurs_connus() t where t.code = p_transporteur) then
    perform public.erreur_metier('CARRIER_INVALID', 'Transporteur inconnu : choisissez-le dans la liste.');
  end if;
  if v_nature = 'goship' then
    perform public.erreur_metier('GOSHIP_NUMBER', 'C''est le numéro d''un colis GoShip : son suivi est déjà le nôtre.');
  end if;
  -- Hors des limites de 17TRACK (5 à 50 lettres, chiffres ou tirets) : rien n'est rangé
  -- ni envoyé. Ce n'est pas un jugement sur le numéro, c'est la limite du fournisseur.
  if v_numero !~ '^[A-Z0-9-]{5,50}$' then
    return jsonb_build_object('numero', v_numero, 'code_resultat', 'UNSUPPORTED_TRACKING', 'enregistre', false);
  end if;

  select * into v_fournisseur from public.fournisseurs_suivi where actif or essai limit 1;
  v_exclus := coalesce(v_fournisseur.transporteurs_exclus, array['usps']);

  select * into s from public.suivis_externes where numero = v_numero for update;
  if found then
    -- Déjà suivi : jamais une seconde demande pour le même numéro, sauf un choix de
    -- transporteur de l'équipe qui change quelque chose.
    if p_transporteur is null or p_transporteur is not distinct from s.transporteur
       or s.code_resultat = 'ORDER_NUMBER_DETECTED' then
      return public.suivi_externe(v_numero) || jsonb_build_object('deja', true);
    end if;
    if s.requete is not null then
      perform public.erreur_metier('TRACKING_BUSY', 'Ce numéro est en cours chez le fournisseur : réessayez dans une minute.');
    end if;
    if p_transporteur = any (v_exclus) then
      update public.suivis_externes
         set transporteur = p_transporteur, transporteur_source = 'equipe', etat = 'arrete', etape = 'fini',
             code_resultat = 'UNSUPPORTED_TRACKING', derniere_erreur = 'TRANSPORTEUR_EXCLU'
       where id = s.id;
    elsif s.inscrit_le is null then
      -- Pas encore inscrit (refusé, transporteur inconnu…) : on recommence avec ce transporteur
      update public.suivis_externes
         set transporteur = p_transporteur, transporteur_source = 'equipe', etat = 'en_attente',
             etape = 'inscription', code_resultat = null, derniere_erreur = null, tentatives = 0,
             prochaine_synchro_le = null, fin_motif = null, fournisseur = coalesce(v_fournisseur.code, fournisseur)
       where id = s.id;
    elsif public.suivi17_code(p_transporteur) is null then
      perform public.erreur_metier('CARRIER_INVALID', 'Ce transporteur ne se choisit pas pour un numéro déjà inscrit.');
    else
      -- Déjà inscrit : un changement de transporteur, qui coûte un numéro de plus
      update public.suivis_externes
         set transporteur = p_transporteur, transporteur_source = 'equipe', etat = 'en_attente',
             etape = 'changement', code_resultat = null, derniere_erreur = null, tentatives = 0,
             prochaine_synchro_le = null, fin_motif = null
       where id = s.id;
    end if;
    return public.suivi_externe(v_numero);
  end if;

  perform public.suivi_externe_ouvrir(p_numero, p_transporteur, 'equipe');
  return public.suivi_externe(v_numero);
end;
$$;


-- 5. Planifier : relectures et fins ---------------------------------------------------------
-- Chaque minute, avant les envois. Ne touche que les suivis sans fin (fin_motif vide) et
-- sans demande en cours ; rien n'est appelé ici. Rend le nombre de suivis replanifiés
-- et terminés.
create or replace function public.planifier_suivis_externes()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_arrives integer;
  v_livres integer;
  v_termines integer;
  v_muets integer;
  v_relus integer;
begin
  -- 1. Arrivé à Miami : un colis GoShip porte ce numéro de suivi (colis.suivi_transporteur,
  --    rangé en majuscules par regles_colis ; on ne fait que le LIRE). Un suivi pas encore
  --    inscrit ne l'est jamais : rien n'est dépensé pour un colis déjà chez nous.
  with fins as (
    update public.suivis_externes s
       set fin_motif = 'ARRIVE_MIAMI', etape = 'fini',
           etat = case when s.inscrit_le is null then 'arrete' else 'actif' end,
           prochaine_synchro_le = null
     where s.fin_motif is null and s.requete is null and s.etape <> 'changement'
       and s.etat in ('en_attente', 'actif')
       and exists (select 1 from public.colis c where c.suivi_transporteur = s.numero)
    returning 1)
  select count(*) into v_arrives from fins;

  -- 2. Livré par le transporteur : une dernière lecture 24 h après l'avoir vu livré, puis fin
  with relire as (
    update public.suivis_externes s
       set livre_vu_le = now(), etape = 'lecture', prochaine_synchro_le = now() + interval '24 hours'
     where s.fin_motif is null and s.etat = 'actif' and s.etape = 'fini' and s.requete is null
       and s.statut = 'DELIVERED' and s.livre_vu_le is null
    returning 1)
  select count(*) into v_livres from relire;
  with fins as (
    update public.suivis_externes s
       set fin_motif = 'LIVRE'
     where s.fin_motif is null and s.etat = 'actif' and s.etape = 'fini' and s.requete is null
       and s.statut = 'DELIVERED' and s.livre_vu_le is not null
    returning 1)
  select v_livres + count(*) into v_livres from fins;

  -- 3. Terminé chez le transporteur : retourné, expiré, numéro invalide
  with fins as (
    update public.suivis_externes s
       set fin_motif = 'TERMINE'
     where s.fin_motif is null and s.etape = 'fini' and s.requete is null
       and (s.etat in ('arrete', 'erreur')
            or (s.etat = 'actif' and (s.statut in ('RETURNED', 'EXPIRED')
                                      or s.code_resultat in ('TRACKING_EXPIRED', 'INVALID_TRACKING'))))
    returning 1)
  select count(*) into v_termines from fins;

  -- 4. 30 jours sans nouvel événement : 17TRACK s'arrête lui aussi
  with fins as (
    update public.suivis_externes s
       set fin_motif = 'SILENCE_30J', code_resultat = 'TRACKING_EXPIRED'
     where s.fin_motif is null and s.etat = 'actif' and s.etape = 'fini' and s.requete is null
       and coalesce(s.dernier_evenement_le, s.inscrit_le, s.cree_le) < now() - interval '30 days'
    returning 1)
  select count(*) into v_muets from fins;

  -- 5. Les autres suivis en cours : relus dans 6 h (12 h sans premier scan), gratuitement
  with relire as (
    update public.suivis_externes s
       set etape = 'lecture',
           prochaine_synchro_le = coalesce(s.derniere_synchro_le, now())
             + case when s.statut is null or s.statut in ('PENDING', 'INFO_RECEIVED', 'NOT_FOUND')
                         or s.code_resultat = 'PENDING_FIRST_SCAN'
                    then interval '12 hours' else interval '6 hours' end
     where s.fin_motif is null and s.etat = 'actif' and s.etape = 'fini' and s.requete is null
    returning 1)
  select count(*) into v_relus from relire;

  return jsonb_build_object('arrives', v_arrives, 'livres', v_livres, 'termines', v_termines,
                            'silence', v_muets, 'replanifies', v_relus);
end;
$$;


-- 6. Le travailleur ---------------------------------------------------------------------------
-- Celui de la Phase 2, plus : la planification (partie 5) avant les envois, la relecture des
-- suivis en cours (etat « actif », gratuite), et le plafond mensuel des pré-alertes à
-- l'inscription. Au plus 3 requêtes par passage, 40 numéros par requête.
create or replace function public.traiter_suivis_externes(p_lot integer default 40)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_lot integer := least(greatest(coalesce(p_lot, 40), 1), 40);
  f public.fournisseurs_suivi;
  q record;
  v_cle text;
  v_entetes jsonb;
  v_ids uuid[];
  v_ids_prealertes uuid[];
  v_requete bigint;
  v_permis integer;
  v_mois integer;
  v_planif jsonb;
  v_reponses integer := 0;
  v_lectures integer := 0;
  v_inscriptions integer := 0;
  v_changements integer := 0;
  v_quota boolean := false;
  v_url text := 'https://api.17track.net/track/v2.4/';
begin
  -- 1. Les réponses
  for q in select distinct requete, etape from public.suivis_externes where requete is not null loop
    if public.suivi17_reponse(q.requete, q.etape) <> 'attente' then
      v_reponses := v_reponses + 1;
    end if;
  end loop;
  for q in select code from public.fournisseurs_suivi where quota_requete is not null loop
    perform public.suivi17_quota_reponse(q.code);
  end loop;

  -- 2. Relectures et fins (rien n'est appelé)
  v_planif := public.planifier_suivis_externes();

  -- 3. Les envois
  select * into f from public.fournisseurs_suivi where actif or essai limit 1 for update;
  if not found then
    return jsonb_build_object('en_service', false, 'reponses', v_reponses, 'planification', v_planif);
  end if;
  if f.code <> '17track' then
    return jsonb_build_object('en_service', true, 'adaptateur', false, 'reponses', v_reponses);
  end if;
  v_cle := coalesce(public.lire_reglage('suivi_17track_cle'), '');
  if v_cle = '' then
    return jsonb_build_object('en_service', true, 'cle', false, 'reponses', v_reponses);
  end if;
  v_entetes := jsonb_build_object('17token', v_cle, 'Content-Type', 'application/json');

  -- Le quota, relu avant tout lot qui coûte (et au plus une fois l'heure sinon)
  if f.quota_requete is null and (f.quota_lu_le is null or f.quota_lu_le < now() - interval '1 hour') then
    select net.http_post(url := v_url || 'getquota', body := '[]'::jsonb, headers := v_entetes,
                         timeout_milliseconds := 10000) into v_requete;
    update public.fournisseurs_suivi set quota_requete = v_requete, maj_le = now() where code = f.code;
    v_quota := true;
  end if;

  -- Les lectures, premières et relectures (gratuites)
  select array_agg(id) into v_ids from (
    select id from public.suivis_externes
     where fournisseur = f.code and etat in ('en_attente', 'actif') and etape = 'lecture' and requete is null
       and (prochaine_synchro_le is null or prochaine_synchro_le <= now())
     order by prochaine_synchro_le nulls first, cree_le
     limit v_lot for update skip locked) x;
  if v_ids is not null then
    select net.http_post(url := v_url || 'gettrackinfo', body := public.suivi17_corps(v_ids, 'lecture'),
                         headers := v_entetes, timeout_milliseconds := 10000) into v_requete;
    update public.suivis_externes set requete = v_requete, requete_le = now() where id = any (v_ids);
    v_lectures := cardinality(v_ids);
  end if;

  -- Ce qui coûte : seulement avec un quota frais, sous le plafond et au-dessus de la marge
  if not v_quota and f.quota_requete is null and f.quota_lu_le is not null then
    if coalesce(f.quota_restant, 0) <= f.marge_quota then
      perform public.suivi_externe_arreter(f.code, 'QUOTA_MARGE');
      return jsonb_build_object('en_service', false, 'arret', 'QUOTA_MARGE', 'reponses', v_reponses,
                                'lectures', v_lectures);
    end if;
    v_permis := least(v_lot, f.quota_restant - f.marge_quota);
    if f.essai and not f.actif then
      v_permis := least(v_permis, f.plafond_essai - public.suivi_externe_consommes(f.code));
    end if;

    if v_permis > 0 then
      -- Les demandes de l'équipe d'abord
      v_ids := null;
      select array_agg(id) into v_ids from (
        select id from public.suivis_externes
         where (fournisseur is null or fournisseur = f.code) and etat = 'en_attente' and etape = 'inscription'
           and origine = 'equipe' and requete is null
           and (prochaine_synchro_le is null or prochaine_synchro_le <= now())
           and not (coalesce(transporteur, '') = any (f.transporteurs_exclus))
         order by cree_le
         limit v_permis for update skip locked) x;
      -- Puis celles des pré-alertes, dans le plafond du mois (jours de Santo Domingo).
      -- Au-delà, elles attendent le mois suivant sans rien coûter.
      select count(*) into v_mois from public.suivis_externes
       where origine = 'prealerte' and fournisseur = f.code
         and inscription_demandee_le >= (date_trunc('month', now() at time zone 'America/Santo_Domingo')
                                         at time zone 'America/Santo_Domingo');
      v_ids_prealertes := null;
      select array_agg(id) into v_ids_prealertes from (
        select id from public.suivis_externes
         where (fournisseur is null or fournisseur = f.code) and etat = 'en_attente' and etape = 'inscription'
           and origine = 'prealerte' and requete is null
           and (prochaine_synchro_le is null or prochaine_synchro_le <= now())
           and not (coalesce(transporteur, '') = any (f.transporteurs_exclus))
         order by cree_le
         limit greatest(0, least(v_permis - coalesce(cardinality(v_ids), 0),
                                 coalesce(f.plafond_mensuel, 0) - v_mois))
         for update skip locked) x;
      v_ids := coalesce(v_ids, array[]::uuid[]) || coalesce(v_ids_prealertes, array[]::uuid[]);
      if cardinality(v_ids) > 0 then
        select net.http_post(url := v_url || 'register', body := public.suivi17_corps(v_ids, 'inscription'),
                             headers := v_entetes, timeout_milliseconds := 10000) into v_requete;
        update public.suivis_externes
           set requete = v_requete, requete_le = now(), fournisseur = f.code,
               inscription_demandee_le = coalesce(inscription_demandee_le, now())
         where id = any (v_ids);
        v_inscriptions := cardinality(v_ids);
        v_permis := v_permis - v_inscriptions;
      end if;
    end if;

    if v_permis > 0 then
      v_ids := null;
      select array_agg(id) into v_ids from (
        select id from public.suivis_externes
         where fournisseur = f.code and etat = 'en_attente' and etape = 'changement' and requete is null
           and (prochaine_synchro_le is null or prochaine_synchro_le <= now())
         order by cree_le
         limit v_permis for update skip locked) x;
      if v_ids is not null then
        select net.http_post(url := v_url || 'changecarrier', body := public.suivi17_corps(v_ids, 'changement'),
                             headers := v_entetes, timeout_milliseconds := 10000) into v_requete;
        -- Un changement compte une fois, à l'envoi (un réessai ne le recompte pas)
        update public.suivis_externes
           set requete = v_requete, requete_le = now(),
               changements = changements + case when tentatives = 0 then 1 else 0 end
         where id = any (v_ids);
        v_changements := cardinality(v_ids);
      end if;
    end if;

    -- Après un lot qui coûte, le quota sera relu avant le suivant
    if v_inscriptions + v_changements > 0 then
      update public.fournisseurs_suivi set quota_lu_le = null where code = f.code;
    end if;
  end if;

  return jsonb_build_object('en_service', true, 'reponses', v_reponses, 'quota_demande', v_quota,
                            'lectures', v_lectures, 'inscriptions', v_inscriptions, 'changements', v_changements,
                            'planification', v_planif);
end;
$$;


-- 7. Les pré-alertes ------------------------------------------------------------------------
-- Après l'enregistrement d'une pré-alerte en attente, si l'interrupteur est allumé : son
-- numéro est demandé au moteur (suivi_externe_ouvrir) et la pré-alerte y est reliée. Deux
-- clients qui annoncent le même numéro partagent un seul suivi. Rien n'est appelé ici ; le
-- travailleur l'inscrira dans le plafond du mois. Ce déclencheur ne fait JAMAIS échouer la
-- pré-alerte : une erreur est écrite au journal des appels (son code, jamais de donnée du
-- client), et la pré-alerte est enregistrée comme avant.
create or replace function public.suivre_prealerte()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if new.statut <> 'attente' or coalesce(new.suivi_transporteur, '') = ''
     or not exists (select 1 from public.fournisseurs_suivi where (actif or essai) and suivre_prealertes) then
    return null;
  end if;
  begin
    v_id := public.suivi_externe_ouvrir(new.suivi_transporteur, null, 'prealerte');
    if v_id is not null then
      update public.prealertes set suivi_externe_id = v_id where id = new.id and suivi_externe_id is null;
    end if;
  exception when others then
    begin
      insert into public.suivis_externes_journal (operation, resultat, code_erreur)
      values ('prealerte', 'erreur', left('SQLSTATE_' || sqlstate, 60));
    exception when others then
      null;
    end;
  end;
  return null;
end;
$$;

drop trigger if exists suivre_prealerte on public.prealertes;
create trigger suivre_prealerte
  after insert on public.prealertes
  for each row execute function public.suivre_prealerte();


-- 8. Réglages et lectures ---------------------------------------------------------------------
-- Régler un fournisseur (Phase 2), avec l'interrupteur des pré-alertes en plus. Journalisé.
create or replace function public.regler_fournisseur_suivi(p_code text, p_champs jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_avant public.fournisseurs_suivi;
  v_apres public.fournisseurs_suivi;
  v_cle text;
begin
  perform public.exiger_permission('tracking.manage');
  select * into v_avant from public.fournisseurs_suivi where code = p_code for update;
  if not found then
    perform public.erreur_metier('PROVIDER_UNKNOWN', 'Fournisseur de suivi inconnu.');
  end if;
  for v_cle in select jsonb_object_keys(coalesce(p_champs, '{}'::jsonb)) loop
    if v_cle not in ('essai', 'actif', 'conformite', 'plafond_essai', 'marge_quota', 'plafond_mensuel',
                     'note', 'transporteurs_exclus', 'suivre_prealertes') then
      perform public.erreur_metier('FIELD_NOT_ALLOWED', 'Réglage inconnu : ' || v_cle || '.');
    end if;
  end loop;
  v_apres := v_avant;
  v_apres.essai := coalesce((p_champs ->> 'essai')::boolean, v_avant.essai);
  v_apres.actif := coalesce((p_champs ->> 'actif')::boolean, v_avant.actif);
  v_apres.conformite := coalesce(p_champs ->> 'conformite', v_avant.conformite);
  v_apres.plafond_essai := coalesce((p_champs ->> 'plafond_essai')::integer, v_avant.plafond_essai);
  v_apres.marge_quota := coalesce((p_champs ->> 'marge_quota')::integer, v_avant.marge_quota);
  v_apres.plafond_mensuel := case when p_champs ? 'plafond_mensuel' then (p_champs ->> 'plafond_mensuel')::integer
                                  else v_avant.plafond_mensuel end;
  v_apres.note := coalesce(left(p_champs ->> 'note', 500), v_avant.note);
  v_apres.suivre_prealertes := coalesce((p_champs ->> 'suivre_prealertes')::boolean, v_avant.suivre_prealertes);
  if p_champs ? 'transporteurs_exclus' then
    select coalesce(array_agg(x order by x), array[]::text[]) into v_apres.transporteurs_exclus
      from jsonb_array_elements_text(p_champs -> 'transporteurs_exclus') x;
  end if;
  if v_apres.actif and v_apres.conformite <> 'VERIFIED' then
    perform public.erreur_metier('PROVIDER_NOT_VERIFIED',
      'Un fournisseur ne peut être actif que s''il est vérifié (VERIFIED) : utilisez l''essai.');
  end if;
  if v_apres.essai and v_apres.conformite not in ('VERIFIED', 'PENDING_VERIFICATION') then
    perform public.erreur_metier('PROVIDER_NOT_VERIFIED',
      'L''essai demande un fournisseur vérifié ou en cours de vérification.');
  end if;
  if (v_apres.actif or v_apres.essai)
     and exists (select 1 from public.fournisseurs_suivi where code <> p_code and (actif or essai)) then
    perform public.erreur_metier('PROVIDER_IN_SERVICE', 'Un autre fournisseur est déjà en service : arrêtez-le d''abord.');
  end if;
  -- Suivre les pré-alertes sans plafond du mois reviendrait à ne rien suivre : on le dit
  if v_apres.suivre_prealertes and coalesce(v_apres.plafond_mensuel, 0) <= 0 then
    perform public.erreur_metier('MONTHLY_CAP_REQUIRED',
      'Fixez d''abord un plafond mensuel (plafond_mensuel) pour suivre les pré-alertes.');
  end if;
  update public.fournisseurs_suivi
     set essai = v_apres.essai, actif = v_apres.actif, conformite = v_apres.conformite,
         plafond_essai = v_apres.plafond_essai, marge_quota = v_apres.marge_quota,
         plafond_mensuel = v_apres.plafond_mensuel, note = v_apres.note,
         transporteurs_exclus = v_apres.transporteurs_exclus, suivre_prealertes = v_apres.suivre_prealertes,
         -- Remis en service : le motif de l'arrêt s'efface, et le quota sera relu d'abord
         arret_motif = case when (v_apres.actif or v_apres.essai) then null else arret_motif end,
         quota_lu_le = case when (v_apres.actif or v_apres.essai) and not (v_avant.actif or v_avant.essai)
                            then null else quota_lu_le end,
         maj_le = now()
   where code = p_code;
  perform public.auditer('fournisseur_suivi.reglage', 'fournisseur_suivi', p_code,
                         to_jsonb(v_avant) - 'quota_requete', to_jsonb(v_apres) - 'quota_requete');
  return public.etat_fournisseurs_suivi();
end;
$$;

-- Les fournisseurs (mêmes clés qu'en Phase 2, plus l'interrupteur et le compte du mois)
create or replace function public.etat_fournisseurs_suivi()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('tracking.view');
  return coalesce((
    select jsonb_agg(jsonb_build_object('code', f.code, 'nom', f.nom, 'conformite', f.conformite,
                                        'actif', f.actif, 'essai', f.essai, 'plafond_mensuel', f.plafond_mensuel,
                                        'plafond_essai', f.plafond_essai, 'marge_quota', f.marge_quota,
                                        'consommes', public.suivi_externe_consommes(f.code),
                                        'quota_restant', f.quota_restant, 'quota_lu_le', f.quota_lu_le,
                                        'arret_motif', f.arret_motif, 'transporteurs_exclus', to_jsonb(f.transporteurs_exclus),
                                        'suivre_prealertes', f.suivre_prealertes,
                                        'prealertes_ce_mois', (select count(*) from public.suivis_externes s
                                           where s.fournisseur = f.code and s.origine = 'prealerte'
                                             and s.inscription_demandee_le >= (date_trunc('month', now() at time zone 'America/Santo_Domingo')
                                                                               at time zone 'America/Santo_Domingo')),
                                        'note', f.note, 'maj_le', f.maj_le)
                     order by f.code)
      from public.fournisseurs_suivi f), '[]'::jsonb);
end;
$$;

-- La santé du suivi externe, pour l'équipe (l'écran viendra en Phase 6) : les mêmes chiffres
-- que le contrôle de production. Aucune donnée client, aucune clé.
create or replace function public.sante_suivi_externe()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  f public.fournisseurs_suivi;
begin
  perform public.exiger_permission('tracking.view');
  select * into f from public.fournisseurs_suivi where actif or essai limit 1;
  return jsonb_build_object(
    'en_service', f.code is not null,
    'fournisseur', f.code,
    'quota_restant', f.quota_restant,
    'quota_lu_le', f.quota_lu_le,
    'arrets', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'motif', arret_motif)), '[]'::jsonb)
                 from public.fournisseurs_suivi where arret_motif is not null and not (actif or essai)),
    'en_cours', (select count(*) from public.suivis_externes where fin_motif is null and etat in ('en_attente', 'actif')),
    'a_relire', (select count(*) from public.suivis_externes where etape = 'lecture' and requete is null),
    'en_retard', (select count(*) from public.suivis_externes
                   where f.code is not null and etape = 'lecture' and requete is null
                     and prochaine_synchro_le < now() - interval '2 hours'),
    'erreurs_24h', (select count(*) from public.suivis_externes_journal
                     where resultat <> 'ok' and cree_le > now() - interval '24 hours'),
    'derniere_lecture_ok', (select max(cree_le) from public.suivis_externes_journal
                             where operation = 'lecture' and resultat = 'ok'));
end;
$$;


-- 9. Droits --------------------------------------------------------------------------------
revoke execute on function public.transporteurs_connus() from public, anon, authenticated;
revoke execute on function public.suivi_externe_ouvrir(text, text, text) from public, anon, authenticated;
revoke execute on function public.planifier_suivis_externes() from public, anon, authenticated;
revoke execute on function public.traiter_suivis_externes(integer) from public, anon, authenticated;
revoke execute on function public.suivre_prealerte() from public, anon, authenticated;
revoke execute on function public.demander_suivi_externe(text, text) from public, anon;
revoke execute on function public.regler_fournisseur_suivi(text, jsonb) from public, anon;
revoke execute on function public.etat_fournisseurs_suivi() from public, anon;
revoke execute on function public.sante_suivi_externe() from public, anon;
grant execute on function public.demander_suivi_externe(text, text) to authenticated;
grant execute on function public.regler_fournisseur_suivi(text, jsonb) to authenticated;
grant execute on function public.etat_fournisseurs_suivi() to authenticated;
grant execute on function public.sante_suivi_externe() to authenticated;
grant execute on function public.traiter_suivis_externes(integer) to service_role;


-- 10. Contrôle -------------------------------------------------------------------------------
-- colonnes : 4 ; pre_alertes_suivies : 0 (l'interrupteur est éteint) ; declencheur : 1 ;
-- ouverte_aux_visiteurs : false ; transporteurs : 18
select (select count(*) from information_schema.columns
         where table_schema = 'public'
           and ((table_name = 'fournisseurs_suivi' and column_name = 'suivre_prealertes')
             or (table_name = 'suivis_externes' and column_name in ('origine', 'fin_motif', 'livre_vu_le')))) as colonnes,
       (select count(*) from public.fournisseurs_suivi where suivre_prealertes) as pre_alertes_suivies,
       (select count(*) from pg_trigger where tgname = 'suivre_prealerte' and not tgisinternal) as declencheur,
       has_function_privilege('anon', 'public.sante_suivi_externe()', 'execute')
         or has_function_privilege('anon', 'public.planifier_suivis_externes()', 'execute')
         or has_function_privilege('anon', 'public.suivi_externe_ouvrir(text, text, text)', 'execute') as ouverte_aux_visiteurs,
       (select count(*) from public.transporteurs_connus()) as transporteurs;
