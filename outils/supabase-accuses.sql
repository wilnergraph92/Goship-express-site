-- =============================================================================
-- Goship Express — les accusés de réception des notifications push (27/10/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce fichier
-- AJOUTE trois colonnes vides (deux à « notification_envois », une à
-- « notification_moteur »), une fonction et une tâche planifiée. Il ne remplace
-- aucune fonction existante, ne change aucune donnée existante, et peut être
-- relancé autant de fois qu'on veut.
--
-- Ordre d'installation : le dernier de la chaîne (outils/migrations.txt), après
-- supabase-identite.sql.
--
-- Pourquoi : quand Expo accepte une notification push (« ticket » ok), elle est
-- marquée « envoye ». Mais un téléphone dont l'application a été désinstallée ou
-- réinstallée n'est connu qu'APRÈS : Expo le dit dans l'accusé de réception
-- (« receipt »), disponible au bout de quelques minutes et gardé 24 heures. La
-- base ne lisait jamais ces accusés : les anciens identifiants de téléphone
-- s'accumulaient (huit pour un seul compte au 27/10), et chaque notification leur
-- était encore envoyée pour rien.
--
-- Ce que fait lire_accuses_push(), toutes les 5 minutes :
--    1. lit les réponses d'Expo arrivées depuis le passage précédent :
--         · accusé « ok »    → l'envoi passe à « livre » (remis au service de
--                              notifications de Google ou d'Apple ; ce n'est pas
--                              une preuve que le client l'a lu) ;
--         · accusé d'erreur  → « echec », avec le code d'Expo ; pour
--                              DeviceNotRegistered, le téléphone est oublié
--                              (supprimé de « appareils »), comme le faisait déjà
--                              lire_reponse_envoi quand Expo le refusait d'emblée ;
--         · pas encore d'accusé → redemandé au passage suivant, jusqu'à 24 h ;
--    2. demande à Expo les accusés des push acceptés il y a plus de 15 minutes,
--       par lots (une seule requête pour 300 envois au plus).
--
-- Règles :
--    · Seuls les push envoyés APRÈS l'installation de ce fichier sont lus
--      (notification_moteur.accuses_depuis) : aucun envoi plus ancien ne change.
--    · Le texte d'erreur d'Expo n'est pas recopié (il contient l'identifiant du
--      téléphone) : seul son code est gardé.
--    · Rien n'est ouvert aux comptes ni aux visiteurs : seule la tâche planifiée
--      appelle la fonction.
--    · Les premiers jours, les anciens téléphones désinstallés passent en échec
--      d'un coup : l'onglet Notifications peut alors montrer les alertes
--      « TAUX_ECHEC » (push) ou « APPAREILS_OUBLIES ». C'est le nettoyage, pas
--      une panne ; elles s'éteignent d'elles-mêmes.
--
-- Contenu :
--    1. garde : la chaîne est-elle à jour ?
--    2. les colonnes
--    3. lire_accuses_push
--    4. droits
--    5. la tâche planifiée
--    6. contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regclass('public.notification_envois') is null
     or to_regclass('public.notification_moteur') is null
     or to_regclass('public.appareils') is null
     or to_regprocedure('public.traiter_notifications(integer)') is null
     or to_regprocedure('public.lire_type_document(text)') is null then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt), puis ce fichier.';
  end if;
end;
$garde$;


-- 2. Les colonnes ------------------------------------------------------------------
-- accuses_depuis : posé une fois, à la première installation (la ligne unique du
-- moteur reçoit la valeur par défaut) ; une relance ne le change pas.
alter table public.notification_moteur add column if not exists accuses_depuis timestamptz not null default now();
-- accuse_requete : n° pg_net de la demande en cours ; accuse_le : accusé lu (ou abandonné)
alter table public.notification_envois add column if not exists accuse_requete bigint;
alter table public.notification_envois add column if not exists accuse_le timestamptz;

create index if not exists notification_envois_accuses_idx
  on public.notification_envois (envoye_le)
  where canal = 'push' and statut = 'envoye' and accuse_le is null;


-- 3. lire_accuses_push -----------------------------------------------------------------
create or replace function public.lire_accuses_push(p_lot integer default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_lot integer := least(greatest(coalesce(p_lot, 300), 1), 1000);
  v_depuis timestamptz := (select accuses_depuis from public.notification_moteur);
  rq record;
  r record;
  e record;
  v_json jsonb;
  v_accuse jsonb;
  v_code text;
  v_ids text[] := array[]::text[];
  v_envois bigint[] := array[]::bigint[];
  v_requete bigint;
  v_lues integer := 0;
  v_livres integer := 0;
  v_echecs integer := 0;
  v_oublies integer := 0;
  v_abandons integer := 0;
  v_clos integer := 0;
begin
  -- 1. Les réponses d'Expo arrivées depuis le passage précédent
  for rq in select distinct accuse_requete as id from public.notification_envois
             where accuse_requete is not null and accuse_le is null loop
    select status_code, content, error_msg into r from net._http_response where id = rq.id;
    if not found then
      -- Pas encore de réponse ; au-delà de 10 minutes, la demande est refaite
      update public.notification_envois set accuse_requete = null, maj_le = now()
       where accuse_requete = rq.id and accuse_le is null and maj_le < now() - interval '10 minutes';
      continue;
    end if;
    v_lues := v_lues + 1;
    begin
      v_json := r.content::jsonb;
    exception when others then
      v_json := null;
    end;
    if r.error_msg is not null or r.status_code is null or r.status_code not between 200 and 299
       or jsonb_typeof(v_json -> 'data') is distinct from 'object' then
      -- Réseau, Expo indisponible, réponse illisible : redemandé au passage suivant
      update public.notification_envois set accuse_requete = null, maj_le = now()
       where accuse_requete = rq.id and accuse_le is null;
      continue;
    end if;

    for e in select id, message_id, appareil_id, envoye_le from public.notification_envois
              where accuse_requete = rq.id and accuse_le is null for update loop
      v_accuse := v_json -> 'data' -> e.message_id;
      if v_accuse is null then
        -- Accusé pas encore prêt chez Expo ; il n'y est plus après 24 heures
        update public.notification_envois
           set accuse_requete = null,
               accuse_le = case when e.envoye_le < now() - interval '24 hours' then now() end,
               maj_le = now()
         where id = e.id;
        if e.envoye_le < now() - interval '24 hours' then
          v_abandons := v_abandons + 1;
        end if;
      elsif v_accuse ->> 'status' = 'ok' then
        update public.notification_envois
           set statut = 'livre', livre_le = now(), accuse_le = now(), accuse_requete = null, maj_le = now()
         where id = e.id;
        v_livres := v_livres + 1;
      else
        v_code := left(coalesce(nullif(v_accuse -> 'details' ->> 'error', ''), 'EXPO_ERREUR'), 60);
        -- Le message d'Expo n'est pas gardé : il cite l'identifiant du téléphone
        update public.notification_envois
           set statut = 'echec', code_erreur = v_code, erreur = 'Accusé de réception Expo : ' || v_code,
               accuse_le = now(), accuse_requete = null, maj_le = now()
         where id = e.id;
        v_echecs := v_echecs + 1;
        if v_code = 'DeviceNotRegistered' and e.appareil_id is not null then
          -- Application désinstallée ou jeton révoqué : on oublie ce téléphone
          delete from public.appareils where id = e.appareil_id;
          if found then
            v_oublies := v_oublies + 1;
          end if;
        end if;
      end if;
    end loop;
  end loop;

  -- 2. Les push trop anciens pour avoir encore un accusé chez Expo (tâche arrêtée
  --    plus d'un jour…) : clos sans changer leur statut
  update public.notification_envois
     set accuse_le = now(), maj_le = now()
   where canal = 'push' and statut = 'envoye' and accuse_le is null and accuse_requete is null
     and envoye_le >= v_depuis and envoye_le < now() - interval '24 hours';
  get diagnostics v_clos = row_count;
  v_abandons := v_abandons + v_clos;

  -- 3. Les nouvelles demandes : push acceptés il y a plus de 15 minutes, un lot à la fois.
  --    Un accusé pas encore prêt n'est redemandé qu'au passage suivant (maj_le) : Expo
  --    n'aurait pas eu le temps de le préparer.
  for e in select id, message_id from public.notification_envois
            where canal = 'push' and statut = 'envoye' and message_id is not null and message_id <> ''
              and accuse_requete is null and accuse_le is null
              and envoye_le >= greatest(v_depuis, now() - interval '23 hours')
              and envoye_le <= now() - interval '15 minutes'
              and maj_le <= now() - interval '4 minutes'
            order by envoye_le
            limit v_lot for update skip locked loop
    v_ids := v_ids || e.message_id;
    v_envois := v_envois || e.id;
  end loop;
  if coalesce(array_length(v_ids, 1), 0) > 0 then
    select net.http_post(
      url := 'https://exp.host/--/api/v2/push/getReceipts',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Accept', 'application/json'),
      body := jsonb_build_object('ids', to_jsonb(v_ids))
    ) into v_requete;
    update public.notification_envois set accuse_requete = v_requete, maj_le = now()
     where id = any (v_envois);
  end if;

  return jsonb_build_object('reponses_lues', v_lues, 'livres', v_livres, 'echecs', v_echecs,
                            'telephones_oublies', v_oublies, 'clos_sans_accuse', v_abandons,
                            'demandes', coalesce(array_length(v_ids, 1), 0));
end;
$$;


-- 4. Droits --------------------------------------------------------------------------
revoke execute on function public.lire_accuses_push(integer) from public, anon, authenticated;


-- 5. La tâche planifiée ------------------------------------------------------------------
-- Toutes les 5 minutes. Sans pg_cron, rien ne se perd : les envois gardent
-- simplement leur statut « envoye » (voir supabase-notifications.sql, partie 15).
do $cron$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('goship-accuses-push', '*/5 * * * *', 'select public.lire_accuses_push()');
  else
    raise notice 'pg_cron absent : la lecture des accusés ne tournera pas tant qu''il n''est pas activé.';
  end if;
end
$cron$;


-- 6. Contrôle ----------------------------------------------------------------------------
-- colonnes : 3 ; fonction : 1 ; ouverte_aux_visiteurs : false ; tache : 1
-- (0 si pg_cron n'est pas activé : voir la partie 5).
select (select count(*) from information_schema.columns
         where table_schema = 'public'
           and ((table_name = 'notification_envois' and column_name in ('accuse_requete', 'accuse_le'))
             or (table_name = 'notification_moteur' and column_name = 'accuses_depuis'))) as colonnes,
       (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = 'lire_accuses_push') as fonction,
       has_function_privilege('anon', 'public.lire_accuses_push(integer)', 'execute')
         or has_function_privilege('authenticated', 'public.lire_accuses_push(integer)', 'execute') as ouverte_aux_visiteurs,
       case when to_regclass('cron.job') is null then 0
            else (xpath('/row/n/text()', query_to_xml(
                    'select count(*) as n from cron.job where jobname = ''goship-accuses-push''', false, true, '')))[1]::text::integer
       end as tache;
