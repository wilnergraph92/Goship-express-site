# GoShip Express — Centre de communication
# CLÔTURE DE L'AUDIT DE LA PHASE 1.3.1 — Vérification finale indépendante

| | |
|---|---|
| Date | 20 novembre 2026 |
| Code examiné | commit `0693d5e` (brouillons SQL 40 à 43, version 1.3.1). `git diff 0693d5e HEAD -- docs/communication-center/brouillons-sql/` est vide : les brouillons n'ont pas changé depuis. |
| Branche | `ccr-056ddc8c-m7u4p1`, PR #65 (brouillon, **non fusionnée**) |
| Mode | Lecture du code, analyse statique sans serveur (`pglast`), revue indépendante. Seule exception, autorisée par écrit par la direction le 20/11/2026 (« Oui, SELECT agrégés ») : **des comptages agrégés en lecture seule sur la production** (§8), sans écriture et sans donnée personnelle. |
| Phase 2 | **Non autorisée** par cette mission |
| Verdict | **NON VALIDÉ** (§11) |

**Documents de la clôture** :
- le présent audit ;
- `PHASE_1_3_1_KILL_SWITCH_LOCK_PROOF.md` : les verrous de l'arrêt d'urgence, fonction par fonction, et la preuve ;
- `PHASE_1_3_1_SQL_40_43_SECURITY_REVIEW.md` : la revue des migrations 40 à 43 ;
- `PHASE_1_3_1_FINAL_TEST_PLAN.md` : 25 essais, **tous non exécutés** ;
- `PHASE_1_3_1_FINAL_INDEPENDENT_REVIEWER_REPORT.md` : le rapport de la revue indépendante finale, reproduit tel quel.

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
4. **La revue indépendante finale arrive à la même conclusion** sur les points 2 et 3 (§6). Elle ajoute une hypothèse, H4′ : le transfert doit **commencer** moins de 60 s après que la sortie de la file est devenue visible. Elle trouve aussi un défaut de l'arrêt que j'avais sous-évalué : **RF-01**. La demande d'arrêt est écrite dans la même transaction que le constat. Une erreur ou un délai dépassé pendant le constat **annule la demande elle-même**. L'écran reçoit alors une erreur, et les envois continuent d'être autorisés.
5. **Un effet de bord, borné :** pendant l'arrêt, le webhook, la purge et l'annulation peuvent attendre une ligne que l'arrêt a verrouillée, jusqu'à la fin de l'arrêt (au plus quelques secondes). Il n'y a pas de cycle.

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
| 1 | Arrêt d'urgence | **Partiel** | Refait en 1.3.1 : porte unique (40 l. 379), N0 exclusif, `STOP_PENDING` sans repli (41 l. 960-1016). **Aucun faux `STOP_CONFIRMED`** trouvé, par deux lectures indépendantes. **Restent** : RF-01 (ÉLEVÉE) ; les garanties H1 à H5 et H4′, non éprouvées ; la documentation des verrous, qui était inexacte et a été corrigée (S-01). |
| 2 | Ordre des verrous | **Partiel** *(revu après la revue finale : « corrigé » dans le brouillon de cet audit)* | Les verrous **déclarés** (N0 → N0a → N1 … N5) sont pris dans l'ordre, et le constat de l'arrêt est en SKIP LOCKED. **Mais** une clé étrangère pose un verrou `FOR KEY SHARE` caché sur la ligne d'envoi **avant** N1. Deux retours du fournisseur pour le même envoi peuvent donc s'interbloquer (RF-02, vérifié dans le code : 43 l. 1257, 1444, 1525, 1531). S'y ajoute un ordre inversé entre un STOP et le code 131050 (RF-05). Ces interblocages sont **détectés** par PostgreSQL, qui annule une transaction : il n'y a pas d'attente infinie, mais un retour est perdu si le fournisseur ne réessaie pas. **Aucun ne passe par l'arrêt.** |
| 3 | Quota Brevo et débit global | **Partiel** | `communication_reserver` sous N5 (43 l. 253), READ COMMITTED vérifié. Le vrai quota reste une déclaration manuelle (non vérifiable). Le coût des lectures sous N5 reste à mesurer (RF-04). Non éprouvé (T-03B). |
| 4 | Réponses 5xx et 429 | **Corrigé** (code) | Incertain sans renvoi automatique ; relance avec risque de doublon accepté explicitement (43 l. 1671-1691). Non éprouvé (T-04B). |
| 5 | Données personnelles | **Partiel** | Centre : empreintes HMAC, purges. **Hors du Centre** : corps des requêtes pg_net (environ 6 h, rapporté), motifs dans `journal_audit`, fournisseurs. Décision du juriste attendue. |
| 6 | Fuseaux horaires | **Corrigé** (code) | `FUSEAU_INCONNU` plutôt qu'un fuseau deviné (40 l. 890-915, 42 l. 550). Prudent : **aujourd'hui, 15 clients sur 71 seraient exclus pour cette seule raison** (§8). |
| 7 | Webhooks et horodatage | **Partiel** | Rejeu refusé (43 l. 1261), STOP gardé (IR-08, IR2-06). **Restent** :<br>- interblocages RF-02 et RF-05 ;<br>- STOP reconnu seulement si le message entier est le mot d'arrêt (RF-03, 43 l. 1291) ;<br>- débit compté avant la signature.<br>**Non vérifiable** : authentification de la fonction Edge (décision S-1, fonction pas écrite). |
| 8 | Garde des brouillons | **Corrigé** | Quatre couches ; IR2-08 (découpeur qui ignore les commentaires) accepté en LOW |

### 5.2 Les constats des revues indépendantes n° 1 à n° 3

| Constats | État | Réserve |
|---|---|---|
| IR-01, IR-02, IR-03 (sous réserve de RF-01), IR-05, IR-06, IR-08, IR-09, IR-10, IR-11, IR-13 (les trois interblocages visés ; RF-02 et RF-05 en sont d'autres), IR-14, IR-15, IR-17, IR-18, IR-19, IR-20, IR-22, IR-23, IR-25 | **Corrigé** (code) | Lignes dans `PHASE_1_3_1_SQL_DRAFT_CORRECTIONS.md` §1.4, contrôlées par sondage : 41 l. 593 (Brevo partagé), 43 l. 586 et 946 (`AUTH_FOURNISSEUR`), 43 l. 964 (`ORIGINAL_REMIS`), 43 l. 1104-1107 (IR3-01) |
| IR-04 | **Partiel** | Délais de 3 s + 2 s ; coût sous le délai d'exécution non mesuré (S-03, F-K07) |
| IR-07 | **Partiel** | Données hors du Centre (voir 5.1, n° 5) |
| IR-12 | **Non vérifiable** | Exigence des pages de la Phase 2c, pas encore écrites |
| IR-16 | **Partiel** | Limite connue : une annulation par délai n'est pas attrapée (41 l. 372-374) |
| IR-21 | **Partiel** | Performance sous verrous à mesurer (T-05) |
| IR-24 | **Non vérifiable** | Conflits entre PR : documentés |
| IR2-01 à IR2-07, IR2-09 à IR2-15, IR2-17 | **Corrigé** (code) | IR2-01 repose sur H4 (pg_net) |
| IR2-08 | **Non corrigé** (accepté, LOW) | — |
| IR3-01, IR3-02, IR3-03, IR3-05, IR3-06, IR3-08, IR3-09 | **Corrigé** (code) | IR3-01, IR3-03 et IR3-06 sont confirmés par la revue finale (§3.4 de son rapport) : remise à zéro de l'observation à chaque nouvelle requête, lectures Meta comptées, fenêtre de 120 s. IR3-06 repose sur H4 et H4′. |
| IR3-04 | **Corrigé** (code) | Contrôle à la porte (40 l. 403) et sur le fournisseur figé (43 l. 932) |
| IR3-07 | **Partiel** | La levée ne compare pas l'état affiché à l'écran ; elle refuse si un appui est postérieur à son début (constat L4, Phase 2c) |

---

## 6. Revue indépendante finale de `0693d5e`

### 6.1 Méthode

- **Relecteur** : une session distincte (`security-auditor`), lancée sans le contexte de l'auteur.
- **Ce qu'elle a reçu** :
  - le commit ;
  - les fichiers ;
  - les questions de la mission ;
  - la consigne de chercher des contre-exemples.
- **Ce qu'elle n'a pas reçu** : les conclusions attendues, la preuve des verrous, les constats S-01 à S-07.
- **Ce qu'elle a fait** :
  - relecture complète des quatre brouillons ;
  - analyse statique (`pglast`) ;
  - simulation d'un découpeur naïf.
- **Ce qu'elle n'a pas fait** : exécuter une seule requête, ou modifier le dépôt.
- **Son rapport** : `PHASE_1_3_1_FINAL_INDEPENDENT_REVIEWER_REPORT.md` (19 constats, RF-01 à RF-19).

**Limite** : ce n'est ni un humain ni un modèle différent.

### 6.2 Points d'accord

| Question | Auteur | Relecteur |
|---|---|---|
| Le constat de l'arrêt verrouille-t-il des lignes après N0 et N0a ? | Oui, en SKIP LOCKED ; la documentation était fausse (S-01) | Oui ; mêmes lignes ; commentaires inexacts (RF-17) |
| Interblocage possible **dans** l'arrêt ? | Non : il n'attend jamais après N0a | Non : « aucun cycle ne passe par S » (§3.2) |
| `STOP_CONFIRMED` peut-il mentir ? | Non dans le code, sous H1 à H5 | Non dans le code, sous H1 à H5 et **H4′** ; contre-exemples cherchés sans succès (§3.4) |
| Séparation avec le transactionnel | Vérifiée dans le code ; e-mails de facture coupés | Confirmée dans le code ; réserve de configuration (RF-06) |
| Droits, RLS, `SECURITY DEFINER`, `search_path` | Inventaire vérifié | Vérifié avec `pglast` |
| Durée de l'arrêt sous le délai d'exécution | MEDIUM (S-03, R-03) | **ÉLEVÉE** (RF-01) |

Les deux numérotations des hypothèses diffèrent :
- le H1 du relecteur (verrou consultatif et sous-transaction) correspond à mon H2 ;
- son H2 (visibilité) correspond à mon H3 ;
- son H3 et son H4 (pg_net) correspondent à mon H4 ;
- son H5 (file d'attente des verrous) est une hypothèse **nouvelle** pour moi ;
- **mon** H1 (`journal_audit`) et **mon** H5 (SKIP LOCKED) sont **vérifiés** dans son rapport, par la lecture des définitions existantes, ou **rapportés**.

### 6.3 Désaccords et leur résolution

| # | Sujet | Auteur (avant la revue) | Relecteur | Vérification de l'auteur dans le code | Résolution |
|---|---|---|---|---|---|
| X-01 | Gravité de la demande d'arrêt annulée avec le constat | MEDIUM (S-03) : seul le délai d'exécution était envisagé | ÉLEVÉE (RF-01) : toute erreur après l. 1006 annule la demande. Causes possibles : délai, recul d'horloge contre la contrainte, attente sans limite face à une migration rejouée. | **Confirmé** : 41 l. 1001-1017 ; aucun bloc `exception` autour de `communication_conclure_arret` | **Le relecteur a raison.** R-03 passe à **ÉLEVÉE** ; correction P-07. |
| X-02 | Ordre des verrous hors de l'arrêt | « Corrigé (code) » | PARTIEL : `FOR KEY SHARE` des clés étrangères avant N1 ; deux retours pour un même envoi s'interbloquent (RF-02) | **Confirmé** : clé étrangère 43 l. 1257 ; insertion l. 1444 ; campagne `for update` l. 1525 ; envoi `for update` l. 1531. Deux transactions tiennent chacune `KEY SHARE`, puis demandent `FOR UPDATE` : un cycle, que PostgreSQL rompt en annulant l'une d'elles. | **Le relecteur a raison**, et cela m'avait échappé. §5.1 n° 2 corrigé ; R-14 (ÉLEVÉE) ; P-08. |
| X-03 | Quota Brevo | « Corrigé (code) » | PARTIEL : quota déclaré à la main ; coût sous N5 (RF-04) | Accord sur les faits | Classé **Partiel** |
| X-04 | Reconnaissance du STOP | Non relevé | MOYENNE (RF-03) : seul le message **entier** égal à un mot d'arrêt compte | **Confirmé** : 43 l. 1291-1300 (`in (...)` sur le message entier simplifié) | Adopté : R-15, P-09 |
| X-05 | Doublon d'envoi par contact partagé | MEDIUM (S-06), appuyé sur le relevé de production | Non relevé (le relecteur n'avait pas les chiffres de production) | 42 l. 1000 | **Maintenu** (R-04) |
| X-06 | E-mail de connexion non recopié | LOW (S-07) | Non relevé | `outils/supabase.sql` l. 535 | **Maintenu** (R-12) |
| X-07 | Garde derrière un pooler | Limite IR2-08 acceptée (LOW) | RF-08 (LOW) : derrière un pooler, la couche 4 ne ferme qu'une connexion. Les `revoke` en blocs `DO` sont coupés, et `communication_segment_clients` resterait ouverte. | Plausible ; simulation du relecteur, non refaite | Adopté (LOW) : en Phase 2, chaque `revoke` devient une instruction seule (P-12) |
| X-08 | Rejouabilité | « Rejouable » (règle du projet) | `create table if not exists` n'ajoute pas les colonnes nouvelles ; un rejeu verrouille `clients` (RF-09) | Accord | Exigence de la Phase 2 : `alter table … add column if not exists` et `lock_timeout` en tête (P-13) |

Aucun constat du relecteur n'a été écarté. Les gravités FAIBLE et INFO (RF-05, RF-07 et RF-09 à RF-19) sont reprises telles quelles, au §7.

### 6.4 Ce que la revue change à la réponse de la mission

- **La question posée** (les verrous du constat créent-ils un interblocage ?) : **non, confirmé deux fois.**
- **Le mécanisme d'arrêt n'est pas pour autant prêt.** Il ne ment pas (pas de faux `STOP_CONFIRMED`), mais il peut **échouer sans rien écrire** (RF-01).
- **Hors de l'arrêt, deux défauts de gravité ÉLEVÉE ou MOYENNE** touchent les signaux de désinscription : RF-02 (retours perdus par interblocage) et RF-03 (STOP mal reconnu). Ce sont précisément les signaux qu'il ne faut jamais perdre.

---

## 7. Tableau des risques

| # | Gravité | Risque | Preuve | Impact | Action corrective |
|---|---|---|---|---|---|
| R-01 | MEDIUM | Hypothèses de pg_net non éprouvées (H4, et H4′ : début du transfert moins de 60 s après la sortie de file visible) | `PHASE_1_3_1_KILL_SWITCH_LOCK_PROOF.md` §5 ; rapport du relecteur §3.6 ; 43 l. 1863 | Si pg_net retire la requête de sa file **après** l'appel, ou réessaie seul, un `STOP_CONFIRMED` pourrait précéder une dernière transmission | F-K05, F-K06, F-K09 avant toute activation |
| R-02 | MEDIUM | Hypothèses de PostgreSQL non éprouvées (H1, H2, H3, H5) | Même document §3-4 | Attente imprévue (H1, H5), ou autorisation après la fermeture (H2, H3) | F-K01 à F-K03 |
| R-03 | **ÉLEVÉE** *(MEDIUM avant la revue finale)* | Demande d'arrêt annulée avec le constat (RF-01, S-03) | 41 l. 1001-1017 : pas de bloc `exception` autour de `communication_conclure_arret` | L'arrêt peut **ne rien écrire** au moment où on en a besoin, et les envois continuent | P-07 ; F-K07, F-K10 |
| R-04 | MEDIUM | Messages en double vers un contact partagé | 42 l. 1000 ; **2 numéros partagés en production** (§8) | Coût double, plainte, note de qualité WhatsApp | P-05, F-C06 |
| R-05 | MEDIUM | Données hors du Centre : pg_net, fournisseurs, et motifs en texte libre dans `journal_audit`, que la purge ne peut pas effacer (RF-11) | Revue SQL §2.2 ; 41 l. 427, 454, 1228 | Effacement incomplet ; conservation plus longue que la politique du Centre | Motifs codés (liste fermée) plus une référence (P-11) ; décision du juriste |
| R-06 | MEDIUM | Authentification de la fonction Edge non décidée | Décision S-1 | Webhooks non authentifiés si mal configurés | Décision du CEO avant la Phase 2 |
| R-07 | MEDIUM | Jeton dans le `Referer`, y compris vers Meta depuis la page **suivante** si la PR #46 est fusionnée (RF-12) | IR-12 ; branche `pixel-meta` | Fuite du jeton de désinscription ou de confirmation | Exigence de la Phase 2c (PR #46) |
| R-08 | LOW | Documentation et commentaires des verrous inexacts | S-01, RF-17 (41 l. 898-899, 979, 988, 1094-1097) | Mauvaise compréhension, pas un trou de sûreté | P-01 (fait) ; P-02 (proposé), étendu aux autres commentaires de RF-17 |
| R-09 | LOW | `lock_timeout = 0` après N0a ; N0 exclusif sans limite dans trois fonctions de réglage (RF-07) | 41 l. 998, 549-550, 637, 660, 1153 ; S-02 | Une attente imprévue n'a pas de limite ; un réglage pendant un envoi retarde l'arrêt (`STOP_PENDING`, sans contournement) | P-03 étendu : `lock_timeout` borné partout où N0 exclusif est pris |
| R-10 | LOW | Rôle global `communication_webhook` | S-04 | Survit à un retour arrière | Script de retrait (F-M03) |
| R-11 | LOW | Forme interne de pg_net | S-05 | Une mise à jour de pg_net peut casser le décompte | Version notée dans le script ; F-K05 à chaque mise à jour |
| R-12 | LOW | E-mail de connexion non recopié dans `clients` | S-07 | Message envoyé à une ancienne adresse | Décider la source de vérité (Phase 2c) |
| R-13 | LOW | Garde : découpeur qui ignore les commentaires (IR2-08) ou pooler qui rouvre la connexion (RF-08) | Simulation du relecteur | Fonctions `SECURITY DEFINER` créées sans leur `revoke` (par ex. `communication_segment_clients`, qui énumère les clients) | Accepté pour un brouillon ; P-12 en Phase 2 |
| **R-14** | **ÉLEVÉE** | Interblocage de deux retours du fournisseur pour le même envoi (RF-02) | 43 l. 1257, 1444, 1525, 1531 (vérifié) | Un retour est annulé (statut, rebond, plainte, désinscription) ; il n'est repris que si le fournisseur réessaie (rapporté) | P-08 ; F-W01 |
| R-15 | MEDIUM | STOP non reconnu s'il n'est pas le message entier (RF-03) | 43 l. 1291-1300 (vérifié) | Désinscription ignorée : conformité, note de qualité WhatsApp | P-09 ; F-W03 |
| R-16 | MEDIUM | Coût d'un STOP et de l'aperçu : une lecture du coffre et un HMAC par client (RF-04) | 43 l. 1470-1471 ; 40 l. 249-265 | Négligeable à 71 clients ; délai dépassé et STOP perdu à grande échelle ; N0 partagé tenu plus longtemps | P-10 ; mesure à 20 000 clients |
| R-17 | MEDIUM | Séparation tenue seulement par le nom des réglages (RF-06) | 41 l. 584-647 ; 40 l. 401-404 | Un administrateur peut mettre la clé transactionnelle côté commercial | Refuser des valeurs identiques (empreintes) ; deux personnes pour déclarer `brevo_compte_partage = false` ; même garde pour Resend et WhatsApp |
| R-18 | LOW | Interblocage entre un STOP entrant et le code 131050 (RF-05) | 43 l. 1466-1473 contre l. 1528-1552 | STOP ou opposition annulé, puis repris si Meta réessaie | N3 avant l'insertion de la suppression ; F-W02 |
| R-19 | LOW | Rejeu d'une migration : verrou sur `clients` et sur la ligne d'arrêt (RF-09) | 41 l. 376-379 ; 40 l. 210-212 | Espace client et arrêt bloqués pendant un rejeu | P-13 |
| R-20 | LOW | Le déclencheur sur `clients` attend N3 sans délai (RF-10) | 41 l. 296-326 | Une modification de profil peut attendre, puis échouer, à cause du Centre | `pg_try_advisory_xact_lock` et reprise par le travailleur |
| R-21 | LOW | File pg_net partagée avec le transactionnel (RF-15) | 43 l. 868-871 | E-mails de colis retardés à fort débit | Céder la place selon la profondeur de la file |
| R-22 | LOW / INFO | RF-13 (lien de confirmation sans contrôle `https`), RF-14 (fréquence sans les échecs après remise), RF-16 (fenêtre avant `revoke`), RF-18 (`Prefer: tx=rollback`), RF-19 (purge du dernier consentement actif) | Rapport du relecteur, §2 | Faibles | Repris en Phase 2 ; RF-19 : décision du juriste et du CEO |

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
| D-04 | `PHASE_1_3_1_SQL_40_43_SECURITY_REVIEW.md` | Constats S-06 et S-07 ajoutés ; S-03 passé à ÉLEVÉE (RF-01) |
| D-05 | `PHASE_1_3_1_KILL_SWITCH_LOCK_PROOF.md` | Hypothèse H4′ et défaut RF-01 ajoutés ; verrou caché des clés étrangères (RF-02) mentionné au §2.10 |
| D-06 | `PHASE_1_3_1_FINAL_INDEPENDENT_REVIEWER_REPORT.md` | Rapport du relecteur, reproduit tel quel |
| D-07 | `README.md` | Index des documents de clôture |

### 9.2 Corrections SQL proposées (NON appliquées)

| # | Fichier, fonction, ligne | Proposition | Priorité |
|---|---|---|---|
| P-02 | 41 l. 898-899, 979, 988, 1094-1097 (commentaires) | Même correction que P-01, plus les durées réelles (3 s et 2 s ; levée 5 s) (RF-17) | Avant la Phase 2 |
| P-03 | 41 `arreter_communications` l. 998 ; `confirmer_arret_communications` ; `regler_communications` l. 549-550 ; `verifier_quota_brevo` l. 637 ; `regler_whatsapp_commercial` l. 660 ; `verifier_issue_http` l. 1153 | `lock_timeout` borné (2 à 3 s) partout où N0 exclusif est tenu, et valeur précédente remise au lieu de `'0'` (S-02, RF-07) | Avant la Phase 2 |
| P-04 | — | Éprouver H1 et H5 (F-K03) | Avant toute activation |
| P-05 | 42 `communication_destinataires` l. 1000 et le calcul de l'audience | Un seul destinataire par (campagne, canal, empreinte du contact) ; l'autre est exclu avec `CONTACT_EN_DOUBLE` | Avant toute campagne |
| P-06 | Script de retrait (Phase 2) | Retirer le droit du rôle `communication_webhook` ; noter la version de pg_net | Avec la Phase 2 |

| **P-07** | 41 `arreter_communications` l. 1015-1017 | **Isoler le constat** dans une sous-transaction : `begin … exception when others or query_canceled then … 'STOP_PENDING', 'CONSTAT_IMPOSSIBLE' end`. Mieux : séparer en deux appels, `demander_arret` (court, validé tout de suite) puis `confirmer_arret_communications`. La demande doit **toujours** rester écrite (RF-01). | **Condition de la Phase 2** |
| **P-08** | 43 `communication_recevoir_evenement` l. 1444-1531 ; `relancer_envoi_communication` l. 1686 ; purge 43 l. 1816 | Prendre N1, N3 puis l'envoi `FOR UPDATE` **avant** d'insérer l'événement : l'index unique détecte toujours le rejeu, et l'insertion se fait en dernier. Ou retirer la clé étrangère sur `envoi_id`. Dans la relance, prendre la campagne avant l'envoi. Dans la purge, `NOWAIT` puis `PURGE_RETRY` (RF-02). | **Condition de la Phase 2** |
| P-09 | 43 `communication_est_stop` l. 1291-1300 | Reconnaître le **premier mot**, ou la présence d'un mot d'arrêt, dans les quatre langues ; traiter la charge du bouton de désinscription de Meta. La liste doit être validée par le juriste (RF-03). | Avant toute campagne WhatsApp |
| P-10 | 43 l. 1470-1471 ; 40 `communication_empreinte` | Chercher les clients d'un numéro par `telephone_international(...)` indexé, et lire le poivre une fois par instruction (RF-04) | Avant toute campagne |
| P-11 | 41 l. 427, 454, 1228 ; 40 l. 1128 | Motifs codés (liste fermée) et référence de ticket, aucun texte libre dans `journal_audit` (RF-11) | Avec l'avis du juriste |
| P-12 | Migrations de la Phase 2 | Chaque `revoke` en instruction seule, juste après son `create function` ; fonctions internes dans un schéma non exposé (RF-08, RF-16) | Avec la Phase 2 |
| P-13 | Migrations de la Phase 2 | `alter table … add column if not exists` pour toute colonne ajoutée ; déclencheurs créés seulement s'ils manquent ; `lock_timeout` en tête (RF-09) | Avec la Phase 2 |
| P-14 | 41 `communication_suivre_client` l. 296-326 | `pg_try_advisory_xact_lock` ; si le verrou est occupé, noter l'invalidation à reprendre (RF-10) | Avant la Phase 2 |
| P-15 | 41 `regler_communications`, porte | Refuser une valeur commerciale identique à la valeur transactionnelle (empreintes) ; deux personnes pour déclarer le compte non partagé (RF-06) | Avant toute activation |
| P-16 | 43 l. 405 et 1089 ; l. 190-209 ; l. 868-871 ; 40 l. 1136-1142 | RF-13 (contrôle `https` du lien de confirmation), RF-14 (fréquence), RF-15 (file pg_net), RF-19 (décision) | Avec la Phase 2 |

---

## 10. Vérifié, documenté, non éprouvé, externe

| Catégorie | Contenu |
|---|---|
| **Vérifié** (code lu deux fois, par l'auteur et par le relecteur, ou compté) | Inventaire des objets et des droits ; porte unique et marque de sortie dans les trois fonctions d'appel ; `STOP_CONFIRMED` conditionné à N0 exclusif et à zéro transmission (code et contrainte) ; aucun faux `STOP_CONFIRMED` trouvé ; SKIP LOCKED dans l'observation, sans interblocage par l'arrêt ; aucun repli ; séparation avec le transactionnel dans le code ; e-mails de facture non touchés ; garde à quatre couches (analyse) ; chiffres clients du §8 (production, en lecture seule) ; 0 table du Centre en production. **Défauts vérifiés** : RF-01, RF-02, RF-03, RF-05. |
| **Seulement documenté** | Ordre des migrations et transaction unique ; retour arrière ; exigences de la Phase 2c (Referer, pages) ; politique de conservation |
| **Non éprouvé** | Les 65 essais (40 + 25), dont : absence d'interblocage, propriétés (a) et (b) de l'arrêt, quota, 5xx et 429, webhooks, purges, non-régression du transactionnel |
| **Dépend d'une vérification externe** | Fonctionnement interne de PostgreSQL (H1 à H3, H5, `KEY SHARE` des clés étrangères) et de pg_net 0.20.4 (H4, H4′) ; réessais des webhooks par Meta et Brevo ; privilèges par défaut et `Prefer: tx=rollback` de Supabase ; règles de Meta (pause +1, tarifs, Coexistence) ; quotas Brevo ; avis du juriste (consentement, durées, motifs) ; délai d'exécution réel de Supabase (8 s, rapporté) |

---

## 11. Verdict

# **NON VALIDÉ**

**Pourquoi.** La question posée trouve une réponse claire, confirmée par deux lectures indépendantes. Les verrous que prend le constat d'arrêt (en SKIP LOCKED) ne créent **aucun** interblocage. Le code n'écrit **jamais** `STOP_CONFIRMED` à tort, sous les hypothèses H1 à H5 et H4′.

Mais la vérification finale a trouvé, **dans les brouillons de `0693d5e`**, deux défauts de gravité ÉLEVÉE. Les corriger demande de modifier le SQL, ce que cette mission interdit. Ils restent donc ouverts :

1. **RF-01, l'arrêt d'urgence peut échouer sans rien écrire** : la demande est annulée avec le constat. Un arrêt qui peut perdre sa propre demande ne répond pas à l'exigence de la direction.
2. **RF-02, deux retours du fournisseur pour le même envoi s'interbloquent.** Un signal de plainte ou de désinscription peut être perdu.

S'y ajoutent :
- un STOP mal reconnu (RF-03, MOYENNE) ;
- des messages en double vers les **2 numéros** partagés relevés en production (S-06, MOYENNE).

Enfin, **aucun des 65 essais n'a été exécuté.**

> **Note du 23/11/2026, décompte des essais.** Le nombre 65 (40 + 25) est celui de cet audit, établi sur
> les brouillons de `0693d5e`, avant les corrections D5. D5 a ajouté 13 essais (F-K11, F-K12,
> F-W04 à F-W08, F-C08 à F-C11, F-S01, F-S03) : le plan final en compte donc 38, et le total de
> référence est **78 = 40 + 38** (`PHASE_1_3_1_FINAL_TEST_PLAN.md`, §5). Les deux nombres ne se
> contredisent pas ; ils décrivent deux états successifs. Au 23/11/2026, **aucun des 78 essais n'a été
> exécuté.** Le texte de l'audit est conservé tel quel.

**Ce verdict ne remet pas en cause la conception de l'arrêt.** Il dit que les brouillons, tels qu'ils sont, **ne peuvent pas servir de base à la Phase 2**.

### Conditions exactes avant toute Phase 2

1. **Autorisation écrite** de la direction pour corriger les brouillons : P-07 et P-08 obligatoirement ; P-02, P-03, P-05, P-09, P-14 et P-15 recommandées.
2. **Revue indépendante** de ces seules corrections, idéalement par un humain spécialiste de PostgreSQL. Pour cette nouvelle revue :
   - RF-01 doit être clos : une demande d'arrêt qui reste écrite quoi qu'il arrive au constat ;
   - RF-02 doit être clos : plus aucun verrou caché pris avant N1.
3. **Autorisation écrite** de la direction pour une Phase 2 **limitée à une base jetable**, puis exécution des essais BLOQUANTS dans l'ordre du plan :
   - F-M01, F-M02 ;
   - F-K05 et F-K09 (pg_net) ;
   - F-K01 à F-K03, F-K08, F-K10 ;
   - F-K06, F-K04, F-K07 ;
   - F-W01 à F-W03 ;
   - F-T01, F-T02 ;
   - F-C01 à F-C07 ;
   - puis le plan précédent.
4. **Décisions du CEO toujours ouvertes** :
   - C4 : compte e-mail commercial séparé ; numéro WhatsApp ;
   - S-1 : authentification de la fonction Edge ;
   - D-G, D-H : adresses ;
   - ordre des PR #46 et #48, et RF-12 (le pixel Meta et le `Referer`).
5. **Avis du juriste** : texte du consentement ; liste des mots d'arrêt (RF-03) ; durées de conservation ; motifs dans `journal_audit` (RF-11) ; purge du dernier consentement (RF-19).

**Rien n'a été exécuté. La production n'a pas été modifiée** : seulement 5 comptages agrégés en lecture seule, autorisés. **La PR #65 n'est pas fusionnée.** Les PR #46 et #48 n'ont pas été touchées.

**Aucune Phase 2 n'est autorisée par ce document.**

**CLÔTURE DE L'AUDIT 1.3.1 TERMINÉE — EN ATTENTE DE LA DÉCISION ÉCRITE DU CEO**
