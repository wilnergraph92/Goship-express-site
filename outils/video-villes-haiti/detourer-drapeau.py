#!/usr/bin/env python3
# ==========================================================================
#  Détoure la photo du drapeau haïtien (fond de ciel → transparent) pour la
#  vidéo : photos/drapeau.png. Appelé par preparer-photos.sh.
#
#  Le ciel se reconnaît à sa couleur (bleu clair grisé ou blanc) ET au fait
#  qu'il touche le bord de l'image : le blanc du panneau des armes, enfermé
#  dans le bleu et le rouge, n'est donc jamais retiré.
#
#  python3 detourer-drapeau.py source.jpg sortie.png
# ==========================================================================
import sys
from collections import deque
import numpy as np
from PIL import Image, ImageFilter

src, dst = sys.argv[1], sys.argv[2]
im = np.asarray(Image.open(src).convert('RGB')).astype(float)
r, g, b = im[..., 0], im[..., 1], im[..., 2]
bb = np.maximum(b, 1)
ciel = (r / bb > 0.45) & (g / bb > 0.62) & (r < g + 12)
h, w = ciel.shape

# Remplissage depuis les bords : seul le ciel relié au bord disparaît
fond = np.zeros_like(ciel)
file = deque()
for y in range(h):
    for x in (0, w - 1):
        if ciel[y, x] and not fond[y, x]:
            fond[y, x] = True; file.append((y, x))
for x in range(w):
    for y in (0, h - 1):
        if ciel[y, x] and not fond[y, x]:
            fond[y, x] = True; file.append((y, x))
while file:
    y, x = file.popleft()
    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        ny, nx = y + dy, x + dx
        if 0 <= ny < h and 0 <= nx < w and ciel[ny, nx] and not fond[ny, nx]:
            fond[ny, nx] = True; file.append((ny, nx))

alpha = Image.fromarray(((~fond) * 255).astype(np.uint8))
# Bord adouci, légèrement rentré pour ne pas garder de liseré de ciel
alpha = alpha.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(0.8))
rgba = Image.fromarray(im.astype(np.uint8)).convert('RGBA')
rgba.putalpha(alpha)
rgba = rgba.resize((w * 3, h * 3), Image.LANCZOS).filter(ImageFilter.UnsharpMask(2, 60, 2))
rgba.save(dst)
print('Drapeau détouré :', dst, f'({fond.mean() * 100:.0f} % de fond retiré)')
