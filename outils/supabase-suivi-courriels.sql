-- =============================================================================
-- Goship Express — le suivi des e-mails chez Brevo (27/10/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce fichier
-- AJOUTE deux colonnes vides (une à « notification_envois », une à
-- « notification_moteur »), un index, une fonction et une tâche planifiée. Il ne remplace aucune fonction existante, ne change aucune
-- donnée existante, et peut être relancé autant de fois qu'on veut.
--
-- Ordre d'installation : le dernier de la chaîne (outils/migrations.txt), après
-- supabase-accuses.sql, dont il reprend la colonne accuse_le (« suivi
-- terminé »). La demande en cours a sa propre colonne, suivi_requete :
-- lire_accuses_push relit toute ligne qui a une accuse_requete, quel que soit
-- son canal, et effacerait celles des e-mails.
--
-- Pourquoi : Brevo répond « 201 » dès qu'il ACCEPTE un e-mail, et c'est tout ce
-- que la base attendait pour le marquer « envoye ». Mais Brevo peut le refuser
-- quelques secondes plus tard : expéditeur non validé, adresse inexistante,
-- adresse bloquée. Du 26/10 à 10 h 16 au 27/10 à 6 h 44 UTC, tous les e-mails ont
-- ainsi été refusés (« the sender you used infos@goshipexpress.net is not
-- valid ») pendant que l'onglet Notifications les montrait « envoyés ». Personne
-- ne pouvait le voir.
--
-- Ce que fait lire_suivi_courriels(), toutes les 5 minutes :
--    1. lit les réponses de Brevo arrivées depuis le passage précédent (la
--       liste des événements de chaque e-mail) :
--         · « delivered »                   → l'envoi passe à « livre » (remis au
--                                              serveur de messagerie du client ;
--                                              ce n'est pas une preuve de lecture) ;
--         · « error », « hardBounces »,
--           « invalid » ou « blocked »       → « echec », avec un code qui dit
--                                              pourquoi (voir plus bas) ;
--         · rien de définitif (« requests »,
--           « softBounces », « deferred »…)  → redemandé plus tard, jusqu'à 72 h ;
--    2. demande à Brevo les événements des e-mails acceptés il y a plus de
--       2 minutes, une requête par e-mail, 50 au plus par passage. Un e-mail
--       encore en suspens est redemandé de moins en moins souvent (au plus une
--       fois par heure).
--
-- Les codes d'échec (affichés en clair dans l'onglet Notifications) :
--    BREVO_EXPEDITEUR      l'adresse d'expédition n'est pas validée chez Brevo :
--                          TOUS les e-mails échouent, c'est la configuration à
--                          reprendre (Brevo > Expéditeurs, domaines) ;
--    BREVO_REFUS           un autre refus de Brevo (compte, contenu, quota…) ;
--    ADRESSE_INEXISTANTE   la boîte du client n'existe pas (rejet définitif) ;
--    ADRESSE_INVALIDE      l'adresse du client est mal écrite ;
--    ADRESSE_BLOQUEE       Brevo bloque cette adresse (rejets passés, plainte,
--                          désinscription).
--
-- Règles :
--    · Seuls les e-mails envoyés APRÈS l'installation de ce fichier sont lus
--      (notification_moteur.suivi_courriels_depuis) : aucun envoi plus ancien ne
--      change.
--    · Le texte de Brevo n'est pas recopié (il peut citer l'adresse du client) :
--      seul le code est gardé.
--    · Seul Brevo est suivi ; un autre fournisseur (Resend) garde « envoye ».
--    · Rien n'est ouvert aux comptes ni aux visiteurs : seule la tâche planifiée
--      appelle la fonction.
--
-- Contenu :
--    1. garde : la chaîne est-elle à jour ?
--    2. les colonnes et l'index
--    3. lire_suivi_courriels
--    4. droits
--    5. la tâche planifiée
--    6. contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regclass('public.notification_envois') is null
     or to_regclass('public.notification_moteur') is null
     or to_regprocedure('public.lire_accuses_push(integer)') is null then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt), jusqu''à supabase-accuses.sql, puis ce fichier.';
  end if;
end;
$garde$;


-- 2. Les colonnes et l'index -------------------------------------------------------
-- suivi_courriels_depuis : posé une fois, à la première installation (la ligne
-- unique du moteur reçoit la valeur par défaut) ; une relance ne le change pas.
alter table public.notification_moteur add column if not exists suivi_courriels_depuis timestamptz not null default now();
-- suivi_requete : n° pg_net de la demande en cours chez Brevo
alter table public.notification_envois add column if not exists suivi_requete bigint;

create index if not exists notification_envois_courriels_suivis_idx
  on public.notification_envois (envoye_le)
  where canal = 'email' and statut = 'envoye' and accuse_le is null;


-- 3. lire_suivi_courriels ------------------------------------------------------------
create or replace function public.lire_suivi_courriels(p_lot integer default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_lot integer := least(greatest(coalesce(p_lot, 50), 1), 200);
  v_depuis timestamptz := (select suivi_courriels_depuis from public.notification_moteur);
  v_cle text := coalesce(public.lire_reglage('email_cle_api'), '');
  e record;
  r record;
  v_json jsonb;
  v_evenements jsonb;
  v_types text[];
  v_raison text;
  v_code text;
  v_requete bigint;
  v_lues integer := 0;
  v_livres integer := 0;
  v_echecs integer := 0;
  v_attente integer := 0;
  v_clos integer := 0;
  v_demandes integer := 0;
begin
  -- 1. Les réponses de Brevo arrivées depuis le passage précédent
  for e in select id, suivi_requete, envoye_le, maj_le from public.notification_envois
            where canal = 'email' and fournisseur = 'brevo' and suivi_requete is not null and accuse_le is null
            for update skip locked loop
    select status_code, content, error_msg into r from net._http_response where id = e.suivi_requete;
    if not found then
      -- Pas encore de réponse ; au-delà de 10 minutes, la demande est refaite
      if e.maj_le < now() - interval '10 minutes' then
        update public.notification_envois set suivi_requete = null, maj_le = now() where id = e.id;
      end if;
      continue;
    end if;
    v_lues := v_lues + 1;
    begin
      v_json := r.content::jsonb;
    exception when others then
      v_json := null;
    end;
    if r.error_msg is not null or r.status_code is null or r.status_code not between 200 and 299
       or jsonb_typeof(v_json) is distinct from 'object' then
      -- Réseau, Brevo indisponible, clé refusée, réponse illisible : redemandé plus tard
      update public.notification_envois set suivi_requete = null, maj_le = now() where id = e.id;
      continue;
    end if;

    -- Brevo répond {} quand il n'a encore rien à dire sur cet e-mail
    v_evenements := case when jsonb_typeof(v_json -> 'events') = 'array' then v_json -> 'events' else '[]'::jsonb end;
    select coalesce(array_agg(lower(ev ->> 'event')), array[]::text[]) into v_types
      from jsonb_array_elements(v_evenements) ev;

    if 'delivered' = any (v_types) then
      update public.notification_envois
         set statut = 'livre', livre_le = now(), accuse_le = now(), suivi_requete = null, maj_le = now()
       where id = e.id;
      v_livres := v_livres + 1;
    elsif v_types && array['error', 'hardbounces', 'hardbounce', 'invalid', 'blocked'] then
      -- Le premier refus définitif dit pourquoi ; son texte n'est pas gardé
      select lower(ev ->> 'event'), coalesce(ev ->> 'reason', '') into v_code, v_raison
        from jsonb_array_elements(v_evenements) ev
       where lower(ev ->> 'event') in ('error', 'hardbounces', 'hardbounce', 'invalid', 'blocked')
       limit 1;
      v_code := case
                  when v_code = 'error' and v_raison ilike '%sender%' then 'BREVO_EXPEDITEUR'
                  when v_code = 'error' then 'BREVO_REFUS'
                  when v_code in ('hardbounces', 'hardbounce') then 'ADRESSE_INEXISTANTE'
                  when v_code = 'invalid' then 'ADRESSE_INVALIDE'
                  else 'ADRESSE_BLOQUEE'
                end;
      update public.notification_envois
         set statut = 'echec', code_erreur = v_code,
             erreur = case v_code
                        when 'BREVO_EXPEDITEUR' then 'Refusé par Brevo : adresse d''expédition non validée'
                        when 'BREVO_REFUS' then 'Refusé par Brevo'
                        when 'ADRESSE_INEXISTANTE' then 'Adresse e-mail inexistante'
                        when 'ADRESSE_INVALIDE' then 'Adresse e-mail invalide'
                        else 'Adresse e-mail bloquée par Brevo'
                      end,
             accuse_le = now(), suivi_requete = null, maj_le = now()
       where id = e.id;
      v_echecs := v_echecs + 1;
    else
      -- Rien de définitif encore (accepté, retardé, rejet temporaire) : redemandé plus
      -- tard ; clos sans changer le statut après 72 heures
      update public.notification_envois
         set suivi_requete = null,
             accuse_le = case when e.envoye_le < now() - interval '72 hours' then now() end,
             maj_le = now()
       where id = e.id;
      if e.envoye_le < now() - interval '72 hours' then
        v_clos := v_clos + 1;
      else
        v_attente := v_attente + 1;
      end if;
    end if;
  end loop;

  -- 2. Les e-mails trop anciens pour être encore suivis (tâche arrêtée longtemps…) :
  --    clos sans changer leur statut
  with clos as (
    update public.notification_envois
       set accuse_le = now(), maj_le = now()
     where canal = 'email' and fournisseur = 'brevo' and statut = 'envoye'
       and accuse_le is null and suivi_requete is null
       and envoye_le >= v_depuis and envoye_le < now() - interval '72 hours'
    returning 1)
  select v_clos + count(*) into v_clos from clos;

  -- 3. Les nouvelles demandes : une requête par e-mail, accepté il y a plus de
  --    2 minutes ; un e-mail encore en suspens attend d'autant plus qu'il est ancien
  --    (un sixième de son âge, entre 2 minutes et 1 heure).
  if v_cle <> '' then
    for e in select id, message_id from public.notification_envois
              where canal = 'email' and fournisseur = 'brevo' and statut = 'envoye'
                and message_id is not null and message_id <> ''
                and suivi_requete is null and accuse_le is null
                and envoye_le >= greatest(v_depuis, now() - interval '71 hours')
                and envoye_le <= now() - interval '2 minutes'
                and maj_le <= now() - least(interval '1 hour', greatest(interval '2 minutes', (now() - envoye_le) / 6))
              order by envoye_le
              limit v_lot for update skip locked loop
      select net.http_get(
        url := 'https://api.brevo.com/v3/smtp/statistics/events',
        params := jsonb_build_object('messageId', e.message_id, 'days', '7', 'limit', '100'),
        headers := jsonb_build_object('api-key', v_cle, 'Accept', 'application/json')
      ) into v_requete;
      update public.notification_envois set suivi_requete = v_requete, maj_le = now() where id = e.id;
      v_demandes := v_demandes + 1;
    end loop;
  end if;

  return jsonb_build_object('reponses_lues', v_lues, 'livres', v_livres, 'echecs', v_echecs,
                            'en_attente', v_attente, 'clos_sans_suivi', v_clos, 'demandes', v_demandes);
end;
$$;


-- 4. Droits --------------------------------------------------------------------------
revoke execute on function public.lire_suivi_courriels(integer) from public, anon, authenticated;


-- 5. La tâche planifiée ------------------------------------------------------------------
-- Toutes les 5 minutes, décalée de deux minutes sur celle des push (goship-accuses-push)
-- pour ne pas tomber dans la même seconde. Sans pg_cron, rien ne se perd : les e-mails
-- gardent simplement leur statut « envoye ».
do $cron$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('goship-suivi-courriels', '2-59/5 * * * *', 'select public.lire_suivi_courriels()');
  else
    raise notice 'pg_cron absent : le suivi des e-mails ne tournera pas tant qu''il n''est pas activé.';
  end if;
end
$cron$;


-- 6. Contrôle ----------------------------------------------------------------------------
-- colonnes : 2 ; fonction : 1 ; ouverte_aux_visiteurs : false ; tache : 1
-- (0 si pg_cron n'est pas activé : voir la partie 5).
select (select count(*) from information_schema.columns
         where table_schema = 'public'
           and ((table_name = 'notification_moteur' and column_name = 'suivi_courriels_depuis')
             or (table_name = 'notification_envois' and column_name = 'suivi_requete'))) as colonnes,
       (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = 'lire_suivi_courriels') as fonction,
       has_function_privilege('anon', 'public.lire_suivi_courriels(integer)', 'execute')
         or has_function_privilege('authenticated', 'public.lire_suivi_courriels(integer)', 'execute') as ouverte_aux_visiteurs,
       case when to_regclass('cron.job') is null then 0
            else (xpath('/row/n/text()', query_to_xml(
                    'select count(*) as n from cron.job where jobname = ''goship-suivi-courriels''', false, true, '')))[1]::text::integer
       end as tache;
