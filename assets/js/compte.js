/* ==========================================================================
   Goship Express — espace client
   Inscription, connexion, mot de passe oublié, et page « Mon compte » :
   code client, adresse en Floride et suivi des colis en temps réel.
   Les textes affichés viennent de la page (<template data-textes>), traduite
   comme le reste du site.
   ========================================================================== */
(function () {
  'use strict';

  var API = window.GoshipAPI;
  if (!API) return;
  var O = API.outils;
  var t = O.texte;
  var REGLAGES = window.GOSHIP_CONFIG || {};
  var WHATSAPP = String(REGLAGES.whatsapp || '18495386262').replace(/\D/g, '');

  function $(sel, scope) { return (scope || document).querySelector(sel); }
  function $$(sel, scope) { return Array.prototype.slice.call((scope || document).querySelectorAll(sel)); }
  function waUrl(message) { return 'https://wa.me/' + WHATSAPP + '?text=' + encodeURIComponent(message); }

  /* ---- Le code d'un parrain, gardé sur l'appareil (jamais une donnée sensible) ------------ */
  var CLE_PARRAIN = 'gse-parrain';
  function garderParrain(code) {
    try { if (code) localStorage.setItem(CLE_PARRAIN, code); else localStorage.removeItem(CLE_PARRAIN); } catch (e) { /* stockage bloqué : le champ suffit */ }
  }
  function lireParrain() {
    try { return localStorage.getItem(CLE_PARRAIN) || ''; } catch (e) { return ''; }
  }

  /* ---- Régions et villes : assets/js/lieux.js, chargé avant cette page ---------- */
  var LIEUX = window.GoshipLieux || { REGIONS: {}, ETATS_US: [] };
  var REGIONS = LIEUX.REGIONS;
  var ETATS_US = LIEUX.ETATS_US;
  var TELEPHONE_EXEMPLE = { HT: '+509 3712 3456', DO: '+1 809 555 0147', US: '+1 305 555 0147' };
  var AUTRE = '__autre';

  function trier(liste) {
    return liste.slice().sort(function (a, b) { return a.localeCompare(b, 'fr'); });
  }

  // Pays -> région -> ville (liste des communes, ou saisie libre)
  function initLieu(form) {
    var pays = $('[data-pays]', form);
    var region = $('[data-region]', form);
    var ville = $('[data-ville]', form);
    var autre = $('[data-ville-autre]', form);
    var tel = $('[type="tel"]', form);
    if (!pays || !region || !ville || !autre) return null;

    function options(select, liste, invite) {
      select.textContent = '';
      select.add(new Option(invite, ''));
      liste.forEach(function (v) { select.add(new Option(v, v)); });
    }
    function majRegions(valeur) {
      var p = pays.value;
      var liste = p === 'US' ? ETATS_US : (REGIONS[p] ? Object.keys(REGIONS[p]) : []);
      options(region, liste, t(p ? 'region-choisir' : 'region-pays'));
      region.disabled = !p;
      if (valeur && liste.indexOf(valeur) >= 0) region.value = valeur;
      if (tel) tel.placeholder = TELEPHONE_EXEMPLE[p] || tel.getAttribute('data-invite') || tel.placeholder;
    }
    // Haïti et République dominicaine : liste des communes (+ « Autre ville… ») ;
    // États-Unis : saisie libre.
    function majVilles(valeur) {
      var p = pays.value;
      var communes = REGIONS[p] && REGIONS[p][region.value];
      options(ville, communes ? trier(communes) : [], t('ville-choisir'));
      if (communes) ville.add(new Option(t('ville-autre'), AUTRE));
      ville.hidden = p === 'US';
      ville.disabled = !communes;
      if (valeur) {
        if (communes && communes.indexOf(valeur) >= 0) ville.value = valeur;
        else if (communes) { ville.value = AUTRE; autre.value = valeur; }
        else if (p === 'US') autre.value = valeur;
      }
      majAutre();
    }
    function majAutre() {
      var libre = pays.value === 'US' || ville.value === AUTRE;
      autre.hidden = !libre;
      autre.disabled = !libre;
      if (etiquette) etiquette.htmlFor = pays.value === 'US' ? autre.id : ville.id;
    }

    var etiquette = ville.id ? $('label[for="' + ville.id + '"]', form) : null;
    if (!autre.id) autre.id = (ville.id || 'ville') + '-libre';
    if (tel && !tel.getAttribute('data-invite')) tel.setAttribute('data-invite', tel.placeholder);
    pays.addEventListener('change', function () { majRegions(); majVilles(); });
    region.addEventListener('change', function () { majVilles(); });
    ville.addEventListener('change', function () {
      majAutre();
      if (ville.value === AUTRE) autre.focus();
    });
    majRegions();
    majVilles();

    return {
      valeurs: function () {
        var libre = !autre.disabled;
        return { pays: pays.value, region: region.value, ville: (libre ? autre.value : ville.value).trim() };
      },
      remplir: function (p, r, v) {
        pays.value = p || '';
        majRegions(r || '');
        majVilles(v || '');
      }
    };
  }

  /* ---- Formulaires : validation, attente, erreurs ------------------------------- */
  function erreurChamp(champ, message) {
    var bloc = champ.closest('.gs-champ');
    if (!bloc) return;
    var msg = bloc.querySelector('.gs-champ__message');
    if (message) {
      bloc.classList.add('is-invalide');
      champ.setAttribute('aria-invalid', 'true');
      if (!msg) {
        msg = document.createElement('p');
        msg.className = 'gs-champ__message';
        msg.id = 'erreur-' + (champ.id || champ.name);
        bloc.appendChild(msg);
        champ.setAttribute('aria-describedby', ((champ.getAttribute('aria-describedby') || '') + ' ' + msg.id).trim());
      }
      msg.textContent = message;
    } else {
      bloc.classList.remove('is-invalide');
      champ.removeAttribute('aria-invalid');
      if (msg) {
        champ.setAttribute('aria-describedby', (champ.getAttribute('aria-describedby') || '').replace(msg.id, '').trim());
        if (!champ.getAttribute('aria-describedby')) champ.removeAttribute('aria-describedby');
        msg.remove();
      }
    }
  }

  /* ---- Date de naissance : un jour civil « AAAA-MM-JJ », sans fuseau ------------------ */
  // Le jour d'aujourd'hui de l'appareil, écrit à la main : toISOString() donnerait celui d'UTC.
  function aujourdhuiLocal() {
    var n = new Date();
    return n.getFullYear() + '-' + ('0' + (n.getMonth() + 1)).slice(-2) + '-' + ('0' + n.getDate()).slice(-2);
  }

  // Vide si la date est bonne, sinon la clé du message. La base refait toujours ce contrôle.
  function messageNaissance(v) {
    var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(v);
    if (!m) return 'champ-naissance';
    var a = +m[1], mo = +m[2], j = +m[3], u = new Date(Date.UTC(a, mo - 1, j));
    if (u.getUTCFullYear() !== a || u.getUTCMonth() !== mo - 1 || u.getUTCDate() !== j || a < 1900) return 'champ-naissance';
    if (v > aujourdhuiLocal()) return 'champ-naissance-futur';
    return '';
  }

  // Un jour civil lisible dans la langue de la page, sans jamais passer par le fuseau de l'appareil
  function jourCivil(v) {
    var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(v || '');
    if (!m) return '';
    try {
      return new Intl.DateTimeFormat(API.langue || 'fr', { timeZone: 'UTC', day: 'numeric', month: 'long', year: 'numeric' })
        .format(new Date(Date.UTC(+m[1], +m[2] - 1, +m[3])));
    } catch (e) { return v; }
  }

  // Le champ date ne laisse pas choisir demain : l'attribut max est le jour de l'appareil
  $$('input[data-naissance]').forEach(function (c) { c.max = aujourdhuiLocal(); });

  function verifierChamp(champ) {
    if (champ.disabled || champ.hidden || champ.classList.contains('gs-hp')) return true;
    var v = String(champ.value || '').trim();
    var message = '';
    if (champ.required && !v) message = t('champ-requis');
    else if (champ.type === 'email' && !/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(v)) message = t('champ-email');
    else if (/^mot_de_passe$/.test(champ.name) && champ.minLength > 0 && champ.value.length < champ.minLength) message = t('champ-mdp');
    else if (champ.type === 'tel' && v.replace(/\D/g, '').length < 7) message = t('champ-tel');
    else if (champ.name === 'nom_complet' && v.split(/\s+/).length < 2) message = t('champ-nom');
    else if (champ.name === 'date_naissance' && v && messageNaissance(v)) message = t(messageNaissance(v));
    erreurChamp(champ, message);
    return !message;
  }

  function verifierFormulaire(form) {
    var premier = null;
    $$('input, select, textarea', form).forEach(function (c) {
      if (/^(hidden|checkbox|radio|submit|button)$/.test(c.type)) return;
      if (!verifierChamp(c) && !premier) premier = c;
    });
    if (premier) premier.focus();
    return !premier;
  }

  function surModification(e) {
    var c = e.target;
    if (c.closest && c.closest('.gs-champ.is-invalide')) verifierChamp(c);
  }
  document.addEventListener('input', surModification);
  document.addEventListener('change', surModification);

  function montrerErreur(form, erreur) {
    var zone = $('[data-form-erreur]', form);
    if (!zone) return;
    var code = erreur && erreur.code ? erreur.code : 'inconnu';
    zone.textContent = t('erreur-' + code) || t('erreur-inconnu');
    zone.hidden = false;
  }

  function cacherErreur(form) {
    var zone = $('[data-form-erreur]', form);
    if (zone) zone.hidden = true;
  }

  function attente(form, cle) {
    var b = $('[data-envoyer]', form);
    if (!b) return;
    if (!b.hasAttribute('data-libelle')) b.setAttribute('data-libelle', b.textContent);
    if (cle) {
      b.disabled = true;
      b.setAttribute('aria-busy', 'true');
      b.textContent = '';
      var roue = document.createElement('span');
      roue.className = 'gs-roue';
      roue.setAttribute('aria-hidden', 'true');
      b.appendChild(roue);
      b.appendChild(document.createTextNode(t(cle)));
    } else {
      b.disabled = false;
      b.removeAttribute('aria-busy');
      b.textContent = b.getAttribute('data-libelle');
    }
  }

  // Seules les pages du site peuvent servir de destination après connexion
  function destination(defaut) {
    var m = /[?&]retour=([a-z0-9-]+\.html)/.exec(location.search);
    return m ? m[1] : defaut;
  }

  function annoncerSession() {
    var ev;
    try { ev = new Event('goship:session'); } catch (e) { ev = document.createEvent('Event'); ev.initEvent('goship:session', true, true); }
    document.dispatchEvent(ev);
  }

  /* ---- Éléments communs ----------------------------------------------------- */
  $$('[data-lien-wa]').forEach(function (a) {
    a.href = waUrl(t(a.getAttribute('data-lien-wa'), { code: '', numero: '' }).replace(/\s+\./, '.'));
  });

  $$('[data-action="voir-mdp"]').forEach(function (bouton) {
    var champ = bouton.parentElement.querySelector('input');
    bouton.addEventListener('click', function () {
      var visible = champ.type === 'password';
      champ.type = visible ? 'text' : 'password';
      bouton.setAttribute('aria-pressed', String(visible));
      bouton.setAttribute('aria-label', t(visible ? 'mdp-masquer' : 'mdp-afficher'));
      champ.focus();
    });
  });

  // Mode démonstration (ordinateur local, Supabase pas encore configuré)
  if (API.mode === 'demo') {
    var corps = $('.gs-carte-auth__corps') || $('.gs-espace__wrap');
    if (corps) {
      var bandeau = document.createElement('p');
      bandeau.className = 'gs-alerte gs-alerte--info gs-demo';
      bandeau.textContent = t('demo-bandeau');
      corps.insertBefore(bandeau, corps.firstChild);
    }
  }

  // Espace client fermé (site en ligne, Supabase pas encore configuré)
  if (API.mode === 'off') {
    $$('[data-espace-ferme]').forEach(function (el) { el.hidden = false; });
    $$('form[data-form], [data-methode]').forEach(function (el) { el.hidden = true; });
    if ($('[data-liste-colis]') || $('form[data-form="nouveau-mdp"]')) location.replace('connexion.html');
    return;
  }

  /* ---- Continuer avec Google (connexion et inscription) -------------------- */
  // Le bouton n'apparaît que si Supabase a activé le fournisseur. Google renvoie
  // toujours sur connexion.html : avec la session dans l'adresse, la page mène à
  // « Mon compte » comme après un mot de passe ; avec une erreur, elle la dit ici.
  var social = $('[data-social]');
  if (social) {
    var erreurSociale = $('[data-social-erreur]', social);
    var retourSocial = function () {
      var m = /[?&]retour=([a-z0-9-]+\.html)/.exec(location.search);
      return 'connexion.html' + (m ? '?retour=' + m[1] : '');
    };
    var direErreurSociale = function (cle) {
      erreurSociale.textContent = t(cle) || t('erreur-inconnu');
      erreurSociale.hidden = false;
      social.hidden = false;
    };

    // Retour du fournisseur avec une erreur (?error=… ou #error=…) : on la dit, et
    // on l'efface de l'adresse (on garde seulement ?retour=).
    var parametres = (location.search.slice(1) + '&' + location.hash.slice(1)).split('&');
    var erreurRetour = null;
    parametres.forEach(function (p) {
      var cle = p.split('=')[0];
      if (cle === 'error' && !erreurRetour) erreurRetour = decodeURIComponent(p.split('=')[1] || '');
    });
    if (erreurRetour) {
      direErreurSociale(erreurRetour === 'access_denied' ? 'erreur-social-annule' : 'erreur-social-echec');
      try { history.replaceState(null, '', location.pathname + retourSocial().replace('connexion.html', '')); } catch (e) {}
    }

    API.fournisseursConnexion().then(function (actifs) {
      $$('[data-fournisseur]', social).forEach(function (b) {
        b.hidden = actifs.indexOf(b.getAttribute('data-fournisseur')) < 0;
      });
      if (actifs.length) social.hidden = false;
    });

    $$('[data-action="connexion-sociale"]', social).forEach(function (bouton) {
      bouton.addEventListener('click', function () {
        erreurSociale.hidden = true;
        bouton.disabled = true;
        bouton.setAttribute('aria-busy', 'true');
        API.connecterAvec(bouton.getAttribute('data-fournisseur'), retourSocial()).catch(function (err) {
          bouton.disabled = false;
          bouton.removeAttribute('aria-busy');
          direErreurSociale('erreur-' + err.code);
        });
      });
    });
  }

  /* ---- Inscription ---------------------------------------------------------- */
  var formInscription = $('form[data-form="inscription"]');
  if (formInscription) {
    var lieuInscription = initLieu(formInscription);
    var boutonMethodes = $('[data-action="methodes"]');

    var voirMethodes = function (liste) {
      $('[data-methode-choisie]').hidden = liste;
      $('[data-methode-liste]').hidden = !liste;
      $('[data-methode-texte="formulaire"]').hidden = liste;
      $('[data-methode-texte="choix"]').hidden = !liste;
      formInscription.hidden = liste;
      boutonMethodes.setAttribute('aria-expanded', String(liste));
    };
    boutonMethodes.addEventListener('click', function () {
      voirMethodes(true);
      $('[data-action="methode-formulaire"]').focus();
    });
    $('[data-action="methode-formulaire"]').addEventListener('click', function () {
      voirMethodes(false);
      formInscription.elements.nom_complet.focus();
    });

    // Un lien de parrainage (« ?parrain=CODE ») remplit le champ ; le code est aussi gardé sur l'appareil,
    // pour un compte ouvert avec Google (qui n'a pas ce champ) : il sera saisi à l'arrivée dans l'espace client.
    var champParrain = formInscription.elements.code_parrainage;
    var venuDuLien = /[?&]parrain=([A-Za-z0-9]{4,24})/.exec(location.search);
    if (venuDuLien) garderParrain(venuDuLien[1].toUpperCase());
    if (champParrain) champParrain.value = lireParrain();

    // Déjà connecté : direction l'espace client
    API.session().then(function (s) { if (s) location.replace('mon-compte.html'); }, function () {});

    formInscription.addEventListener('submit', function (e) {
      e.preventDefault();
      if (formInscription.elements._gotcha.value) return;
      cacherErreur(formInscription);
      if (!verifierFormulaire(formInscription)) return;
      var f = formInscription.elements;
      var lieu = lieuInscription.valeurs();
      var donnees = {
        nom_complet: f.nom_complet.value.trim().replace(/\s+/g, ' '),
        pays: lieu.pays, region: lieu.region, ville: lieu.ville,
        adresse: f.adresse.value.trim(),
        telephone: f.telephone.value.trim(),
        date_naissance: f.date_naissance.value,
        code_parrainage: f.code_parrainage ? f.code_parrainage.value.trim().toUpperCase() : '',
        email: f.email.value.trim().toLowerCase(),
        motDePasse: f.mot_de_passe.value
      };
      attente(formInscription, 'attente-inscription');
      API.inscrire(donnees).then(function (r) {
        if (r.confirmation) {
          attente(formInscription);
          formInscription.hidden = true;
          $('[data-methode]').hidden = true;
          var boite = $('[data-confirmation]');
          $('[data-confirmation-texte]', boite).textContent = t('confirmation-email', { email: donnees.email });
          boite.hidden = false;
          boite.focus();
          return;
        }
        annoncerSession();
        // Le code est entré dans le compte par la base ; inutile de le rejouer ensuite
        if (donnees.code_parrainage) garderParrain('');
        location.href = 'mon-compte.html?bienvenue=1';
      }).catch(function (err) {
        attente(formInscription);
        montrerErreur(formInscription, err);
        if (/^naissance-/.test(err.code) || err.code === 'inscription-refusee') f.date_naissance.focus();
        else if (err.code === 'email-existe' || err.code === 'email-invalide') f.email.focus();
        else if (err.code === 'mot-de-passe-faible') f.mot_de_passe.focus();
      });
    });
  }

  /* ---- Connexion et mot de passe oublié ------------------------------------- */
  var formConnexion = $('form[data-form="connexion"]');
  var formOubli = $('form[data-form="oubli"]');
  if (formConnexion && formOubli) {
    var voirOubli = function (oui) {
      formConnexion.hidden = oui;
      formOubli.hidden = !oui;
      if (oui) {
        if (!formOubli.elements.email.value) formOubli.elements.email.value = formConnexion.elements.email.value;
        formOubli.elements.email.focus();
      } else {
        formConnexion.elements.email.focus();
      }
    };
    $('[data-action="oubli"]').addEventListener('click', function (e) {
      e.preventDefault();
      voirOubli(true);
      history.replaceState(null, '', '#oubli');
    });
    $('[data-action="retour-connexion"]').addEventListener('click', function () {
      voirOubli(false);
      history.replaceState(null, '', location.pathname + location.search);
    });
    if (location.hash === '#oubli') voirOubli(true);

    API.session().then(function (s) { if (s && location.hash !== '#oubli') location.replace(destination('mon-compte.html')); }, function () {});

    formConnexion.addEventListener('submit', function (e) {
      e.preventDefault();
      cacherErreur(formConnexion);
      if (!verifierFormulaire(formConnexion)) return;
      attente(formConnexion, 'attente-connexion');
      API.connecter(formConnexion.elements.email.value.trim().toLowerCase(), formConnexion.elements.mot_de_passe.value)
        .then(function (profil) {
          annoncerSession();
          // Un compte de l'équipe (employé, gérant, administrateur) va au tableau de bord
          var admin = !!profil && API.regles.rolesEquipe.indexOf(profil.role) >= 0;
          location.href = admin && !/[?&]retour=/.test(location.search) ? 'admin.html' : destination('mon-compte.html');
        })
        .catch(function (err) {
          attente(formConnexion);
          montrerErreur(formConnexion, err);
          formConnexion.elements.mot_de_passe.select();
        });
    });

    formOubli.addEventListener('submit', function (e) {
      e.preventDefault();
      cacherErreur(formOubli);
      $('[data-oubli-ok]', formOubli).hidden = true;
      if (!verifierFormulaire(formOubli)) return;
      attente(formOubli, 'attente-envoi');
      API.envoyerLienMotDePasse(formOubli.elements.email.value.trim().toLowerCase()).then(function (r) {
        attente(formOubli);
        var ok = $('[data-oubli-ok]', formOubli);
        var demo = $('[data-oubli-demo]', ok);
        demo.hidden = !(r && r.lienDemo);
        if (r && r.lienDemo) {
          demo.textContent = t('demo-lien') + ' ';
          var lien = document.createElement('a');
          lien.href = r.lienDemo;
          lien.textContent = 'nouveau-mot-de-passe.html';
          demo.appendChild(lien);
        }
        ok.hidden = false;
      }).catch(function (err) {
        attente(formOubli);
        montrerErreur(formOubli, err);
      });
    });
  }

  /* ---- Nouveau mot de passe -------------------------------------------------- */
  var formMdp = $('form[data-form="nouveau-mdp"]');
  if (formMdp) {
    API.attendreRecuperation().then(function (valide) {
      $('[data-attente]').hidden = true;
      if (!valide) { $('[data-lien-invalide]').hidden = false; return; }
      formMdp.hidden = false;
      formMdp.elements.mot_de_passe.focus();
    }, function () {
      $('[data-attente]').hidden = true;
      $('[data-lien-invalide]').hidden = false;
    });

    formMdp.addEventListener('submit', function (e) {
      e.preventDefault();
      cacherErreur(formMdp);
      if (!verifierFormulaire(formMdp)) return;
      var mdp = formMdp.elements.mot_de_passe.value;
      if (formMdp.elements.confirmation.value !== mdp) {
        erreurChamp(formMdp.elements.confirmation, t('champ-confirmation'));
        formMdp.elements.confirmation.focus();
        return;
      }
      attente(formMdp, 'attente-enregistrement');
      API.changerMotDePasse(mdp).then(function () {
        formMdp.hidden = true;
        var ok = $('[data-mdp-ok]');
        ok.hidden = false;
        ok.focus();
        setTimeout(function () { location.href = 'mon-compte.html'; }, 2200);
      }).catch(function (err) {
        attente(formMdp);
        montrerErreur(formMdp, err);
      });
    });
  }

  /* ---- Mon compte ---------------------------------------------------------------- */
  var liste = $('[data-liste-colis]');
  if (liste) {
    var profil = null;
    var colis = [];
    var dejaVus = {};
    var onglet = 'en-cours';
    var modele = $('template[data-modele="colis"]');

    var nomPays = function (code) { return t('pays-' + code) || code || ''; };

    var afficherProfil = function () {
      var prenom = (profil.nom_complet || '').trim().split(/\s+/)[0] || '';
      $('[data-prenom]').textContent = prenom ? ', ' + prenom : '';
      $$('[data-code]').forEach(function (el) { el.textContent = profil.code || '—'; });
      // Le nom et le code viennent du compte connecté, jamais d'ailleurs. Sans l'un des deux,
      // l'adresse serait fausse (les colis ne seraient pas reconnus) : on n'en compose pas, on le dit.
      var nomPropre = (profil.nom_complet || '').trim();
      var adresseComplete = !!nomPropre && !!profil.code;
      var tableAdresse = $('[data-address-table]');
      $('[data-nom-adresse]').textContent = adresseComplete ? nomPropre + ' ' + profil.code : '';
      if (adresseComplete) tableAdresse.removeAttribute('data-incomplet'); else tableAdresse.setAttribute('data-incomplet', '');
      var noteAdresse = $('[data-adresse-manquante]');
      noteAdresse.hidden = adresseComplete;
      noteAdresse.textContent = adresseComplete ? '' : t('adresse-manquante');
      var infos = {
        nom_complet: profil.nom_complet, email: profil.email, telephone: profil.telephone, adresse: profil.adresse,
        lieu: [profil.ville, profil.region, nomPays(profil.pays)].filter(Boolean).join(', ')
      };
      Object.keys(infos).forEach(function (k) {
        var dd = $('[data-info="' + k + '"]');
        if (dd) dd.textContent = infos[k] || '—';
      });
      $$('[data-lien-wa="wa-aide"]').forEach(function (a) { a.href = waUrl(t('wa-aide', { code: profil.code || '' })); });
      // Compte ouvert avec Google : ni pays, ni ville, ni téléphone. On les demande.
      var incomplet = !profil.nom_complet || !profil.pays || !profil.ville || !profil.telephone;
      $('[data-completer]').hidden = !incomplet || API.regles.rolesEquipe.indexOf(profil.role) >= 0;
      if (API.regles.rolesEquipe.indexOf(profil.role) >= 0 && !$('[data-avis-admin]')) {
        var avis = document.createElement('p');
        avis.className = 'gs-alerte gs-alerte--info';
        avis.setAttribute('data-avis-admin', '');
        avis.style.marginBottom = '20px';
        avis.textContent = t('admin-avis') + ' ';
        var lien = document.createElement('a');
        lien.href = 'admin.html';
        lien.textContent = t('admin-lien');
        avis.appendChild(lien);
        $('.gs-espace__wrap').insertBefore(avis, $('.gs-espace__grille'));
      }
    };

    var champ = function (racine, nom) { return racine.querySelector('[data-champ="' + nom + '"]'); };

    var carte = function (c) {
      var fragment = document.importNode(modele.content, true);
      var article = fragment.querySelector('.gs-colis');
      article.setAttribute('data-id', c.id);
      champ(article, 'numero').textContent = c.numero;
      champ(article, 'description').textContent = c.description || '';
      var badge = champ(article, 'statut');
      badge.textContent = t('statut-' + c.statut);
      badge.className = 'gs-badge gs-badge--' + c.statut;
      champ(article, 'recu').textContent = t('recu-le', { date: O.date(c.recu_le || c.cree_le, true) });
      champ(article, 'expediteur').textContent = c.expediteur ? t('expediteur', { nom: c.expediteur }) : '';
      champ(article, 'service').textContent = t('service-' + c.service);
      champ(article, 'poids').textContent = c.poids_lb != null && c.poids_lb !== '' ? O.nombre(Number(c.poids_lb)) + ' lb' : '';
      champ(article, 'destination').textContent = [c.destination, nomPays(c.pays_destination)].filter(Boolean).join(', ');
      champ(article, 'suivi').textContent = c.suivi_transporteur ? t('suivi-vendeur', { numero: c.suivi_transporteur }) : '';
      O.remplirEtapes(champ(article, 'etapes'), c.statut, c.historique);
      if (c.note) {
        var note = champ(article, 'note');
        note.textContent = c.note;
        note.hidden = false;
      }
      champ(article, 'maj').textContent = t('maj', { date: O.date(c.maj_le, true) });
      var n = (c.historique || []).length;
      champ(article, 'nb-etapes').textContent = '(' + (n === 1 ? t('etape-une') : t('etapes', { n: n })) + ')';
      O.remplirHistorique(champ(article, 'historique'), c.historique, { notes: true });
      return article;
    };

    var afficherColis = function (nouveautes) {
      var enCours = colis.filter(function (c) { return c.statut !== 'livre'; });
      var livres = colis.filter(function (c) { return c.statut === 'livre'; });
      $('[data-nombre="en-cours"]').textContent = enCours.length;
      $('[data-nombre="livres"]').textContent = livres.length;
      var ouverts = $$('.gs-colis__historique[open]', liste).map(function (d) { return d.closest('.gs-colis').getAttribute('data-id'); });
      liste.textContent = '';
      liste.removeAttribute('aria-busy');
      (onglet === 'livres' ? livres : enCours).forEach(function (c) {
        var article = carte(c);
        if (ouverts.indexOf(c.id) >= 0) article.querySelector('.gs-colis__historique').open = true;
        if (nouveautes && nouveautes.indexOf(c.id) >= 0) article.classList.add('is-maj');
        liste.appendChild(article);
      });
      $('[data-vide="en-cours"]').hidden = !(onglet === 'en-cours' && !enCours.length);
      $('[data-vide="livres"]').hidden = !(onglet === 'livres' && !livres.length);
    };

    var chargerColis = function () {
      return API.mesColis().then(function (lignes) {
        var nouveautes = [];
        lignes.forEach(function (c) {
          if (dejaVus[c.id] && dejaVus[c.id] !== c.maj_le) nouveautes.push(c.id);
          dejaVus[c.id] = c.maj_le;
        });
        colis = lignes;
        $('[data-colis-erreur]').hidden = true;
        afficherColis(nouveautes);
      }).catch(function (err) {
        if (err.code === 'non-autorise') { location.replace('connexion.html?retour=mon-compte.html'); return; }
        liste.textContent = '';
        liste.removeAttribute('aria-busy');
        var zone = $('[data-colis-erreur]');
        zone.textContent = t('erreur-' + err.code) || t('erreur-inconnu');
        zone.hidden = false;
      });
    };

    /* ---- Mes factures ------------------------------------------------------
       Le tableau de bord les crée ; le client les lit, les règle et les
       imprime. Une facture marquée payée change d'état ici sans que la page
       soit rechargée (voir API.surveiller). */
    var listeFactures = $('[data-liste-factures]');
    var modeleFacture = $('template[data-modele="facture"]');
    var factures = [];

    var carteFacture = function (f) {
      var fragment = document.importNode(modeleFacture.content, true);
      var article = fragment.querySelector('.gs-facture');
      article.setAttribute('data-id', f.id);
      champ(article, 'numero').textContent = f.numero || '';
      // Le payé, le solde et l'état viennent de la base (mes_factures) : on
      // les affiche, on ne les refait pas.
      var totaux = O.totauxFacture(f);
      var ouverte = totaux.etat === 'a_payer' || totaux.etat === 'partielle' || totaux.etat === 'en_retard';

      var dates = [t('facture-etablie', { date: O.date(f.cree_le) })];
      if (ouverte && f.echeance_le) {
        dates.push(t('facture-echeance', { date: O.date(f.echeance_le) }));
      } else if (totaux.etat === 'payee' && f.payee_le) {
        dates.push(t('facture-payee-le', { date: O.date(f.payee_le) }));
      }
      champ(article, 'date').textContent = dates.join(' · ');
      champ(article, 'montant').textContent = O.argent(totaux.grandTotal);

      var badge = champ(article, 'statut');
      badge.textContent = t('facture-' + totaux.etat);
      badge.className = 'gs-badge gs-badge--facture-' + totaux.etat;

      var lignes = champ(article, 'lignes');
      (f.lignes || []).forEach(function (l) {
        var li = document.createElement('li');
        var texte = document.createElement('span');
        texte.textContent = l.libelle || t('facture-transport');
        li.appendChild(texte);
        if (l.colis) {
          var numero = document.createElement('span');
          numero.className = 'gs-facture__colis';
          numero.setAttribute('translate', 'no');
          numero.textContent = t('facture-colis', { numero: l.colis });
          li.appendChild(numero);
        }
        // Le poids et le tarif du jour de la facture, recopiés sur la ligne
        if (l.poids_lb != null && l.tarif_lb_usd != null) {
          var calcul = document.createElement('span');
          calcul.className = 'gs-facture__colis';
          calcul.setAttribute('translate', 'no');
          calcul.textContent = O.nombre(Number(l.poids_lb)) + ' lb × ' + O.argent(l.tarif_lb_usd) + '/lb';
          li.appendChild(calcul);
        }
        var montant = document.createElement('span');
        montant.className = 'gs-facture__ligne-montant';
        montant.textContent = O.argent(l.montant_usd);
        li.appendChild(montant);
        lignes.appendChild(li);
      });
      lignes.hidden = !(f.lignes || []).length;

      // Payé et reste à payer, dès qu'un premier paiement est arrivé
      var soldes = champ(article, 'soldes');
      if (totaux.paye > 0 && totaux.etat !== 'annulee') {
        [['facture-total', totaux.grandTotal, ''], ['facture-paye', totaux.paye, ''],
         ['facture-reste', totaux.balance, 'gs-facture__reste']].forEach(function (x) {
          if (x[0] === 'facture-reste' && x[1] <= 0) return;
          var morceau = document.createElement('span');
          if (x[2]) morceau.className = x[2];
          var gras = document.createElement('strong');
          gras.setAttribute('translate', 'no');
          gras.textContent = O.argent(x[1]);
          var modele = t(x[0], { montant: '\u0000' }).split('\u0000');
          morceau.appendChild(document.createTextNode(modele[0] || ''));
          morceau.appendChild(gras);
          morceau.appendChild(document.createTextNode(modele[1] || ''));
          soldes.appendChild(morceau);
        });
        soldes.hidden = false;
      }

      // L'historique des paiements reçus
      var liste = champ(article, 'paiements');
      (f.paiements || []).forEach(function (p) {
        var li = document.createElement('li');
        var modele = t('facture-paiement', { montant: '\u0000', date: O.date(p.paye_le) }).split('\u0000');
        var gras = document.createElement('strong');
        gras.setAttribute('translate', 'no');
        gras.textContent = O.argent(p.montant_usd);
        li.appendChild(document.createTextNode(modele[0] || ''));
        li.appendChild(gras);
        li.appendChild(document.createTextNode((modele[1] || '') + (t('moyen-' + p.moyen) ? ' · ' + t('moyen-' + p.moyen) : '')));
        liste.appendChild(li);
      });
      liste.hidden = !(f.paiements || []).length || totaux.etat === 'payee' && (f.paiements || []).length < 2;

      // « Payée par PayPal » vaut mieux, sur une facture réglée, que la note
      // de relance qui l'accompagnait.
      var note = champ(article, 'note');
      var moyen = totaux.etat === 'payee' && f.moyen ? t('facture-moyen-' + f.moyen) : '';
      if (moyen || f.note) {
        note.textContent = moyen || f.note;
        note.hidden = false;
      }

      var payer = champ(article, 'payer');
      // Seules les adresses web deviennent un lien. Un « javascript: » glissé
      // dans le champ du tableau de bord ne doit pas s'exécuter ici.
      if (ouverte && /^https?:\/\//i.test(f.lien_paiement || '')) {
        payer.href = f.lien_paiement;
        payer.hidden = false;
      }
      champ(article, 'imprimer').addEventListener('click', function () {
        if (!window.GoshipImpression) return;
        window.GoshipImpression.imprimer(
          [window.GoshipImpression.facture(f, profil, { langue: API.langue })],
          { papier: 'A4', langue: API.langue, titre: (f.numero || '') + ' — Goship Express' }
        ).catch(function () { /* la fenêtre d'impression a été refusée */ });
      });
      return article;
    };

    var afficherFactures = function () {
      listeFactures.textContent = '';
      listeFactures.removeAttribute('aria-busy');
      factures.forEach(function (f) { listeFactures.appendChild(carteFacture(f)); });
      $('[data-vide="factures"]').hidden = factures.length > 0;
      // « 2 à payer » : les factures qui ont encore un solde, d'après la base
      var aPayer = factures.filter(function (f) { return O.totauxFacture(f).balance > 0; }).length;
      var total = $('[data-total-factures]');
      total.textContent = aPayer ? t('factures-total', { n: aPayer }) : '';
      total.hidden = !aPayer;
    };

    var chargerFactures = function () {
      return API.mesFactures().then(function (lignes) {
        factures = lignes || [];
        $('[data-factures-erreur]').hidden = true;
        afficherFactures();
      }).catch(function (err) {
        if (err.code === 'non-autorise') return;
        // « absent » : outils/supabase-factures.sql n'a pas encore été lancé.
        // Le panneau disparaît alors, plutôt que d'annoncer une panne au client.
        if (err.code === 'absent') {
          $('.gs-panneau--factures').hidden = true;
          return;
        }
        listeFactures.textContent = '';
        listeFactures.removeAttribute('aria-busy');
        var zone = $('[data-factures-erreur]');
        zone.textContent = t('erreur-' + err.code) || t('erreur-inconnu');
        zone.hidden = false;
      });
    };

    // Mon solde et mes messages : les chiffres de la base (mon_resume), les
    // mêmes que ceux des factures ci-dessous. Si la base n'a pas encore cette
    // fonction, les deux cadres restent cachés : rien d'inventé.
    var chargerResume = function () {
      return API.monResume().then(function (r) {
        var f = r && r.factures;
        var solde = $('[data-solde]');
        var note = $('[data-solde-note]');
        solde.hidden = !(f && f.nombre);
        note.hidden = true;
        if (f && f.nombre) {
          $('[data-solde-champ="facture"]').textContent = O.argent(f.facture_usd);
          $('[data-solde-champ="paye"]').textContent = O.argent(f.paye_usd);
          $('[data-solde-champ="solde"]').textContent = O.argent(f.solde_usd);
          solde.classList.toggle('is-a-jour', !(Number(f.solde_usd) > 0));
          var phrases = [];
          if (Number(f.montant_en_retard) > 0) phrases.push(t('solde-retard', { montant: O.argent(f.montant_en_retard) }));
          if (f.prochaine_echeance) phrases.push(t('solde-echeance', { date: O.date(f.prochaine_echeance + 'T12:00:00') }));
          note.textContent = phrases.join(' ');
          note.hidden = !phrases.length;
        }
        var panneau = $('[data-panneau-messages]');
        var messages = (r && r.notifications) || null;
        panneau.hidden = !messages;
        if (!messages) return;
        var liste = $('[data-messages]');
        liste.textContent = '';
        messages.forEach(function (m) {
          var li = document.createElement('li');
          li.className = 'gs-messages__ligne';
          var quoi = document.createElement('strong');
          quoi.textContent = t('message-' + m.evenement) || t('statut-' + m.evenement) || t('message-autre');
          li.appendChild(quoi);
          var details = document.createElement('span');
          details.textContent = [t('canal-' + m.canal) || m.canal, m.numero, O.date(m.envoye_le, true)].filter(Boolean).join(' · ');
          li.appendChild(details);
          liste.appendChild(li);
        });
        $('[data-messages-vide]').hidden = messages.length > 0;
      }).catch(function () {
        $('[data-solde]').hidden = true;
        $('[data-solde-note]').hidden = true;
        $('[data-panneau-messages]').hidden = true;
      });
    };

    // Onglets « En cours » / « Livrés » (flèches du clavier comprises)
    var onglets = $$('[data-onglet]');
    var choisirOnglet = function (bouton) {
      onglet = bouton.getAttribute('data-onglet');
      onglets.forEach(function (b) {
        var actif = b === bouton;
        b.setAttribute('aria-selected', String(actif));
        b.tabIndex = actif ? 0 : -1;
      });
      liste.setAttribute('aria-labelledby', bouton.id);
      afficherColis();
    };
    onglets.forEach(function (b, i) {
      b.addEventListener('click', function () { choisirOnglet(b); });
      b.addEventListener('keydown', function (e) {
        if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') return;
        var suivant = onglets[(i + (e.key === 'ArrowRight' ? 1 : onglets.length - 1)) % onglets.length];
        suivant.focus();
        choisirOnglet(suivant);
      });
    });

    // Copier le code client
    $('[data-action="copier-code"]').addEventListener('click', function () {
      var libelle = $('[data-copier-libelle]');
      if (!libelle.hasAttribute('data-origine')) libelle.setAttribute('data-origine', libelle.textContent);
      O.copier(profil ? profil.code || '' : '').then(function () {
        libelle.textContent = t('copie-ok');
      }, function () {
        libelle.textContent = t('copie-echec');
      }).then(function () {
        setTimeout(function () { libelle.textContent = libelle.getAttribute('data-origine'); }, 2200);
      });
    });

    // Modifier mes informations
    var formProfil = $('form[data-form="profil"]');
    var lieuProfil = initLieu(formProfil);
    var boutonModifier = $('[data-action="modifier-profil"]');
    var editer = function (oui) {
      formProfil.hidden = !oui;
      $('[data-profil-lecture]').hidden = oui;
      boutonModifier.hidden = oui;
      boutonModifier.setAttribute('aria-expanded', String(oui));
      if (oui) {
        var f = formProfil.elements;
        f.nom_complet.value = profil.nom_complet || '';
        f.telephone.value = profil.telephone || '';
        f.adresse.value = profil.adresse || '';
        lieuProfil.remplir(profil.pays, profil.region, profil.ville);
        cacherErreur(formProfil);
        $$('.gs-champ.is-invalide', formProfil).forEach(function (b) { b.classList.remove('is-invalide'); });
        $$('.gs-champ__message', formProfil).forEach(function (m) { m.remove(); });
        f.nom_complet.focus();
      } else {
        boutonModifier.focus();
      }
    };
    boutonModifier.addEventListener('click', function () { editer(true); });
    var completerProfil = function () {
      editer(true);
      try { formProfil.scrollIntoView({ behavior: 'smooth', block: 'start' }); } catch (e) { formProfil.scrollIntoView(); }
    };
    $('[data-action="completer-profil"]').addEventListener('click', completerProfil);
    $('[data-action="annuler-profil"]').addEventListener('click', function () { editer(false); });
    formProfil.addEventListener('submit', function (e) {
      e.preventDefault();
      cacherErreur(formProfil);
      if (!verifierFormulaire(formProfil)) return;
      var f = formProfil.elements;
      var lieu = lieuProfil.valeurs();
      attente(formProfil, 'attente-enregistrement');
      API.modifierProfil({
        nom_complet: f.nom_complet.value.trim().replace(/\s+/g, ' '),
        telephone: f.telephone.value.trim(),
        adresse: f.adresse.value.trim(),
        pays: lieu.pays, region: lieu.region, ville: lieu.ville
      }).then(function (p) {
        attente(formProfil);
        profil = p;
        afficherProfil();
        editer(false);
        var ok = $('[data-profil-ok]');
        ok.textContent = t('profil-ok');
        ok.hidden = false;
        setTimeout(function () { ok.hidden = true; }, 2600);
      }).catch(function (err) {
        attente(formProfil);
        montrerErreur(formProfil, err);
      });
    });

    // La date de naissance : demandée une fois aux comptes qui n'en ont pas (comptes d'avant,
    // Google, Apple), jamais imposée : tout le reste du compte fonctionne sans.
    var formNaissance = $('form[data-form="naissance"]');
    var chargerNaissance = function () {
      var banniere = $('[data-completer-naissance]');
      if (!formNaissance || !banniere || !profil || API.regles.rolesEquipe.indexOf(profil.role) >= 0) return;
      API.naissance().then(function (v) {
        banniere.hidden = !!v;
        $('[data-ligne-naissance]').hidden = !v;
        $('[data-info="naissance"]').textContent = v ? jourCivil(v) : '';
      }, function () { banniere.hidden = true; }); // base sans la fonction : aucune demande
    };
    if (formNaissance) {
      formNaissance.addEventListener('submit', function (e) {
        e.preventDefault();
        cacherErreur(formNaissance);
        if (!verifierFormulaire(formNaissance)) return;
        attente(formNaissance, 'attente-enregistrement');
        API.definirNaissance(formNaissance.elements.date_naissance.value).then(function () {
          attente(formNaissance);
          chargerNaissance();
          var ok = $('[data-profil-ok]');
          ok.textContent = t('naissance-ok');
          ok.hidden = false;
          setTimeout(function () { ok.hidden = true; }, 2600);
        }).catch(function (err) {
          attente(formNaissance);
          montrerErreur(formNaissance, err);
        });
      });
    }

    /* ---- Mes avantages : GOPOINTS, offre de bienvenue, GOship Refer, anniversaire --------
       Rien n'est calculé ici : le solde, le code, le statut d'un avantage viennent de la base
       (outils/supabase-fidelite.sql, supabase-campagnes.sql). Un avantage n'est jamais montré
       comme acquis avant qu'elle le dise, et une base qui n'a pas ces fichiers ne montre rien. */
    var panneauAvt = $('[data-panneau-programmes]');
    function avtMessage(zone, texte, erreur) {
      var n = $(zone);
      n.textContent = texte || '';
      n.hidden = !texte;
      if (texte && !erreur) setTimeout(function () { n.hidden = true; }, 3200);
    }
    function avtErreur(err) {
      var code = err && err.code ? err.code : 'inconnu';
      avtMessage('[data-avt-erreur]', t('erreur-' + code) || t('erreur-inconnu'), true);
    }
    function noeud(balise, classe, texte) {
      var n = document.createElement(balise);
      if (classe) n.className = classe;
      if (texte !== undefined && texte !== null) n.textContent = texte;
      return n;
    }
    function pointsTexte(n) { return n === 1 ? t('points-un') : t('points-n', { n: O.nombre(n) }); }
    function dateCourte(iso) { return iso ? O.date(iso) : ''; }
    function clePartage() {
      var o = new Uint8Array(16);
      if (window.crypto && window.crypto.getRandomValues) window.crypto.getRandomValues(o);
      else for (var i = 0; i < o.length; i++) o[i] = Math.floor(Math.random() * 256);
      var h = Array.prototype.map.call(o, function (x) { return (x < 16 ? '0' : '') + x.toString(16); }).join('');
      return h.slice(0, 8) + '-' + h.slice(8, 12) + '-4' + h.slice(13, 16) + '-8' + h.slice(17, 20) + '-' + h.slice(20, 32);
    }

    function dessinerBienvenue(b) {
      var zone = $('[data-avt-bienvenue]');
      zone.textContent = '';
      if (!b) { zone.hidden = true; return; }
      zone.hidden = false;
      var tete = noeud('div', 'gs-avt__tete');
      tete.appendChild(noeud('h3', null, b.nom || t('bienvenue-titre')));
      tete.appendChild(noeud('span', 'gs-avt__etat gs-avt__etat--' + b.statut, t('bienvenue-' + b.statut)));
      zone.appendChild(tete);
      if (b.description) zone.appendChild(noeud('p', null, b.description));
      zone.appendChild(noeud('p', 'gs-avt__fort', t('bienvenue-avantage', { avantage: b.avantage })));
      var etapes = noeud('ol', 'gs-avt__etapes');
      (b.etapes || []).forEach(function (e) {
        var li = noeud('li', e.fait ? 'is-fait' : '', t(e.cle === 'compte' ? 'bienvenue-etape-compte' : 'bienvenue-etape-' + b.operation));
        etapes.appendChild(li);
      });
      zone.appendChild(etapes);
      if (b.statut === 'en_attente') zone.appendChild(noeud('p', 'gs-avt__note', t('bienvenue-attente')));
      if (b.fin && b.statut === 'a_debloquer') zone.appendChild(noeud('p', 'gs-avt__note', t('bienvenue-fin', { date: dateCourte(b.fin) })));
      if (b.conditions) {
        var d = noeud('details'); d.appendChild(noeud('summary', null, t('conditions')));
        d.appendChild(noeud('p', null, b.conditions)); zone.appendChild(d);
      }
    }

    function dessinerPoints(w) {
      var zone = $('[data-avt-points]');
      zone.textContent = '';
      if (!w || (!w.actif && !w.total)) { zone.hidden = true; return; }
      zone.hidden = false;
      var tete = noeud('div', 'gs-avt__tete');
      tete.appendChild(noeud('h3', null, t('points-titre')));
      tete.appendChild(noeud('strong', 'gs-avt__solde', pointsTexte(w.solde)));
      zone.appendChild(tete);
      if (!w.actif) zone.appendChild(noeud('p', 'gs-avt__note', t('points-ferme')));
      if (w.offres && w.offres.length) {
        zone.appendChild(noeud('h4', null, t('points-offres')));
        var liste = noeud('ul', 'gs-avt__liste');
        w.offres.forEach(function (o) {
          var li = noeud('li', 'gs-avt__offre');
          var texte = noeud('div', 'gs-avt__offre-texte');
          texte.appendChild(noeud('strong', null, o.nom));
          if (o.description) texte.appendChild(noeud('span', null, o.description));
          texte.appendChild(noeud('span', 'gs-avt__note', pointsTexte(o.cout_points) + (o.fin ? ' · ' + t('bienvenue-fin', { date: dateCourte(o.fin) }) : '')));
          li.appendChild(texte);
          var b = noeud('button', 'gs-bouton gs-bouton--sombre', t('points-echanger'));
          b.type = 'button'; b.disabled = w.solde < o.cout_points;
          // Une clé par appui : un double clic ou une coupure ne dépense qu'une fois
          var cle = null;
          b.addEventListener('click', function () {
            b.disabled = true; cle = cle || clePartage();
            API.utiliserPoints(o.id, cle).then(function (r) {
              avtMessage('[data-avt-ok]', t(r.deja ? 'points-deja' : 'points-ok'));
              chargerProgrammes();
            }).catch(function (err) { cle = null; avtErreur(err); b.disabled = false; });
          });
          li.appendChild(b); liste.appendChild(li);
        });
        zone.appendChild(liste);
      }
      if (w.elements && w.elements.length) {
        zone.appendChild(noeud('h4', null, t('points-historique')));
        var h = noeud('ul', 'gs-avt__liste gs-avt__liste--histo');
        w.elements.slice(0, 10).forEach(function (m) {
          var li = noeud('li', m.statut === 'annule' ? 'is-annule' : '');
          li.appendChild(noeud('span', null, t('mouvement-' + m.type) + ' · ' + dateCourte(m.date)));
          li.appendChild(noeud('strong', m.points > 0 ? 'gs-avt__plus' : 'gs-avt__moins', (m.points > 0 ? '+' : '') + O.nombre(m.points)));
          h.appendChild(li);
        });
        zone.appendChild(h);
      }
      if (w.conditions) {
        var d = noeud('details'); d.appendChild(noeud('summary', null, t('conditions')));
        d.appendChild(noeud('p', null, w.conditions)); zone.appendChild(d);
      }
    }

    function copierTexte(texte, bouton, canal) {
      O.copier(texte).then(function () {
        var ancien = bouton.textContent; bouton.textContent = t('refer-copie');
        setTimeout(function () { bouton.textContent = ancien; }, 1800);
        API.noterInvitation(canal).catch(function () {});
      }).catch(function () { avtMessage('[data-avt-erreur]', t('erreur-copie'), true); });
    }

    function dessinerParrainage(r) {
      var zone = $('[data-avt-parrainage]');
      zone.textContent = '';
      // Fermé et jamais utilisé : rien à montrer. Fermé mais déjà des filleuls : l'historique reste visible.
      if (!r || (!r.actif && !r.inscrits && !(r.recompenses && r.recompenses.length))) { zone.hidden = true; return; }
      zone.hidden = false;
      var tete = noeud('div', 'gs-avt__tete');
      tete.appendChild(noeud('h3', null, r.nom || t('refer-titre')));
      zone.appendChild(tete);
      zone.appendChild(noeud('p', null, t('refer-texte')));
      if (!r.actif) zone.appendChild(noeud('p', 'gs-avt__note', t('refer-inactif')));
      if (r.avantage_parrain) zone.appendChild(noeud('p', 'gs-avt__fort', t('refer-avantage-parrain', { avantage: r.avantage_parrain })));
      if (r.avantage_filleul) zone.appendChild(noeud('p', 'gs-avt__fort', t('refer-avantage-filleul', { avantage: r.avantage_filleul })));
      if (r.actif) {
        var boite = noeud('div', 'gs-avt__invitation');
        boite.appendChild(noeud('span', 'gs-avt__note', t('refer-code')));
        boite.appendChild(noeud('strong', 'gs-avt__code', r.code)).setAttribute('translate', 'no');
        var lignes = noeud('div', 'gs-avt__boutons');
        var bc = noeud('button', 'gs-bouton gs-bouton--contour', t('refer-copier-code')); bc.type = 'button';
        bc.addEventListener('click', function () { copierTexte(r.code, bc, 'code'); });
        lignes.appendChild(bc);
        if (r.lien) {
          var bl = noeud('button', 'gs-bouton gs-bouton--contour', t('refer-copier-lien')); bl.type = 'button';
          bl.addEventListener('click', function () { copierTexte(r.lien, bl, 'lien'); });
          lignes.appendChild(bl);
        }
        // Le bouton principal : le partage natif de l'appareil s'il existe, sinon la copie du message complet
        var message = t('refer-partage-message', { code: r.code, lien: r.lien || '' }).trim();
        var cta = noeud('button', 'gs-bouton gs-bouton--plein gs-avt__cta', t('refer-cta')); cta.type = 'button';
        cta.addEventListener('click', function () {
          if (navigator.share) {
            navigator.share({ title: t('refer-partage-titre'), text: message, url: r.lien || undefined }).then(function () {
              API.noterInvitation('partage').catch(function () {});
            }).catch(function () { /* partage annulé : rien à compter */ });
          } else copierTexte(message, cta, 'message');
        });
        boite.appendChild(cta); boite.appendChild(lignes); zone.appendChild(boite);
      }
      var chiffres = noeud('dl', 'gs-avt__chiffres');
      [['refer-invitations', r.invitations], ['refer-inscrits', r.inscrits], ['refer-attente', r.en_attente_premiere_operation], ['refer-valides', r.valides]].forEach(function (c) {
        var d = noeud('div'); d.appendChild(noeud('dt', null, t(c[0]))); d.appendChild(noeud('dd', null, O.nombre(c[1]))); chiffres.appendChild(d);
      });
      zone.appendChild(chiffres);
      if (r.recompenses && r.recompenses.length) {
        zone.appendChild(noeud('h4', null, t('refer-recompenses')));
        var l = noeud('ul', 'gs-avt__liste gs-avt__liste--histo');
        r.recompenses.forEach(function (x) {
          var li = noeud('li');
          li.appendChild(noeud('span', null, x.avantage + ' · ' + dateCourte(x.date)));
          li.appendChild(noeud('span', 'gs-avt__etat gs-avt__etat--' + x.statut, t('avantage-' + x.statut)));
          l.appendChild(li);
        });
        zone.appendChild(l);
      }
      // Un code reçu plus tard (compte ouvert avec Google, ami oublié à l'inscription)
      if (r.actif && !r.mon_parrain) {
        var d2 = noeud('details'); d2.appendChild(noeud('summary', null, t('refer-j-ai-un-code')));
        var form = noeud('form', 'gs-avt__saisie'); form.noValidate = true;
        var champ = noeud('input'); champ.name = 'code'; champ.maxLength = 24; champ.autocomplete = 'off';
        champ.setAttribute('aria-label', t('refer-code-champ')); champ.placeholder = t('refer-code-champ');
        champ.value = lireParrain();
        var envoyer = noeud('button', 'gs-bouton gs-bouton--sombre', t('refer-code-envoyer')); envoyer.type = 'submit';
        form.appendChild(champ); form.appendChild(envoyer);
        form.addEventListener('submit', function (e) {
          e.preventDefault();
          envoyer.disabled = true;
          API.utiliserCodeParrainage(champ.value.trim().toUpperCase()).then(function () {
            garderParrain('');
            avtMessage('[data-avt-ok]', t('refer-code-ok'));
            chargerProgrammes();
          }).catch(function (err) { avtErreur(err); envoyer.disabled = false; });
        });
        d2.appendChild(form); zone.appendChild(d2);
      }
      var cond = [r.conditions, r.annulation].filter(Boolean);
      if (cond.length) {
        var d3 = noeud('details'); d3.appendChild(noeud('summary', null, t('conditions')));
        cond.forEach(function (c) { d3.appendChild(noeud('p', null, c)); }); zone.appendChild(d3);
      }
    }

    var chargerProgrammes = function () {
      if (!panneauAvt || !profil || API.regles.rolesEquipe.indexOf(profil.role) >= 0) return;
      // Chaque morceau se charge seul : une base qui n'a pas l'un des fichiers n'empêche pas les autres
      var vus = 0;
      function montrer() { vus += 1; if (vus < 4) return; panneauAvt.hidden = !$$('.gs-avt__bloc', panneauAvt).some(function (b) { return !b.hidden; }); }
      API.maBienvenue().then(dessinerBienvenue, function () { dessinerBienvenue(null); }).then(montrer);
      API.portefeuille().then(dessinerPoints, function () { dessinerPoints(null); }).then(montrer);
      API.monParrainage().then(dessinerParrainage, function () { dessinerParrainage(null); }).then(montrer);
      var pref = $('[data-avt-preferences]');
      API.preferencesProgrammes().then(function (p) {
        pref.hidden = false;
        $('[data-pref-anniversaire]').checked = !!p.anniversaire;
      }, function () { pref.hidden = true; }).then(montrer);
    };
    var casePref = $('[data-pref-anniversaire]');
    if (casePref) casePref.addEventListener('change', function () {
      API.reglerAnniversaire(casePref.checked).then(function () { avtMessage('[data-avt-ok]', t('pref-ok')); }, function (err) { avtErreur(err); casePref.checked = !casePref.checked; });
    });

    // Déconnexion
    $('[data-action="deconnexion"]').addEventListener('click', function () {
      API.deconnecter().then(function () {
        annoncerSession();
        location.href = 'connexion.html';
      });
    });

    // Chargement, puis mises à jour en direct
    API.profil().then(function (p) {
      if (!p) { location.replace('connexion.html?retour=mon-compte.html'); return; }
      profil = p;
      afficherProfil();
      // Profil incomplet (compte ouvert avec Google, le plus souvent) : le formulaire
      // s'ouvre de lui-même, sans attendre qu'on remarque le bandeau. Sans téléphone ni
      // ville, l'équipe ne peut pas remettre un colis, et la base refuse les pré-alertes.
      if (!$('[data-completer]').hidden) completerProfil();
      if (/[?&]bienvenue=1/.test(location.search)) {
        var bienvenue = $('[data-bienvenue]');
        bienvenue.hidden = false;
        history.replaceState(null, '', location.pathname);
      }
      chargerNaissance();
      chargerProgrammes();
      // Un code de parrain gardé sur l'appareil (lien d'invitation, compte ouvert avec Google) : on l'enregistre
      // une fois, sans bruit ; un refus (parrainage fermé, déjà parrainé) n'est pas une erreur à montrer.
      if (lireParrain()) API.utiliserCodeParrainage(lireParrain()).then(function () { garderParrain(''); chargerProgrammes(); }, function () { garderParrain(''); });
      chargerColis();
      chargerFactures();
      chargerResume();
      var direct = $('[data-direct]');
      var prevu = null;
      API.surveiller(function (quoi) {
        clearTimeout(prevu);
        prevu = setTimeout(function () {
          if (quoi === 'factures') chargerFactures(); else chargerColis();
          chargerResume();
        }, 250);
      }, { etat: function (actif) { direct.hidden = !actif; } });
    }).catch(function (err) {
      if (err.code === 'non-autorise') { location.replace('connexion.html?retour=mon-compte.html'); return; }
      liste.textContent = '';
      liste.removeAttribute('aria-busy');
      var zone = $('[data-colis-erreur]');
      zone.textContent = t('erreur-' + err.code) || t('erreur-inconnu');
      zone.hidden = false;
    });
  }
})();
