-- =============================================================================
-- Goship Express — GOship APP Welcome et GOship Refer : l'offre de bienvenue et le
-- parrainage (19/10/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce fichier
-- AJOUTE des tables, des fonctions et trois déclencheurs « en lecture » (compte créé,
-- colis reçu, facture payée ou annulée). Il ne change ni un colis, ni une facture, ni un
-- paiement, ne modifie aucune règle de facturation, et peut être relancé autant de fois
-- qu'on veut (les campagnes déjà réglées par l'équipe sont gardées).
--
-- Ordre d'installation : après supabase-anniversaires.sql (voir outils/migrations.txt).
--
-- AUCUNE valeur commerciale n'est inventée ici : ni montant de bonus, ni récompense du
-- parrain ou du filleul, ni date. La campagne de bienvenue et le parrainage naissent en
-- BROUILLON, vides ; un administrateur (programs.manage) les remplit et les publie. Une
-- campagne incomplète ne se publie pas.
--
-- Comment ça marche — des faits que la base a vus, jamais un clic de page :
--   · « Opération qualifiante » : un colis reçu à l'entrepôt de Miami (COLIS_RECU), ou une
--     facture payée (FACTURE_PAYEE), au choix de la campagne. Un déclencheur sur colis_historique
--     et un autre sur evenements_facturation notent le fait ; le téléchargement de l'application
--     n'en est PAS un (aucune attribution fiable : voir docs/programmes.md).
--   · Un client ne reçoit le bonus de bienvenue QU'UNE FOIS : un index unique sur les avantages.
--     Les opérations rejouées, les requêtes simultanées, les travailleurs doublés : la clé unique
--     de chaque avantage (« welcome:<campagne>:<client> », « refer:<parrainage>:parrain »…) fait
--     qu'un seul est créé.
--   · Un avantage peut passer par un DÉLAI DE VALIDATION (réglable, 0 = immédiat). En attente, il
--     n'est pas acquis ; si l'opération est annulée ou remboursée avant la fin du délai, il est
--     annulé, jamais accordé. Le client est prévenu à chaque changement, et rien n'est présenté
--     comme acquis avant la confirmation.
--   · Les avantages autres que des points (crédit d'expédition, réduction sur les frais de service,
--     bonus fixe, avantage sur un prochain colis) sont ENREGISTRÉS dans la table « recompenses » :
--     l'équipe les applique à la facture à la main. Aucune règle de facturation n'est modifiée.
--     Les GOPOINTS, eux, sont écrits dans le registre (supabase-fidelite.sql).
--   · Parrainage : un code par client (créé à la première demande), rattaché au compte à
--     l'inscription (« code_parrainage » dans le formulaire) ou saisi ensuite. Jamais soi-même ; pas de
--     cycle (A parraine B, B parraine A) ; un parrain par filleul. Les indices d'abus (même
--     téléphone, même adresse, rafale d'inscriptions) mettent le parrainage « suspect » : il attend
--     l'examen d'un administrateur, rien n'est bloqué ni accordé automatiquement.
--   · Le parrain ne voit que des chiffres et ses propres avantages : jamais l'identité d'un
--     filleul, ni ses opérations.
--   · Une erreur dans ces calculs ne bloque JAMAIS l'opération qui les a causés (la réception d'un
--     colis, un paiement) : elle est journalisée (programmes_erreurs) et visible de l'équipe.
--
-- Permissions : programs.view (lire), programs.manage (créer, publier, suspendre, examiner),
-- points.adjust (accorder ou annuler un avantage à la main, motif obligatoire, journalisé).
--
-- Contenu :
--    1. garde
--    2. tables
--    3. petites aides : textes des avantages, statuts des campagnes
--    4. avantages : créer, valider, annuler (interne)
--    5. le moteur : une opération qualifiante, un compte créé
--    6. les déclencheurs
--    7. le parrainage : code, rattachement, examen
--    8. le client : sa bienvenue, son parrainage
--    9. l'équipe : campagnes, parrainage, avantages, erreurs
--   10. le travail du jour, droits, contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regprocedure('public.points_ecrire(uuid, text, integer, text, text, text, text, uuid, date, bigint, uuid)') is null
     or to_regprocedure('public.points_attribuer(uuid, text, text, integer)') is null
     or to_regprocedure('public.creer_notification(text, uuid, text, uuid, uuid, uuid, bigint, jsonb, text[])') is null
     or to_regprocedure('public.lire_entier_programme(jsonb, text, integer, integer)') is null
     or to_regprocedure('public.contexte_reprise()') is null
     or to_regclass('public.notification_modeles') is null
     or to_regclass('public.recompenses') is null
     or not ('programs.manage' = any (public.permissions_du_role('admin'))) then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt) jusqu''à supabase-anniversaires.sql, puis ce fichier.';
  end if;
end;
$garde$;


-- 2. Tables --------------------------------------------------------------------------
-- La campagne de bienvenue (GOship APP Welcome). Les champs d'une campagne en brouillon peuvent
-- être vides ; ils sont tous exigés à la publication.
create table if not exists public.campagnes_bienvenue (
  id                     uuid primary key default gen_random_uuid(),
  nom                    text not null default '' check (length(nom) <= 80),
  description            text not null default '' check (length(description) <= 500),
  statut                 text not null default 'brouillon'
                         check (statut in ('brouillon', 'programmee', 'active', 'suspendue', 'terminee')),
  debut                  date,
  fin                    date,
  type_recompense        text check (type_recompense is null or type_recompense in
                                     ('credit_expedition', 'reduction_frais', 'bonus_fixe', 'gopoints', 'avantage_colis')),
  valeur_recompense      numeric(10, 2) check (valeur_recompense is null or valeur_recompense > 0),
  operation              text check (operation is null or operation in ('colis_recu', 'facture_payee')),
  budget_max             integer check (budget_max is null or budget_max > 0),   -- nombre maximal d'avantages
  delai_validation_jours integer not null default 0 check (delai_validation_jours between 0 and 90),
  cumul_parrainage       boolean not null default true,
  conditions             text not null default '' check (length(conditions) <= 4000),
  cree_le                timestamptz not null default now(),
  maj_le                 timestamptz not null default now(),
  maj_par                uuid,
  check (debut is null or fin is null or debut <= fin)
);
create index if not exists campagnes_bienvenue_statut_idx on public.campagnes_bienvenue (statut);
alter table public.campagnes_bienvenue enable row level security;
revoke all on public.campagnes_bienvenue from anon, authenticated;

-- Le parrainage (GOship Refer) : une seule configuration, qui naît en brouillon.
create table if not exists public.parrainage_config (
  id                     boolean primary key default true check (id),
  nom                    text not null default 'GOship Refer',
  statut                 text not null default 'brouillon'
                         check (statut in ('brouillon', 'programmee', 'active', 'suspendue', 'terminee')),
  debut                  date,
  fin                    date,
  parrain_type           text check (parrain_type is null or parrain_type in
                                     ('credit_expedition', 'reduction_frais', 'bonus_fixe', 'gopoints', 'avantage_colis')),
  parrain_valeur         numeric(10, 2) check (parrain_valeur is null or parrain_valeur > 0),
  filleul_type           text check (filleul_type is null or filleul_type in
                                     ('credit_expedition', 'reduction_frais', 'bonus_fixe', 'gopoints', 'avantage_colis')),
  filleul_valeur         numeric(10, 2) check (filleul_valeur is null or filleul_valeur > 0),
  operation              text check (operation is null or operation in ('colis_recu', 'facture_payee')),
  delai_validation_jours integer not null default 0 check (delai_validation_jours between 0 and 90),
  max_recompenses        integer check (max_recompenses is null or max_recompenses > 0),   -- parrainages récompensés, au total
  max_par_parrain        integer check (max_par_parrain is null or max_par_parrain > 0),
  cumul_bienvenue        boolean not null default true,
  expiration_jours       integer check (expiration_jours is null or expiration_jours between 1 and 3650),  -- durée de vie d'un avantage obtenu
  conditions             text not null default '' check (length(conditions) <= 4000),
  annulation             text not null default '' check (length(annulation) <= 2000),   -- conditions d'annulation, visibles
  maj_le                 timestamptz not null default now(),
  maj_par                uuid,
  check (debut is null or fin is null or debut <= fin)
);
insert into public.parrainage_config (id) values (true) on conflict (id) do nothing;
alter table public.parrainage_config enable row level security;
revoke all on public.parrainage_config from anon, authenticated;

create table if not exists public.codes_parrainage (
  client_id uuid primary key references public.clients (id),
  code      text not null unique check (code ~ '^[A-Z0-9]{6,12}$'),
  cree_le   timestamptz not null default now()
);
alter table public.codes_parrainage enable row level security;
revoke all on public.codes_parrainage from anon, authenticated;

-- Un filleul a un seul parrain (contrainte unique) et ne peut pas être son propre parrain (check).
--   inscrit    rattaché, la première opération qualifiante n'a pas encore eu lieu
--   qualifie   l'opération a eu lieu, les avantages attendent leur délai de validation
--   recompense avantages accordés
--   refuse     plafond atteint, ou refusé après examen
--   annule     l'opération a été annulée avant la fin du délai
--   suspect    indices d'abus : attend l'examen d'un administrateur, rien n'est accordé
create table if not exists public.parrainages (
  id           bigint generated always as identity primary key,
  parrain_id   uuid not null references public.clients (id),
  filleul_id   uuid not null unique references public.clients (id),
  code         text not null,
  statut       text not null default 'inscrit'
               check (statut in ('inscrit', 'qualifie', 'recompense', 'refuse', 'annule', 'suspect')),
  motif        text not null default '',
  source       text not null default '' check (source in ('', 'inscription', 'saisie')),
  qualifie_le  timestamptz,
  examine_par  uuid,
  cree_le      timestamptz not null default now(),
  maj_le       timestamptz not null default now(),
  check (parrain_id <> filleul_id)
);
create index if not exists parrainages_parrain_idx on public.parrainages (parrain_id, statut);
alter table public.parrainages enable row level security;
revoke all on public.parrainages from anon, authenticated;

-- Chaque fois qu'un parrain copie ou partage son code : le nombre d'invitations. Au plus 50 par jour.
create table if not exists public.parrainage_invitations (
  id         bigint generated always as identity primary key,
  parrain_id uuid not null references public.clients (id),
  canal      text not null default '' check (length(canal) <= 20),
  cree_le    timestamptz not null default now()
);
create index if not exists parrainage_invitations_idx on public.parrainage_invitations (parrain_id, cree_le desc);
alter table public.parrainage_invitations enable row level security;
revoke all on public.parrainage_invitations from anon, authenticated;

-- Les opérations qualifiantes vues par la base (une ligne par client, opération et référence) :
-- le « première » et le « suivantes » des points, la preuve qu'un fait a eu lieu.
create table if not exists public.programme_operations (
  id          bigint generated always as identity primary key,
  client_id   uuid not null references public.clients (id),
  operation   text not null check (operation in ('colis_recu', 'facture_payee')),
  reference   text not null,
  cree_le     timestamptz not null default now(),
  annulee_le  timestamptz,
  unique (client_id, operation, reference)
);
alter table public.programme_operations enable row level security;
revoke all on public.programme_operations from anon, authenticated;

-- Le journal des erreurs du moteur : elles ne bloquent jamais l'opération qui les a causées.
create table if not exists public.programmes_erreurs (
  id         bigint generated always as identity primary key,
  programme  text not null,
  evenement  text not null,
  client_id  uuid,
  message    text not null default '',
  cree_le    timestamptz not null default now()
);
alter table public.programmes_erreurs enable row level security;
revoke all on public.programmes_erreurs from anon, authenticated;

-- Les avantages (supabase-fidelite.sql) : une date « valide après » pour le délai de validation, et
-- un seul bonus de bienvenue par client.
alter table public.recompenses add column if not exists valide_apres date;
create unique index if not exists recompenses_bienvenue_unique
  on public.recompenses (client_id) where programme = 'welcome' and statut in ('en_attente', 'obtenue', 'utilisee');


-- 3. Petites aides --------------------------------------------------------------------------
-- La phrase qui décrit un avantage, dans la langue du client (jamais un montant sans sa nature)
create or replace function public.texte_recompense(p_type text, p_valeur numeric, p_langue text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case public.langue_notification(p_langue)
    when 'en' then case p_type
      when 'gopoints' then trim(to_char(p_valeur, 'FM999999990')) || ' GOPOINTS'
      when 'credit_expedition' then '$' || trim(to_char(p_valeur, 'FM999999990.00')) || ' shipping credit'
      when 'reduction_frais' then '$' || trim(to_char(p_valeur, 'FM999999990.00')) || ' off the service fee'
      when 'bonus_fixe' then '$' || trim(to_char(p_valeur, 'FM999999990.00')) || ' bonus'
      else 'a $' || trim(to_char(p_valeur, 'FM999999990.00')) || ' benefit on your next package' end
    when 'es' then case p_type
      when 'gopoints' then trim(to_char(p_valeur, 'FM999999990')) || ' GOPOINTS'
      when 'credit_expedition' then 'crédito de envío de $' || trim(to_char(p_valeur, 'FM999999990.00'))
      when 'reduction_frais' then '$' || trim(to_char(p_valeur, 'FM999999990.00')) || ' de descuento en la tarifa de servicio'
      when 'bonus_fixe' then 'bono de $' || trim(to_char(p_valeur, 'FM999999990.00'))
      else 'un beneficio de $' || trim(to_char(p_valeur, 'FM999999990.00')) || ' en su próximo paquete' end
    when 'ht' then case p_type
      when 'gopoints' then trim(to_char(p_valeur, 'FM999999990')) || ' GOPOINTS'
      when 'credit_expedition' then 'kredi ekspedisyon $' || trim(to_char(p_valeur, 'FM999999990.00'))
      when 'reduction_frais' then '$' || trim(to_char(p_valeur, 'FM999999990.00')) || ' rabè sou frè sèvis la'
      when 'bonus_fixe' then 'bonis $' || trim(to_char(p_valeur, 'FM999999990.00'))
      else 'yon avantaj $' || trim(to_char(p_valeur, 'FM999999990.00')) || ' sou pwochen koli ou' end
    else case p_type
      when 'gopoints' then trim(to_char(p_valeur, 'FM999999990')) || ' GOPOINTS'
      when 'credit_expedition' then replace(trim(to_char(p_valeur, 'FM999999990.00')), '.', ',') || ' $ de crédit d''expédition'
      when 'reduction_frais' then replace(trim(to_char(p_valeur, 'FM999999990.00')), '.', ',') || ' $ de réduction sur les frais de service'
      when 'bonus_fixe' then 'un bonus de ' || replace(trim(to_char(p_valeur, 'FM999999990.00')), '.', ',') || ' $'
      else 'un avantage de ' || replace(trim(to_char(p_valeur, 'FM999999990.00')), '.', ',') || ' $ sur votre prochain colis' end
  end
$$;

-- Les textes des messages d'avantage (trois types, quatre langues). Comme les anniversaires : lus dans
-- notification_modeles ; {{avantage}} est la phrase de texte_recompense.
insert into public.notification_modeles (type, langue, titre, message, titre_defaut, message_defaut) values
  ('reward_pending', 'fr', 'Votre avantage est en cours de validation', 'Votre avantage ({{avantage}}) sera confirmé après vérification de l''opération concernée. Rien n''est acquis avant cette confirmation : nous vous prévenons dès que c''est fait.', 'Votre avantage est en cours de validation', 'Votre avantage ({{avantage}}) sera confirmé après vérification de l''opération concernée. Rien n''est acquis avant cette confirmation : nous vous prévenons dès que c''est fait.'),
  ('reward_pending', 'en', 'Your benefit is being validated', 'Your benefit ({{avantage}}) will be confirmed once the related operation has been checked. Nothing is yours before that confirmation: we will tell you as soon as it is done.', 'Your benefit is being validated', 'Your benefit ({{avantage}}) will be confirmed once the related operation has been checked. Nothing is yours before that confirmation: we will tell you as soon as it is done.'),
  ('reward_pending', 'es', 'Su beneficio está en validación', 'Su beneficio ({{avantage}}) se confirmará tras verificar la operación correspondiente. Nada es suyo antes de esa confirmación: le avisaremos en cuanto esté hecho.', 'Su beneficio está en validación', 'Su beneficio ({{avantage}}) se confirmará tras verificar la operación correspondiente. Nada es suyo antes de esa confirmación: le avisaremos en cuanto esté hecho.'),
  ('reward_pending', 'ht', 'Avantaj ou an kou validasyon', 'Avantaj ou a ({{avantage}}) ap konfime apre nou fin verifye operasyon ki konsène a. Anyen pa pou ou anvan konfimasyon sa a : nou pral di w le sa fèt.', 'Avantaj ou an kou validasyon', 'Avantaj ou a ({{avantage}}) ap konfime apre nou fin verifye operasyon ki konsène a. Anyen pa pou ou anvan konfimasyon sa a : nou pral di w le sa fèt.'),
  ('reward_earned', 'fr', '🎁 Avantage obtenu', 'C''est confirmé : vous avez obtenu {{avantage}}. Retrouvez le détail dans l''application.', '🎁 Avantage obtenu', 'C''est confirmé : vous avez obtenu {{avantage}}. Retrouvez le détail dans l''application.'),
  ('reward_earned', 'en', '🎁 Benefit earned', 'It is confirmed: you have earned {{avantage}}. See the details in the app.', '🎁 Benefit earned', 'It is confirmed: you have earned {{avantage}}. See the details in the app.'),
  ('reward_earned', 'es', '🎁 Beneficio obtenido', 'Está confirmado: ha obtenido {{avantage}}. Consulte el detalle en la aplicación.', '🎁 Beneficio obtenido', 'Está confirmado: ha obtenido {{avantage}}. Consulte el detalle en la aplicación.'),
  ('reward_earned', 'ht', '🎁 Avantaj jwenn', 'Sa konfime : ou jwenn {{avantage}}. Gade detay yo nan aplikasyon an.', '🎁 Avantaj jwenn', 'Sa konfime : ou jwenn {{avantage}}. Gade detay yo nan aplikasyon an.'),
  ('reward_cancelled', 'fr', 'Avantage annulé', 'L''avantage {{avantage}} a été annulé : l''opération concernée n''est plus valable. Pour toute question, contactez-nous.', 'Avantage annulé', 'L''avantage {{avantage}} a été annulé : l''opération concernée n''est plus valable. Pour toute question, contactez-nous.'),
  ('reward_cancelled', 'en', 'Benefit cancelled', 'The benefit {{avantage}} has been cancelled: the related operation is no longer valid. If you have any question, contact us.', 'Benefit cancelled', 'The benefit {{avantage}} has been cancelled: the related operation is no longer valid. If you have any question, contact us.'),
  ('reward_cancelled', 'es', 'Beneficio anulado', 'El beneficio {{avantage}} ha sido anulado: la operación correspondiente ya no es válida. Si tiene alguna pregunta, contáctenos.', 'Beneficio anulado', 'El beneficio {{avantage}} ha sido anulado: la operación correspondiente ya no es válida. Si tiene alguna pregunta, contáctenos.'),
  ('reward_cancelled', 'ht', 'Avantaj anile', 'Avantaj {{avantage}} la anile : operasyon ki konsène a pa valab ankò. Si w gen kesyon, kontakte nou.', 'Avantaj anile', 'Avantaj {{avantage}} la anile : operasyon ki konsène a pa valab ankò. Si w gen kesyon, kontakte nou.')
on conflict (type, langue) do nothing;

-- Le moteur lit les statuts à la demande : une campagne programmée devient active à sa date de début, une
-- campagne terminée le lendemain de sa fin. Aucune page, aucun client ne décide de cela.
create or replace function public.campagnes_maj_statuts()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_jour date := public.aujourdhui_entreprise();
begin
  update public.campagnes_bienvenue set statut = 'active', maj_le = now() where statut = 'programmee' and debut <= v_jour;
  update public.campagnes_bienvenue set statut = 'terminee', maj_le = now() where statut in ('active', 'programmee', 'suspendue') and fin < v_jour;
  update public.parrainage_config set statut = 'active', maj_le = now() where statut = 'programmee' and debut <= v_jour;
  update public.parrainage_config set statut = 'terminee', maj_le = now() where statut in ('active', 'programmee', 'suspendue') and fin < v_jour;
end;
$$;

create or replace function public.programmes_noter_erreur(p_programme text, p_evenement text, p_client uuid, p_message text)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.programmes_erreurs (programme, evenement, client_id, message)
  values (p_programme, p_evenement, p_client, left(coalesce(p_message, ''), 200))
$$;


-- 4. Avantages : créer, valider, annuler (interne) -------------------------------------------------
-- Des points accordés par une campagne : le nombre est celui de la campagne (pas celui d'une règle). Le
-- programme GOPOINTS doit être allumé ; sinon rien n'est écrit (null).
create or replace function public.points_gain_campagne(p_client uuid, p_source text, p_reference text, p_points integer)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  g public.points_reglages;
begin
  select * into g from public.points_reglages where id;
  if not g.actif or p_points is null or p_points <= 0 then
    return null;
  end if;
  return public.points_ecrire(p_client, 'gain', p_points, p_source, p_reference, 'gain:' || p_source || ':' || p_reference,
                              '', null, case when g.expiration_jours is null then null else public.aujourdhui_entreprise() + g.expiration_jours end);
end;
$$;

-- Prévenir le client du statut de son avantage, une fois par statut
create or replace function public.recompense_prevenir(p_id uuid, p_type_message text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.recompenses;
  v_langue text;
begin
  select * into r from public.recompenses where id = p_id;
  select langue into v_langue from public.clients where id = r.client_id;
  perform public.creer_notification(p_type_message, r.client_id, 'recompense:' || r.id || ':' || p_type_message, null, null, null, null,
                                    jsonb_build_object('avantage', public.texte_recompense(r.type, r.valeur, v_langue)),
                                    array['push', 'email']);
exception when others then
  perform public.programmes_noter_erreur('recompense', 'prevenir', r.client_id, sqlerrm);
end;
$$;

-- Un avantage devient acquis : les points entrent dans le registre, le client est prévenu. Rend vrai si c'est fait.
create or replace function public.recompense_finaliser(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.recompenses;
  v_ok bigint;
begin
  select * into r from public.recompenses where id = p_id for update;
  if not found or r.statut not in ('en_attente', 'obtenue') then
    return false;
  end if;
  if r.type = 'gopoints' then
    v_ok := public.points_gain_campagne(r.client_id, 'recompense', r.id::text, r.valeur::integer);
    if v_ok is null and not exists (select 1 from public.points_mouvements where cle = 'gain:recompense:' || r.id) then
      -- Le programme GOPOINTS est éteint : l'avantage attend, il n'est pas perdu (repris chaque jour)
      update public.recompenses set statut = 'en_attente', motif = 'POINTS_INDISPONIBLES', maj_le = now() where id = r.id;
      return false;
    end if;
  end if;
  update public.recompenses set statut = 'obtenue', motif = '', maj_le = now() where id = r.id and statut <> 'obtenue';
  perform public.recompense_prevenir(r.id, 'reward_earned');
  return true;
end;
$$;

-- Créer un avantage : une clé unique (rien en double), un délai de validation éventuel. Rend l'identifiant, ou null s'il existait.
create or replace function public.recompense_creer(p_client uuid, p_programme text, p_type text, p_valeur numeric, p_cle text,
                                                   p_campagne text, p_reference text, p_delai integer, p_expiration integer default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_jour date := public.aujourdhui_entreprise();
begin
  insert into public.recompenses (client_id, programme, type, valeur, statut, cle, campagne, reference, valide_apres, expire_le)
  values (p_client, p_programme, p_type, p_valeur, case when coalesce(p_delai, 0) > 0 then 'en_attente' else 'obtenue' end,
          p_cle, coalesce(p_campagne, ''), coalesce(p_reference, ''),
          case when coalesce(p_delai, 0) > 0 then v_jour + p_delai else null end,
          case when p_expiration is null then null else v_jour + coalesce(p_delai, 0) + p_expiration end)
  on conflict do nothing
  returning id into v_id;
  if v_id is null then
    return null;
  end if;
  if coalesce(p_delai, 0) > 0 then
    perform public.recompense_prevenir(v_id, 'reward_pending');
  else
    perform public.recompense_finaliser(v_id);
  end if;
  return v_id;
end;
$$;

-- L'opération d'un avantage est-elle encore valable ? (référence « colis:<uuid> » ou « facture:<uuid> »)
create or replace function public.operation_valable(p_reference text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_reference like 'facture:%' then
    return exists (select 1 from public.factures f where f.id = substr(p_reference, 9)::uuid and f.statut <> 'annulee')
           and not exists (select 1 from public.paiements p where p.facture_id = substr(p_reference, 9)::uuid and p.annule_le is not null
                              and not exists (select 1 from public.paiements q where q.facture_id = p.facture_id and q.annule_le is null));
  elsif p_reference like 'colis:%' then
    return exists (select 1 from public.colis c where c.id = substr(p_reference, 7)::uuid);
  end if;
  return true;
exception when others then
  return true;   -- une référence illisible n'annule rien toute seule : l'équipe tranche
end;
$$;


-- 5. Le moteur ----------------------------------------------------------------------------------
-- Une opération qualifiante vue par la base. Idempotent : la même opération rejouée ne fait rien de plus.
create or replace function public.programmes_operation(p_client uuid, p_operation text, p_reference text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
  v_rang integer;
  b public.campagnes_bienvenue;
  c public.parrainage_config;
  pa public.parrainages;
  v_cree date;
  v_fuseau text;
  v_deja_parrain boolean;
  v_langue text;
begin
  if p_client is null or not exists (select 1 from public.clients where id = p_client and role = 'client' and supprime_le is null) then
    return;
  end if;
  perform public.campagnes_maj_statuts();
  insert into public.programme_operations (client_id, operation, reference) values (p_client, p_operation, p_reference)
  on conflict (client_id, operation, reference) do nothing
  returning id into v_id;
  if v_id is null then
    return;   -- déjà vue : tout ce qu'elle déclenche l'a déjà été
  end if;
  select count(*) into v_rang from public.programme_operations where client_id = p_client and operation = p_operation and annulee_le is null;

  -- Les points de fidélité : première opération, puis les suivantes (selon la règle et son opération qualifiante)
  if v_rang = 1 and exists (select 1 from public.points_regles where evenement = 'first_operation' and operation = p_operation) then
    perform public.points_attribuer(p_client, 'first_operation', p_reference);
  elsif v_rang > 1 and exists (select 1 from public.points_regles where evenement = 'repeat_operation' and operation = p_operation) then
    perform public.points_attribuer(p_client, 'repeat_operation', p_reference);
  end if;

  select fuseau into v_fuseau from public.programme_reglages where id;
  select (cree_le at time zone coalesce(v_fuseau, 'America/Santo_Domingo'))::date, langue into v_cree, v_langue from public.clients where id = p_client;
  select exists (select 1 from public.parrainages where filleul_id = p_client and statut in ('inscrit', 'qualifie', 'recompense', 'suspect'))
    into v_deja_parrain;

  -- GOship APP Welcome : le client inscrit pendant la campagne active, première opération qualifiante, une seule fois
  select * into b from public.campagnes_bienvenue
   where statut = 'active' and operation = p_operation and v_cree between debut and fin
   order by debut, id limit 1;
  if found
     and not (not b.cumul_parrainage and v_deja_parrain)
     and (b.budget_max is null or (select count(*) from public.recompenses r where r.programme = 'welcome' and r.campagne = b.id::text
                                      and r.statut in ('en_attente', 'obtenue', 'utilisee')) < b.budget_max) then
    perform public.recompense_creer(p_client, 'welcome', b.type_recompense, b.valeur_recompense,
                                    'welcome:' || b.id || ':' || p_client, b.id::text, p_reference, b.delai_validation_jours);
  end if;

  -- GOship Refer : le filleul rattaché, sa première opération qualifiante
  select * into c from public.parrainage_config where id;
  select * into pa from public.parrainages where filleul_id = p_client and statut = 'inscrit' for update;
  if found and c.statut = 'active' and c.operation = p_operation then
    if c.max_recompenses is not null and (select count(*) from public.parrainages where statut in ('qualifie', 'recompense')) >= c.max_recompenses then
      update public.parrainages set statut = 'refuse', motif = 'PLAFOND_GLOBAL', maj_le = now() where id = pa.id;
    elsif c.max_par_parrain is not null and (select count(*) from public.parrainages
                                              where parrain_id = pa.parrain_id and statut in ('qualifie', 'recompense')) >= c.max_par_parrain then
      update public.parrainages set statut = 'refuse', motif = 'PLAFOND_PARRAIN', maj_le = now() where id = pa.id;
    else
      update public.parrainages set statut = 'qualifie', qualifie_le = now(), maj_le = now() where id = pa.id;
      -- Le filleul : son avantage, sauf si le cumul avec la bienvenue est interdit et qu'il l'a déjà
      if c.cumul_bienvenue or not exists (select 1 from public.recompenses where client_id = p_client and programme = 'welcome'
                                           and statut in ('en_attente', 'obtenue', 'utilisee')) then
        perform public.recompense_creer(p_client, 'refer_filleul', c.filleul_type, c.filleul_valeur,
                                        'refer:' || pa.id || ':filleul', 'parrainage', p_reference, c.delai_validation_jours, c.expiration_jours);
      end if;
      perform public.recompense_creer(pa.parrain_id, 'refer_parrain', c.parrain_type, c.parrain_valeur,
                                      'refer:' || pa.id || ':parrain', 'parrainage', p_reference, c.delai_validation_jours, c.expiration_jours);
      -- Des points pour un parrainage validé : seulement si l'avantage du parrain n'est pas déjà en points
      if c.parrain_type <> 'gopoints' and c.delai_validation_jours = 0 then
        perform public.points_attribuer(pa.parrain_id, 'referral_validated', 'parrainage:' || pa.id);
      end if;
      perform public.parrainage_actualiser(pa.id);
    end if;
  end if;
end;
$$;

-- Le parrainage passe à « récompensé » quand plus aucun de ses avantages n'attend, à « annulé » si tous sont annulés
create or replace function public.parrainage_actualiser(p_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_attente integer;
  v_valides integer;
begin
  select count(*) filter (where r.statut = 'en_attente'), count(*) filter (where r.statut in ('obtenue', 'utilisee'))
    into v_attente, v_valides
    from public.recompenses r where r.cle in ('refer:' || p_id || ':parrain', 'refer:' || p_id || ':filleul');
  if v_attente = 0 and v_valides > 0 then
    update public.parrainages set statut = 'recompense', maj_le = now() where id = p_id and statut = 'qualifie';
  elsif v_attente = 0 and v_valides = 0 then
    update public.parrainages set statut = 'annule', motif = 'OPERATION_ANNULEE', maj_le = now() where id = p_id and statut = 'qualifie';
  end if;
end;
$$;

-- Une opération annulée ou remboursée : les avantages qui n'étaient qu'en attente sont annulés, jamais accordés
create or replace function public.programmes_operation_annulee(p_reference text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_parrainage bigint;
begin
  update public.programme_operations set annulee_le = now() where reference = p_reference and annulee_le is null;
  for r in select id, client_id, cle from public.recompenses where reference = p_reference and statut = 'en_attente' loop
    update public.recompenses set statut = 'annulee', motif = 'OPERATION_ANNULEE', maj_le = now() where id = r.id;
    perform public.recompense_prevenir(r.id, 'reward_cancelled');
    if r.cle like 'refer:%' then
      v_parrainage := split_part(r.cle, ':', 2)::bigint;
      perform public.parrainage_actualiser(v_parrainage);
    end if;
  end loop;
end;
$$;


-- 6. Les déclencheurs -----------------------------------------------------------------------------
-- Un compte créé : les points de bienvenue (si la règle est allumée) et le rattachement au parrain venu du formulaire.
create or replace function public.programmes_compte_cree()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text;
begin
  if public.contexte_reprise() or new.role <> 'client' then
    return null;
  end if;
  begin
    perform public.points_attribuer(new.id, 'account_created', 'compte:' || new.id);
    select upper(trim(coalesce(raw_user_meta_data ->> 'code_parrainage', ''))) into v_code from auth.users where id = new.id;
    if coalesce(v_code, '') <> '' then
      perform public.parrainage_rattacher(new.id, v_code, 'inscription', false);
    end if;
  exception when others then
    perform public.programmes_noter_erreur('compte', 'cree', new.id, sqlerrm);
  end;
  return null;
end;
$$;
drop trigger if exists programmes_compte_cree on public.clients;
create trigger programmes_compte_cree
  after insert on public.clients
  for each row execute function public.programmes_compte_cree();

-- Un colis reçu à l'entrepôt de Miami : une opération qualifiante (« colis_recu »)
create or replace function public.programmes_etape_colis()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_client uuid;
begin
  if new.type_evenement is distinct from 'COLIS_RECU' or new.visibilite is distinct from 'publique' or public.contexte_reprise() then
    return null;
  end if;
  select client_id into v_client from public.colis where id = new.colis_id;
  begin
    perform public.programmes_operation(v_client, 'colis_recu', 'colis:' || new.colis_id);
  exception when others then
    perform public.programmes_noter_erreur('operation', 'colis_recu', v_client, sqlerrm);
  end;
  return null;
end;
$$;
drop trigger if exists programmes_etape_colis on public.colis_historique;
create trigger programmes_etape_colis
  after insert on public.colis_historique
  for each row execute function public.programmes_etape_colis();

-- Une facture payée : une opération qualifiante (« facture_payee ») ; une facture ou un paiement annulé : ses avantages en attente le sont aussi
create or replace function public.programmes_evenement_facturation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.contexte_reprise() then
    return null;
  end if;
  begin
    if new.type = 'FACTURE_PAYEE' and new.client_id is not null then
      perform public.programmes_operation(new.client_id, 'facture_payee', 'facture:' || new.facture_id);
    elsif new.type in ('FACTURE_ANNULEE', 'PAIEMENT_ANNULE') and new.facture_id is not null then
      perform public.programmes_operation_annulee('facture:' || new.facture_id);
    end if;
  exception when others then
    perform public.programmes_noter_erreur('operation', new.type, new.client_id, sqlerrm);
  end;
  return null;
end;
$$;
drop trigger if exists programmes_evenement_facturation on public.evenements_facturation;
create trigger programmes_evenement_facturation
  after insert on public.evenements_facturation
  for each row execute function public.programmes_evenement_facturation();


-- 7. Le parrainage ------------------------------------------------------------------------------------
-- Le code d'un client : créé à la première demande, 8 signes sans ambiguïté (ni O, ni 0, ni I, ni 1, ni L).
create or replace function public.code_parrainage_de(p_client uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text;
  v_alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  i integer;
begin
  select code into v_code from public.codes_parrainage where client_id = p_client;
  if v_code is not null then
    return v_code;
  end if;
  loop
    v_code := 'GS';
    for i in 1..6 loop
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::integer, 1);
    end loop;
    begin
      insert into public.codes_parrainage (client_id, code) values (p_client, v_code);
      return v_code;
    exception when unique_violation then
      -- soit ce code existe déjà (on en tire un autre), soit un appel simultané vient de créer celui du client
      select code into v_code from public.codes_parrainage where client_id = p_client;
      if v_code is not null then
        return v_code;
      end if;
    end;
  end loop;
end;
$$;

-- Rattacher un filleul à un parrain par un code. p_strict : vrai pour un appel d'un client (il lui faut la raison du refus) ;
-- faux à l'inscription (un code invalide ne bloque jamais la création du compte : on l'ignore).
create or replace function public.parrainage_rattacher(p_filleul uuid, p_code text, p_source text, p_strict boolean)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.parrainage_config;
  v_parrain uuid;
  f public.clients;
  p public.clients;
  v_motif text := '';
  v_id bigint;
  v_fuseau text;
begin
  perform public.campagnes_maj_statuts();
  select * into c from public.parrainage_config where id;
  select client_id into v_parrain from public.codes_parrainage where code = upper(trim(coalesce(p_code, '')));
  if v_parrain is null then
    if p_strict then perform public.erreur_metier('INVALID_REFERRAL_CODE', 'Ce code de parrainage n''existe pas. Vérifiez-le.'); end if;
    return null;
  end if;
  if v_parrain = p_filleul then
    if p_strict then perform public.erreur_metier('SELF_REFERRAL', 'Vous ne pouvez pas utiliser votre propre code de parrainage.'); end if;
    return null;
  end if;
  if c.statut <> 'active' or public.aujourdhui_entreprise() not between c.debut and c.fin then
    if p_strict then perform public.erreur_metier('REFERRAL_INACTIVE', 'Le parrainage n''est pas ouvert pour le moment : ce code ne peut pas être utilisé.'); end if;
    return null;
  end if;
  select * into f from public.clients where id = p_filleul;
  select * into p from public.clients where id = v_parrain;
  if f.role <> 'client' or f.supprime_le is not null or p.role <> 'client' or p.supprime_le is not null then
    if p_strict then perform public.erreur_metier('INVALID_REFERRAL_CODE', 'Ce code de parrainage ne peut pas être utilisé.'); end if;
    return null;
  end if;
  if exists (select 1 from public.parrainages where filleul_id = p_filleul) then
    if p_strict then perform public.erreur_metier('ALREADY_REFERRED', 'Un code de parrainage est déjà enregistré pour votre compte.'); end if;
    return null;
  end if;
  if exists (select 1 from public.parrainages where filleul_id = v_parrain and parrain_id = p_filleul) then
    if p_strict then perform public.erreur_metier('REFERRAL_CYCLE', 'Ce parrainage n''est pas possible : cette personne a été invitée par vous.'); end if;
    return null;
  end if;
  -- Après sa première opération qualifiante, trop tard : le parrainage doit précéder l'opération
  if exists (select 1 from public.programme_operations where client_id = p_filleul and operation = c.operation) then
    if p_strict then perform public.erreur_metier('REFERRAL_TOO_LATE', 'Un code de parrainage ne peut plus être ajouté : votre première opération a déjà eu lieu.'); end if;
    return null;
  end if;
  select fuseau into v_fuseau from public.programme_reglages where id;
  if p_source = 'saisie' and f.cree_le < now() - interval '30 days' then
    if p_strict then perform public.erreur_metier('REFERRAL_TOO_LATE', 'Un code de parrainage ne s''ajoute que dans les 30 jours qui suivent l''ouverture du compte.'); end if;
    return null;
  end if;

  -- Les indices d'abus : un seul ne bloque rien, mais le parrainage attend l'examen d'un administrateur
  if length(regexp_replace(coalesce(f.telephone, ''), '\D', '', 'g')) >= 7
     and regexp_replace(coalesce(f.telephone, ''), '\D', '', 'g') = regexp_replace(coalesce(p.telephone, ''), '\D', '', 'g') then
    v_motif := v_motif || 'MEME_TELEPHONE ';
  end if;
  if length(trim(coalesce(f.adresse, ''))) >= 8 and lower(trim(f.adresse)) = lower(trim(coalesce(p.adresse, ''))) then
    v_motif := v_motif || 'MEME_ADRESSE ';
  end if;
  if split_part(lower(coalesce(f.email, '')), '@', 1) <> '' and split_part(lower(f.email), '@', 1) = split_part(lower(coalesce(p.email, '')), '@', 1) then
    v_motif := v_motif || 'MEME_IDENTIFIANT_EMAIL ';
  end if;
  if (select count(*) from public.parrainages where parrain_id = v_parrain and cree_le > now() - interval '24 hours') >= 5 then
    v_motif := v_motif || 'RAFALE_INSCRIPTIONS ';
  end if;

  insert into public.parrainages (parrain_id, filleul_id, code, statut, motif, source)
  values (v_parrain, p_filleul, upper(trim(p_code)), case when v_motif = '' then 'inscrit' else 'suspect' end, trim(v_motif), p_source)
  on conflict (filleul_id) do nothing
  returning id into v_id;
  return v_id;
end;
$$;


-- 8. Le client ---------------------------------------------------------------------------------------------
-- Le compte connecté, et lui seul. Rend null s'il n'y a aucune campagne qui le concerne.
create or replace function public.ma_bienvenue()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_moi uuid := auth.uid();
  b public.campagnes_bienvenue;
  v_cree date;
  v_fuseau text;
  r public.recompenses;
  v_statut text;
  v_langue text;
begin
  if v_moi is null then
    perform public.erreur_metier('PERMISSION_DENIED', 'Connectez-vous pour voir votre offre de bienvenue.');
  end if;
  perform public.campagnes_maj_statuts();
  select fuseau into v_fuseau from public.programme_reglages where id;
  select (cree_le at time zone coalesce(v_fuseau, 'America/Santo_Domingo'))::date, langue into v_cree, v_langue
    from public.clients where id = v_moi and role = 'client' and supprime_le is null;
  if v_cree is null then
    return null;
  end if;
  -- Le bonus déjà accordé (ou en attente) l'emporte ; sinon la campagne ouverte à laquelle ce client a droit
  select * into r from public.recompenses where client_id = v_moi and programme = 'welcome' order by cree_le desc limit 1;
  if found then
    select * into b from public.campagnes_bienvenue where id::text = r.campagne;
    v_statut := case r.statut when 'en_attente' then 'en_attente' when 'obtenue' then 'obtenu' when 'utilisee' then 'obtenu'
                              else 'expire' end;
  else
    select * into b from public.campagnes_bienvenue
     where statut in ('active', 'terminee') and v_cree between debut and fin order by (statut = 'active') desc, debut desc limit 1;
    if not found then
      return null;
    end if;
    v_statut := case when b.statut = 'active' and (b.budget_max is null or (select count(*) from public.recompenses x
                        where x.programme = 'welcome' and x.campagne = b.id::text and x.statut in ('en_attente', 'obtenue', 'utilisee')) < b.budget_max)
                     then 'a_debloquer' else 'expire' end;
  end if;
  return jsonb_build_object(
    'nom', b.nom, 'description', b.description, 'statut', v_statut, 'fin', b.fin,
    'operation', b.operation, 'type', b.type_recompense, 'valeur', b.valeur_recompense,
    'avantage', public.texte_recompense(b.type_recompense, b.valeur_recompense, v_langue),
    'delai_validation_jours', b.delai_validation_jours, 'conditions', b.conditions,
    'etapes', jsonb_build_array(jsonb_build_object('cle', 'compte', 'fait', true),
                                jsonb_build_object('cle', 'operation', 'fait', v_statut in ('en_attente', 'obtenu'))));
end;
$$;

-- Le parrainage du client : son code, son lien, des chiffres, ses propres avantages. Jamais l'identité ni les opérations d'un filleul.
create or replace function public.mon_parrainage()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_moi uuid := auth.uid();
  c public.parrainage_config;
  v_site text := coalesce(public.lire_reglage('site_url'), '');
  v_langue text;
  v_code text;
begin
  if v_moi is null or not exists (select 1 from public.clients where id = v_moi and role = 'client' and supprime_le is null) then
    perform public.erreur_metier('PERMISSION_DENIED', 'Connectez-vous avec un compte client pour voir votre parrainage.');
  end if;
  perform public.campagnes_maj_statuts();
  select * into c from public.parrainage_config where id;
  select langue into v_langue from public.clients where id = v_moi;
  v_code := public.code_parrainage_de(v_moi);
  return jsonb_build_object(
    'actif', c.statut = 'active' and public.aujourdhui_entreprise() between c.debut and c.fin,
    'nom', c.nom, 'code', v_code,
    'lien', case when v_site ~ '^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~/-]*)?$'
                 then regexp_replace(v_site, '/?$', '/') || 'inscription.html?parrain=' || v_code else '' end,
    'fin', c.fin, 'operation', c.operation,
    'avantage_parrain', case when c.parrain_type is null then '' else public.texte_recompense(c.parrain_type, c.parrain_valeur, v_langue) end,
    'avantage_filleul', case when c.filleul_type is null then '' else public.texte_recompense(c.filleul_type, c.filleul_valeur, v_langue) end,
    'delai_validation_jours', c.delai_validation_jours, 'conditions', c.conditions, 'annulation', c.annulation,
    'invitations', (select count(*) from public.parrainage_invitations where parrain_id = v_moi),
    'inscrits', (select count(*) from public.parrainages where parrain_id = v_moi and statut <> 'refuse'),
    'en_attente_premiere_operation', (select count(*) from public.parrainages where parrain_id = v_moi and statut in ('inscrit', 'suspect')),
    'valides', (select count(*) from public.parrainages where parrain_id = v_moi and statut in ('qualifie', 'recompense')),
    'recompenses', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'type', r.type, 'valeur', r.valeur, 'statut', r.statut,
                                                                 'date', r.cree_le, 'avantage', public.texte_recompense(r.type, r.valeur, v_langue))
                                              order by r.cree_le desc)
                               from public.recompenses r where r.client_id = v_moi and r.programme = 'refer_parrain'), '[]'::jsonb),
    'mon_parrain', exists (select 1 from public.parrainages where filleul_id = v_moi));
end;
$$;

-- Compter une invitation (le client vient de copier ou de partager son code) : 50 par jour au plus
create or replace function public.noter_invitation(p_canal text default '')
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_moi uuid := auth.uid();
begin
  if v_moi is null or not exists (select 1 from public.clients where id = v_moi and role = 'client' and supprime_le is null) then
    perform public.erreur_metier('PERMISSION_DENIED', 'Connectez-vous pour partager votre code.');
  end if;
  if (select count(*) from public.parrainage_invitations where parrain_id = v_moi and cree_le > now() - interval '24 hours') < 50 then
    insert into public.parrainage_invitations (parrain_id, canal) values (v_moi, left(coalesce(p_canal, ''), 20));
  end if;
  return (select count(*) from public.parrainage_invitations where parrain_id = v_moi)::integer;
end;
$$;

-- Saisir un code de parrainage après l'inscription (compte Google, code reçu plus tard)
create or replace function public.utiliser_code_parrainage(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_moi uuid := auth.uid();
  v_id bigint;
begin
  if v_moi is null or not exists (select 1 from public.clients where id = v_moi and role = 'client' and supprime_le is null) then
    perform public.erreur_metier('PERMISSION_DENIED', 'Connectez-vous avec un compte client pour utiliser un code.');
  end if;
  v_id := public.parrainage_rattacher(v_moi, p_code, 'saisie', true);
  if v_id is null then
    perform public.erreur_metier('ALREADY_REFERRED', 'Un code de parrainage est déjà enregistré pour votre compte.');
  end if;
  return jsonb_build_object('enregistre', true);
end;
$$;


-- 9. L'équipe ------------------------------------------------------------------------------------------------------
-- Une campagne à partir d'un jsonb : seuls les champs présents changent
create or replace function public.bienvenue_enregistrer(p_id uuid, p_donnees jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  d jsonb := coalesce(p_donnees, '{}'::jsonb);
  b public.campagnes_bienvenue;
  v_avant jsonb;
begin
  perform public.exiger_permission('programs.manage');
  begin
    if p_id is null then
      insert into public.campagnes_bienvenue (nom, description, debut, fin, type_recompense, valeur_recompense, operation, budget_max,
                                              delai_validation_jours, cumul_parrainage, conditions, maj_par)
      values (left(trim(coalesce(d ->> 'nom', '')), 80), left(trim(coalesce(d ->> 'description', '')), 500),
              nullif(d ->> 'debut', '')::date, nullif(d ->> 'fin', '')::date, nullif(d ->> 'type_recompense', ''),
              nullif(d ->> 'valeur_recompense', '')::numeric, nullif(d ->> 'operation', ''),
              public.lire_entier_programme(d, 'budget_max', 1, 10000000),
              coalesce(public.lire_entier_programme(d, 'delai_validation_jours', 0, 90), 0),
              coalesce((d ->> 'cumul_parrainage')::boolean, true), left(coalesce(d ->> 'conditions', ''), 4000), auth.uid())
      returning * into b;
    else
      select * into b from public.campagnes_bienvenue where id = p_id for update;
      if not found then
        perform public.erreur_metier('INVALID_CAMPAIGN', 'Cette campagne n''existe pas.');
      end if;
      if b.statut in ('active', 'terminee') then
        perform public.erreur_metier('CAMPAIGN_LOCKED', 'Une campagne active ou terminée ne se modifie pas : suspendez-la d''abord (une campagne terminée se duplique).');
      end if;
      v_avant := to_jsonb(b) - 'maj_par';
      update public.campagnes_bienvenue set
        nom = case when d ? 'nom' then left(trim(coalesce(d ->> 'nom', '')), 80) else nom end,
        description = case when d ? 'description' then left(trim(coalesce(d ->> 'description', '')), 500) else description end,
        debut = case when d ? 'debut' then nullif(d ->> 'debut', '')::date else debut end,
        fin = case when d ? 'fin' then nullif(d ->> 'fin', '')::date else fin end,
        type_recompense = case when d ? 'type_recompense' then nullif(d ->> 'type_recompense', '') else type_recompense end,
        valeur_recompense = case when d ? 'valeur_recompense' then nullif(d ->> 'valeur_recompense', '')::numeric else valeur_recompense end,
        operation = case when d ? 'operation' then nullif(d ->> 'operation', '') else operation end,
        budget_max = case when d ? 'budget_max' then public.lire_entier_programme(d, 'budget_max', 1, 10000000) else budget_max end,
        delai_validation_jours = case when d ? 'delai_validation_jours' then coalesce(public.lire_entier_programme(d, 'delai_validation_jours', 0, 90), 0) else delai_validation_jours end,
        cumul_parrainage = case when d ? 'cumul_parrainage' then (d ->> 'cumul_parrainage')::boolean else cumul_parrainage end,
        conditions = case when d ? 'conditions' then left(coalesce(d ->> 'conditions', ''), 4000) else conditions end,
        maj_le = now(), maj_par = auth.uid()
       where id = p_id returning * into b;
    end if;
  exception when check_violation or invalid_text_representation or invalid_datetime_format or numeric_value_out_of_range then
    perform public.erreur_metier('INVALID_CAMPAIGN', 'La campagne contient une valeur qui n''est pas valable (type, dates, nombres) : vérifiez-la.');
  end;
  perform public.auditer(case when p_id is null then 'bienvenue.creation' else 'bienvenue.modification' end, 'programme', b.id::text,
                         v_avant, to_jsonb(b) - 'maj_par' - 'conditions');
  return to_jsonb(b) - 'maj_par';
end;
$$;

-- Ce qui manque à une campagne pour être publiée (liste de phrases, vide si elle est complète)
create or replace function public.bienvenue_manques(b public.campagnes_bienvenue)
returns text[]
language plpgsql
stable
set search_path = ''
as $$
declare
  m text[] := '{}';
begin
  if length(trim(b.nom)) < 2 then m := array_append(m, 'le nom'::text); end if;
  if b.debut is null then m := array_append(m, 'la date de début'::text); end if;
  if b.fin is null then m := array_append(m, 'la date de fin'::text); end if;
  if b.type_recompense is null then m := array_append(m, 'le type de récompense'::text); end if;
  if b.valeur_recompense is null then m := array_append(m, 'la valeur de la récompense'::text); end if;
  if b.operation is null then m := array_append(m, 'l''opération qualifiante'::text); end if;
  if length(trim(b.conditions)) < 10 then m := array_append(m, 'les conditions générales (visibles par le client)'::text); end if;
  if b.fin is not null and b.fin < public.aujourdhui_entreprise() then m := array_append(m, 'une date de fin qui n''est pas déjà passée'::text); end if;
  if b.type_recompense = 'gopoints' and not exists (select 1 from public.points_reglages where id and actif) then
    m := array_append(m, 'le programme GOPOINTS allumé (la récompense est en points)'::text);
  end if;
  return m;
end;
$$;

create or replace function public.bienvenue_publier(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  b public.campagnes_bienvenue;
  m text[];
begin
  perform public.exiger_permission('programs.manage');
  select * into b from public.campagnes_bienvenue where id = p_id for update;
  if not found then
    perform public.erreur_metier('INVALID_CAMPAIGN', 'Cette campagne n''existe pas.');
  end if;
  if b.statut not in ('brouillon', 'suspendue') then
    perform public.erreur_metier('INVALID_CAMPAIGN_STATUS', 'Seul un brouillon ou une campagne suspendue se publie.');
  end if;
  m := public.bienvenue_manques(b);
  if cardinality(m) > 0 then
    perform public.erreur_metier('INCOMPLETE_CAMPAIGN', 'La campagne est incomplète : il manque ' || array_to_string(m, ', ') || '.');
  end if;
  update public.campagnes_bienvenue
     set statut = case when debut > public.aujourdhui_entreprise() then 'programmee' else 'active' end, maj_le = now(), maj_par = auth.uid()
   where id = p_id returning * into b;
  perform public.auditer('bienvenue.publication', 'programme', b.id::text, null, jsonb_build_object('statut', b.statut));
  return to_jsonb(b) - 'maj_par';
end;
$$;

create or replace function public.bienvenue_statut(p_id uuid, p_action text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  b public.campagnes_bienvenue;
  v_nouveau text;
begin
  perform public.exiger_permission('programs.manage');
  select * into b from public.campagnes_bienvenue where id = p_id for update;
  if not found then
    perform public.erreur_metier('INVALID_CAMPAIGN', 'Cette campagne n''existe pas.');
  end if;
  v_nouveau := case when p_action = 'suspendre' and b.statut in ('active', 'programmee') then 'suspendue'
                    when p_action = 'terminer' and b.statut in ('active', 'programmee', 'suspendue') then 'terminee'
                    else null end;
  if p_action = 'reprendre' then
    return public.bienvenue_publier(p_id);
  end if;
  if v_nouveau is null then
    perform public.erreur_metier('INVALID_CAMPAIGN_STATUS', 'Cette action n''est pas possible dans l''état actuel de la campagne.');
  end if;
  update public.campagnes_bienvenue set statut = v_nouveau, maj_le = now(), maj_par = auth.uid() where id = p_id returning * into b;
  perform public.auditer('bienvenue.' || p_action, 'programme', b.id::text, null, jsonb_build_object('statut', b.statut));
  return to_jsonb(b) - 'maj_par';
end;
$$;

create or replace function public.bienvenue_liste()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_fuseau text;
begin
  perform public.exiger_permission('programs.view');
  perform public.campagnes_maj_statuts();
  select fuseau into v_fuseau from public.programme_reglages where id;
  return jsonb_build_object(
    'campagnes', coalesce((
      select jsonb_agg(to_jsonb(b) - 'maj_par' || jsonb_build_object(
               'manques', to_jsonb(public.bienvenue_manques(b)),
               'clients_admissibles', (select count(*) from public.clients c where c.role = 'client' and c.supprime_le is null
                                         and b.debut is not null and b.fin is not null
                                         and (c.cree_le at time zone coalesce(v_fuseau, 'America/Santo_Domingo'))::date between b.debut and b.fin),
               'recompenses', (select jsonb_object_agg(s.statut, s.n) from (
                                 select r.statut, count(*) as n from public.recompenses r
                                  where r.programme = 'welcome' and r.campagne = b.id::text group by r.statut) s)) order by b.cree_le desc)
        from public.campagnes_bienvenue b), '[]'::jsonb),
    'erreurs', (select count(*) from public.programmes_erreurs where programme in ('compte', 'operation', 'recompense')));
end;
$$;

-- Parrainage : la configuration, comme une campagne
create or replace function public.parrainage_config_lire()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.parrainage_config;
begin
  perform public.exiger_permission('programs.view');
  perform public.campagnes_maj_statuts();
  select * into c from public.parrainage_config where id;
  return to_jsonb(c) - 'maj_par' || jsonb_build_object('manques', to_jsonb(public.parrainage_manques(c)));
end;
$$;

create or replace function public.parrainage_manques(c public.parrainage_config)
returns text[]
language plpgsql
stable
set search_path = ''
as $$
declare
  m text[] := '{}';
begin
  if c.debut is null then m := array_append(m, 'la date de début'::text); end if;
  if c.fin is null then m := array_append(m, 'la date de fin'::text); end if;
  if c.parrain_type is null or c.parrain_valeur is null then m := array_append(m, 'l''avantage du parrain (type et valeur)'::text); end if;
  if c.filleul_type is null or c.filleul_valeur is null then m := array_append(m, 'l''avantage du filleul (type et valeur)'::text); end if;
  if c.operation is null then m := array_append(m, 'la transaction qualifiante'::text); end if;
  if length(trim(c.conditions)) < 10 then m := array_append(m, 'les conditions générales (visibles par le client)'::text); end if;
  if length(trim(c.annulation)) < 10 then m := array_append(m, 'les conditions d''annulation'::text); end if;
  if c.fin is not null and c.fin < public.aujourdhui_entreprise() then m := array_append(m, 'une date de fin qui n''est pas déjà passée'::text); end if;
  if 'gopoints' in (c.parrain_type, c.filleul_type) and not exists (select 1 from public.points_reglages where id and actif) then
    m := array_append(m, 'le programme GOPOINTS allumé (un avantage est en points)'::text);
  end if;
  return m;
end;
$$;

create or replace function public.parrainage_config_modifier(p_donnees jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  d jsonb := coalesce(p_donnees, '{}'::jsonb);
  c public.parrainage_config;
  v_avant jsonb;
begin
  perform public.exiger_permission('programs.manage');
  select * into c from public.parrainage_config where id for update;
  if c.statut in ('active', 'terminee') then
    perform public.erreur_metier('CAMPAIGN_LOCKED', 'Le parrainage actif ou terminé ne se modifie pas : suspendez-le d''abord.');
  end if;
  v_avant := to_jsonb(c) - 'maj_par' - 'conditions' - 'annulation';
  begin
    update public.parrainage_config set
      nom = case when d ? 'nom' then left(trim(coalesce(d ->> 'nom', '')), 80) else nom end,
      debut = case when d ? 'debut' then nullif(d ->> 'debut', '')::date else debut end,
      fin = case when d ? 'fin' then nullif(d ->> 'fin', '')::date else fin end,
      parrain_type = case when d ? 'parrain_type' then nullif(d ->> 'parrain_type', '') else parrain_type end,
      parrain_valeur = case when d ? 'parrain_valeur' then nullif(d ->> 'parrain_valeur', '')::numeric else parrain_valeur end,
      filleul_type = case when d ? 'filleul_type' then nullif(d ->> 'filleul_type', '') else filleul_type end,
      filleul_valeur = case when d ? 'filleul_valeur' then nullif(d ->> 'filleul_valeur', '')::numeric else filleul_valeur end,
      operation = case when d ? 'operation' then nullif(d ->> 'operation', '') else operation end,
      delai_validation_jours = case when d ? 'delai_validation_jours' then coalesce(public.lire_entier_programme(d, 'delai_validation_jours', 0, 90), 0) else delai_validation_jours end,
      max_recompenses = case when d ? 'max_recompenses' then public.lire_entier_programme(d, 'max_recompenses', 1, 10000000) else max_recompenses end,
      max_par_parrain = case when d ? 'max_par_parrain' then public.lire_entier_programme(d, 'max_par_parrain', 1, 100000) else max_par_parrain end,
      cumul_bienvenue = case when d ? 'cumul_bienvenue' then (d ->> 'cumul_bienvenue')::boolean else cumul_bienvenue end,
      expiration_jours = case when d ? 'expiration_jours' then public.lire_entier_programme(d, 'expiration_jours', 1, 3650) else expiration_jours end,
      conditions = case when d ? 'conditions' then left(coalesce(d ->> 'conditions', ''), 4000) else conditions end,
      annulation = case when d ? 'annulation' then left(coalesce(d ->> 'annulation', ''), 2000) else annulation end,
      maj_le = now(), maj_par = auth.uid()
     where id returning * into c;
  exception when check_violation or invalid_text_representation or invalid_datetime_format or numeric_value_out_of_range then
    perform public.erreur_metier('INVALID_CAMPAIGN', 'La configuration contient une valeur qui n''est pas valable (type, dates, nombres) : vérifiez-la.');
  end;
  perform public.auditer('parrainage.configuration', 'programme', 'parrainage', v_avant, to_jsonb(c) - 'maj_par' - 'conditions' - 'annulation');
  return to_jsonb(c) - 'maj_par';
end;
$$;

create or replace function public.parrainage_statut(p_action text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.parrainage_config;
  m text[];
  v_nouveau text;
begin
  perform public.exiger_permission('programs.manage');
  select * into c from public.parrainage_config where id for update;
  if p_action in ('publier', 'reprendre') then
    if c.statut not in ('brouillon', 'suspendue') then
      perform public.erreur_metier('INVALID_CAMPAIGN_STATUS', 'Seul un brouillon ou un parrainage suspendu se publie.');
    end if;
    m := public.parrainage_manques(c);
    if cardinality(m) > 0 then
      perform public.erreur_metier('INCOMPLETE_CAMPAIGN', 'Le parrainage est incomplet : il manque ' || array_to_string(m, ', ') || '.');
    end if;
    v_nouveau := case when c.debut > public.aujourdhui_entreprise() then 'programmee' else 'active' end;
  elsif p_action = 'suspendre' and c.statut in ('active', 'programmee') then
    v_nouveau := 'suspendue';
  elsif p_action = 'terminer' and c.statut in ('active', 'programmee', 'suspendue') then
    v_nouveau := 'terminee';
  else
    perform public.erreur_metier('INVALID_CAMPAIGN_STATUS', 'Cette action n''est pas possible dans l''état actuel du parrainage.');
  end if;
  update public.parrainage_config set statut = v_nouveau, maj_le = now(), maj_par = auth.uid() where id returning * into c;
  perform public.auditer('parrainage.' || p_action, 'programme', 'parrainage', null, jsonb_build_object('statut', c.statut));
  return to_jsonb(c) - 'maj_par';
end;
$$;

create or replace function public.parrainage_apercu(p_debut date default null, p_fin date default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_fuseau text;
  v_debut timestamptz;
  v_fin timestamptz;
begin
  perform public.exiger_permission('programs.view');
  perform public.campagnes_maj_statuts();
  select fuseau into v_fuseau from public.programme_reglages where id;
  v_fuseau := coalesce(v_fuseau, 'America/Santo_Domingo');
  v_debut := case when p_debut is null then '-infinity'::timestamptz else p_debut::timestamp at time zone v_fuseau end;
  v_fin := case when p_fin is null then 'infinity'::timestamptz else (p_fin + 1)::timestamp at time zone v_fuseau end;
  return jsonb_build_object(
    'statut', (select statut from public.parrainage_config where id),
    'parrains', (select count(distinct parrain_id) from public.parrainages where cree_le >= v_debut and cree_le < v_fin),
    'filleuls_inscrits', (select count(*) from public.parrainages where cree_le >= v_debut and cree_le < v_fin),
    'transactions_qualifiantes', (select count(*) from public.parrainages where qualifie_le >= v_debut and qualifie_le < v_fin),
    'recompenses_accordees', (select count(*) from public.recompenses where programme in ('refer_parrain', 'refer_filleul')
                               and statut in ('obtenue', 'utilisee') and cree_le >= v_debut and cree_le < v_fin),
    'recompenses_en_attente', (select count(*) from public.recompenses where programme in ('refer_parrain', 'refer_filleul') and statut = 'en_attente'),
    'suspects', (select count(*) from public.parrainages where statut = 'suspect'),
    'en_attente_premiere_operation', (select count(*) from public.parrainages where statut = 'inscrit'),
    'par_statut', coalesce((select jsonb_object_agg(s.statut, s.n) from (
                              select statut, count(*) as n from public.parrainages
                               where cree_le >= v_debut and cree_le < v_fin group by statut) s), '{}'::jsonb));
end;
$$;

-- La liste des parrainages avec les deux comptes (code et nom) : pour l'équipe habilitée seulement
create or replace function public.parrainages_liste(p_statut text default '', p_debut date default null, p_fin date default null,
                                                    p_page integer default 0, p_par_page integer default 50)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_fuseau text;
  v_debut timestamptz;
  v_fin timestamptz;
  v_par_page integer := least(greatest(coalesce(p_par_page, 50), 1), 200);
  v_page integer := greatest(coalesce(p_page, 0), 0);
begin
  perform public.exiger_permission('programs.view');
  if coalesce(p_statut, '') not in ('', 'inscrit', 'qualifie', 'recompense', 'refuse', 'annule', 'suspect') then
    perform public.erreur_metier('INVALID_FILTER', 'Filtre inconnu.');
  end if;
  select fuseau into v_fuseau from public.programme_reglages where id;
  v_fuseau := coalesce(v_fuseau, 'America/Santo_Domingo');
  v_debut := case when p_debut is null then '-infinity'::timestamptz else p_debut::timestamp at time zone v_fuseau end;
  v_fin := case when p_fin is null then 'infinity'::timestamptz else (p_fin + 1)::timestamp at time zone v_fuseau end;
  return (
    with lignes as (
      select pa.*, pc.code as parrain_code, pc.nom_complet as parrain_nom, fc.code as filleul_code, fc.nom_complet as filleul_nom
        from public.parrainages pa
        join public.clients pc on pc.id = pa.parrain_id join public.clients fc on fc.id = pa.filleul_id
       where (coalesce(p_statut, '') = '' or pa.statut = p_statut) and pa.cree_le >= v_debut and pa.cree_le < v_fin)
    select jsonb_build_object(
      'total', (select count(*) from lignes),
      'elements', coalesce((
        select jsonb_agg(jsonb_build_object('id', l.id, 'statut', l.statut, 'motif', l.motif, 'source', l.source, 'date', l.cree_le,
                                            'qualifie_le', l.qualifie_le, 'parrain_code', l.parrain_code, 'parrain_nom', l.parrain_nom,
                                            'filleul_code', l.filleul_code, 'filleul_nom', l.filleul_nom) order by l.cree_le desc, l.id desc)
          from (select * from lignes order by cree_le desc, id desc limit v_par_page offset v_page * v_par_page) l), '[]'::jsonb)));
end;
$$;

-- Examiner un parrainage suspect : valider (il reprend son cours) ou refuser. Un motif, journalisé.
create or replace function public.parrainage_examiner(p_id bigint, p_decision text, p_motif text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  pa public.parrainages;
  v_operation text;
begin
  perform public.exiger_permission('programs.manage');
  if length(trim(coalesce(p_motif, ''))) < 3 then
    perform public.erreur_metier('REASON_REQUIRED', 'Un motif est obligatoire pour examiner un parrainage.');
  end if;
  if p_decision not in ('valider', 'refuser') then
    perform public.erreur_metier('INVALID_DECISION', 'La décision est « valider » ou « refuser ».');
  end if;
  select * into pa from public.parrainages where id = p_id for update;
  if not found or pa.statut <> 'suspect' then
    perform public.erreur_metier('INVALID_REFERRAL', 'Seul un parrainage suspect peut être examiné.');
  end if;
  update public.parrainages
     set statut = case when p_decision = 'valider' then 'inscrit' else 'refuse' end,
         motif = left(trim(p_motif), 200), examine_par = auth.uid(), maj_le = now()
   where id = p_id returning * into pa;
  perform public.auditer('parrainage.examen', 'programme', p_id::text, null,
                         jsonb_build_object('decision', p_decision, 'motif', left(trim(p_motif), 200)));
  -- Validé : si le filleul a déjà fait son opération qualifiante, le parrainage reprend où il s'était arrêté
  if p_decision = 'valider' then
    select operation into v_operation from public.parrainage_config where id;
    if exists (select 1 from public.programme_operations where client_id = pa.filleul_id and operation = v_operation and annulee_le is null) then
      perform public.parrainage_reprendre(pa.id);
    end if;
  end if;
  return jsonb_build_object('id', pa.id, 'statut', pa.statut);
end;
$$;

-- Reprend un parrainage validé après examen, avec l'opération qualifiante que le filleul avait déjà faite
create or replace function public.parrainage_reprendre(p_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  pa public.parrainages;
  c public.parrainage_config;
  v_operation record;
begin
  select * into pa from public.parrainages where id = p_id and statut = 'inscrit' for update;
  select * into c from public.parrainage_config where id;
  if not found or c.statut <> 'active' then
    return;
  end if;
  select * into v_operation from public.programme_operations
   where client_id = pa.filleul_id and operation = c.operation and annulee_le is null order by id limit 1;
  if not found then
    return;
  end if;
  update public.parrainages set statut = 'qualifie', qualifie_le = now(), maj_le = now() where id = pa.id;
  if c.cumul_bienvenue or not exists (select 1 from public.recompenses where client_id = pa.filleul_id and programme = 'welcome'
                                       and statut in ('en_attente', 'obtenue', 'utilisee')) then
    perform public.recompense_creer(pa.filleul_id, 'refer_filleul', c.filleul_type, c.filleul_valeur,
                                    'refer:' || pa.id || ':filleul', 'parrainage', v_operation.reference, c.delai_validation_jours, c.expiration_jours);
  end if;
  perform public.recompense_creer(pa.parrain_id, 'refer_parrain', c.parrain_type, c.parrain_valeur,
                                  'refer:' || pa.id || ':parrain', 'parrainage', v_operation.reference, c.delai_validation_jours, c.expiration_jours);
  perform public.parrainage_actualiser(pa.id);
end;
$$;

-- Les avantages de tous les programmes (bienvenue, parrainage, anniversaire, points, manuel)
create or replace function public.recompenses_liste(p_programme text default '', p_statut text default '', p_page integer default 0, p_par_page integer default 50)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_par_page integer := least(greatest(coalesce(p_par_page, 50), 1), 200);
  v_page integer := greatest(coalesce(p_page, 0), 0);
begin
  perform public.exiger_permission('programs.view');
  return (
    with lignes as (
      select r.*, c.code as client_code, c.nom_complet as client_nom from public.recompenses r join public.clients c on c.id = r.client_id
       where (coalesce(p_programme, '') = '' or r.programme = p_programme) and (coalesce(p_statut, '') = '' or r.statut = p_statut))
    select jsonb_build_object(
      'total', (select count(*) from lignes),
      'elements', coalesce((
        select jsonb_agg(jsonb_build_object('id', l.id, 'client_code', l.client_code, 'client_nom', l.client_nom, 'programme', l.programme,
                                            'type', l.type, 'valeur', l.valeur, 'statut', l.statut, 'motif', l.motif, 'date', l.cree_le,
                                            'valide_apres', l.valide_apres, 'expire_le', l.expire_le, 'reference', l.reference)
                         order by l.cree_le desc)
          from (select * from lignes order by cree_le desc limit v_par_page offset v_page * v_par_page) l), '[]'::jsonb)));
end;
$$;

-- Accorder un avantage à la main : un motif, journalisé ; en points, il entre dans le registre
create or replace function public.recompense_accorder(p_client uuid, p_type text, p_valeur numeric, p_motif text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform public.exiger_permission('points.adjust');
  if length(trim(coalesce(p_motif, ''))) < 3 then
    perform public.erreur_metier('REASON_REQUIRED', 'Un motif est obligatoire pour accorder un avantage à la main.');
  end if;
  if p_type not in ('credit_expedition', 'reduction_frais', 'bonus_fixe', 'gopoints', 'avantage_colis') or p_valeur is null or p_valeur <= 0 then
    perform public.erreur_metier('INVALID_REWARD', 'Le type et la valeur de l''avantage sont obligatoires (valeur positive).');
  end if;
  if not exists (select 1 from public.clients where id = p_client and role = 'client' and supprime_le is null) then
    perform public.erreur_metier('CLIENT_NOT_FOUND', 'Client introuvable.');
  end if;
  v_id := public.recompense_creer(p_client, 'manuel', p_type, p_valeur, 'manuel:' || gen_random_uuid(), 'manuel', '', 0);
  update public.recompenses set motif = left(trim(p_motif), 200), auteur_id = auth.uid() where id = v_id;
  perform public.auditer('recompense.accordee', 'client', p_client::text, null,
                         jsonb_build_object('recompense', v_id, 'type', p_type, 'valeur', p_valeur, 'motif', left(trim(p_motif), 200)));
  return jsonb_build_object('id', v_id, 'statut', (select statut from public.recompenses where id = v_id));
end;
$$;

create or replace function public.recompense_annuler(p_id uuid, p_motif text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.recompenses;
  g public.points_mouvements;
begin
  perform public.exiger_permission('points.adjust');
  if length(trim(coalesce(p_motif, ''))) < 3 then
    perform public.erreur_metier('REASON_REQUIRED', 'Un motif est obligatoire pour annuler un avantage.');
  end if;
  select * into r from public.recompenses where id = p_id for update;
  if not found or r.statut not in ('en_attente', 'obtenue') then
    perform public.erreur_metier('INVALID_REWARD', 'Seul un avantage en attente ou obtenu, pas encore utilisé, peut être annulé.');
  end if;
  if r.type = 'gopoints' then
    select * into g from public.points_mouvements where cle = 'gain:recompense:' || r.id;
    if found and not exists (select 1 from public.points_mouvements where annule_id = g.id) then
      -- les points retirés : si le client les a déjà utilisés, l'équipe corrige son solde avec un motif
      perform public.points_ecrire(r.client_id, 'annulation', -g.points, 'admin', 'recompense:' || r.id, 'annul:' || g.id,
                                   trim(p_motif), auth.uid(), null, g.id);
    end if;
  end if;
  update public.recompenses set statut = 'annulee', motif = left(trim(p_motif), 200), auteur_id = auth.uid(), maj_le = now() where id = p_id;
  perform public.recompense_prevenir(p_id, 'reward_cancelled');
  if r.cle like 'refer:%' then
    perform public.parrainage_actualiser(split_part(r.cle, ':', 2)::bigint);
  end if;
  perform public.auditer('recompense.annulee', 'client', r.client_id::text, null,
                         jsonb_build_object('recompense', p_id, 'motif', left(trim(p_motif), 200)));
  return jsonb_build_object('id', p_id, 'statut', 'annulee');
end;
$$;

create or replace function public.programmes_erreurs_liste(p_page integer default 0, p_par_page integer default 50)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_par_page integer := least(greatest(coalesce(p_par_page, 50), 1), 200);
  v_page integer := greatest(coalesce(p_page, 0), 0);
begin
  perform public.exiger_permission('programs.view');
  return jsonb_build_object(
    'total', (select count(*) from public.programmes_erreurs),
    'elements', coalesce((
      select jsonb_agg(jsonb_build_object('date', e.cree_le, 'programme', e.programme, 'evenement', e.evenement,
                                          'client_code', c.code, 'message', e.message) order by e.cree_le desc)
        from (select * from public.programmes_erreurs order by cree_le desc limit v_par_page offset v_page * v_par_page) e
        left join public.clients c on c.id = e.client_id), '[]'::jsonb));
end;
$$;


-- 10. Le travail du jour, droits, contrôle ------------------------------------------------------------------------------
-- Chaque jour : les statuts des campagnes, les avantages dont le délai est passé (acquis si l'opération est toujours valable,
-- annulés sinon), les avantages expirés, et les points qui attendaient leur programme.
create or replace function public.campagnes_quotidien()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_jour date := public.aujourdhui_entreprise();
  v_valides integer := 0;
  v_annules integer := 0;
  v_expires integer;
begin
  if not pg_try_advisory_xact_lock(hashtext('goship-campagnes')) then
    return jsonb_build_object('occupe', true);
  end if;
  perform public.campagnes_maj_statuts();
  for r in select id, reference, cle from public.recompenses
            where statut = 'en_attente' and (valide_apres is null or valide_apres <= v_jour) order by cree_le loop
    begin
      if public.operation_valable(r.reference) then
        if public.recompense_finaliser(r.id) then v_valides := v_valides + 1; end if;
      else
        update public.recompenses set statut = 'annulee', motif = 'OPERATION_ANNULEE', maj_le = now() where id = r.id;
        perform public.recompense_prevenir(r.id, 'reward_cancelled');
        v_annules := v_annules + 1;
      end if;
      if r.cle like 'refer:%' then
        perform public.parrainage_actualiser(split_part(r.cle, ':', 2)::bigint);
        -- Les points d'un parrainage validé après délai (si l'avantage du parrain n'est pas en points)
        perform public.points_attribuer(pa.parrain_id, 'referral_validated', 'parrainage:' || pa.id)
           from public.parrainages pa join public.parrainage_config c on c.id
          where pa.id = split_part(r.cle, ':', 2)::bigint and pa.statut = 'recompense' and c.parrain_type <> 'gopoints';
      end if;
    exception when others then
      perform public.programmes_noter_erreur('recompense', 'quotidien', null, sqlerrm);
    end;
  end loop;
  update public.recompenses set statut = 'expiree', maj_le = now() where statut = 'obtenue' and expire_le < v_jour;
  get diagnostics v_expires = row_count;
  return jsonb_build_object('valides', v_valides, 'annules', v_annules, 'expires', v_expires);
end;
$$;

do $planif$
begin
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise notice 'pg_cron indisponible (%). Activez-le : Database > Extensions > pg_cron, puis relancez ce fichier.', sqlerrm;
  end;
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('goship-campagnes', '25 11 * * *', 'select public.campagnes_quotidien()');
  end if;
end;
$planif$;

-- Droits : le moteur est fermé à tous les comptes ; les fonctions du client et de l'équipe, aux comptes connectés
revoke execute on function public.texte_recompense(text, numeric, text) from public, anon, authenticated;
revoke execute on function public.campagnes_maj_statuts() from public, anon, authenticated;
revoke execute on function public.programmes_noter_erreur(text, text, uuid, text) from public, anon, authenticated;
revoke execute on function public.points_gain_campagne(uuid, text, text, integer) from public, anon, authenticated;
revoke execute on function public.recompense_prevenir(uuid, text) from public, anon, authenticated;
revoke execute on function public.recompense_finaliser(uuid) from public, anon, authenticated;
revoke execute on function public.recompense_creer(uuid, text, text, numeric, text, text, text, integer, integer) from public, anon, authenticated;
revoke execute on function public.operation_valable(text) from public, anon, authenticated;
revoke execute on function public.programmes_operation(uuid, text, text) from public, anon, authenticated;
revoke execute on function public.parrainage_actualiser(bigint) from public, anon, authenticated;
revoke execute on function public.programmes_operation_annulee(text) from public, anon, authenticated;
revoke execute on function public.programmes_compte_cree() from public, anon, authenticated;
revoke execute on function public.programmes_etape_colis() from public, anon, authenticated;
revoke execute on function public.programmes_evenement_facturation() from public, anon, authenticated;
revoke execute on function public.code_parrainage_de(uuid) from public, anon, authenticated;
revoke execute on function public.parrainage_rattacher(uuid, text, text, boolean) from public, anon, authenticated;
revoke execute on function public.parrainage_reprendre(bigint) from public, anon, authenticated;
revoke execute on function public.bienvenue_manques(public.campagnes_bienvenue) from public, anon, authenticated;
revoke execute on function public.parrainage_manques(public.parrainage_config) from public, anon, authenticated;
revoke execute on function public.campagnes_quotidien() from public, anon, authenticated;
revoke execute on function public.ma_bienvenue() from public, anon;
revoke execute on function public.mon_parrainage() from public, anon;
revoke execute on function public.noter_invitation(text) from public, anon;
revoke execute on function public.utiliser_code_parrainage(text) from public, anon;
revoke execute on function public.bienvenue_enregistrer(uuid, jsonb) from public, anon;
revoke execute on function public.bienvenue_publier(uuid) from public, anon;
revoke execute on function public.bienvenue_statut(uuid, text) from public, anon;
revoke execute on function public.bienvenue_liste() from public, anon;
revoke execute on function public.parrainage_config_lire() from public, anon;
revoke execute on function public.parrainage_config_modifier(jsonb) from public, anon;
revoke execute on function public.parrainage_statut(text) from public, anon;
revoke execute on function public.parrainage_apercu(date, date) from public, anon;
revoke execute on function public.parrainages_liste(text, date, date, integer, integer) from public, anon;
revoke execute on function public.parrainage_examiner(bigint, text, text) from public, anon;
revoke execute on function public.recompenses_liste(text, text, integer, integer) from public, anon;
revoke execute on function public.recompense_accorder(uuid, text, numeric, text) from public, anon;
revoke execute on function public.recompense_annuler(uuid, text) from public, anon;
revoke execute on function public.programmes_erreurs_liste(integer, integer) from public, anon;
grant execute on function public.ma_bienvenue() to authenticated;
grant execute on function public.mon_parrainage() to authenticated;
grant execute on function public.noter_invitation(text) to authenticated;
grant execute on function public.utiliser_code_parrainage(text) to authenticated;
grant execute on function public.bienvenue_enregistrer(uuid, jsonb) to authenticated;
grant execute on function public.bienvenue_publier(uuid) to authenticated;
grant execute on function public.bienvenue_statut(uuid, text) to authenticated;
grant execute on function public.bienvenue_liste() to authenticated;
grant execute on function public.parrainage_config_lire() to authenticated;
grant execute on function public.parrainage_config_modifier(jsonb) to authenticated;
grant execute on function public.parrainage_statut(text) to authenticated;
grant execute on function public.parrainage_apercu(date, date) to authenticated;
grant execute on function public.parrainages_liste(text, date, date, integer, integer) to authenticated;
grant execute on function public.parrainage_examiner(bigint, text, text) to authenticated;
grant execute on function public.recompenses_liste(text, text, integer, integer) to authenticated;
grant execute on function public.recompense_accorder(uuid, text, numeric, text) to authenticated;
grant execute on function public.recompense_annuler(uuid, text) to authenticated;
grant execute on function public.programmes_erreurs_liste(integer, integer) to authenticated;

-- tables : 9 ; modeles : 12 ; declencheurs : 3 ; ouvertes_aux_visiteurs : false ; tables_fermees : true ; brouillons : true.
select (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relname in ('campagnes_bienvenue', 'parrainage_config', 'codes_parrainage', 'parrainages',
              'parrainage_invitations', 'programme_operations', 'programmes_erreurs', 'recompenses', 'notification_modeles')) as tables,
       (select count(*) from public.notification_modeles where type in ('reward_pending', 'reward_earned', 'reward_cancelled')) as modeles,
       (select count(*) from pg_trigger where tgname in ('programmes_compte_cree', 'programmes_etape_colis', 'programmes_evenement_facturation')
          and not tgisinternal)                                                                                                   as declencheurs,
       (select coalesce(bool_or(has_function_privilege('anon', p.oid, 'execute')), false)
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('ma_bienvenue', 'mon_parrainage', 'utiliser_code_parrainage', 'bienvenue_liste', 'parrainage_config_lire',
                            'recompense_accorder', 'recompense_annuler', 'programmes_operation', 'parrainage_rattacher'))   as ouvertes_aux_visiteurs,
       not has_table_privilege('authenticated', 'public.parrainages', 'select')
         and not has_table_privilege('authenticated', 'public.campagnes_bienvenue', 'select')
         and not has_table_privilege('authenticated', 'public.codes_parrainage', 'select')                                       as tables_fermees,
       (select statut = 'brouillon' from public.parrainage_config where id)
         and not exists (select 1 from public.campagnes_bienvenue where statut <> 'brouillon')                                   as brouillons;
