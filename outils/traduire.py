#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Génère les versions anglaise, espagnole et créole du site Goship Express.

Les pages françaises, à la racine du site, font référence. Chaque texte y est
recherché dans les dictionnaires outils/traductions/<langue>.json (clé : texte
français, valeur : traduction), puis les pages traduites sont écrites dans les
dossiers en/, es/ et ht/. Le sélecteur de langue de chaque page (françaises
comprises) est régénéré au passage.

Dans les textes, les repères {1}…{/1} entourent une mise en forme (gras, lien,
couleur) et {br} marque un retour à la ligne : une traduction doit reprendre
exactement les mêmes repères.

Usage :
    python3 outils/traduire.py               génère les pages traduites
    python3 outils/traduire.py --manquants   liste les textes sans traduction
"""
import glob
import hashlib
import html
import json
import os
import re
import sys
from collections import Counter

RACINE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOSSIER_TRAD = os.path.join(RACINE, 'outils', 'traductions')

# Adresse publique du site, par ex. 'https://www.goshipexpress.com'.
# Une fois renseignée, les balises hreflang et le fichier sitemap.xml sont générés.
SITE_URL = ''

LANGUES = {
    'fr': {'dossier': '', 'nom': 'Français', 'drapeau': 'fr', 'libelle': 'Langue',
           'aria': 'Langue : Français', 'locale': 'fr_FR'},
    'en': {'dossier': 'en', 'nom': 'English', 'drapeau': 'gb', 'libelle': 'Language',
           'aria': 'Language: English', 'locale': 'en_US'},
    'es': {'dossier': 'es', 'nom': 'Español', 'drapeau': 'es', 'libelle': 'Idioma',
           'aria': 'Idioma: Español', 'locale': 'es_DO'},
    'ht': {'dossier': 'ht', 'nom': 'Kreyòl', 'drapeau': 'ht', 'libelle': 'Lang',
           'aria': 'Lang: Kreyòl ayisyen', 'locale': 'ht_HT'},
}
ORDRE_MENU = ['en', 'es', 'fr', 'ht']
TRADUITES = ['en', 'es', 'ht']
# Pages françaises non traduites : la page 404 (traitée à part) et le tableau
# de bord de l'équipe.
NON_TRADUITES = {'404.html', 'admin.html'}

# --------------------------------------------------------------------------
# Découpage HTML
# --------------------------------------------------------------------------
TOKEN_RE = re.compile(r'<!--.*?-->|<script\b.*?</script\s*>|<style\b.*?</style\s*>|<[^>]*>|[^<]+', re.S | re.I)
TAGNAME_RE = re.compile(r'<\s*(/?)\s*([a-zA-Z][a-zA-Z0-9-]*)')
VIDES = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'source', 'track', 'wbr'}
EN_LIGNE = {'a', 'abbr', 'b', 'br', 'cite', 'code', 'em', 'i', 'mark', 'q', 's', 'small', 'span',
            'strong', 'sub', 'sup', 'time', 'u'}
LETTRE = re.compile(r'[^\W\d_]')
REPERE = re.compile(r'\{(/?\d+|br)\}')
ESPACES = ' \t\r\n'
ATTRS_TRADUITS = ('alt', 'placeholder', 'aria-label', 'title')
META_TRADUITES = ('description', 'og:title', 'og:description', 'twitter:title', 'twitter:description')


def decouper(src):
    jetons = []
    for m in TOKEN_RE.finditer(src):
        brut = m.group(0)
        if brut.startswith('<!--'):
            jetons.append(('commentaire', brut, None))
        elif brut[:7].lower() == '<script':
            jetons.append(('script', brut, 'script'))
        elif brut[:6].lower() == '<style':
            jetons.append(('style', brut, 'style'))
        elif brut.startswith(('<!', '<?')):
            jetons.append(('autre', brut, None))
        elif brut.startswith('<'):
            t = TAGNAME_RE.match(brut)
            nom = t.group(2).lower()
            if t.group(1):
                jetons.append(('fin', brut, nom))
            elif nom in VIDES or brut.endswith('/>'):
                jetons.append(('vide', brut, nom))
            else:
                jetons.append(('debut', brut, nom))
        else:
            jetons.append(('texte', brut, None))
    if ''.join(j[1] for j in jetons) != src:
        raise ValueError('découpage HTML incomplet')
    return jetons


def apparier(jetons):
    """Associe chaque balise ouvrante à sa balise fermante (et inversement)."""
    fin_de, debut_de, pile = {}, {}, []
    for i, (genre, _, nom) in enumerate(jetons):
        if genre == 'debut':
            pile.append(i)
        elif genre == 'fin':
            while pile:
                j = pile.pop()
                if jetons[j][2] == nom:
                    fin_de[j], debut_de[i] = i, j
                    break
    return fin_de, debut_de


def zones_ignorees(jetons, fin_de):
    """Jetons à ne pas traduire : translate="no", sélecteur de langue, scripts."""
    ignore = [False] * len(jetons)
    i = 0
    while i < len(jetons):
        genre, brut, _ = jetons[i]
        if genre == 'debut' and re.search(r'\stranslate="no"', brut) and i in fin_de:
            for k in range(i, fin_de[i] + 1):
                ignore[k] = True
            i = fin_de[i] + 1
            continue
        if genre == 'commentaire' and brut.startswith('<!--langues:'):
            k = i
            while k < len(jetons) and jetons[k][1] != '<!--/langues-->':
                ignore[k] = True
                k += 1
            i = k + 1
            continue
        if genre in ('script', 'style'):
            ignore[i] = True
        i += 1
    return ignore


def texte_de(jetons, indices):
    return html.unescape(''.join(jetons[i][1] for i in indices if jetons[i][0] == 'texte'))


def segments(jetons, fin_de, debut_de, ignore):
    """Repère les segments traduisibles : texte + balises en ligne équilibrées."""
    resultats, courant = [], []

    def vider():
        if courant:
            resultats.extend(scinder(list(courant)))
        courant.clear()

    def scinder(seg):
        dedans = set(seg)
        # une balise ouverte dans le segment mais fermée après est une frontière
        coupures = {i for i in seg if jetons[i][0] == 'debut' and fin_de.get(i) not in dedans}
        morceaux, m = [], []
        for i in seg:
            if i in coupures:
                morceaux.append(m)
                m = []
            else:
                m.append(i)
        morceaux.append(m)
        out = []
        for m in morceaux:
            out.extend(affiner(m))
        return out

    def affiner(seg):
        seg = rogner(seg)
        if not seg or not LETTRE.search(texte_de(jetons, seg)):
            return []
        # Pas de texte au premier niveau : chaque élément devient son propre segment
        niveau, texte_haut, elements, debut = 0, False, [], None
        for i in seg:
            genre = jetons[i][0]
            if genre == 'debut':
                if niveau == 0:
                    debut = i
                niveau += 1
            elif genre == 'fin':
                niveau -= 1
                if niveau == 0:
                    elements.append(seg[seg.index(debut):seg.index(i) + 1])
            elif genre == 'texte' and niveau == 0 and jetons[i][1].strip(ESPACES):
                texte_haut = True
        if not texte_haut and len(elements) > 1:
            out = []
            for e in elements:
                out.extend(affiner(e))
            return out
        return [seg]

    def rogner(seg):
        change = True
        while change and seg:
            change = False
            g0, gN = jetons[seg[0]][0], jetons[seg[-1]][0]
            if g0 == 'texte' and not jetons[seg[0]][1].strip(ESPACES):
                seg, change = seg[1:], True
            elif gN == 'texte' and not jetons[seg[-1]][1].strip(ESPACES):
                seg, change = seg[:-1], True
            elif g0 == 'vide':
                seg, change = seg[1:], True
            elif gN == 'vide':
                seg, change = seg[:-1], True
            elif g0 == 'debut' and fin_de.get(seg[0]) not in seg:
                seg, change = seg[1:], True
            elif gN == 'fin' and debut_de.get(seg[-1]) not in seg:
                seg, change = seg[:-1], True
            elif g0 == 'debut' and fin_de.get(seg[0]) == seg[-1]:
                seg, change = seg[1:-1], True
            elif g0 == 'debut' and not LETTRE.search(texte_de(jetons, seg[:seg.index(fin_de[seg[0]]) + 1])):
                seg, change = seg[seg.index(fin_de[seg[0]]) + 1:], True
            elif gN == 'fin' and not LETTRE.search(texte_de(jetons, seg[seg.index(debut_de[seg[-1]]):])):
                seg, change = seg[:seg.index(debut_de[seg[-1]])], True
        return seg

    for i, (genre, _, nom) in enumerate(jetons):
        if ignore[i]:
            vider()
        elif genre == 'texte':
            courant.append(i)
        elif genre in ('debut', 'vide') and nom in EN_LIGNE:
            courant.append(i)
        elif genre == 'fin' and nom in EN_LIGNE and debut_de.get(i) in courant:
            courant.append(i)
        else:
            vider()
    vider()
    return resultats


def construire(jetons, seg, debut_de, bruts=None):
    """Texte du segment avec ses repères, et correspondance repère -> balise.

    bruts : balises déjà traduites (attributs), utilisées à la place des originales."""
    bruts = bruts or [j[1] for j in jetons]
    parties, numeros, balises, n = [], {}, {}, 0
    for i in seg:
        genre, brut, nom = jetons[i]
        if genre == 'texte':
            parties.append(html.unescape(brut))
        elif genre == 'vide':
            parties.append('{br}')
            balises.setdefault('{br}', bruts[i])
        elif genre == 'debut':
            n += 1
            numeros[i] = n
            parties.append('{%d}' % n)
            balises['{%d}' % n] = bruts[i]
        elif debut_de.get(i) in numeros:
            r = '{/%d}' % numeros[debut_de[i]]
            parties.append(r)
            balises[r] = bruts[i]
    cle = re.sub(r'[ \t\r\n]+', ' ', ''.join(parties)).strip(ESPACES)
    premier, dernier = jetons[seg[0]][1], jetons[seg[-1]][1]
    avant = premier[:len(premier) - len(premier.lstrip(ESPACES))] if jetons[seg[0]][0] == 'texte' else ''
    apres = dernier[len(dernier.rstrip(ESPACES)):] if jetons[seg[-1]][0] == 'texte' else ''
    return cle, balises, avant, apres


def reperes_valides(cle, traduction):
    if Counter(REPERE.findall(cle)) != Counter(REPERE.findall(traduction)):
        return False
    ouverts = []
    for r in REPERE.findall(traduction):
        if r == 'br':
            continue
        if r.startswith('/'):
            if not ouverts or ouverts.pop() != r[1:]:
                return False
        else:
            ouverts.append(r)
    return not ouverts


def rendre(traduction, balises):
    out, pos = [], 0
    for m in REPERE.finditer(traduction):
        out.append(html.escape(traduction[pos:m.start()], quote=False))
        out.append(balises[m.group(0)])
        pos = m.end()
    out.append(html.escape(traduction[pos:], quote=False))
    return ''.join(out)


def normaliser(valeur):
    return re.sub(r'[ \t\r\n]+', ' ', html.unescape(valeur)).strip(ESPACES)


def attributs_traduisibles(brut, nom):
    """Liste (attribut, valeur brute) des attributs à traduire dans une balise."""
    trouves = []
    for attr in ATTRS_TRADUITS:
        m = re.search(r'\s%s="([^"]*)"' % re.escape(attr), brut)
        if m:
            trouves.append((attr, m.group(1)))
    if nom == 'meta':
        m = re.search(r'\s(?:name|property)="([^"]*)"', brut)
        c = re.search(r'\scontent="([^"]*)"', brut)
        if m and c and m.group(1) in META_TRADUITES:
            trouves.append(('content', c.group(1)))
    return [(a, v) for a, v in trouves if LETTRE.search(html.unescape(v))]


# --------------------------------------------------------------------------
# Analyse d'une page
# --------------------------------------------------------------------------
class Page:
    def __init__(self, nom, src):
        self.nom = nom
        self.src = src
        self.jetons = decouper(src)
        self.fin_de, self.debut_de = apparier(self.jetons)
        self.ignore = zones_ignorees(self.jetons, self.fin_de)
        self.segments = segments(self.jetons, self.fin_de, self.debut_de, self.ignore)

    def textes(self):
        """Tous les textes traduisibles de la page, dans l'ordre de lecture."""
        vus, out = set(), []

        def ajouter(t):
            if t and t not in vus:
                vus.add(t)
                out.append(t)

        segs = {s[0]: s for s in self.segments}
        for i, (genre, brut, nom) in enumerate(self.jetons):
            if self.ignore[i]:
                if genre == 'script' and 'application/ld+json' in brut:
                    ajouter(self.description_jsonld(brut))
                continue
            if genre in ('debut', 'vide'):
                for _, v in attributs_traduisibles(brut, nom):
                    ajouter(normaliser(v))
            if i in segs:
                ajouter(construire(self.jetons, segs[i], self.debut_de)[0])
        return out

    @staticmethod
    def description_jsonld(brut):
        m = re.search(r'>(.*)</script', brut, re.S)
        try:
            return json.loads(m.group(1)).get('description', '')
        except (ValueError, AttributeError):
            return ''

    def traduire(self, dico, manquants):
        jetons, out = self.jetons, [j[1] for j in self.jetons]

        def chercher(texte):
            t = dico.get(texte)
            if t is None:
                manquants.add((texte, self.nom))
                return texte
            return t

        # 1. Attributs (alt, placeholder, aria-label…), métadonnées et JSON-LD
        for i, (genre, brut, nom) in enumerate(jetons):
            if self.ignore[i]:
                if genre == 'script' and 'application/ld+json' in brut:
                    desc = self.description_jsonld(brut)
                    if desc:
                        m = re.search(r'>(.*)</script', brut, re.S)
                        data = json.loads(m.group(1))
                        data['description'] = chercher(desc)
                        out[i] = brut[:m.start(1)] + json.dumps(data, ensure_ascii=False) + brut[m.end(1):]
                continue
            if genre in ('debut', 'vide'):
                nouveau = out[i]
                for attr, valeur in attributs_traduisibles(brut, nom):
                    trad = chercher(normaliser(valeur))
                    nouveau = nouveau.replace(f' {attr}="{valeur}"',
                                              f' {attr}="{html.escape(trad, quote=True).replace("&#x27;", chr(39))}"', 1)
                out[i] = nouveau

        # 2. Textes (avec leurs balises en ligne, déjà traduites ci-dessus)
        bruts = list(out)
        for seg in self.segments:
            cle, balises, avant, apres = construire(jetons, seg, self.debut_de, bruts)
            trad = dico.get(cle)
            if trad is None:
                manquants.add((cle, self.nom))
                continue
            if not reperes_valides(cle, trad):
                print(f'  ! repères différents, texte laissé en français ({self.nom}) : {cle[:70]}')
                continue
            out[seg[0]] = avant + rendre(trad, balises) + apres
            for i in seg[1:]:
                out[i] = ''
        return ''.join(out)


# --------------------------------------------------------------------------
# Sélecteur de langue, chemins, métadonnées
# --------------------------------------------------------------------------
def url_page(langue, page):
    d = LANGUES[langue]['dossier']
    return (d + '/' if d else '') + page


def selecteur(langue, page, variante, absolu=False):
    L = LANGUES[langue]
    base = '/' if absolu else ('../' if L['dossier'] else '')

    def drapeau(l):
        return (f'<img class="gs-flag" src="{base}assets/img/drapeaux/{LANGUES[l]["drapeau"]}.svg" '
                f'alt="" width="30" height="20">')

    lignes = []
    for l in ORDRE_MENU:
        if absolu:
            cible = '/' + url_page(l, 'index.html')
        elif l == langue:
            cible = page
        else:
            cible = base + url_page(l, page)
        courant = ' aria-current="true"' if l == langue else ''
        lignes.append(f'          <li><a href="{cible}" hreflang="{l}" lang="{l}"{courant}>'
                      f'{drapeau(l)}<span>{LANGUES[l]["nom"]}</span></a></li>')
    classe = 'gs-lang gs-lang--compact' if variante == 'mobile' else 'gs-lang'
    return (f'<details class="{classe}" data-lang-menu>\n'
            f'        <summary class="gs-lang__btn" aria-label="{L["aria"]}">{drapeau(langue)}'
            f'<span class="gs-lang__label">{L["libelle"]}</span><span class="gs-lang__chev" aria-hidden="true"></span></summary>\n'
            f'        <ul class="gs-lang__list">\n' + '\n'.join(lignes) + '\n        </ul>\n      </details>')


def poser_selecteurs(src, langue, page, absolu=False):
    def repl(m):
        return f'<!--langues:{m.group(1)}-->{selecteur(langue, page, m.group(1), absolu)}<!--/langues-->'
    return re.sub(r'<!--langues:(desktop|mobile)-->.*?<!--/langues-->', repl, src, flags=re.S)


def poser_alternates(src, page):
    bloc = ''
    if SITE_URL:
        base = SITE_URL.rstrip('/') + '/'
        liens = [f'<link rel="alternate" hreflang="{l}" href="{base}{url_page(l, page)}">' for l in ORDRE_MENU]
        liens.append(f'<link rel="alternate" hreflang="x-default" href="{base}{page}">')
        bloc = '\n'.join(liens)
    src = re.sub(r'\n?<!--alternates-->.*?<!--/alternates-->', '', src, flags=re.S)
    if bloc:
        src = src.replace('</head>', f'<!--alternates-->\n{bloc}\n<!--/alternates-->\n</head>', 1)
    return src


def adapter_sous_dossier(src, langue):
    """Chemins relatifs vers assets/, langue du document et locale."""
    src = re.sub(r'(\s(?:href|src)=")(assets/)', r'\1../\2', src)
    src = src.replace('<html lang="fr">', f'<html lang="{langue}">', 1)
    src = src.replace('<meta property="og:locale" content="fr_FR">',
                      f'<meta property="og:locale" content="{LANGUES[langue]["locale"]}">', 1)
    return src


def charger(langue):
    chemin = os.path.join(DOSSIER_TRAD, langue + '.json')
    if not os.path.exists(chemin):
        return {}
    with open(chemin, encoding='utf-8') as f:
        return json.load(f)


def ecrire_si_change(chemin, contenu):
    ancien = None
    if os.path.exists(chemin):
        with open(chemin, encoding='utf-8') as f:
            ancien = f.read()
    if ancien != contenu:
        os.makedirs(os.path.dirname(chemin), exist_ok=True)
        with open(chemin, 'w', encoding='utf-8') as f:
            f.write(contenu)


def pages_francaises():
    return sorted(os.path.basename(p) for p in glob.glob(os.path.join(RACINE, '*.html'))
                  if os.path.basename(p) not in NON_TRADUITES)


def main():
    args = sys.argv[1:]
    pages = pages_francaises()
    sources = {}
    for p in pages:
        with open(os.path.join(RACINE, p), encoding='utf-8') as f:
            sources[p] = f.read()

    # Extraction pour la traduction (liste ordonnée des textes, avec identifiants)
    if args[:1] == ['--extraire']:
        sortie = {'pages': {}, 'textes': {}}
        for p in pages:
            ids = []
            for t in Page(p, sources[p]).textes():
                ident = hashlib.sha1(t.encode('utf-8')).hexdigest()[:8]
                sortie['textes'][ident] = t
                ids.append(ident)
            sortie['pages'][p] = ids
        with open(args[1], 'w', encoding='utf-8') as f:
            json.dump(sortie, f, ensure_ascii=False, indent=1)
        print(f"{len(sortie['textes'])} textes uniques extraits vers {args[1]}")
        return

    # 1. Pages françaises : sélecteur de langue et balises hreflang
    for p in pages:
        src = poser_alternates(poser_selecteurs(sources[p], 'fr', p), p)
        ecrire_si_change(os.path.join(RACINE, p), src)
        sources[p] = src
    chemin_404 = os.path.join(RACINE, '404.html')
    if os.path.exists(chemin_404):
        with open(chemin_404, encoding='utf-8') as f:
            ecrire_si_change(chemin_404, poser_selecteurs(f.read(), 'fr', 'index.html', absolu=True))

    # 2. Pages traduites
    rapport = {}
    for langue in TRADUITES:
        dico = charger(langue)
        manquants = set()
        for p in pages:
            src = Page(p, sources[p]).traduire(dico, manquants)
            src = adapter_sous_dossier(poser_selecteurs(src, langue, p), langue)
            ecrire_si_change(os.path.join(RACINE, LANGUES[langue]['dossier'], p), src)
        rapport[langue] = manquants

    # 3. Plan du site (si l'adresse publique est connue)
    if SITE_URL:
        base = SITE_URL.rstrip('/') + '/'
        publiques = [p for p in pages if 'name="robots" content="noindex' not in sources[p]]
        urls = ''.join(f'  <url><loc>{base}{url_page(l, p)}</loc></url>\n' for p in publiques for l in ORDRE_MENU)
        ecrire_si_change(os.path.join(RACINE, 'sitemap.xml'),
                         '<?xml version="1.0" encoding="UTF-8"?>\n'
                         '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' + urls + '</urlset>\n')

    for langue, manquants in rapport.items():
        textes = sorted({t for t, _ in manquants})
        etat = 'complet' if not textes else f'{len(textes)} texte(s) sans traduction (laissés en français)'
        print(f'{LANGUES[langue]["nom"]:<8} ({langue}/) : {len(pages)} pages, {etat}')
        if textes and '--manquants' in args:
            par_page = {}
            for t, p in sorted(manquants, key=lambda x: (x[1], x[0])):
                par_page.setdefault(p, []).append(t)
            for p, ts in par_page.items():
                print(f'  {p}')
                for t in ts:
                    print(f'    - {t}')


if __name__ == '__main__':
    main()
