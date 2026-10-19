-- =============================================================================
-- Goship Express — l'e-mail « Colis reçu » et « Colis disponible » donne les détails du colis (19/10/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce fichier
-- AJOUTE trois petites fonctions et REMPLACE expedier_envoi (la fonction qui
-- remet un envoi à son fournisseur). Il ne change aucune donnée, aucune règle,
-- aucun envoi déjà fait, et peut être relancé autant de fois qu'on veut.
--
-- Ordre d'installation : le dernier de la chaîne (outils/migrations.txt), après
-- supabase-campagnes.sql. Il ne faut PAS relancer supabase-notifications.sql
-- après lui : ce fichier-là remettrait l'ancienne expedier_envoi.
--
-- Avant : l'e-mail d'un colis reçu ne portait que la phrase « Votre colis GSE-…
-- a bien été reçu à notre entrepôt de Miami ». Maintenant il garde cette phrase
-- et ajoute un tableau :
--    Statut · Code client · N° de colis · Expéditeur · Service · Contenu ·
--    Suivi vendeur (masqué sauf les 4 derniers signes) · Poids
-- dans la langue du compte (français, anglais, espagnol, créole). Une ligne dont
-- la valeur est vide n'est pas écrite.
--
-- Quand : seulement pour « Colis reçu » (shipment_received) et « Colis disponible »
-- (shipment_available), les deux seuls messages de colis qui ont le canal e-mail
-- (docs/notifications.md, section 3). Les autres étapes (emballé, expédié, arrivé,
-- transféré, livré) n'envoient pas d'e-mail. Les messages de facture et d'action
-- requise gardent leur phrase seule.
--
-- Rien d'autre ne change : le téléphone, l'espace client et WhatsApp gardent leur
-- court message ; l'e-mail n'est toujours remis que par expedier_envoi, sur le
-- même chemin (file, essais, statut honnête). Les valeurs viennent de la base, échappées.
--
-- Contenu :
--    1. garde : la chaîne est-elle à jour ?
--    2. les textes (quatre langues)
--    3. suivi_masque
--    4. courriel_colis : l'intro et le tableau
--    5. expedier_envoi (REMPLACE celle de supabase-notifications.sql)
--    6. droits
--    7. contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regprocedure('public.expedier_envoi(public.notification_envois)') is null
     or to_regprocedure('public.courriel_gabarit(text, text, text, text, text, text, text)') is null
     or to_regprocedure('public.html_echappe(text)') is null
     or to_regprocedure('public.langue_notification(text)') is null
     or to_regprocedure('public.notification_textes()') is null then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt), puis ce fichier.';
  end if;
end;
$garde$;


-- 2. Les textes -----------------------------------------------------------------------
-- Ceux du message que le tableau de bord préparait « à la main » (assets/js/notifications.js),
-- plus la ligne « Statut ». {agence} : le lieu de la dernière étape du colis.
create or replace function public.courriel_colis_textes()
returns jsonb
language sql
immutable
set search_path = ''
as $cat$
  select $json$
{
  "fr": {
    "intro": {
      "recu": "Nous avons bien reçu votre colis à notre entrepôt de Miami. En voici les détails :",
      "disponible": "Votre colis est disponible dans notre agence de {agence}. Présentez votre code client pour le retirer. En voici les détails :",
      "disponible_sans_agence": "Votre colis est disponible dans notre agence. Présentez votre code client pour le retirer. En voici les détails :"
    },
    "statut": {
      "recu": "Reçu à Miami",
      "disponible": "Disponible en agence"
    },
    "libelles": {
      "statut": "Statut",
      "code": "Code client",
      "numero": "N° de colis",
      "expediteur": "Expéditeur",
      "service": "Service",
      "contenu": "Contenu",
      "suivi": "Suivi vendeur",
      "poids": "Poids"
    },
    "services": {
      "aerien": "Fret aérien",
      "maritime": "Fret maritime",
      "terrestre": "Transport terrestre"
    }
  },
  "en": {
    "intro": {
      "recu": "We have received your package at our Miami warehouse. Here are the details:",
      "disponible": "Your package is ready for pickup at our {agence} office. Please show your customer code when you collect it. Here are the details:",
      "disponible_sans_agence": "Your package is ready for pickup at our office. Please show your customer code when you collect it. Here are the details:"
    },
    "statut": {
      "recu": "Received in Miami",
      "disponible": "Ready for pickup"
    },
    "libelles": {
      "statut": "Status",
      "code": "Customer code",
      "numero": "Package number",
      "expediteur": "Sender",
      "service": "Service",
      "contenu": "Contents",
      "suivi": "Seller tracking",
      "poids": "Weight"
    },
    "services": {
      "aerien": "Air freight",
      "maritime": "Ocean freight",
      "terrestre": "Ground transport"
    }
  },
  "es": {
    "intro": {
      "recu": "Le informamos que recibimos su paquete en nuestro almacén de Miami. Estos son los detalles:",
      "disponible": "Le informamos que tiene disponible en nuestra oficina de {agence} el siguiente paquete. Presente su código de cliente para retirarlo. Estos son los detalles:",
      "disponible_sans_agence": "Le informamos que tiene disponible en nuestra oficina el siguiente paquete. Presente su código de cliente para retirarlo. Estos son los detalles:"
    },
    "statut": {
      "recu": "Recibido en Miami",
      "disponible": "Disponible para retiro"
    },
    "libelles": {
      "statut": "Estatus",
      "code": "Código de cliente",
      "numero": "N.º de paquete",
      "expediteur": "Suplidor",
      "service": "Servicio",
      "contenu": "Contenido",
      "suivi": "Tracking del suplidor",
      "poids": "Peso"
    },
    "services": {
      "aerien": "Flete aéreo",
      "maritime": "Flete marítimo",
      "terrestre": "Transporte terrestre"
    }
  },
  "ht": {
    "intro": {
      "recu": "Nou byen resevwa koli ou nan depo nou an Miami. Men detay li yo :",
      "disponible": "Koli ou disponib nan ajans nou an {agence}. Montre kòd kliyan ou pou w vin chèche l. Men detay li yo :",
      "disponible_sans_agence": "Koli ou disponib nan ajans nou an. Montre kòd kliyan ou pou w vin chèche l. Men detay li yo :"
    },
    "statut": {
      "recu": "Resevwa Miami",
      "disponible": "Disponib nan ajans"
    },
    "libelles": {
      "statut": "Estati",
      "code": "Kòd kliyan",
      "numero": "Nimewo koli",
      "expediteur": "Machann",
      "service": "Sèvis",
      "contenu": "Sa ki ladan l",
      "suivi": "Swivi machann",
      "poids": "Pwa"
    },
    "services": {
      "aerien": "Fret pa lè",
      "maritime": "Fret pa lanmè",
      "terrestre": "Transpò pa tè"
    }
  }
}
$json$::jsonb
$cat$;


-- 3. Le suivi du vendeur, masqué ------------------------------------------------------------
-- Les quatre derniers signes seulement : le numéro entier suffit à suivre le colis chez
-- le vendeur, pas besoin de le promener dans une boîte de réception.
create or replace function public.suivi_masque(p_suivi text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when length(trim(coalesce(p_suivi, ''))) = 0 then ''
              when length(trim(p_suivi)) <= 4 then repeat('*', length(trim(p_suivi)))
              else repeat('*', length(trim(p_suivi)) - 4) || right(trim(p_suivi), 4) end
$$;


-- 4. Le contenu de l'e-mail d'un colis --------------------------------------------------------
-- Rend {html, texte} : la phrase, puis le tableau. null pour tout autre type de message
-- (l'appelant garde alors sa phrase seule). Lit le colis AU MOMENT de l'envoi : un poids
-- corrigé entre-temps part corrigé.
create or replace function public.courriel_colis(p_type text, p_langue text, p_colis uuid, p_code_client text)
returns jsonb
language plpgsql
stable
set search_path = ''
as $fn$
declare
  v_langue text := public.langue_notification(p_langue);
  v_t jsonb := public.courriel_colis_textes() -> v_langue;
  v_evenement text := case p_type when 'shipment_received' then 'recu' when 'shipment_available' then 'disponible' end;
  c public.colis;
  v_agence text;
  v_intro text;
  v_cles text[] := array['statut', 'code', 'numero', 'expediteur', 'service', 'contenu', 'suivi', 'poids'];
  v_valeurs text[];
  v_html text := '';
  v_texte text := '';
  v_separateur text := case when v_langue in ('en', 'es') then ': ' else ' : ' end;
  i integer;
begin
  if v_evenement is null then
    return null;
  end if;
  select * into c from public.colis where id = p_colis;
  if not found then
    return null;
  end if;

  v_agence := coalesce(trim(c.lieu), '');
  v_intro := case when v_evenement = 'recu' then v_t -> 'intro' ->> 'recu'
                  when v_agence <> '' then replace(v_t -> 'intro' ->> 'disponible', '{agence}', v_agence)
                  else v_t -> 'intro' ->> 'disponible_sans_agence' end;

  v_valeurs := array[
    v_t -> 'statut' ->> v_evenement,
    p_code_client,
    c.numero,
    c.expediteur,
    coalesce(v_t -> 'services' ->> c.service, c.service),
    c.description,
    public.suivi_masque(c.suivi_transporteur),
    case when c.poids_lb is null then ''
         else replace(to_char(c.poids_lb, 'FM999990.00'), '.', case when v_langue in ('fr', 'ht') then ',' else '.' end) || ' lb' end];

  for i in 1 .. array_length(v_cles, 1) loop
    if length(trim(coalesce(v_valeurs[i], ''))) = 0 then
      continue;
    end if;
    v_html := v_html ||
      '<tr><td style="padding:7px 14px;font-size:15px;color:#5b6782;text-align:right;vertical-align:top">' ||
      public.html_echappe(v_t -> 'libelles' ->> v_cles[i]) ||
      '</td><td style="padding:7px 14px;font-size:15px;font-weight:bold;color:#061a3f;text-align:left;vertical-align:top">' ||
      public.html_echappe(trim(v_valeurs[i])) || '</td></tr>';
    v_texte := v_texte || E'\n' || (v_t -> 'libelles' ->> v_cles[i]) || v_separateur || trim(v_valeurs[i]);
  end loop;

  return jsonb_build_object(
    'html', '<p style="margin:0;font-size:17px;line-height:1.55">' || public.html_echappe(v_intro) || '</p>' ||
            '<table role="presentation" cellpadding="0" cellspacing="0" align="center" style="margin:18px auto 0">' ||
            v_html || '</table>',
    'texte', v_intro || E'\n' || v_texte);
end;
$fn$;


-- 5. L'envoi : la même fonction que supabase-notifications.sql, sauf le corps de l'e-mail ----------
-- (« Colis reçu » et « Colis disponible » : le tableau ; le reste : la phrase seule, comme avant)
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
  v_detail jsonb;
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
    -- « Colis reçu » et « Colis disponible » : l'e-mail donne les détails du colis (courriel_colis) ;
    -- tout autre message garde sa phrase seule
    v_detail := case when n.type in ('shipment_received', 'shipment_available') and n.colis_id is not null
                     then public.courriel_colis(n.type, v_langue, n.colis_id, cl.code) end;
    v_email := jsonb_build_object(
      'sujet', (v_t ->> 'titre') || case when v_numero <> '' then ' — ' || v_numero
                                         when n.donnees ? 'facture' then ' — ' || (n.donnees ->> 'facture') else '' end,
      'html', public.courriel_gabarit(v_langue, v_t ->> 'titre',
                replace(v_email ->> 'salutation', '{{nom}}', coalesce(nullif(split_part(cl.nom_complet, ' ', 1), ''), '')),
                coalesce(v_detail ->> 'html',
                         '<p style="margin:0;font-size:16px;line-height:1.6">' || public.html_echappe(v_t ->> 'message') || '</p>'),
                v_email ->> 'bouton', v_lien, v_email ->> 'pied'),
      'texte', replace(v_email ->> 'salutation', '{{nom}}', coalesce(split_part(cl.nom_complet, ' ', 1), '')) || E'\n\n' ||
               coalesce(v_detail ->> 'texte', v_t ->> 'message') || case when v_lien <> '' then E'\n\n' || v_lien else '' end || E'\n\n— Goship Express');
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


-- 6. Droits ------------------------------------------------------------------------------------
revoke execute on function public.courriel_colis_textes() from public, anon, authenticated;
revoke execute on function public.suivi_masque(text) from public, anon, authenticated;
revoke execute on function public.courriel_colis(text, text, uuid, text) from public, anon, authenticated;
revoke execute on function public.expedier_envoi(public.notification_envois) from public, anon, authenticated;


-- 7. Contrôle -------------------------------------------------------------------------------------
-- fonctions : 3 ; ouvertes_aux_visiteurs : false ; expedier_envoi_a_jour : true.
select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname in ('courriel_colis_textes', 'suivi_masque', 'courriel_colis')) as fonctions,
       (select coalesce(bool_or(has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute')), false)
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('courriel_colis_textes', 'suivi_masque', 'courriel_colis', 'expedier_envoi')) as ouvertes_aux_visiteurs,
       position('courriel_colis' in pg_get_functiondef('public.expedier_envoi(public.notification_envois)'::regprocedure)) > 0 as expedier_envoi_a_jour;
