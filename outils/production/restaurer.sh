#!/bin/bash
# =============================================================================
# Goship Express — restauration d'une sauvegarde chiffrée (Phase 12)
#
#   RESTORE_TARGET=essai|staging CIBLE_DB_URL=… \
#     bash outils/production/restaurer.sh <dossier> <nom> <clé privée age>
#     <dossier>  où se trouvent les fichiers de la sauvegarde
#     <nom>      goship-AAAA-MM-JJTHHMMSSZ (voir le manifeste)
#     <clé>      fichier de la clé PRIVÉE age (jamais dans le dépôt)
#
# RESTORE_TARGET est obligatoire et dit où l'on restaure :
#   essai       une base jetable (workflows, essais)
#   staging     la préproduction (un projet Supabase vidé ou neuf)
#   production  seulement après un sinistre, dans le NOUVEAU projet de production, et
#               avec RESTORE_CONFIRM=RESTAURER-EN-PRODUCTION en plus
# Si SUPABASE_DB_URL est aussi posée (la base en service) et que CIBLE_DB_URL pointe
# le même serveur et la même base, la restauration est refusée hors « production ».
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
case "${RESTORE_TARGET:-}" in
  essai|staging) ;;
  production)
    if [ "${RESTORE_CONFIRM:-}" != "RESTAURER-EN-PRODUCTION" ]; then
      echo "Restauration en production refusée : poser aussi RESTORE_CONFIRM=RESTAURER-EN-PRODUCTION" >&2
      echo "(uniquement dans le nouveau projet après un sinistre : docs/production/disaster-recovery.md)." >&2
      exit 1
    fi ;;
  *) echo "RESTORE_TARGET manquante ou inconnue : essai, staging ou production" >&2; exit 1 ;;
esac
# La base en service, reconnue par son serveur et son nom de base (sans rien afficher)
meme_base() {
  python3 - "$1" "$2" <<'PY2'
import sys
from urllib.parse import urlsplit
def cle(u):
    s = urlsplit(u)
    return ((s.hostname or '').lower(), s.port or 5432, (s.path or '/').lstrip('/') or 'postgres')
sys.exit(0 if cle(sys.argv[1]) == cle(sys.argv[2]) else 1)
PY2
}
if [ "$RESTORE_TARGET" != "production" ] && [ -n "${SUPABASE_DB_URL:-}" ] && meme_base "$CIBLE_DB_URL" "$SUPABASE_DB_URL"; then
  echo "La cible est la base de production : refusé (RESTORE_TARGET=$RESTORE_TARGET)." >&2
  exit 1
fi
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

[ -f "$dossier/$nom.manifeste.json.age" ] || { echo "Manifeste introuvable : $dossier/$nom.manifeste.json.age" >&2; exit 1; }
# Les fichiers chiffrés d'abord : une empreinte absente ou fausse arrête tout, avant
# même de déchiffrer
for partie in manifeste.json comptes.dump public.dump; do
  [ -f "$dossier/$nom.$partie.age.sha256" ] || { echo "Empreinte absente : $nom.$partie.age.sha256" >&2; exit 1; }
  ( cd "$dossier" && sha256sum -c --quiet "$nom.$partie.age.sha256" ) \
    || { echo "SHA-256 différent pour $nom.$partie.age : fichier altéré, restauration refusée" >&2; exit 1; }
done
echo "SHA-256 des fichiers chiffrés : conformes."

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

# Le manifeste est chiffré comme le reste : une mauvaise clé s'arrête ici
manifeste="$travail/manifeste.json"
age -d -i "$cle" -o "$manifeste" "$dossier/$nom.manifeste.json.age"

for partie in comptes public; do
  age -d -i "$cle" -o "$travail/$partie.dump" "$dossier/$nom.$partie.dump.age"
  attendu="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['fichiers'][sys.argv[2]]['sha256_clair'])" "$manifeste" "$partie")"
  obtenu="$(sha256sum "$travail/$partie.dump" | cut -d' ' -f1)"
  [ "$attendu" = "$obtenu" ] || { echo "Empreinte différente pour $partie : fichier altéré ?" >&2; exit 1; }
done
echo "Déchiffrement et empreintes : conformes au manifeste."

# 1. Les comptes (données seulement). En restauration d'épreuve sur un PostgreSQL
# ordinaire (RESTAURATION_ESSAI=1 : sauvegarde.yml), les deux tables sont d'abord
# recréées telles qu'elles sont en production (définition sans index ni
# déclencheurs), à la place des doublures d'essai. Jamais dans un vrai projet.
if [ "${RESTAURATION_ESSAI:-}" = 1 ]; then
  "$PSQL" "$CIBLE_DB_URL" -X -q -v ON_ERROR_STOP=1 -c 'drop table if exists auth.identities, auth.users cascade;'
  "$PG_RESTORE" --no-owner --no-privileges --section=pre-data --single-transaction \
    --dbname "$CIBLE_DB_URL" "$travail/comptes.dump"
fi
"$PG_RESTORE" --no-owner --no-privileges --data-only --single-transaction \
  --dbname "$CIBLE_DB_URL" "$travail/comptes.dump"
if [ "${RESTAURATION_ESSAI:-}" = 1 ]; then
  # Clés primaires et index des comptes (le schéma public y rattache ses clés
  # étrangères) ; sans leurs déclencheurs, que la chaîne de migrations recrée
  "$PG_RESTORE" --section=post-data -l "$travail/comptes.dump" | grep -v ' TRIGGER ' > "$travail/comptes.liste"
  "$PG_RESTORE" --no-owner --no-privileges --single-transaction -L "$travail/comptes.liste" \
    --dbname "$CIBLE_DB_URL" "$travail/comptes.dump"
fi

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
