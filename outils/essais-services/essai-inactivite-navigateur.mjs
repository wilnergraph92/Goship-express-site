// Éprouve, dans un vrai navigateur, la déconnexion après un moment sans activité
// (assets/js/inactivite.js) : le tableau de bord (fenêtre « Toujours là ? », bouton « Rester
// connecté », un geste qui la fait disparaître, puis la déconnexion et son message), le retour
// après une longue absence (déconnexion immédiate), une connexion récente qui repart à zéro,
// deux onglets qui partagent la même heure de dernier geste, la déconnexion voulue, l'anglais,
// et « Mon compte » de l'espace client (bandeau, puis la page de connexion qui dit pourquoi).
//
// Le temps est celui d'une horloge simulée (page.clock de Playwright) : une minute passe en un
// instant. Les délais sont mis à 1 minute par la configuration de l'essai ; l'avertissement
// paraît alors 30 secondes avant (la moitié d'un délai court).
//
// Aucun appel à Supabase : config.js est remplacé et toute requête vers supabase.co est coupée
// (et comptée). Le mode démonstration sert de fond.
//
//     cd <racine du site> && python3 -m http.server 8765 --bind 127.0.0.1 &
//     node outils/essais-services/essai-inactivite-navigateur.mjs
//
// GOSHIP_PLAYWRIGHT : chemin de Playwright.
import { createRequire } from 'node:module';

const exiger = createRequire(import.meta.url);
const { chromium } = exiger(process.env.GOSHIP_PLAYWRIGHT || 'playwright');
const SITE = process.env.SITE || 'http://127.0.0.1:8765';
const CONFIG = 'window.GOSHIP_CONFIG={deconnexionTableauMinutes:1,deconnexionCompteMinutes:1};';
const CLE = 'gse-derniere-activite';
const resultats = [];
let appelsSupabase = 0;
const erreursJs = [];

function verifier(titre, obtenu, attendu) {
  const bon = JSON.stringify(obtenu) === JSON.stringify(attendu);
  console.log('  ' + (bon ? 'OK  ' : 'RATÉ') + ' ' + titre.padEnd(78) + ' ' + (bon ? '' : JSON.stringify(obtenu)));
  if (!bon) console.log('       attendu : ' + JSON.stringify(attendu));
  resultats.push(bon);
}

async function contexte(navigateur, options) {
  options = options || {};
  const ctx = await navigateur.newContext({ viewport: { width: 1280, height: 860 }, locale: 'fr-FR' });
  await ctx.route('**/assets/js/config.js', (r) => r.fulfill({ contentType: 'application/javascript', body: CONFIG }));
  await ctx.route(/supabase\.co/, (r) => { appelsSupabase++; return r.abort(); });
  if (options.langue) await ctx.addInitScript((l) => { try { localStorage.setItem('gse-tableau-langue', l); } catch (e) {} }, options.langue);
  return ctx;
}

async function page(ctx) {
  const p = await ctx.newPage();
  p.on('pageerror', (e) => erreursJs.push(String(e)));
  // « Blocked script execution in 'about:blank' » : l'horloge simulée tente de s'installer aussi
  // dans l'iframe de l'aperçu d'e-mail, isolée sans scripts (sandbox) — c'est l'essai, pas le site.
  p.on('console', (m) => { if (m.type() === 'error' && !/supabase|fonts|ERR_FAILED|Blocked script execution in 'about:blank'/.test(m.text())) erreursJs.push(m.text()); });
  // L'horloge simulée, posée avant tout script de la page
  await p.clock.install();
  return p;
}

// Connexion de démonstration par le formulaire du tableau de bord
async function connecterAdmin(p) {
  await p.goto(SITE + '/admin.html');
  await p.waitForFunction(() => window.GoshipAPI);
  await p.evaluate(() => window.GoshipAPI.deconnecter());
  await p.goto(SITE + '/admin.html');
  await p.waitForSelector('[data-form="admin-connexion"]', { state: 'visible' });
  await p.fill('#adm-email', 'admin@goship.demo');
  await p.fill('#adm-mdp', 'demo1234');
  await p.click('[data-form="admin-connexion"] [data-envoyer]');
  await p.waitForSelector('[data-ecran="tableau"]:not([hidden])');
}

const visible = (p, sel) => p.evaluate((s) => { const n = document.querySelector(s); return !!n && !n.closest('[hidden]') && !n.hidden; }, sel);
const ouverte = (p) => p.evaluate(() => document.querySelector('[data-dialogue="inactivite"]').open);
const texte = (p, sel) => p.evaluate((s) => { const n = document.querySelector(s); return n ? n.textContent.trim() : null; }, sel);
const session = (p) => p.evaluate(() => window.GoshipAPI.session().then((s) => !!s));
// Les promesses d'api.js (démo) passent par des minuteries : on laisse l'horloge avancer un peu
const laisser = (p, ms) => p.clock.runFor(ms || 200);

async function main() {
  const navigateur = await chromium.launch();

  console.log('A. Tableau de bord : l\'avertissement, « Rester connecté », un geste, puis la déconnexion');
  let ctx = await contexte(navigateur);
  let p = await page(ctx);
  await connecterAdmin(p);
  verifier('connecté : l\'heure du dernier geste est notée', await p.evaluate((c) => !!localStorage.getItem(c), CLE), true);
  await p.clock.runFor(25000);
  verifier('25 s sans geste : pas encore d\'avertissement', await ouverte(p), false);
  await p.clock.runFor(10000);
  verifier('35 s : « Toujours là ? » (30 s avant la fin d\'un délai d\'une minute)', await ouverte(p), true);
  verifier('… avec son texte', await texte(p, '[data-dialogue="inactivite"] .gs-dialogue__aide'), 'Sans activité, vous serez déconnecté dans une minute.');
  // Le bouton lui-même, sans geste de souris (un geste suffit déjà à tout reprendre : section suivante)
  await p.evaluate(() => document.querySelector('[data-inactivite-rester]').click());
  await laisser(p);
  verifier('« Rester connecté » ferme la fenêtre', await ouverte(p), false);
  await p.clock.runFor(40000);
  verifier('le compteur est reparti : 40 s plus tard, l\'avertissement revient', await ouverte(p), true);
  await p.mouse.move(400, 300);
  await p.mouse.move(420, 320);
  await laisser(p);
  verifier('un simple geste de la souris le fait disparaître', await ouverte(p), false);
  await p.clock.runFor(65000);
  await laisser(p, 500);
  verifier('une minute sans rien : retour à l\'écran de connexion', [await visible(p, '[data-ecran="connexion"]'), await visible(p, '[data-ecran="tableau"]')], [true, false]);
  verifier('… avec la raison',
           /après un moment sans activité/.test(await texte(p, 'form[data-form="admin-connexion"] [data-form-erreur]')), true);
  verifier('… et la session est bien fermée', await session(p), false);
  verifier('la fenêtre d\'avertissement est refermée', await ouverte(p), false);
  await ctx.close();

  console.log('\nB. Revenir après une longue absence : déconnecté tout de suite');
  ctx = await contexte(navigateur);
  p = await page(ctx);
  await connecterAdmin(p);
  // L'ordinateur est resté en veille deux heures : dernier geste et connexion sont anciens
  await p.evaluate((c) => {
    const avant = Date.now() - 2 * 3600 * 1000;
    localStorage.setItem(c, String(avant));
    localStorage.setItem('gse-demo-connecte-le', String(avant - 60000));
  }, CLE);
  await p.reload();
  await p.waitForFunction(() => window.GoshipAPI);
  await laisser(p, 1500);
  verifier('la page rouverte s\'arrête à l\'écran de connexion', await visible(p, '[data-ecran="connexion"]'), true);
  verifier('… avec la raison', /après un moment sans activité/.test(await texte(p, 'form[data-form="admin-connexion"] [data-form-erreur]')), true);
  verifier('… et la session est fermée', await session(p), false);

  console.log('\nC. Une connexion plus récente que le dernier geste noté repart à zéro');
  await connecterAdmin(p);
  await laisser(p, 1500);
  verifier('la vieille heure ne déconnecte pas une connexion toute neuve', await visible(p, '[data-ecran="tableau"]'), true);
  verifier('… et l\'heure notée est celle de maintenant',
           await p.evaluate((c) => Math.abs(Date.now() - Number(localStorage.getItem(c))) < 10000, CLE), true);

  console.log('\nD. Deux onglets partagent la même heure de dernier geste');
  const p2 = await page(ctx);
  await p2.goto(SITE + '/admin.html');
  await p2.waitForSelector('[data-ecran="tableau"]:not([hidden])');
  // Le second onglet voit tout le temps passer, le premier reçoit les gestes
  await p2.clock.runFor(20000);
  await p.clock.runFor(20000);
  await p.mouse.move(300, 300);
  await p.mouse.move(310, 330);
  await laisser(p);
  await p2.clock.runFor(25000);
  verifier('travailler dans l\'onglet 1 garde l\'onglet 2 sans avertissement (45 s)', await ouverte(p2), false);
  await p2.clock.runFor(70000);
  await laisser(p2, 500);
  verifier('sans geste nulle part, l\'onglet 2 se déconnecte aussi', await visible(p2, '[data-ecran="connexion"]'), true);
  await ctx.close();

  console.log('\nE. Déconnexion voulue : la veille s\'arrête et l\'heure est effacée');
  ctx = await contexte(navigateur);
  p = await page(ctx);
  await connecterAdmin(p);
  // La déconnexion recharge la page : on attend la nouvelle avant de lire
  await Promise.all([
    p.waitForEvent('load'),
    p.evaluate(() => { document.querySelector('[data-action="deconnexion"]').click(); }),
  ]);
  verifier('plus d\'heure de dernier geste rangée', await p.evaluate((c) => localStorage.getItem(c), CLE), null);
  await ctx.close();

  console.log('\nF. En anglais');
  ctx = await contexte(navigateur, { langue: 'en' });
  p = await page(ctx);
  await connecterAdmin(p);
  await p.clock.runFor(35000);
  await laisser(p, 500);
  verifier('« Still there? »', await texte(p, '#dlg-inactivite-titre'), 'Still there?');
  verifier('« Stay signed in »', await texte(p, '[data-inactivite-rester]'), 'Stay signed in');
  await ctx.close();

  console.log('\nG. Mon compte : le bandeau, puis la page de connexion qui dit pourquoi');
  ctx = await contexte(navigateur);
  p = await page(ctx);
  await connecterAdmin(p);
  await p.evaluate(() => window.GoshipAPI.admin.exemples());
  // Déconnexion voulue de l'équipe, puis la cliente entre par le formulaire de connexion
  await Promise.all([
    p.waitForEvent('load'),
    p.evaluate(() => { document.querySelector('[data-action="deconnexion"]').click(); }),
  ]);
  await p.goto(SITE + '/connexion.html');
  await p.waitForSelector('#cnx-email');
  await p.fill('#cnx-email', 'marie-ange@exemple.com');
  await p.fill('#cnx-mdp', 'demo1234');
  await Promise.all([
    p.waitForURL(/mon-compte\.html/),
    p.click('[data-form="connexion"] [data-envoyer]'),
  ]);
  await p.waitForSelector('[data-liste-colis]');
  await laisser(p, 1500);
  verifier('connectée : pas de bandeau', await visible(p, '[data-inactivite]'), false);
  await p.clock.runFor(35000);
  await laisser(p);
  verifier('35 s sans geste : le bandeau « Toujours là ? »', await visible(p, '[data-inactivite]'), true);
  await p.evaluate(() => document.querySelector('[data-action="rester-connecte"]').click());
  await laisser(p);
  verifier('« Rester connecté » le cache', await visible(p, '[data-inactivite]'), false);
  await p.clock.runFor(65000);
  await p.waitForURL(/connexion\.html\?raison=inactivite/);
  await p.waitForSelector('[data-raison-inactivite]');
  await laisser(p, 500);
  verifier('une minute sans rien : la page de connexion, avec la raison', await visible(p, '[data-raison-inactivite]'), true);
  verifier('… et la session est fermée', await session(p), false);
  await p.goto(SITE + '/connexion.html');
  await laisser(p, 500);
  verifier('sans ?raison=, la page de connexion ne dit rien', await visible(p, '[data-raison-inactivite]'), false);
  await ctx.close();

  await navigateur.close();
  console.log('');
  verifier('aucune erreur JavaScript', erreursJs, []);
  verifier('aucune requête vers Supabase', appelsSupabase, 0);
  const rates = resultats.filter((r) => !r).length;
  console.log(`\n${resultats.length - rates} / ${resultats.length} vérifications réussies`);
  process.exit(rates ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(1); });
