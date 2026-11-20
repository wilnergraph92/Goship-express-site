# GoShip Express — Centre de communication
# CLÔTURE DE L'AUDIT DE LA PHASE 1.3.1 — Vérification finale indépendante

| | |
|---|---|
| Date | 20 novembre 2026 |
| Code examiné | commit `0693d5e` (brouillons SQL 40 à 43, version 1.3.1). `git diff 0693d5e HEAD -- docs/communication-center/brouillons-sql/` est vide : les brouillons n'ont pas changé depuis. |
| Branche | `ccr-056ddc8c-m7u4p1`, PR #65 (brouillon, **non fusionnée**) |
| Mode | Lecture du code, analyse statique sans serveur (`pglast`), revue indépendante. Seule exception, autorisée par écrit par la direction le 20/11/2026 (« Oui, SELECT agrégés ») : **des comptages agrégés en lecture seule sur la production** (§8), sans écriture et sans donnée personnelle. |
| Phase 2 | **Non autorisée** par cette mission |
| Verdict | voir §11 |

**Documents de la clôture** :
- le présent audit ;
- `PHASE_1_3_1_KILL_SWITCH_LOCK_PROOF.md` : les verrous de l'arrêt d'urgence, fonction par fonction, et la preuve ;
- `PHASE_1_3_1_SQL_40_43_SECURITY_REVIEW.md` : la revue des migrations 40 à 43 ;
- `PHASE_1_3_1_FINAL_TEST_PLAN.md` : 20 essais, **tous non exécutés**.

---

## 1. Ce qui a été fait, et ce qui ne l'a pas été

| Fait | Pas fait |
|---|---|
| Lecture complète des migrations 40 à 43 (commit `0693d5e`) et des huit fonctions demandées | Aucune migration exécutée, nulle part |
| Inventaire automatique des objets, droits, `SECURITY DEFINER`, `search_path` (`pglast`) | Aucun SQL sur une base jetable |
| Preuve écrite des verrous de l'arrêt | Aucun essai exécuté |
| Revue indépendante finale par une session distincte, sans les conclusions de l'auteur (§6) | Aucune connexion à Brevo ni à Meta ; aucun secret créé ni lu |
| 5 comptages agrégés en lecture seule sur la production (§8), autorisés par écrit | Aucune écriture en production ; aucune donnée personnelle lue ou affichée |
| Corrections **documentaires** dans le dossier (§9.1) | Aucune correction appliquée aux brouillons SQL (§9.2 : propositions) |
| | Aucun déploiement ; PR #65 non fusionnée ; PR #46 et #48 non touchées |

---

## 2. La question posée : l'arrêt d'urgence et ses verrous

Détail complet : `PHASE_1_3_1_KILL_SWITCH_LOCK_PROOF.md`.

1. **La documentation était inexacte.** `communication_conclure_arret()` (41 l. 903) appelle `communication_observer_sorties()` (43 l. 1881). Cette fonction modifie des lignes de `communication_envois` et de `communication_modeles_meta` **après** N0 et N0a. Deux textes disaient le contraire :
   - `PHASE_1_3_1_KILL_SWITCH_DESIGN.md` l. 85 ;
   - le commentaire de 41 l. 899.

   **Le premier est corrigé** (correction documentaire, §9.1). **Le second est dans un brouillon SQL** : sa correction est proposée, pas appliquée (P-02).
2. **Il n'y a pas d'interblocage**, parce que ces deux verrouillages sont faits en `FOR UPDATE SKIP LOCKED` (43 l. 1891, 1898). Après N0a, la transaction d'arrêt ne fait plus que :
   - des lectures ;
   - des écritures sur sa propre ligne ;
   - une insertion dans `journal_audit`.

   Elle n'attend donc jamais. **Cette conclusion dépend de deux comportements de PostgreSQL non éprouvés** : H1 et H5 (essai F-K03).
3. **`STOP_CONFIRMED` exige N0 exclusif obtenu après la demande, et zéro transmission en cours.** C'est écrit dans le code (41 l. 924-952) et dans une contrainte de la table. La garantie « plus rien ne part après la confirmation » dépend de quatre comportements de pg_net 0.20.4 **non éprouvés** (H4, essais F-K05 et F-K06).
4. **Un effet de bord, borné :** pendant l'arrêt, le webhook, la purge et l'annulation peuvent attendre une ligne que l'arrêt a verrouillée, jusqu'à la fin de l'arrêt (au plus quelques secondes). Il n'y a pas de cycle.

---

## 3. Audit des migrations 40 à 43

Détail : `PHASE_1_3_1_SQL_40_43_SECURITY_REVIEW.md`.

| Point | Résultat |
|---|---|
| Inventaire | 28 tables, 105 fonctions (dont 1 procédure), 25 index, 7 déclencheurs |
| RLS | 28 / 28 activées, 0 règle : aucun accès direct |
| Droits | `revoke all` sur les 28 tables pour `anon`, `authenticated` et `service_role`. 2 fonctions ouvertes aux visiteurs, protégées par un jeton. 34 ouvertes aux comptes connectés, chacune avec son propre contrôle. |
| `search_path` | 104 / 105 fixés à `''`. L'exception est la procédure, qui vide le sien elle-même. |
| Employé | Aucune permission `communications.*` |
| Garde | Quatre couches, vérifiées par analyse ; limite connue IR2-08 (LOW, acceptée) |
| Objets existants touchés | `permissions_du_role` (remplacée), un déclencheur `after update` sur `clients`, le rôle global `communication_webhook`, une tâche pg_cron **inactive** |
| Exigence pour la Phase 2 | Appliquer 40 → 43 **dans une seule transaction** (F-M02) |

---

## 4. Séparation marketing / transactionnel

**Vérifiée dans le code** (revue SQL, §3) :
- **clés** : le Centre ne lit que des clés `communication_*`, plus `site_url` et `whatsapp_version` ;
- **aucun repli** sur l'expéditeur transactionnel ;
- **aucune écriture** dans `notifications`, `notification_envois`, `notification_regles` ni `messages_recents` ;
- **rien n'est redéfini** : ni `expedier_envoi`, ni `courriel_gabarit`, ni `traiter_notifications` ;
- **aucun déclencheur** sur `colis_historique` ni sur `evenements_facturation`.

**Les e-mails de facture restent coupés** : 40 à 43 ne font aucune référence à `notification_regles` ni aux règles de facture.

**Non éprouvé** : la non-régression réelle (essais F-T01, F-T02).

---

## 5. Les corrections des Phases 1.3 et 1.3.1, réexaminées

**Légende** :
- **Corrigé** : présent dans le code de `0693d5e`, à la ligne citée, et conforme à la description ;
- **Partiel** : une partie reste à faire, ou dépend d'une hypothèse ;
- **Non corrigé** : accepté ou différé ;
- **Non vérifiable** : hors du code, ou seulement par un essai.

**Aucun « corrigé » ne veut dire « éprouvé ».**

### 5.1 Les huit corrections de la Phase 1.3

| # | Correction | État | Preuve / réserve |
|---|---|---|---|
| 1 | Arrêt d'urgence | **Partiel** | Refait en 1.3.1 : porte unique (40 l. 379), N0 exclusif, `STOP_PENDING` sans repli (41 l. 960-1016). Garanties H1 à H5 non éprouvées ; documentation des verrous inexacte, corrigée (S-01). |
| 2 | Ordre des verrous | **Corrigé** (code) | N0 → N0a → N1 … N5 respecté dans les fonctions lues ; SKIP LOCKED à l'observation. Interblocages non éprouvés (F-K04). |
| 3 | Quota Brevo et débit global | **Corrigé** (code) | `communication_reserver` N5 (43 l. 253), READ COMMITTED vérifié. Non éprouvé (T-03B). |
| 4 | Réponses 5xx et 429 | **Corrigé** (code) | Incertain sans renvoi automatique ; relance avec risque de doublon accepté explicitement (43 l. 1671-1691). Non éprouvé (T-04B). |
| 5 | Données personnelles | **Partiel** | Centre : empreintes HMAC, purges. **Hors du Centre** : corps des requêtes pg_net (environ 6 h, rapporté), motifs dans `journal_audit`, fournisseurs. Décision du juriste attendue. |
| 6 | Fuseaux horaires | **Corrigé** (code) | `FUSEAU_INCONNU` plutôt qu'un fuseau deviné (40 l. 890-915, 42 l. 550). Prudent : **aujourd'hui, 15 clients sur 71 seraient exclus pour cette seule raison** (§8). |
| 7 | Webhooks et horodatage | **Partiel** | Rejeu refusé (43 l. 1261), STOP gardé (IR-08, IR2-06). **Non vérifiable** : authentification de la fonction Edge (décision S-1, fonction pas écrite). |
| 8 | Garde des brouillons | **Corrigé** | Quatre couches ; IR2-08 (découpeur qui ignore les commentaires) accepté en LOW |

### 5.2 Les constats des revues indépendantes n° 1 à n° 3

| Constats | État | Réserve |
|---|---|---|
| IR-01, IR-02, IR-03, IR-05, IR-06, IR-08, IR-09, IR-10, IR-11, IR-13, IR-14, IR-15, IR-17, IR-18, IR-19, IR-20, IR-22, IR-23, IR-25 | **Corrigé** (code) | Lignes dans `PHASE_1_3_1_SQL_DRAFT_CORRECTIONS.md` §1.4, contrôlées par sondage : 41 l. 593 (Brevo partagé), 43 l. 586 et 946 (`AUTH_FOURNISSEUR`), 43 l. 964 (`ORIGINAL_REMIS`), 43 l. 1104-1107 (IR3-01) |
| IR-04 | **Partiel** | Délais de 3 s + 2 s ; coût sous le délai d'exécution non mesuré (S-03, F-K07) |
| IR-07 | **Partiel** | Données hors du Centre (voir 5.1, n° 5) |
| IR-12 | **Non vérifiable** | Exigence des pages de la Phase 2c, pas encore écrites |
| IR-16 | **Partiel** | Limite connue : une annulation par délai n'est pas attrapée (41 l. 372-374) |
| IR-21 | **Partiel** | Performance sous verrous à mesurer (T-05) |
| IR-24 | **Non vérifiable** | Conflits entre PR : documentés |
| IR2-01 à IR2-07, IR2-09 à IR2-15, IR2-17 | **Corrigé** (code) | IR2-01 repose sur H4 (pg_net) |
| IR2-08 | **Non corrigé** (accepté, LOW) | — |
| IR3-01, IR3-02, IR3-03, IR3-05, IR3-06, IR3-08, IR3-09 | **Corrigé** (code) | Revérifiés par la revue finale (§6). IR3-06 (120 s) repose sur H4. |
| IR3-04 | **Corrigé** (code) | Contrôle à la porte (40 l. 403) et sur le fournisseur figé (43 l. 932) |
| IR3-07 | **Partiel** | La levée ne compare pas l'état affiché à l'écran ; elle refuse si un appui est postérieur à son début (constat L4, Phase 2c) |

---

## 6. Revue indépendante finale de `0693d5e`

*(Complété à réception du rapport de la revue.)*

---

## 7. Tableau des risques

| # | Gravité | Risque | Preuve | Impact | Action corrective |
|---|---|---|---|---|---|
| R-01 | MEDIUM | Hypothèses de pg_net non éprouvées (H4) | `PHASE_1_3_1_KILL_SWITCH_LOCK_PROOF.md` §5 ; 43 l. 1863 | Si pg_net retire la requête de sa file **après** l'appel, ou réessaie seul, un `STOP_CONFIRMED` pourrait précéder une dernière transmission | F-K05, F-K06 avant toute activation |
| R-02 | MEDIUM | Hypothèses de PostgreSQL non éprouvées (H1, H2, H3, H5) | Même document §3-4 | Attente imprévue (H1, H5), ou autorisation après la fermeture (H2, H3) | F-K01 à F-K03 |
| R-03 | MEDIUM | Arrêt sous le délai d'exécution | 41 `arreter_communications` ; S-03 | La demande d'arrêt elle-même peut être annulée | F-K07 ; si besoin, écrire la demande dans une transaction à part |
| R-04 | MEDIUM | Messages en double vers un contact partagé | 42 l. 1000 ; **2 numéros partagés en production** (§8) | Coût double, plainte, note de qualité WhatsApp | P-05, F-C06 |
| R-05 | MEDIUM | Données hors du Centre (pg_net, `journal_audit`, fournisseurs) | Revue SQL §2.2 | Conservation plus longue que la politique du Centre | Décision du juriste |
| R-06 | MEDIUM | Authentification de la fonction Edge non décidée | Décision S-1 | Webhooks non authentifiés si mal configurés | Décision du CEO avant la Phase 2 |
| R-07 | MEDIUM | Jeton dans le `Referer` | IR-12 | Fuite du jeton de désinscription ou de confirmation | Exigence de la Phase 2c (PR #46) |
| R-08 | LOW | Documentation des verrous inexacte | S-01 | Mauvaise compréhension, pas un trou de sûreté | P-01 (fait), P-02 (proposé) |
| R-09 | LOW | `lock_timeout = 0` après N0a | 41 l. 998 ; S-02 | Une attente imprévue n'aurait pas de limite | P-03, à peser |
| R-10 | LOW | Rôle global `communication_webhook` | S-04 | Survit à un retour arrière | Script de retrait (F-M03) |
| R-11 | LOW | Forme interne de pg_net | S-05 | Une mise à jour de pg_net peut casser le décompte | Version notée dans le script ; F-K05 à chaque mise à jour |
| R-12 | LOW | E-mail de connexion non recopié dans `clients` | S-07 | Message envoyé à une ancienne adresse | Décider la source de vérité (Phase 2c) |
| R-13 | LOW | Découpeur qui ignore les commentaires | IR2-08 | Exécution partielle d'un brouillon | Accepté |

Les risques venant de la revue finale sont ajoutés au §6.

---

## 8. Base clients : chiffres de la Phase 0 et chiffres actuels

**Source des chiffres actuels** : comptages agrégés en lecture seule, exécutés le **20/11/2026 à 03:12 UTC** sur la production, avec l'autorisation écrite de la direction. Aucune écriture n'a été faite. Aucune donnée personnelle n'a été affichée : ni nom, ni e-mail, ni numéro, ni identifiant.

**Définitions** :
- **client** : `clients.role = 'client'` ;
- **actif** : `supprime_le is null` ;
- **e-mail de forme valide** : motif `nom@domaine.tld` ;
- **téléphone de forme plausible** : 8 à 15 chiffres. Ce n'est **pas** une validation E.164, et cela ne prouve pas que le numéro est joignable sur WhatsApp.

### 8.1 Tableau comparatif

| Mesure | Phase 0 (18/11/2026, historique) | Actuel (20/11/2026) | Écart |
|---|---|---|---|
| Comptes, toutes catégories | 71 | 73 | +2 |
| Comptes de l'équipe (administrateurs) | 2 | 2 | 0 |
| Gérants, employés | 0 / 0 | 0 / 0 | 0 |
| **Clients actifs** | **69** | **71** | **+2** |
| Clients supprimés | non relevé | **0** | — |
| Clients avec un e-mail | 69 | 71 (71 de forme valide) | +2 |
| Clients avec un téléphone | 64 | 66 (66 de forme plausible) | +2 |
| Clients avec e-mail **et** téléphone | non relevé | 66 | — |
| E-mails partagés entre clients actifs | non relevé | 0 | — |
| **Numéros partagés entre clients actifs** | non relevé | **2 numéros** | — |
| Pays : HT · DO · US · vide | 37 · 18 · 9 · 5 | **38 · 18 · 10 · 5** | HT +1, US +1 |
| Langue : fr · en · ht · es | 51 · 9 · 7 · 2 | **52 · 9 · 8 · 2** | fr +1, ht +1 |
| Ville vide | non relevé | 8 | — |
| Tables `communication_*` en production | 0 | **0** | 0 |
| **Consentements marketing enregistrés** | **0** | **0** | 0 |

### 8.2 Les nouveaux clients

- **Inscriptions de clients depuis le 18/11/2026 à 00:00 UTC : 3.** Elles ont eu lieu le 18/11 vers 02 h UTC, le 18/11 vers 19 h UTC et le 19/11 vers 21 h UTC.
- **Deux sont nouveaux par rapport à la Phase 0.** C'est **cohérent** avec les écarts du tableau : +1 HT, +1 US, +1 fr, +1 ht, +2 téléphones, aucune suppression.

  **C'est une déduction, pas une preuve** : l'heure exacte du relevé de la Phase 0 n'a pas été notée. Celui de 02 h UTC (le 17/11 au soir, heure de Santo Domingo) faisait très probablement partie des 69.
- **Les deux nouveaux n'ont pas consenti au marketing, et ne le peuvent pas aujourd'hui.** Aucune table de consentement n'existe en production. Aucun écran ne demande ce consentement. `notification_preferences`, qui existe, ne concerne que le transactionnel et **ne vaut jamais consentement** (Phase 0, C6).

### 8.3 Changements de pays, de langue ou de coordonnées

`journal_audit`, depuis le 18/11/2026, en comptages seulement :

| Action | Nombre | Concerne |
|---|---|---|
| `client.creation` | 3 | les 3 inscriptions ci-dessus |
| `client.modification` | 5 | **2 clients, tous créés depuis le 18/11** : profil complété après l'inscription |
| `client.naissance_declaree` | 2 | — |

Champs touchés par ces 5 modifications :
- nom ×2 ;
- téléphone ×2 ;
- pays ×2 ;
- ville ×2 ;
- adresse ×2 ;
- région ×1 ;
- langue ×1.

**Aucune modification de pays, de langue ou de coordonnées d'un client de la Phase 0** n'est journalisée depuis le 18/11.

**Limite** : `journal_audit` ne voit que les écritures qui passent par ses déclencheurs. Une modification faite à la main dans le Table Editor de Supabase n'y serait pas, et un changement d'e-mail dans `auth.users` n'est pas recopié dans `clients` (S-07).

### 8.4 Ce que cela change pour l'audience

**71 clients ne sont pas 71 contacts autorisés au marketing.** Aujourd'hui, **0** contact est autorisé, sur tous les canaux.

Le jour où le Centre serait installé, chacun de ces clients passerait par les mêmes contrôles, dans l'ordre de `communication_raison_exclusion` (42 l. 507) :

| Contrôle | Code | Effet sur les 71 clients actuels |
|---|---|---|
| Compte actif, pas de l'équipe | `COMPTE_INACTIF`, `COMPTE_EQUIPE` | 71 passent ; les 2 administrateurs ne reçoivent que des essais |
| Contact présent | `SANS_DESTINATAIRE` | E-mail : 71. WhatsApp : 66 au plus (5 sans téléphone). |
| Liste de suppression | `SUPPRIME` (40 l. 660, par empreinte du **contact**) | 0 aujourd'hui (table absente) |
| **Consentement confirmé** (double consentement) | `SANS_CONSENTEMENT_CONFIRME` (42 l. 546 ; 40 l. 590 : `actif` seulement si `confirme`, pour le contact **actuel**) | **71 exclus** tant que personne n'a confirmé. La demande seule ne suffit pas. |
| Fuseau sûr | `FUSEAU_INCONNU` (42 l. 550 ; 40 l. 890-915) | **15 exclus** même avec un consentement : 10 aux États-Unis (table des États vide) et 5 sans pays. Il faut un fuseau déclaré. |
| WhatsApp : territoire et tarif vérifiés | `TERRITOIRE_NON_AUTORISE`, `TARIF_NON_VERIFIE` | Les numéros +1 (US, DO) dépendent de la décision sur la pause de Meta |
| Un seul message par contact | **absent** (S-06) | **2 numéros partagés** : deux messages au même numéro si les deux comptes confirment. Correction P-05. |

**Suppression et désinscription** : elles portent sur l'**empreinte du contact** (40 l. 660 ; 43 l. 1604), pas sur le compte. Un STOP venu d'un numéro partagé bloque donc les deux comptes. C'est le comportement attendu.

**Changement de coordonnées** (41 l. 278-380) :
- un nouvel e-mail ou un nouveau numéro invalide le consentement du canal concerné ;
- un changement de pays peut aussi invalider le consentement WhatsApp, car le préfixe international en dépend ;
- un changement de pays ou de région efface le fuseau déclaré ;
- l'écriture du client ne peut pas être bloquée par le Centre.

Les 5 modifications relevées au §8.3 n'auraient rien changé : aucun consentement n'existait.

**Ce qui est vérifié** :
- les comptages ;
- le code de ces contrôles, par lecture.

**Ce qui ne l'est pas** : leur fonctionnement réel (essais F-C01 à F-C07).

---

## 9. Corrections restantes

### 9.1 Corrections documentaires (autorisées par la mission, faites)

| # | Fichier | Correction |
|---|---|---|
| D-01 | `PHASE_1_3_1_KILL_SWITCH_DESIGN.md` l. 85 | Les verrous de ligne en SKIP LOCKED pris après N0a sont maintenant décrits (P-01) |
| D-02 | `COMMUNICATION_CENTER_PHASE_0_AUDIT.md` §3.1 | Note datée : chiffres historiques gardés, chiffres actuels au §8 |
| D-03 | `COMMUNICATION_CENTER_PHASE_1_RAPPORT.md` (3 endroits) | Chiffres de la Phase 0 marqués comme tels ; chiffres actuels ajoutés |
| D-04 | `PHASE_1_3_1_SQL_40_43_SECURITY_REVIEW.md` | Constats S-06 et S-07 ajoutés |

### 9.2 Corrections SQL proposées (NON appliquées)

| # | Fichier, fonction, ligne | Proposition | Priorité |
|---|---|---|---|
| P-02 | 41 l. 899 (commentaire) | Même correction que P-01 | Avant la Phase 2 |
| P-03 | 41 `arreter_communications` l. 998 ; `confirmer_arret_communications` | `lock_timeout` de 2 s au lieu de 0 après N0a | À peser après F-K03 |
| P-04 | — | Éprouver H1 et H5 (F-K03) | Avant toute activation |
| P-05 | 42 `communication_destinataires` l. 1000 et le calcul de l'audience | Un seul destinataire par (campagne, canal, empreinte du contact) ; l'autre est exclu avec `CONTACT_EN_DOUBLE` | Avant toute campagne |
| P-06 | Script de retrait (Phase 2) | Retirer le droit du rôle `communication_webhook` ; noter la version de pg_net | Avec la Phase 2 |

Les propositions issues de la revue finale sont au §6.

---

## 10. Vérifié, documenté, non éprouvé, externe

| Catégorie | Contenu |
|---|---|
| **Vérifié** (code lu ou compté) | Inventaire des objets et des droits ; porte unique et marque de sortie dans toutes les fonctions d'appel ; `STOP_CONFIRMED` conditionné à N0 exclusif et à zéro transmission ; SKIP LOCKED dans l'observation ; aucun repli ; séparation avec le transactionnel dans le code ; garde à quatre couches (analyse) ; chiffres clients du §8 (production, en lecture seule) ; 0 table du Centre en production |
| **Seulement documenté** | Ordre des migrations et transaction unique ; retour arrière ; exigences de la Phase 2c (Referer, pages) ; politique de conservation |
| **Non éprouvé** | Les 60 essais (40 + 20), dont : absence d'interblocage, propriétés (a) et (b) de l'arrêt, quota, 5xx et 429, webhooks, purges, non-régression du transactionnel |
| **Dépend d'une vérification externe** | Fonctionnement interne de pg_net 0.20.4 (H4) ; règles de Meta (pause +1, tarifs, Coexistence) ; quotas Brevo ; avis du juriste (consentement, durées, motifs) ; délai d'exécution réel de Supabase (8 s, rapporté) |

---

## 11. Verdict

*(Arrêté après la comparaison avec la revue indépendante finale, §6.)*

**Aucune Phase 2 n'est autorisée par ce document.**
