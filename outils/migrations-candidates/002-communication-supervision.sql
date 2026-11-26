-- CANDIDATE LOCALE — Communication Center.
-- En fin de outils/migrations.txt depuis le 23/11/2026 (étape C11) : essais locaux et CI
-- seulement. Ne pas appliquer à une base distante (critère C14 de docs/production/go-no-go.md).
-- Dépend de 001-communication-foundation.sql et de la permission centrale.

begin;

create or replace function public.sante_communications()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fonction$
declare
  v_travailleur jsonb;
  v_envois jsonb := jsonb_build_object(
    'disponible', false,
    'en_attente', null,
    'en_cours', null,
    'envoyes', null,
    'livres', null,
    'echecs', null,
    'incertains', null,
    'annules', null);
begin
  perform public.exiger_permission('communications.view');

  if pg_catalog.to_regclass('cron.job') is null
     or pg_catalog.to_regclass('cron.job_run_details') is null then
    v_travailleur := jsonb_build_object(
      'tables_disponibles', false,
      'present', false,
      'planifie_actif', null,
      'derniere_execution', null);
  else
    execute $requete$
      select jsonb_build_object(
        'tables_disponibles', true,
        'present', exists (
          select 1 from cron.job j where j.jobname = $1
        ),
        'planifie_actif', (
          select j.active from cron.job j where j.jobname = $1
        ),
        'derniere_execution', (
          select jsonb_build_object(
            'demarree_le', r.start_time,
            'statut', case
              when r.status in ('succeeded', 'failed', 'running', 'starting') then r.status
              else 'inconnu'
            end)
          from cron.job_run_details r
          where r.jobid = (select j.jobid from cron.job j where j.jobname = $1)
          order by r.start_time desc
          limit 1
        ))
    -- Décision A du 23/11/2026 : le Centre n'a pas de travailleur propre. Il réutilise
    -- la tâche officielle de outils/supabase-notifications.sql.
    $requete$ into v_travailleur using 'goship-notifications';
  end if;

  -- Outbox unique (décision A) : notification_envois et ses statuts réels.
  -- « confirmation » est l'attente d'un code WhatsApp à transmettre par l'Edge (009).
  -- Correction du 23/11/2026 : la version précédente lisait la table
  -- communication_envois des brouillons, qui n'existe pas, et des statuts
  -- inexistants (« traitement », « nouvel_essai », « lu », « abandon »).
  if pg_catalog.to_regclass('public.notification_envois') is not null then
    execute $requete$
      select jsonb_build_object(
        'disponible', true,
        'en_attente', count(*) filter (where statut in ('attente', 'confirmation')),
        'en_cours', count(*) filter (where statut = 'envoi'),
        'envoyes', count(*) filter (where statut = 'envoye'),
        'livres', count(*) filter (where statut = 'livre'),
        'echecs', count(*) filter (where statut = 'echec'),
        'incertains', count(*) filter (where statut = 'incertain'),
        'annules', count(*) filter (where statut = 'annule'))
      from public.notification_envois
    $requete$ into v_envois;
  end if;

  return jsonb_build_object(
    'evenements', (
      select jsonb_build_object(
        'recus_conserves', (select count(*) from public.communication_evenements_fournisseur),
        'a_traiter', count(*) filter (where t.etat = 'a_traiter'),
        'en_cours', null::integer,
        'en_cours_mesurable', false,
        'traites_conserves', count(*) filter (where t.etat = 'traite'),
        'echec', count(*) filter (where t.etat = 'echec'),
        'echec_prioritaires', count(*) filter (where t.etat = 'echec' and t.priorite = 1),
        'derniere_reception_le',
          (select max(e.recu_le) from public.communication_evenements_fournisseur e),
        'derniere_activite_le', max(t.traite_le))
      from public.communication_evenements_traitement t
    ),
    'envois', v_envois,
    'arret', (
      select jsonb_build_object('etat', a.etat)
      from public.communication_arret a
      where a.id is true
    ),
    'travailleur', v_travailleur);
end;
$fonction$;

revoke all on function public.sante_communications()
  from public, anon, authenticated, service_role;
grant execute on function public.sante_communications() to authenticated;

commit;
