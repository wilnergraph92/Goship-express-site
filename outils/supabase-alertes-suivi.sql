-- =============================================================================
-- Goship Express — les notifications des transporteurs (Phase 5 du suivi universel, 13/11/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce fichier
-- AJOUTE trois règles de notification (ÉTEINTES), leurs textes en quatre langues, un
-- déclencheur et une lecture pour l'équipe. Il ne change aucune donnée existante ni
-- aucune fonction existante, et peut être relancé autant de fois qu'on veut (une règle
-- déjà allumée, un texte déjà corrigé ne sont pas touchés).
--
-- Ordre d'installation : le dernier de la chaîne (outils/migrations.txt), après
-- supabase-mes-suivis.sql.
--
-- Pourquoi : le client suit ses achats annoncés chez leur transporteur (Phase 4). Dossier
-- de la Phase 5 validé par le CEO le 13/11/2026 : il est prévenu des événements qui
-- comptent, et de ceux-là seulement :
--    · carrier_delivered   le transporteur a livré (DELIVERED) — l'achat n'est pas encore
--                          « reçu » : c'est le scan de l'entrepôt qui le dira, par la
--                          notification GoShip qui existe déjà ;
--    · carrier_issue       un incident (EXCEPTION, FAILED_ATTEMPT, RETURNED) ;
--    · carrier_invalid     le transporteur refuse le numéro (INVALID_TRACKING).
-- Rien pour « en route », ni à chaque relecture. Sur le téléphone (push) et dans les
-- messages du compte, jamais par e-mail ni WhatsApp.
--
-- Le moteur de notifications fait le reste, comme pour les colis : une notification par
-- achat et par cas (clé unique), la préférence « colis » du client respectée, un envoi
-- par téléphone, le journal des envois. Rien ne part d'un fournisseur qui n'est pas
-- VERIFIED et en service. Le déclencheur ne fait JAMAIS échouer le moteur de suivi :
-- une erreur va au journal des appels (son code seulement).
--
-- Les trois règles naissent ÉTEINTES (actif = false) : elles s'allument à la publication
-- de l'application (Paramètres > Notifications du tableau de bord, ou
-- modifier_regle_notification), sur décision écrite du CEO.
--
-- Règles inchangées : aucun lien d'écriture avec les colis, leur historique ou leur
-- statut ; le travailleur d'envoi n'est pas touché ; aucune permission nouvelle ; rien
-- d'ouvert aux visiteurs.
--
-- Contenu :
--    1. garde : la chaîne est-elle à jour ?
--    2. les trois règles (éteintes)
--    3. leurs textes, quatre langues
--    4. le déclencheur
--    5. la lecture de l'équipe : etat_alertes_suivi()
--    6. droits
--    7. contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regprocedure('public.mes_suivis_externes()') is null
     or to_regprocedure('public.creer_notification(text, uuid, text, uuid, uuid, uuid, bigint, jsonb, text[])') is null
     or to_regclass('public.notification_modeles') is null then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt), jusqu''à supabase-mes-suivis.sql, puis ce fichier.';
  end if;
end;
$garde$;


-- 2. Les règles -------------------------------------------------------------------
-- Une source de plus pour le moteur : le suivi externe. La contrainte est reposée avec
-- les sources d'avant, plus celle-ci.
alter table public.notification_regles drop constraint if exists notification_regles_source_check;
alter table public.notification_regles add constraint notification_regles_source_check
  check (source in ('colis', 'facturation', 'planifie', 'suivi_externe'));

-- Éteintes à l'installation ; une règle déjà là (déjà allumée, canaux changés) n'est pas touchée
insert into public.notification_regles (type, source, evenement, categorie, priorite, canaux, sensible, actif, libelle) values
  ('carrier_delivered', 'suivi_externe', 'SUIVI_LIVRE',    'colis', 'normale', '{push}', false, false, 'Achat livré par le transporteur'),
  ('carrier_issue',     'suivi_externe', 'SUIVI_INCIDENT', 'colis', 'normale', '{push}', false, false, 'Incident chez le transporteur'),
  ('carrier_invalid',   'suivi_externe', 'SUIVI_REFUSE',   'colis', 'normale', '{push}', false, false, 'Numéro refusé par le transporteur')
on conflict (type) do nothing;


-- 3. Les textes -------------------------------------------------------------------
-- {{numero}} porte le nom de l'achat (« SHEIN — Robe »), posé par le déclencheur : c'est
-- la variable que le moteur sait déjà remplir. Un texte corrigé depuis n'est pas touché.
insert into public.notification_modeles (type, langue, titre, message, titre_defaut, message_defaut) values
  ('carrier_delivered', 'fr', 'Livré par le transporteur',
   'Votre achat {{numero}} a été livré par le transporteur. Nous vous prévenons dès sa réception à notre entrepôt de Miami.',
   'Livré par le transporteur',
   'Votre achat {{numero}} a été livré par le transporteur. Nous vous prévenons dès sa réception à notre entrepôt de Miami.'),
  ('carrier_delivered', 'en', 'Delivered by the carrier',
   'Your purchase {{numero}} was delivered by the carrier. We''ll let you know as soon as it is received at our Miami warehouse.',
   'Delivered by the carrier',
   'Your purchase {{numero}} was delivered by the carrier. We''ll let you know as soon as it is received at our Miami warehouse.'),
  ('carrier_delivered', 'es', 'Entregado por la transportista',
   'Su compra {{numero}} fue entregada por la transportista. Le avisaremos en cuanto llegue a nuestro almacén de Miami.',
   'Entregado por la transportista',
   'Su compra {{numero}} fue entregada por la transportista. Le avisaremos en cuanto llegue a nuestro almacén de Miami.'),
  ('carrier_delivered', 'ht', 'Transpòtè a livre l',
   'Transpòtè a livre acha ou {{numero}}. N ap fè w konnen depi depo nou an Miami resevwa l.',
   'Transpòtè a livre l',
   'Transpòtè a livre acha ou {{numero}}. N ap fè w konnen depi depo nou an Miami resevwa l.'),
  ('carrier_issue', 'fr', 'Incident chez le transporteur',
   'Le transporteur signale un incident pour votre achat {{numero}}. Ouvrez l''application pour voir le détail.',
   'Incident chez le transporteur',
   'Le transporteur signale un incident pour votre achat {{numero}}. Ouvrez l''application pour voir le détail.'),
  ('carrier_issue', 'en', 'Carrier issue',
   'The carrier reports an issue with your purchase {{numero}}. Open the app to see the details.',
   'Carrier issue',
   'The carrier reports an issue with your purchase {{numero}}. Open the app to see the details.'),
  ('carrier_issue', 'es', 'Incidencia de la transportista',
   'La transportista informa una incidencia con su compra {{numero}}. Abra la aplicación para ver el detalle.',
   'Incidencia de la transportista',
   'La transportista informa una incidencia con su compra {{numero}}. Abra la aplicación para ver el detalle.'),
  ('carrier_issue', 'ht', 'Pwoblèm kay transpòtè a',
   'Transpòtè a siyale yon pwoblèm sou acha ou {{numero}}. Louvri aplikasyon an pou w wè detay la.',
   'Pwoblèm kay transpòtè a',
   'Transpòtè a siyale yon pwoblèm sou acha ou {{numero}}. Louvri aplikasyon an pou w wè detay la.'),
  ('carrier_invalid', 'fr', 'Numéro de suivi refusé',
   'Le transporteur ne reconnaît pas le numéro de suivi de votre achat {{numero}}. Vérifiez-le.',
   'Numéro de suivi refusé',
   'Le transporteur ne reconnaît pas le numéro de suivi de votre achat {{numero}}. Vérifiez-le.'),
  ('carrier_invalid', 'en', 'Tracking number not recognized',
   'The carrier doesn''t recognize the tracking number of your purchase {{numero}}. Please check it.',
   'Tracking number not recognized',
   'The carrier doesn''t recognize the tracking number of your purchase {{numero}}. Please check it.'),
  ('carrier_invalid', 'es', 'Número de seguimiento no reconocido',
   'La transportista no reconoce el número de seguimiento de su compra {{numero}}. Verifíquelo.',
   'Número de seguimiento no reconocido',
   'La transportista no reconoce el número de seguimiento de su compra {{numero}}. Verifíquelo.'),
  ('carrier_invalid', 'ht', 'Nimewo swivi a pa rekonèt',
   'Transpòtè a pa rekonèt nimewo swivi acha ou {{numero}}. Verifye l.',
   'Nimewo swivi a pa rekonèt',
   'Transpòtè a pa rekonèt nimewo swivi acha ou {{numero}}. Verifye l.')
on conflict (type, langue) do nothing;


-- 4. Le déclencheur ---------------------------------------------------------------
-- Après qu'un suivi a changé de statut ou de code de résultat (moteur des Phases 2 et 3).
-- Pour chaque pré-alerte EN ATTENTE reliée à ce suivi, une notification par client, par
-- achat et par cas : clé « suivi:<pré-alerte>:<type> ». Le même événement relu, ou un
-- incident suivi d'un autre incident, ne notifie donc qu'une fois. Une règle éteinte : rien
-- (creer_notification le décide). Un fournisseur pas VERIFIED et en service : rien.
create or replace function public.notifier_suivi_externe()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_type text;
  p record;
  v_achat text;
begin
  v_type := case
    when new.statut = 'DELIVERED' and old.statut is distinct from 'DELIVERED' then 'carrier_delivered'
    when new.statut in ('EXCEPTION', 'FAILED_ATTEMPT', 'RETURNED')
         and old.statut is distinct from new.statut then 'carrier_issue'
    when new.code_resultat = 'INVALID_TRACKING'
         and old.code_resultat is distinct from 'INVALID_TRACKING' then 'carrier_invalid'
  end;
  if v_type is null
     or not exists (select 1 from public.fournisseurs_suivi f
                     where f.code = new.fournisseur and f.actif and f.conformite = 'VERIFIED') then
    return null;
  end if;
  begin
    for p in select pa.id, pa.client_id, pa.magasin, pa.description
               from public.prealertes pa
              where pa.suivi_externe_id = new.id and pa.statut = 'attente' loop
      -- Le nom de l'achat, tel que le client l'a saisi, sans accolades (aucune variable ne
      -- peut s'y glisser) et court
      v_achat := left(regexp_replace(
                   concat_ws(' — ', nullif(btrim(p.magasin), ''), nullif(btrim(p.description), '')),
                   '[{}]', '', 'g'), 80);
      perform public.creer_notification(
        v_type, p.client_id, 'suivi:' || p.id || ':' || v_type, null, null, null, null,
        -- Pas de « statut » ici : les messages du compte (messages_recents) prendraient le statut
        -- brut du transporteur comme libellé au lieu du type de la notification
        jsonb_build_object('numero', v_achat, 'prealerte_id', p.id), null);
    end loop;
  exception when others then
    begin
      insert into public.suivis_externes_journal (suivi_id, operation, resultat, code_erreur)
      values (new.id, 'notification', 'erreur', left('SQLSTATE_' || sqlstate, 60));
    exception when others then
      null;
    end;
  end;
  return null;
end;
$$;

drop trigger if exists notifier_suivi_externe on public.suivis_externes;
create trigger notifier_suivi_externe
  after update of statut, code_resultat on public.suivis_externes
  for each row execute function public.notifier_suivi_externe();


-- 5. La lecture de l'équipe --------------------------------------------------------------
-- Les trois règles (allumées ou non, leurs canaux) et ce qu'elles ont produit : de quoi
-- vérifier la mise en service sans ouvrir une table. Aucune donnée client.
create or replace function public.etat_alertes_suivi()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('tracking.view');
  return jsonb_build_object(
    'regles', (select coalesce(jsonb_agg(jsonb_build_object('type', r.type, 'actif', r.actif, 'canaux', r.canaux)
                                         order by r.type), '[]'::jsonb)
                 from public.notification_regles r where r.source = 'suivi_externe'),
    'notifications', (select coalesce(jsonb_object_agg(x.type, x.n), '{}'::jsonb)
                        from (select n.type, count(*) as n from public.notifications n
                               where n.type in ('carrier_delivered', 'carrier_issue', 'carrier_invalid')
                               group by n.type) x),
    'erreurs_24h', (select count(*) from public.suivis_externes_journal
                     where operation = 'notification' and resultat <> 'ok'
                       and cree_le > now() - interval '24 hours'));
end;
$$;


-- 6. Droits --------------------------------------------------------------------------
revoke execute on function public.notifier_suivi_externe() from public, anon, authenticated;
revoke execute on function public.etat_alertes_suivi() from public, anon;
grant execute on function public.etat_alertes_suivi() to authenticated;


-- 7. Contrôle ------------------------------------------------------------------------
-- regles : 3 ; allumees : 0 (à l'installation) ; textes : 12 ; declencheur : 1 ;
-- ouverte_aux_visiteurs : false
select (select count(*) from public.notification_regles where source = 'suivi_externe') as regles,
       (select count(*) from public.notification_regles where source = 'suivi_externe' and actif) as allumees,
       (select count(*) from public.notification_modeles
         where type in ('carrier_delivered', 'carrier_issue', 'carrier_invalid')) as textes,
       (select count(*) from pg_trigger where tgname = 'notifier_suivi_externe' and not tgisinternal) as declencheur,
       has_function_privilege('anon', 'public.etat_alertes_suivi()', 'execute') as ouverte_aux_visiteurs;
