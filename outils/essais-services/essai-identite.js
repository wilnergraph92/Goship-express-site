/* ==========================================================================
   Goship Express — le sexe et le document d'identité à l'inscription,
   mode démonstration, hors navigateur
   ==========================================================================
   Rejoue sur la copie démo (assets/js/api.js) les cas de essai-identite.py
   (outils/supabase-identite.sql) : les deux valeurs sont gardées, une valeur
   inconnue ne l'est pas et ne refuse pas l'inscription, l'équipe les lit, un
   client ou un visiteur ne les lit pas chez les autres.

     node outils/essais-services/essai-identite.js
   ========================================================================== */
'use strict';

var fs = require('fs');
var path = require('path');

var memoire = {};
global.window = { GOSHIP_CONFIG: {}, addEventListener: function () {} };
global.location = { protocol: 'file:', hostname: '', href: 'file:///site/admin.html', hash: '', search: '',
                    pathname: '/site/admin.html' };
global.document = { currentScript: null, documentElement: { lang: 'fr' }, querySelector: function () { return null; } };
global.localStorage = {
  getItem: function (k) { return Object.prototype.hasOwnProperty.call(memoire, k) ? memoire[k] : null; },
  setItem: function (k, v) { memoire[k] = String(v); },
  removeItem: function (k) { delete memoire[k]; }
};
global.history = { replaceState: function () {} };
var attendre = global.setTimeout;
global.setTimeout = function (f) { return setImmediate(f); };
new Function(fs.readFileSync(path.join(__dirname, '..', '..', 'assets', 'js', 'api.js'), 'utf8'))();
var API = global.window.GoshipAPI;
global.setTimeout = attendre;

var resultats = [];
function verifier(titre, obtenu, attendu) {
  var bon = JSON.stringify(obtenu) === JSON.stringify(attendu);
  var montre = JSON.stringify(obtenu);
  console.log('  ' + (bon ? 'OK  ' : 'RATÉ') + ' ' + (titre + ' '.repeat(62)).slice(0, 62) + ' ' +
              (montre.length > 60 ? montre.slice(0, 57) + '…' : montre));
  if (!bon) console.log('       attendu : ' + JSON.stringify(attendu));
  resultats.push(bon);
}
function code(p) { return p.then(function () { return 'aucune'; }, function (e) { return e.code; }); }
var REFUS = 'non-autorise';
var EQUIPE = { admin: 'admin@goship.demo', gerant: 'gerant@goship.demo', employe: 'employe@goship.demo' };
function comme(role) {
  return API.deconnecter().then(function () { return API.connecter(EQUIPE[role], 'demo1234'); });
}

function aujourdhui(decalage) {
  var t = new Date(Date.now() + (decalage || 0) * 864e5);
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Santo_Domingo', year: 'numeric', month: '2-digit', day: '2-digit' }).format(t);
}

var compteur = 0;
async function inscrire(extra) {
  compteur += 1;
  var r = await API.inscrire(Object.assign({ email: 'id' + compteur + '@exemple.com', motDePasse: 'secret12', nom_complet: 'Nadège Joseph ' + compteur,
    pays: 'HT', region: 'Ouest', ville: 'Port-au-Prince', adresse: 'Rue ' + compteur, telephone: '+509 3700 ' + (1000 + compteur),
    date_naissance: '1990-05-17' }, extra || {}));
  return r.profil;
}
function paire(p) { return (p.sexe || '-') + '|' + (p.type_document || '-'); }

(async function () {
  console.log('A. L\'inscription garde le sexe et le type de document');
  verifier('Masculin, Passeport', paire(await inscrire({ sexe: 'M', type_document: 'passeport' })), 'M|passeport');
  var marie = await inscrire({ sexe: 'F', type_document: 'cedula' });
  verifier('Féminin, Cédula', paire(marie), 'F|cedula');
  verifier('le client les voit dans son profil', [marie.sexe, marie.type_document], ['F', 'cedula']);

  console.log('\nB. Facultatifs : une inscription sans eux marche (application d\'avant)');
  verifier('sans sexe ni document : compte créé, rien d\'inventé', paire(await inscrire()), '-|-');
  verifier('seulement le sexe', paire(await inscrire({ sexe: 'F' })), 'F|-');
  verifier('seulement le document', paire(await inscrire({ type_document: 'cedula' })), '-|cedula');

  console.log('\nC. Une valeur inconnue n\'est pas gardée ; la date reste obligatoire');
  verifier('ni M/F ni passeport/cedula', paire(await inscrire({ sexe: 'X', type_document: 'permis' })), '-|-');
  verifier('valeurs vides', paire(await inscrire({ sexe: '', type_document: '' })), '-|-');
  verifier('texte piégé', paire(await inscrire({ sexe: '<b>M</b>', type_document: '\'; drop' })), '-|-');
  verifier('sans date de naissance : refusée, malgré un sexe et un document valides',
           await code(inscrireBrut({ date_naissance: '', sexe: 'M', type_document: 'passeport' })), 'naissance-requise');

  console.log('\nD. Qui les lit');
  await API.deconnecter();
  var clients = null;
  await comme('admin');
  clients = (await API.admin.clients({ parPage: 200 })).lignes;
  var cible = clients.filter(function (c) { return c.sexe === 'F' && c.type_document === 'cedula'; })[0];
  verifier('l\'administrateur lit le sexe et le document d\'un client', cible ? await API.admin.identiteClient(cible.id) : null, { sexe: 'F', type_document: 'cedula' });
  await comme('employe');
  verifier('un employé (clients.view) aussi', cible ? await API.admin.identiteClient(cible.id) : null, { sexe: 'F', type_document: 'cedula' });
  verifier('un identifiant inconnu : rien', await API.admin.identiteClient('personne'), { sexe: null, type_document: null });
  await API.deconnecter();
  verifier('un visiteur ne lit rien', await code(API.admin.identiteClient(cible.id)), REFUS);
  await inscrire();
  verifier('un client ne lit pas ceux d\'un autre', await code(API.admin.identiteClient(cible.id)), REFUS);

  console.log('\nE. Le numéro du passeport ou de la cédula');
  async function numeroDe(extra) {
    var p = await inscrire(extra);
    var id = p.id;
    await API.deconnecter();
    await comme('admin');
    var n = await API.admin.numeroDocument(id);
    await API.deconnecter();
    return { id: id, numero: n };
  }
  verifier('passeport : espaces et tirets retirés, majuscules', (await numeroDe({ sexe: 'M', type_document: 'passeport', numero_document: 'ab 1234-567' })).numero, 'AB1234567');
  verifier('cédula : 001-1234567-8 devient 00112345678', (await numeroDe({ type_document: 'cedula', numero_document: '001-1234567-8' })).numero, '00112345678');
  verifier('passeport trop court : pas gardé', (await numeroDe({ type_document: 'passeport', numero_document: 'AB12' })).numero, null);
  verifier('cédula avec des lettres : pas gardée', (await numeroDe({ type_document: 'cedula', numero_document: '12AB567' })).numero, null);
  verifier('un numéro sans type de document : pas gardé', (await numeroDe({ numero_document: 'AB1234567' })).numero, null);
  verifier('texte piégé : pas gardé', (await numeroDe({ type_document: 'passeport', numero_document: '<b>x</b>' })).numero, null);
  var avecNumero = await numeroDe({ type_document: 'passeport', numero_document: 'PA1234567' });
  verifier('le profil du client ne montre jamais le numéro',
           JSON.stringify((await (async function () { await API.connecter('id1@exemple.com', 'secret12').catch(function () {}); return API.profil(); })()) || {}).indexOf('PA1234567'), -1);
  await API.deconnecter();
  await comme('gerant');
  verifier('le gérant (clients.edit) lit le numéro', await API.admin.numeroDocument(avecNumero.id), 'PA1234567');
  await comme('employe');
  verifier('un employé (sans clients.edit) est refusé', await code(API.admin.numeroDocument(avecNumero.id)), REFUS);
  await API.deconnecter();
  verifier('un visiteur est refusé', await code(API.admin.numeroDocument(avecNumero.id)), REFUS);
  await inscrire();
  verifier('un client est refusé', await code(API.admin.numeroDocument(avecNumero.id)), REFUS);

  var reussis = resultats.filter(Boolean).length;
  console.log('\n' + resultats.length + ' vérifications, ' + reussis + ' réussies.');
  process.exit(reussis === resultats.length ? 0 : 1);
})().catch(function (e) { console.error(e); process.exit(2); });
function inscrireBrut(extra) {
  compteur += 1;
  return API.inscrire(Object.assign({ email: 'brut' + compteur + '@exemple.com', motDePasse: 'secret12', nom_complet: 'Sans Date', pays: 'HT',
    region: 'Ouest', ville: 'Port-au-Prince', adresse: 'Rue 1', telephone: '+509 3700 2000' }, extra));
}
