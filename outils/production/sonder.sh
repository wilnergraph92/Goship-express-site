#!/bin/bash
# =============================================================================
# Goship Express — sonde anonyme de la base de production (Phase 12, finalisation)
#
#   bash outils/production/sonder.sh
#   (adresse et clé publique lues dans assets/js/config.js, ou SUPABASE_URL /
#    SUPABASE_CLE)
#
# Dit, SANS aucun secret, quelles migrations de la chaîne officielle sont passées
# en production : pour chaque fichier de outils/migrations.txt, une fonction témoin
# est appelée comme le ferait un visiteur, avec la seule clé publique.
#   401 + 42501 « permission denied »  → la fonction EXISTE (fermée aux visiteurs)
#   404 + PGRST202                      → la fonction N'EXISTE PAS
#   200                                 → elle existe et répond aux visiteurs
# Éprouvé contre PostgREST 12 (essai-production.py, section H).
#
# Rien ne peut être écrit : chaque appel est un GET, que PostgREST exécute dans une
# transaction EN LECTURE SEULE, et un visiteur n'a de toute façon le droit
# d'exécuter aucune de ces fonctions (sauf sante et suivre_colis, qui ne font que
# lire). Aucune réponse n'est affichée : seulement son code. Le journal d'un
# dépôt public ne contient donc aucune donnée.
#
# Lit aussi les réglages publics de l'authentification (auth/v1/settings) :
# confirmation des adresses e-mail, inscriptions ouvertes, fournisseurs.
#
# Ce que la sonde NE voit PAS (il faut controle-securite.sql, avec l'accès à la
# base) : les tables, la RLS, les verrous, les comptes, le Vault, pg_cron.
# =============================================================================
set -uo pipefail

RACINE="$(cd "$(dirname "$0")/../.." && pwd)"
URL="${SUPABASE_URL:-$(grep -Eo "supabaseUrl: *'[^']+'" "$RACINE/assets/js/config.js" | cut -d"'" -f2)}"
CLE="${SUPABASE_CLE:-$(grep -Eo "supabaseKey: *'[^']+'" "$RACINE/assets/js/config.js" | cut -d"'" -f2)}"
[ -n "$URL" ] && [ -n "$CLE" ] || { echo "Adresse ou clé publique introuvable."; exit 2; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# fichier | fonction témoin | paramètres (noms exacts : PostgREST choisit la fonction par eux)
# | ouverte aux visiteurs ? (oui = 200 attendu)
TEMOINS='supabase.sql|mes_permissions||non
supabase.sql|suivre_colis|p_numero=GSE-0000-ZZ|oui
supabase-facturation.sql|mes_factures||non
supabase-services.sql|tarifs||non
supabase-services.sql|equipe||non
supabase-evenements.sql|types_evenement||non
supabase-evenements.sql|statuts_possibles|p_colis=00000000-0000-0000-0000-000000000000|non
supabase-scanner.sql|operations_du_scanner||non
supabase-finances.sql|moyens_paiement||non
supabase-finances.sql|resume_facturation||non
supabase-tableau-de-bord.sql|mon_resume||non
supabase-tableau-de-bord.sql|vue_generale||non
supabase-analytics.sql|analytics_synthese||non
supabase-analytics.sql|analytics_qualite||non
supabase-mobile.sql|creer_prealerte|p_cle=00000000-0000-0000-0000-000000000000&p_magasin=sonde&p_description=sonde|non
supabase-notifications.sql|regles_notifications||non
supabase-notifications.sql|notifications_non_lues||non
supabase-notifications.sql|mes_notifications||non
supabase-production.sql|sante||oui
supabase-rapports.sql|liste_rapports||non'

echo "== Base : ${URL%%.*}… (clé publique seulement, appels GET en lecture seule)"
printf '%-30s %-26s %-6s %s\n' "MIGRATION" "FONCTION TÉMOIN" "CODE" "ÉTAT"
presentes=0; absentes=0; ouvertes=0; inattendus=0
declare -A fichier_ok fichier_ko
while IFS='|' read -r fichier fonction params ouverte; do
  lien="$URL/rest/v1/rpc/$fonction"; [ -n "$params" ] && lien="$lien?$params"
  code="$(curl -sS -o "$tmp/r" -w '%{http_code}' --max-time 20 -H "apikey: $CLE" "$lien" 2>/dev/null || echo 000)"
  pg="$(python3 -c "import json,sys
try: d=json.load(open(sys.argv[1])); print(d.get('code','') if isinstance(d,dict) else '')
except Exception: print('')" "$tmp/r")"
  if [ "$code" = 404 ] && [ "$pg" = PGRST202 ]; then
    etat="ABSENTE"; absentes=$((absentes + 1)); fichier_ko[$fichier]=1
  elif [ "$code" = 401 ] || [ "$code" = 403 ] || [ "$pg" = 42501 ]; then
    if [ "$ouverte" = oui ]; then etat="présente, FERMÉE aux visiteurs (inattendu)"; inattendus=$((inattendus + 1))
    else etat="présente"; fi
    presentes=$((presentes + 1)); fichier_ok[$fichier]=1
  elif [ "$code" = 200 ]; then
    if [ "$ouverte" = oui ]; then etat="présente, ouverte aux visiteurs (voulu)"
    else etat="présente, OUVERTE AUX VISITEURS"; ouvertes=$((ouvertes + 1)); fi
    presentes=$((presentes + 1)); fichier_ok[$fichier]=1
  else
    etat="réponse inattendue ($pg)"; inattendus=$((inattendus + 1))
  fi
  printf '%-30s %-26s %-6s %s\n' "$fichier" "$fonction" "$code" "$etat"
done <<< "$TEMOINS"

echo
echo "== Chaîne des migrations (outils/migrations.txt)"
passe=0; manque=0
while read -r f; do
  case "$f" in ''|\#*) continue ;; esac
  if [ -n "${fichier_ko[$f]:-}" ] && [ -z "${fichier_ok[$f]:-}" ]; then echo "  ABSENTE   $f"; manque=$((manque + 1))
  elif [ -n "${fichier_ko[$f]:-}" ]; then echo "  PARTIELLE $f (une fonction témoin manque)"; manque=$((manque + 1))
  elif [ -n "${fichier_ok[$f]:-}" ]; then echo "  présente  $f"; passe=$((passe + 1))
  else echo "  ?         $f (aucune réponse exploitable)"; manque=$((manque + 1)); fi
done < "$RACINE/outils/migrations.txt"

echo
echo "== Authentification (réglages publics)"
code="$(curl -sS -o "$tmp/auth" -w '%{http_code}' --max-time 20 -H "apikey: $CLE" "$URL/auth/v1/settings" 2>/dev/null || echo 000)"
if [ "$code" = 200 ]; then
  python3 - "$tmp/auth" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ext = d.get('external') or {}
actifs = sorted(k for k, v in ext.items() if v is True)
auto = d.get('mailer_autoconfirm')
print('  confirmation des adresses e-mail : %s' % ('ACTIVE' if auto is False else ('DÉSACTIVÉE — un compte est utilisable sans prouver son adresse' if auto is True else 'inconnue')))
print('  inscriptions : %s' % ('fermées' if d.get('disable_signup') else 'ouvertes'))
print('  fournisseurs de connexion actifs : %s' % (', '.join(actifs) or 'aucun'))
print('  confirmation par téléphone automatique : %s' % d.get('phone_autoconfirm'))
PY
else
  echo "  auth/v1/settings : code $code"
fi

echo
echo "== Résumé : $passe migration(s) présente(s), $manque absente(s) ou partielle(s) ; $ouvertes fonction(s) ouverte(s) aux visiteurs sans raison ; $inattendus réponse(s) inattendue(s)"
# Code de sortie : 0 = chaîne complète et aucune exposition ; 1 = écart (le journal dit
# lequel). SONDE_RAPPORT_SEUL=1 (pull request : la PR n'est pas responsable de l'état
# de la production) : le rapport, toujours code 0.
[ "${SONDE_RAPPORT_SEUL:-}" = 1 ] && exit 0
[ "$manque" = 0 ] && [ "$ouvertes" = 0 ] && [ "$inattendus" = 0 ]
