-- =============================================================================
-- BROUILLON — CENTRE DE COMMUNICATION — NE PAS EXÉCUTER
-- Version Phase 1.3.1 (18/11/2026) : arrêt d'urgence prouvé et constats de la revue indépendante
-- (docs/communication-center/PHASE_1_3_1_*.md), après les Phases 1.1, 1.2 et 1.3.
-- =============================================================================
-- Ce fichier est un BROUILLON de conception, rangé dans docs/ (jamais publié, jamais
-- dans outils/migrations.txt). Il n'a été exécuté sur AUCUNE base, même jetable : les
-- Phases 1 à 1.3 n'autorisent aucune exécution.
--
-- La garde a TROIS couches (Phase 1.3, correction 8) — aucune ne suffit seule :
--   1. le bloc DO ci-dessous lève une exception : dans un client qui envoie le fichier en
--      une transaction (SQL Editor, psql --single-transaction, psql -v ON_ERROR_STOP=1),
--      rien de ce qui suit n'est appliqué ;
--   2. TOUT le contenu du brouillon est ensuite enfermé dans UNE chaîne de caractères
--      ($brouillon_goship_non_executable$ … $brouillon_goship_non_executable$) : même un
--      client qui continue après une erreur (psql sans ON_ERROR_STOP, en autocommit) ne
--      reçoit qu'un SELECT d'un texte. Rien n'est créé ;
--   3. la garde « BROUILLON » d'origine est gardée en tête du contenu, pour qui le
--      recopierait hors de la chaîne.
-- Limite connue : un outil qui découpe le texte sur « ; » sans comprendre les dollar-quotes
-- et continue après erreur pourrait exécuter des morceaux du contenu. Les brouillons ne
-- se passent à aucun outil de ce genre ; protocole d'épreuve : PHASE_1_3_TEST_PLAN.md (T-14).
--
-- En Phase 2, et seulement après accord écrit du CEO, il deviendra
-- outils/supabase-communications-fondation.sql, SANS la chaîne englobante, avec la garde
-- habituelle « base incomplète », et sera éprouvé d'abord sur une base jetable.
-- =============================================================================
do $brouillon$
begin
  raise exception 'BROUILLON NON APPROUVÉ (Centre de communication, Phase 1.3.1) : ne pas exécuter.';
end;
$brouillon$;

select $brouillon_goship_non_executable$
-- ===== DÉBUT DU CONTENU INERTE : tout ce qui suit est du TEXTE jusqu'à la balise de fin =====
do $brouillon$
begin
  raise exception 'BROUILLON NON APPROUVÉ (Centre de communication, Phase 1.3.1) : ne pas exécuter.';
end;
$brouillon$;
-- Couche 4 (Phase 1.3.1, IR-22) : un outil qui découperait ce texte à chaque point-virgule, sans comprendre les
-- chaînes, et continuerait après les erreurs, exécuterait CETTE instruction en premier : elle
-- ferme sa propre connexion, et rien de ce qui suit ne peut s'exécuter dans cette session. Dans
-- tout client correct, elle est du texte, comme le reste.
select pg_catalog.pg_terminate_backend(pg_catalog.pg_backend_pid());

-- =============================================================================
-- Goship Express — Centre de communication : la fondation
--
-- Ce que pose ce fichier, sans rien changer au moteur transactionnel :
--    1. les permissions communications.* (copie de permissions_du_role + 7 permissions)
--    2. les réglages, tous nés ÉTEINTS ou BLOQUÉS (aucune campagne ne peut partir)
--    3. les petites aides : jour, empreintes (HMAC poivré), masques, verrous
--    4. le classement des indicatifs téléphoniques (+1 n'est pas « les États-Unis »)
--    5. le journal des erreurs du Centre (jamais d'erreur avalée en silence)
--    6. le consentement commercial : textes, registre (demande → confirmé → retiré ou
--       invalidé), jetons de confirmation
--    7. la liste de suppression, par canal et par adresse exacte
--    8. la liste des destinataires d'essai
--    9. tarifs par territoire et codes d'erreur des fournisseurs (rien d'autorisé d'office)
--   10. les dépenses du jour, sous un verrou commun
--   11. le quota Brevo : ce que le commercial peut encore utiliser
--   12. conservation, anonymisation et effacement contrôlés (la seule exception à
--       l'immuabilité)
--   13. droits
--
-- Ce qu'il ne touche PAS : notifications, notification_envois, notification_regles,
-- notification_preferences, expedier_envoi, traiter_notifications, courriel_gabarit,
-- mon_resume, messages_recents. Le consentement commercial n'est jamais déduit de
-- notification_preferences (transactionnel), et inversement.
-- =============================================================================


-- 1. Les permissions : déplacées en fin de fichier (§13 bis, Phase 1.3.1, IR-22) — remplacer une
-- fonction EXISTANTE en dernier : si l'exécution s'arrête avant, rien de l'existant n'a changé.


-- 2. Les réglages ------------------------------------------------------------------------
-- Une seule ligne. Tout naît ÉTEINT, à ZÉRO ou BLOQUÉ (null) : un plafond à 0 bloque, il ne
-- veut jamais dire « illimité ». Les champs marqués BLOQUÉ attendent une décision du CEO ou
-- une preuve extérieure ; tant qu'ils sont vides, ce qui en dépend ne part pas.
create table if not exists public.communication_reglages (
  id                          boolean primary key default true check (id),
  campagnes_actives           boolean not null default false,   -- interrupteur général du commercial
  mode                        text not null default 'essai' check (mode in ('essai', 'production')),
  email_actif                 boolean not null default false,
  whatsapp_actif              boolean not null default false,
  confirmations_actives       boolean not null default false,   -- envoi des e-mails de confirmation (C2)
  -- Plafonds GLOBAUX du jour (jour civil de Santo Domingo), tous canaux, toutes campagnes
  plafond_jour_usd            numeric(10, 2) not null default 0 check (plafond_jour_usd >= 0),
  plafond_jour_messages       integer not null default 0 check (plafond_jour_messages >= 0),
  -- Quota Brevo du compte COMMERCIAL (décision C4) : BLOQUÉ tant que non vérifié (D-C).
  -- Fenêtres GLISSANTES (24 h, 30 jours) : l'heure de renouvellement de Brevo n'est pas connue.
  brevo_quota_24h             integer check (brevo_quota_24h is null or brevo_quota_24h > 0),
  brevo_quota_30j             integer check (brevo_quota_30j is null or brevo_quota_30j > 0),
  brevo_reserve_24h           integer not null default 150 check (brevo_reserve_24h >= 0),
  brevo_compte_partage        boolean not null default true,    -- true tant que le commercial partage le compte du transactionnel
  brevo_quota_verifie_le      timestamptz,
  brevo_quota_verifie_par     uuid,
  brevo_quota_preuve          text,                             -- où le quota a été lu (capture, page, date)
  -- WhatsApp : limite quotidienne de destinataires du numéro COMMERCIAL, telle que Meta l'a
  -- attribuée (H11). BLOQUÉ (null) : aucun WhatsApp commercial. Jamais une valeur inventée.
  whatsapp_destinataires_jour integer check (whatsapp_destinataires_jour is null or whatsapp_destinataires_jour > 0),
  whatsapp_limite_preuve      text,
  -- Le numéro WhatsApp COMMERCIAL tel qu'il est montré au client pour confirmer son accord
  -- (« écrivez OUI 1234 au … »). BLOQUÉ (null) tant que le CEO n'a pas choisi entre un numéro
  -- dédié et la Coexistence (décision C4) : le recueil WhatsApp reste fermé.
  whatsapp_numero_affiche     text check (whatsapp_numero_affiche is null or whatsapp_numero_affiche ~ '^\+[0-9]{8,15}$'),
  -- Le quota vérifié ne vaut que pour un temps : au-delà, il redevient NON VÉRIFIÉ (1.3, C3).
  -- Choix de conception de GoShip, pas une règle de Brevo : à confirmer par le CEO.
  brevo_quota_validite_jours  integer not null default 30 check (brevo_quota_validite_jours between 1 and 90),
  -- L'ARRÊT D'URGENCE n'est plus ici (Phase 1.3.1) : il a sa propre table, communication_arret
  -- (§2 bis), écrite seulement par les fonctions d'arrêt (41 §4.8), jamais par un réglage.
  -- Débit, délais, fenêtres d'envoi (heure locale du destinataire), fréquence
  -- lot_par_minute : taille d'UN passage du travailleur. debit_max_minute : plafond GLOBAL
  -- (tous travailleurs, tous canaux) d'envois remis au fournisseur par minute, compté sous le
  -- verrou des compteurs (1.3, C3). Valeur de conception, PAS une limite du fournisseur : elle
  -- devra rester sous les limites documentées de Brevo et de Meta, non vérifiées à ce jour.
  lot_par_minute              integer not null default 20 check (lot_par_minute between 1 and 200),
  debit_max_minute            integer not null default 20 check (debit_max_minute between 1 and 600),
  -- Marge avant la fin de la fenêtre horaire : pg_net envoie APRÈS la validation, quelques
  -- secondes plus tard ; on n'entame donc pas un envoi dans les dernières minutes (1.3, C6).
  marge_fenetre_min           integer not null default 15 check (marge_fenetre_min between 0 and 120),
  -- Retours des fournisseurs : au-delà de ce nombre d'appels par minute et par fournisseur, la
  -- base répond « saturé » sans rien traiter (1.3, C7) ; la fonction Edge répond alors une
  -- erreur temporaire pour que le fournisseur réessaie (comportement de réessai À VÉRIFIER).
  webhook_max_minute          integer not null default 600 check (webhook_max_minute between 10 and 10000),
  delai_http_ms               integer not null default 20000 check (delai_http_ms between 5000 and 60000),
  heure_debut                 integer not null default 9  check (heure_debut between 0 and 23),
  heure_fin                   integer not null default 19 check (heure_fin between 1 and 24),
  frequence_max_jour          integer not null default 1 check (frequence_max_jour between 1 and 5),
  frequence_max_semaine       integer not null default 2 check (frequence_max_semaine between 1 and 14),
  attente_transactionnel_max  integer not null default 50 check (attente_transactionnel_max >= 0),
  -- Audience et modèles
  seuil_croissance_pct        integer not null default 10 check (seuil_croissance_pct between 0 and 100),
  modele_meta_fraicheur_min   integer not null default 60 check (modele_meta_fraicheur_min between 5 and 1440),
  -- Consentement (C2, M14)
  confirmation_validite_h     integer not null default 168 check (confirmation_validite_h between 1 and 720),
  changements_consentement_jour integer not null default 5 check (changements_consentement_jour between 1 and 20),
  demandes_confirmation_jour  integer not null default 3 check (demandes_confirmation_jour between 1 and 10),
  -- Quatre yeux : un administrateur peut-il approuver une campagne qu'il a créée ? (décision CEO)
  quatre_yeux                 boolean not null default false,
  -- BLOQUÉ en attente du CEO (D-G, D-H) : jamais inventés
  identite_legale             text check (identite_legale is null or length(identite_legale) between 2 and 200),
  adresse_postale             text check (adresse_postale is null or length(adresse_postale) between 10 and 300),
  identite_validee_par        uuid,
  identite_validee_le         timestamptz,
  adresse_miami_validee       boolean not null default false,
  maj_le                      timestamptz not null default now(),
  maj_par                     uuid,
  check (heure_debut < heure_fin),
  check (brevo_quota_24h is null or brevo_reserve_24h < brevo_quota_24h)
);
insert into public.communication_reglages (id) values (true) on conflict (id) do nothing;
alter table public.communication_reglages enable row level security;
revoke all on public.communication_reglages from anon, authenticated, service_role;


-- 2 bis. L'arrêt d'urgence (Phase 1.3.1 — remplace arret_urgence de la Phase 1.3) ----------------
-- Trois états, et un seul sens pour chacun :
--   actif           rien n'est demandé ;
--   arret_demande   l'arrêt est DEMANDÉ et durablement écrit : toute transaction qui lit cet état
--                   (sous N0 partagé, après l'avoir obtenu) REFUSE d'autoriser un envoi. Ce n'est
--                   PAS un arrêt confirmé : une transaction qui avait lu « actif » juste avant peut
--                   encore valider son envoi ; des requêtes déjà validées peuvent encore être
--                   chez pg_net. Réponse : STOP_PENDING ;
--   arret_confirme  deux faits sont PROUVÉS : (1) N0 a été obtenu en EXCLUSIF dans la transaction
--                   de la demande ou APRÈS elle (autorisations_closes_le) — donc plus aucune
--                   transaction autorisée n'est en cours et aucune ne peut plus l'être ; (2) plus
--                   aucune requête validée n'attend d'être transmise par pg_net. Réponse :
--                   STOP_CONFIRMED.
-- Le passage à arret_confirme ne se fait QUE sous N0 exclusif (contrainte de la table + 41 §4.8).
-- Un délai dépassé ne fait JAMAIS passer à arret_confirme : il laisse arret_demande, et une
-- nouvelle tentative (manuelle, ou automatique au début de chaque passage du travailleur)
-- termine l'arrêt proprement.
create table if not exists public.communication_arret (
  id                       boolean primary key default true check (id),
  etat                     text not null default 'actif' check (etat in ('actif', 'arret_demande', 'arret_confirme')),
  demande_le               timestamptz,
  demande_par              uuid,
  derniere_demande_le      timestamptz,      -- dernier appui sur « Arrêt », même déjà arrêté (IR2-03)
  motif                    text check (motif is null or length(motif) between 5 and 300),
  autorisations_closes_le  timestamptz,      -- N0 exclusif obtenu avec ou après la demande
  confirme_le              timestamptz,
  tentatives               integer not null default 0,
  derniere_tentative_le    timestamptz,
  derniere_raison          text,             -- VERROU_NON_OBTENU, TRANSMISSIONS_EN_COURS…
  leve_le                  timestamptz,
  leve_par                 uuid,
  motif_levee              text check (motif_levee is null or length(motif_levee) between 10 and 300),
  maj_le                   timestamptz not null default now(),
  check (etat = 'actif' or (demande_le is not null and motif is not null)),
  check (etat <> 'actif' or (autorisations_closes_le is null and confirme_le is null)),
  check (etat <> 'arret_confirme' or (autorisations_closes_le is not null and confirme_le is not null
                                       and confirme_le >= autorisations_closes_le
                                       and autorisations_closes_le >= demande_le))
);
insert into public.communication_arret (id) values (true) on conflict (id) do nothing;
-- La ligne ne s'efface jamais (IR2-11) : sans elle, la porte refuserait tout (état illisible),
-- et les fonctions d'arrêt lèvent une erreur au lieu de répondre.
create or replace function public.communication_arret_permanent()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'ARRET_LIGNE_PERMANENTE';
end;
$$;
drop trigger if exists communication_arret_permanent on public.communication_arret;
create trigger communication_arret_permanent before delete or truncate on public.communication_arret
  for each statement execute function public.communication_arret_permanent();
alter table public.communication_arret enable row level security;
revoke all on public.communication_arret from anon, authenticated, service_role;


-- 3. Les petites aides -----------------------------------------------------------------

create or replace function public.communication_jour(p_quand timestamptz default now())
returns date
language sql
stable
set search_path = ''
as $$
  select (p_quand at time zone 'America/Santo_Domingo')::date
$$;

-- La forme normalisée d'une adresse ou d'un numéro (ce qui est comparé et empreint).
create or replace function public.communication_normaliser(p_canal text, p_valeur text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when coalesce(trim(p_valeur), '') = '' then null
    when p_canal = 'email' then lower(trim(p_valeur))
    else nullif(regexp_replace(p_valeur, '\D', '', 'g'), '')
  end
$$;

-- L'empreinte d'une adresse ou d'un numéro (revue 1.1, M11) : HMAC-SHA-256 avec un « poivre »
-- gardé dans le coffre (communication_poivre) ET hors ligne par le propriétaire (comme la clé
-- de sauvegarde age) : sans le poivre, une empreinte ne se devine pas à partir d'une liste
-- d'adresses courantes. Poivre absent (restauration sans lui) : null, et tout ce qui dépend
-- d'une empreinte REFUSE d'envoyer (consentement non reconnu, suppression non vérifiable) :
-- l'échec est fermé, jamais ouvert. Le poivre ne change jamais (sinon toutes les preuves
-- et suppressions deviennent inutilisables) : procédure dans COMMUNICATION_CENTER_SECURITY.md.
create or replace function public.communication_empreinte(p_canal text, p_valeur text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_poivre text := public.lire_reglage('communication_poivre');
  v_norme text := public.communication_normaliser(p_canal, p_valeur);
begin
  if v_norme is null or coalesce(v_poivre, '') = '' then
    return null;
  end if;
  return encode(extensions.hmac(p_canal || ':' || v_norme, v_poivre, 'sha256'), 'hex');
end;
$$;

-- La cible actuelle d'un client sur un canal.
create or replace function public.communication_cible(p_client uuid, p_canal text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case p_canal
           when 'email' then public.communication_normaliser('email', c.email)
           when 'whatsapp' then public.communication_normaliser('whatsapp', public.telephone_international(c.telephone, c.pays))
         end
  from public.clients c where c.id = p_client
$$;

-- Le contact masqué, montré au client sur l'écran de consentement (C2) : « j•••@gmail.com »,
-- « +509 •••• ••12 ». Jamais renvoyé en clair par une fonction de consentement.
create or replace function public.communication_masque(p_canal text, p_valeur text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_valeur is null then null
    when p_canal = 'email' then left(split_part(p_valeur, '@', 1), 1) || '•••@' || split_part(p_valeur, '@', 2)
    else '+' || left(p_valeur, length(p_valeur) - 8) || ' •••• ••' || right(p_valeur, 2)
  end
$$;

-- Les verrous (revue 1.1, H1, H4, H6 ; Phase 1.3, correction 2). Verrous de TRANSACTION
-- (relâchés au COMMIT ou à l'annulation). ORDRE UNIQUE, pour TOUTES les fonctions du Centre ;
-- une transaction peut sauter un niveau, jamais revenir en arrière :
--   N0  interrupteurs   verrou consultatif « interrupteurs » : PARTAGÉ par toute transaction
--                       qui envoie ou prépare un envoi ; EXCLUSIF pour qui écrit un interrupteur
--                       ou un réglage d'envoi (arrêt d'urgence compris)
--   N1  campagne        la ligne de communication_campagnes (FOR UPDATE)
--   N2  client          verrou consultatif « client:<id> »
--   N3  consentement    verrou consultatif « consentement:<client>:<canal> » ; plusieurs
--                       clients dans une même transaction : par identifiant CROISSANT
--   N4  envoi           la ligne de communication_envois (FOR UPDATE)
--   N5  compteurs       verrou consultatif « compteurs » (global) : dépenses du jour, débit par
--                       minute, quota Brevo, plafonds de campagne, limite du numéro WhatsApp
-- Le travailleur traite UN envoi par transaction (43 §8) : il ne garde jamais les verrous
-- d'un envoi en prenant ceux du suivant. Avant la Phase 1.3, il prenait « client » puis
-- « jour » à chaque envoi, mais gardait « jour » jusqu'à la fin du lot : deux travailleurs
-- pouvaient s'attendre l'un l'autre (interblocage) ; et il verrouillait l'envoi AVANT la
-- campagne, quand l'annulation verrouille la campagne AVANT les envois.
create or replace function public.communication_verrou(p_sujet text)
returns void
language sql
set search_path = ''
as $$
  select pg_advisory_xact_lock(hashtextextended('goship-communication:' || p_sujet, 0))
$$;

-- N0 : partagé (toute transaction qui AUTORISE une requête sortante, par
-- communication_autoriser_sortie — et rien d'autre) ou exclusif (arrêt, levée, réglages
-- d'envoi). Obtenir N0 en exclusif PROUVE qu'aucune transaction autorisée n'est en cours : elles
-- tiennent toutes N0 partagé de leur autorisation jusqu'à leur COMMIT.
-- Phase 1.3.1 : AUCUNE fonction n'écrit plus un état d'arrêt « confirmé » sans l'avoir obtenu.
-- (Ordre de service des demandes de verrou par PostgreSQL : à éprouver, PHASE_1_3_1_TEST_PLAN.)
create or replace function public.communication_verrou_interrupteurs(p_exclusif boolean)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_exclusif then
    perform pg_advisory_xact_lock(hashtextextended('goship-communication:interrupteurs', 0));
  else
    perform pg_advisory_xact_lock_shared(hashtextextended('goship-communication:interrupteurs', 0));
  end if;
end;
$$;

-- Ce qui interdit une sortie, d'après l'état d'arrêt et les réglages : null = permis, sinon le
-- code. Natures : « campagne », « confirmation » (e-mail de confirmation du consentement),
-- « lecture_meta » (lecture d'un modèle chez Meta : n'envoie rien à un client ; seul l'arrêt la
-- bloque). Tout état d'arrêt autre que « actif », ou illisible, ferme tout.
create or replace function public.communication_interrupteur_ferme(r public.communication_reglages, p_arret text,
                                                                   p_nature text, p_canal text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_arret is distinct from 'actif' then 'ARRET_URGENCE'
    when r is null then 'REGLAGES_ILLISIBLES'
    when coalesce(p_canal, '') not in ('email', 'whatsapp')
      or coalesce(p_nature, '') not in ('campagne', 'confirmation', 'lecture_meta') then 'INCONNU'
    when p_nature = 'lecture_meta' then null
    when p_nature = 'campagne' and not r.campagnes_actives then 'CAMPAGNES_COUPEES'
    when p_nature = 'confirmation' and not r.confirmations_actives then 'CONFIRMATIONS_COUPEES'
    when p_canal = 'email' and not r.email_actif then 'EMAIL_COUPE'
    when p_canal = 'whatsapp' and not r.whatsapp_actif then 'WHATSAPP_COUPE'
  end
$$;

-- LA PORTE UNIQUE des sorties (Phase 1.3.1). Toute transaction qui va déposer une requête chez
-- pg_net (net.http_post, net.http_get) l'appelle d'abord, dans la MÊME transaction :
--   1. N0 PARTAGÉ — tenu jusqu'au COMMIT ou à l'annulation de la transaction ;
--   2. PUIS lecture de l'état d'arrêt et des réglages (requête postérieure au verrou, donc
--      nouvel instantané : elle voit tout arrêt validé avant l'obtention du verrou) ;
--   3. si tout est ouvert, marque la transaction comme autorisée (goship.sortie_autorisee =
--      identifiant de la transaction). Les fonctions d'appel (43 §5, 42 §2) REFUSENT de déposer
--      une requête si cette marque manque : la règle n'est pas une convention, elle est vérifiée.
-- C'est le POINT D'AUTORISATION. Le dernier contrôle de l'arrêt pour un envoi est ICI ; la
-- relecture sous N5 (communication_reserver) n'est qu'une défense de plus.
create or replace function public.communication_autoriser_sortie(p_nature text, p_canal text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.communication_reglages;
  v_arret text;
  v_raison text;
begin
  -- Revue n° 2 (IR2-10) : la démonstration suppose READ COMMITTED (chaque requête voit ce qui a été
  -- validé avant elle) ; vérifié ICI, à la porte, pour toutes les sorties
  if current_setting('transaction_isolation') <> 'read committed' then
    raise exception 'ISOLATION_NON_SUPPORTEE';
  end if;
  perform public.communication_verrou_interrupteurs(false);                      -- N0 partagé
  select a.etat into v_arret from public.communication_arret a;                 -- APRÈS le verrou
  select * into r from public.communication_reglages;
  v_raison := public.communication_interrupteur_ferme(r, v_arret, p_nature, p_canal);
  -- IR2-12 : compte Brevo partagé avec le transactionnel = aucun e-mail commercial ni de
  -- confirmation, à CHAQUE sortie (pas seulement à l'allumage du canal)
  if v_raison is null and p_canal = 'email' and r.brevo_compte_partage
     and coalesce(nullif(public.lire_reglage('communication_email_fournisseur'), ''), 'brevo') = 'brevo' then
    v_raison := 'COMPTE_BREVO_PARTAGE';
  end if;
  if v_raison is null then
    -- La marque porte la transaction, la nature et le canal autorisés (IR2-10)
    perform set_config('goship.sortie_autorisee', txid_current()::text || ':' || p_nature || ':' || p_canal, true);
  end if;
  return v_raison;
end;
$$;

-- Vraie seulement dans une transaction qui est passée par la porte, avec succès.
create or replace function public.communication_sortie_autorisee(p_nature text, p_canal text)
returns boolean
language sql
volatile
set search_path = ''
as $$
  select coalesce(current_setting('goship.sortie_autorisee', true), '') = txid_current()::text || ':' || p_nature || ':' || p_canal
$$;


-- 4. Les indicatifs téléphoniques (revue 1.1, H12) ----------------------------------------
-- Un numéro « +1 » n'est pas forcément américain. Le territoire se lit par le préfixe le plus
-- long connu. Tout ce qui n'est pas listé, ou listé sans autorisation VÉRIFIÉE auprès de Meta,
-- est BLOQUÉ pour le marketing. Les préfixes ci-dessous sont des faits du plan de numérotation
-- nord-américain (NANP) à reconfirmer sur la liste officielle de NANPA en Phase 2 ; les
-- indicatifs des États-Unis et du Canada (plusieurs centaines) seront chargés depuis cette
-- liste officielle, jamais recopiés de mémoire. Haïti (+509) n'est pas autorisé d'office non
-- plus : l'éligibilité au marketing doit être confirmée par Meta pour CHAQUE territoire.
create table if not exists public.communication_indicatifs (
  prefixe            text primary key check (prefixe ~ '^[0-9]{1,6}$'),
  territoire         text not null check (territoire in ('HT', 'DO', 'PR', 'JM', 'CA', 'US', 'NANP_AUTRE')),
  autorise_marketing boolean not null default false,
  verifie            boolean not null default false,
  preuve             text not null default '',
  verifie_par        uuid,
  verifie_le         timestamptz,
  check (not autorise_marketing or verifie)
);
insert into public.communication_indicatifs (prefixe, territoire, preuve) values
  ('509',  'HT', 'Indicatif d''Haïti — éligibilité marketing Meta à confirmer'),
  ('1809', 'DO', 'République dominicaine — NANPA à reconfirmer ; pause marketing +1 de Meta à clarifier'),
  ('1829', 'DO', 'République dominicaine — idem'),
  ('1849', 'DO', 'République dominicaine — idem'),
  ('1787', 'PR', 'Porto Rico — NANPA à reconfirmer ; statut Meta à confirmer'),
  ('1939', 'PR', 'Porto Rico — idem'),
  ('1876', 'JM', 'Jamaïque — NANPA à reconfirmer ; statut Meta à confirmer'),
  ('1658', 'JM', 'Jamaïque — idem'),
  ('1',    'NANP_AUTRE', 'Tout autre +1 : non classé tant que la liste NANPA n''est pas chargée')
on conflict (prefixe) do nothing;
alter table public.communication_indicatifs enable row level security;
revoke all on public.communication_indicatifs from anon, authenticated, service_role;

-- Le territoire d'un numéro international (chiffres), par le préfixe le plus long.
create or replace function public.communication_territoire(p_numero text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select i.territoire from public.communication_indicatifs i
   where p_numero like i.prefixe || '%'
   order by length(i.prefixe) desc limit 1
$$;


-- 5. Le journal des erreurs du Centre (revue 1.1, M13) ---------------------------------------
-- Un déclencheur du Centre qui échoue n'empêche jamais l'opération du client, mais l'erreur
-- est GARDÉE ici (code et contexte court, sans donnée personnelle), visible dans le Centre et
-- comptée par controle-integrite.sql (Phase 2).
create table if not exists public.communication_erreurs (
  id        bigint generated always as identity primary key,
  source    text not null,
  code      text not null,
  detail    text not null default '' check (length(detail) <= 300),
  cree_le   timestamptz not null default now()
);
alter table public.communication_erreurs enable row level security;
revoke all on public.communication_erreurs from anon, authenticated, service_role;


-- 6. Le consentement commercial ---------------------------------------------------------------
-- 6.1 Les textes présentés au client, versionnés par canal ET par langue. Un texte n'est
-- présentable qu'après l'attestation de l'administrateur qu'il a été approuvé par le conseil
-- juridique (référence de l'avis). La base ne peut pas vérifier l'avis lui-même : elle rend
-- l'étape obligatoire, visible et journalisée (revue 1.1, §5 point 4).
create table if not exists public.communication_textes_consentement (
  version             text not null check (version ~ '^[0-9]{4}-[0-9]{2}-[a-z0-9-]{1,20}$'),
  canal               text not null check (canal in ('email', 'whatsapp')),
  langue              text not null check (langue in ('fr', 'en', 'es', 'ht')),
  texte               text not null check (length(texte) between 20 and 2000),
  empreinte           text not null,
  statut              text not null default 'brouillon' check (statut in ('brouillon', 'atteste_juridique', 'retire')),
  reference_juridique text check (reference_juridique is null or length(reference_juridique) between 5 and 300),
  atteste_par         uuid,
  atteste_le          timestamptz,
  cree_le             timestamptz not null default now(),
  primary key (version, canal, langue),
  check (statut <> 'atteste_juridique' or (reference_juridique is not null and atteste_par is not null))
);
alter table public.communication_textes_consentement enable row level security;
revoke all on public.communication_textes_consentement from anon, authenticated, service_role;

-- 6.2 Le registre. Une ligne par étape, jamais modifiée hors de la purge contrôlée (§12) :
--   demande    le client a coché la case (texte, langue, contact masqué affichés) : EN ATTENTE
--   confirme   le contact a prouvé qu'il est bien à lui (lien e-mail, ou message WhatsApp
--              reçu depuis ce numéro) : seul état qui permet un envoi commercial
--   retire     retrait VOLONTAIRE (case décochée, lien, STOP, plainte, demande à l'équipe…)
--   invalide   le contact a CHANGÉ (ou le compte est supprimé) : ce n'est PAS un retrait ;
--              l'empreinte gardée est celle de l'ANCIEN contact (revue 1.1, H7)
-- Chaque ligne porte l'empreinte du contact exact. L'état d'un client sur un canal est celui
-- de sa dernière ligne, et un envoi exige : dernière ligne = « confirme » ET empreinte égale à
-- celle du contact ACTUEL. Un nouveau contact n'hérite donc jamais d'un consentement.
-- Ordre fiable (revue 1.1, H6) : toutes les écritures prennent le verrou client+canal, l'heure
-- est clock_timestamp() (pas l'heure de début de transaction), et à heure égale un retrait ou
-- une invalidation passe devant (communication_etat_consentement).
-- client_id peut devenir null à l'anonymisation (§12) ; pas de clé étrangère vers clients :
-- la preuve survit à l'effacement d'un compte, le temps fixé par la politique de conservation.
create table if not exists public.communication_consentements (
  id               bigint generated always as identity primary key,
  client_id        uuid,
  canal            text not null check (canal in ('email', 'whatsapp')),
  finalite         text not null default 'marketing' check (finalite = 'marketing'),
  action           text not null check (action in ('demande', 'confirme', 'retire', 'invalide')),
  source           text not null check (source in (
                     'compte_web', 'application',                                  -- demande, retrait du client
                     'lien_confirmation', 'whatsapp_confirmation',                 -- confirmation par le contact
                     'lien_desinscription', 'whatsapp_stop', 'opposition_meta',    -- retraits par le canal
                     'plainte', 'equipe_sur_demande',                              -- retraits
                     'changement_contact', 'suppression_compte', 'expiration')),   -- invalidations
  texte_version    text,
  texte_empreinte  text,
  langue           text check (langue is null or langue in ('fr', 'en', 'es', 'ht')),
  cible_empreinte  text,
  contexte         jsonb not null default '{}'::jsonb,   -- page ou version de l'application, rien de plus
  auteur_id        uuid,
  motif            text check (motif is null or length(motif) <= 300),
  anonymise_le     timestamptz,
  cree_le          timestamptz not null default clock_timestamp(),
  -- Une ligne anonymisée peut perdre son empreinte de contact au second temps de la purge
  -- (catégorie « empreintes », durée BLOQUÉE tant que le juriste ne l'a pas fixée ; 1.3, C5)
  check (action not in ('demande', 'confirme') or (texte_version is not null and texte_empreinte is not null
                                                    and langue is not null
                                                    and (cible_empreinte is not null or anonymise_le is not null))),
  check (action <> 'demande' or source in ('compte_web', 'application')),
  check (action <> 'confirme' or source in ('lien_confirmation', 'whatsapp_confirmation')),
  check (action <> 'retire' or source in ('compte_web', 'application', 'lien_desinscription', 'whatsapp_stop',
                                          'opposition_meta', 'plainte', 'equipe_sur_demande')),
  check (action <> 'invalide' or source in ('changement_contact', 'suppression_compte', 'expiration'))
);
create index if not exists communication_consentements_client_idx
  on public.communication_consentements (client_id, canal, cree_le desc, id desc);
alter table public.communication_consentements enable row level security;
revoke all on public.communication_consentements from anon, authenticated, service_role;

-- 6.3 Les jetons de confirmation (C2) : un par demande. Le jeton n'est JAMAIS gardé en clair
-- (seulement son SHA-256) ; usage unique ; durée limitée ; lié à l'empreinte du contact au
-- moment de la demande. WhatsApp : un code court (4 chiffres) que le client renvoie depuis
-- son numéro, avec le mot de confirmation (OUI, YES, SÍ, WI) — mots à valider (juriste, Meta).
create table if not exists public.communication_confirmations (
  id               bigint generated always as identity primary key,
  consentement_id  bigint not null references public.communication_consentements (id),
  client_id        uuid,
  canal            text not null check (canal in ('email', 'whatsapp')),
  cible_empreinte  text not null,
  jeton_empreinte  text,                       -- e-mail : SHA-256 du jeton du lien
  code             text check (code is null or code ~ '^[0-9]{4}$'),  -- WhatsApp
  expire_le        timestamptz not null,
  utilise_le       timestamptz,
  annule_le        timestamptz,
  cree_le          timestamptz not null default clock_timestamp(),
  -- E-mail : le jeton n'existe qu'au moment où le travailleur envoie l'e-mail de confirmation
  -- (il est mis dans le lien, puis seule son empreinte est gardée) ; avant, jeton_empreinte est vide.
  check (canal = 'email' or code is not null)
);
create unique index if not exists communication_confirmations_jeton_idx
  on public.communication_confirmations (jeton_empreinte) where jeton_empreinte is not null;
create index if not exists communication_confirmations_attente_idx
  on public.communication_confirmations (cible_empreinte, canal) where utilise_le is null and annule_le is null;
create index if not exists communication_confirmations_consentement_idx
  on public.communication_confirmations (consentement_id);
alter table public.communication_confirmations enable row level security;
revoke all on public.communication_confirmations from anon, authenticated, service_role;

-- L'état d'un client sur un canal : aucun, en_attente, confirme, retire, invalide — et s'il
-- permet un envoi (« actif »). À heure égale, retrait et invalidation passent devant.
create or replace function public.communication_etat_consentement(p_client uuid, p_canal text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  k public.communication_consentements;
  v_actuelle text := public.communication_empreinte(p_canal, public.communication_cible(p_client, p_canal));
begin
  select * into k from public.communication_consentements c
   where c.client_id = p_client and c.canal = p_canal
   order by c.cree_le desc, (c.action in ('retire', 'invalide')) desc, c.id desc
   limit 1;
  if not found then
    return jsonb_build_object('etat', 'aucun', 'actif', false);
  end if;
  return jsonb_build_object(
    'etat', case k.action when 'demande' then 'en_attente' when 'confirme' then 'confirme'
                          when 'retire' then 'retire' else 'invalide' end,
    -- Actif seulement si confirmé, pour le contact ACTUEL, et si le poivre est là (sinon null ≠ null)
    'actif', k.action = 'confirme' and v_actuelle is not null and k.cible_empreinte = v_actuelle,
    'depuis', k.cree_le, 'version', k.texte_version, 'langue', k.langue);
end;
$$;

create or replace function public.communication_consentement_actuel(p_client uuid, p_canal text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((public.communication_etat_consentement(p_client, p_canal) ->> 'actif')::boolean, false)
$$;


-- 7. La liste de suppression ---------------------------------------------------------------------
-- Par canal et par adresse EXACTE (empreinte) : un e-mail désinscrit ne bloque pas WhatsApp, et
-- inversement ; une désinscription bloque l'adresse qui a reçu le message, pas la nouvelle
-- adresse d'un client qui a changé de contact (revue 1.1, H5). Ne concerne QUE le commercial :
-- aucune fonction transactionnelle ne lit cette table.
-- Lever une suppression ne rend JAMAIS le consentement. Une nouvelle demande CONFIRMÉE par le
-- client lui-même lève une suppression « desinscription » ou « stop » de ce même contact (choix
-- à faire valider par le juriste) ; « plainte », « rebond_definitif », « numero_invalide »,
-- « opposition_meta » et « manuel » ne se lèvent que par l'administrateur, avec motif.
create table if not exists public.communication_suppressions (
  id               bigint generated always as identity primary key,
  canal            text not null check (canal in ('email', 'whatsapp')),
  cible_empreinte  text not null,
  client_id        uuid,
  raison           text not null check (raison in ('desinscription', 'stop', 'rebond_definitif', 'plainte',
                                                    'numero_invalide', 'opposition_meta', 'manuel')),
  source           text not null default '',
  auteur_id        uuid,
  motif            text check (motif is null or length(motif) <= 300),
  cree_le          timestamptz not null default clock_timestamp(),
  leve_le          timestamptz,
  leve_par         uuid,
  motif_levee      text check (motif_levee is null or length(motif_levee) between 5 and 300)
);
create unique index if not exists communication_suppressions_active_idx
  on public.communication_suppressions (canal, cible_empreinte) where leve_le is null;
create index if not exists communication_suppressions_client_idx
  on public.communication_suppressions (client_id) where client_id is not null;
alter table public.communication_suppressions enable row level security;
revoke all on public.communication_suppressions from anon, authenticated, service_role;

-- Supprimée ? Empreinte inconnue (poivre absent) : on répond « oui » (échec fermé).
create or replace function public.communication_supprimee(p_canal text, p_cible_empreinte text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_cible_empreinte is null
      or exists (select 1 from public.communication_suppressions s
                  where s.canal = p_canal and s.leve_le is null and s.cible_empreinte = p_cible_empreinte)
$$;


-- 8. Les destinataires d'essai ------------------------------------------------------------------
-- La SEULE liste qui reçoit en mode « essai » et la seule qui reçoit un envoi d'essai, quel que
-- soit le mode. Vérifiée à la constitution de l'audience ET juste avant chaque envoi.
create table if not exists public.communication_destinataires_essai (
  client_id   uuid not null references public.clients (id) on delete cascade,
  canal       text not null check (canal in ('email', 'whatsapp')),
  actif       boolean not null default true,
  motif       text not null check (length(motif) between 5 and 300),
  ajoute_par  uuid not null,
  ajoute_le   timestamptz not null default now(),
  primary key (client_id, canal)
);
alter table public.communication_destinataires_essai enable row level security;
revoke all on public.communication_destinataires_essai from anon, authenticated, service_role;

create or replace function public.communication_est_essai(p_client uuid, p_canal text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.communication_destinataires_essai d
                  where d.client_id = p_client and d.canal = p_canal and d.actif)
$$;


-- 9. Tarifs et codes des fournisseurs ------------------------------------------------------------
-- 9.1 Le prix ESTIMÉ d'un message par territoire. Aucune ligne n'est créée par ce fichier : un
-- prix n'entre qu'avec sa preuve (grille officielle, date), saisi par l'administrateur
-- (verifier_tarif_communication). Sans prix vérifié pour le territoire, rien ne part.
create table if not exists public.communication_tarifs (
  fournisseur   text not null check (fournisseur in ('meta', 'brevo', 'resend')),
  canal         text not null check (canal in ('email', 'whatsapp')),
  categorie     text not null check (categorie in ('marketing', 'email')),
  territoire    text not null check (territoire in ('HT', 'DO', 'PR', 'JM', 'CA', 'US', 'NANP_AUTRE', '*')),
  prix_usd      numeric(10, 5) not null check (prix_usd >= 0),
  preuve        text not null check (length(preuve) >= 5),
  verifie_par   uuid not null,
  verifie_le    timestamptz not null default now(),
  primary key (fournisseur, canal, categorie, territoire)
);
alter table public.communication_tarifs enable row level security;
revoke all on public.communication_tarifs from anon, authenticated, service_role;

-- 9.2 Ce que fait le Centre d'un code d'erreur d'un fournisseur (revue 1.1, H11). Les actions
-- sont des choix de conception PRUDENTS ; la signification exacte de chaque code est à
-- confirmer sur la documentation officielle de Meta (verifie = false).
create table if not exists public.communication_codes_fournisseur (
  fournisseur  text not null,
  code         text not null,
  action       text not null check (action in ('suppression_contact', 'echec_sans_relance',
                                               'reporter_destinataire', 'pause_canal', 'pause_campagne')),
  delai_heures integer check (delai_heures is null or delai_heures between 1 and 720),
  description  text not null,
  verifie      boolean not null default false,
  primary key (fournisseur, code)
);
insert into public.communication_codes_fournisseur (fournisseur, code, action, delai_heures, description) values
  ('meta', '131050', 'suppression_contact', null,
   'Rapporté : le destinataire a refusé les messages marketing de l''entreprise. Suppression WhatsApp de ce contact, retrait « opposition_meta ». À confirmer.'),
  ('meta', '131049', 'echec_sans_relance', null,
   'Rapporté : message non remis par Meta pour préserver l''expérience de l''utilisateur. Échec, jamais relancé automatiquement dans la campagne. À confirmer.'),
  ('meta', '131048', 'pause_canal', null,
   'Rapporté : limite anti-spam atteinte pour le numéro. Pause de tout le WhatsApp commercial, alerte à l''administrateur. À confirmer.'),
  ('meta', '131056', 'reporter_destinataire', 24,
   'Rapporté : trop de messages vers le même destinataire. Reporté une seule fois, 24 h plus tard. À confirmer.')
on conflict (fournisseur, code) do nothing;
alter table public.communication_codes_fournisseur enable row level security;
revoke all on public.communication_codes_fournisseur from anon, authenticated, service_role;

-- 9.3 Ce que prouve une réponse HTTP d'erreur d'un fournisseur (Phase 1.3, correction 4).
-- Une réponse 5xx NE PROUVE PAS que le message a été refusé : le fournisseur a pu l'accepter
-- puis échouer avant de répondre. Une 429 n'est un refus SÛR que si la documentation officielle
-- du fournisseur le garantit. Sans ligne VÉRIFIÉE ici, la règle par défaut s'applique
-- (communication_lire_reponse, 43 §6) :
--   429 et 5xx → « incertain » (JAMAIS de nouvel essai automatique) ;
--   autres 4xx → « echec » (requête refusée telle quelle : rien n'est parti).
-- Une ligne n'entre qu'avec sa preuve (page officielle, date), par verifier_issue_http (41) ;
-- aucune n'est créée par ce fichier.
create table if not exists public.communication_issues_http (
  fournisseur  text not null check (fournisseur in ('meta', 'brevo', 'resend')),
  code_http    integer not null check (code_http between 400 and 599),
  issue        text not null check (issue in ('rejet_temporaire', 'echec', 'incertain')),
  preuve       text not null check (length(preuve) >= 10),
  verifie_par  uuid not null,
  verifie_le   timestamptz not null default now(),
  primary key (fournisseur, code_http)
);
alter table public.communication_issues_http enable row level security;
revoke all on public.communication_issues_http from anon, authenticated, service_role;


-- 10. Les dépenses du jour et le débit (revue 1.1, H1 ; Phase 1.3, correction 3) ---------------
-- Une ligne par jour, fournisseur et canal. Toute réservation prend D'ABORD le verrou GLOBAL
-- des compteurs (N5, communication_verrou('compteurs')), PUIS relit les sommes, PUIS augmente,
-- dans la même transaction d'UN envoi : deux travailleurs passent l'un après l'autre, et le
-- second voit ce que le premier a validé (il ne prend le verrou qu'après son COMMIT).
create table if not exists public.communication_depenses_jour (
  jour        date not null,
  fournisseur text not null,
  canal       text not null,
  messages    integer not null default 0 check (messages >= 0),
  cout_usd    numeric(12, 5) not null default 0 check (cout_usd >= 0),
  primary key (jour, fournisseur, canal)
);
alter table public.communication_depenses_jour enable row level security;
revoke all on public.communication_depenses_jour from anon, authenticated, service_role;

-- Le débit GLOBAL : envois remis au fournisseur par minute (tous travailleurs, tous canaux),
-- compté sous N5. Remplace la limite « par passage », qui ne valait que pour un travailleur.
create table if not exists public.communication_debit_minute (
  minute   timestamptz primary key,
  envois   integer not null default 0 check (envois >= 0)
);
alter table public.communication_debit_minute enable row level security;
revoke all on public.communication_debit_minute from anon, authenticated, service_role;


-- 11. Le quota Brevo (revue 1.1, H2, H3, M12) -------------------------------------------------------
-- Brevo compte ensemble tous les e-mails d'un COMPTE. Tant que le commercial partage le compte
-- du transactionnel (brevo_compte_partage = true), il ne prend que ce qui reste APRÈS :
--   la réserve (brevo_reserve_24h),
--   les e-mails d'authentification (ESTIMÉS : auth.users ne garde qu'une date par compte et
--     par type, c'est une borne basse ; si le journal d'Auth est lisible, il est utilisé — sa
--     structure est à vérifier en Phase 2),
--   les e-mails transactionnels CONNUS (envoyés, et EN ATTENTE dans la file),
--   le commercial déjà réservé.
-- Fenêtres GLISSANTES de 24 heures et de 30 jours : l'heure de renouvellement des quotas de
-- Brevo n'est pas connue, on ne suppose pas minuit de Santo Domingo.
-- Quota non vérifié (null, sans date et preuve, ou vérifié il y a plus de
-- brevo_quota_validite_jours) : 0, l'e-mail commercial reste fermé.
-- PHASE 1.3 (correction 3) : n'est PLUS calculé une fois par passage et décompté en mémoire
-- (deux travailleurs partaient alors de la même estimation). Il est RECALCULÉ à chaque
-- réservation, SOUS le verrou N5, par communication_reserver (43 §3) : la somme des réservations
-- ne peut pas dépasser ce qu'il renvoie. Brevo n'a pas été prouvé séparer le quota commercial du
-- transactionnel : tant que brevo_compte_partage est vrai, tout le transactionnel connu est
-- retiré d'abord, plus la réserve.
create or replace function public.communication_brevo_disponible()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  r public.communication_reglages;
  v_auth_24h integer := 0;
  v_auth_30j integer := 0;
  v_trans_24h integer;
  v_trans_30j integer;
  v_attente integer;
  v_comm_24h integer;
  v_comm_30j integer;
  v_dispo_24h integer;
  v_dispo_30j integer;
begin
  select * into r from public.communication_reglages;
  if (r.brevo_quota_24h is null and r.brevo_quota_30j is null)
     or r.brevo_quota_verifie_le is null or coalesce(r.brevo_quota_preuve, '') = '' then
    return jsonb_build_object('disponible', 0, 'raison', 'QUOTA_NON_VERIFIE');
  end if;
  if r.brevo_quota_verifie_le < now() - make_interval(days => r.brevo_quota_validite_jours) then
    return jsonb_build_object('disponible', 0, 'raison', 'QUOTA_A_REVERIFIER');
  end if;

  if r.brevo_compte_partage then
    -- Estimé (borne basse) : une date par compte et par type
    select count(*) filter (where a.t >= now() - interval '24 hours'),
           count(*) filter (where a.t >= now() - interval '30 days')
      into v_auth_24h, v_auth_30j
      from (select confirmation_sent_at t from auth.users union all
            select recovery_sent_at from auth.users union all
            select email_change_sent_at from auth.users union all
            select reauthentication_sent_at from auth.users) a
     where a.t >= now() - interval '30 days';
    -- Connu : envois transactionnels partis (y compris refusés après coup) et bienvenue
    select count(*) filter (where coalesce(e.envoye_le, e.maj_le) >= now() - interval '24 hours'),
           count(*)
      into v_trans_24h, v_trans_30j
      from public.notification_envois e
     where e.canal = 'email' and e.statut in ('envoi', 'envoye', 'livre', 'echec')
       and coalesce(e.envoye_le, e.maj_le) >= now() - interval '30 days';
    v_trans_24h := v_trans_24h + (select count(*) from public.notifications n
                                   where n.canal = 'email' and n.envoye_le >= now() - interval '24 hours');
    v_trans_30j := v_trans_30j + (select count(*) from public.notifications n
                                   where n.canal = 'email' and n.envoye_le >= now() - interval '30 days');
    -- Connu : ce qui attend dans la file transactionnelle (il partira, il faut le garder)
    select count(*) into v_attente from public.notification_envois e
     where e.canal = 'email' and e.statut = 'attente';
  else
    v_trans_24h := 0; v_trans_30j := 0; v_attente := 0;
  end if;

  select coalesce(sum(messages) filter (where jour >= public.communication_jour(now() - interval '24 hours')), 0),
         coalesce(sum(messages), 0)
    into v_comm_24h, v_comm_30j
    from public.communication_depenses_jour
   where canal = 'email' and jour >= public.communication_jour(now() - interval '30 days');

  v_dispo_24h := case when r.brevo_quota_24h is null then 2147483647
                      else r.brevo_quota_24h - r.brevo_reserve_24h - v_auth_24h - v_trans_24h - v_attente - v_comm_24h end;
  v_dispo_30j := case when r.brevo_quota_30j is null then 2147483647
                      else r.brevo_quota_30j - r.brevo_reserve_24h * 30 - v_auth_30j - v_trans_30j - v_attente - v_comm_30j end;
  return jsonb_build_object(
    'disponible', greatest(least(v_dispo_24h, v_dispo_30j), 0),
    'connu', jsonb_build_object('transactionnel_24h', v_trans_24h, 'transactionnel_30j', v_trans_30j,
                                'transactionnel_en_attente', v_attente, 'commercial_24h', v_comm_24h,
                                'commercial_30j', v_comm_30j),
    'estime', jsonb_build_object('authentification_24h_borne_basse', v_auth_24h,
                                 'authentification_30j_borne_basse', v_auth_30j),
    'compte_partage', r.brevo_compte_partage);
end;
$$;


-- 11 bis. Le fuseau horaire du destinataire (Phase 1.3, correction 6) ------------------------------
-- Avant 1.3 : « HT → Port-au-Prince, DO → Santo Domingo, TOUT LE RESTE → New York ». Faux pour
-- un client de Chicago, Denver, Los Angeles, Anchorage ou Honolulu (et pour tout autre pays) :
-- un message « à 9 h » partait à 6 h à Los Angeles. Désormais :
--   1. un fuseau DÉCLARÉ pour ce client (par lui, ou par l'équipe qui l'a vérifié), valable
--      tant que son pays et sa région n'ont pas changé ;
--   2. sinon HT → America/Port-au-Prince, DO → America/Santo_Domingo (un seul fuseau IANA par
--      pays). HYPOTHÈSE ASSUMÉE (1.3.1, IR-23) : pour ces deux pays, le pays du PROFIL vaut lieu de
--      résidence ; un client HT qui vit à Miami doit déclarer son fuseau (Mon compte, Phase 2c) ;
--   3. sinon US → le fuseau de son État, SEULEMENT si cet État figure dans
--      communication_fuseaux_regions, saisi avec sa preuve (base IANA, date). Aucune ligne
--      n'est créée ici : la table est vide, et un État à plusieurs fuseaux (Floride, Texas,
--      Tennessee, Kentucky, Indiana, Michigan, Kansas, Nebraska, Dakota du Nord et du Sud,
--      Oregon, Idaho, Alaska…) n'y entre pas : il faut un fuseau déclaré ;
--   4. sinon : INCONNU → null, et l'envoi est écarté (FUSEAU_INCONNU). Jamais deviné. Le pays
--      n'est jamais la preuve du fuseau, et l'indicatif de téléphone non plus.
--   WhatsApp : si le territoire du numéro (indicatif) ne correspond pas au pays du profil
--   (client « HT » avec un numéro +1), seul un fuseau déclaré vaut.
-- Les heures d'été et d'hiver sont celles de la base IANA du serveur (« at time zone » avec un
-- NOM de fuseau, jamais un décalage fixe) ; sa mise à jour suit celle de PostgreSQL (à surveiller).
create table if not exists public.communication_fuseaux_regions (
  pays         text not null check (pays in ('US')),
  region       text not null check (length(region) between 2 and 60),   -- comme clients.region (lieux.js)
  fuseau       text not null,                                           -- nom IANA, vérifié à la saisie
  preuve       text not null check (length(preuve) >= 10),
  verifie_par  uuid not null,
  verifie_le   timestamptz not null default now(),
  primary key (pays, region)
);
alter table public.communication_fuseaux_regions enable row level security;
revoke all on public.communication_fuseaux_regions from anon, authenticated, service_role;

create table if not exists public.communication_fuseaux_clients (
  client_id    uuid primary key references public.clients (id) on delete cascade,
  fuseau       text not null,                                           -- nom IANA, vérifié à la saisie
  source       text not null check (source in ('client', 'equipe')),
  pays         text not null,                                           -- pays et région au moment de la
  region       text not null,                                           -- déclaration : changés = caduc
  auteur_id    uuid,
  cree_le      timestamptz not null default now()
);
alter table public.communication_fuseaux_clients enable row level security;
revoke all on public.communication_fuseaux_clients from anon, authenticated, service_role;

-- Un nom de fuseau que le serveur connaît vraiment (pas d'abréviation, pas de décalage fixe).
create or replace function public.communication_fuseau_valide(p_fuseau text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_fuseau ~ '^[A-Z][A-Za-z_]+(/[A-Za-z0-9_+-]+){1,2}$'
     and exists (select 1 from pg_catalog.pg_timezone_names z where z.name = p_fuseau)
$$;

create or replace function public.communication_fuseau(p_client uuid, p_canal text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  cl record;
  v_declare text;
  v_territoire text;
begin
  select c.pays, c.region into cl from public.clients c where c.id = p_client and c.supprime_le is null;
  if not found then
    return null;
  end if;
  select f.fuseau into v_declare from public.communication_fuseaux_clients f
   where f.client_id = p_client and f.pays = cl.pays and f.region = cl.region;
  -- Les noms sont vérifiés à l'ÉCRITURE (communication_fuseau_valide lit pg_timezone_names,
  -- trop coûteux pour chaque destinataire) ; un nom devenu inconnu du serveur fait renvoyer
  -- null par communication_prochaine_fenetre (43 §2) : l'envoi est écarté, jamais deviné.
  if v_declare is not null then
    return v_declare;
  end if;
  if p_canal = 'whatsapp' then
    v_territoire := public.communication_territoire(public.communication_cible(p_client, 'whatsapp'));
    if v_territoire is distinct from cl.pays then
      return null;                                       -- numéro d'un autre territoire : fuseau à déclarer
    end if;
  end if;
  return case cl.pays
           when 'HT' then 'America/Port-au-Prince'
           when 'DO' then 'America/Santo_Domingo'
           when 'US' then (select r.fuseau from public.communication_fuseaux_regions r
                            where r.pays = 'US' and r.region = cl.region)
         end;
end;
$$;


-- 12. Conservation, anonymisation et effacement (revue 1.1, C5) -------------------------------------
-- 12.1 La politique : une durée par catégorie, NULL tant que le juriste ne l'a pas fixée
-- (BLOQUÉ). Sans durée, AUCUNE purge automatique ne tourne : la conservation n'est pas
-- « indéfinie par décision », elle est « en attente de décision ». Les durées proposées au
-- juriste sont dans COMMUNICATION_CENTER_SECURITY.md (jamais appliquées d'office).
-- Phase 1.3 (correction 5) : une catégorie de plus, « empreintes » — le SECOND temps de la
-- conservation. L'anonymisation retire le lien au compte, mais l'empreinte HMAC du contact
-- reste une donnée pseudonyme (le propriétaire du poivre peut la recalculer). Elle n'est gardée
-- que pour ce qu'elle prouve (consentement donné, désinscription à respecter), et effacée à
-- l'échéance de « empreintes » — BLOQUÉE, comme les autres, tant que le juriste ne l'a pas
-- fixée. Une suppression ACTIVE (désinscription à respecter) n'est jamais effacée par
-- l'échéance : seules les suppressions LEVÉES le sont.
create table if not exists public.communication_conservation (
  categorie           text primary key check (categorie in (
                        'consentements', 'confirmations', 'campagnes', 'destinataires', 'envois',
                        'evenements_fournisseur', 'fenetres_whatsapp', 'suppressions', 'erreurs',
                        'empreintes')),
  duree_jours         integer check (duree_jours is null or duree_jours between 1 and 7300),
  apres               text not null default 'anonymiser' check (apres in ('anonymiser', 'effacer')),
  base_juridique      text,
  reference_juridique text,
  regle_par           uuid,
  regle_le            timestamptz,
  check (duree_jours is null or (reference_juridique is not null and regle_par is not null))
);
insert into public.communication_conservation (categorie, apres) values
  ('consentements', 'anonymiser'), ('confirmations', 'effacer'), ('campagnes', 'anonymiser'),
  ('destinataires', 'effacer'), ('envois', 'anonymiser'), ('evenements_fournisseur', 'effacer'),
  ('fenetres_whatsapp', 'effacer'), ('suppressions', 'anonymiser'), ('erreurs', 'effacer'),
  ('empreintes', 'effacer')
on conflict (categorie) do nothing;
alter table public.communication_conservation enable row level security;
revoke all on public.communication_conservation from anon, authenticated, service_role;

-- 12.2 Les demandes de purge : demandées par un administrateur (communications.manage), ou
-- notées sur demande d'une personne (droit d'effacement, communications.consents), APPROUVÉES
-- par un AUTRE administrateur (communications.approve, quatre yeux obligatoires ici), puis
-- exécutées par la fonction de purge. Le journal garde la preuve de l'opération (qui, quand,
-- quoi, combien de lignes), jamais les données effacées.
create table if not exists public.communication_demandes_purge (
  id             bigint generated always as identity primary key,
  type           text not null check (type in ('echeance', 'personne')),
  categorie      text references public.communication_conservation (categorie),
  client_id      uuid,                                   -- type « personne » ; vidé après exécution (1.3.1)
  -- 1.3.1 (IR-07) : empreintes des contacts de la personne, prises au moment de la suppression
  -- du compte (old.* du déclencheur), avant qu'ils ne soient vidés ; effacées après exécution
  empreintes     text[],
  motif          text not null check (length(motif) between 5 and 300),
  demandee_par   uuid not null,
  demandee_le    timestamptz not null default now(),
  statut         text not null default 'demandee' check (statut in ('demandee', 'approuvee', 'refusee', 'executee')),
  approuvee_par  uuid,
  approuvee_le   timestamptz,
  executee_le    timestamptz,
  check ((type = 'echeance' and categorie is not null)
         or (type = 'personne' and (client_id is not null or statut = 'executee'))),
  check (approuvee_par is null or approuvee_par <> demandee_par)
);
alter table public.communication_demandes_purge enable row level security;
revoke all on public.communication_demandes_purge from anon, authenticated, service_role;

create table if not exists public.communication_journal_purges (
  id          bigint generated always as identity primary key,
  demande_id  bigint not null references public.communication_demandes_purge (id),
  table_nom   text not null,
  operation   text not null check (operation in ('anonymiser', 'effacer')),
  lignes      integer not null,
  avant       timestamptz,
  execute_par uuid,
  execute_le  timestamptz not null default now()
);
alter table public.communication_journal_purges enable row level security;
revoke all on public.communication_journal_purges from anon, authenticated, service_role;

-- 12.3 L'immuabilité, avec UNE exception : une purge approuvée en cours dans CETTE transaction.
-- La fonction de purge pose goship.purge_demande ; le déclencheur vérifie que la demande existe
-- et qu'elle est approuvée. Une page ne peut pas poser ce réglage (elle n'appelle que des RPC) ;
-- le propriétaire de la base, dans le SQL Editor, le pourrait — comme il pourrait retirer le
-- déclencheur : limite assumée et documentée.
create or replace function public.communication_immuable()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_demande text := nullif(current_setting('goship.purge_demande', true), '');
begin
  if v_demande is not null and v_demande ~ '^[0-9]{1,18}$'
     and exists (select 1 from public.communication_demandes_purge d
                  where d.id = v_demande::bigint and d.statut = 'approuvee') then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  raise exception 'IMMUTABLE_RECORD' using
    detail = 'Cette ligne est une preuve : elle ne se modifie ni ne s''efface hors d''une purge approuvée.',
    hint = 'goship';
end;
$$;
drop trigger if exists communication_consentements_immuable on public.communication_consentements;
create trigger communication_consentements_immuable
  before update or delete on public.communication_consentements
  for each row execute function public.communication_immuable();
drop trigger if exists communication_journal_purges_immuable on public.communication_journal_purges;
create trigger communication_journal_purges_immuable
  before update or delete on public.communication_journal_purges
  for each row execute function public.communication_immuable();

-- 12.4 La purge. Échéance : refusée tant que la durée de la catégorie est BLOQUÉE (null).
-- Personne (Phase 1.3, correction 5 — inventaire complet : PHASE_1_3_TECHNICAL_CORRECTIONS §5) :
--   · verrou N2 du client d'abord : aucun envoi vers lui ne peut se valider pendant la purge ;
--   · ses empreintes de contact sont RECUEILLIES AVANT toute anonymisation (contact actuel,
--     consentements, confirmations, envois, audiences) pour retrouver ce qui n'a pas de
--     client_id (fenêtres WhatsApp) ;
--   · consentements : client_id, contexte, motif, auteur effacés ; action, dates, version du
--     texte et empreinte gardées comme PREUVE MINIMALE jusqu'à l'échéance « empreintes »
--     (BLOQUÉE, juriste) ;
--   · confirmations, fuseau déclaré, liste d'essai, fenêtres WhatsApp : effacés ;
--   · envois, audiences, retours des fournisseurs : liens et identifiants indirects effacés
--     (client, contact, identifiant du fournisseur, requête, empreinte du contenu) — avant 1.3,
--     l'empreinte du contact, la requête et l'empreinte du contenu restaient ;
--   · suppressions : lien au compte effacé, empreinte GARDÉE (elle empêche de lui écrire de
--     nouveau), jusqu'à l'échéance « empreintes » si elle a été levée.
-- Ici : « consentements » et « confirmations » ; les autres catégories et la suite de
-- l'effacement d'une personne sont dans 43 §12 (communication_purger_autres,
-- communication_purger_personne_suite), appelées d'ici, avec le même journal.
create or replace function public.executer_purge_communication(p_demande bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.communication_demandes_purge;
  c public.communication_conservation;
  v_avant timestamptz;
  v_n integer;
  v_empreintes text[];
begin
  perform public.exiger_permission('communications.manage');
  select * into d from public.communication_demandes_purge where id = p_demande for update;
  if not found or d.statut <> 'approuvee' then
    perform public.erreur_metier('PURGE_NOT_APPROVED', 'Demande inconnue ou pas encore approuvée par un autre administrateur.');
  end if;
  perform set_config('goship.purge_demande', d.id::text, true);
  perform set_config('goship.motif', 'purge:' || d.id || ' ' || d.motif, true);

  if d.type = 'echeance' then
    select * into c from public.communication_conservation where categorie = d.categorie;
    if c.duree_jours is null then
      perform public.erreur_metier('RETENTION_BLOCKED', 'Durée de conservation non fixée par le juriste : aucune purge.');
    end if;
    v_avant := now() - make_interval(days => c.duree_jours);
    if d.categorie = 'consentements' then
      update public.communication_consentements
         set client_id = null, contexte = '{}'::jsonb, motif = null, auteur_id = null, anonymise_le = now()
       where cree_le < v_avant and anonymise_le is null;
      get diagnostics v_n = row_count;
      insert into public.communication_journal_purges (demande_id, table_nom, operation, lignes, avant, execute_par)
      values (d.id, 'communication_consentements', 'anonymiser', v_n, v_avant, auth.uid());
    elsif d.categorie = 'confirmations' then
      -- 1.3.1 (revue n° 2, IR2-05) : les e-mails de confirmation jamais partis (interrupteur éteint)
      -- sont d'abord écartés ; un e-mail EN COURS de remise fait refuser la purge (à refaire)
      if exists (select 1 from public.communication_envois e join public.communication_confirmations f on f.id = e.confirmation_id
                  where f.cree_le < v_avant and e.statut = 'traitement') then
        perform public.erreur_metier('PURGE_RETRY', 'Un e-mail de confirmation est en cours de remise : réessayez dans quelques minutes.');
      end if;
      update public.communication_envois e set statut = 'supprime', code_erreur = 'CONFIRMATION_PURGEE', maj_le = now()
        from public.communication_confirmations f
       where f.id = e.confirmation_id and f.cree_le < v_avant and e.statut in ('attente', 'nouvel_essai');
      delete from public.communication_confirmations where cree_le < v_avant;
      get diagnostics v_n = row_count;
      insert into public.communication_journal_purges (demande_id, table_nom, operation, lignes, avant, execute_par)
      values (d.id, 'communication_confirmations', 'effacer', v_n, v_avant, auth.uid());
    else
      -- Les autres catégories : 43 §12 (communication_purger_autres), même journal, même règle
      perform public.communication_purger_autres(d.id, d.categorie, v_avant);
    end if;
  else
    perform public.communication_verrou('client:' || d.client_id);                 -- N2
    -- 1.3.1 (revue n° 2, IR2-07) : N3 aussi (e-mail puis WhatsApp) — aucune désinscription ni
    -- confirmation de cette personne ne peut écrire pendant la purge
    perform public.communication_verrou('consentement:' || d.client_id || ':email');
    perform public.communication_verrou('consentement:' || d.client_id || ':whatsapp');
    if exists (select 1 from public.communication_envois e where e.client_id = d.client_id and e.statut = 'traitement') then
      perform public.erreur_metier('PURGE_RETRY', 'Un message à cette personne est en cours de remise : réessayez dans quelques minutes.');
    end if;
    -- Les empreintes de la personne, recueillies AVANT d'effacer les liens (C5). 1.3.1 (IR-07) :
    -- aussi celles prises par le déclencheur à la suppression du compte (d.empreintes), des
    -- audiences et des suppressions — le profil est déjà vidé à ce moment-là.
    select coalesce(array_agg(distinct x.e) filter (where x.e is not null), '{}') into v_empreintes
      from (select public.communication_empreinte('email', public.communication_cible(d.client_id, 'email')) e
            union all select public.communication_empreinte('whatsapp', public.communication_cible(d.client_id, 'whatsapp'))
            union all select unnest(coalesce(d.empreintes, '{}'))
            union all select k.cible_empreinte from public.communication_consentements k where k.client_id = d.client_id
            union all select f.cible_empreinte from public.communication_confirmations f where f.client_id = d.client_id
            union all select dd.cible_empreinte from public.communication_destinataires dd where dd.client_id = d.client_id
            union all select s.cible_empreinte from public.communication_suppressions s where s.client_id = d.client_id
            union all select e2.cible_empreinte from public.communication_envois e2 where e2.client_id = d.client_id) x;
    perform public.communication_purger_personne_suite(d.id, d.client_id, v_empreintes);   -- 43 §12
    update public.communication_consentements
       set client_id = null, contexte = '{}'::jsonb, motif = null, auteur_id = null, anonymise_le = now()
     where client_id = d.client_id;
    get diagnostics v_n = row_count;
    insert into public.communication_journal_purges (demande_id, table_nom, operation, lignes, execute_par)
    values (d.id, 'communication_consentements', 'anonymiser', v_n, auth.uid());
    delete from public.communication_confirmations where client_id = d.client_id;
    get diagnostics v_n = row_count;
    insert into public.communication_journal_purges (demande_id, table_nom, operation, lignes, execute_par)
    values (d.id, 'communication_confirmations', 'effacer', v_n, auth.uid());
    delete from public.communication_fuseaux_clients where client_id = d.client_id;
    get diagnostics v_n = row_count;
    insert into public.communication_journal_purges (demande_id, table_nom, operation, lignes, execute_par)
    values (d.id, 'communication_fuseaux_clients', 'effacer', v_n, auth.uid());
  end if;

  -- 1.3.1 (IR-07) : la demande exécutée ne garde plus ni la personne ni ses empreintes ; une
  -- demande ouverte d'office (demandeur = la personne) perd aussi ce lien
  update public.communication_demandes_purge
     set statut = 'executee', executee_le = now(), client_id = null, empreintes = null,
         demandee_par = case when type = 'personne' and demandee_par = d.client_id
                             then '00000000-0000-0000-0000-000000000000'::uuid else demandee_par end
   where id = d.id;
  perform set_config('goship.purge_demande', '', true);
  perform public.auditer('communication.purge', 'communication_demande_purge', d.id::text, null,
                         jsonb_build_object('type', d.type, 'categorie', d.categorie));
  return jsonb_build_object('ok', true, 'demande', d.id);
end;
$$;


-- 13. Droits -----------------------------------------------------------------------------------------
-- Rien de ce fichier n'est ouvert à un visiteur. executer_purge_communication est ouverte aux
-- comptes connectés et refuse elle-même sans communications.manage ni demande approuvée.
revoke execute on function public.communication_jour(timestamptz) from public, anon, authenticated, service_role;
revoke execute on function public.communication_normaliser(text, text) from public, anon, authenticated, service_role;
revoke execute on function public.communication_empreinte(text, text) from public, anon, authenticated, service_role;
revoke execute on function public.communication_cible(uuid, text) from public, anon, authenticated, service_role;
revoke execute on function public.communication_masque(text, text) from public, anon, authenticated, service_role;
revoke execute on function public.communication_verrou(text) from public, anon, authenticated, service_role;
revoke execute on function public.communication_verrou_interrupteurs(boolean) from public, anon, authenticated, service_role;
revoke execute on function public.communication_interrupteur_ferme(public.communication_reglages, text, text, text) from public, anon, authenticated, service_role;
revoke execute on function public.communication_autoriser_sortie(text, text) from public, anon, authenticated, service_role;
revoke execute on function public.communication_sortie_autorisee(text, text) from public, anon, authenticated, service_role;
revoke execute on function public.communication_fuseau_valide(text) from public, anon, authenticated, service_role;
revoke execute on function public.communication_fuseau(uuid, text) from public, anon, authenticated, service_role;
revoke execute on function public.communication_arret_permanent() from public, anon, authenticated, service_role;
revoke execute on function public.communication_territoire(text) from public, anon, authenticated, service_role;
revoke execute on function public.communication_etat_consentement(uuid, text) from public, anon, authenticated, service_role;
revoke execute on function public.communication_consentement_actuel(uuid, text) from public, anon, authenticated, service_role;
revoke execute on function public.communication_supprimee(text, text) from public, anon, authenticated, service_role;
revoke execute on function public.communication_est_essai(uuid, text) from public, anon, authenticated, service_role;
revoke execute on function public.communication_brevo_disponible() from public, anon, authenticated, service_role;
revoke execute on function public.communication_immuable() from public, anon, authenticated, service_role;
revoke execute on function public.executer_purge_communication(bigint) from public, anon;
grant execute on function public.executer_purge_communication(bigint) to authenticated;

-- 13 bis. Les permissions (déplacées ici en 1.3.1) -----------------------------------------------------------------
-- supabase.sql fait foi. Cette fonction existe en TROIS copies identiques aujourd'hui
-- (supabase.sql, supabase-naissance.sql, supabase-suivi-externe.sql) et en une copie démo
-- (PERMISSIONS_DES_ROLES, assets/js/api.js). En Phase 2, les QUATRE copies SQL et la copie
-- démo reçoivent ensemble les sept permissions ci-dessous, mot pour mot (revue 1.1, H10) :
-- sinon relancer supabase-naissance.sql ou supabase-suivi-externe.sql après ce fichier
-- retirerait les permissions du Centre, et essai-programmes.py, essai-suivi-externe.py,
-- essai-permissions.py/.js échoueraient. Un essai de Phase 2 compare les cinq copies.
--
--   communications.view      voir le Centre, l'historique, les statistiques, les dépenses
--   communications.create    brouillons (campagnes, modèles, segments), soumettre, retirer,
--                            programmer, remettre en brouillon avant lancement, annuler un
--                            brouillon ou une soumission
--   communications.test      envoyer un essai, aux seuls destinataires d'essai
--   communications.pause     mettre en pause une campagne programmée ou en cours
--   communications.approve   approuver ou refuser campagnes et modèles ; reprendre ; annuler
--                            une campagne approuvée ; approuver une demande de purge ;
--                            relancer un message incertain ou mort
--   communications.manage    réglages, interrupteurs, plafonds, quotas, tarifs, indicatifs,
--                            liste d'essai, textes de consentement, identité légale et
--                            adresse postale (après décision du CEO), demandes de purge,
--                            levée d'une suppression
--   communications.consents  lire l'historique de consentement d'un client ; noter un
--                            RETRAIT qu'il demande ; ajouter une suppression manuelle
--                            (jamais un accord à sa place)
-- Gérant : view, create, test, pause, consents. Employé et client : aucune.
-- La double authentification (aal2) s'applique d'elle-même : permissions de l'équipe.
create or replace function public.permissions_du_role(p_role text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select case p_role
    when 'admin' then array[
      'clients.view', 'clients.create', 'clients.edit',
      'shipments.view', 'shipments.create', 'shipments.edit', 'shipments.delete',
      'shipments.scan', 'shipments.change_status', 'shipments.correct', 'shipments.view_history',
      'invoices.view', 'invoices.create', 'invoices.edit', 'invoices.cancel',
      'payments.view', 'payments.create', 'payments.cancel',
      'reports.view', 'reports.create', 'reports.edit', 'reports.delete',
      'users.view', 'roles.manage', 'settings.manage', 'audit_logs.view',
      'birthdays.view', 'birthdays.manage', 'programs.view', 'programs.manage', 'points.adjust',
      'tracking.view', 'tracking.manage',
      'communications.view', 'communications.create', 'communications.test', 'communications.pause',
      'communications.approve', 'communications.manage', 'communications.consents']
    when 'gerant' then array[
      'clients.view', 'clients.create', 'clients.edit',
      'shipments.view', 'shipments.create', 'shipments.edit',
      'shipments.scan', 'shipments.change_status', 'shipments.correct', 'shipments.view_history',
      'invoices.view', 'invoices.create', 'invoices.edit', 'invoices.cancel',
      'payments.view', 'payments.create', 'payments.cancel',
      'reports.view', 'reports.create',
      'users.view',
      'birthdays.view', 'programs.view',
      'tracking.view',
      'communications.view', 'communications.create', 'communications.test', 'communications.pause',
      'communications.consents']
    when 'employe' then array[
      'clients.view', 'clients.create',
      'shipments.view', 'shipments.create', 'shipments.edit',
      'shipments.scan', 'shipments.change_status', 'shipments.view_history',
      'invoices.view', 'payments.view',
      'tracking.view']
    when 'client' then array[
      'clients.view:own', 'clients.edit:own',
      'shipments.view:own', 'shipments.view_history:own',
      'invoices.view:own', 'payments.view:own']
    else array[]::text[]
  end
$$;


-- 14. Contrôle (Phase 2) -------------------------------------------------------------------------------
-- Résultat attendu, en une ligne (après CE fichier seul) : tables 19 | permissions_admin 7 | permissions_gerant 5 |
-- employe 0 | tarifs 0 | indicatifs_autorises 0 | campagnes_actives false
-- (18 = les 14 de la Phase 1.2 + communication_issues_http, communication_debit_minute,
--  communication_fuseaux_regions, communication_fuseaux_clients ; 19 avec communication_arret, 1.3.1)
select (select count(*) from pg_tables where schemaname = 'public' and tablename like 'communication\_%') as tables,
       (select count(*) from unnest(public.permissions_du_role('admin')) p where p like 'communications.%') as permissions_admin,
       (select count(*) from unnest(public.permissions_du_role('gerant')) p where p like 'communications.%') as permissions_gerant,
       (select count(*) from unnest(public.permissions_du_role('employe')) p where p like 'communications.%') as employe,
       (select count(*) from public.communication_tarifs) as tarifs,
       (select count(*) from public.communication_indicatifs where autorise_marketing) as indicatifs_autorises,
       (select campagnes_actives from public.communication_reglages) as campagnes_actives;
-- ===== FIN DU CONTENU INERTE =====
$brouillon_goship_non_executable$ as brouillon_non_executable;
