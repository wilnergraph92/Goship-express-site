# Sauvegarde du code sur le Mac (launchd → age → Backblaze B2)

Deux sauvegardes protègent GoShip Express, et elles ne se remplacent pas :

| | Quoi | Où tourne-t-elle | Fichiers |
|---|---|---|---|
| **Code** | le dossier du projet : code, historique Git, travail pas encore poussé | le Mac du propriétaire, chaque jour (launchd) | ce dossier |
| **Base** | la base Supabase : clients, colis, factures, paiements, comptes | GitHub Actions, chaque jour | `.github/workflows/sauvegarde.yml`, `outils/README-backup.md` |

Ce guide ne parle que de la première. Elle ne contient **aucune** donnée de la base.

## Ce que fait `backup-goship.sh`

1. Un seul passage à la fois (verrou ; celui d'un passage interrompu est repris).
2. `tar | gzip | age` : l'archive est chiffrée au vol pour les clés **publiques** de
   `config/age-recipients.txt` ; rien n'est écrit en clair. `node_modules` et `.DS_Store`
   sont laissés de côté (réinstallables).
3. L'archive porte un nom provisoire tant qu'elle n'est pas complète et vérifiée
   (chiffrée, taille), puis son vrai nom et son empreinte SHA-256 (`….sha256`).
4. Envoi des deux fichiers vers B2 (`rclone`), puis **relecture** : l'empreinte que B2
   garde du fichier doit être celle du fichier local.
5. Rétention : 7 archives sur le Mac ; sur B2, rien n'est supprimé (réglable).
6. Journal `~/GoShip-Backups/backup.log` à chaque étape ; en cas d'échec, l'étape en
   cause, une notification macOS et un code de sortie non nul. La dernière sauvegarde
   réussie est notée dans `~/GoShip-Backups/derniere-sauvegarde.txt`.

`backup-goship.sh --verifier <clé privée>` relit la dernière archive **depuis B2**,
vérifie son SHA-256, la déchiffre en mémoire et la lit en entier : c'est la preuve
qu'elle se restaure. La clé n'est lue que par `age`, jamais affichée ni copiée.

### Ce qui a changé par rapport au script d'origine

| Script d'origine | Maintenant |
|---|---|
| `export PATH=…` collé à `#!/bin/bash` sur la première ligne : le shebang ne servait plus, et `/sbin` sortait du PATH | `#!/bin/bash` seul en première ligne |
| PATH sans `/opt/homebrew/bin` : sur un Mac Apple Silicon, launchd ne trouve pas `age` ni `rclone` | `/opt/homebrew/bin` et `/usr/local/bin` |
| Un échec arrêtait le script sans rien écrire ni prévenir | l'étape en échec est écrite au journal, notification macOS, code non nul |
| Envoi vers B2 sans relecture | empreinte relue sur B2, `.sha256` envoyé à côté |
| Une archive à moitié écrite pouvait garder le nom d'une vraie | nom provisoire, puis vrai nom une fois vérifiée |
| Deux passages pouvaient se chevaucher | verrou |
| `node_modules` dans chaque archive | exclu |
| Clé publique écrite dans le script, variable `AGE_KEY` inutilisée | fichier `config/age-recipients.txt` ; le script refuse d'y trouver une clé privée |
| Aucun moyen simple de prouver qu'une archive se relit | `--verifier` |

Ce qui ne change pas : le dossier sauvegardé, le nom des archives
(`goship-express-site-AAAA-MM-JJ_HH-MM-SS.tar.gz.age`), la destination
`goship-a:goship-sauvegardes/goship-express`, la clé publique, 7 archives sur le Mac,
aucune suppression sur B2. Les archives déjà faites restent lisibles et comptées.

## Installer (une fois, dans le Terminal du Mac)

Rien ici ne demande d'afficher un secret.

```bash
# 1. Garder l'ancien script, pour revenir en arrière si besoin
cp ~/GoShip-Backups/scripts/backup-goship.sh ~/GoShip-Backups/scripts/backup-goship.sh.avant-2026-09-28

# 2. Le fichier des destinataires : la clé PUBLIQUE déjà utilisée, reprise de l'ancien script
mkdir -p ~/GoShip-Backups/config
grep -oE 'age1[0-9a-z]{58}' ~/GoShip-Backups/scripts/backup-goship.sh | sort -u > ~/GoShip-Backups/config/age-recipients.txt
chmod 600 ~/GoShip-Backups/config/age-recipients.txt
wc -l < ~/GoShip-Backups/config/age-recipients.txt     # doit afficher 1

# 3. Le nouveau script, tiré du dépôt (la branche, ou main une fois fusionnée)
git -C ~/GoShip-Backups/Goship-express-site fetch origin
git -C ~/GoShip-Backups/Goship-express-site show origin/sauvegarde-base:outils/sauvegarde-locale/backup-goship.sh > ~/GoShip-Backups/scripts/backup-goship.sh
chmod 700 ~/GoShip-Backups/scripts/backup-goship.sh
head -1 ~/GoShip-Backups/scripts/backup-goship.sh      # doit afficher #!/bin/bash

# 4. Un passage à la main
/bin/bash ~/GoShip-Backups/scripts/backup-goship.sh
tail -5 ~/GoShip-Backups/backup.log                    # « Sauvegarde terminée avec succès »

# 5. La preuve qu'elle se relit : avec la clé PRIVÉE des sauvegardes du code
#    (là où vous la gardez ; son contenu ne s'affiche pas)
~/GoShip-Backups/scripts/backup-goship.sh --verifier /chemin/vers/la/cle-privee.txt
```

Aucun fichier de réglages n'est nécessaire : les valeurs par défaut sont celles de
l'installation actuelle. Pour en changer une, voir `goship-backup.conf.exemple`.

### Le LaunchAgent

Rien à changer s'il lance déjà le script. Pour le vérifier :

```bash
plutil -p ~/Library/LaunchAgents/com.goshipexpress.backup.plist
```

`ProgramArguments` doit être `/bin/bash` puis le chemin complet du script (ou le
chemin du script seul, qui marche maintenant que la première ligne est correcte).
Modèle commenté : `com.goshipexpress.backup.plist.exemple`. Pour lancer le passage
planifié tout de suite, comme launchd le fera :

```bash
launchctl kickstart -k gui/$(id -u)/com.goshipexpress.backup
```

Si vous modifiez le fichier `.plist`, rechargez-le :

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.goshipexpress.backup.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.goshipexpress.backup.plist
```

### Revenir en arrière

```bash
cp ~/GoShip-Backups/scripts/backup-goship.sh.avant-2026-09-28 ~/GoShip-Backups/scripts/backup-goship.sh
```

## Au quotidien

- `cat ~/GoShip-Backups/derniere-sauvegarde.txt` : date et nom de la dernière réussie.
- `grep ÉCHEC ~/GoShip-Backups/backup.log` : les échecs et leur étape.
- Une fois par mois : `backup-goship.sh --verifier …` avec la clé privée.

## La clé privée

L'archive ne se lit qu'avec la clé **privée** qui correspond à la clé publique de
`age-recipients.txt`. Gardez-en au moins une copie **hors de ce Mac** (gestionnaire de
mots de passe et support physique) : si le Mac est perdu et la clé avec, les archives
de B2 sont illisibles. Ce script ne lit jamais la clé privée, sauf pour `--verifier`,
avec le chemin que vous lui donnez.

## Limites

- Le Mac doit être allumé : en veille, launchd lance le passage manqué au réveil ;
  éteint, le jour est sauté.
- Les accès à B2 sont ceux de la configuration de rclone du Mac. Une *Application Key*
  limitée au bucket `goship-sauvegardes` suffit ; celle de GitHub (sauvegarde de la
  base) doit être une autre clé.
- Essai automatique, sans vraie clé ni vrai bucket :
  `bash outils/essais-services/essai-sauvegarde-locale.sh` (sous Linux et, en CI, sous
  le bash 3.2 de macOS).
