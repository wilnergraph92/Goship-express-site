import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const racine = new URL('../../', import.meta.url);
const lire = async (chemin) => readFile(new URL(chemin, racine), 'utf8');
const [js, html, css, api, sql, tableau, enJson, esJson, htJson] = await Promise.all([
  lire('assets/js/communications-campagnes.js'), lire('outils/generateur/pages/admin.html'),
  lire('assets/css/site.css'), lire('assets/js/api.js'),
  lire('outils/migrations-candidates/008-communication-campagnes-marketing.sql'),
  lire('outils/traductions/tableau.txt'), lire('outils/traductions/en.json'),
  lire('outils/traductions/es.json'), lire('outils/traductions/ht.json')
]);
const contexte = { window: {}, document: { querySelector: () => null } };
vm.runInNewContext(js, contexte, { filename: 'assets/js/communications-campagnes.js' });
const campagnes = contexte.window.GoshipCampagnes;

test('la segmentation reste bornée aux critères métier autorisés', () => {
  assert.deepEqual(JSON.parse(JSON.stringify(campagnes.criteresDepuisValeurs({
    mode: 'or', pays: 'DO', langue_client: 'es', inscription_jours: '30',
    inscription_operateur: 'au_moins', a_des_colis: 'true', a_des_prealertes: '', activite_jours: '7'
  }))), {
    mode: 'or', regles: [
      { champ: 'pays', operateur: 'est', valeur: 'DO' },
      { champ: 'langue', operateur: 'est', valeur: 'es' },
      { champ: 'inscrit_depuis_jours', operateur: 'au_moins', valeur: 30 },
      { champ: 'a_des_colis', operateur: 'est', valeur: true },
      { champ: 'activite_colis_jours', operateur: 'dans_les_jours', valeur: 7 }
    ]
  });
  assert.equal(campagnes.criteresDepuisValeurs({ pays: 'US; drop table clients', langue_client: '' }), null);
  assert.equal(campagnes.criteresDepuisValeurs({ inscription_jours: '-1' }), null);
  assert.equal(campagnes.criteresDepuisValeurs({ a_des_colis: 'yes' }), null);
  assert.equal(campagnes.criteresDepuisValeurs({}), null);
});

test('les états de campagne sont rendus explicitement et sans état d’envoi', () => {
  assert.equal(campagnes.statut('scheduled'), 'Planifiée — sans envoi');
  assert.equal(campagnes.statut('pending_approval'), 'En attente d’approbation');
  assert.equal(campagnes.coutReelDisponible(), false);
  assert.equal(campagnes.transmissionActive(), false);
});

test('l’aperçu choisit le modèle et la langue sélectionnés sans interpréter le HTML', () => {
  const disponibles = {
    email: [{ id: 7, traductions: {
      fr: { titre: 'Titre FR', message: 'Message FR' },
      en: { titre: 'Title EN', message: 'Message EN' },
      es: { titre: 'Título ES', message: 'Mensaje ES' },
      ht: { titre: 'Tit HT', message: 'Mesaj HT' }
    } }]
  };
  assert.deepEqual(JSON.parse(JSON.stringify(campagnes.apercuMessageDepuisModeles(
    ['email'], disponibles, { email: '7' }, 'es'))),
  [{ canal: 'email', titre: 'Título ES', message: 'Mensaje ES' }]);
  assert.deepEqual(JSON.parse(JSON.stringify(campagnes.apercuMessageDepuisModeles(
    ['email'], disponibles, { email: '7' }, 'xx'))), []);
  const rendu = js.slice(js.indexOf('function afficherApercuModele()'), js.indexOf('function chargerCampagne'));
  assert.match(rendu, /creer\('strong'/);
  assert.match(rendu, /creer\('p'/);
  assert.doesNotMatch(rendu, /innerHTML/);
});

test('le Dashboard fournit la gestion, les quatre langues et les limites sans défaut', async () => {
  for (const chemin of ['admin.html', 'outils/generateur/pages/admin.html']) {
    const source = chemin === 'admin.html' ? await lire(chemin) : html;
    const zone = source.slice(source.indexOf('data-cc-pane="campaigns"'));
    assert.ok(zone.includes('name="nom"'));
    assert.ok(zone.includes('data-cm-save-segment'));
    assert.ok(zone.includes('data-cm-preview'));
    assert.ok(zone.includes('data-cm-approve'));
    assert.ok(zone.includes('data-cm-schedule'));
    assert.ok(zone.includes('data-cm-journal'));
    assert.ok(zone.includes('value="email"') && zone.includes('value="whatsapp"') && zone.includes('value="push"'));
    for (const langue of ['fr', 'en', 'es', 'ht']) assert.ok(zone.includes(`data-cm-locale="${langue}"`));
    // Depuis la candidate 012, la campagne approuvée et planifiée part, sous l'arrêt d'urgence.
    assert.match(zone, /part à son heure, sous l’arrêt d’urgence/i);
  }
  assert.match(css, /\.gs-campagnes__grille/);
  assert.match(css, /\.gs-campagnes__apercu/);
  assert.match(js, /alertes_limites/);
});

test('l’API C6 passe uniquement par les RPC marketing contrôlés et refuse le faux mode démo', () => {
  for (const methode of ['communicationCampagnes', 'communicationCampagneSegments',
    'communicationCampagneEnregistrer', 'communicationCampagneApercu',
    'communicationCampagneSoumettre', 'communicationCampagneApprouver',
    'communicationCampagnePlanifier', 'communicationCampagneJournal']) {
    assert.match(api, new RegExp(`${methode}: function`));
  }
  assert.match(api, /communicationCampagnes: function \(\) \{ return communicationDemoNonDisponible\('communications\.campaigns\.view'\); \}/);
  assert.doesNotMatch(js, /\bfetch\s*\(|XMLHttpRequest|api\.(?:brevo|resend|meta|expo)\b/i);
  assert.doesNotMatch(sql, /net\.http_post|communication_campagne_(?:envoyer|expedier)|worker_marketing/i);
  assert.match(sql, /'transmission_active', false/);
});

test('les contrôles serveur imposent consentement, STOP, rôles, audience et limites avant planification', () => {
  assert.match(sql, /communication_campagne_calculer_audience/);
  assert.match(sql, /communication_contact_suppressions/);
  assert.match(sql, /contact_partage_ambigu/);
  assert.match(sql, /consentement_non_verifiable/);
  assert.match(sql, /exiger_permission\('communications\.campaigns\.approve'\)/);
  assert.match(sql, /COMMUNICATION_CAMPAIGN_LIMITS_REQUIRED/);
  assert.match(sql, /COMMUNICATION_CAMPAIGN_AUDIENCE_CHANGED/);
  assert.match(sql, /COMMUNICATION_CAMPAIGN_LIMIT_EXCEEDED/);
  assert.match(sql, /communication_campagne_revisions_immuables/);
  assert.match(sql, /communication_campagne_approbations_immuables/);
  assert.match(sql, /communication_campagne_audit_immuable/);
  assert.doesNotMatch(sql, /supprime_le/);
});

test('les principales chaînes visibles C6 ont les traductions FR, EN, ES et HT', () => {
  const dictionnaires = [JSON.parse(enJson), JSON.parse(esJson), JSON.parse(htJson)];
  const obligatoires = [
    'Campagnes marketing', 'Créer une campagne', 'Nom de la campagne', 'Objectif',
    'Segment dynamique', 'Enregistrer le segment', 'Budget et quotas — aucun défaut n’est appliqué',
    'Planification à préparer', 'Fuseau IANA explicite', 'Prévisualiser l’audience',
    'Créer une version de modèle marketing', 'Approbation, planification et audit',
    'Soumettre pour approbation', 'Approuver', 'Enregistrer la planification',
    'Annuler la campagne', 'Une campagne approuvée et planifiée part à son heure, sous l’arrêt d’urgence.',
    'Seuls les clients qui ont accepté les offres sur le canal la reçoivent. Les budgets, quotas et coûts ne sont jamais estimés automatiquement.',
    'Prévisualisation agrégée — aucun contact n’est affiché',
    'Clients correspondant au segment : ', 'Limites configurées.',
    'Budget et quotas : non configurés. Aucune transmission ne peut être préparée.',
    'Coût réel : non disponible.',
    'Alertes de limites', 'Quota dépassé',
    'Coût estimé supérieur au budget prévu.',
    'Coût estimé supérieur au plafond de dépenses.'
  ];
  for (const cle of obligatoires) {
    assert.ok(tableau.split(/\r?\n/).includes(cle), `tableau.txt: ${cle}`);
    for (const dictionnaire of dictionnaires) assert.ok(dictionnaire[cle], `traduction: ${cle}`);
  }
});
