#!/usr/bin/env python3
"""Convertit l'export Claude Design (.dc.html) en site statique HTML/CSS/JS."""
import glob
import html as htmllib
import json
import os
import re
import sys

SP = os.path.dirname(os.path.abspath(__file__))
EXPORT = os.path.join(SP, 'export')
# Le site se trouve deux dossiers au-dessus de ce fichier
# (outils/generateur/build.py). Calculé, et non écrit en dur : le dépôt
# doit se cloner n'importe où, sur n'importe quelle machine.
OUT = os.environ.get('GSE_OUT', os.path.normpath(os.path.join(SP, '..', '..')))

WHATSAPP = '18495386262'
PHONE_TEL = '+18495386262'
PHONE_TXT = '+1 849 538-6262'
# Second numéro, sur la page Contacts uniquement. « TÉLÉPHONE » et non
# « TÉLÉPHONE & WHATSAPP » : on ne promet WhatsApp que là où il répond.
PHONE2_TEL = '+18093176686'
PHONE2_TXT = '+1 809 317-6686'

# --------------------------------------------------------------------------
# Pages
# --------------------------------------------------------------------------
MAIN_PAGES = [
    # source, sortie, titre, description
    ('Goship Express.dc.html', 'index.html',
     'Goship Express — Envoi de colis USA, Haïti et Santo Domingo',
     "Réception, consolidation, transport et livraison de colis entre les États-Unis, Santo Domingo et Haïti. Délais annoncés, prix clairs, colis suivis de bout en bout."),
    ('A-propos.dc.html', 'a-propos.html',
     'À propos — Goship Express',
     "Goship Express est spécialisée dans le transport, la réception et la livraison de colis entre les États-Unis et Haïti, avec des solutions simples, rapides et adaptées."),
    ('Nos-Services.dc.html', 'nos-services.html',
     'Nos services — Goship Express',
     "Adresse de réception aux USA, consolidation, fret maritime et aérien, dédouanement et livraison finale vers Haïti et Santo Domingo."),
    ('Blog.dc.html', 'blog.html',
     'Blog — Goship Express',
     "Conseils, douane et bonnes pratiques d'expédition : tout ce qu'il faut savoir pour acheter aux États-Unis et recevoir sans mauvaise surprise."),
    ('Contacts.dc.html', 'contacts.html',
     'Contacts et devis — Goship Express',
     "Parlons de votre envoi : un responsable corridor vous répond sous 2 heures ouvrées avec un tarif et un délai fermes."),
    ('Support.dc.html', 'support.html',
     'Support client — Goship Express',
     "Notre équipe vous accompagne pour vos commandes, factures, livraisons et questions relatives à votre compte et vos colis."),
    ('Fermer-un-compte.dc.html', 'fermer-un-compte.html',
     'Fermer un compte — Goship Express',
     "Comment demander la fermeture de votre compte Goship Express : démarche, vérification d'identité et données conservées."),
    ('Confidentialite.dc.html', 'confidentialite.html',
     'Politique de confidentialité — Goship Express',
     "Comment Goship Express collecte, utilise et protège vos informations personnelles."),
    ('Termes-et-Conditions.dc.html', 'termes-et-conditions.html',
     'Termes et conditions — Goship Express',
     "Les termes et conditions d'utilisation des services de Goship Express."),
    ('Marchandises-Dangereuses.dc.html', 'marchandises-dangereuses.html',
     'Marchandises dangereuses — Goship Express',
     "Liste des marchandises dangereuses et restreintes que Goship Express ne peut pas transporter."),
]
ARTICLES = sorted(os.path.basename(p) for p in glob.glob(os.path.join(EXPORT, 'Article-*.dc.html')))

LINK_MAP = {}
for src, out, *_ in MAIN_PAGES:
    LINK_MAP[src] = out
    LINK_MAP[src.replace(' ', '%20')] = out
for src in ARTICLES:
    LINK_MAP[src] = src.replace('.dc.html', '.html').lower()

IMG_MAP = {
    'goship-logo.png': ('assets/img/logo-goship.png', 360, 120),
    './logo-w-mu7cz2s7-qtjg.png': ('assets/img/logo-goship-blanc.png', 420, 147),
    './about-mu77sl2m-qwoi.png': ('assets/img/entrepot-goship.jpg', 1200, 857),
    './pourquoi-livreur.jpeg': ('assets/img/livreur-goship.jpg', 706, 760),
    './box-mu7cqxm1-1929.png': ('assets/img/icone-colis.png', None, None),
    './espace-reserve-mu7cxii3-ejai.png': ('assets/img/icone-suivi.png', None, None),
    './email-mu7cu10b-09l6.png': ('assets/img/icone-notification.png', None, None),
}

SLOT_IMAGES = {
    'gs-map-hti': ('assets/img/employe-goship.webp', 896, 1195, '50% 28.7%',
                   'Employé Goship Express en polo, un colis à la main'),
    'gs-vision-team': ('assets/img/parcours-usa-haiti.webp', 670, 1200, '50% 0%',
                       "Parcours d'un colis Goship Express : des États-Unis au hub dominicain, jusqu'à la livraison en Haïti"),
    'gs-tshirt': ('assets/img/equipe-goship.webp', 496, 620, '50% 50%',
                  'Équipe Goship Express en uniforme orange au dépôt'),
}
AVATAR_INITIALS = {'gs-av-1': 'MD', 'gs-av-2': 'JP'}

HOVER_NAMES = {
    'color:var(--accent)': 'hv-accent',
    'background:var(--accent);color:#fff': 'hv-fill-accent',
    'background:#d4500a;color:#fff': 'hv-fill-cta',
    'color:#fff': 'hv-white',
    'transform:translateY(-10px)': 'hv-rise',
    'transform:scale(1.09);box-shadow:0 26px 44px -18px rgba(244,96,13,.9);border-color:var(--ink)': 'hv-why-icon',
    'transform:translateY(-8px);box-shadow:0 36px 60px -40px rgba(6,26,63,.45)': 'hv-card-soft',
    'color:var(--ink)': 'hv-ink',
    'transform:translateY(-8px);box-shadow:0 36px 60px -34px rgba(6,26,63,.4)': 'hv-card',
    'background:#d4500a;color:#fff;transform:translateY(-2px)': 'hv-fill-cta-lift',
    'transform:translateY(-8px);border-color:var(--accent);box-shadow:0 34px 60px -40px rgba(6,26,63,.5)': 'hv-card-accent',
    'transform:translateY(-8px)': 'hv-lift',
    'background:var(--accent)': 'hv-bg-accent',
    'background:var(--cream);color:var(--ink)': 'hv-fill-cream',
    'background:rgba(255,255,255,.12);color:#fff': 'hv-glass',
    'background:rgba(255,255,255,.12)': 'hv-glass-bg',
    'background:rgba(255,255,255,.1);color:#fff': 'hv-glass-soft',
    'background:#d4500a;transform:translateY(-2px)': 'hv-bg-cta-lift',
    'background:#d4500a': 'hv-bg-cta',
    'background:#020c22;color:#fff': 'hv-fill-night',
}
USED_HOVERS = set()

PAGES = os.path.join(SP, 'pages')

# Pages de l'espace client (mêmes en-tête et pied que le reste du site)
COMPTE_PAGES = [
    # sortie, gabarit, titre, description, noindex
    ('inscription.html', 'inscription.main.html', 'Créer un compte — Goship Express',
     "Ouvrez votre compte Goship Express : votre code client, votre adresse de réception en Floride "
     "et le suivi de vos colis en temps réel.", False),
    ('connexion.html', 'connexion.main.html', 'Se connecter — Goship Express',
     "Connectez-vous à votre espace client Goship Express pour suivre vos colis en temps réel.", False),
    ('mon-compte.html', 'mon-compte.main.html', 'Mon compte — Goship Express',
     "Votre espace client Goship Express : code client, adresse en Floride et suivi de vos colis.", True),
    ('nouveau-mot-de-passe.html', 'nouveau-mot-de-passe.main.html', 'Nouveau mot de passe — Goship Express',
     "Choisissez un nouveau mot de passe pour votre compte Goship Express.", True),
]

# Pictogrammes (traits, 24 × 24)
ICONES = {
    'user': '<path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/>',
    'user-plus': '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M19 8v6M22 11h-6"/>',
    'check-circle': '<circle cx="12" cy="12" r="10"/><path d="m8.5 12.5 2.5 2.5 5-5.5"/>',
    'shield': '<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><path d="m9 12 2 2 4-4"/>',
    'map-pin': '<path d="M20 10c0 6-8 12-8 12s-8-6-8-12a8 8 0 0 1 16 0Z"/><circle cx="12" cy="10" r="3"/>',
    'eye': '<path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12Z"/><circle cx="12" cy="12" r="3"/>',
    'lock': '<rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
    'clipboard': '<rect x="8" y="2" width="8" height="4" rx="1"/><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/><path d="M8 11h8M8 15h5"/>',
    'message': '<path d="M7.9 20A9 9 0 1 0 4 16.1L2 22Z"/><path d="M9 10.5c.3 1.6 1.9 3.2 3.5 3.5l1-1.2 2 .8c-.2 1.2-1.1 1.9-2.3 1.7-2.7-.4-4.9-2.6-5.3-5.3-.2-1.2.5-2.1 1.7-2.3l.8 2Z"/>',
    'copy': '<rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>',
    'package': '<path d="m7.5 4.3 9 5.2"/><path d="M21 8a2 2 0 0 0-1-1.7l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.7l7 4a2 2 0 0 0 2 0l7-4a2 2 0 0 0 1-1.7Z"/><path d="m3.3 7 8.7 5 8.7-5M12 22V12"/>',
    'log-out': '<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><path d="m16 17 5-5-5-5M21 12H9"/>',
    'plus': '<path d="M12 5v14M5 12h14"/>',
    'search': '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
    'x': '<path d="M18 6 6 18M6 6l12 12"/>',
    'pencil': '<path d="M17 3a2.8 2.8 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z"/>',
    'trash': '<path d="M3 6h18M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>',
}


def icone(nom, taille=20):
    return (f'<svg class="gs-ico" viewBox="0 0 24 24" width="{taille}" height="{taille}" fill="none" '
            f'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" '
            f'aria-hidden="true" focusable="false">{ICONES[nom]}</svg>')


def poser_icones(s):
    return re.sub(r'\[\[ico:([a-z-]+)\]\]', lambda m: icone(m.group(1)), s)


def textes_compte(prefixes=None):
    """Textes utilisés par les scripts de l'espace client (traduits comme le reste de la page)."""
    s = open(os.path.join(PAGES, 'textes-compte.html'), encoding='utf-8').read().strip('\n')
    if prefixes:
        lignes = s.split('\n')
        s = '\n'.join(l for l in lignes
                      if not l.strip().startswith('<p data-t=')
                      or any(f'data-t="{p}' in l for p in prefixes))
    return s


ICON_FONT = ('https://fonts.googleapis.com/css2?family=Material+Symbols+Outlined:opsz,wght,FILL,GRAD@24,300,0,0'
             '&amp;icon_names=directions_boat,flight,inventory_2,local_shipping,sensors,support_agent,timer&amp;display=block')
TEXT_FONTS = ('https://fonts.googleapis.com/css2?family=Archivo:wdth,wght@75..125,400..900'
              '&amp;family=Manrope:wght@400;500;600;700&amp;family=IBM+Plex+Mono:wght@500;600&amp;display=swap')


# Politique de sécurité du contenu (CSP)
# ------------------------------------------------------------------
# Le navigateur n'exécute et ne contacte que ce qui est listé ici. Un script
# étranger glissé dans une page (extension, publicité, faille) ne peut donc ni
# s'exécuter, ni envoyer ailleurs les données des clients ou leur session.
# Pour ajouter un service (tchat, statistiques, Formspree…), ajoutez son adresse
# à la ligne qui convient, sinon le navigateur le bloquera.
# Voir README.md, « Sécurité ».

def origine_supabase():
    """Adresse du projet Supabase, lue dans assets/js/config.js du site construit."""
    try:
        with open(os.path.join(OUT, 'assets/js/config.js'), encoding='utf-8') as f:
            m = re.search(r"supabaseUrl:\s*'([^']*)'", f.read())
        return m.group(1).strip().rstrip('/') if m else ''
    except OSError:
        return ''


def csp(entete=False):
    sb = origine_supabase()
    images = ["'self'", 'data:', 'https://images.unsplash.com']
    connexions = ["'self'"]
    if sb:
        images.append(sb)
        connexions += [sb, 'wss://' + sb.split('://', 1)[-1]]
    regles = [
        "default-src 'self'",
        "base-uri 'none'",
        "object-src 'none'",
        "form-action 'self'",
        "script-src 'self'",
        "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
        "font-src 'self' https://fonts.gstatic.com",
        'img-src ' + ' '.join(images),
        'connect-src ' + ' '.join(connexions),
    ]
    # Ces deux règles n'ont d'effet que dans un vrai en-tête HTTP (fichiers
    # _headers et .htaccess) : dans la page, le navigateur les ignore.
    if entete:
        regles += ["frame-ancestors 'none'", 'upgrade-insecure-requests']
    return '; '.join(regles)


def attr_escape(s):
    return htmllib.escape(s, quote=False).replace('"', '&quot;')


def fail(msg):
    sys.exit('ERREUR : ' + msg)


def replace_once(s, old, new, page, count=1):
    n = s.count(old)
    if n != count:
        fail(f'{page}: attendu {count} occurrence(s) de {old[:90]!r}, trouvé {n}')
    return s.replace(old, new)


def sub_count(pattern, repl, s, page, count=1, flags=0):
    out, n = re.subn(pattern, repl, s, flags=flags)
    if n != count:
        fail(f'{page}: attendu {count} remplacement(s) pour {pattern[:90]!r}, trouvé {n}')
    return out


# --------------------------------------------------------------------------
# Transformation des balises ouvrantes (attributs)
# --------------------------------------------------------------------------
TAG_RE = re.compile(
    r'<([a-zA-Z][a-zA-Z0-9-]*)'
    r'((?:\s+[^\s=/>"\']+(?:\s*=\s*(?:"[^"]*"|\'[^\']*\'|[^\s"\'=<>`]+))?)*)'
    r'\s*(/?)>')
ATTR_RE = re.compile(r'([^\s=/>"\']+)(?:\s*=\s*(?:"([^"]*)"|\'([^\']*)\'|([^\s"\'=<>`]+)))?')


def parse_attrs(raw):
    attrs = []
    for m in ATTR_RE.finditer(raw):
        name = m.group(1)
        if m.group(2) is not None:
            val = m.group(2)
        elif m.group(3) is not None:
            val = m.group(3)
            if '"' in val:
                fail('valeur entre apostrophes contenant un guillemet : ' + val)
        else:
            val = m.group(4)
        attrs.append([name, val])
    return attrs


def serialize(tag, attrs, selfclose):
    parts = [tag]
    for name, val in attrs:
        parts.append(name if val is None else f'{name}="{val}"')
    return '<' + ' '.join(parts) + (' /' if selfclose else '') + '>'


def get_attr(attrs, name):
    for a in attrs:
        if a[0] == name:
            return a[1]
    return None


def set_attr(attrs, name, val, before=None):
    for a in attrs:
        if a[0] == name:
            a[1] = val
            return
    if before:
        for i, a in enumerate(attrs):
            if a[0] == before:
                attrs.insert(i, [name, val])
                return
    attrs.append([name, val])


def del_attr(attrs, name):
    attrs[:] = [a for a in attrs if a[0] != name]


def add_class(attrs, cls):
    cur = get_attr(attrs, 'class')
    if cur:
        if cls not in cur.split():
            set_attr(attrs, 'class', cur + ' ' + cls)
    else:
        # la classe est placée avant le style pour rester lisible
        set_attr(attrs, 'class', cls, before='style')


def unsplash_srcset(src):
    m = re.search(r'([?&](?:amp;)?)w=(\d+)', src)
    maxw = int(m.group(2))
    widths = [w for w in (640, 960, 1280, 1600, 2000) if w < maxw] + [maxw]
    return ', '.join(re.sub(r'w=\d+', f'w={w}', src) + f' {w}w' for w in widths)


def transform_tag(tag, attrs, page):
    changed = False

    hover = get_attr(attrs, 'style-hover')
    if hover is not None:
        if hover not in HOVER_NAMES:
            fail(f'{page}: style de survol inconnu {hover!r}')
        USED_HOVERS.add(hover)
        del_attr(attrs, 'style-hover')
        add_class(attrs, HOVER_NAMES[hover])
        changed = True

    for junk in ('data-path-to-node', 'data-index-in-node'):
        if get_attr(attrs, junk) is not None:
            del_attr(attrs, junk)
            changed = True

    href = get_attr(attrs, 'href')
    if tag == 'a' and href:
        path, _, frag = href.partition('#')
        if path in LINK_MAP:
            set_attr(attrs, 'href', LINK_MAP[path] + ('#' + frag if frag else ''))
            changed = True
        elif path.endswith('.dc.html'):
            fail(f'{page}: lien vers une page inconnue {href}')
        if href.startswith('http') and get_attr(attrs, 'target') is None:
            set_attr(attrs, 'target', '_blank', before='style')
            set_attr(attrs, 'rel', 'noopener', before='style')
            changed = True

    if tag == 'span' and 'Material Symbols' in (get_attr(attrs, 'style') or '') and get_attr(attrs, 'translate') is None:
        set_attr(attrs, 'translate', 'no', before='style')
        changed = True

    if tag == 'img':
        src = get_attr(attrs, 'src')
        style = get_attr(attrs, 'style') or ''
        if src in IMG_MAP:
            new, w, h = IMG_MAP[src]
            if w is None:
                # icônes décoratives à côté d'un titre : pas de texte alternatif
                set_attr(attrs, 'alt', '')
            if src == 'goship-logo.png' and 'position:absolute' in style:
                new, w, h = 'assets/img/logo-goship-grand.png', 640, 214
            set_attr(attrs, 'src', new)
            if w and get_attr(attrs, 'width') is None:
                set_attr(attrs, 'width', str(w), before='style')
                set_attr(attrs, 'height', str(h), before='style')
            changed = True
        elif src and 'images.unsplash.com' in src:
            m = re.search(r'[?&;]w=(\d+)', src)
            if m and int(m.group(1)) >= 1800 and 'position:absolute;inset:0' in style.replace(' ', ''):
                set_attr(attrs, 'srcset', unsplash_srcset(src), before='alt')
                set_attr(attrs, 'sizes', '100vw', before='alt')
                changed = True
        elif src and not src.startswith('assets/'):
            fail(f'{page}: image non gérée {src}')
        if get_attr(attrs, 'loading') == 'lazy' and get_attr(attrs, 'decoding') is None:
            set_attr(attrs, 'decoding', 'async', before='style')
            changed = True

    return changed


def transform_tags(body, page):
    def repl(m):
        tag, raw, selfclose = m.group(1).lower(), m.group(2), m.group(3)
        attrs = parse_attrs(raw)
        if transform_tag(tag, attrs, page):
            return serialize(m.group(1), attrs, bool(selfclose))
        return m.group(0)
    return TAG_RE.sub(repl, body)


# --------------------------------------------------------------------------
# <sc-if> (rendu conditionnel de la maquette)
# --------------------------------------------------------------------------
SCIF_OPEN = re.compile(r'<sc-if\s+value="\{\{\s*(\w+)\s*\}\}"[^>]*>')


def process_scif(s, rules, page):
    out, pos = [], 0
    while True:
        m = SCIF_OPEN.search(s, pos)
        if not m:
            out.append(s[pos:])
            return ''.join(out)
        out.append(s[pos:m.start()])
        depth, i = 1, m.end()
        while depth:
            nxt_open = SCIF_OPEN.search(s, i)
            nxt_close = s.find('</sc-if>', i)
            if nxt_close == -1:
                fail(f'{page}: <sc-if> non fermé')
            if nxt_open and nxt_open.start() < nxt_close:
                depth += 1
                i = nxt_open.end()
            else:
                depth -= 1
                close_at = nxt_close
                i = nxt_close + len('</sc-if>')
        name = m.group(1)
        if name not in rules:
            fail(f'{page}: condition sc-if non gérée {name}')
        inner = process_scif(s[m.end():close_at], rules, page)
        out.append(rules[name](inner))
        pos = i


def add_attrs_to_first(extra):
    def rule(inner):
        return re.sub(r'<([a-zA-Z][a-zA-Z0-9-]*)(\s)', lambda m: f'<{m.group(1)} {extra}{m.group(2)}', inner, count=1)
    return rule


TRACK_RESULT = '''
      <div data-track-result hidden tabindex="-1" style="margin-top:32px;border-top:1px dashed #dbe2ef;padding-top:28px">
        <div class="gs-suivi" data-track-etat="trouve" hidden>
          <div class="gs-suivi__tete">
            <span class="gs-suivi__ref" data-track-ref translate="no"></span>
            <span class="gs-badge" data-track-statut></span>
            <span class="gs-suivi__maj" data-track-maj></span>
          </div>
          <ol class="gs-etapes gs-etapes--large" data-track-etapes>
            <li>Reçu</li>
            <li>Emballé</li>
            <li>Embarqué</li>
            <li>Distribution</li>
            <li>Succursale</li>
            <li>Disponible</li>
            <li>Livré</li>
          </ol>
          <ol class="gs-chrono gs-chrono--suivi" data-track-historique></ol>
          <p class="gs-suivi__plus">Suivez tous vos colis en temps réel depuis votre espace client : <a href="connexion.html">se connecter</a> ou <a href="inscription.html">créer un compte</a>.</p>
        </div>
        <div class="gs-suivi" data-track-etat="introuvable" hidden>
          <p class="gs-suivi__titre">Aucun colis ne correspond à cette référence.</p>
          <p>Vérifiez le numéro de colis (par exemple GSE-4821-HT) ou saisissez le numéro de suivi du vendeur. Un colis tout juste expédié apparaît dès sa réception à Miami. <a data-track-link href="https://wa.me/''' + WHATSAPP + '''" target="_blank" rel="noopener">Écrire sur WhatsApp</a></p>
        </div>
        <div class="gs-suivi" data-track-etat="code-client" hidden>
          <p class="gs-suivi__titre">Ceci est un code client.</p>
          <p>Connectez-vous à votre espace client pour voir tous les colis rattachés à votre compte. <a href="connexion.html">Se connecter</a></p>
        </div>
        <div data-track-etat="whatsapp" hidden>
          <div style="display:flex;flex-wrap:wrap;gap:10px 18px;align-items:center">
            <span data-track-ref style="font-family:'IBM Plex Mono',monospace;font-size:14px;font-weight:600;background:var(--ink);color:#fff;padding:8px 13px;border-radius:8px"></span>
            <span style="font-size:14.5px;font-weight:700;color:var(--accent2)">Demande de suivi préparée dans WhatsApp</span>
            <span style="font-family:'IBM Plex Mono',monospace;font-size:10.5px;letter-spacing:.14em;text-transform:uppercase;color:#8a93ac">Réponse Lun–Sam · 8h–18h</span>
          </div>
          <p style="margin-top:14px;font-size:14.5px;color:#55627e">Envoyez le message dans WhatsApp : notre équipe vous répond avec chaque étape de votre colis, de la réception à Medley jusqu'à la livraison. WhatsApp ne s'est pas ouvert ? <a data-track-link href="https://wa.me/''' + WHATSAPP + '''" target="_blank" rel="noopener" style="font-weight:700">Ouvrir WhatsApp</a> ou appelez le <a href="tel:''' + PHONE_TEL + '''" style="font-weight:700;white-space:nowrap">''' + PHONE_TXT + '''</a>.</p>
        </div>
      </div>
    '''

SCIF_RULES = {
    'showTracking': lambda inner: inner,
    'showPricing': lambda inner: inner,
    'notSent': lambda inner: inner,
    'copied': add_attrs_to_first('data-copy-feedback hidden role="status"'),
    'sent': add_attrs_to_first('data-form-success hidden tabindex="-1"'),
    'trackResult': lambda inner: TRACK_RESULT,
}


# --------------------------------------------------------------------------
# Transformations spécifiques
# --------------------------------------------------------------------------
HEADER_OPEN = ('<header style="position:sticky;top:0;z-index:60;background:rgba(6,26,63,.95);'
               'backdrop-filter:blur(16px);border-bottom:1px solid rgba(255,255,255,.1)">')
HEADER_BAR = ('<div style="max-width:1320px;margin:0 auto;padding:14px 28px;display:flex;flex-wrap:wrap;'
              'align-items:center;gap:14px 28px;justify-content:space-between">')
NAV_OPEN = '<nav style="display:flex;align-items:center;gap:30px;flex-wrap:wrap;font-size:15px;font-weight:600">'
ACTIONS_OPEN = '<div style="display:flex;flex-wrap:wrap;align-items:center;gap:12px 20px">'
HEADER_PHONE = '<a href="tel:+18495386262" style="display:flex;align-items:center;gap:11px;color:#fff;white-space:nowrap">'
MOBILE_ACTIONS = f'''
    <div class="gs-mobile-actions">
      <!--langues:mobile--><!--/langues-->
      <a class="gs-call" href="tel:{PHONE_TEL}" aria-label="Appeler Goship Express au {PHONE_TXT}">☎</a>
      <button class="gs-burger" type="button" data-menu-toggle aria-expanded="false" aria-controls="menu-principal" aria-label="Ouvrir le menu"><span></span><span></span><span></span></button>
    </div>'''


def transform_header(body, page):
    start = body.find('<header')
    end = body.find('</header>') + len('</header>')
    h = body[start:end]
    h = replace_once(h, HEADER_OPEN, HEADER_OPEN.replace('<header ', '<header class="gs-header" data-header '), page)
    h = replace_once(h, HEADER_BAR, HEADER_BAR.replace('<div ', '<div class="gs-header__bar" '), page)
    # logo -> lien d'accueil + boutons mobiles juste après
    m = re.search(r'<a href="(#top|Goship%20Express\.dc\.html)" style="display:flex;align-items:center;flex:none">', h)
    if not m:
        fail(page + ': logo introuvable')
    logo_close = h.find('</a>', m.end()) + len('</a>')
    logo = h[m.start():logo_close].replace(
        '<a href=', '<a class="gs-logo" aria-label="Goship Express — Accueil" href=', 1)
    # Le logo ramène à l'accueil depuis toutes les pages (la maquette pointait
    # parfois vers #top) ; sur l'accueil il remonte en haut de page.
    logo = re.sub(r'href="[^"]*"', 'href="#top"' if page == 'index.html' else 'href="Goship%20Express.dc.html"', logo, count=1)
    h = h[:m.start()] + logo + MOBILE_ACTIONS + h[logo_close:]
    h = replace_once(h, NAV_OPEN, NAV_OPEN.replace(
        '<nav ', '<nav class="gs-nav" id="menu-principal" aria-label="Navigation principale" '), page)
    h = replace_once(h, ACTIONS_OPEN, ACTIONS_OPEN.replace('<div ', '<div class="gs-actions" ')
                     + '\n      <!--langues:desktop--><!--/langues-->', page)
    h = replace_once(h, HEADER_PHONE, HEADER_PHONE.replace('<a ', '<a class="gs-header-phone" '), page)
    # « Demander un devis » devient « Créer un compte » (« Mon compte » une fois connecté)
    h = sub_count(r'<a href="(?:Contacts\.dc\.html)?#contact" (style="[^"]*" style-hover="[^"]*")>Demander un devis</a>',
                  r'<a class="gs-connexion-mobile" href="connexion.html" data-session="non">Se connecter</a>\n'
                  r'      <a href="inscription.html" class="gs-cta" data-session="non" \1>Créer un compte</a>\n'
                  r'      <a href="mon-compte.html" class="gs-cta" data-session="oui" hidden \1>Mon compte</a>', h, page)
    # page active
    nav_start = h.find('<nav ')
    nav_end = h.find('</nav>')
    nav = h[nav_start:nav_end]
    nav, n = re.subn(r'<a (href="[^"]*") style="color:var\(--accent\)"', r'<a \1 aria-current="page" style="color:var(--accent)"', nav)
    if n > 1:
        fail(page + ': plusieurs liens actifs dans le menu')
    h = h[:nav_start] + nav + h[nav_end:]
    return body[:start] + h + body[end:]


def transform_topbar(body, page):
    """Bandeau du haut : accès à l'espace client.

    Sur mobile, adresse, e-mail et horaires sont masqués (ils restent dans le pied de page
    et sur la page Contacts) : il ne reste que « Se connecter » et le bouton « Créer un
    compte ». Les classes posées ici servent aux règles de site.css.
    """
    fin = body.find('<header')
    haut = body[:fin]
    haut = replace_once(haut, '<div style="max-width:1320px;margin:0 auto;padding:12px 28px;',
                        '<div class="gs-bandeau__ligne" style="max-width:1320px;margin:0 auto;padding:12px 28px;', page)
    haut = replace_once(haut, '<span style="display:flex;align-items:center;gap:10px"><span style="width:6px;',
                        '<span class="gs-bandeau-info" style="display:flex;align-items:center;gap:10px"><span style="width:6px;', page)
    haut = replace_once(haut, '<span style="color:#dde5f8">', '<span class="gs-bandeau-info" style="color:#dde5f8">', page)
    haut = sub_count(r'<span>(Lun–Sam[^<]*)</span>', r'<span class="gs-bandeau-info">\1</span>', haut, page)
    haut = sub_count(r'<div (style="display:flex;flex-wrap:wrap;gap:8px 26px;align-items:center">)(.*?)\s*</div>',
                     lambda m: '<div class="gs-bandeau__actions" ' + m.group(1) + m.group(2).rstrip()
                     + '\n      <a class="gs-bandeau-compte" href="connexion.html" data-session="non">[[ico:user]]Se connecter</a>'
                     + '\n      <a class="gs-bandeau-compte" href="mon-compte.html" data-session="oui" hidden>[[ico:user]]Mon compte</a>'
                     + '\n      <a class="gs-bandeau-inscription" href="inscription.html" data-session="non">Créer un compte</a>'
                     + '\n    </div>',
                     haut, page, flags=re.S)
    return poser_icones_petites(haut) + body[fin:]


def poser_icones_petites(s):
    return re.sub(r'\[\[ico:([a-z-]+)\]\]', lambda m: icone(m.group(1), 14), s)


WHY_SCROLL = '<div style="max-width:1200px;margin:clamp(20px,2.4vw,36px) auto 0;overflow-x:auto;overflow-y:hidden;-webkit-overflow-scrolling:touch">'
WHY_BOX = '<div style="position:relative;width:100%;min-width:880px;aspect-ratio:1200/900;container-type:inline-size">'
WHY_PHOTO = '<div style="position:absolute;left:30.83%;top:32.2%;width:38.33%;aspect-ratio:1;border-radius:50%;overflow:hidden;box-shadow:0 40px 80px -42px rgba(6,26,63,.6)">'


def transform_why(body, page):
    if WHY_BOX not in body:
        return body
    body = replace_once(body, WHY_SCROLL, WHY_SCROLL.replace('<div ', '<div class="gs-why-scroll" '), page)
    body = replace_once(body, WHY_BOX, WHY_BOX.replace('<div ', '<div class="gs-why" '), page)
    body = replace_once(body, WHY_PHOTO, WHY_PHOTO.replace('<div ', '<div class="gs-why-photo" '), page)
    start = body.find('class="gs-why" ')
    end = body.find('</section>', start)
    sec = body[start:end]
    sec = sub_count(r'<div (style="position:absolute;[^"]*pointer-events:none")', r'<div class="gs-why-deco" \1', sec, page, 2)
    sec = sub_count(r'<div (style="position:absolute;[^"]*transition:transform \.4s cubic-bezier\(\.2,\.7,\.3,1\)" style-hover="transform:translateY\(-10px\)")',
                    r'<div class="gs-why-item" \1', sec, page, 5)
    sec = sub_count(r'<div (style="flex:none;width:clamp\(58px,10\.67cqw,128px\)[^"]*" style-hover="transform:scale\(1\.09\))',
                    r'<div class="gs-why-icon" \1', sec, page, 5)
    return body[:start] + sec + body[end:]


def transform_slots(body, page):
    def repl(m):
        sid, style = m.group(1), m.group(2)
        if sid in SLOT_IMAGES:
            src, w, h, pos, alt = SLOT_IMAGES[sid]
            return (f'<img src="{src}" alt="{attr_escape(alt)}" width="{w}" height="{h}" loading="lazy" decoding="async" '
                    f'style="display:block;{style};object-fit:cover;object-position:{pos}">')
        if sid in AVATAR_INITIALS:
            return f'<span class="gs-avatar" aria-hidden="true" translate="no" style="{style}">{AVATAR_INITIALS[sid]}</span>'
        fail(f'{page}: image-slot inconnu {sid}')
    return re.sub(r'<image-slot id="([^"]+)" shape="[^"]*" style="([^"]*)" placeholder="[^"]*"></image-slot>', repl, body)


LV_CARD = (r'\s*<div style="background:#fff;border:1px solid #e3e8f2;border-radius:var\(--r\);overflow:hidden;[^"]*"[^>]*>'
           r'\s*<div style="position:relative">\s*<span [^>]*>LV</span>\s*</div>\s*</div>')

PARALLAXE = [
    ('position:absolute;left:clamp(-14px,-1vw,0px);bottom:-30px;', '-0.06'),
    ('position:absolute;top:26px;right:-22px;', '0.1'),
    ('position:absolute;top:-40px;right:-40px;', '0.12'),
]

VALEUR_ADRESSE = '<span style="padding:18px 20px;font-size:16px;color:#5b6782">'
LIGNE_GRILLE = '<div style="display:grid;grid-template-columns:minmax(120px,38%) 1fr;border-bottom:1px solid #eef2f9">'
LIGNE_ZIP = (LIGNE_GRILLE + '\n'
             '          <span style="padding:18px 20px;font-weight:800;font-size:16px;color:var(--accent);border-right:1px solid #eef2f9">Zip Code</span>\n'
             '          ' + VALEUR_ADRESSE + '33166</span>\n'
             '        </div>\n')
LIGNE_PAYS = (LIGNE_GRILLE + '\n'
              '          <span style="padding:18px 20px;font-weight:800;font-size:16px;color:var(--accent);border-right:1px solid #eef2f9">Country</span>\n'
              '          <span translate="no" style="padding:18px 20px;font-size:16px;color:#5b6782">United States</span>\n'
              '        </div>\n')


HONEYPOT = '<input class="gs-hp" type="text" name="_gotcha" tabindex="-1" autocomplete="off" aria-hidden="true">'


# --------------------------------------------------------------------------
# Section « Application mobile » (bas de la page d'accueil)
# --------------------------------------------------------------------------
# Les trois téléphones ne sont pas des photos : ce sont les écrans de
# l'application refaits en HTML, avec ses vraies couleurs (application-mobile/
# lib/theme.js). Ils restent donc nets sur tous les écrans, se traduisent avec
# le reste du site et ne pèsent rien à charger.

LOGO_PLAY = ('<svg class="gs-store__logo" viewBox="0 0 24 24" width="22" height="22" fill="currentColor" '
             'aria-hidden="true" focusable="false">'
             '<path d="M4.5 3.1c-.3.3-.5.8-.5 1.4v15c0 .6.2 1.1.5 1.4l.1.1 8.4-8.4v-.2L4.6 3l-.1.1z"/>'
             '<path d="m16.2 15.4-2.8-2.8v-.2l2.8-2.8.1.1 3.3 1.9c.9.5.9 1.4 0 1.9l-3.4 1.9z"/>'
             '<path d="m16.3 15.3-2.9-2.9-8.9 9c.3.3.8.3 1.4 0l10.4-6.1"/>'
             '<path d="M18.9 8.1 8.5 2.1c-.6-.3-1.1-.3-1.4 0l8.9 8.9 2.9-2.9z"/></svg>')

LOGO_POMME = ('<svg class="gs-store__logo" viewBox="0 0 24 24" width="22" height="22" fill="currentColor" '
              'aria-hidden="true" focusable="false">'
              '<path d="M17.2 12.6c0-2.4 1.9-3.5 2-3.6-1.1-1.6-2.8-1.8-3.4-1.8-1.5-.2-2.8.9-3.5.9-.7 0-1.8-.9-3-.8-1.6 0-3 .9-3.8 2.3-1.6 2.8-.4 7 1.2 9.3.8 1.1 1.7 2.4 2.9 2.4 1.2 0 1.6-.8 3-.8s1.8.8 3 .7c1.3 0 2.1-1.1 2.8-2.3.9-1.3 1.3-2.6 1.3-2.7-.1 0-2.5-1-2.5-3.6z"/>'
              '<path d="M14.8 5.9c.6-.8 1.1-1.9 1-3-.9 0-2.1.6-2.8 1.4-.6.7-1.1 1.9-1 2.9 1 .1 2.1-.5 2.8-1.3z"/></svg>')


def ajouter_second_numero(body, page):
    """Ajoute la carte du second numéro sur la page Contacts.

    On recopie la carte existante au lieu d'en réécrire le style : si la
    maquette change de couleurs ou d'espacements, la seconde carte suit toute
    seule. Elle porte « TÉLÉPHONE » et non « TÉLÉPHONE & WHATSAPP » : on ne
    promet WhatsApp que sur le numéro où il répond.
    """
    # La page porte deux liens « tel: » : celui de l'en-tête (« APPELEZ-NOUS »)
    # et celui de la section Contact. C'est le second qu'on veut, reconnu à son
    # libellé.
    LIBELLE = 'TÉLÉPHONE &amp; WHATSAPP'
    cartes = [m.group(0) for m in
              re.finditer(r'<a href="tel:' + re.escape(PHONE_TEL) + r'"[\s\S]*?</a>', body)
              if LIBELLE in m.group(0)]
    if len(cartes) != 1:
        fail('%s : %d carte(s) « %s » trouvée(s), une seule attendue' % (page, len(cartes), LIBELLE))
    carte = cartes[0]
    for morceau in (PHONE_TEL, PHONE_TXT, LIBELLE):
        if carte.count(morceau) != 1:
            fail('%s : %r attendu une seule fois dans la carte téléphone' % (page, morceau))
    seconde = (carte.replace(PHONE_TEL, PHONE2_TEL)
                    .replace(PHONE_TXT, PHONE2_TXT)
                    .replace(LIBELLE, 'TÉLÉPHONE'))
    return body.replace(carte, carte + '\n        ' + seconde, 1)


def bouton_store(magasin, logo, nom, mini=False):
    """Bouton d'une boutique. Sans adresse dans config.js il affiche « Bientôt sur »
    et ne mène nulle part ; site.js le transforme en vrai lien dès qu'elle est remplie."""
    classe = 'gs-store gs-store--mini' if mini else 'gs-store'
    return (f'<a class="{classe}" data-store="{magasin}">{logo}'
            f'<span class="gs-store__texte">'
            f'<small data-store-etat="bientot">Bientôt sur</small>'
            f'<small data-store-etat="pret" hidden>Disponible sur</small>'
            f'<strong translate="no">{nom}</strong></span></a>')


def boutons_stores(mini=False):
    return (bouton_store('android', LOGO_PLAY, 'Google Play', mini)
            + ('\n        ' if mini else '\n      ')
            + bouton_store('ios', LOGO_POMME, 'App Store', mini))


# Les trois écrans de l'application, dessinés aux mesures de l'application par
# outils/ecrans-app/ecrans.py. Les images valent mieux que du HTML ici : ce sont
# les vrais écrans, ils ne peuvent pas se décaler d'un navigateur à l'autre, et
# celui du milieu est posé un peu plus haut que les deux autres.
ECRANS = [
    ('colis', "Le suivi d'un colis dans l'application : son statut, son avancement et ses étapes", ''),
    ('accueil', "L'accueil de l'application : votre adresse à Miami et vos derniers colis",
     ' gs-tel--centre'),
    ('prealerte', "La pré-alerte dans l'application : annoncer un achat avant son arrivée à Miami", ''),
]


def telephones():
    return '\n'.join(
        f'      <figure class="gs-tel{classe}">\n'
        f'        <img src="assets/img/app-ecran-{nom}.webp" width="660" height="1384"'
        f' loading="lazy" decoding="async" alt="{alt}">\n'
        f'      </figure>'
        for nom, alt, classe in ECRANS)


# Petits éléments qui flottent autour des téléphones (purement décoratifs)
DECOR = (
    '    <span class="gs-decor gs-decor--pastille gs-decor--a" aria-hidden="true" translate="no">USA</span>\n'
    '    <span class="gs-decor gs-decor--pastille gs-decor--b" aria-hidden="true" translate="no">HT</span>\n'
    '    <span class="gs-decor gs-decor--pastille gs-decor--c" aria-hidden="true" translate="no">DO</span>\n'
    '    <svg class="gs-decor gs-decor--avion" viewBox="0 0 26 20" width="26" height="20" aria-hidden="true" '
    'focusable="false"><path d="M0 0 26 10 0 20 6 10Z" fill="currentColor"/></svg>\n'
    '    <svg class="gs-decor gs-decor--boucle" viewBox="0 0 44 30" width="44" height="30" fill="none" '
    'aria-hidden="true" focusable="false"><path d="M2 28C2 10 16 2 26 8s2 18 10 18 6-14 6-14" '
    'stroke="currentColor" stroke-width="3" stroke-linecap="round"/></svg>\n'
    '    <span class="gs-decor gs-decor--point gs-decor--p1" aria-hidden="true"></span>\n'
    '    <span class="gs-decor gs-decor--point gs-decor--p2" aria-hidden="true"></span>'
)

# Ligne pointillée et petits avions au bas de la section, comme un trajet
TRACE = (
    '  <svg class="gs-app__trace" viewBox="0 0 1440 120" fill="none" aria-hidden="true" focusable="false" '
    'preserveAspectRatio="none">\n'
    '    <path d="M-20 74C180 18 330 104 560 78S900 8 1080 50s260 44 380 8" stroke="rgba(255,255,255,.28)" '
    'stroke-width="2.5" stroke-linecap="round" stroke-dasharray="11 13"/>\n'
    '  </svg>\n'
    '  <span class="gs-app__avions" aria-hidden="true">\n'
    '    <svg viewBox="0 0 26 20" width="26" height="20" focusable="false"><path d="M0 0 26 10 0 20 6 10Z" '
    'fill="currentColor"/></svg>\n'
    '    <svg viewBox="0 0 26 20" width="26" height="20" focusable="false"><path d="M0 0 26 10 0 20 6 10Z" '
    'fill="currentColor"/></svg>\n'
    '    <svg viewBox="0 0 26 20" width="26" height="20" focusable="false"><path d="M0 0 26 10 0 20 6 10Z" '
    'fill="currentColor"/></svg>\n'
    '  </span>'
)


def section_application():
    html = f'''
<section id="application" class="gs-app">
  <div class="gs-app__halo" aria-hidden="true"></div>
  <div class="gs-app__dedans">
    <span class="gs-app__oeil">Application mobile</span>
    <h2 class="gs-app__titre">Vos colis dans votre poche</h2>
    <p class="gs-app__texte">Suivez chaque étape en direct, recevez une notification dès qu'un colis change d'état et annoncez vos achats avant même leur arrivée à Miami. Gratuite, en français, créole, anglais et espagnol.</p>
    <div class="gs-stores">
    {boutons_stores()}
    </div>
    <p class="gs-app__attente" data-store-etat="bientot">L'application arrive sur les deux boutiques. En attendant, tout le suivi est déjà dans votre espace client.</p>
{DECOR}
    <div class="gs-app__telephones">
{telephones()}
    </div>
  </div>
{TRACE}
</section>
'''
    return poser_icones(html)



# --------------------------------------------------------------------------
# Trajet en pointillés au bas de chaque section
# --------------------------------------------------------------------------
# Le même motif que la section de l'application, repris partout : un fil
# pointillé qui ondule d'une section à l'autre, comme un colis qui voyage.
# Il est posé en image de fond (classe .gs-trace--clair / --sombre dans
# site.css) : la structure des pages n'est pas touchée, donc rien ne bouge.
# Sont laissées de côté la bannière du haut (sa photo couvrirait le fil) et la
# section de l'application, qui a déjà le sien, avec ses avions.

SANS_TRACE = ('id="top"', 'id="application"')


def poser_traces(body, page):
    def repl(m):
        ouvrant, attrs = m.group(0), m.group(1)
        if any(x in attrs for x in SANS_TRACE):
            return ouvrant
        sombre = 'var(--ink)' in attrs or '#061a3f' in attrs
        classe = 'gs-trace--clair' if sombre else 'gs-trace--sombre'
        if 'class="' in attrs:
            return ouvrant.replace('class="', f'class="{classe} ', 1)
        return '<section ' + f'class="{classe}"' + attrs + '>'

    corps = body[body.find('<main'):body.rfind('</main>')]
    nouveau = re.sub(r'<section((?:(?!>)[\s\S])*)>', repl, corps)
    return body.replace(corps, nouveau, 1)


def page_specific(body, src, page):
    # Coquilles évidentes
    body = body.replace('Uilisez', 'Utilisez').replace('tableau&nbsp;&nbsp;ci-contre', 'tableau ci-contre')
    body = body.replace('Notre vison :', 'Notre vision :')
    # « Votre adresse aux USA » (Accueil et Nos services) : texte fourni par Goship Express (19/09/2026)
    if 'Comment commander avec Goship Express ?' in body:
        body = replace_once(body, 'Comment commander avec Goship Express ?', 'Comment acheter avec GoShip Express ?', page)
        body = replace_once(
            body,
            'Acheter avec Goship Express est très simple.</strong> Utilisez l\'adresse de réception en Floride dans le '
            'tableau ci-contre. Achetez ensuite sur Amazon, SHEIN, Walmart, eBay ou chez n\'importe quel fournisseur, '
            'comme d\'habitude. Au moment du paiement, renseignez l\'adresse de livraison exactement comme dans le '
            'tableau ci-contre, en ajoutant votre nom complet</p>',
            'Acheter sur GoShip Express, c\'est très simple.</strong> Commencez par créer votre compte et obtenir une '
            'adresse aux États-Unis. Ensuite, effectuez vos achats comme d\'habitude. Au moment de payer, il vous suffit '
            'de renseigner l\'adresse de livraison comme indiqué sur l\'image.</p>',
            page)
        body = replace_once(
            body,
            'Dès réception au dépôt de Medley, nous photographions votre colis, le regroupons avec vos autres achats si '
            'vous le souhaitez, puis l\'expédions vers Haïti ou Santo Domingo. Vous êtes livré à domicile ou retirez en '
            'agence, sans aucune démarche douanière de votre côté. <strong style="color:var(--ink);font-weight:700">'
            'C\'est aussi simple que ça.</strong>',
            'Enfin, patientez quelques jours et vos colis seront livrés à votre domicile ou vous pourrez les retirer '
            'dans nos agences sans avoir à vous soucier d\'aucune démarche supplémentaire. '
            '<strong style="color:var(--ink);font-weight:700">C\'est aussi simple que ça d\'acheter avec GoShip Express !</strong>',
            page)
    # Nom d'un transporteur concurrent resté dans un article repris d'un autre site
    if src == 'Article-boutiques-chinoises.dc.html':
        body = replace_once(body, 'en utilisant Boxpaq comme transporteur de confiance',
                            'en utilisant Goship Express comme transporteur de confiance', page)

    # Grilles : une colonne ne dépasse jamais la largeur disponible (petits téléphones)
    body = re.sub(r'minmax\((\d+px),1fr\)', r'minmax(min(\1,100%),1fr)', body)
    # Grand titre de l'accueil
    if src == 'Goship Express.dc.html':
        body = replace_once(body, '<div style="min-width:0;animation:om-rise .7s cubic-bezier(.2,.7,.3,1) both">',
                            '<div class="gs-hero-col" style="min-width:0;animation:om-rise .7s cubic-bezier(.2,.7,.3,1) both">', page)
        body = replace_once(body,
                            '<h1 style="margin-top:30px;font-size:clamp(42px,6.3vw,86px);line-height:.93;font-weight:800">'
                            'Vos colis partent<br>de Miami.<br><span style="color:var(--accent)">Ils arrivent chez eux.</span></h1>',
                            '<h1 class="gs-hero-titre" style="margin-top:30px;font-weight:800">'
                            'Livraison<br><span style="color:var(--accent)">internationale</span></h1>', page)
    # L'ouverture de compte mène au formulaire d'inscription
    body = re.sub(r'<a href="Contacts\.dc\.html#contact"( style="[^"]*" style-hover="[^"]*">\s*Ouvrir mon compte gratuitement)',
                  r'<a href="inscription.html"\1', body)
    # Parallaxe discrète des éléments flottants (cartes, pastilles, halos)
    for debut, vitesse in PARALLAXE:
        body = body.replace(f'<div style="{debut}', f'<div data-parallax="{vitesse}" style="{debut}')

    # Réseaux sociaux du pied de page
    body = re.sub(r'<a href="#top"( style="[^"]*"[^>]*)>IG</a>', r'<a href="#top" aria-label="Instagram"\1>IG</a>', body)
    body = re.sub(r'<a href="#top"( style="[^"]*"[^>]*)>Tok</a>', r'<a href="#top" aria-label="TikTok"\1>Tok</a>', body)
    body = sub_count(r'<a href="#top"( style="[^"]*"[^>]*)>wa</a>',
                     rf'<a href="https://wa.me/{WHATSAPP}" aria-label="WhatsApp"\1>wa</a>', body, page)
    body = sub_count(r'<a href="(https://www\.facebook\.com/[^"]*)" style=', r'<a href="\1" aria-label="Facebook" style=', body, page)

    # Carte « LV » vide et section vide (restes d'édition de la maquette)
    if src in ('Goship Express.dc.html', 'Nos-Services.dc.html'):
        body = sub_count(LV_CARD, '', body, page)
    if src == 'Goship Express.dc.html':
        body = sub_count(r'\n<section style="position:relative;background:var\(--ink\);color:#fff;overflow:hidden">\s*</section>\n',
                         '\n', body, page)
        # Photo principale : visible dès l'arrivée (pas de chargement différé),
        # description fidèle et ratio d'origine (plus de déformation)
        body = replace_once(body, 'alt="Colis en carton prêts à l\'expédition" loading="lazy" ',
                            'alt="Employé Goship Express contrôlant des colis à l\'entrepôt" ', page)
        body = replace_once(body,
                            'style="display: block; width: 100%; height: clamp(320px,38vw,470px); object-fit: fill"',
                            'style="display:block;width:100%;height:auto;aspect-ratio:1484/1060;object-fit:cover"', page)
        # Comptes entreprises : visuel fourni par Goship Express (19/09/2026), affiché en entier.
        # La carte « Engagement » passe en bas à gauche pour ne pas masquer l'encadré du bas.
        body = replace_once(body,
                            '<div style="position:relative;min-width:0">\n'
                            '      <div style="border-radius:24px 24px 96px 24px;overflow:hidden;',
                            '<div style="position:relative;min-width:0;width:100%;max-width:440px;margin-left:auto" class="gs-entreprise-visuel">\n'
                            '      <div style="border-radius:24px 24px 24px 96px;overflow:hidden;', page)
        body = replace_once(body,
                            '<img src="https://images.unsplash.com/photo-1565793298595-6a879b1d9492?auto=format&amp;fit=crop&amp;w=1200&amp;q=75" '
                            'alt="Flotte de camions au dépôt" loading="lazy" style="display: block; width: 644px; height: 678px; object-fit: cover">',
                            '<img src="assets/img/partenaire-logistique-goship.jpg" '
                            'alt="Avion cargo, camion et colis aux couleurs de Goship Express" width="900" height="1613" '
                            'loading="lazy" style="display:block;width:100%;height:auto">', page)
        body = replace_once(body,
                            '<div style="position:absolute;right:-6px;bottom:-34px;background:#fff;color:var(--ink);'
                            'border-radius:16px;padding:22px 26px;box-shadow:0 34px 64px -30px rgba(0,0,0,.65);max-width:250px">',
                            '<div data-parallax="-0.06" style="position:absolute;left:clamp(-30px,-2vw,0px);bottom:-34px;background:#fff;color:var(--ink);'
                            'border-radius:16px;padding:22px 26px;box-shadow:0 34px 64px -30px rgba(0,0,0,.65);max-width:250px" '
                            'class="gs-engagement">', page)
        # « Un colis suivi, un client rassuré » : visuels fournis par Goship Express (19/09/2026),
        # affichés en entier. La petite photo passe sous la grande (léger chevauchement) pour ne
        # masquer ni le camion ni l'enseigne ; la carte orange reste en bas à gauche.
        body = replace_once(body,
                            '    <div style="position:relative;min-width:0;order:2">\n'
                            '      <div style="border-radius:24px;overflow:hidden;border:1px solid #e3e8f2">\n'
                            '        <img src="https://images.unsplash.com/photo-1592085198739-ffcad7f36b54?auto=format&amp;fit=crop&amp;w=1200&amp;q=72" '
                            'alt="Entrepôt de consolidation, colis sur racks" loading="lazy" '
                            'style="display:block;width:100%;height:clamp(300px,34vw,430px);object-fit:cover">\n'
                            '      </div>\n'
                            '      <div style="position:absolute;right:-14px;bottom:-46px;width:clamp(180px,26%,240px);'
                            'border-radius:18px;overflow:hidden;border:5px solid #fff;box-shadow:0 30px 60px -30px rgba(6,26,63,.55)">\n'
                            '        <img src="https://images.unsplash.com/photo-1616432043562-3671ea2e5242?auto=format&amp;fit=crop&amp;w=800&amp;q=72" '
                            'alt="Camion de fret sur la route" loading="lazy" style="display:block;width:100%;height:150px;object-fit:cover">\n'
                            '      </div>\n'
                            '      <div style="position:absolute;left:-14px;bottom:-40px;background:var(--accent);color:#fff;'
                            'border-radius:16px;padding:20px 24px;box-shadow:0 30px 60px -30px rgba(6,26,63,.6)">\n'
                            '        \n'
                            '        <p style="font-size:13px;font-weight:600;max-width:120px;line-height:1.3">sur le corridor USA – Caraïbes</p>\n'
                            '      </div>\n'
                            '    </div>\n',
                            '    <div style="position:relative;min-width:0;order:2">\n'
                            '      <div style="position:relative">\n'
                            '        <div style="border-radius:24px;overflow:hidden;border:1px solid #e3e8f2">\n'
                            '          <img src="assets/img/camion-enseigne-goship.jpg" alt="Camion, enseigne et colis aux couleurs de Goship Express" '
                            'width="1146" height="678" loading="lazy" style="display:block;width:100%;height:auto">\n'
                            '        </div>\n'
                            '        <div data-parallax="-0.1" class="gs-suivi-corridor" style="position:absolute;left:-14px;bottom:-40px;'
                            'background:var(--accent);color:#fff;border-radius:16px;padding:20px 24px;box-shadow:0 30px 60px -30px rgba(6,26,63,.6)">\n'
                            '          <p style="font-size:13px;font-weight:600;max-width:120px;line-height:1.3">sur le corridor USA – Caraïbes</p>\n'
                            '        </div>\n'
                            '      </div>\n'
                            '      <div data-parallax="-0.07" class="gs-suivi-encart" style="position:relative;width:clamp(190px,48%,300px);'
                            'margin:clamp(-48px,-7%,-28px) -14px 0 auto;border-radius:18px;overflow:hidden;border:5px solid #fff;'
                            'box-shadow:0 30px 60px -30px rgba(6,26,63,.55)">\n'
                            '        <img src="assets/img/livraison-cliente-goship.jpg" alt="Livreur Goship Express remettant un colis à une cliente souriante" '
                            'width="900" height="538" loading="lazy" style="display:block;width:100%;height:auto">\n'
                            '      </div>\n'
                            '    </div>\n', page)

    # Adresse de réception (copie)
    if 'onClick="{{ onCopy }}"' in body:
        # Adresse de réception : valeurs exactes fournies par Goship Express (20/09/2026)
        body = body.replace(VALEUR_ADRESSE + '8140 NW 74th Ave, Unit 3</span>',
                            VALEUR_ADRESSE + '8140 NW 74th Ave Unit 3</span>')
        body = body.replace(VALEUR_ADRESSE + 'ABX 46780</span>', VALEUR_ADRESSE + 'APT-46780</span>')
        body = body.replace(VALEUR_ADRESSE + 'Medley (Miami)</span>', VALEUR_ADRESSE + 'Medley</span>')
        body = body.replace(VALEUR_ADRESSE + 'Florida (FL)</span>', VALEUR_ADRESSE + 'Florida</span>')
        # Ligne « Country » ajoutée après le code postal
        body = replace_once(body, LIGNE_ZIP, LIGNE_ZIP + LIGNE_PAYS, page)
        body = replace_once(body, '<div style="border:1px solid var(--accent);border-radius:6px;overflow:hidden">',
                            '<div data-address-table style="border:1px solid var(--accent);border-radius:6px;overflow:hidden">', page)
        body = replace_once(body, 'onClick="{{ onCopy }}"', 'data-action="copy-address"', page)
        label = '<span style="padding:18px 20px;font-weight:800;font-size:16px;color:var(--accent);border-right:1px solid #eef2f9">'
        body = replace_once(body, label, label.replace('<span ', '<span translate="no" '), page, count=8)

    # Suivi de colis
    if 'onSubmit="{{ onTrack }}"' in body:
        body = replace_once(body, 'onSubmit="{{ onTrack }}"', 'data-form="track"', page)
        body = replace_once(body, ' value="{{ trackValue }}" onChange="{{ onTrackInput }}"',
                            ' name="ref" required aria-label="Référence de votre colis" autocomplete="off" spellcheck="false"', page)

    # Formulaire de devis
    if src == 'Contacts.dc.html':
        body = ajouter_second_numero(body, page)
        body = replace_once(body, 'onSubmit="{{ onSubmit }}"', 'data-form="quote"', page)
        body = replace_once(body, 'onClick="{{ onReset }}"', 'data-action="form-reset"', page)
        body = replace_once(body, '<h3 style="font-size:26px;font-weight:800">Demande envoyée.</h3>',
                            '<h3 data-success-title style="font-size:26px;font-weight:800">Demande envoyée.</h3>', page)
        body = replace_once(body, '<p style="font-size:15.5px;color:#c0cdea">Merci ! Un responsable',
                            '<p data-success-text style="font-size:15.5px;color:#c0cdea">Merci ! Un responsable', page)
        body = replace_once(body, '          <button data-action="form-reset"',
                            f'          <a data-success-link hidden href="https://wa.me/{WHATSAPP}" target="_blank" rel="noopener" '
                            'style="font-weight:700;color:var(--accent)">WhatsApp ne s\'est pas ouvert ? Ouvrir WhatsApp</a>\n'
                            '          <button data-action="form-reset"', page)
        body = replace_once(body, '<span style="display:grid;place-items:center;width:54px;height:54px;border-radius:50%;background:var(--accent2);color:#fff;font-size:22px">',
                            '<span aria-hidden="true" style="display:grid;place-items:center;width:54px;height:54px;border-radius:50%;background:var(--accent2);color:#fff;font-size:22px">', page)
        body = replace_once(body, '<input required="required" placeholder="Votre nom"',
                            '<input name="nom" autocomplete="name" required="required" placeholder="Votre nom"', page)
        body = replace_once(body, '<input placeholder="Raison sociale"',
                            '<input name="entreprise" autocomplete="organization" placeholder="Raison sociale"', page)
        body = replace_once(body, '<input required="required" type="email" placeholder="vous@exemple.com"',
                            '<input name="email" autocomplete="email" required="required" type="email" placeholder="vous@exemple.com"', page)
        body = replace_once(body, '<input placeholder="+509 ..."',
                            '<input name="telephone" type="tel" autocomplete="tel" placeholder="+509 ..."', page)
        parts = body.split('<select style=')
        if len(parts) != 3:
            fail(page + ': deux listes déroulantes attendues')
        body = parts[0] + '<select name="corridor" style=' + parts[1] + '<select name="type_envoi" style=' + parts[2]
        body = replace_once(body, '<textarea rows="4"', '<textarea name="besoin" rows="4"', page)
        m = re.search(r'(<form data-form="quote"[^>]*>)', body)
        body = body.replace(m.group(1), m.group(1) + '\n        ' + HONEYPOT, 1)
        body = sub_count(r'(\n\s*)(<p style="[^"]*">Réponse sous 2 heures ouvrées)',
                         r'\1<p data-form-error hidden role="alert" style="font-size:14.5px;font-weight:600;color:#ffb38a">'
                         rf"L'envoi a échoué. Réessayez ou écrivez-nous sur WhatsApp au {PHONE_TXT}.</p>\1\2", body, page)

    # Inscription aux conseils (blog)
    if src == 'Blog.dc.html':
        body = replace_once(body, 'onSubmit="{{ onSubmit }}"', 'data-form="newsletter"', page)
        body = replace_once(body, '<input required="required" type="email" placeholder="vous@exemple.com"',
                            '<input name="email" autocomplete="email" aria-label="Votre adresse e-mail" required="required" type="email" placeholder="vous@exemple.com"', page)
        m = re.search(r'(<form data-form="newsletter"[^>]*>)', body)
        body = body.replace(m.group(1), m.group(1) + '\n        ' + HONEYPOT, 1)
        body = sub_count(r'(\n\s*)</form>', r'\1  <p data-form-note hidden role="status" style="flex:1 1 100%;font-size:16px;font-weight:600;color:#fff"></p>\1</form>', body, page)

    return body


def check_leftovers(body, page):
    for bad in ('{{', 'style-hover', '<sc-if', '<image-slot', '.dc.html', 'onClick=', 'onSubmit=', 'onChange=',
                'data-path-to-node', 'mu7c', 'mu77'):
        if bad in body:
            i = body.find(bad)
            fail(f'{page}: reste « {bad} » : …{body[max(0, i - 80):i + 80]}…')


# --------------------------------------------------------------------------
# <head>
# --------------------------------------------------------------------------
def text_of(fragment):
    t = re.sub(r'<br\s*/?>', ' ', fragment)
    t = re.sub(r'<[^>]+>', '', t)
    return re.sub(r'\s+', ' ', htmllib.unescape(t)).strip()


def shorten(text, limit=158):
    if len(text) <= limit:
        return text
    cut = text[:limit].rsplit(' ', 1)[0].rstrip(',;:')
    return cut + '…'


# Image des aperçus de lien (WhatsApp, Facebook) : il faut une adresse complète, donc une photo
# Unsplash tant que le site n'a pas de nom de domaine. L'accueil garde celle d'avant le
# remplacement de ses photos par les visuels Goship Express (19/09/2026).
OG_IMAGE_FIXE = {
    'index.html': 'https://images.unsplash.com/photo-1592085198739-ffcad7f36b54?auto=format&amp;fit=crop&amp;w=1200&amp;h=630&amp;q=72',
}


def og_image_for(body):
    m = re.search(r'<img src="(https://images\.unsplash\.com/[^"]+)"', body)
    if not m:
        return None
    return re.sub(r'w=\d+', 'w=1200&amp;h=630', m.group(1))


LOCAL_BUSINESS = {
    '@context': 'https://schema.org',
    '@type': 'LocalBusiness',
    'name': 'Goship Express LLC',
    'description': "Réception, consolidation, transport et livraison de colis entre les États-Unis, Santo Domingo et Haïti.",
    'telephone': '+1-849-538-6262',
    'email': 'goshipexpressllc@gmail.com',
    'address': {
        '@type': 'PostalAddress',
        'streetAddress': '8140 NW 74th Ave, Unit 3, Apt 46780',
        'addressLocality': 'Medley',
        'addressRegion': 'FL',
        'postalCode': '33166',
        'addressCountry': 'US',
    },
    'openingHoursSpecification': [{
        '@type': 'OpeningHoursSpecification',
        'dayOfWeek': ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'],
        'opens': '08:00',
        'closes': '18:00',
    }],
    'areaServed': ['US', 'HT', 'DO'],
    'sameAs': ['https://www.facebook.com/share/1EnDJ5wgFG/'],
}


def build_head(title, desc, og_image, uses_icons, jsonld, prefix='', scripts=(), noindex=False):
    esc = attr_escape
    lines = [
        '<!DOCTYPE html>',
        '<html lang="fr">',
        '<head>',
        '<meta charset="utf-8">',
        f'<meta http-equiv="Content-Security-Policy" content="{csp()}">',
        '<meta name="referrer" content="strict-origin-when-cross-origin">',
    ]
    if noindex:
        lines.append('<meta name="robots" content="noindex">')
    lines += [
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
        f'<title>{esc(title)}</title>',
        f'<meta name="description" content="{esc(desc)}">',
        '<meta name="theme-color" content="#061a3f">',
        '<meta property="og:type" content="website">',
        '<meta property="og:site_name" content="Goship Express">',
        '<meta property="og:locale" content="fr_FR">',
        f'<meta property="og:title" content="{esc(title)}">',
        f'<meta property="og:description" content="{esc(desc)}">',
    ]
    if og_image:
        lines.append(f'<meta property="og:image" content="{og_image}">')
        lines.append('<meta name="twitter:card" content="summary_large_image">')
    lines += [
        # favicon.ico à la racine : c'est lui que réclament d'office les navigateurs,
        # les favoris et les moteurs de recherche. Les PNG servent aux écrans fins.
        f'<link rel="icon" href="{prefix}favicon.ico" sizes="32x32">',
        f'<link rel="icon" href="{prefix}assets/img/favicon-32.png" type="image/png" sizes="32x32">',
        f'<link rel="icon" href="{prefix}assets/img/favicon-64.png" type="image/png" sizes="64x64">',
        f'<link rel="apple-touch-icon" href="{prefix}assets/img/apple-touch-icon.png">',
        '<link rel="preconnect" href="https://fonts.googleapis.com">',
        '<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>',
        '<link rel="preconnect" href="https://images.unsplash.com">',
        f'<link rel="stylesheet" href="{TEXT_FONTS}">',
    ]
    if uses_icons:
        lines.append(f'<link rel="stylesheet" href="{ICON_FONT}">')
    lines.append(f'<link rel="stylesheet" href="{prefix}assets/css/site.css">')
    for nom in ('config', 'site') + tuple(scripts):
        lines.append(f'<script src="{prefix}assets/js/{nom}.js" defer></script>')
    if jsonld:
        lines.append('<script type="application/ld+json">' + json.dumps(LOCAL_BUSINESS, ensure_ascii=False) + '</script>')
    lines += ['</head>', '<body>']
    return '\n'.join(lines) + '\n'


# --------------------------------------------------------------------------
# Assemblage d'une page
# --------------------------------------------------------------------------
def convert(src, out, title=None, desc=None):
    page = out
    raw = open(os.path.join(EXPORT, src), encoding='utf-8').read()
    m = re.search(r'<x-dc>(.*)</x-dc>', raw, re.S)
    body = m.group(1)
    body = re.sub(r'<helmet>.*?</helmet>', '', body, flags=re.S)
    body = re.sub(r'<template id="__bundler_thumbnail">.*?</template>\n?', '', body, flags=re.S)
    body = body.strip('\n') + '\n'

    body = page_specific(body, src, page)
    body = process_scif(body, SCIF_RULES, page)
    body = transform_topbar(body, page)
    body = transform_header(body, page)
    body = transform_why(body, page)
    body = transform_slots(body, page)

    # Conteneur de page, lien d'évitement et <main>
    body = replace_once(body, '<div style="overflow-x:hidden">',
                        '<div class="gs-page">\n<a class="gs-skip" href="#contenu-principal">Aller au contenu</a>', page)
    body = replace_once(body, '</header>\n', '</header>\n\n<main id="contenu-principal" tabindex="-1">\n', page)
    fpos = body.rfind('<footer')
    fin_main = '\n\n</main>\n\n'
    if 'data-form="track"' in body:
        # libellés des statuts pour le suivi de colis
        fin_main = '\n\n' + textes_compte(('statut-', 'etape-', 'etapes', 'maj', 'service-', 'pays-')) + fin_main
    body = body[:fpos].rstrip('\n') + fin_main + body[fpos:]

    body = transform_tags(body, page)

    # Promotion de l'application sur la page d'accueil : les deux boutons de
    # boutique dans la bannière du haut, et la section complète juste après
    # « Un colis suivi, un client rassuré » — assez haut pour que le visiteur la
    # voie sans avoir à chercher.
    if out == 'index.html':
        body = replace_once(
            body,
            '<div style="margin-top:46px;display:grid;grid-template-columns:'
            'repeat(auto-fit,minmax(min(150px,100%),1fr));gap:20px;max-width:620px">',
            f'''<div class="gs-hero-app">
        <span class="gs-hero-app__mot">Application mobile</span>
        <div class="gs-stores gs-stores--mini">
        {poser_icones(boutons_stores(mini=True))}
        </div>
      </div>
      <div style="margin-top:46px;display:grid;grid-template-columns:'''
            '''repeat(auto-fit,minmax(min(150px,100%),1fr));gap:20px;max-width:620px">''',
            page)
        ancre = '\n<section id="pourquoi"'
        body = replace_once(body, ancre, section_application() + ancre, page)

    body = poser_traces(body, page)

    # Image principale de chaque page : chargement prioritaire
    body = re.sub(r'(<section id="top"[^>]*>\s*<img )', r'\1fetchpriority="high" ', body, count=1)

    check_leftovers(body, page)

    h1 = re.search(r'<h1[^>]*>(.*?)</h1>', body, re.S)
    h1_text = text_of(h1.group(1)) if h1 else ''
    if title is None:  # article
        title = f'{h1_text} — Blog Goship Express'
        first_p = re.search(r'<section[^>]*>\s*<div[^>]*>\s*<p[^>]*>(.*?)</p>', body[body.find('</section>'):], re.S)
        desc = shorten(text_of(first_p.group(1)))
    uses_icons = 'Material Symbols Outlined' in body
    jsonld = out in ('index.html', 'contacts.html')
    scripts = ('api',) if 'data-form="track"' in body else ()
    doc = (build_head(title, desc, OG_IMAGE_FIXE.get(out) or og_image_for(body), uses_icons, jsonld, scripts=scripts)
           + body.rstrip('\n') + '\n</body>\n</html>\n')
    with open(os.path.join(OUT, out), 'w', encoding='utf-8') as f:
        f.write(doc)
    return {'out': out, 'title': title, 'desc': desc, 'size': len(doc.encode('utf-8'))}


# --------------------------------------------------------------------------
# Page 404
# --------------------------------------------------------------------------
def build_404():
    """Page 404 construite à partir de la page Support (même en-tête et pied)."""
    raw = open(os.path.join(OUT, 'support.html'), encoding='utf-8').read()
    head_end = raw.find('<body>') + len('<body>\n')
    body = raw[head_end:]
    s = body.find('<main id="contenu-principal" tabindex="-1">')
    e = body.find('</main>')
    main = '''<main id="contenu-principal" tabindex="-1">
<section id="top" style="position:relative;background:var(--ink);overflow:hidden">
  <img fetchpriority="high" src="https://images.unsplash.com/photo-1494412519320-aa613dfb7738?auto=format&amp;fit=crop&amp;w=2000&amp;q=72" alt="Terminal à conteneurs vu du ciel" style="position:absolute;inset:0;width:100%;height:100%;object-fit:cover">
  <div style="position:absolute;inset:0;background:linear-gradient(180deg,rgba(6,26,63,.86),rgba(6,26,63,.68))"></div>
  <div style="position:relative;max-width:1100px;margin:0 auto;padding:clamp(64px,9vw,128px) 24px;text-align:center;color:#fff">
    <span style="font-family:'IBM Plex Mono',monospace;font-size:12px;letter-spacing:.2em;text-transform:uppercase;color:var(--accent)">Erreur 404</span>
    <h1 style="margin-top:16px;font-size:clamp(36px,5.4vw,68px);line-height:1;font-weight:800">Ce colis s'est égaré</h1>
    <p style="margin:20px auto 0;max-width:560px;font-size:18px;color:#c4d0ec">La page demandée n'existe pas ou a été déplacée.</p>
    <div style="margin-top:34px;display:flex;flex-wrap:wrap;gap:14px;justify-content:center">
      <a href="/index.html" class="hv-fill-cta" style="display:inline-flex;align-items:center;gap:12px;background:var(--accent);color:#fff;font-weight:700;padding:17px 26px;border-radius:13px">Retour à l'accueil<span style="width:9px;height:9px;border-top:2px solid #fff;border-right:2px solid #fff;transform:rotate(45deg);display:block"></span></a>
      <a href="/contacts.html" class="hv-glass-soft" style="display:inline-flex;align-items:center;border:1px solid rgba(255,255,255,.3);color:#fff;font-weight:700;padding:17px 26px;border-radius:13px">Nous contacter</a>
    </div>
  </div>
</section>
'''
    body = body[:s] + main + body[e:]
    # Chemins absolus : la page 404 peut être servie depuis n'importe quelle URL.
    body = re.sub(r'(href|src)="(?!https?:|tel:|mailto:|#|/)([^"]+)"', r'\1="/\2"', body)
    head = build_head('Page introuvable — Goship Express', "Cette page n'existe pas ou a été déplacée.", None, False, False, prefix='/')
    head = head.replace('<meta name="viewport"', '<meta name="robots" content="noindex">\n<meta name="viewport"')
    with open(os.path.join(OUT, '404.html'), 'w', encoding='utf-8') as f:
        f.write(head + body)


# --------------------------------------------------------------------------
# Espace client et tableau de bord
# --------------------------------------------------------------------------
def build_compte():
    """Pages de l'espace client, construites avec l'en-tête et le pied de la page Support."""
    raw = open(os.path.join(OUT, 'support.html'), encoding='utf-8').read()
    body = raw[raw.find('<body>') + len('<body>\n'):]
    s = body.find('<main id="contenu-principal" tabindex="-1">')
    e = body.find('</main>') + len('</main>')
    for out, gabarit, title, desc, noindex in COMPTE_PAGES:
        main = open(os.path.join(PAGES, gabarit), encoding='utf-8').read().strip('\n')
        main = poser_icones(main.replace('[[textes]]', textes_compte()))
        if '[[' in main:
            fail(f'{out}: repère non remplacé')
        head = build_head(title, desc, None, False, False, scripts=('api', 'compte'), noindex=noindex)
        with open(os.path.join(OUT, out), 'w', encoding='utf-8') as f:
            f.write(head + body[:s] + main + body[e:])


def build_admin():
    """Tableau de bord (réservé à l'équipe, en français uniquement)."""
    doc = open(os.path.join(PAGES, 'admin.html'), encoding='utf-8').read()
    doc = poser_icones(doc.replace('[[fonts]]', TEXT_FONTS))
    if '[[' in doc:
        fail('admin.html : repère non remplacé')
    with open(os.path.join(OUT, 'admin.html'), 'w', encoding='utf-8') as f:
        f.write(doc)


# --------------------------------------------------------------------------
# CSS : états de survol
# --------------------------------------------------------------------------
def importantify(css):
    decls = [d.strip() for d in css.split(';') if d.strip()]
    return ';'.join(d if d.endswith('!important') else d + ' !important' for d in decls)


def write_hover_css():
    path = os.path.join(OUT, 'assets/css/site.css')
    css = open(path, encoding='utf-8').read()
    # Survol souris uniquement (évite les effets « collés » sur écran tactile) ;
    # les mêmes effets s'appliquent au focus clavier.
    hover = [f'.{cls}:hover{{{importantify(style)}}}' for style, cls in HOVER_NAMES.items()]
    focus = [f'.{cls}:focus-visible{{{importantify(style)}}}' for style, cls in HOVER_NAMES.items()]
    block = ('/*<hover>*/\n@media (hover:hover){\n' + '\n'.join('  ' + r for r in hover) + '\n}\n'
             + '\n'.join(focus) + '\n/*</hover>*/')
    css = re.sub(r'/\*<hover>\*/.*?/\*</hover>\*/', lambda _: block, css, flags=re.S)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(css)


ENTETES = [
    ('Content-Security-Policy', None),          # rempli par csp(entete=True)
    ('X-Frame-Options', 'DENY'),                # le site ne peut pas être affiché dans un cadre
    ('X-Content-Type-Options', 'nosniff'),
    ('Referrer-Policy', 'strict-origin-when-cross-origin'),
    ('Permissions-Policy', 'camera=(), microphone=(), geolocation=(), payment=(), interest-cohort=()'),
    ('Cross-Origin-Opener-Policy', 'same-origin'),
    ('Strict-Transport-Security', 'max-age=31536000; includeSubDomains'),
]


def write_entetes():
    """Fichiers d'en-têtes de sécurité, à côté du site.

    _headers   : lu tout seul par Netlify, Cloudflare Pages, Vercel…
    .htaccess  : lu tout seul par un hébergement Apache (cPanel, OVH, Hostinger…)
    Un hébergeur qui ne lit ni l'un ni l'autre ignore simplement ces fichiers :
    les pages gardent alors la protection inscrite dans leur propre en-tête.
    """
    valeurs = [(nom, csp(entete=True) if valeur is None else valeur) for nom, valeur in ENTETES]

    lignes = ['# En-têtes de sécurité (Netlify, Cloudflare Pages…). Voir README.md, « Sécurité ».',
              '/*']
    lignes += [f'  {nom}: {valeur}' for nom, valeur in valeurs]
    with open(os.path.join(OUT, '_headers'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(lignes) + '\n')

    # Netlify / Cloudflare Pages : les dossiers de travail ne sont pas des pages du site
    interdits = ['# Les fichiers de travail ne sont pas servis aux visiteurs.',
                 '/outils/*             /404.html  404',
                 '/application-mobile/* /404.html  404',
                 '/README.md            /404.html  404']
    with open(os.path.join(OUT, '_redirects'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(interdits) + '\n')

    apache = ['# En-têtes de sécurité (hébergement Apache). Voir README.md, « Sécurité ».',
              '<IfModule mod_headers.c>']
    apache += [f'  Header always set {nom} "{valeur}"' for nom, valeur in valeurs]
    apache += ['</IfModule>', '',
               '# Les fichiers de travail ne sont jamais servis aux visiteurs',
               '<FilesMatch "(^\\.|\\.(sql|py|md|command|json|lock)$)">',
               '  Require all denied',
               '</FilesMatch>',
               'RedirectMatch 404 ^/(outils|application-mobile|\\.claude)/',
               '',
               'ErrorDocument 404 /404.html']
    with open(os.path.join(OUT, '.htaccess'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(apache) + '\n')


def main():
    report = []
    for src, out, title, desc in MAIN_PAGES:
        report.append(convert(src, out, title, desc))
    for src in ARTICLES:
        report.append(convert(src, LINK_MAP[src]))
    build_404()
    build_compte()
    build_admin()
    write_hover_css()
    write_entetes()
    unused = set(HOVER_NAMES) - USED_HOVERS
    for r in report:
        print(f"{r['out']:<44} {r['size'] / 1024:6.1f} Ko  | {r['title']}")
        print(f"{'':<44}            {r['desc']}")
    if unused:
        print('Survols non utilisés :', unused)


if __name__ == '__main__':
    main()
