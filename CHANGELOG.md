# Journal des changements

Une entrée par mise en production (docs/production/releases.md). Ce fichier
n'est pas publié sur le site (`deploy.yml` l'exclut).

Les versions `site-AAAA.MM.JJ` désignent à la fois les pages et l'état de
`outils/` : la chaîne de migrations (`outils/migrations.txt`) à appliquer à la
base **avant** de publier le site.

## site-2026.09.28.3 — tableau de bord : onglet « Rapport » (non publié)

Migration **à passer par le propriétaire avant de publier** : `supabase.sql` (les
permissions `reports.create`, `reports.edit`, `reports.delete`), puis toute la chaîne
dans l'ordre jusqu'au nouveau `supabase-rapports.sql` (outils/migrations.txt).
`supabase-rapports.sql` ajoute une table (`rapports`), trois index et des fonctions ; il
ne change aucune donnée. Sans lui, l'onglet répond « La base n'est pas à jour ».

- Onglet « Rapport » (administrateur, gérant) : période, statut du colis, état de la
  facture, type ; cartes (colis, factures, payé, impayé, annulé, supprimées, encaissé,
  clients, activité) ; colis, étapes, factures (et supprimées), paiements, clients,
  activité du journal d'audit, page par page.
- Rapports enregistrés : créer (administrateur, gérant), modifier et supprimer
  (administrateur), détails, voir, imprimer, PDF ; journalisés.
- Impression A4 portrait ou paysage : logo, en-tête, pied de page numéroté.

## site-2026.09.28.2 — tableau de bord : actions dans la fiche seulement (publié le 28/09/2026)

Aucune migration, aucune donnée modifiée.

- Colis, clients, factures : les boutons quittent les lignes (Mettre à jour, Voir la
  facture, Étiquette ; Ses colis, Ses factures, + Colis ; Encaisser, Imprimer,
  Détails, WhatsApp, Annuler). Ils ne sont plus que dans la fiche qu'un clic sur la
  ligne ouvre, avec les mêmes permissions.

## site-2026.09.28 — tableau de bord : fiches complètes, destinations réelles (publié le 28/09/2026)

Aucune migration nouvelle (celle de `site-2026.09.27.3` reste à relancer pour le
filtre « Agence »). Aucune donnée modifiée.

- Destination : seulement les villes que les colis vers le pays choisi portent
  vraiment, rangées par département ou province ; plus aucune ville sans colis.
- Filtre Statut : affichage rendu identique à avant le 27/09 (« (0) » compris).
- Fiche d'un colis par sections : informations générales et code-barres,
  destinataire, expéditeur, colis, parcours, historique complet ; « Modifier » en
  plus, chaque action selon les permissions du rôle.
- Fiches d'une facture (colis facturés, paiements, montants), d'un client (derniers
  colis, factures, paiements, lus à l'ouverture) et d'un paiement reçu.
- Poste de scan : « Fiche complète » ouvre la fiche du colis scanné.
- Langue : les traductions du tableau de bord rejoignent les dictionnaires du site
  (`outils/traductions/`) ; les mots déjà traduits sur le site sont repris tels quels.

## site-2026.09.27.3 — tableau de bord : filtres fixes, fiche d'une ligne, langue (publié le 27/09/2026)

Migration en lecture seule **à relancer par le propriétaire**, sans urgence :
`supabase-analytics.sql` puis `supabase-mobile.sql` (SQL Editor, « Copy raw file »).
Elle ajoute la clé de filtre `agence` et, dans les choix des filtres, le pays de
chaque ville et le nombre de colis par agence ; aucune table, aucune donnée, aucune
règle ne change. Tant qu'elle n'est pas passée, le filtre « Agence » reste désactivé
(la page le dit) et les villes des colis s'ajoutent sous chaque pays.

- Filtres de la vue générale : Pays (Haïti, Santo Domingo, USA), Destination (toutes
  les villes du pays choisi : communes d'Haïti, municipalités dominicaines, plus
  celles des colis), Mode (aérienne, maritime, terrestre), Statut (inchangé), Agence
  (USA : au dépôt de Miami ; Haïti, Santo Domingo : arrivé dans le pays).
- Un clic sur une ligne ouvre sa fiche, dans tous les onglets. Un colis : client,
  route, mode, poids, montant, lieu, dates, parcours en sept étapes datées, et
  « Mettre à jour », « Voir la facture », « Étiquette », « Voir le client ». Clients,
  factures, paiements, équipe, analytics, scanner : leurs colonnes et leurs boutons.
  La recherche rapide et les « Ouvrir » de la vue générale ouvrent aussi la fiche.
- Sélecteur de langue dans la barre (FR, EN, ES, HT), gardé sur l'appareil.
- Les régions et villes de l'espace client passent dans `assets/js/lieux.js`,
  partagé avec le tableau de bord (aucun changement visible).

## site-2026.09.27.2 — tableau de bord : filtres, apparence, direct, disposition (publié le 27/09/2026)

Migration en lecture seule, appliquée en production le 27/09/2026 avant la
publication : `supabase-analytics.sql` relancé (contrôle de fin : 15 | 8 | 0 | true),
puis `supabase-mobile.sql` (contrôle : 1 | false | 2 | 1). Elle ajoute
`vue_generale_filtree` et ses aides ; aucune table, aucune donnée, aucune règle ne
change. Une base sans elle garde un tableau de bord entier, filtres désactivés.
Barre du haut : sur une ligne jusqu'à 1365 px (elle passait sur deux lignes à 1280 px).

- Correction : le menu latéral défilait avec la page et laissait un blanc dessous
  (la vue générale portait par erreur la classe à hauteur fixe de l'aperçu d'e-mail,
  depuis `site-2026.09.27`). Il reste fixe sur toute la hauteur.
- Menu en trois groupes : Opérations, Finance (dont « Encaissements », le module
  Finances des Analytics), Gestion.
- Vue générale : filtres par pays, destination, mode de transport, statut et agence
  (lieu actuel du colis), comptés par la base ; les cartes que les filtres ne
  découpent pas le disent.
- Direct : état (en direct, mise à jour chaque minute, en pause), heure des chiffres,
  « Suspendre / Reprendre le direct ».
- « Personnaliser » : blocs affichés et leur ordre, gardés sur l'appareil.
- Apparence claire, sombre ou système (engrenage de la barre, ou Réglages), et
  animations au défilement avec un léger relief, coupées par le réglage
  « Animations » ou quand le système demande moins d'animations.

## site-2026.09.27 — nouvelle vue générale du tableau de bord (publié le 27/09/2026)

Aucune migration, aucune donnée modifiée : la page ne lit que `vue_generale` et les
Analytics, déjà en production.

- Tableau de bord : la vue générale reprend la maquette Claude Design « GoShip
  Dashboard » aux couleurs du logo (bleu nuit, orange, bleu), sur tous les écrans.
  Chiffres de `vue_generale` et, pour les comptes qui voient les rapports, des
  Analytics (comparaison à la période précédente, routes, villes, clients actifs).
  Les blocs de la maquette sans donnée dans la base (marge, agences, filtres par
  mode de transport, « mises à jour simulées ») n'ont pas été repris.

## site-2026.09.26.2 — finalisation de la mise en production (publié le 26/09/2026)

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
