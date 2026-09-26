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
# SANS_PG_NET=1 : pour une base PostgreSQL ordinaire (essai de restauration en CI),
# la ligne qui crée l'extension pg_net est retirée (les doublures la remplacent).
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

depart="${1:-}"
commence=$([ -z "$depart" ] && echo oui || echo non)
travail="$(mktemp -d)"; trap 'rm -rf "$travail"' EXIT
n=0
while read -r f; do
  case "$f" in ''|\#*) continue ;; esac
  [ "$f" = "$depart" ] && commence=oui
  [ "$commence" = oui ] || continue
  source="$OUTILS/$f"
  if [ "${SANS_PG_NET:-}" = 1 ]; then
    sed 's/^create extension if not exists pg_net with schema extensions;$//' "$source" > "$travail/$f"
    source="$travail/$f"
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
