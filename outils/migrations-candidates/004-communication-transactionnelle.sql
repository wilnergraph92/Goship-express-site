-- CANDIDATE LOCALE — intégration transactionnelle au moteur de notifications GoShip.
-- Hors de outils/migrations.txt. Ne pas appliquer à une base distante.
-- Dépend des 39 migrations officielles, puis des candidates 001–003 (dont P-07).
--
-- Cette candidate réutilise les événements colis, notifications et l'outbox
-- notification_envois existants. Elle ne crée ni deuxième référentiel client,
-- ni deuxième historique colis, ni deuxième file d'envoi, ni adaptateur réseau.
-- Les fournisseurs restent hors de portée des essais de cette candidate.

begin;

-- 1. Modèles transactionnels versionnés ---------------------------------------
-- La version 1 est copiée depuis notification_textes(), la source actuellement
-- utilisée par le site et par les notifications mobiles. Une nouvelle version
-- s'ajoute sans réécrire les modèles déjà utilisés.

create table if not exists public.communication_modeles_transactionnels (
  type                    text not null references public.notification_regles (type) on delete restrict,
  version                 integer not null check (version > 0),
  langue                  text not null check (langue in ('fr', 'en', 'es', 'ht')),
  titre                   text not null,
  message                 text not null,
  variables_requises      text[] not null default '{}',
  canaux                  text[] not null,
  modele_whatsapp         text,
  cree_le                 timestamptz not null default clock_timestamp(),
  primary key (type, version, langue),
  check (variables_requises <@ array['numero', 'facture', 'montant']::text[]),
  check (canaux <@ array['push', 'email', 'whatsapp', 'sms']::text[])
);

alter table public.communication_modeles_transactionnels enable row level security;
revoke all on table public.communication_modeles_transactionnels
  from public, anon, authenticated, service_role;

create or replace function public.communication_modele_immuable()
returns trigger
language plpgsql
set search_path = ''
as $fonction$
begin
  raise exception 'COMMUNICATION_TEMPLATE_IMMUTABLE' using errcode = '55000';
end;
$fonction$;

create or replace function public.communication_interdire_truncate()
returns trigger
language plpgsql
set search_path = ''
as $fonction$
begin
  raise exception 'COMMUNICATION_TRUNCATE_INTERDIT' using errcode = '55000';
end;
$fonction$;

drop trigger if exists communication_modeles_immuables
  on public.communication_modeles_transactionnels;
create trigger communication_modeles_immuables
  before update or delete on public.communication_modeles_transactionnels
  for each row execute function public.communication_modele_immuable();
drop trigger if exists communication_modeles_truncate_interdit
  on public.communication_modeles_transactionnels;
create trigger communication_modeles_truncate_interdit
  before truncate on public.communication_modeles_transactionnels
  for each statement execute function public.communication_modele_immuable();

with sources as (
  select r.type,
         locale.langue,
         locale.contenu ->> 'titre' as titre,
         locale.contenu ->> 'message' as message,
         r.canaux,
         case when 'whatsapp' = any (r.canaux) then public.modele_whatsapp(r.type) end
           as modele_whatsapp
    from public.notification_regles r
    cross join lateral jsonb_each(public.notification_textes() -> r.type)
      as locale(langue, contenu)
   where r.source in ('colis', 'facturation', 'planifie')
     and locale.contenu ? 'titre'
     and locale.contenu ? 'message'
), modeles as (
  select s.*,
         coalesce((
           select array_agg(distinct capture.partie[1] order by capture.partie[1])
             from regexp_matches(concat_ws(' ', s.titre, s.message),
                                 '\{\{([a-z_]+)\}\}', 'g') as capture(partie)
         ), '{}'::text[]) as variables_requises
    from sources s
)
insert into public.communication_modeles_transactionnels
  (type, version, langue, titre, message, variables_requises, canaux, modele_whatsapp)
select type, 1, langue, titre, message, variables_requises, canaux, modele_whatsapp
  from modeles
on conflict (type, version, langue) do nothing;

do $verification$
begin
  if exists (
    select 1
      from public.notification_regles r
     where r.source in ('colis', 'facturation', 'planifie')
       and not exists (
         select 1 from public.communication_modeles_transactionnels m
          where m.type = r.type and m.version = 1
            and m.langue in ('fr', 'en', 'es', 'ht')
       )
  ) then
    raise exception 'COMMUNICATION_TEMPLATE_INITIAL_INCOMPLET';
  end if;
end;
$verification$;

-- 2. Version effectivement utilisée par chaque notification ------------------
-- La version et la langue sont des métadonnées internes. Les RPC clients
-- continuent de ne renvoyer que les champs qu'ils exposaient déjà.

create or replace function public.communication_attacher_modele_transactionnel()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fonction$
declare
  v_langue text;
  v_version integer;
begin
  if new.canal <> 'app'
     or new.categorie not in ('colis', 'factures', 'paiements')
     or new.type is null
     or not exists (select 1 from public.notification_regles r where r.type = new.type) then
    return new;
  end if;

  select public.langue_notification(c.langue)
    into v_langue
    from public.clients c
   where c.id = new.client_id;
  v_langue := coalesce(v_langue, 'fr');

  select max(m.version)
    into v_version
    from public.communication_modeles_transactionnels m
   where m.type = new.type and m.langue = v_langue;
  if v_version is null then
    raise exception 'COMMUNICATION_TEMPLATE_UNAVAILABLE' using errcode = '23514';
  end if;

  new.donnees := coalesce(new.donnees, '{}'::jsonb)
    || jsonb_build_object('_communication_modele_version', v_version,
                          '_communication_modele_langue', v_langue);
  return new;
end;
$fonction$;

drop trigger if exists communication_attacher_modele_transactionnel
  on public.notifications;
create trigger communication_attacher_modele_transactionnel
  before insert on public.notifications
  for each row execute function public.communication_attacher_modele_transactionnel();

update public.notifications n
   set donnees = coalesce(n.donnees, '{}'::jsonb)
     || jsonb_build_object(
          '_communication_modele_version', (
            select max(m.version)
              from public.communication_modeles_transactionnels m
             where m.type = n.type and m.langue = public.langue_notification(c.langue)),
          '_communication_modele_langue', public.langue_notification(c.langue))
  from public.clients c
 where c.id = n.client_id
   and n.canal = 'app'
   and n.categorie in ('colis', 'factures', 'paiements')
   and n.type in (select r.type from public.notification_regles r)
   and n.donnees ->> '_communication_modele_version' is null
   and exists (
     select 1 from public.communication_modeles_transactionnels m
      where m.type = n.type and m.langue = public.langue_notification(c.langue)
   );

create or replace function public.communication_rendre_modele_transactionnel(
  p_type text, p_langue text, p_donnees jsonb, p_version integer default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare
  -- La langue demandée (écran ou client) prime ; celle retenue à la création ne
  -- sert qu'à défaut (correction du 23/11/2026, comme texte_notification).
  v_langue text := public.langue_notification(coalesce(
    nullif(p_langue, ''), nullif(p_donnees ->> '_communication_modele_langue', '')));
  v_version integer := coalesce(
    p_version, nullif(p_donnees ->> '_communication_modele_version', '')::integer);
  v_modele public.communication_modeles_transactionnels;
  v_variables jsonb := coalesce(p_donnees, '{}'::jsonb);
  v_variable text;
begin
  if v_version is null then
    select max(m.version) into v_version
      from public.communication_modeles_transactionnels m
     where m.type = p_type and m.langue = v_langue;
  end if;

  select * into v_modele
    from public.communication_modeles_transactionnels m
   where m.type = p_type and m.langue = v_langue and m.version = v_version;
  if not found and p_version is null then
    -- La version retenue n'existe pas dans la langue demandée : dernière version
    -- de cette langue.
    select * into v_modele
      from public.communication_modeles_transactionnels m
     where m.type = p_type and m.langue = v_langue
     order by m.version desc
     limit 1;
  end if;
  if v_modele.type is null then
    return null;
  end if;

  v_variables := v_variables || jsonb_build_object(
    'montant', public.montant_notification(
      nullif(v_variables ->> 'montant_usd', '')::numeric, v_langue));
  foreach v_variable in array v_modele.variables_requises loop
    if nullif(btrim(v_variables ->> v_variable), '') is null then
      raise exception 'COMMUNICATION_TEMPLATE_VARIABLE_REQUIRED'
        using errcode = '23514', detail = v_variable;
    end if;
  end loop;

  return jsonb_build_object(
    'titre', public.rendre_notification(v_modele.titre, v_variables),
    'message', public.rendre_notification(v_modele.message, v_variables));
end;
$fonction$;

create or replace function public.texte_notification(p_type text, p_langue text, p_donnees jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare
  -- La langue demandée (celle de l'écran qui affiche, ou celle du client à
  -- l'envoi) prime ; la langue retenue à la création ne sert qu'à défaut.
  -- Correction du 23/11/2026 : l'ordre inverse affichait toujours la langue du
  -- compte, même dans une application réglée sur une autre langue.
  v_langue text := public.langue_notification(coalesce(
    nullif(p_langue, ''), nullif(p_donnees ->> '_communication_modele_langue', '')));
  v_texte jsonb;
  v_variables jsonb := coalesce(p_donnees, '{}'::jsonb)
    || jsonb_build_object('montant', public.montant_notification(
         (p_donnees ->> 'montant_usd')::numeric, v_langue));
begin
  v_texte := public.communication_rendre_modele_transactionnel(
    p_type, v_langue, p_donnees, null);
  if v_texte is not null then
    return v_texte;
  end if;

  -- Les types hors règles transactionnelles conservent le rendu de la chaîne
  -- officielle (supabase-anniversaires.sql) : d'abord les modèles modifiables
  -- par l'équipe (notification_modeles, dont les anniversaires), puis les textes
  -- fixes. Correction du 23/11/2026 : notification_modeles n'était plus lu, et
  -- un message d'anniversaire serait parti vide.
  select pg_catalog.jsonb_build_object('titre', m.titre, 'message', m.message) into v_texte
    from public.notification_modeles m
   where m.type = p_type and m.langue = v_langue;
  if v_texte is null then
    v_texte := public.notification_textes() -> p_type -> v_langue;
  end if;
  if v_texte is null then
    v_texte := jsonb_build_object('titre', 'GoShip Express', 'message', '');
  end if;
  return jsonb_build_object(
    'titre', public.rendre_notification(v_texte ->> 'titre', v_variables),
    'message', public.rendre_notification(v_texte ->> 'message', v_variables));
end;
$fonction$;

-- Correction du 23/11/2026 (étape C11, trouvée par essai-production.py) : cette version
-- est « security definer » pour lire les modèles versionnés malgré leur RLS ; ouverte à
-- tous comme l'était la version officielle (non privilégiée), elle aurait laissé un
-- visiteur sans compte rendre n'importe quel modèle. Ses appelants (mes_notifications,
-- expedier_envoi) sont eux-mêmes « security definer » : la fermer ne retire rien.
revoke execute on function public.texte_notification(text, text, jsonb) from public, anon, authenticated;
grant execute on function public.texte_notification(text, text, jsonb) to service_role;

create or replace function public.communication_verifier_canal_modele_transactionnel()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fonction$
declare
  v_notification public.notifications;
  v_version integer;
  v_langue text;
  v_canaux text[];
begin
  select * into v_notification
    from public.notifications n
   where n.id = new.notification_id;
  if not found or v_notification.categorie not in ('colis', 'factures', 'paiements') then
    return new;
  end if;

  v_version := nullif(v_notification.donnees ->> '_communication_modele_version', '')::integer;
  v_langue := coalesce(nullif(v_notification.donnees ->> '_communication_modele_langue', ''), 'fr');
  select m.canaux into v_canaux
    from public.communication_modeles_transactionnels m
   where m.type = v_notification.type
     and m.version = v_version
     and m.langue = v_langue;
  if not found then
    raise exception 'COMMUNICATION_TEMPLATE_UNAVAILABLE' using errcode = '23514';
  end if;
  if not (new.canal = any (v_canaux)) then
    raise exception 'COMMUNICATION_TEMPLATE_CHANNEL_UNSUPPORTED' using errcode = '23514';
  end if;
  return new;
end;
$fonction$;

drop trigger if exists communication_verifier_canal_modele_transactionnel
  on public.notification_envois;
create trigger communication_verifier_canal_modele_transactionnel
  before insert on public.notification_envois
  for each row execute function public.communication_verifier_canal_modele_transactionnel();

-- 2.5 Garde l'unique adaptateur réseau existant -------------------------------
-- Conserver son implémentation, mais lui retirer toute invocation directe : le
-- nouveau wrapper exige l'autorisation N0 dans la transaction du travailleur.
-- Le bloc est rejouable avec les candidates 001–004.
-- Correction du 23/11/2026 (étape C11) : quand la chaîne est rejouée, les fichiers
-- officiels (supabase-notifications.sql, supabase-courriel-colis.sql,
-- supabase-lieu-reception.sql) réécrivent expedier_envoi ; c'est CETTE version, la
-- plus récente, qui doit devenir l'adaptateur intérieur. L'ancien code gardait celui
-- du premier passage : une évolution officielle de l'adaptateur (texte, pied de
-- courriel, lieu de réception) ne prenait jamais effet sur une base existante. Le
-- wrapper se reconnaît à son appel de l'adaptateur intérieur.
do $renommage$
declare
  v_adaptateur regprocedure := pg_catalog.to_regprocedure('public.expedier_envoi(public.notification_envois)');
begin
  if v_adaptateur is not null
     and pg_catalog.strpos((select p.prosrc from pg_catalog.pg_proc p where p.oid = v_adaptateur),
                           'communication_expedier_envoi_sans_porte') = 0 then
    execute 'drop function if exists public.communication_expedier_envoi_sans_porte(public.notification_envois)';
    execute 'alter function public.expedier_envoi(public.notification_envois) '
            'rename to communication_expedier_envoi_sans_porte';
  elsif pg_catalog.to_regprocedure('public.communication_expedier_envoi_sans_porte(public.notification_envois)') is null then
    raise exception 'NOTIFICATION_SENDER_UNAVAILABLE';
  end if;
end;
$renommage$;

create or replace function public.expedier_envoi(p_envoi public.notification_envois)
returns bigint
language plpgsql
security definer
set search_path = ''
as $fonction$
declare
  v_raison text;
begin
  -- Le travailleur a déjà passé la porte avant de verrouiller la ligne. Un
  -- appel interne sans cette marque doit lui-même demander une autorisation.
  if not public.communication_sortie_autorisee('envoi', p_envoi.canal) then
    v_raison := public.communication_autoriser_sortie('envoi', p_envoi.canal);
  end if;
  if v_raison is not null then
    raise exception 'COMMUNICATION_OUTPUT_BLOCKED'
      using errcode = '55000', detail = v_raison;
  end if;
  if not public.communication_sortie_autorisee('envoi', p_envoi.canal) then
    raise exception 'COMMUNICATION_GATE_REQUIRED' using errcode = '55000';
  end if;
  -- Consommer avant l'unique appel réseau : le même marqueur ne peut pas
  -- autoriser une seconde transmission dans cette transaction.
  perform pg_catalog.set_config('goship.sortie_autorisee', '', true);
  perform pg_catalog.set_config('goship.sortie_consommee',
    pg_catalog.txid_current()::text, true);
  return public.communication_expedier_envoi_sans_porte(p_envoi);
end;
$fonction$;

revoke all on function public.communication_expedier_envoi_sans_porte(public.notification_envois)
  from public, anon, authenticated, service_role;
revoke all on function public.expedier_envoi(public.notification_envois)
  from public, anon, authenticated, service_role;

-- 3. File existante, historique structuré et vue de traçabilité ---------------
-- notification_envois reste l'unique outbox. Le journal conserve les transitions
-- sans recopier de cible, d'adresse ou d'erreur libre.

create table if not exists public.communication_transactionnelle_historique (
  id                     bigint generated always as identity primary key,
  notification_envoi_id  bigint not null
                         references public.notification_envois (id) on delete cascade,
  statut                 text not null,
  tentative              integer not null,
  code_erreur            text,
  cree_le                timestamptz not null default clock_timestamp()
);

alter table public.communication_transactionnelle_historique enable row level security;
revoke all on table public.communication_transactionnelle_historique
  from public, anon, authenticated, service_role;

create or replace function public.communication_journaliser_envoi_transactionnel()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fonction$
begin
  if tg_op = 'UPDATE'
     and old.statut is not distinct from new.statut
     and old.tentative is not distinct from new.tentative
     and old.code_erreur is not distinct from new.code_erreur then
    return new;
  end if;

  insert into public.communication_transactionnelle_historique
    (notification_envoi_id, statut, tentative, code_erreur)
  values (new.id, new.statut, new.tentative, new.code_erreur);
  return new;
end;
$fonction$;

create or replace function public.communication_historique_envoi_immuable()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fonction$
begin
  if tg_op = 'DELETE'
     and not exists (select 1 from public.notification_envois e
                      where e.id = old.notification_envoi_id) then
    return old;
  end if;
  raise exception 'COMMUNICATION_DELIVERY_HISTORY_IMMUTABLE' using errcode = '55000';
end;
$fonction$;

drop trigger if exists communication_envoi_transactionnel_historique
  on public.notification_envois;
create trigger communication_envoi_transactionnel_historique
  after insert or update of statut, tentative, code_erreur
  on public.notification_envois
  for each row execute function public.communication_journaliser_envoi_transactionnel();
drop trigger if exists communication_historique_envoi_immuable
  on public.communication_transactionnelle_historique;
create trigger communication_historique_envoi_immuable
  before update or delete on public.communication_transactionnelle_historique
  for each row execute function public.communication_historique_envoi_immuable();
drop trigger if exists communication_historique_envoi_truncate_interdit
  on public.communication_transactionnelle_historique;
create trigger communication_historique_envoi_truncate_interdit
  before truncate on public.communication_transactionnelle_historique
  for each statement execute function public.communication_interdire_truncate();

create or replace view public.communication_transactionnelle_outbox as
select e.id as envoi_id,
       n.id as notification_id,
       n.cle as cle_idempotence,
       case when n.historique_id is not null then 'colis_historique'
            when n.paiement_id is not null then 'paiement'
            when n.facture_id is not null then 'facture'
            else 'autre' end as source_evenement_type,
       coalesce(n.historique_id::text, n.paiement_id::text, n.facture_id::text) as source_evenement_id,
       n.type as type_notification,
       nullif(n.donnees ->> '_communication_modele_version', '')::integer as modele_version,
       nullif(n.donnees ->> '_communication_modele_langue', '') as modele_langue,
       e.canal,
       e.cree_le as prepare_le,
       e.statut,
       e.tentative,
       e.code_erreur,
       e.maj_le
  from public.notification_envois e
  join public.notifications n on n.id = e.notification_id
 where n.categorie in ('colis', 'factures', 'paiements')
   and n.type <> 'test';

revoke all on public.communication_transactionnelle_outbox
  from public, anon, authenticated, service_role;

create or replace function public.communication_lister_outbox_transactionnel(p_limite integer default 100)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare
  v_limite integer := least(greatest(coalesce(p_limite, 100), 1), 500);
begin
  perform public.exiger_permission('communications.view');
  return coalesce((
    select jsonb_agg(to_jsonb(ligne) order by ligne.prepare_le desc, ligne.envoi_id desc)
      from (
        select * from public.communication_transactionnelle_outbox
         order by prepare_le desc, envoi_id desc
         limit v_limite
      ) ligne
  ), '[]'::jsonb);
end;
$fonction$;

create or replace function public.communication_previsualiser_transactionnelle(
  p_notification bigint, p_langue text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare
  v_n public.notifications;
  v_langue text;
  v_modele jsonb;
begin
  perform public.exiger_permission('communications.view');
  select * into v_n from public.notifications n where n.id = p_notification;
  if not found or v_n.categorie not in ('colis', 'factures', 'paiements') then
    perform public.erreur_metier('NOTIFICATION_NOT_FOUND', 'Notification transactionnelle introuvable.');
  end if;

  v_langue := case when p_langue in ('fr', 'en', 'es', 'ht') then p_langue
                   else coalesce(v_n.donnees ->> '_communication_modele_langue',
                                 public.langue_notification((select c.langue from public.clients c
                                                              where c.id = v_n.client_id))) end;
  v_modele := public.communication_rendre_modele_transactionnel(
    v_n.type, v_langue, v_n.donnees,
    nullif(v_n.donnees ->> '_communication_modele_version', '')::integer);
  if v_modele is null then
    perform public.erreur_metier('COMMUNICATION_TEMPLATE_UNAVAILABLE', 'Modèle transactionnel indisponible.');
  end if;
  return jsonb_build_object(
    'notification_id', v_n.id,
    'type', v_n.type,
    'version', nullif(v_n.donnees ->> '_communication_modele_version', '')::integer,
    'langue', v_langue,
    'modele', v_modele);
end;
$fonction$;

revoke execute on function public.communication_modele_immuable() from public, anon, authenticated, service_role;
revoke execute on function public.communication_interdire_truncate() from public, anon, authenticated, service_role;
revoke execute on function public.communication_attacher_modele_transactionnel() from public, anon, authenticated, service_role;
revoke execute on function public.communication_verifier_canal_modele_transactionnel() from public, anon, authenticated, service_role;
revoke execute on function public.communication_rendre_modele_transactionnel(text, text, jsonb, integer)
  from public, anon, authenticated, service_role;
revoke execute on function public.communication_journaliser_envoi_transactionnel() from public, anon, authenticated, service_role;
revoke execute on function public.communication_historique_envoi_immuable() from public, anon, authenticated, service_role;
revoke execute on function public.communication_lister_outbox_transactionnel(integer) from public, anon;
revoke execute on function public.communication_previsualiser_transactionnelle(bigint, text) from public, anon;
grant execute on function public.communication_lister_outbox_transactionnel(integer) to authenticated;
grant execute on function public.communication_previsualiser_transactionnelle(bigint, text) to authenticated;

-- 4. Résultat incertain ------------------------------------------------------
-- Une absence de réponse après dépôt chez un fournisseur ne prouve pas que la
-- requête a échoué. L'état « incertain » bloque la reprise automatique afin
-- d'éviter un doublon ; une réconciliation explicite reste nécessaire.
-- Décision K (CEO, 23/11/2026) : pour les notifications transactionnelles, un
-- silence, une erreur réseau ou une réponse 408, 425 ou 5xx est au contraire
-- réessayé comme dans le moteur officiel ; c'est la version de
-- lire_reponse_envoi de 005 (appliquée après celle-ci) qui en décide.

-- Correction du 23/11/2026 (étape C11, trouvée par le rejeu de la chaîne) : la 009 ajoute
-- le statut « confirmation » (codes WhatsApp). Rejouée sur une base où la 009 est déjà
-- passée, cette contrainte doit le garder, sinon elle échoue dès qu'une ligne l'a.
alter table public.notification_envois
  drop constraint if exists notification_envois_statut_check;
do $statuts$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'notification_envois'
                and column_name = 'communication_confirmation_demande_id') then
    alter table public.notification_envois
      add constraint notification_envois_statut_check
      check (statut in ('attente', 'envoi', 'envoye', 'livre', 'echec', 'annule', 'incertain', 'confirmation'));
  else
    alter table public.notification_envois
      add constraint notification_envois_statut_check
      check (statut in ('attente', 'envoi', 'envoye', 'livre', 'echec', 'annule', 'incertain'));
  end if;
end
$statuts$;

create or replace function public.lire_reponse_envoi(
  p_envoi public.notification_envois, p_code integer, p_contenu text, p_erreur text)
returns void
language plpgsql
security definer
set search_path = ''
as $fonction$
declare
  v_json jsonb;
  v_ticket jsonb;
  v_id text;
  v_code text;
  v_temporaire boolean := false;
  v_incertain boolean := false;
  v_max integer := (select tentatives_max from public.notification_moteur);
begin
  begin
    v_json := p_contenu::jsonb;
  exception when others then
    v_json := null;
  end;

  if p_erreur = 'SANS_REPONSE' then
    v_incertain := true;
    v_code := 'RESULTAT_INCERTAIN';
  elsif p_erreur is not null then
    v_temporaire := true;
    v_code := 'RESEAU';
  elsif p_code between 200 and 299 then
    if p_envoi.canal = 'push' then
      v_ticket := coalesce(v_json -> 'data' -> 0, v_json -> 'data');
      if v_ticket ->> 'status' = 'ok' then
        v_id := v_ticket ->> 'id';
      else
        v_code := coalesce(v_ticket -> 'details' ->> 'error', 'EXPO_ERREUR');
        v_temporaire := v_code in ('MessageRateExceeded', 'ExpoError');
        if v_code = 'DeviceNotRegistered' then
          delete from public.appareils where id = p_envoi.appareil_id;
        end if;
      end if;
    else
      v_id := coalesce(v_json ->> 'messageId', v_json ->> 'id', v_json -> 'messages' -> 0 ->> 'id');
    end if;
  elsif p_code in (408, 425, 429) or p_code >= 500 then
    v_temporaire := true;
    v_code := 'HTTP_' || p_code;
  else
    v_code := 'HTTP_' || coalesce(p_code, 0);
  end if;

  if v_incertain then
    update public.notification_envois
       set statut = 'incertain', code_erreur = 'RESULTAT_INCERTAIN', erreur = null,
           verrouille_le = null, maj_le = now()
     where id = p_envoi.id;
  elsif v_code is null then
    update public.notification_envois
       set statut = 'envoye', message_id = left(v_id, 200), envoye_le = now(),
           code_erreur = null, erreur = null, verrouille_le = null, maj_le = now()
     where id = p_envoi.id;
  elsif v_temporaire and p_envoi.tentative < v_max then
    update public.notification_envois
       set statut = 'attente', code_erreur = v_code, verrouille_le = null, maj_le = now(),
           prochain_essai_le = now() + case p_envoi.tentative
             when 1 then interval '30 seconds'
             when 2 then interval '2 minutes'
             else interval '10 minutes' end
     where id = p_envoi.id;
  else
    update public.notification_envois
       set statut = 'echec',
           code_erreur = case when v_temporaire then 'ABANDON_' || v_code else v_code end,
           erreur = left(coalesce(v_json ->> 'message', v_json -> 'error' ->> 'message',
                                  v_json ->> 'code', p_erreur, ''), 200),
           verrouille_le = null, maj_le = now()
     where id = p_envoi.id;
  end if;
end;
$fonction$;

-- Le même travailleur traite les réponses séparément des nouvelles sorties.
-- Il ne verrouille jamais une ligne N4 avant N0 et ne prépare qu'une sortie par
-- transaction : le marqueur N0 de P-07 ne peut ainsi autoriser un second message.
create or replace function public.traiter_notifications(p_lot integer default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fonction$
declare
  v_lot integer := coalesce(p_lot, (select lot from public.notification_moteur), 50);
  v_lus integer := 0;
  v_partis integer := 0;
  v_rates integer := 0;
  e public.notification_envois;
  c public.notification_envois;
  r record;
  v_requete bigint;
  v_raison text;
  v_message text;
  v_detail text;
begin
  perform pg_catalog.set_config('lock_timeout', '2s', true);

  -- Les lignes sans réponse ne sont pas verrouillées : elles restent en envoi
  -- et sont comptées par la confirmation d'arrêt sans inversion N4 → N0.
  for e in
    select q.*
      from public.notification_envois q
     where q.statut = 'envoi'
       and (exists (select 1 from net._http_response h where h.id = q.requete)
            or q.verrouille_le < pg_catalog.now() - interval '10 minutes')
     order by q.verrouille_le
     limit v_lot * 4
     for update of q skip locked
  loop
    select status_code, content, error_msg into r
      from net._http_response where id = e.requete;
    if found then
      perform public.lire_reponse_envoi(e, r.status_code, r.content, r.error_msg);
    else
      perform public.lire_reponse_envoi(e, null, null, 'SANS_REPONSE');
    end if;
    v_lus := v_lus + 1;
  end loop;

  -- Libérer les verrous N4 des réponses avant toute tentative de sortie.
  if v_lus > 0 then
    return pg_catalog.jsonb_build_object(
      'reponses_lues', v_lus, 'envoyes', v_partis, 'non_partis', v_rates);
  end if;

  -- N0 partagé d'abord (ordre V0 → V4), puis les lignes du lot verrouillées en
  -- SKIP LOCKED : des travailleurs simultanés se partagent la file au lieu de
  -- viser tous les mêmes lignes. Chaque ligne repasse ensuite la porte, qui relit
  -- l'état de l'arrêt. Correction du 23/11/2026 : les lignes étaient lues sans
  -- verrou, et quatre travailleurs simultanés ne traitaient que le quart de la file.
  begin
    perform public.communication_verrou_interrupteurs(false);
  exception when lock_not_available then
    -- Une confirmation d'arrêt détient N0 exclusif : rien ne part ce passage-ci.
    return pg_catalog.jsonb_build_object(
      'reponses_lues', v_lus, 'envoyes', v_partis, 'non_partis', v_rates);
  end;
  for c in
    select q.*
      from public.notification_envois q
     where q.statut = 'attente' and q.prochain_essai_le <= pg_catalog.now()
     order by (q.priorite = 'haute') desc, q.prochain_essai_le
     limit v_lot
     for update of q skip locked
  loop
    begin
      v_raison := public.communication_autoriser_sortie('envoi', c.canal);
    exception when lock_not_available then
      v_rates := v_rates + 1;
      exit;
    end;
    if v_raison in ('CANAL_NON_AUTORISE', 'NATURE_NON_AUTORISEE') then
      -- Refus propre à CETTE ligne (par exemple un canal « sms », accepté par
      -- l'outbox mais par aucun adaptateur) : elle est annulée, et le lot continue.
      -- Correction du 23/11/2026 : la sortie de boucle laissait une telle ligne
      -- bloquer indéfiniment toutes les suivantes. Ordre des verrous : V0 (déjà
      -- tenu par la porte) puis V4, sans attente.
      perform pg_catalog.set_config('goship.sortie_autorisee', '', true);
      select * into e
        from public.notification_envois q
       where q.id = c.id and q.statut = 'attente'
       for update skip locked;
      if found then
        update public.notification_envois
           set statut = 'annule', code_erreur = v_raison, maj_le = pg_catalog.now()
         where id = e.id;
      end if;
      v_rates := v_rates + 1;
      continue;
    end if;
    if v_raison is not null then
      -- Arrêt d'urgence ou état d'arrêt illisible : aucun verrou d'envoi ni appel
      -- réseau n'a été pris ; la ligne reste due et le lot s'interrompt.
      v_rates := v_rates + 1;
      exit;
    end if;

    select * into e
      from public.notification_envois q
     where q.id = c.id
       and q.statut = 'attente'
       and q.prochain_essai_le <= pg_catalog.now()
     for update skip locked;
    if not found then
      perform pg_catalog.set_config('goship.sortie_autorisee', '', true);
      continue;
    end if;

    begin
      v_requete := public.expedier_envoi(e);
      update public.notification_envois
         set statut = 'envoi', requete = v_requete, tentative = tentative + 1,
             verrouille_le = pg_catalog.now(), maj_le = pg_catalog.now()
       where id = e.id;
      v_partis := v_partis + 1;
    exception when others then
      get stacked diagnostics v_message = message_text, v_detail = pg_exception_detail;
      if v_message = 'COMMUNICATION_OUTPUT_BLOCKED' then
        update public.notification_envois
           set statut = 'attente', code_erreur = coalesce(nullif(v_detail, ''), v_message),
               erreur = null, prochain_essai_le = pg_catalog.now() + interval '30 seconds',
               verrouille_le = null, maj_le = pg_catalog.now()
         where id = e.id;
        v_rates := v_rates + 1;
      else
        update public.notification_envois
           set statut = case when v_message in
                  ('NON_CONFIGURE', 'SANS_DESTINATAIRE', 'APPAREIL_INCONNU') then 'annule'
                            else 'echec' end,
               code_erreur = case when v_message in
                  ('NON_CONFIGURE', 'SANS_DESTINATAIRE', 'APPAREIL_INCONNU') then v_message
                                  else 'ERREUR_INTERNE' end,
               erreur = left(v_message, 200), maj_le = pg_catalog.now()
         where id = e.id;
        v_rates := v_rates + 1;
      end if;
    end;
    -- Une autorisation P-07 couvre cette seule ligne et ce seul adaptateur. La
    -- ligne suivante repasse la porte : elle relit l'état de l'arrêt (READ
    -- COMMITTED, nouvel instantané) et le lot s'interrompt dès qu'une demande
    -- d'arrêt est validée. Seul le travailleur rouvre ainsi la porte : un appel
    -- d'adaptateur qui n'est pas passé par lui reste refusé dans la transaction.
    -- Correction du 23/11/2026 : la version précédente sortait de la boucle après
    -- une seule transmission, soit un message par minute pour toute la plateforme.
    perform pg_catalog.set_config('goship.sortie_consommee', '', true);
  end loop;

  return pg_catalog.jsonb_build_object(
    'reponses_lues', v_lus, 'envoyes', v_partis, 'non_partis', v_rates);
end;
$fonction$;

commit;
