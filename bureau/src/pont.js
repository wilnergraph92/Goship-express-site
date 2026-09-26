/* ==========================================================================
   GoShip Express (bureau) — le pont entre le site et l'application
   --------------------------------------------------------------------------
   Chargé avant la page, isolé d'elle (contextIsolation, sandbox). Il donne au
   tableau de bord un seul objet, window.GoshipBureau, et seulement si la page
   est bien celle du site configuré :

     version, plateforme, environnement, contrat   ce qu'est ce poste
     stockageSession                               la session Supabase, chiffrée
                                                   par le système (voir
                                                   stockage-session.js)
     imprimer({ html, titre, papier })             la fenêtre « Imprimer »
     journal(niveau, texte)                        une ligne dans le journal local
     surCommande(rappel)                           les commandes du menu

   Pas de require, pas d'accès aux fichiers, pas de commande système : le site
   ne peut rien demander d'autre que ces six choses, et l'application revérifie
   l'expéditeur de chaque message.

   Le « contrat » est la version de cet objet : le site le lit avant de se
   servir d'une fonction, pour qu'un poste ancien et un site plus récent
   (ou l'inverse) ne se cassent pas.
   ========================================================================== */
'use strict';

var electron = require('electron');
var contextBridge = electron.contextBridge, ipcRenderer = electron.ipcRenderer;

function argument(nom) {
  var prefixe = '--goship-' + nom + '=';
  for (var i = 0; i < process.argv.length; i++) {
    if (process.argv[i].indexOf(prefixe) === 0) return process.argv[i].slice(prefixe.length);
  }
  return '';
}

var site = argument('site');
var ici = window.location.href;
var PLATEFORMES = { win32: 'windows', darwin: 'macos', linux: 'linux' };

function estDuSite(adresse) {
  try {
    var u = new URL(adresse), s = new URL(site);
    return u.origin === s.origin && u.pathname.indexOf(s.pathname) === 0;
  } catch (e) { return false; }
}

if (site && estDuSite(ici)) {
  var rappels = [];
  ipcRenderer.on('bureau:commande', function (e, commande) {
    rappels.forEach(function (r) { try { r(String(commande)); } catch (err) { /* un rappel qui échoue n'empêche pas les autres */ } });
  });
  contextBridge.exposeInMainWorld('GoshipBureau', {
    contrat: 1,
    version: argument('version'),
    plateforme: PLATEFORMES[process.platform] || process.platform,
    environnement: argument('env'),
    stockageSession: {
      getItem: function (cle) { return ipcRenderer.invoke('bureau:session', 'lire', String(cle)); },
      setItem: function (cle, valeur) { return ipcRenderer.invoke('bureau:session', 'ecrire', String(cle), String(valeur)); },
      removeItem: function (cle) { return ipcRenderer.invoke('bureau:session', 'effacer', String(cle)); }
    },
    sessionChiffree: function () { return ipcRenderer.invoke('bureau:session', 'chiffree', 'sb-x'); },
    imprimer: function (demande) {
      demande = demande || {};
      return ipcRenderer.invoke('bureau:imprimer', {
        html: String(demande.html || ''), titre: String(demande.titre || ''), papier: String(demande.papier || '')
      });
    },
    journal: function (niveau, texte) { ipcRenderer.send('bureau:journal', String(niveau), String(texte).slice(0, 500)); },
    surCommande: function (rappel) { if (typeof rappel === 'function') rappels.push(rappel); }
  });
} else if (ici.split(/[?#]/)[0] === 'goship-app://ui/hors-ligne.html') {
  // La page « Connexion impossible » de l'application : un seul bouton
  contextBridge.exposeInMainWorld('GoshipHorsLigne', {
    reessayer: function () { ipcRenderer.send('bureau:reessayer'); }
  });
}
