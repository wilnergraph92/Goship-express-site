#!/bin/bash
# =============================================================================
# Goship Express — sauvegarde logique chiffrée de la base (Phase 12)
#
#   SUPABASE_DB_URL=… SAUVEGARDE_DESTINATAIRE=age1… bash outils/production/sauvegarder.sh <dossier>
#
# Produit dans <dossier> :
#   goship-AAAA-MM-JJTHHMMZ.public.dump.age   schéma public complet (tables, fonctions,
#                                             règles, données), chiffré
#   goship-AAAA-MM-JJTHHMMZ.comptes.dump.age  données des comptes (auth.users,
#                                             auth.identities), chiffrées
#   goship-AAAA-MM-JJTHHMMZ.manifeste.json.age  date, versions, empreintes, nombre de
#                                             lignes par table, chiffré lui aussi : le
#                                             dépôt est public, et le nombre de clients,
#                                             de colis ou de factures ne regarde personne
#
# Le fichier en clair ne touche jamais le disque plus longtemps que le chiffrement :
# il est effacé aussitôt. Seule la clé PRIVÉE correspondant à SAUVEGARDE_DESTINATAIRE
# (gardée hors de GitHub, voir docs/production/backup.md) peut relire la sauvegarde.
#
# Ne sauvegarde PAS : les fichiers de Supabase Storage (seul le logo des e-mails y est,
# redéposable), le coffre-fort Vault (réglages et clés des fournisseurs : à reposer
# avec definir_reglage), la configuration de Supabase (Auth, URL, extensions) :
# voir docs/production/backup.md.
# =============================================================================
set -euo pipefail

sortie="${1:?Usage : sauvegarder.sh <dossier de sortie>}"
: "${SUPABASE_DB_URL:?SUPABASE_DB_URL manquante (chaîne de connexion de la base, jamais dans le dépôt)}"
: "${SAUVEGARDE_DESTINATAIRE:?SAUVEGARDE_DESTINATAIRE manquante (clé publique age1…)}"
case "$SAUVEGARDE_DESTINATAIRE" in age1*) ;; *) echo "SAUVEGARDE_DESTINATAIRE doit être une clé publique age (age1…)"; exit 1 ;; esac
PG_DUMP="${PG_DUMP:-pg_dump}"
PG_RESTORE="${PG_RESTORE:-pg_restore}"
PSQL="${PSQL:-psql}"

# Le nombre exact de lignes de chaque table du schéma public, en JSON {table: n}
compter_lignes() {
  local requete
  requete="$("$PSQL" "$1" -X -A -t -v ON_ERROR_STOP=1 -c "
    select 'select coalesce(json_object_agg(t, n order by t), ''{}'') from ('
           || coalesce(string_agg(format('select %L as t, count(*) as n from public.%I', c.relname, c.relname), ' union all '),
                       'select null::text as t, null::bigint as n where false')
           || ') x;'
      from pg_class c join pg_namespace s on s.oid = c.relnamespace
     where s.nspname = 'public' and c.relkind = 'r';")"
  "$PSQL" "$1" -X -A -t -v ON_ERROR_STOP=1 -c "$requete"
}

mkdir -p "$sortie"
horodatage="$(date -u +%Y-%m-%dT%H%MZ)"
nom="goship-$horodatage"
travail="$(mktemp -d)"
chmod 700 "$travail"
trap 'rm -rf "$travail"' EXIT

# 1. Le schéma public, complet. Les déclencheurs et règles de sécurité sont recréés
# après les données au moment de la restauration : aucune règle ne se déclenche en
# rechargeant l'historique.
"$PG_DUMP" --format=custom --no-owner --schema=public \
  --file "$travail/public.dump" "$SUPABASE_DB_URL"

# 2. Les comptes : données seulement. Le schéma auth appartient à Supabase, qui le
# recrée dans tout projet neuf.
"$PG_DUMP" --format=custom --no-owner --no-privileges --data-only \
  --table=auth.users --table=auth.identities \
  --file "$travail/comptes.dump" "$SUPABASE_DB_URL"

# 3. Vérifier que les archives se relisent, et qu'elles contiennent bien les données
for partie in public comptes; do
  "$PG_RESTORE" --list "$travail/$partie.dump" > "$travail/$partie.liste"
done
for table in clients colis colis_historique factures paiements; do
  if ! grep -q "TABLE DATA public $table " "$travail/public.liste"; then
    echo "Sauvegarde incomplète : pas de données pour public.$table" >&2
    exit 1
  fi
done

# 4. Le manifeste : ce qu'il faudra retrouver après une restauration
lignes="$(compter_lignes "$SUPABASE_DB_URL")"
version_serveur="$("$PSQL" "$SUPABASE_DB_URL" -X -A -t -c 'show server_version;')"
empreinte() { sha256sum "$1" | cut -d' ' -f1; }

# 5. Chiffrer, puis effacer le clair
for partie in public comptes; do
  age -r "$SAUVEGARDE_DESTINATAIRE" -o "$sortie/$nom.$partie.dump.age" "$travail/$partie.dump"
done
python3 - "$travail/manifeste.json" <<PY
import json, sys
json.dump({
  "sauvegarde": "$nom",
  "date_utc": "$horodatage",
  "version_serveur": "$version_serveur",
  "pg_dump": "$("$PG_DUMP" --version)",
  "fichiers": {
    "public": {"chiffre": "$nom.public.dump.age", "sha256_clair": "$(empreinte "$travail/public.dump")",
               "entrees": $(wc -l < "$travail/public.liste")},
    "comptes": {"chiffre": "$nom.comptes.dump.age", "sha256_clair": "$(empreinte "$travail/comptes.dump")",
                "entrees": $(wc -l < "$travail/comptes.liste")}
  },
  "lignes_par_table": json.loads('''$lignes''')
}, open(sys.argv[1], 'w'), ensure_ascii=False, indent=2)
PY
age -r "$SAUVEGARDE_DESTINATAIRE" -o "$sortie/$nom.manifeste.json.age" "$travail/manifeste.json"
echo "Sauvegarde $nom : $(du -h "$sortie/$nom.public.dump.age" | cut -f1) (public), $(du -h "$sortie/$nom.comptes.dump.age" | cut -f1) (comptes), chiffrée pour ${SAUVEGARDE_DESTINATAIRE:0:12}…"
