/* ==========================================================================
   Goship Express — les pré-alertes (onglet « Pré-alertes » du tableau de bord)
   --------------------------------------------------------------------------
   Un client annonce un achat depuis l'application avant qu'il arrive à Miami :
   magasin, contenu, numéro de suivi du vendeur. Jusqu'ici, l'équipe ne voyait
   rien de ces annonces. Cet onglet les montre, et propose d'enregistrer le
   colis pour le bon client quand le carton arrive.

   Il ne décide de rien :
     - la liste vient de API.admin.prealertes (lecture, règle RLS existante
       prealertes_lecture : shipments.view) ;
     - « Enregistrer le colis » ouvre le formulaire habituel (admin.js), rempli
       avec ce que le client a annoncé. C'est creer_colis qui crée le colis, et
       le déclencheur rapprocher_prealerte qui passe la pré-alerte à « Reçue »
       quand le client et le numéro sont les mêmes. Aucun statut de colis,
       aucun événement n'est touché ici ;
     - « Modifier » (pré-alerte en attente, shipments.edit) et « Supprimer »
       (pas une pré-alerte reçue, shipments.delete) passent par
       modifier_prealerte et supprimer_prealerte (outils/supabase-prealertes-
       equipe.sql) : la base contrôle, refuse et journalise. Les boutons ne
       paraissent que pour un rôle qui a la permission ; la base refuse d'elle-
       même dans tous les autres cas.
   Le transporteur affiché vient de GoshipTransporteur (transporteur.js) :
   seulement quand le numéro le prouve.
   ========================================================================== */
(function () {
  'use strict';

  var API = window.GoshipAPI;
  var vue = document.querySelector('[data-vue="prealertes"]');
  if (!API || !vue || !API.admin || !API.admin.prealertes) return;
  var O = API.outils;

  function $(sel, scope) { return (scope || document).querySelector(sel); }
  function el(balise, classe, texte) {
    var n = document.createElement(balise);
    if (classe) n.className = classe;
    if (texte !== undefined && texte !== null) n.textContent = texte;
    return n;
  }

  // Les états d'une pré-alerte, avec la couleur d'un statut de colis qui dit la même chose
  var ETATS = { attente: 'En attente', recu: 'Reçue', annulee: 'Annulée' };
  var COULEURS = { attente: 'gs-badge--distribution', recu: 'gs-badge--livre', annulee: 'gs-badge--facture-annulee' };
  var SERVICES = { aerien: 'Aérien', maritime: 'Maritime', terrestre: 'Terrestre' };
  var TAILLES_PAGE = [10, 25, 50, 100];

  var etat = { statut: 'attente', recherche: '', page: 0, parPage: 25, charge: false, requete: 0 };
  var corps = $('[data-lignes="prealertes"]', vue);
  var zoneVide = $('[data-vide="prealertes"]', vue);
  var champRecherche = $('[data-recherche-prealertes]', vue);
  var choixStatut = $('[data-filtre-prealertes]', vue);
  var total = document.querySelector('[data-total="prealertes"]');

  // Le droit de créer un colis : lu comme admin.js le fait, depuis la base
  var droits = null;
  function peutFaire(permission) { return !!droits && droits.indexOf(permission) >= 0; }
  function peutCreer() { return peutFaire('shipments.create'); }
  function lireDroits() {
    if (droits) return Promise.resolve(droits);
    return API.permissions().then(function (p) { droits = (p && p.permissions) || []; return droits; },
                                  function () { droits = []; return droits; });
  }

  function transporteurDe(numero) {
    return window.GoshipTransporteur && numero ? window.GoshipTransporteur(numero) : null;
  }

  // Les refus de modifier_prealerte et supprimer_prealerte : la base joint sa phrase
  // (prioritaire) ; ces textes servent au mode démonstration et en dernier recours
  var REFUS = {
    PREALERT_NOT_FOUND: 'Cette pré-alerte n’existe plus : rechargez la liste.',
    PREALERT_NOT_PENDING: 'Cette pré-alerte n’est plus en attente : elle ne se modifie plus.',
    PREALERT_RECEIVED: 'Cette pré-alerte est rattachée à un colis : elle ne se supprime pas.',
    PREALERT_STORE_REQUIRED: 'Indiquez le magasin.',
    PREALERT_DESCRIPTION_REQUIRED: 'Indiquez le contenu du colis.',
    PREALERT_DUPLICATE: 'Ce numéro de suivi est déjà annoncé par ce client dans une autre pré-alerte.',
    PREALERT_ALREADY_RECEIVED: 'Ce colis est déjà arrivé chez ce client.',
    INVALID_TRACKING: 'Numéro de suivi illisible : lettres et chiffres seulement, de 6 à 60.',
    INVALID_VALUE: 'La valeur doit être comprise entre 0 et 100 000 $.',
    INVALID_SERVICE: 'Mode inconnu.',
    REASON_REQUIRED: 'Indiquez un motif (5 caractères au moins).',
    'non-autorise': 'Votre rôle ne permet pas cette action.',
    reseau: 'Connexion impossible : vérifiez le réseau, puis réessayez.'
  };
  function messageRefus(err) {
    if (err && err.metier && err.detail) return err.detail;
    return REFUS[err && err.code] || 'L’opération n’a pas abouti. Réessayez.';
  }

  function messageErreur(err) {
    if (err && err.metier && err.detail) return err.detail;
    if (err && err.code === 'reseau') return 'Connexion impossible : vérifiez le réseau, puis réessayez.';
    if (err && err.code === 'non-autorise') return 'Votre rôle ne permet pas de voir les pré-alertes.';
    return 'Les pré-alertes n’ont pas pu être lues.';
  }

  /* ---- Le colis du client, à partir de sa pré-alerte ---------------------- */
  // Le formulaire d'enregistrement (admin.js) s'ouvre rempli : client, numéro,
  // magasin, contenu, mode. L'employé complète et enregistre ; la base fait le reste.
  function enregistrerColis(p) {
    document.dispatchEvent(new CustomEvent('goship:nouveau-colis', {
      detail: { code: p.code_client || '', prealerte: p }
    }));
  }

  /* ---- Une ligne ---------------------------------------------------------- */
  function cellule(libelle) {
    var td = el('td');
    if (libelle) td.setAttribute('data-libelle', libelle);
    return td;
  }

  function ligne(p) {
    var tr = el('tr');

    var tdSuivi = cellule('Numéro de suivi');
    tdSuivi.appendChild(el('span', 'gs-cellule-num', p.suivi_transporteur || 'Sans numéro'));
    var t = transporteurDe(p.suivi_transporteur);
    tdSuivi.appendChild(el('span', 'gs-cellule-sous', t ? t.nom : (p.suivi_transporteur ? 'Transporteur non déterminé' : '')));
    tr.appendChild(tdSuivi);

    var tdClient = cellule('Client');
    tdClient.appendChild(el('span', 'gs-cellule-principale', p.nom_client || 'Client supprimé'));
    tdClient.appendChild(el('span', 'gs-cellule-sous', [p.code_client, p.telephone_client].filter(Boolean).join(' · ')));
    tr.appendChild(tdClient);

    var tdAchat = cellule('Magasin et contenu');
    tdAchat.appendChild(el('span', 'gs-cellule-principale', p.magasin || '—'));
    tdAchat.appendChild(el('span', 'gs-cellule-sous', [p.description, SERVICES[p.service] || p.service,
      p.valeur_usd != null ? O.argent(p.valeur_usd) : ''].filter(Boolean).join(' · ')));
    tr.appendChild(tdAchat);

    var tdDate = cellule('Annoncée le');
    tdDate.appendChild(el('span', null, O.date(p.cree_le, true)));
    tr.appendChild(tdDate);

    var tdEtat = cellule('État');
    tdEtat.appendChild(el('span', 'gs-badge ' + (COULEURS[p.statut] || ''), ETATS[p.statut] || p.statut));
    if (p.numero_colis) tdEtat.appendChild(el('span', 'gs-cellule-sous', 'Colis ' + p.numero_colis));
    tr.appendChild(tdEtat);

    // La seule action : enregistrer le colis d'une pré-alerte en attente. Ouvrir le
    // colis déjà rapproché passe par sa fiche (clic sur la ligne : fiche générique).
    var tdAction = el('td', 'gs-cellule-actions');
    if (p.statut === 'attente' && p.code_client && peutCreer()) {
      var b = el('button', 'gs-bouton gs-bouton--petit gs-bouton--plein', 'Enregistrer le colis');
      b.type = 'button';
      b.setAttribute('data-prealerte-colis', '');
      b.setAttribute('aria-label', 'Enregistrer le colis de ' + (p.nom_client || p.code_client));
      b.addEventListener('click', function () { enregistrerColis(p); });
      tdAction.appendChild(b);
    } else if (p.numero_colis) {
      var voir = el('button', 'gs-bouton gs-bouton--petit gs-bouton--contour', 'Voir le colis');
      voir.type = 'button';
      voir.addEventListener('click', function () {
        document.dispatchEvent(new CustomEvent('goship:fiche-colis', { detail: { numero: p.numero_colis } }));
      });
      tdAction.appendChild(voir);
    }
    // Modifier : une pré-alerte en attente ; supprimer : toute pré-alerte qui n'est pas
    // rattachée à un colis. La base applique les mêmes règles, et d'autres encore.
    if (p.statut === 'attente' && peutFaire('shipments.edit')) {
      var modifier = el('button', 'gs-bouton gs-bouton--petit gs-bouton--contour', 'Modifier');
      modifier.type = 'button';
      modifier.setAttribute('data-prealerte-modifier', '');
      modifier.setAttribute('aria-label', 'Modifier la pré-alerte ' + (p.suivi_transporteur || p.magasin || ''));
      modifier.addEventListener('click', function () { ouvrirModification(p); });
      tdAction.appendChild(modifier);
    }
    if (p.statut !== 'recu' && peutFaire('shipments.delete')) {
      var supprimer = el('button', 'gs-bouton gs-bouton--petit gs-bouton--danger', 'Supprimer');
      supprimer.type = 'button';
      supprimer.setAttribute('data-prealerte-supprimer', '');
      supprimer.setAttribute('aria-label', 'Supprimer la pré-alerte ' + (p.suivi_transporteur || p.magasin || ''));
      supprimer.addEventListener('click', function () { ouvrirSuppression(p); });
      tdAction.appendChild(supprimer);
    }
    tr.appendChild(tdAction);
    return tr;
  }

  /* ---- Modifier, supprimer ------------------------------------------------ */
  // Deux fenêtres de admin.html. Fermeture, « Fermer sans enregistrer ? » : admin.js,
  // comme toutes les fenêtres du tableau de bord ; d.close() ferme sans question.
  var dlgModifier = document.querySelector('[data-dialogue="prealerte-modifier"]');
  var formModifier = dlgModifier && $('form[data-form="prealerte-modifier"]', dlgModifier);
  var dlgSupprimer = document.querySelector('[data-dialogue="prealerte-supprimer"]');
  var formSupprimer = dlgSupprimer && $('form[data-form="prealerte-supprimer"]', dlgSupprimer);
  var enCours = null;

  function erreurDe(form, texte) {
    var n = $('[data-form-erreur]', form);
    n.textContent = texte || '';
    n.hidden = !texte;
  }
  function attendre(bouton, texte) {
    if (texte) { bouton.setAttribute('data-texte', bouton.textContent); bouton.textContent = texte; bouton.disabled = true; }
    else { bouton.textContent = bouton.getAttribute('data-texte') || bouton.textContent; bouton.disabled = false; }
  }
  function annoncer(message, erreur) {
    document.dispatchEvent(new CustomEvent('goship:toast', { detail: { message: message, erreur: !!erreur } }));
  }
  function nomDe(p) { return [p.nom_client, p.code_client].filter(Boolean).join(' · ') || 'Client supprimé'; }

  function ouvrirModification(p) {
    if (!dlgModifier) return;
    enCours = p;
    formModifier.reset();
    erreurDe(formModifier, '');
    $('[data-prealerte-client]', dlgModifier).textContent = nomDe(p);
    var f = formModifier.elements;
    f.magasin.value = p.magasin || '';
    f.description.value = p.description || '';
    f.suivi_transporteur.value = p.suivi_transporteur || '';
    f.valeur_usd.value = p.valeur_usd != null ? String(p.valeur_usd) : '';
    f.service.value = SERVICES[p.service] ? p.service : 'aerien';
    dlgModifier.showModal();
    f.magasin.focus();
  }

  function ouvrirSuppression(p) {
    if (!dlgSupprimer) return;
    enCours = p;
    formSupprimer.reset();
    erreurDe(formSupprimer, '');
    $('[data-prealerte-resume]', dlgSupprimer).textContent =
      [p.suivi_transporteur || 'Sans numéro', p.magasin, nomDe(p)].filter(Boolean).join(' · ');
    dlgSupprimer.showModal();
    formSupprimer.elements.motif.focus();
  }

  if (formModifier) formModifier.addEventListener('submit', function (e) {
    e.preventDefault();
    if (!enCours) return;
    var f = formModifier.elements;
    // Tous les champs partent : la base ne retient que ce qui change vraiment
    var champs = { magasin: f.magasin.value, description: f.description.value,
                   suivi_transporteur: f.suivi_transporteur.value, service: f.service.value,
                   valeur_usd: f.valeur_usd.value.trim() === '' ? null : f.valeur_usd.value.trim() };
    if (!champs.magasin.trim()) { erreurDe(formModifier, REFUS.PREALERT_STORE_REQUIRED); f.magasin.focus(); return; }
    if (!champs.description.trim()) { erreurDe(formModifier, REFUS.PREALERT_DESCRIPTION_REQUIRED); f.description.focus(); return; }
    erreurDe(formModifier, '');
    var bouton = $('[data-envoyer]', formModifier);
    attendre(bouton, 'Enregistrement…');
    API.admin.modifierPrealerte(enCours.id, champs, f.motif.value.trim() || null).then(function (r) {
      attendre(bouton);
      dlgModifier.close();
      annoncer(r && r.deja ? 'Rien n’a changé.' : 'Pré-alerte modifiée.');
      charger();
    }).catch(function (err) {
      attendre(bouton);
      erreurDe(formModifier, messageRefus(err));
    });
  });

  if (formSupprimer) formSupprimer.addEventListener('submit', function (e) {
    e.preventDefault();
    if (!enCours) return;
    var motif = formSupprimer.elements.motif.value.trim();
    if (motif.length < 5) { erreurDe(formSupprimer, REFUS.REASON_REQUIRED); formSupprimer.elements.motif.focus(); return; }
    erreurDe(formSupprimer, '');
    var bouton = $('[data-envoyer]', formSupprimer);
    attendre(bouton, 'Suppression…');
    API.admin.supprimerPrealerte(enCours.id, motif).then(function () {
      attendre(bouton);
      dlgSupprimer.close();
      annoncer('Pré-alerte supprimée.');
      charger();
      compterEnAttente();
    }).catch(function (err) {
      attendre(bouton);
      erreurDe(formSupprimer, messageRefus(err));
    });
  });

  /* ---- La pagination : même barre que les autres listes ------------------- */
  function paginer(totalLignes) {
    var zone = $('[data-pagination="prealertes"]', vue);
    zone.textContent = '';
    zone.hidden = !totalLignes || (totalLignes <= TAILLES_PAGE[0] && !etat.page);
    if (zone.hidden) return;
    var taille = el('label', 'gs-pagination__taille');
    taille.appendChild(el('span', '', 'Lignes par page'));
    var choix = el('select', 'gs-admin-filtre gs-admin-filtre--petit');
    TAILLES_PAGE.forEach(function (n) {
      var o = new Option(String(n), String(n));
      o.selected = n === etat.parPage;
      choix.add(o);
    });
    choix.addEventListener('change', function () { etat.parPage = Number(choix.value); etat.page = 0; charger(); });
    taille.appendChild(choix);
    zone.appendChild(taille);
    var premier = etat.page * etat.parPage + 1, dernier = Math.min(totalLignes, (etat.page + 1) * etat.parPage);
    zone.appendChild(el('span', 'gs-pagination__texte', premier + '–' + dernier + ' sur ' + totalLignes));
    var precedente = el('button', 'gs-bouton gs-bouton--petit gs-bouton--contour', 'Précédente');
    precedente.type = 'button';
    precedente.disabled = etat.page === 0;
    precedente.addEventListener('click', function () { etat.page -= 1; charger(); });
    var suivante = el('button', 'gs-bouton gs-bouton--petit gs-bouton--contour', 'Suivante');
    suivante.type = 'button';
    suivante.disabled = dernier >= totalLignes;
    suivante.addEventListener('click', function () { etat.page += 1; charger(); });
    zone.appendChild(precedente);
    zone.appendChild(suivante);
  }

  /* ---- Charger, afficher -------------------------------------------------- */
  function charger() {
    var n = ++etat.requete;
    vue.setAttribute('aria-busy', 'true');
    return lireDroits().then(function () {
      return API.admin.prealertes({ statut: etat.statut, recherche: etat.recherche, page: etat.page,
                                    parPage: etat.parPage });
    }).then(function (r) {
      if (n !== etat.requete) return;   // une recherche plus récente a déjà répondu
      if (!r.lignes.length && etat.page > 0 && r.total > 0) {
        etat.page = Math.ceil(r.total / etat.parPage) - 1;
        return charger();
      }
      etat.charge = true;
      corps.textContent = '';
      r.lignes.forEach(function (p) { corps.appendChild(ligne(p)); });
      zoneVide.hidden = r.lignes.length > 0;
      zoneVide.textContent = etat.recherche ? 'Aucune pré-alerte ne correspond à cette recherche.'
        : (etat.statut === 'attente' ? 'Aucune pré-alerte en attente.' : 'Aucune pré-alerte.');
      paginer(r.total);
      if (etat.statut === 'attente' && !etat.recherche) montrerTotal(r.total);
    }).catch(function (err) {
      if (n !== etat.requete) return;
      corps.textContent = '';
      zoneVide.hidden = false;
      zoneVide.textContent = messageErreur(err);
      $('[data-pagination="prealertes"]', vue).hidden = true;
    }).then(function () {
      // Seule la dernière requête dit que le chargement est fini : une réponse périmée
      // (une recherche tapée entre-temps) ne doit pas l'annoncer avant elle
      if (n === etat.requete) vue.removeAttribute('aria-busy');
    });
  }

  // Le nombre de pré-alertes en attente, à côté du nom de l'onglet
  function montrerTotal(n) {
    if (!total) return;
    total.textContent = n ? O.nombre(n) : '';
  }
  function compterEnAttente() {
    API.admin.prealertes({ statut: 'attente', parPage: 1 })
      .then(function (r) { montrerTotal(r.total); }, function () { /* sans le compte, l'onglet reste utilisable */ });
  }

  var minuteur = null;
  champRecherche.addEventListener('input', function () {
    clearTimeout(minuteur);
    minuteur = setTimeout(function () { etat.recherche = champRecherche.value.trim(); etat.page = 0; charger(); }, 250);
  });
  choixStatut.addEventListener('change', function () { etat.statut = choixStatut.value; etat.page = 0; charger(); });

  // L'onglet s'ouvre (admin.js, choisirVue) : la liste se relit, jamais d'il y a une heure
  var compte = false;
  window.addEventListener('goship:vue', function (e) {
    if (e.detail === 'prealertes') { charger(); return; }
    if (!compte) { compte = true; compterEnAttente(); }
  });
  // Un colis vient d'être enregistré : une pré-alerte a pu passer à « Reçue »
  document.addEventListener('goship:colis-enregistre', function () {
    if (!vue.hidden) charger(); else compterEnAttente();
  });

  // Pour les essais automatiques et la console
  window.GoshipPrealertes = { charger: charger, modifier: ouvrirModification, supprimer: ouvrirSuppression };
})();
