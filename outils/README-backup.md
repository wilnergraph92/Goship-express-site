# Sauvegardes de la base GoShip Express (Supabase Free)

L'offre gratuite de Supabase ne garde **aucune sauvegarde téléchargeable** (les
sauvegardes quotidiennes sont réservées aux offres payantes). GoShip Express reste sur
l'offre gratuite et fait donc ses sauvegardes lui-même, **hors de Supabase** : chaque
jour, GitHub Actions copie la base avec `pg_dump`, la chiffre, l'envoie dans un stockage
externe privé, garde les 7 dernières, puis **restaure** la copie du jour dans une base
jetable pour prouver qu'elle est utilisable.

Rien ne change dans l'architecture : Supabase, PostgreSQL, Supabase Auth, GitHub,
Electron et Expo restent ce qu'ils sont. Aucun script de sauvegarde n'écrit dans la base.

> Tant qu'une exécution réelle de `sauvegarde.yml` n'est pas **verte de bout en bout**
> (les deux jobs), il n'y a **pas** de sauvegarde de production. Le workflow est rouge
> tant qu'un secret manque : c'est voulu.

## A. Architecture

```
Supabase PostgreSQL (production)
      │  SUPABASE_DB_URL (Session pooler, port 5432) — lecture seule
      ▼
GitHub Actions « Sauvegarde de la base » (chaque jour 5 h 23 UTC, ou à la demande)
      │  sauvegarder.sh : pg_dump --format=custom (compressé)
      │     • schéma public complet : tables, données, fonctions, déclencheurs,
      │       séquences, types, contraintes, index, règles RLS, droits
      │     • comptes : auth.users, auth.identities
      │  relu (pg_restore --list), tailles vérifiées
      │  chiffré avec age (clé du propriétaire + clé d'épreuve), le clair effacé
      │  empreinte SHA-256 de chaque fichier chiffré
      ▼
verifier-sauvegarde.sh : fichiers, tailles, SHA-256, en-tête age
      ▼
stocker.sh : rclone → destination A (et B si posée), chaque fichier RELU et comparé
      ▼
Rétention : les 7 sauvegardes complètes les plus récentes, garde-fous
      ▼
Job « restaurer » : retéléchargement depuis A, SHA-256, déchiffrement (RESTAURATION_CLE),
restauration dans un PostgreSQL 17 jetable, chaîne de migrations rejouée,
verifier-restauration.sh, rapport et durées réelles (RTO), âge de la copie (RPO)
      ▼
Échec n'importe où → workflow ROUGE (+ ALERTE_WEBHOOK s'il est posé)
```

Fichiers d'une sauvegarde (`goship-AAAA-MM-JJTHHMMSSZ`, heure UTC) :

| Fichier | Contenu |
|---|---|
| `….public.dump.age` | schéma `public` complet (format custom de `pg_dump`, compressé), chiffré |
| `….comptes.dump.age` | `auth.users` et `auth.identities` (données et définition), chiffré |
| `….manifeste.json.age` | date, versions, empreintes du clair, lignes par table, nombre de comptes — chiffré (le dépôt est public) |
| `….age.sha256` (×3) | empreinte SHA-256 de chaque fichier chiffré, format `sha256sum` |

**Pourquoi `pg_dump` et pas `supabase db dump`** : `supabase db dump` produit du SQL en
clair (via Docker) et exclut les schémas gérés par Supabase, dont `auth` ; le format
custom de `pg_dump` est compressé, se vérifie sans rien restaurer (`pg_restore --list`)
et se restaure partie par partie (les comptes avant le schéma public, ce qu'exige la
restauration dans un projet Supabase neuf). `pg_dump` 17 lit les serveurs 15 à 17.

### Les scripts (`outils/production/`)

| Script | Rôle |
|---|---|
| `verifier-adresse.sh [VARIABLE]` | l'adresse de la base (`SUPABASE_DB_URL` par défaut) convient-elle à `pg_dump` depuis GitHub ? Session pooler 5432 accepté ; connexion directe, port 6543, `sslmode=disable`, utilisateur sans `.<ref>` refusés. N'affiche jamais l'adresse, ne se connecte pas |
| `sauvegarder.sh <dossier>` | la copie : adresse vérifiée, connexion vérifiée, `pg_dump`, relecture, chiffrement, SHA-256 ; le manifeste garde aussi la valeur des séquences et le détail des comptes (identités, mots de passe, confirmés) |
| `verifier-sauvegarde.sh <dossier> <nom> [clé]` | sans clé : fichiers, tailles, SHA-256, chiffrement ; avec clé : déchiffrement, manifeste, structure. `FINAL RESULT: PASS/FAIL` |
| `stocker.sh envoyer\|lister\|recuperer\|retention` | le stockage externe par rclone (A, B), relecture après envoi, rétention. A obligatoire ; B non configurée : `Destination B : SKIPPED` ; B configurée qui échoue : échec |
| `restaurer.sh <dossier> <nom> <clé>` | la restauration ; `RESTORE_TARGET` obligatoire |
| `verifier-restauration.sh [manifeste]` | la base restaurée, en lecture seule : tables, fonctions, contraintes, verrous, données, séquences, comptes et leur détail |
| `epreuve-restauration.sh <dossier> <nom> <clé> [s]` | l'épreuve complète (les quatre précédents enchaînés) et son rapport chronométré ; avec `PREPARER_CIBLE=1` (base jetable seulement, refusé sur une adresse Supabase), crée d'abord les rôles de Supabase qui manquent (`anon`, `authenticated`, `service_role`, `authenticator`…) et les doublures |
| `alerter.sh "<texte>"` | prévient une seconde personne par `ALERTE_WEBHOOK` |

Workflows : `.github/workflows/sauvegarde.yml` (quotidien + manuel) et
`.github/workflows/restauration-test.yml` (manuel). Tous deux posent
`defaults: run: shell: bash` : chaque étape tourne sous `bash -eo pipefail`, si bien
qu'une commande qui échoue devant un tube (`stocker.sh … | tee`) fait échouer l'étape.
Sans cela, GitHub lance `bash -e` et l'échec était masqué par `tee`. Ne jamais retirer
cette ligne.

## B. Secrets

Tous dans **GitHub > Settings > Environments > `production`** (n'autoriser que la
branche `main`), sauf mention. **Jamais** dans le dépôt, un fichier, un message ou un
journal. Seuls les noms figurent ici.

| Secret | Obligatoire | Contenu (nature, jamais la valeur) |
|---|---|---|
| `SUPABASE_DB_URL` | oui | chaîne de connexion **Session pooler** (Supabase > Connect > Session pooler), de la forme `postgresql://postgres.<ref>:<mot de passe>@aws-…pooler.supabase.com:5432/postgres` ; `verifier-adresse.sh` refuse toute autre forme avant de se connecter (voir L) |
| `SAUVEGARDE_DESTINATAIRE` | oui | clé **publique** age du propriétaire (`age1…`) |
| `RESTAURATION_DESTINATAIRE` | oui | clé **publique** age de l'épreuve |
| `RESTAURATION_CLE` | oui | clé **privée** age de l'épreuve (tout le fichier) |
| `SAUVEGARDE_RCLONE_CONFIG` | oui | tout le contenu d'un `rclone.conf` décrivant la ou les destinations (il contient leurs clés d'accès) |
| `SAUVEGARDE_STOCKAGE` | oui | destination A, `remote:chemin` (ex. `goship-a:goship-sauvegardes/production`) |
| `SAUVEGARDE_STOCKAGE_B` | non | destination B, chez un **autre** fournisseur |
| `ALERTE_WEBHOOK` | non | Slack, Discord ou ntfy (déjà utilisé par `surveillance.yml`) |
| `STAGING_DB_URL` | pour une restauration vers staging | environnement `staging` : la base goship-staging (qui doit alors porter aussi `RESTAURATION_CLE`, `SAUVEGARDE_RCLONE_CONFIG`, `SAUVEGARDE_STOCKAGE`) |

Note : `SAUVEGARDE_DESTINATAIRE` et `RESTAURATION_DESTINATAIRE` sont des **clés de
chiffrement**, pas des lieux de stockage. Les lieux sont `SAUVEGARDE_STOCKAGE` et
`SAUVEGARDE_STOCKAGE_B`.

## C. Mettre en service (une fois)

1. **Les clés age** (sur un ordinateur de confiance) :
   ```
   age-keygen -o goship-sauvegarde.key    # la clé du PROPRIÉTAIRE
   age-keygen -o goship-epreuve.key       # la clé de l'ÉPREUVE automatique
   ```
   La ligne `# public key: age1…` de chaque fichier est sa clé publique.
   - `goship-sauvegarde.key` (privée) : **deux** copies hors ligne (gestionnaire de
     mots de passe **et** support physique). Jamais dans GitHub.
   - `goship-epreuve.key` : son contenu va dans `RESTAURATION_CLE`, puis supprimer le
     fichier. Quiconque lit cet environnement lit déjà `SUPABASE_DB_URL` : cette clé
     n'ouvre rien de plus.
   - **Perdre les deux clés privées rend toutes les sauvegardes illisibles.** Aucune
     récupération n'est possible : c'est le principe du chiffrement.
2. **Le stockage externe** (coût nul au démarrage) : un compte chez un fournisseur
   gratuit, un conteneur privé, une clé d'accès limitée à ce conteneur. Recommandé :
   - destination A : **Backblaze B2** (offre gratuite de quelques Go, sans carte à
     l'inscription au moment d'écrire — vérifier les conditions actuelles). Créer le
     bucket **privé** `goship-sauvegardes`, une *Application Key* limitée à ce bucket
     (lecture, écriture, suppression), et régler le cycle de vie du bucket sur
     « Keep only the last version of the file » : sinon un fichier supprimé par la
     rétention reste stocké en version cachée.
   - destination B (conseillée) : un autre fournisseur, pour qu'une panne ou une
     fermeture de compte n'emporte pas tout : Google Drive (compte dédié ; attention,
     avec une application OAuth « en test », le jeton expire au bout de 7 jours :
     publier l'application ou utiliser un compte de service), ou Cloudflare R2 (offre
     gratuite, mais une carte est demandée à l'inscription).
   - Sans fournisseur, les sauvegardes ne restent que 7 jours en artefact GitHub et le
     workflow est rouge.
3. **Le fichier rclone.conf** (sur l'ordinateur de confiance, avec rclone installé) :
   `rclone config` → *New remote* `goship-a`, type `b2`, l'identifiant et la clé de
   l'*Application Key* ; `goship-b` pour B. Vérifier : `rclone lsd goship-a:`. Puis
   copier tout le contenu de `rclone config file` (le chemin affiché) dans le secret
   `SAUVEGARDE_RCLONE_CONFIG`, et **supprimer ce fichier** de l'ordinateur s'il ne sert
   plus.
4. **Les secrets** du tableau B, dans l'environnement `production`.
5. **Premier passage** : Actions > *Sauvegarde de la base* > *Run workflow*. Les jobs
   « Copie chiffrée, stockage externe, rétention » et « Restauration d'épreuve » doivent
   être **verts** ; le résumé du second donne le rapport (`FINAL RESULT: PASS`), les
   durées et l'âge de la copie. Reporter la date dans `docs/production/backup.md`.
6. **Première restauration dans un vrai projet Supabase** vide (voir E), puis supprimer
   ce projet. C'est la seule façon d'éprouver ce que l'épreuve automatique ne couvre
   pas (le vrai schéma `auth`, les extensions, le Vault).

## D. Sauvegarde manuelle

GitHub > **Actions** > **Sauvegarde de la base** > **Run workflow** (branche `main`).
Même chemin que la sauvegarde de la nuit, rétention comprise. En local (dépannage), sur
un ordinateur de confiance :

```
SUPABASE_DB_URL='…' SAUVEGARDE_DESTINATAIRE='age1…' \
  bash outils/production/sauvegarder.sh /tmp/goship-backup
bash outils/production/verifier-sauvegarde.sh /tmp/goship-backup goship-… [goship-sauvegarde.key]
```

## E. Restaurer

**Jamais dans la base de production en service.** `restaurer.sh` exige
`RESTORE_TARGET` (`essai`, `staging` ou `production`), refuse une cible qui contient
déjà des colis, refuse la base en service si `SUPABASE_DB_URL` est posée et identique,
vérifie le SHA-256 de chaque fichier chiffré **avant** de déchiffrer, et
`RESTORE_TARGET=production` exige en plus `RESTORE_CONFIRM=RESTAURER-EN-PRODUCTION`.

**Test (sans rien toucher)** : Actions > **Test de restauration** > *Run workflow*,
sauvegarde `derniere` (ou un nom), source A ou B, cible `essai` : téléchargement,
SHA-256, déchiffrement, restauration dans un PostgreSQL jetable, chaîne, vérification,
rapport chronométré.

**Vers la préproduction** : vider goship-staging (ou recréer le projet), poser dans
l'environnement `staging` : `STAGING_DB_URL`, `RESTAURATION_CLE`,
`SAUVEGARDE_RCLONE_CONFIG`, `SAUVEGARDE_STOCKAGE` ; puis *Test de restauration*, cible
`staging`. Le workflow refuse une `STAGING_DB_URL` qui pointe la production.

**À la main** (ordinateur de confiance, `pg_restore`/`psql` 17, `age`, `rclone`) :

```
RCLONE_CONFIG=~/.config/rclone/rclone.conf SAUVEGARDE_STOCKAGE='goship-a:goship-sauvegardes/production' \
  bash outils/production/stocker.sh recuperer derniere /tmp/restauration
RESTORE_TARGET=staging CIBLE_DB_URL='postgresql://…projet-neuf…' \
  bash outils/production/restaurer.sh /tmp/restauration goship-… goship-sauvegarde.key
```

**Restauration dans un vrai projet Supabase : deux points à trancher sur goship-staging**
(ils ne peuvent pas l'être sur un PostgreSQL ordinaire) :

- *Droits du schéma public (m2).* Le dump du schéma public contient, en plus des
  objets GoShip : `COMMENT ON SCHEMA public`, les `GRANT … ON SCHEMA public`, les
  `GRANT` de chaque table, fonction et séquence à `anon`, `authenticated` et
  `service_role`, et les `ALTER DEFAULT PRIVILEGES [FOR ROLE …] IN SCHEMA public`.
  Dans un projet Supabase, on restaure en tant que `postgres`, qui n'est pas
  superutilisateur. Si le dump contient un `ALTER DEFAULT PRIVILEGES FOR ROLE
  supabase_admin` ou une ligne sur le schéma que `postgres` n'a pas le droit
  d'écrire, `pg_restore` le refuse. Or `restaurer.sh` ne tolère que l'erreur
  `schema "public" already exists` : la restauration s'arrêterait en échec, sans
  rien laisser passer en silence. **NON PROUVÉ** : sur une base jetable ces lignes
  passent (le restaurateur y est superutilisateur). Aucune correction préventive
  n'est faite. Si le test staging échoue sur ces lignes, la correction envisagée
  (sauter les entrées `DEFAULT ACL`, `COMMENT - SCHEMA public` et `ACL - SCHEMA
  public`, qu'un projet neuf porte déjà) sera faite et éprouvée à ce moment-là.
- *Comptes (m5).* `auth.users` et `auth.identities` se restaurent en données seules
  dans le schéma `auth` du projet. `verifier-restauration.sh` (lancé par le test de
  restauration) compare alors au manifeste : nombre de comptes, chaque profil client
  avec son compte, nombre d'identités, de comptes avec empreinte de mot de passe et
  de comptes confirmés (`AUTH ACCOUNTS`, `AUTH DETAILS`). Ensuite, se connecter à la
  main à goship-staging avec un compte d'essai connu. **NON PROUVÉ** tant que ce test
  n'a pas tourné sur goship-staging (il a tourné sur une base jetable portant les
  vraies tables des comptes de la sauvegarde).

Ensuite, dans le projet restauré : activer `pg_cron` et `pg_net`, rejouer la chaîne
`outils/migrations.txt` (`appliquer-chaine.sh`), reposer le Vault et la configuration
Auth (section J), puis `verifier-restauration.sh` avec le manifeste déchiffré,
`controle-securite.sql`, `controle-integrite.sql`, `select public.sante();`.

## F. Restauration d'urgence (la production est perdue)

Procédure complète : `docs/production/disaster-recovery.md`. En bref :

1. Ne rien écrire dans l'ancien projet s'il existe encore (il peut servir de preuve).
2. Créer un **nouveau** projet Supabase (offre gratuite possible), même région.
3. Récupérer la dernière sauvegarde (`stocker.sh recuperer derniere`, ou B si A est en
   panne : `SOURCE=B`), avec la clé du **propriétaire**.
4. `RESTORE_TARGET=production RESTORE_CONFIRM=RESTAURER-EN-PRODUCTION CIBLE_DB_URL=…nouveau projet…
   bash outils/production/restaurer.sh …` — le nouveau projet est vide : c'est la seule
   cible « production » admise.
5. Chaîne de migrations, Vault, Auth (section J), contrôles.
6. Pointer le site vers le nouveau projet : `assets/js/config.js` (adresse et clé
   publique du nouveau projet), l'application mobile (`EXPO_PUBLIC_*`) et le bureau
   suivent le site. Mettre à jour `SUPABASE_DB_URL` pour que les sauvegardes suivent.
7. Noter la durée réelle : c'est le RTO complet (base + remise en service).

## G. Rotation des clés

- **Clé age du propriétaire** : générer une nouvelle paire, mettre la nouvelle clé
  publique dans `SAUVEGARDE_DESTINATAIRE`. Les **anciennes** sauvegardes restent
  chiffrées pour l'ancienne clé : garder l'ancienne clé privée tant qu'elles existent
  (7 jours au moins, plus pour les copies mensuelles hors ligne), puis la détruire.
- **Clé d'épreuve** : nouvelle paire, `RESTAURATION_DESTINATAIRE` (publique) et
  `RESTAURATION_CLE` (privée) changés ensemble ; lancer la sauvegarde à la main.
- **Accès au stockage** : nouvelle *Application Key*, nouveau `SAUVEGARDE_RCLONE_CONFIG`,
  puis révoquer l'ancienne clé chez le fournisseur.
- **Mot de passe de la base** : Supabase > Database > Reset password, puis
  `SUPABASE_DB_URL`. Lancer la sauvegarde à la main pour vérifier.
- Une clé soupçonnée d'avoir fuité : changer tout de suite (et, pour la clé du
  propriétaire, envisager de supprimer les anciennes sauvegardes chiffrées pour elle).

## H. Rétention

`stocker.sh retention 7`, après chaque envoi, sur chaque destination :

- garde les **7 sauvegardes complètes** (six fichiers) les plus récentes ; la nouvelle
  en fait partie ;
- ne supprime rien s'il y en a 7 ou moins, refuse une valeur inférieure à 7 ;
- supprime **3 sauvegardes au plus** par passage (le reste au passage suivant) : un
  bug ou une erreur de date ne peut pas tout vider d'un coup ;
- ne supprime que des fichiers au nom exact d'une sauvegarde
  (`goship-AAAA-MM-JJTHHMMSSZ.….age(.sha256)`), un par un (`rclone deletefile`) :
  aucun joker, aucun dossier entier, aucun fichier étranger ;
- vérifie ensuite qu'il reste au moins 7 sauvegardes complètes, sinon échec.

Copie de secours : l'artefact GitHub de chaque passage, 7 jours. Recommandé en plus :
une sauvegarde par mois téléchargée et rangée hors ligne (12 mois), avec la clé du
propriétaire.

## I. RPO et RTO

- **RPO** (données qu'on peut perdre) : une sauvegarde par jour → **jusqu'à environ
  24 h** de modifications (plus si un passage échoue et n'est pas relancé). Le résumé
  du job « Restauration d'épreuve » donne l'âge réel de la copie vérifiée
  (`BACKUP AGE (RPO)`). Pour moins de 24 h : lancer la sauvegarde à la main avant une
  opération risquée, ou ajouter un second horaire au `cron`.
- **RTO de la base** (remettre les données en état) : **mesuré à chaque passage**,
  étape par étape (`RESTORE DURATION` : téléchargement + vérification/déchiffrement +
  restauration + chaîne + validation). Aucune valeur n'est inventée ici : la première
  valeur réelle viendra du premier passage vert en production (à reporter dans
  `docs/production/backup.md`). Sur la base d'essai (334 lignes), l'essai mesure
  environ 2 s ; une vraie base sera plus longue.
- **RTO complet** (le service remis en marche) : RTO de la base + créer le projet,
  Vault, Auth, `config.js` (section F) — à mesurer lors de l'exercice trimestriel.

## J. Ce qui est sauvegardé — et ce qui ne l'est pas

Ce n'est **pas** une « sauvegarde complète de Supabase ».

| Élément | Sauvegardé ? | Comment le retrouver sinon |
|---|---|---|
| Schéma `public` : tables, données, fonctions, déclencheurs, séquences, types, index, contraintes, règles RLS, droits | **oui** | — |
| Comptes : `auth.users`, `auth.identities` (e-mails, empreintes des mots de passe, métadonnées) | **oui** | — |
| Reste du schéma `auth` (sessions, jetons de rafraîchissement, facteurs MFA, journaux) | non | les utilisateurs se reconnectent |
| Configuration Supabase Auth (Site URL, Redirect URLs, fournisseurs, confirmation d'e-mail, SMTP, modèles d'e-mail) | non | à reporter à la main (`docs/production/environment.md`, section « Domaine de production ») |
| Fichiers de Supabase Storage | non | seul le logo des e-mails y est : redéposable depuis `assets/` |
| Vault (clés Brevo/Resend/Meta, `site_url`, `courriel_logo`) | non | gestionnaire de mots de passe ; `definir_reglage` |
| Tâches `pg_cron`, extensions (`pg_net`, `pg_cron`) | non | activer les extensions, rejouer la chaîne de migrations |
| Rôles et réglages du serveur, clés API du projet (`anon`, `service_role`) | non | propres au nouveau projet |
| Secrets GitHub, variables `EXPO_PUBLIC_*`, configuration du tableau de bord Supabase | non | gestionnaire de mots de passe ; `docs/production/secrets.md` |
| Le site, le bureau, l'application | dans Git | chaque version est un commit |

## K. Indépendance vis-à-vis du domaine du site

Les scripts et workflows de sauvegarde ne parlent qu'à PostgreSQL
(`SUPABASE_DB_URL`) et au stockage (`SAUVEGARDE_STOCKAGE`). Ils ne contiennent aucune
adresse du site (ni `github.io`, ni `/Goship-express-site/`, ni `goshipexpress.net`) :
passer le site sur `https://www.goshipexpress.net`, ou chez un autre hébergeur, ne
demande **aucun** changement ici. La configuration Auth liée au domaine est décrite à
part : `docs/production/environment.md`, « Domaine de production ».

## L. Limites de l'offre gratuite de Supabase

- Aucune sauvegarde fournie, pas de restauration à un instant donné (PITR) : ce
  système les remplace pour la base, avec un RPO d'environ 24 h.
- Connexion directe (`db.<ref>.supabase.co`) en IPv6 seulement : GitHub Actions n'a pas
  d'IPv6. Utiliser l'adresse **Session pooler** (port 5432 ; pas le *Transaction
  pooler* 6543, incompatible avec `pg_dump`). `verifier-adresse.sh` l'impose :

  | Adresse | Résultat |
  |---|---|
  | `…@db.<ref>.supabase.co:5432/postgres` (directe) | REFUSÉE |
  | `postgres.<ref>:…@aws-…pooler.supabase.com:6543/postgres` (transaction) | REFUSÉE |
  | `postgres.<ref>:…@aws-…pooler.supabase.com:5432/postgres` (session) | ACCEPTÉE |
  | pooler sans `.<ref>` dans l'utilisateur, sans mot de passe, `sslmode=disable` ou `allow`, chaîne `clé=valeur` | REFUSÉE |
  | hors Supabase (base jetable d'un essai) | ACCEPTÉE |

  Le message dit seulement quel type d'adresse est attendu : jamais l'adresse, ni
  l'utilisateur, ni le mot de passe. L'accès réel au pooler depuis un runner n'est
  prouvé qu'au premier passage (section C.5).
- Un projet gratuit inactif est **mis en pause** par Supabase : `pg_dump` échoue alors,
  le workflow devient rouge et l'alerte part. Rien ici ne garantit que la sauvegarde
  quotidienne suffise à éviter la mise en pause.
- Taille de base limitée par l'offre : la sauvegarde grossit avec elle ; surveiller la
  taille affichée dans le résumé et le quota du stockage externe.

## M. Essais (sans jamais toucher la production)

`python3 outils/essais-services/essai-production.py`, sections F, K et L : sur une
base PostgreSQL jetable qui porte toute la chaîne de migrations et des données
d'essai — base injoignable, sauvegarde, vérification avec et sans clé, mauvaise clé,
fichier altéré, envoi vers deux destinations par le vrai rclone (dossiers locaux),
jamais de remplacement, rétention (minimum 7, 3 suppressions au plus, fichier
étranger épargné), téléchargement, copie distante altérée refusée, garde-fous de
restauration, restauration chronométrée, vérification de la base, le script des
workflows de bout en bout, une base vide jamais déclarée PASS, aucun secret dans les
journaux. Et, depuis la revue du 27/09/2026 :

- **serveur PostgreSQL neuf** : un second serveur, créé par l'essai, sans aucun rôle de
  Supabase, où la vraie procédure (`epreuve-restauration.sh`, `PREPARER_CIBLE=1`) doit
  réussir seule. Rôles, tables, RLS, fonctions, données, séquences, déclencheurs sur
  `auth.users` et comptes y sont vérifiés ;
- **l'étape « Stockage externe » de `sauvegarde.yml`, extraite telle quelle** et lancée
  comme GitHub la lance (`bash --noprofile --norc -eo pipefail`), avec un rclone en
  panne sur commande. Résultats attendus :
  - A absente, envoi ou relecture de A en panne : échec ;
  - B non configurée : `SKIPPED` et succès ;
  - B absente, envoi, relecture ou rétention de B en panne : échec ;
  - sous `bash -e` seul, la panne de B passe en succès, ce qui reproduit le défaut
    corrigé ;
- **les adresses** : directe et 6543 refusées, Session pooler 5432 acceptée, rien
  affiché ;
- **le compteur** du journal : le vrai nombre de tables, fonctions, déclencheurs et
  règles RLS.

Lancé à chaque modification par `essais.yml` (banc « production »).
