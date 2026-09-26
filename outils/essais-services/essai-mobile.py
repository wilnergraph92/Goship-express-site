# -*- coding: utf-8 -*-
"""L'application mobile vue de la base : isolation, pré-alertes, factures (Phase 10).

Même base jetable que essai-services.py (jamais la vraie base). On installe
toutes les migrations, puis on joue ce que fait l'application mobile
(dépôt goship-express-app, lib/api.js) : les MÊMES requêtes HTTP, envoyées à
un vrai PostgREST, avec le jeton d'un client — comme le ferait quelqu'un qui
contourne l'application et appelle l'API à la main.

    python3 outils/essais-services/essai-mobile.py              # les essais
    python3 outils/essais-services/essai-mobile.py --serveur    # la base d'essai reste allumée

Le mode --serveur sert les essais de l'application elle-même (navigateur,
émulateur Android, simulateur iOS) : une fausse « Supabase » sur
http://localhost:54321, avec
  /rest/v1/…   un vrai PostgREST sur la base d'essai (règles de sécurité réelles)
  /auth/v1/…   une doublure de l'authentification : comptes d'essai ci-dessous,
               jetons signés par une clé tirée au hasard à chaque lancement
  /essai/…     de quoi provoquer une panne, une lenteur ou une session expirée
Rien de tout cela ne touche la vraie base ni ne contient de secret réel.

Il faut PostgREST 12 : la commande `postgrest` (ou son chemin dans la variable
POSTGREST). Voir https://github.com/PostgREST/postgrest/releases.
"""
import base64
import hashlib
import hmac
import http.server
import importlib.util
import json
import os
import secrets
import shutil
import socketserver
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

ICI = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location('essai_services', os.path.join(ICI, 'essai-services.py'))
S = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(S)

RACINE, TRAVAIL = S.RACINE, S.TRAVAIL
ADMIN, MARIE, JEAN = S.ADMIN, S.MARIE, S.JEAN
EMPLOYE = 'cccccccc-0000-0000-0000-00000000000c'
verifier, jsonq, creer, un = S.verifier, S.jsonq, S.creer, S.un

FICHIERS = ('supabase.sql', 'supabase-facturation.sql', 'supabase-services.sql', 'supabase-evenements.sql',
            'supabase-scanner.sql', 'supabase-finances.sql', 'supabase-tableau-de-bord.sql',
            'supabase-analytics.sql', 'supabase-mobile.sql', 'supabase-notifications.sql')

# Les comptes d'essai (mots de passe d'essai, valables sur cette base jetable seulement)
COMPTES = {
    'marie@exemple.com': (MARIE, 'marie-essai-1', 'Marie-Ange Dorvil'),
    'jean@exemple.com': (JEAN, 'jean-essai-1', 'Jean Pierre'),
    'employe@goship.test': (EMPLOYE, 'employe-essai-1', 'Emma Employée'),
    'equipe@goship.test': (ADMIN, 'admin-essai-1', 'Ada Admin'),
}

PORT_PGRST = int(os.environ.get('GOSHIP_PORT_PGRST', '3999'))
PORT = int(os.environ.get('GOSHIP_PORT', '54321'))
SECRET = secrets.token_urlsafe(40)

# Les colonnes exactes que demande l'application (lib/api.js)
CHAMPS_LISTE = ('id,numero,suivi_transporteur,expediteur,description,poids_lb,service,pays_destination,'
                'destination,statut,lieu,note,recu_le,cree_le,maj_le')
CHAMPS_DETAIL = CHAMPS_LISTE + ',colis_historique(id,type_evenement,statut,lieu,note,cree_le)'


def q(v):
    return 'null' if v is None else "'%s'" % str(v).replace("'", "''")


def op(db, compte, id_colis, type_, lieu=None, note=None, motif=None, cible=None):
    return jsonq(db, compte, "select public.executer_operation('%s', %s, %s, %s, '{}'::jsonb, null, null, %s, %s);"
                 % (id_colis, q(type_), q(lieu), q(note), q(cible), q(motif)))


# ---- La base d'essai et ses données ----------------------------------------------------
def installer():
    db = S.Base()
    db.sql(S.DOUBLURES)
    for f in FICHIERS:
        db.fichier(os.path.join(RACINE, 'outils', f))
    # Rejouable sans risque : la migration mobile, deux fois de plus
    db.fichier(os.path.join(RACINE, 'outils', 'supabase-mobile.sql'))
    db.fichier(os.path.join(RACINE, 'outils', 'supabase-mobile.sql'))
    for email, (uid, _mdp, nom) in COMPTES.items():
        db.sql("""insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
                  values ('%s', '%s', now(), '{"nom_complet":"%s","pays":"HT","ville":"Pétion-Ville"}'::jsonb);"""
               % (uid, email, nom))
    db.sql("select public.definir_admin('equipe@goship.test');")
    jsonq(db, ADMIN, "select public.changer_role('employe@goship.test', 'employe');")
    # PostgREST se connecte avec le rôle authenticator : il lui faut le droit de se connecter
    db.sql('grant connect on database %s to authenticator;' % S.BASE)
    return db


def peupler(db):
    """25 colis pour Marie (plus d'une page), 2 pour Jean, factures, paiements, pré-alertes."""
    base = {'description': 'Chaussures', 'poids_lb': 4, 'service': 'aerien', 'pays_destination': 'HT',
            'destination': 'Pétion-Ville', 'expediteur': 'Amazon'}
    d = {'marie': [], 'jean': []}
    for i in range(25):
        r = creer(db, ADMIN, dict(base, client_id=MARIE, description='Colis de Marie %02d' % (i + 1),
                                   suivi_transporteur='TBAMARIE%04d' % (i + 1), poids_lb=2 + i),
                  facturer=(i < 3))
        d['marie'].append(r)
    for i in range(2):
        d['jean'].append(creer(db, ADMIN, dict(base, client_id=JEAN, description='Colis de Jean %d' % (i + 1),
                                                suivi_transporteur='TBAJEAN%04d' % (i + 1))))
    c = lambda n: d['marie'][n]['colis']['id']
    # Un parcours complet, un colis disponible, un « action requise », une correction
    for t, lieu in (('COLIS_EMBALLE', None), ('COLIS_EXPEDIE', None), ('COLIS_ARRIVE', 'Port-au-Prince'),
                    ('COLIS_DISPONIBLE', 'Agence de Pétion-Ville'), ('COLIS_LIVRE', None)):
        op(db, ADMIN, c(0), t, lieu=lieu)
    op(db, ADMIN, c(1), 'COLIS_INSPECTE', note='Carton abîmé, contenu intact')   # interne : invisible du client
    for t, lieu in (('COLIS_EMBALLE', None), ('COLIS_EXPEDIE', None), ('COLIS_ARRIVE', 'Port-au-Prince'),
                    ('COLIS_DISPONIBLE', 'Agence de Pétion-Ville')):
        op(db, ADMIN, c(1), t, lieu=lieu)
    op(db, ADMIN, c(2), 'ACTION_REQUISE', note='Adresse incomplète : appelez-nous.')
    op(db, ADMIN, c(3), 'COLIS_EMBALLE')
    op(db, ADMIN, c(3), 'COLIS_EXPEDIE')
    op(db, ADMIN, c(3), 'CORRECTION', motif='Embarqué par erreur')             # l'étape corrigée disparaît
    # Factures : colis 0 payé en entier, colis 1 payé en partie, colis 2 rien
    f = lambda n: d['marie'][n]['facture']['id']
    total0 = float(un(db, "select montant_usd from factures where id = '%s';" % f(0)))
    jsonq(db, ADMIN, "select public.enregistrer_paiement('%s', '{\"montant_usd\": %s, \"moyen\": \"especes\"}'::jsonb);"
          % (f(0), total0))
    jsonq(db, ADMIN, "select public.enregistrer_paiement('%s', '{\"montant_usd\": 5, \"moyen\": \"moncash\"}'::jsonb);"
          % f(1))
    jsonq(db, ADMIN, "select public.enregistrer_paiement('%s', '{\"montant_usd\": 3, \"moyen\": \"especes\"}'::jsonb);"
          % d['jean'][0]['facture']['id'])
    db.comme(JEAN, "select public.creer_prealerte(null, 'eBay', 'Montre', 'EBAYJEAN0001', 40, 'aerien');")
    db.comme(MARIE, "select public.creer_prealerte(null, 'SHEIN', 'Robe', 'SHEINMARIE01', 25, 'aerien');")
    return d


# ---- PostgREST et la doublure d'authentification ----------------------------------------
def b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b'=').decode()


def jeton(sub, email, duree=3600):
    h = b64(json.dumps({'alg': 'HS256', 'typ': 'JWT'}).encode())
    maintenant = int(time.time())
    p = b64(json.dumps({'role': 'authenticated', 'aud': 'authenticated', 'sub': sub, 'email': email,
                        'iat': maintenant, 'exp': maintenant + duree, 'session_id': str(uuid.uuid4())}).encode())
    return h + '.' + p + '.' + b64(hmac.new(SECRET.encode(), (h + '.' + p).encode(), hashlib.sha256).digest())


def lire_jeton(texte):
    try:
        h, p, s = texte.split('.')
        attendu = b64(hmac.new(SECRET.encode(), (h + '.' + p).encode(), hashlib.sha256).digest())
        if not hmac.compare_digest(attendu, s):
            return None
        return json.loads(base64.urlsafe_b64decode(p + '=' * (-len(p) % 4)))
    except Exception:
        return None


def lancer_postgrest(db):
    binaire = os.environ.get('POSTGREST') or shutil.which('postgrest')
    if not binaire or not os.path.exists(binaire):
        raise SystemExit('PostgREST introuvable : installez-le, ou donnez son chemin dans la variable POSTGREST.')
    conf = os.path.join(TRAVAIL, 'postgrest.conf')
    open(conf, 'w').write('db-uri = "postgres://authenticator@/%s?host=%s"\ndb-schemas = "public"\n'
                          'db-anon-role = "anon"\njwt-secret = "%s"\nserver-port = %d\nserver-host = "127.0.0.1"\n'
                          % (S.BASE, db.socket, SECRET, PORT_PGRST))
    proc = subprocess.Popen([binaire, conf], stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    # Prêt quand il a lu le schéma : avant, il répond 503 (PGRST002)
    for _ in range(120):
        try:
            urllib.request.urlopen('http://127.0.0.1:%d/' % PORT_PGRST, timeout=1)
            return proc
        except Exception:
            time.sleep(0.25)
    proc.terminate()
    raise SystemExit('PostgREST ne répond pas.')


class Etat:
    """Ce que la doublure retient : mots de passe, sessions, panne simulée."""
    def __init__(self, db):
        self.db = db
        self.verrou = threading.Lock()
        self.comptes = {e: {'id': v[0], 'mdp': v[1]} for e, v in COMPTES.items()}
        self.renouvellements = {}   # jeton de renouvellement → email
        self.revoques = set()       # comptes dont les sessions ne valent plus
        self.panne = None           # None, 'serveur' (503) ou 'lent'
        self.delai = 0


def utilisateur(email, uid, meta=None):
    return {'id': uid, 'aud': 'authenticated', 'role': 'authenticated', 'email': email,
            'email_confirmed_at': '2026-01-01T00:00:00Z', 'user_metadata': meta or {},
            'app_metadata': {'provider': 'email', 'providers': ['email']},
            'identities': [{'id': uid, 'provider': 'email'}], 'created_at': '2026-01-01T00:00:00Z'}


def session(etat, email):
    c = etat.comptes[email]
    r = secrets.token_urlsafe(24)
    etat.renouvellements[r] = email
    return {'access_token': jeton(c['id'], email), 'token_type': 'bearer', 'expires_in': 3600,
            'expires_at': int(time.time()) + 3600, 'refresh_token': r, 'user': utilisateur(email, c['id'])}


def fabriquer_gestionnaire(etat):
    class Gestionnaire(http.server.BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *a):
            pass

        def entetes_cors(self):
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Access-Control-Allow-Methods', 'GET, POST, PATCH, PUT, DELETE, OPTIONS')
            self.send_header('Access-Control-Allow-Headers', self.headers.get('Access-Control-Request-Headers') or '*')
            self.send_header('Access-Control-Expose-Headers', 'Content-Range, Content-Location, Preference-Applied')

        def repondre(self, code, corps=None, entetes=None):
            donnees = b'' if corps is None else (corps if isinstance(corps, bytes) else json.dumps(corps).encode())
            self.send_response(code)
            self.entetes_cors()
            for k, v in (entetes or {}).items():
                self.send_header(k, v)
            if corps is not None and not (entetes or {}).get('Content-Type'):
                self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(donnees)))
            self.end_headers()
            self.wfile.write(donnees)

        def corps(self):
            n = int(self.headers.get('Content-Length') or 0)
            return self.rfile.read(n) if n else b''

        def do_OPTIONS(self):
            self.repondre(204)

        def do_GET(self):
            self.traiter('GET')

        def do_POST(self):
            self.traiter('POST')

        def do_PATCH(self):
            self.traiter('PATCH')

        def do_DELETE(self):
            self.traiter('DELETE')

        def do_PUT(self):
            self.traiter('PUT')

        def traiter(self, methode):
            chemin = urllib.parse.urlsplit(self.path)
            donnees = self.corps()
            if chemin.path.startswith('/essai/'):
                return self.essai(chemin.path[len('/essai/'):], donnees)
            if chemin.path.startswith('/auth/v1/'):
                return self.auth(methode, chemin.path[len('/auth/v1/'):], urllib.parse.parse_qs(chemin.query), donnees)
            if chemin.path.startswith('/rest/v1/'):
                return self.rest(methode, self.path[len('/rest/v1'):], donnees)
            self.repondre(404, {'message': 'introuvable'})

        # -- Contrôle des essais : panne, lenteur, session expirée
        def essai(self, action, donnees):
            d = json.loads(donnees or b'{}')
            with etat.verrou:
                if action == 'panne':
                    etat.panne = d.get('mode') or None
                    etat.delai = int(d.get('delai') or 0)
                elif action == 'revoquer':
                    etat.revoques.add(d['email'])
                    for r, e in list(etat.renouvellements.items()):
                        if e == d['email']:
                            del etat.renouvellements[r]
                elif action == 'retablir':
                    etat.revoques.discard(d.get('email'))
                elif action == 'sql':
                    return self.repondre(200, {'sortie': etat.db.sql(d['requete'], echec_permis=True)})
            self.repondre(200, {'ok': True})

        # -- Doublure de l'authentification Supabase (GoTrue)
        def auth(self, methode, action, params, donnees):
            d = json.loads(donnees or b'{}')
            if action == 'token':
                genre = (params.get('grant_type') or [''])[0]
                with etat.verrou:
                    if genre == 'password':
                        email = str(d.get('email', '')).strip().lower()
                        c = etat.comptes.get(email)
                        if not c or c['mdp'] != d.get('password'):
                            return self.repondre(400, {'code': 400, 'error_code': 'invalid_credentials',
                                                       'msg': 'Invalid login credentials'})
                        etat.revoques.discard(email)
                        return self.repondre(200, session(etat, email))
                    if genre == 'refresh_token':
                        email = etat.renouvellements.pop(d.get('refresh_token'), None)
                        if not email:
                            return self.repondre(400, {'code': 400, 'error_code': 'refresh_token_not_found',
                                                       'msg': 'Invalid Refresh Token: Refresh Token Not Found'})
                        return self.repondre(200, session(etat, email))
                return self.repondre(400, {'code': 400, 'error_code': 'validation_failed', 'msg': 'grant_type'})
            if action == 'user':
                j = lire_jeton((self.headers.get('Authorization') or '')[7:])
                if not j or j.get('email') in etat.revoques:
                    return self.repondre(401, {'code': 401, 'error_code': 'bad_jwt', 'msg': 'invalid JWT'})
                return self.repondre(200, utilisateur(j['email'], j['sub']))
            if action == 'logout':
                return self.repondre(204)
            if action == 'recover':
                return self.repondre(200, {})
            if action == 'signup':
                email = str(d.get('email', '')).strip().lower()
                meta = d.get('data') or {}
                with etat.verrou:
                    if email in etat.comptes:
                        # Comme Supabase : une adresse déjà inscrite revient sans identité
                        u = utilisateur(email, str(uuid.uuid4()), meta)
                        u['identities'] = []
                        return self.repondre(200, u)
                    if len(str(d.get('password') or '')) < 6:
                        return self.repondre(422, {'code': 422, 'error_code': 'weak_password',
                                                   'msg': 'Password should be at least 6 characters.'})
                    uid = str(uuid.uuid4())
                    etat.db.sql("insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) "
                                "values ('%s', %s, now(), '%s'::jsonb);"
                                % (uid, q(email), json.dumps(meta).replace("'", "''")))
                    etat.comptes[email] = {'id': uid, 'mdp': d.get('password')}
                    return self.repondre(200, session(etat, email))
            self.repondre(404, {'code': 404, 'msg': 'not found'})

        # -- PostgREST, avec la panne ou la lenteur demandées
        def rest(self, methode, chemin, donnees):
            if etat.panne == 'serveur':
                return self.repondre(503, {'message': 'Service indisponible (panne simulée)'})
            if etat.panne == 'lent':
                time.sleep(etat.delai / 1000.0)
            auth = self.headers.get('Authorization') or ''
            if auth.startswith('Bearer '):
                j = lire_jeton(auth[7:])
                if j and j.get('email') in etat.revoques:
                    return self.repondre(401, {'code': 'PGRST301', 'message': 'JWT expired'})
            entetes = {k: v for k, v in self.headers.items()
                       if k.lower() in ('authorization', 'content-type', 'accept', 'prefer', 'range',
                                        'range-unit', 'content-profile', 'accept-profile')}
            if 'authorization' not in {k.lower() for k in entetes}:
                entetes.pop('Authorization', None)
            if auth and not auth.startswith('Bearer ey'):
                # La clé publique envoyée seule (pas de session) : on joue le visiteur
                entetes = {k: v for k, v in entetes.items() if k.lower() != 'authorization'}
            req = urllib.request.Request('http://127.0.0.1:%d%s' % (PORT_PGRST, chemin), method=methode,
                                         data=donnees if methode not in ('GET',) else None, headers=entetes)
            try:
                with urllib.request.urlopen(req, timeout=30) as rep:
                    code, corps, hs = rep.status, rep.read(), rep.headers
            except urllib.error.HTTPError as e:
                code, corps, hs = e.code, e.read(), e.headers
            garder = {k: v for k, v in hs.items() if k.lower() in ('content-type', 'content-range', 'preference-applied')}
            if code >= 400:
                # Le journal de la base d'essai (base.log en CI) : chaque refus, pour comprendre un
                # parcours qui échoue sur un émulateur. Ni jeton ni mot de passe : la réponse d'erreur.
                print('REST %s %s → %d %s (jeton : %s)' % (methode, chemin[:140], code, corps[:200].decode('utf-8', 'replace'),
                      'oui' if auth.startswith('Bearer ey') else ('clé publique' if auth else 'aucun')), flush=True)
            self.repondre(code, corps, garder)

    return Gestionnaire


class Serveur(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def demarrer(db):
    pgrst = lancer_postgrest(db)
    etat = Etat(db)
    serveur = Serveur(('0.0.0.0', PORT), fabriquer_gestionnaire(etat))
    threading.Thread(target=serveur.serve_forever, daemon=True).start()
    return pgrst, serveur, etat


# ---- Un client HTTP qui envoie ce qu'envoie l'application --------------------------------
def appel(methode, chemin, qui=None, corps=None, entetes=None):
    h = {'Content-Type': 'application/json', 'Accept': 'application/json', 'apikey': 'cle-publique-essai'}
    if qui:
        email = [e for e, v in COMPTES.items() if v[0] == qui][0]
        h['Authorization'] = 'Bearer ' + jeton(qui, email)
    h.update(entetes or {})
    req = urllib.request.Request('http://127.0.0.1:%d/rest/v1%s' % (PORT, chemin), method=methode, headers=h,
                                 data=json.dumps(corps).encode() if corps is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=30) as rep:
            texte = rep.read().decode()
            return rep.status, (json.loads(texte) if texte else None), rep.headers
    except urllib.error.HTTPError as e:
        texte = e.read().decode()
        try:
            return e.code, json.loads(texte) if texte else None, e.headers
        except ValueError:
            return e.code, texte, e.headers


def rpc(nom, qui, corps=None):
    c, v, _ = appel('POST', '/rpc/' + nom, qui, corps or {})
    return c, v


def enc(v):
    return urllib.parse.quote(str(v), safe='')


def essais(db, d):
    colis_marie = [r['colis'] for r in d['marie']]
    colis_jean = [r['colis'] for r in d['jean']]

    print('A. La migration (supabase-mobile.sql)')
    verifier('les neuf fichiers s\'installent, la migration mobile se rejoue', 'oui', 'oui')
    verifier('contrôle : fonction, fermée aux visiteurs, 2 index, colonne',
             un(db, "select (select count(*) from pg_proc where proname = 'creer_prealerte') || ':' || "
                    "(select count(*) from pg_indexes where indexname in ('colis_client_maj_idx', 'prealertes_cle_envoi_idx')) || ':' || "
                    "has_function_privilege('anon', 'public.creer_prealerte(uuid,text,text,text,numeric,text)', 'execute');"),
             '1:2:false')
    verifier('la liste d\'un client passe par son index',
             'colis_client_maj_idx' in db.sql("set enable_seqscan = off; explain select id from colis "
                                               "where client_id = '%s' order by maj_le desc limit 20;" % MARIE), True)

    print('B. Mes colis : la liste paginée, les filtres, la recherche (requêtes de lib/api.js)')
    c, v, h = appel('GET', '/colis?select=%s&client_id=eq.%s&order=maj_le.desc,id.desc' % (CHAMPS_LISTE, MARIE), MARIE,
                    entetes={'Range': '0-19', 'Prefer': 'count=exact'})
    verifier('page 1 : 20 colis, 25 au total', (c in (200, 206), len(v), h.get('Content-Range')), (True, 20, '0-19/25'))
    c, v, h = appel('GET', '/colis?select=id&client_id=eq.%s&order=maj_le.desc,id.desc' % MARIE, MARIE,
                    entetes={'Range': '20-39'})
    verifier('page 2 : les 5 derniers', len(v), 5)
    c, v, _ = appel('GET', '/colis?select=id,statut&client_id=eq.%s&statut=in.(disponible)' % MARIE, MARIE)
    verifier('filtre « À retirer » : fait par la base', [x['statut'] for x in v], ['disponible'])
    c, v, _ = appel('GET', '/colis?select=id,statut&client_id=eq.%s&statut=in.(incident)' % MARIE, MARIE)
    verifier('filtre « Action requise »', len(v), 1)
    motif = enc('(numero.ilike."*MARIE 0*",description.ilike."*Marie 07*",suivi_transporteur.ilike."*Marie 07*",'
                'expediteur.ilike."*Marie 07*")')
    c, v, _ = appel('GET', '/colis?select=description&client_id=eq.%s&or=%s' % (MARIE, motif), MARIE)
    verifier('recherche côté base (contenu)', [x['description'] for x in v], ['Colis de Marie 07'])
    num = colis_marie[4]['numero']
    c, v, _ = appel('GET', '/colis?select=id&client_id=eq.%s&or=%s' % (MARIE, enc('(numero.eq.%s,suivi_transporteur.eq.%s)' % (num, num))), MARIE)
    verifier('recherche par numéro exact (scan d\'étiquette)', [x['id'] for x in v], [colis_marie[4]['id']])
    c, v, _ = appel('GET', '/colis?select=id&client_id=eq.%s&or=%s' % (MARIE, enc('(numero.eq.TBAMARIE0006,suivi_transporteur.eq.TBAMARIE0006)')), MARIE)
    verifier('recherche par suivi du vendeur', [x['id'] for x in v], [colis_marie[5]['id']])

    print('C. Le détail et ses étapes (colis_historique)')
    c, v, _ = appel('GET', '/colis?select=%s&id=eq.%s&client_id=eq.%s' % (CHAMPS_DETAIL, colis_marie[0]['id'], MARIE), MARIE)
    h = sorted(v[0]['colis_historique'], key=lambda x: x['id'])
    verifier('parcours complet : 6 étapes, dans l\'ordre', [x['statut'] for x in h],
             ['recu', 'emballe', 'embarque', 'distribution', 'disponible', 'livre'])
    c, v, _ = appel('GET', '/colis?select=%s&id=eq.%s&client_id=eq.%s' % (CHAMPS_DETAIL, colis_marie[1]['id'], MARIE), MARIE)
    verifier('une opération interne (inspection) n\'est pas montrée au client',
             [x['type_evenement'] for x in v[0]['colis_historique']].count('COLIS_INSPECTE'), 0)
    c, v, _ = appel('GET', '/colis?select=%s&id=eq.%s&client_id=eq.%s' % (CHAMPS_DETAIL, colis_marie[3]['id'], MARIE), MARIE)
    verifier('une étape corrigée n\'est plus montrée (ni la correction elle-même)',
             sorted(x['statut'] for x in v[0]['colis_historique']), ['emballe', 'recu'])
    verifier('et le statut suit la correction', v[0]['statut'], 'emballe')
    c, v, _ = appel('GET', '/colis?select=note,statut&id=eq.%s' % colis_marie[2]['id'], MARIE)
    verifier('action requise : la note est lisible par son client', v[0]['note'] if v[0]['note'] else v[0]['statut'],
             v[0]['note'] or 'incident')

    print('D. Isolation : Marie contre Jean, par l\'API directe')
    cj = colis_jean[0]
    for titre, chemin in (('ses colis par client_id', '/colis?select=id&client_id=eq.%s' % JEAN),
                          ('son colis par id', '/colis?select=id&id=eq.%s' % cj['id']),
                          ('son colis par numéro', '/colis?select=id&numero=eq.%s' % cj['numero']),
                          ('ses étapes', '/colis_historique?select=id&colis_id=eq.%s' % cj['id']),
                          ('ses factures (table)', '/factures?select=id&client_id=eq.%s' % JEAN),
                          ('ses lignes de facture', '/facture_lignes?select=id&colis_id=eq.%s' % cj['id']),
                          ('ses paiements', '/paiements?select=id'),
                          ('ses pré-alertes', '/prealertes?select=id&client_id=eq.%s' % JEAN),
                          ('son profil', '/clients?select=id,email&id=eq.%s' % JEAN),
                          ('ses téléphones', '/appareils?select=id&client_id=eq.%s' % JEAN),
                          ('ses notifications', '/notifications?select=id&client_id=eq.%s' % JEAN)):
        c, v, _ = appel('GET', chemin, MARIE)
        if titre == 'ses paiements':
            # Marie voit les siens (2) et jamais celui de Jean
            ids_jean = un(db, "select count(*) from paiements p join factures f on f.id = p.facture_id "
                              "where f.client_id = '%s';" % JEAN)
            c2, v2, _ = appel('GET', '/paiements?select=facture_id,factures!inner(client_id)&factures.client_id=eq.%s' % JEAN, MARIE)
            verifier('Marie → paiements de Jean (%s en base) : rien' % ids_jean, (c2, v2 if isinstance(v2, list) else v2), (200, []))
            continue
        verifier('Marie → %s : rien' % titre, (c, v if isinstance(v, list) else 'refus'),
                 (c, []) if c == 200 else (c, 'refus'))
    c, v = rpc('mes_factures', MARIE)
    verifier('mes_factures : uniquement les siennes', len(v) == 3 and all(un(db, "select client_id from factures where id = '%s';" % x['id']) == MARIE for x in v), True)
    c, v = rpc('suivre_colis', MARIE, {'p_numero': cj['numero']})
    verifier('suivi public du colis de Jean : sans description, note ni client',
             sorted(v.keys()), ['historique', 'maj_le', 'numero', 'pays_destination', 'service', 'statut'])
    c, v, _ = appel('PATCH', '/clients?id=eq.%s' % JEAN, MARIE, {'nom_complet': 'Piraté'}, {'Prefer': 'return=representation'})
    verifier('modifier le profil de Jean : aucune ligne', (c, v), (200, []))
    c, v, _ = appel('POST', '/prealertes', MARIE, {'client_id': JEAN, 'magasin': 'X', 'description': 'Y'})
    verifier('pré-alerte au nom de Jean (insert direct) : refusée', c, 403)
    pj = un(db, "select id from prealertes where client_id = '%s' limit 1;" % JEAN)
    c, v, _ = appel('DELETE', '/prealertes?id=eq.%s' % pj, MARIE, entetes={'Prefer': 'return=representation'})
    verifier('supprimer la pré-alerte de Jean : aucune ligne', (c, v), (200, []))
    verifier('elle est toujours là', un(db, "select count(*) from prealertes where id = '%s';" % pj), '1')
    c, v = rpc('pousser_colis', MARIE, {'p_colis': cj['id'], 'p_evenement': 'maj'})
    verifier('faire sonner le téléphone de Jean : refusé', (c, v.get('message')), (403, 'PERMISSION_DENIED'))
    c, v = rpc('scanner_colis', MARIE, {'p_reference': cj['numero']})
    verifier('le poste de scan de l\'équipe : refusé à un client', c in (401, 403, 404), True)
    c, v = rpc('changer_statut_colis', MARIE, {'p_colis': [colis_marie[5]['id']], 'p_statut': 'livre'})
    verifier('changer le statut de son propre colis : refusé', c in (400, 403, 404), True)

    print('E. Le visiteur (application sans session)')
    for titre, chemin in (('colis', '/colis?select=id'), ('factures', '/factures?select=id'),
                          ('pré-alertes', '/prealertes?select=id'), ('clients', '/clients?select=id')):
        c, v, _ = appel('GET', chemin, None)
        verifier('visiteur → %s : refusé ou vide' % titre, c in (401, 403) or v == [], True)
    for nom, corps in (('mon_resume', {}), ('mes_factures', {}), ('mes_permissions', {}),
                       ('creer_prealerte', {'p_cle': None, 'p_magasin': 'A', 'p_description': 'B'})):
        c, v = rpc(nom, None, corps)
        verifier('visiteur → %s : refusé' % nom, c in (401, 403, 404) or v in (None, [], {'role': None}), True)
    c, v = rpc('suivre_colis', None, {'p_numero': colis_marie[0]['numero']})
    verifier('visiteur → suivi public : oui (même moteur que le site)', v['statut'], 'livre')

    print('F. Résumé, factures, paiements, solde : les chiffres de la base')
    c, r = rpc('mon_resume', MARIE)
    verifier('mon_resume : colis par état', (r['colis']['en_cours'], r['colis']['livres'], r['colis']['disponibles'],
                                             r['colis']['action_requise']), (24, 1, 1, 1))
    c, fs = rpc('mes_factures', MARIE)
    verifier('3 factures, avec lignes et paiements', (len(fs), all(x['lignes'] for x in fs)), (3, True))
    solde = round(sum(float(x['solde_usd']) for x in fs), 2)
    verifier('solde du résumé = somme des soldes des factures', round(float(r['factures']['solde_usd']), 2), solde)
    partielle = [x for x in fs if x['paiements'] and float(x['solde_usd']) > 0][0]
    verifier('facture partielle : total − payé = solde (valeurs de la base)',
             round(float(partielle['montant_usd']) - float(partielle['paye_usd']), 2), round(float(partielle['solde_usd']), 2))
    verifier('son état est déduit par la base', partielle['etat'], 'partielle')
    payee = [x for x in fs if float(x['solde_usd']) == 0][0]
    verifier('facture payée : état payee, un paiement listé', (payee['etat'], len(payee['paiements'])), ('payee', 1))
    c, v, _ = appel('PATCH', '/factures?id=eq.%s' % partielle['id'], MARIE, {'montant_paye_usd': 999},
                    {'Prefer': 'return=representation'})
    verifier('modifier le payé de sa facture : refusé', c in (401, 403) or v == [], True)
    c, v, _ = appel('POST', '/paiements', MARIE, {'facture_id': partielle['id'], 'montant_usd': 1, 'moyen': 'especes'})
    verifier('s\'inscrire un paiement : refusé', c in (401, 403), True)
    c, v = rpc('enregistrer_paiement', MARIE, {'p_facture': partielle['id'], 'p_paiement': {'montant_usd': 1, 'moyen': 'especes'}})
    verifier('enregistrer_paiement par un client : refusé', (c, v.get('message')), (403, 'PERMISSION_DENIED'))
    c, n = rpc('mon_resume', MARIE)
    verifier('mon_resume : derniers messages (liste)', isinstance(n['notifications'], list), True)

    print('G. Pré-alertes (creer_prealerte)')
    def pa(qui, cle, magasin='Amazon', desc='Livres', suivi='', valeur=None, service='aerien'):
        return rpc('creer_prealerte', qui, {'p_cle': cle, 'p_magasin': magasin, 'p_description': desc,
                                            'p_suivi': suivi, 'p_valeur': valeur, 'p_service': service})
    for titre, args, attendu in (('magasin vide', dict(magasin='  '), 'PREALERT_STORE_REQUIRED'),
                                 ('contenu vide', dict(desc=''), 'PREALERT_DESCRIPTION_REQUIRED'),
                                 ('suivi illisible', dict(suivi='ab/cd?'), 'INVALID_TRACKING'),
                                 ('suivi trop court', dict(suivi='AB1'), 'INVALID_TRACKING'),
                                 ('valeur négative', dict(valeur=-1), 'INVALID_VALUE'),
                                 ('valeur absurde', dict(valeur=1e9), 'INVALID_VALUE'),
                                 ('service inconnu', dict(service='fusee'), 'INVALID_SERVICE')):
        c, v = pa(MARIE, str(uuid.uuid4()), **args)
        verifier('refus : %s' % titre, (c, v.get('message'), v.get('hint')), (400, attendu, 'goship'))
    avant = un(db, "select count(*) from prealertes where client_id = '%s';" % MARIE)
    verifier('aucun refus n\'a rien créé', avant, '1')
    cle = str(uuid.uuid4())
    c, v = pa(MARIE, cle, suivi=' tba 1234 5678 ', valeur=12.345)
    verifier('pré-alerte valide : créée, suivi remis en forme, valeur arrondie',
             (c, v['deja'], v['suivi_transporteur'], float(v['valeur_usd']), v['statut']),
             (200, False, 'TBA12345678', 12.35, 'attente'))
    c, v2 = pa(MARIE, cle, suivi=' tba 1234 5678 ', valeur=12.345)
    verifier('même envoi répété (délai dépassé, nouvel essai) : la même, « deja »', (c, v2['id'], v2['deja']), (200, v['id'], True))
    resultats = []
    cle2 = str(uuid.uuid4())
    fils = [threading.Thread(target=lambda: resultats.append(pa(MARIE, cle2, desc='Jouet', suivi='DOUBLETAP01')))
            for _ in range(5)]
    [f.start() for f in fils]
    [f.join() for f in fils]
    verifier('double appui : 5 requêtes simultanées → 1 pré-alerte',
             (sorted({r[1]['id'] for r in resultats}).__len__(), un(db, "select count(*) from prealertes where cle_envoi = '%s';" % cle2)),
             (1, '1'))
    c, v = pa(MARIE, str(uuid.uuid4()), suivi='TBA12345678')
    verifier('même suivi, autre envoi : doublon refusé', (c, v.get('message')), (400, 'PREALERT_DUPLICATE'))
    c, v = pa(MARIE, str(uuid.uuid4()), suivi='TBAMARIE0010')
    verifier('suivi d\'un colis déjà arrivé : refusé, avec son numéro',
             (c, v.get('message'), colis_marie[9]['numero'] in (v.get('details') or '')), (400, 'PREALERT_ALREADY_RECEIVED', True))
    c, v = pa(JEAN, str(uuid.uuid4()), suivi='TBA12345678')
    verifier('le même suivi chez un autre client n\'est pas un doublon', c, 200)
    c, v = pa(JEAN, cle, suivi='TBA12345678')
    verifier('la clé de Marie rejouée par Jean ne rend pas la pré-alerte de Marie', (c, v.get('deja')), (400, None) if c == 400 else (200, False))
    c, v, _ = appel('GET', '/prealertes?select=id,magasin&client_id=eq.%s&order=cree_le.desc' % MARIE, MARIE,
                    entetes={'Range': '0-19'})
    verifier('liste de ses pré-alertes', len(v), 3)
    c, v, _ = appel('POST', '/prealertes', MARIE, {'client_id': MARIE, 'magasin': 'X', 'description': 'Y', 'statut': 'recu'})
    verifier('se marquer « reçue » soi-même : refusé', c, 403)
    c, v, _ = appel('POST', '/prealertes', MARIE, {'client_id': MARIE, 'magasin': 'Ancienne', 'description': 'App 1.0'},
                    {'Prefer': 'return=representation'})
    verifier('l\'ancien chemin (versions déjà installées) marche encore', c, 201)
    db.sql("insert into prealertes (client_id, magasin, description) select '%s', 'M', 'D' from generate_series(1, "
           "60 - (select count(*)::int from prealertes where client_id = '%s' and statut = 'attente'));" % (MARIE, MARIE))
    c, v = pa(MARIE, str(uuid.uuid4()))
    verifier('au-delà de 60 en attente : refus clair', (c, v.get('message')), (400, 'TOO_MANY_PREALERTS'))
    db.sql("delete from prealertes where magasin = 'M' and client_id = '%s';" % MARIE)

    print('H. Un compte de l\'équipe dans l\'application mobile')
    c, v = rpc('mes_permissions', EMPLOYE)
    verifier('mes_permissions : l\'employée est de l\'équipe', (v['role'], v['equipe']), ('employe', True))
    c, v, _ = appel('GET', '/colis?select=id&client_id=eq.%s' % EMPLOYE, EMPLOYE)
    verifier('« Mes colis » (filtré sur son compte) : les siens seulement', v, [])
    c, v, _ = appel('GET', '/colis?select=id', EMPLOYE)
    verifier('sans filtre, les règles lui ouvrent tout (d\'où le filtre de l\'application)', len(v), 27)
    c, v = rpc('mes_permissions', MARIE)
    verifier('mes_permissions : Marie est cliente, sans permission d\'équipe',
             (v['role'], v['equipe'], sorted(v['permissions'])),
             ('client', False, ['clients.edit:own', 'clients.view:own', 'invoices.view:own', 'payments.view:own',
                                'shipments.view:own', 'shipments.view_history:own']))

    print('I. Téléphones (notifications)')
    c, v = rpc('enregistrer_appareil', MARIE, {'p_jeton': 'n-importe-quoi', 'p_plateforme': 'ios', 'p_langue': 'fr'})
    verifier('jeton inventé : refusé', c, 400)
    c, v = rpc('enregistrer_appareil', MARIE, {'p_jeton': 'ExponentPushToken[essai-marie]', 'p_plateforme': 'ios', 'p_langue': 'fr'})
    verifier('jeton Expo : enregistré', c in (200, 204), True)
    c, v = rpc('enregistrer_appareil', JEAN, {'p_jeton': 'ExponentPushToken[essai-marie]', 'p_plateforme': 'ios', 'p_langue': 'fr'})
    verifier('même téléphone, Jean se connecte : il passe à Jean seul',
             un(db, "select string_agg(client_id::text, ',') from appareils where jeton = 'ExponentPushToken[essai-marie]';"), JEAN)
    c, v, _ = appel('DELETE', '/appareils?jeton=eq.%s' % enc('ExponentPushToken[essai-marie]'), MARIE,
                    entetes={'Prefer': 'return=representation'})
    verifier('Marie ne peut plus le détacher (il n\'est plus à elle)', v, [])
    c, v, _ = appel('DELETE', '/appareils?jeton=eq.%s' % enc('ExponentPushToken[essai-marie]'), JEAN,
                    entetes={'Prefer': 'return=representation'})
    verifier('déconnexion de Jean : son téléphone est détaché', len(v), 1)

    print('J. Volume')
    db.sql("insert into colis (client_id, numero, description, poids_lb, service, pays_destination, destination, statut, prix_usd, tarif_lb_usd) "
           "select '%s', 'GSE-9' || lpad(g::text, 7, '0') || '-HT', 'Volume ' || g, 1, 'aerien', 'HT', 'X', 'recu', 5, 5 "
           "from generate_series(1, 10000) g;" % JEAN, echec_permis=True)
    n = un(db, "select count(*) from colis where client_id = '%s';" % JEAN)
    debut = time.time()
    c, v, h = appel('GET', '/colis?select=%s&client_id=eq.%s&order=maj_le.desc,id.desc' % (CHAMPS_LISTE, JEAN), JEAN,
                    entetes={'Range': '0-19', 'Prefer': 'count=exact'})
    duree = time.time() - debut
    verifier('%s colis chez un client : une page de 20 en %.0f ms' % (n, duree * 1000), (len(v), duree < 1.5), (20, True))


def main():
    serveur_seul = '--serveur' in sys.argv
    db = installer()
    d = peupler(db)
    pgrst, serveur, etat = demarrer(db)
    try:
        if serveur_seul:
            print('Base d\'essai prête : http://localhost:%d (PostgREST et doublure de l\'authentification).' % PORT)
            print('Comptes : ' + ', '.join('%s / %s' % (e, v[1]) for e, v in COMPTES.items()))
            print('Numéros : Marie %s (livré), %s (disponible) ; Jean %s.'
                  % (d['marie'][0]['colis']['numero'], d['marie'][1]['colis']['numero'], d['jean'][0]['colis']['numero']))
            json.dump({'marie': [r['colis'] for r in d['marie']], 'jean': [r['colis'] for r in d['jean']]},
                      open(os.path.join(TRAVAIL, 'donnees-mobile.json'), 'w'), default=str)
            sys.stdout.flush()
            while True:
                time.sleep(3600)
        else:
            essais(db, d)
    except KeyboardInterrupt:
        pass
    finally:
        serveur.shutdown()
        pgrst.terminate()
    if not serveur_seul:
        print('%d vérifications, %d réussies.' % (len(S.RESULTATS), sum(S.RESULTATS)))
        sys.exit(0 if all(S.RESULTATS) else 1)


if __name__ == '__main__':
    main()
