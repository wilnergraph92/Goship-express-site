-- =============================================================================
-- Goship Express — le pied des e-mails : les boutiques d'applications ; plus d'e-mail de facture (19/10/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Il REMPLACE la coquille
-- des e-mails (courriel_gabarit), AJOUTE deux petites fonctions, COUPE le canal
-- e-mail de trois règles et peut être relancé autant de fois qu'on veut.
--
-- Ordre d'installation : le dernier de la chaîne (outils/migrations.txt), après
-- supabase-courriel-colis.sql. Ne pas relancer supabase.sql ni supabase-bienvenue.sql
-- après lui : ils remettraient l'ancien pied de page.
--
-- 1. Le pied de page de TOUS les e-mails envoyés par la base (colis reçu ou disponible,
--    facture, bienvenue…) : l'adresse de Medley et le numéro WhatsApp disparaissent ;
--    à leur place, deux boutons cliquables, Google Play et App Store, puis la phrase
--    « Vous recevez ce message car… ». Les adresses des boutiques sont deux réglages
--    (comme email_cle_api, dans le coffre de Supabase) :
--        store_android_url   la fiche Google Play ; ce fichier la pose, une fois,
--                            si elle n'existe pas (com.goshipexpress.app)
--        store_ios_url       la fiche App Store ; AUCUNE n'existe tant que le compte
--                            Apple Developer n'est pas ouvert : le bouton dit alors
--                            « Bientôt sur App Store », sans lien
--    Un réglage vide, absent ou qui n'est pas une adresse https affiche « Bientôt sur » :
--    pour retirer le lien Google Play,  select public.definir_reglage('store_android_url', '-');
--    pour poser celui de l'App Store,   select public.definir_reglage('store_ios_url', 'https://apps.apple.com/app/id…');
--
-- 2. Plus d'e-mail de facturation : « Nouvelle facture » (invoice_created), « Paiement
--    enregistré » (payment_received) et « Facture en retard » (invoice_overdue) n'ont plus
--    le canal e-mail. Le téléphone et l'espace client gardent leur message. Un e-mail de
--    ces trois types qui attendait encore son envoi est annulé (« REGLE_COUPEE »). Pour en
--    rallumer un : tableau de bord > Notifications, case « E-mail » de la règle.
--    Ni « Colis reçu », ni « Colis disponible », ni « Action requise » ne changent.
--
-- Contenu :
--    1. garde : la chaîne est-elle à jour ?
--    2. les boutons des boutiques
--    3. la coquille des e-mails (REMPLACE celle de supabase.sql)
--    4. plus d'e-mail de facturation
--    5. droits
--    6. contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regprocedure('public.courriel_gabarit(text, text, text, text, text, text, text)') is null
     or to_regprocedure('public.courriel_colis(text, text, uuid, text)') is null
     or to_regprocedure('public.html_echappe(text)') is null
     or to_regprocedure('public.lire_reglage(text)') is null
     or to_regprocedure('public.definir_reglage(text, text)') is null
     or to_regclass('public.notification_regles') is null then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt), puis ce fichier.';
  end if;
end;
$garde$;


-- 2. Les boutons des boutiques ----------------------------------------------------------------
create or replace function public.courriel_boutiques_textes()
returns jsonb
language sql
immutable
set search_path = ''
as $cat$
  select $json$
{
  "fr": {
    "titre": "Téléchargez l'application Goship Express",
    "dispo": "Disponible sur",
    "bientot": "Bientôt sur"
  },
  "en": {
    "titre": "Get the Goship Express app",
    "dispo": "Available on",
    "bientot": "Coming soon on"
  },
  "es": {
    "titre": "Descargue la app de Goship Express",
    "dispo": "Disponible en",
    "bientot": "Próximamente en"
  },
  "ht": {
    "titre": "Telechaje aplikasyon Goship Express la",
    "dispo": "Disponib sou",
    "bientot": "Byento sou"
  }
}
$json$::jsonb
$cat$;

-- Deux lignes de tableau (<tr>…</tr>) pour le pied des e-mails. En tableaux et en styles
-- en ligne, comme le reste de la coquille : ni image, ni SVG (Gmail les retire).
-- Une adresse n'est un lien que si c'est une adresse https sans espace ni guillemet.
create or replace function public.courriel_boutiques(p_langue text)
returns text
language plpgsql
stable
set search_path = ''
as $fn$
declare
  v_t jsonb := public.courriel_boutiques_textes() -> public.langue_notification(p_langue);
  v_boutiques text[][] := array[['Google Play', coalesce(public.lire_reglage('store_android_url'), '')],
                                ['App Store',   coalesce(public.lire_reglage('store_ios_url'), '')]];
  v_boutons text := '';
  v_url text;
  i integer;
begin
  for i in 1 .. 2 loop
    v_url := trim(v_boutiques[i][2]);
    if v_url ~ '^https://[^\s"''<>]+$' then
      v_boutons := v_boutons || '<td style="padding:4px"><a href="' || public.html_echappe(v_url) ||
        '" style="display:inline-block;background:#061a3f;color:#ffffff;text-decoration:none;border-radius:10px;' ||
        'padding:9px 20px;text-align:left;font-family:Arial,Helvetica,sans-serif"><span style="font-size:10.5px;line-height:1.3">' ||
        public.html_echappe(v_t ->> 'dispo') || '</span><br><span style="font-size:17px;font-weight:bold;line-height:1.3">' ||
        public.html_echappe(v_boutiques[i][1]) || '</span></a></td>';
    else
      v_boutons := v_boutons || '<td style="padding:4px"><span style="display:inline-block;background:#e3e8f2;color:#5b6782;' ||
        'border-radius:10px;padding:9px 20px;text-align:left;font-family:Arial,Helvetica,sans-serif">' ||
        '<span style="font-size:10.5px;line-height:1.3">' || public.html_echappe(v_t ->> 'bientot') ||
        '</span><br><span style="font-size:17px;font-weight:bold;line-height:1.3">' ||
        public.html_echappe(v_boutiques[i][1]) || '</span></span></td>';
    end if;
  end loop;
  return '<tr><td align="center" style="padding:22px 32px 4px;font-size:14px;font-weight:bold;color:#061a3f">' ||
         public.html_echappe(v_t ->> 'titre') || '</td></tr>' ||
         '<tr><td align="center" style="padding:6px 32px 14px"><table role="presentation" cellpadding="0" cellspacing="0" align="center">' ||
         '<tr>' || v_boutons || '</tr></table></td></tr>';
end;
$fn$;

-- Le lien Google Play, posé une fois (jamais écrasé : le propriétaire peut le changer ou le retirer)
do $reglage$
begin
  if public.lire_reglage('store_android_url') is null then
    perform public.definir_reglage('store_android_url', 'https://play.google.com/store/apps/details?id=com.goshipexpress.app');
  end if;
end;
$reglage$;


-- 3. La coquille des e-mails : celle de supabase.sql, sans adresse ni téléphone, avec les boutiques --
create or replace function public.courriel_gabarit(p_langue text, p_sujet text, p_salutation text,
                                                   p_corps text, p_bouton text, p_lien text, p_pied text)
returns text
language plpgsql
stable
set search_path = ''
as $fn$
declare
  v_logo text := public.lire_reglage('courriel_logo');
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
    public.courriel_boutiques(p_langue) ||
    '<tr><td align="center" style="padding:6px 32px 28px;font-size:12.5px;line-height:1.6;color:#5b6782">' ||
    public.html_echappe(p_pied) || '</td></tr>' ||
    '</table></td></tr></table></body></html>';
end;
$fn$;


-- 4. Plus d'e-mail de facturation -------------------------------------------------------------
-- Les règles qui avaient le canal e-mail : facture créée, paiement enregistré, facture en retard.
update public.notification_regles
   set canaux = array_remove(canaux, 'email'), maj_le = now()
 where type in ('invoice_created', 'payment_received', 'invoice_overdue')
   and 'email' = any(canaux);

-- Un e-mail de ces types qui attendait encore son envoi ne part pas
update public.notification_envois e
   set statut = 'annule', code_erreur = 'REGLE_COUPEE', erreur = '', maj_le = now()
  from public.notifications n
 where n.id = e.notification_id
   and e.canal = 'email' and e.statut = 'attente'
   and n.type in ('invoice_created', 'payment_received', 'invoice_overdue');


-- 5. Droits ----------------------------------------------------------------------------------------
revoke execute on function public.courriel_boutiques_textes() from public, anon, authenticated;
revoke execute on function public.courriel_boutiques(text) from public, anon, authenticated;
revoke execute on function public.courriel_gabarit(text, text, text, text, text, text, text) from public, anon, authenticated;


-- 6. Contrôle -------------------------------------------------------------------------------------
-- fonctions : 2 ; ouvertes_aux_visiteurs : false ; gabarit_sans_adresse : true ; factures_sans_email : true.
select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname in ('courriel_boutiques_textes', 'courriel_boutiques')) as fonctions,
       (select coalesce(bool_or(has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute')), false)
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname in ('courriel_boutiques_textes', 'courriel_boutiques', 'courriel_gabarit')) as ouvertes_aux_visiteurs,
       position('8140 NW' in pg_get_functiondef('public.courriel_gabarit(text, text, text, text, text, text, text)'::regprocedure)) = 0 as gabarit_sans_adresse,
       not exists (select 1 from public.notification_regles
                    where type in ('invoice_created', 'payment_received', 'invoice_overdue') and 'email' = any(canaux)) as factures_sans_email;
