-- CANDIDATE LOCALE — Communication Center, arrêt d'urgence côté Admin.
-- En fin de outils/migrations.txt depuis le 23/11/2026 (étape C11) : essais locaux et CI
-- seulement. Ne pas appliquer à une base distante (critère C14 de docs/production/go-no-go.md).
-- Dépend des candidates 001 (arrêt en deux temps) et 008 (dernière définition
-- de permissions_du_role).
--
-- Pourquoi : la candidate 001 réserve la demande et la confirmation de l'arrêt
-- à service_role et ne fournit aucune levée. L'Admin ne pouvait donc ni arrêter
-- les sorties depuis le tableau de bord, ni les rétablir sans SQL manuel. Cette
-- candidate ajoute des RPC protégées par une permission réservée à l'Admin
-- (décision C du 23/11/2026, docs/communication-center/
-- COMMUNICATION_CENTER_DECISIONS_DELEGUEES.md). Elle ne change pas la porte des
-- sorties, ni la règle selon laquelle la demande et la confirmation restent deux
-- appels, donc deux transactions.
begin;

do $garde$
begin
  if pg_catalog.to_regclass('public.communication_arret') is null
     or pg_catalog.to_regprocedure('public.communication_demander_arret(text)') is null
     or pg_catalog.to_regprocedure('public.communication_confirmer_arret()') is null
     or pg_catalog.to_regprocedure('public.communication_verrou_interrupteurs(boolean)') is null
     or pg_catalog.to_regprocedure('public.exiger_permission(text,uuid)') is null
     or pg_catalog.to_regprocedure('public.erreur_metier(text,text)') is null
     or pg_catalog.to_regprocedure('public.auditer(text,text,text,jsonb,jsonb)') is null
     or pg_catalog.to_regclass('public.communication_campagnes_marketing') is null then
    raise exception 'COMMUNICATION_C10_DEPENDENCY_MISSING';
  end if;
end
$garde$;

-- Reprise exacte de la candidate 008, avec une seule permission en plus pour
-- l'Admin : communications.emergency_stop. Le Gérant et l'Employé ne peuvent ni
-- arrêter ni rétablir les sorties.
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
      'communications.queue.retry', 'communications.campaigns.view',
      'communications.campaigns.manage', 'communications.campaigns.approve',
      'communications.emergency_stop']
    when 'gerant' then array[
      'clients.view', 'clients.create', 'clients.edit',
      'shipments.view', 'shipments.create', 'shipments.edit',
      'shipments.scan', 'shipments.change_status', 'shipments.correct', 'shipments.view_history',
      'invoices.view', 'invoices.create', 'invoices.edit', 'invoices.cancel',
      'payments.view', 'payments.create', 'payments.cancel',
      'reports.view', 'reports.create', 'users.view',
      'birthdays.view', 'programs.view', 'tracking.view', 'communications.view',
      'communications.campaigns.view', 'communications.campaigns.manage']
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

-- État affiché à l'écran. Toute personne qui voit la supervision voit si les
-- sorties sont arrêtées ; la version permet à la levée de refuser un état
-- qui a changé depuis l'affichage.
create or replace function public.communication_c10_arret_etat()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare
  a public.communication_arret;
begin
  perform public.exiger_permission('communications.view');
  select * into a from public.communication_arret where id is true;
  if not found then
    raise exception 'ARRET_LIGNE_ABSENTE';
  end if;
  return pg_catalog.jsonb_build_object(
    'etat', a.etat,
    'version', a.version,
    'demande_le', a.demande_le,
    'motif', a.motif,
    'confirme_le', a.confirme_le,
    'tentatives', a.tentatives,
    'derniere_raison', a.derniere_raison,
    'leve_le', a.leve_le,
    'peut_gerer', public.peut('communications.emergency_stop', null));
end;
$fonction$;

-- Premier appel de l'écran : la demande seule, validée par son propre COMMIT.
-- L'écran doit attendre la réponse avant d'appeler la confirmation.
create or replace function public.communication_c10_arret_demander(p_motif text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fonction$
declare
  v_resultat jsonb;
begin
  perform public.exiger_permission('communications.emergency_stop');
  v_resultat := public.communication_demander_arret(p_motif);
  if v_resultat ->> 'etat' in ('STOP_REQUESTED', 'STOP_CONFIRMED') then
    perform pg_catalog.set_config('goship.motif',
      pg_catalog.left(pg_catalog.btrim(coalesce(p_motif, '')), 300), true);
    perform public.auditer('communication.arret_demande', 'communication_arret', 'arret',
      null, pg_catalog.jsonb_build_object('etat', v_resultat ->> 'etat'));
  end if;
  return v_resultat;
end;
$fonction$;

-- Second appel, relancé par l'écran tant qu'il répond STOP_PENDING.
create or replace function public.communication_c10_arret_confirmer()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fonction$
begin
  perform public.exiger_permission('communications.emergency_stop');
  return public.communication_confirmer_arret();
end;
$fonction$;

-- Levée : N0 exclusif puis N0a, comme la confirmation. Elle est refusée si
-- l'état a changé depuis l'affichage (version) ou si une demande est arrivée
-- pendant l'attente des verrous. Les envois en attente reprennent ensuite sous
-- toutes les règles de la porte et du moteur transactionnel.
create or replace function public.communication_c10_arret_lever(
  p_motif text, p_version_attendue bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fonction$
declare
  a public.communication_arret;
  v_debut timestamptz := pg_catalog.clock_timestamp();
  v_motif text := pg_catalog.btrim(coalesce(p_motif, ''));
begin
  perform public.exiger_permission('communications.emergency_stop');
  if pg_catalog.current_setting('transaction_isolation') <> 'read committed' then
    raise exception 'ISOLATION_NON_SUPPORTEE' using errcode = '25001';
  end if;
  if pg_catalog.length(v_motif) < 10 then
    perform public.erreur_metier('REASON_REQUIRED',
      'Dites pourquoi l''envoi peut reprendre (10 caractères au moins).');
  end if;
  if p_version_attendue is null then
    perform public.erreur_metier('VERSION_REQUIRED',
      'Rechargez l''état de l''arrêt avant de le lever.');
  end if;

  perform pg_catalog.set_config('synchronous_commit', 'on', true);
  perform pg_catalog.set_config('lock_timeout', '3s', true); -- sous les 8 s du rôle authenticated
  begin
    perform public.communication_verrou_interrupteurs(true); -- N0 exclusif.
    select * into a from public.communication_arret where id is true for update; -- N0a.
  exception when lock_not_available then
    perform public.erreur_metier('BUSY',
      'Des envois ou un autre arrêt sont en cours : réessayez dans quelques secondes.');
  end;
  if a.id is null then
    raise exception 'ARRET_LIGNE_ABSENTE';
  end if;
  if a.etat = 'actif' then
    perform public.erreur_metier('INVALID_TRANSITION', 'Aucun arrêt d''urgence en cours.');
  end if;
  if a.version <> p_version_attendue then
    perform public.erreur_metier('STOP_STATE_CHANGED',
      'L''état de l''arrêt a changé depuis l''affichage : vérifiez la situation avant de relever.');
  end if;
  if a.derniere_demande_le > v_debut then
    perform public.erreur_metier('STOP_REQUESTED_DURING_LIFT',
      'Un arrêt a été demandé pendant la levée : vérifiez la situation avant de relever.');
  end if;

  update public.communication_arret
     set etat = 'actif',
         autorisations_closes_le = null,
         confirme_le = null,
         leve_le = pg_catalog.clock_timestamp(),
         leve_par = auth.uid(),
         motif_levee = pg_catalog.left(v_motif, 300),
         version = version + 1,
         maj_le = pg_catalog.clock_timestamp()
   where id is true;

  perform pg_catalog.set_config('goship.motif', pg_catalog.left(v_motif, 300), true);
  perform public.auditer('communication.arret_leve', 'communication_arret', 'arret',
    pg_catalog.jsonb_build_object('etat', a.etat, 'version', a.version),
    pg_catalog.jsonb_build_object('etat', 'actif', 'version', a.version + 1));
  return pg_catalog.jsonb_build_object('etat', 'actif', 'version', a.version + 1);
end;
$fonction$;

revoke all on function public.communication_c10_arret_etat(),
  public.communication_c10_arret_demander(text),
  public.communication_c10_arret_confirmer(),
  public.communication_c10_arret_lever(text, bigint)
  from public, anon, authenticated, service_role;
-- La permission est contrôlée dans chaque fonction ; authenticated doit
-- seulement pouvoir les appeler depuis le tableau de bord.
grant execute on function public.communication_c10_arret_etat(),
  public.communication_c10_arret_demander(text),
  public.communication_c10_arret_confirmer(),
  public.communication_c10_arret_lever(text, bigint)
  to authenticated;

commit;
