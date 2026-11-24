/* ===========================================================================
   GoShip Express — arrêt d'urgence du Centre de communication (tableau de bord).
   Demander l'arrêt, le confirmer (relance automatique tant qu'il est en attente),
   le lever. Toutes les règles sont dans la base (candidates 001 et 010) : motif d'au
   moins 10 signes, version affichée exigée pour la levée, droit
   communications.emergency_stop. Cette page n'invente aucun état.
   =========================================================================== */
(function (racine) {
  'use strict';

  var RELANCE_MS = 10000;      // une confirmation toutes les 10 s tant qu'elle attend
  var RELANCES_MAX = 30;       // soit 5 minutes, puis l'Admin relance à la main
  var etat = null;
  var relances = 0;
  var minuterie = null;

  function api() { return racine.GoshipAPI && racine.GoshipAPI.admin; }
  function $(sel, base) { return (base || document).querySelector(sel); }
  function texte(n, t) { if (n) n.textContent = t == null ? '' : String(t); }
  function el(tag, cls, t) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (t != null) n.textContent = String(t);
    return n;
  }
  function locale() { return (document.documentElement.lang || 'fr').slice(0, 2); }
  function dateLocale(v) {
    var d = v ? new Date(v) : null;
    return d && !isNaN(d.getTime()) ? d.toLocaleString(locale()) : '';
  }

  var LIBELLES_ETAT = {
    actif: 'Envois autorisés',
    arret_demande: 'Arrêt demandé : confirmation en cours',
    arret_confirme: 'Arrêt confirmé : plus rien ne part'
  };
  var RAISONS = {
    VERROU_NON_OBTENU: 'Confirmation en attente : des envois sont en train de partir. Nouvelle tentative automatique.',
    TRANSMISSIONS_EN_COURS: 'Confirmation en attente : des envois déjà partis attendent la réponse du fournisseur.',
    TRANSMISSIONS_INCERTAINES: 'Confirmation en attente : des envois au résultat incertain doivent être réconciliés.'
  };
  var ERREURS = {
    REASON_REQUIRED: 'Indiquez un motif d’au moins 10 caractères.',
    STOP_STATE_CHANGED: 'L’état a changé depuis l’affichage. Vérifiez-le avant de lever l’arrêt.',
    'non-autorise': 'Vous n’avez pas le droit de gérer l’arrêt d’urgence.',
    reseau: 'Connexion impossible. Réessayez.',
    absent: 'L’arrêt d’urgence n’est pas encore installé sur cette base.'
  };
  function messageErreur(e) {
    var code = e && (ERREURS[e.code] ? e.code : (ERREURS[e.detail] ? e.detail : null));
    return code ? ERREURS[code] : 'L’opération n’a pas abouti. Réessayez.';
  }

  function zone() { return $('[data-cc-arret]'); }
  function message(t, erreur) {
    var n = $('[data-cc-arret-message]');
    if (!n) return;
    texte(n, t);
    n.className = erreur ? 'gs-form__erreur' : 'gs-communications__message';
    n.hidden = !t;
  }

  function arreterRelance() {
    if (minuterie) racine.clearTimeout(minuterie);
    minuterie = null;
  }

  function relancerConfirmation() {
    arreterRelance();
    if (relances >= RELANCES_MAX) {
      message('La confirmation attend toujours. Relancez-la quand les envois en cours sont terminés.', true);
      return;
    }
    minuterie = racine.setTimeout(confirmer, RELANCE_MS);
  }

  function confirmer() {
    var a = api();
    if (!a) return;
    relances += 1;
    a.communicationArretConfirmer().then(function (r) {
      r = r || {};
      if (r.etat === 'STOP_CONFIRMED') {
        relances = 0;
        message('Arrêt confirmé : plus aucun message ne part.');
        charger();
        return;
      }
      message(RAISONS[r.raison] || 'Confirmation en attente : nouvelle tentative automatique.');
      charger(true);
      relancerConfirmation();
    }, function (e) { message(messageErreur(e), true); });
  }

  function demander(motif, bouton) {
    var a = api();
    if (!a) return;
    if (!racine.confirm('Arrêter TOUS les envois (notifications et campagnes) ?')) return;
    bouton.disabled = true;
    a.communicationArretDemander(motif).then(function (r) {
      bouton.disabled = false;
      if (r && (r.etat === 'STOP_REQUESTED' || r.etat === 'STOP_CONFIRMED')) {
        relances = 0;
        message('Arrêt demandé : la demande est enregistrée. Confirmation…');
        confirmer();
      } else {
        message('L’arrêt n’a pas été enregistré. Réessayez.', true);
      }
    }, function (e) { bouton.disabled = false; message(messageErreur(e), true); });
  }

  function lever(motif, bouton) {
    var a = api();
    if (!a || !etat) return;
    if (!racine.confirm('Lever l’arrêt d’urgence et autoriser de nouveau les envois ?')) return;
    bouton.disabled = true;
    a.communicationArretLever(motif, etat.version).then(function () {
      bouton.disabled = false;
      arreterRelance();
      message('Arrêt levé : les envois reprennent.');
      charger();
    }, function (e) { bouton.disabled = false; message(messageErreur(e), true); charger(true); });
  }

  function formulaireMotif(libelleBouton, classeBouton, action) {
    var form = el('form', 'gs-form gs-form--compact gs-communications__arret-form');
    form.noValidate = true;
    var champ = el('div', 'gs-champ');
    var id = 'cc-arret-motif-' + Math.random().toString(36).slice(2, 8);
    var label = el('label', '', 'Motif (au moins 10 caractères)');
    label.htmlFor = id;
    var input = el('input');
    input.id = id; input.name = 'motif'; input.required = true; input.minLength = 10; input.maxLength = 300;
    champ.appendChild(label); champ.appendChild(input);
    var bouton = el('button', 'gs-bouton ' + classeBouton, libelleBouton);
    bouton.type = 'submit';
    form.appendChild(champ); form.appendChild(bouton);
    form.addEventListener('submit', function (ev) {
      ev.preventDefault();
      var motif = String(input.value || '').trim();
      if (motif.length < 10) { message(ERREURS.REASON_REQUIRED, true); input.focus(); return; }
      action(motif, bouton);
    });
    return form;
  }

  function afficher(e) {
    var z = zone();
    if (!z) return;
    etat = e;
    while (z.firstChild) z.removeChild(z.firstChild);
    var titre = el('h3', 'gs-sous-titre', 'Arrêt d’urgence');
    z.appendChild(titre);
    var ligne = el('p', 'gs-communications__arret-etat gs-communications__arret-etat--' + e.etat,
                   LIBELLES_ETAT[e.etat] || 'État inconnu');
    z.appendChild(ligne);
    // Un libellé fixe (traduit par tableau-langue.js) puis sa valeur, dans des nœuds séparés.
    var details = el('dl', 'gs-communications__arret-details');
    function detail(libelle, valeur) {
      if (!valeur) return;
      details.appendChild(el('dt', '', libelle));
      details.appendChild(el('dd', '', valeur));
    }
    if (e.etat !== 'actif') detail('Demandé le', dateLocale(e.demande_le));
    if (e.etat === 'arret_confirme') detail('Confirmé le', dateLocale(e.confirme_le));
    if (e.etat !== 'actif') detail('Motif', e.motif);
    if (e.etat === 'actif') detail('Dernière levée', dateLocale(e.leve_le));
    if (details.firstChild) z.appendChild(details);

    if (!e.peut_gerer) {
      z.appendChild(el('p', 'gs-panneau__intro', 'Seul l’administrateur peut demander ou lever l’arrêt.'));
    } else if (e.etat === 'actif') {
      z.appendChild(formulaireMotif('Arrêter tous les envois', 'gs-bouton--danger', demander));
    } else if (e.etat === 'arret_demande') {
      var b = el('button', 'gs-bouton gs-bouton--contour', 'Confirmer l’arrêt maintenant');
      b.type = 'button';
      b.addEventListener('click', function () { relances = 0; confirmer(); });
      z.appendChild(b);
      if (!minuterie) relancerConfirmation();
    } else if (e.etat === 'arret_confirme') {
      z.appendChild(formulaireMotif('Lever l’arrêt', 'gs-bouton--plein', lever));
    }
    var m = el('p', 'gs-communications__message');
    m.setAttribute('data-cc-arret-message', '');
    m.setAttribute('role', 'status');
    m.setAttribute('aria-live', 'polite');
    m.hidden = true;
    z.appendChild(m);
  }

  function charger(garderMessage) {
    var a = api(), z = zone();
    if (!a || !z || typeof a.communicationArretEtat !== 'function') return;
    var precedent = garderMessage ? $('[data-cc-arret-message]') : null;
    var ancien = precedent && !precedent.hidden ? { t: precedent.textContent, e: precedent.className === 'gs-form__erreur' } : null;
    a.communicationArretEtat().then(function (e) {
      if (!e || typeof e !== 'object' || !e.etat) { z.hidden = true; return; }
      z.hidden = false;
      afficher(e);
      if (ancien) message(ancien.t, ancien.e);
    }, function (e) {
      // Base sans la candidate 010, ou droit absent : rien à montrer.
      z.hidden = !(e && e.code && e.code !== 'absent' && e.code !== 'non-autorise');
      if (!z.hidden) { afficher({ etat: 'inconnu', peut_gerer: false }); message(messageErreur(e), true); }
    });
  }

  function init() {
    if (!zone()) return;
    charger();
    document.addEventListener('click', function (ev) {
      var t = ev.target && ev.target.closest && ev.target.closest('[data-cc-refresh],[data-cc-tab="overview"],[data-onglet-vue="communications"]');
      if (t) charger();
    });
    document.addEventListener('visibilitychange', function () {
      if (document.hidden) arreterRelance();
      else if (etat && etat.etat === 'arret_demande') relancerConfirmation();
    });
  }

  if (typeof document !== 'undefined') {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
    else init();
  }

  // Pour les essais (outils/essais-services/essai-communication-ecrans.mjs)
  racine.GoshipCommunicationsArret = { afficher: afficher, messageErreur: messageErreur };
})(typeof window !== 'undefined' ? window : this);
