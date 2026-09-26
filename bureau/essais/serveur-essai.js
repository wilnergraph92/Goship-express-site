/* ==========================================================================
   GoShip Express (bureau) — le site, servi pour les essais
   --------------------------------------------------------------------------
   Sert la racine du dépôt sur http://localhost:8765/ (l'environnement
   « local » de config/environnements.json), avec un config.js VIDE à la place
   du vrai : le site passe en mode démonstration et ne parle jamais à la base
   de production. Les essais du poste de travail n'ont besoin de rien d'autre,
   sur Windows, macOS ou Linux.

     node essais/serveur-essai.js        (Ctrl+C pour arrêter)
   ========================================================================== */
'use strict';

var http = require('http');
var fs = require('fs');
var path = require('path');

var RACINE = path.resolve(__dirname, '..', '..');
var PORT = 8765;
var CONFIG_VIDE = 'window.GOSHIP_CONFIG = { whatsapp: "18495386262", supabaseUrl: "", supabaseKey: "", carteEmail: "paye@exemple.com" };\n';
var TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'application/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
              '.png': 'image/png', '.jpg': 'image/jpeg', '.webp': 'image/webp', '.svg': 'image/svg+xml', '.ico': 'image/x-icon',
              '.json': 'application/json', '.woff2': 'font/woff2' };

function demarrer(port) {
  var serveur = http.createServer(function (req, res) {
    var chemin = decodeURIComponent(req.url.split(/[?#]/)[0]);
    if (chemin === '/') chemin = '/index.html';
    if (chemin === '/assets/js/config.js') {
      res.writeHead(200, { 'Content-Type': TYPES['.js'] });
      return res.end(CONFIG_VIDE);
    }
    var fichier = path.join(RACINE, path.normalize(chemin));
    // Rien hors du site : ni le dépôt git, ni les outils, ni l'application elle-même
    if (fichier.indexOf(RACINE + path.sep) !== 0 || /^[\\/](\.git|bureau|outils|application-mobile)([\\/]|$)/.test(chemin)) {
      res.writeHead(404); return res.end();
    }
    fs.readFile(fichier, function (err, contenu) {
      if (err) { res.writeHead(404); return res.end(); }
      res.writeHead(200, { 'Content-Type': TYPES[path.extname(fichier).toLowerCase()] || 'application/octet-stream' });
      res.end(contenu);
    });
  });
  return new Promise(function (ok, ko) {
    serveur.once('error', ko);
    serveur.listen(port || PORT, '127.0.0.1', function () { ok(serveur); });
  });
}

module.exports = { demarrer: demarrer, PORT: PORT };

if (require.main === module) {
  demarrer().then(function () { console.log('Site d\'essai (mode démonstration) : http://localhost:' + PORT + '/admin.html'); },
                  function (err) { console.error('Serveur impossible : ' + err.message); process.exit(1); });
}
