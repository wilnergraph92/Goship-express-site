#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Non-régression des essais officiels avec les candidates du Communication Center
appliquées (décision A′ du 23/11/2026, étape C10 de la feuille de route).

Les candidates redéfinissent des fonctions de la chaîne officielle (expedier_envoi,
lire_reponse_envoi, texte_notification, traiter_notifications, permissions_du_role…).
Depuis l'étape C11 (23/11/2026), les candidates ferment la chaîne officielle
(outils/migrations.txt) : essai-notifications.py et tous les essais qui installent
toute la chaîne les appliquent d'eux-mêmes. Trois essais, en revanche, éprouvent
une mise à niveau et n'installent la chaîne que jusqu'à « leur » fichier : ils ne
verraient jamais les candidates. Ce harnais les rejoue tels quels, candidates
appliquées par-dessus :

  accuses          essai-accuses.py           après supabase-accuses.sql
  suivi-courriels  essai-suivi-courriels.py   après supabase-suivi-courriels.sql
  programmes       essai-programmes.py        après le dernier fichier de sa série

Ces essais installent la chaîne jusqu'à « leur » fichier, observent l'état
d'avant, puis appliquent ce fichier.
Les candidates sont appliquées juste après ce fichier, jamais avant : l'état
d'avant reste celui que l'essai veut observer. Ensuite, chaque fois que l'essai
rejoue un fichier de la chaîne officielle, les candidates sont réappliquées
aussitôt, dans l'ordre, comme le serait une chaîne qui les intègre à sa fin.

Chaque essai tourne dans son propre processus et son propre dossier de travail.
Bases PostgreSQL locales jetables (pgserver), aucun réseau, aucun fournisseur.
Les doublures de pgcrypto et de Vault ne testent aucune propriété cryptographique.

Usage :
  python3 outils/essais-services/essai-communication-non-regression.py
  python3 outils/essais-services/essai-communication-non-regression.py accuses programmes
"""
import importlib.util
import os
import pathlib
import subprocess
import sys
import tempfile
import uuid

ICI = os.path.dirname(os.path.abspath(__file__))
OUTILS = os.path.normpath(os.path.join(ICI, '..'))
CANDIDATES = os.path.join(OUTILS, 'migrations-candidates')
CHAINE = [l.strip() for l in open(os.path.join(OUTILS, 'migrations.txt'), encoding='utf-8')
          if l.strip() and not l.startswith('#')]
# Les candidates, dans l'ordre où la chaîne officielle les applique
FICHIERS_CANDIDATS = [os.path.join(OUTILS, f) for f in CHAINE if f.startswith('migrations-candidates/')]

# Essai officiel → fichier de la chaîne après lequel les candidates entrent en jeu.
CIBLES = {
    'accuses': ('essai-accuses.py', lambda m: m.NOUVEAU),
    'suivi-courriels': ('essai-suivi-courriels.py', lambda m: m.NOUVEAU),
    'programmes': ('essai-programmes.py', lambda m: m.NOUVEAUX[-1]),
}

# Écarts voulus par les candidates, chacun nommé, justifié et limité à la valeur exacte
# obtenue : toute autre différence reste un échec. Essai → titre → (valeur des
# candidates, raison). Vide depuis C11 : le seul écart connu (LIMITE_DEBIT au lieu de
# HTTP_429) est devenu l'attente de essai-notifications.py.
ECARTS_VOLONTAIRES = {}

DOUBLURES_CRYPTO = """
  create schema if not exists extensions;
  create or replace function extensions.gen_random_bytes(p_taille integer)
  returns bytea language sql volatile set search_path = '' as $$
    select substring(decode(replace(gen_random_uuid()::text, '-', ''), 'hex') from 1 for p_taille)
  $$;
  create or replace function extensions.digest(p_texte text, p_type text)
  returns bytea language sql immutable set search_path = '' as $$
    select decode(md5(p_texte) || md5('fixture:' || p_texte), 'hex')
  $$;
  create or replace function extensions.hmac(p_texte text, p_cle text, p_type text)
  returns bytea language sql immutable set search_path = '' as $$
    select decode(md5(p_cle || ':' || p_texte) || md5('fixture:' || p_cle || ':' || p_texte), 'hex')
  $$;
"""


def executer_cible(nom):
    fichier_essai, declencheur = CIBLES[nom]
    spec = importlib.util.spec_from_file_location('essai_cible', os.path.join(ICI, fichier_essai))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    S = module.S
    # Dossier de travail propre : l'essai officiel peut tourner en même temps dans le
    # dossier partagé par défaut, et chacun supprime sa base en fin d'essai.
    S.TRAVAIL = os.path.join(tempfile.gettempdir(), 'goship-non-regression-' + uuid.uuid4().hex)
    os.makedirs(S.TRAVAIL, exist_ok=True)
    fichier_declencheur = declencheur(module)
    original = S.Base.fichier
    etat = {'en_cours': False, 'actives': set(), 'doublees': set()}

    def appliquer_candidates(db):
        etat['en_cours'] = True
        try:
            if id(db) not in etat['doublees']:
                db.sql(DOUBLURES_CRYPTO)
                etat['doublees'].add(id(db))
            for chemin in FICHIERS_CANDIDATS:
                texte = pathlib.Path(chemin).read_text(encoding='utf-8')
                texte = texte.replace('create extension if not exists pgcrypto with schema extensions;', '')
                copie = pathlib.Path(S.TRAVAIL, 'candidate-' + os.path.basename(chemin))
                copie.write_text(texte, encoding='utf-8')
                original(db, str(copie))
        finally:
            etat['en_cours'] = False

    def fichier(self, chemin):
        sortie = original(self, chemin)
        officiel = os.path.dirname(os.path.abspath(chemin)) == OUTILS
        if officiel and not etat['en_cours']:
            if os.path.basename(chemin) == fichier_declencheur:
                etat['actives'].add(id(self))
            if id(self) in etat['actives']:
                appliquer_candidates(self)
        return sortie

    S.Base.fichier = fichier

    ecarts = ECARTS_VOLONTAIRES.get(nom, {})
    verifier_original = S.verifier

    def verifier(titre, obtenu, attendu):
        if titre in ecarts:
            valeur, raison = ecarts[titre]
            obtenu_net = obtenu.strip() if isinstance(obtenu, str) else obtenu
            if obtenu_net == valeur and obtenu_net != attendu:
                print('       écart volontaire des candidates : %s' % raison)
                return verifier_original(titre, obtenu, obtenu)
        return verifier_original(titre, obtenu, attendu)

    # Les essais gardent une référence à S.verifier sous le nom « verifier ».
    S.verifier = verifier
    if getattr(module, 'verifier', None) is verifier_original:
        module.verifier = verifier
    print('Non-régression « %s » (%s) avec les candidates %s, appliquées après %s'
          % (nom, fichier_essai, ', '.join(os.path.basename(f)[:3] for f in FICHIERS_CANDIDATS),
             fichier_declencheur))
    sys.stdout.flush()
    module.main()


def main(arguments):
    if len(arguments) == 2 and arguments[0] == '--cible':
        executer_cible(arguments[1])
        return 0
    noms = arguments or list(CIBLES)
    inconnus = [n for n in noms if n not in CIBLES]
    if inconnus:
        print('Cible inconnue : %s (attendu : %s)' % (', '.join(inconnus), ', '.join(CIBLES)))
        return 2
    bilan = []
    for nom in noms:
        r = subprocess.run([sys.executable, os.path.abspath(__file__), '--cible', nom])
        bilan.append((nom, r.returncode))
        print()
    print('Bilan de la non-régression avec les candidates :')
    for nom, code in bilan:
        print('  %-16s %s' % (nom, 'réussi' if code == 0 else 'ÉCARTS (code %d)' % code))
    return 0 if all(code == 0 for _, code in bilan) else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
