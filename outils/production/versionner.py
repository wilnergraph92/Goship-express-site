#!/usr/bin/env python3
"""Pose l'empreinte de chaque script et feuille de style dans les pages publiées.

    python3 outils/production/versionner.py _site            # pose les empreintes
    python3 outils/production/versionner.py _site --verifier # ne change rien, dit si tout est à jour

Appelé par deploy.yml sur la copie du site qui part en ligne (_site), jamais
sur le dépôt : les pages du dépôt gardent des liens nus (assets/js/api.js),
qu'aucune modification d'un script ne peut rendre faux, et le site reste sans
étape de construction pour qui le sert en local.

Dans la copie publiée, chaque lien vers assets/css/… ou assets/js/… reçoit
« ?v= » et les dix premiers signes du SHA-256 du fichier. Le .htaccess garde
ces fichiers-là un an (voir HTACCESS dans outils/generateur/build.py) : un
fichier changé change d'empreinte, donc d'adresse, et le navigateur ne peut pas
servir une copie ancienne. Un lien sans empreinte reste « no-cache ».

Un lien qui porte déjà « ?v= » est recalculé (relancer ne double rien). Un
lien vers un fichier absent est une erreur : la publication s'arrête plutôt
que de mettre en ligne une page qui charge un script introuvable.
"""

import hashlib
import os
import re
import sys

# href="…assets/css/site.css" ou src="../assets/js/api.js?v=0123456789",
# relatif à la page ou depuis la racine (/assets/…, page 404).
LIEN = re.compile(
    r'(?P<attr>\b(?:href|src)=")'
    r'(?P<chemin>(?:\.\./|/)?assets/(?:css|js)/[^"?#]+\.(?:css|js))'
    r'(?:\?v=[0-9a-f]{10})?"'
)


def empreinte(fichier, cache):
    if fichier not in cache:
        with open(fichier, 'rb') as f:
            cache[fichier] = hashlib.sha256(f.read()).hexdigest()[:10]
    return cache[fichier]


def cible(racine, page, chemin):
    """Le fichier sur disque que ce lien désigne, depuis cette page."""
    if chemin.startswith('/'):
        return os.path.normpath(os.path.join(racine, chemin.lstrip('/')))
    return os.path.normpath(os.path.join(os.path.dirname(page), chemin))


def traiter(racine, verifier=False):
    cache, manquants, perimes, pages, liens = {}, [], [], 0, 0
    for dossier, sous, fichiers in os.walk(racine):
        sous[:] = [d for d in sous if not d.startswith('.')]
        for nom in sorted(fichiers):
            if not nom.endswith('.html'):
                continue
            page = os.path.join(dossier, nom)
            with open(page, encoding='utf-8') as f:
                texte = f.read()
            compte = [0]

            def remplacer(m):
                fichier = cible(racine, page, m.group('chemin'))
                if not os.path.isfile(fichier):
                    manquants.append('%s → %s' % (os.path.relpath(page, racine), m.group('chemin')))
                    return m.group(0)
                compte[0] += 1
                return '%s%s?v=%s"' % (m.group('attr'), m.group('chemin'), empreinte(fichier, cache))

            neuf = LIEN.sub(remplacer, texte)
            liens += compte[0]
            if neuf != texte:
                if verifier:
                    perimes.append(os.path.relpath(page, racine))
                else:
                    with open(page, 'w', encoding='utf-8') as f:
                        f.write(neuf)
                    pages += 1
    return manquants, perimes, pages, liens


def main(argv):
    if len(argv) < 2 or not os.path.isdir(argv[1]):
        sys.exit('Usage : versionner.py <dossier du site> [--verifier]')
    verifier = '--verifier' in argv[2:]
    manquants, perimes, pages, liens = traiter(argv[1], verifier)
    if manquants:
        print('Lien vers un script ou une feuille de style absent :')
        print('\n'.join('  ' + m for m in manquants[:30]))
        sys.exit(1)
    if verifier:
        if perimes:
            print('Empreintes absentes ou périmées dans %d page(s) :' % len(perimes))
            print('\n'.join('  ' + p for p in perimes[:30]))
            sys.exit(1)
        print('%d liens, toutes les empreintes sont à jour.' % liens)
    else:
        print('%d liens versionnés, %d pages modifiées.' % (liens, pages))


if __name__ == '__main__':
    main(sys.argv)
