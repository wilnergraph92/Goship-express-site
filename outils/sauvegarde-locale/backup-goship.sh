#!/bin/bash
# =============================================================================
# GoShip Express — sauvegarde chiffrée du dossier du projet (Mac → Backblaze B2)
#
#   backup-goship.sh                         sauvegarder (ce que lance launchd chaque jour)
#   backup-goship.sh --verifier <clé> [nom]  relire la dernière archive (ou <nom>) depuis
#                                            B2, la déchiffrer en mémoire et la lister
#   backup-goship.sh --aide
#
# Ce que ce script sauvegarde : le DOSSIER du projet (le code, son historique Git et
# le travail pas encore poussé). Pas la base Supabase : clients, colis, factures,
# paiements et comptes ne vivent que dans la base, et se sauvegardent à part
# (.github/workflows/sauvegarde.yml, outils/README-backup.md).
#
# Chaque passage :
#   1. un seul passage à la fois (verrou ; un verrou laissé par un passage mort est repris) ;
#   2. tar | gzip | age : l'archive est chiffrée au vol pour la ou les clés PUBLIQUES du
#      fichier de destinataires ; le contenu en clair ne touche jamais le disque ;
#   3. l'archive s'écrit sous un nom provisoire et ne prend son vrai nom qu'une fois
#      complète, chiffrée (en-tête age) et son empreinte SHA-256 écrite à côté ;
#   4. envoi vers B2 (rclone), puis RELECTURE : l'empreinte que B2 garde du fichier
#      (SHA-1, sans le retélécharger) doit être celle du fichier local ;
#   5. rétention locale (7 par défaut) et, si on la demande, distante (garde-fous) ;
#   6. le journal dit chaque étape ; un échec y est écrit avec son étape, s'affiche en
#      notification macOS, et le code de sortie n'est pas 0.
#
# Réglages : un fichier de configuration (voir goship-backup.conf.exemple), jamais de
# secret dedans. Les accès à B2 restent dans la configuration de rclone ; la clé
# PRIVÉE age ne sert qu'à --verifier, lue par age seul, jamais affichée ni copiée.
#
# Compatible avec le bash 3.2 de macOS (/bin/bash) et les outils BSD du Mac.
# Guide : outils/sauvegarde-locale/LISEZ-MOI.md
# =============================================================================
set -euo pipefail
umask 077
# launchd lance les tâches avec un PATH minimal : on y met Homebrew (Apple Silicon, puis Intel)
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# -----------------------------------------------------------------------------
# Réglages : valeurs par défaut (celles de l'installation d'origine), puis le fichier
# de configuration s'il existe
# -----------------------------------------------------------------------------
BACKUP_DIR="$HOME/GoShip-Backups"
SOURCE="$BACKUP_DIR/Goship-express-site"
REMOTE="goship-a:goship-sauvegardes/goship-express"
AGE_RECIPIENTS_FILE="$BACKUP_DIR/config/age-recipients.txt"
LOG="$BACKUP_DIR/backup.log"
LOCAL_KEEP=7          # archives gardées sur le Mac (1 au moins)
REMOTE_KEEP=0         # archives gardées sur B2 : 0 = toutes (rien n'est jamais supprimé)
NOTIFIER=1            # notification macOS en cas d'échec
# Reconstructibles (npm install) et lourds : jamais dans l'archive
EXCLURE="node_modules .DS_Store"

CONF="${GOSHIP_BACKUP_CONF:-$BACKUP_DIR/config/goship-backup.conf}"
if [ -f "$CONF" ]; then
  # Un fichier de configuration est du code : il doit n'être modifiable que par nous
  if [ -n "$(find "$CONF" \( -perm -020 -o -perm -002 \) -print 2> /dev/null)" ] || [ ! -O "$CONF" ]; then
    echo "Configuration refusée : $CONF doit appartenir à $(id -un) et n'être modifiable que par lui (chmod 600)." >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  . "$CONF"
fi

MINIMUM_DISTANT=7     # REMOTE_KEEP, s'il est posé, ne descend jamais en dessous
MAX_SUPPRESSIONS=3    # suppressions distantes au plus par passage
PREFIXE="goship-express-site-"
SUFFIXE=".tar.gz.age"
# goship-express-site-AAAA-MM-JJ_HH-MM-SS.tar.gz.age (le format d'origine, gardé)
MOTIF_NOM='^goship-express-site-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}\.tar\.gz\.age$'
VERROU="$BACKUP_DIR/.backup-goship.verrou"
ETAT="$BACKUP_DIR/derniere-sauvegarde.txt"
RC=(rclone --retries 3 --low-level-retries 5 --stats 0 -q)

etape="démarrage"
partiel=""
temporaire=""
verrou_pris=0

# -----------------------------------------------------------------------------
# Journal, échec, nettoyage
# -----------------------------------------------------------------------------
journal() {
  local ligne
  ligne="[$(date '+%Y-%m-%d %H:%M:%S %z')] $*"
  echo "$ligne"
  if [ -d "$(dirname "$LOG")" ]; then echo "$ligne" >> "$LOG"; fi
}

notifier() {
  [ "$NOTIFIER" = 1 ] || return 0
  command -v osascript > /dev/null 2>&1 || return 0
  osascript -e "display notification \"$1\" with title \"GoShip Express\" subtitle \"Sauvegarde du code\"" > /dev/null 2>&1 || true
}

terminer() {
  local code=$?
  set +e
  [ -n "$partiel" ] && rm -f "$partiel" "$partiel.sha256"
  [ -n "$temporaire" ] && rm -rf "$temporaire"
  if [ "$verrou_pris" = 1 ]; then rm -rf "$VERROU"; fi
  if [ "$code" -ne 0 ]; then
    journal "ÉCHEC (code $code) pendant : $etape"
    notifier "ÉCHEC pendant : $etape. Voir $LOG"
  fi
  exit "$code"
}
trap terminer EXIT
trap 'exit 130' INT TERM

echouer() { journal "ERREUR : $*"; exit 1; }

# SHA-256 et SHA-1 d'un fichier (shasum existe sur macOS comme sur Linux)
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
sha1()   { shasum -a 1 "$1" | awk '{print $1}'; }
octets() { wc -c < "$1" | tr -d ' '; }

outils() {
  local manque="" o
  for o in "$@"; do command -v "$o" > /dev/null 2>&1 || manque="$manque $o"; done
  [ -z "$manque" ] || echouer "outil(s) introuvable(s) :$manque (brew install age rclone)"
}

# Les noms d'archives présents dans une liste (un par ligne), du plus récent au plus ancien.
# Le nom porte sa date : l'ordre alphabétique est l'ordre chronologique.
archives_de() { grep -E "$MOTIF_NOM" | LC_ALL=C sort -r || true; }

prendre_verrou() {
  mkdir -p "$BACKUP_DIR"
  if mkdir "$VERROU" 2> /dev/null; then
    echo $$ > "$VERROU/pid"; verrou_pris=1; return 0
  fi
  local ancien
  ancien="$(cat "$VERROU/pid" 2> /dev/null || true)"
  if [ -n "$ancien" ] && kill -0 "$ancien" 2> /dev/null; then
    journal "Une sauvegarde est déjà en cours (processus $ancien) : ce passage s'arrête sans rien faire."
    exit 0
  fi
  journal "Verrou d'un passage interrompu (processus ${ancien:-inconnu}, terminé) : repris."
  rm -rf "$VERROU"
  mkdir "$VERROU" || echouer "verrou impossible à prendre"
  echo $$ > "$VERROU/pid"; verrou_pris=1
}

# Pose n_dest : le nombre de clés publiques du fichier des destinataires
destinataires_valides() {
  [ -f "$AGE_RECIPIENTS_FILE" ] || echouer "fichier des destinataires age introuvable : $AGE_RECIPIENTS_FILE (voir LISEZ-MOI.md, installation)"
  if grep -q 'AGE-SECRET-KEY' "$AGE_RECIPIENTS_FILE"; then
    echouer "$AGE_RECIPIENTS_FILE contient une clé PRIVÉE : il ne doit contenir que des clés publiques age1…"
  fi
  n_dest="$(grep -cE '^age1[0-9a-z]{58}$' "$AGE_RECIPIENTS_FILE" || true)"
  [ "$n_dest" -ge 1 ] || echouer "aucune clé publique age valide (age1…) dans $AGE_RECIPIENTS_FILE"
}

# -----------------------------------------------------------------------------
# Sauvegarder
# -----------------------------------------------------------------------------
sauvegarder() {
  etape="vérifications"
  outils tar gzip age rclone shasum
  prendre_verrou
  journal "Début de la sauvegarde GoShip Express (code)"
  [ -d "$SOURCE" ] || echouer "dossier du projet introuvable : $SOURCE"
  [ -n "$(ls -A "$SOURCE" 2> /dev/null)" ] || echouer "dossier du projet vide : $SOURCE"
  [[ "$LOCAL_KEEP" =~ ^[0-9]+$ ]] && [ "$LOCAL_KEEP" -ge 1 ] || echouer "LOCAL_KEEP doit valoir 1 au moins"
  [[ "$REMOTE_KEEP" =~ ^[0-9]+$ ]] || echouer "REMOTE_KEEP doit être un nombre (0 = tout garder)"
  if [ "$REMOTE_KEEP" -ne 0 ] && [ "$REMOTE_KEEP" -lt "$MINIMUM_DISTANT" ]; then
    echouer "REMOTE_KEEP refusé : 0 (tout garder) ou $MINIMUM_DISTANT au moins"
  fi
  local n_dest
  destinataires_valides

  # L'état du dépôt, pour retrouver ce que contient chaque archive (aucune donnée sensible)
  if [ -d "$SOURCE/.git" ] && command -v git > /dev/null 2>&1; then
    local commit branche modifies
    commit="$(git -C "$SOURCE" rev-parse --short HEAD 2> /dev/null || echo '?')"
    branche="$(git -C "$SOURCE" rev-parse --abbrev-ref HEAD 2> /dev/null || echo '?')"
    modifies="$(git -C "$SOURCE" status --porcelain 2> /dev/null | wc -l | tr -d ' ')"
    journal "Projet : branche $branche, commit $commit, $modifies fichier(s) modifié(s) non commité(s)"
  fi

  etape="archive chiffrée"
  local horodatage nom archive exclusions=() motif
  horodatage="${GOSHIP_HORODATAGE:-$(date +"%Y-%m-%d_%H-%M-%S")}"
  nom="$PREFIXE$horodatage$SUFFIXE"
  archive="$BACKUP_DIR/$nom"
  [ ! -e "$archive" ] || echouer "une archive porte déjà ce nom : $nom"
  for motif in $EXCLURE; do exclusions+=(--exclude "$motif"); done
  partiel="$BACKUP_DIR/.$nom.partiel"
  # ${a[@]+…} : un tableau vide sous « set -u » fait échouer le bash 3.2 du Mac
  tar -czf - ${exclusions[@]+"${exclusions[@]}"} -C "$(dirname "$SOURCE")" "$(basename "$SOURCE")" \
    | age -R "$AGE_RECIPIENTS_FILE" -o "$partiel"

  etape="contrôle de l'archive"
  [ -s "$partiel" ] || echouer "archive vide"
  [ "$(head -c 21 "$partiel")" = "age-encryption.org/v1" ] || echouer "l'archive n'est pas chiffrée (en-tête age absent)"
  [ "$(octets "$partiel")" -ge 1024 ] || echouer "archive suspecte : moins de 1 ko"
  mv "$partiel" "$archive"
  partiel=""                   # complète et chiffrée : gardée sur le Mac même si l'envoi échoue
  ( cd "$BACKUP_DIR" && shasum -a 256 "$nom" > "$nom.sha256" )
  journal "Archive créée : $nom ($(octets "$archive") octets, chiffrée pour $n_dest clé(s), SHA-256 $(sha256 "$archive" | cut -c1-16)…)"

  etape="envoi vers Backblaze B2"
  "${RC[@]}" copyto "$archive" "$REMOTE/$nom"
  "${RC[@]}" copyto "$archive.sha256" "$REMOTE/$nom.sha256"

  etape="relecture sur Backblaze B2"
  local distant local1
  local1="$(sha1 "$archive")"
  distant="$("${RC[@]}" hashsum sha1 "$REMOTE/$nom" 2> /dev/null | awk '{print $1}' | head -1 || true)"
  if [ -z "$distant" ]; then
    # Le stockage ne donne pas d'empreinte : on relit le fichier entier
    distant="$("${RC[@]}" cat "$REMOTE/$nom" | shasum -a 1 | awk '{print $1}')"
  fi
  [ "$distant" = "$local1" ] || echouer "l'archive relue sur B2 diffère de l'archive locale (SHA-1)"
  "${RC[@]}" cat "$REMOTE/$nom.sha256" | cmp -s - "$archive.sha256" || echouer "l'empreinte relue sur B2 diffère"
  journal "Envoi vers B2 terminé et relu (empreinte identique)"

  etape="rétention locale"
  retention_locale
  if [ "$REMOTE_KEEP" -gt 0 ]; then
    etape="rétention sur B2"
    retention_distante
  fi

  printf 'date: %s\narchive: %s\nsha256: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$nom" "$(sha256 "$archive")" > "$ETAT"
  etape="fin"
  journal "Sauvegarde terminée avec succès : $nom"
}

retention_locale() {
  local toutes a_supprimer n=0 f
  toutes="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "$PREFIXE*$SUFFIXE" | sed 's#.*/##' | archives_de)"
  a_supprimer="$(printf '%s\n' "$toutes" | sed -n "$((LOCAL_KEEP + 1)),\$p")"
  for f in $a_supprimer; do
    [[ "$f" =~ $MOTIF_NOM ]] || continue
    rm -f "$BACKUP_DIR/$f" "$BACKUP_DIR/$f.sha256"
    n=$((n + 1))
  done
  journal "Rétention locale : $(printf '%s\n' "$toutes" | grep -c . || true) archive(s) avant, $n supprimée(s), $LOCAL_KEEP gardée(s) au plus"
}

retention_distante() {
  local toutes total a_supprimer n=0 f restantes
  toutes="$("${RC[@]}" lsf --files-only "$REMOTE" | archives_de)"
  total="$(printf '%s\n' "$toutes" | grep -c . || true)"
  if [ "$total" -le "$REMOTE_KEEP" ]; then
    journal "Rétention B2 : $total archive(s), rien à supprimer (on en garde $REMOTE_KEEP)"
    return 0
  fi
  a_supprimer="$(printf '%s\n' "$toutes" | sed -n "$((REMOTE_KEEP + 1)),\$p")"
  for f in $a_supprimer; do
    [[ "$f" =~ $MOTIF_NOM ]] || echouer "nom inattendu dans la liste B2 : arrêt, rien de plus n'est supprimé"
    if [ "$n" -ge "$MAX_SUPPRESSIONS" ]; then
      journal "Rétention B2 : plus de $MAX_SUPPRESSIONS archives à supprimer ; le reste au prochain passage"
      break
    fi
    "${RC[@]}" deletefile "$REMOTE/$f"
    "${RC[@]}" deletefile "$REMOTE/$f.sha256" 2> /dev/null || true   # absente pour les anciennes archives
    n=$((n + 1))
  done
  restantes="$("${RC[@]}" lsf --files-only "$REMOTE" | archives_de | grep -c . || true)"
  [ "$restantes" -ge "$REMOTE_KEEP" ] || echouer "Rétention B2 : seulement $restantes archive(s) après suppression"
  journal "Rétention B2 : $n supprimée(s), $restantes gardée(s)"
}

# -----------------------------------------------------------------------------
# Vérifier : relire une archive depuis B2, comme pour une vraie restauration
# -----------------------------------------------------------------------------
verifier() {
  local cle="${1:-}" nom="${2:-}"
  etape="vérification (préparation)"
  outils tar gzip age rclone shasum
  [ -n "$cle" ] || echouer "usage : backup-goship.sh --verifier <fichier de la clé PRIVÉE age> [nom de l'archive]"
  [ -f "$cle" ] || echouer "fichier de clé introuvable (le chemin donné n'existe pas)"
  if [ -z "$nom" ]; then
    nom="$("${RC[@]}" lsf --files-only "$REMOTE" | archives_de | head -1)"
    [ -n "$nom" ] || echouer "aucune archive sur B2 ($REMOTE)"
  fi
  [[ "$nom" =~ $MOTIF_NOM ]] || echouer "nom d'archive invalide : $nom"
  journal "Vérification de $nom (depuis B2)"

  temporaire="$(mktemp -d "${TMPDIR:-/tmp}/goship-verif.XXXXXX")"
  etape="vérification (téléchargement)"
  "${RC[@]}" copyto "$REMOTE/$nom" "$temporaire/$nom"
  if "${RC[@]}" copyto "$REMOTE/$nom.sha256" "$temporaire/$nom.sha256" 2> /dev/null; then
    ( cd "$temporaire" && shasum -a 256 -c -s "$nom.sha256" ) || echouer "SHA-256 différent : archive altérée"
    journal "SHA-256 : conforme"
  else
    journal "SHA-256 : pas d'empreinte sur B2 (archive d'avant la version actuelle du script), non vérifié"
  fi

  etape="vérification (déchiffrement et lecture)"
  local liste="$temporaire/liste.txt" base
  # Le clair ne passe que par un tube : jamais sur le disque
  age -d -i "$cle" "$temporaire/$nom" | tar -tzf - > "$liste" \
    || echouer "déchiffrement ou lecture impossible (mauvaise clé, ou archive abîmée)"
  base="$(basename "$SOURCE")"
  grep -q "^$base/" "$liste" || echouer "l'archive ne contient pas le dossier $base/"
  local git="non"
  grep -qE "^$base/\.git/HEAD$" "$liste" && git="oui"
  journal "Archive lisible : $(grep -c . "$liste") entrées, historique Git présent : $git"
  etape="fin"
  journal "VÉRIFICATION RÉUSSIE : $nom se déchiffre et se relit entièrement"
}

case "${1:-}" in
  "")            sauvegarder ;;
  --verifier)    verifier "${2:-}" "${3:-}" ;;
  --aide|-h)     sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)             echo "Option inconnue : $1 (--aide)" >&2; exit 2 ;;
esac
