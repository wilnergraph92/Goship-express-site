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
    'non-autorise': 'Accès refusé : session expirée ou compte non administrateur. Reconnectez-vous.',
    'trop-de-tentatives': 'Trop de tentatives. Patientez quelques minutes.',
    'non-confirme': 'Adresse e-mail pas encore confirmée.',
    inconnu: 'Une erreur est survenue. Réessayez.'
  };
  var PAR_PAGE = 50;

  function $(sel, scope) { return (scope || document).querySelector(sel); }
  function $$(sel, scope) { return Array.prototype.slice.call((scope || document).querySelectorAll(sel)); }
  function messageErreur(err) { return ERREURS[err && err.code] || ERREURS.inconnu; }

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
    } else {
      bouton.disabled = false;
      bouton.removeAttribute('aria-busy');
      bouton.textContent = bouton.getAttribute('data-libelle');
    }
  }

  function erreurFormulaire(form, message) {
    var zone = $('[data-form-erreur]', form);
    zone.textContent = message || '';
    zone.hidden = !message;
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
      return API.estAdmin().then(function (admin) {
        if (admin) ouvrirTableau(); else ecran('refuse');
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
    chargerClients();
    chargerFactures();
    installerLogoEmail();
    var prevu = null;
    API.surveiller(function (quoi) {
      clearTimeout(prevu);
      prevu = setTimeout(function () {
        chargerStatistiques();
        chargerColis(true);
        if (quoi === 'clients' || etat.vue === 'clients') chargerClients();
        if (quoi === 'factures' || etat.vue === 'factures') chargerFactures();
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

  function chargerClients() {
    var c = etat.clients;
    return API.admin.clients({ recherche: c.recherche, page: 0, parPage: PAR_PAGE * c.pages }).then(function (r) {
      c.lignes = r.lignes;
      c.total = r.total;
      afficherClients();
    }).catch(function (err) { toast(messageErreur(err), true); });
  }

  function afficherClients() {
    var c = etat.clients;
    corpsClients.textContent = '';
    c.lignes.forEach(function (client) {
      var tr = el('tr');
      var tdCode = cellule('Code');
      tdCode.appendChild(el('span', 'gs-cellule-num', client.code || '—'));
      tr.appendChild(tdCode);

      var tdNom = cellule('Client');
      tdNom.appendChild(el('span', 'gs-cellule-principale', client.nom_complet || '—'));
      tdNom.appendChild(el('span', 'gs-cellule-sous', client.email || ''));
      tr.appendChild(tdNom);

      var tdLieu = cellule('Lieu');
      tdLieu.appendChild(el('span', '', [client.ville, client.region].filter(Boolean).join(', ') || '—'));
      tdLieu.appendChild(el('span', 'gs-cellule-sous', [client.adresse, PAYS[client.pays] || client.pays].filter(Boolean).join(' · ')));
      tr.appendChild(tdLieu);

      var tdTel = cellule('Téléphone');
      tdTel.appendChild(el('span', '', client.telephone || '—'));
      if (client.langue) tdTel.appendChild(el('span', 'gs-cellule-sous', 'Langue : ' + (LANGUES[client.langue] || client.langue)));
      tr.appendChild(tdTel);

      var tdDate = cellule('Inscrit le');
      tdDate.textContent = O.date(client.cree_le);
      tr.appendChild(tdDate);

      var tdActions = el('td', 'gs-cellule-actions');
      var voir = el('button', 'gs-bouton gs-bouton--petit gs-bouton--contour', 'Ses colis');
      voir.type = 'button';
      voir.addEventListener('click', function () { filtrerParClient(client); });
      var ajouter = el('button', 'gs-bouton gs-bouton--petit gs-bouton--sombre', '+ Colis');
      ajouter.type = 'button';
      ajouter.setAttribute('aria-label', 'Enregistrer un colis pour ' + (client.nom_complet || client.code));
      ajouter.addEventListener('click', function () { ouvrirColis({ code: client.code }); });
      tdActions.appendChild(voir);
      tdActions.appendChild(ajouter);
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


  /* ---- Factures ------------------------------------------------------------- */
  var corpsFactures = $('[data-lignes="factures"]');
  var dlgFacture = $('[data-dialogue="facture"]');
  var formFacture = $('form[data-form="facture"]', dlgFacture);
  var champCodeFacture = $('[data-code-client-facture]', formFacture);
  var infoClientFacture = $('[data-client-facture]', formFacture);
  var blocColisFacture = $('[data-colis-facture]', formFacture);
  var listeColisFacture = $('[data-liste-colis-facture]', formFacture);
  var blocPaiement = $('[data-bloc-paiement]', formFacture);
  var factureEditee = null;
  var clientFacture = null;
  var rechercheFacture = null;

  var STATUTS_FACTURE = { a_payer: 'À payer', payee: 'Payée', annulee: 'Annulée' };
  var MOYENS = {
    paypal: 'PayPal', banque: 'Compte bancaire', azul: 'Azul',
    moncash: 'MonCash', natcash: 'NatCash', especes: 'Espèces'
  };
  var MESSAGE_FACTURE = {
    fr: 'Bonjour {nom}, votre facture {numero} chez GoShip Express s’élève à {montant}.{lien}',
    en: 'Hello {nom}, your GoShip Express invoice {numero} comes to {montant}.{lien}',
    es: 'Hola {nom}, su factura {numero} de GoShip Express asciende a {montant}.{lien}',
    ht: 'Bonjou {nom}, fakti ou {numero} nan GoShip Express se {montant}.{lien}'
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

  function chargerFactures() {
    var f = etat.factures;
    return API.admin.factures({ statut: f.statut, page: 0, parPage: PAR_PAGE * f.pages }).then(function (r) {
      f.lignes = r.lignes || [];
      f.total = r.total || 0;
      afficherFactures();
    }).catch(function (err) { toast(messageErreur(err), true); });
  }

  function badgeFacture(statut) {
    var b = el('span', 'gs-badge gs-badge--facture-' + statut, STATUTS_FACTURE[statut] || statut);
    return b;
  }

  function afficherFactures() {
    var f = etat.factures;
    corpsFactures.textContent = '';
    f.lignes.forEach(function (facture) {
      var client = facture.clients || {};
      var tr = el('tr');

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
      tdMontant.appendChild(el('span', 'gs-cellule-principale', argent(facture.montant_usd)));
      if (facture.moyen) tdMontant.appendChild(el('span', 'gs-cellule-sous', MOYENS[facture.moyen] || facture.moyen));
      else if (facture.lien_paiement) tdMontant.appendChild(el('span', 'gs-cellule-sous', 'Lien de paiement prêt'));
      tr.appendChild(tdMontant);

      var tdStatut = cellule('Statut');
      tdStatut.appendChild(badgeFacture(facture.statut));
      if (facture.echeance_le && facture.statut === 'a_payer') {
        tdStatut.appendChild(el('span', 'gs-cellule-sous', 'Avant le ' + O.date(facture.echeance_le)));
      }
      tr.appendChild(tdStatut);

      var tdDate = cellule('Créée le');
      tdDate.textContent = O.date(facture.cree_le);
      tr.appendChild(tdDate);

      var tdActions = el('td', 'gs-cellule-actions');
      if (facture.statut === 'a_payer') {
        var payee = el('button', 'gs-bouton gs-bouton--petit gs-bouton--plein', 'Marquer payée');
        payee.type = 'button';
        payee.addEventListener('click', function () {
          var fin = attente(payee, 'Enregistrement…');
          API.admin.modifierFacture(facture.id, { statut: 'payee', payee_le: new Date().toISOString() })
            .then(function () { toast('Facture ' + facture.numero + ' marquée payée.'); return chargerFactures(); })
            .catch(function (err) { toast(messageErreur(err), true); })
            .then(fin);
        });
        tdActions.appendChild(payee);
      }
      var imprimerBouton = el('button', 'gs-bouton gs-bouton--petit gs-bouton--contour', 'Imprimer');
      imprimerBouton.type = 'button';
      imprimerBouton.setAttribute('aria-label', 'Imprimer la facture ' + facture.numero);
      imprimerBouton.addEventListener('click', function () { imprimerFacture(facture); });
      tdActions.appendChild(imprimerBouton);

      var modifier = el('button', 'gs-bouton gs-bouton--petit gs-bouton--contour', 'Modifier');
      modifier.type = 'button';
      modifier.addEventListener('click', function () { ouvrirFacture(facture); });
      tdActions.appendChild(modifier);

      if (client.telephone) {
        var whatsapp = el('button', 'gs-bouton gs-bouton--petit gs-bouton--contour', 'WhatsApp');
        whatsapp.type = 'button';
        whatsapp.addEventListener('click', function () {
          var modele = MESSAGE_FACTURE[client.langue] || MESSAGE_FACTURE.fr;
          var texte = modele
            .replace('{nom}', (client.nom_complet || '').split(' ')[0])
            .replace('{numero}', facture.numero)
            .replace('{montant}', argent(facture.montant_usd))
            .replace('{lien}', facture.lien_paiement ? '\n' + facture.lien_paiement : '');
          var numero = String(client.telephone).replace(/\D/g, '');
          window.open('https://wa.me/' + numero + '?text=' + encodeURIComponent(texte), '_blank', 'noopener');
        });
        tdActions.appendChild(whatsapp);
      }

      var supprimer = el('button', 'gs-bouton gs-bouton--petit gs-bouton--danger', 'Supprimer');
      supprimer.type = 'button';
      supprimer.addEventListener('click', function () {
        if (!window.confirm('Supprimer définitivement la facture ' + facture.numero + ' ?')) return;
        API.admin.supprimerFacture(facture.id)
          .then(function () { toast('Facture supprimée.'); return chargerFactures(); })
          .catch(function (err) { toast(messageErreur(err), true); });
      });
      tdActions.appendChild(supprimer);
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

  function chargerColisDuClient(client) {
    listeColisFacture.textContent = 'Chargement…';
    API.admin.colis({ clientId: client.id, statut: '', parPage: 40 }).then(function (r) {
      listeColisFacture.textContent = '';
      if (!r.lignes.length) {
        listeColisFacture.appendChild(el('p', 'gs-champ__aide', 'Ce client n’a aucun colis enregistré.'));
        return;
      }
      r.lignes.forEach(function (colis) {
        var label = el('label');
        var input = document.createElement('input');
        input.type = 'checkbox';
        input.value = colis.id;
        input.setAttribute('data-colis-id', colis.id);
        input.setAttribute('data-colis-libelle', [colis.numero, colis.description].filter(Boolean).join(' — '));
        var span = el('span');
        span.appendChild(el('strong', '', colis.numero));
        span.appendChild(el('span', 'gs-cellule-sous', [colis.description, STATUTS[colis.statut]].filter(Boolean).join(' · ')));
        label.appendChild(input);
        label.appendChild(span);
        listeColisFacture.appendChild(label);
      });
    }).catch(function () {
      listeColisFacture.textContent = '';
      listeColisFacture.appendChild(el('p', 'gs-champ__aide', 'Colis indisponibles pour l’instant.'));
    });
  }

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

  function ouvrirFacture(facture) {
    factureEditee = facture;
    formFacture.reset();
    erreurFormulaire(formFacture, '');
    $('[data-dialogue-titre]', dlgFacture).textContent = facture ? 'Modifier la facture ' + facture.numero : 'Nouvelle facture';
    blocPaiement.hidden = !facture;
    blocColisFacture.hidden = true;
    listeColisFacture.textContent = '';
    if (facture) {
      var client = facture.clients || {};
      champCodeFacture.value = client.code || '';
      champCodeFacture.readOnly = true;
      clientFacture = { id: facture.client_id, nom_complet: client.nom_complet, code: client.code };
      infoClientFacture.className = 'gs-champ__aide gs-client-trouve is-ok';
      infoClientFacture.textContent = '✓ ' + (client.nom_complet || '');
      formFacture.montant_usd.value = facture.montant_usd;
      formFacture.echeance_le.value = facture.echeance_le || '';
      formFacture.lien_paiement.value = facture.lien_paiement || '';
      formFacture.note.value = facture.note || '';
      formFacture.statut.value = facture.statut;
      formFacture.moyen.value = facture.moyen || '';
    } else {
      champCodeFacture.readOnly = false;
      clientFacture = null;
      infoClientFacture.textContent = '';
      infoClientFacture.className = 'gs-champ__aide gs-client-trouve';
    }
    dlgFacture.showModal();
  }

  formFacture.addEventListener('submit', function (e) {
    e.preventDefault();
    erreurFormulaire(formFacture, '');
    if (!clientFacture) { erreurFormulaire(formFacture, 'Indiquez d’abord le code du client.'); return; }
    var montant = Number(String(formFacture.montant_usd.value).replace(',', '.'));
    if (!(montant >= 0)) { erreurFormulaire(formFacture, 'Indiquez le montant de la facture.'); return; }

    var champs = {
      client_id: clientFacture.id,
      montant_usd: montant,
      echeance_le: formFacture.echeance_le.value || null,
      lien_paiement: formFacture.lien_paiement.value.trim(),
      note: formFacture.note.value.trim()
    };
    if (factureEditee) {
      champs.statut = formFacture.statut.value;
      champs.moyen = formFacture.moyen.value;
      if (champs.statut === 'payee' && !factureEditee.payee_le) champs.payee_le = new Date().toISOString();
    }

    var lignes = $$('[data-colis-id]', listeColisFacture).filter(function (i) { return i.checked; }).map(function (i) {
      return { colis_id: i.getAttribute('data-colis-id'), libelle: i.getAttribute('data-colis-libelle'), montant_usd: 0 };
    });

    var bouton = $('button[type="submit"]', formFacture);
    var fin = attente(bouton, 'Enregistrement…');
    var action = factureEditee
      ? API.admin.modifierFacture(factureEditee.id, champs)
      : API.admin.creerFacture(champs, lignes);
    action.then(function (f) {
      // Aucun lien fourni : on en fabrique un avec l'adresse PayPal des réglages
      if (!factureEditee && f && !champs.lien_paiement) {
        var lien = lienCarte(f.numero, montant);
        if (lien) return API.admin.modifierFacture(f.id, { lien_paiement: lien }).then(function () { return f; });
      }
      return f;
    }).then(function (f) {
      dlgFacture.close();
      toast(factureEditee ? 'Facture mise à jour.' : 'Facture ' + (f && f.numero ? f.numero : '') + ' créée.');
      return chargerFactures();
    }).catch(function (err) {
      erreurFormulaire(formFacture, messageErreur(err));
    }).then(fin);
  });

  /* ---- Onglets Colis / Clients / Factures -------------------------------------------------- */
  var onglets = $$('[data-onglet-vue]');
  function choisirVue(vue) {
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
      var autre = onglets[(i + 1) % onglets.length];
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
  var colisEdite = null;
  var clientChoisi = null;
  var recherchesClient = 0;

  function montrerClient(client, message) {
    clientChoisi = client;
    infoClient.className = 'gs-champ__aide gs-client-trouve' + (client ? ' is-ok' : (message ? ' is-erreur' : ''));
    infoClient.textContent = client
      ? '✓ ' + client.nom_complet + ' — ' + [client.ville, client.region, PAYS[client.pays]].filter(Boolean).join(', ')
      : (message || '');
  }

  function chercherClient(prefill) {
    var code = API.normaliserCode(champCode.value);
    if (!code) { montrerClient(null, champCode.value.trim() ? 'Code client invalide (format GSE-4323).' : ''); return Promise.resolve(null); }
    var numero = ++recherchesClient;
    infoClient.className = 'gs-champ__aide gs-client-trouve';
    infoClient.textContent = 'Recherche du client…';
    return API.admin.chercherClient(code).then(function (client) {
      if (numero !== recherchesClient) return clientChoisi;
      if (!client) { montrerClient(null, 'Aucun client avec le code ' + code + '.'); return null; }
      montrerClient(client);
      if (prefill) {
        var f = formColis.elements;
        if (PAYS[client.pays] && client.pays !== 'US') f.pays_destination.value = client.pays;
        if (!f.destination.value) f.destination.value = client.ville || '';
      }
      return client;
    }).catch(function (err) { montrerClient(null, messageErreur(err)); return null; });
  }

  var delaiCode = null;
  champCode.addEventListener('input', function () {
    clearTimeout(delaiCode);
    clientChoisi = null;
    delaiCode = setTimeout(function () { chercherClient(!colisEdite); }, 350);
  });
  champCode.addEventListener('blur', function () {
    var code = API.normaliserCode(champCode.value);
    if (code) champCode.value = code;
  });

  // Date et heure au format des champs du formulaire (heure locale)
  function deux(n) { return (n < 10 ? '0' : '') + n; }
  function valeurDate(d) { return d.getFullYear() + '-' + deux(d.getMonth() + 1) + '-' + deux(d.getDate()); }
  function valeurHeure(d) { return deux(d.getHours()) + ':' + deux(d.getMinutes()); }
  function dateHeureSaisie(date, heure) {
    var d = new Date(date + 'T' + (heure || '00:00'));
    return isNaN(d.getTime()) ? null : d;
  }

  function ouvrirColis(options) {
    options = options || {};
    colisEdite = options.colis || null;
    formColis.reset();
    erreurFormulaire(formColis, '');
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
    } else {
      f.code.value = options.code || etat.colis.clientCode || '';
      f.lieu.value = 'Miami (Medley), FL';
    }
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
    var poids = String(f.poids_lb.value || '').replace(',', '.').trim();
    if (poids && (isNaN(Number(poids)) || Number(poids) < 0)) {
      erreurFormulaire(formColis, 'Poids invalide : indiquez un nombre en livres (ex. 4,5).');
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
        erreurFormulaire(formColis, 'Indiquez le code d’un client existant (ex. GSE-4323).');
        f.code.focus();
        return;
      }
      var donnees = {
        client_id: client.id,
        description: f.description.value.trim(),
        expediteur: f.expediteur.value.trim(),
        recu_le: reception.toISOString(),
        suivi_transporteur: f.suivi_transporteur.value.trim(),
        poids_lb: poids ? Math.round(Number(poids) * 100) / 100 : null,
        service: f.service.value,
        pays_destination: f.pays_destination.value,
        destination: f.destination.value.trim()
      };
      if (!colisEdite) {
        donnees.statut = f.statut.value;
        donnees.lieu = f.lieu.value.trim();
        donnees.note = f.note.value.trim();
      }
      var creation = !colisEdite;
      var prevenir = creation && f.prevenir.checked;
      var action = creation ? API.admin.creerColis(donnees) : API.admin.modifierColis(colisEdite.id, donnees);
      return action.then(function (colis) {
        attente(bouton);
        dlgColis.close();
        etat.vus[colis.id] = null;
        chargerStatistiques();
        chargerColis(true);
        if (prevenir) {
          notifier([{ colis: colis, client: client }], 'recu', { apresEnregistrement: true });
        } else {
          toast(creation ? 'Colis ' + colis.numero + ' enregistré pour ' + client.nom_complet + '.' : 'Colis ' + colis.numero + ' modifié.');
        }
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
    if (colis) {
      var radio = $('input[name="statut"][value="' + colis.statut + '"]', formStatut);
      if (radio) radio.checked = true;
      formStatut.elements.lieu.value = colis.lieu || '';
      formStatut.elements.note.value = colis.note || '';
      API.admin.historique(colis.id).then(function (h) {
        O.remplirHistorique(historique, h, { notes: true, libelle: function (s) { return STATUTS[s] || s; } });
      }).catch(function () { /* historique facultatif */ });
      afficherNotificationsEnvoyees(colis.id);
    }
    majChoixStatut();
    dlgStatut.showModal();
    var coche = $('input[name="statut"]:checked', formStatut) || $('input[name="statut"]', formStatut);
    coche.focus();
  }

  // « Disponible en agence » : l'agence devient obligatoire et le client est prévenu
  var libelleLieu = $('[data-libelle-lieu]', formStatut);
  var libelleLieuOrigine = libelleLieu.innerHTML;
  function majChoixStatut() {
    var statut = ($('input[name="statut"]:checked', formStatut) || {}).value;
    var colis = cibleStatut.colis;
    var disponible = statut === 'disponible';
    // Le client est prévenu quand son colis devient disponible (pas à chaque modification)
    $('[data-bloc-prevenir]', formStatut).hidden = !disponible || !!(colis && colis.statut === 'disponible');
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
    erreurFormulaire(formStatut, '');
    var bouton = $('[data-envoyer]', formStatut);
    var prevenir = statut === 'disponible' && f.prevenir.checked && !$('[data-bloc-prevenir]', formStatut).hidden;
    var note = f.note.value.trim();
    // Colis qui deviennent disponibles, avec les coordonnées de leur client
    var concernes = (cibleStatut.colis ? [cibleStatut.colis] : etat.colis.lignes.filter(function (l) {
      return cibleStatut.ids.indexOf(l.id) >= 0;
    })).filter(function (l) { return l.statut !== 'disponible'; });
    attente(bouton, 'Mise à jour…');
    API.admin.changerStatut(cibleStatut.ids, { statut: statut, lieu: lieu, note: note })
      .then(function (n) {
        attente(bouton);
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
