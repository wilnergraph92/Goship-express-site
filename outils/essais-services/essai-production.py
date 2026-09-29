#!/usr/bin/env python3
# =============================================================================
# Goship Express — banc d'essai de la mise en production (Phase 12)
#
#   python3 outils/essais-services/essai-production.py
#
# Sur une base jetable (jamais la vraie base) :
#   A. la chaîne officielle des migrations (outils/migrations.txt) est la même
#      partout : README.md, CLAUDE.md, les bancs d'essai ; les anciens fichiers
#      refusent de s'exécuter sur une base à jour ;
#   B. la chaîne complète s'installe, et se rejoue (vide, puis remplie, sans rien
#      changer aux données), sur une base qui a les droits
#      par défaut de Supabase (tout nouvel objet du schéma public ouvert à anon et
#      authenticated) : c'est là qu'un oubli de « revoke » se verrait ;
#   C. outils/production/controle-securite.sql : aucune alerte hors les comptes
#      d'essai et les extensions que la doublure n'a pas ; et il voit bien une table
#      sans RLS, une fonction privilégiée sans search_path, une fonction ouverte ;
#   D. sante() : ce qu'elle dit à un visiteur, et rien de plus ; « en_retard » quand
#      la file des notifications ne bouge plus ;
#   E. les index des recherches fréquentes (suivi, tableau de bord, scanner, factures) ;
#   F. sauvegarde chiffrée (sauvegarder.sh) → restauration dans une base neuve
#      (restaurer.sh) → chaîne rejouée → mêmes données, table par table, règles
#      toujours actives ; restauration refusée sur une base non vide ou avec une
#      mauvaise clé ;
#   G. outils/production/controle-integrite.sql : tout vert sur des données saines,
#      et chaque anomalie volontairement introduite est vue.
# =============================================================================
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

ICI = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True


def charger(nom, fichier):
    spec = importlib.util.spec_from_file_location(nom, os.path.join(ICI, fichier))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


S = charger('essai_services', 'essai-services.py')
M = charger('essai_mobile', 'essai-mobile.py')
RACINE = S.RACINE
OUTILS = os.path.join(RACINE, 'outils')
PRODUCTION = os.path.join(OUTILS, 'production')
BIN = os.path.dirname(str(S.PSQL))
verifier, jsonq, un = S.verifier, S.jsonq, S.un
RESTAUREE = 'goship_restauree'

CHAINE = [l.strip() for l in open(os.path.join(OUTILS, 'migrations.txt'), encoding='utf-8')
          if l.strip() and not l.startswith('#')]
ANCIENS = ('supabase-application.sql', 'supabase-bienvenue.sql', 'supabase-code-client.sql',
           'supabase-factures.sql', 'supabase-numero-facture.sql', 'supabase-securite.sql')

# Ce que Supabase fait sur tout projet : les objets créés par postgres dans le schéma
# public sont ouverts à anon et authenticated, sauf « revoke » explicite.
DROITS_SUPABASE = """
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
"""


def texte_migration(chemin):
    t = open(chemin, encoding='utf-8').read()
    return t.replace('create extension if not exists pg_net with schema extensions;', '')


def fichier_dans(db, base, chemin):
    """Comme Base.fichier, mais dans la base de son choix."""
    tmp = os.path.join(S.TRAVAIL, 'prod-' + os.path.basename(chemin))
    open(tmp, 'w', encoding='utf-8').write(texte_migration(chemin))
    r = subprocess.run([str(S.PSQL), '-U', db.su, '-h', db.socket, '-d', base, '-v', 'ON_ERROR_STOP=1',
                        '-X', '-q', '-f', tmp], capture_output=True, text=True)
    if r.returncode:
        raise SystemExit('ERREUR dans %s (%s)\n%s' % (chemin, base, r.stderr.strip()))


def psql_dans(db, base, sql, echec_permis=False):
    return db._psql(db.su, base, sql, echec_permis)


def lignes_controle(db, base, script):
    """Les lignes d'un script de contrôle : [(controle, verdict, objet, detail)]."""
    r = subprocess.run([str(S.PSQL), '-U', db.su, '-h', db.socket, '-d', base, '-v', 'ON_ERROR_STOP=1',
                        '-X', '-q', '-A', '-t', '-F', '\t', '-f', os.path.join(PRODUCTION, script)],
                       capture_output=True, text=True)
    if r.returncode:
        raise SystemExit('ERREUR dans %s\n%s' % (script, r.stderr.strip()))
    return [tuple(l.split('\t')) for l in r.stdout.splitlines() if l.strip()]


def empreintes(db, base):
    """Nombre de lignes et empreinte du contenu de chaque table du schéma public."""
    tables = psql_dans(db, base, """select relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
                                    where n.nspname = 'public' and c.relkind = 'r' order by 1;""").split()
    res = {}
    for t in tables:
        contenu = psql_dans(db, base, "select md5(coalesce(string_agg(x::text, '|' order by x::text), '')) || ':' || count(*) "
                                      "from public.%s x;" % t)
        res[t] = contenu
    return res


def env_pg(url):
    e = dict(os.environ)
    e.update(PG_DUMP=os.path.join(BIN, 'pg_dump'), PG_RESTORE=os.path.join(BIN, 'pg_restore'),
             PSQL=os.path.join(BIN, 'psql'))
    return e


def main():
    print('A. Une seule chaîne de migrations, la même partout')
    manquants = [f for f in CHAINE if not os.path.exists(os.path.join(OUTILS, f))]
    verifier('migrations.txt : %d fichiers, tous présents' % len(CHAINE), manquants, [])
    verifier('les bancs d\'essai suivent la même chaîne (essai-mobile.py)',
             list(M.FICHIERS), CHAINE)
    for doc in ('README.md', 'CLAUDE.md'):
        texte = open(os.path.join(RACINE, doc), encoding='utf-8').read()
        # La phrase d'ordre : chaque fichier de la chaîne y apparaît, dans l'ordre
        trouve = re.search(r'.*?'.join(re.escape(f) for f in CHAINE), texte, re.S) is not None
        verifier('%s : les %d fichiers cités dans l\'ordre de la chaîne' % (doc, len(CHAINE)), trouve, True)
    reste = sorted(os.path.basename(f) for f in os.listdir(OUTILS)
                   if f.endswith('.sql') and f not in CHAINE)
    verifier('hors chaîne : seulement les six anciens fichiers', reste, sorted(ANCIENS))
    gardes = [f for f in ANCIENS if 'Fichier obsolète' not in open(os.path.join(OUTILS, f), encoding='utf-8').read()[:1500]]
    verifier('chacun porte une garde qui l\'arrête sur une base à jour', gardes, [])

    print('\nB. La chaîne complète, sur une base aux droits par défaut de Supabase')
    db = S.Base()
    db.sql(S.DOUBLURES)
    db.sql(DROITS_SUPABASE)
    for f in CHAINE:
        db.fichier(os.path.join(OUTILS, f))
    for f in CHAINE:                                       # rejouable : une deuxième fois
        db.fichier(os.path.join(OUTILS, f))
    verifier('les %d fichiers s\'installent, puis se rejouent sans erreur' % len(CHAINE), True, True)
    refus = []
    for f in ANCIENS:
        r = subprocess.run([str(S.PSQL), '-U', db.su, '-h', db.socket, '-d', S.BASE, '-v', 'ON_ERROR_STOP=1',
                            '-X', '-q', '-f', os.path.join(OUTILS, f)], capture_output=True, text=True)
        refus.append('Fichier obsolète' in r.stderr and r.returncode != 0)
    verifier('les six anciens fichiers refusent de s\'exécuter', refus, [True] * len(ANCIENS))
    for email, (uid, _mdp, nom) in M.COMPTES.items():
        db.sql("""insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
                  values ('%s', '%s', now(), '{"nom_complet":"%s","pays":"HT","ville":"Pétion-Ville","telephone":"+509 3000 0000"}'::jsonb);"""
               % (uid, email, nom))
    db.sql("select public.definir_admin('equipe@goship.test');")
    jsonq(db, M.ADMIN, "select public.changer_role('employe@goship.test', 'employe');")
    M.peupler(db)
    verifier('données d\'essai : 27 colis, factures, paiements', un(db, 'select count(*) from public.colis;'), '27')
    # « Relancer l'un impose de relancer ceux qui le suivent » (README) : sur une base
    # déjà remplie, la chaîne rejouée ne doit rien changer aux données
    avant_rejeu = empreintes(db, S.BASE)
    for f in CHAINE:
        db.fichier(os.path.join(OUTILS, f))
    apres_rejeu = empreintes(db, S.BASE)
    verifier('chaîne rejouée sur une base remplie : aucune donnée modifiée',
             sorted(t for t in avant_rejeu if avant_rejeu[t] != apres_rejeu.get(t)), [])

    print('\nC. Contrôle de sécurité (outils/production/controle-securite.sql)')
    lignes = lignes_controle(db, S.BASE, 'controle-securite.sql')
    alertes = sorted((c, o) for c, v, o, _d in lignes if v == 'ALERTE')
    attendues = sorted([('Comptes de démonstration', e) for e in M.COMPTES if e.endswith(('.test', 'exemple.com'))]
                       + [('Extensions', 'pg_cron'), ('Extensions', 'pg_net')])
    verifier('seules alertes : comptes d\'essai et extensions absentes de la doublure', alertes, attendues)
    ouvertes = [o for c, v, o, _d in lignes if c == 'Ouvert aux visiteurs' and v == 'INFO' and 'privilégiées' in _d]
    verifier('avec les droits Supabase, un visiteur n\'appelle que suivre_colis et sante', ouvertes,
             ['sante, suivre_colis'])
    migr = [v for c, v, o, _d in lignes if c == 'Migrations']
    verifier('les %d migrations sont reconnues' % len(CHAINE), migr, ['OK'] * len(CHAINE))
    verrous = [(o, v) for c, v, o, _d in lignes if c == 'Verrous métier']
    verifier('les quatre verrous métier sont actifs', sorted(verrous),
             [('evenement_immuable', 'OK'), ('garde_facture', 'OK'), ('verrou_role', 'OK'), ('verrou_statut', 'OK')])
    # Le contrôle voit ce qu'il doit voir
    db.sql("""create table public.essai_sans_rls (x int);
              create function public.essai_sans_chemin() returns int language sql security definer as 'select 1';
              create function public.essai_ouverte() returns int language sql security definer
                set search_path = '' as 'select 2';
              alter table public.colis disable trigger verrou_statut;""")
    lignes2 = lignes_controle(db, S.BASE, 'controle-securite.sql')
    vues = sorted((c, o.split('(')[0]) for c, v, o, _d in lignes2 if v == 'ALERTE' and 'essai' in o or
                  (v == 'ALERTE' and c == 'Verrous métier'))
    verifier('il voit une table sans RLS, une fonction sans search_path, une fonction ouverte, un verrou coupé',
             vues, sorted([('RLS activée', 'essai_sans_rls'), ('Fonctions privilégiées', 'essai_sans_chemin'),
                           ('Ouvert aux visiteurs', 'essai_ouverte'), ('Ouvert aux visiteurs', 'essai_sans_chemin'),
                           ('Verrous métier', 'verrou_statut')]))
    db.sql("""drop table public.essai_sans_rls; drop function public.essai_sans_chemin();
              drop function public.essai_ouverte(); alter table public.colis enable trigger verrou_statut;""")
    r = subprocess.run([str(S.PSQL), '-U', db.su, '-h', db.socket, '-d', S.BASE, '-X', '-q', '-o', '/dev/null',
                        '-v', 'ON_ERROR_STOP=1'],
                       input='begin transaction read only;\n%s\nrollback;\nbegin transaction read only;\n%s\nrollback;\n'
                             % (open(os.path.join(PRODUCTION, 'controle-securite.sql')).read(),
                                open(os.path.join(PRODUCTION, 'controle-integrite.sql')).read()),
                       capture_output=True, text=True)
    verifier('les deux contrôles passent en transaction READ ONLY (ils n\'écrivent rien)', r.returncode, 0)

    print('\nD. sante() : vivacité et disponibilité')
    s = jsonq(db, None, 'select public.sante();')
    verifier('un visiteur sans compte : status ok, pret', (s['status'], s['base'], s['notifications'], s['pret']),
             ('ok', 'ok', 'ok', True))
    verifier('elle ne dit rien d\'autre', sorted(s), ['base', 'heure', 'notifications', 'pret', 'status'])
    n = un(db, "select id from public.notifications where canal = 'app' order by id limit 1;")
    db.sql("""insert into public.notification_envois (notification_id, canal, cible, statut, prochain_essai_le)
              values (%s, 'push', 'essai-bloque', 'attente', now() - interval '20 minutes');""" % n)
    s = jsonq(db, None, 'select public.sante();')
    verifier('un envoi bloqué depuis 20 min : notifications en_retard, pas prête', (s['notifications'], s['pret']),
             ('en_retard', False))
    db.sql("delete from public.notification_envois where cible = 'essai-bloque';")
    verifier('pas d\'autre fonction de santé ouverte (etat_*, diagnostic…)',
             un(db, """select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                       where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
                         and p.prosecdef and p.proname not in ('sante', 'suivre_colis');"""), '0')

    print('\nE. Index des recherches fréquentes')
    index = psql_dans(db, S.BASE, r"""select tablename || '(' || substring(indexdef from ' USING [a-z]+ \(([^)]*)\)') || ')'
                                      from pg_indexes where schemaname = 'public';""").splitlines()
    for t, col in (('colis', 'numero'), ('colis', 'suivi_transporteur'), ('colis', 'client_id'),
                   ('colis_historique', 'colis_id'), ('factures', 'client_id'), ('facture_lignes', 'facture_id'),
                   ('paiements', 'facture_id'), ('notifications', 'client_id'), ('notification_envois', 'prochain_essai_le')):
        present = any(i.startswith(t + '(') and i[len(t) + 1:].rstrip(')').split(',')[0].strip().split(' ')[0] == col for i in index)
        verifier('index %s(%s)' % (t, col), present, True)

    print('\nF. Sauvegarde chiffrée → restauration dans une base neuve')
    travail = tempfile.mkdtemp(prefix='goship-sauvegarde-')
    cle = os.path.join(travail, 'cle.txt')
    subprocess.run(['age-keygen', '-o', cle], capture_output=True, check=True)
    publique = [l.split(': ')[1].strip() for l in open(cle) if l.startswith('# public key')][0]
    url = 'postgresql://%s@/%s?host=%s' % (db.su, S.BASE, db.socket)
    r = subprocess.run(['bash', os.path.join(PRODUCTION, 'sauvegarder.sh'), os.path.join(travail, 'sortie')],
                       env=dict(env_pg(url), SUPABASE_DB_URL=url, SAUVEGARDE_DESTINATAIRE=publique),
                       capture_output=True, text=True)
    verifier('sauvegarder.sh réussit', (r.returncode, r.stderr.strip()[-200:]), (0, ''))
    fichiers = sorted(os.listdir(os.path.join(travail, 'sortie')))
    nom = fichiers[0].split('.')[0]
    verifier('trois fichiers, tous chiffrés (le manifeste aussi : le dépôt est public)', [f[len(nom):] for f in fichiers],
             ['.comptes.dump.age', '.manifeste.json.age', '.public.dump.age'])
    manifeste = json.loads(subprocess.run(['age', '-d', '-i', cle, os.path.join(travail, 'sortie', nom + '.manifeste.json.age')],
                                          capture_output=True, text=True, check=True).stdout)
    verifier('le manifeste compte les lignes (27 colis)', manifeste['lignes_par_table'].get('colis'), 27)
    brut = open(os.path.join(travail, 'sortie', nom + '.public.dump.age'), 'rb').read()
    verifier('rien de lisible dans le fichier chiffré (ni e-mail, ni numéro)',
             (b'marie@exemple.com' in brut, b'GSE-' in brut, brut.startswith(b'age-encryption.org')), (False, False, True))
    verifier('aucun fichier en clair laissé derrière', [f for f in fichiers if f.endswith('.dump')], [])

    avant = empreintes(db, S.BASE)
    resume_avant = jsonq(db, M.MARIE, 'select public.mon_resume();')
    psql_dans(db, 'postgres', 'drop database if exists %s with (force);' % RESTAUREE)
    psql_dans(db, 'postgres', 'create database %s;' % RESTAUREE)
    psql_dans(db, RESTAUREE, S.DOUBLURES)                 # un projet Supabase neuf : auth, vault, storage
    psql_dans(db, RESTAUREE, DROITS_SUPABASE)
    cible = 'postgresql://%s@/%s?host=%s' % (db.su, RESTAUREE, db.socket)
    mauvaise = os.path.join(travail, 'autre-cle.txt')
    subprocess.run(['age-keygen', '-o', mauvaise], capture_output=True, check=True)
    r = subprocess.run(['bash', os.path.join(PRODUCTION, 'restaurer.sh'), os.path.join(travail, 'sortie'), nom, mauvaise],
                       env=dict(env_pg(cible), CIBLE_DB_URL=cible), capture_output=True, text=True)
    verifier('avec une autre clé : refusé, rien de restauré', (r.returncode != 0,
             psql_dans(db, RESTAUREE, "select to_regclass('public.colis') is null;")), (True, 't'))
    r = subprocess.run(['bash', os.path.join(PRODUCTION, 'restaurer.sh'), os.path.join(travail, 'sortie'), nom, cle],
                       env=dict(env_pg(cible), CIBLE_DB_URL=cible), capture_output=True, text=True)
    verifier('restaurer.sh réussit, lignes identiques au manifeste',
             (r.returncode, 'identiques au manifeste' in r.stdout), (0, True))
    if r.returncode:
        print(r.stdout[-800:], r.stderr[-800:])
    for f in CHAINE:                                       # la chaîne rejouée sur la base restaurée
        fichier_dans(db, RESTAUREE, os.path.join(OUTILS, f))
    apres = empreintes(db, RESTAUREE)
    differentes = sorted(t for t in set(avant) | set(apres) if avant.get(t) != apres.get(t))
    verifier('après la chaîne rejouée : %d tables, contenu identique à l\'original' % len(avant), differentes, [])
    integ = [v for _c, v, _n, _e in lignes_controle(db, RESTAUREE, 'controle-integrite.sql')]
    verifier('contrôle d\'intégrité de la base restaurée : tout vert', sorted(set(integ)), ['OK'])
    secu = sorted((c, o) for c, v, o, _d in lignes_controle(db, RESTAUREE, 'controle-securite.sql') if v == 'ALERTE')
    verifier('contrôle de sécurité de la base restaurée : mêmes seules alertes', secu, attendues)
    r = subprocess.run(['bash', os.path.join(PRODUCTION, 'restaurer.sh'), os.path.join(travail, 'sortie'), nom, cle],
                       env=dict(env_pg(cible), CIBLE_DB_URL=cible), capture_output=True, text=True)
    verifier('une deuxième restauration sur cette base (non vide) : refusée',
             (r.returncode != 0, 'restauration refusée' in r.stderr), (True, True))
    # Les règles vivent : lecture d'un client, écriture par la porte prévue, verrou du statut
    def comme_restauree(compte, texte):
        entete = 'set role authenticated;\nset request.jwt.claims = \'{"sub":"%s"}\';\n' % compte
        return db._psql('authenticator', RESTAUREE, entete + texte)
    psql_dans(db, RESTAUREE, 'grant connect on database %s to authenticator;' % RESTAUREE)
    resume = json.loads(comme_restauree(M.MARIE, 'select public.mon_resume();').splitlines()[-1])
    verifier('Marie retrouve son compte : mon_resume identique à l\'original', resume, resume_avant)
    cree = json.loads(comme_restauree(M.ADMIN, """select public.creer_colis('{"client_id":"%s","description":"Après restauration",
        "poids_lb":2,"service":"aerien","pays_destination":"HT"}'::jsonb, null, true);""" % M.MARIE).splitlines()[-1])
    verifier('l\'équipe enregistre un colis : numéro, prix et facture calculés par la base',
             (cree['colis']['numero'].startswith('GSE-'), float(cree['colis']['prix_usd']) > 0, cree['facture'] is not None),
             (True, True, True))
    refus = psql_dans(db, RESTAUREE, "update public.colis set statut = 'livre' where numero = '%s';" % cree['colis']['numero'],
                      echec_permis=True)
    verifier('le statut ne change toujours pas par un UPDATE (verrou_statut)', 'ERROR' in refus, True)
    shutil.rmtree(travail)
    psql_dans(db, 'postgres', 'drop database if exists %s with (force);' % RESTAUREE)

    print('\nK. Restauration d\'épreuve (RESTAURATION_ESSAI=1) : le vrai auth.users a plus de colonnes que la doublure')
    # Comme en production : auth.users a des colonnes que la doublure n'a pas, et auth.identities existe
    psql_dans(db, S.BASE, """alter table auth.users add column if not exists aud varchar(255) default 'authenticated';
                             alter table auth.users add column if not exists instance_id uuid;
                             create table if not exists auth.identities (id text primary key, user_id uuid,
                                    provider text, identity_data jsonb, cree_le timestamptz default now());
                             insert into auth.identities (id, user_id, provider, identity_data)
                               select id::text, id, 'email', jsonb_build_object('sub', id) from auth.users
                             on conflict do nothing;""")
    travail = tempfile.mkdtemp(prefix='goship-epreuve-')
    cle = os.path.join(travail, 'cle.txt')
    subprocess.run(['age-keygen', '-o', cle], capture_output=True, check=True)
    cle2 = os.path.join(travail, 'cle-restauration.txt')
    subprocess.run(['age-keygen', '-o', cle2], capture_output=True, check=True)
    pub = lambda f: [l.split(': ')[1].strip() for l in open(f) if l.startswith('# public key')][0]
    source = 'postgresql://%s@/%s?host=%s' % (db.su, S.BASE, db.socket)
    r = subprocess.run(['bash', os.path.join(PRODUCTION, 'sauvegarder.sh'), os.path.join(travail, 'sortie')],
                       env=dict(env_pg(source), SUPABASE_DB_URL=source, SAUVEGARDE_DESTINATAIRE=pub(cle),
                                RESTAURATION_DESTINATAIRE=pub(cle2)),
                       capture_output=True, text=True)
    verifier('sauvegarde chiffrée pour deux destinataires (propriétaire + épreuve)',
             (r.returncode, '2 destinataire(s)' in r.stdout), (0, True))
    nom = sorted(os.listdir(os.path.join(travail, 'sortie')))[0].split('.')[0]
    EPREUVE = 'goship_epreuve'

    def cible_neuve():
        psql_dans(db, 'postgres', 'drop database if exists %s with (force);' % EPREUVE)
        psql_dans(db, 'postgres', 'create database %s;' % EPREUVE)
        psql_dans(db, EPREUVE, subprocess.run([sys.executable, os.path.join(PRODUCTION, 'doublures-supabase.py')],
                                              capture_output=True, text=True, check=True).stdout)
        return 'postgresql://%s@/%s?host=%s' % (db.su, EPREUVE, db.socket)
    restaurer = lambda cible, cle_privee, **e: subprocess.run(
        ['bash', os.path.join(PRODUCTION, 'restaurer.sh'), os.path.join(travail, 'sortie'), nom, cle_privee],
        env=dict(env_pg(cible), CIBLE_DB_URL=cible, **e), capture_output=True, text=True)
    r = restaurer(cible_neuve(), cle)
    verifier('sans le mode d\'épreuve, les comptes ne rentrent pas dans la doublure (refus net, rien d\'écrit)',
             (r.returncode != 0, psql_dans(db, EPREUVE, 'select count(*) from auth.users;').strip()), (True, '0'))
    cible = cible_neuve()
    t0 = time.time()
    r = restaurer(cible, cle2, RESTAURATION_ESSAI='1')
    verifier('mode d\'épreuve, avec la seule clé de restauration : lignes identiques au manifeste',
             (r.returncode, 'identiques au manifeste' in r.stdout), (0, True))
    if r.returncode:
        print(r.stdout[-600:], r.stderr[-600:])
    verifier('auth.users et auth.identities restaurés avec leurs vraies colonnes',
             psql_dans(db, EPREUVE, """select (select count(*) from information_schema.columns
                                                where table_schema = 'auth' and table_name = 'users' and column_name = 'aud')
                                       || ':' || (select count(*) from auth.identities)""").strip(),
             '1:' + psql_dans(db, S.BASE, 'select count(*) from auth.identities;').strip())
    r = subprocess.run(['bash', os.path.join(PRODUCTION, 'appliquer-chaine.sh')],
                       env=dict(env_pg(cible), CIBLE_DB_URL=cible, SANS_PG_NET='1'), capture_output=True, text=True)
    verifier('la chaîne se rejoue sur la base restaurée', r.returncode, 0)
    verifier('durée mesurée de la restauration + chaîne : %.0f s' % (time.time() - t0), time.time() - t0 < 600, True)
    shutil.rmtree(travail)
    psql_dans(db, 'postgres', 'drop database if exists %s with (force);' % EPREUVE)

    print('\nG. Contrôle d\'intégrité (outils/production/controle-integrite.sql)')
    lignes = lignes_controle(db, S.BASE, 'controle-integrite.sql')
    verifier('%d contrôles, tous verts sur des données saines' % len(lignes), sorted({v for _c, v, _n, _e in lignes}), ['OK'])
    # Des anomalies introduites en contournant les règles (comme le ferait une
    # correction manuelle hasardeuse) : chacune doit être vue.
    db.sql("""set session_replication_role = replica;
              update public.factures set montant_paye_usd = 7
               where id = (select id from public.factures where client_id = '%s' and montant_paye_usd = 0
                            order by numero limit 1);
              insert into public.paiements (facture_id, client_id, montant_usd, moyen, origine)
                select id, '%s', 1, 'especes', 'saisie' from public.factures where client_id = '%s' limit 1;
              insert into public.facture_lignes (facture_id, colis_id, libelle, montant_usd, quantite)
                select f2.id, l.colis_id, 'doublon', 0, 1
                  from public.facture_lignes l join public.factures f on f.id = l.facture_id
                  join public.factures f2 on f2.client_id = f.client_id and f2.id <> f.id and f2.statut <> 'annulee'
                 where f.client_id = '%s' limit 1;
              insert into public.notification_envois (notification_id, canal, cible, statut, prochain_essai_le)
                select id, 'push', 'essai-integrite', 'attente', now() - interval '1 hour'
                  from public.notifications where canal = 'app' limit 1;
              delete from public.clients where id = '%s';""" % (M.MARIE, M.JEAN, M.MARIE, M.MARIE, M.JEAN))
    lignes = lignes_controle(db, S.BASE, 'controle-integrite.sql')
    alertes = sorted(c for c, v, _n, _e in lignes if v == 'ALERTE')
    verifier('chaque anomalie introduite est vue', alertes, sorted([
        'Colis sans client', 'Factures sans client', 'Notifications sans client',
        'Envois en attente depuis plus de 15 min', 'Colis sur deux factures actives',
        'Paiements d\'un autre client que la facture', 'Payé ≠ somme des paiements']))
    exemples = {c: e for c, v, _n, e in lignes if v == 'ALERTE'}
    verifier('les exemples ne montrent que des numéros, jamais un nom ou une adresse',
             any(re.search(r'[a-z]+@|Marie|Jean|Pétion', e) for e in exemples.values()), False)

    print('\nH. controler.sh : les deux contrôles en lecture seule, sortie publiable, détail chiffré')
    travail = tempfile.mkdtemp(prefix='goship-controle-')
    cle = os.path.join(travail, 'cle.txt')
    subprocess.run(['age-keygen', '-o', cle], capture_output=True, check=True)
    publique = [l.split(': ')[1].strip() for l in open(cle) if l.startswith('# public key')][0]
    url = 'postgresql://%s@/%s?host=%s' % (db.su, S.BASE, db.socket)
    r = subprocess.run(['bash', os.path.join(PRODUCTION, 'controler.sh'), os.path.join(travail, 'sortie')],
                       env=dict(env_pg(url), CIBLE_DB_URL=url, SAUVEGARDE_DESTINATAIRE=publique),
                       capture_output=True, text=True)
    verifier('les anomalies de G et les comptes d\'essai donnent le code 1 (ALERTE)', r.returncode, 1)
    verifier('la sortie visible cite chaque contrôle d\'intégrité en alerte',
             all(c in r.stdout for c in ('Colis sans client', 'Payé ≠ somme des paiements')), True)
    verifier('aucune adresse e-mail en clair dans la sortie visible (masquées)',
             (re.search(r'[a-z0-9._-]+@goship\.test', r.stdout) is not None, '•••@goship.test' in r.stdout), (False, True))
    verifier('aucun numéro de colis ni de facture dans la sortie visible', re.search(r'GSE-\d|\d{4}-\d{2}-\d{4}', r.stdout), None)
    fichiers = os.listdir(os.path.join(travail, 'sortie'))
    verifier('le détail complet n\'est écrit que chiffré (un seul fichier .tar.age)',
             [f.endswith('.tar.age') for f in fichiers], [True])
    detail = subprocess.run('age -d -i %s %s | tar -xOf - integrite.tsv' % (cle, os.path.join(travail, 'sortie', fichiers[0])),
                            shell=True, capture_output=True, text=True).stdout
    verifier('déchiffré avec la clé privée, il contient les exemples', 'Colis sans client' in detail and 'GSE-' in detail, True)
    r = subprocess.run(['bash', os.path.join(PRODUCTION, 'controler.sh'), os.path.join(travail, 'sortie2')],
                       env=dict(env_pg(url), CIBLE_DB_URL='postgresql://%s:mot-de-passe-secret@/base_inexistante?host=%s'
                                % (db.su, db.socket)),
                       capture_output=True, text=True)
    verifier('base injoignable : code 2, jamais le mot de passe dans le message',
             (r.returncode, 'mot-de-passe-secret' in r.stdout + r.stderr), (2, False))
    shutil.rmtree(travail)

    print('\nI. essai-metier.sql : le parcours métier complet, dans une transaction annulée')
    def essai_metier():
        return subprocess.run([str(S.PSQL), '-U', db.su, '-h', db.socket, '-d', S.BASE, '-v', 'ON_ERROR_STOP=1',
                               '-X', '-q', '-f', os.path.join(PRODUCTION, 'essai-metier.sql')],
                              capture_output=True, text=True)
    avant = empreintes(db, S.BASE)
    r = essai_metier()
    oks = [l.split('OK ', 1)[1] for l in r.stderr.splitlines() if 'NOTICE:  OK ' in l]
    if r.returncode:
        print('\n'.join(l for l in r.stderr.splitlines() if 'NOTICE:  OK' not in l)[-1500:])
    verifier('le parcours passe (code 0)', (r.returncode, [l for l in r.stderr.splitlines() if 'ÉCHEC' in l or 'ERROR' in l]), (0, []))
    verifier('%d étapes réussies, dont notifications, sante() et l\'annulation finale' % len(oks),
             (len(oks) >= 11, any(o.startswith('notifications') for o in oks), any(o.startswith('sante()') for o in oks),
              any(o.startswith('transaction annulée') for o in oks)), (True, True, True, True))
    verifier('rien n\'est resté : chaque table identique, ligne pour ligne', empreintes(db, S.BASE), avant)
    db.sql('alter table public.colis disable trigger verrou_statut;')
    r = essai_metier()
    db.sql('alter table public.colis enable trigger verrou_statut;')
    verifier('verrou_statut retiré : l\'essai échoue et le dit', (r.returncode != 0, 'verrou_statut' in r.stderr), (True, True))
    verifier('même en échec, rien n\'est resté', empreintes(db, S.BASE), avant)

    print('\nJ. appliquer-chaine.sh et doublures-supabase.py : la chaîne sur un PostgreSQL neuf')
    NEUVE = 'goship_chaine'
    psql_dans(db, 'postgres', 'drop database if exists %s with (force);' % NEUVE)
    psql_dans(db, 'postgres', 'create database %s;' % NEUVE)
    doublures = subprocess.run([sys.executable, os.path.join(PRODUCTION, 'doublures-supabase.py')],
                               capture_output=True, text=True, check=True).stdout
    psql_dans(db, NEUVE, doublures)
    cible = 'postgresql://%s@/%s?host=%s' % (db.su, NEUVE, db.socket)
    chaine = lambda *a, **e: subprocess.run(['bash', os.path.join(PRODUCTION, 'appliquer-chaine.sh')] + list(a),
                                           env=dict(env_pg(cible), CIBLE_DB_URL=e.get('url', cible), SANS_PG_NET='1'),
                                           capture_output=True, text=True)
    r = chaine()
    verifier('les %d migrations passent dans l\'ordre, une par une' % len(CHAINE),
             (r.returncode, r.stdout.count('OK     ')), (0, len(CHAINE)))
    verifier('sante() répond sur la base ainsi migrée', jsonq_su(db, NEUVE, 'select public.sante() ->> \'status\';'), 'ok')
    r = chaine()
    verifier('rejouée une seconde fois : toujours sans erreur', r.returncode, 0)
    r = chaine('supabase-notifications.sql')
    verifier('à partir d\'un fichier : lui et ceux qui le suivent seulement', (r.returncode, r.stdout.count('OK     ')),
             (0, len(CHAINE) - CHAINE.index('supabase-notifications.sql')))
    r = chaine(url='postgresql://postgres:x@db.gpfdyslysqjmojgzggib.supabase.co:5432/postgres')
    verifier('adresse de la production : refus (code 3) avant toute connexion',
             (r.returncode, 'REFUS' in r.stdout), (3, True))
    psql_dans(db, NEUVE, 'drop function public.peut(text, uuid) cascade;')
    r = chaine('supabase-evenements.sql')
    en_echec = re.search(r'ÉCHEC  (\S+)', r.stdout)
    suivants = CHAINE[CHAINE.index(en_echec.group(1)) + 1:] if en_echec else []
    verifier('une migration en erreur arrête la chaîne (%s) : aucun fichier suivant n\'est lancé'
             % (en_echec.group(1) if en_echec else '?'),
             (r.returncode, bool(suivants), [f for f in suivants if 'OK     ' + f in r.stdout]), (1, True, []))
    psql_dans(db, 'postgres', 'drop database if exists %s with (force);' % NEUVE)

    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), sum(S.RESULTATS)))
    sys.exit(0 if all(S.RESULTATS) else 1)


def jsonq_su(db, base, sql):
    return psql_dans(db, base, sql).strip()


if __name__ == '__main__':
    main()
