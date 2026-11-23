-- CANDIDATE LOCALE — Communication Center.
-- Hors de outils/migrations.txt. Ne pas appliquer à une base distante.
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
    'incertains', null);
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
    $requete$ into v_travailleur using 'goship-communications';
  end if;

  if pg_catalog.to_regclass('public.communication_envois') is not null
     and exists (
       select 1
       from pg_catalog.pg_attribute a
       where a.attrelid = pg_catalog.to_regclass('public.communication_envois')
         and a.attname = 'statut'
         and a.attnum > 0
         and not a.attisdropped
     ) then
    execute $requete$
      select jsonb_build_object(
        'disponible', true,
        'en_attente', count(*) filter (where statut in ('attente', 'nouvel_essai')),
        'en_cours', count(*) filter (where statut = 'traitement'),
        'envoyes', count(*) filter (where statut = 'envoye'),
        'livres', count(*) filter (where statut in ('livre', 'lu')),
        'echecs', count(*) filter (where statut in ('echec', 'abandon')),
        'incertains', count(*) filter (where statut = 'incertain'))
      from public.communication_envois
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
