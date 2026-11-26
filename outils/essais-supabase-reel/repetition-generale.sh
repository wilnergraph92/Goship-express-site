#!/bin/bash
# =============================================================================
#  Goship Express — RÉPÉTITION GÉNÉRALE du Centre de communication sur un PROJET
#  SUPABASE D'ESSAI hébergé (jamais la production).
#
#    REPETITION_DB_URL='postgresql://postgres:…@db.<ref>.supabase.co:5432/postgres' \
#      bash outils/essais-supabase-reel/repetition-generale.sh
#
#  1. refuse l'adresse de la production, et demande de retaper la référence du projet ;
#  2. applique outils/migrations.txt EN ENTIER, candidates comprises, par postgres
#     (outils/production/appliquer-chaine.sh), puis la rejoue (rejouabilité) ;
#  3. lance verifier.py en mode hébergé (vrai pgcrypto, vrai Vault, webhook signé de bout
#     en bout, droits, classification STOP, tâches pg_cron).
#
#  Le mot de passe reste chez vous : il n'est ni affiché ni écrit nulle part.
#  Sur ce projet d'essai : AUCUNE clé de fournisseur (Brevo, Meta, Expo) et aucune donnée
#  de client. Sans clé, les tâches pg_cron ne peuvent rien envoyer.
#  Exige : psql (macOS : brew install libpq && brew link --force libpq) et python3.
# =============================================================================
set -euo pipefail
ICI="$(cd "$(dirname "$0")" && pwd)"
RACINE="$(cd "$ICI/../.." && pwd)"
PRODUCTION_REF="gpfdyslysqjmojgzggib"
: "${REPETITION_DB_URL:?REPETITION_DB_URL manquante : l'adresse de connexion du projet d'ESSAI}"

if [[ "$REPETITION_DB_URL" == *"$PRODUCTION_REF"* ]]; then
  echo "REFUS : cette adresse est celle de la PRODUCTION. La répétition se fait sur un projet d'essai."
  exit 3
fi
ref="$(printf '%s' "$REPETITION_DB_URL" | sed -nE 's#.*(db\.|postgres\.)([a-z0-9]{20}).*#\2#p')"
if [ -z "$ref" ]; then
  echo "REFUS : impossible de lire la référence du projet dans l'adresse."
  exit 3
fi
echo "Projet d'essai : $ref"
read -r -p "Retapez cette référence pour confirmer qu'il s'agit bien du projet d'ESSAI : " confirmation
[ "$confirmation" = "$ref" ] || { echo "Abandon : référence différente."; exit 3; }

export CIBLE_DB_URL="$REPETITION_DB_URL" APPLIQUER_CANDIDATES=oui
echo "== Premier passage de la chaîne"
bash "$RACINE/outils/production/appliquer-chaine.sh"
echo "== Rejeu de la chaîne"
bash "$RACINE/outils/production/appliquer-chaine.sh"
echo "== Vérifications"
REPETITION_DB_URL="$REPETITION_DB_URL" python3 -I "$ICI/verifier.py"
