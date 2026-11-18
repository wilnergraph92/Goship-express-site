-- =============================================================================
-- BROUILLON — CENTRE DE COMMUNICATION — NE PAS EXÉCUTER
-- Version Phase 1.3.1 (18/11/2026) — garde à trois couches : voir l'en-tête de
-- 40-supabase-communications-fondation.sql (bloc DO, puis TOUT le contenu dans une chaîne inerte).
-- =============================================================================
do $brouillon$
begin
  raise exception 'BROUILLON NON APPROUVÉ (Centre de communication, Phase 1.3.1) : ne pas exécuter.';
end;
$brouillon$;

select $brouillon_goship_non_executable$
-- ===== DÉBUT DU CONTENU INERTE : tout ce qui suit est du TEXTE jusqu'à la balise de fin =====
do $brouillon$
begin
  raise exception 'BROUILLON NON APPROUVÉ (Centre de communication, Phase 1.3.1) : ne pas exécuter.';
end;
$brouillon$;
-- Couche 4 (Phase 1.3.1, IR-22) : un outil qui découperait ce texte à chaque point-virgule, sans comprendre les
-- chaînes, et continuerait après les erreurs, exécuterait CETTE instruction en premier : elle
-- ferme sa propre connexion, et rien de ce qui suit ne peut s'exécuter dans cette session. Dans
-- tout client correct, elle est du texte, comme le reste.
select pg_catalog.pg_terminate_backend(pg_catalog.pg_backend_pid());

-- =============================================================================
-- Goship Express — Centre de communication : modèles (et leur empreinte chez Meta),
-- segments, campagnes, approbation, audience figée. À la suite de 41-…-consentement.
--
-- Cycle d'une campagne (décision D-D : le gérant crée, modifie, programme et met en pause ;
-- SEUL l'administrateur approuve, reprend, annule une campagne approuvée) :
--
--   brouillon ─soumettre─► en_attente_approbation ─approuver (admin)─► programmee
--      ▲  ◄── retirer / refuser (motif) ──┘   ▲                          │ heure venue
--      └──── remettre_en_brouillon ───────────┼──────────────────────────┤ + interrupteurs
--                                              └─ AUDIENCE_DEPASSEE ◄────┤ volume réel > volume approuvé
--                                                 (nouvelle approbation)  ▼
--   annulee ◄── annuler ──                                     en_cours ──► terminee
--                                          en_pause ◄─ pause ──┘   ▲
--                                              └── reprendre (admin) ─┘
--
-- L'approbation porte une EMPREINTE de TOUT ce qui change le message réellement reçu (revue
-- 1.1, C3, H9) : champs de la campagne, modèles (contenu local ET contenu relu chez Meta),
-- environnement d'envoi (identité légale, adresse postale, expéditeur, site_url, habillage,
-- textes du pied, valeur d'adresse_miami()). Elle porte aussi le VOLUME d'audience approuvé
-- (revue 1.1, H13).
-- =============================================================================


-- 1. Les modèles -----------------------------------------------------------------------------
-- Un modèle = un canal, une langue, un texte, une version. Variables permises (liste fermée,
-- celles que la base connaît vraiment) : {{prenom}}, {{nom_complet}}, {{code}} et, seulement
-- quand l'adresse canonique est validée (D-H), {{adresse_miami}} — e-mail seulement : une
-- adresse sur plusieurs lignes n'est pas un paramètre WhatsApp valide (revue 1.1, M2). Pas
-- d'e-mail ni de téléphone dans un message commercial (minimisation ; décision du CEO).
-- Forme normalisée : {{nom}} ou {{nom|repli}}, sans espace (vérifiée à l'enregistrement).
-- WhatsApp : seule la catégorie MARKETING est admise dans la voie commerciale (revue 1.1,
-- M10) ; le contenu qui fait foi est celui relu chez Meta (§2), pas notre copie locale.
create table if not exists public.communication_modeles (
  id                       uuid primary key default gen_random_uuid(),
  nom                      text not null check (length(nom) between 2 and 80),
  canal                    text not null check (canal in ('email', 'whatsapp')),
  langue                   text not null check (langue in ('fr', 'en', 'es', 'ht')),
  version                  integer not null default 1 check (version >= 1),
  statut                   text not null default 'brouillon' check (statut in ('brouillon', 'soumis', 'approuve', 'archive')),
  sujet                    text check (sujet is null or length(sujet) between 2 and 150),
  corps                    text not null check (length(corps) between 2 and 5000),
  variables                text[] not null default '{}',     -- WhatsApp : dans l'ordre {{1}}, {{2}}… de Meta
  whatsapp_nom_meta        text check (whatsapp_nom_meta is null or whatsapp_nom_meta ~ '^[a-z0-9_]{1,512}$'),
  whatsapp_langue_meta     text,
  whatsapp_categorie       text check (whatsapp_categorie is null or whatsapp_categorie = 'MARKETING'),
  empreinte                text not null,                    -- communication_empreinte_modele
  empreinte_meta_approuvee text,                             -- empreinte du contenu relu chez Meta, à l'approbation
  cree_par                 uuid not null,
  cree_le                  timestamptz not null default now(),
  approuve_par             uuid,
  approuve_le              timestamptz,
  remplace_id              uuid references public.communication_modeles (id),
  check (canal <> 'email' or sujet is not null),
  check (canal <> 'whatsapp' or (whatsapp_nom_meta is not null and whatsapp_langue_meta is not null
                                  and whatsapp_categorie is not null)),
  check (statut <> 'approuve' or canal <> 'whatsapp' or empreinte_meta_approuvee is not null)
);
create index if not exists communication_modeles_remplace_idx on public.communication_modeles (remplace_id) where remplace_id is not null;
alter table public.communication_modeles enable row level security;
revoke all on public.communication_modeles from anon, authenticated, service_role;

-- L'empreinte d'un modèle : tout ce qui change le message (revue 1.1, H9).
create or replace function public.communication_empreinte_modele(m public.communication_modeles)
returns text
language sql
immutable
set search_path = ''
as $$
  select encode(extensions.digest(jsonb_build_object(
    'canal', m.canal, 'langue', m.langue, 'version', m.version, 'sujet', m.sujet, 'corps', m.corps,
    'variables', to_jsonb(m.variables), 'nom_meta', m.whatsapp_nom_meta, 'langue_meta', m.whatsapp_langue_meta,
    'categorie', m.whatsapp_categorie)::text, 'sha256'), 'hex')
$$;

-- Un modèle approuvé est figé : contenu, langue, canal, catégorie, empreintes (revue 1.1, H9).
-- Seuls son statut (vers « archive ») et rien d'autre peuvent changer ; une modification = une
-- nouvelle version (nouvelle ligne, remplace_id), à approuver de nouveau.
create or replace function public.communication_modele_fige()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- 1.3.1 (IR-10) : l'empreinte est TOUJOURS celle du contenu (recalculée ici, jamais fournie) ;
  -- un modèle archivé ne revient jamais (il serait redevenu modifiable puis approuvable)
  new.empreinte := public.communication_empreinte_modele(new);
  if tg_op = 'UPDATE' and old.statut = 'archive' then
    raise exception 'TEMPLATE_LOCKED' using detail = 'Un modèle archivé ne se modifie ni ne revient : créez une nouvelle version.', hint = 'goship';
  end if;
  if tg_op = 'UPDATE' and old.statut = 'approuve'
     and ((new.nom, new.canal, new.langue, new.version, new.sujet, new.corps, new.variables, new.whatsapp_nom_meta,
           new.whatsapp_langue_meta, new.whatsapp_categorie, new.empreinte, new.empreinte_meta_approuvee,
           new.approuve_par, new.approuve_le)
          is distinct from
          (old.nom, old.canal, old.langue, old.version, old.sujet, old.corps, old.variables, old.whatsapp_nom_meta,
           old.whatsapp_langue_meta, old.whatsapp_categorie, old.empreinte, old.empreinte_meta_approuvee,
           old.approuve_par, old.approuve_le)
          or new.statut not in ('approuve', 'archive')) then
    raise exception 'TEMPLATE_LOCKED' using detail = 'Un modèle approuvé ne se modifie plus : créez une nouvelle version.', hint = 'goship';
  end if;
  return new;
end;
$$;
drop trigger if exists communication_modele_fige on public.communication_modeles;
create trigger communication_modele_fige before insert or update on public.communication_modeles
  for each row execute function public.communication_modele_fige();

-- Les variables permises aujourd'hui, par canal.
create or replace function public.communication_variables_permises(p_canal text)
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select array['prenom', 'nom_complet', 'code']
         || case when p_canal = 'email' and (select adresse_miami_validee from public.communication_reglages)
                 then array['adresse_miami'] else '{}'::text[] end
$$;

-- Validation d'un texte à l'enregistrement (revue 1.1, M2) : variables connues, forme exacte,
-- pas d'accolade isolée. Renvoie null si le texte est valide, sinon la raison.
create or replace function public.communication_texte_invalide(p_texte text, p_canal text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  m text[];
  v_reste text;
begin
  for m in select regexp_matches(coalesce(p_texte, ''), '\{\{([^}]*)\}\}', 'g') loop
    if m[1] !~ '^[a-z_]+(\|[^{}|]{1,40})?$' then
      return 'VARIABLE_MAL_ECRITE:' || left(m[1], 40);
    end if;
    if not split_part(m[1], '|', 1) = any (public.communication_variables_permises(p_canal)) then
      return 'VARIABLE_INCONNUE:' || split_part(m[1], '|', 1);
    end if;
  end loop;
  v_reste := regexp_replace(coalesce(p_texte, ''), '\{\{[^}]*\}\}', '', 'g');
  if v_reste ~ '[{}]' then
    return 'ACCOLADE_ISOLEE';
  end if;
  return null;
end;
$$;

-- Les valeurs d'un client (lues dans la base, jamais une page). Accolades et barres retirées :
-- un nom de client ne peut pas glisser une variable.
create or replace function public.communication_valeurs_client(p_client uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c public.clients;
  a jsonb := public.adresse_miami();
begin
  select * into c from public.clients where id = p_client;
  return jsonb_strip_nulls(jsonb_build_object(
    'prenom', nullif(regexp_replace(split_part(trim(coalesce(c.nom_complet, '')), ' ', 1), '[{}|]', '', 'g'), ''),
    'nom_complet', nullif(regexp_replace(trim(coalesce(c.nom_complet, '')), '[{}|]', '', 'g'), ''),
    'code', nullif(c.code, ''),
    'adresse_miami', case when coalesce(c.code, '') = '' then null else
       trim(regexp_replace(coalesce(c.nom_complet, ''), '[{}|]', '', 'g') || ' ' || c.code) || E'\n' ||
       (a ->> 'ligne1') || E'\n' || (a ->> 'ligne2') || E'\n' || (a ->> 'ville') || ', ' || (a ->> 'etat') || ' ' ||
       (a ->> 'zip') || E'\n' || (a ->> 'pays') end));
end;
$$;

-- Rendre un texte : {ok, texte} ou {ok:false, raison}. Remplacement par expression régulière
-- (la forme est normalisée), jamais de variable non résolue (revue 1.1, M2).
create or replace function public.communication_rendre(p_texte text, p_client uuid, p_canal text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_valeurs jsonb := public.communication_valeurs_client(p_client);
  v_texte text := coalesce(p_texte, '');
  v_invalide text := public.communication_texte_invalide(p_texte, p_canal);
  m text[];
  v_nom text;
  v_val text;
begin
  if v_invalide is not null then
    return jsonb_build_object('ok', false, 'raison', v_invalide);
  end if;
  for m in select regexp_matches(v_texte, '\{\{([a-z_]+)(\|([^{}|]*))?\}\}', 'g') loop
    v_nom := m[1];
    v_val := coalesce(v_valeurs ->> v_nom, nullif(trim(m[3]), ''));
    if v_val is null then
      return jsonb_build_object('ok', false, 'raison', 'VARIABLE_MANQUANTE:' || v_nom);
    end if;
    v_texte := replace(v_texte, '{{' || v_nom || coalesce(m[2], '') || '}}', v_val);
  end loop;
  if v_texte ~ '\{\{|\}\}' then
    return jsonb_build_object('ok', false, 'raison', 'VARIABLE_NON_RESOLUE');
  end if;
  return jsonb_build_object('ok', true, 'texte', v_texte);
end;
$$;

-- Un paramètre WhatsApp valide (revue 1.1, M2) : une ligne, pas de tabulation, pas plus de
-- quatre espaces de suite (règles rapportées pour les paramètres de modèles Meta, à confirmer ;
-- la longueur maximale aussi, sans valeur inventée ici).
create or replace function public.communication_parametre_whatsapp_invalide(p_valeur text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_valeur is null or p_valeur ~ '[\n\r\t]' or p_valeur ~ ' {5,}' or trim(p_valeur) = ''
$$;


-- 2. Le contenu réel chez Meta (revue 1.1, C3) ------------------------------------------------------
-- Le texte d'un message WhatsApp est défini CHEZ META, et un modèle approuvé peut y être
-- modifié. La base relit donc le modèle chez Meta et en garde une image normalisée, avec son
-- empreinte. Méthode PRÉVUE : la liste des modèles du compte WhatsApp Business par l'API
-- Graph (nom, langue, statut, catégorie, composants : en-tête, corps, pied, boutons). Cette
-- méthode est À CONFIRMER sur la documentation officielle de Meta et sur un compte d'essai en
-- Phase 3 : tant qu'elle ne l'est pas, aucun modèle WhatsApp ne peut être approuvé (échec
-- fermé). Fréquence : à l'approbation du modèle, à l'approbation de la campagne, au lancement,
-- puis au plus tard toutes les modele_meta_fraicheur_min minutes pendant l'envoi — pas avant
-- CHAQUE message (une requête par message serait excessive ; limite documentée).
create table if not exists public.communication_modeles_meta (
  id            bigint generated always as identity primary key,
  modele_id     uuid not null references public.communication_modeles (id),
  demande_le    timestamptz not null default now(),
  requete       bigint,                       -- n° pg_net
  recu_le       timestamptz,
  statut_meta   text,                         -- APPROVED, PAUSED, DISABLED, REJECTED… (valeurs de Meta)
  categorie     text,
  langue        text,
  composants    jsonb,                        -- image NORMALISÉE (voir communication_normaliser_composants)
  empreinte     text,
  erreur        text                          -- un code, jamais le texte de Meta
);
create index if not exists communication_modeles_meta_idx on public.communication_modeles_meta (modele_id, recu_le desc);
alter table public.communication_modeles_meta enable row level security;
revoke all on public.communication_modeles_meta from anon, authenticated, service_role;

-- L'image normalisée des composants : type, format, texte, boutons (type, texte, adresse,
-- téléphone), dans l'ordre de Meta ; tout autre champ est ignoré pour que l'empreinte ne
-- change que si le message change.
create or replace function public.communication_normaliser_composants(p_composants jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'type', c ->> 'type', 'format', c ->> 'format', 'text', c ->> 'text',
           'buttons', (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                         'type', b ->> 'type', 'text', b ->> 'text', 'url', b ->> 'url', 'phone_number', b ->> 'phone_number'))
                         order by o)
                       from jsonb_array_elements(c -> 'buttons') with ordinality as x(b, o))))
           order by i), '[]'::jsonb)
  from jsonb_array_elements(coalesce(p_composants, '[]'::jsonb)) with ordinality as t(c, i)
$$;

-- Demander l'image d'un modèle chez Meta (pg_net, sans attendre). Le compte WhatsApp Business
-- commercial est un réglage du coffre (communication_whatsapp_waba_id).
create or replace function public.communication_demander_modele_meta(p_modele uuid)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  m public.communication_modeles;
  v_waba text := public.lire_reglage('communication_whatsapp_waba_id');
  v_jeton text := public.lire_reglage('communication_whatsapp_jeton');
  v_requete bigint;
  v_id bigint;
begin
  -- Phase 1.3.1 : une requête vers Meta est une SORTIE ; elle exige d'être passée par la porte
  -- (communication_autoriser_sortie('lecture_meta', 'whatsapp')) dans CETTE transaction.
  if not public.communication_sortie_autorisee('lecture_meta', 'whatsapp') then
    raise exception 'SORTIE_NON_AUTORISEE';
  end if;
  select * into m from public.communication_modeles where id = p_modele;
  if m.canal <> 'whatsapp' then
    return null;
  end if;
  if coalesce(v_waba, '') = '' or coalesce(v_jeton, '') = '' then
    insert into public.communication_modeles_meta (modele_id, recu_le, erreur) values (p_modele, now(), 'NON_CONFIGURE')
    returning id into v_id;
    return v_id;
  end if;
  select net.http_get(
    url := 'https://graph.facebook.com/' || coalesce(nullif(public.lire_reglage('whatsapp_version'), ''), 'v23.0') ||
           '/' || v_waba || '/message_templates',
    params := jsonb_build_object('name', m.whatsapp_nom_meta, 'fields', 'name,language,status,category,components'),
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_jeton),
    timeout_milliseconds := (select delai_http_ms from public.communication_reglages)
  ) into v_requete;
  insert into public.communication_modeles_meta (modele_id, requete) values (p_modele, v_requete) returning id into v_id;
  return v_id;
end;
$$;

-- Lire les réponses arrivées (appelée par le travailleur, 43 §6). La bonne langue est choisie
-- parmi les variantes renvoyées ; aucune variante : MODELE_META_INCONNU.
create or replace function public.communication_lire_modeles_meta()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  x record;
  r record;
  m public.communication_modeles;
  v_json jsonb;
  v_variante jsonb;
  v_n integer := 0;
begin
  for x in select * from public.communication_modeles_meta where recu_le is null and requete is not null
            order by demande_le limit 50 for update skip locked loop
    select status_code, content, error_msg into r from net._http_response where id = x.requete;
    if not found then
      if x.demande_le < now() - interval '10 minutes' then
        update public.communication_modeles_meta set recu_le = now(), erreur = 'SANS_REPONSE' where id = x.id;
      end if;
      continue;
    end if;
    select * into m from public.communication_modeles where id = x.modele_id;
    begin v_json := r.content::jsonb; exception when others then v_json := null; end;
    select v into v_variante from jsonb_array_elements(coalesce(v_json -> 'data', '[]'::jsonb)) v
     where v ->> 'name' = m.whatsapp_nom_meta and v ->> 'language' = m.whatsapp_langue_meta limit 1;
    if r.error_msg is not null or r.status_code not between 200 and 299 then
      update public.communication_modeles_meta set recu_le = now(), erreur = 'HTTP_' || coalesce(r.status_code, 0) where id = x.id;
    elsif v_variante is null then
      update public.communication_modeles_meta set recu_le = now(), erreur = 'MODELE_META_INCONNU' where id = x.id;
    else
      update public.communication_modeles_meta
         set recu_le = now(), statut_meta = v_variante ->> 'status', categorie = v_variante ->> 'category',
             langue = v_variante ->> 'language',
             composants = public.communication_normaliser_composants(v_variante -> 'components'),
             empreinte = encode(extensions.digest(jsonb_build_object(
                           'name', v_variante ->> 'name', 'language', v_variante ->> 'language',
                           'category', v_variante ->> 'category',
                           'components', public.communication_normaliser_composants(v_variante -> 'components'))::text,
                         'sha256'), 'hex')
       where id = x.id;
    end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- Le modèle est-il conforme à ce qui a été approuvé ? null si oui, sinon le code du blocage :
-- MODELE_META_NON_VERIFIE (aucune image récente), MODELE_META_STATUT (pas APPROVED),
-- MODELE_META_CATEGORIE (pas MARKETING), MODELE_META_DIFFERENT (empreinte changée).
create or replace function public.communication_modele_meta_bloque(p_modele uuid, p_empreinte_attendue text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  x public.communication_modeles_meta;
  v_fraicheur integer := (select modele_meta_fraicheur_min from public.communication_reglages);
begin
  select * into x from public.communication_modeles_meta
   where modele_id = p_modele and recu_le is not null order by recu_le desc limit 1;
  if not found or x.erreur is not null or x.recu_le < now() - make_interval(mins => v_fraicheur) then
    return 'MODELE_META_NON_VERIFIE';
  end if;
  if x.statut_meta is distinct from 'APPROVED' then return 'MODELE_META_STATUT'; end if;
  if x.categorie is distinct from 'MARKETING' then return 'MODELE_META_CATEGORIE'; end if;
  if p_empreinte_attendue is not null and x.empreinte is distinct from p_empreinte_attendue then
    return 'MODELE_META_DIFFERENT';
  end if;
  return null;
end;
$$;


-- 3. Les segments (revue 1.1, M3) --------------------------------------------------------------------
-- Critères en liste fermée, valeurs contrôlées, jamais du SQL :
--   inscrits_depuis_jours, actifs_jours, inactifs_jours  entiers de 1 à 3650
--   sans_colis, colis_en_transit, colis_livres          booléens
--   pays                                                 sous-ensemble de ["HT","DO","US"]
--   langues                                              sous-ensemble de ["fr","en","es","ht"]
-- Consentement CONFIRMÉ, suppression, contact valide, territoire autorisé et liste d'essai
-- s'ajoutent TOUJOURS (communication_raison_exclusion).
create table if not exists public.communication_segments (
  id        uuid primary key default gen_random_uuid(),
  nom       text not null check (length(nom) between 2 and 80),
  criteres  jsonb not null default '{}'::jsonb,
  cree_par  uuid not null,
  cree_le   timestamptz not null default now(),
  maj_le    timestamptz not null default now()
);
alter table public.communication_segments enable row level security;
revoke all on public.communication_segments from anon, authenticated, service_role;

create or replace function public.communication_criteres_valides(p_criteres jsonb)
returns void
language plpgsql
stable
set search_path = ''
as $$
declare
  k text;
  v jsonb;
begin
  if jsonb_typeof(coalesce(p_criteres, '{}'::jsonb)) <> 'object' then
    perform public.erreur_metier('INVALID_SEGMENT', 'Critères mal formés.');
  end if;
  for k, v in select * from jsonb_each(coalesce(p_criteres, '{}'::jsonb)) loop
    if k in ('inscrits_depuis_jours', 'actifs_jours', 'inactifs_jours') then
      if jsonb_typeof(v) <> 'number' or (v #>> '{}') !~ '^[0-9]{1,4}$' or (v #>> '{}')::integer not between 1 and 3650 then
        perform public.erreur_metier('INVALID_SEGMENT', k || ' : un nombre entier de jours entre 1 et 3650.');
      end if;
    elsif k in ('sans_colis', 'colis_en_transit', 'colis_livres') then
      if jsonb_typeof(v) <> 'boolean' then
        perform public.erreur_metier('INVALID_SEGMENT', k || ' : vrai ou faux.');
      end if;
    elsif k = 'pays' then
      if jsonb_typeof(v) <> 'array' or exists (select 1 from jsonb_array_elements_text(v) x where x not in ('HT', 'DO', 'US')) then
        perform public.erreur_metier('INVALID_SEGMENT', 'pays : HT, DO ou US seulement.');
      end if;
    elsif k = 'langues' then
      if jsonb_typeof(v) <> 'array' or exists (select 1 from jsonb_array_elements_text(v) x where x not in ('fr', 'en', 'es', 'ht')) then
        perform public.erreur_metier('INVALID_SEGMENT', 'langues : fr, en, es ou ht seulement.');
      end if;
    else
      perform public.erreur_metier('INVALID_SEGMENT', 'Critère inconnu : ' || k);
    end if;
  end loop;
end;
$$;

create or replace function public.communication_segment_clients(p_criteres jsonb)
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select c.id
    from public.clients c
   where c.role = 'client' and c.supprime_le is null
     and (not (p_criteres ? 'inscrits_depuis_jours')
          or c.cree_le >= now() - make_interval(days => (p_criteres ->> 'inscrits_depuis_jours')::integer))
     and (coalesce((p_criteres ->> 'sans_colis')::boolean, false) = false
          or not exists (select 1 from public.colis k where k.client_id = c.id))
     and (not (p_criteres ? 'actifs_jours')
          or exists (select 1 from public.colis k where k.client_id = c.id
                      and k.cree_le >= now() - make_interval(days => (p_criteres ->> 'actifs_jours')::integer)))
     and (not (p_criteres ? 'inactifs_jours')
          or (exists (select 1 from public.colis k where k.client_id = c.id)
              and not exists (select 1 from public.colis k where k.client_id = c.id
                               and k.cree_le >= now() - make_interval(days => (p_criteres ->> 'inactifs_jours')::integer))))
     and (coalesce((p_criteres ->> 'colis_en_transit')::boolean, false) = false
          or exists (select 1 from public.colis k where k.client_id = c.id and k.statut <> 'livre'))
     and (coalesce((p_criteres ->> 'colis_livres')::boolean, false) = false
          or exists (select 1 from public.colis k where k.client_id = c.id and k.statut = 'livre'))
     and (not (p_criteres ? 'pays') or c.pays in (select jsonb_array_elements_text(p_criteres -> 'pays')))
     and (not (p_criteres ? 'langues') or c.langue in (select jsonb_array_elements_text(p_criteres -> 'langues')))
$$;

-- L'éligibilité d'un client sur un canal : null si éligible, sinon la raison. Appelée à
-- l'approbation (comptage), au lancement (audience figée) et juste avant chaque envoi.
create or replace function public.communication_raison_exclusion(p_client uuid, p_canal text, p_essai boolean)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  r public.communication_reglages;
  v_cible text;
  v_empreinte text;
  v_territoire text;
  v_equipe boolean;
begin
  select * into r from public.communication_reglages;
  select role <> 'client' into v_equipe from public.clients where id = p_client and supprime_le is null;
  if v_equipe is null then
    return 'COMPTE_INACTIF';
  end if;
  -- Mode essai (réglage) ou campagne d'essai : la liste d'essai, et elle seule
  if (r.mode = 'essai' or p_essai) and not public.communication_est_essai(p_client, p_canal) then
    return 'HORS_LISTE_ESSAI';
  end if;
  -- Un compte de l'équipe ne reçoit QUE des campagnes d'essai (il n'a pas de consentement à donner)
  if v_equipe and not p_essai then
    return 'COMPTE_EQUIPE';
  end if;
  v_cible := public.communication_cible(p_client, p_canal);
  if v_cible is null then
    return 'SANS_DESTINATAIRE';
  end if;
  v_empreinte := public.communication_empreinte(p_canal, v_cible);
  if v_empreinte is null then
    return 'EMPREINTE_INDISPONIBLE';                   -- poivre absent : échec fermé
  end if;
  if public.communication_supprimee(p_canal, v_empreinte) then
    return 'SUPPRIME';
  end if;
  if not v_equipe and not public.communication_consentement_actuel(p_client, p_canal) then
    return 'SANS_CONSENTEMENT_CONFIRME';
  end if;
  -- Phase 1.3 (C6) : sans heure locale SÛRE, pas d'envoi (le pays ne prouve pas le fuseau)
  if public.communication_fuseau(p_client, p_canal) is null then
    return 'FUSEAU_INCONNU';
  end if;
  if p_canal = 'whatsapp' then
    v_territoire := public.communication_territoire(v_cible);
    -- Revue n° 2 (IR2-09) : l'autorisation est celle du préfixe LE PLUS LONG qui correspond au
    -- numéro, pas « un préfixe quelconque du même territoire »
    if v_territoire is null or not coalesce((select i.autorise_marketing and i.verifie
                                               from public.communication_indicatifs i
                                              where v_cible like i.prefixe || '%'
                                              order by length(i.prefixe) desc limit 1), false) then
      return 'TERRITOIRE_NON_AUTORISE';
    end if;
    if not exists (select 1 from public.communication_tarifs t where t.fournisseur = 'meta' and t.canal = 'whatsapp'
                    and t.categorie = 'marketing' and t.territoire = v_territoire) then
      return 'TARIF_NON_VERIFIE';
    end if;
  end if;
  return null;
end;
$$;

-- Aperçu d'audience : des NOMBRES seulement, par canal et par raison (revue 1.1, L4).
create or replace function public.apercu_audience_communication(p_criteres jsonb, p_canaux text[], p_essai boolean default false)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_resultat jsonb := '{}'::jsonb;
  v_canal text;
begin
  perform public.exiger_permission('communications.view');
  perform public.communication_criteres_valides(p_criteres);
  foreach v_canal in array coalesce(p_canaux, '{}') loop
    v_resultat := v_resultat || jsonb_build_object(v_canal, (
      select jsonb_build_object(
        'segment', coalesce(sum(n), 0),
        'eligibles', coalesce(sum(n) filter (where raison is null), 0),
        'exclus', coalesce(jsonb_object_agg(raison, n) filter (where raison is not null), '{}'::jsonb))
      from (select raison, count(*) n
              from (select public.communication_raison_exclusion(id, v_canal, p_essai) raison
                      from public.communication_segment_clients(p_criteres) id) x
             group by raison) y));
  end loop;
  return v_resultat;
end;
$$;


-- 4. Les campagnes --------------------------------------------------------------------------------------
create table if not exists public.communication_campagnes (
  id                    uuid primary key default gen_random_uuid(),
  nom                   text not null check (length(nom) between 2 and 120),
  description           text not null default '' check (length(description) <= 1000),
  statut                text not null default 'brouillon' check (statut in (
                          'brouillon', 'en_attente_approbation', 'programmee', 'en_cours',
                          'terminee', 'en_pause', 'annulee', 'echec')),
  canaux                text[] not null default '{}' check (canaux <@ array['email', 'whatsapp']::text[]),
  segment_id            uuid references public.communication_segments (id),
  criteres              jsonb not null default '{}'::jsonb,      -- copie figée à la soumission
  modeles               jsonb not null default '{}'::jsonb,      -- {"email":{"fr":uuid,…},"whatsapp":{…}}
  langue_repli          text not null default 'fr' check (langue_repli in ('fr', 'en', 'es', 'ht')),
  planifiee_le          timestamptz,
  plafond_cout_usd      numeric(10, 2) not null default 0 check (plafond_cout_usd >= 0),
  plafond_messages      integer not null default 0 check (plafond_messages >= 0),
  essai                 boolean not null default false,
  empreinte             text,                                    -- à la soumission
  empreinte_approuvee   text,
  audience_approuvee    jsonb,                                   -- {"email":n,"whatsapp":n} au moment de l'approbation
  cout_estime_approuve  numeric(12, 5),
  seuil_croissance_pct  integer,                                 -- copié des réglages à l'approbation
  cree_par              uuid not null,
  cree_le               timestamptz not null default now(),
  soumise_par           uuid,
  soumise_le            timestamptz,
  approuvee_par         uuid,
  approuvee_le          timestamptz,
  motif_refus           text,
  lancee_le             timestamptz,
  terminee_le           timestamptz,
  arret_motif           text,
  messages_reserves     integer not null default 0,
  -- 1.3.1 (IR-07) : au lancement, le NOMBRE de retenus et d'exclus par canal et par raison —
  -- jamais la liste des personnes exclues
  retenus               integer,
  exclusions            jsonb,
  cout_reserve_usd      numeric(12, 5) not null default 0,
  maj_le                timestamptz not null default now(),
  maj_par               uuid
);
create index if not exists communication_campagnes_dues_idx on public.communication_campagnes (planifiee_le) where statut = 'programmee';
create index if not exists communication_campagnes_segment_idx on public.communication_campagnes (segment_id) where segment_id is not null;
alter table public.communication_campagnes enable row level security;
revoke all on public.communication_campagnes from anon, authenticated, service_role;

-- 4.1 L'environnement d'envoi : tout ce qui, hors de la campagne et des modèles, change le
-- message reçu (revue 1.1, H9). Les valeurs du coffre n'entrent dans l'empreinte que hachées.
-- « habillage-commercial-v1 » est la version de communication_courriel_commercial (43) : toute
-- modification de cette fonction doit changer ce numéro, ce qui invalide les approbations.
-- 1.3.1 (IR-05) : en PL/pgSQL — en « language sql », sa création échouait (elle appelle
-- communication_textes_pied_tous, créée seulement en 43, et PostgreSQL valide le corps d'une
-- fonction SQL à sa création). (IR-19) : l'empreinte couvre aussi le CODE des fonctions qui
-- fabriquent et envoient le message, le fournisseur e-mail et l'adresse de désinscription en un
-- clic : modifier l'une d'elles invalide les approbations, sans numéro de version à changer à la main.
create or replace function public.communication_environnement_envoi()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  r public.communication_reglages;
begin
  select * into r from public.communication_reglages;
  return jsonb_build_object(
    'identite_legale', r.identite_legale, 'adresse_postale', r.adresse_postale,
    'expediteur', encode(extensions.digest(coalesce(public.lire_reglage('communication_expediteur'), ''), 'sha256'), 'hex'),
    'nom_expediteur', coalesce(public.lire_reglage('communication_nom'), ''),
    'numero_whatsapp', encode(extensions.digest(coalesce(public.lire_reglage('communication_whatsapp_numero_id'), ''), 'sha256'), 'hex'),
    'fournisseur_email', coalesce(public.lire_reglage('communication_email_fournisseur'), ''),
    'compte_email', encode(extensions.digest(coalesce(public.lire_reglage('communication_email_cle_api'), ''), 'sha256'), 'hex'),
    'version_whatsapp', coalesce(public.lire_reglage('whatsapp_version'), ''),
    'url_un_clic', coalesce(public.lire_reglage('communication_url_un_clic'), ''),
    'site_url', coalesce(public.lire_reglage('site_url'), ''),
    'habillage', 'habillage-commercial-v1',
    'code', (select encode(extensions.digest(string_agg(pg_catalog.pg_get_functiondef(p.oid), '|' order by p.proname), 'sha256'), 'hex')
               from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public'
                and p.proname in ('communication_courriel_commercial', 'communication_rendre', 'communication_valeurs_client',
                                  'communication_textes_pied', 'communication_appel_email', 'communication_appel_whatsapp',
                                  'communication_jeton_desinscription', 'communication_traiter_un',
                                  'communication_textes_confirmation', 'communication_raison_exclusion',
                                  'communication_parametre_whatsapp_invalide')),
    'textes_pied', encode(extensions.digest(public.communication_textes_pied_tous()::text, 'sha256'), 'hex'),
    'adresse_miami', case when r.adresse_miami_validee then public.adresse_miami() end);
end;
$$;

-- 4.2 L'empreinte de la campagne : champs + modèles (empreinte locale ET image Meta approuvée)
-- + environnement d'envoi. Le volume approuvé est vérifié à part (H13).
create or replace function public.communication_empreinte_campagne(p public.communication_campagnes)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select encode(extensions.digest(jsonb_build_object(
    'canaux', to_jsonb(p.canaux), 'criteres', p.criteres, 'langue_repli', p.langue_repli,
    'planifiee_le', p.planifiee_le, 'plafond_cout_usd', p.plafond_cout_usd,
    'plafond_messages', p.plafond_messages, 'essai', p.essai,
    'modeles', (select coalesce(jsonb_object_agg(m.id, jsonb_build_array(m.empreinte, m.empreinte_meta_approuvee)), '{}'::jsonb)
                  from public.communication_modeles m
                 where m.id::text in (select jsonb_path_query(p.modeles, '$.*.*') #>> '{}')),
    'environnement', public.communication_environnement_envoi()
  )::text, 'sha256'), 'hex')
$$;

-- 4.3 Le volume et le coût estimés d'une campagne aujourd'hui (comptage, pas de liste).
create or replace function public.communication_volume_campagne(p public.communication_campagnes)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_canal text;
  v_volume jsonb := '{}'::jsonb;
  v_n integer;
  v_somme numeric;
  v_cout numeric := 0;
begin
  foreach v_canal in array p.canaux loop
    select count(*) into v_n from public.communication_segment_clients(p.criteres) id
     where public.communication_raison_exclusion(id, v_canal, p.essai) is null;
    v_volume := v_volume || jsonb_build_object(v_canal, v_n);
    if v_canal = 'whatsapp' then
      select coalesce(sum(t.prix_usd), 0) into v_somme
        from public.communication_segment_clients(p.criteres) id
        join public.communication_tarifs t
          on t.fournisseur = 'meta' and t.canal = 'whatsapp' and t.categorie = 'marketing'
         and t.territoire = public.communication_territoire(public.communication_cible(id, 'whatsapp'))
       where public.communication_raison_exclusion(id, 'whatsapp', p.essai) is null;
      v_cout := v_cout + v_somme;
    end if;
  end loop;
  return jsonb_build_object('volume', v_volume, 'cout_estime_usd', v_cout,
                            'total', (select coalesce(sum(value::integer), 0) from jsonb_each_text(v_volume)));
end;
$$;

-- 4.4 Ce qui manque pour soumettre ou approuver.
create or replace function public.communication_manques(p public.communication_campagnes)
returns text[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v text[] := '{}';
  v_canal text;
  v_id text;
  v_code text;
  m public.communication_modeles;
begin
  if cardinality(p.canaux) = 0 then v := v || 'canaux'; end if;
  if p.planifiee_le is null then v := v || 'date'; end if;
  if p.plafond_messages <= 0 then v := v || 'plafond_messages'; end if;
  if 'whatsapp' = any (p.canaux) and p.plafond_cout_usd <= 0 then v := v || 'plafond_cout'; end if;
  foreach v_canal in array p.canaux loop
    if not (p.modeles ? v_canal) or not ((p.modeles -> v_canal) ? p.langue_repli) then
      v := v || ('modele_' || v_canal || '_' || p.langue_repli);
    end if;
    for v_id in select jsonb_path_query(p.modeles -> v_canal, '$.*') #>> '{}' loop
      select * into m from public.communication_modeles where id::text = v_id;
      if not found or m.canal <> v_canal or m.statut <> 'approuve' then
        v := v || ('modele_non_approuve_' || v_id);
      elsif v_canal = 'whatsapp' then
        v_code := public.communication_modele_meta_bloque(m.id, m.empreinte_meta_approuvee);
        if v_code is not null then v := v || (v_code || '_' || v_id); end if;
      end if;
    end loop;
  end loop;
  return v;
end;
$$;

-- 4.5 Écrire ou modifier un brouillon (créer : p_campagne null). Seulement à l'état brouillon.
create or replace function public.ecrire_campagne_communication(p_campagne uuid, p_champs jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid := p_campagne;
  v_statut text;
begin
  perform public.exiger_permission('communications.create');
  if p_champs ? 'criteres' then
    perform public.communication_criteres_valides(p_champs -> 'criteres');
  end if;
  if v_id is null then
    insert into public.communication_campagnes (nom, cree_par) values (coalesce(p_champs ->> 'nom', 'Sans nom'), auth.uid())
    returning id into v_id;
  else
    select statut into v_statut from public.communication_campagnes where id = v_id for update;
    if v_statut is distinct from 'brouillon' then
      perform public.erreur_metier('CAMPAIGN_LOCKED', 'Seul un brouillon se modifie : remettez la campagne en brouillon.');
    end if;
  end if;
  begin
    update public.communication_campagnes set
      nom = coalesce(p_champs ->> 'nom', nom),
      description = coalesce(p_champs ->> 'description', description),
      canaux = coalesce((select array_agg(x) from jsonb_array_elements_text(p_champs -> 'canaux') x), canaux),
      segment_id = case when p_champs ? 'segment_id' then (p_champs ->> 'segment_id')::uuid else segment_id end,
      criteres = coalesce(p_champs -> 'criteres', criteres),
      modeles = coalesce(p_champs -> 'modeles', modeles),
      langue_repli = coalesce(p_champs ->> 'langue_repli', langue_repli),
      planifiee_le = case when p_champs ? 'planifiee_le' then (p_champs ->> 'planifiee_le')::timestamptz else planifiee_le end,
      plafond_cout_usd = coalesce((p_champs ->> 'plafond_cout_usd')::numeric, plafond_cout_usd),
      plafond_messages = coalesce((p_champs ->> 'plafond_messages')::integer, plafond_messages),
      essai = coalesce((p_champs ->> 'essai')::boolean, essai),
      maj_le = now(), maj_par = auth.uid()
    where id = v_id;
  exception when invalid_text_representation or check_violation or numeric_value_out_of_range or invalid_datetime_format then
    perform public.erreur_metier('INVALID_VALUE', 'Valeur refusée : vérifiez les champs de la campagne.');
  end;
  perform public.auditer('communication.campagne_ecrite', 'communication_campagne', v_id::text, null, p_champs);
  return v_id;
end;
$$;

-- 4.6 Les transitions. Une seule porte ; chaque passage est journalisé ; le verrou de la ligne
-- de campagne est pris AVANT toute lecture, et le travailleur le prend aussi (revue 1.1, M7).
-- Ordre des verrous (Phase 1.3, C2 ; 40 §3) : campagne (N1) PUIS envois (N4). Le travailleur
-- prend lui aussi la campagne AVANT l'envoi (43 §8) : une annulation et un envoi de la même
-- campagne ne peuvent plus s'attendre l'un l'autre. Si le travailleur tient la campagne,
-- l'annulation attend la fin de SON envoi (quelques millisecondes) : ce message-là est parti
-- (« traitement »), les autres sont annulés. Si l'annulation passe d'abord, le travailleur
-- relit « annulee » et n'envoie rien.
create or replace function public.changer_statut_campagne(p_campagne uuid, p_action text, p_motif text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  p public.communication_campagnes;
  r public.communication_reglages;
  v_manques text[];
  v_nouveau text;
  v_volume jsonb;
begin
  -- 1.3.1 (IR-17) : action connue et droit minimal AVANT tout verrou ou lecture (un client ne
  -- doit pas pouvoir savoir si une campagne existe, ni verrouiller une ligne)
  if p_action is null or p_action not in ('soumettre', 'retirer', 'approuver', 'refuser', 'remettre_en_brouillon',
                                          'mettre_en_pause', 'reprendre', 'annuler') then
    perform public.erreur_metier('INVALID_ACTION', 'Action inconnue.');
  end if;
  if not (public.peut('communications.create') or public.peut('communications.pause')
          or public.peut('communications.approve')) then
    perform public.exiger_permission('communications.create');
  end if;
  select * into p from public.communication_campagnes where id = p_campagne for update;
  if not found then
    perform public.erreur_metier('NOT_FOUND', 'Campagne introuvable.');
  end if;
  select * into r from public.communication_reglages;

  case p_action
  when 'soumettre' then
    perform public.exiger_permission('communications.create');
    if p.statut <> 'brouillon' then perform public.erreur_metier('INVALID_TRANSITION', 'Seul un brouillon se soumet.'); end if;
    update public.communication_campagnes
       set criteres = coalesce((select s.criteres from public.communication_segments s where s.id = p.segment_id), p.criteres)
     where id = p.id returning * into p;
    v_manques := public.communication_manques(p);
    if cardinality(v_manques) > 0 then
      perform public.erreur_metier('CAMPAIGN_INCOMPLETE', 'Il manque : ' || array_to_string(v_manques, ', '));
    end if;
    update public.communication_campagnes
       set soumise_par = auth.uid(), soumise_le = now(), empreinte = public.communication_empreinte_campagne(p)
     where id = p.id;
    v_nouveau := 'en_attente_approbation';

  when 'retirer' then
    perform public.exiger_permission('communications.create');
    if p.statut <> 'en_attente_approbation' then perform public.erreur_metier('INVALID_TRANSITION', 'Rien à retirer.'); end if;
    v_nouveau := 'brouillon';

  when 'approuver' then
    perform public.exiger_permission('communications.approve');
    if p.statut <> 'en_attente_approbation' then perform public.erreur_metier('INVALID_TRANSITION', 'Rien à approuver.'); end if;
    if r.quatre_yeux and p.cree_par = auth.uid() then
      perform public.erreur_metier('FOUR_EYES', 'Un autre administrateur doit approuver une campagne que vous avez créée.');
    end if;
    if public.communication_empreinte_campagne(p) is distinct from p.empreinte then
      perform public.erreur_metier('FINGERPRINT_CHANGED',
        'La campagne, un modèle ou l''environnement d''envoi a changé depuis la soumission : soumettez-la de nouveau.');
    end if;
    v_manques := public.communication_manques(p);
    if cardinality(v_manques) > 0 then
      perform public.erreur_metier('CAMPAIGN_INCOMPLETE', 'Il manque : ' || array_to_string(v_manques, ', '));
    end if;
    -- L'administrateur approuve un VOLUME et un COÛT réels, dans les plafonds (revue 1.1, H13)
    v_volume := public.communication_volume_campagne(p);
    if (v_volume ->> 'total')::integer > p.plafond_messages
       or ('whatsapp' = any (p.canaux) and (v_volume ->> 'cout_estime_usd')::numeric > p.plafond_cout_usd) then
      perform public.erreur_metier('CAPS_TOO_LOW',
        'Le volume (' || (v_volume ->> 'total') || ') ou le coût estimé dépasse les plafonds de la campagne.');
    end if;
    update public.communication_campagnes
       set approuvee_par = auth.uid(), approuvee_le = now(), empreinte_approuvee = p.empreinte,
           audience_approuvee = v_volume -> 'volume', cout_estime_approuve = (v_volume ->> 'cout_estime_usd')::numeric,
           seuil_croissance_pct = r.seuil_croissance_pct, motif_refus = null, arret_motif = null
     where id = p.id;
    v_nouveau := 'programmee';

  when 'refuser' then
    perform public.exiger_permission('communications.approve');
    if p.statut <> 'en_attente_approbation' then perform public.erreur_metier('INVALID_TRANSITION', 'Rien à refuser.'); end if;
    if length(trim(coalesce(p_motif, ''))) < 5 then perform public.erreur_metier('REASON_REQUIRED', 'Dites pourquoi.'); end if;
    update public.communication_campagnes set motif_refus = trim(p_motif) where id = p.id;
    v_nouveau := 'brouillon';

  when 'remettre_en_brouillon' then
    perform public.exiger_permission('communications.create');
    if p.statut not in ('programmee', 'en_pause', 'en_attente_approbation') or p.lancee_le is not null then
      perform public.erreur_metier('INVALID_TRANSITION', 'Une campagne déjà lancée ne revient pas en brouillon : annulez-la.');
    end if;
    update public.communication_campagnes
       set approuvee_par = null, approuvee_le = null, empreinte_approuvee = null, audience_approuvee = null,
           cout_estime_approuve = null
     where id = p.id;
    v_nouveau := 'brouillon';

  when 'mettre_en_pause' then
    perform public.exiger_permission('communications.pause');
    if p.statut not in ('programmee', 'en_cours') then perform public.erreur_metier('INVALID_TRANSITION', 'Rien à mettre en pause.'); end if;
    update public.communication_campagnes set arret_motif = coalesce(nullif(trim(p_motif), ''), 'PAUSE_MANUELLE') where id = p.id;
    v_nouveau := 'en_pause';

  when 'reprendre' then
    perform public.exiger_permission('communications.approve');
    if p.statut <> 'en_pause' then perform public.erreur_metier('INVALID_TRANSITION', 'La campagne n''est pas en pause.'); end if;
    if p.empreinte_approuvee is distinct from public.communication_empreinte_campagne(p) then
      perform public.erreur_metier('FINGERPRINT_CHANGED', 'La campagne ou son environnement a changé depuis l''approbation : remettez-la en brouillon.');
    end if;
    update public.communication_campagnes set arret_motif = null where id = p.id;
    v_nouveau := case when p.lancee_le is null then 'programmee' else 'en_cours' end;

  when 'annuler' then
    if p.statut in ('brouillon', 'en_attente_approbation') then
      perform public.exiger_permission('communications.create');
    else
      perform public.exiger_permission('communications.approve');
    end if;
    if p.statut in ('terminee', 'annulee', 'echec') then perform public.erreur_metier('INVALID_TRANSITION', 'Campagne déjà close.'); end if;
    if length(trim(coalesce(p_motif, ''))) < 5 then perform public.erreur_metier('REASON_REQUIRED', 'Dites pourquoi.'); end if;
    -- Ce qui n'est pas parti ne partira pas ; ce qui est parti ou incertain garde son statut.
    -- 1.3.1 (IR-13) : lignes verrouillées d'abord PAR IDENTIFIANT CROISSANT (même règle que la
    -- purge) : deux opérations sur des ensembles qui se recoupent ne peuvent plus s'attendre.
    perform 1 from public.communication_envois
     where campagne_id = p.id and statut in ('attente', 'nouvel_essai') order by id for update;
    update public.communication_envois set statut = 'annule', maj_le = now()
     where campagne_id = p.id and statut in ('attente', 'nouvel_essai');
    update public.communication_campagnes set arret_motif = trim(p_motif), terminee_le = now() where id = p.id;
    v_nouveau := 'annulee';

  else
    perform public.erreur_metier('INVALID_ACTION', 'Action inconnue.');
  end case;

  update public.communication_campagnes set statut = v_nouveau, maj_le = now(), maj_par = auth.uid() where id = p.id;
  perform set_config('goship.motif', coalesce(trim(p_motif), ''), true);
  perform public.auditer('communication.campagne_' || p_action, 'communication_campagne', p.id::text,
                         jsonb_build_object('statut', p.statut), jsonb_build_object('statut', v_nouveau));
  return jsonb_build_object('id', p.id, 'statut', v_nouveau);
end;
$$;


-- 5. L'audience figée --------------------------------------------------------------------------------
-- Constituée AU LANCEMENT par le travailleur (43 §6), après le contrôle du volume. Une ligne par
-- client et par canal, retenue ou exclue avec sa raison, avec l'EMPREINTE DU CONTACT visé et son
-- territoire (revue 1.1, H5). Immuable (sauf purge approuvée) : c'est la preuve de qui était
-- visé. Le consentement, la suppression et le contact sont revérifiés avant chaque envoi : un
-- retrait gagne toujours ; un contact changé depuis le gel n'est jamais utilisé.
create table if not exists public.communication_destinataires (
  id               bigint generated always as identity primary key,
  campagne_id      uuid not null references public.communication_campagnes (id),
  client_id        uuid,
  canal            text not null check (canal in ('email', 'whatsapp')),
  langue           text not null,
  modele_id        uuid references public.communication_modeles (id),
  cible_empreinte  text,
  territoire       text,
  retenu           boolean not null,
  raison           text,
  cree_le          timestamptz not null default now(),
  unique (campagne_id, client_id, canal)
);
create index if not exists communication_destinataires_modele_idx on public.communication_destinataires (modele_id);
create index if not exists communication_destinataires_client_idx on public.communication_destinataires (client_id) where client_id is not null;
alter table public.communication_destinataires enable row level security;
revoke all on public.communication_destinataires from anon, authenticated, service_role;
drop trigger if exists communication_destinataires_immuable on public.communication_destinataires;
create trigger communication_destinataires_immuable
  before update or delete on public.communication_destinataires
  for each row execute function public.communication_immuable();


-- 6. Droits ------------------------------------------------------------------------------------------
do $droits$
declare
  f text;
begin
  foreach f in array array[
    'public.communication_empreinte_modele(public.communication_modeles)',
    'public.communication_modele_fige()',
    'public.communication_variables_permises(text)',
    'public.communication_texte_invalide(text, text)',
    'public.communication_valeurs_client(uuid)',
    'public.communication_rendre(text, uuid, text)',
    'public.communication_parametre_whatsapp_invalide(text)',
    'public.communication_normaliser_composants(jsonb)',
    'public.communication_demander_modele_meta(uuid)',
    'public.communication_lire_modeles_meta()',
    'public.communication_modele_meta_bloque(uuid, text)',
    'public.communication_criteres_valides(jsonb)',
    'public.communication_segment_clients(jsonb)',
    'public.communication_raison_exclusion(uuid, text, boolean)',
    'public.communication_environnement_envoi()',
    'public.communication_empreinte_campagne(public.communication_campagnes)',
    'public.communication_volume_campagne(public.communication_campagnes)',
    'public.communication_manques(public.communication_campagnes)'] loop
    execute 'revoke execute on function ' || f || ' from public, anon, authenticated, service_role';
  end loop;
  foreach f in array array[
    'public.apercu_audience_communication(jsonb, text[], boolean)',
    'public.ecrire_campagne_communication(uuid, jsonb)',
    'public.changer_statut_campagne(uuid, text, text)'] loop
    execute 'revoke execute on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end
$droits$;
-- Phase 2, même forme (permission, liste blanche de champs, journal) :
--   ecrire_modele_communication (communications.create ; validation communication_texte_invalide,
--     empreinte calculée par la base ; une modification d'un modèle approuvé crée une version),
--   soumettre_modele_communication (create), approuver_modele_communication (approve : relit
--     Meta, exige une image fraîche APPROVED + MARKETING, pose empreinte_meta_approuvee),
--   archiver_modele_communication (approve), ecrire_segment_communication (create),
--   campagnes_communication / fiche_campagne_communication (view).
-- ===== FIN DU CONTENU INERTE =====
$brouillon_goship_non_executable$ as brouillon_non_executable;
