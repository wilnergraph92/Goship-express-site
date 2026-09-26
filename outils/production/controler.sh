#!/bin/bash
# =============================================================================
# Goship Express — contrôles de sécurité et d'intégrité d'une base, en lecture seule
#
#   CIBLE_DB_URL=… [SAUVEGARDE_DESTINATAIRE=age1…] bash outils/production/controler.sh <dossier>
#
# Exécute outils/production/controle-securite.sql et controle-integrite.sql dans
# des transactions EN LECTURE SEULE (default_transaction_read_only) : la base ne
# peut rien écrire, même par erreur.
#
# Ce qui est affiché (et peut donc finir dans le journal public de GitHub) :
# chaque contrôle, son verdict, l'objet concerné (adresses e-mail masquées) et un
# nombre — jamais les exemples de l'intégrité (numéros de colis, de factures).
# Le résultat complet, lui, est écrit dans <dossier> CHIFFRÉ pour
# SAUVEGARDE_DESTINATAIRE (la même clé publique age que les sauvegardes) ; sans
# destinataire, rien n'est écrit, sauf CONTROLE_EN_CLAIR=1 (sur un ordinateur de
# confiance seulement).
#
# Code de sortie : 0 = aucune ALERTE ; 1 = au moins une ALERTE ; 2 = contrôle impossible.
# =============================================================================
set -uo pipefail

sortie="${1:?Usage : controler.sh <dossier de sortie>}"
: "${CIBLE_DB_URL:?CIBLE_DB_URL manquante (chaîne de connexion de la base à contrôler)}"
PSQL="${PSQL:-psql}"
ICI="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$sortie"
travail="$(mktemp -d)"; chmod 700 "$travail"; trap 'rm -rf "$travail"' EXIT

export PGOPTIONS="-c default_transaction_read_only=on -c statement_timeout=120000"
for c in securite integrite; do
  if ! "$PSQL" "$CIBLE_DB_URL" -X -q -A -t -F $'\t' -v ON_ERROR_STOP=1 \
         -f "$ICI/controle-$c.sql" > "$travail/$c.tsv" 2> "$travail/$c.err"; then
    echo "Contrôle $c impossible :"; sed -E 's#postgres(ql)?://[^ ]*#<adresse masquée>#g' "$travail/$c.err" | head -5
    exit 2
  fi
done

python3 - "$travail" <<'PY'
import re, sys, os
d = sys.argv[1]
masque = lambda t: re.sub(r'[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+)', r'•••@\1', t)
alertes = 0
for nom, titre in (('securite', 'SÉCURITÉ'), ('integrite', 'INTÉGRITÉ')):
    lignes = [l.split('\t') for l in open(os.path.join(d, nom + '.tsv'), encoding='utf-8').read().splitlines() if l.strip()]
    compte = {}
    print('== %s (%d contrôles)' % (titre, len(lignes)))
    for l in lignes:
        l += [''] * (4 - len(l))
        controle, verdict = l[0], l[1]
        compte[verdict] = compte.get(verdict, 0) + 1
        if nom == 'securite':
            objet, detail = masque(l[2])[:60], masque(l[3])[:90]
            print('%-7s %-32s %-45s %s' % (verdict, controle[:32], objet, detail))
        else:                                   # nombre seulement, jamais les exemples
            print('%-7s %-55s %s' % (verdict, controle[:55], l[2]))
    alertes += compte.get('ALERTE', 0)
    print('   → %s' % ', '.join('%s : %d' % (k, v) for k, v in sorted(compte.items())))
    print()
print('== %d ALERTE(S) au total' % alertes)
open(os.path.join(d, 'alertes'), 'w').write(str(alertes))
PY

nom="controle-$(date -u +%Y-%m-%dT%H%MZ)"
if [ -n "${SAUVEGARDE_DESTINATAIRE:-}" ]; then
  destinataires=()
  for r in $(echo "$SAUVEGARDE_DESTINATAIRE" | tr ',' ' '); do destinataires+=(-r "$r"); done
  tar -C "$travail" -cf - securite.tsv integrite.tsv | age "${destinataires[@]}" -o "$sortie/$nom.tar.age"
  echo "Résultat complet chiffré : $sortie/$nom.tar.age"
elif [ "${CONTROLE_EN_CLAIR:-}" = 1 ]; then
  cp "$travail/securite.tsv" "$sortie/$nom.securite.tsv"; cp "$travail/integrite.tsv" "$sortie/$nom.integrite.tsv"
  echo "Résultat complet en clair : $sortie/$nom.*.tsv"
fi

[ "$(cat "$travail/alertes")" = 0 ]
