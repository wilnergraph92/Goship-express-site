-- =============================================================================
-- BROUILLON — CENTRE DE COMMUNICATION — NE PAS EXÉCUTER
-- Version Phase 1.2 (18/11/2026) — voir l'en-tête de 40-supabase-communications-fondation.sql
-- =============================================================================
do $brouillon$
begin
  raise exception 'BROUILLON NON APPROUVÉ (Centre de communication, Phase 1.2) : ne pas exécuter.';
end;
$brouillon$;

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
--   · for update skip locked ; verrou du jour avant toute réservation ; verrou du client avant
--     le contrôle de fréquence (revue 1.1, H1, H4) ;
--   · dépense RÉSERVÉE avant l'appel, sous verrou ;
--   · consentement CONFIRMÉ, suppression, contact inchangé depuis le gel, liste d'essai, heures,
--     fréquence, modèle Meta conforme : revérifiés juste avant l'envoi ;
--   · issue inconnue = « incertain », JAMAIS renvoyé automatiquement (revue 1.1, H8) ;
--   · 3 essais au plus, seulement sur refus temporaire sûr (429, 5xx) ; au-delà : « abandon » ;
--   · un STOP, une plainte, une désinscription ne sont JAMAIS refusés pour leur âge (C6).
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
  confirmation_id   bigint references public.communication_confirmations (id),
  client_id         uuid,
  canal             text not null check (canal in ('email', 'whatsapp')),
  cle               text not null unique,                     -- campagne:<id>:<client>:<canal> | confirmation:<id>
  cible_empreinte   text,                                     -- le contact EXACT visé (revue 1.1, H5)
  territoire        text,
  statut            text not null default 'attente' check (statut in (
                      'attente', 'traitement', 'envoye', 'livre', 'lu', 'echec',
                      'nouvel_essai', 'supprime', 'annule', 'abandon', 'incertain')),
  fournisseur       text not null default '',
  tentative         integer not null default 0,
  prochain_essai_le timestamptz not null default now(),
  verrouille_le     timestamptz,
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
  check (nature <> 'confirmation' or confirmation_id is not null)
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
create index if not exists communication_envois_incertains_idx on public.communication_envois (maj_le) where statut = 'incertain' and incertain_clos_le is null;
alter table public.communication_envois enable row level security;
revoke all on public.communication_envois from anon, authenticated;


-- 2. Heures et fréquence (revue 1.1, H4) ------------------------------------------------------------
-- Heure locale du destinataire : Haïti, République dominicaine ; autres : heure de l'Est
-- (Floride), faute d'État connu. Fenêtre et fréquence à confirmer par le juriste (FTSA, TCPA).
create or replace function public.communication_fuseau(p_client uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case (select pays from public.clients where id = p_client)
           when 'HT' then 'America/Port-au-Prince'
           when 'DO' then 'America/Santo_Domingo'
           else 'America/New_York' end
$$;

create or replace function public.communication_prochaine_fenetre(p_client uuid)
returns timestamptz
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  r public.communication_reglages;
  v_tz text := public.communication_fuseau(p_client);
  v_local timestamp := now() at time zone v_tz;
begin
  select * into r from public.communication_reglages;
  if extract(hour from v_local) >= r.heure_debut and extract(hour from v_local) < r.heure_fin then
    return now();
  end if;
  return ((case when extract(hour from v_local) >= r.heure_fin then v_local::date + 1 else v_local::date end)
          + make_interval(hours => r.heure_debut)) at time zone v_tz;
end;
$$;

-- Fréquence atteinte ? Compte AUSSI les messages en cours et incertains (leur date d'envoi est
-- peut-être vide : on prend l'heure de remise à pg_net). Appelée SOUS le verrou du client, dans
-- la même transaction que la mise à « traitement » : deux campagnes ne passent pas ensemble.
create or replace function public.communication_frequence_atteinte(p_client uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select (select count(*) from public.communication_envois e
           where e.client_id = p_client and e.nature = 'campagne'
             and e.statut in ('traitement', 'envoye', 'livre', 'lu', 'incertain')
             and coalesce(e.envoye_le, e.verrouille_le) > now() - interval '24 hours') >= r.frequence_max_jour
      or (select count(*) from public.communication_envois e
           where e.client_id = p_client and e.nature = 'campagne'
             and e.statut in ('traitement', 'envoye', 'livre', 'lu', 'incertain')
             and coalesce(e.envoye_le, e.verrouille_le) > now() - interval '7 days') >= r.frequence_max_semaine
  from public.communication_reglages r
$$;


-- 3. La réservation de dépense (revue 1.1, H1, M7, H11) ------------------------------------------------
-- Ordre des verrous : jour, puis campagne (le verrou du client est pris avant, par l'appelant).
-- Renvoie null si l'envoi peut partir (dépense comptée), sinon le code de ce qui bloque.
-- Un refus définitif du fournisseur NE REND PAS la réservation (l'estimation reste au-dessus de
-- la réalité) ; une erreur avant l'appel annule la sous-transaction, donc la réservation aussi.
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
  v_messages integer;
  v_cout numeric;
begin
  select * into r from public.communication_reglages;
  perform public.communication_verrou('depenses:' || v_jour);

  if p_envoi.nature = 'campagne' then
    -- Relue SOUS verrou : une pause validée entre-temps arrête l'envoi (revue 1.1, M7)
    select * into c from public.communication_campagnes where id = p_envoi.campagne_id for update;
    if c.statut <> 'en_cours' then
      return 'CAMPAGNE_PAS_EN_COURS';
    end if;
    if c.messages_reserves + 1 > c.plafond_messages then return 'PLAFOND_CAMPAGNE_MESSAGES'; end if;
    if p_cout > 0 and c.cout_reserve_usd + p_cout > c.plafond_cout_usd then return 'PLAFOND_CAMPAGNE_COUT'; end if;
  end if;

  select coalesce(sum(messages), 0), coalesce(sum(cout_usd), 0) into v_messages, v_cout
    from public.communication_depenses_jour where jour = v_jour;
  if v_messages + 1 > r.plafond_jour_messages then return 'PLAFOND_JOUR_MESSAGES'; end if;
  if p_cout > 0 and v_cout + p_cout > r.plafond_jour_usd then return 'PLAFOND_JOUR_COUT'; end if;

  -- Limite quotidienne de destinataires du numéro WhatsApp commercial (valeur de Meta, H11)
  if p_envoi.canal = 'whatsapp' and (r.whatsapp_destinataires_jour is null or
       (select count(distinct e.client_id) from public.communication_envois e
         where e.canal = 'whatsapp' and e.statut in ('traitement', 'envoye', 'livre', 'lu', 'incertain')
           and coalesce(e.envoye_le, e.verrouille_le) > now() - interval '24 hours') + 1 > r.whatsapp_destinataires_jour) then
    return 'LIMITE_NUMERO_WHATSAPP';
  end if;

  insert into public.communication_depenses_jour (jour, fournisseur, canal, messages, cout_usd)
  values (v_jour, p_envoi.fournisseur, p_envoi.canal, 1, p_cout)
  on conflict (jour, fournisseur, canal) do update
    set messages = public.communication_depenses_jour.messages + 1,
        cout_usd = public.communication_depenses_jour.cout_usd + excluded.cout_usd;
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
  v_fournisseur text := coalesce(nullif(public.lire_reglage('communication_email_fournisseur'), ''), 'brevo');
  v_expediteur text := public.lire_reglage('communication_expediteur');
  v_nom text := public.lire_reglage('communication_nom');
  v_un_clic text := public.lire_reglage('communication_url_un_clic');
  v_entetes jsonb;
  v_delai integer := (select delai_http_ms from public.communication_reglages);
  v_requete bigint;
begin
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


-- 6. La réponse d'un appel (revue 1.1, H8) ------------------------------------------------------------
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
begin
  begin v_json := p_contenu::jsonb; exception when others then v_json := null; end;
  if p_erreur is null and p_code between 200 and 299 then
    v_id := coalesce(v_json ->> 'messageId', v_json ->> 'id', v_json -> 'messages' -> 0 ->> 'id');
    update public.communication_envois
       set statut = 'envoye', message_id = left(v_id, 200), envoye_le = coalesce(envoye_le, now()), code_erreur = null,
           verrouille_le = null, maj_le = now()
     where id = p_envoi.id and statut = 'traitement';
  elsif p_erreur is null and (p_code = 429 or p_code >= 500) and p_envoi.tentative < 3 then
    -- Refus temporaire SÛR (le fournisseur répond qu'il n'a rien accepté) : nouvel essai 2 min, 10 min, 1 h
    update public.communication_envois
       set statut = 'nouvel_essai', code_erreur = 'HTTP_' || p_code, verrouille_le = null, maj_le = now(),
           prochain_essai_le = now() + case p_envoi.tentative when 1 then interval '2 minutes'
                                                               when 2 then interval '10 minutes' else interval '1 hour' end
     where id = p_envoi.id and statut = 'traitement';
  elsif p_erreur is null and (p_code = 429 or p_code >= 500) then
    update public.communication_envois set statut = 'abandon', code_erreur = 'ABANDON_HTTP_' || p_code,
           verrouille_le = null, maj_le = now() where id = p_envoi.id and statut = 'traitement';
  elsif p_erreur is null and p_code is not null then
    update public.communication_envois set statut = 'echec', code_erreur = 'HTTP_' || p_code,
           verrouille_le = null, maj_le = now() where id = p_envoi.id and statut = 'traitement';
  else
    -- Délai dépassé, réseau, pas de réponse : le message est PEUT-ÊTRE parti. Jamais renvoyé seul.
    update public.communication_envois set statut = 'incertain', code_erreur = left(coalesce(p_erreur, 'SANS_REPONSE'), 60),
           verrouille_le = null, maj_le = now() where id = p_envoi.id and statut = 'traitement';
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


-- 8. Le travailleur ---------------------------------------------------------------------------------------
create or replace function public.traiter_communications()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.communication_reglages;
  c public.communication_campagnes;
  e public.communication_envois;
  d public.communication_destinataires;
  m public.communication_modeles;
  f public.communication_confirmations;
  x record;
  v_raison text;
  v_rendu jsonb;
  v_sujet jsonb;
  v_requete bigint;
  v_cout numeric;
  v_brevo integer;
  v_volume jsonb;
  v_lien text;
  v_html text;
  v_jeton text;
  v_params text[];
  v_site text := regexp_replace(coalesce(public.lire_reglage('site_url'), ''), '/?$', '/');
  v_lus integer := 0;
  v_partis integer := 0;
  v_ecartes integer := 0;
begin
  select * into r from public.communication_reglages;

  -- 1. Les réponses arrivées, toujours (même interrupteur coupé : rien ne reste « en cours »)
  for e in select * from public.communication_envois where statut = 'traitement'
            order by verrouille_le limit 200 for update skip locked loop
    select status_code, content, error_msg into x from net._http_response where id = e.requete;
    if found then
      perform public.communication_lire_reponse(e, x.status_code, x.content, x.error_msg);
      v_lus := v_lus + 1;
    elsif e.verrouille_le < now() - interval '10 minutes' then
      perform public.communication_lire_reponse(e, null, null, 'SANS_REPONSE');
      v_lus := v_lus + 1;
    end if;
  end loop;
  perform public.communication_lire_modeles_meta();
  -- Incertains de plus de 72 h sans preuve : restent incertains, marqués clos (H8)
  update public.communication_envois set incertain_clos_le = now()
   where statut = 'incertain' and incertain_clos_le is null and maj_le < now() - interval '72 hours';

  if not r.campagnes_actives then
    return jsonb_build_object('reponses_lues', v_lus, 'arret', 'CAMPAGNES_COUPEES');
  end if;
  if (select count(*) from public.notification_envois
       where statut = 'attente' and prochain_essai_le <= now()) > r.attente_transactionnel_max then
    return jsonb_build_object('reponses_lues', v_lus, 'arret', 'TRANSACTIONNEL_PRIORITAIRE');
  end if;

  -- 2. Images Meta à rafraîchir : modèles des campagnes programmées dans l'heure ou en cours
  perform public.communication_demander_modele_meta(mm.id)
     from public.communication_modeles mm
    where mm.canal = 'whatsapp' and mm.statut = 'approuve'
      and mm.id::text in (select jsonb_path_query(cc.modeles, '$.whatsapp.*') #>> '{}'
                            from public.communication_campagnes cc
                           where cc.statut = 'en_cours' or (cc.statut = 'programmee' and cc.planifiee_le <= now() + interval '1 hour'))
      and not exists (select 1 from public.communication_modeles_meta s
                       where s.modele_id = mm.id and s.demande_le > now() - make_interval(mins => greatest(r.modele_meta_fraicheur_min / 2, 5)));

  -- 3. Le lancement d'une campagne due (une par passage)
  for c in select * from public.communication_campagnes
            where statut = 'programmee' and planifiee_le <= now()
            order by planifiee_le limit 1 for update skip locked loop
    if c.empreinte_approuvee is null or c.empreinte_approuvee is distinct from public.communication_empreinte_campagne(c) then
      update public.communication_campagnes set statut = 'en_pause', arret_motif = 'EMPREINTE_CHANGEE', maj_le = now() where id = c.id;
      perform public.auditer('communication.campagne_bloquee', 'communication_campagne', c.id::text, null, jsonb_build_object('motif', 'EMPREINTE_CHANGEE'));
      continue;
    end if;
    -- Modèles WhatsApp : image Meta fraîche ET identique à celle approuvée ; sinon on attend ou on bloque
    v_raison := (select string_agg(m2.id || ':' || public.communication_modele_meta_bloque(m2.id, m2.empreinte_meta_approuvee), ',')
                   from public.communication_modeles m2
                  where m2.id::text in (select jsonb_path_query(c.modeles, '$.whatsapp.*') #>> '{}')
                    and public.communication_modele_meta_bloque(m2.id, m2.empreinte_meta_approuvee) is not null);
    if v_raison is not null then
      if v_raison like '%MODELE_META_NON_VERIFIE%' and c.planifiee_le > now() - interval '1 hour' then
        continue;                                            -- image en cours de lecture : on réessaie au passage suivant
      end if;
      update public.communication_campagnes set statut = 'en_pause', arret_motif = left('MODELE_META:' || v_raison, 300), maj_le = now()
       where id = c.id;
      perform public.auditer('communication.campagne_bloquee', 'communication_campagne', c.id::text, null, jsonb_build_object('motif', v_raison));
      continue;
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
      continue;
    end if;
    insert into public.communication_destinataires (campagne_id, client_id, canal, langue, modele_id, cible_empreinte,
                                                    territoire, retenu, raison)
    select c.id, k.id, ca.canal, lg.langue, ((c.modeles -> ca.canal) ->> lg.langue)::uuid,
           public.communication_empreinte(ca.canal, public.communication_cible(k.id, ca.canal)),
           case when ca.canal = 'whatsapp' then public.communication_territoire(public.communication_cible(k.id, 'whatsapp')) end,
           ex.raison is null, ex.raison
      from public.communication_segment_clients(c.criteres) k
      cross join unnest(c.canaux) as ca(canal)
      cross join lateral (select case when (c.modeles -> ca.canal) ? cl.langue then cl.langue else c.langue_repli end langue
                            from public.clients cl where cl.id = k.id) lg
      cross join lateral (select public.communication_raison_exclusion(k.id, ca.canal, c.essai) raison) ex
    on conflict (campagne_id, client_id, canal) do nothing;
    insert into public.communication_envois (nature, campagne_id, destinataire_id, client_id, canal, cle, cible_empreinte,
                                             territoire, fournisseur)
    select 'campagne', d2.campagne_id, d2.id, d2.client_id, d2.canal,
           'campagne:' || d2.campagne_id || ':' || d2.client_id || ':' || d2.canal, d2.cible_empreinte, d2.territoire,
           case d2.canal when 'whatsapp' then 'meta'
                         else coalesce(nullif(public.lire_reglage('communication_email_fournisseur'), ''), 'brevo') end
      from public.communication_destinataires d2 where d2.campagne_id = c.id and d2.retenu
    on conflict (cle) do nothing;
    update public.communication_campagnes set statut = 'en_cours', lancee_le = now(), maj_le = now() where id = c.id;
  end loop;

  -- 4. Les envois dus, par petits lots. Quota Brevo calculé UNE fois par passage (revue 1.1, M12).
  v_brevo := (public.communication_brevo_disponible() ->> 'disponible')::integer;
  for e in select ev.* from public.communication_envois ev
             left join public.communication_campagnes ca on ca.id = ev.campagne_id
            where ev.statut in ('attente', 'nouvel_essai') and ev.prochain_essai_le <= now()
              and (ev.nature = 'confirmation' or ca.statut = 'en_cours')
            order by ev.prochain_essai_le limit r.lot_par_minute
            for update of ev skip locked loop
    begin
      perform public.communication_verrou('client:' || e.client_id);   -- fréquence sérialisée par client (H4)

      -- Canal coupé entre-temps : on attend, sans rien perdre
      if (e.canal = 'email' and not r.email_actif) or (e.canal = 'whatsapp' and not r.whatsapp_actif)
         or (e.nature = 'confirmation' and not r.confirmations_actives) then
        update public.communication_envois set prochain_essai_le = now() + interval '15 minutes', maj_le = now() where id = e.id;
        continue;
      end if;
      -- Le contact a changé depuis le gel (ou la demande) : jamais envoyé à la nouvelle adresse (H5)
      if public.communication_empreinte(e.canal, public.communication_cible(e.client_id, e.canal)) is distinct from e.cible_empreinte then
        update public.communication_envois set statut = 'supprime', code_erreur = 'CONTACT_CHANGE', maj_le = now() where id = e.id;
        v_ecartes := v_ecartes + 1;
        continue;
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
          continue;
        end if;
        if v_brevo < 1 then
          update public.communication_envois set prochain_essai_le = now() + interval '1 hour', maj_le = now() where id = e.id;
          continue;
        end if;
        v_raison := public.communication_reserver(e, 0);
        if v_raison is not null then
          update public.communication_envois set prochain_essai_le = now() + interval '1 hour', code_erreur = v_raison, maj_le = now() where id = e.id;
          continue;
        end if;
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
        update public.communication_envois
           set statut = 'traitement', requete = v_requete, tentative = tentative + 1, verrouille_le = now(),
               empreinte_contenu = encode(extensions.digest(v_sujet::text, 'sha256'), 'hex'), maj_le = now()
         where id = e.id;
        v_brevo := v_brevo - 1;
        v_partis := v_partis + 1;
        continue;
      end if;

      -- Campagne
      select * into c from public.communication_campagnes where id = e.campagne_id;
      select * into d from public.communication_destinataires where id = e.destinataire_id;
      select * into m from public.communication_modeles where id = d.modele_id;
      v_raison := public.communication_raison_exclusion(e.client_id, e.canal, c.essai);   -- retrait, STOP, liste d'essai…
      if v_raison is not null then
        update public.communication_envois set statut = 'supprime', code_erreur = v_raison, maj_le = now() where id = e.id;
        v_ecartes := v_ecartes + 1;
        continue;
      end if;
      if public.communication_prochaine_fenetre(e.client_id) > now() then
        update public.communication_envois set prochain_essai_le = public.communication_prochaine_fenetre(e.client_id), maj_le = now() where id = e.id;
        continue;
      end if;
      if public.communication_frequence_atteinte(e.client_id) then
        update public.communication_envois set prochain_essai_le = now() + interval '6 hours', maj_le = now() where id = e.id;
        continue;
      end if;
      if m.statut <> 'approuve' then
        update public.communication_campagnes set statut = 'en_pause', arret_motif = 'MODELE_INDISPONIBLE', maj_le = now() where id = c.id;
        continue;
      end if;
      if e.canal = 'whatsapp' then
        v_raison := public.communication_modele_meta_bloque(m.id, m.empreinte_meta_approuvee);
        if v_raison is not null then                          -- image Meta trop vieille ou différente : pause
          update public.communication_campagnes set statut = 'en_pause', arret_motif = v_raison, maj_le = now() where id = c.id;
          perform public.auditer('communication.campagne_bloquee', 'communication_campagne', c.id::text, null, jsonb_build_object('motif', v_raison));
          continue;
        end if;
      end if;
      -- L'environnement d'envoi n'a pas changé depuis l'approbation (pied, adresse, expéditeur…)
      if c.empreinte_approuvee is distinct from public.communication_empreinte_campagne(c) then
        update public.communication_campagnes set statut = 'en_pause', arret_motif = 'EMPREINTE_CHANGEE', maj_le = now() where id = c.id;
        continue;
      end if;
      -- Texte : jamais de variable non résolue ; paramètres WhatsApp valides
      if e.canal = 'email' then
        v_rendu := public.communication_rendre(m.corps, e.client_id, 'email');
        v_sujet := public.communication_rendre(m.sujet, e.client_id, 'email');
        if not (v_rendu ->> 'ok')::boolean or not (v_sujet ->> 'ok')::boolean then
          update public.communication_envois set statut = 'supprime',
                 code_erreur = left(coalesce(v_rendu ->> 'raison', v_sujet ->> 'raison'), 60), maj_le = now() where id = e.id;
          v_ecartes := v_ecartes + 1;
          continue;
        end if;
        v_lien := case when public.communication_jeton_desinscription(e.id) is null then null
                       else v_site || 'desinscription.html?t=' || public.communication_jeton_desinscription(e.id) end;
        v_html := public.communication_courriel_commercial(m.langue, v_sujet ->> 'texte', v_rendu ->> 'texte', v_lien,
                                                           r.identite_legale, r.adresse_postale);
        if v_html is null then                                 -- clé, identité ou adresse absentes : REFUS (C1, M8)
          update public.communication_campagnes set statut = 'en_pause', arret_motif = 'PIED_COMMERCIAL_INCOMPLET', maj_le = now() where id = c.id;
          continue;
        end if;
        if v_brevo < 1 then
          update public.communication_envois set prochain_essai_le = now() + interval '1 hour', code_erreur = 'QUOTA_BREVO_RESERVE', maj_le = now() where id = e.id;
          continue;
        end if;
        v_cout := 0;
      else
        select array_agg(public.communication_rendre('{{' || v || '}}', e.client_id, 'whatsapp') ->> 'texte' order by i) into v_params
          from unnest(m.variables) with ordinality as t(v, i);
        if exists (select 1 from unnest(coalesce(v_params, '{}')) p where public.communication_parametre_whatsapp_invalide(p)) then
          update public.communication_envois set statut = 'supprime', code_erreur = 'PARAMETRE_WHATSAPP_INVALIDE', maj_le = now() where id = e.id;
          v_ecartes := v_ecartes + 1;
          continue;
        end if;
        select t.prix_usd into v_cout from public.communication_tarifs t
         where t.fournisseur = 'meta' and t.canal = 'whatsapp' and t.categorie = 'marketing' and t.territoire = e.territoire;
        if v_cout is null then
          update public.communication_envois set statut = 'supprime', code_erreur = 'TARIF_NON_VERIFIE', maj_le = now() where id = e.id;
          continue;
        end if;
      end if;
      -- Réservation sous verrous : plafond de campagne → pause ; plafond du jour → demain 9 h
      v_raison := public.communication_reserver(e, v_cout);
      if v_raison is not null then
        if v_raison like 'PLAFOND_CAMPAGNE%' then
          update public.communication_campagnes set statut = 'en_pause', arret_motif = v_raison, maj_le = now() where id = c.id;
        elsif v_raison <> 'CAMPAGNE_PAS_EN_COURS' then
          update public.communication_envois
             set prochain_essai_le = ((public.communication_jour() + 1)::timestamp + interval '9 hours') at time zone 'America/Santo_Domingo',
                 code_erreur = v_raison, maj_le = now()
           where id = e.id;
        end if;
        continue;
      end if;
      if e.canal = 'email' then
        v_requete := public.communication_appel_email(e, v_sujet ->> 'texte', v_html,
                       (v_rendu ->> 'texte') || E'\n\n' || r.identite_legale || ' — ' || r.adresse_postale || E'\n' ||
                       (public.communication_textes_pied(m.langue) ->> 'desinscrire') || ' : ' || v_lien, v_lien);
        v_brevo := v_brevo - 1;
      else
        v_requete := public.communication_appel_whatsapp(e, m, v_params);
      end if;
      update public.communication_envois
         set statut = 'traitement', requete = v_requete, tentative = tentative + 1, verrouille_le = now(),
             cout_estime_usd = v_cout, maj_le = now(),
             empreinte_contenu = encode(extensions.digest(coalesce(v_html, array_to_string(v_params, '|'), ''), 'sha256'), 'hex')
       where id = e.id;
      v_partis := v_partis + 1;
    exception when others then
      -- Rien n'est parti (la sous-transaction, réservation comprise, est annulée) : un code, jamais le texte
      update public.communication_envois
         set statut = 'echec', code_erreur = case when sqlerrm = 'NON_CONFIGURE' then 'NON_CONFIGURE' else 'ERREUR_INTERNE' end,
             maj_le = now()
       where id = e.id;
      insert into public.communication_erreurs (source, code, detail) values ('traiter_communications', sqlstate, left(sqlerrm, 300));
    end;
  end loop;

  -- 5. Les campagnes finies : plus rien à envoyer ni en cours (les incertains n'empêchent pas la fin)
  update public.communication_campagnes ca set statut = 'terminee', terminee_le = now(), maj_le = now()
   where ca.statut = 'en_cours'
     and not exists (select 1 from public.communication_envois ev
                      where ev.campagne_id = ca.id and ev.statut in ('attente', 'traitement', 'nouvel_essai'));

  return jsonb_build_object('reponses_lues', v_lus, 'envoyes', v_partis, 'ecartes', v_ecartes);
end;
$$;


-- 9. Les retours des fournisseurs (revue 1.1, C6, H8, H11) ------------------------------------------------
-- Parcours complet (détail : COMMUNICATION_CENTER_SECURITY.md §6) :
--   Meta → fonction Edge : signature X-Hub-Signature-256 vérifiée sur le CORPS BRUT ;
--   Brevo → fonction Edge : Brevo ne signe pas ses envois (rapporté) ; protections PRÉVUES :
--     jeton secret dans l'adresse ou authentification simple, et plages d'adresses IP publiées
--     par Brevo — plus faibles, à confirmer et documentées comme telles ;
--   fonction Edge → base : chaque événement normalisé en texte, signé par HMAC avec la clé
--     partagée « communication_cle_webhook » (coffre + secrets de la fonction Edge), appel avec
--     la clé PUBLIQUE de Supabase. La clé publique N'AUTORISE RIEN : elle désigne le projet. La
--     seule porte est la signature ; clé absente du coffre : tout est refusé.
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
revoke all on public.communication_evenements_fournisseur from anon, authenticated;
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
revoke all on public.communication_fenetres_whatsapp from anon, authenticated;

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

create or replace function public.communication_recevoir_evenement(p_fournisseur text, p_charge text, p_signature text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cle text;
  p jsonb;
  v_type text;
  e public.communication_envois;
  v_ref bigint;
  v_id bigint;
  v_empreinte text;
  v_mot text;
  v_code text;
  f public.communication_confirmations;
  k public.communication_consentements;
  a public.communication_codes_fournisseur;
  cl record;
  v_rang_actuel integer;
  v_rang_nouveau integer;
begin
  -- Contrôles bon marché AVANT toute lecture du coffre (revue 1.1, M6)
  if p_fournisseur not in ('meta', 'brevo', 'resend') or p_charge is null or length(p_charge) > 20000
     or coalesce(p_signature, '') !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('ok', false);
  end if;
  v_cle := public.lire_reglage('communication_cle_webhook');
  if coalesce(v_cle, '') = ''
     or p_signature <> encode(extensions.hmac(p_fournisseur || ':' || p_charge, v_cle, 'sha256'), 'hex') then
    raise log 'goship communication webhook signature refusee fournisseur=%', p_fournisseur;   -- détection d'abus (journaux)
    return jsonb_build_object('ok', false);
  end if;
  begin
    p := p_charge::jsonb;
  exception when others then
    return jsonb_build_object('ok', false);
  end;
  v_type := p ->> 'type';
  if (p ->> 'survenu_le')::timestamptz > now() + interval '5 minutes' then
    return jsonb_build_object('ok', false, 'futur', true);
  end if;

  -- L'envoi concerné : par l'identifiant du fournisseur, sinon par la référence (rapprochement d'un incertain)
  if v_type <> 'inbound' then
    select * into e from public.communication_envois
     where fournisseur = p_fournisseur and message_id = p ->> 'message_id' for update;
    if not found and (p ->> 'reference') ~ '^communication:[0-9]{1,18}$' then
      v_ref := split_part(p ->> 'reference', ':', 2)::bigint;
      select * into e from public.communication_envois where id = v_ref and fournisseur = p_fournisseur for update;
    end if;
  end if;
  insert into public.communication_evenements_fournisseur (fournisseur, evenement_id, type, message_id, reference, envoi_id, code, survenu_le)
  values (p_fournisseur, left(p ->> 'id', 200), left(v_type, 40), left(p ->> 'message_id', 200), left(p ->> 'reference', 60),
          e.id, left(p ->> 'code', 60), (p ->> 'survenu_le')::timestamptz)
  on conflict (fournisseur, evenement_id) do nothing
  returning id into v_id;
  if v_id is null then
    return jsonb_build_object('ok', true, 'rejeu', true);      -- déjà traité : rien de plus, rien de moins
  end if;

  -- Message entrant (WhatsApp) : fenêtre de 24 h, STOP, confirmation. Le contenu n'est jamais gardé.
  if v_type = 'inbound' then
    v_empreinte := public.communication_empreinte('whatsapp', p ->> 'telephone');
    if v_empreinte is null then
      return jsonb_build_object('ok', false);
    end if;
    insert into public.communication_fenetres_whatsapp (cible_empreinte, dernier_entrant) values (v_empreinte, now())
    on conflict (cible_empreinte) do update set dernier_entrant = now();
    if public.communication_est_stop(p ->> 'texte') then
      insert into public.communication_suppressions (canal, cible_empreinte, raison, source)
      values ('whatsapp', v_empreinte, 'stop', 'whatsapp_entrant') on conflict do nothing;
      for cl in select c.id from public.clients c
                 where public.communication_empreinte('whatsapp', public.telephone_international(c.telephone, c.pays)) = v_empreinte loop
        perform public.communication_verrou('consentement:' || cl.id || ':whatsapp');
        insert into public.communication_consentements (client_id, canal, action, source, cible_empreinte)
        values (cl.id, 'whatsapp', 'retire', 'whatsapp_stop', v_empreinte);
        update public.communication_confirmations set annule_le = clock_timestamp()
         where client_id = cl.id and canal = 'whatsapp' and utilise_le is null and annule_le is null;
      end loop;
      return jsonb_build_object('ok', true, 'stop', true);
    end if;
    -- Confirmation : « <mot> <code> » depuis le numéro dont l'empreinte est celle de la demande
    v_mot := split_part(public.communication_mot_simple(p ->> 'texte'), ' ', 1);
    v_code := split_part(public.communication_mot_simple(p ->> 'texte'), ' ', 2);
    if v_mot in ('OUI', 'YES', 'SI', 'WI') and v_code ~ '^[0-9]{4}$' then
      select * into f from public.communication_confirmations
       where canal = 'whatsapp' and cible_empreinte = v_empreinte and code = v_code
         and utilise_le is null and annule_le is null and expire_le > now()
       order by id desc limit 1 for update;
      if found then
        perform public.communication_verrou('consentement:' || f.client_id || ':whatsapp');
        if (public.communication_etat_consentement(f.client_id, 'whatsapp') ->> 'etat') = 'en_attente'
           and public.communication_empreinte('whatsapp', public.communication_cible(f.client_id, 'whatsapp')) = f.cible_empreinte then
          select * into k from public.communication_consentements where id = f.consentement_id;
          update public.communication_confirmations set utilise_le = clock_timestamp() where id = f.id;
          insert into public.communication_consentements (client_id, canal, action, source, texte_version, texte_empreinte,
                                                          langue, cible_empreinte)
          values (f.client_id, 'whatsapp', 'confirme', 'whatsapp_confirmation', k.texte_version, k.texte_empreinte, k.langue, v_empreinte);
          update public.communication_suppressions
             set leve_le = clock_timestamp(), motif_levee = 'Nouvelle inscription confirmée par le contact'
           where canal = 'whatsapp' and cible_empreinte = v_empreinte and leve_le is null and raison in ('desinscription', 'stop');
          return jsonb_build_object('ok', true, 'confirme', true);
        end if;
      end if;
    end if;
    return jsonb_build_object('ok', true);
  end if;

  if e.id is null then
    return jsonb_build_object('ok', true, 'inconnu', true);
  end if;

  -- Statut d'un message : jamais en arrière ; un incertain retrouvé est rapproché (H8)
  v_rang_actuel := case e.statut when 'livre' then 2 when 'lu' then 3 when 'envoye' then 1 else 0 end;
  v_rang_nouveau := case v_type when 'sent' then 1 when 'delivered' then 2 when 'read' then 3 else 0 end;
  if v_rang_nouveau > 0 and v_rang_nouveau > v_rang_actuel and e.statut in ('traitement', 'envoye', 'livre', 'incertain') then
    update public.communication_envois
       set statut = case v_rang_nouveau when 1 then 'envoye' when 2 then 'livre' else 'lu' end,
           message_id = coalesce(message_id, left(p ->> 'message_id', 200)),
           envoye_le = coalesce(envoye_le, (p ->> 'survenu_le')::timestamptz, now()),
           livre_le = case when v_rang_nouveau >= 2 then coalesce(livre_le, (p ->> 'survenu_le')::timestamptz, now()) else livre_le end,
           lu_le = case when v_rang_nouveau = 3 then coalesce(lu_le, (p ->> 'survenu_le')::timestamptz, now()) else lu_le end,
           incertain_clos_le = null, maj_le = now()
     where id = e.id;
  elsif v_type in ('failed', 'hard_bounce', 'blocked') and e.statut in ('traitement', 'envoye', 'incertain') then
    update public.communication_envois set statut = 'echec', code_erreur = left(coalesce(p ->> 'code', upper(v_type)), 60),
           incertain_clos_le = null, maj_le = now() where id = e.id;
  end if;

  -- Ce que dit un code d'erreur (table des codes, H11)
  if p ->> 'code' is not null then
    select * into a from public.communication_codes_fournisseur where fournisseur = p_fournisseur and code = p ->> 'code';
    if found then
      if a.action = 'suppression_contact' then
        insert into public.communication_suppressions (canal, cible_empreinte, client_id, raison, source)
        values (e.canal, e.cible_empreinte, e.client_id, 'opposition_meta', p_fournisseur) on conflict do nothing;
        perform public.communication_verrou('consentement:' || e.client_id || ':' || e.canal);
        insert into public.communication_consentements (client_id, canal, action, source, cible_empreinte)
        values (e.client_id, e.canal, 'retire', 'opposition_meta', e.cible_empreinte);
      elsif a.action = 'pause_canal' then
        update public.communication_reglages set whatsapp_actif = false, maj_le = now() where e.canal = 'whatsapp';
        insert into public.communication_erreurs (source, code, detail) values ('fournisseur', 'PAUSE_CANAL', p_fournisseur || ':' || (p ->> 'code'));
      elsif a.action = 'pause_campagne' and e.campagne_id is not null then
        update public.communication_campagnes set statut = 'en_pause', arret_motif = 'CODE_' || (p ->> 'code'), maj_le = now()
         where id = e.campagne_id and statut = 'en_cours';
      elsif a.action = 'reporter_destinataire' and e.relance_de is null and e.campagne_id is not null then
        insert into public.communication_envois (nature, campagne_id, destinataire_id, client_id, canal, cle, cible_empreinte,
                                                 territoire, fournisseur, prochain_essai_le, relance_de)
        values ('campagne', e.campagne_id, e.destinataire_id, e.client_id, e.canal, e.cle || ':report', e.cible_empreinte,
                e.territoire, e.fournisseur, now() + make_interval(hours => coalesce(a.delai_heures, 24)), e.id)
        on conflict (cle) do nothing;                             -- une seule fois
      end if;
    end if;
  end if;

  -- Rebond définitif, plainte, désinscription chez le fournisseur : suppression du contact EXACT
  -- visé par l'envoi ; retrait seulement pour une plainte ou une désinscription (pas un rebond)
  if v_type in ('hard_bounce', 'complaint', 'unsubscribe') then
    insert into public.communication_suppressions (canal, cible_empreinte, client_id, raison, source)
    values (e.canal, e.cible_empreinte, e.client_id,
            case v_type when 'complaint' then 'plainte' when 'unsubscribe' then 'desinscription' else 'rebond_definitif' end,
            p_fournisseur)
    on conflict do nothing;
    if v_type in ('complaint', 'unsubscribe') then
      perform public.communication_verrou('consentement:' || e.client_id || ':' || e.canal);
      insert into public.communication_consentements (client_id, canal, action, source, cible_empreinte)
      values (e.client_id, e.canal, 'retire', case v_type when 'complaint' then 'plainte' else 'lien_desinscription' end,
              e.cible_empreinte);
    end if;
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
  if not found or e.cible_empreinte is null then
    return jsonb_build_object('ok', false);
  end if;
  insert into public.communication_suppressions (canal, cible_empreinte, client_id, raison, source)
  values (e.canal, e.cible_empreinte, e.client_id, 'desinscription', 'lien')
  on conflict do nothing;
  perform public.communication_verrou('consentement:' || e.client_id || ':' || e.canal);
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


-- 12. Purge des autres catégories (revue 1.1, C5) — appelée par executer_purge_communication (40) ----------
-- Même règle : seulement dans une purge approuvée (goship.purge_demande posé par la fonction
-- de 40), chaque opération comptée au journal des purges, jamais les données elles-mêmes.
create or replace function public.communication_purger_autres(p_demande bigint, p_categorie text, p_avant timestamptz)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  if p_categorie = 'envois' then
    update public.communication_envois set client_id = null, message_id = null, requete = null
     where cree_le < p_avant and client_id is not null;
  elsif p_categorie = 'destinataires' then
    delete from public.communication_destinataires dd where dd.cree_le < p_avant
       and not exists (select 1 from public.communication_envois ee where ee.destinataire_id = dd.id);
  elsif p_categorie = 'campagnes' then
    update public.communication_campagnes set description = '' where terminee_le < p_avant;
  elsif p_categorie = 'evenements_fournisseur' then
    delete from public.communication_evenements_fournisseur where recu_le < p_avant;
  elsif p_categorie = 'fenetres_whatsapp' then
    delete from public.communication_fenetres_whatsapp where dernier_entrant < p_avant;
  elsif p_categorie = 'suppressions' then
    update public.communication_suppressions set client_id = null, motif = null where cree_le < p_avant and client_id is not null;
  elsif p_categorie = 'erreurs' then
    delete from public.communication_erreurs where cree_le < p_avant;
  else
    perform public.erreur_metier('INVALID_CATEGORY', 'Catégorie inconnue.');
  end if;
  get diagnostics v_n = row_count;
  insert into public.communication_journal_purges (demande_id, table_nom, operation, lignes, avant, execute_par)
  values (p_demande, 'communication_' || p_categorie,
          case when p_categorie in ('destinataires', 'evenements_fournisseur', 'fenetres_whatsapp', 'erreurs') then 'effacer'
               else 'anonymiser' end, v_n, p_avant, auth.uid());
end;
$$;

-- Effacement demandé par une personne : la suite de 40 (envois, audiences, suppressions gardées
-- mais déliées du compte : l'empreinte reste pour ne plus lui écrire).
create or replace function public.communication_purger_personne_suite(p_demande bigint, p_client uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  update public.communication_envois set client_id = null, message_id = null where client_id = p_client;
  get diagnostics v_n = row_count;
  insert into public.communication_journal_purges (demande_id, table_nom, operation, lignes, execute_par)
  values (p_demande, 'communication_envois', 'anonymiser', v_n, auth.uid());
  update public.communication_destinataires set client_id = null where client_id = p_client;
  get diagnostics v_n = row_count;
  insert into public.communication_journal_purges (demande_id, table_nom, operation, lignes, execute_par)
  values (p_demande, 'communication_destinataires', 'anonymiser', v_n, auth.uid());
  update public.communication_suppressions set client_id = null, motif = null where client_id = p_client;
  get diagnostics v_n = row_count;
  insert into public.communication_journal_purges (demande_id, table_nom, operation, lignes, execute_par)
  values (p_demande, 'communication_suppressions', 'anonymiser', v_n, auth.uid());
  delete from public.communication_destinataires_essai where client_id = p_client;
end;
$$;


-- 13. Santé et planificateur -------------------------------------------------------------------------------
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

-- Le travailleur : chaque minute (pg_cron accepte aussi des intervalles en secondes ; la minute
-- suffit et reste alignée sur le transactionnel). C'est lui qui cède la place
-- (attente_transactionnel_max), pas l'horaire. Créé INACTIF : seul l'administrateur l'allume, sur
-- décision écrite du CEO, en plus de l'interrupteur campagnes_actives qui reste éteint.
do $cron$
declare
  v_job bigint;
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 'goship-communications') then
      v_job := cron.schedule('goship-communications', '* * * * *', 'select public.traiter_communications()');
      perform cron.alter_job(v_job, active := false);
    end if;
  end if;
end
$cron$;


-- 14. Droits ------------------------------------------------------------------------------------------------
do $droits$
declare
  f text;
begin
  -- Ouvertes à personne (appelées par d'autres fonctions, le travailleur ou un déclencheur)
  foreach f in array array[
    'public.communication_fuseau(uuid)', 'public.communication_prochaine_fenetre(uuid)',
    'public.communication_frequence_atteinte(uuid)',
    'public.communication_reserver(public.communication_envois, numeric)',
    'public.communication_jeton_desinscription(bigint)', 'public.communication_textes_pied(text)',
    'public.communication_textes_confirmation(text)', 'public.communication_textes_pied_tous()',
    'public.communication_courriel_commercial(text, text, text, text, text, text)',
    'public.communication_appel_email(public.communication_envois, text, text, text, text)',
    'public.communication_appel_whatsapp(public.communication_envois, public.communication_modeles, text[])',
    'public.communication_lire_reponse(public.communication_envois, integer, text, text)',
    'public.communication_demander_envoi_confirmation(bigint)',
    'public.traiter_communications()', 'public.communication_mot_simple(text)', 'public.communication_est_stop(text)',
    'public.communication_purger_autres(bigint, text, timestamptz)',
    'public.communication_purger_personne_suite(bigint, uuid)'] loop
    execute 'revoke execute on function ' || f || ' from public, anon, authenticated';
  end loop;
  foreach f in array array['public.relancer_envoi_communication(bigint, text, boolean)', 'public.sante_communications()'] loop
    execute 'revoke execute on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end
$droits$;

-- Les SEULES portes ouvertes sans compte, chacune protégée par sa propre signature (à ajouter
-- à la liste blanche de controle-securite.sql, section 6, avec confirmer_consentement_communication) :
revoke execute on function public.communication_recevoir_evenement(text, text, text) from public, authenticated;
grant execute on function public.communication_recevoir_evenement(text, text, text) to anon;
revoke execute on function public.desinscrire_communication(text) from public;
grant execute on function public.desinscrire_communication(text) to anon, authenticated;
