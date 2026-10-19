-- =============================================================================
-- Goship Express — les icônes des réseaux sociaux dans le pied des e-mails (19/10/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Il AJOUTE une petite
-- fonction et REMPLACE la coquille des e-mails (courriel_gabarit). Il ne change
-- aucune donnée, aucun envoi déjà fait, et peut être relancé autant de fois qu'on veut.
--
-- Ordre d'installation : le dernier de la chaîne (outils/migrations.txt), après
-- supabase-lieu-reception.sql. Ne pas relancer supabase.sql, supabase-bienvenue.sql ni
-- supabase-courriel-pied.sql après lui : ils remettraient le pied sans les icônes.
--
-- Le pied de TOUS les e-mails envoyés par la base (colis reçu ou disponible, bienvenue,
-- anniversaire…) porte maintenant, entre les boutons Google Play / App Store et la phrase
-- « Vous recevez ce message car… », une ligne « Suivez-nous » avec quatre icônes rondes
-- cliquables : Facebook, Instagram, TikTok et WhatsApp (les mêmes comptes que le pied du site).
--
-- Les icônes sont quatre petites images du site (assets/img/email/*.png). Leur adresse de base
-- est le réglage courriel_icones_url (en https), à défaut site_url ; ce fichier pose
-- courriel_icones_url une fois, s'il n'existe pas, à l'adresse où le site est publié
-- (https://wilnergraph92.github.io/Goship-express-site/) : site_url, lui, est vide tant que le
-- domaine n'est pas basculé, et le bouton « Ouvrir mon espace » en dépend. Après la bascule :
--     select public.definir_reglage('courriel_icones_url', 'https://goshipexpress.net/');
-- Sans aucune adresse https, les quatre noms s'écrivent en liens de texte, jamais un trou.
-- Le numéro WhatsApp n'est écrit nulle part : seul le lien y mène.
--
-- Contenu :
--    1. garde : la chaîne est-elle à jour ?
--    2. la ligne des réseaux
--    3. la coquille des e-mails (REMPLACE celle de supabase-courriel-pied.sql)
--    4. droits
--    5. contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regprocedure('public.courriel_gabarit(text, text, text, text, text, text, text)') is null
     or to_regprocedure('public.courriel_boutiques(text)') is null
     or to_regprocedure('public.html_echappe(text)') is null
     or to_regprocedure('public.lire_reglage(text)') is null
     or to_regprocedure('public.langue_notification(text)') is null
     or to_regprocedure('public.definir_reglage(text, text)') is null then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt), puis ce fichier.';
  end if;
end;
$garde$;


-- 2. La ligne des réseaux ---------------------------------------------------------------------
create or replace function public.courriel_reseaux_textes()
returns jsonb
language sql
immutable
set search_path = ''
as $cat$
  select $json$
{
  "fr": {"titre": "Suivez-nous"},
  "en": {"titre": "Follow us"},
  "es": {"titre": "Síganos"},
  "ht": {"titre": "Swiv nou"}
}
$json$::jsonb
$cat$;

-- Une ligne de tableau (<tr>…</tr>) pour le pied des e-mails : titre, puis les icônes.
create or replace function public.courriel_reseaux(p_langue text)
returns text
language plpgsql
stable
set search_path = ''
as $fn$
declare
  v_t jsonb := public.courriel_reseaux_textes() -> public.langue_notification(p_langue);
  v_icones text := trim(coalesce(public.lire_reglage('courriel_icones_url'), ''));
  v_site text := coalesce(public.lire_reglage('site_url'), '');
  v_base text;
  -- nom, fichier de l'icône, adresse du compte (les mêmes que le pied du site)
  v_reseaux text[][] := array[
    ['Facebook',  'facebook',  'https://www.facebook.com/goshipexpress'],
    ['Instagram', 'instagram', 'https://www.instagram.com/goshipexpressllc'],
    ['TikTok',    'tiktok',    'https://www.tiktok.com/@goshipexpress.net'],
    ['WhatsApp',  'whatsapp',  'https://wa.me/18495386262']];
  v_images text := '';
  i integer;
begin
  -- Les icônes sont des images du site : seulement à une adresse https sûre. Le réglage
  -- courriel_icones_url passe avant site_url ; l'un ou l'autre illisible, on prend l'autre.
  v_base := case when v_icones ~ '^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~/-]*)?$'
                 then regexp_replace(v_icones, '/?$', '/') || 'assets/img/email/'
                 when v_site ~ '^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~/-]*)?$'
                 then regexp_replace(v_site, '/?$', '/') || 'assets/img/email/' else '' end;
  for i in 1 .. array_length(v_reseaux, 1) loop
    if v_base <> '' then
      v_images := v_images || '<td style="padding:0 5px"><a href="' || public.html_echappe(v_reseaux[i][3]) ||
        '" style="text-decoration:none"><img src="' || public.html_echappe(v_base || v_reseaux[i][2] || '.png') ||
        '" width="36" height="36" alt="' || public.html_echappe(v_reseaux[i][1]) ||
        '" style="display:block;width:36px;height:36px;border:0;border-radius:18px;background:#0d2b6b;' ||
        'color:#ffffff;font-size:11px;text-align:center"></a></td>';
    else
      v_images := v_images || '<td style="padding:0 7px"><a href="' || public.html_echappe(v_reseaux[i][3]) ||
        '" style="color:#0d2b6b;font-size:13px;font-weight:bold;text-decoration:underline;' ||
        'font-family:Arial,Helvetica,sans-serif">' || public.html_echappe(v_reseaux[i][1]) || '</a></td>';
    end if;
  end loop;
  return '<tr><td align="center" style="padding:10px 32px 4px;font-size:14px;font-weight:bold;color:#061a3f">' ||
         public.html_echappe(v_t ->> 'titre') || '</td></tr>' ||
         '<tr><td align="center" style="padding:6px 32px 18px"><table role="presentation" cellpadding="0" cellspacing="0" align="center">' ||
         '<tr>' || v_images || '</tr></table></td></tr>';
end;
$fn$;

-- L'adresse de base des icônes, posée une fois (jamais écrasée : le propriétaire peut la changer)
do $reglage$
begin
  if public.lire_reglage('courriel_icones_url') is null then
    perform public.definir_reglage('courriel_icones_url', 'https://wilnergraph92.github.io/Goship-express-site/');
  end if;
end;
$reglage$;


-- 3. La coquille des e-mails ----------------------------------------------------------------------
-- La même que supabase-courriel-pied.sql, avec la ligne des réseaux sous les boutiques.
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
    public.courriel_reseaux(p_langue) ||
    '<tr><td align="center" style="padding:6px 32px 28px;font-size:12.5px;line-height:1.6;color:#5b6782">' ||
    public.html_echappe(p_pied) || '</td></tr>' ||
    '</table></td></tr></table></body></html>';
end;
$fn$;


-- 4. Droits ----------------------------------------------------------------------------------------
revoke execute on function public.courriel_reseaux_textes() from public, anon, authenticated;
revoke execute on function public.courriel_reseaux(text) from public, anon, authenticated;
revoke execute on function public.courriel_gabarit(text, text, text, text, text, text, text) from public, anon, authenticated;


-- 5. Contrôle -------------------------------------------------------------------------------------
-- fonctions : 2 ; ouvertes_aux_visiteurs : false ; gabarit_avec_reseaux : true.
select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname in ('courriel_reseaux_textes', 'courriel_reseaux')) as fonctions,
       (select coalesce(bool_or(has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute')), false)
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname in ('courriel_reseaux_textes', 'courriel_reseaux', 'courriel_gabarit')) as ouvertes_aux_visiteurs,
       position('courriel_reseaux' in pg_get_functiondef('public.courriel_gabarit(text, text, text, text, text, text, text)'::regprocedure)) > 0 as gabarit_avec_reseaux;
