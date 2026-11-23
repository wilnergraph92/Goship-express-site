-- C5 — RPC d'interface opérationnelle du Communication Center.
-- Candidate locale, hors de outils/migrations.txt. Ne pas appliquer à distance.
-- Dépend des candidates 001–006. Les permissions d'écriture et de consentement
-- sont ajoutées à l'Administrateur uniquement ; le Manager garde communications.view.

begin;

do $garde$
begin
  if pg_catalog.to_regclass('public.communication_transactionnelle_outbox') is null
     or pg_catalog.to_regclass('public.communication_transactionnelle_historique') is null
     or pg_catalog.to_regclass('public.communication_evenements_traitement_historique') is null
     or pg_catalog.to_regclass('public.communication_consentements_clients') is null
     or pg_catalog.to_regclass('public.communication_confirmations_whatsapp') is null
     or pg_catalog.to_regprocedure('public.sante_communications()') is null
     or pg_catalog.to_regprocedure('public.exiger_permission(text,uuid)') is null then
    raise exception 'COMMUNICATION_C5_DEPENDENCY_MISSING';
  end if;
end
$garde$;

-- Les nouvelles permissions sont attribuées à l'Admin seulement. Le tableau
-- du Manager reste identique : communications.view ne donne aucune écriture.
create or replace function public.permissions_du_role(p_role text)
returns text[]
language sql
immutable
set search_path = ''
as $fonction$
  select case p_role
    when 'admin' then array[
      'clients.view', 'clients.create', 'clients.edit',
      'shipments.view', 'shipments.create', 'shipments.edit', 'shipments.delete',
      'shipments.scan', 'shipments.change_status', 'shipments.correct', 'shipments.view_history',
      'invoices.view', 'invoices.create', 'invoices.edit', 'invoices.cancel',
      'payments.view', 'payments.create', 'payments.cancel',
      'reports.view', 'reports.create', 'reports.edit', 'reports.delete',
      'users.view', 'roles.manage', 'settings.manage', 'audit_logs.view',
      'birthdays.view', 'birthdays.manage', 'programs.view', 'programs.manage', 'points.adjust',
      'tracking.view', 'tracking.manage', 'communications.view',
      'communications.templates.manage', 'communications.consents.view',
      'communications.queue.retry']
    when 'gerant' then array[
      'clients.view', 'clients.create', 'clients.edit',
      'shipments.view', 'shipments.create', 'shipments.edit',
      'shipments.scan', 'shipments.change_status', 'shipments.correct', 'shipments.view_history',
      'invoices.view', 'invoices.create', 'invoices.edit', 'invoices.cancel',
      'payments.view', 'payments.create', 'payments.cancel',
      'reports.view', 'reports.create', 'users.view',
      'birthdays.view', 'programs.view', 'tracking.view', 'communications.view']
    when 'employe' then array[
      'clients.view', 'clients.create',
      'shipments.view', 'shipments.create', 'shipments.edit',
      'shipments.scan', 'shipments.change_status', 'shipments.view_history',
      'invoices.view', 'payments.view', 'tracking.view']
    when 'client' then array[
      'clients.view:own', 'clients.edit:own',
      'shipments.view:own', 'shipments.view_history:own',
      'invoices.view:own', 'payments.view:own']
    else array[]::text[]
  end
$fonction$;

-- Journal append-only des actions administratives C5. Il ne contient ni texte
-- de modèle, ni données client, ni cible, ni charge fournisseur.
create table if not exists public.communication_interface_audit (
  id          bigint generated always as identity primary key,
  action      text not null check (action in ('modele_version_creee', 'evenement_repris')),
  acteur      uuid not null references public.clients(id) on delete restrict,
  type        text,
  reference   bigint,
  details     jsonb not null default '{}'::jsonb,
  cree_le     timestamptz not null default clock_timestamp()
);
alter table public.communication_interface_audit enable row level security;
revoke all on public.communication_interface_audit from public, anon, authenticated, service_role;

create or replace function public.communication_c5_audit_immuable()
returns trigger
language plpgsql
set search_path = ''
as $fonction$
begin
  raise exception 'COMMUNICATION_AUDIT_IMMUTABLE' using errcode = '55000';
end
$fonction$;
drop trigger if exists communication_c5_audit_immuable on public.communication_interface_audit;
create trigger communication_c5_audit_immuable
  before update or delete on public.communication_interface_audit
  for each row execute function public.communication_c5_audit_immuable();
drop trigger if exists communication_c5_audit_truncate_interdit on public.communication_interface_audit;
create trigger communication_c5_audit_truncate_interdit
  before truncate on public.communication_interface_audit
  for each statement execute function public.communication_c5_audit_immuable();

-- Vue opérationnelle enrichie sans fabriquer les compteurs non mesurables.
create or replace function public.communication_c5_sante()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare
  v_sante jsonb;
  v_derniere timestamptz;
  v_alertes jsonb := '[]'::jsonb;
  v_echecs_prioritaires bigint;
  v_incertains bigint;
begin
  perform public.exiger_permission('communications.view');
  v_sante := public.sante_communications();

  select max(activite) into v_derniere
    from (
      select max(e.recu_le) as activite from public.communication_evenements_fournisseur e
      union all
      select max(t.traite_le) from public.communication_evenements_traitement t
      union all
      select max(en.maj_le)
        from public.notification_envois en
        join public.notifications n on n.id = en.notification_id
       where n.categorie in ('colis', 'factures', 'paiements') and n.type <> 'test'
    ) activites;

  v_echecs_prioritaires := coalesce((v_sante #>> '{evenements,echec_prioritaires}')::bigint, 0);
  if v_echecs_prioritaires > 0 then
    v_alertes := v_alertes || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('code', 'EVENEMENTS_PRIORITAIRES_EN_ECHEC', 'compte', v_echecs_prioritaires));
  end if;
  if v_sante #>> '{envois,disponible}' = 'true' then
    v_incertains := coalesce((v_sante #>> '{envois,incertains}')::bigint, 0);
    if v_incertains > 0 then
      v_alertes := v_alertes || pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('code', 'TRANSMISSIONS_INCERTAINES', 'compte', v_incertains));
    end if;
  end if;

  return v_sante || pg_catalog.jsonb_build_object(
    'activite', pg_catalog.jsonb_build_object('derniere_le', v_derniere),
    'alertes', v_alertes);
end
$fonction$;

-- Historique paginé, filtrable, expurgé des coordonnées, du contenu et des IDs
-- fournisseur. Le code GoShip et le numéro de colis ne sont renvoyés qu'aux
-- comptes possédant aussi clients.view / shipments.view.
create or replace function public.communication_c5_historique(
  p_debut timestamptz default null,
  p_fin timestamptz default null,
  p_canal text default null,
  p_statut text default null,
  p_type text default null,
  p_recherche text default '',
  p_page integer default 0,
  p_par_page integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare
  v_debut integer := greatest(coalesce(p_page, 0), 0);
  v_par_page integer := least(greatest(coalesce(p_par_page, 50), 1), 100);
  v_recherche text := pg_catalog.btrim(coalesce(p_recherche, ''));
  v_total bigint;
  v_lignes jsonb;
begin
  perform public.exiger_permission('communications.view');
  if p_debut is not null and p_fin is not null and p_fin <= p_debut then
    raise exception 'COMMUNICATION_FILTER_DATE_RANGE_INVALID';
  end if;
  if p_canal is not null and p_canal not in ('push', 'email', 'whatsapp', 'sms') then
    raise exception 'COMMUNICATION_FILTER_CHANNEL_INVALID';
  end if;
  if p_statut is not null and p_statut not in ('attente', 'envoi', 'envoye', 'livre', 'echec', 'annule', 'incertain') then
    raise exception 'COMMUNICATION_FILTER_STATUS_INVALID';
  end if;
  if length(v_recherche) > 100 then raise exception 'COMMUNICATION_FILTER_SEARCH_TOO_LONG'; end if;
  if p_type is not null and not exists (select 1 from public.notification_regles r where r.type = p_type) then
    raise exception 'COMMUNICATION_FILTER_TYPE_INVALID';
  end if;

  with filtrage as (
    select en.id as envoi_id, n.id as notification_id, n.type as type_notification,
           en.canal, en.statut, en.tentative, en.code_erreur, en.cree_le as prepare_le,
           en.envoye_le, en.livre_le, en.maj_le,
           nullif(n.donnees ->> '_communication_modele_version', '')::integer as modele_version,
           nullif(n.donnees ->> '_communication_modele_langue', '') as modele_langue,
           cl.code as client_code, co.numero as colis_numero, f.numero as facture_numero
      from public.notification_envois en
      join public.notifications n on n.id = en.notification_id
      left join public.clients cl on cl.id = n.client_id
      left join public.colis co on co.id = n.colis_id
      left join public.factures f on f.id = n.facture_id
     where n.categorie in ('colis', 'factures', 'paiements') and n.type <> 'test'
       and (p_debut is null or en.cree_le >= p_debut)
       and (p_fin is null or en.cree_le < p_fin)
       and (p_canal is null or en.canal = p_canal)
       and (p_statut is null or en.statut = p_statut)
       and (p_type is null or n.type = p_type)
       and (v_recherche = '' or
            pg_catalog.strpos(pg_catalog.lower(coalesce(cl.code, '')), pg_catalog.lower(v_recherche)) > 0 or
            pg_catalog.strpos(pg_catalog.lower(coalesce(co.numero, '')), pg_catalog.lower(v_recherche)) > 0 or
            pg_catalog.strpos(pg_catalog.lower(coalesce(f.numero, '')), pg_catalog.lower(v_recherche)) > 0 or
            pg_catalog.strpos(pg_catalog.lower(coalesce(n.type, '')), pg_catalog.lower(v_recherche)) > 0)
  ), page as (
      select f.prepare_le, f.envoi_id,
             pg_catalog.jsonb_build_object(
               'envoi_id', f.envoi_id, 'notification_id', f.notification_id,
               'type', f.type_notification, 'canal', f.canal, 'statut', f.statut,
               'tentatives', f.tentative,
               'prepare_le', f.prepare_le, 'envoye_le', f.envoye_le, 'livre_le', f.livre_le,
               'maj_le', f.maj_le, 'modele_version', f.modele_version, 'modele_langue', f.modele_langue,
               'client_reference', case when public.peut('clients.view') then f.client_code else null end,
               'colis_reference', case when public.peut('shipments.view') then f.colis_numero else null end,
               'facture_reference', case when public.peut('invoices.view') then f.facture_numero else null end,
               'transitions', coalesce((
                 select jsonb_agg(pg_catalog.jsonb_build_object(
                   'statut', h.statut, 'tentatives', h.tentative,
                   'cree_le', h.cree_le)
                   order by h.cree_le, h.id)
                   from public.communication_transactionnelle_historique h
                  where h.notification_envoi_id = f.envoi_id
               ), '[]'::jsonb)) as obj
        from filtrage f
       order by f.prepare_le desc, f.envoi_id desc
       limit v_par_page offset v_debut * v_par_page
  )
  select (select count(*) from filtrage),
         coalesce((select jsonb_agg(page.obj order by page.prepare_le desc, page.envoi_id desc)
                     from page), '[]'::jsonb)
    into v_total, v_lignes;

  return pg_catalog.jsonb_build_object('total', v_total, 'page', v_debut,
    'par_page', v_par_page, 'lignes', v_lignes);
end
$fonction$;

-- Catalogue des modèles et des types autorisés. Les libellés de type viennent
-- des textes déjà traduits du moteur GoShip ; aucun type métier n'est inventé.
create or replace function public.communication_c5_modeles_lister()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare
  v_types jsonb;
  v_modeles jsonb;
begin
  perform public.exiger_permission('communications.view');
  select coalesce(jsonb_agg(pg_catalog.jsonb_build_object(
      'type', r.type, 'canaux_autorises', r.canaux,
      'libelles', coalesce((select jsonb_object_agg(locale.langue, locale.contenu ->> 'titre')
                             from jsonb_each(public.notification_textes() -> r.type)
                               as locale(langue, contenu)), '{}'::jsonb)) order by r.type), '[]'::jsonb)
    into v_types
    from public.notification_regles r
   where r.actif and r.source in ('colis', 'facturation', 'planifie')
     and r.type in (select m.type from public.communication_modeles_transactionnels m);

  select coalesce(jsonb_agg(pg_catalog.jsonb_build_object(
      'type', m.type, 'version', m.version, 'langue', m.langue,
      'titre', m.titre, 'message', m.message,
      'variables_requises', m.variables_requises, 'canaux', m.canaux,
      'modele_whatsapp', m.modele_whatsapp, 'cree_le', m.cree_le)
      order by m.type, m.version desc, m.langue), '[]'::jsonb)
    into v_modeles
    from (select * from public.communication_modeles_transactionnels
           order by type, version desc, langue limit 1000) m;

  return pg_catalog.jsonb_build_object('types', v_types, 'modeles', v_modeles,
    'variables_autorisees', pg_catalog.jsonb_build_array('numero', 'facture', 'montant'));
end
$fonction$;

-- Prévisualisation d'un brouillon sur une notification réelle de même type.
-- Seules les trois variables autorisées sont extraites des données GoShip.
create or replace function public.communication_c5_previsualiser_brouillon(
  p_notification bigint, p_type text, p_langue text, p_titre text, p_message text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare
  v_n public.notifications;
  v_langue text;
  v_numero text;
  v_facture text;
  v_montant numeric;
  v_variables jsonb;
begin
  perform public.exiger_permission('communications.view');
  if p_notification is null or p_type is null or p_langue is null
     or p_langue not in ('fr', 'en', 'es', 'ht')
     or p_titre is null or length(p_titre) not between 1 and 300
     or p_message is null or length(p_message) not between 1 and 3000 then
    raise exception 'COMMUNICATION_TEMPLATE_INPUT_INVALID';
  end if;
  if (p_titre || p_message) ~ '<[^>]*>' then raise exception 'COMMUNICATION_TEMPLATE_MARKUP_FORBIDDEN'; end if;
  select * into v_n from public.notifications n
   where n.id = p_notification and n.canal = 'app'
     and n.categorie in ('colis', 'factures', 'paiements') and n.type is not null;
  if not found then raise exception 'COMMUNICATION_NOTIFICATION_NOT_FOUND'; end if;
  if v_n.type is distinct from p_type then
    raise exception 'COMMUNICATION_NOTIFICATION_TYPE_MISMATCH';
  end if;

  v_langue := public.langue_notification(p_langue);
  select coalesce(nullif(v_n.donnees ->> 'numero', ''), co.numero),
         coalesce(nullif(v_n.donnees ->> 'facture', ''), f.numero),
         nullif(v_n.donnees ->> 'montant_usd', '')::numeric
    into v_numero, v_facture, v_montant
    from (select 1) x
    left join public.colis co on co.id = v_n.colis_id
    left join public.factures f on f.id = v_n.facture_id;
  v_variables := pg_catalog.jsonb_build_object(
    'numero', v_numero, 'facture', v_facture,
    'montant', case when v_montant is null then null
                    else public.montant_notification(v_montant, v_langue) end);
  if (pg_catalog.strpos(p_titre || p_message, '{{numero}}') > 0 and nullif(v_variables ->> 'numero', '') is null)
     or (pg_catalog.strpos(p_titre || p_message, '{{facture}}') > 0 and nullif(v_variables ->> 'facture', '') is null)
     or (pg_catalog.strpos(p_titre || p_message, '{{montant}}') > 0 and nullif(v_variables ->> 'montant', '') is null) then
    raise exception 'COMMUNICATION_TEMPLATE_VARIABLE_MISSING';
  end if;
  if pg_catalog.strpos(pg_catalog.replace(pg_catalog.replace(pg_catalog.replace(
       p_titre || p_message, '{{numero}}', ''), '{{facture}}', ''), '{{montant}}', ''), '{{') > 0
     or pg_catalog.strpos(pg_catalog.replace(pg_catalog.replace(pg_catalog.replace(
       p_titre || p_message, '{{numero}}', ''), '{{facture}}', ''), '{{montant}}', ''), '}}') > 0 then
    raise exception 'COMMUNICATION_TEMPLATE_VARIABLE_INVALID';
  end if;

  return pg_catalog.jsonb_build_object(
    'type', v_n.type, 'langue', v_langue,
    'titre', public.rendre_notification(p_titre, v_variables),
    'message', public.rendre_notification(p_message, v_variables));
end
$fonction$;

-- Une version complète contient les quatre langues. Aucun UPDATE/DELETE de
-- version historique : l'insertion est atomique et sérialisée par type.
create or replace function public.communication_c5_modele_nouvelle_version(
  p_type text, p_traductions jsonb, p_variables text[], p_canaux text[],
  p_modele_whatsapp text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'
as $fonction$
declare
  v_regle public.notification_regles;
  v_version integer;
  v_langues text[];
  v_variables_requises text[];
  v_variables_contenu text[];
  v_variables_reference text[];
  v_ligne record;
  v_sans_variables text;
begin
  perform public.exiger_permission('communications.templates.manage');
  if p_type is null or p_traductions is null or p_variables is null or p_canaux is null
     or cardinality(p_canaux) = 0 or cardinality(p_canaux) <> cardinality(array(select distinct unnest(p_canaux)))
     or cardinality(array_remove(p_canaux, null)) <> cardinality(p_canaux)
     or cardinality(array_remove(p_variables, null)) <> cardinality(p_variables)
     or not (coalesce(p_variables, '{}'::text[]) <@ array['numero', 'facture', 'montant']::text[]) then
    raise exception 'COMMUNICATION_TEMPLATE_INPUT_INVALID';
  end if;
  if pg_catalog.jsonb_typeof(p_traductions) <> 'array' then
    raise exception 'COMMUNICATION_TEMPLATE_INPUT_INVALID';
  end if;
  if pg_catalog.jsonb_array_length(p_traductions) <> 4
     or exists (
       select 1 from pg_catalog.jsonb_array_elements(p_traductions) as item(valeur)
        where pg_catalog.jsonb_typeof(item.valeur) <> 'object'
     ) then
    raise exception 'COMMUNICATION_TEMPLATE_INPUT_INVALID';
  end if;
  select * into v_regle from public.notification_regles r
   where r.type = p_type and r.actif and r.source in ('colis', 'facturation', 'planifie');
  if not found then raise exception 'COMMUNICATION_TEMPLATE_TYPE_INVALID'; end if;
  if not (p_canaux <@ v_regle.canaux) then raise exception 'COMMUNICATION_TEMPLATE_CHANNEL_INVALID'; end if;
  if 'whatsapp' = any(p_canaux)
     and (p_modele_whatsapp is null or p_modele_whatsapp !~ '^[a-z0-9_]{1,100}$') then
    raise exception 'COMMUNICATION_TEMPLATE_WHATSAPP_NAME_REQUIRED';
  end if;
  if not ('whatsapp' = any(p_canaux)) and p_modele_whatsapp is not null then
    raise exception 'COMMUNICATION_TEMPLATE_WHATSAPP_NAME_UNUSED';
  end if;

  select array_agg(distinct x.langue order by x.langue) into v_langues
    from jsonb_to_recordset(p_traductions) as x(langue text, titre text, message text);
  if v_langues is distinct from array['en', 'es', 'fr', 'ht']::text[] then
    raise exception 'COMMUNICATION_TEMPLATE_LANGUAGES_REQUIRED';
  end if;
  select coalesce(array_agg(x.variable order by x.ordre), '{}'::text[])
    into v_variables_requises
    from unnest(array['numero', 'facture', 'montant']::text[]) with ordinality as x(variable, ordre)
   where x.variable = any(p_variables);
  for v_ligne in select * from jsonb_to_recordset(p_traductions)
                 as x(langue text, titre text, message text)
  loop
    if v_ligne.langue not in ('fr', 'en', 'es', 'ht')
       or v_ligne.titre is null or length(v_ligne.titre) not between 1 and 300
       or v_ligne.message is null or length(v_ligne.message) not between 1 and 3000
       or (v_ligne.titre || v_ligne.message) ~ '<[^>]*>' then
      raise exception 'COMMUNICATION_TEMPLATE_INPUT_INVALID';
    end if;
    v_sans_variables := pg_catalog.replace(pg_catalog.replace(pg_catalog.replace(
      v_ligne.titre || v_ligne.message, '{{numero}}', ''), '{{facture}}', ''), '{{montant}}', '');
    if pg_catalog.strpos(v_sans_variables, '{{') > 0
       or pg_catalog.strpos(v_sans_variables, '}}') > 0 then
      raise exception 'COMMUNICATION_TEMPLATE_VARIABLE_INVALID';
    end if;
    v_variables_contenu := array_remove(array[
      case when pg_catalog.strpos(v_ligne.titre || v_ligne.message, '{{numero}}') > 0 then 'numero'::text end,
      case when pg_catalog.strpos(v_ligne.titre || v_ligne.message, '{{facture}}') > 0 then 'facture'::text end,
      case when pg_catalog.strpos(v_ligne.titre || v_ligne.message, '{{montant}}') > 0 then 'montant'::text end
    ], null);
    if v_variables_reference is null then
      v_variables_reference := v_variables_contenu;
    elsif v_variables_reference is distinct from v_variables_contenu then
      raise exception 'COMMUNICATION_TEMPLATE_VARIABLES_MISMATCH';
    end if;
  end loop;
  if coalesce(v_variables_reference, '{}'::text[]) is distinct from v_variables_requises then
    raise exception 'COMMUNICATION_TEMPLATE_VARIABLES_MISMATCH';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('goship:communication-template:' || p_type, 0));
  select coalesce(max(m.version), 0) + 1 into v_version
    from public.communication_modeles_transactionnels m where m.type = p_type;

  insert into public.communication_modeles_transactionnels
    (type, version, langue, titre, message, variables_requises, canaux, modele_whatsapp)
  select p_type, v_version, x.langue, x.titre, x.message,
         coalesce(p_variables, '{}'::text[]), p_canaux, p_modele_whatsapp
    from jsonb_to_recordset(p_traductions) as x(langue text, titre text, message text);

  insert into public.communication_interface_audit(action, acteur, type, reference, details)
  values ('modele_version_creee', auth.uid(), p_type, v_version,
          pg_catalog.jsonb_build_object('langues', v_langues, 'canaux', p_canaux,
            'variables_requises', coalesce(p_variables, '{}'::text[])));
  return pg_catalog.jsonb_build_object('type', p_type, 'version', v_version,
    'langues', v_langues, 'canaux', p_canaux);
end
$fonction$;

-- File expurgée : ni destinataire, empreinte, charge brute, code de confirmation,
-- ID message fournisseur ni erreur libre. L'outbox incertaine reste observable.
create or replace function public.communication_c5_file_lister(p_limite integer default 100)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare
  v_limite integer := least(greatest(coalesce(p_limite, 100), 1), 200);
  v_evenements jsonb;
  v_envois jsonb;
begin
  perform public.exiger_permission('communications.view');
  select coalesce(jsonb_agg(pg_catalog.jsonb_build_object(
      'id', q.evenement_id, 'fournisseur', e.fournisseur, 'type', e.type,
      'etat', q.etat, 'priorite', q.priorite, 'tentatives', q.tentatives,
      'code', q.dernier_code, 'resultat', q.resultat,
      'recu_le', e.recu_le, 'prochain_essai_le', q.prochain_essai_le,
      'traite_le', q.traite_le,
      'reprise_possible', q.etat = 'echec' and e.type = 'inbound'
        and q.classe = 'stop' and q.resultat in ('A_REVOIR', 'LIMITE_TENTATIVES'),
      'historique', coalesce((
        select jsonb_agg(pg_catalog.jsonb_build_object(
          'etat', h.nouvel_etat, 'tentatives', h.tentatives,
          'code', h.code, 'resultat', h.resultat, 'cree_le', h.cree_le)
          order by h.cree_le, h.id)
          from public.communication_evenements_traitement_historique h
         where h.evenement_id = q.evenement_id
      ), '[]'::jsonb)) order by e.recu_le desc, q.evenement_id desc), '[]'::jsonb)
    into v_evenements
    from (
      select t.* from public.communication_evenements_traitement t
       order by t.cree_le desc, t.evenement_id desc limit v_limite
    ) q
    join public.communication_evenements_fournisseur e on e.id = q.evenement_id;

  select coalesce(jsonb_agg(pg_catalog.jsonb_build_object(
      'envoi_id', o.envoi_id, 'notification_id', o.notification_id,
      'type', o.type_notification, 'canal', o.canal, 'statut', o.statut,
      'tentatives', o.tentative, 'code_erreur', o.code_erreur,
      'modele_version', o.modele_version, 'modele_langue', o.modele_langue,
      'prepare_le', o.prepare_le, 'maj_le', o.maj_le)
      order by o.prepare_le desc, o.envoi_id desc), '[]'::jsonb)
    into v_envois
    from (select * from public.communication_transactionnelle_outbox
           order by prepare_le desc, envoi_id desc limit v_limite) o;

  return pg_catalog.jsonb_build_object('evenements', v_evenements, 'envois', v_envois);
end
$fonction$;

-- La reprise manuelle ne vise qu'un STOP entrant idempotent déjà échoué. Les
-- retours e-mail non rapprochés et les transmissions incertaines sont exclus.
create or replace function public.communication_c5_evenement_reprendre(p_evenement bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '3s'
as $fonction$
declare
  v_traitement public.communication_evenements_traitement;
  v_type text;
begin
  perform public.exiger_permission('communications.queue.retry');
  select q.* into v_traitement
    from public.communication_evenements_traitement q
   where q.evenement_id = p_evenement
   for update;
  if not found then raise exception 'COMMUNICATION_EVENT_RETRY_NOT_SAFE'; end if;
  select e.type into v_type from public.communication_evenements_fournisseur e
   where e.id = v_traitement.evenement_id;
  if not found or v_traitement.etat <> 'echec'
     or v_type <> 'inbound' or v_traitement.classe <> 'stop'
     or v_traitement.resultat not in ('A_REVOIR', 'LIMITE_TENTATIVES') then
    raise exception 'COMMUNICATION_EVENT_RETRY_NOT_SAFE';
  end if;

  update public.communication_evenements_traitement
     set etat = 'a_traiter', prochain_essai_le = clock_timestamp(),
         resultat = 'REPRISE_ADMIN'
   where evenement_id = p_evenement;
  insert into public.communication_interface_audit(action, acteur, type, reference, details)
  values ('evenement_repris', auth.uid(), v_type, p_evenement,
          pg_catalog.jsonb_build_object('etat_precedent', v_traitement.etat,
            'resultat_precedent', v_traitement.resultat,
            'tentatives_conservees', v_traitement.tentatives));
  return pg_catalog.jsonb_build_object('ok', true, 'evenement_id', p_evenement,
    'etat', 'a_traiter', 'reprise_idempotente', true);
end
$fonction$;

-- Consultation des consentements marketing, réservée à l'Admin. Les empreintes,
-- coordonnées, codes et contenus juridiques ne quittent jamais les tables.
create or replace function public.communication_c5_consentements_lister(p_limite integer default 200)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare
  v_limite integer := least(greatest(coalesce(p_limite, 200), 1), 500);
  v_lignes jsonb;
begin
  perform public.exiger_permission('communications.consents.view');
  select coalesce(jsonb_agg(l.obj order by l.maj_le desc, l.id desc), '[]'::jsonb)
    into v_lignes
    from (
      select c.id, c.maj_le,
             pg_catalog.jsonb_build_object(
               'client_reference', case when public.peut('clients.view') then cl.code else null end,
               'canal', c.canal, 'finalite', c.finalite, 'etat', c.etat,
               'source', c.source, 'langue', c.langue, 'demande_le', c.demande_le,
               'confirme_le', c.confirme_le, 'retire_le', c.retire_le,
               'expiration_le', d.expire_le,
               'demandes', coalesce((
                 select jsonb_agg(pg_catalog.jsonb_build_object(
                   'etat', x.etat, 'cree_le', x.cree_le, 'expire_le', x.expire_le,
                   'termine_le', x.termine_le,
                   'tentatives', (select count(*) from public.communication_confirmation_tentatives t
                                  where t.demande_id = x.id))
                   order by x.cree_le desc)
                   from (select * from public.communication_confirmations_whatsapp q
                          where q.consentement_id = c.id
                          order by q.cree_le desc limit 20) x
               ), '[]'::jsonb),
               'historique', coalesce((
                 select jsonb_agg(pg_catalog.jsonb_build_object(
                   'action', h.action, 'source', h.source, 'langue', h.langue,
                   'cree_le', h.cree_le)
                   order by h.cree_le desc, h.id desc)
                   from (select * from public.communication_consentement_historique h
                          where h.consentement_id = c.id
                          order by h.cree_le desc, h.id desc limit 50) h
               ), '[]'::jsonb)) as obj
        from public.communication_consentements_clients c
        join public.clients cl on cl.id = c.client_id
        left join public.communication_confirmations_whatsapp d on d.id = c.demande_id
       order by c.maj_le desc, c.id desc
       limit v_limite
    ) l;
  return pg_catalog.jsonb_build_object('lignes', v_lignes);
end
$fonction$;

revoke all on function public.communication_c5_audit_immuable() from public, anon, authenticated, service_role;
revoke all on function public.communication_c5_sante() from public, anon, authenticated, service_role;
revoke all on function public.communication_c5_historique(timestamptz,timestamptz,text,text,text,text,integer,integer)
  from public, anon, service_role;
revoke all on function public.communication_c5_modeles_lister() from public, anon, service_role;
revoke all on function public.communication_c5_previsualiser_brouillon(bigint,text,text,text,text)
  from public, anon, service_role;
revoke all on function public.communication_c5_modele_nouvelle_version(text,jsonb,text[],text[],text)
  from public, anon, service_role;
revoke all on function public.communication_c5_file_lister(integer) from public, anon, service_role;
revoke all on function public.communication_c5_evenement_reprendre(bigint) from public, anon, service_role;
revoke all on function public.communication_c5_consentements_lister(integer) from public, anon, service_role;
grant execute on function public.communication_c5_sante() to authenticated;
grant execute on function public.communication_c5_historique(timestamptz,timestamptz,text,text,text,text,integer,integer) to authenticated;
grant execute on function public.communication_c5_modeles_lister() to authenticated;
grant execute on function public.communication_c5_previsualiser_brouillon(bigint,text,text,text,text) to authenticated;
grant execute on function public.communication_c5_modele_nouvelle_version(text,jsonb,text[],text[],text) to authenticated;
grant execute on function public.communication_c5_file_lister(integer) to authenticated;
grant execute on function public.communication_c5_evenement_reprendre(bigint) to authenticated;
grant execute on function public.communication_c5_consentements_lister(integer) to authenticated;

commit;
