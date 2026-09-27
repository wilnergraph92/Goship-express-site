#!/bin/bash
# =============================================================================
# Goship Express — sauvegarde logique chiffrée de la base (Phase 12)
#
#   SUPABASE_DB_URL=… SAUVEGARDE_DESTINATAIRE=age1… bash outils/production/sauvegarder.sh <dossier>
#
# Produit dans <dossier> (six fichiers, tous chiffrés ou empreintes de fichiers chiffrés) :
#   goship-AAAA-MM-JJTHHMMSSZ.public.dump.age   schéma public complet (tables, fonctions,
#                                             règles, données), chiffré
#   goship-AAAA-MM-JJTHHMMSSZ.comptes.dump.age  données des comptes (auth.users,
#                                             auth.identities), chiffrées
#   goship-AAAA-MM-JJTHHMMSSZ.manifeste.json.age  date, versions, empreintes, nombre de
#                                             lignes par table, chiffré lui aussi : le
#                                             dépôt est public, et le nombre de clients,
#                                             de colis ou de factures ne regarde personne
#   et, pour chacun, <fichier>.age.sha256 : l'empreinte SHA-256 du fichier CHIFFRÉ, au
#   format de sha256sum, vérifiée après tout transfert et avant toute restauration.
#
# Format : pg_dump --format=custom (compressé, relu par pg_restore --list, restaurable
# partie par partie : les comptes avant le schéma public). Pas « supabase db dump » :
# il produit du SQL en clair et exclut justement les schémas gérés par Supabase (auth).
#
# Ce script ne parle qu'à la base (SUPABASE_DB_URL) : aucune adresse du site, aucun
# domaine. Changer le domaine du site ne le concerne pas. Il n'écrit rien dans la base.
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
# Un ou plusieurs destinataires (séparés par des virgules ou des espaces) : la clé
# hors ligne du propriétaire, et, pour la restauration d'épreuve quotidienne de
# sauvegarde.yml, RESTAURATION_DESTINATAIRE. Chacun peut relire la sauvegarde seul.
destinataires=()
for r in $(echo "$SAUVEGARDE_DESTINATAIRE ${RESTAURATION_DESTINATAIRE:-}" | tr ',' ' '); do
  case "$r" in age1*) destinataires+=(-r "$r") ;; *) echo "Destinataire invalide : une clé publique age commence par age1"; exit 1 ;; esac
done
ICI="$(cd "$(dirname "$0")" && pwd)"
PG_DUMP="${PG_DUMP:-pg_dump}"
PG_RESTORE="${PG_RESTORE:-pg_restore}"
PSQL="${PSQL:-psql}"
for outil in "$PG_DUMP" "$PG_RESTORE" "$PSQL" age sha256sum python3; do
  command -v "$outil" > /dev/null || { echo "Outil manquant : $outil" >&2; exit 1; }
done

# Un message d'erreur de PostgreSQL peut citer une chaîne de connexion : on la masque
# toujours avant de l'afficher (jamais de mot de passe dans un journal)
masquer() { sed -E 's#postgres(ql)?://[^[:space:]"]+#postgresql://***#g; s#password=[^[:space:]"]+#password=***#g'; }

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
horodatage="$(date -u +%Y-%m-%dT%H%M%SZ)"
nom="goship-$horodatage"
travail="$(mktemp -d)"
chmod 700 "$travail"
trap 'rm -rf "$travail"' EXIT
echo "Sauvegarde $nom : début"

# 0. L'adresse convient-elle (Session pooler, pas la connexion directe ni le port 6543) ?
# Rien n'est affiché de l'adresse, seulement le type reconnu ou la raison du refus.
bash "$ICI/verifier-adresse.sh" SUPABASE_DB_URL

# La base répond-elle ? (lecture seule : select 1)
if ! "$PSQL" "$SUPABASE_DB_URL" -X -A -t -v ON_ERROR_STOP=1 -c 'select 1;' > /dev/null 2> "$travail/connexion.txt"; then
  echo "Connexion à la base impossible. Sur Supabase Free, utiliser l'adresse « Session pooler »" >&2
  echo "(port 5432) : la connexion directe n'est joignable qu'en IPv6. Détail :" >&2
  head -3 "$travail/connexion.txt" | masquer >&2
  exit 1
fi
echo "Base jointe"

# 1. Le schéma public, complet. Les déclencheurs et règles de sécurité sont recréés
# après les données au moment de la restauration : aucune règle ne se déclenche en
# rechargeant l'historique.
"$PG_DUMP" --format=custom --no-owner --schema=public \
  --file "$travail/public.dump" "$SUPABASE_DB_URL"

# 2. Les comptes : données ET définition des deux tables. Une restauration dans un
# projet Supabase neuf n'en lit que les données (le schéma auth appartient à
# Supabase, qui le recrée) ; la définition sert à la restauration d'épreuve sur un
# PostgreSQL ordinaire (restaurer.sh, RESTAURATION_ESSAI=1), où les colonnes du
# vrai auth.users doivent exister.
"$PG_DUMP" --format=custom --no-owner --no-privileges \
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
for f in FUNCTION TRIGGER POLICY "FK CONSTRAINT"; do
  grep -q " $f public " "$travail/public.liste" || { echo "Sauvegarde incomplète : aucun élément $f dans public" >&2; exit 1; }
done
grep -q "TABLE DATA auth users " "$travail/comptes.liste" || { echo "Sauvegarde incomplète : pas de données pour auth.users" >&2; exit 1; }
taille_min=20000   # un schéma public GoShip vide pèse déjà bien plus : en dessous, le dump est suspect
[ "$(stat -c %s "$travail/public.dump")" -ge "$taille_min" ] || { echo "Sauvegarde suspecte : schéma public de moins de $taille_min octets" >&2; exit 1; }
# Les entrées de la liste de pg_restore s'écrivent « TYPE schéma nom » : on compte les
# FUNCTION du schéma public, pas les lignes de droits (« ACL public FUNCTION … »)
compter() { grep -c " $1 public " "$travail/public.liste" || true; }
echo "Copie relue : $(compter 'TABLE DATA') tables avec données, $(compter FUNCTION) fonctions, $(compter TRIGGER) déclencheurs, $(compter POLICY) règles RLS, $(compter 'SEQUENCE SET') séquences"

# 4. Le manifeste : ce qu'il faudra retrouver après une restauration
lignes="$(compter_lignes "$SUPABASE_DB_URL")"
comptes="$("$PSQL" "$SUPABASE_DB_URL" -X -A -t -v ON_ERROR_STOP=1 -c 'select count(*) from auth.users;')"
version_serveur="$("$PSQL" "$SUPABASE_DB_URL" -X -A -t -c 'show server_version;')"
lire() { "$PSQL" "$SUPABASE_DB_URL" -X -A -t -v ON_ERROR_STOP=1 -c "$1"; }
# La valeur de chaque séquence du schéma public (numéros de colis, de factures, codes
# clients) : une restauration qui les remettrait à zéro redonnerait des numéros déjà pris
sequences="$(lire "select coalesce(json_object_agg(sequencename, last_value order by sequencename), '{}') from pg_sequences where schemaname = 'public';")"
# Ce qu'il faut pour qu'un compte restauré puisse se reconnecter : ses identités et
# l'empreinte de son mot de passe. None (null dans le manifeste) quand la table ou la
# colonne n'existe pas dans la base sauvegardée.
identites=None
[ "$(lire "select to_regclass('auth.identities') is not null;")" = t ] && identites="$(lire 'select count(*) from auth.identities;')"
avec_mot_de_passe=None
[ "$(lire "select exists (select 1 from information_schema.columns where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password');")" = t ] \
  && avec_mot_de_passe="$(lire "select count(*) from auth.users where coalesce(encrypted_password, '') <> '';")"
confirmes="$(lire 'select count(*) from auth.users where email_confirmed_at is not null;')"
empreinte() { sha256sum "$1" | cut -d' ' -f1; }

# 5. Chiffrer, puis effacer le clair
for partie in public comptes; do
  age "${destinataires[@]}" -o "$sortie/$nom.$partie.dump.age" "$travail/$partie.dump"
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
  "lignes_par_table": json.loads('''$lignes'''),
  "comptes_auth": $comptes,
  "auth": {"identites": $identites, "avec_mot_de_passe": $avec_mot_de_passe, "confirmes": $confirmes},
  "sequences": json.loads('''$sequences''')
}, open(sys.argv[1], 'w'), ensure_ascii=False, indent=2)
PY
age "${destinataires[@]}" -o "$sortie/$nom.manifeste.json.age" "$travail/manifeste.json"

# 6. Chaque fichier chiffré : bien chiffré (en-tête age), non vide, et son empreinte
for partie in public.dump comptes.dump manifeste.json; do
  f="$sortie/$nom.$partie.age"
  [ -s "$f" ] || { echo "Fichier chiffré vide : $nom.$partie.age" >&2; exit 1; }
  [ "$(head -c 21 "$f")" = "age-encryption.org/v1" ] || { echo "Fichier non chiffré : $nom.$partie.age" >&2; exit 1; }
  ( cd "$sortie" && sha256sum "$nom.$partie.age" > "$nom.$partie.age.sha256" )
done
echo "Chiffrement et empreintes SHA-256 : faits"
echo "Sauvegarde $nom : $(du -h "$sortie/$nom.public.dump.age" | cut -f1) (public), $(du -h "$sortie/$nom.comptes.dump.age" | cut -f1) (comptes), chiffrée pour $(( ${#destinataires[@]} / 2 )) destinataire(s)"
