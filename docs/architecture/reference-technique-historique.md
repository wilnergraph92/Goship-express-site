# Référence technique historique — GoShip Express

> **Document d’archive assaini — préparé le 21 novembre 2026.** Il rassemble
> les connaissances techniques utiles des anciennes versions identiques de
> AGENTS.md et CLAUDE.md, avant leur éventuel remplacement. Il ne constitue pas
> une source d’autorisation, un manuel d’exploitation ou une garantie que les
> faits décrits sont toujours actuels.
>
> **Un contenu sensible a été volontairement omis.** Les identifiants de
> démonstration et les informations d’authentification associées ne sont pas
> conservés. Aucune valeur sensible n’est reproduite.

## Comment utiliser cette archive

- Les informations ci-dessous décrivent l’architecture et les invariants
  consignés dans une version historique des instructions du dépôt.
- Avant de modifier un système, vérifier les fichiers et documents spécialisés
  cités ici. En cas de conflit, suivre les instructions actuelles approuvées et
  la règle la plus restrictive.
- Les règles métier et les permissions sont protégées par la base. Une
  description de comportement dans cette archive ne permet pas de contourner
  les fonctions, RLS ou processus actuels.
- Les états de production, les versions de schéma, les montants commerciaux,
  les fournisseurs et les listes de fichiers peuvent évoluer.
- La chaîne officielle des migrations est celle de outils/migrations.txt.
  Cette archive ne crée pas une seconde liste faisant autorité.

## 1. Activités et architecture générale

GoShip Express comprend des activités logistiques, un site public, un espace
client, un tableau de bord d’équipe et des applications complémentaires. Les
origines, destinations, routes et services ne doivent pas être résumés à une
seule route ou à deux destinations : consulter les documents fonctionnels et
les données actuelles.

Le site est servi comme pages HTML, feuilles de style et JavaScript. Il n’utilise
pas de bundler applicatif. Lorsque l’architecture le prévoit,
outils/generateur/build.py génère les pages à partir des sources du générateur.
outils/traduire.py produit les pages traduites. Le workflow
.github/workflows/deploy.yml prépare l’artefact publié, applique ses exclusions
et son versionnage ; il ne lance pas le générateur.

Les pages générées se modifient dans outils/generateur/export/ ou
outils/generateur/pages/ selon leur origine, puis suivent le processus de
génération et de traduction documenté dans outils/generateur/LISEZ-MOI.md. Ne
corriger une page générée directement qu’après avoir vérifié qu’elle n’est pas
écrasée par la prochaine génération.

### Inventaire historique des modules JavaScript

| Module | Responsabilité historique |
|---|---|
| assets/js/api.js | Couche de données exposée via GoshipAPI ; accès Supabase et mode démo |
| assets/js/admin.js | Tableau de bord de l’équipe : colis, clients, factures et fiches |
| assets/js/compte.js | Espace client |
| assets/js/impression.js | Étiquettes et factures imprimables, plusieurs langues |
| assets/js/site.js | Pages publiques et suivi de colis |
| assets/js/fond.js | Fond animé des pages publiques |
| assets/js/mesure.js | Mesure d’audience, sous les réglages et protections documentés |
| assets/js/codes.js | QR codes et codes-barres |
| assets/js/scan-parser.js | Interprétation locale de codes scannés ; copie mobile à garder compatible |
| assets/js/transporteur.js | Reconnaissance prudente de certains suivis vendeurs |
| assets/js/scanner.js | Poste de scan du tableau de bord |
| assets/js/prealertes.js | Interface des pré-alertes d’équipe |
| assets/js/lieux.js | Régions, villes et lieux utilisés par les formulaires et filtres |
| assets/js/tableau-langue.js | Traduction à l’écran du tableau de bord |
| assets/js/tableau-textes.js | Textes traduits du tableau de bord, produits par l’outil de traduction |
| assets/js/notifications.js | Interface historique autour des notifications |
| assets/js/config.js | Configuration publique du site ; ne doit pas contenir de secret |

L’inventaire est indicatif et daté : vérifier l’arborescence actuelle avant
d’ajouter, supprimer ou déplacer un module. Les commentaires du projet sont en
français, avec les accents, et expliquent le pourquoi des choix. Le JavaScript
historique peut utiliser ES5, des IIFE et var ; conserver le style local du
fichier plutôt que moderniser son architecture sans demande.

## 2. Couche API et modes d’exécution

La couche API a historiquement fourni une interface commune avec un chemin
Supabase et un chemin démo local. La sélection dépend de la configuration et du
contexte d’exécution. Un mode hors service évite les opérations lorsque le site
en ligne n’est pas configuré.

Le mode démo utilise localStorage et n’est pas une base de production. Les
identifiants de démonstration sont volontairement omis de cette archive. Ne
reconstitue ni ne republie ces valeurs.

Les méthodes ajoutées à API.admin ou à d’autres interfaces à double
implémentation doivent être cohérentes côté Supabase et côté démo lorsque les
deux chemins existent. Les règles démo ne remplacent jamais les contrôles de la
base. Les essais historiques comparaissaient parfois les deux implémentations ;
consulter leurs guides avant toute vérification autorisée.

La clé Supabase publishable peut être publique par conception ; elle n’accorde
que les droits que la RLS permet. Les clés secrètes, service_role, mots de passe
et clés fournisseur ne doivent pas se trouver dans les fichiers web ou les
applications. Voir docs/production/secrets.md.

## 3. Règles métier, événements et permissions

Les règles métier sont principalement appliquées dans Supabase afin que chaque
chemin d’écriture soit contrôlé. Les fonctions de service et déclencheurs
historiquement documentés couvrent la création et la modification de colis, les
transitions de statut, la facturation, les paiements, les permissions et le
journal d’audit.

### Colis et événements

- Le statut d’un colis ne doit changer que par les opérations d’événement
  prévues par la base.
- Les événements historiques sont immuables ; une correction passe par un
  événement dédié avec son motif.
- Le poste de scan est une porte d’entrée vers les opérations métier, pas un
  lieu où recopier ou contourner les règles.
- Les statuts de transporteur externe ne sont pas des statuts GoShip et ne
  doivent pas modifier seuls le statut d’un colis.
- Le mode démo garde une copie de certaines règles métier. Une modification de
  règle doit être examinée dans les deux chemins et dans les essais documentés.

Les migrations événementielles et métier se trouvent notamment dans
outils/supabase-evenements.sql, outils/supabase-services.sql et
outils/supabase-scanner.sql. Ces noms et responsabilités sont à revalider dans
outils/migrations.txt et dans le code courant.

L’ancien texte décrivait huit statuts de colis stables et des types
d’événement plus fins. L’opération d’événement était la porte normale pour
changer le statut ; les corrections étaient elles-mêmes des événements avec un
motif obligatoire. Le scanner lisait les codes déjà imprimés et appelait la
porte d’opération, sans définir ses propres règles. Confirmer ces invariants
dans la chaîne actuelle avant toute modification.

### Permissions et authentification

Le rôle d’un compte sert à déterminer ses permissions ; les règles de données
doivent vérifier les permissions plutôt que coder des noms de rôle. RLS et les
fonctions SQL constituent les contrôles de sécurité effectifs. Les attributs
d’interface qui masquent des actions ne remplacent jamais ces contrôles.

Le rôle change par une opération dédiée et journalisée. La double
authentification de l’équipe est décrite par
docs/production/double-authentification.md et
outils/supabase-double-auth.sql. Vérifier les versions actives avant toute
conclusion sur les exigences actuelles.

Historiquement, les fonctions demandaient des permissions du domaine concerné
(par exemple clients, shipments, invoices, payments, reports, utilisateurs,
rôles, réglages ou audit). Les permissions propres au client ne devaient pas
être remplacées par une vérification du nom du rôle. L’interface pouvait
masquer une action, mais la base devait la refuser elle-même. La double
authentification concernait les permissions d’équipe et dépendait du réglage
et de l’état MFA ; les permissions propres au client suivaient un chemin
distinct.

## 4. Facturation et paiements

Les règles historiques de facturation incluent le prix calculé au niveau du
colis, des frais de service appliqués selon les opérations de facture, et une
source commune pour les totaux affichés à l’écran et à l’impression. Les
montants, champs, transitions et procédures ci-dessous sont des faits
historiques ; ils doivent être revérifiés dans assets/js/api.js et les
migrations actives avant usage.

- Le prix d’un colis est stocké et ne doit pas être recalculé à l’affichage
  d’une facture déjà émise.
- Les totaux de facture doivent venir de l’outil API prévu à cet effet, pas
  d’un calcul propre à une page.
- Les paiements sont enregistrés par une fonction contrôlée, avec vérification
  du trop-payé et mécanisme d’idempotence ; un paiement reçu s’annule avec
  motif plutôt que par édition ou suppression.
- Les factures payées ne sont pas modifiées directement. Annulation,
  regroupement, retrait de colis et correction suivent des opérations dédiées.
- Un tarif manuel, lorsqu’il existe, doit être distingué d’un prix calculé et
  être protégé par permission et journalisation.
- Les frais de service et leurs conditions historiques doivent être vérifiés
  dans outils/supabase-frais-service.sql et les fonctions de facture actives.

Les détails consignés dans l’ancienne instruction comprenaient notamment :

- Le transport calculé historiquement à 5 $/lb et 10 $ de frais de service par
  facture. Ces montants sont cités uniquement pour retracer l’ancien document ;
  ils ne sont pas présentés comme tarif actuel.
- Les frais ne naissaient pas nécessairement avec chaque colis : les chemins
  décrits les appliquaient lors de certaines opérations de regroupement ou
  d’encaissement, ou par une action dédiée. Leur état était porté par un champ
  de facture ; l’ajout ne devait pas compter deux fois.
- Le grand total de facture était arrêté à l’émission. Les montants payés,
  soldes et états de paiement provenaient des fonctions de calcul prévues et
  des paiements enregistrés.
- Le prix fixé manuellement était distingué du prix poids × tarif. Les
  contrôles de poids et de prix dépendaient de ce choix.
- Un paiement s’enregistrait par une opération idempotente, avec refus du
  trop-payé ; il s’annulait avec motif plutôt que d’être modifié ou supprimé.
- Une facture émise suivait des opérations dédiées d’annulation, correction,
  regroupement ou retrait de colis. Les corrections de montant exigeaient un
  motif et ne devaient pas réduire la facture sous le montant déjà payé.

Références : outils/supabase-facturation.sql, outils/supabase-finances.sql,
outils/supabase-corrections.sql, outils/supabase-regroupement.sql et
docs/production/database.md. Ne pas utiliser les montants historiques de
l’ancienne instruction comme tarif actuel sans confirmation.

## 5. Tableau de bord, analytics et rapports

Le tableau de bord a son habillage dans assets/css/tableau.css et ses modules
dans assets/js/. Le fichier d’apparence peut poser le thème avant l’affichage ;
chaque ajout de style doit respecter les variantes clair et sombre.

Les chiffres de la vue générale, des soldes et des résumés client sont fournis
par des fonctions de lecture dédiées. Les pages ne doivent pas recomposer des
KPI en agrégeant leurs listes. Les filtres de colis, les options de destination,
les permissions et les périodes relèvent de fonctions et modules spécialisés.
Les lignes de colis, clients et factures s’ouvrent historiquement dans une fiche
commune ; les actions y sont conditionnées par les permissions.

La vue générale avait des filtres de pays, destination, mode, statut et agence.
Les choix de destination devaient refléter les villes réellement présentes pour
le pays choisi. Les parties qui comptaient des colis étaient recalculées sur
les colis filtrés ; les données financières et les parties non découpées par
colis restaient entières. Toute option de filtre et toute agrégation doivent
être vérifiées dans la fonction de lecture, pas recalculées dans la page.

La fiche commune regroupait les informations et actions d’une ligne selon son
type et les permissions : historique de colis à l’ouverture, lignes et
paiements de facture, ou derniers colis et factures d’un client. Les boutons
des lignes de colis, clients et factures avaient été retirés au profit des
actions dans la fiche. L’impression pouvait laisser la fiche ouverte.

Les analytics comparent des périodes et distinguent les données réellement
suivies des données inconnues. Une valeur non suivie ne doit pas être présentée
comme zéro. Les rapports enregistrés représentent une définition ; les données
sont relues à l’ouverture selon la période et les permissions. Vérifier les
fonctions en vigueur dans outils/supabase-tableau-de-bord.sql,
outils/supabase-analytics.sql et outils/supabase-rapports.sql ainsi que leurs
interfaces.

## 6. Pré-alertes et suivi externe

Les pré-alertes sont des annonces de clients. La création d’un colis et le
rapprochement d’une pré-alerte passent par les fonctions prévues ; ils ne
doivent pas changer directement un statut ou un historique de colis.

Les migrations de suivi externe ajoutent une couche distincte des statuts
GoShip : suivi vendeur, événements externes, fournisseurs, synchronisation et
supervision. Un statut externe inconnu ne doit pas devenir un statut livré.
Les fournisseurs non validés ne doivent pas être traités comme actifs. Les
appels externes, quotas, données demandées et tâches planifiées sont soumis
aux contrôles et autorisations actuels.

Historiquement, la Phase 1 était une fondation de données sans lien vers le
statut d’un colis ; les phases suivantes ajoutaient moteur, synchronisation,
suivi client, notifications de transporteur et supervision d’équipe. Un statut
de transporteur ne devait jamais être présenté comme un statut GoShip. Le
fournisseur devait être vérifié et actif avant toute diffusion au client ; en
mode d’essai, aucune donnée ne devait sortir vers le client. Ces notes
décrivent l’architecture historique, pas une permission d’appeler un
fournisseur ou d’activer une tâche.

Références historiques : outils/supabase-prealertes-equipe.sql,
outils/supabase-suivi-externe.sql, outils/supabase-moteur-suivi.sql,
outils/supabase-synchro-suivi.sql, outils/supabase-mes-suivis.sql,
outils/supabase-alertes-suivi.sql et
outils/supabase-supervision-suivi.sql. Pour les règles présentes, se reporter à
outils/migrations.txt et aux documents opérationnels actuels.

## 7. Colis, étiquettes et journal d’audit

Le pays de destination, la ville et l’adresse de livraison sont des champs
distincts. L’adresse portée par un colis n’est pas l’adresse du profil client.
L’étiquette doit utiliser une liste explicite de champs autorisés et ne pas
substituer les données d’adresse du profil.

Le journal d’audit conserve les motifs requis et n’est pas éditable ou
supprimable par les interfaces ordinaires. Les corrections de colis ou
d’événement passent par les fonctions dédiées et sont journalisées.

La liste de champs d’étiquette était explicitement contrôlée : l’adresse du
profil client ne devait pas se substituer à l’adresse de livraison du colis.
La date imprimée correspondait à la date d’enregistrement indiquée par la
fonction prévue, pas au moment où l’étiquette était imprimée.

Références : assets/js/impression.js, outils/supabase-corrections.sql,
outils/supabase-evenements.sql et les guides d’impression existants.

## 8. Notifications transactionnelles

Le modèle historique est événement → règle → notification → envoi → statut.
Les déclencheurs et le travailleur de la base créent et traitent les envois.
Les pages et applications lisent les fonctions prévues ; elles ne doivent pas
envoyer directement un message en contournant le moteur.

Un envoi ne peut être déclaré envoyé ou livré sans réponse du fournisseur. Les
accusés Expo et les événements de suivi e-mail peuvent mettre à jour certains
états selon les migrations actives. Les erreurs fournisseur et les données
sensibles doivent suivre les règles de confidentialité et les guides d’incident.

Références : docs/notifications.md, outils/supabase-notifications.sql,
outils/supabase-accuses.sql et outils/supabase-suivi-courriels.sql. Confirmer
les comportements et workflows actuels avant usage.

Dans le modèle historique, les événements métier et les règles créaient des
notifications et des lignes d’envoi dans la base ; un travailleur les envoyait
et enregistrait les réponses. Les pages n’étaient pas censées envoyer
directement un message en contournant ce moteur. Les erreurs définitives
n’étaient pas à marquer comme livrées. Les gabarits et contenus d’e-mail
relevaient des migrations dédiées, pas d’un envoi ponctuel depuis une page.

## 9. Comptes, identité et connexion Google

Les flux de compte reposent sur Supabase Auth et des fonctions dédiées. Les
opérations de suppression de compte conservent certaines traces nécessaires,
effacent ou neutralisent des données suivant les règles en vigueur, et sont
refusées dans certaines conditions métier.

Les fournisseurs de connexion sociale ne doivent être présentés que si leur
état est confirmé par la configuration publique prévue. Les profils incomplets
peuvent être empêchés d’effectuer certaines opérations. Les données de document
d’identité, de naissance ou autres données sensibles doivent rester dans les
emplacements protégés et ne pas être copiées dans le journal d’audit.

Références : outils/supabase-compte.sql, outils/supabase-connexion.sql,
outils/supabase-profil-complet.sql, outils/supabase-identite.sql et
assets/js/compte.js. Vérifier les fonctions et champs courants.

Les données de profil, les documents d’identité et la date de naissance
n’avaient pas le même niveau de sensibilité ni le même stockage. Le numéro de
document et la date de naissance étaient décrits comme des données protégées,
non destinées au journal d’audit. Les nouveaux comptes Google pouvaient devoir
compléter les coordonnées du profil avant certaines actions. Toute
modification de ce parcours doit respecter les fonctions de lecture et les
règles de suppression applicables.

## 10. Programmes et applications

Les règles et valeurs commerciales des programmes sont définies par la base et
les réglages prévus, pas par des montants codés dans les interfaces. Les
programmes peuvent être éteints ou en brouillon ; ne pas inférer leur
activation depuis le code.

L’application mobile consomme des fonctions et formes de réponse qui doivent
rester compatibles avec les versions installées. L’application de bureau
Electron est une coquille autour du site, non une seconde implémentation des
règles métier. Son pont IPC doit vérifier les expéditeurs et n’exposer que les
opérations explicitement prévues.

Références : docs/programmes.md, bureau/LISEZ-MOI.md, les modules du site et
la documentation du dépôt mobile. L’application mobile est un dépôt séparé ;
ne suppose pas qu’un clone local éventuel est suivi par ce dépôt.

Le texte historique décrivait des programmes désactivés ou en brouillon, des
mouvements de points immuables, des récompenses appliquées séparément et des
événements de programme qui ne devaient pas bloquer les opérations métier.
L’application mobile lisait les résumés et écrivait par des fonctions dédiées ;
les réponses consommées par les versions installées ne devaient pas être
renommées ou remodelées sans transition.

## 11. Base de données, RLS et migrations

Les tables métier sont protégées par RLS. Les fonctions privilégiées doivent
fixer leur search_path et leurs droits d’exécution. Les permissions et les
fonctions d’opération sont les portes effectives ; l’interface ne fait que
présenter ou masquer des actions.

La chaîne officielle et son ordre sont dans outils/migrations.txt. Les scripts
de migrations, les contrôles de production en lecture seule, les outils
d’essais et les brouillons ne sont pas interchangeables. Cette archive ne
constitue pas une consigne d’exécuter du SQL.

Les règles historiques insistaient sur RLS pour les tables, des droits
d’exécution explicites pour les fonctions et un search_path fixé pour les
fonctions privilégiées. Les contrôles de sécurité et d’intégrité en lecture
seule se trouvent dans outils/production/. Les anciens textes recommandaient
des migrations rejouables et additives ; chaque migration actuelle doit
toutefois être examinée individuellement, car ce principe général ne prouve
pas son innocuité.

Références : docs/production/database.md,
outils/production/controle-securite.sql,
outils/production/controle-integrite.sql et les guides dans
outils/essais-services/, outils/essais-sql/ et outils/essais-codes/.

## 12. Traductions et générateur de pages

Les pages traduites sont historiquement des copies de pages complètes. Le
générateur et l’outil de traduction sont les sources de ces pages lorsque la
page est déclarée générée. Le tableau de bord est rédigé en français et ses
textes sont traduits à l’écran. Les décisions de logique ne doivent pas
dépendre d’un texte affiché qui peut être traduit.

Références : outils/generateur/LISEZ-MOI.md,
outils/generateur/build.py, outils/traduire.py,
outils/traductions/tableau.txt et les fichiers de traduction. Le processus de
génération ou de test n’est pas autorisé par cette archive.

Les textes du tableau de bord étaient listés dans tableau.txt puis générés en
JavaScript traduit. Les noms, notes et adresses des utilisateurs ne devaient
pas être traduits. La logique ne devait pas interpréter un texte visible,
puisqu’il change avec la langue ; un attribut sémantique devait porter l’état.

## 13. Vérification, exploitation et publication

Les anciens guides décrivent des serveurs locaux, des essais métier, des
contrôles de production, des sauvegardes, des restaurations et des workflows.
Ces procédures ne sont pas des autorisations et plusieurs états consignés
étaient datés.

- Vérifier les procédures actuelles avant toute opération.
- Une configuration locale ne garantit pas à elle seule l’absence d’accès à
  la production ; vérifier les réglages et la destination des appels.
- Les sauvegardes et restaurations sont décrites dans
  docs/production/backup.md, docs/production/disaster-recovery.md et
  docs/production/rollback.md.
- Les changements de production sont gouvernés par
  docs/production/deployment.md, docs/production/go-no-go.md et
  docs/production/checklist-release.md. Une procédure écrite ne vaut pas
  autorisation actuelle.
- Le workflow .github/workflows/deploy.yml prépare l’artefact et applique ses
  exclusions et son versionnage ; il ne lance pas
  outils/generateur/build.py.
- Les documents d’exploitation contiennent des instructions historiques
  d’application en production ; l’ambiguïté de docs/production/deployment.md
  doit être clarifiée avant toute opération de production.

## 14. Anciennes instructions écartées ou à revalider

Les éléments suivants de l’ancien document ne doivent pas être repris comme
règles actuelles :

- L’affirmation que tout fichier placé à la racine est publié : le workflow
  exclut des fichiers et prépare un artefact.
- La consigne de committer directement sur main : le processus documenté est
  branche de travail, pull request et fusion.
- La formule générale qui dit d’exécuter les migrations dans SQL Editor :
  elle ne distingue pas contrôles, essais et brouillons.
- Les anciennes indications de connexion locale à la production : elles ne
  constituent pas une procédure d’essai sûre.
- Les états de production, listes de versions et dates historiques : les
  vérifier à nouveau avant de les citer comme état courant.
- L’ancienne description de config.js comme contenant des secrets : ne pas
  recopier cette affirmation. Vérifier le contenu et la règle actuelle de
  docs/production/secrets.md ; aucune valeur secrète n’a sa place dans le site.
- Les montants ou réglages commerciaux consignés dans l’archive : vérifier
  leur valeur courante dans la source autorisée.

Les chemins suivants sont des sources de référence à consulter, pas des
autorisations d’agir : docs/production/secrets.md,
docs/production/incident-response.md, docs/production/deployment.md,
docs/communication-center/README.md et
docs/communication-center/PHASE_1_3_1_FINAL_INDEPENDENT_AUDIT.md.

## 15. Pièges de sécurité à retenir

- Ne jamais placer secrets, identifiants d’accès, clés privées, tokens ou
  données personnelles dans le dépôt, les tests, les journaux ou les rapports.
- Les fichiers racine et les pages générées ont des règles de publication
  distinctes ; vérifier l’artefact de déploiement avant toute modification
  autorisée.
- La clé publique Supabase ne remplace pas RLS et les permissions.
- Les montants doivent être formatés par l’utilitaire prévu, après vérification
  de son implémentation actuelle.
- Les informations d’authentification de démonstration ont été volontairement
  omises et ne doivent pas être reconstituées ou republiées.

## Note de clôture

Cette archive conserve une synthèse assainie des connaissances techniques de
l’ancien fichier de 728 lignes. Elle n’en est pas une copie intégrale : les
informations sensibles ont été exclues, les instructions obsolètes ont été
reformulées ou écartées, et les faits variables sont signalés comme historiques
à vérifier.
