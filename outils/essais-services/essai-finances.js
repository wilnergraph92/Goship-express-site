/* ==========================================================================
   Goship Express — les finances du mode démonstration, hors navigateur
   ==========================================================================
   Rejoue sur la copie démo (assets/js/api.js) les cas de essai-finances.py :
   mêmes montants, mêmes refus, mêmes codes. Les deux doivent dire la même
   chose, sinon le tableau de bord se comporte autrement sur votre ordinateur
   qu'en ligne.

     node outils/essais-services/essai-finances.js             les cas
     node outils/essais-services/essai-finances.js --totaux    (entrée JSON)
          les montants que l'écran et le papier affichent pour des factures
          telles que la base les renvoie — sert à essai-finances.py.
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

if (process.argv[2] === '--totaux') {
  fs.writeSync(1, JSON.stringify(JSON.parse(fs.readFileSync(0, 'utf8')).map(API.outils.totauxFacture)));
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
function resume(f) { return [f.montant_usd, f.paye_usd, f.solde_usd, f.etat_paiement, f.statut]; }

(async function () {
  var A = API.admin;
  await API.connecter('admin@goship.demo', 'demo1234');
  await A.exemples();
  var clients = {};
  (await A.clients({ parPage: 50 })).lignes.forEach(function (c) { clients[c.email] = c.id; });
  var marie = clients['marie-ange@exemple.com'], jean = clients['jean-robert@exemple.com'];
  var base = { client_id: marie, description: 'Chaussures', poids_lb: 4, service: 'aerien', pays_destination: 'HT',
               destination: 'Pétion-Ville' };
  function avec(x) { return Object.assign({}, base, x); }
  async function colis(x, facturer) {
    var r = await A.creerColis(avec(x));
    return r;
  }
  async function lire(id) { return (await A.factures({ parPage: 500 })).lignes.filter(function (f) { return f.id === id; })[0]; }

  console.log('A. Les exemples de démonstration');
  var toutes = (await A.factures({ parPage: 500 })).lignes;
  verifier('chaque colis d\'exemple a sa facture', toutes.length, 7);
  verifier('une payée, une partielle, une en retard',
           ['payee', 'partielle', 'en_retard'].map(function (e) {
             return toutes.filter(function (f) { return f.etat_paiement === e; }).length;
           }), [1, 1, 1]);

  console.log('\nB. La facture de 31 $');
  var h31 = await colis({ description: 'Colis à 31 $', poids_lb: 4.2 });
  var f31 = h31.facture;
  await A.enregistrerPaiement(f31.id, { montant_usd: 31, moyen: 'paypal' });
  var t31 = API.outils.totauxFacture(await lire(f31.id));
  verifier('31 $, payée : écran et papier', [t31.grandTotal, t31.colis, t31.frais, t31.paye, t31.balance, t31.etat],
           [31, 21, 10, 31, 0, 'payee']);
  await API.deconnecter();
  await API.connecter('marie-ange@exemple.com', 'demo1234');
  var mf = (await API.mesFactures()).filter(function (f) { return f.id === f31.id; })[0];
  verifier('espace client : 31 $, payé 31 $, solde 0, payée, tarif 5 $/lb',
           [mf.montant_usd, mf.paye_usd, mf.solde_usd, mf.etat, mf.lignes[0].tarif_lb_usd, mf.paiements.length],
           [31, 31, 0, 'payee', 5, 1]);
  verifier('un client n\'encaisse rien', await code(A.enregistrerPaiement(f31.id, { montant_usd: 1, moyen: 'especes' })),
           'non-autorise');
  verifier('ne regroupe rien', await code(A.regrouperFactures([f31.id, f31.id])), 'non-autorise');
  verifier('ne lit pas le rapport', await code(A.anomaliesFacturation()), 'non-autorise');
  await API.deconnecter();
  await API.connecter('admin@goship.demo', 'demo1234');

  console.log('\nC. Tarif arrêté');
  var t = await colis({ description: 'Tarif spécial', poids_lb: 10, tarif_lb_usd: 2.5 });
  verifier('10 lb × 2,50 $ = 25 $ ; facture 35 $ ; la ligne garde 2,50 $/lb',
           [t.colis.prix_usd, t.facture.montant_usd, t.facture.facture_lignes[0].tarif_lb_usd], [25, 35, 2.5]);

  console.log('\nD. Regroupement : 20 + 15 + 30 + 10 = 75 $');
  var c3 = [];
  for (var p of [4, 3, 6]) c3.push((await colis({ description: 'Groupe ' + p, poids_lb: p })).facture.id);
  var calc = await A.calculerFacture((await Promise.all(c3.map(lire))).map(function (f) { return f.facture_lignes[0].colis_id; }));
  verifier('aperçu : 65 + 10 = 75', [calc.sous_total, calc.frais_service, calc.total], [65, 10, 75]);
  var rg = await A.regrouperFactures(c3, 'regroupe-1');
  verifier('regroupées : 75 $, frais une fois, trois lignes, à payer',
           [rg.facture.montant_usd, rg.facture.frais_service_usd, rg.facture.facture_lignes.length,
            rg.facture.etat_paiement], [75, 10, 3, 'a_payer']);
  var anciennes = await Promise.all(c3.map(lire));
  verifier('les anciennes : annulées, avec motif, vers la nouvelle',
           anciennes.every(function (f) {
             return f.statut === 'annulee' && f.remplacee_par === rg.facture.id &&
                    f.motif_annulation.indexOf('Regroupement des factures') === 0;
           }), true);
  verifier('même demande : même facture', [(await A.regrouperFactures(c3, 'regroupe-1')).deja], [true]);
  var x1 = (await colis({ description: 'Payé', poids_lb: 1 })).facture.id;
  var x2 = (await colis({ description: 'Pas payé', poids_lb: 1 })).facture.id;
  var x3 = (await colis({ client_id: jean, description: 'Autre client', poids_lb: 1 })).facture.id;
  var libre = (await A.creerFacture({ client_id: jean, montant_usd: 18 }, [])).facture.id;
  await A.enregistrerPaiement(x1, { montant_usd: 5, moyen: 'especes' });
  verifier('avec un paiement : refusé', await code(A.regrouperFactures([x1, x2])), 'INVOICE_HAS_PAYMENTS');
  verifier('deux clients : refusé', await code(A.regrouperFactures([x2, x3])), 'INVOICE_CLIENT_MISMATCH');
  verifier('une seule : refusé', await code(A.regrouperFactures([x2])), 'INVALID_INPUT');
  verifier('sans colis : refusé', await code(A.regrouperFactures([x3, libre])), 'INVOICE_NOT_GROUPABLE');
  verifier('annulée : refusé', await code(A.regrouperFactures([x2, c3[0]])), 'INVOICE_NOT_GROUPABLE');
  verifier('refus : rien d\'annulé', (await lire(x2)).statut, 'a_payer');

  console.log('\nE. Paiements : partiel, multiples, en trop');
  var fg = rg.facture.id;
  var p1 = await A.enregistrerPaiement(fg, { montant_usd: 25, moyen: 'moncash', reference: 'MC-001',
                                             paye_le: '2026-09-20T10:00:00-04:00' }, 'p-1');
  verifier('25 $ : payé 25, solde 50, partielle', resume(p1.facture), [75, 25, 50, 'partielle', 'a_payer']);
  await A.enregistrerPaiement(fg, { montant_usd: 20, moyen: 'especes', paye_le: '2026-09-22T10:00:00-04:00' });
  verifier('+ 20 $ : payé 45, solde 30', resume(await lire(fg)), [75, 45, 30, 'partielle', 'a_payer']);
  verifier('80 $ : refusé', await code(A.enregistrerPaiement(fg, { montant_usd: 80, moyen: 'especes' })), 'OVERPAYMENT');
  verifier('31 $ pour 30 $ : refusé', await code(A.enregistrerPaiement(fg, { montant_usd: 31, moyen: 'especes' })),
           'OVERPAYMENT');
  var p3 = await A.enregistrerPaiement(fg, { montant_usd: '30,00', moyen: 'banque', reference: 'VIR-77',
                                             paye_le: '2026-09-24T15:00:00-04:00' });
  verifier('+ 30 $ : payée', resume(p3.facture), [75, 75, 0, 'payee', 'payee']);
  verifier('datée du dernier paiement, par son moyen',
           [new Date(p3.facture.payee_le).toISOString(), p3.facture.moyen], ['2026-09-24T19:00:00.000Z', 'banque']);
  verifier('payée : un paiement de plus est refusé',
           await code(A.enregistrerPaiement(fg, { montant_usd: 1, moyen: 'especes' })), 'INVOICE_ALREADY_PAID');
  var refus = [];
  for (var v of [{ montant_usd: 0, moyen: 'especes' }, { montant_usd: -5, moyen: 'especes' },
                 { montant_usd: 'abc', moyen: 'especes' }, { montant_usd: 1, moyen: 'bitcoin' },
                 { montant_usd: 1, moyen: 'especes', paye_le: '2099-01-01' }]) {
    refus.push(await code(A.enregistrerPaiement(x2, v)));
  }
  verifier('nul, négatif, illisible, moyen inconnu, futur', refus,
           ['INVALID_AMOUNT', 'INVALID_AMOUNT', 'INVALID_AMOUNT', 'INVALID_PAYMENT_METHOD', 'INVALID_DATE']);
  verifier('facture inconnue', await code(A.enregistrerPaiement('fac-0', { montant_usd: 1, moyen: 'especes' })),
           'INVOICE_NOT_FOUND');

  console.log('\nF. Double paiement');
  var y = (await colis({ description: 'Double', poids_lb: 13 })).facture.id;
  var a = await A.enregistrerPaiement(y, { montant_usd: 25, moyen: 'paypal', reference: 'PP-1' }, 'double');
  var b = await A.enregistrerPaiement(y, { montant_usd: 25, moyen: 'paypal', reference: 'PP-1' }, 'double');
  verifier('même clé : le même paiement', [b.deja, b.paiement.id === a.paiement.id, resume(b.facture)],
           [true, true, [75, 25, 50, 'partielle', 'a_payer']]);
  verifier('même référence : refusé', await code(A.enregistrerPaiement(y, { montant_usd: 25, moyen: 'paypal',
                                                                           reference: 'pp-1' }, 'autre')),
           'DUPLICATE_PAYMENT');
  verifier('même clé, autre facture : refusé', await code(A.enregistrerPaiement(x2, { montant_usd: 1, moyen: 'especes' },
                                                                                   'double')), 'DUPLICATE_OPERATION');

  console.log('\nG. Deux paiements de 50 $ sur 75 $, lancés ensemble');
  var z = (await colis({ description: 'Course', poids_lb: 13 })).facture.id;
  var deux = await Promise.all([code(A.enregistrerPaiement(z, { montant_usd: 50, moyen: 'especes' })),
                                code(A.enregistrerPaiement(z, { montant_usd: 50, moyen: 'banque' }))]);
  verifier('un seul passe, l\'autre est refusé', deux.sort(), ['OVERPAYMENT', 'aucune']);
  verifier('payé 50, solde 25', resume(await lire(z)), [75, 50, 25, 'partielle', 'a_payer']);

  console.log('\nH. Annuler un paiement');
  var ps = (await lire(fg)).paiements;
  var vingt = ps.filter(function (x) { return x.montant_usd === 20; })[0];
  verifier('sans motif : refusé', await code(A.annulerPaiement(vingt.id, ' ')), 'REASON_REQUIRED');
  var an = await A.annulerPaiement(vingt.id, 'Billet refusé à la banque');
  verifier('annulé : payé 55, solde 20, à payer, plus datée', resume(an.facture).concat([an.facture.payee_le]),
           [75, 55, 20, 'partielle', 'a_payer', null]);
  verifier('reste, barré, avec motif', [!!an.paiement.annule_le, an.paiement.motif_annulation],
           [true, 'Billet refusé à la banque']);
  verifier('deux fois : rien de plus', (await A.annulerPaiement(vingt.id, 'x')).deja, true);
  await A.enregistrerPaiement(fg, { montant_usd: 20, moyen: 'natcash', reference: 'NC-9' });
  verifier('le bon saisi : payée', resume(await lire(fg)), [75, 75, 0, 'payee', 'payee']);

  console.log('\nI. La facture : seuls échéance, note, lien et total libre changent');
  var w = (await colis({ description: 'Garde', poids_lb: 2 })).facture.id;
  var mod = await A.modifierFacture(w, { statut: 'payee', montant_paye_usd: 20, moyen: 'paypal', note: 'Merci',
                                         echeance_le: '2026-10-01' });
  verifier('statut, payé et moyen ignorés ; note et échéance changées',
           [mod.statut, mod.paye_usd, mod.moyen, mod.note, mod.echeance_le], ['a_payer', 0, '', 'Merci', '2026-10-01']);
  verifier('total d\'une facture de colis : refusé', await code(A.modifierFacture(w, { montant_usd: 99 })), 'INVOICE_LOCKED');
  await A.enregistrerPaiement(libre, { montant_usd: 8, moyen: 'especes' });
  verifier('facture libre : jamais sous le payé', await code(A.modifierFacture(libre, { montant_usd: 5 })), 'INVALID_AMOUNT');
  verifier('ramenée au payé : payée', resume(await A.modifierFacture(libre, { montant_usd: 8 })),
           [8, 8, 0, 'payee', 'payee']);
  var cp = (await A.creerFacture({ client_id: jean, montant_usd: 50, montant_paye_usd: 20 }, [])).facture;
  verifier('payée en partie à la création : un paiement « à la création »',
           resume(cp).concat([cp.paiements[0].origine]), [50, 20, 30, 'partielle', 'a_payer', 'creation']);

  console.log('\nJ. Annuler une facture');
  verifier('avec de l\'argent : refusé', await code(A.annulerFacture(z, 'Erreur')), 'INVOICE_HAS_PAYMENTS');
  verifier('sans motif : refusé', await code(A.annulerFacture(w, '')), 'REASON_REQUIRED');
  var af = (await A.annulerFacture(w, 'Mauvais client')).facture;
  verifier('annulée : motif, solde 0', [af.statut, af.motif_annulation, af.solde_usd, af.etat_paiement],
           ['annulee', 'Mauvais client', 0, 'annulee']);
  verifier('deux fois : rien de plus', (await A.annulerFacture(w, 'x')).deja, true);
  verifier('un paiement dessus : refusé', await code(A.enregistrerPaiement(w, { montant_usd: 1, moyen: 'especes' })),
           'INVOICE_CANCELLED');
  verifier('elle ne se modifie plus', await code(A.modifierFacture(w, { note: 'x' })), 'INVOICE_LOCKED');
  var nf = (await A.facturerColis(af.facture_lignes[0].colis_id)).facture;
  verifier('son colis se refacture, sous un autre numéro', [nf.numero !== af.numero, nf.montant_usd], [true, 20]);
  verifier('plus de suppression', typeof A.supprimerFacture, 'undefined');

  console.log('\nM. Résumé et retard');
  var r1 = (await colis({ description: 'Échue', poids_lb: 2 })).facture.id;
  await A.modifierFacture(r1, { echeance_le: '2020-01-01' });
  await A.enregistrerPaiement(r1, { montant_usd: 5, moyen: 'especes' });
  verifier('échue, en partie payée : en retard', (await lire(r1)).etat_paiement, 'en_retard');
  var res = await A.resumeFacturation();
  var ouvertes = (await A.factures({ parPage: 500 })).lignes.filter(function (f) { return f.statut !== 'annulee'; });
  verifier('à encaisser = somme des soldes', res.a_encaisser,
           API.outils.arrondi(ouvertes.reduce(function (s, f) { return s + f.solde_usd; }, 0)));
  verifier('en retard : l\'échue et les pièces auto', res.en_retard, 2);
  verifier('filtre « en retard »', (await A.factures({ etat: 'en_retard', parPage: 500 })).lignes.length, 2);
  verifier('filtre « partiellement payées »', (await A.factures({ etat: 'partielle', parPage: 500 })).lignes
    .every(function (f) { return f.paye_usd > 0 && f.solde_usd > 0; }), true);

  console.log('\nO. Traçabilité');
  var actions = (await A.journal({ parPage: 1000 })).lignes.map(function (l) { return l.action; });
  verifier('journal : paiements, annulations, regroupement',
           ['paiement.enregistrement', 'paiement.annulation', 'facture.annulation', 'facture.regroupement']
             .every(function (x) { return actions.indexOf(x) >= 0; }), true);

  console.log('\nP. Rapport d\'anomalies');
  var rap = await A.anomaliesFacturation();
  verifier('rien de grave dans des données propres',
           rap.filter(function (x) { return x.gravite !== 'info'; }).map(function (x) { return x.type; }), []);

  console.log('\nR. Les deux côtés d\'accord');
  verifier('mêmes moyens de paiement que la base', API.regles.moyensPaiement,
           ['paypal', 'banque', 'azul', 'moncash', 'natcash', 'especes', 'transfert', 'autre']);

  var n = resultats.filter(Boolean).length;
  console.log('\n' + resultats.length + ' vérifications, ' + n + ' réussies.');
  process.exit(n === resultats.length ? 0 : 1);
})().catch(function (e) { console.error(e); process.exit(2); });
