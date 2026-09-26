-- =============================================================================
-- Goship Express — les règles métier dans la base (Phase 2, 25/09/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier > Run. Sans risque : aucune donnée n'est supprimée, aucune facture
-- ni aucun colis existant n'est recalculé, et le script peut être relancé
-- autant de fois qu'on veut.
--
-- Ordre d'installation sur une base neuve : supabase.sql, puis
-- supabase-facturation.sql, puis ce fichier.
--
-- Depuis la Phase 6, les erreurs métier et les permissions (erreur_metier,
-- permissions_du_role, peut, exiger_permission) vivent dans supabase.sql,
-- partie 4 : les règles de sécurité des tables de ce fichier-là s'en servent,
-- et une règle ne peut appeler qu'une fonction qui existe déjà. Ce fichier
-- garde la gestion des rôles de l'équipe (partie 4).
--
-- Pourquoi ce fichier. Jusqu'ici, les règles vivaient dans le navigateur de
-- l'équipe (assets/js/admin.js) : le prix était calculé par la page et envoyé
-- tel quel, n'importe quel statut pouvait suivre n'importe quel autre, et un
-- double clic pouvait créer deux colis ou deux factures. Une page se modifie
-- en trois clics dans la console du navigateur ; la base, non. Les règles
-- passent donc ici, à deux niveaux :
--
--   1. des DÉCLENCHEURS sur les tables (colis, factures, lignes). Ils
--      s'appliquent à tout le monde, quel que soit le chemin : le tableau de
--      bord, l'application mobile, une ancienne page restée en cache, le SQL
--      Editor. C'est la vraie barrière.
--   2. des FONCTIONS DE SERVICE (creer_colis, modifier_colis,
--      facturer_colis…) que le site appelle. Le changement de statut, lui,
--      passe par le moteur d'événements (outils/supabase-evenements.sql). Elles ajoutent ce qu'un
--      déclencheur ne sait pas faire : vérifier la permission, poser un verrou,
--      reconnaître une requête répétée, créer colis et facture d'un seul bloc,
--      et répondre par une erreur métier claire.
--
-- Les erreurs métier ont toutes la même forme : le message est un code
-- (INVALID_WEIGHT, INVALID_STATUS_TRANSITION…), le détail est une phrase en
-- français pour l'équipe, et l'indice vaut « goship ». assets/js/api.js les
-- reconnaît à cet indice. La liste complète est dans le README, « Les règles
-- métier ».
--
-- Contenu :
--    1. colonnes et index
--    2. erreurs métier                         (déplacé dans supabase.sql)
--    3. tarifs et prix                         (BillingService, côté calcul)
--    4. rôles de l'équipe                      (PermissionService)
--    5. statuts et transitions                 (StatusService)
--    6. journal d'audit                        (AuditService)
--    7. règles des colis (déclencheur)         (validation + prix + transitions)
--    8. règles des factures (déclencheurs)     (doublons, montants arrêtés)
--    9. fonctions de service des colis         (ShipmentService)
--   10. fonctions de service de facturation    (BillingService)
--   11. droits d'exécution
-- =============================================================================


-- 1. Colonnes et index ---------------------------------------------------------
-- Les colonnes de supabase-facturation.sql sont reprises ici (sans effet si
-- elles existent déjà) : ce fichier ne doit pas dépendre de l'ordre dans lequel
-- les autres ont été lancés.

alter table public.colis add column if not exists prix_usd     numeric(10, 2);
alter table public.colis add column if not exists tarif_lb_usd numeric(10, 2);
alter table public.factures add column if not exists frais_service_usd numeric(10, 2) not null default 0;
alter table public.factures add column if not exists montant_paye_usd  numeric(10, 2) not null default 0
  check (montant_paye_usd >= 0);
alter table public.facture_lignes add column if not exists quantite integer not null default 1 check (quantite > 0);
alter table public.facture_lignes add column if not exists poids_lb numeric(8, 2)
  check (poids_lb is null or poids_lb >= 0);

-- Clé d'idempotence : le tableau de bord tire une clé à l'ouverture du
-- formulaire et la renvoie à chaque nouvel essai. Si la connexion a coupé après
-- l'enregistrement mais avant la réponse, le second envoi retrouve le colis (ou
-- la facture) du premier au lieu d'en créer un deuxième.
alter table public.colis    add column if not exists cle_idempotence text;
alter table public.factures add column if not exists cle_idempotence text;
create unique index if not exists colis_cle_idempotence_idx
  on public.colis (cle_idempotence) where cle_idempotence is not null;
create unique index if not exists factures_cle_idempotence_idx
  on public.factures (cle_idempotence) where cle_idempotence is not null;

-- Les listes du tableau de bord filtrent par statut et trient par date : ces
-- index évitent de parcourir toute la table quand elle comptera des milliers
-- de colis.
create index if not exists colis_statut_maj_idx on public.colis (statut, maj_le desc);
create index if not exists colis_recu_idx on public.colis (recu_le desc);
create index if not exists colis_destination_idx on public.colis (pays_destination, maj_le desc);
-- « Ce colis est-il déjà facturé ? » se pose à chaque facture
create index if not exists facture_lignes_colis_idx on public.facture_lignes (colis_id);

-- Un numéro de suivi du vendeur ne désigne qu'un colis : le suivi public
-- (suivre_colis) le cherche par ce numéro, et deux colis le partageant
-- rendraient la réponse ambiguë. La règle est appliquée par regles_colis
-- (partie 7) ; l'index la rend incontournable. S'il existe déjà des doublons
-- dans la base, on ne peut pas le créer : on le dit, et la règle vaut quand
-- même pour tous les nouveaux colis.
do $$
begin
  if not exists (select 1 from pg_indexes
                 where schemaname = 'public' and indexname = 'colis_suivi_unique_idx') then
    if exists (select 1 from public.colis
               where suivi_transporteur <> ''
               group by suivi_transporteur having count(*) > 1) then
      raise notice 'Des colis partagent déjà un numéro de suivi vendeur : index unique non créé. Requête de contrôle à la fin de ce fichier.';
    else
      create unique index colis_suivi_unique_idx
        on public.colis (suivi_transporteur) where suivi_transporteur <> '';
    end if;
  end if;
end $$;


-- 2. Erreurs métier ------------------------------------------------------------
-- erreur_metier est définie dans supabase.sql, partie 4 (Phase 6).


-- 3. Tarifs et prix ------------------------------------------------------------
-- Les deux constantes de la maison. Elles existent aussi dans assets/js/api.js
-- (TARIF_LB_DEFAUT, FRAIS_SERVICE), pour l'aperçu du formulaire et le mode
-- démonstration ; outils/essais-services/ vérifie que les deux disent la même
-- chose. Ici, elles font foi.

create or replace function public.tarifs()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object('par_livre', 5, 'frais_service', 10)
$$;

-- Le prix du transport, au cent près : poids × tarif, arrondi comme un
-- comptable (0,005 monte). Le seul calcul de prix de tout le projet ; le
-- navigateur n'en fait qu'un aperçu.
create or replace function public.prix_transport(p_poids numeric, p_tarif numeric)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select round(coalesce(p_poids, 0) * coalesce(p_tarif, 0), 2)
$$;


-- 4. Rôles de l'équipe ----------------------------------------------------------
-- Les permissions de chaque rôle et leur vérification (permissions_du_role,
-- peut, exiger_permission) sont dans supabase.sql, partie 4. Ici : qui fait
-- partie de l'équipe, et comment un rôle se donne.
--
-- Un rôle se change par changer_role, et seulement avec roles.manage (les
-- administrateurs). Le déclencheur verrou_role (supabase.sql) refuse tout
-- autre chemin. Un administrateur ne change pas son propre rôle, et le
-- dernier administrateur ne peut pas être rétrogradé : personne ne peut se
-- donner plus de droits, ni retirer à la maison sa dernière clé.

create or replace function public.roles_equipe()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['employe', 'gerant', 'admin']
$$;

-- Les membres de l'équipe, pour l'onglet Équipe
create or replace function public.equipe()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('users.view');
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', c.id, 'nom_complet', c.nom_complet, 'email', c.email,
                                        'role', c.role, 'cree_le', c.cree_le, 'moi', c.id = auth.uid())
                     order by array_position(array['admin', 'gerant', 'employe'], c.role), c.nom_complet)
    from public.clients c
    where c.role = any (public.roles_equipe())), '[]'::jsonb);
end;
$$;

-- Donner un rôle à un compte, retrouvé par son adresse e-mail (ou son
-- identifiant). p_role : « client », « employe », « gerant » ou « admin ».
-- Réponse : { compte, ancien_role, nouveau_role, deja }
create or replace function public.changer_role(p_compte text, p_role text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.clients;
  v_role text := lower(trim(coalesce(p_role, '')));
  v_ref text := trim(coalesce(p_compte, ''));
  v_admins integer;
  v_avant text := coalesce(current_setting('goship.roles', true), '');
begin
  perform public.exiger_permission('roles.manage');
  if not (v_role = any (public.roles_equipe() || array['client'])) then
    perform public.erreur_metier('INVALID_ROLE', 'Rôle inconnu : ' || coalesce(nullif(v_role, ''), '(vide)') ||
                                 '. Choisissez client, employe, gerant ou admin.');
  end if;
  select * into c from public.clients
   where (v_ref ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' and id::text = lower(v_ref))
      or (v_ref <> '' and lower(email) = lower(v_ref))
   for update;
  if not found then
    perform public.erreur_metier('USER_NOT_FOUND',
      'Aucun compte avec l''adresse ' || v_ref || '. La personne doit d''abord créer son compte sur le site.');
  end if;
  if c.id = auth.uid() then
    perform public.erreur_metier('SELF_ROLE_CHANGE',
      'On ne change pas son propre rôle : demandez-le à un autre administrateur.');
  end if;
  if c.role = v_role then
    return jsonb_build_object('compte', jsonb_build_object('id', c.id, 'email', c.email, 'nom_complet', c.nom_complet),
                              'ancien_role', c.role, 'nouveau_role', v_role, 'deja', true);
  end if;
  if c.role = 'admin' then
    -- Le verrou met en file deux rétrogradations simultanées : la seconde voit la première
    perform pg_advisory_xact_lock(hashtextextended('goship-admins', 0));
    select count(*) into v_admins from public.clients where role = 'admin';
    if v_admins <= 1 then
      perform public.erreur_metier('LAST_ADMIN', 'C''est le dernier administrateur : nommez-en un autre d''abord.');
    end if;
  end if;

  perform set_config('goship.roles', 'on', true);
  -- Un compte qui redevient client retrouve un code client s'il n'en a plus
  update public.clients
     set role = v_role,
         code = case when v_role = 'client' and code is null then public.nouveau_code_client() else code end
   where id = c.id;
  perform set_config('goship.roles', v_avant, true);

  perform public.auditer('utilisateur.role', 'client', c.id::text,
                         jsonb_build_object('role', c.role, 'email', c.email),
                         jsonb_build_object('role', v_role, 'email', c.email));
  raise log 'goship role change compte=% de=% vers=% par=%', c.id, c.role, v_role, auth.uid();
  return jsonb_build_object('compte', jsonb_build_object('id', c.id, 'email', c.email, 'nom_complet', c.nom_complet),
                            'ancien_role', c.role, 'nouveau_role', v_role, 'deja', false);
end;
$$;


-- 5. Statuts et transitions ----------------------------------------------------
-- Le parcours normal :
--
--   recu → emballe → embarque → distribution → succursale → disponible → livre
--
-- « Emballé », « Centre de distribution » et « Transféré à la succursale » sont
-- des étapes facultatives : un colis peut partir sans être réemballé, ou
-- arriver directement à l'agence. Les autres ne se sautent pas — en
-- particulier, « Livré » exige « Disponible » : c'est à « Disponible » que le
-- client est prévenu, et on ne livre pas un colis dont personne n'a été averti.
--
-- « Action requise » (incident) peut interrompre tout colis non livré. Il en
-- sort en revenant à l'étape où il était, ou en passant à une étape qui l'aurait
-- suivie (le problème réglé, le colis a continué sa route).
--
-- Enfin, une erreur de saisie se corrige en revenant à l'étape précédente du
-- colis (celle d'avant dans son historique) — mais seulement par un événement
-- CORRECTION, avec son motif et la permission shipments.correct : c'est la
-- procédure explicite, journalisée, de outils/supabase-evenements.sql. « Livré »
-- par erreur redevient ainsi « Disponible », jamais par un simple clic.
--
-- Cette matrice existe aussi dans assets/js/api.js (REGLES.transitions), pour
-- griser les choix impossibles et pour le mode démonstration ;
-- outils/essais-services/ vérifie qu'elles sont identiques.

create or replace function public.transitions_statut()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'recu',         jsonb_build_array('emballe', 'embarque', 'incident'),
    'emballe',      jsonb_build_array('embarque', 'incident'),
    'embarque',     jsonb_build_array('distribution', 'succursale', 'disponible', 'incident'),
    'distribution', jsonb_build_array('succursale', 'disponible', 'incident'),
    'succursale',   jsonb_build_array('disponible', 'incident'),
    'disponible',   jsonb_build_array('livre', 'incident'),
    'livre',        jsonb_build_array(),
    'incident',     jsonb_build_array())
$$;

-- p_precedent : l'étape d'avant dans l'historique du colis (statut_precedent).
create or replace function public.transition_permise(p_de text, p_vers text, p_precedent text default null)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case
    when p_vers is null or not (public.transitions_statut() ? p_vers) then false
    -- Même statut : on met à jour le lieu ou le message de l'étape
    when p_de = p_vers then true
    -- Ancien statut d'avant le 19/09/2026 : la conversion doit rester possible
    when p_de is null or not (public.transitions_statut() ? p_de) then true
    -- Correction : retour à l'étape précédente
    when p_precedent is not null and p_vers = p_precedent then true
    -- Sortie d'incident : l'étape d'avant, ou l'une de celles qui la suivent
    when p_de = 'incident' then
      p_vers = coalesce(p_precedent, 'recu')
      or (p_vers <> 'incident'
          and coalesce((public.transitions_statut() -> coalesce(p_precedent, 'recu')) ? p_vers, false))
    else coalesce((public.transitions_statut() -> p_de) ? p_vers, false)
  end
$$;

-- L'étape d'avant : le dernier statut de l'historique qui n'est ni l'actuel, ni
-- un incident, ni une étape annulée par une correction. Trié par identifiant
-- (ordre d'écriture) et non par date : la première étape porte la date de
-- réception saisie, qui peut être postérieure de quelques minutes aux étapes
-- suivantes.
create or replace function public.statut_precedent(p_colis uuid, p_actuel text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select h.statut
  from public.colis_historique h
  where h.colis_id = p_colis and h.statut not in (coalesce(p_actuel, ''), 'incident')
    and not exists (select 1 from public.colis_historique x where x.corrige_id = h.id)
  order by h.id desc
  limit 1
$$;

-- Les statuts qu'un colis peut prendre maintenant (statuts_possibles) : voir
-- outils/supabase-evenements.sql.


-- 6. Journal d'audit -----------------------------------------------------------
-- Qui a fait quoi, et quand : création et modification des colis, changements
-- de statut, modification des clients, opérations sur les factures.
--
-- Il est rempli par des déclencheurs, donc quel que soit le chemin (tableau de
-- bord, application, SQL Editor). Personne ne peut y écrire directement ; seule
-- l'équipe peut le lire.
--
-- On n'y recopie que ce qui a changé, et pour un client seulement le NOM des
-- champs modifiés (adresse, téléphone…) : l'adresse d'un client n'a pas à
-- exister en deux exemplaires.

create table if not exists public.journal_audit (
  id         bigint generated always as identity primary key,
  auteur_id  uuid,                        -- compte connecté ; vide pour le SQL Editor
  action     text not null,               -- colis.creation, colis.statut, facture.paiement…
  entite     text not null,               -- colis, client, facture
  entite_id  text not null default '',
  avant      jsonb,
  apres      jsonb,
  cree_le    timestamptz not null default now()
);

create index if not exists journal_audit_entite_idx on public.journal_audit (entite, entite_id, cree_le desc);
create index if not exists journal_audit_date_idx on public.journal_audit (cree_le desc);

alter table public.journal_audit enable row level security;
drop policy if exists journal_audit_lecture on public.journal_audit;
create policy journal_audit_lecture on public.journal_audit
  for select to authenticated
  using ((select public.peut('audit_logs.view')));
revoke all on public.journal_audit from anon, authenticated;
grant select on public.journal_audit to authenticated;
grant select, insert on public.journal_audit to service_role;

create or replace function public.auditer(p_action text, p_entite text, p_entite_id text,
                                          p_avant jsonb, p_apres jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.journal_audit (auteur_id, action, entite, entite_id, avant, apres)
  values (auth.uid(), p_action, p_entite, coalesce(p_entite_id, ''), p_avant, p_apres);
end;
$$;

-- Ce qui a changé entre deux versions d'une ligne, clé par clé, en ignorant
-- les dates tenues à jour automatiquement.
create or replace function public.difference(p_avant jsonb, p_apres jsonb, p_ignorer text[] default '{}')
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'avant', coalesce(jsonb_object_agg(k, p_avant -> k), '{}'::jsonb),
    'apres', coalesce(jsonb_object_agg(k, p_apres -> k), '{}'::jsonb))
  from jsonb_object_keys(p_apres) k
  where not (k = any (p_ignorer)) and (p_avant -> k) is distinct from (p_apres -> k)
$$;

create or replace function public.journaliser_colis()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  d jsonb;
  v_resume text[] := array['numero', 'client_id', 'statut', 'poids_lb', 'tarif_lb_usd', 'prix_usd',
                           'service', 'pays_destination', 'suivi_transporteur'];
begin
  if tg_op = 'INSERT' then
    perform public.auditer('colis.creation', 'colis', new.id::text, null,
      (select jsonb_object_agg(k, v) from jsonb_each(to_jsonb(new)) e(k, v) where k = any (v_resume)));
    raise log 'goship colis cree numero=% compte=%', new.numero, coalesce(auth.uid()::text, 'aucun');
  elsif tg_op = 'UPDATE' then
    d := public.difference(to_jsonb(old), to_jsonb(new), array['maj_le', 'cree_le']);
    if d -> 'apres' = '{}'::jsonb then
      return null;
    end if;
    perform public.auditer(case when new.statut is distinct from old.statut then 'colis.statut'
                                else 'colis.modification' end,
                           'colis', new.id::text, d -> 'avant', d -> 'apres');
    if new.statut is distinct from old.statut then
      raise log 'goship statut change numero=% de=% vers=% compte=%',
        new.numero, old.statut, new.statut, coalesce(auth.uid()::text, 'aucun');
    end if;
  else
    perform public.auditer('colis.suppression', 'colis', old.id::text,
      (select jsonb_object_agg(k, v) from jsonb_each(to_jsonb(old)) e(k, v) where k = any (v_resume)), null);
  end if;
  return null;
end;
$$;

drop trigger if exists journaliser_colis on public.colis;
create trigger journaliser_colis
  after insert or update or delete on public.colis
  for each row execute function public.journaliser_colis();

create or replace function public.journaliser_client()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  d jsonb;
  v_champs jsonb;
begin
  if tg_op = 'INSERT' then
    perform public.auditer('client.creation', 'client', new.id::text, null,
                           jsonb_build_object('code', new.code, 'role', new.role));
  elsif tg_op = 'UPDATE' then
    d := public.difference(to_jsonb(old), to_jsonb(new), array['cree_le']);
    if d -> 'apres' = '{}'::jsonb then
      return null;
    end if;
    select jsonb_agg(k order by k) into v_champs from jsonb_object_keys(d -> 'apres') k;
    if new.role is distinct from old.role or new.code is distinct from old.code then
      -- Rôle et code : les valeurs comptent (qui est devenu administrateur ?)
      perform public.auditer('client.role', 'client', new.id::text,
                             jsonb_build_object('role', old.role, 'code', old.code),
                             jsonb_build_object('role', new.role, 'code', new.code, 'champs', v_champs));
    else
      -- Coordonnées : seulement le nom des champs, pas leur contenu
      perform public.auditer('client.modification', 'client', new.id::text, null,
                             jsonb_build_object('champs', v_champs));
    end if;
  else
    perform public.auditer('client.suppression', 'client', old.id::text,
                           jsonb_build_object('code', old.code), null);
  end if;
  return null;
end;
$$;

drop trigger if exists journaliser_client on public.clients;
create trigger journaliser_client
  after insert or update or delete on public.clients
  for each row execute function public.journaliser_client();

create or replace function public.journaliser_facture()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  d jsonb;
  v_finances text[] := array['numero', 'client_id', 'montant_usd', 'frais_service_usd',
                             'montant_paye_usd', 'statut', 'moyen', 'payee_le'];
begin
  if tg_op = 'INSERT' then
    perform public.auditer('facture.creation', 'facture', new.id::text, null,
      (select jsonb_object_agg(k, v) from jsonb_each(to_jsonb(new)) e(k, v) where k = any (v_finances)));
  elsif tg_op = 'UPDATE' then
    d := public.difference(
      (select jsonb_object_agg(k, v) from jsonb_each(to_jsonb(old)) e(k, v) where k = any (v_finances)),
      (select jsonb_object_agg(k, v) from jsonb_each(to_jsonb(new)) e(k, v) where k = any (v_finances)));
    if d -> 'apres' = '{}'::jsonb then
      return null;
    end if;
    perform public.auditer(
      case when (d -> 'apres') ?| array['montant_paye_usd', 'statut', 'moyen', 'payee_le']
           then 'facture.paiement' else 'facture.modification' end,
      'facture', new.id::text, d -> 'avant', d -> 'apres');
  else
    perform public.auditer('facture.suppression', 'facture', old.id::text,
      (select jsonb_object_agg(k, v) from jsonb_each(to_jsonb(old)) e(k, v) where k = any (v_finances)), null);
  end if;
  return null;
end;
$$;

drop trigger if exists journaliser_facture on public.factures;
create trigger journaliser_facture
  after insert or update or delete on public.factures
  for each row execute function public.journaliser_facture();


-- 7. Règles des colis ----------------------------------------------------------
-- Le déclencheur qui fait foi, quel que soit le chemin d'écriture. Il passe
-- après preparer_colis (ordre alphabétique des déclencheurs « before ») : le
-- numéro est attribué et le suivi vendeur déjà mis en majuscules.
--
-- À la modification, un champ n'est contrôlé que s'il change : un vieux colis
-- sans poids reste modifiable, et la suppression d'un client (qui vide
-- client_id de ses colis) ne bute jamais sur une règle apparue depuis.

create or replace function public.regles_colis()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  t jsonb := public.tarifs();
  v_nouveau boolean := tg_op = 'INSERT';
  v_autre text;
  v_precedent text;
begin
  -- Textes nettoyés et bornés, comme le profil client
  new.description := left(trim(coalesce(new.description, '')), 300);
  new.expediteur  := left(trim(coalesce(new.expediteur, '')), 80);
  new.destination := left(trim(coalesce(new.destination, '')), 80);
  new.lieu        := left(trim(coalesce(new.lieu, '')), 80);
  new.note        := left(trim(coalesce(new.note, '')), 300);
  new.suivi_transporteur := left(coalesce(new.suivi_transporteur, ''), 60);

  -- Client : un vrai client, pas un compte de l'équipe
  if v_nouveau or new.client_id is distinct from old.client_id then
    if v_nouveau and new.client_id is null then
      perform public.erreur_metier('CLIENT_NOT_FOUND', 'Choisissez le client à qui appartient ce colis.');
    end if;
    if new.client_id is not null
       and not exists (select 1 from public.clients where id = new.client_id and role = 'client') then
      perform public.erreur_metier('CLIENT_NOT_FOUND', 'Aucun client avec cet identifiant.');
    end if;
  end if;

  if (v_nouveau or new.description is distinct from old.description) and new.description = '' then
    perform public.erreur_metier('INVALID_DESCRIPTION', 'Décrivez le contenu du colis.');
  end if;

  if v_nouveau or new.poids_lb is distinct from old.poids_lb then
    if new.poids_lb is null or new.poids_lb <= 0 then
      perform public.erreur_metier('INVALID_WEIGHT', 'Le poids doit être supérieur à zéro, en livres.');
    end if;
    -- Au-delà, c'est une faute de frappe : 45 000 lb feraient une facture de
    -- 225 000 $.
    if new.poids_lb > 10000 then
      perform public.erreur_metier('INVALID_WEIGHT', 'Poids supérieur à 10 000 lb : vérifiez la saisie.');
    end if;
  end if;

  if (v_nouveau or new.service is distinct from old.service)
     and coalesce(new.service, '') not in ('aerien', 'maritime', 'terrestre') then
    perform public.erreur_metier('INVALID_SERVICE', 'Service inconnu : aérien, maritime ou terrestre.');
  end if;

  if (v_nouveau or new.pays_destination is distinct from old.pays_destination)
     and coalesce(new.pays_destination, '') not in ('HT', 'DO', 'US') then
    perform public.erreur_metier('INVALID_DESTINATION', 'Destination inconnue : HT, DO ou US.');
  end if;

  if (v_nouveau or new.recu_le is distinct from old.recu_le) and new.recu_le > now() + interval '1 hour' then
    perform public.erreur_metier('INVALID_DATE', 'La date de réception ne peut pas être dans le futur.');
  end if;

  -- Suivi vendeur unique. Le verrou empêche deux enregistrements simultanés du
  -- même numéro de passer chacun le contrôle avant que l'autre soit écrit.
  if new.suivi_transporteur <> ''
     and (v_nouveau or new.suivi_transporteur is distinct from old.suivi_transporteur) then
    perform pg_advisory_xact_lock(hashtextextended('goship-suivi:' || new.suivi_transporteur, 0));
    select numero into v_autre from public.colis
     where suivi_transporteur = new.suivi_transporteur and id <> new.id
     limit 1;
    if v_autre is not null then
      perform public.erreur_metier('TRACKING_ALREADY_EXISTS',
        'Le numéro de suivi ' || new.suivi_transporteur || ' est déjà celui du colis ' || v_autre || '.');
    end if;
  end if;

  -- Tarif et prix. Le prix n'est jamais accepté tel qu'envoyé : il est
  -- recalculé quand le poids ou le tarif change, et sinon il reste celui qui a
  -- été arrêté — une facture déjà remise ne bouge pas.
  if v_nouveau then
    new.tarif_lb_usd := coalesce(new.tarif_lb_usd, (t ->> 'par_livre')::numeric);
  else
    new.tarif_lb_usd := coalesce(new.tarif_lb_usd, old.tarif_lb_usd, (t ->> 'par_livre')::numeric);
  end if;
  if (v_nouveau or new.tarif_lb_usd is distinct from old.tarif_lb_usd)
     and (new.tarif_lb_usd < 0 or new.tarif_lb_usd > 1000) then
    perform public.erreur_metier('INVALID_RATE', 'Le tarif doit être compris entre 0 et 1 000 $ la livre.');
  end if;
  -- Un tarif autre que celui de la maison change ce que paiera le client :
  -- c'est un geste de facturation (invoices.edit), pas d'entrepôt. Le SQL
  -- Editor, sans compte connecté, reste libre.
  if auth.uid() is not null and not public.peut('invoices.edit')
     and ((v_nouveau and new.tarif_lb_usd is distinct from (t ->> 'par_livre')::numeric)
          or (not v_nouveau and new.tarif_lb_usd is distinct from old.tarif_lb_usd)) then
    perform public.erreur_metier('PERMISSION_DENIED',
      'Un tarif particulier est réservé à qui peut modifier les factures.');
  end if;
  if v_nouveau
     or new.poids_lb is distinct from old.poids_lb
     or new.tarif_lb_usd is distinct from old.tarif_lb_usd
     or old.prix_usd is null then
    new.prix_usd := public.prix_transport(new.poids_lb, new.tarif_lb_usd);
  else
    new.prix_usd := old.prix_usd;
  end if;

  -- Statut. Un colis naît « Reçu » : c'est l'événement initial de son
  -- historique. Ensuite, seule une transition de la matrice est acceptée.
  if v_nouveau then
    if coalesce(new.statut, 'recu') <> 'recu' then
      perform public.erreur_metier('INVALID_STATUS',
        'Un colis est enregistré au statut « Reçu » ; changez ensuite son statut.');
    end if;
    new.statut := 'recu';
  elsif new.statut is distinct from old.statut then
    if not (public.transitions_statut() ? coalesce(new.statut, '')) then
      perform public.erreur_metier('INVALID_STATUS', 'Statut inconnu : ' || coalesce(new.statut, '(vide)') || '.');
    end if;
    v_precedent := public.statut_precedent(new.id, old.statut);
    if not public.transition_permise(old.statut, new.statut, v_precedent) then
      raise log 'goship transition refusee numero=% de=% vers=%', new.numero, old.statut, new.statut;
      perform public.erreur_metier('INVALID_STATUS_TRANSITION',
        public.texte_statut(old.statut) || ' → ' || public.texte_statut(new.statut) ||
        ' : transition interdite pour le colis ' || new.numero || '.');
    end if;
  end if;

  -- « Disponible » dit au client où retirer son colis : sans agence, le
  -- message ne sert à rien.
  if new.statut = 'disponible' and new.lieu = ''
     and (v_nouveau or new.statut is distinct from old.statut or new.lieu is distinct from old.lieu) then
    perform public.erreur_metier('LOCATION_REQUIRED', 'Indiquez l''agence où le client peut retirer son colis.');
  end if;

  -- La clé d'idempotence est celle de la création ; elle ne se change pas.
  if not v_nouveau then
    new.cle_idempotence := old.cle_idempotence;
  end if;
  return new;
end;
$$;

drop trigger if exists regles_colis on public.colis;
create trigger regles_colis
  before insert or update on public.colis
  for each row execute function public.regles_colis();


-- 8. Règles des factures -------------------------------------------------------
-- Un colis ne figure que sur une facture active (non annulée). Le montant d'une
-- ligne est le prix inscrit sur le colis, pas celui qu'envoie la page. Une
-- facture émise garde ses frais de service et, si elle porte des colis, son
-- total : c'est ce que le client a sous les yeux.

create or replace function public.regles_facture_ligne()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.colis;
  v_client uuid;
  v_statut text;
  v_autre text;
begin
  if new.colis_id is null then
    return new;   -- ligne libre, ou colis supprimé depuis (la ligne reste)
  end if;
  if tg_op = 'UPDATE' and new.colis_id is not distinct from old.colis_id then
    if new.montant_usd is distinct from old.montant_usd then
      perform public.erreur_metier('INVOICE_LOCKED',
        'Le montant d''une ligne de colis est celui du colis : il ne se modifie pas.');
    end if;
    return new;
  end if;

  -- Le verrou sur le colis met en file deux factures créées au même instant
  -- pour lui : la seconde voit la première et s'arrête.
  select * into c from public.colis where id = new.colis_id for update;
  if not found then
    perform public.erreur_metier('SHIPMENT_NOT_FOUND', 'Colis introuvable.');
  end if;
  select client_id, statut into v_client, v_statut from public.factures where id = new.facture_id;
  if c.client_id is distinct from v_client then
    perform public.erreur_metier('INVOICE_CLIENT_MISMATCH',
      'Le colis ' || c.numero || ' appartient à un autre client que celui de la facture.');
  end if;
  select f.numero into v_autre
    from public.facture_lignes l join public.factures f on f.id = l.facture_id
   where l.colis_id = new.colis_id and l.id <> new.id and f.statut <> 'annulee'
   limit 1;
  if v_autre is not null and v_statut <> 'annulee' then
    perform public.erreur_metier('INVOICE_ALREADY_EXISTS',
      'Le colis ' || c.numero || ' est déjà sur la facture ' || v_autre || '.');
  end if;

  new.montant_usd := coalesce(c.prix_usd, public.prix_transport(c.poids_lb,
                              coalesce(c.tarif_lb_usd, (public.tarifs() ->> 'par_livre')::numeric)));
  new.poids_lb := c.poids_lb;
  new.quantite := 1;
  if coalesce(trim(new.libelle), '') = '' then
    new.libelle := coalesce(nullif(c.description, ''), 'Transport');
  end if;
  return new;
end;
$$;

drop trigger if exists regles_facture_ligne on public.facture_lignes;
create trigger regles_facture_ligne
  before insert or update on public.facture_lignes
  for each row execute function public.regles_facture_ligne();

create or replace function public.regles_facture()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_autre text;
begin
  if new.frais_service_usd is distinct from old.frais_service_usd then
    perform public.erreur_metier('INVOICE_LOCKED',
      'Les frais de service sont fixés à la création de la facture.');
  end if;
  if new.client_id is distinct from old.client_id then
    perform public.erreur_metier('INVOICE_LOCKED', 'Une facture émise ne change pas de client.');
  end if;
  if new.montant_usd is distinct from old.montant_usd
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

drop trigger if exists regles_facture on public.factures;
create trigger regles_facture
  before update on public.factures
  for each row execute function public.regles_facture();


-- 9. Fonctions de service des colis (ShipmentService) ------------------------
-- « security definer » : elles s'exécutent avec les droits de la base, et
-- c'est pourquoi chacune commence par exiger_permission. Le jour où le
-- tableau de bord n'écrira plus du tout dans les tables (voir la fin de ce
-- fichier), ce sont elles qui resteront la seule porte.

-- Un colis tel que le tableau de bord l'affiche (vue colis_details)
create or replace function public.colis_json(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select to_jsonb(d) from public.colis_details d where d.id = p_id
$$;

-- Une facture avec son client et ses lignes, dans la forme que produit la
-- requête de assets/js/api.js (admin.factures) : l'impression s'en sert telle
-- quelle.
create or replace function public.facture_json(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select to_jsonb(f)
         || jsonb_build_object(
              'clients', (select jsonb_build_object('code', c.code, 'nom_complet', c.nom_complet,
                                                    'telephone', c.telephone, 'email', c.email,
                                                    'adresse', c.adresse, 'region', c.region,
                                                    'ville', c.ville, 'pays', c.pays, 'langue', c.langue)
                          from public.clients c where c.id = f.client_id),
              'facture_lignes', coalesce((
                select jsonb_agg(to_jsonb(l) || jsonb_build_object(
                         'colis', (select jsonb_build_object('numero', co.numero, 'description', co.description,
                                                             'poids_lb', co.poids_lb)
                                   from public.colis co where co.id = l.colis_id))
                       order by l.id)
                from public.facture_lignes l where l.facture_id = f.id), '[]'::jsonb))
  from public.factures f
  where f.id = p_id
$$;

-- Lecture d'un nombre envoyé par la page : une valeur illisible devient une
-- erreur métier plutôt qu'une erreur de conversion incompréhensible.
create or replace function public.lire_nombre(p_valeur jsonb, p_code text, p_detail text)
returns numeric
language plpgsql
set search_path = ''
as $$
begin
  if p_valeur is null or p_valeur = 'null'::jsonb or trim(p_valeur #>> '{}') = '' then
    return null;
  end if;
  return replace(p_valeur #>> '{}', ',', '.')::numeric;
exception when others then
  perform public.erreur_metier(p_code, p_detail);
  return null;
end;
$$;

create or replace function public.lire_uuid(p_valeur jsonb, p_code text, p_detail text)
returns uuid
language plpgsql
set search_path = ''
as $$
begin
  if p_valeur is null or p_valeur = 'null'::jsonb or trim(p_valeur #>> '{}') = '' then
    return null;
  end if;
  return (p_valeur #>> '{}')::uuid;
exception when others then
  perform public.erreur_metier(p_code, p_detail);
  return null;
end;
$$;

-- Enregistrer un colis, et sa facture dans la même transaction.
--
--   1. permission             5. insertion (regles_colis : validations, tarif,
--   2. requête répétée ?         prix, statut « Reçu », numéro, suivi unique)
--   3. lecture des champs     6. événement initial (historiser_colis)
--   4. —                      7. facture (facturer_colis)
--                             8. audit (journaliser_colis, journaliser_facture)
--
-- Si quoi que ce soit échoue, rien n'est enregistré : pas de colis sans sa
-- facture, pas de facture sans son colis.
create or replace function public.creer_colis(p_colis jsonb, p_cle text default null,
                                              p_facturer boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cle text := nullif(trim(coalesce(p_cle, '')), '');
  v_client uuid;
  v_id uuid;
  v_existant public.colis;
  v_facture jsonb;
  v_recu timestamptz;
begin
  perform public.exiger_permission('shipments.create');
  if p_colis is null or jsonb_typeof(p_colis) <> 'object' then
    perform public.erreur_metier('INVALID_INPUT', 'Données du colis manquantes.');
  end if;
  if v_cle is not null and length(v_cle) > 80 then
    perform public.erreur_metier('INVALID_INPUT', 'Clé de requête trop longue.');
  end if;
  v_client := public.lire_uuid(p_colis -> 'client_id', 'CLIENT_NOT_FOUND', 'Identifiant de client illisible.');

  -- Requête répétée (double clic, connexion revenue) : on rend le colis déjà
  -- créé. Le verrou couvre le cas où les deux envois arrivent en même temps.
  if v_cle is not null then
    perform pg_advisory_xact_lock(hashtextextended('goship-creer-colis:' || v_cle, 0));
    select * into v_existant from public.colis where cle_idempotence = v_cle;
    if found then
      if v_existant.client_id is distinct from v_client then
        perform public.erreur_metier('DUPLICATE_OPERATION',
          'Cette requête a déjà servi à enregistrer le colis ' || v_existant.numero || ' pour un autre client.');
      end if;
      raise log 'goship creer_colis repete numero=%', v_existant.numero;
      return jsonb_build_object(
        'colis', public.colis_json(v_existant.id),
        'facture', (select public.facture_json(l.facture_id)
                      from public.facture_lignes l join public.factures f on f.id = l.facture_id
                     where l.colis_id = v_existant.id and f.statut <> 'annulee'
                     order by f.cree_le desc limit 1),
        'deja', true);
    end if;
  end if;

  begin
    v_recu := coalesce(nullif(p_colis ->> 'recu_le', '')::timestamptz, now());
  exception when others then
    perform public.erreur_metier('INVALID_DATE', 'Date de réception illisible.');
  end;

  insert into public.colis (client_id, description, expediteur, suivi_transporteur, poids_lb, service,
                            pays_destination, destination, recu_le, tarif_lb_usd, lieu, note,
                            statut, cle_idempotence)
  values (v_client,
          coalesce(p_colis ->> 'description', ''),
          coalesce(p_colis ->> 'expediteur', ''),
          coalesce(p_colis ->> 'suivi_transporteur', ''),
          public.lire_nombre(p_colis -> 'poids_lb', 'INVALID_WEIGHT', 'Poids illisible.'),
          coalesce(nullif(p_colis ->> 'service', ''), 'aerien'),
          coalesce(nullif(p_colis ->> 'pays_destination', ''), 'HT'),
          coalesce(p_colis ->> 'destination', ''),
          v_recu,
          public.lire_nombre(p_colis -> 'tarif_lb_usd', 'INVALID_RATE', 'Tarif illisible.'),
          coalesce(nullif(p_colis ->> 'lieu', ''), 'Miami (Medley), FL'),
          coalesce(p_colis ->> 'note', ''),
          'recu',
          v_cle)
  returning id into v_id;

  -- La facture naît avec le colis : c'est la règle de la maison, pas une
  -- facturation à part. Elle ne demande donc pas invoices.create — un employé
  -- qui enregistre un colis produit sa facture, sans pouvoir en faire d'autres.
  if p_facturer then
    v_facture := public.facturer_colis_interne(v_id) -> 'facture';
  end if;

  return jsonb_build_object('colis', public.colis_json(v_id), 'facture', v_facture, 'deja', false);
end;
$$;

-- Corriger un colis. Seuls les champs de la liste sont pris ; le statut passe
-- par changer_statut_colis, le prix se recalcule tout seul (regles_colis).
-- p_maj_le : la date de dernière modification que la page avait sous les yeux.
-- Si quelqu'un a modifié le colis entre-temps, on refuse plutôt que d'écraser
-- son travail sans le dire.
create or replace function public.modifier_colis(p_id uuid, p_champs jsonb, p_maj_le timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.colis;
  v jsonb := coalesce(p_champs, '{}'::jsonb);
begin
  perform public.exiger_permission('shipments.edit');
  select * into c from public.colis where id = p_id for update;
  if not found then
    perform public.erreur_metier('SHIPMENT_NOT_FOUND', 'Ce colis n''existe plus.');
  end if;
  if p_maj_le is not null and c.maj_le <> p_maj_le then
    perform public.erreur_metier('CONCURRENT_MODIFICATION',
      'Le colis ' || c.numero || ' a été modifié par quelqu''un d''autre entre-temps : rechargez-le.');
  end if;

  update public.colis set
    client_id          = case when v ? 'client_id'
                              then public.lire_uuid(v -> 'client_id', 'CLIENT_NOT_FOUND', 'Identifiant de client illisible.')
                              else client_id end,
    description        = case when v ? 'description' then coalesce(v ->> 'description', '') else description end,
    expediteur         = case when v ? 'expediteur' then coalesce(v ->> 'expediteur', '') else expediteur end,
    suivi_transporteur = case when v ? 'suivi_transporteur' then coalesce(v ->> 'suivi_transporteur', '')
                              else suivi_transporteur end,
    poids_lb           = case when v ? 'poids_lb'
                              then public.lire_nombre(v -> 'poids_lb', 'INVALID_WEIGHT', 'Poids illisible.')
                              else poids_lb end,
    service            = case when v ? 'service' then v ->> 'service' else service end,
    pays_destination   = case when v ? 'pays_destination' then v ->> 'pays_destination' else pays_destination end,
    destination        = case when v ? 'destination' then coalesce(v ->> 'destination', '') else destination end,
    recu_le            = case when v ? 'recu_le' then coalesce(nullif(v ->> 'recu_le', '')::timestamptz, recu_le)
                              else recu_le end,
    tarif_lb_usd       = case when v ? 'tarif_lb_usd'
                              then public.lire_nombre(v -> 'tarif_lb_usd', 'INVALID_RATE', 'Tarif illisible.')
                              else tarif_lb_usd end
  where id = p_id;

  return public.colis_json(p_id);
end;
$$;

-- Le changement de statut (changer_statut_colis) et les statuts possibles
-- (statuts_possibles) sont dans outils/supabase-evenements.sql : ils passent
-- par le moteur d'événements, qui seul peut changer le statut d'un colis.


-- TrackingService, côté équipe : un colis par son numéro GSE ou par le
-- numéro de suivi du vendeur, avec tout son détail. Le suivi public reste
-- suivre_colis (supabase.sql, partie 5), qui ne montre ni nom, ni adresse,
-- ni note, ni montant.
create or replace function public.trouver_colis(p_reference text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ref text := upper(trim(coalesce(p_reference, '')));
  v_id uuid;
begin
  perform public.exiger_permission('shipments.view');
  if length(v_ref) < 4 then
    return null;
  end if;
  select id into v_id from public.colis
   where numero = v_ref or (suivi_transporteur <> '' and suivi_transporteur = v_ref)
   order by maj_le desc limit 1;
  if v_id is null then
    return null;
  end if;
  return public.colis_json(v_id) || jsonb_build_object('historique', coalesce((
    select jsonb_agg(jsonb_build_object('id', h.id, 'type_evenement', h.type_evenement,
                                        'statut_precedent', h.statut_precedent, 'statut', h.statut,
                                        'lieu', h.lieu, 'note', h.note, 'cree_le', h.cree_le,
                                        'visibilite', h.visibilite, 'corrige_id', h.corrige_id)
                     order by h.id)
    from public.colis_historique h where h.colis_id = v_id), '[]'::jsonb));
end;
$$;


-- 10. Fonctions de service de facturation (BillingService) --------------------

-- La facture d'un colis : son prix, plus les frais de service une fois.
-- Idempotente : un colis déjà sur une facture active la retrouve, il n'en
-- reçoit pas une deuxième.
create or replace function public.facturer_colis(p_colis uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('invoices.create');
  return public.facturer_colis_interne(p_colis);
end;
$$;

-- Le corps de facturer_colis, sans la vérification de permission : appelé par
-- facturer_colis (invoices.create) et par creer_colis (shipments.create).
-- Fermé au site.
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
  v_frais numeric := (public.tarifs() ->> 'frais_service')::numeric;
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
  values (c.client_id, v_prix + v_frais, v_frais, 0, 'a_payer')
  returning id into v_facture;
  insert into public.facture_lignes (facture_id, colis_id, libelle, montant_usd, quantite, poids_lb)
  values (v_facture, c.id, coalesce(nullif(c.description, ''), 'Transport'), v_prix, 1, c.poids_lb);

  raise log 'goship facture creee colis=% facture=%', c.numero, v_facture;
  return jsonb_build_object('facture', public.facture_json(v_facture), 'deja', false);
end;
$$;

-- Une facture pour plusieurs colis d'un même client, ou d'un montant libre
-- (sans colis). Le montant n'est pris de la page que dans ce second cas ;
-- avec des colis, c'est la somme de leurs prix plus les frais de service.
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
    v_frais := (public.tarifs() ->> 'frais_service')::numeric;
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


-- 11. Droits d'exécution -------------------------------------------------------
-- PostgreSQL ouvre toute nouvelle fonction à tout le monde : on referme, puis
-- on n'ouvre aux comptes connectés que les fonctions de service. Chacune
-- vérifie elle-même la permission.

revoke execute on function public.auditer(text, text, text, jsonb, jsonb) from public, anon, authenticated;
revoke execute on function public.difference(jsonb, jsonb, text[]) from public, anon, authenticated;
revoke execute on function public.journaliser_colis() from public, anon, authenticated;
revoke execute on function public.journaliser_client() from public, anon, authenticated;
revoke execute on function public.journaliser_facture() from public, anon, authenticated;
revoke execute on function public.regles_colis() from public, anon, authenticated;
revoke execute on function public.regles_facture() from public, anon, authenticated;
revoke execute on function public.regles_facture_ligne() from public, anon, authenticated;
revoke execute on function public.lire_nombre(jsonb, text, text) from public, anon, authenticated;
revoke execute on function public.lire_uuid(jsonb, text, text) from public, anon, authenticated;
revoke execute on function public.colis_json(uuid) from public, anon, authenticated;
revoke execute on function public.facture_json(uuid) from public, anon, authenticated;
revoke execute on function public.statut_precedent(uuid, text) from public, anon, authenticated;
revoke execute on function public.facturer_colis_interne(uuid) from public, anon, authenticated;

revoke execute on function public.tarifs() from public, anon;
revoke execute on function public.prix_transport(numeric, numeric) from public, anon;
revoke execute on function public.roles_equipe() from public, anon;
revoke execute on function public.equipe() from public, anon;
revoke execute on function public.changer_role(text, text) from public, anon;
revoke execute on function public.transitions_statut() from public, anon;
revoke execute on function public.transition_permise(text, text, text) from public, anon;
revoke execute on function public.creer_colis(jsonb, text, boolean) from public, anon;
revoke execute on function public.modifier_colis(uuid, jsonb, timestamptz) from public, anon;
revoke execute on function public.trouver_colis(text) from public, anon;
revoke execute on function public.facturer_colis(uuid) from public, anon;
revoke execute on function public.creer_facture(uuid, uuid[], jsonb, text) from public, anon;

grant execute on function public.tarifs() to authenticated;
grant execute on function public.prix_transport(numeric, numeric) to authenticated;
grant execute on function public.roles_equipe() to authenticated;
grant execute on function public.equipe() to authenticated;
grant execute on function public.changer_role(text, text) to authenticated;
grant execute on function public.transitions_statut() to authenticated;
grant execute on function public.transition_permise(text, text, text) to authenticated;
grant execute on function public.creer_colis(jsonb, text, boolean) to authenticated;
grant execute on function public.modifier_colis(uuid, jsonb, timestamptz) to authenticated;
grant execute on function public.trouver_colis(text) to authenticated;
grant execute on function public.facturer_colis(uuid) to authenticated;
grant execute on function public.creer_facture(uuid, uuid[], jsonb, text) to authenticated;


-- La vue colis_details est refaite : « c.* » y est figé au moment de sa
-- création, et les colonnes ajoutées depuis (prix, tarif) n'y apparaîtraient
-- pas sinon. Même définition que supabase.sql, partie 4.
drop view if exists public.colis_details;
create view public.colis_details
with (security_invoker = true) as
  select c.*,
         cl.code        as code_client,
         cl.nom_complet as nom_client,
         cl.telephone   as telephone_client,
         cl.email       as email_client,
         cl.adresse     as adresse_client,
         cl.region      as region_client,
         cl.ville       as ville_client,
         cl.pays        as pays_client,
         cl.langue      as langue_client
  from public.colis c
  left join public.clients cl on cl.id = c.client_id;

revoke all on public.colis_details from anon;
grant select on public.colis_details to authenticated, service_role;


-- Facultatif, plus tard : fermer l'écriture directe -------------------------
-- Aujourd'hui l'équipe peut encore écrire dans la table colis sans passer par
-- les fonctions de service (les règles de sécurité le lui permettent). Ce n'est
-- pas une brèche — regles_colis s'applique à ce chemin-là aussi —, mais c'est
-- une seconde porte. Une fois l'application mobile vérifiée (elle ne doit pas
-- écrire dans colis), enlevez les deux tirets des lignes suivantes et relancez
-- ce fichier :
--
-- revoke insert, update on public.colis from authenticated;
-- revoke insert on public.factures, public.facture_lignes from authenticated;


-- Contrôle ---------------------------------------------------------------------
select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('creer_colis', 'modifier_colis', 'facturer_colis',
                            'creer_facture', 'trouver_colis'))                                 as services_sur_5,
       (select count(*) from pg_trigger
        where tgname in ('regles_colis', 'regles_facture', 'regles_facture_ligne',
                         'journaliser_colis', 'journaliser_client', 'journaliser_facture')) as regles_sur_6,
       (select count(*) from pg_indexes
        where schemaname = 'public' and indexname = 'colis_suivi_unique_idx')              as suivi_unique,
       (select count(*) from (select suivi_transporteur from public.colis
                              where suivi_transporteur <> ''
                              group by suivi_transporteur having count(*) > 1) d)          as suivis_en_double;
