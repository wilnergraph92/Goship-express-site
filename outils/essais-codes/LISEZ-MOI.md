# Les codes des étiquettes, comparés à deux références

`assets/js/codes.js` calcule lui-même les QR codes et les codes-barres des
étiquettes d'expédition, sans bibliothèque et sans service extérieur. Un code
mal calculé ne se voit pas à l'œil : il s'imprime, part avec le colis, et ne se
lit pas au scanner. Ce banc d'essai le compare donc, module par module, à deux
bibliothèques éprouvées.

```bash
pip3 install qrcode python-barcode
python3 outils/essais-codes/essai-codes.py
```

**À relancer après toute modification de `assets/js/codes.js`.**

## Ce qu'il prouve

- **QR codes** — dix textes, d'un caractère à 213 (la limite), accents compris.
  Pour chacun, les **huit masques** sont comparés à ceux de la bibliothèque
  `qrcode`, puis le masque retenu est vérifié. Un seul module de différence
  fait échouer l'essai. Sont ainsi contrôlés : le découpage en octets, les mots
  de correction (Reed-Solomon), l'entrelacement des blocs, le placement des
  motifs, l'information de format et celle de version.
- **Codes-barres** — sept textes, dont l'alphabet complet, les chiffres et
  toute la ponctuation, comparés à `python-barcode`. Le passage automatique au
  jeu C (les chiffres écrits deux par deux) est compris dans la comparaison.
- **Les refus** — un texte trop long pour un QR code, un code-barres vide, un
  accent dans un code-barres : chacun doit s'arrêter avec un message clair
  plutôt que produire un code muet.
- **Le dessin SVG** — la zone claire autour du code, le fond blanc, le titre lu
  par les lecteurs d'écran, les coordonnées de la première barre.

## Une différence assumée

La norme demande de noter les huit codes **finis** et de garder le moins
pénalisé. La bibliothèque `qrcode`, elle, note des codes dont la zone de format
est laissée vide : c'est un raccourci de son code, pas la norme. Sur quatre des
dix textes, elle choisit donc un autre masque que nous — aucun des deux codes
n'est illisible pour autant.

L'essai ne compare donc pas les deux choix. Il redonne nos huit codes aux
quatre règles de pénalité de la bibliothèque, et vérifie que le masque
qu'elles désignent est bien celui que `codes.js` a retenu.

## Node.js

Le calcul est écrit en JavaScript, pour le navigateur. Node ne sert qu'à le
lancer hors du navigateur, le temps de l'essai : `essai-codes.js` remplace le
navigateur par le strict minimum (de quoi créer une balise SVG), charge
`assets/js/codes.js` tel quel, et écrit ce qu'il calcule en JSON. Aucun code
d'essai ne se trouve dans le fichier livré.
