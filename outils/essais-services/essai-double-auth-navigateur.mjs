// Éprouve, dans un vrai navigateur, l'interface de la double authentification du tableau de
// bord (lot 1 du contrôle qualité) : l'écran du code à la connexion, l'inscription d'un appareil
// (QR code, clé, premier code), le bandeau d'un compte qui ne l'a pas activée, la ligne des
// réglages, les badges de l'onglet Équipe, la double authentification obligatoire, l'anglais et
// le téléphone.
//
// La vraie vérification du code est faite par Supabase Auth, et la règle par la base
// (outils/supabase-double-auth.sql, éprouvée par essai-double-auth.py). Ici, le mode démonstration
// sert de fond (comptes, onglets) et API.doubleAuth est remplacée, avant que la page ne s'en serve,
// par une doublure qui répond comme ma_double_auth() et Supabase Auth : « 123456 » est le bon code.
// Sans doublure, le mode démo répond null : rien ne doit apparaître (dernier cas).
//
// Aucun appel à Supabase : config.js est remplacé par une configuration vide et toute requête
// vers supabase.co est coupée (et comptée).
//
//     cd <racine du site> && python3 -m http.server 8765 --bind 127.0.0.1 &
//     node outils/essais-services/essai-double-auth-navigateur.mjs
//
// CAPTURES=<dossier> enregistre les captures d'écran. GOSHIP_PLAYWRIGHT : chemin de Playwright.
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
  if (CAPTURES) await page.screenshot({ path: `${CAPTURES}/${nom}.png` });
}

// La doublure : posée au moment où api.js publie window.GoshipAPI, avant qu'admin.js ne démarre
function doublure(etat) {
  const m = window.__mfa = Object.assign({ active: false, aal: 'aal1', obligatoire: false, absent: false, inscriptions: 0 }, etat || {});
  let api;
  Object.defineProperty(window, 'GoshipAPI', {
    configurable: true,
    get() { return api; },
    set(v) {
      api = v;
      if (m.absent) return;
      v.doubleAuth = {
        etat: () => Promise.resolve({ equipe: true, active: m.active, appareils: m.active ? 1 : 0, session: m.aal,
                                      obligatoire: m.obligatoire,
                                      code_requis: m.aal !== 'aal2' && (m.active || m.obligatoire) }),
        inscrire: () => { m.inscriptions++; return Promise.resolve({ id: 'appareil-1', cle: 'JBSWY3DPEHPK3PXP',
          qr: 'data:image/svg+xml;utf-8,<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>' }); },
        confirmer: (id, code) => (code === '123456' && id === 'appareil-1'
          ? (m.active = true, m.aal = 'aal2', Promise.resolve(true)) : Promise.reject({ code: 'code-invalide' })),
        verifier: (code) => (code === '123456' ? (m.aal = 'aal2', Promise.resolve(true)) : Promise.reject({ code: 'code-invalide' })),
        equipe: () => v.admin.equipe().then((l) => ({ obligatoire: m.obligatoire,
          comptes: l.map((c, i) => ({ id: c.id, appareils: i === 0 ? 1 : 0 })) })),
        regler: (oui, motif) => { m.reglages = (m.reglages || []).concat([[oui, motif]]); m.obligatoire = oui;
                                  return Promise.resolve({ obligatoire: oui, deja: false }); }
      };
    }
  });
}

async function nouvellePage(navigateur, etat, options) {
  options = options || {};
  const ctx = await navigateur.newContext({ viewport: { width: options.largeur || 1280, height: options.hauteur || 860 },
                                            locale: 'fr-FR', deviceScaleFactor: CAPTURES ? 2 : 1 });
  await ctx.route('**/assets/js/config.js', (r) => r.fulfill({ contentType: 'application/javascript', body: 'window.GOSHIP_CONFIG={};' }));
  await ctx.route(/supabase\.co/, (r) => { appelsSupabase++; return r.abort(); });
  await ctx.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  if (options.langue) await ctx.addInitScript((l) => { try { localStorage.setItem('gse-tableau-langue', l); } catch (e) {} }, options.langue);
  await ctx.addInitScript(doublure, etat);
  const page = await ctx.newPage();
  page.on('pageerror', (e) => erreursJs.push(String(e)));
  page.on('console', (msg) => { if (msg.type() === 'error' && !/supabase|fonts|ERR_FAILED/.test(msg.text())) erreursJs.push(msg.text()); });
  // Connexion de démonstration, puis la page telle qu'un administrateur l'ouvre
  await page.goto(SITE + '/admin.html');
  await page.waitForFunction(() => window.GoshipAPI);
  await page.evaluate(() => window.GoshipAPI.deconnecter().then(() => window.GoshipAPI.connecter('admin@goship.demo', 'demo1234')));
  await page.goto(SITE + '/admin.html');
  await page.waitForSelector('[data-ecran="code"]:not([hidden]), [data-ecran="tableau"]:not([hidden])');
  return page;
}

const visible = (page, sel) => page.evaluate((s) => { const n = document.querySelector(s); return !!n && !n.closest('[hidden]') && !n.hidden; }, sel);
const texte = (page, sel) => page.evaluate((s) => { const n = document.querySelector(s); return n ? n.textContent.trim() : null; }, sel);

async function main() {
  const navigateur = await chromium.launch();

  console.log('A. Un administrateur protégé se connecte : le code d\'abord');
  let page = await nouvellePage(navigateur, { active: true });
  verifier('l\'écran du code, pas le tableau de bord', [await visible(page, '[data-ecran="code"]'), await visible(page, '[data-ecran="tableau"]')], [true, false]);
  verifier('le champ du code, pas l\'inscription', [await visible(page, '[data-code-bloc="saisie"]'), await visible(page, '[data-code-bloc="inscrire"]')], [true, false]);
  verifier('le champ attend un code à usage unique (saisie automatique du téléphone)',
           await page.getAttribute('#adm-code', 'autocomplete'), 'one-time-code');
  await capture(page, 'double-auth-code');
  await page.fill('#adm-code', '12');
  await page.click('form[data-form="double-auth-code"] [data-envoyer]');
  verifier('trop court : la page le dit sans rien envoyer', await texte(page, 'form[data-form="double-auth-code"] [data-form-erreur]'), 'Tapez les 6 chiffres du code.');
  await page.fill('#adm-code', '000000');
  await page.click('form[data-form="double-auth-code"] [data-envoyer]');
  await page.waitForFunction(() => /Code incorrect/.test(document.querySelector('form[data-form="double-auth-code"] [data-form-erreur]').textContent));
  verifier('mauvais code : refusé, le champ est vidé', [await visible(page, '[data-ecran="code"]'), await page.inputValue('#adm-code')], [true, '']);
  await page.fill('#adm-code', '123456');
  await page.click('form[data-form="double-auth-code"] [data-envoyer]');
  await page.waitForSelector('[data-ecran="tableau"]:not([hidden])');
  verifier('bon code : le tableau de bord s\'ouvre', await visible(page, '[data-ecran="tableau"]'), true);
  verifier('protégé : pas de bandeau', await visible(page, '[data-double-auth-bandeau]'), false);
  await page.click('[data-action="reglages"]').catch(() => page.evaluate(() => document.querySelector('[data-dialogue="reglages"]').showModal()));
  await page.waitForSelector('[data-dialogue="reglages"][open]');
  await page.click('[data-reglages-rubrique="compte"]');
  verifier('réglages > Mon compte : « Activée »', await texte(page, '[data-reglages-double-auth]'), 'Activée');
  verifier('… et de quoi inscrire un second appareil', await visible(page, '[data-double-auth-reglages]'), true);
  await page.close();

  console.log('\nB. Un administrateur pas encore protégé : le bandeau, puis l\'inscription');
  page = await nouvellePage(navigateur, { active: false });
  verifier('le tableau de bord s\'ouvre sans code', await visible(page, '[data-ecran="tableau"]'), true);
  verifier('le bandeau « Protégez votre compte » est là', await visible(page, '[data-double-auth-bandeau]'), true);
  await capture(page, 'double-auth-bandeau');
  await page.click('[data-double-auth-bandeau] [data-action="double-auth-activer"]');
  await page.waitForSelector('[data-dialogue="double-auth"][open] [data-double-auth-etapes]:not([hidden])');
  verifier('la fenêtre montre le QR code de Supabase (image data:, aucun autre site)',
           (await page.getAttribute('[data-double-auth-qr]', 'src')).slice(0, 19), 'data:image/svg+xml;');
  verifier('… et la clé à taper, par groupes de 4', await texte(page, '[data-double-auth-cle]'), 'JBSW Y3DP EHPK 3PXP');
  await capture(page, 'double-auth-inscription');
  await page.fill('[data-double-auth-code]', '999999');
  await page.click('[data-double-auth-confirmer]');
  await page.waitForFunction(() => !document.querySelector('[data-double-auth-erreur]').hidden);
  verifier('mauvais premier code : refusé, la fenêtre reste ouverte',
           [await page.evaluate(() => document.querySelector('[data-dialogue="double-auth"]').open), /Code incorrect/.test(await texte(page, '[data-double-auth-erreur]'))],
           [true, true]);
  await page.fill('[data-double-auth-code]', '123456');
  await page.click('[data-double-auth-confirmer]');
  await page.waitForFunction(() => !document.querySelector('[data-dialogue="double-auth"]').open);
  await page.waitForFunction(() => document.querySelector('[data-double-auth-bandeau]').hidden);
  verifier('bon code : la fenêtre se ferme sans question, le bandeau disparaît', true, true);
  verifier('le message le confirme', await texte(page, '[data-toast]'), 'Double authentification activée : le code sera demandé à chaque connexion.');
  await page.click('[data-onglet-vue="equipe"]');
  await page.waitForSelector('[data-lignes="equipe"] tr');
  await page.waitForTimeout(200);
  const badges = await page.evaluate(() => [document.querySelectorAll('[data-lignes="equipe"] .gs-badge--double-auth').length,
                                            document.querySelectorAll('[data-lignes="equipe"] .gs-badge--sans-double-auth').length]);
  verifier('onglet Équipe : un compte protégé, les autres « Mot de passe seul »', [badges[0], badges[1] > 0], [1, true]);
  await capture(page, 'double-auth-equipe');
  verifier('l\'administrateur voit « obligatoire : non » et le bouton pour l\'exiger',
           [await texte(page, '[data-double-auth-obligatoire-etat]'), await texte(page, '[data-action="double-auth-obligatoire"]')],
           ['non', 'Rendre obligatoire pour l’équipe']);
  await page.click('[data-action="double-auth-obligatoire"]');
  await page.waitForSelector('[data-dialogue="motif"][open]');
  await page.fill('form[data-form="motif"] [name="motif"]', 'Toute l\'équipe est équipée');
  await page.click('[data-motif-valider]');
  await page.waitForFunction(() => document.querySelector('[data-double-auth-obligatoire-etat]').textContent === 'oui');
  verifier('avec un motif : la base est appelée, l\'état passe à « oui »',
           [await page.evaluate(() => JSON.stringify(window.__mfa.reglages)), await texte(page, '[data-action="double-auth-obligatoire"]')],
           [JSON.stringify([[true, 'Toute l\'équipe est équipée']]), 'Ne plus l’exiger']);
  await page.close();

  console.log('\nC. Obligatoire, sans appareil : inscrire le sien pour entrer');
  page = await nouvellePage(navigateur, { active: false, obligatoire: true });
  verifier('l\'écran du code propose d\'inscrire son téléphone',
           [await visible(page, '[data-ecran="code"]'), await visible(page, '[data-code-bloc="saisie"]'), await visible(page, '[data-code-bloc="inscrire"]')],
           [true, false, true]);
  await page.click('[data-code-bloc="inscrire"] [data-action="double-auth-activer"]');
  await page.waitForSelector('[data-dialogue="double-auth"][open] [data-double-auth-etapes]:not([hidden])');
  await page.fill('[data-double-auth-code]', '123456');
  await page.click('[data-double-auth-confirmer]');
  await page.waitForSelector('[data-ecran="tableau"]:not([hidden])');
  verifier('premier code donné : le tableau de bord s\'ouvre, sans bandeau',
           [await visible(page, '[data-ecran="tableau"]'), await visible(page, '[data-double-auth-bandeau]')], [true, false]);
  await page.close();

  console.log('\nD. En anglais, et sur un téléphone');
  page = await nouvellePage(navigateur, { active: true }, { langue: 'en', largeur: 390, hauteur: 844 });
  await page.waitForTimeout(300);
  verifier('l\'écran du code est traduit', await texte(page, '[data-ecran="code"] h1'), 'Verification code');
  verifier('… sa consigne aussi', await texte(page, '[data-code-bloc="saisie"] p'),
           'Open your authenticator app and enter the 6-digit code shown for Goship Express.');
  verifier('aucun débordement horizontal à 390 px',
           await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true);
  await capture(page, 'double-auth-code-telephone-en');
  await page.close();

  console.log('\nE. Une base sans supabase-double-auth.sql (et le mode démonstration) : rien ne change');
  page = await nouvellePage(navigateur, { absent: true });
  verifier('le tableau de bord s\'ouvre directement', await visible(page, '[data-ecran="tableau"]'), true);
  verifier('ni bandeau, ni ligne dans les réglages',
           [await visible(page, '[data-double-auth-bandeau]'), await page.evaluate(() => document.querySelector('[data-reglages-double-auth-ligne]').hidden)],
           [false, true]);
  await page.close();

  verifier('aucune erreur JavaScript', erreursJs, []);
  verifier('aucun appel à la vraie base (supabase.co)', appelsSupabase, 0);
  await navigateur.close();
  console.log('\n' + resultats.length + ' vérifications, ' + resultats.filter(Boolean).length + ' réussies.');
  process.exit(resultats.every(Boolean) ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
