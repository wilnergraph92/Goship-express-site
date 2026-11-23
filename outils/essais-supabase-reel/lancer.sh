#!/bin/bash
# =============================================================================
#  Goship Express — essai de la chaîne complète sur l'IMAGE SUPABASE RÉELLE
#
#    bash outils/essais-supabase-reel/lancer.sh
#
#  Démarre un conteneur jetable ghcr.io/supabase/postgres (PostgreSQL 17, extensions
#  réelles pgcrypto, Vault, pg_net, pg_cron ; postgres NON superutilisateur, comme
#  en production), applique outils/migrations.txt EN ENTIER (candidates du Centre
#  de communication comprises), la rejoue une seconde fois (rejouabilité), puis lance
#  verifier.py. Le conteneur est supprimé à la fin, réussite ou échec.
#
#  Ce que pgserver ne montre pas et que cet essai montre : le vrai chiffrement, le
#  vrai Vault, et les droits d'un postgres non superutilisateur (constat du
#  23/11/2026 : la candidate 009 échouait sur toute base Supabase).
#
#  GARDE-FOUS : le conteneur tourne SANS AUCUN RÉSEAU (--network none). La chaîne
#  programme des tâches pg_cron (notifications, accusés Expo…) qui, sur une vraie
#  instance, appellent les fournisseurs par pg_net : ici, aucun appel ne peut sortir.
#  Tout passe par « docker exec » dans ce conteneur ; aucune variable ne permet de
#  viser une autre base. Exige : docker, python3.
# =============================================================================
set -euo pipefail
ICI="$(cd "$(dirname "$0")" && pwd)"
OUTILS="$(cd "$ICI/.." && pwd)"
IMAGE="${IMAGE_SUPABASE:-ghcr.io/supabase/postgres:17.4.1.054}"
NOM="goship-essai-supabase-reel-$$"
MDP="essai-jetable"
export CONTENEUR_ESSAI="$NOM"
# psql DANS le conteneur, connexion locale à sa propre base
dpsql() { local role="$1"; shift; docker exec -i -e PGPASSWORD="$MDP" "$NOM" psql -h 127.0.0.1 -U "$role" -d postgres "$@"; }
trap 'docker rm -f "$NOM" >/dev/null 2>&1 || true' EXIT

docker run -d --name "$NOM" --network none -e POSTGRES_PASSWORD="$MDP" "$IMAGE" >/dev/null
for i in $(seq 1 90); do
  dpsql postgres -X -At -c 'select 1' >/dev/null 2>&1 && break
  [ "$i" = 90 ] && { echo "La base du conteneur ne répond pas."; exit 1; }
  sleep 2
done
dpsql supabase_admin -X -q -v ON_ERROR_STOP=1 -f - < "$ICI/plateforme.sql" 2>&1 | grep -v NOTICE || true
# Preuve de l'isolement : seule l'interface locale existe dans le conteneur
if docker exec "$NOM" sh -c 'ls /sys/class/net' | grep -qv '^lo$'; then
  echo "REFUS : le conteneur a une interface réseau autre que lo."; exit 1
fi

appliquer() {
  local n=0 f r
  while read -r f; do
    case "$f" in ''|\#*) continue ;; esac
    r=postgres
    # 009 crée l'identité PostgREST des Edge Functions : elle exige une session
    # superutilisateur (voir son en-tête) ; tout le reste passe par postgres.
    case "$f" in *009-communication-identite-edge.sql) r=supabase_admin ;; esac
    if ! dpsql "$r" -X -q -v ON_ERROR_STOP=1 --single-transaction -f - < "$OUTILS/$f" > /dev/null 2> /tmp/goship-essai-reel.err; then
      echo "ÉCHEC ($1) $f"
      grep -vE 'NOTICE|already a transaction' /tmp/goship-essai-reel.err | head -8
      exit 1
    fi
    n=$((n + 1))
  done < "$OUTILS/migrations.txt"
  echo "Chaîne $1 : $n fichiers appliqués sans erreur."
}
appliquer "premier passage"
appliquer "rejeu"
python3 -I "$ICI/verifier.py"
