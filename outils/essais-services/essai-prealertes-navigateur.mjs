// Éprouve, dans un vrai navigateur et en mode démonstration, le Palier A du suivi universel :
// l'onglet « Pré-alertes » du tableau de bord, et le poste de scan qui consulte les
// pré-alertes quand le numéro d'un vendeur n'est pas encore un colis (aucune, une,
// plusieurs : l'employé choisit), puis le colis enregistré pour le client choisi.
//
// Aucun appel à Supabase : config.js est remplacé par une configuration vide (le mode démo
// s'active tout seul), comme le demande le CLAUDE.md, et toute requête vers supabase.co est
// coupée (et comptée). Le site est servi par un serveur statique :
//
//     cd <racine du site> && python3 -m http.server 8765 --bind 127.0.0.1 &
//     node outils/essais-services/essai-prealertes-navigateur.mjs
//
// CAPTURES=<dossier> enregistre les captures d'écran. Playwright n'est pas une dépendance du
// site : GOSHIP_PLAYWRIGHT donne son chemin (sinon le module « playwright » de la machine).
import { createRequire } from 'node:module';

const exiger = createRequire(import.meta.url);
const { chromium } = exiger(process.env.GOSHIP_PLAYWRIGHT || 'playwright');
const SITE = process.env.SITE || 'http://127.0.0.1:8765';
const CAPTURES = process.env.CAPTURES || '';
const resultats = [];
let appelsSupabase = 0;
const erreursJs = [];

function verifier(titre, obtenu, attendu) {
  const bon = JSON.stringify(obtenu) === JSON.stringify(attendu);
  console.log('  ' + (bon ? 'OK  ' : 'RATÉ') + ' ' + titre.padEnd(76) + ' ' + (bon ? '' : JSON.stringify(obtenu)));
  if (!bon) console.log('       attendu : ' + JSON.stringify(attendu));
  resultats.push(bon);
}

async function capture(page, nom) {
  if (CAPTURES) await page.screenshot({ path: `${CAPTURES}/${nom}.png`, fullPage: false });
}

async function contexte(navigateur, largeur, hauteur) {
  const ctx = await navigateur.newContext({ viewport: { width: largeur, height: hauteur }, locale: 'fr-FR',
                                            deviceScaleFactor: CAPTURES ? 2 : 1 });
  await ctx.route('**/assets/js/config.js', (r) => r.fulfill({ contentType: 'application/javascript', body: 'window.GOSHIP_CONFIG={};' }));
  await ctx.route(/supabase\.co/, (r) => { appelsSupabase++; return r.abort(); });
  await ctx.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  return ctx;
}

async function connecter(page, email) {
  await page.goto(SITE + '/admin.html');
  await page.waitForSelector('[data-form="admin-connexion"]', { state: 'visible' });
  await page.fill('#adm-email', email);
  await page.fill('#adm-mdp', 'demo1234');
  await page.click('[data-form="admin-connexion"] [data-envoyer]');
  await page.waitForSelector('[data-ecran="tableau"]:not([hidden])');
}

async function onglet(page, vue) {
  await page.click(`[data-onglet-vue="${vue}"]`);
  await page.waitForSelector(`[data-vue="${vue}"]:not([hidden])`);
}

async function lignesPrealertes(page) {
  await page.waitForFunction(() => !document.querySelector('[data-vue="prealertes"]').hasAttribute('aria-busy'));
  return page.$$eval('[data-lignes="prealertes"] tr', (trs) => trs.map((tr) => Array.from(tr.cells).map((td) => td.innerText.trim())));
}

async function scanner(page, code) {
  await page.fill('[data-scan-code]', code);
  await page.press('[data-scan-code]', 'Enter');
  await page.waitForFunction(() => {
    const t = document.querySelector('[data-scan-titre]').textContent;
    return !/Recherche|Enregistrement|Prêt/.test(t);
  });
  // la recherche des pré-alertes suit l'« introuvable » : on attend que le poste soit libre
  await page.waitForTimeout(700);
  return page.$eval('[data-scan-titre]', (n) => n.textContent.trim());
}

const navigateur = await chromium.launch({ executablePath: process.env.CHROMIUM, args: ['--no-sandbox'] });
try {
  const ctx = await contexte(navigateur, 1440, 960);
  const page = await ctx.newPage();
  page.on('pageerror', (e) => erreursJs.push(String(e)));
  page.on('console', (m) => { if (m.type() === 'error' && !/supabase|fonts|ERR_FAILED/.test(m.text())) erreursJs.push(m.text()); });

  console.log('1. L\'onglet « Pré-alertes » (administrateur)');
  await connecter(page, 'admin@goship.demo');
  await page.evaluate(() => window.GoshipAPI.admin.exemples());
  await page.reload();
  await page.waitForSelector('[data-ecran="tableau"]:not([hidden])');
  verifier('l\'onglet est dans le menu « Opérations », après le scanner',
    await page.$$eval('[aria-labelledby="menu-operations"] [data-onglet-vue]', (b) => b.map((x) => x.getAttribute('data-onglet-vue'))),
    ['apercu', 'colis', 'scanner', 'prealertes', 'suivi', 'clients']);
  await onglet(page, 'prealertes');
  let lignes = await lignesPrealertes(page);
  verifier('5 pré-alertes en attente', lignes.length, 5);
  verifier('le nombre en attente à côté du nom de l\'onglet', await page.$eval('[data-total="prealertes"]', (n) => n.textContent), '5');
  verifier('le transporteur : nommé seulement quand le numéro le prouve',
    lignes.map((l) => l[0].split('\n').pop()),
    ['Sans numéro', 'USPS', 'Amazon Logistics', 'USPS', 'Transporteur non déterminé']);
  verifier('chaque ligne en attente a « Enregistrer le colis »',
    await page.$$eval('[data-lignes="prealertes"] [data-prealerte-colis]', (b) => b.length), 5);
  verifier('le titre de la vue', await page.$eval('[data-titre-vue]', (n) => n.textContent), 'Pré-alertes');
  await capture(page, '1-prealertes-en-attente');

  await page.selectOption('[data-filtre-prealertes]', 'recu');
  lignes = await lignesPrealertes(page);
  verifier('« Reçues » : la pré-alerte rapprochée, avec le numéro de son colis', [lignes.length, /Colis GSE-\d+-HT/.test(lignes[0][4])], [1, true]);
  await page.fill('[data-recherche-prealertes]', 'Carolina');
  await page.selectOption('[data-filtre-prealertes]', '');
  await page.waitForTimeout(500);
  lignes = await lignesPrealertes(page);
  verifier('recherche par nom du client (toutes)', lignes.map((l) => l[2].split('\n')[0]), ['Target', 'SHEIN']);
  await page.fill('[data-recherche-prealertes]', '');
  await page.selectOption('[data-filtre-prealertes]', 'attente');
  await page.waitForTimeout(700);
  await lignesPrealertes(page);
  await page.click('[data-lignes="prealertes"] tr:nth-child(2) td:nth-child(3)');
  await page.waitForSelector('dialog[data-dialogue="fiche"][open]');
  verifier('un clic sur la ligne ouvre sa fiche « Pré-alerte »',
    await page.$eval('dialog[data-dialogue="fiche"]', (d) => [d.textContent.includes('Pré-alerte'), d.textContent.includes('9400111899223399887764'),
      d.textContent.includes('Enregistrer le colis')]), [true, true, true]);
  await capture(page, '2-fiche-prealerte');
  await page.keyboard.press('Escape');

  console.log('\n2. Le poste de scan');
  await onglet(page, 'scanner');
  const avant = await page.evaluate(() => JSON.parse(localStorage.getItem('gse-demo-donnees')));
  verifier('numéro annoncé par un seul client : « pré-alerte trouvée »', await scanner(page, 'TBA312345678901'),
    'ℹ PAS ENCORE DE COLIS : PRÉ-ALERTE TROUVÉE');
  verifier('… une carte : le client, son code, le magasin, le transporteur',
    await page.$eval('[data-scan-fiche]', (f) => [f.querySelectorAll('[data-scan-prealerte]').length,
      /Marie-Ange Dorvil · GSE-\d+/.test(f.innerText), f.innerText.includes('Amazon'), f.innerText.includes('Amazon Logistics')]),
    [1, true, true, true]);
  verifier('… ni téléphone ni adresse du client (comme la fiche du poste)',
    await page.$eval('[data-scan-fiche]', (f) => /\+509|Téléphone|Rue/.test(f.innerText)), false);
  await capture(page, '3-scan-une-prealerte');

  verifier('même numéro annoncé par deux clients : « choisissez le client »', await scanner(page, '9400111899223399887764'),
    '⚠ PLUSIEURS PRÉ-ALERTES : CHOISISSEZ LE CLIENT');
  const cartes = await page.$$eval('[data-scan-prealerte]', (l) => l.map((x) => x.innerText.split('\n').find((t) => /·/.test(t))));
  verifier('… les deux clients, chacun avec « Choisir ce client »',
    [cartes.length, await page.$$eval('[data-scan-choisir]', (b) => b.map((x) => x.textContent))],
    [2, ['Choisir ce client', 'Choisir ce client']]);
  await capture(page, '4-scan-plusieurs-prealertes');
  const apresLecture = await page.evaluate(() => JSON.parse(localStorage.getItem('gse-demo-donnees')));
  verifier('scanner et lire n\'ont rien écrit (colis, historique, pré-alertes)',
    JSON.stringify([apresLecture.colis, apresLecture.historique, apresLecture.prealertes]),
    JSON.stringify([avant.colis, avant.historique, avant.prealertes]));

  // L'employé choisit Carolina : le formulaire s'ouvre rempli
  await page.click('[data-scan-prealerte]:nth-child(2) [data-scan-choisir]');
  await page.waitForSelector('dialog[data-dialogue="colis"][open]');
  await page.waitForTimeout(600);
  const champs = await page.$eval('form[data-form="colis"]', (f) => ({
    code: f.elements.code.value, suivi: f.elements.suivi_transporteur.value, magasin: f.elements.expediteur.value,
    contenu: f.elements.description.value, lieu: f.elements.lieu.value }));
  verifier('le formulaire « Enregistrer un colis » : client, numéro, magasin, contenu repris',
    [/^GSE-\d+$/.test(champs.code), champs.suivi, champs.magasin, champs.contenu, champs.lieu],
    [true, '9400111899223399887764', 'Target', 'Jouets pour enfants', '']);
  verifier('… le client trouvé est bien Carolina',
    await page.$eval('[data-client-trouve]', (n) => n.innerText.includes('Carolina')), true);
  await capture(page, '5-formulaire-prerempli');
  await page.fill('#col-poids', '3');
  if (await page.$('form[data-form="colis"] [name="pays_destination"]')) {
    await page.selectOption('form[data-form="colis"] [name="pays_destination"]', 'DO');
  }
  await page.fill('#col-dest', 'Santiago de los Caballeros');
  await page.fill('#col-lieu', 'Miami (Medley), FL');
  await page.uncheck('form[data-form="colis"] [name="prevenir"]');
  await page.click('form[data-form="colis"] [data-envoyer]');
  await page.waitForFunction(() => !document.querySelector('dialog[data-dialogue="colis"]').open);
  await page.waitForFunction(() => /COLIS TROUVÉ/.test(document.querySelector('[data-scan-titre]').textContent), null, { timeout: 8000 });
  verifier('enregistré : le poste montre aussitôt le nouveau colis « Reçu »',
    await page.$eval('[data-scan-fiche]', (f) => [/GSE-\d+-DO/.test(f.innerText), f.innerText.includes('USPS')]), [true, true]);
  await capture(page, '6-colis-enregistre');
  const apres = await page.evaluate(() => JSON.parse(localStorage.getItem('gse-demo-donnees')));
  const nouveau = apres.colis.filter((c) => !avant.colis.some((a) => a.id === c.id));
  verifier('un seul colis de plus, pour Carolina, statut « recu »', nouveau.map((c) => c.statut), ['recu']);
  verifier('les autres colis : statuts et historique intacts',
    JSON.stringify([apres.colis.filter((c) => c.id !== nouveau[0].id).map((c) => [c.id, c.statut, c.maj_le]),
                    apres.historique.slice(0, avant.historique.length)]),
    JSON.stringify([avant.colis.map((c) => [c.id, c.statut, c.maj_le]), avant.historique]));
  const pa = (id) => apres.prealertes.filter((p) => p.client_id === id && p.suivi_transporteur === '9400111899223399887764')[0];
  verifier('la pré-alerte de Carolina : reçue, liée au colis ; celle de Jean : en attente',
    [pa(nouveau[0].client_id).statut, pa(nouveau[0].client_id).colis_id === nouveau[0].id,
     apres.prealertes.filter((p) => p.suivi_transporteur === '9400111899223399887764' && p.client_id !== nouveau[0].client_id)[0].statut],
    ['recu', true, 'attente']);

  verifier('numéro sans colis ni pré-alerte : « colis introuvable »', await scanner(page, 'TBA999999999999'), '✕ COLIS INTROUVABLE');
  verifier('… le poste le dit et propose d\'enregistrer un colis avec ce numéro',
    await page.$eval('[data-scan-fiche]', (f) => [f.innerText.includes('Aucun colis et aucune pré-alerte'),
      !!f.querySelector('[data-scan-nouveau-colis]')]), [true, true]);
  await capture(page, '7-scan-inconnu');
  verifier('numéro déjà associé à un colis : la fiche du colis, comme avant', await scanner(page, '1Z999AA10123456784'), '✓ COLIS TROUVÉ');
  verifier('… avec son transporteur (UPS)', await page.$eval('[data-scan-fiche]', (f) => /Transporteur\s*UPS/.test(f.innerText)), true);
  verifier('numéro Goship (GSE) : inchangé', await scanner(page, nouveau[0].numero), '✓ COLIS TROUVÉ');
  verifier('mode rapide, carton sans colis : les pré-alertes aussi',
    await (async () => {
      await page.selectOption('[data-scan-mode]', 'COLIS_INSPECTE');
      const t = await scanner(page, 'TBA312345678901');
      await page.selectOption('[data-scan-mode]', '');
      return t;
    })(), 'ℹ PAS ENCORE DE COLIS : PRÉ-ALERTE TROUVÉE');

  console.log('\n3. L\'employé, l\'anglais, l\'apparence sombre, le téléphone');
  await page.evaluate(() => window.GoshipAPI.deconnecter());
  await connecter(page, 'employe@goship.demo');
  await onglet(page, 'prealertes');
  lignes = await lignesPrealertes(page);
  verifier('employé : voit l\'onglet et les 4 pré-alertes encore en attente', lignes.length, 4);
  verifier('employé : peut enregistrer le colis (shipments.create)',
    await page.$$eval('[data-prealerte-colis]', (b) => b.length), 4);
  await page.selectOption('[data-langue-tableau]', 'en');
  await page.waitForTimeout(400);
  verifier('en anglais : titre et colonnes traduits',
    [await page.$eval('[data-titre-vue]', (n) => n.textContent),
     await page.$$eval('[data-vue="prealertes"] thead th', (t) => t.slice(0, 3).map((x) => x.textContent))],
    ['Pre-alerts', ['Tracking number', 'Customer', 'Store and contents']]);
  await capture(page, '8-prealertes-anglais');
  await page.selectOption('[data-langue-tableau]', 'fr');
  await page.evaluate(() => document.documentElement.setAttribute('data-apparence', 'sombre'));
  await onglet(page, 'scanner');
  verifier('apparence sombre : la carte de pré-alerte s\'affiche', await scanner(page, 'TBA312345678901'),
    'ℹ PAS ENCORE DE COLIS : PRÉ-ALERTE TROUVÉE');
  await capture(page, '9-scanner-sombre');
  await page.evaluate(() => document.documentElement.setAttribute('data-apparence', 'clair'));

  const tel = await (await contexte(navigateur, 390, 844)).newPage();
  tel.on('pageerror', (e) => erreursJs.push(String(e)));
  await connecter(tel, 'admin@goship.demo');
  await tel.evaluate(() => window.GoshipAPI.admin.exemples());
  await tel.reload();
  await tel.waitForSelector('[data-ecran="tableau"]:not([hidden])');
  await tel.evaluate(() => document.querySelector('[data-onglet-vue="prealertes"]').click());
  await tel.waitForSelector('[data-vue="prealertes"]:not([hidden])');
  await lignesPrealertes(tel);
  verifier('téléphone (390 px) : aucun défilement horizontal de la page',
    await tel.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), true);
  await capture(tel, '10-prealertes-telephone');

  verifier('aucune erreur JavaScript', erreursJs, []);
  verifier('aucun appel à la vraie base (supabase.co)', appelsSupabase, 0);
} finally {
  await navigateur.close();
}
const n = resultats.filter(Boolean).length;
console.log('\n' + resultats.length + ' vérifications, ' + n + ' réussies.');
process.exit(n === resultats.length ? 0 : 1);
