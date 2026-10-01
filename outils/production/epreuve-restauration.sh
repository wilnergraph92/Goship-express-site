#!/bin/bash
# =============================================================================
# Goship Express — l'épreuve complète d'une sauvegarde : la restaurer et le prouver
#
#   RESTORE_TARGET=essai|staging CIBLE_DB_URL=… \
#     bash outils/production/epreuve-restauration.sh <dossier> <nom> <clé privée age> [téléchargement_s]
#
# Dans l'ordre, le premier échec arrête tout (code 1) :
#   0. (essai seulement, PREPARER_CIBLE=1) habiller la base jetable en projet Supabase
#      neuf : rôles de Supabase (administration, puis anon, authenticated,
#      service_role, authenticator : un PostgreSQL neuf, comme le conteneur du
#      workflow, n'en a aucun), puis doublures (auth, vault, net, storage,
#      publication supabase_realtime). Refusé sur une adresse Supabase : un vrai
#      projet a déjà tout cela, et on n'y crée jamais de rôle ;
#   1. verifier-sauvegarde.sh avec la clé : SHA-256, déchiffrement, manifeste, structure ;
#   2. restaurer.sh (RESTORE_TARGET) : comptes puis schéma public, lignes = manifeste ;
#   3. appliquer-chaine.sh : la chaîne de migrations rejouée (elle refuse la production) ;
#   4. verifier-restauration.sh avec le manifeste : tables, fonctions, contraintes,
#      verrous, données, comptes.
# Puis le rapport, avec les durées réelles de chaque étape (RTO de la base) et l'âge de
# la sauvegarde (RPO) ; recopié dans le résumé du job GitHub s'il existe.
# La clé n'est jamais affichée ; le manifeste en clair vit dans un dossier temporaire
# (700) effacé en sortant.
# =============================================================================
set -euo pipefail
ICI="$(cd "$(dirname "$0")" && pwd)"
dossier="${1:?Usage : epreuve-restauration.sh <dossier> <nom> <clé> [téléchargement_s]}"
nom="${2:?nom manquant}"
cle="${3:?clé manquante}"
telechargement="${4:-0}"
: "${CIBLE_DB_URL:?CIBLE_DB_URL manquante}"
case "${RESTORE_TARGET:-}" in essai|staging) ;; *) echo "RESTORE_TARGET : essai ou staging (jamais production ici)" >&2; exit 1 ;; esac

travail="$(mktemp -d)"
chmod 700 "$travail"
trap 'rm -rf "$travail"' EXIT
rapport="$travail/rapport.txt"

if [ "$RESTORE_TARGET" = essai ] && [ "${PREPARER_CIBLE:-}" = 1 ]; then
  case "$CIBLE_DB_URL" in
    *supabase.co*)   # couvre aussi supabase.com
      echo "PREPARER_CIBLE refusé : la cible est un projet Supabase (rôles et schémas déjà là, jamais recréés)" >&2
      exit 1 ;;
  esac
  # Les rôles vivent dans le serveur, pas dans la base : on ne crée que ceux qui manquent,
  # avec les attributs de Supabase (anon et authenticated sans connexion, service_role
  # qui passe la RLS, authenticator qui les endosse)
  "${PSQL:-psql}" "$CIBLE_DB_URL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
do $$ declare r text; begin
  foreach r in array array['supabase_admin', 'supabase_auth_admin', 'supabase_storage_admin',
                           'dashboard_user', 'pgbouncer', 'supabase_realtime_admin',
                           'supabase_replication_admin', 'supabase_read_only_user'] loop
    if not exists (select 1 from pg_roles where rolname = r) then
      execute format('create role %I nologin', r);
    end if;
  end loop;
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator nologin noinherit;   -- personne ne s'y connecte ici
  end if;
end $$;
grant anon, authenticated, service_role to authenticator;
SQL
  python3 "$ICI/doublures-supabase.py" | "${PSQL:-psql}" "$CIBLE_DB_URL" -X -q -v ON_ERROR_STOP=1
fi

t0=$(date +%s)
bash "$ICI/verifier-sauvegarde.sh" "$dossier" "$nom" "$cle" | tee "$rapport"
t1=$(date +%s)
essai=""; [ "$RESTORE_TARGET" = essai ] && essai=1
RESTAURATION_ESSAI="$essai" bash "$ICI/restaurer.sh" "$dossier" "$nom" "$cle"
t2=$(date +%s)
SANS_PG_NET="$essai" bash "$ICI/appliquer-chaine.sh"
t3=$(date +%s)
age -d -i "$cle" -o "$travail/manifeste.json" "$dossier/$nom.manifeste.json.age"
bash "$ICI/verifier-restauration.sh" "$travail/manifeste.json" | tee -a "$rapport"
t4=$(date +%s)

prise="$(python3 -c "
import datetime, re, sys
m = re.match(r'goship-(\d{4}-\d\d-\d\d)T(\d\d)(\d\d)(\d\d)?Z$', sys.argv[1])
d = datetime.datetime.strptime(m.group(1) + m.group(2) + m.group(3) + (m.group(4) or '00'), '%Y-%m-%d%H%M%S')
print(int(d.replace(tzinfo=datetime.timezone.utc).timestamp()))" "$nom")"
{
  echo "RESTORE:           OK   RESTORE_TARGET=$RESTORE_TARGET, lignes identiques au manifeste, chaîne rejouée"
  echo "RESTORE DURATION:  $(( telechargement + t4 - t0 )) s (téléchargement $telechargement s + vérification/déchiffrement $(( t1 - t0 )) s + restauration $(( t2 - t1 )) s + chaîne $(( t3 - t2 )) s + validation $(( t4 - t3 )) s)"
  echo "BACKUP AGE (RPO):  $(( (t4 - prise) / 60 )) min au moment de la vérification"
  echo "FINAL RESULT:      PASS"
} | tee -a "$rapport"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "### Restauration d'épreuve de \`$nom\` : réussie"; echo '```'; cat "$rapport"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
fi
