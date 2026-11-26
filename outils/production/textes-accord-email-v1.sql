-- =============================================================================
-- Goship Express — textes d'accord des offres par e-mail, version 1 (4 langues)
--
-- À LANCER UNE SEULE FOIS, au moment de la mise en production du Centre de
-- communication (candidates 001 à 012 déjà appliquées), dans Supabase > SQL Editor
-- ou avec psql. Rejouable : un texte déjà enregistré n'est ni modifié ni doublé.
--
-- Décision : la CEO de GoShip Express, le 26/11/2026, valide ces textes (« mon GO
-- vaut validation des textes d'accord e-mail »), sur l'avis juridique PRÉLIMINAIRE
-- du 25/11/2026. Cet avis a été rédigé avec une IA et n'est pas signé par un avocat :
-- la référence d'attestation le dit, pour que la preuve ne prétende pas plus.
--
-- Effet : le site propose aussitôt, dans « Mon compte », d'accepter les offres par
-- e-mail dans ces quatre langues. Rien ne part tant qu'aucune campagne n'est
-- approuvée et planifiée, et sans adresse postale réglée (courriel_adresse_postale).
--
-- Un texte attesté ne peut plus être modifié ni supprimé (déclencheur de la 003) :
-- une correction se fait par une nouvelle version (email-…-v2).
--
-- La phrase facultative « [Au plus [N] messages par mois.] » du projet du 24/11/2026
-- n'est PAS reprise : la fréquence est un réglage de l'Admin, qui peut changer.
-- =============================================================================
begin;

do $verif$
begin
  if to_regclass('public.communication_consentement_textes') is null then
    raise exception 'Le Centre de communication n''est pas installé (candidates 001 à 012) : rien n''est enregistré.';
  end if;
  if not exists (select 1 from pg_catalog.pg_constraint
                  where conname = 'communication_consentement_textes_canal_check'
                    and pg_catalog.pg_get_constraintdef(oid) like '%email%') then
    raise exception 'La candidate 012 (consentement e-mail) n''est pas appliquée : rien n''est enregistré.';
  end if;
end
$verif$;

insert into public.communication_consentement_textes
  (version, canal, langue, texte, empreinte, statut, atteste_le, reference_attestation)
select t.version, 'email', t.langue, t.texte,
       encode(extensions.digest(t.texte, 'sha256'), 'hex'),
       'atteste_juridique', clock_timestamp(),
       'Décision de la CEO du 26/11/2026 sur avis juridique préliminaire du 25/11/2026 (analyse assistée par IA, non signée par un avocat)'
  from (values
    ('email-2026-11-v1', 'fr',
     'J''accepte de recevoir par e-mail les offres, promotions et nouveautés de GoShip Express, à l''adresse e-mail de mon compte. Cet accord est facultatif : il n''a aucun effet sur l''envoi de mes colis ni sur les messages qui les concernent. Je peux le retirer à tout moment, gratuitement, depuis mon compte ou avec le lien de désinscription présent dans chaque e-mail. Mes données sont traitées selon la politique de confidentialité de GoShip Express.'),
    ('email-2026-11-v1', 'en',
     'I agree to receive offers, promotions and news from GoShip Express by email, at the email address of my account. This consent is optional: it has no effect on the shipping of my packages or on the messages about them. I can withdraw it at any time, free of charge, from my account or with the unsubscribe link included in every email. My data is processed in accordance with the GoShip Express privacy policy.'),
    ('email-2026-11-v1', 'es',
     'Acepto recibir por correo electrónico las ofertas, promociones y novedades de GoShip Express, en el correo de mi cuenta. Este consentimiento es opcional: no afecta el envío de mis paquetes ni los mensajes sobre ellos. Puedo retirarlo en cualquier momento, sin costo, desde mi cuenta o con el enlace para darse de baja incluido en cada correo. Mis datos se tratan según la política de privacidad de GoShip Express.'),
    ('email-2026-11-v1', 'ht',
     'Mwen dakò resevwa pa imèl òf, pwomosyon ak nouvèl GoShip Express, nan adrès imèl kont mwen an. Konsantman sa a pa obligatwa: li pa chanje anyen nan voye koli mwen yo ni nan mesaj ki gen rapò ak yo. Mwen ka retire l nenpòt ki lè, gratis, nan kont mwen oswa ak lyen pou dezabone ki nan chak imèl. Done mwen yo trete dapre politik konfidansyalite GoShip Express.')
  ) as t(version, langue, texte)
on conflict (version, canal, langue) do nothing;

-- Contrôle : les quatre langues sont proposées par le site.
select l.langue,
       (public.communication_consentement_texte_actuel('email', l.langue) ->> 'version') as version_proposee
  from (values ('fr'), ('en'), ('es'), ('ht')) as l(langue);

commit;
