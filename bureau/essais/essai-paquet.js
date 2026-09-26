/* ==========================================================================
   GoShip Express (bureau) — l'essai de l'application construite
   --------------------------------------------------------------------------
   L'application empaquetée (celle qu'on installe) ne se pilote pas de
   l'extérieur : ses verrous (fuses) interdisent l'inspecteur. On la lance
   donc comme un utilisateur, sur le site d'essai (mode démonstration), et on
   lit son journal :
     1. serveur en marche  → « page chargée : …/admin.html », avec la version
        et le système attendus ;
     2. serveur arrêté     → la page locale « Connexion impossible » s'affiche
        (servie depuis l'archive de l'application).

     node essais/essai-paquet.js <chemin de l'exécutable>
   ========================================================================== */
'use strict';

var fs = require('fs');
var os = require('os');
var path = require('path');
var spawn = require('child_process').spawn;
var serveurEssai = require('./serveur-essai');

var exe = process.argv[2];
var VERSION = require('../package.json').version;
var n = 0, bons = 0;
function ok(t, v) { n++; if (v) bons++; console.log((v ? 'OK   ' : 'RATÉ ') + t); }
function attendre(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

// Le journal de l'application, où que le système range ses données
function fichierJournal() {
  var base = process.platform === 'win32' ? process.env.APPDATA
    : process.platform === 'darwin' ? path.join(os.homedir(), 'Library', 'Application Support')
    : (process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config'));
  return path.join(base, 'GoShip Express', 'journaux', 'bureau.log');
}

function lancer() {
  var p = spawn(exe, ['--env=local'], { stdio: 'ignore', detached: process.platform !== 'win32' });
  return p;
}
function arreter(p) {
  try { if (process.platform === 'win32') spawn('taskkill', ['/pid', String(p.pid), '/T', '/F']); else process.kill(-p.pid, 'SIGTERM'); }
  catch (e) { try { p.kill(); } catch (e2) { /* déjà arrêté */ } }
}
async function attendreLigne(depuis, motif, delai) {
  for (var t = 0; t < delai / 500; t++) {
    var texte = fs.existsSync(fichierJournal()) ? fs.readFileSync(fichierJournal(), 'utf8').slice(depuis) : '';
    if (motif.test(texte)) return texte;
    await attendre(500);
  }
  return fs.existsSync(fichierJournal()) ? fs.readFileSync(fichierJournal(), 'utf8').slice(depuis) : '';
}
function taille() { return fs.existsSync(fichierJournal()) ? fs.readFileSync(fichierJournal(), 'utf8').length : 0; }

(async function () {
  if (!exe || !fs.existsSync(exe)) { console.error('Exécutable introuvable : ' + exe); process.exit(2); }
  console.log('Application : ' + exe + '\nJournal : ' + fichierJournal());
  var systeme = { win32: 'win32', darwin: 'darwin', linux: 'linux' }[process.platform];

  var serveur = await serveurEssai.demarrer();
  var depuis = taille();
  var app = lancer();
  var texte = await attendreLigne(depuis, /page chargée : http:\/\/localhost:8765\/admin\.html/, 90000);
  arreter(app);
  serveur.close();
  ok('démarrage noté : version ' + VERSION + ', ' + systeme + ' ' + process.arch,
     new RegExp('démarrage ' + VERSION.replace(/\./g, '\\.') + ' \\(' + systeme + ' ').test(texte));
  ok('le tableau de bord du site est chargé', /page chargée : http:\/\/localhost:8765\/admin\.html/.test(texte));
  ok('aucune erreur au démarrage', !/ ERREUR /.test(texte));
  await attendre(3000);

  depuis = taille();
  app = lancer();
  texte = await attendreLigne(depuis, /page locale affichée : hors-ligne\.html/, 90000);
  await attendre(3000);
  texte = fs.readFileSync(fichierJournal(), 'utf8').slice(depuis);
  var echecs = (texte.match(/site injoignable/g) || []).length;
  ok('serveur arrêté : « Connexion impossible » affichée depuis l\'archive, une seule fois (' + echecs + ')',
     echecs === 1 && /page locale affichée : hors-ligne\.html/.test(texte) && !/page locale impossible/.test(texte));
  arreter(app);
  ok('jamais de jeton ni de clé dans le journal', !/eyJ[\w-]{8,}\.|service_role|sb_secret/.test(fs.readFileSync(fichierJournal(), 'utf8')));

  console.log('\n' + bons + ' / ' + n + ' vérifications (' + process.platform + ' ' + process.arch + ').');
  process.exit(bons === n ? 0 : 1);
})();
