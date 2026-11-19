#!/usr/bin/env python3
"""Donne aux liens entre pages l'adresse que Google doit retenir, dans la copie publiée.

    python3 outils/production/liens_propres.py _site            # réécrit les liens
    python3 outils/production/liens_propres.py _site --verifier # ne change rien, dit s'il en reste

Pourquoi : chaque page déclare son adresse propre (balise canonical, sitemap.xml :
goshipexpress.net/nos-services, sans « .html »), mais ses liens menaient à
nos-services.html. Google voyait donc deux adresses par page : celle qu'on lui
demande de montrer ne recevait aucun lien du site, et l'accueil (/) non plus,
puisque tout pointait vers index.html (rapport SEO du 19/11/2026). Les deux
hébergeurs servent l'adresse propre : Hostinger par la règle du .htaccess
(nos-services → nos-services.html), GitHub Pages de lui-même.

Seulement dans la copie qui part en ligne (_site, deploy.yml), comme les
empreintes de versionner.py : le dépôt garde ses liens en .html, sans quoi le
site ne s'ouvrirait plus depuis le disque (file:), où « nos-services » ne
désigne aucun fichier.

Règles :
- seuls les href d'une page vers une autre page du site qui existe sont touchés :
  nos-services.html → nos-services, index.html → ./, ../index.html → ../,
  /contacts.html → /contacts (page 404) ; l'ancre et les paramètres restent
  (connexion.html?retour=… → connexion?retour=…) ;
- le tableau de bord (admin.html) n'est ni réécrit ni désigné autrement : il
  n'est pas une page publique, et l'application de bureau l'ouvre par son nom ;
- un lien vers un fichier absent n'est pas touché (versionner.py et surveiller.sh
  s'occupent des liens cassés) ;
- relancer ne change rien.
"""

import os
import re
import sys

# href="…" : adresse relative ou depuis la racine, jamais https:, mailto:, tel:, #…
LIEN = re.compile(r'(?P<attr>\bhref=")(?P<chemin>(?![a-z][a-z0-9+.-]*:|#|//)[^"?#]*\.html)(?P<suite>[?#][^"]*)?"')
EXCLUES = {'admin.html'}


def cible(racine, page, chemin):
    """Le fichier sur disque que ce lien désigne, depuis cette page."""
    if chemin.startswith('/'):
        return os.path.normpath(os.path.join(racine, chemin.lstrip('/')))
    return os.path.normpath(os.path.join(os.path.dirname(page), chemin))


def adresse_propre(chemin):
    """nos-services.html → nos-services ; en/index.html → en/ ; index.html → ./"""
    if chemin == 'index.html':
        return './'
    if chemin.endswith('/index.html'):
        return chemin[:-len('index.html')]
    return chemin[:-len('.html')]


def traiter(racine, verifier=False):
    restes, pages, liens = [], 0, 0
    for dossier, sous, fichiers in os.walk(racine):
        sous[:] = [d for d in sous if not d.startswith('.')]
        for nom in sorted(fichiers):
            if not nom.endswith('.html') or nom in EXCLUES:
                continue
            page = os.path.join(dossier, nom)
            with open(page, encoding='utf-8') as f:
                texte = f.read()
            compte = [0]

            def remplacer(m):
                fichier = cible(racine, page, m.group('chemin'))
                if os.path.basename(fichier) in EXCLUES or not os.path.isfile(fichier):
                    return m.group(0)
                compte[0] += 1
                return '%s%s%s"' % (m.group('attr'), adresse_propre(m.group('chemin')), m.group('suite') or '')

            neuf = LIEN.sub(remplacer, texte)
            liens += compte[0]
            if neuf != texte:
                if verifier:
                    restes.append('%s (%d lien(s) en .html)' % (os.path.relpath(page, racine), compte[0]))
                else:
                    with open(page, 'w', encoding='utf-8') as f:
                        f.write(neuf)
                    pages += 1
    return restes, pages, liens


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if len(args) != 1 or not os.path.isdir(args[0]):
        sys.exit('Usage : liens_propres.py <dossier du site> [--verifier]')
    verifier = '--verifier' in sys.argv
    restes, pages, liens = traiter(args[0], verifier)
    if verifier:
        if restes:
            print('Liens entre pages encore en .html :')
            for r in restes:
                print('  ' + r)
            sys.exit(1)
        print('Tous les liens entre pages portent l\'adresse propre.')
        return
    print('%d lien(s) réécrit(s) en adresse propre dans %d page(s).' % (liens, pages))


if __name__ == '__main__':
    main()
