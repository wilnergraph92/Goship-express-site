/* ===========================================================================
   GoShip Express — envoi des campagnes marketing (tableau de bord, candidate 012).
   Réglage de fréquence par contact (N-01, sans valeur par défaut : tant qu'il manque,
   aucune campagne ne part) et suivi d'une campagne : mis en file, exclus par motif,
   état des transmissions. Comptages seulement : aucune donnée de client n'est affichée.
   =========================================================================== */
(function (racine) {
  'use strict';

  function api() { return racine.GoshipAPI && racine.GoshipAPI.admin; }
  function $(sel, base) { return (base || document).querySelector(sel); }
  function el(tag, cls, t) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (t != null) n.textContent = String(t);
    return n;
  }
  function vider(n) { while (n && n.firstChild) n.removeChild(n.firstChild); }
  function entier(v) { return typeof v === 'number' && isFinite(v) && v >= 0 ? Math.floor(v) : 0; }

  var MOTIFS = {
    sans_consentement: 'Sans accord pour ce canal',
    consentement_retire: 'Accord retiré',
    consentement_expire: 'Accord expiré',
    consentement_non_confirme: 'Accord non confirmé',
    consentement_invalide: 'Accord invalide',
    consentement_non_verifiable: 'Canal sans accord possible',
    contact_modifie: 'Contact modifié depuis l’accord',
    contact_non_verifiable: 'Contact absent ou illisible',
    contact_partage_ambigu: 'Contact partagé entre plusieurs comptes',
    suppression_active: 'STOP ou désinscription',
    doublon_contact: 'Déjà atteint par cette campagne',
    frequence: 'Limite de fréquence atteinte',
    plafond_journalier: 'Plafond d’e-mails sur 24 heures atteint',
    quota: 'Quota du canal atteint',
    compte_inexistant: 'Compte introuvable'
  };
  var STATUTS = {
    attente: 'En attente', envoi: 'En cours', envoye: 'Envoyés', livre: 'Livrés',
    echec: 'En échec', annule: 'Annulés', incertain: 'Incertains'
  };
  var ETATS = {
    scheduled: 'Planifiée', sending: 'Envoi en cours', completed: 'Terminée', cancelled: 'Annulée',
    approved: 'Approuvée', pending_approval: 'En attente d’approbation', draft: 'Brouillon'
  };
  var ERREURS = {
    COMMUNICATION_MARKETING_SETTINGS_INVALID: 'Fréquence entre 1 et 50 messages, fenêtre entre 1 et 2160 heures, plafond d’e-mails entre 1 et 100 000.',
    'non-autorise': 'Vous n’avez pas le droit de modifier ce réglage.',
    reseau: 'Connexion impossible. Réessayez.',
    absent: 'L’envoi des campagnes n’est pas encore installé sur cette base.'
  };
  function messageErreur(e) {
    var code = e && (ERREURS[e.code] ? e.code : (ERREURS[e.detail] ? e.detail : null));
    return code ? ERREURS[code] : 'L’opération n’a pas abouti. Réessayez.';
  }

  function message(t, erreur) {
    var n = $('[data-ce-message]');
    if (!n) return;
    n.textContent = t || '';
    n.className = erreur ? 'gs-form__erreur' : 'gs-communications__message';
    n.hidden = !t;
  }

  function afficherReglages(r) {
    var zone = $('[data-ce-reglages]');
    if (!zone) return;
    vider(zone);
    zone.appendChild(el('h4', '', 'Fréquence par client'));
    if (r && r.configure) {
      var dl = el('dl', 'gs-ce__reglage');
      dl.appendChild(el('dt', '', 'Messages marketing au plus, par client et par canal'));
      dl.appendChild(el('dd', '', entier(r.frequence_max)));
      dl.appendChild(el('dt', '', 'Sur une fenêtre de (heures)'));
      dl.appendChild(el('dd', '', entier(r.frequence_fenetre_heures)));
      dl.appendChild(el('dt', '', 'E-mails marketing au plus par 24 heures'));
      dl.appendChild(el('dd', '', r.email_max_jour ? entier(r.email_max_jour) : 'Sans plafond'));
      dl.appendChild(el('dt', '', 'E-mails marketing mis en file sur 24 heures'));
      dl.appendChild(el('dd', '', entier(r.email_mis_en_file_24h)));
      zone.appendChild(dl);
    } else {
      zone.appendChild(el('p', 'gs-panneau__intro', 'Non réglée : aucune campagne ne part tant que l’administrateur ne l’a pas fixée.'));
    }
    var form = el('form', 'gs-form gs-form--compact');
    form.noValidate = true;
    [['frequence_max', 'Messages au plus', 1, 50, r && r.frequence_max],
     ['fenetre_heures', 'Sur combien d’heures', 1, 2160, r && r.frequence_fenetre_heures],
     ['email_max_jour', 'E-mails marketing au plus par 24 heures (facultatif)', 1, 100000, r && r.email_max_jour]].forEach(function (c) {
      var champ = el('div', 'gs-champ');
      var label = el('label', '', c[1]);
      var input = el('input');
      input.type = 'number'; input.name = c[0]; input.min = String(c[2]); input.max = String(c[3]);
      input.required = c[0] !== 'email_max_jour'; input.id = 'ce-' + c[0];
      if (c[4]) input.value = String(c[4]);
      label.htmlFor = input.id;
      champ.appendChild(label); champ.appendChild(input);
      form.appendChild(champ);
    });
    var bouton = el('button', 'gs-bouton gs-bouton--plein', 'Enregistrer la fréquence');
    bouton.type = 'submit';
    form.appendChild(bouton);
    form.addEventListener('submit', function (ev) {
      ev.preventDefault();
      var max = Number(form.elements.frequence_max.value), heures = Number(form.elements.fenetre_heures.value);
      var brut = String(form.elements.email_max_jour.value || '').trim(), plafond = brut ? Number(brut) : null;
      if (!(max >= 1 && max <= 50 && heures >= 1 && heures <= 2160)
          || (plafond !== null && !(plafond >= 1 && plafond <= 100000))) {
        message(ERREURS.COMMUNICATION_MARKETING_SETTINGS_INVALID, true);
        return;
      }
      bouton.disabled = true;
      api().communicationMarketingReglagesDefinir(max, heures, plafond).then(function (nouveau) {
        bouton.disabled = false;
        message('Fréquence enregistrée.');
        afficherReglages(nouveau);
      }, function (e) { bouton.disabled = false; message(messageErreur(e), true); });
    });
    zone.appendChild(form);
  }

  function tableau(titre, objet, libelles) {
    var bloc = el('div', 'gs-ce__bloc');
    bloc.appendChild(el('h5', '', titre));
    var cles = Object.keys(objet || {}).filter(function (k) { return entier(objet[k]) > 0; });
    if (!cles.length) { bloc.appendChild(el('p', 'gs-panneau__intro', 'Aucun.')); return bloc; }
    var liste = el('ul', 'gs-ce__liste');
    cles.sort().forEach(function (k) {
      var li = el('li');
      li.appendChild(el('span', '', libelles[k] || k));
      li.appendChild(el('strong', 'gs-ce__nombre', entier(objet[k])));
      liste.appendChild(li);
    });
    bloc.appendChild(liste);
    return bloc;
  }

  function afficherSuivi(s) {
    var zone = $('[data-ce-suivi-resultat]');
    if (!zone) return;
    vider(zone);
    if (!s) return;
    var tete = el('dl', 'gs-ce__reglage');
    tete.appendChild(el('dt', '', 'État'));
    tete.appendChild(el('dd', 'gs-ce__etat', ETATS[s.etat] || s.etat));
    tete.appendChild(el('dt', '', 'Mis en file'));
    tete.appendChild(el('dd', '', entier(s.mis_en_file)));
    zone.appendChild(tete);
    zone.appendChild(tableau('Transmissions', s.transmission, STATUTS));
    zone.appendChild(tableau('Exclus', s.exclus, MOTIFS));
    var annulations = {};
    Object.keys(s.annulations || {}).forEach(function (k) {
      if (/^MARKETING_/.test(k)) annulations[k.replace(/^MARKETING_/, '').toLowerCase()] = s.annulations[k];
      else annulations[k] = s.annulations[k];
    });
    zone.appendChild(tableau('Annulés avant de partir', annulations,
      Object.assign({ campagne_annulee: 'Campagne annulée', NON_CONFIGURE: 'Canal non configuré',
                      SANS_DESTINATAIRE: 'Sans destinataire' }, MOTIFS)));
  }

  function chargerCampagnes() {
    var select = $('[data-ce-campagne]');
    var a = api();
    if (!select || !a || typeof a.communicationCampagnes !== 'function') return;
    a.communicationCampagnes(100).then(function (r) {
      var liste = (r && Array.isArray(r.campagnes)) ? r.campagnes : [];
      vider(select);
      select.appendChild(el('option', '', 'Choisir une campagne'));
      select.firstChild.value = '';
      liste.filter(function (c) { return ['scheduled', 'sending', 'completed', 'cancelled'].indexOf(c.etat) >= 0; })
        .forEach(function (c) {
          var o = el('option', '', (c.nom || ('#' + c.id)) + ' (' + c.etat + ')');
          o.value = String(c.id);
          select.appendChild(o);
        });
    }, function () {});
  }

  function charger() {
    var a = api(), zone = $('[data-ce-envoi]');
    if (!a || !zone || typeof a.communicationMarketingReglages !== 'function') return;
    a.communicationMarketingReglages().then(function (r) {
      zone.hidden = false;
      afficherReglages(r);
      chargerCampagnes();
    }, function (e) {
      zone.hidden = !(e && e.code && e.code !== 'absent' && e.code !== 'non-autorise');
      if (!zone.hidden) message(messageErreur(e), true);
    });
  }

  function init() {
    if (!$('[data-ce-envoi]')) return;
    charger();
    document.addEventListener('click', function (ev) {
      var t = ev.target && ev.target.closest && ev.target.closest('[data-cc-tab="campaigns"],[data-cm-refresh]');
      if (t) charger();
    });
    var select = $('[data-ce-campagne]');
    if (select) select.addEventListener('change', function () {
      var id = Number(select.value);
      if (!id) { afficherSuivi(null); return; }
      api().communicationCampagneSuivi(id).then(afficherSuivi, function (e) { message(messageErreur(e), true); });
    });
  }

  if (typeof document !== 'undefined') {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
    else init();
  }

  racine.GoshipCommunicationsEnvoi = { afficherSuivi: afficherSuivi, afficherReglages: afficherReglages, messageErreur: messageErreur };
})(typeof window !== 'undefined' ? window : this);
