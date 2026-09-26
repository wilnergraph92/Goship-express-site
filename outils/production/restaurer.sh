#!/bin/bash
# =============================================================================
# Goship Express — restauration d'une sauvegarde chiffrée (Phase 12)
#
#   CIBLE_DB_URL=… bash outils/production/restaurer.sh <dossier> <nom> <clé privée age>
#     <dossier>  où se trouvent les fichiers de la sauvegarde
#     <nom>      goship-AAAA-MM-JJTHHMMZ (voir le manifeste)
#     <clé>      fichier de la clé PRIVÉE age (jamais dans le dépôt)
#
# JAMAIS sur la production en service : la cible est un projet Supabase NEUF (ou
# une base d'essai), dont le schéma public est vide. Le script refuse une cible
# qui contient déjà des colis. Procédure complète, et ce qui vient après (chaîne
# de migrations, Vault, Auth, contrôles) : docs/production/backup.md et
# docs/production/disaster-recovery.md.
#
# Ordre :
#   1. comptes (auth.users, auth.identities) — avant que nos déclencheurs existent
#      dans la cible, pour qu'aucun profil ne soit recréé en double ;
#   2. schéma public complet : tables, données, puis index, règles et déclencheurs
#      (pg_restore les recrée après les données : rien ne se déclenche) ;
#   3. comparaison avec le manifeste : même nombre de lignes, table par table.
# =============================================================================
set -euo pipefail

dossier="${1:?Usage : restaurer.sh <dossier> <nom> <clé privée age>}"
nom="${2:?nom de la sauvegarde manquant}"
cle="${3:?fichier de la clé privée manquant}"
: "${CIBLE_DB_URL:?CIBLE_DB_URL manquante (base de destination)}"
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

manifeste="$dossier/$nom.manifeste.json"
[ -f "$manifeste" ] || { echo "Manifeste introuvable : $manifeste" >&2; exit 1; }

# Refuser une base qui a déjà des colis : ce n'est pas une cible de restauration
deja=0
if [ "$("$PSQL" "$CIBLE_DB_URL" -X -A -t -c "select to_regclass('public.colis') is not null;")" = "t" ]; then
  deja="$("$PSQL" "$CIBLE_DB_URL" -X -A -t -c "select count(*) from public.colis;")"
fi
if [ "$deja" != "0" ]; then
  echo "La base cible contient déjà $deja colis : restauration refusée (cible neuve seulement)." >&2
  exit 1
fi

travail="$(mktemp -d)"
chmod 700 "$travail"
trap 'rm -rf "$travail"' EXIT

for partie in comptes public; do
  age -d -i "$cle" -o "$travail/$partie.dump" "$dossier/$nom.$partie.dump.age"
  attendu="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['fichiers'][sys.argv[2]]['sha256_clair'])" "$manifeste" "$partie")"
  obtenu="$(sha256sum "$travail/$partie.dump" | cut -d' ' -f1)"
  [ "$attendu" = "$obtenu" ] || { echo "Empreinte différente pour $partie : fichier altéré ?" >&2; exit 1; }
done
echo "Déchiffrement et empreintes : conformes au manifeste."

# 1. Les comptes (données seulement)
"$PG_RESTORE" --no-owner --no-privileges --data-only --single-transaction \
  --dbname "$CIBLE_DB_URL" "$travail/comptes.dump"

# 2. Le schéma public. Dans un projet Supabase neuf, « schema public already exists »
# est la seule erreur attendue : on la tolère, et aucune autre.
set +e
"$PG_RESTORE" --no-owner --dbname "$CIBLE_DB_URL" "$travail/public.dump" 2> "$travail/erreurs.txt"
set -e
autres="$(grep -E '^pg_restore: error:' "$travail/erreurs.txt" | grep -v 'schema "public" already exists' || true)"
if [ -n "$autres" ]; then
  echo "Erreurs de restauration :" >&2
  echo "$autres" | head -20 >&2
  exit 1
fi

# 3. Comparer avec le manifeste
compter_lignes "$CIBLE_DB_URL" > "$travail/lignes.json"
python3 - "$manifeste" "$travail/lignes.json" <<'PY'
import json, sys
attendu = json.load(open(sys.argv[1]))['lignes_par_table']
obtenu = json.load(open(sys.argv[2]))
ecarts = {t: (attendu.get(t), obtenu.get(t)) for t in set(attendu) | set(obtenu) if attendu.get(t) != obtenu.get(t)}
if ecarts:
    print('Nombre de lignes différent du manifeste :', ecarts)
    sys.exit(1)
print('Lignes restaurées : %d tables, %d lignes, identiques au manifeste.' % (len(obtenu), sum(obtenu.values())))
PY
echo "Étape suivante : relancer la chaîne de migrations (outils/migrations.txt), reposer les réglages Vault,"
echo "puis outils/production/controle-integrite.sql et controle-securite.sql (docs/production/backup.md)."
