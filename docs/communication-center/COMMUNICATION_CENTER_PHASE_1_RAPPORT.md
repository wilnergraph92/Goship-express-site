# GoShip Express — Centre de communication
# RAPPORT DE LA PHASE 1 — Architecture et conception de la sécurité

| | |
|---|---|
| Date | 18 novembre 2026 |
| Périmètre | Conception seulement : architecture, sécurité, base de données, brouillons de migrations |
| Mode | **Aucune modification de la production.** Aucune migration exécutée, aucun message envoyé, aucun fournisseur activé, aucun secret touché, rien de déployé |
| Statut | **En attente de l'approbation du CEO.** La Phase 2 n'a pas commencé |
| Documents détaillés | `COMMUNICATION_CENTER_ARCHITECTURE.md`, `COMMUNICATION_CENTER_SECURITY.md`, `COMMUNICATION_CENTER_DATABASE.md`, `brouillons-sql/40…43` (PR #65, brouillon) |

Ce rapport résume et rassemble ces documents. En cas de différence, les documents détaillés font foi.

> **Correctif Phase 1.2 (18/11/2026).** La revue indépendante Phase 1.1
> (`COMMUNICATION_CENTER_PHASE_1_1_RAPPORT.md`, verdict ÉCHEC) a relevé des affirmations fausses ou non
> prouvées dans ce rapport. Elles sont corrigées ci-dessous, à leur place, sous la mention
> **« [Corrigé 1.2] »**. Les documents de conception, les brouillons SQL et le plan d'essais ont été
> réécrits ; le détail est dans `COMMUNICATION_CENTER_PHASE_1_2_RAPPORT.md`. Ce rapport est conservé
> comme trace de la Phase 1 ; **la conception en vigueur est celle de la Phase 1.2**.
>
> Erreurs principales de la Phase 1, désormais corrigées dans la conception :
> - lien de désinscription non cliquable : `courriel_gabarit` échappe le pied [C1] ;
> - consentement sans preuve que le contact appartient au client [C2] ;
> - empreinte qui ne couvrait pas le contenu tenu par Meta [C3] ;
> - voies séparées dans la base mais pas chez les fournisseurs [C4] ;
> - conservation « pour toujours » supposée, sans chemin d'effacement [C5] ;
> - STOP tardif refusé [C6].

---

## 0. Résumé pour le CEO

1. **Deux voies séparées, jamais mélangées.** Les messages transactionnels existants (colis, factures,
   bienvenue) **ne changent pas d'un octet**. Les messages commerciaux ont leurs propres tables, leur
   propre file d'attente, leur propre travailleur, leurs propres règles de consentement. Ils n'entrent
   jamais dans le fil de notifications de l'application mobile (décision D-E).
   **[Corrigé 1.2]** Cette séparation n'était vraie que dans la base : chez Brevo et chez Meta, les
   deux voies partageaient compte, expéditeur et numéro. La conception 1.2 exige des identités d'envoi
   commerciales séparées, sans repli (ARCHITECTURE §6).
2. **Tout naît éteint.** Interrupteur général coupé, canaux coupés, plafonds à 0 (= rien ne part),
   mode « essai » (seule la liste d'essai reçoit), tâche planifiée créée **inactive**. Chaque mise en
   route est une action de l'administrateur, journalisée, sur votre décision écrite.
3. **Le gérant crée, modifie et programme ; seul l'administrateur approuve** (décision D-D).
   L'approbation porte une **empreinte** du contenu : la moindre modification après approbation
   l'annule.
   **[Corrigé 1.2]** Faux pour WhatsApp : le contenu est tenu par Meta, et l'empreinte omettait le pied,
   l'adresse, l'expéditeur et `site_url`. L'empreinte 1.2 couvre le contenu relu chez Meta et tout
   l'environnement d'envoi (ARCHITECTURE §5.3–5.4).
4. **Aucun consentement par défaut** (décision D-I). Le client coche lui-même une case jamais
   pré-cochée dans « Mon compte ». Chaque accord et chaque retrait sont gardés **pour toujours**, avec
   le texte exact lu par le client. L'équipe peut noter un retrait, **jamais** un accord.
   **[Corrigé 1.2]** « Pour toujours » était une hypothèse : les durées sont désormais BLOQUÉES jusqu'à
   l'avis du juriste, avec une purge approuvée par deux administrateurs. Le consentement n'est actif
   qu'après confirmation par le contact lui-même (lien e-mail, message WhatsApp depuis le numéro), et
   un changement de contact est une invalidation, jamais un retrait.
5. **Le recueil du consentement reste fermé tant qu'un texte n'est pas marqué « approuvé par le
   juriste »** (décision D-F) : la base l'impose.
   **[Corrigé 1.2]** La base impose une **attestation saisie par un administrateur**, avec la référence
   de l'avis ; elle ne peut pas vérifier l'avis lui-même.
6. **Deux plafonds de dépense indépendants** (global par jour, et par campagne), vérifiés **avant**
   chaque envoi, et une **réserve Brevo** qui protège les e-mails de connexion et d'inscription.
7. **Constat important sur WhatsApp** : Meta ne livre plus de messages marketing aux numéros
   américains depuis avril 2025. Les numéros dominicains commencent aussi par +1 : s'ils sont touchés,
   le marketing WhatsApp n'atteindrait que les clients haïtiens (37 sur 69 à la Phase 0, le 18/11/2026 ; 38 sur 71 au relevé du 20/11/2026, voir `PHASE_1_3_1_FINAL_INDEPENDENT_AUDIT.md` §8).
8. **Coexistence WhatsApp** (garder le numéro actuel) : possible, mais seulement par un partenaire
   agréé par Meta. Recommandation : demander 2 à 3 devis ; à défaut, un numéro GoShip dédié au
   marketing. **Le numéro actuel n'est ni migré ni déconnecté.**
   **[Corrigé 1.2]** La revue a montré que la Coexistence ferait peser le marketing sur la note de
   qualité du numéro du service client. La conception 1.2 recommande d'**étudier en priorité un numéro
   dédié** ; aucune acquisition sans votre autorisation écrite.
9. **Coût réel aujourd'hui : 0 $.** Avec 69 clients (Phase 0 ; 71 au 20/11/2026) et la moitié qui accepte, le marketing WhatsApp
   coûterait environ 3 à 4 $ par mois. Aucune activation payante n'est proposée.
10. **Brouillons SQL non validés, volontairement** : la Phase 1 n'autorise aucune exécution. Les
    éprouver sur une base jetable est la première tâche de la Phase 2.

---

## 1. Ce qui a été inspecté

| Élément | Comment | Effet |
|---|---|---|
| PR #46 (pixel Meta) et PR #48 (Centre de Commandement IA) | Branches récupérées en lecture, différences lues | Aucun |
| Toutes les occurrences de l'adresse de Miami | Recherche dans le site, le SQL, l'application mobile | Aucun |
| Volume d'e-mails en production (60 jours) | Requêtes de **lecture** en totaux seulement (aucune donnée personnelle) | Aucun |
| Faits extérieurs : Coexistence, tarifs WhatsApp, offres Brevo, droit américain/floridien, dominicain, haïtien | Recherches publiques | Aucun |
| Fonctions existantes à réutiliser (`auditer`, `erreur_metier`, `permissions_du_role`, `courriel_gabarit`…) | Lecture du dépôt | Aucun |

**Ce qui n'a pas pu être vérifié** : l'abonnement Brevo (il faut votre tableau de bord Brevo, ou un
appel en lecture avec la clé enregistrée, non autorisé) et le réglage SMTP de Supabase Auth (tableau de
bord Supabase). Les tarifs viennent de sources secondaires et doivent être confirmés sur les grilles
officielles.

---

## 2. Livrables

| Livrable demandé | Où |
|---|---|
| `COMMUNICATION_CENTER_ARCHITECTURE.md` | dossier `docs/communication-center/` |
| `COMMUNICATION_CENTER_SECURITY.md` | idem |
| `COMMUNICATION_CENTER_DATABASE.md` | idem |
| Brouillons de migrations (non exécutés) | `brouillons-sql/40` à `43`, ~2 400 lignes ; chacun commence par une garde qui arrête toute exécution |
| Schémas d'architecture mis à jour | ARCHITECTURE §2 et ce rapport §4 |
| Matrice des permissions | SECURITY §2 et ce rapport §5 |
| Analyse des coûts | ARCHITECTURE §10 et ce rapport §10 |
| Évaluation des risques | SECURITY §6 et ce rapport §11 |
| Feuille de route | ARCHITECTURE §13 et ce rapport §13 |

Livrés dans la PR **#65** (brouillon, branche de session, pas `main`) : `docs/` n'est jamais publié,
aucun fichier du site, de `outils/` ni de `assets/` n'a changé. Les 30 vérifications automatiques
sont vertes.

---

## 3. Vos décisions et ce que la conception en fait

| # | Décision du CEO | Mise en œuvre prévue |
|---|---|---|
| D-A | Base jetable + bacs à sable, pas de Supabase Pro | Bancs d'essai sur PostgreSQL jetable (comme toutes les phases précédentes) ; Brevo en mode « sandbox » ; numéro d'essai de Meta ; réévaluation avant la Phase 7 |
| D-B | Étudier la Coexistence, ne pas migrer le numéro | Évaluation §8 ; aucune migration ni déconnexion nulle part |
| D-C | Vérifier Brevo, protéger les e-mails d'authentification | Volume mesuré ; e-mail commercial **fermé** tant que le quota vérifié n'est pas saisi ; réserve calculée avant chaque e-mail |
| D-D | Gérant : créer, modifier, programmer ; admin : approuver | Permission `communications.approve` réservée à l'administrateur ; rien ne part sans approbation et empreinte intacte |
| D-E | Marketing hors du fil transactionnel mobile ; contrats d'API préservés | Tables et file à part ; aucune écriture dans `notifications` ; aucune fonction utilisée par l'application n'est modifiée |
| D-F | Exigences RD, Haïti, USA ; signaler le texte à faire valider | Section 9 ; 8 textes marqués ⚖️ ; la base refuse le recueil sans texte approuvé |
| D-G | Adresse postale en attente, ne rien inventer | E-mail commercial impossible en production sans adresse validée ; informations à confirmer listées §9.1 |
| D-H | Adresse de Miami en attente ; trouver la source et proposer | Sources trouvées et proposition §9.2 ; variable `{{adresse_miami}}` refusée tant que ce n'est pas tranché ; **rien changé** |
| D-I | Accord par l'espace client, aucun consentement par défaut | Case jamais pré-cochée ; pas de ligne = pas de consentement |
| D-J | Examiner #46 et #48 sans y toucher | §12 |

---

## 4. Architecture

### 4.1 Vue d'ensemble

```text
 Tableau de bord ──► onglet « Communications » (admin, gérant) ──► fonctions SQL communications.*
 Mon compte      ──► cases de consentement (le client, pour lui-même)
 desinscription.html (public) ──► desinscrire_communication(jeton signé)

 ┌──────────── VOIE TRANSACTIONNELLE (existante, INCHANGÉE) ────────────┐
 │ étapes de colis, facturation, bienvenue → notifications (fil mobile) │
 │ → notification_envois → traiter_notifications()  (chaque minute)     │──┐
 └──────────────────────────────────────────────────────────────────────┘  │ pg_net
 ┌──────────── VOIE COMMERCIALE (nouvelle) ─────────────────────────────┐  ├──► Expo (push)
 │ réglages · consentements (immuables) · suppressions · liste d'essai  │  ├──► Brevo (e-mail)
 │ modèles · segments · campagnes (approbation + empreinte)             │  │     + e-mails de
 │ audience figée → communication_envois → traiter_communications()     │──┘     connexion Supabase
 │ (tâche créée INACTIVE, cède la place au transactionnel)              │  └──► Meta (WhatsApp)
 │ tarifs vérifiés · dépenses du jour · retours des fournisseurs        │
 └──────────────────────────────────────────────────────────────────────┘
        ▲ retours signés
 Fonction Edge « communication-webhooks » (Phase 3) : vérifie la signature de Meta / Brevo,
 puis appelle la base avec la clé PUBLIQUE et une signature interne. Elle ne détient aucune clé
 capable de contourner les règles de sécurité de la base.
```

**[Corrigé 1.2]** Formulation trompeuse : la fonction SQL appelée s'exécute avec tous les droits et
contourne la sécurité par ligne par construction ; la clé publique n'authentifie rien ; **la seule
porte est la signature**. Les opérations permises et leur justification sont listées dans SECURITY §6.4.

### 4.2 Vie d'une campagne

```text
 brouillon ─soumettre─► en attente d'approbation ─approuver (ADMIN)─► programmée
     ▲  ◄── retirer / refuser (motif) ──┘                               │ heure venue
     └────── remettre en brouillon (avant lancement) ───────────────────┤ + interrupteurs allumés
                                                                        ▼ audience figée
 annulée ◄─ annuler ─                                      en cours ──► terminée
                                     en pause ◄─ pause (gérant/admin) ─┘  ▲
                                         └──── reprendre (ADMIN, empreinte revérifiée) ─┘
```

### 4.3 Vie d'un message commercial

```text
 attente ─(revérification juste avant)─► supprimé   (retrait, STOP, hors liste d'essai, variable manquante)
    │ hors des heures permises / fréquence atteinte → décalé, pas écarté
    │ plafond ou quota atteint → reporté au lendemain (ou campagne en pause)
    ▼
 en cours d'envoi ──accepté──► envoyé ──► livré ──► lu (WhatsApp seulement)
    │ refus temporaire (429, 5xx) → nouvel essai : 2 min, 10 min, 1 h → au-delà : abandon (file des messages morts)
    │ refus définitif ou issue inconnue → échec, JAMAIS renvoyé tout seul
```

Pourquoi « jamais renvoyé » en cas d'issue inconnue : pour un message commercial, **un doublon est pire
qu'un message manqué**. Le transactionnel, lui, continue de réessayer comme aujourd'hui.

### 4.4 Deux files, deux priorités

| | Transactionnel (existant) | Commercial (nouveau) |
|---|---|---|
| File | `notification_envois` | `communication_envois` |
| Travailleur | `traiter_notifications()` | `traiter_communications()` |
| Rythme | 50 par minute | 20 par minute (réglable) |
| Priorité | Toujours d'abord | **Attend** dès que plus de 50 messages transactionnels sont en retard |
| Doublons | clé unique existante | clé unique `campagne:<id>:<client>:<canal>` |

### 4.5 Garde-fous de l'envoi commercial

- **Heures permises** : 9 h–19 h à l'heure du client (Haïti, Santo Domingo, heure de l'Est pour les
  États-Unis) ; à confirmer par le juriste.
- **Fréquence** : au plus 1 message commercial par jour et 2 par semaine et par client, tous canaux.
- **Variables** : liste fermée (`{{prenom}}`, `{{nom_complet}}`, `{{code}}`, `{{adresse_miami}}` après
  D-H). Pas d'e-mail ni de téléphone dans un message commercial (minimisation). Un client à qui il
  manque une valeur est écarté : **jamais** de message avec une variable non remplacée.
- **Modèles WhatsApp** : seulement ceux approuvés par Meta ; un modèle mis en pause par Meta met la
  campagne en pause.

---

## 5. Matrice des permissions (exigence 8)

| Permission | Admin | Gérant | Employé | Client |
|---|---|---|---|---|
| `communications.view` — voir le Centre, l'historique, les statistiques, les dépenses | ✓ | ✓ | – | – |
| `communications.create` — brouillons, soumettre, programmer, annuler un brouillon | ✓ | ✓ | – | – |
| `communications.test` — essai vers la liste d'essai seulement | ✓ | ✓ | – | – |
| `communications.pause` — mettre une campagne en pause | ✓ | ✓ | – | – |
| `communications.approve` — **approuver**, refuser, reprendre, annuler une campagne approuvée, approuver un modèle | ✓ | **–** | – | – |
| `communications.manage` — interrupteurs, plafonds, quotas, tarifs, liste d'essai, textes de consentement, adresse postale, levée d'une suppression | ✓ | **–** | – | – |
| `communications.consents` — lire l'historique de consentement d'un client, noter un **retrait** qu'il demande | ✓ | ✓ | – | – |
| Son propre consentement commercial | – | – | – | ✓ |
| Noter un **accord** à la place d'un client | **personne** (refusé par la base) | | | |

- L'employé n'a **aucun** accès au Centre.
- La double authentification de l'équipe s'applique d'elle-même à ces permissions.
- Chaque fonction vérifie la permission dans la base ; masquer un bouton n'est qu'un confort.
- Les règles des notifications transactionnelles restent sous `settings.manage` (administrateur), comme
  aujourd'hui.
- Le détail action par action est dans SECURITY §2.2.

---

## 6. Base de données

### 6.1 Ce qui est ajouté (14 tables, toutes fermées à la lecture et à l'écriture directes)

| Table | Rôle |
|---|---|
| `communication_reglages` | Interrupteurs, mode essai/production, plafonds du jour, quota et réserve Brevo, heures, fréquence, adresse postale (D-G) |
| `communication_textes_consentement` | Textes de consentement par version, canal, langue ; référence de l'avis du juriste |
| `communication_consentements` | **Registre immuable** des accords et retraits, avec la preuve |
| `communication_suppressions` | Liste « ne plus contacter » (désinscription, STOP, rebond, plainte) |
| `communication_destinataires_essai` | Liste d'essai, la seule qui reçoit en mode essai |
| `communication_tarifs` | Prix estimés par fournisseur, canal, catégorie, pays ; « vérifié » ou non |
| `communication_depenses_jour` | Compteur de dépense du jour (messages et dollars) |
| `communication_modeles` | Modèles e-mail et WhatsApp, versionnés ; figés une fois approuvés |
| `communication_segments` | Critères d'audience en liste fermée |
| `communication_campagnes` | Campagnes, statut, plafonds, empreintes, approbation |
| `communication_destinataires` | Audience figée au lancement |
| `communication_envois` | File d'attente commerciale |
| `communication_evenements_fournisseur` | **Immuable** : retours de Meta et Brevo (codes seulement) |
| `communication_fenetres_whatsapp` | Dernier message reçu d'un numéro (empreinte), pour la fenêtre de 24 h |

### 6.2 Ce qui est touché dans l'existant — la liste complète

1. La liste des permissions (`permissions_du_role`) : **7 permissions ajoutées**, les autres
   identiques.
2. Un déclencheur ajouté sur `clients`, qui note un retrait de consentement quand l'e-mail ou le
   téléphone change, ou quand le compte est supprimé. **Il ne peut jamais bloquer** l'écriture du
   client.

Rien d'autre : aucune colonne ajoutée à une table existante, aucune fonction existante réécrite, aucune
règle de sécurité modifiée, aucune tâche planifiée existante changée.

### 6.3 Place dans la chaîne

Quatre fichiers, numéros 40 à 43, après `supabase-index-cles.sql`. Numéros provisoires si le Centre de
Commandement IA (PR #48) passe avant : les deux modifient la liste des permissions et doivent être
faits **l'un après l'autre**.

### 6.4 Points de vérification des brouillons (première tâche de la Phase 2)

1. Remplacer la garde « brouillon » par la garde habituelle.
2. Recopier la liste des permissions dans `supabase.sql` (qui fait foi) et dans `api.js`.
3. Simplifier le calcul de l'aperçu d'audience.
4. Mesurer le lancement d'une campagne sur 10 000 clients fictifs.
5. Éprouver la signature entre la fonction Edge et la base sur de vrais exemples Meta et Brevo.
6. Éprouver le calcul de la réserve Brevo (jour et mois).
7. Prouver que le nouveau déclencheur ne bloque ni la suppression de compte, ni la modification du
   profil, ni l'inscription par Google.
8. Ajouter la requête de contrôle et le témoin de chaque fichier.

---

## 7. Sécurité

### 7.1 Objectifs

1. Aucun message commercial sans consentement personnel et prouvé, canal par canal.
2. Un retrait gagne toujours, tout de suite, quel que soit son chemin.
3. Aucun message sans approbation de l'administrateur sur son contenu exact.
4. Aucune dépense au-delà des plafonds ; les e-mails de connexion jamais privés de quota.
5. En développement et en mode essai, personne hors de la liste d'essai ne reçoit rien.
6. Le transactionnel et l'application mobile ne changent pas.
7. Aucun secret dans le dépôt, le site, l'application ni la fonction Edge.
8. Chaque action de l'équipe est attribuée, motivée et journalisée ; les preuves ne se modifient pas.

### 7.2 Principales menaces et parades (15 au total : SECURITY §3)

| Menace | Parade |
|---|---|
| Écrire à quelqu'un qui n'a pas consenti | Consentement vérifié au lancement **et** juste avant chaque envoi ; lié à l'adresse exacte |
| Contenu modifié après approbation | Empreinte du contenu ; modèles figés ; vérification par le travailleur |
| Dépense qui s'emballe | Réservation sous verrou **avant** l'appel ; plafonds global et par campagne ; tarifs vérifiés seulement |
| E-mails de connexion bloqués | Quota inconnu = e-mail commercial fermé ; réserve recalculée à chaque e-mail |
| Vrais messages pendant les essais | Mode essai par défaut ; liste d'essai vérifiée deux fois par la base ; bacs à sable |
| Faux retour de fournisseur, fausse désinscription | Signatures vérifiées ; rejeu refusé ; retours de plus de 24 h refusés ; jeton de désinscription signé |
| Doublons | Clés uniques ; pas de renvoi sur issue inconnue |
| Fuite de données personnelles | Codes au lieu des textes des fournisseurs ; aperçus en nombres seulement ; contenu des messages reçus jamais gardé |

### 7.3 Secrets

Les clés existantes restent dans le coffre (Vault), inchangées. Nouveaux secrets prévus pour la
Phase 3, posés par vous-même, jamais dans une conversation ni dans le dépôt : la clé de signature des
liens de désinscription, la clé partagée entre la fonction Edge et la base, et les secrets Meta et
Brevo de la fonction Edge. **La clé `service_role` reste utilisée nulle part.**

---

## 8. Fournisseurs

### 8.1 E-mail : garder Brevo

Brevo est déjà en place et le domaine est authentifié (DKIM et DMARC vérifiés le 18/11). Resend reste
une alternative qu'un réglage suffit à choisir. Deux points à vérifier dans les conditions de Brevo
avant l'activation : l'envoi de marketing par l'API transactionnelle, et le pied « Sent with Brevo » de
l'offre gratuite.

### 8.2 Brevo et les e-mails de connexion (D-C)

**Mesuré en production (60 jours)** : 93 e-mails le jour le plus chargé (28/09), moins de 25
d'habitude ; une inscription = 3 e-mails (confirmation + bienvenue + adresse de Miami).
**[Corrigé 1.2]** Les e-mails de connexion sont une **borne basse** (`auth.users` ne garde qu'une date
par compte et par type), pas une mesure. La conception 1.2 sépare le « connu » de l'« estimé », compte
le transactionnel en attente, et utilise des fenêtres glissantes (l'heure de renouvellement de Brevo
n'est pas connue).

**Protection en couches :**
1. Pas de quota vérifié saisi → e-mail commercial fermé.
2. Le commercial ne prend que : quota − réserve (150 par jour) − e-mails de connexion du jour −
   e-mails transactionnels du jour − commercial déjà réservé.
3. Offre mensuelle : la réserve est gardée pour chaque jour restant du mois.
4. Option à décider : envoyer les e-mails de connexion de Supabase par un autre service, pour qu'ils ne
   partagent plus rien avec le marketing.

**À faire par vous** : dans Brevo, noter le nom de l'offre, les limites par jour et par mois, la date
de renouvellement ; dans Supabase > Authentication > SMTP, confirmer que Brevo est bien utilisé.

### 8.3 WhatsApp : la Coexistence (D-B)

| Point | Constat (sources publiques, à confirmer avec Meta ou un partenaire) |
|---|---|
| Principe | Le même numéro reste dans l'application WhatsApp Business et est relié à l'API ; les messages de l'application restent gratuits, ceux de l'API sont facturés |
| Mise en place | Seulement par un partenaire agréé par Meta (360dialog, Telnyx, YCloud…), ou en devenant soi-même « Tech Provider » (examen par Meta, difficile à défaire) |
| Conditions du numéro | Application WhatsApp **Business** 2.24.17 ou plus, utilisée depuis au moins 7 jours (à confirmer : le numéro est-il sur l'application Business ?) |
| Contraintes | Le téléphone doit ouvrir l'application environ toutes les deux semaines, sinon le lien avec l'API tombe ; certaines fonctions ne se synchronisent pas (groupes, étiquettes…) |
| Historique | Import des anciennes conversations proposé : **à refuser** (minimisation) |

**Recommandation** : demander des devis à 2 ou 3 partenaires (frais, conditions de traitement des
données, refus de l'import d'historique). Solution de repli : un numéro GoShip dédié au marketing, qui
isole aussi la réputation du numéro de service client.

**Constat de marché** : la pause de Meta sur le marketing vers les numéros américains (depuis le
01/04/2025, toujours signalée en novembre 2026). Les sources ne s'accordent pas sur les autres numéros
en +1 : **à vérifier pour la République dominicaine** avant toute activation.

---

## 9. Exigences juridiques et adresses

### 9.1 Les trois marchés (⚖️ = à faire valider par un juriste ; ceci n'est pas un avis juridique)

| Marché | Ce qui s'applique | Ce que fait la conception |
|---|---|---|
| **États-Unis — CAN-SPAM** | Expéditeur exact, objet honnête, **adresse postale valide**, désinscription honorée sous 10 jours ouvrés | Adresse obligatoire avant la production (D-G) ; lien de désinscription ; suppression immédiate |
| **États-Unis — TCPA et loi de Floride (FTSA, 2023)** | Consentement écrit exprès pour le marketing par message ; une case cochée suffit en Floride ; STOP à respecter ; application à WhatsApp incertaine ⚖️ ; heures ⚖️ | Case + version du texte + date ; STOP immédiat ; heures et fréquence limitées |
| **République dominicaine — Loi 172-13** | Consentement libre, sans ambiguïté, précis et informé, gardé par écrit ; droit gratuit de refuser la publicité | Consentement par canal avec le texte gardé ; retrait gratuit en un clic ; retrait noté par l'équipe sur demande |
| **République dominicaine — Loi 310-14** (non vérifiée sur le texte officiel ⚖️) | Consentement préalable, identification de l'expéditeur, désinscription sous 2 jours ouvrés | Suppression immédiate ; expéditeur identifié dans le pied |
| **Haïti** | Aucune loi générale de protection des données confirmée en vigueur fin 2026 ; Code pénal 2025 incertain ⚖️ | **La règle la plus stricte des trois marchés s'applique aussi aux clients haïtiens** |

**Textes à faire approuver par le juriste avant toute activation :**
1. Les textes de consentement (par canal, en 4 langues).
2. La section « Communications commerciales » de la politique de confidentialité (4 langues).
3. Le pied des e-mails commerciaux (raison + lien de désinscription).
4. La page de confirmation de désinscription.
5. La liste des mots STOP et une éventuelle réponse automatique.
6. Les heures permises et la fréquence.
7. L'identification de l'expéditeur et l'adresse postale.
8. La mention « publicité » dans l'objet, si elle est exigée.

### 9.2 Adresse postale (D-G) — à confirmer par vous, rien n'est supposé

1. Le nom légal exact de l'expéditeur (le site indique « Goship Express LLC »).
2. Une adresse **où GoShip reçoit vraiment son courrier** (rue, suite, ville, État, code postal).
3. L'entrepôt de Medley est-il vos propres locaux ou celui d'un prestataire ? Le format « ABX-46780 »
   ressemble à un numéro de compte chez un transitaire. Si c'est le cas, cette adresse peut ne pas
   convenir comme adresse d'expéditeur ; une boîte postale USPS ou une boîte privée enregistrée est une
   alternative conforme.
4. Faut-il aussi afficher une adresse en République dominicaine ou en Haïti (facultatif) ?

### 9.3 Adresse de Miami (D-H) — sources trouvées, rien n'est changé

| Variante | Où | Contenu |
|---|---|---|
| **A. Adresse de réception des clients** | Base (`adresse_miami()`, marquée « fait foi »), page Mon compte, accueil, application mobile, e-mail de bienvenue | 8140 NW 74th Ave Unit 3 / **ABX-46780** / Medley, Florida 33166 / tél. 786 525-2944 |
| **B. Adresse de l'entreprise sur le site** | Bandeau et pied de chaque page, données structurées | 8140 NW 74th Ave, Unit 3, **Apt 46780**, Medley, Florida 33166 / tél. +1 849 538-6262 |
| C. Ancien pied d'e-mail | `notifications.js` | 8140 NW 74th Ave, Unit 3, Medley, FL 33166 (sans suite) |
| D. Carte agence de l'application | `config.js` de l'application | 8140 NW 74th Ave Unit 3, Medley, FL 33166 |

**Source qui fait foi aujourd'hui** : la variante A, la plus récente donnée par GoShip (19/10/2026).
**Proposition** : deux notions, une source chacune — l'adresse de réception des clients dans la base,
lue partout ; l'adresse de l'entreprise = la réponse à D-G, écrite une seule fois. Question à
trancher : « Apt 46780 » et « ABX-46780 » désignent-ils la même boîte ?

---

## 10. Coûts (exigence 10) — aucune activation payante proposée

Prix publics relevés le 18/11/2026 dans des sources secondaires, **à confirmer sur les grilles
officielles** avant tout achat. Ils sont inscrits dans la base comme « non vérifiés » et bloquent
l'envoi tant qu'un administrateur ne les a pas vérifiés.
**[Corrigé 1.2]** Plus aucun prix n'est écrit dans les brouillons : la table des tarifs naît vide et ne
reçoit une ligne qu'avec sa preuve. Tous les territoires, Haïti compris, naissent bloqués.

| Élément | Prix indicatif | Aujourd'hui | Deviendrait payant… |
|---|---|---|---|
| Supabase | Gratuit ; Pro 25 $/mois | Gratuit | Seulement si un vrai projet de préproduction est décidé |
| Fonctions Edge | Incluses (500 000 appels/mois en gratuit) | Aucune | Non prévu à ce volume |
| Brevo | Gratuit 300 e-mails/jour ; Starter ≈ 9 $/mois | Offre **non vérifiée** | Quand marketing + connexion + transactionnel approchent la limite |
| Resend (alternative) | Gratuit 3 000/mois ; Pro ≈ 20 $/mois | Non utilisé | Seulement si choisi |
| WhatsApp marketing | ≈ 0,074 $ par message remis (Haïti, RD) ; USA non livré | Non configuré | Par message, après activation |
| WhatsApp utilitaire | ≈ 0,0113 $ (Haïti, RD) ; gratuit dans la fenêtre de 24 h | Non configuré | Non utilisé par le marketing |
| Partenaire Coexistence | Variable : **devis nécessaire** | — | Si la Coexistence est retenue |
| Numéro dédié (repli) | Faible coût mensuel : **devis nécessaire** | — | Si la Coexistence est écartée |
| Juriste (USA/Floride, RD, Haïti) | Ponctuel : **devis nécessaire** | — | **Obligatoire** avant l'ouverture du recueil |
| Apple Developer | 99 $/an | Absent | Seulement pour iOS |

**Exemple** (chiffres de la Phase 0 ; 71 clients au 20/11/2026, ordre de grandeur inchangé) : 69 clients, la moitié accepte → WhatsApp ≈ 19 clients haïtiens (+ ≈ 9 dominicains si la
pause +1 ne les touche pas) × 2 campagnes/mois × 0,074 $ ≈ **3 à 4 $ par mois** ; e-mail ≈ 70 par mois,
dans l'offre gratuite. À 1 000 clients : WhatsApp ≈ 40 à 60 $ par mois, e-mail ≈ 1 000 par mois (offre
Starter nécessaire les jours de campagne). Les plafonds bornent tous les scénarios.

---

## 11. Risques (15 au total : SECURITY §6)

| Risque | Probabilité | Impact | Parade |
|---|---|---|---|
| Plainte réglementaire (consentement absent ou invalide) | Faible avec la conception | Élevé | Consentement exigé, textes approuvés, preuves |
| WhatsApp marketing inaccessible aux USA (et peut-être RD) | Élevée | Moyen (valeur) | Connu d'avance ; e-mail privilégié pour ces clients |
| La Coexistence perturbe le numéro du service client | Faible à moyenne | Élevé | Partenaire expérimenté, hors heures d'ouverture, repli sur un numéro dédié |
| Quota Brevo épuisé → connexions bloquées | Faible avec la réserve | Élevé | Réserve, quota vérifié, option d'isoler les e-mails de connexion |
| Dépassement de coût | Faible | Moyen | Plafonds, tarifs vérifiés, réservation avant envoi |
| Régression des notifications existantes | Faible | Élevé | Aucune modification du transactionnel ; bancs de régression |
| Première fonction Edge du projet | Moyenne | Moyen | Une seule fonction, droits minimaux, convention commune avec la PR #48 |
| Pas de vraie préproduction | Moyenne | Moyen | Base jetable + bacs à sable ; réévaluation avant la Phase 7 |
| Brouillons SQL non encore validés | Certaine (règle de la phase) | Faible | Première tâche de la Phase 2 |
| Conflits avec les PR #46 et #48 | Moyenne | Faible | Les ordonner avant la Phase 2 |

---

## 12. Les PR ouvertes (D-J) — examinées, non modifiées

| PR | Contenu | Conflit | Recommandation |
|---|---|---|---|
| **#46** pixel Meta | Pixel sur les pages publiques (sans collecte automatique, coupé sur les adresses de suivi, respect de « Ne pas me suivre »), section de la politique de confidentialité en 4 langues, 92 pages régénérées | Touche **les mêmes fichiers** que la future section « Communications commerciales » de la politique de confidentialité ; en retard d'environ 30 changements sur `main` (polices et règles de sécurité du 16/11) ; les liens de campagne avec `utm_*` chargeront le pixel (à mentionner dans la politique) | Décider de #46 **avant** le travail sur la politique de confidentialité ; s'il est gardé, le mettre à jour d'abord |
| **#48** Centre de Commandement IA (document seul) | Tables `ia_*`, une fonction Edge avec la clé Claude, une permission `ia.commander`, une migration | Les deux projets ajoutent des migrations en fin de chaîne, modifient la liste des permissions et introduisent la **première fonction Edge** ; l'agent « Service client » ne doit jamais recevoir une fonction d'envoi `communications.*` | Simple question d'ordre : les faire **l'un après l'autre**, une seule convention pour les fonctions Edge |

---

## 13. Feuille de route (chaque étape demande votre accord écrit)

| Phase | Contenu | Condition de sortie | Effort estimé |
|---|---|---|---|
| **1** (celle-ci) | Conception, brouillons | Votre approbation | fait |
| **2a** | Fondation et consentement (40, 41) sur base jetable ; permissions dans `supabase.sql` et `api.js` ; bancs d'essai ; régression de tous les bancs existants | Tout est vert ; transactionnel identique ; **rien en production** | 5 à 7 séances |
| **2b** | Campagnes et file (42, 43) ; travailleur avec fournisseurs simulés ; concurrence, plafonds, heures, STOP, désinscription, signatures | Idem | 6 à 8 séances |
| **2c** | Cases de consentement dans Mon compte (4 langues), politique de confidentialité, page de désinscription | Textes approuvés par le juriste | 3 à 4 séances |
| **Prod-A** | Exécuter 40–43 en production, sauvegarde vérifiée d'abord, **tout éteint** | Votre GO écrit | 1 séance |
| **3** | Fonction Edge ; Brevo en bac à sable ; numéro d'essai Meta ; Coexistence par un partenaire ou numéro dédié | Essais réels vers la liste d'essai seulement, sur votre autorisation | 5 à 6 séances + délais du partenaire |
| **4** | Interface du Centre (11 vues, mode démo, 4 langues) | Bancs navigateur verts | 7 à 9 séances |
| **5** | Automatisations commerciales (relance des inactifs) | | 2 à 3 séances |
| **6** | Statistiques et surveillance | | 2 séances |
| **7** | Qualité (points A à M), réévaluation de la préproduction, activation par étapes | Votre GO à chaque étape | 3 à 4 séances |

Application mobile : écran de consentement dans une version ultérieure ; les versions installées ne
sont pas touchées.

### Retour arrière (exigence 9)

| Situation | Action | Effet sur l'existant |
|---|---|---|
| Arrêter tout le commercial | Couper l'interrupteur général (administrateur, journalisé) | Aucun |
| Arrêter un canal ou une campagne | Couper le canal ; mettre en pause ou annuler | Aucun |
| Arrêter le travailleur | Désactiver la tâche planifiée | Aucun |
| Migration défaillante | Tout éteindre ; script de retrait relu (déclencheur retiré, permissions remises) ; tables gardées (preuves) | Aucun, par construction |
| Restauration de la base | Les nouvelles tables sont dans la sauvegarde ; les secrets du coffre doivent être ressaisis ; les anciens liens de désinscription renvoient alors vers « connectez-vous pour vous désinscrire » | Comme aujourd'hui pour les clés des fournisseurs |

---

## 14. Décisions encore nécessaires

1. **D-G** — l'adresse postale (§9.2).
2. **D-H** — l'adresse de Miami de référence, et si « Apt 46780 » = « ABX-46780 ».
3. **Brevo** — l'offre, les limites, et s'il faut isoler les e-mails de connexion.
4. **Coexistence** — devis de partenaires, ou numéro dédié.
5. **Juriste** — engagement pour les textes, la politique de confidentialité, les heures, STOP.
6. **Quatre yeux** — un administrateur peut-il approuver une campagne qu'il a créée ? (par défaut :
   oui, journalisé).
7. **Modèles** — le gérant peut-il approuver un modèle ? (conception : non).
8. **Variables** — `{{email}}` et `{{telephone}}` dans le marketing ? (conception : non).
9. **Conservation** — registre de consentement et suppressions : toujours ; file commerciale :
   24 mois ; retours des fournisseurs : 90 jours.
   **[Corrigé 1.2]** Ce ne sont que des propositions : aucune durée n'est appliquée sans l'avis écrit du
   juriste (SECURITY §7).
10. **PR #46 et #48** — dans quel ordre.

---

## 15. Rapport de phase (cahier des charges §14)

1. **Inspecté** : PR #46 et #48 ; toutes les adresses de Miami (site, SQL, application) ; volume
   d'e-mails en production par requêtes de lecture en totaux ; faits publics sur la Coexistence, les
   tarifs, Brevo et le droit des trois marchés ; fonctions existantes à réutiliser.
2. **Réalisé** : conception (architecture, sécurité, base de données), brouillons SQL gardés, ce rapport.
3. **Fichiers modifiés** : seulement ajoutés, tous dans `docs/communication-center/` (jamais publié) :
   README, audit de la Phase 0, trois documents de conception, quatre brouillons SQL, ce rapport. Aucun
   fichier du site, de `outils/` ou de `assets/`.
4. **Changements de base** : aucun. Seules des requêtes de lecture (totaux) ont été faites en production.
5. **Essais faits** : aucun essai de code (aucune exécution autorisée) ; les 30 vérifications
   automatiques de la PR #65 sont vertes (elles éprouvent le code existant, inchangé).
6. **Résultats** : vert ; les brouillons, eux, restent à valider.
7. **Conséquences de sécurité** : aucune tant que rien n'est exécuté ; à la mise en œuvre, deux
   fonctions publiques (désinscription, retours des fournisseurs), toutes deux protégées par signature,
   et une première fonction Edge sans clé capable de contourner la sécurité.
8. **Blocages restants** : D-G, D-H, offre Brevo, choix Coexistence ou numéro dédié, juriste, ordre des
   PR #46 et #48 ; vérification de la pause +1 pour la République dominicaine.
9. **Coût estimé de la phase suivante** : Phase 2 ≈ 14 à 19 séances de travail ; aucun coût extérieur,
   sauf le juriste (devis) avant l'ouverture du recueil.
10. **Approbation nécessaire pour continuer** : votre approbation écrite de la Phase 1, qui autorise la
    Phase 2 **sur base jetable uniquement, sans aucune modification de la production**, et vos réponses
    (ou un report explicite) aux décisions de la section 14.

---

## Sources

- [Embedded Signup (Meta)](https://developers.facebook.com/documentation/business-messaging/whatsapp/embedded-signup/overview)
- [360dialog — Coexistence onboarding](https://docs.360dialog.com/partner/waba-management/phone-number-and-hosting/whatsapp-coexistence/coexistence-onboarding)
- [Telnyx — Coexistence](https://developers.telnyx.com/docs/messaging/whatsapp/coexistence)
- [YCloud — Business App Coexistence](https://www.ycloud.com/blog/whatsapp-business-app-coexistence-meta-update)
- [Dualhook — Coexistence limitations](https://dualhook.com/whatsapp-coexistence-limitations)
- [Forum développeurs Meta — Tech Provider et sa propre entreprise](https://developers.facebook.com/community/threads/1403894925145722/)
- [WATI — Marketing vers les numéros US, état 2026](https://www.wati.io/en/blog/whatsapp-marketing-messages-us-2026/)
- [Salesforce — Échecs de modèles vers les numéros US](https://help.salesforce.com/s/articleView?id=004633478&language=en_US&type=1)
- [usewhapi — Tarifs WhatsApp par pays](https://usewhapi.com/whatsapp-api-pricing/)
- [srileo — Tarifs « Rest of Latin America »](https://srileo.com/tools/whatsapp-api-pricing-calculator/rest-of-latin-america/)
- [Blueticks — Tarifs WhatsApp API 2026](https://blueticks.co/blog/whatsapp-business-api-pricing-2026)
- [EmailVendorSelection — Tarifs Brevo](https://www.emailvendorselection.com/brevo-pricing/)
- [smtpedia — Tarifs Brevo](https://smtpedia.com/brevo-pricing/)
- [Loi 172-13 (texte officiel, one.gob.do)](https://www.one.gob.do/media/u5ohmfyp/ley-172-13.pdf)
- [gmedia.do — Loi 172-13 et les sites web](https://gmedia.do/actualidad/ley-172-13-proteccion-datos-web-republica-dominicana)
- [Orrick — Amendement de la FTSA (Floride)](https://infobytes.orrick.com/2023-06-07/florida-tightens-restrictions-phone-and-text-solicitations/)
- [Sénat de Floride — Résumé de la loi de 2023](https://www.flsenate.gov/Committees/BillSummaries/2023/html/761)
- [DLA Piper — Protection des données en Haïti](https://www.dlapiperdataprotection.com/?c=HT&t=law)
