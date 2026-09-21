-- =============================================================================
-- Goship Express — les deux e-mails de bienvenue (21/09/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier > Run. Sans risque : aucune donnée n'est supprimée, et le script peut
-- être relancé autant de fois qu'on veut.
--
-- Ce fichier est déjà inclus dans outils/supabase.sql (partie 14) : si vous
-- relancez le fichier complet, vous n'avez pas besoin de celui-ci.
--
-- Ce qu'il ajoute : à la création d'un compte, le client reçoit deux e-mails
-- dans sa langue — « Bienvenue » avec son code client, puis « Votre adresse en
-- Floride » avec l'adresse à donner aux boutiques. Ils partent tout seuls, que
-- le compte soit créé depuis le site ou depuis l'application. Si l'adresse doit
-- être confirmée (Authentication > Confirm email), ils attendent la
-- confirmation. Un e-mail qui échoue n'empêche jamais la création du compte.
--
-- Il faut que l'envoi des e-mails soit déjà configuré (README, « Activer
-- l'envoi des e-mails ») : sans clé d'API, rien ne part et rien ne casse.
-- =============================================================================

-- Deux réglages à poser une fois dans le SQL Editor (voir README) :
--   select public.definir_reglage('site_url', 'https://www.goshipexpress.com');
--   select public.definir_reglage('courriel_logo',
--          'https://VOTRE-PROJET.supabase.co/storage/v1/object/public/site/logo-goship.png');
-- Sans 'site_url', les e-mails partent sans bouton. Sans 'courriel_logo', le nom
-- « Goship Express » remplace le logo. Dans les deux cas l'e-mail reste correct.

alter table public.notifications add column if not exists client_id uuid
  references public.clients (id) on delete cascade;
create index if not exists notifications_client_idx on public.notifications (client_id, envoye_le desc);

-- L'adresse de l'entrepôt. Elle est écrite à quatre endroits dans le projet :
-- ici, dans assets/js/notifications.js, dans application-mobile/config.js et sur
-- la page mon-compte.html. Si elle change, il faut la corriger aux quatre.
create or replace function public.adresse_miami()
returns jsonb
language sql
immutable
set search_path = ''
as $fn$
  select jsonb_build_object(
    'ligne1', '8140 NW 74th Ave Unit 3',
    'ligne2', 'APT-46780',
    'ville', 'Medley',
    'etat', 'Florida',
    'zip', '33166',
    'pays', 'United States',
    'telephone', '786 525-2944')
$fn$;

create or replace function public.html_echappe(p_texte text)
returns text
language sql
immutable
set search_path = ''
as $fn$
  select replace(replace(replace(replace(replace(
           coalesce(p_texte, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;')
$fn$;

-- Les textes des deux e-mails, dans les quatre langues. Pour changer une phrase,
-- c'est ici — et seulement ici.
create or replace function public.courriels_compte_textes(p_langue text)
returns jsonb
language sql
immutable
set search_path = ''
as $fn$
  with d(tout) as (
    select jsonb_build_object(
      'fr', jsonb_build_object(
        'salutation',   $t$Bonjour {nom},$t$,
        'b_sujet',      $t$Bienvenue chez Goship Express — votre code client$t$,
        'b_intro',      $t$Votre compte est créé. Voici votre code client : écrivez-le juste après votre nom à chacun de vos achats en ligne.$t$,
        'b_code_titre', $t$VOTRE CODE CLIENT$t$,
        'b_apres',      $t$Gardez-le : c'est lui qui relie chaque colis à votre compte. Vous le retrouverez toujours dans votre espace client.$t$,
        'b_bouton',     $t$OUVRIR MON ESPACE CLIENT$t$,
        'b_suite',      $t$Un second e-mail vous donne votre adresse en Floride, prête à recopier dans les boutiques.$t$,
        'a_sujet',      $t$Votre adresse en Floride — Goship Express$t$,
        'a_intro',      $t$Voici l'adresse à utiliser pour vos achats en ligne (Amazon, SHEIN, Walmart, eBay…). Recopiez-la champ par champ dans le formulaire de livraison de la boutique.$t$,
        'a_note_titre', $t$À ne pas oublier$t$,
        'a_note',       $t$Écrivez toujours votre code client juste après votre nom. C'est ce qui nous permet de reconnaître votre colis dès son arrivée à Miami.$t$,
        'a_bouton',     $t$VOIR MON ADRESSE$t$,
        'pied',         $t$Vous recevez cet e-mail car un compte Goship Express vient d'être créé avec cette adresse.$t$),
      'en', jsonb_build_object(
        'salutation',   $t$Hello {nom},$t$,
        'b_sujet',      $t$Welcome to Goship Express — your customer code$t$,
        'b_intro',      $t$Your account is ready. Here is your customer code: write it right after your name on every online order.$t$,
        'b_code_titre', $t$YOUR CUSTOMER CODE$t$,
        'b_apres',      $t$Keep it: it is what links every package to your account. You will always find it in your customer area.$t$,
        'b_bouton',     $t$OPEN MY CUSTOMER AREA$t$,
        'b_suite',      $t$A second email gives you your Florida address, ready to copy into any store.$t$,
        'a_sujet',      $t$Your Florida address — Goship Express$t$,
        'a_intro',      $t$Here is the address to use for your online purchases (Amazon, SHEIN, Walmart, eBay…). Copy it field by field into the store's delivery form.$t$,
        'a_note_titre', $t$Do not forget$t$,
        'a_note',       $t$Always write your customer code right after your name. That is how we recognise your package the moment it reaches Miami.$t$,
        'a_bouton',     $t$VIEW MY ADDRESS$t$,
        'pied',         $t$You are receiving this email because a Goship Express account has just been created with this address.$t$),
      'es', jsonb_build_object(
        'salutation',   $t$Estimado/a {nom}:$t$,
        'b_sujet',      $t$Bienvenido a Goship Express — su código de cliente$t$,
        'b_intro',      $t$Su cuenta ya está creada. Este es su código de cliente: escríbalo justo después de su nombre en cada compra en línea.$t$,
        'b_code_titre', $t$SU CÓDIGO DE CLIENTE$t$,
        'b_apres',      $t$Consérvelo: es lo que vincula cada paquete con su cuenta. Siempre lo encontrará en su área de clientes.$t$,
        'b_bouton',     $t$ABRIR MI ÁREA DE CLIENTES$t$,
        'b_suite',      $t$Un segundo correo le envía su dirección en Florida, lista para copiar en las tiendas.$t$,
        'a_sujet',      $t$Su dirección en Florida — Goship Express$t$,
        'a_intro',      $t$Esta es la dirección que debe usar para sus compras en línea (Amazon, SHEIN, Walmart, eBay…). Cópiela campo por campo en el formulario de envío de la tienda.$t$,
        'a_note_titre', $t$No lo olvide$t$,
        'a_note',       $t$Escriba siempre su código de cliente justo después de su nombre. Así reconocemos su paquete en cuanto llega a Miami.$t$,
        'a_bouton',     $t$VER MI DIRECCIÓN$t$,
        'pied',         $t$Recibe este correo porque acaba de crearse una cuenta de Goship Express con esta dirección.$t$),
      'ht', jsonb_build_object(
        'salutation',   $t$Bonjou {nom},$t$,
        'b_sujet',      $t$Byenveni nan Goship Express — kòd kliyan ou$t$,
        'b_intro',      $t$Kont ou kreye. Men kòd kliyan ou : ekri l jis apre non ou chak fwa w ap achte sou entènèt.$t$,
        'b_code_titre', $t$KÒD KLIYAN OU$t$,
        'b_apres',      $t$Kenbe l byen : se li ki mare chak koli ak kont ou. W ap toujou jwenn li nan espas kliyan ou.$t$,
        'b_bouton',     $t$OUVRI ESPAS KLIYAN MWEN$t$,
        'b_suite',      $t$Yon dezyèm imèl ap ba ou adrès ou nan Florid, pare pou kopye nan magazen yo.$t$,
        'a_sujet',      $t$Adrès ou nan Florid — Goship Express$t$,
        'a_intro',      $t$Men adrès pou w itilize lè w ap achte sou entènèt (Amazon, SHEIN, Walmart, eBay…). Kopye l liy pa liy nan fòm livrezon magazen an.$t$,
        'a_note_titre', $t$Pa bliye$t$,
        'a_note',       $t$Toujou ekri kòd kliyan ou jis apre non ou. Se konsa nou rekonèt koli ou depi li rive Miami.$t$,
        'a_bouton',     $t$WÈ ADRÈS MWEN$t$,
        'pied',         $t$Ou resevwa imèl sa a paske yon kont Goship Express fèk kreye ak adrès sa a.$t$)))
  select coalesce(d.tout -> coalesce(nullif(p_langue, ''), 'fr'), d.tout -> 'fr') from d
$fn$;

-- La coquille des e-mails : logo, trait bleu, contenu, bouton, pied de page.
-- Mise en page en tableaux, comme assets/js/notifications.js : c'est la seule
-- qui tienne dans toutes les messageries (Gmail, Outlook, Apple Mail…).
create or replace function public.courriel_gabarit(p_langue text, p_sujet text, p_salutation text,
                                                   p_corps text, p_bouton text, p_lien text, p_pied text)
returns text
language plpgsql
stable
set search_path = ''
as $fn$
declare
  v_logo text := public.lire_reglage('courriel_logo');
  v_adresse text := 'Goship Express · 8140 NW 74th Ave, Unit 3, Medley, FL 33166 · WhatsApp +1 849 538-6262';
  v_entete text;
begin
  if coalesce(v_logo, '') <> '' then
    v_entete := '<img src="' || public.html_echappe(v_logo) || '" width="190" alt="Goship Express" ' ||
                'style="display:block;width:190px;max-width:70%;height:auto;border:0">';
  else
    v_entete := '<span style="font-size:24px;font-weight:bold;color:#0d2b6b">Goship Express</span>';
  end if;

  return '<!doctype html><html lang="' || public.html_echappe(p_langue) || '"><head><meta charset="utf-8">' ||
    '<meta name="viewport" content="width=device-width,initial-scale=1"><title>' ||
    public.html_echappe(p_sujet) || '</title></head><body style="margin:0;padding:0;background:#f5f7fb">' ||
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f5f7fb"><tr>' ||
    '<td align="center" style="padding:28px 12px">' ||
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;' ||
    'background:#ffffff;border-radius:18px;font-family:Arial,Helvetica,sans-serif;color:#061a3f">' ||
    '<tr><td align="center" style="padding:32px 24px 26px">' || v_entete || '</td></tr>' ||
    '<tr><td style="padding:0 32px"><div style="height:3px;line-height:3px;font-size:0;background:#0d2b6b">&nbsp;</div></td></tr>' ||
    '<tr><td style="padding:34px 32px 0">' ||
    '<p style="margin:0;font-size:22px;font-weight:bold;font-style:italic;color:#f4600d">' ||
    public.html_echappe(p_salutation) || '</p></td></tr>' ||
    '<tr><td style="padding:14px 32px 0">' || p_corps || '</td></tr>' ||
    case when coalesce(p_lien, '') <> '' then
      '<tr><td align="center" style="padding:28px 32px 36px"><a href="' || public.html_echappe(p_lien) ||
      '" style="display:inline-block;background:#f4600d;color:#ffffff;text-decoration:none;font-weight:bold;' ||
      'font-size:16px;letter-spacing:.02em;padding:16px 34px;border-radius:999px">' ||
      public.html_echappe(p_bouton) || '</a></td></tr>'
    else '<tr><td style="height:30px;line-height:30px;font-size:0">&nbsp;</td></tr>' end ||
    '<tr><td style="padding:0 32px"><div style="height:1px;line-height:1px;font-size:0;background:#e3e8f2">&nbsp;</div></td></tr>' ||
    '<tr><td align="center" style="padding:20px 32px 28px;font-size:12.5px;line-height:1.6;color:#5b6782">' ||
    public.html_echappe(v_adresse) || '<br>' || public.html_echappe(p_pied) || '</td></tr>' ||
    '</table></td></tr></table></body></html>';
end;
$fn$;

-- Envoi d'un e-mail à un client (et non au client d'un colis, comme
-- envoyer_email_client). Le destinataire est lu dans la base : le site ne peut
-- pas choisir à qui la base écrit.
create or replace function public.envoyer_courriel_client(p_client uuid, p_evenement text, p_sujet text,
                                                          p_html text, p_texte text)
returns text
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_email text;
  v_nom text;
  v_cle text := public.lire_reglage('email_cle_api');
  v_fournisseur text := coalesce(nullif(public.lire_reglage('email_fournisseur'), ''), 'brevo');
  v_expediteur text := public.lire_reglage('email_expediteur');
  v_nom_expediteur text := coalesce(nullif(public.lire_reglage('email_nom'), ''), 'Goship Express');
  v_requete bigint;
begin
  if coalesce(v_cle, '') = '' or coalesce(v_expediteur, '') = '' then
    return 'non-configure';
  end if;
  select email, nom_complet into v_email, v_nom from public.clients where id = p_client;
  if coalesce(v_email, '') = '' then
    return 'sans-destinataire';
  end if;

  if v_fournisseur = 'resend' then
    select net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object('Authorization', 'Bearer ' || v_cle, 'Content-Type', 'application/json'),
      body := jsonb_build_object('from', v_nom_expediteur || ' <' || v_expediteur || '>',
                                 'to', jsonb_build_array(v_email),
                                 'subject', p_sujet, 'html', p_html, 'text', p_texte)
    ) into v_requete;
  else
    select net.http_post(
      url := 'https://api.brevo.com/v3/smtp/email',
      headers := jsonb_build_object('api-key', v_cle, 'Content-Type', 'application/json', 'Accept', 'application/json'),
      body := jsonb_build_object('sender', jsonb_build_object('name', v_nom_expediteur, 'email', v_expediteur),
                                 'to', jsonb_build_array(jsonb_build_object('email', v_email, 'name', coalesce(v_nom, ''))),
                                 'subject', p_sujet, 'htmlContent', p_html, 'textContent', p_texte)
    ) into v_requete;
  end if;

  insert into public.notifications (client_id, canal, evenement, destinataire, requete)
  values (p_client, 'email', p_evenement, v_email, v_requete);
  return 'envoye';
end;
$fn$;

-- Les deux e-mails de bienvenue. Renvoie ce qui a été fait, pour le voir dans
-- le SQL Editor : « envoye », « deja-envoye », « non-configure »…
create or replace function public.courriels_bienvenue(p_client uuid, p_forcer boolean default false)
returns text
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  c record;
  t jsonb;
  a jsonb := public.adresse_miami();
  v_site text := public.lire_reglage('site_url');
  v_lien text := '';
  v_nom text;
  v_nom_adresse text;
  v_corps text;
  v_texte text;
  v_lignes jsonb;
  v_ligne jsonb;
  v_resultat text;
begin
  select * into c from public.clients where id = p_client;
  if not found or coalesce(c.email, '') = '' then
    return 'sans-destinataire';
  end if;
  -- Les comptes de l'équipe n'ont pas de code client : definir_admin le met à
  -- null. Leur écrire « voici votre code client » suivi de rien n'aurait aucun
  -- sens, et l'adresse de Miami sans code ne servirait à identifier personne.
  if coalesce(c.code, '') = '' then
    return 'sans-code';
  end if;
  if not p_forcer and exists (select 1 from public.notifications
                              where client_id = p_client and evenement = 'bienvenue') then
    return 'deja-envoye';
  end if;

  t := public.courriels_compte_textes(c.langue);
  v_nom := coalesce(nullif(trim(c.nom_complet), ''), c.code);
  v_nom_adresse := trim(coalesce(nullif(trim(c.nom_complet), ''), '') || ' ' || coalesce(c.code, ''));
  if coalesce(v_site, '') <> '' then
    v_lien := rtrim(v_site, '/') || '/' ||
              case when coalesce(c.langue, 'fr') = 'fr' then '' else c.langue || '/' end ||
              'mon-compte.html';
  end if;

  -- 1. Bienvenue : le code client, en grand
  v_corps :=
    '<p style="margin:0;font-size:17px;line-height:1.55">' || public.html_echappe(t ->> 'b_intro') || '</p>' ||
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:22px 0 0">' ||
    '<tr><td align="center" style="background:#f5f7fb;border-radius:14px;padding:20px 16px">' ||
    '<div style="font-size:11px;letter-spacing:.18em;color:#5b6782">' ||
    public.html_echappe(t ->> 'b_code_titre') || '</div>' ||
    '<div style="margin-top:8px;font-family:''Courier New'',Courier,monospace;font-size:27px;' ||
    'font-weight:bold;letter-spacing:.04em;color:#0d2b6b">' || public.html_echappe(c.code) || '</div>' ||
    '</td></tr></table>' ||
    '<p style="margin:20px 0 0;font-size:16px;line-height:1.55">' || public.html_echappe(t ->> 'b_apres') || '</p>' ||
    '<p style="margin:14px 0 0;font-size:15px;line-height:1.55;color:#5b6782">' ||
    public.html_echappe(t ->> 'b_suite') || '</p>';

  v_texte := replace(t ->> 'salutation', '{nom}', v_nom) || E'\n\n' || (t ->> 'b_intro') || E'\n\n' ||
             (t ->> 'b_code_titre') || ' : ' || c.code || E'\n\n' || (t ->> 'b_apres') || E'\n\n' ||
             (t ->> 'b_suite') || case when v_lien <> '' then E'\n\n' || (t ->> 'b_bouton') || ' : ' || v_lien else '' end;

  v_resultat := public.envoyer_courriel_client(
    p_client, 'bienvenue', t ->> 'b_sujet',
    public.courriel_gabarit(coalesce(c.langue, 'fr'), t ->> 'b_sujet',
                            replace(t ->> 'salutation', '{nom}', v_nom),
                            v_corps, t ->> 'b_bouton', v_lien, t ->> 'pied'),
    v_texte);
  if v_resultat <> 'envoye' then
    return v_resultat;
  end if;

  -- 2. L'adresse en Floride, champ par champ comme le formulaire d'une boutique
  v_lignes := jsonb_build_array(
    jsonb_build_array('Full Name',      v_nom_adresse),
    jsonb_build_array('Address line 1', a ->> 'ligne1'),
    jsonb_build_array('Address line 2', a ->> 'ligne2'),
    jsonb_build_array('City',           a ->> 'ville'),
    jsonb_build_array('State',          a ->> 'etat'),
    jsonb_build_array('Zip Code',       a ->> 'zip'),
    jsonb_build_array('Country',        a ->> 'pays'),
    jsonb_build_array('Phone',          a ->> 'telephone'));

  v_corps := '<p style="margin:0;font-size:17px;line-height:1.55">' ||
             public.html_echappe(t ->> 'a_intro') || '</p>' ||
             '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" ' ||
             'style="margin:22px 0 0;background:#f5f7fb;border-radius:14px">';
  for v_ligne in select * from jsonb_array_elements(v_lignes) loop
    v_corps := v_corps ||
      '<tr><td style="padding:9px 18px;font-size:14px;color:#5b6782;white-space:nowrap;vertical-align:top" ' ||
      'translate="no">' || public.html_echappe(v_ligne ->> 0) || '</td>' ||
      '<td style="padding:9px 18px 9px 0;font-size:15px;font-weight:bold;color:#061a3f;vertical-align:top" ' ||
      'translate="no">' || public.html_echappe(v_ligne ->> 1) || '</td></tr>';
  end loop;
  v_corps := v_corps || '</table>' ||
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:20px 0 0">' ||
    '<tr><td style="border-left:4px solid #f4600d;padding:2px 0 2px 16px">' ||
    '<div style="font-size:13px;font-weight:bold;letter-spacing:.06em;color:#f4600d">' ||
    public.html_echappe(t ->> 'a_note_titre') || '</div>' ||
    '<p style="margin:6px 0 0;font-size:15.5px;line-height:1.55">' ||
    public.html_echappe(t ->> 'a_note') || '</p></td></tr></table>';

  v_texte := replace(t ->> 'salutation', '{nom}', v_nom) || E'\n\n' || (t ->> 'a_intro') || E'\n';
  for v_ligne in select * from jsonb_array_elements(v_lignes) loop
    v_texte := v_texte || E'\n' || (v_ligne ->> 0) || ': ' || (v_ligne ->> 1);
  end loop;
  v_texte := v_texte || E'\n\n' || (t ->> 'a_note_titre') || ' — ' || (t ->> 'a_note') ||
             case when v_lien <> '' then E'\n\n' || (t ->> 'a_bouton') || ' : ' || v_lien else '' end;

  return public.envoyer_courriel_client(
    p_client, 'adresse_miami', t ->> 'a_sujet',
    public.courriel_gabarit(coalesce(c.langue, 'fr'), t ->> 'a_sujet',
                            replace(t ->> 'salutation', '{nom}', v_nom),
                            v_corps, t ->> 'a_bouton', v_lien, t ->> 'pied'),
    v_texte);
end;
$fn$;

-- Le déclencheur. Un e-mail qui ne part pas ne doit jamais empêcher la création
-- d'un compte : l'échec est avalé et noté dans les journaux de Supabase.
create or replace function public.declencher_courriels_bienvenue()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  -- Sur auth.users, on n'agit qu'au moment où l'adresse vient d'être confirmée.
  if tg_table_name = 'users' then
    if new.email_confirmed_at is null or old.email_confirmed_at is not null then
      return new;
    end if;
  else
    -- Compte créé sans confirmation d'adresse : on écrit tout de suite.
    if not exists (select 1 from auth.users u where u.id = new.id and u.email_confirmed_at is not null) then
      return new;
    end if;
  end if;

  begin
    perform public.courriels_bienvenue(new.id);
  exception when others then
    raise warning 'Courriels de bienvenue non envoyés pour % : %', new.id, sqlerrm;
  end;
  return new;
end;
$fn$;

drop trigger if exists courriels_bienvenue_client on public.clients;
create trigger courriels_bienvenue_client
  after insert on public.clients
  for each row execute function public.declencher_courriels_bienvenue();

drop trigger if exists courriels_bienvenue_confirmation on auth.users;
create trigger courriels_bienvenue_confirmation
  after update of email_confirmed_at on auth.users
  for each row execute function public.declencher_courriels_bienvenue();

-- Renvoyer les deux e-mails à un client, depuis le tableau de bord ou le SQL
-- Editor : select public.renvoyer_courriels_bienvenue('GSE-4323');
create or replace function public.renvoyer_courriels_bienvenue(p_code text)
returns text
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id uuid;
begin
  -- Par le site, seul un administrateur passe. Dans le SQL Editor de Supabase,
  -- il n'y a pas de client connecté : c'est déjà un accès direct à la base, et
  -- exiger un administrateur y interdirait justement le seul endroit d'où on
  -- peut renvoyer les e-mails à la main.
  if not public.est_admin()
     and (session_user in ('anon', 'authenticated', 'authenticator')
          or coalesce(current_setting('request.jwt.claims', true), '') <> '') then
    raise exception 'Accès réservé aux administrateurs' using errcode = '42501';
  end if;
  select id into v_id from public.clients where upper(trim(code)) = upper(trim(p_code));
  if v_id is null then
    raise exception 'Aucun client avec le code %', p_code;
  end if;
  return public.courriels_bienvenue(v_id, true);
end;
$fn$;

-- Ces fonctions écrivent aux clients : le site n'y touche pas. Seuls le
-- déclencheur (qui s'exécute avec les droits de son propriétaire) et les
-- administrateurs, par renvoyer_courriels_bienvenue, peuvent les appeler.
revoke execute on function public.envoyer_courriel_client(uuid, text, text, text, text)
  from public, anon, authenticated;
revoke execute on function public.courriels_bienvenue(uuid, boolean) from public, anon, authenticated;
revoke execute on function public.declencher_courriels_bienvenue() from public, anon, authenticated;
revoke execute on function public.courriel_gabarit(text, text, text, text, text, text, text)
  from public, anon;
revoke execute on function public.renvoyer_courriels_bienvenue(text) from public, anon;
grant execute on function public.renvoyer_courriels_bienvenue(text) to authenticated;
