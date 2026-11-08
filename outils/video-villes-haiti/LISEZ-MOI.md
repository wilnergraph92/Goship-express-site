# Vidéo « Nos villes de livraison en Haïti »

Reel vertical (1080 × 1920, 30 images/s, 51,5 s) qui présente les villes
desservies par Goship Express, avec le slogan **« Plop Plop Koli'w nan
Men'w »** et un appel à l'action (WhatsApp, site).

Chaque ville s'affiche en **photo** si `photos/<ville>.jpg` existe, sinon avec
son **décor dessiné** au canvas (`scene.js`). La musique est synthétisée
(`musique.py`).

Les photos ne sont **pas** dans le dépôt (`photos/` est ignoré) : ce sont des
images de tiers. Avant de diffuser la vidéo, s'assurer d'avoir l'accord de
leurs auteurs. Les décors dessinés et la musique, eux, sont libres de droits. Police : Montserrat (licence OFL,
`polices/OFL.txt`). Le dossier `outils/` n'est jamais publié sur le site.

## Déroulé

| Temps | Scène |
|---|---|
| 0 – 1,5 s | Miniature (première image) : six vignettes de villes, logo, « Livraison partout en HAÏTI », slogan |
| 1,5 – 7,5 s | Logo, « Livraison partout en HAÏTI », carte d'Haïti, trajet Miami → Port-au-Prince |
| 7,5 – 43,5 s | Port-au-Prince, Cap-Haïtien, Gonaïves, Les Cayes, Hinche, Jacmel (6 s chacune) |
| 43,5 – 51,5 s | « PLOP PLOP! Koli'w nan Men'w », carte complète, bouton « Expédiez maintenant », WhatsApp, site |

## Fabriquer

```sh
./preparer-photos.sh ~/Photos/villes   # port-au-prince.jpg, cap-haitien.jpg, gonaives.jpg,
                                       # les-cayes.jpg, hinche.jpg, jacmel.jpg (facultatif)
./fabriquer.sh                 # → goship-villes-haiti.mp4 (musique originale),
                               #   …-effets-seuls.mp4 (pour ajouter un morceau dans
                               #   TikTok / Instagram) et …-miniature.png
MUSIQUE=morceau.wav ./fabriquer.sh   # un autre morceau, déjà calé (voir fabriquer.sh)
node rendre.js --images 9,21   # quelques images PNG dans apercus/, pour vérifier
node rendre.js --miniature miniature.png   # la couverture seule, à publier avec la vidéo
```

Pour regarder l'animation en direct : servir la racine du dépôt et ouvrir
`outils/video-villes-haiti/index.html`.

## Modifier

- **Cadrer une photo** : `photo.cy` (hauteur du centre), `photo.pan`, `photo.drapeau`
  dans `VILLES` (`scene.js`).
- **Ajouter une ville** : une ligne dans `VILLES` (`scene.js`, nom, département,
  coordonnées) et sa fonction de dessin ; la durée s'allonge de 6 s. Mettre
  `NB_VILLES` à jour dans `musique.py`.
- **Changer le texte d'appel à l'action ou les coordonnées** : `dessinerFinale`.
- Le minutage (`INTRO`, `VILLE`, `FINALE`) est le même dans les deux fichiers :
  les coupes tombent sur les mesures de la musique (120 BPM). La miniature
  (`MINIATURE`) passe avant la musique : `DEBUT` dans `musique.py`, même valeur.

## Musique d'un autre morceau

La musique originale de `musique.py` est libre de droits. Un morceau du
commerce (celui d'une autre publicité, par exemple) n'est couvert que par la
licence de celui qui l'a acheté : les réseaux le reconnaissent et rendent la
vidéo muette ou la retirent. Pour un tel morceau, publier la version
`effets-seuls` et l'ajouter depuis la bibliothèque musicale de l'application,
où il est sous licence. Le morceau n'est jamais commité ici.
