/* ==========================================================================
   Goship Express — mesure d'audience (Google Analytics 4) et pixel Meta
   Combien de visiteurs, d'où ils viennent, quelles pages ils lisent, et
   combien écrivent ensuite sur WhatsApp ou demandent un devis. Rien de plus.
   Le pixel Meta sert à la même chose pour les publicités Facebook et
   Instagram : savoir si une publicité a fait écrire quelqu'un.

   Ne mesure rien si :
     • googleAnalytics et metaPixel sont vides dans config.js (chacun des deux
       ne se charge que s'il est réglé) ;
     • la page n'est pas servie par siteUrl (ordinateur, copie GitHub Pages) :
       on ne compte que les vrais visiteurs du vrai site ;
     • le navigateur demande à ne pas être suivi (Global Privacy Control,
       « Do Not Track »).
   Ce script n'est posé que sur les pages publiques (build.py) : jamais sur
   l'espace client ni le tableau de bord.

   Ce qui ne part jamais chez Google ni chez Meta : le contenu d'un formulaire,
   un numéro de colis, et les paramètres de l'adresse (?suivi=GSE-…,
   ?retour=…). Google reçoit la page sans eux. Le pixel Meta, lui, lit
   l'adresse tout seul et ne sait pas l'oublier : il ne se charge donc pas du
   tout quand l'adresse porte d'autres paramètres que ceux d'une publicité
   (fbclid, utm_…). Ni signaux Google, ni collecte automatique de Meta.
   ========================================================================== */
(function () {
  'use strict';

  var REGLAGES = window.GOSHIP_CONFIG || {};
  var idGoogle = String(REGLAGES.googleAnalytics || '').trim();
  var idMeta = String(REGLAGES.metaPixel || '').trim();
  if (!/^G-[A-Z0-9]{4,20}$/.test(idGoogle)) idGoogle = '';
  if (!/^\d{10,20}$/.test(idMeta)) idMeta = '';
  if (!idGoogle && !idMeta) return;

  var site = String(REGLAGES.siteUrl || '').trim().replace(/\/+$/, '');
  if (!site || window.location.origin !== site) return;

  var nav = window.navigator || {};
  if (nav.globalPrivacyControl === true || nav.doNotTrack === '1' || window.doNotTrack === '1') return;

  // L'adresse de la page sans ses paramètres ni son ancre
  function adressePropre() {
    return window.location.origin + window.location.pathname;
  }

  // Une adresse que le pixel peut voir telle quelle : sans paramètre, ou avec
  // seulement ceux qu'ajoute une publicité. Un lien de suivi (?suivi=GSE-…) ou
  // de retour garde le pixel éteint sur cette page.
  function adresseSansSecret() {
    var reste = window.location.search.replace(/^\?/, '').split('&').filter(function (morceau) {
      var nom = morceau.split('=')[0];
      return nom && nom !== 'fbclid' && !/^utm_[a-z]+$/.test(nom);
    });
    return reste.length === 0 && !window.location.hash;
  }

  // ---- Google Analytics 4 ------------------------------------------------
  var gtag = null;
  if (idGoogle) {
    window.dataLayer = window.dataLayer || [];
    // gtag.js attend l'objet « arguments » lui-même, pas un tableau : c'est la
    // forme exacte que donne Google, gardée telle quelle.
    gtag = function () { window.dataLayer.push(arguments); };

    gtag('js', new Date());
    gtag('config', idGoogle, {
      page_location: adressePropre(),
      // La page d'où l'on vient, si elle est du site, perd aussi ses paramètres
      page_referrer: document.referrer.indexOf(site + '/') === 0
        ? document.referrer.replace(/[?#].*$/, '') : document.referrer,
      allow_google_signals: false,
      allow_ad_personalization_signals: false
    });

    var scriptGoogle = document.createElement('script');
    scriptGoogle.async = true;
    scriptGoogle.src = 'https://www.googletagmanager.com/gtag/js?id=' + encodeURIComponent(idGoogle);
    document.head.appendChild(scriptGoogle);
  }

  // ---- Pixel Meta --------------------------------------------------------
  var fbq = null;
  if (idMeta && adresseSansSecret()) {
    // La file d'attente que Meta documente : les appels faits avant que
    // fbevents.js soit chargé attendent dans fbq.queue, puis il les rejoue.
    fbq = window.fbq = function () {
      if (fbq.callMethod) fbq.callMethod.apply(fbq, arguments);
      else fbq.queue.push(arguments);
    };
    if (!window._fbq) window._fbq = fbq;
    fbq.push = fbq;
    fbq.loaded = true;
    fbq.version = '2.0';
    fbq.queue = [];

    // Pas de collecte automatique : Meta ne lit ni le texte des boutons ni le
    // contenu de la page, il ne reçoit que les événements envoyés plus bas.
    fbq('set', 'autoConfig', false, idMeta);
    fbq('init', idMeta);
    fbq('track', 'PageView');

    var scriptMeta = document.createElement('script');
    scriptMeta.async = true;
    scriptMeta.src = 'https://connect.facebook.net/en_US/fbevents.js';
    document.head.appendChild(scriptMeta);
  }

  // Les gestes qui comptent pour l'entreprise : un contact (WhatsApp, téléphone,
  // e-mail), une inscription commencée, un formulaire envoyé. Seulement leur
  // nature, jamais ce qui a été écrit. Meta reçoit les mêmes gestes sous ses
  // noms à lui : « Contact » pour un contact, « Lead » pour une demande écrite.
  function evenement(nom, details) {
    details = details || {};
    if (gtag) {
      details.page_location = adressePropre();
      gtag('event', nom, details);
    }
    if (fbq && nom === 'generate_lead') {
      fbq('track', details.method === 'formulaire' ? 'Lead' : 'Contact', { content_name: details.method });
    }
  }

  document.addEventListener('click', function (e) {
    var lien = e.target && e.target.closest ? e.target.closest('a[href]') : null;
    if (!lien) return;
    var href = lien.getAttribute('href') || '';
    if (/^https:\/\/(wa\.me|api\.whatsapp\.com)\//i.test(href)) evenement('generate_lead', { method: 'whatsapp' });
    else if (/^tel:/i.test(href)) evenement('generate_lead', { method: 'telephone' });
    else if (/^mailto:/i.test(href)) evenement('generate_lead', { method: 'email' });
    else if (/(^|\/)inscription(\.html)?([?#]|$)/i.test(href)) evenement('clic_inscription');
  }, true);

  document.addEventListener('submit', function (e) {
    var form = e.target;
    var type = form && form.getAttribute ? form.getAttribute('data-form') : '';
    if (!type) return;
    if (type === 'track') evenement('suivi_colis');
    else evenement('generate_lead', { method: 'formulaire', form_name: type });
  }, true);
})();
