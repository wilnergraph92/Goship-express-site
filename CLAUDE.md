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
assets/css/site.css                 styles du site (et de l'espace client)
assets/css/tableau.css              habillage du tableau de bord seul (admin.html)
outils/*.sql                        migrations Supabase
application-mobile/                 app Expo — DÉPÔT SÉPARÉ, ignoré par git
bureau/                             app de bureau Windows/macOS (Electron) — jamais publiée
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
| `scan-parser.js` | Lecture d'un code scanné (étiquette, QR, suivi vendeur) — aucune requête |
| `scanner.js` | Onglet « Scanner » du tableau de bord (`admin.html#scanner`) |
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

**Le statut d'un colis ne change que par un événement**
(`outils/supabase-evenements.sql`) : `executer_operation` est la seule
porte ; le déclencheur `verrou_statut` refuse tout autre `UPDATE` du
statut, et `evenement_immuable` toute modification d'une ligne de
`colis_historique` (on corrige par un événement `CORRECTION`, motif
obligatoire). `changer_statut_colis` et `statuts_possibles` vivent dans ce
fichier, pas dans `supabase-services.sql`. Le poste de scan
(`outils/supabase-scanner.sql`, `scanner_colis` / `scanner_operation`)
n'est qu'une porte de plus vers `executer_operation` : aucune règle n'y
vit. Les étiquettes ne changent pas pour lui — il lit le Code128 (numéro)
et le QR (lien `index.html?suivi=`) déjà imprimés. Les colonnes d'événement
(`type_evenement`, `statut_precedent`, `auteur_id`, `visibilite`,
`corrige_id`…) sont déclarées dans `supabase.sql`, parce que le suivi
public et la règle de lecture du client s'en servent. Les huit statuts ne
changent pas ; les événements sont plus fins (`types_evenement()`).

Le mode démo en garde une copie dans `api.js` (`TRANSITIONS`,
`TYPES_EVENEMENT`, `validerOperation`, `operationDemo`,
`reglesColis`, `facturerColisDemo`…). **Une règle changée dans le SQL se
change aussi dans la copie démo**, et `essai-services.py` /
`essai-evenements.py` comparent les deux cas par cas. Les erreurs métier ont la
forme `message = CODE`, `detail = phrase`, `hint = 'goship'` ;
`erreurSupabase` les reconnaît et `admin.js` affiche la phrase.

### Rôles et permissions

Un rôle par compte (`clients.role`) : `client`, `employe`, `gerant`,
`admin`. Un rôle ne sert qu'à lire sa liste de permissions
(`permissions_du_role`, `supabase.sql` partie 4, avec `peut` et
`exiger_permission`) : **aucune règle ne teste un nom de rôle**. Toute
nouvelle fonction ou règle RLS demande une permission (`clients.*`,
`shipments.*`, `invoices.*`, `payments.*`, `reports.view`, `users.view`,
`roles.manage`, `settings.manage`, `audit_logs.view`) ; une fonction qui
n'existe pas n'a pas de permission. `est_admin()` n'est gardée que pour
l'application mobile et les anciennes pages. Le rôle ne change que par
`changer_role` (`roles.manage`, journalisé) ; le déclencheur `verrou_role`
refuse tout autre chemin. Côté pages, `API.permissions()` et
`data-permission` sur les éléments de `admin.html` ne font que masquer :
la base refuse d'elle-même. La matrice a une copie démo
(`PERMISSIONS_DES_ROLES` dans `api.js`), comparée par
`essai-permissions.py` ; les méthodes démo appellent `exiger(d, 'perm')`.

## Facturation

Transport facturé **5 $/lb**, plus **10 $ de frais de service** une seule
fois par facture. Les deux constantes vivent dans `api.js`, exposées
gelées via `API.tarifs` (`Object.freeze`) : aucune page ne peut les
modifier. Le tarif se remplace colis par colis depuis le formulaire
admin ; les frais, jamais.

**Le prix est stocké sur le colis** (`prix_usd`, `tarif_lb_usd`), jamais
recalculé à l'affichage : changer le tarif ne doit pas modifier une
facture déjà remise à un client.

Les montants d'une facture viennent tous de
`API.outils.totauxFacture()` — écran et papier doivent afficher la même
chose. Ne recalcule jamais à la main ailleurs. Le grand total est
`montant_usd`, arrêté à la création ; le payé, le solde et l'état
(`paye_usd`, `solde_usd`, `etat_paiement`) sont calculés par la base et
`totauxFacture` les reprend tels quels.

**Les paiements** (`outils/supabase-finances.sql`) : une ligne par
encaissement dans `paiements`, écrite seulement par
`enregistrer_paiement` (verrou sur la facture, trop-payé refusé, clé
d'idempotence). Un paiement ne se modifie ni ne se supprime : il s'annule
(`annuler_paiement`, motif obligatoire). `factures.montant_paye_usd`,
`statut`, `moyen` et `payee_le` suivent les paiements (déclencheur
`garde_facture` : aucune page ne les écrit). Une facture ne se supprime
pas : `annuler_facture` (motif, refusée si elle a reçu de l'argent).
Regrouper : `regrouper_factures` (annule les anciennes, `remplacee_par`).
Les trois statuts stockés ne changent pas ; « partielle » et « en_retard »
sont des états déduits. Même copie démo que le reste (`ajouterPaiementDemo`,
`recalculerFactureDemo`…), comparée par `essai-finances.py` /
`essai-finances.js`.

Le prix d'un colis se calcule dans la base (`prix_transport`, appelé par
`regles_colis`) : celui qu'envoie une page est ignoré. Le champ prix du
formulaire admin n'est qu'un aperçu en lecture seule. Une nouvelle facture
passe par `creer_facture` / `facturer_colis`, qui refusent un colis déjà
sur une facture active (`INVOICE_ALREADY_EXISTS`).

Les factures antérieures au 22/09/2026 portent `frais_service_usd = 0`,
volontairement : leur total ne devait pas changer rétroactivement.

### Le tableau de bord

Habillage : `assets/css/tableau.css`, chargé par `admin.html` seulement —
menu latéral (les onglets `data-onglet-vue`), barre du haut (titre de la
vue, date et heure de l'appareil, recherche rapide, cloche des alertes,
réglages, compte). Préfixe `gs-td__` (`gs-app` est déjà pris par la section
de l'application mobile du site). Les réglages sont des préférences
d'affichage gardées en `localStorage` (`gse-tableau-reglages`) : aucune
donnée, aucune permission.

`outils/supabase-tableau-de-bord.sql` : fonctions de **lecture** seulement
(`vue_generale`, `colis_a_traiter`, `recherche_rapide`, `clients_soldes`,
`mon_resume`) et leurs index. Tout chiffre affiché par la vue générale, la
liste des clients ou « Mon compte » vient de là : **aucun total ne se fait
dans une page** (pas de `reduce` sur une liste pour un KPI), et une donnée
que la base ne connaît pas (dépenses, scans échoués) n'a pas de case plutôt
qu'un zéro. Les parties (`tableau_colis`, `tableau_facturation`…) ne sont
ouvertes à aucun compte : `vue_generale` vérifie les permissions et ne rend
que les parties que le rôle peut voir. Périodes en jours de Santo Domingo
(`bornes_periode`). Copie démo dans `api.js` (`vueGenerale`,
`bornesPeriode`, `jourSD`…) ; `essai-tableau.py` compare la forme des
réponses des deux côtés.

### Analytics

`outils/supabase-analytics.sql` (onglet `admin.html#analytics`) : ce qui
s'est passé, période contre période précédente — le tableau de bord dit ce
qui se passe maintenant. Fonctions de **lecture** (`analytics_synthese`,
`_serie`, `_operations`, `_clients`, `_finances`, `_routes`, `_scanner`,
`_qualite`), toutes sous `reports.view` ; les aides (`bornes_analytics`,
`analytics_mesures`, `creances_au`, `statistiques_durees`…) ne sont ouvertes
à personne. Mêmes définitions que la vue générale pour les mêmes chiffres
(`essai-analytics.py` le vérifie). Une variation contre zéro vaut `null`,
jamais Infinity ; une donnée non suivie (dépenses, dettes, résultat, scans
échoués, origine, cause d'action requise) porte `suivi: false` plutôt qu'un
zéro. Aucune prévision, aucun classement du personnel. Copie démo dans
`api.js` (`analyticsDemo`, `bornesAnalytics`, `comparerValeurs`…),
comparée par `essai-analytics.js --formes` / `--periodes`. La page garde une
réponse une minute (`lireAnalytics`), pas de temps réel.

### L'application de bureau (`bureau/`)

Une coquille Electron autour de `admin.html` **du site** (chargé en ligne,
pas copié) : ni données métier, ni règles, ni permissions à elle. C'est la
seule partie du dépôt avec des dépendances npm (`bureau/node_modules`, ignoré)
et une construction (GitHub Actions, `.github/workflows/bureau.yml`) ; le site
reste sans build. `deploy.yml` exclut `bureau/` de GitHub Pages.

- Le site ne connaît que `window.GoshipBureau` (`bureau/src/pont.js`) :
  `contrat`, `version`, `plateforme`, `stockageSession`, `imprimer`,
  `journal`, `surCommande`, `sessionChiffree`. Toujours tester sa présence
  (`api.js` : `BUREAU` ; `admin.js` : `BUREAU`, `BUREAU_CONTRAT_MIN`) : dans un
  navigateur il n'existe pas, et rien ne doit changer.
- Une fonction de plus dans le pont → `contrat` + 1, nouveaux installateurs,
  **puis** `BUREAU_CONTRAT_MIN` dans `admin.js`.
- Chaque message IPC est revérifié (`securite.expediteurSite`) ; jamais de
  commande générique (shell, fichiers). Pages locales par `goship-app://`,
  pas `file://`.
- Un scan fait depuis l'application porte `poste`, `plateforme`,
  `version_bureau` dans ses métadonnées (`avecPoste`, `api.js`, des deux côtés).
- Adresse du site : `bureau/config/environnements.json`, nulle part ailleurs.
- Essais : `bureau/essais/essai-bureau.js` (Playwright + Electron, jamais en
  root) et `essai-paquet.js` ; le site d'essai (`serveur-essai.js`) sert un
  `config.js` vide. Voir `bureau/LISEZ-MOI.md`.

## Base de données

Tables : `clients`, `colis`, `colis_historique`, `notifications`,
`prealertes`, `factures`, `facture_lignes`, `paiements`, `factures_numeros`,
`evenements_facturation`, `appareils`, `journal_audit`. Vue
`colis_details` (colis + client). RLS activé partout, ~35 policies.

Les migrations sont dans `outils/*.sql`, à exécuter dans Supabase >
SQL Editor, copiés depuis GitHub avec « Copy raw file » (un aperçu tronqué
donne « unterminated dollar-quoted string »). Ordre : `supabase.sql`,
`supabase-facturation.sql`, `supabase-services.sql`,
`supabase-evenements.sql`, `supabase-scanner.sql`, `supabase-finances.sql`,
`supabase-tableau-de-bord.sql`, `supabase-analytics.sql` — relancer l'un impose
de relancer ceux qui le suivent. Elles sont écrites pour être **rejouables sans risque** :
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

Bancs d'essai : `outils/essais-services/` (règles métier et moteur
d'événements, SQL + démo, migration depuis la version publiée),
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
