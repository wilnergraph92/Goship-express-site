# Sauvegardes

## Ce qui existe vraiment (26/09/2026)

| Sauvegarde | État | Preuve |
|---|---|---|
| Sauvegardes automatiques de Supabase | **inconnu** — dépend de l'offre du projet (l'offre gratuite n'en garde aucune téléchargeable ; Pro : quotidiennes, 7 jours ; PITR en option) | à relever dans Supabase > Database > Backups et à noter ici |
| `sauvegarde.yml` (copie logique chiffrée, chaque jour) | **écrite et éprouvée sur une base d'essai, pas encore en service** : les secrets `SUPABASE_DB_URL` et `SAUVEGARDE_DESTINATAIRE` ne sont pas posés | tant qu'ils manquent, le workflow s'arrête sur l'avis « Sauvegarde non configurée » |
| Restauration d'une vraie sauvegarde de production | **jamais faite** | go-no-go.md, bloqueur B3 |

Personne ne doit dire « on a des sauvegardes » avant que les deux premières lignes
soient vérifiées et qu'une restauration ait réussi.

## Ce que fait `sauvegarder.sh`

`outils/production/sauvegarder.sh <dossier>` (lancé chaque jour à 5 h 23 UTC par
`sauvegarde.yml`, ou à la main) :

1. `pg_dump` du schéma `public` complet (tables, données, fonctions, règles RLS,
   déclencheurs, droits) ;
2. `pg_dump` des **données** des comptes (`auth.users`, `auth.identities`) ;
3. vérifie que les archives se relisent et contiennent les tables principales ;
4. chiffre les trois fichiers avec la clé **publique** age et efface le clair :
   - `goship-<date>.public.dump.age`
   - `goship-<date>.comptes.dump.age`
   - `goship-<date>.manifeste.json.age` (empreintes sha256, nombre de lignes par
     table — chiffré lui aussi : le dépôt est public, et les artefacts d'un dépôt
     public se téléchargent par n'importe quel compte GitHub).

`sauvegarde.yml` garde les fichiers **90 jours** dans les artefacts du workflow.
Sans la clé privée, ils ne valent rien : c'est le chiffrement qui les protège, pas
GitHub.

### Ce qui n'est PAS dans la sauvegarde

| Quoi | Où le retrouver |
|---|---|
| Vault (clés Brevo/Resend/Meta, `site_url`, `courriel_logo`) | gestionnaire de mots de passe ; reposer avec `definir_reglage` |
| Storage (logo des e-mails, espace `site`) | `assets/` du dépôt ; redéposer |
| Réglages Supabase (Auth : URL, fournisseurs, confirmation d'e-mail, mot de passe ; SMTP ; extensions) | README, « Les cinq réglages à faire dans Supabase » ; à reporter à la main |
| Tâches pg_cron | recréées en relançant `supabase-notifications.sql` |
| Le site, le bureau, le mobile | le dépôt Git (chaque version est un commit) |

## Mettre en service (une fois)

1. Sur un ordinateur de confiance : `age-keygen -o goship-sauvegarde.key`. La
   ligne `# public key: age1…` est la clé publique.
2. Ranger `goship-sauvegarde.key` (la clé **privée**) en deux endroits hors ligne
   : gestionnaire de mots de passe **et** support physique. Jamais dans GitHub,
   jamais dans le dépôt, jamais dans un message.
3. GitHub > Settings > Environments > New environment `production`. Dans
   *Deployment branches and tags*, n'autoriser que `main` : une PR ou une autre
   branche ne peut alors pas lire ces secrets. (Pas de *Required reviewers* : la
   sauvegarde de la nuit attendrait une approbation chaque jour.)
4. Environment secrets :
   - `SAUVEGARDE_DESTINATAIRE` = la clé publique `age1…` ;
   - `SUPABASE_DB_URL` = Supabase > Connect > *Session pooler* (port 5432), avec
     le mot de passe de la base. Un rôle dédié en lecture seule serait préférable ;
     non éprouvé sur Supabase (il doit lire `public`, `auth.users` et
     `auth.identities`) — à essayer d'abord sur la préproduction.
5. Actions > Sauvegarde de la base > Run workflow. Vérifier l'artefact.
6. **Restaurer cette première sauvegarde** (ci-dessous) dans un projet vide.
   Noter la date et la durée ici.

## Restaurer

**Jamais dans la base de production en service.** La cible est un projet Supabase
neuf (préproduction, ou le futur projet de production après un sinistre).
`restaurer.sh` refuse une base qui contient déjà des colis.

```
# sur un ordinateur de confiance, avec pg_restore/psql 17 et age
CIBLE_DB_URL='postgresql://…projet-neuf…' \
  bash outils/production/restaurer.sh <dossier des fichiers> goship-<date> goship-sauvegarde.key
```

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

| Où | Combien de temps |
|---|---|
| Artefacts GitHub (`sauvegarde.yml`) | 90 jours |
| Supabase (selon l'offre) | à noter |
| Copie hors GitHub (recommandé) | une sauvegarde par mois, téléchargée et rangée hors ligne, 12 mois |

## Tester (chaque trimestre)

Restaurer la dernière sauvegarde dans la préproduction vidée (ou un projet
temporaire), suivre « Restaurer », noter ici la date, la durée et le résultat.
Une sauvegarde qui n'a jamais été restaurée n'est pas une sauvegarde.

| Date | Sauvegarde | Durée | Résultat | Par |
|---|---|---|---|---|
| 26/09/2026 | base d'essai (`essai-production.py`) | < 1 min | réussie, 46/46 | CI |
| — | première sauvegarde de production | — | **à faire** | — |
