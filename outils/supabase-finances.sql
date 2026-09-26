-- =============================================================================
-- Goship Express — les finances : paiements, soldes, annulations (Phase 5, 26/09/2026)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier (bouton « Copy raw file » sur GitHub) > Run. Sans risque : aucune
-- facture n'est supprimée ni recalculée, aucun montant existant ne change, et
-- le script peut être relancé autant de fois qu'on veut.
--
-- Ordre d'installation : supabase.sql, supabase-facturation.sql,
-- supabase-services.sql, supabase-evenements.sql, supabase-scanner.sql, puis
-- ce fichier. Après une mise à jour de l'un d'eux, relancez aussi celui-ci.
--
-- Ce qui existait : une facture portait un seul chiffre, « montant déjà payé »,
-- que le tableau de bord écrivait directement, et un bouton « Marquer payée ».
-- Un acompte de 25 $ puis un second de 20 $ ne laissaient aucune trace ; deux
-- clics simultanés pouvaient faire payer plus que dû ; une facture pouvait
-- être supprimée, et son numéro revenir un jour sur une autre.
--
-- Ce qui change :
--
--   1. Chaque paiement est une ligne de la table « paiements » : montant,
--      moyen, référence, date, qui l'a saisi. Un paiement ne se modifie ni ne
--      s'efface ; une erreur s'annule, avec son motif, et reste visible.
--   2. Le montant payé et le statut d'une facture SUIVENT ses paiements : la
--      base les recalcule à chaque paiement ou annulation, sous verrou. Le
--      tableau de bord ne peut plus les écrire (déclencheur garde_facture).
--   3. Le solde = total − paiements valides, calculé par la base
--      (solde_usd). L'état affiché — à payer, partielle, payée, en retard,
--      annulée — aussi (etat_paiement). Les trois statuts stockés ne changent
--      pas : « partielle » et « en retard » se déduisent, ils ne s'écrivent pas.
--   4. Une facture ne se supprime plus : elle s'annule, avec son motif. Un
--      numéro attribué ne sert jamais deux fois (registre factures_numeros).
--   5. Plusieurs factures d'un même client se regroupent en une seule : les
--      anciennes sont annulées (et pointent vers la nouvelle), la nouvelle
--      porte tous les colis et les frais de service UNE fois.
--   6. Chaque ligne garde le tarif à la livre du jour où elle a été facturée.
--   7. Un rapport d'anomalies, en lecture seule : il signale, ne corrige rien.
--   8. Les événements FACTURE_CREEE, PAIEMENT_ENREGISTRE… sont notés dans une
--      file (evenements_facturation), pour de futures notifications. Rien ne
--      les envoie encore.
--
-- Les montants payés avant ce fichier deviennent des paiements « repris »,
-- datés du jour où la facture avait été marquée payée : le total, le payé et
-- le statut de chaque ancienne facture restent exactement ce qu'ils étaient.
--
-- Contenu :
--    1. colonnes, tables et index
--    2. petites fonctions : moyens de paiement, date du jour, contexte
--    3. payé, solde et état d'une facture
--    4. le registre des numéros
--    5. la garde des factures et de leurs lignes
--    6. les paiements : règles, recalcul, journal
--    7. les fonctions du tableau de bord          (BillingService, PaymentService)
--    8. l'espace client (mes_factures)
--    9. le rapport d'anomalies
--   10. la reprise des montants déjà payés
--   11. droits et contrôle
-- =============================================================================


-- 1. Colonnes, tables et index ---------------------------------------------------

-- L'annulation d'une facture : quand, par qui, pourquoi, et — si elle a été
-- regroupée — la facture qui la remplace.
alter table public.factures add column if not exists annulee_le       timestamptz;
alter table public.factures add column if not exists annulee_par      uuid;
alter table public.factures add column if not exists motif_annulation text not null default '';
alter table public.factures add column if not exists remplacee_par    uuid references public.factures (id);

comment on column public.factures.montant_paye_usd is
  'Somme des paiements valides (table paiements), tenue à jour par la base ; ne s''écrit pas directement';
comment on column public.factures.remplacee_par is 'Facture qui reprend les colis de celle-ci (regroupement)';

-- Le tarif à la livre appliqué à la ligne, recopié du colis au moment de la
-- facture. Vide sur les lignes d'avant ce fichier dont on ne peut pas
-- l'affirmer (voir la reprise, partie 10).
alter table public.facture_lignes add column if not exists tarif_lb_usd numeric(10, 2);
comment on column public.facture_lignes.tarif_lb_usd is 'Tarif en $/lb au jour de la facture (instantané du colis)';

create index if not exists factures_statut_idx on public.factures (statut, cree_le desc);
create index if not exists factures_echeance_idx on public.factures (echeance_le) where statut = 'a_payer';


-- 2. Petites fonctions ------------------------------------------------------------

-- Les moyens de paiement acceptés. Les six du tableau de bord d'avant, plus
-- les transferts d'argent (Western Union, Unitransfer, Ria… imprimés sur la
-- facture) et « autre », qui sert aussi aux montants repris dont on ignore
-- le moyen. assets/js/api.js en garde la même liste (MOYENS_PAIEMENT).
create or replace function public.moyens_paiement()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['paypal', 'banque', 'azul', 'moncash', 'natcash', 'especes', 'transfert', 'autre']
$$;

-- « Aujourd'hui » à Santo Domingo, pas à Greenwich : une facture due le 26
-- n'est pas en retard le 26 à 21 h, heure de La Caleta.
create or replace function public.aujourdhui()
returns date
language sql
stable
set search_path = ''
as $$
  select (now() at time zone 'America/Santo_Domingo')::date
$$;

-- Les fonctions de ce fichier écrivent parfois ce que la garde refuse à tout
-- autre chemin (le payé, le statut). Elles l'annoncent par ce réglage,
-- limité à la transaction en cours — le même procédé que le moteur
-- d'événements (goship.moteur).
create or replace function public.contexte_finances()
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(current_setting('goship.finances', true), '') = 'on'
$$;

create or replace function public.contexte_reprise()
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(current_setting('goship.reprise', true), '') = 'on'
$$;

-- Les paiements : une ligne par encaissement. client_id est recopié de la
-- facture, pour que la règle de lecture du client soit simple et rapide.
create table if not exists public.paiements (
  id               uuid primary key default gen_random_uuid(),
  facture_id       uuid not null references public.factures (id) on delete cascade,
  client_id        uuid not null references public.clients (id) on delete cascade,
  montant_usd      numeric(10, 2) not null check (montant_usd > 0),
  moyen            text not null check (moyen = any (public.moyens_paiement())),
  reference        text not null default '',     -- n° de transaction, de reçu, de virement…
  paye_le          timestamptz not null default now(),
  note             text not null default '',
  origine          text not null default 'saisie'
                   check (origine in ('saisie', 'creation', 'reprise')),
  cle_idempotence  text,
  cree_par         uuid,
  cree_le          timestamptz not null default now(),
  annule_le        timestamptz,
  annule_par       uuid,
  motif_annulation text not null default ''
);

comment on table public.paiements is
  'Un encaissement par ligne. Ne se modifie ni ne se supprime : une erreur s''annule, avec son motif.';
comment on column public.paiements.origine is
  'saisie : enregistré depuis le tableau de bord ; creation : payé à la création de la facture ; reprise : montant payé d''avant la Phase 5';

create index if not exists paiements_facture_idx on public.paiements (facture_id);
create index if not exists paiements_client_idx on public.paiements (client_id, paye_le desc);
create index if not exists paiements_date_idx on public.paiements (paye_le desc) where annule_le is null;
create unique index if not exists paiements_cle_idempotence_idx
  on public.paiements (cle_idempotence) where cle_idempotence is not null;
-- Le même reçu, le même virement, ne se saisit pas deux fois sur une facture
create unique index if not exists paiements_reference_unique_idx
  on public.paiements (facture_id, moyen, lower(reference))
  where reference <> '' and annule_le is null;

-- Le registre des numéros de facture : chaque numéro attribué y reste, même si
-- sa facture disparaît avec le compte de son client. Il ne sera jamais donné
-- à une autre facture.
create table if not exists public.factures_numeros (
  numero      text primary key,
  facture_id  uuid,
  attribue_le timestamptz not null default now()
);

-- La file des événements de facturation, pour de futures notifications
-- (e-mail, WhatsApp) et pour les chiffres. Remplie par des déclencheurs ;
-- rien ne la lit encore. traite_le restera vide jusqu'au jour où un envoi
-- s'en chargera.
create table if not exists public.evenements_facturation (
  id          bigint generated always as identity primary key,
  type        text not null,          -- FACTURE_CREEE, PAIEMENT_ENREGISTRE…
  facture_id  uuid,
  paiement_id uuid,
  client_id   uuid,
  donnees     jsonb not null default '{}'::jsonb,
  cree_le     timestamptz not null default now(),
  traite_le   timestamptz
);
create index if not exists evenements_facturation_attente_idx
  on public.evenements_facturation (cree_le) where traite_le is null;

create or replace function public.noter_evenement_facturation(p_type text, p_facture uuid, p_paiement uuid,
                                                              p_client uuid, p_donnees jsonb)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.evenements_facturation (type, facture_id, paiement_id, client_id, donnees)
  values (p_type, p_facture, p_paiement, p_client, coalesce(p_donnees, '{}'::jsonb))
$$;


-- 3. Payé, solde et état ------------------------------------------------------------
-- Trois fonctions qui prennent une facture entière : Supabase les expose comme
-- des colonnes calculées (select=*,solde_usd,etat_paiement). Sans « security
-- definer » : un client ne voit que ses paiements, et la somme qu'il obtient
-- est bien celle de sa facture.

-- Le payé : la somme des paiements valides (non annulés)
create or replace function public.paye_usd(f public.factures)
returns numeric
language sql
stable
set search_path = ''
as $$
  select coalesce(sum(p.montant_usd), 0)::numeric(10, 2)
  from public.paiements p
  where p.facture_id = f.id and p.annule_le is null
$$;

-- Le solde : ce qui reste dû. Une facture annulée ne doit plus rien.
create or replace function public.solde_usd(f public.factures)
returns numeric
language sql
stable
set search_path = ''
as $$
  select case when f.statut = 'annulee' then 0::numeric(10, 2)
              else greatest(f.montant_usd - public.paye_usd(f), 0)::numeric(10, 2) end
$$;

-- L'état affiché. Le retard passe avant le « partielle » : une facture à
-- moitié payée et échue est d'abord une facture en retard.
--   annulee    statut « annulée »
--   payee      plus rien à payer
--   en_retard  échéance dépassée et solde > 0
--   partielle  une partie payée, pas d'échéance dépassée
--   a_payer    rien payé encore
create or replace function public.etat_paiement(f public.factures)
returns text
language sql
stable
set search_path = ''
as $$
  select case
           when f.statut = 'annulee' then 'annulee'
           when x.solde <= 0 then 'payee'
           when f.echeance_le is not null and f.echeance_le < public.aujourdhui() then 'en_retard'
           when x.paye > 0 then 'partielle'
           else 'a_payer'
         end
  from (select public.paye_usd(f) as paye, public.solde_usd(f) as solde) x
$$;


-- 4. Le registre des numéros -----------------------------------------------------
-- preparer_facture (supabase.sql) tire le numéro ; ce déclencheur passe juste
-- après (ordre alphabétique) et vérifie qu'il n'a jamais servi. Un numéro
-- tiré au hasard qui a déjà servi est retiré ; un numéro imposé qui a déjà
-- servi est refusé.

insert into public.factures_numeros (numero, facture_id, attribue_le)
select f.numero, f.id, f.cree_le from public.factures f where f.numero is not null
on conflict (numero) do nothing;

create or replace function public.reserver_numero_facture()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_essais int := 0;
begin
  while exists (select 1 from public.factures_numeros where numero = new.numero)
        or exists (select 1 from public.factures where numero = new.numero and id <> new.id) loop
    if new.numero !~ '^[0-9]{4}-[0-9]{2}-[0-9]{4}$' then
      perform public.erreur_metier('INVOICE_NUMBER_USED',
        'Le numéro de facture ' || new.numero || ' a déjà été attribué : un numéro ne sert qu''une fois.');
    end if;
    v_essais := v_essais + 1;
    if v_essais >= 200 then
      raise exception 'Plus de numéro de facture libre pour % .', to_char(now(), 'YYYY-MM');
    end if;
    new.numero := to_char(now(), 'YYYY-MM') || '-' || lpad(floor(random() * 10000)::int::text, 4, '0');
  end loop;
  insert into public.factures_numeros (numero, facture_id) values (new.numero, new.id);
  return new;
end;
$$;

drop trigger if exists reserver_numero_facture on public.factures;
create trigger reserver_numero_facture
  before insert on public.factures
  for each row execute function public.reserver_numero_facture();


-- 5. La garde des factures et de leurs lignes --------------------------------------
-- Le payé, le statut, le moyen et la date de paiement d'une facture suivent
-- ses paiements : seules les fonctions de ce fichier les écrivent. Ce qui
-- reste modifiable à la main : l'échéance, le lien de paiement, la note, et
-- le total d'une facture sans colis (jamais sous ce qui est déjà payé).
--
-- La garde passe avant preparer_facture et regles_facture (ordre alphabétique
-- des déclencheurs « before ») : elle juge la demande telle qu'elle arrive.

create or replace function public.garde_facture()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    -- Profondeur 1 : quelqu'un a demandé la suppression. Au-delà, c'est la
    -- disparition du compte du client (auth.users → clients → factures), que
    -- l'on ne bloque pas ici : le numéro reste de toute façon réservé.
    if pg_trigger_depth() <= 1 and not public.contexte_finances() then
      perform public.erreur_metier('INVOICE_DELETE_FORBIDDEN',
        'Une facture ne se supprime pas : annulez-la, avec son motif. Son numéro reste réservé.');
    end if;
    return old;
  end if;

  if tg_op = 'INSERT' then
    if not public.contexte_finances() then
      -- Une facture naît à payer, ou payée si elle l'est entièrement à sa
      -- création ; ce qui est payé devient aussitôt un paiement (suivre_facture).
      new.montant_paye_usd := round(coalesce(new.montant_paye_usd, 0), 2);
      if new.montant_paye_usd < 0 or new.montant_paye_usd > new.montant_usd then
        perform public.erreur_metier('INVALID_AMOUNT', 'Le montant payé dépasse le total de la facture.');
      end if;
      new.statut := case when new.montant_usd > 0 and new.montant_paye_usd >= new.montant_usd
                         then 'payee' else 'a_payer' end;
      if new.statut <> 'payee' then
        new.payee_le := null;
      end if;
      if new.montant_paye_usd = 0 then
        new.moyen := '';
      end if;
      new.annulee_le := null;
      new.annulee_par := null;
      new.motif_annulation := '';
      new.remplacee_par := null;
    end if;
    return new;
  end if;

  -- Modification
  if new.numero is distinct from old.numero then
    perform public.erreur_metier('INVOICE_LOCKED', 'Le numéro d''une facture ne change jamais.');
  end if;
  if public.contexte_finances() then
    return new;
  end if;
  if old.statut = 'annulee' and new is distinct from old then
    perform public.erreur_metier('INVOICE_LOCKED', 'Une facture annulée ne se modifie plus.');
  end if;
  if new.statut is distinct from old.statut then
    if new.statut = 'annulee' then
      perform public.erreur_metier('INVOICE_LOCKED',
        'Une facture s''annule par « Annuler la facture », avec son motif.');
    end if;
    perform public.erreur_metier('PAYMENT_REQUIRED',
      'Le statut d''une facture suit ses paiements : enregistrez un paiement.');
  end if;
  if new.montant_paye_usd is distinct from old.montant_paye_usd
     or new.moyen is distinct from old.moyen
     or new.payee_le is distinct from old.payee_le then
    perform public.erreur_metier('PAYMENT_REQUIRED',
      'Le montant payé d''une facture est la somme de ses paiements : enregistrez un paiement.');
  end if;
  if new.annulee_le is distinct from old.annulee_le
     or new.annulee_par is distinct from old.annulee_par
     or new.motif_annulation is distinct from old.motif_annulation
     or new.remplacee_par is distinct from old.remplacee_par
     or new.cle_idempotence is distinct from old.cle_idempotence then
    perform public.erreur_metier('INVOICE_LOCKED', 'Cette partie de la facture ne se modifie pas.');
  end if;
  -- Nouveau total d'une facture sans colis (regles_facture refuse déjà le
  -- reste) : l'état payé se recalcule avec lui.
  if new.montant_usd is distinct from old.montant_usd then
    if new.montant_usd < old.montant_paye_usd then
      perform public.erreur_metier('INVALID_AMOUNT',
        'Le nouveau total est inférieur à ce qui est déjà payé (' || old.montant_paye_usd || ' $).');
    end if;
    new.statut := case when new.montant_usd > 0 and new.montant_paye_usd >= new.montant_usd
                       then 'payee' else 'a_payer' end;
    new.payee_le := case when new.statut = 'payee' then coalesce(old.payee_le, now()) end;
  end if;
  return new;
end;
$$;

drop trigger if exists garde_facture on public.factures;
create trigger garde_facture
  before insert or update or delete on public.factures
  for each row execute function public.garde_facture();

-- Après l'écriture d'une facture : marquer qu'elle est née dans cette
-- transaction (seule une facture neuve reçoit des lignes), transformer ce qui
-- est payé à sa création en paiement, et noter les événements.
create or replace function public.suivre_facture()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    perform set_config('goship.fn_' || replace(new.id::text, '-', ''), 'on', true);
    if not public.contexte_reprise() then
      perform public.noter_evenement_facturation('FACTURE_CREEE', new.id, null, new.client_id,
        jsonb_build_object('numero', new.numero, 'montant_usd', new.montant_usd));
    end if;
    if new.montant_paye_usd > 0 then
      insert into public.paiements (facture_id, client_id, montant_usd, moyen, paye_le, note, origine, cree_par)
      values (new.id, new.client_id, new.montant_paye_usd,
              case when new.moyen = any (public.moyens_paiement()) then new.moyen else 'autre' end,
              coalesce(new.payee_le, now()), 'Payé à la création de la facture.', 'creation', auth.uid());
    end if;
    return null;
  end if;

  if new.statut is distinct from old.statut then
    if new.statut = 'annulee' then
      perform public.noter_evenement_facturation('FACTURE_ANNULEE', new.id, null, new.client_id,
        jsonb_build_object('numero', new.numero, 'motif', new.motif_annulation));
    elsif new.statut = 'payee' then
      perform public.noter_evenement_facturation('FACTURE_PAYEE', new.id, null, new.client_id,
        jsonb_build_object('numero', new.numero, 'montant_usd', new.montant_usd));
    end if;
  end if;
  return null;
end;
$$;

drop trigger if exists suivre_facture on public.factures;
create trigger suivre_facture
  after insert or update on public.factures
  for each row execute function public.suivre_facture();

-- Les lignes d'une facture émise ne bougent plus : ni ajout, ni retrait, ni
-- changement. Une ligne ne s'ajoute qu'à une facture née dans la même
-- transaction (creer_facture, facturer_colis). À l'ajout, le tarif du colis
-- est recopié sur la ligne. Passe après regles_facture_ligne (ordre
-- alphabétique), qui a déjà fixé le montant.
create or replace function public.verrou_facture_ligne()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    if pg_trigger_depth() <= 1 and not public.contexte_finances() then
      perform public.erreur_metier('INVOICE_LOCKED',
        'Une ligne de facture émise ne se retire pas : annulez la facture, ou regroupez-la.');
    end if;
    return old;
  end if;

  if tg_op = 'INSERT' then
    if not public.contexte_finances()
       and coalesce(current_setting('goship.fn_' || replace(new.facture_id::text, '-', ''), true), '') <> 'on' then
      perform public.erreur_metier('INVOICE_LOCKED',
        'Une facture émise ne reçoit plus de colis : créez-en une nouvelle, ou regroupez les factures.');
    end if;
    if new.colis_id is not null then
      new.tarif_lb_usd := (select c.tarif_lb_usd from public.colis c where c.id = new.colis_id);
    end if;
    return new;
  end if;

  if public.contexte_finances() or public.contexte_reprise() then
    return new;
  end if;
  -- Le colis supprimé depuis : sa clé étrangère vide la ligne (profondeur > 1)
  if pg_trigger_depth() > 1 and new.colis_id is null and old.colis_id is not null
     and row(new.facture_id, new.montant_usd, new.libelle) is not distinct from row(old.facture_id, old.montant_usd, old.libelle) then
    return new;
  end if;
  if row(new.facture_id, new.colis_id, new.libelle, new.montant_usd, new.quantite, new.poids_lb, new.tarif_lb_usd)
     is distinct from row(old.facture_id, old.colis_id, old.libelle, old.montant_usd, old.quantite, old.poids_lb, old.tarif_lb_usd) then
    perform public.erreur_metier('INVOICE_LOCKED', 'Une ligne de facture émise ne se modifie pas.');
  end if;
  return new;
end;
$$;

drop trigger if exists verrou_facture_ligne on public.facture_lignes;
create trigger verrou_facture_ligne
  before insert or update or delete on public.facture_lignes
  for each row execute function public.verrou_facture_ligne();


-- 6. Les paiements -------------------------------------------------------------------
-- Toutes les règles d'un paiement vivent ici, quel que soit le chemin : la
-- facture est verrouillée, puis on vérifie qu'elle existe, qu'elle n'est pas
-- annulée, et que le montant ne dépasse pas ce qui reste dû. Deux paiements
-- de 50 $ sur une facture de 75 $, envoyés au même instant, passent donc
-- l'un après l'autre : le second voit le premier et est refusé.

create or replace function public.regles_paiement()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  f public.factures;
  v_paye numeric;
begin
  if tg_op = 'DELETE' then
    if pg_trigger_depth() <= 1 then
      perform public.erreur_metier('PAYMENT_LOCKED',
        'Un paiement ne se supprime pas : annulez-le, avec son motif. Il restera visible, barré.');
    end if;
    return old;
  end if;

  if tg_op = 'UPDATE' then
    -- Seule l'annulation, une fois, par annuler_paiement
    if not public.contexte_finances()
       or old.annule_le is not null
       or row(new.facture_id, new.client_id, new.montant_usd, new.moyen, new.reference, new.paye_le, new.note,
              new.origine, new.cle_idempotence, new.cree_par, new.cree_le)
          is distinct from
          row(old.facture_id, old.client_id, old.montant_usd, old.moyen, old.reference, old.paye_le, old.note,
              old.origine, old.cle_idempotence, old.cree_par, old.cree_le) then
      perform public.erreur_metier('PAYMENT_LOCKED',
        'Un paiement enregistré ne se modifie pas : annulez-le, avec son motif, puis saisissez le bon.');
    end if;
    return new;
  end if;

  select * into f from public.factures where id = new.facture_id for update;
  if not found then
    perform public.erreur_metier('INVOICE_NOT_FOUND', 'Aucune facture avec cet identifiant.');
  end if;

  new.client_id := f.client_id;
  new.montant_usd := round(new.montant_usd, 2);
  new.moyen := lower(trim(coalesce(new.moyen, '')));
  new.reference := left(trim(coalesce(new.reference, '')), 100);
  new.note := left(trim(coalesce(new.note, '')), 300);
  new.paye_le := coalesce(new.paye_le, now());
  new.cree_le := now();

  if public.contexte_reprise() then
    return new;     -- montant d'avant la Phase 5 : il est ce qu'il est
  end if;

  new.origine := case when new.origine = 'creation' then 'creation' else 'saisie' end;
  new.annule_le := null;
  new.annule_par := null;
  new.motif_annulation := '';
  new.cree_par := auth.uid();

  if new.montant_usd is null or new.montant_usd <= 0 then
    perform public.erreur_metier('INVALID_AMOUNT', 'Le montant du paiement doit être supérieur à zéro.');
  end if;
  if not (new.moyen = any (public.moyens_paiement())) then
    perform public.erreur_metier('INVALID_PAYMENT_METHOD',
      'Moyen de paiement inconnu : ' || coalesce(nullif(new.moyen, ''), '(vide)') || '.');
  end if;
  if new.paye_le > now() + interval '1 hour' then
    perform public.erreur_metier('INVALID_DATE', 'La date du paiement ne peut pas être dans le futur.');
  end if;
  if f.statut = 'annulee' then
    perform public.erreur_metier('INVOICE_CANCELLED',
      'La facture ' || f.numero || ' est annulée : elle ne reçoit plus de paiement.');
  end if;

  select coalesce(sum(montant_usd), 0) into v_paye
    from public.paiements where facture_id = f.id and annule_le is null;
  if v_paye >= f.montant_usd then
    perform public.erreur_metier('INVOICE_ALREADY_PAID',
      'La facture ' || f.numero || ' est déjà entièrement payée.');
  end if;
  if new.montant_usd > f.montant_usd - v_paye then
    perform public.erreur_metier('OVERPAYMENT',
      'Le paiement de ' || to_char(new.montant_usd, 'FM999999990.00') || ' $ dépasse le solde de ' ||
      to_char(f.montant_usd - v_paye, 'FM999999990.00') || ' $ de la facture ' || f.numero || '.');
  end if;
  if new.reference <> '' and exists (
       select 1 from public.paiements
        where facture_id = f.id and moyen = new.moyen and lower(reference) = lower(new.reference)
          and annule_le is null) then
    perform public.erreur_metier('DUPLICATE_PAYMENT',
      'Ce paiement (référence ' || new.reference || ') est déjà enregistré sur la facture ' || f.numero || '.');
  end if;
  return new;
end;
$$;

drop trigger if exists regles_paiement on public.paiements;
create trigger regles_paiement
  before insert or update or delete on public.paiements
  for each row execute function public.regles_paiement();

-- Le payé, le statut, la date et le moyen de paiement d'une facture, recalculés
-- depuis ses paiements valides. Appelé sous le verrou de la facture.
create or replace function public.recalculer_facture(p_facture uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_paye numeric;
  v_dernier timestamptz;
  v_moyen text;
  v_avant text := coalesce(current_setting('goship.finances', true), '');
begin
  select coalesce(sum(montant_usd), 0), max(paye_le) into v_paye, v_dernier
    from public.paiements where facture_id = p_facture and annule_le is null;
  select moyen into v_moyen from public.paiements
   where facture_id = p_facture and annule_le is null
   order by paye_le desc, cree_le desc limit 1;

  perform set_config('goship.finances', 'on', true);
  update public.factures f
     set montant_paye_usd = v_paye,
         statut = case when f.statut = 'annulee' then 'annulee'
                       when f.montant_usd > 0 and v_paye >= f.montant_usd then 'payee'
                       else 'a_payer' end,
         payee_le = case when f.statut <> 'annulee' and f.montant_usd > 0 and v_paye >= f.montant_usd
                         then coalesce(v_dernier, now()) end,
         moyen = case when v_paye > 0 then coalesce(nullif(v_moyen, 'autre'), '') else '' end
   where f.id = p_facture;
  perform set_config('goship.finances', v_avant, true);
end;
$$;

create or replace function public.suivre_paiement()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_numero text := (select numero from public.factures where id = new.facture_id);
  v_resume jsonb := jsonb_build_object('facture', v_numero, 'montant_usd', new.montant_usd, 'moyen', new.moyen,
                                       'reference', new.reference, 'paye_le', new.paye_le, 'origine', new.origine);
begin
  if tg_op = 'INSERT' then
    if public.contexte_reprise() then
      perform public.auditer('paiement.reprise', 'paiement', new.id::text, null, v_resume);
      return null;
    end if;
    perform public.recalculer_facture(new.facture_id);
    perform public.auditer('paiement.enregistrement', 'paiement', new.id::text, null, v_resume);
    perform public.noter_evenement_facturation('PAIEMENT_ENREGISTRE', new.facture_id, new.id, new.client_id, v_resume);
  elsif new.annule_le is not null and old.annule_le is null then
    perform public.recalculer_facture(new.facture_id);
    perform public.auditer('paiement.annulation', 'paiement', new.id::text, v_resume,
                           jsonb_build_object('motif', new.motif_annulation));
    perform public.noter_evenement_facturation('PAIEMENT_ANNULE', new.facture_id, new.id, new.client_id,
                                               v_resume || jsonb_build_object('motif', new.motif_annulation));
  end if;
  return null;
end;
$$;

drop trigger if exists suivre_paiement on public.paiements;
create trigger suivre_paiement
  after insert or update on public.paiements
  for each row execute function public.suivre_paiement();

-- Qui voit quoi. Un client ne voit que les paiements de ses factures ; il n'en
-- écrit aucun. L'équipe voit tout. Personne n'écrit dans la table : tout
-- passe par les fonctions de la partie 7.
alter table public.paiements enable row level security;
drop policy if exists paiements_lecture on public.paiements;
create policy paiements_lecture on public.paiements
  for select to authenticated
  using (public.peut('invoices.view', client_id));
revoke all on public.paiements from anon, authenticated;
grant select on public.paiements to authenticated;
grant all on public.paiements to service_role;

alter table public.factures_numeros enable row level security;
drop policy if exists factures_numeros_lecture on public.factures_numeros;
create policy factures_numeros_lecture on public.factures_numeros
  for select to authenticated
  using ((select public.peut('invoices.view')));
revoke all on public.factures_numeros from anon, authenticated;
grant select on public.factures_numeros to authenticated;
grant all on public.factures_numeros to service_role;

alter table public.evenements_facturation enable row level security;
drop policy if exists evenements_facturation_lecture on public.evenements_facturation;
create policy evenements_facturation_lecture on public.evenements_facturation
  for select to authenticated
  using ((select public.peut('audit.view')));
revoke all on public.evenements_facturation from anon, authenticated;
grant select on public.evenements_facturation to authenticated;
grant all on public.evenements_facturation to service_role;


-- 7. Les fonctions du tableau de bord ---------------------------------------------------

-- Une facture complète pour le tableau de bord : celle de facture_json, plus
-- son payé, son solde, son état et TOUS ses paiements (annulés compris, qui
-- s'affichent barrés).
create or replace function public.facture_complete(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.facture_json(f.id)
         || jsonb_build_object(
              'paye_usd', public.paye_usd(f),
              'solde_usd', public.solde_usd(f),
              'etat_paiement', public.etat_paiement(f),
              'paiements', coalesce((select jsonb_agg(to_jsonb(p) order by p.paye_le, p.cree_le)
                                     from public.paiements p where p.facture_id = f.id), '[]'::jsonb))
  from public.factures f
  where f.id = p_id
$$;

-- Enregistrer un paiement (PaymentService.record).
--   p_paiement : { montant_usd, moyen, reference, paye_le, note }
--   p_cle      : identifie la demande ; la même clé renvoyée (double clic,
--                réseau coupé) rend le paiement déjà enregistré, sans en
--                créer un second.
-- Réponse : { paiement, facture, deja }
create or replace function public.enregistrer_paiement(p_facture uuid, p_paiement jsonb, p_cle text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v jsonb := coalesce(p_paiement, '{}'::jsonb);
  v_cle text := nullif(trim(coalesce(p_cle, '')), '');
  p public.paiements;
  v_montant numeric;
  v_date timestamptz;
begin
  perform public.exiger_permission('invoices.edit');
  if v_cle is not null then
    perform pg_advisory_xact_lock(hashtextextended('goship-paiement:' || v_cle, 0));
    select * into p from public.paiements where cle_idempotence = v_cle;
    if found then
      if p.facture_id <> p_facture then
        perform public.erreur_metier('DUPLICATE_OPERATION', 'Cette requête a déjà servi pour une autre facture.');
      end if;
      return jsonb_build_object('paiement', to_jsonb(p), 'facture', public.facture_complete(p.facture_id),
                                'deja', true);
    end if;
  end if;

  v_montant := public.lire_nombre(v -> 'montant_usd', 'INVALID_AMOUNT', 'Montant illisible.');
  if v_montant is null or v_montant <= 0 then
    perform public.erreur_metier('INVALID_AMOUNT', 'Le montant du paiement doit être supérieur à zéro.');
  end if;
  begin
    v_date := nullif(v ->> 'paye_le', '')::timestamptz;
  exception when others then
    perform public.erreur_metier('INVALID_DATE', 'Date du paiement illisible.');
  end;

  insert into public.paiements (facture_id, client_id, montant_usd, moyen, reference, paye_le, note, cle_idempotence)
  values (p_facture, null, v_montant, coalesce(v ->> 'moyen', ''), coalesce(v ->> 'reference', ''), v_date,
          coalesce(v ->> 'note', ''), v_cle)
  returning * into p;

  raise log 'goship paiement facture=% montant=% moyen=%', p_facture, p.montant_usd, p.moyen;
  return jsonb_build_object('paiement', to_jsonb(p), 'facture', public.facture_complete(p.facture_id), 'deja', false);
end;
$$;

-- Annuler un paiement (saisi par erreur, chèque rejeté, remboursement). Il
-- reste dans la liste, barré, avec son motif ; le solde remonte. Déjà annulé :
-- rien ne change, la réponse le dit.
create or replace function public.annuler_paiement(p_paiement uuid, p_motif text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_motif text := left(trim(coalesce(p_motif, '')), 300);
  v_facture uuid;
  p public.paiements;
  v_avant text := coalesce(current_setting('goship.finances', true), '');
begin
  perform public.exiger_permission('invoices.edit');
  select facture_id into v_facture from public.paiements where id = p_paiement;
  if not found then
    perform public.erreur_metier('PAYMENT_NOT_FOUND', 'Aucun paiement avec cet identifiant.');
  end if;
  -- Même ordre de verrous que l'enregistrement : la facture, puis le paiement
  perform 1 from public.factures where id = v_facture for update;
  select * into p from public.paiements where id = p_paiement for update;
  if p.annule_le is not null then
    return jsonb_build_object('paiement', to_jsonb(p), 'facture', public.facture_complete(v_facture), 'deja', true);
  end if;
  if v_motif = '' then
    perform public.erreur_metier('REASON_REQUIRED', 'Indiquez pourquoi ce paiement est annulé.');
  end if;

  perform set_config('goship.finances', 'on', true);
  update public.paiements
     set annule_le = now(), annule_par = auth.uid(), motif_annulation = v_motif
   where id = p_paiement
  returning * into p;
  perform set_config('goship.finances', v_avant, true);

  return jsonb_build_object('paiement', to_jsonb(p), 'facture', public.facture_complete(v_facture), 'deja', false);
end;
$$;

-- Annuler une facture, à la place de la supprimer. Elle garde son numéro, ses
-- lignes et son histoire ; ses colis redeviennent facturables. Une facture
-- qui a reçu de l'argent ne s'annule pas tant que ses paiements tiennent :
-- rembourser se trace, paiement par paiement.
create or replace function public.annuler_facture(p_facture uuid, p_motif text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_motif text := left(trim(coalesce(p_motif, '')), 300);
  f public.factures;
  v_paye numeric;
  v_avant text := coalesce(current_setting('goship.finances', true), '');
begin
  perform public.exiger_permission('invoices.edit');
  select * into f from public.factures where id = p_facture for update;
  if not found then
    perform public.erreur_metier('INVOICE_NOT_FOUND', 'Aucune facture avec cet identifiant.');
  end if;
  if f.statut = 'annulee' then
    return jsonb_build_object('facture', public.facture_complete(f.id), 'deja', true);
  end if;
  if v_motif = '' then
    perform public.erreur_metier('REASON_REQUIRED', 'Indiquez pourquoi cette facture est annulée.');
  end if;
  select coalesce(sum(montant_usd), 0) into v_paye
    from public.paiements where facture_id = f.id and annule_le is null;
  if v_paye > 0 then
    perform public.erreur_metier('INVOICE_HAS_PAYMENTS',
      'La facture ' || f.numero || ' a reçu ' || to_char(v_paye, 'FM999999990.00') ||
      ' $ : annulez d''abord ses paiements, un par un, avec leur motif.');
  end if;

  perform set_config('goship.finances', 'on', true);
  update public.factures
     set statut = 'annulee', payee_le = null, annulee_le = now(), annulee_par = auth.uid(),
         motif_annulation = v_motif
   where id = f.id;
  perform set_config('goship.finances', v_avant, true);
  perform public.auditer('facture.annulation', 'facture', f.id::text,
                         jsonb_build_object('statut', f.statut),
                         jsonb_build_object('statut', 'annulee', 'motif', v_motif));
  return jsonb_build_object('facture', public.facture_complete(f.id), 'deja', false);
end;
$$;

-- Le détail chiffré d'un ensemble de colis, tel que la base le facturerait :
-- prix de chaque colis (celui inscrit sur lui), sous-total, frais de service
-- une fois, total. Sert d'aperçu avant de créer ou de regrouper ; ne crée rien.
create or replace function public.calculer_facture(p_colis uuid[])
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_lignes jsonb;
  v_sous_total numeric;
  v_frais numeric;
begin
  perform public.exiger_permission('invoices.view');
  select coalesce(jsonb_agg(jsonb_build_object(
           'colis_id', c.id, 'numero', c.numero, 'description', c.description, 'poids_lb', c.poids_lb,
           'tarif_lb_usd', c.tarif_lb_usd,
           'prix_usd', coalesce(c.prix_usd, public.prix_transport(c.poids_lb, c.tarif_lb_usd)))
           order by c.recu_le, c.id), '[]'::jsonb),
         coalesce(sum(coalesce(c.prix_usd, public.prix_transport(c.poids_lb, c.tarif_lb_usd))), 0)
    into v_lignes, v_sous_total
    from public.colis c
   where c.id = any (coalesce(p_colis, '{}'));
  v_frais := case when jsonb_array_length(v_lignes) > 0
                  then (public.tarifs() ->> 'frais_service')::numeric else 0 end;
  return jsonb_build_object('lignes', v_lignes, 'sous_total', v_sous_total, 'frais_service', v_frais,
                            'total', v_sous_total + v_frais);
end;
$$;

-- Regrouper plusieurs factures d'un même client en une seule (BillingService.merge).
-- Seules des factures de colis, à payer et sans aucun paiement, se regroupent :
-- les autres ont déjà une vie comptable. Les anciennes sont annulées, avec leur
-- motif et un renvoi vers la nouvelle ; la nouvelle passe par creer_facture,
-- donc par les mêmes règles que toute facture : prix des colis tels
-- qu'inscrits sur eux, frais de service une seule fois. Tout se fait dans la
-- même transaction.
create or replace function public.regrouper_factures(p_factures uuid[], p_cle text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cle text := nullif(trim(coalesce(p_cle, '')), '');
  v_ids uuid[];
  f public.factures;
  v_client uuid;
  v_colis uuid[] := '{}';
  v_echeance date;
  v_numeros text[] := '{}';
  v_existante uuid;
  v_nouvelle uuid;
  r jsonb;
  v_avant text := coalesce(current_setting('goship.finances', true), '');
begin
  perform public.exiger_permission('invoices.create');
  perform public.exiger_permission('invoices.edit');
  if v_cle is not null then
    perform pg_advisory_xact_lock(hashtextextended('goship-creer-facture:' || v_cle, 0));
    select id into v_existante from public.factures where cle_idempotence = v_cle;
    if found then
      return jsonb_build_object(
        'facture', public.facture_complete(v_existante),
        'annulees', coalesce((select jsonb_agg(numero order by numero) from public.factures
                              where remplacee_par = v_existante), '[]'::jsonb),
        'deja', true);
    end if;
  end if;

  select array_agg(distinct i order by i) into v_ids from unnest(coalesce(p_factures, '{}')) i where i is not null;
  if coalesce(array_length(v_ids, 1), 0) < 2 then
    perform public.erreur_metier('INVALID_INPUT', 'Choisissez au moins deux factures à regrouper.');
  end if;
  if array_length(v_ids, 1) > 50 then
    perform public.erreur_metier('INVALID_INPUT', 'Au plus 50 factures par regroupement.');
  end if;
  if (select count(*) from public.factures where id = any (v_ids)) <> array_length(v_ids, 1) then
    perform public.erreur_metier('INVOICE_NOT_FOUND', 'Une des factures choisies n''existe plus.');
  end if;

  for f in select * from public.factures where id = any (v_ids) order by id for update loop
    if v_client is null then
      v_client := f.client_id;
    elsif f.client_id <> v_client then
      perform public.erreur_metier('INVOICE_CLIENT_MISMATCH',
        'Les factures choisies appartiennent à plusieurs clients : on ne regroupe que celles d''un seul.');
    end if;
    if f.statut <> 'a_payer' then
      perform public.erreur_metier('INVOICE_NOT_GROUPABLE',
        'La facture ' || f.numero || ' est ' || case when f.statut = 'payee' then 'payée' else 'annulée' end ||
        ' : elle ne se regroupe pas.');
    end if;
    if exists (select 1 from public.paiements where facture_id = f.id and annule_le is null) then
      perform public.erreur_metier('INVOICE_HAS_PAYMENTS',
        'La facture ' || f.numero || ' a déjà reçu un paiement : elle ne se regroupe pas.');
    end if;
    if not exists (select 1 from public.facture_lignes where facture_id = f.id)
       or exists (select 1 from public.facture_lignes where facture_id = f.id and colis_id is null) then
      perform public.erreur_metier('INVOICE_NOT_GROUPABLE',
        'La facture ' || f.numero || ' n''est pas une facture de colis : elle ne se regroupe pas.');
    end if;
    v_colis := v_colis || array(select colis_id from public.facture_lignes where facture_id = f.id);
    v_echeance := least(v_echeance, f.echeance_le);
    v_numeros := v_numeros || f.numero;
  end loop;

  perform set_config('goship.finances', 'on', true);
  update public.factures
     set statut = 'annulee', annulee_le = now(), annulee_par = auth.uid(),
         motif_annulation = 'Regroupement des factures ' || array_to_string(v_numeros, ', ')
   where id = any (v_ids);
  perform set_config('goship.finances', v_avant, true);

  r := public.creer_facture(v_client, v_colis, jsonb_build_object('echeance_le', v_echeance), v_cle);
  v_nouvelle := (r -> 'facture' ->> 'id')::uuid;

  perform set_config('goship.finances', 'on', true);
  update public.factures set remplacee_par = v_nouvelle where id = any (v_ids);
  perform set_config('goship.finances', v_avant, true);

  perform public.auditer('facture.regroupement', 'facture', v_nouvelle::text,
                         jsonb_build_object('factures', to_jsonb(v_numeros)),
                         jsonb_build_object('numero', r -> 'facture' ->> 'numero',
                                            'montant_usd', r -> 'facture' -> 'montant_usd'));
  return jsonb_build_object('facture', public.facture_complete(v_nouvelle), 'annulees', to_jsonb(v_numeros),
                            'deja', false);
end;
$$;

-- Les chiffres du haut de l'onglet Factures : ce qui reste à encaisser, les
-- factures en retard, ce qui est entré ce mois-ci (heure de Santo Domingo).
create or replace function public.resume_facturation()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  r jsonb;
  v_mois timestamptz := date_trunc('month', now() at time zone 'America/Santo_Domingo')
                        at time zone 'America/Santo_Domingo';
begin
  perform public.exiger_permission('invoices.view');
  -- Une seule agrégation des paiements plutôt que solde_usd() facture par
  -- facture : même règle (solde = total − paiements valides ; en retard =
  -- solde > 0 et échéance passée), dix fois plus vite sur des milliers de
  -- factures.
  with pa as (
    select facture_id, sum(montant_usd) as paye
    from public.paiements where annule_le is null group by facture_id
  ), f as (
    select coalesce(pa.paye, 0) as paye,
           greatest(fa.montant_usd - coalesce(pa.paye, 0), 0) as solde,
           fa.echeance_le
    from public.factures fa left join pa on pa.facture_id = fa.id
    where fa.statut <> 'annulee'
  )
  select jsonb_build_object(
           'a_encaisser',       coalesce(sum(solde), 0),
           'ouvertes',          count(*) filter (where solde > 0),
           'partielles',        count(*) filter (where solde > 0 and paye > 0),
           'en_retard',         count(*) filter (where solde > 0 and echeance_le < public.aujourdhui()),
           'montant_en_retard', coalesce(sum(solde) filter (where solde > 0 and echeance_le < public.aujourdhui()), 0),
           'encaisse_mois',     (select coalesce(sum(montant_usd), 0) from public.paiements
                                 where annule_le is null and paye_le >= v_mois))
    into r
    from f;
  return r;
end;
$$;


-- 8. L'espace client ----------------------------------------------------------------
-- Même fonction qu'avant (supabase-facturation.sql), enrichie : le payé, le
-- solde et l'état calculés par la base, le tarif de chaque ligne, et les
-- paiements reçus (les paiements annulés n'y figurent pas : ils ne regardent
-- que l'équipe). Toujours sans « security definer » : les règles de sécurité
-- des tables s'appliquent, et le filtre sur auth.uid() dit la même chose une
-- seconde fois.
create or replace function public.mes_factures()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(f.j order by f.cree_le desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
             'id',                fa.id,
             'numero',            fa.numero,
             'montant_usd',       fa.montant_usd,
             'frais_service_usd', fa.frais_service_usd,
             'montant_paye_usd',  public.paye_usd(fa),
             'paye_usd',          public.paye_usd(fa),
             'solde_usd',         public.solde_usd(fa),
             'etat',              public.etat_paiement(fa),
             'statut',            fa.statut,
             'note',              fa.note,
             'lien_paiement',     fa.lien_paiement,
             'moyen',             fa.moyen,
             'echeance_le',       fa.echeance_le,
             'cree_le',           fa.cree_le,
             'payee_le',          fa.payee_le,
             'annulee_le',        fa.annulee_le,
             'lignes',            coalesce((
               select jsonb_agg(jsonb_build_object(
                        'libelle',      l.libelle,
                        'montant_usd',  l.montant_usd,
                        'quantite',     l.quantite,
                        'poids_lb',     l.poids_lb,
                        'tarif_lb_usd', l.tarif_lb_usd,
                        'colis',        co.numero) order by l.id)
               from public.facture_lignes l
               left join public.colis co on co.id = l.colis_id
               where l.facture_id = fa.id), '[]'::jsonb),
             'paiements',         coalesce((
               select jsonb_agg(jsonb_build_object(
                        'montant_usd', p.montant_usd,
                        'moyen',       p.moyen,
                        'paye_le',     p.paye_le) order by p.paye_le, p.cree_le)
               from public.paiements p
               where p.facture_id = fa.id and p.annule_le is null), '[]'::jsonb)) as j,
           fa.cree_le
    from public.factures fa
    where fa.client_id = (select auth.uid())
  ) f
$$;


-- 9. Le rapport d'anomalies -----------------------------------------------------------
-- Ce que la base trouve d'incohérent dans la facturation, facture par facture.
-- Il ne corrige RIEN : une facture remise à un client ne se réécrit pas en
-- silence. Chaque ligne dit ce qui cloche ; l'équipe décide (annuler,
-- refacturer, annuler un paiement…), et chacun de ces gestes est tracé.
--
--   erreur     l'argent ou le document est faux
--   attention  à regarder
--   info       normal, mais bon à savoir
--
-- Les factures d'avant le 22/09/2026 n'ont pas de frais de service, et c'est
-- voulu : elles ne sont pas signalées pour cela.
create or replace function public.rapport_anomalies_facturation()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  r jsonb;
begin
  -- Depuis le SQL Editor, personne n'est connecté : le rapport s'y lit quand
  -- même (un visiteur, lui, n'a pas le droit d'appeler la fonction).
  if auth.uid() is not null then
    perform public.exiger_permission('audit.view');
  end if;
  with lignes as (
    select l.facture_id, count(*) as nb, count(l.colis_id) as nb_colis, sum(l.montant_usd) as total
    from public.facture_lignes l group by l.facture_id
  ), payes as (
    select p.facture_id, sum(p.montant_usd) as paye
    from public.paiements p where p.annule_le is null group by p.facture_id
  ), a as (
    -- Un colis sur plusieurs factures actives
    select 'colis_facture_deux_fois' as type, 'erreur' as gravite, f.id as facture_id, f.numero,
           'Le colis ' || co.numero || ' est aussi sur la facture ' ||
           (select string_agg(f2.numero, ', ') from public.facture_lignes l2
              join public.factures f2 on f2.id = l2.facture_id
             where l2.colis_id = l.colis_id and f2.id <> f.id and f2.statut <> 'annulee') || '.' as detail
    from public.facture_lignes l
    join public.factures f on f.id = l.facture_id and f.statut <> 'annulee'
    join public.colis co on co.id = l.colis_id
    where exists (select 1 from public.facture_lignes l2 join public.factures f2 on f2.id = l2.facture_id
                  where l2.colis_id = l.colis_id and f2.id <> f.id and f2.statut <> 'annulee')
    union all
    -- Un colis d'un autre client que celui de la facture
    select 'client_different', 'erreur', f.id, f.numero,
           'Le colis ' || co.numero || ' appartient à un autre client.'
    from public.facture_lignes l
    join public.factures f on f.id = l.facture_id
    join public.colis co on co.id = l.colis_id
    where co.client_id is distinct from f.client_id
    union all
    -- Total différent de ses lignes + frais
    select 'total_incoherent', 'erreur', f.id, f.numero,
           'Total ' || f.montant_usd || ' $ ; lignes ' || li.total || ' $ + frais ' || f.frais_service_usd ||
           ' $ = ' || (li.total + f.frais_service_usd) || ' $.'
    from public.factures f join lignes li on li.facture_id = f.id
    where f.statut <> 'annulee' and li.nb_colis > 0 and f.montant_usd <> li.total + f.frais_service_usd
    union all
    -- Payé plus que le total
    select 'paye_depasse_total', 'erreur', f.id, f.numero,
           'Payé ' || coalesce(pa.paye, 0) || ' $ pour un total de ' || f.montant_usd || ' $.'
    from public.factures f left join payes pa on pa.facture_id = f.id
    where coalesce(pa.paye, 0) > f.montant_usd or f.montant_paye_usd > f.montant_usd
    union all
    -- Le payé inscrit sur la facture n'est pas la somme de ses paiements
    select 'paye_different_paiements', 'erreur', f.id, f.numero,
           'La facture indique ' || f.montant_paye_usd || ' $ payés, ses paiements font ' ||
           coalesce(pa.paye, 0) || ' $.'
    from public.factures f left join payes pa on pa.facture_id = f.id
    where f.montant_paye_usd <> coalesce(pa.paye, 0)
    union all
    -- Statut qui ne correspond pas au solde
    select 'statut_incoherent', 'attention', f.id, f.numero,
           case when f.statut = 'payee' then 'Marquée payée, mais il reste ' ||
                     (f.montant_usd - coalesce(pa.paye, 0)) || ' $ à payer.'
                else 'Marquée à payer, mais entièrement payée.' end
    from public.factures f left join payes pa on pa.facture_id = f.id
    where (f.statut = 'payee' and coalesce(pa.paye, 0) < f.montant_usd)
       or (f.statut = 'a_payer' and f.montant_usd > 0 and coalesce(pa.paye, 0) >= f.montant_usd)
    union all
    -- De l'argent sur une facture annulée
    select 'paiement_sur_facture_annulee', 'attention', f.id, f.numero,
           pa.paye || ' $ encaissés sur une facture annulée : à rembourser ou à reporter.'
    from public.factures f join payes pa on pa.facture_id = f.id
    where f.statut = 'annulee' and pa.paye > 0
    union all
    -- Facture de colis récente sans frais de service
    select 'frais_absents', 'info', f.id, f.numero,
           'Facture de colis du ' || to_char(f.cree_le, 'DD/MM/YYYY') || ' sans frais de service.'
    from public.factures f join lignes li on li.facture_id = f.id
    where f.statut <> 'annulee' and li.nb_colis > 0 and f.frais_service_usd = 0
      and f.cree_le >= timestamptz '2026-09-22 00:00:00-04'
    union all
    -- Ligne dont le colis a été supprimé depuis
    select 'ligne_sans_colis', 'info', f.id, f.numero,
           'La ligne « ' || l.libelle || ' » (' || l.montant_usd || ' $) n''a plus de colis.'
    from public.facture_lignes l join public.factures f on f.id = l.facture_id
    where l.colis_id is null
    union all
    -- Colis repesé après sa facture : la facture garde le prix du jour, c'est voulu
    select 'prix_colis_change', 'info', f.id, f.numero,
           'Le colis ' || co.numero || ' vaut aujourd''hui ' || co.prix_usd || ' $ ; la facture garde ' ||
           l.montant_usd || ' $.'
    from public.facture_lignes l
    join public.factures f on f.id = l.facture_id and f.statut <> 'annulee'
    join public.colis co on co.id = l.colis_id
    where co.prix_usd is not null and co.prix_usd <> l.montant_usd
    union all
    -- Colis d'un client, sans facture active
    select 'colis_sans_facture', 'info', null, co.numero,
           'Le colis ' || co.numero || ' n''est sur aucune facture active.'
    from public.colis co
    where co.client_id is not null
      and not exists (select 1 from public.facture_lignes l join public.factures f on f.id = l.facture_id
                      where l.colis_id = co.id and f.statut <> 'annulee')
  )
  select coalesce(jsonb_agg(jsonb_build_object('type', a.type, 'gravite', a.gravite, 'facture_id', a.facture_id,
                                               'numero', a.numero, 'detail', a.detail)
                            order by case a.gravite when 'erreur' then 0 when 'attention' then 1 else 2 end,
                                     a.type, a.numero), '[]'::jsonb)
    into r
    from a;
  return r;
end;
$$;


-- 10. La reprise des montants déjà payés ------------------------------------------------
-- Chaque facture qui porte un montant payé mais aucun paiement reçoit UN
-- paiement « repris » de ce montant, daté du jour où elle a été marquée payée
-- (ou, à défaut, de sa création), avec le moyen noté sur elle s'il est connu.
-- La facture elle-même n'est pas touchée : ni son total, ni son payé, ni son
-- statut, ni sa date. Relancer ce fichier ne reprend rien deux fois.
--
-- Même principe pour le tarif des anciennes lignes : il n'est recopié que là
-- où le calcul retombe exactement sur le montant facturé (poids × tarif du
-- colis = montant de la ligne). Ailleurs, il reste vide plutôt que faux.
do $$
begin
  perform set_config('goship.reprise', 'on', true);

  insert into public.paiements (facture_id, client_id, montant_usd, moyen, paye_le, note, origine)
  select f.id, f.client_id, f.montant_paye_usd,
         case when f.moyen = any (public.moyens_paiement()) then f.moyen else 'autre' end,
         coalesce(f.payee_le, f.cree_le),
         'Montant payé repris du registre d''avant les paiements détaillés.',
         'reprise'
    from public.factures f
   where f.montant_paye_usd > 0
     and not exists (select 1 from public.paiements p where p.facture_id = f.id);

  update public.facture_lignes l
     set tarif_lb_usd = co.tarif_lb_usd
    from public.colis co
   where co.id = l.colis_id
     and l.tarif_lb_usd is null
     and co.tarif_lb_usd is not null
     and l.poids_lb is not null
     and public.prix_transport(l.poids_lb, co.tarif_lb_usd) = l.montant_usd;

  perform set_config('goship.reprise', '', true);
end $$;


-- 11. Droits ---------------------------------------------------------------------------
-- Les rouages internes ne s'appellent pas depuis le site ; les fonctions de
-- service et les colonnes calculées, si, et chacune vérifie la permission.
revoke execute on function public.contexte_finances() from public, anon, authenticated;
revoke execute on function public.contexte_reprise() from public, anon, authenticated;
revoke execute on function public.noter_evenement_facturation(text, uuid, uuid, uuid, jsonb) from public, anon, authenticated;
revoke execute on function public.reserver_numero_facture() from public, anon, authenticated;
revoke execute on function public.garde_facture() from public, anon, authenticated;
revoke execute on function public.suivre_facture() from public, anon, authenticated;
revoke execute on function public.verrou_facture_ligne() from public, anon, authenticated;
revoke execute on function public.regles_paiement() from public, anon, authenticated;
revoke execute on function public.recalculer_facture(uuid) from public, anon, authenticated;
revoke execute on function public.suivre_paiement() from public, anon, authenticated;
revoke execute on function public.facture_complete(uuid) from public, anon, authenticated;

revoke execute on function public.moyens_paiement() from public, anon;
revoke execute on function public.aujourdhui() from public, anon;
revoke execute on function public.paye_usd(public.factures) from public, anon;
revoke execute on function public.solde_usd(public.factures) from public, anon;
revoke execute on function public.etat_paiement(public.factures) from public, anon;
revoke execute on function public.enregistrer_paiement(uuid, jsonb, text) from public, anon;
revoke execute on function public.annuler_paiement(uuid, text) from public, anon;
revoke execute on function public.annuler_facture(uuid, text) from public, anon;
revoke execute on function public.calculer_facture(uuid[]) from public, anon;
revoke execute on function public.regrouper_factures(uuid[], text) from public, anon;
revoke execute on function public.resume_facturation() from public, anon;
revoke execute on function public.rapport_anomalies_facturation() from public, anon;
revoke execute on function public.mes_factures() from public, anon;

grant execute on function public.moyens_paiement() to authenticated;
grant execute on function public.aujourdhui() to authenticated;
grant execute on function public.paye_usd(public.factures) to authenticated;
grant execute on function public.solde_usd(public.factures) to authenticated;
grant execute on function public.etat_paiement(public.factures) to authenticated;
grant execute on function public.enregistrer_paiement(uuid, jsonb, text) to authenticated;
grant execute on function public.annuler_paiement(uuid, text) to authenticated;
grant execute on function public.annuler_facture(uuid, text) to authenticated;
grant execute on function public.calculer_facture(uuid[]) to authenticated;
grant execute on function public.regrouper_factures(uuid[], text) to authenticated;
grant execute on function public.resume_facturation() to authenticated;
grant execute on function public.rapport_anomalies_facturation() to authenticated;
grant execute on function public.mes_factures() to authenticated;


-- Contrôle -------------------------------------------------------------------------------
-- finances_sur_9 : 9 ; gardes_sur_6 : 6 ; factures_sans_paiement doit valoir 0
-- (le payé de chaque facture est la somme de ses paiements) ; paiements_repris :
-- le nombre de montants payés d'avant ce fichier devenus des paiements. Le
-- détail des anomalies : onglet Factures > « Contrôler », ou ici même :
--   select a from jsonb_array_elements(public.rapport_anomalies_facturation()) a;
select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('enregistrer_paiement', 'annuler_paiement', 'annuler_facture', 'calculer_facture',
                            'regrouper_factures', 'resume_facturation', 'rapport_anomalies_facturation',
                            'solde_usd', 'etat_paiement'))                               as finances_sur_9,
       (select count(*) from pg_trigger
        where tgname in ('garde_facture', 'suivre_facture', 'reserver_numero_facture',
                         'verrou_facture_ligne', 'regles_paiement', 'suivre_paiement'))   as gardes_sur_6,
       (select count(*) from public.factures f
        where f.montant_paye_usd <> (select coalesce(sum(p.montant_usd), 0) from public.paiements p
                                     where p.facture_id = f.id and p.annule_le is null)) as factures_sans_paiement,
       (select count(*) from public.paiements where origine = 'reprise')                  as paiements_repris;
