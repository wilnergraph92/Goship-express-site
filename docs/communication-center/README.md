# Communication Center — dossier de conception

Ce dossier n'est pas publié (`deploy.yml` exclut `docs/`). Il réunit les livrables du projet
« Centre de communication » (WhatsApp, e-mail, campagnes), phase par phase, chacune approuvée par écrit
par le CEO avant la suivante.

| Fichier | Phase | État |
|---|---|---|
| `COMMUNICATION_CENTER_PHASE_0_AUDIT.md` | 0 — audit en lecture seule | approuvé le 18/11/2026 |
| `COMMUNICATION_CENTER_PHASE_1_RAPPORT.md` | 1 — rapport de la phase (corrigé en 1.2 : mentions « [Corrigé 1.2] ») | remplacé par la conception 1.2 |
| `COMMUNICATION_CENTER_PHASE_1_1_RAPPORT.md` | 1.1 — revue indépendante, verdict ÉCHEC | référence des constats C, H, M, L |
| `COMMUNICATION_CENTER_PHASE_1_2_RAPPORT.md` | 1.2 — corrections, traçabilité, verdict (errata 1.3 en tête) | remplacé par la Phase 1.3 |
| `PHASE_1_3_FINAL_REPORT.md` | 1.3 — corrections techniques, verdict VALIDÉ SOUS CONDITIONS | remplacé par la Phase 1.3.1 |
| `PHASE_1_3_1_FINAL_INDEPENDENT_AUDIT.md` | Clôture 1.3.1 — vérification finale, revue indépendante comparée, risques, chiffres clients (71, Phase 0 : 69) ; **verdict NON VALIDÉ** | **en attente de la décision du CEO** |
| `PHASE_1_3_1_KILL_SWITCH_LOCK_PROOF.md` | Clôture 1.3.1 — verrous de l'arrêt fonction par fonction, preuve, hypothèses H1 à H6 et H4′ | en attente |
| `PHASE_1_3_1_SQL_40_43_SECURITY_REVIEW.md` | Clôture 1.3.1 — revue des migrations 40 à 43, séparation, constats S-01 à S-07 | en attente |
| `PHASE_1_3_1_FINAL_TEST_PLAN.md` | Clôture 1.3.1 — 25 essais (aucun exécuté) | en attente |
| `PHASE_1_3_1_ANALYSE_POST_AUDIT_P07_P08.md` | Après la clôture 1.3.1 — analyse en lecture seule des corrections P-07 (arrêt d'urgence), P-08 (retours fournisseurs), STOP et doublons ; aucune correction faite | **en attente de l'autorisation écrite du CEO** |
| `PHASE_1_3_1_FINAL_INDEPENDENT_REVIEWER_REPORT.md` | Clôture 1.3.1 — rapport du relecteur indépendant (RF-01 à RF-19), tel quel | référence |
| `PHASE_1_3_1_FINAL_REPORT.md` | 1.3.1 — audit indépendant, arrêt d'urgence ; verdict CONDITIONAL — INDEPENDENT REVIEW PENDING (complété par la clôture) | remplacé par la clôture |
| `PHASE_1_3_1_INDEPENDENT_SECURITY_AUDIT.md` | 1.3.1 — trois revues indépendantes, constats, risques ouverts | en attente |
| `PHASE_1_3_1_KILL_SWITCH_DESIGN.md` | 1.3.1 — arrêt d'urgence prouvé : verrous, scénarios, démonstration | en attente |
| `PHASE_1_3_1_SQL_DRAFT_CORRECTIONS.md` | 1.3.1 — corrections des brouillons, constat par constat | en attente |
| `PHASE_1_3_1_TEST_PLAN.md` | 1.3.1 — 40 essais (aucun exécuté) | en attente |
| `PHASE_1_3_TECHNICAL_CORRECTIONS.md` | 1.3 — diagnostic des huit problèmes, corrections, avant / après | en attente |
| `PHASE_1_3_SECURITY_REVIEW.md` | 1.3 — contre-revue, PostgreSQL, dépendances, PR #46 et #48 | en attente |
| `PHASE_1_3_TEST_PLAN.md` | 1.3 — essais T-01 à T-20 (aucun exécuté) | en attente |
| `COMMUNICATION_CENTER_ARCHITECTURE.md` | conception en vigueur (1.2, annotée « [Corrigé 1.3] ») | en attente |
| `COMMUNICATION_CENTER_SECURITY.md` | conception en vigueur (1.2, annotée « [Corrigé 1.3] ») | en attente |
| `COMMUNICATION_CENTER_DATABASE.md` | conception en vigueur (1.2, annotée « [Corrigé 1.3] ») | en attente |
| `COMMUNICATION_CENTER_TESTING.md` | plan d'essais (aucun exécuté) | en attente |
| `brouillons-sql/40…43-*.sql` | **brouillons jamais exécutés** (version 1.3.1) | garde à quatre couches : bloc DO, contenu dans une chaîne inerte, garde interne, fermeture de session pour un outil qui découpe le texte |

**Les brouillons SQL ne font pas partie de la chaîne** (`outils/migrations.txt`) et ne doivent être
exécutés nulle part. En Phase 2, après accord écrit du CEO, ils deviendront des fichiers de `outils/`,
éprouvés d'abord sur une base jetable.

**Règle de livraison (consigne du CEO, 18/11/2026)** : chaque phase se termine par un rapport complet,
en français, sur le modèle de celui de la Phase 0 (fichier rangé dans ce dossier).
