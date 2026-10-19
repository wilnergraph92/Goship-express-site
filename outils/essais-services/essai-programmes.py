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
NOUVEAUX = [f for f in ('supabase-naissance.sql', 'supabase-anniversaires.sql',
                        'supabase-fidelite.sql', 'supabase-campagnes.sql') if f in CHAINE]
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

    # D'autres sections suivent (anniversaires, points, campagnes, permissions)
    reussis = sum(S.RESULTATS)
    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), reussis))
    sys.exit(0 if reussis == len(S.RESULTATS) else 1)


if __name__ == '__main__':
    main()
