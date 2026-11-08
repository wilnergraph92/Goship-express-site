#!/usr/bin/env bash
# ==========================================================================
#  Fabrique la vidéo complète : images (rendre.js) + musique (musique.py),
#  assemblées par ffmpeg. Demande node + Playwright, python3 + numpy, ffmpeg.
#
#  ./fabriquer.sh            → goship-villes-haiti.mp4 et sa miniature (PNG)
# ==========================================================================
set -euo pipefail
cd "$(dirname "$0")"
travail="$(mktemp -d)"
trap 'rm -rf "$travail"' EXIT

node rendre.js "$travail/images.mp4"
python3 musique.py "$travail/musique.wav"
ffmpeg -y -v error -i "$travail/images.mp4" -i "$travail/musique.wav" \
  -map 0:v -map 1:a -c:v copy -c:a aac -b:a 192k -shortest -movflags +faststart \
  goship-villes-haiti.mp4
node rendre.js --miniature goship-villes-haiti-miniature.png
echo "Vidéo prête : $(pwd)/goship-villes-haiti.mp4 (miniature : goship-villes-haiti-miniature.png)"
