# -*- coding: utf-8 -*-
"""Éprouve les règles métier de la base (outils/supabase-services.sql).

Installe la base COMPLÈTE — supabase.sql, supabase-facturation.sql, puis
supabase-services.sql — sur un PostgreSQL local et jetable, et rejoue ce que
font le tableau de bord, l'espace client et un visiteur : chacun connecté
comme le fait le site (rôle « authenticated » ou « anon », compte dans le
jeton), pour que les règles de sécurité s'appliquent vraiment.

Depuis la racine du site :

    python3 outils/essais-services/essai-services.py

Voir LISEZ-MOI.md.
"""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
import time

import pgserver

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.normpath(os.path.join(ICI, '..', '..'))
TRAVAIL = os.path.join(tempfile.gettempdir(), 'goship-essais-services')
PSQL = pathlib.Path(pgserver.__file__).parent / 'pginstall' / 'bin' / 'psql'
BASE = 'goship_services'

SCRIPTS = [os.path.join(RACINE, 'outils', f) for f in
           ('supabase.sql', 'supabase-facturation.sql', 'supabase-services.sql', 'supabase-evenements.sql')]

# Ce que Supabase apporte et qu'un PostgreSQL ordinaire n'a pas : les comptes
# (auth), le coffre-fort (vault), les appels sortants (pg_net) et le stockage.
# Des doublures, juste assez fidèles pour que les scripts s'installent.
DOUBLURES = r"""
create schema auth;
create schema vault;
create schema net;
create schema storage;
create schema extensions;

create table auth.users (
  id uuid primary key,
  email text,
  email_confirmed_at timestamptz,
  raw_user_meta_data jsonb default '{}'::jsonb
);

-- Chez Supabase, auth.uid() est lu dans le jeton envoyé par le navigateur
create function auth.uid() returns uuid language sql stable as $$
  select case when coalesce(current_setting('request.jwt.claims', true), '') = '' then null
              else (current_setting('request.jwt.claims', true)::jsonb ->> 'sub')::uuid end
$$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;

create table vault.decrypted_secrets (id uuid default gen_random_uuid(), name text primary key,
                                      decrypted_secret text);
create view vault.secrets as select id, name from vault.decrypted_secrets;
create function vault.create_secret(v text, n text) returns uuid language sql as $$
  insert into vault.decrypted_secrets (name, decrypted_secret) values (n, v) returning id $$;
create function vault.update_secret(i uuid, v text) returns void language sql as $$
  update vault.decrypted_secrets set decrypted_secret = v where id = i $$;

create table net.envois (id bigint generated always as identity primary key, url text, headers jsonb, body jsonb);
create table net._http_response (id bigint, status_code integer, content text, error_msg text,
                                 created timestamptz default now());
create function net.http_post(url text, body jsonb default '{}'::jsonb, params jsonb default '{}'::jsonb,
                              headers jsonb default '{}'::jsonb, timeout_milliseconds integer default 5000)
returns bigint language sql as $$
  insert into net.envois (url, headers, body) values (url, headers, body) returning id
$$;

create table storage.buckets (id text primary key, name text, public boolean);
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text);

create publication supabase_realtime;
"""

ADMIN = 'aaaaaaaa-0000-0000-0000-00000000000a'
ADMIN2 = 'aaaaaaaa-0000-0000-0000-00000000000b'
MARIE = '11111111-1111-1111-1111-111111111111'
JEAN = '22222222-2222-2222-2222-222222222222'


class Base:
    def __init__(self):
        os.makedirs(TRAVAIL, exist_ok=True)
        serveur = pgserver.get_server(os.path.join(TRAVAIL, 'pgdata'))
        self.socket = serveur.get_uri().split('host=')[1]
        self.su = self._superutilisateur()
        self._psql(self.su, 'postgres', """
            do $r$ begin
              if not exists (select 1 from pg_roles where rolname = 'anon') then
                create role anon nologin noinherit; end if;
              if not exists (select 1 from pg_roles where rolname = 'authenticated') then
                create role authenticated nologin noinherit; end if;
              if not exists (select 1 from pg_roles where rolname = 'authenticator') then
                create role authenticator login noinherit; end if;
              if not exists (select 1 from pg_roles where rolname = 'service_role') then
                create role service_role nologin noinherit bypassrls; end if;
            end $r$;
            grant anon, authenticated, service_role to authenticator;""")
        # Une base neuve à chaque lancement : rien ne traîne d'un essai à l'autre
        self._psql(self.su, 'postgres', 'drop database if exists %s with (force);' % BASE)
        self._psql(self.su, 'postgres', 'create database %s;' % BASE)

    def _superutilisateur(self):
        for nom in ('postgres', 'supabase_admin'):
            r = subprocess.run([str(PSQL), '-U', nom, '-h', self.socket, '-d', 'postgres', '-X', '-t', '-A',
                                '-c', 'select rolsuper from pg_roles where rolname = current_user;'],
                               capture_output=True, text=True)
            if r.returncode == 0 and r.stdout.strip() in ('t', 'true'):
                return nom
        raise SystemExit("Aucun superutilisateur trouvé sur la base d'essai.")

    def _psql(self, role, base, sql, echec_permis=False):
        r = subprocess.run([str(PSQL), '-U', role, '-h', self.socket, '-d', base,
                            '-v', 'ON_ERROR_STOP=1', '-X', '-q', '-t', '-A', '-c', sql],
                           capture_output=True, text=True)
        if r.returncode and not echec_permis:
            raise SystemExit('ERREUR SQL (%s)\n%s\n--- requête ---\n%s' % (role, r.stderr.strip(), sql.strip()[:600]))
        return (r.stdout + r.stderr).strip()

    def sql(self, texte, echec_permis=False):
        """Comme le SQL Editor : superutilisateur, personne de connecté."""
        return self._psql(self.su, BASE, texte, echec_permis)

    def comme(self, compte, texte, echec_permis=False):
        """Comme le site : rôle authenticated (ou anon), compte dans le jeton."""
        if compte is None:
            entete = 'set role anon;\n'
        else:
            entete = 'set role authenticated;\nset request.jwt.claims = \'{"sub":"%s"}\';\n' % compte
        return self._psql('authenticator', BASE, entete + texte, echec_permis)

    def erreur(self, compte, texte):
        """Le code métier de l'erreur (INVALID_WEIGHT…), ou « aucune »."""
        sortie = self.comme(compte, texte, echec_permis=True) if compte != 'sql' else self.sql(texte, True)
        for ligne in sortie.splitlines():
            if ligne.startswith('ERROR:'):
                return ligne.split(':', 1)[1].strip()
        return 'aucune'

    def fichier(self, chemin):
        texte = open(chemin, encoding='utf-8').read()
        # pg_net n'existe pas sur un PostgreSQL ordinaire : la doublure le remplace
        texte = texte.replace('create extension if not exists pg_net with schema extensions;', '')
        fichier = os.path.join(TRAVAIL, os.path.basename(chemin))
        open(fichier, 'w', encoding='utf-8').write(texte)
        r = subprocess.run([str(PSQL), '-U', self.su, '-h', self.socket, '-d', BASE,
                            '-v', 'ON_ERROR_STOP=1', '-X', '-q', '-f', fichier],
                           capture_output=True, text=True)
        if r.returncode:
            raise SystemExit('ERREUR dans %s\n%s' % (chemin, r.stderr.strip()))
        return r.stdout.strip()


RESULTATS = []


def verifier(titre, obtenu, attendu):
    obtenu = obtenu.strip() if isinstance(obtenu, str) else obtenu
    bon = obtenu == attendu
    print('  %s %-62s %s' % ('OK  ' if bon else 'RATÉ', titre, obtenu if len(str(obtenu)) < 60 else str(obtenu)[:57] + '…'))
    if not bon:
        print('       attendu : %s' % (attendu,))
    RESULTATS.append(bon)
    return bon


def jsonq(db, compte, texte):
    sortie = db.comme(compte, texte) if compte != 'sql' else db.sql(texte)
    lignes = [l for l in sortie.splitlines() if l.strip().startswith(('{', '[')) or l.strip() == '']
    return json.loads(lignes[-1]) if lignes and lignes[-1] else None


def colis(champs):
    return "'%s'::jsonb" % json.dumps(champs).replace("'", "''")


def creer(db, compte, champs, cle=None, facturer=True):
    return jsonq(db, compte, "select public.creer_colis(%s, %s, %s);"
                 % (colis(champs), "'%s'" % cle if cle else 'null', 'true' if facturer else 'false'))


def statut(db, compte, ids, vers, lieu='', note='', attendus=None, motif=None, cle=None):
    return jsonq(db, compte, "select public.changer_statut_colis(array[%s]::uuid[], '%s', '%s', '%s', %s, %s, %s);"
                 % (','.join("'%s'" % i for i in ids), vers, lieu.replace("'", "''"), note.replace("'", "''"),
                    "'%s'::jsonb" % json.dumps(attendus) if attendus else 'null',
                    "'%s'" % motif.replace("'", "''") if motif else 'null',
                    "'%s'" % cle if cle else 'null'))


def un(db, texte):
    return db.sql(texte).splitlines()[-1].strip() if db.sql(texte) else ''


def main():
    db = Base()
    db.sql(DOUBLURES)

    print('0. Installation')
    for chemin in SCRIPTS:
        db.fichier(chemin)
    print("  supabase.sql, supabase-facturation.sql et supabase-services.sql s'installent.")
    # Rejouable sans risque : tout relancer, dans le désordre, ne casse rien
    for chemin in SCRIPTS[::-1] + SCRIPTS:
        db.fichier(chemin)
    verifier('tout relancer deux fois, dans le désordre : aucune erreur', 'oui', 'oui')

    # Les comptes : deux membres de l'équipe, deux clients
    for uid, email, nom in ((ADMIN, 'equipe@goship.test', 'Équipe'), (ADMIN2, 'equipe2@goship.test', 'Équipe 2'),
                            (MARIE, 'marie@exemple.com', 'Marie-Ange Dorvil'),
                            (JEAN, 'jean@exemple.com', 'Jean Baptiste')):
        db.sql("""insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
                  values ('%s', '%s', now(), '{"nom_complet":"%s","pays":"HT","ville":"Port-au-Prince",
                          "adresse":"12 rue Capois"}'::jsonb);""" % (uid, email, nom))
    db.sql("select public.definir_admin('equipe@goship.test'); select public.definir_admin('equipe2@goship.test');")

    base = {'client_id': MARIE, 'description': 'Chaussures Nike', 'expediteur': 'Amazon',
            'poids_lb': 4.2, 'service': 'aerien', 'pays_destination': 'HT', 'destination': 'Pétion-Ville'}

    print('\n1. Création d\'un colis (ShipmentService.createShipment)')
    r = creer(db, ADMIN, dict(base, suivi_transporteur='tba-1', prix_usd=1, statut='livre', tarif_lb_usd=None),
              cle='cle-1')
    c = r['colis']
    verifier('numéro attribué par la base', c['numero'][:4] + '…' + c['numero'][-3:], 'GSE-…-HT')
    verifier('statut initial « Reçu », même si la page envoie « Livré »', c['statut'], 'recu')
    verifier('tarif de la maison appliqué : 5 $/lb', c['tarif_lb_usd'], 5)
    verifier('prix calculé par la base (4,2 × 5), pas celui envoyé (1)', c['prix_usd'], 21)
    verifier('suivi vendeur mis en majuscules', c['suivi_transporteur'], 'TBA-1')
    verifier('événement initial dans l\'historique',
             un(db, "select count(*) || ' ' || min(statut) from colis_historique where colis_id = '%s';" % c['id']),
             '1 recu')
    f = r['facture']
    verifier('facture créée dans la même transaction', f is not None and f['statut'], 'a_payer')
    verifier('facture = prix + 10 $ de frais, une fois',
             '%s = %s + %s' % (f['montant_usd'], f['facture_lignes'][0]['montant_usd'], f['frais_service_usd']),
             '31.0 = 21.0 + 10.0')
    verifier('la ligne nomme le colis', f['facture_lignes'][0]['colis']['numero'], c['numero'])
    verifier('le client de la facture est celui du colis', f['clients']['nom_complet'], 'Marie-Ange Dorvil')

    print('\n2. Requête répétée (double clic, connexion qui coupe)')
    r2 = creer(db, ADMIN, dict(base, suivi_transporteur='tba-1'), cle='cle-1')
    verifier('même clé : le colis déjà créé est rendu', (r2['deja'], r2['colis']['id'] == c['id']), (True, True))
    verifier('et sa facture, sans en créer une deuxième',
             un(db, "select count(*) from facture_lignes where colis_id = '%s';" % c['id']), '1')
    verifier('même clé pour un autre client : refusé',
             db.erreur(ADMIN, "select public.creer_colis(%s, 'cle-1');" % colis(dict(base, client_id=JEAN))),
             'DUPLICATE_OPERATION')
    verifier('suivi vendeur déjà pris (même en minuscules) : refusé',
             db.erreur(ADMIN, "select public.creer_colis(%s, 'cle-2');" % colis(dict(base, suivi_transporteur='TbA-1'))),
             'TRACKING_ALREADY_EXISTS')

    print('\n3. Validation côté base')
    cas = [('poids nul', {'poids_lb': 0}, 'INVALID_WEIGHT'),
           ('poids négatif', {'poids_lb': -3}, 'INVALID_WEIGHT'),
           ('poids absent', {'poids_lb': None}, 'INVALID_WEIGHT'),
           ('poids illisible', {'poids_lb': 'lourd'}, 'INVALID_WEIGHT'),
           ('poids de 45 000 lb (faute de frappe)', {'poids_lb': 45000}, 'INVALID_WEIGHT'),
           ('tarif négatif', {'tarif_lb_usd': -1}, 'INVALID_RATE'),
           ('tarif illisible', {'tarif_lb_usd': 'x'}, 'INVALID_RATE'),
           ('description vide', {'description': '   '}, 'INVALID_DESCRIPTION'),
           ('client inconnu', {'client_id': '99999999-9999-9999-9999-999999999999'}, 'CLIENT_NOT_FOUND'),
           ('client illisible', {'client_id': 'GSE-12'}, 'CLIENT_NOT_FOUND'),
           ('un compte de l\'équipe n\'est pas un client', {'client_id': ADMIN}, 'CLIENT_NOT_FOUND'),
           ('service inconnu', {'service': 'fusee'}, 'INVALID_SERVICE'),
           ('destination inconnue', {'pays_destination': 'FR'}, 'INVALID_DESTINATION'),
           ('réception dans le futur', {'recu_le': '2099-01-01T00:00:00Z'}, 'INVALID_DATE')]
    for titre, modif, code in cas:
        verifier(titre, db.erreur(ADMIN, "select public.creer_colis(%s);" % colis(dict(base, **modif))), code)
    verifier('aucun colis de trop après ces refus', un(db, 'select count(*) from colis;'), '1')
    r0 = creer(db, ADMIN, dict(base, tarif_lb_usd=0, description='Cadeau'), facturer=False)
    verifier('tarif 0 accepté (geste commercial) : prix 0', r0['colis']['prix_usd'], 0)
    r_arrondi = creer(db, ADMIN, dict(base, poids_lb=2.25, tarif_lb_usd=1.5), facturer=False)
    verifier('arrondi au cent : 2,25 × 1,5 = 3,375 → 3,38', r_arrondi['colis']['prix_usd'], 3.38)

    print('\n4. Même règles par l\'ancien chemin (écriture directe dans la table)')
    verifier('INSERT direct au statut « Livré » : refusé',
             db.erreur(ADMIN, "insert into colis (client_id, description, poids_lb, statut) values ('%s', 'x', 1, 'livre');"
                       % MARIE), 'INVALID_STATUS')
    un_id = db.comme(ADMIN, "insert into colis (client_id, description, poids_lb, prix_usd) "
                            "values ('%s', 'Direct', 3, 999) returning id;" % MARIE).splitlines()[0]
    verifier('INSERT direct avec un prix de 999 $ : ramené à 3 × 5',
             un(db, "select prix_usd from colis where id = '%s';" % un_id), '15.00')
    verifier('UPDATE direct Reçu → Livré : refusé',
             db.erreur(ADMIN, "update colis set statut = 'livre' where id = '%s';" % un_id),
             'INVALID_STATUS_TRANSITION')
    db.comme(ADMIN, "update colis set description = 'Direct (corrigé)', prix_usd = 1 where id = '%s';" % un_id)
    verifier('UPDATE direct du prix sans changer le poids : prix inchangé',
             un(db, "select prix_usd from colis where id = '%s';" % un_id), '15.00')

    print('\n5. Permissions (PermissionService)')
    verifier('un client ne crée pas de colis',
             db.erreur(MARIE, "select public.creer_colis(%s);" % colis(base)), 'PERMISSION_DENIED')
    verifier('ni ne change un statut',
             db.erreur(MARIE, "select public.changer_statut_colis(array['%s']::uuid[], 'embarque');" % c['id']),
             'PERMISSION_DENIED')
    verifier('ni ne facture',
             db.erreur(MARIE, "select public.facturer_colis('%s');" % c['id']), 'PERMISSION_DENIED')
    verifier('par la table non plus : aucune ligne touchée',
             db.comme(MARIE, "with m as (update colis set statut = 'livre' where id = '%s' returning 1) "
                             "select count(*) from m;" % c['id']), '0')
    verifier('un visiteur ne peut même pas appeler les services',
             un(db, "select has_function_privilege('anon', 'public.creer_colis(jsonb, text, boolean)', 'execute')"
                    " or has_function_privilege('anon', 'public.changer_statut_colis(uuid[], text, text, text, jsonb, text, text)', 'execute');"),
             'f')
    verifier('peut() : l\'équipe voit tout', db.comme(ADMIN, "select public.peut('shipments.view');"), 't')
    verifier('peut() : un client voit SES colis',
             db.comme(MARIE, "select public.peut('shipments.view', '%s');" % MARIE), 't')
    verifier('peut() : pas ceux d\'un autre',
             db.comme(MARIE, "select public.peut('shipments.view', '%s');" % JEAN), 'f')
    verifier('personne de connecté : aucune permission', db.comme(None, "select public.peut('shipments.view');",
                                                                    echec_permis=True).splitlines()[-1][:40] != 't', True)

    print('\n6. Transitions de statut (StatusService)')
    i = c['id']
    verifier('Reçu → Livré : interdit', statut(db, ADMIN, [i], 'livre')['refus'][0]['code'],
             'INVALID_STATUS_TRANSITION')
    verifier('Reçu → Embarqué (Emballé est facultatif)', statut(db, ADMIN, [i], 'embarque', 'Miami')['modifies'], 1)
    verifier('Embarqué → Action requise', statut(db, ADMIN, [i], 'incident', 'Douane', 'Facture demandée')['modifies'], 1)
    verifier('Action requise → Livré : interdit', statut(db, ADMIN, [i], 'livre')['refus'][0]['code'],
             'INVALID_STATUS_TRANSITION')
    verifier('Action requise → Embarqué (retour)', statut(db, ADMIN, [i], 'embarque', 'Port-au-Prince')['modifies'], 1)
    p = jsonq(db, ADMIN, "select public.statuts_possibles('%s');" % i)
    verifier('statuts possibles depuis Embarqué (Reçu seulement en correction)',
             (','.join(sorted(p['possibles'])), p['correction']),
             ('disponible,distribution,embarque,incident,succursale', 'recu'))
    verifier('Disponible sans agence : refusé',
             db.erreur(ADMIN, "select public.changer_statut_colis(array['%s']::uuid[], 'disponible');" % i),
             'LOCATION_REQUIRED')
    verifier('Embarqué → Disponible', statut(db, ADMIN, [i], 'disponible', 'Agence de Pétion-Ville')['modifies'], 1)
    verifier('Disponible → Livré', statut(db, ADMIN, [i], 'livre', 'Pétion-Ville')['modifies'], 1)
    verifier('Livré → Reçu : interdit', statut(db, ADMIN, [i], 'recu')['refus'][0]['code'],
             'INVALID_STATUS_TRANSITION')
    verifier('Livré → Disponible sans motif : refusé (c\'est une correction)',
             statut(db, ADMIN, [i], 'disponible', 'Agence de Pétion-Ville')['refus'][0]['code'], 'INVALID_EVENT_DATA')
    verifier('Livré → Disponible avec son motif : correction enregistrée',
             statut(db, ADMIN, [i], 'disponible', 'Agence de Pétion-Ville', motif='Livré par erreur')['modifies'], 1)
    verifier('statut inconnu', db.erreur(ADMIN, "select public.changer_statut_colis(array['%s']::uuid[], 'perdu');" % i),
             'INVALID_STATUS')
    verifier('colis inconnu',
             statut(db, ADMIN, ['99999999-9999-9999-9999-999999999999'], 'embarque')['refus'][0]['code'],
             'SHIPMENT_NOT_FOUND')
    evts = un(db, "select string_agg(statut, ' → ' order by id) from colis_historique where colis_id = '%s';" % i)
    verifier('historique : un événement par changement, dans l\'ordre', evts,
             'recu → embarque → incident → embarque → disponible → livre → disponible')

    print('\n7. Idempotence et conflits des statuts')
    avant = un(db, "select count(*) from colis_historique where colis_id = '%s';" % i)
    r = statut(db, ADMIN, [i], 'disponible', 'Agence de Pétion-Ville', attendus={i: 'livre'})
    verifier('même demande rejouée (double clic) : rien de réécrit', (r['modifies'], r['inchanges']), (0, 1))
    verifier('aucun événement en double',
             un(db, "select count(*) from colis_historique where colis_id = '%s';" % i), avant)
    r = statut(db, ADMIN, [i], 'livre', 'Pétion-Ville', attendus={i: 'embarque'})
    verifier('la page affichait un autre statut : conflit signalé', r['refus'][0]['code'], 'STATUS_CONFLICT')

    print('\n8. Lot tout ou rien')
    a = creer(db, ADMIN, dict(base, description='Lot A'), facturer=False)['colis']['id']
    b = creer(db, ADMIN, dict(base, description='Lot B'), facturer=False)['colis']['id']
    statut(db, ADMIN, [b], 'embarque', 'Miami')
    r = statut(db, ADMIN, [a, b], 'emballe', 'Miami')
    verifier('un colis du lot ne peut pas : aucun ne change', (r['modifies'], len(r['refus'])), (0, 1))
    verifier('le colis bloquant est nommé', r['refus'][0]['id'], b)
    verifier('l\'autre est resté « Reçu »', un(db, "select statut from colis where id = '%s';" % a), 'recu')
    r = statut(db, ADMIN, [a, b], 'distribution', 'Port-au-Prince')
    verifier('lot mixte Reçu/Embarqué → Centre de distribution : refusé pour le Reçu',
             [x['id'] for x in r['refus']], [a])
    r = statut(db, ADMIN, [a], 'embarque', 'Miami')
    r = statut(db, ADMIN, [a, b], 'distribution', 'Port-au-Prince')
    verifier('les deux Embarqués passent ensemble', r['modifies'], 2)

    print('\n9. Modification d\'un colis')
    m = jsonq(db, ADMIN, "select public.modifier_colis('%s', '{\"description\":\"Nike Air\"}'::jsonb);" % c['id'])
    verifier('changer la description ne touche pas au prix', m['prix_usd'], 21)
    m = jsonq(db, ADMIN, "select public.modifier_colis('%s', '{\"poids_lb\":\"5,5\",\"prix_usd\":1}'::jsonb);" % c['id'])
    verifier('changer le poids recalcule le prix (5,5 × 5)', m['prix_usd'], 27.5)
    verifier('la facture déjà émise, elle, ne bouge pas',
             un(db, "select f.montant_usd from factures f join facture_lignes l on l.facture_id = f.id "
                    "where l.colis_id = '%s';" % c['id']), '31.00')
    verifier('modifier_colis ignore le statut envoyé',
             jsonq(db, ADMIN, "select public.modifier_colis('%s', '{\"statut\":\"recu\"}'::jsonb);" % c['id'])['statut'],
             'disponible')
    verifier('modification pendant qu\'un autre modifiait : conflit',
             db.erreur(ADMIN, "select public.modifier_colis('%s', '{}'::jsonb, '2020-01-01');" % c['id']),
             'CONCURRENT_MODIFICATION')
    verifier('colis inconnu',
             db.erreur(ADMIN, "select public.modifier_colis('99999999-9999-9999-9999-999999999999', '{}');"),
             'SHIPMENT_NOT_FOUND')

    print('\n10. Facturation (BillingService)')
    r = jsonq(db, ADMIN, "select public.facturer_colis('%s');" % c['id'])
    verifier('facturer un colis déjà facturé : la facture existante est rendue', r['deja'], True)
    verifier('pas de deuxième facture pour lui',
             un(db, "select count(*) from facture_lignes where colis_id = '%s';" % c['id']), '1')
    verifier('creer_facture avec ce colis : refusé',
             db.erreur(ADMIN, "select public.creer_facture('%s', array['%s']::uuid[]);" % (MARIE, c['id'])),
             'INVOICE_ALREADY_EXISTS')
    fid = db.sql("select facture_id from facture_lignes where colis_id = '%s';" % c['id'])
    verifier('ligne ajoutée à la main pour ce colis : refusée aussi',
             db.erreur(ADMIN, "insert into facture_lignes (facture_id, colis_id, montant_usd) values ('%s', '%s', 1);"
                       % (fid, c['id'])), 'INVOICE_ALREADY_EXISTS')
    r = jsonq(db, ADMIN, "select public.creer_facture('%s', array['%s','%s']::uuid[], "
                         "'{\"montant_usd\":1,\"note\":\"Lot\"}'::jsonb, 'fac-1');" % (MARIE, a, b))
    fa = r['facture']
    verifier('facture de deux colis : leurs prix (2 × 21) + 10 $ une seule fois',
             (fa['montant_usd'], fa['frais_service_usd'], len(fa['facture_lignes'])), (52.0, 10.0, 2))
    verifier('le montant envoyé par la page (1 $) est ignoré', fa['montant_usd'] != 1, True)
    r = jsonq(db, ADMIN, "select public.creer_facture('%s', array['%s','%s']::uuid[], '{}'::jsonb, 'fac-1');"
              % (MARIE, a, b))
    verifier('même clé rejouée : même facture', (r['deja'], r['facture']['id'] == fa['id']), (True, True))
    j = creer(db, ADMIN, dict(base, client_id=JEAN, description='Colis de Jean'), facturer=False)['colis']['id']
    verifier('colis d\'un autre client sur la facture : refusé',
             db.erreur(ADMIN, "select public.creer_facture('%s', array['%s']::uuid[]);" % (MARIE, j)),
             'INVOICE_CLIENT_MISMATCH')
    libre = jsonq(db, ADMIN, "select public.creer_facture('%s', null, '{\"montant_usd\":\"12,5\"}'::jsonb);" % JEAN)
    verifier('facture libre (sans colis) : montant saisi, pas de frais',
             (libre['facture']['montant_usd'], libre['facture']['frais_service_usd']), (12.5, 0.0))
    verifier('montant libre négatif : refusé',
             db.erreur(ADMIN, "select public.creer_facture('%s', null, '{\"montant_usd\":-4}'::jsonb);" % JEAN),
             'INVALID_AMOUNT')
    verifier('frais de service modifiés après coup : refusé',
             db.erreur(ADMIN, "update factures set frais_service_usd = 0 where id = '%s';" % fa['id']), 'INVOICE_LOCKED')
    verifier('total d\'une facture de colis modifié : refusé',
             db.erreur(ADMIN, "update factures set montant_usd = 5 where id = '%s';" % fa['id']), 'INVOICE_LOCKED')
    verifier('payé plus que le total : refusé',
             db.erreur(ADMIN, "update factures set montant_paye_usd = 99 where id = '%s';" % fa['id']), 'INVALID_AMOUNT')
    db.comme(ADMIN, "update factures set montant_paye_usd = 31, statut = 'payee' where id = '%s';" % fa['id'])
    verifier('paiement enregistré, date de paiement posée',
             un(db, "select statut || ' ' || (payee_le is not null) from factures where id = '%s';" % fa['id']),
             'payee true')
    db.comme(ADMIN, "update factures set statut = 'annulee' where id = '%s';" % fa['id'])
    r = jsonq(db, ADMIN, "select public.facturer_colis('%s');" % a)
    verifier('facture annulée : le colis peut être refacturé', r['deja'], False)
    verifier('réactiver l\'ancienne facture doublerait : refusé',
             db.erreur(ADMIN, "update factures set statut = 'a_payer' where id = '%s';" % fa['id']),
             'INVOICE_ALREADY_EXISTS')

    print('\n11. Journal d\'audit (AuditService)')
    actions = un(db, "select string_agg(distinct action, ',' order by action) from journal_audit;")
    verifier('créations, statuts, modifications, paiements journalisés',
             all(x in actions.split(',') for x in ('colis.creation', 'colis.statut', 'colis.modification',
                                                   'facture.creation', 'facture.paiement')), True)
    verifier('l\'auteur est le compte connecté',
             un(db, "select auteur_id from journal_audit where action = 'colis.statut' limit 1;"), ADMIN)
    verifier('statut : avant et après',
             un(db, "select (avant ->> 'statut') || '→' || (apres ->> 'statut') from journal_audit "
                    "where action = 'colis.statut' and entite_id = '%s' order by id limit 1;" % c['id']),
             'recu→embarque')
    db.comme(MARIE, "update clients set adresse = '99 rue Secrète', telephone = '+509 0000' where id = '%s';" % MARIE)
    verifier('client modifié : le nom des champs, jamais leur contenu',
             un(db, "select coalesce(avant::text, '') || (apres -> 'champs')::text from journal_audit "
                    "where action = 'client.modification' order by id desc limit 1;"),
             '["adresse", "telephone"]')
    verifier('l\'adresse ne figure nulle part dans le journal',
             un(db, "select count(*) from journal_audit where avant::text like '%%Secrète%%' "
                    "or apres::text like '%%Secrète%%';"), '0')
    verifier('un client ne lit pas le journal', db.comme(MARIE, 'select count(*) from journal_audit;'), '0')
    verifier('l\'équipe le lit', db.comme(ADMIN, 'select count(*) > 0 from journal_audit;'), 't')
    verifier('personne n\'y écrit à la main',
             db.erreur(ADMIN, "insert into journal_audit (action, entite) values ('faux', 'colis');").startswith(
                 'permission denied'), True)

    print('\n12. Suivi (TrackingService)')
    pub = jsonq(db, None, "select public.suivre_colis('tba-1');")
    verifier('suivi public par le numéro vendeur', pub['numero'], c['numero'])
    verifier('suivi public : ni nom, ni note, ni prix',
             [k for k in ('nom_client', 'note', 'prix_usd', 'client_id', 'description') if k in json.dumps(pub)], [])
    verifier('suivi public : pas de note dans l\'historique',
             any('note' in h for h in pub['historique']), False)
    interne = jsonq(db, ADMIN, "select public.trouver_colis('%s');" % c['numero'].lower())
    verifier('suivi interne : le détail complet, notes comprises',
             (interne['nom_client'], interne['historique'][2]['note']), ('Marie-Ange Dorvil', 'Facture demandée'))
    verifier('suivi interne refusé à un client',
             db.erreur(MARIE, "select public.trouver_colis('%s');" % c['numero']), 'PERMISSION_DENIED')

    print('\n13. Flux 4 : chaque client ne voit que ses colis (RLS)')
    verifier('Marie : ses colis, aucun de Jean',
             db.comme(MARIE, "select count(*) filter (where client_id <> '%s') || '/' || (count(*) > 0) "
                             "from colis_details;" % MARIE), '0/true')
    verifier('Jean : le sien seulement', db.comme(JEAN, 'select count(*) from colis;'), '1')
    verifier('Jean ne lit pas l\'historique des colis de Marie',
             db.comme(JEAN, "select count(*) from colis_historique where colis_id = '%s';" % c['id']), '0')
    verifier('RLS toujours active sur les tables',
             un(db, "select count(*) from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r' "
                    "and not relrowsecurity;"), '0')

    print('\n14. Sécurité des fonctions')
    verifier('toute fonction « security definer » a un search_path fixé',
             un(db, "select count(*) from pg_proc where pronamespace = 'public'::regnamespace and prosecdef "
                    "and (proconfig is null or not exists (select 1 from unnest(proconfig) c "
                    "where c like 'search_path=%'));"), '0')
    internes = ['erreur_metier(text, text)', 'auditer(text, text, text, jsonb, jsonb)', 'regles_colis()',
                'colis_json(uuid)', 'facture_json(uuid)', 'exiger_permission(text, uuid)']
    verifier('les fonctions internes sont fermées au site',
             un(db, "select bool_or(has_function_privilege('authenticated', 'public.' || f, 'execute')) "
                    "from unnest(array[%s]) f;" % ','.join("'%s'" % x for x in internes)), 'f')

    print('\n15. Suppression d\'un client avec un vieux colis sans poids')
    db.sql("alter table colis disable trigger regles_colis;"
           "insert into colis (client_id, description, poids_lb) values ('%s', '', null);"
           "alter table colis enable trigger regles_colis;" % JEAN)
    db.sql("delete from auth.users where id = '%s';" % JEAN)
    verifier('le client part, ses colis restent sans client',
             un(db, "select count(*) from colis where client_id is null;"), '2')

    print('\n16. Concurrence')
    x = creer(db, ADMIN, dict(base, description='Course'), facturer=False)['colis']['id']
    sorties = {}

    def lancer(nom, compte, texte, pause=0):
        time.sleep(pause)
        sorties[nom] = db.comme(compte, texte, echec_permis=True)

    lent = ("begin; select public.changer_statut_colis(array['%s']::uuid[], 'embarque', 'Miami', '', "
            "'{\"%s\":\"recu\"}'::jsonb); select pg_sleep(1); commit;" % (x, x))
    rapide = ("select public.changer_statut_colis(array['%s']::uuid[], 'incident', 'Miami', '', "
              "'{\"%s\":\"recu\"}'::jsonb);" % (x, x))
    t1 = threading.Thread(target=lancer, args=('A', ADMIN, lent))
    t2 = threading.Thread(target=lancer, args=('B', ADMIN2, rapide, 0.3))
    t1.start(); t2.start(); t1.join(); t2.join()
    verifier('A et B changent le même colis : B attend, puis voit le conflit',
             'STATUS_CONFLICT' in sorties['B'], True)
    verifier('état final cohérent : celui de A, un seul événement',
             un(db, "select statut || ' ' || (select count(*) from colis_historique where colis_id = '%s') "
                    "from colis where id = '%s';" % (x, x)), 'embarque 2')

    creation = ("begin; select public.creer_colis(%s, 'meme-cle'); select pg_sleep(1); commit;"
                % colis(dict(base, description='Double envoi')))
    t1 = threading.Thread(target=lancer, args=('C', ADMIN, creation))
    t2 = threading.Thread(target=lancer, args=('D', ADMIN, creation, 0.3))
    t1.start(); t2.start(); t1.join(); t2.join()
    verifier('même création envoyée deux fois en même temps : un seul colis',
             un(db, "select count(*) from colis where description = 'Double envoi';"), '1')
    verifier('et une seule facture',
             un(db, "select count(*) from facture_lignes l join colis c on c.id = l.colis_id "
                    "where c.description = 'Double envoi';"), '1')

    y = creer(db, ADMIN, dict(base, description='Facture simultanée'), facturer=False)['colis']['id']
    fact = "begin; select public.facturer_colis('%s'); select pg_sleep(1); commit;" % y
    t1 = threading.Thread(target=lancer, args=('E', ADMIN, fact))
    t2 = threading.Thread(target=lancer, args=('F', ADMIN2, fact, 0.3))
    t1.start(); t2.start(); t1.join(); t2.join()
    verifier('deux factures demandées en même temps : une seule',
             un(db, "select count(*) from facture_lignes where colis_id = '%s';" % y), '1')

    z = [creer(db, ADMIN, dict(base, description='Scan %d' % k), facturer=False)['colis']['id'] for k in range(3)]
    for _ in range(3):
        statut(db, ADMIN, z, 'embarque', 'Miami', attendus={k: 'recu' for k in z})
    verifier('scan répété trois fois : un seul événement par colis',
             un(db, "select string_agg(n::text, ',') from (select count(*) n from colis_historique "
                    "where colis_id in ('%s') group by colis_id) s;" % "','".join(z)), '2,2,2')

    print('\n17. Volume')
    db.sql("""insert into colis (client_id, description, poids_lb)
              select '%s', 'Volume ' || n, 1 + n %% 20 from generate_series(1, 5000) n;""" % MARIE)
    debut = time.time()
    db.comme(ADMIN, "select count(*) from colis_details where statut = 'recu';"
                    "select id from colis_details where statut = 'recu' order by maj_le desc limit 50 offset 100;")
    duree = time.time() - debut
    verifier('5 000 colis : une page filtrée répond en moins d\'une seconde', duree < 1, True)
    verifier('5 000 colis de plus, chacun avec son événement initial',
             un(db, "select count(*) from colis c where description like 'Volume %%' and exists "
                    "(select 1 from colis_historique h where h.colis_id = c.id);"), '5000')

    print('\n18. Les mêmes règles dans le navigateur (mode démonstration)')
    demo = subprocess.run(['node', os.path.join(ICI, 'essai-demo.js'), '--regles'],
                          capture_output=True, text=True)
    if demo.returncode:
        print(demo.stdout, demo.stderr)
        verifier('essai-demo.js --regles', 'échec', 'ok')
    else:
        js = json.loads(demo.stdout)
        sql_transitions = jsonq(db, 'sql', 'select public.transitions_statut();')
        verifier('matrice des transitions : api.js = base',
                 {k: sorted(v) for k, v in js['transitions'].items()} ==
                 {k: sorted(v) for k, v in sql_transitions.items()}, True)
        sql_tarifs = jsonq(db, 'sql', 'select public.tarifs();')
        verifier('tarifs : api.js = base', (js['tarifs']['parLivre'], js['tarifs']['fraisService']),
                 (sql_tarifs['par_livre'], sql_tarifs['frais_service']))
        # Chaque paire de statuts, avec et sans étape précédente, doit donner
        # la même réponse des deux côtés.
        paires = [(de, vers, prec) for de in js['statuts'] for vers in js['statuts']
                  for prec in [None] + js['statuts'] if prec != de]
        valeurs = ','.join("(%s,%s,%s)" % ("'%s'" % de, "'%s'" % vers, "'%s'" % prec if prec else 'null::text')
                           for de, vers, prec in paires)
        sql_rep = db.sql("select string_agg(public.transition_permise(de, vers, prec)::text, ',' order by n) "
                         "from (select *, row_number() over () n from (values %s) v(de, vers, prec)) s;" % valeurs)
        sql_rep = [x == 'true' for x in sql_rep.split(',')]
        js_rep = json.loads(subprocess.run(['node', os.path.join(ICI, 'essai-demo.js'), '--paires'],
                                           input=json.dumps(paires), capture_output=True, text=True).stdout)
        ecarts = [paires[k] for k in range(len(paires)) if sql_rep[k] != js_rep[k]]
        verifier('%d cas de transition : même réponse des deux côtés' % len(paires), ecarts, [])
        prix = [(2.25, 1.5), (4.2, 5), (1.11, 5.55), (0.01, 5), (9999.99, 1000), (3.335, 3)]
        sql_prix = db.sql("select string_agg(public.prix_transport(p, t)::text, ',' order by n) from "
                          "(values %s) v(p, t, n);" % ','.join('(%s,%s,%d)' % (p, t, n) for n, (p, t) in enumerate(prix)))
        js_prix = json.loads(subprocess.run(['node', os.path.join(ICI, 'essai-demo.js'), '--prix'],
                                            input=json.dumps(prix), capture_output=True, text=True).stdout)
        verifier('prix au cent près : api.js = base',
                 [float(v) for v in sql_prix.split(',')], js_prix)

    print('\n%d vérifications, %d réussies.' % (len(RESULTATS), sum(RESULTATS)))
    return 0 if all(RESULTATS) else 1


if __name__ == '__main__':
    sys.exit(main())
