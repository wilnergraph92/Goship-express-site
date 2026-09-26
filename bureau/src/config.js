/* ==========================================================================
   GoShip Express (bureau) — l'environnement : quel site charger
   --------------------------------------------------------------------------
   L'application n'a pas de copie du tableau de bord : elle ouvre celui du
   site, celui que l'équipe utilise déjà dans son navigateur. Même code, mêmes
   permissions, même base ; une mise en ligne du site met aussi à jour ce que
   montre l'application.

   config/environnements.json donne une adresse par environnement ; rien
   d'autre. Aucun secret : la clé Supabase est la clé publique du site, et
   c'est la base qui décide de tout (règles RLS, permissions).

   L'environnement se choisit par l'argument --env=local ou la variable
   GOSHIP_ENV (développement, essais) ; sans eux, « production ». Seuls les
   noms du fichier sont acceptés : on ne peut pas faire charger une adresse
   quelconque.
   ========================================================================== */
'use strict';

var fs = require('fs');
var path = require('path');

var FICHIER = path.join(__dirname, '..', 'config', 'environnements.json');

// Une adresse de site acceptable : https, ou http seulement sur cet ordinateur
function verifierSite(texte) {
  var u;
  try { u = new URL(texte); } catch (e) { throw new Error('adresse de site illisible : ' + texte); }
  var local = u.hostname === 'localhost' || u.hostname === '127.0.0.1';
  if (u.protocol !== 'https:' && !(u.protocol === 'http:' && local)) {
    throw new Error('le site doit être en https (ou http sur cet ordinateur) : ' + texte);
  }
  if (u.search || u.hash || u.username || u.password) throw new Error('adresse de site trop précise : ' + texte);
  if (!/\/$/.test(u.pathname)) u.pathname += '/';
  return u;
}

function charger() {
  var tous = JSON.parse(fs.readFileSync(FICHIER, 'utf8'));
  var argument = process.argv.filter(function (a) { return /^--env=/.test(a); })[0];
  var nom = (argument && argument.slice(6)) || process.env.GOSHIP_ENV || 'production';
  if (nom.charAt(0) === '_' || !Object.prototype.hasOwnProperty.call(tous, nom)) {
    throw new Error('environnement inconnu : « ' + nom + ' » (voir config/environnements.json)');
  }
  var site = verifierSite(tous[nom].site);
  return {
    nom: nom,
    site: site.href,                                   // https://…/Goship-express-site/
    origine: site.origin,                              // https://…
    tableau: new URL('admin.html', site).href,         // la page que l'application ouvre
    // Une adresse est « du site » si elle a la même origine et le même dossier
    estDuSite: function (adresse) {
      try {
        var u = new URL(adresse);
        return u.origin === site.origin && u.pathname.indexOf(site.pathname) === 0;
      } catch (e) { return false; }
    }
  };
}

module.exports = { charger: charger, verifierSite: verifierSite };
