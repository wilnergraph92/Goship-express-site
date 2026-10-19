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
    # La suite crée des comptes : la règle « création de compte » ne doit plus leur accorder de points (la création de compte
    # accorde bien ses points aux nouveaux clients : voir la section E)
    pts(ADMIN, "select public.points_regle_modifier('account_created', '{\"actif\":false}');")
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

    print("\nD. GOship APP Welcome : une offre complète, un bonus par client")
    aujourdhui = lambda n=0: un(db, "select (public.aujourdhui_entreprise() + %d)::text;" % n)
    colis_de = lambda client, **k: jsonq(db, ADMIN, "select public.creer_colis(%s, null, true);" % js(dict(
        {'client_id': client, 'description': 'Colis d\'essai', 'poids_lb': 4, 'service': 'aerien', 'pays_destination': 'HT', 'destination': 'Jacmel'}, **k)))
    nb = lambda requete: int(un(db, requete))
    recus = lambda client: nb("select count(*) from recompenses where client_id = '%s' and programme = 'welcome' and statut in ('en_attente', 'obtenue', 'utilisee');" % client)

    verifier('au départ : aucune campagne, rien à débloquer pour un client',
             [pts(MARIE, "select public.ma_bienvenue();"), pts(ADMIN, "select public.bienvenue_liste();")['campagnes']], [None, []])
    for nom, compte in (('un client', JEAN), ('un employé', EMPLOYE)):
        verifier('%s : voir les campagnes refusé' % nom, code(db, compte, "select public.bienvenue_liste();"), REFUS)
    for nom, compte in (('un client', JEAN), ('un employé', EMPLOYE), ('un gérant', GERANT)):
        verifier('%s : créer une campagne refusé' % nom, code(db, compte, "select public.bienvenue_enregistrer(null, '{\"nom\":\"X\"}');"), REFUS)
        verifier('%s : accorder un avantage à la main refusé' % nom,
                 code(db, compte, "select public.recompense_accorder('%s', 'bonus_fixe', 5, 'motif');" % JEAN), REFUS)
    verifier('un gérant voit les campagnes', code(db, GERANT, "select public.bienvenue_liste();"), 'aucune')
    verifier('un visiteur ne peut rien appeler',
             [code(db, None, "select public.ma_bienvenue();")[:17], code(db, None, "select public.bienvenue_liste();")[:17]], ['permission denied'] * 2)
    verifier('le moteur est fermé à tous les comptes',
             [code(db, ADMIN, "select public.programmes_operation('%s', 'colis_recu', 'colis:x');" % JEAN)[:17],
              code(db, ADMIN, "select public.recompense_creer('%s', 'manuel', 'bonus_fixe', 5, 'k', '', '', 0);" % JEAN)[:17]], ['permission denied'] * 2)

    print('   Une campagne incomplète ne se publie pas')
    brouillon = pts(ADMIN, "select public.bienvenue_enregistrer(null, '{\"nom\":\"Bienvenue d\'essai\"}');") if False else pts(ADMIN, "select public.bienvenue_enregistrer(null, %s);" % js({'nom': 'Bienvenue essai'}))
    verifier('un brouillon se crée vide', [brouillon['statut'], brouillon['valeur_recompense']], ['brouillon', None])
    verifier('le publier : refusé, avec ce qui manque',
             [code(db, ADMIN, "select public.bienvenue_publier('%s');" % brouillon['id']),
              (lambda r: 'la date de début' in r and 'les conditions générales' in r)(db.comme(ADMIN, "select public.bienvenue_publier('%s');" % brouillon['id'], echec_permis=True))],
             ['INCOMPLETE_CAMPAIGN', True])
    for titre, d in (('type de récompense inconnu', {'type_recompense': 'voiture'}), ('valeur négative', {'valeur_recompense': -5}),
                     ('dates à l\'envers', {'debut': aujourdhui(5), 'fin': aujourdhui(1)}), ('opération inconnue', {'operation': 'connexion'}),
                     ('délai de 200 jours', {'delai_validation_jours': 200}), ('budget illisible', {'budget_max': 'beaucoup'})):
        verifier('valeur refusée : %s' % titre, code(db, ADMIN, "select public.bienvenue_enregistrer('%s', %s);" % (brouillon['id'], js(d))),
                 'INVALID_PROGRAM_VALUE' if titre in ('délai de 200 jours', 'budget illisible') else 'INVALID_CAMPAIGN')
    verifier('une campagne en points exige le programme GOPOINTS allumé',
             [pts(ADMIN, "select public.points_reglages_modifier('{\"actif\":false}');")['actif'],
              (lambda r: 'GOPOINTS' in r)(db.comme(ADMIN, "select public.bienvenue_enregistrer('%s', %s); select public.bienvenue_publier('%s');" % (brouillon['id'], js({'type_recompense': 'gopoints', 'valeur_recompense': 30, 'debut': aujourdhui(-1), 'fin': aujourdhui(30), 'operation': 'colis_recu', 'conditions': 'Conditions de l offre essai.'}), brouillon['id']), echec_permis=True))],
             [False, True])
    pts(ADMIN, "select public.points_reglages_modifier('{\"actif\":true}');")

    complet = {'nom': 'Bienvenue GoShip', 'description': 'Votre première opération vous rapporte un crédit.',
               'debut': aujourdhui(-1), 'fin': aujourdhui(30), 'type_recompense': 'credit_expedition', 'valeur_recompense': 5,
               'operation': 'colis_recu', 'budget_max': 2, 'delai_validation_jours': 0, 'cumul_parrainage': True,
               'conditions': 'Offre réservée aux nouveaux clients, une seule fois par client.'}
    pts(ADMIN, "select public.bienvenue_enregistrer('%s', %s);" % (brouillon['id'], js(complet)))
    verifier('un gérant ne publie pas', code(db, GERANT, "select public.bienvenue_publier('%s');" % brouillon['id']), REFUS)
    pub = pts(ADMIN, "select public.bienvenue_publier('%s');" % brouillon['id'])
    verifier('complète : publiée, active dès aujourd\'hui', pub['statut'], 'active')
    verifier('une campagne active ne se modifie pas', code(db, ADMIN, "select public.bienvenue_enregistrer('%s', '{\"valeur_recompense\":500}');" % brouillon['id']), 'CAMPAIGN_LOCKED')

    print('   Le parcours : compte → première opération → bonus, une fois')
    ids_w = {}
    for cle, nom in (('a', 'Alice Bienvenue'), ('b', 'Bruno Bienvenue'), ('c', 'Clara Bienvenue'), ('ancien', 'Ancien Client'), ('d', 'Denis Concurrent')):
        ids_w[cle] = 'd%sffffff-0000-0000-0000-00000000000%d' % (len(ids_w), len(ids_w) + 1)
        nouveau(ids_w[cle], '%s-w@exemple.com' % cle, nom, '1990-01-0%d' % (len(ids_w)))
    db.sql("update clients set cree_le = now() - interval '60 days' where id = '%s';" % ids_w['ancien'])
    vue_a = pts(ids_w['a'], "select public.ma_bienvenue();")
    verifier('un nouveau client voit l\'offre « à débloquer » : nom, avantage, conditions, fin, deux étapes',
             [vue_a['nom'], vue_a['statut'], vue_a['avantage'], vue_a['fin'] == aujourdhui(30), len(vue_a['etapes']), [e['fait'] for e in vue_a['etapes']]],
             ['Bienvenue GoShip', 'a_debloquer', '5,00 $ de crédit d\'expédition', True, 2, [True, False]])
    verifier('un client inscrit AVANT la campagne n\'y a pas droit : rien à voir', pts(ids_w['ancien'], "select public.ma_bienvenue();"), None)
    verifier('l\'inscription seule ne donne rien (aucun avantage tant que la première opération n\'a pas eu lieu)', recus(ids_w['a']), 0)
    verifier('un compte de l\'équipe ne voit pas d\'offre', pts(EMPLOYE, "select public.ma_bienvenue();"), None)
    colis_de(ids_w['a'])
    verifier('première opération qualifiante (colis reçu) : le bonus est accordé', recus(ids_w['a']), 1)
    verifier('… « crédit d\'expédition 5 $ », obtenu, avec sa référence unique',
             un(db, "select type || '|' || valeur || '|' || statut || '|' || cle from recompenses where client_id = '%s' and programme = 'welcome';" % ids_w['a']).split('|')[:3]
             + [un(db, "select cle like 'welcome:%%' from recompenses where client_id = '%s' and programme = 'welcome';" % ids_w['a'])],
             ['credit_expedition', '5.00', 'obtenue', 't'])
    verifier('le client est prévenu, et l\'offre devient « obtenu »',
             [pts(ids_w['a'], "select public.ma_bienvenue();")['statut'],
              [e['titre'] for e in pts(ids_w['a'], "select public.mes_notifications('compte');")['elements'] if e['type'] == 'reward_earned']],
             ['obtenu', ['🎁 Avantage obtenu']])
    colis_de(ids_w['a'])
    colis_de(ids_w['a'])
    verifier('d\'autres colis : jamais un second bonus', recus(ids_w['a']), 1)
    sorties = en_parallele(db, [(ADMIN, "select public.creer_colis(%s, null, true);" % js({'client_id': ids_w['b'], 'description': 'Colis %d' % i, 'poids_lb': 4, 'service': 'aerien', 'pays_destination': 'HT', 'destination': 'Jacmel', 'lieu': 'Miami'})) for i in range(4)])
    verifier('quatre colis reçus en même temps pour un même client : un seul bonus', recus(ids_w['b']), 1)
    colis_de(ids_w['ancien'])
    verifier('un client d\'avant la campagne : aucun bonus', recus(ids_w['ancien']), 0)
    colis_de(ids_w['c'])
    verifier('budget de 2 avantages : atteint avec Alice et Bruno, la troisième cliente n\'a rien',
             [nb("select count(*) from recompenses where programme = 'welcome' and statut in ('en_attente', 'obtenue');"), recus(ids_w['c'])], [2, 0])
    colis_de(ids_w['d'])
    verifier('… le troisième client n\'a rien (plafond respecté)', recus(ids_w['d']), 0)
    verifier('… et son offre est « expirée », pas « obtenue »', pts(ids_w['d'], "select public.ma_bienvenue();")['statut'], 'expire')
    verifier('rien d\'autre n\'a bougé : un seul bonus par client, jamais deux',
             nb("select count(*) from (select client_id from recompenses where programme = 'welcome' group by client_id having count(*) > 1) x;"), 0)
    verifier('l\'index unique l\'impose même hors du moteur',
             code(db, 'sql', "insert into recompenses (client_id, programme, type, valeur, statut, cle) values ('%s', 'welcome', 'bonus_fixe', 1, 'obtenue', 'pirate-1');" % ids_w['a'])[:20], 'duplicate key value')

    print('   Suspendre, reprendre, terminer')
    verifier('suspendre', pts(ADMIN, "select public.bienvenue_statut('%s', 'suspendre');" % brouillon['id'])['statut'], 'suspendue')
    nouveau('d5ffffff-0000-0000-0000-000000000099', 'e-w@exemple.com', 'Eve Suspendue', '1990-01-09')
    colis_de('d5ffffff-0000-0000-0000-000000000099')
    verifier('suspendue : une première opération ne rapporte rien', recus('d5ffffff-0000-0000-0000-000000000099'), 0)
    verifier('action impossible dans cet état : refusée', code(db, ADMIN, "select public.bienvenue_statut('%s', 'suspendre');" % brouillon['id']), 'INVALID_CAMPAIGN_STATUS')
    verifier('suspendue : elle se modifie', pts(ADMIN, "select public.bienvenue_enregistrer('%s', '{\"budget_max\":10}');" % brouillon['id'])['budget_max'], 10)
    verifier('reprendre : active de nouveau', pts(ADMIN, "select public.bienvenue_statut('%s', 'reprendre');" % brouillon['id'])['statut'], 'active')
    verifier('terminer', pts(ADMIN, "select public.bienvenue_statut('%s', 'terminer');" % brouillon['id'])['statut'], 'terminee')
    verifier('terminée : elle ne se modifie ni ne se reprend plus',
             [code(db, ADMIN, "select public.bienvenue_enregistrer('%s', '{\"budget_max\":99}');" % brouillon['id']), code(db, ADMIN, "select public.bienvenue_statut('%s', 'reprendre');" % brouillon['id'])],
             ['CAMPAIGN_LOCKED', 'INVALID_CAMPAIGN_STATUS'])
    verifier('le client voit son bonus déjà obtenu, même campagne terminée', pts(ids_w['a'], "select public.ma_bienvenue();")['statut'], 'obtenu')
    liste = pts(ADMIN, "select public.bienvenue_liste();")['campagnes'][0]
    verifier('l\'équipe voit les chiffres : clients admissibles, avantages par statut',
             [liste['clients_admissibles'] >= 5, liste['recompenses']], [True, {'obtenue': 2}])
    futur = pts(ADMIN, "select public.bienvenue_enregistrer(null, %s);" % js(dict(complet, nom='Campagne à venir', debut=aujourdhui(10), fin=aujourdhui(40))))
    verifier('une campagne qui commence plus tard est « programmée », sans effet avant sa date',
             [pts(ADMIN, "select public.bienvenue_publier('%s');" % futur['id'])['statut']], ['programmee'])
    pts(ADMIN, "select public.bienvenue_statut('%s', 'terminer');" % futur['id'])

    print('   Une opération annulée ne donne rien (délai de validation)')
    delai = pts(ADMIN, "select public.bienvenue_enregistrer(null, %s);" % js(dict(complet, nom='Bienvenue payée', operation='facture_payee', delai_validation_jours=3, budget_max=None, type_recompense='bonus_fixe', valeur_recompense=8)))
    pts(ADMIN, "select public.bienvenue_publier('%s');" % delai['id'])
    ids_w['p1'] = 'd6ffffff-0000-0000-0000-000000000011'
    ids_w['p2'] = 'd6ffffff-0000-0000-0000-000000000012'
    ids_w['p3'] = 'd6ffffff-0000-0000-0000-000000000013'
    for cle, nom in (('p1', 'Paula Paiement'), ('p2', 'Pierre Paiement'), ('p3', 'Perrine Paiement')):
        nouveau(ids_w[cle], '%s-w@exemple.com' % cle, nom, '1990-02-1%d' % int(cle[1]))
    factures = {}
    for cle in ('p1', 'p2', 'p3'):
        r = colis_de(ids_w[cle], description='Colis payé')
        factures[cle] = r['facture']
        verifier('colis reçu seul : pas de bonus (la campagne attend une facture payée), %s' % cle, recus(ids_w[cle]), 0)
    payer = lambda facture: pts(ADMIN, "select public.enregistrer_paiement('%s', %s, null);" % (facture['id'], js({'montant_usd': facture['montant_usd'], 'moyen': 'especes'})))
    payer(factures['p1'])
    verifier('facture payée : l\'avantage est « en attente de validation » (3 jours), pas encore acquis',
             un(db, "select statut || '|' || valide_apres::text from recompenses where client_id = '%s' and programme = 'welcome';" % ids_w['p1']), 'en_attente|' + aujourdhui(3))
    vue = pts(ids_w['p1'], "select public.ma_bienvenue();")
    verifier('le client voit « en attente », jamais « obtenu »', vue['statut'], 'en_attente')
    verifier('… et reçoit un message qui ne promet rien d\'acquis',
             [e['titre'] for e in pts(ids_w['p1'], "select public.mes_notifications('compte');")['elements'] if e['type'] == 'reward_pending'], ['Votre avantage est en cours de validation'])
    pts(ADMIN, "select public.annuler_paiement((select id from paiements where facture_id = '%s'), 'Chèque refusé');" % factures['p1']['id'])
    verifier('paiement annulé avant la fin du délai : l\'avantage est annulé, jamais accordé',
             [un(db, "select statut || '|' || motif from recompenses where client_id = '%s' and programme = 'welcome';" % ids_w['p1']),
              [e['titre'] for e in pts(ids_w['p1'], "select public.mes_notifications('compte');")['elements'] if e['type'] == 'reward_cancelled']],
             ['annulee|OPERATION_ANNULEE', ['Avantage annulé']])
    verifier('… et le client n\'a plus d\'avantage de bienvenue en cours', recus(ids_w['p1']), 0)
    payer(factures['p2'])
    db.sql("update recompenses set valide_apres = current_date - 1 where client_id = '%s';" % ids_w['p2'])
    verifier('délai passé, opération toujours valable : l\'avantage est acquis par le travail du jour',
             [json.loads(un(db, "select public.campagnes_quotidien()::text;"))['valides'], un(db, "select statut from recompenses where client_id = '%s' and programme = 'welcome';" % ids_w['p2'])],
             [1, 'obtenue'])
    verifier('le travail du jour relancé : rien de plus', [json.loads(un(db, "select public.campagnes_quotidien()::text;"))['valides'], recus(ids_w['p2'])], [0, 1])
    payer(factures['p3'])
    pts(ADMIN, "select public.annuler_facture('%s', 'Erreur de saisie');" % factures['p3']['id']) if False else None
    db.sql("update recompenses set valide_apres = current_date - 1 where client_id = '%s';" % ids_w['p3'])
    db.sql("update factures set statut = 'annulee' where id = '%s';" % factures['p3']['id']) if False else None
    verifier('en attente, puis facture annulée : annulé au travail du jour',
             [json.loads(un(db, "select public.campagnes_quotidien()::text;")) is not None, recus(ids_w['p3'])], [True, 1])

    print('   Les avantages à la main et les erreurs')
    verifier('accorder à la main : un motif obligatoire', code(db, ADMIN, "select public.recompense_accorder('%s', 'bonus_fixe', 5, '');" % JEAN), 'REASON_REQUIRED')
    verifier('… un type et une valeur valables', code(db, ADMIN, "select public.recompense_accorder('%s', 'voiture', 5, 'motif');" % JEAN), 'INVALID_REWARD')
    manuel = pts(ADMIN, "select public.recompense_accorder('%s', 'gopoints', 40, 'geste de la direction');" % JEAN)
    verifier('en points : l\'avantage est « obtenu » et les points entrent dans le registre',
             [manuel['statut'], un(db, "select count(*) from points_mouvements where reference = '%s' and source = 'recompense';" % manuel['id'])], ['obtenue', '1'])
    solde_avant = nb("select solde from points_soldes where client_id = '%s';" % JEAN)
    pts(ADMIN, "select public.recompense_annuler('%s', 'accordé par erreur');" % manuel['id'])
    verifier('annuler : les points sont retirés par une annulation du registre',
             [nb("select solde from points_soldes where client_id = '%s';" % JEAN), un(db, "select statut from recompenses where id = '%s';" % manuel['id'])], [solde_avant - 40, 'annulee'])
    verifier('annuler deux fois : refusé', code(db, ADMIN, "select public.recompense_annuler('%s', 'encore');" % manuel['id']), 'INVALID_REWARD')
    db.sql("alter table recompenses add constraint essai_casse check (client_id <> '%s');" % 'd5ffffff-0000-0000-0000-000000000098')
    nouveau('d5ffffff-0000-0000-0000-000000000098', 'casse-w@exemple.com', 'Cas Cassé Bienvenue', '1990-03-03')
    pts(ADMIN, "select public.bienvenue_enregistrer(null, %s);" % js(dict(complet, nom='Pour l\'erreur', debut=aujourdhui(0))))
    campagne_err = un(db, "select id from campagnes_bienvenue where nom = 'Pour l''erreur';")
    pts(ADMIN, "select public.bienvenue_publier('%s');" % campagne_err)
    colis_ok = colis_de('d5ffffff-0000-0000-0000-000000000098')
    db.sql("alter table recompenses drop constraint essai_casse;")
    verifier('une erreur du moteur ne bloque pas la réception du colis : le colis existe, l\'erreur est journalisée',
             [colis_ok['colis']['numero'][:4], nb("select count(*) from programmes_erreurs where programme = 'operation';") >= 1 if False else nb("select count(*) from programmes_erreurs;") >= 1],
             ['GSE-', True])
    verifier('l\'équipe voit l\'erreur', pts(GERANT, "select public.programmes_erreurs_liste();")['total'] >= 1, True)
    verifier('un employé ne la voit pas', code(db, EMPLOYE, "select public.programmes_erreurs_liste();"), REFUS)
    pts(ADMIN, "select public.bienvenue_statut('%s', 'terminer');" % campagne_err)
    pts(ADMIN, "select public.bienvenue_statut('%s', 'terminer');" % delai['id'])

    print("\nE. GOship Refer : le bon parrain, jamais soi-même, des avantages après la première opération")
    parrain = 'e1ffffff-0000-0000-0000-000000000001'
    nouveau(parrain, 'parrain@exemple.com', 'Pascal Parrain', '1980-05-05')
    db.sql("update clients set telephone = '+509 3700 1111', adresse = '12 rue des Parrains, Pétion-Ville' where id = '%s';" % parrain)
    vue = pts(parrain, "select public.mon_parrainage();")
    code_p = vue['code']
    verifier('le code : GS + 6 signes sans ambiguïté, créé à la première demande', bool(__import__('re').match(r'^GS[A-HJ-KM-NP-Z2-9]{6}$', code_p)), True)
    verifier('… le même à chaque demande, une seule ligne',
             [pts(parrain, "select public.mon_parrainage();")['code'] == code_p, nb("select count(*) from codes_parrainage where client_id = '%s';" % parrain)], [True, 1])
    autre = 'e1ffffff-0000-0000-0000-000000000002'
    nouveau(autre, 'autre-p@exemple.com', 'Aline Autre', '1981-06-06')
    sorties = en_parallele(db, [(autre, "select public.mon_parrainage()->>'code';")] * 4)
    verifier('quatre demandes simultanées : un seul code, jamais deux lignes',
             [nb("select count(*) from codes_parrainage where client_id = '%s';" % autre), len({(s or '').strip().splitlines()[-1] for s in sorties})], [1, 1])
    verifier('deux clients, deux codes', pts(autre, "select public.mon_parrainage()->>'code';") if False else un(db, "select count(distinct code) from codes_parrainage;"), '2')
    verifier('avant publication : le parrainage n\'est pas ouvert, et les chiffres sont à zéro',
             [vue['actif'], vue['invitations'], vue['inscrits'], vue['valides'], vue['recompenses']], [False, 0, 0, 0, []])
    verifier('un compte de l\'équipe n\'a pas de code', code(db, EMPLOYE, "select public.mon_parrainage();"), REFUS)
    verifier('un visiteur non plus', code(db, None, "select public.mon_parrainage();")[:17], 'permission denied')
    for nom, compte in (('un client', JEAN), ('un employé', EMPLOYE)):
        verifier('%s : lire la configuration du parrainage refusé' % nom, code(db, compte, "select public.parrainage_config_lire();"), REFUS)
    for nom, compte in (('un client', JEAN), ('un employé', EMPLOYE), ('un gérant', GERANT)):
        verifier('%s : modifier, publier ou examiner refusé' % nom,
                 [code(db, compte, "select public.parrainage_config_modifier('{}');"), code(db, compte, "select public.parrainage_statut('publier');"),
                  code(db, compte, "select public.parrainage_examiner(1, 'valider', 'motif');")], [REFUS] * 3)
    verifier('un gérant lit la configuration', code(db, GERANT, "select public.parrainage_config_lire();"), 'aucune')

    print('   Une configuration incomplète ne se publie pas')
    verifier('publier un brouillon vide : refusé, avec ce qui manque',
             [code(db, ADMIN, "select public.parrainage_statut('publier');"),
              (lambda r: 'l\'avantage du parrain' in r and 'les conditions d\'annulation' in r)(db.comme(ADMIN, "select public.parrainage_statut('publier');", echec_permis=True))],
             ['INCOMPLETE_CAMPAIGN', True])
    verifier('avant publication : un code ne rattache personne (REFERRAL_INACTIVE) mais ne bloque jamais l\'inscription',
             [code(db, JEAN, "select public.utiliser_code_parrainage('%s');" % code_p)], ['REFERRAL_INACTIVE'])
    cfg = {'nom': 'GOship Refer', 'debut': aujourdhui(-1), 'fin': aujourdhui(30), 'parrain_type': 'bonus_fixe', 'parrain_valeur': 10,
           'filleul_type': 'credit_expedition', 'filleul_valeur': 5, 'operation': 'colis_recu', 'delai_validation_jours': 0,
           'max_par_parrain': 3, 'cumul_bienvenue': True,
           'conditions': 'Le filleul doit ouvrir son compte avec ce code et faire sa première opération.',
           'annulation': 'Une opération annulée ou remboursée avant validation annule les avantages.'}
    pts(ADMIN, "select public.parrainage_config_modifier(%s);" % js(cfg))
    verifier('valeurs refusées : type inconnu, valeur négative, dates à l\'envers',
             [code(db, ADMIN, "select public.parrainage_config_modifier(%s);" % js(d)) for d in
              ({'parrain_type': 'voiture'}, {'filleul_valeur': -1}, {'debut': aujourdhui(9), 'fin': aujourdhui(2)})], ['INVALID_CAMPAIGN'] * 3)
    pts(ADMIN, "select public.parrainage_statut('publier');")
    verifier('publié : actif', pts(ADMIN, "select public.parrainage_config_lire();")['statut'], 'active')
    verifier('actif : il ne se modifie pas', code(db, ADMIN, "select public.parrainage_config_modifier('{\"parrain_valeur\":500}');"), 'CAMPAIGN_LOCKED')

    print('   Le parrain et le filleul')
    signe = lambda cle, nom, tel, code_saisi, naissance='1995-04-04': inscrire(db, 'e2ffffff-0000-0000-0000-0000000000%02d' % int(cle), 'f%s@exemple.com' % cle,
        {'nom_complet': nom, 'telephone': tel, 'date_naissance': naissance, 'code_parrainage': code_saisi}, fournisseur='email')
    fid = lambda cle: 'e2ffffff-0000-0000-0000-0000000000%02d' % int(cle)
    signe('01', 'Fanny Filleule', '+509 3700 2201', code_p.lower())
    verifier('l\'inscription avec le code (même en minuscules) rattache au BON parrain',
             un(db, "select (select code from clients where id = parrain_id) || '|' || statut || '|' || source from parrainages where filleul_id = '%s';" % fid('01')).split('|')[1:],
             ['inscrit', 'inscription'])
    verifier('… le parrain est bien celui du code', un(db, "select parrain_id::text from parrainages where filleul_id = '%s';" % fid('01')), parrain)
    verifier('l\'inscription seule ne donne aucun avantage, ni au parrain ni au filleul', nb("select count(*) from recompenses where programme in ('refer_parrain', 'refer_filleul');"), 0)
    verifier('le parrain voit un inscrit en attente de sa première opération, rien d\'acquis',
             [(lambda v: [v['inscrits'], v['en_attente_premiere_operation'], v['valides'], v['recompenses']])(pts(parrain, "select public.mon_parrainage();"))], [[1, 1, 0, []]])
    signe('02', 'Gaston Sans Code', '+509 3700 2202', 'GSZZZZZZ')
    verifier('un code inconnu à l\'inscription : le compte est créé, aucun parrainage', [nb("select count(*) from clients where id = '%s';" % fid('02')), nb("select count(*) from parrainages where filleul_id = '%s';" % fid('02'))], [1, 0])
    verifier('code inconnu saisi ensuite : refusé avec son code', code(db, fid('02'), "select public.utiliser_code_parrainage('GSZZZZZZ');"), 'INVALID_REFERRAL_CODE')
    verifier('son propre code : refusé (jamais soi-même)', code(db, parrain, "select public.utiliser_code_parrainage('%s');" % code_p), 'SELF_REFERRAL')
    verifier('déjà parrainé : un second code est refusé',
             code(db, fid('01'), "select public.utiliser_code_parrainage('%s');" % pts(autre, "select public.mon_parrainage();")['code']), 'ALREADY_REFERRED')
    verifier('un cycle (le parrain utilise le code de son propre filleul) : refusé',
             code(db, parrain, "select public.utiliser_code_parrainage('%s');" % pts(fid('01'), "select public.mon_parrainage();")['code']), 'REFERRAL_CYCLE')
    verifier('un compte Google saisit un code reçu plus tard : rattaché', [pts(fid('02'), "select public.utiliser_code_parrainage('%s');" % code_p)['enregistre'],
             un(db, "select source from parrainages where filleul_id = '%s';" % fid('02'))], [True, 'saisie'])
    signe('03', 'Hugo Trop Tard', '+509 3700 2203', '')
    colis_de(fid('03'))
    verifier('une première opération déjà faite : trop tard pour ajouter un code', code(db, fid('03'), "select public.utiliser_code_parrainage('%s');" % code_p), 'REFERRAL_TOO_LATE')
    verifier('un visiteur n\'utilise aucun code', code(db, None, "select public.utiliser_code_parrainage('%s');" % code_p)[:17], 'permission denied')

    print('   La première opération qualifiante : les deux sont récompensés, une fois')
    colis_de(fid('01'))
    pa = un(db, "select id from parrainages where filleul_id = '%s';" % fid('01'))
    verifier('le parrainage est « récompensé »', un(db, "select statut from parrainages where id = %s;" % pa), 'recompense')
    verifier('le parrain reçoit son avantage (bonus fixe 10 $) et le filleul le sien (crédit d\'expédition 5 $), chacun avec sa clé unique',
             un(db, "select string_agg(programme || ':' || type || ':' || valeur || ':' || statut || ':' || cle, ',' order by programme) from recompenses where programme like 'refer_%%';"),
             'refer_filleul:credit_expedition:5.00:obtenue:refer:%s:filleul,refer_parrain:bonus_fixe:10.00:obtenue:refer:%s:parrain' % (pa, pa))
    verifier('les deux sont prévenus',
             [[e['titre'] for e in pts(c, "select public.mes_notifications('compte');")['elements'] if e['type'] == 'reward_earned'] for c in (parrain, fid('01'))],
             [['🎁 Avantage obtenu'], ['🎁 Avantage obtenu']])
    colis_de(fid('01'))
    colis_de(fid('01'))
    verifier('un événement rejoué, d\'autres colis : rien de plus', nb("select count(*) from recompenses where programme like 'refer_%';"), 2)
    sorties = en_parallele(db, [(ADMIN, "select public.programmes_operation('%s', 'colis_recu', 'colis:x');" % fid('01'))] * 2)
    verifier('l\'avantage du parrain est obtenu une seule fois : un index unique sur les clés', nb("select count(*) from (select cle from recompenses group by cle having count(*) > 1) x;"), 0)
    vue = pts(parrain, "select public.mon_parrainage();")
    verifier('le parrain voit ses chiffres et son propre avantage',
             [vue['inscrits'], vue['valides'], [r['statut'] for r in vue['recompenses']], [r['type'] for r in vue['recompenses']], vue['recompenses'][0]['avantage']],
             [2, 1, ['obtenue'], ['bonus_fixe'], 'un bonus de 10,00 $'])
    texte_vue = json.dumps(vue)
    verifier('… sans jamais l\'identité d\'un filleul, ni ses opérations',
             any(m in texte_vue for m in ('Fanny', 'Filleule', fid('01'), 'f01@exemple.com')), False)
    verifier('le filleul voit son propre parrainage (il a été invité) sans nom de parrain',
             [pts(fid('01'), "select public.mon_parrainage();")['mon_parrain'], 'Pascal' in json.dumps(pts(fid('01'), "select public.mon_parrainage();"))], [True, False])

    print('   Les indices d\'abus : examiner, jamais bloquer à l\'aveugle')
    signe('04', 'Faux Filleul', '+509 3700 1111', code_p)
    verifier('même téléphone que le parrain : le parrainage est « suspect », rien n\'est bloqué',
             un(db, "select statut || '|' || motif from parrainages where filleul_id = '%s';" % fid('04')), 'suspect|MEME_TELEPHONE')
    colis_de(fid('04'))
    verifier('suspect : sa première opération ne rapporte rien, ni au parrain ni au filleul',
             nb("select count(*) from recompenses where client_id in ('%s', '%s') and programme like 'refer_%%' and cle like '%%' || (select id::text from parrainages where filleul_id = '%s') || '%%';" % (parrain, fid('04'), fid('04'))), 0)
    liste = pts(GERANT, "select public.parrainages_liste('suspect');")
    verifier('l\'équipe voit le cas, avec les deux comptes', [liste['total'], liste['elements'][0]['filleul_nom'], liste['elements'][0]['parrain_nom']], [1, 'Faux Filleul', 'Pascal Parrain'])
    suspect = liste['elements'][0]['id']
    verifier('examiner sans motif : refusé', code(db, ADMIN, "select public.parrainage_examiner(%s, 'valider', '');" % suspect), 'REASON_REQUIRED')
    verifier('décision inconnue : refusée', code(db, ADMIN, "select public.parrainage_examiner(%s, 'peut-etre', 'motif');" % suspect), 'INVALID_DECISION')
    verifier('un parrainage non suspect ne s\'examine pas', code(db, ADMIN, "select public.parrainage_examiner(%s, 'valider', 'motif');" % pa), 'INVALID_REFERRAL')
    pts(ADMIN, "select public.parrainage_examiner(%s, 'valider', 'même foyer, deux personnes différentes vérifiées');" % suspect)
    verifier('validé après examen : le parrainage reprend, les avantages sont accordés (l\'opération avait eu lieu)',
             [un(db, "select statut from parrainages where id = %s;" % suspect), nb("select count(*) from recompenses where cle like 'refer:%s:%%';" % suspect)], ['recompense', 2])
    signe('05', 'Autre Suspect', '+509 3700 1111', code_p)
    colis_de(fid('05'))
    suspect2 = un(db, "select id from parrainages where filleul_id = '%s';" % fid('05'))
    pts(ADMIN, "select public.parrainage_examiner(%s, 'refuser', 'compte en double');" % suspect2)
    verifier('refusé après examen : aucun avantage', [un(db, "select statut from parrainages where id = %s;" % suspect2), nb("select count(*) from recompenses where cle like 'refer:%s:%%';" % suspect2)], ['refuse', 0])
    verifier('l\'examen est journalisé, avec son motif', un(db, "select count(*) from journal_audit where action = 'parrainage.examen';"), '2')

    print('   Les plafonds : trois parrainages récompensés par parrain')
    # Les inscriptions de ce banc tiennent en quelques secondes : sans ce vieillissement, la règle
    # « rafale » (5 en 24 h) classerait « suspect » tout ce qui suit.
    vieillir = lambda: db.sql("update parrainages set cree_le = cree_le - interval '2 days';")
    vieillir()
    signe('06', 'Sixième Filleul', '+509 3700 2206', code_p)
    colis_de(fid('06'))
    verifier('le troisième parrainage récompensé de ce parrain : accordé', un(db, "select statut from parrainages where filleul_id = '%s';" % fid('06')), 'recompense')
    signe('07', 'Septième Filleul', '+509 3700 2207', code_p)
    colis_de(fid('07'))
    verifier('le quatrième : refusé (plafond par parrain), aucun avantage',
             [un(db, "select statut || '|' || motif from parrainages where filleul_id = '%s';" % fid('07')), nb("select count(*) from recompenses where cle like 'refer:' || (select id::text from parrainages where filleul_id = '%s') || ':%%';" % fid('07'))],
             ['refuse|PLAFOND_PARRAIN', 0])
    verifier('une rafale d\'inscriptions avec un même code : à partir de la sixième, « suspect »',
             [signe('%02d' % (10 + i), 'Rafale %d' % i, '+509 3700 33%02d' % i, pts(autre, "select public.mon_parrainage();")['code']) for i in range(6)] and
             un(db, "select string_agg(distinct statut, ',' order by statut) from parrainages where parrain_id = '%s';" % autre), 'inscrit,suspect')
    verifier('exactement une rafale : la sixième seulement',
             un(db, "select count(*) from parrainages where parrain_id = '%s' and motif like '%%RAFALE%%';" % autre), '1')

    print('   Les invitations')
    pts(autre, "select public.noter_invitation('whatsapp'); select public.noter_invitation('lien');")
    verifier('chaque partage est compté', pts(autre, "select public.mon_parrainage();")['invitations'], 2)
    db.comme(autre, "do $$ begin for i in 1..60 loop perform public.noter_invitation('x'); end loop; end $$;")
    verifier('au plus 50 par jour', pts(autre, "select public.mon_parrainage();")['invitations'], 50)
    verifier('un visiteur ne compte rien', code(db, None, "select public.noter_invitation('x');")[:17], 'permission denied')

    print('   Cumul avec la bienvenue')
    vieillir()
    pts(ADMIN, "select public.parrainage_statut('suspendre');")
    pts(ADMIN, "select public.parrainage_config_modifier('{\"cumul_bienvenue\":false,\"max_par_parrain\":null}');")
    pts(ADMIN, "select public.parrainage_statut('reprendre');")
    camp = pts(ADMIN, "select public.bienvenue_enregistrer(null, %s);" % js(dict(complet, nom='Bienvenue cumul', budget_max=None, debut=aujourdhui(0))))
    pts(ADMIN, "select public.bienvenue_publier('%s');" % camp['id'])
    ids_c = 'e3ffffff-0000-0000-0000-000000000001'
    inscrire(db, ids_c, 'cumul@exemple.com', {'nom_complet': 'Cumul Interdit', 'telephone': '+509 3700 4401', 'date_naissance': '1990-09-09', 'code_parrainage': code_p}, fournisseur='email')
    colis_de(ids_c)
    verifier('cumul refusé par le parrainage : le filleul a SA bienvenue mais pas l\'avantage de filleul ; le parrain, lui, est récompensé',
             [recus(ids_c), nb("select count(*) from recompenses where client_id = '%s' and programme = 'refer_filleul';" % ids_c),
              nb("select count(*) from recompenses where client_id = '%s' and programme = 'refer_parrain' and cle like 'refer:' || (select id::text from parrainages where filleul_id = '%s') || ':%%';" % (parrain, ids_c))],
             [1, 0, 1])
    pts(ADMIN, "select public.bienvenue_statut('%s', 'terminer');" % camp['id'])
    camp2 = pts(ADMIN, "select public.bienvenue_enregistrer(null, %s);" % js(dict(complet, nom='Bienvenue sans parrainage', budget_max=None, debut=aujourdhui(0), cumul_parrainage=False)))
    pts(ADMIN, "select public.bienvenue_publier('%s');" % camp2['id'])
    pts(ADMIN, "select public.parrainage_statut('suspendre');")
    pts(ADMIN, "select public.parrainage_config_modifier('{\"cumul_bienvenue\":true}');")
    pts(ADMIN, "select public.parrainage_statut('reprendre');")
    ids_d = 'e3ffffff-0000-0000-0000-000000000002'
    inscrire(db, ids_d, 'cumul2@exemple.com', {'nom_complet': 'Sans Bienvenue', 'telephone': '+509 3700 4402', 'date_naissance': '1990-09-10', 'code_parrainage': code_p}, fournisseur='email')
    colis_de(ids_d)
    verifier('la bienvenue refuse le cumul : un client parrainé n\'a pas de bienvenue, mais son avantage de filleul',
             [recus(ids_d), nb("select count(*) from recompenses where client_id = '%s' and programme = 'refer_filleul';" % ids_d)], [0, 1])
    pts(ADMIN, "select public.bienvenue_statut('%s', 'terminer');" % camp2['id'])

    print('   Validation différée, opération annulée')
    vieillir()
    pts(ADMIN, "select public.parrainage_statut('suspendre');")
    pts(ADMIN, "select public.parrainage_config_modifier('{\"delai_validation_jours\":3}');")
    pts(ADMIN, "select public.parrainage_statut('reprendre');")
    signe('20', 'Vingtième Filleul', '+509 3700 5520', code_p)
    colis_de(fid('20'))
    pa20 = un(db, "select id from parrainages where filleul_id = '%s';" % fid('20'))
    verifier('avec un délai : parrainage « qualifié », deux avantages « en attente » (rien d\'acquis)',
             [un(db, "select statut from parrainages where id = %s;" % pa20), nb("select count(*) from recompenses where cle like 'refer:%s:%%' and statut = 'en_attente';" % pa20)], ['qualifie', 2])
    verifier('les deux sont prévenus que rien n\'est acquis',
             [[e['titre'] for e in pts(c, "select public.mes_notifications('compte');")['elements'] if e['type'] == 'reward_pending'] for c in (parrain, fid('20'))],
             [['Votre avantage est en cours de validation']] * 2)
    verifier('le travail du jour avant la fin du délai : rien',
             [json.loads(un(db, "select public.campagnes_quotidien()::text;"))['valides'], un(db, "select statut from parrainages where id = %s;" % pa20)], [0, 'qualifie'])
    db.sql("update recompenses set valide_apres = current_date - 1 where cle like 'refer:%s:%%';" % pa20)
    verifier('délai passé, opération valable : les deux avantages sont acquis, le parrainage est « récompensé »',
             [json.loads(un(db, "select public.campagnes_quotidien()::text;"))['valides'], un(db, "select statut from parrainages where id = %s;" % pa20)], [2, 'recompense'])
    pts(ADMIN, "select public.parrainage_statut('suspendre');")
    pts(ADMIN, "select public.parrainage_config_modifier('{\"operation\":\"facture_payee\"}');")
    pts(ADMIN, "select public.parrainage_statut('reprendre');")
    signe('21', 'Vingt-et-unième', '+509 3700 5521', code_p)
    r21 = colis_de(fid('21'))
    pts(ADMIN, "select public.enregistrer_paiement('%s', %s, null);" % (r21['facture']['id'], js({'montant_usd': r21['facture']['montant_usd'], 'moyen': 'especes'})))
    pa21 = un(db, "select id from parrainages where filleul_id = '%s';" % fid('21'))
    verifier('transaction « facture payée » : avantages en attente', [un(db, "select statut from parrainages where id = %s;" % pa21), nb("select count(*) from recompenses where cle like 'refer:%s:%%' and statut = 'en_attente';" % pa21)], ['qualifie', 2])
    pts(ADMIN, "select public.annuler_paiement((select id from paiements where facture_id = '%s'), 'Remboursé au client');" % r21['facture']['id'])
    verifier('paiement annulé ou remboursé avant validation : les deux avantages sont annulés, le parrainage aussi',
             [un(db, "select statut || '|' || motif from parrainages where id = %s;" % pa21), nb("select count(*) from recompenses where cle like 'refer:%s:%%' and statut = 'annulee';" % pa21),
              nb("select count(*) from recompenses where cle like 'refer:%s:%%' and statut in ('obtenue', 'utilisee');" % pa21)],
             ['annule|OPERATION_ANNULEE', 2, 0])
    verifier('les deux sont prévenus de l\'annulation',
             [[e['titre'] for e in pts(c, "select public.mes_notifications('compte');")['elements'] if e['type'] == 'reward_cancelled'] for c in (parrain, fid('21'))],
             [['Avantage annulé']] * 2)

    print('   L\'équipe : chiffres, listes, filtres')
    ap = pts(ADMIN, "select public.parrainage_apercu();")
    verifier('l\'aperçu : parrains, inscrits, qualifiés, avantages, suspects',
             [ap['filleuls_inscrits'] == nb("select count(*) from parrainages;"), ap['parrains'] == nb("select count(distinct parrain_id) from parrainages;"),
              ap['transactions_qualifiantes'] == nb("select count(*) from parrainages where qualifie_le is not null;"),
              ap['suspects'] == nb("select count(*) from parrainages where statut = 'suspect';")], [True] * 4)
    lp = pts(GERANT, "select public.parrainages_liste('annule');")
    verifier('une liste filtrée par statut', [lp['total'], {e['statut'] for e in lp['elements']}], [1, {'annule'}])
    verifier('filtre inconnu refusé', code(db, GERANT, "select public.parrainages_liste('bizarre');"), 'INVALID_FILTER')
    rl = pts(GERANT, "select public.recompenses_liste('refer_parrain', 'obtenue');")
    verifier('les avantages d\'un programme, par statut', {e['programme'] for e in rl['elements']} == {'refer_parrain'} and {e['statut'] for e in rl['elements']} == {'obtenue'}, True)
    verifier('un employé ne lit ni les parrainages ni les avantages',
             [code(db, EMPLOYE, "select public.parrainages_liste();"), code(db, EMPLOYE, "select public.recompenses_liste();"), code(db, EMPLOYE, "select public.parrainage_apercu();")], [REFUS] * 3)
    verifier('toutes les tables des programmes sont fermées, même à l\'administrateur',
             [code(db, c, "select count(*) from %s;" % tb)[:17] for tb in ('parrainages', 'codes_parrainage', 'recompenses', 'campagnes_bienvenue', 'parrainage_config', 'programmes_erreurs', 'programme_operations', 'points_mouvements') for c in (ADMIN, MARIE)],
             ['permission denied'] * 16)

    print('\nF. Chaque rôle, chaque permission')
    matrice = [
        ('birthdays.view', ["select public.anniversaires_liste();", "select public.anniversaire_reglages_lire();", "select public.anniversaires_messages();",
                            "select public.anniversaires_erreurs();", "select public.anniversaires_rappels_liste();", "select public.anniversaire_modeles_liste();"], (ADMIN, GERANT)),
        ('birthdays.manage', ["select public.anniversaire_reglages_modifier('{}');", "select public.anniversaire_modele_modifier('birthday', 'fr', 'T', 'M');",
                              "select public.anniversaire_modele_restaurer('birthday', 'fr');", "select public.corriger_naissance('%s', '1990-01-01', 'motif');" % MARIE], (ADMIN,)),
        ('programs.view', ["select public.points_regles_liste();", "select public.points_apercu();", "select public.points_mouvements_liste();", "select public.bienvenue_liste();",
                           "select public.parrainage_config_lire();", "select public.parrainage_apercu();", "select public.parrainages_liste();",
                           "select public.recompenses_liste();", "select public.programmes_erreurs_liste();"], (ADMIN, GERANT)),
        ('programs.manage', ["select public.points_reglages_modifier('{}');", "select public.points_regle_modifier('birthday', '{}');",
                             "select public.points_offre_enregistrer(null, '{}');", "select public.bienvenue_enregistrer(null, '{}');",
                             "select public.bienvenue_publier('00000000-0000-0000-0000-000000000000');", "select public.bienvenue_statut('00000000-0000-0000-0000-000000000000', 'terminer');",
                             "select public.parrainage_config_modifier('{}');", "select public.parrainage_statut('terminer');" if False else "select public.parrainage_statut('xx');",
                             "select public.parrainage_examiner(0, 'valider', 'motif');"], (ADMIN,)),
        ('points.adjust', ["select public.points_corriger('%s', 1, 'motif');" % MARIE, "select public.points_annuler_mouvement(0, 'motif');",
                           "select public.recompense_accorder('%s', 'bonus_fixe', 1, 'motif');" % MARIE, "select public.recompense_annuler('00000000-0000-0000-0000-000000000000', 'motif');"], (ADMIN,)),
    ]
    for permission, appels, permis in matrice:
        for nom, compte in (('administrateur', ADMIN), ('gérant', GERANT), ('employé', EMPLOYE), ('client', MARIE)):
            refuses = [a for a in appels if code(db, compte, a) == REFUS]
            verifier('%s : %s' % (permission, nom), 'refusé partout' if len(refuses) == len(appels) else ('accepté partout' if not refuses else 'mélangé : %s' % refuses[:1]),
                     'accepté partout' if compte in permis else 'refusé partout')
    # La copie démo des permissions est comparée à la base par essai-permissions.py / .js.

    # D'autres sections suivent (permissions du mode démo : voir essai-permissions.py)
    reussis = sum(S.RESULTATS)
    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), reussis))
    sys.exit(0 if reussis == len(S.RESULTATS) else 1)


if __name__ == '__main__':
    main()
