/* ==========================================================================
   Goship Express — les règles métier du mode démonstration, hors navigateur
   ==========================================================================
   Charge assets/js/api.js dans un navigateur minuscule (localStorage en
   mémoire, fichier ouvert « en local ») : il démarre donc en mode
   démonstration, et on y rejoue les cas de essai-services.py. Les deux
   implémentations doivent refuser les mêmes choses, avec les mêmes codes.

     node outils/essais-services/essai-demo.js            les cas, un par un
     node outils/essais-services/essai-demo.js --regles   la matrice, en JSON
     node outils/essais-services/essai-demo.js --paires   (entrée JSON) réponses
     node outils/essais-services/essai-demo.js --prix     (entrée JSON) prix

   Les trois dernières formes servent à essai-services.py, qui compare avec la
   base. Voir LISEZ-MOI.md.
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
// Le mode démonstration imite le délai d'un serveur : inutile ici
var attendre = global.setTimeout;
global.setTimeout = function (f) { return setImmediate(f); };

new Function(fs.readFileSync(path.join(__dirname, '..', '..', 'assets', 'js', 'api.js'), 'utf8'))();
var API = global.window.GoshipAPI;
global.setTimeout = attendre;

function lireEntree() { return JSON.parse(fs.readFileSync(0, 'utf8')); }
// Écriture immédiate : process.exit n'attend pas qu'un tuyau soit vidé, et
// couperait une longue réponse à 64 Ko.
function ecrire(texte) { fs.writeSync(1, texte); }

if (process.argv[2] === '--regles') {
  ecrire(JSON.stringify({ transitions: API.regles.transitions, tarifs: API.tarifs, statuts: API.statuts }));
  process.exit(0);
}
if (process.argv[2] === '--paires') {
  ecrire(JSON.stringify(lireEntree().map(function (p) {
    return API.regles.transitionPermise(p[0], p[1], p[2]);
  })));
  process.exit(0);
}
if (process.argv[2] === '--catalogue') {
  ecrire(JSON.stringify(API.regles.typesEvenement));
  process.exit(0);
}
// [de, vers, précédent] → « nature/type », comme nature_transition et type_pour_statut
if (process.argv[2] === '--nature') {
  ecrire(JSON.stringify(lireEntree().map(function (p) {
    return (API.regles.natureTransition(p[0], p[1], p[2]) || '-') + '/' + (API.regles.typePourStatut(p[0], p[1], p[2]) || '-');
  })));
  process.exit(0);
}
// [actuel, précédent, type, cible] → « code/cible », comme valider_operation
if (process.argv[2] === '--operations') {
  ecrire(JSON.stringify(lireEntree().map(function (p) {
    var v = API.regles.validerOperation(p[0], p[1], p[2], p[3]);
    return (v.code || 'ok') + '/' + (v.cible || '-');
  })));
  process.exit(0);
}
if (process.argv[2] === '--prix') {
  ecrire(JSON.stringify(lireEntree().map(function (p) { return API.regles.prixTransport(p[0], p[1]); })));
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

// Le code de l'erreur d'une promesse, ou « aucune »
function code(promesse) {
  return promesse.then(function () { return 'aucune'; }, function (e) { return e.code; });
}

(async function () {
  var A = API.admin;
  console.log('Mode : ' + API.mode);
  await API.connecter('admin@goship.demo', 'demo1234');
  await A.exemples();
  var clients = (await A.clients({})).lignes;
  var marie = clients.filter(function (c) { return c.email === 'marie-ange@exemple.com'; })[0].id;
  var jean = clients.filter(function (c) { return c.email === 'jean-robert@exemple.com'; })[0].id;
  var base = { client_id: marie, description: 'Chaussures Nike', expediteur: 'Amazon', poids_lb: 4.2,
               service: 'aerien', pays_destination: 'HT', destination: 'Pétion-Ville' };
  function avec(m) { return Object.assign({}, base, m); }

  console.log('\n1. Création d\'un colis');
  var r = await A.creerColis(avec({ suivi_transporteur: 'tba-1', prix_usd: 1, statut: 'livre' }), 'cle-1');
  var c = r.colis;
  verifier('statut initial « Reçu », même si la page envoie « Livré »', c.statut, 'recu');
  verifier('tarif de la maison : 5 $/lb', c.tarif_lb_usd, 5);
  verifier('prix calculé (4,2 × 5), pas celui envoyé', c.prix_usd, 21);
  verifier('facture créée avec lui : prix + 10 $',
           [r.facture.montant_usd, r.facture.frais_service_usd, r.facture.facture_lignes[0].montant_usd], [31, 10, 21]);
  verifier('un seul événement d\'historique', (await A.historique(c.id)).length, 1);

  console.log('\n2. Requête répétée');
  var r2 = await A.creerColis(avec({ suivi_transporteur: 'tba-1' }), 'cle-1');
  verifier('même clé : même colis, rien de créé', [r2.deja, r2.colis.id === c.id], [true, true]);
  verifier('même clé, autre client', await code(A.creerColis(avec({ client_id: jean }), 'cle-1')), 'DUPLICATE_OPERATION');
  verifier('suivi vendeur déjà pris', await code(A.creerColis(avec({ suivi_transporteur: 'TbA-1' }), 'cle-2')),
           'TRACKING_ALREADY_EXISTS');

  console.log('\n3. Validation');
  var cas = [['poids nul', { poids_lb: 0 }, 'INVALID_WEIGHT'], ['poids négatif', { poids_lb: -3 }, 'INVALID_WEIGHT'],
             ['poids absent', { poids_lb: null }, 'INVALID_WEIGHT'], ['poids illisible', { poids_lb: 'lourd' }, 'INVALID_WEIGHT'],
             ['poids de 45 000 lb', { poids_lb: 45000 }, 'INVALID_WEIGHT'], ['tarif négatif', { tarif_lb_usd: -1 }, 'INVALID_RATE'],
             ['tarif illisible', { tarif_lb_usd: 'x' }, 'INVALID_RATE'], ['description vide', { description: '  ' }, 'INVALID_DESCRIPTION'],
             ['client inconnu', { client_id: 'personne' }, 'CLIENT_NOT_FOUND'],
             ['compte de l\'équipe', { client_id: 'admin-demo' }, 'CLIENT_NOT_FOUND'],
             ['service inconnu', { service: 'fusee' }, 'INVALID_SERVICE'],
             ['destination inconnue', { pays_destination: 'FR' }, 'INVALID_DESTINATION'],
             ['réception dans le futur', { recu_le: '2099-01-01T00:00:00Z' }, 'INVALID_DATE']];
  for (var i = 0; i < cas.length; i++) verifier(cas[i][0], await code(A.creerColis(avec(cas[i][1]))), cas[i][2]);
  verifier('poids « 4,5 » avec une virgule accepté', (await A.creerColis(avec({ poids_lb: '4,5' }))).colis.prix_usd, 22.5);
  verifier('arrondi au cent : 2,25 × 1,5 → 3,38',
           (await A.creerColis(avec({ poids_lb: 2.25, tarif_lb_usd: 1.5 }))).colis.prix_usd, 3.38);

  console.log('\n4. Transitions');
  var id = c.id;
  function st(ids, vers, lieu, attendus, motif) {
    return A.changerStatut(ids, { statut: vers, lieu: lieu || '' }, attendus, motif);
  }
  verifier('Reçu → Livré : interdit', (await st([id], 'livre')).refus[0].code, 'INVALID_STATUS_TRANSITION');
  verifier('Reçu → Embarqué', (await st([id], 'embarque', 'Miami')).modifies, 1);
  verifier('Embarqué → Action requise', (await st([id], 'incident', 'Douane')).modifies, 1);
  verifier('Action requise → Livré : interdit', (await st([id], 'livre')).refus[0].code, 'INVALID_STATUS_TRANSITION');
  verifier('Action requise → Embarqué', (await st([id], 'embarque', 'Port-au-Prince')).modifies, 1);
  var poss = await A.statutsPossibles(id);
  verifier('statuts possibles depuis Embarqué (Reçu seulement en correction)', [poss.possibles.slice().sort(), poss.correction],
           [['disponible', 'distribution', 'embarque', 'incident', 'succursale'], 'recu']);
  verifier('Disponible sans agence', await code(st([id], 'disponible')), 'LOCATION_REQUIRED');
  verifier('Embarqué → Disponible → Livré',
           [(await st([id], 'disponible', 'Agence')).modifies, (await st([id], 'livre', 'Pétion-Ville')).modifies], [1, 1]);
  verifier('Livré → Disponible sans motif : refusé', (await st([id], 'disponible', 'Agence')).refus[0].code,
           'INVALID_EVENT_DATA');
  verifier('Livré → Disponible avec motif : correction', (await st([id], 'disponible', 'Agence', null, 'Erreur')).modifies, 1);
  var h = (await A.historique(id)).length;
  var rep = await st([id], 'disponible', 'Agence', { [id]: 'livre' });
  verifier('double clic : rien de réécrit', [rep.modifies, rep.inchanges, (await A.historique(id)).length], [0, 1, h]);
  verifier('conflit : la page affichait un autre statut',
           (await st([id], 'livre', 'X', { [id]: 'embarque' })).refus[0].code, 'STATUS_CONFLICT');

  var evts = await A.historique(id);
  var livre = evts.filter(function (e) { return e.type_evenement === 'COLIS_LIVRE'; })[0];
  var corr = evts.filter(function (e) { return e.type_evenement === 'CORRECTION'; })[0];
  verifier('historique : chaque étape a son type, son statut d\'avant, son auteur',
           evts.map(function (e) { return e.type_evenement + ':' + e.statut_precedent; }).slice(0, 3),
           ['COLIS_RECU:null', 'COLIS_EXPEDIE:recu', 'ACTION_REQUISE:embarque']);
  verifier('la correction désigne la livraison erronée, gardée et marquée', [corr.corrige_id === livre.id, livre.corrige],
           [true, true]);
  verifier('le suivi public ne montre plus la livraison annulée',
           (await API.suivre(c.numero)).historique.some(function (e) { return e.statut === 'livre'; }), false);
  var k = (await A.creerColis(avec({ description: 'Clé' }))).colis.id;
  var k1 = await A.changerStatut([k], { statut: 'embarque', lieu: 'Miami' }, { [k]: 'recu' }, null, 'lot-1');
  var k2 = await A.changerStatut([k], { statut: 'embarque', lieu: 'Miami' }, { [k]: 'recu' }, null, 'lot-1');
  verifier('même lot renvoyé avec la même clé : rien de refait', [k1.modifies, k2.modifies, k2.inchanges], [1, 0, 1]);

  console.log('\n5. Lot tout ou rien');
  var a = (await A.creerColis(avec({ description: 'Lot A' }))).colis.id;
  var b = (await A.creerColis(avec({ description: 'Lot B' }))).colis.id;
  await st([b], 'embarque', 'Miami');
  rep = await st([a, b], 'emballe', 'Miami');
  verifier('un bloquant : aucun ne change', [rep.modifies, rep.refus.length, rep.refus[0].id], [0, 1, b]);

  console.log('\n6. Modification');
  var m = await A.modifierColis(id, { description: 'Nike Air', prix_usd: 1 });
  verifier('description changée : prix inchangé', m.prix_usd, 21);
  m = await A.modifierColis(id, { poids_lb: '5,5' });
  verifier('poids changé : prix recalculé', m.prix_usd, 27.5);
  verifier('conflit de modification', await code(A.modifierColis(id, {}, '2020-01-01T00:00:00Z')),
           'CONCURRENT_MODIFICATION');

  console.log('\n7. Facturation');
  verifier('facturer un colis déjà facturé : la même', (await A.facturerColis(id)).deja, true);
  verifier('creer_facture avec lui : refusé', await code(A.creerFacture({ client_id: marie }, [id])), 'INVOICE_ALREADY_EXISTS');
  // Le tableau de bord facture chaque colis à son enregistrement : on annule
  // ces deux factures-là pour regrouper les colis sur une seule.
  for (var k of [a, b]) await A.modifierFacture((await A.factureDuColis(k)).id, { statut: 'annulee' });
  var fa = (await A.creerFacture({ client_id: marie, montant_usd: 1 }, [a, b], 'fac-1')).facture;
  verifier('deux colis : prix + 10 $ une fois', [fa.montant_usd, fa.frais_service_usd, fa.facture_lignes.length], [52, 10, 2]);
  verifier('même clé : même facture', (await A.creerFacture({ client_id: marie }, [a, b], 'fac-1')).facture.id, fa.id);
  var j = (await A.creerColis(avec({ client_id: jean, description: 'Colis de Jean' }))).colis.id;
  verifier('colis d\'un autre client', await code(A.creerFacture({ client_id: marie }, [j])), 'INVOICE_CLIENT_MISMATCH');
  verifier('facture libre sans colis : pas de frais',
           (await A.creerFacture({ client_id: jean, montant_usd: '12,5' }, [])).facture.frais_service_usd, 0);
  verifier('frais modifiés après coup', await code(A.modifierFacture(fa.id, { frais_service_usd: 0 })), 'INVOICE_LOCKED');
  verifier('total d\'une facture de colis modifié', await code(A.modifierFacture(fa.id, { montant_usd: 5 })), 'INVOICE_LOCKED');
  verifier('payé plus que le total', await code(A.modifierFacture(fa.id, { montant_paye_usd: 99 })), 'INVALID_AMOUNT');
  await A.modifierFacture(fa.id, { statut: 'annulee' });
  verifier('facture annulée : le colis se refacture', (await A.facturerColis(a)).deja, false);
  verifier('réactiver l\'ancienne doublerait', await code(A.modifierFacture(fa.id, { statut: 'a_payer' })),
           'INVOICE_ALREADY_EXISTS');

  console.log('\n8. Journal et permissions');
  var actions = (await A.journal({ parPage: 500 })).lignes.map(function (l) { return l.action; });
  verifier('créations, statuts, modifications, paiements journalisés',
           ['colis.creation', 'colis.statut', 'colis.modification', 'facture.creation', 'facture.paiement']
             .every(function (x) { return actions.indexOf(x) >= 0; }), true);
  await API.deconnecter();
  await API.connecter('marie-ange@exemple.com', 'demo1234');
  verifier('un client ne crée pas de colis', await code(A.creerColis(base)), 'non-autorise');
  verifier('ni ne change un statut', await code(A.changerStatut([id], { statut: 'livre' })), 'non-autorise');
  verifier('ni ne lit le journal', await code(A.journal()), 'non-autorise');
  verifier('ses colis seulement', (await API.mesColis()).every(function (x) { return x.id !== j; }), true);

  var n = resultats.filter(Boolean).length;
  console.log('\n' + resultats.length + ' vérifications, ' + n + ' réussies.');
  process.exit(n === resultats.length ? 0 : 1);
})().catch(function (e) { console.error(e); process.exit(2); });
