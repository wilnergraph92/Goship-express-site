/* ==========================================================================
   Goship Express — les notifications du mode démonstration, hors navigateur
   ==========================================================================
   Rejoue sur la copie démo (assets/js/api.js) les cas de essai-notifications.py
   qui ont un sens sans fournisseur : règles, idempotence, regroupement des
   paiements, lecture, préférences, permissions. Rien ne part en démonstration :
   chaque envoi dit pourquoi (non configuré, pas de téléphone, préférence).

     node outils/essais-services/essai-notifications.js            les cas
     node outils/essais-services/essai-notifications.js --modele   règles et textes (JSON)
     node outils/essais-services/essai-notifications.js --formes   clés des réponses (JSON)
          --modele et --formes servent à essai-notifications.py, qui compare
          avec la base.
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

if (process.argv[2] === '--modele') {
  fs.writeSync(1, JSON.stringify(API.regles.notifications));
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
var EQUIPE = { admin: 'admin@goship.demo', gerant: 'gerant@goship.demo', employe: 'employe@goship.demo',
               marie: 'marie-ange@exemple.com', jean: 'jean-robert@exemple.com' };
function comme(qui) {
  return API.deconnecter().then(function () { return API.connecter(EQUIPE[qui], 'demo1234'); });
}
function cles(o) { return Object.keys(o || {}).sort(); }

(async function () {
  var A = API.admin;
  await comme('admin');
  await A.exemples();
  var clients = {};
  (await A.clients({ parPage: 50 })).lignes.forEach(function (c) { clients[c.email] = c.id; });
  var base = { client_id: clients['marie-ange@exemple.com'], description: 'Chaussures', poids_lb: 4, service: 'aerien',
               pays_destination: 'HT', destination: 'Pétion-Ville' };
  var r = await A.creerColis(base);
  var c1 = r.colis;

  if (process.argv[2] === '--formes') {
    await A.changerStatut([c1.id], { statut: 'emballe' });
    var formes = {
      'centre': cles(await A.centreNotifications({})),
      'centre, élément': cles((await A.centreNotifications({})).elements[0]),
      'règles': cles(await A.reglesNotifications()),
      'règle': cles((await A.reglesNotifications()).regles[0]),
      'envois d\'un colis': cles((await A.envoisColis(c1.id))[0])
    };
    var n = (await A.centreNotifications({})).elements[0].notification_id;
    var s = await A.suiviNotification(n);
    formes['suivi'] = cles(s);
    formes['suivi, notification'] = cles(s.notification);
    formes['suivi, envoi'] = cles(s.envois[0]);
    await comme('marie');
    var m = await API.mesNotifications();
    formes['mes notifications'] = cles(m);
    formes['mes notifications, élément'] = cles(m.elements[0]);
    var p = await API.mesPreferencesNotifications();
    formes['préférences'] = cles(p);
    formes['préférences, catégorie'] = cles(p.preferences[0]);
    formes['préférences, canal'] = cles(p.canaux.push);
    fs.writeSync(1, JSON.stringify(formes));
    process.exit(0);
  }

  console.log('A. Un colis, ses étapes, ses notifications');
  await A.changerStatut([c1.id], { statut: 'emballe' });
  await A.changerStatut([c1.id], { statut: 'embarque' });
  await comme('marie');
  var m = await API.mesNotifications();
  verifier('reçu, emballé, expédié : trois notifications, la plus récente d\'abord',
           m.elements.filter(function (e) { return e.colis_id === c1.id; }).map(function (e) { return e.type; }),
           ['shipment_shipped', 'shipment_packed', 'shipment_received']);
  var recu = m.elements.filter(function (e) { return e.colis_id === c1.id && e.type === 'shipment_received'; })[0];
  verifier('texte traduit par la même table que la base', [recu.titre, recu.message],
           ['Colis reçu', 'Votre colis ' + c1.numero + ' a été reçu à notre entrepôt de Miami.']);
  verifier('dans la langue de l\'écran si on la donne',
           (await API.mesNotifications({ langue: 'ht' })).elements.filter(function (e) {
             return e.colis_id === c1.id && e.type === 'shipment_received'; })[0].titre, 'Koli resevwa');
  await comme('admin');
  var envois = await A.envoisColis(c1.id);
  verifier('rien ne part en démonstration : chaque envoi dit pourquoi',
           envois.filter(function (e) { return e.type === 'shipment_received'; }).map(function (e) {
             return e.canal + ':' + e.statut + ':' + e.code_erreur; }).sort(),
           ['email:annule:NON_CONFIGURE', 'push:annule:SANS_APPAREIL', 'whatsapp:annule:NON_CONFIGURE']);
  var avant = (await A.envoisColis(c1.id)).length;
  await A.changerStatut([c1.id], { statut: 'distribution' }, null, null, 'cle-rejeu');
  await A.changerStatut([c1.id], { statut: 'distribution' }, null, null, 'cle-rejeu');
  verifier('la même opération rejouée : une seule notification (un envoi, le téléphone)',
           (await A.envoisColis(c1.id)).length - avant, 1);

  console.log('B. Factures et paiements');
  var f = r.facture;
  await A.enregistrerPaiement(f.id, { montant_usd: 5, moyen: 'moncash' }, 'pay-demo-1');
  await A.enregistrerPaiement(f.id, { montant_usd: 5, moyen: 'moncash' }, 'pay-demo-1');
  var total = (await A.factures({ parPage: 500 })).lignes.filter(function (x) { return x.id === f.id; })[0].montant_usd;
  await A.enregistrerPaiement(f.id, { montant_usd: Math.round((total - 5) * 100) / 100, moyen: 'especes' });
  await comme('marie');
  var fac = (await API.mesNotifications({ parPage: 100 })).elements.filter(function (e) { return e.facture_id === f.id; });
  verifier('créée, un paiement (même clé deux fois), payée — le paiement qui solde regroupé',
           fac.map(function (e) { return e.type; }), ['invoice_paid', 'payment_received', 'invoice_created']);
  verifier('montant mis en forme comme dans la base',
           fac.filter(function (e) { return e.type === 'payment_received'; })[0].message,
           'Votre paiement de 5,00 $ sur la facture ' + f.numero + ' a été enregistré.');

  console.log('C. Lu, non lu, préférences');
  var tout = await API.mesNotifications({ parPage: 100 });
  verifier('badge : toutes non lues au départ', tout.non_lues, tout.total);
  verifier('marquer une notification', await API.marquerNotificationsLues([tout.elements[0].id]), 1);
  verifier('filtre « non lues »', (await API.mesNotifications({ filtre: 'non_lues', parPage: 100 })).total, tout.total - 1);
  await API.marquerNotificationsLues();
  verifier('tout marquer lu : badge à zéro', await API.notificationsNonLues(), 0);
  verifier('filtre inconnu refusé', await code(API.mesNotifications({ filtre: 'marketing' })), 'INVALID_FILTER');
  await API.reglerPreferenceNotification('colis', 'email', false);
  verifier('préférence enregistrée', (await API.mesPreferencesNotifications()).preferences[0],
           { categorie: 'colis', push: true, email: false, whatsapp: true, sms: true });
  verifier('réglage inconnu refusé', await code(API.reglerPreferenceNotification('marketing', 'email', false)), 'INVALID_PREFERENCE');
  await comme('admin');
  var r2 = await A.creerColis(base);
  var e2 = (await A.envoisColis(r2.colis.id)).filter(function (e) { return e.canal === 'email'; })[0];
  verifier('e-mail coupé par le client : envoi annulé (PREFERENCE)', [e2.statut, e2.code_erreur], ['annule', 'PREFERENCE']);
  await comme('jean');
  verifier('Jean ne voit rien des notifications de Marie',
           (await API.mesNotifications({ parPage: 100 })).elements.some(function (e) {
             return e.colis_id === c1.id || e.facture_id === f.id; }), false);
  var idsMarie = tout.elements.map(function (e) { return e.id; });
  verifier('Jean ne peut pas marquer « lu » celles de Marie', await API.marquerNotificationsLues(idsMarie), 0);

  console.log('D. L\'équipe');
  var droits = {};
  for (var role of ['employe', 'gerant', 'admin']) {
    await comme(role);
    droits[role] = [await code(A.centreNotifications({})), await code(A.reglesNotifications()),
                    await code(A.modifierRegleNotification('action_resolved', true, ['push'])),
                    await code(A.testerNotification('push'))];
  }
  verifier('employé : rien ; gérant : voir ; administrateur : voir, régler, tester', droits, {
    employe: ['non-autorise', 'non-autorise', 'non-autorise', 'non-autorise'],
    gerant: ['aucune', 'aucune', 'non-autorise', 'non-autorise'],
    admin: ['aucune', 'aucune', 'aucune', 'aucune']
  });
  verifier('essai : une fois par minute', await code(A.testerNotification('push')), 'TOO_MANY_TESTS');
  await A.modifierRegleNotification('shipment_packed', false, ['push']);
  var r3 = await A.creerColis(base);
  await A.changerStatut([r3.colis.id], { statut: 'emballe' });
  verifier('règle coupée : aucune notification « emballé »',
           (await A.envoisColis(r3.colis.id)).some(function (e) { return e.type === 'shipment_packed'; }), false);
  verifier('règle modifiable : canaux inconnus refusés',
           await code(A.modifierRegleNotification('shipment_packed', true, ['fax'])), 'INVALID_RULE');
  var regles = await A.reglesNotifications();
  verifier('règles : treize, SMS non configuré, modifiable pour l\'administrateur',
           [regles.regles.length, regles.canaux.sms, regles.modifiable], [13, false, true]);
  var centre = await A.centreNotifications({});
  verifier('centre : envois par canal, aucun « envoyé » en démonstration',
           [centre.envois > 0, centre.par_statut.envoye || 0], [true, 0]);

  console.log('\n' + resultats.filter(Boolean).length + ' / ' + resultats.length + ' réussies.');
  process.exit(resultats.every(Boolean) ? 0 : 1);
})().catch(function (e) { console.error(e); process.exit(1); });
