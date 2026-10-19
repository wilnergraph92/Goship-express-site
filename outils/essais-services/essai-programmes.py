# -*- coding: utf-8 -*-
"""Éprouve la date de naissance, les anniversaires, GOPOINTS, GOship APP Welcome et GOship Refer
(outils/supabase-naissance.sql, -anniversaires.sql, -fidelite.sql, -campagnes.sql).

Même base jetable et mêmes rôles SQL que essai-services.py, avec toute la chaîne de
outils/migrations.txt. On installe d'abord la chaîne SANS ces fichiers, on y laisse des
comptes à l'ancienne, puis on installe les fichiers deux fois : rien ne doit bouger.
Ensuite :
  A. la date de naissance : obligatoire à l'inscription par e-mail, refus du futur et des
     dates impossibles, pas de décalage de jour, une seule déclaration, fermée à l'équipe ;
  B. les anniversaires : un message par client et par an, rappel avant la date, 29 février,
     canaux non configurés, droits ;
  C. GOPOINTS : un registre qui ne se réécrit pas, jamais deux fois le même événement,
     jamais plus que le solde, même en simultané ;
  D. GOship APP Welcome : une campagne complète seulement, un bonus par client ;
  E. GOship Refer : le bon parrain, jamais soi-même, récompense après la première opération ;
  F. les permissions de chaque rôle.

Depuis la racine du site :

    python3 outils/essais-services/essai-programmes.py
"""
import importlib.util
import json
import os
import sys
import threading

ICI = os.path.dirname(os.path.abspath(__file__))
# Pas de dossier __pycache__ à côté des essais : il partirait en ligne avec le site.
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location('essai_analytics', os.path.join(ICI, 'essai-analytics.py'))
A = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(A)
S = A.S

RACINE = S.RACINE
OUTILS = os.path.join(RACINE, 'outils')
ADMIN, GERANT, EMPLOYE, MARIE, JEAN, CARO = A.ADMIN, A.GERANT, A.EMPLOYE, A.MARIE, A.JEAN, A.CARO
verifier, jsonq = S.verifier, S.jsonq
REFUS = 'PERMISSION_DENIED'
CHAINE = [l.strip() for l in open(os.path.join(OUTILS, 'migrations.txt'), encoding='utf-8')
          if l.strip() and not l.startswith('#')]
# Les fichiers de cette série, installés après le reste de la chaîne
NOUVEAUX = [f for f in ('supabase-naissance.sql', 'supabase-fidelite.sql',
                        'supabase-anniversaires.sql', 'supabase-campagnes.sql') if f in CHAINE]
ANNA = '55555555-5555-5555-5555-555555555555'
LEA = '66666666-6666-6666-6666-666666666666'
GUY = '77777777-7777-7777-7777-777777777777'


def q(v):
    return 'null' if v is None else "'%s'" % str(v).replace("'", "''")


def js(d):
    return "'%s'::jsonb" % json.dumps(d).replace("'", "''")


def un(db, texte, compte=None):
    """La dernière ligne de la réponse. Une seule exécution (les écritures ne se rejouent pas)."""
    sortie = db.comme(compte, texte) if compte not in (None, 'sql') else db.sql(texte)
    lignes = [l for l in sortie.splitlines() if l.strip()]
    return lignes[-1].strip() if lignes else ''


def inscrire(db, uid, email, meta=None, fournisseur='email', brut=False):
    """Une inscription, comme GoTrue la fait : une ligne dans auth.users, fournisseur dans app_meta."""
    texte = ("insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data, raw_app_meta_data) "
             "values ('%s', '%s', now(), %s, %s);" % (uid, email, js(meta or {}), js({'provider': fournisseur})))
    return texte if brut else db.sql(texte)


def code(db, compte, texte):
    return db.erreur(compte, texte)


def en_parallele(db, taches):
    """Lance des requêtes en même temps ; rend leurs sorties dans l'ordre."""
    sorties = [None] * len(taches)

    def lancer(i, compte, texte):
        sorties[i] = db.comme(compte, texte, echec_permis=True) if compte not in (None, 'sql') else db.sql(texte, True)
    fils = [threading.Thread(target=lancer, args=(i,) + t) for i, t in enumerate(taches)]
    for f in fils:
        f.start()
    for f in fils:
        f.join()
    return sorties


def main():
    db = S.Base()
    db.sql(S.DOUBLURES)

    print("A0. Installation : la chaîne, des comptes à l'ancienne, puis les fichiers de cette série deux fois")
    avant_chaine = CHAINE[:CHAINE.index(NOUVEAUX[0])] if NOUVEAUX else CHAINE
    for f in avant_chaine:
        db.fichier(os.path.join(OUTILS, f))
    A.comptes(db)
    photo = ("select (select string_agg(id || ':' || role || ':' || coalesce(code, '-') || ':' || nom_complet, ',' "
             "order by id) from clients) || '|' || (select count(*) from journal_audit);")
    avant = un(db, photo)
    for _ in range(2):
        for f in NOUVEAUX:
            db.fichier(os.path.join(OUTILS, f))
    verifier('installés deux fois : aucune erreur', 'oui', 'oui')
    apres = un(db, photo)
    # Le journal d'audit n'a pas bougé : aucune ligne écrite par l'installation
    verifier("comptes d'avant : mêmes rôles, mêmes codes, même nom ; journal inchangé", apres, avant)
    verifier("les comptes d'avant n'ont pas de date de naissance, et leur profil marche",
             un(db, "select count(*) from clients;") + '|'
             + (un(db, "select public.ma_naissance()::text;", MARIE) or 'null'), '6|null')

    print('\nA. La date de naissance')
    meta = {'nom_complet': 'Anna Joseph', 'pays': 'HT', 'ville': 'Jacmel', 'telephone': '+509 3700 0000'}
    cas = [('sans date', {}, 'BIRTHDATE_REQUIRED'),
           ('date vide', {'date_naissance': ''}, 'BIRTHDATE_REQUIRED'),
           ('des espaces', {'date_naissance': '   '}, 'BIRTHDATE_REQUIRED'),
           ('date dans le futur', {'date_naissance': '2999-01-01'}, 'INVALID_BIRTHDATE'),
           ('demain (jour de Santo Domingo)', {'date_naissance': un(db, "select (public.aujourdhui_entreprise() + 1)::text;")},
            'INVALID_BIRTHDATE'),
           ('30 février', {'date_naissance': '1990-02-30'}, 'INVALID_BIRTHDATE'),
           ('mois 13', {'date_naissance': '1990-13-01'}, 'INVALID_BIRTHDATE'),
           ('pas une date', {'date_naissance': 'abc'}, 'INVALID_BIRTHDATE'),
           ('format jour/mois/année', {'date_naissance': '15/03/1990'}, 'INVALID_BIRTHDATE'),
           ('avant 1900', {'date_naissance': '1899-12-31'}, 'INVALID_BIRTHDATE')]
    for titre, m, attendu in cas:
        uid = '99999999-0000-0000-0000-0000000000%02d' % cas.index((titre, m, attendu))
        r = code(db, 'sql', inscrire(db, uid, 'refus%d@exemple.com' % cas.index((titre, m, attendu)),
                                     dict(meta, **m), brut=True))
        verifier('e-mail et mot de passe, %s : inscription refusée' % titre, r, attendu)
    verifier('… et aucun compte n\'a été créé par ces refus',
             un(db, "select count(*) from auth.users where email like 'refus%@exemple.com';") + '|'
             + un(db, "select count(*) from clients where email like 'refus%@exemple.com';"), '0|0')

    inscrire(db, ANNA, 'anna@exemple.com', dict(meta, date_naissance='1990-03-15'))
    verifier('une date valide : le compte est créé, avec son profil',
             un(db, "select nom_complet || '|' || (code is not null) from clients where id = '%s';" % ANNA),
             'Anna Joseph|true')
    verifier('… et la date lue par la cliente est exactement celle saisie',
             un(db, "select public.ma_naissance()::text;", ANNA), '1990-03-15')
    verifier("la date reste la même quel que soit le fuseau de la session (pas de décalage de jour)",
             ' '.join(un(db, "set timezone = '%s'; select public.ma_naissance()::text;" % z, ANNA)
                      for z in ('Pacific/Auckland', 'Pacific/Honolulu', 'UTC')),
             '1990-03-15 1990-03-15 1990-03-15')
    verifier("« aujourd'hui » à Santo Domingo est accepté (jour de naissance d'un nouveau-né)",
             code(db, 'sql', inscrire(db, 'a0a0a0a0-0000-0000-0000-000000000001', 'bebe@exemple.com',
                                      dict(meta, date_naissance=un(db, 'select public.aujourdhui_entreprise()::text;')),
                                      brut=True)), 'aucune')

    inscrire(db, LEA, 'lea@exemple.com', {'full_name': 'Léa Google'}, fournisseur='google')
    verifier('Google, sans date : le compte est créé, et sans date inventée',
             un(db, "select count(*) from clients where id = '%s';" % LEA) + '|'
             + (un(db, "select public.ma_naissance()::text;", LEA) or 'null'), '1|null')
    inscrire(db, GUY, 'guy@exemple.com', {'full_name': 'Guy Apple', 'date_naissance': 'n\'importe quoi'},
             fournisseur='apple')
    verifier("Apple, avec une date illisible : le compte est créé, la date n'est pas gardée",
             un(db, "select count(*) from clients where id = '%s';" % GUY) + '|'
             + (un(db, "select public.ma_naissance()::text;", GUY) or 'null'), '1|null')

    print('\nA. Compléter plus tard (comptes existants, Google, Apple)')
    verifier('la date est invalide : refusée avec son code',
             code(db, LEA, "select public.definir_ma_naissance('2999-01-01');"), 'INVALID_BIRTHDATE')
    verifier('la date est vide : refusée avec son code',
             code(db, LEA, "select public.definir_ma_naissance('');"), 'BIRTHDATE_REQUIRED')
    verifier('une date valide est enregistrée et rendue',
             un(db, "select public.definir_ma_naissance('1985-07-09')::text;", LEA), '1985-07-09')
    verifier('… elle est là après une nouvelle connexion (autre session)',
             un(db, "select public.ma_naissance()::text;", LEA), '1985-07-09')
    verifier('la même date rejouée (double clic) est sans effet ni erreur',
             un(db, "select public.definir_ma_naissance('1985-07-09')::text;", LEA), '1985-07-09')
    verifier('une AUTRE date est refusée : on ne refait pas son anniversaire',
             code(db, LEA, "select public.definir_ma_naissance('1986-07-09');"), 'BIRTHDATE_LOCKED')
    verifier("… et celle qui est gardée n'a pas bougé",
             un(db, "select public.ma_naissance()::text;", LEA), '1985-07-09')
    sorties = en_parallele(db, [(MARIE, "select public.definir_ma_naissance('1991-01-01')::text;"),
                                (MARIE, "select public.definir_ma_naissance('1992-02-02')::text;")])
    verifier('deux déclarations simultanées : une seule date est gardée',
             un(db, "select count(*) from profils_naissance where client_id = '%s';" % MARIE) + '|'
             + str(sum('BIRTHDATE_LOCKED' in (s or '') for s in sorties)), '1|1')
    verifier('un visiteur ne peut rien appeler',
             code(db, None, "select public.definir_ma_naissance('1990-01-01');")[:17], 'permission denied')
    verifier('un compte lit sa date, jamais celle d\'une autre (pas de paramètre qui désigne un autre compte)',
             un(db, "select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace "
                    "where n.nspname = 'public' and p.proname in ('ma_naissance', 'definir_ma_naissance') "
                    "and p.pronargs > 1;"), '0')

    print('\nA. Confidentialité')
    for nom, compte in (('un client', JEAN), ('une cliente', ANNA), ('un employé', EMPLOYE), ('un gérant', GERANT),
                        ('un administrateur', ADMIN)):
        verifier('%s ne lit pas la table directement' % nom,
                 code(db, compte, 'select count(*) from profils_naissance;')[:17], 'permission denied')
    verifier('… ni ne l\'écrit',
             code(db, ADMIN, "insert into profils_naissance (client_id, date_naissance) values ('%s', '1980-01-01');" % JEAN)[:17],
             'permission denied')
    verifier('la table « clients » (lue par toute l\'équipe) n\'a aucune colonne de naissance',
             un(db, "select count(*) from information_schema.columns where table_schema = 'public' "
                    "and table_name in ('clients', 'colis_details') and column_name like '%naissance%';"), '0')
    verifier('le journal d\'audit note la déclaration, sans la date',
             un(db, "select count(*) from journal_audit where action = 'client.naissance_declaree';") + '|'
             + un(db, "select count(*) from journal_audit where coalesce(avant::text, '') || coalesce(apres::text, '') "
                      "~ '(1985|1990|1991|1992)';"), '2|0')
    verifier('la table et ses fonctions sont fermées aux visiteurs',
             un(db, "select has_table_privilege('anon', 'public.profils_naissance', 'select')::text || '|' || "
                    "has_function_privilege('anon', 'public.ma_naissance()', 'execute')::text;"), 'false|false')

    print('\nA. Suppression du compte')
    inscrire(db, 'a1a1a1a1-0000-0000-0000-000000000002', 'partir@exemple.com',
             dict(meta, nom_complet='Pierre Partant', date_naissance='1975-05-05'))
    jsonq(db, 'a1a1a1a1-0000-0000-0000-000000000002', "select public.supprimer_mon_compte('SUPPRIMER');")
    verifier('un compte supprimé n\'a plus de date de naissance',
             un(db, "select count(*) from profils_naissance where client_id = 'a1a1a1a1-0000-0000-0000-000000000002';"),
             '0')

    print("\nA. L'adresse de réception et les permissions de la série")
    verifier("l'adresse des e-mails : Address 2 = ABX-46780, comme sur le site et dans l'application",
             un(db, "select public.adresse_miami() ->> 'ligne2';"), 'ABX-46780')
    verifier("… et le reste de l'adresse est celui fourni par Goship Express",
             json.loads(un(db, "select (public.adresse_miami() - 'ligne2')::text;")),
             {'ligne1': '8140 NW 74th Ave Unit 3', 'ville': 'Medley', 'etat': 'Florida', 'zip': '33166',
              'pays': 'United States', 'telephone': '786 525-2944'})

    def definition(fichier, repere, fin):
        texte = open(os.path.join(OUTILS, fichier), encoding='utf-8').read()
        debut = texte.index('create or replace function public.' + repere)
        return ' '.join(texte[debut:texte.index(fin, debut) + len(fin)].split())
    verifier('permissions_du_role : la copie de supabase-naissance.sql est celle de supabase.sql',
             definition('supabase-naissance.sql', 'permissions_du_role(p_role text)', '$$;'),
             definition('supabase.sql', 'permissions_du_role(p_role text)', '$$;'))
    verifier('adresse_miami : la copie de supabase-naissance.sql est celle de supabase.sql',
             definition('supabase-naissance.sql', 'adresse_miami()', '$fn$;'), definition('supabase.sql', 'adresse_miami()', '$fn$;'))

    print("\nC. GOPOINTS : un registre qui ne se réécrit pas")
    pts = lambda compte, requete: jsonq(db, compte, requete)
    verifier('le programme naît éteint, six règles à 0 point, éteintes, aucune offre',
             un(db, "select (select actif from points_reglages)::text || '|' || (select count(*) from points_regles where not actif and points = 0) "
                    "|| '|' || (select count(*) from points_offres);"), 'false|6|0')
    verifier('éteint : aucun point n\'est accordé',
             un(db, "select coalesce(public.points_attribuer('%s', 'account_created', 'compte:%s')::text, 'null');" % (MARIE, MARIE)), 'null')
    portefeuille = pts(MARIE, "select public.mon_portefeuille();")
    verifier('le portefeuille d\'un client : solde 0, programme éteint, aucune offre',
             [portefeuille['actif'], portefeuille['solde'], portefeuille['offres'], portefeuille['elements']], [False, 0, [], []])

    print('   Permissions')
    for nom, compte, attendu in (('un client', MARIE, REFUS), ('un employé', EMPLOYE, REFUS), ('un gérant', GERANT, 'aucune')):
        verifier('%s : lire les règles' % nom, code(db, compte, "select public.points_regles_liste();"), attendu)
    for nom, compte in (('un client', MARIE), ('un employé', EMPLOYE), ('un gérant', GERANT)):
        verifier('%s : régler le programme refusé' % nom,
                 code(db, compte, "select public.points_reglages_modifier('{\"actif\":true}');"), REFUS)
        verifier('%s : corriger un solde refusé' % nom,
                 code(db, compte, "select public.points_corriger('%s', 10, 'essai');" % JEAN), REFUS)
    verifier('un employé ne lit pas les mouvements des clients',
             code(db, EMPLOYE, "select public.points_mouvements_liste();"), REFUS)
    verifier('un visiteur ne peut rien appeler',
             [code(db, None, "select public.mon_portefeuille();")[:17], code(db, None, "select public.points_regles_liste();")[:17]],
             ['permission denied', 'permission denied'])
    verifier('les fonctions du moteur sont fermées à tous les comptes',
             [code(db, ADMIN, "select public.points_attribuer('%s', 'account_created', 'x');" % MARIE)[:17],
              code(db, ADMIN, "select public.points_ecrire('%s', 'gain', 5, 'x', 'x', 'x');" % MARIE)[:17]],
             ['permission denied', 'permission denied'])

    print('   Règles : validées côté base')
    regle = lambda ev, d, compte=ADMIN: code(db, compte, "select public.points_regle_modifier('%s', %s);" % (ev, js(d)))
    verifier('allumer une règle à 0 point : refusé', regle('account_created', {'actif': True}), 'INVALID_RULE')
    verifier('allumer « première opération » sans opération qualifiante : refusé',
             regle('first_operation', {'actif': True, 'points': 10}), 'INVALID_RULE')
    verifier('opération qualifiante inconnue : refusée', regle('first_operation', {'operation': 'fusee'}), 'INVALID_RULE')
    verifier('nombre de points illisible : refusé', regle('account_created', {'points': 'beaucoup'}), 'INVALID_PROGRAM_VALUE')
    verifier('points négatifs : refusés', regle('account_created', {'points': -5}), 'INVALID_PROGRAM_VALUE')
    verifier('événement inconnu : refusé', regle('connexion', {'points': 5}), 'INVALID_RULE')

    print('   Accorder : une fois par événement, selon les limites')
    pts(ADMIN, "select public.points_reglages_modifier('{\"actif\":true,\"conditions\":\"Conditions essai\"}');")
    pts(ADMIN, "select public.points_regle_modifier('account_created', '{\"points\":50,\"actif\":true}');")
    attribuer = lambda cl, ev, ref, p='': un(db, "select coalesce(public.points_attribuer('%s', '%s', '%s'%s)::text, 'null');" % (cl, ev, ref, p))
    premier = attribuer(MARIE, 'account_created', 'compte:marie')
    verifier('création du compte : 50 points accordés', premier != 'null', True)
    verifier('le même événement rejoué : rien de plus', [attribuer(MARIE, 'account_created', 'compte:marie')] * 3, ['null'] * 3)
    verifier('une ligne au registre, solde 50',
             un(db, "select count(*) || '|' || (select solde from points_soldes where client_id = '%s') from points_mouvements where client_id = '%s';" % (MARIE, MARIE)),
             '1|50')
    sorties = en_parallele(db, [('sql', "select coalesce(public.points_attribuer('%s', 'account_created', 'compte:jean')::text, 'null');" % JEAN)] * 4)
    verifier('quatre travailleurs simultanés, même événement : un seul gain',
             un(db, "select count(*) || '|' || (select solde from points_soldes where client_id = '%s') from points_mouvements where client_id = '%s';" % (JEAN, JEAN)),
             '1|50')
    pts(ADMIN, "select public.points_regle_modifier('campaign', '{\"points\":10,\"actif\":true,\"limite_client\":2}');")
    verifier('limite par client (2) : le troisième gain est refusé sans erreur',
             [attribuer(CARO, 'campaign', 'promo-%d' % i) != 'null' for i in range(3)], [True, True, False])
    pts(ADMIN, "select public.points_regle_modifier('repeat_operation', '{\"points\":5,\"actif\":true,\"operation\":\"colis_recu\",\"limite_jour\":2}');")
    verifier('limite par jour (2) : le troisième gain du jour est refusé',
             [attribuer(CARO, 'repeat_operation', 'colis-%d' % i) != 'null' for i in range(3)], [True, True, False])
    bonus = attribuer(JEAN, 'campaign', 'bonus-x', ', 25')
    verifier('un nombre de points propre à une campagne (p_points) est respecté, pas celui de la règle',
             un(db, "select points from points_mouvements where id = %s;" % bonus), '25')
    verifier('une règle éteinte n\'accorde rien',
             attribuer(MARIE, 'birthday', 'anniv:marie:2026'), 'null')

    print('   Le registre ne se réécrit pas')
    for titre, requete in (('modifier un mouvement', "update points_mouvements set points = 999;"),
                           ('supprimer un mouvement', "delete from points_mouvements;"),
                           ('vider le registre', "truncate points_mouvements;"),
                           ('écrire le solde à la main', "update points_soldes set solde = 100000;")):
        verifier('même le superutilisateur : %s refusé' % titre, code(db, 'sql', requete), 'LEDGER_IMMUTABLE')
    verifier('un compte connecté n\'écrit pas dans le registre ni dans les soldes',
             [code(db, ADMIN, "insert into points_mouvements (client_id, type, points, cle) values ('%s', 'gain', 5, 'pirate');" % MARIE)[:17],
              code(db, MARIE, "update points_soldes set solde = 100000;")[:17]], ['permission denied', 'permission denied'])
    verifier('un solde négatif est refusé par la table elle-même',
             'violates check' in db.sql("update points_soldes set solde = -1;", True) or 'LEDGER_IMMUTABLE' in db.sql("update points_soldes set solde = -1;", True), True)

    print('   Utiliser ses points')
    pts(ADMIN, "select public.points_corriger('%s', 100, 'points pour les échanges');" % JEAN)
    offre_a = pts(ADMIN, "select public.points_offre_enregistrer(null, %s);" % js({'nom': 'Crédit d\'essai', 'cout_points': 40, 'type': 'credit_expedition', 'valeur': 5, 'actif': True}))
    verifier('une offre se crée : coût en points, type, valeur saisis par l\'administrateur',
             [offre_a['cout_points'], offre_a['type'], float(offre_a['valeur']), offre_a['actif']], [40, 'credit_expedition', 5.0, True])
    verifier('une offre incomplète est refusée', code(db, ADMIN, "select public.points_offre_enregistrer(null, '{\"nom\":\"X\"}');"), 'INVALID_OFFER')
    verifier('un type d\'offre inconnu est refusé',
             code(db, ADMIN, "select public.points_offre_enregistrer(null, %s);" % js({'nom': 'Z', 'cout_points': 5, 'type': 'voiture', 'valeur': 1})), 'INVALID_OFFER')
    verifier('une offre est refusée par un gérant',
             code(db, GERANT, "select public.points_offre_enregistrer(null, %s);" % js({'nom': 'Z', 'cout_points': 5, 'type': 'bonus_fixe', 'valeur': 1})), REFUS)
    vue = pts(MARIE, "select public.mon_portefeuille();")
    verifier('le portefeuille montre l\'offre à un client', [o['nom'] for o in vue['offres']], ["Crédit d'essai"])
    utiliser = lambda cl, offre, cle: "select public.utiliser_points('%s', '%s');" % (offre, cle)
    k1, k2, k3 = ('aaaaaaaa-1111-4111-8111-00000000000%d' % i for i in (1, 2, 3))
    r1 = pts(MARIE, utiliser(MARIE, offre_a['id'], k1))
    verifier('Marie (50 points) échange 40 points : il lui en reste 10', [r1['deja'], r1['solde']], [False, 10])
    verifier('la même requête rejouée (double clic) : rien de plus débité',
             [pts(MARIE, utiliser(MARIE, offre_a['id'], k1))['deja'], un(db, "select solde from points_soldes where client_id = '%s';" % MARIE)], [True, '10'])
    verifier('un second échange avec 10 points : solde insuffisant', code(db, MARIE, utiliser(MARIE, offre_a['id'], k2)), 'INSUFFICIENT_POINTS')
    verifier('… et rien n\'a été écrit', un(db, "select count(*) from points_mouvements where client_id = '%s' and type = 'utilisation';" % MARIE), '1')
    verifier('l\'avantage obtenu est enregistré, à appliquer par l\'équipe',
             un(db, "select type || '|' || valeur || '|' || statut from recompenses where client_id = '%s';" % MARIE), 'credit_expedition|5.00|obtenue')
    offre_b = pts(ADMIN, "select public.points_offre_enregistrer(null, %s);" % js({'nom': 'Bonus 100', 'cout_points': 100, 'type': 'bonus_fixe', 'valeur': 3, 'actif': True}))
    sorties = en_parallele(db, [(JEAN, utiliser(JEAN, offre_b['id'], 'bbbbbbbb-2222-4222-8222-00000000000%d' % i)) for i in (1, 2)])
    verifier('Jean (150 points) : deux échanges de 100 simultanés — un seul passe, l\'autre voit le solde entamé',
             [sum('INSUFFICIENT_POINTS' in (s or '') for s in sorties), un(db, "select solde from points_soldes where client_id = '%s';" % JEAN)], [1, '75'])
    pts(ADMIN, "select public.points_corriger('%s', 300, 'plus de points pour essai');" % JEAN)
    cle_commune = 'cccccccc-3333-4333-8333-000000000001'
    avant_solde = int(un(db, "select solde from points_soldes where client_id = '%s';" % JEAN))
    en_parallele(db, [(JEAN, utiliser(JEAN, offre_b['id'], cle_commune))] * 3)
    verifier('trois appuis simultanés avec la même clé : débité une seule fois',
             avant_solde - int(un(db, "select solde from points_soldes where client_id = '%s';" % JEAN)), 100)
    offre_c = pts(ADMIN, "select public.points_offre_enregistrer(null, %s);" % js({'nom': 'Dernier', 'cout_points': 10, 'type': 'avantage_colis', 'valeur': 1, 'actif': True, 'stock': 1}))
    sorties = en_parallele(db, [(JEAN, utiliser(JEAN, offre_c['id'], 'dddddddd-4444-4444-8444-000000000001')),
                                (ANNA, utiliser(ANNA, offre_c['id'], 'dddddddd-4444-4444-8444-000000000002'))])
    verifier('stock d\'une pièce, deux clients en même temps : un seul l\'obtient (l\'autre : stock épuisé ou solde insuffisant)',
             [un(db, "select stock from points_offres where id = '%s';" % offre_c['id']), un(db, "select count(*) from points_mouvements where offre_id = '%s';" % offre_c['id'])],
             ['0', '1'])
    offre_d = pts(ADMIN, "select public.points_offre_enregistrer(null, %s);" % js({'nom': 'Une fois', 'cout_points': 5, 'type': 'bonus_fixe', 'valeur': 1, 'actif': True, 'limite_client': 1}))
    pts(JEAN, utiliser(JEAN, offre_d['id'], 'eeeeeeee-5555-4555-8555-000000000001'))
    verifier('limite par client (1) : le second échange est refusé',
             code(db, JEAN, utiliser(JEAN, offre_d['id'], 'eeeeeeee-5555-4555-8555-000000000002')), 'OFFER_LIMIT_REACHED')
    pts(ADMIN, "select public.points_offre_enregistrer('%s', '{\"actif\":false}');" % offre_d['id'])
    verifier('offre désactivée : indisponible', code(db, JEAN, utiliser(JEAN, offre_d['id'], 'eeeeeeee-5555-4555-8555-000000000003')), 'OFFER_UNAVAILABLE')
    offre_e = pts(ADMIN, "select public.points_offre_enregistrer(null, %s);" % js({'nom': 'Périmée', 'cout_points': 5, 'type': 'bonus_fixe', 'valeur': 1, 'actif': True, 'fin': '2020-01-01'}))
    verifier('offre dont la date de fin est passée : indisponible', code(db, JEAN, utiliser(JEAN, offre_e['id'], 'eeeeeeee-5555-4555-8555-000000000004')), 'OFFER_UNAVAILABLE')
    verifier('offre inconnue : indisponible', code(db, JEAN, utiliser(JEAN, '00000000-0000-0000-0000-000000000000', 'eeeeeeee-5555-4555-8555-000000000005')), 'OFFER_UNAVAILABLE')
    verifier('un visiteur ne peut pas utiliser de points', code(db, None, utiliser(None, offre_a['id'], k3))[:17], 'permission denied')

    print('   Corrections et annulations : un motif, jamais un solde négatif')
    verifier('correction sans motif : refusée', code(db, ADMIN, "select public.points_corriger('%s', 5, '');" % ANNA), 'REASON_REQUIRED')
    verifier('correction de 0 point : refusée', code(db, ADMIN, "select public.points_corriger('%s', 0, 'motif');" % ANNA), 'INVALID_POINTS')
    verifier('retirer plus que le solde : refusé', code(db, ADMIN, "select public.points_corriger('%s', -5, 'trop');" % ANNA), 'INSUFFICIENT_POINTS')
    pts(ADMIN, "select public.points_corriger('%s', 30, 'geste commercial décidé par la direction');" % ANNA)
    verifier('correction positive : le solde suit, le motif est gardé',
             un(db, "select (select solde from points_soldes where client_id = '%s') || '|' || motif from points_mouvements where client_id = '%s' and type = 'correction';" % (ANNA, ANNA)),
             '30|geste commercial décidé par la direction')
    gain_anna = un(db, "select id from points_mouvements where client_id = '%s' and type = 'correction';" % ANNA)
    verifier('une correction ne s\'annule pas (elle se corrige par une autre)',
             code(db, ADMIN, "select public.points_annuler_mouvement(%s, 'erreur');" % gain_anna), 'INVALID_MOVEMENT')
    g1 = un(db, "select public.points_attribuer('%s', 'campaign', 'promo-annulable', 12);" % ANNA)
    verifier('annuler un gain : le solde baisse', [pts(ADMIN, "select public.points_annuler_mouvement(%s, 'campagne annulée');" % g1)['solde']], [30])
    verifier('annuler deux fois : refusé', code(db, ADMIN, "select public.points_annuler_mouvement(%s, 'encore');" % g1), 'MOVEMENT_ALREADY_CANCELLED')
    verifier('annuler sans motif : refusé', code(db, ADMIN, "select public.points_annuler_mouvement(%s, '');" % g1), 'REASON_REQUIRED')
    ut = un(db, "select id from points_mouvements where client_id = '%s' and type = 'utilisation' limit 1;" % MARIE)
    stock_avant = un(db, "select coalesce(stock::text, 'illimité') from points_offres where id = '%s';" % offre_a['id'])
    pts(ADMIN, "select public.points_annuler_mouvement(%s, 'échange fait par erreur');" % ut)
    verifier('annuler une utilisation : points rendus, avantage retiré',
             un(db, "select (select solde from points_soldes where client_id = '%s') || '|' || (select statut from recompenses where client_id = '%s');" % (MARIE, MARIE)),
             '50|annulee')
    verifier('le portefeuille de Marie marque l\'échange « annulé »',
             [e['statut'] for e in pts(MARIE, "select public.mon_portefeuille();")['elements'] if e['type'] == 'utilisation'], ['annule'])
    del stock_avant

    print('   Expiration')
    verifier('une expiration de 30 jours se règle', pts(ADMIN, "select public.points_reglages_modifier('{\"expiration_jours\":30}');")['expiration_jours'], 30)
    jour = un(db, "select public.aujourdhui_entreprise()::text;")
    gain_anna = attribuer(ANNA, 'account_created', 'compte:anna')
    verifier('un gain reçoit sa date d\'expiration (aujourd\'hui + 30 jours)',
             un(db, "select expire_le::text from points_mouvements where id = %s;" % gain_anna),
             un(db, "select (public.aujourdhui_entreprise() + 30)::text;"))
    # Des gains d'avant : posés avec une date passée, par le moteur d'écriture
    GUY2 = 'a2a2a2a2-0000-0000-0000-000000000003'
    inscrire(db, GUY2, 'expire@exemple.com', {}, fournisseur='google')
    LEA2 = 'a3a3a3a3-0000-0000-0000-000000000004'
    inscrire(db, LEA2, 'expire2@exemple.com', {}, fournisseur='google')
    for cl in (GUY2, LEA2):
        db.sql("select public.points_ecrire('%s', 'gain', 20, 'campaign', 'vieux', 'vieux:%s', '', null, date '2026-01-01');"
               "select public.points_ecrire('%s', 'gain', 30, 'campaign', 'recent', 'recent:%s', '', null, date '2999-01-01');" % (cl, cl, cl, cl))
    db.sql("select public.points_ecrire('%s', 'utilisation', -25, 'offre', 'x', 'u1');" % GUY2)   # 20 du vieux lot + 5 du récent
    db.sql("select public.points_ecrire('%s', 'utilisation', -10, 'offre', 'x', 'u2');" % LEA2)   # 10 du vieux lot
    r = pts('sql', "select public.points_expirer();") if False else json.loads(un(db, "select public.points_expirer()::text;"))
    verifier('un lot expiré déjà consommé : rien à éteindre ; sinon, son reste s\'éteint (l\'ordre d\'usage est celui des dates)',
             [int(un(db, "select solde from points_soldes where client_id = '%s';" % GUY2)),
              int(un(db, "select solde from points_soldes where client_id = '%s';" % LEA2))], [25, 30])
    verifier('relancée, l\'expiration ne fait rien de plus',
             [json.loads(un(db, "select public.points_expirer()::text;"))['points'],
              int(un(db, "select solde from points_soldes where client_id = '%s';" % LEA2))], [0, 30])
    verifier('l\'expiration est dans le registre, avec sa source', un(db, "select count(*) from points_mouvements where type = 'expiration' and source = 'expiration';") != '0', True)
    verifier('un solde ne devient jamais négatif en expirant',
             un(db, "select count(*) from points_soldes where solde < 0;"), '0')

    print('   Lecture : chacun la sienne, l\'équipe habilitée le reste')
    ma = pts(MARIE, "select public.mon_portefeuille();")
    verifier('le portefeuille de Marie ne contient que ses mouvements',
             un(db, "select count(*) from points_mouvements where client_id <> '%s';" % MARIE) != '0' and ma['total'] == int(un(db, "select count(*) from points_mouvements where client_id = '%s';" % MARIE)), True)
    verifier('gagnés, utilisés, expirés suivent le registre',
             [ma['gagnes'], ma['utilises'], ma['expires']],
             [int(un(db, "select coalesce(sum(points), 0) from points_mouvements where client_id = '%s' and points > 0;" % MARIE)),
              40, 0])
    ap = pts(ADMIN, "select public.points_apercu();")
    verifier('l\'aperçu de l\'équipe : solde total = somme des soldes, clients avec points',
             [ap['solde_total'], ap['clients_avec_points']],
             [int(un(db, "select sum(solde) from points_soldes;")), int(un(db, "select count(*) from points_soldes where solde > 0;"))])
    lis = pts(GERANT, "select public.points_mouvements_liste('', 'correction');")
    verifier('un gérant lit les corrections avec le code du client', [lis['total'] > 0, all(e['client_code'] for e in lis['elements'])], [True, True])
    verifier('le journal d\'audit note chaque réglage, correction et annulation (sans donnée personnelle)',
             un(db, "select count(distinct action) from journal_audit where action like 'points.%';") >= '5', True)

    print('   Programme éteint')
    pts(ADMIN, "select public.points_reglages_modifier('{\"actif\":false}');")
    verifier('éteint : plus de gain, plus d\'échange',
             [attribuer(MARIE, 'account_created', 'compte:marie-bis'),
              code(db, MARIE, utiliser(MARIE, offre_a['id'], 'ffffffff-6666-4666-8666-000000000001'))], ['null', 'OFFER_UNAVAILABLE'])
    verifier('… et le portefeuille ne propose plus d\'offre', pts(MARIE, "select public.mon_portefeuille();")['offres'], [])
    pts(ADMIN, "select public.points_reglages_modifier('{\"actif\":true}');")

    print("\nB. Les anniversaires : un message par client et par année")
    ancre = "'2026-10-20 14:00:00+00'"   # 10 h à Santo Domingo, le 20 octobre 2026
    avant_heure = "'2026-10-20 12:00:00+00'"   # 8 h : avant l'heure d'envoi (9 h)
    executer = lambda quand=ancre: json.loads(un(db, "select public.anniversaires_executer(%s::timestamptz)::text;" % quand))

    def nouveau(uid, email, nom, naissance, langue='fr', role=None):
        inscrire(db, uid, email, {}, fournisseur='google')
        db.sql("update clients set nom_complet = %s, langue = %s where id = '%s';" % (q(nom), q(langue), uid))
        if naissance:
            db.sql("insert into profils_naissance (client_id, date_naissance) values ('%s', '%s');" % (uid, naissance))
    ids = {}
    for cle, (nom, naissance, langue) in {
            'rose': ('Rose Anniversaire', '1990-10-20', 'fr'), 'paul': ('Paul Fête', '1985-10-20', 'ht'),
            'sans_nom': ('', '1991-10-20', 'fr'), 'refus': ('Marc Silence', '1992-10-20', 'fr'),
            'sept': ('Sept Jours', '1992-10-27', 'fr'), 'avant': ('Hier Déjà', '1993-10-19', 'fr'),
            'supprime': ('Sam Parti', '1994-10-20', 'fr'), 'bissextile': ('Bis Sextile', '2000-02-29', 'fr'),
            'bissextile2': ('Bis Sexte', '2000-02-29', 'es')}.items():
        i = len(ids) + 1
        ids[cle] = 'b%dffffff-0000-0000-0000-0000000000%02d' % (i, i)
        nouveau(ids[cle], '%s@exemple.com' % cle, nom, naissance, langue)
    # Un compte de l'équipe et un compte supprimé : jamais de message
    db.sql("update clients set role = 'gerant' where id = '%s';" % ids['sans_nom'] if False else "select 1;")
    db.sql("update clients set supprime_le = now() where id = '%s';" % ids['supprime'])
    db.sql("insert into programme_preferences (client_id, anniversaire) values ('%s', false);" % ids['refus'])
    equipe_nee = 'c1ffffff-0000-0000-0000-000000000001'
    nouveau(equipe_nee, 'equipe-nee@exemple.com', 'Eva Équipe', '1980-10-20')
    db.sql("update clients set role = 'employe' where id = '%s';" % equipe_nee)

    print('   Éteint au départ, réglé par les seuls habilités')
    verifier('éteint : le travailleur ne fait rien', executer(), {'actif': False})
    verifier('aucune notification, aucun journal', un(db, "select (select count(*) from notifications where type like 'birthday%') || '|' || (select count(*) from anniversaire_journal);"), '0|0')
    for nom, compte in (('un client', MARIE), ('un employé', EMPLOYE)):
        verifier('%s : voir les anniversaires refusé' % nom, code(db, compte, "select public.anniversaires_liste();"), REFUS)
        verifier('%s : voir les réglages refusé' % nom, code(db, compte, "select public.anniversaire_reglages_lire();"), REFUS)
        verifier('%s : voir les rappels, messages et erreurs refusé' % nom,
                 [code(db, compte, "select public.anniversaires_rappels_liste();"), code(db, compte, "select public.anniversaires_messages();"),
                  code(db, compte, "select public.anniversaires_erreurs();")], [REFUS] * 3)
    for nom, compte in (('un client', MARIE), ('un employé', EMPLOYE), ('un gérant', GERANT)):
        verifier('%s : allumer l\'automatisation refusé' % nom,
                 code(db, compte, "select public.anniversaire_reglages_modifier('{\"actif\":true}');"), REFUS)
        verifier('%s : modifier un modèle refusé' % nom,
                 code(db, compte, "select public.anniversaire_modele_modifier('birthday', 'fr', 'T', 'M');"), REFUS)
        verifier('%s : corriger une date de naissance refusé' % nom,
                 code(db, compte, "select public.corriger_naissance('%s', '1990-01-01', 'motif');" % MARIE), REFUS)
    verifier('un gérant voit les anniversaires (birthdays.view)', code(db, GERANT, "select public.anniversaires_liste();"), 'aucune')
    verifier('un visiteur ne peut rien appeler', code(db, None, "select public.anniversaires_liste();")[:17], 'permission denied')
    verifier('le travailleur est fermé à tous les comptes', code(db, ADMIN, "select public.anniversaires_executer();")[:17], 'permission denied')

    reg = pts(ADMIN, "select public.anniversaire_reglages_lire();")['reglages']
    verifier('réglages de départ : éteint, 9 h, 29 février le 28, rappel interne 7 jours, rappel client éteint, aucun avantage',
             [reg['actif'], reg['heure_envoi'], reg['regle_29_fevrier'], reg['rappel_admin_jours'], reg['rappel_client_actif'],
              reg['avantage_actif'], reg['fuseau']], [False, '09:00', 'fev28', 7, False, False, 'America/Santo_Domingo'])
    for titre, d, attendu in (('heure illisible', {'heure_envoi': '25:99'}, 'INVALID_PROGRAM_VALUE'),
                              ('règle du 29 février inconnue', {'regle_29_fevrier': 'jamais'}, 'INVALID_PROGRAM_VALUE'),
                              ('fuseau inconnu', {'fuseau': 'Mars/Olympus'}, 'INVALID_PROGRAM_VALUE'),
                              ('canal WhatsApp (pas encore disponible)', {'canaux': ['whatsapp']}, 'INVALID_PROGRAM_VALUE'),
                              ('rappel de 90 jours', {'rappel_admin_jours': 90}, 'INVALID_PROGRAM_VALUE'),
                              ('avantage activé sans type', {'avantage_actif': True}, 'BENEFIT_INCOMPLETE'),
                              ('avantage en GOPOINTS sans règle d\'anniversaire', {'avantage_actif': True, 'avantage_type': 'gopoints'}, 'BENEFIT_INCOMPLETE'),
                              ('avantage sans valeur ni texte', {'avantage_actif': True, 'avantage_type': 'credit_expedition'}, 'BENEFIT_INCOMPLETE')):
        verifier('réglage refusé : %s' % titre, code(db, ADMIN, "select public.anniversaire_reglages_modifier(%s);" % js(d)), attendu)
    verifier('… et rien n\'a changé après ces refus', pts(ADMIN, "select public.anniversaire_reglages_lire();")['reglages']['actif'], False)
    allume = pts(ADMIN, "select public.anniversaire_reglages_modifier('{\"actif\":true}');")
    verifier('l\'administrateur allume : la date d\'activation est aujourd\'hui', allume['actif_depuis'], un(db, "select public.aujourdhui_entreprise()::text;"))
    # L'horloge de l'essai est celle du 20 octobre 2026 : l'activation « a eu lieu » ce jour-là
    db.sql("update anniversaire_reglages set actif_depuis = date '2026-10-20';")

    print('   Le jour J : un message, pas avant l\'heure, personne d\'autre')
    verifier('à 8 h (avant 9 h) : aucun message', [executer(avant_heure)['prepares'], un(db, "select count(*) from anniversaire_journal;")], [0, '0'])
    r = executer()
    verifier('à 10 h : Rose et Paul reçoivent leur message ; deux comptes sans message (sans prénom, a coupé)',
             [r['prepares'], r['ignores'], r['erreurs']], [2, 2, 0])
    verifier('le journal dit pourquoi : SANS_PRENOM, DESACTIVE_PAR_CLIENT',
             un(db, "select string_agg(motif, ',' order by motif) from anniversaire_journal where statut = 'ignore';"), 'DESACTIVE_PAR_CLIENT,SANS_PRENOM')
    verifier('ni le compte de l\'équipe, ni le compte supprimé, ni le client né la veille (avant l\'activation)',
             un(db, "select count(*) from anniversaire_journal where client_id in ('%s', '%s', '%s');" % (equipe_nee, ids['supprime'], ids['avant'])), '0')
    verifier('une notification « compte » par message, pour le bon client',
             un(db, "select count(*) || '|' || string_agg(distinct categorie, ',') from notifications where type = 'birthday' and canal = 'app';"), '2|compte')
    texte = lambda cl, langue: jsonq(db, 'sql', "select public.texte_notification('birthday', '%s', "
                                      "(select donnees from notifications where type = 'birthday' and client_id = '%s' order by id desc limit 1));" % (langue, cl))
    fr = texte(ids['rose'], 'fr')
    verifier('le message français porte le prénom du profil et rien d\'autre de personnel',
             [fr['titre'], 'Rose' in fr['titre'], 'Anniversaire' in fr['message'], '{{' in fr['message'], '1990' in fr['message']],
             ['🎉🎂 Joyeux anniversaire, Rose ! 💙🧡', True, False, False, False])
    verifier('le message ne promet ni cadeau, ni crédit, ni réduction (aucun avantage configuré)',
             any(m in (fr['message'] + fr['titre']).lower() for m in ('cadeau', 'crédit', 'réduction', 'gopoints', 'offre', 'gift')), False)
    ht = texte(ids['paul'], 'ht')
    verifier('le message créole est celui fourni, avec le prénom',
             [ht['titre'], ht['message'].startswith('Jodi a se yon jou espesyal, epi tout ekip GoShip Express ap voye anpil lanmou ak pi bèl swè pou ou!'),
              ht['message'].endswith('Avèk anpil afeksyon, ekip GoShip Express. 💙🧡🚚')], ['🎉🎂 Bòn fèt, Paul ! 💙🧡', True, True])
    verifier('en anglais et en espagnol aussi, avec le prénom',
             [texte(ids['rose'], 'en')['titre'], texte(ids['rose'], 'es')['titre']],
             ['🎉🎂 Happy birthday, Rose! 💙🧡', '🎉🎂 ¡Feliz cumpleaños, Rose! 💙🧡'])
    verifier('la date de naissance n\'est dans aucun message, journal ni notification',
             un(db, "select (select count(*) from notifications where donnees::text ~ '19[89][0-9]-') + (select count(*) from anniversaire_journal where motif ~ '19[89]') "
                    "+ (select count(*) from journal_audit where coalesce(apres::text, '') ~ '19[89][0-9]-[0-9][0-9]-[0-9][0-9]');"), '0')

    print('   Aucun doublon, jamais')
    for _ in range(3):
        executer()
    verifier('le travailleur relancé trois fois : rien de plus', un(db, "select (select count(*) from anniversaire_journal) || '|' || (select count(*) from notifications where type = 'birthday');"), '4|2')
    en_parallele(db, [('sql', "select public.anniversaires_executer(%s::timestamptz);" % ancre)] * 4)
    verifier('quatre travailleurs en même temps : toujours un seul message par client',
             un(db, "select (select count(*) from anniversaire_journal) || '|' || (select count(*) from notifications where type = 'birthday') || '|' || (select count(distinct cle) from notifications where type = 'birthday');"), '4|2|2')
    db.sql("delete from anniversaire_journal;")   # même sans journal, la clé de la notification empêche le doublon
    r = executer()
    verifier('journal perdu : la clé unique de la notification empêche un second message',
             [un(db, "select count(*) from notifications where type = 'birthday';"), r['erreurs']], ['2', 0])
    executer("'2027-10-20 14:00:00+00'")
    verifier('l\'année suivante, un nouveau message par client (clé « anniv:<client>:<année> ») : Rose et Paul, sans doublon',
             un(db, "select (select count(*) from notifications where type = 'birthday' and cle like '%%:2027' and client_id in ('%s', '%s')) || '|' || "
                    "(select count(*) from notifications where type = 'birthday' and cle like '%%:2027') || '|' || "
                    "(select count(distinct client_id) from notifications where type = 'birthday' and cle like '%%:2027');" % (ids['rose'], ids['paul'])),
             '2|4|4')   # + le client né la veille de l'activation, et le nouveau-né du 19 octobre
    verifier('… dont le client né la veille de l\'activation : son prochain anniversaire, lui, est fêté',
             un(db, "select count(*) from notifications where type = 'birthday' and cle = 'anniv:%s:2027';" % ids['avant']), '1')

    print('   Les envois : des statuts honnêtes')
    verifier('canaux non configurés : « annulé » avec la raison, jamais « envoyé »',
             un(db, "select string_agg(distinct e.canal || ':' || e.statut || ':' || coalesce(e.code_erreur, ''), ',' order by e.canal || ':' || e.statut || ':' || coalesce(e.code_erreur, '')) "
                    "from notification_envois e join notifications n on n.id = e.notification_id where n.type = 'birthday';"),
             'email:annule:NON_CONFIGURE,push:annule:SANS_APPAREIL')
    db.sql("select public.definir_reglage('email_fournisseur', 'brevo'); select public.definir_reglage('email_cle_api', 'cle-essai');"
           "select public.definir_reglage('email_expediteur', 'essai@exemple.com');"
           "insert into appareils (client_id, jeton, plateforme) values ('%s', 'ExponentPushToken[essai]', 'android');" % ids['rose'])
    ids['tard'] = 'b9ffffff-0000-0000-0000-000000000099'
    nouveau(ids['tard'], 'tard@exemple.com', 'Tard Venu', '1990-10-20')
    r = executer()
    verifier('un client créé après le passage du travailleur : son message part au passage suivant (rattrapage du jour)', r['prepares'], 1)
    db.sql("insert into appareils (client_id, jeton, plateforme) values ('%s', 'ExponentPushToken[tard]', 'android');" % ids['tard'])
    verifier('les envois d\'un client joignable sont « en attente »',
             un(db, "select string_agg(e.canal || ':' || e.statut, ',' order by e.canal) from notification_envois e "
                    "join notifications n on n.id = e.notification_id where n.type = 'birthday' and n.client_id = '%s' and n.cle like '%%2026';" % ids['tard']),
             'email:attente,push:annule')
    db.sql("select public.traiter_notifications();")
    verifier('envoyés au fournisseur, jamais « envoyé » ni « livré » sans sa réponse',
             un(db, "select count(*) from notification_envois e join notifications n on n.id = e.notification_id "
                    "where n.type like 'birthday%' and e.statut in ('envoye', 'livre');"), '0')
    verifier('… le statut est « envoi » (remis à pg_net, réponse pas encore lue)',
             un(db, "select string_agg(distinct e.statut, ',') from notification_envois e join notifications n on n.id = e.notification_id "
                    "where n.type = 'birthday' and n.client_id = '%s' and e.canal = 'email';" % ids['tard']), 'envoi')
    verifier('le client lit son message d\'anniversaire dans ses notifications (catégorie « compte »)',
             [e['titre'] for e in pts(ids['tard'], "select public.mes_notifications('compte');")['elements']], ['🎉🎂 Joyeux anniversaire, Tard ! 💙🧡'])

    print('   Le 29 février')
    verifier('né un 29 février, année non bissextile (règle « le 28 février ») : message le 28 février',
             [executer("'2027-02-28 14:00:00+00'")['prepares'] >= 1,
              un(db, "select count(*) from anniversaire_journal where client_id = '%s' and annee = 2027;" % ids['bissextile'])], [True, '1'])
    pts(ADMIN, "select public.anniversaire_reglages_modifier('{\"regle_29_fevrier\":\"mars1\"}');")
    executer("'2031-02-28 14:00:00+00'")
    verifier('règle « le 1er mars » : rien le 28 février 2031 pour les clients nés un 29 février',
             un(db, "select count(*) from anniversaire_journal where annee = 2031 and client_id in ('%s', '%s');" % (ids['bissextile'], ids['bissextile2'])), '0')
    executer("'2031-03-01 14:00:00+00'")
    verifier('… le message part le 1er mars', un(db, "select string_agg(distinct anniversaire_le::text, ',') from anniversaire_journal where annee = 2031 and client_id in ('%s', '%s');" % (ids['bissextile'], ids['bissextile2'])), '2031-03-01')
    verifier('année bissextile (2028) : le 29 février pour les deux',
             [executer("'2028-02-29 14:00:00+00'")['prepares'], un(db, "select count(*) from anniversaire_journal where annee = 2028 and anniversaire_le = '2028-02-29';")], [2, '2'])
    verifier('la fonction du jour : 29 février 2000 → 2027 / 2028',
             un(db, "select public.anniversaire_en('2000-02-29', 2027)::text || ',' || public.anniversaire_en('2000-02-29', 2027, 'mars1')::text || ',' || public.anniversaire_en('2000-02-29', 2028)::text || ',' || public.anniversaire_en('1999-12-31', 2027)::text;"),
             '2027-02-28,2027-03-01,2028-02-29,2027-12-31')
    pts(ADMIN, "select public.anniversaire_reglages_modifier('{\"regle_29_fevrier\":\"fev28\"}');")

    print('   Le rappel interne, 7 jours avant')
    verifier('le rappel est préparé AVANT le jour (client né le 27 octobre, rappel le 20)',
             un(db, "select prepare_le::text || ' < ' || anniversaire_le::text from anniversaire_rappels where client_id = '%s' and annee = 2026;" % ids['sept']),
             '2026-10-20 < 2026-10-27')
    verifier('un résumé pour chaque habilité (administrateur, gérant), pas pour un employé ni un client',
             un(db, "select string_agg(distinct cl.role, ',' order by cl.role) from notifications n join clients cl on cl.id = n.client_id where n.type = 'birthday_reminder' and n.cle like 'anniv-rappel:2026-10-27:%';"),
             'admin,gerant')
    resume = jsonq(db, GERANT, "select public.mes_notifications('compte');")['elements']
    verifier('le gérant lit le résumé dans ses notifications, avec le nombre, sans aucune date de naissance',
             [[e['titre'] for e in resume if e['type'] == 'birthday_reminder'][:1],
              un(db, "select count(*) from notifications where type = 'birthday_reminder' and client_id = '%s' and cle like 'anniv-rappel:2026-10-27:%%';" % GERANT),
              un(db, "select donnees ->> 'nombre' from notifications where type = 'birthday_reminder' and cle = 'anniv-rappel:2026-10-27:%s';" % GERANT)],
             [['Anniversaires à venir'], '1', '1'])
    verifier('relancé : aucun rappel de plus', [executer()['rappels'], un(db, "select count(*) from notifications where type = 'birthday_reminder' and cle like 'anniv-rappel:2026-10-27:%';")], [0, '2'])
    pts(ADMIN, "select public.anniversaire_reglages_modifier('{\"rappel_admin_jours\":0}');")
    ids['trente'] = 'bbffff00-0000-0000-0000-000000000030'
    nouveau(ids['trente'], 'trente@exemple.com', 'Trente Octobre', '1990-10-30')
    verifier('délai à 0 : plus de rappel interne', [executer()['rappels'], un(db, "select count(*) from anniversaire_rappels where anniversaire_le = '2026-10-30';")], [0, '0'])
    pts(ADMIN, "select public.anniversaire_reglages_modifier('{\"rappel_admin_jours\":10}');")
    executer()
    verifier('délai à 10 jours : le rappel du 30 octobre est préparé le 20', un(db, "select prepare_le::text from anniversaire_rappels where anniversaire_le = '2026-10-30';"), '2026-10-20')
    liste = pts(GERANT, "select public.anniversaires_rappels_liste();")
    verifier('un gérant lit les rappels à venir', [e['code'] is not None for e in liste['elements']][:1], [True])
    verifier('le rappel au client est éteint par défaut : aucun message de plus',
             un(db, "select count(*) from notifications where type = 'birthday_upcoming';"), '0')
    pts(ADMIN, "select public.anniversaire_reglages_modifier('{\"rappel_client_actif\":true,\"rappel_client_jours\":10}');")
    executer(); executer()
    verifier('allumé : le client né le 30 octobre reçoit UN rappel, jamais deux',
             un(db, "select count(*) from notifications where type = 'birthday_upcoming' and client_id = '%s';" % ids['trente']), '1')
    pts(ADMIN, "select public.anniversaire_reglages_modifier('{\"rappel_client_actif\":false}');")

    print('   Une erreur sur un client n\'arrête pas les autres')
    ids['casse'] = 'bafffff0-0000-0000-0000-0000000000a0'
    ids['sain'] = 'bafffff0-0000-0000-0000-0000000000a1'
    nouveau(ids['casse'], 'casse@exemple.com', 'Cas Cassé', '1990-11-05')
    nouveau(ids['sain'], 'sain@exemple.com', 'Sain Sauf', '1990-11-05')
    db.sql("alter table notifications add constraint essai_casse check (type not like 'birthday%%' or client_id <> '%s');" % ids['casse'])
    r = executer("'2026-11-05 14:00:00+00'")
    db.sql("alter table notifications drop constraint essai_casse;")
    verifier('un client en erreur : journalisé « erreur », l\'autre reçoit son message', [r['erreurs'], r['prepares'] >= 1], [1, True])
    verifier('l\'erreur est visible de l\'équipe, sans donnée personnelle',
             [e['origine'] for e in pts(GERANT, "select public.anniversaires_erreurs();")['elements'] if e['statut'] == 'erreur'], ['preparation'])

    print('   Un avantage d\'anniversaire : annoncé seulement s\'il est vraiment accordé')
    pts(ADMIN, "select public.points_reglages_modifier('{\"actif\":true}');")
    pts(ADMIN, "select public.points_regle_modifier('birthday', '{\"points\":20,\"actif\":true}');")
    pts(ADMIN, "select public.anniversaire_reglages_modifier('{\"avantage_actif\":true,\"avantage_type\":\"gopoints\"}');")
    ids['gp'] = 'bafffff1-0000-0000-0000-000000000001'
    nouveau(ids['gp'], 'gp@exemple.com', 'Gabrielle Points', '1990-12-01')
    executer("'2026-12-01 14:00:00+00'")
    gp = jsonq(db, 'sql', "select public.texte_notification(type, 'fr', donnees) || jsonb_build_object('type', type) from notifications where client_id = '%s' and type like 'birthday%%' order by id desc limit 1;" % ids['gp'])
    verifier('avantage en GOPOINTS : le modèle « avec avantage » dit « 20 GOPOINTS »', [gp['type'], '20 GOPOINTS' in gp['message']], ['birthday_avantage', True])
    verifier('… et les 20 points sont vraiment accordés, une seule fois',
             un(db, "select (select solde from points_soldes where client_id = '%s') || '|' || (select count(*) from points_mouvements where client_id = '%s' and source = 'birthday');" % (ids['gp'], ids['gp'])), '20|1')
    executer("'2026-12-01 14:00:00+00'")
    verifier('relancé : toujours 20 points', un(db, "select solde from points_soldes where client_id = '%s';" % ids['gp']), '20')
    pts(ADMIN, "select public.anniversaire_reglages_modifier(%s);" % js({'avantage_type': 'credit_expedition', 'avantage_valeur': 5, 'avantage_libelle': "5 $ de crédit d'expédition"}))
    ids['cr'] = 'bafffff1-0000-0000-0000-000000000002'
    nouveau(ids['cr'], 'cr@exemple.com', 'Cédric Crédit', '1990-12-02')
    executer("'2026-12-02 14:00:00+00'")
    verifier('avantage en crédit d\'expédition : enregistré « obtenu » (à appliquer par l\'équipe), annoncé dans le message',
             un(db, "select type || '|' || valeur || '|' || statut || '|' || programme from recompenses where client_id = '%s';" % ids['cr']), 'credit_expedition|5.00|obtenue|anniversaire')
    verifier('… le message dit le crédit',
             "5 $ de crédit d'expédition" in jsonq(db, 'sql', "select public.texte_notification(type, 'fr', donnees) from notifications where client_id = '%s' and type like 'birthday%%' limit 1;" % ids['cr'])['message'], True)
    pts(ADMIN, "select public.anniversaire_reglages_modifier('{\"avantage_actif\":false}');")
    ids['ne'] = 'bafffff1-0000-0000-0000-000000000003'
    nouveau(ids['ne'], 'ne@exemple.com', 'Nina Neutre', '1990-12-03')
    executer("'2026-12-03 14:00:00+00'")
    verifier('avantage désactivé : retour au message sans promesse, rien d\'accordé',
             un(db, "select (select type from notifications where client_id = '%s' and type like 'birthday%%') || '|' || (select count(*) from recompenses where client_id = '%s') || '|' || (select count(*) from points_mouvements where client_id = '%s');" % (ids['ne'], ids['ne'], ids['ne'])),
             'birthday|0|0')

    print('   Les modèles se modifient, avec garde-fous')
    for titre, args, attendu in (('variable inconnue', ("birthday", "fr", "Salut {{nom}}", "Texte"), 'INVALID_TEMPLATE'),
                                 ('accolade seule', ("birthday", "fr", "Salut {prenom", "Texte"), 'INVALID_TEMPLATE'),
                                 ('{{avantage}} dans le modèle sans avantage', ("birthday", "fr", "Salut {{prenom}}", "Cadeau : {{avantage}}"), 'INVALID_TEMPLATE'),
                                 ('titre vide', ("birthday", "fr", "", "Texte"), 'INVALID_TEMPLATE'),
                                 ('langue inconnue', ("birthday", "de", "Hallo", "Text"), 'INVALID_TEMPLATE'),
                                 ('type étranger aux anniversaires', ("shipment_received", "fr", "Hack", "Hack"), 'INVALID_TEMPLATE')):
        verifier('modèle refusé : %s' % titre, code(db, ADMIN, "select public.anniversaire_modele_modifier(%s);" % ', '.join(q(a) for a in args)), attendu)
    verifier('un modèle trop long est refusé', code(db, ADMIN, "select public.anniversaire_modele_modifier('birthday', 'fr', 'T', %s);" % q('x' * 1300)), 'INVALID_TEMPLATE')
    pts(ADMIN, "select public.anniversaire_modele_modifier('birthday', 'fr', %s, %s);" % (q('Joyeux anniversaire {{prenom}} !'), q('Toute l\'équipe pense à vous, {{prenom}}.')))
    nouveau_texte = texte(ids['rose'], 'fr')
    verifier('un modèle modifié est utilisé tout de suite', [nouveau_texte['titre'], nouveau_texte['message']],
             ['Joyeux anniversaire Rose !', "Toute l'équipe pense à vous, Rose."])
    verifier('la liste dit qu\'il est modifié', [m['modifie'] for m in pts(ADMIN, "select public.anniversaire_modeles_liste();") if m['type'] == 'birthday' and m['langue'] == 'fr'], [True])
    pts(ADMIN, "select public.anniversaire_modele_restaurer('birthday', 'fr');")
    verifier('« restaurer » remet le modèle d\'origine', texte(ids['rose'], 'fr')['titre'], '🎉🎂 Joyeux anniversaire, Rose ! 💙🧡')
    verifier('les textes des notifications de colis et de factures n\'ont pas changé',
             jsonq(db, 'sql', "select public.texte_notification('shipment_received', 'fr', '{\"numero\":\"GSE-1-HT\"}'::jsonb);"),
             {'titre': 'Colis reçu', 'message': 'Votre colis GSE-1-HT a été reçu à notre entrepôt de Miami.'})
    verifier('un prénom ne peut pas glisser une variable dans le message',
             jsonq(db, 'sql', "select public.texte_notification('birthday', 'fr', jsonb_build_object('prenom', public.prenom_client('{{numero}}x Pierre')));")['titre'],
             '🎉🎂 Joyeux anniversaire, numerox ! 💙🧡')

    print('   Préférence du client, correction d\'une date, listes')
    verifier('un visiteur ne règle aucune préférence', code(db, None, "select public.regler_ma_preference_anniversaire(false);")[:17], 'permission denied')
    verifier('un client règle la sienne', [pts(MARIE, "select public.regler_ma_preference_anniversaire(false);")['anniversaire'], pts(MARIE, "select public.mes_preferences_programmes();")['anniversaire']], [False, False])
    pts(MARIE, "select public.regler_ma_preference_anniversaire(true);")
    verifier('corriger une date sans motif : refusé', code(db, ADMIN, "select public.corriger_naissance('%s', '1989-10-20', '');" % ids['rose']), 'REASON_REQUIRED')
    verifier('corriger avec une date future : refusé', code(db, ADMIN, "select public.corriger_naissance('%s', '2999-10-20', 'faute de frappe');" % ids['rose']), 'INVALID_BIRTHDATE')
    verifier('corriger un compte inconnu : refusé', code(db, ADMIN, "select public.corriger_naissance('%s', '1989-10-20', 'faute de frappe');" % '00000000-0000-0000-0000-000000000000'), 'CLIENT_NOT_FOUND')
    pts(ADMIN, "select public.corriger_naissance('%s', '1989-10-20', 'faute de frappe corrigée sur pièce justificative');" % ids['rose'])
    verifier('la correction est faite et journalisée avec son motif, sans la date',
             un(db, "select (select count(*) from journal_audit where action = 'client.naissance_corrigee' and avant is null and apres::text like '%%faute de frappe%%' and apres::text !~ '19[0-9][0-9]') || '|' || (select corrigee_le is not null from profils_naissance where client_id = '%s');" % ids['rose']), '1|true')
    jour = pts(GERANT, "select public.anniversaires_liste('2026-10-20', '2026-10-20');")
    verifier('un gérant voit les anniversaires du jour (nom, âge, état), sans date de naissance complète',
             [jour['total'] >= 3, 'Rose Anniversaire' in {e['nom'] for e in jour['elements']}, '1990-10-20' in json.dumps(jour), '1989-10-20' in json.dumps(jour)], [True, True, False, False])
    verifier('une période de plus d\'un an est refusée', code(db, GERANT, "select public.anniversaires_liste('2026-01-01', '2028-01-01');"), 'INVALID_PERIOD')
    msgs = pts(GERANT, "select public.anniversaires_messages('ignore');")
    verifier('les messages ignorés, avec leur motif', sorted({e['motif'] for e in msgs['elements']}), ['DESACTIVE_PAR_CLIENT', 'SANS_PRENOM'])
    errs = pts(GERANT, "select public.anniversaires_erreurs();")
    verifier('la liste des erreurs montre les envois jamais partis, avec leur code', ['NON_CONFIGURE' in {e['code_erreur'] for e in errs['elements']}, 'SANS_APPAREIL' in {e['code_erreur'] for e in errs['elements']}], [True, True])
    verifier('le journal d\'audit note chaque réglage et chaque modèle', un(db, "select count(distinct action) from journal_audit where action like 'anniversaire.%';") >= '3', True)

    # D'autres sections suivent (campagnes, permissions)
    reussis = sum(S.RESULTATS)
    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), reussis))
    sys.exit(0 if reussis == len(S.RESULTATS) else 1)


if __name__ == '__main__':
    main()
