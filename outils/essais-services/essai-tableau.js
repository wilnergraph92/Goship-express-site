/* ==========================================================================
   Goship Express — le tableau de bord du mode démonstration, hors navigateur
   ==========================================================================
   Rejoue sur la copie démo (assets/js/api.js) les cas de essai-tableau.py :
   chaque rôle sa part, des zéros sur une base vide, facturé = payé + solde,
   un scan visible aussitôt, des périodes en jours de Santo Domingo, une
   recherche qui ne liste jamais tout.

     node outils/essais-services/essai-tableau.js             les cas
     node outils/essais-services/essai-tableau.js --formes    la forme (clés) de
          chaque réponse, pour essai-tableau.py : la page doit recevoir la même
          chose en démonstration et en ligne
     node outils/essais-services/essai-tableau.js --periodes  les jours de
          chaque période nommée, aujourd'hui
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
// Les réponses de la démonstration arrivent après un petit délai, pour imiter
// le réseau ; ici, tout de suite.
global.setTimeout = function (f) { return setImmediate(f); };
new Function(fs.readFileSync(path.join(__dirname, '..', '..', 'assets', 'js', 'api.js'), 'utf8'))();
var API = global.window.GoshipAPI;
var A = API.admin;
var CLE = 'gse-demo-donnees';

var resultats = [];
function verifier(titre, obtenu, attendu) {
  var bon = JSON.stringify(obtenu) === JSON.stringify(attendu);
  var montre = JSON.stringify(obtenu);
  if (!sortieSilencieuse) {
    console.log('  ' + (bon ? 'OK  ' : 'RATÉ') + ' ' + (titre + ' '.repeat(62)).slice(0, 62) + ' ' +
                (montre.length > 60 ? montre.slice(0, 57) + '…' : montre));
    if (!bon) console.log('       attendu : ' + JSON.stringify(attendu));
  }
  resultats.push(bon);
}
var sortieSilencieuse = process.argv[2] === '--formes' || process.argv[2] === '--periodes';
// Ces deux modes ne rendent que du JSON : les titres des cas se taisent
if (sortieSilencieuse) console.log = function () {};
function code(p) { return p.then(function () { return 'aucune'; }, function (e) { return e.code; }); }
var EQUIPE = { admin: 'admin@goship.demo', gerant: 'gerant@goship.demo', employe: 'employe@goship.demo',
               client: 'marie-ange@exemple.com', carolina: 'carolina@exemple.com' };
function comme(qui) {
  return API.deconnecter().then(function () { return API.connecter(EQUIPE[qui], 'demo1234'); });
}
// Retoucher les données de la démonstration comme le temps le ferait
function retoucher(f) {
  var d = JSON.parse(memoire[CLE]);
  f(d);
  memoire[CLE] = JSON.stringify(d);
}
function r2(n) { return Math.round(n * 100) / 100; }

// La forme d'une réponse, comme cles() dans essai-tableau.py
function cles(v, chemin) {
  chemin = chemin || '';
  if (v && typeof v === 'object' && !Array.isArray(v)) {
    var sortie = [];
    Object.keys(v).sort().forEach(function (k) {
      sortie.push(chemin + k);
      if (k === 'metadonnees' || (k === 'statuts' && chemin.indexOf('[]') >= 0)) return;
      sortie = sortie.concat(cles(v[k], chemin + k + '.'));
    });
    return sortie;
  }
  if (Array.isArray(v) && v.length) return cles(v[0], chemin + '[].');
  return [];
}

(async function () {
  if (process.argv[2] === '--periodes') {
    var sortie = {};
    for (var p of ['aujourdhui', '7j', '30j', 'mois', 'mois_precedent', 'annee']) {
      await comme('admin');
      var v = await A.vueGenerale({ periode: p });
      sortie[p] = [v.periode.debut, v.periode.fin];
    }
    fs.writeSync(1, JSON.stringify(sortie));
    process.exit(0);
  }

  console.log('A. Une démonstration vide : des zéros');
  await comme('admin');
  var v0 = await A.vueGenerale({});
  verifier('toutes les parties pour l\'administrateur', Object.keys(v0).sort(),
           ['activite', 'alertes', 'clients', 'colis', 'facturation', 'genere_le', 'jours_sans_mouvement',
            'paiements_recents', 'periode', 'scanner']);
  verifier('0 colis, 0 facturé, aucune alerte', [v0.colis.total, v0.facturation.facture_periode, v0.alertes], [0, 0, []]);
  verifier('30 jours dans la courbe', v0.colis.par_jour.length, 30);
  verifier('les scans échoués ne sont pas suivis', v0.scanner.echecs_suivis, false);

  await A.exemples();
  var clients = {};
  (await A.clients({ parPage: 50 })).lignes.forEach(function (c) { clients[c.email] = c; });
  var marie = clients['marie-ange@exemple.com'], jean = clients['jean-robert@exemple.com'];
  var caro = clients['carolina@exemple.com'];
  var base = { client_id: marie.id, description: 'Chaussures', poids_lb: 4, service: 'aerien', pays_destination: 'HT' };
  var c1 = (await A.creerColis(Object.assign({}, base, { suivi_transporteur: 'ESSAI7TABLEAU77' }))).colis;

  console.log('\nB. Chaque rôle, sa part');
  var parties = {};
  for (var role of ['admin', 'gerant', 'employe']) {
    await comme(role);
    parties[role] = Object.keys(await A.vueGenerale({})).sort().join(',');
  }
  verifier('gérant = administrateur', parties.gerant, parties.admin);
  verifier('employée : tout sauf la facturation', parties.employe, parties.admin.replace('facturation,', ''));
  await comme('client');
  verifier('client : vue générale, à traiter, recherche, clients → refusés',
           [await code(A.vueGenerale({})), await code(A.colisATraiter('action_requise')),
            await code(A.rechercheRapide('GSE')), await code(A.clientsSoldes({}))],
           ['non-autorise', 'non-autorise', 'non-autorise', 'non-autorise']);
  var m = await API.monResume();
  verifier('client : son résumé, ses colis et sa facture', [m.colis.en_cours > 0, m.factures.nombre > 0], [true, true]);
  await API.deconnecter();
  verifier('visiteur : aucun résumé', await code(API.monResume()), 'non-autorise');

  console.log('\nC. Les périodes');
  await comme('admin');
  var v = await A.vueGenerale({ periode: 'mois_precedent' });
  verifier('mois précédent : du 1er au dernier jour', [v.periode.debut.slice(8), v.periode.fin < v0.periode.fin], ['01', true]);
  verifier('période refusée : fin avant début',
           await code(A.vueGenerale({ periode: 'personnalise', debut: '2026-09-10', fin: '2026-09-01' })), 'INVALID_PERIOD');
  verifier('période refusée : plus de 367 jours',
           await code(A.vueGenerale({ periode: 'personnalise', debut: '2025-01-01', fin: '2026-09-01' })), 'INVALID_PERIOD');
  verifier('période inconnue', await code(A.vueGenerale({ periode: 'hier' })), 'INVALID_PERIOD');
  verifier('jours sans mouvement à 0 : refusé', await code(A.vueGenerale({ jours: 0 })), 'INVALID_INPUT');
  var fj = (await A.creerFacture({ client_id: caro.id, montant_usd: 40 }, [])).facture;
  var pj = await A.enregistrerPaiement(fj.id, { montant_usd: 15, moyen: 'especes', paye_le: '2026-09-10T23:30:00-04:00' });
  var le10 = (await A.vueGenerale({ periode: 'personnalise', debut: '2026-09-10', fin: '2026-09-10' })).facturation;
  var le11 = (await A.vueGenerale({ periode: 'personnalise', debut: '2026-09-11', fin: '2026-09-11' })).facturation;
  verifier('payé le 10 à 23 h 30 (le 11 en UTC) : compté le 10', [le10.encaisse_periode, le11.encaisse_periode], [15, 0]);
  await A.annulerPaiement(pj.paiement.id, 'Essai de fuseau');
  await A.annulerFacture(fj.id, 'Essai de fuseau');

  console.log('\nD. Facturé = payé + solde');
  // La démonstration a déjà des factures d'exemple : on compte ce que la nouvelle ajoute
  var avant = (await A.vueGenerale({})).facturation;
  var cAvant = (await A.clientsSoldes({ recherche: 'carolina' })).lignes[0];
  await comme('carolina');
  var mAvant = (await API.monResume()).factures;
  await comme('admin');
  var f = (await A.creerFacture({ client_id: caro.id, montant_usd: 75 }, [])).facture;
  var etapes = [];
  for (var paiement of [0, 25, 50]) {
    if (paiement) await A.enregistrerPaiement(f.id, { montant_usd: paiement, moyen: 'especes' });
    var x = (await A.vueGenerale({})).facturation;
    var c = (await A.clientsSoldes({ recherche: 'carolina' })).lignes[0];
    var r = (await A.rechercheRapide(f.numero)).factures.filter(function (z) { return z.id === f.id; })[0];
    etapes.push([r2(x.a_encaisser - avant.a_encaisser), r2(x.encaisse_periode - avant.encaisse_periode),
                 r2(x.facture_periode - x.paye_sur_periode - x.solde_sur_periode),
                 [r2(c.facture_usd - cAvant.facture_usd), r2(c.paye_usd - cAvant.paye_usd), r2(c.solde_usd - cAvant.solde_usd)],
                 r.etat]);
  }
  verifier('75 → payé 25 → payé 50 : solde, encaissé, identité, client, état', etapes, [
    [75, 0, 0, [75, 0, 75], 'a_payer'], [50, 25, 0, [75, 25, 50], 'partielle'], [0, 75, 0, [75, 75, 0], 'payee']]);
  await comme('carolina');
  var mc = (await API.monResume()).factures;
  verifier('espace client de Carolina : les mêmes chiffres',
           [r2(mc.facture_usd - mAvant.facture_usd), r2(mc.paye_usd - mAvant.paye_usd), r2(mc.solde_usd - mAvant.solde_usd)],
           [75, 75, 0]);
  await comme('admin');
  var retard = (await A.vueGenerale({})).facturation;
  var g = (await A.creerFacture({ client_id: jean.id, montant_usd: 12, echeance_le: '2020-01-01' }, [])).facture;
  var vr = await A.vueGenerale({});
  verifier('une facture échue : en retard, et son alerte',
           [vr.facturation.etats.en_retard - retard.etats.en_retard,
            r2(vr.facturation.montant_en_retard - retard.montant_en_retard),
            vr.alertes.filter(function (a) { return a.code === 'factures_en_retard'; })[0].nombre],
           [1, 12, retard.etats.en_retard + 1]);
  await A.annulerFacture(g.id, 'Erreur');
  verifier('paiements récents : 50 puis 25, sans le paiement annulé',
           (await A.vueGenerale({})).paiements_recents.slice(0, 2).map(function (z) { return z.montant_usd; }), [50, 25]);

  console.log('\nE. Un scan → le tableau de bord');
  await comme('employe');
  avant = await A.vueGenerale({});
  var s = await A.operationScanner(c1.numero, 'COLIS_EMBALLE', { lieu: 'Miami (Medley), FL' });
  verifier('l\'employée scanne « Emballé »', s.code, 'OK');
  var apres = await A.vueGenerale({});
  verifier('scans +1, reçus −1, emballés +1',
           [apres.scanner.periode - avant.scanner.periode, apres.scanner.aujourdhui - avant.scanner.aujourdhui,
            apres.colis.statuts.recu - avant.colis.statuts.recu, apres.colis.statuts.emballe - avant.colis.statuts.emballe],
           [1, 1, -1, 1]);
  verifier('dernier scan, activité : ce colis, source scanner',
           [apres.scanner.dernier.numero, apres.activite[0].numero, apres.activite[0].source, apres.activite[0].libelle],
           [c1.numero, c1.numero, 'scanner', 'Emballé']);
  var deux = await Promise.all([A.operationScanner(c1.numero, 'COLIS_EXPEDIE', {}), A.operationScanner(c1.numero, 'COLIS_EXPEDIE', {})]);
  verifier('le même scan deux fois : une opération, puis « déjà fait »', deux.map(function (z) { return z.code; }).sort(),
           ['ALREADY_IN_TARGET_STATE', 'OK']);
  verifier('… un seul événement compté', (await A.vueGenerale({})).scanner.periode - apres.scanner.periode, 1);

  console.log('\nF. Les colis à traiter');
  await comme('admin');
  var cj = (await A.creerColis(Object.assign({}, base, { client_id: jean.id, description: 'Colis de Jean' }))).colis;
  await A.changerStatut([cj.id], { statut: 'incident', lieu: 'Miami', note: 'Adresse incomplète' });
  var ar = await A.colisATraiter('action_requise');
  var laLigne = ar.lignes.filter(function (z) { return z.id === cj.id; })[0];
  verifier('action requise : le colis de Jean, et pourquoi', [laLigne.client.nom_complet, laLigne.action.note],
           ['Jean-Robert Pierre', 'Adresse incomplète']);
  var vieux = (await A.creerColis(Object.assign({}, base, { description: 'Oublié' }))).colis;
  retoucher(function (d) {
    var il = new Date(Date.now() - 10 * 864e5).toISOString();
    d.historique.forEach(function (h) { if (h.colis_id === vieux.id) h.cree_le = il; });
    d.colis.forEach(function (c) { if (c.id === vieux.id) c.recu_le = il; });
  });
  var sm = await A.colisATraiter('sans_mouvement', { jours: 7 });
  verifier('sans mouvement depuis 7 jours : le colis oublié, 10 jours',
           sm.lignes.filter(function (z) { return z.id === vieux.id; }).map(function (z) { return z.jours; }), [10]);
  verifier('… et la vue générale suit le réglage',
           [(await A.vueGenerale({ jours: 7 })).colis.sans_mouvement >= 1, (await A.vueGenerale({ jours: 365 })).colis.sans_mouvement],
           [true, 0]);
  verifier('liste inconnue : refusée', await code(A.colisATraiter('tout')), 'INVALID_INPUT');

  console.log('\nG. La recherche rapide');
  var fm = (await A.factures({ parPage: 200 })).lignes.filter(function (z) { return z.client_id === marie.id; })[0].numero;
  var cas = [
    ['numéro exact', c1.numero, 'colis', c1.numero],
    ['numéro en minuscules', c1.numero.toLowerCase(), 'colis', c1.numero],
    ['début de numéro', c1.numero.slice(0, 7), 'colis', c1.numero],
    ['QR de l\'étiquette', 'https://www.goshipexpress.com/index.html?suivi=' + c1.numero, 'colis', c1.numero],
    ['suivi du vendeur', 'ESSAI7TABLEAU77', 'colis', c1.numero],
    ['code client', marie.code, 'clients', marie.nom_complet],
    ['chiffres du code', marie.code.slice(4), 'clients', marie.nom_complet],
    ['un mot du nom', 'dorvil', 'clients', marie.nom_complet],
    ['nom composé', 'marie ange', 'clients', marie.nom_complet],
    ['fin du téléphone', marie.telephone.replace(/\D/g, '').slice(-4), 'clients', marie.nom_complet],
    ['début de l\'e-mail', 'jean-rob', 'clients', jean.nom_complet],
    ['n° de facture', fm, 'factures', fm]
  ];
  for (var k of cas) {
    var liste = (await A.rechercheRapide(k[1]))[k[2]];
    verifier(k[0] + ' « ' + k[1].slice(0, 24) + ' »',
             liste.map(function (z) { return k[2] === 'clients' ? z.nom_complet : z.numero; }).indexOf(k[3]) >= 0, true);
  }
  var trouve = (await A.rechercheRapide(c1.numero)).colis[0];
  verifier('un colis trouvé : client, dernier événement, facture et solde',
           [!!trouve.client, !!trouve.dernier_evenement, trouve.facture && typeof trouve.facture.solde_usd], [true, true, 'number']);
  for (var t of ['%', '_', 'a', '', 'GSE-%']) {
    var rr = await A.rechercheRapide(t);
    verifier('« ' + t + ' » ne liste pas tout', rr.colis.length + rr.clients.length + rr.factures.length, 0);
  }

  console.log('\nH. Les clients et leurs soldes');
  var cs = await A.clientsSoldes({ tri: 'solde' });
  var soldes = cs.lignes.map(function (z) { return z.solde_usd; });
  verifier('triés par solde décroissant', soldes, soldes.slice().sort(function (a, b) { return b - a; }));
  verifier('une page de 1 : total inchangé', (await A.clientsSoldes({ tri: 'nom', parPage: 1 })).total, cs.total);
  verifier('avec un solde seulement : tous > 0',
           (await A.clientsSoldes({ filtre: 'avec_solde' })).lignes.every(function (z) { return z.solde_usd > 0; }), true);
  verifier('tri inconnu : refusé', await code(A.clientsSoldes({ tri: 'hasard' })), 'INVALID_INPUT');

  console.log('\nI. Volume : 100 puis 1 000 colis');
  for (var n of [100, 1000]) {
    retoucher(function (d) {
      var t0 = new Date().toISOString();
      while (d.colis.length < n) {
        d.seqColis += 1;
        var statut = ['recu', 'emballe', 'embarque', 'livre'][d.colis.length % 4];
        d.colis.push({ id: 'vrac-' + d.seqColis, numero: 'GSE-' + d.seqColis + '-HT', client_id: caro.id, statut: statut,
                       description: 'Vrac', poids_lb: 2, service: 'aerien', pays_destination: 'HT', recu_le: t0,
                       cree_le: t0, maj_le: t0, lieu: '', note: '' });
      }
    });
    var vv = await A.vueGenerale({});
    var somme = Object.keys(vv.colis.statuts).reduce(function (t, k) { return t + vv.colis.statuts[k]; }, 0);
    verifier(n + ' colis : total, somme des huit statuts', [vv.colis.total, somme], [n, n]);
    verifier(n + ' colis : facturé = payé + solde',
             r2(vv.facturation.facture_periode - vv.facturation.paye_sur_periode - vv.facturation.solde_sur_periode), 0);
  }

  var nb = resultats.filter(Boolean).length;
  if (process.argv[2] === '--formes') {
    await comme('admin');
    await A.envoyerEmail(c1.id, 'recu', {});
    var formes = {
      'vue générale': cles(await A.vueGenerale({})),
      'colis à traiter': cles(await A.colisATraiter('action_requise')),
      'recherche rapide': cles(await A.rechercheRapide(c1.numero)),
      'clients et soldes': cles(await A.clientsSoldes({}))
    };
    await comme('client');
    formes['mon résumé'] = cles(await API.monResume());
    fs.writeSync(1, JSON.stringify(formes));
    process.exit(nb === resultats.length ? 0 : 1);
  }
  console.log('\n' + resultats.length + ' vérifications, ' + nb + ' réussies.');
  process.exit(nb === resultats.length ? 0 : 1);
})().catch(function (e) { console.error(e); process.exit(2); });
