-- =============================================================================
-- Goship Express — la santé du service, pour la surveillance (Phase 12)
--
-- À exécuter APRÈS outils/supabase-notifications.sql (dernier de la chaîne,
-- voir README, « Les règles métier »). Supabase > SQL Editor > coller tout le
-- fichier (« Copy raw file » sur GitHub) > Run. Rejouable sans risque : il
-- n'ajoute qu'une fonction de lecture, ne touche à aucune donnée, n'ouvre
-- aucune table.
--
-- Pourquoi : la surveillance automatique (.github/workflows/surveillance.yml)
-- n'a que la clé publique du site. Elle doit pouvoir demander « la base
-- répond-elle, et la file des notifications avance-t-elle ? » sans rien voir
-- d'autre. sante() répond exactement à ces deux questions, et à rien de plus :
-- ni nombre de clients, ni message d'erreur, ni nom de table.
--
--   select public.sante();
--   → {"status": "ok", "base": "ok", "notifications": "ok", "pret": true, "heure": "…"}
--
--   status        « ok » dès que la base répond (vivacité : le service est là)
--   notifications « ok »          la file avance
--                 « en_retard »   un envoi attend son tour depuis plus de 15 minutes :
--                                 le travailleur (pg_cron) ne passe plus
--                 « inactives »   le moteur des notifications n'est pas installé
--   pret          le service peut servir correctement (disponibilité) : faux si la
--                 file est en retard. La surveillance alerte dans ce cas.
-- =============================================================================

create or replace function public.sante()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_notifications text := 'inactives';
begin
  -- Le moteur des notifications (Phase 11) : présent si sa table existe
  if to_regclass('public.notification_envois') is not null then
    -- Un envoi « attente » dont l'heure est passée depuis 15 minutes : le travailleur,
    -- qui passe chaque minute, ne tourne plus. Les envois « annule » (canal non
    -- configuré, préférence) ne comptent pas : ils ne partiront jamais, c'est voulu.
    execute $q$select case when exists (
                 select 1 from public.notification_envois
                  where statut = 'attente'
                    and prochain_essai_le < now() - interval '15 minutes')
               then 'en_retard' else 'ok' end$q$
       into v_notifications;
  end if;
  return jsonb_build_object(
    'status', 'ok',
    'base', 'ok',
    'notifications', v_notifications,
    'pret', v_notifications <> 'en_retard',
    'heure', now());
end;
$$;

-- Ouverte à tous, y compris sans compte : elle ne dit rien d'autre que « ça tourne ».
revoke execute on function public.sante() from public;
grant execute on function public.sante() to anon, authenticated;


-- Contrôle ----------------------------------------------------------------------
-- Le résultat attendu, en une ligne :
--   status ok | pret true (ou false si la file est en retard : voir docs/production/monitoring.md)
select public.sante() ->> 'status' as status,
       (public.sante() ->> 'pret')::boolean as pret,
       public.sante() ->> 'notifications' as notifications;
