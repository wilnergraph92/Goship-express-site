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
| `lieux.js` | Régions et villes (Haïti, Rép. dominicaine, États des USA) : adresse du client (`compte.js`), filtre « Destination » du tableau de bord |
| `tableau-langue.js` | Langue du tableau de bord (fr, en, es, ht) : traduction à l'écran |
| `tableau-textes.js` | **Généré** par `outils/traduire.py` : les textes du tableau de bord et leurs traductions |
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
`shipments.*`, `invoices.*`, `payments.*`, `reports.*`, `users.view`,
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
admin ; le montant des frais, jamais.

**Les frais de service ne naissent pas avec le colis** (`outils/supabase-frais-service.sql`,
depuis le 30/09/2026) : la facture créée à l'enregistrement (`facturer_colis_interne`)
et celle de « Nouvelle facture » (`creer_facture` sans `frais_service: true`) en ont
0 $. Ils s'appliquent **au regroupement** (`regrouper(p_factures, p_colis, p_frais, p_cle)`,
case « Appliquer le frais de service », cochée d'office) **ou à l'encaissement**
(`encaisser_facture(p_facture, p_paiement, p_frais, p_cle)` : frais puis paiement dans
la même transaction, fenêtre « Encaisser » qui demande Oui / Non avant de confirmer), ou
depuis la fiche (`changer_frais_service`, ajouter / retirer, `invoices.edit`). Leur
état est `factures.frais_service_usd` (0 = pas appliqués, > 0 = appliqués) : aucune
autre colonne. **Jamais deux fois** : `frais_service_interne` ne fait rien si les frais
y sont déjà (« déjà inclus » à l'écran) ; `regles_facture` refuse toute autre écriture
des frais ou du total. « Ajouter un colis » à une facture = la regrouper avec lui
(`regrouper`, `colis_a_regrouper` pour la recherche) : une facture émise ne reçoit
toujours ni colis ni ligne. L'aperçu « Oui » de la fenêtre vient de
`API.outils.totauxAvecFrais`. Copie démo : `fraisServiceDemo`, `regrouperDemo`,
`colisARegrouper`, `encaisserFacture` ; `essai-frais.py` / `essai-frais.js`.

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
Regrouper : `regrouper_factures` (annule les anciennes, `remplacee_par`). Le chemin
inverse : `sortir_du_regroupement` (`outils/supabase-regroupement.sql`) — les colis
choisis d'une facture de colis à payer, sans paiement, passent sur leur propre facture,
les autres sur une seconde que l'ancienne désigne (`remplacee_par`) ; celle-ci garde
les frais de service s'il y en avait, celle des colis sortis n'en a pas
(`supabase-frais-service.sql`) ; le lien de paiement n'est pas recopié (le tableau de bord
en pose un). Copie démo : `sortirDuRegroupement` dans `api.js`. Côté page, la fenêtre
de regroupement a « Encaisser » (payée, la facture quitte la liste : `ouvrirPaiement`
prend une suite) et « Retirer » (la liste seulement, rien en base) ; la fenêtre « Sortir
des colis » (`ouvrirSortie`) montre l'aperçu par deux `calculer_facture`.
Les trois statuts stockés ne changent pas ; « partielle » et « en_retard »
sont des états déduits. Même copie démo que le reste (`ajouterPaiementDemo`,
`recalculerFactureDemo`…), comparée par `essai-finances.py` /
`essai-finances.js`.

Le prix d'un colis se calcule dans la base (`prix_transport`, appelé par
`regles_colis`) : celui qu'envoie une page est ignoré. Le champ prix du
formulaire admin n'est qu'un aperçu en lecture seule, sauf « Fixer le prix à
la main » : `colis.prix_fixe_usd` (0 à 100 000 $, `invoices.edit`, vérifié et
journalisé par `regles_colis`) remplace alors poids × tarif, `tarif_lb_usd`
devient null (la ligne de facture n'affiche aucun $/lb) ; null = prix calculé.
Pas de frais de service à l'enregistrement (voir plus haut). Copie démo : `reglesColis`, `tarifLigne`.
Une nouvelle facture
passe par `creer_facture` / `facturer_colis`, qui refusent un colis déjà
sur une facture active (`INVOICE_ALREADY_EXISTS`).

Les factures antérieures au 22/09/2026 portent `frais_service_usd = 0`,
volontairement : leur total ne devait pas changer rétroactivement.

### Le tableau de bord

Habillage : `assets/css/tableau.css`, chargé par `admin.html` seulement —
menu latéral (les onglets `data-onglet-vue`), barre du haut (titre de la
vue, date et heure de l'appareil, recherche rapide, cloche des alertes,
réglages, compte). Préfixe `gs-td__` (`gs-app` est déjà pris par la section
de l'application mobile du site). Menu en trois groupes (Opérations,
Finance, Gestion) ; un groupe dont le rôle ne peut rien ouvrir disparaît.
Les réglages sont des préférences d'affichage gardées en `localStorage`
(`gse-tableau-reglages`, dont l'apparence clair / sombre / système et les
animations ; `gse-tableau-disposition` pour les blocs de la vue générale et
leur ordre) : aucune donnée, aucune permission. `assets/js/apparence.js`,
chargé sans `defer`, pose `data-apparence` sur `<html>` avant le premier
affichage ; l'apparence sombre est la fin de `tableau.css` (la contrepartie de
chaque couleur claire, puis des retouches) : une nouvelle règle claire du
tableau de bord demande sa ligne sombre. La vue générale n'a jamais la classe
`gs-apercu` (celle de l'aperçu d'e-mail, à hauteur fixe).

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

Les filtres de la vue générale — pays (Haïti, Santo Domingo, USA : codes
`HT`, `DO`, `US` de la base), destination (les villes que les colis vers ce pays
portent vraiment, `options_filtres`, rangées par département via `lieux.js` ;
jamais une ville sans colis), mode (aérienne, maritime, terrestre : `aerien`,
`maritime`, `terrestre`), statut (inchangé), agence
(USA = au dépôt de Miami, reçu ou emballé ; Haïti, Santo Domingo = arrivé dans
le pays : distribution, succursale, disponible ; la règle est dans
`colis_filtre`, clé `agence`) : `vue_generale_filtree`, section 11 de
`supabase-analytics.sql`, sous `shipments.view` (comparaison et routes sous
`reports.view`). C'est `vue_generale` entière dont les parties qui se
comptent en colis (`colis`, `activite`, plus `comparaison` et `routes`) sont
recalculées sur les colis filtrés, par des copies filtrées de
`tableau_colis`, `tableau_activite` et `analytics_routes` : sans filtre,
chaque partie vaut l'originale (`essai-analytics.py`, section M). L'argent,
les clients, le scanner et les alertes ne se découpent pas par colis et
restent entiers. Une base sans cette fonction répond « absent » : la page
reprend `vue_generale` et désactive les filtres ; une base d'avant la clé
`agence` (pas d'`options.agences`) désactive ce seul filtre. Copie démo :
`vueGeneraleFiltree`, `filtresColisDemo`, `optionsFiltresDemo`, `agenceDuColis`.

**La fiche d'une ligne** (`admin.js`, `<dialog data-dialogue="fiche">`, une seule
pour tous les onglets) : un clic ou Entrée sur une ligne de n'importe quel tableau
l'ouvre ; un bouton, un lien, une case de la ligne gardent leur rôle. Par sections
(`sectionFiche`, `champFiche`) : un champ que la base ne connaît pas n'est pas
affiché. Colis (`ouvrirFicheColis`) : informations générales et code-barres,
destinataire (le client), expéditeur (le magasin), colis, parcours en sept étapes et
historique complet (`API.admin.historique`, lu à l'ouverture) ; « Mettre à jour »,
« Modifier », « Voir la facture », « Étiquette » selon `peut()`. Facture : lignes,
paiements, montants par `totauxFacture`. Client : ses derniers colis, ses factures
et leurs paiements, lus à l'ouverture. Paiement reçu : sa facture. Les autres lignes
montrent leurs colonnes (`data-libelle`) et une copie des boutons de la ligne.
**Les lignes des colis, des clients et des factures n'ont plus de boutons** : leurs
actions ne sont que dans la fiche (`ouvrirFicheColis`, `actionsClient`,
`actionsFacture`, selon `peut()`) ; un bouton d'impression porte `data-imprimer` et
laisse la fiche ouverte. Le poste de scan demande la fiche
par l'événement `goship:fiche-colis`. Rien ne s'y calcule.

**Les fenêtres (`<dialog>`) ne se ferment que sur demande** (`admin.js`, bloc des
dialogues) : un clic à côté ne fait rien. Une saisie de l'utilisateur (événement
`isTrusted` dans un formulaire) pose `data-saisie` ; Échap, × ou « Annuler » ouvrent
alors `data-dialogue="abandon"` (« Fermer sans enregistrer ? »), et une fermeture
imprévue du navigateur rouvre la fenêtre. `d.close()` appelé par le code (après un
enregistrement) ferme sans question. Une nouvelle fenêtre n'a rien à faire de plus.

**La langue du tableau de bord** (`tableau-langue.js`, sélecteur
`[data-langue-tableau]` dans la barre, préférence `gse-tableau-langue`) : le
tableau de bord s'écrit en français ; ce fichier remplace à l'écran les textes
qu'il connaît, y compris ceux qu'`admin.js` écrit plus tard (MutationObserver),
plus quelques phrases à trous et les dates. Les traductions sont **celles du site**
(`outils/traductions/<langue>.json`) : `outils/traductions/tableau.txt` liste les
textes du tableau de bord, et `traduire.py` en écrit `assets/js/tableau-textes.js`.
Noms, notes et adresses restent tels quels. **Un texte ajouté au tableau de bord :
sa ligne dans `tableau.txt`, ses trois traductions, puis `traduire.py`.** Aucune logique
ne doit lire un texte affiché pour décider (il peut être traduit) : un attribut
`data-*` le fait. Factures et étiquettes imprimées gardent la langue du client.

**Les rapports** (onglet « Rapport », `admin.html#rapports`, `outils/supabase-rapports.sql`,
dernier de la chaîne) : une période (aujourd'hui, jour, semaine du lundi au dimanche,
mois, trimestre, année, personnalisée ; jours de Santo Domingo, `rapport_bornes`), deux
filtres (statut du colis par groupe, état de la facture) et les données à inclure →
`rapport_donnees`, qui compte tout (définitions d'`analytics_mesures`) et rend les lignes
page par page (50 à l'écran, 2 000 au plus pour le papier). Un rapport enregistré
(table `rapports`, aucune lecture ni écriture directe) n'est que sa **définition** ; ses
chiffres se relisent à chaque ouverture, avec SES dates. Factures « supprimées » et colis
supprimés : lus dans `journal_audit` (une facture ne se supprime qu'avec le compte de son
client), jamais comptés dans le facturé. L'activité est `journal_audit`, filtrée ligne à
ligne par la permission de ce dont elle parle. Permissions : `reports.view` (voir,
imprimer, PDF), `reports.create` (administrateur, gérant), `reports.edit` et
`reports.delete` (administrateur) ; supprimer un rapport n'efface que lui (journal
`rapport.suppression`). Impression et PDF : `impression.js` (options `pied` et
`numeroter` : pied de page et « Page 2 / 5 » par `@page`), le PDF est celui de la
fenêtre d'impression ou de l'application de bureau — aucune bibliothèque. Copie démo :
`donneesRapportDemo`, `bornesRapport`… ; `essai-rapports.py` / `essai-rapports.js`.

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

### Les notifications (`outils/supabase-notifications.sql`, `docs/notifications.md`)

Événement → règle → notification → envois → statut, tout dans la base. Les
déclencheurs sur `colis_historique` (étapes publiques) et `evenements_facturation`
créent, dans la même transaction, la notification (table `notifications`, canal
`app`, clé unique `cle`) et un envoi par canal (`notification_envois`) ; le
travailleur `traiter_notifications()` (pg_cron, chaque minute) les envoie par
pg_net et lit les réponses (3 essais au plus, erreurs définitives jamais
réessayées). **Aucune page n'envoie de message** : ni e-mail, ni WhatsApp, ni
push depuis admin.js, compte.js ou l'application — elles lisent
`mes_notifications`, `centre_notifications`, `envois_colis`, `regles_notifications`.
Un nouveau type de notification = une ligne dans `notification_regles` + ses
textes dans `notification_textes()` (quatre langues) + la même chose dans la
copie démo (`REGLES_NOTIFICATIONS`, `TEXTES_NOTIFICATIONS` dans `api.js`) :
`essai-notifications.py` compare les deux. Ne jamais marquer un envoi
« envoye » ou « livre » sans réponse du fournisseur.

### Supprimer mon compte (`outils/supabase-compte.sql`)

`supprimer_mon_compte('SUPPRIMER')`, appelée par l'application mobile pour le compte
connecté et lui seul. **On n'efface jamais la ligne du compte** : `clients.id` suit
`auth.users` en cascade, et factures, paiements, pré-alertes suivent `clients` de la même
façon. La fonction vide le profil (nom, e-mail, téléphone, adresse → « Compte
supprimé », `clients.supprime_le`), garde le code client, efface les téléphones et les
pré-alertes en attente, bloque le compte de connexion (e-mail remplacé, mot de passe
retiré, `banned_until`, sessions fermées : l'adresse redevient libre) et journalise
`client.suppression_demandee`. Refusée à un compte de l'équipe (`clients.view`), tant
qu'un colis n'est pas livré ou qu'une facture a un solde. `essai-mobile.py` (section K)
l'éprouve ; la doublure d'`auth` (`essai-services.py`, `DOUBLURES`) a les colonnes et
tables de GoTrue qu'elle touche.

### Continuer avec Google (`outils/supabase-connexion.sql`)

La connexion passe par Supabase Auth (`signInWithOAuth`), rien d'autre : aucune clé Google
dans le dépôt, le fournisseur s'active dans Supabase > Authentication > Providers. Le site
ne montre le bouton (`[data-social]`, connexion et inscription) que si les réglages
publics de Supabase (`/auth/v1/settings`, `external.google`) le disent actif :
`API.fournisseursConnexion()` ; `API.connecterAvec()` part chez le fournisseur et revient
toujours sur `connexion.html` (session dans l'adresse, ou `error=` dit par la page). Un
fournisseur de plus : `FOURNISSEURS` dans `api.js` et son bouton. Le profil d'un compte
Google naît par le même déclencheur (`creer_profil_client`), qui lit le nom et la langue
envoyés par Google (`nom_depuis_metadonnees`, `langue_depuis_metadonnees`, fermées à tous) ;
pays, ville et téléphone manquent : « Mon compte » affiche « Complétez votre profil »
(`[data-completer]`) et ouvre de lui-même le formulaire du profil ; l'application ouvre
l'écran « Mes informations ». E-mails de bienvenue et « Supprimer mon compte » (qui efface
`auth.identities`) n'ont pas changé. `essai-mobile.py` (section L) l'éprouve.

**Pas de pré-alerte sans profil complet** (`outils/supabase-profil-complet.sql`) : le
déclencheur `exiger_profil_prealerte` (avant insertion dans `prealertes`, donc aussi pour
l'écriture directe des anciennes versions de l'application) refuse avec
`PROFILE_INCOMPLETE` tant que `profil_complet(client)` est faux : nom, téléphone, pays et
ville non vides — les mêmes champs que le bandeau du site et la carte de l'application.
Les pré-alertes déjà enregistrées ne sont pas touchées. `essai-mobile.py` (section M).

### L'application mobile (dépôt `goship-express-app`)

L'espace client sur téléphone (Expo), cloné dans `application-mobile/` (ignoré ici).
Même règle que le bureau : aucune logique métier, elle lit `mon_resume`,
`mes_factures`, `suivre_colis`, `mes_permissions`, les tables `colis`,
`colis_historique`, `prealertes`, et écrit par `creer_prealerte`,
`enregistrer_appareil` et `supprimer_mon_compte`. `outils/supabase-mobile.sql` ne fait qu'ajouter
`creer_prealerte` (clé d'envoi, doublon, validation) et un index ; l'insert direct
dans `prealertes` reste ouvert pour les versions déjà installées — **ne le ferme pas**
sans une période de transition. Une fonction dont l'application dépend ne se renomme
pas et ne change pas de forme de réponse : les versions déjà installées ne se mettent
pas à jour toutes seules. `essai-mobile.py` rejoue ses requêtes ; `--serveur` sert de
base à ses essais (navigateur, émulateur, simulateur).

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
`supabase-tableau-de-bord.sql`, `supabase-analytics.sql`, `supabase-mobile.sql`,
`supabase-notifications.sql`, `supabase-production.sql`, `supabase-rapports.sql`, `supabase-compte.sql`, `supabase-regroupement.sql`, `supabase-connexion.sql`, `supabase-profil-complet.sql`, `supabase-frais-service.sql` (liste de référence :
`outils/migrations.txt`) — relancer l'un impose
de relancer ceux qui le suivent. Elles sont écrites pour être **rejouables sans risque** :
`add column if not exists`, valeurs par défaut neutres, aucune
suppression. Garde cette propriété pour toute nouvelle migration.

Code client : `GSE-` suivi d'au moins 4 chiffres. `API.normaliserCode()`
ne retient que les chiffres — attention, une adresse e-mail contenant
des chiffres ne doit jamais passer par là.

## Traductions

Les pages traduites sont des **copies complètes** dans `en/`, `es/`,
`ht/`. `outils/traduire.py` et `outils/traductions/` servent à les
régénérer. `admin.html` n'a pas de copie traduite : il s'écrit en
français et `tableau-langue.js` l'affiche en anglais, espagnol ou créole.

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

### La production (`docs/production/`, `outils/production/`)

Tout ce qui sert à mettre en ligne, surveiller, sauvegarder, restaurer et
revenir en arrière. **L'état GO / NO-GO est dans `docs/production/go-no-go.md`** :
le lire avant de toucher à la base de production. `deploy.yml` refuse de
publier un fichier de travail (`.md`, `.sql`, `.py`, clés, sauvegardes) ou une
clé secrète, puis vérifie le site publié (`surveiller.sh`). Les contrôles
`controle-securite.sql` et `controle-integrite.sql` sont en lecture seule ;
`sante()` (`supabase-production.sql`) est la seule fonction ajoutée pour la
surveillance. Une migration qui ajoute une fonction ouverte aux visiteurs doit
l'ajouter à la liste blanche de `controle-securite.sql` (section 6), sinon le
contrôle la signale. `essai-production.py` éprouve tout cela, sauvegarde et
restauration comprises. Changements notables : `CHANGELOG.md` (non publié).

Messages de commit : une phrase en français qui dit ce que ça change
pour l'utilisateur, pas un préfixe technique. Voir `git log`.

## Pièges

- `.mcp.json` ou tout fichier de config déposé à la racine part en ligne.
- `config.js` contient la clé Supabase : ne la recopie pas dans un
  fichier d'essai qui serait ensuite commité.
- Les montants s'écrivent avec une virgule en français (`40,00 $`) ;
  `API.outils.argent()` s'en charge.
