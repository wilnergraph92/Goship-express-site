# Les trois téléphones de la section « Vos colis dans votre poche »

Les trois images `assets/img/app-ecran-colis.webp`, `app-ecran-accueil.webp` et
`app-ecran-prealerte.webp` ne sont pas des photos ni des captures d'écran : elles
sont **dessinées** par `ecrans.py`, aux mesures exactes de l'application mobile.

Rien n'est inventé : les couleurs et les polices sont lues dans
`application-mobile/lib/theme.js` et `node_modules/@expo-google-fonts`, et chaque
écran reprend la disposition d'un écran réel de l'application :

| Image                     | Écran de l'application         |
| ------------------------- | ------------------------------ |
| `app-ecran-colis.webp`    | `app/colis/[id].jsx`           |
| `app-ecran-accueil.webp`  | `app/(onglets)/index.jsx`      |
| `app-ecran-prealerte.webp`| `app/(onglets)/prealerte.jsx`  |

## Refaire les images

Depuis la racine du site :

```bash
python3 outils/ecrans-app/ecrans.py
```

Les trois fichiers sont réécrits dans `assets/img/`. Il n'y a rien d'autre à
faire : le site les reprend telles quelles.

Le script a besoin de Pillow. L'application doit avoir ses dépendances
installées (`application-mobile/node_modules`), car les polices viennent de là.

## Modifier ce que montrent les écrans

Tout est dans `ecrans.py`, dans les trois fonctions `ecran_colis()`,
`ecran_accueil()` et `ecran_prealerte()` : le nom de la cliente, son code GSE,
l'adresse de Miami, les colis et leurs statuts, les champs de la pré-alerte.

Deux repères pour s'y retrouver :

- **Tout est écrit en points**, comme dans l'application : l'écran fait
  390 × 843 points, la taille d'un téléphone courant. `ECHELLE` multiplie le
  tout pour obtenir l'image. Augmenter `ECHELLE` donne des images plus fines
  mais plus lourdes ; la valeur actuelle suffit largement, même sur un écran
  très fin.
- **Un fond semi-transparent passe par `rect_voile()`**, jamais par `rect()` :
  dessiné directement, il remplacerait les pixels de l'image au lieu de les
  laisser paraître, et ressortirait en aplat opaque.

## Les noms affichés

« Marie-Ange Dorvil », le code `GSE-4323` et les numéros de colis sont des
exemples. L'adresse de Miami, elle, est la vraie adresse de l'entrepôt : si elle
change, il faut la corriger ici aussi (elle apparaît dans `ecran_accueil()`).

## Si l'application évolue

Quand un écran de l'application change pour de bon, il faut reprendre la
fonction correspondante ici, sinon le site montrera une version périmée. C'est
le seul entretien à prévoir.
