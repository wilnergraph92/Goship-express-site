# GoShip Express — Centre de communication
# COMMUNICATION_CENTER_SECURITY.md — version Phase 1.2

| | |
|---|---|
| Date | 18 novembre 2026 |
| Version | **Phase 1.2** — corrige la version Phase 1 après la revue Phase 1.1 |
| Statut | **Conception à approuver.** Aucune modification de la production, aucun secret changé, aucun fournisseur activé |
| Avertissement | Ce document **n'est pas un avis juridique**. Tout ce qui est marqué ⚖️ exige l'approbation écrite d'un juriste avant toute activation |

---

## 1. Objectifs de sécurité

1. Aucun message commercial sans consentement **personnel, confirmé par le contact lui-même et
   prouvé**, canal par canal [C2].
2. Un retrait gagne toujours, tout de suite, par tous ses chemins, quel que soit son âge [C6, H6].
3. Aucun message sans l'approbation de l'administrateur sur son **contenu réel** (y compris celui tenu
   par Meta), son environnement, son volume et ses plafonds [C3, H9, H13].
4. Aucune dépense au-delà des plafonds ; e-mails de connexion et transactionnels jamais privés de
   quota [H1, H2, H3].
5. En développement et en mode essai, personne hors de la liste d'essai ne reçoit rien.
6. Le transactionnel, ses données et les contrats de l'application mobile ne changent pas, et une
   opposition commerciale ne peut pas les interrompre, **ni dans la base ni chez les fournisseurs**
   (identités séparées) [C4].
7. Aucun secret dans le dépôt, le site, l'application ou le code de la fonction Edge ; aucune clé
   capable de contourner la sécurité de la base hors de la base.
8. Chaque action de l'équipe est attribuée, motivée et journalisée ; les preuves sont immuables, sauf
   la purge approuvée par deux administrateurs [C5].

---

## 2. Matrice des permissions (exigence 8)

### 2.1 Permissions

| Permission | Admin | Gérant | Employé | Client |
|---|---|---|---|---|
| `communications.view` | ✓ | ✓ | – | – |
| `communications.create` | ✓ | ✓ | – | – |
| `communications.test` | ✓ | ✓ | – | – |
| `communications.pause` | ✓ | ✓ | – | – |
| `communications.approve` | ✓ | **–** | – | – |
| `communications.manage` | ✓ | **–** | – | – |
| `communications.consents` | ✓ | ✓ | – | – |
| Son propre consentement (aucune permission : `auth.uid()`, rôle `client`) | – | – | – | ✓ |

- Double authentification : ce sont des permissions de l'équipe, donc `session_double_auth_ok()`
  s'applique d'elle-même.
- Aucune autre permission existante ne change. **L'employé n'a aucun accès au Centre.**
- **Copies à synchroniser** [H10] : `supabase.sql` (fait foi), `supabase-naissance.sql`,
  `supabase-suivi-externe.sql`, brouillon 40, et `PERMISSIONS_DES_ROLES` dans `api.js`.
- Contrôles : `essai-programmes.py`, `essai-suivi-externe.py`, `essai-permissions.py/.js`, plus un
  nouvel essai qui compare les cinq copies (TESTING groupe 3).

### 2.2 Action par action

| Action | Fonction (brouillon) | Exige | Admin | Gérant |
|---|---|---|---|---|
| Voir le Centre, l'historique, les statistiques, les dépenses, la santé | `sante_communications` (43) | view | ✓ | ✓ |
| Aperçu d'audience (**nombres seulement**) | `apercu_audience_communication` (42) | view | ✓ | ✓ |
| Écrire un brouillon de campagne | `ecrire_campagne_communication` (42) | create | ✓ | ✓ |
| Écrire un modèle, un segment (Phase 2, même forme) | `ecrire_modele_…`, `ecrire_segment_…` | create | ✓ | ✓ |
| Soumettre, retirer, remettre en brouillon, annuler un brouillon | `changer_statut_campagne` (42) | create | ✓ | ✓ |
| Programmer (date dans le brouillon) | `ecrire_campagne_communication` | create | ✓ | ✓ |
| Mettre en pause | `changer_statut_campagne('mettre_en_pause')` | pause | ✓ | ✓ |
| Essai vers la liste d'essai | Phase 2 | test | ✓ | ✓ |
| **Approuver ou refuser une campagne** (= autoriser l'envoi) | `changer_statut_campagne('approuver'/'refuser')` | approve | ✓ | – |
| **Approuver un modèle** (après relecture chez Meta) | Phase 2 | approve | ✓ | – |
| **Reprendre**, **annuler** une campagne approuvée | `changer_statut_campagne` | approve | ✓ | – |
| **Relancer** un message incertain ou mort | `relancer_envoi_communication` (43) | approve | ✓ | – |
| **Approuver une purge** (jamais la sienne) | `approuver_purge_communication` (41) | approve | ✓ | – |
| Réglages ordinaires (interrupteurs, plafonds, heures, fréquence, seuils) | `regler_communications` (41) | manage | ✓ | – |
| Quota Brevo avec preuve | `verifier_quota_brevo` (41) | manage | ✓ | – |
| Numéro WhatsApp commercial et limite de Meta, avec preuve | `regler_whatsapp_commercial` (41) | manage | ✓ | – |
| Identité légale et adresse postale (après décision écrite du CEO) | `valider_identite_expediteur` (41) | manage | ✓ | – |
| Tarifs et territoires, avec preuve | `verifier_tarif_communication`, `verifier_indicatif_communication` (41) | manage | ✓ | – |
| Liste d'essai | `regler_destinataire_essai` (41) | manage | ✓ | – |
| Textes de consentement (écrire, attester avec la référence du juriste) | `ecrire_/attester_texte_consentement` (41) | manage | ✓ | – |
| Lever une suppression (ne rend jamais le consentement) | `lever_suppression_communication` (41) | manage | ✓ | – |
| Durées de conservation (référence du juriste) | `regler_conservation_communication` (41) | manage | ✓ | – |
| Demander une purge à l'échéance ; exécuter une purge approuvée | `demander_purge_…`, `executer_purge_communication` (40, 41) | manage | ✓ | – |
| Lire l'historique de consentement d'un client | `consentements_client` (41) | consents | ✓ | ✓ |
| Noter un **retrait** demandé par le client | `retirer_consentement_client` (41) | consents | ✓ | ✓ |
| Ajouter une suppression manuelle | `ajouter_suppression_communication` (41) | consents | ✓ | ✓ |
| Noter une demande d'effacement d'une personne | `demander_purge_communication('personne')` (41) | consents | ✓ | ✓ |
| **Demander, confirmer ou accorder un consentement à la place d'un client** | — | **personne** (contraintes de la table) | – | – |
| Client : voir, demander, retirer SON consentement | `mes_consentements_…`, `demander_…`, `retirer_mon_…` (41) | soi-même | – | – |
| Visiteur : confirmer par le lien ; se désinscrire par le lien | `confirmer_consentement_communication`, `desinscrire_communication` | jeton | – | – |
| Retours des fournisseurs | `communication_recevoir_evenement` (43) | signature | – | – |

Chaque fonction vérifie la permission **dans la base** ; `data-permission` dans `admin.html` ne fait que
masquer. Les tables ont la sécurité par ligne activée, **aucune règle et aucun droit direct**.

---

## 3. Menaces et parades

| # | Menace | Parade |
|---|---|---|
| T1 | Écrire à quelqu'un qui n'a pas consenti | Consentement **confirmé par le contact**, lié à son empreinte, vérifié au gel et avant chaque envoi |
| T2 | Faire consentir le contact d'un tiers (« mauvais numéro ») | Lien envoyé à l'adresse, ou message venu du numéro ; contact masqué montré ; l'équipe ne peut rien activer [C2] |
| T3 | Écrire après un retrait | Verrou client+canal ; le retrait gagne à égalité ; revérification avant envoi [H6] |
| T4 | Contenu modifié après approbation, y compris chez Meta | Empreinte complète + image Meta relue au lancement et à chaque lot [C3, H9] |
| T5 | Dépense qui s'emballe | Verrou du jour, plafonds global, campagne et numéro, tarifs prouvés, volume approuvé [H1, H11, H13] |
| T6 | E-mails de connexion bloqués | Quota prouvé, réserve, transactionnel connu et en attente comptés, fenêtres glissantes, ou compte commercial séparé [H2, H3, C4] |
| T7 | Avis de colis bloqués par une plainte commerciale | **Identités d'envoi séparées** ; aucun repli ; signal « transactionnel bloqué » dans la santé [C4] |
| T8 | Vrais messages pendant les essais | Mode essai, liste d'essai vérifiée deux fois, bacs à sable, interrupteurs coupés, tâche inactive |
| T9 | Faux retour de fournisseur, fausse désinscription | Signature à chaque étage, rejeu refusé, futur refusé, jeton HMAC (§6) |
| T10 | Doublons | Clés uniques, pas de renvoi d'un incertain, relance manuelle avec risque coché [H8] |
| T11 | Élévation de privilège | Permission dans chaque fonction, aucun accès direct aux tables, employé sans accès, double authentification |
| T12 | Injection dans un message | Texte brut échappé par la base ; liste fermée de variables ; accolades et barres retirées des valeurs ; paramètres WhatsApp contrôlés [M2] |
| T13 | Fuite de données personnelles | Aperçus en nombres ; codes au lieu des textes des fournisseurs ; contenu des messages reçus jamais gardé ; empreintes poivrées [M11] |
| T14 | Perte d'une opposition | Aucune limite d'âge ; idempotence ; échec fermé si l'empreinte est indisponible [C6] |
| T15 | Saturation des fonctions publiques | Contrôles bon marché avant le coffre ; journalisation des refus ; limites à la fonction Edge (§6.6) [M6] |
| T16 | Agents IA (PR #48) qui enverraient du marketing | Aucune fonction `communications.*` d'envoi dans leurs outils |

---

## 4. Secrets et réglages du coffre

| Secret | Où | Qui lit | Statut |
|---|---|---|---|
| `email_*`, `whatsapp_*` actuels | coffre | **transactionnel seulement** | inchangés ; le commercial ne les lit jamais |
| `communication_email_cle_api`, `communication_email_fournisseur`, `communication_expediteur`, `communication_nom` | coffre | fonctions commerciales | nouveaux, BLOQUÉS jusqu'à la décision C4 |
| `communication_whatsapp_jeton`, `communication_whatsapp_numero_id`, `communication_whatsapp_waba_id` | coffre | fonctions commerciales | nouveaux, BLOQUÉS jusqu'à la décision C4 |
| `communication_poivre` (empreintes) | coffre **et copie hors ligne** chez le propriétaire | fonctions SQL | nouveau ; **ne change jamais** ; absent = échec fermé [M11] |
| `communication_cle_desinscription` (liens de désinscription) | coffre | fonctions SQL | nouveau ; absent = aucun e-mail commercial [M8] |
| `communication_cle_webhook` (fonction Edge ↔ base) | coffre **et** secrets de la fonction Edge | fonction Edge, SQL | nouveau ; absent = tout retour refusé |
| `META_APP_SECRET`, `META_VERIFY_TOKEN`, `BREVO_WEBHOOK_TOKEN` | secrets de la fonction Edge | fonction Edge | nouveaux (Phase 3) |
| `communication_url_un_clic` (adresse publique, pas un secret) | coffre | SQL | nouveau |
| Clé `service_role` de Supabase | tableau de bord seulement | **personne** | reste « utilisée nulle part » |

Tous seront posés par le propriétaire, jamais dans une conversation ni dans le dépôt ;
`docs/production/secrets.md` sera mis à jour en Phase 2.

**Poivre** : sans lui, une empreinte ne se devine pas à partir d'une liste d'adresses courantes. S'il est
perdu à une restauration sans sa copie hors ligne, aucun consentement n'est reconnu et aucun envoi ne
part (échec fermé) ; les suppressions restent liées aux comptes par leur identifiant.

---

## 5. ⚖️ Exigences juridiques et consentement (D-F)

### 5.1 États-Unis (fédéral et Floride)

| Règle | Exigence relevée | Conception |
|---|---|---|
| CAN-SPAM (e-mail commercial) | Expéditeur exact, objet honnête, **adresse postale valide**, désinscription honorée sous 10 jours ouvrés, lien valable au moins 30 jours ; mention « publicité » si exigée ⚖️ | Habillage commercial avec lien cliquable, identité et adresse (BLOQUÉES jusqu'à D-G) ; suppression immédiate ; lien sans expiration |
| TCPA | Consentement écrit exprès pour le marketing par message vers un mobile ; application à WhatsApp incertaine ⚖️ | Case + texte attesté + confirmation par le contact + date |
| Loi de Floride (FTSA, amendement 2023) | Une case cochée ou une réponse affirmative suffit ; STOP à respecter ; application aux messageries incertaine ⚖️ ; heures ⚖️ | Confirmation par message du numéro ; STOP immédiat ; heures et fréquence limitées |
| Pause de Meta sur le marketing vers les numéros américains | Rapportée depuis le 01/04/2025 (sources secondaires) | Territoire US non autorisé par défaut |
| Règles des grandes messageries (Gmail, Yahoo) | Désinscription en un clic, DMARC ; seuils d'obligation rapportés, non vérifiés | `List-Unsubscribe`, un clic par la fonction Edge |

### 5.2 République dominicaine

| Règle | Exigence relevée | Conception |
|---|---|---|
| Loi 172-13 | Consentement libre, sans ambiguïté, précis et éclairé, gardé par écrit ; droit gratuit de refuser la publicité ; accès, rectification, suppression | Consentement par canal, contact montré, texte gardé ; retrait gratuit ; effacement par la purge « personne » |
| Loi 310-14 (non vérifiée sur le texte officiel ⚖️) | Consentement préalable, identification de l'expéditeur, désinscription sous 2 jours ouvrés (rapporté) | Suppression immédiate ; expéditeur identifié |
| Bonne pratique locale | Case **non cochée** par défaut, finalité dite, lien vers la politique de confidentialité | Prévu dans l'interface |

### 5.3 Haïti
Aucune loi générale de protection des données n'a pu être confirmée en vigueur fin 2026 ; les
dispositions du Code pénal de 2025 sont d'application incertaine ⚖️. **La règle la plus stricte des
trois marchés s'applique aussi aux clients haïtiens.**

### 5.4 Textes à faire approuver par le juriste avant toute activation ⚖️
1. Textes de consentement, par canal, en 4 langues.
2. Section « Communications commerciales » de la politique de confidentialité (4 langues) : finalité,
   canaux, retrait, conservation, fournisseurs (Brevo, Meta), transfert vers des prestataires américains.
3. Pied commercial (`communication_textes_pied`) et e-mail de confirmation
   (`communication_textes_confirmation`), 4 langues.
4. Pages de confirmation et de désinscription, 4 langues.
5. Mots de confirmation (OUI, YES, SÍ, WI) et de STOP, et une éventuelle réponse automatique.
6. Heures permises et fréquence.
7. Identité de l'expéditeur et adresse postale.
8. Mention « publicité », si exigée.
9. Règle : une nouvelle inscription confirmée lève les désinscriptions et STOP antérieurs du même contact.
10. Durées de conservation (§7).

---

## 6. Retours des fournisseurs et fonction Edge [B, C6, M6]

### 6.1 Le parcours complet
1. **Meta → fonction Edge.**
   - Vérification de l'abonnement : `GET` avec `hub.verify_token` (comparé à `META_VERIFY_TOKEN`).
   - Chaque événement : `POST`. La signature `X-Hub-Signature-256` (HMAC-SHA-256 avec `META_APP_SECRET`)
     est vérifiée **sur le corps brut, avant toute lecture du JSON** ; une signature fausse est refusée
     et journalisée.
2. **Brevo → fonction Edge.**
   - **Ce qui est disponible** : rien de signé (Brevo ne signe pas ses envois, rapporté).
   - **Ce qui est seulement envisagé, à confirmer** : un jeton secret dans l'adresse ou une
     authentification simple, et un filtrage sur les plages d'adresses IP publiées par Brevo.
   - Protection plus faible, documentée comme telle. Conséquence : un faux retour Brevo ne peut au pire
     que bloquer un contact ou marquer un message, jamais accorder un consentement (§6.4).
3. **Fonction Edge → PostgreSQL.**
   - Elle met chaque événement sous une forme texte stable, la signe par HMAC (`communication_cle_webhook`)
     et appelle `communication_recevoir_evenement(fournisseur, texte_brut, signature)` avec la **clé
     publique**.
   - **La clé publique de Supabase n'authentifie rien** : elle désigne le projet, et n'importe qui la
     trouve dans `config.js`. La **seule porte est la signature**, vérifiée dans la base sur le texte brut.
4. **Dans la base.**
   - Contrôles bon marché d'abord (fournisseur connu, taille ≤ 20 000, forme de la signature), puis
     lecture du coffre.
   - Clé absente : tout est refusé. Signature fausse : refus, avec `raise log` dans les journaux de
     Supabase (détection d'abus).

### 6.2 Rejeu, horodatage, identifiants
- Identifiant unique par événement :
  - statuts Meta : `meta:<message>:<statut>:<horodatage>` (Meta n'en fournit pas) ;
  - messages entrants : `meta:in:<id>` ;
  - Brevo : `brevo:<message-id>:<événement>:<horodatage>` (forme réelle à confirmer).
- Paire (fournisseur, identifiant) unique : un rejeu ne change rien.
- **Aucune limite d'âge** : un STOP reçu cinq jours plus tard s'applique.
- Seuls les événements datés de **plus de 5 minutes dans le futur** sont refusés.
- Les statuts ne reculent jamais.

### 6.3 Clé partagée absente ou compromise
- **Absente** : tous les retours sont refusés. Meta et Brevo réessaient leurs envois ; les oppositions
  arrivées entre-temps sont appliquées au rétablissement, puisque l'âge n'est pas limité.
- **Compromise** : changer la clé dans le coffre **et** dans les secrets de la fonction Edge.
- **Conséquences possibles d'une fuite** : faux statuts, fausses suppressions, faux retraits, ou une
  confirmation WhatsApp forgée **seulement** pour une demande en attente dont l'attaquant connaîtrait à
  la fois le numéro et le code. **Jamais** de consentement créé de toutes pièces, jamais d'accès à des
  données clients, aucune élévation de privilège.

### 6.4 Fonctions qui contournent la sécurité par ligne, et pourquoi
Toutes les fonctions du Centre sont `security definer` avec `search_path` vide. Elles lisent et écrivent
des tables fermées : c'est voulu, la règle est **dans** la fonction.

| Fonction | Opérations permises | Justification |
|---|---|---|
| `communication_recevoir_evenement` (visiteur, signature) | statuts d'envoi (sans recul), suppressions, **retraits**, confirmation d'une demande en attente venue du bon numéro, fenêtre 24 h | Seul chemin des retours des fournisseurs |
| `desinscrire_communication` (visiteur, jeton HMAC) | une suppression du contact visé, un retrait si le consentement actif porte sur ce contact | Lien de désinscription |
| `confirmer_consentement_communication` (visiteur, jeton aléatoire) | confirmation d'UNE demande en attente | Lien de confirmation |
| Fonctions du client (`mes_…`, `demander_…`, `retirer_mon_…`) | ses propres lignes seulement (`auth.uid()`) | Espace client |
| Fonctions de l'équipe | chacune sous sa permission, avec motif et journal | Tableau de bord |
| `traiter_communications`, travailleur | file, réservations, appels | Tâche planifiée, ouverte à personne |
| `executer_purge_communication` et suite | effacements et anonymisations **d'une purge approuvée par un autre administrateur** | Seule exception à l'immuabilité |

### 6.5 Fonctions publiques (ouvertes sans compte)
Trois : `communication_recevoir_evenement`, `desinscrire_communication`,
`confirmer_consentement_communication`. Elles seront ajoutées à la liste blanche de
`controle-securite.sql` (section 6). Chacune vérifie d'abord la forme de son entrée, puis sa signature
ou son jeton ; aucune ne renvoie de donnée personnelle.

### 6.6 Limitation de débit et saturation [M6]
- La base n'offre pas de limite de débit par fonction. Une limite dans la fonction Edge **ne protège pas**
  un appel direct à la fonction publique.
- **Risque résiduel accepté** : la falsification est impossible à calculer, le risque est la charge.
- Parades : contrôles bon marché avant le coffre, refus journalisés (détection dans les journaux de
  Supabase), surveillance du volume de refus en Phase 6. Si un abus est observé, on fermera la fonction
  au visiteur et on fera appeler la fonction Edge seule, avec une autre méthode d'authentification à
  concevoir. **Ce changement n'est pas fait d'avance.**

---

## 7. Conservation, anonymisation, effacement [C5]

### 7.1 Politique proposée au juriste (aucune durée appliquée d'office)

| Catégorie | Contenu identifiant | Proposition à examiner | Après l'échéance |
|---|---|---|---|
| Consentements | client, contexte, auteur | vie du compte + délai de prescription applicable ⚖️ (4 ans souvent cités pour la TCPA, **à confirmer** pour la TCPA, la FTSA et la Loi 172-13) | anonymiser (garder action, date, version du texte, empreinte) |
| Confirmations | jeton (empreinte), code | 30 jours après usage ou expiration | effacer |
| Campagnes | description | durée comptable et commerciale ⚖️ | anonymiser |
| Audiences figées | client, empreinte | 24 mois ⚖️ | effacer |
| Envois | client, identifiant chez le fournisseur | 24 mois ⚖️ | anonymiser (garder statistiques) |
| Retours des fournisseurs | identifiants | 90 jours ⚖️ | effacer |
| Fenêtres WhatsApp | empreinte | 7 jours | effacer |
| Suppressions | client | **l'empreinte est gardée tant qu'elle sert à ne plus écrire** ⚖️ ; le lien au client s'efface | anonymiser |
| Erreurs du Centre | aucun | 90 jours | effacer |

### 7.2 Qui demande, approuve, exécute
- **Demande à l'échéance** : un administrateur (`communications.manage`).
- **Demande d'effacement d'une personne** : notée par un administrateur ou un gérant
  (`communications.consents`) à la demande du client.
- **Approbation** : un **autre** administrateur (`communications.approve`) — quatre yeux toujours.
- **Exécution** : `executer_purge_communication`, refusée sans approbation et sans durée fixée par le
  juriste.
- **Preuve** : `communication_journal_purges` (immuable) garde qui, quand, quelle table, quelle opération
  et combien de lignes, **jamais les données**.
- **Exception à l'immuabilité** : seulement dans la transaction d'une purge approuvée (réglage
  `goship.purge_demande`, vérifié par le déclencheur). Le propriétaire de la base, dans le SQL Editor,
  peut contourner tout déclencheur : limite assumée et documentée.

---

## 8. Registre des risques (mis à jour)

| # | Risque | Prob. | Impact | Parade | Responsable |
|---|---|---|---|---|---|
| R1 | Plainte réglementaire (consentement) | faible | élevé | confirmation par le contact, textes attestés, preuves | CEO, juriste |
| R2 | WhatsApp marketing inaccessible pour une partie des clients | élevée | moyen (valeur) | territoires bloqués par défaut ; e-mail privilégié | CEO |
| R3 | Le marketing nuit au numéro du service client | moyenne si Coexistence | élevé | numéro dédié recommandé à l'étude | CEO |
| R4 | Plainte commerciale qui bloque les avis de colis chez Brevo | moyenne si même compte | élevé | compte ou fournisseur commercial séparé ; signal dans la santé | CEO, admin |
| R5 | Quota Brevo épuisé | faible | élevé | quota prouvé, réserve, fenêtres glissantes | admin |
| R6 | Dépense excessive | faible | moyen | verrou du jour, plafonds, tarifs prouvés | admin |
| R7 | Régression du transactionnel | faible | élevé | aucune modification ; bancs de non-régression | développement |
| R8 | Doublons | faible | moyen | clés uniques, incertains jamais renvoyés seuls | développement |
| R9 | Faux retours | faible | moyen | signatures, rejeu, futur refusé | développement |
| R10 | Perte du poivre ou des clés à une restauration | faible | moyen | copie hors ligne ; échec fermé | propriétaire |
| R11 | Lecture des modèles Meta non confirmée | moyenne | moyen | aucun modèle WhatsApp approuvable sans elle | Phase 3 |
| R12 | Pas de vraie préproduction | moyenne | moyen | base jetable + bacs à sable ; réévaluation avant Phase 7 | CEO |
| R13 | Brouillons non exécutés, donc non éprouvés | certaine (règle de phase) | faible | première tâche de la Phase 2 | développement |
| R14 | Conflits avec PR #46 et #48 | moyenne | faible | ordre décidé avant la Phase 2 | CEO |
| R15 | Adresses incohérentes | moyenne | moyen | identité, adresse et variable BLOQUÉES | CEO |

## 9. Vérification
Le plan complet (16 groupes, préconditions, données, scénarios, résultats attendus, conditions d'échec,
preuves) est dans `COMMUNICATION_CENTER_TESTING.md`. **Aucun de ces essais n'a été exécuté.**
