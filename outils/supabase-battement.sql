-- =============================================================================
-- Goship Express — le battement de cœur de la base (lot 1 du contrôle qualité, 16/11/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce fichier
-- AJOUTE une fonction et une tâche planifiée. Il ne change aucune table, aucune
-- donnée, aucune fonction existante, et se relance autant de fois qu'on veut.
--
-- Ordre d'installation : le dernier de la chaîne (outils/migrations.txt), après
-- supabase-double-auth.sql.
--
-- Pourquoi : le contrôle qualité du 16/11/2026 a trouvé que personne ne serait prévenu
-- d'une panne. La surveillance de GitHub (surveillance.yml) est prévue toutes les
-- 30 minutes, mais GitHub ne lance les tâches planifiées d'un dépôt gratuit qu'« au
-- mieux » : en moyenne toutes les 6 h 24, jusqu'à 10 h 48 d'écart. pg_cron, lui,
-- tourne chaque minute dans la base (il envoie déjà les e-mails).
--
-- Ce que fait ce fichier : toutes les 30 minutes, battement() demande à la base si
-- elle va bien (sante() : la file des notifications avance ; et aucune tâche
-- planifiée « goship-… » n'a échoué depuis 35 minutes), puis prévient Healthchecks.io
-- (gratuit, décidé par le CEO) :
--    tout va bien      → un appel à l'adresse du contrôle ;
--    quelque chose cloche → un appel à l'adresse + « /fail », avec la raison (des
--                         noms de tâches et d'états, jamais une donnée de client) ;
--    la base, pg_cron ou pg_net ne tournent plus → plus aucun appel : au bout de
--                         30 minutes de grâce, Healthchecks prévient lui-même
--                         (e-mail, SMS, plusieurs personnes).
--
-- L'adresse du contrôle (https://hc-ping.com/…) est rangée dans le coffre, comme les
-- autres réglages : quiconque la connaît peut faire croire que tout va bien. On la pose
-- une fois, dans le SQL Editor (voir docs/production/monitoring.md, « Healthchecks.io ») :
--    select public.definir_reglage('battement_url', 'https://hc-ping.com/<identifiant>');
-- Sans adresse, battement() ne fait rien (« non_configure ») : aucun appel ne part.
--
-- Contenu :
--    1. garde : la chaîne est-elle à jour ?
--    2. battement()
--    3. droits
--    4. la tâche planifiée
--    5. contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regprocedure('public.sante()') is null
     or to_regprocedure('public.lire_reglage(text)') is null
     or to_regprocedure('public.ma_double_auth()') is null then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt), jusqu''à supabase-double-auth.sql, puis ce fichier.';
  end if;
end;
$garde$;


-- 2. battement() -------------------------------------------------------------------
-- Rend ce qui a été envoyé (pour le SQL Editor et le banc d'essai). L'adresse n'est
-- acceptée que chez Healthchecks (hc-ping.com, en https) : un réglage mal tapé ne peut
-- pas envoyer l'état de la base ailleurs.
create or replace function public.battement()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text := btrim(coalesce(public.lire_reglage('battement_url'), ''));
  v_sante jsonb;
  v_echecs text[] := array[]::text[];
  v_pret boolean;
  v_corps jsonb;
begin
  if v_url = '' then
    return jsonb_build_object('envoye', false, 'raison', 'non_configure');
  end if;
  if v_url !~ '^https://hc-ping\.com/[A-Za-z0-9_/-]+$' then
    return jsonb_build_object('envoye', false, 'raison', 'adresse_refusee');
  end if;
  v_url := regexp_replace(v_url, '/+$', '');

  v_sante := public.sante();
  -- Une tâche planifiée de GoShip qui a échoué depuis 35 minutes (e-mails, suivi des
  -- transporteurs, accusés de réception…) : son nom seulement
  if to_regclass('cron.job_run_details') is not null and to_regclass('cron.job') is not null then
    execute $q$select coalesce(array_agg(distinct j.jobname order by j.jobname), array[]::text[])
                 from cron.job_run_details d join cron.job j on j.jobid = d.jobid
                where j.jobname like 'goship-%' and j.jobname <> 'goship-battement'
                  and d.status = 'failed' and d.start_time > now() - interval '35 minutes'$q$
       into v_echecs;
  end if;
  v_pret := coalesce((v_sante ->> 'pret')::boolean, false) and cardinality(v_echecs) = 0;
  v_corps := jsonb_build_object('pret', v_pret, 'notifications', v_sante ->> 'notifications',
                                'taches_en_echec', to_jsonb(v_echecs), 'heure', now());
  perform net.http_post(
    url := v_url || case when v_pret then '' else '/fail' end,
    body := v_corps,
    headers := jsonb_build_object('Content-Type', 'application/json'),
    timeout_milliseconds := 10000);
  return jsonb_build_object('envoye', true, 'pret', v_pret, 'corps', v_corps);
end;
$$;


-- 3. Droits --------------------------------------------------------------------------
-- Ouverte à personne : seule la tâche planifiée (et le SQL Editor) l'appelle.
revoke execute on function public.battement() from public, anon, authenticated;


-- 4. La tâche planifiée ------------------------------------------------------------------
-- À 4 et 34 de chaque heure : loin des tâches de la minute pile.
do $cron$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('goship-battement', '4,34 * * * *', 'select public.battement()');
  else
    raise notice 'pg_cron absent : le battement ne partira pas tant qu''il n''est pas activé.';
  end if;
end
$cron$;


-- 5. Contrôle ------------------------------------------------------------------------
-- fonction : 1 ; ouverte : false ; tache : 1 (0 sans pg_cron) ; adresse_posee : true une
-- fois l'adresse de Healthchecks rangée (false avant : rien ne part, voir l'en-tête).
-- La tâche est comptée dans un bloc : une requête qui nommerait cron.job échouerait sur
-- une base sans pg_cron, même derrière un « case ».
do $compte$
declare
  v integer := 0;
begin
  if to_regclass('cron.job') is not null then
    execute 'select count(*) from cron.job where jobname = ''goship-battement''' into v;
  end if;
  perform set_config('goship.controle_tache', v::text, false);
end
$compte$;
select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = 'battement') as fonction,
       (has_function_privilege('anon', 'public.battement()', 'execute')
        or has_function_privilege('authenticated', 'public.battement()', 'execute')) as ouverte,
       current_setting('goship.controle_tache')::integer as tache,
       (public.lire_reglage('battement_url') is not null) as adresse_posee;
