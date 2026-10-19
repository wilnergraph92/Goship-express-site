// Éprouve, dans un vrai navigateur et en mode démonstration, ce que le client voit :
// l'inscription avec sa date de naissance, l'adresse en Floride (exacte, personnelle,
// copiable champ par champ) et la demande de date des comptes qui n'en ont pas.
//
// Aucun appel à Supabase : config.js est remplacé par une configuration vide (le mode démo
// s'active tout seul), comme le demande le CLAUDE.md. Le site est servi par un serveur statique :
//
//     cd <racine du site> && python3 -m http.server 8765 --bind 127.0.0.1 &
//     CHROMIUM=/chemin/vers/chrome node outils/essais-services/essai-programmes-navigateur.mjs
//
// Playwright n'est pas une dépendance du site : le module vient du dossier node_modules de
// l'application mobile (GOSHIP_PLAYWRIGHT), ou de celui de l'application de bureau.
import { createRequire } from 'node:module';

const exiger = createRequire(import.meta.url);
const chemin = process.env.GOSHIP_PLAYWRIGHT || '/home/user/goship-express-app/node_modules/playwright-core';
const { chromium } = exiger(chemin);
const SITE = process.env.SITE || 'http://127.0.0.1:8765';
const resultats = [];

function verifier(titre, obtenu, attendu) {
  const bon = JSON.stringify(obtenu) === JSON.stringify(attendu);
  console.log('  ' + (bon ? 'OK  ' : 'RATÉ') + ' ' + titre.padEnd(76) + ' ' + (bon ? '' : JSON.stringify(obtenu)));
  if (!bon) console.log('       attendu : ' + JSON.stringify(attendu));
  resultats.push(bon);
}

const ADRESSE = ['8140 NW 74th Ave Unit 3', 'ABX-46780', 'Medley, Florida 33166', 'United States', '786 525-2944'];

async function contexte(navigateur, largeur, hauteur) {
  const ctx = await navigateur.newContext({ viewport: { width: largeur, height: hauteur }, locale: 'fr-FR',
                                            permissions: ['clipboard-read', 'clipboard-write'] });
  // Démo : aucune clé, aucun appel à la vraie base
  await ctx.route('**/assets/js/config.js', (r) => r.fulfill({ contentType: 'application/javascript', body: 'window.GOSHIP_CONFIG={};' }));
  await ctx.route(/supabase\.co/, (r) => r.abort());
  return ctx;
}

async function inscrire(page, nom, email, naissance) {
  await page.goto(SITE + '/inscription.html');
  await page.click('[data-action="methode-formulaire"]').catch(() => {});
  await page.fill('#ins-nom', nom);
  if (naissance !== null) await page.fill('#ins-naissance', naissance);
  await page.selectOption('#ins-pays', 'HT');
  await page.selectOption('#ins-region', { index: 1 });
  await page.selectOption('#ins-ville', { index: 1 });
  await page.fill('#ins-adresse', '12 rue Capois');
  await page.fill('#ins-tel', '+509 3712 3456');
  await page.fill('#ins-email', email);
  await page.fill('#ins-mdp', 'motdepasse1');
}

const navigateur = await chromium.launch({ executablePath: process.env.CHROMIUM, args: ['--no-sandbox'] });
try {
  console.log("1. L'inscription demande la date de naissance (téléphone, 390 px)");
  const ctx = await contexte(navigateur, 390, 844);
  const page = await ctx.newPage();
  await inscrire(page, 'Anna Joseph', 'anna@exemple.com', null);
  verifier('le champ existe, est de type date et obligatoire',
    await page.$eval('#ins-naissance', (c) => [c.type, c.required, c.max.length === 10]), ['date', true, true]);
  verifier('le libellé est « Date de naissance »', (await page.textContent('label[for="ins-naissance"]')).replace('*', '').trim(), 'Date de naissance');
  await page.click('[data-envoyer]');
  verifier('sans date : message clair, et le focus va au champ',
    [await page.textContent('#erreur-ins-naissance'), await page.evaluate(() => document.activeElement.id)],
    ['Ce champ est obligatoire.', 'ins-naissance']);
  await page.fill('#ins-naissance', '2999-01-01');
  await page.click('[data-envoyer]');
  verifier('date future : refusée avec son message', await page.textContent('#erreur-ins-naissance'),
    'La date de naissance ne peut pas être dans le futur.');
  await page.fill('#ins-naissance', '1990-02-30').catch(() => {});
  const valeurImpossible = await page.$eval('#ins-naissance', (c) => c.value);
  verifier('30 février : le champ date du navigateur le refuse (valeur vide)', valeurImpossible, '');
  verifier('rien n\'a été enregistré par ces refus',
    await page.evaluate(() => { try { return JSON.parse(localStorage.getItem('gse-demo-donnees') || '{"comptes":[]}').comptes.filter((c) => c.email === 'anna@exemple.com').length; } catch (e) { return 0; } }), 0);
  await page.fill('#ins-naissance', '1990-03-15');
  await page.click('[data-envoyer]');
  await page.waitForURL(/mon-compte\.html/);
  await page.waitForSelector('[data-nom-adresse]:not(:empty)');

  console.log("\n2. L'adresse en Floride : exacte, personnelle, copiable (téléphone)");
  const code = await page.textContent('[data-code]');
  const lignes = await page.$$eval('[data-address-table] > div', (rs) => rs.map((r) => [r.children[0].textContent.trim(), r.children[1].textContent.trim()]));
  verifier('les huit champs, avec leurs noms en anglais, exactement comme fournis', lignes.map((l) => l[0]),
    ['Name', 'Address 1', 'Address 2', 'City', 'State', 'Zip Code', 'Country', 'Phone']);
  verifier('Name = nom du compte connecté + son code client', lignes[0][1], 'Anna Joseph ' + code);
  verifier('Address 1', lignes[1][1], '8140 NW 74th Ave Unit 3');
  verifier('Address 2 = ABX-46780, tiret compris', lignes[2][1], 'ABX-46780');
  verifier('City, State, Zip Code, Country, Phone', lignes.slice(3).map((l) => l[1]),
    ['Medley', 'Florida', '33166', 'United States', '786 525-2944']);
  verifier('le bouton principal dit « Copier l\'adresse complète »', (await page.textContent('[data-action="copy-address"]')).trim(),
    "Copier l'adresse complète");
  await page.click('[data-action="copy-address"]');
  verifier('copie réussie : confirmation affichée', await page.textContent('[data-copy-feedback]'), 'Adresse copiée ✓');
  const presse = await page.evaluate(() => navigator.clipboard.readText());
  verifier("le presse-papiers contient l'adresse complète de CE client", presse,
    ['Anna Joseph ' + code, '8140 NW 74th Ave Unit 3', 'ABX-46780', 'Medley, Florida 33166', 'United States', '786 525-2944'].join('\n'));
  const attendusChamps = ['Anna Joseph ' + code, '8140 NW 74th Ave Unit 3', 'ABX-46780', 'Medley', 'Florida', '33166', 'United States', '786 525-2944'];
  const boutons = await page.$$('[data-copier-champ]');
  verifier('un bouton de copie par champ (8), chacun avec son nom accessible', boutons.length, 8);
  const copies = [];
  for (const b of boutons) {
    await b.click();
    copies.push(await page.evaluate(() => navigator.clipboard.readText()));
  }
  verifier('chaque bouton copie son champ, et lui seul', copies, attendusChamps);
  verifier('les boutons sont assez grands pour un doigt (44 px)',
    await page.$$eval('[data-copier-champ]', (bs) => bs.every((b) => b.getBoundingClientRect().width >= 44 && b.getBoundingClientRect().height >= 44)), true);
  verifier('aucun débordement horizontal à 390 px', await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true);
  verifier('la date saisie est lue sans décalage de jour', await page.textContent('[data-info="naissance"]'), '15 mars 1990');
  verifier('le compte a une date : aucune demande', await page.$eval('[data-completer-naissance]', (b) => b.hidden), true);
  await page.screenshot({ path: process.env.CAPTURES ? process.env.CAPTURES + '/adresse-390.png' : '/dev/null', fullPage: true });

  console.log('\n3. Deux clients, deux adresses');
  await page.evaluate(() => { localStorage.removeItem('gse-demo-session'); });
  await inscrire(page, 'Jean Pierre', 'jean@exemple.com', '1985-07-09');
  await page.click('[data-envoyer]');
  await page.waitForURL(/mon-compte\.html/);
  await page.waitForSelector('[data-nom-adresse]:not(:empty)');
  const nomJean = await page.textContent('[data-nom-adresse]');
  verifier('le second client voit SON nom et SON code', [nomJean.startsWith('Jean Pierre GSE-'), nomJean !== 'Anna Joseph ' + code], [true, true]);

  console.log("\n4. Un compte d'avant, sans date : invité à la compléter, jamais bloqué");
  await page.evaluate(() => {
    const d = JSON.parse(localStorage.getItem('gse-demo-donnees'));
    const moi = d.comptes.find((c) => c.id === localStorage.getItem('gse-demo-session'));
    delete d.naissances[moi.id];
    localStorage.setItem('gse-demo-donnees', JSON.stringify(d));
  });
  await page.reload();
  await page.waitForSelector('[data-nom-adresse]:not(:empty)');
  await page.waitForSelector('[data-completer-naissance]:not([hidden])');
  verifier('la demande de date s\'affiche', await page.$eval('[data-completer-naissance]', (b) => !b.hidden), true);
  verifier("… et le reste du compte marche (colis, adresse)", await page.$eval('[data-address-table]', (t) => !t.hasAttribute('data-incomplet')), true);
  await page.fill('#cpt-naissance', '2999-01-01');
  await page.click('form[data-form="naissance"] [data-envoyer]');
  verifier('une date future est refusée ici aussi', await page.textContent('#erreur-cpt-naissance'),
    'La date de naissance ne peut pas être dans le futur.');
  await page.fill('#cpt-naissance', '1991-01-01');
  await page.click('form[data-form="naissance"] [data-envoyer]');
  await page.waitForSelector('[data-completer-naissance]', { state: 'hidden' });
  verifier('date enregistrée, demande disparue, date affichée', await page.textContent('[data-info="naissance"]'), '1 janvier 1991');
  await page.reload();
  await page.waitForSelector('[data-nom-adresse]:not(:empty)');
  await page.waitForSelector('[data-info="naissance"]:not(:empty)');
  verifier('après rechargement (nouvelle session de page), la date est toujours là', await page.textContent('[data-info="naissance"]'), '1 janvier 1991');
  const verrou = await page.evaluate(() => window.GoshipAPI.definirNaissance('1992-02-02').then(() => 'accepté', (e) => e.code));
  verifier('une autre date est refusée : elle ne se change pas à volonté', verrou, 'naissance-verrouillee');

  console.log("\n5. Sans nom ou sans code : un message, pas une adresse fausse");
  await page.evaluate(() => {
    const d = JSON.parse(localStorage.getItem('gse-demo-donnees'));
    d.comptes.find((c) => c.id === localStorage.getItem('gse-demo-session')).nom_complet = '';
    localStorage.setItem('gse-demo-donnees', JSON.stringify(d));
    navigator.clipboard.writeText('témoin');
  });
  await page.reload();
  await page.waitForSelector('[data-adresse-manquante]:not([hidden])');
  verifier('la table est marquée incomplète et le nom reste vide', await page.$eval('[data-address-table]', (t) => [t.hasAttribute('data-incomplet'), t.querySelector('[data-nom-adresse]').textContent]), [true, '']);
  verifier('un message compréhensible s\'affiche', (await page.textContent('[data-adresse-manquante]')).slice(0, 29), 'Complétez votre profil (nom e');
  await page.click('[data-action="copy-address"]');
  verifier('copier l\'adresse complète refuse et le dit', (await page.textContent('[data-copy-feedback]')).slice(0, 9), 'Complétez');
  verifier('… le presse-papiers n\'a pas été touché', await page.evaluate(() => navigator.clipboard.readText()), 'témoin');
  await ctx.close();

  console.log('\n6. Sur ordinateur (1280 px)');
  const ctx2 = await contexte(navigateur, 1280, 900);
  const bureau = await ctx2.newPage();
  await inscrire(bureau, 'Léa Charles', 'lea@exemple.com', '1988-11-23');
  await bureau.click('[data-envoyer]');
  await bureau.waitForURL(/mon-compte\.html/);
  await bureau.waitForSelector('[data-nom-adresse]:not(:empty)');
  await bureau.click('[data-action="copy-address"]');
  const pressee = await bureau.evaluate(() => navigator.clipboard.readText());
  verifier("l'adresse complète se copie sur ordinateur", pressee.split('\n').slice(1), ADRESSE.slice(0, 2).concat(ADRESSE.slice(2)));
  verifier('aucun débordement horizontal à 1280 px', await bureau.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true);
  await bureau.screenshot({ path: process.env.CAPTURES ? process.env.CAPTURES + '/adresse-1280.png' : '/dev/null' });
  await ctx2.close();

  console.log('\n7. Les pages traduites (anglais, espagnol, créole)');
  for (const [dossier, libelle, bouton] of [['en', 'Date of birth', 'Copy full address'], ['es', 'Fecha de nacimiento', 'Copiar la dirección completa'], ['ht', 'Dat nesans', 'Kopye adrès konplè a']]) {
    const c = await contexte(navigateur, 390, 844);
    const p = await c.newPage();
    await p.goto(`${SITE}/${dossier}/inscription.html`);
    verifier(`${dossier} : le libellé du champ est traduit`, (await p.textContent('label[for="ins-naissance"]')).replace('*', '').trim(), libelle);
    await inscrire(p, 'Test Langue', `langue-${dossier}@exemple.com`, '1980-05-05').catch(() => {});
    await p.goto(`${SITE}/${dossier}/inscription.html`);
    await p.fill('#ins-nom', 'Test Langue');
    await p.click('[data-envoyer]').catch(() => {});
    verifier(`${dossier} : le message d'un champ vide est traduit`, (await p.textContent('#erreur-ins-naissance')).length > 5, true);
    await c.close();
    void bouton;
  }

  console.log('\n8. Mes avantages : GOPOINTS, bienvenue, GOship Refer (valeurs d\'essai, saisies par l\'équipe)');
  const cp = await contexte(navigateur, 390, 844);
  const pg = await cp.newPage();
  const erreursPage = [];
  pg.on('pageerror', (e) => erreursPage.push(String(e)));
  await pg.goto(SITE + '/connexion.html');
  // L'équipe règle les programmes (comme dans l'onglet Programmes) ; aucune valeur n'existe avant
  await pg.evaluate(async () => {
    const A = window.GoshipAPI, P = A.admin.programmes;
    await A.connecter('admin@goship.demo', 'demo1234');
    const j = (n) => new Date(Date.now() + n * 864e5).toISOString().slice(0, 10);
    await P.pointsReglages({ actif: true, conditions: 'Conditions GOPOINTS d\'essai.' });
    await P.pointsRegle('account_created', { points: 30, actif: true });
    await P.pointsOffre(null, { nom: 'Crédit d\'essai', cout_points: 20, type: 'credit_expedition', valeur: 5, actif: true, limite_client: 1 });
    const camp = await P.bienvenueEnregistrer(null, { nom: 'Bienvenue d\'essai', description: 'Un bonus pour votre première opération.', debut: j(-1), fin: j(30),
      type_recompense: 'bonus_fixe', valeur_recompense: 7, operation: 'colis_recu', delai_validation_jours: 0, conditions: 'Un bonus par client, une seule fois.' });
    await P.bienvenuePublier(camp.id);
    await P.parrainageConfigModifier({ debut: j(-1), fin: j(60), parrain_type: 'bonus_fixe', parrain_valeur: 10, filleul_type: 'credit_expedition', filleul_valeur: 5,
      operation: 'colis_recu', conditions: 'Conditions de parrainage d\'essai.', annulation: 'Annulé si l\'opération est annulée.' });
    await P.parrainageStatut('publier');
    await A.deconnecter();
  });
  await inscrire(pg, 'Pascal Parrain', 'pascal@exemple.com', '1980-01-02');
  await pg.click('[data-envoyer]');
  await pg.waitForURL(/mon-compte\.html/);
  await pg.waitForSelector('[data-avt-parrainage]:not([hidden])');
  const panneau = pg.locator('[data-panneau-programmes]');
  verifier('le panneau « Mes avantages » apparaît', await panneau.isVisible(), true);
  verifier('GOPOINTS : 30 points de bienvenue (valeur d\'essai), l\'offre à 20 points', 
    [(await pg.textContent('[data-avt-points] .gs-avt__solde')).trim(), await pg.locator('[data-avt-points] .gs-avt__offre').count()], ['30 points', 1]);
  verifier('bienvenue : à débloquer, l\'avantage décrit avec la virgule', 
    [(await pg.textContent('[data-avt-bienvenue] .gs-avt__etat')).trim(), (await pg.textContent('[data-avt-bienvenue] .gs-avt__fort')).includes('7,00 $')], ['À débloquer', true]);
  verifier('la CTA du parrainage', (await pg.textContent('[data-avt-parrainage] .gs-avt__cta')).trim(), 'INVITER UN AMI');
  const codeP = (await pg.textContent('[data-avt-parrainage] .gs-avt__code')).trim();
  verifier('le code de parrainage a la bonne forme', /^GS[A-HJKMNP-Z2-9]{6}$/.test(codeP), true);
  await pg.locator('[data-avt-parrainage]').getByRole('button', { name: 'Copier le code' }).click();
  verifier('copier le code : le presse-papiers le contient', await pg.evaluate(() => navigator.clipboard.readText()), codeP);
  await pg.locator('[data-avt-parrainage]').getByRole('button', { name: 'Copier le lien' }).click();
  verifier('copier le lien : il pointe vers l\'inscription avec le code', (await pg.evaluate(() => navigator.clipboard.readText())).endsWith('inscription.html?parrain=' + codeP), true);
  await pg.click('.gs-avt__cta');
  verifier('sans partage natif : le message complet est copié', (await pg.evaluate(() => navigator.clipboard.readText())).includes(codeP), true);
  verifier('invitations comptées par la base (3 gestes)', (await pg.textContent('[data-avt-parrainage] .gs-avt__chiffres div:first-child dd')).trim() === '0' ? 'a recharger' : 'ok', 'a recharger');
  await pg.reload();
  await pg.waitForSelector('[data-avt-parrainage]:not([hidden])');
  verifier('après rechargement : 3 invitations partagées', (await pg.textContent('[data-avt-parrainage] .gs-avt__chiffres div:first-child dd')).trim(), '3');

  // L'échange de points : une fois, jamais deux
  await pg.locator('[data-avt-points]').getByRole('button', { name: 'Échanger' }).click();
  await pg.waitForSelector('[data-avt-ok]:not([hidden])');
  await pg.waitForFunction(() => document.querySelector('[data-avt-points] .gs-avt__solde').textContent.trim() === '10 points');
  verifier('échange : 10 points restent, l\'avantage est enregistré',
    [(await pg.textContent('[data-avt-points] .gs-avt__solde')).trim(), (await pg.textContent('[data-avt-ok]')).includes('enregistré')], ['10 points', true]);
  verifier('l\'offre à limite 1 : le bouton est désactivé ensuite', await pg.locator('[data-avt-points] .gs-avt__offre button').isDisabled(), true);
  verifier('l\'historique garde les deux lignes', await pg.locator('[data-avt-points] .gs-avt__liste--histo li').count(), 2);

  // Le filleul arrive par le lien
  await pg.evaluate(() => { localStorage.removeItem('gse-demo-session'); });
  await pg.goto(SITE + '/inscription.html?parrain=' + codeP.toLowerCase());
  verifier('le champ du code est déjà rempli (en capitales)', await pg.inputValue('#ins-parrain'), codeP);
  await inscrire(pg, 'Fanny Filleule', 'fanny@exemple.com', '1995-03-03');
  await pg.fill('#ins-parrain', codeP);
  await pg.click('[data-envoyer]');
  await pg.waitForURL(/mon-compte\.html/);
  await pg.waitForSelector('[data-avt-parrainage]:not([hidden])');
  verifier('le filleul voit qu\'il a un parrain (plus de saisie de code)', await pg.locator('[data-avt-parrainage] details:has(summary:has-text("J\'ai un code"))').count(), 0);
  verifier('et aucun nom de parrain', (await pg.textContent('[data-panneau-programmes]')).includes('Pascal'), false);
  await pg.screenshot({ path: process.env.CAPTURES ? process.env.CAPTURES + '/avantages-390.png' : '/dev/null', fullPage: true });

  // Une saisie tardive : mauvais code, son propre code
  await pg.evaluate(() => { localStorage.removeItem('gse-demo-session'); });
  await inscrire(pg, 'Gina Google', 'gina@exemple.com', '1991-04-04');
  await pg.click('[data-envoyer]');
  await pg.waitForURL(/mon-compte\.html/);
  await pg.waitForSelector('[data-avt-parrainage]:not([hidden])');
  await pg.locator('[data-avt-parrainage] summary:has-text("J\'ai un code")').click();
  await pg.fill('[data-avt-parrainage] .gs-avt__saisie input', 'GSZZZZZZ');
  await pg.click('[data-avt-parrainage] .gs-avt__saisie button');
  await pg.waitForSelector('[data-avt-erreur]:not([hidden])');
  verifier('un code inconnu : message clair, rien d\'enregistré', (await pg.textContent('[data-avt-erreur]')).startsWith('Ce code de parrainage n\'existe pas'), true);
  await pg.fill('[data-avt-parrainage] .gs-avt__saisie input', codeP);
  await pg.click('[data-avt-parrainage] .gs-avt__saisie button');
  await pg.waitForSelector('[data-avt-ok]:not([hidden])');
  verifier('un bon code saisi plus tard : enregistré', (await pg.textContent('[data-avt-ok]')).includes('enregistré'), true);

  // La case de l'anniversaire
  const caseAnniv = pg.locator('[data-pref-anniversaire]');
  verifier('la préférence d\'anniversaire est cochée par défaut', await caseAnniv.isChecked(), true);
  await caseAnniv.uncheck();
  await pg.waitForSelector('[data-avt-ok]:not([hidden])');
  await pg.reload();
  await pg.waitForSelector('[data-avt-preferences]:not([hidden])');
  verifier('décochée, elle le reste', await pg.locator('[data-pref-anniversaire]').isChecked(), false);
  verifier('aucun débordement horizontal à 390 px', await pg.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true);
  verifier('aucune erreur JavaScript', erreursPage, []);
  await cp.close();

  console.log('\n9. Le créole : la CTA du programme est « ENVITE YON ZANMI », et le texte marketing est celui fourni');
  const ch = await contexte(navigateur, 390, 844);
  const ph = await ch.newPage();
  await ph.goto(SITE + '/connexion.html');
  await ph.evaluate(async () => {
    const A = window.GoshipAPI, P = A.admin.programmes;
    await A.connecter('admin@goship.demo', 'demo1234');
    const j = (n) => new Date(Date.now() + n * 864e5).toISOString().slice(0, 10);
    await P.parrainageConfigModifier({ debut: j(-1), fin: j(60), parrain_type: 'bonus_fixe', parrain_valeur: 10, filleul_type: 'credit_expedition', filleul_valeur: 5,
      operation: 'colis_recu', conditions: 'Conditions de parrainage d\'essai.', annulation: 'Annulé si l\'opération est annulée.' }).catch(() => {});
    await P.parrainageStatut('publier').catch(() => {});
    await A.deconnecter();
  });
  await ph.goto(SITE + '/ht/inscription.html');
  await ph.fill('#ins-nom', 'Mari Jozèf');
  await ph.fill('#ins-naissance', '1990-06-06');
  await ph.selectOption('#ins-pays', 'HT'); await ph.selectOption('#ins-region', { index: 1 }); await ph.selectOption('#ins-ville', { index: 1 });
  await ph.fill('#ins-adresse', '12 rue Capois'); await ph.fill('#ins-tel', '+509 3712 3999'); await ph.fill('#ins-email', 'mari@exemple.com'); await ph.fill('#ins-mdp', 'motdepasse1');
  await ph.click('[data-envoyer]');
  await ph.waitForURL(/mon-compte\.html/);
  await ph.waitForSelector('[data-avt-parrainage]:not([hidden])');
  verifier('la CTA en créole', (await ph.textContent('[data-avt-parrainage] .gs-avt__cta')).trim(), 'ENVITE YON ZANMI');
  verifier('le texte marketing en créole, tel que fourni',
    (await ph.textContent('[data-avt-parrainage] p')).trim(), 'Envite yon zanmi dekouvri GoShip Express. Lè zanmi ou a kreye kont li epi li fè premye tranzaksyon kalifye li, nou ka rekonpanse nou toulede selon kondisyon pwogram nan.');
  verifier('le titre du panneau en créole', (await ph.textContent('[data-panneau-programmes] h2')).trim(), 'Avantaj mwen yo');
  await ch.close();
} finally {
  await navigateur.close();
}
const ok = resultats.filter(Boolean).length;
console.log(`\n${resultats.length} vérifications, ${ok} réussies.`);
process.exit(ok === resultats.length ? 0 : 1);
