#!/usr/bin/env bash
# ==========================================================================
#  Fabrique la vidéo complète : images (rendre.js) + son (musique.py),
#  assemblés par ffmpeg. Demande node + Playwright, python3 + numpy, ffmpeg.
#
#  ./fabriquer.sh
#      → goship-villes-haiti.mp4               musique originale (libre de droits)
#      → goship-villes-haiti-effets-seuls.mp4  effets sans musique, pour ajouter
#                                              un morceau dans TikTok / Instagram
#      → goship-villes-haiti-miniature.png     la première image, seule
#
#  MUSIQUE=morceau.wav ./fabriquer.sh
#      La vidéo principale prend ce morceau à la place de la musique originale,
#      effets par-dessus. Le morceau doit déjà être calé : il démarre à la
#      première image, ses mesures de 2 s tombent sur les coupes (1,5 s puis
#      toutes les 6 s). Coupé à la durée de la vidéo, fondu sur les 2 dernières
#      secondes. Attention aux droits : un morceau du commerce sans licence
#      fait rendre la vidéo muette, ou la fait retirer, par les réseaux.
# ==========================================================================
set -euo pipefail
cd "$(dirname "$0")"
travail="$(mktemp -d)"
trap 'rm -rf "$travail"' EXIT

node rendre.js "$travail/images.mp4"
duree="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$travail/images.mp4")"
python3 musique.py "$travail/effets.wav" --effets

if [ -n "${MUSIQUE:-}" ]; then
  fin="$(python3 -c "print(max(0, $duree - 2))")"
  ffmpeg -y -v error -i "$MUSIQUE" -i "$travail/effets.wav" -filter_complex \
    "[0:a]aresample=44100,aformat=channel_layouts=stereo,atrim=0:$duree,afade=t=out:st=$fin:d=2,volume=0.8[m];[1:a]volume=0.55[e];[m][e]amix=inputs=2:normalize=0,loudnorm=I=-12:TP=-1:LRA=11[a]" \
    -map "[a]" -ar 44100 "$travail/son.wav"
else
  python3 musique.py "$travail/son.wav"
fi

assembler() {
  ffmpeg -y -v error -i "$travail/images.mp4" -i "$1" \
    -map 0:v -map 1:a -c:v copy -c:a aac -b:a 192k -shortest -movflags +faststart "$2"
}
assembler "$travail/son.wav" goship-villes-haiti.mp4
assembler "$travail/effets.wav" goship-villes-haiti-effets-seuls.mp4
node rendre.js --miniature goship-villes-haiti-miniature.png
echo "Prêt : goship-villes-haiti.mp4, goship-villes-haiti-effets-seuls.mp4, goship-villes-haiti-miniature.png"
