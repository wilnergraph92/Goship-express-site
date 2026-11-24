/* ===========================================================================
   GoShip Express — offres marketing du client (candidates 003 et 012).
   - Mon compte : le client lit le texte d'accord en vigueur et accepte ou retire,
     canal par canal (e-mail ; WhatsApp avec un code à 6 chiffres).
   - desabonnement.html : le lien de chaque e-mail marketing, sans connexion.
   Toutes les règles (texte attesté, adresse confirmée, numéro partagé, limites de
   demandes, jeton du lien) sont vérifiées par la base. Rien n'est supposé ici.
   =========================================================================== */
(function (racine) {
  'use strict';

  function API() { return racine.GoshipAPI; }
  function t(cle) {
    var a = API();
    return (a && a.outils && typeof a.outils.texte === 'function' && a.outils.texte(cle)) || '';
  }
  function $(sel, base) { return (base || document).querySelector(sel); }
  function langue() {
    var l = (document.documentElement.lang || 'fr').slice(0, 2);
    return ['fr', 'en', 'es', 'ht'].indexOf(l) >= 0 ? l : 'fr';
  }

  var ERREURS = {
    EMAIL_NOT_CONFIRMED: 'offres-err-email',
    CONTACT_UNAVAILABLE: 'offres-err-contact',
    INVALID_INPUT: 'offres-err-contact',
    REQUEST_RATE_LIMITED: 'offres-err-trop',
    'trop-de-tentatives': 'offres-err-trop',
    SHARED_TARGET_BLOCKED: 'offres-err-partage',
    SHARED_TARGET_POLICY_REQUIRED: 'offres-err-partage',
    POLICY_UNCONFIGURED: 'offres-err-indisponible',
    CONSENT_TEXT_NOT_APPROVED: 'offres-err-indisponible',
    SECURE_CONFIGURATION_UNAVAILABLE: 'offres-err-indisponible',
    absent: 'offres-err-indisponible'
  };
  function cleErreur(e) {
    if (!e) return 'offres-err-generique';
    return ERREURS[e.code] || ERREURS[e.detail] || 'offres-err-generique';
  }

  /* ---- Mon compte -------------------------------------------------------- */
  function messages(ok, erreur) {
    var nOk = $('[data-offres-ok]'), nErr = $('[data-offres-erreur]');
    if (nOk) { nOk.textContent = ok || ''; nOk.hidden = !ok; }
    if (nErr) { nErr.textContent = erreur || ''; nErr.hidden = !erreur; }
  }

  var LIRE = { email: 'marketingCourriel', whatsapp: 'marketingWhatsapp' };

  function afficherCanal(canal, etat, texte) {
    var bloc = $('[data-offre="' + canal + '"]');
    if (!bloc) return false;
    var actif = !!(etat && etat.actif);
    // Sans texte d'accord attesté, on ne propose pas d'accepter ; un client déjà inscrit
    // garde toujours le moyen de retirer son accord.
    if (!texte && !actif) { bloc.hidden = true; return false; }
    bloc.hidden = false;
    $('[data-offre-etat]', bloc).textContent = t(actif ? 'offres-etat-actif' : 'offres-etat-inactif');
    var citation = $('[data-offre-texte]', bloc);
    citation.textContent = texte && !actif ? String(texte.texte || '') : '';
    citation.hidden = !(texte && !actif);
    var accepter = $('[data-offre-accepter]', bloc);
    accepter.hidden = actif || !texte;
    accepter.setAttribute('data-version', texte ? String(texte.version) : '');
    $('[data-offre-retirer]', bloc).hidden = !actif;
    var form = $('[data-offre-code]', bloc);
    if (form && actif) form.hidden = true;
    return true;
  }

  function chargerCanal(canal) {
    var api = API();
    return Promise.all([
      api[LIRE[canal]]().catch(function () { return null; }),
      api.marketingTexte(canal, langue()).catch(function () { return null; })
    ]).then(function (r) { return afficherCanal(canal, r[0], r[1]); });
  }

  function chargerOffres() {
    var panneau = $('[data-offres]');
    if (!panneau) return;
    Promise.all([chargerCanal('email'), chargerCanal('whatsapp')]).then(function (vus) {
      panneau.hidden = !(vus[0] || vus[1]);
    });
  }

  function brancherMonCompte() {
    var panneau = $('[data-offres]');
    if (!panneau) return;
    var api = API();
    if (!api || typeof api.marketingTexte !== 'function') return;
    api.session().then(function (s) { if (s) chargerOffres(); }, function () {});

    panneau.addEventListener('click', function (ev) {
      var bouton = ev.target && ev.target.closest && ev.target.closest('[data-offre-accepter],[data-offre-retirer]');
      if (!bouton) return;
      var canal = bouton.closest('[data-offre]').getAttribute('data-offre');
      messages('', '');
      bouton.disabled = true;
      var appel;
      if (bouton.hasAttribute('data-offre-retirer')) {
        appel = (canal === 'email' ? api.marketingCourrielRetirer() : api.marketingWhatsappRetirer())
          .then(function () { messages(t('offres-ok-retire'), ''); });
      } else if (canal === 'email') {
        appel = api.marketingCourrielAccorder(bouton.getAttribute('data-version'), langue())
          .then(function () { messages(t('offres-ok-accepte'), ''); });
      } else {
        appel = api.marketingWhatsappDemander(bouton.getAttribute('data-version'), langue()).then(function () {
          var form = $('[data-offre="whatsapp"] [data-offre-code]');
          form.hidden = false;
          messages(t('offres-code-envoye'), '');
          var champ = form.querySelector('input');
          if (champ) champ.focus();
        });
      }
      appel.then(function () {
        bouton.disabled = false;
        if (!(canal === 'whatsapp' && bouton.hasAttribute('data-offre-accepter'))) chargerOffres();
      }, function (e) { bouton.disabled = false; messages('', t(cleErreur(e))); });
    });

    var form = $('[data-offre="whatsapp"] [data-offre-code]');
    if (form) form.addEventListener('submit', function (ev) {
      ev.preventDefault();
      var code = String(form.elements.code.value || '').replace(/\s+/g, '');
      if (!/^[0-9]{6}$/.test(code)) { messages('', t('offres-code-faux')); return; }
      api.marketingWhatsappConfirmer(code).then(function (r) {
        if (r && r.ok) {
          form.reset();
          form.hidden = true;
          messages(t('offres-ok-accepte'), '');
          chargerOffres();
        } else {
          messages('', t('offres-code-faux'));
        }
      }, function (e) { messages('', t(cleErreur(e))); });
    });
  }

  /* ---- Page de désinscription -------------------------------------------- */
  function brancherDesabonnement() {
    var carte = $('[data-desabonnement]');
    if (!carte) return;
    var attente = $('[data-desabo-attente]'), ok = $('[data-desabo-ok]'), invalide = $('[data-desabo-invalide]');
    function fin(reussi) {
      attente.hidden = true;
      ok.hidden = !reussi;
      invalide.hidden = reussi;
      if (reussi) ok.focus();
    }
    var params = new URLSearchParams(racine.location.search);
    var d = params.get('d'), j = params.get('j');
    // Le jeton ne quitte pas la page : il est retiré de l'adresse affichée et de l'historique.
    try { racine.history.replaceState(null, '', racine.location.pathname); } catch (e) { /* rien */ }
    if (!/^[0-9]{1,18}$/.test(d || '') || !/^[0-9a-f]{64}$/.test(j || '')) { fin(false); return; }
    var api = API();
    if (!api || typeof api.desabonnerCourriel !== 'function') { fin(false); return; }
    api.desabonnerCourriel(d, j).then(function (r) { fin(!!(r && r.ok)); }, function () { fin(false); });
  }

  function init() {
    brancherMonCompte();
    brancherDesabonnement();
  }
  if (typeof document !== 'undefined') {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
    else init();
  }

  racine.GoshipOffres = { afficherCanal: afficherCanal, cleErreur: cleErreur };
})(typeof window !== 'undefined' ? window : this);
