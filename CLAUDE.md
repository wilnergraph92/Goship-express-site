# Goship Express — site et tableau de bord

Site vitrine et espace client d'une entreprise de transport de colis
Miami → Haïti / République dominicaine. Site statique, sans build : les
fichiers du dépôt sont exactement ceux qui sont servis.

## Avant de toucher au code

- **Tout est commenté en français**, avec les accents, dans un ton qui
  explique le pourquoi plutôt que le quoi. Écris tes commentaires dans le
  même registre. Les noms de variables et de fonctions sont en français
  (`chercherClient`, `montrerClient`, `argent`, `colisEdite`).
- **Aucune étape de compilation.** Pas de bundler, pas de TypeScript, pas
  de framework. JavaScript ES5 dans des IIFE, `var`, pas de modules.
- **La racine du dépôt est la racine du site déployé.** Tout fichier
  ajouté ici part en ligne sur GitHub Pages. N'y dépose jamais de secret
  ni de fichier de travail.

## Architecture

```
index.html, nos-services.html, …   27 pages à la racine
admin.html                          tableau de bord équipe
mon-compte.html, connexion.html     espace client
en/ es/ ht/                         traductions (copies complètes des pages)
assets/js/                          toute la logique
outils/*.sql                        migrations Supabase
application-mobile/                 app Expo — DÉPÔT SÉPARÉ, ignoré par git
```

### Les fichiers JavaScript

| Fichier | Rôle |
|---|---|
| `api.js` | Couche de données, `window.GoshipAPI`. Le cœur. |
| `admin.js` | Tableau de bord équipe : colis, clients, factures |
| `compte.js` | Espace client |
| `impression.js` | Étiquettes 4×6 et factures A4, en 4 langues |
| `site.js` | Pages publiques, suivi de colis |
| `codes.js` | QR codes et codes-barres |
| `notifications.js` | E-mail et WhatsApp |
| `config.js` | Clés Supabase et réglages — **contient des secrets** |

### Le double backend — à comprendre avant tout

`api.js` expose **une seule interface** mais deux implémentations :

```js
var MODE = CFG.supabaseUrl && CFG.supabaseKey ? 'supabase'
         : (LOCAL ? 'demo' : 'off');
```

- **`supabase`** — la vraie base, en production
- **`demo`** — tout en `localStorage`, si aucune clé n'est configurée et
  qu'on est en local (`file:` ou localhost). Compte de test :
  `admin@goship.demo` / `demo1234`, avec `API.admin.exemples()` pour
  peupler des données.
- **`off`** — en ligne sans configuration : l'interface le dit et
  n'essaie rien.

**Toute méthode ajoutée à `API.admin` doit l'être dans les deux
implémentations**, sinon le mode démo casse silencieusement. Elles sont
loin l'une de l'autre dans le fichier — cherche le nom de la méthode, tu
la trouveras deux fois.

### Les règles métier vivent dans la base

`outils/supabase-services.sql` : déclencheurs (`regles_colis`,
`regles_facture`, `regles_facture_ligne`, `journaliser_*`) qui s'appliquent
à tout chemin d'écriture, et fonctions de service appelées par `api.js`
(`creer_colis`, `modifier_colis`, `changer_statut_colis`,
`statuts_possibles`, `trouver_colis`, `facturer_colis`, `creer_facture`).
Le prix, le statut initial, les transitions, les doublons et le journal
d'audit se décident là, jamais dans une page.

Le mode démo en garde une copie dans `api.js` (`TRANSITIONS`,
`reglesColis`, `facturerColisDemo`…). **Une règle changée dans le SQL se
change aussi dans la copie démo**, et `python3
outils/essais-services/essai-services.py` compare les deux (matrice des
transitions cas par cas, tarifs, arrondis). Les erreurs métier ont la
forme `message = CODE`, `detail = phrase`, `hint = 'goship'` ;
`erreurSupabase` les reconnaît et `admin.js` affiche la phrase.

## Facturation

Transport facturé **5 $/lb**, plus **10 $ de frais de service** une seule
fois par facture. Les deux constantes vivent dans `api.js`, exposées
gelées via `API.tarifs` (`Object.freeze`) : aucune page ne peut les
modifier. Le tarif se remplace colis par colis depuis le formulaire
admin ; les frais, jamais.

**Le prix est stocké sur le colis** (`prix_usd`, `tarif_lb_usd`), jamais
recalculé à l'affichage : changer le tarif ne doit pas modifier une
facture déjà remise à un client.

Les quatre montants d'une facture viennent tous de
`API.outils.totauxFacture()` — écran et papier doivent afficher la même
chose. Ne recalcule jamais à la main ailleurs.

Le prix d'un colis se calcule dans la base (`prix_transport`, appelé par
`regles_colis`) : celui qu'envoie une page est ignoré. Le champ prix du
formulaire admin n'est qu'un aperçu en lecture seule. Une nouvelle facture
passe par `creer_facture` / `facturer_colis`, qui refusent un colis déjà
sur une facture active (`INVOICE_ALREADY_EXISTS`).

Les factures antérieures au 22/09/2026 portent `frais_service_usd = 0`,
volontairement : leur total ne devait pas changer rétroactivement.

## Base de données

Tables : `clients`, `colis`, `colis_historique`, `notifications`,
`prealertes`, `factures`, `facture_lignes`, `appareils`, `journal_audit`. Vue
`colis_details` (colis + client). RLS activé partout, ~35 policies.

Les migrations sont dans `outils/*.sql`, à exécuter dans Supabase >
SQL Editor. Ordre sur une base neuve : `supabase.sql`,
`supabase-facturation.sql`, `supabase-services.sql`. Elles sont écrites pour être **rejouables sans risque** :
`add column if not exists`, valeurs par défaut neutres, aucune
suppression. Garde cette propriété pour toute nouvelle migration.

Code client : `GSE-` suivi d'au moins 4 chiffres. `API.normaliserCode()`
ne retient que les chiffres — attention, une adresse e-mail contenant
des chiffres ne doit jamais passer par là.

## Traductions

Les pages traduites sont des **copies complètes** dans `en/`, `es/`,
`ht/`. `outils/traduire.py` et `outils/traductions/` servent à les
régénérer. `admin.html` n'est pas traduit (réservé à l'équipe, en
français).

Speed Express, le projet frère, fonctionne tout autrement
(dictionnaires JS à l'exécution) — ne transpose pas d'un projet à
l'autre.

## Travailler et vérifier

Ouvre `Voir le site en local.command`, ou sers le dossier. Le mode démo
s'active tout seul en local, **sans configuration** — or `config.js`
contient les vraies clés : servi tel quel, même en local, le site parle à
la base de production. Pour un essai automatisé, remplace `config.js` par
une configuration vide (interception de requête) et coupe tout appel à
`*.supabase.co`.

Bancs d'essai : `outils/essais-services/` (règles métier, SQL + démo),
`outils/essais-sql/` (e-mails, factures client), `outils/essais-codes/`
(QR, Code128). Tous tournent sans toucher la vraie base.

Déploiement : **GitHub Pages depuis `main`**. Un `git push origin main`
met le site en ligne. Les commits vont directement sur `main` — pas de
branche pour un changement ordinaire.

Messages de commit : une phrase en français qui dit ce que ça change
pour l'utilisateur, pas un préfixe technique. Voir `git log`.

## Pièges

- `.mcp.json` ou tout fichier de config déposé à la racine part en ligne.
- `config.js` contient la clé Supabase : ne la recopie pas dans un
  fichier d'essai qui serait ensuite commité.
- Les montants s'écrivent avec une virgule en français (`40,00 $`) ;
  `API.outils.argent()` s'en charge.
