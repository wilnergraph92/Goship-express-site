#!/bin/bash
# Goship Express — voir le site sur cet ordinateur.
# Double-cliquez sur ce fichier : le tableau de bord s'ouvre dans votre navigateur
# (http://localhost:8000/admin.html). Laissez la fenêtre du Terminal ouverte pendant
# votre visite ; fermez-la pour arrêter. Inutile de mettre ce fichier en ligne.
cd "$(dirname "$0")" || exit 1
PORT=8000
ADRESSE="http://localhost:$PORT/admin.html"

# Site déjà démarré : on ouvre simplement la page
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  open "$ADRESSE"
  exit 0
fi

echo "Site Goship Express : http://localhost:$PORT/"
echo "Tableau de bord     : $ADRESSE"
echo "Démonstration       : admin@goship.demo / demo1234"
echo
echo "Laissez cette fenêtre ouverte ; fermez-la pour arrêter le site."
(sleep 1 && open "$ADRESSE") &
# Petit serveur local ; « no-cache » : le navigateur affiche toujours la dernière version
exec python3 - "$PORT" <<'PY'
import http.server
import sys


class Serveur(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cache-Control', 'no-cache')
        super().end_headers()


http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), Serveur).serve_forever()
PY
