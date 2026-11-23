# Communication Center — feuille de route vers la mise en service

**Établie le 23/11/2026 par Claude Code**, après la décision A : les candidates sont la base de la
Phase 2. Elle suit le plan officiel en 7 phases, sans nouvelle nomenclature. Les incréments sont
numérotés à la suite de C1–C7.3 et de 010. ✅ signale une étape faite et prouvée en local, ⏳ une étape
en cours ou à faire, 🔒 une étape qui exige une personne ou une autorisation nommée.

## Phase 1 — Architecture & security

| Étape | État |
|---|---|
| Décisions A–J prises sur délégation | ✅ `COMMUNICATION_CENTER_DECISIONS_DELEGUEES.md` |
| Hiérarchie des verrous des candidates | ✅ `COMMUNICATION_CENTER_VERROUS_CANDIDATES.md` |
| Questions Q1–Q7 adaptées aux candidates, version figée par empreinte | ⏳ |
| Revue indépendante humaine PostgreSQL | 🔒 la CEO envoie la demande de devis (D5 §6) |
| Validations juridiques (D2, STOP, conservation) | 🔒 juriste |

## Phase 2 — Database & backend (local)

| Étape | État |
|---|---|
| C8 — Arrêt d'urgence côté Admin, avec levée (candidate 010) | ✅ banc |
| C8 — Permissions `communications.*` alignées entre la chaîne officielle et `api.js` | ✅ `essai-permissions.py` 114/114 |
| C8 — Transmission de code par l'Edge soumise à l'arrêt d'urgence (009) | ✅ correction et essai ajoutés |
| C9 — Réglages N-02 et D2 décidés, installés comme réglages par défaut (`communication_consentement_reglages`) | ⏳ |
| C9 — Alertes D dans `communication_c5_sante` (`STOP_PENDING` > 2 min, transmission `incertain`, retour en attente > 10 min, échec prioritaire) | ⏳ |
| C10 — Non-régression transactionnelle avec les candidates appliquées (`essai-notifications.py`, `essai-accuses.py`, `essai-suivi-courriels.py`) | ⏳ |
| C10 — Plan d'essais adapté aux candidates, remplaçant les 78 essais | ⏳ |
| C11 — Intégration des candidates dans `outils/migrations.txt`, puis rejeu complet de la chaîne sur base jetable | ⏳ |

## Phase 3 — Email + WhatsApp

| Étape | État |
|---|---|
| Envoi marketing par l'outbox unique `notification_envois`, sous la porte P-07, avec consentement, fréquence N-01, quotas et budgets | ⏳ à construire (les brouillons 40–43 servent de référence) |
| Consentement marketing e-mail et lien de désinscription | ⏳ |
| Purge et conservation | ⏳ |
| Compte WhatsApp Business, modèles Meta, domaine d'envoi e-mail | 🔒 la CEO, auprès des fournisseurs |

## Phase 4 — Dashboard UI

| Étape | État |
|---|---|
| Boutons Admin d'arrêt d'urgence et de levée, relance automatique de la confirmation, affichage de `STOP_PENDING` | ⏳ |
| Alertes D visibles | ⏳ |
| Suivi des campagnes envoyées | ⏳ après la Phase 3 |

## Phase 5 — Automation

| Étape | État |
|---|---|
| Campagnes planifiées → envoi par le travailleur existant | ⏳ après la Phase 3 |

## Phase 6 — QA & deployment

| Étape | État |
|---|---|
| QA locale complète | ⏳ |
| Pile locale relancée sur `127.0.0.1`, procédure versionnée pour les vérifications sur Supabase local | ⏳ |
| Commit et pull request | 🔒 autorisation nommée |
| Staging, puis production : migration, Edge, secrets, `pg_cron` | 🔒 autorisation nommée, après la revue humaine et les validations juridiques |
