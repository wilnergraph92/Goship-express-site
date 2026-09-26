/* ==========================================================================
   GoShip Express (bureau) — goship-app:// : les pages de l'application
   --------------------------------------------------------------------------
   Les deux pages locales (« Connexion impossible », « Imprimer ») et le
   document à imprimer ne passent pas par file:// : l'application construite
   retire ses privilèges à file:// (fuse GrantFileProtocolExtraPrivileges), et
   une page file:// pourrait lire d'autres fichiers du disque. Un protocole à
   soi ne sert que ce qu'on lui donne :
     goship-app://ui/<fichier>          le dossier ui/ de l'application, rien d'autre
     goship-app://document/<numéro>     un document à imprimer, gardé en mémoire
                                        le temps de la fenêtre « Imprimer » —
                                        jamais écrit sur le disque
   ========================================================================== */
'use strict';

var fs = require('fs');
var path = require('path');

var SCHEMA = 'goship-app';
var DOSSIER_UI = path.join(__dirname, '..', 'ui');
var TYPES = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.png': 'image/png' };
var documents = {};

// Avant « ready » : le schéma se comporte comme https (origine, CSP 'self')
function declarer(protocol) {
  protocol.registerSchemesAsPrivileged([{ scheme: SCHEMA, privileges: { standard: true, secure: true, supportFetchAPI: false, corsEnabled: false } }]);
}

function reponse(contenu, type, statut) {
  return new Response(contenu, { status: statut || 200, headers: { 'Content-Type': type || 'text/plain; charset=utf-8', 'X-Content-Type-Options': 'nosniff' } });
}

// quoi : 'ui' (fenêtre principale, fenêtre « Imprimer ») ou 'document' (rendu à imprimer)
function servir(quoi, requete) {
  var u = new URL(requete.url);
  if (u.hostname !== quoi) return reponse('', null, 404);
  if (u.hostname === 'ui') {
    var nom = decodeURIComponent(u.pathname.replace(/^\/+/, ''));
    if (!/^[\w.-]+$/.test(nom) || !TYPES[path.extname(nom)]) return reponse('', null, 404);
    try { return reponse(fs.readFileSync(path.join(DOSSIER_UI, nom)), TYPES[path.extname(nom)]); }
    catch (e) { return reponse('', null, 404); }
  }
  if (u.hostname === 'document') {
    var d = documents[u.pathname.replace(/^\/+/, '').replace(/\.html$/, '')];
    return d ? reponse(d, TYPES['.html']) : reponse('', null, 404);
  }
  return reponse('', null, 404);
}

function installer(ses, quoi) { ses.protocol.handle(SCHEMA, function (r) { return servir(quoi, r); }); }

function page(nom) { return SCHEMA + '://ui/' + nom; }

// Un document à imprimer → son adresse ; oublier() le retire de la mémoire
function ajouterDocument(html) {
  var id = Date.now().toString(36) + Math.random().toString(36).slice(2, 10);
  documents[id] = html;
  return { adresse: SCHEMA + '://document/' + id + '.html', oublier: function () { delete documents[id]; } };
}

function estPageLocale(adresse, nom) {
  var base = String(adresse || '').split(/[?#]/)[0];
  return nom ? base === page(nom) : base.indexOf(SCHEMA + '://ui/') === 0;
}

module.exports = { SCHEMA: SCHEMA, declarer: declarer, installer: installer, page: page, ajouterDocument: ajouterDocument, estPageLocale: estPageLocale };
