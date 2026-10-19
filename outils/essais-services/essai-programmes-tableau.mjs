// Éprouve, dans un vrai navigateur et en mode démonstration, l'onglet « Programmes » du tableau de bord :
// l'équipe règle les anniversaires, l'offre de bienvenue, le parrainage et GOPOINTS, et chaque rôle ne voit
// que ce que ses permissions lui ouvrent.
//
// Aucun appel à Supabase : config.js est remplacé par une configuration vide (le mode démo s'active tout
// seul). Le site est servi par un serveur statique :
//
//     cd <racine du site> && python3 -m http.server 8765 --bind 127.0.0.1 &
//     CHROMIUM=/chemin/vers/chrome node outils/essais-services/essai-programmes-tableau.mjs
//
// CAPTURES=/dossier : enregistre des captures (bureau et téléphone, clair et sombre) pour les regarder.
import { createRequire } from 'node:module';

const exiger = createRequire(import.meta.url);
const chemin = process.env.GOSHIP_PLAYWRIGHT || '/home/user/goship-express-app/node_modules/playwright-core';
const { chromium } = exiger(chemin);
const SITE = process.env.SITE || 'http://127.0.0.1:8765';
const CAPTURES = process.env.CAPTURES || '';
const resultats = [];

function verifier(titre, obtenu, attendu) {
  const bon = JSON.stringify(obtenu) === JSON.stringify(attendu);
  console.log('  ' + (bon ? 'OK  ' : 'RATÉ') + ' ' + titre.padEnd(76) + ' ' + (bon ? '' : JSON.stringify(obtenu)));
  if (!bon) console.log('       attendu : ' + JSON.stringify(attendu));
  resultats.push(bon);
}

async function contexte(navigateur, largeur, hauteur, apparence) {
  const ctx = await navigateur.newContext({ viewport: { width: largeur, height: hauteur }, locale: 'fr-FR', colorScheme: apparence || 'light' });
  await ctx.route('**/assets/js/config.js', (r) => r.fulfill({ contentType: 'application/javascript', body: 'window.GOSHIP_CONFIG={};' }));
  await ctx.route(/supabase\.co/, (r) => r.abort());
  return ctx;
}

async function connecter(page, email) {
  await page.goto(SITE + '/admin.html');
  await page.waitForSelector('[data-form="admin-connexion"]');
  await page.fill('#adm-email', email);
  await page.fill('#adm-mdp', 'demo1234');
  await page.click('[data-form="admin-connexion"] [data-envoyer]');
  await page.waitForSelector('[data-onglet-vue="colis"]', { state: 'visible' });
}

async function ouvrirProgrammes(page) {
  await page.click('[data-onglet-vue="programmes"]');
  await page.waitForSelector('[data-vue="programmes"]:not([hidden])');
}

async function ongletProg(page, nom) {
  await page.click('[data-prog-onglet="' + nom + '"]');
  await page.waitForSelector('[data-prog-panneau="' + nom + '"]:not([hidden]) .gs-prog__bloc');
}

async function remplir(zone, nom, valeur) {
  const c = zone.locator('[name="' + nom + '"]').first();
  if ((await c.getAttribute('type')) === 'checkbox') { if ((await c.isChecked()) !== valeur) await c.setChecked(valeur); }
  else if ((await c.evaluate((n) => n.tagName)) === 'SELECT') await c.selectOption(valeur);
  else await c.fill(String(valeur));
}

// Le message affiché : on attend qu'il commence par le texte attendu (un ancien message peut encore être là)
async function message(page, debut) {
  await page.waitForFunction((d) => { const n = document.querySelector('[data-prog-message]'); return !n.hidden && n.textContent.startsWith(d || ''); }, debut || '');
  return (await page.textContent('[data-prog-message]')).trim();
}

const navigateur = await chromium.launch({ executablePath: process.env.CHROMIUM, args: ['--no-sandbox'] });
try {
  console.log("1. L'administrateur ouvre l'onglet Programmes (bureau)");
  const ctx = await contexte(navigateur, 1440, 900);
  const page = await ctx.newPage();
  const erreursPage = [];
  page.on('pageerror', (e) => erreursPage.push(String(e)));
  await connecter(page, 'admin@goship.demo');
  verifier('le menu propose « Programmes »', await page.locator('[data-onglet-vue="programmes"]:not([data-interdit])').count(), 1);
  await ouvrirProgrammes(page);
  verifier('le titre de la vue est « Programmes »', (await page.textContent('[data-titre-vue]')).trim(), 'Programmes');
  verifier('cinq sous-onglets visibles à l\'administrateur',
    await page.locator('[data-prog-onglet]:not([data-interdit])').count(), 5);
  await ongletProg(page, 'bienvenue');
  verifier('aucune campagne au départ : message clair',
    (await page.textContent('[data-prog-panneau="bienvenue"] .gs-admin-vide')).trim().startsWith('Aucune campagne'), true);

  console.log('\n2. Offre de bienvenue : brouillon, publication refusée tant qu\'elle est incomplète');
  const bienvenue = page.locator('[data-prog-panneau="bienvenue"]');
  await bienvenue.getByRole('button', { name: 'Nouvelle campagne' }).click();
  const formulaire = bienvenue.locator('.gs-prog__edition form');
  await remplir(formulaire, 'nom', 'Bienvenue d\'essai');
  await bienvenue.getByRole('button', { name: 'Enregistrer en brouillon' }).click();
  await message(page);
  verifier('le brouillon est créé', await bienvenue.locator('.gs-prog__carte h4').first().textContent(), 'Bienvenue d\'essai');
  verifier('ce qui manque est listé',
    (await bienvenue.locator('.gs-prog__manque').first().textContent()).includes('la date de début'), true);
  await bienvenue.getByRole('button', { name: 'Publier' }).click();
  verifier('la publier incomplète : refusée avec la phrase de la base',
    (await message(page, 'La campagne est incomplète')).startsWith('La campagne est incomplète'), true);
  await bienvenue.getByRole('button', { name: 'Modifier' }).click();
  const f2 = bienvenue.locator('.gs-prog__edition form');
  const aujourdhui = new Date().toISOString().slice(0, 10);
  const dans30 = new Date(Date.now() + 30 * 864e5).toISOString().slice(0, 10);
  await remplir(f2, 'debut', aujourdhui); await remplir(f2, 'fin', dans30);
  await remplir(f2, 'type_recompense', 'bonus_fixe'); await remplir(f2, 'valeur_recompense', '7');
  await remplir(f2, 'operation', 'colis_recu'); await remplir(f2, 'conditions', 'Un bonus par client, première opération uniquement.');
  await bienvenue.getByRole('button', { name: 'Enregistrer en brouillon' }).click();
  await message(page);
  await bienvenue.getByRole('button', { name: 'Publier' }).click();
  await page.waitForFunction(() => document.querySelector('[data-prog-panneau="bienvenue"] .gs-prog__etat')?.textContent === 'Active');
  verifier('complète, la campagne est active', await bienvenue.locator('.gs-prog__etat').first().textContent(), 'Active');
  verifier('active : plus de bouton Modifier, mais Suspendre et Terminer',
    [await bienvenue.getByRole('button', { name: 'Modifier' }).count(), await bienvenue.getByRole('button', { name: 'Suspendre' }).count(),
     await bienvenue.getByRole('button', { name: 'Terminer' }).count()], [0, 1, 1]);
  verifier('une récompense en dollars s\'écrit avec la virgule française', (await bienvenue.locator('.gs-prog__dl dd').nth(1).textContent()).includes('7,00'), true);

  console.log('\n3. GOPOINTS : programme éteint, une règle sans point refusée, une offre créée');
  await ongletProg(page, 'points');
  const points = page.locator('[data-prog-panneau="points"]');
  verifier('le programme est éteint', (await points.locator('.gs-prog__statut .gs-prog__etat').first().textContent()).trim(), 'Éteint');
  const carteInscription = points.locator('.gs-prog__carte--regle').first();
  await remplir(carteInscription, 'actif', true);
  await carteInscription.getByRole('button', { name: 'Enregistrer cette règle' }).click();
  verifier('allumer une règle sans point : refusé', (await message(page, 'Une règle allumée')).startsWith('Une règle allumée doit accorder au moins 1 point'), true);
  verifier('le catalogue d\'offres est vide', (await points.locator('.gs-admin-vide').first().textContent()).includes('catalogue est vide'), true);
  await points.getByRole('button', { name: 'Nouvelle offre' }).click();
  const fo = points.locator('.gs-prog__edition form');
  await remplir(fo, 'nom', 'Crédit d\'essai'); await remplir(fo, 'cout_points', '100'); await remplir(fo, 'type', 'credit_expedition');
  await remplir(fo, 'valeur', '5');
  await points.getByRole('button', { name: 'Enregistrer' }).last().click();
  await message(page);
  verifier('l\'offre apparaît, éteinte', (await points.locator('table').last().textContent()).includes('Crédit d\'essai'), true);

  console.log('\n4. Parrainage : brouillon incomplet, rien à publier');
  await ongletProg(page, 'parrainage');
  const parr = page.locator('[data-prog-panneau="parrainage"]');
  verifier('le parrainage naît en brouillon', (await parr.locator('.gs-prog__statut .gs-prog__etat').textContent()).trim(), 'Brouillon');
  await parr.getByRole('button', { name: 'Publier' }).click();
  verifier('incomplet : refusé', (await message(page, 'Le parrainage est incomplet')).startsWith('Le parrainage est incomplet'), true);
  verifier('ce qui manque est listé', (await parr.locator('.gs-prog__manque').textContent()).includes('l\'avantage du parrain'), true);

  console.log('\n5. Anniversaires : éteints par défaut, aucun canal déclaré configuré, WhatsApp indisponible');
  await ongletProg(page, 'anniversaires');
  const anniv = page.locator('[data-prog-panneau="anniversaires"]');
  verifier('le programme est éteint', (await anniv.locator('.gs-prog__statut .gs-prog__etat').first().textContent()).trim(), 'Éteint');
  const canaux = await anniv.locator('.gs-prog__canaux li').allTextContents();
  verifier('les canaux disent « non configuré » et WhatsApp « pas encore disponible »',
    [canaux.some((c) => c.startsWith('E-mail') && c.endsWith('non configuré')), canaux.some((c) => c.startsWith('WhatsApp') && c.includes('pas encore disponible'))], [true, true]);
  verifier('seize modèles de messages, quatre langues par type', await anniv.locator('.gs-prog__modele').count(), 16);
  await anniv.locator('.gs-prog__modele summary', { hasText: 'Créole' }).first().click();
  verifier('le message créole commence par « Bòn fèt »',
    (await anniv.locator('.gs-prog__modele[open] input[name="titre"]').inputValue()).includes('Bòn fèt'), true);
  await remplir(anniv, 'avantage_actif', true);
  await anniv.getByRole('button', { name: 'Enregistrer les réglages' }).click();
  verifier('un avantage actif sans type : refusé', (await message(page, 'Choisissez le type')).startsWith('Choisissez le type d\'avantage'), true);
  await remplir(anniv, 'avantage_actif', false);
  await remplir(anniv, 'actif', true);
  await anniv.getByRole('button', { name: 'Enregistrer les réglages' }).click();
  await page.waitForFunction(() => document.querySelector('[data-prog-message]').textContent.startsWith('Réglages enregistrés'));
  await page.waitForSelector('[data-prog-panneau="anniversaires"] .gs-prog__statut .gs-prog__etat--ok');
  verifier('allumé, il le dit', (await anniv.locator('.gs-prog__statut .gs-prog__etat').first().textContent()).trim(), 'Allumé');
  await remplir(anniv, 'actif', false);
  await anniv.getByRole('button', { name: 'Enregistrer les réglages' }).click();
  await page.waitForSelector('[data-prog-panneau="anniversaires"] .gs-prog__statut .gs-prog__etat--neutre');

  console.log('\n6. Avantages : un motif est obligatoire pour accorder, puis pour annuler');
  await ongletProg(page, 'avantages');
  const av = page.locator('[data-prog-panneau="avantages"]');
  await av.getByRole('button', { name: 'Accorder' }).click();
  verifier('sans code de client : une phrase claire', (await message(page, 'Écrivez le code')).startsWith('Écrivez le code du client'), true);
  verifier('aucune erreur JavaScript pendant ce parcours', erreursPage, []);

  if (CAPTURES) {
    await ongletProg(page, 'bienvenue');
    await page.screenshot({ path: CAPTURES + '/prog-bureau-bienvenue.png', fullPage: true });
    await ongletProg(page, 'anniversaires');
    await page.screenshot({ path: CAPTURES + '/prog-bureau-anniversaires.png', fullPage: true });
  }
  await ctx.close();

  console.log('\n7. Chaque rôle voit ce que ses permissions ouvrent');
  const gerantCtx = await contexte(navigateur, 1280, 800);
  const gerant = await gerantCtx.newPage();
  await connecter(gerant, 'gerant@goship.demo');
  await ouvrirProgrammes(gerant);
  await gerant.waitForSelector('[data-prog-panneau]:not([hidden]) .gs-prog__bloc');
  verifier('le gérant lit les cinq onglets', await gerant.locator('[data-prog-onglet]:not([data-interdit])').count(), 5);
  await ongletProg(gerant, 'anniversaires');
  verifier('… en lecture seule : champs désactivés, aucun bouton d\'enregistrement',
    [await gerant.locator('[data-prog-panneau="anniversaires"] .gs-prog__formulaire input:not([disabled]):not([type="date"])').count() === 0,
     await gerant.getByRole('button', { name: 'Enregistrer les réglages' }).count()], [true, 0]);
  await ongletProg(gerant, 'bienvenue');
  verifier('le gérant ne crée pas de campagne', await gerant.getByRole('button', { name: 'Nouvelle campagne' }).count(), 0);
  await ongletProg(gerant, 'avantages');
  verifier('ni n\'accorde un avantage à la main', await gerant.getByRole('button', { name: 'Accorder' }).count(), 0);
  await gerantCtx.close();

  const employeCtx = await contexte(navigateur, 1280, 800);
  const employe = await employeCtx.newPage();
  await connecter(employe, 'employe@goship.demo');
  verifier('l\'employé n\'a pas l\'onglet Programmes (ni donc aucune date de naissance)',
    await employe.locator('[data-onglet-vue="programmes"]:not([data-interdit])').count(), 0);
  await employeCtx.close();

  console.log('\n8. Téléphone (390 px) et apparence sombre : lisible, sans défilement horizontal');
  for (const [apparence, suffixe] of [['light', 'clair'], ['dark', 'sombre']]) {
    const mc = await contexte(navigateur, 390, 844, apparence);
    const mobile = await mc.newPage();
    await mobile.addInitScript((a) => { try { localStorage.setItem('gse-tableau-reglages', JSON.stringify({ apparence: a === 'dark' ? 'sombre' : 'clair', animations: 'non' })); } catch (e) { /* sans stockage */ } }, apparence);
    await connecter(mobile, 'admin@goship.demo');
    await mobile.click('[data-action="ouvrir-menu"]').catch(() => {});
    await mobile.click('[data-onglet-vue="programmes"]');
    await mobile.waitForSelector('[data-vue="programmes"]:not([hidden])');
    await ongletProg(mobile, 'parrainage');
    const debordement = await mobile.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    verifier('pas de défilement horizontal de la page (' + suffixe + ')', debordement <= 0, true);
    if (CAPTURES) await mobile.screenshot({ path: CAPTURES + '/prog-mobile-parrainage-' + suffixe + '.png', fullPage: true });
    await mc.close();
  }

  console.log('\n9. Le tableau de bord en anglais, espagnol et créole : les textes de l\'onglet suivent');
  for (const [langue, attendus] of [['en', ['Birthdays', 'Welcome offer', 'Referrals', 'Benefits']], ['es', ['Cumpleaños', 'Oferta de bienvenida', 'Patrocinios', 'Beneficios']],
                                    ['ht', ['Fèt', 'Òf byenveni', 'Parennaj', 'Avantaj']]]) {
    const lc = await contexte(navigateur, 1280, 900);
    const pl = await lc.newPage();
    await pl.addInitScript((l) => { try { localStorage.setItem('gse-tableau-langue', l); } catch (e) { /* sans stockage */ } }, langue);
    await connecter(pl, 'admin@goship.demo');
    await ouvrirProgrammes(pl);
    await ongletProg(pl, 'bienvenue');
    const onglets = (await pl.locator('[data-prog-onglet]').allTextContents()).map((x) => x.trim());
    verifier('les onglets en ' + langue, [onglets[0], onglets[1], onglets[2], onglets[4]], attendus);
    verifier('le menu et le titre aussi (' + langue + ')',
      (await pl.textContent('[data-titre-vue]')).trim() !== 'Programmes' || langue === 'fr', true);
    await ongletProg(pl, 'anniversaires');
    const francais = await pl.locator('[data-prog-panneau="anniversaires"] .gs-prog__titre').allTextContents();
    verifier('les titres de l\'onglet Anniversaires ne sont plus en français (' + langue + ')', francais.some((x) => /^(Réglages|Modèles de messages|Erreurs)$/.test(x.trim())), false);
    await lc.close();
  }

  console.log('\nLes cases à cocher : l\'état coché se voit (clair et sombre), et le texte les bascule aussi');
  // Régression : « .gs-champ input » retire l'apparence native de tout champ, et une case cochée ressemblait alors
  // à une case vide (le réglage s'enregistrait sans qu'on le voie). On compare donc le rendu, pas seulement .checked.
  // Session à part : l'onglet « Offre de bienvenue » s'ouvre par défaut et se recharge à chaque retour.
  {
    const cc = await contexte(navigateur, 1440, 900);
    const pc = await cc.newPage();
    await connecter(pc, 'admin@goship.demo');
    await ouvrirProgrammes(pc);
    await ongletProg(pc, 'anniversaires');
    const interrupteur = pc.locator('[data-prog-panneau="anniversaires"] [name="actif"]').first();
    // Les 200 ms de la transition du fond, plus de la marge
    const rendu = async () => { await pc.waitForTimeout(450); return interrupteur.evaluate((n) => ({ fond: getComputedStyle(n).backgroundColor, pastille: getComputedStyle(n, '::after').transform })); };
    const videClair = await rendu();
    await interrupteur.click();
    const cocheClair = await rendu();
    verifier('clair : cochée, la case n\'a ni le même fond ni la même pastille que vide',
      (await interrupteur.isChecked()) && videClair.fond !== cocheClair.fond && videClair.pastille !== cocheClair.pastille, true);
    await pc.locator('[data-prog-panneau="anniversaires"] .gs-prog__champ--case label', { hasText: 'Envoyer les messages' }).click();
    verifier('clic sur le texte : la case se décoche et reprend son rendu vide',
      (await interrupteur.isChecked()) === false && (await rendu()).fond === videClair.fond, true);
    await pc.evaluate(() => document.documentElement.setAttribute('data-apparence', 'sombre'));
    const videSombre = await rendu();
    await interrupteur.click();
    const cocheSombre = await rendu();
    verifier('sombre : cochée, la case se distingue de la case vide',
      videSombre.fond !== cocheSombre.fond && videSombre.fond !== videClair.fond, true);
    await cc.close();
  }
} finally {
  await navigateur.close();
}
const reussis = resultats.filter(Boolean).length;
console.log('\n' + resultats.length + ' vérifications, ' + reussis + ' réussies.');
process.exit(reussis === resultats.length ? 0 : 1);
