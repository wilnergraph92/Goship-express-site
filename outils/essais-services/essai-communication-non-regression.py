#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Non-régression du moteur de notifications transactionnelles avec les candidates
du Communication Center appliquées (décision A′ du 23/11/2026).

Les candidates 004 et 005 redéfinissent expedier_envoi, lire_reponse_envoi,
texte_notification et traiter_notifications. Ce harnais rejoue tel quel
essai-notifications.py, mais sur une base où la chaîne officielle est suivie des
candidates. Quand l'essai relance un fichier de la chaîne, les candidates sont
réappliquées juste après, comme le serait une chaîne qui les intègre.

Bases PostgreSQL locales jetables (pgserver), aucun réseau, aucun fournisseur.
Les doublures de pgcrypto et de Vault ne testent aucune propriété cryptographique.

Usage : python3 outils/essais-services/essai-communication-non-regression.py
"""
import importlib.util
import os
import pathlib
import tempfile
import uuid

ICI = os.path.dirname(os.path.abspath(__file__))
OUTILS = os.path.normpath(os.path.join(ICI, '..'))
CANDIDATES = os.path.join(OUTILS, 'migrations-candidates')
FICHIERS_CANDIDATS = sorted(
    os.path.join(CANDIDATES, f) for f in os.listdir(CANDIDATES)
    if f.endswith('.sql') and f[:3].isdigit())

_spec = importlib.util.spec_from_file_location(
    'essai_notifications', os.path.join(ICI, 'essai-notifications.py'))
N = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(N)
S = N.S
# Dossier de travail propre : essai-notifications.py peut tourner en même temps
# dans le dossier partagé par défaut, et chacun supprime sa base en fin d'essai.
S.TRAVAIL = os.path.join(tempfile.gettempdir(), 'goship-non-regression-' + uuid.uuid4().hex)
os.makedirs(S.TRAVAIL, exist_ok=True)

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

_fichier_original = S.Base.fichier
_etat = {'candidates': False, 'en_cours': False}


def _appliquer_candidates(db):
    _etat['en_cours'] = True
    try:
        for chemin in FICHIERS_CANDIDATS:
            texte = pathlib.Path(chemin).read_text(encoding='utf-8')
            texte = texte.replace('create extension if not exists pgcrypto with schema extensions;', '')
            copie = pathlib.Path(S.TRAVAIL, 'candidate-' + os.path.basename(chemin))
            copie.write_text(texte, encoding='utf-8')
            _fichier_original(db, str(copie))
    finally:
        _etat['en_cours'] = False


def _fichier(self, chemin):
    _fichier_original(self, chemin)
    # Un fichier de la chaîne officielle rejoué écrase les redéfinitions des candidates :
    # on les réapplique aussitôt, dans l'ordre.
    if _etat['candidates'] and not _etat['en_cours'] and \
            os.path.dirname(os.path.abspath(chemin)) == OUTILS:
        _appliquer_candidates(self)


S.Base.fichier = _fichier
_installer_original = N.installer


def installer_avec_candidates():
    # Une nouvelle base installe d'abord toute la chaîne, sans réapplication intercalée.
    _etat['candidates'] = False
    db = _installer_original()
    db.sql(DOUBLURES_CRYPTO)
    _appliquer_candidates(db)
    _etat['candidates'] = True
    return db


N.installer = installer_avec_candidates

if __name__ == '__main__':
    print('Non-régression transactionnelle avec les candidates %s'
          % ', '.join(os.path.basename(f)[:3] for f in FICHIERS_CANDIDATS))
    N.main()
