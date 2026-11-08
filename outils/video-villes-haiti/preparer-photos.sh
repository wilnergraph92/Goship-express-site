#!/usr/bin/env bash
# ==========================================================================
#  Prépare les photos des villes pour la vidéo : agrandissement (lanczos),
#  netteté, étalonnage chaud « heure dorée ». Les photos préparées vont dans
#  photos/, que Git ignore : ce sont des images de tiers, elles ne vont pas
#  dans le dépôt. Sans photo, la ville garde son décor dessiné.
#
#  ./preparer-photos.sh dossier-source
#  Le dossier source contient, en .jpg : port-au-prince, cap-haitien,
#  gonaives, les-cayes, hinche, jacmel (une ou plusieurs).
# ==========================================================================
set -euo pipefail
cd "$(dirname "$0")"
source="${1:?Dossier des photos manquant}"
mkdir -p photos
for ville in port-au-prince cap-haitien gonaives les-cayes hinche jacmel; do
  f="$source/$ville.jpg"
  [ -f "$f" ] || { echo "— $ville : pas de photo, décor dessiné"; continue; }
  ffmpeg -y -v error -i "$f" -vf "scale=iw*3:ih*3:flags=lanczos,unsharp=7:7:0.7,eq=saturation=1.22:contrast=1.07:gamma=0.97,colorbalance=rs=0.03:bs=-0.05:rm=0.03:bm=-0.03:rh=0.04:bh=-0.04" -q:v 2 "photos/$ville.jpg"
  echo "✓ $ville"
done
