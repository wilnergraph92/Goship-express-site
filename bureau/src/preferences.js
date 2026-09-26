/* ==========================================================================
   GoShip Express (bureau) — les préférences de ce poste
   --------------------------------------------------------------------------
   Rien de sensible, rien de métier : la taille de la fenêtre et l'imprimante
   choisie pour chaque format (étiquette 4×6, A4). preferences.json, dans le
   dossier de l'application ; le désinstaller ou l'effacer ne change aucune
   donnée de GoShip Express, qui vivent toutes dans la base.
   ========================================================================== */
'use strict';

var fs = require('fs');
var path = require('path');

function creer(dossierDonnees) {
  var fichier = path.join(dossierDonnees, 'preferences.json');
  var valeurs = {};
  try { valeurs = JSON.parse(fs.readFileSync(fichier, 'utf8')) || {}; } catch (e) { valeurs = {}; }

  function enregistrer() {
    try { fs.writeFileSync(fichier, JSON.stringify(valeurs, null, 2)); } catch (e) { /* tant pis : ce n'est qu'une commodité */ }
  }

  return {
    lire: function (cle, defaut) {
      return Object.prototype.hasOwnProperty.call(valeurs, cle) ? valeurs[cle] : defaut;
    },
    ecrire: function (cle, valeur) {
      valeurs[cle] = valeur;
      enregistrer();
    }
  };
}

module.exports = { creer: creer };
