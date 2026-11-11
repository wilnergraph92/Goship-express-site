/* ==========================================================================
   Goship Express — les pré-alertes (onglet « Pré-alertes » du tableau de bord)
   --------------------------------------------------------------------------
   Un client annonce un achat depuis l'application avant qu'il arrive à Miami :
   magasin, contenu, numéro de suivi du vendeur. Jusqu'ici, l'équipe ne voyait
   rien de ces annonces. Cet onglet les montre, et propose d'enregistrer le
   colis pour le bon client quand le carton arrive.

   Il ne décide de rien et n'écrit rien :
     - la liste vient de API.admin.prealertes (lecture, règle RLS existante
       prealertes_lecture : shipments.view) ;
     - « Enregistrer le colis » ouvre le formulaire habituel (admin.js), rempli
       avec ce que le client a annoncé. C'est creer_colis qui crée le colis, et
       le déclencheur rapprocher_prealerte qui passe la pré-alerte à « Reçue »
       quand le client et le numéro sont les mêmes. Aucun statut de colis,
       aucun événement n'est touché ici.
   Le transporteur affiché vient de GoshipScan.transporteur (scan-parser.js) :
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
  function peutCreer() { return !!droits && droits.indexOf('shipments.create') >= 0; }
  function lireDroits() {
    if (droits) return Promise.resolve(droits);
    return API.permissions().then(function (p) { droits = (p && p.permissions) || []; return droits; },
                                  function () { droits = []; return droits; });
  }

  function transporteurDe(numero) {
    return window.GoshipScan && numero ? window.GoshipScan.transporteur(numero) : null;
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
    tr.appendChild(tdAction);
    return tr;
  }

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
  window.GoshipPrealertes = { charger: charger };
})();
