-- =============================================================================
-- Goship Express — base de données de l'espace client (Supabase)
--
-- À exécuter une fois : Supabase > SQL Editor > New query > coller tout ce
-- fichier > Run. Le script peut être relancé sans risque (il ne supprime
-- aucune donnée) : relancez-le après chaque mise à jour du site.
--
-- Contenu :
--   clients            un profil par compte, avec son code unique tiré au hasard
--                      (GSE- suivi de 4 chiffres, ex. GSE-4323)
--   colis              les colis, chacun rattaché à un client (GSE-1001-HT…)
--   colis_historique   chaque changement de statut : date, lieu, note
--   notifications      les e-mails et messages WhatsApp envoyés aux clients
--   factures           les factures, et leurs lignes (un colis par ligne)
--
-- Sécurité : chaque client ne voit que son profil et ses colis ; seuls les
-- comptes administrateurs voient tout et peuvent enregistrer des colis.
-- Pour faire d'un compte un administrateur (après l'avoir créé dans
-- Authentication > Users > Add user, ou sur la page « Créer un compte » du site) :
--   select public.definir_admin('votre-adresse@exemple.com');
-- Réglages des notifications (e-mail, WhatsApp) : voir la partie 7.
-- Logo des e-mails (dossier public « site » de Supabase) : voir la partie 8.
-- =============================================================================


-- 1. Numérotation --------------------------------------------------------------

-- Ancienne numérotation des codes clients (GSE-000001…), conservée pour les bases existantes
create sequence if not exists public.code_client_seq;
-- Numéros de colis : GSE-1001-HT, GSE-1002-DO…
create sequence if not exists public.numero_colis_seq start with 1001;

create or replace function public.formater_code_client(n bigint)
returns text
language sql
immutable
set search_path = ''
as $$
  select 'GSE-' || lpad(n::text, greatest(6, length(n::text)), '0')
$$;

-- Code client tiré au hasard : « GSE- » suivi de 4 chiffres (GSE-4323), jamais
-- deux fois le même. 9 000 codes sont possibles (1000 à 9999) : de quoi voir
-- venir, mais ce n'est pas illimité — voir README, « Le format des codes
-- clients », qui explique comment passer à 5 chiffres le jour où il faudra.
create or replace function public.nouveau_code_client()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_code text;
  v_essais int := 0;
begin
  loop
    v_code := 'GSE-' || (1000 + floor(random() * 9000))::int;
    exit when not exists (select 1 from public.clients where code = v_code);
    v_essais := v_essais + 1;
    -- Sans cette limite, une base presque pleine ferait tourner la boucle sans
    -- fin : la création de compte resterait bloquée, sans rien dire. Mieux vaut
    -- un message clair, qui nomme le problème et la solution.
    if v_essais >= 200 then
      raise exception 'Plus de code client libre au format GSE-0000 : % codes déjà pris sur 9000. Voir README, « Le format des codes clients ».',
        (select count(*) from public.clients where code is not null);
    end if;
  end loop;
  return v_code;
end;
$$;


-- 2. Tables -------------------------------------------------------------------

create table if not exists public.clients (
  id          uuid primary key references auth.users (id) on delete cascade,
  code        text unique,              -- vide pour les administrateurs
  nom_complet text not null default '',
  pays        text not null default '', -- HT, DO ou US
  region      text not null default '',
  ville       text not null default '',
  adresse     text not null default '',
  telephone   text not null default '',
  email       text not null default '',
  langue      text not null default 'fr',
  role        text not null default 'client' check (role in ('client', 'admin')),
  cree_le     timestamptz not null default now()
);

create table if not exists public.colis (
  id                 uuid primary key default gen_random_uuid(),
  numero             text unique,
  client_id          uuid references public.clients (id) on delete set null,
  suivi_transporteur text not null default '',   -- n° de suivi du vendeur (Amazon, USPS…)
  expediteur         text not null default '',   -- magasin ou fournisseur (Amazon, SHEIN…)
  description        text not null default '',
  poids_lb           numeric(8, 2) check (poids_lb is null or poids_lb >= 0),
  service            text not null default 'aerien'
                     check (service in ('aerien', 'maritime', 'terrestre')),
  pays_destination   text not null default 'HT' check (pays_destination in ('HT', 'DO', 'US')),
  destination        text not null default '',   -- ville de livraison
  statut             text not null default 'recu'
                     check (statut in ('recu', 'emballe', 'embarque', 'distribution',
                                       'succursale', 'disponible', 'livre', 'incident')),
  lieu               text not null default '',   -- lieu de la dernière étape
  note               text not null default '',   -- message visible par le client
  recu_le            timestamptz not null default now(), -- date et heure de réception à Miami
  cree_le            timestamptz not null default now(),
  maj_le             timestamptz not null default now()
);

-- Colonnes ajoutées après la première version (sans effet si elles existent)
alter table public.colis add column if not exists expediteur text not null default '';
alter table public.colis add column if not exists recu_le timestamptz not null default now();

create index if not exists colis_client_idx on public.colis (client_id);
create index if not exists colis_maj_idx on public.colis (maj_le desc);
create index if not exists colis_suivi_idx on public.colis (suivi_transporteur);

create table if not exists public.colis_historique (
  id       bigint generated always as identity primary key,
  colis_id uuid not null references public.colis (id) on delete cascade,
  statut   text not null,
  lieu     text not null default '',
  note     text not null default '',
  cree_le  timestamptz not null default now()
);

create index if not exists colis_historique_colis_idx on public.colis_historique (colis_id, cree_le);


-- 3. Automatismes -------------------------------------------------------------

-- Profil client créé à l'inscription, avec son code unique tiré au hasard
create or replace function public.creer_profil_client()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  insert into public.clients (id, code, nom_complet, pays, region, ville, adresse, telephone, email, langue)
  values (
    new.id,
    public.nouveau_code_client(),
    left(trim(coalesce(m ->> 'nom_complet', '')), 120),
    left(upper(trim(coalesce(m ->> 'pays', ''))), 2),
    left(trim(coalesce(m ->> 'region', '')), 80),
    left(trim(coalesce(m ->> 'ville', '')), 80),
    left(trim(coalesce(m ->> 'adresse', '')), 200),
    left(trim(coalesce(m ->> 'telephone', '')), 40),
    coalesce(new.email, ''),
    case when m ->> 'langue' in ('fr', 'en', 'es', 'ht') then m ->> 'langue' else 'fr' end
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists creer_profil_client on auth.users;
create trigger creer_profil_client
  after insert on auth.users
  for each row execute function public.creer_profil_client();

-- Numéro de colis attribué à l'enregistrement ; dates tenues à jour
create or replace function public.preparer_colis()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if coalesce(trim(new.numero), '') = '' then
      new.numero := 'GSE-' || nextval('public.numero_colis_seq') || '-' || new.pays_destination;
    end if;
    new.numero := upper(trim(new.numero));
    new.cree_le := now();
  else
    new.numero := old.numero;
    new.cree_le := old.cree_le;
  end if;
  new.recu_le := coalesce(new.recu_le, now());
  new.suivi_transporteur := upper(trim(new.suivi_transporteur));
  new.maj_le := now();
  return new;
end;
$$;

drop trigger if exists preparer_colis on public.colis;
create trigger preparer_colis
  before insert or update on public.colis
  for each row execute function public.preparer_colis();

-- Chaque nouveau statut (ou nouvelle note) est ajouté à l'historique.
-- La première étape porte la date et l'heure de réception saisies.
create or replace function public.historiser_colis()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.colis_historique (colis_id, statut, lieu, note, cree_le)
    values (new.id, new.statut, new.lieu, new.note, coalesce(new.recu_le, now()));
  elsif new.statut is distinct from old.statut
        or new.lieu is distinct from old.lieu
        or new.note is distinct from old.note then
    insert into public.colis_historique (colis_id, statut, lieu, note)
    values (new.id, new.statut, new.lieu, new.note);
  end if;
  return null;
end;
$$;

drop trigger if exists historiser_colis on public.colis;
create trigger historiser_colis
  after insert or update on public.colis
  for each row execute function public.historiser_colis();


-- 4. Droits d'accès -------------------------------------------------------------

create or replace function public.est_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.clients where id = auth.uid() and role = 'admin')
$$;

alter table public.clients enable row level security;
alter table public.colis enable row level security;
alter table public.colis_historique enable row level security;

drop policy if exists clients_lecture on public.clients;
create policy clients_lecture on public.clients
  for select to authenticated
  using (id = (select auth.uid()) or (select public.est_admin()));

drop policy if exists clients_modification on public.clients;
create policy clients_modification on public.clients
  for update to authenticated
  using (id = (select auth.uid()) or (select public.est_admin()))
  with check (id = (select auth.uid()) or (select public.est_admin()));

drop policy if exists colis_lecture on public.colis;
create policy colis_lecture on public.colis
  for select to authenticated
  using (client_id = (select auth.uid()) or (select public.est_admin()));

drop policy if exists colis_ajout on public.colis;
create policy colis_ajout on public.colis
  for insert to authenticated
  with check ((select public.est_admin()));

drop policy if exists colis_modification on public.colis;
create policy colis_modification on public.colis
  for update to authenticated
  using ((select public.est_admin()))
  with check ((select public.est_admin()));

drop policy if exists colis_suppression on public.colis;
create policy colis_suppression on public.colis
  for delete to authenticated
  using ((select public.est_admin()));

drop policy if exists historique_lecture on public.colis_historique;
create policy historique_lecture on public.colis_historique
  for select to authenticated
  using (
    (select public.est_admin())
    or exists (select 1 from public.colis c where c.id = colis_id and c.client_id = (select auth.uid()))
  );

-- Droits d'accès aux tables. Depuis 2026, Supabase n'ouvre plus automatiquement
-- les nouvelles tables : chaque droit est accordé ici, et les règles ci-dessus
-- limitent ensuite les lignes visibles (un client ne voit que les siennes).
grant usage on schema public to anon, authenticated, service_role;
revoke all on public.clients, public.colis, public.colis_historique from anon;
grant select on public.clients, public.colis_historique to authenticated;
grant select, insert, update, delete on public.colis to authenticated;
grant select, insert, update, delete on public.clients, public.colis, public.colis_historique to service_role;
-- Un client ne peut modifier que ses coordonnées (jamais son code ni son rôle)
revoke insert, update, delete on public.clients from authenticated;
grant update (nom_complet, pays, region, ville, adresse, telephone, langue) on public.clients to authenticated;
revoke insert, update, delete on public.colis_historique from authenticated;

-- Colis avec les coordonnées du client (tableau de bord)
drop view if exists public.colis_details;
create view public.colis_details
with (security_invoker = true) as
  select c.*,
         cl.code        as code_client,
         cl.nom_complet as nom_client,
         cl.telephone   as telephone_client,
         cl.email       as email_client,
         cl.adresse     as adresse_client,
         cl.region      as region_client,
         cl.ville       as ville_client,
         cl.pays        as pays_client,
         cl.langue      as langue_client
  from public.colis c
  left join public.clients cl on cl.id = c.client_id;

revoke all on public.colis_details from anon;
grant select on public.colis_details to authenticated, service_role;


-- 5. Fonctions appelées par le site --------------------------------------------

-- Suivi public (formulaire « Où est mon colis ? ») : statut et étapes
-- uniquement, sans nom, adresse, description ni note.
create or replace function public.suivre_colis(p_numero text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'numero', c.numero,
    'statut', c.statut,
    'service', c.service,
    'pays_destination', c.pays_destination,
    'maj_le', c.maj_le,
    'historique', coalesce((
      select jsonb_agg(jsonb_build_object('statut', h.statut, 'lieu', h.lieu, 'cree_le', h.cree_le) order by h.cree_le)
      from public.colis_historique h
      where h.colis_id = c.id), '[]'::jsonb))
  from public.colis c
  where length(trim(coalesce(p_numero, ''))) >= 4
    and (c.numero = upper(trim(p_numero))
         or (c.suivi_transporteur <> '' and c.suivi_transporteur = upper(trim(p_numero))))
  order by c.maj_le desc
  limit 1
$$;

-- Chiffres du tableau de bord
create or replace function public.statistiques_admin()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.est_admin() then
    raise exception 'Accès réservé aux administrateurs' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'clients', (select count(*) from public.clients where role = 'client'),
    'statuts', coalesce((select jsonb_object_agg(s.statut, s.n)
                         from (select statut, count(*) as n from public.colis group by statut) s), '{}'::jsonb),
    'livres_30j', (select count(*) from public.colis
                   where statut = 'livre' and maj_le > now() - interval '30 days')
  );
end;
$$;

-- Désigner un administrateur (à lancer depuis le SQL Editor uniquement).
-- Le compte perd son code client.
create or replace function public.definir_admin(p_email text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select id into v_id from public.clients where lower(email) = lower(trim(p_email));
  if v_id is null then
    raise exception 'Aucun compte avec l''adresse %. Créez d''abord le compte (Authentication > Users > Add user).', p_email;
  end if;
  update public.clients set role = 'admin', code = null where id = v_id;
  return 'Le compte ' || p_email || ' est maintenant administrateur.';
end;
$$;

revoke execute on function public.creer_profil_client() from public, anon, authenticated;
revoke execute on function public.nouveau_code_client() from public, anon, authenticated;
revoke execute on function public.preparer_colis() from public, anon, authenticated;
revoke execute on function public.historiser_colis() from public, anon, authenticated;
revoke execute on function public.definir_admin(text) from public, anon, authenticated;
revoke execute on function public.statistiques_admin() from public, anon;
grant execute on function public.statistiques_admin() to authenticated;
grant execute on function public.est_admin() to authenticated;
grant execute on function public.suivre_colis(text) to anon, authenticated;


-- 6. Temps réel ------------------------------------------------------------------
-- Les pages « Mon compte » et « Tableau de bord » se mettent à jour d'elles-mêmes.

do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'colis') then
    alter publication supabase_realtime add table public.colis;
  end if;
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'clients') then
    alter publication supabase_realtime add table public.clients;
  end if;
exception
  when undefined_object then
    raise notice 'Publication supabase_realtime absente : mises à jour en direct désactivées.';
end $$;


-- 7. Notifications aux clients (e-mail et WhatsApp) -------------------------------
-- Le tableau de bord prépare le message dans la langue du client ; la base
-- l'envoie avec les clés enregistrées ci-dessous (jamais visibles dans le site).
--
-- E-mails (Brevo ou Resend), à lancer une fois dans le SQL Editor :
--   select public.definir_reglage('email_fournisseur', 'brevo');        -- ou 'resend'
--   select public.definir_reglage('email_cle_api', 'xkeysib-…');        -- clé API du service
--   select public.definir_reglage('email_expediteur', 'notifications@votre-domaine.com');
--   select public.definir_reglage('email_nom', 'Goship Express');
--
-- WhatsApp automatique (API WhatsApp Cloud de Meta, facultatif) :
--   select public.definir_reglage('whatsapp_jeton', 'EAAG…');           -- jeton d'accès permanent
--   select public.definir_reglage('whatsapp_numero_id', '1234567890');  -- Phone number ID
-- Sans ces réglages, le tableau de bord propose d'envoyer le message WhatsApp
-- en un clic depuis votre propre WhatsApp.

create extension if not exists pg_net with schema extensions;

create table if not exists public.notifications (
  id           bigint generated always as identity primary key,
  colis_id     uuid references public.colis (id) on delete cascade,
  canal        text not null check (canal in ('email', 'whatsapp')),
  evenement    text not null,          -- recu, disponible
  destinataire text not null default '',
  requete      bigint,                 -- n° de la requête d'envoi (réponse dans net._http_response)
  envoye_le    timestamptz not null default now()
);

create index if not exists notifications_colis_idx on public.notifications (colis_id, envoye_le desc);

alter table public.notifications enable row level security;
drop policy if exists notifications_lecture on public.notifications;
create policy notifications_lecture on public.notifications
  for select to authenticated
  using ((select public.est_admin()));
revoke all on public.notifications from anon;
grant select on public.notifications to authenticated;
grant select, insert, update, delete on public.notifications to service_role;
revoke insert, update, delete on public.notifications from authenticated;

-- Réglages secrets (clés d'API), rangés dans le coffre-fort de Supabase (Vault)
create or replace function public.definir_reglage(p_nom text, p_valeur text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select id into v_id from vault.secrets where name = p_nom limit 1;
  if v_id is null then
    perform vault.create_secret(p_valeur, p_nom);
  else
    perform vault.update_secret(v_id, p_valeur);
  end if;
  return 'Réglage « ' || p_nom || ' » enregistré.';
end;
$$;

create or replace function public.lire_reglage(p_nom text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return (select decrypted_secret from vault.decrypted_secrets where name = p_nom limit 1);
end;
$$;

-- Numéro WhatsApp du client au format international (chiffres uniquement)
create or replace function public.telephone_international(p_telephone text, p_pays text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  t text := regexp_replace(coalesce(p_telephone, ''), '\D', '', 'g');
begin
  if length(t) = 8 and p_pays = 'HT' then
    return '509' || t;
  elsif length(t) = 10 and p_pays in ('DO', 'US') then
    return '1' || t;
  end if;
  return t;
end;
$$;

-- E-mail au client d'un colis (le destinataire est lu dans la base, jamais fourni par le site)
create or replace function public.envoyer_email_client(p_colis uuid, p_evenement text, p_sujet text,
                                                       p_html text, p_texte text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text;
  v_nom text;
  v_cle text := public.lire_reglage('email_cle_api');
  v_fournisseur text := coalesce(nullif(public.lire_reglage('email_fournisseur'), ''), 'brevo');
  v_expediteur text := public.lire_reglage('email_expediteur');
  v_nom_expediteur text := coalesce(nullif(public.lire_reglage('email_nom'), ''), 'Goship Express');
  v_requete bigint;
begin
  if not public.est_admin() then
    raise exception 'Accès réservé aux administrateurs' using errcode = '42501';
  end if;
  if coalesce(v_cle, '') = '' or coalesce(v_expediteur, '') = '' then
    return 'non-configure';
  end if;
  select cl.email, cl.nom_complet into v_email, v_nom
  from public.colis c join public.clients cl on cl.id = c.client_id
  where c.id = p_colis;
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
                                 'to', jsonb_build_array(jsonb_build_object('email', v_email, 'name', v_nom)),
                                 'subject', p_sujet, 'htmlContent', p_html, 'textContent', p_texte)
    ) into v_requete;
  end if;

  insert into public.notifications (colis_id, canal, evenement, destinataire, requete)
  values (p_colis, 'email', p_evenement, v_email, v_requete);
  return 'envoye';
end;
$$;

-- Message WhatsApp automatique (modèle approuvé par Meta) au client d'un colis
create or replace function public.envoyer_whatsapp_client(p_colis uuid, p_evenement text, p_modele text,
                                                          p_langue text, p_parametres jsonb)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_jeton text := public.lire_reglage('whatsapp_jeton');
  v_numero_id text := public.lire_reglage('whatsapp_numero_id');
  v_version text := coalesce(nullif(public.lire_reglage('whatsapp_version'), ''), 'v23.0');
  v_telephone text;
  v_requete bigint;
begin
  if not public.est_admin() then
    raise exception 'Accès réservé aux administrateurs' using errcode = '42501';
  end if;
  if coalesce(v_jeton, '') = '' or coalesce(v_numero_id, '') = '' then
    return 'non-configure';
  end if;
  select public.telephone_international(cl.telephone, cl.pays) into v_telephone
  from public.colis c join public.clients cl on cl.id = c.client_id
  where c.id = p_colis;
  if coalesce(v_telephone, '') = '' then
    return 'sans-destinataire';
  end if;

  select net.http_post(
    url := 'https://graph.facebook.com/' || v_version || '/' || v_numero_id || '/messages',
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_jeton, 'Content-Type', 'application/json'),
    body := jsonb_build_object(
      'messaging_product', 'whatsapp',
      'to', v_telephone,
      'type', 'template',
      'template', jsonb_build_object(
        'name', p_modele,
        'language', jsonb_build_object('code', p_langue),
        'components', jsonb_build_array(jsonb_build_object(
          'type', 'body',
          'parameters', (select coalesce(jsonb_agg(jsonb_build_object('type', 'text', 'text', p.valeur) order by p.rang),
                                         '[]'::jsonb)
                         from jsonb_array_elements_text(coalesce(p_parametres, '[]'::jsonb))
                              with ordinality as p(valeur, rang))))))
  ) into v_requete;

  insert into public.notifications (colis_id, canal, evenement, destinataire, requete)
  values (p_colis, 'whatsapp', p_evenement, '+' || v_telephone, v_requete);
  return 'envoye';
end;
$$;

-- Notifications envoyées pour un colis, avec la réponse du service d'envoi
-- (conservée quelques heures par Supabase)
create or replace function public.notifications_colis(p_colis uuid)
returns table (canal text, evenement text, destinataire text, envoye_le timestamptz,
               code_http integer, erreur text)
language sql
stable
security definer
set search_path = ''
as $$
  select n.canal, n.evenement, n.destinataire, n.envoye_le, r.status_code,
         coalesce(r.error_msg, case when r.status_code >= 300 then left(r.content, 300) end)
  from public.notifications n
  left join net._http_response r on r.id = n.requete
  where n.colis_id = p_colis and public.est_admin()
  order by n.envoye_le desc
$$;

revoke execute on function public.definir_reglage(text, text) from public, anon, authenticated;
revoke execute on function public.lire_reglage(text) from public, anon, authenticated;
revoke execute on function public.envoyer_email_client(uuid, text, text, text, text) from public, anon;
revoke execute on function public.envoyer_whatsapp_client(uuid, text, text, text, jsonb) from public, anon;
revoke execute on function public.notifications_colis(uuid) from public, anon;
grant execute on function public.envoyer_email_client(uuid, text, text, text, text) to authenticated;
grant execute on function public.envoyer_whatsapp_client(uuid, text, text, text, jsonb) to authenticated;
grant execute on function public.notifications_colis(uuid) to authenticated;


-- 8. Logo des e-mails -------------------------------------------------------------
-- Les messageries (Gmail…) n'affichent que des images en ligne : à sa première
-- ouverture, le tableau de bord copie le logo dans ce dossier public de Supabase.

insert into storage.buckets (id, name, public)
values ('site', 'site', true)
on conflict (id) do update set public = true;

-- Seuls les administrateurs y déposent des fichiers ; tout le monde peut les voir
do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
                 and policyname = 'site_lecture_admin') then
    create policy site_lecture_admin on storage.objects
      for select to authenticated
      using (bucket_id = 'site' and (select public.est_admin()));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
                 and policyname = 'site_ajout_admin') then
    create policy site_ajout_admin on storage.objects
      for insert to authenticated
      with check (bucket_id = 'site' and (select public.est_admin()));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
                 and policyname = 'site_modification_admin') then
    create policy site_modification_admin on storage.objects
      for update to authenticated
      using (bucket_id = 'site' and (select public.est_admin()))
      with check (bucket_id = 'site' and (select public.est_admin()));
  end if;
end $$;


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

-- Numéro de facture : année, mois, quatre chiffres tirés au hasard (2026-09-0417),
-- jamais deux fois le même. 10 000 numéros par mois, et le compteur repart à
-- chaque mois. Voir outils/supabase-numero-facture.sql.
create or replace function public.preparer_facture()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_numero text;
  v_essais int := 0;
begin
  if coalesce(trim(new.numero), '') = '' then
    loop
      v_numero := to_char(now(), 'YYYY-MM') || '-'
                  || lpad(floor(random() * 10000)::int::text, 4, '0');
      exit when not exists (select 1 from public.factures where numero = v_numero);
      v_essais := v_essais + 1;
      -- Sans cette limite, un mois déjà bien rempli ferait tourner la boucle
      -- sans fin : la facture ne s'enregistrerait plus, sans rien dire.
      if v_essais >= 200 then
        raise exception 'Plus de numéro de facture libre pour %  : % numéros déjà pris sur 10 000.',
          to_char(now(), 'YYYY-MM'),
          (select count(*) from public.factures
           where numero like to_char(now(), 'YYYY-MM') || '-%');
      end if;
    end loop;
    new.numero := v_numero;
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
  -- Réservé au tableau de bord (et aux automatismes de la base, qui n'ont pas de
  -- compte) : sans cela, n'importe quel client connecté pourrait faire sonner le
  -- téléphone d'un autre client.
  if auth.uid() is not null and not public.est_admin() then
    raise exception 'Accès réservé aux administrateurs' using errcode = '42501';
  end if;
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


-- 13. Renforcement de la sécurité (20/09/2026) ------------------------------------
-- Ces réglages ferment ce qui restait ouvert : notifications déclenchables par un
-- client, téléphone gardant son ancien propriétaire, pré-alertes modifiables au-delà
-- des champs du client, textes sans limite de longueur, fonctions internes ouvertes.
-- (La correction des notifications elle-même est dans la partie 11 ci-dessus.)
-- Le même contenu existe seul dans outils/supabase-securite.sql.

-- 13.1 Téléphones : un seul propriétaire à la fois --------------------------------
-- L'application n'écrit plus directement dans la table : elle passe par cette
-- fonction, qui vérifie le jeton et rattache le téléphone au client connecté.
-- Un téléphone revendu ou prêté cesse donc de recevoir les colis de l'ancien
-- propriétaire dès que le nouveau se connecte.

create or replace function public.enregistrer_appareil(p_jeton text,
                                                       p_plateforme text default '',
                                                       p_langue text default 'fr')
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_client uuid := auth.uid();
begin
  if v_client is null then
    raise exception 'Connexion requise' using errcode = '42501';
  end if;
  -- Un vrai jeton Expo, pas une valeur inventée
  if coalesce(p_jeton, '') !~ '^Ex(ponent)?PushToken\[[A-Za-z0-9_%+/=.-]{1,200}\]$' then
    raise exception 'Jeton de notification invalide' using errcode = '22023';
  end if;

  delete from public.appareils where jeton = p_jeton and client_id <> v_client;

  insert into public.appareils (client_id, jeton, plateforme, langue, maj_le)
  values (v_client, p_jeton,
          left(coalesce(p_plateforme, ''), 20),
          case when p_langue in ('fr', 'en', 'es', 'ht') then p_langue else 'fr' end,
          now())
  on conflict (jeton) do update
    set plateforme = excluded.plateforme, langue = excluded.langue, maj_le = now();

  -- Au plus 10 téléphones par client : les plus anciens sont oubliés
  delete from public.appareils
   where client_id = v_client
     and id not in (select id from public.appareils
                     where client_id = v_client
                     order by maj_le desc
                     limit 10);
end;
$$;

revoke execute on function public.enregistrer_appareil(text, text, text) from public, anon;
grant execute on function public.enregistrer_appareil(text, text, text) to authenticated;

-- L'application ne peut plus écrire en direct (elle garde la lecture et la
-- suppression de ses propres téléphones, pour la déconnexion)
revoke insert, update on public.appareils from authenticated;


-- 13.3 Pré-alertes : seuls les champs du client sont modifiables -------------------
-- Avant : un client pouvait marquer sa pré-alerte « reçue » ou la rattacher au
-- colis de quelqu'un d'autre. Le rapprochement reste fait par la base seule.

revoke insert, update on public.prealertes from authenticated;
grant insert (client_id, magasin, description, suivi_transporteur, valeur_usd, service)
  on public.prealertes to authenticated;
grant update (magasin, description, suivi_transporteur, valeur_usd, service)
  on public.prealertes to authenticated;


-- 13.4 Longueurs bornées -----------------------------------------------------------
-- Le profil était borné à l'inscription, mais pas lors des modifications : un
-- compte pouvait y ranger des textes énormes.

create or replace function public.borner_profil_client()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.nom_complet := left(trim(coalesce(new.nom_complet, '')), 120);
  new.pays        := left(upper(trim(coalesce(new.pays, ''))), 2);
  new.region      := left(trim(coalesce(new.region, '')), 80);
  new.ville       := left(trim(coalesce(new.ville, '')), 80);
  new.adresse     := left(trim(coalesce(new.adresse, '')), 200);
  new.telephone   := left(trim(coalesce(new.telephone, '')), 40);
  new.email       := left(trim(coalesce(new.email, '')), 160);
  new.langue      := case when new.langue in ('fr', 'en', 'es', 'ht') then new.langue else 'fr' end;
  return new;
end;
$$;

drop trigger if exists borner_profil_client on public.clients;
create trigger borner_profil_client
  before insert or update on public.clients
  for each row execute function public.borner_profil_client();

create or replace function public.borner_prealerte()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_en_cours integer;
begin
  new.magasin            := left(trim(coalesce(new.magasin, '')), 80);
  new.description        := left(trim(coalesce(new.description, '')), 300);
  new.suivi_transporteur := left(upper(trim(coalesce(new.suivi_transporteur, ''))), 60);

  if tg_op = 'INSERT' then
    select count(*) into v_en_cours
      from public.prealertes
     where client_id = new.client_id and statut = 'attente';
    if v_en_cours >= 60 then
      raise exception 'Trop de pré-alertes en attente' using errcode = '22023';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists borner_prealerte on public.prealertes;
create trigger borner_prealerte
  before insert or update on public.prealertes
  for each row execute function public.borner_prealerte();


-- 13.5 Fonctions internes fermées au site -------------------------------------------
-- PostgreSQL ouvre par défaut l'exécution des nouvelles fonctions à tout le monde ;
-- on referme celles qui n'ont rien à faire dans les mains d'un visiteur.

revoke execute on function public.est_admin() from public, anon;
revoke execute on function public.borner_profil_client() from public, anon, authenticated;
revoke execute on function public.borner_prealerte() from public, anon, authenticated;
revoke execute on function public.preparer_facture() from public, anon, authenticated;
revoke execute on function public.rapprocher_prealerte() from public, anon, authenticated;
revoke execute on function public.pousser_au_changement() from public, anon, authenticated;
revoke execute on function public.telephone_international(text, text) from public, anon, authenticated;
revoke execute on function public.formater_code_client(bigint) from public, anon, authenticated;
revoke execute on function public.texte_statut(text, text) from public, anon;
grant execute on function public.est_admin() to authenticated;
grant execute on function public.texte_statut(text, text) to authenticated;


-- 13.6 Facultatif : numéros de colis imprévisibles -----------------------------------
-- Les numéros se suivent (GSE-1001-HT, GSE-1002-HT…) : n'importe qui peut donc
-- essayer les numéros voisins sur la page « Suivre mon colis » et voir passer
-- toute l'activité de l'entreprise (statuts, destinations, dates). Aucune donnée
-- personnelle n'est exposée, mais le volume d'affaires, lui, l'est.
--
-- Pour que les nouveaux colis reçoivent un numéro tiré au hasard
-- (GSE-48207391-HT), enlevez les deux tirets au début des lignes suivantes et
-- relancez ce fichier. Les colis déjà enregistrés gardent leur numéro.
--
-- create or replace function public.preparer_colis()
-- returns trigger
-- language plpgsql
-- security definer
-- set search_path = ''
-- as $$
-- declare
--   v_numero text;
-- begin
--   if tg_op = 'INSERT' then
--     if coalesce(trim(new.numero), '') = '' then
--       loop
--         v_numero := 'GSE-' || (10000000 + floor(random() * 90000000))::bigint || '-' || new.pays_destination;
--         exit when not exists (select 1 from public.colis where numero = v_numero);
--       end loop;
--       new.numero := v_numero;
--     end if;
--     new.numero := upper(trim(new.numero));
--     new.cree_le := now();
--   else
--     new.numero := old.numero;
--     new.cree_le := old.cree_le;
--   end if;
--   new.recu_le := coalesce(new.recu_le, now());
--   new.suivi_transporteur := upper(trim(new.suivi_transporteur));
--   new.maj_le := now();
--   return new;
-- end;
-- $$;
-- revoke execute on function public.preparer_colis() from public, anon, authenticated;



-- 14. E-mails de bienvenue (21/09/2026) --------------------------------------------
-- À la création d'un compte, le client reçoit deux e-mails dans sa langue :
--   1. « Bienvenue » : son code client, en grand, et le bouton de son espace.
--   2. « Votre adresse en Floride » : l'adresse à donner aux boutiques, champ
--      par champ, avec le rappel d'écrire son code juste après son nom.
-- Ils partent tout seuls, sans passer par le tableau de bord : l'inscription
-- peut venir du site comme de l'application. Si l'adresse doit être confirmée
-- (Authentication > Confirm email), ils attendent la confirmation ; sinon ils
-- partent aussitôt. Un e-mail qui échoue n'empêche jamais la création du
-- compte : un client ne doit pas être perdu pour un e-mail.
--
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


-- 15. Les factures dans l'espace client --------------------------------------------
-- Le tableau de bord crée les factures (partie 10) ; le client les lit ici, et
-- les voit changer d'état sans recharger sa page.
--
-- L'adresse complète du client se trouve dans la vue colis_details de la
-- partie 4 : c'est elle qui s'imprime sur les étiquettes d'expédition.

-- Les factures du client -------------------------------------------------------
-- Appelée par « Mon compte » (assets/js/api.js, mesFactures).
--
-- Volontairement **sans** security definer : la fonction s'exécute avec les
-- droits de celui qui l'appelle, donc les règles de sécurité des tables
-- s'appliquent malgré tout. Le filtre « client_id = auth.uid() » dit la même
-- chose une seconde fois : même une erreur d'écriture ici ne laisserait
-- personne lire les factures d'un autre.
create or replace function public.mes_factures()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(f order by f.cree_le desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
             'id',            fa.id,
             'numero',        fa.numero,
             'montant_usd',   fa.montant_usd,
             'statut',        fa.statut,
             'note',          fa.note,
             'lien_paiement', fa.lien_paiement,
             'moyen',         fa.moyen,
             'echeance_le',   fa.echeance_le,
             'cree_le',       fa.cree_le,
             'payee_le',      fa.payee_le,
             'lignes',        coalesce((
               select jsonb_agg(jsonb_build_object(
                        'libelle',     l.libelle,
                        'montant_usd', l.montant_usd,
                        'colis',       co.numero) order by l.id)
               from public.facture_lignes l
               left join public.colis co on co.id = l.colis_id
               where l.facture_id = fa.id), '[]'::jsonb)) as f,
           fa.cree_le
    from public.factures fa
    where fa.client_id = (select auth.uid())
  ) f
$$;

revoke execute on function public.mes_factures() from public, anon;
grant execute on function public.mes_factures() to authenticated;


-- Les factures en direct -------------------------------------------------------
-- « Payée » cochée dans le tableau de bord, et la facture change d'état chez le
-- client dans la seconde. Les règles de sécurité s'appliquent aussi à ces
-- messages : chacun ne reçoit que les changements de ses propres factures.
do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'factures') then
    alter publication supabase_realtime add table public.factures;
  end if;
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'facture_lignes') then
    alter publication supabase_realtime add table public.facture_lignes;
  end if;
exception
  when undefined_object then
    raise notice 'Publication supabase_realtime absente : factures sans mise à jour en direct.';
end $$;

-- Fin. Rien d'autre à faire ici : les réglages restants (confirmation des
-- adresses e-mail, adresses de retour autorisées, longueur des mots de passe)
-- se font dans les écrans de Supabase. Voir README.md, « Sécurité ».
