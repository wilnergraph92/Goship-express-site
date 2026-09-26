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
    // Le menu latéral et les outils de la barre n'existent qu'une fois dans le tableau de bord
    document.body.classList.toggle('is-app', nom === 'tableau');
    if (nom !== 'tableau') $('[data-titre-vue]').textContent = 'Tableau de bord';
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
    $('[data-role-texte]').textContent = ROLES[droits.role] || '';
  }

  /* ---- État de l'affichage ------------------------------------------------ */
  var etat = {
    vue: 'apercu',
    // page commence à 0 ; parPage : 10, 25, 50 ou 100 (barre de pagination)
    colis: { lignes: [], total: 0, page: 0, parPage: 25, statut: 'actifs', recherche: '', clientId: null, clientCode: '',
             service: '', pays: '', depuis: '', jusqua: '' },
    clients: { lignes: [], total: 0, page: 0, parPage: 25, recherche: '', tri: 'recent', filtre: 'tous', finances: true },
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
      $('[data-avatar]').textContent = String(s.email || '?').replace(/@.*/, '').split(/[._-]+/)
        .filter(Boolean).slice(0, 2).map(function (m) { return m.charAt(0).toUpperCase(); }).join('') || '?';
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

  var deconnexionVoulue = false;
  $$('[data-action="deconnexion"]').forEach(function (b) {
    b.addEventListener('click', function () {
      deconnexionVoulue = true;
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
    appliquerReglages();
    choisirVue(etat.vue);
    chargerStatistiques();
    chargerColis();
    if (peut('clients.view')) chargerClients();
    if (peut('invoices.view')) chargerFactures();
    if (peut('users.view')) chargerEquipe();
    installerLogoEmail();
    arreterSurveillance();
    arreterSurveillance = API.surveiller(function (quoi) {
      clearTimeout(rechargementPrevu);
      rechargementPrevu = setTimeout(function () { toutRecharger(quoi); }, 350);
    }, { tout: true, etat: function (actif) { $('[data-direct]').hidden = !actif; } });
  }

  // Un changement signalé en direct (ou le retour du réseau) : les listes
  // ouvertes se rechargent. La vue générale, au plus toutes les 15 secondes ;
  // elle porte aussi les alertes des notifications du poste de travail.
  var rechargementPrevu = null;
  var arreterSurveillance = function () {};
  function toutRecharger(quoi) {
    chargerStatistiques();
    chargerColis(true);
    if (peut('clients.view') && (quoi === 'clients' || etat.vue === 'clients')) chargerClients();
    if (peut('invoices.view') && (quoi === 'factures' || etat.vue === 'factures')) chargerFactures();
    if (peut('users.view') && (quoi === 'clients' || etat.vue === 'equipe')) chargerEquipe();
    if (etat.vue === 'apercu' || notificationsActives()) rafraichirApercu();
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

  // Un jour du filtre « Reçus du … au … », en heure de Santo Domingo (UTC−4
  // toute l'année) : « au 12/09 » compte tout le 12, jusqu'à minuit.
  function debutDuJour(jour) { return jour + 'T00:00:00-04:00'; }
  function lendemain(jour) {
    var t = new Date(jour + 'T00:00:00Z');
    t.setUTCDate(t.getUTCDate() + 1);
    return t.toISOString().slice(0, 10);
  }

  function colisFiltres() {
    var c = etat.colis;
    return c.statut !== 'actifs' || c.recherche || c.clientId || c.service || c.pays || c.depuis || c.jusqua;
  }

  function chargerColis(enDirect) {
    var c = etat.colis;
    if (c.depuis && c.jusqua && c.jusqua < c.depuis) {
      toast('La date de fin est avant la date de début.', true);
      return Promise.resolve();
    }
    return API.admin.colis({
      recherche: c.recherche, statut: c.statut, clientId: c.clientId, service: c.service, pays: c.pays,
      depuis: c.depuis ? debutDuJour(c.depuis) : null, jusqua: c.jusqua ? debutDuJour(lendemain(c.jusqua)) : null,
      page: c.page, parPage: c.parPage
    }).then(function (r) {
      // Une page vidée entre-temps (colis supprimés, filtre changé) : la dernière qui existe
      if (!r.lignes.length && c.page > 0 && r.total > 0) {
        c.page = Math.ceil(r.total / c.parPage) - 1;
        return chargerColis(enDirect);
      }
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
      vide.textContent = colisFiltres()
        ? 'Aucun colis ne correspond à ces filtres.'
        : 'Aucun colis en cours. Cliquez sur « Enregistrer un colis » à la réception d’un paquet à Miami.';
    }
    $('.gs-tableau--colis').closest('.gs-tableau-cadre').hidden = !c.lignes.length;
    paginer('colis', c, c.total, function () { chargerColis(); });
    $('[data-action="reinitialiser-colis"]').hidden = !colisFiltres();
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
      etat.colis.page = 0;
      chargerColis();
    }, 300);
  });
  var filtre = $('[data-filtre-colis]');
  filtre.addEventListener('change', function () {
    etat.colis.statut = filtre.value;
    etat.colis.page = 0;
    chargerColis();
  });
  // Service, destination, dates de réception : la base filtre, la page n'écarte rien
  [['[data-filtre-service]', 'service'], ['[data-filtre-pays]', 'pays'], ['[data-filtre-depuis]', 'depuis'],
   ['[data-filtre-jusqua]', 'jusqua']].forEach(function (x) {
    $(x[0]).addEventListener('change', function (e) {
      etat.colis[x[1]] = e.target.value || '';
      etat.colis.page = 0;
      chargerColis();
    });
  });
  function viderFiltresColis() {
    var c = etat.colis;
    c.statut = 'actifs'; c.recherche = ''; c.service = ''; c.pays = ''; c.depuis = ''; c.jusqua = ''; c.page = 0;
    filtre.value = 'actifs';
    $('[data-recherche="colis"]').value = '';
    $('[data-filtre-service]').value = '';
    $('[data-filtre-pays]').value = '';
    $('[data-filtre-depuis]').value = '';
    $('[data-filtre-jusqua]').value = '';
  }
  $('[data-action="reinitialiser-colis"]').addEventListener('click', function () {
    viderFiltresColis();
    retirerFiltreClient(false);
    chargerColis();
  });
  $$('[data-filtre-statut]').forEach(function (b) {
    b.addEventListener('click', function () {
      // La pastille compte tous les colis de ce statut : les autres filtres s'effacent
      viderFiltresColis();
      filtrerParStatut(b.getAttribute('data-filtre-statut'));
    });
  });
  $('[data-vue-cible="clients"]').addEventListener('click', function () { choisirVue('clients'); });

  // La liste des colis, filtrée sur un statut (pastilles du haut, vue générale)
  function filtrerParStatut(statut) {
    filtre.value = statut;
    etat.colis.statut = statut;
    retirerFiltreClient(false);
    etat.colis.page = 0;
    choisirVue('colis');
    chargerColis();
  }

  function filtrerParClient(client) {
    etat.colis.clientId = client.id;
    etat.colis.clientCode = client.code;
    etat.colis.statut = '';
    filtre.value = '';
    etat.colis.recherche = '';
    $('[data-recherche="colis"]').value = '';
    etat.colis.page = 0;
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
      etat.colis.page = 0;
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

  // Une page de clients avec leurs colis en cours et leurs montants, triée,
  // filtrée et comptée par la base (clients_soldes) : juste pour 50 clients
  // comme pour 50 000. Sans outils/supabase-tableau-de-bord.sql, la liste
  // s'affiche quand même, sans les chiffres.
  function chargerClients() {
    var c = etat.clients;
    return API.admin.clientsSoldes({ recherche: c.recherche, tri: c.tri, filtre: c.filtre, page: c.page, parPage: c.parPage })
      .then(function (r) {
        if (!r.lignes.length && c.page > 0 && r.total > 0) {
          c.page = Math.ceil(r.total / c.parPage) - 1;
          return chargerClients();
        }
        c.lignes = r.lignes || [];
        c.total = r.total || 0;
        c.finances = r.finances !== false;
        c.sansChiffres = false;
        afficherClients();
      })
      .catch(function (err) {
        if (err.code !== 'absent') { toast(messageErreur(err), true); return; }
        return API.admin.clients({ recherche: c.recherche, page: c.page, parPage: c.parPage }).then(function (r) {
          c.lignes = r.lignes;
          c.total = r.total;
          c.sansChiffres = true;
          afficherClients();
        }).catch(function (e) { toast(messageErreur(e), true); });
      });
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
    var montants = peut('invoices.view') && c.finances && !c.sansChiffres;
    corpsClients.textContent = '';
    c.lignes.forEach(function (client) {
      var tr = el('tr');
      var enCours = Number(client.colis_en_cours) || 0;
      if (enCours) tr.classList.add('is-actif-client');

      var tdCode = cellule('Identifiant');
      tdCode.appendChild(el('span', 'gs-cellule-num', client.code || '—'));
      if (client.cree_le) tdCode.appendChild(el('span', 'gs-cellule-sous', 'Inscrit le ' + O.date(client.cree_le)));
      tr.appendChild(tdCode);

      var tdNom = cellule('Client');
      tdNom.appendChild(el('span', 'gs-cellule-principale', client.nom_complet || '—'));
      tdNom.appendChild(el('span', 'gs-cellule-sous',
        [client.telephone, [client.ville, PAYS[client.pays] || client.pays].filter(Boolean).join(', ')]
          .filter(Boolean).join(' · ')));
      tdNom.appendChild(el('span', 'gs-cellule-sous', client.email || ''));
      tr.appendChild(tdNom);

      var tdNb = cellule('Colis en cours');
      if (c.sansChiffres) {
        tdNb.appendChild(el('span', 'gs-cellule-sous', 'Non disponible'));
      } else if (enCours) {
        tdNb.appendChild(el('span', 'gs-cellule-principale', String(enCours)));
        tdNb.appendChild(pastillesStatuts(client.statuts || {}));
      } else {
        tdNb.appendChild(el('span', 'gs-cellule-sous', 'Aucun colis en cours'));
      }
      tr.appendChild(tdNb);

      var tdPoids = cellule('Poids en cours');
      tdPoids.textContent = Number(client.poids_en_cours) ? O.nombre(Number(client.poids_en_cours)) + ' lb' : '—';
      tr.appendChild(tdPoids);

      if (peut('invoices.view')) {
        var tdFacture = cellule('Facturé');
        tdFacture.textContent = montants && Number(client.facture_usd) ? argent(client.facture_usd) : (montants ? '—' : 'Non disponible');
        tr.appendChild(tdFacture);
        var tdPaye = cellule('Payé');
        tdPaye.textContent = montants && Number(client.paye_usd) ? argent(client.paye_usd) : (montants ? '—' : 'Non disponible');
        tr.appendChild(tdPaye);
        var tdSolde = cellule('Solde');
        var solde = Number(client.solde_usd) || 0;
        tdSolde.appendChild(el('span', solde > 0 ? 'gs-cellule-principale gs-balance-due' : 'gs-cellule-sous',
                               !montants ? 'Non disponible' : (solde > 0 ? argent(solde) : 'Rien à payer')));
        if (montants && Number(client.factures_ouvertes) > 0) {
          tdSolde.appendChild(el('span', 'gs-cellule-sous', client.factures_ouvertes +
                                 (client.factures_ouvertes > 1 ? ' factures ouvertes' : ' facture ouverte')));
        }
        tr.appendChild(tdSolde);
      }

      var tdDate = cellule('Dernière activité');
      tdDate.textContent = client.derniere_activite ? O.date(client.derniere_activite, true) : '—';
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
      vide.textContent = c.recherche || c.filtre !== 'tous' ? 'Aucun client ne correspond à cette recherche.'
        : 'Aucun client inscrit pour l’instant. Les comptes créés sur le site apparaissent ici, avec leur code GSE.';
    }
    $('.gs-tableau--clients').closest('.gs-tableau-cadre').hidden = !c.lignes.length;
    paginer('clients', c, c.total, function () { chargerClients(); });
    $('[data-total="clients"]').textContent = c.total ? String(c.total) : '';
  }

  var delaiClients = null;
  $('[data-recherche="clients"]').addEventListener('input', function (e) {
    clearTimeout(delaiClients);
    delaiClients = setTimeout(function () {
      etat.clients.recherche = e.target.value.trim();
      etat.clients.page = 0;
      chargerClients();
    }, 300);
  });
  $('[data-filtre-clients]').addEventListener('change', function (e) {
    etat.clients.filtre = e.target.value;
    etat.clients.page = 0;
    chargerClients();
  });
  $('[data-tri-clients]').addEventListener('change', function (e) {
    etat.clients.tri = e.target.value;
    etat.clients.page = 0;
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
  var TITRES_VUES = { apercu: 'Vue générale', colis: 'Colis', clients: 'Clients', factures: 'Factures',
                      scanner: 'Poste de scan', equipe: 'Équipe', analytics: 'Analytics', notifications: 'Notifications' };
  function choisirVue(vue) {
    var onglet = $('[data-onglet-vue="' + vue + '"]');
    if (!onglet || onglet.hasAttribute('data-interdit')) {
      vue = $('[data-onglet-vue="apercu"]').hasAttribute('data-interdit') ? 'colis' : 'apercu';
    }
    etat.vue = vue;
    $('[data-titre-vue]').textContent = TITRES_VUES[vue] || 'Tableau de bord';
    fermerMenu();
    onglets.forEach(function (b) {
      var actif = b.getAttribute('data-onglet-vue') === vue;
      b.setAttribute('aria-selected', String(actif));
      b.tabIndex = actif ? 0 : -1;
    });
    $$('[data-vue]').forEach(function (v) { v.hidden = v.getAttribute('data-vue') !== vue; });
    // Les factures ne se rechargent qu'à leur propre changement : en ouvrant
    // l'onglet, on s'assure de ne pas regarder une liste d'il y a une heure.
    if (vue === 'factures') chargerFactures();
    if (vue === 'apercu' && Date.now() - etatApercu.charge > 60000) chargerApercu();
    if (vue === 'analytics') afficherAnalytics();
    if (vue === 'notifications') chargerNotifications();
  }
  onglets.forEach(function (b, i) {
    b.addEventListener('click', function () { choisirVue(b.getAttribute('data-onglet-vue')); });
    b.addEventListener('keydown', function (e) {
      // Le menu est vertical : ↓ et → pour le suivant, ↑ et ← pour le précédent
      var sens = { ArrowDown: 1, ArrowRight: 1, ArrowUp: -1, ArrowLeft: -1 }[e.key];
      if (!sens) return;
      e.preventDefault();
      var visibles = onglets.filter(function (o) { return !o.hasAttribute('data-interdit'); });
      var autre = visibles[(visibles.indexOf(b) + sens + visibles.length) % visibles.length];
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

  /* ---- Messages au client ----------------------------------------------------------
     La base prévient le client elle-même, à chaque étape, selon ses règles
     (outils/supabase-notifications.sql) : ce tableau de bord n'envoie plus rien.
     Il montre ce qui est parti — ou pourquoi rien n'est parti — et garde l'envoi
     WhatsApp « à la main » depuis votre propre WhatsApp quand l'API n'est pas
     configurée : c'est vous qui envoyez, pas la base. */
  var EVENEMENTS = ['recu', 'disponible'];
  var N = window.GoshipNotifications;
  var dlgNotif = $('[data-dialogue="notification"]');
  var EVENEMENT_LIBELLE = { recu: 'Colis reçu', disponible: 'Colis disponible' };
  var TYPE_EVENEMENT = { recu: 'shipment_received', disponible: 'shipment_available' };
  var CANAUX = { push: 'Téléphone', email: 'E-mail', whatsapp: 'WhatsApp', sms: 'SMS' };
  var ETATS_ENVOI = { attente: 'en file d’envoi', envoi: 'remis au fournisseur', envoye: 'envoyé', livre: 'livré',
                      echec: 'échec', annule: 'non envoyé' };
  var RAISONS = {
    NON_CONFIGURE: 'canal non configuré', PREFERENCE: 'coupé par le client', SANS_APPAREIL: 'aucun téléphone enregistré',
    SANS_DESTINATAIRE: 'pas d’adresse ou de numéro', SANS_MODELE: 'pas de modèle WhatsApp pour ce message',
    APPAREIL_INCONNU: 'téléphone oublié', DeviceNotRegistered: 'application désinstallée',
    RESEAU: 'fournisseur injoignable', ERREUR_INTERNE: 'erreur interne'
  };
  var TYPES_NOTIF = {};
  (API.regles.notifications ? API.regles.notifications.regles : []).forEach(function (r) { TYPES_NOTIF[r.type] = r.libelle; });
  TYPES_NOTIF.test = 'Essai';

  function clientDe(ligne) {
    return {
      nom_complet: ligne.nom_client, code: ligne.code_client, telephone: ligne.telephone_client,
      email: ligne.email_client, langue: ligne.langue_client, pays: ligne.pays_client
    };
  }

  // « E-mail : non envoyé (canal non configuré) », « Téléphone : envoyé »…
  function etatEnvoi(e) {
    var texte = ETATS_ENVOI[e.statut] || e.statut;
    var raison = e.code_erreur ? (RAISONS[e.code_erreur] || e.code_erreur) : '';
    if (e.statut === 'attente' && e.tentative > 0) texte = 'nouvel essai prévu';
    return (CANAUX[e.canal] || e.canal) + ' : ' + texte + (raison ? ' (' + raison + ')' : '');
  }
  function classeEnvoi(e) {
    return e.statut === 'envoye' || e.statut === 'livre' ? 'gs-envoi__ligne--ok'
      : e.statut === 'echec' ? 'gs-envoi__ligne--alerte' : '';
  }

  function notifier(entrees, evenement, options) {
    options = options || {};
    var liste = $('[data-envois]', dlgNotif);
    liste.textContent = '';
    var premier = entrees[0];
    $('[data-notif-titre]', dlgNotif).textContent = options.apresEnregistrement ? 'Colis enregistré'
      : (entrees.length > 1 ? entrees.length + ' clients prévenus' : 'Messages au client');
    $('[data-notif-sous-titre]', dlgNotif).textContent = entrees.length === 1
      ? premier.colis.numero + ' · ' + (premier.client.nom_complet || '') + (premier.client.code ? ' (' + premier.client.code + ')' : '')
      : (EVENEMENT_LIBELLE[evenement] || '') + ' : chaque client est prévenu par la base.';
    $('[data-action="autre-colis"]', dlgNotif).hidden = !options.apresEnregistrement;
    var aide = $('[data-notif-aide]', dlgNotif);
    aide.hidden = true;

    var aLaMain = false;
    var chargements = entrees.map(function (entree) {
      var colis = entree.colis, client = entree.client || {};
      var li = el('li', 'gs-envoi');
      var tete = el('div', 'gs-envoi__tete');
      tete.appendChild(el('strong', '', client.nom_complet || client.code || 'Client'));
      tete.appendChild(el('span', 'gs-envoi__num', colis.numero));
      li.appendChild(tete);
      var lignes = el('div', '');
      lignes.appendChild(el('p', 'gs-envoi__ligne gs-envoi__ligne--attente', 'Lecture des envois…'));
      li.appendChild(lignes);
      liste.appendChild(li);

      return API.admin.envoisColis(colis.id).then(function (envois) {
        // La notification de l'événement demandé, sinon la plus récente du colis
        var voulu = TYPE_EVENEMENT[evenement];
        var cible = envois.filter(function (e) { return e.type === voulu; })[0] || envois[0];
        var siens = cible ? envois.filter(function (e) { return e.notification_id === cible.notification_id; }) : [];
        lignes.textContent = '';
        if (!cible) {
          lignes.appendChild(el('p', 'gs-envoi__ligne', 'Aucune notification pour ce colis (règle coupée, ou colis sans client).'));
          return;
        }
        lignes.appendChild(el('p', 'gs-envoi__ligne gs-envoi__ligne--ok',
                              '✓ ' + (TYPES_NOTIF[cible.type] || cible.type) + ' : visible dans l’espace du client (site et application)'));
        siens.forEach(function (e) { lignes.appendChild(el('p', 'gs-envoi__ligne ' + classeEnvoi(e), etatEnvoi(e))); });
        // WhatsApp sans API : l'équipe peut l'envoyer elle-même, message déjà rédigé
        var wa = siens.filter(function (e) { return e.canal === 'whatsapp'; })[0];
        if (N && EVENEMENTS.indexOf(evenement) >= 0 && wa && wa.statut === 'annule' &&
            (wa.code_erreur === 'NON_CONFIGURE' || wa.code_erreur === 'SANS_MODELE')) {
          var message = N.preparer(evenement, colis, client);
          if (message.lienWhatsApp) {
            aLaMain = true;
            var lien = el('a', 'gs-bouton gs-bouton--petit gs-bouton--wa', 'Envoyer depuis mon WhatsApp');
            lien.href = message.lienWhatsApp;
            lien.target = '_blank';
            lien.rel = 'noopener';
            lien.addEventListener('click', function () {
              lien.textContent = '✓ WhatsApp ouvert';
              lien.classList.add('is-fait');
            });
            var actions = el('div', 'gs-envoi__actions');
            actions.appendChild(lien);
            lignes.appendChild(actions);
          }
        }
      }).catch(function (err) {
        lignes.textContent = '';
        lignes.appendChild(el('p', 'gs-envoi__ligne gs-envoi__ligne--alerte', 'Envois illisibles : ' + messageErreur(err)));
      });
    });

    Promise.all(chargements).then(function () {
      if (aLaMain) {
        aide.textContent = 'WhatsApp s’ouvre avec le message déjà rédigé : appuyez sur Envoyer. Pour que la base l’envoie elle-même, configurez l’API WhatsApp (docs/notifications.md).';
        aide.hidden = false;
      }
    });
    dlgNotif.showModal();
  }

  $('[data-action="autre-colis"]', dlgNotif).addEventListener('click', function () {
    dlgNotif.close();
    ouvrirColis();
  });

  // Messages au client pour un colis (fenêtre « Mettre à jour »)
  function afficherNotificationsEnvoyees(id) {
    var bloc = $('[data-bloc-notifications]', dlgStatut);
    var liste = $('[data-notifications]', dlgStatut);
    liste.textContent = '';
    API.admin.envoisColis(id).then(function (envois) {
      if (!cibleStatut.colis || cibleStatut.colis.id !== id || !envois || !envois.length) return;
      var parNotif = [];
      envois.forEach(function (e) {
        var g = parNotif.filter(function (x) { return x.id === e.notification_id; })[0];
        if (!g) parNotif.push(g = { id: e.notification_id, type: e.type, cree_le: e.cree_le, envois: [] });
        g.envois.push(e);
      });
      parNotif.forEach(function (g) {
        var echec = g.envois.some(function (e) { return e.statut === 'echec'; });
        var li = el('li', echec ? 'is-echec' : '');
        li.appendChild(el('strong', '', (TYPES_NOTIF[g.type] || g.type) + ' · ' + O.date(g.cree_le, true)));
        li.appendChild(el('span', '', ['Espace client'].concat(g.envois.map(etatEnvoi)).join(' · ')));
        liste.appendChild(li);
      });
      bloc.hidden = false;
    }).catch(function () { /* liste facultative */ });
  }

  /* ---- Vue « Notifications » : envois, canaux, règles ------------------------------ */
  var vueNotifs = $('[data-vue="notifications"]');
  var etatNotifs = { page: 0, parPage: 25 };
  function filtreNotifs(nom) { return $('[data-notifs-filtre="' + nom + '"]', vueNotifs).value; }

  function chargerNotifications() {
    var jours = Number(filtreNotifs('periode')) || 7;
    var erreur = $('[data-notifs-erreur]', vueNotifs);
    erreur.hidden = true;
    return Promise.all([
      API.admin.centreNotifications({
        debut: new Date(Date.now() - jours * 864e5).toISOString(), type: filtreNotifs('type') || null,
        canal: filtreNotifs('canal') || null, statut: filtreNotifs('statut') || null,
        page: etatNotifs.page, parPage: etatNotifs.parPage
      }),
      API.admin.reglesNotifications()
    ]).then(function (r) {
      afficherCentreNotifications(r[0]);
      afficherRegles(r[1]);
    }).catch(function (err) {
      erreur.textContent = messageErreur(err);
      erreur.hidden = false;
    });
  }

  function afficherCentreNotifications(c) {
    var st = c.par_statut || {};
    var envoyes = (st.envoye || 0) + (st.livre || 0);
    var echecs = st.echec || 0;
    kpis('notifications', [
      { libelle: 'Notifications', valeur: entier(c.notifications), sous: entier(c.non_lues) + ' non lues', picto: 'cloche' },
      { libelle: 'Envoyés', valeur: entier(envoyes), sous: 'acceptés par le fournisseur', ton: '' },
      { libelle: 'Échecs', valeur: entier(echecs),
        sous: envoyes + echecs ? (Math.round(1000 * echecs / (envoyes + echecs)) / 10 + ' % des envois tentés') : 'aucun envoi tenté',
        ton: echecs ? 'critique' : '' },
      { libelle: 'En file', valeur: entier((st.attente || 0) + (st.envoi || 0)) },
      { libelle: 'Non envoyés', valeur: entier(st.annule || 0), sous: 'canal non configuré, préférence…' },
      { libelle: 'Délai moyen', valeur: c.delai_moyen_s == null ? '—' : entier(c.delai_moyen_s) + ' s', sous: 'création → envoi' }
    ]);
    var alertes = $('[data-notifs-alertes]', vueNotifs);
    alertes.textContent = '';
    (c.alertes || []).forEach(function (a) {
      alertes.appendChild(el('li', 'gs-alerte gs-alerte--erreur',
        a.code === 'FILE_BLOQUEE' ? entier(a.nombre) + ' envois attendent depuis plus de 15 minutes : le travailleur (pg_cron) tourne-t-il ?'
        : a.code === 'ECHECS_ANORMAUX' ? (CANAUX[a.canal] || a.canal) + ' : ' + a.taux + ' % d’échecs sur 24 heures.'
        : a.code === 'APPAREILS_OUBLIES' ? entier(a.nombre) + ' téléphones inconnus d’Expo en 24 heures.' : a.code));
    });
    alertes.hidden = !(c.alertes || []).length;

    var corps = $('[data-lignes="envois"]', vueNotifs);
    corps.textContent = '';
    (c.elements || []).forEach(function (e) {
      var tr = el('tr', '');
      tr.appendChild(el('td', '', O.date(e.cree_le, true)));
      tr.appendChild(el('td', '', TYPES_NOTIF[e.type] || e.type));
      tr.appendChild(el('td', '', e.client_code || '—'));
      tr.appendChild(el('td', '', e.numero || e.facture || '—'));
      tr.appendChild(el('td', '', CANAUX[e.canal] || e.canal));
      var statut = el('td', classeEnvoi(e) ? 'gs-envois__statut ' + classeEnvoi(e) : 'gs-envois__statut',
                      (ETATS_ENVOI[e.statut] || e.statut) + (e.code_erreur ? ' · ' + (RAISONS[e.code_erreur] || e.code_erreur) : ''));
      tr.appendChild(statut);
      tr.appendChild(el('td', '', entier(e.tentative)));
      var td = el('td', '');
      var b = el('button', 'gs-lien-bouton', 'Suivi');
      b.type = 'button';
      b.addEventListener('click', function () { ouvrirSuiviNotification(e.notification_id); });
      td.appendChild(b);
      tr.appendChild(td);
      corps.appendChild(tr);
    });
    if (!(c.elements || []).length) {
      var vide = el('tr', '');
      var td0 = el('td', 'gs-tableau__vide', 'Aucun envoi pour ces filtres.');
      td0.colSpan = 8;
      vide.appendChild(td0);
      corps.appendChild(vide);
    }
    paginer('envois', etatNotifs, c.total, chargerNotifications);
  }

  function afficherRegles(r) {
    var types = $('[data-notifs-filtre="type"]', vueNotifs);
    if (types.options.length === 1) {
      r.regles.forEach(function (x) { types.add(new Option(x.libelle || x.type, x.type)); });
    }
    var canaux = $('[data-notifs-canaux]', vueNotifs);
    canaux.textContent = '';
    Object.keys(CANAUX).forEach(function (k) {
      var li = el('li', 'gs-notifs-canaux__canal' + (r.canaux[k] ? ' is-configure' : ''));
      li.appendChild(el('strong', '', CANAUX[k]));
      li.appendChild(el('span', '', r.canaux[k] ? 'configuré' : 'non configuré'));
      if (r.modifiable && r.canaux[k]) {
        var essai = el('button', 'gs-lien-bouton', 'Essai vers mon compte');
        essai.type = 'button';
        essai.addEventListener('click', function () {
          attente(essai, '…');
          API.admin.testerNotification(k).then(function (s) {
            toast('Essai ' + CANAUX[k] + ' : ' + (s.envois[0] ? etatEnvoi(s.envois[0]) : 'créé') + '.');
            chargerNotifications();
          }).catch(function (err) { toast(messageErreur(err), true); }).then(function () { attente(essai); });
        });
        li.appendChild(essai);
      }
      canaux.appendChild(li);
    });

    var corps = $('[data-lignes="regles"]', vueNotifs);
    corps.textContent = '';
    r.regles.forEach(function (x) {
      var tr = el('tr', x.actif ? '' : 'is-inactif');
      var nom = el('td', '');
      nom.appendChild(el('strong', '', x.libelle || x.type));
      if (x.priorite === 'haute') nom.appendChild(el('span', 'gs-regle__priorite', 'prioritaire'));
      if (x.sensible) nom.appendChild(el('span', 'gs-regle__sensible', 'texte neutre sur l’écran verrouillé'));
      tr.appendChild(nom);
      tr.appendChild(el('td', 'gs-regle__evenement', x.evenement));
      var tdCanaux = el('td', 'gs-regle__canaux');
      var cases = {};
      Object.keys(CANAUX).forEach(function (k) {
        var lab = el('label', 'gs-case gs-case--petite');
        var cb = document.createElement('input');
        cb.type = 'checkbox';
        cb.checked = x.canaux.indexOf(k) >= 0;
        cb.disabled = !r.modifiable;
        cases[k] = cb;
        lab.appendChild(cb);
        lab.appendChild(el('span', '', CANAUX[k] + (r.canaux[k] ? '' : ' (non configuré)')));
        tdCanaux.appendChild(lab);
      });
      tr.appendChild(tdCanaux);
      var tdActif = el('td', '');
      var labA = el('label', 'gs-case gs-case--petite');
      var actif = document.createElement('input');
      actif.type = 'checkbox';
      actif.checked = x.actif;
      actif.disabled = !r.modifiable;
      labA.appendChild(actif);
      labA.appendChild(el('span', '', 'active'));
      tdActif.appendChild(labA);
      tr.appendChild(tdActif);
      var tdAction = el('td', '');
      if (r.modifiable) {
        var b = el('button', 'gs-bouton gs-bouton--petit gs-bouton--contour', 'Enregistrer');
        b.type = 'button';
        b.addEventListener('click', function () {
          attente(b, '…');
          var choisis = Object.keys(cases).filter(function (k) { return cases[k].checked; });
          API.admin.modifierRegleNotification(x.type, actif.checked, choisis).then(function () {
            toast('Règle « ' + (x.libelle || x.type) + ' » enregistrée.');
            return chargerNotifications();
          }).catch(function (err) { toast(messageErreur(err), true); }).then(function () { attente(b); });
        });
        tdAction.appendChild(b);
      }
      tr.appendChild(tdAction);
      corps.appendChild(tr);
    });
    $('[data-notifs-regles-aide]', vueNotifs).hidden = false;
  }

  var dlgSuivi = $('[data-dialogue="suivi-notification"]');
  function ouvrirSuiviNotification(id) {
    var etapes = $('[data-suivi-etapes]', dlgSuivi);
    etapes.textContent = '';
    etapes.appendChild(el('li', '', 'Lecture…'));
    dlgSuivi.showModal();
    API.admin.suiviNotification(id).then(function (s) {
      var n = s.notification;
      $('[data-suivi-sous-titre]', dlgSuivi).textContent = (TYPES_NOTIF[n.type] || n.type) + ' · client ' +
        (n.client_code || '—') + (n.numero || n.facture ? ' · ' + (n.numero || n.facture) : '');
      etapes.textContent = '';
      var etape = function (titre, texte, classe) {
        var li = el('li', classe || '');
        li.appendChild(el('strong', '', titre));
        li.appendChild(el('span', '', texte));
        etapes.appendChild(li);
      };
      etape('Événement', s.evenement ? s.evenement.type + ' · ' + O.date(s.evenement.date, true) : 'essai ou rappel planifié');
      etape('Règle', s.regle ? (s.regle.actif ? 'active' : 'coupée') + ' · canaux : ' +
            (s.regle.canaux.map(function (k) { return CANAUX[k] || k; }).join(', ') || 'espace client seulement') : 'essai');
      etape('Notification', 'créée le ' + O.date(n.cree_le, true) + (n.lu_le ? ' · lue le ' + O.date(n.lu_le, true) : ' · pas encore lue'));
      (s.envois || []).forEach(function (e) {
        etape('Envoi ' + (CANAUX[e.canal] || e.canal), etatEnvoi(e) + (e.tentative ? ' · ' + e.tentative + ' essai' + (e.tentative > 1 ? 's' : '') : '') +
              (e.envoye_le ? ' · ' + O.date(e.envoye_le, true) : '') + (e.prochain_essai_le ? ' · prochain essai ' + O.date(e.prochain_essai_le, true) : '') +
              (e.erreur ? ' · « ' + e.erreur + ' »' : ''), classeEnvoi(e));
      });
    }).catch(function (err) {
      etapes.textContent = '';
      etapes.appendChild(el('li', 'gs-envoi__ligne--alerte', messageErreur(err)));
    });
  }

  ['periode', 'type', 'canal', 'statut'].forEach(function (nom) {
    $('[data-notifs-filtre="' + nom + '"]', vueNotifs).addEventListener('change', function () {
      etatNotifs.page = 0;
      chargerNotifications();
    });
  });

  /* ---- Pagination -------------------------------------------------------------
     La même barre pour les colis, les clients et les colis à traiter :
     « Lignes par page · 26–50 sur 340 · Précédente · Suivante ». La base
     compte et découpe ; la page n'affiche que ce qu'elle reçoit. */
  var TAILLES_PAGE = [10, 25, 50, 100];

  // nom : la zone [data-pagination=nom], ou la zone elle-même quand elle n'est
  // pas encore dans la page (les Analytics se construisent à part, puis s'affichent)
  function paginer(nom, p, total, recharger) {
    var zone = typeof nom === 'string' ? $('[data-pagination="' + nom + '"]') : nom;
    zone.textContent = '';
    total = Number(total) || 0;
    zone.hidden = !total || (total <= TAILLES_PAGE[0] && !p.page);
    if (zone.hidden) return;
    var taille = el('label', 'gs-pagination__taille');
    taille.appendChild(el('span', '', 'Lignes par page'));
    var choix = el('select', 'gs-admin-filtre gs-admin-filtre--petit');
    TAILLES_PAGE.forEach(function (n) {
      var o = new Option(String(n), String(n));
      o.selected = n === p.parPage;
      choix.add(o);
    });
    choix.addEventListener('change', function () { p.parPage = Number(choix.value); p.page = 0; recharger(); });
    taille.appendChild(choix);
    zone.appendChild(taille);
    var premier = p.page * p.parPage + 1, dernier = Math.min(total, (p.page + 1) * p.parPage);
    zone.appendChild(el('span', 'gs-pagination__texte', premier + '–' + dernier + ' sur ' + total));
    var precedente = el('button', 'gs-bouton gs-bouton--petit gs-bouton--contour', 'Précédente');
    precedente.type = 'button';
    precedente.disabled = p.page === 0;
    precedente.addEventListener('click', function () { p.page -= 1; recharger(); });
    var suivante = el('button', 'gs-bouton gs-bouton--petit gs-bouton--contour', 'Suivante');
    suivante.type = 'button';
    suivante.disabled = dernier >= total;
    suivante.addEventListener('click', function () { p.page += 1; recharger(); });
    zone.appendChild(precedente);
    zone.appendChild(suivante);
  }

  /* ---- Petits outils d'affichage ---------------------------------------------- */
  function entier(n) { return O.nombre(Number(n) || 0); }
  function pluriel(n, un, plusieurs) { return entier(n) + ' ' + ((Number(n) || 0) > 1 ? plusieurs : un); }
  // « 2026-09-12 » → « 12/09/2026 », sans passer par un fuseau horaire
  function jourLisible(jour, court) {
    var m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(jour || ''));
    if (!m) return '';
    return m[3] + '/' + m[2] + (court ? '' : '/' + m[1]);
  }
  function heure(iso) {
    var d = new Date(iso);
    if (isNaN(d.getTime())) return '';
    return (d.getHours() < 10 ? '0' : '') + d.getHours() + ':' + (d.getMinutes() < 10 ? '0' : '') + d.getMinutes();
  }
  function libelleTypeEvenement(type) {
    var t = API.regles.typesEvenement[type];
    return t ? t.libelle : (type || 'Étape');
  }
  var SOURCES = { scanner: 'scanner', tableau_de_bord: 'tableau de bord', creation: 'enregistrement' };

  // Ouvrir un colis trouvé ailleurs (vue générale, recherche) dans la fenêtre
  // « Mettre à jour » : la liste des colis le relit d'abord, pour avoir la
  // fiche complète et à jour.
  function ouvrirColisParNumero(numero) {
    API.admin.colis({ recherche: numero, statut: '', parPage: 5 }).then(function (r) {
      var colis = (r.lignes || []).filter(function (l) { return l.numero === numero; })[0];
      if (colis) ouvrirStatut([colis.id], colis);
      else toast('Ce colis n’existe plus.', true);
    }).catch(function (err) { toast(messageErreur(err), true); });
  }

  function ouvrirFactureParId(id) {
    API.admin.factures({ id: id, etat: '', parPage: 1 }).then(function (r) {
      var facture = (r.lignes || [])[0];
      if (!facture) { toast('Cette facture n’existe plus.', true); return; }
      choisirVue('factures');
      ouvrirFacture(facture);
    }).catch(function (err) { toast(messageErreur(err), true); });
  }

  /* ---- Graphiques -----------------------------------------------------------------
     Peu nombreux, et seulement ce qui se lit mieux en barres : par jour et par
     statut. Les valeurs sont celles de la base ; la page ne fait que les
     mettre à l'échelle. Chaque barre porte son chiffre (survol, lecteur
     d'écran), et le résumé écrit dit l'essentiel sans le dessin. */
  var SVG = 'http://www.w3.org/2000/svg';
  function svg(balise, attributs) {
    var n = document.createElementNS(SVG, balise);
    Object.keys(attributs || {}).forEach(function (k) { n.setAttribute(k, attributs[k]); });
    return n;
  }

  // series : [{ nom, cle, classe, total, format }] ; jours : [{ jour, <cle>: n }]
  function grapheJours(zone, jours, series, nommer) {
    // nommer(case, court) : « 12/09 », « semaine du 07/09 », « sept. 2026 »…
    nommer = nommer || function (j, court) { return jourLisible(j.jour, court); };
    zone.textContent = '';
    jours = jours || [];
    var max = 0;
    jours.forEach(function (j) { series.forEach(function (s) { max = Math.max(max, Number(j[s.cle]) || 0); }); });
    var legende = el('ul', 'gs-graphe__legende');
    series.forEach(function (s) {
      var li = el('li');
      li.appendChild(el('i', 'gs-graphe__puce ' + s.classe));
      li.appendChild(document.createTextNode(s.nom + ' : ' + s.format(s.total)));
      legende.appendChild(li);
    });
    zone.appendChild(legende);
    if (!jours.length || !max) {
      zone.appendChild(el('p', 'gs-graphe__vide', 'Rien sur cette période.'));
      return;
    }
    var L = 600, H = 160, n = jours.length, pas = L / n;
    var largeur = Math.max(1, (pas * (n > 60 ? 0.9 : 0.72)) / series.length);
    var dessin = svg('svg', { viewBox: '0 0 ' + L + ' ' + H, preserveAspectRatio: 'none', class: 'gs-graphe__svg',
                              role: 'img', 'aria-label': series.map(function (s) { return s.nom + ' ' + s.format(s.total); }).join(', ') +
                                ', du ' + nommer(jours[0]) + ' au ' + nommer(jours[n - 1]) + '.' });
    dessin.appendChild(svg('line', { x1: 0, x2: L, y1: H - 0.5, y2: H - 0.5, class: 'gs-graphe__axe' }));
    jours.forEach(function (j, i) {
      series.forEach(function (s, k) {
        var v = Number(j[s.cle]) || 0;
        if (!v) return;
        var h = Math.max(2, v / max * (H - 8));
        var barre = svg('rect', { x: (i * pas + (pas - largeur * series.length) / 2 + k * largeur).toFixed(2),
                                  y: (H - h).toFixed(2), width: largeur.toFixed(2), height: h.toFixed(2), class: s.classe,
                                  rx: Math.min(4, largeur / 2).toFixed(2) });
        var titre = svg('title');
        titre.textContent = nommer(j) + ' — ' + s.nom + ' : ' + s.format(v);
        barre.appendChild(titre);
        dessin.appendChild(barre);
      });
    });
    var cadre = el('div', 'gs-graphe__cadre');
    cadre.appendChild(el('span', 'gs-graphe__max', 'max. ' + series[0].format(max)));
    cadre.appendChild(dessin);
    zone.appendChild(cadre);
    var axe = el('div', 'gs-graphe__dates');
    axe.appendChild(el('span', '', nommer(jours[0], true)));
    if (n > 2) axe.appendChild(el('span', '', nommer(jours[Math.floor((n - 1) / 2)], true)));
    if (n > 1) axe.appendChild(el('span', '', nommer(jours[n - 1], true)));
    zone.appendChild(axe);
  }

  // Une répartition en barres horizontales : [{ libelle, nombre, classe }]
  function repartition(liste, lignes, videTexte) {
    liste.textContent = '';
    var max = 0;
    lignes.forEach(function (l) { max = Math.max(max, Number(l.nombre) || 0); });
    if (!lignes.length) {
      liste.appendChild(el('li', 'gs-repartition__vide', videTexte));
      return;
    }
    lignes.forEach(function (l) {
      var li = el('li', 'gs-repartition__ligne');
      var nom = el('span', 'gs-repartition__nom');
      if (l.pastille) nom.appendChild(el('i', 'gs-pastille gs-pastille--' + l.pastille));
      nom.appendChild(document.createTextNode(l.libelle));
      li.appendChild(nom);
      var piste = el('span', 'gs-repartition__piste');
      var barre = el('span', 'gs-repartition__barre' + (l.pastille ? ' gs-repartition__barre--' + l.pastille : ''));
      barre.style.width = max ? Math.round((Number(l.nombre) || 0) / max * 100) + '%' : '0%';
      piste.appendChild(barre);
      li.appendChild(piste);
      li.appendChild(el('strong', 'gs-repartition__nombre', entier(l.nombre)));
      liste.appendChild(li);
    });
  }

  /* ---- La vue générale ------------------------------------------------------------
     Une requête (vue_generale) pour tous les chiffres de la période ; une
     seconde (colis_a_traiter) pour la liste du bas. Mise à jour : le bouton
     « Actualiser », l'ouverture de l'onglet si les chiffres ont plus d'une
     minute, et les changements en direct — au plus une fois toutes les
     quinze secondes, pour ne pas recompter la base à chaque scan. */
  var etatApercu = { periode: '30j', debut: '', fin: '', donnees: null, charge: 0, demande: 0, prevu: null };
  var traiter = { liste: 'action_requise', jours: 7, page: 0, parPage: 10, demande: 0 };
  var corpsApercu = $('[data-apercu-corps]');
  var messageApercu = $('[data-apercu-message]');

  function texteErreurApercu(err) {
    if (err && err.code === 'non-autorise') return 'Accès refusé : votre rôle ne permet pas de voir la vue générale.';
    if (err && err.code === 'absent') {
      return 'La vue générale n’est pas encore installée : lancez outils/supabase-tableau-de-bord.sql dans Supabase ' +
             '(SQL Editor), puis « Actualiser ».';
    }
    if (err && err.code === 'reseau') return 'Connexion impossible : les chiffres n’ont pas pu être chargés. Vérifiez la connexion, puis « Actualiser ».';
    return messageErreur(err);
  }

  function chargerApercu() {
    if (!peut('shipments.view')) return Promise.resolve();
    var numero = ++etatApercu.demande;
    clearTimeout(etatApercu.prevu);
    etatApercu.prevu = null;
    etatApercu.charge = Date.now();
    corpsApercu.setAttribute('aria-busy', 'true');
    if (!etatApercu.donnees) $('[data-apercu-etat]').textContent = 'Chargement des chiffres…';
    chargerTraiter();
    return API.admin.vueGenerale({ periode: etatApercu.periode, debut: etatApercu.debut, fin: etatApercu.fin, jours: traiter.jours })
      .then(function (v) {
        if (numero !== etatApercu.demande) return;
        etatApercu.donnees = v;
        messageApercu.hidden = true;
        corpsApercu.hidden = false;
        afficherApercu(v);
      }).catch(function (err) {
        if (numero !== etatApercu.demande) return;
        etatApercu.charge = 0;
        messageApercu.textContent = texteErreurApercu(err);
        messageApercu.hidden = false;
        // Des chiffres déjà affichés restent, avec l'erreur au-dessus ; sinon rien plutôt que des zéros faux
        corpsApercu.hidden = !etatApercu.donnees;
        if (!etatApercu.donnees) $('[data-apercu-etat]').textContent = '';
      }).then(function () {
        if (numero === etatApercu.demande) corpsApercu.removeAttribute('aria-busy');
      });
  }

  function rafraichirApercu() {
    if (etatApercu.prevu) return;
    var attente = Math.max(0, 15000 - (Date.now() - etatApercu.charge));
    etatApercu.prevu = setTimeout(function () {
      etatApercu.prevu = null;
      if (etat.vue === 'apercu' || notificationsActives()) chargerApercu();
    }, attente);
  }

  // Les pictogrammes des chiffres clés (traits, 24 × 24) : des constantes, jamais une donnée
  var PICTOS = {
    colis: '<path d="m7.5 4.3 9 5.2"/><path d="M21 8a2 2 0 0 0-1-1.7l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.7l7 4a2 2 0 0 0 2 0l7-4a2 2 0 0 0 1-1.7Z"/><path d="m3.3 7 8.7 5 8.7-5M12 22V12"/>',
    livre: '<circle cx="12" cy="12" r="10"/><path d="m8.5 12.5 2.5 2.5 5-5.5"/>',
    route: '<path d="M14 18V6a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2v11a1 1 0 0 0 1 1h2"/><path d="M15 18H9"/><path d="M19 18h2a1 1 0 0 0 1-1v-3.65a1 1 0 0 0-.22-.62l-3.48-4.35A1 1 0 0 0 17.52 8H14"/><circle cx="17" cy="18" r="2"/><circle cx="7" cy="18" r="2"/>',
    cloche: '<path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/>',
    alerte: '<path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z"/><path d="M12 9v4M12 17h.01"/>',
    horloge: '<circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/>',
    clients: '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75"/>',
    nouveau: '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M19 8v6M22 11h-6"/>',
    facture: '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8Z"/><path d="M14 2v6h6"/><path d="M8 13h8M8 17h6"/>',
    argent: '<rect x="2" y="6" width="20" height="12" rx="2"/><circle cx="12" cy="12" r="2.5"/><path d="M6 12h.01M18 12h.01"/>',
    portefeuille: '<path d="M19 7V4a1 1 0 0 0-1-1H5a2 2 0 0 0 0 4h15a1 1 0 0 1 1 1v4h-3a2 2 0 0 0 0 4h3a1 1 0 0 0 1-1v-2a1 1 0 0 0-1-1"/><path d="M3 5v14a2 2 0 0 0 2 2h15a1 1 0 0 0 1-1v-4"/>',
    scan: '<path d="M3 7V5a2 2 0 0 1 2-2h2M17 3h2a2 2 0 0 1 2 2v2M21 17v2a2 2 0 0 1-2 2h-2M7 21H5a2 2 0 0 1-2-2v-2"/><path d="M7 8v8M10 8v8M13 8v8M17 8v8"/>'
  };
  function picto(nom) {
    return '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" ' +
           'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">' + PICTOS[nom] + '</svg>';
  }

  function kpis(nom, cartes) {
    var zone = $('[data-kpis="' + nom + '"]');
    zone.textContent = '';
    cartes.forEach(function (k) {
      var carte = el(k.action ? 'button' : 'div', 'gs-kpi' + (k.ton ? ' gs-kpi--' + k.ton : ''));
      if (k.action) {
        carte.type = 'button';
        carte.addEventListener('click', k.action);
      }
      if (k.picto && PICTOS[k.picto]) {
        var pastille = el('span', 'gs-kpi__picto gs-kpi__picto--' + (k.teinte || 'bleu'));
        pastille.innerHTML = picto(k.picto);
        carte.appendChild(pastille);
      }
      carte.appendChild(el('span', 'gs-kpi__libelle', k.libelle));
      carte.appendChild(el('strong', 'gs-kpi__valeur', k.valeur));
      if (k.sous) carte.appendChild(el('span', 'gs-kpi__sous', k.sous));
      zone.appendChild(carte);
    });
  }

  function partie(nom, visible) {
    $$('[data-apercu-partie="' + nom + '"]').forEach(function (n) { n.hidden = !visible; });
  }

  function afficherApercu(v) {
    var p = v.periode || {};
    $('[data-apercu-etat]').textContent = (p.debut === p.fin ? 'Le ' + jourLisible(p.debut) : 'Du ' + jourLisible(p.debut) +
      ' au ' + jourLisible(p.fin)) + ' (jours de Santo Domingo) · chiffres de ' + heure(v.genere_le);

    var c = v.colis || {};
    kpis('colis', [
      { picto: 'colis', teinte: 'bleu', libelle: 'Reçus', valeur: entier(c.recus_periode),
        sous: Number(c.poids_periode) ? O.nombre(Number(c.poids_periode)) + ' lb sur la période' : 'sur la période' },
      { picto: 'livre', teinte: 'vert', libelle: 'Livrés', valeur: entier(c.livres_periode), sous: 'sur la période' },
      { picto: 'route', teinte: 'marine', libelle: 'En cours', valeur: entier(c.actifs), sous: 'maintenant · ' + pluriel(c.total, 'colis au total', 'colis au total'),
        action: function () { viderFiltresColis(); filtrerParStatut('actifs'); } },
      { picto: 'alerte', teinte: 'rouge', libelle: 'Action requise', valeur: entier(c.action_requise), sous: 'maintenant', ton: c.action_requise ? 'critique' : '',
        action: function () { choisirListe('action_requise'); } },
      { picto: 'horloge', teinte: 'orange', libelle: 'Sans mouvement', valeur: entier(c.sans_mouvement), sous: 'aucun événement depuis ' + v.jours_sans_mouvement + ' j ou plus',
        ton: c.sans_mouvement ? 'attention' : '', action: function () { choisirListe('sans_mouvement'); } }
    ]);

    partie('clients', !!v.clients);
    if (v.clients) {
      kpis('clients', [
        { picto: 'clients', teinte: 'bleu', libelle: 'Clients inscrits', valeur: entier(v.clients.total), sous: 'maintenant',
          action: function () { choisirVue('clients'); } },
        { picto: 'nouveau', teinte: 'vert', libelle: 'Nouveaux', valeur: entier(v.clients.nouveaux_periode), sous: 'inscrits sur la période' },
        { picto: 'colis', teinte: 'marine', libelle: 'Avec des colis en cours', valeur: entier(v.clients.avec_colis_en_cours), sous: 'maintenant' }
      ]);
    }

    var f = v.facturation;
    partie('facturation', !!f);
    if (f) {
      kpis('facturation', [
        { picto: 'facture', teinte: 'marine', libelle: 'Facturé', valeur: argent(f.facture_periode),
          sous: pluriel(f.emises_periode, 'facture', 'factures') + ' · payé ' + argent(f.paye_sur_periode) + ' · reste ' + argent(f.solde_sur_periode) },
        { picto: 'argent', teinte: 'vert', libelle: 'Encaissé', valeur: argent(f.encaisse_periode), sous: pluriel(f.paiements_periode, 'paiement reçu', 'paiements reçus') },
        { picto: 'portefeuille', teinte: 'orange', ton: 'fort', libelle: 'À encaisser', valeur: argent(f.a_encaisser),
          sous: pluriel(f.ouvertes, 'facture ouverte', 'factures ouvertes') + ' · ' + pluriel(f.clients_avec_solde, 'client', 'clients'),
          action: function () { choisirFactures('a_payer'); } },
        { picto: 'alerte', teinte: 'rouge', libelle: 'En retard', valeur: argent(f.montant_en_retard), sous: pluriel((f.etats || {}).en_retard, 'facture échue', 'factures échues'),
          ton: (f.etats || {}).en_retard ? 'attention' : '', action: function () { choisirFactures('en_retard'); } }
      ]);
      var etats = el('p', 'gs-apercu__etats');
      ['a_payer', 'partielle', 'en_retard', 'payee', 'annulee'].forEach(function (k) {
        var morceau = el('span', 'gs-apercu__etat-facture');
        morceau.appendChild(badgeFacture(k));
        morceau.appendChild(document.createTextNode(' ' + entier((f.etats || {})[k])));
        etats.appendChild(morceau);
      });
      $('[data-kpis="facturation"]').appendChild(etats);
      grapheJours($('[data-graphe="argent"] [data-graphe-zone]'), f.par_jour, [
        { nom: 'Facturé', cle: 'facture', classe: 'gs-graphe--facture', total: f.facture_periode, format: argent },
        { nom: 'Encaissé', cle: 'encaisse', classe: 'gs-graphe--encaisse', total: f.encaisse_periode, format: argent }
      ]);
    }

    grapheJours($('[data-graphe="colis"] [data-graphe-zone]'), c.par_jour, [
      { nom: 'Reçus', cle: 'recus', classe: 'gs-graphe--recus', total: c.recus_periode, format: entier },
      { nom: 'Livrés', cle: 'livres', classe: 'gs-graphe--livres', total: c.livres_periode, format: entier }
    ]);
    var statuts = c.statuts || {};
    var zoneStatuts = $('[data-graphe="statuts"] [data-graphe-zone]');
    zoneStatuts.textContent = '';
    var liste = el('ul', 'gs-repartition');
    zoneStatuts.appendChild(liste);
    repartition(liste, Object.keys(STATUTS).map(function (k) {
      return { libelle: STATUTS[k], nombre: statuts[k] || 0, pastille: k };
    }), '');

    // Les alertes : celles que la base a levées, rien d'autre
    var alertes = $('[data-alertes]');
    alertes.textContent = '';
    (v.alertes || []).forEach(function (a) {
      var li = el('li', 'gs-alerte-ligne gs-alerte-ligne--' + a.gravite);
      li.appendChild(el('span', 'gs-alerte-ligne__texte', a.message));
      var aller = actionAlerte(a.code);
      if (aller) {
        var b = el('button', 'gs-lien-bouton', 'Voir');
        b.type = 'button';
        b.addEventListener('click', aller);
        li.appendChild(b);
      }
      alertes.appendChild(li);
    });
    if (!(v.alertes || []).length) alertes.appendChild(el('li', 'gs-alerte-ligne gs-alerte-ligne--ok', 'Aucune alerte critique.'));
    majCloche(v.alertes || []);

    partie('activite', !!v.activite);
    if (v.activite) {
      var activite = $('[data-activite]');
      activite.textContent = '';
      v.activite.forEach(function (e) {
        var li = el('li', 'gs-activite__ligne');
        li.appendChild(el('time', 'gs-activite__date', O.date(e.cree_le, true)));
        var corps = el('div', 'gs-activite__corps');
        var tete = el('div', 'gs-activite__tete');
        var numero = el('button', 'gs-lien-bouton gs-cellule-num', e.numero || '—');
        numero.type = 'button';
        numero.setAttribute('aria-label', 'Ouvrir le colis ' + (e.numero || ''));
        if (e.numero) numero.addEventListener('click', function () { ouvrirColisParNumero(e.numero); });
        tete.appendChild(numero);
        tete.appendChild(el('strong', '', e.libelle || libelleTypeEvenement(e.type_evenement)));
        tete.appendChild(badge(e.statut));
        corps.appendChild(tete);
        corps.appendChild(el('span', 'gs-cellule-sous', [e.client, e.lieu, e.auteur ? 'par ' + e.auteur : '',
          SOURCES[e.source] ? 'via ' + SOURCES[e.source] : '', e.corrige ? 'annulé par une correction' : '']
          .filter(Boolean).join(' · ')));
        li.appendChild(corps);
        activite.appendChild(li);
      });
      if (!v.activite.length) activite.appendChild(el('li', 'gs-activite__vide', 'Aucun événement pour l’instant.'));
    }

    partie('scanner', !!v.scanner);
    if (v.scanner) {
      var s = v.scanner, d = s.dernier;
      kpis('scanner', [
        { picto: 'scan', teinte: 'orange', libelle: 'Opérations aujourd’hui', valeur: entier(s.aujourdhui), sous: 'enregistrées au poste de scan' },
        { picto: 'scan', teinte: 'bleu', libelle: 'Sur la période', valeur: entier(s.periode), sous: 'opérations enregistrées' },
        { picto: 'horloge', teinte: 'marine', libelle: 'Dernier scan', valeur: d ? O.date(d.cree_le, true) : 'Aucun',
          sous: d ? [d.numero, libelleTypeEvenement(d.type_evenement), d.auteur ? 'par ' + d.auteur : ''].filter(Boolean).join(' · ') : 'aucune opération encore' }
      ]);
      repartition($('[data-scan-employes]'), (s.par_employe || []).map(function (x) {
        return { libelle: x.nom + (x.role && ROLES[x.role] ? ' (' + ROLES[x.role].toLowerCase() + ')' : ''), nombre: x.nombre };
      }), 'Aucune opération sur la période.');
      repartition($('[data-scan-operations]'), (s.par_operation || []).map(function (x) {
        return { libelle: x.libelle, nombre: x.nombre };
      }), 'Aucune opération sur la période.');
      grapheJours($('[data-graphe="scans"] [data-graphe-zone]'), s.par_jour, [
        { nom: 'Opérations', cle: 'nombre', classe: 'gs-graphe--scans', total: s.periode, format: entier }
      ]);
    }

    partie('paiements_recents', !!v.paiements_recents);
    if (v.paiements_recents) {
      var corpsPaiements = $('[data-lignes="paiements-recents"]');
      corpsPaiements.textContent = '';
      v.paiements_recents.forEach(function (x) {
        var tr = el('tr');
        cellulePleine(tr, 'Reçu le', O.date(x.paye_le, true));
        var tdClient = cellule('Client');
        tdClient.appendChild(el('span', 'gs-cellule-principale', (x.client && x.client.nom_complet) || '—'));
        tdClient.appendChild(el('span', 'gs-cellule-sous', (x.client && x.client.code) || ''));
        tr.appendChild(tdClient);
        var tdFacture = cellule('Facture');
        var lien = el('button', 'gs-lien-bouton gs-cellule-num', x.facture || '—');
        lien.type = 'button';
        lien.addEventListener('click', function () { ouvrirFactureParId(x.facture_id); });
        tdFacture.appendChild(lien);
        tr.appendChild(tdFacture);
        cellulePleine(tr, 'Moyen', MOYENS[x.moyen] || x.moyen || '—');
        cellulePleine(tr, 'Montant', argent(x.montant_usd)).classList.add('gs-cellule-montant');
        corpsPaiements.appendChild(tr);
      });
      $('[data-vide="paiements-recents"]').hidden = v.paiements_recents.length > 0;
      $('.gs-tableau--paiements').closest('.gs-tableau-cadre').hidden = !v.paiements_recents.length;
    }
  }

  function cellulePleine(tr, libelle, texte) {
    var td = cellule(libelle);
    td.textContent = texte;
    tr.appendChild(td);
    return td;
  }

  function choisirFactures(etatFactures) {
    var liste = $('[data-filtre-factures]');
    liste.value = etatFactures;
    liste.dispatchEvent(new Event('change', { bubbles: true }));
    choisirVue('factures');
  }

  // La période : une liste, et deux dates pour « Personnalisée »
  var choixPeriode = $('[data-apercu-periode]');
  choixPeriode.addEventListener('change', function () {
    var perso = choixPeriode.value === 'personnalise';
    $('[data-apercu-dates]').hidden = !perso;
    if (perso) {
      var debut = $('[data-apercu-debut]'), fin = $('[data-apercu-fin]');
      if (!debut.value && etatApercu.donnees) debut.value = etatApercu.donnees.periode.debut;
      if (!fin.value && etatApercu.donnees) fin.value = etatApercu.donnees.periode.fin;
      debut.focus();
      return;
    }
    etatApercu.periode = choixPeriode.value;
    chargerApercu();
  });
  $('[data-action="apercu-appliquer"]').addEventListener('click', function () {
    var debut = $('[data-apercu-debut]').value, fin = $('[data-apercu-fin]').value;
    if (!debut || !fin) { toast('Choisissez une date de début et une date de fin.', true); return; }
    if (fin < debut) { toast('La date de fin est avant la date de début.', true); return; }
    etatApercu.periode = 'personnalise';
    etatApercu.debut = debut;
    etatApercu.fin = fin;
    chargerApercu();
  });
  $('[data-action="apercu-actualiser"]').addEventListener('click', function () {
    chargerApercu();
    chargerStatistiques();
  });

  /* ---- Les colis à traiter ----------------------------------------------------- */
  var DEFINITIONS_TRAITER = {
    action_requise: 'Colis au statut « Action requise » : le client ou l’équipe doit agir. Les plus anciens d’abord ; la note dit pourquoi.',
    sans_mouvement: 'Colis pas encore livrés, sans aucun événement (scan, changement de statut, correction) depuis {n} jours ou plus. Les plus anciens d’abord.'
  };

  function choisirListe(liste) {
    traiter.liste = liste;
    traiter.page = 0;
    $$('[data-traiter-liste]').forEach(function (r) { r.checked = r.value === liste; });
    choisirVue('apercu');
    chargerTraiter();
    var bloc = $('#apercu-traiter-titre');
    if (bloc && bloc.scrollIntoView) bloc.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  function chargerTraiter() {
    if (!peut('shipments.view')) return Promise.resolve();
    var numero = ++traiter.demande;
    var corps = $('[data-lignes="traiter"]');
    var vide = $('[data-vide="traiter"]');
    $('[data-traiter-definition]').textContent = DEFINITIONS_TRAITER[traiter.liste].replace('{n}', traiter.jours);
    corps.closest('.gs-tableau-cadre').setAttribute('aria-busy', 'true');
    return API.admin.colisATraiter(traiter.liste, { jours: traiter.jours, page: traiter.page, parPage: traiter.parPage })
      .then(function (r) {
        if (numero !== traiter.demande) return;
        if (!r.lignes.length && traiter.page > 0 && r.total > 0) {
          traiter.page = Math.ceil(r.total / traiter.parPage) - 1;
          return chargerTraiter();
        }
        afficherTraiter(r);
      }).catch(function (err) {
        if (numero !== traiter.demande) return;
        corps.textContent = '';
        corps.closest('.gs-tableau-cadre').hidden = true;
        vide.textContent = texteErreurApercu(err);
        vide.hidden = false;
        $('[data-pagination="traiter"]').hidden = true;
      }).then(function () { corps.closest('.gs-tableau-cadre').removeAttribute('aria-busy'); });
  }

  function afficherTraiter(r) {
    var corps = $('[data-lignes="traiter"]');
    corps.textContent = '';
    (r.lignes || []).forEach(function (x) {
      var tr = el('tr');
      var tdNum = cellule('Colis');
      tdNum.appendChild(el('span', 'gs-cellule-num', x.numero));
      if (x.description) tdNum.appendChild(el('span', 'gs-cellule-sous', x.description));
      tr.appendChild(tdNum);
      var tdClient = cellule('Client');
      tdClient.appendChild(el('span', 'gs-cellule-principale', x.client ? x.client.nom_complet || '—' : 'Client supprimé'));
      if (x.client) tdClient.appendChild(el('span', 'gs-cellule-sous', [x.client.code, x.client.telephone].filter(Boolean).join(' · ')));
      tr.appendChild(tdClient);
      var tdStatut = cellule('Statut');
      tdStatut.appendChild(badge(x.statut));
      if (x.lieu) tdStatut.appendChild(el('span', 'gs-cellule-sous', x.lieu));
      tr.appendChild(tdStatut);
      var tdEv = cellule('Dernier événement');
      var ev = x.action || x.dernier_evenement;
      if (ev) {
        tdEv.appendChild(el('span', '', libelleTypeEvenement(ev.type_evenement) + ' · ' + O.date(ev.cree_le, true)));
        var details = [ev.note ? '« ' + ev.note + ' »' : '', ev.auteur ? 'par ' + ev.auteur : ''].filter(Boolean).join(' · ');
        if (details) tdEv.appendChild(el('span', 'gs-cellule-sous', details));
      } else {
        tdEv.appendChild(el('span', 'gs-cellule-sous', 'Reçu le ' + O.date(x.recu_le, true)));
      }
      tr.appendChild(tdEv);
      var tdDepuis = cellule('Depuis');
      var jours = Number(x.jours) || 0;
      tdDepuis.appendChild(el('span', 'gs-cellule-principale', jours ? pluriel(jours, 'jour', 'jours') : 'aujourd’hui'));
      tr.appendChild(tdDepuis);
      var tdActions = el('td', 'gs-cellule-actions');
      var ouvrir = el('button', 'gs-bouton gs-bouton--petit gs-bouton--sombre', 'Ouvrir');
      ouvrir.type = 'button';
      ouvrir.setAttribute('aria-label', 'Ouvrir le colis ' + x.numero);
      ouvrir.addEventListener('click', function () { ouvrirColisParNumero(x.numero); });
      tdActions.appendChild(ouvrir);
      tr.appendChild(tdActions);
      corps.appendChild(tr);
    });
    var vide = $('[data-vide="traiter"]');
    vide.hidden = (r.lignes || []).length > 0;
    vide.textContent = traiter.liste === 'action_requise' ? 'Aucun colis en « action requise ».'
      : 'Aucun colis sans mouvement depuis ' + traiter.jours + ' jours.';
    corps.closest('.gs-tableau-cadre').hidden = !(r.lignes || []).length;
    paginer('traiter', traiter, r.total, function () { chargerTraiter(); });
  }

  $$('[data-traiter-liste]').forEach(function (r) {
    r.addEventListener('change', function () { if (r.checked) choisirListe(r.value); });
  });
  $('[data-traiter-jours]').addEventListener('change', function (e) {
    traiter.jours = Number(e.target.value) || 7;
    traiter.page = 0;
    // Le chiffre « Sans mouvement » de la vue générale suit le même réglage
    chargerApercu();
  });

  /* ---- La recherche rapide ------------------------------------------------------
     La base cherche (recherche_rapide) : numéro de colis ou son début, suivi
     du vendeur, code-barres, QR d'étiquette, code client, nom, fin du
     téléphone, e-mail, numéro de facture. Rien n'est filtré dans la page. */
  var formRapide = $('form[data-form="recherche-rapide"]');
  var champRapide = $('[data-rapide-texte]');
  var zoneRapide = $('[data-rapide-resultats]');
  var demandeRapide = 0, delaiRapide = null;

  function fermerRapide() {
    ++demandeRapide;
    zoneRapide.hidden = true;
    zoneRapide.textContent = '';
  }

  function chercherRapide(texte) {
    texte = String(texte || '').trim();
    clearTimeout(delaiRapide);
    if (texte.length < 2) { fermerRapide(); return; }
    var numero = ++demandeRapide;
    zoneRapide.hidden = false;
    zoneRapide.setAttribute('aria-busy', 'true');
    API.admin.rechercheRapide(texte).then(function (r) {
      if (numero !== demandeRapide) return;
      afficherRapide(r);
    }).catch(function (err) {
      if (numero !== demandeRapide) return;
      zoneRapide.textContent = '';
      zoneRapide.appendChild(teteRapide('Recherche impossible'));
      zoneRapide.appendChild(el('p', 'gs-rapide__message', err.code === 'absent'
        ? 'La recherche rapide attend outils/supabase-tableau-de-bord.sql dans Supabase (SQL Editor).' : texteErreurApercu(err)));
    }).then(function () { zoneRapide.removeAttribute('aria-busy'); });
  }

  function teteRapide(titre) {
    var tete = el('div', 'gs-rapide__tete');
    tete.appendChild(el('h2', 'gs-rapide__titre', titre));
    var fermer = el('button', 'gs-lien-bouton', 'Fermer');
    fermer.type = 'button';
    fermer.addEventListener('click', function () { fermerRapide(); champRapide.focus(); });
    tete.appendChild(fermer);
    return tete;
  }

  function carteRapide(lignes, actions) {
    var li = el('li', 'gs-rapide__carte');
    lignes.forEach(function (l) { if (l) li.appendChild(l); });
    if (actions.length) {
      var zone = el('div', 'gs-rapide__actions');
      actions.forEach(function (a) {
        var b = el('button', 'gs-bouton gs-bouton--petit ' + (a.classe || 'gs-bouton--contour'), a.texte);
        b.type = 'button';
        b.addEventListener('click', a.faire);
        zone.appendChild(b);
      });
      li.appendChild(zone);
    }
    return li;
  }

  function ligneTexte(classe, morceaux) {
    var texte = morceaux.filter(Boolean).join(' · ');
    return texte ? el('p', classe, texte) : null;
  }

  function afficherRapide(r) {
    zoneRapide.textContent = '';
    var colis = r.colis || [], clients = r.clients || [], factures = r.factures || [];
    var n = colis.length + clients.length + factures.length;
    zoneRapide.appendChild(teteRapide(n ? pluriel(n, 'résultat', 'résultats') + ' pour « ' + r.texte + ' »'
                                        : 'Aucun résultat pour « ' + r.texte + ' »'));
    if (!n) {
      zoneRapide.appendChild(el('p', 'gs-rapide__message', 'Essayez le numéro complet du colis ou de la facture, le code GSE du client, ' +
        'le début de son nom ou les 4 derniers chiffres de son téléphone.'));
      return;
    }
    function section(titre, elements) {
      if (!elements.length) return;
      zoneRapide.appendChild(el('h3', 'gs-rapide__section', titre));
      var liste = el('ul', 'gs-rapide__liste');
      elements.forEach(function (x) { liste.appendChild(x); });
      zoneRapide.appendChild(liste);
    }
    section('Colis', colis.map(function (c) {
      var tete = el('p', 'gs-rapide__ligne-tete');
      tete.appendChild(el('strong', 'gs-cellule-num', c.numero));
      tete.appendChild(badge(c.statut));
      var ev = c.dernier_evenement;
      var facture = c.facture;
      var ligneFacture = null;
      if (facture) {
        ligneFacture = el('p', 'gs-rapide__ligne');
        ligneFacture.appendChild(document.createTextNode('Facture ' + facture.numero + ' · '));
        ligneFacture.appendChild(badgeFacture(facture.etat));
        ligneFacture.appendChild(document.createTextNode(' · solde ' + argent(facture.solde_usd)));
      } else if (peut('invoices.view')) {
        ligneFacture = el('p', 'gs-rapide__ligne', 'Sur aucune facture active');
      }
      var actions = [{ texte: 'Ouvrir', classe: 'gs-bouton--sombre', faire: function () { ouvrirColisParNumero(c.numero); } }];
      if (facture) actions.push({ texte: 'Voir la facture', faire: function () { ouvrirFactureParId(facture.id); } });
      return carteRapide([
        tete,
        ligneTexte('gs-rapide__ligne', [c.client ? c.client.nom_complet + ' (' + c.client.code + ')' : 'Client supprimé',
          [c.destination, PAYS[c.pays_destination]].filter(Boolean).join(', '),
          c.poids_lb != null ? O.nombre(Number(c.poids_lb)) + ' lb' : 'poids non renseigné', c.description]),
        ev ? ligneTexte('gs-rapide__ligne gs-cellule-sous', ['Dernier événement : ' + libelleTypeEvenement(ev.type_evenement),
          O.date(ev.cree_le, true), ev.lieu, ev.auteur ? 'par ' + ev.auteur : '']) : null,
        ligneFacture
      ], actions);
    }));
    section('Clients', clients.map(function (cl) {
      var tete = el('p', 'gs-rapide__ligne-tete');
      tete.appendChild(el('strong', '', cl.nom_complet || '—'));
      tete.appendChild(el('span', 'gs-cellule-num', cl.code || ''));
      var actions = [{ texte: 'Ses colis', faire: function () { fermerRapide(); filtrerParClient(cl); } }];
      if (peut('shipments.create')) actions.push({ texte: '+ Colis', faire: function () { ouvrirColis({ code: cl.code }); } });
      return carteRapide([
        tete,
        ligneTexte('gs-rapide__ligne', [cl.telephone, [cl.ville, PAYS[cl.pays] || cl.pays].filter(Boolean).join(', '), cl.email]),
        ligneTexte('gs-rapide__ligne gs-cellule-sous', [pluriel(cl.colis_en_cours, 'colis en cours', 'colis en cours'),
          cl.solde_usd == null ? '' : (Number(cl.solde_usd) > 0 ? 'solde ' + argent(cl.solde_usd) : 'rien à payer')])
      ], actions);
    }));
    section('Factures', factures.map(function (f) {
      var tete = el('p', 'gs-rapide__ligne-tete');
      tete.appendChild(el('strong', 'gs-cellule-num', f.numero));
      tete.appendChild(badgeFacture(f.etat));
      return carteRapide([
        tete,
        ligneTexte('gs-rapide__ligne', [f.client && f.client.nom_complet, f.client && f.client.code, O.date(f.cree_le)]),
        ligneTexte('gs-rapide__ligne gs-cellule-sous', ['total ' + argent(f.montant_usd), 'payé ' + argent(f.paye_usd),
          'solde ' + argent(f.solde_usd)])
      ], [{ texte: 'Ouvrir', classe: 'gs-bouton--sombre', faire: function () { ouvrirFactureParId(f.id); } }]);
    }));
  }

  formRapide.addEventListener('submit', function (e) {
    e.preventDefault();
    chercherRapide(champRapide.value);
  });
  champRapide.addEventListener('input', function () {
    clearTimeout(delaiRapide);
    var texte = champRapide.value;
    delaiRapide = setTimeout(function () { chercherRapide(texte); }, 400);
  });
  champRapide.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') { champRapide.value = ''; fermerRapide(); }
  });

  /* ---- Le cadre : horloge, menu, panneaux de la barre du haut -----------------
     Rien ici ne lit ni n'écrit une donnée de la base : c'est la présentation
     de ce que les autres parties de ce fichier chargent déjà. */

  // Les préférences d'affichage, gardées sur cet appareil seulement
  var CLE_REGLAGES = 'gse-tableau-reglages';
  var REGLAGES_DEFAUT = { periode: '30j', parPage: 25, jours: 7, menuReduit: false, secondes: false, notifications: true };
  var PERIODES_REGLAGES = ['aujourdhui', '7j', '30j', 'mois', 'mois_precedent', 'annee'];
  function lireReglages() {
    var r = Object.assign({}, REGLAGES_DEFAUT), lu = {};
    try { lu = JSON.parse(localStorage.getItem(CLE_REGLAGES) || '{}') || {}; } catch (e) { lu = {}; }
    if (PERIODES_REGLAGES.indexOf(lu.periode) >= 0) r.periode = lu.periode;
    if (TAILLES_PAGE.indexOf(Number(lu.parPage)) >= 0) r.parPage = Number(lu.parPage);
    if ([3, 7, 14, 30].indexOf(Number(lu.jours)) >= 0) r.jours = Number(lu.jours);
    r.menuReduit = lu.menuReduit === true;
    r.secondes = lu.secondes === true;
    r.notifications = lu.notifications !== false;
    return r;
  }
  function ecrireReglages() {
    try { localStorage.setItem(CLE_REGLAGES, JSON.stringify(reglages)); } catch (e) { /* navigation privée : tant pis */ }
  }
  var reglages = lireReglages();

  // La date et l'heure de cet appareil, toujours visibles en haut de l'écran
  var horloge = { date: $('[data-horloge-date]'), court: $('[data-horloge-date-courte]'), heure: $('[data-horloge-heure]'), jour: '' };
  function majHorloge() {
    var t = new Date();
    var jour = t.getFullYear() + '-' + deux(t.getMonth() + 1) + '-' + deux(t.getDate());
    if (jour !== horloge.jour) {
      horloge.jour = jour;
      try {
        var long = new Intl.DateTimeFormat('fr-FR', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' }).format(t);
        horloge.date.textContent = long.charAt(0).toUpperCase() + long.slice(1);
        horloge.court.textContent = new Intl.DateTimeFormat('fr-FR', { weekday: 'short', day: 'numeric', month: 'short' }).format(t);
      } catch (e) {
        horloge.date.textContent = horloge.court.textContent = deux(t.getDate()) + '/' + deux(t.getMonth() + 1) + '/' + t.getFullYear();
      }
    }
    var texte = deux(t.getHours()) + ':' + deux(t.getMinutes()) + (reglages.secondes ? ':' + deux(t.getSeconds()) : '');
    if (horloge.heure.textContent !== texte) {
      horloge.heure.textContent = texte;
      horloge.heure.setAttribute('datetime', jour + 'T' + deux(t.getHours()) + ':' + deux(t.getMinutes()));
    }
  }
  majHorloge();
  setInterval(majHorloge, 1000);

  // Le menu : un tiroir sur téléphone et tablette, réductible sur ordinateur
  var burger = $('[data-action="ouvrir-menu"]');
  var voile = $('.gs-td__voile');
  function ouvrirMenu() {
    document.body.classList.add('is-menu-ouvert');
    voile.hidden = false;
    burger.setAttribute('aria-expanded', 'true');
    var actif = $('[data-onglet-vue][aria-selected="true"]');
    if (actif) actif.focus();
  }
  function fermerMenu() {
    if (!document.body.classList.contains('is-menu-ouvert')) return;
    document.body.classList.remove('is-menu-ouvert');
    voile.hidden = true;
    burger.setAttribute('aria-expanded', 'false');
  }
  burger.addEventListener('click', function () {
    if (document.body.classList.contains('is-menu-ouvert')) fermerMenu(); else ouvrirMenu();
  });
  voile.addEventListener('click', fermerMenu);
  $('[data-action="replier-menu"]').addEventListener('click', function () {
    majReglage('menuReduit', !reglages.menuReduit);
  });

  // Les deux panneaux de la barre : les alertes (cloche) et le compte
  var deroulants = [
    { bouton: $('[data-action="alertes"]'), panneau: $('[data-panneau-alertes]') },
    { bouton: $('[data-action="menu-compte"]'), panneau: $('[data-menu-compte]') }
  ];
  function fermerPanneaux(sauf) {
    deroulants.forEach(function (d) {
      if (d === sauf) return;
      d.panneau.hidden = true;
      d.bouton.setAttribute('aria-expanded', 'false');
    });
  }
  deroulants.forEach(function (d) {
    d.bouton.addEventListener('click', function (e) {
      e.stopPropagation();
      var ouvrir = d.panneau.hidden;
      fermerPanneaux(d);
      d.panneau.hidden = !ouvrir;
      d.bouton.setAttribute('aria-expanded', String(ouvrir));
      // La cloche lit les alertes de la vue générale : chargées si elles ne le sont pas encore
      if (ouvrir && d.panneau.hasAttribute('data-panneau-alertes') && !etatApercu.donnees) chargerApercu();
    });
    d.panneau.addEventListener('click', function (e) { e.stopPropagation(); });
  });
  document.addEventListener('click', function () { fermerPanneaux(null); });
  document.addEventListener('keydown', function (e) {
    if (e.key !== 'Escape') return;
    fermerPanneaux(null);
    fermerMenu();
  });
  $$('[data-menu-compte] .gs-td__lien').forEach(function (b) { b.addEventListener('click', function () { fermerPanneaux(null); }); });

  // Ce que fait « Voir » sur une alerte, dans la vue générale comme sous la cloche
  function actionAlerte(code) {
    return {
      action_requise: function () { choisirListe('action_requise'); },
      sans_mouvement: function () { choisirListe('sans_mouvement'); },
      factures_en_retard: function () { choisirFactures('en_retard'); },
      colis_sans_facture: peut('reports.view')
        ? function () { choisirVue('factures'); $('[data-action="controler-factures"]').click(); } : null
    }[code] || null;
  }

  function majCloche(alertes) {
    annoncerAlertes(alertes);
    var compteur = $('[data-alertes-nombre]');
    compteur.textContent = String(alertes.length);
    compteur.hidden = !alertes.length;
    compteur.classList.toggle('is-critique', alertes.some(function (a) { return a.gravite === 'critique'; }));
    var liste = $('[data-alertes-cloche]');
    liste.textContent = '';
    alertes.forEach(function (a) {
      var li = el('li', 'gs-alerte-ligne gs-alerte-ligne--' + a.gravite);
      li.appendChild(el('span', 'gs-alerte-ligne__texte', a.message));
      var aller = actionAlerte(a.code);
      if (aller) {
        var b = el('button', 'gs-lien-bouton', 'Voir');
        b.type = 'button';
        b.addEventListener('click', function () { fermerPanneaux(null); aller(); });
        li.appendChild(b);
      }
      liste.appendChild(li);
    });
    if (!alertes.length) liste.appendChild(el('li', 'gs-alerte-ligne gs-alerte-ligne--ok', 'Aucune alerte critique.'));
  }
  $('[data-alertes-cloche]').appendChild(el('li', 'gs-alerte-ligne', 'Chargement des alertes…'));

  /* ---- Les réglages --------------------------------------------------------------- */
  var dlgReglages = $('[data-dialogue="reglages"]');
  var rubriques = $$('[data-reglages-rubrique]', dlgReglages);

  // Les préférences s'appliquent au tableau de bord : période, listes, menu, horloge
  function appliquerReglages() {
    etatApercu.periode = reglages.periode;
    etatApercu.debut = etatApercu.fin = '';
    choixPeriode.value = reglages.periode;
    $('[data-apercu-dates]').hidden = true;
    etat.colis.parPage = etat.clients.parPage = traiter.parPage = reglages.parPage;
    etat.colis.page = etat.clients.page = traiter.page = 0;
    traiter.jours = reglages.jours;
    $('[data-traiter-jours]').value = String(reglages.jours);
    appliquerMenu();
  }
  function appliquerMenu() {
    document.body.classList.toggle('is-menu-reduit', reglages.menuReduit);
    var b = $('[data-action="replier-menu"]');
    b.setAttribute('aria-pressed', String(reglages.menuReduit));
    b.setAttribute('aria-label', reglages.menuReduit ? 'Déplier le menu' : 'Réduire le menu');
    b.title = b.getAttribute('aria-label');
  }

  function majReglage(cle, valeur) {
    reglages[cle] = valeur;
    ecrireReglages();
    if (cle === 'periode') {
      etatApercu.periode = valeur;
      etatApercu.debut = etatApercu.fin = '';
      choixPeriode.value = valeur;
      $('[data-apercu-dates]').hidden = true;
      chargerApercu();
    } else if (cle === 'parPage') {
      etat.colis.parPage = etat.clients.parPage = traiter.parPage = valeur;
      etat.colis.page = etat.clients.page = traiter.page = 0;
      chargerColis();
      if (peut('clients.view')) chargerClients();
      chargerTraiter();
    } else if (cle === 'jours') {
      traiter.jours = valeur;
      traiter.page = 0;
      $('[data-traiter-jours]').value = String(valeur);
      chargerApercu();
    } else if (cle === 'menuReduit') {
      appliquerMenu();
      var controle = $('[data-reglage="menuReduit"]', dlgReglages);
      if (controle) controle.checked = valeur;
    } else if (cle === 'secondes') {
      majHorloge();
    } else if (cle === 'notifications' && valeur) {
      demanderNotifications();
    }
  }

  function choisirRubrique(nom) {
    rubriques.forEach(function (b) {
      var actif = b.getAttribute('data-reglages-rubrique') === nom;
      b.setAttribute('aria-selected', String(actif));
      b.tabIndex = actif ? 0 : -1;
    });
    $$('[data-reglages-section]', dlgReglages).forEach(function (s) {
      s.hidden = s.getAttribute('data-reglages-section') !== nom;
    });
  }
  rubriques.forEach(function (b) {
    b.addEventListener('click', function () { choisirRubrique(b.getAttribute('data-reglages-rubrique')); });
    b.addEventListener('keydown', function (e) {
      var sens = { ArrowDown: 1, ArrowRight: 1, ArrowUp: -1, ArrowLeft: -1 }[e.key];
      if (!sens) return;
      e.preventDefault();
      var visibles = rubriques.filter(function (o) { return !o.hasAttribute('data-interdit'); });
      var autre = visibles[(visibles.indexOf(b) + sens + visibles.length) % visibles.length];
      autre.focus();
      choisirRubrique(autre.getAttribute('data-reglages-rubrique'));
    });
  });

  function reglageScanner(cle, defaut) {
    try { var v = localStorage.getItem('gse-scan-' + cle); return v === null ? defaut : v; } catch (e) { return defaut; }
  }

  function ouvrirReglages() {
    fermerPanneaux(null);
    fermerMenu();
    $$('[data-reglage]', dlgReglages).forEach(function (c) {
      var cle = c.getAttribute('data-reglage');
      if (c.type === 'checkbox') c.checked = !!reglages[cle]; else c.value = String(reglages[cle]);
    });
    $('[data-reglages-role]', dlgReglages).textContent = ROLES[droits.role] || '—';
    $('[data-reglages-permissions]', dlgReglages).textContent = pluriel(droits.permissions.length, 'permission', 'permissions');
    $('[data-reglages-mode]', dlgReglages).textContent = API.mode === 'demo'
      ? 'Démonstration : données enregistrées dans ce navigateur seulement' : 'Base de données en ligne (Supabase)';
    if (BUREAU) {
      $('[data-bureau-info]', dlgReglages).textContent = 'GoShip Express ' + BUREAU.version + ' pour ' +
        ({ windows: 'Windows', macos: 'macOS', linux: 'Linux' }[BUREAU.plateforme] || BUREAU.plateforme) + ' — chargement…';
      BUREAU.sessionChiffree().then(function (oui) {
        $('[data-bureau-info]', dlgReglages).textContent = 'GoShip Express ' + BUREAU.version + ' pour ' +
          ({ windows: 'Windows', macos: 'macOS', linux: 'Linux' }[BUREAU.plateforme] || BUREAU.plateforme) +
          (oui ? ' · session chiffrée par le système' : ' · session gardée en mémoire (reconnexion à chaque lancement)');
      }).catch(function () { /* l'information reste générale */ });
    }
    $('[data-reglages-direct]', dlgReglages).textContent = $('[data-direct]').hidden
      ? 'Inactives : les listes se mettent à jour à chaque action et avec « Actualiser »' : 'Actives';
    var mode = reglageScanner('mode', '');
    var type = mode && API.regles.typesEvenement[mode];
    $('[data-reglages-scan-mode]', dlgReglages).textContent = type ? 'Rapide : « ' + type.libelle + ' » à chaque scan'
      : 'Consulter, puis choisir l’opération';
    $('[data-reglages-scan-lieu]', dlgReglages).textContent = reglageScanner('lieu', '') || 'Non renseigné';
    $('[data-reglages-scan-son]', dlgReglages).textContent = reglageScanner('son', 'oui') === 'oui' ? 'Activé' : 'Coupé';
    choisirRubrique('affichage');
    dlgReglages.showModal();
  }
  $$('[data-action="ouvrir-reglages"]').forEach(function (b) { b.addEventListener('click', ouvrirReglages); });

  $$('[data-reglage]', dlgReglages).forEach(function (c) {
    c.addEventListener('change', function () {
      var cle = c.getAttribute('data-reglage');
      majReglage(cle, c.type === 'checkbox' ? c.checked : (cle === 'periode' ? c.value : Number(c.value)));
    });
  });
  $('[data-action="reglages-defaut"]', dlgReglages).addEventListener('click', function () {
    reglages = Object.assign({}, REGLAGES_DEFAUT);
    ecrireReglages();
    appliquerReglages();
    majHorloge();
    $$('[data-reglage]', dlgReglages).forEach(function (c) {
      var cle = c.getAttribute('data-reglage');
      if (c.type === 'checkbox') c.checked = !!reglages[cle]; else c.value = String(reglages[cle]);
    });
    chargerApercu();
    chargerColis();
    if (peut('clients.view')) chargerClients();
    toast('Affichage par défaut rétabli.');
  });
  $('[data-action="reglages-equipe"]', dlgReglages).addEventListener('click', function () {
    dlgReglages.close();
    choisirVue('equipe');
    var roles = $('details.gs-roles');
    if (roles) roles.open = true;
  });
  $('[data-action="reglages-scanner"]', dlgReglages).addEventListener('click', function () {
    dlgReglages.close();
    $('[data-onglet-vue="scanner"]').click();
  });

  /* ---- Le poste de travail : raccourcis, réseau, session, application de bureau --
     Les raccourcis marchent aussi dans un navigateur. Le reste ne sert que dans
     l'application GoShip Express pour Windows et macOS (bureau/), qui donne
     window.GoshipBureau : commandes du menu, notifications du système. Tout
     passe par les mêmes fonctions que les boutons : rien de métier ici. */
  var POSTE = window.GoshipBureau || null;
  var BUREAU_CONTRAT_MIN = 1;      // le pont dont ce tableau de bord a besoin (bureau/src/pont.js)
  var BUREAU = POSTE && POSTE.contrat >= BUREAU_CONTRAT_MIN ? POSTE : null;
  function tableauOuvert() { return !$('[data-ecran="tableau"]').hidden; }

  function ouvrirRecherche() {
    if (!tableauOuvert()) return;
    fermerPanneaux(null);
    fermerMenu();
    champRapide.focus();
    champRapide.select();
  }
  function ouvrirScanner() {
    if (!tableauOuvert()) return;
    var onglet = $('[data-onglet-vue="scanner"]');
    if (!onglet || onglet.hasAttribute('data-interdit')) {
      toast('Vous n’avez pas la permission d’utiliser le poste de scan.', true);
      return;
    }
    onglet.click();
  }
  // Ctrl+K (⌘K) : recherche rapide ; Ctrl+Maj+S (⌘⇧S) : poste de scan. La lettre
  // tapée d'abord (AZERTY comme QWERTY), la position de la touche sinon.
  document.addEventListener('keydown', function (e) {
    if (!(e.ctrlKey || e.metaKey) || e.altKey || document.querySelector('dialog[open]')) return;
    var touche = String(e.key || '').toLowerCase();
    if (!/^[a-z]$/.test(touche)) touche = { KeyK: 'k', KeyS: 's' }[e.code] || touche;
    if (touche === 'k' && !e.shiftKey) { e.preventDefault(); ouvrirRecherche(); }
    else if (touche === 's' && e.shiftKey) { e.preventDefault(); ouvrirScanner(); }
  });

  // Réseau coupé : le dire, et ne rien laisser croire enregistré ; au retour, tout recharger
  var bandeauHorsLigne = $('[data-hors-ligne]');
  function majConnexion() {
    var coupe = navigator.onLine === false;
    var etaitCoupe = !bandeauHorsLigne.hidden;
    bandeauHorsLigne.hidden = !coupe;
    if (etaitCoupe && !coupe && tableauOuvert()) {
      toast('Connexion rétablie : les données sont actualisées.');
      toutRecharger('connexion');
    }
  }
  window.addEventListener('online', majConnexion);
  window.addEventListener('offline', majConnexion);
  majConnexion();

  // Session terminée sans « Déconnexion » (jeton expiré ou révoqué) : retour à la
  // connexion, avec la raison. Rien n'est effacé côté serveur.
  API.surSessionPerdue(function () {
    if (deconnexionVoulue || !tableauOuvert()) return;
    arreterSurveillance();
    arreterSurveillance = function () {};
    $$('dialog[open]').forEach(function (d) { d.close(); });
    $('[data-barre-connecte]').hidden = true;
    ecran('connexion');
    erreurFormulaire(formConnexion, 'Votre session a expiré : reconnectez-vous. Rien n’a été perdu, les données sont sur le serveur.');
    notificationSysteme('Session expirée', 'Reconnectez-vous pour continuer.', 'session');
  });

  // Notifications du système, dans l'application de bureau : une alerte qui
  // apparaît ou grossit (les alertes de la vue générale, rien d'autre) pendant
  // que la fenêtre n'est pas au premier plan. Jamais à la première lecture.
  var alertesConnues = null;
  function notificationsActives() { return !!(BUREAU && reglages.notifications && 'Notification' in window); }
  function demanderNotifications() {
    if (notificationsActives() && Notification.permission === 'default') Notification.requestPermission();
  }
  function notificationSysteme(titre, texte, etiquette, action) {
    if (!notificationsActives() || Notification.permission !== 'granted') return;
    try {
      var n = new Notification(titre, { body: texte, tag: etiquette });
      n.onclick = function () { window.focus(); if (action) action(); };
    } catch (e) { BUREAU.journal('erreur', 'notification impossible : ' + e.message); }
  }
  function annoncerAlertes(alertes) {
    var avant = alertesConnues;
    alertesConnues = {};
    alertes.forEach(function (a) { alertesConnues[a.code] = Number(a.nombre) || 1; });
    if (!avant || document.hasFocus()) return;
    alertes.forEach(function (a) {
      if (a.gravite === 'info' || (avant[a.code] || 0) >= (Number(a.nombre) || 1)) return;
      notificationSysteme(a.gravite === 'critique' ? 'GoShip Express — action requise' : 'GoShip Express', a.message,
               'alerte-' + a.code, actionAlerte(a.code));
    });
  }

  if (BUREAU) {
    BUREAU.surCommande(function (nom) {
      if (nom === 'recherche') ouvrirRecherche();
      else if (nom === 'scanner') ouvrirScanner();
      else if (nom === 'reglages' && tableauOuvert()) ouvrirReglages();
    });
    $$('[data-bureau-seulement]').forEach(function (n) { n.hidden = false; });
    demanderNotifications();
  } else if (POSTE) {
    $('[data-bureau-ancien]').hidden = false;
  }

  /* ---- Analytics ------------------------------------------------------------------
     Ce qui s'est passé et comment cela évolue (outils/supabase-analytics.sql).
     La base compte tout, sur les vraies tables, et compare chaque période à la
     précédente ; la page met en forme, sans rien additionner. Chargé à
     l'ouverture d'une rubrique et sur « Actualiser », jamais en direct : une
     réponse est gardée une minute pour passer d'une rubrique à l'autre sans
     recompter, et « Actualiser » l'oublie. */
  var etatAnalytics = { module: 'synthese', periode: '30j', debut: '', fin: '', decoupage: 'jour', tri: 'colis',
                        page: 0, parPage: 25, demande: 0, memoire: {}, tables: [], titre: '' };
  var corpsAnalytics = $('[data-analytics-corps]');
  var messageAnalytics = $('[data-analytics-message]');
  var ongletsAnalytics = $$('[data-analytics-module]');
  var NOMS_MODULES = { synthese: 'Synthèse', expeditions: 'Expéditions', operations: 'Opérations', clients: 'Clients',
                       finances: 'Finances', routes: 'Routes et destinations', scanner: 'Scanner', qualite: 'Qualité des données' };
  var PAYS_NOMS = { HT: 'Haïti', DO: 'République dominicaine', US: 'États-Unis' };

  // Une réponse de la base, gardée une minute (même module, mêmes réglages)
  function lireAnalytics(module, options) {
    var o = Object.assign({ periode: etatAnalytics.periode, debut: etatAnalytics.debut, fin: etatAnalytics.fin }, options || {});
    var cle = module + '|' + JSON.stringify(o);
    var garde = etatAnalytics.memoire[cle];
    if (garde && Date.now() - garde.t < 60000) return Promise.resolve(garde.r);
    return API.admin.analytics(module, o).then(function (r) {
      etatAnalytics.memoire[cle] = { t: Date.now(), r: r };
      return r;
    });
  }

  function texteErreurAnalytics(err) {
    if (err && err.code === 'non-autorise') {
      return 'Accès refusé : les Analytics sont réservées aux comptes qui voient les rapports (gérant, administrateur).';
    }
    if (err && err.code === 'absent') {
      return 'Les Analytics ne sont pas encore installées : lancez outils/supabase-analytics.sql dans Supabase (SQL Editor), puis « Actualiser ».';
    }
    if (err && err.code === 'reseau') return 'Connexion impossible : les données n’ont pas pu être chargées. Vérifiez la connexion, puis « Actualiser ».';
    return 'Impossible de calculer ces statistiques. ' + messageErreur(err);
  }

  // ---- Mise en forme : jamais de NaN, d'Infinity ni d'undefined à l'écran
  function nombreOuTiret(n, format) { return n == null || !isFinite(Number(n)) ? '—' : format(Number(n)); }
  function pourcent(n) { return nombreOuTiret(n, function (x) { return O.nombre(x) + ' %'; }); }
  function duree(h) {
    return nombreOuTiret(h, function (x) {
      return x < 48 ? O.nombre(Math.round(x * 10) / 10) + ' h' : O.nombre(Math.round(x / 24 * 10) / 10) + ' j';
    });
  }
  function poidsLb(n) { return nombreOuTiret(n, function (x) { return O.nombre(x) + ' lb'; }); }
  function nomPays(code) { return PAYS_NOMS[code] || code || '—'; }
  function nomService(code) { return SERVICES[code] || code || '—'; }
  function nomStatut(code) { return STATUTS[code] || code || '—'; }
  function nomMoyen(code) { return MOYENS[code] || code || '—'; }
  function caseLisible(c, court) {
    if (etatAnalytics.decoupage === 'mois') {
      try { return new Intl.DateTimeFormat('fr-FR', { month: court ? 'short' : 'long', year: 'numeric' }).format(new Date(c.jour + 'T12:00:00Z')); }
      catch (e) { return c.jour.slice(0, 7); }
    }
    if (etatAnalytics.decoupage === 'semaine') return (court ? '' : 'semaine du ') + jourLisible(c.debut, court);
    return jourLisible(c.jour, court);
  }

  // Une comparaison : « +12,5 % », « nouveau », ou « stable » — et le chiffre d'avant
  function variation(cmp, format) {
    if (!cmp) return { texte: '—', classe: '' };
    var sens = cmp.tendance === 'hausse' ? '↗' : (cmp.tendance === 'baisse' ? '↘' : '→');
    var texte;
    if (cmp.variation_pct != null) texte = (cmp.variation_pct > 0 ? '+' : '') + O.nombre(cmp.variation_pct) + ' %';
    else if (Number(cmp.actuel)) texte = 'nouveau';
    else texte = 'stable';
    return { texte: sens + ' ' + texte, classe: 'gs-variation--' + (cmp.tendance || 'stable'),
             precedent: 'avant : ' + format(cmp.precedent) };
  }

  function carte(libelle, cmp, format, note) {
    var c = el('div', 'gs-kpi gs-kpi--analytics');
    c.appendChild(el('span', 'gs-kpi__libelle', libelle));
    c.appendChild(el('strong', 'gs-kpi__valeur', cmp && typeof cmp === 'object' ? format(cmp.actuel) : format(cmp)));
    if (cmp && typeof cmp === 'object') {
      var v = variation(cmp, format);
      var ligne = el('span', 'gs-kpi__sous');
      ligne.appendChild(el('span', 'gs-variation ' + v.classe, v.texte));
      ligne.appendChild(document.createTextNode(' · ' + v.precedent));
      c.appendChild(ligne);
    }
    if (note) c.appendChild(el('span', 'gs-kpi__sous', note));
    return c;
  }

  function grille(cartes) {
    var g = el('div', 'gs-kpis');
    cartes.forEach(function (c) { g.appendChild(c); });
    return g;
  }

  function section(titre, aide) {
    var s = el('section', 'gs-apercu__bloc gs-analytics__section');
    s.appendChild(el('h2', 'gs-apercu__titre', titre));
    if (aide) s.appendChild(el('p', 'gs-apercu__note', aide));
    corpsAnalytics.appendChild(s);
    return s;
  }

  // Un tableau lisible, gardé pour l'export : colonnes [{ titre, valeur(ligne), brut(ligne), nombre }]
  function tableau(parent, titre, colonnes, lignes, vide) {
    etatAnalytics.tables.push({ titre: titre, colonnes: colonnes, lignes: lignes });
    if (!lignes.length) {
      parent.appendChild(el('p', 'gs-admin-vide', vide || 'Aucune donnée disponible pour cette période.'));
      return;
    }
    var cadre = el('div', 'gs-tableau-cadre');
    var t = el('table', 'gs-tableau gs-tableau--analytics');
    var cap = el('caption', 'gs-invisible', titre);
    t.appendChild(cap);
    var tete = el('tr');
    colonnes.forEach(function (c) {
      var th = el('th', c.nombre ? 'gs-nombre' : '', c.titre);
      th.scope = 'col';
      tete.appendChild(th);
    });
    var thead = el('thead');
    thead.appendChild(tete);
    t.appendChild(thead);
    var tbody = el('tbody');
    lignes.forEach(function (l) {
      var tr = el('tr');
      colonnes.forEach(function (c) {
        var td = cellule(c.titre);
        if (c.nombre) td.className = 'gs-nombre';
        td.textContent = c.valeur(l);
        tr.appendChild(td);
      });
      tbody.appendChild(tr);
    });
    t.appendChild(tbody);
    cadre.appendChild(t);
    parent.appendChild(cadre);
  }

  // Une phrase qui décrit, sans expliquer : « a augmenté de 18 % par rapport à la période précédente »
  function phrase(libelle, cmp, format) {
    if (!cmp) return null;
    var a = format(cmp.actuel), b = format(cmp.precedent);
    if (cmp.tendance === 'stable') return libelle + ' : stable (' + a + ').';
    if (cmp.variation_pct == null) return libelle + ' : ' + a + ', contre aucun sur la période précédente.';
    return libelle + ' : ' + (cmp.tendance === 'hausse' ? 'en hausse' : 'en baisse') + ' de ' +
           O.nombre(Math.abs(cmp.variation_pct)) + ' % par rapport à la période précédente (' + a + ' contre ' + b + ').';
  }

  function definitions(parent, liste) {
    var d = el('details', 'gs-definitions');
    d.appendChild(el('summary', '', 'Définitions et sources'));
    var dl = el('dl');
    liste.forEach(function (x) {
      dl.appendChild(el('dt', '', x[0]));
      dl.appendChild(el('dd', '', x[1]));
    });
    d.appendChild(dl);
    parent.appendChild(d);
  }

  function serieGraphe(parent, titre, cases, series) {
    var fig = el('figure', 'gs-graphe gs-analytics__graphe');
    fig.appendChild(el('figcaption', 'gs-graphe__titre', titre));
    var zone = el('div', 'gs-graphe__zone');
    fig.appendChild(zone);
    parent.appendChild(fig);
    grapheJours(zone, cases, series, caseLisible);
  }

  // Un tableau qui double un graphique (une ligne par jour, semaine, mois ou
  // statut) : replié dessous ; l'export CSV et l'impression le reprennent en entier
  function detailSerie(parent, nombre, texte) {
    var d = el('details', 'gs-definitions gs-analytics__detail');
    d.appendChild(el('summary', '', (texte || 'Voir le détail, période par période') + ' (' + nombre + ' ligne' + (nombre > 1 ? 's' : '') + ')'));
    parent.appendChild(d);
    return d;
  }

  function repartitionAvecPart(parent, lignes, total) {
    var ul = el('ul', 'gs-repartition');
    parent.appendChild(ul);
    repartition(ul, lignes.map(function (l) {
      return { libelle: l.libelle + (total ? ' — ' + O.nombre(Math.round(l.nombre * 1000 / total) / 10) + ' %' : ''),
               nombre: l.nombre, pastille: l.pastille };
    }), 'Aucune donnée disponible pour cette période.');
  }

  /* ---- Les rubriques ----------------------------------------------------------- */
  var RUBRIQUES = {
    synthese: function () {
      return lireAnalytics('synthese').then(function (s) {
        var m = s.mesures;
        var colis = section('Colis', 'Période choisie comparée à la période précédente de même longueur.');
        colis.appendChild(grille([
          carte('Colis reçus', m.recus, entier), carte('Expédiés (embarqués)', m.expedies, entier),
          carte('Rendus disponibles', m.disponibles, entier), carte('Livrés', m.livres, entier),
          carte('Passés en action requise', m.actions_requises, entier), carte('Poids reçu', m.poids, poidsLb)]));
        var cl = section('Clients');
        cl.appendChild(grille([carte('Clients inscrits (fin de période)', s.clients_total, entier),
                               carte('Nouveaux clients', m.nouveaux_clients, entier)]));
        var fi = section('Argent', 'Facturé et encaissé ne se confondent pas : l’un est ce qui a été demandé, l’autre ce qui est entré.');
        fi.appendChild(grille([carte('Facturé', m.facture, argent), carte('Encaissé', m.encaisse, argent),
                               carte('Reste sur les factures de la période', m.reste, argent, 'dû aujourd’hui'),
                               carte('Créances en fin de période', s.creances_fin, argent)]));
        var tend = section('Tendances', 'Des faits chiffrés, sans explication : les causes ne se lisent pas dans les données.');
        var ul = el('ul', 'gs-tendances');
        [phrase('Colis reçus', m.recus, entier), phrase('Colis livrés', m.livres, entier),
         phrase('Nouveaux clients', m.nouveaux_clients, entier), phrase('Facturé', m.facture, argent),
         phrase('Encaissé', m.encaisse, argent), phrase('Créances en fin de période', s.creances_fin, argent),
         phrase('Opérations au scanner', m.scans, entier)].filter(Boolean).forEach(function (t) { ul.appendChild(el('li', '', t)); });
        tend.appendChild(ul);
        var st = section('Colis par statut, maintenant', 'Le stock actuel, les huit statuts du système — les mêmes chiffres que la vue générale.');
        repartitionAvecPart(st, Object.keys(STATUTS).map(function (k) {
          return { libelle: STATUTS[k], nombre: s.maintenant.statuts[k] || 0, pastille: k };
        }), s.maintenant.total);
        tableau(detailSerie(st, 8, 'Voir le tableau'), 'Colis par statut, maintenant', [
          { titre: 'Statut', valeur: function (l) { return l.nom; } },
          { titre: 'Colis', nombre: true, valeur: function (l) { return entier(l.n); }, brut: function (l) { return l.n; } }],
          Object.keys(STATUTS).map(function (k) { return { nom: STATUTS[k], n: s.maintenant.statuts[k] || 0 }; }));
        definitions(corpsAnalytics, [
          ['Colis reçus', 'Colis dont la réception à Miami (date saisie à l’arrivée) tombe dans la période. Source : colis.'],
          ['Expédiés, rendus disponibles, livrés, action requise', 'Colis passés à ce statut pendant la période, chacun une fois, sans les étapes annulées par une correction. Source : les événements (colis_historique).'],
          ['Facturé', 'Total des factures émises pendant la période, hors annulées ; montants arrêtés à la création (un changement de tarif ne les modifie pas).'],
          ['Encaissé', 'Paiements valides reçus pendant la période, quelle que soit la facture. Source : paiements.'],
          ['Créances en fin de période', 'Ce qui restait dû à la fin de la période, reconstitué à partir des factures et des paiements datés.'],
          ['Période précédente', 'Même nombre de jours juste avant ; « ce mois » : le mois précédent aux mêmes dates ; « cette année » : l’année précédente aux mêmes dates.'],
          ['Pourcentage', 'Absent quand la période précédente vaut zéro : on écrit « nouveau » plutôt qu’un pourcentage infini.']]);
      });
    },

    expeditions: function () {
      return Promise.all([lireAnalytics('serie', { granularite: etatAnalytics.decoupage }), lireAnalytics('synthese')]).then(function (r) {
        var se = r[0], s = r[1], m = s.mesures;
        var haut = section('Volume');
        haut.appendChild(grille([carte('Colis reçus', m.recus, entier), carte('Livrés', m.livres, entier),
                                 carte('Poids total', m.poids, poidsLb),
                                 carte('Poids moyen', s.moyennes.poids_moyen, poidsLb, 'colis pesés seulement'),
                                 carte('Prix moyen d’un colis', s.moyennes.prix_moyen, function (x) { return x == null ? '—' : argent(x); },
                                       'prix arrêté à l’enregistrement'),
                                 carte('Facture moyenne', s.moyennes.revenu_moyen_facture, function (x) { return x == null ? '—' : argent(x); })]));
        var g = section('Colis reçus et livrés');
        serieGraphe(g, 'Colis reçus et livrés, ' + { jour: 'par jour', semaine: 'par semaine', mois: 'par mois' }[se.granularite],
                    se.cases, [{ nom: 'Reçus', cle: 'recus', classe: 'gs-graphe--serie1', total: m.recus.actuel, format: entier },
                               { nom: 'Livrés', cle: 'livres', classe: 'gs-graphe--serie2', total: m.livres.actuel, format: entier }]);
        tableau(detailSerie(g, se.cases.length), 'Volume par période', [
          { titre: 'Période', valeur: function (c) { return c.debut === c.fin ? jourLisible(c.debut) : jourLisible(c.debut) + ' → ' + jourLisible(c.fin); } },
          { titre: 'Colis reçus', nombre: true, valeur: function (c) { return entier(c.recus); }, brut: function (c) { return c.recus; } },
          { titre: 'Poids', nombre: true, valeur: function (c) { return poidsLb(c.poids); }, brut: function (c) { return c.poids; } },
          { titre: 'Expédiés', nombre: true, valeur: function (c) { return entier(c.expedies); }, brut: function (c) { return c.expedies; } },
          { titre: 'Livrés', nombre: true, valeur: function (c) { return entier(c.livres); }, brut: function (c) { return c.livres; } },
          { titre: 'Facturé', nombre: true, valeur: function (c) { return argent(c.facture); }, brut: function (c) { return c.facture; } },
          { titre: 'Encaissé', nombre: true, valeur: function (c) { return argent(c.encaisse); }, brut: function (c) { return c.encaisse; } }],
          se.cases);
        var st = section('Colis par statut, maintenant');
        repartitionAvecPart(st, Object.keys(STATUTS).map(function (k) {
          return { libelle: STATUTS[k], nombre: s.maintenant.statuts[k] || 0, pastille: k };
        }), s.maintenant.total);
        definitions(corpsAnalytics, [
          ['Découpage', 'Par jour, par semaine (du lundi au dimanche) ou par mois, en jours de Santo Domingo. La première et la dernière case peuvent être partielles.'],
          ['Livrés, expédiés', 'Un colis compte le jour de sa première arrivée à l’étape pendant la période : la somme des cases vaut le total.'],
          ['Prix moyen', 'Moyenne des prix enregistrés sur les colis reçus (poids × tarif du jour de l’enregistrement).']]);
      });
    },

    operations: function () {
      return lireAnalytics('operations').then(function (o) {
        var d = o.durees;
        var ETAPES = [['reception_expedition', 'Reçu → Embarqué (entrepôt de Miami)'], ['expedition_disponible', 'Embarqué → Disponible (acheminement)'],
                      ['disponible_livraison', 'Disponible → Livré (retrait)'], ['reception_livraison', 'Reçu → Livré (total)']];
        var s1 = section('Temps de traitement', 'Tirés des événements réels. Une étape compte dans la période où elle s’achève. Les valeurs extrêmes restent dans les chiffres et sont signalées.');
        repartition((function () { var ul = el('ul', 'gs-repartition'); s1.appendChild(ul); return ul; })(),
                    ETAPES.filter(function (e) { return d[e[0]].nombre; }).map(function (e) {
                      return { libelle: e[1] + ' — médiane ' + duree(d[e[0]].mediane_h), nombre: d[e[0]].mediane_h };
                    }), 'Aucune étape achevée pendant cette période.');
        tableau(s1, 'Temps de traitement', [
          { titre: 'Étape', valeur: function (e) { return e[1]; } },
          { titre: 'Colis', nombre: true, valeur: function (e) { return entier(d[e[0]].nombre); }, brut: function (e) { return d[e[0]].nombre; } },
          { titre: 'Moyenne', nombre: true, valeur: function (e) { return duree(d[e[0]].moyenne_h); }, brut: function (e) { return d[e[0]].moyenne_h; } },
          { titre: 'Médiane', nombre: true, valeur: function (e) { return duree(d[e[0]].mediane_h); }, brut: function (e) { return d[e[0]].mediane_h; } },
          { titre: 'Minimum', nombre: true, valeur: function (e) { return duree(d[e[0]].minimum_h); }, brut: function (e) { return d[e[0]].minimum_h; } },
          { titre: 'Maximum', nombre: true, valeur: function (e) { return duree(d[e[0]].maximum_h); }, brut: function (e) { return d[e[0]].maximum_h; } },
          { titre: 'Valeurs extrêmes', nombre: true, valeur: function (e) { return entier(d[e[0]].extremes); }, brut: function (e) { return d[e[0]].extremes; } },
          { titre: 'Durées négatives', nombre: true, valeur: function (e) { return entier(d[e[0]].negatives); }, brut: function (e) { return d[e[0]].negatives; } }],
          ETAPES.filter(function (e) { return d[e[0]].nombre || d[e[0]].negatives; }), 'Aucune étape achevée pendant cette période.');
        var s2 = section('Livraison');
        s2.appendChild(grille([
          carte('Livrés pendant la période', o.livraison.livres, entier),
          carte('Taux de livraison de la cohorte', o.livraison.taux_cohorte, pourcent,
                entier(o.livraison.cohorte_livres) + ' livrés sur ' + entier(o.livraison.cohorte_recus) + ' reçus pendant la période'),
          carte('Même taux, période précédente', o.livraison.taux_cohorte_precedente, pourcent),
          carte('Délai médian Reçu → Livré', d.reception_livraison.mediane_h, duree, 'moyenne : ' + duree(d.reception_livraison.moyenne_h))]));
        var s3 = section('Transitions de statut', 'Chaque changement de statut de la période et le temps passé dans le statut quitté.');
        tableau(s3, 'Transitions de statut', [
          { titre: 'Transition', valeur: function (t) { return nomStatut(t.de) + ' → ' + nomStatut(t.vers); } },
          { titre: 'Nombre', nombre: true, valeur: function (t) { return entier(t.nombre); }, brut: function (t) { return t.nombre; } },
          { titre: 'Durée moyenne', nombre: true, valeur: function (t) { return duree(t.moyenne_h); }, brut: function (t) { return t.moyenne_h; } },
          { titre: 'Durée médiane', nombre: true, valeur: function (t) { return duree(t.mediane_h); }, brut: function (t) { return t.mediane_h; } }],
          o.transitions, 'Aucun changement de statut pendant cette période.');
        s3.appendChild(el('p', 'gs-apercu__note', 'Anomalies : ' + pluriel(o.anomalies.corrections, 'correction', 'corrections') + ' et ' +
                          pluriel(o.anomalies.retours_en_arriere, 'retour en arrière', 'retours en arrière') + ' pendant la période.'));
        var s4 = section('Colis sans progression, maintenant', 'Colis pas encore livrés, selon le temps écoulé depuis leur dernier événement. Des repères de lecture : l’alerte officielle reste le réglage « sans mouvement » de la vue générale, où se trouve la liste.');
        var sm = o.sans_mouvement;
        repartitionAvecPart(s4, [{ libelle: 'Moins de 24 h', nombre: sm.moins_24h }, { libelle: '24 à 48 h', nombre: sm.de_24_a_48h },
                                 { libelle: '48 à 72 h', nombre: sm.de_48_a_72h }, { libelle: '72 h à 7 jours', nombre: sm.de_72h_a_7j },
                                 { libelle: 'Plus de 7 jours', nombre: sm.plus_de_7j }], sm.actifs);
        var ar = o.action_requise;
        var s5 = section('Action requise');
        s5.appendChild(grille([carte('Colis passés en action requise', ar.entrees, entier), carte('En action requise maintenant', ar.en_cours, entier),
                               carte('Durée moyenne dans l’état', ar.duree_episodes.moyenne_h, duree,
                                     pluriel(ar.duree_episodes.nombre, 'épisode terminé', 'épisodes terminés') + ' · médiane ' + duree(ar.duree_episodes.mediane_h)),
                               carte('Clients concernés', ar.clients, entier)]));
        tableau(s5, 'Action requise par destination', [
          { titre: 'Destination', valeur: function (x) { return nomPays(x.pays); } },
          { titre: 'Colis', nombre: true, valeur: function (x) { return entier(x.nombre); }, brut: function (x) { return x.nombre; } }],
          ar.par_destination, 'Aucun colis passé en action requise pendant cette période.');
        s5.appendChild(el('p', 'gs-apercu__note', 'Le motif d’une action requise est une note en texte libre : aucune cause n’est classée. Les notes les plus fréquentes, telles qu’elles ont été écrites :'));
        tableau(s5, 'Notes les plus fréquentes', [
          { titre: 'Note', valeur: function (x) { return x.note; } },
          { titre: 'Fois', nombre: true, valeur: function (x) { return entier(x.nombre); }, brut: function (x) { return x.nombre; } }],
          ar.notes, 'Aucune note.');
        definitions(corpsAnalytics, [
          ['Départ d’un colis', 'Sa réception à Miami (date et heure saisies à l’arrivée) ; chaque étape suivante est la première arrivée au statut, non annulée par une correction.'],
          ['Taux de livraison de la cohorte', 'Parmi les colis reçus pendant la période, la part livrée aujourd’hui. Une période récente a naturellement un taux plus bas : ses colis sont encore en route.'],
          ['Valeurs extrêmes', 'Au-delà de Q3 + 1,5 × l’écart interquartile (dès 4 valeurs). Gardées dans la moyenne et le maximum.'],
          ['Durées négatives', 'Date de réception saisie après l’événement : comptées à part, hors statistiques.']]);
      });
    },

    clients: function () {
      return lireAnalytics('clients', { tri: etatAnalytics.tri, page: etatAnalytics.page, parPage: etatAnalytics.parPage }).then(function (c) {
        var s1 = section('Clients');
        s1.appendChild(grille([carte('Inscrits (fin de période)', c.total_fin, entier), carte('Nouveaux', c.nouveaux, entier),
                               carte('Actifs', c.actifs, entier, 'au moins un colis reçu pendant la période'),
                               carte('Inactifs', c.inactifs, entier, 'inscrits, sans colis reçu pendant la période'),
                               carte('Colis par client actif', c.colis_par_client_actif, function (x) { return x == null ? '—' : O.nombre(x); })]));
        var s2 = section('Activité des clients actifs', 'Des seuils fixes, affichés tels quels : ce n’est pas une note ni un classement.');
        tableau(s2, 'Segments', [
          { titre: 'Activité', valeur: function (x) { return { petite: 'Petite', moyenne: 'Moyenne', forte: 'Forte' }[x.segment] || x.segment; } },
          { titre: 'Définition', valeur: function (x) { return x.definition; } },
          { titre: 'Clients', nombre: true, valeur: function (x) { return entier(x.clients); }, brut: function (x) { return x.clients; } },
          { titre: 'Colis', nombre: true, valeur: function (x) { return entier(x.colis); }, brut: function (x) { return x.colis; } }], c.segments);
        var s3 = section('Clients les plus actifs');
        var outils = el('div', 'gs-admin-outils');
        var choix = el('select', 'gs-admin-filtre');
        choix.setAttribute('aria-label', 'Trier les clients');
        [['colis', 'Par nombre de colis'], ['poids', 'Par poids'], ['facture', 'Par montant facturé'], ['paye', 'Par montant payé'], ['solde', 'Par solde']]
          .forEach(function (x) { var op = new Option(x[1], x[0]); op.selected = x[0] === etatAnalytics.tri; choix.add(op); });
        choix.addEventListener('change', function () { etatAnalytics.tri = choix.value; etatAnalytics.page = 0; afficherAnalytics(); });
        outils.appendChild(choix);
        s3.appendChild(outils);
        tableau(s3, 'Clients les plus actifs', [
          { titre: 'Client', valeur: function (x) { return (x.nom_complet || '—') + ' (' + (x.code || '—') + ')'; } },
          { titre: 'Colis', nombre: true, valeur: function (x) { return entier(x.colis); }, brut: function (x) { return x.colis; } },
          { titre: 'Poids', nombre: true, valeur: function (x) { return poidsLb(x.poids); }, brut: function (x) { return x.poids; } },
          { titre: 'Facturé', nombre: true, valeur: function (x) { return argent(x.facture); }, brut: function (x) { return x.facture; } },
          { titre: 'Payé', nombre: true, valeur: function (x) { return argent(x.paye); }, brut: function (x) { return x.paye; } },
          { titre: 'Solde (maintenant)', nombre: true, valeur: function (x) { return argent(x.solde); }, brut: function (x) { return x.solde; } },
          { titre: 'Dernière activité', valeur: function (x) { return x.derniere_activite ? O.date(x.derniere_activite, true) : '—'; } }],
          c.lignes, 'Aucun client actif pendant cette période.');
        var pages = el('div', 'gs-pagination');
        s3.appendChild(pages);
        paginer(pages, etatAnalytics, c.total_liste, afficherAnalytics);
        definitions(corpsAnalytics, [
          ['Client actif', 'Au moins un colis reçu à Miami pendant la période.'],
          ['Liste', 'Les clients qui ont reçu un colis, reçu une facture ou payé pendant la période. Facturé et payé : pendant la période ; solde : aujourd’hui, toutes factures.']]);
      });
    },

    finances: function () {
      return Promise.all([lireAnalytics('finances'), lireAnalytics('serie', { granularite: etatAnalytics.decoupage })]).then(function (r) {
        var f = r[0], se = r[1], cr = f.creances;
        var s1 = section('Facturé et encaissé', 'Le facturé est ce qui a été demandé ; l’encaissé, l’argent réellement reçu. Les deux ne se confondent jamais.');
        s1.appendChild(grille([carte('Facturé', f.facture, argent), carte('Encaissé', f.encaisse, argent),
                               carte('Reste sur les factures de la période', f.reste, argent, 'dû aujourd’hui'),
                               carte('Factures émises', f.factures_emises, entier),
                               carte('Dont transport', f.transport, argent), carte('Dont frais de service', f.frais_service, argent)]));
        serieGraphe(s1, 'Facturé et encaissé, ' + { jour: 'par jour', semaine: 'par semaine', mois: 'par mois' }[se.granularite], se.cases,
                    [{ nom: 'Facturé', cle: 'facture', classe: 'gs-graphe--serie1', total: f.facture.actuel, format: argent },
                     { nom: 'Encaissé', cle: 'encaisse', classe: 'gs-graphe--serie2', total: f.encaisse.actuel, format: argent }]);
        tableau(detailSerie(s1, se.cases.length), 'Facturé, encaissé et dû par période', [
          { titre: 'Période', valeur: function (c) { return c.debut === c.fin ? jourLisible(c.debut) : jourLisible(c.debut) + ' → ' + jourLisible(c.fin); } },
          { titre: 'Factures', nombre: true, valeur: function (c) { return entier(c.factures); }, brut: function (c) { return c.factures; } },
          { titre: 'Facturé', nombre: true, valeur: function (c) { return argent(c.facture); }, brut: function (c) { return c.facture; } },
          { titre: 'Encaissé', nombre: true, valeur: function (c) { return argent(c.encaisse); }, brut: function (c) { return c.encaisse; } },
          { titre: 'Dû en fin de période', nombre: true, valeur: function (c) { return argent(c.creances_fin); }, brut: function (c) { return c.creances_fin; } }],
          se.cases);
        var s2 = section('Créances, maintenant');
        s2.appendChild(grille([carte('À recouvrer', cr.total, argent, pluriel(cr.factures, 'facture ouverte', 'factures ouvertes')),
                               carte('Impayées', cr.impayees, entier, 'rien reçu'), carte('Payées en partie', cr.partielles, entier),
                               carte('En retard', cr.montant_en_retard, argent, pluriel(cr.en_retard, 'facture échue', 'factures échues')),
                               carte('Non échues', cr.non_echues, entier), carte('Sans échéance', cr.sans_echeance, entier),
                               carte('Créances en fin de période', f.creances_fin, argent)]));
        var TRANCHES = { '0_30': '0 à 30 jours', '31_60': '31 à 60 jours', '61_90': '61 à 90 jours', '90_plus': 'Plus de 90 jours' };
        tableau(s2, 'Âge des créances (depuis l’émission)', [
          { titre: 'Âge', valeur: function (t) { return TRANCHES[t.tranche] || t.tranche; } },
          { titre: 'Factures', nombre: true, valeur: function (t) { return entier(t.factures); }, brut: function (t) { return t.factures; } },
          { titre: 'Montant dû', nombre: true, valeur: function (t) { return argent(t.montant); }, brut: function (t) { return t.montant; } }], cr.age);
        var s3 = section('Encaissé par moyen de paiement');
        tableau(s3, 'Encaissé par moyen de paiement', [
          { titre: 'Moyen', valeur: function (x) { return nomMoyen(x.moyen); } },
          { titre: 'Paiements', nombre: true, valeur: function (x) { return entier(x.nombre); }, brut: function (x) { return x.nombre; } },
          { titre: 'Montant', nombre: true, valeur: function (x) { return argent(x.montant); }, brut: function (x) { return x.montant; } }],
          f.par_moyen, 'Aucun paiement reçu pendant cette période.');
        var s4 = section('Dépenses, dettes et résultat');
        s4.appendChild(el('p', 'gs-analytics__non-suivi', 'Non suivis par le système : aucune dépense ni dette n’y est enregistrée. Aucun résultat ni bénéfice n’est donc calculé — l’encaissé n’est pas un bénéfice.'));
        definitions(corpsAnalytics, [
          ['Facturé', 'Factures émises pendant la période, hors annulées ; montant arrêté à la création. Transport = total − frais de service.'],
          ['Encaissé', 'Paiements valides reçus pendant la période ; un paiement annulé n’y est jamais.'],
          ['Dû en fin de période', 'Factures émises avant la fin, moins celles annulées, moins les paiements reçus, plus ceux annulés — tous datés. Maintenant, il vaut « à encaisser » de la vue générale.'],
          ['Âge des créances', 'Jours écoulés depuis l’émission de chaque facture encore ouverte. En retard : échéance dépassée et solde restant.']]);
      });
    },

    routes: function () {
      return lireAnalytics('routes').then(function (r) {
        var s1 = section('Routes', 'Origine unique : l’entrepôt de ' + r.origine + ' — la base n’enregistre pas d’autre origine. Seules les routes réellement utilisées apparaissent, pour les colis reçus pendant la période.');
        tableau(s1, 'Routes', [
          { titre: 'Route', valeur: function (x) { return 'Miami → ' + nomPays(x.pays) + ' · ' + nomService(x.service); } },
          { titre: 'Colis', nombre: true, valeur: function (x) { return entier(x.colis); }, brut: function (x) { return x.colis; } },
          { titre: 'Période précédente', nombre: true, valeur: function (x) { return entier(x.colis_precedents); }, brut: function (x) { return x.colis_precedents; } },
          { titre: 'Poids', nombre: true, valeur: function (x) { return poidsLb(x.poids); }, brut: function (x) { return x.poids; } },
          { titre: 'Transport facturé', nombre: true, valeur: function (x) { return argent(x.facture); }, brut: function (x) { return x.facture; } },
          { titre: 'Livrés', nombre: true, valeur: function (x) { return entier(x.livres) + ' (' + pourcent(x.taux_livre) + ')'; }, brut: function (x) { return x.livres; } },
          { titre: 'Délai moyen Reçu → Livré', nombre: true, valeur: function (x) { return duree(x.delai_moyen_h); }, brut: function (x) { return x.delai_moyen_h; } }],
          r.routes, 'Aucun colis reçu pendant cette période.');
        var s2 = section('Pays de destination');
        tableau(s2, 'Pays de destination', [
          { titre: 'Pays', valeur: function (x) { return nomPays(x.pays); } },
          { titre: 'Colis', nombre: true, valeur: function (x) { return entier(x.colis); }, brut: function (x) { return x.colis; } },
          { titre: 'Période précédente', nombre: true, valeur: function (x) { return entier(x.colis_precedents); }, brut: function (x) { return x.colis_precedents; } },
          { titre: 'Évolution', nombre: true, valeur: function (x) { var v = variation({ actuel: x.colis, precedent: x.colis_precedents,
              variation_pct: x.colis_precedents ? Math.round((x.colis - x.colis_precedents) * 1000 / x.colis_precedents) / 10 : null,
              tendance: x.colis > x.colis_precedents ? 'hausse' : (x.colis < x.colis_precedents ? 'baisse' : 'stable') }, entier); return v.texte; } }],
          r.pays, 'Aucun colis sur ces deux périodes.');
        var s3 = section('Villes les plus fréquentes', 'La ville de livraison saisie, telle quelle. ' + pluriel(r.sans_ville, 'colis sans ville indiquée', 'colis sans ville indiquée') + '.');
        tableau(s3, 'Villes les plus fréquentes', [
          { titre: 'Ville', valeur: function (x) { return x.ville + ' (' + nomPays(x.pays) + ')'; } },
          { titre: 'Colis', nombre: true, valeur: function (x) { return entier(x.colis); }, brut: function (x) { return x.colis; } },
          { titre: 'Période précédente', nombre: true, valeur: function (x) { return entier(x.colis_precedents); }, brut: function (x) { return x.colis_precedents; } }],
          r.villes, 'Aucune ville indiquée.');
        definitions(corpsAnalytics, [
          ['Route', 'Miami → pays de destination, par service (aérien, maritime, terrestre).'],
          ['Transport facturé', 'Lignes des colis de la route sur des factures non annulées ; les frais de service, comptés par facture, n’y sont pas.'],
          ['Livrés, taux', 'Colis de la route livrés aujourd’hui, rapportés aux colis reçus pendant la période.']]);
      });
    },

    scanner: function () {
      return Promise.all([lireAnalytics('scanner'), lireAnalytics('serie', { granularite: etatAnalytics.decoupage })]).then(function (r) {
        var s = r[0], se = r[1];
        var s1 = section('Opérations au poste de scan', 'Une opération compte quand le scan l’a enregistrée. Les scans refusés, illisibles ou sans suite ne sont pas enregistrés : ils ne peuvent pas être comptés.');
        s1.appendChild(grille([carte('Opérations', s.total, entier), carte('Colis scannés', s.colis, entier),
                               carte('Jours avec des scans', s.jours_actifs, entier),
                               carte('Intervalle médian entre deux opérations', s.intervalle_minutes.mediane,
                                     function (x) { return x == null ? '—' : O.nombre(x) + ' min'; }, 'même compte, même jour')]));
        serieGraphe(s1, 'Opérations, ' + { jour: 'par jour', semaine: 'par semaine', mois: 'par mois' }[se.granularite], se.cases,
                    [{ nom: 'Opérations', cle: 'scans', classe: 'gs-graphe--serie1', total: s.total.actuel, format: entier }]);
        var s2 = section('Par opération');
        tableau(s2, 'Par opération', [
          { titre: 'Opération', valeur: function (x) { return x.libelle; } },
          { titre: 'Nombre', nombre: true, valeur: function (x) { return entier(x.nombre); }, brut: function (x) { return x.nombre; } }],
          s.par_operation, 'Aucune opération pendant cette période.');
        var s3 = section('Par compte', 'Dans l’ordre alphabétique : pour comprendre l’activité, pas pour classer les personnes.');
        tableau(s3, 'Par compte', [
          { titre: 'Compte', valeur: function (x) { return x.nom + (x.role && ROLES[x.role] ? ' (' + ROLES[x.role].toLowerCase() + ')' : ''); } },
          { titre: 'Opérations', nombre: true, valeur: function (x) { return entier(x.operations); }, brut: function (x) { return x.operations; } },
          { titre: 'Jours', nombre: true, valeur: function (x) { return entier(x.jours); }, brut: function (x) { return x.jours; } }],
          s.par_compte, 'Aucune opération pendant cette période.');
        var s4 = section('Par lieu');
        tableau(s4, 'Par lieu', [
          { titre: 'Lieu du poste', valeur: function (x) { return x.lieu || 'Lieu non indiqué'; } },
          { titre: 'Opérations', nombre: true, valeur: function (x) { return entier(x.nombre); }, brut: function (x) { return x.nombre; } }],
          s.par_lieu, 'Aucune opération pendant cette période.');
      });
    },

    qualite: function () {
      return lireAnalytics('qualite').then(function (q) {
        var s1 = section('Indicateurs de qualité', 'Sur toute la base. Rien n’est corrigé ni caché : chaque ligne dit combien de données sont en cause.');
        tableau(s1, 'Indicateurs de qualité', [
          { titre: 'Indicateur', valeur: function (x) { return x.libelle; } },
          { titre: 'Conformes', nombre: true, valeur: function (x) { return entier(x.ok) + ' sur ' + entier(x.total); }, brut: function (x) { return x.ok; } },
          { titre: 'Part', nombre: true, valeur: function (x) { return x.total ? pourcent(Math.round(x.ok * 1000 / x.total) / 10) : 'Aucune donnée'; },
            brut: function (x) { return x.total ? Math.round(x.ok * 1000 / x.total) / 10 : ''; } }], q.indicateurs);
        var s2 = section('Anomalies');
        tableau(s2, 'Anomalies', [
          { titre: 'Anomalie', valeur: function (x) { return x.libelle; } },
          { titre: 'Nombre', nombre: true, valeur: function (x) { return entier(x.nombre); }, brut: function (x) { return x.nombre; } }], q.anomalies);
        var s3 = section('Facturation', 'Le rapport d’anomalies de facturation (bouton « Contrôler » de l’onglet Factures), compté par type.');
        tableau(s3, 'Anomalies de facturation', [
          { titre: 'Type', valeur: function (x) { return x.type.replace(/_/g, ' '); } },
          { titre: 'Gravité', valeur: function (x) { return x.gravite; } },
          { titre: 'Nombre', nombre: true, valeur: function (x) { return entier(x.nombre); }, brut: function (x) { return x.nombre; } }],
          q.facturation, 'Aucune anomalie de facturation.');
      });
    }
  };

  function afficherAnalytics() {
    if (!peut('reports.view')) return Promise.resolve();
    var numero = ++etatAnalytics.demande;
    var module = etatAnalytics.module;
    corpsAnalytics.setAttribute('aria-busy', 'true');
    messageAnalytics.hidden = true;
    $('[data-analytics-etat]').textContent = 'Chargement des données…';
    // Le découpage ne sert qu'aux rubriques qui ont une série dans le temps
    $('[data-analytics-decoupage]').closest('label').hidden = ['expeditions', 'finances', 'scanner'].indexOf(module) < 0;
    return lireAnalytics('synthese').then(function (s) {
      if (numero !== etatAnalytics.demande) return;
      etatAnalytics.titre = NOMS_MODULES[module];
      var p = s.periode;
      $('[data-analytics-etat]').textContent = (module === 'qualite' ? 'Toute la base · ' : '') +
        (p.debut === p.fin ? 'Le ' + jourLisible(p.debut) : 'Du ' + jourLisible(p.debut) + ' au ' + jourLisible(p.fin)) +
        ', comparé ' + (p.precedente.debut === p.precedente.fin ? 'au ' + jourLisible(p.precedente.debut)
          : 'du ' + jourLisible(p.precedente.debut) + ' au ' + jourLisible(p.precedente.fin)) +
        ' · jours de Santo Domingo · chiffres de ' + heure(s.genere_le);
      var temporaire = el('div');
      var vrai = corpsAnalytics;
      corpsAnalytics = temporaire;
      etatAnalytics.tables = [];
      return RUBRIQUES[module]().then(function () {
        corpsAnalytics = vrai;
        if (numero !== etatAnalytics.demande) return;
        corpsAnalytics.textContent = '';
        while (temporaire.firstChild) corpsAnalytics.appendChild(temporaire.firstChild);
      }, function (err) { corpsAnalytics = vrai; throw err; });
    }).catch(function (err) {
      if (numero !== etatAnalytics.demande) return;
      corpsAnalytics.textContent = '';
      etatAnalytics.tables = [];
      messageAnalytics.textContent = texteErreurAnalytics(err);
      messageAnalytics.hidden = false;
      $('[data-analytics-etat]').textContent = '';
    }).then(function () {
      if (numero === etatAnalytics.demande) corpsAnalytics.removeAttribute('aria-busy');
    });
  }

  function choisirModule(module) {
    etatAnalytics.module = module;
    etatAnalytics.page = 0;
    ongletsAnalytics.forEach(function (b) {
      var actif = b.getAttribute('data-analytics-module') === module;
      b.setAttribute('aria-selected', String(actif));
      b.tabIndex = actif ? 0 : -1;
    });
    afficherAnalytics();
  }
  ongletsAnalytics.forEach(function (b) {
    b.addEventListener('click', function () { choisirModule(b.getAttribute('data-analytics-module')); });
    b.addEventListener('keydown', function (e) {
      var sens = { ArrowRight: 1, ArrowLeft: -1 }[e.key];
      if (!sens) return;
      e.preventDefault();
      var autre = ongletsAnalytics[(ongletsAnalytics.indexOf(b) + sens + ongletsAnalytics.length) % ongletsAnalytics.length];
      autre.focus();
      choisirModule(autre.getAttribute('data-analytics-module'));
    });
  });

  var choixPeriodeAnalytics = $('[data-analytics-periode]');
  choixPeriodeAnalytics.addEventListener('change', function () {
    var perso = choixPeriodeAnalytics.value === 'personnalise';
    $('[data-analytics-dates]').hidden = !perso;
    if (perso) { $('[data-analytics-debut]').focus(); return; }
    etatAnalytics.periode = choixPeriodeAnalytics.value;
    etatAnalytics.debut = etatAnalytics.fin = '';
    etatAnalytics.page = 0;
    afficherAnalytics();
  });
  $('[data-action="analytics-appliquer"]').addEventListener('click', function () {
    var debut = $('[data-analytics-debut]').value, fin = $('[data-analytics-fin]').value;
    if (!debut || !fin) { toast('Choisissez une date de début et une date de fin.', true); return; }
    if (fin < debut) { toast('La date de fin est avant la date de début.', true); return; }
    etatAnalytics.periode = 'personnalise';
    etatAnalytics.debut = debut;
    etatAnalytics.fin = fin;
    etatAnalytics.page = 0;
    afficherAnalytics();
  });
  $('[data-analytics-decoupage]').addEventListener('change', function (e) {
    etatAnalytics.decoupage = e.target.value;
    afficherAnalytics();
  });
  $('[data-action="analytics-actualiser"]').addEventListener('click', function () {
    etatAnalytics.memoire = {};
    afficherAnalytics();
  });

  /* ---- Export : un seul mécanisme, les tableaux affichés -----------------------
     CSV avec point-virgule, virgule décimale et marque UTF-8 : Excel l'ouvre tel
     quel. Pour le PDF, l'impression A4 existante (impression.js) : « Enregistrer
     au format PDF » dans la fenêtre d'impression. Rien de plus que ce que la
     page montre, donc rien de plus que ce que reports.view permet. */
  function celluleCsv(v) {
    var t = typeof v === 'number' ? String(v).replace('.', ',') : String(v == null ? '' : v);
    return /[;"\n\r]/.test(t) ? '"' + t.replace(/"/g, '""') + '"' : t;
  }
  function periodeTexte() { return $('[data-analytics-etat]').textContent; }
  $('[data-action="analytics-csv"]').addEventListener('click', function () {
    if (!etatAnalytics.tables.length) { toast('Rien à exporter : chargez d’abord une rubrique.', true); return; }
    var lignes = [['Goship Express — Analytics — ' + etatAnalytics.titre], [periodeTexte()], []];
    etatAnalytics.tables.forEach(function (t) {
      lignes.push([t.titre]);
      lignes.push(t.colonnes.map(function (c) { return c.titre; }));
      t.lignes.forEach(function (l) {
        lignes.push(t.colonnes.map(function (c) { return c.brut ? c.brut(l) : c.valeur(l); }));
      });
      lignes.push([]);
    });
    var texte = '﻿' + lignes.map(function (l) { return l.map(celluleCsv).join(';'); }).join('\r\n');
    var lien = el('a');
    lien.href = URL.createObjectURL(new Blob([texte], { type: 'text/csv;charset=utf-8' }));
    lien.download = 'goship-analytics-' + etatAnalytics.module + '-' + aujourdhuiTexte() + '.csv';
    document.body.appendChild(lien);
    lien.click();
    setTimeout(function () { URL.revokeObjectURL(lien.href); lien.remove(); }, 1000);
  });
  function aujourdhuiTexte() {
    var t = new Date();
    return t.getFullYear() + '-' + deux(t.getMonth() + 1) + '-' + deux(t.getDate());
  }
  $('[data-action="analytics-imprimer"]').addEventListener('click', function () {
    if (!corpsAnalytics.children.length) { toast('Rien à imprimer : chargez d’abord une rubrique.', true); return; }
    var feuille = el('div', 'gs-rapport');
    feuille.appendChild(el('h1', '', 'Goship Express — Analytics : ' + etatAnalytics.titre));
    feuille.appendChild(el('p', 'gs-rapport__periode', periodeTexte()));
    var copie = corpsAnalytics.cloneNode(true);
    $$('select, button, .gs-pagination', copie).forEach(function (n) { n.remove(); });
    $$('details', copie).forEach(function (n) { n.open = true; });
    feuille.appendChild(copie);
    IMP.imprimer(feuille, { titre: 'Analytics — ' + etatAnalytics.titre, papier: 'A4', marge: '12mm' }).catch(function () {
      toast('Impression impossible : autorisez les fenêtres de ce site.', true);
    });
  });

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
