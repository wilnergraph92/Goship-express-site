# Sauvegardes

## Ce qui existe vraiment (27/09/2026)

Guide complet de la sauvegarde autonome (Supabase Free) : **`outils/README-backup.md`**.
Ce fichier garde l'état réel et le registre des restaurations.

| Sauvegarde | État | Preuve |
|---|---|---|
| Sauvegardes automatiques de Supabase | **aucune** : le projet reste sur l'offre gratuite, qui n'en fournit pas de téléchargeable | choix du 27/09/2026 |
| `sauvegarde.yml` : copie chiffrée quotidienne, stockage externe (rclone), rétention 7, restauration d'épreuve | **écrite et éprouvée sur une base jetable, jamais exécutée sur la production** : secrets non posés (`SUPABASE_DB_URL`, clés age, `SAUVEGARDE_RCLONE_CONFIG`, `SAUVEGARDE_STOCKAGE`) | `essai-production.py`, sections F, K et L ; le 26/09/2026, l'unique passage avait été **sauté** faute de secrets (et affiché vert : ce n'est plus possible, il est rouge désormais) |
| Stockage externe | **non configuré** : aucun fournisseur choisi | outils/README-backup.md, C.2 |
| Restauration dans un vrai projet Supabase | **jamais faite** | go-no-go.md, A3b |
| RPO, RTO | **non mesurés en production** : aucune sauvegarde de production n'existe | le résumé du job « Restauration d'épreuve » les donnera à chaque passage |

Personne ne doit dire « on a des sauvegardes » avant qu'un passage de `sauvegarde.yml`
soit vert de bout en bout **et** qu'une restauration dans un vrai projet ait réussi.

## Ce que fait `sauvegarder.sh`

`outils/production/sauvegarder.sh <dossier>` (lancé chaque jour à 5 h 23 UTC par
`sauvegarde.yml`, ou à la main) :

1. `pg_dump` du schéma `public` complet (tables, données, fonctions, règles RLS,
   déclencheurs, droits) ;
2. `pg_dump` des comptes (`auth.users`, `auth.identities`) : données **et**
   définition des deux tables. Une restauration dans un vrai projet n'en lit que
   les données ; la définition sert à la restauration d'épreuve (le vrai
   `auth.users` a bien plus de colonnes que la doublure des essais) ;
3. vérifie que les archives se relisent et contiennent les tables principales ;
4. chiffre les trois fichiers pour une ou deux clés **publiques** age
   (`SAUVEGARDE_DESTINATAIRE` : le propriétaire ; `RESTAURATION_DESTINATAIRE` :
   l'épreuve automatique — chacune relit seule la sauvegarde) et efface le clair :
   - `goship-<date>.public.dump.age`
   - `goship-<date>.comptes.dump.age`
   - `goship-<date>.manifeste.json.age` (empreintes sha256, nombre de lignes par
     table — chiffré lui aussi : le dépôt est public, et les artefacts d'un dépôt
     public se téléchargent par n'importe quel compte GitHub).

Puis `sauvegarde.yml` vérifie les fichiers (`verifier-sauvegarde.sh`), les envoie
dans le stockage externe et applique la rétention (`stocker.sh`), et en garde une
copie de secours 7 jours dans les artefacts du workflow. Chaque fichier chiffré a son
empreinte SHA-256 (`….age.sha256`). Sans la clé privée, ils ne valent rien : c'est le
chiffrement qui les protège, pas GitHub.

### Ce qui n'est PAS dans la sauvegarde

| Quoi | Où le retrouver |
|---|---|
| Vault (clés Brevo/Resend/Meta, `site_url`, `courriel_logo`) | gestionnaire de mots de passe ; reposer avec `definir_reglage` |
| Storage (logo des e-mails, espace `site`) | `assets/` du dépôt ; redéposer |
| Réglages Supabase (Auth : URL, fournisseurs, confirmation d'e-mail, mot de passe ; SMTP ; extensions) | README, « Les cinq réglages à faire dans Supabase » ; à reporter à la main |
| Tâches pg_cron | recréées en relançant `supabase-notifications.sql` |
| Le site, le bureau, le mobile | le dépôt Git (chaque version est un commit) |

## Mettre en service (une fois)

1. Sur un ordinateur de confiance : `age-keygen -o goship-sauvegarde.key` (la clé
   du propriétaire) et `age-keygen -o goship-epreuve.key` (la clé de l'épreuve
   automatique). La ligne `# public key: age1…` de chacune est sa clé publique.
2. Ranger `goship-sauvegarde.key` (la clé **privée**) en deux endroits hors ligne
   : gestionnaire de mots de passe **et** support physique. Jamais dans GitHub,
   jamais dans le dépôt, jamais dans un message.
3. GitHub > Settings > Environments > New environment `production`. Dans
   *Deployment branches and tags*, n'autoriser que `main` : une PR ou une autre
   branche ne peut alors pas lire ces secrets. (Pas de *Required reviewers* : la
   sauvegarde de la nuit attendrait une approbation chaque jour.)
4. Environment secrets :
   - `SAUVEGARDE_DESTINATAIRE` = la clé publique `age1…` du propriétaire ;
   - `RESTAURATION_DESTINATAIRE` = la clé publique de l'épreuve ;
   - `RESTAURATION_CLE` = **tout le contenu** de `goship-epreuve.key` (la clé
     privée de l'épreuve ; puis supprimer ce fichier de l'ordinateur). Pourquoi
     l'accepter dans GitHub : quiconque peut lire les secrets de cet environnement
     lit déjà `SUPABASE_DB_URL`, donc la base elle-même — la clé d'épreuve n'ouvre
     rien de plus. La clé du **propriétaire**, elle, ne va jamais dans GitHub ;
   - `SUPABASE_DB_URL` = Supabase > Connect > *Session pooler* (port 5432), avec
     le mot de passe de la base. Un rôle dédié en lecture seule serait préférable ;
     non éprouvé sur Supabase (il doit lire `public`, `auth.users` et
     `auth.identities`) — à essayer d'abord sur la préproduction.
5. Actions > Sauvegarde de la base > Run workflow. Les deux jobs doivent être
   verts ; le résumé du job « Restauration d'épreuve » donne l'âge de la
   sauvegarde (RPO) et la durée de restauration (RTO de la base). Les noter
   ci-dessous.
6. **Restaurer cette première sauvegarde dans un vrai projet Supabase vide**
   (ci-dessous), puis supprimer ce projet. Noter la date et la durée ici.

## La restauration d'épreuve (chaque nuit, automatique)

Après chaque sauvegarde, `sauvegarde.yml` la restaure dans un PostgreSQL 17
jetable, habillé en projet Supabase (rôles, publication `supabase_realtime`,
doublures `doublures-supabase.py`), avec `RESTAURATION_ESSAI=1` : empreintes,
lignes comparées table par table au manifeste, chaîne rejouée
(`appliquer-chaine.sh`), contrôles (détail chiffré). Aucune donnée dans le
journal. Ce n'est pas un vrai projet Supabase : la restauration trimestrielle
dans un projet neuf reste nécessaire.

**Une base qui porte des lignes orphelines ne se restaure pas** : les clés
étrangères sont recréées après les données et refusent l'orphelin (éprouvé par
`essai-production.py`). `controle-integrite.sql` vert est donc une condition
pour qu'une sauvegarde soit utilisable ; une restauration d'épreuve rouge sur
des clés étrangères signale une intégrité à corriger.

## Restaurer

**Jamais dans la base de production en service.** La cible est un projet Supabase
neuf (préproduction, ou le futur projet de production après un sinistre).
`restaurer.sh` refuse une base qui contient déjà des colis.

```
# sur un ordinateur de confiance, avec pg_restore/psql 17 et age
RESTORE_TARGET=staging CIBLE_DB_URL='postgresql://…projet-neuf…' \
  bash outils/production/restaurer.sh <dossier des fichiers> goship-<date> goship-sauvegarde.key
```

`RESTORE_TARGET` est obligatoire (`essai`, `staging`, ou `production` avec
`RESTORE_CONFIRM=RESTAURER-EN-PRODUCTION`, dans le nouveau projet après un sinistre
seulement) ; le SHA-256 de chaque fichier chiffré est vérifié avant de déchiffrer.

Le script déchiffre (une mauvaise clé s'arrête là), vérifie les empreintes,
restaure les comptes puis le schéma public, et compare le nombre de lignes table
par table avec le manifeste.

Ensuite, dans le SQL Editor du projet restauré :

1. activer `pg_cron` et `pg_net` (Database > Extensions) ;
2. rejouer la chaîne `outils/migrations.txt` (remet les tâches pg_cron et tout ce
   qui dépend du schéma Supabase) ;
3. `controle-securite.sql`, `controle-integrite.sql` : même résultat qu'en
   production ;
4. `select public.sante();` → `pret = true` ;
5. reposer les secrets du Vault et les réglages Auth (tableau plus haut) ;
6. se connecter avec un compte client et un compte de l'équipe.

Cette suite est exactement ce que `essai-production.py` (section F) éprouve sur une
base jetable : empreintes md5 identiques table par table, contrôles verts, espace
client identique, création de colis et verrous actifs après restauration.
**Limite :** l'essai tourne sur PostgreSQL avec des doublures d'Auth, Vault et
Storage, pas sur un vrai projet Supabase. La première restauration réelle (étape 6
de la mise en service) reste à faire.

## Conservation

| Où | Combien |
|---|---|
| Stockage externe, destination A (et B) | les **7** dernières sauvegardes complètes (`stocker.sh retention`, garde-fous : outils/README-backup.md, H) |
| Artefacts GitHub (`sauvegarde.yml`) | 7 jours, copie de secours |
| Supabase | aucune (offre gratuite) |
| Copie hors ligne (recommandé) | une sauvegarde par mois, téléchargée et rangée hors ligne, 12 mois |

## Tester (chaque trimestre)

Restaurer la dernière sauvegarde dans la préproduction vidée (ou un projet
temporaire), suivre « Restaurer », noter ici la date, la durée et le résultat.
Une sauvegarde qui n'a jamais été restaurée n'est pas une sauvegarde.

| Date | Sauvegarde | Durée | Résultat | Par |
|---|---|---|---|---|
| 26/09/2026 | base d'essai (`essai-production.py`, sections F et K) | ~1 s (base d'essai de 27 colis) | réussie, 70/70 | CI |
| 27/09/2026 | base jetable, chaîne complète (`essai-production.py`, section L : stockage rclone, rétention, téléchargement, `epreuve-restauration.sh`) | ~2 s (334 lignes) | réussie, 106/106 | local (ce conteneur) |
| — | première sauvegarde de production, épreuve automatique | — | **à faire** (A3) | — |
| — | première sauvegarde de production, vrai projet Supabase | — | **à faire** (A3b) | — |
