/* ==========================================================================
   Goship Express — les Analytics du mode démonstration, hors navigateur
   ==========================================================================
   Rejoue sur la copie démo (assets/js/api.js) les cas de essai-analytics.py :
   permissions, périodes et période précédente, jeu contrôlé, délais tirés
   des événements, facturé et encaissé, tarif historique, cohérence avec la
   vue générale, jamais de NaN ni d'Infinity.

     node outils/essais-services/essai-analytics.js             les cas
     node outils/essais-services/essai-analytics.js --formes    la forme (clés)
          de chaque module, pour essai-analytics.py
     node outils/essais-services/essai-analytics.js --periodes  les jours de
          chaque période et de sa précédente, aujourd'hui
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
// Les réponses de la démonstration arrivent après un petit délai ; ici, tout de suite.
global.setTimeout = function (f) { return setImmediate(f); };
new Function(fs.readFileSync(path.join(__dirname, '..', '..', 'assets', 'js', 'api.js'), 'utf8'))();
var API = global.window.GoshipAPI;
var A = API.admin;
var CLE = 'gse-demo-donnees';
var MODULES = ['synthese', 'serie', 'operations', 'clients', 'finances', 'routes', 'scanner', 'qualite'];

var silencieux = process.argv[2] === '--formes' || process.argv[2] === '--periodes';
if (silencieux) console.log = function () {};
var resultats = [];
function verifier(titre, obtenu, attendu) {
  var bon = JSON.stringify(obtenu) === JSON.stringify(attendu);
  var montre = JSON.stringify(obtenu);
  console.log('  ' + (bon ? 'OK  ' : 'RATÉ') + ' ' + (titre + ' '.repeat(62)).slice(0, 62) + ' ' +
              (montre && montre.length > 60 ? montre.slice(0, 57) + '…' : montre));
  if (!bon) console.log('       attendu : ' + JSON.stringify(attendu));
  resultats.push(bon);
}
function code(p) { return p.then(function () { return 'aucune'; }, function (e) { return e.code; }); }
var EQUIPE = { admin: 'admin@goship.demo', gerant: 'gerant@goship.demo', employe: 'employe@goship.demo',
               client: 'marie-ange@exemple.com' };
function comme(qui) { return API.deconnecter().then(function () { return API.connecter(EQUIPE[qui], 'demo1234'); }); }
function retoucher(f) {
  var d = JSON.parse(memoire[CLE]);
  f(d);
  memoire[CLE] = JSON.stringify(d);
}
// Un instant de Santo Domingo (UTC−4 toute l'année)
function sd(texte) { return new Date(texte.replace(' ', 'T') + ':00-04:00').toISOString(); }
function douteux(v, chemin) {
  chemin = chemin || '';
  if (v && typeof v === 'object') {
    return Object.keys(v).reduce(function (t, k) { return t.concat(douteux(v[k], chemin + '.' + k)); }, []);
  }
  if (typeof v === 'number' && !isFinite(v)) return [chemin];
  if (v === undefined) return [chemin];
  return [];
}
function cles(v, chemin) {
  chemin = chemin || '';
  if (v && typeof v === 'object' && !Array.isArray(v)) {
    var sortie = [];
    Object.keys(v).sort().forEach(function (k) {
      sortie.push(chemin + k);
      sortie = sortie.concat(cles(v[k], chemin + k + '.'));
    });
    return sortie;
  }
  if (Array.isArray(v) && v.length) return cles(v[0], chemin + '[].');
  return [];
}

(async function () {
  if (process.argv[2] === '--periodes') {
    await comme('admin');
    var sortie = {};
    for (var p of ['aujourdhui', '7j', '30j', 'mois', 'mois_precedent', '3m', '6m', '12m', 'annee']) {
      var s0 = await A.analytics('synthese', { periode: p });
      sortie[p] = [s0.periode.debut, s0.periode.fin, s0.periode.precedente.debut, s0.periode.precedente.fin];
    }
    fs.writeSync(1, JSON.stringify(sortie));
    process.exit(0);
  }

  await comme('admin');
  await A.exemples();
  var clients = {};
  (await A.clients({ parPage: 50 })).lignes.forEach(function (c) { clients[c.email] = c; });
  var marie = clients['marie-ange@exemple.com'], jean = clients['jean-robert@exemple.com'];
  var caro = clients['carolina@exemple.com'];

  if (process.argv[2] === '--formes') {
    // De quoi remplir chaque liste : un scan, une facture annulée (anomalie « colis sans facture »)
    var c0 = (await A.colis({ statut: 'recu' })).lignes[0];
    await A.operationScanner(c0.numero, 'COLIS_INSPECTE', { lieu: 'Miami (Medley), FL' });
    var f0 = await A.factureDuColis(c0.id);
    if (f0 && !(f0.paye_usd > 0)) await A.annulerFacture(f0.id, 'Essai de forme');
    var formes = {};
    for (var m of MODULES) formes[m] = cles(await A.analytics(m, { periode: '30j' }));
    fs.writeSync(1, JSON.stringify(formes));
    process.exit(0);
  }

  console.log('A. Permissions : reports.view');
  for (var qui of ['admin', 'gerant', 'employe', 'client']) {
    await comme(qui);
    var codes = [];
    for (var mm of MODULES) codes.push(await code(A.analytics(mm, { periode: '30j' })));
    var attendu = qui === 'admin' || qui === 'gerant' ? 'aucune' : 'non-autorise';
    verifier(qui + ' : les huit modules → ' + attendu, codes, MODULES.map(function () { return attendu; }));
  }
  await API.deconnecter();
  verifier('visiteur : refusé', await code(A.analytics('synthese', {})), 'non-autorise');
  await comme('admin');
  verifier('module inconnu : refusé', await code(A.analytics('ventes', {})), 'INVALID_INPUT');

  console.log('\nB. Périodes et période précédente');
  var s = await A.analytics('synthese', { periode: '7j' });
  verifier('7 jours ↔ les 7 d\'avant', [s.periode.jours, s.periode.precedente.fin < s.periode.debut], [7, true]);
  s = await A.analytics('synthese', { periode: 'personnalise', debut: '2026-03-10', fin: '2026-03-20' });
  verifier('10/03 → 20/03 ↔ 27/02 → 09/03', [s.periode.precedente.debut, s.periode.precedente.fin], ['2026-02-27', '2026-03-09']);
  s = await A.analytics('synthese', { periode: 'personnalise', debut: '2024-03-31', fin: '2024-03-31' });
  verifier('un seul jour ↔ la veille', [s.periode.precedente.debut, s.periode.precedente.fin], ['2024-03-30', '2024-03-30']);
  verifier('plus de trois ans : refusé', await code(A.analytics('synthese', { periode: 'personnalise', debut: '2020-01-01', fin: '2026-01-01' })),
           'INVALID_PERIOD');
  verifier('découpage inconnu : refusé', await code(A.analytics('serie', { periode: '7j', granularite: 'heure' })), 'INVALID_INPUT');

  console.log('\nC. Un jeu contrôlé en mars 2026');
  var ids = [];
  for (var k = 0; k < 4; k++) {
    var c = (await A.creerColis({ client_id: marie.id, description: 'Mars ' + k, poids_lb: 4, service: 'aerien', pays_destination: 'HT' })).colis;
    ids.push(c.id);
  }
  for (var e of ['embarque', 'distribution', 'succursale', 'disponible', 'livre']) {
    await A.changerStatut([ids[0]], { statut: e, lieu: e === 'disponible' ? 'Pétion-Ville' : 'Miami' });
  }
  await A.changerStatut([ids[1]], { statut: 'embarque', lieu: 'Miami' });
  var quand = { recu: '2026-03-02 08:00', embarque: '2026-03-03 08:00', distribution: '2026-03-04 08:00',
                succursale: '2026-03-04 20:00', disponible: '2026-03-05 08:00', livre: '2026-03-06 08:00' };
  retoucher(function (d) {
    d.colis.forEach(function (c) { if (ids.indexOf(c.id) >= 0) c.recu_le = sd(quand.recu); });
    d.historique.forEach(function (h) {
      if (ids.indexOf(h.colis_id) >= 0) h.cree_le = sd(h.statut_precedent == null ? quand.recu : quand[h.statut]);
    });
    d.factures.forEach(function (f) {
      if ((f.facture_lignes || []).some(function (l) { return ids.indexOf(l.colis_id) >= 0; })) f.cree_le = sd('2026-03-02 09:00');
    });
  });
  var MARS = { periode: 'personnalise', debut: '2026-03-01', fin: '2026-03-31' };
  s = await A.analytics('synthese', MARS);
  verifier('4 reçus, 2 embarqués, 1 disponible, 1 livré',
           [s.mesures.recus.actuel, s.mesures.expedies.actuel, s.mesures.disponibles.actuel, s.mesures.livres.actuel], [4, 2, 1, 1]);
  verifier('février vide : pas de pourcentage', [s.mesures.recus.precedent, s.mesures.recus.variation_pct], [0, null]);
  verifier('facturé : 4 factures de 30 $', [s.mesures.factures_emises.actuel, s.mesures.facture.actuel], [4, 120]);
  var o = await A.analytics('operations', MARS);
  verifier('Reçu → Embarqué : 2 colis, 24 h', [o.durees.reception_expedition.nombre, o.durees.reception_expedition.mediane_h], [2, 24]);
  verifier('Embarqué → Disponible 48 h, Disponible → Livré 24 h, total 96 h',
           [o.durees.expedition_disponible.moyenne_h, o.durees.disponible_livraison.moyenne_h, o.durees.reception_livraison.maximum_h],
           [48, 24, 96]);
  var tr = {};
  o.transitions.forEach(function (t) { tr[t.de + '>' + t.vers] = t; });
  verifier('Succursale → Disponible : 12 h', tr['succursale>disponible'].moyenne_h, 12);
  verifier('cohorte : 4 reçus, 1 livré, 25 %', [o.livraison.cohorte_recus, o.livraison.cohorte_livres, o.livraison.taux_cohorte], [4, 1, 25]);

  console.log('\nD. Facturé, encaissé, solde ; tarif historique');
  var fa = (await A.creerFacture({ client_id: caro.id, montant_usd: 75 }, [])).facture;
  retoucher(function (d) { d.factures.forEach(function (f) { if (f.id === fa.id) f.cree_le = sd('2026-03-15 10:00'); }); });
  await A.enregistrerPaiement(fa.id, { montant_usd: 25, moyen: 'especes', paye_le: sd('2026-03-16 10:00') });
  var fi = await A.analytics('finances', MARS);
  verifier('75 payée 25 : facturé + 75, encaissé 25, reste + 50', [fi.facture.actuel - 120, fi.encaisse.actuel, fi.reste.actuel - 120], [75, 25, 50]);
  await A.enregistrerPaiement(fa.id, { montant_usd: 50, moyen: 'moncash', paye_le: sd('2026-03-20 10:00') });
  fi = await A.analytics('finances', MARS);
  verifier('… puis 50 : encaissé 75, reste + 0', [fi.encaisse.actuel, fi.reste.actuel - 120], [75, 0]);
  var v = await A.vueGenerale({});
  verifier('créances maintenant = « à encaisser » de la vue générale', fi.creances.total, v.facturation.a_encaisser);
  var se = await A.analytics('serie', Object.assign({ granularite: 'jour' }, MARS));
  var parJour = {};
  se.cases.forEach(function (c) { parJour[c.jour] = c; });
  verifier('série : 31 jours ; dû fin 15 − dû fin 16 = 25', [se.cases.length,
           Math.round((parJour['2026-03-15'].creances_fin - parJour['2026-03-16'].creances_fin) * 100) / 100], [31, 25]);
  verifier('série : la somme des jours = les totaux', [se.cases.reduce(function (t, c) { return t + c.recus; }, 0),
           se.cases.reduce(function (t, c) { return t + c.encaisse; }, 0)], [4, 75]);
  var sem = await A.analytics('serie', Object.assign({ granularite: 'semaine' }, MARS));
  verifier('par semaine : case du lundi 23 février, commencée le 1er mars', [sem.cases[0].jour, sem.cases[0].debut], ['2026-02-23', '2026-03-01']);
  var ancien = await A.creerColis({ client_id: jean.id, description: 'Ancien tarif', poids_lb: 10, tarif_lb_usd: 3, service: 'aerien', pays_destination: 'HT' });
  var avant = (await A.analytics('finances', { periode: '7j' })).facture.actuel;
  await A.modifierColis(ancien.colis.id, { tarif_lb_usd: 4 });
  verifier('tarif changé après coup : la facture (40 $) et le facturé ne bougent pas',
           [(await A.factureDuColis(ancien.colis.id)).montant_usd, (await A.analytics('finances', { periode: '7j' })).facture.actuel], [40, avant]);
  verifier('dépenses, dettes, résultat : non suivis', [fi.depenses, fi.dettes, fi.resultat], [{ suivi: false }, { suivi: false }, { suivi: false }]);

  console.log('\nE. Cohérence avec la vue générale, et jamais de NaN');
  s = await A.analytics('synthese', { periode: '30j' });
  v = await A.vueGenerale({ periode: '30j' });
  verifier('30 jours : reçus, livrés, facturé, encaissé identiques',
           [s.mesures.recus.actuel, s.mesures.livres.actuel, s.mesures.facture.actuel, s.mesures.encaisse.actuel],
           [v.colis.recus_periode, v.colis.livres_periode, v.facturation.facture_periode, v.facturation.encaisse_periode]);
  verifier('les huit statuts de maintenant', s.maintenant.statuts, v.colis.statuts);
  for (var m2 of MODULES) {
    for (var per of ['aujourdhui', '30j', '12m']) {
      verifier(m2 + ' (' + per + ') : aucun NaN, Infinity ni undefined', douteux(await A.analytics(m2, { periode: per })), []);
    }
  }
  var cl = await A.analytics('clients', { periode: '12m', tri: 'solde' });
  var soldes = cl.lignes.map(function (x) { return x.solde; });
  verifier('clients triés par solde', soldes, soldes.slice().sort(function (a, b) { return b - a; }));
  verifier('segments : chaque client actif une fois', cl.segments.reduce(function (t, x) { return t + x.clients; }, 0), cl.actifs.actuel);
  var c0 = (await A.colis({ statut: 'recu' })).lignes[0];
  await comme('gerant');
  await A.operationScanner(c0.numero, 'COLIS_INSPECTE', { lieu: 'Miami (Medley), FL' });
  await comme('admin');
  var sc = await A.analytics('scanner', { periode: 'aujourdhui' });
  verifier('scanner : 1 opération, par compte alphabétique, échecs non suivis',
           [sc.total.actuel, sc.par_compte.map(function (x) { return x.nom; }).slice().sort().join() === sc.par_compte.map(function (x) { return x.nom; }).join(),
            sc.echecs_suivis], [1, true, false]);
  var ro = await A.analytics('routes', { periode: '30j' });
  verifier('routes : une seule origine, Miami', [ro.origine, ro.origines_distinctes], ['Miami (Medley), FL', 1]);

  var nb = resultats.filter(Boolean).length;
  console.log('\n' + resultats.length + ' vérifications, ' + nb + ' réussies.');
  process.exit(nb === resultats.length ? 0 : 1);
})().catch(function (e) { console.error(e); process.exit(2); });
