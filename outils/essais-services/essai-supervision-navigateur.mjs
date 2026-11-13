// Éprouve, dans un vrai navigateur et en mode démonstration, la Phase 6 du suivi universel :
// l'onglet « Suivi transporteurs » du tableau de bord (santé, à surveiller, tous les suivis),
// la fiche d'un suivi, la section « Chez le transporteur » de la fiche d'un colis, le pilotage
// réservé à l'administrateur, les rôles, les quatre langues, l'apparence sombre, le téléphone.
// La copie démo (api.js) rend les mêmes formes que la base : les clés attendues ci-dessous sont
// celles de supervision_suivi et fiche_suivi_externe (outils/supabase-supervision-suivi.sql),
// que essai-supervision-suivi.py éprouve côté SQL.
//
// Aucun appel à Supabase : config.js est remplacé par une configuration vide (le mode démo
// s'active tout seul) et toute requête vers supabase.co est coupée (et comptée).
//
//     cd <racine du site> && python3 -m http.server 8765 --bind 127.0.0.1 &
//     node outils/essais-services/essai-supervision-navigateur.mjs
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

// Les clés des réponses de la base (supabase-supervision-suivi.sql)
const CLES = {
  reponse: ['a_surveiller', 'alertes', 'fournisseurs', 'noms', 'page', 'pages', 'peut_piloter', 'sante', 'seuils', 'suivis', 'total'],
  sante: ['a_relire', 'arrets', 'derniere_lecture_ok', 'en_cours', 'en_retard', 'en_service', 'erreurs_24h', 'fournisseur',
          'quota_lu_le', 'quota_restant'],
  compteurs: ['AUTRE_CLIENT', 'INCIDENT', 'LIVRE_NON_RECU', 'NUMERO_REFUSE', 'SILENCE', 'total'],
  cas: ['achat', 'colis', 'depuis', 'raison', 'suivi'],
  achat: ['cree_le', 'client', 'description', 'id', 'magasin', 'numero_suivi'],
  ligne: ['achats', 'clients', 'code_resultat', 'colis', 'cree_le', 'derniere_erreur', 'dernier_evenement_le', 'dernier_lieu',
          'etape', 'etat', 'evenements', 'fin_motif', 'fournisseur', 'id', 'inscrit_le', 'numero', 'origine', 'statut',
          'transporteur', 'transporteur_nom'],
  fiche: ['achats', 'colis', 'evenements', 'journal', 'noms', 'suivi'],
  fournisseur: ['actif', 'arret_motif', 'code', 'conformite', 'consommes', 'essai', 'maj_le', 'marge_quota', 'nom', 'note',
                'plafond_essai', 'plafond_mensuel', 'prealertes_ce_mois', 'quota_lu_le', 'quota_restant', 'suivre_prealertes',
                'transporteurs_exclus']
};
const cles = (o) => Object.keys(o || {}).sort();
Object.keys(CLES).forEach((k) => CLES[k].sort());

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

async function connecter(page, email) {
  await page.goto(SITE + '/admin.html');
  await page.waitForFunction(() => window.GoshipAPI);
  await page.evaluate((e) => window.GoshipAPI.deconnecter().then(() => window.GoshipAPI.connecter(e, 'demo1234')), email);
  await page.goto(SITE + '/admin.html');
  await page.waitForSelector('[data-ecran="tableau"]:not([hidden])');
}

async function ouvrirOnglet(page) {
  await page.click('[data-onglet-vue="suivi"]');
  await page.waitForSelector('[data-vue="suivi"]:not([hidden])');
  await attendre(page);
}

async function attendre(page) {
  await page.waitForTimeout(150);
  await page.waitForFunction(() => !document.querySelector('[data-vue="suivi"]').hasAttribute('aria-busy'));
}

async function lire(page) {
  return page.evaluate(() => {
    const v = document.querySelector('[data-vue="suivi"]');
    const txt = (n) => (n ? n.textContent.trim() : '');
    return {
      chiffres: Array.from(v.querySelectorAll('.gs-sv__chiffre')).map((c) => [txt(c.querySelector('dt')), txt(c.querySelector('.gs-sv__valeur')),
                                                                                txt(c.querySelector('.gs-sv__detail'))]),
      actions: !v.querySelector('[data-suivi-actions]').hidden,
      arreter: !v.querySelector('[data-suivi-action="arreter"]').hidden,
      reprendre: !v.querySelector('[data-suivi-action="reprendre"]').hidden,
      raisons: Array.from(v.querySelectorAll('[data-lignes="surveiller"] tr')).map((tr) => tr.getAttribute('data-raison')),
      videSurv: !v.querySelector('[data-vide="surveiller"]').hidden,
      suivis: Array.from(v.querySelectorAll('[data-lignes="suivis"] tr')).map((tr) => txt(tr.querySelector('.gs-cellule-num'))),
      puces: Array.from(v.querySelectorAll('[data-suivi-raisons] .gs-sv__puce')).map((b) => txt(b))
    };
  });
}

// Des données que les exemples n'ont pas : un colis reçu chez Jean-Robert avec le numéro de
// l'achat de Marie-Ange, et un achat annoncé il y a 40 jours sans aucune nouvelle
async function semer(page) {
  await page.evaluate(() => {
    const d = JSON.parse(localStorage.getItem('gse-demo-donnees'));
    const qui = (e) => d.comptes.find((c) => c.email === e);
    const jean = qui('jean-robert@exemple.com'), marie = qui('marie-ange@exemple.com');
    d.colis.push(Object.assign({}, d.colis[0], { id: 'essai-colis-autre', numero: 'GSE-90001', client_id: jean.id,
                                                 suivi_transporteur: 'TBA312345678901', cree_le: new Date().toISOString() }));
    d.prealertes.push({ id: 'essai-pa-silence', client_id: marie.id, magasin: 'Nike', description: 'Baskets',
                        suivi_transporteur: '1Z999AA10123456791', valeur_usd: 80, service: 'aerien', statut: 'attente',
                        colis_id: null, cree_le: new Date(Date.now() - 40 * 864e5).toISOString() });
    localStorage.setItem('gse-demo-donnees', JSON.stringify(d));
  });
}

async function piloter(page, action, champs) {
  await page.click(`[data-suivi-action="${action}"]`);
  await page.waitForSelector('[data-dialogue="suivi-pilote"][open]');
  for (const [sel, val] of Object.entries(champs || {})) await page.fill(`[data-dialogue="suivi-pilote"] ${sel}`, val);
  await page.click('[data-suivi-pilote-confirmer]');
  await page.waitForTimeout(700);
}

const navigateur = await chromium.launch({ executablePath: process.env.CHROMIUM, args: ['--no-sandbox'] });
try {
  const ctx = await contexte(navigateur, 1440, 960);
  const page = await ctx.newPage();
  surveiller(page);

  console.log('1. Administrateur : l\'onglet, la santé, la liste');
  await connecter(page, 'admin@goship.demo');
  await page.evaluate(() => window.GoshipAPI.admin.exemples());
  await ouvrirOnglet(page);
  let e = await lire(page);
  verifier('le fournisseur et son état : 17TRACK, en essai, en cours de vérification',
    e.chiffres[0], ['Fournisseur', '17TRACK', 'En essai : rien n’est montré aux clients · En cours de vérification']);
  verifier('le quota restant vient de la base (184)', e.chiffres.find((c) => c[0] === 'Quota restant')[1], '184');
  verifier('les commandes de l\'administrateur : arrêter visible, reprendre caché', [e.actions, e.arreter, e.reprendre], [true, true, false]);
  verifier('tous les suivis : un par numéro des achats d\'exemple (le reçu compris), une ligne chacun',
    e.suivis.slice().sort(), ['1Z999AA10123456784', '9400111899223399887764', 'GFUS01072196299901', 'TBA312345678901']);
  verifier('rien à surveiller dans les exemples : la phrase le dit', [e.raisons, e.videSurv], [[], true]);
  await capture(page, 'suivi-admin', true);

  console.log('\n2. À surveiller : colis reçu chez un autre client, sans nouvelles');
  await semer(page);
  await page.evaluate(() => window.GoshipSupervision.charger());
  await attendre(page);
  e = await lire(page);
  verifier('deux cas, dans l\'ordre de la base : autre client, puis sans nouvelles', e.raisons, ['AUTRE_CLIENT', 'SILENCE']);
  verifier('les puces : tous (2), reçu chez un autre client (1), sans nouvelles (1)',
    e.puces, ['Tous2', 'Reçu chez un autre client1', 'Sans nouvelles1']);
  verifier('le numéro sans nouvelles a son suivi dans la liste', e.suivis.includes('1Z999AA10123456791'), true);
  await page.click('[data-suivi-raison="SILENCE"]');
  verifier('une puce filtre les cas', (await lire(page)).raisons, ['SILENCE']);
  await page.click('[data-suivi-raison=""]');
  verifier('… « Tous » les remet', (await lire(page)).raisons, ['AUTRE_CLIENT', 'SILENCE']);
  verifier('la pré-alerte de Marie-Ange attend toujours : rien n\'est rapproché tout seul',
    await page.evaluate(() => JSON.parse(localStorage.getItem('gse-demo-donnees')).prealertes
      .find((p) => p.suivi_transporteur === 'TBA312345678901').statut), 'attente');
  await capture(page, 'suivi-surveiller', true);

  console.log('\n3. La fiche d\'un suivi');
  await page.click('[data-lignes="surveiller"] tr[data-raison="AUTRE_CLIENT"]');
  await page.waitForSelector('[data-dialogue="fiche"][open]');
  await page.waitForFunction(() => document.querySelector('[data-fiche-titre]').textContent !== 'Chargement…');
  const fiche = await page.evaluate(() => {
    const f = document.querySelector('[data-dialogue="fiche"]');
    return { titre: f.querySelector('[data-fiche-titre]').textContent, type: f.querySelector('[data-fiche-type]').textContent,
             sections: Array.from(f.querySelectorAll('.gs-fiche__section h3')).map((h) => h.textContent),
             evenements: Array.from(f.querySelectorAll('.gs-fiche__section'))
               .find((x) => x.querySelector('h3').textContent === 'Chronologie du transporteur')
               .querySelectorAll('.gs-fiche__ligne').length };
  });
  verifier('titre : le numéro ; type : suivi transporteur', [fiche.titre, fiche.type], ['TBA312345678901', 'Suivi transporteur']);
  verifier('les sections : transporteur, le suivi, achats, colis, chronologie, journal', fiche.sections,
    ['Chez le transporteur', 'Le suivi', 'Achats annoncés', 'Colis GoShip', 'Chronologie du transporteur', 'Journal des appels au fournisseur']);
  verifier('la chronologie : les trois événements du transporteur', fiche.evenements, 3);
  await capture(page, 'suivi-fiche');
  await page.click('[data-dialogue="fiche"] [data-action="fermer"]');

  console.log('\n4. Recherche et filtres');
  await page.fill('[data-recherche-suivis]', 'walmart');
  await page.waitForTimeout(400);
  await attendre(page);
  verifier('recherche d\'un magasin : son numéro seulement', (await lire(page)).suivis, ['9400111899223399887764']);
  await page.fill('[data-recherche-suivis]', '');
  await page.waitForTimeout(400);
  await page.selectOption('[data-filtre-suivis="statut"]', 'DELIVERED');
  await attendre(page);
  verifier('statut « livré par le transporteur » : le numéro GOFO', (await lire(page)).suivis, ['GFUS01072196299901']);
  await page.selectOption('[data-filtre-suivis="statut"]', '');
  await attendre(page);

  console.log('\n5. Piloter (administrateur)');
  await piloter(page, 'arreter', { '[data-suivi-pilote-motif]': 'non' });
  verifier('sans motif : la fenêtre reste ouverte et le dit',
    await page.evaluate(() => [document.querySelector('[data-dialogue="suivi-pilote"]').open,
                               document.querySelector('[data-suivi-pilote-erreur]').textContent]),
    [true, 'Indiquez un motif (5 caractères au moins).']);
  await page.fill('[data-suivi-pilote-motif]', 'Essai de l’équipe');
  await page.click('[data-suivi-pilote-confirmer]');
  await page.waitForTimeout(700);
  await attendre(page);
  e = await lire(page);
  verifier('arrêté : la santé le dit, « Reprendre » remplace « Arrêter »', [e.chiffres[0][2].split(' · ')[0], e.arreter, e.reprendre],
    ['Arrêté', false, true]);
  verifier('… journalisé avec son motif', await page.evaluate(() => {
    const j = JSON.parse(localStorage.getItem('gse-demo-donnees')).journal.slice(-1)[0];
    return [j.action, j.motif];
  }), ['fournisseur_suivi.reglage', 'Essai de l’équipe']);
  await piloter(page, 'reprendre', { '[data-suivi-pilote-motif]': 'Reprise après essai' });
  await attendre(page);
  verifier('repris : de nouveau en essai (pas encore vérifié)', (await lire(page)).chiffres[0][2].split(' · ')[0],
    'En essai : rien n’est montré aux clients');
  await piloter(page, 'plafond', { '[data-suivi-pilote-valeur]': '45', '[data-suivi-pilote-motif]': 'Plus d’achats ce mois' });
  await attendre(page);
  verifier('plafond mensuel : 45', (await lire(page)).chiffres.find((c) => c[0] === 'Pré-alertes suivies ce mois')[1], '0 / 45');
  await page.click('[data-suivi-action="suivre"]');
  await page.waitForSelector('[data-dialogue="suivi-pilote"][open]');
  verifier('suivre un numéro : la fenêtre montre le quota restant',
    await page.$eval('[data-suivi-pilote-aide] .gs-sv__quota', (n) => n.textContent.trim()), 'Quota restant 184');
  await page.fill('[data-suivi-pilote-numero]', '1z 999 aa1 0123456799');
  await page.click('[data-suivi-pilote-confirmer]');
  await page.waitForTimeout(700);
  await attendre(page);
  verifier('le numéro demandé s\'ajoute à la liste, rangé', (await lire(page)).suivis.includes('1Z999AA10123456799'), true);

  console.log('\n6. La fiche d\'un colis : « Chez le transporteur »');
  await page.evaluate(() => document.dispatchEvent(new CustomEvent('goship:fiche-colis', { detail: { numero: 'GSE-90001' } })));
  await page.waitForSelector('[data-dialogue="fiche"][open]');
  await page.waitForFunction(() => {
    const s = Array.from(document.querySelectorAll('[data-dialogue="fiche"] .gs-fiche__section'))
      .find((x) => x.querySelector('h3').textContent === 'Chez le transporteur');
    return s && !s.querySelector('.gs-fiche__attente');
  });
  verifier('la section dit le statut du transporteur et mène au suivi', await page.evaluate(() => {
    const s = Array.from(document.querySelectorAll('[data-dialogue="fiche"] .gs-fiche__section'))
      .find((x) => x.querySelector('h3').textContent === 'Chez le transporteur');
    return [!!s && s.textContent.includes('En route'), !!s && !!Array.from(s.querySelectorAll('button')).find((b) => b.textContent === 'Voir le suivi')];
  }), [true, true]);
  await page.click('[data-dialogue="fiche"] [data-action="fermer"]');

  console.log('\n7. Les formes : la démo répond comme la base');
  const r = await page.evaluate(() => window.GoshipAPI.admin.supervisionSuivi({}, 1));
  verifier('la réponse', cles(r), CLES.reponse);
  verifier('la santé', cles(r.sante), CLES.sante);
  verifier('les compteurs', cles(r.a_surveiller.compteurs), CLES.compteurs);
  verifier('un cas à surveiller, et son achat', [cles(r.a_surveiller.cas[0]), cles(r.a_surveiller.cas[0].achat)], [CLES.cas, CLES.achat]);
  verifier('une ligne de la liste', cles(r.suivis[0]), CLES.ligne);
  verifier('un fournisseur', cles(r.fournisseurs[0]), CLES.fournisseur);
  const f = await page.evaluate((id) => window.GoshipAPI.admin.ficheSuivi(id), r.suivis[0].id);
  verifier('la fiche d\'un suivi', cles(f), CLES.fiche);

  console.log('\n8. Les rôles');
  for (const [nom, email] of [['gérant', 'gerant@goship.demo'], ['employé', 'employe@goship.demo']]) {
    await connecter(page, email);
    verifier(`${nom} : l'onglet est dans le menu`, await page.isVisible('[data-onglet-vue="suivi"]'), true);
    await ouvrirOnglet(page);
    e = await lire(page);
    verifier(`${nom} : il lit la santé et les cas, sans les commandes`, [e.chiffres.length > 5, e.raisons.length, e.actions], [true, 2, false]);
    verifier(`${nom} : la base refuse de toute façon le pilotage`, await page.evaluate(() =>
      window.GoshipAPI.admin.piloterSuivi('17track', 'arreter', 'motif valable').then(() => 'accepté', (x) => x.code)), 'non-autorise');
  }
  await page.evaluate(() => window.GoshipAPI.deconnecter().then(() => window.GoshipAPI.connecter('marie-ange@exemple.com', 'demo1234')));
  verifier('cliente : la supervision lui est refusée', await page.evaluate(() =>
    window.GoshipAPI.admin.supervisionSuivi({}, 1).then(() => 'acceptée', (x) => x.code)), 'non-autorise');

  console.log('\n9. Langues, apparence sombre, téléphone');
  await connecter(page, 'admin@goship.demo');
  await ouvrirOnglet(page);
  for (const [langue, onglet, titre] of [['en', 'Carrier tracking', 'Tracking health'], ['es', 'Seguimiento de transportistas', 'Estado del seguimiento'],
                                          ['ht', 'Swivi transpòtè', 'Sante swivi a']]) {
    await page.selectOption('[data-langue-tableau]', langue);
    await page.waitForTimeout(300);
    verifier(`${langue} : l'onglet et la santé sont traduits`, await page.evaluate(() => [
      document.querySelector('[data-onglet-vue="suivi"] .gs-td__libelle').textContent.trim(),
      document.querySelector('#sv-sante-titre').textContent.trim()]), [onglet, titre]);
  }
  await page.selectOption('[data-langue-tableau]', 'fr');
  await page.evaluate(() => document.documentElement.setAttribute('data-apparence', 'sombre'));
  verifier('sombre : les cartes du suivi ne restent pas blanches', await page.$eval('.gs-sv__sante',
    (n) => getComputedStyle(n).backgroundColor), 'rgb(14, 24, 48)');
  await capture(page, 'suivi-sombre', true);
  await page.evaluate(() => document.documentElement.removeAttribute('data-apparence'));

  const tel = await contexte(navigateur, 390, 844);
  const p2 = await tel.newPage();
  surveiller(p2);
  await connecter(p2, 'admin@goship.demo');
  await p2.evaluate(() => window.GoshipAPI.admin.exemples());
  await p2.evaluate(() => { const b = document.querySelector('[data-onglet-vue="suivi"]'); b.click(); });
  await p2.waitForSelector('[data-vue="suivi"]:not([hidden])');
  await attendre(p2);
  verifier('téléphone : aucun défilement horizontal de la page', await p2.evaluate(() =>
    document.documentElement.scrollWidth <= window.innerWidth + 1), true);
  await capture(p2, 'suivi-telephone', true);
  await tel.close();

  verifier('aucun appel à Supabase', appelsSupabase, 0);
  verifier('aucune erreur JavaScript', erreursJs, []);
} finally {
  await navigateur.close();
}
console.log(`\n${resultats.length} vérifications, ${resultats.filter(Boolean).length} réussies.`);
process.exit(resultats.every(Boolean) ? 0 : 1);
