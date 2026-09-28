#!/bin/bash
# =============================================================================
# Goship Express — le stockage externe des sauvegardes chiffrées (rclone)
#
#   bash outils/production/stocker.sh envoyer   <dossier> <nom>
#   bash outils/production/stocker.sh lister
#   bash outils/production/stocker.sh recuperer <nom|derniere> <dossier>
#   bash outils/production/stocker.sh retention [garder]      (7 par défaut, 7 au moins)
#
# Où : rclone, qui parle à la plupart des stockages (Backblaze B2, Google Drive,
# Cloudflare R2, S3, OneDrive, SFTP…). Rien n'est propre à un fournisseur ici :
#   SAUVEGARDE_STOCKAGE    destination A, « remote:chemin » (obligatoire)
#   SAUVEGARDE_STOCKAGE_B  destination B, chez un AUTRE fournisseur (facultative)
#   RCLONE_CONFIG          chemin du fichier rclone.conf qui décrit ces remotes (ses
#                          clés d'accès : un secret, jamais dans le dépôt)
# Les destinations ne sont jamais affichées en entier : « destination A », « B ».
# A est obligatoire. B non configurée : « Destination B : SKIPPED » (jamais « réussi »).
# B configurée : exactement les mêmes exigences que A — son échec est un échec (code 1).
#
# envoyer   copie les six fichiers de <nom> vers A (et B), sans jamais écraser un
#           fichier existant (identique : sauté ; différent : échec), puis RELIT chaque fichier envoyé et compare son SHA-256
#           à l'empreinte locale : un envoi n'est réussi que relu.
# lister    les sauvegardes COMPLÈTES (six fichiers) de A, la plus récente d'abord
#           (SOURCE=B pour lire B).
# recuperer télécharge une sauvegarde complète et vérifie les SHA-256 ; « derniere »
#           prend la plus récente.
# retention garde les <garder> sauvegardes complètes les plus récentes de chaque
#           destination et supprime les plus anciennes, fichier par fichier, avec des
#           garde-fous : jamais moins de 7 gardées, rien supprimé s'il n'y a pas plus
#           de <garder> sauvegardes complètes, 3 sauvegardes supprimées au plus par
#           passage, seuls des noms exacts de sauvegarde (jamais de joker, jamais de
#           dossier entier), jamais la plus récente.
# Code de sortie : 0 si tout a réussi, 1 sinon.
# =============================================================================
set -euo pipefail

action="${1:?Usage : stocker.sh envoyer|lister|recuperer|retention …}"
: "${SAUVEGARDE_STOCKAGE:?SAUVEGARDE_STOCKAGE manquante (destination rclone « remote:chemin »)}"
: "${RCLONE_CONFIG:?RCLONE_CONFIG manquante (chemin du fichier rclone.conf)}"
[ -f "$RCLONE_CONFIG" ] || { echo "Fichier rclone.conf introuvable" >&2; exit 1; }
export RCLONE_CONFIG
command -v rclone > /dev/null || { echo "Outil manquant : rclone" >&2; exit 1; }
PARTIES="public.dump comptes.dump manifeste.json"
MAX_SUPPRESSIONS=3
MINIMUM_GARDE=7
RC=(rclone --retries 3 --low-level-retries 5 --stats 0 -q)

# destination « A » ou « B » → remote:chemin (sans / final)
destination() {
  case "$1" in
    A) echo "${SAUVEGARDE_STOCKAGE%/}" ;;
    B) echo "${SAUVEGARDE_STOCKAGE_B%/}" ;;
  esac
}
destinations() { echo A; [ -n "${SAUVEGARDE_STOCKAGE_B:-}" ] && echo B; return 0; }

nom_valide() {
  [[ "$1" =~ ^goship-[0-9]{4}-[0-9]{2}-[0-9]{2}T([0-9]{4}|[0-9]{6})Z$ ]]
}

# Les sauvegardes d'une destination : « nom complet|incomplet », la plus récente d'abord
inventaire() {
  local liste
  liste="$("${RC[@]}" lsf --files-only "$(destination "$1")" 2> /dev/null)" || { echo "Destination $1 illisible" >&2; return 1; }
  printf '%s\n' "$liste" | python3 -c '
import re, sys
motif = re.compile(r"^(goship-\d{4}-\d{2}-\d{2}T(?:\d{4}|\d{6})Z)\.(public\.dump|comptes\.dump|manifeste\.json)\.age(\.sha256)?$")
vus = {}
for ligne in sys.stdin:
    m = motif.match(ligne.strip())
    if m:
        vus.setdefault(m.group(1), set()).add(ligne.strip())
def cle(nom):                     # T0523Z (ancien format) se range comme T052300Z
    return re.sub(r"T(\d{4})Z$", r"T\g<1>00Z", nom)
for nom in sorted(vus, key=cle, reverse=True):
    print("%s|%s" % (nom, "complet" if len(vus[nom]) == 6 else "incomplet"))
'
}

case "$action" in
  envoyer)
    dossier="${2:?Usage : stocker.sh envoyer <dossier> <nom>}"
    nom="${3:?nom manquant}"
    nom_valide "$nom" || { echo "Nom de sauvegarde invalide" >&2; exit 1; }
    for p in $PARTIES; do
      [ -f "$dossier/$nom.$p.age" ] && [ -f "$dossier/$nom.$p.age.sha256" ] || { echo "Fichier local manquant : $nom.$p.age(.sha256)" >&2; exit 1; }
      ( cd "$dossier" && sha256sum -c --quiet "$nom.$p.age.sha256" ) || { echo "Empreinte locale fausse : $nom.$p.age" >&2; exit 1; }
    done
    for d in $(destinations); do
      cible="$(destination "$d")"
      for p in $PARTIES; do
        for f in "$nom.$p.age" "$nom.$p.age.sha256"; do
          # Un fichier déjà présent n'est jamais remplacé : identique, on passe ; différent,
          # on s'arrête. (L'option --immutable de rclone ne suffit pas : à taille et date
          # égales, elle laisse passer un contenu différent.)
          if [ -n "$("${RC[@]}" lsf --files-only "$cible/$f" 2> /dev/null)" ]; then
            if [ "$("${RC[@]}" cat "$cible/$f" | sha256sum | cut -d' ' -f1)" = "$(sha256sum "$dossier/$f" | cut -d' ' -f1)" ]; then
              continue
            fi
            echo "Destination $d : $f existe déjà avec un autre contenu, jamais remplacé" >&2
            exit 1
          fi
          "${RC[@]}" copyto "$dossier/$f" "$cible/$f" || { echo "Envoi impossible vers la destination $d : $f" >&2; exit 1; }
        done
      done
      # Relire ce qui est arrivé : l'envoi n'est réussi que si le SHA-256 relu est le bon
      for p in $PARTIES; do
        attendu="$(awk '{print $1}' "$dossier/$nom.$p.age.sha256")"
        relu="$("${RC[@]}" cat "$cible/$nom.$p.age" | sha256sum | cut -d' ' -f1)"
        [ "$relu" = "$attendu" ] || { echo "Destination $d : $nom.$p.age relu différent (SHA-256)" >&2; exit 1; }
        cmp -s <("${RC[@]}" cat "$cible/$nom.$p.age.sha256") "$dossier/$nom.$p.age.sha256" \
          || { echo "Destination $d : empreinte $nom.$p.age.sha256 relue différente" >&2; exit 1; }
      done
      echo "Destination $d : 6 fichiers envoyés et relus (SHA-256 identiques)"
    done
    [ -n "${SAUVEGARDE_STOCKAGE_B:-}" ] || echo "Destination B : SKIPPED (non configurée)"
    ;;

  lister)
    inventaire "${SOURCE:-A}" | awk -F'|' '$2 == "complet" {print $1}'
    ;;

  recuperer)
    quoi="${2:?Usage : stocker.sh recuperer <nom|derniere> <dossier>}"
    dossier="${3:?dossier de destination manquant}"
    source="${SOURCE:-A}"
    if [ "$quoi" = "derniere" ]; then
      quoi="$(inventaire "$source" | awk -F'|' '$2 == "complet" {print $1; exit}')"
      [ -n "$quoi" ] || { echo "Aucune sauvegarde complète dans la destination $source" >&2; exit 1; }
    fi
    nom_valide "$quoi" || { echo "Nom de sauvegarde invalide" >&2; exit 1; }
    mkdir -p "$dossier"
    for p in $PARTIES; do
      for f in "$quoi.$p.age" "$quoi.$p.age.sha256"; do
        "${RC[@]}" copyto "$(destination "$source")/$f" "$dossier/$f" || { echo "Téléchargement impossible : $f" >&2; exit 1; }
      done
      ( cd "$dossier" && sha256sum -c --quiet "$quoi.$p.age.sha256" ) || { echo "SHA-256 faux après téléchargement : $quoi.$p.age" >&2; exit 1; }
    done
    echo "$quoi"
    ;;

  retention)
    garder="${2:-$MINIMUM_GARDE}"
    [[ "$garder" =~ ^[0-9]+$ ]] && [ "$garder" -ge "$MINIMUM_GARDE" ] || { echo "Rétention refusée : garder au moins $MINIMUM_GARDE sauvegardes" >&2; exit 1; }
    for d in $(destinations); do
      cible="$(destination "$d")"
      inv="$(inventaire "$d")"
      completes="$(printf '%s\n' "$inv" | awk -F'|' '$2 == "complet" {print $1}' | grep -c . || true)"
      if [ "$completes" -le "$garder" ]; then
        echo "Destination $d : $completes sauvegarde(s) complète(s), rien à supprimer (on en garde $garder)"
        continue
      fi
      # La plus ancienne gardée : la <garder>-ième complète. Tout ce qui est plus ancien part
      # (complet ou non) ; les incomplètes plus récentes restent, pour qu'on les voie.
      derniere_gardee="$(printf '%s\n' "$inv" | awk -F'|' '$2 == "complet" {print $1}' | sed -n "${garder}p")"
      a_supprimer="$(printf '%s\n' "$inv" | awk -F'|' -v g="$derniere_gardee" 'vu {print $1} $1 == g {vu = 1}')"
      n=0
      for nom in $a_supprimer; do
        nom_valide "$nom" || { echo "Nom inattendu, arrêt : rien de plus n'est supprimé" >&2; exit 1; }
        if [ "$n" -ge "$MAX_SUPPRESSIONS" ]; then
          echo "::warning::Destination $d : plus de $MAX_SUPPRESSIONS sauvegardes à supprimer ; le reste au prochain passage."
          break
        fi
        for p in $PARTIES; do
          for f in "$nom.$p.age" "$nom.$p.age.sha256"; do
            # deletefile : un seul fichier, nommé exactement ; absent = déjà supprimé
            "${RC[@]}" deletefile "$cible/$f" 2> /dev/null || true
          done
        done
        n=$((n + 1))
        echo "Destination $d : $nom supprimée (plus ancienne que les $garder gardées)"
      done
      restantes="$(inventaire "$d" | awk -F'|' '$2 == "complet"' | grep -c . || true)"
      [ "$restantes" -ge "$garder" ] || { echo "Destination $d : seulement $restantes sauvegardes complètes après rétention" >&2; exit 1; }
      echo "Destination $d : $restantes sauvegardes complètes gardées"
    done
    [ -n "${SAUVEGARDE_STOCKAGE_B:-}" ] || echo "Destination B : SKIPPED (non configurée)"
    ;;

  *)
    echo "Action inconnue : $action (envoyer, lister, recuperer, retention)" >&2
    exit 1
    ;;
esac
