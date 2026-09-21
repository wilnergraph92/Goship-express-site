# -*- coding: utf-8 -*-
"""Éprouve les scripts de la base sur un PostgreSQL local et jetable.

Supabase fournit auth.users, le coffre-fort (vault) et pg_net ; ici on les
remplace par des doublures, juste assez pour que les scripts s'exécutent et
qu'on puisse relire les deux e-mails de bienvenue tels qu'ils partiraient
vraiment.

Depuis la racine du site :

    python3 outils/essais-sql/essai-base.py [chemin-d-un-autre-script.sql]

Voir LISEZ-MOI.md pour les deux paquets à installer.
"""
import os
import pathlib
import re
import subprocess
import sys
import tempfile

import pgserver

SP = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.normpath(os.path.join(SP, '..', '..'))
# La base d'essai et les aperçus restent hors du site : c'est gros, et ça n'a
# rien à faire dans les fichiers qui partent en ligne.
TRAVAIL = os.path.join(tempfile.gettempdir(), 'goship-essais-sql')
SQL = sys.argv[1] if len(sys.argv) > 1 else os.path.join(RACINE, 'outils', 'supabase-bienvenue.sql')
PSQL = pathlib.Path(pgserver.__file__).parent / 'pginstall' / 'bin' / 'psql'

DOUBLURES = r"""
do $roles$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  -- Par le site, PostgREST se connecte sous « authenticator » : on veut pouvoir
  -- rejouer ce chemin-là, et pas seulement celui du SQL Editor.
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator login noinherit;
  else
    alter role authenticator login;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
  grant anon, authenticated to authenticator;
end
$roles$;

drop schema if exists auth cascade;
drop schema if exists vault cascade;
drop schema if exists net cascade;
drop table if exists public.notifications cascade;
drop table if exists public.clients cascade;

create schema auth;
create schema vault;
create schema net;

create table auth.users (
  id uuid primary key,
  email text,
  email_confirmed_at timestamptz,
  raw_user_meta_data jsonb default '{}'::jsonb
);

create table vault.decrypted_secrets (name text primary key, decrypted_secret text);

-- Doublure de pg_net : au lieu d'envoyer, on garde la requête pour la relire
create table net.envois (id bigint generated always as identity primary key,
                         url text, headers jsonb, body jsonb);
create function net.http_post(url text, body jsonb default '{}'::jsonb,
                              params jsonb default '{}'::jsonb, headers jsonb default '{}'::jsonb,
                              timeout_milliseconds integer default 5000)
returns bigint language sql as $$
  insert into net.envois (url, headers, body) values (url, headers, body) returning id
$$;

-- Mêmes colonnes que dans supabase.sql : « code » y est nullable, c'est ainsi
-- que definir_admin distingue un compte d'équipe d'un compte client.
create table public.clients (
  id uuid primary key,
  code text unique,
  nom_complet text not null default '',
  email text not null default '',
  langue text not null default 'fr',
  role text not null default 'client' check (role in ('client', 'admin')),
  cree_le timestamptz not null default now()
);

create table public.notifications (
  id bigint generated always as identity primary key,
  colis_id uuid,
  canal text not null check (canal in ('email', 'whatsapp')),
  evenement text not null,
  destinataire text not null default '',
  requete bigint,
  envoye_le timestamptz not null default now()
);

create or replace function public.lire_reglage(p_nom text) returns text
language sql stable security definer set search_path = '' as $$
  select decrypted_secret from vault.decrypted_secrets where name = p_nom limit 1
$$;

create or replace function public.est_admin() returns boolean
language sql stable as $$
  select coalesce(current_setting('essai.admin', true), 'true') = 'true'
$$;

-- Le profil client naît avec le compte, comme dans supabase.sql
create or replace function public.creer_profil_client() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.clients (id, code, nom_complet, email, langue)
  values (new.id, 'GSE-' || (1028370000 + (abs(hashtext(new.id::text)) % 999))::text,
          coalesce(new.raw_user_meta_data ->> 'nom_complet', ''),
          coalesce(new.email, ''),
          coalesce(new.raw_user_meta_data ->> 'langue', 'fr'))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists creer_profil_client on auth.users;
create trigger creer_profil_client after insert on auth.users
  for each row execute function public.creer_profil_client();

insert into vault.decrypted_secrets values
  ('email_cle_api', 'xkeysib-essai'),
  ('email_expediteur', 'notifications@goshipexpress.com'),
  ('email_nom', 'Goship Express'),
  ('site_url', 'https://www.goshipexpress.com'),
  ('courriel_logo', 'https://exemple.supabase.co/storage/v1/object/public/site/logo-goship.png');
"""


class Base:
    def __init__(self):
        os.makedirs(TRAVAIL, exist_ok=True)
        serveur = pgserver.get_server(os.path.join(TRAVAIL, 'pgdata'))
        self.socket = serveur.get_uri().split('host=')[1]
        self.utilisateur = self.superutilisateur()

    def superutilisateur(self):
        """Selon la base, il s'appelle postgres ou supabase_admin."""
        for nom in ('postgres', 'supabase_admin'):
            r = subprocess.run([str(PSQL), '-U', nom, '-h', self.socket, '-d', 'postgres', '-X', '-t', '-A',
                                '-c', 'select rolsuper from pg_roles where rolname = current_user;'],
                               capture_output=True, text=True)
            if r.returncode == 0 and r.stdout.strip() in ('t', 'true'):
                return nom
        raise SystemExit("Aucun superutilisateur trouvé sur la base d'essai.")

    def lancer(self, sql, brut=False, echec_permis=False):
        args = [str(PSQL), '-U', self.utilisateur, '-h', self.socket, '-d', 'postgres',
                '-v', 'ON_ERROR_STOP=1', '-X', '-q']
        if not brut:
            args += ['-t', '-A']
        r = subprocess.run(args + ['-c', sql], capture_output=True, text=True)
        if r.returncode and not echec_permis:
            raise SystemExit('ERREUR SQL\n%s\n--- requête ---\n%s' % (r.stderr.strip(), sql.strip()[:400]))
        return (r.stdout + r.stderr).strip()

    def lancer_role(self, role, sql, echec_permis=False):
        """La même chose, mais connecté comme le fait le site."""
        r = subprocess.run([str(PSQL), '-U', role, '-h', self.socket, '-d', 'postgres',
                            '-v', 'ON_ERROR_STOP=1', '-X', '-q', '-t', '-A', '-c', sql],
                           capture_output=True, text=True)
        if r.returncode and not echec_permis:
            raise SystemExit('ERREUR SQL (%s)\n%s' % (role, r.stderr.strip()))
        return (r.stdout + r.stderr).strip()

    def fichier(self, chemin):
        r = subprocess.run([str(PSQL), '-U', self.utilisateur, '-h', self.socket, '-d', 'postgres',
                            '-v', 'ON_ERROR_STOP=1', '-X', '-q', '-f', chemin],
                           capture_output=True, text=True)
        if r.returncode:
            raise SystemExit('ERREUR dans %s\n%s' % (chemin, r.stderr.strip()))
        return r.stdout.strip()


def verifier(titre, obtenu, attendu, chiffre=False):
    if chiffre:
        # psql mêle ses avertissements au résultat : on ne garde que le nombre.
        obtenu = next((l.strip() for l in obtenu.splitlines() if l.strip().isdigit()), obtenu)
    bon = obtenu == attendu
    print('  %s %-46s %s' % ('OK  ' if bon else 'RATÉ', titre, obtenu))
    if not bon:
        print('       attendu : %s' % attendu)
    return bon


def main():
    db = Base()
    db.lancer(DOUBLURES)
    db.fichier(SQL)
    print("Le script s'installe sans erreur.\n")
    ok = []

    print('1. Un compte dont l\'adresse est déjà confirmée (Confirm email désactivé)')
    db.lancer("""insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
                 values ('11111111-1111-1111-1111-111111111111', 'marie@exemple.com', now(),
                         '{"nom_complet":"Marie-Ange Dorvil","langue":"fr"}'::jsonb);""")
    ok.append(verifier('les deux e-mails partent',
                       db.lancer("""select string_agg(evenement, ', ' order by id) from public.notifications
                                    where client_id = '11111111-1111-1111-1111-111111111111';"""),
                       'bienvenue, adresse_miami'))
    ok.append(verifier('adressés au bon client',
                       db.lancer("""select distinct destinataire from public.notifications
                                    where client_id = '11111111-1111-1111-1111-111111111111';"""),
                       'marie@exemple.com'))

    print("\n2. Un compte en attente de confirmation (Confirm email activé)")
    db.lancer("""insert into auth.users (id, email, raw_user_meta_data)
                 values ('22222222-2222-2222-2222-222222222222', 'jean@exemple.com',
                         '{"nom_complet":"Jean Baptiste","langue":"ht"}'::jsonb);""")
    ok.append(verifier('rien tant que l\'adresse n\'est pas prouvée',
                       db.lancer("""select count(*)::text from public.notifications
                                    where client_id = '22222222-2222-2222-2222-222222222222';"""), '0'))
    db.lancer("""update auth.users set email_confirmed_at = now()
                 where id = '22222222-2222-2222-2222-222222222222';""")
    ok.append(verifier('les deux e-mails partent à la confirmation',
                       db.lancer("""select string_agg(evenement, ', ' order by id) from public.notifications
                                    where client_id = '22222222-2222-2222-2222-222222222222';"""),
                       'bienvenue, adresse_miami'))

    print('\n3. Garde-fous')
    db.lancer("""update auth.users set email_confirmed_at = now()
                 where id = '22222222-2222-2222-2222-222222222222';""")
    ok.append(verifier('une seconde confirmation ne renvoie rien',
                       db.lancer("""select count(*)::text from public.notifications
                                    where client_id = '22222222-2222-2222-2222-222222222222';"""), '2'))
    ok.append(verifier('un client connecté ne peut pas les déclencher',
                       db.lancer("""select has_function_privilege('authenticated',
                                    'public.courriels_bienvenue(uuid, boolean)', 'execute')::text;"""), 'false'))
    ok.append(verifier('ni écrire à qui il veut',
                       db.lancer("""select has_function_privilege('authenticated',
                                    'public.envoyer_courriel_client(uuid, text, text, text, text)',
                                    'execute')::text;"""), 'false'))
    ok.append(verifier('un administrateur peut les renvoyer',
                       db.lancer("select public.renvoyer_courriels_bienvenue('%s');"
                                 % db.lancer("select code from public.clients where email = 'marie@exemple.com';")),
                       'envoye'))
    ok.append(verifier("un compte d'équipe (sans code) ne reçoit rien",
                       db.lancer("""update public.clients set code = null
                                    where id = '11111111-1111-1111-1111-111111111111';
                                    select public.courriels_bienvenue(
                                      '11111111-1111-1111-1111-111111111111', true);"""), 'sans-code'))
    db.lancer("""update public.clients set code = 'GSE-4323'
                 where id = '11111111-1111-1111-1111-111111111111';""")
    db.lancer("delete from vault.decrypted_secrets where name = 'email_cle_api';")
    ok.append(verifier("sans clé d'API, la base le dit au lieu de planter",
                       db.lancer("""select public.courriels_bienvenue(
                                    '11111111-1111-1111-1111-111111111111', true);"""), 'non-configure'))
    db.lancer("insert into vault.decrypted_secrets values ('email_cle_api', 'xkeysib-essai');")
    ok.append(verifier("un envoi qui échoue ne bloque pas la création du compte",
                       db.lancer("""drop function net.http_post(text, jsonb, jsonb, jsonb, integer);
                                    insert into auth.users (id, email, email_confirmed_at)
                                    values ('44444444-4444-4444-4444-444444444444', 'casse@exemple.com', now());
                                    select count(*)::text from public.clients
                                    where id = '44444444-4444-4444-4444-444444444444';""",
                                 echec_permis=True), '1', chiffre=True))
    db.lancer("""create function net.http_post(url text, body jsonb default '{}'::jsonb,
                   params jsonb default '{}'::jsonb, headers jsonb default '{}'::jsonb,
                   timeout_milliseconds integer default 5000)
                 returns bigint language sql as $$
                   insert into net.envois (url, headers, body) values (url, headers, body) returning id $$;""")

    print("\n3 bis. Qui peut renvoyer les e-mails à la main")
    code = db.lancer("select code from public.clients where email = 'marie@exemple.com';")
    ok.append(verifier('un administrateur, par le site',
                       db.lancer("""set request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
                                    set essai.admin = 'true';
                                    select public.renvoyer_courriels_bienvenue('%s');""" % code), 'envoye'))
    ok.append(verifier("l'équipe, depuis le SQL Editor (aucun client connecté)",
                       db.lancer("set essai.admin = 'false'; select public.renvoyer_courriels_bienvenue('%s');"
                                 % code), 'envoye'))
    refus = db.lancer_role('authenticator',
                           """set role authenticated;
                              set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000000000"}';
                              set essai.admin = 'false';
                              select public.renvoyer_courriels_bienvenue('%s');""" % code, echec_permis=True)
    ok.append(verifier('un client ordinaire, par le site : refusé',
                       str('Accès réservé aux administrateurs' in refus), 'True'))

    print('\n3 ter. Le format des codes clients')
    db.fichier(os.path.join(RACINE, 'outils', 'supabase-code-client.sql'))
    codes = db.lancer("""select string_agg(public.nouveau_code_client(), ' ')
                          from generate_series(1, 6);""").split()
    ok.append(verifier('six codes tirés : %s' % ' '.join(codes),
                       str(all(re.fullmatch(r'GSE-[1-9][0-9]{3}', c) for c in codes)), 'True'))
    db.lancer("""insert into public.clients (id, code, email)
                 select gen_random_uuid(), public.nouveau_code_client(),
                        'foule' || n || '@exemple.com'
                 from generate_series(1, 3000) n;""")
    ok.append(verifier('3000 comptes, 3000 codes tous différents',
                       db.lancer("""select count(distinct code)::text from public.clients
                                    where email like 'foule%@exemple.com';"""), '3000'))
    ok.append(verifier('tous au bon format',
                       db.lancer("""select count(*)::text from public.clients
                                    where email like 'foule%@exemple.com'
                                      and code !~ '^GSE-[1-9][0-9]{3}$';"""), '0'))
    # Une base presque pleine ne doit pas boucler sans fin : elle doit le dire.
    db.lancer("""insert into public.clients (id, code, email)
                 select gen_random_uuid(), 'GSE-' || n, 'plein' || n || '@exemple.com'
                 from generate_series(1000, 9999) n
                 on conflict do nothing;""")
    plein = db.lancer('select public.nouveau_code_client();', echec_permis=True)
    ok.append(verifier('base pleine : message clair au lieu d\'une boucle sans fin',
                       str('Plus de code client libre' in plein), 'True'))
    db.lancer("""delete from public.clients
                 where email like 'plein%@exemple.com' or email like 'foule%@exemple.com';""")

    print('\n4. Les quatre langues, et ce que reçoit le client')
    for i, (langue, nom) in enumerate([('fr', 'Marie-Ange Dorvil'), ('en', 'John Pierre'),
                                       ('es', 'Ana Rodríguez'), ('ht', 'Jean Baptiste')]):
        uid = '5555555%d-5555-5555-5555-555555555555' % i
        db.lancer("""insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
                     values ('%s', '%s@exemple.com', now(), '{"nom_complet":"%s","langue":"%s"}'::jsonb);"""
                  % (uid, langue, nom, langue))
        sujets = db.lancer("""select body ->> 'subject' from net.envois
                              where body -> 'to' -> 0 ->> 'email' = '%s@exemple.com' order by id;""" % langue)
        for ligne in sujets.splitlines():
            print('  %-3s %s' % (langue, ligne))
        ok.append(verifier('%s : deux e-mails' % langue, str(len(sujets.splitlines())), '2'))

    # Le code client et l'adresse doivent apparaître tels quels dans le corps
    code = db.lancer("select code from public.clients where email = 'fr@exemple.com';")
    corps = db.lancer("""select body ->> 'htmlContent' from net.envois
                         where body -> 'to' -> 0 ->> 'email' = 'fr@exemple.com' order by id;""")
    ok.append(verifier('le code client est dans le premier e-mail', str(code in corps), 'True'))
    ok.append(verifier("l'adresse de Miami est dans le second",
                       str('8140 NW 74th Ave Unit 3' in corps and 'Medley' in corps), 'True'))
    ok.append(verifier('le nom porte le code, comme sur le site',
                       str(('Marie-Ange Dorvil ' + code) in corps), 'True'))

    for i, nom in enumerate(('bienvenue', 'adresse')):
        html = db.lancer("""select body ->> 'htmlContent' from net.envois
                            where body -> 'to' -> 0 ->> 'email' = 'fr@exemple.com'
                            order by id limit 1 offset %d;""" % i)
        open(os.path.join(TRAVAIL, 'courriel-%s.html' % nom), 'w', encoding='utf-8').write(html)

    print('\n%d vérifications, %d réussies.' % (len(ok), sum(ok)))
    print('Aperçus : %s/courriel-bienvenue.html et courriel-adresse.html' % TRAVAIL)
    return 0 if all(ok) else 1


if __name__ == '__main__':
    sys.exit(main())
