-- =============================================================================
-- BROUILLON — CENTRE DE COMMUNICATION — NE PAS EXÉCUTER
-- Version Phase 1.3.1 (18/11/2026) — garde à trois couches : voir l'en-tête de
-- 40-supabase-communications-fondation.sql (bloc DO, puis TOUT le contenu dans une chaîne inerte).
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
-- Goship Express — Centre de communication : la file commerciale, son travailleur, l'habillage
-- des e-mails commerciaux, les fournisseurs, les retours des fournisseurs, STOP, désinscription,
-- rapprochement des issues incertaines, purge des autres catégories. À la suite de 42-…-campagnes.
--
-- Deux files, deux travailleurs, deux priorités :
--   · transactionnel (EXISTANT, inchangé) : notification_envois, traiter_notifications(),
--     tâche goship-notifications ;
--   · commercial (CE FICHIER) : communication_envois, traiter_communications(), tâche
--     goship-communications, créée INACTIVE, qui CÈDE la place quand le transactionnel a du retard.
--
-- Identités d'envoi SÉPARÉES (revue 1.1, C4) : le commercial n'utilise QUE ses propres
-- réglages du coffre (communication_email_cle_api, communication_expediteur, communication_nom,
-- communication_email_fournisseur ; communication_whatsapp_jeton, communication_whatsapp_numero_id,
-- communication_whatsapp_waba_id). Aucun repli sur les clés, l'expéditeur ou le numéro du
-- transactionnel : réglage absent = envoi refusé. expedier_envoi et courriel_gabarit ne sont
-- PAS modifiés (exigence 7 du CEO).
--
-- Garanties :
--   · clé unique par campagne, client et canal : jamais deux messages ;
--   · UN envoi par transaction (Phase 1.3, C1, C2) : la procédure traiter_communications valide
--     (COMMIT) après chaque envoi ; les verrous sont pris dans l'ordre unique de 40 §3
--     (interrupteurs N0 partagé → campagne N1 → client N2 → consentement N3 → envoi N4 →
--     compteurs N5) et relâchés à chaque COMMIT ;
--   · arrêt d'urgence, interrupteur général et interrupteurs des canaux RELUS sous N0 pour
--     chaque envoi, et une dernière fois sous N5 (C1) ;
--   · dépense, débit par minute et quota Brevo RÉSERVÉS avant l'appel, sous N5, recalculés à
--     chaque envoi (C3) ;
--   · consentement CONFIRMÉ, suppression, contact inchangé depuis le gel, liste d'essai, heure
--     locale RÉELLE (C6), fréquence, modèle Meta conforme : revérifiés juste avant l'envoi ;
--   · issue inconnue = « incertain », JAMAIS renvoyé automatiquement (revue 1.1, H8) ; une 5xx
--     est une issue inconnue (C4) ;
--   · nouvel essai automatique SEULEMENT sur un refus prouvé sûr (table communication_issues_http,
--     vide par défaut) ; 3 au plus ; au-delà : « abandon » ;
--   · un STOP, une plainte, une désinscription ne sont JAMAIS refusés pour leur âge (C6) ;
--   · pg_net n'envoie une requête qu'APRÈS le COMMIT de la transaction qui l'a demandée : une
--     transaction annulée (erreur, interblocage, délai de verrou) n'envoie rien.
-- =============================================================================


-- 1. La file commerciale -----------------------------------------------------------------------
-- Deux natures : « campagne » (un message d'une campagne approuvée) et « confirmation » (l'e-mail
-- qui porte le lien de confirmation d'une demande de consentement, 41).
-- Statuts :
--   attente       à envoyer à prochain_essai_le                               (Pending)
--   traitement    remis à pg_net, réponse pas encore lue                      (Processing)
--   envoye        accepté par le fournisseur (≠ remis)                        (Sent)
--   livre         remise confirmée par le fournisseur                         (Delivered)
--   lu            lecture confirmée (WhatsApp seulement, si le client l'autorise) (Read)
--   echec         refus définitif du fournisseur                              (Failed)
--   nouvel_essai  refus temporaire sûr, nouvel essai prévu                    (Retrying)
--   supprime      écarté juste avant l'envoi (retrait, STOP, contact changé…) (Suppressed)
--   annule        campagne annulée avant l'envoi
--   abandon       3 refus temporaires : file des messages morts               (dead letter)
--   incertain     issue inconnue (délai dépassé, réseau) : peut-être parti    (Uncertain)
create table if not exists public.communication_envois (
  id                bigint generated always as identity primary key,
  nature            text not null default 'campagne' check (nature in ('campagne', 'confirmation')),
  campagne_id       uuid references public.communication_campagnes (id),
  destinataire_id   bigint references public.communication_destinataires (id),
  -- 1.3.1 (IR-01) : « on delete set null » — l'effacement d'une confirmation (purge) ne bute plus
  -- sur l'envoi qui la cite (avant : violation de clé étrangère, purge impossible)
  confirmation_id   bigint references public.communication_confirmations (id) on delete set null,
  client_id         uuid,
  canal             text not null check (canal in ('email', 'whatsapp')),
  -- 1.3.1 (IR-02) : la clé ne contient PLUS l'identifiant du client (il survivait à l'effacement) :
  -- campagne:<campagne>:<destinataire> | confirmation:<id> ; « efface:<id> » après une purge
  cle               text not null unique,
  cible_empreinte   text,                                     -- le contact EXACT visé (revue 1.1, H5)
  territoire        text,
  statut            text not null default 'attente' check (statut in (
                      'attente', 'traitement', 'envoye', 'livre', 'lu', 'echec',
                      'nouvel_essai', 'supprime', 'annule', 'abandon', 'incertain')),
  -- 1.3.1 (IR-06) : choisi UNE fois (au lancement ou à la mise en file) et seul utilisé à l'appel
  fournisseur       text not null check (fournisseur in ('meta', 'brevo', 'resend')),
  tentative         integer not null default 0,
  prochain_essai_le timestamptz not null default now(),
  verrouille_le     timestamptz,
  -- Heure de remise à pg_net, JAMAIS effacée (Phase 1.3) : avant, la fréquence et la limite du
  -- numéro WhatsApp comptaient coalesce(envoye_le, verrouille_le), or verrouille_le est remis à
  -- vide à la lecture de la réponse — un message « incertain » cessait d'être compté.
  remis_le          timestamptz,
  -- 1.3.1 (revue n° 2, IR2-01) : premier instant où NOUS avons vu la requête absente de la file de
  -- pg_net. Le délai HTTP de pg_net court à partir de sa prise en charge, que nous ne connaissons
  -- pas : on part de cette observation (toujours POSTÉRIEURE ou égale à la prise en charge, donc
  -- prudente). Tant qu'elle manque, la requête compte comme « en transmission ».
  sortie_file_vue_le timestamptz,
  -- La requête pg_net n'est JAMAIS effacée tant qu'elle n'est pas résolue (IR2-02)
  requete           bigint,
  message_id        text,
  empreinte_contenu text,                                     -- SHA-256 du contenu réellement envoyé
  cout_estime_usd   numeric(10, 5) not null default 0,
  code_erreur       text,
  incertain_clos_le timestamptz,                              -- 72 h sans preuve : reste incertain
  relance_de        bigint references public.communication_envois (id),
  cree_le           timestamptz not null default now(),
  envoye_le         timestamptz,
  livre_le          timestamptz,
  lu_le             timestamptz,
  maj_le            timestamptz not null default now(),
  check (nature <> 'campagne' or (campagne_id is not null and destinataire_id is not null)),
  check (nature <> 'confirmation' or confirmation_id is not null
         or statut not in ('attente', 'traitement', 'nouvel_essai'))   -- confirmation effacée : envoi clos
);
create index if not exists communication_envois_dus_idx
  on public.communication_envois (prochain_essai_le) where statut in ('attente', 'nouvel_essai');
create index if not exists communication_envois_en_cours_idx
  on public.communication_envois (verrouille_le) where statut = 'traitement';
create index if not exists communication_envois_message_idx
  on public.communication_envois (fournisseur, message_id) where message_id is not null;
create index if not exists communication_envois_client_idx on public.communication_envois (client_id, envoye_le desc);
create index if not exists communication_envois_campagne_idx on public.communication_envois (campagne_id, statut);
create index if not exists communication_envois_destinataire_idx on public.communication_envois (destinataire_id);
create index if not exists communication_envois_confirmation_idx on public.communication_envois (confirmation_id) where confirmation_id is not null;
create index if not exists communication_envois_auth_idx
  on public.communication_envois (fournisseur, maj_le) where code_erreur like 'AUTH_FOURNISSEUR%';
create index if not exists communication_envois_incertains_idx on public.communication_envois (maj_le) where statut = 'incertain' and incertain_clos_le is null;
alter table public.communication_envois enable row level security;
revoke all on public.communication_envois from anon, authenticated, service_role;


-- 2. Heures et fréquence (revue 1.1, H4 ; Phase 1.3, C6) ------------------------------------------
-- Heure locale RÉELLE du destinataire : communication_fuseau(client, canal) (40 §11 bis) — un
-- fuseau déclaré, Haïti, République dominicaine, ou l'État américain s'il n'a qu'un fuseau
-- enregistré avec sa preuve ; sinon INCONNU (null) et RIEN ne part. Avant 1.3, tout ce qui
-- n'était ni HT ni DO recevait l'heure de New York. Fenêtre et fréquence à confirmer par le
-- juriste (FTSA, TCPA) : ce sont des réglages, pas des valeurs juridiques.
-- La fenêtre : l'heure locale doit être ≥ heure_debut, et la fin de la marge (marge_fenetre_min)
-- doit tomber AVANT heure_fin — pg_net envoie quelques secondes après la validation.
-- Renvoie now() si l'envoi peut partir maintenant, l'instant (UTC) du prochain début de fenêtre
-- sinon, null si le fuseau est inconnu. Changements d'heure : le calcul passe toujours par le
-- NOM du fuseau (« at time zone »), donc par les règles IANA de la date concernée ; 9 h et 19 h
-- existent tous les jours dans ces fuseaux (les changements d'heure se font la nuit).
create or replace function public.communication_prochaine_fenetre(p_client uuid, p_canal text)
returns timestamptz
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  r public.communication_reglages;
  v_tz text := public.communication_fuseau(p_client, p_canal);
  v_local timestamp;
  v_debut timestamp;
  v_fin timestamp;
begin
  if v_tz is null then
    return null;
  end if;
  select * into r from public.communication_reglages;
  begin
    v_local := now() at time zone v_tz;
  exception when invalid_parameter_value then
    return null;                                             -- nom de fuseau inconnu du serveur : écarté
  end;
  v_debut := v_local::date + make_interval(hours => r.heure_debut);
  v_fin := v_local::date + make_interval(hours => r.heure_fin);
  if v_local >= v_debut and v_local + make_interval(mins => r.marge_fenetre_min) < v_fin then
    return now();
  end if;
  return (case when v_local < v_debut then v_debut else v_debut + interval '1 day' end) at time zone v_tz;
end;
$$;

-- Fréquence atteinte ? Compte AUSSI les messages en cours, incertains et refusés après remise
-- (on ne sait pas toujours s'ils sont arrivés) : heure de remise à pg_net (remis_le, jamais
-- effacée). Appelée SOUS le verrou du client (N2), dans la transaction de l'envoi.
create or replace function public.communication_frequence_atteinte(p_client uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select (select count(*) from public.communication_envois e
           where e.client_id = p_client and e.nature = 'campagne' and e.remis_le is not null
             and e.statut in ('traitement', 'envoye', 'livre', 'lu', 'incertain')
             and coalesce(e.envoye_le, e.remis_le) > now() - interval '24 hours') >= r.frequence_max_jour
      or (select count(*) from public.communication_envois e
           where e.client_id = p_client and e.nature = 'campagne' and e.remis_le is not null
             and e.statut in ('traitement', 'envoye', 'livre', 'lu', 'incertain')
             and coalesce(e.envoye_le, e.remis_le) > now() - interval '7 days') >= r.frequence_max_semaine
  from public.communication_reglages r
$$;


-- 3. La réservation (revue 1.1, H1, M7, H11 ; Phase 1.3, C1, C3) --------------------------------------
-- Appelée par communication_traiter_un (§8), qui tient déjà N0 (partagé), N1 (la campagne),
-- N2, N3 et N4 (l'envoi). Prend N5 — le verrou GLOBAL des compteurs — puis, dans cet ordre :
--   1. relit les réglages : un arrêt écrit SANS attendre N0 (repli d'arreter_communications)
--      est vu ici (dernier contrôle avant l'appel) ;
--   2. plafonds de la campagne (ligne déjà verrouillée en N1) ;
--   3. plafonds GLOBAUX du jour (messages, dollars) ;
--   4. débit GLOBAL par minute (tous travailleurs, tous canaux) ;
--   5. limite quotidienne de destinataires du numéro WhatsApp commercial (valeur de Meta, H11) ;
--   6. quota Brevo RECALCULÉ ICI (communication_brevo_disponible) : plus d'estimation gardée en
--      mémoire par un travailleur. N5 est tenu jusqu'au COMMIT de l'envoi : le travailleur
--      suivant ne le prend qu'APRÈS, et sa requête suivante voit la réservation validée. La
--      somme des réservations ne peut donc pas dépasser le disponible (preuve : TEST_PLAN T-04).
-- Renvoie null si l'envoi peut partir (tout est compté), sinon le code de ce qui bloque.
-- Réconciliation : une réservation n'existe que dans la transaction de l'envoi ; si celle-ci
-- est annulée (erreur, interblocage, délai), la réservation l'est aussi — il n'y a pas de
-- réservation « expirée » à rattraper. Un refus du fournisseur, un « incertain » ou un nouvel
-- essai NE RENDENT PAS la réservation : l'estimation reste AU-DESSUS de la réalité (prudent).
-- La vérification du compte réel chez Brevo est manuelle (verifier_quota_brevo, valable
-- brevo_quota_validite_jours) ; une lecture automatique demandera une autorisation (Phase 3).
create or replace function public.communication_reserver(p_envoi public.communication_envois, p_cout numeric)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.communication_reglages;
  c public.communication_campagnes;
  v_jour date := public.communication_jour();
  v_minute timestamptz := date_trunc('minute', clock_timestamp());
  v_messages integer;
  v_cout numeric;
  v_debit integer;
  v_raison text;
begin
  -- 1.3.1 (IR-25) : la sérialisation des compteurs suppose READ COMMITTED (chaque requête voit
  -- ce qui a été validé avant elle) ; on le vérifie au lieu de le supposer
  if current_setting('transaction_isolation') <> 'read committed' then
    raise exception 'ISOLATION_NON_SUPPORTEE';
  end if;
  perform public.communication_verrou('compteurs');                                 -- N5
  select * into r from public.communication_reglages;                              -- relu SOUS N5
  -- Défense de plus (Phase 1.3.1) : la décision a été prise à la porte (N0 partagé tenu jusqu'au
  -- COMMIT, communication_autoriser_sortie) ; cette relecture n'est PAS ce qui rend l'arrêt sûr.
  v_raison := public.communication_interrupteur_ferme(r, (select a.etat from public.communication_arret a),
                                                      p_envoi.nature, p_envoi.canal);
  if v_raison is not null then
    return v_raison;
  end if;

  if p_envoi.nature = 'campagne' then
    select * into c from public.communication_campagnes where id = p_envoi.campagne_id;   -- déjà verrouillée (N1)
    if c.statut is distinct from 'en_cours' then
      return 'CAMPAGNE_PAS_EN_COURS';
    end if;
    if c.messages_reserves + 1 > c.plafond_messages then return 'PLAFOND_CAMPAGNE_MESSAGES'; end if;
    if p_cout > 0 and c.cout_reserve_usd + p_cout > c.plafond_cout_usd then return 'PLAFOND_CAMPAGNE_COUT'; end if;
  end if;

  select coalesce(sum(messages), 0), coalesce(sum(cout_usd), 0) into v_messages, v_cout
    from public.communication_depenses_jour where jour = v_jour;
  if v_messages + 1 > r.plafond_jour_messages then return 'PLAFOND_JOUR_MESSAGES'; end if;
  if p_cout > 0 and v_cout + p_cout > r.plafond_jour_usd then return 'PLAFOND_JOUR_COUT'; end if;

  select coalesce((select envois from public.communication_debit_minute where minute = v_minute), 0) into v_debit;
  if v_debit + 1 > r.debit_max_minute then
    return 'DEBIT_MINUTE';
  end if;

  if p_envoi.canal = 'whatsapp' and (r.whatsapp_destinataires_jour is null or
       (select count(distinct e.client_id) from public.communication_envois e
         where e.canal = 'whatsapp' and e.remis_le is not null
           and e.statut in ('traitement', 'envoye', 'livre', 'lu', 'incertain')
           and coalesce(e.envoye_le, e.remis_le) > now() - interval '24 hours') + 1 > r.whatsapp_destinataires_jour) then
    return 'LIMITE_NUMERO_WHATSAPP';
  end if;

  if p_envoi.canal = 'email' and p_envoi.fournisseur = 'brevo'
     and coalesce((public.communication_brevo_disponible() ->> 'disponible')::integer, 0) < 1 then
    return 'QUOTA_BREVO';
  end if;

  insert into public.communication_depenses_jour (jour, fournisseur, canal, messages, cout_usd)
  values (v_jour, p_envoi.fournisseur, p_envoi.canal, 1, p_cout)
  on conflict (jour, fournisseur, canal) do update
    set messages = public.communication_depenses_jour.messages + 1,
        cout_usd = public.communication_depenses_jour.cout_usd + excluded.cout_usd;
  insert into public.communication_debit_minute (minute, envois) values (v_minute, 1)
  on conflict (minute) do update set envois = public.communication_debit_minute.envois + 1;
  if p_envoi.nature = 'campagne' then
    update public.communication_campagnes
       set messages_reserves = messages_reserves + 1, cout_reserve_usd = cout_reserve_usd + p_cout
     where id = c.id;
  end if;
  return null;
end;
$$;


-- 4. Jetons, textes et habillage ------------------------------------------------------------------
-- 4.1 Le jeton de désinscription : identifiant de l'envoi + HMAC (clé « communication_cle_
-- desinscription »). Clé absente : null, et l'appelant REFUSE l'envoi (revue 1.1, M8). Pas
-- d'expiration (le lien doit marcher au moins 30 jours, CAN-SPAM) ; révocation de tous les
-- liens = changer la clé (les anciens liens renvoient alors vers « connectez-vous »).
create or replace function public.communication_jeton_desinscription(p_envoi bigint)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_cle text := public.lire_reglage('communication_cle_desinscription');
begin
  if coalesce(v_cle, '') = '' then
    return null;
  end if;
  return p_envoi::text || '.' ||
         left(translate(encode(extensions.hmac(p_envoi::text, v_cle, 'sha256'), 'base64'), '+/=', '-_'), 32);
end;
$$;

-- 4.2 Les textes du pied commercial et de l'e-mail de confirmation, quatre langues.
-- TEXTES À FAIRE APPROUVER PAR LE JURISTE avant toute activation (D-F).
create or replace function public.communication_textes_pied(p_langue text)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case p_langue
    when 'en' then jsonb_build_object('raison', 'You receive this offer because you confirmed that you want to receive news from us.',
                                      'desinscrire', 'Unsubscribe', 'expediteur', 'Sender')
    when 'es' then jsonb_build_object('raison', 'Recibe esta oferta porque confirmó que desea recibir nuestras novedades.',
                                      'desinscrire', 'Darse de baja', 'expediteur', 'Remitente')
    when 'ht' then jsonb_build_object('raison', 'Ou resevwa òf sa a paske ou te konfime ou vle resevwa nouvèl nou yo.',
                                      'desinscrire', 'Dezabòne', 'expediteur', 'Moun ki voye l')
    else jsonb_build_object('raison', 'Vous recevez cette offre car vous avez confirmé vouloir recevoir nos nouvelles.',
                            'desinscrire', 'Se désinscrire', 'expediteur', 'Expéditeur')
  end
$$;

create or replace function public.communication_textes_confirmation(p_langue text)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case p_langue
    when 'en' then jsonb_build_object('sujet', 'Confirm that you want to receive our news',
                                      'corps', 'You asked to receive news and offers by e-mail. To confirm, open the link below and press the button. If you did not ask for this, ignore this e-mail: nothing will be sent to you.',
                                      'bouton', 'Confirm')
    when 'es' then jsonb_build_object('sujet', 'Confirme que desea recibir nuestras novedades',
                                      'corps', 'Usted pidió recibir novedades y ofertas por correo. Para confirmar, abra el enlace y pulse el botón. Si no lo pidió, ignore este correo: no se le enviará nada.',
                                      'bouton', 'Confirmar')
    when 'ht' then jsonb_build_object('sujet', 'Konfime ou vle resevwa nouvèl nou yo',
                                      'corps', 'Ou te mande resevwa nouvèl ak òf pa imèl. Pou konfime, louvri lyen an epi peze bouton an. Si se pa ou ki te mande sa, pa okipe imèl sa a : nou p ap voye anyen.',
                                      'bouton', 'Konfime')
    else jsonb_build_object('sujet', 'Confirmez que vous voulez recevoir nos nouvelles',
                            'corps', 'Vous avez demandé à recevoir nos nouvelles et nos offres par e-mail. Pour confirmer, ouvrez le lien ci-dessous et appuyez sur le bouton. Si vous n''avez rien demandé, ignorez cet e-mail : rien ne vous sera envoyé.',
                            'bouton', 'Confirmer')
  end
$$;

create or replace function public.communication_textes_pied_tous()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object('fr', public.communication_textes_pied('fr'), 'en', public.communication_textes_pied('en'),
                            'es', public.communication_textes_pied('es'), 'ht', public.communication_textes_pied('ht'))
$$;

-- 4.3 L'habillage des e-mails COMMERCIAUX (revue 1.1, C1). courriel_gabarit (transactionnel)
-- échappe tout son pied : il n'est donc PAS utilisé ici, et il n'est pas modifié. Cet habillage
-- échappe chaque TEXTE, mais insère le lien de désinscription comme un VRAI lien : l'adresse
-- est échappée pour un attribut (html_echappe) et placée dans href="…". Version : la constante
-- 'habillage-commercial-v1' de communication_environnement_envoi (42) — toute modification de
-- cette fonction change la version et invalide les approbations.
-- Identité légale ou adresse postale absentes (BLOQUÉES, D-G) : null, l'envoi est refusé.
create or replace function public.communication_courriel_commercial(p_langue text, p_sujet text, p_corps text,
                                                                    p_lien_desinscription text, p_identite text,
                                                                    p_adresse text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  t jsonb := public.communication_textes_pied(p_langue);
begin
  if p_lien_desinscription is null or p_lien_desinscription !~ '^https://[A-Za-z0-9.-]+/[A-Za-z0-9._~/?=&%-]+$'
     or coalesce(p_identite, '') = '' or coalesce(p_adresse, '') = '' then
    return null;
  end if;
  return
    '<!doctype html><html lang="' || public.html_echappe(p_langue) || '"><head><meta charset="utf-8">' ||
    '<meta name="viewport" content="width=device-width,initial-scale=1"><title>' || public.html_echappe(p_sujet) || '</title></head>' ||
    '<body style="margin:0;background:#f5f7fb;font-family:Arial,Helvetica,sans-serif;color:#0d2b6b">' ||
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:24px 12px">' ||
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#ffffff;border-radius:14px">' ||
    '<tr><td style="padding:28px 32px;font-size:16px;line-height:1.6">' ||
      replace(public.html_echappe(p_corps), E'\n', '<br>') ||
    '</td></tr>' ||
    '<tr><td style="padding:20px 32px 28px;border-top:1px solid #e7edf9;font-size:13px;line-height:1.6;color:#5b6782">' ||
      public.html_echappe(t ->> 'raison') || ' ' ||
      '<a href="' || public.html_echappe(p_lien_desinscription) || '" style="color:#0d2b6b;text-decoration:underline">' ||
      public.html_echappe(t ->> 'desinscrire') || '</a><br>' ||
      public.html_echappe(t ->> 'expediteur') || ' : ' || public.html_echappe(p_identite) || ' — ' || public.html_echappe(p_adresse) ||
    '</td></tr></table></td></tr></table></body></html>';
end;
$$;


-- 5. Les appels aux fournisseurs (commercial seulement, identités séparées) --------------------------
create or replace function public.communication_appel_email(p_envoi public.communication_envois, p_sujet text,
                                                            p_html text, p_texte text, p_lien_desinscription text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  cl public.clients;
  v_cle text := public.lire_reglage('communication_email_cle_api');
  v_fournisseur text := p_envoi.fournisseur;          -- 1.3.1 (IR-06) : celui de l'envoi, jamais relu
  v_expediteur text := public.lire_reglage('communication_expediteur');
  v_nom text := public.lire_reglage('communication_nom');
  v_un_clic text := public.lire_reglage('communication_url_un_clic');
  v_entetes jsonb;
  v_delai integer := (select delai_http_ms from public.communication_reglages);
  v_requete bigint;
begin
  -- Phase 1.3.1 : aucune requête sans être passé par la porte, dans CETTE transaction, pour CETTE
  -- nature et CE canal
  if not public.communication_sortie_autorisee(p_envoi.nature, 'email') then
    raise exception 'SORTIE_NON_AUTORISEE';
  end if;
  select * into cl from public.clients where id = p_envoi.client_id;
  if coalesce(v_cle, '') = '' or coalesce(v_expediteur, '') = '' or coalesce(v_nom, '') = '' or p_html is null then
    raise exception 'NON_CONFIGURE';
  end if;
  v_entetes := jsonb_build_object('X-Mailin-custom', 'communication:' || p_envoi.id);   -- rapprochement (H8), à confirmer chez Brevo
  if p_lien_desinscription is not null then
    v_entetes := v_entetes || jsonb_build_object('List-Unsubscribe',
                   '<' || coalesce(nullif(v_un_clic, '') || '?t=' || public.communication_jeton_desinscription(p_envoi.id),
                                   p_lien_desinscription) || '>');
    if coalesce(v_un_clic, '') <> '' then
      v_entetes := v_entetes || jsonb_build_object('List-Unsubscribe-Post', 'List-Unsubscribe=One-Click');
    end if;
  end if;
  if v_fournisseur not in ('brevo', 'resend') then
    raise exception 'NON_CONFIGURE';
  end if;
  if v_fournisseur = 'resend' then
    select net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object('Authorization', 'Bearer ' || v_cle, 'Content-Type', 'application/json'),
      body := jsonb_build_object('from', v_nom || ' <' || v_expediteur || '>', 'to', jsonb_build_array(trim(cl.email)),
                                 'subject', p_sujet, 'html', p_html, 'text', p_texte, 'headers', v_entetes,
                                 'tags', jsonb_build_array(jsonb_build_object('name', 'flux', 'value', 'marketing'))),
      timeout_milliseconds := v_delai
    ) into v_requete;
  else
    select net.http_post(
      url := 'https://api.brevo.com/v3/smtp/email',
      headers := jsonb_build_object('api-key', v_cle, 'Content-Type', 'application/json', 'Accept', 'application/json'),
      body := jsonb_build_object('sender', jsonb_build_object('name', v_nom, 'email', v_expediteur),
                                 'to', jsonb_build_array(jsonb_build_object('email', trim(cl.email))),
                                 'subject', p_sujet, 'htmlContent', p_html, 'textContent', p_texte, 'headers', v_entetes,
                                 'tags', jsonb_build_array('goship-marketing',
                                         coalesce('campagne-' || p_envoi.campagne_id, 'confirmation'))),
      timeout_milliseconds := v_delai
    ) into v_requete;
  end if;
  return v_requete;
end;
$$;

create or replace function public.communication_appel_whatsapp(p_envoi public.communication_envois,
                                                               m public.communication_modeles, p_parametres text[])
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_jeton text := public.lire_reglage('communication_whatsapp_jeton');
  v_numero_id text := public.lire_reglage('communication_whatsapp_numero_id');
  v_delai integer := (select delai_http_ms from public.communication_reglages);
  v_requete bigint;
begin
  if not public.communication_sortie_autorisee(p_envoi.nature, 'whatsapp') then   -- Phase 1.3.1 : la porte
    raise exception 'SORTIE_NON_AUTORISEE';
  end if;
  if coalesce(v_jeton, '') = '' or coalesce(v_numero_id, '') = '' then
    raise exception 'NON_CONFIGURE';
  end if;
  select net.http_post(
    url := 'https://graph.facebook.com/' || coalesce(nullif(public.lire_reglage('whatsapp_version'), ''), 'v23.0') ||
           '/' || v_numero_id || '/messages',
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_jeton, 'Content-Type', 'application/json'),
    body := jsonb_build_object(
      'messaging_product', 'whatsapp',
      'to', public.communication_cible(p_envoi.client_id, 'whatsapp'),
      'type', 'template',
      'biz_opaque_callback_data', 'communication:' || p_envoi.id,     -- rapprochement (H8)
      'template', jsonb_build_object(
        'name', m.whatsapp_nom_meta,
        'language', jsonb_build_object('code', m.whatsapp_langue_meta),
        'components', case when cardinality(p_parametres) = 0 then '[]'::jsonb else jsonb_build_array(
          jsonb_build_object('type', 'body', 'parameters',
            (select jsonb_agg(jsonb_build_object('type', 'text', 'text', x) order by i)
               from unnest(p_parametres) with ordinality as t(x, i)))) end)),
    timeout_milliseconds := v_delai
  ) into v_requete;
  return v_requete;
end;
$$;


-- 6. La réponse d'un appel (revue 1.1, H8 ; Phase 1.3, C4) -------------------------------------------
-- AVANT 1.3 : 429 et TOUTE 5xx étaient lues comme « refus temporaire sûr » et renvoyées jusqu'à
-- trois fois. Or un fournisseur peut ACCEPTER le message puis échouer avant de répondre : un
-- nouvel essai pouvait doubler le message. DÉSORMAIS :
--   2xx                         → envoye (accepté, pas encore remis) ;
--   ligne VÉRIFIÉE de communication_issues_http (40 §9.3) → ce qu'elle dit ;
--   sinon 429 ou 5xx            → INCERTAIN : JAMAIS de nouvel essai automatique ;
--   sinon autre 4xx             → echec (la requête a été refusée telle quelle) ;
--   pas de réponse, délai, réseau → incertain.
-- Un « incertain » se RAPPROCHE par les retours du fournisseur (§9 : la référence
-- « communication:<id> » — X-Mailin-custom chez Brevo, biz_opaque_callback_data chez Meta —
-- est un identifiant de CORRÉLATION, PAS une clé d'idempotence : elle n'empêche aucun doublon).
-- Après 72 h sans preuve, il est clos et reste incertain ; seul un administrateur peut le
-- relancer, en acceptant explicitement le risque de doublon (§11).
-- Idempotence chez les fournisseurs : Brevo documente une clé d'idempotence (emplacement exact
-- et durée de validité NON confirmés à ce jour) ; Resend documente un en-tête Idempotency-Key
-- (24 h, rapporté) ; aucune n'est trouvée pour l'API WhatsApp de Meta. Aucune n'est utilisée ici :
-- même vérifiée, une clé ne protège que pendant sa durée de validité, et ne change pas la règle
-- « une 5xx est incertaine » tant que le CEO ne l'a pas décidé sur preuve.
create or replace function public.communication_lire_reponse(p_envoi public.communication_envois, p_code integer,
                                                             p_contenu text, p_erreur text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_json jsonb;
  v_id text;
  v_issue text;
begin
  begin v_json := p_contenu::jsonb; exception when others then v_json := null; end;
  if p_erreur is null and p_code between 200 and 299 then
    v_id := coalesce(v_json ->> 'messageId', v_json ->> 'id', v_json -> 'messages' -> 0 ->> 'id');
    update public.communication_envois
       set statut = 'envoye', message_id = left(v_id, 200), envoye_le = coalesce(envoye_le, now()), code_erreur = null,
           verrouille_le = null, maj_le = now()
     where id = p_envoi.id and statut = 'traitement';
    return;
  end if;
  if p_erreur is null and p_code between 400 and 599 then
    select i.issue into v_issue from public.communication_issues_http i
     where i.fournisseur = p_envoi.fournisseur and i.code_http = p_code;
    if p_code >= 500 then
      v_issue := 'incertain';                               -- une 5xx ne prouve jamais un refus
    end if;
    v_issue := coalesce(v_issue, case when p_code = 429 then 'incertain' else 'echec' end);
    -- 1.3.1 (IR-20) : 401/403 = clé ou compte refusé ; le travailleur met alors la campagne en
    -- pause au lieu de consommer toute l'audience (communication_traiter_un). Le code d'erreur
    -- de Meta dans le corps est gardé (sans le texte du fournisseur).
    if p_code in (401, 403) then
      update public.communication_envois set statut = 'echec', code_erreur = 'AUTH_FOURNISSEUR_' || p_code,
             verrouille_le = null, maj_le = now() where id = p_envoi.id and statut = 'traitement';
      return;
    end if;
    if p_envoi.fournisseur = 'meta' and (v_json -> 'error' ->> 'code') ~ '^[0-9]{1,9}$' then
      update public.communication_envois set code_erreur = 'META_' || (v_json -> 'error' ->> 'code')
       where id = p_envoi.id and statut = 'traitement';
    end if;
  else
    v_issue := 'incertain';                                 -- délai, réseau, pas de réponse, code inattendu
  end if;

  if v_issue = 'rejet_temporaire' and p_envoi.tentative < 3 then
    -- Refus PROUVÉ sûr par la documentation du fournisseur : nouvel essai 2 min, 10 min, 1 h
    update public.communication_envois
       set statut = 'nouvel_essai', code_erreur = 'HTTP_' || p_code, verrouille_le = null, maj_le = now(),
           prochain_essai_le = now() + case p_envoi.tentative when 1 then interval '2 minutes'
                                                               when 2 then interval '10 minutes' else interval '1 hour' end
     where id = p_envoi.id and statut = 'traitement';
  elsif v_issue = 'rejet_temporaire' then
    update public.communication_envois set statut = 'abandon', code_erreur = 'ABANDON_HTTP_' || p_code,
           verrouille_le = null, maj_le = now() where id = p_envoi.id and statut = 'traitement';
  elsif v_issue = 'echec' then
    update public.communication_envois set statut = 'echec', code_erreur = coalesce(code_erreur, 'HTTP_' || p_code),
           verrouille_le = null, maj_le = now() where id = p_envoi.id and statut = 'traitement';
  else
    -- Le message est PEUT-ÊTRE parti. Jamais renvoyé seul. Un code, jamais le texte du fournisseur.
    update public.communication_envois
       set statut = 'incertain',
           code_erreur = case when p_code is not null and p_erreur is null then 'INCERTAIN_HTTP_' || p_code
                              else left(coalesce(p_erreur, 'SANS_REPONSE'), 60) end,
           verrouille_le = null, maj_le = now()
     where id = p_envoi.id and statut = 'traitement';
  end if;
end;
$$;


-- 7. L'e-mail de confirmation (C2) --------------------------------------------------------------------
-- Mis en file par 41 (demander_consentement_communication) ; envoyé par le travailleur
-- seulement si confirmations_actives et email_actif sont allumés. Le jeton n'existe qu'à
-- l'envoi : 32 octets aléatoires (43 caractères base64url), seul son SHA-256 est gardé.
create or replace function public.communication_demander_envoi_confirmation(p_consentement bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  f public.communication_confirmations;
begin
  select * into f from public.communication_confirmations
   where consentement_id = p_consentement and canal = 'email' and utilise_le is null and annule_le is null
   order by id desc limit 1;
  if found then
    insert into public.communication_envois (nature, confirmation_id, client_id, canal, cle, cible_empreinte, fournisseur)
    values ('confirmation', f.id, f.client_id, 'email', 'confirmation:' || f.id, f.cible_empreinte,
            coalesce(nullif(public.lire_reglage('communication_email_fournisseur'), ''), 'brevo'))
    on conflict (cle) do nothing;
  end if;
end;
$$;


-- 8. Le travailleur (Phase 1.3, C1, C2, C3) -----------------------------------------------------------------
-- AVANT 1.3 : UNE fonction, UNE transaction pour tout le passage. Les réglages étaient lus une
-- fois au début (un arrêt écrit pendant le passage n'était pas vu) ; les verrous de chaque envoi
-- (client, jour, campagne, lignes de la file) restaient pris jusqu'à la fin du lot, dans un ordre
-- contraire à celui de l'annulation (interblocage possible) ; le quota Brevo était estimé une fois
-- et décompté en mémoire ; et pg_net n'envoyait rien avant la fin du lot.
-- DÉSORMAIS : une PROCÉDURE, traiter_communications(), lancée par pg_cron (« call »), qui VALIDE
-- (COMMIT) après chaque étape et après CHAQUE envoi. Chaque étape est une fonction SECURITY
-- DEFINER (search_path vide, lock_timeout de 2 s) :
--   8.1 communication_lire_reponses()     les réponses arrivées ; les incertains de plus de 72 h ;
--   8.2 communication_preparer()          images Meta à relire ; lancement d'UNE campagne due ;
--   8.3 communication_candidats()         les identifiants dus (lecture SANS verrou) ;
--   8.4 communication_traiter_un(id)      UN envoi, verrous dans l'ordre N0 → N5 ;
--   8.5 communication_clore_campagnes()   les campagnes finies.
-- Une procédure qui fait COMMIT ne peut être ni SECURITY DEFINER ni porter de clause SET
-- (règle de PostgreSQL) : elle tourne donc avec les droits du propriétaire de la tâche pg_cron
-- (postgres), n'appelle que des noms qualifiés « public. », vide son search_path elle-même, et
-- n'est exécutable par personne d'autre. Une erreur dans un envoi annule SA sous-transaction
-- (réservation et requête pg_net comprises : rien ne part) et n'arrête pas les suivants.
-- pg_cron ne lance jamais deux exécutions de la MÊME tâche en même temps (la seconde attend la
-- fin de la première — documentation de pg_cron, à reconfirmer en Phase 2) ; la conception ne
-- s'appuie PAS là-dessus : deux travailleurs simultanés (appel manuel, seconde tâche) restent sûrs
-- (verrous, relecture des statuts, compteurs sous N5).

-- 8.1 Les réponses arrivées. Lit TOUJOURS, même arrêt d'urgence posé : rien ne reste « en cours ».
create or replace function public.communication_lire_reponses()
returns integer
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  e public.communication_envois;
  x record;
  v_lus integer := 0;
begin
  perform public.communication_observer_sorties();
  -- Seulement des lignes « traitement » (N4), sans autre verrou : aucun cycle possible
  for e in select * from public.communication_envois where statut = 'traitement'
            order by verrouille_le limit 200 for update skip locked loop
    select status_code, content, error_msg into x from net._http_response where id = e.requete;
    if found then
      perform public.communication_lire_reponse(e, x.status_code, x.content, x.error_msg);
      v_lus := v_lus + 1;
    elsif not public.communication_en_transmission(e.requete, e.sortie_file_vue_le) then
      -- 1.3.1 (IR-15, IR2-01) : « incertain » seulement quand l'appel est FORCÉMENT terminé :
      -- sorti de la file (vu par nous) depuis plus que le délai HTTP + 60 s, sans réponse
      perform public.communication_lire_reponse(e, null, null, 'SANS_REPONSE');
      v_lus := v_lus + 1;
    end if;
  end loop;
  -- Incertains de plus de 72 h sans preuve : restent incertains, marqués clos (H8).
  -- 1.3.1 (IR-13) : lignes prises en « skip locked » — cette fonction tient déjà des lignes
  -- « traitement » ; attendre ici une ligne tenue par une purge pourrait former un cycle.
  update public.communication_envois set incertain_clos_le = now()
   where id in (select x.id from public.communication_envois x
                 where x.statut = 'incertain' and x.incertain_clos_le is null and x.maj_le < now() - interval '72 hours'
                 for update skip locked);
  perform public.communication_lire_modeles_meta();              -- lecture seule des réponses de Meta
  perform public.communication_nettoyer_compteurs();
  return v_lus;
end;
$$;

-- 8.2 Préparer : lancer UNE campagne due. Phase 1.3.1 : NE prend PLUS N0 — un lancement ne dépose
-- aucune requête (il crée des lignes « attente » qui passeront une à une par la porte). Tenir N0
-- pendant un lancement de milliers de lignes aurait pu faire attendre l'arrêt d'urgence plus que
-- son délai. L'état d'arrêt est lu simplement : un lancement qui le croise ne crée que des envois
-- qui ne partiront pas. Les lectures de modèles chez Meta sont à part (8.2 bis), sous la porte.
create or replace function public.communication_preparer()
returns text
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  r public.communication_reglages;
  c public.communication_campagnes;
  v_raison text;
  v_volume jsonb;
begin
  if (select a.etat from public.communication_arret a) is distinct from 'actif' then
    return 'ARRET_URGENCE';
  end if;
  select * into r from public.communication_reglages;
  if not r.campagnes_actives then
    return 'CAMPAGNES_COUPEES';
  end if;

  -- Le lancement d'une campagne due (une par passage) : N1 sur la campagne, puis des lignes NEUVES
  for c in select * from public.communication_campagnes
            where statut = 'programmee' and planifiee_le <= now()
            order by planifiee_le limit 1 for update skip locked loop
    if c.empreinte_approuvee is null or c.empreinte_approuvee is distinct from public.communication_empreinte_campagne(c) then
      update public.communication_campagnes set statut = 'en_pause', arret_motif = 'EMPREINTE_CHANGEE', maj_le = now() where id = c.id;
      perform public.auditer('communication.campagne_bloquee', 'communication_campagne', c.id::text, null, jsonb_build_object('motif', 'EMPREINTE_CHANGEE'));
      return 'EMPREINTE_CHANGEE';
    end if;
    -- Modèles WhatsApp : image Meta fraîche ET identique à celle approuvée ; sinon on attend ou on bloque
    v_raison := (select string_agg(m2.id || ':' || public.communication_modele_meta_bloque(m2.id, m2.empreinte_meta_approuvee), ',')
                   from public.communication_modeles m2
                  where m2.id::text in (select jsonb_path_query(c.modeles, '$.whatsapp.*') #>> '{}')
                    and public.communication_modele_meta_bloque(m2.id, m2.empreinte_meta_approuvee) is not null);
    if v_raison is not null then
      if v_raison like '%MODELE_META_NON_VERIFIE%' and c.planifiee_le > now() - interval '1 hour' then
        return 'MODELE_META_EN_LECTURE';                    -- image en cours de lecture : passage suivant
      end if;
      update public.communication_campagnes set statut = 'en_pause', arret_motif = left('MODELE_META:' || v_raison, 300), maj_le = now()
       where id = c.id;
      perform public.auditer('communication.campagne_bloquee', 'communication_campagne', c.id::text, null, jsonb_build_object('motif', v_raison));
      return 'MODELE_META';
    end if;
    -- Le volume réel ne dépasse ni le volume approuvé (+ seuil), ni les plafonds (revue 1.1, H13)
    v_volume := public.communication_volume_campagne(c);
    if (select bool_or((v_volume -> 'volume' ->> k)::integer
                       > ceil(coalesce((c.audience_approuvee ->> k)::integer, 0) * (1 + c.seuil_croissance_pct / 100.0)))
          from jsonb_object_keys(v_volume -> 'volume') k)
       or (v_volume ->> 'total')::integer > c.plafond_messages
       or ('whatsapp' = any (c.canaux) and (v_volume ->> 'cout_estime_usd')::numeric > c.plafond_cout_usd) then
      update public.communication_campagnes
         set statut = 'en_attente_approbation', arret_motif = 'AUDIENCE_DEPASSEE', approuvee_par = null, approuvee_le = null,
             empreinte_approuvee = null, maj_le = now()
       where id = c.id;
      perform public.auditer('communication.campagne_bloquee', 'communication_campagne', c.id::text, null,
                             jsonb_build_object('motif', 'AUDIENCE_DEPASSEE', 'volume', v_volume, 'approuve', c.audience_approuvee));
      return 'AUDIENCE_DEPASSEE';
    end if;
    -- 1.3.1 (IR-07) : l'audience figée ne garde QUE les personnes retenues. Les exclus (sans
    -- consentement, supprimés, hors fuseau…) ne laissent qu'un COMPTE par canal et par raison,
    -- dans la campagne : ni leur identifiant ni l'empreinte de leur contact ne sont gardés.
    with audience as materialized (
      select k.id client_id, ca.canal, lg.langue, ex.raison
        from public.communication_segment_clients(c.criteres) k
        cross join unnest(c.canaux) as ca(canal)
        cross join lateral (select case when (c.modeles -> ca.canal) ? cl.langue then cl.langue else c.langue_repli end langue
                              from public.clients cl where cl.id = k.id) lg
        cross join lateral (select public.communication_raison_exclusion(k.id, ca.canal, c.essai) raison) ex
    ), retenus as (
      insert into public.communication_destinataires (campagne_id, client_id, canal, langue, modele_id, cible_empreinte,
                                                      territoire, retenu, raison)
      select c.id, a.client_id, a.canal, a.langue, ((c.modeles -> a.canal) ->> a.langue)::uuid,
             public.communication_empreinte(a.canal, public.communication_cible(a.client_id, a.canal)),
             case when a.canal = 'whatsapp' then public.communication_territoire(public.communication_cible(a.client_id, 'whatsapp')) end,
             true, null
        from audience a where a.raison is null
      on conflict (campagne_id, client_id, canal) do nothing
      returning 1
    )
    update public.communication_campagnes
       set exclusions = (select coalesce(jsonb_object_agg(x.canal || ':' || x.raison, x.n), '{}'::jsonb)
                           from (select a.canal, a.raison, count(*) n from audience a
                                  where a.raison is not null group by a.canal, a.raison) x),
           retenus = (select count(*) from retenus)
     where id = c.id;
    insert into public.communication_envois (nature, campagne_id, destinataire_id, client_id, canal, cle, cible_empreinte,
                                             territoire, fournisseur)
    select 'campagne', d2.campagne_id, d2.id, d2.client_id, d2.canal,
           'campagne:' || d2.campagne_id || ':' || d2.id, d2.cible_empreinte, d2.territoire,
           case d2.canal when 'whatsapp' then 'meta'
                         else coalesce(nullif(public.lire_reglage('communication_email_fournisseur'), ''), 'brevo') end
      from public.communication_destinataires d2 where d2.campagne_id = c.id and d2.retenu
    on conflict (cle) do nothing;
    update public.communication_campagnes set statut = 'en_cours', lancee_le = now(), maj_le = now() where id = c.id;
    return 'LANCEE';
  end loop;
  return null;
end;
$$;

-- 8.2 bis Les images des modèles chez Meta (Phase 1.3.1) : une SORTIE (requête vers Meta), donc
-- par la porte (nature « lecture_meta » : seul l'arrêt la bloque), N0 partagé jusqu'au COMMIT.
create or replace function public.communication_rafraichir_modeles_meta()
returns text
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  r public.communication_reglages;
  v_raison text;
begin
  v_raison := public.communication_autoriser_sortie('lecture_meta', 'whatsapp');
  if v_raison is not null then
    return v_raison;
  end if;
  select * into r from public.communication_reglages;
  perform public.communication_demander_modele_meta(mm.id)
     from public.communication_modeles mm
    where mm.canal = 'whatsapp' and mm.statut = 'approuve'
      and mm.id::text in (select jsonb_path_query(cc.modeles, '$.whatsapp.*') #>> '{}'
                            from public.communication_campagnes cc
                           where cc.statut = 'en_cours' or (cc.statut = 'programmee' and cc.planifiee_le <= now() + interval '1 hour'))
      and not exists (select 1 from public.communication_modeles_meta s
                       where s.modele_id = mm.id and s.demande_le > now() - make_interval(mins => greatest(r.modele_meta_fraicheur_min / 2, 5)));
  return null;
end;
$$;

-- 8.3 Les candidats : identifiants seulement, lus SANS verrou (deux travailleurs peuvent lire
-- les mêmes : communication_traiter_un verrouille et RELIT le statut). Rien si l'arrêt
-- d'urgence est posé, ou si le transactionnel a du retard (il passe d'abord).
create or replace function public.communication_candidats()
returns bigint[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  r public.communication_reglages;
begin
  select * into r from public.communication_reglages;
  if (select a.etat from public.communication_arret a) is distinct from 'actif' then
    return '{}';                                              -- simple économie : la porte décide
  end if;
  if (select count(*) from public.notification_envois
       where statut = 'attente' and prochain_essai_le <= now()) > r.attente_transactionnel_max then
    return '{}';
  end if;
  return coalesce((
    select array_agg(x.id order by x.prochain_essai_le)
      from (select ev.id, ev.prochain_essai_le
              from public.communication_envois ev
              left join public.communication_campagnes ca on ca.id = ev.campagne_id
             where ev.statut in ('attente', 'nouvel_essai') and ev.prochain_essai_le <= now()
               and ((ev.nature = 'confirmation' and r.confirmations_actives)
                    or (ev.nature = 'campagne' and r.campagnes_actives and ca.statut = 'en_cours'))
               and ((ev.canal = 'email' and r.email_actif) or (ev.canal = 'whatsapp' and r.whatsapp_actif))
             order by ev.prochain_essai_le
             limit least(r.lot_par_minute, r.debit_max_minute)) x), '{}');
end;
$$;

-- 8.4 UN envoi. Ordre des verrous (40 §3) : N0 partagé → N1 campagne → N2 client →
-- N3 consentement → N4 envoi → N5 compteurs (dans communication_reserver). Renvoie un code
-- court (ENVOYE, ou la raison) pour le compte rendu ; jamais de donnée personnelle.
-- Les verrous ne s'attendent pas plus de 2 s (lock_timeout) : au-delà, la procédure annule ce
-- seul envoi (rien n'est parti, rien n'est réservé) et il repasse au passage suivant.
create or replace function public.communication_traiter_un(p_envoi bigint)
returns text
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  r public.communication_reglages;
  c public.communication_campagnes;
  e public.communication_envois;
  d public.communication_destinataires;
  m public.communication_modeles;
  f public.communication_confirmations;
  v_raison text;
  v_rendu jsonb;
  v_sujet jsonb;
  v_requete bigint;
  v_cout numeric;
  v_lien text;
  v_html text;
  v_jeton text;
  v_params text[];
  v_fenetre timestamptz;
  v_site text := regexp_replace(coalesce(public.lire_reglage('site_url'), ''), '/?$', '/');
begin
  select * into e from public.communication_envois where id = p_envoi;              -- lecture sans verrou
  if not found or e.statut not in ('attente', 'nouvel_essai') or e.prochain_essai_le > now() then
    return 'PAS_DU';
  end if;
  -- N0 et POINT D'AUTORISATION (Phase 1.3.1) : la porte unique. Elle tient N0 partagé jusqu'au
  -- COMMIT de cet envoi et lit l'état d'arrêt APRÈS l'avoir obtenu. Refus : rien n'est modifié,
  -- l'envoi reste en attente.
  v_raison := public.communication_autoriser_sortie(e.nature, e.canal);
  if v_raison is not null then
    return v_raison;
  end if;
  select * into r from public.communication_reglages;              -- même état que la porte (N0 tenu)
  -- Revue n° 3 (IR3-04) : la règle du compte Brevo partagé porte sur le fournisseur FIGÉ de l'envoi
  -- (la porte, elle, lit le réglage du moment) ; l'envoi reste en attente
  if e.canal = 'email' and e.fournisseur = 'brevo' and r.brevo_compte_partage then
    return 'COMPTE_BREVO_PARTAGE';
  end if;

  -- N1 : la campagne AVANT l'envoi (même ordre que l'annulation, 42 §4.6)
  if e.nature = 'campagne' then
    select * into c from public.communication_campagnes where id = e.campagne_id for update;
    if c.statut is distinct from 'en_cours' then
      return 'CAMPAGNE_' || coalesce(c.statut, 'INCONNUE');
    end if;
    -- 1.3.1 (IR-20) : le fournisseur a refusé la clé ou le compte dans l'heure : pause (N1 tenu)
    if exists (select 1 from public.communication_envois x
                where x.fournisseur = e.fournisseur and x.code_erreur like 'AUTH_FOURNISSEUR%'
                  -- IR2-14 : seulement depuis la dernière reprise de la campagne (pas de boucle de pauses)
                  and x.maj_le > greatest(now() - interval '1 hour', c.maj_le)) then
      update public.communication_campagnes set statut = 'en_pause', arret_motif = 'AUTH_FOURNISSEUR', maj_le = now() where id = c.id;
      return 'AUTH_FOURNISSEUR';
    end if;
  end if;
  -- N2, N3 : le client (fréquence) et son consentement sur ce canal (un retrait en cours attend
  -- la fin de cet envoi, ou cet envoi attend la fin du retrait et le voit)
  perform public.communication_verrou('client:' || e.client_id);
  perform public.communication_verrou('consentement:' || e.client_id || ':' || e.canal);
  -- N4 : l'envoi, RELU sous verrou (un autre travailleur l'a peut-être pris)
  select * into e from public.communication_envois
   where id = p_envoi and statut in ('attente', 'nouvel_essai') for update skip locked;
  if not found then
    return 'DEJA_PRIS';
  end if;
  -- 1.3.1 (IR-14) : une RELANCE dont l'original a finalement été remis (retour tardif du
  -- fournisseur) ne part pas : ce serait un doublon
  if e.relance_de is not null and exists (select 1 from public.communication_envois o
                                           where o.id = e.relance_de and o.statut in ('envoye', 'livre', 'lu')) then
    update public.communication_envois set statut = 'supprime', code_erreur = 'ORIGINAL_REMIS', maj_le = now() where id = e.id;
    return 'ORIGINAL_REMIS';
  end if;

  -- Le contact a changé depuis le gel (ou la demande) : jamais envoyé à la nouvelle adresse (H5)
  if public.communication_empreinte(e.canal, public.communication_cible(e.client_id, e.canal)) is distinct from e.cible_empreinte then
    update public.communication_envois set statut = 'supprime', code_erreur = 'CONTACT_CHANGE', maj_le = now() where id = e.id;
    return 'CONTACT_CHANGE';
  end if;

  if e.nature = 'confirmation' then
    -- Confirmation : demandée par le client lui-même ; jamais vers une adresse en plainte,
    -- rebond définitif ou suppression manuelle ; liste d'essai en mode essai
    select * into f from public.communication_confirmations where id = e.confirmation_id;
    if f.utilise_le is not null or f.annule_le is not null or f.expire_le < now()
       or (r.mode = 'essai' and not public.communication_est_essai(e.client_id, 'email'))
       or exists (select 1 from public.communication_suppressions s
                   where s.canal = 'email' and s.cible_empreinte = e.cible_empreinte and s.leve_le is null
                     and s.raison in ('plainte', 'rebond_definitif', 'manuel')) then
      update public.communication_envois set statut = 'supprime', code_erreur = 'CONFIRMATION_IMPOSSIBLE', maj_le = now() where id = e.id;
      return 'CONFIRMATION_IMPOSSIBLE';
    end if;
    v_cout := 0;
  else
    select * into d from public.communication_destinataires where id = e.destinataire_id;
    select * into m from public.communication_modeles where id = d.modele_id;
    v_raison := public.communication_raison_exclusion(e.client_id, e.canal, c.essai);   -- retrait, STOP, fuseau…
    if v_raison is not null then
      update public.communication_envois set statut = 'supprime', code_erreur = v_raison, maj_le = now() where id = e.id;
      return v_raison;
    end if;
    -- Heure locale RÉELLE (C6) : fuseau inconnu = écarté ; hors fenêtre = reporté au début de la suivante
    v_fenetre := public.communication_prochaine_fenetre(e.client_id, e.canal);
    if v_fenetre is null then
      update public.communication_envois set statut = 'supprime', code_erreur = 'FUSEAU_INCONNU', maj_le = now() where id = e.id;
      return 'FUSEAU_INCONNU';
    end if;
    if v_fenetre > now() then
      update public.communication_envois set prochain_essai_le = v_fenetre, maj_le = now() where id = e.id;
      return 'HORS_FENETRE';
    end if;
    if public.communication_frequence_atteinte(e.client_id) then
      update public.communication_envois set prochain_essai_le = now() + interval '6 hours', maj_le = now() where id = e.id;
      return 'FREQUENCE';
    end if;
    -- Campagne à mettre en pause : permis ici, la ligne est déjà à nous (N1)
    -- 1.3.1 (IR-10) : le contenu envoyé doit être celui dont l'empreinte a été approuvée
    if m.statut is distinct from 'approuve' or m.empreinte is distinct from public.communication_empreinte_modele(m) then
      update public.communication_campagnes set statut = 'en_pause', arret_motif = 'MODELE_INDISPONIBLE', maj_le = now() where id = c.id;
      return 'MODELE_INDISPONIBLE';
    end if;
    if e.canal = 'whatsapp' then
      v_raison := public.communication_modele_meta_bloque(m.id, m.empreinte_meta_approuvee);
      if v_raison is not null then                          -- image Meta trop vieille ou différente : pause
        update public.communication_campagnes set statut = 'en_pause', arret_motif = v_raison, maj_le = now() where id = c.id;
        perform public.auditer('communication.campagne_bloquee', 'communication_campagne', c.id::text, null, jsonb_build_object('motif', v_raison));
        return v_raison;
      end if;
    end if;
    -- L'environnement d'envoi n'a pas changé depuis l'approbation (pied, adresse, expéditeur…)
    if c.empreinte_approuvee is distinct from public.communication_empreinte_campagne(c) then
      update public.communication_campagnes set statut = 'en_pause', arret_motif = 'EMPREINTE_CHANGEE', maj_le = now() where id = c.id;
      return 'EMPREINTE_CHANGEE';
    end if;
    -- Texte : jamais de variable non résolue ; paramètres WhatsApp valides
    if e.canal = 'email' then
      v_rendu := public.communication_rendre(m.corps, e.client_id, 'email');
      v_sujet := public.communication_rendre(m.sujet, e.client_id, 'email');
      if not (v_rendu ->> 'ok')::boolean or not (v_sujet ->> 'ok')::boolean then
        update public.communication_envois set statut = 'supprime',
               code_erreur = left(coalesce(v_rendu ->> 'raison', v_sujet ->> 'raison'), 60), maj_le = now() where id = e.id;
        return 'RENDU_IMPOSSIBLE';
      end if;
      v_lien := case when public.communication_jeton_desinscription(e.id) is null then null
                     else v_site || 'desinscription.html?t=' || public.communication_jeton_desinscription(e.id) end;
      v_html := public.communication_courriel_commercial(m.langue, v_sujet ->> 'texte', v_rendu ->> 'texte', v_lien,
                                                         r.identite_legale, r.adresse_postale);
      if v_html is null then                                 -- clé, identité ou adresse absentes : REFUS (C1, M8)
        update public.communication_campagnes set statut = 'en_pause', arret_motif = 'PIED_COMMERCIAL_INCOMPLET', maj_le = now() where id = c.id;
        return 'PIED_COMMERCIAL_INCOMPLET';
      end if;
      v_cout := 0;
    else
      select array_agg(public.communication_rendre('{{' || v || '}}', e.client_id, 'whatsapp') ->> 'texte' order by i) into v_params
        from unnest(m.variables) with ordinality as t(v, i);
      if exists (select 1 from unnest(coalesce(v_params, '{}')) p where public.communication_parametre_whatsapp_invalide(p)) then
        update public.communication_envois set statut = 'supprime', code_erreur = 'PARAMETRE_WHATSAPP_INVALIDE', maj_le = now() where id = e.id;
        return 'PARAMETRE_WHATSAPP_INVALIDE';
      end if;
      select t.prix_usd into v_cout from public.communication_tarifs t
       where t.fournisseur = 'meta' and t.canal = 'whatsapp' and t.categorie = 'marketing' and t.territoire = e.territoire;
      if v_cout is null then
        update public.communication_envois set statut = 'supprime', code_erreur = 'TARIF_NON_VERIFIE', maj_le = now() where id = e.id;
        return 'TARIF_NON_VERIFIE';
      end if;
    end if;
  end if;

  -- N5 et l'appel, dans une sous-transaction : une erreur de configuration (NON_CONFIGURE…)
  -- annule la réservation ET la requête pg_net, et l'envoi est noté en échec. Un interblocage
  -- ou un délai de verrou est RELANCÉ vers la procédure : tout l'envoi est annulé, il repassera.
  begin
    v_raison := public.communication_reserver(e, v_cout);
    if v_raison is not null then
      if v_raison like 'PLAFOND_CAMPAGNE%' then
        update public.communication_campagnes set statut = 'en_pause', arret_motif = v_raison, maj_le = now() where id = c.id;
      elsif v_raison = 'DEBIT_MINUTE' then
        update public.communication_envois set prochain_essai_le = date_trunc('minute', clock_timestamp()) + interval '1 minute',
               maj_le = now() where id = e.id;
      elsif v_raison = 'QUOTA_BREVO' then
        update public.communication_envois set prochain_essai_le = now() + interval '1 hour', code_erreur = v_raison,
               maj_le = now() where id = e.id;
      elsif v_raison like 'PLAFOND_JOUR%' or v_raison = 'LIMITE_NUMERO_WHATSAPP' then
        update public.communication_envois
           set prochain_essai_le = ((public.communication_jour() + 1)::timestamp + interval '9 hours') at time zone 'America/Santo_Domingo',
               code_erreur = v_raison, maj_le = now()
         where id = e.id;
      end if;                                                -- interrupteur, campagne arrêtée : rien ne change
      return v_raison;
    end if;

    if e.nature = 'confirmation' then
      v_jeton := translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/=', '-_');
      update public.communication_confirmations
         set jeton_empreinte = encode(extensions.digest(v_jeton, 'sha256'), 'hex') where id = f.id;
      v_lien := v_site || 'confirmation-communication.html?t=' || v_jeton;
      v_sujet := public.communication_textes_confirmation(
                   (select langue from public.communication_consentements where id = f.consentement_id));
      v_html := '<!doctype html><html><body style="font-family:Arial,Helvetica,sans-serif;color:#0d2b6b">' ||
                '<p>' || public.html_echappe(v_sujet ->> 'corps') || '</p>' ||
                '<p><a href="' || public.html_echappe(v_lien) || '">' || public.html_echappe(v_sujet ->> 'bouton') || '</a></p>' ||
                '<p style="font-size:12px;color:#5b6782">' || public.html_echappe(coalesce(r.identite_legale, '')) || '</p></body></html>';
      v_requete := public.communication_appel_email(e, v_sujet ->> 'sujet', v_html, (v_sujet ->> 'corps') || E'\n\n' || v_lien, null);
      v_html := v_sujet::text;                               -- l'empreinte du contenu ne garde pas le jeton
    elsif e.canal = 'email' then
      v_requete := public.communication_appel_email(e, v_sujet ->> 'texte', v_html,
                     (v_rendu ->> 'texte') || E'\n\n' || r.identite_legale || ' — ' || r.adresse_postale || E'\n' ||
                     (public.communication_textes_pied(m.langue) ->> 'desinscrire') || ' : ' || v_lien, v_lien);
    else
      v_requete := public.communication_appel_whatsapp(e, m, v_params);
    end if;
    update public.communication_envois
       set statut = 'traitement', requete = v_requete, tentative = tentative + 1, verrouille_le = now(), remis_le = now(),
           sortie_file_vue_le = null,           -- revue n° 3 (IR3-01) : nouvelle requête, nouvelle observation
           code_erreur = null,
           cout_estime_usd = v_cout, maj_le = now(),
           empreinte_contenu = encode(extensions.digest(coalesce(v_html, array_to_string(v_params, '|'), ''), 'sha256'), 'hex')
     where id = e.id;
    return 'ENVOYE';
  exception
    when lock_not_available or deadlock_detected or query_canceled then
      raise;                                                 -- la procédure annule tout l'envoi
    when others then
      update public.communication_envois
         set statut = 'echec', code_erreur = case when sqlerrm = 'NON_CONFIGURE' then 'NON_CONFIGURE' else 'ERREUR_INTERNE' end,
             maj_le = now()
       where id = e.id;
      insert into public.communication_erreurs (source, code, detail)
      values ('communication_traiter_un', sqlstate, case when sqlerrm ~ '^[A-Z_]{3,40}$' then sqlerrm else '' end);
      return 'ECHEC';
  end;
end;
$$;

-- 8.5 Les campagnes finies : plus rien à envoyer ni en cours (les incertains n'empêchent pas la fin).
create or replace function public.communication_clore_campagnes()
returns integer
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  v_n integer;
begin
  update public.communication_campagnes ca set statut = 'terminee', terminee_le = now(), maj_le = now()
   where ca.statut = 'en_cours'
     and not exists (select 1 from public.communication_envois ev
                      where ev.campagne_id = ca.id and ev.statut in ('attente', 'traitement', 'nouvel_essai'));
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- 8.6 La procédure lancée par pg_cron. Une étape ou un envoi en échec n'arrête pas les autres
-- (sa sous-transaction est annulée, l'erreur est gardée en code, jamais en texte du client).
-- COMMIT hors de tout bloc EXCEPTION (règle de PL/pgSQL).
create or replace procedure public.traiter_communications()
language plpgsql
as $$
declare
  v_ids bigint[];
  v_id bigint;
  v_res text;
  v_etat text;
  v_code text;
begin
  perform pg_catalog.set_config('search_path', '', false);
  -- Phase 1.3.1 : un arrêt EN ATTENTE est terminé ici s'il peut l'être (aucun verrou tenu à ce
  -- moment ; tentative non bloquante de N0 exclusif). Ne dit jamais « confirmé » sans preuve.
  begin
    perform public.communication_confirmer_arret_auto();
  exception when others then
    get stacked diagnostics v_etat = returned_sqlstate;
    insert into public.communication_erreurs (source, code) values ('traiter_communications:arret', v_etat);
  end;
  commit;
  begin
    perform public.communication_lire_reponses();
  exception when others then
    get stacked diagnostics v_etat = returned_sqlstate;
    insert into public.communication_erreurs (source, code) values ('traiter_communications:reponses', v_etat);
  end;
  commit;
  begin
    perform public.communication_rafraichir_modeles_meta();
  exception when others then
    get stacked diagnostics v_etat = returned_sqlstate;
    insert into public.communication_erreurs (source, code) values ('traiter_communications:modeles', v_etat);
  end;
  commit;
  begin
    perform public.communication_preparer();
  exception when others then
    get stacked diagnostics v_etat = returned_sqlstate;
    insert into public.communication_erreurs (source, code) values ('traiter_communications:preparer', v_etat);
  end;
  commit;
  v_ids := public.communication_candidats();
  commit;
  foreach v_id in array v_ids loop
    begin
      v_res := public.communication_traiter_un(v_id);
    exception when others then
      get stacked diagnostics v_etat = returned_sqlstate;
      -- 57014 (annulation par délai) n'est pas attrapée par « when others » : la procédure entière
      -- s'arrête alors, et le passage suivant reprend (IR-25)
      v_code := case when v_etat in ('55P03', '40P01') then 'REESSAI' else 'ERREUR' end;
      insert into public.communication_erreurs (source, code, detail)
      values ('traiter_communications:envoi', v_etat, v_code || ' envoi ' || v_id);
      -- Erreur qui n'est pas un conflit de verrou : l'envoi n'est jamais parti (sous-transaction
      -- annulée) ; on le sort de la file pour qu'il ne repasse pas à chaque minute. Seul verrou
      -- pris ici : la ligne (N4), aucun autre n'est tenu à ce moment.
      if v_code = 'ERREUR' then
        update public.communication_envois set statut = 'echec', code_erreur = 'ERREUR_INTERNE', maj_le = now()
         where id = v_id and statut in ('attente', 'nouvel_essai');
      end if;
      v_res := v_code;
    end;
    commit;                                                  -- pg_net reçoit CETTE requête maintenant
    exit when v_res in ('ARRET_URGENCE', 'CAMPAGNES_COUPEES');
  end loop;
  begin
    perform public.communication_clore_campagnes();
  exception when others then
    get stacked diagnostics v_etat = returned_sqlstate;
    insert into public.communication_erreurs (source, code) values ('traiter_communications:clore', v_etat);
  end;
  commit;
end;
$$;


-- 9. Les retours des fournisseurs (revue 1.1, C6, H8, H11) ------------------------------------------------
-- Parcours complet (détail : COMMUNICATION_CENTER_SECURITY.md §6) :
--   Meta → fonction Edge : signature X-Hub-Signature-256 vérifiée sur le CORPS BRUT ;
--   Brevo → fonction Edge : Brevo ne signe pas ses envois (rapporté) ; protections PRÉVUES :
--     jeton secret dans l'adresse ou authentification simple, et plages d'adresses IP publiées
--     par Brevo — plus faibles, à confirmer et documentées comme telles ;
--   fonction Edge → base : chaque événement normalisé en texte, signé par HMAC avec la clé
--     partagée « communication_cle_webhook » (coffre + secrets de la fonction Edge). PHASE 1.3
--     (C7) : l'appel ne se fait PLUS avec la clé publique (« anon ») — la fonction n'est
--     exécutable que par le rôle communication_webhook (§14) ; DEUX portes : le rôle ET la
--     signature ; clé absente du coffre : tout est refusé.
-- Identifiant unique d'un événement (rejeu refusé) : Meta ne donne pas d'identifiant aux
-- statuts → « meta:<id du message>:<statut>:<horodatage> » ; message entrant →
-- « meta:in:<id du message entrant> » ; Brevo → « brevo:<message-id>:<événement>:<horodatage> »
-- (forme des envois de Brevo à confirmer sur des exemples réels en Phase 3).
-- Âge : AUCUNE limite (un STOP reçu cinq jours plus tard s'applique) ; seuls les événements
-- datés de plus de 5 minutes dans le FUTUR sont refusés. Les statuts ne reculent jamais
-- (un « remis » tardif ne repasse pas un « lu » en « remis »).
-- Ordre de priorité : retrait/suppression > confirmation > demande ; à heure égale, le retrait
-- gagne (communication_etat_consentement) ; un fournisseur n'écrit JAMAIS un accord, il ne
-- peut que confirmer une demande faite par le client (message entrant depuis le numéro).
-- Rien ici ne touche le transactionnel (notification_preferences, notification_envois).
create table if not exists public.communication_evenements_fournisseur (
  id             bigint generated always as identity primary key,
  fournisseur    text not null check (fournisseur in ('meta', 'brevo', 'resend')),
  evenement_id   text not null,
  type           text not null,          -- sent, delivered, read, failed, hard_bounce, soft_bounce, complaint,
                                         -- unsubscribe, blocked, inbound
  message_id     text,
  reference      text,                   -- biz_opaque_callback_data / X-Mailin-custom : « communication:<id> »
  envoi_id       bigint references public.communication_envois (id),
  code           text,                   -- code du fournisseur, jamais son texte libre
  survenu_le     timestamptz,
  recu_le        timestamptz not null default now(),
  unique (fournisseur, evenement_id)
);
create index if not exists communication_evenements_envoi_idx on public.communication_evenements_fournisseur (envoi_id) where envoi_id is not null;
alter table public.communication_evenements_fournisseur enable row level security;
revoke all on public.communication_evenements_fournisseur from anon, authenticated, service_role;
drop trigger if exists communication_evenements_immuable on public.communication_evenements_fournisseur;
create trigger communication_evenements_immuable
  before update or delete on public.communication_evenements_fournisseur
  for each row execute function public.communication_immuable();

-- La fenêtre de 24 h de WhatsApp : dernier message reçu d'un numéro (empreinte seulement,
-- jamais le contenu). Sert aux réponses de service, jamais au commercial.
create table if not exists public.communication_fenetres_whatsapp (
  cible_empreinte  text primary key,
  dernier_entrant  timestamptz not null
);
alter table public.communication_fenetres_whatsapp enable row level security;
revoke all on public.communication_fenetres_whatsapp from anon, authenticated, service_role;

-- Les mots qui arrêtent tout, quatre langues. Liste À FAIRE VALIDER (juriste, D-F).
create or replace function public.communication_mot_simple(p_texte text)
returns text
language sql
immutable
set search_path = ''
as $$
  select upper(trim(regexp_replace(translate(coalesce(p_texte, ''), 'ÀÂÉÈÊËÎÏÔÙÛÜÇÍÓÚÑàâéèêëîïôùûüçíóúñ',
                                             'AAEEEEIIOUUUCIOUNaaeeeeiiouuuciouun'), '[^A-Za-z0-9 ]', '', 'g')))
$$;

create or replace function public.communication_est_stop(p_texte text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select public.communication_mot_simple(p_texte)
         in ('STOP', 'ARRET', 'ARRETER', 'DESABONNER', 'DESINSCRIRE', 'UNSUBSCRIBE', 'CANCEL',
             'BAJA', 'PARAR', 'DETENER', 'KANPE', 'SISPANN', 'DEZABONE')
$$;

-- Le compteur des retours par minute et par fournisseur (Phase 1.3, C7) : une limite de débit
-- DANS la base, qui ne dépend pas de la fonction Edge.
-- 1.3.1 (IR-25) : huit « éclats » par minute, pour que les retours d'un même fournisseur ne
-- s'attendent pas tous sur une seule ligne jusqu'au COMMIT ; la limite porte sur leur somme.
create table if not exists public.communication_webhook_debit (
  minute       timestamptz not null,
  fournisseur  text not null,
  eclat        smallint not null default 0 check (eclat between 0 and 7),
  appels       integer not null default 0,
  primary key (minute, fournisseur, eclat)
);
alter table public.communication_webhook_debit enable row level security;
revoke all on public.communication_webhook_debit from anon, authenticated, service_role;

-- Phase 1.3 (C7) — ce qui change :
--   · ACCÈS : n'est PLUS ouverte à « anon ». Seul le rôle communication_webhook (créé SANS
--     connexion possible, §14) peut l'appeler ; la façon dont la fonction Edge s'authentifiera
--     (rôle de connexion dédié avec mot de passe dans ses secrets, ou clé service_role — aujourd'hui
--     « utilisée nulle part » d'après docs/production/secrets.md) est une DÉCISION DU CEO avant la
--     Phase 3. Un appel direct par l'API publique (clé publishable) est refusé par PostgreSQL
--     avant même d'entrer dans la fonction. La signature HMAC reste exigée (défense en profondeur).
--   · DÉBIT : au-delà de webhook_max_minute appels par minute et par fournisseur, réponse
--     « sature » sans traitement ; la fonction Edge répond alors une erreur temporaire (le
--     fournisseur réessaie — comportement de réessai de Meta et de Brevo À VÉRIFIER).
--   · FORMAT : charge de 20 000 caractères au plus, JSON objet, type connu, horodatage lisible
--     (une valeur illisible est refusée proprement, sans message d'erreur qui la recopie).
--   · HORODATAGE : la fenêtre de 24 h de WhatsApp part de l'heure RÉELLE du message du client
--     (survenu_le, fourni par Meta), JAMAIS de l'heure de réception : un message de 10 h reçu à
--     18 h ouvre une fenêtre jusqu'à 10 h le lendemain. Elle ne recule jamais (greatest) : un
--     événement ancien ou reçu dans le désordre ne l'allonge pas. Sans horodatage, la fenêtre
--     n'est pas touchée (le STOP, lui, s'applique toujours).
--   · VERROUS : ordre unique (40 §3). L'envoi est d'abord LU sans verrou ; puis, si besoin,
--     N0 exclusif (pause d'un canal, décidée avant tout autre verrou), N1 (campagne), N3
--     (consentements, par client croissant), N4 (l'envoi, relu).
--   · SECRETS : rien du coffre n'apparaît dans une réponse ou un journal ; les refus ne
--     disent pas pourquoi (seul le fournisseur est noté dans les journaux).
create or replace function public.communication_recevoir_evenement(p_fournisseur text, p_charge text, p_signature text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
as $$
declare
  r public.communication_reglages;
  v_cle text;
  p jsonb;
  v_type text;
  v_survenu timestamptz;
  e public.communication_envois;
  v_envoi bigint;
  v_campagne uuid;
  v_ref bigint;
  v_id bigint;
  v_empreinte text;
  v_mot text;
  v_code text;
  v_appels integer;
  v_clients uuid[];
  v_client uuid;
  f public.communication_confirmations;
  k public.communication_consentements;
  a public.communication_codes_fournisseur;
  v_rang_actuel integer;
  v_rang_nouveau integer;
begin
  -- Contrôles bon marché AVANT toute lecture du coffre (revue 1.1, M6)
  if p_fournisseur is null or p_fournisseur not in ('meta', 'brevo', 'resend') or p_charge is null or length(p_charge) > 20000
     or coalesce(p_signature, '') !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('ok', false);
  end if;
  -- 1.3.1 (IR-08) : un STOP ne doit JAMAIS être perdu. Ordre : forme ; puis débit, SAUF pour un
  -- message entrant ; puis signature. Un horodatage illisible ou dans le futur ne fait plus
  -- refuser un message entrant : il est simplement ignoré (la fenêtre de 24 h n'est pas touchée).
  begin
    p := p_charge::jsonb;
  exception when others then
    return jsonb_build_object('ok', false, 'format', true);
  end;
  v_type := p ->> 'type';
  if jsonb_typeof(p) <> 'object' or coalesce(p ->> 'id', '') = '' or length(p ->> 'id') > 200
     or v_type is null or v_type not in ('sent', 'delivered', 'read', 'failed', 'hard_bounce', 'soft_bounce',
                                         'complaint', 'unsubscribe', 'blocked', 'inbound') then
    return jsonb_build_object('ok', false, 'format', true);
  end if;
  begin
    v_survenu := (p ->> 'survenu_le')::timestamptz;
  exception when others then
    v_survenu := null;
  end;
  select * into r from public.communication_reglages;
  if v_type <> 'inbound' then
    -- Débit (C7), compté AVANT la signature (un flot d'appels faux est lui aussi borné), sur huit
    -- éclats par minute ; jamais pour un message entrant
    insert into public.communication_webhook_debit (minute, fournisseur, eclat, appels)
    values (date_trunc('minute', clock_timestamp()), p_fournisseur, (txid_current() % 8)::smallint, 1)
    on conflict (minute, fournisseur, eclat) do update set appels = public.communication_webhook_debit.appels + 1;
    select coalesce(sum(w.appels), 0) into v_appels from public.communication_webhook_debit w
     where w.minute = date_trunc('minute', clock_timestamp()) and w.fournisseur = p_fournisseur;
    if v_appels > r.webhook_max_minute then
      return jsonb_build_object('ok', false, 'sature', true);   -- la fonction Edge répond 5xx : le fournisseur réessaie
    end if;
  end if;
  v_cle := public.lire_reglage('communication_cle_webhook');
  if coalesce(v_cle, '') = ''
     or p_signature <> encode(extensions.hmac(p_fournisseur || ':' || p_charge, v_cle, 'sha256'), 'hex') then
    raise log 'goship communication webhook signature refusee fournisseur=%', p_fournisseur;   -- détection d'abus (journaux)
    return jsonb_build_object('ok', false);
  end if;
  if v_survenu > now() + interval '5 minutes' then
    if v_type <> 'inbound' then
      return jsonb_build_object('ok', false, 'futur', true);
    end if;
    v_survenu := null;                                          -- entrant : traité, sans horodatage
  end if;

  -- L'envoi concerné, LU SANS VERROU. 1.3.1 (IR-06) : par la RÉFÉRENCE d'abord (posée par nous),
  -- puis par l'identifiant du fournisseur
  if v_type <> 'inbound' then
    if (p ->> 'reference') ~ '^communication:[0-9]{1,18}$' then
      v_ref := split_part(p ->> 'reference', ':', 2)::bigint;
      select id, campagne_id into v_envoi, v_campagne from public.communication_envois
       where id = v_ref and fournisseur = p_fournisseur;
    end if;
    if v_envoi is null then
      select id, campagne_id into v_envoi, v_campagne from public.communication_envois
       where fournisseur = p_fournisseur and message_id = p ->> 'message_id';
    end if;
  end if;
  -- 1.3.1 (revue n° 2, IR2-06) : un message entrant dont on ne peut pas calculer l'empreinte
  -- (poivre absent, numéro manquant) lève une ERREUR : rien n'est enregistré, pas même le rejeu,
  -- la fonction Edge répond 5xx et le fournisseur réessaie. Avant, la ligne de rejeu était
  -- validée et le STOP réessayé était pris pour un doublon : perdu pour toujours.
  if v_type = 'inbound' then
    v_empreinte := public.communication_empreinte('whatsapp', p ->> 'telephone');
    if v_empreinte is null then
      raise exception 'EMPREINTE_INDISPONIBLE';
    end if;
  end if;
  -- Rejeu : l'identifiant de l'événement est unique ; un événement déjà reçu ne refait rien.
  -- 1.3.1 (IR-07) : pour un message ENTRANT, ni son identifiant chez Meta ni rien qui le relie au
  -- numéro n'est gardé — seulement l'empreinte SHA-256 de son identifiant, pour le rejeu.
  insert into public.communication_evenements_fournisseur (fournisseur, evenement_id, type, message_id, reference, envoi_id, code, survenu_le)
  values (p_fournisseur,
          case when v_type = 'inbound' then 'in:' || encode(extensions.digest(p ->> 'id', 'sha256'), 'hex')
               else left(p ->> 'id', 200) end,
          v_type,
          case when v_type = 'inbound' then null else left(p ->> 'message_id', 200) end,
          left(p ->> 'reference', 60), v_envoi, left(p ->> 'code', 60), v_survenu)
  on conflict (fournisseur, evenement_id) do nothing
  returning id into v_id;
  if v_id is null then
    return jsonb_build_object('ok', true, 'rejeu', true);      -- déjà traité : rien de plus, rien de moins
  end if;

  -- Message entrant (WhatsApp) : fenêtre de 24 h, STOP, confirmation. Le contenu n'est jamais gardé.
  if v_type = 'inbound' then
    if v_survenu is not null then
      insert into public.communication_fenetres_whatsapp (cible_empreinte, dernier_entrant)
      values (v_empreinte, least(v_survenu, now()))
      on conflict (cible_empreinte) do update
        set dernier_entrant = greatest(public.communication_fenetres_whatsapp.dernier_entrant, excluded.dernier_entrant);
    end if;
    if public.communication_est_stop(p ->> 'texte') then
      insert into public.communication_suppressions (canal, cible_empreinte, raison, source)
      values ('whatsapp', v_empreinte, 'stop', 'whatsapp_entrant') on conflict do nothing;
      -- N3 pour CHAQUE client qui a ce numéro, par identifiant CROISSANT (deux STOP simultanés
      -- prennent les verrous dans le même ordre)
      select coalesce(array_agg(c.id order by c.id), '{}') into v_clients from public.clients c
       where public.communication_empreinte('whatsapp', public.telephone_international(c.telephone, c.pays)) = v_empreinte;
      foreach v_client in array v_clients loop
        perform public.communication_verrou('consentement:' || v_client || ':whatsapp');
        insert into public.communication_consentements (client_id, canal, action, source, cible_empreinte, contexte)
        values (v_client, 'whatsapp', 'retire', 'whatsapp_stop', v_empreinte,
                jsonb_build_object('survenu_le', v_survenu));
        update public.communication_confirmations set annule_le = clock_timestamp()
         where client_id = v_client and canal = 'whatsapp' and utilise_le is null and annule_le is null;
      end loop;
      return jsonb_build_object('ok', true, 'stop', true);
    end if;
    -- Confirmation : « <mot> <code> » depuis le numéro dont l'empreinte est celle de la demande.
    -- La demande est d'abord LUE sans verrou, puis N3, puis la ligne est verrouillée et RELUE
    -- (même ordre que demander_consentement_communication, qui prend N3 avant d'annuler).
    v_mot := split_part(public.communication_mot_simple(p ->> 'texte'), ' ', 1);
    v_code := split_part(public.communication_mot_simple(p ->> 'texte'), ' ', 2);
    if v_mot in ('OUI', 'YES', 'SI', 'WI') and v_code ~ '^[0-9]{4}$' then
      select * into f from public.communication_confirmations
       where canal = 'whatsapp' and cible_empreinte = v_empreinte and code = v_code
         and utilise_le is null and annule_le is null and expire_le > now()
       order by id desc limit 1;
      if found then
        perform public.communication_verrou('consentement:' || f.client_id || ':whatsapp');
        select * into f from public.communication_confirmations
         where id = f.id and utilise_le is null and annule_le is null and expire_le > now() for update;
        if found
           and (public.communication_etat_consentement(f.client_id, 'whatsapp') ->> 'etat') = 'en_attente'
           and public.communication_empreinte('whatsapp', public.communication_cible(f.client_id, 'whatsapp')) = f.cible_empreinte then
          select * into k from public.communication_consentements where id = f.consentement_id;
          update public.communication_confirmations set utilise_le = clock_timestamp() where id = f.id;
          insert into public.communication_consentements (client_id, canal, action, source, texte_version, texte_empreinte,
                                                          langue, cible_empreinte, contexte)
          values (f.client_id, 'whatsapp', 'confirme', 'whatsapp_confirmation', k.texte_version, k.texte_empreinte, k.langue,
                  v_empreinte, jsonb_build_object('survenu_le', v_survenu));
          update public.communication_suppressions
             set leve_le = clock_timestamp(), motif_levee = 'Nouvelle inscription confirmée par le contact'
           where canal = 'whatsapp' and cible_empreinte = v_empreinte and leve_le is null and raison in ('desinscription', 'stop');
          return jsonb_build_object('ok', true, 'confirme', true);
        end if;
      end if;
    end if;
    return jsonb_build_object('ok', true);
  end if;

  if v_envoi is null then
    return jsonb_build_object('ok', true, 'inconnu', true);
  end if;

  -- Ce que dit un code d'erreur (table des codes, H11) — lu AVANT les verrous
  if p ->> 'code' is not null then
    select * into a from public.communication_codes_fournisseur where fournisseur = p_fournisseur and code = p ->> 'code';
  end if;
  -- N1 la campagne, N3 le consentement (si l'événement peut retirer), puis N4 l'envoi, RELU
  if v_campagne is not null then
    perform 1 from public.communication_campagnes where id = v_campagne for update;
  end if;
  select * into e from public.communication_envois where id = v_envoi;
  if v_type in ('complaint', 'unsubscribe') or a.action = 'suppression_contact' then
    perform public.communication_verrou('consentement:' || e.client_id || ':' || e.canal);
  end if;
  select * into e from public.communication_envois where id = v_envoi for update;

  -- Statut d'un message : jamais en arrière ; un incertain retrouvé est rapproché (H8)
  v_rang_actuel := case e.statut when 'livre' then 2 when 'lu' then 3 when 'envoye' then 1 else 0 end;
  v_rang_nouveau := case v_type when 'sent' then 1 when 'delivered' then 2 when 'read' then 3 else 0 end;
  if v_rang_nouveau > 0 and v_rang_nouveau > v_rang_actuel and e.statut in ('traitement', 'envoye', 'livre', 'incertain') then
    update public.communication_envois
       set statut = case v_rang_nouveau when 1 then 'envoye' when 2 then 'livre' else 'lu' end,
           message_id = coalesce(message_id, left(p ->> 'message_id', 200)),
           envoye_le = coalesce(envoye_le, v_survenu, now()),
           livre_le = case when v_rang_nouveau >= 2 then coalesce(livre_le, v_survenu, now()) else livre_le end,
           lu_le = case when v_rang_nouveau = 3 then coalesce(lu_le, v_survenu, now()) else lu_le end,
           incertain_clos_le = null, maj_le = now()
     where id = e.id;
  elsif v_type in ('failed', 'hard_bounce', 'blocked') and e.statut in ('traitement', 'envoye', 'incertain') then
    update public.communication_envois set statut = 'echec', code_erreur = left(coalesce(p ->> 'code', upper(v_type)), 60),
           incertain_clos_le = null, maj_le = now() where id = e.id;
  end if;

  if a.action = 'suppression_contact' and e.cible_empreinte is not null then
    insert into public.communication_suppressions (canal, cible_empreinte, client_id, raison, source)
    values (e.canal, e.cible_empreinte, e.client_id, 'opposition_meta', p_fournisseur) on conflict do nothing;
    if e.client_id is not null then                          -- envoi anonymisé : la suppression suffit
      insert into public.communication_consentements (client_id, canal, action, source, cible_empreinte)
      values (e.client_id, e.canal, 'retire', 'opposition_meta', e.cible_empreinte);
    end if;
  elsif a.action = 'pause_campagne' and e.campagne_id is not null then
    update public.communication_campagnes set statut = 'en_pause', arret_motif = 'CODE_' || (p ->> 'code'), maj_le = now()
     where id = e.campagne_id and statut = 'en_cours';
  -- Phase 1.3.1 : un report CRÉE un nouvel envoi ; il exige donc un code dont le sens est VÉRIFIÉ
  -- (communication_codes_fournisseur.verifie). Les actions qui ne font que protéger (suppression,
  -- pauses) restent appliquées même non vérifiées : elles ne peuvent qu'empêcher un envoi.
  elsif a.action = 'reporter_destinataire' and a.verifie and e.relance_de is null and e.campagne_id is not null then
    insert into public.communication_envois (nature, campagne_id, destinataire_id, client_id, canal, cle, cible_empreinte,
                                             territoire, fournisseur, prochain_essai_le, relance_de)
    values ('campagne', e.campagne_id, e.destinataire_id, e.client_id, e.canal, e.cle || ':report', e.cible_empreinte,
            e.territoire, e.fournisseur, now() + make_interval(hours => coalesce(a.delai_heures, 24)), e.id)
    on conflict (cle) do nothing;                             -- une seule fois
  end if;

  -- Rebond définitif, plainte, désinscription chez le fournisseur : suppression du contact EXACT
  -- visé par l'envoi ; retrait seulement pour une plainte ou une désinscription (pas un rebond)
  if v_type in ('hard_bounce', 'complaint', 'unsubscribe') and e.cible_empreinte is not null then
    insert into public.communication_suppressions (canal, cible_empreinte, client_id, raison, source)
    values (e.canal, e.cible_empreinte, e.client_id,
            case v_type when 'complaint' then 'plainte' when 'unsubscribe' then 'desinscription' else 'rebond_definitif' end,
            p_fournisseur)
    on conflict do nothing;
    if v_type in ('complaint', 'unsubscribe') and e.client_id is not null then
      insert into public.communication_consentements (client_id, canal, action, source, cible_empreinte)
      values (e.client_id, e.canal, 'retire', case v_type when 'complaint' then 'plainte' else 'lien_desinscription' end,
              e.cible_empreinte);
    end if;
  end if;
  -- Coupure du canal demandée par un code de Meta (Phase 1.3.1) : écrite SANS prendre N0 (un
  -- retour de fournisseur ne doit pas attendre les envois), donc AU MIEUX — ce n'est PAS un arrêt
  -- confirmé et rien ne le présente comme tel : un envoi déjà autorisé peut encore valider. Écrite EN DERNIER (IR-04) :
  -- la ligne des réglages n'est tenue qu'un instant. Elle est journalisée ; pour une garantie, l'administrateur utilise l'arrêt d'urgence (41 §4.8).
  -- Avant 1.3.1, elle tentait N0 exclusif puis écrivait « quand même » : même défaut que l'arrêt.
  if a.action = 'pause_canal' then
    update public.communication_reglages set whatsapp_actif = false, maj_le = now() where p_fournisseur = 'meta';
    insert into public.communication_erreurs (source, code, detail)
    values ('fournisseur', 'PAUSE_CANAL_NON_CONFIRMEE', p_fournisseur || ':' || (p ->> 'code'));
  end if;
  return jsonb_build_object('ok', true);
end;
$$;


-- 10. La désinscription par le lien (revue 1.1, H5) -------------------------------------------------------
-- Ouverte sans compte (liste blanche de controle-securite.sql). Jeton vérifié par HMAC ;
-- idempotente ; ne renvoie aucune donnée personnelle. Bloque le contact EXACT qui a reçu le
-- message (empreinte de l'envoi), jamais la nouvelle adresse d'un client qui a changé de contact.
create or replace function public.desinscrire_communication(p_jeton text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
  e public.communication_envois;
  v_attendu text;
begin
  if coalesce(p_jeton, '') !~ '^[0-9]{1,18}\.[A-Za-z0-9_-]{32}$' then
    return jsonb_build_object('ok', false);
  end if;
  v_id := split_part(p_jeton, '.', 1)::bigint;
  v_attendu := public.communication_jeton_desinscription(v_id);
  if v_attendu is null or v_attendu <> p_jeton then
    return jsonb_build_object('ok', false);
  end if;
  select * into e from public.communication_envois where id = v_id;
  if not found then
    return jsonb_build_object('ok', false);
  end if;
  -- 1.3.1 (IR-09) : ne JAMAIS répondre « fait » sans avoir rien écrit.
  --   · personne EFFACÉE (clé « efface:… ») : ses consentements sont anonymisés, rien ne peut plus
  --     lui être envoyé à partir de ce compte : réponse vraie, « efface » ;
  --   · empreinte effacée à l'échéance « empreintes » : on ne sait plus quel contact bloquer :
  --     « lien_expire », et la page propose les autres moyens (compte, réponse STOP, équipe).
  -- La purge à l'échéance « envois » GARDE l'empreinte du contact (jusqu'à « empreintes ») : un
  -- vieux lien reste efficace aussi longtemps qu'un consentement peut l'être.
  if e.cle like 'efface:%' then
    return jsonb_build_object('ok', true, 'canal', e.canal, 'efface', true);
  end if;
  if e.cible_empreinte is null then
    return jsonb_build_object('ok', false, 'lien_expire', true, 'canal', e.canal);
  end if;
  -- 1.3.1 (IR-13) : N3 AVANT l'insertion de la suppression (même ordre que les retours des
  -- fournisseurs, qui prennent N3 puis insèrent) — sinon un clic et une plainte simultanés
  -- s'attendaient l'un l'autre sur l'index unique des suppressions.
  perform public.communication_verrou('consentement:' || e.client_id || ':' || e.canal);
  -- IR2-07 : RELU sous N3 — une purge a pu passer entre la première lecture et le verrou
  select * into e from public.communication_envois where id = v_id;
  if e.cle like 'efface:%' then
    return jsonb_build_object('ok', true, 'canal', e.canal, 'efface', true);
  end if;
  if e.cible_empreinte is null then
    return jsonb_build_object('ok', false, 'lien_expire', true, 'canal', e.canal);
  end if;
  insert into public.communication_suppressions (canal, cible_empreinte, client_id, raison, source)
  values (e.canal, e.cible_empreinte, e.client_id, 'desinscription', 'lien')
  on conflict do nothing;
  -- Le retrait n'est écrit que si le consentement actif porte sur CE contact
  if public.communication_consentement_actuel(e.client_id, e.canal)
     and public.communication_empreinte(e.canal, public.communication_cible(e.client_id, e.canal)) = e.cible_empreinte then
    insert into public.communication_consentements (client_id, canal, action, source, cible_empreinte)
    values (e.client_id, e.canal, 'retire', 'lien_desinscription', e.cible_empreinte);
  end if;
  return jsonb_build_object('ok', true, 'canal', e.canal);
end;
$$;


-- 11. Relancer à la main (revue 1.1, H8, M4) -----------------------------------------------------------
-- Administrateur seulement, motif obligatoire, journalisé. Un message INCERTAIN est peut-être
-- déjà parti : la relance exige de cocher explicitement le risque de doublon. Un message mort
-- (« abandon ») n'est jamais parti. La relance crée un NOUVEL envoi (clé « …:relance:n »),
-- soumis à toutes les règles (consentement, suppression, plafonds, heures, fréquence).
create or replace function public.relancer_envoi_communication(p_envoi bigint, p_motif text, p_risque_doublon_accepte boolean)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  e public.communication_envois;
  v_n integer;
  v_id bigint;
begin
  perform public.exiger_permission('communications.approve');
  if length(trim(coalesce(p_motif, ''))) < 10 then
    perform public.erreur_metier('REASON_REQUIRED', 'Dites pourquoi ce message doit repartir (10 caractères au moins).');
  end if;
  select * into e from public.communication_envois where id = p_envoi for update;
  if not found or e.statut not in ('incertain', 'abandon') or e.nature <> 'campagne' then
    perform public.erreur_metier('INVALID_TRANSITION', 'Seul un message incertain ou mort se relance.');
  end if;
  if e.statut = 'incertain' and not coalesce(p_risque_doublon_accepte, false) then
    perform public.erreur_metier('DUPLICATE_RISK', 'Ce message est peut-être déjà arrivé : confirmez que vous acceptez le risque de doublon.');
  end if;
  select count(*) into v_n from public.communication_envois where relance_de = e.id;
  insert into public.communication_envois (nature, campagne_id, destinataire_id, client_id, canal, cle, cible_empreinte,
                                           territoire, fournisseur, relance_de)
  values ('campagne', e.campagne_id, e.destinataire_id, e.client_id, e.canal, e.cle || ':relance:' || (v_n + 1),
          e.cible_empreinte, e.territoire, e.fournisseur, e.id)
  returning id into v_id;
  perform set_config('goship.motif', trim(p_motif), true);
  perform public.auditer('communication.relance', 'communication_envoi', e.id::text,
                         jsonb_build_object('statut', e.statut), jsonb_build_object('nouvel_envoi', v_id, 'risque_doublon', p_risque_doublon_accepte));
  return v_id;
end;
$$;


-- 12. Purge des autres catégories (revue 1.1, C5 ; Phase 1.3, C5) — appelée par executer_purge_communication (40)
-- Même règle : seulement dans une purge approuvée (goship.purge_demande posé par la fonction
-- de 40), chaque opération comptée au journal des purges, jamais les données elles-mêmes.
-- Phase 1.3 — ce qui change (inventaire table par table : PHASE_1_3_TECHNICAL_CORRECTIONS §5) :
--   · envois : en plus du client et de l'identifiant du fournisseur, l'empreinte du contact, la
--     requête pg_net et l'empreinte du contenu sont effacées (identifiants INDIRECTS) ;
--   · audiences : AVANT, une ligne n'était effacée que si AUCUN envoi ne la citait — donc
--     presque jamais (toute ligne retenue a un envoi). Elles sont désormais ANONYMISÉES (client
--     et empreinte du contact effacés), ce qui ne dépend plus des envois ;
--   · retours des fournisseurs : effacés à l'échéance (déjà) ;
--   · suppressions : à l'échéance « suppressions », le lien au compte s'efface ; les
--     suppressions LEVÉES depuis plus longtemps que « empreintes » sont effacées ; une
--     suppression ACTIVE n'est jamais effacée (elle fait respecter une désinscription) ;
--   · « empreintes » (nouvelle) : efface l'empreinte de contact des consentements DÉJÀ
--     anonymisés, et les suppressions levées ;
--   · compteurs techniques (débit par minute, retours par minute) : nettoyés par le
--     travailleur, sans donnée personnelle.
create or replace function public.communication_purger_autres(p_demande bigint, p_categorie text, p_avant timestamptz)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n integer;
  v_operation text := 'anonymiser';
begin
  if p_categorie = 'envois' then
    -- 1.3.1 (IR-09) : l'empreinte du contact est GARDÉE ici (elle fait marcher les vieux liens de
    -- désinscription) et n'est effacée qu'à l'échéance « empreintes ». (IR-13) : lignes
    -- verrouillées d'abord par identifiant croissant.
    perform 1 from public.communication_envois
     where cree_le < p_avant and statut not in ('attente', 'traitement', 'nouvel_essai') and client_id is not null
     order by id for update;
    update public.communication_envois
       set client_id = null, message_id = null, empreinte_contenu = null,
           requete = case when public.communication_en_transmission(requete, sortie_file_vue_le) then requete end
     where cree_le < p_avant and statut not in ('attente', 'traitement', 'nouvel_essai')
       and (client_id is not null or cible_empreinte is not null or message_id is not null);
  elsif p_categorie = 'destinataires' then
    update public.communication_destinataires set client_id = null, cible_empreinte = null
     where cree_le < p_avant and (client_id is not null or cible_empreinte is not null);
  elsif p_categorie = 'campagnes' then
    update public.communication_campagnes set description = '' where terminee_le < p_avant and description <> '';
  elsif p_categorie = 'evenements_fournisseur' then
    delete from public.communication_evenements_fournisseur where recu_le < p_avant;
    v_operation := 'effacer';
  elsif p_categorie = 'fenetres_whatsapp' then
    delete from public.communication_fenetres_whatsapp where dernier_entrant < p_avant;
    v_operation := 'effacer';
  elsif p_categorie = 'suppressions' then
    -- 1.3.1 (IR-07) : aussi les champs de levée et l'auteur (texte libre, comptes de l'équipe)
    update public.communication_suppressions
       set client_id = null, motif = null, motif_levee = null, leve_par = null, auteur_id = null
     where cree_le < p_avant and (client_id is not null or motif is not null or motif_levee is not null);
  elsif p_categorie = 'erreurs' then
    delete from public.communication_erreurs where cree_le < p_avant;
    v_operation := 'effacer';
  elsif p_categorie = 'empreintes' then
    update public.communication_consentements set cible_empreinte = null
     where anonymise_le is not null and anonymise_le < p_avant and cible_empreinte is not null;
    get diagnostics v_n = row_count;
    insert into public.communication_journal_purges (demande_id, table_nom, operation, lignes, avant, execute_par)
    values (p_demande, 'communication_consentements', 'anonymiser', v_n, p_avant, auth.uid());
    delete from public.communication_suppressions where leve_le is not null and leve_le < p_avant;
    get diagnostics v_n = row_count;
    insert into public.communication_journal_purges (demande_id, table_nom, operation, lignes, avant, execute_par)
    values (p_demande, 'communication_suppressions', 'effacer', v_n, p_avant, auth.uid());
    -- 1.3.1 (IR-09) : l'empreinte des envois DÉJÀ anonymisés part à cette échéance seulement
    update public.communication_envois set cible_empreinte = null
     where cree_le < p_avant and client_id is null and cible_empreinte is not null
       and statut not in ('attente', 'traitement', 'nouvel_essai');
    get diagnostics v_n = row_count;
    insert into public.communication_journal_purges (demande_id, table_nom, operation, lignes, avant, execute_par)
    values (p_demande, 'communication_envois', 'anonymiser', v_n, p_avant, auth.uid());
    return;
  else
    perform public.erreur_metier('INVALID_CATEGORY', 'Catégorie inconnue.');
  end if;
  get diagnostics v_n = row_count;
  insert into public.communication_journal_purges (demande_id, table_nom, operation, lignes, avant, execute_par)
  values (p_demande, 'communication_' || p_categorie, v_operation, v_n, p_avant, auth.uid());
end;
$$;

-- Effacement demandé par une personne : la suite de 40. p_empreintes = ses empreintes de
-- contact, recueillies par 40 AVANT toute anonymisation (contact actuel et historique).
-- Gardé : les SUPPRESSIONS (empreinte seule, déliée du compte) — elles empêchent de lui écrire
-- de nouveau ; leur durée suit la politique de conservation (BLOQUÉE, juriste).
create or replace function public.communication_purger_personne_suite(p_demande bigint, p_client uuid, p_empreintes text[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  -- Retours des fournisseurs liés à SES envois : identifiants du fournisseur et référence
  -- effacés ; l'identifiant d'événement est remplacé (il contenait l'identifiant du message)
  update public.communication_evenements_fournisseur
     set message_id = null, reference = null, evenement_id = 'efface:' || id
   where envoi_id in (select id from public.communication_envois where client_id = p_client);
  get diagnostics v_n = row_count;
  insert into public.communication_journal_purges (demande_id, table_nom, operation, lignes, execute_par)
  values (p_demande, 'communication_evenements_fournisseur', 'anonymiser', v_n, auth.uid());
  -- Envois : plus rien qui mène à la personne (client, contact, fournisseur, requête, contenu).
  -- 1.3.1 (IR-02) : la clé aussi (elle contenait l'identifiant du client) ; (IR-13) : lignes
  -- verrouillées d'abord par identifiant croissant, comme l'annulation de campagne.
  perform 1 from public.communication_envois where client_id = p_client order by id for update;
  update public.communication_envois
     set client_id = null, message_id = null, cible_empreinte = null, empreinte_contenu = null,
         cle = 'efface:' || id,                    -- « requete » GARDÉE : pas une donnée personnelle (IR2-02)
         statut = case when statut in ('attente', 'nouvel_essai') then 'supprime' else statut end,
         code_erreur = case when statut in ('attente', 'nouvel_essai') then 'EFFACEMENT' else code_erreur end
   where client_id = p_client;
  get diagnostics v_n = row_count;
  insert into public.communication_journal_purges (demande_id, table_nom, operation, lignes, execute_par)
  values (p_demande, 'communication_envois', 'anonymiser', v_n, auth.uid());
  -- Audiences : client et contact effacés
  update public.communication_destinataires set client_id = null, cible_empreinte = null where client_id = p_client;
  get diagnostics v_n = row_count;
  insert into public.communication_journal_purges (demande_id, table_nom, operation, lignes, execute_par)
  values (p_demande, 'communication_destinataires', 'anonymiser', v_n, auth.uid());
  -- Suppressions : déliées du compte, empreinte GARDÉE
  update public.communication_suppressions
     set client_id = null, motif = null, motif_levee = null, leve_par = null, auteur_id = null
   where client_id = p_client;
  get diagnostics v_n = row_count;
  insert into public.communication_journal_purges (demande_id, table_nom, operation, lignes, execute_par)
  values (p_demande, 'communication_suppressions', 'anonymiser', v_n, auth.uid());
  -- Fenêtres WhatsApp : clé = empreinte du numéro, sans client_id — retrouvées par ses empreintes
  delete from public.communication_fenetres_whatsapp where cible_empreinte = any (coalesce(p_empreintes, '{}'));
  get diagnostics v_n = row_count;
  insert into public.communication_journal_purges (demande_id, table_nom, operation, lignes, execute_par)
  values (p_demande, 'communication_fenetres_whatsapp', 'effacer', v_n, auth.uid());
  delete from public.communication_destinataires_essai where client_id = p_client;
  get diagnostics v_n = row_count;
  insert into public.communication_journal_purges (demande_id, table_nom, operation, lignes, execute_par)
  values (p_demande, 'communication_destinataires_essai', 'effacer', v_n, auth.uid());
end;
$$;


-- 13. Santé et planificateur -------------------------------------------------------------------------------
-- Les requêtes DÉJÀ VALIDÉES qui peuvent encore partir (Phase 1.3.1, corrigé après la revue
-- indépendante n° 2, IR2-01 : la version précédente faisait partir le délai du DÉPÔT de la
-- requête ; une file pg_net en retard pouvait alors laisser croire « plus rien en route » pendant
-- qu'un appel commençait). Lecture SEULE des tables de pg_net (rien n'y est écrit ni effacé).
-- Une requête est « en transmission » tant qu'elle n'a pas de réponse ET :
--   · elle est encore dans la file de pg_net, OU
--   · nous ne l'avons pas encore VUE hors de la file, OU
--   · nous l'avons vue hors de la file depuis moins que le délai HTTP + 60 s.
-- Au-delà, pg_net a forcément terminé ou abandonné l'appel (délai appliqué par pg_net : rapporté,
-- à éprouver). Compté PAR REQUÊTE, quel que soit le statut de l'envoi (un retour tardif d'une
-- tentative précédente ne la fait plus disparaître).
create or replace function public.communication_en_transmission(p_requete bigint, p_sortie_vue timestamptz)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_requete is not null
     and not exists (select 1 from net._http_response x where x.id = p_requete)
     and (exists (select 1 from net.http_request_queue q where q.id = p_requete)
          or p_sortie_vue is null
          -- Revue n° 3 (IR3-06) : le délai MAXIMAL permis (60 s, contrainte de delai_http_ms) + 60 s,
          -- et non le réglage du moment, qui a pu être réduit après le dépôt de la requête
          or p_sortie_vue > now() - interval '120 seconds')
$$;

-- Noter le premier instant où une requête est vue hors de la file (appelée par la lecture des
-- réponses et par le constat d'arrêt, avant de compter). Lignes en « skip locked ».
create or replace function public.communication_observer_sorties()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n integer;
  v_m integer;
begin
  update public.communication_envois set sortie_file_vue_le = clock_timestamp()
   where id in (select e.id from public.communication_envois e
                 where e.requete is not null and e.sortie_file_vue_le is null
                   and not exists (select 1 from net.http_request_queue q where q.id = e.requete)
                 for update skip locked);
  get diagnostics v_n = row_count;
  -- Revue n° 3 (IR3-03) : les lectures de modèles chez Meta aussi
  update public.communication_modeles_meta set sortie_file_vue_le = clock_timestamp()
   where id in (select m.id from public.communication_modeles_meta m
                 where m.requete is not null and m.sortie_file_vue_le is null
                   and not exists (select 1 from net.http_request_queue q where q.id = m.requete)
                 for update skip locked);
  get diagnostics v_m = row_count;
  return v_n + v_m;
end;
$$;

-- Revue n° 3 (IR3-02) : le décompte ne parcourt que les requêtes RÉCENTES ou pas encore vues hors
-- de la file (index partiels ci-dessous), pas tout l'historique, dans la transaction de l'arrêt
create index if not exists communication_envois_non_vues_idx
  on public.communication_envois (id) where requete is not null and sortie_file_vue_le is null;
create index if not exists communication_envois_sorties_idx
  on public.communication_envois (sortie_file_vue_le) where requete is not null;
create index if not exists communication_modeles_meta_non_vues_idx
  on public.communication_modeles_meta (id) where requete is not null and sortie_file_vue_le is null;

create or replace function public.communication_transmissions_en_cours()
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select (select count(*)::integer from public.communication_envois e
           where e.requete is not null and e.remis_le is not null
             and (e.sortie_file_vue_le is null or e.sortie_file_vue_le > now() - interval '120 seconds')
             and public.communication_en_transmission(e.requete, e.sortie_file_vue_le))
       + (select count(*)::integer from public.communication_modeles_meta m      -- IR3-03 : lectures Meta
           where m.requete is not null
             and (m.sortie_file_vue_le is null or m.sortie_file_vue_le > now() - interval '120 seconds')
             and public.communication_en_transmission(m.requete, m.sortie_file_vue_le))
$$;

create or replace function public.sante_communications()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('communications.view');
  return jsonb_build_object(
    'reglages', (select to_jsonb(r) - 'identite_validee_par' - 'maj_par' - 'brevo_quota_verifie_par' from public.communication_reglages r),
    'arret', (select to_jsonb(a) - 'demande_par' - 'leve_par' from public.communication_arret a),
    'transmissions_en_cours', public.communication_transmissions_en_cours(),
    'brevo', public.communication_brevo_disponible(),
    'depenses_du_jour', (select coalesce(jsonb_agg(to_jsonb(d)), '[]'::jsonb)
                           from public.communication_depenses_jour d where d.jour = public.communication_jour()),
    'file', (select coalesce(jsonb_object_agg(statut, n), '{}'::jsonb)
               from (select statut, count(*) n from public.communication_envois group by statut) s),
    'messages_morts', (select count(*) from public.communication_envois where statut = 'abandon'),
    'incertains', (select count(*) from public.communication_envois where statut = 'incertain'),
    'en_cours_bloques', (select count(*) from public.communication_envois
                          where statut = 'traitement' and verrouille_le < now() - interval '15 minutes'),
    'erreurs_24h', (select count(*) from public.communication_erreurs where cree_le > now() - interval '24 hours'),
    -- Signal C4 : e-mails TRANSACTIONNELS refusés pour adresse bloquée chez le fournisseur
    'transactionnel_bloque_7j', (select count(*) from public.notification_envois
                                  where canal = 'email' and code_erreur = 'ADRESSE_BLOQUEE' and maj_le > now() - interval '7 days'),
    'travailleur', (select jsonb_build_object('actif', j.active) from cron.job j where j.jobname = 'goship-communications'));
end;
$$;

-- Le travailleur : chaque minute (la minute suffit et reste alignée sur le transactionnel).
-- C'est lui qui cède la place (attente_transactionnel_max), pas l'horaire. Créé INACTIF : seul
-- l'administrateur l'allume, sur décision écrite du CEO, en plus de l'interrupteur
-- campagnes_actives qui reste éteint. Phase 1.3 : « call » d'une PROCÉDURE (COMMIT par envoi).
do $cron$
declare
  v_job bigint;
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 'goship-communications') then
      v_job := cron.schedule('goship-communications', '* * * * *', 'call public.traiter_communications()');
      perform cron.alter_job(v_job, active := false);
    end if;
  end if;
end
$cron$;

-- Nettoyage des compteurs techniques (aucune donnée personnelle) : fait par la lecture des
-- réponses, à chaque passage, sur ce qui a plus d'un jour.
create or replace function public.communication_nettoyer_compteurs()
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.communication_debit_minute where minute < now() - interval '1 day';
  delete from public.communication_webhook_debit where minute < now() - interval '1 day';
$$;


-- 14. Droits ------------------------------------------------------------------------------------------------
-- Le rôle des retours des fournisseurs (Phase 1.3, C7) : créé SANS connexion possible (NOLOGIN),
-- sans aucun autre droit que la fonction ci-dessous. Comment la fonction Edge l'utilisera (rôle
-- de connexion dédié, ou clé service_role) : DÉCISION DU CEO avant la Phase 3. Tant qu'elle
-- n'est pas prise, PERSONNE ne peut appeler communication_recevoir_evenement.
do $role$
begin
  if not exists (select 1 from pg_catalog.pg_roles where rolname = 'communication_webhook') then
    create role communication_webhook nologin noinherit;
  end if;
end
$role$;

do $droits$
declare
  f text;
begin
  -- Ouvertes à personne (appelées par d'autres fonctions, le travailleur ou un déclencheur)
  foreach f in array array[
    'public.communication_prochaine_fenetre(uuid, text)',
    'public.communication_frequence_atteinte(uuid)',
    'public.communication_reserver(public.communication_envois, numeric)',
    'public.communication_jeton_desinscription(bigint)', 'public.communication_textes_pied(text)',
    'public.communication_textes_confirmation(text)', 'public.communication_textes_pied_tous()',
    'public.communication_courriel_commercial(text, text, text, text, text, text)',
    'public.communication_appel_email(public.communication_envois, text, text, text, text)',
    'public.communication_appel_whatsapp(public.communication_envois, public.communication_modeles, text[])',
    'public.communication_lire_reponse(public.communication_envois, integer, text, text)',
    'public.communication_demander_envoi_confirmation(bigint)',
    'public.communication_lire_reponses()', 'public.communication_preparer()', 'public.communication_candidats()',
    'public.communication_rafraichir_modeles_meta()', 'public.communication_transmissions_en_cours()',
    'public.communication_en_transmission(bigint, timestamptz)', 'public.communication_observer_sorties()',
    'public.communication_traiter_un(bigint)', 'public.communication_clore_campagnes()',
    'public.communication_nettoyer_compteurs()',
    'public.communication_mot_simple(text)', 'public.communication_est_stop(text)',
    'public.communication_purger_autres(bigint, text, timestamptz)',
    'public.communication_purger_personne_suite(bigint, uuid, text[])'] loop
    execute 'revoke execute on function ' || f || ' from public, anon, authenticated, service_role';
  end loop;
  -- La procédure : son propriétaire (celui de la tâche pg_cron) seulement
  execute 'revoke execute on procedure public.traiter_communications() from public, anon, authenticated, service_role';
  foreach f in array array['public.relancer_envoi_communication(bigint, text, boolean)', 'public.sante_communications()'] loop
    execute 'revoke execute on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end
$droits$;

-- Les retours des fournisseurs : PLUS ouverts à « anon » (Phase 1.3, C7). Le rôle dédié
-- seulement ; deux portes (rôle, puis signature HMAC). Supabase accorde par défaut l'exécution
-- des nouvelles fonctions à anon, authenticated et service_role : on retire les trois.
revoke execute on function public.communication_recevoir_evenement(text, text, text) from public, anon, authenticated, service_role;
grant execute on function public.communication_recevoir_evenement(text, text, text) to communication_webhook;
-- La SEULE porte de ce fichier ouverte sans compte : protégée par sa signature HMAC (à ajouter
-- à la liste blanche de controle-securite.sql, section 6, avec confirmer_consentement_communication)
revoke execute on function public.desinscrire_communication(text) from public;
grant execute on function public.desinscrire_communication(text) to anon, authenticated;
-- ===== FIN DU CONTENU INERTE =====
$brouillon_goship_non_executable$ as brouillon_non_executable;
