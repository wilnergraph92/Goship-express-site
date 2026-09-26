/* ==========================================================================
   GoShip Express (bureau) — imprimer une étiquette, une facture, un rapport
   --------------------------------------------------------------------------
   Le document ne change pas : c'est celui qu'assemble le site
   (assets/js/impression.js — étiquette 4×6, facture A4, Code128, QR), avec
   sa feuille impression.css. L'application ne fait que l'imprimer mieux
   qu'un navigateur :
     - une fenêtre « Imprimer » : l'aperçu exact (PDF), le choix de
       l'imprimante, le nombre d'exemplaires ;
     - l'imprimante choisie est retenue par format (l'étiquette part sur
       l'imprimante thermique, la facture sur l'imprimante de bureau) ;
     - « Enregistrer en PDF » ;
     - si l'imprimante refuse, le message le dit et « Réessayer » relance.
   Rien ne s'imprime sans cette fenêtre : pas d'impression silencieuse.

   Le document est rendu dans une fenêtre cachée, sans JavaScript, qui ne
   peut charger que le site (feuille de style, logo, signature). Il est gardé
   en mémoire (goship-app://document/…) et jamais écrit sur le disque : une
   facture ne traîne pas dans un dossier temporaire.
   ========================================================================== */
'use strict';

var fs = require('fs');
var path = require('path');
var journal = require('./journal');
var protocole = require('./protocole');

var FORMATS = {
  'A4': { nom: 'A4', page: 'A4' },
  '4in 6in': { nom: 'Étiquette 4 × 6 po', page: { width: 101600, height: 152400 } }   // en microns
};

function nomFichier(titre) {
  return (String(titre || 'document').replace(/[\\/:*?"<>|\r\n]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 80) || 'document') + '.pdf';
}

function creer(electron, config, preferences) {
  var BrowserWindow = electron.BrowserWindow, dialog = electron.dialog, ipcMain = electron.ipcMain, session = electron.session;
  var enCours = null;   // une seule fenêtre « Imprimer » à la fois

  // La session des documents : le site et les polices, rien d'autre
  var sesRendu = session.fromPartition('goship-impression');
  protocole.installer(sesRendu, 'document');
  sesRendu.webRequest.onBeforeRequest(function (d, rappel) {
    var ok = d.url.indexOf(protocole.SCHEMA + '://document/') === 0 || config.estDuSite(d.url) ||
             /^https:\/\/fonts\.(googleapis|gstatic)\.com\//.test(d.url) || /^data:/.test(d.url);
    if (!ok) journal.alerte('impression : ressource refusée ' + d.url);
    rappel({ cancel: !ok });
  });
  sesRendu.setPermissionRequestHandler(function (c, p, repondre) { repondre(false); });

  // Le document → une fenêtre cachée qui l'a chargé (feuille de style et images comprises)
  function rendre(doc) {
    var memoire = protocole.ajouterDocument(doc.html);
    var rendu = new BrowserWindow({
      show: false, width: 900, height: 1200,
      webPreferences: { javascript: false, sandbox: true, contextIsolation: true, nodeIntegration: false,
                        session: sesRendu, spellcheck: false }
    });
    var nettoyer = function () {
      memoire.oublier();
      if (!rendu.isDestroyed()) rendu.destroy();
    };
    return rendu.loadURL(memoire.adresse).then(function () {
      return { fenetre: rendu, nettoyer: nettoyer };
    }, function (err) { nettoyer(); throw err; });
  }

  function options(doc) {
    var f = FORMATS[doc.papier] || FORMATS.A4;
    return { printBackground: true, pageSize: f.page, margins: { marginType: 'none' } };
  }

  // Ce que le site envoie : vérifié avant tout usage
  function valider(demande) {
    if (!demande || typeof demande.html !== 'string' || !demande.html.length) throw new Error('document vide');
    if (demande.html.length > 8 * 1024 * 1024) throw new Error('document trop lourd');
    var papier = FORMATS[demande.papier] ? demande.papier : 'A4';
    return { html: demande.html, papier: papier, titre: String(demande.titre || 'Document').slice(0, 160) };
  }

  // La fenêtre « Imprimer » : se résout quand elle se ferme — { etat: imprime | pdf | annule }
  function ouvrir(parent, demande) {
    var doc = valider(demande);
    if (enCours) { enCours.fenetre.focus(); return Promise.resolve({ etat: 'occupe' }); }
    return new Promise(function (resoudre) {
      var etat = { etat: 'annule' };
      var fen = new BrowserWindow({
        parent: parent, modal: true, width: 980, height: 760, minWidth: 720, minHeight: 520,
        title: 'Imprimer — ' + doc.titre, show: false, backgroundColor: '#f3f6fb',
        webPreferences: { preload: path.join(__dirname, 'pont-impression.js'), sandbox: true, contextIsolation: true,
                          nodeIntegration: false, plugins: true, spellcheck: false }
      });
      fen.setMenuBarVisibility(false);
      var rendu = null, pdf = null;
      enCours = { fenetre: fen, doc: doc,
        definir: function (e) { etat = e; },
        apercu: function () {
          var p = rendu ? Promise.resolve(rendu) : rendre(doc).then(function (r) { rendu = r; return r; });
          return p.then(function (r) {
            return r.fenetre.webContents.printToPDF(Object.assign({ preferCSSPageSize: true }, options(doc)));
          }).then(function (b) { pdf = b; return b; });
        },
        imprimer: function (imprimante, copies) {
          var p = rendu ? Promise.resolve(rendu) : rendre(doc).then(function (r) { rendu = r; return r; });
          return p.then(function (r) {
            return new Promise(function (ok) {
              r.fenetre.webContents.print(Object.assign({ silent: true, deviceName: imprimante, copies: copies }, options(doc)),
                function (reussi, raison) { ok({ ok: reussi, raison: raison || '' }); });
            });
          }).then(function (res) {
            if (res.ok) {
              var choix = preferences.lire('imprimantes', {});
              choix[doc.papier] = imprimante;
              preferences.ecrire('imprimantes', choix);
              journal.info('impression envoyée (' + doc.papier + ', ' + copies + ' ex.)');
            } else {
              journal.erreur('impression échouée (' + doc.papier + ') : ' + res.raison);
            }
            return res;
          });
        },
        pdf: function () {
          return (pdf ? Promise.resolve(pdf) : enCours.apercu()).then(function (b) {
            return dialog.showSaveDialog(fen, { defaultPath: nomFichier(doc.titre), filters: [{ name: 'PDF', extensions: ['pdf'] }] })
              .then(function (r) {
                if (r.canceled || !r.filePath) return { ok: false, annule: true };
                fs.writeFileSync(r.filePath, b);
                journal.info('PDF enregistré (' + doc.papier + ')');
                return { ok: true };
              });
          });
        }
      };
      fen.on('closed', function () {
        if (rendu) rendu.nettoyer();
        enCours = null;
        resoudre(etat);
      });
      fen.once('ready-to-show', function () { fen.show(); });
      fen.loadURL(protocole.page('impression.html'));
    });
  }

  // Les messages de la fenêtre « Imprimer », d'elle seule
  function depuisDialogue(ev) {
    var ok = !!(enCours && ev.sender === enCours.fenetre.webContents);
    if (!ok) journal.alerte('impression : message refusé');
    return ok;
  }
  ipcMain.handle('impression:preparer', function (ev) {
    if (!depuisDialogue(ev)) throw new Error('refusé');
    return ev.sender.getPrintersAsync().then(function (liste) {
      var choix = preferences.lire('imprimantes', {})[enCours.doc.papier];
      return {
        titre: enCours.doc.titre,
        format: (FORMATS[enCours.doc.papier] || FORMATS.A4).nom,
        imprimantes: liste.map(function (p) { return { nom: p.name, libelle: p.displayName || p.name, defaut: !!p.isDefault }; }),
        choix: liste.some(function (p) { return p.name === choix; }) ? choix : ''
      };
    });
  });
  ipcMain.handle('impression:apercu', function (ev) {
    if (!depuisDialogue(ev)) throw new Error('refusé');
    return enCours.apercu().then(function (b) { return new Uint8Array(b); });
  });
  ipcMain.handle('impression:imprimer', function (ev, imprimante, copies) {
    if (!depuisDialogue(ev)) throw new Error('refusé');
    copies = Math.max(1, Math.min(50, parseInt(copies, 10) || 1));
    if (typeof imprimante !== 'string' || !imprimante) return { ok: false, raison: 'Choisissez une imprimante.' };
    return enCours.imprimer(imprimante, copies).then(function (r) {
      if (r.ok) enCours.definir({ etat: 'imprime' });
      return r;
    });
  });
  ipcMain.handle('impression:pdf', function (ev) {
    if (!depuisDialogue(ev)) throw new Error('refusé');
    return enCours.pdf().then(function (r) {
      if (r.ok) enCours.definir({ etat: 'pdf' });
      return r;
    });
  });
  ipcMain.handle('impression:fermer', function (ev) {
    if (!depuisDialogue(ev)) throw new Error('refusé');
    enCours.fenetre.close();
  });

  return { ouvrir: ouvrir, FORMATS: FORMATS, nomFichier: nomFichier };
}

module.exports = { creer: creer, nomFichier: nomFichier };
