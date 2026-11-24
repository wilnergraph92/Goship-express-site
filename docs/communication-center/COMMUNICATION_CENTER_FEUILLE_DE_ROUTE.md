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
| Questions Q1–Q7 adaptées aux candidates, version figée par empreinte | ✅ `COMMUNICATION_CENTER_DOSSIER_REVUE_CANDIDATES.md` (11 empreintes SHA-256, points R-1 à R-8 à examiner en priorité) ; commit de la version figée : **`c7702cb5afa4f4fde14500072b5c4762619606ae`** (23/11/2026) |
| Revue indépendante humaine PostgreSQL | 🔒 la CEO envoie la demande de devis (D5 §6) |
| Validations juridiques (D2, STOP, conservation) | 🔒 juriste |

## Phase 2 — Database & backend (local)

| Étape | État |
|---|---|
| C8 — Arrêt d'urgence côté Admin, avec levée (candidate 010) | ✅ banc |
| C8 — Permissions `communications.*` alignées entre la chaîne officielle et `api.js` | ✅ `essai-permissions.py` 114/114 |
| C8 — Transmission de code par l'Edge soumise à l'arrêt d'urgence (009) | ✅ correction et essai ajoutés |
| C9 — Réglages N-02 et D2 décidés, installés comme réglages par défaut (candidate 011) | ✅ banc |
| C9 — Alertes D dans `communication_c5_sante` (arrêt non confirmé > 2 min, retour en attente > 10 min, en plus des transmissions incertaines et des échecs prioritaires) ; libellés traduits en 4 langues | ✅ banc |
| C9 — Supervision corrigée : lecture de l'outbox unique avec ses statuts réels et de la tâche `goship-notifications` (002) | ✅ banc |
| C10 — Non-régression transactionnelle avec les candidates appliquées : harnais `essai-communication-non-regression.py` (rejoue `essai-notifications.py`) ; 5 régressions corrigées | ✅ 87/87 après la décision K ; le nom `LIMITE_DEBIT` (au lieu de `HTTP_429`) y est reconnu comme écart volontaire, nommé et limité à sa valeur exacte |
| C10 — Étendre le harnais à `essai-accuses.py`, `essai-suivi-courriels.py` et `essai-programmes.py` (candidates appliquées après le fichier dont chaque essai éprouve la mise à niveau, puis après chaque fichier rejoué) | ✅ 36/36, 49/49 et 374/374 : aucune régression |
| C10 — Plan d'essais adapté aux candidates, remplaçant les 78 essais | ✅ `COMMUNICATION_CENTER_PLAN_ESSAIS_CANDIDATES.md` : 18 couverts, 11 partiels, 4 à écrire, 2 hors local, 3 sans objet avant la Phase 3 ; 9 essais à écrire (E-01 à E-09) |
| C11 — Intégration des candidates dans `outils/migrations.txt`, puis rejeu complet de la chaîne sur base jetable (autorisée par la CEO le 23/11/2026) | ✅ en local : chaîne de 50 fichiers ; garde-fou dans `appliquer-chaine.sh` (arrêt avant les candidates, refus en production), sonde et contrôle de sécurité (« réservées aux essais »), critère C14 de `go-no-go.md` ; 3 défauts corrigés ; banc 528/528, production 153/153, non-régression 36/36, 49/49 et 374/374, parcours WhatsApp 74/74, Node 9/9, 7/7 et 23/23, 30 bancs officiels sur 32 verts (analytics et mobile échouent de la même façon sans C11 sur ce Mac : temps et fuseau) |

## Phase 3 — Email + WhatsApp

| Étape | État |
|---|---|
| Envoi marketing par l'outbox unique `notification_envois`, sous la porte P-07, avec consentement, fréquence N-01, quotas et budgets | ✅ candidate 012 (24/11/2026), banc 646/646, image Supabase réelle 33/33 ; fréquence N-01 à régler par l'Admin (aucune valeur par défaut) |
| Consentement marketing e-mail et lien de désinscription | ✅ candidate 012 ; `desabonnement.html` (4 langues), en-tête `List-Unsubscribe` |
| Purge et conservation | ⏳ |
| Offres côté client : accord e-mail et WhatsApp depuis « Mon compte » | ✅ `offres.js`, panneau « Offres et nouvelles » (4 langues) |
| Compte WhatsApp Business, modèles Meta, domaine d'envoi e-mail | 🔒 la CEO, auprès des fournisseurs |

## Phase 4 — Dashboard UI

| Étape | État |
|---|---|
| Boutons Admin d'arrêt d'urgence et de levée, relance automatique de la confirmation, affichage de `STOP_PENDING` | ✅ `communications-arret.js` (24/11/2026) |
| Alertes D visibles | ✅ vue générale du Centre de communication |
| Suivi des campagnes envoyées | ✅ `communications-envoi.js` : mis en file, exclus par motif, transmissions, annulations |

## Phase 5 — Automation

| Étape | État |
|---|---|
| Campagnes planifiées → envoi par le travailleur existant | ✅ `communication_campagnes_lancer` (pg_cron chaque minute) puis `traiter_notifications` |

## Phase 6 — QA & deployment

| Étape | État |
|---|---|
| QA locale complète | ⏳ |
| Pile locale relancée sur `127.0.0.1`, procédure versionnée pour les vérifications sur Supabase local | ⏳ |
| Commit et pull request | 🔒 autorisation nommée |
| Staging, puis production : migration, Edge, secrets, `pg_cron` | 🔒 autorisation nommée, après la revue humaine et les validations juridiques |
