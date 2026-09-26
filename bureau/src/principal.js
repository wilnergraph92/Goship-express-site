/* ==========================================================================
   GoShip Express (bureau) — le processus principal
   --------------------------------------------------------------------------
   Une fenêtre, qui ouvre le tableau de bord du site (admin.html). Tout le
   métier reste où il est : la base décide des prix, des statuts, des
   paiements et des permissions ; le site affiche. L'application ajoute ce
   qu'un navigateur fait mal sur un poste de travail : une fenêtre à soi,
   un menu, des raccourcis, l'impression avec choix de l'imprimante, la
   session chiffrée par le système, un journal local.

   Au lancement :
     1. une seule instance (un second lancement ramène la fenêtre) ;
     2. l'environnement (config/environnements.json) ;
     3. le site : sa page restaure la session si elle est encore valide,
        lit les permissions du compte et ouvre sa vue — sinon, la connexion ;
     4. si le site ne répond pas : « Connexion au serveur impossible »,
        avec « Réessayer », et un nouvel essai dès que le réseau revient.
   ========================================================================== */
'use strict';

var electron = require('electron');
var path = require('path');
var app = electron.app, BrowserWindow = electron.BrowserWindow, ipcMain = electron.ipcMain;
var shell = electron.shell, dialog = electron.dialog, Menu = electron.Menu, safeStorage = electron.safeStorage;

var journal = require('./journal');
var configuration = require('./config');
var securite = require('./securite');
var stockageSession = require('./stockage-session');
var preferencesPoste = require('./preferences');
var impression = require('./impression');
var menu = require('./menu');
var protocole = require('./protocole');

var GUIDE = 'https://github.com/wilnergraph92/Goship-express-site/blob/main/bureau/LISEZ-MOI.md';
// Les erreurs de chargement qui veulent dire « pas de réseau » : Internet coupé,
// nom introuvable, réseau changé, adresse injoignable, délai dépassé, proxy.
// Les autres (connexion refusée, fermée…) : le serveur ne répond pas.
var SANS_RESEAU = [-106, -105, -21, -109, -118, -130, -137, -7];

app.setName('GoShip Express');
if (process.platform === 'win32') app.setAppUserModelId('com.goshipexpress.bureau');
app.enableSandbox();
protocole.declarer(electron.protocol);   // avant « ready » : goship-app:// pour les pages de l'application
// Essais seulement : un dossier de données jetable (jamais dans l'application construite)
if (!app.isPackaged && process.env.GOSHIP_DONNEES) app.setPath('userData', process.env.GOSHIP_DONNEES);

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.whenReady().then(demarrer).catch(function (err) {
    journal.erreur('démarrage impossible : ' + (err && err.message));
    dialog.showErrorBox('GoShip Express', 'L’application n’a pas pu démarrer : ' + (err && err.message) + '.');
    app.quit();
  });
}

var fenetre = null;

// La fenêtre tient toujours dans l'écran : 1440 × 900 au plus (ou la taille
// retenue), jamais plus grande que la zone utile de l'écran (un poste en
// 1366 × 768 ou 1024 × 768 garde tout son tableau de bord visible), et une
// position retenue n'est reprise que si elle est encore sur un écran branché.
function cadreSurEcran(ecran, retenu) {
  var zone = ecran.getPrimaryDisplay().workArea;
  var cadre = {
    width: Math.min(retenu.width || 1440, zone.width),
    height: Math.min(retenu.height || 900, zone.height),
    minWidth: Math.min(1024, zone.width),
    minHeight: Math.min(640, zone.height)
  };
  if (typeof retenu.x === 'number' && typeof retenu.y === 'number') {
    var visible = ecran.getAllDisplays().some(function (d) {
      var a = d.workArea;
      return retenu.x >= a.x && retenu.y >= a.y && retenu.x + cadre.width <= a.x + a.width + 1 && retenu.y + cadre.height <= a.y + a.height + 1;
    });
    if (visible) { cadre.x = retenu.x; cadre.y = retenu.y; }
  }
  return cadre;
}

function demarrer() {
  journal.initialiser(app.getPath('userData'));
  var config = configuration.charger();
  journal.info('démarrage ' + app.getVersion() + ' (' + process.platform + ' ' + process.arch + ', Electron ' +
               process.versions.electron + ') — environnement ' + config.nom + ' : ' + config.site);

  var preferences = preferencesPoste.creer(app.getPath('userData'));
  var session = stockageSession.creer(safeStorage, app.getPath('userData'));
  protocole.installer(electron.session.defaultSession, 'ui');
  var imprimeur = impression.creer(electron, config, preferences);
  securite.installer(electron, config);

  // ---- La fenêtre -------------------------------------------------------------
  var cadre = cadreSurEcran(electron.screen, preferences.lire('fenetre', {}));
  fenetre = new BrowserWindow({
    width: cadre.width, height: cadre.height, x: cadre.x, y: cadre.y,
    minWidth: cadre.minWidth, minHeight: cadre.minHeight, show: false, backgroundColor: '#f3f6fb', title: 'GoShip Express',
    icon: path.join(__dirname, '..', 'build', 'icone.png'),
    webPreferences: {
      preload: path.join(__dirname, 'pont.js'),
      contextIsolation: true, sandbox: true, nodeIntegration: false, webSecurity: true,
      allowRunningInsecureContent: false, webviewTag: false, navigateOnDragDrop: false, spellcheck: false,
      additionalArguments: ['--goship-site=' + config.site, '--goship-version=' + app.getVersion(), '--goship-env=' + config.nom]
    }
  });
  if (cadre.maximise) fenetre.maximize();
  fenetre.once('ready-to-show', function () { fenetre.show(); });
  var garderCadre = function () {
    if (fenetre.isDestroyed() || fenetre.isMinimized() || fenetre.isFullScreen()) return;
    var b = fenetre.getNormalBounds();
    preferences.ecrire('fenetre', { x: b.x, y: b.y, width: b.width, height: b.height, maximise: fenetre.isMaximized() });
  };
  fenetre.on('close', garderCadre);
  fenetre.on('closed', function () { fenetre = null; });

  var contenu = fenetre.webContents;
  function ouvrirSite(vue) {
    contenu.loadURL(config.tableau + (vue ? '#' + vue : '')).catch(function () { /* did-fail-load s'en charge */ });
  }
  function horsLigne(raison, code) {
    journal.alerte('site injoignable (' + code + ') : ' + raison);
    fenetre.loadURL(protocole.page('hors-ligne.html') + '?raison=' + encodeURIComponent(raison) +
                    '&code=' + encodeURIComponent(String(code)));
  }
  contenu.on('did-fail-load', function (e, code, description, adresse, principal) {
    if (!principal || code === -3) return;   // -3 : chargement interrompu par une nouvelle navigation
    if (protocole.estPageLocale(adresse)) {       // jamais de boucle : la page locale elle-même a échoué
      journal.erreur('page locale impossible (' + code + ' ' + description + ')');
      return;
    }
    horsLigne(SANS_RESEAU.indexOf(code) >= 0 ? 'reseau' : 'serveur', code + ' ' + description);
  });
  contenu.on('did-navigate', function (e, adresse, statut) {
    if (!config.estDuSite(adresse)) return;
    if (statut >= 500) horsLigne('serveur', 'HTTP ' + statut);
    else if (statut >= 200 && statut < 400) journal.info('page chargée : ' + adresse);
  });
  contenu.on('did-finish-load', function () {
    if (protocole.estPageLocale(contenu.getURL(), 'hors-ligne.html')) journal.info('page locale affichée : hors-ligne.html');
  });
  contenu.on('render-process-gone', function (e, d) {
    journal.erreur('page arrêtée : ' + d.reason);
    if (d.reason !== 'clean-exit') ouvrirSite();
  });
  contenu.on('unresponsive', function () { journal.alerte('page sans réponse'); });
  contenu.on('console-message', function (e) {
    var d = e && e.level !== undefined ? e : { level: arguments[1], message: arguments[2] };
    if (d.level === 'error' || d.level === 3) journal.erreur('page : ' + d.message);
  });

  // ---- Les messages du site (vérifiés un par un) ------------------------------
  ipcMain.handle('bureau:session', function (ev, action, cle, valeur) {
    if (!securite.expediteurSite(config, fenetre, ev)) throw new Error('refusé');
    if (action === 'lire') return session.lire(cle);
    if (action === 'ecrire') return session.ecrire(cle, valeur);
    if (action === 'effacer') return session.effacer(cle);
    if (action === 'chiffree') return session.chiffree();
    throw new Error('action inconnue');
  });
  ipcMain.handle('bureau:imprimer', function (ev, demande) {
    if (!securite.expediteurSite(config, fenetre, ev)) throw new Error('refusé');
    return imprimeur.ouvrir(fenetre, demande);
  });
  var lignes = { minute: 0, nombre: 0 };
  ipcMain.on('bureau:journal', function (ev, niveau, texte) {
    if (!securite.expediteurSite(config, fenetre, ev)) return;
    var m = Math.floor(Date.now() / 60000);
    if (m !== lignes.minute) { lignes.minute = m; lignes.nombre = 0; }
    if (++lignes.nombre > 60) return;                    // pas plus de 60 lignes par minute depuis la page
    (niveau === 'erreur' ? journal.erreur : journal.info)('page : ' + String(texte).slice(0, 500));
  });
  ipcMain.on('bureau:reessayer', function (ev) {
    if (!fenetre || ev.sender !== fenetre.webContents || !protocole.estPageLocale(ev.senderFrame.url, 'hors-ligne.html')) return;
    ouvrirSite();
  });

  // ---- Le menu --------------------------------------------------------------------
  var aPropos = function () {
    dialog.showMessageBox(fenetre, {
      type: 'info', title: 'À propos de GoShip Express', message: 'GoShip Express ' + app.getVersion(),
      detail: 'Poste de travail de l’équipe GoShip Express.\n\n' +
              'Site : ' + config.site + ' (' + config.nom + ')\n' +
              'Système : ' + ({ win32: 'Windows', darwin: 'macOS', linux: 'Linux' }[process.platform] || process.platform) +
              ' ' + process.arch + '\nElectron ' + process.versions.electron + ' · Chromium ' + process.versions.chrome +
              '\nSession ' + (session.chiffree() ? 'chiffrée par le système' : 'gardée en mémoire (pas de coffre du système)')
    });
  };
  Menu.setApplicationMenu(menu.construire(electron, {
    developpement: !app.isPackaged,
    commande: function (nom) { if (fenetre) fenetre.webContents.send('bureau:commande', nom); },
    actualiser: function () { if (fenetre) (config.estDuSite(contenu.getURL()) ? contenu.reload() : ouvrirSite()); },
    agrandir: function () { if (fenetre) (fenetre.isMaximized() ? fenetre.unmaximize() : fenetre.maximize()); },
    guide: function () { shell.openExternal(GUIDE); },
    journaux: function () { if (journal.dossier()) shell.openPath(journal.dossier()); },
    aPropos: aPropos
  }));

  app.on('second-instance', function () {
    if (!fenetre) return;
    if (fenetre.isMinimized()) fenetre.restore();
    fenetre.focus();
  });
  app.on('window-all-closed', function () { app.quit(); });

  ouvrirSite(process.env.GOSHIP_VUE || '');
}
