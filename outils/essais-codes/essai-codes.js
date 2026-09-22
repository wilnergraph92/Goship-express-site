/* ==========================================================================
   Goship Express — le calcul des codes, sorti de la page
   ==========================================================================
   Charge assets/js/codes.js hors du navigateur et écrit ce qu'il calcule en
   JSON. C'est essai-codes.py qui compare ensuite à deux bibliothèques de
   référence. Rien à lancer ici directement : voir LISEZ-MOI.md.
   ========================================================================== */
'use strict';

var fs = require('fs');
var path = require('path');

// Un navigateur minuscule : juste ce que codes.js demande pour dessiner un SVG
function Noeud(nom) {
  this.nom = nom;
  this.attributs = {};
  this.enfants = [];
  this.textContent = '';
}
Noeud.prototype.setAttribute = function (k, v) { this.attributs[k] = v; };
Noeud.prototype.appendChild = function (n) { this.enfants.push(n); return n; };

global.window = {};
global.document = { createElementNS: function (espace, nom) { return new Noeud(nom); } };

var fichier = path.join(__dirname, '..', '..', 'assets', 'js', 'codes.js');
new Function(fs.readFileSync(fichier, 'utf8'))();
var C = global.window.GoshipCodes;

var entree = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
var sortie = { qr: [], codebarre: [], svg: {}, erreurs: {} };

entree.qr.forEach(function (texte) {
  var cas = { texte: texte, masques: {} };
  for (var masque = 0; masque < 8; masque++) {
    cas.masques[masque] = C.qrModules(texte, { masque: masque }).map(function (ligne) {
      return ligne.map(function (c) { return c ? '#' : '.'; }).join('');
    });
  }
  cas.auto = C.qrModules(texte).map(function (ligne) {
    return ligne.map(function (c) { return c ? '#' : '.'; }).join('');
  });
  sortie.qr.push(cas);
});

entree.codebarre.forEach(function (texte) {
  // Largeurs alternées barre/espace, converties en modules 1 et 0
  var modules = '';
  C.code128Modules(texte).forEach(function (largeur, i) {
    modules += new Array(largeur + 1).join(i % 2 === 0 ? '1' : '0');
  });
  sortie.codebarre.push({ texte: texte, modules: modules });
});

// Textes que les deux fonctions doivent refuser
entree.refus.forEach(function (cas) {
  try {
    if (cas.quoi === 'qr') C.qrModules(cas.texte); else C.code128Modules(cas.texte);
    sortie.erreurs[cas.nom] = null;
  } catch (e) {
    sortie.erreurs[cas.nom] = e.message;
  }
});

// Un SVG complet, pour vérifier le dessin et pas seulement le calcul
function decrire(svg) {
  return {
    nom: svg.nom,
    viewBox: svg.attributs.viewBox,
    enfants: svg.enfants.map(function (n) { return n.nom; }),
    remplissages: svg.enfants.map(function (n) { return n.attributs.fill || ''; }),
    titre: svg.enfants.filter(function (n) { return n.nom === 'title'; })
      .map(function (n) { return n.textContent; })[0] || '',
    chemin: svg.enfants.filter(function (n) { return n.nom === 'path'; })
      .map(function (n) { return n.attributs.d; })[0] || ''
  };
}
sortie.svg.qr = decrire(C.qr('GSE-1001-DO', { titre: 'Suivi du colis GSE-1001-DO' }));
sortie.svg.qr.modules = C.qrModules('GSE-1001-DO').map(function (ligne) {
  return ligne.map(function (c) { return c ? '#' : '.'; }).join('');
});
sortie.svg.codebarre = decrire(C.code128('GSE-1001-DO', { hauteur: 30 }));

process.stdout.write(JSON.stringify(sortie));
