/* ==========================================================================
   GoShip Express (bureau) — le menu de l'application
   --------------------------------------------------------------------------
   Seulement des commandes qui existent. Ctrl/Cmd+K et Ctrl/Cmd+Maj+S sont
   affichés ici mais traités par la page (admin.js), qui les connaît aussi
   dans un navigateur : registerAccelerator: false laisse la touche arriver
   jusqu'à elle, et un clic dans le menu lui envoie la même commande.
   ========================================================================== */
'use strict';

function construire(electron, o) {
  var Menu = electron.Menu, app = electron.app;
  var mac = process.platform === 'darwin';
  var commande = function (nom) { return function () { o.commande(nom); }; };

  var modele = [];
  if (mac) {
    modele.push({ label: app.name, submenu: [
      { label: 'À propos de GoShip Express', click: o.aPropos },
      { type: 'separator' },
      { label: 'Préférences…', accelerator: 'Cmd+,', click: commande('reglages') },
      { type: 'separator' },
      { role: 'services', label: 'Services' },
      { type: 'separator' },
      { role: 'hide', label: 'Masquer GoShip Express' },
      { role: 'hideOthers', label: 'Masquer les autres' },
      { role: 'unhide', label: 'Tout afficher' },
      { type: 'separator' },
      { role: 'quit', label: 'Quitter GoShip Express' }
    ] });
  }
  modele.push({ label: 'Fichier', submenu: [
    { label: 'Recherche rapide', accelerator: 'CmdOrCtrl+K', registerAccelerator: false, click: commande('recherche') },
    { label: 'Poste de scan', accelerator: 'CmdOrCtrl+Shift+S', registerAccelerator: false, click: commande('scanner') },
    { type: 'separator' },
    { label: 'Actualiser', accelerator: 'CmdOrCtrl+R', click: o.actualiser }
  ].concat(mac ? [] : [
    { label: 'Préférences…', accelerator: 'Ctrl+,', click: commande('reglages') },
    { type: 'separator' },
    { role: 'quit', label: 'Quitter' }
  ]) });
  modele.push({ label: 'Édition', submenu: [
    { role: 'undo', label: 'Annuler' },
    { role: 'redo', label: 'Rétablir' },
    { type: 'separator' },
    { role: 'cut', label: 'Couper' },
    { role: 'copy', label: 'Copier' },
    { role: 'paste', label: 'Coller' },
    { role: 'selectAll', label: 'Tout sélectionner' }
  ] });
  modele.push({ label: 'Affichage', submenu: [
    { role: 'resetZoom', label: 'Taille réelle' },
    { role: 'zoomIn', label: 'Agrandir' },
    { role: 'zoomOut', label: 'Réduire' },
    { type: 'separator' },
    { role: 'togglefullscreen', label: 'Plein écran' }
  ].concat(o.developpement ? [{ type: 'separator' }, { role: 'toggleDevTools', label: 'Outils de développement' }] : []) });
  modele.push({ label: 'Fenêtre', submenu: [
    { role: 'minimize', label: 'Réduire' },
    mac ? { role: 'zoom', label: 'Agrandir' } : { label: 'Agrandir', click: o.agrandir },
    { role: 'close', label: 'Fermer' }
  ] });
  modele.push({ label: 'Aide', role: 'help', submenu: [
    { label: 'Guide du poste de travail', click: o.guide },
    { label: 'Ouvrir le dossier des journaux', click: o.journaux }
  ].concat(mac ? [] : [{ type: 'separator' }, { label: 'À propos de GoShip Express', click: o.aPropos }]) });

  return Menu.buildFromTemplate(modele);
}

module.exports = { construire: construire };
