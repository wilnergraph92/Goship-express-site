-- =============================================================================
--  Essai sur l'image Supabase PostgreSQL réelle : ce que les SERVICES Supabase
--  ajoutent eux-mêmes sur une vraie instance et que l'image PostgreSQL seule n'a pas.
--  Appliqué par supabase_admin sur la base JETABLE du conteneur, jamais ailleurs.
-- =============================================================================
-- storage-api
alter table storage.buckets add column if not exists public boolean default false;
alter table storage.buckets add column if not exists file_size_limit bigint;
alter table storage.buckets add column if not exists allowed_mime_types text[];
-- GoTrue (auth.users)
alter table auth.users add column if not exists email_confirmed_at timestamptz;
alter table auth.users add column if not exists phone text;
alter table auth.users add column if not exists phone_confirmed_at timestamptz;
alter table auth.users add column if not exists banned_until timestamptz;
alter table auth.users add column if not exists deleted_at timestamptz;
alter table auth.users add column if not exists is_sso_user boolean not null default false;
alter table auth.users add column if not exists is_anonymous boolean not null default false;
-- Base jetable : mot de passe d'essai pour se connecter comme PostgREST
alter role authenticator password 'essai-jetable';
