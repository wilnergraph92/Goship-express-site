-- =============================================================================
-- Goship Express — les anniversaires : un message chaleureux, le jour même (19/10/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce fichier
-- AJOUTE des tables et des fonctions, et REMPLACE deux fonctions de textes des
-- notifications (rendre_notification, texte_notification) pour qu'elles lisent les
-- modèles modifiables. Il ne change aucune donnée existante, n'envoie aucun message
-- tout seul à l'installation, et peut être relancé autant de fois qu'on veut (les
-- modèles et les réglages déjà modifiés par l'équipe sont gardés).
--
-- Ordre d'installation : après supabase-fidelite.sql (voir outils/migrations.txt).
--
-- Ce que fait ce fichier, sans créer de deuxième système de messages :
--   1. Un travailleur (pg_cron, tous les quarts d'heure) cherche les clients dont c'est
--      l'anniversaire dans le fuseau de l'entreprise (America/Santo_Domingo au départ), et crée,
--      par le moteur de notifications DÉJÀ en place (supabase-notifications.sql), la
--      notification de l'espace client et les envois par canal. Il n'envoie rien lui-même :
--      un envoi garde son statut honnête (en attente, accepté par le fournisseur, échec,
--      annulé parce que le canal n'est pas configuré…) ; « livré » n'est jamais écrit sans
--      réponse du fournisseur.
--   2. Un seul message par client et par année : la clé unique « anniv:<client>:<année> » de la
--      notification ET la ligne unique (client, année) du journal. Deux travailleurs en même
--      temps, un travailleur relancé, une panne puis un rattrapage : un seul message.
--   3. Le prénom vient du profil du client (le premier mot de son nom), jamais d'ailleurs ;
--      le message n'est écrit que s'il y en a un. Aucune date de naissance ne sort de la table
--      profils_naissance dans un message, un journal ou une notification.
--   4. Le message ne promet aucun cadeau, crédit ni réduction tant qu'un avantage d'anniversaire
--      n'est pas configuré ET activé ; alors, et alors seulement, le modèle « avec avantage »
--      est utilisé, et l'avantage est vraiment accordé (GOPOINTS par le registre, autre avantage
--      par la table « recompenses »).
--   5. Un rappel interne, par défaut 7 jours avant : un résumé (« 3 anniversaires dans 7 jours »)
--      pour l'équipe qui a la permission birthdays.view, dans sa liste de notifications et dans le
--      tableau de bord. Le délai se règle (0 = pas de rappel). Un rappel au client lui-même est
--      prévu mais éteint par défaut : aucun message de plus n'est envoyé tant qu'on ne l'allume pas.
--
-- Le programme naît ÉTEINT. L'administrateur l'allume (Programmes > Anniversaires), après avoir
-- vérifié les canaux. Canaux de départ : l'application (notification de l'espace client et téléphone)
-- et l'e-mail ; le canal e-mail n'envoie que si le fournisseur est configuré (docs/notifications.md).
-- WhatsApp n'est pas proposé : il exige un modèle de message approuvé par Meta, qui n'existe pas
-- encore pour les anniversaires (docs/programmes.md, « Ce qui reste à configurer »).
--
-- Un client peut couper les messages d'anniversaire (regler_ma_preference_anniversaire). Il n'y a pas de
-- date de naissance sans son accord : sans date, aucun message.
--
-- Permissions (supabase.sql, permissions_du_role) :
--   birthdays.view    voir les anniversaires, les messages, les erreurs, les rappels et les réglages
--   birthdays.manage  régler l'automatisation, les modèles, l'avantage ; corriger une date (motif)
-- Un employé, un client ou un visiteur est refusé par chaque fonction d'équipe : « clients.view » ne
-- donne jamais accès à une date de naissance.
--
-- Contenu :
--    1. garde
--    2. réglages
--    3. modèles de messages (modifiables) et textes
--    4. le journal, les rappels, la préférence du client
--    5. le jour d'anniversaire (29 février compris)
--    6. le travailleur
--    7. l'équipe : lire
--    8. l'équipe : régler, modèles, correction d'une date
--    9. le client : sa préférence
--   10. planification, droits, contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regprocedure('public.points_attribuer(uuid, text, text, integer)') is null
     or to_regprocedure('public.creer_notification(text, uuid, text, uuid, uuid, uuid, bigint, jsonb, text[])') is null
     or to_regprocedure('public.texte_notification(text, text, jsonb)') is null
     or to_regprocedure('public.rendre_notification(text, jsonb)') is null
     or to_regprocedure('public.canal_configure(text)') is null
     or to_regprocedure('public.valider_date_naissance(text)') is null
     or not ('birthdays.manage' = any (public.permissions_du_role('admin'))) then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt) jusqu''à supabase-fidelite.sql, puis ce fichier.';
  end if;
end;
$garde$;


-- 2. Réglages -------------------------------------------------------------------------
-- Une seule ligne. Éteint au départ ; 7 jours de rappel interne ; 29 février fêté le 28 ;
-- 9 h (heure de l'entreprise) ; un jour de rattrapage si une panne a manqué la veille.
create table if not exists public.anniversaire_reglages (
  id                  boolean primary key default true check (id),
  actif               boolean not null default false,
  actif_depuis        date,                       -- les anniversaires d'avant ne sont jamais rattrapés
  heure_envoi         time not null default '09:00',
  regle_29_fevrier    text not null default 'fev28' check (regle_29_fevrier in ('fev28', 'mars1')),
  rattrapage_jours    integer not null default 1 check (rattrapage_jours between 0 and 7),
  canaux              text[] not null default '{push,email}' check (canaux <@ array['push', 'email']::text[]),
  rappel_admin_jours  integer not null default 7 check (rappel_admin_jours between 0 and 60),
  rappel_client_actif boolean not null default false,
  rappel_client_jours integer not null default 3 check (rappel_client_jours between 1 and 30),
  avantage_actif      boolean not null default false,
  avantage_type       text not null default 'aucun'
                      check (avantage_type in ('aucun', 'gopoints', 'credit_expedition', 'reduction_frais', 'bonus_fixe', 'avantage_colis')),
  avantage_valeur     numeric(10, 2) check (avantage_valeur is null or avantage_valeur >= 0),
  avantage_libelle    text not null default '',
  maj_le              timestamptz not null default now(),
  maj_par             uuid
);
insert into public.anniversaire_reglages (id) values (true) on conflict (id) do nothing;
alter table public.anniversaire_reglages enable row level security;
revoke all on public.anniversaire_reglages from anon, authenticated;


-- 3. Les modèles de messages ---------------------------------------------------------------
-- Séparés de la logique d'envoi : un modèle = un type, une langue, un titre et un message.
-- notification_textes() (fonction figée des notifications de colis et de factures) n'est pas
-- touchée ; texte_notification regarde d'abord ici, puis retombe sur elle. Le modèle d'origine est
-- gardé dans titre_defaut / message_defaut : « restaurer » le remet. Variables permises :
--   {{prenom}}    le prénom du client (premier mot de son nom)
--   {{avantage}}  l'avantage d'anniversaire configuré (modèle « avec avantage » seulement)
--   {{nombre}}, {{jours}}   rappel interne
create table if not exists public.notification_modeles (
  type            text not null,
  langue          text not null check (langue in ('fr', 'en', 'es', 'ht')),
  titre           text not null check (length(titre) between 1 and 120),
  message         text not null check (length(message) between 1 and 1200),
  titre_defaut    text not null,
  message_defaut  text not null,
  maj_le          timestamptz not null default now(),
  maj_par         uuid,
  primary key (type, langue)
);
alter table public.notification_modeles enable row level security;
revoke all on public.notification_modeles from anon, authenticated;

-- Les variables permises, en plus de {{numero}}, {{facture}} et {{montant}} des notifications existantes.
-- Un nom de client ne peut pas y glisser d'autre variable : les accolades sont retirées du prénom
-- avant qu'il n'entre dans une notification (voir le travailleur).
create or replace function public.rendre_notification(p_modele text, p_vars jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select regexp_replace(
           replace(replace(replace(replace(replace(replace(replace(coalesce(p_modele, ''),
             '{{numero}}', coalesce(p_vars ->> 'numero', '')),
             '{{facture}}', coalesce(p_vars ->> 'facture', '')),
             '{{montant}}', coalesce(p_vars ->> 'montant', '')),
             '{{nombre}}', coalesce(p_vars ->> 'nombre', '')),
             '{{jours}}', coalesce(p_vars ->> 'jours', '')),
             '{{avantage}}', coalesce(p_vars ->> 'avantage', '')),
             '{{prenom}}', coalesce(p_vars ->> 'prenom', '')),
           '\{\{[a-z_]*\}\}', '', 'g')
$$;

-- Titre et message d'une notification dans une langue : le modèle de la table s'il y en a un, sinon le
-- texte figé de notification_textes(). Même résultat qu'avant pour tous les types qui existaient.
create or replace function public.texte_notification(p_type text, p_langue text, p_donnees jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_langue text := public.langue_notification(p_langue);
  v_t jsonb;
  v_vars jsonb := coalesce(p_donnees, '{}'::jsonb)
                  || jsonb_build_object('montant', public.montant_notification((p_donnees ->> 'montant_usd')::numeric, v_langue));
begin
  select jsonb_build_object('titre', m.titre, 'message', m.message) into v_t
    from public.notification_modeles m where m.type = p_type and m.langue = v_langue;
  if v_t is null then
    v_t := public.notification_textes() -> p_type -> v_langue;
  end if;
  if v_t is null then
    v_t := jsonb_build_object('titre', 'GoShip Express', 'message', '');
  end if;
  return jsonb_build_object('titre', public.rendre_notification(v_t ->> 'titre', v_vars),
                            'message', public.rendre_notification(v_t ->> 'message', v_vars));
end;
$$;

-- Les modèles de départ. Un modèle déjà là n'est pas touché : l'équipe a pu le modifier (« restaurer » remet celui-ci).
-- Le modèle « birthday » ne promet rien ; « birthday_avantage » n'est utilisé que si un avantage est configuré ET activé.
insert into public.notification_modeles (type, langue, titre, message, titre_defaut, message_defaut) values
  ('birthday', 'fr', '🎉🎂 Joyeux anniversaire, {{prenom}} ! 💙🧡', 'Aujourd''hui est un jour spécial, et toute l''équipe GoShip Express vous envoie beaucoup d''affection et ses plus beaux vœux !
Nous souhaitons que cette nouvelle année vous apporte santé, joie, réussite, prospérité et de belles surprises. Merci de faire confiance à GoShip Express pour vous accompagner dans toutes vos livraisons.
C''est un plaisir de vous compter dans notre communauté. Passez une journée extraordinaire et continuez à réaliser vos beaux rêves !
Avec toute notre affection, l''équipe GoShip Express. 💙🧡🚚', '🎉🎂 Joyeux anniversaire, {{prenom}} ! 💙🧡', 'Aujourd''hui est un jour spécial, et toute l''équipe GoShip Express vous envoie beaucoup d''affection et ses plus beaux vœux !
Nous souhaitons que cette nouvelle année vous apporte santé, joie, réussite, prospérité et de belles surprises. Merci de faire confiance à GoShip Express pour vous accompagner dans toutes vos livraisons.
C''est un plaisir de vous compter dans notre communauté. Passez une journée extraordinaire et continuez à réaliser vos beaux rêves !
Avec toute notre affection, l''équipe GoShip Express. 💙🧡🚚'),
  ('birthday', 'en', '🎉🎂 Happy birthday, {{prenom}}! 💙🧡', 'Today is a special day, and the whole GoShip Express team is sending you lots of love and our very best wishes!
We hope this new year brings you health, joy, success, prosperity and many lovely surprises. Thank you for trusting GoShip Express to be with you in all your deliveries.
It is a pleasure to have you in our community. Have an extraordinary day and keep making your beautiful dreams come true!
With all our affection, the GoShip Express team. 💙🧡🚚', '🎉🎂 Happy birthday, {{prenom}}! 💙🧡', 'Today is a special day, and the whole GoShip Express team is sending you lots of love and our very best wishes!
We hope this new year brings you health, joy, success, prosperity and many lovely surprises. Thank you for trusting GoShip Express to be with you in all your deliveries.
It is a pleasure to have you in our community. Have an extraordinary day and keep making your beautiful dreams come true!
With all our affection, the GoShip Express team. 💙🧡🚚'),
  ('birthday', 'es', '🎉🎂 ¡Feliz cumpleaños, {{prenom}}! 💙🧡', '¡Hoy es un día especial, y todo el equipo de GoShip Express le envía mucho cariño y sus mejores deseos!
Deseamos que este nuevo año le traiga salud, alegría, éxito, prosperidad y muchas bonitas sorpresas. Gracias por confiar en GoShip Express para acompañarle en todas sus entregas.
Es un placer contarle entre nuestra comunidad. ¡Pase un día extraordinario y siga cumpliendo sus hermosos sueños!
Con todo nuestro cariño, el equipo de GoShip Express. 💙🧡🚚', '🎉🎂 ¡Feliz cumpleaños, {{prenom}}! 💙🧡', '¡Hoy es un día especial, y todo el equipo de GoShip Express le envía mucho cariño y sus mejores deseos!
Deseamos que este nuevo año le traiga salud, alegría, éxito, prosperidad y muchas bonitas sorpresas. Gracias por confiar en GoShip Express para acompañarle en todas sus entregas.
Es un placer contarle entre nuestra comunidad. ¡Pase un día extraordinario y siga cumpliendo sus hermosos sueños!
Con todo nuestro cariño, el equipo de GoShip Express. 💙🧡🚚'),
  ('birthday', 'ht', '🎉🎂 Bòn fèt, {{prenom}} ! 💙🧡', 'Jodi a se yon jou espesyal, epi tout ekip GoShip Express ap voye anpil lanmou ak pi bèl swè pou ou!
Nou swete nouvo ane sa a pote sante, lajwa, siksè, pwosperite ak anpil bèl sipriz nan lavi ou. Mèsi paske ou fè GoShip Express konfyans pou akonpaye w nan tout livrezon ou yo.
Se yon plezi pou ou fè pati kominote nou an. Pase yon jounen ekstraòdinè epi kontinye reyalize bèl rèv ou yo!
Avèk anpil afeksyon, ekip GoShip Express. 💙🧡🚚', '🎉🎂 Bòn fèt, {{prenom}} ! 💙🧡', 'Jodi a se yon jou espesyal, epi tout ekip GoShip Express ap voye anpil lanmou ak pi bèl swè pou ou!
Nou swete nouvo ane sa a pote sante, lajwa, siksè, pwosperite ak anpil bèl sipriz nan lavi ou. Mèsi paske ou fè GoShip Express konfyans pou akonpaye w nan tout livrezon ou yo.
Se yon plezi pou ou fè pati kominote nou an. Pase yon jounen ekstraòdinè epi kontinye reyalize bèl rèv ou yo!
Avèk anpil afeksyon, ekip GoShip Express. 💙🧡🚚'),
  ('birthday_avantage', 'fr', '🎉🎂 Joyeux anniversaire, {{prenom}} ! 💙🧡', 'Aujourd''hui est un jour spécial, et toute l''équipe GoShip Express vous envoie beaucoup d''affection et ses plus beaux vœux !
Pour fêter ça, voici votre cadeau : {{avantage}}.
Nous souhaitons que cette nouvelle année vous apporte santé, joie, réussite, prospérité et de belles surprises. Merci de faire confiance à GoShip Express pour vous accompagner dans toutes vos livraisons.
C''est un plaisir de vous compter dans notre communauté. Passez une journée extraordinaire et continuez à réaliser vos beaux rêves !
Avec toute notre affection, l''équipe GoShip Express. 💙🧡🚚', '🎉🎂 Joyeux anniversaire, {{prenom}} ! 💙🧡', 'Aujourd''hui est un jour spécial, et toute l''équipe GoShip Express vous envoie beaucoup d''affection et ses plus beaux vœux !
Pour fêter ça, voici votre cadeau : {{avantage}}.
Nous souhaitons que cette nouvelle année vous apporte santé, joie, réussite, prospérité et de belles surprises. Merci de faire confiance à GoShip Express pour vous accompagner dans toutes vos livraisons.
C''est un plaisir de vous compter dans notre communauté. Passez une journée extraordinaire et continuez à réaliser vos beaux rêves !
Avec toute notre affection, l''équipe GoShip Express. 💙🧡🚚'),
  ('birthday_avantage', 'en', '🎉🎂 Happy birthday, {{prenom}}! 💙🧡', 'Today is a special day, and the whole GoShip Express team is sending you lots of love and our very best wishes!
To celebrate, here is your gift: {{avantage}}.
We hope this new year brings you health, joy, success, prosperity and many lovely surprises. Thank you for trusting GoShip Express to be with you in all your deliveries.
It is a pleasure to have you in our community. Have an extraordinary day and keep making your beautiful dreams come true!
With all our affection, the GoShip Express team. 💙🧡🚚', '🎉🎂 Happy birthday, {{prenom}}! 💙🧡', 'Today is a special day, and the whole GoShip Express team is sending you lots of love and our very best wishes!
To celebrate, here is your gift: {{avantage}}.
We hope this new year brings you health, joy, success, prosperity and many lovely surprises. Thank you for trusting GoShip Express to be with you in all your deliveries.
It is a pleasure to have you in our community. Have an extraordinary day and keep making your beautiful dreams come true!
With all our affection, the GoShip Express team. 💙🧡🚚'),
  ('birthday_avantage', 'es', '🎉🎂 ¡Feliz cumpleaños, {{prenom}}! 💙🧡', '¡Hoy es un día especial, y todo el equipo de GoShip Express le envía mucho cariño y sus mejores deseos!
Para celebrarlo, este es su regalo: {{avantage}}.
Deseamos que este nuevo año le traiga salud, alegría, éxito, prosperidad y muchas bonitas sorpresas. Gracias por confiar en GoShip Express para acompañarle en todas sus entregas.
Es un placer contarle entre nuestra comunidad. ¡Pase un día extraordinario y siga cumpliendo sus hermosos sueños!
Con todo nuestro cariño, el equipo de GoShip Express. 💙🧡🚚', '🎉🎂 ¡Feliz cumpleaños, {{prenom}}! 💙🧡', '¡Hoy es un día especial, y todo el equipo de GoShip Express le envía mucho cariño y sus mejores deseos!
Para celebrarlo, este es su regalo: {{avantage}}.
Deseamos que este nuevo año le traiga salud, alegría, éxito, prosperidad y muchas bonitas sorpresas. Gracias por confiar en GoShip Express para acompañarle en todas sus entregas.
Es un placer contarle entre nuestra comunidad. ¡Pase un día extraordinario y siga cumpliendo sus hermosos sueños!
Con todo nuestro cariño, el equipo de GoShip Express. 💙🧡🚚'),
  ('birthday_avantage', 'ht', '🎉🎂 Bòn fèt, {{prenom}} ! 💙🧡', 'Jodi a se yon jou espesyal, epi tout ekip GoShip Express ap voye anpil lanmou ak pi bèl swè pou ou!
Pou n selebre sa, men kado ou : {{avantage}}.
Nou swete nouvo ane sa a pote sante, lajwa, siksè, pwosperite ak anpil bèl sipriz nan lavi ou. Mèsi paske ou fè GoShip Express konfyans pou akonpaye w nan tout livrezon ou yo.
Se yon plezi pou ou fè pati kominote nou an. Pase yon jounen ekstraòdinè epi kontinye reyalize bèl rèv ou yo!
Avèk anpil afeksyon, ekip GoShip Express. 💙🧡🚚', '🎉🎂 Bòn fèt, {{prenom}} ! 💙🧡', 'Jodi a se yon jou espesyal, epi tout ekip GoShip Express ap voye anpil lanmou ak pi bèl swè pou ou!
Pou n selebre sa, men kado ou : {{avantage}}.
Nou swete nouvo ane sa a pote sante, lajwa, siksè, pwosperite ak anpil bèl sipriz nan lavi ou. Mèsi paske ou fè GoShip Express konfyans pou akonpaye w nan tout livrezon ou yo.
Se yon plezi pou ou fè pati kominote nou an. Pase yon jounen ekstraòdinè epi kontinye reyalize bèl rèv ou yo!
Avèk anpil afeksyon, ekip GoShip Express. 💙🧡🚚'),
  ('birthday_upcoming', 'fr', '🎂 Votre anniversaire approche, {{prenom}} !', 'Dans {{jours}} jour(s), toute l''équipe GoShip Express vous souhaitera un joyeux anniversaire. 💙🧡', '🎂 Votre anniversaire approche, {{prenom}} !', 'Dans {{jours}} jour(s), toute l''équipe GoShip Express vous souhaitera un joyeux anniversaire. 💙🧡'),
  ('birthday_upcoming', 'en', '🎂 Your birthday is coming, {{prenom}}!', 'In {{jours}} day(s), the whole GoShip Express team will wish you a happy birthday. 💙🧡', '🎂 Your birthday is coming, {{prenom}}!', 'In {{jours}} day(s), the whole GoShip Express team will wish you a happy birthday. 💙🧡'),
  ('birthday_upcoming', 'es', '🎂 ¡Se acerca su cumpleaños, {{prenom}}!', 'Dentro de {{jours}} día(s), todo el equipo de GoShip Express le deseará un feliz cumpleaños. 💙🧡', '🎂 ¡Se acerca su cumpleaños, {{prenom}}!', 'Dentro de {{jours}} día(s), todo el equipo de GoShip Express le deseará un feliz cumpleaños. 💙🧡'),
  ('birthday_upcoming', 'ht', '🎂 Fèt ou ap pwoche, {{prenom}} !', 'Nan {{jours}} jou, tout ekip GoShip Express ap swete w bòn fèt. 💙🧡', '🎂 Fèt ou ap pwoche, {{prenom}} !', 'Nan {{jours}} jou, tout ekip GoShip Express ap swete w bòn fèt. 💙🧡'),
  ('birthday_reminder', 'fr', 'Anniversaires à venir', '{{nombre}} client(s) fêteront leur anniversaire dans {{jours}} jour(s). Ouvrez Programmes > Anniversaires pour préparer vos offres.', 'Anniversaires à venir', '{{nombre}} client(s) fêteront leur anniversaire dans {{jours}} jour(s). Ouvrez Programmes > Anniversaires pour préparer vos offres.'),
  ('birthday_reminder', 'en', 'Upcoming birthdays', '{{nombre}} customer(s) will celebrate a birthday in {{jours}} day(s). Open Programs > Birthdays to prepare your offers.', 'Upcoming birthdays', '{{nombre}} customer(s) will celebrate a birthday in {{jours}} day(s). Open Programs > Birthdays to prepare your offers.'),
  ('birthday_reminder', 'es', 'Próximos cumpleaños', '{{nombre}} cliente(s) cumplirán años dentro de {{jours}} día(s). Abra Programas > Cumpleaños para preparar sus ofertas.', 'Próximos cumpleaños', '{{nombre}} cliente(s) cumplirán años dentro de {{jours}} día(s). Abra Programas > Cumpleaños para preparar sus ofertas.'),
  ('birthday_reminder', 'ht', 'Fèt k ap vini', '{{nombre}} kliyan ap fete fèt yo nan {{jours}} jou. Louvri Pwogram > Fèt pou prepare òf ou yo.', 'Fèt k ap vini', '{{nombre}} kliyan ap fete fèt yo nan {{jours}} jou. Louvri Pwogram > Fèt pou prepare òf ou yo.')
on conflict (type, langue) do nothing;


-- 4. Le journal, les rappels, la préférence du client -------------------------------------------
-- Une ligne par client et par année : la trace de ce que le programme a fait (ou décidé de ne pas
-- faire, avec la raison). C'est aussi le verrou contre le doublon. L'état de livraison, lui, se lit
-- sur les envois de la notification (notification_envois) : jamais recopié ici.
--   prepare  la notification et ses envois ont été créés
--   ignore   pas de message, et pourquoi (motif : SANS_PRENOM, DESACTIVE_PAR_CLIENT)
--   erreur   la préparation a échoué (motif : le code de l'erreur) ; l'équipe la voit, rien n'est perdu
create table if not exists public.anniversaire_journal (
  id               bigint generated always as identity primary key,
  client_id        uuid not null references public.clients (id),
  annee            integer not null,
  anniversaire_le  date not null,
  statut           text not null check (statut in ('prepare', 'ignore', 'erreur')),
  motif            text not null default '',
  notification_id  bigint,
  cree_le          timestamptz not null default now(),
  unique (client_id, annee)
);
create index if not exists anniversaire_journal_date_idx on public.anniversaire_journal (anniversaire_le desc);
alter table public.anniversaire_journal enable row level security;
revoke all on public.anniversaire_journal from anon, authenticated;

-- Les rappels internes préparés (un par client et par année) : « dans 7 jours, c'est l'anniversaire de… »
create table if not exists public.anniversaire_rappels (
  id               bigint generated always as identity primary key,
  client_id        uuid not null references public.clients (id),
  annee            integer not null,
  anniversaire_le  date not null,
  prepare_le       date not null,
  cree_le          timestamptz not null default now(),
  unique (client_id, annee)
);
alter table public.anniversaire_rappels enable row level security;
revoke all on public.anniversaire_rappels from anon, authenticated;

-- Ce que le client accepte de recevoir de ces programmes. Une ligne seulement quand il coupe.
create table if not exists public.programme_preferences (
  client_id   uuid primary key references public.clients (id),
  anniversaire boolean not null default true,
  maj_le      timestamptz not null default now()
);
alter table public.programme_preferences enable row level security;
revoke all on public.programme_preferences from anon, authenticated;


-- 5. Le jour d'anniversaire ------------------------------------------------------------------
-- Le jour où un client né le p_naissance fête son anniversaire l'année p_annee. Né un 29 février,
-- il le fête le 28 février ou le 1er mars les années non bissextiles, selon le réglage.
create or replace function public.anniversaire_en(p_naissance date, p_annee integer, p_regle text default 'fev28')
returns date
language sql
immutable
set search_path = ''
as $$
  select case
    when extract(month from p_naissance) = 2 and extract(day from p_naissance) = 29
         and not ((p_annee % 4 = 0 and p_annee % 100 <> 0) or p_annee % 400 = 0)
      then case when p_regle = 'mars1' then make_date(p_annee, 3, 1) else make_date(p_annee, 2, 28) end
    else make_date(p_annee, extract(month from p_naissance)::integer, extract(day from p_naissance)::integer)
  end
$$;

-- Le prénom : le premier mot du nom, sans accolades (aucune variable ne peut s'y glisser), 40 signes au plus
create or replace function public.prenom_client(p_nom text)
returns text
language sql
immutable
set search_path = ''
as $$
  select left(regexp_replace(split_part(trim(coalesce(p_nom, '')), ' ', 1), '[{}<>]', '', 'g'), 40)
$$;


-- 6. Le travailleur --------------------------------------------------------------------------------
-- Prépare le message d'anniversaire d'UN client. Rend le statut du journal. Tout ce qui peut échouer est
-- attrapé : une erreur sur un client n'empêche pas les autres, elle est journalisée.
create or replace function public.anniversaire_traiter(p_client uuid, p_jour date, p_regles public.anniversaire_reglages)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_annee integer := extract(year from p_jour)::integer;
  v_nom text;
  v_prenom text;
  v_cle text := 'anniv:' || p_client || ':' || extract(year from p_jour)::integer;
  v_type text := 'birthday';
  v_avantage text := '';
  v_points integer;
  v_donnees jsonb;
  v_notification bigint;
  v_statut text := 'prepare';
  v_motif text := '';
begin
  select nom_complet into v_nom from public.clients where id = p_client;
  v_prenom := public.prenom_client(v_nom);

  if exists (select 1 from public.programme_preferences where client_id = p_client and not anniversaire) then
    v_statut := 'ignore'; v_motif := 'DESACTIVE_PAR_CLIENT';
  elsif v_prenom = '' then
    v_statut := 'ignore'; v_motif := 'SANS_PRENOM';
  else
    -- L'avantage n'est annoncé que s'il est vraiment accordé : réglé, activé, et valable
    if p_regles.avantage_actif and p_regles.avantage_type = 'gopoints' then
      select r.points into v_points from public.points_regles r
        join public.points_reglages g on g.id
       where r.evenement = 'birthday' and r.actif and g.actif;
      if v_points is not null then
        v_avantage := v_points || ' GOPOINTS';
      end if;
    elsif p_regles.avantage_actif and p_regles.avantage_type <> 'aucun'
          and coalesce(p_regles.avantage_valeur, 0) > 0 and length(trim(p_regles.avantage_libelle)) > 0 then
      v_avantage := trim(p_regles.avantage_libelle);
    end if;
    if v_avantage <> '' then
      v_type := 'birthday_avantage';
    end if;
    v_donnees := jsonb_build_object('prenom', v_prenom, 'avantage', left(regexp_replace(v_avantage, '[{}]', '', 'g'), 120));

    v_notification := public.creer_notification(v_type, p_client, v_cle, null, null, null, null, v_donnees,
                                                p_regles.canaux);
    if v_notification is null then
      -- La clé existait déjà : un message est déjà parti pour cette année. Aucun doublon, aucun avantage de plus.
      v_statut := 'prepare'; v_motif := 'DEJA_PREPARE';
    elsif v_avantage <> '' then
      if p_regles.avantage_type = 'gopoints' then
        perform public.points_attribuer(p_client, 'birthday', 'anniv:' || v_annee);
      else
        insert into public.recompenses (client_id, programme, type, valeur, statut, cle, campagne, reference)
        values (p_client, 'anniversaire', p_regles.avantage_type, p_regles.avantage_valeur, 'obtenue',
                'anniv:' || p_client || ':' || v_annee, 'anniversaire', 'annee:' || v_annee)
        on conflict (cle) do nothing;
      end if;
    end if;
  end if;

  insert into public.anniversaire_journal (client_id, annee, anniversaire_le, statut, motif, notification_id)
  values (p_client, v_annee, p_jour, v_statut, v_motif, v_notification)
  on conflict (client_id, annee) do nothing;
  return v_statut;
end;
$$;

-- Le travailleur. Appelé par pg_cron tous les quarts d'heure ; relançable à volonté (il ne refait rien).
-- p_maintenant : l'instant à considérer (les essais le déplacent ; en production, now()).
create or replace function public.anniversaires_executer(p_maintenant timestamptz default now())
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.anniversaire_reglages;
  v_fuseau text;
  v_local timestamp;
  v_jour date;
  v_cible date;
  v_jour_k date;
  c record;
  s record;
  v_statut text;
  v_prepares integer := 0;
  v_ignores integer := 0;
  v_erreurs integer := 0;
  v_rappels integer := 0;
  v_digests integer := 0;
  v_clients integer := 0;
begin
  if not pg_try_advisory_xact_lock(hashtext('goship-anniversaires')) then
    return jsonb_build_object('occupe', true);
  end if;
  select * into r from public.anniversaire_reglages where id;
  if not r.actif then
    return jsonb_build_object('actif', false);
  end if;
  select fuseau into v_fuseau from public.programme_reglages where id;
  begin
    v_local := p_maintenant at time zone coalesce(v_fuseau, 'America/Santo_Domingo');
  exception when others then
    v_local := p_maintenant at time zone 'America/Santo_Domingo';
  end;
  v_jour := v_local::date;

  -- Pas avant l'heure d'envoi du jour. Les jours de rattrapage (une panne a manqué la veille) n'attendent pas.
  for k in 0..r.rattrapage_jours loop
    v_jour_k := v_jour - (r.rattrapage_jours - k);
    if v_jour_k < coalesce(r.actif_depuis, v_jour) then
      continue;   -- les anniversaires d'avant l'activation ne sont jamais rattrapés
    end if;
    if v_jour_k = v_jour and v_local::time < r.heure_envoi then
      continue;
    end if;
    for c in
      select cl.id from public.clients cl
        join public.profils_naissance n on n.client_id = cl.id
       where cl.role = 'client' and cl.supprime_le is null
         and public.anniversaire_en(n.date_naissance, extract(year from v_jour_k)::integer, r.regle_29_fevrier) = v_jour_k
         and not exists (select 1 from public.anniversaire_journal j
                          where j.client_id = cl.id and j.annee = extract(year from v_jour_k)::integer)
       order by cl.id
    loop
      v_clients := v_clients + 1;
      begin
        v_statut := public.anniversaire_traiter(c.id, v_jour_k, r);
        if v_statut = 'ignore' then v_ignores := v_ignores + 1; else v_prepares := v_prepares + 1; end if;
      exception when others then
        -- Une erreur sur un client : journalisée (sans donnée personnelle), les autres continuent
        insert into public.anniversaire_journal (client_id, annee, anniversaire_le, statut, motif)
        values (c.id, extract(year from v_jour_k)::integer, v_jour_k, 'erreur', left(coalesce(sqlerrm, 'ERREUR'), 120))
        on conflict (client_id, annee) do nothing;
        v_erreurs := v_erreurs + 1;
      end;
    end loop;
  end loop;

  -- Le rappel interne : « dans N jours, X anniversaires » pour ceux qui peuvent voir les anniversaires
  if r.rappel_admin_jours > 0 and v_local::time >= r.heure_envoi then
    v_cible := v_jour + r.rappel_admin_jours;
    insert into public.anniversaire_rappels (client_id, annee, anniversaire_le, prepare_le)
    select cl.id, extract(year from v_cible)::integer, v_cible, v_jour
      from public.clients cl join public.profils_naissance n on n.client_id = cl.id
     where cl.role = 'client' and cl.supprime_le is null
       and public.anniversaire_en(n.date_naissance, extract(year from v_cible)::integer, r.regle_29_fevrier) = v_cible
    on conflict (client_id, annee) do nothing;
    get diagnostics v_rappels = row_count;
    if exists (select 1 from public.anniversaire_rappels where anniversaire_le = v_cible) then
      for s in select cl.id from public.clients cl
                where cl.role <> 'client' and 'birthdays.view' = any (public.permissions_du_role(cl.role)) loop
        if public.creer_notification('birthday_reminder', s.id, 'anniv-rappel:' || v_cible || ':' || s.id, null, null, null, null,
             jsonb_build_object('nombre', (select count(*) from public.anniversaire_rappels where anniversaire_le = v_cible),
                                'jours', r.rappel_admin_jours),
             '{}'::text[]) is not null then
          v_digests := v_digests + 1;
        end if;
      end loop;
    end if;
  end if;

  -- Le rappel au client lui-même : éteint tant qu'on ne l'allume pas
  if r.rappel_client_actif and v_local::time >= r.heure_envoi then
    v_cible := v_jour + r.rappel_client_jours;
    for c in
      select cl.id, public.prenom_client(cl.nom_complet) as prenom
        from public.clients cl join public.profils_naissance n on n.client_id = cl.id
       where cl.role = 'client' and cl.supprime_le is null
         and public.anniversaire_en(n.date_naissance, extract(year from v_cible)::integer, r.regle_29_fevrier) = v_cible
         and not exists (select 1 from public.programme_preferences p where p.client_id = cl.id and not p.anniversaire)
    loop
      if c.prenom <> '' then
        perform public.creer_notification('birthday_upcoming', c.id, 'anniv-avant:' || c.id || ':' || extract(year from v_cible)::integer,
                                          null, null, null, null,
                                          jsonb_build_object('prenom', c.prenom, 'jours', r.rappel_client_jours), r.canaux);
      end if;
    end loop;
  end if;

  return jsonb_build_object('actif', true, 'jour', v_jour, 'clients', v_clients, 'prepares', v_prepares,
                            'ignores', v_ignores, 'erreurs', v_erreurs, 'rappels', v_rappels, 'resumes', v_digests);
end;
$$;


-- 7. L'équipe : lire -------------------------------------------------------------------------------
-- Les anniversaires d'une période (jours de l'entreprise, 366 jours au plus), avec l'état du message.
-- La date de naissance complète ne sort pas : le jour d'anniversaire et l'âge atteint.
create or replace function public.anniversaires_liste(p_debut date default null, p_fin date default null,
                                                      p_page integer default 0, p_par_page integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  r public.anniversaire_reglages;
  v_debut date;
  v_fin date;
  v_par_page integer := least(greatest(coalesce(p_par_page, 50), 1), 200);
  v_page integer := greatest(coalesce(p_page, 0), 0);
begin
  perform public.exiger_permission('birthdays.view');
  select * into r from public.anniversaire_reglages where id;
  v_debut := coalesce(p_debut, public.aujourdhui_entreprise());
  v_fin := coalesce(p_fin, v_debut);
  if v_fin < v_debut or v_fin - v_debut > 365 then
    perform public.erreur_metier('INVALID_PERIOD', 'La période doit aller d''un jour à un an au plus.');
  end if;
  return (
    with jours as (select d::date as jour from generate_series(v_debut, v_fin, interval '1 day') d),
    lignes as (
      select j.jour, cl.id as client_id, cl.code, cl.nom_complet,
             extract(year from j.jour)::integer - extract(year from n.date_naissance)::integer as age,
             jn.statut, jn.motif, jn.notification_id
        from jours j
        join public.profils_naissance n
          on public.anniversaire_en(n.date_naissance, extract(year from j.jour)::integer, r.regle_29_fevrier) = j.jour
        join public.clients cl on cl.id = n.client_id and cl.role = 'client' and cl.supprime_le is null
        left join public.anniversaire_journal jn on jn.client_id = cl.id and jn.annee = extract(year from j.jour)::integer)
    select jsonb_build_object(
      'du', v_debut, 'au', v_fin,
      'total', (select count(*) from lignes),
      'elements', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'client_id', l.client_id, 'code', l.code, 'nom', l.nom_complet, 'date', l.jour, 'age', l.age,
                 'statut', coalesce(l.statut, 'a_venir'), 'motif', l.motif,
                 'envois', coalesce((select jsonb_agg(jsonb_build_object('canal', e.canal, 'statut', e.statut, 'code_erreur', e.code_erreur) order by e.canal)
                                       from public.notification_envois e where e.notification_id = l.notification_id), '[]'::jsonb))
               order by l.jour, l.nom_complet)
          from (select * from lignes order by jour, nom_complet limit v_par_page offset v_page * v_par_page) l), '[]'::jsonb)));
end;
$$;

-- Les messages préparés et leur état de livraison, canal par canal
create or replace function public.anniversaires_messages(p_statut text default '', p_debut date default null, p_fin date default null,
                                                         p_page integer default 0, p_par_page integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_par_page integer := least(greatest(coalesce(p_par_page, 50), 1), 200);
  v_page integer := greatest(coalesce(p_page, 0), 0);
begin
  perform public.exiger_permission('birthdays.view');
  if coalesce(p_statut, '') not in ('', 'prepare', 'ignore', 'erreur') then
    perform public.erreur_metier('INVALID_FILTER', 'Filtre inconnu.');
  end if;
  return (
    with lignes as (
      select jn.*, cl.code, cl.nom_complet
        from public.anniversaire_journal jn join public.clients cl on cl.id = jn.client_id
       where (coalesce(p_statut, '') = '' or jn.statut = p_statut)
         and (p_debut is null or jn.anniversaire_le >= p_debut) and (p_fin is null or jn.anniversaire_le <= p_fin))
    select jsonb_build_object(
      'total', (select count(*) from lignes),
      'elements', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', l.id, 'client_id', l.client_id, 'code', l.code, 'nom', l.nom_complet, 'date', l.anniversaire_le,
                 'statut', l.statut, 'motif', l.motif, 'prepare_le', l.cree_le,
                 'envois', coalesce((select jsonb_agg(jsonb_build_object(
                                       'canal', e.canal, 'statut', e.statut, 'tentative', e.tentative,
                                       'code_erreur', e.code_erreur, 'envoye_le', e.envoye_le, 'livre_le', e.livre_le) order by e.canal)
                                       from public.notification_envois e where e.notification_id = l.notification_id), '[]'::jsonb))
               order by l.cree_le desc, l.id desc)
          from (select * from lignes order by cree_le desc, id desc limit v_par_page offset v_page * v_par_page) l), '[]'::jsonb)));
end;
$$;

-- Les erreurs : une préparation qui a échoué, un envoi refusé par le fournisseur, un envoi jamais parti
-- (canal non configuré, pas d'adresse…). Rien n'est caché derrière un « envoyé ».
create or replace function public.anniversaires_erreurs(p_page integer default 0, p_par_page integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_par_page integer := least(greatest(coalesce(p_par_page, 50), 1), 200);
  v_page integer := greatest(coalesce(p_page, 0), 0);
begin
  perform public.exiger_permission('birthdays.view');
  return (
    with erreurs as (
      select jn.cree_le as quand, cl.code, cl.nom_complet as nom, 'preparation' as origine, 'erreur' as statut,
             jn.motif as code_erreur, null::text as canal
        from public.anniversaire_journal jn join public.clients cl on cl.id = jn.client_id where jn.statut = 'erreur'
      union all
      select e.maj_le, cl.code, cl.nom_complet, 'envoi', e.statut, coalesce(e.code_erreur, ''), e.canal
        from public.notification_envois e
        join public.notifications n on n.id = e.notification_id and n.type in ('birthday', 'birthday_avantage', 'birthday_upcoming')
        join public.clients cl on cl.id = n.client_id
       where e.statut in ('echec', 'annule'))
    select jsonb_build_object(
      'total', (select count(*) from erreurs),
      'elements', coalesce((
        select jsonb_agg(jsonb_build_object('date', x.quand, 'code', x.code, 'nom', x.nom, 'origine', x.origine, 'statut', x.statut,
                                            'code_erreur', x.code_erreur, 'canal', x.canal) order by x.quand desc)
          from (select * from erreurs order by quand desc limit v_par_page offset v_page * v_par_page) x), '[]'::jsonb)));
end;
$$;

-- Les rappels préparés pour l'équipe
create or replace function public.anniversaires_rappels_liste(p_page integer default 0, p_par_page integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_par_page integer := least(greatest(coalesce(p_par_page, 50), 1), 200);
  v_page integer := greatest(coalesce(p_page, 0), 0);
begin
  perform public.exiger_permission('birthdays.view');
  return jsonb_build_object(
    'total', (select count(*) from public.anniversaire_rappels where anniversaire_le >= public.aujourdhui_entreprise()),
    'elements', coalesce((
      select jsonb_agg(jsonb_build_object('client_id', x.client_id, 'code', x.code, 'nom', x.nom_complet, 'date', x.anniversaire_le,
                                          'prepare_le', x.prepare_le) order by x.anniversaire_le, x.nom_complet)
        from (select ra.*, cl.code, cl.nom_complet from public.anniversaire_rappels ra join public.clients cl on cl.id = ra.client_id
               where ra.anniversaire_le >= public.aujourdhui_entreprise()
               order by ra.anniversaire_le, cl.nom_complet limit v_par_page offset v_page * v_par_page) x), '[]'::jsonb));
end;
$$;

-- Les réglages, l'état des canaux (« oui / non » : jamais une clé) et quelques chiffres
create or replace function public.anniversaire_reglages_lire()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  r public.anniversaire_reglages;
  v_jour date := public.aujourdhui_entreprise();
begin
  perform public.exiger_permission('birthdays.view');
  select * into r from public.anniversaire_reglages where id;
  return jsonb_build_object(
    'reglages', to_jsonb(r) - 'maj_par' || jsonb_build_object('fuseau', (select fuseau from public.programme_reglages where id),
                                                               'heure_envoi', to_char(r.heure_envoi, 'HH24:MI')),
    'canaux_configures', jsonb_build_object('push', public.canal_configure('push'), 'email', public.canal_configure('email'),
                                            'whatsapp', public.canal_configure('whatsapp')),
    'whatsapp_disponible', false,
    'chiffres', jsonb_build_object(
      'aujourdhui', (select count(*) from public.profils_naissance n join public.clients cl on cl.id = n.client_id
                      where cl.role = 'client' and cl.supprime_le is null
                        and public.anniversaire_en(n.date_naissance, extract(year from v_jour)::integer, r.regle_29_fevrier) = v_jour),
      'sept_jours', (select count(*) from public.profils_naissance n join public.clients cl on cl.id = n.client_id
                      where cl.role = 'client' and cl.supprime_le is null
                        and public.anniversaire_en(n.date_naissance, extract(year from v_jour + 7)::integer, r.regle_29_fevrier) = v_jour + 7),
      'clients_avec_date', (select count(*) from public.profils_naissance n join public.clients cl on cl.id = n.client_id where cl.role = 'client' and cl.supprime_le is null),
      'clients_sans_date', (select count(*) from public.clients cl where cl.role = 'client' and cl.supprime_le is null
                             and not exists (select 1 from public.profils_naissance n where n.client_id = cl.id)),
      'messages_annee', (select count(*) from public.anniversaire_journal where statut = 'prepare' and annee = extract(year from v_jour)::integer),
      'erreurs', (select count(*) from public.anniversaire_journal where statut = 'erreur')));
end;
$$;

create or replace function public.anniversaire_modeles_liste()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('birthdays.view');
  return coalesce((select jsonb_agg(jsonb_build_object('type', m.type, 'langue', m.langue, 'titre', m.titre, 'message', m.message,
                                                       'modifie', (m.titre <> m.titre_defaut or m.message <> m.message_defaut))
                                    order by m.type, m.langue)
                     from public.notification_modeles m where m.type in ('birthday', 'birthday_avantage', 'birthday_upcoming', 'birthday_reminder')),
                  '[]'::jsonb);
end;
$$;


-- 8. L'équipe : régler ---------------------------------------------------------------------------------
create or replace function public.anniversaire_reglages_modifier(p_donnees jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  d jsonb := coalesce(p_donnees, '{}'::jsonb);
  avant public.anniversaire_reglages;
  apres public.anniversaire_reglages;
  v_actif boolean;
  v_heure time;
  v_canaux text[];
  v_fuseau text;
  v_type text;
  v_avantage_actif boolean;
  v_valeur numeric;
  v_libelle text;
begin
  perform public.exiger_permission('birthdays.manage');
  select * into avant from public.anniversaire_reglages where id for update;

  v_actif := case when d ? 'actif' then (d ->> 'actif')::boolean else avant.actif end;
  begin
    v_heure := case when d ? 'heure_envoi' then (d ->> 'heure_envoi')::time else avant.heure_envoi end;
  exception when others then
    perform public.erreur_metier('INVALID_PROGRAM_VALUE', 'L''heure d''envoi doit s''écrire HH:MM (par exemple 09:00).');
  end;
  if d ? 'regle_29_fevrier' and (d ->> 'regle_29_fevrier') not in ('fev28', 'mars1') then
    perform public.erreur_metier('INVALID_PROGRAM_VALUE', 'La règle du 29 février est « fev28 » (le 28 février) ou « mars1 » (le 1er mars).');
  end if;
  if d ? 'canaux' then
    select coalesce(array_agg(distinct c), '{}'::text[]) into v_canaux from jsonb_array_elements_text(d -> 'canaux') c;
    if not (v_canaux <@ array['push', 'email']::text[]) then
      perform public.erreur_metier('INVALID_PROGRAM_VALUE', 'Les canaux possibles sont « push » (application) et « email » : WhatsApp n''est pas encore disponible pour les anniversaires.');
    end if;
    -- Sans canal extérieur, la notification de l'espace client part quand même (elle ne se coupe pas)
  else
    v_canaux := avant.canaux;
  end if;
  if d ? 'fuseau' then
    if not exists (select 1 from pg_timezone_names where name = d ->> 'fuseau') then
      perform public.erreur_metier('INVALID_PROGRAM_VALUE', 'Ce fuseau horaire n''existe pas (par exemple America/Santo_Domingo).');
    end if;
    v_fuseau := d ->> 'fuseau';
    update public.programme_reglages set fuseau = v_fuseau where id;
  end if;

  v_type := case when d ? 'avantage_type' then d ->> 'avantage_type' else avant.avantage_type end;
  v_avantage_actif := case when d ? 'avantage_actif' then (d ->> 'avantage_actif')::boolean else avant.avantage_actif end;
  begin
    v_valeur := case when d ? 'avantage_valeur' then nullif(d ->> 'avantage_valeur', '')::numeric else avant.avantage_valeur end;
  exception when others then
    perform public.erreur_metier('INVALID_PROGRAM_VALUE', 'La valeur de l''avantage n''est pas un nombre.');
  end;
  v_libelle := case when d ? 'avantage_libelle' then left(trim(coalesce(d ->> 'avantage_libelle', '')), 120) else avant.avantage_libelle end;
  if v_avantage_actif then
    if v_type = 'aucun' then
      perform public.erreur_metier('BENEFIT_INCOMPLETE', 'Choisissez le type d''avantage avant de l''activer.');
    elsif v_type = 'gopoints' then
      if not exists (select 1 from public.points_regles r join public.points_reglages g on g.id
                      where r.evenement = 'birthday' and r.actif and g.actif) then
        perform public.erreur_metier('BENEFIT_INCOMPLETE',
          'Pour un avantage en GOPOINTS, allumez d''abord le programme GOPOINTS et la règle « Anniversaire du client » (avec son nombre de points).');
      end if;
    elsif coalesce(v_valeur, 0) <= 0 or length(v_libelle) = 0 then
      perform public.erreur_metier('BENEFIT_INCOMPLETE', 'Un avantage a une valeur et un texte (par exemple « 5 $ de crédit d''expédition ») : indiquez-les avant de l''activer.');
    end if;
  end if;

  update public.anniversaire_reglages set
    actif = v_actif,
    actif_depuis = case when v_actif and not avant.actif then public.aujourdhui_entreprise()
                        when not v_actif then null else actif_depuis end,
    heure_envoi = v_heure,
    regle_29_fevrier = case when d ? 'regle_29_fevrier' then d ->> 'regle_29_fevrier' else regle_29_fevrier end,
    rattrapage_jours = case when d ? 'rattrapage_jours' then public.lire_entier_programme(d, 'rattrapage_jours', 0, 7) else rattrapage_jours end,
    canaux = v_canaux,
    rappel_admin_jours = case when d ? 'rappel_admin_jours' then coalesce(public.lire_entier_programme(d, 'rappel_admin_jours', 0, 60), 0) else rappel_admin_jours end,
    rappel_client_actif = case when d ? 'rappel_client_actif' then (d ->> 'rappel_client_actif')::boolean else rappel_client_actif end,
    rappel_client_jours = case when d ? 'rappel_client_jours' then coalesce(public.lire_entier_programme(d, 'rappel_client_jours', 1, 30), 3) else rappel_client_jours end,
    avantage_actif = v_avantage_actif, avantage_type = v_type, avantage_valeur = v_valeur, avantage_libelle = v_libelle,
    maj_le = now(), maj_par = auth.uid()
   where id returning * into apres;

  perform public.auditer('anniversaire.reglages', 'programme', 'anniversaires',
                         to_jsonb(avant) - 'maj_par' - 'maj_le', to_jsonb(apres) - 'maj_par' - 'maj_le');
  return to_jsonb(apres) - 'maj_par';
end;
$$;

-- Les variables permises dans un modèle (aucune autre : elle serait effacée à l'envoi)
create or replace function public.verifier_modele(p_texte text, p_type text)
returns void
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text;
  v_permises text[] := case p_type
    when 'birthday' then array['prenom']
    when 'birthday_avantage' then array['prenom', 'avantage']
    when 'birthday_upcoming' then array['prenom', 'jours']
    when 'birthday_reminder' then array['nombre', 'jours']
    else array[]::text[] end;
begin
  for v in select (regexp_matches(p_texte, '\{\{([^{}]*)\}\}', 'g'))[1] loop
    if not (v = any (v_permises)) then
      perform public.erreur_metier('INVALID_TEMPLATE', 'La variable {{' || v || '}} n''est pas permise dans ce modèle (permises : '
                                   || coalesce(array_to_string(v_permises, ', '), 'aucune') || ').');
    end if;
  end loop;
  if regexp_replace(p_texte, '\{\{[^{}]*\}\}', '', 'g') ~ '[{}]' then
    perform public.erreur_metier('INVALID_TEMPLATE', 'Les accolades { } ne servent qu''aux variables, par exemple {{prenom}}.');
  end if;
end;
$$;

create or replace function public.anniversaire_modele_modifier(p_type text, p_langue text, p_titre text, p_message text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  m public.notification_modeles;
begin
  perform public.exiger_permission('birthdays.manage');
  select * into m from public.notification_modeles
   where type = p_type and langue = p_langue and type in ('birthday', 'birthday_avantage', 'birthday_upcoming', 'birthday_reminder') for update;
  if not found then
    perform public.erreur_metier('INVALID_TEMPLATE', 'Ce modèle n''existe pas (type ou langue inconnus).');
  end if;
  if length(trim(coalesce(p_titre, ''))) = 0 or length(trim(coalesce(p_message, ''))) = 0 then
    perform public.erreur_metier('INVALID_TEMPLATE', 'Le titre et le message ne peuvent pas être vides.');
  end if;
  if length(p_titre) > 120 or length(p_message) > 1200 then
    perform public.erreur_metier('INVALID_TEMPLATE', 'Le titre (120 signes) ou le message (1 200 signes) est trop long.');
  end if;
  perform public.verifier_modele(p_titre, p_type);
  perform public.verifier_modele(p_message, p_type);
  update public.notification_modeles set titre = trim(p_titre), message = trim(p_message), maj_le = now(), maj_par = auth.uid()
   where type = p_type and langue = p_langue;
  perform public.auditer('anniversaire.modele', 'programme', p_type || ':' || p_langue, null,
                         jsonb_build_object('type', p_type, 'langue', p_langue));
  return jsonb_build_object('type', p_type, 'langue', p_langue, 'titre', trim(p_titre), 'message', trim(p_message));
end;
$$;

create or replace function public.anniversaire_modele_restaurer(p_type text, p_langue text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('birthdays.manage');
  update public.notification_modeles set titre = titre_defaut, message = message_defaut, maj_le = now(), maj_par = auth.uid()
   where type = p_type and langue = p_langue and type in ('birthday', 'birthday_avantage', 'birthday_upcoming', 'birthday_reminder');
  if not found then
    perform public.erreur_metier('INVALID_TEMPLATE', 'Ce modèle n''existe pas (type ou langue inconnus).');
  end if;
  perform public.auditer('anniversaire.modele_restaure', 'programme', p_type || ':' || p_langue, null,
                         jsonb_build_object('type', p_type, 'langue', p_langue));
  return (select jsonb_build_object('type', type, 'langue', langue, 'titre', titre, 'message', message)
            from public.notification_modeles where type = p_type and langue = p_langue);
end;
$$;

-- Corriger la date de naissance d'un client (une faute de frappe, un document) : un motif, journalisé,
-- sans jamais écrire la date au journal. La date d'un client reste sinon déclarée une seule fois.
create or replace function public.corriger_naissance(p_client uuid, p_date text, p_motif text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_date date;
begin
  perform public.exiger_permission('birthdays.manage');
  if length(trim(coalesce(p_motif, ''))) < 3 then
    perform public.erreur_metier('REASON_REQUIRED', 'Un motif est obligatoire pour corriger une date de naissance.');
  end if;
  if not exists (select 1 from public.clients where id = p_client and role = 'client') then
    perform public.erreur_metier('CLIENT_NOT_FOUND', 'Client introuvable.');
  end if;
  v_date := public.valider_date_naissance(p_date);
  insert into public.profils_naissance (client_id, date_naissance, corrigee_le) values (p_client, v_date, now())
  on conflict (client_id) do update set date_naissance = excluded.date_naissance, corrigee_le = now();
  perform public.auditer('client.naissance_corrigee', 'client', p_client::text, null,
                         jsonb_build_object('motif', left(trim(p_motif), 200)));
  return jsonb_build_object('corrigee', true);
end;
$$;


-- 9. Le client : sa préférence ------------------------------------------------------------------------
create or replace function public.mes_preferences_programmes()
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
    perform public.erreur_metier('PERMISSION_DENIED', 'Connectez-vous pour voir vos préférences.');
  end if;
  return jsonb_build_object('anniversaire', coalesce((select anniversaire from public.programme_preferences where client_id = v_moi), true));
end;
$$;

create or replace function public.regler_ma_preference_anniversaire(p_actif boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_moi uuid := auth.uid();
begin
  if v_moi is null or not exists (select 1 from public.clients where id = v_moi and supprime_le is null) then
    perform public.erreur_metier('PERMISSION_DENIED', 'Connectez-vous pour régler vos préférences.');
  end if;
  insert into public.programme_preferences (client_id, anniversaire) values (v_moi, coalesce(p_actif, true))
  on conflict (client_id) do update set anniversaire = excluded.anniversaire, maj_le = now();
  return jsonb_build_object('anniversaire', coalesce(p_actif, true));
end;
$$;


-- 10. Planification, droits, contrôle -------------------------------------------------------------
-- Tous les quarts d'heure : la fonction est relançable sans risque (le journal et la clé unique empêchent
-- tout doublon) ; ce rythme sert à l'heure d'envoi réglée. Sans pg_cron (Database > Extensions), rien ne part :
-- activez l'extension puis relancez ce fichier.
do $planif$
begin
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise notice 'pg_cron indisponible (%). Activez-le : Database > Extensions > pg_cron, puis relancez ce fichier.', sqlerrm;
  end;
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('goship-anniversaires', '*/15 * * * *', 'select public.anniversaires_executer()');
  end if;
end;
$planif$;

revoke execute on function public.anniversaire_traiter(uuid, date, public.anniversaire_reglages) from public, anon, authenticated;
revoke execute on function public.anniversaires_executer(timestamptz) from public, anon, authenticated;
revoke execute on function public.anniversaire_en(date, integer, text) from public, anon, authenticated;
revoke execute on function public.prenom_client(text) from public, anon, authenticated;
revoke execute on function public.verifier_modele(text, text) from public, anon, authenticated;
revoke execute on function public.anniversaires_liste(date, date, integer, integer) from public, anon;
revoke execute on function public.anniversaires_messages(text, date, date, integer, integer) from public, anon;
revoke execute on function public.anniversaires_erreurs(integer, integer) from public, anon;
revoke execute on function public.anniversaires_rappels_liste(integer, integer) from public, anon;
revoke execute on function public.anniversaire_reglages_lire() from public, anon;
revoke execute on function public.anniversaire_modeles_liste() from public, anon;
revoke execute on function public.anniversaire_reglages_modifier(jsonb) from public, anon;
revoke execute on function public.anniversaire_modele_modifier(text, text, text, text) from public, anon;
revoke execute on function public.anniversaire_modele_restaurer(text, text) from public, anon;
revoke execute on function public.corriger_naissance(uuid, text, text) from public, anon;
revoke execute on function public.mes_preferences_programmes() from public, anon;
revoke execute on function public.regler_ma_preference_anniversaire(boolean) from public, anon;
grant execute on function public.anniversaires_liste(date, date, integer, integer) to authenticated;
grant execute on function public.anniversaires_messages(text, date, date, integer, integer) to authenticated;
grant execute on function public.anniversaires_erreurs(integer, integer) to authenticated;
grant execute on function public.anniversaires_rappels_liste(integer, integer) to authenticated;
grant execute on function public.anniversaire_reglages_lire() to authenticated;
grant execute on function public.anniversaire_modeles_liste() to authenticated;
grant execute on function public.anniversaire_reglages_modifier(jsonb) to authenticated;
grant execute on function public.anniversaire_modele_modifier(text, text, text, text) to authenticated;
grant execute on function public.anniversaire_modele_restaurer(text, text) to authenticated;
grant execute on function public.corriger_naissance(uuid, text, text) to authenticated;
grant execute on function public.mes_preferences_programmes() to authenticated;
grant execute on function public.regler_ma_preference_anniversaire(boolean) to authenticated;

-- modeles : 16 ; ouvertes_aux_visiteurs : false ; tables_fermees : true ; programme_eteint : true.
select (select count(*) from public.notification_modeles where type in ('birthday', 'birthday_avantage', 'birthday_upcoming', 'birthday_reminder')) as modeles,
       (select coalesce(bool_or(has_function_privilege('anon', p.oid, 'execute')), false)
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('anniversaires_liste', 'anniversaires_messages', 'anniversaires_erreurs', 'anniversaire_reglages_lire',
                            'anniversaire_reglages_modifier', 'corriger_naissance', 'anniversaires_executer',
                            'mes_preferences_programmes', 'regler_ma_preference_anniversaire'))               as ouvertes_aux_visiteurs,
       not has_table_privilege('authenticated', 'public.anniversaire_journal', 'select')
         and not has_table_privilege('authenticated', 'public.anniversaire_reglages', 'select')
         and not has_table_privilege('authenticated', 'public.notification_modeles', 'select')              as tables_fermees,
       not (select actif from public.anniversaire_reglages where id)                                         as programme_eteint;
