#!/usr/bin/env python3
"""Goship Express — les codes des étiquettes, comparés à deux références.

assets/js/codes.js calcule les QR codes et les codes-barres des étiquettes
d'expédition. Un code mal calculé ne se voit pas à l'œil : il s'imprime, part
avec le colis, et ne se lit pas au scanner. Ce banc d'essai compare donc chaque
code, module par module, à deux bibliothèques éprouvées :

    qrcode          (norme ISO/IEC 18004)   → les QR codes
    python-barcode  (Code 128)              → les codes-barres

Installation, puis lancement :

    pip3 install qrcode python-barcode
    python3 outils/essais-codes/essai-codes.py

Les huit masques du QR code sont comparés un par un, puis le masque choisi
automatiquement. Un seul module de différence fait échouer l'essai.
"""

import json
import os
import re
import subprocess
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
PROJET = os.path.normpath(os.path.join(ICI, '..', '..'))

try:
    import qrcode
    import qrcode.util
    import barcode
except ImportError:
    sys.exit("Manque une bibliothèque de référence. Lancez :\n"
             "    pip3 install qrcode python-barcode")

# Textes d'essai : de 1 caractère à la limite des versions 1 à 10 du QR code
URL = 'https://www.goshipexpress.com/index.html?suivi=GSE-1001-DO'
TEXTES_QR = [
    '1',
    'GSE-4323',
    'GSE-1001-DO',
    'A' * 14,                      # dernier texte qui tient en version 1
    'A' * 15,                      # premier qui demande la version 2
    URL,
    'Colis reçu à Miami — Goship Express',   # accents : plusieurs octets par lettre
    'GSE-1001-DO ' * 9,            # versions intermédiaires
    'X' * 180,
    'Z' * 213,                     # dernier texte qui tient en version 10
]
TEXTES_CODEBARRE = [
    'GSE-4323',
    'GSE-1001-DO',
    'GSE-10001-HT',
    'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
    'abcdefghijklmnopqrstuvwxyz',
    '0123456789',
    ' !"#$%&\'()*+,-./:;<=>?@[\\]^_`{|}~',
]
REFUS = [
    {'nom': 'qr-trop-long', 'quoi': 'qr', 'texte': 'Z' * 214},
    {'nom': 'codebarre-vide', 'quoi': 'codebarre', 'texte': ''},
    {'nom': 'codebarre-accent', 'quoi': 'codebarre', 'texte': 'Colis reçu'},
]

total = 0
ratés = []


def verifier(nom, obtenu, attendu):
    global total
    total += 1
    if obtenu == attendu:
        print(f'  ok   {nom}')
        return True
    print(f'  RATÉ {nom}')
    print(f'       attendu : {attendu!r}'[:300])
    print(f'       obtenu  : {obtenu!r}'[:300])
    ratés.append(nom)
    return False


def grille_du_dessin(chemin, taille, marge):
    """Relit le « d » du SVG (M x y h1 v1 h-1 z par module sombre)."""
    grille = [['.'] * taille for _ in range(taille)]
    for x, y in re.findall(r'M(\d+) (\d+)h1v1h-1z', chemin):
        grille[int(y) - marge][int(x) - marge] = '#'
    return [''.join(ligne) for ligne in grille]


def en_booleens(lignes):
    return [[c == '#' for c in ligne] for ligne in lignes]


def reference_qr(texte, masque):
    q = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M,
                      border=0, mask_pattern=masque)
    q.add_data(qrcode.util.QRData(texte.encode('utf-8'),
                                  mode=qrcode.util.MODE_8BIT_BYTE, check_data=False))
    q.make(fit=True)
    return [''.join('#' if c else '.' for c in ligne) for ligne in q.modules]


def reference_codebarre(texte):
    return barcode.get_barcode_class('code128')(texte).build()[0]


def main():
    entree = os.path.join(ICI, 'cas.json')
    with open(entree, 'w', encoding='utf-8') as f:
        json.dump({'qr': TEXTES_QR, 'codebarre': TEXTES_CODEBARRE, 'refus': REFUS}, f)
    try:
        brut = subprocess.run(['node', os.path.join(ICI, 'essai-codes.js'), entree],
                              capture_output=True, text=True, check=True, cwd=PROJET)
    except FileNotFoundError:
        sys.exit("Node.js est absent. Il ne sert qu'à lancer assets/js/codes.js hors "
                 "du navigateur, le temps de cet essai.")
    except subprocess.CalledProcessError as e:
        sys.exit('assets/js/codes.js a échoué :\n' + e.stderr)
    finally:
        os.remove(entree)
    nos = json.loads(brut.stdout)

    print('QR codes — les huit masques, puis le masque choisi')
    for cas in nos['qr']:
        texte = cas['texte']
        nom = f'« {texte[:28]}{"…" if len(texte) > 28 else ""} » ({len(texte.encode("utf-8"))} octets)'
        for masque in range(8):
            verifier(f'{nom}, masque {masque}', cas['masques'][str(masque)],
                     reference_qr(texte, masque))
        # Masque choisi : la norme demande de noter les huit codes finis et de
        # garder le moins pénalisé. On redonne donc nos huit codes aux quatre
        # règles de pénalité de la référence, et le masque qu'elles désignent
        # doit être celui que codes.js a retenu.
        #
        # (La référence, elle, note des codes dont la zone de format est
        # laissée vide : c'est un raccourci de son code, pas la norme. Comparer
        # son choix au nôtre ferait donc échouer l'essai sans qu'aucun des deux
        # codes soit illisible.)
        notes = [qrcode.util.lost_point(en_booleens(cas['masques'][str(m)])) for m in range(8)]
        choisi = notes.index(min(notes))
        verifier(f'{nom}, masque choisi ({choisi}, noté {min(notes)})',
                 cas['auto'], cas['masques'][str(choisi)])

    print('\nCodes-barres Code 128')
    for cas in nos['codebarre']:
        verifier(f'« {cas["texte"][:34]} »', cas['modules'], reference_codebarre(cas['texte']))

    print('\nTextes impossibles : refusés avec un message clair')
    for cas in REFUS:
        message = nos['erreurs'].get(cas['nom'])
        total_avant = total
        verifier(cas['nom'], bool(message), True)
        if total_avant != total and message:
            print(f'       « {message} »')

    print('\nLe dessin SVG')
    qr = nos['svg']['qr']
    verifier('QR : balise', qr['nom'], 'svg')
    verifier('QR : viewBox (21 modules + 4 de marge de chaque côté)', qr['viewBox'], '0 0 29 29')
    verifier('QR : titre, fond clair, dessin', [qr['titre'], qr['enfants'], qr['remplissages']],
             ['Suivi du colis GSE-1001-DO', ['title', 'rect', 'path'], ['', '#fff', '#000']])
    verifier('QR : le dessin commence par un module', qr['chemin'][:8], 'M4 4h1v1')
    # Le dessin est relu et la grille reconstruite : c'est ce qui prouve que le
    # SVG posé dans la page est bien le QR code calculé, et pas un décalage
    # d'un module ou deux coordonnées inversées.
    verifier('QR : le dessin redonne exactement la grille calculée',
             grille_du_dessin(qr['chemin'], len(qr['modules']), 4), qr['modules'])
    barres = nos['svg']['codebarre']
    verifier('Code-barres : viewBox (156 modules + 10 de marge)', barres['viewBox'], '0 0 176 30')
    verifier('Code-barres : fond clair puis barres', [barres['enfants'], barres['remplissages']],
             [['rect', 'path'], ['#fff', '#000']])
    verifier('Code-barres : première barre à gauche de la zone claire',
             barres['chemin'][:13], 'M10 0h2v30h-2')

    print(f'\n{total - len(ratés)} contrôles sur {total}.')
    if ratés:
        print('Ratés : ' + ', '.join(ratés))
        sys.exit(1)
    print('Les codes sont identiques, module par module, à ceux des bibliothèques de référence.')


if __name__ == '__main__':
    main()
