/* ==========================================================================
   Goship Express — tableau de bord (équipe)
   Enregistrer les colis, mettre à jour leur statut (un par un ou par lot),
   retrouver les clients. Les données se mettent à jour en direct.
   ========================================================================== */
(function () {
  'use strict';

  var API = window.GoshipAPI;
  if (!API) return;
  var O = API.outils;

  var STATUTS = {
    recu: 'Reçu', emballe: 'Emballé', embarque: 'Embarqué', distribution: 'Centre de distribution',
    succursale: 'Transféré à la succursale', disponible: 'Disponible', livre: 'Livré', incident: 'Action requise'
  };
  var SERVICES = { aerien: 'Aérien', maritime: 'Maritime', terrestre: 'Terrestre' };
  var PAYS = { HT: 'Haïti', DO: 'République dominicaine', US: 'États-Unis' };
  var LANGUES = { fr: 'français', en: 'anglais', es: 'espagnol', ht: 'créole' };
  var ERREURS = {
    identifiants: 'E-mail ou mot de passe incorrect.',
    reseau: 'Connexion impossible. Vérifiez la connexion Internet, puis réessayez.',
    'non-autorise': 'Action réservée : votre rôle ne le permet pas, ou la session a expiré (reconnectez-vous).',
    'trop-de-tentatives': 'Trop de tentatives. Patientez quelques minutes.',
    'non-confirme': 'Adresse e-mail pas encore confirmée.',
    // Les refus de la base (outils/supabase-services.sql). Elle joint le plus
    // souvent une phrase plus précise, qui a la priorité (messageErreur).
    SHIPMENT_NOT_FOUND: 'Ce colis n’existe plus : rechargez la liste.',
    CLIENT_NOT_FOUND: 'Client introuvable : choisissez un client existant.',
    INVALID_WEIGHT: 'Poids invalide : indiquez un nombre de livres supérieur à zéro.',
    INVALID_RATE: 'Tarif invalide : entre 0 et 1 000 $ la livre.',
    INVALID_DESCRIPTION: 'Décrivez le contenu du colis.',
    INVALID_SERVICE: 'Service inconnu.',
    INVALID_DESTINATION: 'Destination inconnue.',
    INVALID_DATE: 'Date invalide.',
    INVALID_STATUS: 'Statut inconnu.',
    INVALID_STATUS_TRANSITION: 'Ce changement de statut n’est pas permis.',
    STATUS_CONFLICT: 'Le colis a changé de statut entre-temps : rechargez la liste.',
    CONCURRENT_MODIFICATION: 'Le colis a été modifié entre-temps par quelqu’un d’autre : rouvrez-le.',
    LOCATION_REQUIRED: 'Indiquez l’agence où le client peut retirer son colis.',
    TRACKING_ALREADY_EXISTS: 'Ce numéro de suivi vendeur est déjà celui d’un autre colis.',
    DUPLICATE_OPERATION: 'Cette demande a déjà été traitée pour un autre client.',
    INVOICE_ALREADY_EXISTS: 'Ce colis est déjà sur une facture.',
    INVOICE_CLIENT_MISMATCH: 'Une facture ne regroupe que les colis d’un seul client.',
    INVOICE_LOCKED: 'Cette partie de la facture est arrêtée depuis sa création.',
    INVALID_AMOUNT: 'Montant invalide.',
    INVALID_INPUT: 'Données incomplètes.',
    // Les refus des finances (outils/supabase-finances.sql)
    INVOICE_NOT_FOUND: 'Cette facture n’existe plus : rechargez la liste.',
    INVOICE_CANCELLED: 'Cette facture est annulée : elle ne reçoit plus de paiement.',
    INVOICE_ALREADY_PAID: 'Cette facture est déjà entièrement payée.',
    OVERPAYMENT: 'Ce paiement dépasse ce qui reste à payer.',
    INVALID_PAYMENT_METHOD: 'Moyen de paiement inconnu.',
    DUPLICATE_PAYMENT: 'Ce paiement (même référence) est déjà enregistré.',
    PAYMENT_NOT_FOUND: 'Ce paiement n’existe plus : rechargez la liste.',
    PAYMENT_LOCKED: 'Un paiement enregistré ne se modifie pas : annulez-le, puis saisissez le bon.',
    PAYMENT_REQUIRED: 'Le payé d’une facture suit ses paiements : enregistrez un paiement.',
    REASON_REQUIRED: 'Indiquez le motif.',
    INVOICE_HAS_PAYMENTS: 'Cette facture a déjà reçu un paiement.',
    INVOICE_NOT_GROUPABLE: 'Cette facture ne peut pas être regroupée.',
    INVOICE_DELETE_FORBIDDEN: 'Une facture ne se supprime pas : annulez-la.',
    INVOICE_NUMBER_USED: 'Ce numéro de facture a déjà servi.',
    // Les rôles (onglet Équipe)
    INVALID_ROLE: 'Rôle inconnu.',
    USER_NOT_FOUND: 'Aucun compte avec cette adresse : la personne doit d’abord créer son compte sur le site.',
    SELF_ROLE_CHANGE: 'On ne change pas son propre rôle : demandez-le à un autre administrateur.',
    LAST_ADMIN: 'C’est le dernier administrateur : nommez-en un autre d’abord.',
    // La base n'a pas encore reçu l'un des fichiers outils/supabase-*.sql
    absent: 'La base n’est pas à jour : lancez dans Supabase (SQL Editor) les fichiers de outils/, dans l’ordre du README.',
    inconnu: 'Une erreur est survenue. Réessayez.'
  };
  var PAR_PAGE = 50;

  function $(sel, scope) { return (scope || document).querySelector(sel); }
  function $$(sel, scope) { return Array.prototype.slice.call((scope || document).querySelectorAll(sel)); }
  function messageErreur(err) {
    if (err && err.metier && err.detail) return err.detail;
    // Un refus de la base dit souvent lequel (« Un tarif particulier est réservé… »)
    if (err && err.code === 'non-autorise' && err.detail && !/^[a-z]/.test(err.detail)) return err.detail;
    return ERREURS[err && err.code] || ERREURS.inconnu;
  }

  // Une clé par demande d'enregistrement, tirée à l'ouverture du formulaire et
  // gardée jusqu'au succès : un second clic, ou un nouvel essai après une
  // coupure, est reconnu par la base au lieu de créer un doublon.
  function nouvelleCle() {
    var octets = new Uint8Array(16);
    if (window.crypto && window.crypto.getRandomValues) window.crypto.getRandomValues(octets);
    else for (var i = 0; i < 16; i++) octets[i] = Math.floor(Math.random() * 256);
    return Array.prototype.map.call(octets, function (o) { return (o < 16 ? '0' : '') + o.toString(16); }).join('');
  }

  function el(balise, classe, texte) {
    var n = document.createElement(balise);
    if (classe) n.className = classe;
    if (texte !== undefined && texte !== null) n.textContent = texte;
    return n;
  }

  function ecran(nom) {
    $$('[data-ecran]').forEach(function (s) { s.hidden = s.getAttribute('data-ecran') !== nom; });
  }

  var minuteurToast = null;
  function toast(message, erreur) {
    var t = $('[data-toast]');
    t.textContent = message;
    t.className = 'gs-toast' + (erreur ? ' gs-toast--erreur' : '');
    t.hidden = false;
    clearTimeout(minuteurToast);
    minuteurToast = setTimeout(function () { t.hidden = true; }, 3600);
  }

  // attente(bouton, 'Enregistrement…') met le bouton en attente et rend la
  // fonction qui le remet dans son état (… .then(fin)) ; attente(bouton) le
  // remet directement.
  function attente(bouton, texte) {
    if (!bouton.hasAttribute('data-libelle')) bouton.setAttribute('data-libelle', bouton.textContent);
    if (texte) {
      bouton.disabled = true;
      bouton.setAttribute('aria-busy', 'true');
      bouton.textContent = '';
      var roue = el('span', 'gs-roue');
      roue.setAttribute('aria-hidden', 'true');
      bouton.appendChild(roue);
      bouton.appendChild(document.createTextNode(texte));
      return function () { attente(bouton); };
    }
    bouton.disabled = false;
    bouton.removeAttribute('aria-busy');
    bouton.textContent = bouton.getAttribute('data-libelle');
  }

  function erreurFormulaire(form, message) {
    var zone = $('[data-form-erreur]', form);
    zone.textContent = message || '';
    zone.hidden = !message;
  }

  /* ---- Les droits du compte connecté ----------------------------------------
     Lus dans la base au démarrage (API.permissions → mes_permissions). Ils ne
     servent qu'à montrer les bons menus et les bons boutons : chaque action
     est revérifiée par la base, qui refuse d'elle-même ce que le rôle ne
     permet pas. Un élément marqué data-permission="a b" n'apparaît que si le
     compte a toutes ces permissions.
     -------------------------------------------------------------------------- */
  var droits = { role: null, equipe: false, permissions: [] };
  var ROLES = { admin: 'Administrateur', gerant: 'Gérant', employe: 'Employé', client: 'Client' };

  function peut(permission) {
    return droits.permissions.indexOf(permission) >= 0;
  }

  function appliquerDroits() {
    $$('[data-permission]').forEach(function (n) {
      var permis = n.getAttribute('data-permission').split(/\s+/).every(peut);
      if (permis) n.removeAttribute('data-interdit'); else n.setAttribute('data-interdit', '');
    });
    var badge = $('[data-role-compte]');
    badge.textContent = ROLES[droits.role] || '';
    badge.hidden = !droits.role;
  }

  /* ---- État de l'affichage ------------------------------------------------ */
  var etat = {
    vue: 'colis',
    colis: { lignes: [], total: 0, pages: 1, statut: 'actifs', recherche: '', clientId: null, clientCode: '' },
    clients: { lignes: [], total: 0, pages: 1, recherche: '' },
    factures: { lignes: [], total: 0, pages: 1, statut: 'a_payer' },
    selection: [],
    vus: {}
  };

  /* ---- Démarrage ---------------------------------------------------------- */
  function demarrer() {
    if (API.mode === 'demo') {
      $('[data-demo]').hidden = false;
      $('[data-demo-badge]').hidden = false;
      $$('[data-demo-identifiants]').forEach(function (n) { n.hidden = false; });
    }
    if (API.mode === 'off') { ecran('off'); return; }
    API.session().then(function (s) {
      if (!s) { ecran('connexion'); return null; }
      $$('[data-email]').forEach(function (n) { n.textContent = s.email; });
      $('[data-barre-connecte]').hidden = false;
      // Un compte de l'équipe entre ; un client est renvoyé vers son espace
      return API.permissions().then(function (p) {
        droits = p || droits;
        appliquerDroits();
        if (droits.equipe) ouvrirTableau(); else ecran('refuse');
      });
    }).catch(function (err) {
      ecran('connexion');
      erreurFormulaire($('form[data-form="admin-connexion"]'), messageErreur(err));
    });
  }

  // Connexion
  var formConnexion = $('form[data-form="admin-connexion"]');
  formConnexion.addEventListener('submit', function (e) {
    e.preventDefault();
    var f = formConnexion.elements;
    if (!f.email.value.trim() || !f.mot_de_passe.value) {
      erreurFormulaire(formConnexion, 'Renseignez votre e-mail et votre mot de passe.');
      return;
    }
    erreurFormulaire(formConnexion, '');
    var bouton = $('[data-envoyer]', formConnexion);
    attente(bouton, 'Connexion…');
    API.connecter(f.email.value.trim().toLowerCase(), f.mot_de_passe.value).then(function () {
      attente(bouton);
      f.mot_de_passe.value = '';
      demarrer();
    }).catch(function (err) {
      attente(bouton);
      erreurFormulaire(formConnexion, messageErreur(err));
    });
  });

  $$('[data-action="deconnexion"]').forEach(function (b) {
    b.addEventListener('click', function () {
      API.deconnecter().then(function () { location.reload(); });
    });
  });

  /* ---- Tableau de bord ---------------------------------------------------------- */
  // Logo des e-mails : copié une fois dans le dossier public de Supabase, pour que
  // Gmail et les autres messageries puissent l'afficher
  var logoVerifie = false;
  function installerLogoEmail() {
    if (logoVerifie || API.mode !== 'supabase' || !window.GoshipNotifications || !API.admin.preparerLogo) return;
    if (!peut('settings.manage')) return;   // le dossier « site » n'est ouvert qu'à ce rôle
    logoVerifie = true;
    API.admin.preparerLogo(window.GoshipNotifications.logo).then(function (etat) {
      if (etat === 'envoye') toast('Logo des e-mails installé.');
    }).catch(function (err) {
      toast('Logo des e-mails non installé : ' + ((err && err.message) || 'erreur inconnue') + '.', true);
    });
  }

  function ouvrirTableau() {
    ecran('tableau');
    $('[data-demo-actions]').hidden = API.mode !== 'demo';
    try {
      var jour = new Intl.DateTimeFormat('fr-FR', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' }).format(new Date());
      $('[data-date-jour]').textContent = jour.charAt(0).toUpperCase() + jour.slice(1);
    } catch (e) { /* date facultative */ }
    chargerStatistiques();
    chargerColis();
    if (peut('clients.view')) chargerClients();
    if (peut('invoices.view')) chargerFactures();
    if (peut('users.view')) chargerEquipe();
    installerLogoEmail();
    var prevu = null;
    API.surveiller(function (quoi) {
      clearTimeout(prevu);
      prevu = setTimeout(function () {
        chargerStatistiques();
        chargerColis(true);
        if (peut('clients.view') && (quoi === 'clients' || etat.vue === 'clients')) chargerClients();
        if (peut('invoices.view') && (quoi === 'factures' || etat.vue === 'factures')) chargerFactures();
        if (peut('users.view') && (quoi === 'clients' || etat.vue === 'equipe')) chargerEquipe();
      }, 350);
    }, { tout: true, etat: function (actif) { $('[data-direct]').hidden = !actif; } });
  }

  function chargerStatistiques() {
    API.admin.statistiques().then(function (s) {
      var statuts = (s && s.statuts) || {};
      $$('[data-stat]').forEach(function (n) {
        var cle = n.getAttribute('data-stat');
        var valeur = cle === 'clients' ? s.clients : (cle === 'livres_30j' ? s.livres_30j : statuts[cle]);
        n.textContent = String(valeur || 0);
      });
    }).catch(function () { /* les chiffres restent affichés tels quels */ });
  }

  /* ---- Colis --------------------------------------------------------------- */
  var corpsColis = $('[data-lignes="colis"]');

  function chargerColis(enDirect) {
    var c = etat.colis;
    return API.admin.colis({
      recherche: c.recherche, statut: c.statut, clientId: c.clientId, page: 0, parPage: PAR_PAGE * c.pages
    }).then(function (r) {
      var nouveaux = [];
      r.lignes.forEach(function (ligne) {
        if (enDirect && etat.vus[ligne.id] !== ligne.maj_le) nouveaux.push(ligne.id);
        etat.vus[ligne.id] = ligne.maj_le;
      });
      c.lignes = r.lignes;
      c.total = r.total;
      var ids = r.lignes.map(function (l) { return l.id; });
      etat.selection = etat.selection.filter(function (id) { return ids.indexOf(id) >= 0; });
      afficherColis(nouveaux);
    }).catch(function (err) {
      if (err.code === 'non-autorise') { location.reload(); return; }
      toast(messageErreur(err), true);
    });
  }

  function cellule(libelle) {
    var td = el('td');
    if (libelle) td.setAttribute('data-libelle', libelle);
    return td;
  }

  function badge(statut) {
    return el('span', 'gs-badge gs-badge--' + statut, STATUTS[statut] || statut);
  }

  /* ---- Étiquettes et factures imprimées ----------------------------------
     assets/js/impression.js dessine le document, code-barres et QR code
     compris, puis l'envoie à l'imprimante dans un cadre à part. La fenêtre
     d'impression du navigateur sert d'aperçu : on n'en ajoute pas un second. */
  var IMP = window.GoshipImpression;

  function imprimer(noeuds, options) {
    if (!IMP) {
      toast("L'impression demande le fichier assets/js/impression.js.", true);
      return Promise.resolve(false);
    }
    return IMP.imprimer(noeuds, options).catch(function () {
      toast("L'impression n'a pas pu s'ouvrir. Réessayez.", true);
      return false;
    });
  }

  // L'étiquette d'expédition : 4 × 6 pouces, une page par colis
  function imprimerEtiquettes(liste) {
    if (!IMP || !liste.length) return;
    var noeuds = liste.map(function (colis) { return IMP.etiquette(colis); });
    imprimer(noeuds, {
      papier: '4in 6in',
      titre: liste.length === 1 ? 'Étiquette ' + liste[0].numero
                                : liste.length + ' étiquettes Goship Express'
    }).then(function (fait) {
      if (fait && liste.length > 1) toast(liste.length + ' étiquettes envoyées à l\'imprimante.');
    });
  }

  function imprimerFacture(facture) {
    if (!IMP) return;
    var client = facture.clients || {};
    imprimer([IMP.facture(facture, client)], {
      papier: 'A4', langue: client.langue || 'fr', titre: 'Facture ' + (facture.numero || '')
    });
  }

  function boutonEtiquette(colis, classe) {
    var b = el('button', classe, 'Étiquette');
    b.type = 'button';
    b.setAttribute('aria-label', 'Imprimer l\'étiquette du colis ' + colis.numero);
    b.addEventListener('click', function () { imprimerEtiquettes([colis]); });
    return b;
  }

  // « Voir la facture » : ouvre la facture de ce colis. Un colis d'avant la
  // facturation automatique n'en a pas : on propose alors de la créer.
  function boutonFactureDuColis(colis) {
    var b = el('button', 'gs-bouton gs-bouton--petit gs-bouton--contour', 'Voir la facture');
    b.type = 'button';
    b.setAttribute('aria-label', 'Voir la facture du colis ' + colis.numero);
    b.addEventListener('click', function () {
      var fin = attente(b, 'Ouverture…');
      API.admin.factureDuColis(colis.id).then(function (facture) {
        if (facture) { choisirVue('factures'); ouvrirFacture(facture); return; }
        if (!peut('invoices.create')) { toast('Ce colis n\u2019a pas encore de facture.'); return; }
        if (!window.confirm('Ce colis n\u2019a pas encore de facture. En créer une maintenant ?')) return;
        if (!colis.client_id) { toast('Colis sans client : facture impossible.', true); return; }
        // La base crée la facture, ou rend celle qu'un collègue vient de créer
        return API.admin.facturerColis(colis.id)
          .then(function (r) { return ajouterLienPaiement(r.facture); })
          .then(function (f) {
            toast('Facture ' + (f && f.numero ? f.numero : '') + ' créée.');
            choisirVue('factures');
            return chargerFactures();
          });
      }).catch(function (err) { toast(messageErreur(err), true); }).then(fin);
    });
    return b;
  }

  function afficherColis(nouveaux) {
    var c = etat.colis;
    corpsColis.textContent = '';
    c.lignes.forEach(function (colis) {
      var tr = el('tr');
      tr.setAttribute('data-id', colis.id);
      var choisi = etat.selection.indexOf(colis.id) >= 0;
      if (choisi) tr.classList.add('is-choisi');
      if (nouveaux && nouveaux.indexOf(colis.id) >= 0) tr.classList.add('is-nouveau');

      var tdCase = el('td', 'gs-tableau__case');
      var caseACocher = el('input');
      caseACocher.type = 'checkbox';
      caseACocher.checked = choisi;
      caseACocher.setAttribute('aria-label', 'Sélectionner le colis ' + colis.numero);
      caseACocher.setAttribute('data-choix', colis.id);
      tdCase.appendChild(caseACocher);
      tr.appendChild(tdCase);

      var tdNum = cellule('Colis');
      tdNum.appendChild(el('span', 'gs-cellule-num', colis.numero));
      if (colis.suivi_transporteur) tdNum.appendChild(el('span', 'gs-cellule-sous', colis.suivi_transporteur));
      tr.appendChild(tdNum);

      var tdClient = cellule('Client');
      tdClient.appendChild(el('span', 'gs-cellule-principale', colis.nom_client || 'Client supprimé'));
      tdClient.appendChild(el('span', 'gs-cellule-sous', [colis.code_client, colis.telephone_client].filter(Boolean).join(' · ')));
      tr.appendChild(tdClient);

      var tdContenu = cellule('Contenu');
      tdContenu.appendChild(el('span', '', colis.description || '—'));
      var detailsContenu = [colis.expediteur, colis.poids_lb != null && colis.poids_lb !== '' ? O.nombre(Number(colis.poids_lb)) + ' lb' : '']
        .filter(Boolean).join(' · ');
      if (detailsContenu) tdContenu.appendChild(el('span', 'gs-cellule-sous', detailsContenu));
      tr.appendChild(tdContenu);

      var tdService = cellule('Service');
      tdService.appendChild(el('span', '', SERVICES[colis.service] || colis.service));
      tdService.appendChild(el('span', 'gs-cellule-sous', [colis.destination, PAYS[colis.pays_destination]].filter(Boolean).join(', ')));
      tr.appendChild(tdService);

      var tdStatut = cellule('Statut');
      tdStatut.appendChild(badge(colis.statut));
      if (colis.lieu) tdStatut.appendChild(el('span', 'gs-cellule-sous', colis.lieu));
      tr.appendChild(tdStatut);

      var tdRecu = cellule('Reçu le');
      tdRecu.textContent = O.date(colis.recu_le || colis.cree_le, true);
      tr.appendChild(tdRecu);

      var tdMaj = cellule('Mis à jour');
      tdMaj.textContent = O.date(colis.maj_le, true);
      tr.appendChild(tdMaj);

      var tdActions = el('td', 'gs-cellule-actions');
      var bouton = el('button', 'gs-bouton gs-bouton--petit gs-bouton--sombre', 'Mettre à jour');
      bouton.type = 'button';
      bouton.setAttribute('data-maj', colis.id);
      bouton.setAttribute('aria-label', 'Mettre à jour le statut du colis ' + colis.numero);
      tdActions.appendChild(bouton);
      if (peut('invoices.view')) tdActions.appendChild(boutonFactureDuColis(colis));
      tdActions.appendChild(boutonEtiquette(colis, 'gs-bouton gs-bouton--petit gs-bouton--contour'));
      tr.appendChild(tdActions);

      corpsColis.appendChild(tr);
    });

    var vide = $('[data-vide="colis"]');
    vide.hidden = c.lignes.length > 0;
    if (!c.lignes.length) {
      vide.textContent = c.recherche || c.clientId || (c.statut && c.statut !== 'actifs')
        ? 'Aucun colis ne correspond à cette recherche.'
        : 'Aucun colis en cours. Cliquez sur « Enregistrer un colis » à la réception d’un paquet à Miami.';
    }
    $('.gs-tableau--colis').closest('.gs-tableau-cadre').hidden = !c.lignes.length;
    $('[data-plus="colis"]').hidden = c.lignes.length >= c.total;
    $('[data-total="colis"]').textContent = c.total ? String(c.total) : '';
    majSelection();
    $$('[data-filtre-statut]').forEach(function (b) {
      b.classList.toggle('is-actif', !c.clientId && !c.recherche && b.getAttribute('data-filtre-statut') === c.statut);
    });
  }

  // Recherche (avec un court délai pendant la frappe) et filtres
  var delaiRecherche = null;
  $('[data-recherche="colis"]').addEventListener('input', function (e) {
    clearTimeout(delaiRecherche);
    delaiRecherche = setTimeout(function () {
      etat.colis.recherche = e.target.value.trim();
      etat.colis.pages = 1;
      chargerColis();
    }, 300);
  });
  var filtre = $('[data-filtre-colis]');
  filtre.addEventListener('change', function () {
    etat.colis.statut = filtre.value;
    etat.colis.pages = 1;
    chargerColis();
  });
  $$('[data-filtre-statut]').forEach(function (b) {
    b.addEventListener('click', function () {
      var statut = b.getAttribute('data-filtre-statut');
      filtre.value = statut;
      etat.colis.statut = statut;
      etat.colis.recherche = '';
      $('[data-recherche="colis"]').value = '';
      retirerFiltreClient(false);
      etat.colis.pages = 1;
      choisirVue('colis');
      chargerColis();
    });
  });
  $('[data-vue-cible="clients"]').addEventListener('click', function () { choisirVue('clients'); });
  $('[data-plus="colis"]').addEventListener('click', function () {
    etat.colis.pages += 1;
    chargerColis();
  });

  function filtrerParClient(client) {
    etat.colis.clientId = client.id;
    etat.colis.clientCode = client.code;
    etat.colis.statut = '';
    filtre.value = '';
    etat.colis.recherche = '';
    $('[data-recherche="colis"]').value = '';
    etat.colis.pages = 1;
    $('[data-filtre-client-nom]').textContent = client.nom_complet + ' (' + client.code + ')';
    $('[data-filtre-client]').hidden = false;
    choisirVue('colis');
    chargerColis();
  }

  function retirerFiltreClient(recharger) {
    etat.colis.clientId = null;
    etat.colis.clientCode = '';
    $('[data-filtre-client]').hidden = true;
    if (recharger) {
      etat.colis.statut = 'actifs';
      filtre.value = 'actifs';
      chargerColis();
    }
  }
  $('[data-action="retirer-filtre-client"]').addEventListener('click', function () { retirerFiltreClient(true); });

  // Sélection de plusieurs colis
  function majSelection() {
    var n = etat.selection.length;
    $('[data-selection]').hidden = n === 0;
    $('[data-selection-nombre]').textContent = n + (n > 1 ? ' colis sélectionnés' : ' colis sélectionné');
    var tout = $('[data-tout-selectionner]');
    var affiches = etat.colis.lignes.length;
    tout.checked = affiches > 0 && n === affiches;
    tout.indeterminate = n > 0 && n < affiches;
  }

  corpsColis.addEventListener('change', function (e) {
    var id = e.target.getAttribute('data-choix');
    if (!id) return;
    if (e.target.checked) { if (etat.selection.indexOf(id) < 0) etat.selection.push(id); }
    else etat.selection = etat.selection.filter(function (x) { return x !== id; });
    e.target.closest('tr').classList.toggle('is-choisi', e.target.checked);
    majSelection();
  });
  $('[data-tout-selectionner]').addEventListener('change', function (e) {
    etat.selection = e.target.checked ? etat.colis.lignes.map(function (l) { return l.id; }) : [];
    afficherColis();
  });
  $('[data-action="deselectionner"]').addEventListener('click', function () {
    etat.selection = [];
    afficherColis();
  });
  // Toutes les étiquettes d'un coup : c'est ce qu'on veut après avoir
  // enregistré l'arrivée d'un lot.
  $('[data-action="etiquettes-groupe"]').addEventListener('click', function () {
    var ids = etat.selection;
    imprimerEtiquettes(etat.colis.lignes.filter(function (l) { return ids.indexOf(l.id) >= 0; }));
  });
  /* Supprimer les colis cochés. Irréversible : la base emporte aussi leur
     historique. On nomme donc ce qu'on va détruire, jusqu'à trois numéros. */
  $('[data-action="supprimer-groupe"]').addEventListener('click', function () {
    var ids = etat.selection.slice();
    if (!ids.length) return;
    var numeros = etat.colis.lignes
      .filter(function (l) { return ids.indexOf(l.id) >= 0; })
      .map(function (l) { return l.numero; });
    var quoi = numeros.length <= 3
      ? (numeros.length === 1 ? 'le colis ' : 'les colis ') + numeros.join(', ')
      : 'ces ' + ids.length + ' colis';
    if (!window.confirm('Supprimer définitivement ' + quoi + ' et leur historique ?\n'
                        + 'Cette action ne peut pas être annulée.')) return;
    Promise.all(ids.map(function (id) {
      return API.admin.supprimerColis(id).then(function () { return true; },
                                               function () { return false; });
    })).then(function (faits) {
      var reussis = faits.filter(Boolean).length;
      var rates = faits.length - reussis;
      etat.selection = [];
      chargerStatistiques();
      chargerColis();
      if (rates) toast(reussis + ' colis supprimé' + (reussis > 1 ? 's' : '') + ', '
                       + rates + ' non supprimé' + (rates > 1 ? 's' : '') + '.', true);
      else toast(reussis > 1 ? reussis + ' colis supprimés.' : 'Colis supprimé.');
    });
  });

  $('[data-action="statut-groupe"]').addEventListener('click', function () {
    if (etat.selection.length) ouvrirStatut(etat.selection.slice(), null);
  });

  corpsColis.addEventListener('click', function (e) {
    var b = e.target.closest('[data-maj]');
    if (!b) return;
    var id = b.getAttribute('data-maj');
    var colis = etat.colis.lignes.filter(function (l) { return l.id === id; })[0];
    if (colis) ouvrirStatut([id], colis);
  });

  /* ---- Clients ---------------------------------------------------------------- */
  var corpsClients = $('[data-lignes="clients"]');

  // Résumé par client : nombre de colis en cours, poids, montant, balance.
  // Chargé en même temps que la liste ; s'il échoue, la liste s'affiche quand
  // même, simplement sans les chiffres.
  var resumeParClient = {};

  function chargerClients() {
    var c = etat.clients;
    return Promise.all([
      API.admin.clients({ recherche: c.recherche, page: 0, parPage: PAR_PAGE * c.pages }),
      API.admin.resumeClients().catch(function () { return []; })
    ]).then(function (r) {
      c.lignes = r[0].lignes;
      c.total = r[0].total;
      resumeParClient = {};
      (r[1] || []).forEach(function (e) { resumeParClient[e.client_id] = e; });
      afficherClients();
    }).catch(function (err) { toast(messageErreur(err), true); });
  }

  // Les statuts d'un client, du plus avancé au moins avancé, en petites pastilles
  function pastillesStatuts(statuts) {
    var boite = el('span', 'gs-statuts-mini');
    Object.keys(STATUTS).forEach(function (cle) {
      var n = statuts[cle];
      if (!n) return;
      var p = el('span', 'gs-statut-mini gs-statut-mini--' + cle);
      p.appendChild(el('i', 'gs-pastille gs-pastille--' + cle));
      p.appendChild(document.createTextNode(n + ' ' + STATUTS[cle].toLowerCase()));
      boite.appendChild(p);
    });
    return boite;
  }

  function afficherClients() {
    var c = etat.clients;
    corpsClients.textContent = '';
    c.lignes.forEach(function (client) {
      var tr = el('tr');
      var resume = resumeParClient[client.id] || { nbColis: 0, poids: 0, montant: 0, balance: 0, statuts: {}, majLe: null };
      if (resume.nbColis) tr.classList.add('is-actif-client');

      var tdCode = cellule('Identifiant');
      tdCode.appendChild(el('span', 'gs-cellule-num', client.code || '—'));
      tr.appendChild(tdCode);

      var tdNom = cellule('Client');
      tdNom.appendChild(el('span', 'gs-cellule-principale', client.nom_complet || '—'));
      tdNom.appendChild(el('span', 'gs-cellule-sous',
        [client.telephone, [client.ville, PAYS[client.pays] || client.pays].filter(Boolean).join(', ')]
          .filter(Boolean).join(' · ')));
      tdNom.appendChild(el('span', 'gs-cellule-sous', client.email || ''));
      tr.appendChild(tdNom);

      var tdNb = cellule('Colis en cours');
      tdNb.appendChild(el('span', 'gs-cellule-principale', resume.nbColis ? String(resume.nbColis) : '—'));
      if (client.cree_le) tdNb.appendChild(el('span', 'gs-cellule-sous', 'Inscrit le ' + O.date(client.cree_le)));
      tr.appendChild(tdNb);

      var tdStatuts = cellule('Statut des colis');
      if (resume.nbColis) tdStatuts.appendChild(pastillesStatuts(resume.statuts));
      else tdStatuts.appendChild(el('span', 'gs-cellule-sous', 'Aucun colis en cours'));
      tr.appendChild(tdStatuts);

      var tdPoids = cellule('Poids total');
      tdPoids.textContent = resume.poids ? O.nombre(resume.poids) + ' lb' : '—';
      tr.appendChild(tdPoids);

      var tdMontant = cellule('Montant total');
      tdMontant.textContent = resume.montant ? argent(resume.montant) : '—';
      tr.appendChild(tdMontant);

      var tdBalance = cellule('Balance');
      var soldeur = el('span', resume.balance > 0 ? 'gs-cellule-principale gs-balance-due' : 'gs-cellule-sous',
                       resume.balance > 0 ? argent(resume.balance) : 'Rien à payer');
      tdBalance.appendChild(soldeur);
      tr.appendChild(tdBalance);

      var tdDate = cellule('Dernière mise à jour');
      tdDate.textContent = resume.majLe ? O.date(resume.majLe, true) : '—';
      tr.appendChild(tdDate);

      var tdActions = el('td', 'gs-cellule-actions');
      var voir = el('button', 'gs-bouton gs-bouton--petit gs-bouton--contour', 'Ses colis');
      voir.type = 'button';
      voir.addEventListener('click', function () { filtrerParClient(client); });
      var ajouter = el('button', 'gs-bouton gs-bouton--petit gs-bouton--sombre', '+ Colis');
      ajouter.type = 'button';
      ajouter.setAttribute('aria-label', 'Enregistrer un colis pour ' + (client.nom_complet || client.code));
      ajouter.addEventListener('click', function () { ouvrirColis({ code: client.code }); });
      var sesFactures = el('button', 'gs-bouton gs-bouton--petit gs-bouton--contour', 'Ses factures');
      sesFactures.type = 'button';
      sesFactures.setAttribute('aria-label', 'Voir les factures de ' + (client.nom_complet || client.code));
      sesFactures.addEventListener('click', function () {
        choisirVue('factures');
        ouvrirFacture(null);
        champCodeFacture.value = client.code || '';
        champCodeFacture.dispatchEvent(new Event('input', { bubbles: true }));
      });
      tdActions.appendChild(voir);
      if (peut('invoices.create')) tdActions.appendChild(sesFactures);
      if (peut('shipments.create')) tdActions.appendChild(ajouter);
      tr.appendChild(tdActions);

      corpsClients.appendChild(tr);
    });
    var vide = $('[data-vide="clients"]');
    vide.hidden = c.lignes.length > 0;
    if (!c.lignes.length) {
      vide.textContent = c.recherche ? 'Aucun client ne correspond à cette recherche.'
        : 'Aucun client inscrit pour l’instant. Les comptes créés sur le site apparaissent ici, avec leur code GSE.';
    }
    $('.gs-tableau--clients').closest('.gs-tableau-cadre').hidden = !c.lignes.length;
    $('[data-plus="clients"]').hidden = c.lignes.length >= c.total;
    $('[data-total="clients"]').textContent = c.total ? String(c.total) : '';
  }

  var delaiClients = null;
  $('[data-recherche="clients"]').addEventListener('input', function (e) {
    clearTimeout(delaiClients);
    delaiClients = setTimeout(function () {
      etat.clients.recherche = e.target.value.trim();
      etat.clients.pages = 1;
      chargerClients();
    }, 300);
  });
  $('[data-plus="clients"]').addEventListener('click', function () {
    etat.clients.pages += 1;
    chargerClients();
  });


  /* ---- Factures -------------------------------------------------------------
     La base fait tous les comptes (outils/supabase-finances.sql) : le total à
     la création, le payé, le solde et l'état à chaque paiement. Cette page
     les affiche tels qu'elle les reçoit et ne décide de rien : pas de
     « Marquer payée », mais un paiement enregistré ; pas de suppression, mais
     une annulation motivée.
     -------------------------------------------------------------------------- */
  var corpsFactures = $('[data-lignes="factures"]');
  var dlgFacture = $('[data-dialogue="facture"]');
  var formFacture = $('form[data-form="facture"]', dlgFacture);
  var champCodeFacture = $('[data-code-client-facture]', formFacture);
  var infoClientFacture = $('[data-client-facture]', formFacture);
  var blocColisFacture = $('[data-colis-facture]', formFacture);
  var listeColisFacture = $('[data-liste-colis-facture]', formFacture);
  var blocPaiements = $('[data-bloc-paiements]', formFacture);
  var blocActionsFacture = $('[data-bloc-actions-facture]', formFacture);
  var factureEditee = null;
  var clientFacture = null;
  var rechercheFacture = null;

  var ETATS_FACTURE = {
    a_payer: 'À payer', partielle: 'Payée en partie', en_retard: 'En retard', payee: 'Payée', annulee: 'Annulée'
  };
  var MOYENS = {
    paypal: 'PayPal', banque: 'Virement bancaire', azul: 'Azul', moncash: 'MonCash', natcash: 'NatCash',
    especes: 'Espèces', transfert: 'Transfert d’argent', autre: 'Autre moyen'
  };
  var MESSAGE_FACTURE = {
    fr: 'Bonjour {nom}, votre facture {numero} chez GoShip Express s’élève à {montant}.{lien}',
    en: 'Hello {nom}, your GoShip Express invoice {numero} comes to {montant}.{lien}',
    es: 'Hola {nom}, su factura {numero} de GoShip Express asciende a {montant}.{lien}',
    ht: 'Bonjou {nom}, fakti ou {numero} nan GoShip Express se {montant}.{lien}'
  };
  // Une facture déjà payée en partie : on rappelle ce qui reste, pas le total
  var MESSAGE_RESTE = {
    fr: 'Bonjour {nom}, il reste {montant} à payer sur votre facture {numero} chez GoShip Express.{lien}',
    en: 'Hello {nom}, {montant} is still due on your GoShip Express invoice {numero}.{lien}',
    es: 'Hola {nom}, quedan {montant} por pagar en su factura {numero} de GoShip Express.{lien}',
    ht: 'Bonjou {nom}, ou rete {montant} pou peye sou fakti {numero} ou nan GoShip Express.{lien}'
  };

  // Lien de paiement par carte (Visa, Mastercard) d'une facture :
  // le lien d'Azul (ou d'un autre encaisseur) s'il est renseigné dans config.js,
  // sinon un lien PayPal fabriqué avec l'adresse et le montant.
  function lienCarte(numero, montant) {
    var cfg = window.GOSHIP_CONFIG || {};
    if (cfg.carteLien) return cfg.carteLien;
    if (!cfg.carteEmail) return '';
    return 'https://www.paypal.com/cgi-bin/webscr?cmd=_xclick' +
      '&business=' + encodeURIComponent(cfg.carteEmail) +
      '&currency_code=' + encodeURIComponent(cfg.carteDevise || 'USD') +
      '&amount=' + (Number(montant) || 0).toFixed(2) +
      '&item_name=' + encodeURIComponent('Goship Express — facture ' + numero) +
      '&no_shipping=1&no_note=1';
  }

  function argent(n) { return (Number(n) || 0).toFixed(2).replace('.', ',') + ' $'; }

  // Une facture de colis, à payer, sans aucun paiement : elle peut se regrouper
  function regroupable(f) {
    var lignes = f.facture_lignes || [];
    return f.statut === 'a_payer' && O.payeDe(f) === 0 && lignes.length > 0 &&
           lignes.every(function (l) { return l.colis_id; });
  }

  // Plusieurs chargements peuvent se croiser (filtre changé, mise à jour en
  // direct, paiement) : seule la réponse du plus récent s'affiche.
  var demandeFactures = 0;
  function chargerFactures() {
    var f = etat.factures;
    var numero = ++demandeFactures;
    if (peut('reports.view')) chargerResumeFactures();
    return API.admin.factures({ etat: f.statut, page: 0, parPage: PAR_PAGE * f.pages }).then(function (r) {
      if (numero !== demandeFactures) return;
      f.lignes = r.lignes || [];
      f.total = r.total || 0;
      afficherFactures();
    }).catch(function (err) { toast(messageErreur(err), true); });
  }

  // Les trois chiffres du haut, calculés par la base (resume_facturation)
  function chargerResumeFactures() {
    var zone = $('[data-resume-factures]');
    return API.admin.resumeFacturation().then(function (r) {
      function poser(cle, texte) { $('[data-resume="' + cle + '"]', zone).textContent = texte; }
      poser('a_encaisser', argent(r.a_encaisser));
      poser('ouvertes', r.ouvertes + (r.ouvertes > 1 ? ' factures ouvertes' : ' facture ouverte'));
      poser('montant_en_retard', argent(r.montant_en_retard));
      poser('en_retard', r.en_retard ? r.en_retard + (r.en_retard > 1 ? ' factures échues' : ' facture échue')
                                     : 'Aucune facture échue');
      poser('encaisse_mois', argent(r.encaisse_mois));
      poser('partielles', r.partielles ? r.partielles + (r.partielles > 1 ? ' payées en partie' : ' payée en partie') : '');
      zone.classList.toggle('gs-finances--retard', r.en_retard > 0);
      zone.hidden = false;
    }).catch(function () { zone.hidden = true; });
  }

  function badgeFacture(etatFacture) {
    return el('span', 'gs-badge gs-badge--facture-' + etatFacture, ETATS_FACTURE[etatFacture] || etatFacture);
  }

  function petitBouton(texte, classe, action) {
    var b = el('button', 'gs-bouton gs-bouton--petit ' + (classe || 'gs-bouton--contour'), texte);
    b.type = 'button';
    b.addEventListener('click', action);
    return b;
  }

  function afficherFactures() {
    var f = etat.factures;
    corpsFactures.textContent = '';
    f.lignes.forEach(function (facture) {
      var client = facture.clients || {};
      var t = O.totauxFacture(facture);
      var tr = el('tr', t.etat === 'annulee' ? 'gs-ligne-annulee' : '');

      var tdNum = cellule('Facture');
      tdNum.appendChild(el('span', 'gs-cellule-num', facture.numero || '—'));
      var nb = (facture.facture_lignes || []).length;
      if (nb) tdNum.appendChild(el('span', 'gs-cellule-sous', nb + (nb > 1 ? ' colis' : ' colis')));
      tr.appendChild(tdNum);

      var tdClient = cellule('Client');
      tdClient.appendChild(el('span', 'gs-cellule-principale', client.nom_complet || '—'));
      tdClient.appendChild(el('span', 'gs-cellule-sous', client.code || ''));
      tr.appendChild(tdClient);

      var tdMontant = cellule('Montant');
      tdMontant.appendChild(el('span', 'gs-cellule-principale', argent(t.grandTotal)));
      if (t.etat === 'payee') {
        tdMontant.appendChild(el('span', 'gs-cellule-sous', facture.moyen ? 'Payée · ' + (MOYENS[facture.moyen] || facture.moyen)
                                                                          : 'Payée'));
      } else if (t.paye > 0 && t.etat !== 'annulee') {
        tdMontant.appendChild(el('span', 'gs-cellule-sous', 'Payé ' + argent(t.paye) + ' · reste ' + argent(t.balance)));
      } else if (facture.lien_paiement && t.etat !== 'annulee') {
        tdMontant.appendChild(el('span', 'gs-cellule-sous', 'Lien de paiement prêt'));
      }
      tr.appendChild(tdMontant);

      var tdEtat = cellule('État');
      tdEtat.appendChild(badgeFacture(t.etat));
      if (t.etat === 'annulee') {
        if (facture.motif_annulation) tdEtat.appendChild(el('span', 'gs-cellule-sous', facture.motif_annulation));
      } else if (facture.echeance_le && t.balance > 0) {
        tdEtat.appendChild(el('span', 'gs-cellule-sous', (t.etat === 'en_retard' ? 'Échue le ' : 'Avant le ') +
                                                         O.date(facture.echeance_le)));
      }
      tr.appendChild(tdEtat);

      var tdDate = cellule('Créée le');
      tdDate.textContent = O.date(facture.cree_le);
      tr.appendChild(tdDate);

      var tdActions = el('td', 'gs-cellule-actions');
      if (t.etat !== 'annulee' && t.balance > 0 && peut('payments.create')) {
        tdActions.appendChild(petitBouton('Encaisser', 'gs-bouton--plein', function () { ouvrirPaiement(facture); }));
      }
      var imprimerBouton = petitBouton('Imprimer', null, function () { imprimerFacture(facture); });
      imprimerBouton.setAttribute('aria-label', 'Imprimer la facture ' + facture.numero);
      tdActions.appendChild(imprimerBouton);
      tdActions.appendChild(petitBouton(t.etat === 'annulee' ? 'Voir' : 'Détails', null,
                                        function () { ouvrirFacture(facture); }));

      if (client.telephone && t.etat !== 'annulee' && t.balance > 0) {
        tdActions.appendChild(petitBouton('WhatsApp', null, function () {
          var reste = t.paye > 0;
          var modele = (reste ? MESSAGE_RESTE : MESSAGE_FACTURE)[client.langue] || (reste ? MESSAGE_RESTE : MESSAGE_FACTURE).fr;
          var texte = modele
            .replace('{nom}', (client.nom_complet || '').split(' ')[0])
            .replace('{numero}', facture.numero)
            .replace('{montant}', argent(reste ? t.balance : t.grandTotal))
            .replace('{lien}', facture.lien_paiement ? '\n' + facture.lien_paiement : '');
          var numero = String(client.telephone).replace(/\D/g, '');
          window.open('https://wa.me/' + numero + '?text=' + encodeURIComponent(texte), '_blank', 'noopener');
        }));
      }
      if (t.etat !== 'annulee' && t.paye === 0 && peut('invoices.cancel')) {
        var annuler = petitBouton('Annuler', 'gs-bouton--danger', function () { demanderAnnulationFacture(facture); });
        annuler.setAttribute('aria-label', 'Annuler la facture ' + facture.numero);
        tdActions.appendChild(annuler);
      }
      tr.appendChild(tdActions);

      corpsFactures.appendChild(tr);
    });

    var vide = $('[data-vide="factures"]');
    vide.hidden = f.lignes.length > 0;
    if (!f.lignes.length) {
      vide.textContent = f.statut === 'a_payer'
        ? 'Aucune facture à payer. Créez-en une avec « Nouvelle facture ».'
        : 'Aucune facture pour ce filtre.';
    }
    $('.gs-tableau--factures').closest('.gs-tableau-cadre').hidden = !f.lignes.length;
    $('[data-plus="factures"]').hidden = f.lignes.length >= f.total;
    $('[data-total="factures"]').textContent = f.total ? String(f.total) : '';
  }

  $('[data-filtre-factures]').addEventListener('change', function (e) {
    etat.factures.statut = e.target.value;
    etat.factures.pages = 1;
    chargerFactures();
  });
  $('[data-plus="factures"]').addEventListener('click', function () {
    etat.factures.pages += 1;
    chargerFactures();
  });
  $('[data-action="nouvelle-facture"]').addEventListener('click', function () { ouvrirFacture(null); });

  function montrerClientFacture(client, message) {
    clientFacture = client;
    infoClientFacture.className = 'gs-champ__aide gs-client-trouve' + (client ? ' is-ok' : (message ? ' is-erreur' : ''));
    infoClientFacture.textContent = client
      ? '✓ ' + client.nom_complet + ' — ' + [client.ville, PAYS[client.pays]].filter(Boolean).join(', ')
      : (message || '');
    blocColisFacture.hidden = !client || !!factureEditee;
    if (client && !factureEditee) chargerColisDuClient(client);
    else listeColisFacture.textContent = '';
  }

  // Les colis proposés à la facturation, par identifiant. La liste ne contient
  // que ceux du client choisi : deux clients ne peuvent pas se retrouver sur la
  // même facture, ni par la souris ni par « tout sélectionner ».
  var colisFacturables = {};

  function chargerColisDuClient(client) {
    colisFacturables = {};
    listeColisFacture.textContent = 'Chargement…';
    API.admin.colis({ clientId: client.id, statut: '', parPage: 40 }).then(function (r) {
      listeColisFacture.textContent = '';
      if (!r.lignes.length) {
        listeColisFacture.appendChild(el('p', 'gs-champ__aide', 'Ce client n’a aucun colis enregistré.'));
        majTotauxFacture();
        return;
      }
      r.lignes.forEach(function (colis) {
        if (colis.client_id !== client.id) return;   // ceinture et bretelles
        colisFacturables[colis.id] = colis;
        var label = el('label');
        var input = document.createElement('input');
        input.type = 'checkbox';
        input.value = colis.id;
        input.setAttribute('data-colis-id', colis.id);
        input.setAttribute('data-colis-libelle', [colis.numero, colis.description].filter(Boolean).join(' — '));
        input.addEventListener('change', majTotauxFacture);
        var span = el('span');
        span.appendChild(el('strong', '', colis.numero));
        var poids = colis.poids_lb != null && colis.poids_lb !== '' ? O.nombre(Number(colis.poids_lb)) + ' lb' : '';
        span.appendChild(el('span', 'gs-cellule-sous',
          [colis.description, poids, STATUTS[colis.statut]].filter(Boolean).join(' · ')));
        label.appendChild(input);
        label.appendChild(span);
        label.appendChild(el('span', 'gs-choix-colis__prix', argent(O.prixColis(colis))));
        listeColisFacture.appendChild(label);
      });
      majTotauxFacture();
    }).catch(function () {
      listeColisFacture.textContent = '';
      listeColisFacture.appendChild(el('p', 'gs-champ__aide', 'Colis indisponibles pour l’instant.'));
      majTotauxFacture();
    });
  }

  function casesColisFacture() { return $$('[data-colis-id]', listeColisFacture); }
  function colisCoches() {
    return casesColisFacture().filter(function (i) { return i.checked; })
      .map(function (i) { return colisFacturables[i.getAttribute('data-colis-id')]; })
      .filter(Boolean);
  }

  // Aperçu du total pendant qu'on coche : prix inscrits sur les colis, frais
  // de service une seule fois. Ce n'est qu'un aperçu : la base refait le
  // compte à l'enregistrement (creer_facture), et c'est le sien qui compte.
  function majTotauxFacture() {
    var cases = casesColisFacture();
    var choisis = colisCoches();
    var totalColis = O.arrondi(choisis.reduce(function (s, c) { return s + O.prixColis(c); }, 0));
    var frais = choisis.length ? API.tarifs.fraisService : 0;
    var grand = O.arrondi(totalColis + frais);

    var tout = $('[data-tout-colis-facture]', formFacture);
    if (tout) {
      tout.checked = cases.length > 0 && choisis.length === cases.length;
      tout.indeterminate = choisis.length > 0 && choisis.length < cases.length;
      tout.disabled = !cases.length;
    }
    $('[data-compte-colis]', formFacture).textContent = cases.length
      ? choisis.length + ' / ' + cases.length + (cases.length > 1 ? ' colis cochés' : ' colis coché')
      : '';

    var recap = $('[data-recap-facture]');
    recap.hidden = !choisis.length;
    $$('[data-recap-emise]', recap).forEach(function (n) { n.hidden = true; });
    if (choisis.length) {
      $('[data-recap="colis"]', recap).textContent = argent(totalColis);
      $('[data-recap="frais"]', recap).textContent = argent(frais);
      $('[data-recap="grand"]', recap).textContent = argent(grand);
      formFacture.montant_usd.value = grand.toFixed(2);
      formFacture.montant_usd.readOnly = true;
      $('[data-aide-montant]', formFacture).textContent =
        choisis.length + (choisis.length > 1 ? ' colis' : ' colis') + ' + ' + argent(frais) + ' de frais de service.';
    } else if (!factureEditee) {
      formFacture.montant_usd.readOnly = false;
      $('[data-aide-montant]', formFacture).textContent = 'Cochez des colis, ou saisissez un montant libre.';
    }
  }

  $('[data-tout-colis-facture]', formFacture).addEventListener('change', function (e) {
    casesColisFacture().forEach(function (i) { i.checked = e.target.checked; });
    majTotauxFacture();
  });

  champCodeFacture.addEventListener('input', function () {
    clearTimeout(rechercheFacture);
    var valeur = champCodeFacture.value.trim();
    if (!valeur) { montrerClientFacture(null, ''); return; }
    rechercheFacture = setTimeout(function () {
      API.admin.chercherClient(valeur).then(function (client) {
        montrerClientFacture(client, client ? '' : 'Aucun client avec ce code.');
      }).catch(function () { montrerClientFacture(null, 'Recherche impossible.'); });
    }, 350);
  });

  // Les paiements d'une facture, du plus ancien au plus récent. Un paiement
  // annulé reste dans la liste, barré, avec son motif.
  function afficherPaiements(facture) {
    var liste = $('[data-liste-paiements]', formFacture);
    liste.textContent = '';
    var paiements = facture.paiements || [];
    paiements.forEach(function (p) {
      var li = el('li', 'gs-paiement' + (p.annule_le ? ' gs-paiement--annule' : ''));
      var corps = el('div', 'gs-paiement__corps');
      corps.appendChild(el('strong', 'gs-paiement__montant', argent(p.montant_usd)));
      corps.appendChild(el('span', 'gs-paiement__moyen',
        [MOYENS[p.moyen] || p.moyen, p.reference ? 'réf. ' + p.reference : '', O.date(p.paye_le)].filter(Boolean).join(' · ')));
      var notes = [];
      if (p.origine === 'reprise') notes.push('Montant payé enregistré avant le registre des paiements');
      if (p.origine === 'creation') notes.push('Payé à la création de la facture');
      if (p.note) notes.push(p.note);
      if (p.annule_le) notes.push('Annulé le ' + O.date(p.annule_le) + ' : ' + p.motif_annulation);
      if (notes.length) corps.appendChild(el('span', 'gs-paiement__note', notes.join(' — ')));
      li.appendChild(corps);
      if (!p.annule_le && peut('payments.cancel')) {
        var annuler = el('button', 'gs-lien-bouton gs-lien-bouton--danger', 'Annuler');
        annuler.type = 'button';
        annuler.setAttribute('aria-label', 'Annuler le paiement de ' + argent(p.montant_usd));
        annuler.addEventListener('click', function () { demanderAnnulationPaiement(facture, p); });
        li.appendChild(annuler);
      }
      liste.appendChild(li);
    });
    $('[data-paiements-vide]', formFacture).hidden = paiements.length > 0;
  }

  // La fenêtre d'une facture : nouvelle (client, colis, montant), ou émise
  // (échéance, note, lien ; ses totaux, ses paiements, et ce qu'on peut en faire)
  function ouvrirFacture(facture) {
    factureEditee = facture;
    formFacture.reset();
    erreurFormulaire(formFacture, '');
    $('[data-dialogue-titre]', dlgFacture).textContent = facture ? 'Facture ' + facture.numero : 'Nouvelle facture';
    blocColisFacture.hidden = true;
    listeColisFacture.textContent = '';
    colisFacturables = {};
    $('[data-recap-facture]').hidden = true;
    $('[data-compte-colis]', formFacture).textContent = '';
    formFacture.montant_usd.readOnly = false;
    blocPaiements.hidden = !facture;
    blocActionsFacture.hidden = true;
    var annulee = $('[data-facture-annulee]', formFacture);
    annulee.hidden = true;
    var enregistrer = $('button[type="submit"]', formFacture);
    enregistrer.hidden = false;
    $$('input, textarea', formFacture).forEach(function (n) { n.disabled = false; });

    if (facture) {
      var client = facture.clients || {};
      var t = O.totauxFacture(facture);
      champCodeFacture.value = client.code || '';
      champCodeFacture.readOnly = true;
      clientFacture = { id: facture.client_id, nom_complet: client.nom_complet, code: client.code };
      infoClientFacture.className = 'gs-champ__aide gs-client-trouve is-ok';
      infoClientFacture.textContent = '✓ ' + (client.nom_complet || '') + ' · ' + ETATS_FACTURE[t.etat];
      formFacture.montant_usd.value = t.grandTotal.toFixed(2);
      formFacture.echeance_le.value = facture.echeance_le || '';
      formFacture.lien_paiement.value = facture.lien_paiement || '';
      formFacture.note.value = facture.note || '';
      // Les totaux tels que la base les a arrêtés et tels que les paiements
      // les ont amenés : rien n'est recalculé ici.
      var recap = $('[data-recap-facture]');
      $('[data-recap="colis"]', recap).textContent = argent(t.colis);
      $('[data-recap="frais"]', recap).textContent = argent(t.frais);
      $('[data-recap="grand"]', recap).textContent = argent(t.grandTotal);
      $('[data-recap="paye"]', recap).textContent = argent(t.paye);
      $('[data-recap="balance"]', recap).textContent = argent(t.balance);
      $$('[data-recap-emise]', recap).forEach(function (n) { n.hidden = false; });
      recap.hidden = false;
      $('[data-aide-montant]', formFacture).textContent = 'Total arrêté à la création de la facture.';
      // Une facture de colis garde le total de ses colis : la base refuse
      // qu'on le change. Celui d'une facture libre, oui, jamais sous le payé.
      formFacture.montant_usd.readOnly = (facture.facture_lignes || []).some(function (l) { return l.colis_id; });
      afficherPaiements(facture);
      $('[data-action="encaisser-facture"]', formFacture).hidden = t.etat === 'annulee' || t.balance <= 0;
      if (t.etat === 'annulee') {
        annulee.textContent = 'Annulée le ' + O.date(facture.annulee_le || facture.cree_le) +
          (facture.motif_annulation ? ' — ' + facture.motif_annulation : '') + '. Elle garde son numéro et ne se modifie plus.';
        annulee.hidden = false;
        enregistrer.hidden = true;
        $$('input, textarea', formFacture).forEach(function (n) { n.disabled = true; });
      } else {
        var regrouper = regroupable(facture) && peut('invoices.create') && peut('invoices.cancel');
        var annulable = t.paye === 0 && peut('invoices.cancel');
        $('[data-action="regrouper-facture"]', formFacture).hidden = !regrouper;
        $('[data-action="annuler-facture"]', formFacture).hidden = !annulable;
        blocActionsFacture.hidden = !regrouper && !annulable;
        // Sans invoices.edit, la facture se consulte sans se modifier
        if (!peut('invoices.edit')) {
          enregistrer.hidden = true;
          $$('input, textarea', formFacture).forEach(function (n) { n.disabled = true; });
        }
      }
    } else {
      cleFacture = nouvelleCle();
      champCodeFacture.readOnly = false;
      clientFacture = null;
      infoClientFacture.textContent = '';
      infoClientFacture.className = 'gs-champ__aide gs-client-trouve';
      $('[data-aide-montant]', formFacture).textContent = 'Cochez des colis, ou saisissez un montant libre.';
    }
    if (!dlgFacture.open) dlgFacture.showModal();
  }

  var cleFacture = null;

  formFacture.addEventListener('submit', function (e) {
    e.preventDefault();
    erreurFormulaire(formFacture, '');
    if (!clientFacture) { erreurFormulaire(formFacture, 'Indiquez d’abord le code du client.'); return; }
    var montant = Number(String(formFacture.montant_usd.value).replace(',', '.'));
    if (!(montant >= 0)) { erreurFormulaire(formFacture, 'Indiquez le montant de la facture.'); return; }

    var choisis = colisCoches();
    // Une facture appartient à un seul client. La liste n'en propose jamais
    // d'autres, mais on refuse quand même plutôt que d'émettre un document faux.
    var intrus = choisis.filter(function (c) { return c.client_id && c.client_id !== clientFacture.id; });
    if (intrus.length) {
      erreurFormulaire(formFacture, 'Un colis sélectionné appartient à un autre client : une facture ne peut en regrouper qu’un seul.');
      return;
    }

    var champs = {
      client_id: clientFacture.id,
      montant_usd: montant,
      echeance_le: formFacture.echeance_le.value || null,
      lien_paiement: formFacture.lien_paiement.value.trim(),
      note: formFacture.note.value.trim()
    };

    // Une nouvelle facture : la base fait les comptes (prix des colis, frais
    // de service une fois). Le montant saisi ne compte que pour une facture
    // sans colis. Une facture émise : seuls l'échéance, le lien, la note — et
    // le total d'une facture libre — se changent.
    var bouton = $('button[type="submit"]', formFacture);
    var fin = attente(bouton, 'Enregistrement…');
    var action = factureEditee
      ? API.admin.modifierFacture(factureEditee.id, champs)
      : API.admin.creerFacture(champs, choisis.map(function (c) { return c.id; }), cleFacture)
          .then(function (r) {
            cleFacture = null;
            // Aucun lien fourni : on en fabrique un avec l'adresse PayPal des réglages
            return champs.lien_paiement ? r.facture : ajouterLienPaiement(r.facture);
          });
    action.then(function (f) {
      dlgFacture.close();
      toast(factureEditee ? 'Facture mise à jour.' : 'Facture ' + (f && f.numero ? f.numero : '') + ' créée.');
      return chargerFactures();
    }).catch(function (err) {
      erreurFormulaire(formFacture, messageErreur(err));
    }).then(fin);
  });

  // Après un paiement ou une annulation : la liste, et la fenêtre de la
  // facture si elle est ouverte, montrent ce que la base vient de répondre.
  function apresFinances(facture, message) {
    toast(message);
    if (dlgFacture.open && factureEditee && facture && factureEditee.id === facture.id) {
      ouvrirFacture(facture);
    }
    return chargerFactures();
  }

  /* ---- Encaisser un paiement ------------------------------------------------ */
  var dlgPaiement = $('[data-dialogue="paiement"]');
  var formPaiement = $('form[data-form="paiement"]', dlgPaiement);
  var facturePayee = null;
  var clePaiement = null;

  function dateDuJour() {
    var d = new Date();
    return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
  }

  function ouvrirPaiement(facture) {
    facturePayee = facture;
    clePaiement = nouvelleCle();
    formPaiement.reset();
    erreurFormulaire(formPaiement, '');
    var t = O.totauxFacture(facture);
    $('[data-paiement-facture]', dlgPaiement).textContent =
      'Facture ' + facture.numero + ' · ' + ((facture.clients || {}).nom_complet || '');
    $('[data-paiement-recap="total"]', dlgPaiement).textContent = argent(t.grandTotal);
    $('[data-paiement-recap="paye"]', dlgPaiement).textContent = argent(t.paye);
    $('[data-paiement-recap="solde"]', dlgPaiement).textContent = argent(t.balance);
    formPaiement.montant_usd.value = t.balance.toFixed(2);
    formPaiement.montant_usd.max = t.balance.toFixed(2);
    formPaiement.paye_le.value = dateDuJour();
    formPaiement.paye_le.max = dateDuJour();
    dlgPaiement.showModal();
    formPaiement.moyen.focus();
  }

  formPaiement.addEventListener('submit', function (e) {
    e.preventDefault();
    erreurFormulaire(formPaiement, '');
    var t = O.totauxFacture(facturePayee);
    var montant = Number(String(formPaiement.montant_usd.value).replace(',', '.'));
    if (!(montant > 0)) { erreurFormulaire(formPaiement, 'Indiquez le montant reçu.'); return; }
    if (montant > t.balance) {
      erreurFormulaire(formPaiement, 'Il ne reste que ' + argent(t.balance) + ' à payer sur cette facture.');
      return;
    }
    if (!formPaiement.moyen.value) { erreurFormulaire(formPaiement, 'Indiquez comment le client a payé.'); return; }
    // Reçu aujourd'hui : l'heure exacte. Un autre jour : midi, heure locale.
    var jour = formPaiement.paye_le.value;
    var payeLe = !jour || jour === dateDuJour() ? new Date().toISOString() : new Date(jour + 'T12:00:00').toISOString();
    var bouton = $('button[type="submit"]', formPaiement);
    var fin = attente(bouton, 'Enregistrement…');
    API.admin.enregistrerPaiement(facturePayee.id, {
      montant_usd: montant, moyen: formPaiement.moyen.value, reference: formPaiement.reference.value.trim(),
      paye_le: payeLe, note: formPaiement.note.value.trim()
    }, clePaiement).then(function (r) {
      clePaiement = null;
      dlgPaiement.close();
      var f = r.facture;
      var tf = O.totauxFacture(f);
      return majLienPaiement(f).then(function () {
        return apresFinances(f, (r.deja ? 'Paiement déjà enregistré. ' : 'Paiement de ' + argent(r.paiement.montant_usd) +
          ' enregistré. ') + (tf.balance > 0 ? 'Reste ' + argent(tf.balance) + ' à payer.' : 'Facture ' + f.numero + ' soldée.'));
      });
    }).catch(function (err) {
      erreurFormulaire(formPaiement, messageErreur(err));
    }).then(fin);
  });

  $('[data-action="encaisser-facture"]', formFacture).addEventListener('click', function () {
    if (factureEditee) ouvrirPaiement(factureEditee);
  });

  // Un lien PayPal fabriqué ici porte un montant. Après un acompte, il doit
  // demander ce qui reste, pas le total : sinon le client paierait deux fois.
  // Un lien collé à la main (Azul…) n'est pas touché.
  function majLienPaiement(f) {
    var t = O.totauxFacture(f);
    if (!f.lien_paiement || t.balance <= 0 || t.etat === 'annulee') return Promise.resolve(f);
    if (!/^https:\/\/www\.paypal\.com\/cgi-bin\/webscr\?cmd=_xclick&/.test(f.lien_paiement)) return Promise.resolve(f);
    var lien = lienCarte(f.numero, t.balance);
    if (!lien || lien === f.lien_paiement) return Promise.resolve(f);
    return API.admin.poserLienPaiement(f.id, lien)
      .then(function () { f.lien_paiement = lien; return f; })
      .catch(function () { return f; });
  }

  /* ---- Annuler, avec son motif ------------------------------------------------ */
  var dlgMotif = $('[data-dialogue="motif"]');
  var formMotif = $('form[data-form="motif"]', dlgMotif);
  var actionMotif = null;

  function demanderMotif(options, action) {
    actionMotif = action;
    formMotif.reset();
    erreurFormulaire(formMotif, '');
    $('[data-motif-titre]', dlgMotif).textContent = options.titre;
    $('[data-motif-sous-titre]', dlgMotif).textContent = options.sousTitre || '';
    $('[data-motif-aide]', dlgMotif).textContent = options.aide || '';
    var valider = $('[data-motif-valider]', dlgMotif);
    valider.textContent = options.bouton;
    valider.removeAttribute('data-libelle');
    dlgMotif.showModal();
    formMotif.motif.focus();
  }

  formMotif.addEventListener('submit', function (e) {
    e.preventDefault();
    erreurFormulaire(formMotif, '');
    var motif = formMotif.motif.value.trim();
    if (!motif) { erreurFormulaire(formMotif, 'Indiquez le motif : il reste au journal.'); return; }
    var bouton = $('[data-motif-valider]', dlgMotif);
    var fin = attente(bouton, 'Annulation…');
    actionMotif(motif).then(function () {
      dlgMotif.close();
    }).catch(function (err) {
      erreurFormulaire(formMotif, messageErreur(err));
    }).then(fin);
  });

  function demanderAnnulationFacture(facture) {
    demanderMotif({
      titre: 'Annuler la facture ' + facture.numero,
      sousTitre: ((facture.clients || {}).nom_complet || '') + ' · ' + argent(facture.montant_usd),
      aide: 'La facture ne sera pas supprimée : elle garde son numéro et reste consultable, marquée « Annulée ». ' +
            'Ses colis pourront être facturés à nouveau.',
      bouton: 'Annuler la facture'
    }, function (motif) {
      return API.admin.annulerFacture(facture.id, motif).then(function (r) {
        return apresFinances(r.facture, 'Facture ' + facture.numero + ' annulée.');
      });
    });
  }

  function demanderAnnulationPaiement(facture, paiement) {
    demanderMotif({
      titre: 'Annuler le paiement de ' + argent(paiement.montant_usd),
      sousTitre: 'Facture ' + facture.numero + ' · ' + (MOYENS[paiement.moyen] || paiement.moyen) + ' · ' +
                 O.date(paiement.paye_le),
      aide: 'Le paiement restera visible, barré, avec ce motif. Le solde de la facture remonte d’autant. ' +
            'S’il s’agissait d’une erreur de saisie, enregistrez ensuite le bon paiement.',
      bouton: 'Annuler le paiement'
    }, function (motif) {
      return API.admin.annulerPaiement(paiement.id, motif).then(function (r) {
        return apresFinances(r.facture, r.deja ? 'Ce paiement était déjà annulé.' : 'Paiement annulé.');
      });
    });
  }

  $('[data-action="annuler-facture"]', formFacture).addEventListener('click', function () {
    if (factureEditee) demanderAnnulationFacture(factureEditee);
  });

  /* ---- Regrouper les factures d'un client --------------------------------- */
  var dlgRegroupement = $('[data-dialogue="regroupement"]');
  var formRegroupement = $('form[data-form="regroupement"]', dlgRegroupement);
  var listeRegroupement = $('[data-liste-regroupement]', dlgRegroupement);
  var facturesRegroupables = {};
  var cleRegroupement = null;
  var apercuRegroupement = 0;

  function ouvrirRegroupement(facture) {
    cleRegroupement = nouvelleCle();
    facturesRegroupables = {};
    erreurFormulaire(formRegroupement, '');
    $('[data-regroupement-client]', dlgRegroupement).textContent = (facture.clients || {}).nom_complet || '';
    listeRegroupement.textContent = 'Chargement…';
    $('[data-recap-regroupement]', dlgRegroupement).hidden = true;
    dlgRegroupement.showModal();
    API.admin.factures({ client_id: facture.client_id, etat: 'a_payer', parPage: 200 }).then(function (r) {
      listeRegroupement.textContent = '';
      var candidates = (r.lignes || []).filter(regroupable);
      candidates.forEach(function (f) {
        facturesRegroupables[f.id] = f;
        var label = el('label', 'gs-regroupement__choix');
        var input = document.createElement('input');
        input.type = 'checkbox';
        input.value = f.id;
        input.checked = f.id === facture.id;
        input.addEventListener('change', majApercuRegroupement);
        var carte = el('div', 'gs-regroupement__carte');
        carte.appendChild(el('strong', '', f.numero));
        carte.appendChild(el('b', '', argent(f.montant_usd)));
        carte.appendChild(el('small', '', (f.facture_lignes || []).map(function (l) {
          return (l.colis && l.colis.numero) || l.libelle;
        }).join(', ') + ' · ' + O.date(f.cree_le)));
        label.appendChild(input);
        label.appendChild(carte);
        listeRegroupement.appendChild(label);
      });
      if (candidates.length < 2) {
        listeRegroupement.appendChild(el('p', 'gs-champ__aide',
          'Ce client n’a pas d’autre facture de colis à payer sans paiement : rien à regrouper.'));
      }
      majApercuRegroupement();
    }).catch(function (err) {
      listeRegroupement.textContent = '';
      erreurFormulaire(formRegroupement, messageErreur(err));
    });
  }

  function facturesCochees() {
    return $$('input[type="checkbox"]', listeRegroupement).filter(function (i) { return i.checked; })
      .map(function (i) { return facturesRegroupables[i.value]; }).filter(Boolean);
  }

  // L'aperçu vient de la base (calculer_facture) : c'est elle qui facturera
  function majApercuRegroupement() {
    var cochees = facturesCochees();
    var recap = $('[data-recap-regroupement]', dlgRegroupement);
    $('[data-regroupement-valider]', dlgRegroupement).disabled = cochees.length < 2;
    if (cochees.length < 2) { recap.hidden = true; return; }
    var numero = ++apercuRegroupement;
    var colis = [];
    cochees.forEach(function (f) { (f.facture_lignes || []).forEach(function (l) { colis.push(l.colis_id); }); });
    API.admin.calculerFacture(colis).then(function (c) {
      if (numero !== apercuRegroupement) return;   // une coche plus récente a déjà répondu
      var avant = O.arrondi(cochees.reduce(function (s, f) { return s + Number(f.montant_usd); }, 0));
      $('[data-regroupement-avant]', dlgRegroupement).textContent = 'Aujourd’hui, ' + cochees.length + ' factures';
      $('[data-regroupement="avant"]', dlgRegroupement).textContent = argent(avant);
      $('[data-regroupement="colis"]', dlgRegroupement).textContent = argent(c.sous_total);
      $('[data-regroupement="frais"]', dlgRegroupement).textContent = argent(c.frais_service);
      $('[data-regroupement="total"]', dlgRegroupement).textContent = argent(c.total);
      recap.hidden = false;
    }).catch(function () { recap.hidden = true; });
  }

  formRegroupement.addEventListener('submit', function (e) {
    e.preventDefault();
    erreurFormulaire(formRegroupement, '');
    var cochees = facturesCochees();
    if (cochees.length < 2) { erreurFormulaire(formRegroupement, 'Cochez au moins deux factures.'); return; }
    var bouton = $('[data-regroupement-valider]', dlgRegroupement);
    var fin = attente(bouton, 'Regroupement…');
    API.admin.regrouperFactures(cochees.map(function (f) { return f.id; }), cleRegroupement).then(function (r) {
      cleRegroupement = null;
      dlgRegroupement.close();
      if (dlgFacture.open) dlgFacture.close();
      return ajouterLienPaiement(r.facture).then(function () {
        toast('Nouvelle facture ' + r.facture.numero + ' (' + argent(r.facture.montant_usd) + ') : ' +
              r.annulees.length + ' factures regroupées.');
        return chargerFactures();
      });
    }).catch(function (err) {
      erreurFormulaire(formRegroupement, messageErreur(err));
    }).then(fin);
  });

  $('[data-action="regrouper-facture"]', formFacture).addEventListener('click', function () {
    if (factureEditee) ouvrirRegroupement(factureEditee);
  });

  /* ---- Contrôle de la facturation ------------------------------------------- */
  var dlgControle = $('[data-dialogue="controle"]');
  var GRAVITES = { erreur: 'Erreur', attention: 'À regarder', info: 'Pour info' };

  function ligneAnomalie(a) {
    var li = el('li', 'gs-anomalie gs-anomalie--' + a.gravite);
    li.appendChild(el('span', 'gs-anomalie__gravite', GRAVITES[a.gravite] || a.gravite));
    var texte = el('span', 'gs-anomalie__texte');
    if (a.numero) texte.appendChild(el('strong', '', a.numero + ' '));
    texte.appendChild(document.createTextNode(a.detail));
    li.appendChild(texte);
    return li;
  }

  $('[data-action="controler-factures"]').addEventListener('click', function () {
    var liste = $('[data-liste-anomalies]', dlgControle);
    var resume = $('[data-controle-resume]', dlgControle);
    liste.textContent = 'Contrôle en cours…';
    resume.textContent = '';
    dlgControle.showModal();
    API.admin.anomaliesFacturation().then(function (anomalies) {
      liste.textContent = '';
      var compte = { erreur: 0, attention: 0, info: 0 };
      anomalies.forEach(function (a) { compte[a.gravite] = (compte[a.gravite] || 0) + 1; });
      resume.textContent = compte.erreur || compte.attention
        ? compte.erreur + ' erreur' + (compte.erreur > 1 ? 's' : '') + ' · ' + compte.attention + ' à regarder · ' +
          compte.info + ' pour info'
        : 'Rien d’anormal' + (compte.info ? ' · ' + compte.info + ' remarque' + (compte.info > 1 ? 's' : '') + ' pour info' : '');
      anomalies.filter(function (a) { return a.gravite !== 'info'; }).forEach(function (a) { liste.appendChild(ligneAnomalie(a)); });
      var infos = anomalies.filter(function (a) { return a.gravite === 'info'; });
      if (infos.length) {
        var details = el('details', 'gs-anomalies__infos');
        details.appendChild(el('summary', '', infos.length + ' remarque' + (infos.length > 1 ? 's' : '') + ' pour information'));
        var sous = el('ul', 'gs-anomalies');
        infos.forEach(function (a) { sous.appendChild(ligneAnomalie(a)); });
        details.appendChild(sous);
        var li = el('li', 'gs-anomalies__groupe');
        li.appendChild(details);
        liste.appendChild(li);
      }
      if (!anomalies.length) liste.appendChild(el('li', 'gs-anomalie', 'Aucune incohérence trouvée.'));
    }).catch(function (err) {
      liste.textContent = '';
      liste.appendChild(el('li', 'gs-anomalie gs-anomalie--erreur', messageErreur(err)));
    });
  });

  /* ---- Équipe ------------------------------------------------------------------
     Qui fait partie de l'équipe, avec quel rôle (users.view), et, pour qui a
     roles.manage, le formulaire qui donne un rôle. La base refuse d'elle-même
     tout le reste : changer son propre rôle, retirer le dernier
     administrateur, donner un rôle sans en avoir le droit.
     -------------------------------------------------------------------------- */
  var corpsEquipe = $('[data-lignes="equipe"]');
  var formRole = $('form[data-form="role"]');
  var LIBELLES_PERMISSIONS = {
    'clients.view': 'Voir les clients', 'clients.create': 'Créer un client', 'clients.edit': 'Modifier un client',
    'shipments.view': 'Voir les colis', 'shipments.create': 'Enregistrer un colis', 'shipments.edit': 'Modifier un colis',
    'shipments.delete': 'Supprimer un colis', 'shipments.scan': 'Scanner',
    'shipments.change_status': 'Changer un statut', 'shipments.correct': 'Corriger une étape',
    'shipments.view_history': 'Historique interne',
    'invoices.view': 'Voir les factures', 'invoices.create': 'Créer une facture', 'invoices.edit': 'Modifier une facture',
    'invoices.cancel': 'Annuler une facture',
    'payments.view': 'Voir les paiements', 'payments.create': 'Encaisser', 'payments.cancel': 'Annuler un paiement',
    'reports.view': 'Chiffres et contrôle de la facturation',
    'users.view': 'Voir l’équipe', 'roles.manage': 'Donner un rôle', 'settings.manage': 'Réglages du site',
    'audit_logs.view': 'Journal d’audit'
  };

  function chargerEquipe() {
    return API.admin.equipe().then(afficherEquipe).catch(function (err) { toast(messageErreur(err), true); });
  }

  function afficherEquipe(membres) {
    corpsEquipe.textContent = '';
    membres.forEach(function (m) {
      var tr = el('tr');
      var tdNom = cellule('Nom');
      tdNom.appendChild(el('span', 'gs-cellule-principale', (m.nom_complet || '—') + (m.moi ? ' (vous)' : '')));
      tr.appendChild(tdNom);
      var tdEmail = cellule('E-mail');
      tdEmail.textContent = m.email || '';
      tr.appendChild(tdEmail);
      var tdRole = cellule('Rôle');
      tdRole.appendChild(el('span', 'gs-badge gs-badge--role-' + m.role, ROLES[m.role] || m.role));
      tr.appendChild(tdRole);
      var tdActions = el('td', 'gs-cellule-actions');
      if (peut('roles.manage') && !m.moi) {
        tdActions.appendChild(petitBouton('Changer le rôle', null, function () {
          formRole.compte.value = m.email || '';
          formRole.role.value = m.role;
          formRole.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
          formRole.role.focus();
        }));
      }
      tr.appendChild(tdActions);
      corpsEquipe.appendChild(tr);
    });
  }

  // La matrice des rôles, pour que chacun sache ce que son rôle permet
  (function () {
    var table = $('[data-matrice-roles]');
    var roles = ['admin', 'gerant', 'employe', 'client'];
    var thead = el('thead'), ligne = el('tr');
    ligne.appendChild(el('th', null, 'Permission'));
    roles.forEach(function (r) { ligne.appendChild(el('th', 'gs-centre', ROLES[r])); });
    thead.appendChild(ligne);
    table.appendChild(thead);
    var tbody = el('tbody');
    Object.keys(LIBELLES_PERMISSIONS).forEach(function (perm) {
      var tr = el('tr');
      var th = el('th', null, LIBELLES_PERMISSIONS[perm]);
      th.appendChild(el('span', 'gs-cellule-sous', perm));
      tr.appendChild(th);
      roles.forEach(function (r) {
        var liste = API.regles.permissionsDesRoles[r] || [];
        tr.appendChild(el('td', 'gs-centre', liste.indexOf(perm) >= 0 ? '✓'
                                              : (liste.indexOf(perm + ':own') >= 0 ? 'les siens' : '—')));
      });
      tbody.appendChild(tr);
    });
    table.appendChild(tbody);
  })();

  formRole.addEventListener('submit', function (e) {
    e.preventDefault();
    erreurFormulaire(formRole, '');
    var compte = formRole.compte.value.trim().toLowerCase();
    if (!compte) { erreurFormulaire(formRole, 'Indiquez l’e-mail du compte.'); return; }
    var bouton = $('button[type="submit"]', formRole);
    var fin = attente(bouton, 'Enregistrement…');
    API.admin.changerRole(compte, formRole.role.value).then(function (r) {
      toast(r.deja ? (r.compte.nom_complet || compte) + ' avait déjà ce rôle.'
                   : (r.compte.nom_complet || compte) + ' : ' + (ROLES[r.ancien_role] || r.ancien_role) + ' → ' +
                     (ROLES[r.nouveau_role] || r.nouveau_role) + '.');
      formRole.reset();
      return chargerEquipe();
    }).catch(function (err) {
      erreurFormulaire(formRole, messageErreur(err));
    }).then(fin);
  });

  /* ---- Onglets Colis / Clients / Factures -------------------------------------------------- */
  var onglets = $$('[data-onglet-vue]');
  function choisirVue(vue) {
    var onglet = $('[data-onglet-vue="' + vue + '"]');
    if (!onglet || onglet.hasAttribute('data-interdit')) vue = 'colis';
    etat.vue = vue;
    onglets.forEach(function (b) {
      var actif = b.getAttribute('data-onglet-vue') === vue;
      b.setAttribute('aria-selected', String(actif));
      b.tabIndex = actif ? 0 : -1;
    });
    $$('[data-vue]').forEach(function (v) { v.hidden = v.getAttribute('data-vue') !== vue; });
    // Les factures ne se rechargent qu'à leur propre changement : en ouvrant
    // l'onglet, on s'assure de ne pas regarder une liste d'il y a une heure.
    if (vue === 'factures') chargerFactures();
  }
  onglets.forEach(function (b, i) {
    b.addEventListener('click', function () { choisirVue(b.getAttribute('data-onglet-vue')); });
    b.addEventListener('keydown', function (e) {
      if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') return;
      var visibles = onglets.filter(function (o) { return !o.hasAttribute('data-interdit'); });
      var autre = visibles[(visibles.indexOf(b) + 1) % visibles.length];
      autre.focus();
      choisirVue(autre.getAttribute('data-onglet-vue'));
    });
  });

  /* ---- Fenêtres (enregistrer un colis, mettre à jour un statut) -------------- */
  $$('.gs-dialogue').forEach(function (d) {
    d.addEventListener('click', function (e) { if (e.target === d) d.close(); });
    $$('[data-action="fermer"]', d).forEach(function (b) { b.addEventListener('click', function () { d.close(); }); });
  });

  // Enregistrer ou modifier un colis
  var dlgColis = $('[data-dialogue="colis"]');
  var formColis = $('form[data-form="colis"]', dlgColis);
  var champCode = $('[data-code-client]', formColis);
  var infoClient = $('[data-client-trouve]', formColis);
  var listeClients = $('[data-completion-client]', formColis);
  var colisEdite = null;
  var clientChoisi = null;
  var recherchesClient = 0;
  var suggestions = [];
  var suggestionActive = -1;

  function montrerClient(client, message) {
    clientChoisi = client;
    infoClient.className = 'gs-champ__aide gs-client-trouve' + (client ? ' is-ok' : (message ? ' is-erreur' : ''));
    infoClient.textContent = client
      ? '✓ ' + client.nom_complet + ' — ' + [client.ville, client.region, PAYS[client.pays]].filter(Boolean).join(', ')
      : (message || '');
  }

  function prefillClient(client) {
    var f = formColis.elements;
    if (PAYS[client.pays] && client.pays !== 'US') f.pays_destination.value = client.pays;
    if (!f.destination.value) f.destination.value = client.ville || '';
  }

  // Liste déroulante sous le champ, quand plusieurs clients correspondent
  function fermerSuggestions() {
    suggestions = [];
    suggestionActive = -1;
    listeClients.hidden = true;
    listeClients.textContent = '';
    champCode.setAttribute('aria-expanded', 'false');
    champCode.removeAttribute('aria-activedescendant');
  }

  function surlignerSuggestion(index) {
    suggestionActive = index;
    $$('[role="option"]', listeClients).forEach(function (o, i) {
      var actif = i === index;
      o.classList.toggle('is-actif', actif);
      o.setAttribute('aria-selected', actif ? 'true' : 'false');
      if (actif) {
        champCode.setAttribute('aria-activedescendant', o.id);
        if (o.scrollIntoView) o.scrollIntoView({ block: 'nearest' });
      }
    });
    if (index < 0) champCode.removeAttribute('aria-activedescendant');
  }

  function choisirSuggestion(client) {
    champCode.value = client.code || '';
    montrerClient(client);
    if (!colisEdite) prefillClient(client);
    fermerSuggestions();
    champCode.focus();
  }

  function afficherSuggestions(clients) {
    listeClients.textContent = '';
    suggestions = clients;
    suggestionActive = -1;
    if (!clients.length) {
      var vide = document.createElement('p');
      vide.className = 'gs-completion__vide';
      vide.textContent = 'Aucun client ne correspond.';
      listeClients.appendChild(vide);
    } else {
      clients.forEach(function (client, i) {
        var bouton = document.createElement('button');
        bouton.type = 'button';
        bouton.id = 'col-client-' + i;
        bouton.className = 'gs-completion__item';
        bouton.setAttribute('role', 'option');
        bouton.setAttribute('aria-selected', 'false');
        var code = document.createElement('span');
        code.className = 'gs-completion__code';
        code.textContent = client.code || '—';
        bouton.appendChild(code);
        bouton.appendChild(document.createTextNode(' · ' + (client.nom_complet || '')));
        var detail = document.createElement('span');
        detail.className = 'gs-completion__det';
        detail.textContent = [client.email, client.ville].filter(Boolean).join(' — ');
        bouton.appendChild(detail);
        bouton.addEventListener('click', function () { choisirSuggestion(client); });
        listeClients.appendChild(bouton);
      });
    }
    listeClients.hidden = false;
    champCode.setAttribute('aria-expanded', 'true');
  }

  // Recherche par identifiant GSE, nom ou e-mail. Un identifiant complet est
  // résolu directement ; tout autre texte passe par la recherche multi-champs,
  // qui propose la liste des correspondances dès qu'il y en a plusieurs.
  function chercherParTexte(texte, numero, prefill) {
    return API.admin.clients({ recherche: texte, parPage: 8 }).then(function (r) {
      if (numero !== recherchesClient) return clientChoisi;
      var lignes = (r && r.lignes) || [];
      if (!lignes.length) {
        afficherSuggestions([]);
        montrerClient(null, 'Aucun client ne correspond à « ' + texte + ' ».');
        return null;
      }
      if (lignes.length === 1) {
        fermerSuggestions();
        montrerClient(lignes[0]);
        if (prefill) prefillClient(lignes[0]);
        return lignes[0];
      }
      afficherSuggestions(lignes);
      montrerClient(null, lignes.length + ' clients correspondent — choisissez dans la liste.');
      return null;
    }).catch(function (err) { fermerSuggestions(); montrerClient(null, messageErreur(err)); return null; });
  }

  function chercherClient(prefill) {
    var texte = champCode.value.trim();
    if (!texte) { fermerSuggestions(); montrerClient(null, ''); return Promise.resolve(null); }
    var numero = ++recherchesClient;
    infoClient.className = 'gs-champ__aide gs-client-trouve';
    infoClient.textContent = 'Recherche du client…';
    var code = API.normaliserCode(texte);
    if (code) {
      return API.admin.chercherClient(code).then(function (client) {
        if (numero !== recherchesClient) return clientChoisi;
        if (client) {
          fermerSuggestions();
          montrerClient(client);
          if (prefill) prefillClient(client);
          return client;
        }
        return chercherParTexte(texte, numero, prefill);
      }).catch(function (err) { montrerClient(null, messageErreur(err)); return null; });
    }
    if (texte.length < 2) { fermerSuggestions(); montrerClient(null, ''); return Promise.resolve(null); }
    return chercherParTexte(texte, numero, prefill);
  }

  /* ---- Prix du colis : poids x tarif -----------------------------------------
     Le tarif de la maison est 5 $/lb ; il reste remplaçable colis par colis
     pour un accord particulier. Le prix, lui, ne se saisit plus : c'est la
     base qui le calcule (outils/supabase-services.sql, regles_colis) et qui
     l'arrête. Le champ n'en montre qu'un aperçu, fait avec la même règle.
     -------------------------------------------------------------------------- */
  var champTarif = $('[data-tarif-lb]', formColis);
  // Le tarif à la livre change ce que paiera le client : réservé à qui peut
  // modifier les factures (la base refuse de toute façon un autre tarif).
  var champPrix = $('[data-prix-colis]', formColis);
  var aidePrix = $('[data-calcul-prix]', formColis);

  function nombreSaisi(valeur) {
    var n = Number(String(valeur == null ? '' : valeur).replace(',', '.').trim());
    return isFinite(n) ? n : NaN;
  }

  // Champ vide : le tarif de la maison. Zéro reste zéro (un envoi offert).
  function tarifSaisi() {
    if (!champTarif.value.trim()) return API.tarifs.parLivre;
    return nombreSaisi(champTarif.value);
  }

  function ecrireMontant(champ, valeur) {
    champ.value = O.arrondi(valeur).toFixed(2).replace('.', ',');
  }

  function recalculerPrix() {
    var poids = nombreSaisi(formColis.elements.poids_lb.value);
    var tarif = tarifSaisi();
    if (!(tarif >= 0)) {
      champPrix.value = '';
      aidePrix.textContent = 'Tarif invalide : un nombre de dollars par livre, 5 par défaut.';
      return;
    }
    // Un colis déjà enregistré garde le prix arrêté tant que ni son poids ni
    // son tarif ne changent : il a pu être facturé.
    if (colisEdite && colisEdite.prix_usd != null && poids === Number(colisEdite.poids_lb) &&
        tarif === O.tarifDe(colisEdite)) {
      ecrireMontant(champPrix, Number(colisEdite.prix_usd));
      aidePrix.textContent = 'Prix arrêté à l’enregistrement du colis.';
      return;
    }
    if (!(poids > 0)) {
      champPrix.value = '';
      aidePrix.textContent = 'Indiquez le poids : le prix se calcule tout seul, à ' + argent(tarif) + ' la livre.';
      return;
    }
    var prix = API.regles.prixTransport(poids, tarif);
    ecrireMontant(champPrix, prix);
    aidePrix.textContent = O.nombre(poids) + ' lb × ' + argent(tarif) + ' = ' + argent(prix) +
      (colisEdite ? ' · recalculé à l’enregistrement ; une facture déjà émise ne change pas.'
                  : ' · frais de service ' + argent(API.tarifs.fraisService) + ' ajoutés sur la facture.');
  }

  formColis.elements.poids_lb.addEventListener('input', recalculerPrix);
  champTarif.addEventListener('input', recalculerPrix);

  var delaiCode = null;
  champCode.addEventListener('input', function () {
    clearTimeout(delaiCode);
    clientChoisi = null;
    delaiCode = setTimeout(function () { chercherClient(!colisEdite); }, 300);
  });
  champCode.addEventListener('keydown', function (e) {
    if (listeClients.hidden || !suggestions.length) return;
    if (e.key === 'ArrowDown') { e.preventDefault(); surlignerSuggestion((suggestionActive + 1) % suggestions.length); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); surlignerSuggestion((suggestionActive - 1 + suggestions.length) % suggestions.length); }
    else if (e.key === 'Enter' && suggestionActive >= 0) { e.preventDefault(); choisirSuggestion(suggestions[suggestionActive]); }
    else if (e.key === 'Escape') { e.preventDefault(); fermerSuggestions(); }
    else if (e.key === 'Tab') fermerSuggestions();
  });
  // Un identifiant saisi en clair est remis au format GSE-0000, mais jamais un
  // nom ni un e-mail : « client2024@… » ne doit pas devenir « GSE-2024 ».
  champCode.addEventListener('blur', function () {
    if (clientChoisi && clientChoisi.code) { champCode.value = clientChoisi.code; return; }
    if (!/^\s*(gse)?[\s-]*\d{4,}\s*$/i.test(champCode.value)) return;
    var code = API.normaliserCode(champCode.value);
    if (code) champCode.value = code;
  });
  document.addEventListener('click', function (e) {
    if (e.target !== champCode && !listeClients.contains(e.target)) fermerSuggestions();
  });

  // Date et heure au format des champs du formulaire (heure locale)
  function deux(n) { return (n < 10 ? '0' : '') + n; }
  function valeurDate(d) { return d.getFullYear() + '-' + deux(d.getMonth() + 1) + '-' + deux(d.getDate()); }
  function valeurHeure(d) { return deux(d.getHours()) + ':' + deux(d.getMinutes()); }
  function dateHeureSaisie(date, heure) {
    var d = new Date(date + 'T' + (heure || '00:00'));
    return isNaN(d.getTime()) ? null : d;
  }

  /* ---- La facture d'un colis --------------------------------------------------
     Tout colis enregistré repart avec sa facture : la base les crée ensemble,
     dans la même transaction (creer_colis). Reste ici le lien de paiement,
     préparé dans la foulée quand les réglages le permettent.
     -------------------------------------------------------------------------- */
  function ajouterLienPaiement(f) {
    if (!f || f.lien_paiement) return Promise.resolve(f);
    var lien = lienCarte(f.numero, Number(f.montant_usd));
    if (!lien) return Promise.resolve(f);
    return API.admin.poserLienPaiement(f.id, lien)
      .then(function () { f.lien_paiement = lien; return f; })
      .catch(function () { return f; });   // sans lien, la facture reste valable
  }

  var cleColis = null;

  function ouvrirColis(options) {
    options = options || {};
    colisEdite = options.colis || null;
    cleColis = colisEdite ? null : nouvelleCle();
    formColis.reset();
    erreurFormulaire(formColis, '');
    fermerSuggestions();
    montrerClient(null, '');
    var f = formColis.elements;
    var reception = colisEdite && (colisEdite.recu_le || colisEdite.cree_le) ? new Date(colisEdite.recu_le || colisEdite.cree_le) : new Date();
    f.date_reception.value = valeurDate(reception);
    f.heure_reception.value = valeurHeure(reception);
    $('[data-bloc-etape]', formColis).hidden = !!colisEdite;
    $('[data-dialogue-titre]', dlgColis).textContent = colisEdite ? 'Modifier le colis ' + colisEdite.numero : 'Enregistrer un colis';
    var bouton = $('[data-envoyer]', formColis);
    bouton.removeAttribute('data-libelle');
    bouton.textContent = colisEdite ? 'Enregistrer les modifications' : 'Enregistrer le colis';
    if (colisEdite) {
      f.code.value = colisEdite.code_client || '';
      f.description.value = colisEdite.description || '';
      f.expediteur.value = colisEdite.expediteur || '';
      f.suivi_transporteur.value = colisEdite.suivi_transporteur || '';
      f.poids_lb.value = colisEdite.poids_lb != null ? String(colisEdite.poids_lb).replace('.', ',') : '';
      f.service.value = colisEdite.service;
      f.pays_destination.value = colisEdite.pays_destination;
      f.destination.value = colisEdite.destination || '';
      // Un colis déjà enregistré garde son prix tel quel : il a pu être
      // facturé, et sa facture ne doit pas bouger derrière son dos.
      champTarif.value = colisEdite.tarif_lb_usd != null ? String(colisEdite.tarif_lb_usd).replace('.', ',') : '';
      recalculerPrix();
    } else {
      f.code.value = options.code || etat.colis.clientCode || '';
      f.lieu.value = 'Miami (Medley), FL';
      champTarif.value = String(API.tarifs.parLivre);
      recalculerPrix();
    }
    champTarif.readOnly = !peut('invoices.edit');
    champTarif.title = champTarif.readOnly ? 'Tarif de la maison : un tarif particulier est réservé à qui peut modifier les factures' : '';
    dlgColis.showModal();
    if (f.code.value) chercherClient(!colisEdite);
    (f.code.value ? f.description : f.code).focus();
  }
  $('[data-action="nouveau-colis"]').addEventListener('click', function () { ouvrirColis(); });

  formColis.addEventListener('submit', function (e) {
    e.preventDefault();
    erreurFormulaire(formColis, '');
    var f = formColis.elements;
    var bouton = $('[data-envoyer]', formColis);
    // Ces contrôles ne font que prévenir plus tôt : la base refait les mêmes,
    // et c'est elle qui décide.
    var poids = String(f.poids_lb.value || '').replace(',', '.').trim();
    if (!poids || isNaN(Number(poids)) || Number(poids) <= 0) {
      erreurFormulaire(formColis, 'Indiquez le poids du colis, en livres (ex. 4,5).');
      f.poids_lb.focus();
      return;
    }
    if (!f.description.value.trim()) {
      erreurFormulaire(formColis, 'Décrivez le contenu du colis.');
      f.description.focus();
      return;
    }
    var reception = dateHeureSaisie(f.date_reception.value, f.heure_reception.value);
    if (!reception) {
      erreurFormulaire(formColis, 'Indiquez la date et l’heure de réception du colis.');
      f.date_reception.focus();
      return;
    }
    if (reception.getTime() > Date.now() + 36e5) {
      erreurFormulaire(formColis, 'La date de réception ne peut pas être dans le futur.');
      f.date_reception.focus();
      return;
    }
    attente(bouton, 'Enregistrement…');
    (clientChoisi ? Promise.resolve(clientChoisi) : chercherClient(false)).then(function (client) {
      if (!client) {
        attente(bouton);
        erreurFormulaire(formColis, 'Choisissez un client existant : identifiant GSE, nom ou e-mail.');
        f.code.focus();
        return;
      }
      var donnees = {
        client_id: client.id,
        description: f.description.value.trim(),
        expediteur: f.expediteur.value.trim(),
        recu_le: reception.toISOString(),
        suivi_transporteur: f.suivi_transporteur.value.trim(),
        poids_lb: Math.round(Number(poids) * 100) / 100,
        service: f.service.value,
        pays_destination: f.pays_destination.value,
        destination: f.destination.value.trim(),
        // Tel que saisi : la base lit « 5,5 » comme 5.5, et refuse ce qui
        // n'est pas un tarif (INVALID_RATE). Vide : le tarif de la maison.
        tarif_lb_usd: champTarif.value.trim() || null
      };
      // Ni prix ni statut : la base calcule l'un et fait naître le colis
      // « Reçu ». Le lieu et le message sont ceux de ce premier événement.
      var creation = !colisEdite;
      if (creation) {
        donnees.lieu = f.lieu.value.trim();
        donnees.note = f.note.value.trim();
      }
      var prevenir = creation && f.prevenir.checked;
      var action = creation ? API.admin.creerColis(donnees, cleColis)
                            : API.admin.modifierColis(colisEdite.id, donnees, colisEdite.maj_le);
      return action.then(function (r) {
        var colis = creation ? r.colis : r;
        attente(bouton);
        dlgColis.close();
        etat.vus[colis.id] = null;
        chargerStatistiques();
        chargerColis(true);
        if (!creation) { toast('Colis ' + colis.numero + ' modifié.'); return colis; }
        cleColis = null;
        if (r.deja) {
          // Second envoi de la même demande : la base a rendu le colis déjà
          // créé. Rien n'est fait deux fois, ni facture ni message au client.
          toast('Colis ' + colis.numero + ' déjà enregistré : rien n\u2019a été créé en double.');
          return colis;
        }
        // Colis et facture sont nés ensemble ; seul le lien de paiement reste
        // à poser, et son échec ne retire rien au reste.
        return ajouterLienPaiement(r.facture).then(function (facture) {
          if (prevenir) notifier([{ colis: colis, client: client }], 'recu', { apresEnregistrement: true });
          else toast('Colis ' + colis.numero + ' enregistré pour ' + client.nom_complet +
                     (facture ? ' · facture ' + facture.numero : '') + '.');
          if (etat.vue === 'factures') chargerFactures();
          return colis;
        });
      });
    }).catch(function (err) {
      attente(bouton);
      erreurFormulaire(formColis, messageErreur(err));
    });
  });

  // Mettre à jour le statut (un colis ou une sélection)
  var dlgStatut = $('[data-dialogue="statut"]');
  var formStatut = $('form[data-form="statut"]', dlgStatut);
  var cibleStatut = { ids: [], colis: null };
  var cleStatut = null;

  function ouvrirStatut(ids, colis) {
    cibleStatut = { ids: ids, colis: colis };
    formStatut.reset();
    erreurFormulaire(formStatut, '');
    var bouton = $('[data-envoyer]', formStatut);
    bouton.removeAttribute('data-libelle');
    bouton.textContent = 'Mettre à jour';
    $('[data-statut-cible]', dlgStatut).textContent = colis
      ? colis.numero + ' · ' + (colis.nom_client || 'Client supprimé') + (colis.code_client ? ' (' + colis.code_client + ')' : '')
      : ids.length + ' colis sélectionnés : le même statut sera appliqué à chacun.';
    $('[data-bloc-historique]', dlgStatut).hidden = !colis;
    $('[data-bloc-actions]', dlgStatut).hidden = !colis;
    $('[data-bloc-notifications]', dlgStatut).hidden = true;
    $('[data-action="prevenir-client"]', dlgStatut).hidden = !(colis && EVENEMENTS.indexOf(colis.statut) >= 0);
    var historique = $('[data-historique]', dlgStatut);
    historique.textContent = '';
    griserStatuts(null);
    cleStatut = nouvelleCle();
    formStatut.elements.motif.value = '';
    if (colis) {
      var radio = $('input[name="statut"][value="' + colis.statut + '"]', formStatut);
      if (radio) radio.checked = true;
      formStatut.elements.lieu.value = colis.lieu || '';
      formStatut.elements.note.value = colis.note || '';
      API.admin.historique(colis.id).then(function (h) {
        O.remplirHistorique(historique, h, { notes: true, libelle: libelleEvenement });
      }).catch(function () { /* historique facultatif */ });
      // Les statuts que ce colis ne peut pas prendre sont grisés. C'est la
      // base qui répond : elle seule connaît la règle et l'historique complet.
      // Sans réponse, rien n'est grisé et la base refusera le cas échéant.
      if (API.admin.statutsPossibles) {
        API.admin.statutsPossibles(colis.id).then(function (p) {
          if (cibleStatut.colis === colis) { griserStatuts(p.possibles, p.correction); majChoixStatut(); }
        }).catch(function () { /* simple confort d'affichage */ });
      }
      afficherNotificationsEnvoyees(colis.id);
    }
    majChoixStatut();
    dlgStatut.showModal();
    var coche = $('input[name="statut"]:checked', formStatut) || $('input[name="statut"]', formStatut);
    coche.focus();
  }

  // possibles : la liste des statuts permis, ou null pour tout laisser ouvert
  // (un lot mêle des colis à des étapes différentes : la base triera).
  // correction : l'étape d'avant, permise seulement comme correction (motif
  // obligatoire), ou null.
  var statutCorrection = null;
  function griserStatuts(possibles, correction) {
    statutCorrection = peut('shipments.correct') ? correction || null : null;
    $$('input[name="statut"]', formStatut).forEach(function (r) {
      var permis = !possibles || possibles.indexOf(r.value) >= 0 || r.value === statutCorrection;
      r.disabled = !permis;
      r.parentNode.title = !permis ? 'Transition non permise depuis le statut actuel'
        : (r.value === statutCorrection ? 'Retour à l\u2019étape précédente : correction, motif obligatoire' : '');
    });
  }

  // Le libellé d'un événement de l'historique. Les étapes gardent le nom de
  // leur statut ; les opérations internes et les corrections disent ce
  // qu'elles sont. Une étape annulée par une correction le dit aussi.
  var EVENEMENTS_INTERNES = { COLIS_INSPECTE: 'Inspecté', COLIS_CONSOLIDE: 'Consolidé', COLIS_CHARGE: 'Chargé' };
  function libelleEvenement(statut, h) {
    h = h || {};
    var texte;
    if (EVENEMENTS_INTERNES[h.type_evenement]) texte = EVENEMENTS_INTERNES[h.type_evenement] + ' (interne)';
    else if (h.type_evenement === 'CORRECTION') {
      texte = 'Correction → ' + (STATUTS[statut] || statut) +
        (h.metadonnees && h.metadonnees.motif ? ' — ' + h.metadonnees.motif : '');
    } else texte = STATUTS[statut] || statut;
    if (h.corrige) texte += ' (annulé par une correction)';
    if (h.auteur) texte += ' · ' + h.auteur;
    return texte;
  }

  // « Disponible en agence » : l'agence devient obligatoire et le client est prévenu
  var libelleLieu = $('[data-libelle-lieu]', formStatut);
  var libelleLieuOrigine = libelleLieu.innerHTML;
  function majChoixStatut() {
    var statut = ($('input[name="statut"]:checked', formStatut) || {}).value;
    var colis = cibleStatut.colis;
    // Le motif : pour un colis, quand le statut coché est une correction ;
    // pour un lot, toujours proposé (la base dira pour quels colis il manque).
    $('[data-bloc-motif]', formStatut).hidden = colis ? !(statut && statut === statutCorrection) : false;
    var disponible = statut === 'disponible';
    // Le client est prévenu quand son colis devient disponible (pas à chaque
    // modification, ni quand une correction le ramène à « Disponible »)
    $('[data-bloc-prevenir]', formStatut).hidden = !disponible || !!(colis && colis.statut === 'disponible') ||
      !!(colis && statut === statutCorrection);
    if (disponible) libelleLieu.textContent = 'Agence où retirer le colis';
    else libelleLieu.innerHTML = libelleLieuOrigine;
    var lieu = formStatut.elements.lieu;
    lieu.placeholder = disponible ? 'Ex. Ciudad Juan Bosch' : 'Ex. Port-au-Prince';
    // Nouvelle étape : le lieu et le message de l'étape précédente ne sont pas repris
    if (colis) {
      [[lieu, colis.lieu], [formStatut.elements.note, colis.note]].forEach(function (c) {
        if (statut !== colis.statut && c[0].value === (c[1] || '')) c[0].value = '';
        else if (statut === colis.statut && !c[0].value) c[0].value = c[1] || '';
      });
    }
  }
  $$('input[name="statut"]', formStatut).forEach(function (r) { r.addEventListener('change', majChoixStatut); });

  formStatut.addEventListener('submit', function (e) {
    e.preventDefault();
    var f = formStatut.elements;
    var statut = ($('input[name="statut"]:checked', formStatut) || {}).value;
    if (!statut) { erreurFormulaire(formStatut, 'Choisissez le nouveau statut.'); return; }
    var lieu = f.lieu.value.trim();
    if (statut === 'disponible' && !lieu) {
      erreurFormulaire(formStatut, 'Indiquez l’agence où le client peut retirer son colis.');
      f.lieu.focus();
      return;
    }
    var motif = f.motif.value.trim();
    if (cibleStatut.colis && statut === statutCorrection && !motif) {
      erreurFormulaire(formStatut, 'Revenir à l\u2019étape précédente est une correction : indiquez-en le motif.');
      f.motif.focus();
      return;
    }
    erreurFormulaire(formStatut, '');
    var bouton = $('[data-envoyer]', formStatut);
    var prevenir = statut === 'disponible' && f.prevenir.checked && !$('[data-bloc-prevenir]', formStatut).hidden;
    var note = f.note.value.trim();
    // Colis qui deviennent disponibles, avec les coordonnées de leur client
    var concernes = (cibleStatut.colis ? [cibleStatut.colis] : etat.colis.lignes.filter(function (l) {
      return cibleStatut.ids.indexOf(l.id) >= 0;
    })).filter(function (l) { return l.statut !== 'disponible'; });
    // Le statut que la page affichait pour chaque colis : si quelqu'un l'a
    // changé entre-temps, la base le dit au lieu d'écraser son travail.
    var attendus = {};
    (cibleStatut.colis ? [cibleStatut.colis] : etat.colis.lignes).forEach(function (l) {
      if (cibleStatut.ids.indexOf(l.id) >= 0) attendus[l.id] = l.statut;
    });
    attente(bouton, 'Mise à jour…');
    API.admin.changerStatut(cibleStatut.ids, { statut: statut, lieu: lieu, note: note }, attendus, motif || null, cleStatut)
      .then(function (r) {
        attente(bouton);
        // Tout ou rien : un seul colis bloquant, et aucun n'a changé. On dit
        // lesquels, le dialogue reste ouvert pour les décocher.
        if (r.refus.length) {
          var details = r.refus.slice(0, 4).map(function (x) { return x.detail; }).join(' · ') +
            (r.refus.length > 4 ? ' · et ' + (r.refus.length - 4) + ' autre(s).' : '');
          erreurFormulaire(formStatut, cibleStatut.ids.length > 1
            ? 'Aucun colis n\u2019a changé. ' + details : details);
          return;
        }
        var n = r.modifies + r.inchanges;
        // Ne prévenir que les colis réellement passés à « Disponible » par
        // cette demande : un double clic ne renvoie pas le message.
        concernes = concernes.filter(function (l) { return r.ids.indexOf(l.id) >= 0; });
        dlgStatut.close();
        cibleStatut.ids.forEach(function (id) { etat.vus[id] = null; });
        if (!cibleStatut.colis) etat.selection = [];
        chargerStatistiques();
        chargerColis(true);
        if (prevenir && concernes.length) {
          notifier(concernes.map(function (ligne) {
            return { colis: Object.assign({}, ligne, { statut: statut, lieu: lieu, note: note }), client: clientDe(ligne) };
          }), 'disponible');
        } else {
          toast(n > 1 ? n + ' colis passés à « ' + STATUTS[statut] + ' ».' : 'Statut mis à jour : ' + STATUTS[statut] + '.');
        }
      }).catch(function (err) {
        attente(bouton);
        erreurFormulaire(formStatut, messageErreur(err));
      });
  });

  $('[data-action="prevenir-client"]', dlgStatut).addEventListener('click', function () {
    var colis = cibleStatut.colis;
    if (!colis || EVENEMENTS.indexOf(colis.statut) < 0) return;
    dlgStatut.close();
    notifier([{ colis: colis, client: clientDe(colis) }], colis.statut);
  });

  $('[data-action="etiquette-colis"]', dlgStatut).addEventListener('click', function () {
    var colis = cibleStatut.colis;
    // La fenêtre d'impression s'ouvre par-dessus le dialogue : on le ferme
    // d'abord, sinon l'aperçu ne montre rien.
    dlgStatut.close();
    if (colis) imprimerEtiquettes([colis]);
  });

  $('[data-action="modifier-colis"]', dlgStatut).addEventListener('click', function () {
    var colis = cibleStatut.colis;
    dlgStatut.close();
    if (colis) ouvrirColis({ colis: colis });
  });

  $('[data-action="supprimer-colis"]', dlgStatut).addEventListener('click', function () {
    var colis = cibleStatut.colis;
    if (!colis || !window.confirm('Supprimer définitivement le colis ' + colis.numero + ' et son historique ?')) return;
    API.admin.supprimerColis(colis.id).then(function () {
      dlgStatut.close();
      toast('Colis ' + colis.numero + ' supprimé.');
      chargerStatistiques();
      chargerColis();
    }).catch(function (err) { erreurFormulaire(formStatut, messageErreur(err)); });
  });

  /* ---- Notifications aux clients (e-mail et WhatsApp) ----------------------------
     À l'enregistrement d'un colis (« reçu à Miami ») et quand il passe à
     « Disponible en agence ». L'e-mail part automatiquement ; WhatsApp aussi si
     l'API WhatsApp est configurée, sinon en un clic depuis votre WhatsApp. */
  var EVENEMENTS = ['recu', 'disponible'];
  var N = window.GoshipNotifications;
  var dlgNotif = $('[data-dialogue="notification"]');
  var dlgApercu = $('[data-dialogue="apercu"]');
  var EVENEMENT_LIBELLE = { recu: 'Colis reçu', disponible: 'Colis disponible' };

  function clientDe(ligne) {
    return {
      nom_complet: ligne.nom_client, code: ligne.code_client, telephone: ligne.telephone_client,
      email: ligne.email_client, langue: ligne.langue_client, pays: ligne.pays_client
    };
  }

  function apercu(message) {
    $('[data-apercu-sujet]', dlgApercu).textContent = message.email.sujet;
    // Aperçu sans script ; les liens s'ouvrent dans un nouvel onglet
    $('[data-apercu]', dlgApercu).srcdoc = message.email.html.replace('<head>', '<head><base target="_blank">');
    dlgApercu.showModal();
  }

  function etatEmail(resultat, client) {
    if (resultat === 'envoye') return { ok: true, texte: 'E-mail envoyé à ' + (client.email || 'l’adresse du client') };
    if (resultat === 'demo') return { ok: null, texte: 'Démonstration : e-mail préparé mais non envoyé (voir l’aperçu)' };
    if (resultat === 'non-configure') return { ok: false, texte: 'E-mail non configuré : voir le README, partie « Notifications »' };
    if (resultat === 'sans-destinataire') return { ok: false, texte: 'Pas d’adresse e-mail pour ce client' };
    return { ok: false, texte: 'Échec de l’envoi de l’e-mail : ' + resultat };
  }

  function notifier(entrees, evenement, options) {
    options = options || {};
    var liste = $('[data-envois]', dlgNotif);
    liste.textContent = '';
    var premier = entrees[0];
    $('[data-notif-titre]', dlgNotif).textContent = options.apresEnregistrement ? 'Colis enregistré'
      : (entrees.length > 1 ? entrees.length + ' clients prévenus' : 'Client prévenu');
    $('[data-notif-sous-titre]', dlgNotif).textContent = entrees.length === 1
      ? premier.colis.numero + ' · ' + (premier.client.nom_complet || '') + (premier.client.code ? ' (' + premier.client.code + ')' : '')
      : EVENEMENT_LIBELLE[evenement] + ' : un e-mail et un message WhatsApp par client.';
    $('[data-action="autre-colis"]', dlgNotif).hidden = !options.apresEnregistrement;
    var aide = $('[data-notif-aide]', dlgNotif);
    aide.hidden = true;

    var sansApiWhatsApp = false;
    var envois = entrees.map(function (entree) {
      var colis = entree.colis, client = entree.client || {};
      var message = N.preparer(evenement, colis, client);
      var li = el('li', 'gs-envoi');
      var tete = el('div', 'gs-envoi__tete');
      tete.appendChild(el('strong', '', client.nom_complet || client.code || 'Client'));
      tete.appendChild(el('span', 'gs-envoi__num', colis.numero));
      li.appendChild(tete);
      var ligneEmail = el('p', 'gs-envoi__ligne gs-envoi__ligne--attente', 'Envoi de l’e-mail…');
      var ligneWa = el('div', 'gs-envoi__ligne gs-envoi__ligne--attente', 'Message WhatsApp…');
      li.appendChild(ligneEmail);
      li.appendChild(ligneWa);
      var actions = el('div', 'gs-envoi__actions');
      var voir = el('button', 'gs-lien-bouton', 'Aperçu de l’e-mail');
      voir.type = 'button';
      voir.addEventListener('click', function () { apercu(message); });
      actions.appendChild(voir);
      li.appendChild(actions);
      liste.appendChild(li);

      var email = API.admin.envoyerEmail(colis.id, evenement, message.email).then(function (r) {
        var e = etatEmail(r, client);
        ligneEmail.textContent = (e.ok ? '✓ ' : '') + e.texte;
        ligneEmail.className = 'gs-envoi__ligne ' + (e.ok ? 'gs-envoi__ligne--ok' : e.ok === false ? 'gs-envoi__ligne--alerte' : '');
      }, function (err) {
        ligneEmail.textContent = 'Échec de l’envoi de l’e-mail : ' + messageErreur(err);
        ligneEmail.className = 'gs-envoi__ligne gs-envoi__ligne--alerte';
      });

      var whatsapp = API.admin.envoyerWhatsApp(colis.id, evenement, message.modele).then(function (r) {
        return r;
      }, function () { return 'erreur'; }).then(function (r) {
        ligneWa.textContent = '';
        if (r === 'envoye') {
          ligneWa.textContent = '✓ Message WhatsApp envoyé automatiquement';
          ligneWa.className = 'gs-envoi__ligne gs-envoi__ligne--ok';
          return;
        }
        sansApiWhatsApp = true;
        ligneWa.className = 'gs-envoi__ligne';
        if (!message.lienWhatsApp) {
          ligneWa.textContent = 'Pas de numéro de téléphone pour ce client';
          ligneWa.className = 'gs-envoi__ligne gs-envoi__ligne--alerte';
          return;
        }
        var lien = el('a', 'gs-bouton gs-bouton--petit gs-bouton--wa', 'Envoyer sur WhatsApp');
        lien.href = message.lienWhatsApp;
        lien.target = '_blank';
        lien.rel = 'noopener';
        lien.addEventListener('click', function () {
          lien.textContent = '✓ WhatsApp ouvert';
          lien.classList.add('is-fait');
        });
        ligneWa.appendChild(lien);
        ligneWa.appendChild(el('span', 'gs-envoi__detail', client.telephone || ''));
      });
      return Promise.all([email, whatsapp]);
    });

    Promise.all(envois).then(function () {
      if (sansApiWhatsApp) {
        aide.textContent = 'WhatsApp s’ouvre avec le message déjà rédigé : appuyez sur Envoyer. Pour un envoi automatique, configurez l’API WhatsApp (README, partie « Notifications »).';
        aide.hidden = false;
      }
    });
    dlgNotif.showModal();
  }

  $('[data-action="autre-colis"]', dlgNotif).addEventListener('click', function () {
    dlgNotif.close();
    ouvrirColis();
  });

  // Messages déjà envoyés pour un colis (fenêtre « Mettre à jour »)
  function afficherNotificationsEnvoyees(id) {
    var bloc = $('[data-bloc-notifications]', dlgStatut);
    var liste = $('[data-notifications]', dlgStatut);
    liste.textContent = '';
    API.admin.notifications(id).then(function (lignes) {
      if (!cibleStatut.colis || cibleStatut.colis.id !== id || !lignes || !lignes.length) return;
      lignes.forEach(function (n) {
        var reussite = n.code_http ? n.code_http < 300 : null;
        var resultat = API.mode === 'demo' ? 'démonstration, non envoyé'
          : reussite === true ? 'envoyé' : reussite === false ? 'échec (' + (n.erreur || 'code ' + n.code_http) + ')' : 'envoyé';
        var li = el('li', reussite === false ? 'is-echec' : '');
        li.appendChild(el('strong', '', (n.canal === 'email' ? 'E-mail' : 'WhatsApp') + ' · ' + (EVENEMENT_LIBELLE[n.evenement] || n.evenement)));
        li.appendChild(el('span', '', O.date(n.envoye_le, true) + ' · ' + (n.destinataire || '') + ' · ' + resultat));
        liste.appendChild(li);
      });
      bloc.hidden = false;
    }).catch(function () { /* liste facultative */ });
  }

  /* ---- Démonstration --------------------------------------------------------- */
  $('[data-action="exemples"]').addEventListener('click', function () {
    API.admin.exemples().then(function () {
      toast('Exemples ajoutés : 3 clients et 7 colis.');
      chargerStatistiques();
      chargerColis();
      chargerClients();
    }).catch(function (err) { toast(messageErreur(err), true); });
  });
  $('[data-action="effacer-demo"]').addEventListener('click', function () {
    if (!window.confirm('Effacer tous les comptes et colis de la démonstration ?')) return;
    API.admin.effacerDemo().then(function () { location.reload(); });
  });

  demarrer();
})();
