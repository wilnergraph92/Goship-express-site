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

  /* ---- Régions et villes ------------------------------------------------------ */
  var REGIONS = {
    HT: {
      'Artibonite': ['Gonaïves', 'Saint-Marc', 'Dessalines', 'Gros-Morne', 'Ennery', "L'Estère", 'Terre-Neuve', 'Anse-Rouge',
                     'Verrettes', 'La Chapelle', "Petite-Rivière-de-l'Artibonite", 'Grande-Saline', 'Desdunes',
                     "Saint-Michel-de-l'Attalaye", 'Marmelade'],
      'Centre': ['Hinche', 'Mirebalais', 'Lascahobas', 'Belladère', 'Maïssade', 'Thomonde', 'Cerca-Carvajal',
                 "Saut-d'Eau", 'Boucan-Carré', 'Savanette', 'Cerca-la-Source', 'Thomassique'],
      "Grand'Anse": ['Jérémie', 'Abricots', 'Bonbon', 'Moron', 'Chambellan', "Anse-d'Hainault", 'Dame-Marie',
                     'Les Irois', 'Corail', 'Roseaux', 'Beaumont', 'Pestel'],
      'Nippes': ['Miragoâne', 'Petite-Rivière-de-Nippes', 'Paillant', 'Fonds-des-Nègres', 'Anse-à-Veau', 'Arnaud',
                 "L'Asile", 'Petit-Trou-de-Nippes', 'Plaisance-du-Sud', 'Baradères', 'Grand-Boucan'],
      'Nord': ['Cap-Haïtien', 'Limonade', 'Quartier-Morin', 'Acul-du-Nord', 'Plaine-du-Nord', 'Milot',
               'Grande-Rivière-du-Nord', 'Bahon', 'Borgne', 'Port-Margot', 'Limbé', 'Bas-Limbé', 'Plaisance',
               'Pilate', 'Dondon', 'Saint-Raphaël', 'Pignon', 'La Victoire', 'Ranquitte'],
      'Nord-Est': ['Fort-Liberté', 'Ouanaminthe', 'Trou-du-Nord', 'Terrier-Rouge', 'Caracol', 'Sainte-Suzanne',
                   'Ferrier', 'Perches', 'Capotille', 'Mont-Organisé', 'Vallières', 'Carice', 'Mombin-Crochu'],
      'Nord-Ouest': ['Port-de-Paix', 'Saint-Louis-du-Nord', 'Jean-Rabel', 'Môle-Saint-Nicolas', 'Bassin-Bleu',
                     'Chansolme', 'La Tortue', 'Anse-à-Foleur', 'Baie-de-Henne', 'Bombardopolis'],
      'Ouest': ['Port-au-Prince', 'Delmas', 'Pétion-Ville', 'Carrefour', 'Tabarre', 'Cité Soleil', 'Croix-des-Bouquets',
                'Kenscoff', 'Gressier', 'Léogâne', 'Petit-Goâve', 'Grand-Goâve', 'Arcahaie', 'Cabaret', 'Thomazeau',
                'Ganthier', 'Cornillon', 'Fonds-Verrettes', 'Anse-à-Galets', 'Pointe-à-Raquette'],
      'Sud': ['Les Cayes', 'Aquin', 'Cavaillon', 'Saint-Louis-du-Sud', 'Camp-Perrin', 'Maniche', 'Chantal',
              'Torbeck', 'Île-à-Vache', 'Port-Salut', 'Saint-Jean-du-Sud', 'Arniquet', 'Côteaux', 'Port-à-Piment',
              'Roche-à-Bateau', 'Chardonnières', 'Les Anglais', 'Tiburon'],
      'Sud-Est': ['Jacmel', 'Cayes-Jacmel', 'Marigot', 'La Vallée', 'Bainet', 'Côtes-de-Fer', 'Belle-Anse',
                  'Grand-Gosier', 'Thiotte', 'Anse-à-Pitres']
    },
    DO: {
      'Azua': ['Azua de Compostela', 'Padre Las Casas', 'Sabana Yegua', 'Estebanía', 'Las Charcas', 'Peralta',
               'Pueblo Viejo', 'Tábara Arriba', 'Guayabal', 'Las Yayas de Viajama'],
      'Bahoruco': ['Neiba', 'Galván', 'Tamayo', 'Villa Jaragua', 'Los Ríos'],
      'Barahona': ['Santa Cruz de Barahona', 'Cabral', 'Enriquillo', 'Paraíso', 'Vicente Noble', 'Polo',
                   'La Ciénaga', 'Fundación', 'El Peñón', 'Jaquimeyes', 'Las Salinas'],
      'Dajabón': ['Dajabón', 'Loma de Cabrera', 'Partido', 'Restauración', 'El Pino'],
      'Distrito Nacional': ['Santo Domingo de Guzmán'],
      'Duarte': ['San Francisco de Macorís', 'Arenoso', 'Castillo', 'Eugenio María de Hostos', 'Las Guáranas',
                 'Pimentel', 'Villa Riva'],
      'El Seibo': ['Santa Cruz de El Seibo', 'Miches'],
      'Elías Piña': ['Comendador', 'Bánica', 'El Llano', 'Hondo Valle', 'Juan Santiago', 'Pedro Santana'],
      'Espaillat': ['Moca', 'Cayetano Germosén', 'Gaspar Hernández', 'Jamao al Norte'],
      'Hato Mayor': ['Hato Mayor del Rey', 'El Valle', 'Sabana de la Mar'],
      'Hermanas Mirabal': ['Salcedo', 'Tenares', 'Villa Tapia'],
      'Independencia': ['Jimaní', 'Cristóbal', 'Duvergé', 'La Descubierta', 'Mella', 'Postrer Río'],
      'La Altagracia': ['Higüey', 'Punta Cana', 'San Rafael del Yuma'],
      'La Romana': ['La Romana', 'Guaymate', 'Villa Hermosa'],
      'La Vega': ['La Vega', 'Constanza', 'Jarabacoa', 'Jima Abajo'],
      'María Trinidad Sánchez': ['Nagua', 'Cabrera', 'El Factor', 'Río San Juan'],
      'Monseñor Nouel': ['Bonao', 'Maimón', 'Piedra Blanca'],
      'Monte Cristi': ['Monte Cristi', 'Castañuelas', 'Guayubín', 'Las Matas de Santa Cruz', 'Pepillo Salcedo',
                       'Villa Vásquez'],
      'Monte Plata': ['Monte Plata', 'Bayaguana', 'Peralvillo', 'Sabana Grande de Boyá', 'Yamasá'],
      'Pedernales': ['Pedernales', 'Oviedo'],
      'Peravia': ['Baní', 'Nizao'],
      'Puerto Plata': ['Puerto Plata', 'Sosúa', 'Imbert', 'Luperón', 'Altamira', 'Guananico', 'Los Hidalgos',
                       'Villa Isabela', 'Villa Montellano'],
      'Samaná': ['Santa Bárbara de Samaná', 'Las Terrenas', 'Sánchez'],
      'San Cristóbal': ['San Cristóbal', 'Bajos de Haina', 'Villa Altagracia', 'Cambita Garabitos', 'Los Cacaos',
                        'Sabana Grande de Palenque', 'San Gregorio de Nigua', 'Yaguate'],
      'San José de Ocoa': ['San José de Ocoa', 'Rancho Arriba', 'Sabana Larga'],
      'San Juan': ['San Juan de la Maguana', 'Las Matas de Farfán', 'El Cercado', 'Bohechío', 'Juan de Herrera',
                   'Vallejuelo'],
      'San Pedro de Macorís': ['San Pedro de Macorís', 'Consuelo', 'Guayacanes', 'Quisqueya', 'Ramón Santana',
                               'San José de Los Llanos'],
      'Sánchez Ramírez': ['Cotuí', 'Cevicos', 'Fantino', 'La Mata'],
      'Santiago': ['Santiago de los Caballeros', 'Tamboril', 'Licey al Medio', 'Puñal', 'Villa González',
                   'Villa Bisonó (Navarrete)', 'San José de las Matas', 'Jánico', 'Sabana Iglesia', 'Baitoa'],
      'Santiago Rodríguez': ['San Ignacio de Sabaneta', 'Monción', 'Villa Los Almácigos'],
      'Santo Domingo': ['Santo Domingo Este', 'Santo Domingo Oeste', 'Santo Domingo Norte', 'Boca Chica',
                        'Los Alcarrizos', 'Pedro Brand', 'San Antonio de Guerra'],
      'Valverde': ['Mao', 'Esperanza', 'Laguna Salada']
    }
  };
  var ETATS_US = ['Alabama', 'Alaska', 'Arizona', 'Arkansas', 'California', 'Colorado', 'Connecticut', 'Delaware',
    'District of Columbia', 'Florida', 'Georgia', 'Hawaii', 'Idaho', 'Illinois', 'Indiana', 'Iowa', 'Kansas',
    'Kentucky', 'Louisiana', 'Maine', 'Maryland', 'Massachusetts', 'Michigan', 'Minnesota', 'Mississippi',
    'Missouri', 'Montana', 'Nebraska', 'Nevada', 'New Hampshire', 'New Jersey', 'New Mexico', 'New York',
    'North Carolina', 'North Dakota', 'Ohio', 'Oklahoma', 'Oregon', 'Pennsylvania', 'Rhode Island',
    'South Carolina', 'South Dakota', 'Tennessee', 'Texas', 'Utah', 'Vermont', 'Virginia', 'Washington',
    'West Virginia', 'Wisconsin', 'Wyoming'];
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

  function verifierChamp(champ) {
    if (champ.disabled || champ.hidden || champ.classList.contains('gs-hp')) return true;
    var v = String(champ.value || '').trim();
    var message = '';
    if (champ.required && !v) message = t('champ-requis');
    else if (champ.type === 'email' && !/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(v)) message = t('champ-email');
    else if (/^mot_de_passe$/.test(champ.name) && champ.minLength > 0 && champ.value.length < champ.minLength) message = t('champ-mdp');
    else if (champ.type === 'tel' && v.replace(/\D/g, '').length < 7) message = t('champ-tel');
    else if (champ.name === 'nom_complet' && v.split(/\s+/).length < 2) message = t('champ-nom');
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
        location.href = 'mon-compte.html?bienvenue=1';
      }).catch(function (err) {
        attente(formInscription);
        montrerErreur(formInscription, err);
        if (err.code === 'email-existe' || err.code === 'email-invalide') f.email.focus();
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
          var admin = profil && profil.role === 'admin';
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
      $('[data-nom-adresse]').textContent = ((profil.nom_complet || '') + ' ' + (profil.code || '')).trim();
      var infos = {
        nom_complet: profil.nom_complet, email: profil.email, telephone: profil.telephone, adresse: profil.adresse,
        lieu: [profil.ville, profil.region, nomPays(profil.pays)].filter(Boolean).join(', ')
      };
      Object.keys(infos).forEach(function (k) {
        var dd = $('[data-info="' + k + '"]');
        if (dd) dd.textContent = infos[k] || '—';
      });
      $$('[data-lien-wa="wa-aide"]').forEach(function (a) { a.href = waUrl(t('wa-aide', { code: profil.code || '' })); });
      if (profil.role === 'admin' && !$('[data-avis-admin]')) {
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
      if (/[?&]bienvenue=1/.test(location.search)) {
        var bienvenue = $('[data-bienvenue]');
        bienvenue.hidden = false;
        history.replaceState(null, '', location.pathname);
      }
      chargerColis();
      chargerFactures();
      var direct = $('[data-direct]');
      var prevu = null;
      API.surveiller(function (quoi) {
        clearTimeout(prevu);
        prevu = setTimeout(function () {
          if (quoi === 'factures') chargerFactures(); else chargerColis();
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
