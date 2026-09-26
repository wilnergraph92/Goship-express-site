/* ==========================================================================
   GoShip Express (bureau) — ce que les pages ont le droit de faire
   --------------------------------------------------------------------------
   L'application n'affiche qu'une page : le tableau de bord du site
   (admin.html). Tout le reste est fermé :
     - navigation : admin.html seulement ; une autre page du site (accueil,
       espace client) ou un lien extérieur s'ouvre dans le navigateur ;
       les adresses javascript:, file:, data:… ne s'ouvrent nulle part ;
     - nouvelles fenêtres (window.open, target=_blank) : jamais dans
       l'application ;
     - permissions du navigateur : notifications, copie dans le
       presse-papiers et plein écran, pour le site seulement ; caméra, micro,
       position, USB, HID, port série… refusés ;
     - Content-Security-Policy : celle de _headers (que GitHub Pages
       n'envoie pas), posée par l'application sur la page du site ;
     - messages vers l'application (IPC) : acceptés seulement de la page
       principale du site, dans la fenêtre principale.
   ========================================================================== */
'use strict';

var journal = require('./journal');

var SCHEMAS_EXTERIEURS = ['https:', 'http:', 'mailto:', 'tel:'];
var PERMISSIONS_ACCORDEES = ['notifications', 'clipboard-sanitized-write', 'fullscreen'];

// La même politique que _headers, avec l'hôte Supabase en générique : la clé
// et l'adresse du projet restent dans config.js, pas dans l'application.
function politique(origine) {
  var https = /^https:/.test(origine);
  return [
    "default-src 'self'",
    "base-uri 'self'",
    "object-src 'none'",
    "form-action 'self'",
    "script-src 'self'",
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
    "font-src 'self' https://fonts.gstatic.com",
    "img-src 'self' data: blob: https://images.unsplash.com https://*.supabase.co",
    "connect-src 'self' https://*.supabase.co wss://*.supabase.co",
    "frame-ancestors 'none'"
  ].concat(https ? ['upgrade-insecure-requests'] : []).join('; ');
}

// Une adresse que l'application garde : le tableau de bord, avec ou sans #vue
function estTableau(config, adresse) {
  try {
    var u = new URL(adresse);
    return config.estDuSite(adresse) && u.href.split(/[?#]/)[0] === config.tableau;
  } catch (e) { return false; }
}

function ouvrirDehors(shell, adresse) {
  var u;
  try { u = new URL(adresse); } catch (e) { return; }
  if (SCHEMAS_EXTERIEURS.indexOf(u.protocol) < 0) {
    journal.alerte('adresse refusée (' + u.protocol + ')');
    return;
  }
  journal.info('ouverture dans le navigateur : ' + u.origin + u.pathname);
  shell.openExternal(u.href);
}

function installer(electron, config) {
  var app = electron.app, session = electron.session, shell = electron.shell;

  // Toutes les pages, fenêtre principale comme fenêtre d'impression
  app.on('web-contents-created', function (e, contenu) {
    contenu.on('will-attach-webview', function (ev) { ev.preventDefault(); });
    contenu.setWindowOpenHandler(function (d) {
      ouvrirDehors(shell, d.url);
      return { action: 'deny' };
    });
    var garder = function (ev, adresse) {
      if (estTableau(config, adresse)) return;
      ev.preventDefault();
      ouvrirDehors(shell, adresse);
    };
    contenu.on('will-navigate', garder);
    contenu.on('will-redirect', function (ev, adresse, dansLaPage, principal) {
      if (principal) garder(ev, adresse);
    });
  });

  var ses = session.defaultSession;
  ses.setPermissionRequestHandler(function (contenu, permission, repondre, details) {
    var ok = PERMISSIONS_ACCORDEES.indexOf(permission) >= 0 && config.estDuSite((details && details.requestingUrl) || contenu.getURL());
    if (!ok) journal.alerte('permission refusée : ' + permission);
    repondre(ok);
  });
  ses.setPermissionCheckHandler(function (contenu, permission, origine) {
    var o = '';
    try { o = new URL(origine).origin; } catch (e) { o = ''; }
    return PERMISSIONS_ACCORDEES.indexOf(permission) >= 0 && o === config.origine;
  });
  // Aucun périphérique donné à une page : le scanner est un clavier, il n'en a pas besoin
  if (ses.setDevicePermissionHandler) ses.setDevicePermissionHandler(function () { return false; });

  var regle = politique(config.origine);
  ses.webRequest.onHeadersReceived({ urls: [config.origine + '/*'] }, function (d, rappel) {
    if (d.resourceType !== 'mainFrame' && d.resourceType !== 'subFrame') return rappel({});
    var entetes = Object.assign({}, d.responseHeaders);
    entetes['Content-Security-Policy'] = [regle];
    entetes['X-Content-Type-Options'] = ['nosniff'];
    rappel({ responseHeaders: entetes });
  });
}

// Un message IPC n'est accepté que de la page principale du site, dans la fenêtre prévue
function expediteurSite(config, fenetre, ev) {
  var cadre = ev.senderFrame;
  var ok = !!(fenetre && !fenetre.isDestroyed() && ev.sender === fenetre.webContents &&
              cadre && cadre.parent === null && config.estDuSite(cadre.url));
  if (!ok) journal.alerte('message IPC refusé' + (cadre ? ' depuis ' + cadre.url : ''));
  return ok;
}

module.exports = {
  installer: installer,
  politique: politique,
  estTableau: estTableau,
  expediteurSite: expediteurSite,
  ouvrirDehors: ouvrirDehors
};
