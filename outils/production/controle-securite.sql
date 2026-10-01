-- =============================================================================
-- Goship Express — contrôle de sécurité de la base (Phase 12)
--
-- LECTURE SEULE. Ne modifie rien, ne crée rien. À lancer dans Supabase >
-- SQL Editor (en production comme en préproduction), avant chaque mise en
-- production et après chaque migration. Une seule requête : le SQL Editor
-- n'affiche que le résultat de la dernière.
--
-- Chaque ligne : controle | verdict | objet | detail
--   ALERTE  à corriger avant de mettre en production (voir docs/production/secrets.md
--           et docs/production/database.md)
--   INFO    à relire : normal si c'est voulu
--   OK      rien à signaler pour ce contrôle
--
-- Les adresses e-mail des comptes de l'équipe s'affichent (section 8) : ce
-- résultat reste dans le SQL Editor, ne le copiez pas dans un ticket public.
--
-- Le même contrôle tourne sur la base d'essai (outils/essais-services/
-- essai-production.py) : les attentes y sont écrites noir sur blanc.
-- =============================================================================

with
tables as (
  select c.oid, c.relname, c.relrowsecurity,
         (select count(*) from pg_policies p where p.schemaname = 'public' and p.tablename = c.relname) as politiques
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'p')
),
fonctions as (
  select p.oid, p.proname, p.prosecdef, pg_get_function_identity_arguments(p.oid) as args,
         exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%') as search_path_fixe,
         has_function_privilege('anon', p.oid, 'execute') as anon,
         -- Une fonction de déclencheur (trigger, event_trigger) ne s'appelle pas :
         -- PostgreSQL refuse (« trigger functions can only be called as triggers »),
         -- par l'API comme en SQL. Ex. rls_auto_enable(), posée par Supabase.
         p.prorettype in ('trigger'::regtype, 'event_trigger'::regtype) as declencheur
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
),
-- Les seules fonctions privilégiées qu'un visiteur sans compte peut appeler :
-- le suivi public d'un colis et la santé du service. Toute autre est une fuite.
ouvertes_attendues(nom) as (values ('suivre_colis'), ('sante')),
-- Les verrous des règles métier : sans eux, une page pourrait écrire ce que seule
-- la base doit décider (statut, rôle, montants payés, historique).
verrous_attendus(nom, role) as (values
  ('verrou_statut', 'le statut d''un colis ne change que par un événement'),
  ('evenement_immuable', 'l''historique d''un colis ne se réécrit pas'),
  ('verrou_role', 'le rôle ne change que par changer_role'),
  ('garde_facture', 'payé, statut et moyen d''une facture suivent les paiements')),
-- Une migration de la chaîne officielle = un objet qu'elle seule installe
migrations(ordre, fichier, present) as (values
  (1,  'supabase.sql',                 to_regprocedure('public.permissions_du_role(text)') is not null),
  (2,  'supabase-facturation.sql',     exists (select 1 from information_schema.columns
                                               where table_schema = 'public' and table_name = 'factures'
                                                 and column_name = 'frais_service_usd')),
  (3,  'supabase-services.sql',        exists (select 1 from pg_proc where proname = 'creer_colis')),
  (4,  'supabase-evenements.sql',      exists (select 1 from pg_proc where proname = 'executer_operation')),
  (5,  'supabase-scanner.sql',         exists (select 1 from pg_proc where proname = 'scanner_colis')),
  (6,  'supabase-finances.sql',        to_regclass('public.paiements') is not null),
  (7,  'supabase-tableau-de-bord.sql', exists (select 1 from pg_proc where proname = 'vue_generale')),
  (8,  'supabase-analytics.sql',       exists (select 1 from pg_proc where proname = 'analytics_synthese')),
  (9,  'supabase-mobile.sql',          exists (select 1 from pg_proc where proname = 'creer_prealerte')),
  (10, 'supabase-notifications.sql',   to_regclass('public.notification_envois') is not null),
  (11, 'supabase-production.sql',      exists (select 1 from pg_proc where proname = 'sante')),
  (12, 'supabase-rapports.sql',        to_regclass('public.rapports') is not null),
  (13, 'supabase-compte.sql',          exists (select 1 from pg_proc where proname = 'supprimer_mon_compte')),
  (14, 'supabase-regroupement.sql',    exists (select 1 from pg_proc where proname = 'sortir_du_regroupement')),
  (15, 'supabase-connexion.sql',       exists (select 1 from pg_proc where proname = 'nom_depuis_metadonnees')),
  (16, 'supabase-profil-complet.sql',  exists (select 1 from pg_proc where proname = 'profil_complet')),
  (17, 'supabase-frais-service.sql',   exists (select 1 from pg_proc where proname = 'encaisser_facture'))),
comptes as (
  select u.id, lower(coalesce(u.email, '')) as email,
         to_jsonb(u) ->> 'last_sign_in_at' as derniere_connexion,
         c.role
    from auth.users u left join public.clients c on c.id = u.id
),
lignes(ordre, controle, verdict, objet, detail) as (
  -- 1. Chaque table du schéma public a la RLS activée (refus par défaut)
  select 1, 'RLS activée', 'ALERTE', relname, 'table sans RLS : lisible et modifiable selon les seuls droits SQL'
    from tables where not relrowsecurity
  union all
  select 1, 'RLS activée', 'OK', count(*)::text || ' tables', 'toutes les tables du schéma public ont la RLS'
    from tables having bool_and(relrowsecurity)
  union all
  -- 2. Tables sans aucune politique : personne n'y accède en direct (voulu pour les
  -- tables internes lues par des fonctions)
  select 2, 'Tables sans politique', 'INFO', relname, 'aucun accès direct : seulement par les fonctions de la base'
    from tables where relrowsecurity and politiques = 0
  union all
  -- 3. Politiques ouvertes aux visiteurs sans compte, ou toujours vraies en écriture
  select 3, 'Politiques', 'ALERTE', tablename || ' · ' || policyname,
         'politique pour ' || roles::text || ' (' || cmd || ')'
    from pg_policies where schemaname = 'public' and (roles::text like '%anon%' or roles::text like '%public%')
  union all
  select 3, 'Politiques', 'ALERTE', tablename || ' · ' || policyname,
         cmd || ' toujours autorisé (using/with check = true)'
    from pg_policies
   where schemaname = 'public' and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
     and (coalesce(qual, 'true') = 'true' and coalesce(with_check, 'true') = 'true')
  union all
  select 3, 'Politiques', 'OK', (select count(*) from pg_policies where schemaname = 'public')::text || ' politiques',
         'aucune pour les visiteurs, aucune écriture sans condition'
   where not exists (select 1 from pg_policies where schemaname = 'public'
                      and (roles::text like '%anon%' or roles::text like '%public%'
                           or (cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
                               and coalesce(qual, 'true') = 'true' and coalesce(with_check, 'true') = 'true')))
  union all
  -- 4. Une vue s'exécute avec les droits de son propriétaire, sauf security_invoker :
  -- sans lui, elle contourne la RLS des tables qu'elle lit
  select 4, 'Vues', case when coalesce(c.reloptions::text, '') like '%security_invoker=true%'
                              or not has_table_privilege('authenticated', c.oid, 'select')
                         then 'OK' else 'ALERTE' end,
         c.relname, coalesce(c.reloptions::text, 'sans security_invoker')
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('v', 'm')
  union all
  -- 5. Fonctions privilégiées (security definer) : search_path figé, sinon on peut
  -- leur faire appeler une fonction piégée
  select 5, 'Fonctions privilégiées', 'ALERTE', proname || '(' || args || ')', 'security definer sans search_path figé'
    from fonctions where prosecdef and not search_path_fixe
  union all
  select 5, 'Fonctions privilégiées', 'OK', count(*)::text || ' fonctions', 'toutes ont un search_path figé'
    from fonctions where prosecdef having bool_and(search_path_fixe)
  union all
  -- 6. Ce qu'un visiteur sans compte peut appeler
  select 6, 'Ouvert aux visiteurs', 'ALERTE', proname || '(' || args || ')',
         'fonction privilégiée appelable sans compte (attendues : suivre_colis, sante)'
    from fonctions where prosecdef and anon and not declencheur and proname not in (select nom from ouvertes_attendues)
  union all
  select 6, 'Ouvert aux visiteurs', 'INFO', string_agg(proname || '()', ', ' order by proname),
         'fonctions de déclencheur privilégiées : droit d''exécution sans effet, PostgreSQL refuse de les appeler'
    from fonctions where prosecdef and anon and declencheur having count(*) > 0
  union all
  select 6, 'Ouvert aux visiteurs', 'INFO', string_agg(proname, ', ' order by proname),
         'fonctions privilégiées ouvertes sans compte (attendu)'
    from fonctions where prosecdef and anon and proname in (select nom from ouvertes_attendues)
  union all
  select 6, 'Ouvert aux visiteurs', 'INFO', count(*)::text || ' fonctions',
         'fonctions ordinaires (sans privilège, soumises à la RLS) appelables sans compte : '
         || string_agg(proname, ', ' order by proname)
    from fonctions where not prosecdef and anon having count(*) > 0
  union all
  -- 7. Les verrous des règles métier sont en place et actifs
  select 7, 'Verrous métier', case when t.tgenabled in ('O', 'A') then 'OK' else 'ALERTE' end,
         v.nom, v.role || case when t.tgname is null then ' — ABSENT' when t.tgenabled = 'D' then ' — DÉSACTIVÉ' else '' end
    from verrous_attendus v
    left join pg_trigger t on t.tgname = v.nom and not t.tgisinternal
  union all
  -- 8. Comptes : aucune adresse de démonstration ou d'essai ; l'équipe, nommément
  select 8, 'Comptes de démonstration', 'ALERTE', email, 'compte de démonstration ou d''essai présent : à supprimer'
    from comptes
   where email like '%@goship.demo' or email like '%@goship.test' or email like '%@exemple.com'
      or email like '%@example.com' or email like '%@example.org'
  union all
  select 8, 'Comptes de démonstration', 'OK', 'aucun', 'aucune adresse @goship.demo, @goship.test, @exemple.com ou @example.*'
   where not exists (select 1 from comptes
                      where email like '%@goship.demo' or email like '%@goship.test' or email like '%@exemple.com'
                         or email like '%@example.com' or email like '%@example.org')
  union all
  select 8, 'Comptes de l''équipe', 'INFO', email,
         role || ' · dernière connexion : ' || coalesce(derniere_connexion, 'jamais')
    from comptes where role in ('admin', 'gerant', 'employe')
  union all
  select 8, 'Comptes de l''équipe', case when count(*) filter (where role = 'admin') = 0 then 'ALERTE'
                                          when count(*) filter (where role = 'admin') > 3 then 'INFO' else 'OK' end,
         count(*) filter (where role = 'admin')::text || ' administrateur(s)',
         'employés ' || count(*) filter (where role = 'employe') || ', gérants ' || count(*) filter (where role = 'gerant')
         || ', clients ' || count(*) filter (where coalesce(role, 'client') = 'client')
    from comptes
  union all
  -- 9. Stockage : un espace public sert ses fichiers à qui connaît l'adresse
  -- « site » est public exprès : le logo des e-mails (supabase.sql, partie 8), que
  -- seuls les comptes settings.manage déposent. Tout autre espace public est une alerte.
  select 9, 'Stockage', case when not b.public then 'OK' when b.id = 'site' then 'INFO' else 'ALERTE' end, b.id,
         case when not b.public then 'espace privé (adresses signées)'
              when b.id = 'site' then 'espace public du logo des e-mails (voulu) : rien d''autre ne doit y être déposé'
              else 'espace PUBLIC : factures ou documents personnels n''y ont pas leur place' end
    from storage.buckets b
  union all
  select 9, 'Stockage', 'INFO', 'site : ' || count(*)::text || ' fichier(s)',
         'fichiers servis publiquement : ' || string_agg(name, ', ' order by name)
    from storage.objects where bucket_id = 'site' having count(*) > 0
  union all
  select 9, 'Stockage', 'INFO', 'aucun espace', 'le projet n''utilise pas Supabase Storage'
   where not exists (select 1 from storage.buckets)
  union all
  -- 10. Extensions dont dépend le service
  select 10, 'Extensions', case when exists (select 1 from pg_extension where extname = e.nom) then 'OK' else 'ALERTE' end,
         e.nom, e.role || case when exists (select 1 from pg_extension where extname = e.nom) then '' else ' — ABSENTE' end
    from (values ('pg_cron', 'le travailleur des notifications et les rappels quotidiens'),
                 ('pg_net', 'les appels aux fournisseurs (e-mail, WhatsApp, Expo)')) e(nom, role)
  union all
  -- 11. Temps réel : la RLS s'applique aussi aux changements diffusés
  select 11, 'Temps réel', 'INFO', string_agg(tablename, ', ' order by tablename),
         'tables diffusées en temps réel (chacune sous RLS)'
    from pg_publication_tables where pubname = 'supabase_realtime' having count(*) > 0
  union all
  -- 12. La chaîne de migrations : chaque fichier a laissé son empreinte
  select 12, 'Migrations', case when present then 'OK' else 'ALERTE' end, lpad(ordre::text, 2, '0') || ' ' || fichier,
         case when present then 'installée' else 'ABSENTE : exécutez ce fichier, puis tous ceux qui le suivent' end
    from migrations
  union all
  -- 13. Les réglages et clés du coffre-fort (noms seulement, jamais les valeurs)
  select 13, 'Coffre-fort (noms)', 'INFO', string_agg(name, ', ' order by name),
         'réglages et clés rangés dans Vault (valeurs non affichées)'
    from vault.secrets having count(*) > 0
)
select controle, verdict, objet, detail
  from lignes
 order by ordre, case verdict when 'ALERTE' then 0 when 'INFO' then 1 else 2 end, objet;
