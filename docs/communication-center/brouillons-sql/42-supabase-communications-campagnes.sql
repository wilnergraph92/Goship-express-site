-- =============================================================================
-- BROUILLON — PHASE 1 DU CENTRE DE COMMUNICATION — NE PAS EXÉCUTER
-- (voir l'en-tête de 40-supabase-communications-fondation.sql)
-- =============================================================================
do $brouillon$
begin
  raise exception 'BROUILLON NON APPROUVÉ (Phase 1 du Centre de communication) : ne pas exécuter.';
end;
$brouillon$;

-- =============================================================================
-- Goship Express — Centre de communication : modèles, segments, campagnes, audience,
-- approbation (brouillon du 18/11/2026). À la suite de 41-…-consentement.
--
-- Cycle d'une campagne (décision D-D : le gérant crée, modifie et programme ;
-- l'administrateur APPROUVE, sans quoi rien ne part) :
--
--   brouillon ──soumettre──► en_attente_approbation ──approuver (admin)──► programmee
--      ▲    ◄──retirer / refuser (motif)──┘                                   │ heure venue,
--      └──────────────── remettre_en_brouillon (avant lancement) ─────────────┤ interrupteurs allumés
--                                                                              ▼
--   annulee ◄── annuler ── (tout état non terminé)              en_cours ──► terminee
--                                                    en_pause ◄──┘  ▲          (ou echec)
--                                                        └reprendre (admin)┘
--
-- L'approbation porte une EMPREINTE (canaux, critères, modèles et leurs versions, heure,
-- plafonds) : toute modification après soumission oblige à soumettre de nouveau ; une
-- campagne approuvée dont l'empreinte ne correspond plus ne part pas.
-- =============================================================================


-- 1. Les modèles de messages -------------------------------------------------------------
-- Un modèle = un canal, une langue, un texte. Variables permises (liste fermée, celles que la
-- base connaît vraiment) : {{prenom}}, {{nom_complet}}, {{code}}, {{adresse_miami}} (refusée
-- tant que l'adresse canonique n'est pas validée : D-H). Pas d'e-mail ni de téléphone dans un
-- message commercial (minimisation) : à demander explicitement si le CEO le veut.
-- Une variable peut avoir un repli écrit par l'auteur : {{prenom|Bonjour}}. Sans repli, un
-- destinataire à qui la valeur manque est EXCLU de l'audience (raison VARIABLE_MANQUANTE) :
-- jamais de message avec une variable non résolue.
-- WhatsApp : le texte est celui du modèle approuvé chez Meta ; on garde son nom, sa langue
-- Meta et l'ordre des variables (paramètres {{1}}, {{2}}… chez Meta).
create table if not exists public.communication_modeles (
  id                 uuid primary key default gen_random_uuid(),
  nom                text not null check (length(nom) between 2 and 80),
  canal              text not null check (canal in ('email', 'whatsapp')),
  langue             text not null check (langue in ('fr', 'en', 'es', 'ht')),
  version            integer not null default 1,
  statut             text not null default 'brouillon' check (statut in ('brouillon', 'soumis', 'approuve', 'archive')),
  sujet              text check (sujet is null or length(sujet) between 2 and 150),       -- e-mail
  corps              text not null check (length(corps) between 2 and 5000),              -- texte, sans HTML
  variables          text[] not null default '{}',                                         -- dans l'ordre d'apparition
  whatsapp_nom_meta  text check (whatsapp_nom_meta is null or whatsapp_nom_meta ~ '^[a-z0-9_]{1,512}$'),
  whatsapp_langue_meta text,                                                               -- ex. fr, en_US, es
  whatsapp_categorie text check (whatsapp_categorie is null or whatsapp_categorie in ('MARKETING', 'UTILITY')),
  whatsapp_statut_meta text not null default 'inconnu'
                     check (whatsapp_statut_meta in ('inconnu', 'approuve', 'rejete', 'en_pause', 'desactive')),
  empreinte          text not null,
  cree_par           uuid not null,
  cree_le            timestamptz not null default now(),
  approuve_par       uuid,
  approuve_le        timestamptz,
  remplace_id        uuid references public.communication_modeles (id),
  check (canal <> 'email' or sujet is not null),
  check (canal <> 'whatsapp' or (whatsapp_nom_meta is not null and whatsapp_langue_meta is not null and whatsapp_categorie is not null))
);
alter table public.communication_modeles enable row level security;
revoke all on public.communication_modeles from anon, authenticated;

-- Un modèle approuvé ne bouge plus (on en crée une nouvelle version).
create or replace function public.communication_modele_fige()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.statut = 'approuve' and (new.corps, new.sujet, new.variables, new.whatsapp_nom_meta, new.whatsapp_langue_meta)
     is distinct from (old.corps, old.sujet, old.variables, old.whatsapp_nom_meta, old.whatsapp_langue_meta) then
    raise exception 'TEMPLATE_LOCKED' using detail = 'Un modèle approuvé ne se modifie plus : créez une nouvelle version.', hint = 'goship';
  end if;
  return new;
end;
$$;
drop trigger if exists communication_modele_fige on public.communication_modeles;
create trigger communication_modele_fige before update on public.communication_modeles
  for each row execute function public.communication_modele_fige();

-- Les variables d'un texte, et leur validité.
create or replace function public.communication_variables_du_texte(p_texte text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select coalesce(array_agg(m[1] order by ord), '{}')
  from regexp_matches(coalesce(p_texte, ''), '\{\{\s*([a-z_]+)\s*(?:\|[^}]*)?\}\}', 'g') with ordinality as t(m, ord)
$$;

create or replace function public.communication_variables_permises()
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select array['prenom', 'nom_complet', 'code']
         || case when (select adresse_miami_validee from public.communication_reglages) then array['adresse_miami'] else '{}'::text[] end
$$;

-- Rendre un texte pour un client. Renvoie {ok, texte, manquantes}. Les valeurs viennent de la
-- base, jamais d'une page ; les accolades sont retirées des valeurs (un nom de client ne peut
-- pas glisser une variable). L'échappement HTML est fait par l'appelant e-mail.
create or replace function public.communication_rendre(p_texte text, p_client uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c public.clients;
  a jsonb;
  v_valeurs jsonb;
  v_texte text := coalesce(p_texte, '');
  v_manquantes text[] := '{}';
  m text[];
  v_val text;
begin
  select * into c from public.clients where id = p_client;
  a := public.adresse_miami();
  v_valeurs := jsonb_build_object(
    'prenom', nullif(regexp_replace(split_part(trim(coalesce(c.nom_complet, '')), ' ', 1), '[{}|]', '', 'g'), ''),
    'nom_complet', nullif(regexp_replace(trim(coalesce(c.nom_complet, '')), '[{}|]', '', 'g'), ''),
    'code', nullif(c.code, ''),
    'adresse_miami', case when coalesce(c.code, '') = '' then null else
       trim(regexp_replace(coalesce(c.nom_complet, ''), '[{}|]', '', 'g') || ' ' || c.code) || E'\n' ||
       (a ->> 'ligne1') || E'\n' || (a ->> 'ligne2') || E'\n' || (a ->> 'ville') || ', ' || (a ->> 'etat') || ' ' ||
       (a ->> 'zip') || E'\n' || (a ->> 'pays') end);
  for m in select regexp_matches(v_texte, '\{\{\s*([a-z_]+)\s*(\|([^}]*))?\}\}', 'g') loop
    if not m[1] = any (public.communication_variables_permises()) then
      v_manquantes := v_manquantes || m[1];
      continue;
    end if;
    v_val := coalesce(v_valeurs ->> m[1], nullif(trim(m[3]), ''));
    if v_val is null then
      v_manquantes := v_manquantes || m[1];
    end if;
  end loop;
  if cardinality(v_manquantes) > 0 then
    return jsonb_build_object('ok', false, 'manquantes', to_jsonb(v_manquantes));
  end if;
  -- Remplacer : variable par variable, repli compris
  for m in select regexp_matches(v_texte, '\{\{\s*([a-z_]+)\s*(\|([^}]*))?\}\}', 'g') loop
    v_texte := replace(v_texte, '{{' || m[1] || coalesce(m[2], '') || '}}',
                       coalesce(v_valeurs ->> m[1], trim(m[3])));
  end loop;
  if v_texte ~ '\{\{|\}\}' then
    return jsonb_build_object('ok', false, 'manquantes', jsonb_build_array('syntaxe'));
  end if;
  return jsonb_build_object('ok', true, 'texte', v_texte);
end;
$$;


-- 2. Les segments ------------------------------------------------------------------------
-- Des critères en liste fermée, jamais du SQL. Le consentement, la suppression, la cible
-- valide et la liste d'essai s'ajoutent TOUJOURS, quel que soit le segment.
--   inscrits_depuis_jours  entier : comptes créés il y a moins de N jours
--   sans_colis             vrai : aucun colis
--   actifs_jours           entier : au moins un colis créé dans les N derniers jours
--   inactifs_jours         entier : un colis déjà, mais aucun depuis N jours
--   colis_en_transit       vrai : au moins un colis pas encore livré
--   colis_livres           vrai : au moins un colis livré
--   pays                   ["HT","DO","US"]
--   langues                ["fr","en","es","ht"]
create table if not exists public.communication_segments (
  id        uuid primary key default gen_random_uuid(),
  nom       text not null check (length(nom) between 2 and 80),
  criteres  jsonb not null default '{}'::jsonb,
  cree_par  uuid not null,
  cree_le   timestamptz not null default now(),
  maj_le    timestamptz not null default now()
);
alter table public.communication_segments enable row level security;
revoke all on public.communication_segments from anon, authenticated;

create or replace function public.communication_criteres_valides(p_criteres jsonb)
returns void
language plpgsql
immutable
set search_path = ''
as $$
declare
  k text;
begin
  for k in select jsonb_object_keys(coalesce(p_criteres, '{}'::jsonb)) loop
    if k not in ('inscrits_depuis_jours', 'sans_colis', 'actifs_jours', 'inactifs_jours',
                 'colis_en_transit', 'colis_livres', 'pays', 'langues') then
      perform public.erreur_metier('INVALID_SEGMENT', 'Critère inconnu : ' || k);
    end if;
  end loop;
end;
$$;

-- Les clients d'un segment, AVANT les règles d'éligibilité (consentement, etc.).
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

-- L'éligibilité d'un client sur un canal : null si éligible, sinon la raison (un code).
-- Appelée à la constitution de l'audience ET juste avant chaque envoi.
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
  v_pays text;
begin
  select * into r from public.communication_reglages;
  if not exists (select 1 from public.clients where id = p_client and role = 'client' and supprime_le is null)
     and not public.communication_est_essai(p_client, p_canal) then
    return 'COMPTE_INACTIF';
  end if;
  -- Mode essai (réglage) ou envoi d'essai : la liste d'essai, et elle seule
  if (r.mode = 'essai' or p_essai) and not public.communication_est_essai(p_client, p_canal) then
    return 'HORS_LISTE_ESSAI';
  end if;
  v_cible := public.communication_cible(p_client, p_canal);
  if v_cible is null then
    return 'SANS_DESTINATAIRE';
  end if;
  if public.communication_supprimee(p_canal, v_cible) then
    return 'SUPPRIME';
  end if;
  -- Un compte de l'équipe sur la liste d'essai n'a pas de consentement commercial à donner :
  -- il reçoit les essais au titre de son travail (motif noté à l'inscription sur la liste)
  if not (p_essai and public.communication_est_essai(p_client, p_canal)
          and exists (select 1 from public.clients where id = p_client and role <> 'client'))
     and not public.communication_consentement_actuel(p_client, p_canal) then
    return 'SANS_CONSENTEMENT';
  end if;
  if p_canal = 'whatsapp' then
    v_pays := public.communication_pays_numero(v_cible);
    if v_pays is null then
      return 'NUMERO_INCONNU';
    end if;
    if exists (select 1 from public.communication_tarifs t
                where t.fournisseur = 'meta' and t.canal = 'whatsapp' and t.categorie = 'marketing'
                  and t.pays = v_pays and not t.autorise) then
      return 'PAYS_NON_AUTORISE';      -- ex. pause de Meta vers les numéros US
    end if;
  end if;
  return null;
end;
$$;

-- Aperçu d'audience : des NOMBRES seulement (par canal et par raison), jamais une liste.
create or replace function public.apercu_audience_communication(p_criteres jsonb, p_canaux text[])
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
        'segment', count(*),
        'eligibles', count(*) filter (where raison is null),
        'exclus', coalesce(jsonb_object_agg(raison, n) filter (where raison is not null), '{}'::jsonb))
      from (select raison, count(*) over (partition by raison) n
              from (select public.communication_raison_exclusion(id, v_canal, false) raison
                      from public.communication_segment_clients(p_criteres) id) x) y));
  end loop;
  return v_resultat;
end;
$$;


-- 3. Les campagnes ------------------------------------------------------------------------
create table if not exists public.communication_campagnes (
  id                  uuid primary key default gen_random_uuid(),
  nom                 text not null check (length(nom) between 2 and 120),
  description         text not null default '' check (length(description) <= 1000),
  statut              text not null default 'brouillon' check (statut in (
                        'brouillon', 'en_attente_approbation', 'programmee', 'en_cours',
                        'terminee', 'en_pause', 'annulee', 'echec')),
  canaux              text[] not null default '{}' check (canaux <@ array['email', 'whatsapp']::text[]),
  segment_id          uuid references public.communication_segments (id),
  criteres            jsonb not null default '{}'::jsonb,       -- copie figée à la soumission
  modeles             jsonb not null default '{}'::jsonb,       -- {"email":{"fr":uuid,…},"whatsapp":{…}}
  langue_repli        text not null default 'fr' check (langue_repli in ('fr', 'en', 'es', 'ht')),
  planifiee_le        timestamptz,
  plafond_cout_usd    numeric(10, 2) not null default 0 check (plafond_cout_usd >= 0),
  plafond_messages    integer not null default 0 check (plafond_messages >= 0),
  essai               boolean not null default false,           -- campagne d'essai : liste d'essai seulement
  empreinte           text,                                     -- calculée à la soumission
  empreinte_approuvee text,
  cree_par            uuid not null,
  cree_le             timestamptz not null default now(),
  soumise_par         uuid,
  soumise_le          timestamptz,
  approuvee_par       uuid,
  approuvee_le        timestamptz,
  motif_refus         text,
  lancee_le           timestamptz,
  terminee_le         timestamptz,
  arret_motif         text,
  messages_reserves   integer not null default 0,
  cout_reserve_usd    numeric(12, 5) not null default 0,
  maj_le              timestamptz not null default now(),
  maj_par             uuid
);
create index if not exists communication_campagnes_dues_idx
  on public.communication_campagnes (planifiee_le) where statut = 'programmee';
alter table public.communication_campagnes enable row level security;
revoke all on public.communication_campagnes from anon, authenticated;

-- L'empreinte : tout ce que l'administrateur approuve. Un modèle y entre par son identifiant
-- ET son empreinte de contenu (une nouvelle version change l'empreinte de la campagne).
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
    'modeles', (select coalesce(jsonb_object_agg(m.id, m.empreinte), '{}'::jsonb)
                  from public.communication_modeles m
                 where m.id::text in (select jsonb_path_query(p.modeles, '$.*.*') #>> '{}'))
  )::text, 'sha256'), 'hex')
$$;

-- Écrire ou modifier un brouillon (créer : p_campagne null). Seulement à l'état brouillon.
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
  perform public.auditer('communication.campagne_ecrite', 'communication_campagne', v_id::text, null, p_champs);
  return v_id;
end;
$$;

-- Les contrôles d'une campagne prête à être approuvée : la liste de ce qui manque.
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
      if not exists (select 1 from public.communication_modeles m
                      where m.id::text = v_id and m.canal = v_canal and m.statut = 'approuve'
                        and (v_canal <> 'whatsapp' or m.whatsapp_statut_meta = 'approuve')) then
        v := v || ('modele_non_approuve_' || v_id);
      end if;
    end loop;
  end loop;
  -- WhatsApp : tarifs VÉRIFIÉS pour les pays visés
  if 'whatsapp' = any (p.canaux) and exists (
       select 1 from public.communication_tarifs t
        where t.fournisseur = 'meta' and t.canal = 'whatsapp' and t.categorie = 'marketing' and t.autorise and not t.verifie) then
    v := v || 'tarifs_whatsapp_non_verifies';
  end if;
  return v;
end;
$$;

-- Les transitions. Une seule porte pour changer le statut ; chaque passage est journalisé.
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
begin
  select * into p from public.communication_campagnes where id = p_campagne for update;
  if not found then
    perform public.erreur_metier('NOT_FOUND', 'Campagne introuvable.');
  end if;
  select * into r from public.communication_reglages;

  case p_action
  when 'soumettre' then
    perform public.exiger_permission('communications.create');
    if p.statut <> 'brouillon' then perform public.erreur_metier('INVALID_TRANSITION', 'Seul un brouillon se soumet.'); end if;
    v_manques := public.communication_manques(p);
    if cardinality(v_manques) > 0 then
      perform public.erreur_metier('CAMPAIGN_INCOMPLETE', 'Il manque : ' || array_to_string(v_manques, ', '));
    end if;
    update public.communication_campagnes
       set statut = 'en_attente_approbation', soumise_par = auth.uid(), soumise_le = now(),
           criteres = coalesce((select s.criteres from public.communication_segments s where s.id = p.segment_id), p.criteres),
           maj_le = now(), maj_par = auth.uid()
     where id = p.id returning * into p;
    update public.communication_campagnes set empreinte = public.communication_empreinte_campagne(p) where id = p.id;
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
      perform public.erreur_metier('FINGERPRINT_CHANGED', 'La campagne ou un de ses modèles a changé depuis la soumission : elle doit être soumise de nouveau.');
    end if;
    v_manques := public.communication_manques(p);
    if cardinality(v_manques) > 0 then
      perform public.erreur_metier('CAMPAIGN_INCOMPLETE', 'Il manque : ' || array_to_string(v_manques, ', '));
    end if;
    update public.communication_campagnes
       set approuvee_par = auth.uid(), approuvee_le = now(), empreinte_approuvee = p.empreinte
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
    if p.statut not in ('programmee', 'en_pause') or p.lancee_le is not null then
      perform public.erreur_metier('INVALID_TRANSITION', 'Une campagne déjà lancée ne revient pas en brouillon : annulez-la.');
    end if;
    update public.communication_campagnes
       set approuvee_par = null, approuvee_le = null, empreinte_approuvee = null where id = p.id;
    v_nouveau := 'brouillon';

  when 'mettre_en_pause' then
    perform public.exiger_permission('communications.pause');
    if p.statut not in ('programmee', 'en_cours') then perform public.erreur_metier('INVALID_TRANSITION', 'Rien à mettre en pause.'); end if;
    update public.communication_campagnes set arret_motif = coalesce(trim(p_motif), 'PAUSE_MANUELLE') where id = p.id;
    v_nouveau := 'en_pause';

  when 'reprendre' then
    perform public.exiger_permission('communications.approve');
    if p.statut <> 'en_pause' then perform public.erreur_metier('INVALID_TRANSITION', 'La campagne n''est pas en pause.'); end if;
    if p.empreinte_approuvee is distinct from public.communication_empreinte_campagne(p) then
      perform public.erreur_metier('FINGERPRINT_CHANGED', 'La campagne a changé depuis l''approbation.');
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
    -- Ce qui n'est pas parti ne partira pas ; ce qui est parti garde son statut
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


-- 4. L'audience figée ---------------------------------------------------------------------
-- Constituée AU LANCEMENT (pas à l'approbation : un client qui retire son accord entre-temps
-- est exclu). Une ligne par client et par canal, retenu ou exclu avec sa raison. Le
-- consentement et la suppression sont revérifiés avant chaque envoi : un retrait gagne
-- toujours, même après la constitution de l'audience.
create table if not exists public.communication_destinataires (
  id              bigint generated always as identity primary key,
  campagne_id     uuid not null references public.communication_campagnes (id),
  client_id       uuid not null,
  canal           text not null check (canal in ('email', 'whatsapp')),
  langue          text not null,
  modele_id       uuid references public.communication_modeles (id),
  retenu          boolean not null,
  raison          text,
  cree_le         timestamptz not null default now(),
  unique (campagne_id, client_id, canal)
);
alter table public.communication_destinataires enable row level security;
revoke all on public.communication_destinataires from anon, authenticated;


-- 5. Droits -------------------------------------------------------------------------------
revoke execute on function public.communication_modele_fige() from public, anon, authenticated;
revoke execute on function public.communication_variables_du_texte(text) from public, anon, authenticated;
revoke execute on function public.communication_variables_permises() from public, anon, authenticated;
revoke execute on function public.communication_rendre(text, uuid) from public, anon, authenticated;
revoke execute on function public.communication_criteres_valides(jsonb) from public, anon, authenticated;
revoke execute on function public.communication_segment_clients(jsonb) from public, anon, authenticated;
revoke execute on function public.communication_raison_exclusion(uuid, text, boolean) from public, anon, authenticated;
revoke execute on function public.communication_empreinte_campagne(public.communication_campagnes) from public, anon, authenticated;
revoke execute on function public.communication_manques(public.communication_campagnes) from public, anon, authenticated;

revoke execute on function public.apercu_audience_communication(jsonb, text[]) from public, anon;
revoke execute on function public.ecrire_campagne_communication(uuid, jsonb) from public, anon;
revoke execute on function public.changer_statut_campagne(uuid, text, text) from public, anon;
grant execute on function public.apercu_audience_communication(jsonb, text[]) to authenticated;
grant execute on function public.ecrire_campagne_communication(uuid, jsonb) to authenticated;
grant execute on function public.changer_statut_campagne(uuid, text, text) to authenticated;
-- Phase 2 : ecrire_modele_communication, soumettre / approuver_modele_communication,
-- regler_statut_meta_modele, ecrire_segment_communication, campagnes_communication (liste),
-- fiche_campagne_communication — même forme (permission, liste blanche de champs, journal).
