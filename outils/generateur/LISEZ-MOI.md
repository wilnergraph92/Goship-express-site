# Le générateur des pages du site

Les pages françaises à la racine du site (`index.html`, `contacts.html`,
`a-propos.html`, les articles du blog…) **ne s'écrivent pas à la main** : elles
sont fabriquées par `build.py` à partir de deux sources, puis traduites en
anglais, espagnol et créole par `outils/traduire.py`.

```bash
python3 outils/generateur/build.py   # les pages françaises
python3 outils/traduire.py           # en/, es/, ht/
```

**Les deux commandes vont ensemble.** Lancer la première sans la seconde laisse
les trois autres langues en retard sur le français.

## Les deux sources

| Dossier   | Ce qu'il contient |
| --------- | ----------------- |
| `export/` | La maquette Claude Design exportée (`*.dc.html`) et ses images. C'est d'elle que viennent l'accueil, À propos, Nos services, Contacts, le blog et les pages légales. On n'y touche pas : `build.py` la transforme. |
| `pages/`  | Les pages écrites à la main, que la maquette ne contient pas : l'espace client (inscription, connexion, mon compte, nouveau mot de passe) et le tableau de bord (`admin.html`). |

`build.py` lit ces deux sources, applique les corrections et les ajouts du site
(icônes, en-têtes de sécurité, section de l'application mobile, fil en
pointillés, formulaires…) et écrit les pages à la racine.

## Modifier un texte

- **Texte venu de la maquette** (accueil, services, blog…) : cherchez-le dans
  `build.py`. Il y est presque toujours déjà, dans un `replace_once(...)` qui le
  corrige. Sinon, ajoutez-en un.
- **Texte de l'espace client ou du tableau de bord** : modifiez directement le
  fichier correspondant dans `pages/`.
- **Traductions** : `outils/traductions/*.json`. Pour voir ce qui manque :
  `python3 outils/traduire.py --manquants`.

Ne modifiez jamais une page à la racine : la prochaine génération l'écrasera.

## La vérification qui compte

Après chaque changement, le site doit se reconstruire **à l'identique** :
relancer les deux commandes sur un site déjà à jour ne doit rien modifier.

```bash
python3 outils/generateur/build.py && python3 outils/traduire.py && git status
```

Si `git status` ne montre rien, tout va bien. S'il montre des pages modifiées
alors que vous n'avez rien changé, c'est que le générateur n'est pas
déterministe : il faut comprendre pourquoi avant de continuer.

`build.py` s'arrête net, avec un message, si un texte qu'il cherche à remplacer
a disparu de la maquette. C'est voulu : mieux vaut une erreur qu'une page
silencieusement incomplète.

## Où le site est écrit

Par défaut, deux dossiers au-dessus de `build.py` — c'est-à-dire la racine du
projet, quel que soit l'endroit où le dépôt est cloné. Pour écrire ailleurs
(par exemple pour comparer) :

```bash
GSE_OUT=/un/autre/dossier python3 outils/generateur/build.py
```
