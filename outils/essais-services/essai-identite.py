# -*- coding: utf-8 -*-
"""Éprouve le sexe et le document d'identité demandés à l'inscription (outils/supabase-identite.sql).

Même base jetable, mêmes rôles SQL et même fausse pg_net que essai-services.py, avec toute la
chaîne de outils/migrations.txt. On installe d'abord la chaîne SANS ce fichier, on ouvre des
comptes à l'ancienne, puis on installe le fichier DEUX fois. Ensuite :
  A. l'inscription par e-mail garde le sexe (M, F) et le type de document (passeport, cedula) ;
  B. facultatifs côté base : une inscription sans eux (application déjà installée, Google) marche ;
  C. une valeur inconnue n'est pas gardée et ne refuse pas l'inscription ; la date de naissance,
     elle, reste obligatoire ;
  D. aucun autre chemin d'écriture ne peut y mettre autre chose (contraintes), le client ne les
     modifie pas lui-même, l'équipe et le client les lisent ;
  E. la suppression du compte les efface ;
  F. rien n'est ouvert aux comptes ni aux visiteurs, et relancer le fichier ne change aucune donnée.

Depuis la racine du site :

    python3 outils/essais-services/essai-identite.py
"""
import importlib.util
import json
import os
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
# Pas de dossier __pycache__ à côté des essais : il partirait en ligne avec le site.
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location('essai_analytics', os.path.join(ICI, 'essai-analytics.py'))
A = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(A)
S = A.S

RACINE = S.RACINE
OUTILS = os.path.join(RACINE, 'outils')
ADMIN, MARIE, JEAN, EMPLOYE = A.ADMIN, A.MARIE, A.JEAN, A.EMPLOYE
verifier = S.verifier
NOUVEAU = 'supabase-identite.sql'
CHAINE = [l.strip() for l in open(os.path.join(OUTILS, 'migrations.txt'), encoding='utf-8')
          if l.strip() and not l.startswith('#')]


def js(d):
    return "'%s'::jsonb" % json.dumps(d).replace("'", "''")


def un(db, texte, compte=None):
    """La dernière ligne de la réponse."""
    sortie = db.comme(compte, texte) if compte not in (None, 'sql') else db.sql(texte)
    lignes = [l for l in sortie.splitlines() if l.strip()]
    return lignes[-1].strip() if lignes else ''


def main():
    db = S.Base()
    db.sql(S.DOUBLURES)
    compteur = [0]

    def inscrire(meta, fournisseur='email', brut=False):
        """Une inscription, comme GoTrue la fait : une ligne dans auth.users, fournisseur dans app_meta."""
        compteur[0] += 1
        uid = '00000000-0000-4000-8000-%012d' % (9000 + compteur[0])
        texte = ("insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data, raw_app_meta_data) "
                 "values ('%s', 'id%d@exemple.com', now(), %s, %s);" % (uid, compteur[0], js(meta), js({'provider': fournisseur})))
        if brut:
            return uid, texte
        db.sql(texte)
        return uid, None

    def champs(uid):
        return un(db, "select coalesce(sexe, '-') || '|' || coalesce(type_document, '-') from clients where id = '%s';" % uid)

    base = {'nom_complet': 'Nadège Joseph', 'pays': 'HT', 'date_naissance': '1990-05-12'}

    print("A0. Installation : la chaîne, des comptes à l'ancienne, puis le fichier deux fois")
    assert NOUVEAU in CHAINE, "%s n'est pas dans outils/migrations.txt" % NOUVEAU
    for f in CHAINE[:CHAINE.index(NOUVEAU)]:
        db.fichier(os.path.join(OUTILS, f))
    A.comptes(db)
    ancien, _ = inscrire(dict(base, nom_complet='Ancien Compte'))
    for _ in range(2):
        db.fichier(os.path.join(OUTILS, NOUVEAU))
    verifier('installé deux fois : aucune erreur', 'oui', 'oui')
    verifier('le contrôle du fichier : 2 colonnes, 2 fonctions, rien d\'ouvert, profil à jour',
             un(db, "select (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'clients' "
                    "and column_name in ('sexe', 'type_document'))::text || '|' || "
                    "(select count(*) from pg_proc where proname in ('lire_sexe', 'lire_type_document'))::text || '|' || "
                    "(select coalesce(bool_or(has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute')), false) "
                    "from pg_proc p where p.proname in ('lire_sexe', 'lire_type_document', 'creer_profil_client', 'effacer_identite_compte_supprime'))::text || '|' || "
                    "(position('lire_type_document' in pg_get_functiondef('public.creer_profil_client()'::regprocedure)) > 0)::text;"),
             '2|2|false|true')
    verifier("un compte d'avant le fichier : ni sexe ni document, rien d'inventé", champs(ancien), '-|-')
    verifier("les comptes de l'équipe et les clients des essais : vides aussi",
             un(db, "select count(*) from clients where sexe is not null or type_document is not null;"), '0')

    print("\nA. L'inscription par e-mail garde le sexe et le type de document")
    for meta, attendu, titre in (({'sexe': 'M', 'type_document': 'passeport'}, 'M|passeport', 'Masculin, Passeport'),
                                 ({'sexe': 'F', 'type_document': 'cedula'}, 'F|cedula', 'Féminin, Cédula'),
                                 ({'sexe': ' f ', 'type_document': ' CEDULA '}, 'F|cedula', 'espaces et majuscules autour'),
                                 ({'sexe': 'Féminin', 'type_document': 'Passport'}, 'F|passeport', 'les mots entiers (Féminin, Passport)'),
                                 ({'sexe': 'masculino', 'type_document': 'Pasaporte'}, 'M|passeport', 'espagnol (masculino, Pasaporte)'),
                                 ({'sexe': 'Gason', 'type_document': 'Cédula'}, 'M|cedula', 'créole et accent (Gason, Cédula)')):
        uid, _ = inscrire(dict(base, **meta))
        verifier(titre, champs(uid), attendu)

    print("\nB. Facultatifs côté base : l'application déjà installée et Google ne sont pas bloqués")
    uid, _ = inscrire(base)
    verifier("e-mail, sans sexe ni document (application mobile d'avant) : compte créé, colonnes vides", champs(uid), '-|-')
    uid, _ = inscrire({'nom_complet': 'Compte Google', 'pays': 'HT'}, fournisseur='google')
    verifier("Google : compte créé sans date, sans sexe, sans document", champs(uid), '-|-')
    uid, _ = inscrire(dict(base, sexe='F'))
    verifier("seulement le sexe : gardé, le document reste vide", champs(uid), 'F|-')
    uid, _ = inscrire(dict(base, type_document='cedula'))
    verifier("seulement le document : gardé, le sexe reste vide", champs(uid), '-|cedula')

    print("\nC. Une valeur inconnue n'est pas gardée ; la date de naissance reste obligatoire")
    for meta, attendu, titre in (({'sexe': 'X', 'type_document': 'permis'}, '-|-', 'ni M/F ni passeport/cedula'),
                                 ({'sexe': '', 'type_document': ''}, '-|-', 'valeurs vides'),
                                 ({'sexe': 'M\'; drop table clients; --', 'type_document': '<b>x</b>'}, '-|-', 'texte piégé'),
                                 ({'sexe': 1, 'type_document': None}, '-|-', 'pas du texte')):
        uid, _ = inscrire(dict(base, **meta))
        verifier('%s : compte créé, colonnes vides' % titre, champs(uid), attendu)
    avant = un(db, "select count(*) from clients;")
    _, texte = inscrire({'nom_complet': 'Sans Date', 'pays': 'HT', 'sexe': 'M', 'type_document': 'passeport'}, brut=True)
    verifier("sans date de naissance : l'inscription est refusée, malgré un sexe et un document valides",
             db.erreur('sql', texte)[:18], 'BIRTHDATE_REQUIRED')
    verifier("… et aucun compte n'a été créé", un(db, "select count(*) from clients;"), avant)

    print("\nD. Contraintes, droits de lecture et d'écriture")
    verifier("une valeur hors M/F est refusée par la table (aucun autre chemin d'écriture)",
             db.erreur('sql', "update clients set sexe = 'X' where id = '%s';" % MARIE)[:40].startswith('new row for relation'), True)
    verifier("un document hors passeport/cedula aussi",
             db.erreur('sql', "update clients set type_document = 'permis' where id = '%s';" % MARIE)[:40].startswith('new row for relation'), True)
    db.sql("update clients set sexe = 'F', type_document = 'cedula' where id = '%s';" % MARIE)
    verifier("un client ne modifie pas son sexe lui-même", db.erreur(MARIE, "update clients set sexe = 'M' where id = '%s';" % MARIE)[:17], 'permission denied')
    verifier("… ni son document", db.erreur(MARIE, "update clients set type_document = 'passeport' where id = '%s';" % MARIE)[:17], 'permission denied')
    verifier("le client lit les siens", un(db, "select sexe || '|' || type_document from clients where id = '%s';" % MARIE, MARIE), 'F|cedula')
    verifier("un autre client ne lit pas ceux de Marie", un(db, "select count(*) from clients where id = '%s';" % MARIE, JEAN), '0')
    verifier("l'équipe (clients.view) les lit", un(db, "select sexe || '|' || type_document from clients where id = '%s';" % MARIE, EMPLOYE), 'F|cedula')
    verifier("un visiteur ne lit rien", db.erreur(None, "select sexe from clients;")[:17], 'permission denied')

    print("\nE. La suppression du compte efface les deux valeurs")
    uid, _ = inscrire(dict(base, sexe='M', type_document='passeport'))
    verifier("avant : gardés", champs(uid), 'M|passeport')
    db.sql("update clients set supprime_le = now() where id = '%s';" % uid)
    verifier("après la suppression du compte : effacés", champs(uid), '-|-')
    uid2, _ = inscrire(dict(base, sexe='F', type_document='cedula'))
    db.sql("update clients set telephone = '+1 305 555 0100' where id = '%s';" % uid2)
    verifier("une autre modification du profil ne les efface pas", champs(uid2), 'F|cedula')

    print("\nF. Les droits, et relancer le fichier ne change aucune donnée")
    for nom, requete in (('lire_sexe', "select public.lire_sexe('M');"),
                         ('lire_type_document', "select public.lire_type_document('cedula');"),
                         ('creer_profil_client', "select public.creer_profil_client();"),
                         ('effacer_identite_compte_supprime', "select public.effacer_identite_compte_supprime();")):
        for qui, compte in (('un visiteur', None), ('un client', MARIE), ('un employé', EMPLOYE), ('un administrateur', ADMIN)):
            verifier('%s ne peut pas appeler %s' % (qui, nom), db.erreur(compte, requete)[:17], 'permission denied')
    photo = lambda: un(db, "select md5(string_agg(id::text || coalesce(sexe, '') || coalesce(type_document, ''), ',' order by id)) from clients;")
    avant = photo()
    db.fichier(os.path.join(OUTILS, NOUVEAU))
    verifier("relancer le fichier : mêmes valeurs pour tous les clients", photo(), avant)

    echecs = [r for r in S.RESULTATS if not r]
    print('\n%d vérifications, %d réussies.' % (len(S.RESULTATS), len(S.RESULTATS) - len(echecs)))
    return 1 if echecs else 0


if __name__ == '__main__':
    sys.exit(main())
