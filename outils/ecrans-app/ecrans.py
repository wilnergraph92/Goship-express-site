# -*- coding: utf-8 -*-
"""Dessine trois écrans de l'application GoShip Express, chacun dans son téléphone.

Le résultat part dans assets/img/ et sert la section « Vos colis dans votre
poche » de l'accueil du site. Tout est dessiné aux mesures de l'application :
les couleurs et les polices viennent de application-mobile/lib/theme.js, les
écrans reprennent app/colis/[id].jsx, app/(onglets)/index.jsx et
app/(onglets)/prealerte.jsx. Voir LISEZ-MOI.md.

    python3 outils/ecrans-app/ecrans.py
"""
import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

RACINE = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
APP = os.path.join(RACINE, 'application-mobile')
POLICES = os.path.join(APP, 'node_modules', '@expo-google-fonts')
SORTIE = os.path.join(RACINE, 'assets', 'img')

# L'écran est dessiné en points, comme dans l'application (390 x 843 points,
# la taille d'un téléphone courant), puis agrandi d'autant de fois.
LARGEUR, HAUTEUR, ECHELLE = 390, 843, 1.6
HAUT_SUR = 47          # zone de l'encoche, en haut
BAS_SUR = 24           # barre de geste, en bas

# lib/theme.js
NUIT, ACCENT, FOND, CARTE = '#061a3f', '#f4600d', '#f5f7fc', '#ffffff'
BORD, BORD_FORT, TEXTE, DOUX, FAIBLE = '#eef2f9', '#dfe6f3', '#0d1b3e', '#5b6782', '#8a93ac'
SUR_NUIT, BLEU = '#b9c6e4', '#2563eb'
VOILE = (255, 255, 255, 26)     # couleurs.voileClair

# Un statut = une couleur, un fond (aplati sur blanc) et une étape sur 7.
STATUTS = {
    'recu':         ('#0d2b6b', (232, 236, 243), '#0d2b6b', 1),
    'emballe':      ('#6d28d9', (238, 232, 250), '#7c3aed', 2),
    'embarque':     ('#1d4ed8', (228, 235, 252), '#2563eb', 3),
    'distribution': ('#92400e', (247, 238, 226), '#b45309', 4),
    'succursale':   ('#c2410c', (251, 234, 222), '#ea580c', 5),
    'livre':        ('#0a7d57', (226, 245, 238), '#0e9f6e', 7),
}
ETAPES = 7

FONTES = {}


def p(v):
    """Points de l'application → pixels de l'image."""
    return v * ECHELLE


def police(nom, taille):
    chemins = {
        'titre': 'archivo/800ExtraBold/Archivo_800ExtraBold.ttf',
        'titre_moyen': 'archivo/700Bold/Archivo_700Bold.ttf',
        'corps': 'manrope/500Medium/Manrope_500Medium.ttf',
        'gras': 'manrope/700Bold/Manrope_700Bold.ttf',
        'tres_gras': 'manrope/800ExtraBold/Manrope_800ExtraBold.ttf',
        'mono': 'ibm-plex-mono/500Medium/IBMPlexMono_500Medium.ttf',
        'mono_gras': 'ibm-plex-mono/600SemiBold/IBMPlexMono_600SemiBold.ttf',
    }
    cle = (nom, round(taille, 2))
    if cle not in FONTES:
        FONTES[cle] = ImageFont.truetype(os.path.join(POLICES, chemins[nom]), int(round(p(taille))))
    return FONTES[cle]


# --------------------------------------------------------------------------
# Écriture
# --------------------------------------------------------------------------

def ecrire(d, xy, texte, f, fill, ecart=0):
    """Texte, avec une chasse supplémentaire entre les lettres si besoin."""
    x, y = p(xy[0]), p(xy[1])
    if not ecart:
        d.text((x, y), texte, font=f, fill=fill)
        return
    for c in texte:
        d.text((x, y), c, font=f, fill=fill)
        x += d.textlength(c, font=f) + p(ecart)


def largeur_texte(d, texte, f, ecart=0):
    if not ecart:
        return d.textlength(texte, font=f) / ECHELLE
    return sum(d.textlength(c, font=f) + p(ecart) for c in texte) / ECHELLE - ecart


def centrer(d, y, texte, f, fill, x0=0, x1=LARGEUR, ecart=0):
    l = largeur_texte(d, texte, f, ecart)
    ecrire(d, (x0 + (x1 - x0 - l) / 2, y), texte, f, fill, ecart)


def etiquette(d, xy, texte, fill=FAIBLE):
    """Le composant Etiquette : mono 10, majuscules, très espacé."""
    ecrire(d, xy, texte.upper(), police('mono', 10), fill, 1.4)


def paragraphe(d, xy, texte, f, fill, largeur, interligne, lignes=99):
    """Coupe le texte à la largeur donnée et renvoie le bas atteint."""
    mots, ligne, sorties = texte.split(' '), '', []
    for mot in mots:
        essai = (ligne + ' ' + mot).strip()
        if largeur_texte(d, essai, f) > largeur and ligne:
            sorties.append(ligne)
            ligne = mot
        else:
            ligne = essai
    sorties.append(ligne)
    x, y = xy
    for i, l in enumerate(sorties[:lignes]):
        ecrire(d, (x, y + i * interligne), l, f, fill)
    return y + min(len(sorties), lignes) * interligne


# --------------------------------------------------------------------------
# Formes
# --------------------------------------------------------------------------

def rect(d, box, rayon, fond=None, bord=None, epaisseur=1):
    d.rounded_rectangle([p(box[0]), p(box[1]), p(box[2]), p(box[3])],
                        radius=p(rayon), fill=fond, outline=bord,
                        width=max(1, int(round(p(epaisseur)))))


def rect_voile(im, box, rayon, couleur):
    """Un fond semi-transparent. Il doit être fondu dans l'image : dessiné
    directement, il en remplacerait les pixels au lieu de les laisser paraître."""
    voile = Image.new('RGBA', im.size, (0, 0, 0, 0))
    rect(ImageDraw.Draw(voile), box, rayon, couleur)
    im.alpha_composite(voile)


def carte(im, box, rayon=22, fond=CARTE, bord=BORD, ombre=0.09):
    """Une carte de l'application : ombre douce, fond blanc, fin liseré."""
    if ombre:
        voile = Image.new('RGBA', im.size, (0, 0, 0, 0))
        dv = ImageDraw.Draw(voile)
        dv.rounded_rectangle([p(box[0] + 2), p(box[1] + 6), p(box[2] - 2), p(box[3] + 8)],
                             radius=p(rayon), fill=(6, 26, 63, int(255 * ombre)))
        im.alpha_composite(voile.filter(ImageFilter.GaussianBlur(p(9))))
    rect(ImageDraw.Draw(im), box, rayon, fond, bord)


def halo(im, cx, cy, r, couleur):
    """Le rond orange diffus des en-têtes bleu nuit."""
    voile = Image.new('RGBA', im.size, (0, 0, 0, 0))
    ImageDraw.Draw(voile).ellipse([p(cx - r), p(cy - r), p(cx + r), p(cy + r)], fill=couleur)
    im.alpha_composite(voile.filter(ImageFilter.GaussianBlur(p(10))))


def entete(im, hauteur, rayon=30):
    """Bandeau bleu nuit arrondi en bas, avec son halo orange."""
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([p(-rayon), p(-rayon), p(LARGEUR + rayon), p(hauteur)], radius=p(rayon), fill=NUIT)
    coupe = Image.new('RGBA', im.size, (0, 0, 0, 0))
    ImageDraw.Draw(coupe).rounded_rectangle(
        [p(-rayon), p(-rayon), p(LARGEUR + rayon), p(hauteur)], radius=p(rayon), fill=(255, 255, 255, 255))
    marque = Image.new('RGBA', im.size, (0, 0, 0, 0))
    halo(marque, LARGEUR + 4, -26, 104, (244, 96, 13, 44))
    im.alpha_composite(Image.composite(marque, Image.new('RGBA', im.size, (0, 0, 0, 0)), coupe.getchannel('A')))


def pastille(d, x, y, texte, statut, taille=11.5):
    """PuceStatut : le libellé du statut dans sa couleur."""
    couleur, fond = STATUTS[statut][0], STATUTS[statut][1]
    f = police('gras', taille)
    l = largeur_texte(d, texte, f)
    h = taille + 10
    rect(d, (x, y, x + l + 22, y + h), h / 2, fond)
    ecrire(d, (x + 11, y + 5 - taille * 0.05), texte, f, couleur)
    return l + 22


def frise(d, x, y, largeur, statut, hauteur=4):
    """Les sept segments de l'avancement du colis."""
    barre, etape = STATUTS[statut][2], STATUTS[statut][3]
    ecart, seg = 3, (largeur - 3 * (ETAPES - 1)) / ETAPES
    for n in range(ETAPES):
        cx = x + n * (seg + ecart)
        rect(d, (cx, y, cx + seg, y + hauteur), hauteur / 2, barre if n < etape else '#e6ebf5')


# --------------------------------------------------------------------------
# Icônes (les traits de Feather, redessinés)
# --------------------------------------------------------------------------

def icone(d, cx, cy, nom, couleur, t=9):
    """t = demi-taille en points. Épaisseur de trait comme Feather : 2/24 du corps."""
    e = max(1, int(round(p(t * 2 / 11))))
    X, Y, T = p(cx), p(cy), p(t)

    def ligne(x1, y1, x2, y2, larg=None):
        d.line([X + T * x1, Y + T * y1, X + T * x2, Y + T * y2], fill=couleur,
               width=larg or e, joint='curve')

    def boite(x1, y1, x2, y2, r=0.25, plein=False):
        d.rounded_rectangle([X + T * x1, Y + T * y1, X + T * x2, Y + T * y2], radius=T * r,
                            fill=couleur if plein else None, outline=None if plein else couleur, width=e)

    if nom == 'home':
        d.line([X - T, Y - T * .05, X, Y - T, X + T, Y - T * .05], fill=couleur, width=e, joint='curve')
        d.line([X - T * .72, Y - T * .3, X - T * .72, Y + T, X + T * .72, Y + T, X + T * .72, Y - T * .3],
               fill=couleur, width=e, joint='curve')
        ligne(-.26, 1, -.26, .25); ligne(.26, 1, .26, .25); ligne(-.26, .25, .26, .25)
    elif nom == 'package':
        d.line([X - T, Y - T * .5, X, Y - T, X + T, Y - T * .5, X + T, Y + T * .5,
                X, Y + T, X - T, Y + T * .5, X - T, Y - T * .5], fill=couleur, width=e, joint='curve')
        ligne(-1, -.5, 0, 0); ligne(1, -.5, 0, 0); ligne(0, 0, 0, 1)
        ligne(-.5, -.75, .5, -.25)
    elif nom == 'plus':
        ligne(-1, 0, 1, 0); ligne(0, -1, 0, 1)
    elif nom == 'file-text':
        d.line([X - T * .75, Y + T, X - T * .75, Y - T, X + T * .2, Y - T, X + T * .75, Y - T * .4,
                X + T * .75, Y + T, X - T * .75, Y + T], fill=couleur, width=e, joint='curve')
        ligne(-.4, .1, .4, .1); ligne(-.4, .55, .4, .55)
    elif nom == 'user':
        d.ellipse([X - T * .45, Y - T, X + T * .45, Y - T * .1], outline=couleur, width=e)
        d.arc([X - T * .85, Y + T * .1, X + T * .85, Y + T * 1.8], 180, 360, fill=couleur, width=e)
    elif nom == 'bell':
        d.arc([X - T * .78, Y - T, X + T * .78, Y + T * .55], 180, 360, fill=couleur, width=e)
        ligne(-.78, -.22, -.78, .5); ligne(.78, -.22, .78, .5)
        ligne(-.95, .5, .95, .5); d.ellipse([X - T * .22, Y + T * .6, X + T * .22, Y + T], outline=couleur, width=e)
    elif nom == 'map-pin':
        d.arc([X - T * .8, Y - T, X + T * .8, Y + T * .6], 155, 25, fill=couleur, width=e)
        d.line([X - T * .68, Y + T * .22, X, Y + T, X + T * .68, Y + T * .22], fill=couleur, width=e, joint='curve')
        d.ellipse([X - T * .3, Y - T * .5, X + T * .3, Y + T * .1], outline=couleur, width=e)
    elif nom == 'copy':
        boite(-1, -.45, .45, 1)
        d.line([X - T * .45, Y - T * .45, X - T * .45, Y - T, X + T, Y - T, X + T, Y + T * .45,
                X + T * .45, Y + T * .45], fill=couleur, width=e, joint='curve')
    elif nom == 'share-2':
        for cx2, cy2 in ((.7, -.85), (.7, .85), (-.75, 0)):
            d.ellipse([X + T * cx2 - T * .33, Y + T * cy2 - T * .33,
                       X + T * cx2 + T * .33, Y + T * cy2 + T * .33], outline=couleur, width=e)
        ligne(-.45, -.18, .4, -.65); ligne(-.45, .18, .4, .65)
    elif nom == 'arrow-left':
        ligne(1, 0, -1, 0); ligne(-1, 0, -.25, -.7); ligne(-1, 0, -.25, .7)
    elif nom == 'chevron-right':
        ligne(-.4, -.85, .45, 0); ligne(.45, 0, -.4, .85)
    elif nom == 'send':
        ligne(1, -1, -1, .05); ligne(1, -1, .1, 1); ligne(.1, 1, -.1, .05); ligne(-.1, .05, -1, .05)
    elif nom == 'message-circle':
        d.ellipse([X - T, Y - T, X + T, Y + T * .8], outline=couleur, width=e)
        d.polygon([(X - T * .55, Y + T * .5), (X - T * .05, Y + T * .5), (X - T * .8, Y + T * 1.25)], fill=couleur)
    elif nom == 'search':
        d.ellipse([X - T, Y - T, X + T * .45, Y + T * .45], outline=couleur, width=e)
        ligne(.3, .3, 1, 1)
    elif nom == 'camera':
        boite(-1, -.55, 1, .9, r=.3)
        d.line([X - T * .45, Y - T * .55, X - T * .2, Y - T, X + T * .2, Y - T, X + T * .45, Y - T * .55],
               fill=couleur, width=e, joint='curve')
        d.ellipse([X - T * .4, Y - T * .12, X + T * .4, Y + T * .68], outline=couleur, width=e)
    elif nom == 'maximize':        # cadre du scanner
        for sx in (-1, 1):
            for sy in (-1, 1):
                ligne(sx, sy, sx * .25, sy); ligne(sx, sy, sx, sy * .25)


# --------------------------------------------------------------------------
# Barres du système et de l'application
# --------------------------------------------------------------------------

def barre_etat(d, sombre=True):
    couleur = '#ffffff' if sombre else TEXTE
    ecrire(d, (26, 16), '9:41', police('tres_gras', 14), couleur)
    x = LARGEUR - 24
    rect(d, (x - 25, 18, x, 30), 3.5, bord=couleur, epaisseur=1.2)
    rect(d, (x + 1.5, 21.5, x + 3.5, 26.5), 1, couleur)
    rect(d, (x - 23, 20, x - 6, 28), 2, couleur)
    cx, cy = x - 38, 29                     # wifi
    for r in (11, 7.2, 3.4):
        d.arc([p(cx - r), p(cy - r), p(cx + r), p(cy + r)], 205, 335, fill=couleur,
              width=max(1, int(round(p(1.6)))))
    d.ellipse([p(cx - 1.1), p(cy - 1.1), p(cx + 1.1), p(cy + 1.1)], fill=couleur)
    for i, h in enumerate((4, 6.5, 9, 11.5)):   # réseau
        rect(d, (cx - 32 + i * 5, cy - h, cx - 32 + i * 5 + 3.2, cy), 1, couleur)


def barre_onglets(im, actif='index'):
    """La barre du bas : Accueil, Mes colis, le bouton orange, Factures, Compte."""
    d = ImageDraw.Draw(im)
    haut = HAUTEUR - (9 + 22 + 5 + 15 + max(BAS_SUR, 10))
    d.rectangle([0, p(haut), p(LARGEUR), p(HAUTEUR)], fill=CARTE)
    d.line([0, p(haut), p(LARGEUR), p(haut)], fill='#e9eef7', width=max(1, int(round(p(1)))))
    onglets = [('index', 'home', 'Accueil'), ('colis', 'package', 'Mes colis'),
               ('factures', 'file-text', 'Factures'), ('compte', 'user', 'Compte')]
    f = police('gras', 11)
    positions = (LARGEUR * 0.14, LARGEUR * 0.335, LARGEUR * 0.665, LARGEUR * 0.86)
    for (nom, ic, libelle), cx in zip(onglets, positions):
        couleur = ACCENT if nom == actif else FAIBLE
        icone(d, cx, haut + 20, ic, couleur, 11)
        centrer(d, haut + 36, libelle, f, couleur, cx - 40, cx + 40)
    # Bouton central : pré-alerte
    cx, cy = LARGEUR / 2, haut + 7
    voile = Image.new('RGBA', im.size, (0, 0, 0, 0))
    ImageDraw.Draw(voile).rounded_rectangle(
        [p(cx - 29), p(cy - 22), p(cx + 29), p(cy + 36)], radius=p(20), fill=(244, 96, 13, 90))
    im.alpha_composite(voile.filter(ImageFilter.GaussianBlur(p(8))))
    rect(d, (cx - 29, cy - 29, cx + 29, cy + 29), 20, ACCENT)
    icone(d, cx, cy, 'plus', '#ffffff', 12.5)
    # Barre de geste
    rect(d, (LARGEUR / 2 - 65, HAUTEUR - 10, LARGEUR / 2 + 65, HAUTEUR - 6), 2, '#c7cede')


# --------------------------------------------------------------------------
# Les trois écrans
# --------------------------------------------------------------------------

def neuf():
    return Image.new('RGBA', (int(p(LARGEUR)), int(p(HAUTEUR))), FOND)


def ecran_accueil():
    """app/(onglets)/index.jsx — l'adresse de Miami, les compteurs, les colis."""
    im = neuf()
    haut_entete = 234
    entete(im, haut_entete)
    d = ImageDraw.Draw(im)
    barre_etat(d)

    logo = Image.open(os.path.join(APP, 'assets', 'logo-goship-blanc.png')).convert('RGBA')
    logo = logo.resize((int(p(108)), int(p(108) * logo.height / logo.width)), Image.LANCZOS)
    im.alpha_composite(logo, (int(p(22)), int(p(63))))

    rect_voile(im, (LARGEUR - 66, 63, LARGEUR - 22, 107), 14, VOILE)
    icone(d, LARGEUR - 44, 85, 'bell', '#ffffff', 9.5)
    d.ellipse([p(LARGEUR - 34), p(70), p(LARGEUR - 25), p(79)], fill=ACCENT, outline=NUIT,
              width=max(1, int(round(p(2)))))

    ecrire(d, (22, 110), 'Bonjour', police('corps', 13), SUR_NUIT)
    ecrire(d, (22, 130), 'Marie-Ange Dorvil', police('titre', 25), '#ffffff')
    l = largeur_texte(d, 'GSE-4323', police('mono', 12), 0.4)
    rect_voile(im, (22, 168, 22 + l + 42, 199), 15.5, VOILE)
    icone(d, 42, 183, 'user', ACCENT, 6.5)
    ecrire(d, (55, 176), 'GSE-4323', police('mono', 12), '#ffffff', 0.4)

    # Carte « Mon adresse à Miami »
    y = haut_entete - 20
    lignes = ['Marie-Ange Dorvil · GSE-4323', '8140 NW 74th Ave, Unit 3 — APT-46780',
              'Medley, Florida 33166, USA']
    bas = y + 17 + 12 + 9 + len(lignes) * 21 + 14 + 46 + 17
    carte(im, (18, y, LARGEUR - 18, bas), 22)
    d = ImageDraw.Draw(im)
    etiquette(d, (35, y + 17), 'Mon adresse à Miami')
    icone(d, LARGEUR - 35 - 8, y + 21, 'map-pin', ACCENT, 8)
    f = police('gras', 14)
    for i, ligne in enumerate(lignes):
        ecrire(d, (35, y + 42 + i * 21), ligne, f, TEXTE)
    by = bas - 17 - 46
    rect(d, (35, by, LARGEUR - 35 - 112, by + 46), 16, ACCENT)
    icone(d, 35 + 34, by + 23, 'copy', '#ffffff', 9)
    ecrire(d, (35 + 49, by + 13.5), 'Copier', police('tres_gras', 15.5), '#ffffff')
    rect(d, (LARGEUR - 35 - 103, by, LARGEUR - 35, by + 46), 16, CARTE, BORD_FORT, 1.5)
    icone(d, LARGEUR - 35 - 82, by + 23, 'share-2', TEXTE, 9)
    ecrire(d, (LARGEUR - 35 - 67, by + 13.5), 'Partager', police('tres_gras', 15.5), TEXTE)

    # Deux compteurs
    y = bas + 14
    for i, (nombre, mot, ic, couleur, fond) in enumerate(
            [('2', 'en route', 'send', BLEU, (228, 235, 252)),
             ('1', 'à retirer', 'package', ACCENT, (253, 235, 224))]):
        x0 = 18 + i * ((LARGEUR - 36 - 11) / 2 + 11)
        x1 = x0 + (LARGEUR - 36 - 11) / 2
        carte(im, (x0, y, x1, y + 64), 18)
        d = ImageDraw.Draw(im)
        rect(d, (x0 + 13, y + 13, x0 + 51, y + 51), 13, fond)
        icone(d, x0 + 32, y + 32, ic, couleur, 9)
        ecrire(d, (x0 + 62, y + 13), nombre, police('titre', 19), TEXTE)
        ecrire(d, (x0 + 62, y + 38), mot, police('corps', 12), DOUX)

    # Derniers mouvements
    y += 64 + 20
    ecrire(d, (18, y), 'Derniers mouvements', police('titre', 17), TEXTE)
    t = 'Tout voir'
    ecrire(d, (LARGEUR - 18 - largeur_texte(d, t, police('gras', 13)), y + 4), t, police('gras', 13), ACCENT)

    y += 22 + 11
    colis = [('GSE-1042-HT', 'Baskets et sac à dos', 'Amazon · 6,4 lb · Aérien', 'Succursale', 'succursale'),
             ('GSE-1039-HT', 'Téléphone reconditionné', 'eBay · 1,2 lb · Aérien', 'Embarqué', 'embarque')]
    for numero, quoi, details, libelle, statut in colis:
        carte(im, (18, y, LARGEUR - 18, y + 111), 20)
        d = ImageDraw.Draw(im)
        ecrire(d, (33, y + 16), numero, police('mono', 13), TEXTE, 0.4)
        l = largeur_texte(d, libelle, police('gras', 11.5)) + 22
        pastille(d, LARGEUR - 33 - l, y + 13, libelle, statut)
        ecrire(d, (33, y + 40), quoi, police('gras', 14.5), TEXTE)
        ecrire(d, (33, y + 62), details, police('corps', 12.5), DOUX)
        frise(d, 33, y + 88, LARGEUR - 66, statut)
        y += 111 + 11

    # Bande « Annoncer un achat »
    rect(d, (18, y, LARGEUR - 18, y + 66), 20, NUIT)
    rect_voile(im, (32, y + 14, 70, y + 52), 13, (244, 96, 13, 51))
    icone(d, 51, y + 33, 'bell', '#ff8b45', 9.5)
    ecrire(d, (82, y + 16), 'Annoncer un achat', police('gras', 14), '#ffffff')
    ecrire(d, (82, y + 37), 'Pré-alerte : votre colis est traité plus vite',
           police('corps', 12.5), SUR_NUIT)
    icone(d, LARGEUR - 34, y + 33, 'chevron-right', '#ffffff', 10)

    barre_onglets(im, 'index')
    return im


def ecran_colis():
    """app/colis/[id].jsx — le statut, l'avancement et les étapes d'un colis."""
    im = neuf()
    haut_entete = 153
    entete(im, haut_entete, rayon=0)
    d = ImageDraw.Draw(im)
    barre_etat(d)
    rect_voile(im, (18, 63, 62, 107), 14, VOILE)
    icone(d, 40, 85, 'arrow-left', '#ffffff', 9)
    centrer(d, 78, 'GSE-1042-HT', police('mono', 14), '#ffffff', ecart=0.4)
    rect_voile(im, (LARGEUR - 62, 63, LARGEUR - 18, 107), 14, VOILE)
    icone(d, LARGEUR - 40, 85, 'share-2', '#ffffff', 8.5)

    # Carte du statut
    y = haut_entete - 34
    bas = y + 18 + 46 + 16 + 29 + 18
    carte(im, (18, y, LARGEUR - 18, bas), 24)
    d = ImageDraw.Draw(im)
    rect(d, (36, y + 18, 82, y + 64), 16, STATUTS['succursale'][1])
    icone(d, 59, y + 41, 'package', STATUTS['succursale'][0], 10)
    ecrire(d, (95, y + 22), 'Transféré à la succursale', police('titre', 18), TEXTE)
    ecrire(d, (95, y + 47), 'il y a 2 h · Port-au-Prince', police('corps', 12.5), DOUX)
    ligne_y = y + 18 + 46 + 16
    ecrire(d, (36, ligne_y), 'ÉTAPE 5 SUR 7', police('mono', 11.5), FAIBLE, 0.6)
    t = 'Succursale'
    ecrire(d, (LARGEUR - 36 - largeur_texte(d, t, police('gras', 12)), ligne_y),
           t, police('gras', 12), STATUTS['succursale'][0])
    frise(d, 36, ligne_y + 24, LARGEUR - 72, 'succursale', 5)

    # Quatre informations
    y = bas + 14
    infos = [('Poids', '6,4 lb'), ('Service', 'Aérien'), ('Magasin', 'Amazon'), ('Destination', 'Port-au-Prince')]
    lg = (LARGEUR - 36 - 10) / 2
    for i, (cle, valeur) in enumerate(infos):
        x0 = 18 + (i % 2) * (lg + 10)
        y0 = y + (i // 2) * (58 + 10)
        carte(im, (x0, y0, x0 + lg, y0 + 58), 16, ombre=0.06)
        d = ImageDraw.Draw(im)
        etiquette(d, (x0 + 12, y0 + 12), cle)
        ecrire(d, (x0 + 12, y0 + 29), valeur, police('gras', 14.5), TEXTE)

    # Étapes du colis
    y = y + 2 * 58 + 10 + 16
    etapes = [('Transféré à la succursale', 'Hier, 14:05 · Port-au-Prince', 'succursale'),
              ('En distribution', 'Hier, 07:30 · Port-au-Prince', 'distribution'),
              ('Embarqué', '17 sept., 08:20 · Miami', 'embarque'),
              ('Emballé', '16 sept., 11:15 · Medley', 'emballe'),
              ('Reçu à Miami', '15 sept., 16:42 · Medley', 'recu')]
    bas = y + 18 + 20 + 14 + len(etapes) * 46 + 4
    carte(im, (18, y, LARGEUR - 18, bas), 22)
    d = ImageDraw.Draw(im)
    ecrire(d, (36, y + 18), 'Étapes du colis', police('titre', 15.5), TEXTE)
    ey = y + 18 + 20 + 14
    for i, (titre, quand, statut) in enumerate(etapes):
        cx = 36 + 6.5
        if i < len(etapes) - 1:
            rect(d, (cx - 1, ey + 15, cx + 1, ey + 44), 1, '#edf1f8')
        d.ellipse([p(cx - 6.5), p(ey + 2), p(cx + 6.5), p(ey + 15)], fill=STATUTS[statut][2])
        ecrire(d, (36 + 27, ey), titre, police('gras', 13.5), TEXTE)
        ecrire(d, (36 + 27, ey + 19), quand, police('corps', 12), DOUX)
        ey += 46

    # Barre du bas : WhatsApp et agences
    h = 14 + 54 + max(BAS_SUR, 14)
    d.rectangle([0, p(HAUTEUR - h), p(LARGEUR), p(HAUTEUR)], fill=CARTE)
    d.line([0, p(HAUTEUR - h), p(LARGEUR), p(HAUTEUR - h)], fill='#e9eef7', width=max(1, int(round(p(1)))))
    by = HAUTEUR - h + 14
    rect(d, (18, by, LARGEUR - 18 - 62, by + 54), 16, NUIT)
    cx = (18 + LARGEUR - 18 - 62) / 2
    t = 'Écrire sur WhatsApp'
    l = largeur_texte(d, t, police('tres_gras', 15.5)) + 27
    icone(d, cx - l / 2 + 9, by + 27, 'message-circle', '#ffffff', 9)
    ecrire(d, (cx - l / 2 + 27, by + 17), t, police('tres_gras', 15.5), '#ffffff')
    rect(d, (LARGEUR - 18 - 52, by + 1, LARGEUR - 18, by + 53), 16, CARTE, BORD_FORT, 1.5)
    icone(d, LARGEUR - 44, by + 27, 'map-pin', TEXTE, 10)
    rect(d, (LARGEUR / 2 - 65, HAUTEUR - 10, LARGEUR / 2 + 65, HAUTEUR - 6), 2, '#c7cede')
    return im


def ecran_prealerte():
    """app/(onglets)/prealerte.jsx — annoncer un achat avant son arrivée à Miami."""
    im = neuf()
    haut_entete = 164
    entete(im, haut_entete, rayon=28)
    d = ImageDraw.Draw(im)
    barre_etat(d)
    ecrire(d, (20, 63), 'Nouvelle pré-alerte', police('titre', 21), '#ffffff')
    paragraphe(d, (20, 102), 'Annoncez votre achat : à son arrivée à Miami, votre colis est reconnu '
                             'tout de suite.', police('corps', 12.5), SUR_NUIT, LARGEUR - 40, 19)

    def champ(y, cle, valeur, gris=False, x0=18, x1=LARGEUR - 18):
        etiquette(d, (x0, y), cle)
        rect(d, (x0, y + 22, x1, y + 76), 15, CARTE, BORD)
        ecrire(d, (x0 + 16, y + 40), valeur, police('corps', 15.5), FAIBLE if gris else TEXTE)
        return y + 76

    y = haut_entete + 18
    y = champ(y, 'Magasin', 'Amazon')

    y += 9                                   # suggestions
    x = 18
    for mot in ('SHEIN', 'Walmart', 'eBay', 'Temu'):
        l = largeur_texte(d, mot, police('gras', 12.5)) + 26
        rect(d, (x, y, x + l, y + 34), 17, '#eaeff8')
        ecrire(d, (x + 13, y + 8), mot, police('gras', 12.5), DOUX)
        x += l + 8
    y += 34 + 13

    y = champ(y, 'Contenu', 'Baskets et sac à dos')
    y += 13

    etiquette(d, (18, y), 'Numéro de suivi du magasin')
    rect(d, (18, y + 22, LARGEUR - 18 - 63, y + 76), 15, CARTE, BORD)
    ecrire(d, (34, y + 40), 'TBA123456789000', police('corps', 15.5), TEXTE)
    rect(d, (LARGEUR - 18 - 54, y + 22, LARGEUR - 18, y + 76), 15, ACCENT)
    icone(d, LARGEUR - 45, y + 49, 'maximize', '#ffffff', 10)
    y += 76 + 13

    etiquette(d, (18, y), 'Service')
    rect(d, (18, y + 22, LARGEUR - 18, y + 76), 15, '#e9eef7')
    milieu = LARGEUR / 2
    rect(d, (23, y + 27, milieu - 2.5, y + 71), 11, CARTE)
    centrer(d, y + 40, 'Aérien', police('tres_gras', 14.5), TEXTE, 23, milieu - 2.5)
    centrer(d, y + 40, 'Maritime', police('gras', 14.5), DOUX, milieu + 2.5, LARGEUR - 23)
    y += 76 + 13

    # Photo du reçu : cadre en pointillés
    rect(d, (18, y, LARGEUR - 18, y + 72), 16, CARTE)
    pointilles(d, (18, y, LARGEUR - 18, y + 72), 16, '#c9d4ea')
    rect_voile(im, (33, y + 15, 75, y + 57), 14, (244, 96, 13, 33))
    icone(d, 54, y + 36, 'camera', ACCENT, 9)
    ecrire(d, (88, y + 27), 'Ajouter une photo', police('gras', 14), TEXTE)
    y += 72 + 13

    rect(d, (18, y, LARGEUR - 18, y + 54), 16, ACCENT)
    centrer(d, y + 17, 'Envoyer la pré-alerte', police('tres_gras', 15.5), '#ffffff', 18, LARGEUR - 18)

    barre_onglets(im, 'prealerte')
    return im


def pointilles(d, box, rayon, couleur, trait=5, vide=4, epaisseur=1.5):
    """Le bord tireté du cadre « Ajouter une photo »."""
    x0, y0, x1, y1 = box
    e = max(1, int(round(p(epaisseur))))
    for (ax, ay, bx, by) in ((x0 + rayon, y0, x1 - rayon, y0), (x0 + rayon, y1, x1 - rayon, y1),
                             (x0, y0 + rayon, x0, y1 - rayon), (x1, y0 + rayon, x1, y1 - rayon)):
        long = max(abs(bx - ax), abs(by - ay))
        n = int(long // (trait + vide))
        for i in range(n + 1):
            t0 = i * (trait + vide)
            t1 = min(t0 + trait, long)
            ux, uy = (1, 0) if bx != ax else (0, 1)
            d.line([p(ax + ux * t0), p(ay + uy * t0), p(ax + ux * t1), p(ay + uy * t1)],
                   fill=couleur, width=e)
    for (cx, cy, d0) in ((x0 + rayon, y0 + rayon, 180), (x1 - rayon, y0 + rayon, 270),
                         (x1 - rayon, y1 - rayon, 0), (x0 + rayon, y1 - rayon, 90)):
        for a in range(0, 90, 18):
            d.arc([p(cx - rayon), p(cy - rayon), p(cx + rayon), p(cy + rayon)],
                  d0 + a, d0 + a + 11, fill=couleur, width=e)


# --------------------------------------------------------------------------
# Le téléphone autour de l'écran
# --------------------------------------------------------------------------

BORDURE = 11          # épaisseur du cadre, en points
RAYON_EXT = 46


def telephone(ecran):
    """Pose l'écran dans un boîtier sombre, coins arrondis et fond transparent."""
    b = int(round(p(BORDURE)))
    larg, haut = ecran.width + 2 * b, ecran.height + 2 * b
    im = Image.new('RGBA', (larg, haut), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([0, 0, larg - 1, haut - 1], radius=p(RAYON_EXT), fill='#0a1430')
    d.rounded_rectangle([0, 0, larg - 1, haut - 1], radius=p(RAYON_EXT), outline='#3c4c78',
                        width=max(1, int(round(p(1.6)))))
    d.rounded_rectangle([b - p(1.6), b - p(1.6), larg - b + p(1.6), haut - b + p(1.6)],
                        radius=p(RAYON_EXT - BORDURE + 2), outline='#050d20',
                        width=max(1, int(round(p(1.6)))))

    coins = Image.new('L', ecran.size, 0)
    ImageDraw.Draw(coins).rounded_rectangle([0, 0, ecran.width - 1, ecran.height - 1],
                                            radius=p(RAYON_EXT - BORDURE), fill=255)
    ecran = ecran.copy()
    ecran.putalpha(coins)
    im.alpha_composite(ecran, (b, b))

    # Objectif avant, percé dans l'écran
    cx, cy, r = larg / 2, b + p(20), p(5.4)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill='#060d1e')
    d.ellipse([cx - r * .45, cy - r * .45, cx + r * .45, cy + r * .45], fill='#16244a')

    # Boutons de tranche
    for y0, y1 in ((140, 172), (186, 218)):
        d.rounded_rectangle([0, p(y0), p(3), p(y1)], radius=p(1.5), fill='#25315a')
    d.rounded_rectangle([larg - p(3), p(200), larg, p(252)], radius=p(1.5), fill='#25315a')
    return im


def main():
    ecrans = [('app-ecran-colis', ecran_colis), ('app-ecran-accueil', ecran_accueil),
              ('app-ecran-prealerte', ecran_prealerte)]
    for nom, faire in ecrans:
        im = telephone(faire().convert('RGB').convert('RGBA'))
        chemin = os.path.join(SORTIE, nom + '.webp')
        im.save(chemin, 'WEBP', quality=86, method=6)
        print('%-22s %4d x %4d  %5d ko' % (nom + '.webp', im.width, im.height,
                                           os.path.getsize(chemin) // 1024))


if __name__ == '__main__':
    main()
