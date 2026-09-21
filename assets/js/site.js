/* ==========================================================================
   Goship Express — interactions du site
   ========================================================================== */
(function () {
  'use strict';

  /* ---- Réglages : voir assets/js/config.js ------------------------------- */
  var REGLAGES = window.GOSHIP_CONFIG || {};
  var CONFIG = {
    whatsapp: String(REGLAGES.whatsapp || '18495386262').replace(/\D/g, ''),
    formEndpoint: REGLAGES.formEndpoint || ''
  };

  /* ---- Textes affichés par le script, dans chaque langue du site ---------- */
  var TEXTES = {
    fr: {
      menuOuvrir: 'Ouvrir le menu',
      menuFermer: 'Fermer le menu',
      copie: 'Adresse copiée ✓',
      copieEchec: 'Copie impossible : sélectionnez l’adresse à la main',
      suivi: 'Bonjour Goship Express, je souhaite connaître le statut de mon colis. Référence : ',
      devis: 'Bonjour Goship Express, je souhaite un devis.',
      champs: { nom: 'Nom', entreprise: 'Entreprise', email: 'E-mail', telephone: 'Téléphone / WhatsApp',
                corridor: 'Corridor', type_envoi: "Type d'envoi", besoin: 'Besoin' },
      devisWaTitre: 'Demande prête dans WhatsApp.',
      devisWaTexte: 'Appuyez sur « Envoyer » dans WhatsApp pour nous la transmettre. Un responsable corridor vous répond sous 2 heures ouvrées avec un tarif et un délai fermes.',
      devisOkTitre: 'Demande envoyée.',
      devisOkTexte: 'Merci ! Un responsable corridor vous répond sous 2 heures ouvrées avec un tarif et un délai fermes.',
      lettre: "Bonjour Goship Express, je souhaite recevoir vos conseils d'expédition par e-mail : ",
      lettreWa: 'Merci ! Envoyez le message préparé dans WhatsApp pour confirmer votre inscription.',
      lettreOk: 'Merci ! Votre inscription est bien enregistrée.',
      lettreErreur: 'Envoi impossible pour le moment. Réessayez ou écrivez-nous sur WhatsApp.'
    },
    en: {
      menuOuvrir: 'Open menu',
      menuFermer: 'Close menu',
      copie: 'Address copied ✓',
      copieEchec: 'Copy failed: please select the address manually',
      suivi: 'Hello Goship Express, I would like to know the status of my package. Reference: ',
      devis: 'Hello Goship Express, I would like a quote.',
      champs: { nom: 'Name', entreprise: 'Company', email: 'Email', telephone: 'Phone / WhatsApp',
                corridor: 'Route', type_envoi: 'Shipment type', besoin: 'Details' },
      devisWaTitre: 'Your request is ready in WhatsApp.',
      devisWaTexte: 'Tap “Send” in WhatsApp to pass it on to us. A route manager will reply within 2 business hours with a firm price and delivery time.',
      devisOkTitre: 'Request sent.',
      devisOkTexte: 'Thank you! A route manager will reply within 2 business hours with a firm price and delivery time.',
      lettre: 'Hello Goship Express, I would like to receive your shipping tips by email: ',
      lettreWa: 'Thank you! Send the prepared message in WhatsApp to confirm your subscription.',
      lettreOk: 'Thank you! Your subscription has been recorded.',
      lettreErreur: 'Unable to send right now. Please try again or message us on WhatsApp.'
    },
    es: {
      menuOuvrir: 'Abrir el menú',
      menuFermer: 'Cerrar el menú',
      copie: 'Dirección copiada ✓',
      copieEchec: 'No se pudo copiar: seleccione la dirección manualmente',
      suivi: 'Hola Goship Express, quisiera saber el estado de mi paquete. Referencia: ',
      devis: 'Hola Goship Express, quisiera una cotización.',
      champs: { nom: 'Nombre', entreprise: 'Empresa', email: 'Correo', telephone: 'Teléfono / WhatsApp',
                corridor: 'Ruta', type_envoi: 'Tipo de envío', besoin: 'Detalles' },
      devisWaTitre: 'Su solicitud está lista en WhatsApp.',
      devisWaTexte: 'Pulse «Enviar» en WhatsApp para hacérnosla llegar. Un encargado de ruta le responderá en menos de 2 horas hábiles con un precio y un plazo firmes.',
      devisOkTitre: 'Solicitud enviada.',
      devisOkTexte: '¡Gracias! Un encargado de ruta le responderá en menos de 2 horas hábiles con un precio y un plazo firmes.',
      lettre: 'Hola Goship Express, quisiera recibir sus consejos de envío por correo: ',
      lettreWa: '¡Gracias! Envíe el mensaje preparado en WhatsApp para confirmar su suscripción.',
      lettreOk: '¡Gracias! Su suscripción ha quedado registrada.',
      lettreErreur: 'No se pudo enviar por ahora. Inténtelo de nuevo o escríbanos por WhatsApp.'
    },
    ht: {
      menuOuvrir: 'Louvri meni an',
      menuFermer: 'Fèmen meni an',
      copie: 'Adrès la kopye ✓',
      copieEchec: 'Nou pa rive kopye l : seleksyone adrès la ak men ou',
      suivi: 'Bonjou Goship Express, mwen ta renmen konnen ki kote koli mwen an ye. Referans : ',
      devis: 'Bonjou Goship Express, mwen ta renmen yon devi.',
      champs: { nom: 'Non', entreprise: 'Konpayi', email: 'Imèl', telephone: 'Telefòn / WhatsApp',
                corridor: 'Wout', type_envoi: 'Kalite koli', besoin: 'Detay' },
      devisWaTitre: 'Demann ou an pare nan WhatsApp.',
      devisWaTexte: 'Peze « Voye » nan WhatsApp pou voye l ba nou. Yon responsab wout ap reponn ou nan 2 èdtan travay, ak yon pri ak yon dele ki fiks.',
      devisOkTitre: 'Demann lan pati.',
      devisOkTexte: 'Mèsi ! Yon responsab wout ap reponn ou nan 2 èdtan travay, ak yon pri ak yon dele ki fiks.',
      lettre: 'Bonjou Goship Express, mwen ta renmen resevwa konsèy ekspedisyon nou yo pa imèl : ',
      lettreWa: 'Mèsi ! Voye mesaj ki pare nan WhatsApp la pou konfime enskripsyon ou.',
      lettreOk: 'Mèsi ! Enskripsyon ou anrejistre.',
      lettreErreur: 'Nou pa rive voye l kounye a. Eseye ankò oswa ekri nou sou WhatsApp.'
    }
  };
  var LANGUE = (document.documentElement.lang || 'fr').slice(0, 2).toLowerCase();
  var T = TEXTES[LANGUE] || TEXTES.fr;

  function whatsappUrl(text) {
    return 'https://wa.me/' + CONFIG.whatsapp + '?text=' + encodeURIComponent(text);
  }

  // Ouvre WhatsApp dans un nouvel onglet (ou l'application sur mobile).
  function openWhatsApp(text) {
    var link = document.createElement('a');
    link.href = whatsappUrl(text);
    link.target = '_blank';
    link.rel = 'noopener';
    document.body.appendChild(link);
    link.click();
    link.remove();
  }

  // Les e-mails reçus par Goship ont un objet en français, avec la langue du visiteur.
  function sendToEndpoint(form, subject) {
    var data = new FormData(form);
    data.append('_subject', subject + ' [' + LANGUE.toUpperCase() + ']');
    data.append('langue', LANGUE);
    return fetch(CONFIG.formEndpoint, {
      method: 'POST',
      body: data,
      headers: { Accept: 'application/json' }
    }).then(function (res) {
      if (!res.ok) throw new Error('HTTP ' + res.status);
    });
  }

  function field(form, name) {
    var el = form.elements[name];
    return el ? String(el.value || '').trim() : '';
  }

  /* ---- Sélecteur de langue ------------------------------------------------- */
  var langMenus = Array.prototype.slice.call(document.querySelectorAll('[data-lang-menu]'));
  function closeLangMenus(except) {
    langMenus.forEach(function (d) { if (d !== except) d.open = false; });
  }

  /* ---- Menu mobile ------------------------------------------------------- */
  var header = document.querySelector('[data-header]');
  var toggle = document.querySelector('[data-menu-toggle]');
  var setOpen = function () {};
  if (header && toggle) {
    setOpen = function (open) {
      header.classList.toggle('is-open', open);
      toggle.setAttribute('aria-expanded', String(open));
      toggle.setAttribute('aria-label', open ? T.menuFermer : T.menuOuvrir);
      if (open) closeLangMenus();
    };
    toggle.addEventListener('click', function () {
      setOpen(!header.classList.contains('is-open'));
    });
    header.addEventListener('click', function (e) {
      if (e.target.closest('.gs-nav a, .gs-actions a')) setOpen(false);
    });
    var desktop = window.matchMedia('(min-width: 1024px)');
    var onChange = function () { if (desktop.matches) setOpen(false); };
    if (desktop.addEventListener) desktop.addEventListener('change', onChange);
    else if (desktop.addListener) desktop.addListener(onChange);
  }

  langMenus.forEach(function (menu) {
    menu.addEventListener('toggle', function () {
      if (menu.open) {
        closeLangMenus(menu);
        if (header && header.classList.contains('is-open')) setOpen(false);
      }
    });
  });
  document.addEventListener('click', function (e) {
    if (!e.target.closest('[data-lang-menu]')) closeLangMenus();
  });
  document.addEventListener('keydown', function (e) {
    if (e.key !== 'Escape') return;
    var openMenu = langMenus.filter(function (d) { return d.open; })[0];
    if (openMenu) {
      openMenu.open = false;
      openMenu.querySelector('summary').focus();
    } else if (header && header.classList.contains('is-open')) {
      setOpen(false);
      toggle.focus();
    }
  });

  /* ---- Copier l'adresse de réception USA --------------------------------- */
  function addressText(table) {
    var v = {};
    Array.prototype.forEach.call(table.children, function (row) {
      var cells = row.children;
      if (cells.length >= 2) v[cells[0].textContent.trim()] = cells[1].textContent.trim();
    });
    return [
      v['Name'],
      v['Address 1'],
      v['Address 2'],
      [v['City'], [v['State'], v['Zip Code']].filter(Boolean).join(' ')].filter(Boolean).join(', '),
      v['Country'],
      v['Phone']
    ].filter(Boolean).join('\n');
  }

  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text).catch(function () { return legacyCopy(text); });
    }
    return legacyCopy(text);
  }

  function legacyCopy(text) {
    return new Promise(function (resolve, reject) {
      var ta = document.createElement('textarea');
      ta.value = text;
      ta.setAttribute('readonly', '');
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      var ok = false;
      try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
      ta.remove();
      if (ok) resolve(); else reject(new Error('copy failed'));
    });
  }

  document.querySelectorAll('[data-action="copy-address"]').forEach(function (btn) {
    var scope = btn.closest('section') || document;
    var table = scope.querySelector('[data-address-table]');
    var feedback = scope.querySelector('[data-copy-feedback]');
    if (!table) return;
    var timer;
    btn.addEventListener('click', function () {
      copyText(addressText(table)).then(function () {
        if (!feedback) return;
        feedback.textContent = T.copie;
        feedback.hidden = false;
        clearTimeout(timer);
        timer = setTimeout(function () { feedback.hidden = true; }, 2600);
      }, function () {
        if (!feedback) return;
        feedback.textContent = T.copieEchec;
        feedback.hidden = false;
      });
    });
  });

  /* ---- Espace client : « Créer un compte » devient « Mon compte » ---------- */
  var DEMO = !(REGLAGES.supabaseUrl && REGLAGES.supabaseKey);
  function sessionOuverte() {
    try {
      if (DEMO) return !!localStorage.getItem('gse-demo-session');
      for (var i = 0; i < localStorage.length; i++) {
        if (/^sb-.+-auth-token$/.test(localStorage.key(i) || '')) return true;
      }
    } catch (e) { /* stockage indisponible */ }
    return false;
  }
  function majSession() {
    var connecte = sessionOuverte();
    document.querySelectorAll('[data-session]').forEach(function (el) {
      el.hidden = (el.getAttribute('data-session') === 'oui') !== connecte;
    });
  }
  majSession();
  window.addEventListener('storage', majSession);
  document.addEventListener('goship:session', majSession);

  /* ---- Boutons Google Play et App Store ------------------------------------
     Tant que les adresses des boutiques ne sont pas renseignées dans config.js,
     les boutons affichent « Bientôt sur » et ne mènent nulle part. Dès qu'une
     adresse est ajoutée, le bouton devient un vrai lien. */
  (function boutiques() {
    var boutons = document.querySelectorAll('.gs-store');
    if (!boutons.length) return;
    var toutesPretes = true;
    boutons.forEach(function (bouton) {
      var reglage = bouton.getAttribute('data-store') === 'ios' ? REGLAGES.appStoreLien : REGLAGES.googlePlayLien;
      var lien = String(reglage || '').trim();
      if (/^https:\/\//.test(lien)) {
        bouton.href = lien;
        bouton.target = '_blank';
        bouton.rel = 'noopener';
      } else {
        toutesPretes = false;
      }
      bouton.querySelectorAll('[data-store-etat]').forEach(function (el) {
        el.hidden = (el.getAttribute('data-store-etat') === 'pret') !== !!bouton.href;
      });
    });
    if (toutesPretes) {
      document.querySelectorAll('.gs-app__attente[data-store-etat="bientot"]').forEach(function (el) {
        el.hidden = true;
      });
    }
  })();

  /* ---- Suivi de colis ------------------------------------------------------
     Espace client actif : recherche du colis (numéro GSE ou suivi du vendeur)
     et affichage de ses étapes. Sinon : demande de suivi préparée dans WhatsApp. */
  document.querySelectorAll('form[data-form="track"]').forEach(function (form) {
    var scope = form.closest('section') || document;
    var result = scope.querySelector('[data-track-result]');
    var bouton = form.querySelector('[type="submit"]');
    var API = null;
    if (!result) return;

    function montrer(etat) {
      result.querySelectorAll('[data-track-etat]').forEach(function (bloc) {
        bloc.hidden = bloc.getAttribute('data-track-etat') !== etat;
      });
      result.hidden = false;
    }

    function viaWhatsApp(ref) {
      openWhatsApp(T.suivi + ref);
      montrer('whatsapp');
    }

    function afficherColis(colis) {
      var O = API.outils;
      var badge = result.querySelector('[data-track-statut]');
      badge.textContent = O.texte('statut-' + colis.statut);
      badge.className = 'gs-badge gs-badge--' + colis.statut;
      result.querySelector('[data-track-maj]').textContent = O.texte('maj', { date: O.date(colis.maj_le, true) });
      O.remplirEtapes(result.querySelector('[data-track-etapes]'), colis.statut, colis.historique);
      O.remplirHistorique(result.querySelector('[data-track-historique]'), colis.historique);
      result.querySelectorAll('[data-track-ref]').forEach(function (el) { el.textContent = colis.numero; });
      montrer('trouve');
    }

    form.addEventListener('submit', function (e) {
      e.preventDefault();
      var input = form.elements.ref;
      var ref = String(input.value || '').trim().toUpperCase();
      if (!ref) { input.focus(); return; }
      result.querySelectorAll('[data-track-ref]').forEach(function (el) { el.textContent = ref; });
      result.querySelectorAll('[data-track-link]').forEach(function (a) { a.href = whatsappUrl(T.suivi + ref); });

      API = window.GoshipAPI; // chargé après ce script (api.js)
      if (!API || API.mode === 'off') { viaWhatsApp(ref); return; }
      if (/^GSE-?\d{6,}$/.test(ref.replace(/\s+/g, ''))) { montrer('code-client'); return; }

      bouton.disabled = true;
      form.setAttribute('aria-busy', 'true');
      API.suivre(ref).then(function (colis) {
        if (colis) afficherColis(colis); else montrer('introuvable');
      }, function () {
        viaWhatsApp(ref);
      }).then(function () {
        bouton.disabled = false;
        form.removeAttribute('aria-busy');
        if (result.getBoundingClientRect().top > window.innerHeight * 0.8) {
          result.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
        }
      });
    });
  });

  /* ---- Demande de devis (page Contacts) ----------------------------------- */
  document.querySelectorAll('form[data-form="quote"]').forEach(function (form) {
    var scope = form.parentElement;
    var success = scope.querySelector('[data-form-success]');
    var title = success && success.querySelector('[data-success-title]');
    var text = success && success.querySelector('[data-success-text]');
    var link = success && success.querySelector('[data-success-link]');
    var error = form.querySelector('[data-form-error]');
    var submit = form.querySelector('[type="submit"]');

    function showSuccess(viaWhatsApp, message) {
      if (viaWhatsApp) {
        title.textContent = T.devisWaTitre;
        text.textContent = T.devisWaTexte;
        link.href = whatsappUrl(message);
        link.hidden = false;
      } else {
        title.textContent = T.devisOkTitre;
        text.textContent = T.devisOkTexte;
        link.hidden = true;
      }
      form.hidden = true;
      success.hidden = false;
      success.focus();
    }

    form.addEventListener('submit', function (e) {
      e.preventDefault();
      if (field(form, '_gotcha')) return;
      if (error) error.hidden = true;

      var lines = [T.devis, ''];
      ['nom', 'entreprise', 'email', 'telephone', 'corridor', 'type_envoi', 'besoin'].forEach(function (name) {
        var value = field(form, name);
        if (value) lines.push(T.champs[name] + ' : ' + value);
      });
      if (LANGUE === 'en' || LANGUE === 'es') {
        lines = lines.map(function (l) { return l.replace(' : ', ': '); });
      }
      var message = lines.join('\n');

      if (!CONFIG.formEndpoint) {
        openWhatsApp(message);
        showSuccess(true, message);
        return;
      }
      submit.disabled = true;
      sendToEndpoint(form, 'Demande de devis — ' + field(form, 'nom')).then(function () {
        showSuccess(false);
      }, function () {
        if (error) error.hidden = false;
      }).then(function () {
        submit.disabled = false;
      });
    });

    scope.querySelectorAll('[data-action="form-reset"]').forEach(function (btn) {
      btn.addEventListener('click', function () {
        form.reset();
        success.hidden = true;
        form.hidden = false;
        var first = form.querySelector('input:not(.gs-hp)');
        if (first) first.focus();
      });
    });
  });

  /* ---- Inscription aux conseils (page Blog) -------------------------------- */
  document.querySelectorAll('form[data-form="newsletter"]').forEach(function (form) {
    var note = form.querySelector('[data-form-note]');
    form.addEventListener('submit', function (e) {
      e.preventDefault();
      if (field(form, '_gotcha')) return;
      var email = field(form, 'email');

      function done(msg) {
        Array.prototype.forEach.call(form.children, function (el) {
          if (el !== note) el.hidden = true;
        });
        note.textContent = msg;
        note.hidden = false;
      }

      if (!CONFIG.formEndpoint) {
        openWhatsApp(T.lettre + email);
        done(T.lettreWa);
        return;
      }
      sendToEndpoint(form, 'Inscription aux conseils — ' + email).then(function () {
        done(T.lettreOk);
      }, function () {
        note.textContent = T.lettreErreur;
        note.hidden = false;
      });
    });
  });

  /* ---- Animations -----------------------------------------------------------
     Discrètes et cohérentes : les sections apparaissent au défilement, les
     éléments flottants se décalent légèrement (parallaxe), un halo suit la
     souris sur les bandeaux sombres et les boutons principaux s'attirent vers
     le curseur. Rien ne bouge si le visiteur a demandé à réduire les animations. */
  function media(requete) {
    return window.matchMedia ? window.matchMedia(requete) : { matches: false };
  }
  var mouvementReduit = media('(prefers-reduced-motion: reduce)').matches;
  var souris = media('(hover: hover) and (pointer: fine)').matches;

  // En-tête : ombre plus marquée dès que la page défile
  if (header) {
    var defile = null;
    var majEntete = function () {
      var d = window.scrollY > 8;
      if (d !== defile) { defile = d; header.classList.toggle('is-scrolled', d); }
    };
    majEntete();
    window.addEventListener('scroll', majEntete, { passive: true });
  }

  // Apparition au défilement : titres de section, colonnes et cartes
  function initApparitions() {
    var main = document.querySelector('main');
    if (!main || !('IntersectionObserver' in window)) return;
    var cibles = [];
    var marque = function (el) { return cibles.indexOf(el) >= 0; };
    var dansCible = function (el) {
      for (var p = el.parentElement; p && p !== main; p = p.parentElement) if (marque(p)) return true;
      return false;
    };
    var enfants = function (el) {
      return Array.prototype.filter.call(el.children, function (c) {
        return !/^(BR|SCRIPT|TEMPLATE|STYLE|INPUT)$/.test(c.tagName) && !c.hidden &&
          !c.hasAttribute('data-parallax') && getComputedStyle(c).position !== 'absolute';
      });
    };
    var ajouter = function (el) { if (!marque(el) && !dansCible(el)) cibles.push(el); };

    Array.prototype.forEach.call(main.children, function (bloc) {
      if (bloc.id === 'top' || bloc.hasAttribute('data-no-reveal') || /^(TEMPLATE|SCRIPT)$/.test(bloc.tagName)) return;
      // Grilles : chaque colonne ou carte
      bloc.querySelectorAll('[style*="display:grid"]').forEach(function (grille) {
        if (marque(grille) || dansCible(grille)) return;
        var k = enfants(grille);
        if (k.length >= 2 && k.length <= 24) k.forEach(ajouter);
      });
      // Titres de section, avec leur surtitre, leur texte et leurs boutons
      bloc.querySelectorAll('h2').forEach(function (titre) {
        if (dansCible(titre)) return;
        var groupe = titre.parentElement;
        var k = enfants(groupe);
        if (k.length <= 2 && groupe !== bloc && enfants(groupe.parentElement).length <= 4) {
          groupe = groupe.parentElement;
          k = enfants(groupe);
        }
        if (k.length <= 8) k.forEach(ajouter);
      });
    });

    var observateur = new IntersectionObserver(function (entrees) {
      var visibles = entrees.filter(function (e) { return e.isIntersecting; }).map(function (e) { return e.target; });
      visibles.sort(function (a, b) { return a.compareDocumentPosition(b) & 4 ? -1 : 1; });
      visibles.forEach(function (el, i) {
        observateur.unobserve(el);
        el.style.setProperty('--gs-delai', Math.min(i * 90, 450) + 'ms');
        el.classList.add('gs-reveal--in');
        el.addEventListener('animationend', function fin(ev) {
          if (ev.target !== el) return;
          el.removeEventListener('animationend', fin);
          el.classList.remove('gs-reveal', 'gs-reveal--in');
          el.style.removeProperty('--gs-delai');
        });
      });
    }, { rootMargin: '0px 0px -10% 0px' });

    // Ce qui est déjà à l'écran au chargement reste en place (aucun clignotement)
    var hauteur = window.innerHeight;
    cibles.forEach(function (el) {
      var r = el.getBoundingClientRect();
      if (r.top < hauteur * 0.92 && r.bottom > 0) return;
      el.classList.add('gs-reveal');
      observateur.observe(el);
    });
  }

  // Parallaxe : photo de fond des bandeaux et éléments flottants [data-parallax]
  function initParallaxe() {
    var elements = [];
    var fond = document.querySelector('main > section#top > img:first-child');
    if (fond) elements.push({ el: fond, zone: fond.parentElement, vitesse: 0.22, fond: true });
    document.querySelectorAll('[data-parallax]').forEach(function (el) {
      elements.push({ el: el, zone: el.parentElement, vitesse: parseFloat(el.getAttribute('data-parallax')) || 0 });
    });
    if (!elements.length) return;
    var ecranLarge = media('(min-width: 768px)');
    var prevu = false;
    var maj = function () {
      prevu = false;
      var h = window.innerHeight;
      elements.forEach(function (it) {
        if (!ecranLarge.matches) {
          if (it.actif) { it.el.style.translate = ''; it.actif = false; }
          return;
        }
        var r = it.zone.getBoundingClientRect();
        if (r.bottom < -200 || r.top > h + 200) return;
        var y = it.fond ? Math.max(0, -r.top) * it.vitesse : -(r.top + r.height / 2 - h / 2) * it.vitesse;
        it.el.style.translate = '0 ' + y.toFixed(1) + 'px';
        it.actif = true;
      });
    };
    var demander = function () {
      if (!prevu) { prevu = true; requestAnimationFrame(maj); }
    };
    window.addEventListener('scroll', demander, { passive: true });
    window.addEventListener('resize', demander);
    maj();
  }

  // Halo orange qui suit la souris sur les bandeaux sombres
  function initHalo() {
    document.querySelectorAll('main > section#top, .gs-espace-tete, .gs-carte-auth__tete').forEach(function (zone) {
      var x = 0, y = 0, prevu = false;
      zone.classList.add('gs-halo');
      zone.addEventListener('pointermove', function (e) {
        var r = zone.getBoundingClientRect();
        x = e.clientX - r.left;
        y = e.clientY - r.top;
        if (prevu) return;
        prevu = true;
        requestAnimationFrame(function () {
          prevu = false;
          zone.style.setProperty('--gs-x', x + 'px');
          zone.style.setProperty('--gs-y', y + 'px');
        });
      }, { passive: true });
      zone.addEventListener('pointerenter', function () { zone.classList.add('gs-halo--actif'); });
      zone.addEventListener('pointerleave', function () { zone.classList.remove('gs-halo--actif'); });
    });
  }

  // Boutons principaux légèrement « aimantés » par le curseur
  function initAimant() {
    document.querySelectorAll('.hv-fill-cta-lift, .gs-cta').forEach(function (el) {
      el.addEventListener('pointermove', function (e) {
        if (e.pointerType && e.pointerType !== 'mouse') return;
        var r = el.getBoundingClientRect();
        var dx = (e.clientX - r.left) / r.width - 0.5;
        var dy = (e.clientY - r.top) / r.height - 0.5;
        el.style.translate = (dx * 10).toFixed(1) + 'px ' + (dy * 6).toFixed(1) + 'px';
      });
      el.addEventListener('pointerleave', function () { el.style.translate = ''; });
    });
  }

  if (!mouvementReduit) {
    initApparitions();
    initParallaxe();
    if (souris) {
      initHalo();
      initAimant();
    }
  }
})();
