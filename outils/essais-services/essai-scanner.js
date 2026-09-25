/* ==========================================================================
   Goship Express — le poste de scan, hors navigateur
   ==========================================================================
   1. Le lecteur de codes (assets/js/scan-parser.js) : chaque forme de code
      qu'un scanner peut taper, et ce qu'il doit en tirer — ou refuser sans
      rien demander au serveur.
   2. Le rythme des frappes : scanner ou personne.
   3. Les deux appels du poste en mode démonstration (assets/js/api.js) :
      mêmes réponses que la base (essai-scanner.py).

     node outils/essais-services/essai-scanner.js
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
var API = global.window.GoshipAPI, SCAN = global.window.GoshipScan;
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
function lu(texte) {
  var a = SCAN.analyser(texte);
  return a.ok ? a.type + ':' + a.reference : a.code;
}
function code(p) { return p.then(function () { return 'aucune'; }, function (e) { return e.code; }); }

(async function () {
  console.log('1. Ce que le scanner tape → la référence du colis');
  var cas = [
    ['Code128 de l\'étiquette', 'GSE-1001-HT', 'numero:GSE-1001-HT'],
    ['avec Entrée (CR/LF) et espaces', '  GSE-1001-HT\r\n', 'numero:GSE-1001-HT'],
    ['en minuscules', 'gse-1002-do', 'numero:GSE-1002-DO'],
    ['numéro tiré au hasard (8 chiffres)', 'GSE-48207391-US', 'numero:GSE-48207391-US'],
    ['QR de l\'étiquette (site en ligne)', 'https://www.goshipexpress.com/index.html?suivi=GSE-1001-HT', 'lien:GSE-1001-HT'],
    ['QR imprimé depuis un poste local', 'http://localhost:8000/index.html?suivi=GSE-1003-HT', 'lien:GSE-1003-HT'],
    ['QR en anglais (/en/)', 'https://www.goshipexpress.com/en/index.html?suivi=GSE-1004-DO', 'lien:GSE-1004-DO'],
    ['QR sans lien (site sans adresse)', 'GSE-1005-HT', 'numero:GSE-1005-HT'],
    ['lien avec le numéro encodé', 'https://x.com/index.html?suivi=GSE%2D1006%2DHT', 'lien:GSE-1006-HT'],
    ['lien avec le numéro après #', 'https://x.com/suivi.html#suivi=GSE-1007-HT', 'lien:GSE-1007-HT'],
    ['scanner QWERTY sur poste AZERTY', 'GSE)&àà&)HT', 'numero:GSE-1001-HT'],
    ['… avec un 6 (tapé « - »)', 'GSE)&-(-)DO', 'numero:GSE-1656-DO'],
    ['carton Amazon', 'TBA304918577000', 'suivi_vendeur:TBA304918577000'],
    ['carton UPS', '1z999aa10123456784', 'suivi_vendeur:1Z999AA10123456784'],
    ['carton SHEIN', 'GFUS01072196252801', 'suivi_vendeur:GFUS01072196252801'],
    ['USPS avec préfixe 420 + code postal', '420331669400111899223344556677', 'suivi_vendeur:9400111899223344556677'],
    ['USPS avec code postal à 9 chiffres', '420331661234' + '9400111899223344556677', 'suivi_vendeur:9400111899223344556677']
  ];
  cas.forEach(function (c) { verifier(c[0], lu(c[1]), c[2]); });
  var refus = [
    ['vide', ''], ['trop court', 'ABC'], ['GSE incomplet', 'GSE-10'], ['GSE sans pays', 'GSE-1001'],
    ['pays inconnu', 'GSE-1001-FR'], ['phrase', 'bonjour le monde'], ['que des lettres', 'ABCDEFGHIJ'],
    ['QR d\'une facture (PayPal)', 'https://www.paypal.com/cgi-bin/webscr?cmd=_xclick&amount=31.00'],
    ['lien sans numéro', 'https://www.goshipexpress.com/index.html'], ['lien javascript:', 'javascript:alert(1)'],
    ['beaucoup trop long', 'A1'.repeat(300)]
  ];
  refus.forEach(function (c) { verifier('refusé sans requête : ' + c[0], lu(c[1]), 'INVALID_SCAN_FORMAT'); });
  verifier('un vrai tiret reste un tiret (pas de correction à tort)', SCAN.corrigerClavier('GSE-1001-HT'), 'GSE-1001-HT');

  console.log('\n2. Scanner ou personne ?');
  function lecteur(ecarts) {
    var l = new SCAN.Lecteur(), t = 1000;
    ecarts.forEach(function (e) { t += e; l.noter(t); });
    return l.estScanner();
  }
  verifier('11 caractères en 110 ms : un scanner', lecteur([0, 10, 12, 9, 11, 10, 10, 12, 9, 10, 11]), true);
  verifier('11 caractères en 2 s : une personne', lecteur([0, 180, 210, 150, 190, 220, 170, 200, 180, 190, 200]), false);
  verifier('trop peu de caractères pour juger', lecteur([0, 10, 10]), false);

  console.log('\n3. Les deux appels du poste, en mode démonstration');
  var A = API.admin;
  await API.connecter('admin@goship.demo', 'demo1234');
  await A.exemples();
  var liste = (await A.colis({ statut: '' })).lignes;
  var recu = liste.filter(function (c) { return c.statut === 'recu'; })[0];
  var f = await A.scannerColis(recu.numero.toLowerCase());
  verifier('fiche trouvée, en minuscules', f.colis.numero, recu.numero);
  verifier('par le suivi du vendeur', (await A.scannerColis(recu.suivi_transporteur)).colis.id, recu.id);
  verifier('inconnu : réponse vide', await A.scannerColis('GSE-999999-HT'), null);
  verifier('opérations à « Reçu » : les mêmes que la base', f.operations.map(function (o) { return o.type; }),
           ['COLIS_INSPECTE', 'COLIS_EMBALLE', 'COLIS_CONSOLIDE', 'COLIS_CHARGE', 'COLIS_EXPEDIE', 'ACTION_REQUISE']);
  var r = await A.operationScanner(recu.numero, 'COLIS_EXPEDIE', { lieu: 'Miami', cle: 'k1', attendu: 'recu' });
  verifier('« Expédier » : fait, événement du scanner',
           [r.code, r.resultat.evenement.statut_precedent, r.resultat.evenement.statut, r.resultat.evenement.metadonnees.source,
            r.fiche.colis.statut], ['OK', 'recu', 'embarque', 'scanner', 'embarque']);
  var r2 = await A.operationScanner(recu.numero, 'COLIS_EXPEDIE', { lieu: 'Miami', cle: 'k2' });
  verifier('rescanné aussitôt : déjà fait, même événement', [r2.code, r2.resultat.evenement.id],
           ['ALREADY_IN_TARGET_STATE', r.resultat.evenement.id]);
  var r3 = await A.operationScanner(recu.numero, 'COLIS_EXPEDIE', { lieu: 'Miami', cle: 'k1', attendu: 'recu' });
  verifier('retry avec la même clé : même événement', [r3.code, r3.resultat.evenement.id],
           ['ALREADY_IN_TARGET_STATE', r.resultat.evenement.id]);
  verifier('livrer un colis embarqué : refusé', await code(A.operationScanner(recu.numero, 'COLIS_LIVRE', {})),
           'INVALID_STATUS_TRANSITION');
  verifier('corriger depuis le scanner : refusé', await code(A.operationScanner(recu.numero, 'CORRECTION', {})),
           'EVENT_TYPE_INVALID');
  verifier('colis inconnu : refusé', await code(A.operationScanner('GSE-999999-HT', 'COLIS_EXPEDIE', {})),
           'SHIPMENT_NOT_FOUND');
  verifier('statut affiché dépassé : conflit',
           await code(A.operationScanner(recu.numero, 'ACTION_REQUISE', { attendu: 'recu' })), 'STATUS_CONFLICT');
  await API.deconnecter();
  await API.connecter('marie-ange@exemple.com', 'demo1234');
  verifier('un client ne scanne pas', await code(A.scannerColis(recu.numero)), 'non-autorise');

  var n = resultats.filter(Boolean).length;
  console.log('\n' + resultats.length + ' vérifications, ' + n + ' réussies.');
  process.exit(n === resultats.length ? 0 : 1);
})().catch(function (e) { console.error(e); process.exit(2); });
