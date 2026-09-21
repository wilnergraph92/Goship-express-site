-- Mise à jour de la base pour l'application mobile GoShip Express
-- À coller dans le SQL Editor de Supabase (Run). Le script peut être relancé sans risque.
-- Il ajoute les pré-alertes, les factures, les notifications sur le téléphone,
-- et il installe les nouveaux statuts de colis.
-- (Ces mêmes parties se trouvent aussi à la fin de outils/supabase.sql.)

-- 9. Pré-alertes (application mobile) ---------------------------------------------
-- Le client annonce un achat avant son arrivée à Miami. Dès qu'un colis est
-- enregistré avec le même numéro de suivi, la pré-alerte est rapprochée toute seule.

create table if not exists public.prealertes (
  id                 uuid primary key default gen_random_uuid(),
  client_id          uuid not null default auth.uid() references public.clients (id) on delete cascade,
  magasin            text not null default '',
  description        text not null default '',
  suivi_transporteur text not null default '',
  valeur_usd         numeric(10, 2) check (valeur_usd is null or valeur_usd >= 0),
  service            text not null default 'aerien'
                     check (service in ('aerien', 'maritime', 'terrestre')),
  statut             text not null default 'attente'
                     check (statut in ('attente', 'recu', 'annulee')),
  colis_id           uuid references public.colis (id) on delete set null,
  cree_le            timestamptz not null default now()
);

create index if not exists prealertes_client_idx on public.prealertes (client_id, cree_le desc);
create index if not exists prealertes_suivi_idx on public.prealertes (lower(suivi_transporteur));

alter table public.prealertes enable row level security;

drop policy if exists prealertes_lecture on public.prealertes;
create policy prealertes_lecture on public.prealertes
  for select to authenticated
  using (client_id = (select auth.uid()) or (select public.est_admin()));

drop policy if exists prealertes_ajout on public.prealertes;
create policy prealertes_ajout on public.prealertes
  for insert to authenticated
  with check (client_id = (select auth.uid()));

drop policy if exists prealertes_modification on public.prealertes;
create policy prealertes_modification on public.prealertes
  for update to authenticated
  using (client_id = (select auth.uid()) or (select public.est_admin()))
  with check (client_id = (select auth.uid()) or (select public.est_admin()));

drop policy if exists prealertes_suppression on public.prealertes;
create policy prealertes_suppression on public.prealertes
  for delete to authenticated
  using (client_id = (select auth.uid()) or (select public.est_admin()));

revoke all on public.prealertes from anon;
grant select, insert, update, delete on public.prealertes to authenticated;
grant select, insert, update, delete on public.prealertes to service_role;

-- Rapprochement automatique pré-alerte / colis
create or replace function public.rapprocher_prealerte()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(trim(new.suivi_transporteur), '') <> '' and new.client_id is not null then
    update public.prealertes p
       set statut = 'recu', colis_id = new.id
     where p.client_id = new.client_id
       and p.statut = 'attente'
       and lower(trim(p.suivi_transporteur)) = lower(trim(new.suivi_transporteur));
  end if;
  return null;
end;
$$;

drop trigger if exists rapprocher_prealerte on public.colis;
create trigger rapprocher_prealerte
  after insert or update of suivi_transporteur, client_id on public.colis
  for each row execute function public.rapprocher_prealerte();


-- 10. Factures --------------------------------------------------------------------
-- Créées depuis le tableau de bord ; le client les consulte dans l'application.

create sequence if not exists public.numero_facture_seq start with 1;

create table if not exists public.factures (
  id            uuid primary key default gen_random_uuid(),
  numero        text unique,
  client_id     uuid not null references public.clients (id) on delete cascade,
  montant_usd   numeric(10, 2) not null default 0 check (montant_usd >= 0),
  statut        text not null default 'a_payer'
                check (statut in ('a_payer', 'payee', 'annulee')),
  note          text not null default '',
  lien_paiement text not null default '',   -- lien PayPal ou Azul préparé pour cette facture
  moyen         text not null default '',   -- comment le client a payé (paypal, banque, azul, moncash, natcash)
  echeance_le   date,
  cree_le       timestamptz not null default now(),
  payee_le      timestamptz
);

-- Colonnes ajoutées après la première version (sans effet si elles existent)
alter table public.factures add column if not exists lien_paiement text not null default '';
alter table public.factures add column if not exists moyen text not null default '';

create table if not exists public.facture_lignes (
  id          bigint generated always as identity primary key,
  facture_id  uuid not null references public.factures (id) on delete cascade,
  colis_id    uuid references public.colis (id) on delete set null,
  libelle     text not null default '',
  montant_usd numeric(10, 2) not null default 0
);

create index if not exists factures_client_idx on public.factures (client_id, cree_le desc);
create index if not exists facture_lignes_facture_idx on public.facture_lignes (facture_id);

-- Numéro de facture : FAC-2026-0001
create or replace function public.preparer_facture()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(trim(new.numero), '') = '' then
    new.numero := 'FAC-' || to_char(now(), 'YYYY') || '-'
                  || lpad(nextval('public.numero_facture_seq')::text, 4, '0');
  end if;
  if new.statut = 'payee' and new.payee_le is null then
    new.payee_le := now();
  end if;
  return new;
end;
$$;

drop trigger if exists preparer_facture on public.factures;
create trigger preparer_facture
  before insert or update on public.factures
  for each row execute function public.preparer_facture();

alter table public.factures enable row level security;
alter table public.facture_lignes enable row level security;

drop policy if exists factures_lecture on public.factures;
create policy factures_lecture on public.factures
  for select to authenticated
  using (client_id = (select auth.uid()) or (select public.est_admin()));

drop policy if exists factures_admin on public.factures;
create policy factures_admin on public.factures
  for all to authenticated
  using ((select public.est_admin()))
  with check ((select public.est_admin()));

drop policy if exists facture_lignes_lecture on public.facture_lignes;
create policy facture_lignes_lecture on public.facture_lignes
  for select to authenticated
  using (exists (select 1 from public.factures f
                 where f.id = facture_id
                   and (f.client_id = (select auth.uid()) or (select public.est_admin()))));

drop policy if exists facture_lignes_admin on public.facture_lignes;
create policy facture_lignes_admin on public.facture_lignes
  for all to authenticated
  using ((select public.est_admin()))
  with check ((select public.est_admin()));

revoke all on public.factures, public.facture_lignes from anon;
grant select, insert, update, delete on public.factures, public.facture_lignes to authenticated;
grant select, insert, update, delete on public.factures, public.facture_lignes to service_role;


-- 11. Notifications sur le téléphone (application mobile) --------------------------
-- Chaque téléphone connecté enregistre son jeton Expo ; à chaque changement de
-- statut, la base envoie la notification, comme elle envoie déjà les e-mails.

create table if not exists public.appareils (
  id         uuid primary key default gen_random_uuid(),
  client_id  uuid not null default auth.uid() references public.clients (id) on delete cascade,
  jeton      text not null unique,
  plateforme text not null default '',
  langue     text not null default 'fr',
  cree_le    timestamptz not null default now(),
  maj_le     timestamptz not null default now()
);

create index if not exists appareils_client_idx on public.appareils (client_id);

alter table public.appareils enable row level security;

drop policy if exists appareils_lecture on public.appareils;
create policy appareils_lecture on public.appareils
  for select to authenticated
  using (client_id = (select auth.uid()) or (select public.est_admin()));

drop policy if exists appareils_ajout on public.appareils;
create policy appareils_ajout on public.appareils
  for insert to authenticated
  with check (client_id = (select auth.uid()));

drop policy if exists appareils_modification on public.appareils;
create policy appareils_modification on public.appareils
  for update to authenticated
  using (client_id = (select auth.uid()))
  with check (client_id = (select auth.uid()));

drop policy if exists appareils_suppression on public.appareils;
create policy appareils_suppression on public.appareils
  for delete to authenticated
  using (client_id = (select auth.uid()) or (select public.est_admin()));

revoke all on public.appareils from anon;
grant select, insert, update, delete on public.appareils to authenticated;
grant select, insert, update, delete on public.appareils to service_role;

-- La colonne « canal » accepte désormais les notifications du téléphone
alter table public.notifications drop constraint if exists notifications_canal_check;
alter table public.notifications add constraint notifications_canal_check
  check (canal in ('email', 'whatsapp', 'push'));

-- Libellé d'un statut dans la langue du client
create or replace function public.texte_statut(p_statut text, p_langue text default 'fr')
returns text
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    (jsonb_build_object(
      'recu',         jsonb_build_object('fr', 'Reçu', 'en', 'Received', 'es', 'Recibido', 'ht', 'Resevwa'),
      'emballe',      jsonb_build_object('fr', 'Emballé', 'en', 'Packed', 'es', 'Embalado', 'ht', 'Anbale'),
      'embarque',     jsonb_build_object('fr', 'Embarqué', 'en', 'Shipped', 'es', 'Embarcado', 'ht', 'Anbake'),
      'distribution', jsonb_build_object('fr', 'Centre de distribution', 'en', 'Distribution centre', 'es', 'Centro de distribución', 'ht', 'Sant distribisyon'),
      'succursale',   jsonb_build_object('fr', 'Transféré à la succursale', 'en', 'Transferred to the branch', 'es', 'Transferido a la sucursal', 'ht', 'Transfere nan sikisal la'),
      'disponible',   jsonb_build_object('fr', 'Disponible', 'en', 'Ready for pickup', 'es', 'Disponible', 'ht', 'Disponib'),
      'livre',        jsonb_build_object('fr', 'Livré', 'en', 'Delivered', 'es', 'Entregado', 'ht', 'Livre'),
      'incident',     jsonb_build_object('fr', 'Action requise', 'en', 'Action required', 'es', 'Acción requerida', 'ht', 'Aksyon nesesè')
    ) -> p_statut ->> (case when p_langue in ('fr', 'en', 'es', 'ht') then p_langue else 'fr' end)),
    p_statut);
$$;

-- Envoi des notifications à tous les téléphones d'un client
create or replace function public.pousser_colis(p_colis uuid, p_evenement text default 'maj')
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_colis    public.colis;
  v_code     text;
  v_messages jsonb := '[]'::jsonb;
  v_requete  bigint;
  a          record;
begin
  select * into v_colis from public.colis where id = p_colis;
  if not found or v_colis.client_id is null then
    return 'sans-client';
  end if;
  select code into v_code from public.clients where id = v_colis.client_id;

  for a in select * from public.appareils where client_id = v_colis.client_id loop
    v_messages := v_messages || jsonb_build_object(
      'to', a.jeton,
      'title', public.texte_statut(v_colis.statut, a.langue),
      'body', coalesce(nullif(v_colis.description, ''), v_colis.numero) || ' · ' || v_colis.numero,
      'sound', 'default',
      'channelId', 'colis',
      'priority', 'high',
      'data', jsonb_build_object('colis_id', v_colis.id, 'evenement', p_evenement)
    );
  end loop;

  if jsonb_array_length(v_messages) = 0 then
    return 'sans-appareil';
  end if;

  select net.http_post(
    url := 'https://exp.host/--/api/v2/push/send',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Accept', 'application/json'),
    body := v_messages
  ) into v_requete;

  insert into public.notifications (colis_id, canal, evenement, destinataire, requete)
  values (p_colis, 'push', p_evenement, coalesce(v_code, ''), v_requete);
  return 'envoye';
end;
$$;

revoke execute on function public.pousser_colis(uuid, text) from public, anon;
grant execute on function public.pousser_colis(uuid, text) to authenticated, service_role;

-- Déclenché à chaque changement de statut, sans jamais bloquer le tableau de bord
create or replace function public.pousser_au_changement()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  begin
    perform public.pousser_colis(new.id, new.statut);
  exception when others then
    null;
  end;
  return null;
end;
$$;

drop trigger if exists pousser_au_changement on public.colis;
create trigger pousser_au_changement
  after insert or update of statut on public.colis
  for each row execute function public.pousser_au_changement();


-- 12. Nouveaux statuts de colis (19/09/2026) --------------------------------------
-- Reçu → Emballé → Embarqué → Centre de distribution → Transféré à la succursale →
-- Disponible → Livré, plus « Action requise » en cas de problème.
-- Les colis déjà enregistrés avec les anciens statuts sont convertis.

update public.colis
   set statut = case statut
                  when 'transit'   then 'embarque'
                  when 'douane'    then 'distribution'
                  when 'livraison' then 'succursale'
                  else statut
                end
 where statut in ('transit', 'douane', 'livraison');

update public.colis_historique
   set statut = case statut
                  when 'transit'   then 'embarque'
                  when 'douane'    then 'distribution'
                  when 'livraison' then 'succursale'
                  else statut
                end
 where statut in ('transit', 'douane', 'livraison');

alter table public.colis drop constraint if exists colis_statut_check;
alter table public.colis add constraint colis_statut_check
  check (statut in ('recu', 'emballe', 'embarque', 'distribution',
                    'succursale', 'disponible', 'livre', 'incident'));
