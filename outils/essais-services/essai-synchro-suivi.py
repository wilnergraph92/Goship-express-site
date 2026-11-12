# -*- coding: utf-8 -*-
"""La synchronisation du suivi externe, Phase 3 du suivi universel (outils/supabase-synchro-suivi.sql).

Même base jetable et même fausse pg_net que essai-moteur-suivi.py : 17TRACK n'est jamais appelé,
l'essai écrit lui-même ses réponses (forme de l'API v2.4). On installe la chaîne SANS ce fichier,
on fait vivre quelques suivis avec le moteur de la Phase 2, puis on pose la migration trois fois :

  A. installation par-dessus une base en service, sans changer une donnée (hormis les noms de
     transporteurs que la liste connaît désormais) ;
  B. la relecture : en route toutes les 6 h, sans premier scan toutes les 12 h, gratuite ;
  C. les fins : livré (une dernière lecture 24 h après), arrivé à Miami (même pas inscrit),
     30 jours de silence, terminé ;
  D. les pré-alertes : interrupteur éteint, puis allumé ; un seul suivi pour un même numéro ;
     plafond du mois ; numéro de commande, USPS, colis déjà arrivé ; jamais d'échec de la
     pré-alerte, même quand le moteur bute ; l'application mobile inchangée ;
  E. l'équipe : demander_suivi_externe et regler_fournisseur_suivi comme avant, plus l'interrupteur ;
  F. sante_suivi_externe et les quatre lignes du contrôle de production ;
  G. rien d'autre ne bouge ; tout est fermé aux clients et aux visiteurs.

    python3 outils/essais-services/essai-synchro-suivi.py
"""
import importlib.util
import json
import os
import subprocess
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location('essai_moteur', os.path.join(ICI, 'essai-moteur-suivi.py'))
M = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(M)
S = M.S

RACINE = S.RACINE
ADMIN, MARIE, JEAN, EMPLOYE, GERANT = M.ADMIN, M.MARIE, M.JEAN, M.EMPLOYE, M.GERANT
verifier, jsonq, creer, un, q = S.verifier, S.jsonq, S.creer, S.un, M.q
CHAINE = M.CHAINE
NOUVEAU = 'supabase-synchro-suivi.sql'
travailler, envois, dernier, repondre, requete_de, requete_quota = (M.travailler, M.envois, M.dernier, M.repondre,
                                                                    M.requete_de, M.requete_quota)
ligne, accepte, info, ev = M.ligne, M.accepte, M.info, M.ev


def un1(db, texte):
    """Une seule exécution (un() lance sa requête deux fois)."""
    return db.sql(texte).splitlines()[-1].strip()


def quota(db, reste=180):
    if requete_quota(db):
        M.quota(db, reste)


def tourner(db, reste=180):
    """Un passage du travailleur, en répondant d'abord au quota s'il l'a demandé."""
    quota(db, reste)
    t = travailler(db)
    if t.get('quota_demande'):
        quota(db, reste)
        t = travailler(db)
    return t


def avancer(db, numero, heures=0):
    """Le temps passe : la prochaine lecture de ce suivi est due."""
    db.sql("update suivis_externes set prochaine_synchro_le = now() - interval '1 second' where numero = %s;" % q(numero))


def lectures_parties(db, depuis):
    return [o['number'] for op, corps, _h in envois(db, depuis) if op == 'gettrackinfo' for o in corps]


def inscriptions_parties(db, depuis):
    return [o['number'] for op, corps, _h in envois(db, depuis) if op == 'register' for o in corps]


def controle(db):
    r = subprocess.run([str(S.PSQL), '-U', db.su, '-h', db.socket, '-d', S.BASE, '-v', 'ON_ERROR_STOP=1', '-X', '-q',
                        '-A', '-t', '-F', '\t', '-f', os.path.join(RACINE, 'outils', 'production', 'controle-integrite.sql')],
                       capture_output=True, text=True)
    if r.returncode:
        raise SystemExit('ERREUR dans controle-integrite.sql\n%s' % r.stderr)
    return {l.split('\t')[0]: l.split('\t')[1:] for l in r.stdout.splitlines() if l.startswith('Suivi externe')}


def prealerte(db, client, numero, magasin='Shein'):
    """Comme l'application : creer_prealerte, sous le compte du client. Rend la réponse."""
    return jsonq(db, client, "select public.creer_prealerte(null, %s, 'Robe', %s, 25, 'aerien');" % (q(magasin), q(numero)))


def lien(db, numero):
    """Les pré-alertes de ce numéro et le suivi auquel elles sont reliées."""
    return un(db, "select coalesce(string_agg(coalesce(s.numero, '-') || '/' || coalesce(s.origine, '-'), ',' "
                  "order by p.cree_le), 'aucune') from prealertes p left join suivis_externes s on s.id = p.suivi_externe_id "
                  "where p.suivi_transporteur = %s;" % q(numero))


def main():
    db = S.Base()
    db.sql(S.DOUBLURES)

    print('A. Installation par-dessus une base en service')
    verifier('la chaîne officielle se termine par ce fichier', CHAINE[-1], NOUVEAU)
    for f in CHAINE[:-1]:
        db.fichier(M.chemin(f))
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
    # Un colis déjà arrivé à Miami, avec le numéro du vendeur : son suivi externe doit s'arrêter
    creer(db, ADMIN, dict(base, client_id=MARIE, suivi_transporteur='GFUS01000000000009'))
    db.sql("select public.definir_reglage('suivi_17track_cle', 'cle-essai-17track');")
    jsonq(db, ADMIN, "select public.regler_fournisseur_suivi('17track', '{\"conformite\": \"PENDING_VERIFICATION\", "
                     "\"essai\": true, \"plafond_essai\": 30, \"marge_quota\": 20}');")
    # Des suivis vivants, par le moteur de la Phase 2 : livré, en route, sans scan, SwiftX, arrivé, refusé
    vivants = {'1Z999AA10123456784': ('Delivered', 'Delivered_Other', 100002),
               'GFUS01000000000002': ('InTransit', 'InTransit_Arrival', 100996),
               'GFUS01000000000003': ('NotFound', 'NotFound_Other', 100996),
               'SWX000000000000004': ('InTransit', 'InTransit_Departure', 101228),
               'GFUS01000000000009': ('InTransit', 'InTransit_Departure', 100996)}
    for n in list(vivants) + ['SWF0000000000005']:
        jsonq(db, ADMIN, "select public.demander_suivi_externe(%s);" % q(n))
    tourner(db)
    req = requete_de(db, '1Z999AA10123456784')
    repondre(db, req, 200, {'code': 0, 'data': {
        'accepted': [accepte(n, c, 3) for n, (_s, _ss, c) in vivants.items()],
        'rejected': [M.rejete('SWF0000000000005', -18019903, 'Carrier cannot be detected.')]}})
    travailler(db)
    db.sql("update suivis_externes set prochaine_synchro_le = now() - interval '1 second' where etape = 'lecture';")
    tourner(db)
    evenements = {n: [ev('2026-11-10T10:00:00Z', 'Picked up', 'Doral, FL, US', 'InTransit_PickedUp')] +
                  ([ev('2026-11-11T14:00:00Z', 'Delivered', 'MEDLEY, FL, US', 'Delivered_Other')] if s == 'Delivered' else [])
                  for n, (s, _ss, _c) in vivants.items() if s != 'NotFound'}
    repondre(db, requete_de(db, '1Z999AA10123456784'), 200, {'code': 0, 'data': {'accepted': [
        info(n, c, s, ss, list(reversed(evenements.get(n, [])))) for n, (s, ss, c) in vivants.items()], 'rejected': []}})
    travailler(db)
    # Le sans-scan a fini ses trois lectures de la Phase 2
    db.sql("update suivis_externes set etat = 'actif', etape = 'fini', lectures = 3, prochaine_synchro_le = null "
           "where numero = 'GFUS01000000000003';")
    verifier('avant la migration : 5 suivis lus, 1 refusé (transporteur inconnu)',
             un(db, "select string_agg(numero || ':' || etat || '/' || etape || '/' || coalesce(statut, '-'), ' ' "
                    "order by numero) from suivis_externes;"),
             '1Z999AA10123456784:actif/fini/DELIVERED GFUS01000000000002:actif/fini/IN_TRANSIT '
             'GFUS01000000000003:actif/fini/NOT_FOUND GFUS01000000000009:actif/fini/IN_TRANSIT '
             'SWF0000000000005:arrete/fini/- SWX000000000000004:actif/fini/IN_TRANSIT')
    db.comme(MARIE, "select public.creer_prealerte(null, 'Temu', 'Lampe', 'TEMU0000000001', 12, 'aerien');")
    interne = M.suivi_interne(db)
    avant = M.empreintes(db, sauf=('fournisseurs_suivi', 'suivis_externes'))
    # Hors le nom du transporteur et la date de mise à jour que le déclencheur de la Phase 1 pose avec lui
    suivis_avant = un(db, "select md5(string_agg((to_jsonb(s) - 'transporteur' - 'maj_le')::text, '|' order by numero)) "
                          "from suivis_externes s;")
    consommes = un(db, "select public.suivi_externe_consommes('17track');")
    for _ in range(3):
        db.fichier(M.chemin(NOUVEAU))
    verifier('la migration s\'installe, puis se relance deux fois sans erreur', 'oui', 'oui')
    verifier('aucune autre donnée existante n\'a changé (%d tables)' % len(avant),
             M.empreintes(db, sauf=('fournisseurs_suivi', 'suivis_externes')), avant)
    verifier('les suivis : rien d\'autre que le nom du transporteur',
             un(db, "select md5(string_agg((to_jsonb(s) - 'transporteur' - 'maj_le' - 'origine' - 'fin_motif' "
                    "- 'livre_vu_le')::text, '|' order by numero)) from suivis_externes s;"), suivis_avant)
    verifier('SwiftX prend son nom ; les autres gardent le leur',
             un(db, "select string_agg(numero || ':' || coalesce(transporteur, '-'), ' ' order by numero) "
                    "from suivis_externes where transporteur_fournisseur is not null;"),
             '1Z999AA10123456784:ups GFUS01000000000002:gofo GFUS01000000000003:gofo GFUS01000000000009:gofo '
             'SWX000000000000004:swiftx')
    verifier('le contrôle de fin de fichier : 4 | 0 | 1 | false | 18',
             un(db, "select (select count(*) from information_schema.columns where table_schema = 'public' and "
                    "((table_name = 'fournisseurs_suivi' and column_name = 'suivre_prealertes') or (table_name = "
                    "'suivis_externes' and column_name in ('origine', 'fin_motif', 'livre_vu_le')))) || '|' || "
                    "(select count(*) from fournisseurs_suivi where suivre_prealertes) || '|' || "
                    "(select count(*) from pg_trigger where tgname = 'suivre_prealerte' and not tgisinternal) || '|' || "
                    "(has_function_privilege('anon', 'public.sante_suivi_externe()', 'execute') or "
                    "has_function_privilege('anon', 'public.planifier_suivis_externes()', 'execute')) || '|' || "
                    "(select count(*) from public.transporteurs_connus());"), '4|0|1|false|18')
    verifier('les suivis existants viennent de l\'équipe ; aucune fin encore',
             un(db, "select string_agg(distinct origine, ',') || '|' || count(*) filter (where fin_motif is not null) "
                    "from suivis_externes;"), 'equipe|0')

    print('\nB. La relecture, gratuite')
    depuis = dernier(db)
    tourner(db)
    verifier('premier passage : 3 replanifiés, 1 livré, 1 arrivé, 1 terminé ; rien de relu tout de suite',
             [un(db, "select count(*) filter (where etape = 'lecture' and livre_vu_le is null) || '|' || "
                     "count(*) filter (where livre_vu_le is not null) || '|' || "
                     "count(*) filter (where fin_motif = 'ARRIVE_MIAMI') || '|' || count(*) filter (where fin_motif = 'TERMINE') "
                     "from suivis_externes;"), lectures_parties(db, depuis)], ['3|1|1|1', []])
    verifier('en route : relu dans 6 h ; sans premier scan : dans 12 h',
             un(db, "select string_agg(numero || ':' || etape || ':' || round(extract(epoch from prochaine_synchro_le - "
                    "derniere_synchro_le) / 3600), ' ' order by numero) from suivis_externes "
                    "where numero in ('GFUS01000000000002', 'GFUS01000000000003', 'SWX000000000000004');"),
             'GFUS01000000000002:lecture:6 GFUS01000000000003:lecture:12 SWX000000000000004:lecture:6')
    avancer(db, 'GFUS01000000000002')
    depuis = dernier(db)
    tourner(db)
    verifier('dû : relu (gettrackinfo, gratuit), avec son transporteur', lectures_parties(db, depuis),
             ['GFUS01000000000002'])
    nouveaux = [ev('2026-11-12T09:00:00Z', 'Out for delivery', 'Medley, FL, US', 'OutForDelivery_Other'),
                ev('2026-11-10T10:00:00Z', 'Picked up', 'Doral, FL, US', 'InTransit_PickedUp')]
    repondre(db, requete_de(db, 'GFUS01000000000002'), 200, {'code': 0, 'data': {'accepted': [
        info('GFUS01000000000002', 100996, 'OutForDelivery', 'OutForDelivery_Other', nouveaux)], 'rejected': []}})
    tourner(db)
    verifier('la relecture range le nouvel événement, une fois, et replanifie à 6 h',
             [ligne(db, 'GFUS01000000000002', "statut || '|' || etape || '|' || "
                                             "round(extract(epoch from prochaine_synchro_le - derniere_synchro_le) / 3600)"),
              un(db, "select count(*) from suivis_externes_evenements e join suivis_externes s on s.id = e.suivi_id "
                     "where s.numero = 'GFUS01000000000002';")], ['OUT_FOR_DELIVERY|lecture|6', '2'])
    verifier('les relectures n\'ont rien coûté', un(db, "select public.suivi_externe_consommes('17track');"), consommes)

    print('\nC. Les fins')
    verifier('livré : une dernière lecture prévue 24 h après',
             ligne(db, '1Z999AA10123456784', "etape || '|' || (livre_vu_le is not null) || '|' || "
                                             "round(extract(epoch from prochaine_synchro_le - livre_vu_le) / 3600)"),
             'lecture|true|24')
    avancer(db, '1Z999AA10123456784')
    tourner(db)
    repondre(db, requete_de(db, '1Z999AA10123456784'), 200, {'code': 0, 'data': {'accepted': [
        info('1Z999AA10123456784', 100002, 'Delivered', 'Delivered_Other', list(reversed(evenements['1Z999AA10123456784'])))],
        'rejected': []}})
    tourner(db)
    verifier('… puis fin : LIVRE, plus jamais relu', ligne(db, '1Z999AA10123456784', "etape || '|' || fin_motif"),
             'fini|LIVRE')
    verifier('arrivé à Miami (un colis GoShip porte ce numéro) : fin ARRIVE_MIAMI',
             ligne(db, 'GFUS01000000000009', "etat || '|' || etape || '|' || fin_motif"), 'actif|fini|ARRIVE_MIAMI')
    verifier('refusé (transporteur inconnu) : TERMINE, en attendant un choix de l\'équipe',
             ligne(db, 'SWF0000000000005', "etat || '|' || fin_motif"), 'arrete|TERMINE')
    db.sql("update suivis_externes set dernier_evenement_le = now() - interval '31 days', etape = 'fini', "
           "prochaine_synchro_le = null where numero = 'SWX000000000000004';")
    tourner(db)
    verifier('30 jours sans nouvel événement : fin SILENCE_30J, TRACKING_EXPIRED',
             ligne(db, 'SWX000000000000004', "fin_motif || '|' || code_resultat"), 'SILENCE_30J|TRACKING_EXPIRED')
    depuis = dernier(db)
    db.sql("update suivis_externes set prochaine_synchro_le = now() - interval '1 second' where fin_motif is not null;")
    tourner(db)
    verifier('un suivi terminé n\'est plus jamais relu', lectures_parties(db, depuis), [])
    r = jsonq(db, ADMIN, "select public.demander_suivi_externe('SWF0000000000005', 'fedex');")
    verifier('l\'équipe choisit un transporteur pour le refusé : il reprend (fin effacée)',
             [r['etat'], r['etape'], r['fin_motif']], ['en_attente', 'inscription', None])

    print('\nD. Les pré-alertes')
    p = prealerte(db, MARIE, 'GFUS01000000000020')
    verifier('interrupteur éteint : la pré-alerte s\'enregistre, aucun suivi',
             [p is not None, lien(db, 'GFUS01000000000020'),
              un(db, "select count(*) from suivis_externes where numero = 'GFUS01000000000020';")],
             [True, '-/-', '0'])
    verifier('allumer sans plafond du mois : refusé',
             db.erreur(ADMIN, "select public.regler_fournisseur_suivi('17track', '{\"suivre_prealertes\": true}');"),
             'MONTHLY_CAP_REQUIRED')
    etat = jsonq(db, ADMIN, "select public.regler_fournisseur_suivi('17track', '{\"suivre_prealertes\": true, "
                            "\"plafond_mensuel\": 2}');")
    f17 = [f for f in etat if f['code'] == '17track'][0]
    verifier('allumé, plafond 2 par mois ; journalisé', [f17['suivre_prealertes'], f17['plafond_mensuel'],
             un(db, "select count(*) from journal_audit where action = 'fournisseur_suivi.reglage' "
                    "and apres ->> 'suivre_prealertes' = 'true';")], [True, 2, '1'])
    prealerte(db, MARIE, ' gfus01000000000021 ')
    prealerte(db, JEAN, 'GFUS01000000000021', 'Amazon')
    verifier('Marie et Jean annoncent le même numéro : un seul suivi, venu d\'une pré-alerte, sans auteur',
             [un(db, "select count(*) || '|' || string_agg(origine || '/' || coalesce(demande_par::text, 'personne'), ',') "
                     "from suivis_externes where numero = 'GFUS01000000000021';"), lien(db, 'GFUS01000000000021')],
             ['1|prealerte/personne', 'GFUS01000000000021/prealerte,GFUS01000000000021/prealerte'])
    for n in ('GFUS01000000000022', 'GFUS01000000000023'):
        prealerte(db, MARIE, n)
    prealerte(db, MARIE, '111-1234567-1234567', 'Amazon')
    prealerte(db, JEAN, '9400111899223399887764', 'Walmart')
    # Annoncé, puis arrivé à Miami avant que le moteur ne l'inscrive : jamais inscrit
    prealerte(db, JEAN, 'GFUS01000000000024', 'Shein')
    creer(db, ADMIN, dict(base, client_id=JEAN, suivi_transporteur='GFUS01000000000024'))
    interne = M.suivi_interne(db)  # le colis que l'essai vient de créer ; plus rien ne doit bouger ensuite
    verifier('numéro de commande : relié, ORDER_NUMBER_DETECTED ; USPS : exclu',
             [ligne(db, '111-1234567-1234567', "etat || '|' || code_resultat"),
              ligne(db, '9400111899223399887764', "etat || '|' || code_resultat")],
             ['arrete|ORDER_NUMBER_DETECTED', 'arrete|UNSUPPORTED_TRACKING'])
    depuis = dernier(db)
    tourner(db)
    tourner(db)
    partis = inscriptions_parties(db, depuis)
    verifier('plafond du mois 2 : deux numéros de pré-alertes inscrits, le troisième attend sans coût',
             [sorted(n for n in partis if n.startswith('GFUS010000000000')),
              ligne(db, 'GFUS01000000000023', "etat || '|' || etape || '|' || (inscription_demandee_le is null)")],
             [['GFUS01000000000021', 'GFUS01000000000022'], 'en_attente|inscription|true'])
    verifier('… la demande de l\'équipe (le refusé, choisi FedEx) passe, elle, hors du plafond des pré-alertes',
             'SWF0000000000005' in partis, True)
    verifier('aucun numéro de commande, USPS ni colis arrivé n\'est parti',
             [n for n in partis if n in ('111-1234567-1234567', '9400111899223399887764', 'GFUS01000000000024')], [])
    verifier('annoncé puis arrivé avant l\'inscription : ARRIVE_MIAMI, jamais inscrit, rien dépensé',
             ligne(db, 'GFUS01000000000024', "etat || '|' || fin_motif || '|' || (inscription_demandee_le is null)"),
             'arrete|ARRIVE_MIAMI|true')
    # Le mois suivant (les inscriptions de ce mois-ci reculées d'un mois)
    db.sql("update suivis_externes set inscription_demandee_le = inscription_demandee_le - interval '35 days' "
           "where origine = 'prealerte';")
    db.sql("update fournisseurs_suivi set quota_lu_le = null where code = '17track';")
    depuis = dernier(db)
    tourner(db)
    verifier('le mois suivant : le troisième part', [n for n in inscriptions_parties(db, depuis)], ['GFUS01000000000023'])
    # Le moteur bute : la pré-alerte s'enregistre quand même
    db.sql("alter table suivis_externes add constraint essai_panne check (numero not like 'PANNE%');")
    p = prealerte(db, MARIE, 'PANNE0000000001')
    db.sql("alter table suivis_externes drop constraint essai_panne;")
    verifier('le moteur bute : la pré-alerte est enregistrée, l\'erreur au journal (son code seulement)',
             [p is not None, lien(db, 'PANNE0000000001'),
              un(db, "select operation || '|' || resultat || '|' || code_erreur from suivis_externes_journal "
                     "where operation = 'prealerte' order by id desc limit 1;")],
             [True, '-/-', 'prealerte|erreur|SQLSTATE_23514'])
    # L'application mobile : la réponse de creer_prealerte et l'insertion directe des anciennes versions
    r = prealerte(db, JEAN, 'GFUS01000000000030')
    verifier('creer_prealerte : même forme de réponse qu\'avant (aucune clé du moteur)',
             sorted(k for k in r if 'suivi_externe' in k), [])
    db.comme(JEAN, "insert into public.prealertes (magasin, description, suivi_transporteur, service) "
                   "values ('Temu', 'Ancienne version', 'GFUS01000000000031', 'aerien');")
    verifier('insertion directe des anciennes versions : acceptée, et suivie', lien(db, 'GFUS01000000000031'),
             'GFUS01000000000031/prealerte')
    verifier('un client ne lit aucun suivi externe, même relié à sa pré-alerte',
             'permission denied' in db.erreur(MARIE, 'select count(*) from public.suivis_externes;'), True)

    print('\nE. L\'équipe')
    r = jsonq(db, ADMIN, "select public.demander_suivi_externe('ABC0000000040');")
    verifier('demander_suivi_externe : nouveau suivi de l\'équipe, avec son auteur',
             [r['origine'], r['demande_par'], r['etat']], ['equipe', ADMIN, 'en_attente'])
    r = jsonq(db, ADMIN, "select public.demander_suivi_externe('GFUS01000000000021');")
    verifier('un numéro déjà suivi (venu d\'une pré-alerte) : rien de renvoyé', r.get('deja'), True)
    verifier('commande, GoShip, vide, hors limites : mêmes réponses qu\'en Phase 2',
             [jsonq(db, ADMIN, "select public.demander_suivi_externe('222-1234567-1234567');")['code_resultat'],
              db.erreur(ADMIN, "select public.demander_suivi_externe('GSE-1001-HT');"),
              db.erreur(ADMIN, "select public.demander_suivi_externe('  ');"),
              jsonq(db, ADMIN, "select public.demander_suivi_externe('AB1');")['code_resultat']],
             ['ORDER_NUMBER_DETECTED', 'GOSHIP_NUMBER', 'TRACKING_REQUIRED', 'UNSUPPORTED_TRACKING'])
    verifier('un employé ne demande rien, ne règle rien',
             [db.erreur(EMPLOYE, "select public.demander_suivi_externe('ABC0000000041');").startswith(('PERMISSION', 'permission')),
              db.erreur(EMPLOYE, "select public.regler_fournisseur_suivi('17track', '{\"suivre_prealertes\": false}');")
              .startswith(('PERMISSION', 'permission'))], [True, True])
    verifier('la liste du choix manuel : 18 transporteurs, avec SwiftX, SpeedX, YWE',
             [len(jsonq(db, EMPLOYE, "select public.transporteurs_suivi();")),
              sorted(t['nom'] for t in jsonq(db, EMPLOYE, "select public.transporteurs_suivi();")
                     if t['code'] in ('swiftx', 'speedx', 'ywe'))], [18, ['SpeedX', 'SwiftX', 'YWE']])

    print('\nF. Santé et contrôle de production')
    s = jsonq(db, EMPLOYE, "select public.sante_suivi_externe();")
    verifier('sante_suivi_externe (employé) : ses clés, aucune clé secrète',
             [sorted(s), 'cle-essai' in json.dumps(s)],
             [sorted(['en_service', 'fournisseur', 'quota_restant', 'quota_lu_le', 'arrets', 'en_cours', 'a_relire',
                      'en_retard', 'erreurs_24h', 'derniere_lecture_ok']), False])
    verifier('… refusée à un client', db.erreur(MARIE, "select public.sante_suivi_externe();")
             .startswith(('PERMISSION', 'permission')), True)
    c = controle(db)
    verifier('contrôle de production : les quatre lignes du suivi externe', sorted(c), sorted([
        'Suivi externe : quota sous 50', 'Suivi externe : fournisseur arrêté tout seul',
        'Suivi externe : lectures en retard de plus de 2 h', 'Suivi externe : appels en erreur (24 h)']))
    verifier('… vertes sur un moteur en bonne santé (erreurs : information seulement)',
             [c[k][0] for k in sorted(c) if k != 'Suivi externe : appels en erreur (24 h)'], ['OK', 'OK', 'OK'])
    db.sql("update fournisseurs_suivi set quota_restant = 40 where code = '17track';"
           "update suivis_externes set prochaine_synchro_le = now() - interval '3 hours' where numero = 'GFUS01000000000002' "
           "and requete is null;")
    c = controle(db)
    verifier('quota 40 et une lecture en retard de 3 h : deux ALERTES',
             [c['Suivi externe : quota sous 50'][0], c['Suivi externe : lectures en retard de plus de 2 h'][0],
              jsonq(db, EMPLOYE, "select public.sante_suivi_externe();")['en_retard'] >= 1], ['ALERTE', 'ALERTE', True])
    db.sql("select public.suivi_externe_arreter('17track', 'CLE_REFUSEE');")
    c = controle(db)
    verifier('fournisseur arrêté tout seul : ALERTE, avec le motif',
             c['Suivi externe : fournisseur arrêté tout seul'][:3:2], ['ALERTE', '17track : CLE_REFUSEE'])
    verifier('… et le retard ne sonne plus (rien n\'est en service)',
             c['Suivi externe : lectures en retard de plus de 2 h'][0], 'OK')
    p = prealerte(db, MARIE, 'GFUS01000000000050')
    verifier('fournisseur arrêté : une pré-alerte s\'enregistre, sans suivi', [p is not None, lien(db, 'GFUS01000000000050')],
             [True, '-/-'])

    print('\nG. Rien d\'autre ne bouge ; tout est fermé')
    verifier('le suivi GoShip : colis, historique, notifications identiques', M.suivi_interne(db), interne)
    for compte, nom in ((MARIE, 'cliente'), (None, 'visiteur')):
        verifier('%s : ni travailleur, ni planification, ni ouverture de suivi' % nom,
                 all('permission denied' in db.erreur(compte, t) for t in (
                     'select public.traiter_suivis_externes();', 'select public.planifier_suivis_externes();',
                     "select public.suivi_externe_ouvrir('GFUS01000000000060', null, 'equipe');")), True)
    verifier('aucune fonction du suivi externe ouverte aux visiteurs',
             un(db, "select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace "
                    "where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute') and p.proname in "
                    "('suivi_externe_ouvrir','planifier_suivis_externes','traiter_suivis_externes','suivre_prealerte',"
                    "'demander_suivi_externe','regler_fournisseur_suivi','etat_fournisseurs_suivi','sante_suivi_externe',"
                    "'transporteurs_connus','liste_suivis_externes','suivi_externe');"), '0')

    ok = sum(S.RESULTATS)
    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), ok))
    sys.exit(0 if ok == len(S.RESULTATS) else 1)


if __name__ == '__main__':
    main()
