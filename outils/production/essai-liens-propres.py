#!/usr/bin/env python3
"""Banc de liens_propres.py.

    python3 outils/production/essai-liens-propres.py

Aucune requête, aucun fichier du dépôt modifié : tout se passe dans un dossier
temporaire. Vérifie que les liens entre pages perdent leur « .html » (index.html
devient le dossier), depuis la racine, depuis en/ et depuis la page 404 ; que
l'ancre et les paramètres restent ; que les adresses extérieures, les ancres, les
fichiers absents et le tableau de bord ne sont pas touchés ; que relancer ne change
rien ; que --verifier signale une page oubliée ; et que le dépôt lui-même garde ses
liens en .html (la réécriture ne vit que dans la copie publiée).
"""

import os
import re
import subprocess
import sys
import tempfile

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.normpath(os.path.join(ICI, '..', '..'))
SCRIPT = os.path.join(ICI, 'liens_propres.py')
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


with tempfile.TemporaryDirectory() as site:
    for page in ('nos-services.html', 'connexion.html', 'admin.html', 'en/index.html', 'en/faq.html'):
        ecrire(os.path.join(site, page), '<p>page</p>\n')
    ecrire(os.path.join(site, 'index.html'),
           '<a href="index.html">Accueil</a>\n'
           '<a href="index.html#adresse">Adresse</a>\n'
           '<a href="nos-services.html#services">Services</a>\n'
           '<a href="connexion.html?retour=mon-compte.html">Connexion</a>\n'
           '<a href="en/index.html" hreflang="en">English</a>\n'
           '<a href="en/faq.html">FAQ</a>\n'
           '<a href="admin.html">Tableau de bord</a>\n'
           '<a href="absente.html">Absente</a>\n'
           '<a href="https://exemple.com/page.html">Ailleurs</a>\n'
           '<a href="#top">Haut</a>\n'
           '<link rel="stylesheet" href="assets/css/site.css">\n')
    ecrire(os.path.join(site, 'en/faq.html'),
           '<a href="index.html">Home</a>\n'
           '<a href="../index.html" hreflang="fr">Français</a>\n'
           '<a href="../nos-services.html">Services FR</a>\n')
    ecrire(os.path.join(site, '404.html'),
           '<a href="/index.html">Accueil</a>\n<a href="/nos-services.html">Services</a>\n')
    ecrire(os.path.join(site, 'admin.html'), '<a href="index.html">Voir le site</a>\n')

    code, sortie = lancer(site, '--verifier')
    verifier(code == 1 and 'index.html' in sortie, '--verifier signale les pages aux liens en .html')

    code, sortie = lancer(site)
    verifier(code == 0, 'réécriture sans erreur : ' + sortie.strip())
    accueil = lire(os.path.join(site, 'index.html'))
    verifier('href="./">Accueil' in accueil, 'index.html → ./')
    verifier('href="./#adresse"' in accueil, "l'ancre reste (./#adresse)")
    verifier('href="nos-services#services"' in accueil, 'nos-services.html#services → nos-services#services')
    verifier('href="connexion?retour=mon-compte.html"' in accueil, 'les paramètres restent tels quels')
    verifier('href="en/" hreflang="en"' in accueil, 'en/index.html → en/')
    verifier('href="en/faq"' in accueil, 'en/faq.html → en/faq')
    verifier('href="admin.html"' in accueil, 'le tableau de bord garde son nom')
    verifier('href="absente.html"' in accueil, "un fichier absent n'est pas touché")
    verifier('href="https://exemple.com/page.html"' in accueil, "une adresse extérieure n'est pas touchée")
    verifier('href="#top"' in accueil and 'href="assets/css/site.css"' in accueil, 'ancres et feuilles de style intactes')
    faq = lire(os.path.join(site, 'en/faq.html'))
    verifier('href="./">Home' in faq and 'href="../" hreflang="fr"' in faq, 'depuis en/ : ./ et ../')
    verifier('href="../nos-services"' in faq, 'depuis en/ : ../nos-services')
    page404 = lire(os.path.join(site, '404.html'))
    verifier('href="/">' in page404 and 'href="/nos-services"' in page404, 'page 404 : /index.html → /, /nos-services')
    verifier(lire(os.path.join(site, 'admin.html')) == '<a href="index.html">Voir le site</a>\n',
             "le tableau de bord lui-même n'est pas réécrit")

    avant = {p: lire(os.path.join(site, p)) for p in ('index.html', 'en/faq.html', '404.html')}
    code, sortie = lancer(site)
    verifier(code == 0 and all(lire(os.path.join(site, p)) == t for p, t in avant.items()),
             'relancer ne change rien')
    code, sortie = lancer(site, '--verifier')
    verifier(code == 0, '--verifier : tout est à jour')

# Le dépôt garde ses liens en .html : le site doit s'ouvrir depuis le disque
with open(os.path.join(RACINE, 'nos-services.html'), encoding='utf-8') as f:
    depot = f.read()
verifier(re.search(r'href="contacts\.html', depot) is not None and 'href="contacts"' not in depot,
         'le dépôt garde ses liens en .html (nos-services.html)')

if echecs:
    print('\n%d échec(s)' % len(echecs))
    sys.exit(1)
print('\nTout est bon.')
