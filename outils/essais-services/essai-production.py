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
    # Comme rls_auto_enable() de Supabase : une fonction d'event trigger privilégiée,
    # exécutable par tous, mais que PostgreSQL refuse d'appeler hors déclencheur
    db.sql("""create function public.essai_declencheur() returns event_trigger language plpgsql
                security definer set search_path = '' as 'begin end';""")
    lignes3 = lignes_controle(db, S.BASE, 'controle-securite.sql')
    verifier('une fonction de déclencheur ouverte n\'est pas une alerte, seulement une information',
             ([o for c, v, o, _d in lignes3 if v == 'ALERTE' and 'essai_declencheur' in o],
              [v for c, v, o, _d in lignes3 if c == 'Ouvert aux visiteurs' and 'essai_declencheur' in o]),
             ([], ['INFO']))
    r = subprocess.run([str(S.PSQL), '-U', db.su, '-h', db.socket, '-d', S.BASE, '-X', '-q',
                        '-c', 'set role anon; select public.essai_declencheur();'], capture_output=True, text=True)
    verifier('et un visiteur ne peut vraiment pas l\'appeler', 'can only be called' in r.stderr, True)
    db.sql('drop function public.essai_declencheur();')
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
    verifier('trois fichiers chiffrés (le manifeste aussi : le dépôt est public) et leurs empreintes SHA-256',
             [f[len(nom):] for f in fichiers],
             ['.comptes.dump.age', '.comptes.dump.age.sha256', '.manifeste.json.age', '.manifeste.json.age.sha256',
              '.public.dump.age', '.public.dump.age.sha256'])
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
                       env=dict(env_pg(cible), CIBLE_DB_URL=cible, RESTORE_TARGET='essai'), capture_output=True, text=True)
    verifier('avec une autre clé : refusé, rien de restauré', (r.returncode != 0,
             psql_dans(db, RESTAUREE, "select to_regclass('public.colis') is null;")), (True, 't'))
    r = subprocess.run(['bash', os.path.join(PRODUCTION, 'restaurer.sh'), os.path.join(travail, 'sortie'), nom, cle],
                       env=dict(env_pg(cible), CIBLE_DB_URL=cible, RESTORE_TARGET='essai'), capture_output=True, text=True)
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
                       env=dict(env_pg(cible), CIBLE_DB_URL=cible, RESTORE_TARGET='essai'), capture_output=True, text=True)
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
        env=dict(env_pg(cible), CIBLE_DB_URL=cible, RESTORE_TARGET='essai', **e), capture_output=True, text=True)
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

    # Avant G, qui introduit exprès des anomalies (orphelins) : une base saine, comme en service
    sauvegarde_autonome(db)

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
              delete from public.clients where id = '%s';
              -- Deux événements de facturation sans traite_le : l'un d'avant les
              -- notifications (comme les trois de la production, 26-27/09), l'autre
              -- resté coincé après leur installation
              update public.notification_moteur set actives_depuis = now() - interval '1 day';
              insert into public.evenements_facturation (type, cree_le)
                values ('FACTURE_ANNULEE', now() - interval '2 days'), ('FACTURE_CREEE', now() - interval '20 minutes');"""
           % (M.MARIE, M.JEAN, M.MARIE, M.MARIE, M.JEAN))
    lignes = lignes_controle(db, S.BASE, 'controle-integrite.sql')
    alertes = sorted(c for c, v, _n, _e in lignes if v == 'ALERTE')
    verifier('chaque anomalie introduite est vue', alertes, sorted([
        'Colis sans client', 'Factures sans client', 'Notifications sans client',
        'Envois en attente depuis plus de 15 min', 'Colis sur deux factures actives',
        'Paiements d\'un autre client que la facture', 'Payé ≠ somme des paiements',
        'Événements de facturation non traités (15 min)']))
    verifier('l\'événement d\'avant les notifications est compté à part, en information',
             [(v, n) for c, v, n, _e in lignes if c.startswith('Événements de facturation d\'avant')], [('INFO', '1')])
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


# Un rclone en panne sur commande, placé devant le vrai (essais seulement). PANNE contient
# des « opération:remote » : « copyto:stock_b » fait échouer un envoi vers stock_b,
# « lsf:stock_b » sa lecture, « cat-altere:stock_a » altère ce que la relecture de A reçoit.
RCLONE_EN_PANNE = """#!/bin/bash
cmd=""
for a in "$@"; do case "$a" in copyto|cat|lsf|deletefile) cmd="$a"; break ;; esac; done
for p in ${PANNE:-}; do
  op="${p%%:*}"; remote="${p#*:}"; touche=0
  for a in "$@"; do case "$a" in "$remote":*) touche=1 ;; esac; done
  [ "$touche" = 1 ] || continue
  if [ "$op" = "$cmd" ]; then echo "panne simulée : rclone $cmd sur $remote" >&2; exit 1; fi
  if [ "$op" = cat-altere ] && [ "$cmd" = cat ]; then "$VRAI_RCLONE" "$@" | sed '1s/^/X/'; exit "${PIPESTATUS[0]}"; fi
done
exec "$VRAI_RCLONE" "$@"
"""


def etape_stockage(travail, sortie, nom, conf):
    """TEST 2, 3, 4 (D2) : l'étape « Stockage externe » de sauvegarde.yml, extraite telle
    quelle et lancée comme GitHub lance une étape « shell: bash »
    (bash --noprofile --norc -eo pipefail), vers de vrais dossiers par le vrai rclone. A est
    obligatoire, B facultative : B absente → SKIPPED et vert ; toute destination
    configurée qui échoue (inaccessible, envoi, relecture, rétention) → l'étape échoue,
    donc le job et le workflow. Le même essai sous « bash -e » (le shell par défaut de
    GitHub, sans pipefail) montre le défaut corrigé : l'échec de B y passait en vert."""
    # Lu dans le texte des workflows (sans module YAML : le banc n'a que la bibliothèque
    # standard), avec l'indentation fixe des fichiers du dépôt
    flux = {f: open(os.path.join(RACINE, '.github', 'workflows', f), encoding='utf-8').read()
            for f in ('sauvegarde.yml', 'restauration-test.yml')}
    for f, w in flux.items():
        verifier('D2 : %s — toutes les étapes sous « shell: bash » (bash -eo pipefail)' % f,
                 re.search(r'^defaults:\n  run:\n    shell: bash$', w, re.M) is not None, True)
    lignes = flux['sauvegarde.yml'].splitlines()
    debut_job = lignes.index('  sauvegarder:')
    fin_job = next(i for i in range(debut_job + 1, len(lignes)) if re.match(r'^  [a-z]', lignes[i]))
    job = lignes[debut_job:fin_job]
    i_id = job.index('        id: stockage')
    debut = max(i for i in range(i_id) if job[i].startswith('      - '))
    fin = next((i for i in range(i_id + 1, len(job)) if job[i].startswith('      - ')), len(job))
    etape = job[debut:fin]
    verifier('… l\'étape « Stockage externe » ne tolère aucun échec (pas de continue-on-error, ni sur le job)',
             ([l for l in etape if 'continue-on-error' in l], [l for l in job if l.startswith('    continue-on-error')]), ([], []))
    i_run = etape.index('        run: |')
    corps = [l[10:] for l in etape[i_run + 1:] if l.startswith('          ') or not l.strip()]
    script = '\n'.join(corps).replace('${{ steps.copie.outputs.nom }}', nom) + '\n'
    faux_bin = os.path.join(travail, 'faux-bin')
    os.makedirs(faux_bin, exist_ok=True)
    open(os.path.join(faux_bin, 'rclone'), 'w').write(RCLONE_EN_PANNE)
    os.chmod(os.path.join(faux_bin, 'rclone'), 0o755)
    n = [0]

    def lancer_etape(a, b, panne='', shell=('-eo', 'pipefail')):
        n[0] += 1
        runner = os.path.join(travail, 'runner-%d' % n[0])
        os.makedirs(runner)
        shutil.copytree(sortie, os.path.join(runner, 'goship-backup'))
        open(os.path.join(runner, 'etape.sh'), 'w').write(script)
        dest = lambda x: '' if x == '' else (x if ':' in x else 'stock_%s:%s' % (x[0], os.path.join(runner, x)))
        env = dict(os.environ, RUNNER_TEMP=runner, SAUVEGARDE_RCLONE_CONFIG=open(conf).read(),
                   SAUVEGARDE_STOCKAGE=dest(a), SAUVEGARDE_STOCKAGE_B=dest(b), PANNE=panne,
                   VRAI_RCLONE=shutil.which('rclone'), PATH=faux_bin + os.pathsep + os.environ['PATH'])
        r = subprocess.run(['bash', '--noprofile', '--norc'] + list(shell) + [os.path.join(runner, 'etape.sh')],
                           cwd=RACINE, env=env, capture_output=True, text=True)
        return r.returncode, r.stdout + r.stderr

    rouge = lambda c: 'FAILED' if c else 'SUCCESS'
    c, s = lancer_etape('a-ok', '')
    verifier('TEST 3 : A correcte, B non configurée → B SKIPPED, étape SUCCESS',
             (rouge(c), 'Destination A : 6 fichiers envoyés et relus' in s, 'Destination B : SKIPPED' in s,
              'Destination B : 6 fichiers' in s), ('SUCCESS', True, True, False))
    c, s = lancer_etape('a-ok', 'b-ok')
    verifier('A et B correctes → les deux envoyées, relues et retenues, SUCCESS',
             (rouge(c), s.count('6 fichiers envoyés et relus'), 'SKIPPED' in s), ('SUCCESS', 2, False))
    for libelle, a, panne in (('A inaccessible (remote absent)', 'absente_a:goship', ''),
                              ('envoi vers A refusé (copyto)', 'a-ok', 'copyto:stock_a'),
                              ('relecture de A altérée (SHA-256)', 'a-ok', 'cat-altere:stock_a')):
        c, s = lancer_etape(a, '', panne)
        verifier('TEST 2 : %s → étape FAILED' % libelle, rouge(c), 'FAILED')
    for libelle, b, panne in (('B inaccessible (remote absent)', 'absente_b:goship', ''),
                              ('envoi vers B refusé (copyto)', 'b-ok', 'copyto:stock_b'),
                              ('relecture de B altérée (SHA-256)', 'b-ok', 'cat-altere:stock_b'),
                              ('B illisible à la rétention (lsf)', 'b-ok', 'lsf:stock_b')):
        c, s = lancer_etape('a-ok', b, panne)
        verifier('TEST 4 : %s, A correcte → étape FAILED (jamais SUCCESS)' % libelle,
                 (rouge(c), 'Destination A : 6 fichiers envoyés et relus' in s), ('FAILED', True))
    c, s = lancer_etape('a-ok', 'absente_b:goship', shell=('-e',))
    verifier('le défaut D2 reproduit : sous « bash -e » (sans pipefail), B en échec passait en SUCCESS', rouge(c), 'SUCCESS')


def serveur_neuf(recue, nom, cle, comptes_source, lancer):
    """TEST 1 (D1) : un serveur PostgreSQL NEUF, créé pour l'essai, sans aucun rôle de
    Supabase (ni anon, ni authenticated, ni service_role, ni authenticator), comme le
    conteneur postgres:17 des workflows. La vraie procédure (epreuve-restauration.sh,
    PREPARER_CIBLE=1) doit y réussir seule : rôles, tables, fonctions, RLS, données,
    séquences, déclencheurs, comptes."""
    import pgserver
    dossier = tempfile.mkdtemp(prefix='goship-neuf-')
    serveur = pgserver.get_server(os.path.join(dossier, 'pgdata'), cleanup_mode='delete')
    try:
        uri = serveur.get_uri()
        su, socket = re.match(r'postgresql://([^:@/]+)[^/]*/[^?]*\?host=(.+)$', uri).groups()
        adresse = lambda base: 'postgresql://%s@/%s?host=%s' % (su, base, socket)
        q = lambda base, sql: subprocess.run([str(S.PSQL), adresse(base), '-X', '-A', '-t', '-v', 'ON_ERROR_STOP=1', '-c', sql],
                                             capture_output=True, text=True, check=True).stdout.strip()
        ROLES = "('anon', 'authenticated', 'service_role', 'authenticator')"
        verifier('TEST 1 : serveur neuf — aucun des quatre rôles de Supabase au départ',
                 q('postgres', 'select count(*) from pg_roles where rolname in %s;' % ROLES), '0')
        q('postgres', 'create database goship_neuf;')
        r = lancer('epreuve-restauration.sh', recue, nom, cle, url=adresse('goship_neuf'), CIBLE_DB_URL=adresse('goship_neuf'),
                   RESTORE_TARGET='essai', PREPARER_CIBLE='1')
        print('     ' + '\n     '.join(l for l in r.stdout.strip().splitlines() if re.match(r'^[A-Z][A-Z ()]+:', l)))
        if r.returncode:
            print(r.stdout[-800:], r.stderr[-800:])
        lignes = ('TABLE COUNT', 'RLS', 'FUNCTION COUNT', 'CONSTRAINT CHECK', 'BUSINESS LOCKS', 'DATA CHECK',
                  'SEQUENCES', 'AUTH ACCOUNTS', 'AUTH DETAILS', 'RESTORE')
        verifier('TEST 1 : la vraie procédure sur le serveur neuf → PASS',
                 (r.returncode, r.stdout.count('FINAL RESULT:      PASS')), (0, 3))
        verifier('… tables, RLS, fonctions, contraintes, verrous, données, séquences, comptes : tous OK',
                 [l for l in lignes if not re.search(r'^%s: +OK' % re.escape(l), r.stdout, re.M)], [])
        verifier('… les quatre rôles existent, avec les attributs de Supabase',
                 q('postgres', "select string_agg(rolname || ':' || rolcanlogin || ':' || rolbypassrls, ' ' order by rolname) "
                               "from pg_roles where rolname in %s;" % ROLES),
                 'anon:false:false authenticated:false:false authenticator:false:false service_role:false:true')
        verifier('… déclencheurs recréés sur auth.users (profil client, bienvenue)',
                 q('goship_neuf', "select string_agg(tgname, ' ' order by tgname) from pg_trigger "
                                  "where tgrelid = 'auth.users'::regclass and not tgisinternal;"),
                 'courriels_bienvenue_confirmation creer_profil_client')
        verifier('… comptes restaurés avec identités et empreintes de mot de passe',
                 (q('goship_neuf', 'select count(*) from auth.users;'), q('goship_neuf', 'select count(*) from auth.identities;'),
                  q('goship_neuf', "select count(*) from auth.users where coalesce(encrypted_password, '') <> '';"),
                  q('goship_neuf', 'select count(*) from auth.users u where not exists '
                                   '(select 1 from auth.identities i where i.user_id = u.id);')),
                 (comptes_source['comptes'], comptes_source['identites'], comptes_source['mdp'], '0'))
        verifier('… les droits de Supabase reposés (anon et authenticated lisent le schéma public)',
                 q('goship_neuf', "select has_schema_privilege('anon', 'public', 'usage') and "
                                  "has_schema_privilege('authenticated', 'public', 'usage');"), 't')
    finally:
        serveur.cleanup()
        shutil.rmtree(dossier, ignore_errors=True)


def sauvegarde_autonome(db):
    """L. La sauvegarde autonome (Supabase Free) de bout en bout, sur une base jetable qui
    porte le vrai schéma GoShip (chaîne complète) et des données d'essai : sauvegarde,
    vérification, stockage externe par rclone (vrai rclone, destinations = dossiers
    locaux), rétention, récupération, restauration chronométrée, vérification de la base
    restaurée, garde-fous. Aucune base réelle n'est touchée."""
    print('\nL. Sauvegarde autonome : vérifiée, stockée hors du dépôt, retenue (7), récupérée, restaurée')
    if not shutil.which('rclone'):
        verifier('rclone installé (stockage externe)', False, True)
        return
    travail = tempfile.mkdtemp(prefix='goship-autonome-')
    proprio, epreuve = os.path.join(travail, 'proprio.key'), os.path.join(travail, 'epreuve.key')
    for f in (proprio, epreuve):
        subprocess.run(['age-keygen', '-o', f], capture_output=True, check=True)
    pub = lambda f: [l.split(': ')[1].strip() for l in open(f) if l.startswith('# public key')][0]
    secret = [l.strip() for l in open(epreuve) if l.startswith('AGE-SECRET-KEY')][0]
    source = 'postgresql://%s@/%s?host=%s' % (db.su, S.BASE, db.socket)
    sortie = os.path.join(travail, 'sortie')
    sorties = []                                   # tout ce que les scripts ont écrit, pour la recherche de secrets
    def lancer(script, *args, **env):
        r = subprocess.run(['bash', os.path.join(PRODUCTION, script)] + list(args),
                           env=dict(env_pg(env.pop('url', source)), **env), capture_output=True, text=True)
        sorties.append(r.stdout + r.stderr)
        return r

    # 1. La base ne répond pas : échec net, et le mot de passe n'apparaît nulle part
    r = lancer('sauvegarder.sh', sortie, SUPABASE_DB_URL='postgresql://postgres:motdepasse-essai-42@/nulle?host=/tmp/aucun-serveur',
               SAUVEGARDE_DESTINATAIRE=pub(proprio))
    verifier('base injoignable : échec (code 1), message clair, mot de passe jamais affiché',
             (r.returncode, 'Connexion à la base impossible' in r.stderr, 'motdepasse-essai-42' in r.stdout + r.stderr),
             (1, True, False))

    # TEST 5. L'adresse de la base (m1) : jamais de vrai secret, aucune connexion tentée
    faux = 'motdepasse-essai-42'
    adresses = [
        ('connexion directe', 'postgresql://postgres:%s@db.abcdefghijklmnopqrst.supabase.co:5432/postgres' % faux, 1),
        ('Transaction pooler (6543)', 'postgresql://postgres.abcdefghijklmnopqrst:%s@aws-0-us-east-1.pooler.supabase.com:6543/postgres' % faux, 1),
        ('Session pooler (5432)', 'postgresql://postgres.abcdefghijklmnopqrst:%s@aws-0-us-east-1.pooler.supabase.com:5432/postgres?sslmode=require' % faux, 0),
        ('Session pooler, port implicite', 'postgresql://postgres.abcdefghijklmnopqrst:%s@aws-1-eu-west-3.pooler.supabase.com/postgres' % faux, 0),
        ('pooler sans .<ref>', 'postgresql://postgres:%s@aws-0-us-east-1.pooler.supabase.com:5432/postgres' % faux, 1),
        ('pooler sans mot de passe', 'postgresql://postgres.abcdefghijklmnopqrst@aws-0-us-east-1.pooler.supabase.com:5432/postgres', 1),
        ('sslmode=disable', 'postgresql://postgres.abcdefghijklmnopqrst:%s@aws-0-us-east-1.pooler.supabase.com:5432/postgres?sslmode=disable' % faux, 1),
        ('chaîne clé=valeur', 'host=aws-0-us-east-1.pooler.supabase.com port=5432 user=postgres.x password=%s' % faux, 1),
        ('base jetable (socket)', source, 0),
    ]
    for libelle, adresse, attendu in adresses:
        r = lancer('verifier-adresse.sh', SUPABASE_DB_URL=adresse)
        verifier('adresse %s : %s, sans rien en afficher' % (libelle, 'ACCEPTED' if attendu == 0 else 'REFUSED'),
                 (r.returncode, ('ACCEPTÉE' if attendu == 0 else 'REFUSÉE') in r.stdout + r.stderr, faux in r.stdout + r.stderr,
                  'abcdefghijklmnopqrst' in r.stdout + r.stderr), (attendu, True, False, False))
    r = lancer('sauvegarder.sh', sortie, SUPABASE_DB_URL=adresses[0][1], SAUVEGARDE_DESTINATAIRE=pub(proprio))
    verifier('sauvegarder.sh avec la connexion directe : refusé AVANT toute connexion, rien écrit',
             (r.returncode, 'REFUSÉE' in r.stderr, 'Connexion à la base impossible' in r.stderr, os.path.isdir(sortie) and os.listdir(sortie)),
             (1, True, False, []))
    r = lancer('sauvegarder.sh', sortie, SUPABASE_DB_URL=adresses[1][1], SAUVEGARDE_DESTINATAIRE=pub(proprio))
    verifier('sauvegarder.sh avec le port 6543 : refusé avant toute connexion', (r.returncode, 'port 6543' in r.stderr), (1, True))

    # Les comptes de la base d'essai prennent ce que porte un vrai projet et que la
    # restauration doit rendre (m5) : l'empreinte du mot de passe et une identité
    # (auth.identities, de la forme posée par la section K), sur la doublure d'Auth de ce
    # banc seulement
    psql_dans(db, S.BASE, """
        alter table auth.users add column if not exists encrypted_password text;
        update auth.users set encrypted_password = '$2a$10$' || md5(id::text) where encrypted_password is null;
        create table if not exists auth.identities (id text primary key, user_id uuid,
               provider text, identity_data jsonb, cree_le timestamptz default now());
        insert into auth.identities (id, user_id, provider, identity_data)
          select id::text, id, 'email', jsonb_build_object('sub', id) from auth.users u
           where not exists (select 1 from auth.identities i where i.user_id = u.id)
          on conflict do nothing;
        update auth.users set email_confirmed_at = coalesce(email_confirmed_at, now())
          where id in (select id from auth.users order by id limit 2);""")
    comptes_source = {k: psql_dans(db, S.BASE, q).strip() for k, q in (
        ('comptes', 'select count(*) from auth.users;'), ('identites', 'select count(*) from auth.identities;'),
        ('mdp', "select count(*) from auth.users where coalesce(encrypted_password, '') <> '';"))}

    # 2. La sauvegarde, puis sa vérification sans et avec la clé
    r = lancer('sauvegarder.sh', sortie, SUPABASE_DB_URL=source, SAUVEGARDE_DESTINATAIRE=pub(proprio),
               RESTAURATION_DESTINATAIRE=pub(epreuve))
    verifier('sauvegarder.sh : base jointe, copie relue, chiffrée, empreintes', (r.returncode, 'Base jointe' in r.stdout,
             'Copie relue' in r.stdout, 'empreintes SHA-256 : faits' in r.stdout), (0, True, True, True))
    annonce = re.search(r'Copie relue : (\d+) tables avec données, (\d+) fonctions, (\d+) déclencheurs, (\d+) règles RLS', r.stdout)
    reel = psql_dans(db, S.BASE, "select (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace "
                     "where n.nspname = 'public' and c.relkind = 'r') || ' ' || (select count(*) from pg_proc p join pg_namespace n "
                     "on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind = 'f') || ' ' || (select count(*) from pg_trigger g "
                     "join pg_class c on c.oid = g.tgrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' "
                     "and not g.tgisinternal) || ' ' || (select count(*) from pg_policies where schemaname = 'public');").split()
    verifier('m4 : le journal annonce le vrai nombre de tables, fonctions, déclencheurs et règles RLS (%s)' % ' / '.join(reel),
             list(annonce.groups()) if annonce else None, reel)
    nom = sorted(os.listdir(sortie))[0].split('.')[0]
    verifier('nom horodaté à la seconde (goship-AAAA-MM-JJTHHMMSSZ)', re.match(r'^goship-\d{4}-\d\d-\d\dT\d{6}Z$', nom) is not None, True)
    r = lancer('verifier-sauvegarde.sh', sortie, nom)
    verifier('verifier-sauvegarde.sh sans clé : fichiers, tailles, SHA-256, chiffrement',
             (r.returncode, [l.split()[0] for l in r.stdout.splitlines() if ' OK ' in l]),
             (0, ['BACKUP', 'SIZE:', 'CHECKSUM:', 'ENCRYPTION:']))
    r = lancer('verifier-sauvegarde.sh', sortie, nom, epreuve)
    print('     ' + '\n     '.join(r.stdout.strip().splitlines()))
    verifier('… avec la clé d\'épreuve : déchiffrée, conforme au manifeste, structure relue, PASS',
             (r.returncode, 'DECRYPTION:        OK' in r.stdout, 'MANIFEST:          OK' in r.stdout,
              'DUMP STRUCTURE:    OK' in r.stdout, r.stdout.strip().endswith('PASS')), (0, True, True, True, True))
    autre = os.path.join(travail, 'autre.key')
    subprocess.run(['age-keygen', '-o', autre], capture_output=True, check=True)
    r = lancer('verifier-sauvegarde.sh', sortie, nom, autre)
    verifier('… avec une autre clé : DECRYPTION FAIL, code 1', (r.returncode, 'DECRYPTION:        FAIL' in r.stdout), (1, True))

    # 3. Un fichier chiffré altéré : la vérification et la restauration refusent, avant de déchiffrer
    abime = os.path.join(travail, 'abime')
    shutil.copytree(sortie, abime)
    f = os.path.join(abime, nom + '.public.dump.age')
    contenu = bytearray(open(f, 'rb').read())
    contenu[len(contenu) // 2] ^= 0xFF
    open(f, 'wb').write(bytes(contenu))
    r = lancer('verifier-sauvegarde.sh', abime, nom)
    verifier('un octet changé : CHECKSUM FAIL, code 1', (r.returncode, 'CHECKSUM:          FAIL' in r.stdout), (1, True))

    # 4. Le stockage externe : deux destinations rclone (ici deux dossiers, par le vrai rclone)
    conf = os.path.join(travail, 'rclone.conf')
    open(conf, 'w').write('[stock_a]\ntype = local\n\n[stock_b]\ntype = local\n')
    distant_a, distant_b = os.path.join(travail, 'distant-a'), os.path.join(travail, 'distant-b')
    stock = dict(RCLONE_CONFIG=conf, SAUVEGARDE_STOCKAGE='stock_a:' + distant_a, SAUVEGARDE_STOCKAGE_B='stock_b:' + distant_b)
    r = lancer('stocker.sh', 'envoyer', sortie, nom, **stock)
    verifier('envoyer : 6 fichiers vers A et vers B, relus, SHA-256 identiques',
             (r.returncode, r.stdout.count('6 fichiers envoyés et relus')), (0, 2))
    verifier('… les destinations ne sont jamais écrites en entier dans le journal', distant_a in r.stdout + r.stderr, False)
    r = lancer('stocker.sh', 'envoyer', sortie, nom, **stock)
    verifier('renvoyer la même sauvegarde : sans effet, réussi', r.returncode, 0)
    r = lancer('stocker.sh', 'envoyer', abime, nom, **stock)
    verifier('envoyer une copie altérée : refusé avant tout envoi (empreinte locale fausse)', (r.returncode, 'Empreinte locale fausse' in r.stderr), (1, True))
    faux = os.path.join(travail, 'faux')
    shutil.copytree(abime, faux)
    subprocess.run('cd "%s" && sha256sum %s.public.dump.age > %s.public.dump.age.sha256' % (faux, nom, nom), shell=True, check=True)
    r = lancer('stocker.sh', 'envoyer', faux, nom, **stock)
    verifier('un autre fichier sous le même nom : jamais remplacé (--immutable), échec', r.returncode != 0, True)
    verifier('… et la copie distante est restée l\'originale',
             hashlib.sha256(open(os.path.join(distant_a, nom + '.public.dump.age'), 'rb').read()).hexdigest(),
             hashlib.sha256(open(os.path.join(sortie, nom + '.public.dump.age'), 'rb').read()).hexdigest())
    r = lancer('stocker.sh', 'lister', **stock)
    verifier('lister : la sauvegarde complète', r.stdout.split(), [nom])
    etape_stockage(travail, sortie, nom, conf)

    # 5. La rétention : 10 sauvegardes plus anciennes (dont une à l'ancien format), une
    # incomplète et un fichier étranger ; on garde les 7 plus récentes, 3 suppressions au plus
    anciennes = ['goship-2026-09-%02dT052300Z' % j for j in range(11, 20)] + ['goship-2026-09-01T0523Z']
    for a in anciennes:
        for fichier in os.listdir(sortie):
            shutil.copy(os.path.join(sortie, fichier), os.path.join(distant_a, fichier.replace(nom, a)))
    shutil.copy(os.path.join(sortie, nom + '.public.dump.age'), os.path.join(distant_a, 'goship-2026-08-30T052300Z.public.dump.age'))
    open(os.path.join(distant_a, 'notes.txt'), 'w').write('à garder')
    r = lancer('stocker.sh', 'retention', '5', **stock)
    verifier('garder 5 : refusé (7 au moins), rien supprimé', (r.returncode, len(os.listdir(distant_a))), (1, 11 * 6 + 2))
    r = lancer('stocker.sh', 'retention', **stock)
    completes = lambda: lancer('stocker.sh', 'lister', **stock).stdout.split()
    verifier('1er passage : 11 complètes → 3 supprimées au plus, 8 restent', (r.returncode, len(completes())), (0, 8))
    r = lancer('stocker.sh', 'retention', **stock)
    reste = completes()
    verifier('2e passage : 7 gardées, les plus récentes (la nouvelle en tête)',
             (r.returncode, reste), (0, [nom] + ['goship-2026-09-%02dT052300Z' % j for j in range(19, 13, -1)]))
    verifier('l\'ancienne incomplète est partie ; le fichier étranger est resté',
             (os.path.exists(os.path.join(distant_a, 'goship-2026-08-30T052300Z.public.dump.age')),
              os.path.exists(os.path.join(distant_a, 'notes.txt'))), (False, True))
    r = lancer('stocker.sh', 'retention', **stock)
    verifier('3e passage : rien à supprimer', (r.returncode, len(completes())), (0, 7))
    verifier('destination B : sa seule sauvegarde, jamais supprimée', lancer('stocker.sh', 'lister', SOURCE='B', **stock).stdout.split(), [nom])

    # 6. Récupérer (C7), puis altérer la copie distante : le téléchargement est refusé
    t0 = time.time()
    recue = os.path.join(travail, 'recue')
    r = lancer('stocker.sh', 'recuperer', 'derniere', recue, **stock)
    duree_telechargement = time.time() - t0
    verifier('recuperer « derniere » : la nouvelle, SHA-256 vérifiés', (r.returncode, r.stdout.strip()), (0, nom))
    f = os.path.join(distant_b, nom + '.comptes.dump.age')
    contenu = bytearray(open(f, 'rb').read())
    contenu[40] ^= 0x01
    open(f, 'wb').write(bytes(contenu))
    r = lancer('stocker.sh', 'recuperer', nom, os.path.join(travail, 'recue-b'), SOURCE='B', **stock)
    verifier('copie distante altérée (B) : téléchargement refusé', (r.returncode, 'SHA-256 faux' in r.stderr), (1, True))

    # 7. Les garde-fous de restaurer.sh
    EPREUVE = 'goship_autonome'
    def cible_neuve():
        psql_dans(db, 'postgres', 'drop database if exists %s with (force);' % EPREUVE)
        psql_dans(db, 'postgres', 'create database %s;' % EPREUVE)
        psql_dans(db, EPREUVE, subprocess.run([sys.executable, os.path.join(PRODUCTION, 'doublures-supabase.py')],
                                              capture_output=True, text=True, check=True).stdout)
        return 'postgresql://%s@/%s?host=%s' % (db.su, EPREUVE, db.socket)
    cible = cible_neuve()
    vide = lambda: psql_dans(db, EPREUVE, "select to_regclass('public.colis') is null;").strip()
    r = lancer('restaurer.sh', recue, nom, epreuve, url=cible, CIBLE_DB_URL=cible, RESTAURATION_ESSAI='1')
    verifier('sans RESTORE_TARGET : refusé, rien restauré', (r.returncode, 'RESTORE_TARGET' in r.stderr, vide()), (1, True, 't'))
    r = lancer('restaurer.sh', recue, nom, epreuve, url=cible, CIBLE_DB_URL=cible, RESTORE_TARGET='production')
    verifier('RESTORE_TARGET=production sans confirmation : refusé', (r.returncode, 'RESTORE_CONFIRM' in r.stderr, vide()), (1, True, 't'))
    r = lancer('restaurer.sh', recue, nom, epreuve, url=cible, CIBLE_DB_URL=cible, RESTORE_TARGET='staging', SUPABASE_DB_URL=cible)
    verifier('cible = la base en service (SUPABASE_DB_URL) hors « production » : refusé',
             (r.returncode, 'base de production' in r.stderr, vide()), (1, True, 't'))
    r = lancer('restaurer.sh', abime, nom, epreuve, url=cible, CIBLE_DB_URL=cible, RESTORE_TARGET='essai', RESTAURATION_ESSAI='1')
    verifier('sauvegarde altérée : restauration refusée avant déchiffrement', (r.returncode, 'SHA-256 différent' in r.stderr, vide()), (1, True, 't'))

    # 8. La restauration chronométrée : déchiffrer + vérifier, restaurer, rejouer la chaîne, vérifier la base
    t1 = time.time()
    r = lancer('verifier-sauvegarde.sh', recue, nom, epreuve)
    t2 = time.time()
    verifier('sauvegarde téléchargée : vérifiée et déchiffrable (PASS)', r.returncode, 0)
    r = lancer('restaurer.sh', recue, nom, epreuve, url=cible, CIBLE_DB_URL=cible, RESTORE_TARGET='essai', RESTAURATION_ESSAI='1')
    t3 = time.time()
    verifier('restaurer.sh (RESTORE_TARGET=essai) : lignes identiques au manifeste',
             (r.returncode, 'identiques au manifeste' in r.stdout), (0, True))
    if r.returncode:
        print(r.stdout[-600:], r.stderr[-600:])
    r = lancer('appliquer-chaine.sh', url=cible, CIBLE_DB_URL=cible, SANS_PG_NET='1')
    t4 = time.time()
    verifier('la chaîne de migrations se rejoue sur la base restaurée', r.returncode, 0)
    manifeste = os.path.join(travail, 'manifeste.json')
    subprocess.run(['age', '-d', '-i', epreuve, '-o', manifeste, os.path.join(recue, nom + '.manifeste.json.age')], check=True)
    r = lancer('verifier-restauration.sh', manifeste, url=cible, CIBLE_DB_URL=cible)
    t5 = time.time()
    print('     ' + '\n     '.join(r.stdout.strip().splitlines()))
    verifier('verifier-restauration.sh : connexion, tables, fonctions, contraintes, verrous, données, comptes : PASS',
             (r.returncode, r.stdout.count(' OK '), 'identiques au manifeste' in r.stdout,
              'comme dans la sauvegarde' in r.stdout, r.stdout.strip().endswith('PASS')), (0, 10, True, True, True))
    verifier('… séquences (valeurs) et détail des comptes (identités, mots de passe, confirmés) comme dans la sauvegarde',
             ('SEQUENCES:         OK' in r.stdout, 'AUTH DETAILS:      OK' in r.stdout,
              'identités : %s, avec mot de passe : %s' % (comptes_source['identites'], comptes_source['mdp']) in r.stdout), (True, True, True))
    # Une séquence remise à zéro sur la base restaurée : la vérification le voit
    psql_dans(db, EPREUVE, "select setval('public.numero_colis_seq', 1001, false);")
    r2 = lancer('verifier-restauration.sh', manifeste, url=cible, CIBLE_DB_URL=cible)
    verifier('… une séquence remise à zéro : SEQUENCES FAIL', (r2.returncode, 'SEQUENCES:         FAIL' in r2.stdout), (1, True))
    print('     RESTORE DURATION (base d\'essai, %s lignes) : téléchargement %.1f s + vérification/déchiffrement %.1f s + '
          'restauration %.1f s + chaîne %.1f s + validation %.1f s = %.1f s'
          % (json.load(open(manifeste))['lignes_par_table'] and sum(json.load(open(manifeste))['lignes_par_table'].values()),
             duree_telechargement, t2 - t1, t3 - t2, t4 - t3, t5 - t4, duree_telechargement + t5 - t1))
    # Une base restaurée abîmée (un verrou coupé) : la vérification le voit
    psql_dans(db, EPREUVE, 'alter table public.colis disable trigger verrou_statut;')
    r = lancer('verifier-restauration.sh', manifeste, url=cible, CIBLE_DB_URL=cible)
    verifier('… un verrou coupé sur la base restaurée : BUSINESS LOCKS FAIL, FAIL', (r.returncode, 'BUSINESS LOCKS:    FAIL' in r.stdout), (1, True))
    # Le script des workflows, tel qu'ils l'appellent : une base PostgreSQL VIDE, qu'il habille
    # lui-même en projet Supabase (PREPARER_CIBLE=1), puis tout l'enchaînement et le rapport
    psql_dans(db, 'postgres', 'drop database if exists goship_workflow with (force);')
    psql_dans(db, 'postgres', 'create database goship_workflow;')
    nue = 'postgresql://%s@/goship_workflow?host=%s' % (db.su, db.socket)
    r = lancer('epreuve-restauration.sh', recue, nom, epreuve, '%.0f' % duree_telechargement, url=nue, CIBLE_DB_URL=nue,
               RESTORE_TARGET='essai', PREPARER_CIBLE='1')
    print('     ' + '\n     '.join(l for l in r.stdout.strip().splitlines() if l.startswith(('RESTORE', 'BACKUP AGE', 'FINAL'))))
    verifier('epreuve-restauration.sh (celui des workflows) sur une base vide : PASS, durées et RPO écrits',
             (r.returncode, r.stdout.count('FINAL RESULT:      PASS'), 'RESTORE DURATION:' in r.stdout, 'BACKUP AGE (RPO):' in r.stdout),
             (0, 3, True, True))
    if r.returncode:
        print(r.stdout[-800:], r.stderr[-800:])
    r = lancer('epreuve-restauration.sh', recue, nom, epreuve, url=nue, CIBLE_DB_URL=nue, RESTORE_TARGET='production')
    verifier('… il refuse RESTORE_TARGET=production', (r.returncode, 'jamais production' in r.stderr), (1, True))
    r = lancer('epreuve-restauration.sh', recue, nom, epreuve, url=nue, RESTORE_TARGET='essai', PREPARER_CIBLE='1',
               CIBLE_DB_URL='postgresql://postgres.abcdefghijklmnopqrst:x@aws-0-us-east-1.pooler.supabase.com:5432/postgres')
    verifier('… PREPARER_CIBLE sur une adresse Supabase : refusé (aucun rôle créé dans un vrai projet)',
             (r.returncode, 'PREPARER_CIBLE refusé' in r.stderr), (1, True))
    serveur_neuf(recue, nom, epreuve, comptes_source, lancer)
    psql_dans(db, 'postgres', 'drop database if exists goship_workflow with (force);')
    # Le piège d'une restauration ratée : le bon schéma, mais aucune donnée. Jamais PASS.
    vide_mais_migree = cible_neuve()
    r = lancer('appliquer-chaine.sh', url=vide_mais_migree, CIBLE_DB_URL=vide_mais_migree, SANS_PG_NET='1')
    r = lancer('verifier-restauration.sh', manifeste, url=vide_mais_migree, CIBLE_DB_URL=vide_mais_migree)
    verifier('… une base au bon schéma mais sans données : DATA CHECK FAIL, AUTH ACCOUNTS FAIL, FAIL',
             (r.returncode, 'DATA CHECK:        FAIL' in r.stdout, 'AUTH ACCOUNTS:     FAIL' in r.stdout), (1, True, True))
    psql_dans(db, 'postgres', 'drop database if exists %s with (force);' % EPREUVE)

    # 9. Aucun secret dans ce que les scripts ont écrit
    tout = '\n'.join(sorties)
    verifier('aucune clé privée age, aucun mot de passe, aucune destination dans les journaux',
             ('AGE-SECRET-KEY' in tout, secret in tout, 'motdepasse-essai-42' in tout, distant_a in tout), (False, False, False, False))
    verifier('aucun fichier en clair laissé (ni .dump ni .json hors du chiffré)',
             [f for d in (sortie, recue, distant_a) for f in os.listdir(d) if f.endswith(('.dump', '.json', '.liste'))], [])
    shutil.rmtree(travail)

def jsonq_su(db, base, sql):
    return psql_dans(db, base, sql).strip()


if __name__ == '__main__':
    main()
