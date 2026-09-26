# Journal des changements

Une entrée par mise en production (docs/production/releases.md). Ce fichier
n'est pas publié sur le site (`deploy.yml` l'exclut).

Les versions `site-AAAA.MM.JJ` désignent à la fois les pages et l'état de
`outils/` : la chaîne de migrations (`outils/migrations.txt`) à appliquer à la
base **avant** de publier le site.

## Non publié — finalisation de la mise en production (26/09/2026)

Aucune page ne change, aucune donnée n'est modifiée. **Verdict : NO-GO**
(docs/production/go-no-go.md) — preuves nouvelles : 9 migrations sur 11 en
production ; confirmation des adresses e-mail désactivée.

- Audit anonyme de la production (`sonder.sh`, `audit-production.yml`).
- Contrôles de la production en lecture seule (`controler.sh`,
  `controles-production.yml`) : journal publiable, détail chiffré.
- Préproduction outillée (`preproduction.yml`, `appliquer-chaine.sh`,
  `essai-metier.sql` dans une transaction annulée) ; profil EAS `staging`
  (dépôt mobile).
- Restauration d'épreuve après chaque sauvegarde, RPO et RTO mesurés ;
  sauvegarde chiffrée pour deux destinataires ; définition des tables de comptes
  sauvegardée.
- Surveillance : CRITIQUE / ATTENTION, fonctions du site et de l'application,
  réglage de confirmation d'e-mail, seconde personne (`ALERTE_WEBHOOK`),
  battement externe (`HEARTBEAT_URL`).
- Bureau : signature Developer ID + notarisation et Authenticode dès que les
  certificats sont posés.
- Actions de GitHub épinglées par empreinte, Dependabot.
- Essais : `essai-production.py` 70/70 (H à K nouvelles), `essai-mobile.py` 87/87
  (section Z), mobile 52/52.

## Non publié — pages de la Phase 11 (PR #13)

**À fusionner juste après `supabase-notifications.sql` en production**
(docs/production/deployment.md, « Une exception »).

- Clients : notifications dans « Mon compte » (badge, filtres, lu, préférences)
  et dans l'application.
- Équipe : onglet Notifications (règles, centre des envois, envois d'un colis) ;
  le dialogue d'un colis n'envoie plus lui-même d'e-mail ni de WhatsApp.
- Essais : `essai-notifications.py` / `.js`, remis dans `essais.yml`.

## site-2026.09.26 — outillage de production (publié le 26/09/2026)

Aucune page du site ne change, et **aucune migration n'a été exécutée** en
production. Verdict de mise en production : **NO-GO** (docs/production/go-no-go.md).

### Publication
- `deploy.yml` ne publie plus `CLAUDE.md`, `CHANGELOG.md`, `.htaccess`, `_headers`,
  `_redirects` ; refuse de publier un fichier de travail ou une clé secrète ;
  vérifie le site publié (`surveiller.sh`).
- `surveillance.yml` : toutes les 30 minutes. `essais.yml` : tous les bancs
  d'essai à chaque PR. `sauvegarde.yml` : chaque jour, une fois ses secrets posés.

### Base (fichiers seulement, à exécuter selon docs/production/deployment.md)
- `outils/migrations.txt` : la chaîne officielle.
- `supabase-notifications.sql` (Phase 11) et `supabase-production.sql` (`sante()`).
- `supabase.sql` : la contrainte `notifications_canal_check` accepte `app` (la
  chaîne ne se rejouait plus sur une base ayant des notifications de la Phase 11).
- `supabase-code-client.sql`, `supabase-factures.sql`, `supabase-numero-facture.sql`
  refusent de s'exécuter sur une base à jour (`supabase-factures.sql` aurait remis
  une ancienne version de `mes_factures`).

### Outils et documentation
- `outils/production/` : contrôles de sécurité et d'intégrité (lecture seule),
  sauvegarde chiffrée et restauration, surveillance.
- `docs/production/` : GO / NO-GO, runbook, déploiement, sauvegarde, reprise,
  surveillance, incidents, retour arrière, versions, dépannage.

### À faire à la main
- `docs/production/go-no-go.md`, actions A1 à A9.

## Déjà sur `main` (avant le 26/09/2026, jamais étiqueté)

Publié sur GitHub Pages au fil des fusions, sans version ni étiquette. L'état de
la base de production par rapport à ces changements n'est **pas connu**
(go-no-go.md, B1).

| Phase | Changement | Migration |
|---|---|---|
| 1 | Générateur des pages, factures imprimables, étiquettes 4×6, QR et Code128 | — |
| 2 | Règles des colis et des factures appliquées par la base | `supabase-services.sql` |
| 3 | Événements de colis ; le statut ne change que par eux | `supabase-evenements.sql` |
| 4 | Poste de scan | `supabase-scanner.sql` |
| 5 | Paiements, soldes, annulations, regroupement de factures | `supabase-finances.sql` |
| 6 | Rôles employé / gérant / administrateur et permissions | `supabase.sql` (partie 4) |
| 7 | Vue générale du tableau de bord, recherche rapide ; nouvel habillage | `supabase-tableau-de-bord.sql` |
| 8 | Analytics | `supabase-analytics.sql` |
| 9 | Application de bureau Windows / macOS (1.0.0) | — |
| 10 | Pré-alerte sans doublon pour l'application mobile | `supabase-mobile.sql` |

Application mobile (dépôt `goship-express-app`) : version de production 1.0.0
(build 1) fusionnée le 26/09/2026, **pas encore publiée** sur les boutiques.
