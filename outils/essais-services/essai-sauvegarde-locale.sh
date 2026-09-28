#!/bin/bash
# Les noms que ls liste ici sont ceux que l'essai crée lui-même
# shellcheck disable=SC2012
# =============================================================================
# Essai de outils/sauvegarde-locale/backup-goship.sh, sans rien toucher de réel
#
#   bash outils/essais-services/essai-sauvegarde-locale.sh
#
# Tout se passe dans un dossier temporaire : un faux « HOME », un faux projet (avec
# son .git et un node_modules), une paire de clés age créée pour l'essai, et un
# « B2 » qui est un dossier local (remote rclone de type local). Aucun réseau,
# aucune vraie clé, aucun vrai bucket. Tourne sous Linux (CI) et sous le bash 3.2
# de macOS (job macOS de essais.yml).
# Dernière ligne : « N vérifications, M réussies » ; code 0 seulement si tout passe.
# =============================================================================
set -uo pipefail

ICI="$(cd "$(dirname "$0")" && pwd)"
# L'interpréteur du script éprouvé : /bin/bash (3.2) sur macOS en CI
BASH_ESSAI="${BASH_ESSAI:-bash}"
SCRIPT="$ICI/../sauvegarde-locale/backup-goship.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/essai-sauvegarde.XXXXXX")"
trap 'rm -rf "$T"' EXIT

total=0; reussies=0
verifier() {  # verifier <libellé> <obtenu> <attendu>
  total=$((total + 1))
  if [ "$2" = "$3" ]; then reussies=$((reussies + 1)); printf '  OK   %-70s %s\n' "$1" "$2"
  else printf '  RATÉ %-70s %s\n       attendu : %s\n' "$1" "$2" "$3"; fi
}

export HOME="$T/home"
SAUV="$HOME/GoShip-Backups"
PROJET="$SAUV/Goship-express-site"
B2="$T/b2/goship-sauvegardes/goship-express"
mkdir -p "$PROJET/assets" "$PROJET/bureau/node_modules/lourd" "$SAUV/config" "$B2"
echo "<html>GoShip</html>" > "$PROJET/index.html"
echo "# notes" > "$PROJET/CLAUDE.md"
head -c 20000 /dev/urandom > "$PROJET/assets/logo.bin"
echo "reconstructible" > "$PROJET/bureau/node_modules/lourd/index.js"
( cd "$PROJET" && git init -q && git -c user.email=e@x -c user.name=essai add -A && git -c user.email=e@x -c user.name=essai commit -qm essai )
age-keygen -o "$T/cle.txt" 2> /dev/null
age-keygen -o "$T/autre-cle.txt" 2> /dev/null
grep -o 'age1[0-9a-z]*' "$T/cle.txt" > "$SAUV/config/age-recipients.txt"
chmod 600 "$SAUV/config/age-recipients.txt"

# Le « B2 » de l'essai : un remote rclone local, décrit par l'environnement
export RCLONE_CONFIG="$T/rclone.conf"; : > "$RCLONE_CONFIG"
export RCLONE_CONFIG_ESSAI_TYPE=local
CONF="$SAUV/config/goship-backup.conf"
export GOSHIP_BACKUP_CONF="$CONF"
configurer() {  # configurer [lignes supplémentaires]
  { echo "REMOTE=\"essai:$B2\""; echo "NOTIFIER=0"; printf '%s\n' "$@"; } > "$CONF"
  chmod 600 "$CONF"
}
lancer() { GOSHIP_HORODATAGE="$1" "$BASH_ESSAI" "$SCRIPT" "${@:2}" > "$T/sortie.txt" 2>&1; echo $?; }
archives_locales() { find "$SAUV" -maxdepth 1 -name 'goship-express-site-*.tar.gz.age' | wc -l | tr -d ' '; }
archives_b2() { find "$B2" -maxdepth 1 -name 'goship-express-site-*.tar.gz.age' | wc -l | tr -d ' '; }

echo "A. Une sauvegarde"
configurer
verifier "premier passage : réussi" "$(lancer 2026-09-01_05-00-00)" 0
N1="goship-express-site-2026-09-01_05-00-00.tar.gz.age"
verifier "archive et empreinte sur le Mac" "$(ls "$SAUV/$N1" "$SAUV/$N1.sha256" 2> /dev/null | wc -l | tr -d ' ')" 2
verifier "archive chiffrée (en-tête age)" "$(head -c 21 "$SAUV/$N1")" "age-encryption.org/v1"
verifier "aucune archive en clair ni fichier provisoire laissé" "$(find "$SAUV" -maxdepth 1 \( -name '*.partiel' -o -name '*.tar.gz' \) | wc -l | tr -d ' ')" 0
verifier "archive et empreinte sur B2, identiques" "$(cmp -s "$SAUV/$N1" "$B2/$N1" && cmp -s "$SAUV/$N1.sha256" "$B2/$N1.sha256" && echo oui)" oui
verifier "empreinte au format shasum, relue juste" "$(cd "$SAUV" && shasum -a 256 -c -s "$N1.sha256" && echo oui)" oui
verifier "journal : relecture sur B2, fin réussie" "$(grep -c 'relu (empreinte identique)\|terminée avec succès' "$SAUV/backup.log")" 2
verifier "journal : l'état Git du projet est noté" "$(grep -c 'commit [0-9a-f]\{7\}' "$SAUV/backup.log")" 1
verifier "état de la dernière sauvegarde écrit" "$(grep -c "archive: $N1" "$SAUV/derniere-sauvegarde.txt")" 1
verifier "permissions de l'archive : propriétaire seul" "$(ls -l "$SAUV/$N1" | cut -c1-10)" "-rw-------"
verifier "aucun verrou laissé" "$(ls -d "$SAUV/.backup-goship.verrou" 2> /dev/null | wc -l | tr -d ' ')" 0

echo "B. Relire (--verifier) comme une restauration"
verifier "vérification avec la bonne clé : réussie" "$(lancer x --verifier "$T/cle.txt")" 0
verifier "… l'historique Git est dans l'archive" "$(grep -c 'historique Git présent : oui' "$T/sortie.txt")" 1
contenu="$(age -d -i "$T/cle.txt" "$SAUV/$N1" | tar -tzf -)"
verifier "le projet est dans l'archive (index.html, logo)" "$(printf '%s\n' "$contenu" | grep -cE 'Goship-express-site/(index\.html|assets/logo\.bin)$')" 2
verifier "node_modules exclu de l'archive" "$(printf '%s\n' "$contenu" | grep -c node_modules)" 0
verifier "une autre clé : refusée" "$(lancer x --verifier "$T/autre-cle.txt")" 1
verifier "… et la clé n'apparaît nulle part dans la sortie ni le journal" "$(cat "$T/sortie.txt" "$SAUV/backup.log" | grep -c 'AGE-SECRET-KEY')" 0
verifier "clé absente : refusé, message clair" "$(lancer x --verifier "$T/inexistante")" 1
cp "$B2/$N1" "$T/copie"; printf 'X' | dd of="$B2/$N1" bs=1 seek=500 conv=notrunc 2> /dev/null
verifier "archive abîmée sur B2 : refusée (SHA-256)" "$(lancer x --verifier "$T/cle.txt" "$N1")" 1
verifier "… le journal dit pourquoi" "$(grep -c 'archive altérée' "$T/sortie.txt")" 1
cp "$T/copie" "$B2/$N1"
mv "$B2/$N1.sha256" "$T/empreinte"
verifier "ancienne archive sans empreinte sur B2 : lue quand même, et dit" "$(lancer x --verifier "$T/cle.txt" "$N1")" 0
verifier "… « non vérifié » écrit" "$(grep -c 'non vérifié' "$T/sortie.txt")" 1
mv "$T/empreinte" "$B2/$N1.sha256"

echo "C. Rétention"
for j in 02 03 04 05 06 07 08 09 10; do lancer "2026-09-${j}_05-00-00" > /dev/null; done
verifier "10 passages : 7 archives gardées sur le Mac" "$(archives_locales)" 7
verifier "… et leurs empreintes seulement (pas d'empreinte orpheline)" "$(find "$SAUV" -maxdepth 1 -name '*.sha256' | wc -l | tr -d ' ')" 7
verifier "… les plus récentes (la plus ancienne gardée : le 4)" "$(find "$SAUV" -maxdepth 1 -name 'goship-express-site-*.age' | sort | head -1 | sed 's#.*/##')" "goship-express-site-2026-09-04_05-00-00.tar.gz.age"
verifier "B2 par défaut : rien n'est supprimé (10)" "$(archives_b2)" 10
echo "fichier étranger" > "$SAUV/goship-express-site-notes.txt"
echo "autre" > "$B2/autre-fichier.txt"
configurer "REMOTE_KEEP=3"
verifier "REMOTE_KEEP sous 7 : refusé" "$(lancer 2026-09-11_05-00-00)" 1
configurer "REMOTE_KEEP=7"
verifier "REMOTE_KEEP=7 : passage réussi" "$(lancer 2026-09-11_05-00-00)" 0
verifier "… 3 supprimées au plus par passage (11 → 8)" "$(archives_b2)" 8
lancer 2026-09-12_05-00-00 > /dev/null
verifier "… au passage suivant : 7 (12 → 7, deux supprimées)" "$(archives_b2)" 7
verifier "fichiers étrangers jamais touchés (Mac et B2)" "$(ls "$SAUV/goship-express-site-notes.txt" "$B2/autre-fichier.txt" 2> /dev/null | wc -l | tr -d ' ')" 2
verifier "les empreintes des archives supprimées partent avec elles" "$(find "$B2" -maxdepth 1 -name '*.sha256' | wc -l | tr -d ' ')" 7

echo "D. Pannes : l'échec se voit, rien de faux ne reste"
configurer
cat > "$CONF" <<EOF
REMOTE="inexistant:ailleurs"
NOTIFIER=0
EOF
chmod 600 "$CONF"
verifier "B2 injoignable : échec (code non nul)" "$(lancer 2026-09-13_05-00-00)" 1
verifier "… le journal dit l'étape" "$(grep -c 'ÉCHEC (code 1) pendant : envoi vers Backblaze B2' "$SAUV/backup.log")" 1
verifier "… l'archive locale, complète, reste sur le Mac" "$(ls "$SAUV/goship-express-site-2026-09-13_05-00-00.tar.gz.age" 2> /dev/null | wc -l | tr -d ' ')" 1
verifier "… pas de fichier provisoire, pas de verrou" "$(find "$SAUV" -maxdepth 1 \( -name '*.partiel' -o -name '.backup-goship.verrou' \) | wc -l | tr -d ' ')" 0
verifier "… l'état de la dernière sauvegarde réussie n'a pas bougé" "$(grep -c '2026-09-12' "$SAUV/derniere-sauvegarde.txt")" 1
configurer
mv "$SAUV/config/age-recipients.txt" "$T/dest"
verifier "sans fichier de destinataires : refusé avant toute archive" "$(lancer 2026-09-14_05-00-00)" 1
verifier "… aucune archive créée" "$(ls "$SAUV"/goship-express-site-2026-09-14* 2> /dev/null | wc -l | tr -d ' ')" 0
cat "$T/cle.txt" > "$SAUV/config/age-recipients.txt"
verifier "clé PRIVÉE dans les destinataires : refusé" "$(lancer 2026-09-14_05-00-00)" 1
verifier "… et dit pourquoi, sans l'afficher" "$(grep -c 'contient une clé PRIVÉE' "$T/sortie.txt")/$(grep -c 'AGE-SECRET-KEY-1' "$T/sortie.txt")" "1/0"
mv "$T/dest" "$SAUV/config/age-recipients.txt"
chmod 666 "$CONF"
verifier "configuration modifiable par d'autres : refusée" "$(lancer 2026-09-14_05-00-00)" 1
chmod 600 "$CONF"
configurer "SOURCE=\"$T/rien\""
verifier "projet introuvable : refusé" "$(lancer 2026-09-14_05-00-00)" 1
configurer 'EXCLURE=""'
verifier "sans aucune exclusion (tableau vide, bash 3.2) : réussi" "$(lancer 2026-09-14_06-00-00)" 0
configurer

echo "E. Un seul passage à la fois"
mkdir "$SAUV/.backup-goship.verrou"; sleep 60 & vivant=$!; echo "$vivant" > "$SAUV/.backup-goship.verrou/pid"
verifier "un passage en cours : le second s'arrête sans rien faire" "$(lancer 2026-09-15_05-00-00)" 0
verifier "… aucune archive créée, le verrou de l'autre intact" "$(ls "$SAUV"/goship-express-site-2026-09-15* 2> /dev/null | wc -l | tr -d ' ')/$(cat "$SAUV/.backup-goship.verrou/pid")" "0/$vivant"
kill "$vivant" 2> /dev/null; wait "$vivant" 2> /dev/null
verifier "verrou d'un passage mort : repris, sauvegarde faite" "$(lancer 2026-09-15_05-00-00)" 0
verifier "… et le journal le dit" "$(grep -c 'passage interrompu' "$SAUV/backup.log")" 1

echo "F. Hygiène"
verifier "aide" "$("$BASH_ESSAI" "$SCRIPT" --aide | grep -c 'backup-goship.sh --verifier')" 1
verifier "option inconnue : refusée" "$("$BASH_ESSAI" "$SCRIPT" --nimporte > /dev/null 2>&1; echo $?)" 2
verifier "première ligne : #!/bin/bash (et rien d'autre)" "$(head -1 "$SCRIPT")" "#!/bin/bash"

echo
echo "$total vérifications, $reussies réussies."
[ "$total" = "$reussies" ]
