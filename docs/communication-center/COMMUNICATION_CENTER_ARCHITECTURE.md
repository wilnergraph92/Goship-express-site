# GoShip Express — Centre de communication
# COMMUNICATION_CENTER_ARCHITECTURE.md — version Phase 1.2

| | |
|---|---|
| Date | 18 novembre 2026 |
| Version | **Phase 1.2** — corrige la version Phase 1 après la revue indépendante Phase 1.1 (`COMMUNICATION_CENTER_PHASE_1_1_RAPPORT.md`) |
| Statut | **Conception à approuver par le CEO.** Rien n'est mis en œuvre, exécuté, activé ni déployé |
| Documents liés | `COMMUNICATION_CENTER_SECURITY.md`, `COMMUNICATION_CENTER_DATABASE.md`, `COMMUNICATION_CENTER_TESTING.md`, `brouillons-sql/40…43` (gardés, jamais exécutés), `COMMUNICATION_CENTER_PHASE_1_2_RAPPORT.md` |

Les identifiants entre crochets (**[C1]**, **[H4]**, **[M7]**…) renvoient aux constats de la revue 1.1.

---

## 1. Principes (opposables aux Phases 2 à 7)

1. **Deux voies, jamais mélangées — dans la base ET chez les fournisseurs** [C4]. Transactionnel
   (existant, inchangé) et commercial (nouveau) ont leurs tables, leur file, leur travailleur, leurs
   règles de consentement **et leurs identités d'envoi** : compte, expéditeur et clés e-mail
   commerciaux ; numéro WhatsApp commercial. Le commercial n'utilise jamais une clé ou un expéditeur du
   transactionnel, même en repli. Un message commercial n'est jamais écrit dans `notifications`,
   `notification_envois`, `mon_resume` ni `messages_recents` (décision D-E).
2. **Le transactionnel est préservé à l'octet près.** Aucune fonction, table, règle, tâche planifiée ni
   contrat d'API existant n'est modifié ; `courriel_gabarit` et `expedier_envoi` ne sont ni modifiés ni
   réutilisés pour le commercial [C1]. Seuls changent : la liste des permissions (7 ajouts, dans toutes
   ses copies [H10]) et un déclencheur **ajouté** sur `clients`, qui ne peut jamais bloquer [M13].
3. **Tout se décide dans la base**, comme le reste de GoShip. Les pages affichent et demandent ; la base
   refuse d'elle-même.
4. **Tout naît éteint ou BLOQUÉ.** Interrupteurs coupés, plafonds à 0, mode « essai », tâche planifiée
   créée inactive, quota Brevo, limite WhatsApp, identité légale, adresse postale, numéro commercial,
   tarifs et territoires : **vides tant qu'une preuve ou une décision n'est pas enregistrée**.
5. **Échec fermé.** Valeur inconnue, preuve absente, modèle non vérifiable chez Meta, variable non
   résolue, clé absente, issue inconnue d'un appel : **rien ne part**.
6. **Les preuves sont immuables**, avec **une seule** exception : la purge approuvée par deux
   administrateurs [C5].
7. **Un doublon est pire qu'un message manqué** : une issue inconnue n'est jamais renvoyée seule [H8].
8. **Une opposition ne se perd jamais** : aucun âge maximal pour un STOP, une plainte ou une
   désinscription [C6].

---

## 2. Schémas d'architecture (mis à jour)

### 2.1 Vue d'ensemble

```text
 admin.html, onglet « Communications » (admin, gérant)  ──► fonctions SQL communications.* (permission + 2FA)
 mon-compte.html (+ application plus tard) ──► état / demande / retrait de SON consentement (contact masqué)
 confirmation-communication.html (public, bouton) ──► confirmer_consentement_communication(jeton)   [anon]
 desinscription.html (public, bouton)             ──► desinscrire_communication(jeton signé)        [anon]

 ┌──────────── VOIE TRANSACTIONNELLE (existante, INCHANGÉE) ─────────────────┐
 │ colis, facturation, bienvenue → notifications (fil mobile)               │   identité e-mail
 │ → notification_envois → traiter_notifications()                          │── transactionnelle ──► Brevo (compte actuel)
 │ courriel_gabarit, expedier_envoi : non modifiés                          │   + e-mails de connexion Supabase Auth
 └───────────────────────────────────────────────────────────────────────────┘   numéro WhatsApp actuel (non touché)
 ┌──────────── VOIE COMMERCIALE (nouvelle) ──────────────────────────────────┐
 │ réglages (éteints, BLOQUÉS) · consentement demande→confirmé (immuable)    │   identité e-mail
 │ suppressions · liste d'essai · indicatifs · tarifs · codes fournisseurs   │── commerciale séparée ──► Brevo (compte ou
 │ modèles (+ image relue chez Meta) · segments · campagnes (empreinte,      │   (décision C4)          expéditeur commercial)
 │   volume approuvé) · audience figée (contact exact)                       │
 │ communication_envois → traiter_communications()                           │── numéro WhatsApp ──────► Meta Cloud API
 │   (créée INACTIVE, cède la place au transactionnel)                       │   commercial (décision C4)
 │ dépenses du jour (verrou) · conservation et purge à quatre yeux           │
 └───────────────────────────────────────────────────────────────────────────┘
          ▲ communication_recevoir_evenement(fournisseur, texte brut, HMAC)  [rôle communication_webhook + signature — Corrigé 1.3 : plus « anon »]
 Fonction Edge « communication-webhooks » (Phase 3) : Meta (X-Hub-Signature-256 sur le corps brut),
 Brevo (jeton secret + adresses IP, protections plus faibles, à confirmer), désinscription en un clic.
 Elle ne détient AUCUNE clé capable de contourner la sécurité de la base ; c'est la fonction SQL qu'elle
 appelle qui s'exécute avec tous les droits. [Corrigé 1.3] Deux protections : le rôle dédié (sans connexion
 tant que le CEO n'a pas choisi comment la fonction Edge s'authentifie) puis la signature ; débit borné
 dans la base (PHASE_1_3_TECHNICAL_CORRECTIONS.md §8).
```

### 2.2 Vie d'un consentement [C2, H6, H7]

```text
 (aucune ligne) = AUCUN consentement
     │ le client coche, dans SA langue, le texte attesté ; le contact exact lui est montré (masqué)
     ▼
 en_attente ──── e-mail : clic sur le bouton de la page ouverte par le lien signé (usage unique, durée limitée)
     │      └─── WhatsApp : « OUI 123456 » (ou YES, SÍ, WI) envoyé DEPUIS le numéro concerné
     ▼
 confirme ──► seul état qui permet un envoi commercial, et seulement pour le contact ACTUEL
     │
     ├─ retire   ◄── case décochée · lien de désinscription · STOP reconnu · opposition Meta · demande à l'équipe
     └─ invalide ◄── e-mail ou numéro changé · compte supprimé · (jamais un « retrait »)
 L'équipe ne peut jamais confirmer ni accorder. Lever une suppression ne rend jamais le consentement.
 Toutes les écritures prennent le verrou client+canal ; à heure égale, le retrait ou l'invalidation gagne.
```

Une plainte fournisseur crée une suppression « plainte » sur le canal et le contact visés. Elle ne
change pas à elle seule l'état du consentement ; un retrait exige un signal explicite distinct.

### 2.3 Vie d'une campagne [D-D, C3, H9, H13]

```text
 brouillon ─soumettre─► en_attente_approbation ─approuver (ADMIN : empreinte, volume, coût, Meta)─► programmee
     ▲  ◄── retirer / refuser (motif) ──┘   ▲                                                         │
     └── remettre_en_brouillon ─────────────┼─────────────────────────────────────────────────────────┤ heure venue
                                            └─ AUDIENCE_DEPASSEE (volume réel > approuvé + seuil) ◄───┤
                                                                                                      ▼
  annulee ◄─ annuler ─                                      en_cours ──────────────────────────► terminee
                                    en_pause ◄─ pause (gérant/admin) ─┘ ▲   pauses automatiques : EMPREINTE_CHANGEE,
                                        └── reprendre (ADMIN, empreinte revérifiée) ┘   MODELE_META_*, PLAFOND_CAMPAGNE_*,
                                                                                        PIED_COMMERCIAL_INCOMPLET, CODE_<meta>
```

### 2.4 Vie d'un message commercial [H4, H5, H8]

```text
 attente ─(revérifié : consentement, suppression, contact inchangé, liste d'essai)─► supprime
    │ heures / fréquence (sous verrou client) → décalé ; plafond du jour → demain 9 h ; plafond campagne → pause
    ▼
 traitement ──2xx──► envoye ──retour──► livre ──retour──► lu (WhatsApp)
    │ [Corrigé 1.3] 5xx → INCERTAIN (jamais de nouvel essai) ; 429 → INCERTAIN, sauf règle PROUVÉE
    │   (communication_issues_http) → nouvel_essai (2 min, 10 min, 1 h) → au 3e : abandon (messages morts)
    │ autre 4xx → echec
    │ délai dépassé, réseau, pas de réponse → INCERTAIN ── rapprochement par la référence « communication:<id> »
    │                                                    └─ 72 h sans preuve : reste incertain (clos), jamais renvoyé seul
 campagne annulée avant l'envoi → annule
```

---

## 3. Décisions du CEO et leur traduction

| # | Décision | Mise en œuvre |
|---|---|---|
| D-A | Base jetable + bacs à sable, pas de Supabase Pro | `COMMUNICATION_CENTER_TESTING.md` ; réévaluation avant la Phase 7 |
| D-B | Étudier la Coexistence, ne pas toucher au numéro | §6.2 ; aucun repli sur le numéro actuel ; rien ne migre ni ne déconnecte |
| D-C | Vérifier Brevo, protéger les e-mails de connexion | §5.6 ; e-mail commercial fermé sans quota prouvé ; réserve ; fenêtres glissantes |
| D-D | Gérant : créer, modifier, programmer (et mettre en pause) ; admin : approuver | `communications.approve` réservé à l'administrateur ; SECURITY §2 |
| D-E | Marketing hors du fil transactionnel mobile | Tables à part ; aucune écriture dans `notifications` ni `messages_recents` |
| D-F | Exigences RD, Haïti, USA ; textes à valider | SECURITY §5 ; textes ⚖️ ; la base exige une attestation (pas une vérification) |
| D-G | Adresse postale en attente | `identite_legale`, `adresse_postale` BLOQUÉES ; pas d'e-mail commercial sans elles |
| D-H | Adresse de Miami en attente | `{{adresse_miami}}` refusée tant que non validée ; e-mail seulement |
| D-I | Consentement par l'espace client, aucun par défaut | §5.2 ; confirmé par le contact lui-même |
| D-J | PR #46, #48 examinées sans y toucher | §8 |
| Phase 1.2 | Identité e-mail commerciale distincte ; étudier un numéro WhatsApp dédié ; rien acheter ni configurer | §6 ; décisions attendues §11 |

---

## 4. Files, priorités, planification

| | Transactionnel (existant) | Commercial (nouveau) |
|---|---|---|
| File | `notification_envois` | `communication_envois` (natures `campagne` et `confirmation`) |
| Travailleur | `traiter_notifications()` | `traiter_communications()` — [Corrigé 1.3] **procédure**, un COMMIT par envoi |
| Tâche | `goship-notifications` (chaque minute) | `goship-communications` (chaque minute, **créée inactive**) |
| Lot | 50 par passage | `lot_par_minute` = 20 par passage ; [1.3] **débit global** `debit_max_minute` = 20 (tous travailleurs) |
| Priorité | Toujours d'abord | **Cède** : plus de `attente_transactionnel_max` (50) envois transactionnels dus → aucun envoi commercial ce passage |
| Délai HTTP | défaut de pg_net (inchangé) | explicite : `delai_http_ms` = 20 000 [H8] |
| Nouvel essai | 30 s, 2 min, 10 min, y compris réseau | 2 min, 10 min, 1 h ; [Corrigé 1.3] **seulement** sur un refus PROUVÉ sûr (vide par défaut) ; 5xx, 429 et issue inconnue = `incertain` |
| Messages morts | `echec` `ABANDON_…` | `abandon`, relance manuelle par l'administrateur [M4] |
| Doublons | clé unique existante | clé `campagne:<id>:<client>:<canal>` ; audience unique (campagne, client, canal) |
| Concurrence | `skip locked` | [Corrigé 1.3] un envoi par transaction ; ordre unique N0 interrupteurs → N1 campagne → N2 client → N3 consentement → N4 envoi → N5 compteurs (40 §3) ; arrêt d'urgence `arret_urgence` |

> **Décision K (CEO, 23/11/2026).** Les notifications **transactionnelles** gardent le nouvel essai du moteur officiel (colonne de gauche) après une réponse 408, 425 ou 5xx, une erreur réseau, un délai dépassé ou un silence du fournisseur : un message reçu deux fois gêne peu, un message perdu est un défaut de service. La règle « 5xx et issue inconnue = `incertain`, jamais renvoyé seul » reste celle des **campagnes** et des codes de confirmation WhatsApp. Mise en œuvre : `lire_reponse_envoi` de la candidate 005.

**Planification.** `planifiee_le` ; une campagne lancée par passage. **Heures permises** 9 h–19 h à
l'heure du destinataire ([Corrigé 1.3] fuseau déclaré, Haïti, Santo Domingo, ou État américain à un seul fuseau
enregistré avec preuve ; **sinon inconnu : rien ne part** — plus d'heure de l'Est par défaut) ; **fréquence** 1 par jour et
2 par semaine, tous canaux, messages en cours compris [H4]. À confirmer par le juriste.

**pg_cron** accepte des intervalles en secondes ; la minute suffit et reste alignée sur le
transactionnel [L1].

---

## 5. Composants

### 5.1 Habillage des e-mails commerciaux [C1, M8]
`communication_courriel_commercial` (brouillon 43 §4.3) : un habillage **propre au commercial**, qui
n'utilise ni ne modifie `courriel_gabarit`. Chaque **texte** est échappé ; le lien de désinscription est
placé dans `href="…"` (adresse échappée pour un attribut) et forme donc un **vrai lien cliquable**. Le
pied porte la raison de l'envoi, le lien, l'identité légale et l'adresse postale. Il renvoie **null —
donc refus d'envoi —** si la clé de signature des liens, l'identité légale ou l'adresse postale manquent
(les deux dernières restent BLOQUÉES jusqu'à la décision D-G). La version de l'habillage
(`habillage-commercial-v1`) entre dans l'empreinte d'approbation. En-têtes : `List-Unsubscribe` (et
`List-Unsubscribe-Post` en un clic quand la fonction Edge existe). Preuves exigées : TESTING groupe 7.

### 5.2 Consentement confirmé par le contact [C2, H6, H7, M1, M14]
- **Écran** : pour chaque canal, l'état (`aucun`, `en_attente`, `confirme`, `retire`, `invalide`), le
  **contact exact masqué** (« j•••@gmail.com », « +509 •••• ••12 »), le texte attesté **dans la langue de
  l'écran**, sans repli silencieux sur une autre langue.
- **Demande** : exige la version et la langue exactes du texte affiché ; crée l'étape `demande` (en
  attente) et une confirmation. Limites : 5 changements et 3 demandes de confirmation par canal et par 24 h.
- **E-mail** : le travailleur envoie un e-mail de confirmation (nature `confirmation`) avec un jeton de
  256 bits, dont seule l'empreinte est gardée, à usage unique, valable 168 h. La page appelle la
  fonction **au clic sur un bouton**, jamais au chargement (les robots de messagerie ouvrent les liens).
  Refus si le contact a changé ou si un retrait a eu lieu depuis la demande.
- **WhatsApp** : le client envoie « OUI 1234 » (ou YES, SÍ, WI) **depuis le numéro concerné** au numéro
  commercial affiché. Le code est tiré au hasard, et le message doit venir du numéro dont l'empreinte est
  celle de la demande. Mots à valider (juriste, Meta).
- **Jamais** un consentement activé parce que l'équipe a saisi un numéro : l'équipe ne peut ni demander
  ni confirmer pour un client.
- **Changement de contact** : invalidation, avec l'empreinte de l'ancien contact ; le nouveau n'hérite
  de rien.
- **Retrait** : toujours permis, sans limite, effet immédiat.

### 5.3 Modèles WhatsApp vérifiés chez Meta [C3, H9, M10]
Le contenu qui fait foi est celui **relu chez Meta** (brouillon 42 §2). Méthode **prévue, à confirmer** :
la liste des modèles du compte WhatsApp Business par l'API Graph (nom, langue, statut, catégorie,
composants). L'image est normalisée (type, format, texte, boutons : type, texte, adresse, téléphone) et
hachée. Vérifications :
- à l'**approbation du modèle** (image fraîche, APPROVED, MARKETING) → `empreinte_meta_approuvee` ;
- à l'**approbation de la campagne** et au **lancement** ;
- pendant l'envoi, à chaque lot, avec une image de moins de `modele_meta_fraicheur_min` (60 min) —
  **pas avant chaque message**, une requête par message serait excessive (limite documentée).

Différence, statut autre qu'APPROVED, catégorie autre que MARKETING, image absente ou trop vieille :
**pause** de la campagne avec la raison, journalisée. Tant que la méthode de lecture n'est pas
confirmée sur un compte d'essai, **aucun modèle WhatsApp ne peut être approuvé** (échec fermé).
**Versionnement** : un modèle approuvé est figé ; toute modification crée une nouvelle version, à
approuver de nouveau, et chez Meta un nouveau nom (`…_v2`).

### 5.4 Empreinte d'approbation complète [H9]
Elle couvre : les champs de la campagne ; chaque modèle (empreinte locale **et** image Meta approuvée) ;
l'**environnement d'envoi** — identité légale, adresse postale, expéditeur (haché), nom d'expéditeur,
numéro commercial (haché), `site_url`, version de l'habillage, textes du pied (4 langues),
`adresse_miami()` si validée. Tout changement invalide l'approbation : refus à l'approbation, pause au
lancement et pendant l'envoi. Chaque envoi garde l'empreinte du contenu réellement envoyé.

### 5.5 Dépenses et plafonds [H1, H11, H13, M7]
- **Verrou du jour pris d'abord**, puis somme de toutes les lignes du jour, puis réservation : deux
  travailleurs, même sur deux canaux, passent l'un après l'autre.
- Plafonds **globaux** (USD et messages), **par campagne** (dans l'empreinte), **limite quotidienne de
  destinataires du numéro WhatsApp** (valeur attribuée par Meta, BLOQUÉE tant qu'elle n'est pas connue).
- La campagne est **relue sous verrou** : une pause validée arrête les lots suivants ; les messages déjà
  remis à pg_net suivent leur cours.
- Un refus définitif ne rend pas la réservation ; une erreur avant l'appel l'annule (sous-transaction).
- **Volume** : l'administrateur approuve un volume et un coût réels ; au lancement, au-delà du volume
  approuvé + seuil (10 %) ou des plafonds, la campagne retourne en attente d'approbation
  (`AUDIENCE_DEPASSEE`).

### 5.6 Protection de Brevo [D-C, H2, H3, M12]
- E-mail commercial **fermé** tant que le quota n'est pas saisi **avec sa preuve** (page Brevo, date)
  par `verifier_quota_brevo`.
- Tant que le commercial partage le compte du transactionnel, il ne prend que : quota − réserve
  (150/24 h) − connexion **estimée** (borne basse) − transactionnel **connu** (envoyé **et en attente**)
  − commercial réservé.
- Fenêtres **glissantes** de 24 h et 30 jours : l'heure de renouvellement de Brevo n'est pas supposée.
- Calcul **une fois par passage**.
- Une identité commerciale sur un **compte Brevo séparé** supprime le partage (décision C4).

### 5.7 Désinscription, suppression, opposition [C6, H5, M4]
- Suppression par **canal** et **contact exact**.
- Le lien bloque le contact qui a **reçu** le message, jamais la nouvelle adresse.
- STOP, plainte, opposition Meta, désinscription chez le fournisseur : jamais refusés pour leur âge.
- Suppression manuelle par l'équipe (`communications.consents`). Levée : administrateur, motif ; elle ne
  rend jamais le consentement. Une nouvelle inscription **confirmée par le contact** lève ses propres
  désinscriptions et STOP (règle à valider par le juriste), jamais une plainte, un rebond ou une
  suppression manuelle.
- **Le transactionnel n'est jamais touché** : aucune fonction transactionnelle ne lit ces tables, et les
  identités séparées limitent les effets chez les fournisseurs (§6).

### 5.8 Issues incertaines [H8]
Statut `incertain` ; délai HTTP explicite ; rapprochement tardif par la référence `communication:<id>`
(`biz_opaque_callback_data` pour WhatsApp ; en-tête `X-Mailin-custom` pour Brevo, **à confirmer**). Après
72 h sans preuve, l'envoi reste incertain (clos). **Jamais renvoyé seul.** Relance manuelle : administrateur,
motif de 10 caractères au moins, case « j'accepte le risque de doublon », nouvel envoi soumis à toutes les
règles, journal.

### 5.9 Indicatifs téléphoniques [H12]
Table des préfixes ; le territoire se lit par le préfixe le plus long. Haïti, République dominicaine
(1809, 1829, 1849), Porto Rico (1787, 1939), Jamaïque (1876, 1658) sont listés **non autorisés** ; tout
autre +1 reste « NANP_AUTRE » jusqu'au chargement de la liste officielle de NANPA (États-Unis, Canada,
autres territoires, en Phase 2). Un territoire ne s'ouvre qu'avec une **preuve** (confirmation écrite de
Meta) et un **tarif vérifié**.

### 5.10 Conservation et purge [C5]
Voir SECURITY §7 et DATABASE §5 :
- une durée par catégorie, **BLOQUÉE** tant que le juriste ne l'a pas fixée (pas de purge automatique
  sans durée) ;
- purge demandée par un administrateur (ou notée sur demande d'une personne), **approuvée par un autre
  administrateur**, exécutée par une fonction unique ;
- seule exception à l'immuabilité, et journal des purges sans les données effacées.

### 5.11 Mode démonstration (critères de développement de la Phase 2)
- `api.js` : une implémentation démo pour **chaque** méthode `API.admin.communications.*` et pour les
  fonctions de consentement de « Mon compte ». Données d'exemple en `localStorage`.
- **Aucun envoi** : les méthodes d'envoi répondent `MODE_DEMO`.
- Consentement simulé jusqu'à `en_attente`, avec une confirmation simulée par un bouton marqué « démo ».
- `PERMISSIONS_DES_ROLES` reçoit les 7 permissions ; `exiger(d, 'communications.…')` dans chaque méthode.
- Formes de réponse identiques à la base, comparées par `essai-communications.js` ; essai dans le
  navigateur avec `config.js` vide.

### 5.12 Quatre langues
- Textes de consentement, pied commercial, e-mail de confirmation, mots de confirmation et de STOP,
  pages de confirmation et de désinscription : **fr, en, es, ht**, tous ⚖️.
- Libellés du tableau de bord : `tableau.txt` + 3 traductions + `traduire.py`.
- Modèles WhatsApp : la langue créole chez Meta est **à confirmer** ; à défaut, le client haïtien reçoit
  le modèle de la langue de repli choisie dans la campagne, jamais un texte non approuvé.

### 5.13 Interface (Phase 4, rappel)
Onglet « Communications » du groupe « Gestion », `data-permission="communications.view"`, 11 vues du
cahier des charges. « Automatisations » montre les règles transactionnelles **existantes** (lecture ;
modification sous `settings.manage`, RPC inchangées) et, à part, les automatisations commerciales.
`admin.html` se modifie dans `outils/generateur/pages/`.

### 5.14 Surveillance
`sante_communications()` donne :
- les réglages et le disponible Brevo, séparé en **connu** et **estimé** ;
- les dépenses du jour et la file par statut ;
- les messages morts, les incertains, les envois bloqués et les erreurs sur 24 h ;
- **le signal C4** : les e-mails transactionnels refusés pour adresse bloquée ;
- l'état du travailleur.

La tâche porte le préfixe `goship-…`, donc `battement()` en signale les échecs. En Phase 2, des lignes
seront ajoutées à `controle-integrite.sql`, et les trois fonctions publiques à la liste blanche de
`controle-securite.sql`.

---

## 6. Identités d'envoi séparées [C4] — étude

### 6.1 E-mail

| Option | Isole la réputation de domaine | Isole les listes de blocage | Isole le quota | Coût | Statut |
|---|---|---|---|---|---|
| A. Même compte Brevo, même expéditeur | non | non | non | 0 | **écartée** |
| B. Même compte Brevo, **sous-domaine commercial** (ex. `news.goshipexpress.net`, à choisir) et expéditeur distinct | en partie (domaine) | **non vérifié** : la liste de blocage du transactionnel de Brevo semble tenue au niveau du compte | non | 0 | possible **si** Brevo confirme par écrit le comportement de ses listes |
| C. **Compte Brevo commercial séparé** + sous-domaine | oui | oui (comptes distincts) | oui | offre à choisir ; conditions de Brevo sur plusieurs comptes à vérifier | **recommandée** |
| D. Autre fournisseur pour le commercial (ex. Resend) + sous-domaine | oui | oui | oui | offre à choisir | possible |

**Décision provisoire de conception** : identité commerciale distincte (sous-domaine + expéditeur +
clés propres). Les brouillons n'ont **aucun repli** sur l'identité transactionnelle.

- `brevo_compte_partage = true` tant que l'option C ou D n'est pas en place : le quota partagé est alors
  protégé par la réserve.
- **Ni sous-domaine, ni DNS, ni compte, ni clé ne sont créés** avant l'autorisation écrite du CEO.
- **Ne pas affirmer** que deux expéditeurs du même compte sont indépendants tant que Brevo ne l'a pas
  confirmé.

### 6.2 WhatsApp

| | Coexistence sur le numéro actuel | **Numéro dédié au marketing** (recommandé à l'étude) |
|---|---|---|
| Numéro du service client | partagé avec le marketing | intact, aucun lien avec l'API commerciale |
| Note de qualité, blocages, signalements | **une campagne mal reçue pèse sur le numéro du service client** | limités au numéro commercial |
| Mise en place | par un partenaire agréé par Meta ; risque de manipulation du numéro existant | Cloud API directe possible ; pas de partenaire obligatoire (à confirmer) |
| Contraintes | ouvrir l'application environ toutes les deux semaines ; fonctions non synchronisées ; débit réduit | numéro à acquérir et à faire vérifier |
| Coût | frais du partenaire (devis) | numéro (devis) ; aucun frais de partenaire si direct |
| Conformité de la décision B | aucune migration, mais le numéro est relié à l'API | **le numéro actuel n'est pas touché du tout** |

**Décision provisoire de conception** : étudier en priorité un **numéro dédié**. Les brouillons n'utilisent
que `communication_whatsapp_numero_id`, `communication_whatsapp_jeton` et
`communication_whatsapp_waba_id`, **jamais** les réglages du numéro actuel. Aucune acquisition,
migration, activation ni configuration sans l'autorisation écrite du CEO.

---

## 7. Adresses (D-G, D-H) — inchangé, en attente

- **D-G** : il faut l'identité légale exacte et une adresse où GoShip reçoit réellement son courrier
  (rue, suite, ville, État, code postal), ou une boîte postale USPS, ou une boîte privée enregistrée. Il
  faut aussi savoir si l'entrepôt de Medley est un local de GoShip ou d'un prestataire (le format
  « ABX-46780 » évoque un compte chez un transitaire). Ces valeurs sont saisies par
  `valider_identite_expediteur`, avec la référence de la décision écrite du CEO.
- **D-H** : source qui fait foi aujourd'hui : `adresse_miami()` (« ABX-46780 », 786 525-2944). Le site
  affiche ailleurs « Apt 46780 » ; deux autres variantes existent (sans suite). Proposition : deux
  notions, une source chacune (réception des clients, adresse de l'entreprise). **Rien n'est changé.**

---

## 8. PR ouvertes (D-J) — examinées, non modifiées

| PR | Conflit | Recommandation |
|---|---|---|
| #46 pixel Meta | Mêmes fichiers que la future section « Communications commerciales » de la politique de confidentialité (`build.py`, `confidentialite.html` × 4) ; en retard sur `main` ; un lien de campagne avec `utm_*` chargera le pixel ; les pages de confirmation et de désinscription doivent **exclure** tout script de mesure [L3] | Décider #46 **avant** le travail sur la politique de confidentialité |
| #48 Centre de Commandement IA | Les deux ajoutent des migrations en fin de chaîne, modifient `permissions_du_role` (toutes ses copies) et introduisent la première fonction Edge ; l'agent « Service client » ne doit jamais recevoir de fonction `communications.*` qui envoie | Les ordonner l'un **après** l'autre ; une seule convention pour les fonctions Edge |

---

## 9. Retour arrière et reprise [M9]

| Situation | Action | Limites |
|---|---|---|
| Tout arrêter | `campagnes_actives = false` (journalisé) ; le travailleur lit encore les réponses, n'envoie rien | — |
| Un canal, une campagne | couper le canal ; pause ou annulation | — |
| Le travailleur | `cron.alter_job(<id>, active := false)` | — |
| Migration défaillante (Phase 2) | tout éteindre ; script de retrait `retrait-communications.sql`, **préparé et relu en Phase 2**, qui remet `permissions_du_role` dans sa définition **d'avant le fichier 40, recopiée littéralement dans le script** (jamais « relancer `supabase.sql` », qui contiendra alors les nouvelles permissions) et retire le déclencheur de `clients` | Les tables restent (preuves) ; aucune ligne de consentement n'est effacée hors purge approuvée |
| Après activation | les messages partis ne se rappellent pas ; les consentements et retraits recueillis **doivent** être gardés ; un retour arrière n'efface jamais une opposition | Les liens de désinscription des messages déjà envoyés doivent continuer de marcher (page + fonction gardées) |
| Restauration de la base | les tables sont dans la sauvegarde ; **les secrets du coffre ne le sont pas** : le poivre `communication_poivre` doit être ressaisi depuis sa **copie hors ligne** (sinon : échec fermé, aucun envoi, et les suppressions restent applicables par l'identifiant client) ; les clés des liens aussi (sinon les anciens liens renvoient vers « connectez-vous pour vous désinscrire ») | Procédure à ajouter à `docs/production/disaster-recovery.md` en Phase 2 |

---

## 10. Coûts (exigence 10) — aucune activation payante proposée

Aucun prix n'est écrit dans les brouillons : `communication_tarifs` naît **vide** et ne reçoit une
ligne qu'avec sa preuve (grille officielle, date). Indications relevées dans des sources **secondaires**
le 18/11/2026, **non vérifiées**, à confirmer sur les grilles officielles :

| Élément | Indication | Statut |
|---|---|---|
| Supabase | gratuit ; Pro 25 $/mois | pas d'achat (D-A) |
| Brevo | gratuit 300/jour ; Starter ≈ 9 $/mois ; compte séparé (option C) : offre à choisir | offre actuelle **non vérifiée** |
| WhatsApp marketing | ≈ 0,074 $ par message remis (Haïti, RD) ; États-Unis non livrés (pause rapportée) | grille officielle de Meta à lire |
| Numéro dédié ou partenaire Coexistence | devis | — |
| Juriste (USA/Floride, RD, Haïti) | devis | obligatoire avant le recueil |

Les plafonds global, par campagne et par numéro bornent toute dépense, quel que soit le scénario.

---

## 11. Informations extérieures et décisions en attente

| # | Point | Connu | Non vérifié | Preuve nécessaire | Responsable | Décision attendue du CEO |
|---|---|---|---|---|---|---|
| 1 | Adresse postale légale | aucune adresse confirmée pour l'envoi commercial | adresse où GoShip reçoit son courrier | décision écrite + justificatif (bail, USPS, CMRA) | CEO | adresse à afficher |
| 2 | Identité juridique | « Goship Express LLC » dans les données du site | nom exact enregistré | registre (Sunbiz) | CEO | nom exact |
| 3 | Adresse de Miami canonique | `adresse_miami()` = ABX-46780 ; site = Apt 46780 | identité des deux | confirmation du prestataire de l'entrepôt | CEO | variante officielle |
| 4 | Offre et quota Brevo | 300/jour pour l'offre gratuite (sources secondaires) | offre réelle du compte | capture Brevo > Mon offre, datée | CEO / admin | saisie par `verifier_quota_brevo` |
| 5 | SMTP de Supabase Auth | Brevo configuré le 28/09 (go-no-go) | réglage actuel | capture Supabase > Auth > SMTP | CEO / admin | confirmation |
| 6 | Listes de blocage Brevo entre expéditeurs | une liste du transactionnel existe (rapporté) | portée (compte ou expéditeur) | réponse écrite de Brevo ou doc officielle | admin | option C, B ou D |
| 7 | Restrictions WhatsApp US / RD | pause marketing US rapportée depuis le 01/04/2025 | portée sur les +1 non américains | confirmation écrite de Meta | partenaire / Meta | territoires à ouvrir |
| 8 | Tarifs officiels | estimations secondaires | grille officielle | grille Meta et Brevo datée | admin | saisie par `verifier_tarif_communication` |
| 9 | Langues de modèles Meta (créole) | fr, en, es acceptées (connu) | créole haïtien | liste officielle de Meta | admin | langue de repli pour les clients haïtiens |
| 10 | Coexistence du numéro actuel | conditions générales publiques | éligibilité de CE numéro | partenaire agréé | CEO | étudier ou écarter |
| 11 | Numéro dédié | possible en Cloud API (connu) | éligibilité, coût | devis, vérification Meta | CEO | acquérir ou non |
| 12 | Limite quotidienne et note de qualité | attribuées par Meta | valeurs du numéro commercial | gestionnaire WhatsApp de Meta | admin | saisie par `regler_whatsapp_commercial` |
| 13 | Textes de consentement et désinscription | brouillons en 4 langues | conformité | avis écrit du juriste | juriste | attestation |
| 14 | Durées de conservation et d'effacement | propositions (SECURITY §7) | durées légales par juridiction | avis écrit du juriste | juriste | saisie par `regler_conservation_communication` |
| 15 | Ordre des PR #46 et #48 | conflits identifiés | — | — | CEO | ordre |

Autres décisions du CEO : quatre yeux sur les campagnes (par défaut : non, journalisé) ; approbation des
modèles réservée à l'administrateur (conception : oui) ; pas d'e-mail ni de téléphone en variable ;
option e-mail C/B/D ; numéro dédié.

---

## 12. Feuille de route (chaque étape exige l'autorisation écrite du CEO)

| Phase | Contenu | Condition de sortie |
|---|---|---|
| 1.2 (celle-ci) | corrections de conception | votre décision sur le rapport 1.2 |
| 2a | 40, 41 sur base jetable ; toutes les copies des permissions ; mode démo ; bancs | tous les groupes de TESTING concernés verts ; aucun changement du transactionnel |
| 2b | 42, 43 ; travailleur avec fournisseurs simulés | groupes 7 à 14 verts |
| 2c | pages Mon compte, confirmation, désinscription (4 langues) ; politique de confidentialité (après #46) | textes attestés par le juriste |
| Prod-A | 40–43 en production, sauvegarde vérifiée, **tout éteint** | GO écrit |
| 3 | fonction Edge ; Brevo bac à sable ; numéro d'essai Meta ; lecture des modèles confirmée | essais réels vers la liste d'essai seulement, sur autorisation |
| 4–7 | interface, automatisations commerciales, statistiques, qualité, activation par étapes | GO à chaque étape |
