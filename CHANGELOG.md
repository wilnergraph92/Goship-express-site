# Journal des changements

Une entrée par mise en production (docs/production/releases.md). Ce fichier
n'est pas publié sur le site (`deploy.yml` l'exclut).

Les versions `site-AAAA.MM.JJ` désignent à la fois les pages et l'état de
`outils/` : la chaîne de migrations (`outils/migrations.txt`) à appliquer à la
base **avant** de publier le site.

## Non publié — Phases 11 et 12 (PR #13)

**Décision : NO-GO** (docs/production/go-no-go.md). À ne fusionner qu'après les
migrations en production.

### Pour les clients
- Notifications : chaque étape de colis, facture ou paiement crée une
  notification dans « Mon compte » (badge, filtres, lu) et dans l'application ;
  e-mail, WhatsApp et push partent de la base, avec nouvelles tentatives et
  préférences par canal.

### Pour l'équipe
- Onglet Notifications : règles (activer, canaux), centre des envois avec leur
  statut réel, envois d'un colis.
- Production : `sante()`, contrôles de sécurité et d'intégrité en lecture seule,
  sauvegarde chiffrée quotidienne (à mettre en service), surveillance toutes les
  30 minutes, documentation `docs/production/`.

### Base
- Migrations nouvelles : `supabase-notifications.sql`, `supabase-production.sql`.
- `supabase.sql` : la contrainte `notifications_canal_check` accepte `app` (la
  chaîne ne se rejouait plus sur une base ayant des notifications de la Phase 11).
- `supabase-code-client.sql`, `supabase-factures.sql`, `supabase-numero-facture.sql`
  refusent de s'exécuter sur une base à jour (`supabase-factures.sql` aurait remis
  une ancienne version de `mes_factures`).

### Publication
- `deploy.yml` ne publie plus `CLAUDE.md`, `CHANGELOG.md`, `.htaccess`, `_headers`,
  `_redirects`, refuse de publier un fichier de travail ou une clé secrète, et
  vérifie le site après publication.

### À faire à la main
- Suivre `docs/production/go-no-go.md`, actions A1 à A9.

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
