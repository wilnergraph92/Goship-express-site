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
   Ce script n'est posé que sur les pages publiques (build.py), plus la page
   d'inscription : jamais sur le reste de l'espace client ni le tableau de bord.
   Sur la page d'inscription, Google n'est chargé qu'une fois le compte créé et
   le formulaire vidé, pour compter l'inscription (« sign_up ») : c'est elle qui
   dit si une publicité amène de vrais clients, pas un simple clic.

   Ce qui ne part jamais chez Google : le contenu d'un formulaire, un numéro
   de colis, et les paramètres de l'adresse (?suivi=GSE-…, ?retour=…) — la
   page est envoyée sans eux. Seuls restent ceux d'une campagne (utm_…, gclid),
   sans lesquels une visite venue d'une publicité serait comptée « directe ».
   Pas de publicité personnalisée ni de « signaux Google ».
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

  // L'adresse de la page sans son ancre ni ses paramètres, sauf ceux d'une campagne
  // publicitaire : Google en déduit d'où vient la visite. Ils ne disent rien du visiteur.
  var CAMPAGNE = /^(utm_(source|medium|campaign|term|content|id)|gclid|gbraid|wbraid|dclid)$/;
  function adressePropre() {
    var gardes = window.location.search.replace(/^\?/, '').split('&').filter(function (p) {
      return p && CAMPAGNE.test(decodeURIComponent(p.split('=')[0]));
    });
    return window.location.origin + window.location.pathname + (gardes.length ? '?' + gardes.join('&') : '');
  }

  window.dataLayer = window.dataLayer || [];
  // gtag.js attend l'objet « arguments » lui-même, pas un tableau : c'est la
  // forme exacte que donne Google, gardée telle quelle.
  function gtag() { window.dataLayer.push(arguments); }

  // Page d'inscription : rien n'est chargé tant que le compte n'est pas créé
  var inscription = !!document.querySelector('form[data-form="inscription"]');

  function demarrer(pageVue) {
    gtag('js', new Date());
    gtag('config', id, {
      page_location: adressePropre(),
      // La page d'où l'on vient, si elle est du site, perd aussi ses paramètres
      page_referrer: document.referrer.indexOf(site + '/') === 0
        ? document.referrer.replace(/[?#].*$/, '') : document.referrer,
      send_page_view: pageVue,
      allow_google_signals: false,
      allow_ad_personalization_signals: false
    });
    var script = document.createElement('script');
    script.async = true;
    script.src = 'https://www.googletagmanager.com/gtag/js?id=' + encodeURIComponent(id);
    document.head.appendChild(script);
  }

  if (inscription) {
    // Appelée par compte.js une fois le compte créé (formulaire déjà vidé) ; « suite »
    // (l'ouverture de Mon compte) attend l'envoi, une seconde et demie au plus.
    window.GoshipMesure = {
      inscription: function (methode, suite) {
        var fait = false;
        var continuer = function () { if (!fait) { fait = true; suite(); } };
        demarrer(false);
        gtag('event', 'sign_up', { method: methode, page_location: adressePropre(), transport_type: 'beacon',
                                   event_callback: continuer, event_timeout: 1500 });
        setTimeout(continuer, 1600);
      }
    };
    return;
  }

  demarrer(true);

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
