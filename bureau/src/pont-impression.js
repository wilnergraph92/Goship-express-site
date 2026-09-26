/* ==========================================================================
   GoShip Express (bureau) — le pont de la fenêtre « Imprimer »
   --------------------------------------------------------------------------
   La fenêtre locale ui/impression.html ne peut que : lister les imprimantes,
   demander l'aperçu, imprimer, enregistrer en PDF, se fermer. Le document
   lui-même ne passe jamais par elle : il reste dans l'application.
   ========================================================================== */
'use strict';

var electron = require('electron');
var ipcRenderer = electron.ipcRenderer;

electron.contextBridge.exposeInMainWorld('Impression', {
  preparer: function () { return ipcRenderer.invoke('impression:preparer'); },
  apercu: function () { return ipcRenderer.invoke('impression:apercu'); },
  imprimer: function (imprimante, copies) { return ipcRenderer.invoke('impression:imprimer', String(imprimante || ''), Number(copies) || 1); },
  pdf: function () { return ipcRenderer.invoke('impression:pdf'); },
  fermer: function () { return ipcRenderer.invoke('impression:fermer'); }
});
