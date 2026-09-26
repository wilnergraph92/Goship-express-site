/* ==========================================================================
   Goship Express — les rôles et permissions du mode démonstration
   ==========================================================================
   Rejoue sur la copie démo (assets/js/api.js) les cas de essai-permissions.py :
   chaque rôle de l'équipe face aux actions, les refus faits aux clients, les
   changements de rôle. La démonstration doit refuser ce que la base refuse.

     node outils/essais-services/essai-permissions.js            les cas
     node outils/essais-services/essai-permissions.js --matrice  la matrice
          rôle → permissions, en JSON, pour essai-permissions.py
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

if (process.argv[2] === '--matrice') {
  fs.writeSync(1, JSON.stringify(API.regles.permissionsDesRoles));
  process.exit(0);
}

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
var EQUIPE = { admin: 'admin@goship.demo', gerant: 'gerant@goship.demo', employe: 'employe@goship.demo',
               client: 'marie-ange@exemple.com' };
function comme(role) {
  return API.deconnecter().then(function () { return API.connecter(EQUIPE[role], 'demo1234'); });
}

(async function () {
  var A = API.admin;
  await comme('admin');
  await A.exemples();
  var clients = (await A.clients({ parPage: 50 })).lignes;
  var marie = clients.filter(function (c) { return c.email === 'marie-ange@exemple.com'; })[0].id;
  var jean = clients.filter(function (c) { return c.email === 'jean-robert@exemple.com'; })[0].id;
  var base = { client_id: marie, description: 'Chaussures', poids_lb: 4, service: 'aerien', pays_destination: 'HT' };

  console.log('A. Qui a quoi');
  for (var role of ['admin', 'gerant', 'employe', 'client']) {
    await comme(role);
    var p = await API.permissions();
    verifier(role + ' : son rôle et ' + p.permissions.length + ' permissions, lus au même endroit',
             [p.role, p.equipe, p.permissions.length], [role, role !== 'client', API.regles.permissionsDesRoles[role].length]);
  }
  await API.deconnecter();
  verifier('personne de connecté : aucune permission', (await API.permissions()).permissions, []);

  console.log('\nB. Chaque rôle face aux actions');
  await comme('admin');
  var colisMarie = (await A.creerColis(Object.assign({}, base, { description: 'Pour la matrice' }))).colis;
  var factureMarie = (await A.factureDuColis(colisMarie.id)).id;
  var cas = [
    ['enregistrer un colis', function () { return A.creerColis(Object.assign({}, base)); }, ['aucune', 'aucune', 'aucune', REFUS]],
    ['… avec un tarif particulier', function () { return A.creerColis(Object.assign({}, base, { tarif_lb_usd: 2 })); },
     ['aucune', 'aucune', REFUS, REFUS]],
    ['scanner un code', function () { return A.scannerColis(colisMarie.numero); }, ['aucune', 'aucune', 'aucune', REFUS]],
    ['historique interne', function () { return A.historique(colisMarie.id); }, ['aucune', 'aucune', 'aucune', REFUS]],
    ['facturer un colis', function () { return A.facturerColis(colisMarie.id); }, ['aucune', 'aucune', REFUS, REFUS]],
    ['créer une facture', function () { return A.creerFacture({ client_id: jean, montant_usd: 3 }, []); },
     ['aucune', 'aucune', REFUS, REFUS]],
    ['modifier une facture', function () { return A.modifierFacture(factureMarie, { note: 'Merci' }); },
     ['aucune', 'aucune', REFUS, REFUS]],
    ['résumé de la facturation', function () { return A.resumeFacturation(); }, ['aucune', 'aucune', REFUS, REFUS]],
    ['rapport d\'anomalies', function () { return A.anomaliesFacturation(); }, ['aucune', 'aucune', REFUS, REFUS]],
    ['voir l\'équipe', function () { return A.equipe(); }, ['aucune', 'aucune', REFUS, REFUS]],
    ['journal d\'audit', function () { return A.journal(); }, ['aucune', REFUS, REFUS, REFUS]],
    ['supprimer un colis', function () { return A.supprimerColis('inconnu'); }, ['aucune', REFUS, REFUS, REFUS]],
    ['donner un rôle', function () { return A.changerRole('jean-robert@exemple.com', 'employe'); },
     ['aucune', REFUS, REFUS, REFUS]]
  ];
  // Le tarif d'un colis : une valeur différente par rôle, pour qu'il y ait vraiment un changement
  var tarifs = [];
  var k = 3;
  for (var rt of ['admin', 'gerant', 'employe', 'client']) {
    await comme(rt);
    tarifs.push(await code(A.modifierColis(colisMarie.id, { tarif_lb_usd: k++ })));
  }
  verifier('changer le tarif d\'un colis : admin / gérant / employé / client', tarifs, ['aucune', 'aucune', REFUS, REFUS]);
  for (var c of cas) {
    var obtenus = [];
    for (var r of ['admin', 'gerant', 'employe', 'client']) {
      await comme(r);
      obtenus.push(await code(c[1]()));
      if (r === 'admin' && c[0] === 'donner un rôle') await A.changerRole('jean-robert@exemple.com', 'client');
    }
    verifier(c[0] + ' : admin / gérant / employé / client', obtenus, c[2]);
  }

  console.log('\nC. Paiements et annulations : pas pour l\'employé');
  await comme('admin');
  var f2 = (await A.creerColis(Object.assign({}, base, { description: 'Paiements' }))).facture;
  for (var r2 of ['employe', 'client']) {
    await comme(r2);
    verifier(r2 + ' : encaisser, annuler une facture, regrouper',
             [await code(A.enregistrerPaiement(f2.id, { montant_usd: 1, moyen: 'especes' })),
              await code(A.annulerFacture(f2.id, 'x')), await code(A.regrouperFactures([f2.id, factureMarie]))],
             [REFUS, REFUS, REFUS]);
  }
  await comme('gerant');
  var pai = await A.enregistrerPaiement(f2.id, { montant_usd: 1, moyen: 'especes' });
  verifier('le gérant encaisse et annule un paiement',
           [pai.deja, (await A.annulerPaiement(pai.paiement.id, 'Erreur')).paiement.motif_annulation], [false, 'Erreur']);

  console.log('\nD. Le colis de l\'employé et son lien de paiement');
  await comme('employe');
  var fe = (await A.creerColis(Object.assign({}, base, { description: 'Employé' }))).facture;
  verifier('sa facture naît avec le colis', fe.montant_usd, 30);
  verifier('il pose le premier lien', await code(A.poserLienPaiement(fe.id, 'https://paypal.test/a')), 'aucune');
  verifier('… puis n\'y retouche plus', await code(A.poserLienPaiement(fe.id, 'https://paypal.test/b')), REFUS);
  verifier('un lien javascript: est refusé', await code(A.poserLienPaiement(fe.id, 'javascript:alert(1)')), 'INVALID_INPUT');
  var corr = await A.changerStatut([colisMarie.id], { statut: 'embarque', lieu: 'Miami' });
  verifier('il change un statut', corr.modifies, 1);
  verifier('mais ne corrige pas une étape (shipments.correct)',
           await code(A.changerStatut([colisMarie.id], { statut: 'recu' }, null, 'Erreur')), REFUS);

  console.log('\nE. Les rôles');
  await comme('admin');
  verifier('l\'administrateur ne change pas son propre rôle',
           await code(A.changerRole('admin@goship.demo', 'client')), 'SELF_ROLE_CHANGE');
  verifier('rôle inconnu', await code(A.changerRole('jean-robert@exemple.com', 'superadmin')), 'INVALID_ROLE');
  verifier('compte inconnu', await code(A.changerRole('personne@x.test', 'employe')), 'USER_NOT_FOUND');
  var promu = await A.changerRole('jean-robert@exemple.com', 'employe');
  verifier('nommer un employé', [promu.ancien_role, promu.nouveau_role], ['client', 'employe']);
  verifier('l\'équipe compte maintenant quatre personnes', (await A.equipe()).length, 4);
  verifier('le journal garde l\'ancien et le nouveau rôle',
           (await A.journal({ parPage: 500 })).lignes.filter(function (l) { return l.action === 'utilisateur.role'; })
             .map(function (l) { return l.avant.role + '→' + l.apres.role; }).slice(-1), ['client→employe']);
  await A.changerRole('jean-robert@exemple.com', 'client');
  verifier('redevenu client, il retrouve un code', /^GSE-\d{4,}$/.test((await A.clients({ parPage: 50 })).lignes
    .filter(function (c) { return c.email === 'jean-robert@exemple.com'; })[0].code), true);

  console.log('\nF. Le client : ses données, rien d\'autre');
  await comme('client');
  var mes = await API.mesColis();
  verifier('ses colis seulement', mes.every(function (x) { return x.client_id === undefined || x.client_id === marie; }) &&
           mes.length > 0, true);
  verifier('ses factures seulement', (await API.mesFactures()).length > 0, true);
  verifier('aucune liste interne : colis, clients, factures',
           [await code(A.colis({})), await code(A.clients({})), await code(A.factures({}))], [REFUS, REFUS, REFUS]);

  var n = resultats.filter(Boolean).length;
  console.log('\n' + resultats.length + ' vérifications, ' + n + ' réussies.');
  process.exit(n === resultats.length ? 0 : 1);
})().catch(function (e) { console.error(e); process.exit(2); });
