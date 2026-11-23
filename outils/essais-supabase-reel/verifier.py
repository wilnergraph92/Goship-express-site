# Vérifications sur la base jetable de l'image Supabase PostgreSQL 17 (extensions réelles :
# pgcrypto, Vault, pg_net). Lancé par lancer.sh. Aucun appel réseau sortant : pg_net n'est jamais appelé.
import hashlib, hmac, json, subprocess, time, os
# psql dans le conteneur jetable de lancer.sh (sans réseau), connexion locale
CONTENEUR = os.environ['CONTENEUR_ESSAI']
R = []
def sql(role, texte, echec=False):
    r = subprocess.run(['docker', 'exec', '-i', '-e', 'PGPASSWORD=essai-jetable', CONTENEUR,
                        'psql', '-h', '127.0.0.1', '-U', role, '-d', 'postgres',
                        '-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1', '-c', texte],
                       capture_output=True, text=True)
    if r.returncode and not echec:
        raise SystemExit('ERREUR (%s): %s\n%s' % (role, r.stderr.strip(), texte[:300]))
    return (r.stdout.strip().splitlines() or [''])[-1].strip() if not r.returncode else 'ERREUR:' + r.stderr.strip().splitlines()[-1]
def verifier(titre, obtenu, attendu):
    ok = obtenu == attendu; R.append(ok)
    print('  %s %s' % ('OK  ' if ok else 'RATÉ', titre) + ('' if ok else '\n       obtenu %r attendu %r' % (obtenu, attendu)))

print('Extensions réelles')
verifier('PostgreSQL 17', sql('postgres', "select current_setting('server_version_num')::int / 10000;"), '17')
verifier('postgres n’est pas superutilisateur (comme en production)',
         sql('postgres', "select rolsuper from pg_roles where rolname = current_user;"), 'f')
verifier('pgcrypto réel : SHA-256("abc") = vecteur officiel',
         sql('postgres', "select encode(extensions.digest('abc','sha256'),'hex');"),
         hashlib.sha256(b'abc').hexdigest())
verifier('pgcrypto réel : HMAC-SHA256 identique à Python',
         sql('postgres', "select encode(extensions.hmac('message','cle','sha256'),'hex');"),
         hmac.new(b'cle', b'message', hashlib.sha256).hexdigest())
verifier('pg_net installé (non appelé)', sql('postgres', "select count(*) from pg_extension where extname='pg_net';"), '1')
verifier('Vault réel installé', sql('postgres', "select count(*) from pg_extension where extname='supabase_vault';"), '1')

print('Rôles dédiés (candidate 009)')
for role in ('communication_webhook', 'communication_worker'):
    verifier('%s : seul membership = authenticator' % role,
             sql('supabase_admin', "select string_agg(m.rolname, ',') from pg_auth_members a join pg_roles r on r.oid=a.roleid "
                 "join pg_roles m on m.oid=a.member where r.rolname='%s';" % role), 'authenticator')
    verifier('%s : aucun attribut élevé' % role,
             sql('supabase_admin', "select rolcanlogin or rolinherit or rolsuper or rolcreaterole or rolbypassrls "
                 "from pg_roles where rolname='%s';" % role), 'f')

print('Fonctions internes fermées aux rôles d’API')
for f in ('public.communication_classer_entrant(text,text)', 'public.communication_recevoir_evenement(text,text,text)'):
    verifier('%s non exécutable par anon/authenticated/service_role' % f,
             sql('postgres', "select bool_or(has_function_privilege(r, '%s', 'execute')) "
                 "from unnest(array['anon','authenticated','service_role']) r;" % f), 'f')

print('P-09 sur PostgreSQL 17 (accents, majuscules réelles)')
for texte, attendu in [('Stop please', 'stop'), ('Arrêter les promotions', 'stop'), ('DÉSABONNER', 'stop'),
                       ('No más', 'stop'), ("mon colis s'est arrêté", 'autre'), ('Arrêt de bus', 'autre'),
                       ('Je veux me désabonner', 'ambigu')]:
    verifier('classe %r' % texte, sql('postgres', "select public.communication_classer_entrant($t$%s$t$, null);" % texte), attendu)

print('Webhook signé de bout en bout (HMAC réel, secret dans le vrai Vault)')
cle = 'cle-webhook-synthetique-jetable'
sql('postgres', "select vault.create_secret('%s', 'communication_cle_webhook') "
    "where not exists (select 1 from vault.secrets where name='communication_cle_webhook');" % cle)
# Base neuve à chaque lancement : le poivre n'existe pas encore.
verifier('sans poivre dans Vault : aucune empreinte (la réception refusera, rien en clair)',
         sql('postgres', "select public.communication_consentement_empreinte('17865550142') is null;"), 't')
sql('postgres', "select vault.create_secret('poivre-trop-court', 'communication_poivre');")
verifier('poivre de moins de 32 caractères refusé : aucune empreinte',
         sql('postgres', "select public.communication_consentement_empreinte('17865550142') is null;"), 't')
sql('postgres', "select vault.update_secret(id, 'poivre-synthetique-jetable-0123456789abc') "
    "from vault.secrets where name='communication_poivre';")
verifier('empreinte = HMAC réel du numéro avec le poivre',
         sql('postgres', "select public.communication_consentement_empreinte('17865550142');"),
         hmac.new(b'poivre-synthetique-jetable-0123456789abc', b'goship:communication:whatsapp:v1:17865550142', hashlib.sha256).hexdigest())
verifier('secret relu par lire_reglage depuis le vrai Vault',
         sql('postgres', "select public.lire_reglage('communication_cle_webhook') = '%s';" % cle), 't')

def recevoir(identifiant, texte, signature=None):
    charge = json.dumps({'id': identifiant, 'type': 'inbound', 'telephone': '+17865550142', 'texte': texte,
                         'bouton': None, 'survenu_le': '2026-11-23T12:00:00Z'}, separators=(',', ':'), ensure_ascii=False)
    sig = signature or hmac.new(cle.encode(), ('meta:' + charge).encode(), hashlib.sha256).hexdigest()
    n = int(time.time())
    claims = json.dumps({'role': 'communication_webhook', 'iss': 'issuer-test', 'aud': 'audience-test',
                         'iat': n, 'nbf': n, 'exp': n + 60, 'jti': 'jti-pg17-' + identifiant}, separators=(',', ':'))
    rep = sql('authenticator', """begin;
      set local role communication_webhook;
      set local app.communication_jwt_issuer = 'issuer-test';
      set local app.communication_jwt_audience = 'audience-test';
      set local app.communication_jwt_max_ttl_seconds = '300';
      set local request.jwt.claims = '%s';
      select communication_edge.communication_edge_webhook_recevoir_evenement('meta', $c$%s$c$, '%s');
      commit;""" % (claims, charge, sig), echec=True)
    return rep

def ligne(identifiant):
    return sql('postgres', "select q.classe || '|' || q.priorite from public.communication_evenements_traitement q "
               "join public.communication_evenements_fournisseur e on e.id = q.evenement_id "
               "where e.evenement_id = 'in:' || encode(extensions.digest('%s','sha256'),'hex');" % identifiant)

suffixe = str(int(time.time()))
for ident, texte, attendu in [('meta:pg17-stop-' + suffixe, 'Stop please', 'stop|1'),
                              ('meta:pg17-arreter-' + suffixe, 'Arrêter les promotions', 'stop|1'),
                              ('meta:pg17-colis-' + suffixe, "mon colis s'est arrêté", 'autre|2')]:
    rep = recevoir(ident, texte)
    verifier('réception %r acceptée (signature HMAC calculée hors base)' % texte, '"ok": true' in rep, True)
    verifier('réception %r : classe et priorité' % texte, ligne(ident), attendu)
rep = recevoir('meta:pg17-faux-' + suffixe, 'STOP', signature='0' * 64)
verifier('signature fausse refusée', ('"ok": false' in rep, ligne('meta:pg17-faux-' + suffixe)), (True, ''))
verifier('aucun texte de message gardé en base',
         sql('postgres', "select count(*) from public.communication_evenements_fournisseur "
             "where coalesce(message_id,'') ilike '%stop%';"), '0')

verifier('aucune réponse HTTP reçue par pg_net (conteneur sans réseau)',
         sql('postgres', "select count(*) filter (where status_code is not null) from net._http_response;"), '0')

print('\nRésultat : %d/%d vérifications réussies.' % (sum(R), len(R)))
raise SystemExit(0 if all(R) else 1)
