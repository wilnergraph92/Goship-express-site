-- =============================================================================
-- Goship Express — le moteur d'événements (Phase 3, 25/09/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier > Run. Sans risque : aucune donnée n'est supprimée, aucun événement
-- passé n'est réécrit, et le script peut être relancé autant de fois qu'on
-- veut.
--
-- Ordre d'installation : supabase.sql, supabase-facturation.sql,
-- supabase-services.sql, puis ce fichier. Après une mise à jour de l'un des
-- trois premiers, relancez aussi celui-ci.
--
-- L'idée. Un colis a un STATUT — où il en est, en un mot, celui que voit le
-- client — et une HISTOIRE — tout ce qui lui est arrivé. Les deux ne se
-- confondent pas : un colis peut être inspecté, consolidé, chargé dans un
-- conteneur, et rester « Reçu » tout du long. Chaque chose qui arrive est un
-- ÉVÉNEMENT, écrit dans colis_historique ; certains événements changent le
-- statut, d'autres non.
--
--     opération ──► événement ──► validation ──► transition ──► statut
--                                                              ──► historique
--
-- Une seule porte : executer_operation. Elle vérifie la permission, verrouille
-- le colis, lit son statut, valide l'opération, écrit l'événement et change le
-- statut dans la même transaction. Le statut d'un colis ne peut plus changer
-- autrement (déclencheur verrou_statut) ; un événement écrit ne se modifie ni
-- ne s'efface (déclencheur evenement_immuable).
--
-- Les statuts restent ceux du site et de l'application (supabase.sql,
-- partie 12) ; aucun n'est ajouté. Les événements, eux, sont plus fins :
-- voir types_evenement() ci-dessous.
--
-- Contenu :
--    1. colonnes et index
--    2. le catalogue des événements                    (EventService)
--    3. la machine à états                             (TransitionService)
--    4. l'écriture des événements : complétée, immuable
--    5. le statut ne change que par un événement
--    6. executer_operation : la seule porte            (TransitionService)
--    7. les fonctions du tableau de bord et du futur scanner
--    8. la lecture de l'historique                     (EventService)
--    9. droits d'exécution
-- =============================================================================


-- 1. Colonnes et index ---------------------------------------------------------
-- Les mêmes que dans supabase.sql (partie 2), répétées ici pour que ce fichier
-- tienne seul. Aucune n'en double une autre : l'événement réutilise les
-- colonnes qui existaient déjà —
--     statut   = le statut après l'événement      (new_status)
--     lieu     = où il s'est produit               (location)
--     note     = le message joint                  (notes)
--     cree_le  = quand, à l'heure de la base      (created_at)

alter table public.colis_historique add column if not exists type_evenement   text;
alter table public.colis_historique add column if not exists statut_precedent text;
alter table public.colis_historique add column if not exists auteur_id        uuid;
alter table public.colis_historique add column if not exists auteur_role      text;
alter table public.colis_historique add column if not exists metadonnees      jsonb not null default '{}'::jsonb;
alter table public.colis_historique add column if not exists cle_idempotence  text;
alter table public.colis_historique add column if not exists visibilite       text not null default 'publique'
  check (visibilite in ('publique', 'interne'));
alter table public.colis_historique add column if not exists corrige_id       bigint;

-- Une clé d'idempotence ne sert qu'une fois : c'est elle qui fait qu'un scan
-- répété, ou une requête renvoyée après une coupure, retrouve l'événement déjà
-- écrit au lieu d'en écrire un second.
create unique index if not exists colis_historique_cle_idx
  on public.colis_historique (cle_idempotence) where cle_idempotence is not null;
-- L'historique d'un colis, dans l'ordre où il a été écrit
create index if not exists colis_historique_ordre_idx on public.colis_historique (colis_id, id);
-- Recherches de l'équipe : par type, par date, par statut atteint, par auteur
create index if not exists colis_historique_type_idx on public.colis_historique (type_evenement, cree_le desc);
create index if not exists colis_historique_date_idx on public.colis_historique (cree_le desc);
create index if not exists colis_historique_statut_idx on public.colis_historique (statut, cree_le desc);
create index if not exists colis_historique_auteur_idx on public.colis_historique (auteur_id, cree_le desc)
  where auteur_id is not null;
-- « Cet événement a-t-il été corrigé ? » se pose à chaque lecture client
create index if not exists colis_historique_corrige_idx on public.colis_historique (corrige_id)
  where corrige_id is not null;


-- 2. Le catalogue des événements ----------------------------------------------
-- Chaque type d'événement dit :
--   statut      le statut qu'il donne au colis, ou null s'il n'en change pas
--   depuis      pour un événement sans changement de statut : les statuts où
--               il a un sens (on n'inspecte pas un colis déjà livré)
--   visibilite  « publique » : le client et le suivi public le voient ;
--               « interne »  : seulement l'équipe
--   permission  ce qu'il faut pour l'enregistrer (voir permissions_du_role)
--   special     « sortie » : quitte « Action requise » ;
--               « correction » : revient à l'étape d'avant, motif obligatoire ;
--               « mise_a_jour » : corrige le lieu ou le message de l'étape
--   lieu_requis vrai si l'événement n'a pas de sens sans lieu
--
-- Les opérations du futur scanner (recevoir, inspecter, emballer, charger,
-- expédier, arriver, transférer, rendre disponible, livrer, signaler) sont ces
-- événements-là : elles ne deviennent pas des statuts.
--
-- Ce catalogue existe aussi dans assets/js/api.js (TYPES_EVENEMENT), pour le
-- mode démonstration ; outils/essais-services/ vérifie qu'ils sont identiques.

create or replace function public.types_evenement()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'COLIS_RECU',       jsonb_build_object('libelle', 'Reçu à l''entrepôt', 'statut', 'recu', 'depuis', null,
                          'visibilite', 'publique', 'permission', 'shipments.create', 'special', null, 'lieu_requis', false),
    'COLIS_INSPECTE',   jsonb_build_object('libelle', 'Inspecté', 'statut', null, 'depuis', jsonb_build_array('recu', 'emballe'),
                          'visibilite', 'interne', 'permission', 'shipments.scan', 'special', null, 'lieu_requis', false),
    'COLIS_EMBALLE',    jsonb_build_object('libelle', 'Emballé', 'statut', 'emballe', 'depuis', null,
                          'visibilite', 'publique', 'permission', 'shipments.change_status', 'special', null, 'lieu_requis', false),
    'COLIS_CONSOLIDE',  jsonb_build_object('libelle', 'Consolidé', 'statut', null, 'depuis', jsonb_build_array('recu', 'emballe'),
                          'visibilite', 'interne', 'permission', 'shipments.scan', 'special', null, 'lieu_requis', false),
    'COLIS_CHARGE',     jsonb_build_object('libelle', 'Chargé', 'statut', null, 'depuis', jsonb_build_array('recu', 'emballe'),
                          'visibilite', 'interne', 'permission', 'shipments.scan', 'special', null, 'lieu_requis', false),
    'COLIS_EXPEDIE',    jsonb_build_object('libelle', 'Expédié', 'statut', 'embarque', 'depuis', null,
                          'visibilite', 'publique', 'permission', 'shipments.change_status', 'special', null, 'lieu_requis', false),
    'COLIS_ARRIVE',     jsonb_build_object('libelle', 'Arrivé au centre de distribution', 'statut', 'distribution', 'depuis', null,
                          'visibilite', 'publique', 'permission', 'shipments.change_status', 'special', null, 'lieu_requis', false),
    'COLIS_TRANSFERE',  jsonb_build_object('libelle', 'Transféré à la succursale', 'statut', 'succursale', 'depuis', null,
                          'visibilite', 'publique', 'permission', 'shipments.change_status', 'special', null, 'lieu_requis', false),
    'COLIS_DISPONIBLE', jsonb_build_object('libelle', 'Disponible', 'statut', 'disponible', 'depuis', null,
                          'visibilite', 'publique', 'permission', 'shipments.change_status', 'special', null, 'lieu_requis', true),
    'COLIS_LIVRE',      jsonb_build_object('libelle', 'Livré', 'statut', 'livre', 'depuis', null,
                          'visibilite', 'publique', 'permission', 'shipments.change_status', 'special', null, 'lieu_requis', false),
    'ACTION_REQUISE',   jsonb_build_object('libelle', 'Action requise', 'statut', 'incident', 'depuis', null,
                          'visibilite', 'publique', 'permission', 'shipments.change_status', 'special', null, 'lieu_requis', false),
    'ACTION_RESOLUE',   jsonb_build_object('libelle', 'Action résolue', 'statut', null, 'depuis', jsonb_build_array('incident'),
                          'visibilite', 'publique', 'permission', 'shipments.change_status', 'special', 'sortie', 'lieu_requis', false),
    'CORRECTION',       jsonb_build_object('libelle', 'Correction', 'statut', null, 'depuis', null,
                          'visibilite', 'interne', 'permission', 'shipments.correct', 'special', 'correction', 'lieu_requis', false),
    'MISE_A_JOUR',      jsonb_build_object('libelle', 'Étape mise à jour', 'statut', null, 'depuis', null,
                          'visibilite', 'publique', 'permission', 'shipments.change_status', 'special', 'mise_a_jour', 'lieu_requis', false))
$$;


-- 3. La machine à états --------------------------------------------------------
-- La matrice elle-même est transitions_statut() (supabase-services.sql,
-- partie 5) :
--
--   recu → (emballe) → embarque → (distribution) → (succursale) → disponible → livre
--   tout statut non livré → incident (Action requise)
--
-- nature_transition dit de quelle sorte est un passage d'un statut à un autre :
--   identique       même statut (on corrige le lieu ou le message)
--   normale         le parcours, dans le bon sens
--   sortie_incident de « Action requise » vers l'étape d'avant, ou une suivante
--   correction      retour à l'étape d'avant (événement CORRECTION seulement)
--   null            interdit
--
-- « Livré » est final : aucun événement ordinaire n'en sort. Seule une
-- CORRECTION, avec son motif, journalisée, peut le ramener à « Disponible ».

create or replace function public.nature_transition(p_de text, p_vers text, p_precedent text default null)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_vers is null or not (public.transitions_statut() ? p_vers) then null
    when p_de = p_vers then 'identique'
    -- Ancien statut d'avant le 19/09/2026 : la conversion reste possible
    when p_de is null or not (public.transitions_statut() ? p_de) then 'normale'
    when p_de = 'incident' then
      case when p_vers = coalesce(p_precedent, 'recu')
             or (p_vers <> 'incident'
                 and coalesce((public.transitions_statut() -> coalesce(p_precedent, 'recu')) ? p_vers, false))
           then 'sortie_incident' end
    when coalesce((public.transitions_statut() -> p_de) ? p_vers, false) then 'normale'
    when p_precedent is not null and p_vers = p_precedent then 'correction'
  end
$$;

-- L'événement qui fait passer d'un statut à un autre, quand on ne connaît que
-- le statut voulu (le tableau de bord coche un statut, pas un événement).
create or replace function public.type_pour_statut(p_de text, p_vers text, p_precedent text default null)
returns text
language sql
immutable
set search_path = ''
as $$
  select case public.nature_transition(p_de, p_vers, p_precedent)
    when 'identique' then 'MISE_A_JOUR'
    when 'correction' then 'CORRECTION'
    when 'sortie_incident' then 'ACTION_RESOLUE'
    when 'normale' then case p_vers
      when 'recu'         then 'COLIS_RECU'
      when 'emballe'      then 'COLIS_EMBALLE'
      when 'embarque'     then 'COLIS_EXPEDIE'
      when 'distribution' then 'COLIS_ARRIVE'
      when 'succursale'   then 'COLIS_TRANSFERE'
      when 'disponible'   then 'COLIS_DISPONIBLE'
      when 'livre'        then 'COLIS_LIVRE'
      when 'incident'     then 'ACTION_REQUISE'
    end
  end
$$;

-- canTransition / validateTransition : cette opération est-elle possible sur un
-- colis à ce statut ? Ne lit rien, n'écrit rien : la même réponse pour le
-- moteur, pour la liste des opérations possibles et pour le mode
-- démonstration. Réponse : { code (null si permis), detail, cible, nature }.
create or replace function public.valider_operation(p_actuel text, p_precedent text, p_type text,
                                                    p_cible text default null)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  t jsonb := public.types_evenement() -> p_type;
  v_special text;
  v_cible text;
  v_nature text;
  v_libelle text;
begin
  if t is null then
    return jsonb_build_object('code', 'EVENT_TYPE_INVALID', 'detail', 'Type d''événement inconnu : ' ||
                              coalesce(p_type, '(vide)') || '.', 'cible', null, 'nature', null);
  end if;
  v_special := t ->> 'special';
  v_libelle := t ->> 'libelle';

  if v_special = 'correction' then
    v_cible := coalesce(p_cible, p_precedent);
    v_nature := public.nature_transition(p_actuel, v_cible, p_precedent);
    if p_precedent is null or v_cible is distinct from p_precedent or v_nature is distinct from 'correction' then
      return jsonb_build_object('code', 'INVALID_STATUS_TRANSITION', 'cible', v_cible, 'nature', v_nature,
        'detail', 'Correction impossible : on ne revient qu''à l''étape précédente du colis' ||
                  case when p_precedent is not null then ' (' || public.texte_statut(p_precedent) || ')' else '' end || '.');
    end if;
  elsif v_special = 'sortie' then
    v_cible := coalesce(p_cible, p_precedent, 'recu');
    v_nature := public.nature_transition(p_actuel, v_cible, p_precedent);
    if p_actuel is distinct from 'incident' or v_nature is distinct from 'sortie_incident' then
      return jsonb_build_object('code', 'INVALID_STATUS_TRANSITION', 'cible', v_cible, 'nature', v_nature,
        'detail', 'Action résolue : le colis doit être en « Action requise » et reprendre son étape, ou une suivante.');
    end if;
  elsif v_special = 'mise_a_jour' then
    v_cible := p_actuel;
    v_nature := 'identique';
    if p_cible is not null and p_cible <> p_actuel then
      return jsonb_build_object('code', 'INVALID_EVENT_DATA', 'cible', p_cible, 'nature', null,
        'detail', 'Une mise à jour ne change pas le statut.');
    end if;
  elsif t ->> 'statut' is null then
    -- Opération sans changement de statut (inspection, consolidation…)
    v_cible := p_actuel;
    v_nature := 'identique';
    if p_cible is not null and p_cible <> p_actuel then
      return jsonb_build_object('code', 'INVALID_EVENT_DATA', 'cible', p_cible, 'nature', null,
        'detail', v_libelle || ' ne change pas le statut du colis.');
    end if;
    if t -> 'depuis' is not null and not ((t -> 'depuis') ? coalesce(p_actuel, '')) then
      return jsonb_build_object('code', 'INVALID_STATUS_TRANSITION', 'cible', v_cible, 'nature', null,
        'detail', v_libelle || ' : impossible au statut « ' || public.texte_statut(p_actuel) || ' ».');
    end if;
  else
    v_cible := t ->> 'statut';
    if p_cible is not null and p_cible <> v_cible then
      return jsonb_build_object('code', 'INVALID_EVENT_DATA', 'cible', p_cible, 'nature', null,
        'detail', v_libelle || ' mène au statut « ' || public.texte_statut(v_cible) || ' », pas ailleurs.');
    end if;
    if v_cible = p_actuel then
      return jsonb_build_object('code', 'STATUS_ALREADY_SET', 'cible', v_cible, 'nature', 'identique',
        'detail', 'Le colis est déjà au statut « ' || public.texte_statut(v_cible) || ' ».');
    end if;
    v_nature := public.nature_transition(p_actuel, v_cible, p_precedent);
    if v_nature is null or v_nature not in ('normale', 'sortie_incident') then
      return jsonb_build_object('code', 'INVALID_STATUS_TRANSITION', 'cible', v_cible, 'nature', v_nature,
        'detail', public.texte_statut(p_actuel) || ' → ' || public.texte_statut(v_cible) || ' : transition interdite.');
    end if;
  end if;

  return jsonb_build_object('code', null, 'detail', null, 'cible', v_cible, 'nature', v_nature);
end;
$$;


-- 4. L'écriture des événements --------------------------------------------------

-- Chaque ligne écrite dans l'historique passe par ici, quel que soit le chemin.
--   · Écrite par le moteur (executer_operation) : ses valeurs sont gardées,
--     sauf l'auteur et l'heure, que la base fixe toujours elle-même.
--   · Écrite par historiser_colis (supabase.sql) alors que le moteur a déjà
--     écrit l'événement de cette opération : c'est un doublon, on l'écarte.
--   · Écrite par historiser_colis pour un colis qui naît (creer_colis) ou dont
--     on corrige le lieu à la main : on la classe (COLIS_RECU, MISE_A_JOUR).
-- Jamais d'auteur, de date ou de type fournis par une page.
create or replace function public.completer_evenement()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_precedent text;
begin
  if coalesce(current_setting('goship.moteur_insere', true), '') = new.colis_id::text then
    return null;
  end if;

  new.auteur_id := auth.uid();
  new.auteur_role := (select role from public.clients where id = auth.uid());

  if coalesce(current_setting('goship.moteur', true), '') = 'on' then
    new.cree_le := now();
    return new;
  end if;

  select statut into v_precedent from public.colis_historique
   where colis_id = new.colis_id order by id desc limit 1;
  new.statut_precedent := v_precedent;
  new.type_evenement := case
    when v_precedent is null then 'COLIS_RECU'
    when v_precedent = new.statut then 'MISE_A_JOUR'
    else coalesce(public.type_pour_statut(v_precedent, new.statut, null), 'MISE_A_JOUR')
  end;
  new.metadonnees := case when v_precedent is null then jsonb_build_object('source', 'creation')
                          else '{}'::jsonb end;
  new.cle_idempotence := null;
  new.visibilite := 'publique';
  new.corrige_id := null;
  -- La première étape garde la date de réception saisie (historiser_colis) :
  -- c'est le moment où le colis est arrivé. Les suivantes, l'heure de la base.
  if v_precedent is not null then
    new.cree_le := now();
  end if;
  return new;
end;
$$;

drop trigger if exists completer_evenement on public.colis_historique;
create trigger completer_evenement
  before insert on public.colis_historique
  for each row execute function public.completer_evenement();

-- Un événement écrit est un fait : il ne se modifie pas et ne s'efface pas.
-- Une erreur se corrige par un nouvel événement (CORRECTION), qui dit ce qu'il
-- annule ; l'original reste lisible par l'équipe. Seule exception : la
-- suppression d'un colis emporte son historique (on delete cascade).
create or replace function public.evenement_immuable()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' and not exists (select 1 from public.colis where id = old.colis_id) then
    return old;
  end if;
  perform public.erreur_metier('EVENT_IMMUTABLE',
    'Un événement de l''historique ne se modifie pas : enregistrez une correction.');
  return null;
end;
$$;

drop trigger if exists evenement_immuable on public.colis_historique;
create trigger evenement_immuable
  before update or delete on public.colis_historique
  for each row execute function public.evenement_immuable();


-- 5. Le statut ne change que par un événement --------------------------------
-- executer_operation lève un drapeau, le temps de sa transaction, pour le
-- colis qu'elle traite. Toute autre modification du statut — ancienne page,
-- écriture directe, application — est refusée : il ne peut pas exister de
-- statut changé sans son événement.

create or replace function public.verrou_statut()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.statut is distinct from old.statut
     and coalesce(current_setting('goship.moteur_insere', true), '') <> new.id::text then
    perform public.erreur_metier('INVALID_STATUS_TRANSITION',
      'Le statut d''un colis ne change que par un événement (executer_operation).');
  end if;
  return new;
end;
$$;

drop trigger if exists verrou_statut on public.colis;
create trigger verrou_statut
  before update of statut on public.colis
  for each row execute function public.verrou_statut();


-- 6. executer_operation : la seule porte --------------------------------------
-- TransitionService.executeTransition. Dans une seule transaction :
--
--    1. type d'événement connu, permission du compte connecté
--    2. précisions (metadonnees) raisonnables, motif si c'est une correction
--    3. clé d'idempotence déjà vue ? → l'événement déjà écrit est rendu
--    4. colis verrouillé (FOR UPDATE) : deux opérations sur lui font la queue
--    5. statut attendu par la page ≠ statut réel ? → conflit, sauf si
--       l'opération est déjà faite (double scan) → l'événement déjà écrit
--    6. validation (valider_operation)
--    7. événement écrit, avec l'ancien et le nouveau statut
--    8. statut, lieu et message du colis mis à jour s'il y a lieu
--    9. journal d'audit (journaliser_colis ; une correction y est détaillée)
--
-- Le compte, l'heure, l'ancien statut ne sont jamais pris de la page : la base
-- les lit elle-même. p_cible ne sert qu'aux événements qui peuvent mener à
-- plusieurs statuts (ACTION_RESOLUE) ; pour les autres, il doit être vide ou
-- égal au statut que l'événement donne.
--
-- Réponse : { deja, change_statut, colis: {…}, evenement: {…} }.

create or replace function public.evenement_json(p_id bigint)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', h.id, 'colis_id', h.colis_id, 'type_evenement', h.type_evenement,
    'statut_precedent', h.statut_precedent, 'statut', h.statut, 'lieu', h.lieu, 'note', h.note,
    'metadonnees', h.metadonnees, 'auteur_id', h.auteur_id, 'auteur_role', h.auteur_role,
    'auteur', (select coalesce(nullif(c.nom_complet, ''), c.email) from public.clients c where c.id = h.auteur_id),
    'visibilite', h.visibilite, 'corrige_id', h.corrige_id,
    'corrige', exists (select 1 from public.colis_historique x where x.corrige_id = h.id),
    'cree_le', h.cree_le)
  from public.colis_historique h where h.id = p_id
$$;

create or replace function public.resultat_operation(p_colis uuid, p_evenement bigint, p_deja boolean)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'deja', p_deja,
    'change_statut', coalesce((e ->> 'statut_precedent') is distinct from (e ->> 'statut'), false)
                     and not p_deja,
    'colis', (select jsonb_build_object('id', c.id, 'numero', c.numero, 'statut', c.statut, 'lieu', c.lieu,
                                        'note', c.note, 'maj_le', c.maj_le)
              from public.colis c where c.id = p_colis),
    'evenement', e)
  from (select public.evenement_json(p_evenement) as e) x
$$;

create or replace function public.executer_operation(p_colis uuid, p_type text, p_lieu text default null,
                                                     p_note text default null, p_metadonnees jsonb default '{}',
                                                     p_cle text default null, p_statut_attendu text default null,
                                                     p_cible text default null, p_motif text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_type text := upper(trim(coalesce(p_type, '')));
  t jsonb := public.types_evenement() -> upper(trim(coalesce(p_type, '')));
  v_cle text := nullif(trim(coalesce(p_cle, '')), '');
  v_meta jsonb := coalesce(p_metadonnees, '{}'::jsonb);
  v_motif text := left(trim(coalesce(p_motif, '')), 300);
  c public.colis;
  v_precedent text;
  d public.colis_historique;
  v_validation jsonb;
  v_cible text;
  v_lieu text;
  v_note text;
  v_corrige bigint;
  v_id bigint;
begin
  if t is null then
    perform public.erreur_metier('EVENT_TYPE_INVALID', 'Type d''événement inconnu : ' || coalesce(p_type, '(vide)') || '.');
  end if;
  perform public.exiger_permission(t ->> 'permission');

  -- Les précisions : un objet, court, sans rien qui ressemble à un secret.
  -- Elles sont lues par l'équipe, et par le client pour ses propres colis.
  if jsonb_typeof(v_meta) <> 'object' then
    perform public.erreur_metier('INVALID_EVENT_DATA', 'Les précisions d''un événement sont un objet JSON.');
  end if;
  if length(v_meta::text) > 4000 then
    perform public.erreur_metier('INVALID_EVENT_DATA', 'Précisions trop longues (4 000 caractères au plus).');
  end if;
  if v_meta::text ~* '"[^"]*(pass|mot_de_passe|secret|token|jeton|api_?key|cle_api|service_role)[^"]*"\s*:' then
    perform public.erreur_metier('INVALID_EVENT_DATA', 'Aucun mot de passe, jeton ni clé dans les précisions d''un événement.');
  end if;
  if t ->> 'special' = 'correction' then
    if v_motif = '' then
      perform public.erreur_metier('INVALID_EVENT_DATA', 'Une correction exige son motif.');
    end if;
    v_meta := v_meta || jsonb_build_object('motif', v_motif);
  end if;
  if length(coalesce(p_lieu, '')) > 80 then
    perform public.erreur_metier('INVALID_LOCATION', 'Lieu trop long (80 caractères au plus).');
  end if;
  if length(coalesce(p_note, '')) > 300 then
    perform public.erreur_metier('INVALID_EVENT_DATA', 'Message trop long (300 caractères au plus).');
  end if;
  if v_cle is not null and length(v_cle) > 120 then
    perform public.erreur_metier('INVALID_EVENT_DATA', 'Clé de requête trop longue.');
  end if;

  -- Même clé : la même opération, déjà faite. On rend son résultat.
  if v_cle is not null then
    perform pg_advisory_xact_lock(hashtextextended('goship-evenement:' || v_cle, 0));
    select * into d from public.colis_historique where cle_idempotence = v_cle;
    if found then
      if d.colis_id <> p_colis or d.type_evenement is distinct from v_type then
        perform public.erreur_metier('DUPLICATE_OPERATION',
          'Cette clé de requête a déjà servi pour une autre opération.');
      end if;
      return public.resultat_operation(p_colis, d.id, true);
    end if;
  end if;

  select * into c from public.colis where id = p_colis for update;
  if not found then
    perform public.erreur_metier('SHIPMENT_NOT_FOUND', 'Aucun colis avec cet identifiant.');
  end if;
  v_precedent := public.statut_precedent(c.id, c.statut);
  select * into d from public.colis_historique where colis_id = c.id order by id desc limit 1;

  -- La page croyait le colis à un autre statut : quelqu'un est passé avant.
  -- Si ce quelqu'un a fait exactement cette opération (double clic, double
  -- scan, deux postes), elle est déjà faite ; sinon, c'est un conflit.
  if p_statut_attendu is not null and p_statut_attendu <> c.statut then
    if d.type_evenement = v_type
       and (t ->> 'statut' is null or t ->> 'statut' = c.statut) then
      return public.resultat_operation(c.id, d.id, true);
    end if;
    perform public.erreur_metier('STATUS_CONFLICT',
      c.numero || ' est passé à « ' || public.texte_statut(c.statut) || ' » entre-temps : rechargez-le.');
  end if;

  v_validation := public.valider_operation(c.statut, v_precedent, v_type, p_cible);
  if v_validation ->> 'code' = 'STATUS_ALREADY_SET' and d.type_evenement = v_type then
    return public.resultat_operation(c.id, d.id, true);     -- double scan
  end if;
  if v_validation ->> 'code' is not null then
    if v_validation ->> 'code' = 'INVALID_STATUS_TRANSITION' then
      raise log 'goship transition refusee numero=% statut=% evenement=%', c.numero, c.statut, v_type;
    end if;
    perform public.erreur_metier(v_validation ->> 'code', c.numero || ' — ' || (v_validation ->> 'detail'));
  end if;
  v_cible := v_validation ->> 'cible';

  -- Le lieu et le message : ceux donnés. À défaut, une opération qui ne
  -- change pas l'étape (inspection, mise à jour…) garde ceux du colis ; une
  -- nouvelle étape repart de zéro, comme dans le tableau de bord.
  if t ->> 'statut' is null and coalesce(t ->> 'special', 'mise_a_jour') = 'mise_a_jour' then
    v_lieu := trim(coalesce(p_lieu, c.lieu));
    v_note := trim(coalesce(p_note, case when t ->> 'special' = 'mise_a_jour' then c.note else '' end));
  elsif t ->> 'special' in ('correction', 'sortie') then
    -- Revenir à une étape, c'est la retrouver telle qu'elle était : son lieu
    -- (l'agence d'un colis « Disponible ») et son message, sauf s'ils sont
    -- donnés. Une sortie d'incident vers une étape nouvelle part de zéro.
    select h.lieu, h.note into v_lieu, v_note from public.colis_historique h
     where h.colis_id = c.id and h.statut = v_cible and h.visibilite = 'publique'
       and not exists (select 1 from public.colis_historique x where x.corrige_id = h.id)
     order by h.id desc limit 1;
    v_lieu := trim(coalesce(p_lieu, v_lieu, ''));
    v_note := trim(coalesce(p_note, v_note, ''));
  else
    v_lieu := trim(coalesce(p_lieu, ''));
    v_note := trim(coalesce(p_note, ''));
  end if;
  if (t ->> 'lieu_requis')::boolean and v_lieu = '' then
    perform public.erreur_metier('LOCATION_REQUIRED', 'Indiquez l''agence où le client peut retirer son colis.');
  end if;

  -- Mise à jour qui ne change rien, ou opération sans changement de statut
  -- répétée à l'identique dans les deux minutes (le même colis scanné deux
  -- fois) : rien de nouveau n'est écrit.
  if t ->> 'special' = 'mise_a_jour' and c.lieu = v_lieu and c.note = v_note then
    return public.resultat_operation(c.id, d.id, true);
  end if;
  if t ->> 'statut' is null and t ->> 'special' is null
     and d.type_evenement = v_type and d.lieu = v_lieu and d.note = v_note
     and d.cree_le > now() - interval '2 minutes' then
    return public.resultat_operation(c.id, d.id, true);
  end if;

  -- Une correction annule le dernier événement qui a mis le colis à son statut
  if t ->> 'special' = 'correction' then
    select id into v_corrige from public.colis_historique h
     where h.colis_id = c.id and h.statut = c.statut and h.visibilite = 'publique'
       and not exists (select 1 from public.colis_historique x where x.corrige_id = h.id)
     order by h.id desc limit 1;
  end if;

  perform set_config('goship.moteur', 'on', true);
  insert into public.colis_historique (colis_id, type_evenement, statut_precedent, statut, lieu, note,
                                       metadonnees, cle_idempotence, visibilite, corrige_id)
  values (c.id, v_type, c.statut, v_cible, v_lieu, v_note, v_meta, v_cle, t ->> 'visibilite', v_corrige)
  returning id into v_id;
  perform set_config('goship.moteur', '', true);

  if v_cible <> c.statut or t ->> 'special' = 'mise_a_jour' then
    perform set_config('goship.moteur_insere', c.id::text, true);
    update public.colis set statut = v_cible, lieu = v_lieu, note = v_note where id = c.id;
    perform set_config('goship.moteur_insere', '', true);
  end if;

  if t ->> 'special' = 'correction' then
    perform public.auditer('colis.correction', 'colis', c.id::text,
                           jsonb_build_object('statut', c.statut, 'evenement', v_corrige),
                           jsonb_build_object('statut', v_cible, 'evenement', v_id, 'motif', v_motif));
  end if;
  raise log 'goship evenement numero=% type=% de=% vers=% compte=%',
    c.numero, v_type, c.statut, v_cible, coalesce(auth.uid()::text, 'aucun');

  return public.resultat_operation(c.id, v_id, false);
end;
$$;


-- 7. Pour le tableau de bord et le futur scanner ------------------------------

-- Le scanner lit un code (numéro GSE ou suivi du vendeur) : même porte.
create or replace function public.executer_operation_par_reference(p_reference text, p_type text,
                                                                   p_lieu text default null,
                                                                   p_note text default null,
                                                                   p_metadonnees jsonb default '{}',
                                                                   p_cle text default null,
                                                                   p_statut_attendu text default null,
                                                                   p_cible text default null,
                                                                   p_motif text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ref text := upper(trim(coalesce(p_reference, '')));
  v_id uuid;
begin
  perform public.exiger_permission('shipments.scan');
  if length(v_ref) >= 4 then
    select id into v_id from public.colis
     where numero = v_ref or (suivi_transporteur <> '' and suivi_transporteur = v_ref)
     order by maj_le desc limit 1;
  end if;
  if v_id is null then
    perform public.erreur_metier('SHIPMENT_NOT_FOUND', 'Aucun colis ne porte le numéro ' || coalesce(p_reference, '') || '.');
  end if;
  return public.executer_operation(v_id, p_type, p_lieu, p_note, p_metadonnees, p_cle, p_statut_attendu,
                                   p_cible, p_motif);
end;
$$;

-- Ce qu'on peut faire sur ce colis maintenant : les boutons du futur scanner.
create or replace function public.operations_possibles(p_colis uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c public.colis;
  v_precedent text;
begin
  perform public.exiger_permission('shipments.scan');
  select * into c from public.colis where id = p_colis;
  if not found then
    perform public.erreur_metier('SHIPMENT_NOT_FOUND', 'Aucun colis avec cet identifiant.');
  end if;
  v_precedent := public.statut_precedent(c.id, c.statut);
  return jsonb_build_object(
    'statut', c.statut,
    'precedent', v_precedent,
    'operations', coalesce((
      select jsonb_agg(jsonb_build_object('type', k, 'libelle', public.types_evenement() -> k ->> 'libelle',
                                          'statut', v ->> 'cible',
                                          'change_statut', (v ->> 'cible') is distinct from c.statut)
                       order by k)
      from jsonb_object_keys(public.types_evenement()) k,
           lateral (select public.valider_operation(c.statut, v_precedent, k, null) as v) x
      where v ->> 'code' is null and public.peut(public.types_evenement() -> k ->> 'permission')), '[]'::jsonb));
end;
$$;

-- Les statuts qu'un colis peut prendre : ceux du parcours, et à part l'étape
-- d'avant, qui n'est permise que comme correction (avec son motif).
create or replace function public.statuts_possibles(p_colis uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_statut text;
  v_precedent text;
begin
  perform public.exiger_permission('shipments.change_status');
  select statut into v_statut from public.colis where id = p_colis;
  if not found then
    perform public.erreur_metier('SHIPMENT_NOT_FOUND', 'Aucun colis avec cet identifiant.');
  end if;
  v_precedent := public.statut_precedent(p_colis, v_statut);
  return jsonb_build_object(
    'actuel', v_statut,
    'precedent', v_precedent,
    'possibles', coalesce((
      select jsonb_agg(s order by n)
      from jsonb_object_keys(public.transitions_statut()) with ordinality as k(s, n)
      where public.nature_transition(v_statut, s, v_precedent) in ('identique', 'normale', 'sortie_incident')),
      '[]'::jsonb),
    'correction', case when public.nature_transition(v_statut, v_precedent, v_precedent) = 'correction'
                       then v_precedent end);
end;
$$;

-- Le changement de statut du tableau de bord (un colis, ou un lot) : chaque
-- statut coché devient l'événement qui y mène (type_pour_statut), écrit par
-- executer_operation.
--
-- Tout ou rien : si un seul colis du lot ne peut pas suivre, aucun ne change,
-- et la réponse dit lesquels bloquent. p_attendus : { id: statut affiché }.
-- p_cle : la clé de la demande ; chaque colis reçoit la sienne (clé:id), si
-- bien qu'une demande renvoyée après une coupure ne refait rien.
-- p_motif : obligatoire quand le statut coché est un retour en arrière.
drop function if exists public.changer_statut_colis(uuid[], text, text, text, jsonb);
create or replace function public.changer_statut_colis(p_ids uuid[], p_statut text, p_lieu text default '',
                                                       p_note text default '', p_attendus jsonb default null,
                                                       p_motif text default null, p_cle text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.colis;
  v_ids uuid[];
  v_lieu text := trim(coalesce(p_lieu, ''));
  v_note text := trim(coalesce(p_note, ''));
  v_attendu text;
  v_type text;
  v_plan jsonb := '[]'::jsonb;
  v_refus jsonb := '[]'::jsonb;
  v_inchanges int := 0;
  v_etape jsonb;
  r jsonb;
  v_modifies jsonb := '[]'::jsonb;
  v_evenements jsonb := '[]'::jsonb;
begin
  perform public.exiger_permission('shipments.change_status');
  if p_statut is null or not (public.transitions_statut() ? p_statut) then
    perform public.erreur_metier('INVALID_STATUS', 'Statut inconnu : ' || coalesce(p_statut, '(vide)') || '.');
  end if;
  if length(v_lieu) > 80 then
    perform public.erreur_metier('INVALID_LOCATION', 'Lieu trop long (80 caractères au plus).');
  end if;
  if p_statut = 'disponible' and v_lieu = '' then
    perform public.erreur_metier('LOCATION_REQUIRED', 'Indiquez l''agence où le client peut retirer son colis.');
  end if;
  select array_agg(distinct i) into v_ids from unnest(coalesce(p_ids, '{}')) i where i is not null;
  if v_ids is null then
    perform public.erreur_metier('INVALID_INPUT', 'Aucun colis choisi.');
  end if;
  if array_length(v_ids, 1) > 500 then
    perform public.erreur_metier('INVALID_INPUT', 'Au plus 500 colis à la fois.');
  end if;

  -- Premier tour : on verrouille (dans un ordre fixe, pour que deux lots qui
  -- se chevauchent fassent la queue au lieu de se bloquer) et on vérifie tout.
  for c in select * from public.colis where id = any (v_ids) order by id for update loop
    v_attendu := p_attendus ->> c.id::text;
    if p_cle is not null and exists (select 1 from public.colis_historique
                                     where cle_idempotence = p_cle || ':' || c.id) then
      v_inchanges := v_inchanges + 1;                    -- demande déjà traitée
    elsif c.statut = p_statut then
      if (v_attendu is not null and v_attendu <> p_statut) or (c.lieu = v_lieu and c.note = v_note) then
        v_inchanges := v_inchanges + 1;                  -- déjà fait, par nous ou un autre
      else
        v_plan := v_plan || jsonb_build_object('id', c.id, 'statut', c.statut, 'type', 'MISE_A_JOUR');
      end if;
    elsif v_attendu is not null and v_attendu <> c.statut then
      v_refus := v_refus || jsonb_build_object(
        'id', c.id, 'numero', c.numero, 'code', 'STATUS_CONFLICT', 'statut', c.statut,
        'detail', c.numero || ' est passé à « ' || public.texte_statut(c.statut) || ' » entre-temps : rechargez la liste.');
    else
      v_type := public.type_pour_statut(c.statut, p_statut, public.statut_precedent(c.id, c.statut));
      if v_type is null then
        v_refus := v_refus || jsonb_build_object(
          'id', c.id, 'numero', c.numero, 'code', 'INVALID_STATUS_TRANSITION', 'statut', c.statut,
          'detail', c.numero || ' : ' || public.texte_statut(c.statut) || ' → ' ||
                    public.texte_statut(p_statut) || ' interdit.');
      elsif v_type = 'CORRECTION' and trim(coalesce(p_motif, '')) = '' then
        v_refus := v_refus || jsonb_build_object(
          'id', c.id, 'numero', c.numero, 'code', 'INVALID_EVENT_DATA', 'statut', c.statut,
          'detail', c.numero || ' : revenir à « ' || public.texte_statut(p_statut) ||
                    ' » est une correction, donnez-en le motif.');
      else
        v_plan := v_plan || jsonb_build_object('id', c.id, 'statut', c.statut, 'type', v_type);
      end if;
    end if;
  end loop;

  select v_refus || coalesce(jsonb_agg(jsonb_build_object(
           'id', i, 'numero', null, 'code', 'SHIPMENT_NOT_FOUND', 'statut', null,
           'detail', 'Un colis choisi n''existe plus.')), '[]'::jsonb)
    into v_refus
    from unnest(v_ids) i
   where not exists (select 1 from public.colis where id = i);

  if jsonb_array_length(v_refus) > 0 then
    raise log 'goship changer_statut refuse vers=% refus=%', p_statut, jsonb_array_length(v_refus);
    return jsonb_build_object('modifies', 0, 'inchanges', 0, 'ids', '[]'::jsonb, 'evenements', '[]'::jsonb,
                              'refus', v_refus);
  end if;

  -- Second tour : chaque colis passe par le moteur
  for v_etape in select * from jsonb_array_elements(v_plan) loop
    r := public.executer_operation(
      (v_etape ->> 'id')::uuid, v_etape ->> 'type', v_lieu, v_note,
      jsonb_build_object('source', 'tableau_de_bord'),
      case when p_cle is not null then p_cle || ':' || (v_etape ->> 'id') end,
      v_etape ->> 'statut',
      case when v_etape ->> 'type' = 'ACTION_RESOLUE' then p_statut end,
      p_motif);
    if (r ->> 'deja')::boolean then
      v_inchanges := v_inchanges + 1;
    else
      v_modifies := v_modifies || to_jsonb(v_etape ->> 'id');
      v_evenements := v_evenements || (r -> 'evenement');
    end if;
  end loop;

  return jsonb_build_object('modifies', jsonb_array_length(v_modifies), 'inchanges', v_inchanges,
                            'ids', v_modifies, 'evenements', v_evenements, 'refus', '[]'::jsonb);
end;
$$;


-- 8. La lecture de l'historique (EventService) --------------------------------
-- Toujours dans l'ordre où les événements ont été écrits (id croissant) : deux
-- lectures donnent la même histoire, et la page n'a rien à reconstituer.

-- L'historique d'un colis. L'équipe voit tout : opérations internes, auteur,
-- précisions, corrections. Le client propriétaire voit ce que montre son
-- espace : les étapes publiques non annulées, sans auteur ni précisions
-- internes.
create or replace function public.historique_colis(p_colis uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_client uuid;
begin
  select client_id into v_client from public.colis where id = p_colis;
  if not found then
    perform public.erreur_metier('SHIPMENT_NOT_FOUND', 'Aucun colis avec cet identifiant.');
  end if;
  if public.peut('shipments.view_history') then
    return coalesce((select jsonb_agg(public.evenement_json(h.id) order by h.id)
                     from public.colis_historique h where h.colis_id = p_colis), '[]'::jsonb);
  end if;
  perform public.exiger_permission('shipments.view', v_client);
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', h.id, 'type_evenement', h.type_evenement,
                                        'statut_precedent', h.statut_precedent, 'statut', h.statut,
                                        'lieu', h.lieu, 'note', h.note, 'cree_le', h.cree_le)
                     order by h.id)
    from public.colis_historique h
    where h.colis_id = p_colis and h.visibilite = 'publique' and not public.evenement_corrige(h.id)),
    '[]'::jsonb);
end;
$$;

-- getLatestEvent : le dernier événement écrit pour ce colis
create or replace function public.dernier_evenement(p_colis uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('shipments.view_history');
  return public.evenement_json((select max(id) from public.colis_historique where colis_id = p_colis));
end;
$$;

-- getEventsByType / getEventsByDate : tous colis confondus, paginé
create or replace function public.rechercher_evenements(p_type text default null, p_depuis timestamptz default null,
                                                        p_jusqua timestamptz default null, p_statut text default null,
                                                        p_limite integer default 50, p_decalage integer default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_limite int := least(greatest(coalesce(p_limite, 50), 1), 500);
begin
  perform public.exiger_permission('shipments.view_history');
  return jsonb_build_object(
    'total', (select count(*) from public.colis_historique h
              where (p_type is null or h.type_evenement = p_type)
                and (p_statut is null or h.statut = p_statut)
                and (p_depuis is null or h.cree_le >= p_depuis)
                and (p_jusqua is null or h.cree_le < p_jusqua)),
    'lignes', coalesce((
      select jsonb_agg(public.evenement_json(x.id) || jsonb_build_object('numero', x.numero) order by x.cree_le desc, x.id desc)
      from (select h.id, h.cree_le, co.numero
            from public.colis_historique h join public.colis co on co.id = h.colis_id
            where (p_type is null or h.type_evenement = p_type)
              and (p_statut is null or h.statut = p_statut)
              and (p_depuis is null or h.cree_le >= p_depuis)
              and (p_jusqua is null or h.cree_le < p_jusqua)
            order by h.cree_le desc, h.id desc
            limit v_limite offset greatest(coalesce(p_decalage, 0), 0)) x), '[]'::jsonb));
end;
$$;


-- 9. Droits d'exécution --------------------------------------------------------

revoke execute on function public.completer_evenement() from public, anon, authenticated;
revoke execute on function public.evenement_immuable() from public, anon, authenticated;
revoke execute on function public.verrou_statut() from public, anon, authenticated;
revoke execute on function public.evenement_json(bigint) from public, anon, authenticated;
revoke execute on function public.resultat_operation(uuid, bigint, boolean) from public, anon, authenticated;

revoke execute on function public.types_evenement() from public, anon;
revoke execute on function public.nature_transition(text, text, text) from public, anon;
revoke execute on function public.type_pour_statut(text, text, text) from public, anon;
revoke execute on function public.valider_operation(text, text, text, text) from public, anon;
revoke execute on function public.executer_operation(uuid, text, text, text, jsonb, text, text, text, text) from public, anon;
revoke execute on function public.executer_operation_par_reference(text, text, text, text, jsonb, text, text, text, text)
  from public, anon;
revoke execute on function public.operations_possibles(uuid) from public, anon;
revoke execute on function public.statuts_possibles(uuid) from public, anon;
revoke execute on function public.changer_statut_colis(uuid[], text, text, text, jsonb, text, text) from public, anon;
revoke execute on function public.historique_colis(uuid) from public, anon;
revoke execute on function public.dernier_evenement(uuid) from public, anon;
revoke execute on function public.rechercher_evenements(text, timestamptz, timestamptz, text, integer, integer)
  from public, anon;

grant execute on function public.types_evenement() to authenticated;
grant execute on function public.nature_transition(text, text, text) to authenticated;
grant execute on function public.type_pour_statut(text, text, text) to authenticated;
grant execute on function public.valider_operation(text, text, text, text) to authenticated;
grant execute on function public.executer_operation(uuid, text, text, text, jsonb, text, text, text, text) to authenticated;
grant execute on function public.executer_operation_par_reference(text, text, text, text, jsonb, text, text, text, text)
  to authenticated;
grant execute on function public.operations_possibles(uuid) to authenticated;
grant execute on function public.statuts_possibles(uuid) to authenticated;
grant execute on function public.changer_statut_colis(uuid[], text, text, text, jsonb, text, text) to authenticated;
grant execute on function public.historique_colis(uuid) to authenticated;
grant execute on function public.dernier_evenement(uuid) to authenticated;
grant execute on function public.rechercher_evenements(text, timestamptz, timestamptz, text, integer, integer)
  to authenticated;


-- Contrôle ---------------------------------------------------------------------
select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('executer_operation', 'executer_operation_par_reference', 'operations_possibles',
                            'statuts_possibles', 'changer_statut_colis', 'historique_colis',
                            'dernier_evenement', 'rechercher_evenements'))                    as moteur_sur_8,
       (select count(*) from pg_trigger
        where tgname in ('completer_evenement', 'evenement_immuable', 'verrou_statut'))       as gardes_sur_3,
       (select count(*) from information_schema.columns
        where table_schema = 'public' and table_name = 'colis_historique'
          and column_name in ('type_evenement', 'statut_precedent', 'auteur_id', 'auteur_role', 'metadonnees',
                              'cle_idempotence', 'visibilite', 'corrige_id'))                  as colonnes_sur_8,
       (select count(*) from public.colis_historique where type_evenement is null)            as evenements_anterieurs;
