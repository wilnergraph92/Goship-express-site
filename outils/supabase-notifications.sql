-- =============================================================================
-- Goship Express — les notifications : événement → règle → notification →
-- envois → fournisseur → statut (Phase 11, 26/09/2026)
--
-- À exécuter APRÈS supabase-mobile.sql (voir README, « Les règles métier ») :
-- Supabase > SQL Editor > New query > coller tout ce fichier > Run. Rejouable :
-- rien n'est supprimé, les règles déjà réglées par l'équipe sont gardées.
--
-- Ce que fait ce fichier, sans créer de deuxième système :
--
--   1. Un fait métier est déjà écrit par la base : une étape dans
--      colis_historique (le moteur d'événements, Phase 3) ou une ligne dans
--      evenements_facturation (la file de la facturation, Phase 5, que rien ne
--      lisait encore). Un déclencheur sur chacune applique les RÈGLES
--      (notification_regles) et crée, dans la MÊME transaction :
--        · la notification (table notifications, canal « app ») — ce que le
--          client lit dans son espace, sur le site comme dans l'application ;
--        · un ENVOI par canal extérieur (notification_envois) : téléphone,
--          e-mail, WhatsApp — ou la raison de ne pas envoyer (canal non
--          configuré, préférence du client, pas d'adresse).
--      Si l'opération métier est annulée, rien de tout cela n'existe ; si
--      l'envoi échoue, l'opération métier n'en sait rien.
--   2. Un travailleur (pg_cron, chaque minute) prend les envois dus, appelle le
--      fournisseur par pg_net (sans attendre), puis lit sa réponse au passage
--      suivant : envoyé, échec définitif (adresse invalide…), ou nouvel essai
--      plus tard (30 s, 2 min, 10 min ; trois essais au plus).
--   3. Le client lit ses notifications, les marque lues, règle ses canaux ;
--      l'équipe voit les envois, les échecs et les règles ; l'administrateur
--      active ou coupe une règle et envoie un essai à son propre compte.
--
-- Aucune page n'envoie plus rien elle-même : l'e-mail et le WhatsApp que le
-- tableau de bord envoyait à l'enregistrement d'un colis partent désormais
-- d'ici, comme la notification du téléphone que la base envoyait déjà.
--
-- Les clés des fournisseurs restent dans le coffre-fort (définir_reglage,
-- supabase.sql partie 7) ; aucune fonction de ce fichier ne les renvoie.
-- =============================================================================

create extension if not exists pg_net with schema extensions;


-- 1. Le moteur : date de mise en service et réglages ----------------------------
-- Une seule ligne. actives_depuis empêche les rappels de remonter le temps : une
-- facture échue avant la mise en service ne déclenche aucun rappel.

create table if not exists public.notification_moteur (
  id             boolean primary key default true check (id),
  actives_depuis timestamptz not null default now(),
  tentatives_max integer not null default 3 check (tentatives_max between 1 and 10),
  lot            integer not null default 50 check (lot between 1 and 500)
);
insert into public.notification_moteur (id) values (true) on conflict (id) do nothing;

alter table public.notification_moteur enable row level security;
revoke all on public.notification_moteur from anon, authenticated;


-- 2. La notification : la table notifications, élargie ---------------------------
-- Jusqu'ici, une ligne = un envoi (e-mail, WhatsApp, téléphone). Ces lignes
-- restent (l'historique ne se réécrit pas). Désormais, une ligne de canal « app »
-- est la notification elle-même : ce que le client lit, une seule fois par
-- événement, quels que soient les canaux par lesquels elle est partie.

alter table public.notifications drop constraint if exists notifications_canal_check;
alter table public.notifications add constraint notifications_canal_check
  check (canal in ('email', 'whatsapp', 'push', 'app'));

alter table public.notifications add column if not exists type          text;
alter table public.notifications add column if not exists categorie     text;
alter table public.notifications add column if not exists priorite      text not null default 'normale';
alter table public.notifications add column if not exists cle           text;
alter table public.notifications add column if not exists historique_id bigint;
alter table public.notifications add column if not exists facture_id    uuid;
alter table public.notifications add column if not exists paiement_id   uuid;
alter table public.notifications add column if not exists donnees       jsonb not null default '{}'::jsonb;
alter table public.notifications add column if not exists lu_le         timestamptz;

-- Idempotence : une clé par (événement, type, client). Rejouer un événement,
-- deux travailleurs en même temps : une seule notification.
create unique index if not exists notifications_cle_idx on public.notifications (cle) where cle is not null;
create index if not exists notifications_app_idx
  on public.notifications (client_id, envoye_le desc) where canal = 'app';
create index if not exists notifications_non_lues_idx
  on public.notifications (client_id) where canal = 'app' and lu_le is null;

-- Le client lit ses propres notifications (l'équipe les lit déjà : shipments.view).
-- Il ne les modifie pas en direct : « lu » passe par marquer_notifications_lues.
drop policy if exists notifications_client on public.notifications;
create policy notifications_client on public.notifications
  for select to authenticated
  using (canal = 'app' and client_id = (select auth.uid()));


-- 3. Les règles ----------------------------------------------------------------
-- Une règle par type de notification : l'événement qui la déclenche, les canaux
-- extérieurs, la priorité. La notification dans l'espace client (« app ») part
-- toujours quand la règle est active. Les identifiants de type sont stables et
-- en anglais ; les textes, traduits, sont dans notification_textes.
--   sensible : le téléphone n'affiche qu'un texte neutre sur l'écran verrouillé
--              (« Une mise à jour concernant votre compte ») ; le détail est
--              dans l'application.

create table if not exists public.notification_regles (
  type       text primary key,
  source     text not null check (source in ('colis', 'facturation', 'planifie')),
  evenement  text not null,
  categorie  text not null check (categorie in ('colis', 'factures', 'paiements', 'compte')),
  priorite   text not null default 'normale' check (priorite in ('normale', 'haute')),
  canaux     text[] not null default '{}',
  sensible   boolean not null default false,
  actif      boolean not null default true,
  libelle    text not null default '',
  maj_le     timestamptz not null default now(),
  maj_par    uuid
);

alter table public.notification_regles drop constraint if exists notification_regles_canaux_check;
alter table public.notification_regles add constraint notification_regles_canaux_check
  check (canaux <@ array['push', 'email', 'whatsapp', 'sms']::text[]);

-- Les règles de départ. Une règle déjà là n'est pas touchée : l'administrateur a
-- pu la couper ou changer ses canaux. Le téléphone suit toutes les étapes que
-- la base envoyait déjà ; l'e-mail et WhatsApp, celles que le tableau de bord
-- envoyait (reçu, disponible) et les étapes importantes (action requise,
-- facture, paiement, retard). Aucun SMS : aucun fournisseur n'est configuré.
insert into public.notification_regles (type, source, evenement, categorie, priorite, canaux, sensible, libelle) values
  ('shipment_received',    'colis',       'COLIS_RECU',          'colis',     'normale', '{push,email,whatsapp}', false, 'Colis reçu à l''entrepôt'),
  ('shipment_packed',      'colis',       'COLIS_EMBALLE',       'colis',     'normale', '{push}',                false, 'Colis emballé'),
  ('shipment_shipped',     'colis',       'COLIS_EXPEDIE',       'colis',     'normale', '{push}',                false, 'Colis expédié'),
  ('shipment_arrived',     'colis',       'COLIS_ARRIVE',        'colis',     'normale', '{push}',                false, 'Arrivé au centre de distribution'),
  ('shipment_transferred', 'colis',       'COLIS_TRANSFERE',     'colis',     'normale', '{push}',                false, 'Transféré à la succursale'),
  ('shipment_available',   'colis',       'COLIS_DISPONIBLE',    'colis',     'haute',   '{push,email,whatsapp}', false, 'Colis disponible'),
  ('shipment_delivered',   'colis',       'COLIS_LIVRE',         'colis',     'normale', '{push}',                false, 'Colis livré'),
  ('action_required',      'colis',       'ACTION_REQUISE',      'colis',     'haute',   '{push,email}',          true,  'Action requise'),
  ('action_resolved',      'colis',       'ACTION_RESOLUE',      'colis',     'normale', '{push}',                false, 'Action résolue'),
  ('invoice_created',      'facturation', 'FACTURE_CREEE',       'factures',  'normale', '{push,email}',          true,  'Nouvelle facture'),
  ('payment_received',     'facturation', 'PAIEMENT_ENREGISTRE', 'paiements', 'normale', '{push,email}',          true,  'Paiement enregistré'),
  ('invoice_paid',         'facturation', 'FACTURE_PAYEE',       'factures',  'normale', '{push}',                true,  'Facture payée'),
  ('invoice_overdue',      'planifie',    'FACTURE_EN_RETARD',   'factures',  'normale', '{push,email}',          true,  'Facture en retard')
on conflict (type) do nothing;

alter table public.notification_regles enable row level security;
revoke all on public.notification_regles from anon, authenticated;


-- 4. Les préférences du client --------------------------------------------------
-- Une ligne seulement quand le client coupe (ou rallume) un canal pour une
-- catégorie : sans ligne, tout est actif. La notification dans l'espace client
-- ne se coupe pas — c'est l'historique de ses colis et de ses factures. Tout
-- est transactionnel ici : il n'y a aucun message commercial dans le projet (un
-- futur envoi commercial aurait son propre consentement, jamais celui-ci).

create table if not exists public.notification_preferences (
  client_id  uuid not null references public.clients (id) on delete cascade,
  categorie  text not null check (categorie in ('colis', 'factures', 'paiements')),
  canal      text not null check (canal in ('push', 'email', 'whatsapp', 'sms')),
  actif      boolean not null,
  maj_le     timestamptz not null default now(),
  primary key (client_id, categorie, canal)
);

alter table public.notification_preferences enable row level security;
revoke all on public.notification_preferences from anon, authenticated;


-- 5. Les envois ----------------------------------------------------------------
-- Un envoi = une notification, un canal, une cible (un téléphone, une adresse).
-- Son statut ne dit que ce que le fournisseur a confirmé :
--   attente   à envoyer (prochain_essai_le)
--   envoi     remis à pg_net, réponse du fournisseur pas encore lue
--   envoye    accepté par le fournisseur (identifiant du message gardé)
--   livre     remise confirmée par le fournisseur (aucun retour branché pour
--             l'instant : voir docs/notifications.md, « Webhooks »)
--   echec     refusé pour de bon, ou trois essais ratés
--   annule    jamais parti : canal non configuré, préférence, pas d'adresse…
-- « envoye » ne veut pas dire « lu », ni même « reçu par le téléphone ».

create table if not exists public.notification_envois (
  id               bigint generated always as identity primary key,
  notification_id  bigint not null references public.notifications (id) on delete cascade,
  canal            text not null check (canal in ('push', 'email', 'whatsapp', 'sms')),
  cible            text not null default '',   -- « appareil:<id> », « email », « whatsapp »
  appareil_id      uuid,
  fournisseur      text not null default '',
  statut           text not null default 'attente'
                   check (statut in ('attente', 'envoi', 'envoye', 'livre', 'echec', 'annule')),
  priorite         text not null default 'normale',
  tentative        integer not null default 0,
  prochain_essai_le timestamptz not null default now(),
  verrouille_le    timestamptz,
  requete          bigint,                     -- n° pg_net (réponse dans net._http_response)
  message_id       text,                       -- identifiant chez le fournisseur
  code_erreur      text,
  erreur           text,                       -- court, sans secret ni donnée personnelle
  cree_le          timestamptz not null default now(),
  envoye_le        timestamptz,
  livre_le         timestamptz,
  maj_le           timestamptz not null default now(),
  unique (notification_id, canal, cible)
);

create index if not exists notification_envois_dus_idx
  on public.notification_envois (prochain_essai_le) where statut = 'attente';
create index if not exists notification_envois_en_cours_idx
  on public.notification_envois (verrouille_le) where statut = 'envoi';
create index if not exists notification_envois_date_idx on public.notification_envois (cree_le desc);

alter table public.notification_envois enable row level security;
revoke all on public.notification_envois from anon, authenticated;


-- 6. Les textes ----------------------------------------------------------------
-- Les quatre langues du projet. Variables permises : {{numero}} (colis),
-- {{facture}} (numéro de facture), {{montant}} (mis en forme par la base) —
-- toutes lues dans la base, jamais tapées par un client ; échappées pour
-- l'e-mail. « verrou » : le texte du téléphone pour une règle sensible.

create or replace function public.notification_textes()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select '{
    "shipment_received": {
      "fr": {"titre": "Colis reçu", "message": "Votre colis {{numero}} a été reçu à notre entrepôt de Miami."},
      "en": {"titre": "Package received", "message": "Your package {{numero}} has been received at our Miami warehouse."},
      "es": {"titre": "Paquete recibido", "message": "Su paquete {{numero}} fue recibido en nuestro almacén de Miami."},
      "ht": {"titre": "Koli resevwa", "message": "Nou resevwa koli ou {{numero}} nan depo nou an Miami."}},
    "shipment_packed": {
      "fr": {"titre": "Colis emballé", "message": "Votre colis {{numero}} est emballé et prêt à partir."},
      "en": {"titre": "Package packed", "message": "Your package {{numero}} is packed and ready to ship."},
      "es": {"titre": "Paquete embalado", "message": "Su paquete {{numero}} está embalado y listo para salir."},
      "ht": {"titre": "Koli anbale", "message": "Koli ou {{numero}} anbale, li pare pou l pati."}},
    "shipment_shipped": {
      "fr": {"titre": "Colis expédié", "message": "Votre colis {{numero}} a été expédié."},
      "en": {"titre": "Package shipped", "message": "Your package {{numero}} has been shipped."},
      "es": {"titre": "Paquete enviado", "message": "Su paquete {{numero}} fue enviado."},
      "ht": {"titre": "Koli voye", "message": "Koli ou {{numero}} pati."}},
    "shipment_arrived": {
      "fr": {"titre": "Colis arrivé", "message": "Votre colis {{numero}} est arrivé au centre de distribution."},
      "en": {"titre": "Package arrived", "message": "Your package {{numero}} has arrived at the distribution centre."},
      "es": {"titre": "Paquete llegó", "message": "Su paquete {{numero}} llegó al centro de distribución."},
      "ht": {"titre": "Koli rive", "message": "Koli ou {{numero}} rive nan sant distribisyon an."}},
    "shipment_transferred": {
      "fr": {"titre": "Colis transféré", "message": "Votre colis {{numero}} a été transféré à la succursale."},
      "en": {"titre": "Package transferred", "message": "Your package {{numero}} has been transferred to the branch."},
      "es": {"titre": "Paquete transferido", "message": "Su paquete {{numero}} fue transferido a la sucursal."},
      "ht": {"titre": "Koli transfere", "message": "Koli ou {{numero}} transfere nan sikisal la."}},
    "shipment_available": {
      "fr": {"titre": "Colis disponible", "message": "Votre colis {{numero}} est disponible. Présentez votre code client pour le retirer."},
      "en": {"titre": "Package ready for pickup", "message": "Your package {{numero}} is ready for pickup. Please show your customer code."},
      "es": {"titre": "Paquete disponible", "message": "Su paquete {{numero}} está disponible. Presente su código de cliente para retirarlo."},
      "ht": {"titre": "Koli disponib", "message": "Koli ou {{numero}} disponib. Montre kòd kliyan ou pou w vin chèche l."}},
    "shipment_delivered": {
      "fr": {"titre": "Colis livré", "message": "Votre colis {{numero}} a été livré."},
      "en": {"titre": "Package delivered", "message": "Your package {{numero}} has been delivered."},
      "es": {"titre": "Paquete entregado", "message": "Su paquete {{numero}} fue entregado."},
      "ht": {"titre": "Koli livre", "message": "Koli ou {{numero}} livre."}},
    "action_required": {
      "fr": {"titre": "Action requise", "message": "Une action est requise concernant votre colis {{numero}}. Ouvrez votre espace pour en savoir plus."},
      "en": {"titre": "Action required", "message": "An action is required regarding your package {{numero}}. Open your account to learn more."},
      "es": {"titre": "Acción requerida", "message": "Se requiere una acción sobre su paquete {{numero}}. Abra su cuenta para más detalles."},
      "ht": {"titre": "Aksyon nesesè", "message": "Gen yon aksyon pou fè sou koli ou {{numero}}. Louvri espas ou pou w konnen plis."}},
    "action_resolved": {
      "fr": {"titre": "Action résolue", "message": "Le point en attente sur votre colis {{numero}} est réglé."},
      "en": {"titre": "Action resolved", "message": "The pending issue with your package {{numero}} has been resolved."},
      "es": {"titre": "Acción resuelta", "message": "El asunto pendiente de su paquete {{numero}} fue resuelto."},
      "ht": {"titre": "Aksyon regle", "message": "Pwoblèm ki te genyen sou koli ou {{numero}} an regle."}},
    "invoice_created": {
      "fr": {"titre": "Nouvelle facture", "message": "Une nouvelle facture ({{facture}}, {{montant}}) est disponible dans votre espace GoShip Express."},
      "en": {"titre": "New invoice", "message": "A new invoice ({{facture}}, {{montant}}) is available in your GoShip Express account."},
      "es": {"titre": "Nueva factura", "message": "Una nueva factura ({{facture}}, {{montant}}) está disponible en su cuenta GoShip Express."},
      "ht": {"titre": "Nouvo fakti", "message": "Yon nouvo fakti ({{facture}}, {{montant}}) disponib nan espas GoShip Express ou."}},
    "payment_received": {
      "fr": {"titre": "Paiement enregistré", "message": "Votre paiement de {{montant}} sur la facture {{facture}} a été enregistré."},
      "en": {"titre": "Payment recorded", "message": "Your payment of {{montant}} on invoice {{facture}} has been recorded."},
      "es": {"titre": "Pago registrado", "message": "Su pago de {{montant}} de la factura {{facture}} fue registrado."},
      "ht": {"titre": "Peman anrejistre", "message": "Nou anrejistre peman ou {{montant}} sou fakti {{facture}}."}},
    "invoice_paid": {
      "fr": {"titre": "Facture payée", "message": "Votre facture {{facture}} est entièrement payée. Merci !"},
      "en": {"titre": "Invoice paid", "message": "Your invoice {{facture}} is fully paid. Thank you!"},
      "es": {"titre": "Factura pagada", "message": "Su factura {{facture}} está totalmente pagada. ¡Gracias!"},
      "ht": {"titre": "Fakti peye", "message": "Fakti ou {{facture}} peye nèt. Mèsi !"}},
    "invoice_overdue": {
      "fr": {"titre": "Facture en retard", "message": "Votre facture {{facture}} a dépassé sa date d''échéance. Consultez-la dans votre espace."},
      "en": {"titre": "Invoice overdue", "message": "Your invoice {{facture}} is past its due date. Please check it in your account."},
      "es": {"titre": "Factura vencida", "message": "Su factura {{facture}} superó su fecha de vencimiento. Consúltela en su cuenta."},
      "ht": {"titre": "Fakti an reta", "message": "Fakti ou {{facture}} depase dat li te dwe peye a. Gade l nan espas ou."}},
    "test": {
      "fr": {"titre": "Notification d''essai", "message": "Ceci est un essai des notifications GoShip Express."},
      "en": {"titre": "Test notification", "message": "This is a test of GoShip Express notifications."},
      "es": {"titre": "Notificación de prueba", "message": "Esta es una prueba de las notificaciones de GoShip Express."},
      "ht": {"titre": "Notifikasyon esè", "message": "Sa se yon esè notifikasyon GoShip Express."}},
    "verrou": {
      "fr": {"titre": "GoShip Express", "message": "Une mise à jour concernant votre compte est disponible."},
      "en": {"titre": "GoShip Express", "message": "An update about your account is available."},
      "es": {"titre": "GoShip Express", "message": "Hay una actualización sobre su cuenta."},
      "ht": {"titre": "GoShip Express", "message": "Gen yon nouvèl sou kont ou."}},
    "email": {
      "fr": {"salutation": "Bonjour {{nom}},", "bouton": "OUVRIR MON ESPACE", "pied": "Vous recevez ce message car vous avez un compte client Goship Express. Réglez vos notifications dans votre espace."},
      "en": {"salutation": "Hello {{nom}},", "bouton": "OPEN MY ACCOUNT", "pied": "You receive this message because you have a Goship Express customer account. Manage your notifications in your account."},
      "es": {"salutation": "Estimado/a {{nom}}:", "bouton": "ABRIR MI CUENTA", "pied": "Recibe este mensaje porque tiene una cuenta de cliente Goship Express. Configure sus notificaciones en su cuenta."},
      "ht": {"salutation": "Bonjou {{nom}},", "bouton": "LOUVRI ESPAS MWEN", "pied": "Ou resevwa mesaj sa a paske ou gen yon kont kliyan Goship Express. Regle notifikasyon ou nan espas ou."}}
  }'::jsonb
$$;

-- Langue d'un client : celle de son compte, sinon le français
create or replace function public.langue_notification(p_langue text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when p_langue in ('fr', 'en', 'es', 'ht') then p_langue else 'fr' end
$$;

-- Un montant, mis en forme comme dans les pages (40,00 $ en français)
create or replace function public.montant_notification(p_montant numeric, p_langue text)
returns text
language sql
immutable
set search_path = ''
as $$
  -- Format écrit en toutes lettres : il ne dépend pas des réglages régionaux du serveur
  select case when p_montant is null then ''
              when p_langue in ('en', 'es') then '$' || to_char(round(p_montant, 2), 'FM9999999990.00')
              else replace(to_char(round(p_montant, 2), 'FM9999999990.00'), '.', ',') || ' $'
         end
$$;

-- Remplace les variables permises ; toute autre {{…}} disparaît
create or replace function public.rendre_notification(p_modele text, p_vars jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select regexp_replace(
           replace(replace(replace(coalesce(p_modele, ''),
             '{{numero}}', coalesce(p_vars ->> 'numero', '')),
             '{{facture}}', coalesce(p_vars ->> 'facture', '')),
             '{{montant}}', coalesce(p_vars ->> 'montant', '')),
           '\{\{[a-z_]*\}\}', '', 'g')
$$;

-- Titre et message d'une notification dans une langue
create or replace function public.texte_notification(p_type text, p_langue text, p_donnees jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_langue text := public.langue_notification(p_langue);
  v_t jsonb := public.notification_textes() -> p_type -> v_langue;
  v_vars jsonb := coalesce(p_donnees, '{}'::jsonb)
                  || jsonb_build_object('montant', public.montant_notification((p_donnees ->> 'montant_usd')::numeric, v_langue));
begin
  if v_t is null then
    v_t := jsonb_build_object('titre', 'GoShip Express', 'message', '');
  end if;
  return jsonb_build_object('titre', public.rendre_notification(v_t ->> 'titre', v_vars),
                            'message', public.rendre_notification(v_t ->> 'message', v_vars));
end;
$$;


-- 7. Les canaux : configurés ou non ---------------------------------------------
-- Lu dans le coffre-fort ; seul « oui / non » sort d'ici, jamais une clé.

create or replace function public.canal_configure(p_canal text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return case p_canal
    when 'push' then true   -- service Expo : aucune clé à poser
    when 'email' then coalesce(public.lire_reglage('email_cle_api'), '') <> ''
                      and coalesce(public.lire_reglage('email_expediteur'), '') <> ''
    when 'whatsapp' then coalesce(public.lire_reglage('whatsapp_jeton'), '') <> ''
                         and coalesce(public.lire_reglage('whatsapp_numero_id'), '') <> ''
    else false              -- sms : aucun fournisseur dans le projet
  end;
end;
$$;

-- Les modèles WhatsApp approuvés par Meta (les mêmes que ceux du tableau de bord).
-- Un type sans modèle ne part pas sur WhatsApp : l'envoi est « annule, SANS_MODELE ».
create or replace function public.modele_whatsapp(p_type text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_type when 'shipment_received' then 'colis_recu'
                     when 'shipment_available' then 'colis_disponible' end
$$;


-- 8. Créer une notification --------------------------------------------------------
-- Le cœur du moteur, appelé par les déclencheurs (jamais par une page).
-- Renvoie l'identifiant de la notification, ou null si elle existait déjà
-- (même clé) ou si la règle est coupée. p_canaux ne sert qu'à l'essai de
-- l'administrateur (règle « test »).

create or replace function public.planifier_envois(p_notification bigint, p_client uuid, p_categorie text,
                                                   p_type text, p_priorite text, p_canaux text[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_client public.clients;
  v_canal text;
  v_raison text;
  a record;
begin
  select * into v_client from public.clients where id = p_client;
  foreach v_canal in array coalesce(p_canaux, '{}'::text[]) loop
    v_raison := null;
    if exists (select 1 from public.notification_preferences p
               where p.client_id = p_client and p.categorie = p_categorie and p.canal = v_canal and not p.actif) then
      v_raison := 'PREFERENCE';
    elsif not public.canal_configure(v_canal) then
      v_raison := 'NON_CONFIGURE';
    end if;

    if v_canal = 'push' and v_raison is null then
      if not exists (select 1 from public.appareils where client_id = p_client) then
        v_raison := 'SANS_APPAREIL';
      else
        for a in select id from public.appareils where client_id = p_client loop
          insert into public.notification_envois (notification_id, canal, cible, appareil_id, fournisseur, priorite)
          values (p_notification, 'push', 'appareil:' || a.id, a.id, 'expo', p_priorite)
          on conflict (notification_id, canal, cible) do nothing;
        end loop;
        continue;
      end if;
    elsif v_canal = 'email' and v_raison is null and coalesce(v_client.email, '') = '' then
      v_raison := 'SANS_DESTINATAIRE';
    elsif v_canal = 'whatsapp' and v_raison is null then
      if public.modele_whatsapp(p_type) is null then
        v_raison := 'SANS_MODELE';
      elsif coalesce(public.telephone_international(v_client.telephone, v_client.pays), '') = '' then
        v_raison := 'SANS_DESTINATAIRE';
      end if;
    end if;

    insert into public.notification_envois (notification_id, canal, cible, fournisseur, priorite, statut, code_erreur)
    values (p_notification, v_canal, v_canal,
            case v_canal when 'push' then 'expo'
                         when 'email' then coalesce(nullif(public.lire_reglage('email_fournisseur'), ''), 'brevo')
                         when 'whatsapp' then 'meta' else '' end,
            p_priorite,
            case when v_raison is null then 'attente' else 'annule' end, v_raison)
    on conflict (notification_id, canal, cible) do nothing;
  end loop;
end;
$$;

create or replace function public.creer_notification(p_type text, p_client uuid, p_cle text,
                                                     p_colis uuid default null, p_facture uuid default null,
                                                     p_paiement uuid default null, p_historique bigint default null,
                                                     p_donnees jsonb default '{}'::jsonb,
                                                     p_canaux text[] default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_regle public.notification_regles;
  v_id bigint;
  v_categorie text;
  v_priorite text;
  v_canaux text[];
begin
  if p_client is null or not exists (select 1 from public.clients where id = p_client) then
    return null;
  end if;
  if p_canaux is null then
    select * into v_regle from public.notification_regles where type = p_type;
    if not found or not v_regle.actif then
      return null;
    end if;
    v_categorie := v_regle.categorie;
    v_priorite := v_regle.priorite;
    v_canaux := v_regle.canaux;
  else
    v_categorie := 'compte';
    v_priorite := 'normale';
    v_canaux := p_canaux;
  end if;

  insert into public.notifications (client_id, colis_id, facture_id, paiement_id, historique_id, canal,
                                    evenement, destinataire, type, categorie, priorite, cle, donnees)
  values (p_client, p_colis, p_facture, p_paiement, p_historique, 'app',
          p_type, '', p_type, v_categorie, v_priorite, p_cle, coalesce(p_donnees, '{}'::jsonb))
  on conflict (cle) where cle is not null do nothing
  returning id into v_id;

  if v_id is null then
    return null; -- déjà créée pour cet événement
  end if;
  perform public.planifier_envois(v_id, p_client, v_categorie, p_type, v_priorite, v_canaux);
  return v_id;
end;
$$;


-- 9. Les sources : étapes des colis et événements de facturation -------------------

-- Une étape écrite dans l'historique d'un colis. Seules les étapes publiques
-- (celles que le client voit déjà) notifient : une inspection interne, une
-- correction, jamais. Un échec ici ne bloque jamais l'opération : le colis est
-- enregistré, la notification manque — et le journal du moteur le dira.
create or replace function public.notifier_etape_colis()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_type text;
  v_colis public.colis;
begin
  -- Une reprise de données (import d'anciens colis) ne réveille personne
  if new.visibilite is distinct from 'publique' or new.type_evenement is null or public.contexte_reprise() then
    return null;
  end if;
  select type into v_type from public.notification_regles
   where source = 'colis' and evenement = new.type_evenement;
  if v_type is null then
    return null;
  end if;
  select * into v_colis from public.colis where id = new.colis_id;
  if v_colis.client_id is null then
    return null;
  end if;
  begin
    perform public.creer_notification(v_type, v_colis.client_id, 'etape:' || new.id || ':' || v_type,
                                      v_colis.id, null, null, new.id,
                                      jsonb_build_object('numero', v_colis.numero, 'statut', new.statut));
  exception when others then
    raise warning 'Notification non créée (étape %) : %', new.id, sqlerrm;
  end;
  return null;
end;
$$;

drop trigger if exists notifier_etape_colis on public.colis_historique;
create trigger notifier_etape_colis
  after insert on public.colis_historique
  for each row execute function public.notifier_etape_colis();

-- La notification du téléphone passe désormais par le moteur (règles, envois,
-- statuts). L'ancien déclencheur, qui l'envoyait directement, est retiré pour
-- ne pas l'envoyer deux fois. pousser_colis reste, sans déclencheur.
drop trigger if exists pousser_au_changement on public.colis;

-- Un événement de la facturation. C'est la file que la Phase 5 avait préparée
-- (« rien ne la lit encore ») : on la lit ici, et traite_le est posé.
-- Un paiement qui solde la facture ne produit qu'une notification : « facture
-- payée » (écrite juste avant, dans la même transaction) suffit.
create or replace function public.notifier_evenement_facturation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_type text;
  v_cle text;
  v_numero text;
begin
  select type into v_type from public.notification_regles
   where source = 'facturation' and evenement = new.type;
  if v_type is not null and new.client_id is not null then
    v_numero := coalesce(new.donnees ->> 'numero', new.donnees ->> 'facture',
                         (select numero from public.factures where id = new.facture_id));
    v_cle := case v_type
               when 'invoice_created' then 'facture:' || new.facture_id
               when 'payment_received' then 'paiement:' || new.paiement_id
               else 'facturation:' || new.id end;
    begin
      if v_type = 'payment_received' and exists (
           select 1 from public.notifications
            where facture_id = new.facture_id and type = 'invoice_paid' and envoye_le = now()) then
        null; -- regroupé dans « facture payée »
      else
        perform public.creer_notification(v_type, new.client_id, v_cle, null, new.facture_id, new.paiement_id, null,
                                          jsonb_build_object('facture', v_numero,
                                                             'montant_usd', (new.donnees ->> 'montant_usd')::numeric));
      end if;
    exception when others then
      raise warning 'Notification non créée (événement de facturation %) : %', new.id, sqlerrm;
    end;
  end if;
  update public.evenements_facturation set traite_le = now() where id = new.id;
  return null;
end;
$$;

drop trigger if exists notifier_evenement_facturation on public.evenements_facturation;
create trigger notifier_evenement_facturation
  after insert on public.evenements_facturation
  for each row execute function public.notifier_evenement_facturation();

-- Rappel « facture en retard » : une fois par facture, seulement si l'échéance
-- est postérieure à la mise en service (aucun rappel rétroactif), jamais sur une
-- facture sans échéance. Appelé chaque jour par le planificateur.
create or replace function public.notifications_quotidiennes()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_depuis date := (select (actives_depuis at time zone 'America/Santo_Domingo')::date from public.notification_moteur);
  v_nb integer := 0;
  v_purge integer;
  f record;
begin
  for f in select * from public.factures fa
            where fa.statut <> 'annulee' and fa.echeance_le is not null
              and fa.echeance_le >= v_depuis
              and public.etat_paiement(fa) = 'en_retard'
              and not exists (select 1 from public.notifications n where n.cle = 'retard:' || fa.id) loop
    if public.creer_notification('invoice_overdue', f.client_id, 'retard:' || f.id, null, f.id, null, null,
                                 jsonb_build_object('facture', f.numero)) is not null then
      v_nb := v_nb + 1;
    end if;
  end loop;

  -- Conservation : les envois terminés depuis plus de 180 jours sont des traces
  -- techniques ; la notification (l'historique du client) reste.
  delete from public.notification_envois
   where statut in ('envoye', 'livre', 'echec', 'annule') and cree_le < now() - interval '180 days';
  get diagnostics v_purge = row_count;
  return jsonb_build_object('rappels', v_nb, 'envois_purges', v_purge);
end;
$$;


-- 10. Le travailleur : envoyer, puis lire les réponses ------------------------------

-- Le contenu d'un envoi pour son fournisseur, et la requête pg_net.
create or replace function public.expedier_envoi(p_envoi public.notification_envois)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  n public.notifications;
  cl public.clients;
  v_regle public.notification_regles;
  v_langue text;
  v_t jsonb;
  v_verrou jsonb;
  v_numero text;
  v_lien text;
  v_site text := coalesce(public.lire_reglage('site_url'), '');
  v_donnees jsonb;
  v_email jsonb;
  v_requete bigint;
  v_jeton text;
  v_cle text;
  v_fournisseur text;
  v_expediteur text;
  v_nom_expediteur text;
  v_telephone text;
begin
  select * into n from public.notifications where id = p_envoi.notification_id;
  select * into cl from public.clients where id = n.client_id;
  select * into v_regle from public.notification_regles where type = n.type;
  v_langue := public.langue_notification(cl.langue);
  v_t := public.texte_notification(n.type, v_langue, n.donnees);
  v_numero := coalesce(n.donnees ->> 'numero', '');

  if p_envoi.canal = 'push' then
    select jeton into v_jeton from public.appareils where id = p_envoi.appareil_id;
    if v_jeton is null then
      raise exception 'APPAREIL_INCONNU';
    end if;
    -- Écran verrouillé : rien de financier ni de personnel pour une règle sensible
    v_verrou := case when coalesce(v_regle.sensible, false)
                     then public.notification_textes() -> 'verrou' -> v_langue else v_t end;
    v_donnees := jsonb_build_object('notification_id', n.id, 'type', n.type);
    if n.colis_id is not null then
      v_donnees := v_donnees || jsonb_build_object('colis_id', n.colis_id);
    elsif n.facture_id is not null then
      -- Les versions installées ouvrent l'onglet Factures ; les suivantes, la facture
      v_donnees := v_donnees || jsonb_build_object('facture_id', n.facture_id, 'route', '/(onglets)/factures');
    end if;
    select net.http_post(
      url := 'https://exp.host/--/api/v2/push/send',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Accept', 'application/json'),
      body := jsonb_build_array(jsonb_build_object(
        'to', v_jeton, 'title', v_verrou ->> 'titre', 'body', v_verrou ->> 'message',
        'sound', 'default', 'channelId', 'colis',
        'priority', case when n.priorite = 'haute' then 'high' else 'default' end,
        'data', v_donnees))
    ) into v_requete;

  elsif p_envoi.canal = 'email' then
    v_cle := public.lire_reglage('email_cle_api');
    v_fournisseur := coalesce(nullif(public.lire_reglage('email_fournisseur'), ''), 'brevo');
    v_expediteur := public.lire_reglage('email_expediteur');
    v_nom_expediteur := coalesce(nullif(public.lire_reglage('email_nom'), ''), 'Goship Express');
    if coalesce(v_cle, '') = '' or coalesce(v_expediteur, '') = '' then
      raise exception 'NON_CONFIGURE';
    end if;
    if coalesce(cl.email, '') = '' then
      raise exception 'SANS_DESTINATAIRE';
    end if;
    -- Lien officiel seulement (réglage site_url, en https) ; sinon, pas de bouton
    v_lien := case when v_site ~ '^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~/-]*)?$'
                   then regexp_replace(v_site, '/?$', '/') || 'mon-compte.html' else '' end;
    v_email := public.notification_textes() -> 'email' -> v_langue;
    v_email := jsonb_build_object(
      'sujet', (v_t ->> 'titre') || case when v_numero <> '' then ' — ' || v_numero
                                         when n.donnees ? 'facture' then ' — ' || (n.donnees ->> 'facture') else '' end,
      'html', public.courriel_gabarit(v_langue, v_t ->> 'titre',
                replace(v_email ->> 'salutation', '{{nom}}', coalesce(nullif(split_part(cl.nom_complet, ' ', 1), ''), '')),
                '<p style="margin:0;font-size:16px;line-height:1.6">' || public.html_echappe(v_t ->> 'message') || '</p>',
                v_email ->> 'bouton', v_lien, v_email ->> 'pied'),
      'texte', replace(v_email ->> 'salutation', '{{nom}}', coalesce(split_part(cl.nom_complet, ' ', 1), '')) || E'\n\n' ||
               (v_t ->> 'message') || case when v_lien <> '' then E'\n\n' || v_lien else '' end || E'\n\n— Goship Express');
    if v_fournisseur = 'resend' then
      select net.http_post(
        url := 'https://api.resend.com/emails',
        headers := jsonb_build_object('Authorization', 'Bearer ' || v_cle, 'Content-Type', 'application/json'),
        body := jsonb_build_object('from', v_nom_expediteur || ' <' || v_expediteur || '>',
                                   'to', jsonb_build_array(cl.email),
                                   'subject', v_email ->> 'sujet', 'html', v_email ->> 'html', 'text', v_email ->> 'texte')
      ) into v_requete;
    else
      select net.http_post(
        url := 'https://api.brevo.com/v3/smtp/email',
        headers := jsonb_build_object('api-key', v_cle, 'Content-Type', 'application/json', 'Accept', 'application/json'),
        body := jsonb_build_object('sender', jsonb_build_object('name', v_nom_expediteur, 'email', v_expediteur),
                                   'to', jsonb_build_array(jsonb_build_object('email', cl.email, 'name', coalesce(cl.nom_complet, ''))),
                                   'subject', v_email ->> 'sujet', 'htmlContent', v_email ->> 'html',
                                   'textContent', v_email ->> 'texte')
      ) into v_requete;
    end if;

  elsif p_envoi.canal = 'whatsapp' then
    if not public.canal_configure('whatsapp') then
      raise exception 'NON_CONFIGURE';
    end if;
    v_telephone := public.telephone_international(cl.telephone, cl.pays);
    if coalesce(v_telephone, '') = '' then
      raise exception 'SANS_DESTINATAIRE';
    end if;
    select net.http_post(
      url := 'https://graph.facebook.com/' || coalesce(nullif(public.lire_reglage('whatsapp_version'), ''), 'v23.0') ||
             '/' || public.lire_reglage('whatsapp_numero_id') || '/messages',
      headers := jsonb_build_object('Authorization', 'Bearer ' || public.lire_reglage('whatsapp_jeton'),
                                    'Content-Type', 'application/json'),
      body := jsonb_build_object(
        'messaging_product', 'whatsapp', 'to', v_telephone, 'type', 'template',
        'template', jsonb_build_object(
          'name', public.modele_whatsapp(n.type),
          'language', jsonb_build_object('code', case v_langue when 'en' then 'en_US' when 'es' then 'es' else 'fr' end),
          'components', jsonb_build_array(jsonb_build_object('type', 'body', 'parameters',
            (select jsonb_agg(jsonb_build_object('type', 'text', 'text', coalesce(nullif(p, ''), '—')))
               from unnest(case public.modele_whatsapp(n.type)
                             when 'colis_disponible' then array[cl.nom_complet, v_numero, 'Goship Express', cl.code]
                             else array[cl.nom_complet, v_numero, cl.code,
                                        (select description from public.colis where id = n.colis_id),
                                        coalesce((select poids_lb::text || ' lb' from public.colis where id = n.colis_id), ''),
                                        to_char(n.envoye_le at time zone 'America/Santo_Domingo', 'DD/MM/YYYY HH24:MI')]
                           end) p)))))
    ) into v_requete;

  else
    raise exception 'NON_CONFIGURE'; -- sms : aucun fournisseur
  end if;
  return v_requete;
end;
$$;

-- La réponse d'un fournisseur → statut de l'envoi. Échec « temporaire » (délai,
-- limite de débit, fournisseur en panne) : nouvel essai 30 s, 2 min, 10 min
-- après ; échec « définitif » (adresse, numéro, jeton ou modèle invalide) :
-- jamais réessayé. L'erreur gardée est courte et sans donnée personnelle.
create or replace function public.lire_reponse_envoi(p_envoi public.notification_envois, p_code integer,
                                                     p_contenu text, p_erreur text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_json jsonb;
  v_ticket jsonb;
  v_id text;
  v_code text;
  v_temporaire boolean := false;
  v_max integer := (select tentatives_max from public.notification_moteur);
begin
  begin
    v_json := p_contenu::jsonb;
  exception when others then
    v_json := null;
  end;

  if p_erreur is not null then
    v_temporaire := true;
    v_code := 'RESEAU';
  elsif p_code between 200 and 299 then
    if p_envoi.canal = 'push' then
      v_ticket := coalesce(v_json -> 'data' -> 0, v_json -> 'data');
      if v_ticket ->> 'status' = 'ok' then
        v_id := v_ticket ->> 'id';
      else
        v_code := coalesce(v_ticket -> 'details' ->> 'error', 'EXPO_ERREUR');
        v_temporaire := v_code in ('MessageRateExceeded', 'ExpoError');
        if v_code = 'DeviceNotRegistered' then
          -- Application désinstallée ou jeton révoqué : on oublie ce téléphone
          delete from public.appareils where id = p_envoi.appareil_id;
        end if;
      end if;
    else
      v_id := coalesce(v_json ->> 'messageId', v_json ->> 'id', v_json -> 'messages' -> 0 ->> 'id');
    end if;
  elsif p_code in (408, 425, 429) or p_code >= 500 then
    v_temporaire := true;
    v_code := 'HTTP_' || p_code;
  else
    v_code := 'HTTP_' || coalesce(p_code, 0);
  end if;

  if v_code is null then
    update public.notification_envois
       set statut = 'envoye', message_id = left(v_id, 200), envoye_le = now(), code_erreur = null, erreur = null,
           verrouille_le = null, maj_le = now()
     where id = p_envoi.id;
  elsif v_temporaire and p_envoi.tentative < v_max then
    update public.notification_envois
       set statut = 'attente', code_erreur = v_code, verrouille_le = null, maj_le = now(),
           prochain_essai_le = now() + case p_envoi.tentative when 1 then interval '30 seconds'
                                                               when 2 then interval '2 minutes'
                                                               else interval '10 minutes' end
     where id = p_envoi.id;
  else
    update public.notification_envois
       set statut = 'echec', code_erreur = case when v_temporaire then 'ABANDON_' || v_code else v_code end,
           erreur = left(coalesce(v_json ->> 'message', v_json -> 'error' ->> 'message', v_json ->> 'code', p_erreur, ''), 200),
           verrouille_le = null, maj_le = now()
     where id = p_envoi.id;
  end if;
end;
$$;

-- Un passage du travailleur. Deux passages en même temps ne prennent jamais le
-- même envoi (for update skip locked). Renvoie ce qui a été fait.
create or replace function public.traiter_notifications(p_lot integer default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_lot integer := coalesce(p_lot, (select lot from public.notification_moteur), 50);
  v_lus integer := 0;
  v_partis integer := 0;
  v_rates integer := 0;
  e public.notification_envois;
  r record;
  v_requete bigint;
begin
  -- 1. Les réponses arrivées depuis le passage précédent
  for e in select * from public.notification_envois
            where statut = 'envoi' order by verrouille_le limit v_lot * 4 for update skip locked loop
    select status_code, content, error_msg into r from net._http_response where id = e.requete;
    if found then
      perform public.lire_reponse_envoi(e, r.status_code, r.content, r.error_msg);
      v_lus := v_lus + 1;
    elsif e.verrouille_le < now() - interval '10 minutes' then
      perform public.lire_reponse_envoi(e, null, null, 'SANS_REPONSE');
      v_lus := v_lus + 1;
    end if;
  end loop;

  -- 2. Les envois dus, les plus urgents d'abord, par lots (pas de rafale)
  for e in select * from public.notification_envois
            where statut = 'attente' and prochain_essai_le <= now()
            order by (priorite = 'haute') desc, prochain_essai_le
            limit v_lot for update skip locked loop
    begin
      v_requete := public.expedier_envoi(e);
      update public.notification_envois
         set statut = 'envoi', requete = v_requete, tentative = tentative + 1,
             verrouille_le = now(), maj_le = now()
       where id = e.id;
      v_partis := v_partis + 1;
    exception when others then
      -- Rien n'est parti : l'envoi est clos avec sa raison (canal coupé entre-temps…)
      update public.notification_envois
         set statut = case when sqlerrm in ('NON_CONFIGURE', 'SANS_DESTINATAIRE', 'APPAREIL_INCONNU') then 'annule'
                           else 'echec' end,
             code_erreur = case when sqlerrm in ('NON_CONFIGURE', 'SANS_DESTINATAIRE', 'APPAREIL_INCONNU') then sqlerrm
                                else 'ERREUR_INTERNE' end,
             erreur = left(sqlerrm, 200), maj_le = now()
       where id = e.id;
      v_rates := v_rates + 1;
    end;
  end loop;

  return jsonb_build_object('reponses_lues', v_lus, 'envoyes', v_partis, 'non_partis', v_rates);
end;
$$;


-- 11. Le client : ses notifications, « lu », ses canaux ----------------------------

create or replace function public.mes_notifications(p_filtre text default 'toutes', p_page integer default 0,
                                                    p_par_page integer default 20, p_langue text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_moi uuid := auth.uid();
  v_langue text;
  v_par_page integer := least(greatest(coalesce(p_par_page, 20), 1), 100);
  v_page integer := greatest(coalesce(p_page, 0), 0);
begin
  if v_moi is null then
    perform public.erreur_metier('PERMISSION_DENIED', 'Connectez-vous pour voir vos notifications.');
  end if;
  if coalesce(p_filtre, 'toutes') not in ('toutes', 'non_lues', 'colis', 'factures', 'paiements', 'compte') then
    perform public.erreur_metier('INVALID_FILTER', 'Filtre inconnu.');
  end if;
  -- La langue de l'écran si elle est connue, sinon celle du compte
  v_langue := case when p_langue in ('fr', 'en', 'es', 'ht') then p_langue
                   else public.langue_notification((select langue from public.clients where id = v_moi)) end;

  return (
    with miennes as (
      select n.* from public.notifications n
       where n.client_id = v_moi and n.canal = 'app'
         and (coalesce(p_filtre, 'toutes') = 'toutes'
              or (p_filtre = 'non_lues' and n.lu_le is null)
              or n.categorie = p_filtre))
    select jsonb_build_object(
      'total', (select count(*) from miennes),
      'non_lues', (select count(*) from public.notifications
                    where client_id = v_moi and canal = 'app' and lu_le is null),
      'elements', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', m.id, 'type', m.type, 'categorie', m.categorie, 'priorite', m.priorite,
                 'titre', t ->> 'titre', 'message', t ->> 'message',
                 'lu', m.lu_le is not null, 'date', m.envoye_le,
                 'colis_id', m.colis_id, 'numero', m.donnees ->> 'numero',
                 'facture_id', m.facture_id, 'facture_numero', m.donnees ->> 'facture')
               order by m.envoye_le desc, m.id desc)
        from (select mi.*, public.texte_notification(mi.type, v_langue, mi.donnees) as t
                from miennes mi order by mi.envoye_le desc, mi.id desc
               limit v_par_page offset v_page * v_par_page) m), '[]'::jsonb))
  );
end;
$$;

create or replace function public.notifications_non_lues()
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer from public.notifications
   where client_id = auth.uid() and canal = 'app' and lu_le is null
$$;

-- p_ids vide ou null : toutes. Jamais celles d'un autre : le filtre sur le
-- client connecté est dans la requête elle-même.
create or replace function public.marquer_notifications_lues(p_ids bigint[] default null)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_moi uuid := auth.uid();
  v_nb integer;
begin
  if v_moi is null then
    perform public.erreur_metier('PERMISSION_DENIED', 'Connectez-vous pour gérer vos notifications.');
  end if;
  update public.notifications set lu_le = now()
   where client_id = v_moi and canal = 'app' and lu_le is null
     and (p_ids is null or cardinality(p_ids) = 0 or id = any (p_ids));
  get diagnostics v_nb = row_count;
  return v_nb;
end;
$$;

create or replace function public.mes_preferences_notifications()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_moi uuid := auth.uid();
begin
  if v_moi is null then
    perform public.erreur_metier('PERMISSION_DENIED', 'Connectez-vous pour régler vos notifications.');
  end if;
  return jsonb_build_object(
    'canaux', (select jsonb_object_agg(c, jsonb_build_object(
                        'configure', public.canal_configure(c),
                        'appareils', case when c = 'push' then (select count(*) from public.appareils where client_id = v_moi) end))
                 from unnest(array['push', 'email', 'whatsapp', 'sms']) c),
    'preferences', (select jsonb_agg(jsonb_build_object(
                             'categorie', cat,
                             'push', coalesce((select actif from public.notification_preferences
                                                where client_id = v_moi and categorie = cat and canal = 'push'), true),
                             'email', coalesce((select actif from public.notification_preferences
                                                 where client_id = v_moi and categorie = cat and canal = 'email'), true),
                             'whatsapp', coalesce((select actif from public.notification_preferences
                                                    where client_id = v_moi and categorie = cat and canal = 'whatsapp'), true),
                             'sms', coalesce((select actif from public.notification_preferences
                                               where client_id = v_moi and categorie = cat and canal = 'sms'), true))
                           order by ord)
                      from unnest(array['colis', 'factures', 'paiements']) with ordinality u(cat, ord)));
end;
$$;

create or replace function public.regler_preference_notification(p_categorie text, p_canal text, p_actif boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_moi uuid := auth.uid();
begin
  if v_moi is null then
    perform public.erreur_metier('PERMISSION_DENIED', 'Connectez-vous pour régler vos notifications.');
  end if;
  if p_categorie not in ('colis', 'factures', 'paiements') or p_canal not in ('push', 'email', 'whatsapp', 'sms')
     or p_actif is null then
    perform public.erreur_metier('INVALID_PREFERENCE', 'Réglage de notification inconnu.');
  end if;
  insert into public.notification_preferences (client_id, categorie, canal, actif, maj_le)
  values (v_moi, p_categorie, p_canal, p_actif, now())
  on conflict (client_id, categorie, canal) do update set actif = excluded.actif, maj_le = now();
  perform public.auditer('notification.preference', 'client', v_moi::text, null,
                         jsonb_build_object('categorie', p_categorie, 'canal', p_canal, 'actif', p_actif));
end;
$$;


-- 12. L'équipe : envois, suivi, règles, canaux, essai --------------------------------
-- Voir les envois et les règles : reports.view (gérant, administrateur). Changer
-- une règle, envoyer un essai : settings.manage (administrateur). Aucune clé ne
-- sort jamais : un canal est « configuré » ou non.

create or replace function public.centre_notifications(p_debut timestamptz default null, p_fin timestamptz default null,
                                                       p_type text default null, p_canal text default null,
                                                       p_statut text default null, p_page integer default 0,
                                                       p_par_page integer default 25)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_debut timestamptz := coalesce(p_debut, now() - interval '30 days');
  v_fin timestamptz := coalesce(p_fin, now());
  v_par_page integer := least(greatest(coalesce(p_par_page, 25), 1), 100);
begin
  perform public.exiger_permission('reports.view');
  return (
    with e as (
      select en.*, n.type, n.client_id, n.donnees
        from public.notification_envois en
        join public.notifications n on n.id = en.notification_id
       where en.cree_le >= v_debut and en.cree_le < v_fin
         and (p_type is null or n.type = p_type)
         and (p_canal is null or en.canal = p_canal)
         and (p_statut is null or en.statut = p_statut))
    select jsonb_build_object(
      'periode', jsonb_build_object('debut', v_debut, 'fin', v_fin),
      'notifications', (select count(*) from public.notifications
                         where canal = 'app' and envoye_le >= v_debut and envoye_le < v_fin
                           and (p_type is null or type = p_type)),
      'non_lues', (select count(*) from public.notifications
                    where canal = 'app' and lu_le is null and envoye_le >= v_debut and envoye_le < v_fin),
      'envois', (select count(*) from e),
      'par_statut', (select coalesce(jsonb_object_agg(statut, nb), '{}'::jsonb)
                       from (select statut, count(*) nb from e group by statut) s),
      'par_canal', (select coalesce(jsonb_object_agg(canal, jsonb_build_object(
                            'total', total, 'envoye', envoye, 'echec', echec, 'attente', attente, 'annule', annule,
                            'taux_echec', case when envoye + echec = 0 then null
                                               else round(100.0 * echec / (envoye + echec), 1) end)), '{}'::jsonb)
                      from (select canal, count(*) total,
                                   count(*) filter (where statut in ('envoye', 'livre')) envoye,
                                   count(*) filter (where statut = 'echec') echec,
                                   count(*) filter (where statut in ('attente', 'envoi')) attente,
                                   count(*) filter (where statut = 'annule') annule
                              from e group by canal) c),
      'delai_moyen_s', (select round(avg(extract(epoch from envoye_le - cree_le)))
                          from e where envoye_le is not null),
      'alertes', (select coalesce(jsonb_agg(a), '[]'::jsonb) from (
          select jsonb_build_object('code', 'FILE_BLOQUEE', 'nombre', count(*)) a
            from public.notification_envois
           where (statut = 'attente' and prochain_essai_le < now() - interval '15 minutes')
              or (statut = 'envoi' and verrouille_le < now() - interval '15 minutes')
          having count(*) > 0
          union all
          select jsonb_build_object('code', 'ECHECS_ANORMAUX', 'canal', canal, 'taux', round(100.0 * ech / tot, 1))
            from (select canal, count(*) filter (where statut = 'echec') ech,
                         count(*) filter (where statut in ('envoye', 'livre', 'echec')) tot
                    from public.notification_envois where cree_le > now() - interval '24 hours'
                   group by canal) t
           where tot >= 10 and ech * 5 > tot
          union all
          select jsonb_build_object('code', 'APPAREILS_OUBLIES', 'nombre', count(*))
            from public.notification_envois
           where code_erreur = 'DeviceNotRegistered' and cree_le > now() - interval '24 hours'
          having count(*) >= 20) x),
      'total', (select count(*) from e),
      'elements', coalesce((select jsonb_agg(jsonb_build_object(
                     'id', l.id, 'notification_id', l.notification_id, 'type', l.type, 'canal', l.canal,
                     'fournisseur', l.fournisseur, 'statut', l.statut, 'tentative', l.tentative,
                     'code_erreur', l.code_erreur, 'cree_le', l.cree_le, 'envoye_le', l.envoye_le,
                     'client_code', (select code from public.clients where id = l.client_id),
                     'numero', l.donnees ->> 'numero', 'facture', l.donnees ->> 'facture')
                   order by l.cree_le desc, l.id desc)
                   from (select * from e order by cree_le desc, id desc
                          limit v_par_page offset greatest(coalesce(p_page, 0), 0) * v_par_page) l), '[]'::jsonb))
  );
end;
$$;

-- « Pourquoi ce client n'a-t-il rien reçu ? » : l'événement, la notification,
-- chacun de ses envois, avec tentatives et codes.
create or replace function public.suivi_notification(p_notification bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  n public.notifications;
begin
  perform public.exiger_permission('reports.view');
  select * into n from public.notifications where id = p_notification and canal = 'app';
  if not found then
    perform public.erreur_metier('NOTIFICATION_NOT_FOUND', 'Notification introuvable.');
  end if;
  return jsonb_build_object(
    'notification', jsonb_build_object('id', n.id, 'type', n.type, 'categorie', n.categorie, 'priorite', n.priorite,
                                       'cree_le', n.envoye_le, 'lu_le', n.lu_le, 'cle', n.cle,
                                       'client_code', (select code from public.clients where id = n.client_id),
                                       'numero', n.donnees ->> 'numero', 'facture', n.donnees ->> 'facture'),
    'evenement', case when n.historique_id is not null then (
                   select jsonb_build_object('source', 'colis', 'id', h.id, 'type', h.type_evenement,
                                             'statut', h.statut, 'date', h.cree_le)
                     from public.colis_historique h where h.id = n.historique_id)
                 when n.facture_id is not null then (
                   select jsonb_build_object('source', 'facturation', 'id', f.id, 'type', f.type, 'date', f.cree_le)
                     from public.evenements_facturation f
                    where f.facture_id = n.facture_id
                      and f.type = (select evenement from public.notification_regles where type = n.type)
                      and (n.paiement_id is null or f.paiement_id = n.paiement_id)
                    order by f.id limit 1) end,
    'regle', (select jsonb_build_object('actif', r.actif, 'canaux', r.canaux, 'sensible', r.sensible)
                from public.notification_regles r where r.type = n.type),
    'envois', coalesce((select jsonb_agg(jsonb_build_object(
                 'canal', en.canal, 'fournisseur', en.fournisseur, 'statut', en.statut, 'tentative', en.tentative,
                 'code_erreur', en.code_erreur, 'erreur', en.erreur, 'message_id', en.message_id,
                 'cree_le', en.cree_le, 'envoye_le', en.envoye_le, 'prochain_essai_le',
                 case when en.statut = 'attente' then en.prochain_essai_le end) order by en.id)
               from public.notification_envois en where en.notification_id = n.id), '[]'::jsonb));
end;
$$;

-- Les envois d'un colis, pour la fiche « Mettre à jour » du tableau de bord
create or replace function public.envois_colis(p_colis uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('shipments.view');
  return coalesce((select jsonb_agg(jsonb_build_object(
            'notification_id', n.id, 'type', n.type, 'cree_le', n.envoye_le, 'canal', en.canal,
            'statut', en.statut, 'code_erreur', en.code_erreur, 'tentative', en.tentative)
            order by n.envoye_le desc, en.id)
          from public.notifications n join public.notification_envois en on en.notification_id = n.id
         where n.colis_id = p_colis and n.canal = 'app'), '[]'::jsonb);
end;
$$;

create or replace function public.regles_notifications()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('reports.view');
  return jsonb_build_object(
    'modifiable', public.peut('settings.manage'),
    'canaux', (select jsonb_object_agg(c, public.canal_configure(c))
                 from unnest(array['push', 'email', 'whatsapp', 'sms']) c),
    'regles', (select jsonb_agg(jsonb_build_object(
                 'type', r.type, 'libelle', r.libelle, 'evenement', r.evenement, 'categorie', r.categorie,
                 'priorite', r.priorite, 'canaux', r.canaux, 'sensible', r.sensible, 'actif', r.actif,
                 'maj_le', r.maj_le) order by r.source, r.type)
               from public.notification_regles r));
end;
$$;

create or replace function public.modifier_regle_notification(p_type text, p_actif boolean, p_canaux text[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_avant public.notification_regles;
begin
  perform public.exiger_permission('settings.manage');
  select * into v_avant from public.notification_regles where type = p_type for update;
  if not found then
    perform public.erreur_metier('RULE_NOT_FOUND', 'Règle de notification inconnue.');
  end if;
  if p_actif is null or p_canaux is null
     or not (p_canaux <@ array['push', 'email', 'whatsapp', 'sms']::text[]) then
    perform public.erreur_metier('INVALID_RULE', 'Canaux de notification inconnus.');
  end if;
  update public.notification_regles
     set actif = p_actif, canaux = (select coalesce(array_agg(distinct c order by c), '{}') from unnest(p_canaux) c),
         maj_le = now(), maj_par = auth.uid()
   where type = p_type;
  perform public.auditer('notification.regle', 'notification_regle', p_type,
                         jsonb_build_object('actif', v_avant.actif, 'canaux', v_avant.canaux),
                         jsonb_build_object('actif', p_actif, 'canaux', p_canaux));
end;
$$;

-- Un essai, vers le compte de l'administrateur lui-même et nul autre ; une fois
-- par minute au plus (la clé d'idempotence porte la minute) ; journalisé.
create or replace function public.tester_notification(p_canal text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_moi uuid := auth.uid();
  v_id bigint;
begin
  perform public.exiger_permission('settings.manage');
  if p_canal not in ('push', 'email', 'whatsapp', 'sms') then
    perform public.erreur_metier('INVALID_CHANNEL', 'Canal inconnu.');
  end if;
  v_id := public.creer_notification('test', v_moi, 'test:' || v_moi || ':' || p_canal || ':' ||
                                    to_char(now() at time zone 'UTC', 'YYYYMMDDHH24MI'),
                                    null, null, null, null, '{}'::jsonb, array[p_canal]);
  if v_id is null then
    perform public.erreur_metier('TOO_MANY_TESTS', 'Un essai par minute au plus.');
  end if;
  perform public.auditer('notification.test', 'notification', v_id::text, null, jsonb_build_object('canal', p_canal));
  return public.suivi_notification(v_id);
end;
$$;


-- 13. Les messages récents de mon_resume (voir supabase-tableau-de-bord.sql) -------
-- Les versions installées de l'application affichent ces messages sur l'accueil :
-- les anciens envois, puis ceux du moteur qui sont vraiment partis, sous la même
-- forme qu'avant (canal, étape du colis, date, numéro).

create or replace function public.messages_recents(p_client uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('canal', m.canal, 'evenement', m.evenement,
                                               'envoye_le', m.envoye_le, 'numero', m.numero)
                            order by m.envoye_le desc), '[]'::jsonb)
  from (select x.* from (
          select n1.canal, n1.evenement, n1.envoye_le, co.numero
            from public.notifications n1 left join public.colis co on co.id = n1.colis_id
           where n1.client_id = p_client and n1.canal <> 'app'
          union all
          select n2.canal, n2.evenement, n2.envoye_le, co.numero
            from public.colis co join public.notifications n2 on n2.colis_id = co.id
           where co.client_id = p_client and n2.client_id is distinct from p_client and n2.canal <> 'app'
          union all
          (select distinct on (n3.id, en.canal) en.canal, coalesce(n3.donnees ->> 'statut', n3.type), en.envoye_le,
                  n3.donnees ->> 'numero'
             from public.notifications n3 join public.notification_envois en on en.notification_id = n3.id
            where n3.client_id = p_client and n3.canal = 'app' and en.statut in ('envoye', 'livre')
            order by n3.id, en.canal, en.envoye_le)) x
        order by x.envoye_le desc limit 10) m
$$;


-- 14. Droits ----------------------------------------------------------------------
-- Rien de ce qui envoie n'est ouvert aux pages : ni creer_notification, ni le
-- travailleur, ni les fournisseurs. Un client ne peut que lire les siennes, les
-- marquer lues et régler ses canaux.

revoke execute on function public.canal_configure(text) from public, anon, authenticated;
revoke execute on function public.planifier_envois(bigint, uuid, text, text, text, text[]) from public, anon, authenticated;
revoke execute on function public.creer_notification(text, uuid, text, uuid, uuid, uuid, bigint, jsonb, text[]) from public, anon, authenticated;
revoke execute on function public.notifier_etape_colis() from public, anon, authenticated;
revoke execute on function public.notifier_evenement_facturation() from public, anon, authenticated;
revoke execute on function public.notifications_quotidiennes() from public, anon, authenticated;
revoke execute on function public.expedier_envoi(public.notification_envois) from public, anon, authenticated;
revoke execute on function public.lire_reponse_envoi(public.notification_envois, integer, text, text) from public, anon, authenticated;
revoke execute on function public.traiter_notifications(integer) from public, anon, authenticated;
revoke execute on function public.messages_recents(uuid) from public, anon, authenticated;

revoke execute on function public.mes_notifications(text, integer, integer, text) from public, anon;
revoke execute on function public.notifications_non_lues() from public, anon;
revoke execute on function public.marquer_notifications_lues(bigint[]) from public, anon;
revoke execute on function public.mes_preferences_notifications() from public, anon;
revoke execute on function public.regler_preference_notification(text, text, boolean) from public, anon;
revoke execute on function public.centre_notifications(timestamptz, timestamptz, text, text, text, integer, integer) from public, anon;
revoke execute on function public.suivi_notification(bigint) from public, anon;
revoke execute on function public.envois_colis(uuid) from public, anon;
revoke execute on function public.regles_notifications() from public, anon;
revoke execute on function public.modifier_regle_notification(text, boolean, text[]) from public, anon;
revoke execute on function public.tester_notification(text) from public, anon;

grant execute on function public.mes_notifications(text, integer, integer, text) to authenticated;
grant execute on function public.notifications_non_lues() to authenticated;
grant execute on function public.marquer_notifications_lues(bigint[]) to authenticated;
grant execute on function public.mes_preferences_notifications() to authenticated;
grant execute on function public.regler_preference_notification(text, text, boolean) to authenticated;
grant execute on function public.centre_notifications(timestamptz, timestamptz, text, text, text, integer, integer) to authenticated;
grant execute on function public.suivi_notification(bigint) to authenticated;
grant execute on function public.envois_colis(uuid) to authenticated;
grant execute on function public.regles_notifications() to authenticated;
grant execute on function public.modifier_regle_notification(text, boolean, text[]) to authenticated;
grant execute on function public.tester_notification(text) to authenticated;

-- Une page ne choisit plus le contenu d'un e-mail ou d'un WhatsApp : ces deux
-- fonctions prenaient le HTML et le modèle envoyés par le tableau de bord. Le
-- moteur les remplace ; elles restent pour le SQL Editor.
revoke execute on function public.envoyer_email_client(uuid, text, text, text, text) from authenticated;
revoke execute on function public.envoyer_whatsapp_client(uuid, text, text, text, jsonb) from authenticated;


-- 15. Le planificateur (pg_cron) -----------------------------------------------------
-- Chaque minute, le travailleur ; chaque matin à 7 h 15 (Santo Domingo), les
-- rappels et la conservation. Sans pg_cron (Database > Extensions > pg_cron), rien
-- ne part : les envois attendent, sans se perdre. Voir docs/notifications.md.

do $cron$
begin
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise notice 'pg_cron indisponible (%). Activez-le : Database > Extensions > pg_cron, puis relancez ce fichier.', sqlerrm;
  end;
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('goship-notifications', '* * * * *', 'select public.traiter_notifications()');
    perform cron.schedule('goship-notifications-jour', '15 11 * * *', 'select public.notifications_quotidiennes()');
  end if;
end
$cron$;


-- 16. Contrôle ----------------------------------------------------------------------
-- Le résultat attendu, en une ligne :
--   regles 13 | declencheurs 2 | ancien_push 0 | ouvertes_aux_visiteurs false | planificateur 2
select (select count(*) from public.notification_regles) as regles,
       (select count(*) from pg_trigger where tgname in ('notifier_etape_colis', 'notifier_evenement_facturation')) as declencheurs,
       (select count(*) from pg_trigger where tgname = 'pousser_au_changement') as ancien_push,
       exists (select 1 from information_schema.routine_privileges
                where grantee = 'anon' and routine_name in ('mes_notifications', 'creer_notification',
                                                            'traiter_notifications', 'centre_notifications')) as ouvertes_aux_visiteurs,
       (select count(*) from pg_extension where extname = 'pg_cron') * 2 as planificateur;
