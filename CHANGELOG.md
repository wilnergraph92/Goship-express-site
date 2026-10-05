# Journal des changements

Une entrée par mise en production (docs/production/releases.md). Ce fichier
n'est pas publié sur le site (`deploy.yml` l'exclut).

Les versions `site-AAAA.MM.JJ` désignent à la fois les pages et l'état de
`outils/` : la chaîne de migrations (`outils/migrations.txt`) à appliquer à la
base **avant** de publier le site.

## site-2026.10.05.2 — la politique de confidentialité décrit l'application

Aucune migration, aucune donnée. Préparation de la fiche Google Play, qui exige une politique
couvrant ce que l'application traite.

- `confidentialite.html` (et `en/`, `es/`, `ht/`) gagne la section « Application mobile
  GoShip Express » (ancre `#application`) : données du compte et des colis, identifiant de
  notification (effacé à la déconnexion), appareil photo (scan seulement, aucune image
  gardée), ce qui reste sur le téléphone, prestataires (Supabase, Expo et Firebase Cloud
  Messaging, Apple, PayPal), suppression du compte dans l'application ou par
  `fermer-un-compte.html`. Posée par `build.py` (`confidentialite_application()`), sans
  toucher la maquette. **Texte à relire par GoShip Express.**

## site-2026.10.05 — le tableau de bord a sa politique de sécurité

Aucune migration, aucune donnée.

- `admin.html` porte la même `Content-Security-Policy` que les 101 autres pages (posée par
  `build_admin()` avec `csp()`) : un script, une image ou une connexion venus d'un autre
  domaine sont refusés par le navigateur. Parcouru en mode démo : 8 onglets, fiches, 5
  impressions (étiquette, facture, rapport, PDF), aperçu d'e-mail, **0 violation** ; un
  script injecté est bien refusé. Constat C1 de `docs/audit-2026-10-05.md`.
- Application (dépôt `goship-express-app`) : la première case de l'accueil dit « en cours »
  au lieu de « en route » (constat C3), publiée par mise à jour sans construction.

## Non publié — l'application : l'accueil sans colis livré, et « Historicité »

Aucune page du site, aucune migration, aucune donnée. Le changement est dans l'application
mobile (dépôt `goship-express-app`) ; ici, seul le banc `essai-mobile.py` gagne une section N
qui rejoue les nouvelles requêtes de l'application contre le vrai PostgREST.

- 05/10/2026 : l'accueil de l'application ne montre plus aucun colis livré (un colis livré
  n'en est plus le « dernier mouvement ») ; **Compte > Historicité** liste tous les colis
  livrés du client avec leur date de livraison. Audit complet du même jour :
  `docs/audit-2026-10-05.md`.

## Non publié — sauvegarde autonome de la base (Supabase Free)

Aucune page ne change, aucune donnée ni migration. Guide : `outils/README-backup.md`.

- 01/10/2026 : première vraie sauvegarde réussie (B2, épreuve : 1 083 lignes, 17 comptes,
  6 s). Les contrôles ne crient plus pour deux faux positifs relevés en production :
  `rls_auto_enable()` (event trigger posé par Supabase, inappelable) passe en INFO, et
  les 3 événements de facturation des 26-27/09, antérieurs aux notifications
  (`actives_depuis`), sont comptés à part ; un événement coincé après reste une ALERTE.

- 30/09/2026 : la branche rejoint de nouveau la version du site (frais de service,
  regroupement, Google) ; l'environnement `production` est désormais ouvert à `main`.
- 28/09/2026 : la branche rejoint la version actuelle du site (12 migrations,
  onglet Rapport), sans les pages des notifications de la PR #13. Destination
  recommandée : `goship-a:goship-sauvegardes/base-supabase`, à côté du dossier
  `goship-express/` de la sauvegarde du code, avec sa propre clé B2.
- Sauvegarde du code sur le Mac (`outils/sauvegarde-locale/`) : le script du
  propriétaire, corrigé et versionné — première ligne (`#!/bin/bash`), PATH Homebrew,
  échec écrit au journal et notifié, archive provisoire puis vérifiée, `.sha256`,
  relecture sur B2, verrou, `node_modules` exclu, `--verifier` (relecture et
  déchiffrement depuis B2). Même dossier, mêmes noms, même clé, même rétention.
  Essai : `essai-sauvegarde-locale.sh`, sous Linux et sous le bash 3.2 de macOS.

- `sauvegarde.yml` : rouge quand un secret manque (il affichait vert sans rien
  sauvegarder), stockage externe par rclone (destinations A et B), rétention 7 avec
  garde-fous, épreuve de restauration retéléchargée du stockage, rapport PASS/FAIL,
  RTO par étape, alerte `ALERTE_WEBHOOK`. Corrige une épreuve qui aurait échoué au
  premier passage (publication `supabase_realtime` créée deux fois).
- Nouveaux : `verifier-sauvegarde.sh`, `stocker.sh`, `verifier-restauration.sh`,
  `epreuve-restauration.sh`, `alerter.sh`, `restauration-test.yml`.
- `sauvegarder.sh` : connexion vérifiée (message sans mot de passe), contrôles de
  structure et de taille, SHA-256 des fichiers chiffrés, nom à la seconde, comptes
  dans le manifeste. `restaurer.sh` : `RESTORE_TARGET` obligatoire, confirmation pour
  la production, SHA-256 vérifié avant de déchiffrer.
- Domaine de production (`www.goshipexpress.net`) : configuration Auth décrite à part
  (`docs/production/environment.md`).
- Revue du 27/09/2026 (rapport, section 0) :
  - l'épreuve de restauration réussit sur un PostgreSQL neuf : elle crée elle-même
    `anon`, `authenticated`, `service_role` et `authenticator` ; elle aurait échoué
    chaque jour dans le conteneur du workflow ;
  - un envoi raté vers le stockage fait maintenant échouer le workflow : chaque étape
    tourne sous `pipefail`, alors que `| tee` masquait l'échec et qu'une destination B
    en panne laissait le workflow vert. Une B non configurée s'affiche `SKIPPED` ;
  - `SUPABASE_DB_URL` est vérifiée avant toute connexion (`verifier-adresse.sh`) :
    Session pooler 5432 seulement, adresse jamais affichée ;
  - le journal annonce le vrai nombre de fonctions ;
  - le manifeste garde la valeur des séquences et le détail des comptes (identités,
    mots de passe, confirmés), comparés après restauration.

## site-2026.10.01 — accueil et tableau de bord au téléphone

Aucune migration. Pages et styles seulement.

- Accueil au téléphone : « Créer mon compte » (vers l'inscription) remplace « Obtenir un
  devis gratuit », qui reste sur ordinateur ; un visiteur connecté ne le voit pas. Le
  bandeau « USA · Santo Domingo · Haïti » tient sur une ligne (lettres moins espacées),
  dans les quatre langues, dès 320 px. Traductions : « Create my account », « Crear mi
  cuenta », « Kreye kont mwen ».
- Tableau de bord au téléphone (moins de 640 px) : l'en-tête passe sur deux lignes —
  menu, titre avec la date et l'heure, compte ; puis recherche, « + », langue, alertes.
  Les boutons ne recouvrent plus le titre ni l'heure.

## site-2026.09.30.5 — frais de service au regroupement et à l'encaissement

**Migration : `outils/supabase-frais-service.sql`** (la 17e de la chaîne), à exécuter
AVANT de publier le site. Contrôle attendu : `4 | false | 0`. Aucune donnée existante
ne change : une facture déjà émise garde ses frais, qu'elle en ait ou non.

- Enregistrer un colis ne met plus de frais de service sur sa facture (0 $) ; « Nouvelle
  facture » non plus.
- Regrouper : case « Appliquer le frais de service à la nouvelle facture » (cochée),
  ligne à part, une fois ; bouton « + Ajouter un colis » (recherche par numéro, contenu,
  magasin, suivi du vendeur, destination, facture ; seuls les colis que la base accepte ;
  jamais deux fois le même). Une facture émise ne reçoit toujours pas de colis :
  l'ajouter, c'est la regrouper avec lui (annulée, remplacée, renvoi).
- Encaisser : « Ajouter le frais de service ? Oui / Non » avant de confirmer, montants
  recalculés à l'écran ; frais déjà appliqués : « déjà inclus », jamais une seconde fois
  (la base y veille : `encaisser_facture`, frais et paiement dans la même transaction).
- Fiche d'une facture à payer : « Ajouter / Retirer le frais de service ».
- Sortir des colis d'un regroupement : les frais restent sur la facture qui garde le
  regroupement, celle des colis sortis n'en a pas.
- Rapport d'anomalies : une facture sans frais n'est plus signalée (sauf du 22 au 29/09).
- Essais : `essai-frais.py` (72), `essai-frais.js` (46), navigateur (30) ; bancs mis à
  jour pour la nouvelle règle (`essai-demo.js`, `essai-finances.js`,
  `essai-permissions.js`, `essai-rapports.py`, `essai-metier.sql`).

## site-2026.09.30.4 — réseaux sociaux : vraies pages et vrais logos

Aucune migration. Le pied de page de toutes les pages (fr, en, es, ht) montre les logos
Facebook, Instagram, TikTok et WhatsApp à la place des lettres de la maquette (« f »,
« IG », « Tok », « wa »). Instagram et TikTok menaient à `#top` : ils mènent maintenant
aux pages de l'entreprise (facebook.com/goshipexpress, instagram.com/goshipexpressllc,
tiktok.com/@goshipexpress.net), ouvertes dans un nouvel onglet. Les liens sont nettoyés
de leurs paramètres de partage. Les données structurées (`sameAs`) citent les trois
pages. Tout vient de `outils/generateur/build.py` (`FACEBOOK`, `INSTAGRAM`, `TIKTOK`,
`LOGOS`) : les logos sont des SVG dans la page (Simple Icons, domaine public), à la
couleur du bouton.

## site-2026.09.30.3 — image de l'accueil de l'application à jour

Aucune migration. Sur la page d'accueil du site (section « Vos colis dans votre poche »),
le téléphone du milieu (`assets/img/app-ecran-accueil.webp`, dessiné par
`outils/ecrans-app/ecrans.py`) montre l'accueil de l'application tel qu'il est depuis
goship-express-app#13 : plus de bande bleue « Annoncer un achat », et une ligne
« Suivi vendeur » (numéro du magasin) sur chaque carte de colis. Les deux autres
téléphones ne changent pas.

## site-2026.09.30.2 — tableau de bord sombre : cases à cocher et « En direct » lisibles

Aucune migration. En apparence sombre, les cases à cocher (`.gs-case` : « Fixer le prix à
la main » et « Prévenir le client » dans les fenêtres Colis et Statut, filtre « Action
requise » de la Vue générale, « Son » du poste de scan) gardaient leur fond clair (#f4f8ff)
sous le texte clair (contraste 1,1:1), et la pastille « En direct » son fond vert très
clair (1,6:1). Leurs règles sombres ne changeaient que la couleur du texte : elles
changent maintenant aussi le fond. Vérifié en mode démo sombre, texte par texte : les dix
vues, toutes les fenêtres (vides et remplies : fiches colis, client, facture) et les menus
de la barre du haut n'ont plus aucun texte sous 3:1 (14 styles fautifs avant).

Dans la même fenêtre, en anglais, espagnol ou créole, trois textes restaient en français :
le placeholder du message au client (le traducteur sautait tout `<textarea>`, placeholder
compris ; il ne saute plus que ce qu'on y tape), l'aide « Indiquez le poids : le prix se
calcule tout seul, à … la livre. » (phrase à trous ajoutée) et l'erreur « Indiquez le poids
du colis, en livres (ex. 4,5). » (ajoutée à `tableau.txt`, trois traductions).

## site-2026.09.30.1 — tableau de bord sombre : les clients avec des colis en cours sont lisibles

Aucune migration. En apparence sombre, les lignes de l'onglet Clients qui ont des colis en
cours (`is-actif-client`) gardaient leur fond clair (#fcfdff) sous le texte clair du mode
sombre : nom, code, téléphone illisibles (contraste 1,15:1). Elles ont maintenant leur
contrepartie sombre dans `tableau.css`, comme le flash d'une ligne nouvelle (`is-nouveau`).
Vérifié dans un navigateur, en mode démo sombre : aucune cellule de tableau sous 3:1 dans
Vue générale, Colis, Clients, Factures et Équipe (42 avant la correction, toutes dans Clients).
L'application de bureau charge le site : elle est corrigée en même temps.

## site-2026.09.29.3 — un compte supprimé depuis l'application peut être effacé dans Supabase

Migration passée le 29/09/2026 par le propriétaire : `outils/supabase-compte.sql` relancé,
puis les fichiers qui le suivent dans la chaîne. Contrôles : `1 | false | 1 | 0`,
`1 | false`, `2 | false | true`, `2 | false | 1`.

- « Supprimer mon compte » bloquait le compte de connexion avec une date infinie
  (`banned_until = 'infinity'`), que Supabase ne sait pas lire : le compte
  `supprime-…@goship.invalid` ne s'ouvrait plus dans Authentication > Users, et sa
  suppression échouait (« Failed to delete user: Database error loading user »). Le blocage
  dure désormais cent ans, une date lisible. Le client supprimé ne peut toujours pas se
  reconnecter.
- La migration répare les comptes déjà supprimés par l'ancienne version (même blocage, date
  lisible) ; relancée, elle ne trouve plus rien à faire.
- `essai-mobile.py` : 125 vérifications (la réparation d'un compte à date infinie comprise).

## 29/09/2026 — « Continuer avec Google » vérifié de bout en bout

Aucun changement de code. Le propriétaire a fait l'aller-retour réel avec Google sur le site
(compte créé, nom repris de Google, formulaire du profil ouvert) et dans l'application
Android construite depuis `main` (3294441, profil `preview`). Dans l'application, le retour
tombait d'abord sur le site : l'adresse `goshipexpress://…` n'était pas encore acceptée dans
Supabase > URL Configuration. Le guide (README, « Continuer avec Google ») donne désormais
les trois adresses de l'application.

## site-2026.09.29.2 — un profil complet avant la première pré-alerte (publié le 29/09/2026)

Migration passée le 29/09/2026 par le propriétaire (contrôle `2 | false | 1`) : **un seul fichier**, `outils/supabase-profil-complet.sql` (le dernier de
la chaîne, 16ᵉ). Il ajoute une fonction et un déclencheur fermés à tous ; il ne change aucune
donnée. Contrôle attendu : `2 | false | 1`.

- La base refuse une nouvelle pré-alerte (`PROFILE_INCOMPLETE`) tant que le profil du client
  n'a pas son nom, son téléphone, son pays et sa ville — par `creer_prealerte` comme par
  l'écriture directe des anciennes versions de l'application. Les pré-alertes déjà
  enregistrées ne sont pas touchées.
- *Mon compte* ouvre de lui-même le formulaire du profil quand il est incomplet (compte
  ouvert avec Google, le plus souvent), sous le bandeau « Complétez votre profil ».
- Bancs : `essai-mobile.py` section M (10 cas) ; la sonde et `controle-securite.sql`
  connaissent la 16ᵉ migration ; les clients d'essai ont un téléphone.

## site-2026.09.29.1 — « Continuer avec Google » (publié le 29/09/2026)

Migration passée le 29/09/2026 par le propriétaire (contrôle `2 | false | true`) : **un seul fichier**, `outils/supabase-connexion.sql` (le dernier de la
chaîne, 15ᵉ). Il ajoute deux fonctions fermées à tous et remplace le déclencheur qui crée
le profil d'un nouveau compte ; il ne change aucune donnée. Contrôle attendu :
`2 | false | true`. Puis les réglages de Google et de Supabase (README, « Continuer avec
Google ») : tant qu'ils ne sont pas faits, le bouton reste caché et rien ne change.

- *Se connecter* et *Créer un compte* : « Continuer avec Google », au-dessus du
  formulaire, seulement si Supabase a activé Google (réglages publics
  `/auth/v1/settings`). Retour toujours sur *Se connecter* : session ouverte, ou phrase
  d'erreur (« annulée », « n'a pas abouti »), en quatre langues.
- Le profil d'un compte Google reprend le nom (`full_name`, `name`, prénom + nom) et la
  langue du compte Google ; le formulaire passe avant. Code client et e-mails de bienvenue
  comme avant ; « Supprimer mon compte » retirait déjà le lien Google (`auth.identities`).
- *Mon compte* : « Complétez votre profil » tant que pays, ville ou téléphone manquent.
- `api.js` : `fournisseursConnexion` et `connecterAvec`, dans les trois modes (démo et
  site fermé : aucun bouton).
- Bancs : `essai-mobile.py` section L (10 cas) ; la sonde et `controle-securite.sql`
  connaissent la 15ᵉ migration.

## site-2026.09.28.8 — le favicon se met à jour dans les navigateurs (publié le 28/09/2026)

Aucune migration. Les adresses des icônes du site portent maintenant un numéro
(`?v=2026-09-28`, `ICONES_VERSION` dans `outils/generateur/build.py`) : un navigateur
qui gardait l'ancien favicon sous la même adresse recharge le nouveau. Les pages
traduites (`en/`, `es/`, `ht/`) demandaient `favicon.ico` dans leur propre dossier, où
il n'existe pas : `traduire.py` le fait maintenant pointer vers celui de la racine.

## site-2026.09.28.7 — regroupement des factures : encaisser, retirer, sortir des colis (publié le 28/09/2026)

Migration : **un seul fichier**, `outils/supabase-regroupement.sql` (le dernier de la
chaîne, 14ᵉ), passée par le propriétaire avant la publication (contrôle : `1 | false`).
Il ajoute une fonction ; il ne change aucune donnée. Sans lui, « Sortir du
regroupement » répondrait « La base n'est pas à jour » ; le reste du tableau de bord
marcherait comme avant.

- Fenêtre « Regrouper des factures » : chaque facture a « Encaisser » (la fenêtre du
  paiement s'ouvre ; payée, même en partie, elle quitte la liste) et « Retirer » (elle
  quitte la liste sans que la facture change ; « Tout remettre » la ramène).
- Une facture de colis à payer, sans paiement, d'au moins deux colis : « Sortir des
  colis de cette facture » (fenêtre de la facture, et fiche : « Sortir des colis »).
  Les colis cochés passent sur leur propre facture, les autres sur une seconde ; la
  facture regroupée est annulée et renvoie vers la seconde (`remplacee_par`). Chaque
  facture compte ses frais de service (sortir des colis en ajoute une fois) ; l'aperçu
  le montre avant de valider. « Sortir et encaisser » ouvre ensuite le paiement de la
  facture des colis sortis. Refusé : tous les colis, un colis étranger, une facture
  payée, annulée ou qui a reçu un paiement, une facture sans colis.
- `sortir_du_regroupement` (base) et sa copie démo (`api.js`), clé d'idempotence,
  journalisé (`facture.sortie_regroupement`). Le lien de paiement n'est pas recopié
  (il portait le montant regroupé) : le tableau de bord en pose un sur chaque facture.
- Bancs : `essai-finances.py` section R (21 cas), `essai-finances.js` section Q
  (16 cas) ; `sonder.sh` et `controle-securite.sql` connaissent la 14ᵉ migration.

## site-2026.09.28.6 — « Supprimer mon compte » dans l'application mobile (publié le 28/09/2026)

Migration exécutée par le propriétaire le 28/09/2026 (contrôle `1 | false | 1`, sonde
anonyme : 13 migrations sur 13) : **un seul
fichier**, `outils/supabase-compte.sql` (le dernier de la chaîne). Il ajoute une
colonne vide (`clients.supprime_le`) et une fonction ; il ne change aucune donnée.
Sans lui, l'application répond « La suppression du compte n'est pas encore
disponible » et renvoie vers WhatsApp.

- `supprimer_mon_compte` : le client connecté supprime son compte lui-même. Profil
  vidé (nom, e-mail, téléphone, adresse), connexion bloquée pour toujours, sessions
  fermées, téléphones et pré-alertes en attente effacés, adresse e-mail libérée.
  Colis, factures et paiements restent, sans ses coordonnées (la ligne du compte n'est
  jamais effacée : factures et paiements la suivent en cascade). Refusé à un compte
  de l'équipe, tant qu'un colis n'est pas livré ou qu'une facture reste à payer.
  Journalisé (`client.suppression_demandee`).
- Bancs : `essai-mobile.py` section K (18 cas) ; la doublure d'`auth` a les colonnes
  et tables de GoTrue que la fonction touche ; `sonder.sh` et `controle-securite.sql`
  connaissent la 13ᵉ migration.

## site-2026.09.28.5 — nouvelles icônes (application de bureau, site) (publié le 28/09/2026)

Aucune migration, aucune donnée modifiée. Toutes tirées du même dessin (le colis et
sa flèche, fourni par le propriétaire).

- Application de bureau (`bureau/build/icone.png`) : tuile blanche arrondie à la
  manière de macOS, avec son ombre ; Windows en tire son `.ico` à la construction.
- Site : icône d'écran d'accueil de l'iPhone (`apple-touch-icon.png`, 180 px) et
  favicons (`favicon-32.png`, `favicon-64.png`, `favicon.ico` 16/32/48).

## site-2026.09.28.4 — formulaire du colis : prix fixé à la main ; fenêtres protégées (publié le 28/09/2026)

Publié à la demande du propriétaire **avant** la migration. Tant qu'elle n'est pas
passée, la base ignore le prix saisi à la main et facture poids × tarif ; les fenêtres
protégées marchent déjà. Migration : `supabase-services.sql`, puis toute la chaîne
qui le suit dans l'ordre jusqu'à `supabase-rapports.sql` (outils/migrations.txt). Elle
ajoute une colonne (`colis.prix_fixe_usd`, vide par défaut : tous les colis existants
gardent leur prix calculé) et ne change aucune donnée. Sans elle, l'ancienne base
ignorerait le prix saisi et facturerait poids × tarif.

- « Enregistrement du colis » : case « Fixer le prix à la main » (qui peut modifier les
  factures : administrateur, gérant). Le prix saisi (0 à 100 000 $) remplace poids ×
  tarif ; les frais de service restent ajoutés sur la facture. La base le vérifie
  (`regles_colis`) et le journalise ; décocher la case revient au prix calculé. La
  ligne de facture n'affiche alors aucun tarif au livre ; la fiche dit « Prix fixé à la main ».
- Toutes les fenêtres du tableau de bord : un clic à côté ne les ferme plus. Échap, ×
  ou « Annuler » sur une fenêtre où l'on a commencé à saisir demandent « Fermer sans
  enregistrer ? » ; sans saisie, elles se ferment comme avant.

## site-2026.09.28.3 — tableau de bord : onglet « Rapport » (publié le 28/09/2026)

Migration passée par le propriétaire avant la publication : `supabase.sql` (les
permissions `reports.create`, `reports.edit`, `reports.delete`), puis toute la chaîne
dans l'ordre jusqu'au nouveau `supabase-rapports.sql` (outils/migrations.txt) ;
`audit-production.yml` : 12 migrations présentes sur 12.
`supabase-rapports.sql` ajoute une table (`rapports`), trois index et des fonctions ; il
ne change aucune donnée. Sans lui, l'onglet répond « La base n'est pas à jour ».

- Onglet « Rapport » (administrateur, gérant) : période, statut du colis, état de la
  facture, type ; cartes (colis, factures, payé, impayé, annulé, supprimées, encaissé,
  clients, activité) ; colis, étapes, factures (et supprimées), paiements, clients,
  activité du journal d'audit, page par page.
- Rapports enregistrés : créer (administrateur, gérant), modifier et supprimer
  (administrateur), détails, voir, imprimer, PDF ; journalisés.
- Impression A4 portrait ou paysage : logo, en-tête, pied de page numéroté.

## site-2026.09.28.2 — tableau de bord : actions dans la fiche seulement (publié le 28/09/2026)

Aucune migration, aucune donnée modifiée.

- Colis, clients, factures : les boutons quittent les lignes (Mettre à jour, Voir la
  facture, Étiquette ; Ses colis, Ses factures, + Colis ; Encaisser, Imprimer,
  Détails, WhatsApp, Annuler). Ils ne sont plus que dans la fiche qu'un clic sur la
  ligne ouvre, avec les mêmes permissions.

## site-2026.09.28 — tableau de bord : fiches complètes, destinations réelles (publié le 28/09/2026)

Aucune migration nouvelle (celle de `site-2026.09.27.3` reste à relancer pour le
filtre « Agence »). Aucune donnée modifiée.

- Destination : seulement les villes que les colis vers le pays choisi portent
  vraiment, rangées par département ou province ; plus aucune ville sans colis.
- Filtre Statut : affichage rendu identique à avant le 27/09 (« (0) » compris).
- Fiche d'un colis par sections : informations générales et code-barres,
  destinataire, expéditeur, colis, parcours, historique complet ; « Modifier » en
  plus, chaque action selon les permissions du rôle.
- Fiches d'une facture (colis facturés, paiements, montants), d'un client (derniers
  colis, factures, paiements, lus à l'ouverture) et d'un paiement reçu.
- Poste de scan : « Fiche complète » ouvre la fiche du colis scanné.
- Langue : les traductions du tableau de bord rejoignent les dictionnaires du site
  (`outils/traductions/`) ; les mots déjà traduits sur le site sont repris tels quels.

## site-2026.09.27.3 — tableau de bord : filtres fixes, fiche d'une ligne, langue (publié le 27/09/2026)

Migration en lecture seule **à relancer par le propriétaire**, sans urgence :
`supabase-analytics.sql` puis `supabase-mobile.sql` (SQL Editor, « Copy raw file »).
Elle ajoute la clé de filtre `agence` et, dans les choix des filtres, le pays de
chaque ville et le nombre de colis par agence ; aucune table, aucune donnée, aucune
règle ne change. Tant qu'elle n'est pas passée, le filtre « Agence » reste désactivé
(la page le dit) et les villes des colis s'ajoutent sous chaque pays.

- Filtres de la vue générale : Pays (Haïti, Santo Domingo, USA), Destination (toutes
  les villes du pays choisi : communes d'Haïti, municipalités dominicaines, plus
  celles des colis), Mode (aérienne, maritime, terrestre), Statut (inchangé), Agence
  (USA : au dépôt de Miami ; Haïti, Santo Domingo : arrivé dans le pays).
- Un clic sur une ligne ouvre sa fiche, dans tous les onglets. Un colis : client,
  route, mode, poids, montant, lieu, dates, parcours en sept étapes datées, et
  « Mettre à jour », « Voir la facture », « Étiquette », « Voir le client ». Clients,
  factures, paiements, équipe, analytics, scanner : leurs colonnes et leurs boutons.
  La recherche rapide et les « Ouvrir » de la vue générale ouvrent aussi la fiche.
- Sélecteur de langue dans la barre (FR, EN, ES, HT), gardé sur l'appareil.
- Les régions et villes de l'espace client passent dans `assets/js/lieux.js`,
  partagé avec le tableau de bord (aucun changement visible).

## site-2026.09.27.2 — tableau de bord : filtres, apparence, direct, disposition (publié le 27/09/2026)

Migration en lecture seule, appliquée en production le 27/09/2026 avant la
publication : `supabase-analytics.sql` relancé (contrôle de fin : 15 | 8 | 0 | true),
puis `supabase-mobile.sql` (contrôle : 1 | false | 2 | 1). Elle ajoute
`vue_generale_filtree` et ses aides ; aucune table, aucune donnée, aucune règle ne
change. Une base sans elle garde un tableau de bord entier, filtres désactivés.
Barre du haut : sur une ligne jusqu'à 1365 px (elle passait sur deux lignes à 1280 px).

- Correction : le menu latéral défilait avec la page et laissait un blanc dessous
  (la vue générale portait par erreur la classe à hauteur fixe de l'aperçu d'e-mail,
  depuis `site-2026.09.27`). Il reste fixe sur toute la hauteur.
- Menu en trois groupes : Opérations, Finance (dont « Encaissements », le module
  Finances des Analytics), Gestion.
- Vue générale : filtres par pays, destination, mode de transport, statut et agence
  (lieu actuel du colis), comptés par la base ; les cartes que les filtres ne
  découpent pas le disent.
- Direct : état (en direct, mise à jour chaque minute, en pause), heure des chiffres,
  « Suspendre / Reprendre le direct ».
- « Personnaliser » : blocs affichés et leur ordre, gardés sur l'appareil.
- Apparence claire, sombre ou système (engrenage de la barre, ou Réglages), et
  animations au défilement avec un léger relief, coupées par le réglage
  « Animations » ou quand le système demande moins d'animations.

## site-2026.09.27 — nouvelle vue générale du tableau de bord (publié le 27/09/2026)

Aucune migration, aucune donnée modifiée : la page ne lit que `vue_generale` et les
Analytics, déjà en production.

- Tableau de bord : la vue générale reprend la maquette Claude Design « GoShip
  Dashboard » aux couleurs du logo (bleu nuit, orange, bleu), sur tous les écrans.
  Chiffres de `vue_generale` et, pour les comptes qui voient les rapports, des
  Analytics (comparaison à la période précédente, routes, villes, clients actifs).
  Les blocs de la maquette sans donnée dans la base (marge, agences, filtres par
  mode de transport, « mises à jour simulées ») n'ont pas été repris.

## site-2026.09.26.2 — finalisation de la mise en production (publié le 26/09/2026)

Aucune page ne change, aucune donnée n'est modifiée. **Verdict : NO-GO**
(docs/production/go-no-go.md) — preuves nouvelles : 9 migrations sur 11 en
production ; confirmation des adresses e-mail désactivée.

- Audit anonyme de la production (`sonder.sh`, `audit-production.yml`).
- Contrôles de la production en lecture seule (`controler.sh`,
  `controles-production.yml`) : journal publiable, détail chiffré.
- Préproduction outillée (`preproduction.yml`, `appliquer-chaine.sh`,
  `essai-metier.sql` dans une transaction annulée) ; profil EAS `staging`
  (dépôt mobile).
- Restauration d'épreuve après chaque sauvegarde, RPO et RTO mesurés ;
  sauvegarde chiffrée pour deux destinataires ; définition des tables de comptes
  sauvegardée.
- Surveillance : CRITIQUE / ATTENTION, fonctions du site et de l'application,
  réglage de confirmation d'e-mail, seconde personne (`ALERTE_WEBHOOK`),
  battement externe (`HEARTBEAT_URL`).
- Bureau : signature Developer ID + notarisation et Authenticode dès que les
  certificats sont posés.
- Actions de GitHub épinglées par empreinte, Dependabot.
- Essais : `essai-production.py` 70/70 (H à K nouvelles), `essai-mobile.py` 87/87
  (section Z), mobile 52/52.

## Non publié — pages de la Phase 11 (PR #13)

**À fusionner juste après `supabase-notifications.sql` en production**
(docs/production/deployment.md, « Une exception »).

- Clients : notifications dans « Mon compte » (badge, filtres, lu, préférences)
  et dans l'application.
- Équipe : onglet Notifications (règles, centre des envois, envois d'un colis) ;
  le dialogue d'un colis n'envoie plus lui-même d'e-mail ni de WhatsApp.
- Essais : `essai-notifications.py` / `.js`, remis dans `essais.yml`.

## site-2026.09.26 — outillage de production (publié le 26/09/2026)

Aucune page du site ne change, et **aucune migration n'a été exécutée** en
production. Verdict de mise en production : **NO-GO** (docs/production/go-no-go.md).

### Publication
- `deploy.yml` ne publie plus `CLAUDE.md`, `CHANGELOG.md`, `.htaccess`, `_headers`,
  `_redirects` ; refuse de publier un fichier de travail ou une clé secrète ;
  vérifie le site publié (`surveiller.sh`).
- `surveillance.yml` : toutes les 30 minutes. `essais.yml` : tous les bancs
  d'essai à chaque PR. `sauvegarde.yml` : chaque jour, une fois ses secrets posés.

### Base (fichiers seulement, à exécuter selon docs/production/deployment.md)
- `outils/migrations.txt` : la chaîne officielle.
- `supabase-notifications.sql` (Phase 11) et `supabase-production.sql` (`sante()`).
- `supabase.sql` : la contrainte `notifications_canal_check` accepte `app` (la
  chaîne ne se rejouait plus sur une base ayant des notifications de la Phase 11).
- `supabase-code-client.sql`, `supabase-factures.sql`, `supabase-numero-facture.sql`
  refusent de s'exécuter sur une base à jour (`supabase-factures.sql` aurait remis
  une ancienne version de `mes_factures`).

### Outils et documentation
- `outils/production/` : contrôles de sécurité et d'intégrité (lecture seule),
  sauvegarde chiffrée et restauration, surveillance.
- `docs/production/` : GO / NO-GO, runbook, déploiement, sauvegarde, reprise,
  surveillance, incidents, retour arrière, versions, dépannage.

### À faire à la main
- `docs/production/go-no-go.md`, actions A1 à A9.

## Déjà sur `main` (avant le 26/09/2026, jamais étiqueté)

Publié sur GitHub Pages au fil des fusions, sans version ni étiquette. L'état de
la base de production par rapport à ces changements n'est **pas connu**
(go-no-go.md, B1).

| Phase | Changement | Migration |
|---|---|---|
| 1 | Générateur des pages, factures imprimables, étiquettes 4×6, QR et Code128 | — |
| 2 | Règles des colis et des factures appliquées par la base | `supabase-services.sql` |
| 3 | Événements de colis ; le statut ne change que par eux | `supabase-evenements.sql` |
| 4 | Poste de scan | `supabase-scanner.sql` |
| 5 | Paiements, soldes, annulations, regroupement de factures | `supabase-finances.sql` |
| 6 | Rôles employé / gérant / administrateur et permissions | `supabase.sql` (partie 4) |
| 7 | Vue générale du tableau de bord, recherche rapide ; nouvel habillage | `supabase-tableau-de-bord.sql` |
| 8 | Analytics | `supabase-analytics.sql` |
| 9 | Application de bureau Windows / macOS (1.0.0) | — |
| 10 | Pré-alerte sans doublon pour l'application mobile | `supabase-mobile.sql` |

Application mobile (dépôt `goship-express-app`) : version de production 1.0.0
(build 1) fusionnée le 26/09/2026, **pas encore publiée** sur les boutiques.
