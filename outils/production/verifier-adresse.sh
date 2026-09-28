#!/bin/bash
# =============================================================================
# Goship Express — l'adresse de la base convient-elle à pg_dump depuis GitHub Actions ?
#
#   bash outils/production/verifier-adresse.sh [NOM_DE_LA_VARIABLE]   (SUPABASE_DB_URL par défaut)
#
# Lit l'adresse dans la variable d'environnement nommée (jamais en argument : les
# arguments se voient dans la liste des processus) et ne l'affiche JAMAIS, ni en
# entier ni en partie : une ligne dit seulement quel type d'adresse a été reconnu, ou
# pourquoi il est refusé. Aucune connexion n'est tentée.
#
# Sur l'offre gratuite de Supabase, depuis un runner GitHub (IPv4 seulement) :
#   ACCEPTÉE  Session pooler : postgresql://postgres.<ref>:<mot de passe>@aws-…pooler.supabase.com:5432/postgres
#   REFUSÉE   connexion directe db.<ref>.supabase.co (IPv6 seulement sur l'offre Free)
#   REFUSÉE   port 6543 (Transaction pooler : pg_dump a besoin d'une session à lui)
#   REFUSÉE   chaîne « clé=valeur », schéma autre que postgres(ql)://, utilisateur du
#             pooler sans « .<ref> », mot de passe absent, sslmode=disable|allow
# Une adresse hors Supabase (base jetable d'un essai, localhost) est acceptée telle quelle.
# Code de sortie : 0 acceptée, 1 refusée.
# =============================================================================
set -euo pipefail

variable="${1:-SUPABASE_DB_URL}"
[[ "$variable" =~ ^[A-Z_][A-Z0-9_]*$ ]] || { echo "Nom de variable invalide" >&2; exit 1; }
[ -n "${!variable:-}" ] || { echo "$variable vide ou absente" >&2; exit 1; }

ADRESSE="${!variable}" VARIABLE="$variable" python3 - <<'PY'
import os, re, sys
from urllib.parse import urlsplit, parse_qs

nom = os.environ['VARIABLE']
ATTENDU = ("attendu : l'adresse « Session pooler » de Supabase (Connect > Session pooler), "
           "postgresql://postgres.<ref>:<mot de passe>@aws-…pooler.supabase.com:5432/postgres")

def refuser(raison):
    print('%s REFUSÉE : %s ; %s.' % (nom, raison, ATTENDU), file=sys.stderr)
    sys.exit(1)

try:
    s = urlsplit(os.environ['ADRESSE'].strip())
    hote = (s.hostname or '').lower()
    port = s.port
    utilisateur = s.username or ''
    mot_de_passe = s.password or ''
    options = parse_qs(s.query)
except Exception:
    refuser("adresse illisible (caractère spécial du mot de passe non encodé ?)")

if s.scheme not in ('postgres', 'postgresql'):
    refuser("ce n'est pas une adresse postgresql://… (une chaîne « clé=valeur » n'est pas acceptée)")
if port == 6543:
    refuser("port 6543 : c'est le Transaction pooler, où pg_dump ne garde pas sa session")
if hote.endswith('.supabase.co'):
    refuser("connexion directe (db.<ref>.supabase.co) : sur l'offre Free elle n'est joignable qu'en "
            "IPv6, et les runners GitHub n'ont que l'IPv4")
if hote.endswith('.supabase.com'):
    if not hote.endswith('.pooler.supabase.com'):
        refuser("hôte Supabase inattendu (seul …pooler.supabase.com est accepté)")
    if (port or 5432) != 5432:
        refuser("port %s : le Session pooler écoute sur 5432" % port)
    if not re.fullmatch(r'[a-z_]+\.[a-z0-9]+', utilisateur):
        refuser("utilisateur du pooler sans la référence du projet (il s'écrit postgres.<ref>)")
    if not mot_de_passe:
        refuser("mot de passe absent de l'adresse")
    if set(options.get('sslmode', [])) & {'disable', 'allow'}:
        refuser("sslmode désactive le chiffrement de la connexion")
    print('%s ACCEPTÉE : Session pooler de Supabase (port 5432, IPv4)' % nom)
else:
    print('%s ACCEPTÉE : serveur PostgreSQL hors Supabase (base jetable ou autre)' % nom)
PY
