# -*- coding: utf-8 -*-
"""Les pré-alertes lues par l'équipe (Palier A), vues de la base.

Le Palier A n'ajoute RIEN à la base : ni table, ni colonne, ni fonction, ni règle.
Le tableau de bord lit public.prealertes par l'API, sous la règle existante
prealertes_lecture (outils/supabase.sql, partie 9). Ce banc le prouve sur la
chaîne officielle complète (outils/migrations.txt), dans une base jetable, avec
un vrai PostgREST et les requêtes EXACTES que construit assets/js/api.js
(CHAMPS_PREALERTE est lu dans api.js, pas recopié) :

  1. l'équipe (employé, gérant, administrateur) lit les pré-alertes, client et
     colis compris ; un client ne lit que les siennes ; un visiteur, rien ;
  2. un numéro annoncé par deux clients rend les deux (l'employé choisira) ;
  3. le colis enregistré par creer_colis pour le bon client fait passer SA
     pré-alerte à « recu » (déclencheur rapprocher_prealerte), et rien d'autre ne
     bouge : statuts et historique des autres colis, pré-alertes des autres clients ;
  4. ces lectures n'écrivent rien, et l'équipe ne peut pas changer le statut d'une
     pré-alerte par l'API.

Jamais la vraie base. Il faut PostgREST 12 (commande `postgrest`, ou son chemin
dans la variable POSTGREST), comme pour essai-mobile.py.

    python3 outils/essais-services/essai-prealertes.py
"""
import base64
import hashlib
import hmac
import importlib.util
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ICI = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location('essai_services', os.path.join(ICI, 'essai-services.py'))
S = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(S)

RACINE, TRAVAIL = S.RACINE, S.TRAVAIL
ADMIN, MARIE, JEAN = S.ADMIN, S.MARIE, S.JEAN
EMPLOYE = 'cccccccc-0000-0000-0000-00000000000c'
GERANT = 'ffffffff-0000-0000-0000-00000000000f'
CARO = 'abababab-0000-0000-0000-0000000000ab'
verifier, jsonq, creer, un = S.verifier, S.jsonq, S.creer, S.un

FICHIERS = tuple(l.strip() for l in open(os.path.join(RACINE, 'outils', 'migrations.txt'), encoding='utf-8')
                 if l.strip() and not l.startswith('#'))
PORT = int(os.environ.get('GOSHIP_PORT_PGRST', '3998'))
SECRET = secrets.token_urlsafe(40)

# La sélection exacte du tableau de bord : lue dans api.js, jamais recopiée à la main
_API = open(os.path.join(RACINE, 'assets', 'js', 'api.js'), encoding='utf-8').read()
_m = re.search(r"var CHAMPS_PREALERTE = ((?:'[^']*'\s*\+?\s*)+);", _API)
if not _m:
    raise SystemExit('CHAMPS_PREALERTE introuvable dans assets/js/api.js')
CHAMPS = ''.join(re.findall(r"'([^']*)'", _m.group(1)))


def b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b'=').decode()


def jeton(sub):
    h = b64(json.dumps({'alg': 'HS256', 'typ': 'JWT'}).encode())
    t = int(time.time())
    p = b64(json.dumps({'role': 'authenticated', 'aud': 'authenticated', 'sub': sub,
                        'iat': t - 3600, 'exp': t + 3600}).encode())
    return h + '.' + p + '.' + b64(hmac.new(SECRET.encode(), (h + '.' + p).encode(), hashlib.sha256).digest())


def http(methode, chemin, qui=None, corps=None, entetes=None):
    """Une requête à PostgREST comme supabase-js la fait : (code, json, en-têtes)."""
    h = {'Accept': 'application/json', 'Content-Type': 'application/json'}
    if qui:
        h['Authorization'] = 'Bearer ' + jeton(qui)
    h.update(entetes or {})
    req = urllib.request.Request('http://127.0.0.1:%d%s' % (PORT, chemin), method=methode, headers=h,
                                 data=json.dumps(corps).encode() if corps is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            brut = r.read().decode()
            return r.status, (json.loads(brut) if brut else None), dict(r.headers)
    except urllib.error.HTTPError as e:
        brut = e.read().decode()
        try:
            return e.code, json.loads(brut), dict(e.headers)
        except ValueError:
            return e.code, brut, dict(e.headers)


def chemin(**filtres):
    """/prealertes?select=CHAMPS&… (filtres PostgREST, encodés comme supabase-js)"""
    return '/prealertes?' + urllib.parse.urlencode([('select', CHAMPS)] + list(filtres.items()))


def du_suivi(qui, numero):
    """API.admin.prealertesDuSuivi : en attente, ce numéro, la plus ancienne d'abord, 20 au plus."""
    return http('GET', chemin(statut='eq.attente', suivi_transporteur='eq.' + numero, order='cree_le.asc',
                              limit='20'), qui)


def installer():
    db = S.Base()
    db.sql(S.DOUBLURES)
    for f in FICHIERS:
        db.fichier(os.path.join(RACINE, 'outils', f))
    for uid, email, nom in ((ADMIN, 'equipe@goship.test', 'Ada Admin'), (EMPLOYE, 'employe@goship.test', 'Emma Employée'),
                            (GERANT, 'gerant@goship.test', 'Gaston Gérant'), (MARIE, 'marie@exemple.com', 'Marie-Ange Dorvil'),
                            (JEAN, 'jean@exemple.com', 'Jean Pierre'), (CARO, 'caro@exemple.com', 'Carolina Méndez')):
        db.sql("""insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
                  values ('%s', '%s', now(), '{"nom_complet":"%s","pays":"HT","ville":"Pétion-Ville",
                          "telephone":"+509 3000 0000"}'::jsonb);""" % (uid, email, nom))
    db.sql("select public.definir_admin('equipe@goship.test');")
    jsonq(db, ADMIN, "select public.changer_role('employe@goship.test', 'employe');")
    jsonq(db, ADMIN, "select public.changer_role('gerant@goship.test', 'gerant');")
    db.sql('grant connect on database %s to authenticator;' % S.BASE)
    return db


def lancer_postgrest(db):
    binaire = os.environ.get('POSTGREST') or shutil.which('postgrest')
    if not binaire or not os.path.exists(binaire):
        raise SystemExit('PostgREST introuvable : installez-le, ou donnez son chemin dans la variable POSTGREST.')
    conf = os.path.join(TRAVAIL, 'postgrest-prealertes.conf')
    open(conf, 'w').write('db-uri = "postgres://authenticator@/%s?host=%s"\ndb-schemas = "public"\n'
                          'db-anon-role = "anon"\njwt-secret = "%s"\nserver-port = %d\nserver-host = "127.0.0.1"\n'
                          % (S.BASE, db.socket, SECRET, PORT))
    proc = subprocess.Popen([binaire, conf], stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    for _ in range(120):
        try:
            urllib.request.urlopen('http://127.0.0.1:%d/' % PORT, timeout=1)
            return proc
        except Exception:
            time.sleep(0.25)
    proc.terminate()
    raise SystemExit('PostgREST ne répond pas.')


def instantane(db, sauf=None):
    """Empreinte des colis et de leur historique, hors le colis qu'on vient de créer ; nombre d'événements."""
    filtre = "where id <> '%s'" % sauf if sauf else ''
    filtre_h = "where colis_id <> '%s'" % sauf if sauf else ''
    return (un(db, "select md5(coalesce(string_agg(c::text, '|' order by c.id), '')) from (select id, statut, lieu, note, "
                   "maj_le, client_id, suivi_transporteur from public.colis %s) c;" % filtre),
            un(db, "select md5(coalesce(string_agg(h::text, '|' order by h.id), '')) from public.colis_historique h %s;"
                   % filtre_h),
            un(db, "select count(*) from public.colis_historique;"))


def main():
    db = installer()
    print('0. La chaîne officielle (%d migrations) s\'installe ; le Palier A n\'en ajoute aucune' % len(FICHIERS))
    verifier('aucun fichier SQL nouveau dans outils/migrations.txt', FICHIERS[-1], 'supabase-suivi-courriels.sql')

    # Les données : des colis existants, puis les pré-alertes que l'application enverrait
    base = {'description': 'Chaussures', 'poids_lb': 4, 'service': 'aerien', 'pays_destination': 'HT',
            'destination': 'Pétion-Ville', 'expediteur': 'Amazon', 'lieu': 'Miami (Medley), FL'}
    ancien = creer(db, ADMIN, dict(base, client_id=MARIE, suivi_transporteur='1Z999AA10123456784'))['colis']
    jsonq(db, ADMIN, "select public.executer_operation('%s', 'COLIS_EMBALLE', null, null, '{}'::jsonb, null, null, null, null);"
          % ancien['id'])
    db.comme(MARIE, "select public.creer_prealerte(null, 'Amazon', 'Écouteurs', 'TBA312345678901', 59.99, 'aerien');")
    db.comme(JEAN, "select public.creer_prealerte(null, 'Walmart', 'Mixeur', '9400 1118 9922 3399 8877 64', 45, 'aerien');")
    db.comme(CARO, "select public.creer_prealerte(null, 'Target', 'Jouets', '9400111899223399887764', 38.5, 'aerien');")
    db.comme(MARIE, "select public.creer_prealerte(null, 'eBay', 'Montre', '', null, 'aerien');")
    proc = lancer_postgrest(db)
    try:
        print('\n1. L\'équipe lit, un client ne lit que les siennes, un visiteur rien')
        for nom, qui in (('employé', EMPLOYE), ('gérant', GERANT), ('administrateur', ADMIN)):
            code, lignes, _ = http('GET', chemin(statut='eq.attente', order='cree_le.desc'), qui)
            verifier('%s : toutes les pré-alertes en attente' % nom, (code, len(lignes)), (200, 4))
        code, lignes, _ = du_suivi(EMPLOYE, 'TBA312345678901')
        p = lignes[0] if lignes else {}
        verifier('la ligne : client imbriqué (code GSE, nom)', (bool(re.match(r'^GSE-\d{4,}$', (p.get('client') or {}).get('code') or '')),
                 (p.get('client') or {}).get('nom_complet')), (True, 'Marie-Ange Dorvil'))
        verifier('la ligne : colis imbriqué vide tant qu\'aucun colis', p.get('colis'), None)
        verifier('ses colonnes : celles que lit la page', sorted(k for k in p if k not in ('client', 'colis')),
                 sorted(['id', 'client_id', 'magasin', 'description', 'suivi_transporteur', 'valeur_usd', 'service',
                         'statut', 'colis_id', 'cree_le']))
        code, lignes, _ = http('GET', chemin(order='cree_le.desc'), MARIE)
        verifier('Marie (cliente) : seulement les siennes', sorted(set(l['client_id'] for l in lignes)), [MARIE])
        code, lignes, _ = du_suivi(MARIE, '9400111899223399887764')
        verifier('Marie : le numéro annoncé par d\'autres ne lui montre rien', (code, lignes), (200, []))
        code, lignes, _ = http('GET', chemin(), None)
        verifier('visiteur sans compte : rien', code in (401, 403) or lignes == [], True)

        print('\n2. Le poste de scan : aucune, une, ou plusieurs pré-alertes pour un numéro')
        code, lignes, _ = du_suivi(EMPLOYE, '9400111899223399887764')
        verifier('même numéro annoncé par deux clients : les deux (espaces retirés à l\'enregistrement)',
                 [l['client']['nom_complet'] for l in lignes], ['Jean Pierre', 'Carolina Méndez'])
        verifier('numéro inconnu : aucune', du_suivi(EMPLOYE, 'TBA999999999999')[1], [])
        code, lignes, entetes = http('GET', chemin(order='cree_le.desc', offset='0', limit='2') + '&or=(' +
                                     urllib.parse.quote('suivi_transporteur.ilike."*99887764*",magasin.ilike."*99887764*",'
                                                        'description.ilike."*99887764*"') + ')',
                                     GERANT, entetes={'Prefer': 'count=exact'})
        verifier('recherche de l\'onglet (ou, ilike, total exact) acceptée par PostgREST',
                 (code, len(lignes), (entetes.get('Content-Range') or '').split('/')[-1]), (200, 2, '2'))
        code, ids, _ = http('GET', '/clients?select=id&or=(code.ilike."*carolina*",nom_complet.ilike."*carolina*")&limit=200'
                            .replace('"', '%22').replace('*', '%2A'), EMPLOYE)
        code2, lignes, _ = http('GET', chemin(order='cree_le.desc') + '&or=(' +
                                urllib.parse.quote('client_id.in.(%s)' % ','.join(i['id'] for i in ids)) + ')', EMPLOYE)
        verifier('recherche par nom du client (deux requêtes, comme api.js)', (code, code2, [l['magasin'] for l in lignes]),
                 (200, 200, ['Target']))
        verifier('le poste de scan : ce numéro n\'est toujours pas un colis',
                 jsonq(db, EMPLOYE, "select public.scanner_colis('9400111899223399887764');"), None)

        print('\n3. Le rapprochement par la base, et rien d\'autre ne bouge')
        avant = instantane(db)
        caro = du_suivi(EMPLOYE, '9400111899223399887764')[1][1]
        r = creer(db, EMPLOYE, dict(base, client_id=CARO, suivi_transporteur=caro['suivi_transporteur'],
                                    expediteur=caro['magasin'], description=caro['description'], poids_lb=3))
        nouveau = r['colis']
        apres = instantane(db, sauf=nouveau['id'])
        verifier('le colis naît « Reçu »', nouveau['statut'], 'recu')
        etat_caro = un(db, "select statut || ' ' || (colis_id = '%s') from public.prealertes where id = '%s';"
                       % (nouveau['id'], caro['id']))
        verifier('la pré-alerte de Carolina : « recu », liée au nouveau colis', etat_caro, 'recu true')
        verifier('celle de Jean (même numéro) : toujours en attente',
                 un(db, "select statut from public.prealertes where client_id = '%s' and magasin = 'Walmart';" % JEAN), 'attente')
        verifier('les autres colis : statut, lieu, note, date inchangés', apres[0], avant[0])
        verifier('l\'historique : un seul événement de plus', int(apres[2]) - int(avant[2]), 1)
        verifier('… la réception du nouveau colis',
                 un(db, "select type_evenement || ' ' || (colis_id = '%s') from public.colis_historique order by id desc limit 1;"
                    % nouveau['id']), 'COLIS_RECU true')
        verifier('… et les anciens événements intacts, un par un', apres[1], avant[1])
        verifier('le même numéro pour Jean : refusé par la règle des colis (TRACKING_ALREADY_EXISTS)',
                 db.erreur(EMPLOYE, "select public.creer_colis('%s'::jsonb, null, true);"
                           % json.dumps(dict(base, client_id=JEAN, suivi_transporteur='9400111899223399887764'))
                           .replace("'", "''")), 'TRACKING_ALREADY_EXISTS')
        code, lignes, _ = du_suivi(EMPLOYE, '9400111899223399887764')
        verifier('le numéro ne propose plus que Jean', [l['client']['nom_complet'] for l in lignes], ['Jean Pierre'])
        code, lignes, _ = http('GET', chemin(statut='eq.recu'), ADMIN)
        verifier('l\'onglet « Reçues » : le numéro du colis imbriqué', [l['colis']['numero'] for l in lignes], [nouveau['numero']])

        print('\n4. Rien ne s\'écrit par ce chemin')
        avant = un(db, "select md5(string_agg(p::text, '|' order by p.id)) from public.prealertes p;")
        code, corps, _ = http('PATCH', '/prealertes?id=eq.%s' % lignes[0]['id'], EMPLOYE, {'statut': 'annulee'})
        verifier('l\'équipe ne peut pas changer le statut d\'une pré-alerte par l\'API', code in (401, 403), True)
        code, corps, _ = http('PATCH', '/prealertes?id=eq.%s' % lignes[0]['id'], EMPLOYE, {'colis_id': ancien['id']})
        verifier('ni la rattacher à un autre colis', code in (401, 403), True)
        verifier('les pré-alertes n\'ont pas bougé',
                 un(db, "select md5(string_agg(p::text, '|' order by p.id)) from public.prealertes p;"), avant)
    finally:
        proc.terminate()

    n = sum(S.RESULTATS)
    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), n))
    sys.exit(0 if n == len(S.RESULTATS) else 1)


if __name__ == '__main__':
    main()
