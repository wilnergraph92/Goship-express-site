#!/bin/bash
# =============================================================================
# Goship Express — le service répond-il ? (Phase 12)
#
#   bash outils/production/surveiller.sh [adresse du site]
#
# Sans argument : la production. Lecture seule : quelques GET sur le site, un
# appel à la santé de l'authentification, sante() et suivre_colis() avec la clé
# publique du site (celle de assets/js/config.js, faite pour être publique).
# Aucune écriture, aucun compte, aucun secret.
#
# Lancé par .github/workflows/surveillance.yml (toutes les 30 minutes) et par
# deploy.yml juste après chaque mise en ligne. Sortie : une ligne par contrôle,
# code 1 dès qu'un contrôle échoue — GitHub prévient alors le propriétaire du
# dépôt (voir docs/production/monitoring.md).
#
# Variables facultatives :
#   SUPABASE_URL, SUPABASE_CLE   sinon lues dans assets/js/config.js
#   SANS_SUPABASE=1              contrôler le site seul
#   SURVEILLANCE_TOLERANTE=1     avant une mise en ligne (pull request) : ce qui
#                                dépend d'une version pas encore publiée (fichiers
#                                retirés, sante() pas encore installée) n'est
#                                qu'un avertissement
# =============================================================================
set -uo pipefail

SITE="${1:-https://wilnergraph92.github.io/Goship-express-site/}"
SITE="${SITE%/}/"
ICI="$(cd "$(dirname "$0")" && pwd)"
RACINE="$(cd "$ICI/../.." && pwd)"
echecs=0
avertissements=0

ok()     { echo "OK       $1"; }
echec()  { echo "ÉCHEC    $1"; echecs=$((echecs + 1)); }
averti() { echo "ATTENTION $1"; avertissements=$((avertissements + 1)); }
tolerant() { if [ "${SURVEILLANCE_TOLERANTE:-}" = 1 ]; then averti "$1 (toléré avant publication)"; else echec "$1"; fi; }

# Une page lente ou un CDN qui se met à jour : trois essais, 20 s d'écart
recuperer() {
  local url="$1" sortie="$2" code
  for essai in 1 2 3; do
    code="$(curl -sS -o "$sortie" -w '%{http_code}' --max-time 20 "$url" 2>/dev/null || echo 000)"
    [ "$code" = 200 ] && { echo 200; return; }
    [ "$essai" -lt 3 ] && sleep 20
  done
  echo "$code"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "== Site : $SITE"
# Pages publiques, espace client, tableau de bord, une traduction : chacune complète
for page in index.html connexion.html mon-compte.html admin.html en/index.html ht/index.html; do
  code="$(recuperer "$SITE$page" "$tmp/page")"
  if [ "$code" = 200 ] && grep -qi '</html>' "$tmp/page"; then ok "$page ($code)"
  else echec "$page : code $code"; fi
done
code="$(recuperer "${SITE}assets/js/api.js" "$tmp/api")"
if [ "$code" = 200 ] && grep -q 'GoshipAPI' "$tmp/api"; then ok "assets/js/api.js"; else echec "assets/js/api.js : code $code"; fi
# config.js publié avec l'adresse de la base : sinon le site passe en mode « hors service »
code="$(recuperer "${SITE}assets/js/config.js" "$tmp/config")"
if [ "$code" = 200 ] && grep -q 'supabase.co' "$tmp/config"; then ok "assets/js/config.js (base configurée)"
else echec "assets/js/config.js : code $code ou base non configurée"; fi
# Une vraie clé secrète : préfixe sb_secret_, ou jeton JWT dont le rôle est service_role
# (le mot « service_role » seul, dans un commentaire, n'est pas une clé)
if python3 - "$tmp/config" "$tmp/api" <<'PY'
import base64, json, re, sys
for f in sys.argv[1:]:
    t = open(f, encoding='utf-8', errors='ignore').read()
    if re.search(r'sb_secret_[A-Za-z0-9_-]{8,}', t):
        sys.exit(0)
    for j in re.findall(r'eyJ[A-Za-z0-9_-]{8,}\.(eyJ[A-Za-z0-9_-]{8,})\.[A-Za-z0-9_-]{8,}', t):
        try:
            if json.loads(base64.urlsafe_b64decode(j + '=' * (-len(j) % 4))).get('role') == 'service_role':
                sys.exit(0)
        except Exception:
            pass
sys.exit(1)
PY
then echec "une clé secrète (service_role ou sb_secret_) apparaît dans un fichier publié"
else ok "aucune clé secrète dans config.js et api.js"; fi

case "$SITE" in
  https://*)
    # Les fichiers de travail ne sont pas servis (deploy.yml les retire)
    for f in CLAUDE.md README.md outils/supabase.sql outils/migrations.txt bureau/package.json docs/notifications.md; do
      code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$SITE$f" 2>/dev/null || echo 000)"
      if [ "$code" = 404 ]; then ok "$f non servi"; else tolerant "$f servi publiquement (code $code)"; fi
    done
    # HTTP redirige vers HTTPS
    http="http://${SITE#https://}"
    entete="$(curl -sS -o /dev/null -D - --max-time 20 "$http" 2>/dev/null | tr -d '\r')"
    if echo "$entete" | grep -Eiq '^HTTP/[0-9.]+ 30[18]' && echo "$entete" | grep -iq '^location: https://'; then
      ok "HTTP redirige vers HTTPS"
    else averti "HTTP ne redirige pas vers HTTPS (à activer : Settings > Pages > Enforce HTTPS)"; fi
    ;;
esac

if [ "${SANS_SUPABASE:-}" = 1 ]; then
  echo "== Base : non contrôlée (SANS_SUPABASE=1)"
else
  URL="${SUPABASE_URL:-$(grep -Eo "supabaseUrl: *'[^']+'" "$RACINE/assets/js/config.js" | cut -d"'" -f2)}"
  CLE="${SUPABASE_CLE:-$(grep -Eo "supabaseKey: *'[^']+'" "$RACINE/assets/js/config.js" | cut -d"'" -f2)}"
  echo "== Base : ${URL%%.*}…"
  if [ -z "$URL" ] || [ -z "$CLE" ]; then
    echec "adresse ou clé publique de la base introuvable"
  else
    code="$(curl -sS -o "$tmp/auth" -w '%{http_code}' --max-time 20 -H "apikey: $CLE" "$URL/auth/v1/health" 2>/dev/null || echo 000)"
    if [ "$code" = 200 ]; then ok "authentification (auth/v1/health)"; else echec "authentification : code $code"; fi

    code="$(curl -sS -o "$tmp/sante" -w '%{http_code}' --max-time 20 -X POST -H "apikey: $CLE" \
            -H 'Content-Type: application/json' -d '{}' \
            "$URL/rest/v1/rpc/sante" 2>/dev/null || echo 000)"
    if [ "$code" = 200 ]; then
      etat="$(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d.get('status'),d.get('pret'),d.get('notifications'))" "$tmp/sante" 2>/dev/null)"
      case "$etat" in
        "ok True "*) ok "base : ${etat}" ;;
        "ok False en_retard") echec "file des notifications bloquée depuis plus de 15 min (pg_cron ?)" ;;
        *) echec "sante() inattendue : $etat" ;;
      esac
    elif [ "$code" = 404 ]; then
      # Avertissement seulement : tant que la migration n'est pas passée en production,
      # l'authentification et le suivi public (plus bas) disent déjà si la base répond
      averti "sante() absente : exécuter outils/supabase-production.sql (docs/production/go-no-go.md)"
    else
      echec "base : sante() répond $code"
    fi

    # (apikey seule, sans « Authorization » : la passerelle joue alors le visiteur,
    # avec une clé publishable comme avec l'ancienne clé anon JWT)
    # Le suivi public (ce que voit un visiteur) : un numéro qui n'existe pas → null
    code="$(curl -sS -o "$tmp/suivi" -w '%{http_code}' --max-time 20 -X POST -H "apikey: $CLE" \
            -H 'Content-Type: application/json' \
            -d '{"p_numero":"GSE-0000-ZZ"}' "$URL/rest/v1/rpc/suivre_colis" 2>/dev/null || echo 000)"
    if [ "$code" = 200 ]; then ok "suivi public (suivre_colis)"; else echec "suivi public : code $code"; fi
  fi
fi

echo "== $echecs échec(s), $avertissements avertissement(s)"
[ "$echecs" -eq 0 ]
