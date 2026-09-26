/* ==========================================================================
   GoShip Express (bureau) — le journal de l'application
   --------------------------------------------------------------------------
   Un fichier texte sur cet ordinateur, pour comprendre une panne : démarrage,
   page qui ne charge pas, impression refusée, navigation bloquée, erreur de
   la page. Il ne part nulle part : aucune télémétrie, rien n'est envoyé.

   Ce qui n'y entre jamais : mots de passe, jetons de session, clés, adresses
   complètes (les paramètres d'une adresse peuvent porter un jeton), montants.
   Tout texte passe par nettoyer() avant d'être écrit.

   Emplacement (menu Aide > Ouvrir le dossier des journaux) :
     Windows  %APPDATA%\GoShip Express\journaux\bureau.log
     macOS    ~/Library/Application Support/GoShip Express/journaux/bureau.log
   Au-delà d'1 Mo, le fichier devient bureau.1.log et un nouveau commence.
   ========================================================================== */
'use strict';

var fs = require('fs');
var path = require('path');

var TAILLE_MAX = 1024 * 1024;
var dossier = null;

// Le texte d'une ligne, sans rien de sensible
function nettoyer(texte) {
  return String(texte == null ? '' : texte)
    // jetons JWT (session Supabase) et clés longues
    .replace(/eyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]{8,}/g, '[jeton]')
    .replace(/\b(sb_(?:publishable|secret)_[\w-]+|service_role[\w-]*)/gi, '[clé]')
    // paramètres qui portent un secret, dans une adresse ou un texte
    .replace(/((?:access|refresh|provider)_token|apikey|api_key|token|password|mot_de_passe|motdepasse)(["']?\s*[=:]\s*["']?)[^&\s"',}]+/gi, '$1$2[masqué]')
    // une adresse : son origine et son chemin, jamais ses paramètres
    .replace(/\b(https?:\/\/[^\s?#"']+)[?#][^\s"']*/g, '$1?…')
    .replace(/[\r\n]+/g, ' ')
    .slice(0, 800);
}

function initialiser(dossierDonnees) {
  dossier = path.join(dossierDonnees, 'journaux');
  try { fs.mkdirSync(dossier, { recursive: true }); } catch (e) { dossier = null; }
}

function fichier() { return dossier ? path.join(dossier, 'bureau.log') : null; }

function ecrire(niveau, texte) {
  var ligne = new Date().toISOString() + ' ' + niveau.toUpperCase() + ' ' + nettoyer(texte) + '\n';
  if (process.env.GOSHIP_JOURNAL_CONSOLE) process.stdout.write(ligne);
  var f = fichier();
  if (!f) return;
  try {
    if (fs.existsSync(f) && fs.statSync(f).size > TAILLE_MAX) fs.renameSync(f, path.join(dossier, 'bureau.1.log'));
    fs.appendFileSync(f, ligne);
  } catch (e) { /* un journal qui ne s'écrit pas ne doit jamais arrêter l'application */ }
}

module.exports = {
  initialiser: initialiser,
  nettoyer: nettoyer,
  dossier: function () { return dossier; },
  fichier: fichier,
  info: function (t) { ecrire('info', t); },
  alerte: function (t) { ecrire('alerte', t); },
  erreur: function (t) { ecrire('erreur', t); }
};
