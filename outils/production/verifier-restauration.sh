#!/bin/bash
# =============================================================================
# Goship Express — vérifier une base RESTAURÉE (en lecture seule)
#
#   CIBLE_DB_URL=… bash outils/production/verifier-restauration.sh [manifeste.json]
#
# À lancer après restaurer.sh, sur la base où l'on vient de restaurer. Ne modifie
# rien (une transaction en lecture seule par requête). Vérifie :
#   - la connexion ;
#   - les tables du schéma public (nombre ; toutes sous RLS) et les tables GoShip
#     attendues, lues dans la base elle-même (pas de liste figée : les tables
#     principales des migrations doivent exister, les autres sont comptées) ;
#   - les fonctions (nombre, et celles dont dépendent le site et l'application) ;
#   - les contraintes : clés primaires, étrangères, uniques, CHECK, toutes validées ;
#   - les verrous métier (déclencheurs verrou_statut, evenement_immuable,
#     garde_facture, verrou_role) présents et actifs ;
#   - les données : chaque table interrogée ; avec le manifeste de la sauvegarde,
#     le nombre de lignes table par table est comparé ; les liens principaux
#     (colis → clients, événements → colis, lignes → factures, paiements → factures)
#     se suivent sans orphelin ;
#   - les séquences (numéros de colis, de factures, codes clients) : avec le manifeste,
#     la valeur de chacune est celle de la sauvegarde ;
#   - les comptes (auth.users) : autant de profils clients que de comptes liés ; avec le
#     manifeste, autant de comptes, d'identités (auth.identities), de comptes avec un
#     mot de passe et de comptes confirmés que dans la sauvegarde.
# Un manifeste plus ancien, sans séquences ni détail des comptes : « non comparé »,
# écrit tel quel, jamais OK.
# Dernière ligne : FINAL RESULT: PASS ou FAIL ; code de sortie 0 ou 1. Aucune donnée
# affichée : des nombres.
# =============================================================================
set -uo pipefail

: "${CIBLE_DB_URL:?CIBLE_DB_URL manquante (la base restaurée)}"
manifeste="${1:-}"
PSQL="${PSQL:-psql}"
echec=0
ok()   { printf '%-18s OK   %s\n' "$1:" "${2:-}"; }
rate() { printf '%-18s FAIL %s\n' "$1:" "${2:-}"; echec=1; }
# Chaque requête en lecture seule (PGOPTIONS) ; une requête en erreur rend « ERREUR »,
# jamais un vide qu'on pourrait prendre pour un bon résultat
export PGOPTIONS="${PGOPTIONS:-} -c default_transaction_read_only=on"
q() {
  local r
  r="$("$PSQL" "$CIBLE_DB_URL" -X -A -t -v ON_ERROR_STOP=1 -c "$1" 2> /dev/null)" || { echo "ERREUR"; return 0; }
  printf '%s\n' "$r" | tail -1
}

if [ "$(q 'select 1;')" = "1" ]; then ok "DATABASE CONNECTION" "$(q "select 'PostgreSQL ' || current_setting('server_version');")"; else
  rate "DATABASE CONNECTION" "la base ne répond pas"; echo "FINAL RESULT:      FAIL"; exit 1; fi

# Tables
n_tables="$(q "select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r';")"
sans_rls="$(q "select coalesce(string_agg(c.relname, ', ' order by c.relname), '') from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;")"
n_regles="$(q "select count(*) from pg_policies where schemaname = 'public';")"
PRINCIPALES="clients colis colis_historique factures facture_lignes paiements notifications prealertes appareils journal_audit"
absentes=""
for t in $PRINCIPALES; do [ "$(q "select to_regclass('public.$t') is not null;")" = "t" ] || absentes="$absentes $t"; done
if [ "${n_tables:-0}" -gt 0 ] && [ -z "$absentes" ]; then ok "TABLE COUNT" "$n_tables tables dans public, dont les 10 tables GoShip principales"; else
  rate "TABLE COUNT" "${n_tables:-0} tables ; absentes :${absentes:- —}"; fi
if [ -z "$sans_rls" ] && [ "${n_regles:-0}" -gt 0 ]; then ok "RLS" "activée sur les $n_tables tables, $n_regles règles"; else
  rate "RLS" "tables sans RLS : ${sans_rls:-—} ; règles : ${n_regles:-0}"; fi

# Fonctions
n_fonctions="$(q "select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind = 'f';")"
ESSENTIELLES="creer_colis executer_operation changer_statut_colis suivre_colis enregistrer_paiement creer_facture vue_generale mon_resume mes_permissions peut"
manquantes=""
for f in $ESSENTIELLES; do
  [ "$(q "select exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = '$f');")" = "t" ] || manquantes="$manquantes $f"
done
if [ "${n_fonctions:-0}" -gt 0 ] && [ -z "$manquantes" ]; then ok "FUNCTION COUNT" "$n_fonctions fonctions dans public, dont les 10 dont dépendent le site et l'application"; else
  rate "FUNCTION COUNT" "${n_fonctions:-0} fonctions ; manquantes :${manquantes:- —}"; fi

# Contraintes
contraintes="$(q "select count(*) filter (where contype = 'p') || ' clés primaires, ' || count(*) filter (where contype = 'f') || ' clés étrangères, ' || count(*) filter (where contype = 'u') || ' uniques, ' || count(*) filter (where contype = 'c') || ' CHECK' from pg_constraint k join pg_namespace n on n.oid = k.connamespace where n.nspname = 'public';")"
non_valides="$(q "select count(*) from pg_constraint k join pg_namespace n on n.oid = k.connamespace where n.nspname = 'public' and not k.convalidated;")"
n_fk="$(q "select count(*) from pg_constraint k join pg_namespace n on n.oid = k.connamespace where n.nspname = 'public' and contype = 'f';")"
if [ "${non_valides:-1}" = "0" ] && [ "${n_fk:-0}" -gt 0 ]; then ok "CONSTRAINT CHECK" "$contraintes, toutes validées"; else
  rate "CONSTRAINT CHECK" "${contraintes:-?} ; non validées : ${non_valides:-?}"; fi

# Verrous métier
verrous=""
for v in verrou_statut evenement_immuable garde_facture verrou_role; do
  [ "$(q "select exists (select 1 from pg_trigger g join pg_class c on c.oid = g.tgrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and g.tgname = '$v' and g.tgenabled <> 'D');")" = "t" ] || verrous="$verrous $v"
done
n_declencheurs="$(q "select count(*) from pg_trigger g join pg_class c on c.oid = g.tgrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and not g.tgisinternal;")"
[ -z "$verrous" ] && ok "BUSINESS LOCKS" "4 verrous actifs ; $n_declencheurs déclencheurs dans public" || rate "BUSINESS LOCKS" "absents ou désactivés :$verrous"

# Données : chaque table se lit ; avec le manifeste, mêmes lignes table par table
illisibles=""
for t in $(q "select string_agg(c.relname, ' ' order by c.relname) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r';"); do
  "$PSQL" "$CIBLE_DB_URL" -X -A -t -v ON_ERROR_STOP=1 -c "select * from public.\"$t\" limit 1;" > /dev/null 2>&1 || illisibles="$illisibles $t"
done
# Le nombre exact de lignes de chaque table, en JSON {table: n} (même méthode que
# sauvegarder.sh : une requête count(*) par table, construite puis exécutée)
requete_comptes="$(q "select 'select coalesce(json_object_agg(t, n order by t), ''{}'') from ('
         || coalesce(string_agg(format('select %L as t, count(*) as n from public.%I', c.relname, c.relname), ' union all '),
                     'select null::text as t, null::bigint as n where false') || ') x;'
    from pg_class c join pg_namespace s on s.oid = c.relnamespace where s.nspname = 'public' and c.relkind = 'r';")"
obtenu="$(q "$requete_comptes")"
total_lignes="$(python3 -c "import json,sys;print(sum(json.loads(sys.argv[1]).values()))" "$obtenu" 2> /dev/null || echo ERREUR)"
orphelins="$(q "select (select count(*) from public.colis c where c.client_id is not null and not exists (select 1 from public.clients k where k.id = c.client_id))
               + (select count(*) from public.colis_historique h where not exists (select 1 from public.colis c where c.id = h.colis_id))
               + (select count(*) from public.facture_lignes l where not exists (select 1 from public.factures f where f.id = l.facture_id))
               + (select count(*) from public.paiements p where not exists (select 1 from public.factures f where f.id = p.facture_id));")"
if [ -n "$manifeste" ]; then
  [ -f "$manifeste" ] || { rate "DATA CHECK" "manifeste introuvable"; manifeste=""; }
fi
if [ -n "$manifeste" ]; then
  ecarts="$(python3 -c "
import json, sys
a = json.load(open(sys.argv[1]))['lignes_par_table']; b = json.loads(sys.argv[2])
print(', '.join(sorted(t for t in set(a) | set(b) if a.get(t) != b.get(t))))" "$manifeste" "$obtenu" 2> /dev/null)" \
    || ecarts="comparaison impossible"
else
  ecarts=""
fi
case "${total_lignes:-}${orphelins:-}" in *ERREUR*|"") illisibles="$illisibles (requêtes de comptage en erreur)" ;; esac
if [ -z "$illisibles" ] && [ "${orphelins:-1}" = "0" ] && [ -z "$ecarts" ]; then
  ok "DATA CHECK" "${total_lignes:-0} lignes lues$( [ -n "$manifeste" ] && echo ', identiques au manifeste table par table'), aucun orphelin (colis, événements, lignes, paiements)"
else
  rate "DATA CHECK" "illisibles :${illisibles:- —} ; orphelins : ${orphelins:-?} ; écarts avec le manifeste : ${ecarts:-—}"
fi
for t in clients colis colis_historique factures paiements notifications; do
  printf '   %-18s %s lignes\n' "$t" "$(q "select count(*) from public.$t;")"
done

# Les séquences : la valeur de chacune, comme dans la sauvegarde
seq_attendues=""
[ -n "$manifeste" ] && seq_attendues="$(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(json.dumps(d['sequences']) if 'sequences' in d else '')" "$manifeste" 2> /dev/null)"
if [ -n "$seq_attendues" ]; then
  seq_obtenues="$(q "select coalesce(json_object_agg(sequencename, last_value order by sequencename), '{}') from pg_sequences where schemaname = 'public';")"
  seq_ecarts="$(python3 -c "
import json, sys
a = json.loads(sys.argv[1]); b = json.loads(sys.argv[2])
print(', '.join(sorted(s for s in set(a) | set(b) if a.get(s) != b.get(s))) or '-')" "$seq_attendues" "$seq_obtenues" 2> /dev/null || echo 'comparaison impossible')"
  if [ "$seq_ecarts" = "-" ]; then ok "SEQUENCES" "$(python3 -c "import json,sys;print(len(json.loads(sys.argv[1])))" "$seq_attendues") séquences, valeurs identiques à la sauvegarde"
  else rate "SEQUENCES" "valeurs différentes de la sauvegarde : $seq_ecarts"; fi
else
  echo "SEQUENCES:         —    non comparées (pas de manifeste, ou manifeste sans séquences)"
fi

# Les comptes : chaque profil client pointe un compte d'authentification
if [ "$(q "select to_regclass('auth.users') is not null;")" = "t" ]; then
  comptes="$(q "select count(*) from auth.users;")"
  sans_compte="$(q "select count(*) from public.clients c where not exists (select 1 from auth.users u where u.id = c.id);")"
  attendus=""
  [ -n "$manifeste" ] && attendus="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('comptes_auth', ''))" "$manifeste" 2> /dev/null)"
  if [ "${sans_compte:-1}" != "0" ]; then rate "AUTH ACCOUNTS" "${sans_compte} profils sans compte d'authentification"
  elif [ -n "$attendus" ] && [ "$attendus" != "$comptes" ]; then rate "AUTH ACCOUNTS" "$comptes comptes restaurés, $attendus dans la sauvegarde"
  else ok "AUTH ACCOUNTS" "$comptes comptes (auth.users)$( [ -n "$attendus" ] && echo ', comme dans la sauvegarde'), chaque profil a son compte"; fi
else
  rate "AUTH ACCOUNTS" "auth.users absente"
fi
# Ce qu'il faut à un compte restauré pour se reconnecter : identités, mot de passe,
# confirmation — mêmes nombres que dans la sauvegarde
auth_attendu=""
[ -n "$manifeste" ] && auth_attendu="$(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(json.dumps(d['auth']) if 'auth' in d else '')" "$manifeste" 2> /dev/null)"
if [ -n "$auth_attendu" ]; then
  if [ "$(q "select to_regclass('auth.identities') is not null;")" = "t" ]; then identites="$(q 'select count(*) from auth.identities;')"; else identites="null"; fi
  if [ "$(q "select exists (select 1 from information_schema.columns where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password');")" = "t" ]; then
    avec_mdp="$(q "select count(*) from auth.users where coalesce(encrypted_password, '') <> '';")"
  else avec_mdp="null"; fi
  confirmes="$(q 'select count(*) from auth.users where email_confirmed_at is not null;')"
  auth_ecarts="$(python3 -c "
import json, sys
a = json.loads(sys.argv[1]); b = {'identites': sys.argv[2], 'avec_mot_de_passe': sys.argv[3], 'confirmes': sys.argv[4]}
b = {k: (None if v == 'null' else int(v)) for k, v in b.items()}
e = ['%s %s au lieu de %s' % (k, b[k], a[k]) for k in ('identites', 'avec_mot_de_passe', 'confirmes') if k in a and a[k] is not None and a[k] != b[k]]
print('; '.join(e) or '-')" "$auth_attendu" "$identites" "$avec_mdp" "$confirmes" 2> /dev/null || echo 'comparaison impossible')"
  if [ "$auth_ecarts" = "-" ]; then
    ok "AUTH DETAILS" "identités : $identites, avec mot de passe : $avec_mdp, confirmés : $confirmes (null : table ou colonne absente), comme dans la sauvegarde"
  else rate "AUTH DETAILS" "$auth_ecarts"; fi
else
  echo "AUTH DETAILS:      —    non comparés (pas de manifeste, ou manifeste sans détail des comptes)"
fi

if [ "$echec" = 0 ]; then echo "FINAL RESULT:      PASS"; exit 0; fi
echo "FINAL RESULT:      FAIL"
exit 1
