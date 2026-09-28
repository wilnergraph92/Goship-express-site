#!/bin/bash
# =============================================================================
# Goship Express — prévenir une seconde personne (ALERTE_WEBHOOK)
#
#   ALERTE_WEBHOOK=… bash outils/production/alerter.sh "<texte>"
#
# Slack, Discord, ou ntfy (tout autre adresse). Sans ALERTE_WEBHOOK : rien, et le
# dit (le workflow en échec prévient déjà le propriétaire du dépôt par GitHub).
# Le texte ne doit contenir aucune donnée : un titre et le lien du journal.
# Même logique que l'alerte de surveillance.yml.
# =============================================================================
set -euo pipefail
texte="${1:?texte manquant}"
[ -n "${ALERTE_WEBHOOK:-}" ] || { echo "ALERTE_WEBHOOK non posé : seul le propriétaire du dépôt est prévenu (workflow en échec)."; exit 0; }
# Le corps JSON, construit hors du « case » (bash lit mal une parenthèse de $(…) dans un case)
json_de() { python3 -c 'import json,sys; print(json.dumps({sys.argv[1]: sys.argv[2]}))' "$1" "$texte"; }
case "$ALERTE_WEBHOOK" in
  *hooks.slack.com*) curl -fsS -m 10 -H 'Content-Type: application/json' -d "$(json_de text)" "$ALERTE_WEBHOOK" > /dev/null ;;
  *discord.com*)     curl -fsS -m 10 -H 'Content-Type: application/json' -d "$(json_de content)" "$ALERTE_WEBHOOK" > /dev/null ;;
  *)                 curl -fsS -m 10 -H 'Title: GoShip Express' -H 'Priority: urgent' -d "$texte" "$ALERTE_WEBHOOK" > /dev/null ;;
esac
echo "Alerte envoyée."
