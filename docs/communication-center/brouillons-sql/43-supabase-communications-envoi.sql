-- =============================================================================
-- BROUILLON — PHASE 1 DU CENTRE DE COMMUNICATION — NE PAS EXÉCUTER
-- (voir l'en-tête de 40-supabase-communications-fondation.sql)
-- =============================================================================
do $brouillon$
begin
  raise exception 'BROUILLON NON APPROUVÉ (Phase 1 du Centre de communication) : ne pas exécuter.';
end;
$brouillon$;

-- =============================================================================
-- Goship Express — Centre de communication : la file commerciale, son travailleur, les
-- fournisseurs, les retours des fournisseurs, STOP et désinscription (brouillon du 18/11/2026).
-- À la suite de 42-…-campagnes.
--
-- Deux files, deux travailleurs, deux priorités :
--   · transactionnel (EXISTANT, inchangé) : notification_envois, traiter_notifications(),
--     tâche goship-notifications, lot 50/min ;
--   · commercial (CE FICHIER) : communication_envois, traiter_communications(), tâche
--     goship-communications, lot 20/min par défaut, qui CÈDE la place quand le
--     transactionnel a du retard (attente_transactionnel_max).
-- Les deux appellent les fournisseurs par pg_net. Les appels commerciaux sont écrits ici, à
-- part : expedier_envoi (transactionnel) n'est PAS modifié (exigence 7 du CEO). Une
-- convergence éventuelle des deux appels est une décision de plus tard, éprouvée à part.
--
-- Garanties :
--   · une clé unique par campagne, client et canal : jamais deux messages ;
--   · for update skip locked : deux passages ne prennent jamais la même ligne ;
--   · dépense RÉSERVÉE sous verrou AVANT l'appel (plafonds du jour et de la campagne,
--     quota Brevo) ;
--   · consentement, suppression, liste d'essai, heures et fréquence revérifiés juste avant
--     l'envoi ;
--   · issue inconnue (pas de réponse) = jamais renvoyé : un doublon commercial est pire
--     qu'un message manqué (le transactionnel, lui, réessaie) ;
--   · 3 essais au plus, seulement sur erreur temporaire sûre (429, 5xx) ; au-delà : « abandon »
--     (la file des messages morts, visible et relançable par l'administrateur).
-- =============================================================================


-- 1. La file commerciale -------------------------------------------------------------------
-- Statuts (cycle du cahier des charges) :
--   attente       à envoyer à prochain_essai_le                        (Pending)
--   traitement    remis à pg_net, réponse pas encore lue               (Processing)
--   envoye        accepté par le fournisseur (≠ reçu)                  (Sent)
--   livre         remise confirmée par le fournisseur                  (Delivered)
--   lu            lecture confirmée (WhatsApp seulement)               (Read)
--   echec         refus définitif du fournisseur, ou issue inconnue    (Failed)
--   nouvel_essai  erreur temporaire, nouvel essai prévu                (Retrying)
--   supprime      écarté juste avant l'envoi (retrait, STOP, liste…)   (Suppressed)
--   annule        campagne annulée avant l'envoi
--   abandon       3 essais ratés : file des messages morts             (dead letter)
create table if not exists public.communication_envois (
  id                bigint generated always as identity primary key,
  campagne_id       uuid not null references public.communication_campagnes (id),
  destinataire_id   bigint not null references public.communication_destinataires (id),
  client_id         uuid not null,
  canal             text not null check (canal in ('email', 'whatsapp')),
  cle               text not null unique,                     -- campagne:<id>:<client>:<canal>
  statut            text not null default 'attente' check (statut in (
                      'attente', 'traitement', 'envoye', 'livre', 'lu', 'echec',
                      'nouvel_essai', 'supprime', 'annule', 'abandon')),
  fournisseur       text not null default '',
  tentative         integer not null default 0,
  prochain_essai_le timestamptz not null default now(),
  verrouille_le     timestamptz,
  requete           bigint,                                   -- n° pg_net
  message_id        text,                                     -- identifiant chez le fournisseur
  pays_tarif        text,
  cout_estime_usd   numeric(10, 5) not null default 0,
  code_erreur       text,                                     -- un code, jamais un texte du fournisseur
  cree_le           timestamptz not null default now(),
  envoye_le         timestamptz,
  livre_le          timestamptz,
  lu_le             timestamptz,
  maj_le            timestamptz not null default now()
);
create index if not exists communication_envois_dus_idx
  on public.communication_envois (prochain_essai_le) where statut in ('attente', 'nouvel_essai');
create index if not exists communication_envois_en_cours_idx
  on public.communication_envois (verrouille_le) where statut = 'traitement';
create index if not exists communication_envois_message_idx on public.communication_envois (fournisseur, message_id);
create index if not exists communication_envois_client_idx on public.communication_envois (client_id, envoye_le desc);
alter table public.communication_envois enable row level security;
revoke all on public.communication_envois from anon, authenticated;


-- 2. Heures et fréquence ------------------------------------------------------------------
-- L'heure locale du destinataire : Haïti, République dominicaine ; États-Unis : l'heure de
-- l'Est (Floride) faute d'État connu — prudence, la fenêtre 9 h-19 h tient dans tous les
-- fuseaux continentaux sauf aux extrêmes, à revoir avec le juriste (FTSA, TCPA).
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

-- Prochain instant permis pour ce client (maintenant s'il est dans la fenêtre).
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

-- Le client a-t-il déjà reçu assez de messages commerciaux (tous canaux) ?
create or replace function public.communication_frequence_atteinte(p_client uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select (select count(*) from public.communication_envois e
           where e.client_id = p_client and e.statut in ('traitement', 'envoye', 'livre', 'lu')
             and e.envoye_le > now() - interval '24 hours') >= r.frequence_max_jour
      or (select count(*) from public.communication_envois e
           where e.client_id = p_client and e.statut in ('traitement', 'envoye', 'livre', 'lu')
             and e.envoye_le > now() - interval '7 days') >= r.frequence_max_semaine
  from public.communication_reglages r
$$;


-- 3. La réservation de dépense, sous verrou, AVANT l'appel -----------------------------------
-- Renvoie null si l'envoi peut partir (la dépense est alors comptée), sinon le code de ce qui
-- bloque. Les compteurs ne sont jamais rendus après un échec : l'estimation reste au-dessus
-- de la réalité (Meta ne facture que les messages remis).
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
  v_total_messages integer;
  v_total_cout numeric;
begin
  select * into r from public.communication_reglages;
  select * into c from public.communication_campagnes where id = p_envoi.campagne_id for update;

  -- Plafonds de la campagne
  if c.messages_reserves + 1 > c.plafond_messages then
    return 'PLAFOND_CAMPAGNE_MESSAGES';
  end if;
  if c.cout_reserve_usd + p_cout > c.plafond_cout_usd and p_cout > 0 then
    return 'PLAFOND_CAMPAGNE_COUT';
  end if;

  -- Plafonds globaux du jour (toutes campagnes, tous canaux), sous verrou de la ligne du jour
  insert into public.communication_depenses_jour (jour, fournisseur, canal)
  values (v_jour, p_envoi.fournisseur, p_envoi.canal) on conflict do nothing;
  perform 1 from public.communication_depenses_jour
   where jour = v_jour for update;
  select coalesce(sum(messages), 0), coalesce(sum(cout_usd), 0) into v_total_messages, v_total_cout
    from public.communication_depenses_jour where jour = v_jour;
  if v_total_messages + 1 > r.plafond_jour_messages then
    return 'PLAFOND_JOUR_MESSAGES';
  end if;
  if v_total_cout + p_cout > r.plafond_jour_usd and p_cout > 0 then
    return 'PLAFOND_JOUR_COUT';
  end if;

  -- Quota Brevo : jamais la réserve de l'authentification et du transactionnel
  if p_envoi.canal = 'email' and p_envoi.fournisseur = 'brevo' and public.communication_brevo_disponible() < 1 then
    return 'QUOTA_BREVO_RESERVE';
  end if;

  update public.communication_depenses_jour
     set messages = messages + 1, cout_usd = cout_usd + p_cout
   where jour = v_jour and fournisseur = p_envoi.fournisseur and canal = p_envoi.canal;
  update public.communication_campagnes
     set messages_reserves = messages_reserves + 1, cout_reserve_usd = cout_reserve_usd + p_cout
   where id = c.id;
  return null;
end;
$$;


-- 4. Les appels aux fournisseurs (commercial seulement) -------------------------------------
-- 4.1 Le jeton de désinscription : identifiant de l'envoi + HMAC (clé du coffre
-- « communication_cle_desinscription », posée en Phase 2 par l'administrateur). Le lien ne
-- contient ni l'adresse, ni le code client.
create or replace function public.communication_jeton_desinscription(p_envoi bigint)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select p_envoi::text || '.' ||
         left(translate(encode(extensions.hmac(p_envoi::text, public.lire_reglage('communication_cle_desinscription'), 'sha256'),
                               'base64'), '+/=', '-_'), 32)
$$;

-- 4.2 E-mail commercial (Brevo, ou Resend si c'est le fournisseur réglé). Le corps est du
-- texte, échappé, mis en page par courriel_gabarit (inchangé) ; le pied commercial porte
-- l'adresse postale validée (D-G) et le lien de désinscription. En-têtes List-Unsubscribe
-- (lien et adresse) ; « One-Click » (RFC 8058) seulement quand la fonction Edge existe
-- (réglage communication_url_un_clic).
create or replace function public.communication_appel_email(p_envoi public.communication_envois, p_langue text,
                                                            p_sujet text, p_corps text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  cl public.clients;
  r public.communication_reglages;
  v_cle text := public.lire_reglage('email_cle_api');
  v_fournisseur text := coalesce(nullif(public.lire_reglage('email_fournisseur'), ''), 'brevo');
  v_expediteur text := coalesce(nullif(public.lire_reglage('communication_expediteur'), ''), public.lire_reglage('email_expediteur'));
  v_nom text := coalesce(nullif(public.lire_reglage('email_nom'), ''), 'Goship Express');
  v_site text := regexp_replace(coalesce(public.lire_reglage('site_url'), ''), '/?$', '/');
  v_lien text;
  v_un_clic text := public.lire_reglage('communication_url_un_clic');
  v_html text;
  v_texte text;
  v_entetes jsonb;
  v_requete bigint;
begin
  select * into cl from public.clients where id = p_envoi.client_id;
  select * into r from public.communication_reglages;
  if coalesce(v_cle, '') = '' or coalesce(v_expediteur, '') = '' or r.adresse_postale is null
     or v_site !~ '^https://[A-Za-z0-9.-]+/$' then
    raise exception 'NON_CONFIGURE';
  end if;
  v_lien := v_site || 'desinscription.html?t=' || public.communication_jeton_desinscription(p_envoi.id);
  v_html := public.courriel_gabarit(p_langue, p_sujet, '',
              '<p style="margin:0;font-size:16px;line-height:1.6">' ||
              replace(public.html_echappe(p_corps), E'\n', '<br>') || '</p>',
              '', '',
              -- Pied commercial : pourquoi ce message, comment ne plus le recevoir, où nous écrire
              public.html_echappe(public.communication_textes_pied(p_langue) ->> 'raison') ||
              ' <a href="' || public.html_echappe(v_lien) || '">' ||
              public.html_echappe(public.communication_textes_pied(p_langue) ->> 'desinscrire') || '</a><br>' ||
              public.html_echappe(r.adresse_postale));
  v_texte := p_corps || E'\n\n— Goship Express\n' || r.adresse_postale || E'\n' ||
             (public.communication_textes_pied(p_langue) ->> 'desinscrire') || ' : ' || v_lien;
  v_entetes := jsonb_build_object('List-Unsubscribe',
                 '<' || coalesce(nullif(v_un_clic, '') || '?t=' || public.communication_jeton_desinscription(p_envoi.id), v_lien) || '>');
  if coalesce(v_un_clic, '') <> '' then
    v_entetes := v_entetes || jsonb_build_object('List-Unsubscribe-Post', 'List-Unsubscribe=One-Click');
  end if;

  if v_fournisseur = 'resend' then
    select net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object('Authorization', 'Bearer ' || v_cle, 'Content-Type', 'application/json'),
      body := jsonb_build_object('from', v_nom || ' <' || v_expediteur || '>', 'to', jsonb_build_array(cl.email),
                                 'subject', p_sujet, 'html', v_html, 'text', v_texte, 'headers', v_entetes,
                                 'tags', jsonb_build_array(jsonb_build_object('name', 'flux', 'value', 'marketing')))
    ) into v_requete;
  else
    select net.http_post(
      url := 'https://api.brevo.com/v3/smtp/email',
      headers := jsonb_build_object('api-key', v_cle, 'Content-Type', 'application/json', 'Accept', 'application/json'),
      body := jsonb_build_object('sender', jsonb_build_object('name', v_nom, 'email', v_expediteur),
                                 'to', jsonb_build_array(jsonb_build_object('email', cl.email)),
                                 'subject', p_sujet, 'htmlContent', v_html, 'textContent', v_texte,
                                 'headers', v_entetes,
                                 'tags', jsonb_build_array('goship-marketing', 'campagne-' || p_envoi.campagne_id))
    ) into v_requete;
  end if;
  return v_requete;
end;
$$;

-- 4.3 WhatsApp commercial : un modèle approuvé par Meta, ses paramètres dans l'ordre.
create or replace function public.communication_appel_whatsapp(p_envoi public.communication_envois,
                                                               m public.communication_modeles, p_parametres text[])
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_jeton text := public.lire_reglage('whatsapp_jeton');
  v_numero_id text := coalesce(nullif(public.lire_reglage('communication_whatsapp_numero_id'), ''),
                               public.lire_reglage('whatsapp_numero_id'));
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
      'biz_opaque_callback_data', 'communication:' || p_envoi.id,
      'template', jsonb_build_object(
        'name', m.whatsapp_nom_meta,
        'language', jsonb_build_object('code', m.whatsapp_langue_meta),
        'components', case when cardinality(p_parametres) = 0 then '[]'::jsonb else jsonb_build_array(
          jsonb_build_object('type', 'body', 'parameters',
            (select jsonb_agg(jsonb_build_object('type', 'text', 'text', x) order by i)
               from unnest(p_parametres) with ordinality as t(x, i)))) end))
  ) into v_requete;
  return v_requete;
end;
$$;

-- Les phrases du pied commercial, quatre langues. TEXTES À FAIRE APPROUVER PAR LE JURISTE
-- avant toute activation (décision D-F).
create or replace function public.communication_textes_pied(p_langue text)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case p_langue
    when 'en' then jsonb_build_object('raison', 'You receive this offer because you agreed to receive news from Goship Express.',
                                      'desinscrire', 'Unsubscribe')
    when 'es' then jsonb_build_object('raison', 'Recibe esta oferta porque aceptó recibir novedades de Goship Express.',
                                      'desinscrire', 'Darse de baja')
    when 'ht' then jsonb_build_object('raison', 'Ou resevwa òf sa a paske ou te dakò resevwa nouvèl Goship Express.',
                                      'desinscrire', 'Dezabòne')
    else jsonb_build_object('raison', 'Vous recevez cette offre car vous avez accepté de recevoir les nouvelles de Goship Express.',
                            'desinscrire', 'Se désinscrire')
  end
$$;


-- 5. La réponse d'un appel -----------------------------------------------------------------
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
       set statut = 'envoye', message_id = left(v_id, 200), envoye_le = now(), code_erreur = null,
           verrouille_le = null, maj_le = now()
     where id = p_envoi.id;
  elsif p_erreur is null and (p_code = 429 or p_code >= 500) and p_envoi.tentative < 3 then
    -- Refus temporaire SÛR (le fournisseur n'a rien accepté) : nouvel essai 2 min, 10 min, 1 h
    update public.communication_envois
       set statut = 'nouvel_essai', code_erreur = 'HTTP_' || p_code, verrouille_le = null, maj_le = now(),
           prochain_essai_le = now() + case p_envoi.tentative when 1 then interval '2 minutes'
                                                               when 2 then interval '10 minutes' else interval '1 hour' end
     where id = p_envoi.id;
  elsif p_erreur is null and (p_code = 429 or p_code >= 500) then
    update public.communication_envois set statut = 'abandon', code_erreur = 'ABANDON_HTTP_' || p_code,
           verrouille_le = null, maj_le = now() where id = p_envoi.id;
  else
    -- Refus définitif, ou issue inconnue (réseau, pas de réponse) : jamais renvoyé tout seul
    update public.communication_envois
       set statut = 'echec', code_erreur = case when p_erreur is not null then 'ISSUE_INCONNUE' else 'HTTP_' || coalesce(p_code, 0) end,
           verrouille_le = null, maj_le = now()
     where id = p_envoi.id;
  end if;
end;
$$;


-- 6. Le travailleur ---------------------------------------------------------------------------
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
  x record;
  v_raison text;
  v_rendu jsonb;
  v_sujet jsonb;
  v_requete bigint;
  v_pays text;
  v_cout numeric;
  v_lus integer := 0;
  v_partis integer := 0;
  v_ecartes integer := 0;
begin
  select * into r from public.communication_reglages;

  -- 1. Les réponses arrivées (toujours, même interrupteur coupé : rien ne reste « en cours »)
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

  -- Interrupteur général coupé : rien ne part, rien ne se lance
  if not r.campagnes_actives then
    return jsonb_build_object('reponses_lues', v_lus, 'arret', 'CAMPAGNES_COUPEES');
  end if;
  -- Le transactionnel d'abord : en retard, le commercial attend le passage suivant
  if (select count(*) from public.notification_envois
       where statut = 'attente' and prochain_essai_le <= now()) > r.attente_transactionnel_max then
    return jsonb_build_object('reponses_lues', v_lus, 'arret', 'TRANSACTIONNEL_PRIORITAIRE');
  end if;

  -- 2. Les campagnes dues : audience figée, file remplie (une campagne par passage)
  for c in select * from public.communication_campagnes
            where statut = 'programmee' and planifiee_le <= now()
            order by planifiee_le limit 1 for update skip locked loop
    if c.empreinte_approuvee is null or c.empreinte_approuvee is distinct from public.communication_empreinte_campagne(c) then
      update public.communication_campagnes set statut = 'en_pause', arret_motif = 'EMPREINTE_CHANGEE', maj_le = now() where id = c.id;
      continue;
    end if;
    insert into public.communication_destinataires (campagne_id, client_id, canal, langue, modele_id, retenu, raison)
    select c.id, k.id, ca.canal, lg.langue,
           ((c.modeles -> ca.canal) ->> lg.langue)::uuid,
           ex.raison is null and rd.ok, coalesce(ex.raison, case when not rd.ok then 'VARIABLE_MANQUANTE' end)
      from public.communication_segment_clients(c.criteres) k
      cross join unnest(c.canaux) as ca(canal)
      cross join lateral (select case when (c.modeles -> ca.canal) ? cl.langue then cl.langue else c.langue_repli end langue
                            from public.clients cl where cl.id = k.id) lg
      cross join lateral (select public.communication_raison_exclusion(k.id, ca.canal, c.essai) raison) ex
      cross join lateral (select coalesce((public.communication_rendre(
                                   (select coalesce(mm.sujet, '') || ' ' || mm.corps from public.communication_modeles mm
                                     where mm.id = ((c.modeles -> ca.canal) ->> lg.langue)::uuid), k.id) ->> 'ok')::boolean, false) ok) rd
    on conflict (campagne_id, client_id, canal) do nothing;
    insert into public.communication_envois (campagne_id, destinataire_id, client_id, canal, cle, fournisseur)
    select d2.campagne_id, d2.id, d2.client_id, d2.canal,
           'campagne:' || d2.campagne_id || ':' || d2.client_id || ':' || d2.canal,
           case d2.canal when 'whatsapp' then 'meta' else coalesce(nullif(public.lire_reglage('email_fournisseur'), ''), 'brevo') end
      from public.communication_destinataires d2 where d2.campagne_id = c.id and d2.retenu
    on conflict (cle) do nothing;
    update public.communication_campagnes set statut = 'en_cours', lancee_le = now(), maj_le = now() where id = c.id;
  end loop;

  -- 3. Les envois dus, campagne en cours seulement, par petits lots
  for e in select ev.* from public.communication_envois ev
             join public.communication_campagnes ca on ca.id = ev.campagne_id and ca.statut = 'en_cours'
            where ev.statut in ('attente', 'nouvel_essai') and ev.prochain_essai_le <= now()
            order by ev.prochain_essai_le limit r.lot_par_minute
            for update of ev skip locked loop
    begin
      select * into c from public.communication_campagnes where id = e.campagne_id;
      select * into d from public.communication_destinataires where id = e.destinataire_id;
      select * into m from public.communication_modeles where id = d.modele_id;

      -- Canal coupé entre-temps : on attend, sans rien perdre
      if (e.canal = 'email' and not r.email_actif) or (e.canal = 'whatsapp' and not r.whatsapp_actif) then
        update public.communication_envois set prochain_essai_le = now() + interval '15 minutes', maj_le = now() where id = e.id;
        continue;
      end if;
      -- Retrait, STOP, liste d'essai… : le retrait gagne toujours
      v_raison := public.communication_raison_exclusion(e.client_id, e.canal, c.essai);
      if v_raison is not null then
        update public.communication_envois set statut = 'supprime', code_erreur = v_raison, maj_le = now() where id = e.id;
        v_ecartes := v_ecartes + 1;
        continue;
      end if;
      -- Heures permises et fréquence : on décale, on n'écarte pas
      if public.communication_prochaine_fenetre(e.client_id) > now() then
        update public.communication_envois set prochain_essai_le = public.communication_prochaine_fenetre(e.client_id), maj_le = now()
         where id = e.id;
        continue;
      end if;
      if public.communication_frequence_atteinte(e.client_id) then
        update public.communication_envois set prochain_essai_le = now() + interval '6 hours', maj_le = now() where id = e.id;
        continue;
      end if;
      -- Modèle toujours valable (Meta peut mettre un modèle en pause ou le désactiver)
      if m.statut <> 'approuve' or (e.canal = 'whatsapp' and m.whatsapp_statut_meta <> 'approuve') then
        update public.communication_campagnes set statut = 'en_pause', arret_motif = 'MODELE_INDISPONIBLE', maj_le = now()
         where id = c.id;
        continue;
      end if;
      -- Texte : jamais de variable non résolue
      v_rendu := public.communication_rendre(m.corps, e.client_id);
      v_sujet := case when e.canal = 'email' then public.communication_rendre(m.sujet, e.client_id) else '{"ok":true,"texte":""}'::jsonb end;
      if not (v_rendu ->> 'ok')::boolean or not (v_sujet ->> 'ok')::boolean then
        update public.communication_envois set statut = 'supprime', code_erreur = 'VARIABLE_MANQUANTE', maj_le = now() where id = e.id;
        v_ecartes := v_ecartes + 1;
        continue;
      end if;
      -- Coût estimé (tarif VÉRIFIÉ, sinon on n'envoie pas)
      v_pays := case when e.canal = 'whatsapp' then public.communication_pays_numero(public.communication_cible(e.client_id, 'whatsapp')) else '*' end;
      select t.prix_usd into v_cout from public.communication_tarifs t
       where t.fournisseur = e.fournisseur and t.canal = e.canal and t.pays = v_pays and t.verifie and t.autorise
         and t.categorie = case when e.canal = 'whatsapp' then lower(m.whatsapp_categorie) else 'email' end;
      if v_cout is null then
        update public.communication_envois set statut = 'supprime', code_erreur = 'TARIF_NON_VERIFIE', maj_le = now() where id = e.id;
        v_ecartes := v_ecartes + 1;
        continue;
      end if;
      -- Réservation sous verrou : plafond atteint → la campagne s'arrête (pause), l'envoi attend
      v_raison := public.communication_reserver(e, v_cout);
      if v_raison is not null then
        if v_raison like 'PLAFOND_CAMPAGNE%' then
          update public.communication_campagnes set statut = 'en_pause', arret_motif = v_raison, maj_le = now() where id = c.id;
        else
          update public.communication_envois
             set prochain_essai_le = ((public.communication_jour() + 1)::timestamp + interval '9 hours') at time zone 'America/Santo_Domingo',
                 maj_le = now()
           where id = e.id;
        end if;
        continue;
      end if;
      -- L'appel
      if e.canal = 'email' then
        v_requete := public.communication_appel_email(e, m.langue, v_sujet ->> 'texte', v_rendu ->> 'texte');
      else
        v_requete := public.communication_appel_whatsapp(e, m,
                       (select coalesce(array_agg((public.communication_rendre('{{' || v || '}}', e.client_id)) ->> 'texte' order by i), '{}')
                          from unnest(m.variables) with ordinality as t(v, i)));
      end if;
      update public.communication_envois
         set statut = 'traitement', requete = v_requete, tentative = tentative + 1, verrouille_le = now(),
             pays_tarif = v_pays, cout_estime_usd = v_cout, maj_le = now()
       where id = e.id;
      v_partis := v_partis + 1;
    exception when others then
      -- Rien n'est parti : l'envoi est clos avec un code (jamais le texte d'une erreur interne)
      update public.communication_envois
         set statut = 'echec', code_erreur = case when sqlerrm = 'NON_CONFIGURE' then 'NON_CONFIGURE' else 'ERREUR_INTERNE' end,
             maj_le = now()
       where id = e.id;
    end;
  end loop;

  -- 4. Les campagnes finies : plus rien à envoyer ni en cours
  update public.communication_campagnes ca set statut = 'terminee', terminee_le = now(), maj_le = now()
   where ca.statut = 'en_cours'
     and not exists (select 1 from public.communication_envois ev
                      where ev.campagne_id = ca.id and ev.statut in ('attente', 'traitement', 'nouvel_essai'));

  return jsonb_build_object('reponses_lues', v_lus, 'envoyes', v_partis, 'ecartes', v_ecartes);
end;
$$;


-- 7. Les retours des fournisseurs (webhooks) ------------------------------------------------
-- Un seul point d'entrée PUBLIC : la fonction Edge « communication-webhooks » (Phase 3), qui
-- vérifie la signature du fournisseur (Meta : X-Hub-Signature-256 ; Brevo : jeton secret
-- dans l'adresse + liste d'adresses IP), puis appelle la fonction ci-dessous avec la clé
-- PUBLIQUE et une signature interne (HMAC du contenu, clé « communication_cle_webhook »
-- partagée entre le coffre et les secrets de la fonction Edge). La fonction Edge ne détient
-- donc AUCUNE clé capable de contourner la RLS (la clé service_role reste « utilisée nulle
-- part », docs/production/secrets.md).
create table if not exists public.communication_evenements_fournisseur (
  id             bigint generated always as identity primary key,
  fournisseur    text not null check (fournisseur in ('meta', 'brevo', 'resend')),
  evenement_id   text not null,                 -- identifiant chez le fournisseur : rejeu refusé
  type           text not null,                 -- sent, delivered, read, failed, bounce, complaint, unsubscribe, inbound
  message_id     text,
  envoi_id       bigint,
  code           text,                          -- code du fournisseur, jamais son texte libre
  recu_le        timestamptz not null default now(),
  survenu_le     timestamptz,
  unique (fournisseur, evenement_id)
);
alter table public.communication_evenements_fournisseur enable row level security;
revoke all on public.communication_evenements_fournisseur from anon, authenticated;
drop trigger if exists communication_evenements_immuable on public.communication_evenements_fournisseur;
create trigger communication_evenements_immuable
  before update or delete on public.communication_evenements_fournisseur
  for each row execute function public.communication_immuable();

-- La fenêtre de 24 h de WhatsApp : le dernier message reçu d'un numéro (empreinte seulement,
-- jamais le contenu). Sert aux réponses de service, jamais au commercial.
create table if not exists public.communication_fenetres_whatsapp (
  cible_empreinte  text primary key,
  dernier_entrant  timestamptz not null
);
alter table public.communication_fenetres_whatsapp enable row level security;
revoke all on public.communication_fenetres_whatsapp from anon, authenticated;

-- Les mots qui arrêtent tout (quatre langues). Liste À FAIRE VALIDER (D-F).
create or replace function public.communication_est_stop(p_texte text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select upper(trim(regexp_replace(translate(coalesce(p_texte, ''), 'ÀÂÉÈÊËÎÏÔÙÛÜÇàâéèêëîïôùûüç', 'AAEEEEIIOUUUCaaeeeeiiouuuc'),
                                   '[^A-Za-z ]', '', 'g')))
         in ('STOP', 'ARRET', 'ARRETER', 'DESABONNER', 'DESINSCRIRE', 'UNSUBSCRIBE', 'CANCEL',
             'BAJA', 'PARAR', 'DETENER', 'KANPE', 'SISPANN', 'DEZABONE')
$$;

-- Le point d'entrée des retours, appelé par la fonction Edge. Idempotent (evenement_id unique).
-- p_evenement : {"id","type","message_id","code","survenu_le","telephone" (entrant seulement),
-- "texte" (entrant seulement, lu pour STOP puis oublié)}.
create or replace function public.communication_recevoir_evenement(p_fournisseur text, p_charge text, p_signature text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  -- La signature porte sur le texte BRUT envoyé par la fonction Edge (jamais sur un JSON
  -- reformaté par PostgreSQL, que la fonction Edge ne saurait pas reproduire)
  v_attendue text := encode(extensions.hmac(p_fournisseur || ':' || coalesce(p_charge, ''),
                                            coalesce(public.lire_reglage('communication_cle_webhook'), ''), 'sha256'), 'hex');
  e public.communication_envois;
  p_evenement jsonb;
  v_type text;
  v_empreinte text;
  v_id bigint;
begin
  -- Clé absente du coffre : tout est refusé (jamais d'acceptation sans signature)
  if coalesce(public.lire_reglage('communication_cle_webhook'), '') = '' or p_signature is distinct from v_attendue then
    perform public.erreur_metier('PERMISSION_DENIED', 'Signature invalide.');
  end if;
  p_evenement := p_charge::jsonb;
  v_type := p_evenement ->> 'type';
  -- Un retour trop vieux (rejeu tardif) est refusé : 24 h de tolérance
  if (p_evenement ->> 'survenu_le')::timestamptz < now() - interval '24 hours' then
    return jsonb_build_object('ok', false, 'trop_ancien', true);
  end if;
  -- L'envoi commercial concerné, s'il y en a un (un entrant n'en a pas)
  if v_type <> 'inbound' then
    select * into e from public.communication_envois
     where fournisseur = p_fournisseur and message_id = p_evenement ->> 'message_id' for update;
  end if;
  insert into public.communication_evenements_fournisseur (fournisseur, evenement_id, type, message_id, envoi_id, code, survenu_le)
  values (p_fournisseur, left(p_evenement ->> 'id', 200), left(v_type, 40), left(p_evenement ->> 'message_id', 200),
          e.id, left(p_evenement ->> 'code', 60), (p_evenement ->> 'survenu_le')::timestamptz)
  on conflict (fournisseur, evenement_id) do nothing
  returning id into v_id;
  if v_id is null then
    return jsonb_build_object('ok', true, 'rejeu', true);
  end if;

  -- Message entrant (WhatsApp) : fenêtre de 24 h, et STOP
  if v_type = 'inbound' then
    v_empreinte := public.communication_empreinte('whatsapp', p_evenement ->> 'telephone');
    insert into public.communication_fenetres_whatsapp (cible_empreinte, dernier_entrant) values (v_empreinte, now())
    on conflict (cible_empreinte) do update set dernier_entrant = now();
    if public.communication_est_stop(p_evenement ->> 'texte') then
      insert into public.communication_suppressions (canal, cible_empreinte, raison, source)
      values ('whatsapp', v_empreinte, 'stop', 'whatsapp_entrant') on conflict do nothing;
      insert into public.communication_consentements (client_id, canal, action, source, cible_empreinte)
      select c.id, 'whatsapp', 'retire', 'whatsapp_stop', v_empreinte
        from public.clients c
       where public.communication_empreinte('whatsapp', public.telephone_international(c.telephone, c.pays)) = v_empreinte;
    end if;
    return jsonb_build_object('ok', true);
  end if;

  -- Statut d'un message commercial (les messages transactionnels ne sont pas dans cette file :
  -- leur suivi reste celui de supabase-suivi-courriels.sql et supabase-accuses.sql)
  if e.id is null then
    return jsonb_build_object('ok', true, 'inconnu', true);
  end if;
  update public.communication_envois set
    statut = case
      when v_type = 'delivered' and statut in ('traitement', 'envoye') then 'livre'
      when v_type = 'read' and statut in ('traitement', 'envoye', 'livre') then 'lu'
      when v_type in ('failed', 'bounce', 'hard_bounce', 'invalid_email', 'blocked') then 'echec'
      else statut end,
    livre_le = case when v_type = 'delivered' then coalesce(livre_le, now()) else livre_le end,
    lu_le = case when v_type = 'read' then coalesce(lu_le, now()) else lu_le end,
    code_erreur = case when v_type in ('failed', 'bounce', 'hard_bounce', 'invalid_email', 'blocked', 'complaint')
                       then left(coalesce(p_evenement ->> 'code', upper(v_type)), 60) else code_erreur end,
    maj_le = now()
  where id = e.id;
  -- Rebond définitif, plainte, désinscription chez le fournisseur : suppression (et retrait)
  if v_type in ('hard_bounce', 'invalid_email', 'complaint', 'unsubscribe') then
    insert into public.communication_suppressions (canal, cible_empreinte, client_id, raison, source)
    values (e.canal, public.communication_empreinte(e.canal, public.communication_cible(e.client_id, e.canal)), e.client_id,
            case v_type when 'complaint' then 'plainte' when 'unsubscribe' then 'desinscription' else 'rebond_definitif' end,
            p_fournisseur)
    on conflict do nothing;
    if v_type in ('complaint', 'unsubscribe') then
      insert into public.communication_consentements (client_id, canal, action, source, cible_empreinte)
      values (e.client_id, e.canal, 'retire', case v_type when 'complaint' then 'plainte' else 'lien_desinscription' end,
              public.communication_empreinte(e.canal, public.communication_cible(e.client_id, e.canal)));
    end if;
  end if;
  return jsonb_build_object('ok', true);
end;
$$;


-- 8. La désinscription par le lien ------------------------------------------------------------
-- Ouverte aux VISITEURS (la page desinscription.html n'exige pas de connexion) : à ajouter à
-- la liste blanche de controle-securite.sql (section 6). Le jeton est vérifié par HMAC ;
-- idempotente ; ne renvoie aucune donnée personnelle.
create or replace function public.desinscrire_communication(p_jeton text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
  e public.communication_envois;
  v_empreinte text;
begin
  if coalesce(p_jeton, '') !~ '^[0-9]{1,18}\.[A-Za-z0-9_-]{32}$' then
    return jsonb_build_object('ok', false);
  end if;
  v_id := split_part(p_jeton, '.', 1)::bigint;
  if public.communication_jeton_desinscription(v_id) is distinct from p_jeton then
    return jsonb_build_object('ok', false);
  end if;
  select * into e from public.communication_envois where id = v_id;
  if not found then
    return jsonb_build_object('ok', false);
  end if;
  v_empreinte := public.communication_empreinte(e.canal, public.communication_cible(e.client_id, e.canal));
  insert into public.communication_suppressions (canal, cible_empreinte, client_id, raison, source)
  values (e.canal, coalesce(v_empreinte, 'inconnue:' || e.client_id), e.client_id, 'desinscription', 'lien')
  on conflict do nothing;
  if public.communication_consentement_actuel(e.client_id, e.canal) then
    insert into public.communication_consentements (client_id, canal, action, source, cible_empreinte)
    values (e.client_id, e.canal, 'retire', 'lien_desinscription', v_empreinte);
  end if;
  return jsonb_build_object('ok', true, 'canal', e.canal);
end;
$$;


-- 9. Santé et planificateur -------------------------------------------------------------------
-- Lue par l'onglet du Centre et, en Phase 2, par controle-integrite.sql. Le battement
-- (supabase-battement.sql) signale déjà toute tâche « goship-… » en échec.
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
    'reglages', (select to_jsonb(r) - 'adresse_postale_validee_par' - 'maj_par' - 'brevo_quota_verifie_par'
                   from public.communication_reglages r),
    'brevo_disponible_aujourdhui', public.communication_brevo_disponible(),
    'depenses_du_jour', (select coalesce(jsonb_agg(to_jsonb(d)), '[]'::jsonb)
                           from public.communication_depenses_jour d where d.jour = public.communication_jour()),
    'file', (select coalesce(jsonb_object_agg(statut, n), '{}'::jsonb)
               from (select statut, count(*) n from public.communication_envois group by statut) s),
    'messages_morts', (select count(*) from public.communication_envois where statut = 'abandon'),
    'en_cours_bloques', (select count(*) from public.communication_envois
                          where statut = 'traitement' and verrouille_le < now() - interval '15 minutes'),
    'travailleur', (select jsonb_build_object('actif', j.active)
                      from cron.job j where j.jobname = 'goship-communications'));
end;
$$;

revoke execute on function public.communication_fuseau(uuid) from public, anon, authenticated;
revoke execute on function public.communication_prochaine_fenetre(uuid) from public, anon, authenticated;
revoke execute on function public.communication_frequence_atteinte(uuid) from public, anon, authenticated;
revoke execute on function public.communication_reserver(public.communication_envois, numeric) from public, anon, authenticated;
revoke execute on function public.communication_jeton_desinscription(bigint) from public, anon, authenticated;
revoke execute on function public.communication_appel_email(public.communication_envois, text, text, text) from public, anon, authenticated;
revoke execute on function public.communication_appel_whatsapp(public.communication_envois, public.communication_modeles, text[]) from public, anon, authenticated;
revoke execute on function public.communication_textes_pied(text) from public, anon, authenticated;
revoke execute on function public.communication_lire_reponse(public.communication_envois, integer, text, text) from public, anon, authenticated;
revoke execute on function public.traiter_communications() from public, anon, authenticated;
revoke execute on function public.communication_est_stop(text) from public, anon, authenticated;

-- Les deux seules portes ouvertes sans compte, chacune protégée par sa propre signature :
revoke execute on function public.communication_recevoir_evenement(text, text, text) from public, authenticated;
grant execute on function public.communication_recevoir_evenement(text, text, text) to anon;
revoke execute on function public.desinscrire_communication(text) from public;
grant execute on function public.desinscrire_communication(text) to anon, authenticated;

revoke execute on function public.sante_communications() from public, anon;
grant execute on function public.sante_communications() to authenticated;

-- Le travailleur : chaque minute, comme le transactionnel (pg_cron ne descend pas sous la
-- minute) ; c'est lui qui cède la place (attente_transactionnel_max), pas l'horaire.
-- NÉ ARRÊTÉ : la tâche est créée inactive, et seul l'administrateur l'allume, sur décision
-- écrite du CEO (en plus de l'interrupteur campagnes_actives, qui reste éteint).
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
