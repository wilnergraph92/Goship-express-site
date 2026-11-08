#!/usr/bin/env python3
# ==========================================================================
#  Goship Express — bande-son de la vidéo des villes (musique originale)
# ==========================================================================
#  Rien n'est emprunté : chaque son est synthétisé ici (numpy seul), pour
#  qu'aucune question de droits ne se pose à la diffusion. La musique de la
#  vidéo de référence n'est pas reprise.
#
#  120 BPM, une mesure = 2 s : les changements de scène de scene.js tombent
#  sur les mesures (intro 6 s, six villes de 6 s, final 8 s). Les effets
#  suivent le même minutage : souffle + impact à chaque plongée, « tching »
#  quand un titre arrive, deux « plop » sur « PLOP PLOP! ».
#
#  python3 musique.py [sortie.wav] [--effets]
#  --effets : seulement les effets (souffles, impacts, « tching », « plop »),
#  sans la musique — pour poser un morceau sous licence par-dessus, dans
#  fabriquer.sh (MUSIQUE=…) ou dans l'application (TikTok, Instagram).
# ==========================================================================
import sys
import wave
import numpy as np

SR = 44100
INTRO, VILLE, FINALE = 6.0, 6.0, 8.0
NB_VILLES = 6
# La miniature (première image de la vidéo, scene.js : MINIATURE) passe
# avant la musique : tous les temps ci-dessous comptent depuis la fin de la
# miniature, et poser() les décale de DEBUT.
DEBUT = 1.5
DUREE = INTRO + NB_VILLES * VILLE + FINALE
N = int((DEBUT + DUREE) * SR)
BEAT = 0.5
rng = np.random.default_rng(1804)
EFFETS = '--effets' in sys.argv
ARGS = [a for a in sys.argv[1:] if not a.startswith('--')]

G = np.zeros((2, N))        # bus principal (stéréo)
R = np.zeros((2, N))        # envoi vers la réverbération
KICKS = []                  # instants des grosses caisses (pour le « pompage »)


def poser(bus, son, t, gain=1.0, pan=0.0):
    """Ajoute un son mono ou stéréo à l'instant t (s), panoramique -1..1."""
    i = int((t + DEBUT) * SR)
    if i >= N:
        return
    if son.ndim == 1:
        g = np.sqrt([(1 - pan) / 2, (1 + pan) / 2]) * np.sqrt(2)
        son = np.vstack([son * g[0], son * g[1]])
    n = min(son.shape[1], N - i)
    if i < 0:
        son = son[:, -i:]; n = min(son.shape[1], N); i = 0
    bus[:, i:i + n] += son[:, :n] * gain


def temps(d):
    return np.arange(int(d * SR)) / SR


def filtre(x, bas=None, haut=None, pente=1.0):
    """Filtre passe-bas / passe-haut doux, dans le domaine fréquentiel."""
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / SR)
    m = np.ones_like(f)
    if bas:
        m *= 1 / (1 + (f / bas) ** (4 * pente))
    if haut:
        m *= 1 / (1 + (haut / np.maximum(f, 1)) ** (4 * pente))
    return np.fft.irfft(X * m, len(x))


def note(midi):
    return 440.0 * 2 ** ((midi - 69) / 12)


def enveloppe(n, a, r, total):
    e = np.ones(n)
    na, nr = int(a * SR), int(r * SR)
    e[:na] = np.linspace(0, 1, na) if na else 1
    if nr:
        e[-nr:] *= np.linspace(1, 0, nr)
    return e


# --- Instruments --------------------------------------------------------

def nappe(freqs, d):
    """Nappe de cordes synthétiques : dents de scie douces, désaccordées."""
    t = temps(d)
    g = np.zeros(len(t)); dr = np.zeros(len(t))
    for f in freqs:
        for k in range(1, 9):
            a = 1 / k
            g += a * np.sin(2 * np.pi * f * 0.997 * k * t + k)
            dr += a * np.sin(2 * np.pi * f * 1.003 * k * t + 2 * k)
    e = enveloppe(len(t), 0.35, 0.5, d)
    return np.vstack([g * e, dr * e]) / (len(freqs) * 3)


def basse(f, d):
    t = temps(d)
    s = np.sin(2 * np.pi * f * t) + 0.35 * np.sin(4 * np.pi * f * t) + 0.12 * np.sin(6 * np.pi * f * t)
    return s * np.exp(-t * 5) * enveloppe(len(t), 0.004, 0.03, d)


def pincee(f, d=0.35):
    t = temps(d)
    s = sum(np.sin(2 * np.pi * f * k * t) / k for k in (1, 3, 5, 7))
    return s * np.exp(-t * 11) * enveloppe(len(t), 0.002, 0.02, d)


def grosse_caisse():
    t = temps(0.45)
    f = 48 + 110 * np.exp(-t * 32)
    ph = 2 * np.pi * np.cumsum(f) / SR
    clic = rng.standard_normal(len(t)) * np.exp(-t * 400) * 0.3
    return (np.sin(ph) * np.exp(-t * 7) + clic)


def claquement():
    t = temps(0.35)
    b = filtre(rng.standard_normal(len(t)), bas=4500, haut=900)
    e = np.exp(-t * 22)
    for dt in (0.008, 0.017):
        e += np.roll(np.exp(-t * 60), int(dt * SR)) * 0.6
    return b * e * 0.55


def charleston(ouvert=False):
    t = temps(0.25 if ouvert else 0.06)
    b = filtre(rng.standard_normal(len(t)), haut=7000)
    return b * np.exp(-t * (14 if ouvert else 70)) * 0.35


def souffle(d=1.0, monte=True):
    """Souffle filtré qui balaie le spectre : la plongée dans les nuages."""
    n = int(d * SR)
    x = rng.standard_normal(n)
    out = np.zeros(n)
    bloc = 1024
    fen = np.hanning(bloc)
    f = np.fft.rfftfreq(bloc, 1 / SR)
    for i in range(0, n - bloc, bloc // 2):
        p = i / n
        centre = 300 * (40 ** (p if monte else 1 - p))
        m = np.exp(-((np.log(np.maximum(f, 1)) - np.log(centre)) ** 2) / 0.9)
        out[i:i + bloc] += np.fft.irfft(np.fft.rfft(x[i:i + bloc] * fen) * m, bloc)
    e = np.sin(np.pi * np.linspace(0, 1, n)) ** 1.5
    return out * e * 1.6


def impact():
    t = temps(1.8)
    sub = np.sin(2 * np.pi * (42 + 30 * np.exp(-t * 9)) * t) * np.exp(-t * 2.4)
    bruit = filtre(rng.standard_normal(len(t)), bas=1800) * np.exp(-t * 7) * 0.5
    return sub + bruit


def tching():
    """Éclat métallique quand le titre chromé se pose."""
    t = temps(1.2)
    s = sum(np.sin(2 * np.pi * f * t + i) * np.exp(-t * (3 + i * 1.5)) / (1 + i * 0.6)
            for i, f in enumerate((1870, 2950, 4210, 5630, 7380)))
    attaque = filtre(rng.standard_normal(len(t)), haut=5000) * np.exp(-t * 60)
    return (s * 0.3 + attaque * 0.4)


def plop(aigu=1.0):
    """Le « plop » du slogan : bulle qui éclate, hauteur qui chute."""
    t = temps(0.22)
    f = (720 * aigu) * np.exp(-t * 14) + 160 * aigu
    ph = 2 * np.pi * np.cumsum(f) / SR
    return np.sin(ph) * np.exp(-t * 18) * enveloppe(len(t), 0.003, 0.03, 0.22)


# --- Composition --------------------------------------------------------
# La mineur : Am – F – C – G, un accord par mesure
ACCORDS = [(57, 60, 64), (53, 57, 60), (48, 52, 55, 60), (55, 59, 62)]
BASSES = [33, 29, 36, 31]
FIN_RYTHME = DUREE - 2.0

nb_mesures = 0 if EFFETS else int(DUREE / 2)
for m in range(nb_mesures):
    t0 = m * 2.0
    acc = ACCORDS[m % 4]
    # Nappe : toujours là, plus présente quand le rythme est lancé
    poser(G, nappe([note(n) for n in acc], 2.4), t0, 0.55 if t0 < INTRO else 0.42)
    poser(R, nappe([note(n + 12) for n in acc], 2.4), t0, 0.18)
    if t0 >= FIN_RYTHME:
        continue
    # Arpège pincé en doubles croches, en ping-pong
    motif = [0, 1, 2, 1, 2, 0, 1, 2] * 2
    for k, idx in enumerate(motif):
        n = acc[idx % len(acc)] + 12 + (12 if k % 4 == 3 else 0)
        g = 0.13 if t0 >= INTRO else 0.07 * (t0 + 2) / INTRO
        poser(G, pincee(note(n)), t0 + k * 0.125, g, pan=-0.45 if k % 2 else 0.45)
        poser(R, pincee(note(n)), t0 + k * 0.125, g * 0.5)
    if t0 < 2.0:
        continue
    # Basse en croches
    for k in range(8):
        if t0 < INTRO - 2 and k % 2:
            continue
        poser(G, basse(note(BASSES[m % 4] + (12 if k in (3, 6) else 0)), 0.24), t0 + k * 0.25, 0.42)
    # Batterie
    for b in range(4):
        tb = t0 + b * BEAT
        if t0 >= INTRO or (t0 >= 4.0 and b % 2 == 0):
            poser(G, grosse_caisse(), tb, 0.95); KICKS.append(tb)
        if t0 >= INTRO:
            if b % 2 == 1:
                poser(G, claquement(), tb, 0.6); poser(R, claquement(), tb, 0.35)
            poser(G, charleston(ouvert=(b == 3)), tb + 0.25, 0.8, pan=0.3)
            poser(G, charleston(), tb, 0.35, pan=-0.3)

# Roulement qui annonce la première ville (4 → 6 s) et le final (40 → 42 s)
for debut, fin in ((4.0, INTRO), (INTRO + NB_VILLES * VILLE - 2.0, INTRO + NB_VILLES * VILLE)):
    k = 0
    t = fin if EFFETS else debut
    while t < fin - 0.01:
        p = (t - debut) / (fin - debut)
        poser(G, claquement(), t, 0.2 + 0.5 * p, pan=(k % 2 - 0.5) * 0.4)
        t += 0.25 if p < 0.5 else 0.125
        k += 1
    poser(G, souffle(fin - debut + 0.2, True), debut, 0.18)

# Plongées : souffle, puis impact sur la coupe
coupes = [INTRO + i * VILLE for i in range(NB_VILLES + 1)]
for tc in coupes:
    poser(G, souffle(1.1, True), tc - 0.75, 0.38, pan=-0.2)
    poser(G, souffle(0.9, False), tc - 0.1, 0.22, pan=0.2)
    poser(G, impact(), tc, 0.75)
    poser(R, impact(), tc, 0.3)

# Titres : « HAÏTI » dans l'intro, puis chaque ville
poser(G, impact(), 1.25, 0.55)
poser(G, tching(), 1.25, 0.5)
poser(R, tching(), 1.25, 0.5)
for i in range(NB_VILLES):
    tt = INTRO + i * VILLE + 1.12
    poser(G, tching(), tt, 0.42, pan=0.15)
    poser(R, tching(), tt, 0.45)

# « PLOP PLOP! » (final, scene.js : 0.8 → 1.2 puis 1.15 → 1.55)
tf = INTRO + NB_VILLES * VILLE
poser(G, plop(1.0), tf + 0.98, 0.9)
poser(G, plop(1.25), tf + 1.33, 0.9)
poser(R, plop(1.0), tf + 0.98, 0.3)
poser(R, plop(1.25), tf + 1.33, 0.3)
# Le bouton d'appel à l'action
poser(G, tching(), tf + 3.6, 0.35)
poser(R, tching(), tf + 3.6, 0.4)
# Dernier accord tenu et impact final
poser(G, impact(), FIN_RYTHME, 0.8)
poser(R, impact(), FIN_RYTHME, 0.4)

# Miniature : un éclat quand elle apparaît, puis le souffle de la plongée
poser(G, tching(), -DEBUT + 0.02, 0.4)
poser(R, tching(), -DEBUT + 0.02, 0.5)
poser(G, impact(), -DEBUT + 0.02, 0.35)
poser(G, souffle(1.0, True), -0.75, 0.38, pan=-0.2)
poser(G, impact(), 0.0, 0.6)
poser(R, impact(), 0.0, 0.25)

# --- Pompage : le reste se creuse à chaque grosse caisse ----------------
pompe = np.ones(N)
courbe = 1 - 0.45 * np.exp(-temps(0.4) * 9)
for tk in KICKS:
    i = int((tk + DEBUT) * SR); n = min(len(courbe), N - i)
    pompe[i:i + n] = np.minimum(pompe[i:i + n], courbe[:n])

# --- Réverbération : convolution par une queue de bruit décroissante ----
ri = temps(2.2)
rep = np.vstack([rng.standard_normal(len(ri)), rng.standard_normal(len(ri))]) * np.exp(-ri * 2.6)
rep = np.vstack([filtre(rep[0], bas=6000), filtre(rep[1], bas=6000)])
taille = 1 << int(np.ceil(np.log2(N + len(ri))))
reverb = np.vstack([np.fft.irfft(np.fft.rfft(R[c], taille) * np.fft.rfft(rep[c], taille), taille)[:N] for c in range(2)])
reverb *= 0.9 / (np.abs(reverb).max() + 1e-9) * np.abs(R).max()

mix = G * pompe + reverb * 0.6 * pompe
# Fondu final
nf = int(1.6 * SR)
mix[:, -nf:] *= np.linspace(1, 0, nf) ** 1.5
mix[:, :int(0.05 * SR)] *= np.linspace(0, 1, int(0.05 * SR))
# Saturation douce, puis normalisation à -1 dBFS
mix = np.tanh(mix / (np.abs(mix).max() + 1e-9) * 1.6)
mix *= 0.84 / np.abs(mix).max()

sortie = ARGS[0] if ARGS else ('effets.wav' if EFFETS else 'musique.wav')
with wave.open(sortie, 'wb') as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes((mix.T * 32767).astype('<i2').tobytes())
print('Écrit :', sortie, '—', DEBUT + DUREE, 's')
