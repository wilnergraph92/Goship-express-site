/* ==========================================================================
   Fabrique la vidéo image par image : sert le dépôt en local, ouvre
   index.html dans Chromium (Playwright), demande chaque image à
   GoshipVideo.rendre(t) et la passe à ffmpeg.

   node rendre.js [sortie.mp4] [--debut 12] [--fin 18] [--images 0,6.5,13]
   --images : n'écrit que quelques images PNG (vérification rapide).
   --miniature fichier.png : n'écrit que la miniature (première image).
   ========================================================================== */
'use strict';
var http = require('http');
var fs = require('fs');
var path = require('path');
var spawn = require('child_process').spawn;
var chromium = require('playwright').chromium;

var RACINE = path.resolve(__dirname, '..', '..');
var FPS = 30;
var args = process.argv.slice(2);
function option(nom, defaut) { var i = args.indexOf(nom); return i >= 0 ? args[i + 1] : defaut; }
var sortie = args[0] && args[0].indexOf('--') !== 0 ? args[0] : path.join(__dirname, 'goship-villes-haiti-sans-son.mp4');

// Petit serveur statique : le canvas refuse d'exporter une image chargée
// en file:// (le logo), il faut une vraie adresse http.
var TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.png': 'image/png', '.ttf': 'font/ttf' };
var serveur = http.createServer(function (req, res) {
  var p = path.join(RACINE, decodeURIComponent(req.url.split('?')[0]));
  if (p.indexOf(RACINE) !== 0 || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { 'Content-Type': TYPES[path.extname(p)] || 'application/octet-stream' });
  fs.createReadStream(p).pipe(res);
});

serveur.listen(0, '127.0.0.1', async function () {
  var port = serveur.address().port;
  var navigateur = await chromium.launch();
  var page = await navigateur.newPage({ viewport: { width: 540, height: 960 } });
  page.on('pageerror', function (e) { console.error('Erreur dans la page :', e.message); });
  await page.goto('http://127.0.0.1:' + port + '/outils/video-villes-haiti/index.html?rendu');
  var infos = await page.evaluate(function () { return GoshipVideo.preparer(); });
  console.log('Durée : ' + infos.duree + ' s, ' + infos.largeur + '×' + infos.hauteur);

  var mini = option('--miniature');
  if (mini) {
    var png = await page.evaluate(function () { return GoshipVideo.miniature(); });
    fs.writeFileSync(mini, Buffer.from(png.split(',')[1], 'base64'));
    console.log('Miniature : ' + mini);
    await navigateur.close(); serveur.close(); return;
  }

  var liste = option('--images');
  if (liste) {
    var dossier = option('--dossier', path.join(__dirname, 'apercus'));
    fs.mkdirSync(dossier, { recursive: true });
    for (var t of liste.split(',').map(Number)) {
      var url = await page.evaluate(function (t) { GoshipVideo.rendre(t); return document.getElementById('ecran').toDataURL('image/png'); }, t);
      var f = path.join(dossier, 'image-' + String(t).replace('.', '_') + '.png');
      fs.writeFileSync(f, Buffer.from(url.split(',')[1], 'base64'));
      console.log(f);
    }
    await navigateur.close(); serveur.close(); return;
  }

  var debut = Number(option('--debut', 0)), fin = Number(option('--fin', infos.duree));
  var n = Math.round((fin - debut) * FPS);
  var ff = spawn('ffmpeg', ['-y', '-v', 'error', '-f', 'image2pipe', '-framerate', String(FPS), '-c:v', 'mjpeg', '-i', '-',
    '-c:v', 'libx264', '-preset', 'slow', '-crf', '18', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', sortie],
    { stdio: ['pipe', 'inherit', 'inherit'] });
  var t0 = Date.now();
  for (var i = 0; i < n; i++) {
    var b64 = await page.evaluate(function (t) { GoshipVideo.rendre(t); return GoshipVideo.image(0.95).split(',')[1]; }, debut + i / FPS);
    if (!ff.stdin.write(Buffer.from(b64, 'base64'))) await new Promise(function (ok) { ff.stdin.once('drain', ok); });
    if (i % 60 === 0) console.log('image ' + i + ' / ' + n + ' (' + ((Date.now() - t0) / 1000).toFixed(0) + ' s)');
  }
  ff.stdin.end();
  await new Promise(function (ok) { ff.on('close', ok); });
  console.log('Écrit : ' + sortie + ' en ' + ((Date.now() - t0) / 1000).toFixed(0) + ' s');
  await navigateur.close(); serveur.close();
});
