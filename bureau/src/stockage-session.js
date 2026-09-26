/* ==========================================================================
   GoShip Express (bureau) — la session, chiffrée par le système
   --------------------------------------------------------------------------
   Dans un navigateur, Supabase garde la session (jeton d'accès et jeton de
   renouvellement) dans le localStorage du site. Ici, api.js la confie à
   l'application, qui la chiffre avec le coffre du système avant de l'écrire :
     Windows  DPAPI (lié au compte Windows)
     macOS    Trousseau (Keychain)
   (safeStorage d'Electron). Le fichier session.bin est illisible ailleurs
   que sur ce compte, sur cet ordinateur.

   Jamais de mot de passe : Supabase ne garde que des jetons, et le mot de
   passe tapé ne sort pas du formulaire de connexion.

   Si le système n'offre pas de coffre (Linux sans trousseau), la session
   reste en mémoire : il faudra se reconnecter à chaque lancement, plutôt
   que d'écrire un jeton en clair sur le disque.
   ========================================================================== */
'use strict';

var fs = require('fs');
var path = require('path');
var journal = require('./journal');

var CLE_VALIDE = /^sb-[\w-]{1,80}$/;          // les clés qu'utilise supabase-js, rien d'autre
var TAILLE_MAX = 64 * 1024;

function creer(safeStorage, dossierDonnees) {
  var fichier = path.join(dossierDonnees, 'session.bin');
  var valeurs = null;
  var avertie = false;

  function coffreDisponible() {
    if (!safeStorage.isEncryptionAvailable()) return false;
    // Sous Linux, « basic_text » n'est qu'un brouillage : autant ne rien écrire
    if (process.platform === 'linux' && safeStorage.getSelectedStorageBackend &&
        safeStorage.getSelectedStorageBackend() === 'basic_text') return false;
    return true;
  }

  function lireTout() {
    if (valeurs) return valeurs;
    valeurs = {};
    if (!coffreDisponible() || !fs.existsSync(fichier)) return valeurs;
    try {
      var texte = safeStorage.decryptString(fs.readFileSync(fichier));
      var lu = JSON.parse(texte);
      if (lu && typeof lu === 'object') valeurs = lu;
    } catch (e) {
      // Fichier d'un autre compte, abîmé ou d'une autre machine : on repart de rien
      journal.alerte('session enregistrée illisible, reconnexion demandée');
      try { fs.unlinkSync(fichier); } catch (e2) { /* rien */ }
    }
    return valeurs;
  }

  function enregistrer() {
    if (!coffreDisponible()) {
      if (!avertie) journal.alerte('pas de coffre du système : la session reste en mémoire (reconnexion à chaque lancement)');
      avertie = true;
      return;
    }
    try {
      if (!Object.keys(valeurs).length) { if (fs.existsSync(fichier)) fs.unlinkSync(fichier); return; }
      fs.writeFileSync(fichier, safeStorage.encryptString(JSON.stringify(valeurs)), { mode: 0o600 });
    } catch (e) {
      journal.erreur('session non enregistrée : ' + e.message);
    }
  }

  function verifierCle(cle) {
    if (typeof cle !== 'string' || !CLE_VALIDE.test(cle)) throw new Error('clé de session refusée');
  }

  return {
    lire: function (cle) {
      verifierCle(cle);
      var v = lireTout()[cle];
      return typeof v === 'string' ? v : null;
    },
    ecrire: function (cle, valeur) {
      verifierCle(cle);
      if (typeof valeur !== 'string' || valeur.length > TAILLE_MAX) throw new Error('valeur de session refusée');
      lireTout()[cle] = valeur;
      enregistrer();
    },
    effacer: function (cle) {
      verifierCle(cle);
      delete lireTout()[cle];
      enregistrer();
    },
    chiffree: coffreDisponible
  };
}

module.exports = { creer: creer };
