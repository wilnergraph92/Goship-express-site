# GO / NO-GO

## Décision du 26/09/2026 (finalisation) : **NO-GO**

Évaluée après la finalisation de la Phase 12. **Rien n'a été modifié en
production** : aucune migration, aucune donnée, aucun réglage. Tout ce qui
pouvait être outillé l'est ; ce qui reste demande les accès du propriétaire
(Supabase, GitHub, Apple, Google, fournisseurs de messages).

Règle : **GO seulement si C1 à C13 sont vérifiés sur la production elle-même.**
Un essai local, de démonstration ou de CI ne prouve pas l'état de la production.

### Par composant

| Composant | Verdict | Ce qui bloque |
|---|---|---|
| Base (Supabase) | **NO-GO** | B1 (2 migrations manquantes), B2, B3 |
| Site + tableau de bord | GO pour la version en ligne (Phase 10) ; **NO-GO** pour la Phase 11 | B1, B4 |
| Bureau | usage interne ; **NO-GO** pour une distribution publique | B7 |
| Mobile | **NO-GO** | B1, B6 |

## Ce qui a été observé sur la production (preuves)

| Date (UTC) | Moyen | Observé |
|---|---|---|
| 26/09 18:06 | `deploy.yml`, job `verifier` (`645e08a`) | 6 pages 200 ; aucune clé secrète publiée ; `CLAUDE.md`, `README.md`, SQL, `docs/`, `bureau/` en 404 ; HTTP → HTTPS ; Auth et suivi public répondent ; `sante()` absente |
| 26/09 18:44 | `surveillance.yml` lancée à la main sur `main` | vert |
| 26/09 18:47 | `audit-production.yml` (`sonder.sh`, clé publique, GET en lecture seule) | migrations **1 à 9 présentes** ; **`supabase-notifications.sql` et `supabase-production.sql` absentes** ; aucune fonction ouverte aux visiteurs sans raison ; Auth : **confirmation des adresses e-mail DÉSACTIVÉE**, inscriptions ouvertes, seul fournisseur : e-mail |

Limite de la sonde : une fonction témoin présente prouve que son fichier est
passé, pas qu'il l'est **dans sa dernière version**. Seul `controler.sh`
(accès à la base) le dit — action A4.

## Critères

| # | Critère | État | Preuve / manque |
|---|---|---|---|
| C1 | Secrets | **vérifié** | audit des deux dépôts et de tout leur historique ; barrière de `deploy.yml` ; contrôle du site publié (aucune clé secrète) ; `controle-paquet.mjs` (mobile). *Secret scanning* de GitHub : non vérifiable (outil indisponible sans GitHub Advanced Security) |
| C2 | Tests verts | **vérifié** | site : 10 bancs sur base réelle (dont `essai-production.py` 70/70, `essai-mobile.py` 87/87), démo, SQL ; mobile : 52/52, navigateur 84/84, Maestro Android et iOS ; bureau : installateurs Windows et macOS |
| C3 | Chaîne complète en production | **non rempli** | 9 sur 11 (sonde du 26/09 18:47) |
| C4 | Sécurité de la production | **partiel** | aucune fonction ouverte aux visiteurs (sonde) ; RLS, verrous, comptes, Vault : `controler.sh` jamais lancé en production |
| C5 | Intégrité de la production | **non vérifié** | `controler.sh` jamais lancé en production. NB : une base avec des lignes orphelines **ne se restaure pas** (clés étrangères) — C5 conditionne C6 |
| C6 | Sauvegarde + restauration réelle | **non rempli** | outils éprouvés (`essai-production.py` F et K) ; secrets non posés ; aucune sauvegarde de production n'existe |
| C7 | Préproduction | **non rempli** | outillée (`preproduction.yml`, profil EAS `staging`) ; le projet `goship-staging` n'existe pas |
| C8 | Auth de production | **non rempli** | confirmation des e-mails désactivée (observé) ; *Site URL* / *Redirect URLs* : non lisibles de l'extérieur |
| C9 | Surveillance | **partiel** | `surveillance.yml` vert sur `main` ; exécution planifiée pas encore observée ; seconde personne (`ALERTE_WEBHOOK`) et battement externe (`HEARTBEAT_URL`) prêts mais non posés ; `sante()` absente |
| C10 | Retour arrière | **partiel** | site : `git revert` + republication (mécanisme de `deploy.yml` éprouvé à chaque publication) ; base : restauration éprouvée hors production seulement ; jamais répété en conditions réelles |
| C11 | HTTPS | **vérifié** | contrôle du 26/09 18:06 |
| C12 | Mobile en test interne | **non rempli** | aucune soumission ; comptes Apple / Google non fournis |
| C13 | Bureau signé et notarisé | **non rempli** | signature prête (`electron-builder.distribution.js`, `bureau.yml`) ; aucun certificat |

## Bloqueurs et actions (dans l'ordre)

Chaque action a son outil ; aucune ne demande de coller un secret dans une
conversation. Les secrets se posent dans GitHub > Settings > Environments.

| # | Action (propriétaire) | Outil | Lève | Preuve attendue |
|---|---|---|---|---|
| A1 | Relever l'offre et les sauvegardes Supabase (Database > Backups) ; les noter dans backup.md | — | B3 (en partie) | capture ou note datée |
| A2 | Créer `goship-staging` ; environnement GitHub `staging` : secret `STAGING_DB_URL`, variables `STAGING_SUPABASE_URL`, `STAGING_SUPABASE_CLE` ; lancer **Préproduction** | `preproduction.yml` | B2 | job vert : chaîne 11/11, contrôles sans ALERTE, essai métier, sonde 11/11 |
| A3 | `age-keygen` ×2 (clé propriétaire hors ligne, clé d'épreuve) ; environnement `production` : `SUPABASE_DB_URL`, `SAUVEGARDE_DESTINATAIRE`, `RESTAURATION_DESTINATAIRE`, `RESTAURATION_CLE` ; lancer **Sauvegarde de la base** | `sauvegarde.yml` | B3 | job « Restauration d'épreuve » vert, résumé : âge (RPO) et durée (RTO) mesurés |
| A3b | Restaurer une fois la sauvegarde dans un **vrai** projet Supabase vide (temporaire), puis le supprimer | `restaurer.sh` (backup.md) | B3 | durée réelle notée dans backup.md |
| A4 | Lancer **Contrôles de la base de production** | `controles-production.yml` | B1, C4, C5 | journal : ALERTES éventuelles ; détail chiffré en artefact |
| A5 | Corriger en préproduction ce que A4 révèle ; puis, en production, **`supabase-notifications.sql` et `supabase-production.sql`** (sauvegarde du jour restaurée d'abord) | `appliquer-chaine.sh` avec `CONFIRMER_PRODUCTION`, ou SQL Editor | B1 | `audit-production.yml` : 11/11 ; `sante()` → `pret: true` |
| A6 | Auth : activer la confirmation des e-mails ; *Site URL* = adresse du site ; *Redirect URLs* sans `localhost` ; mot de passe ≥ 6 ; essayer « mot de passe oublié » et l'inscription avec une vraie boîte | Supabase > Authentication | B4 | `surveiller.sh` : « confirmation des adresses e-mail active » ; essai manuel noté |
| A7 | **Juste après A5** : fusionner la PR #13 (pages des notifications) | `deploy.yml` | — | contrôle après publication vert **sans avertissement** |
| A8 | Surveillance : secrets `ALERTE_WEBHOOK` (seconde personne) et `HEARTBEAT_URL` (Healthchecks.io) ; vérifier une exécution planifiée | `surveillance.yml` | B5 | message reçu lors d'un essai ; Healthchecks « up » |
| A9 | Mobile : comptes Apple Developer et Google Play ; `eas.json` profil `staging` rempli ; `eas build --profile staging` sur téléphone de test ; puis `production` en test interne (TestFlight, Play Internal) ; PR mobile #2 après A5 | EAS | B6 | build de test installé, parcours de fumée noté |
| A10 | Bureau : certificat Developer ID + mot de passe d'application Apple ; certificat de signature de code Windows ; secrets `MAC_CSC_LINK`, `MAC_CSC_KEY_PASSWORD`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`, `WIN_CSC_LINK`, `WIN_CSC_KEY_PASSWORD` ; relancer **Application de bureau** sur `main` | `bureau.yml` | B7 | `spctl` accepte, `stapler validate` OK, Authenticode `Valid` |
| A11 | GitHub : protection de `main` (PR obligatoire, `essais.yml` requis) ; *Secret scanning* et *Push protection* | Settings > Branches, Code security | M1, M2 | réglages visibles |

## Risques

### Moyens
| # | Risque | Traitement |
|---|---|---|
| M1 | `main` sans protection | A11 |
| M2 | *Secret scanning* non vérifié | A11 |
| M3 | Une seule personne reçoit les alertes | A8 (`ALERTE_WEBHOOK`) ; deuxième administrateur GitHub/Supabase |
| M4 | Adresse `github.io` : pas de bascule d'hébergeur | R3 |
| M5 | Fournisseurs de messages non vérifiés | mise en service prudente (deployment.md) |
| M6 | Suivi public sans limite de débit, numéros de colis consécutifs | database.md, « Suivi public » : pas de limite par fonction dans Supabase ; numéros au hasard prêts (partie facultative de `supabase.sql`) ; décision du propriétaire |
| M7 | Sauvegardes seulement dans GitHub | copie mensuelle hors ligne (backup.md) |
| M8 | ~~Actions citées par étiquette~~ | **corrigé** : épinglées par empreinte, Dependabot |
| M9 | Inscriptions ouvertes et confirmation désactivée : n'importe qui crée un compte avec n'importe quelle adresse | A6 |

### Faibles
L1 vulnérabilités modérées des outils de construction du mobile ; L3
identifiants du mode démonstration (sans effet en ligne) ; L4 pas de
prestataire de paiement intégré ; L5 journaux Supabase courts. L2 (fichiers
de configuration publiés) : **corrigé** le 26/09/2026.

## Recommandations (après GO)

R1 Supabase Pro + PITR · R2 ~~profil EAS staging~~ **fait** · R3 domaine
personnalisé du site · R4 domaine personnalisé Supabase · R5 SMTP personnalisé
(SPF, DKIM, DMARC) · R6 deux personnes avec tous les accès · R7 ~~surveillance
externe~~ **prête** (`HEARTBEAT_URL`) · R8 répétition annuelle de la reprise.

## Historique des décisions

| Date | Décision | Par | Motif |
|---|---|---|---|
| 26/09/2026 | NO-GO | évaluation de la Phase 12 | B1 à B7 |
| 26/09/2026 | NO-GO | finalisation | C3 (9/11), C6, C7, C8 (confirmation d'e-mail désactivée), C12, C13 non remplis ; C4, C5, C9, C10 partiels |
