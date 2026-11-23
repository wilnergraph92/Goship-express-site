import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const racine = new URL('../../', import.meta.url);
const lire = async (chemin) => readFile(new URL(chemin, racine), 'utf8');
const scriptInterface = await lire('assets/js/communications.js');
const contexte = { window: {} };
vm.runInNewContext(scriptInterface, contexte, { filename: 'assets/js/communications.js' });
const interfaceC5 = contexte.window.GoshipCommunications;

test('le modèle de santé garde les mesures absentes comme non mesurables', () => {
  const modele = interfaceC5.modeliserSante({
    mode: 'supabase',
    evenements: { recus_conserves: 8, a_traiter: 2, en_cours: 99, en_cours_mesurable: false },
    envois: { disponible: false, incertains: 40 },
    arret: { etat: 'arret_confirme' },
    travailleur: { tables_disponibles: false },
    alertes: [{ code: 'TRANSMISSIONS_INCERTAINES', compte: 1 }, { code: 'IGNORER', compte: 3 }]
  });
  assert.equal(modele.mesures.recus, 8);
  assert.equal(modele.mesures.attente, 2);
  assert.equal(modele.mesures.enCours, null);
  assert.equal(modele.mesures.envoisDisponibles, false);
  assert.equal(modele.mesures.incertains, null);
  assert.equal(modele.arret, 'confirme');
  assert.equal(modele.travailleur, 'indisponible');
  assert.deepEqual(JSON.parse(JSON.stringify(modele.alertes)), [
    { code: 'TRANSMISSIONS_INCERTAINES', compte: 1 }, { code: 'IGNORER', compte: 3 }
  ]);
  assert.match(scriptInterface, /if \(!libellesAlertes\[a\.code\]\) return/);
});

test('le mode démo ne déclare aucune donnée opérationnelle', () => {
  const modele = interfaceC5.modeliserSante({ mode: 'demo', evenements: { recus_conserves: 900 } });
  assert.equal(modele.modeDemo, true);
  assert.equal(modele.mesures.recus, 900);
});

test('le validateur de modèle exige quatre langues et les mêmes variables', () => {
  const traductions = [
    { langue: 'fr', titre: 'Colis {{numero}}', message: 'Arrivé' },
    { langue: 'en', titre: 'Package {{numero}}', message: 'Arrived' },
    { langue: 'es', titre: 'Paquete {{numero}}', message: 'Llegó' },
    { langue: 'ht', titre: 'Koli {{numero}}', message: 'Rive' }
  ];
  assert.equal(interfaceC5.validerModele('shipment_received', ['email'], ['numero'], traductions, ''), null);
  assert.equal(interfaceC5.validerModele('shipment_received', ['email'], [], traductions, ''),
    'COMMUNICATION_TEMPLATE_VARIABLES_MISMATCH');
  const languesManquantes = traductions.slice(0, 3);
  assert.equal(interfaceC5.validerModele('shipment_received', ['email'], ['numero'], languesManquantes, ''),
    'COMMUNICATION_TEMPLATE_LANGUAGES_REQUIRED');
  const variableInconnue = traductions.map((ligne) => ({ ...ligne }));
  variableInconnue[0].message = '{{telephone}}';
  assert.equal(interfaceC5.validerModele('shipment_received', ['email'], ['numero'], variableInconnue, ''),
    'COMMUNICATION_TEMPLATE_VARIABLE_INVALID');
  assert.equal(interfaceC5.validerModele('shipment_received', ['email', 'email'], ['numero'], traductions, ''),
    'COMMUNICATION_TEMPLATE_INPUT_INVALID');
  assert.equal(interfaceC5.validerModele('shipment_received', ['whatsapp'], ['numero'], traductions, ''),
    'COMMUNICATION_TEMPLATE_WHATSAPP_NAME_REQUIRED');
});

test('les filtres de recherche sont normalisés et bornés aux champs attendus', () => {
  const filtres = interfaceC5.normaliserFiltresHistorique({
    recherche: '  GSE-2048  ', canal: 'email', statut: 'incertain', type: 'shipment_received',
    debut: '2026-11-20T10:00', fin: 'valeur invalide'
  }, 3);
  const debutAttendu = new Date('2026-11-20T10:00').toISOString();
  assert.deepEqual(JSON.parse(JSON.stringify(filtres)), {
    recherche: 'GSE-2048', canal: 'email', statut: 'incertain', type: 'shipment_received',
    debut: debutAttendu, fin: null, page: 3, parPage: 50
  });
  assert.equal(interfaceC5.normaliserFiltresHistorique({}, -1).page, 0);
});

test('l’ancienneté de la file reste une durée relative et accepte une date absente', () => {
  const maintenant = Date.parse('2026-11-22T12:00:00Z');
  assert.match(interfaceC5.anciennete('2026-11-22T10:00:00Z', maintenant), /2/);
  assert.equal(interfaceC5.anciennete(null, maintenant), null);
});

test('les deux sources d’admin exposent les cinq vues opérationnelles C5', async () => {
  for (const chemin of ['admin.html', 'outils/generateur/pages/admin.html']) {
    const html = await lire(chemin);
    const panneau = html.slice(html.indexOf('data-vue="communications"'));
    assert.notEqual(panneau, html, `${chemin} contient le tableau de bord C5`);
    for (const vue of ['overview', 'history', 'templates', 'consents', 'queue']) {
      assert.match(panneau, new RegExp(`data-cc-tab="${vue}"`), `${chemin}: onglet ${vue}`);
      assert.match(panneau, new RegExp(`data-cc-pane="${vue}"`), `${chemin}: panneau ${vue}`);
    }
    for (const contrat of ['data-cc-history-form', 'data-cc-template-form', 'data-cc-consent-rows',
      'data-cc-event-rows', 'data-cc-outbox-rows', 'data-cc-refresh']) {
      assert.ok(panneau.includes(contrat), `${chemin}: ${contrat}`);
    }
  }
  const css = await lire('assets/css/site.css');
  assert.match(css, /@media\(max-width:760px\)[\s\S]*?\.gs-communications__locales\{grid-template-columns:minmax\(0,1fr\)\}/);
  assert.match(css, /@media\(max-width:480px\)[\s\S]*?\.gs-communications__filters\{grid-template-columns:minmax\(0,1fr\)\}/);
});

test('le code d’interface ne contacte pas directement de fournisseur', () => {
  assert.doesNotMatch(scriptInterface, /\bfetch\s*\(|XMLHttpRequest|api\.(?:brevo|resend|meta|expo)\b/i);
  assert.match(scriptInterface, /communicationReprendreEvenement/);
  assert.match(scriptInterface, /reprise_possible === true/);
});

test('les libellés visibles C5 possèdent leurs traductions EN, ES et HT', async () => {
  const [fr, en, es, ht, traductionsJs] = await Promise.all([
    lire('outils/traductions/tableau.txt'), lire('outils/traductions/en.json'),
    lire('outils/traductions/es.json'), lire('outils/traductions/ht.json'),
    lire('assets/js/tableau-textes.js')
  ]);
  const dictionnaires = [JSON.parse(en), JSON.parse(es), JSON.parse(ht)];
  const clesNecessaires = [
    'Ce canal n’est pas autorisé pour ce type de communication.',
    'Les mêmes variables doivent être présentes dans les quatre langues.',
    'La notification réelle sélectionnée est introuvable.',
    'La notification réelle sélectionnée est d’un autre type.',
    'Le modèle contient un balisage interdit.',
    'Le modèle contient une variable inconnue ou incomplète.',
    'Le nom du modèle WhatsApp n’est pas utilisé par le canal sélectionné.',
    'Le nom du modèle WhatsApp est obligatoire pour ce canal.',
    'Les données du modèle sont invalides.',
    'Reprendre le STOP',
    'Événement ajouté à la file de reprise. Le worker conserve son propre rythme.',
    'Dernière activité connue', 'Supervision et opérations transactionnelles',
    'Transitions', 'Variables requises', 'Recherche', 'Retiré', 'Ancienneté', 'Titre', 'Message',
    'Appliquer les filtres'
  ];
  for (const cle of clesNecessaires) {
    assert.ok(fr.split(/\r?\n/).includes(cle), `tableau.txt: ${cle}`);
    for (const dico of dictionnaires) assert.ok(dico[cle], `traduction manquante: ${cle}`);
    assert.ok(traductionsJs.includes(JSON.stringify(cle)), `tableau-textes.js: ${cle}`);
  }
});

test('les vues et actions sensibles restent derrière des permissions dédiées', async () => {
  const api = await lire('assets/js/api.js');
  const sql = await lire('outils/migrations-candidates/007-communication-interface-operations.sql');
  assert.match(api, /admin: \[[\s\S]*?'communications\.templates\.manage',[\s\S]*?'communications\.consents\.view',[\s\S]*?'communications\.queue\.retry'/);
  const manager = api.match(/gerant: \[([\s\S]*?)\],\s*employe:/)?.[1] || '';
  assert.match(manager, /communications\.view/);
  assert.doesNotMatch(manager, /communications\.(?:templates\.manage|consents\.view|queue\.retry)/);
  for (const [fonction, permission] of [
    ['communication_c5_modele_nouvelle_version', 'communications.templates.manage'],
    ['communication_c5_consentements_lister', 'communications.consents.view'],
    ['communication_c5_evenement_reprendre', 'communications.queue.retry']
  ]) {
    const debut = sql.indexOf(`function public.${fonction}`);
    const partie = sql.slice(debut, debut + 1200);
    assert.ok(debut >= 0, `RPC ${fonction} présente`);
    assert.ok(partie.includes(`exiger_permission('${permission}')`), `${fonction} vérifie ${permission}`);
  }
});
