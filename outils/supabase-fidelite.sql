-- =============================================================================
-- Goship Express — GOPOINTS : le programme de fidélité (19/10/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : ce fichier
-- AJOUTE des tables et des fonctions. Il ne change aucune donnée existante, ne
-- touche ni aux colis, ni aux factures, ni aux paiements, et peut être relancé
-- autant de fois qu'on veut (les règles déjà réglées par l'équipe sont gardées).
--
-- Ordre d'installation : après supabase-naissance.sql (voir outils/migrations.txt).
--
-- AUCUNE valeur commerciale n'est inventée ici. Le programme naît ÉTEINT, et chaque
-- règle naît à 0 point, éteinte : le nombre de points de chaque événement, la durée de
-- validité, les offres échangeables et leur coût sont saisis par un administrateur
-- (permission programs.manage). Rien n'est accordé tant qu'ils ne le sont pas.
--
-- Le principe : un REGISTRE, pas un compteur.
--   · points_mouvements est le registre : un gain, une utilisation, une expiration, une
--     correction ou une annulation = une ligne, avec sa source, sa date, son auteur et
--     une clé unique. Une ligne ne se modifie ni ne se supprime jamais (déclencheur) :
--     on corrige par une ligne de plus, avec un motif. Le solde n'est jamais écrit
--     à la main.
--   · points_soldes ne garde que le solde courant, tenu par un déclencheur, et sert de
--     verrou : deux utilisations simultanées des mêmes points passent l'une après l'autre,
--     la seconde voit le solde déjà entamé. Un solde négatif est refusé deux fois : par
--     la fonction (INSUFFICIENT_POINTS) et par une contrainte de la table.
--   · La clé unique d'un mouvement (« gain:<événement>:<référence> ») fait qu'un événement
--     rejoué — deux travailleurs, un double clic, une requête répétée — n'accorde qu'une fois.
--   · Les points ne s'accordent que pour un fait que la base a vu (un colis reçu, une facture
--     payée, un parrainage validé…), jamais parce qu'un écran s'ouvre ou se recharge.
--   · Les tables n'ont aucun accès direct : ni le site, ni l'application, ni un employé ne
--     les lisent ou ne les écrivent. Tout passe par des fonctions qui vérifient la permission.
--
-- Permissions (supabase.sql, permissions_du_role) :
--   programs.view    lire les règles, les offres, les chiffres et les mouvements
--   programs.manage  régler le programme, les règles et les offres
--   points.adjust    corriger ou annuler un mouvement (motif obligatoire, journalisé)
-- Un employé, un client ou un visiteur est refusé par chaque fonction d'équipe.
--
-- Contenu :
--    1. garde : la chaîne est-elle à jour ?
--    2. réglages et règles
--    3. le registre et les soldes
--    4. les offres échangeables et les avantages (récompenses qui ne sont pas des points)
--    5. écrire dans le registre (interne) et accorder des points (interne)
--    6. le client : son portefeuille, utiliser ses points
--    7. l'équipe : règles, offres, corrections, annulations, chiffres
--    8. l'expiration (planifiée)
--    9. droits
--   10. contrôle
-- =============================================================================


-- 1. Garde ------------------------------------------------------------------------
do $garde$
begin
  if to_regprocedure('public.aujourdhui_entreprise()') is null
     or to_regprocedure('public.valider_date_naissance(text)') is null
     or to_regprocedure('public.erreur_metier(text, text)') is null
     or to_regprocedure('public.auditer(text, text, text, jsonb, jsonb)') is null
     or to_regprocedure('public.exiger_permission(text, uuid)') is null
     or not ('points.adjust' = any (public.permissions_du_role('admin'))) then
    raise exception 'Base incomplète : exécutez d''abord toute la chaîne (outils/migrations.txt) jusqu''à supabase-naissance.sql, puis ce fichier.';
  end if;
end;
$garde$;


-- 2. Réglages et règles ---------------------------------------------------------------
-- Une seule ligne. Le programme naît éteint : tant qu'il l'est, aucun point n'est accordé
-- et le portefeuille ne montre pas d'offre.
create table if not exists public.points_reglages (
  id               boolean primary key default true check (id),
  actif            boolean not null default false,
  expiration_jours integer check (expiration_jours is null or expiration_jours between 1 and 3650),
  conditions       text not null default '',
  maj_le           timestamptz not null default now(),
  maj_par          uuid
);
insert into public.points_reglages (id) values (true) on conflict (id) do nothing;
alter table public.points_reglages enable row level security;
revoke all on public.points_reglages from anon, authenticated;

-- Une règle par événement qui peut rapporter des points. Les noms des événements sont stables
-- et en anglais ; les libellés affichés se traduisent à part.
--   account_created      création du compte
--   first_operation      première opération qualifiante (la définition est dans « operation »)
--   repeat_operation     opérations suivantes
--   referral_validated   parrainage validé (GOship Refer, supabase-campagnes.sql)
--   campaign             campagne promotionnelle de l'application
--   birthday             anniversaire du client (supabase-anniversaires.sql)
create table if not exists public.points_regles (
  evenement        text primary key
                   check (evenement in ('account_created', 'first_operation', 'repeat_operation',
                                        'referral_validated', 'campaign', 'birthday')),
  libelle          text not null default '',
  points           integer not null default 0 check (points between 0 and 1000000),
  actif            boolean not null default false,
  operation        text check (operation is null or operation in ('colis_recu', 'facture_payee')),
  limite_jour      integer check (limite_jour is null or limite_jour > 0),
  limite_mois      integer check (limite_mois is null or limite_mois > 0),
  limite_client    integer check (limite_client is null or limite_client > 0),
  expiration_jours integer check (expiration_jours is null or expiration_jours between 1 and 3650),
  conditions       text not null default '',
  maj_le           timestamptz not null default now(),
  maj_par          uuid,
  -- Une règle allumée a des points ; une opération qualifiante, une opération définie
  check (not actif or points > 0),
  check (not actif or evenement not in ('first_operation', 'repeat_operation') or operation is not null)
);
insert into public.points_regles (evenement, libelle) values
  ('account_created',    'Création du compte'),
  ('first_operation',    'Première opération qualifiante'),
  ('repeat_operation',   'Opérations répétées'),
  ('referral_validated', 'Parrainage validé'),
  ('campaign',           'Campagne promotionnelle'),
  ('birthday',           'Anniversaire du client')
on conflict (evenement) do nothing;
alter table public.points_regles enable row level security;
revoke all on public.points_regles from anon, authenticated;


-- 3. Le registre et les soldes --------------------------------------------------------------
create table if not exists public.points_mouvements (
  id         bigint generated always as identity primary key,
  client_id  uuid not null references public.clients (id),
  type       text not null check (type in ('gain', 'utilisation', 'expiration', 'correction', 'annulation')),
  points     integer not null check (points <> 0),
  source     text not null default '',        -- l'événement, « offre », « expiration », « admin »
  reference  text not null default '',        -- ce qui l'a causé (numéro de colis, de facture…)
  cle        text not null unique,            -- idempotence : un événement, un mouvement
  motif      text not null default '',        -- obligatoire pour une correction ou une annulation
  auteur_id  uuid,                            -- le compte de l'équipe, pour une correction
  expire_le  date,                            -- seulement pour un gain
  annule_id  bigint references public.points_mouvements (id),
  offre_id   uuid,
  cree_le    timestamptz not null default now(),
  check ((type = 'gain' and points > 0)
         or (type in ('utilisation', 'expiration') and points < 0)
         or type in ('correction', 'annulation')),
  check (type not in ('correction', 'annulation') or length(trim(motif)) >= 3),
  check (type <> 'annulation' or annule_id is not null),
  check (expire_le is null or type = 'gain')
);
create index if not exists points_mouvements_client_idx on public.points_mouvements (client_id, cree_le desc, id desc);
create index if not exists points_mouvements_source_idx on public.points_mouvements (source, cree_le desc);
-- Une annulation par mouvement, au plus
create unique index if not exists points_mouvements_annule_idx on public.points_mouvements (annule_id) where annule_id is not null;
alter table public.points_mouvements enable row level security;
revoke all on public.points_mouvements from anon, authenticated;

-- Un mouvement ne se modifie ni ne s'efface, ni par une page, ni par une fonction, ni à la main :
-- on corrige par un mouvement de plus.
create or replace function public.points_mouvement_immuable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform public.erreur_metier('LEDGER_IMMUTABLE',
    'Le registre des GOPOINTS ne se modifie pas : une erreur se corrige par une correction ou une annulation, avec un motif.');
  return null;
end;
$$;
drop trigger if exists points_mouvement_immuable on public.points_mouvements;
create trigger points_mouvement_immuable
  before update or delete on public.points_mouvements
  for each row execute function public.points_mouvement_immuable();
drop trigger if exists points_mouvement_immuable_vider on public.points_mouvements;
create trigger points_mouvement_immuable_vider
  before truncate on public.points_mouvements
  for each statement execute function public.points_mouvement_immuable();

-- Le solde courant : tenu par le déclencheur, jamais écrit à la main. Il sert aussi de verrou.
create table if not exists public.points_soldes (
  client_id uuid primary key references public.clients (id),
  solde     integer not null default 0 check (solde >= 0),
  maj_le    timestamptz not null default now()
);
alter table public.points_soldes enable row level security;
revoke all on public.points_soldes from anon, authenticated;

create or replace function public.points_maj_solde()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.points_soldes set solde = solde + new.points, maj_le = now() where client_id = new.client_id;
  return null;
end;
$$;
drop trigger if exists points_maj_solde on public.points_mouvements;
create trigger points_maj_solde
  after insert on public.points_mouvements
  for each row execute function public.points_maj_solde();

-- Le solde ne se touche que par ce déclencheur : un UPDATE direct est refusé
create or replace function public.points_solde_verrou()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and pg_trigger_depth() < 2 then
    perform public.erreur_metier('LEDGER_IMMUTABLE', 'Le solde de points ne se modifie pas à la main.');
  end if;
  return new;
end;
$$;
drop trigger if exists points_solde_verrou on public.points_soldes;
create trigger points_solde_verrou
  before update on public.points_soldes
  for each row execute function public.points_solde_verrou();


-- 4. Les offres échangeables et les avantages -----------------------------------------------
-- Le catalogue : vide tant que l'équipe n'y met rien. Une offre dit ce qu'elle coûte en points et
-- ce qu'elle donne ; aucune équivalence en argent n'est supposée.
create table if not exists public.points_offres (
  id            uuid primary key default gen_random_uuid(),
  nom           text not null check (length(trim(nom)) between 2 and 80),
  description   text not null default '',
  cout_points   integer not null check (cout_points > 0),
  type          text not null check (type in ('credit_expedition', 'reduction_frais', 'bonus_fixe', 'avantage_colis')),
  valeur        numeric(10, 2) not null check (valeur >= 0),
  actif         boolean not null default false,
  stock         integer check (stock is null or stock >= 0),     -- null : illimité
  limite_client integer check (limite_client is null or limite_client > 0),
  debut         date,
  fin           date,
  conditions    text not null default '',
  cree_le       timestamptz not null default now(),
  maj_le        timestamptz not null default now(),
  maj_par       uuid,
  check (debut is null or fin is null or debut <= fin)
);
alter table public.points_offres enable row level security;
revoke all on public.points_offres from anon, authenticated;

-- Les avantages accordés qui ne sont pas des points : un crédit d'expédition, une réduction sur les
-- frais de service, un bonus fixe, un avantage sur un prochain colis. Cette table les ENREGISTRE
-- (une ligne, une clé unique, un statut) ; l'équipe les applique à la facture à la main : aucune
-- règle de facturation n'est modifiée. Voir docs/programmes.md.
--   en_attente  décidé, pas encore définitif (délai de validation d'un parrainage)
--   obtenue     acquis : le client peut s'en prévaloir
--   utilisee    appliqué par l'équipe à une facture
--   annulee     retiré (opération annulée ou remboursée, correction)
--   expiree     plus valable
create table if not exists public.recompenses (
  id          uuid primary key default gen_random_uuid(),
  client_id   uuid not null references public.clients (id),
  programme   text not null check (programme in ('welcome', 'refer_parrain', 'refer_filleul', 'anniversaire', 'points', 'manuel')),
  type        text not null check (type in ('gopoints', 'credit_expedition', 'reduction_frais', 'bonus_fixe', 'avantage_colis')),
  valeur      numeric(10, 2) not null check (valeur >= 0),
  statut      text not null default 'en_attente' check (statut in ('en_attente', 'obtenue', 'utilisee', 'annulee', 'expiree')),
  cle         text not null unique,
  campagne    text not null default '',
  reference   text not null default '',
  motif       text not null default '',
  expire_le   date,
  auteur_id   uuid,
  cree_le     timestamptz not null default now(),
  maj_le      timestamptz not null default now()
);
create index if not exists recompenses_client_idx on public.recompenses (client_id, cree_le desc);
create index if not exists recompenses_statut_idx on public.recompenses (programme, statut);
alter table public.recompenses enable row level security;
revoke all on public.recompenses from anon, authenticated;


-- 5. Écrire dans le registre, accorder des points ---------------------------------------------
-- Internes : aucun compte ne les appelle. Les fonctions de la partie 6 et 7 les utilisent.

-- Le seul chemin d'écriture du registre. Verrouille le solde du client, refuse un solde négatif,
-- et ne fait rien si la clé existe déjà (rend alors null).
create or replace function public.points_ecrire(p_client uuid, p_type text, p_points integer, p_source text,
                                                p_reference text, p_cle text, p_motif text default '',
                                                p_auteur uuid default null, p_expire date default null,
                                                p_annule bigint default null, p_offre uuid default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_solde integer;
  v_id bigint;
begin
  if p_client is null or not exists (select 1 from public.clients where id = p_client) then
    perform public.erreur_metier('CLIENT_NOT_FOUND', 'Client introuvable.');
  end if;
  insert into public.points_soldes (client_id) values (p_client) on conflict (client_id) do nothing;
  -- Le verrou : les opérations d'un même client passent l'une après l'autre
  select solde into v_solde from public.points_soldes where client_id = p_client for update;
  if exists (select 1 from public.points_mouvements where cle = p_cle) then
    return null;   -- déjà fait pour cet événement
  end if;
  if v_solde + p_points < 0 then
    perform public.erreur_metier('INSUFFICIENT_POINTS', 'Le solde de points ne suffit pas.');
  end if;
  insert into public.points_mouvements (client_id, type, points, source, reference, cle, motif, auteur_id, expire_le, annule_id, offre_id)
  values (p_client, p_type, p_points, coalesce(p_source, ''), coalesce(p_reference, ''), p_cle, coalesce(p_motif, ''),
          p_auteur, p_expire, p_annule, p_offre)
  returning id into v_id;
  return v_id;
end;
$$;

-- Accorder les points d'un événement, selon sa règle. Rend l'identifiant du mouvement, ou null :
--   programme éteint, règle éteinte ou à 0 point, déjà accordé pour cette référence, ou une limite
--   (par jour, par mois, par client) atteinte. Ne lève jamais d'erreur pour une raison commerciale :
--   un événement qui n'a pas droit aux points n'est pas une erreur de l'opération qui l'a causé.
-- p_points : à renseigner seulement pour une campagne dont le nombre de points est propre (sinon, la règle).
create or replace function public.points_attribuer(p_client uuid, p_evenement text, p_reference text,
                                                   p_points integer default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  g public.points_reglages;
  r public.points_regles;
  v_points integer;
  v_jour date := public.aujourdhui_entreprise();
  v_duree integer;
  v_fuseau text;
begin
  select * into g from public.points_reglages where id;
  select * into r from public.points_regles where evenement = p_evenement;
  if not found or not g.actif or not r.actif then
    return null;
  end if;
  v_points := coalesce(p_points, r.points);
  if v_points is null or v_points <= 0 then
    return null;
  end if;
  select fuseau into v_fuseau from public.programme_reglages where id;
  -- Les limites se comptent en jours et en mois de Santo Domingo
  if r.limite_jour is not null and (
       select count(*) from public.points_mouvements m
        where m.client_id = p_client and m.type = 'gain' and m.source = p_evenement
          and (m.cree_le at time zone coalesce(v_fuseau, 'America/Santo_Domingo'))::date = v_jour) >= r.limite_jour then
    return null;
  end if;
  if r.limite_mois is not null and (
       select count(*) from public.points_mouvements m
        where m.client_id = p_client and m.type = 'gain' and m.source = p_evenement
          and date_trunc('month', m.cree_le at time zone coalesce(v_fuseau, 'America/Santo_Domingo'))
              = date_trunc('month', v_jour::timestamp)) >= r.limite_mois then
    return null;
  end if;
  if r.limite_client is not null and (
       select count(*) from public.points_mouvements m
        where m.client_id = p_client and m.type = 'gain' and m.source = p_evenement) >= r.limite_client then
    return null;
  end if;
  v_duree := coalesce(r.expiration_jours, g.expiration_jours);
  return public.points_ecrire(p_client, 'gain', v_points, p_evenement, coalesce(p_reference, ''),
                              'gain:' || p_evenement || ':' || coalesce(p_reference, ''),
                              '', null, case when v_duree is null then null else v_jour + v_duree end);
end;
$$;


-- 6. Le client : son portefeuille, ses points ------------------------------------------------
-- Le compte connecté, et lui seul : aucun paramètre ne désigne un autre compte.
create or replace function public.mon_portefeuille(p_page integer default 0, p_par_page integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_moi uuid := auth.uid();
  v_par_page integer := least(greatest(coalesce(p_par_page, 20), 1), 100);
  v_page integer := greatest(coalesce(p_page, 0), 0);
  g public.points_reglages;
begin
  if v_moi is null then
    perform public.erreur_metier('PERMISSION_DENIED', 'Connectez-vous pour voir vos GOPOINTS.');
  end if;
  select * into g from public.points_reglages where id;
  return jsonb_build_object(
    'actif', g.actif,
    'conditions', case when g.actif then g.conditions else '' end,
    'solde', coalesce((select solde from public.points_soldes where client_id = v_moi), 0),
    'gagnes', coalesce((select sum(points) from public.points_mouvements where client_id = v_moi and points > 0), 0),
    'utilises', coalesce((select -sum(points) from public.points_mouvements where client_id = v_moi and type = 'utilisation'), 0),
    'expires', coalesce((select -sum(points) from public.points_mouvements where client_id = v_moi and type = 'expiration'), 0),
    'total', (select count(*) from public.points_mouvements where client_id = v_moi),
    'elements', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', m.id, 'type', m.type, 'points', m.points, 'source', m.source, 'date', m.cree_le,
               'expire_le', m.expire_le,
               'statut', case when exists (select 1 from public.points_mouvements a where a.annule_id = m.id)
                              then 'annule' else 'valide' end)
             order by m.cree_le desc, m.id desc)
        from (select * from public.points_mouvements where client_id = v_moi
               order by cree_le desc, id desc limit v_par_page offset v_page * v_par_page) m), '[]'::jsonb),
    'offres', case when g.actif then coalesce((
      select jsonb_agg(jsonb_build_object('id', o.id, 'nom', o.nom, 'description', o.description,
                                          'cout_points', o.cout_points, 'type', o.type, 'valeur', o.valeur,
                                          'fin', o.fin, 'conditions', o.conditions)
                       order by o.cout_points, o.nom)
        from public.points_offres o
       where o.actif and (o.debut is null or o.debut <= public.aujourdhui_entreprise())
         and (o.fin is null or o.fin >= public.aujourdhui_entreprise())
         and (o.stock is null or o.stock > 0)), '[]'::jsonb) else '[]'::jsonb end);
end;
$$;

-- Échanger des points contre une offre. p_cle : une clé que l'application tire une fois par appui
-- (un double clic ou une requête répétée n'échange qu'une fois). Validé ici, jamais dans la page :
-- programme allumé, offre valable, stock, limite par client, solde suffisant — le solde est
-- verrouillé, donc deux échanges simultanés ne dépassent jamais le solde.
create or replace function public.utiliser_points(p_offre uuid, p_cle uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_moi uuid := auth.uid();
  g public.points_reglages;
  o public.points_offres;
  v_cle text;
  v_mouvement bigint;
  v_recompense uuid;
  v_deja jsonb;
  v_existe boolean;
begin
  if v_moi is null or not exists (select 1 from public.clients where id = v_moi and supprime_le is null) then
    perform public.erreur_metier('PERMISSION_DENIED', 'Connectez-vous pour utiliser vos GOPOINTS.');
  end if;
  if p_cle is null then
    perform public.erreur_metier('INVALID_REQUEST', 'Requête incomplète.');
  end if;
  v_cle := 'use:' || v_moi || ':' || p_cle;

  -- Le verrou de l'offre d'abord : le stock, la limite par client et les requêtes répétées se
  -- comptent l'un après l'autre
  select * into o from public.points_offres where id = p_offre for update;
  v_existe := found;

  -- Même clé : la requête répétée (double clic, coupure, deux appels en même temps) rend l'échange
  -- déjà fait, sans rien débiter
  select jsonb_build_object('deja', true, 'recompense', r.id, 'valeur', r.valeur, 'type', r.type)
    into v_deja from public.recompenses r where r.cle = v_cle;
  if v_deja is not null then
    return v_deja;
  end if;

  select * into g from public.points_reglages where id;
  if not g.actif then
    perform public.erreur_metier('OFFER_UNAVAILABLE', 'Le programme GOPOINTS n''est pas ouvert pour le moment.');
  end if;
  if not v_existe or not o.actif
     or (o.debut is not null and o.debut > public.aujourdhui_entreprise())
     or (o.fin is not null and o.fin < public.aujourdhui_entreprise()) then
    perform public.erreur_metier('OFFER_UNAVAILABLE', 'Cette offre n''est pas disponible.');
  end if;
  if o.stock is not null and o.stock <= 0 then
    perform public.erreur_metier('OFFER_OUT_OF_STOCK', 'Cette offre n''est plus disponible : le stock est épuisé.');
  end if;
  if o.limite_client is not null and (
       select count(*) from public.points_mouvements m
        where m.client_id = v_moi and m.type = 'utilisation' and m.offre_id = o.id
          and not exists (select 1 from public.points_mouvements a where a.annule_id = m.id)) >= o.limite_client then
    perform public.erreur_metier('OFFER_LIMIT_REACHED', 'Vous avez déjà utilisé cette offre le nombre de fois permis.');
  end if;

  v_mouvement := public.points_ecrire(v_moi, 'utilisation', -o.cout_points, 'offre', o.nom, v_cle, '', null, null, null, o.id);
  if v_mouvement is null then
    perform public.erreur_metier('DUPLICATE_OPERATION', 'Cet échange a déjà été fait.');
  end if;
  if o.stock is not null then
    update public.points_offres set stock = stock - 1, maj_le = now() where id = o.id;
  end if;
  insert into public.recompenses (client_id, programme, type, valeur, statut, cle, campagne, reference)
  values (v_moi, 'points', o.type, o.valeur, 'obtenue', v_cle, o.nom, 'mouvement:' || v_mouvement)
  returning id into v_recompense;
  return jsonb_build_object('deja', false, 'recompense', v_recompense, 'valeur', o.valeur, 'type', o.type,
                            'points', o.cout_points,
                            'solde', (select solde from public.points_soldes where client_id = v_moi));
end;
$$;

-- Mes avantages (hors points) : ce que j'ai obtenu, ce qui attend sa validation
create or replace function public.mes_recompenses()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_moi uuid := auth.uid();
begin
  if v_moi is null then
    perform public.erreur_metier('PERMISSION_DENIED', 'Connectez-vous pour voir vos avantages.');
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', r.id, 'programme', r.programme, 'type', r.type, 'valeur', r.valeur,
                                        'statut', r.statut, 'date', r.cree_le, 'expire_le', r.expire_le)
                     order by r.cree_le desc)
      from public.recompenses r where r.client_id = v_moi), '[]'::jsonb);
end;
$$;


-- 7. L'équipe ----------------------------------------------------------------------------------
-- Un nombre ou null depuis un jsonb, avec une phrase claire si ce n'en est pas un
create or replace function public.lire_entier_programme(p_donnees jsonb, p_cle text, p_min integer, p_max integer)
returns integer
language plpgsql
stable
set search_path = ''
as $$
declare
  v text := p_donnees ->> p_cle;
begin
  if v is null or trim(v) = '' then
    return null;
  end if;
  if v !~ '^-?[0-9]{1,9}$' or v::integer < p_min or v::integer > p_max then
    perform public.erreur_metier('INVALID_PROGRAM_VALUE',
      'La valeur « ' || p_cle || ' » doit être un nombre entier entre ' || p_min || ' et ' || p_max || '.');
  end if;
  return v::integer;
end;
$$;

create or replace function public.points_regles_liste()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.exiger_permission('programs.view');
  return jsonb_build_object(
    'reglages', (select to_jsonb(g) - 'maj_par' from public.points_reglages g where id),
    'regles', coalesce((select jsonb_agg(to_jsonb(r) - 'maj_par' order by r.evenement) from public.points_regles r), '[]'::jsonb),
    'offres', coalesce((select jsonb_agg(to_jsonb(o) - 'maj_par' order by o.cree_le) from public.points_offres o), '[]'::jsonb));
end;
$$;

create or replace function public.points_reglages_modifier(p_donnees jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  avant public.points_reglages;
  apres public.points_reglages;
  v_actif boolean;
  v_duree integer;
begin
  perform public.exiger_permission('programs.manage');
  p_donnees := coalesce(p_donnees, '{}'::jsonb);
  select * into avant from public.points_reglages where id for update;
  v_actif := case when p_donnees ? 'actif' then (p_donnees ->> 'actif')::boolean else avant.actif end;
  v_duree := case when p_donnees ? 'expiration_jours' then public.lire_entier_programme(p_donnees, 'expiration_jours', 1, 3650)
                  else avant.expiration_jours end;
  update public.points_reglages
     set actif = v_actif, expiration_jours = v_duree,
         conditions = case when p_donnees ? 'conditions' then left(coalesce(p_donnees ->> 'conditions', ''), 4000) else conditions end,
         maj_le = now(), maj_par = auth.uid()
   where id returning * into apres;
  perform public.auditer('points.reglages', 'programme', 'gopoints',
                         jsonb_build_object('actif', avant.actif, 'expiration_jours', avant.expiration_jours),
                         jsonb_build_object('actif', apres.actif, 'expiration_jours', apres.expiration_jours));
  return to_jsonb(apres) - 'maj_par';
end;
$$;

create or replace function public.points_regle_modifier(p_evenement text, p_donnees jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  avant public.points_regles;
  apres public.points_regles;
  d jsonb := coalesce(p_donnees, '{}'::jsonb);
  v_points integer;
  v_actif boolean;
  v_operation text;
begin
  perform public.exiger_permission('programs.manage');
  select * into avant from public.points_regles where evenement = p_evenement for update;
  if not found then
    perform public.erreur_metier('INVALID_RULE', 'Cet événement n''existe pas dans le programme.');
  end if;
  v_points := case when d ? 'points' then coalesce(public.lire_entier_programme(d, 'points', 0, 1000000), 0) else avant.points end;
  v_actif := case when d ? 'actif' then (d ->> 'actif')::boolean else avant.actif end;
  v_operation := case when d ? 'operation' then nullif(d ->> 'operation', '') else avant.operation end;
  if v_actif and v_points <= 0 then
    perform public.erreur_metier('INVALID_RULE', 'Une règle allumée doit accorder au moins 1 point : indiquez le nombre de points avant de l''activer.');
  end if;
  if v_actif and p_evenement in ('first_operation', 'repeat_operation') and v_operation is null then
    perform public.erreur_metier('INVALID_RULE', 'Choisissez l''opération qualifiante (colis reçu ou facture payée) avant d''activer cette règle.');
  end if;
  if v_operation is not null and v_operation not in ('colis_recu', 'facture_payee') then
    perform public.erreur_metier('INVALID_RULE', 'Opération qualifiante inconnue.');
  end if;
  update public.points_regles
     set points = v_points, actif = v_actif, operation = v_operation,
         limite_jour = case when d ? 'limite_jour' then public.lire_entier_programme(d, 'limite_jour', 1, 100000) else limite_jour end,
         limite_mois = case when d ? 'limite_mois' then public.lire_entier_programme(d, 'limite_mois', 1, 100000) else limite_mois end,
         limite_client = case when d ? 'limite_client' then public.lire_entier_programme(d, 'limite_client', 1, 100000) else limite_client end,
         expiration_jours = case when d ? 'expiration_jours' then public.lire_entier_programme(d, 'expiration_jours', 1, 3650) else expiration_jours end,
         conditions = case when d ? 'conditions' then left(coalesce(d ->> 'conditions', ''), 2000) else conditions end,
         maj_le = now(), maj_par = auth.uid()
   where evenement = p_evenement returning * into apres;
  perform public.auditer('points.regle', 'programme', p_evenement,
                         to_jsonb(avant) - 'maj_par' - 'maj_le' - 'conditions',
                         to_jsonb(apres) - 'maj_par' - 'maj_le' - 'conditions');
  return to_jsonb(apres) - 'maj_par';
end;
$$;

-- Créer (p_id null) ou modifier une offre échangeable
create or replace function public.points_offre_enregistrer(p_id uuid, p_donnees jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  d jsonb := coalesce(p_donnees, '{}'::jsonb);
  o public.points_offres;
  v_avant jsonb;
  v_valeur numeric;
  v_ancienne numeric;
begin
  perform public.exiger_permission('programs.manage');
  if p_id is not null then
    select * into o from public.points_offres where id = p_id for update;
    if not found then
      perform public.erreur_metier('INVALID_OFFER', 'Cette offre n''existe pas.');
    end if;
    v_avant := to_jsonb(o) - 'maj_par';
    v_ancienne := o.valeur;
  end if;
  begin
    v_valeur := coalesce((d ->> 'valeur')::numeric, v_ancienne);
  exception when others then
    perform public.erreur_metier('INVALID_OFFER', 'La valeur de l''offre n''est pas un nombre.');
  end;
  if p_id is null then
    if coalesce(trim(d ->> 'nom'), '') = '' or (d ->> 'cout_points') is null or (d ->> 'type') is null or (d ->> 'valeur') is null then
      perform public.erreur_metier('INVALID_OFFER', 'Une offre a un nom, un coût en points, un type et une valeur.');
    end if;
    begin
      insert into public.points_offres (nom, description, cout_points, type, valeur, actif, stock, limite_client, debut, fin, conditions, maj_par)
      values (trim(d ->> 'nom'), left(coalesce(d ->> 'description', ''), 500),
              public.lire_entier_programme(d, 'cout_points', 1, 10000000), d ->> 'type', v_valeur,
              coalesce((d ->> 'actif')::boolean, false), public.lire_entier_programme(d, 'stock', 0, 10000000),
              public.lire_entier_programme(d, 'limite_client', 1, 100000), nullif(d ->> 'debut', '')::date,
              nullif(d ->> 'fin', '')::date, left(coalesce(d ->> 'conditions', ''), 2000), auth.uid())
      returning * into o;
    exception when check_violation or invalid_text_representation or invalid_datetime_format or numeric_value_out_of_range or not_null_violation then
      perform public.erreur_metier('INVALID_OFFER', 'L''offre est incomplète ou ses valeurs ne sont pas valables (type, dates, nombres).');
    end;
  else
    begin
      update public.points_offres set
        nom = case when d ? 'nom' then trim(d ->> 'nom') else nom end,
        description = case when d ? 'description' then left(coalesce(d ->> 'description', ''), 500) else description end,
        cout_points = case when d ? 'cout_points' then public.lire_entier_programme(d, 'cout_points', 1, 10000000) else cout_points end,
        type = case when d ? 'type' then d ->> 'type' else type end,
        valeur = v_valeur,
        actif = case when d ? 'actif' then (d ->> 'actif')::boolean else actif end,
        stock = case when d ? 'stock' then public.lire_entier_programme(d, 'stock', 0, 10000000) else stock end,
        limite_client = case when d ? 'limite_client' then public.lire_entier_programme(d, 'limite_client', 1, 100000) else limite_client end,
        debut = case when d ? 'debut' then nullif(d ->> 'debut', '')::date else debut end,
        fin = case when d ? 'fin' then nullif(d ->> 'fin', '')::date else fin end,
        conditions = case when d ? 'conditions' then left(coalesce(d ->> 'conditions', ''), 2000) else conditions end,
        maj_le = now(), maj_par = auth.uid()
       where id = p_id returning * into o;
    exception when check_violation or invalid_text_representation or invalid_datetime_format or numeric_value_out_of_range or not_null_violation then
      perform public.erreur_metier('INVALID_OFFER', 'L''offre est incomplète ou ses valeurs ne sont pas valables (type, dates, nombres).');
    end;
  end if;
  perform public.auditer(case when p_id is null then 'points.offre_creation' else 'points.offre_modification' end,
                         'programme', o.id::text, v_avant, to_jsonb(o) - 'maj_par');
  return to_jsonb(o) - 'maj_par';
end;
$$;

-- Corriger un solde : un mouvement de plus, avec un motif, jamais un solde négatif
create or replace function public.points_corriger(p_client uuid, p_points integer, p_motif text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
begin
  perform public.exiger_permission('points.adjust');
  if p_points is null or p_points = 0 or abs(p_points) > 1000000 then
    perform public.erreur_metier('INVALID_POINTS', 'Indiquez un nombre de points non nul (positif pour ajouter, négatif pour retirer).');
  end if;
  if length(trim(coalesce(p_motif, ''))) < 3 then
    perform public.erreur_metier('REASON_REQUIRED', 'Un motif est obligatoire pour corriger un solde.');
  end if;
  v_id := public.points_ecrire(p_client, 'correction', p_points, 'admin', '', 'corr:' || gen_random_uuid(),
                               trim(p_motif), auth.uid());
  perform public.auditer('points.correction', 'client', p_client::text, null,
                         jsonb_build_object('mouvement', v_id, 'points', p_points, 'motif', left(trim(p_motif), 200)));
  return jsonb_build_object('mouvement', v_id, 'solde', (select solde from public.points_soldes where client_id = p_client));
end;
$$;

-- Annuler un mouvement (gain ou utilisation) : le mouvement inverse, une seule fois
create or replace function public.points_annuler_mouvement(p_id bigint, p_motif text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  m public.points_mouvements;
  v_id bigint;
begin
  perform public.exiger_permission('points.adjust');
  if length(trim(coalesce(p_motif, ''))) < 3 then
    perform public.erreur_metier('REASON_REQUIRED', 'Un motif est obligatoire pour annuler un mouvement.');
  end if;
  select * into m from public.points_mouvements where id = p_id;
  if not found or m.type not in ('gain', 'utilisation') then
    perform public.erreur_metier('INVALID_MOVEMENT', 'Seul un gain ou une utilisation peut être annulé.');
  end if;
  if exists (select 1 from public.points_mouvements where annule_id = p_id) then
    perform public.erreur_metier('MOVEMENT_ALREADY_CANCELLED', 'Ce mouvement est déjà annulé.');
  end if;
  v_id := public.points_ecrire(m.client_id, 'annulation', -m.points, 'admin', 'mouvement:' || m.id,
                               'annul:' || m.id, trim(p_motif), auth.uid(), null, m.id);
  if v_id is null then
    perform public.erreur_metier('MOVEMENT_ALREADY_CANCELLED', 'Ce mouvement est déjà annulé.');
  end if;
  if m.type = 'utilisation' and m.offre_id is not null then
    -- Les points rendus : l'avantage obtenu avec est retiré, et le stock de l'offre revient
    update public.recompenses set statut = 'annulee', motif = left(trim(p_motif), 200), maj_le = now()
     where reference = 'mouvement:' || m.id and statut in ('obtenue', 'en_attente');
    update public.points_offres set stock = stock + 1, maj_le = now() where id = m.offre_id and stock is not null;
  end if;
  perform public.auditer('points.annulation', 'client', m.client_id::text, null,
                         jsonb_build_object('mouvement', p_id, 'annulation', v_id, 'motif', left(trim(p_motif), 200)));
  return jsonb_build_object('annulation', v_id, 'solde', (select solde from public.points_soldes where client_id = m.client_id));
end;
$$;

-- Les chiffres du programme sur une période (jours de Santo Domingo ; null = tout)
create or replace function public.points_apercu(p_debut date default null, p_fin date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_fuseau text;
  v_debut timestamptz;
  v_fin timestamptz;
begin
  perform public.exiger_permission('programs.view');
  select fuseau into v_fuseau from public.programme_reglages where id;
  v_fuseau := coalesce(v_fuseau, 'America/Santo_Domingo');
  v_debut := case when p_debut is null then '-infinity'::timestamptz else p_debut::timestamp at time zone v_fuseau end;
  v_fin := case when p_fin is null then 'infinity'::timestamptz else (p_fin + 1)::timestamp at time zone v_fuseau end;
  return jsonb_build_object(
    'actif', (select actif from public.points_reglages where id),
    'solde_total', coalesce((select sum(solde) from public.points_soldes), 0),
    'clients_avec_points', (select count(*) from public.points_soldes where solde > 0),
    'gagnes', coalesce((select sum(points) from public.points_mouvements where type = 'gain' and cree_le >= v_debut and cree_le < v_fin), 0),
    'utilises', coalesce((select -sum(points) from public.points_mouvements where type = 'utilisation' and cree_le >= v_debut and cree_le < v_fin), 0),
    'expires', coalesce((select -sum(points) from public.points_mouvements where type = 'expiration' and cree_le >= v_debut and cree_le < v_fin), 0),
    'corriges', coalesce((select sum(points) from public.points_mouvements where type in ('correction', 'annulation') and cree_le >= v_debut and cree_le < v_fin), 0),
    'recompenses_utilisees', (select count(*) from public.recompenses where programme = 'points' and cree_le >= v_debut and cree_le < v_fin),
    'par_source', coalesce((
      select jsonb_object_agg(s.source, s.total) from (
        select source, sum(points) as total from public.points_mouvements
         where type = 'gain' and cree_le >= v_debut and cree_le < v_fin group by source) s), '{}'::jsonb));
end;
$$;

-- Les mouvements, avec le client (code et nom) : l'historique complet pour l'équipe habilitée
create or replace function public.points_mouvements_liste(p_recherche text default '', p_type text default '',
                                                          p_debut date default null, p_fin date default null,
                                                          p_page integer default 0, p_par_page integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_fuseau text;
  v_debut timestamptz;
  v_fin timestamptz;
  v_par_page integer := least(greatest(coalesce(p_par_page, 50), 1), 200);
  v_page integer := greatest(coalesce(p_page, 0), 0);
  v_texte text := '%' || lower(trim(coalesce(p_recherche, ''))) || '%';
begin
  perform public.exiger_permission('programs.view');
  select fuseau into v_fuseau from public.programme_reglages where id;
  v_fuseau := coalesce(v_fuseau, 'America/Santo_Domingo');
  v_debut := case when p_debut is null then '-infinity'::timestamptz else p_debut::timestamp at time zone v_fuseau end;
  v_fin := case when p_fin is null then 'infinity'::timestamptz else (p_fin + 1)::timestamp at time zone v_fuseau end;
  return (
    with filtres as (
      select m.*, c.code as client_code, c.nom_complet as client_nom
        from public.points_mouvements m join public.clients c on c.id = m.client_id
       where m.cree_le >= v_debut and m.cree_le < v_fin
         and (coalesce(p_type, '') = '' or m.type = p_type)
         and (trim(coalesce(p_recherche, '')) = '' or lower(coalesce(c.code, '')) like v_texte
              or lower(c.nom_complet) like v_texte or lower(m.source) like v_texte or lower(m.reference) like v_texte))
    select jsonb_build_object(
      'total', (select count(*) from filtres),
      'elements', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', f.id, 'client_id', f.client_id, 'client_code', f.client_code, 'client_nom', f.client_nom,
                 'type', f.type, 'points', f.points, 'source', f.source, 'reference', f.reference, 'motif', f.motif,
                 'date', f.cree_le, 'expire_le', f.expire_le,
                 'statut', case when exists (select 1 from public.points_mouvements a where a.annule_id = f.id)
                                then 'annule' else 'valide' end)
               order by f.cree_le desc, f.id desc)
          from (select * from filtres order by cree_le desc, id desc limit v_par_page offset v_page * v_par_page) f), '[]'::jsonb)));
end;
$$;


-- 8. L'expiration ----------------------------------------------------------------------------------
-- Les points d'un gain dont la date est passée, et qui n'ont pas déjà servi, s'éteignent. L'ordre
-- d'usage est celui des dates d'expiration (les plus proches d'abord : le client ne perd jamais des
-- points qu'il aurait pu utiliser avant). Les points sans date (corrections positives) ne s'éteignent
-- jamais. Un mouvement « expiration » par client et par jour : relancée, la fonction ne fait rien de plus.
create or replace function public.points_expirer(p_jour date default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_jour date := coalesce(p_jour, public.aujourdhui_entreprise());
  c record;
  v_nb integer := 0;
  v_total integer := 0;
  v_a_eteindre integer;
begin
  if not pg_try_advisory_xact_lock(hashtext('goship-points-expiration')) then
    return jsonb_build_object('clients', 0, 'points', 0, 'occupe', true);
  end if;
  for c in select distinct m.client_id from public.points_mouvements m
            where m.type = 'gain' and m.expire_le < v_jour loop
    -- le verrou du client, comme pour toute écriture du registre
    insert into public.points_soldes (client_id) values (c.client_id) on conflict (client_id) do nothing;
    perform 1 from public.points_soldes where client_id = c.client_id for update;
    with lots as (
      select m.id, m.points, m.expire_le,
             sum(m.points) over (order by coalesce(m.expire_le, date '9999-12-31'), m.cree_le, m.id
                                 rows between unbounded preceding and 1 preceding) as avant
        from public.points_mouvements m
       where m.client_id = c.client_id and m.points > 0),
    consomme as (
      select coalesce(-sum(points), 0) as total from public.points_mouvements
       where client_id = c.client_id and points < 0)
    select coalesce(sum(greatest(0, l.points - greatest(0, (select total from consomme) - coalesce(l.avant, 0)))), 0)
      into v_a_eteindre
      from lots l where l.expire_le < v_jour;
    if v_a_eteindre > 0 then
      if public.points_ecrire(c.client_id, 'expiration', -v_a_eteindre, 'expiration', v_jour::text,
                              'exp:' || c.client_id || ':' || v_jour) is not null then
        v_nb := v_nb + 1;
        v_total := v_total + v_a_eteindre;
      end if;
    end if;
  end loop;
  return jsonb_build_object('clients', v_nb, 'points', v_total);
end;
$$;

-- Planifié chaque jour à 11 h 20 UTC (7 h 20 à Santo Domingo), comme les notifications du jour.
-- Sans pg_cron (Database > Extensions), rien ne s'éteint : relancer ce fichier une fois l'extension activée.
do $planif$
begin
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise notice 'pg_cron indisponible (%). Activez-le : Database > Extensions > pg_cron, puis relancez ce fichier.', sqlerrm;
  end;
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('goship-points-expiration', '20 11 * * *', 'select public.points_expirer()');
  end if;
end;
$planif$;


-- 9. Droits ---------------------------------------------------------------------------------------------
revoke execute on function public.points_mouvement_immuable() from public, anon, authenticated;
revoke execute on function public.points_maj_solde() from public, anon, authenticated;
revoke execute on function public.points_solde_verrou() from public, anon, authenticated;
revoke execute on function public.points_ecrire(uuid, text, integer, text, text, text, text, uuid, date, bigint, uuid) from public, anon, authenticated;
revoke execute on function public.points_attribuer(uuid, text, text, integer) from public, anon, authenticated;
revoke execute on function public.points_expirer(date) from public, anon, authenticated;
revoke execute on function public.lire_entier_programme(jsonb, text, integer, integer) from public, anon, authenticated;
revoke execute on function public.mon_portefeuille(integer, integer) from public, anon;
revoke execute on function public.utiliser_points(uuid, uuid) from public, anon;
revoke execute on function public.mes_recompenses() from public, anon;
revoke execute on function public.points_regles_liste() from public, anon;
revoke execute on function public.points_reglages_modifier(jsonb) from public, anon;
revoke execute on function public.points_regle_modifier(text, jsonb) from public, anon;
revoke execute on function public.points_offre_enregistrer(uuid, jsonb) from public, anon;
revoke execute on function public.points_corriger(uuid, integer, text) from public, anon;
revoke execute on function public.points_annuler_mouvement(bigint, text) from public, anon;
revoke execute on function public.points_apercu(date, date) from public, anon;
revoke execute on function public.points_mouvements_liste(text, text, date, date, integer, integer) from public, anon;
grant execute on function public.mon_portefeuille(integer, integer) to authenticated;
grant execute on function public.utiliser_points(uuid, uuid) to authenticated;
grant execute on function public.mes_recompenses() to authenticated;
grant execute on function public.points_regles_liste() to authenticated;
grant execute on function public.points_reglages_modifier(jsonb) to authenticated;
grant execute on function public.points_regle_modifier(text, jsonb) to authenticated;
grant execute on function public.points_offre_enregistrer(uuid, jsonb) to authenticated;
grant execute on function public.points_corriger(uuid, integer, text) to authenticated;
grant execute on function public.points_annuler_mouvement(bigint, text) to authenticated;
grant execute on function public.points_apercu(date, date) to authenticated;
grant execute on function public.points_mouvements_liste(text, text, date, date, integer, integer) to authenticated;


-- 10. Contrôle -----------------------------------------------------------------------------------------------
-- tables : 7 ; regles : 6 ; ouvertes_aux_visiteurs : false ; tables_fermees : true ; programme_eteint : true.
select (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relname in ('points_reglages', 'points_regles', 'points_mouvements',
              'points_soldes', 'points_offres', 'recompenses', 'programme_reglages'))                     as tables,
       (select count(*) from public.points_regles)                                                        as regles,
       (select coalesce(bool_or(has_function_privilege('anon', p.oid, 'execute')), false)
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('mon_portefeuille', 'utiliser_points', 'mes_recompenses', 'points_regles_liste',
                            'points_corriger', 'points_annuler_mouvement', 'points_ecrire', 'points_attribuer')) as ouvertes_aux_visiteurs,
       not has_table_privilege('authenticated', 'public.points_mouvements', 'select')
         and not has_table_privilege('authenticated', 'public.points_soldes', 'select')
         and not has_table_privilege('authenticated', 'public.recompenses', 'select')                    as tables_fermees,
       not (select actif from public.points_reglages where id)
         and not exists (select 1 from public.points_regles where actif)                                 as programme_eteint;
