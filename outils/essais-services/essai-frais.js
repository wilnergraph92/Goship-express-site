/* ==========================================================================
   Goship Express — les frais de service du mode démonstration, hors navigateur
   ==========================================================================
   Rejoue sur la copie démo (assets/js/api.js) les cas de essai-frais.py
   (outils/supabase-frais-service.sql) : mêmes montants, mêmes refus, mêmes codes.

     node outils/essais-services/essai-frais.js
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
// total, frais, payé, solde, état, statut — comme etat() de essai-frais.py
function etat(f) { return [f.montant_usd, f.frais_service_usd, f.paye_usd, f.solde_usd, f.etat_paiement, f.statut]; }

(async function () {
  var A = API.admin;
  await API.connecter('admin@goship.demo', 'demo1234');
  await A.exemples();
  var clients = {};
  (await A.clients({ parPage: 50 })).lignes.forEach(function (c) { clients[c.email] = c.id; });
  var marie = clients['marie-ange@exemple.com'], jean = clients['jean-robert@exemple.com'];
  async function colis(poids, x, sansFacture) {
    var champs = Object.assign({ client_id: marie, description: 'Colis', poids_lb: poids, service: 'aerien',
                                 pays_destination: 'HT', destination: 'Jacmel' }, x || {});
    var r = await A.creerColis(champs);
    // Un colis sans facture : on annule celle que le tableau de bord crée avec lui
    if (sansFacture) { await A.annulerFacture(r.facture.id, 'Colis sans facture (essai)'); r.facture = null; }
    return r;
  }
  async function lire(id) { return (await A.factures({ parPage: 1000 })).lignes.filter(function (f) { return f.id === id; })[0]; }
  function encaisser(id, montant, frais, cle) {
    return A.encaisserFacture(id, { montant_usd: montant, moyen: 'especes' }, frais, cle);
  }

  console.log('1. Enregistrer un colis : aucun frais de service');
  var r1 = await colis(4, { description: 'Chaussures' });
  verifier('colis de 4 lb : prix 20 $', r1.colis.prix_usd, 20);
  verifier('sa facture : 20 $, frais 0, à payer', [r1.facture.montant_usd, r1.facture.frais_service_usd, r1.facture.statut],
           [20, 0, 'a_payer']);
  var sans = await colis(2, { description: 'Sans facture' }, true);
  var fc = (await A.facturerColis(sans.colis.id)).facture;
  verifier('facturer un colis à part : 10 $, frais 0', [fc.montant_usd, fc.frais_service_usd], [10, 0]);
  var calc = await A.calculerFacture([r1.colis.id]);
  verifier('l\'aperçu donne toujours les frais de la maison (10 $) à part', [calc.sous_total, calc.frais_service, calc.total],
           [20, 10, 30]);

  console.log('\n2. Regrouper plusieurs colis : frais sur une ligne à part, total juste');
  var a = await colis(4), b = await colis(3), c = await colis(6);
  var g = (await A.regrouper([a.facture.id, b.facture.id, c.facture.id], [], true, 'reg-1')).facture;
  verifier('20 + 15 + 30 = 65 $ de colis, 10 $ de frais une fois, total 75 $',
           [g.facture_lignes.map(function (l) { return l.montant_usd; }).sort(function (x, y) { return x - y; }),
            g.frais_service_usd, g.montant_usd], [[15, 20, 30], 10, 75]);
  var anciennes = await Promise.all([a, b, c].map(function (x) { return lire(x.facture.id); }));
  verifier('les trois anciennes : annulées, remplacées par la nouvelle',
           anciennes.every(function (f) { return f.statut === 'annulee' && f.remplacee_par === g.id; }), true);
  verifier('rejouée avec la même clé : la même facture',
           (await A.regrouper([a.facture.id, b.facture.id, c.facture.id], [], true, 'reg-1')).deja, true);
  var d = await colis(2), e = await colis(2);
  var g2 = (await A.regrouper([d.facture.id, e.facture.id], [], false)).facture;
  verifier('regroupées sans frais : 20 $, frais 0', etat(g2), [20, 0, 0, 20, 'a_payer', 'a_payer']);

  console.log('\n3. Regrouper puis « Encaisser → Non » : aucun frais ajouté');
  var r3 = await encaisser(g2.id, 20, false);
  verifier('20 $ encaissés, frais 0, facture payée', etat(r3.facture), [20, 0, 20, 0, 'payee', 'payee']);
  verifier('frais_ajoutes : non', r3.frais_ajoutes, false);

  console.log('\n4. Regrouper puis « Encaisser → Oui » : frais ajoutés une fois');
  var f4 = await colis(2), g4a = await colis(2);
  var g4 = (await A.regrouper([f4.facture.id, g4a.facture.id], [], false)).facture;
  verifier('Oui, mais 40 $ pour un nouveau solde de 30 $ : refusé', await code(encaisser(g4.id, 40, true)), 'OVERPAYMENT');
  verifier('… et les frais ne restent pas ajoutés', etat(await lire(g4.id)), [20, 0, 0, 20, 'a_payer', 'a_payer']);
  var r4 = await encaisser(g4.id, 30, true, 'enc-4');
  verifier('Oui : 20 + 10 = 30 $ encaissés, payée', etat(r4.facture), [30, 10, 30, 0, 'payee', 'payee']);
  verifier('frais_ajoutes : oui', r4.frais_ajoutes, true);
  var r4b = await encaisser(g4.id, 30, true, 'enc-4');
  verifier('rejoué (même clé) : le même paiement, pas de second frais', [r4b.deja, etat(r4b.facture)],
           [true, [30, 10, 30, 0, 'payee', 'payee']]);

  console.log('\n5. Frais appliqués au regroupement, puis encaissement : pas de double frais');
  var h = await colis(4), i = await colis(3);
  var g5 = (await A.regrouper([h.facture.id, i.facture.id], [], true)).facture;
  verifier('regroupée : 20 + 15 + 10 = 45 $', [g5.montant_usd, g5.frais_service_usd], [45, 10]);
  var r5 = await encaisser(g5.id, 20, true);
  verifier('Oui sur une facture qui a déjà ses frais : 45 $, acompte de 20 $', etat(r5.facture),
           [45, 10, 20, 25, 'partielle', 'a_payer']);
  verifier('frais_ajoutes : non (déjà inclus)', r5.frais_ajoutes, false);
  verifier('le reste, encore avec Oui : soldée, frais toujours 10 $', etat((await encaisser(g5.id, 25, true)).facture),
           [45, 10, 45, 0, 'payee', 'payee']);

  console.log('\n6. Ajouter un colis à une facture existante : recalculée, frais une fois');
  var j = await colis(4), k = await colis(2);
  var base6 = (await A.regrouper([j.facture.id, k.facture.id], [], true)).facture;
  verifier('la facture existante : 40 $', base6.montant_usd, 40);
  var l = await colis(6, { description: 'L (avec sa facture)' });
  var m = await colis(3, { description: 'M (sans facture)' }, true);
  var g6 = (await A.regrouper([base6.id], [l.colis.id, m.colis.id], true, 'ajout-6')).facture;
  verifier('+ L (30 $) + M (15 $, sans facture) : 4 lignes, 85 $, frais une fois',
           [g6.facture_lignes.length, g6.montant_usd, g6.frais_service_usd], [4, 85, 10]);
  verifier('la facture existante et celle de L : annulées, renvoyées à la nouvelle',
           [(await lire(base6.id)).remplacee_par === g6.id, (await lire(l.facture.id)).remplacee_par === g6.id], [true, true]);
  var n = await colis(2);
  await encaisser(n.facture.id, 5, false);
  verifier('un colis sur une facture qui a reçu un paiement : refusé',
           await code(A.regrouper([g6.id], [n.colis.id], true)), 'INVOICE_ALREADY_EXISTS');
  verifier('un colis sur une facture payée : refusé', await code(A.regrouper([g6.id], [d.colis.id], true)),
           'INVOICE_ALREADY_EXISTS');
  var chezJean = await colis(2, { client_id: jean, description: 'Chez Jean' }, true);
  verifier('un colis d\'un autre client : refusé', await code(A.regrouper([g6.id], [chezJean.colis.id], true)),
           'INVOICE_CLIENT_MISMATCH');
  verifier('rien n\'a bougé après ces refus', etat(await lire(g6.id)), [85, 10, 0, 85, 'a_payer', 'a_payer']);

  console.log('\n7. Le même colis deux fois : bloqué');
  verifier('la facture et un de ses propres colis : refusé',
           await code(A.regrouper([g6.id], [g6.facture_lignes[0].colis_id], true)), 'INVALID_INPUT');
  var rr = await colis(2), ss = await colis(2);
  var g7 = (await A.regrouper([rr.facture.id, ss.facture.id], [rr.colis.id, rr.colis.id], true)).facture;
  verifier('R choisi deux fois en plus de sa facture : 2 lignes, 30 $', [g7.facture_lignes.length, g7.montant_usd], [2, 30]);
  verifier('refacturer un colis déjà sur une facture active : refusé',
           await code(A.creerFacture({ client_id: marie, frais_service: true }, [rr.colis.id])), 'INVOICE_ALREADY_EXISTS');

  console.log('\n8. Ajouter ou retirer les frais depuis la fiche');
  var t = await colis(4);
  verifier('appliquer : 30 $', etat((await A.changerFraisService(t.facture.id, true)).facture),
           [30, 10, 0, 30, 'a_payer', 'a_payer']);
  verifier('appliquer encore : deja', (await A.changerFraisService(t.facture.id, true)).deja, true);
  await encaisser(t.facture.id, 25, false);
  verifier('retirer sous le payé : refusé', await code(A.changerFraisService(t.facture.id, false)), 'INVALID_AMOUNT');
  var u = await colis(4);
  await A.changerFraisService(u.facture.id, true);
  await encaisser(u.facture.id, 20, false);
  verifier('retirer après 20 $ payés : soldée d\'elle-même', etat((await A.changerFraisService(u.facture.id, false)).facture),
           [20, 0, 20, 0, 'payee', 'payee']);
  verifier('une facture payée : refusé', await code(A.changerFraisService(u.facture.id, true)), 'INVOICE_ALREADY_PAID');
  verifier('une facture annulée : refusé', await code(A.changerFraisService(a.facture.id, true)), 'INVOICE_CANCELLED');

  console.log('\n9. Sortir un colis d\'un regroupement : les frais ne se doublent pas');
  var v = await colis(4), w = await colis(3), x = await colis(2);
  var g9 = (await A.regrouper([v.facture.id, w.facture.id, x.facture.id], [], true)).facture;
  verifier('regroupées avec frais : 55 $', g9.montant_usd, 55);
  var so = await A.sortirDuRegroupement(g9.id, [v.colis.id], 'sortie-9');
  verifier('le colis sorti : 20 $ sans frais ; le reste : 35 $ avec',
           [so.facture.montant_usd, so.facture.frais_service_usd, so.reste.montant_usd, so.reste.frais_service_usd],
           [20, 0, 35, 10]);

  console.log('\n10. L\'ancien chemin (regrouperFactures) : frais une fois');
  var p = await colis(2), q = await colis(2);
  var old = (await A.regrouperFactures([p.facture.id, q.facture.id])).facture;
  verifier('10 + 10 + 10 de frais = 30 $', [old.montant_usd, old.frais_service_usd], [30, 10]);

  console.log('\n11. Les colis qu\'on peut ajouter');
  var c11a = await colis(2, { description: 'Baskets', suivi_transporteur: '1ZFRAIS0000456784' });
  var c11b = await colis(2, { description: 'Casque' }, true);
  var liste = await A.colisARegrouper(marie);
  var nums = liste.map(function (y) { return y.numero; });
  verifier('libres et regroupables : présents', [nums.indexOf(c11a.colis.numero) >= 0, nums.indexOf(c11b.colis.numero) >= 0],
           [true, true]);
  verifier('facture payée, facture avec paiement, autre client : absents',
           [nums.indexOf(d.colis.numero) >= 0, nums.indexOf(n.colis.numero) >= 0, nums.indexOf(chezJean.colis.numero) >= 0],
           [false, false, false]);
  var un11 = liste.filter(function (y) { return y.numero === c11a.colis.numero; })[0];
  verifier('chacun avec sa facture ou null', [un11.facture.numero, un11.facture.nb_colis,
           liste.filter(function (y) { return y.numero === c11b.colis.numero; })[0].facture], [c11a.facture.numero, 1, null]);
  verifier('recherche par suivi du vendeur', (await A.colisARegrouper(marie, 'frais0000456')).map(function (y) { return y.numero; }),
           [c11a.colis.numero]);
  verifier('recherche, sans les colis déjà dans la fenêtre', await A.colisARegrouper(marie, 'casque', [c11b.colis.id]), []);

  console.log('\n12. Un client ne touche à rien');
  await API.deconnecter();
  await API.connecter('marie-ange@exemple.com', 'demo1234');
  verifier('regrouper, encaisser, frais, recherche : refusés',
           [await code(A.regrouper([g6.id], [c11b.colis.id], true)), await code(encaisser(g6.id, 1, true)),
            await code(A.changerFraisService(g6.id, true)), await code(A.colisARegrouper(marie))],
           ['non-autorise', 'non-autorise', 'non-autorise', 'non-autorise']);
  await API.deconnecter();
  await API.connecter('admin@goship.demo', 'demo1234');

  console.log('\n13. Le rapport d\'anomalies');
  var rap = await A.anomaliesFacturation();
  verifier('aucune erreur', rap.filter(function (y) { return y.gravite === 'erreur'; }), []);
  // Les exemples de démonstration sont datés d'avant : seules comptent ici les factures de cet essai
  var neuves = [r1.facture.numero, fc.numero, g2.numero, t.facture.numero];
  verifier('les factures sans frais de cet essai ne sont pas signalées',
           rap.some(function (y) { return y.type === 'frais_absents' && neuves.indexOf(y.numero) >= 0; }), false);

  var ok = resultats.filter(Boolean).length;
  console.log('\n' + resultats.length + ' vérifications, ' + ok + ' réussies.');
  process.exit(ok === resultats.length ? 0 : 1);
})().catch(function (e) { console.error(e); process.exit(2); });
