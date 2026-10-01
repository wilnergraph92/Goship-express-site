-- =============================================================================
-- Goship Express — essai métier de bout en bout, dans UNE transaction ANNULÉE
--
--   psql "$STAGING_DB_URL" -v ON_ERROR_STOP=1 -f outils/production/essai-metier.sql
--
-- Pour la PRÉPRODUCTION (goship-staging), après la chaîne des migrations.
-- Jamais pour la production : outils/production/appliquer-chaine.sh et
-- preproduction.yml le refusent.
--
-- Tout se passe entre « begin » et « rollback » : comptes, colis, événements,
-- facture, paiements, notifications — rien ne reste dans la base, et rien ne part
-- vers un fournisseur (pg_net n'envoie que ce qui a été validé ; ici, rien ne l'est).
-- Le premier échec arrête l'essai (ON_ERROR_STOP) : la connexion se ferme et
-- PostgreSQL annule tout.
--
-- Le parcours :
--   comptes (client, second client, employé, gérant, administrateur) → rôles par
--   changer_role → colis créé par l'employé (prix calculé par la base) → étapes
--   par executer_operation → verrou du statut → poste de scan → facture par le
--   gérant (5 $/lb, sans frais ; frais de service
--   ajoutés une fois, jamais deux — supabase-frais-service.sql) → paiement idempotent, trop-payé refusé, annulation
--   motivée → refus des permissions → espace client (mon_resume, mes_factures,
--   isolation) → suivi public → notifications créées par la base → sante().
-- Chaque vérification réussie s'affiche « OK … » ; un échec lève « ÉCHEC … ».
-- =============================================================================

begin;
set local statement_timeout = '120s';

-- ---- Comptes (adresses d'essai ; annulés avec le reste) -----------------------
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('0e55a100-0000-4000-8000-0000000000c1', 'client.essai@goship.test',  now(), '{"nom_complet":"Client Essai","pays":"HT","ville":"Pétion-Ville"}'),
  ('0e55a100-0000-4000-8000-0000000000c2', 'client2.essai@goship.test', now(), '{"nom_complet":"Second Essai","pays":"HT","ville":"Jacmel"}'),
  ('0e55a100-0000-4000-8000-0000000000e1', 'employe.essai@goship.test', now(), '{"nom_complet":"Employé Essai","pays":"HT"}'),
  ('0e55a100-0000-4000-8000-0000000000f1', 'gerant.essai@goship.test',  now(), '{"nom_complet":"Gérant Essai","pays":"HT"}'),
  ('0e55a100-0000-4000-8000-0000000000a1', 'admin.essai@goship.test',   now(), '{"nom_complet":"Admin Essai","pays":"HT"}');

do $$ begin
  if (select count(*) from public.clients where id::text like '0e55a100-%') <> 5 then
    raise exception 'ÉCHEC : les profils ne sont pas créés à l''inscription (creer_profil_client)';
  end if;
  if exists (select 1 from public.clients where id::text like '0e55a100-%' and role <> 'client') then
    raise exception 'ÉCHEC : un nouveau compte n''est pas « client » par défaut';
  end if;
  raise notice 'OK comptes : profil créé à l''inscription, rôle client par défaut';
end $$;

select public.definir_admin('admin.essai@goship.test');

-- ---- L'administrateur donne les rôles ------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"0e55a100-0000-4000-8000-0000000000a1","role":"authenticated"}', true);
select public.changer_role('employe.essai@goship.test', 'employe');
select public.changer_role('gerant.essai@goship.test', 'gerant');
reset role;
do $$ begin
  if (select role from public.clients where id = '0e55a100-0000-4000-8000-0000000000e1') <> 'employe'
     or (select role from public.clients where id = '0e55a100-0000-4000-8000-0000000000f1') <> 'gerant' then
    raise exception 'ÉCHEC : changer_role';
  end if;
  begin
    update public.clients set role = 'admin' where id = '0e55a100-0000-4000-8000-0000000000c1';
    raise exception 'ÉCHEC : verrou_role a laissé changer un rôle hors de changer_role';
  exception when others then
    if sqlerrm like 'ÉCHEC%' then raise; end if;
  end;
  raise notice 'OK rôles : changer_role seulement, verrou_role actif';
end $$;

-- ---- L'employé : colis, étapes, verrou, scanner -------------------------------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"0e55a100-0000-4000-8000-0000000000e1","role":"authenticated"}', true);
do $$ declare r jsonb; r2 jsonb; begin
  r := public.creer_colis(jsonb_build_object('client_id', '0e55a100-0000-4000-8000-0000000000c1',
         'description', 'Essai de préproduction', 'poids_lb', 4, 'service', 'aerien', 'pays_destination', 'HT',
         'destination', 'Pétion-Ville', 'expediteur', 'Essai', 'prix_usd', 1), 'essai-preproduction-1', false);
  perform set_config('essai.colis', r -> 'colis' ->> 'id', true);
  perform set_config('essai.numero', r -> 'colis' ->> 'numero', true);
  if (r -> 'colis' ->> 'prix_usd')::numeric <> 20 then
    raise exception 'ÉCHEC : prix %, attendu 20 (4 lb × 5 $, le prix envoyé par la page est ignoré)', r -> 'colis' ->> 'prix_usd';
  end if;
  r2 := public.creer_colis(jsonb_build_object('client_id', '0e55a100-0000-4000-8000-0000000000c1',
         'description', 'Essai de préproduction', 'poids_lb', 4, 'service', 'aerien', 'pays_destination', 'HT',
         'destination', 'Pétion-Ville', 'expediteur', 'Essai'), 'essai-preproduction-1', false);
  if not coalesce((r2 ->> 'deja')::boolean, false) or r2 -> 'colis' ->> 'id' <> r -> 'colis' ->> 'id' then
    raise exception 'ÉCHEC : une requête répétée a créé un second colis';
  end if;
  perform public.creer_colis(jsonb_build_object('client_id', '0e55a100-0000-4000-8000-0000000000c2',
         'description', 'Colis de l''autre client', 'poids_lb', 2, 'service', 'aerien', 'pays_destination', 'HT',
         'destination', 'Jacmel', 'expediteur', 'Essai'), 'essai-preproduction-2', false);
  raise notice 'OK colis : prix calculé par la base (20 $), requête répétée sans doublon';
end $$;

do $$ declare c uuid := current_setting('essai.colis')::uuid; begin
  perform public.executer_operation(c, 'COLIS_EMBALLE');
  perform public.executer_operation(c, 'COLIS_EXPEDIE');
  perform public.executer_operation(c, 'COLIS_ARRIVE', 'Port-au-Prince');
  if (select statut from public.colis where id = c) <> 'distribution' then
    raise exception 'ÉCHEC : statut % après trois étapes, attendu distribution', (select statut from public.colis where id = c);
  end if;
  if (select count(*) from public.colis_historique where colis_id = c) < 4 then
    raise exception 'ÉCHEC : historique incomplet';
  end if;
  begin
    perform public.executer_operation(c, 'COLIS_EMBALLE');
    raise exception 'ÉCHEC : transition arrière acceptée (distribution → emballé)';
  exception when others then
    if sqlerrm like 'ÉCHEC%' then raise; end if;
  end;
  raise notice 'OK événements : trois étapes, statut distribution, transition interdite refusée';
end $$;

do $$ declare c uuid := current_setting('essai.colis')::uuid; begin
  if public.scanner_colis(current_setting('essai.numero')) is null then
    raise exception 'ÉCHEC : le poste de scan ne trouve pas le colis par son numéro';
  end if;
  begin
    perform public.enregistrer_paiement(gen_random_uuid(), '{"montant_usd": 1, "moyen": "especes"}'::jsonb);
    raise exception 'ÉCHEC : un employé a pu enregistrer un paiement';
  exception when others then
    if sqlerrm like 'ÉCHEC%' then raise; end if;
  end;
  raise notice 'OK poste de scan, paiement refusé à l''employé';
end $$;
reset role;

-- Le verrou du statut, éprouvé avec le rôle propriétaire (qui passe outre la RLS :
-- seul le déclencheur verrou_statut peut l'arrêter)
do $$ declare c uuid := current_setting('essai.colis')::uuid; m1 text; m2 text; begin
  begin
    -- distribution → disponible est une transition PERMISE : seul verrou_statut
    -- peut refuser qu'elle se fasse sans événement
    update public.colis set statut = 'disponible' where id = c;
    raise exception 'ÉCHEC : le statut a changé par un UPDATE direct (verrou_statut absent ou coupé)';
  exception when others then
    if sqlerrm like 'ÉCHEC%' then raise; end if;
    m1 := sqlerrm;
  end;
  begin
    update public.colis_historique set note = 'réécrite' where colis_id = c;
    raise exception 'ÉCHEC : un événement a été modifié (evenement_immuable absent ou coupé)';
  exception when others then
    if sqlerrm like 'ÉCHEC%' then raise; end if;
    m2 := sqlerrm;
  end;
  raise notice 'OK verrous : le statut (%) et les événements (%) refusent même le propriétaire', m1, m2;
end $$;

-- ---- Le gérant : facture, paiements --------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"0e55a100-0000-4000-8000-0000000000f1","role":"authenticated"}', true);
do $$ declare r jsonb; f uuid; p jsonb; p2 jsonb; begin
  r := public.facturer_colis(current_setting('essai.colis')::uuid);
  f := coalesce(r -> 'facture' ->> 'id', r ->> 'id')::uuid;
  perform set_config('essai.facture', f::text, true);
  if (select montant_usd from public.factures where id = f) <> 20 then
    raise exception 'ÉCHEC : facture de % $, attendu 20 $ (20 $ de transport, sans frais à l''enregistrement)', (select montant_usd from public.factures where id = f);
  end if;
  -- Les frais de service s'ajoutent une fois (fiche de la facture, ou « Encaisser → Oui ») ;
  -- demandés une seconde fois, rien ne change
  perform public.changer_frais_service(f, true);
  perform public.changer_frais_service(f, true);
  if (select montant_usd || '/' || frais_service_usd from public.factures where id = f) <> '30.00/10.00' then
    raise exception 'ÉCHEC : après les frais, % au lieu de 30.00/10.00',
      (select montant_usd || '/' || frais_service_usd from public.factures where id = f);
  end if;
  -- Facturer deux fois le même colis rend la même facture (requête répétée) ;
  -- une seconde facture qui le reprendrait est refusée (INVOICE_ALREADY_EXISTS)
  r := public.facturer_colis(current_setting('essai.colis')::uuid);
  if not coalesce((r ->> 'deja')::boolean, false) or (r -> 'facture' ->> 'id')::uuid <> f then
    raise exception 'ÉCHEC : refacturer le même colis n''a pas rendu la facture existante';
  end if;
  begin
    perform public.creer_facture('0e55a100-0000-4000-8000-0000000000c1', array[current_setting('essai.colis')::uuid]);
    raise exception 'ÉCHEC : une seconde facture a repris un colis déjà facturé';
  exception when others then
    if sqlerrm like 'ÉCHEC%' then raise; end if;
    if sqlerrm <> 'INVOICE_ALREADY_EXISTS' then raise exception 'ÉCHEC : refus inattendu (%)', sqlerrm; end if;
  end;
  p := public.enregistrer_paiement(f, '{"montant_usd": 10, "moyen": "especes"}'::jsonb, 'essai-paiement-1');
  p2 := public.enregistrer_paiement(f, '{"montant_usd": 10, "moyen": "especes"}'::jsonb, 'essai-paiement-1');
  if not coalesce((p2 ->> 'deja')::boolean, false) or (select count(*) from public.paiements where facture_id = f) <> 1 then
    raise exception 'ÉCHEC : le même paiement envoyé deux fois a été compté deux fois';
  end if;
  if (select montant_paye_usd from public.factures where id = f) <> 10 then
    raise exception 'ÉCHEC : payé % $, attendu 10 $', (select montant_paye_usd from public.factures where id = f);
  end if;
  begin
    perform public.enregistrer_paiement(f, '{"montant_usd": 1000, "moyen": "especes"}'::jsonb);
    raise exception 'ÉCHEC : trop-payé accepté';
  exception when others then
    if sqlerrm like 'ÉCHEC%' then raise; end if;
  end;
  perform public.annuler_paiement((p -> 'paiement' ->> 'id')::uuid, 'Essai de préproduction');
  if (select montant_paye_usd from public.factures where id = f) <> 0 then
    raise exception 'ÉCHEC : le paiement annulé compte encore';
  end if;
  perform public.enregistrer_paiement(f, '{"montant_usd": 30, "moyen": "moncash"}'::jsonb, 'essai-paiement-2');
  if (select statut from public.factures where id = f) <> 'payee' then
    raise exception 'ÉCHEC : facture payée en entier mais statut %', (select statut from public.factures where id = f);
  end if;
  raise notice 'OK facturation : 20 $ sans frais, frais ajoutés une fois (30 $), refacturation rendue telle quelle, seconde facture refusée, paiement idempotent, trop-payé refusé, annulation motivée, payée';
end $$;
reset role;

-- ---- Le client : son espace, et seulement le sien -------------------------------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"0e55a100-0000-4000-8000-0000000000c1","role":"authenticated"}', true);
do $$ declare r jsonb; begin
  r := public.mon_resume();
  if coalesce((r -> 'colis' ->> 'en_cours')::int, 0) < 1 then
    raise exception 'ÉCHEC : mon_resume ne compte pas le colis en cours (%)', r -> 'colis';
  end if;
  if (select count(*) from public.colis where client_id = '0e55a100-0000-4000-8000-0000000000c2') <> 0 then
    raise exception 'ÉCHEC : un client voit les colis d''un autre (RLS)';
  end if;
  if (select count(*) from public.colis) <> 1 then
    raise exception 'ÉCHEC : le client voit % colis, attendu 1', (select count(*) from public.colis);
  end if;
  begin
    perform public.vue_generale();
    raise exception 'ÉCHEC : un client a lu la vue générale de l''équipe';
  exception when others then
    if sqlerrm like 'ÉCHEC%' then raise; end if;
  end;
  begin
    perform public.executer_operation(current_setting('essai.colis')::uuid, 'COLIS_LIVRE');
    raise exception 'ÉCHEC : un client a changé le statut de son colis';
  exception when others then
    if sqlerrm like 'ÉCHEC%' then raise; end if;
  end;
  raise notice 'OK espace client : résumé par la base, isolation, vue de l''équipe et opérations refusées';
end $$;
reset role;

-- ---- Le visiteur : suivi public, sans données personnelles ----------------------
set local role anon;
select set_config('request.jwt.claims', '', true);
do $$ declare r jsonb; begin
  r := public.suivre_colis(current_setting('essai.numero'));
  if r is null then raise exception 'ÉCHEC : le suivi public ne trouve pas le colis'; end if;
  if r::text ~* '(Client Essai|goship\.test)' then
    raise exception 'ÉCHEC : le suivi public montre le nom ou l''adresse e-mail du client';
  end if;
  if public.suivre_colis('GSE-0000-ZZ') is not null then
    raise exception 'ÉCHEC : un numéro inexistant donne un résultat';
  end if;
  raise notice 'OK suivi public : étapes sans nom ni adresse ; numéro inconnu → rien';
end $$;
reset role;

-- ---- Notifications (si le moteur est installé) et santé --------------------------
do $$ declare n int; e int; begin
  if to_regclass('public.notification_envois') is null then
    raise notice 'INFO notifications : moteur non installé (supabase-notifications.sql) — non essayé';
  else
    select count(*) into n from public.notifications where client_id = '0e55a100-0000-4000-8000-0000000000c1' and canal = 'app';
    execute 'select count(*) from public.notification_envois e join public.notifications n on n.id = e.notification_id
              where n.client_id = $1' into e using '0e55a100-0000-4000-8000-0000000000c1'::uuid;
    if n < 3 then raise exception 'ÉCHEC : % notification(s) pour le client, attendu au moins 3 (étapes publiques, facture, paiement)', n; end if;
    raise notice 'OK notifications : % créées par la base, % envoi(s) en file (jamais partis : transaction annulée)', n, e;
  end if;
  if to_regproc('public.sante') is null then
    raise notice 'INFO sante() absente (supabase-production.sql)';
  elsif (public.sante() ->> 'status') <> 'ok' then
    raise exception 'ÉCHEC : sante() → %', public.sante();
  else
    raise notice 'OK sante() : %', public.sante();
  end if;
end $$;

rollback;

-- Rien n'est resté
do $$ begin
  if exists (select 1 from auth.users where email like '%.essai@goship.test')
     or exists (select 1 from public.colis where cle_idempotence like 'essai-preproduction-%') then
    raise exception 'ÉCHEC : des données d''essai sont restées après l''annulation';
  end if;
  raise notice 'OK transaction annulée : aucun compte, colis, facture ni envoi d''essai ne reste';
end $$;
