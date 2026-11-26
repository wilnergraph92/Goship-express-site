// Écrans du Centre de communication ajoutés le 24/11/2026 (candidates 010 et 012) :
// arrêt d'urgence et envoi des campagnes (tableau de bord), offres et désinscription
// (espace client). Sans navigateur ni réseau : fonctions pures, appels d'API, points
// d'ancrage des pages et traductions.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const racine = new URL('../../', import.meta.url);
const lire = (chemin) => readFile(new URL(chemin, racine), 'utf8');
const charger = async (chemin) => {
  const contexte = { window: {} };
  vm.runInNewContext(await lire(chemin), contexte, { filename: chemin });
  return contexte.window;
};
const api = await lire('assets/js/api.js');
const arret = await lire('assets/js/communications-arret.js');
const envoi = await lire('assets/js/communications-envoi.js');
const offres = await lire('assets/js/offres.js');

test('les erreurs de la base deviennent des messages, jamais un code brut', async () => {
  const a = (await charger('assets/js/communications-arret.js')).GoshipCommunicationsArret;
  assert.match(a.messageErreur({ code: 'REASON_REQUIRED' }), /10 caractères/);
  assert.match(a.messageErreur({ code: 'STOP_STATE_CHANGED' }), /a changé/);
  assert.match(a.messageErreur({ code: 'inconnu', detail: 'AUTRE' }), /Réessayez/);
  const e = (await charger('assets/js/communications-envoi.js')).GoshipCommunicationsEnvoi;
  assert.match(e.messageErreur({ code: 'inconnu', detail: 'COMMUNICATION_MARKETING_SETTINGS_INVALID' }), /entre 1 et 50/);
  const o = (await charger('assets/js/offres.js')).GoshipOffres;
  assert.equal(o.cleErreur({ code: 'inconnu', detail: 'EMAIL_NOT_CONFIRMED' }), 'offres-err-email');
  assert.equal(o.cleErreur({ code: 'inconnu', detail: 'SHARED_TARGET_BLOCKED' }), 'offres-err-partage');
  assert.equal(o.cleErreur({ code: 'inconnu', detail: 'REQUEST_RATE_LIMITED' }), 'offres-err-trop');
  assert.equal(o.cleErreur(null), 'offres-err-generique');
});

test('chaque écran passe par les RPC prévues, dans les trois modes de l’API', () => {
  const rpc = {
    communicationArretEtat: 'communication_c10_arret_etat', communicationArretDemander: 'communication_c10_arret_demander',
    communicationArretConfirmer: 'communication_c10_arret_confirmer', communicationArretLever: 'communication_c10_arret_lever',
    communicationMarketingReglages: 'communication_marketing_reglages_lire',
    communicationMarketingReglagesDefinir: 'communication_marketing_reglages_definir',
    communicationCampagneSuivi: 'communication_campagne_suivi'
  };
  for (const [methode, nom] of Object.entries(rpc)) {
    assert.match(api, new RegExp(`${methode}: function \\([^)]*\\) \\{\\s*return sb\\(\\)\\.then\\(function \\(c\\) \\{ return c\\.rpc\\('${nom}'`));
    assert.match(api, new RegExp(`${methode}: function \\(\\) \\{ return communicationDemoNonDisponible\\(`));
  }
  assert.match(api, /p_version_attendue: Number\(version\)/);
  const client = {
    marketingTexte: 'communication_consentement_texte_actuel', marketingWhatsapp: 'communication_consentement_etat_whatsapp',
    marketingWhatsappDemander: 'communication_consentement_demander_whatsapp',
    marketingWhatsappConfirmer: 'communication_consentement_confirmer_whatsapp',
    marketingWhatsappRetirer: 'communication_consentement_retirer_whatsapp',
    marketingCourriel: 'communication_consentement_courriel_etat',
    marketingCourrielAccorder: 'communication_consentement_courriel_accorder',
    marketingCourrielRetirer: 'communication_consentement_courriel_retirer',
    desabonnerCourriel: 'communication_desabonner_courriel'
  };
  for (const [methode, nom] of Object.entries(client)) {
    assert.match(api, new RegExp(`${methode}: function \\([^)]*\\) \\{\\s*return appelBase\\('${nom}'`));
    assert.match(api, new RegExp(`${methode}: (?:ferme|function)`));
  }
  // Mode démonstration : aucun texte attesté, donc rien à accepter.
  assert.match(api, /marketingTexte: function \(\) \{ return Promise\.resolve\(null\); \}/);
});

test('aucun écran n’écrit du HTML brut ni n’appelle un fournisseur', () => {
  for (const source of [arret, envoi, offres]) {
    assert.doesNotMatch(source, /innerHTML|outerHTML|insertAdjacentHTML|document\.write/);
    assert.doesNotMatch(source, /\bfetch\s*\(|XMLHttpRequest|graph\.facebook|brevo|resend|exp\.host/i);
  }
  // Le jeton de désinscription est retiré de l'adresse affichée.
  assert.match(offres, /history\.replaceState\(null, '', racine\.location\.pathname\)/);
  assert.match(offres, /\^\[0-9a-f\]\{64\}\$/);
  // La levée exige la version affichée ; la confirmation est relancée, bornée.
  assert.match(arret, /communicationArretLever\(motif, etat\.version\)/);
  assert.match(arret, /RELANCES_MAX = 30/);
});

test('les pages portent les points d’ancrage et les scripts', async () => {
  for (const chemin of ['admin.html', 'outils/generateur/pages/admin.html']) {
    const h = await lire(chemin);
    assert.ok(h.includes('data-cc-arret'), chemin);
    assert.ok(h.includes('data-ce-envoi') && h.includes('data-ce-campagne') && h.includes('data-ce-suivi-resultat'), chemin);
    assert.ok(h.includes('assets/js/communications-arret.js') && h.includes('assets/js/communications-envoi.js'), chemin);
  }
  for (const langue of ['', 'en/', 'es/', 'ht/']) {
    const compte = await lire(`${langue}mon-compte.html`);
    assert.ok(compte.includes('data-offres') && compte.includes('data-offre="email"') && compte.includes('data-offre="whatsapp"'));
    assert.ok(compte.includes('offres.js'));
    const desabo = await lire(`${langue}desabonnement.html`);
    assert.ok(desabo.includes('data-desabonnement') && desabo.includes('offres.js'));
    assert.match(desabo, /<meta name="robots" content="noindex/);
  }
});

test('les nouveaux textes ont leurs traductions EN, ES et HT', async () => {
  const dicos = await Promise.all(['en', 'es', 'ht'].map(async (l) => JSON.parse(await lire(`outils/traductions/${l}.json`))));
  const tableau = (await lire('outils/traductions/tableau.txt')).split('\n');
  const obligatoires = ['Arrêt d’urgence', 'Arrêter tous les envois', 'Lever l’arrêt', 'Confirmer l’arrêt maintenant',
    'Envoi des campagnes', 'Fréquence par client', 'Limite de fréquence atteinte', 'STOP ou désinscription',
    'Offres et nouvelles', 'Se désabonner', 'Recevoir un code sur WhatsApp', 'J\'accepte de recevoir les offres par e-mail'];
  for (const cle of obligatoires) for (const d of dicos) assert.ok(d[cle], cle);
  for (const cle of ['Arrêt d’urgence', 'Envoi des campagnes', 'Fréquence par client']) assert.ok(tableau.includes(cle), cle);
});
