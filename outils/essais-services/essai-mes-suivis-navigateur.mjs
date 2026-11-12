// Éprouve, dans un vrai navigateur et en mode démonstration, la Phase 4 du suivi universel :
// « Mes colis en route » dans Mon compte (les achats annoncés et ce qu'en dit leur
// transporteur, le formulaire « Annoncer un achat »), et la page publique de suivi qui
// reconnaît un numéro de transporteur ou de commande sans rien montrer d'externe.
// Ordinateur et téléphone, dans les quatre langues du site.
//
// Aucun appel à Supabase : config.js est remplacé par une configuration vide (le mode démo
// s'active tout seul), comme le demande le CLAUDE.md, et toute requête vers supabase.co est
// coupée (et comptée). Le site est servi par un serveur statique :
//
//     cd <racine du site> && python3 -m http.server 8765 --bind 127.0.0.1 &
//     node outils/essais-services/essai-mes-suivis-navigateur.mjs
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

async function capture(page, nom, pleine) {
  if (CAPTURES) await page.screenshot({ path: `${CAPTURES}/${nom}.png`, fullPage: !!pleine });
}

async function contexte(navigateur, largeur, hauteur) {
  // Le fuseau des clients (UTC−5) : une date seule ne doit pas s'y afficher la veille
  const ctx = await navigateur.newContext({ viewport: { width: largeur, height: hauteur }, locale: 'fr-FR',
                                            timezoneId: 'America/Port-au-Prince', deviceScaleFactor: CAPTURES ? 2 : 1 });
  await ctx.route('**/assets/js/config.js', (r) => r.fulfill({ contentType: 'application/javascript', body: 'window.GOSHIP_CONFIG={};' }));
  await ctx.route(/supabase\.co/, (r) => { appelsSupabase++; return r.abort(); });
  await ctx.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  return ctx;
}

function surveiller(page) {
  page.on('pageerror', (e) => erreursJs.push(String(e)));
  page.on('console', (m) => { if (m.type() === 'error' && !/supabase|fonts|ERR_FAILED/.test(m.text())) erreursJs.push(m.text()); });
}

// Les données d'exemple (comptes, colis, pré-alertes), puis la connexion d'une cliente
async function preparer(page) {
  await page.goto(SITE + '/admin.html');
  await page.waitForSelector('[data-form="admin-connexion"]', { state: 'visible' });
  await page.fill('#adm-email', 'admin@goship.demo');
  await page.fill('#adm-mdp', 'demo1234');
  await page.click('[data-form="admin-connexion"] [data-envoyer]');
  await page.waitForSelector('[data-ecran="tableau"]:not([hidden])');
  await page.evaluate(() => window.GoshipAPI.admin.exemples());
}

async function connecterClient(page, email, dossier) {
  // Depuis l'accueil (qui charge api.js) : la page de connexion redirige une session ouverte
  await page.goto(SITE + '/index.html');
  await page.waitForFunction(() => window.GoshipAPI);
  await page.evaluate((e) => window.GoshipAPI.deconnecter().then(() => window.GoshipAPI.connecter(e, 'demo1234')), email);
  await page.goto(SITE + (dossier || '') + '/mon-compte.html');
  await page.waitForSelector('[data-panneau-achats]:not([hidden])');
  await page.waitForFunction(() => !document.querySelector('[data-liste-achats]').hasAttribute('aria-busy'));
}

async function cartes(page) {
  return page.$$eval('[data-liste-achats] .gs-achat', (as) => as.map((a) => {
    const v = (c) => { const n = a.querySelector(`[data-champ="${c}"]`); return n && !n.hidden ? n.textContent.trim() : ''; };
    return { titre: v('titre'), numero: v('numero'), badge: v('badge'), statut: v('statut'), message: v('message'),
             transporteur: v('transporteur'), lieu: v('lieu'), livraison: v('livraison'), maj: v('maj'),
             colis: v('colis'), evenements: a.querySelectorAll('[data-champ="evenements"] li').length,
             pied: !a.querySelector('[data-champ="pied"]').hidden };
  }));
}

async function annoncer(page, champs) {
  if (await page.$eval('[data-form="achat"]', (f) => f.hidden)) await page.click('[data-action="annoncer-achat"]');
  for (const [nom, valeur] of Object.entries(champs)) {
    if (nom === 'service') await page.selectOption(`[data-form="achat"] [name="${nom}"]`, valeur);
    else await page.fill(`[data-form="achat"] [name="${nom}"]`, valeur);
  }
  await page.click('[data-form="achat"] [data-envoyer]');
  await page.waitForTimeout(900);
}

async function suivre(page, ref) {
  await page.fill('form[data-form="track"] [name="ref"]', ref);
  await page.click('form[data-form="track"] [type="submit"]');
  await page.waitForTimeout(800);
  return page.$eval('[data-track-result]', (r) => {
    const b = Array.from(r.querySelectorAll('[data-track-etat]')).filter((x) => !x.hidden)[0];
    return b ? b.getAttribute('data-track-etat') : '';
  });
}

const navigateur = await chromium.launch({ executablePath: process.env.CHROMIUM, args: ['--no-sandbox'] });
try {
  const ctx = await contexte(navigateur, 1440, 960);
  const page = await ctx.newPage();
  surveiller(page);
  await preparer(page);

  console.log('1. Mes colis en route (Marie-Ange, ordinateur)');
  await connecterClient(page, 'marie-ange@exemple.com');
  let c = await cartes(page);
  verifier('deux achats en attente (l\'annulé n\'apparaît pas), le plus récent d\'abord',
    c.map((x) => x.titre), ['Temu — Accessoires de téléphone', 'Amazon — Écouteurs sans fil']);
  verifier('sans numéro : le message, pas de parcours',
    [c[0].message, c[0].statut, c[0].pied, c[0].badge],
    ['Pas de numéro de suivi : votre colis sera suivi dès son arrivée à Miami.', '', false, 'En route']);
  const amazon = c[1];
  verifier('avec un suivi : le statut en clair, le transporteur, le dernier lieu',
    [amazon.statut, amazon.transporteur, amazon.lieu, amazon.badge],
    ['En route vers Miami', 'Transporteur : Amazon Logistics', 'Dernier lieu : Hialeah, FL, US', 'En route']);
  const prevue = await page.evaluate(() => window.GoshipAPI.mesSuivis().then((r) =>
    r.achats.filter((a) => a.numero_suivi === 'TBA312345678901')[0].suivi.livraison_estimee_le));
  verifier('la date prévue (donnée par le transporteur), le bon jour à Port-au-Prince, et la fraîcheur',
    [amazon.livraison.replace(/^Livraison prévue par le transporteur : (\d+) .*$/, '$1'), amazon.maj],
    [String(Number(prevue.slice(8, 10))), 'Mis à jour il y a 2 h']);
  verifier('le numéro tel qu\'annoncé', amazon.numero, 'Suivi vendeur : TBA312345678901');
  await page.click('.gs-achat:nth-child(2) [data-champ="parcours"] summary');
  verifier('le parcours : 3 événements, texte d\'origine, du plus récent au plus ancien',
    await page.$$eval('.gs-achat:nth-child(2) [data-champ="evenements"] .gs-chrono__statut', (s) => s.map((x) => x.textContent)),
    ['Package arrived at a carrier facility', 'Package has left the seller facility', 'Shipment information sent to Amazon']);
  verifier('la mention de la source, sous le parcours',
    await page.$eval('.gs-achat:nth-child(2) .gs-achat__source', (n) => n.textContent.trim()),
    'Informations du transporteur, via 17TRACK. GoShip ne les modifie pas.');
  verifier('aucun code affiché au client (PENDING, IN_TRANSIT, NO_TRACKING…)',
    await page.$eval('[data-panneau-achats]', (p) => /\b[A-Z]{2,}_[A-Z_]+\b|\bPENDING\b|\bDELIVERED\b/.test(p.innerText)), false);
  await capture(page, '1-en-route-ordinateur');

  console.log('\n2. Annoncer un achat');
  await page.click('[data-action="annoncer-achat"]');
  verifier('le formulaire s\'ouvre, avec l\'avertissement du cahier des charges',
    [await page.$eval('[data-form="achat"]', (f) => !f.hidden),
     await page.$eval('.gs-achats__avertissement', (n) => n.textContent.trim())],
    [true, 'Entrez le numéro de suivi du transporteur, pas le numéro de commande.']);
  await page.click('[data-form="achat"] [data-envoyer]');
  verifier('envoi vide : les deux champs obligatoires le disent',
    await page.$$eval('[data-form="achat"] .gs-champ.is-invalide', (l) => l.length), 2);
  await page.fill('[data-form="achat"] [name="magasin"]', 'Amazon');
  await page.fill('[data-form="achat"] [name="description"]', 'Chargeur');
  await page.fill('[data-form="achat"] [name="suivi"]', '112-1234567-1234567');
  verifier('un numéro de commande Amazon est reconnu pendant la saisie',
    await page.$eval('[data-achat-alerte]', (n) => n.hidden ? '' : n.textContent.trim()),
    'Ceci ressemble à un numéro de commande. Entrez le numéro de suivi du transporteur, indiqué dans les détails d\'expédition.');
  await page.click('[data-form="achat"] [data-envoyer]');
  await page.waitForTimeout(600);
  verifier('… et il n\'est pas envoyé', (await cartes(page)).length, 2);
  await capture(page, '2-formulaire-numero-commande');
  await annoncer(page, { suivi: 'TBA312345678901' });
  verifier('un numéro déjà annoncé : la phrase de la base, pas un code',
    await page.$eval('[data-form="achat"] [data-form-erreur]', (n) => n.textContent.trim()),
    'Ce numéro de suivi est déjà annoncé : l\'achat est dans votre liste.');
  await annoncer(page, { magasin: 'SHEIN', description: 'Robe d\'été', valeur_usd: '24.90', suivi: 'gfus 0107 2196 2999 01', service: 'maritime' });
  verifier('annoncé : le formulaire se ferme et le dit',
    [await page.$eval('[data-form="achat"]', (f) => f.hidden), await page.$eval('[data-achat-ok]', (n) => n.textContent)],
    [true, 'Achat annoncé ✓']);
  c = await cartes(page);
  const shein = c.find((x) => x.titre === 'SHEIN — Robe d\'été');
  verifier('le numéro rangé sans espaces ni minuscules', shein && shein.numero, 'Suivi vendeur : GFUS01072196299901');
  verifier('livré par le transporteur : jamais « reçu »',
    shein && [shein.statut, shein.badge, shein.livraison],
    ['Livré par GOFO — en attente de réception à l\'entrepôt GoShip', 'Livré au transporteur', '']);
  await annoncer(page, { magasin: 'Nike', description: 'Baskets', suivi: 'SWX0000000000099' });
  c = await cartes(page);
  const nike = c.find((x) => x.titre === 'Nike — Baskets');
  verifier('un numéro tout juste annoncé : en attente des premières nouvelles',
    nike && [nike.statut, nike.transporteur, nike.evenements], ['En attente des premières nouvelles du transporteur',
                                                                 'Transporteur non identifié', 1]);
  verifier('quatre cartes maintenant', c.length, 4);
  await capture(page, '3-apres-annonces', true);

  console.log('\n3. Arrivé à Miami (Jean-Robert)');
  await connecterClient(page, 'jean-robert@exemple.com');
  c = await cartes(page);
  const arrive = c.find((x) => x.badge === 'Arrivé à Miami');
  verifier('la pré-alerte reçue nomme son colis GoShip et mène à son suivi',
    arrive && [/^Arrivé à Miami : c'est le colis GSE-\d+-HT\.$/.test(arrive.statut), arrive.colis, arrive.pied],
    [true, 'Suivre ce colis', false]);
  verifier('le lien de la carte : la page de suivi GoShip, avec le numéro',
    await page.$eval('.gs-achat [data-champ="colis"]:not([hidden])', (a) => /index\.html\?suivi=GSE-\d+-HT$/.test(a.href)), true);
  const usps = c.find((x) => x.titre.indexOf('Walmart') === 0);
  verifier('USPS (exclu) : « pas disponible pour l\'instant »', usps && usps.message,
    'Ce suivi n\'est pas disponible pour l\'instant. Votre colis sera suivi dès son arrivée à Miami.');
  verifier('les achats en attente passent devant l\'arrivé', c[c.length - 1].badge, 'Arrivé à Miami');

  console.log('\n4. La page publique de suivi');
  await page.evaluate(() => window.GoshipAPI.deconnecter());
  await page.goto(SITE + '/index.html');
  verifier('un numéro de colis GoShip : comme aujourd\'hui',
    await suivre(page, await page.evaluate(() => JSON.parse(localStorage.getItem('gse-demo-donnees') || '{"colis":[]}').colis
      .map((x) => x.numero)[0] || '')).then((e) => e || 'aucun'), 'trouve');
  verifier('un numéro de commande : signalé, sans recherche', await suivre(page, '112-1234567-1234567'), 'commande');
  verifier('un numéro de transporteur pas encore chez nous : « connectez-vous »',
    await suivre(page, 'GFUS01000000000777'), 'transporteur');
  verifier('… et rien d\'externe n\'est montré (ni statut, ni transporteur)',
    await page.$eval('[data-track-etat="transporteur"]', (n) => n.innerText.replace(/\s+/g, ' ').trim()),
    'C\'est un numéro de transporteur. Connectez-vous et ajoutez-le à vos colis en route pour le suivre : vous verrez où il en est chez le transporteur, jusqu\'à son arrivée à notre entrepôt de Miami. Mes colis en route');
  await capture(page, '4-public-transporteur');
  verifier('une référence qui n\'a pas la forme d\'un suivi : « aucun colis »', await suivre(page, 'ABCDEF'), 'introuvable');
  verifier('un suivi de vendeur d\'un colis déjà reçu : toujours trouvé', await suivre(page, '1Z999AA10123456784'), 'trouve');

  console.log('\n5. Les quatre langues, ordinateur et téléphone');
  const attendus = {
    '': ['Mes colis en route', 'En route vers Miami', 'Annoncer un achat'],
    '/en': ['My packages on the way', 'On the way to Miami', 'Announce a purchase'],
    '/es': ['Mis paquetes en camino', 'En camino a Miami', 'Anunciar una compra'],
    '/ht': ['Koli mwen yo ki sou wout', 'Sou wout pou Miami', 'Anonse yon acha']
  };
  const tel = await (await contexte(navigateur, 390, 844)).newPage();
  surveiller(tel);
  await preparer(tel);
  for (const [dossier, mots] of Object.entries(attendus)) {
    for (const [p, nom] of [[page, 'ordinateur'], [tel, 'telephone']]) {
      await connecterClient(p, 'marie-ange@exemple.com', dossier);
      const statuts = (await cartes(p)).map((x) => x.statut);
      const vu = [await p.$eval('[data-panneau-achats] h2', (n) => n.textContent.trim()),
                  statuts.indexOf(mots[1]) >= 0 ? mots[1] : statuts,
                  await p.$eval('[data-action="annoncer-achat"]', (n) => n.textContent.trim())];
      verifier(`${dossier || '/fr'} ${nom} : titre, statut, bouton traduits`, vu, mots);
      verifier(`${dossier || '/fr'} ${nom} : aucun défilement horizontal`,
        await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), true);
      if (nom === 'telephone') {
        await p.click('[data-action="annoncer-achat"]');
        verifier(`${dossier || '/fr'} téléphone : le formulaire tient dans l'écran`,
          await p.$eval('[data-form="achat"]', (f) => f.getBoundingClientRect().right <= window.innerWidth + 1), true);
        await p.$eval('[data-panneau-achats]', (n) => n.scrollIntoView());
        await capture(p, `5-telephone${dossier.replace('/', '-') || '-fr'}`);
      }
    }
  }

  verifier('aucune erreur JavaScript', erreursJs, []);
  verifier('aucun appel à la vraie base (supabase.co)', appelsSupabase, 0);
} finally {
  await navigateur.close();
}
const n = resultats.filter(Boolean).length;
console.log('\n' + resultats.length + ' vérifications, ' + n + ' réussies.');
process.exit(n === resultats.length ? 0 : 1);
