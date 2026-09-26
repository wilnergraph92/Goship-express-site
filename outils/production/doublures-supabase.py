#!/usr/bin/env python3
# =============================================================================
# Goship Express — le SQL qui fait d'un PostgreSQL ordinaire un « projet Supabase
# neuf » pour les essais : schémas auth, vault, net, storage, extensions (doublures),
# rôles anon / authenticated / service_role, droits par défaut de Supabase.
#
#   python3 outils/production/doublures-supabase.py | psql "$CIBLE_DB_URL"
#
# Les doublures sont celles des bancs d'essai (outils/essais-services/essai-services.py,
# DOUBLURES ; essai-production.py, DROITS_SUPABASE) : une seule source, lue ici
# sans importer les bancs (qui demandent pgserver). Sert à la restauration
# d'épreuve de sauvegarde.yml. JAMAIS sur un vrai projet Supabase : il a déjà tout cela.
# =============================================================================
import os
import re
import sys

ESSAIS = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'essais-services')


def extraire(fichier, nom):
    texte = open(os.path.join(ESSAIS, fichier), encoding='utf-8').read()
    m = re.search(r'^%s = r?"""(.*?)"""' % nom, texte, re.S | re.M)
    if not m:
        sys.exit('%s introuvable dans %s' % (nom, fichier))
    return m.group(1)


print(extraire('essai-services.py', 'DOUBLURES'))
print(extraire('essai-production.py', 'DROITS_SUPABASE'))
