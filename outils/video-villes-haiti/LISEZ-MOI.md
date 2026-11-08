# Vidéo « Nos villes de livraison en Haïti »

Reel vertical (1080 × 1920, 30 images/s, 51,5 s) qui présente les villes
desservies par Goship Express, avec le slogan **« Plop Plop Koli'w nan
Men'w »** et un appel à l'action (WhatsApp, site).

Tout est fabriqué ici, sans photo ni génération par IA : les décors sont
dessinés au canvas (`scene.js`), la musique est synthétisée (`musique.py`).
Aucun droit à acheter pour la diffuser. Police : Montserrat (licence OFL,
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
./fabriquer.sh                 # → goship-villes-haiti.mp4
node rendre.js --images 9,21   # quelques images PNG dans apercus/, pour vérifier
node rendre.js --miniature miniature.png   # la couverture seule, à publier avec la vidéo
```

Pour regarder l'animation en direct : servir la racine du dépôt et ouvrir
`outils/video-villes-haiti/index.html`.

## Modifier

- **Ajouter une ville** : une ligne dans `VILLES` (`scene.js`, nom, département,
  coordonnées) et sa fonction de dessin ; la durée s'allonge de 6 s. Mettre
  `NB_VILLES` à jour dans `musique.py`.
- **Changer le texte d'appel à l'action ou les coordonnées** : `dessinerFinale`.
- Le minutage (`INTRO`, `VILLE`, `FINALE`) est le même dans les deux fichiers :
  les coupes tombent sur les mesures de la musique (120 BPM). La miniature
  (`MINIATURE`) passe avant la musique : `DEBUT` dans `musique.py`, même valeur.
