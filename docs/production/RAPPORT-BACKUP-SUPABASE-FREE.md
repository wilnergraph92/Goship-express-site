# Rapport — sauvegarde autonome de la base GoShip Express (Supabase Free)

Date : 27/09/2026. Branche de travail partie de `main` (`f0fdcdf`). Rien n'a été exécuté
contre la base de production : aucune connexion, aucune migration, aucune donnée lue
ou modifiée. Ce conteneur ne peut d'ailleurs pas joindre la production (réseau bloqué).

Niveaux de preuve utilisés :

- **IMPLEMENTED** : le code existe ;
- **TESTED LOCALLY** : syntaxe, `shellcheck`, `actionlint` ;
- **TESTED ON DISPOSABLE DATABASE** : exécuté pour de vrai sur une base PostgreSQL jetable
  qui porte toute la chaîne de migrations GoShip et des données d'essai ;
- **TESTED ON STAGING** : sur goship-staging (le projet n'existe pas encore) ;
- **VERIFIED ON PRODUCTION** : sur la vraie base.

## 1. Résumé

Le système de sauvegarde existait déjà (Phase 12). Il n'avait **jamais fonctionné** :
son unique exécution (26/09/2026, lancée à la main) avait **sauté la sauvegarde** faute
de secrets, et s'était pourtant affichée **verte**. Il n'avait pas de stockage externe
(artefacts GitHub seulement), pas de rétention, pas d'empreinte des fichiers chiffrés
ni de garde-fou sur la cible de restauration. Son épreuve de restauration aurait échoué
au premier vrai passage (publication `supabase_realtime` créée deux fois).

Il est maintenant complété, sans changer de technologie (Supabase Free, PostgreSQL,
GitHub Actions, age, rclone). Toute la chaîne est **éprouvée sur une base jetable**,
106 vérifications sur 106. Il **n'est pas encore en service** : aucune sauvegarde de
production n'existe tant que les actions manuelles (section 16) ne sont pas faites et
qu'un passage n'est pas vert de bout en bout.

## 2. Architecture avant

```
GitHub Actions (sauvegarde.yml, 5 h 23 UTC)
   → secrets absents → « avis », job VERT, rien de fait
   (sinon : pg_dump → age → artefact GitHub 90 jours → épreuve sur PostgreSQL jetable)
```

## 3. Architecture après

```
Supabase PostgreSQL (Session pooler)
  → sauvegarder.sh : connexion vérifiée, pg_dump -Fc (public + auth.users/identities),
    relecture (pg_restore --list), tailles, structure, age (2 clés), SHA-256
  → verifier-sauvegarde.sh : fichiers, tailles, SHA-256, en-tête age
  → stocker.sh : rclone → destination A (+ B), chaque fichier relu (SHA-256), jamais remplacé
  → stocker.sh retention 7 (garde-fous)
  → artefact GitHub 7 jours (secours)
  → restauration d'épreuve : retéléchargement depuis A, epreuve-restauration.sh
    (vérification + déchiffrement, restaurer.sh, chaîne, verifier-restauration.sh),
    rapport PASS/FAIL, durées réelles (RTO), âge de la copie (RPO)
  → tout échec : workflow ROUGE + alerter.sh (ALERTE_WEBHOOK)
restauration-test.yml : à la demande, une sauvegarde choisie → essai ou staging
```

Le domaine du site n'intervient nulle part (section 10).

## 4. Fichiers créés

| Fichier | Rôle |
|---|---|
| `outils/production/verifier-sauvegarde.sh` | vérifie une sauvegarde, avec ou sans clé |
| `outils/production/stocker.sh` | stockage externe rclone : envoyer (relu), lister, récupérer, rétention |
| `outils/production/verifier-restauration.sh` | vérifie une base restaurée, en lecture seule |
| `outils/production/epreuve-restauration.sh` | épreuve complète chronométrée (appelée par les deux workflows) |
| `outils/production/alerter.sh` | ALERTE_WEBHOOK (Slack, Discord, ntfy) |
| `.github/workflows/restauration-test.yml` | test de restauration manuel (essai ou staging) |
| `outils/README-backup.md` | le guide complet (architecture, secrets, procédures, rotation, RPO/RTO, limites) |
| `docs/production/RAPPORT-BACKUP-SUPABASE-FREE.md` | ce rapport |

Noms demandés et noms retenus : les scripts vivent dans `outils/production/`, à côté de
`sauvegarder.sh` et `restaurer.sh` qui existaient déjà (pas de doublon) ;
`verifier-sauvegarde.sh` et `verifier-restauration.sh` portent les noms demandés ;
`sauvegarde.yml` existait et a été repris.

## 5. Fichiers modifiés

| Fichier | Changement |
|---|---|
| `outils/production/sauvegarder.sh` | connexion vérifiée (message sans mot de passe), structure et taille contrôlées, SHA-256 des fichiers chiffrés, nom à la seconde, nombre de comptes dans le manifeste |
| `outils/production/restaurer.sh` | `RESTORE_TARGET` obligatoire, `RESTORE_CONFIRM` pour la production, refus de la base en service, SHA-256 vérifié avant de déchiffrer |
| `.github/workflows/sauvegarde.yml` | rouge si un secret manque, stockage externe, rétention, épreuve depuis le stockage, rapport, alerte |
| `.github/workflows/essais.yml` | `rclone` installé pour le banc « production » |
| `outils/essais-services/essai-production.py` | section L (36 vérifications), sections F et K adaptées |
| `.gitignore` | formes d'une sauvegarde ignorées (`*.dump`, `*.backup`, `*.age`, `*.age.sha256`, `*.sql.gz`, `rclone.conf`, dossiers de travail) ; **pas** `*.sql` : les migrations `outils/*.sql` sont versionnées et doivent le rester |
| `docs/production/backup.md`, `environment.md`, `secrets.md`, `runbook.md`, `README.md`, `CLAUDE.md`, `CHANGELOG.md`, `outils/essais-services/LISEZ-MOI.md` | état réel, commandes à jour, secrets, domaine de production |

Aucune migration, aucune page du site, aucun code métier modifié.

## 6. Secrets nécessaires (noms seulement)

Environnement GitHub `production` : `SUPABASE_DB_URL` (Session pooler),
`SAUVEGARDE_DESTINATAIRE`, `RESTAURATION_DESTINATAIRE`, `RESTAURATION_CLE`,
`SAUVEGARDE_RCLONE_CONFIG`, `SAUVEGARDE_STOCKAGE`, et facultatif
`SAUVEGARDE_STOCKAGE_B`. Dépôt : `ALERTE_WEBHOOK` (facultatif, existant). Environnement
`staging`, pour une restauration vers la préproduction : `STAGING_DB_URL` et les mêmes
`RESTAURATION_CLE`, `SAUVEGARDE_RCLONE_CONFIG`, `SAUVEGARDE_STOCKAGE`. Détail :
`outils/README-backup.md`, B.

## 7. Tests effectués

| Test | Niveau | Résultat |
|---|---|---|
| `bash -n` des 7 scripts de sauvegarde | TESTED LOCALLY | OK |
| `shellcheck -S warning` des 7 scripts | TESTED LOCALLY | 0 avertissement |
| `actionlint` 1.7.12 (avec shellcheck) sur `sauvegarde.yml`, `restauration-test.yml`, `essais.yml` | TESTED LOCALLY | 0 erreur |
| `essai-production.py` complet (sections A à L) | TESTED ON DISPOSABLE DATABASE | **106/106** |
| … dont la section L, sauvegarde autonome | TESTED ON DISPOSABLE DATABASE | **36/36** |
| Le même essai dans GitHub Actions (`essais.yml`, banc « Base — production », ubuntu-latest, `rclone` du paquet Ubuntu), commit `f850c27` | TESTED ON DISPOSABLE DATABASE (CI) | **106/106**, job 108560447838 |
| `sauvegarde.yml` réel dans GitHub Actions, sans secrets (lancé à la main sur la branche) | GitHub Actions, sans base | **rouge** à « Secrets posés ? », rien tenté contre la base, job « Alerte en cas d'échec » lancé ; exécution 36298048867 |
| Recherche de secrets (`git grep` : clés age privées, chaînes de connexion avec mot de passe, `sb_secret_`, jetons GitHub, clés AWS) | TESTED LOCALLY | aucun |
| Recherche du domaine du site dans les scripts et workflows de sauvegarde | TESTED LOCALLY | aucun (`github.io`, `/Goship-express-site/`, `goshipexpress`) |
| Sauvegarde, stockage, restauration sur staging | TESTED ON STAGING | **non exécutable** : goship-staging n'existe pas |
| Sauvegarde réelle de la production, envoi, restauration | VERIFIED ON PRODUCTION | **non exécuté** : secrets et stockage non posés |

## 8. Tests réussis (section L, base jetable : 16 tables, 334 lignes, 4 comptes)

Toutes ces valeurs sortent de l'exécution réelle du 27/09/2026 :

```
BACKUP FOUND:      OK   goship-2026-09-27T054156Z (3 fichiers chiffrés + 3 empreintes)
SIZE:              OK   public 521KB comptes 4.1KB manifeste 1.3KB
CHECKSUM:          OK   SHA-256 des 3 fichiers chiffrés conforme
ENCRYPTION:        OK   en-tête age sur les 3 fichiers, aucun en clair
DECRYPTION:        OK   3 fichiers déchiffrés avec la clé fournie
MANIFEST:          OK   empreintes du clair identiques au manifeste
DUMP STRUCTURE:    OK   16 tables, 174 fonctions, 25 déclencheurs, 27 règles RLS, 16 clés étrangères
DATABASE CONNECTION: OK   PostgreSQL 16.2
TABLE COUNT:       OK   16 tables dans public, dont les 10 tables GoShip principales
RLS:               OK   activée sur les 16 tables, 27 règles
FUNCTION COUNT:    OK   174 fonctions dans public, dont les 10 dont dépendent le site et l'application
CONSTRAINT CHECK:  OK   16 clés primaires, 16 clés étrangères, 5 uniques, 29 CHECK, toutes validées
BUSINESS LOCKS:    OK   4 verrous actifs ; 25 déclencheurs dans public
DATA CHECK:        OK   334 lignes lues, identiques au manifeste table par table, aucun orphelin
AUTH ACCOUNTS:     OK   4 comptes (auth.users), comme dans la sauvegarde, chaque profil a son compte
RESTORE:           OK   RESTORE_TARGET=essai, lignes identiques au manifeste, chaîne rejouée
FINAL RESULT:      PASS
```

Et, dans la même section :

- base injoignable : échec, mot de passe jamais affiché ;
- vérification sans clé, avec clé, avec une autre clé (échec) ;
- un octet altéré : `CHECKSUM FAIL`, restauration refusée avant déchiffrement ;
- envoi vers deux destinations rclone, relu (SHA-256) ; destinations jamais écrites en
  entier dans le journal ; renvoi identique sans effet ; un autre contenu sous le même
  nom jamais remplacé ; copie locale altérée refusée avant envoi ;
- rétention : « garder 5 » refusé ; 11 sauvegardes complètes → 8 puis 7 (3 suppressions
  au plus par passage), la plus récente gardée, l'ancienne incomplète supprimée, un
  fichier étranger épargné, la destination B (1 sauvegarde) intacte ;
- téléchargement de « derniere » ; copie distante altérée : téléchargement refusé ;
- garde-fous : sans `RESTORE_TARGET`, production sans confirmation, base en service,
  sauvegarde altérée — refusés, rien restauré ;
- base restaurée avec un verrou coupé : `BUSINESS LOCKS FAIL` ; base au bon schéma mais
  sans données : `DATA CHECK FAIL`, `AUTH ACCOUNTS FAIL` (le piège d'une fausse réussite,
  trouvé et corrigé pendant ce travail) ;
- `epreuve-restauration.sh`, tel que l'appellent les workflows, sur une base vide :
  PASS ; il refuse `RESTORE_TARGET=production` ;
- aucune clé privée, aucun mot de passe, aucune destination dans les journaux ; aucun
  fichier en clair laissé.

Défauts trouvés par ces essais et corrigés avant de livrer : l'option `--immutable` de
rclone laissait remplacer un fichier distant de même taille (remplacée par une
vérification explicite) ; une comparaison en erreur passait pour « aucun écart » ; une
requête dépendait du support XML de PostgreSQL (absent de certaines installations) ;
la publication `supabase_realtime` créée deux fois dans l'épreuve.

## 9. Tests non exécutables ici

- Toute exécution contre la production ou goship-staging (pas de secrets, pas de réseau
  vers Supabase depuis ce conteneur, projet de staging inexistant).
- Un vrai passage de `sauvegarde.yml` et de `restauration-test.yml` dans GitHub
  Actions **avec** secrets : la connexion au Session pooler et la lecture de
  `auth.users` par l'utilisateur de la chaîne de connexion ne sont donc **pas
  prouvées** (le paquet `rclone` d'Ubuntu, lui, l'est : banc « production » en CI).
- Un vrai fournisseur de stockage (Backblaze B2, Drive, R2…) : rclone a été éprouvé
  avec son stockage local ; le chemin vers un fournisseur n'est pas testé.
- La restauration dans un vrai projet Supabase (schéma `auth` réel, extensions, Vault).

## 10. Limites de Supabase Free (et ce que le système y répond)

- Aucune sauvegarde fournie, pas de PITR → sauvegarde quotidienne externe, RPO ≈ 24 h.
- Connexion directe en IPv6 seulement → `SUPABASE_DB_URL` = Session pooler (port 5432).
- Projet mis en pause après une période d'inactivité → `pg_dump` échoue, workflow rouge,
  alerte. Rien ne garantit que la sauvegarde quotidienne évite la pause.
- La sauvegarde **n'est pas** une copie complète de Supabase : pas de Storage, de Vault,
  de configuration Auth, de sessions, de tâches pg_cron, de clés API
  (`outils/README-backup.md`, J, avec la façon de retrouver chacun).
- Domaine : les scripts ne parlent qu'à PostgreSQL et au stockage. Aucun ne contient
  `wilnergraph92.github.io`, `/Goship-express-site/` ni `goshipexpress.net` (vérifié par
  recherche). Le passage à `https://www.goshipexpress.net` ne les touche pas ; la
  configuration Auth correspondante (Site URL, Redirect URLs, `site_url` du Vault) est
  décrite à part dans `docs/production/environment.md`, « Domaine de production », sans
  domaine personnalisé Supabase (option payante, inutile).

## 11. Procédure de sauvegarde

Automatique chaque jour à 5 h 23 UTC ; manuelle : Actions > *Sauvegarde de la base* >
*Run workflow*. Détail : `outils/README-backup.md`, D.

## 12. Procédure de restauration

Test : Actions > *Test de restauration* (cible `essai` ou `staging`). Réelle : ordinateur
de confiance, `stocker.sh recuperer`, `restaurer.sh` avec `RESTORE_TARGET`, chaîne,
Vault, Auth, contrôles. Urgence : `outils/README-backup.md`, F, et
`docs/production/disaster-recovery.md`.

## 13. RPO

Une sauvegarde par jour : **jusqu'à environ 24 heures** de modifications peuvent être
perdues. Chaque passage publie l'âge réel de la copie vérifiée (`BACKUP AGE (RPO)`).

## 14. RTO réel mesuré

- **Base jetable** (334 lignes) : téléchargement 0,5 s + vérification/déchiffrement
  0,2 s + restauration 0,5 s + chaîne 0,3 s + validation 0,5 s = **1,9 s**. Ce chiffre
  ne vaut **que** pour cette base d'essai.
- **Production : non mesuré.** Il le sera à chaque passage de `sauvegarde.yml`
  (`RESTORE DURATION`, par étape) dès que les secrets seront posés. Aucune valeur n'est
  avancée avant.

## 15. Risques restants

1. **Aujourd'hui, aucune sauvegarde de production n'existe.** Une perte de la base
   serait définitive.
2. Perte des deux clés privées age → toutes les sauvegardes illisibles.
3. Le premier passage réel peut révéler un point non éprouvable ici (droits de lecture
   de `auth.users` via le pooler, paquet rclone, fournisseur) : il sera rouge et
   l'alerte partira, rien ne se fera en silence.
4. Une seule destination tant que B n'est pas posée : une fermeture de compte chez le
   fournisseur emporterait les 7 copies (l'artefact GitHub de 7 jours reste).
5. Restauration dans un vrai projet Supabase jamais faite.
6. La documentation du site cite par endroits `goshipexpress.com` (README : exemples de
   `site_url`, expéditeur) alors que le domaine annoncé est `goshipexpress.net` : à
   harmoniser le jour du passage (hors du périmètre des sauvegardes).

## 16. Actions manuelles nécessaires (propriétaire)

1. Générer les deux paires de clés age ; ranger la clé du propriétaire en deux endroits
   hors ligne (README-backup, C.1).
2. Créer le stockage externe gratuit (A ; B conseillé), bucket privé, clé d'accès
   limitée, cycle de vie « dernière version seulement » (C.2), et le `rclone.conf`
   (C.3).
3. Poser les secrets de l'environnement `production` (B), `SUPABASE_DB_URL` en Session
   pooler ; environnement limité à la branche `main`.
4. Publier ces changements sur `main` (le planning quotidien ne tourne que depuis
   `main`), puis lancer *Sauvegarde de la base* à la main : les deux jobs doivent être
   verts ; reporter la date, le RPO et le RTO mesurés dans `docs/production/backup.md`.
5. Lancer *Test de restauration* (cible `essai`, source A, puis B si posée).
6. Une fois par trimestre, restaurer dans un vrai projet Supabase vide, puis le
   supprimer (go-no-go.md, A3b).
7. Facultatif : `ALERTE_WEBHOOK` (déjà prévu pour la surveillance).

## 17. Verdict

**READY WITH MANUAL ACTIONS**

Le système est écrit, relu (`shellcheck`, `actionlint`) et éprouvé de bout en bout sur
une base jetable portant le vrai schéma GoShip (106/106). Il ne protège **rien** tant
que les actions 1 à 4 ne sont pas faites et qu'un passage de `sauvegarde.yml` n'est pas
**vert en production**. D'ici là, rien ici ne doit être lu comme « BACKUP VERIFIED » ou
« RESTORE VERIFIED » pour la production.

Critères de la mission :

| | Critère | État |
|---|---|---|
| C1 | backup PostgreSQL réel généré | TESTED ON DISPOSABLE DATABASE ; production : non |
| C2 | compressé | oui (format custom de `pg_dump`) — base jetable |
| C3 | chiffré avec age | TESTED ON DISPOSABLE DATABASE |
| C4 | stocké hors du dépôt | TESTED ON DISPOSABLE DATABASE (rclone, stockage local) ; fournisseur réel : non |
| C5 | checksum vérifié | TESTED ON DISPOSABLE DATABASE (y compris refus d'un fichier altéré) |
| C6 | rétention | TESTED ON DISPOSABLE DATABASE |
| C7 | téléchargement | TESTED ON DISPOSABLE DATABASE |
| C8 | déchiffrement | TESTED ON DISPOSABLE DATABASE |
| C9 | restauration | TESTED ON DISPOSABLE DATABASE |
| C10 | restauration vérifiée | TESTED ON DISPOSABLE DATABASE |
| C11 | secrets jamais exposés | TESTED ON DISPOSABLE DATABASE (journaux inspectés) + recherche dans le dépôt |
| C12 | lancement manuel | lancé à la main dans GitHub Actions (exécution 36298048867) |
| C13 | planification | IMPLEMENTED (`cron` quotidien, depuis `main`) |
| C14 | échec réel du workflow | secrets absents : **rouge dans GitHub Actions** (exécution 36298048867) ; chaque autre échec : TESTED ON DISPOSABLE DATABASE (codes de sortie des scripts) |
| C15 | documentation reproductible | `outils/README-backup.md` |
