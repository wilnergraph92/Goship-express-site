#!/bin/bash
# =============================================================================
# Goship Express — vérifier une sauvegarde chiffrée, sans rien restaurer
#
#   bash outils/production/verifier-sauvegarde.sh <dossier> <nom> [clé privée age]
#     <dossier>  où se trouvent les six fichiers de la sauvegarde
#     <nom>      goship-AAAA-MM-JJTHHMMSSZ
#     <clé>      facultative : le fichier de la clé PRIVÉE age (jamais dans le dépôt)
#
# Sans clé : les six fichiers sont là, non vides, chiffrés (en-tête age), et chaque
# fichier chiffré a l'empreinte SHA-256 de son .sha256.
# Avec la clé, en plus : le manifeste et les deux archives se déchiffrent, leurs
# empreintes en clair sont celles du manifeste, et pg_restore relit chaque archive
# (tables et données principales, fonctions, déclencheurs, règles RLS, clés
# étrangères, comptes). Le clair ne vit que dans un dossier temporaire (700),
# effacé en sortant, même en cas d'erreur.
#
# Chaque ligne dit OK ou ÉCHEC ; la dernière, FINAL RESULT: PASS ou FAIL. Le code
# de sortie suit : 0 si tout est vert, 1 sinon. Aucune donnée n'est affichée : des
# noms de fichiers, des tailles, des nombres.
# =============================================================================
set -uo pipefail

dossier="${1:?Usage : verifier-sauvegarde.sh <dossier> <nom> [clé privée age]}"
nom="${2:?nom de la sauvegarde manquant (goship-AAAA-MM-JJTHHMMSSZ)}"
cle="${3:-}"
PG_RESTORE="${PG_RESTORE:-pg_restore}"
echec=0
ok()    { printf '%-18s OK   %s\n' "$1:" "${2:-}"; }
rate()  { printf '%-18s FAIL %s\n' "$1:" "${2:-}"; echec=1; }
octets() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 octets"; }

case "$nom" in
  goship-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9][0-9][0-9]Z|goship-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
  *) echo "Nom de sauvegarde invalide : $nom" >&2; exit 1 ;;
esac
PARTIES="public.dump comptes.dump manifeste.json"

# 1. Les six fichiers
manquants=""
for p in $PARTIES; do
  for f in "$nom.$p.age" "$nom.$p.age.sha256"; do [ -f "$dossier/$f" ] || manquants="$manquants $f"; done
done
if [ -z "$manquants" ]; then ok "BACKUP FOUND" "$nom (3 fichiers chiffrés + 3 empreintes)"; else rate "BACKUP FOUND" "manquants :$manquants"; fi

# 2. Tailles, chiffrement, empreintes des fichiers chiffrés
tailles="" ; chiffre=1 ; empreintes=1
for p in $PARTIES; do
  f="$dossier/$nom.$p.age"
  [ -f "$f" ] || { chiffre=0; empreintes=0; continue; }
  n="$(stat -c %s "$f")"
  tailles="$tailles ${p%%.*} $(octets "$n")"
  [ "$n" -gt 0 ] || chiffre=0
  [ "$(head -c 21 "$f")" = "age-encryption.org/v1" ] || chiffre=0
  if [ -f "$f.sha256" ]; then
    attendu="$(awk '{print $1}' "$f.sha256")"
    nomfichier="$(awk '{print $2}' "$f.sha256" | sed 's/^\*//')"
    obtenu="$(sha256sum "$f" | cut -d' ' -f1)"
    [ "$attendu" = "$obtenu" ] && [ "$nomfichier" = "$nom.$p.age" ] || empreintes=0
  else
    empreintes=0
  fi
done
public_octets="$(stat -c %s "$dossier/$nom.public.dump.age" 2>/dev/null || echo 0)"
if [ "$public_octets" -ge 20000 ]; then ok "SIZE" "${tailles# }"; else rate "SIZE" "schéma public trop petit (${tailles# })"; fi
[ "$empreintes" = 1 ] && ok "CHECKSUM" "SHA-256 des 3 fichiers chiffrés conforme" || rate "CHECKSUM" "empreinte absente ou différente : fichier altéré ?"
[ "$chiffre" = 1 ] && ok "ENCRYPTION" "en-tête age sur les 3 fichiers, aucun en clair" || rate "ENCRYPTION" "fichier vide ou non chiffré"

# 3. Avec la clé : déchiffrer et relire
if [ -n "$cle" ] && [ "$echec" = 0 ]; then
  [ -f "$cle" ] || { rate "DECRYPTION" "fichier de clé introuvable"; cle=""; }
fi
if [ -n "$cle" ] && [ "$echec" = 0 ]; then
  travail="$(mktemp -d)"
  chmod 700 "$travail"
  trap 'rm -rf "$travail"' EXIT
  if age -d -i "$cle" -o "$travail/manifeste.json" "$dossier/$nom.manifeste.json.age" 2> /dev/null \
     && age -d -i "$cle" -o "$travail/public.dump" "$dossier/$nom.public.dump.age" 2> /dev/null \
     && age -d -i "$cle" -o "$travail/comptes.dump" "$dossier/$nom.comptes.dump.age" 2> /dev/null; then
    ok "DECRYPTION" "3 fichiers déchiffrés avec la clé fournie"
    conforme=1
    for partie in public comptes; do
      attendu="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['fichiers'][sys.argv[2]]['sha256_clair'])" "$travail/manifeste.json" "$partie" 2>/dev/null)"
      [ "$attendu" = "$(sha256sum "$travail/$partie.dump" | cut -d' ' -f1)" ] || conforme=0
    done
    [ "$conforme" = 1 ] && ok "MANIFEST" "empreintes du clair identiques au manifeste" || rate "MANIFEST" "le clair ne correspond pas au manifeste"
    if "$PG_RESTORE" --list "$travail/public.dump" > "$travail/public.liste" 2> /dev/null \
       && "$PG_RESTORE" --list "$travail/comptes.dump" > "$travail/comptes.liste" 2> /dev/null; then
      manque=""
      for t in clients colis colis_historique factures paiements; do
        grep -q "TABLE DATA public $t " "$travail/public.liste" || manque="$manque public.$t"
      done
      grep -q "TABLE DATA auth users " "$travail/comptes.liste" || manque="$manque auth.users"
      n_tables="$(grep -c ' TABLE public ' "$travail/public.liste")"
      n_fonctions="$(grep -c ' FUNCTION public ' "$travail/public.liste")"
      n_declencheurs="$(grep -c ' TRIGGER public ' "$travail/public.liste")"
      n_regles="$(grep -c ' POLICY public ' "$travail/public.liste")"
      n_fk="$(grep -c ' FK CONSTRAINT public ' "$travail/public.liste")"
      if [ -z "$manque" ] && [ "$n_fonctions" -gt 0 ] && [ "$n_declencheurs" -gt 0 ] && [ "$n_regles" -gt 0 ] && [ "$n_fk" -gt 0 ]; then
        ok "DUMP STRUCTURE" "$n_tables tables, $n_fonctions fonctions, $n_declencheurs déclencheurs, $n_regles règles RLS, $n_fk clés étrangères"
      else
        rate "DUMP STRUCTURE" "incomplet :${manque:- fonctions/déclencheurs/règles/clés étrangères absents}"
      fi
      lignes="$(python3 -c "import json,sys;d=json.load(open(sys.argv[1]))['lignes_par_table'];print(len(d), sum(d.values()))" "$travail/manifeste.json" 2>/dev/null)"
      [ -n "$lignes" ] && ok "MANIFEST ROWS" "${lignes% *} tables, ${lignes#* } lignes attendues à la restauration" || rate "MANIFEST ROWS" "manifeste illisible"
    else
      rate "DUMP STRUCTURE" "pg_restore ne relit pas l'archive"
    fi
  else
    rate "DECRYPTION" "impossible avec cette clé (mauvaise clé ou fichier altéré)"
  fi
elif [ -z "$cle" ]; then
  echo "DECRYPTION:        —    non vérifié ici (pas de clé privée fournie)"
fi

if [ "$echec" = 0 ]; then echo "FINAL RESULT:      PASS"; exit 0; fi
echo "FINAL RESULT:      FAIL"
exit 1
