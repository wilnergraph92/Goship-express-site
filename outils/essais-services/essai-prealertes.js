/* ==========================================================================
   Goship Express — les pré-alertes vues par l'équipe (Palier A), hors navigateur
   ==========================================================================
   1. Le transporteur d'un suivi de vendeur (transporteur.js) : nommé seulement
      quand le numéro le prouve, jamais deviné.
   2. La lecture des pré-alertes en mode démonstration (api.js) : la liste de
      l'onglet, et celles d'un numéro scanné (aucune, une, plusieurs).
   3. Les permissions : l'équipe lit, un client ne lit pas par ce chemin.
   4. Le rapprochement : un colis enregistré pour le bon client et le même
      numéro fait passer SA pré-alerte à « reçue », et rien d'autre ne bouge —
      ni les pré-alertes des autres clients, ni les statuts ni l'historique des
      autres colis (la copie démo de rapprocher_prealerte, outils/supabase.sql).

     node outils/essais-services/essai-prealertes.js

   Le même contrat côté base, avec les vraies règles RLS et un vrai PostgREST :
   essai-prealertes.py.
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
var racine = path.join(__dirname, '..', '..', 'assets', 'js');
new Function(fs.readFileSync(path.join(racine, 'api.js'), 'utf8'))();
new Function(fs.readFileSync(path.join(racine, 'scan-parser.js'), 'utf8'))();
new Function(fs.readFileSync(path.join(racine, 'transporteur.js'), 'utf8'))();
var API = global.window.GoshipAPI, SCAN = global.window.GoshipScan, A = API.admin;
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
function donnees() { return JSON.parse(memoire['gse-demo-donnees']); }
function nomTransporteur(n) { var t = global.window.GoshipTransporteur(n); return t ? t.nom : null; }

(async function () {
  console.log('1. Le transporteur : seulement quand le numéro le prouve');
  [
    ['UPS, clé juste (exemple publié par UPS)', '1Z999AA10123456784', 'UPS'],
    ['UPS, même forme mais clé fausse', '1Z999AA10123456785', null],
    ['UPS en minuscules et avec des espaces', '1z 999 aa1 0123456784', 'UPS'],
    ['USPS, code IMpb à 22 chiffres, clé juste', '9400111899223399887764', 'USPS'],
    ['USPS, même forme mais clé fausse', '9400111899223399887765', null],
    ['USPS international (S10, exemple de l\'UPU)', 'EE123456785US', 'USPS'],
    ['S10 d\'un autre pays : pas l\'USPS', 'EE123456785FR', null],
    ['Amazon Logistics : TBA et 12 chiffres', 'TBA312345678901', 'Amazon Logistics'],
    ['TBA avec 11 chiffres : non déterminé', 'TBA31234567890', null],
    ['12 chiffres (FedEx ? autre ?) : non déterminé', '123456789012', null],
    ['SHEIN (GFUS…) : non déterminé', 'GFUS01072196299901', null],
    ['vide', '', null]
  ].forEach(function (c) { verifier(c[0], nomTransporteur(c[1]), c[2]); });

  console.log('\n2. La lecture : l\'onglet et le poste de scan');
  await API.connecter('admin@goship.demo', 'demo1234');
  await A.exemples();
  var d0 = donnees();
  var instantane = JSON.stringify({ colis: d0.colis, historique: d0.historique });
  var attente = await A.prealertes({ statut: 'attente' });
  verifier('en attente : 5 (dont 2 sans le même client)', attente.total, 5);
  verifier('les plus récentes d\'abord', attente.lignes.map(function (p) { return p.magasin; }),
           ['Temu', 'Target', 'Amazon', 'Walmart', 'SHEIN']);
  verifier('la ligne : à plat, client et colis compris', Object.keys(attente.lignes[0]).sort(),
           ['client_id', 'code_client', 'colis_id', 'cree_le', 'description', 'id', 'magasin', 'nom_client',
            'numero_colis', 'service', 'statut', 'statut_colis', 'suivi_transporteur', 'telephone_client',
            'valeur_usd'].sort());
  var recues = await A.prealertes({ statut: 'recu' });
  verifier('reçues : 1, avec le numéro de son colis', [recues.total, /^GSE-\d+-HT$/.test(recues.lignes[0].numero_colis)],
           [1, true]);
  verifier('annulées : 1', (await A.prealertes({ statut: 'annulee' })).total, 1);
  verifier('toutes : 7', (await A.prealertes({})).total, 7);
  verifier('statut inconnu : ignoré (toutes)', (await A.prealertes({ statut: 'nimporte' })).total, 7);
  verifier('recherche par magasin', (await A.prealertes({ recherche: 'walmart' })).lignes.map(function (p) { return p.nom_client; }),
           ['Jean-Robert Pierre']);
  verifier('recherche par nom du client', (await A.prealertes({ recherche: 'carolina' })).total, 2);
  var codeMarie = attente.lignes.filter(function (p) { return p.magasin === 'Amazon'; })[0].code_client;
  verifier('recherche par code client GSE', (await A.prealertes({ recherche: codeMarie })).total, 3);
  verifier('recherche par numéro de suivi', (await A.prealertes({ recherche: '99887764' })).total, 2);
  verifier('pagination : 2 par page', (await A.prealertes({ parPage: 2, page: 1 })).lignes.length, 2);

  var un = await A.prealertesDuSuivi('TBA312345678901');
  verifier('numéro annoncé par un seul client : une pré-alerte', un.map(function (p) { return p.nom_client; }),
           ['Marie-Ange Dorvil']);
  var plusieurs = await A.prealertesDuSuivi('9400111899223399887764');
  verifier('même numéro, deux clients : les deux, la plus ancienne d\'abord',
           plusieurs.map(function (p) { return p.nom_client; }), ['Jean-Robert Pierre', 'Carolina Méndez']);
  verifier('en minuscules, avec des espaces : mêmes pré-alertes', (await A.prealertesDuSuivi(' tba 3123 4567 8901 ')).length, 1);
  verifier('numéro inconnu : aucune', await A.prealertesDuSuivi('TBA999999999999'), []);
  verifier('numéro déjà rapproché de son colis : aucune en attente', await A.prealertesDuSuivi('1Z999AA10123456784'), []);
  verifier('… et le poste de scan trouve ce colis comme avant',
           (await A.scannerColis('1Z999AA10123456784')).colis.suivi_transporteur, '1Z999AA10123456784');
  verifier('numéro trop court : aucune, sans erreur', await A.prealertesDuSuivi('AB'), []);
  verifier('le poste de scan : un numéro sans colis reste « introuvable »', await A.scannerColis('TBA312345678901'), null);
  verifier('rien n\'a été écrit par ces lectures', JSON.stringify({ colis: donnees().colis, historique: donnees().historique }),
           instantane);

  console.log('\n3. Les permissions');
  for (var e of ['gerant@goship.demo', 'employe@goship.demo']) {
    await API.deconnecter();
    await API.connecter(e, 'demo1234');
    verifier(e.split('@')[0] + ' : lit les pré-alertes', (await A.prealertes({ statut: 'attente' })).total, 5);
    verifier(e.split('@')[0] + ' : lit celles d\'un numéro', (await A.prealertesDuSuivi('9400111899223399887764')).length, 2);
  }
  await API.deconnecter();
  await API.connecter('marie-ange@exemple.com', 'demo1234');
  verifier('un client : refusé (la liste de l\'équipe)', await code(A.prealertes({})), 'non-autorise');
  verifier('un client : refusé (le numéro d\'un autre)', await code(A.prealertesDuSuivi('9400111899223399887764')),
           'non-autorise');
  await API.deconnecter();
  verifier('personne de connecté : refusé', await code(A.prealertes({})), 'non-autorise');

  console.log('\n4. Le rapprochement, et rien d\'autre ne bouge');
  await API.connecter('employe@goship.demo', 'demo1234');
  var avant = donnees();
  var carolina = plusieurs[1], jean = plusieurs[0];
  var r = await A.creerColis({ client_id: carolina.client_id, suivi_transporteur: carolina.suivi_transporteur,
                               expediteur: carolina.magasin, description: carolina.description, poids_lb: 3,
                               service: 'aerien', pays_destination: 'DO', destination: 'Santiago de los Caballeros',
                               lieu: 'Miami (Medley), FL' }, 'essai-pa-1');
  var apres = donnees();
  var paCarolina = apres.prealertes.filter(function (p) { return p.id === carolina.id; })[0];
  var paJean = apres.prealertes.filter(function (p) { return p.id === jean.id; })[0];
  verifier('le colis naît « Reçu », comme toujours', r.colis.statut, 'recu');
  verifier('la pré-alerte de CE client passe à « reçue », liée au colis', [paCarolina.statut, paCarolina.colis_id],
           ['recu', r.colis.id]);
  verifier('celle de l\'autre client reste en attente, sans colis', [paJean.statut, paJean.colis_id], ['attente', null]);
  verifier('le numéro ne propose plus que l\'autre client', (await A.prealertesDuSuivi('9400111899223399887764'))
    .map(function (p) { return p.nom_client; }), ['Jean-Robert Pierre']);
  verifier('les autres colis : statuts inchangés', JSON.stringify(apres.colis.filter(function (c) { return c.id !== r.colis.id; })
    .map(function (c) { return [c.id, c.statut, c.lieu, c.maj_le]; })),
           JSON.stringify(avant.colis.map(function (c) { return [c.id, c.statut, c.lieu, c.maj_le]; })));
  verifier('l\'historique : les anciens événements intacts', JSON.stringify(apres.historique.slice(0, avant.historique.length)),
           JSON.stringify(avant.historique));
  verifier('… et un seul de plus : la réception du nouveau colis',
           apres.historique.slice(avant.historique.length).map(function (h) { return [h.type_evenement, h.colis_id]; }),
           [['COLIS_RECU', r.colis.id]]);
  verifier('les autres pré-alertes : inchangées', JSON.stringify(apres.prealertes.filter(function (p) { return p.id !== carolina.id; })),
           JSON.stringify(avant.prealertes.filter(function (p) { return p.id !== carolina.id; })));
  verifier('le même numéro pour l\'autre client : refusé par la règle des colis',
           await code(A.creerColis({ client_id: jean.client_id, suivi_transporteur: jean.suivi_transporteur, description: 'x',
                                     poids_lb: 1, pays_destination: 'HT', destination: 'Cap-Haïtien', lieu: 'Miami' })),
           'TRACKING_ALREADY_EXISTS');
  verifier('… et sa pré-alerte n\'a pas bougé', donnees().prealertes.filter(function (p) { return p.id === jean.id; })[0].statut,
           'attente');

  // Un colis enregistré pour un autre client que celui de la pré-alerte : aucun rapprochement
  var marie = un[0];
  var autreClient = avant.comptes.filter(function (c) { return c.role === 'client' && c.id !== marie.client_id; })[0];
  var r2 = await A.creerColis({ client_id: autreClient.id, suivi_transporteur: marie.suivi_transporteur, description: 'Écouteurs',
                                poids_lb: 1, pays_destination: autreClient.pays, destination: autreClient.ville,
                                lieu: 'Miami (Medley), FL' });
  verifier('colis du même numéro pour un AUTRE client : la pré-alerte reste en attente',
           donnees().prealertes.filter(function (p) { return p.id === marie.id; })[0].statut, 'attente');
  // Puis l'erreur se corrige depuis la fiche du colis : bon client → rapprochement (même déclencheur à la modification)
  var rapproche = await A.modifierColis(r2.colis.id, { client_id: marie.client_id, suivi_transporteur: marie.suivi_transporteur });
  verifier('client corrigé sur le colis : la pré-alerte passe à « reçue »',
           donnees().prealertes.filter(function (p) { return p.id === marie.id; })[0].colis_id, rapproche.id);

  await API.deconnecter();
  await API.connecter('admin@goship.demo', 'demo1234');
  await A.supprimerColis(r.colis.id);
  var supprimee = donnees().prealertes.filter(function (p) { return p.id === carolina.id; })[0];
  verifier('colis supprimé : la pré-alerte reste « reçue », sans colis (on delete set null)',
           [supprimee.statut, supprimee.colis_id], ['recu', null]);

  var n = resultats.filter(Boolean).length;
  console.log('\n' + resultats.length + ' vérifications, ' + n + ' réussies.');
  process.exit(n === resultats.length ? 0 : 1);
})().catch(function (e) { console.error(e); process.exit(2); });
