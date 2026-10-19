/* ==========================================================================
   Goship Express — les programmes (GOPOINTS, anniversaires, Welcome, Refer),
   mode démonstration, hors navigateur
   ==========================================================================
   Rejoue sur la copie démo (assets/js/api.js) les cas de essai-programmes.py
   (outils/supabase-fidelite.sql, -anniversaires.sql, -campagnes.sql) : mêmes
   refus, mêmes codes d'erreur, mêmes chiffres. La démonstration ne doit pas
   promettre ce que la base refuse. Les montants et les points de cet essai
   sont des valeurs d'essai : aucune n'est celle de GoShip.

     node outils/essais-services/essai-programmes.js
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
new Function(fs.readFileSync(path.join(__dirname, '..', '..', 'assets', 'js', 'api.js'), 'utf8'))();
var API = global.window.GoshipAPI;
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
var REFUS = 'non-autorise';
var EQUIPE = { admin: 'admin@goship.demo', gerant: 'gerant@goship.demo', employe: 'employe@goship.demo' };
function comme(role) {
  return API.deconnecter().then(function () { return API.connecter(EQUIPE[role], 'demo1234'); });
}

function aujourdhui(decalage) {
  var t = new Date(Date.now() + (decalage || 0) * 864e5);
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Santo_Domingo', year: 'numeric', month: '2-digit', day: '2-digit' }).format(t);
}

var compteur = 0;
// Un client qui s'inscrit par e-mail (la session devient la sienne)
async function inscrire(nom, options) {
  compteur += 1;
  options = options || {};
  var r = await API.inscrire({ email: 'prog' + compteur + '@exemple.com', motDePasse: 'secret12', nom_complet: nom,
    pays: 'HT', region: 'Ouest', ville: 'Port-au-Prince', adresse: options.adresse || ('Rue ' + compteur + ' numéro ' + compteur * 7),
    telephone: options.telephone || ('+509 3700 ' + (1000 + compteur)), date_naissance: options.naissance || '1990-05-17',
    code_parrainage: options.code });
  return r.profil;
}

(async function () {
  var A = API.admin, P = A.programmes;
  await comme('admin');
  await A.exemples();
  var clientsDemo = (await A.clients({ parPage: 50 })).lignes;
  var marie = clientsDemo.filter(function (c) { return c.email === 'marie-ange@exemple.com'; })[0].id;
  async function colis(clientId) {
    return A.creerColis({ client_id: clientId, description: 'Colis', poids_lb: 4, service: 'aerien', pays_destination: 'HT', destination: 'Jacmel' });
  }
  async function pts() { await API.deconnecter(); }

  console.log('A. GOPOINTS : programme éteint, règles, registre');
  var base = await P.pointsRegles();
  verifier('le programme naît éteint, six règles toutes éteintes à 0 point',
           [base.reglages.actif, base.regles.length, base.regles.every(function (r) { return !r.actif && r.points === 0; }), base.offres.length],
           [false, 6, true, 0]);
  verifier('une règle allumée sans point : refusée', await code(P.pointsRegle('account_created', { actif: true })), 'INVALID_RULE');
  verifier('première opération allumée sans opération qualifiante : refusée',
           await code(P.pointsRegle('first_operation', { actif: true, points: 10 })), 'INVALID_RULE');
  verifier('opération inconnue : refusée', await code(P.pointsRegle('first_operation', { points: 10, operation: 'autre' })), 'INVALID_RULE');
  verifier('événement inconnu : refusé', await code(P.pointsRegle('inconnu', { points: 10 })), 'INVALID_RULE');
  verifier('points non entiers : refusés', await code(P.pointsRegle('account_created', { points: 'abc' })), 'INVALID_PROGRAM_VALUE');
  var avant = await inscrire('Éva Sans Points');
  verifier('programme éteint : aucun point, portefeuille vide et sans offre',
           await API.portefeuille().then(function (w) { return [w.actif, w.solde, w.total, w.offres.length]; }), [false, 0, 0, 0]);
  await pts(); await comme('admin');

  await P.pointsRegle('account_created', { points: 50, actif: true });
  await P.pointsRegle('first_operation', { points: 100, actif: true, operation: 'colis_recu' });
  await P.pointsRegle('repeat_operation', { points: 20, actif: true, operation: 'colis_recu', limite_jour: 1 });
  verifier('allumer la règle sans allumer le programme : aucun point',
           await (async function () { var c = await inscrire('Léo Programme Éteint'); var w = await API.portefeuille(); await pts(); await comme('admin'); return w.solde; })(), 0);
  await P.pointsReglages({ actif: true, expiration_jours: 365, conditions: 'Conditions d\'essai.' });
  var cl1 = await inscrire('Nadia Points');
  var w1 = await API.portefeuille();
  verifier('compte créé, programme allumé : les points de la règle, une fois', [w1.solde, w1.total, w1.elements[0].type, w1.elements[0].source], [50, 1, 'gain', 'account_created']);
  verifier('le gain expire dans 365 jours', w1.elements[0].expire_le, aujourdhui(365));
  await pts(); await comme('admin');
  await colis(cl1.id);
  await pts(); await API.connecter('prog' + compteur + '@exemple.com', 'secret12');
  verifier('premier colis reçu : 100 points de plus', (await API.portefeuille()).solde, 150);
  await pts(); await comme('admin');
  await colis(cl1.id); await colis(cl1.id);
  await pts(); await API.connecter('prog' + compteur + '@exemple.com', 'secret12');
  verifier('opérations répétées : 20 points, limite d\'un par jour', (await API.portefeuille()).solde, 170);
  var sans = await API.portefeuille();
  verifier('le registre garde chaque mouvement', sans.total, 3);

  await comme('admin');
  var offre = await P.pointsOffre(null, { nom: 'Crédit d\'essai', cout_points: 100, type: 'credit_expedition', valeur: 5, actif: true, stock: 1, limite_client: 1 });
  verifier('une offre incomplète : refusée', await code(P.pointsOffre(null, { nom: 'X' })), 'INVALID_OFFER');
  verifier('un type de points comme offre : refusé', await code(P.pointsOffre(null, { nom: 'Offre de points', cout_points: 5, type: 'gopoints', valeur: 5 })), 'INVALID_OFFER');
  verifier('une offre allumée est visible, avec ses conditions',
           await (async function () { await pts(); await API.connecter('prog' + compteur + '@exemple.com', 'secret12'); var w = await API.portefeuille(); return [w.offres.length, w.offres[0].cout_points]; })(), [1, 100]);
  var cle = 'a0a0a0a0-0000-4000-8000-000000000001';
  var u = await API.utiliserPoints(offre.id, cle);
  verifier('échange : 100 points, un avantage obtenu', [u.deja, u.points, u.type, u.valeur, u.solde], [false, 100, 'credit_expedition', 5, 70]);
  var rejoue = await API.utiliserPoints(offre.id, cle);
  verifier('la même requête rejouée : rien de plus', [rejoue.deja, (await API.portefeuille()).solde], [true, 70]);
  verifier('stock épuisé : refusé', await code(API.utiliserPoints(offre.id, 'a0a0a0a0-0000-4000-8000-000000000002')), 'OFFER_OUT_OF_STOCK');
  verifier('mes avantages : un crédit obtenu', (await API.mesAvantages()).map(function (r) { return [r.programme, r.type, r.statut]; }), [['points', 'credit_expedition', 'obtenue']]);
  verifier('une offre qui n\'existe pas : refusée', await code(API.utiliserPoints('inconnue', 'a0a0a0a0-0000-4000-8000-000000000003')), 'OFFER_UNAVAILABLE');
  await comme('admin');
  var grosse = await P.pointsOffre(null, { nom: 'Grosse offre', cout_points: 500, type: 'bonus_fixe', valeur: 10, actif: true });
  await pts(); await API.connecter('prog' + compteur + '@exemple.com', 'secret12');
  verifier('solde insuffisant : refusé, le solde ne bouge pas',
           [await code(API.utiliserPoints(grosse.id, 'a0a0a0a0-0000-4000-8000-000000000004')), (await API.portefeuille()).solde], ['INSUFFICIENT_POINTS', 70]);

  await comme('admin');
  verifier('corriger sans motif : refusé', await code(P.pointsCorriger(cl1.id, -10, '')), 'REASON_REQUIRED');
  verifier('retirer plus que le solde : refusé (jamais négatif)', await code(P.pointsCorriger(cl1.id, -1000, 'Erreur de saisie')), 'INSUFFICIENT_POINTS');
  verifier('correction de 30 points avec motif', (await P.pointsCorriger(cl1.id, 30, 'Geste commercial d\'essai')).solde, 100);
  var liste = await P.pointsMouvements({ recherche: 'Nadia' });
  var gain = liste.elements.filter(function (m) { return m.source === 'first_operation'; })[0];
  verifier('annuler un gain : le mouvement inverse, une seule fois',
           [(await P.pointsAnnuler(gain.id, 'Opération annulée')).solde, await code(P.pointsAnnuler(gain.id, 'Encore'))], [0, 'MOVEMENT_ALREADY_CANCELLED']);
  verifier('un solde ne passe pas sous zéro par une annulation', await code(P.pointsAnnuler(liste.elements.filter(function (m) { return m.type === 'gain' && m.source === 'account_created'; })[0].id, 'Test')), 'INSUFFICIENT_POINTS');
  var ap = await P.pointsApercu();
  verifier('l\'aperçu : le programme est allumé, des gains comptés', [ap.actif, ap.gagnes > 0, ap.utilises], [true, true, 100]);

  console.log('\nB. Anniversaires : règles, réglages, modèles');
  var reg = await P.anniversaireReglages();
  verifier('le programme naît éteint, WhatsApp indisponible, aucun canal déclaré configuré',
           [reg.reglages.actif, reg.reglages.fuseau, reg.reglages.rappel_admin_jours, reg.reglages.rappel_client_actif, reg.whatsapp_disponible, reg.canaux_configures],
           [false, 'America/Santo_Domingo', 7, false, false, { push: false, email: false, whatsapp: false }]);
  verifier('heure invalide : refusée', await code(P.anniversaireReglagesModifier({ heure_envoi: '25:00' })), 'INVALID_PROGRAM_VALUE');
  verifier('WhatsApp refusé comme canal', await code(P.anniversaireReglagesModifier({ canaux: ['push', 'whatsapp'] })), 'INVALID_PROGRAM_VALUE');
  verifier('règle du 29 février inconnue : refusée', await code(P.anniversaireReglagesModifier({ regle_29_fevrier: 'jamais' })), 'INVALID_PROGRAM_VALUE');
  verifier('fuseau inexistant : refusé', await code(P.anniversaireReglagesModifier({ fuseau: 'Mars/Olympus' })), 'INVALID_PROGRAM_VALUE');
  verifier('avantage activé sans type : refusé', await code(P.anniversaireReglagesModifier({ avantage_actif: true })), 'BENEFIT_INCOMPLETE');
  verifier('avantage en euros sans texte : refusé', await code(P.anniversaireReglagesModifier({ avantage_actif: true, avantage_type: 'bonus_fixe', avantage_valeur: 5 })), 'BENEFIT_INCOMPLETE');
  verifier('avantage en GOPOINTS sans règle « anniversaire » : refusé', await code(P.anniversaireReglagesModifier({ avantage_actif: true, avantage_type: 'gopoints' })), 'BENEFIT_INCOMPLETE');
  var m = await P.anniversaireModeles();
  var ht = m.filter(function (x) { return x.type === 'birthday' && x.langue === 'ht'; })[0];
  verifier('seize modèles, le créole commence par « 🎉🎂 Bòn fèt »', [m.length, ht.titre.indexOf('Bòn fèt') >= 0, ht.message.indexOf('ekip GoShip Express') >= 0, ht.modifie], [16, true, true, false]);
  verifier('le modèle sans avantage ne promet aucun cadeau',
           m.filter(function (x) { return x.type === 'birthday'; }).every(function (x) { return !/\{\{avantage\}\}/.test(x.message); }), true);
  verifier('variable non permise : refusée', await code(P.anniversaireModele('birthday', 'fr', 'Titre', 'Bonjour {{nom}}')), 'INVALID_TEMPLATE');
  verifier('accolades isolées : refusées', await code(P.anniversaireModele('birthday', 'fr', 'Titre', 'Bonjour { toi')), 'INVALID_TEMPLATE');
  var modif = await P.anniversaireModele('birthday', 'fr', 'Joyeux anniversaire {{prenom}}', 'Message d\'essai pour {{prenom}}.');
  verifier('un modèle modifié se marque, et se restaure', [modif.modifie, (await P.anniversaireModeleRestaurer('birthday', 'fr')).modifie], [true, false]);

  var ne = await inscrire('Bébé Aujourd\'hui', { naissance: aujourdhui(0).replace(/^\d{4}/, '2000') });
  await pts(); await comme('admin');
  await P.anniversaireReglagesModifier({ actif: true, canaux: ['push'] });
  var jour = await P.anniversaires({ debut: aujourdhui(0) });
  var bebe = jour.elements.filter(function (e) { return e.client_id === ne.id; })[0];
  verifier('l\'anniversaire du jour est listé, préparé une fois, jamais « envoyé » (aucun canal réel en démonstration)',
           [jour.total >= 1, bebe.age, bebe.statut, bebe.envois.map(function (e) { return e.statut; })], [true, new Date().getFullYear() - 2000, 'prepare', ['attente']]);
  var jour2 = await P.anniversaires({ debut: aujourdhui(0) });
  verifier('relancé : toujours un seul message pour ce client cette année', (await P.anniversairesMessages({})).elements.filter(function (e) { return e.client_id === ne.id; }).length, 1);
  verifier('filtre de statut inconnu : refusé', await code(P.anniversairesMessages({ statut: 'envoye' })), 'INVALID_FILTER');
  verifier('période de plus d\'un an : refusée', await code(P.anniversaires({ debut: '2026-01-01', fin: '2028-01-01' })), 'INVALID_PERIOD');
  await pts(); await API.connecter('prog' + compteur + '@exemple.com', 'secret12');
  await API.reglerAnniversaire(false);
  verifier('le client peut couper son message d\'anniversaire', await API.preferencesProgrammes(), { anniversaire: false });
  var bissextile = await inscrire('Née Un Vingt-Neuf', { naissance: '2000-02-29' });
  await pts(); await comme('admin');
  var le = async function (jour) {
    return (await P.anniversaires({ debut: jour })).elements.filter(function (e) { return e.client_id === bissextile.id; }).length;
  };
  verifier('29 février, année non bissextile : le 28 février par défaut', [await le('2027-02-28'), await le('2027-03-01'), await le('2028-02-29')], [1, 0, 1]);
  await P.anniversaireReglagesModifier({ regle_29_fevrier: 'mars1' });
  verifier('… ou le 1er mars si l\'équipe le choisit (et toujours le 29 en année bissextile)', [await le('2027-02-28'), await le('2027-03-01'), await le('2028-02-29')], [0, 1, 1]);
  await P.anniversaireReglagesModifier({ regle_29_fevrier: 'fev28' });

  console.log('\nC. GOship APP Welcome');
  await comme('admin');
  var camp = await P.bienvenueEnregistrer(null, { nom: 'Bienvenue d\'essai' });
  verifier('un brouillon peut être incomplet', [camp.statut, camp.nom], ['brouillon', 'Bienvenue d\'essai']);
  verifier('la publier incomplète : refusé, avec ce qui manque', await P.bienvenuePublier(camp.id).then(function () { return 'ok'; }, function (e) { return [e.code, /date de début/.test(e.detail), /conditions générales/.test(e.detail)]; }), ['INCOMPLETE_CAMPAIGN', true, true]);
  var complet = { nom: 'Bienvenue d\'essai', description: 'Un bonus pour la première opération.', debut: aujourdhui(0), fin: aujourdhui(30),
                  type_recompense: 'bonus_fixe', valeur_recompense: 7, operation: 'colis_recu', budget_max: 2, delai_validation_jours: 0,
                  cumul_parrainage: true, conditions: 'Un bonus par client, première opération uniquement.' };
  verifier('un type inconnu : refusé', await code(P.bienvenueEnregistrer(camp.id, { type_recompense: 'diamant' })), 'INVALID_CAMPAIGN');
  verifier('dates inversées : refusées', await code(P.bienvenueEnregistrer(camp.id, { debut: aujourdhui(10), fin: aujourdhui(1) })), 'INVALID_CAMPAIGN');
  await P.bienvenueEnregistrer(camp.id, complet);
  var pub = await P.bienvenuePublier(camp.id);
  verifier('complète, elle devient active', pub.statut, 'active');
  verifier('une campagne active ne se modifie pas', await code(P.bienvenueEnregistrer(camp.id, { nom: 'Autre' })), 'CAMPAIGN_LOCKED');
  verifier('suspendre puis reprendre', [(await P.bienvenueStatut(camp.id, 'suspendre')).statut, (await P.bienvenueStatut(camp.id, 'reprendre')).statut], ['suspendue', 'active']);
  verifier('terminer une campagne active : ok, la rouvrir : refusé',
           [(await P.bienvenueStatut(camp.id, 'terminer')).statut, await code(P.bienvenueStatut(camp.id, 'suspendre'))], ['terminee', 'INVALID_CAMPAIGN_STATUS']);
  var camp2 = await P.bienvenueEnregistrer(null, complet);
  await P.bienvenuePublier(camp2.id);
  var nouveau = await inscrire('Client Welcome');
  var bien = await API.maBienvenue();
  verifier('le client voit l\'offre à débloquer, avec sa phrase', [bien.statut, bien.avantage, bien.etapes.map(function (e) { return e.fait; })], ['a_debloquer', 'un bonus de 7,00 $', [true, false]]);
  await pts(); await comme('admin');
  await colis(nouveau.id);
  await colis(nouveau.id);
  await pts(); await API.connecter('prog' + compteur + '@exemple.com', 'secret12');
  verifier('première opération : bonus obtenu, une seule fois', [(await API.maBienvenue()).statut, (await API.mesAvantages()).filter(function (r) { return r.programme === 'welcome'; }).length], ['obtenu', 1]);
  await comme('admin');
  verifier('l\'équipe voit la campagne et ses avantages',
           (await P.bienvenueListe()).campagnes.filter(function (c) { return c.id === camp2.id; }).map(function (c) { return [c.statut, c.recompenses.obtenue, c.manques.length]; }), [['active', 1, 0]]);

  console.log('\nD. GOship Refer');
  var conf = await P.parrainageConfig();
  verifier('le parrainage naît en brouillon, incomplet', [conf.statut, conf.manques.length > 0], ['brouillon', true]);
  verifier('le publier incomplet : refusé', await code(P.parrainageStatut('publier')), 'INCOMPLETE_CAMPAIGN');
  await P.pointsReglages({ actif: true });
  await P.parrainageConfigModifier({ debut: aujourdhui(0), fin: aujourdhui(60), parrain_type: 'bonus_fixe', parrain_valeur: 10,
    filleul_type: 'credit_expedition', filleul_valeur: 5, operation: 'colis_recu', max_par_parrain: 2, cumul_bienvenue: true,
    conditions: 'Conditions de parrainage d\'essai.', annulation: 'Un avantage est annulé si l\'opération est annulée.' });
  verifier('publié, il est actif', (await P.parrainageStatut('publier')).statut, 'active');
  verifier('actif, il ne se modifie plus', await code(P.parrainageConfigModifier({ max_par_parrain: 5 })), 'CAMPAIGN_LOCKED');

  var parrain = await inscrire('Pascal Parrain');
  var infoP = await API.monParrainage();
  verifier('le code : 8 signes sans ambiguïté, un lien d\'inscription, un avantage décrit pour chaque côté',
           [/^GS[A-HJKMNP-Z2-9]{6}$/.test(infoP.code), /inscription\.html\?parrain=GS/.test(infoP.lien), infoP.actif, infoP.avantage_parrain, infoP.avantage_filleul],
           [true, true, true, 'un bonus de 10,00 $', '5,00 $ de crédit d\'expédition']);
  verifier('le code est stable d\'un appel à l\'autre', (await API.monParrainage()).code, infoP.code);
  verifier('son propre code : refusé', await code(API.utiliserCodeParrainage(infoP.code)), 'SELF_REFERRAL');
  verifier('un code inconnu : refusé', await code(API.utiliserCodeParrainage('GSZZZZZZ')), 'INVALID_REFERRAL_CODE');
  verifier('une invitation partagée est comptée', await API.noterInvitation('whatsapp'), 1);
  var parrainEmail = 'prog' + compteur + '@exemple.com';
  await pts();
  var f1 = await inscrire('Fanny Filleule', { code: infoP.code });
  verifier('inscrit avec le code : rattaché', (await API.monParrainage()).mon_parrain, true);
  verifier('déjà parrainé : un second code est refusé', await code(API.utiliserCodeParrainage(infoP.code)), 'ALREADY_REFERRED');
  await pts(); await comme('admin');
  await colis(f1.id);
  await pts(); await API.connecter(parrainEmail, 'secret12');
  var vue = await API.monParrainage();
  verifier('première opération du filleul : le parrain voit ses chiffres et son avantage',
           [vue.inscrits, vue.valides, vue.recompenses.map(function (r) { return [r.type, r.statut]; })], [1, 1, [['bonus_fixe', 'obtenue']]]);
  verifier('… sans jamais l\'identité du filleul', ['Fanny', 'Filleule', f1.id].some(function (t) { return JSON.stringify(vue).indexOf(t) >= 0; }), false);
  await comme('admin');
  var plist = await P.parrainages({ statut: 'recompense' });
  verifier('l\'équipe voit le parrainage avec les deux comptes', [plist.total, plist.elements[0].filleul_nom, plist.elements[0].parrain_nom], [1, 'Fanny Filleule', 'Pascal Parrain']);
  verifier('les avantages des deux côtés', (await P.recompenses({ programme: 'refer_filleul' })).total + (await P.recompenses({ programme: 'refer_parrain' })).total, 2);

  // Les indices d'abus : un même téléphone, jamais bloqué, mais « suspect »
  await API.deconnecter();
  var tel = (await (async function () { await API.connecter(parrainEmail, 'secret12'); var p = await API.profil(); await API.deconnecter(); return p.telephone; })());
  var f2 = await inscrire('Faux Filleul', { code: infoP.code, telephone: tel });
  await pts(); await comme('admin');
  var susp = await P.parrainages({ statut: 'suspect' });
  verifier('même téléphone que le parrain : « suspect », rien n\'est bloqué', [susp.total, susp.elements[0].motif], [1, 'MEME_TELEPHONE']);
  await colis(f2.id);
  verifier('suspect : sa première opération ne rapporte rien', (await P.recompenses({ programme: 'refer_filleul' })).total, 1);
  verifier('examiner sans motif : refusé', await code(P.parrainageExaminer(susp.elements[0].id, 'valider', '')), 'REASON_REQUIRED');
  verifier('décision inconnue : refusée', await code(P.parrainageExaminer(susp.elements[0].id, 'peut-etre', 'motif')), 'INVALID_DECISION');
  verifier('un parrainage non suspect ne s\'examine pas', await code(P.parrainageExaminer(plist.elements[0].id, 'valider', 'motif')), 'INVALID_REFERRAL');
  var ex = await P.parrainageExaminer(susp.elements[0].id, 'valider', 'Même foyer, deux personnes vérifiées');
  verifier('validé après examen : le parrainage reprend, avantages accordés', [ex.statut, (await P.recompenses({ programme: 'refer_filleul' })).total], ['recompense', 2]);
  var f3 = await (async function () { await API.deconnecter(); return inscrire('Troisième Filleul', { code: infoP.code }); })();
  await pts(); await comme('admin');
  await colis(f3.id);
  verifier('le plafond de 2 parrainages récompensés par parrain : le troisième est refusé, sans avantage',
           [(await P.parrainages({ statut: 'refuse' })).elements.map(function (e) { return e.motif; }), (await P.recompenses({ programme: 'refer_filleul' })).total], [['PLAFOND_PARRAIN'], 2]);
  var apc = await P.parrainageApercu();
  verifier('l\'aperçu compte les parrains, inscrits, qualifiés et suspects', [apc.parrains, apc.filleuls_inscrits, apc.transactions_qualifiantes, apc.suspects], [1, 3, 2, 0]);
  verifier('filtre inconnu : refusé', await code(P.parrainages({ statut: 'bizarre' })), 'INVALID_FILTER');

  console.log('\nE. Avantages donnés ou annulés à la main');
  verifier('accorder sans motif : refusé', await code(P.recompenseAccorder(marie, 'bonus_fixe', 3, '')), 'REASON_REQUIRED');
  verifier('type ou valeur invalide : refusé', await code(P.recompenseAccorder(marie, 'bonus_fixe', -1, 'Motif valable')), 'INVALID_REWARD');
  var ra = await P.recompenseAccorder(marie, 'bonus_fixe', 3, 'Geste d\'essai');
  verifier('accordé avec motif : obtenu', ra.statut, 'obtenue');
  verifier('l\'annuler sans motif : refusé, avec motif : annulé, deux fois : refusé',
           [await code(P.recompenseAnnuler(ra.id, '')), (await P.recompenseAnnuler(ra.id, 'Erreur')).statut, await code(P.recompenseAnnuler(ra.id, 'Encore'))],
           ['REASON_REQUIRED', 'annulee', 'INVALID_REWARD']);
  verifier('le journal garde la trace (action et motif)', (await A.journal({ parPage: 200 })).lignes.some(function (j) { return j.action === 'recompense.annulee'; }), true);
  verifier('aucune erreur de programme dans cet essai', (await P.erreurs()).total, 0);

  console.log('\nF. Chaque rôle, chaque permission');
  var appels = {
    'birthdays.view': [function () { return P.anniversaires({}); }, function () { return P.anniversaireReglages(); }, function () { return P.anniversaireModeles(); }],
    'birthdays.manage': [function () { return P.anniversaireReglagesModifier({}); }, function () { return P.anniversaireModele('birthday', 'fr', 'T', 'M'); },
                         function () { return P.corrigerNaissance(marie, '1990-01-01', 'motif'); }],
    'programs.view': [function () { return P.pointsRegles(); }, function () { return P.bienvenueListe(); }, function () { return P.parrainageConfig(); },
                      function () { return P.parrainages({}); }, function () { return P.recompenses({}); }, function () { return P.erreurs(); }],
    'programs.manage': [function () { return P.pointsReglages({}); }, function () { return P.bienvenueEnregistrer(null, {}); },
                        function () { return P.parrainageConfigModifier({}); }, function () { return P.parrainageExaminer(0, 'valider', 'motif'); }],
    'points.adjust': [function () { return P.pointsCorriger(marie, 1, 'motif'); }, function () { return P.pointsAnnuler(0, 'motif'); },
                      function () { return P.recompenseAccorder(marie, 'bonus_fixe', 1, 'motif'); }]
  };
  var permis = { 'birthdays.view': ['admin', 'gerant'], 'birthdays.manage': ['admin'], 'programs.view': ['admin', 'gerant'],
                 'programs.manage': ['admin'], 'points.adjust': ['admin'] };
  for (var perm in appels) {
    for (var role of ['admin', 'gerant', 'employe']) {
      await comme(role);
      var refuses = 0;
      for (var f of appels[perm]) { if (await code(f()) === REFUS) refuses += 1; }
      var attendu = permis[perm].indexOf(role) >= 0 ? 'accepté partout' : 'refusé partout';
      verifier(perm + ' : ' + role, refuses === appels[perm].length ? 'refusé partout' : (refuses === 0 ? 'accepté partout' : 'mélangé'), attendu);
    }
  }
  await API.deconnecter();
  verifier('un visiteur ne lit rien', [await code(API.portefeuille()), await code(P.pointsRegles()), await code(API.monParrainage())], [REFUS, REFUS, REFUS]);
  await inscrire('Client Simple');
  verifier('un client n\'a aucune permission d\'équipe', [await code(P.pointsRegles()), await code(P.recompenses({})), await code(P.parrainages({}))], [REFUS, REFUS, REFUS]);

  var reussis = resultats.filter(Boolean).length;
  console.log('\n' + resultats.length + ' vérifications, ' + reussis + ' réussies.');
  process.exit(reussis === resultats.length ? 0 : 1);
})().catch(function (e) { console.error(e); process.exit(2); });
