# Communication Center — dossier de conception

Ce dossier n'est pas publié (`deploy.yml` exclut `docs/`). Il réunit les livrables du projet
« Centre de communication » (WhatsApp, e-mail, campagnes), phase par phase, chacune approuvée par écrit
par le CEO avant la suivante.

| Fichier | Phase | État |
|---|---|---|
| `COMMUNICATION_CENTER_PHASE_0_AUDIT.md` | 0 — audit en lecture seule | approuvé le 18/11/2026 |
| `COMMUNICATION_CENTER_PHASE_1_RAPPORT.md` | 1 — rapport complet de la phase (résumé de tous les livrables) | en attente d'approbation |
| `COMMUNICATION_CENTER_ARCHITECTURE.md` | 1 — architecture, coûts, feuille de route, retour arrière | en attente d'approbation |
| `COMMUNICATION_CENTER_SECURITY.md` | 1 — permissions, menaces, exigences juridiques, risques | en attente d'approbation |
| `COMMUNICATION_CENTER_DATABASE.md` | 1 — tables, fonctions, place dans la chaîne | en attente d'approbation |
| `brouillons-sql/40…43-*.sql` | 1 — **brouillons jamais exécutés** | chaque fichier commence par une garde qui l'arrête |

**Les brouillons SQL ne font pas partie de la chaîne** (`outils/migrations.txt`) et ne doivent être
exécutés nulle part. En Phase 2, après accord du CEO, ils deviendront des fichiers de `outils/`, éprouvés
d'abord sur une base jetable.
