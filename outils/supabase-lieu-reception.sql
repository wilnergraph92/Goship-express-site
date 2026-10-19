-- =============================================================================
-- Goship Express — le lieu de réception est obligatoire et figure dans l'e-mail « Colis reçu » (19/10/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce fichier
-- AJOUTE trois petites fonctions et REMPLACE creer_colis (l'enregistrement d'un
-- colis), courriel_colis et expedier_envoi (l'e-mail). Il ne change aucune
-- donnée, aucun colis, aucun envoi déjà fait, et peut être relancé autant de
-- fois qu'on veut.
--
-- Ordre d'installation : le dernier de la chaîne (outils/migrations.txt), après
-- supabase-courriel-pied.sql. Il ne faut PAS relancer supabase-corrections.sql,
-- supabase-courriel-colis.sql ni supabase-notifications.sql après lui : ces
-- fichiers-là remettraient les anciennes versions.
--
-- Avant : le champ « Lieu de réception » de la fenêtre d'enregistrement d'un
-- colis arrivait rempli « Miami (Medley), FL », et si on le vidait la base
-- écrivait quand même Miami. Un colis reçu à Santo Domingo ou à Port-au-Prince
-- partait donc « reçu à Miami », et l'e-mail disait toujours « à notre entrepôt
-- de Miami ».
--
-- Maintenant :
--    · creer_colis refuse un colis sans lieu de réception (LOCATION_REQUIRED) ;
--      plus aucun lieu par défaut. Le formulaire du tableau de bord le demande
--      aussi, mais c'est la base qui décide.
--    · l'e-mail « Colis reçu » dit où le colis a été reçu, dans la langue du
--      compte, avec le lieu de l'événement de réception :
--          Colis reçu à Miami · Colis reçu à Port-au-Prince ·
--          Colis reçu en République dominicaine
--          Package received in Miami · Paquete recibido en Miami · Koli resevwa nan Miami
--      Le lieu est dans le sujet, le titre, la phrase d'ouverture et la ligne
--      « Statut ». « Miami (Medley), FL » et « Port de Miami » se lisent « Miami ».
--      Un ancien colis dont l'événement n'a pas de lieu garde l'ancienne phrase.
--
-- Rien d'autre ne change : « Colis disponible » garde son texte (l'agence), le
-- téléphone, l'espace client et WhatsApp gardent leur court message.
--
-- Contenu :
--    1. garde : la chaîne est-elle à jour ?
--    2. creer_colis (REMPLACE celle de supabase-corrections.sql)
--    3. le lieu en toutes lettres : lieu_reception_court, lieu_reception_phrase
--    4. les textes (quatre langues)
--    5. courriel_colis (REMPLACE celle de supabase-courriel-colis.sql)
--    6. expedier_envoi (REMPLACE celle de supabase-courriel-colis.sql)
--    7. droits
--    8. contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regprocedure('public.creer_colis(jsonb, text, boolean)') is null
     or not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                     where n.nspname = 'public' and p.proname = 'courriel_colis')
     or to_regprocedure('public.expedier_envoi(public.notification_envois)') is null
     or to_regprocedure('public.langue_notification(text)') is null
     or to_regprocedure('public.html_echappe(text)') is null then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt), puis ce fichier.';
  end if;
end;
$garde$;


-- 2. Enregistrer un colis -----------------------------------------------------------------
-- creer_colis de supabase-corrections.sql, sauf le lieu : obligatoire, sans défaut.
-- Même contrat : { colis, facture, deja }, tout ou rien, clé d'idempotence. Une requête
-- répétée rend le colis déjà créé avant de regarder le lieu.
create or replace function public.creer_colis(p_colis jsonb, p_cle text default null,
                                              p_facturer boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cle text := nullif(trim(coalesce(p_cle, '')), '');
  v_client uuid;
  v_id uuid;
  v_existant public.colis;
  v_facture jsonb;
  v_recu timestamptz;
  v_lieu text;
begin
  perform public.exiger_permission('shipments.create');
  if p_colis is null or jsonb_typeof(p_colis) <> 'object' then
    perform public.erreur_metier('INVALID_INPUT', 'Données du colis manquantes.');
  end if;
  if v_cle is not null and length(v_cle) > 80 then
    perform public.erreur_metier('INVALID_INPUT', 'Clé de requête trop longue.');
  end if;
  v_client := public.lire_uuid(p_colis -> 'client_id', 'CLIENT_NOT_FOUND', 'Identifiant de client illisible.');

  -- Requête répétée (double clic, connexion revenue) : on rend le colis déjà
  -- créé. Le verrou couvre le cas où les deux envois arrivent en même temps.
  if v_cle is not null then
    perform pg_advisory_xact_lock(hashtextextended('goship-creer-colis:' || v_cle, 0));
    select * into v_existant from public.colis where cle_idempotence = v_cle;
    if found then
      if v_existant.client_id is distinct from v_client then
        perform public.erreur_metier('DUPLICATE_OPERATION',
          'Cette requête a déjà servi à enregistrer le colis ' || v_existant.numero || ' pour un autre client.');
      end if;
      raise log 'goship creer_colis repete numero=%', v_existant.numero;
      return jsonb_build_object(
        'colis', public.colis_json(v_existant.id),
        'facture', (select public.facture_json(l.facture_id)
                      from public.facture_lignes l join public.factures f on f.id = l.facture_id
                     where l.colis_id = v_existant.id and f.statut <> 'annulee'
                     order by f.cree_le desc limit 1),
        'deja', true);
    end if;
  end if;

  -- Le lieu de réception est obligatoire : c'est lui que lit l'e-mail « Colis reçu à… ».
  -- Aucun lieu par défaut : un colis reçu ailleurs qu'à Miami ne doit pas y être
  -- rangé sans que personne l'ait dit.
  v_lieu := trim(coalesce(p_colis ->> 'lieu', ''));
  if v_lieu = '' then
    perform public.erreur_metier('LOCATION_REQUIRED',
      'Indiquez le lieu de réception du colis (Miami, Santo Domingo, Port-au-Prince…).');
  end if;
  if length(v_lieu) > 80 then
    perform public.erreur_metier('INVALID_INPUT', 'Le lieu de réception est trop long (80 signes au plus).');
  end if;

  begin
    v_recu := coalesce(nullif(p_colis ->> 'recu_le', '')::timestamptz, now());
  exception when others then
    perform public.erreur_metier('INVALID_DATE', 'Date de réception illisible.');
  end;

  insert into public.colis (client_id, description, expediteur, suivi_transporteur, poids_lb, service,
                            pays_destination, destination, adresse_livraison, recu_le, tarif_lb_usd,
                            prix_fixe_usd, lieu, note, statut, cle_idempotence)
  values (v_client,
          coalesce(p_colis ->> 'description', ''),
          coalesce(p_colis ->> 'expediteur', ''),
          coalesce(p_colis ->> 'suivi_transporteur', ''),
          public.lire_nombre(p_colis -> 'poids_lb', 'INVALID_WEIGHT', 'Poids illisible.'),
          coalesce(nullif(p_colis ->> 'service', ''), 'aerien'),
          coalesce(nullif(p_colis ->> 'pays_destination', ''), 'HT'),
          coalesce(p_colis ->> 'destination', ''),
          coalesce(p_colis ->> 'adresse_livraison', ''),
          v_recu,
          public.lire_nombre(p_colis -> 'tarif_lb_usd', 'INVALID_RATE', 'Tarif illisible.'),
          public.lire_nombre(p_colis -> 'prix_fixe_usd', 'INVALID_PRICE', 'Prix du colis illisible.'),
          v_lieu,
          coalesce(p_colis ->> 'note', ''),
          'recu',
          v_cle)
  returning id into v_id;

  -- La facture naît avec le colis : c'est la règle de la maison, pas une
  -- facturation à part. Elle ne demande donc pas invoices.create — un employé
  -- qui enregistre un colis produit sa facture, sans pouvoir en faire d'autres.
  if p_facturer then
    v_facture := public.facturer_colis_interne(v_id) -> 'facture';
  end if;

  return jsonb_build_object('colis', public.colis_json(v_id), 'facture', v_facture, 'deja', false);
end;
$$;


-- 3. Le lieu en toutes lettres ---------------------------------------------------------------
-- Ce que le personnel écrit (« Miami (Medley), FL », « Port de Miami ») devient ce qu'un
-- client lit : « Miami ». Un nom de ville ou de pays reste tel quel.
create or replace function public.lieu_reception_court(p_lieu text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
           when trim(coalesce(p_lieu, '')) = '' then ''
           when p_lieu ~* 'miami' then 'Miami'
           else coalesce(
                  nullif(trim(regexp_replace(regexp_replace(trim(p_lieu), '\s*\([^)]*\)', '', 'g'),
                                             ',\s*[A-Za-z]{2}$', '')), ''),
                  trim(p_lieu))
         end
$$;

-- Le lieu avec sa préposition, dans la langue du client : « à Miami », « en République
-- dominicaine », « in Miami », « nan Pòtoprens »… Vide si aucun lieu n'est connu.
create or replace function public.lieu_reception_phrase(p_lieu text, p_langue text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_langue text := public.langue_notification(p_langue);
  v text := public.lieu_reception_court(p_lieu);
  v_norme text;
  v_pays text;
begin
  if v = '' then
    return '';
  end if;
  v_norme := translate(lower(v), 'éèêëàâîïôùûç', 'eeeeaaiiouuc');
  v_pays := case
              when v_norme ~ '^(republique dominicaine|rep\.? dominicaine|republica dominicana|dominican republic|repiblik dominikenn?)$' then 'DO'
              when v_norme in ('haiti', 'ayiti') then 'HT'
              when v_norme in ('etats-unis', 'etats unis', 'usa', 'etazini', 'united states', 'estados unidos') then 'US'
            end;
  if v_pays is not null then
    return case v_langue
      when 'en' then 'in ' || case v_pays when 'DO' then 'the Dominican Republic' when 'HT' then 'Haiti' else 'the United States' end
      when 'es' then 'en ' || case v_pays when 'DO' then 'República Dominicana' when 'HT' then 'Haití' else 'Estados Unidos' end
      when 'ht' then case v_pays when 'DO' then 'nan Repiblik Dominikèn' when 'HT' then 'an Ayiti' else 'nan Etazini' end
      else case v_pays when 'DO' then 'en République dominicaine' when 'HT' then 'en Haïti' else 'aux États-Unis' end
    end;
  end if;
  return case v_langue
    when 'en' then 'in ' || v
    when 'es' then 'en ' || v
    when 'ht' then 'nan ' || v
    else case when v ~* '^les ' then 'aux ' || substr(v, 5)
              when v ~* '^le ' then 'au ' || substr(v, 4)
              else 'à ' || v end
  end;
end;
$$;


-- 4. Les textes ------------------------------------------------------------------------------
-- {lieu} : le lieu avec sa préposition (lieu_reception_phrase).
create or replace function public.courriel_lieu_textes()
returns jsonb
language sql
immutable
set search_path = ''
as $cat$
  select $json$
{
  "fr": {"titre": "Colis reçu {lieu}", "statut": "Reçu {lieu}",
         "intro": "Nous avons bien reçu votre colis {lieu}. En voici les détails :"},
  "en": {"titre": "Package received {lieu}", "statut": "Received {lieu}",
         "intro": "We have received your package {lieu}. Here are the details:"},
  "es": {"titre": "Paquete recibido {lieu}", "statut": "Recibido {lieu}",
         "intro": "Le informamos que recibimos su paquete {lieu}. Estos son los detalles:"},
  "ht": {"titre": "Koli resevwa {lieu}", "statut": "Resevwa {lieu}",
         "intro": "Nou byen resevwa koli ou {lieu}. Men detay li yo :"}
}
$json$::jsonb
$cat$;


-- 5. Le contenu de l'e-mail d'un colis ---------------------------------------------------------
-- courriel_colis de supabase-courriel-colis.sql, avec un paramètre de plus : l'événement
-- (p_historique, facultatif). Pour « Colis reçu », le lieu est celui de l'événement de
-- réception ; sans événement donné, celui du premier événement du colis. Rend {html, texte,
-- titre} : titre est le titre complet (« Colis reçu à Miami »), null quand il n'y a rien à
-- changer au titre habituel du message.
drop function if exists public.courriel_colis(text, text, uuid, text);
create or replace function public.courriel_colis(p_type text, p_langue text, p_colis uuid, p_code_client text,
                                                 p_historique bigint default null)
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
  v_lieu text;
  v_phrase text := '';
  v_titre text;
  v_statut text;
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
  v_statut := v_t -> 'statut' ->> v_evenement;
  v_intro := case when v_evenement = 'recu' then v_t -> 'intro' ->> 'recu'
                  when v_agence <> '' then replace(v_t -> 'intro' ->> 'disponible', '{agence}', v_agence)
                  else v_t -> 'intro' ->> 'disponible_sans_agence' end;

  -- « Colis reçu » : où le colis a été reçu
  if v_evenement = 'recu' then
    if p_historique is not null then
      select nullif(trim(h.lieu), '') into v_lieu from public.colis_historique h
       where h.id = p_historique and h.colis_id = p_colis;
    end if;
    if v_lieu is null then
      select nullif(trim(h.lieu), '') into v_lieu from public.colis_historique h
       where h.colis_id = p_colis order by h.id limit 1;
    end if;
    v_phrase := public.lieu_reception_phrase(v_lieu, v_langue);
    if v_phrase <> '' then
      v_titre := replace(public.courriel_lieu_textes() -> v_langue ->> 'titre', '{lieu}', v_phrase);
      v_statut := replace(public.courriel_lieu_textes() -> v_langue ->> 'statut', '{lieu}', v_phrase);
      v_intro := replace(public.courriel_lieu_textes() -> v_langue ->> 'intro', '{lieu}', v_phrase);
    end if;
  end if;

  v_valeurs := array[
    v_statut,
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
    'texte', v_intro || E'\n' || v_texte,
    'titre', v_titre);
end;
$fn$;


-- 6. L'envoi : la même fonction que supabase-courriel-colis.sql, sauf le titre ----------------------
-- (sujet et titre de l'e-mail « Colis reçu » : « Colis reçu à Miami » ; l'événement de la
-- notification, n.historique_id, dit quel lieu)
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
  v_titre text;
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
                     then public.courriel_colis(n.type, v_langue, n.colis_id, cl.code, n.historique_id) end;
    -- « Colis reçu à Miami » : le titre dit où le colis a été reçu (courriel_colis)
    v_titre := coalesce(nullif(v_detail ->> 'titre', ''), v_t ->> 'titre');
    v_email := jsonb_build_object(
      'sujet', v_titre || case when v_numero <> '' then ' — ' || v_numero
                                         when n.donnees ? 'facture' then ' — ' || (n.donnees ->> 'facture') else '' end,
      'html', public.courriel_gabarit(v_langue, v_titre,
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


-- 7. Droits ------------------------------------------------------------------------------------
revoke execute on function public.lieu_reception_court(text) from public, anon, authenticated;
revoke execute on function public.lieu_reception_phrase(text, text) from public, anon, authenticated;
revoke execute on function public.courriel_lieu_textes() from public, anon, authenticated;
revoke execute on function public.courriel_colis(text, text, uuid, text, bigint) from public, anon, authenticated;
revoke execute on function public.expedier_envoi(public.notification_envois) from public, anon, authenticated;
revoke execute on function public.creer_colis(jsonb, text, boolean) from public, anon;
grant execute on function public.creer_colis(jsonb, text, boolean) to authenticated;


-- 8. Contrôle -------------------------------------------------------------------------------------
-- fonctions : 3 ; creer_colis_exige_le_lieu : true ; expedier_envoi_a_jour : true ;
-- ouvertes_aux_visiteurs : false.
select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname in ('lieu_reception_court', 'lieu_reception_phrase', 'courriel_lieu_textes')) as fonctions,
       position('LOCATION_REQUIRED' in pg_get_functiondef('public.creer_colis(jsonb, text, boolean)'::regprocedure)) > 0 as creer_colis_exige_le_lieu,
       position('historique_id' in pg_get_functiondef('public.expedier_envoi(public.notification_envois)'::regprocedure)) > 0 as expedier_envoi_a_jour,
       (select coalesce(bool_or(has_function_privilege('anon', p.oid, 'execute')), false)
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('lieu_reception_court', 'lieu_reception_phrase', 'courriel_lieu_textes', 'courriel_colis',
                            'courriel_colis_textes', 'expedier_envoi', 'creer_colis')) as ouvertes_aux_visiteurs;
