#!/bin/bash
# =============================================================================
# Goship Express — appliquer la chaîne officielle des migrations à une base
#
#   CIBLE_DB_URL=… bash outils/production/appliquer-chaine.sh [à partir de <fichier>]
#
# Exécute, dans l'ordre de outils/migrations.txt, chaque fichier SQL (tous
# rejouables sans risque), un par un, et s'arrête au premier en erreur — le
# suivant n'est jamais lancé sur une base à moitié migrée. Chaque fichier passe en
# une seule transaction (--single-transaction) : une erreur l'annule en entier.
#
# GARDE-FOU PRODUCTION : si l'adresse est celle du projet de production
# (gpfdyslysqjmojgzggib), le script refuse, sauf CONFIRMER_PRODUCTION=gpfdyslysqjmojgzggib.
# Il ne se lance jamais ainsi depuis un workflow : la production se migre à la
# main, après la préproduction et une restauration réussie (docs/production/deployment.md).
#
# GARDE-FOU COMMUNICATION CENTER : les fichiers migrations-candidates/ ferment la
# chaîne depuis le 23/11/2026 (étape C11), pour les essais locaux et la CI
# seulement. Par défaut le script S'ARRÊTE avant eux (code 0, la chaîne d'avant
# est complète). APPLIQUER_CANDIDATES=oui les applique, sur une base jetable ;
# sur l'adresse de production, ils sont refusés dans tous les cas (code 3), tant
# que la Phase 1.3.1 n'est pas validée et qu'une autorisation écrite nommée n'a
# pas levé cette garde (docs/production/go-no-go.md).
#
# SANS_PG_NET=1 : pour une base PostgreSQL ordinaire (essai de restauration en CI),
# les lignes qui créent les extensions pg_net et pgcrypto sont retirées (les
# doublures les remplacent).
# =============================================================================
set -euo pipefail

: "${CIBLE_DB_URL:?CIBLE_DB_URL manquante}"
PSQL="${PSQL:-psql}"
PRODUCTION_REF="gpfdyslysqjmojgzggib"
ICI="$(cd "$(dirname "$0")" && pwd)"
OUTILS="$(cd "$ICI/.." && pwd)"

if [[ "$CIBLE_DB_URL" == *"$PRODUCTION_REF"* ]] && [ "${CONFIRMER_PRODUCTION:-}" != "$PRODUCTION_REF" ]; then
  echo "REFUS : cette adresse est celle de la PRODUCTION."
  echo "La production se migre à la main, après la préproduction et une restauration réussie"
  echo "(docs/production/deployment.md). Pour confirmer : CONFIRMER_PRODUCTION=$PRODUCTION_REF"
  exit 3
fi

if [[ "$CIBLE_DB_URL" == *"$PRODUCTION_REF"* ]] && [ "${APPLIQUER_CANDIDATES:-}" = oui ]; then
  echo "REFUS : les fichiers migrations-candidates/ (Communication Center) ne s'appliquent pas"
  echo "en production avant la validation de la Phase 1.3.1 et une autorisation écrite nommée."
  exit 3
fi

depart="${1:-}"
commence=$([ -z "$depart" ] && echo oui || echo non)
travail="$(mktemp -d)"; trap 'rm -rf "$travail"' EXIT
n=0
while read -r f; do
  case "$f" in ''|\#*) continue ;; esac
  [ "$f" = "$depart" ] && commence=oui
  [ "$commence" = oui ] || continue
  case "$f" in
    migrations-candidates/*)
      if [ "${APPLIQUER_CANDIDATES:-}" != oui ]; then
        echo "ARRÊT  avant $f : les fichiers du Communication Center ne sont appliqués qu'avec"
        echo "       APPLIQUER_CANDIDATES=oui, sur une base jetable (garde-fou de l'étape C11)."
        break
      fi ;;
  esac
  source="$OUTILS/$f"
  if [ "${SANS_PG_NET:-}" = 1 ]; then
    # Nom à plat : une ligne de la chaîne peut désigner un sous-dossier (migrations-candidates/)
    copie="$travail/$(basename "$f")"
    sed -e 's/^create extension if not exists pg_net with schema extensions;$//' \
        -e 's/^create extension if not exists pgcrypto with schema extensions;$//' "$source" > "$copie"
    source="$copie"
  fi
  debut=$(date +%s)
  if ! "$PSQL" "$CIBLE_DB_URL" -X -q -v ON_ERROR_STOP=1 --single-transaction -f "$source" > "$travail/sortie" 2> "$travail/erreur"; then
    echo "ÉCHEC  $f — arrêt : aucun fichier suivant n'est lancé."
    sed -E 's#postgres(ql)?://[^ ]*#<adresse masquée>#g' "$travail/erreur" | grep -v '^NOTICE' | head -8
    exit 1
  fi
  n=$((n + 1))
  echo "OK     $f ($(( $(date +%s) - debut )) s)"
done < "$OUTILS/migrations.txt"
[ "$commence" = oui ] || { echo "Fichier de départ inconnu : $depart"; exit 2; }
echo "$n migration(s) appliquée(s)."
