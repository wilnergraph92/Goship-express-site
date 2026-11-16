#!/usr/bin/env python3
"""Banc de versionner.py et des règles de cache du .htaccess.

    python3 outils/production/essai-versionner.py

Aucune requête, aucun fichier du dépôt modifié : tout se passe dans un dossier
temporaire. Vérifie que les empreintes posées sont celles des fichiers, qu'une
page en/ et la page 404 (liens depuis la racine) sont traitées, que relancer ne
change rien, qu'un fichier modifié est signalé par --verifier, qu'un lien vers
un fichier absent arrête tout, et que le dépôt lui-même n'a aucune empreinte
(elles ne naissent que dans la copie publiée).
"""

import hashlib
import os
import re
import subprocess
import sys
import tempfile

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.normpath(os.path.join(ICI, '..', '..'))
SCRIPT = os.path.join(ICI, 'versionner.py')
echecs = []


def verifier(cond, nom):
    print(('ok    ' if cond else 'ÉCHEC ') + nom)
    if not cond:
        echecs.append(nom)


def lancer(*args):
    r = subprocess.run([sys.executable, SCRIPT] + list(args), capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def ecrire(chemin, texte):
    os.makedirs(os.path.dirname(chemin), exist_ok=True)
    with open(chemin, 'w', encoding='utf-8') as f:
        f.write(texte)


def lire(chemin):
    with open(chemin, encoding='utf-8') as f:
        return f.read()


def h(chemin):
    with open(chemin, 'rb') as f:
        return hashlib.sha256(f.read()).hexdigest()[:10]


with tempfile.TemporaryDirectory() as site:
    ecrire(os.path.join(site, 'assets/js/api.js'), 'window.GoshipAPI = {};\n')
    ecrire(os.path.join(site, 'assets/css/site.css'), 'body{}\n')
    ecrire(os.path.join(site, 'index.html'),
           '<link rel="stylesheet" href="assets/css/site.css">\n'
           '<script src="assets/js/api.js" defer></script>\n'
           '<a href="assets/img/logo.png">image : pas touchée</a>\n'
           '<a href="https://exemple.org/assets/js/api.js">autre site : pas touché</a>\n')
    ecrire(os.path.join(site, 'en/index.html'),
           '<script src="../assets/js/api.js?v=0000000000" defer></script>\n')
    ecrire(os.path.join(site, '404.html'), '<script src="/assets/js/api.js"></script>\n')

    code, sortie = lancer(site, '--verifier')
    verifier(code == 1 and 'périmées' in sortie, '--verifier signale des pages sans empreinte')

    code, sortie = lancer(site)
    verifier(code == 0 and '3 pages modifiées' in sortie, 'trois pages versionnées')
    js, css = h(os.path.join(site, 'assets/js/api.js')), h(os.path.join(site, 'assets/css/site.css'))
    racine = lire(os.path.join(site, 'index.html'))
    verifier('href="assets/css/site.css?v=%s"' % css in racine, 'feuille de style : empreinte du fichier')
    verifier('src="assets/js/api.js?v=%s"' % js in racine, 'script : empreinte du fichier')
    verifier('assets/img/logo.png"' in racine and 'exemple.org/assets/js/api.js"' in racine,
             'images et autres sites inchangés')
    verifier('src="../assets/js/api.js?v=%s"' % js in lire(os.path.join(site, 'en/index.html')),
             'page en/ : ancienne empreinte remplacée')
    verifier('src="/assets/js/api.js?v=%s"' % js in lire(os.path.join(site, '404.html')),
             'page 404 : lien depuis la racine')

    code, sortie = lancer(site)
    verifier(code == 0 and '0 pages modifiées' in sortie, 'relancer ne change rien')
    code, sortie = lancer(site, '--verifier')
    verifier(code == 0, '--verifier : tout est à jour')

    ecrire(os.path.join(site, 'assets/js/api.js'), 'window.GoshipAPI = { v: 2 };\n')
    code, sortie = lancer(site, '--verifier')
    verifier(code == 1 and 'index.html' in sortie, 'un script modifié rend l\'empreinte périmée')

    ecrire(os.path.join(site, 'contact.html'), '<script src="assets/js/absent.js"></script>\n')
    code, sortie = lancer(site)
    verifier(code == 1 and 'absent.js' in sortie, 'un lien vers un fichier absent arrête tout')

# Le dépôt n'a aucune empreinte : elles ne naissent que dans _site (deploy.yml)
avec = []
for dossier, sous, fichiers in os.walk(RACINE):
    sous[:] = [d for d in sous if not d.startswith('.') and d not in ('application-mobile', 'node_modules')]
    for nom in fichiers:
        if nom.endswith('.html') and re.search(r'assets/(?:css|js)/[^"?]+\?v=', lire(os.path.join(dossier, nom))):
            avec.append(os.path.relpath(os.path.join(dossier, nom), RACINE))
verifier(not avec, 'aucune page du dépôt ne porte d\'empreinte' + (' : ' + ', '.join(avec[:5]) if avec else ''))

# Le .htaccess : un an pour les fichiers versionnés seulement, plus de renvoi des .html
ht = lire(os.path.join(RACINE, '.htaccess'))
verifier('E=GS_VERSIONNE:1' in ht and 'immutable" env=GS_VERSIONNE' in ht,
         '.htaccess : cache d\'un an réservé aux liens versionnés')
verifier(re.search(r'RewriteRule \^\(\.\+\)\\\.html\$ /\$1 \[R=301', ht) is None,
         '.htaccess : plus de renvoi des adresses en .html')
verifier('Header set Cache-Control "no-cache"' in ht, '.htaccess : pages et fichiers nus sans cache')

wf = lire(os.path.join(RACINE, '.github/workflows/deploy.yml'))
verifier('versionner.py _site\n' in wf and 'versionner.py _site --verifier' in wf,
         'deploy.yml pose puis vérifie les empreintes')

print()
if echecs:
    sys.exit('%d échec(s).' % len(echecs))
print('Tout est bon.')
