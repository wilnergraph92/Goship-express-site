/* ==========================================================================
   GoShip Express (bureau) — l'essai de l'application
   --------------------------------------------------------------------------
   Lance la vraie application (Electron, ce dossier) sur le site servi par
   serveur-essai.js — mode démonstration, jamais la base de production — et
   vérifie, sur Windows, macOS ou Linux :
     démarrage, pont (window.GoshipBureau) et rien d'autre dans la page ;
     session : clés refusées, rien en clair sur le disque ;
     sécurité : navigation, nouvelles fenêtres, schémas, CSP, permissions,
       messages IPC d'une autre page ;
     rôles : administrateur, employé (menus et refus de la base) ;
     raccourcis Ctrl/Cmd+K, Ctrl/Cmd+Maj+S (AZERTY, QWERTY, autre alphabet)
       et menu de l'application ;
     scanner : lecture au rythme d'un scanner, mode rapide sur trois colis,
       double scan, code illisible, colis inconnu, poste noté dans l'historique ;
     impression : fenêtre « Imprimer », aperçu, PDF 4×6 et A4, imprimante qui
       refuse puis « Réessayer » ;
     réseau : coupure et retour, serveur injoignable, « Réessayer ».

     npm run essai                 (Linux : xvfb-run -a npm run essai)
   ========================================================================== */
'use strict';

var path = require('path');
var fs = require('fs');
var os = require('os');
var electron = require('playwright-core')._electron;
var serveurEssai = require('./serveur-essai');

var BUREAU = path.resolve(__dirname, '..');
var PAQUET = require(path.join(BUREAU, 'package.json'));
var n = 0, bons = 0;
function ok(texte, vrai) { n++; if (vrai) bons++; console.log((vrai ? 'OK   ' : 'RATÉ ') + texte); }
function attendre(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
// GOSHIP_CAPTURES=dossier : des captures des fenêtres, pour les regarder
var CAPTURES = process.env.GOSHIP_CAPTURES || '';
function capturer(fenetre, nom) {
  return CAPTURES ? fenetre.screenshot({ path: path.join(CAPTURES, nom + '.png') }).catch(function () {}) : Promise.resolve();
}

// Lit la taille de la première page d'un PDF (MediaBox, en points)
function taillePdf(octets) {
  var m = /\/MediaBox\s*\[\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*\]/.exec(octets.toString('latin1'));
  return m ? [Math.round(m[3] - m[1]), Math.round(m[4] - m[2])] : null;
}

(async function () {
  var serveur = await serveurEssai.demarrer();
  var donnees = fs.mkdtempSync(path.join(os.tmpdir(), 'goship-bureau-essai-'));
  var app = await electron.launch({
    args: [BUREAU, '--env=local'].concat(process.platform === 'linux' ? ['--disable-gpu'] : []),
    env: Object.assign({}, process.env, { GOSHIP_DONNEES: donnees }),
    timeout: 60000
  });
  var erreurs = [];
  // Les ouvertures dans le navigateur sont notées, pas faites
  await app.evaluate(function (e) {
    global.__ouverts = [];
    e.shell.openExternal = function (u) { global.__ouverts.push(u); return Promise.resolve(); };
  });
  var ouverts = function () { return app.evaluate(function () { return global.__ouverts.slice(); }); };

  try {
    var page = await app.firstWindow();
    page.on('pageerror', function (e) { erreurs.push('page : ' + e.message); });
    await page.waitForLoadState('domcontentloaded');
    await page.waitForSelector('#adm-email', { timeout: 30000 });

    // ---- 1. Démarrage et pont ---------------------------------------------------
    ok('la fenêtre ouvre le tableau de bord du site : ' + page.url(), page.url() === 'http://localhost:8765/admin.html');
    var pont = await page.evaluate(function () {
      var b = window.GoshipBureau;
      return b && { contrat: b.contrat, version: b.version, plateforme: b.plateforme, env: b.environnement,
                    fonctions: Object.keys(b).sort().join(','), gele: Object.isFrozen(b) || !Object.getOwnPropertyDescriptor(window, 'GoshipBureau').writable };
    });
    ok('window.GoshipBureau : contrat 1, version ' + (pont && pont.version) + ', ' + (pont && pont.plateforme),
       pont && pont.contrat === 1 && pont.version === PAQUET.version && pont.env === 'local' &&
       pont.plateforme === ({ win32: 'windows', darwin: 'macos', linux: 'linux' }[process.platform]));
    ok('… et seulement : ' + (pont && pont.fonctions),
       pont && pont.fonctions === 'contrat,environnement,imprimer,journal,plateforme,sessionChiffree,stockageSession,surCommande,version');
    var nu = await page.evaluate(function () {
      return [typeof require, typeof process, typeof module, typeof window.ipcRenderer, typeof window.electron].join(',');
    });
    ok('rien de Node dans la page (require, process, module…) : ' + nu, nu === 'undefined,undefined,undefined,undefined,undefined');
    var journalApp = path.join(donnees, 'journaux', 'bureau.log');
    var journalTexte = fs.existsSync(journalApp) ? fs.readFileSync(journalApp, 'utf8') : '';
    ok('journal local : démarrage et page chargée notés', /démarrage 1\.\d+\.\d+/.test(journalTexte) && /page chargée : http:\/\/localhost:8765\/admin\.html/.test(journalTexte));

    // ---- 2. Session chiffrée -------------------------------------------------------
    var session = await page.evaluate(async function () {
      var S = window.GoshipBureau.stockageSession, r = {};
      await S.setItem('sb-essai-auth-token', '{"access_token":"jeton-secret-essai"}');
      r.relu = await S.getItem('sb-essai-auth-token');
      r.cleRefusee = await S.getItem('autre-cle').then(function () { return 'acceptée'; }, function () { return 'refusée'; });
      r.chiffree = await window.GoshipBureau.sessionChiffree();
      return r;
    });
    ok('session : relue telle quelle', session.relu === '{"access_token":"jeton-secret-essai"}');
    ok('session : une clé qui n\'est pas celle de Supabase est refusée', session.cleRefusee === 'refusée');
    var fichierSession = path.join(donnees, 'session.bin');
    var surDisque = fs.existsSync(fichierSession) ? fs.readFileSync(fichierSession).toString('latin1') : null;
    ok('session : ' + (session.chiffree ? 'chiffrée sur le disque (session.bin illisible)' : 'pas de coffre du système → rien sur le disque'),
       session.chiffree ? surDisque !== null && surDisque.indexOf('jeton-secret-essai') < 0 : surDisque === null);
    await page.evaluate(function () { return window.GoshipBureau.stockageSession.removeItem('sb-essai-auth-token'); });
    ok('jamais de jeton dans le journal', fs.readFileSync(journalApp, 'utf8').indexOf('jeton-secret-essai') < 0);

    // ---- 3. Connexion, rôles -------------------------------------------------------
    async function connecter(email) {
      await page.evaluate(function () { return window.GoshipAPI.deconnecter(); });
      await page.goto('http://localhost:8765/admin.html');
      await page.fill('#adm-email', email);
      await page.fill('#adm-mdp', 'demo1234');
      await page.click('form[data-form="admin-connexion"] button[type="submit"]');
      await page.waitForSelector('[data-ecran="tableau"]:not([hidden])', { timeout: 15000 });
      await attendre(800);
    }
    var onglets = function () {
      return page.$$eval('[data-onglet-vue]', function (b) { return b.filter(function (x) { return x.offsetWidth; }).map(function (x) { return x.getAttribute('data-onglet-vue'); }); });
    };
    await connecter('admin@goship.demo');
    ok('administrateur connecté : ' + (await onglets()).join(', '), (await onglets()).indexOf('analytics') >= 0 && (await onglets()).indexOf('equipe') >= 0);
    await page.click('[data-action="exemples"]');
    await attendre(1500);
    await capturer(page, 'bureau-tableau');

    // Chaque onglet, sous la Content-Security-Policy de l'application : aucune violation
    var analyticsAffichees = false;
    for (var vue of ['apercu', 'colis', 'clients', 'factures', 'analytics', 'scanner', 'equipe']) {
      await page.click('[data-onglet-vue="' + vue + '"]');
      await attendre(vue === 'analytics' ? 1500 : 600);
      if (vue === 'analytics') analyticsAffichees = await page.isVisible('[data-analytics-corps] .gs-kpi');
    }
    var journalOnglets = fs.readFileSync(journalApp, 'utf8');
    ok('les sept onglets sous la CSP (Analytics affichées) : aucune violation, aucune erreur de page',
       analyticsAffichees && !/Content Security Policy|ERREUR page/.test(journalOnglets));

    // ---- 4. Raccourcis et menu -------------------------------------------------------
    var actif = function () { return page.evaluate(function () { var a = document.activeElement; return a && (a.getAttribute('data-rapide-texte') !== null ? 'recherche' : a.getAttribute('data-scan-code') !== null ? 'scanner' : a.tagName); }); };
    var mod = process.platform === 'darwin' ? 'Meta' : 'Control';
    await page.keyboard.press(mod + '+K');
    ok(mod + '+K : la recherche rapide a le curseur', (await actif()) === 'recherche');
    await page.keyboard.press('Escape');
    await page.keyboard.press(mod + '+Shift+S');
    await attendre(300);
    ok(mod + '+Maj+S : le poste de scan s\'ouvre, prêt à lire', (await page.isVisible('[data-vue="scanner"]')) && (await actif()) === 'scanner');
    await page.click('[data-onglet-vue="colis"]');
    var clavier = await page.evaluate(function () {
      var r = [];
      [['k', 'KeyK'], ['л', 'KeyK']].forEach(function (t) {
        document.body.focus();
        document.dispatchEvent(new KeyboardEvent('keydown', { key: t[0], code: t[1], ctrlKey: true, bubbles: true, cancelable: true }));
        r.push(document.activeElement.getAttribute('data-rapide-texte') !== null);
      });
      return r;
    });
    ok('Ctrl+K par la lettre (AZERTY/QWERTY) et par la touche (autre alphabet)', clavier[0] && clavier[1]);
    await page.keyboard.press('Escape');
    await app.evaluate(function (e) {
      var fichier = e.Menu.getApplicationMenu().items.filter(function (i) { return i.label === 'Fichier'; })[0];
      fichier.submenu.items.filter(function (i) { return i.label === 'Poste de scan'; })[0].click();
    });
    await attendre(400);
    ok('menu Fichier > Poste de scan', await page.isVisible('[data-vue="scanner"]'));
    var menu = await app.evaluate(function (e) {
      return e.Menu.getApplicationMenu().items.map(function (i) { return i.label + ':' + i.submenu.items.filter(function (x) { return x.label; }).length; });
    });
    ok('menus : ' + menu.join(' '), menu.some(function (m) { return /^Fichier:/.test(m); }) && menu.some(function (m) { return /^Édition:/.test(m); }) &&
       menu.some(function (m) { return /^Affichage:/.test(m); }) && menu.some(function (m) { return /^Aide:/.test(m); }));

    // ---- 5. Scanner -------------------------------------------------------------------
    var colis = await page.evaluate(async function () {
      // Trois arrivées de plus : de quoi enchaîner le mode rapide
      var A = window.GoshipAPI;
      var client = (await A.admin.clients({})).lignes[0];
      for (var k = 1; k <= 3; k++) {
        await A.admin.creerColis({ client_id: client.id, description: 'Essai bureau ' + k, poids_lb: 2 + k, service: 'aerien',
                                   pays_destination: 'HT', suivi_transporteur: 'BUREAU-ESSAI-' + k }, 'cle-bureau-' + k);
      }
      var l = (await A.admin.colis({ statut: 'recu' })).lignes;
      return l.map(function (c) { return c.numero; });
    });
    async function scanner(code) {
      await page.focus('[data-scan-code]');
      await page.keyboard.type(code, { delay: 4 });           // le rythme d'un scanner
      await page.keyboard.press('Enter');
      await attendre(900);
      return (await page.textContent('[data-scan-etat]')).replace(/\s+/g, ' ').trim();
    }
    var premier = await scanner(colis[0]);
    ok('scan d\'un colis : ' + premier.slice(0, 70), premier.indexOf(colis[0]) >= 0);
    ok('le poste note la lecture du scanner', /dernière lecture reçue à \d\d:\d\d:\d\d/.test(await page.textContent('[data-scan-lecteur]')));
    await page.selectOption('[data-scan-mode]', 'COLIS_EMBALLE');
    var rapides = [];
    for (var i = 0; i < Math.min(3, colis.length); i++) rapides.push(await scanner(colis[i]));
    ok('mode rapide « Emballé » : ' + rapides.length + ' colis à la suite, sans question', rapides.length === 3 && rapides.every(function (t, k) { return t.indexOf(colis[k]) >= 0; }));
    var double = await scanner(colis[0]);
    ok('double scan : rien de neuf écrit → « ' + double.slice(0, 60) + ' »', /déjà|deja|aucun changement|inchang/i.test(double));
    var illisible = await scanner('%%%');
    ok('code illisible : refusé sans requête → « ' + illisible.slice(0, 60) + ' »', /illisible|invalide|reconn/i.test(illisible));
    var inconnu = await scanner('GSE-9999-HT');
    ok('colis inconnu → « ' + inconnu.slice(0, 60) + ' »', /aucun|introuvable|inconnu/i.test(inconnu));
    var poste = await page.evaluate(async function (numero) {
      var c = (await window.GoshipAPI.admin.colis({ recherche: numero })).lignes[0];
      var h = await window.GoshipAPI.admin.historique(c.id);
      var dernier = h.filter(function (x) { return x.type_evenement === 'COLIS_EMBALLE'; }).pop();
      return dernier && dernier.metadonnees;
    }, colis[0]);
    ok('l\'historique dit de quel poste vient le scan : ' + JSON.stringify(poste),
       poste && poste.source === 'scanner' && poste.poste === 'bureau' && poste.plateforme === pont.plateforme && poste.version_bureau === PAQUET.version);
    await page.selectOption('[data-scan-mode]', '');

    // ---- 6. Impression ------------------------------------------------------------------
    var pdfs = [];
    await app.evaluate(function (e, chemins) {
      var i = 0;
      e.dialog.showSaveDialog = function () { return Promise.resolve({ canceled: false, filePath: chemins[i++] }); };
    }, [path.join(donnees, 'doc-1.pdf'), path.join(donnees, 'doc-2.pdf')]);
    async function fenetreImprimer(declencher) {
      await declencher();
      var f = null;
      for (var essai = 0; essai < 100 && !f; essai++) {
        f = app.windows().filter(function (w) { return /ui\/impression\.html$/.test(w.url()); })[0] || null;
        if (!f) await attendre(200);
      }
      if (!f) throw new Error('pas de fenêtre « Imprimer »');
      await f.waitForLoadState('domcontentloaded');
      await f.waitForSelector('[data-apercu]:not([hidden])', { timeout: 20000 });
      return f;
    }
    await page.click('[data-onglet-vue="colis"]');
    await attendre(500);
    var imp = await fenetreImprimer(function () { return page.click('[data-vue="colis"] tbody button:has-text("Étiquette")'); });
    await attendre(800);
    await capturer(imp, 'bureau-imprimer');
    ok('étiquette → fenêtre « Imprimer » avec aperçu : ' + (await imp.textContent('[data-format]')), /4 × 6/.test(await imp.textContent('[data-format]')));
    var imprimantes = await imp.$$eval('[data-imprimante] option', function (o) { return o.map(function (x) { return x.value; }); });
    ok('imprimantes du système listées (' + imprimantes.filter(Boolean).length + ')', Array.isArray(imprimantes));
    await imp.click('[data-pdf]');
    await imp.waitForSelector('[data-etat]:has-text("PDF enregistré")', { timeout: 20000 });
    var pdf1 = fs.readFileSync(path.join(donnees, 'doc-1.pdf'));
    ok('étiquette en PDF : ' + taillePdf(pdf1) + ' pt (4 × 6 po = 288 × 432)', pdf1.slice(0, 4).toString() === '%PDF' && String(taillePdf(pdf1)) === '288,432');
    // Une imprimante qui refuse : le message le dit, « Réessayer » apparaît
    await imp.evaluate(function () {
      var s = document.querySelector('[data-imprimante]');
      s.disabled = false; s.add(new Option('Imprimante absente', 'Imprimante-absente-essai')); s.value = 'Imprimante-absente-essai';
      document.querySelector('[data-imprimer]').disabled = false;
    });
    await imp.click('[data-imprimer]');
    await imp.waitForSelector('[data-etat].message--erreur', { timeout: 20000 });
    ok('imprimante qui refuse : « ' + (await imp.textContent('[data-etat]')).slice(0, 60) + '… » et « ' + (await imp.textContent('[data-imprimer]')) + ' »',
       /Impression échouée/.test(await imp.textContent('[data-etat]')) && (await imp.textContent('[data-imprimer]')) === 'Réessayer');
    await imp.click('[data-fermer]');
    await attendre(500);
    await page.click('[data-onglet-vue="factures"]');
    await attendre(1200);
    var imp2 = await fenetreImprimer(function () { return page.click('[data-vue="factures"] tbody button:has-text("Imprimer")'); });
    await imp2.click('[data-pdf]');
    await imp2.waitForSelector('[data-etat]:has-text("PDF enregistré")', { timeout: 20000 });
    var pdf2 = fs.readFileSync(path.join(donnees, 'doc-2.pdf'));
    ok('facture en PDF : ' + taillePdf(pdf2) + ' pt (A4 = 595 × 842)', String(taillePdf(pdf2)) === '595,842');
    await imp2.keyboard.press('Escape').catch(function () { /* la fenêtre se ferme pendant la frappe */ });
    await attendre(500);
    ok('fenêtre « Imprimer » fermée, retour au tableau de bord', app.windows().length === 1);

    // ---- 7. Sécurité ----------------------------------------------------------------------
    var avant = (await ouverts()).length;
    await page.evaluate(function () { window.open('https://wa.me/18495386262?text=essai', '_blank'); });
    await page.evaluate(function () { window.open('javascript:alert(1)'); });
    await attendre(500);
    ok('window.open : aucune fenêtre dans l\'application', app.windows().length === 1);
    var liste = (await ouverts()).slice(avant);
    ok('… WhatsApp s\'ouvre dans le navigateur, javascript: nulle part : ' + liste.join(' | '),
       liste.length === 1 && /^https:\/\/wa\.me\//.test(liste[0]));
    await page.evaluate(function () { location.href = 'index.html'; });
    await attendre(800);
    ok('une autre page du site (accueil) : dans le navigateur, pas dans l\'application', page.url().indexOf('/admin.html') > 0 && (await ouverts()).pop() === 'http://localhost:8765/index.html');
    await page.evaluate(function () { location.href = 'file:///etc/hosts'; });
    await attendre(500);
    ok('file:// : refusé, ni ouvert ni affiché', page.url().indexOf('/admin.html') > 0 && (await ouverts()).pop() !== 'file:///etc/hosts');
    // La politique se vérifie par ce que le navigateur refuse (les rapports de
    // violation), pas par page.evaluate, que les outils de développement exemptent
    var csp = await page.evaluate(function () {
      return new Promise(function (fin) {
        var refus = [];
        document.addEventListener('securitypolicyviolation', function (e) { refus.push(e.violatedDirective + ' ' + (e.blockedURI || 'inline')); });
        var a = document.createElement('script'); a.textContent = 'window.__injecte = 1'; document.head.appendChild(a);
        var b = document.createElement('script'); b.src = 'data:text/javascript,window.__data=1'; document.head.appendChild(b);
        var c = document.createElement('script'); c.src = 'https://exemple.invalid/x.js'; document.head.appendChild(c);
        setTimeout(function () { fin({ refus: refus, injecte: window.__injecte, data: window.__data }); }, 800);
      });
    });
    ok('Content-Security-Policy : script injecté, data: et domaine inconnu refusés (' + csp.refus.length + ' refus : ' + csp.refus.join(' · ') + ')',
       csp.refus.length === 3 && csp.refus.every(function (r) { return /^script-src/.test(r); }) && !csp.injecte && !csp.data);
    var droits = await page.evaluate(async function () {
      var r = {};
      r.notifications = (await navigator.permissions.query({ name: 'notifications' })).state;
      try { await navigator.mediaDevices.getUserMedia({ video: true }); r.camera = 'accordée'; } catch (e) { r.camera = 'refusée'; }
      try {
        await new Promise(function (ok2, ko) { navigator.geolocation.getCurrentPosition(ok2, ko, { timeout: 3000 }); });
        r.position = 'accordée';
      } catch (e) { r.position = e && e.code === 1 ? 'refusée' : 'indisponible (' + (e && e.code) + ')'; }
      r.hid = navigator.hid ? (await navigator.hid.getDevices()).length : 0;
      return r;
    });
    ok('permissions : notifications ' + droits.notifications + ', caméra ' + droits.camera + ', position ' + droits.position + ', HID ' + droits.hid,
       droits.notifications === 'granted' && droits.camera === 'refusée' && droits.position === 'refusée' && droits.hid === 0);

    // ---- 8. Réseau ---------------------------------------------------------------------------
    var cdp = await page.context().newCDPSession(page);
    await cdp.send('Network.enable');
    await cdp.send('Network.emulateNetworkConditions', { offline: true, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
    await attendre(500);
    ok('réseau coupé : « Connexion perdue » affiché', await page.isVisible('[data-hors-ligne]'));
    await cdp.send('Network.emulateNetworkConditions', { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
    await attendre(500);
    ok('réseau revenu : bandeau retiré, « Connexion rétablie »', !(await page.isVisible('[data-hors-ligne]')) && /Connexion rétablie/.test(await page.textContent('[data-toast]')));
    await app.evaluate(function (e) { e.BrowserWindow.getAllWindows()[0].webContents.loadURL('http://127.0.0.1:65530/admin.html'); });
    for (var t = 0; t < 100 && !/hors-ligne\.html/.test(page.url()); t++) await attendre(200);
    await page.waitForSelector('[data-reessayer]', { timeout: 10000 });
    await capturer(page, 'bureau-hors-ligne');
    ok('serveur injoignable : « ' + (await page.textContent('[data-titre]')) + ' »', /indisponible/.test(await page.textContent('[data-titre]')));
    var horsLigne = await page.evaluate(function () { return [typeof window.GoshipBureau, typeof window.GoshipHorsLigne].join(','); });
    ok('page locale : pas de pont vers la session ni l\'impression (' + horsLigne + ')', horsLigne === 'undefined,object');
    await page.click('[data-reessayer]');
    await page.waitForURL('http://localhost:8765/admin.html', { timeout: 20000 });
    await page.waitForSelector('[data-ecran="tableau"]:not([hidden])', { timeout: 20000 });
    ok('« Réessayer » : retour au tableau de bord, session gardée', true);

    // ---- 9. Gérant, employé
    await connecter('gerant@goship.demo');
    var gerant = await onglets();
    ok('gérant : ' + gerant.join(', ') + ' — Analytics compris', gerant.indexOf('analytics') >= 0 && gerant.indexOf('factures') >= 0);
    await connecter('employe@goship.demo');
    var employe = await onglets();
    ok('employé : ' + employe.join(', ') + ' — ni Analytics ni Équipe', employe.indexOf('analytics') < 0 && employe.indexOf('equipe') < 0 && employe.indexOf('scanner') >= 0);
    var refus = await page.evaluate(function () { return window.GoshipAPI.admin.analytics('finances', {}).then(function () { return 'ouvert'; }, function (e) { return e.code; }); });
    ok('employé : la base refuse les Analytics (' + refus + ')', refus === 'non-autorise');
    await page.keyboard.press(mod + '+Shift+S');
    await attendre(300);
    ok('employé : ' + mod + '+Maj+S ouvre le poste de scan (permission shipments.scan)', await page.isVisible('[data-vue="scanner"]'));

    ok('aucune erreur de page' + (erreurs.length ? ' → ' + erreurs.join(' | ') : ''), !erreurs.length);
  } catch (err) {
    ok('essai interrompu : ' + (err && err.stack || err), false);
  } finally {
    await app.close().catch(function () {});
    serveur.close();
  }
  console.log('\n' + bons + ' / ' + n + ' vérifications (' + process.platform + ' ' + process.arch + ').');
  process.exit(bons === n ? 0 : 1);
})();
