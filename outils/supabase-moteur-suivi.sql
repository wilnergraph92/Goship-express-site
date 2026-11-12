-- =============================================================================
-- Goship Express — le moteur du suivi externe (Phase 2 du suivi universel, 12/11/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce fichier
-- AJOUTE des colonnes vides aux tables de la Phase 1, des fonctions et une tâche
-- planifiée. Il ne change aucune donnée existante, ne touche ni aux colis, ni à leur
-- historique, ni aux notifications, et peut être relancé autant de fois qu'on veut.
-- Tant qu'aucun fournisseur n'est mis « en essai » ou « actif », il n'appelle
-- PERSONNE : la tâche planifiée tourne à vide.
--
-- Ordre d'installation : le dernier de la chaîne (outils/migrations.txt), après
-- supabase-suivi-externe.sql, dont il remplit les tables.
--
-- Pourquoi : la Phase 1 a préparé les tiroirs (suivis_externes, leurs événements,
-- le journal des appels, les fournisseurs). Ce fichier est le moteur qui les
-- remplit, selon le dossier de conception validé par le CEO le 12/11/2026 :
--    · l'équipe demande le suivi d'un numéro de vendeur (demander_suivi_externe,
--      tracking.manage) ;
--    · le travailleur (traiter_suivis_externes, chaque minute) l'inscrit chez le
--      fournisseur en service, puis lit sa réponse ;
--    · l'adaptateur 17TRACK (fonctions suivi17_*) est le SEUL endroit qui connaît
--      17TRACK : forme des requêtes, codes de transporteurs et d'erreurs, statuts.
--      Ajouter AfterShip, ce sera ajouter un adaptateur, sans toucher au reste.
--    Même chemin que les e-mails : pg_net envoie, la minute suivante lit la
--    réponse, la clé dort dans le coffre (Vault). Ni serveur, ni Edge Function.
--
-- Règles, et pourquoi :
--    · Un fournisseur non « VERIFIED » ne peut pas être ACTIF (Phase 1). La Phase 2
--      ajoute l'ESSAI : permis à un fournisseur « VERIFIED » ou « PENDING_VERIFICATION »,
--      plafonné (plafond_essai), et rien n'en sort vers un client. Un seul fournisseur
--      en service à la fois : jamais de bascule silencieuse vers un autre.
--    · Le quota se tient DANS la base, avant l'appel : chaque numéro envoyé à
--      l'inscription compte, qu'il soit accepté ou refusé (on ne sait pas si un refus
--      coûte : on compte large). Le quota réel est relu chez le fournisseur avant
--      chaque lot qui coûte ; sous la marge, le fournisseur s'arrête tout seul.
--      Quota épuisé ou clé refusée : arrêt, jamais de bascule.
--    · Rien d'un client ne part chez le fournisseur : la requête ne porte que le
--      numéro et, s'il est connu, le code du transporteur. Rien de ce que le
--      fournisseur rend sur le destinataire n'est rangé : ni adresse, ni rue, ni
--      coordonnées, ni référence client (shipping_info et misc_info sont ignorés).
--    · Un statut inconnu reste VIDE, jamais « DELIVERED » ; une date de livraison
--      n'est gardée que si elle vient du transporteur lui-même (source Official) et
--      tient en un jour : GoShip n'estime jamais.
--    · Aucun lien avec colis.statut, colis_historique ni les notifications : un
--      « livré » du transporteur reste un fait du transporteur.
--    · Phase 2 seulement : le moteur lit un suivi une fois inscrit (et redemande
--      deux fois s'il n'y a pas encore de premier scan). La mise à jour régulière et
--      les webhooks sont la Phase 3.
--
-- Contenu :
--    1. garde : la chaîne est-elle à jour ?
--    2. les colonnes, contraintes et index
--    3. la détection : transporteur prouvé par le numéro, numéro de commande
--    4. l'adaptateur 17TRACK
--    5. l'orchestrateur : demander un suivi, régler un fournisseur, les lectures
--    6. le travailleur et sa tâche planifiée
--    7. droits
--    8. contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regclass('public.suivis_externes') is null
     or to_regprocedure('public.etat_fournisseurs_suivi()') is null
     or to_regprocedure('public.auditer(text, text, text, jsonb, jsonb)') is null
     or to_regprocedure('public.lire_reglage(text)') is null then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt), jusqu''à supabase-suivi-externe.sql, puis ce fichier.';
  end if;
end;
$garde$;


-- 2. Les colonnes, contraintes et index ------------------------------------------------
-- Le fournisseur : l'essai, son plafond, la marge gardée sur le quota réel, le dernier
-- quota lu, la demande de quota en cours, et pourquoi il s'est arrêté seul.
alter table public.fournisseurs_suivi add column if not exists essai boolean not null default false;
alter table public.fournisseurs_suivi add column if not exists plafond_essai integer not null default 0;
alter table public.fournisseurs_suivi add column if not exists marge_quota integer not null default 20;
alter table public.fournisseurs_suivi add column if not exists quota_restant integer;
alter table public.fournisseurs_suivi add column if not exists quota_lu_le timestamptz;
alter table public.fournisseurs_suivi add column if not exists quota_requete bigint;
alter table public.fournisseurs_suivi add column if not exists arret_motif text;
-- Les transporteurs qu'on ne lui envoie pas. USPS d'office : depuis avril 2026, USPS lie
-- chaque recherche à un expéditeur vérifié, que GoShip n'est pas (décision du 12/11/2026).
alter table public.fournisseurs_suivi add column if not exists transporteurs_exclus text[] not null default array['usps'];

-- Le suivi : le numéro tel que saisi, l'inscription chez le fournisseur et ce qu'il a dit
-- du transporteur, l'étape du moteur, la demande en cours, les essais, qui l'a demandé.
alter table public.suivis_externes add column if not exists numero_original text;
alter table public.suivis_externes add column if not exists inscription_demandee_le timestamptz;
alter table public.suivis_externes add column if not exists inscrit_le timestamptz;
alter table public.suivis_externes add column if not exists transporteur_fournisseur integer;
alter table public.suivis_externes add column if not exists transporteur_origine text;
alter table public.suivis_externes add column if not exists etape text not null default 'inscription';
alter table public.suivis_externes add column if not exists requete bigint;
alter table public.suivis_externes add column if not exists requete_le timestamptz;
alter table public.suivis_externes add column if not exists tentatives integer not null default 0;
alter table public.suivis_externes add column if not exists lectures integer not null default 0;
alter table public.suivis_externes add column if not exists changements integer not null default 0;
alter table public.suivis_externes add column if not exists derniere_erreur text;
alter table public.suivis_externes add column if not exists demande_par uuid;

do $contraintes$
begin
  -- L'essai n'est permis qu'à un fournisseur vérifié ou en cours de vérification
  if not exists (select 1 from pg_constraint where conname = 'fournisseur_essai_permis') then
    alter table public.fournisseurs_suivi add constraint fournisseur_essai_permis
      check (not essai or conformite in ('VERIFIED', 'PENDING_VERIFICATION'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'fournisseur_reglages_bornes') then
    alter table public.fournisseurs_suivi add constraint fournisseur_reglages_bornes
      check (plafond_essai between 0 and 100000 and marge_quota between 0 and 100000
             and (arret_motif is null or length(arret_motif) <= 60));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'suivi_externe_moteur_borne') then
    alter table public.suivis_externes add constraint suivi_externe_moteur_borne
      check (etape in ('inscription', 'lecture', 'changement', 'fini')
             and (numero_original is null or length(numero_original) <= 120)
             and (transporteur_origine is null or transporteur_origine in ('transmis', 'detecte', 'devine'))
             and (derniere_erreur is null or length(derniere_erreur) <= 60)
             and tentatives >= 0 and lectures >= 0 and changements >= 0);
  end if;
end
$contraintes$;

-- Un seul fournisseur en service (actif ou en essai) à la fois
create unique index if not exists fournisseurs_suivi_un_en_service
  on public.fournisseurs_suivi ((true)) where actif or essai;

create index if not exists suivis_externes_moteur_idx
  on public.suivis_externes (etape, prochaine_synchro_le) where etat = 'en_attente';
create index if not exists suivis_externes_requete_idx
  on public.suivis_externes (requete) where requete is not null;


-- 3. La détection ---------------------------------------------------------------------
-- Le transporteur que le numéro PROUVE : la même règle que assets/js/transporteur.js
-- (Palier A), copiée ici parce que la base décide seule de ce qu'elle envoie.
-- essai-moteur-suivi.py vérifie que les deux copies répondent pareil. Une forme qui
-- n'appartient qu'à lui ET, quand elle en a une, une clé de contrôle juste ; sinon NULL.
create or replace function public.detecter_transporteur(p_numero text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  n text := public.normaliser_numero_suivi(p_numero);
  v_somme integer := 0;
  v_poids integer := 3;
  v_c integer;
  v_v integer;
  v_cle integer;
  v_p integer[] := array[8, 6, 4, 2, 3, 5, 9, 7];
  i integer;
begin
  -- Amazon Logistics : « TBA » et 12 chiffres
  if n ~ '^TBA[0-9]{12}$' then
    return 'amazon';
  end if;
  -- UPS : 1Z, 15 signes, la clé. Une lettre vaut (code − 63) mod 10 ; rangs impairs doublés
  -- (en comptant depuis 0, comme le JavaScript).
  if n ~ '^1Z[0-9A-Z]{16}$' and substr(n, 18, 1) ~ '[0-9]' then
    for i in 2..16 loop
      v_c := ascii(substr(n, i + 1, 1));
      v_v := case when v_c <= 57 then v_c - 48 else (v_c - 63) % 10 end;
      v_somme := v_somme + case when i % 2 = 1 then 2 * v_v else v_v end;
    end loop;
    if (10 - v_somme % 10) % 10 = substr(n, 18, 1)::integer then
      return 'ups';
    end if;
    v_somme := 0;
  end if;
  -- USPS, code-barres IMpb (20 à 22 chiffres, « 9[1-5]… ») : modulo 10, poids 3 puis 1 depuis la droite
  if n ~ '^9[1-5][0-9]{18,20}$' then
    for i in reverse (length(n) - 1)..1 loop
      v_somme := v_somme + substr(n, i, 1)::integer * v_poids;
      v_poids := case when v_poids = 3 then 1 else 3 end;
    end loop;
    if (10 - v_somme % 10) % 10 = substr(n, length(n), 1)::integer then
      return 'usps';
    end if;
    v_somme := 0;
  end if;
  -- Numéro postal international S10 de l'UPU se terminant par US : celui de l'USPS
  if n ~ '^[A-Z]{2}[0-9]{9}US$' then
    for i in 1..8 loop
      v_somme := v_somme + substr(n, i + 2, 1)::integer * v_p[i];
    end loop;
    v_cle := 11 - v_somme % 11;
    if v_cle = 10 then v_cle := 0; end if;
    if v_cle = 11 then v_cle := 5; end if;
    if v_cle = substr(n, 11, 1)::integer then
      return 'usps';
    end if;
  end if;
  return null;
end;
$$;

-- Ce qui n'est PAS un suivi de transporteur, reconnu avant de rien dépenser :
--    goship           le numéro d'un colis GoShip (GSE-1001-HT) : notre propre suivi ;
--    commande_amazon  la forme d'une commande Amazon (111-1234567-1234567).
-- Les formes de commande SHEIN ou Temu ne sont pas prouvées : elles ne sont pas devinées.
create or replace function public.nature_numero(p_numero text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when public.normaliser_numero_suivi(p_numero) ~ '^GSE-[0-9]+-[A-Z]{2}$' then 'goship'
    when public.normaliser_numero_suivi(p_numero) ~ '^[0-9]{3}-[0-9]{7}-[0-9]{7}$' then 'commande_amazon'
    else null
  end
$$;

-- Les transporteurs que l'équipe peut choisir à la main, et leur code chez 17TRACK
-- (liste officielle apicarrier.all.json, lue le 12/11/2026). Amazon Logistics (TBA) n'a
-- pas de code documenté : 17TRACK le détecte seul, ou ne le suit pas.
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
         ('4px', '4PX', 190094), ('jt', 'J&T', 100295), ('gofo', 'GOFO', 100996)
$$;


-- 4. L'adaptateur 17TRACK ----------------------------------------------------------------
-- Tout ce qui sait comment parle 17TRACK (API v2.4, documentation lue le 12/11/2026).

-- Notre code de transporteur → le sien (ou NULL : détection par 17TRACK)
create or replace function public.suivi17_code(p_transporteur text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select t.code_17track from public.transporteurs_connus() t where t.code = p_transporteur
$$;

-- Son code → le nôtre, ou « 17track-<code> » pour un transporteur que la liste ne nomme pas
create or replace function public.suivi17_transporteur(p_code integer)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when p_code is null or p_code <= 0 then null
              else coalesce((select t.code from public.transporteurs_connus() t where t.code_17track = p_code),
                            '17track-' || p_code) end
$$;

-- Le corps d'une requête : un objet par suivi, le numéro et, s'il est connu, le code du
-- transporteur. JAMAIS rien d'autre (17TRACK accepte e-mail, téléphone, destinataire… :
-- on ne les envoie pas). Pour un changement de transporteur : l'ancien et le nouveau.
create or replace function public.suivi17_corps(p_suivis uuid[], p_operation text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(case p_operation
           when 'changement' then jsonb_build_object('number', s.numero, 'carrier_old', s.transporteur_fournisseur,
                                                     'carrier_new', public.suivi17_code(s.transporteur))
           when 'lecture' then jsonb_strip_nulls(jsonb_build_object('number', s.numero,
                                                                   'carrier', s.transporteur_fournisseur))
           else jsonb_strip_nulls(jsonb_build_object('number', s.numero,
                                                     'carrier', public.suivi17_code(s.transporteur)))
         end order by s.numero), '[]'::jsonb)
    from public.suivis_externes s
   where s.id = any (p_suivis)
$$;

-- Le code de refus de 17TRACK → ce que le moteur en fait
--    INVALID_TRACKING, CARRIER_UNKNOWN, UNSUPPORTED_TRACKING, PENDING_FIRST_SCAN : codes du
--    cahier des charges ; DEJA_INSCRIT, NON_INSCRIT, QUOTA, REFUS, AUTRE : internes.
create or replace function public.suivi17_refus(p_code integer)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_code in (-18010011, -18010012, -18010013, -18010015) then 'INVALID_TRACKING'
    when p_code = -18019903 then 'CARRIER_UNKNOWN'
    when p_code in (-18019910, -18019911, -18010016) then 'UNSUPPORTED_TRACKING'
    when p_code = -18019909 then 'PENDING_FIRST_SCAN'
    when p_code = -18019901 then 'DEJA_INSCRIT'
    when p_code = -18019902 then 'NON_INSCRIT'
    when p_code in (-18019907, -18019908) then 'QUOTA'
    when p_code in (-18010001, -18010002, -18010004, -18010005) then 'REFUS'
    else 'AUTRE'
  end
$$;

-- Une réponse de lecture (un élément de data.accepted) → le suivi et ses événements.
-- Rend le code de résultat (ou NULL quand le suivi a des événements ordinaires).
-- Ne lit QUE latest_status, latest_event, time_metrics.estimated_delivery_date et
-- tracking.providers[].events[] : shipping_info (adresses du destinataire et de
-- l'expéditeur, rue, coordonnées) et misc_info (références client) ne sont jamais lus.
create or replace function public.suivi17_ranger(p_suivi uuid, p_item jsonb)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ti jsonb := p_item -> 'track_info';
  v_statut text := v_ti #>> '{latest_status,status}';
  v_sous text := v_ti #>> '{latest_status,sub_status}';
  v_dernier jsonb := v_ti -> 'latest_event';
  v_edd jsonb := v_ti #> '{time_metrics,estimated_delivery_date}';
  v_carrier integer;
  v_quand timestamptz;
  v_dernier_le timestamptz;
  v_edd_jour date;
  v_code text;
  p jsonb;
  ev jsonb;
  v_t text;
  v_sev text;
begin
  begin
    v_carrier := nullif(p_item ->> 'carrier', '')::integer;
  exception when others then
    v_carrier := null;
  end;

  -- Les événements, chacun une seule fois (empreinte), sans jamais inventer une date
  for p in select value from jsonb_array_elements(case when jsonb_typeof(v_ti #> '{tracking,providers}') = 'array'
                                                       then v_ti #> '{tracking,providers}' else '[]'::jsonb end) loop
    for ev in select value from jsonb_array_elements(case when jsonb_typeof(p -> 'events') = 'array'
                                                          then p -> 'events' else '[]'::jsonb end) loop
      v_t := coalesce(ev ->> 'time_utc', ev ->> 'time_iso');
      begin
        v_quand := v_t::timestamptz;
      exception when others then
        v_quand := null;
      end;
      continue when v_quand is null;
      v_sev := left(coalesce(ev ->> 'sub_status', ''), 80);
      insert into public.suivis_externes_evenements
        (suivi_id, survenu_le, statut, statut_original, sous_statut, description, lieu, pays, fournisseur, empreinte)
      values (p_suivi, v_quand,
              public.statut_suivi_normalise('17track', split_part(v_sev, '_', 1), v_sev),
              left(split_part(v_sev, '_', 1), 80), v_sev,
              left(coalesce(ev ->> 'description', ''), 300),
              left(coalesce(ev ->> 'location', ''), 120),
              case when ev #>> '{address,country}' ~ '^[A-Z]{2}$' then ev #>> '{address,country}' end,
              '17track',
              md5(concat_ws('|', p #>> '{provider,key}', v_t, ev ->> 'description', ev ->> 'location', v_sev)))
      on conflict (suivi_id, empreinte) do nothing;
    end loop;
  end loop;

  begin
    v_dernier_le := coalesce(v_dernier ->> 'time_utc', v_dernier ->> 'time_iso')::timestamptz;
  exception when others then
    v_dernier_le := null;
  end;
  -- La date de livraison : celle du transporteur seulement, et seulement si elle tient en un jour
  begin
    if v_edd ->> 'source' = 'Official' and left(v_edd ->> 'from', 10) = left(v_edd ->> 'to', 10) then
      v_edd_jour := left(v_edd ->> 'from', 10)::date;
    end if;
  exception when others then
    v_edd_jour := null;
  end;

  v_code := case
              when v_sous = 'NotFound_InvalidCode' then 'INVALID_TRACKING'
              when v_statut = 'NotFound' then 'PENDING_FIRST_SCAN'
              when v_statut = 'Expired' then 'TRACKING_EXPIRED'
              when v_statut is null then 'PENDING_FIRST_SCAN'
            end;

  update public.suivis_externes
     set statut = public.statut_suivi_normalise('17track', v_statut, v_sous),
         statut_original = left(v_statut, 80),
         sous_statut = left(v_sous, 80),
         dernier_lieu = coalesce(left(v_dernier ->> 'location', 120), dernier_lieu),
         dernier_evenement_le = coalesce(v_dernier_le, dernier_evenement_le),
         livraison_estimee_le = v_edd_jour,
         transporteur_fournisseur = coalesce(v_carrier, transporteur_fournisseur),
         transporteur_source = case when transporteur is null and v_carrier is not null then 'fournisseur'
                                    else transporteur_source end,
         transporteur = coalesce(transporteur, public.suivi17_transporteur(v_carrier)),
         code_resultat = v_code,
         derniere_synchro_le = now()
   where id = p_suivi;
  return v_code;
end;
$$;


-- 5. L'orchestrateur ------------------------------------------------------------------

-- Ce que le fournisseur a déjà compté : chaque numéro envoyé à l'inscription (accepté ou
-- non, une fois), plus chaque changement de transporteur.
create or replace function public.suivi_externe_consommes(p_fournisseur text)
returns integer
language sql
stable
set search_path = ''
as $$
  select (count(*) filter (where s.inscription_demandee_le is not null) + coalesce(sum(s.changements), 0))::integer
    from public.suivis_externes s
   where s.fournisseur = p_fournisseur
$$;

-- Arrêter un fournisseur, et dire pourquoi (quota, clé refusée…). Journalisé.
create or replace function public.suivi_externe_arreter(p_fournisseur text, p_motif text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_avant public.fournisseurs_suivi;
begin
  select * into v_avant from public.fournisseurs_suivi where code = p_fournisseur for update;
  if not found or not (v_avant.actif or v_avant.essai) then
    return;
  end if;
  update public.fournisseurs_suivi
     set actif = false, essai = false, arret_motif = left(p_motif, 60), maj_le = now()
   where code = p_fournisseur;
  perform public.auditer('fournisseur_suivi.arret', 'fournisseur_suivi', p_fournisseur,
                         jsonb_build_object('actif', v_avant.actif, 'essai', v_avant.essai),
                         jsonb_build_object('actif', false, 'essai', false, 'motif', left(p_motif, 60)));
end;
$$;

-- Demander le suivi d'un numéro de vendeur. La seule porte d'entrée du moteur.
-- p_transporteur : le choix de l'équipe (transporteurs_connus), quand le numéro ne le
-- prouve pas ou que 17TRACK n'a pas su le détecter. Rien n'est appelé ici : le
-- travailleur s'en charge à la minute suivante, si un fournisseur est en service.
create or replace function public.demander_suivi_externe(p_numero text, p_transporteur text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_original text := left(btrim(coalesce(p_numero, '')), 120);
  v_numero text := public.normaliser_numero_suivi(p_numero);
  v_nature text := public.nature_numero(p_numero);
  v_fournisseur public.fournisseurs_suivi;
  v_exclus text[];
  v_transporteur text;
  v_source text;
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
             prochaine_synchro_le = null, fournisseur = coalesce(v_fournisseur.code, fournisseur)
       where id = s.id;
    elsif public.suivi17_code(p_transporteur) is null then
      perform public.erreur_metier('CARRIER_INVALID', 'Ce transporteur ne se choisit pas pour un numéro déjà inscrit.');
    else
      -- Déjà inscrit : un changement de transporteur, qui coûte un numéro de plus
      update public.suivis_externes
         set transporteur = p_transporteur, transporteur_source = 'equipe', etat = 'en_attente',
             etape = 'changement', code_resultat = null, derniere_erreur = null, tentatives = 0,
             prochaine_synchro_le = null
       where id = s.id;
    end if;
    return public.suivi_externe(v_numero);
  end if;

  v_transporteur := coalesce(p_transporteur, public.detecter_transporteur(v_numero));
  v_source := case when p_transporteur is not null then 'equipe' when v_transporteur is not null then 'numero' end;
  insert into public.suivis_externes
    (numero, numero_original, transporteur, transporteur_source, fournisseur, etat, etape, code_resultat,
     derniere_erreur, demande_par)
  values (v_numero, v_original, v_transporteur, v_source, v_fournisseur.code,
          case when v_nature = 'commande_amazon' or v_transporteur = any (v_exclus) then 'arrete' else 'en_attente' end,
          case when v_nature = 'commande_amazon' or v_transporteur = any (v_exclus) then 'fini' else 'inscription' end,
          case when v_nature = 'commande_amazon' then 'ORDER_NUMBER_DETECTED'
               when v_transporteur = any (v_exclus) then 'UNSUPPORTED_TRACKING' end,
          case when coalesce(v_nature, '') <> 'commande_amazon' and v_transporteur = any (v_exclus)
               then 'TRANSPORTEUR_EXCLU' end,
          auth.uid());
  return public.suivi_externe(v_numero);
end;
$$;

-- Régler un fournisseur : essai, plafond, marge, transporteurs exclus, conformité,
-- activation. Pour l'administrateur (tracking.manage), journalisé.
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
                     'note', 'transporteurs_exclus') then
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
  update public.fournisseurs_suivi
     set essai = v_apres.essai, actif = v_apres.actif, conformite = v_apres.conformite,
         plafond_essai = v_apres.plafond_essai, marge_quota = v_apres.marge_quota,
         plafond_mensuel = v_apres.plafond_mensuel, note = v_apres.note,
         transporteurs_exclus = v_apres.transporteurs_exclus,
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

-- Les fournisseurs (remplace la lecture de la Phase 1, même forme, quelques clés de plus) :
-- conformité, service, essai, plafond, consommé, quota lu. Jamais de clé : il n'y en a pas
-- dans la table.
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
                                        'note', f.note, 'maj_le', f.maj_le)
                     order by f.code)
      from public.fournisseurs_suivi f), '[]'::jsonb);
end;
$$;

-- Les suivis demandés, du plus récent au plus ancien (pour l'équipe, aucune donnée client)
create or replace function public.liste_suivis_externes(p_limite integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('tracking.view');
  return coalesce((
    select jsonb_agg(jsonb_build_object('numero', s.numero, 'transporteur', s.transporteur,
                                        'transporteur_source', s.transporteur_source, 'etat', s.etat,
                                        'etape', s.etape, 'statut', s.statut, 'sous_statut', s.sous_statut,
                                        'code_resultat', s.code_resultat, 'derniere_erreur', s.derniere_erreur,
                                        'dernier_lieu', s.dernier_lieu, 'dernier_evenement_le', s.dernier_evenement_le,
                                        'evenements', (select count(*) from public.suivis_externes_evenements e
                                                        where e.suivi_id = s.id),
                                        'inscrit_le', s.inscrit_le, 'cree_le', s.cree_le)
                     order by s.cree_le desc, s.numero)
      from (select * from public.suivis_externes order by cree_le desc, numero
             limit least(greatest(coalesce(p_limite, 50), 1), 500)) s), '[]'::jsonb);
end;
$$;

-- La liste du choix manuel (code, nom), pour l'équipe
create or replace function public.transporteurs_suivi()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('tracking.view');
  return (select jsonb_agg(jsonb_build_object('code', t.code, 'nom', t.nom) order by t.nom)
            from public.transporteurs_connus() t);
end;
$$;


-- 6. Le travailleur -------------------------------------------------------------------------

-- Un échec passager (réseau, 429, 5xx, réponse illisible, pas de réponse en 10 minutes) :
-- réessayé à 1, 5 puis 15 minutes ; au quatrième, PROVIDER_UNAVAILABLE. Le suivi est gardé.
create or replace function public.suivi_externe_reessayer(p_suivi uuid, p_erreur text)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.suivis_externes
     set requete = null, tentatives = tentatives + 1, derniere_erreur = left(p_erreur, 60),
         prochaine_synchro_le = now() + case tentatives + 1 when 1 then interval '1 minute'
                                                            when 2 then interval '5 minutes'
                                                            else interval '15 minutes' end,
         etat = case when tentatives + 1 > 3 then 'erreur' else etat end,
         etape = case when tentatives + 1 > 3 then 'fini' else etape end,
         code_resultat = case when tentatives + 1 > 3 then 'PROVIDER_UNAVAILABLE' else code_resultat end
   where id = p_suivi
$$;

-- La réponse de 17TRACK à une requête (inscription, lecture ou changement), pour tous
-- les suivis qu'elle portait. Rend 'attente' (pas encore de réponse), 'ok', 'reessai',
-- 'refus' (clé refusée : fournisseur arrêté) ou 'quota' (fournisseur arrêté).
create or replace function public.suivi17_reponse(p_requete bigint, p_etape text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  s record;
  v_json jsonb;
  v_item jsonb;
  v_rejet jsonb;
  v_code_api text;
  v_refus text;
  v_issue text := 'ok';
  v_resultat text;
  v_code text;
  v_nb integer;
  v_premier uuid;
  v_fournisseur text;
  v_origine text;
  v_carrier integer;
begin
  select count(*), min(id::text)::uuid, min(fournisseur) into v_nb, v_premier, v_fournisseur
    from public.suivis_externes where requete = p_requete;
  if v_nb = 0 then
    return 'ok';
  end if;
  select status_code, content, error_msg, created into r from net._http_response where id = p_requete;
  if not found then
    -- Pas encore de réponse ; au-delà de 10 minutes, la demande est perdue : réessai
    if exists (select 1 from public.suivis_externes where requete = p_requete
                and requete_le < now() - interval '10 minutes') then
      for s in select id from public.suivis_externes where requete = p_requete loop
        perform public.suivi_externe_reessayer(s.id, 'SANS_REPONSE');
      end loop;
      insert into public.suivis_externes_journal (suivi_id, fournisseur, operation, resultat, code_erreur)
      values (case when v_nb = 1 then v_premier end, v_fournisseur, p_etape, 'delai', 'SANS_REPONSE');
      return 'reessai';
    end if;
    return 'attente';
  end if;
  begin
    v_json := r.content::jsonb;
  exception when others then
    v_json := null;
  end;
  v_code_api := coalesce(v_json ->> 'code', '');
  v_refus := public.suivi17_refus(nullif(coalesce(v_json #>> '{data,errors,0,code}', ''), '')::integer);

  if r.status_code = 401 or v_refus = 'REFUS' then
    v_issue := 'refus';
  elsif v_refus = 'QUOTA' then
    v_issue := 'quota';
  elsif r.error_msg is not null or r.status_code is null or r.status_code = 429 or r.status_code >= 500
        or r.status_code <> 200 or jsonb_typeof(v_json) is distinct from 'object' or v_code_api <> '0' then
    v_issue := 'reessai';
  end if;

  insert into public.suivis_externes_journal (suivi_id, fournisseur, operation, resultat, code_http, code_erreur, duree_ms)
  values (case when v_nb = 1 then v_premier end, v_fournisseur, p_etape,
          case v_issue when 'ok' then 'ok' when 'refus' then 'refus' when 'quota' then 'quota'
                       else case when r.error_msg is not null or r.status_code is null then 'delai' else 'erreur' end end,
          case when r.status_code between 100 and 599 then r.status_code end,
          left(coalesce(v_json #>> '{data,errors,0,code}', case when r.status_code is null then 'RESEAU' end), 60),
          greatest(0, (extract(epoch from (coalesce(r.created, now()) -
                       (select min(requete_le) from public.suivis_externes where requete = p_requete))) * 1000)::integer));

  if v_issue = 'refus' then
    -- La clé est refusée : on arrête tout, sans réessai ; les suivis attendent la remise en service
    perform public.suivi_externe_arreter(v_fournisseur, 'CLE_REFUSEE');
    update public.suivis_externes set requete = null, derniere_erreur = 'CLE_REFUSEE' where requete = p_requete;
    return 'refus';
  elsif v_issue = 'quota' then
    perform public.suivi_externe_arreter(v_fournisseur, 'QUOTA_EPUISE');
    update public.suivis_externes set requete = null, derniere_erreur = 'QUOTA_EPUISE' where requete = p_requete;
    return 'quota';
  elsif v_issue = 'reessai' then
    for s in select id from public.suivis_externes where requete = p_requete loop
      perform public.suivi_externe_reessayer(s.id, coalesce('HTTP_' || r.status_code, 'RESEAU'));
    end loop;
    return 'reessai';
  end if;

  -- Une réponse en règle : chaque suivi y trouve son numéro, accepté ou refusé
  for s in select * from public.suivis_externes where requete = p_requete loop
    select value into v_item from jsonb_array_elements(coalesce(v_json #> '{data,accepted}', '[]'::jsonb))
     where upper(value ->> 'number') = s.numero limit 1;
    select value into v_rejet from jsonb_array_elements(coalesce(v_json #> '{data,rejected}', '[]'::jsonb))
     where upper(value ->> 'number') = s.numero limit 1;
    v_refus := case when v_item is null and v_rejet is not null
                    then public.suivi17_refus(nullif(coalesce(v_rejet #>> '{error,code}', ''), '')::integer) end;

    if v_item is null and v_rejet is null then
      perform public.suivi_externe_reessayer(s.id, 'REPONSE_INCOMPLETE');
    elsif v_refus = 'QUOTA' then
      perform public.suivi_externe_arreter(s.fournisseur, 'QUOTA_EPUISE');
      update public.suivis_externes set requete = null, derniere_erreur = 'QUOTA_EPUISE' where id = s.id;
    elsif v_refus = 'AUTRE' then
      perform public.suivi_externe_reessayer(s.id, left('17TRACK_' || coalesce(v_rejet #>> '{error,code}', ''), 60));

    elsif p_etape = 'inscription' then
      if v_item is not null or v_refus = 'DEJA_INSCRIT' then
        -- Inscrit (ou déjà inscrit : 17TRACK ne le compte pas deux fois). Origine du transporteur :
        -- 2 = celui qu'on a transmis, confirmé ; 1 = détecté ou corrigé par 17TRACK ; 3 = deviné.
        begin
          v_carrier := nullif(v_item ->> 'carrier', '')::integer;
        exception when others then
          v_carrier := null;
        end;
        v_origine := case v_item ->> 'origin' when '2' then 'transmis' when '1' then 'detecte' when '3' then 'devine' end;
        update public.suivis_externes
           set inscrit_le = coalesce(inscrit_le, now()), requete = null, tentatives = 0, lectures = 0,
               transporteur_fournisseur = coalesce(v_carrier, transporteur_fournisseur),
               transporteur_origine = coalesce(v_origine, transporteur_origine),
               transporteur_source = case when transporteur is null and v_carrier is not null then 'fournisseur'
                                          else transporteur_source end,
               transporteur = coalesce(transporteur, public.suivi17_transporteur(v_carrier)),
               etape = 'lecture', code_resultat = null, derniere_erreur = null,
               -- 17TRACK donne un premier résultat en quelques secondes, parfois plus de 5 minutes
               prochaine_synchro_le = now() + interval '1 minute'
         where id = s.id;
      else
        -- Refusé : invalide, transporteur inconnu (choix manuel), non pris en charge.
        -- Pour un TBA prouvé que 17TRACK ne sait pas suivre : la limite d'Amazon, dite telle quelle.
        v_code := case when s.transporteur = 'amazon' and v_refus in ('CARRIER_UNKNOWN', 'UNSUPPORTED_TRACKING')
                       then 'AMAZON_TBA_LIMITATION' else v_refus end;
        update public.suivis_externes
           set requete = null, etat = 'arrete', etape = 'fini', code_resultat = v_code,
               derniere_erreur = left('17TRACK_' || coalesce(v_rejet #>> '{error,code}', ''), 60)
         where id = s.id;
      end if;

    elsif p_etape = 'lecture' then
      if v_item is not null and v_item ? 'track_info' then
        v_code := public.suivi17_ranger(s.id, v_item);
      elsif v_refus = 'PENDING_FIRST_SCAN' then
        v_code := 'PENDING_FIRST_SCAN';
        update public.suivis_externes set code_resultat = v_code, derniere_synchro_le = now() where id = s.id;
      else
        -- 17TRACK ne connaît pas (ou plus) ce numéro : on ne le réinscrit pas tout seul
        -- (cela coûterait un numéro) ; l'équipe décide.
        v_code := null;
        update public.suivis_externes
           set requete = null, etat = 'erreur', etape = 'fini',
               derniere_erreur = left('17TRACK_' || coalesce(v_rejet #>> '{error,code}', ''), 60)
         where id = s.id;
        continue;
      end if;
      -- Pas encore de premier scan : redemandé deux fois (5 puis 10 minutes plus tard) ;
      -- la suite est la mise à jour régulière de la Phase 3.
      update public.suivis_externes
         set requete = null, tentatives = 0, lectures = lectures + 1, derniere_erreur = null,
             etat = case when v_code = 'PENDING_FIRST_SCAN' and lectures + 1 < 3 then 'en_attente'
                         when v_code = 'INVALID_TRACKING' then 'arrete'
                         else 'actif' end,
             etape = case when v_code = 'PENDING_FIRST_SCAN' and lectures + 1 < 3 then 'lecture' else 'fini' end,
             prochaine_synchro_le = case when v_code = 'PENDING_FIRST_SCAN' and lectures + 1 < 3
                                         then now() + (lectures + 1) * interval '5 minutes' end
       where id = s.id;

    elsif p_etape = 'changement' then
      if v_item is not null then
        update public.suivis_externes
           set requete = null, tentatives = 0, lectures = 0, transporteur_fournisseur = public.suivi17_code(transporteur),
               transporteur_origine = 'transmis', etape = 'lecture', code_resultat = null, derniere_erreur = null,
               prochaine_synchro_le = now() + interval '1 minute'
         where id = s.id;
      else
        update public.suivis_externes
           set requete = null, etat = 'erreur', etape = 'fini',
               derniere_erreur = left('17TRACK_' || coalesce(v_rejet #>> '{error,code}', ''), 60)
         where id = s.id;
      end if;
    end if;
  end loop;
  return 'ok';
end;
$$;

-- La réponse de 17TRACK à une lecture du quota (getquota, gratuite)
create or replace function public.suivi17_quota_reponse(p_fournisseur text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  f public.fournisseurs_suivi;
  r record;
  v_json jsonb;
  v_reste integer;
begin
  select * into f from public.fournisseurs_suivi where code = p_fournisseur and quota_requete is not null for update;
  if not found then
    return 'ok';
  end if;
  select status_code, content, error_msg, created into r from net._http_response where id = f.quota_requete;
  if not found then
    if f.quota_lu_le is null and f.maj_le < now() - interval '10 minutes' then
      update public.fournisseurs_suivi set quota_requete = null where code = p_fournisseur;
    end if;
    return 'attente';
  end if;
  begin
    v_json := r.content::jsonb;
    v_reste := (v_json #>> '{data,quota_remain}')::integer;
  exception when others then
    v_reste := null;
  end;
  insert into public.suivis_externes_journal (fournisseur, operation, resultat, code_http, code_erreur, quota_restant)
  values (p_fournisseur, 'quota',
          case when v_reste is not null then 'ok'
               when r.status_code = 401 or public.suivi17_refus(nullif(coalesce(v_json #>> '{data,errors,0,code}', ''), '')::integer) = 'REFUS'
                 then 'refus'
               when r.error_msg is not null or r.status_code is null then 'delai' else 'erreur' end,
          case when r.status_code between 100 and 599 then r.status_code end,
          left(v_json #>> '{data,errors,0,code}', 60), v_reste);
  update public.fournisseurs_suivi
     set quota_requete = null,
         quota_restant = coalesce(v_reste, quota_restant),
         quota_lu_le = case when v_reste is not null then now() else quota_lu_le end
   where code = p_fournisseur;
  if r.status_code = 401
     or public.suivi17_refus(nullif(coalesce(v_json #>> '{data,errors,0,code}', ''), '')::integer) = 'REFUS' then
    perform public.suivi_externe_arreter(p_fournisseur, 'CLE_REFUSEE');
    return 'refus';
  end if;
  if v_reste is not null and v_reste <= f.marge_quota then
    perform public.suivi_externe_arreter(p_fournisseur, 'QUOTA_MARGE');
    return 'quota';
  end if;
  return 'ok';
end;
$$;

-- Le travailleur, chaque minute :
--    1. lit les réponses arrivées (requêtes et quota), quel que soit l'état du fournisseur ;
--    2. si un fournisseur est en service et que sa clé est dans le coffre :
--         · relit le quota s'il n'est pas frais (avant tout lot qui coûte) ;
--         · lit les suivis inscrits (gratuit) ;
--         · inscrit les nouveaux et change les transporteurs demandés, dans la limite du
--           plafond d'essai et du quota réel moins la marge — puis le quota sera relu.
--    Au plus 3 requêtes par passage (17TRACK : 3 par seconde), 40 numéros par requête.
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
  v_requete bigint;
  v_permis integer;
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

  -- 2. Les envois
  select * into f from public.fournisseurs_suivi where actif or essai limit 1 for update;
  if not found then
    return jsonb_build_object('en_service', false, 'reponses', v_reponses);
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

  -- Les lectures (gratuites)
  select array_agg(id) into v_ids from (
    select id from public.suivis_externes
     where fournisseur = f.code and etat = 'en_attente' and etape = 'lecture' and requete is null
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
      v_ids := null;
      select array_agg(id) into v_ids from (
        select id from public.suivis_externes
         where (fournisseur is null or fournisseur = f.code) and etat = 'en_attente' and etape = 'inscription'
           and requete is null and (prochaine_synchro_le is null or prochaine_synchro_le <= now())
           and not (coalesce(transporteur, '') = any (f.transporteurs_exclus))
         order by cree_le
         limit v_permis for update skip locked) x;
      if v_ids is not null then
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
                            'lectures', v_lectures, 'inscriptions', v_inscriptions, 'changements', v_changements);
end;
$$;


-- 7. Droits --------------------------------------------------------------------------------
-- Les lectures et les deux portes d'écriture : aux comptes connectés, chaque fonction
-- vérifiant sa permission (tracking.view, tracking.manage). Tout le reste : à personne,
-- sauf le rôle de service (la tâche planifiée tourne comme propriétaire).
revoke execute on function public.detecter_transporteur(text) from public, anon, authenticated;
revoke execute on function public.nature_numero(text) from public, anon, authenticated;
revoke execute on function public.transporteurs_connus() from public, anon, authenticated;
revoke execute on function public.suivi17_code(text) from public, anon, authenticated;
revoke execute on function public.suivi17_transporteur(integer) from public, anon, authenticated;
revoke execute on function public.suivi17_corps(uuid[], text) from public, anon, authenticated;
revoke execute on function public.suivi17_refus(integer) from public, anon, authenticated;
revoke execute on function public.suivi17_ranger(uuid, jsonb) from public, anon, authenticated;
revoke execute on function public.suivi17_reponse(bigint, text) from public, anon, authenticated;
revoke execute on function public.suivi17_quota_reponse(text) from public, anon, authenticated;
revoke execute on function public.suivi_externe_consommes(text) from public, anon, authenticated;
revoke execute on function public.suivi_externe_arreter(text, text) from public, anon, authenticated;
revoke execute on function public.suivi_externe_reessayer(uuid, text) from public, anon, authenticated;
revoke execute on function public.traiter_suivis_externes(integer) from public, anon, authenticated;
revoke execute on function public.demander_suivi_externe(text, text) from public, anon;
revoke execute on function public.regler_fournisseur_suivi(text, jsonb) from public, anon;
revoke execute on function public.liste_suivis_externes(integer) from public, anon;
revoke execute on function public.transporteurs_suivi() from public, anon;
revoke execute on function public.etat_fournisseurs_suivi() from public, anon;
grant execute on function public.demander_suivi_externe(text, text) to authenticated;
grant execute on function public.regler_fournisseur_suivi(text, jsonb) to authenticated;
grant execute on function public.liste_suivis_externes(integer) to authenticated;
grant execute on function public.transporteurs_suivi() to authenticated;
grant execute on function public.etat_fournisseurs_suivi() to authenticated;
grant execute on function public.traiter_suivis_externes(integer) to service_role;


-- La tâche planifiée : chaque minute. Sans fournisseur en service, elle ne lit que les
-- réponses en attente et n'appelle personne. Sans pg_cron, rien ne se perd : les
-- demandes attendent.
do $cron$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('goship-suivi-externe', '* * * * *', 'select public.traiter_suivis_externes()');
  else
    raise notice 'pg_cron absent : le moteur du suivi externe ne tournera pas tant qu''il n''est pas activé.';
  end if;
end
$cron$;


-- 8. Contrôle ----------------------------------------------------------------------------------
-- colonnes : 21 ; en_service : 0 ; ouverte_aux_visiteurs : false ; client_peut_demander : false ;
-- tache : 1 (0 si pg_cron n'est pas activé : voir la partie 7).
select (select count(*) from information_schema.columns
         where table_schema = 'public'
           and ((table_name = 'fournisseurs_suivi'
                 and column_name in ('essai', 'plafond_essai', 'marge_quota', 'quota_restant', 'quota_lu_le',
                                     'quota_requete', 'arret_motif', 'transporteurs_exclus'))
             or (table_name = 'suivis_externes'
                 and column_name in ('numero_original', 'inscription_demandee_le', 'inscrit_le',
                                     'transporteur_fournisseur', 'transporteur_origine', 'etape', 'requete',
                                     'requete_le', 'tentatives', 'lectures', 'changements', 'derniere_erreur',
                                     'demande_par')))) as colonnes,
       (select count(*) from public.fournisseurs_suivi where actif or essai) as en_service,
       has_function_privilege('anon', 'public.demander_suivi_externe(text, text)', 'execute')
         or has_function_privilege('anon', 'public.traiter_suivis_externes(integer)', 'execute')
         or has_function_privilege('anon', 'public.liste_suivis_externes(integer)', 'execute') as ouverte_aux_visiteurs,
       'tracking.manage' = any (public.permissions_du_role('client')) as client_peut_demander,
       case when to_regclass('cron.job') is null then 0
            else (xpath('/row/n/text()', query_to_xml(
                    'select count(*) as n from cron.job where jobname = ''goship-suivi-externe''', false, true, '')))[1]::text::integer
       end as tache;
