# -*- coding: utf-8 -*-
"""Le moteur du suivi externe, Phase 2 du suivi universel (outils/supabase-moteur-suivi.sql).

Même base jetable que essai-services.py, même fausse pg_net (net.envois garde chaque requête,
l'essai écrit lui-même la « réponse de 17TRACK » dans net._http_response) : 17TRACK n'est
JAMAIS appelé ici. Les réponses imitent la forme de l'API v2.4 (documentation lue le
12/11/2026) ; elles éprouvent le code, pas la compatibilité d'un transporteur — c'est le
rôle de l'essai sur de vrais numéros (étape A du dossier de conception).

  A. installation par-dessus une base en service, trois fois, sans changer une donnée ;
  B. la détection : copie SQL et transporteur.js identiques ; numéros de commande et GoShip ;
  C. demander un suivi : permissions, doublons, numéro de commande, hors limites, USPS exclu ;
  D. sans fournisseur en service (ou sans clé) : personne n'est appelé ;
  E. régler un fournisseur : essai seulement s'il est vérifié ou en vérification, un seul en
     service, actif réservé à « VERIFIED », journalisé ;
  F. le quota : relu avant tout lot qui coûte, plafond d'essai jamais dépassé, marge ;
     la requête ne porte que le numéro et le transporteur ;
  G. les réponses : inscrit, refusé (invalide, transporteur inconnu, TBA), lu ; événements
     rangés une fois ; statut inconnu jamais DELIVERED ; adresse du destinataire jamais
     rangée ; date de livraison du transporteur seulement ;
  H. les pannes : 429 et 5xx réessayés 3 fois puis PROVIDER_UNAVAILABLE ; clé refusée et
     quota épuisé arrêtent le fournisseur, sans bascule ;
  I. le choix manuel du transporteur, et le changement qui coûte un numéro ;
  J. le suivi GoShip, les notifications et l'application mobile ne bougent pas ;
     tables et fonctions fermées aux clients et aux visiteurs ;
  L. deux vraies réponses de 17TRACK (étape A, anonymisées : donnees/17track-reel.json) se rangent
     comme dans l'essai réel.

    python3 outils/essais-services/essai-moteur-suivi.py
"""
import importlib.util
import json
import os
import subprocess
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location('essai_services', os.path.join(ICI, 'essai-services.py'))
S = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(S)

RACINE = S.RACINE
ADMIN, MARIE, JEAN = S.ADMIN, S.MARIE, S.JEAN
EMPLOYE = 'cccccccc-0000-0000-0000-00000000000c'
GERANT = 'ffffffff-0000-0000-0000-00000000000f'
verifier, jsonq, creer, un = S.verifier, S.jsonq, S.creer, S.un

CHAINE = [l.strip() for l in open(os.path.join(RACINE, 'outils', 'migrations.txt'), encoding='utf-8')
          if l.strip() and not l.startswith('#')]
NOUVEAU = 'supabase-moteur-suivi.sql'
URL = 'https://api.17track.net/track/v2.4/'
# Une adresse de destinataire telle que 17TRACK la rend : elle ne doit jamais être rangée
RUE = '8400 NW 25th St Suite 110'


def chemin(f):
    return os.path.join(RACINE, 'outils', f)


def q(texte):
    return "'%s'" % texte.replace("'", "''")


def empreintes(db, sauf=()):
    tables = un(db, "select string_agg(relname, ' ' order by relname) from pg_class c join pg_namespace n "
                    "on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r';").split()
    return {t: un(db, "select count(*) || ':' || md5(coalesce(string_agg(to_jsonb(x)::text, '|' order by to_jsonb(x)::text), '')) "
                      "from public.%s x;" % t) for t in tables if t not in sauf}


def suivi_interne(db):
    return (un(db, "select md5(coalesce(string_agg(id || ':' || statut || ':' || lieu || ':' || maj_le, '|' order by id), '')) "
                   "from public.colis;"),
            un(db, "select md5(coalesce(string_agg(h::text, '|' order by h.id), '')) from public.colis_historique h;"),
            un(db, "select count(*) from public.notifications;"),
            un(db, "select count(*) from public.notification_envois;"))


def travailler(db):
    # Une seule exécution : un() lance sa requête deux fois, et le travailleur agit
    return json.loads(db.sql("select public.traiter_suivis_externes();").splitlines()[-1])


def envois(db, depuis=0):
    """[(operation, corps, entêtes)] des requêtes parties après net.envois.id = depuis."""
    lignes = db.sql("select replace(url, %s, '') || '§' || body::text || '§' || headers::text from net.envois "
                    "where id > %d order by id;" % (q(URL), depuis)).splitlines()
    return [(l.split('§')[0], json.loads(l.split('§')[1]), json.loads(l.split('§')[2])) for l in lignes if '§' in l]


def dernier(db):
    return int(un(db, 'select coalesce(max(id), 0) from net.envois;') or 0)


def repondre(db, requete, code, contenu, erreur=None):
    db.sql("insert into net._http_response (id, status_code, content, error_msg) values (%s, %s, %s, %s);"
           % (requete, 'null' if code is None else code,
              'null' if contenu is None else q(contenu if isinstance(contenu, str) else json.dumps(contenu)),
              'null' if erreur is None else q(erreur)))


def requete_de(db, numero):
    return un(db, "select coalesce(requete::text, '') from suivis_externes where numero = %s;" % q(numero))


def requete_quota(db):
    return un(db, "select coalesce(quota_requete::text, '') from fournisseurs_suivi where code = '17track';")


def quota(db, reste):
    """17TRACK répond au getquota en cours."""
    repondre(db, requete_quota(db), 200, {'code': 0, 'data': {'quota_total': 200, 'quota_used': 200 - reste,
                                                              'quota_remain': reste, 'today_used': 0,
                                                              'max_track_daily': 0}})


def ligne(db, numero, champs="etat || '|' || etape || '|' || coalesce(code_resultat, '')"):
    return un(db, "select %s from suivis_externes where numero = %s;" % (champs, q(numero)))


def accepte(numero, carrier, origin=1):
    return {'origin': origin, 'number': numero, 'carrier': carrier, 'email': None, 'lang': None}


def rejete(numero, code, message='refus'):
    return {'number': numero, 'carrier': 0, 'error': {'code': code, 'message': message}}


def info(numero, carrier, statut, sous, evenements, edd=None):
    """Un élément de data.accepted de gettrackinfo, avec ce que 17TRACK rend aussi sur le
    destinataire (shipping_info, misc_info) — que l'adaptateur doit ignorer."""
    return {'number': numero, 'carrier': carrier, 'param': None, 'tag': None,
            'track_info': {
                'shipping_info': {'shipper_address': {'country': 'US', 'state': 'WA', 'city': 'Seattle',
                                                      'street': '410 Terry Ave N', 'postal_code': '98109'},
                                  'recipient_address': {'country': 'US', 'state': 'FL', 'city': 'Miami',
                                                        'street': RUE, 'postal_code': '33122',
                                                        'coordinates': {'longitude': '-80.33', 'latitude': '25.79'}}},
                'latest_status': {'status': statut, 'sub_status': sous, 'sub_status_descr': None},
                'latest_event': evenements[0] if evenements else None,
                'time_metrics': {'days_after_order': 3, 'estimated_delivery_date': edd or {'source': None, 'from': None,
                                                                                            'to': None}},
                'misc_info': {'customer_number': 'CLIENT-MARIE-0042', 'reference_number': 'REF-MARIE'},
                'tracking': {'providers_hash': 1, 'providers': [{
                    'provider': {'key': carrier, 'name': 'UPS', 'country': 'US'},
                    'latest_sync_status': 'Success', 'events': evenements}]}}}


def ev(quand, description, lieu, sous, pays='US'):
    return {'time_iso': quand, 'time_utc': quand, 'description': description, 'location': lieu,
            'stage': None, 'sub_status': sous,
            'address': {'country': pays, 'state': 'FL', 'city': 'Miami', 'street': RUE, 'postal_code': '33122'}}


def detection_js(numeros):
    """Les mêmes numéros passés à assets/js/transporteur.js (Node, sans navigateur)."""
    # Le fichier du dépôt, exécuté tel que le navigateur le charge, dans un contexte à part
    code = ("var vm = require('vm'), window = {}; vm.runInNewContext(require('fs').readFileSync(%s, 'utf8'), "
            "{window: window});"
            "console.log(JSON.stringify(%s.map(function (n) { var t = window.GoshipTransporteur(n); "
            "return t ? t.code : null; })));" % (json.dumps(os.path.join(RACINE, 'assets', 'js', 'transporteur.js')),
                                                 json.dumps(numeros)))
    return json.loads(subprocess.run(['node', '-e', code], capture_output=True, text=True, check=True).stdout)


def main():
    db = S.Base()
    db.sql(S.DOUBLURES)

    print('A. Installation par-dessus une base en service')
    verifier('la chaîne officielle se termine par ce fichier', CHAINE[-1], NOUVEAU)
    for f in CHAINE[:-1]:
        db.fichier(chemin(f))
    for uid, email, nom in ((ADMIN, 'equipe@goship.test', 'Ada Admin'), (EMPLOYE, 'employe@goship.test', 'Emma Employée'),
                            (GERANT, 'gerant@goship.test', 'Gaston Gérant'), (MARIE, 'marie@exemple.com', 'Marie-Ange Dorvil'),
                            (JEAN, 'jean@exemple.com', 'Jean Pierre')):
        db.sql("""insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
                  values ('%s', '%s', now(), '{"nom_complet":"%s","pays":"HT","ville":"Pétion-Ville",
                          "telephone":"+509 3000 0000"}'::jsonb);""" % (uid, email, nom))
    db.sql("select public.definir_admin('equipe@goship.test');")
    jsonq(db, ADMIN, "select public.changer_role('employe@goship.test', 'employe');")
    jsonq(db, ADMIN, "select public.changer_role('gerant@goship.test', 'gerant');")
    base = {'description': 'Chaussures', 'poids_lb': 4, 'service': 'aerien', 'pays_destination': 'HT',
            'destination': 'Pétion-Ville', 'expediteur': 'Amazon', 'lieu': 'Miami (Medley), FL'}
    c1 = creer(db, ADMIN, dict(base, client_id=MARIE, suivi_transporteur='1Z999AA10123456784'))
    creer(db, ADMIN, dict(base, client_id=JEAN, suivi_transporteur='TBA312345678901'))
    jsonq(db, ADMIN, "select public.executer_operation('%s', 'COLIS_EMBALLE', null, null, '{}'::jsonb, null, null, null, null);"
          % c1['colis']['id'])
    db.comme(MARIE, "select public.creer_prealerte(null, 'Walmart', 'Mixeur', '9400111899223399887764', 45, 'aerien');")
    avant = empreintes(db, sauf=('fournisseurs_suivi', 'suivis_externes'))
    fournisseurs_avant = un(db, "select string_agg(code || ':' || conformite || ':' || actif, ',' order by code) "
                                "from fournisseurs_suivi;")
    for _ in range(3):
        db.fichier(chemin(NOUVEAU))
    verifier('la migration s\'installe, puis se relance deux fois sans erreur', 'oui', 'oui')
    verifier('aucune donnée existante n\'a changé (%d tables comparées)' % len(avant),
             empreintes(db, sauf=('fournisseurs_suivi', 'suivis_externes')), avant)
    verifier('les fournisseurs : mêmes codes, même conformité, toujours inactifs',
             un(db, "select string_agg(code || ':' || conformite || ':' || actif, ',' order by code) from fournisseurs_suivi;"),
             fournisseurs_avant)
    verifier('fournisseurs livrés hors service, USPS exclu d\'office',
             un(db, "select string_agg(code || ':' || essai || ':' || array_to_string(transporteurs_exclus, '+'), ',' "
                    "order by code) from fournisseurs_suivi;"), '17track:false:usps,aftership:false:usps')
    verifier('le contrôle de fin de fichier : 21 | 0 | false | false | 0',
             un(db, "select (select count(*) from information_schema.columns where table_schema = 'public' and "
                    "((table_name = 'fournisseurs_suivi' and column_name in ('essai','plafond_essai','marge_quota',"
                    "'quota_restant','quota_lu_le','quota_requete','arret_motif','transporteurs_exclus')) or "
                    "(table_name = 'suivis_externes' and column_name in ('numero_original','inscription_demandee_le',"
                    "'inscrit_le','transporteur_fournisseur','transporteur_origine','etape','requete','requete_le',"
                    "'tentatives','lectures','changements','derniere_erreur','demande_par')))) || '|' || "
                    "(select count(*) from fournisseurs_suivi where actif or essai) || '|' || "
                    "(has_function_privilege('anon', 'public.demander_suivi_externe(text, text)', 'execute') or "
                    "has_function_privilege('anon', 'public.traiter_suivis_externes(integer)', 'execute') or "
                    "has_function_privilege('anon', 'public.liste_suivis_externes(integer)', 'execute')) || '|' || "
                    "('tracking.manage' = any (public.permissions_du_role('client'))) || '|0';"),
             '21|0|false|false|0')
    interne = suivi_interne(db)

    print('\nB. La détection : la copie SQL répond comme transporteur.js')
    numeros = ['1Z999AA10123456784', '1Z999AA10123456785', '1z 999 aa1 0123456784', 'TBA312345678901',
               'TBA31234567890', 'tba312345678901', '9400111899223399887764', '9400111899223399887765',
               '92055901755477000000000013', 'EA123456785US', 'EA123456784US', 'RR123456789CN',
               '794612345678', '420331229400111899223399887764', '1ZABCDEF', '', 'GSE-1001-HT']
    sql = [None if v == '' else v for v in
           un(db, "select string_agg(coalesce(public.detecter_transporteur(n), ''), ',' order by o) from unnest(array[%s]) "
                  "with ordinality as t(n, o);" % ','.join(q(n) for n in numeros)).split(',')]
    js = detection_js(numeros)
    verifier('%d numéros : mêmes réponses des deux côtés' % len(numeros), sql, js)
    verifier('UPS, TBA et USPS reconnus ; clé fausse, FedEx 12 chiffres : rien',
             [sql[0], sql[1], sql[3], sql[4], sql[6], sql[12]], ['ups', None, 'amazon', None, 'usps', None])
    verifier('numéro de commande Amazon et colis GoShip reconnus, un suivi : rien',
             un(db, "select public.nature_numero('111-1234567-1234567') || ',' || public.nature_numero(' gse-1001-ht ') "
                    "|| ',' || coalesce(public.nature_numero('1Z999AA10123456784'), 'suivi');"),
             'commande_amazon,goship,suivi')

    print('\nC. Demander un suivi')
    for compte, nom in ((MARIE, 'cliente'), (None, 'visiteur'), (EMPLOYE, 'employé (tracking.view seulement)'),
                        (GERANT, 'gérant (tracking.view seulement)')):
        e = db.erreur(compte, "select public.demander_suivi_externe('1Z999AA10123456784');")
        verifier('%s : refusé' % nom, 'permission denied' in e or e.startswith('PERMISSION_DENIED'), True)
    r = jsonq(db, ADMIN, "select public.demander_suivi_externe(' 1z999aa1 0123456784 ');")
    verifier('administrateur : demandé, rangé en majuscules, original gardé',
             [r['numero'], r['numero_original'], r['transporteur'], r['transporteur_source'], r['etat'], r['etape']],
             ['1Z999AA10123456784', '1z999aa1 0123456784', 'ups', 'numero', 'en_attente', 'inscription'])
    verifier('qui a demandé : gardé (un compte de l\'équipe, aucune donnée client)', r['demande_par'], ADMIN)
    r = jsonq(db, ADMIN, "select public.demander_suivi_externe('1Z999AA10123456784');")
    verifier('le même numéro deux fois : une seule ligne, rien de renvoyé', [r.get('deja'),
             un(db, "select count(*) from suivis_externes where numero = '1Z999AA10123456784';")], [True, '1'])
    r = jsonq(db, ADMIN, "select public.demander_suivi_externe('111-1234567-1234567');")
    verifier('numéro de commande Amazon : rangé, arrêté, ORDER_NUMBER_DETECTED',
             [r['etat'], r['etape'], r['code_resultat']], ['arrete', 'fini', 'ORDER_NUMBER_DETECTED'])
    verifier('numéro de colis GoShip : refusé, ce n\'est pas un suivi de vendeur',
             db.erreur(ADMIN, "select public.demander_suivi_externe('GSE-1001-HT');"), 'GOSHIP_NUMBER')
    r = jsonq(db, ADMIN, "select public.demander_suivi_externe('AB1');")
    verifier('hors des limites de 17TRACK : UNSUPPORTED_TRACKING, rien rangé',
             [r['code_resultat'], r['enregistre'], un(db, "select count(*) from suivis_externes where numero = 'AB1';")],
             ['UNSUPPORTED_TRACKING', False, '0'])
    verifier('numéro vide : refusé', db.erreur(ADMIN, "select public.demander_suivi_externe('  ');"), 'TRACKING_REQUIRED')
    r = jsonq(db, ADMIN, "select public.demander_suivi_externe('9400111899223399887764');")
    verifier('USPS prouvé : exclu d\'office, jamais envoyé',
             [r['transporteur'], r['etat'], r['code_resultat'], r['derniere_erreur']],
             ['usps', 'arrete', 'UNSUPPORTED_TRACKING', 'TRANSPORTEUR_EXCLU'])
    verifier('transporteur hors liste : refusé',
             db.erreur(ADMIN, "select public.demander_suivi_externe('ABC123456789', 'poste-lune');"), 'CARRIER_INVALID')
    for n in ('TBA312345678901', '794612345678', 'YT2412345678901234', 'BADNUMBER12'):
        jsonq(db, ADMIN, "select public.demander_suivi_externe(%s);" % q(n))
    verifier('la liste de l\'équipe : employé oui, cliente non',
             [len(jsonq(db, EMPLOYE, "select public.liste_suivis_externes();")),
              'permission' in db.erreur(MARIE, "select public.liste_suivis_externes();")
              or db.erreur(MARIE, "select public.liste_suivis_externes();") == 'PERMISSION_DENIED'], [7, True])
    verifier('la liste du choix manuel : 15 transporteurs, pour l\'équipe',
             len(jsonq(db, EMPLOYE, "select public.transporteurs_suivi();")), 15)

    print('\nD. Personne de branché : personne n\'est appelé')
    t = travailler(db)
    verifier('aucun fournisseur en service : le travailleur ne fait rien', [t['en_service'], dernier(db)], [False, 0])

    print('\nE. Régler un fournisseur')
    verifier('essai refusé tant que 17TRACK est « DISABLED »',
             db.erreur(ADMIN, "select public.regler_fournisseur_suivi('17track', '{\"essai\": true}');"), 'PROVIDER_NOT_VERIFIED')
    verifier('actif refusé : il n\'est pas « VERIFIED »',
             db.erreur(ADMIN, "select public.regler_fournisseur_suivi('17track', '{\"actif\": true, "
                              "\"conformite\": \"PENDING_VERIFICATION\"}');"), 'PROVIDER_NOT_VERIFIED')
    verifier('un employé ne règle rien',
             db.erreur(EMPLOYE, "select public.regler_fournisseur_suivi('17track', '{\"plafond_essai\": 5}');")
             .startswith(('PERMISSION_DENIED', 'permission denied')), True)
    verifier('un réglage inconnu (la clé, par exemple) : refusé',
             db.erreur(ADMIN, "select public.regler_fournisseur_suivi('17track', '{\"cle\": \"x\"}');"), 'FIELD_NOT_ALLOWED')
    etat = jsonq(db, ADMIN, "select public.regler_fournisseur_suivi('17track', '{\"conformite\": \"PENDING_VERIFICATION\", "
                            "\"essai\": true, \"plafond_essai\": 3}');")
    f17 = [f for f in etat if f['code'] == '17track'][0]
    verifier('en essai, plafond 3, marge 20, aucune clé dans la réponse',
             [f17['essai'], f17['actif'], f17['plafond_essai'], f17['marge_quota'], f17['consommes'],
              any('cle' in k for k in f17)], [True, False, 3, 20, 0, False])
    verifier('un seul fournisseur en service : AfterShip refusé',
             db.erreur(ADMIN, "select public.regler_fournisseur_suivi('aftership', '{\"conformite\": \"PENDING_VERIFICATION\", "
                              "\"essai\": true}');"), 'PROVIDER_IN_SERVICE')
    verifier('le réglage est au journal d\'audit',
             un(db, "select count(*) from journal_audit where action = 'fournisseur_suivi.reglage' and entite_id = '17track';"),
             '1')

    print('\nF. Le quota avant toute dépense')
    t = travailler(db)
    verifier('sans clé dans le coffre : aucun appel', [t.get('cle'), dernier(db)], [False, 0])
    db.sql("select public.definir_reglage('suivi_17track_cle', 'cle-essai-17track');")
    t = travailler(db)
    e = envois(db)
    verifier('premier passage : la lecture du quota seule, aucune inscription',
             [x[0] for x in e], ['getquota'])
    verifier('… avec la clé du coffre dans l\'en-tête 17token, jamais ailleurs',
             [e[0][2].get('17token'), 'cle-essai-17track' in json.dumps(e[0][1])], ['cle-essai-17track', False])
    quota(db, 200)
    depuis = dernier(db)
    t = travailler(db)
    e = envois(db, depuis)
    verifier('quota lu (200) : une inscription, plafond d\'essai 3 sur 5 demandes en attente',
             [[x[0] for x in e], len(e[0][1]) if e else 0, t['inscriptions']], [['register'], 3, 3])
    corps = e[0][1]
    verifier('la requête ne porte que le numéro et le transporteur prouvé',
             sorted({k for o in corps for k in o}), ['carrier', 'number'])
    verifier('… UPS transmis avec son code 100002, TBA sans code (17TRACK détecte)',
             {o['number']: o.get('carrier') for o in corps if o['number'] in ('1Z999AA10123456784', 'TBA312345678901')},
             {'1Z999AA10123456784': 100002, 'TBA312345678901': None})
    verifier('aucun nom, e-mail, téléphone ni adresse de client dans ce qui part',
             any(s in json.dumps(e) for s in ('Marie', 'marie@', '+509', 'Pétion')), False)
    verifier('consommé compté avant la réponse (3), quota à relire avant le prochain lot',
             [un(db, "select public.suivi_externe_consommes('17track');"),
              un(db, "select (quota_lu_le is null)::text from fournisseurs_suivi where code = '17track';")], ['3', 'true'])
    reste = [n for n in ('1Z999AA10123456784', 'TBA312345678901', '794612345678', 'YT2412345678901234',
                         'BADNUMBER12') if requete_de(db, n) == '']
    verifier('le quatrième et le cinquième attendent : plafond atteint', len(reste), 2)

    print('\nG. Les réponses de 17TRACK')
    req = requete_de(db, '1Z999AA10123456784')
    envoyes = [o['number'] for o in corps]
    acceptes, rejetes = [], []
    for n in envoyes:
        if n == '1Z999AA10123456784':
            acceptes.append(accepte(n, 100002, 2))
        elif n == 'TBA312345678901':
            rejetes.append(rejete(n, -18019903, 'The carrier can not be detected'))
        elif n == 'BADNUMBER12':
            rejetes.append(rejete(n, -18010012, "The format of 'BADNUMBER12' is invalid."))
        else:
            acceptes.append(accepte(n, 3011, 3))
    repondre(db, req, 200, {'code': 0, 'data': {'accepted': acceptes, 'rejected': rejetes}})
    quota(db, 197) if requete_quota(db) else None
    depuis = dernier(db)
    t = travailler(db)
    verifier('UPS : inscrit, transporteur transmis et confirmé, lecture dans une minute',
             ligne(db, '1Z999AA10123456784', "etat || '|' || etape || '|' || transporteur_fournisseur || '|' || "
                                             "transporteur_origine || '|' || (inscrit_le is not null)"),
             'en_attente|lecture|100002|transmis|true')
    if 'TBA312345678901' in envoyes:
        verifier('TBA que 17TRACK ne sait pas détecter : AMAZON_TBA_LIMITATION, rien d\'inventé',
                 ligne(db, 'TBA312345678901'), 'arrete|fini|AMAZON_TBA_LIMITATION')
    autre = [n for n in envoyes if n not in ('1Z999AA10123456784', 'TBA312345678901', 'BADNUMBER12')]
    if autre:
        verifier('transporteur deviné par 17TRACK : gardé avec son origine (« devine »)',
                 ligne(db, autre[0], "transporteur || '|' || transporteur_source || '|' || transporteur_origine"),
                 '17track-3011|fournisseur|devine')
    verifier('le journal des appels : l\'inscription, sans clé ni réponse brute',
             un(db, "select string_agg(operation || ':' || resultat, ',' order by id) from suivis_externes_journal;"),
             'quota:ok,inscription:ok')
    # La lecture, une minute plus tard
    db.sql("update suivis_externes set prochaine_synchro_le = now() - interval '1 second' where etape = 'lecture';")
    depuis = dernier(db)
    travailler(db)
    lectures = [x for x in envois(db, depuis) if x[0] == 'gettrackinfo']
    verifier('la lecture part (gratuite), avec le transporteur inscrit',
             [len(lectures), {o['number']: o.get('carrier') for o in lectures[0][1]}.get('1Z999AA10123456784')],
             [1, 100002])
    evs = [ev('2026-11-12T14:05:00Z', 'Delivered', 'MIAMI, FL, US', 'Delivered_Other'),
           ev('2026-11-12T08:10:00Z', 'Out For Delivery Today', 'Miami, FL, US', 'OutForDelivery_Other'),
           ev('2026-11-10T22:00:00Z', 'Departed from Facility', 'Louisville, KY, US', 'InTransit_Departure'),
           ev('2026-11-11T03:00:00Z', 'Arrived at Facility', 'Doral, FL, US', 'InTransit_Arrival'),
           ev(None, 'Event without a date', 'Nowhere', 'InTransit_Other'),
           ev('2026-11-09T18:00:00Z', 'Shipper created a label', 'Seattle, WA, US', 'InfoReceived')]
    items = [info('1Z999AA10123456784', 100002, 'Delivered', 'Delivered_Other', evs,
                  {'source': 'Official', 'from': '2026-11-12T00:00:00Z', 'to': '2026-11-12T23:59:00Z'})]
    for n in autre:
        items.append(info(n, 3011, 'InTransit', 'InTransit_PickedUp',
                          [ev('2026-11-11T10:00:00Z', 'Picked up', 'Shenzhen, CN', 'InTransit_PickedUp', 'CN')],
                          {'source': '17TRACK', 'from': '2026-11-20T00:00:00Z', 'to': '2026-11-20T00:00:00Z'}))
    reponse_lecture = {'code': 0, 'data': {'accepted': items, 'rejected': []}}
    repondre(db, requete_de(db, '1Z999AA10123456784'), 200, reponse_lecture)
    travailler(db)
    verifier('UPS lu : DELIVERED du transporteur, suivi actif et fini',
             ligne(db, '1Z999AA10123456784', "statut || '|' || statut_original || '|' || sous_statut || '|' || etat "
                                             "|| '|' || etape"), 'DELIVERED|Delivered|Delivered_Other|actif|fini')
    verifier('5 événements rangés (celui sans date est écarté, jamais daté au hasard)',
             un(db, "select count(*) from suivis_externes_evenements e join suivis_externes s on s.id = e.suivi_id "
                    "where s.numero = '1Z999AA10123456784';"), '5')
    verifier('… dans l\'ordre du temps, quel que soit l\'ordre reçu',
             un(db, "select string_agg(e.statut, '>' order by e.survenu_le) from suivis_externes_evenements e "
                    "join suivis_externes s on s.id = e.suivi_id where s.numero = '1Z999AA10123456784';"),
             'INFO_RECEIVED>IN_TRANSIT>IN_TRANSIT>OUT_FOR_DELIVERY>DELIVERED')
    verifier('dernier lieu et date du transporteur ; livraison prévue du transporteur (Official) gardée',
             ligne(db, '1Z999AA10123456784', "dernier_lieu || '|' || dernier_evenement_le::date || '|' || "
                                             "coalesce(livraison_estimee_le::text, '')"),
             'MIAMI, FL, US|2026-11-12|2026-11-12')
    if autre:
        verifier('estimation de 17TRACK lui-même : ignorée (GoShip n\'estime jamais)',
                 ligne(db, autre[0], "coalesce(livraison_estimee_le::text, 'aucune')"), 'aucune')
    for table in ('suivis_externes', 'suivis_externes_evenements', 'suivis_externes_journal', 'fournisseurs_suivi'):
        verifier('%s : ni rue, ni coordonnées, ni référence client' % table,
                 un(db, "select count(*) from public.%s x where to_jsonb(x)::text ~* %s;"
                        % (table, q('8400 NW|25\\.79|CLIENT-MARIE|REF-MARIE|98109|Terry Ave'))), '0')
    # La même réponse reçue une seconde fois : aucun doublon
    sid = un(db, "select id from suivis_externes where numero = '1Z999AA10123456784';")
    db.sql("select public.suivi17_ranger('%s', %s::jsonb);" % (sid, q(json.dumps(items[0]))))
    verifier('la même réponse deux fois : aucun événement en double',
             un(db, "select count(*) from suivis_externes_evenements where suivi_id = '%s';" % sid), '5')
    # Un statut que la correspondance ne connaît pas
    inconnu = info('1Z999AA10123456784', 100002, 'Teleported', 'Teleported_Other',
                   [ev('2026-11-13T01:00:00Z', 'Beamed up', 'Orbit', 'Teleported_Other')])
    db.sql("select public.suivi17_ranger('%s', %s::jsonb);" % (sid, q(json.dumps(inconnu))))
    verifier('un statut inconnu reste vide, jamais DELIVERED (suivi et événement)',
             [ligne(db, '1Z999AA10123456784', "coalesce(statut, 'vide') || '|' || statut_original"),
              un(db, "select coalesce(statut, 'vide') from suivis_externes_evenements where description = 'Beamed up';")],
             ['vide|Teleported', 'vide'])
    db.sql("select public.suivi17_ranger('%s', %s::jsonb);" % (sid, q(json.dumps(items[0]))))

    print('\nH. Pas encore de premier scan, puis les pannes')
    # Le plafond relevé : les deux numéros en attente partent
    jsonq(db, ADMIN, "select public.regler_fournisseur_suivi('17track', '{\"plafond_essai\": 30}');")
    if requete_quota(db):
        quota(db, 197)
    depuis = dernier(db)
    travailler(db)
    if requete_quota(db):
        quota(db, 197)
        travailler(db)
    nouveaux = [x for x in envois(db, depuis) if x[0] == 'register']
    verifier('plafond relevé à 30 : les deux en attente partent, en une requête',
             [len(nouveaux), sorted(o['number'] for o in nouveaux[0][1]) if nouveaux else []],
             [1, sorted(reste)])
    req = requete_de(db, reste[0])
    repondre(db, req, 200, {'code': 0, 'data': {'accepted': [accepte(n, 100003, 1) for n in reste], 'rejected': []}})
    travailler(db)
    db.sql("update suivis_externes set prochaine_synchro_le = now() - interval '1 second' where etape = 'lecture';")
    travailler(db)
    neuf = reste[0]
    repondre(db, requete_de(db, neuf), 200, {'code': 0, 'data': {
        'accepted': [info(n, 100003, 'NotFound', 'NotFound_Other', []) for n in reste], 'rejected': []}})
    travailler(db)
    verifier('aucun premier scan : PENDING_FIRST_SCAN, redemandé dans 5 minutes',
             ligne(db, neuf, "etat || '|' || etape || '|' || code_resultat || '|' || lectures || '|' || "
                             "(prochaine_synchro_le > now() + interval '4 minutes')"),
             'en_attente|lecture|PENDING_FIRST_SCAN|1|true')
    for i in range(2):
        db.sql("update suivis_externes set prochaine_synchro_le = now() - interval '1 second' where numero = %s;" % q(neuf))
        travailler(db)
        repondre(db, requete_de(db, neuf), 200, {'code': 0, 'data': {
            'accepted': [], 'rejected': [rejete(neuf, -18019909, 'No tracking information at this time.')]}})
        travailler(db)
    verifier('après 3 lectures sans scan : fini, toujours PENDING_FIRST_SCAN (la suite : Phase 3)',
             ligne(db, neuf), 'actif|fini|PENDING_FIRST_SCAN')

    # Pannes passagères : 429, 503, réseau, réponse illisible
    autre2 = reste[1]
    db.sql("update suivis_externes set prochaine_synchro_le = now() - interval '1 second', lectures = 0, "
           "etat = 'en_attente', etape = 'lecture' where numero = %s;" % q(autre2))
    pannes = [(429, '{"code":429}', None), (503, 'Service Unavailable', None), (None, None, 'Timeout of 10000 ms reached'),
              (200, '<html>oops</html>', None)]
    for code, contenu, erreur in pannes:
        db.sql("update suivis_externes set prochaine_synchro_le = now() - interval '1 second' where numero = %s;" % q(autre2))
        travailler(db)
        repondre(db, requete_de(db, autre2), code, contenu, erreur)
        travailler(db)
    verifier('429, 503, réseau, illisible : 3 réessais, puis PROVIDER_UNAVAILABLE, suivi gardé',
             ligne(db, autre2, "etat || '|' || code_resultat || '|' || tentatives"), 'erreur|PROVIDER_UNAVAILABLE|4')
    verifier('… chaque panne au journal, sans réponse brute',
             un(db, "select string_agg(resultat || ':' || coalesce(code_http::text, '-'), ',' order by id) "
                    "from suivis_externes_journal where resultat <> 'ok';"),
             'erreur:429,erreur:503,delai:-,erreur:200')

    print('\nI. Le choix manuel du transporteur')
    tba = 'TBA312345678901'
    r = jsonq(db, ADMIN, "select public.demander_suivi_externe(%s, 'amazon_shipping');" % q(tba))
    verifier('TBA refusé, puis choisi « Amazon Shipping » par l\'équipe : redemandé',
             [r['transporteur'], r['transporteur_source'], r['etat'], r['etape']],
             ['amazon_shipping', 'equipe', 'en_attente', 'inscription'])
    if requete_quota(db):
        quota(db, 195)
    depuis = dernier(db)
    travailler(db)
    if requete_quota(db):
        quota(db, 195)
        travailler(db)
    reg = [x for x in envois(db, depuis) if x[0] == 'register']
    verifier('… inscrit avec le code 101392, et ne compte pas deux fois',
             [[o.get('carrier') for o in reg[0][1]] if reg else [], un(db, "select public.suivi_externe_consommes('17track');")],
             [[101392], '5'])
    # Un numéro inscrit dont l'équipe change le transporteur : coûte un numéro de plus
    r = jsonq(db, ADMIN, "select public.demander_suivi_externe('1Z999AA10123456784', 'fedex');")
    verifier('inscrit, puis changé à la main : étape « changement »', r['etape'], 'changement')
    if requete_quota(db):
        quota(db, 195)
    depuis = dernier(db)
    travailler(db)
    if requete_quota(db):
        quota(db, 195)
        travailler(db)
    ch = [x for x in envois(db, depuis) if x[0] == 'changecarrier']
    verifier('… changecarrier : ancien 100002, nouveau 100003, compté (6)',
             [ch[0][1] if ch else None, un(db, "select public.suivi_externe_consommes('17track');")],
             [[{'number': '1Z999AA10123456784', 'carrier_old': 100002, 'carrier_new': 100003}], '6'])

    print('\nJ. Clé refusée, quota épuisé, marge : arrêt, jamais de bascule')
    jsonq(db, ADMIN, "select public.demander_suivi_externe('1Z12345E0205271688');")
    if requete_quota(db):
        quota(db, 195)
    travailler(db)
    if requete_quota(db):
        quota(db, 195)
        travailler(db)
    req = requete_de(db, '1Z12345E0205271688')
    repondre(db, req, 401, {'code': 401, 'data': {'errors': [{'code': -18010002, 'message': 'Access token is invalid.'}]}})
    travailler(db)
    verifier('clé refusée : 17TRACK arrêté (CLE_REFUSEE), le suivi attend, rien d\'autre ne part',
             [un(db, "select essai || '|' || coalesce(arret_motif, '') from fournisseurs_suivi where code = '17track';"),
              ligne(db, '1Z999AA10123456784'.replace('1Z999AA10123456784', '1Z12345E0205271688'),
                    "etat || '|' || etape || '|' || coalesce(derniere_erreur, '')")],
             ['false|CLE_REFUSEE', 'en_attente|inscription|CLE_REFUSEE'])
    verifier('… et AfterShip n\'a pas pris le relais', un(db, "select (essai or actif)::text from fournisseurs_suivi "
                                                             "where code = 'aftership';"), 'false')
    depuis = dernier(db)
    travailler(db)
    verifier('… le travailleur n\'appelle plus personne', dernier(db), depuis)
    verifier('l\'arrêt est au journal d\'audit',
             un(db, "select count(*) from journal_audit where action = 'fournisseur_suivi.arret';"), '1')
    jsonq(db, ADMIN, "select public.regler_fournisseur_suivi('17track', '{\"essai\": true}');")
    travailler(db)
    repondre(db, requete_quota(db), 200, {'code': 0, 'data': {'quota_remain': 18, 'quota_total': 200}})
    travailler(db)
    verifier('quota relu sous la marge (18 ≤ 20) : arrêt QUOTA_MARGE, aucune inscription',
             [un(db, "select essai || '|' || coalesce(arret_motif, '') from fournisseurs_suivi where code = '17track';"),
              ligne(db, '1Z12345E0205271688', "coalesce(requete::text, 'aucune')")], ['false|QUOTA_MARGE', 'aucune'])
    jsonq(db, ADMIN, "select public.regler_fournisseur_suivi('17track', '{\"essai\": true, \"marge_quota\": 0}');")
    travailler(db)
    quota(db, 100)
    travailler(db)
    req = requete_de(db, '1Z12345E0205271688')
    repondre(db, req, 200, {'code': 0, 'data': {'accepted': [], 'rejected': [
        rejete('1Z12345E0205271688', -18019908, 'Your quotas have ran out.')]}})
    travailler(db)
    verifier('quota épuisé chez 17TRACK : arrêt QUOTA_EPUISE, suivi en attente, aucune bascule',
             [un(db, "select essai || '|' || coalesce(arret_motif, '') from fournisseurs_suivi where code = '17track';"),
              ligne(db, '1Z12345E0205271688', "etat || '|' || coalesce(derniere_erreur, '')"),
              un(db, "select (essai or actif)::text from fournisseurs_suivi where code = 'aftership';")],
             ['false|QUOTA_EPUISE', 'en_attente|QUOTA_EPUISE', 'false'])

    print('\nK. Rien d\'autre ne bouge ; tout est fermé')
    verifier('le suivi GoShip : colis, historique, notifications identiques', suivi_interne(db), interne)
    moteur = ('suivis_externes_evenements', 'suivis_externes_journal', 'journal_audit')
    verifier('aucune donnée existante n\'a changé depuis l\'installation (hors tables du moteur et journal d\'audit)',
             empreintes(db, sauf=('fournisseurs_suivi', 'suivis_externes') + moteur),
             {k: v for k, v in avant.items() if k not in moteur})
    for compte, nom in ((MARIE, 'cliente'), (None, 'visiteur'), (EMPLOYE, 'employé')):
        verifier('%s : ne lit aucune table du suivi externe en direct' % nom,
                 all('permission denied' in db.erreur(compte, 'select count(*) from public.%s;' % t)
                     for t in ('suivis_externes', 'suivis_externes_evenements', 'suivis_externes_journal',
                               'fournisseurs_suivi')), True)
        verifier('%s : ne lance pas le travailleur, ne range rien' % nom,
                 all('permission denied' in db.erreur(compte, texte) for texte in (
                     'select public.traiter_suivis_externes();',
                     "select public.suivi17_ranger(gen_random_uuid(), '{}'::jsonb);",
                     "select public.suivi_externe_arreter('17track', 'x');",
                     "select public.detecter_transporteur('1Z999AA10123456784');")), True)
    verifier('employé : lit un suivi externe (tracking.view), sans clé',
             'cle' in json.dumps(jsonq(db, EMPLOYE, "select public.suivi_externe('1Z999AA10123456784');")).lower()
             .replace('cle_', ''), False)
    r = jsonq(db, MARIE, "select public.creer_prealerte(null, 'Target', 'Lampe', 'TBA999888777666', 30, 'aerien');")
    verifier('application mobile : creer_prealerte inchangée, aucune trace du moteur',
             [r is not None, 'suivi_externe_id' in (r or {}),
              un(db, "select count(*) from suivis_externes where numero = 'TBA999888777666';")], [True, False, '0'])
    verifier('aucune fonction du moteur ouverte aux visiteurs',
             un(db, "select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace "
                    "where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute') and p.proname in "
                    "('detecter_transporteur','nature_numero','transporteurs_connus','suivi17_code','suivi17_transporteur',"
                    "'suivi17_corps','suivi17_refus','suivi17_ranger','suivi17_reponse','suivi17_quota_reponse',"
                    "'suivi_externe_consommes','suivi_externe_arreter','suivi_externe_reessayer','traiter_suivis_externes',"
                    "'demander_suivi_externe','regler_fournisseur_suivi','liste_suivis_externes','transporteurs_suivi',"
                    "'etat_fournisseurs_suivi');"), '0')

    print('\nL. De vraies réponses de 17TRACK (étape A du 12/11/2026, anonymisées)')
    reel = json.load(open(os.path.join(ICI, 'donnees', '17track-reel.json'), encoding='utf-8'))
    verifier('la donnée d\'essai ne garde ni adresse du destinataire ni référence client',
             [k for a in reel['lecture']['data']['accepted'] for k in ('shipping_info', 'misc_info') if k in a['track_info']],
             [])
    verifier('le refus réel « transporteur non détecté » → CARRIER_UNKNOWN (choix manuel)',
             un(db, "select public.suivi17_refus(%d);" % reel['inscription']['data']['rejected'][0]['error']['code']),
             'CARRIER_UNKNOWN')
    attendus = {'1Z999AA10123456784': ('REEL-UPS-0001', 13), 'GFUS01000000000001': ('GFUS01000000000001', 17)}
    for item in reel['lecture']['data']['accepted']:
        numero, nb = attendus[item['number']]
        # Une seule exécution chacune : un() lance sa requête deux fois
        sid = db.sql("insert into suivis_externes (numero, fournisseur, etat, etape) values (%s, '17track', 'en_attente', "
                     "'lecture') returning id;" % q(numero)).splitlines()[0].strip()
        code = db.sql("select coalesce(public.suivi17_ranger('%s', %s::jsonb), 'aucun');"
                      % (sid, q(json.dumps(item)))).splitlines()[-1].strip()
        verifier('%s : %d événements réels rangés, statut et lieu du transporteur' % (numero, nb),
                 [code, un(db, "select count(*) from suivis_externes_evenements where suivi_id = '%s';" % sid),
                  ligne(db, numero, "statut || '|' || transporteur || '|' || (dernier_lieu ilike '%%medley%%')")],
                 ['aucun', str(nb), 'DELIVERED|%s|true' % ('ups' if numero.startswith('REEL') else 'gofo')])
        verifier('%s : chaque statut d\'événement reconnu, aucun inventé' % numero,
                 un(db, "select count(*) filter (where statut is null) || '/' || count(*) from suivis_externes_evenements "
                        "where suivi_id = '%s';" % sid), '0/%d' % nb)

    ok = sum(S.RESULTATS)
    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), ok))
    sys.exit(0 if ok == len(S.RESULTATS) else 1)


if __name__ == '__main__':
    main()
