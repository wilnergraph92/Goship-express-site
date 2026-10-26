/* ==========================================================================
   Goship Express — mesure d'audience (Google Analytics 4)
   Combien de visiteurs, d'où ils viennent, quelles pages ils lisent, et
   combien écrivent ensuite sur WhatsApp ou demandent un devis. Rien de plus.

   Ne mesure rien si :
     • googleAnalytics est vide dans config.js ;
     • la page n'est pas servie par siteUrl (ordinateur, copie GitHub Pages) :
       on ne compte que les vrais visiteurs du vrai site ;
     • le navigateur demande à ne pas être suivi (Global Privacy Control,
       « Do Not Track »).
   Ce script n'est posé que sur les pages publiques (build.py) : jamais sur
   l'espace client ni le tableau de bord.

   Ce qui ne part jamais chez Google : le contenu d'un formulaire, un numéro
   de colis, et les paramètres de l'adresse (?suivi=GSE-…, ?retour=…) — la
   page est envoyée sans eux. Pas de publicité ni de « signaux Google ».
   ========================================================================== */
(function () {
  'use strict';

  var REGLAGES = window.GOSHIP_CONFIG || {};
  var id = String(REGLAGES.googleAnalytics || '').trim();
  if (!/^G-[A-Z0-9]{4,20}$/.test(id)) return;

  var site = String(REGLAGES.siteUrl || '').trim().replace(/\/+$/, '');
  if (!site || window.location.origin !== site) return;

  var nav = window.navigator || {};
  if (nav.globalPrivacyControl === true || nav.doNotTrack === '1' || window.doNotTrack === '1') return;

  // L'adresse de la page sans ses paramètres ni son ancre
  function adressePropre() {
    return window.location.origin + window.location.pathname;
  }

  window.dataLayer = window.dataLayer || [];
  // gtag.js attend l'objet « arguments » lui-même, pas un tableau : c'est la
  // forme exacte que donne Google, gardée telle quelle.
  function gtag() { window.dataLayer.push(arguments); }

  gtag('js', new Date());
  gtag('config', id, {
    page_location: adressePropre(),
    // La page d'où l'on vient, si elle est du site, perd aussi ses paramètres
    page_referrer: document.referrer.indexOf(site + '/') === 0
      ? document.referrer.replace(/[?#].*$/, '') : document.referrer,
    allow_google_signals: false,
    allow_ad_personalization_signals: false
  });

  var script = document.createElement('script');
  script.async = true;
  script.src = 'https://www.googletagmanager.com/gtag/js?id=' + encodeURIComponent(id);
  document.head.appendChild(script);

  // Les gestes qui comptent pour l'entreprise : un contact (WhatsApp, téléphone,
  // e-mail), une inscription commencée, un formulaire envoyé. Seulement leur
  // nature, jamais ce qui a été écrit.
  function evenement(nom, details) {
    details = details || {};
    details.page_location = adressePropre();
    gtag('event', nom, details);
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
