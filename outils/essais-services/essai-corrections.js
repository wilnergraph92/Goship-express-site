/* ==========================================================================
   Goship Express — les corrections du 12/10/2026 en démonstration, hors navigateur
   ==========================================================================
   Rejoue sur la copie démo (assets/js/api.js) les cas de essai-corrections.py
   (outils/supabase-corrections.sql) : prix fixé sans poids, ville obligatoire,
   adresse de livraison, envois d'un colis, motif et rectification d'une facture,
   historique des modifications réservé à l'administrateur. Mêmes refus, mêmes codes.

     node outils/essais-services/essai-corrections.js
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
              (montre === undefined ? 'undefined' : montre.length > 60 ? montre.slice(0, 57) + '…' : montre));
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
  var clients = {};
  (await A.clients({ parPage: 50 })).lignes.forEach(function (c) { clients[c.email] = c.id; });
  var marie = clients['marie-ange@exemple.com'], jean = clients['jean-robert@exemple.com'];
  var base = { client_id: marie, description: 'Colis', poids_lb: 4, service: 'aerien', pays_destination: 'HT',
               destination: 'Jacmel' };
  function avec(x) {
    var c = Object.assign({}, base, x);
    Object.keys(c).forEach(function (k) { if (c[k] === undefined) delete c[k]; });
    return c;
  }

  console.log('1. Le prix fixé à la main');
  var r = await A.creerColis(avec({ description: 'Calculé' }));
  verifier('prix calculé, 4 lb : 20 $', [r.colis.prix_usd, r.colis.poids_lb], [20, 4]);
  verifier('prix calculé sans poids : refusé', await code(A.creerColis(avec({ poids_lb: null }))), 'INVALID_WEIGHT');
  verifier('poids 0 au prix fixé : refusé', await code(A.creerColis(avec({ poids_lb: 0, prix_fixe_usd: 30 }))),
           'INVALID_WEIGHT');
  verifier('poids négatif : refusé', await code(A.creerColis(avec({ poids_lb: -2 }))), 'INVALID_WEIGHT');
  var m2 = await A.creerColis(avec({ poids_lb: null, prix_fixe_usd: 40, description: 'Forfait sans poids' }));
  verifier('prix fixé SANS poids : enregistré, poids vide, 40 $, facture 40 $',
           [m2.colis.poids_lb, m2.colis.prix_usd, m2.facture.montant_usd], [null, 40, 40]);
  verifier('quitter le prix fixé sans poids : refusé',
           await code(A.modifierColis(m2.colis.id, { prix_fixe_usd: null })), 'INVALID_WEIGHT');
  var retour = await A.modifierColis(m2.colis.id, { prix_fixe_usd: null, poids_lb: 6 });
  verifier('… avec 6 lb : 30 $', retour.prix_usd, 30);
  await comme('employe');
  verifier('prix fixé par une employée : refusé',
           await code(A.creerColis(avec({ poids_lb: null, prix_fixe_usd: 40 }))), REFUS);
  await comme('admin');

  console.log('\n2. Les envois d\'un colis');
  var envois = await A.envoisColis(r.colis.id);
  verifier('« Colis reçu » : téléphone, e-mail, WhatsApp, non envoyés avec leur raison',
           envois.map(function (e) { return [e.type, e.canal, e.statut, e.code_erreur]; }).sort(),
           [['shipment_received', 'email', 'annule', 'NON_CONFIGURE'], ['shipment_received', 'push', 'annule', 'SANS_APPAREIL'],
            ['shipment_received', 'whatsapp', 'annule', 'NON_CONFIGURE']]);
  for (var role of ['gerant', 'employe']) {
    await comme(role);
    verifier(role + ' : lit les envois', await code(A.envoisColis(r.colis.id)), 'aucune');
  }
  await comme('client');
  verifier('client : refusé', await code(A.envoisColis(r.colis.id)), REFUS);
  await comme('admin');

  console.log('\n3. L\'historique des modifications');
  var c3 = (await A.creerColis(avec({ description: 'Chaussures' }))).colis;
  var m3 = await A.modifierColis(c3.id, { poids_lb: 5, destination: 'Léogâne', motif: 'Pesée refaite au dépôt' });
  verifier('modifié : 5 lb, 25 $, Léogâne', [m3.poids_lb, m3.prix_usd, m3.destination], [5, 25, 'Léogâne']);
  var h = await A.historiqueModifications({ recherche: c3.numero });
  var ligne = h.lignes.filter(function (l) { return l.action === 'colis.modification'; })[0];
  verifier('historique par numéro : avant / après, motif, auteur',
           [ligne.avant.poids_lb, ligne.apres.poids_lb, ligne.motif, ligne.role_auteur], [4, 5, 'Pesée refaite au dépôt', 'admin']);
  verifier('… seulement ce colis', h.lignes.every(function (l) { return l.reference === c3.numero; }), true);
  var libre = (await A.creerFacture({ client_id: jean, montant_usd: 50 }, [])).facture;
  await A.enregistrerPaiement(libre.id, { montant_usd: 20, moyen: 'especes' });
  verifier('montant corrigé sans motif : refusé', await code(A.modifierFacture(libre.id, { montant_usd: 45 })),
           'REASON_REQUIRED');
  verifier('… sous le payé : refusé avant de demander un motif',
           await code(A.modifierFacture(libre.id, { montant_usd: 10 })), 'INVALID_AMOUNT');
  verifier('… facture de colis : son total ne change pas',
           await code(A.modifierFacture(r.facture.id, { montant_usd: 5 })), 'INVOICE_LOCKED');
  var f3 = await A.modifierFacture(libre.id, { montant_usd: 45 }, 'Remise accordée au client');
  verifier('avec un motif : 45 $, payé 20 $ intact, rectifiée',
           [f3.montant_usd, f3.paye_usd, f3.paiements.length, !!f3.rectifiee_le], [45, 20, 1, true]);
  var hf = await A.historiqueModifications({ recherche: libre.numero, entite: 'facture' });
  verifier('journal de la facture : 50 → 45 et son motif',
           [hf.lignes[0].avant.montant_usd, hf.lignes[0].apres.montant_usd, hf.lignes[0].motif], [50, 45, 'Remise accordée au client']);
  verifier('lien de paiement non https : refusé',
           await code(A.modifierFacture(libre.id, { lien_paiement: 'http://exemple.com' })), 'INVALID_INPUT');
  verifier('par période : rien en 2020', (await A.historiqueModifications({ debut: '2020-01-01T04:00:00Z',
                                                                            fin: '2020-02-01T04:00:00Z' })).total, 0);
  verifier('objet inconnu : refusé', await code(A.historiqueModifications({ entite: 'client' })), 'INVALID_INPUT');
  for (var refuse of ['gerant', 'employe', 'client']) {
    await comme(refuse);
    verifier('historique : ' + refuse + ' refusé', await code(A.historiqueModifications({})), REFUS);
  }
  await comme('admin');

  console.log('\n4. La destination');
  verifier('sans ville : refusé', await code(A.creerColis(avec({ destination: '' }))), 'CITY_REQUIRED');
  verifier('ville faite d\'espaces : refusée', await code(A.creerColis(avec({ destination: '   ' }))), 'CITY_REQUIRED');
  verifier('pays inconnu : refusé', await code(A.creerColis(avec({ pays_destination: 'FR' }))), 'INVALID_DESTINATION');
  var c4 = (await A.creerColis(avec({ destination: ' Pétion-Ville ', adresse_livraison: '  Rue Lamarre, 12 ' }))).colis;
  verifier('ville et adresse de livraison nettoyées', [c4.destination, c4.adresse_livraison], ['Pétion-Ville', 'Rue Lamarre, 12']);
  verifier('changer de pays sans ville : refusé',
           await code(A.modifierColis(c4.id, { pays_destination: 'DO', destination: '' })), 'CITY_REQUIRED');
  var m4 = await A.modifierColis(c4.id, { adresse_livraison: 'Delmas 33', motif: 'Nouvelle adresse' });
  verifier('adresse modifiée, date d\'enregistrement inchangée', [m4.adresse_livraison, m4.cree_le === c4.cree_le],
           ['Delmas 33', true]);

  var ok = resultats.filter(Boolean).length;
  console.log('\n' + resultats.length + ' vérifications, ' + ok + ' réussies.');
  process.exit(ok === resultats.length ? 0 : 1);
})().catch(function (e) { console.error(e); process.exit(2); });
