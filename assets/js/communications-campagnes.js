/* C6 — gestion des campagnes marketing, sans transmission réelle. */
(function (racine) {
  'use strict';

  function criteresDepuisValeurs(v) {
    v = v || {};
    var regles = [];
    var pays = v.pays || '';
    var langue = v.langue_client || '';
    var inscription = v.inscription_jours == null ? '' : String(v.inscription_jours).trim();
    var colis = v.a_des_colis == null ? '' : String(v.a_des_colis);
    var prealertes = v.a_des_prealertes == null ? '' : String(v.a_des_prealertes);
    var activite = v.activite_jours == null ? '' : String(v.activite_jours).trim();
    var n;
    if (pays) {
      if (['US', 'DO', 'HT'].indexOf(pays) < 0) return null;
      regles.push({ champ: 'pays', operateur: 'est', valeur: pays });
    }
    if (langue) {
      if (['fr', 'en', 'es', 'ht'].indexOf(langue) < 0) return null;
      regles.push({ champ: 'langue', operateur: 'est', valeur: langue });
    }
    if (inscription !== '') {
      n = Number(inscription);
      if (!isFinite(n) || Math.floor(n) !== n || n < 0 || n > 3650) return null;
      regles.push({ champ: 'inscrit_depuis_jours',
        operateur: v.inscription_operateur === 'au_plus' ? 'au_plus' : 'au_moins', valeur: n });
    }
    if (colis !== '') {
      if (colis !== 'true' && colis !== 'false') return null;
      regles.push({ champ: 'a_des_colis', operateur: 'est', valeur: colis === 'true' });
    }
    if (prealertes !== '') {
      if (prealertes !== 'true' && prealertes !== 'false') return null;
      regles.push({ champ: 'a_des_prealertes', operateur: 'est', valeur: prealertes === 'true' });
    }
    if (activite !== '') {
      n = Number(activite);
      if (!isFinite(n) || Math.floor(n) !== n || n < 1 || n > 3650) return null;
      regles.push({ champ: 'activite_colis_jours', operateur: 'dans_les_jours', valeur: n });
    }
    if (!regles.length || regles.length > 6) return null;
    return { mode: v.mode === 'or' ? 'or' : 'and', regles: regles };
  }
  function statutCampagne(etat) {
    var labels = {
      draft: 'Brouillon', pending_approval: 'En attente d’approbation', approved: 'Approuvée',
      scheduled: 'Planifiée — sans envoi', cancelled: 'Annulée', completed: 'Terminée'
    };
    return labels[etat] || 'État inconnu';
  }
  function apercuMessageDepuisModeles(canaux, disponibles, ids, langue) {
    if (!Array.isArray(canaux) || !disponibles || !ids ||
        ['fr', 'en', 'es', 'ht'].indexOf(langue) < 0) return [];
    return canaux.reduce(function (parts, canal) {
      var modele = (disponibles[canal] || []).filter(function (m) {
        return String(m.id) === String(ids[canal]);
      })[0];
      var contenu = modele && modele.traductions && modele.traductions[langue];
      if (contenu && typeof contenu.titre === 'string' && typeof contenu.message === 'string') {
        parts.push({ canal: canal, titre: contenu.titre, message: contenu.message });
      }
      return parts;
    }, []);
  }
  racine.GoshipCampagnes = Object.freeze({
    criteresDepuisValeurs: criteresDepuisValeurs,
    statut: statutCampagne,
    apercuMessageDepuisModeles: apercuMessageDepuisModeles,
    coutReelDisponible: function () { return false; },
    transmissionActive: function () { return false; }
  });

  var panneau = document.querySelector('[data-cc-pane="campaigns"]');
  if (!panneau) return;

  var campagnes = [];
  var segments = [];
  var modeles = { email: [], whatsapp: [], push: [] };
  var campagneActive = null;
  var permissions = [];
  var chargementRole = null;
  var chargement = false;
  var editionModifiee = false;

  function $(selecteur, parent) { return (parent || panneau).querySelector(selecteur); }
  function $$(selecteur, parent) { return Array.prototype.slice.call((parent || panneau).querySelectorAll(selecteur)); }
  function apiAdmin() { return racine.GoshipAPI && racine.GoshipAPI.admin; }
  function permission(p) { return permissions.indexOf(p) >= 0; }
  function texte(noeud, valeur) { if (noeud) noeud.textContent = valeur == null ? '' : String(valeur); }
  function vider(noeud) { while (noeud && noeud.firstChild) noeud.removeChild(noeud.firstChild); }
  function creer(tag, classe, contenu) {
    var n = document.createElement(tag);
    if (classe) n.className = classe;
    if (contenu != null) n.textContent = String(contenu);
    return n;
  }
  function valeur(formulaire, nom) {
    var champ = formulaire.elements.namedItem(nom);
    return champ ? String(champ.value || '').trim() : '';
  }
  function nombre(s) {
    var n = Number(s);
    return isFinite(n) ? n : null;
  }
  function dateAffichee(s) {
    if (!s) return '—';
    var d = new Date(s);
    return isNaN(d.getTime()) ? String(s) : d.toLocaleString(document.documentElement.lang || 'fr');
  }
  function afficherErreur(e) {
    var zone = $('[data-cm-error]');
    var messages = {
      absent: 'Le backend C6 n’est pas disponible dans cet environnement.',
      reseau: 'Service indisponible. Vérifiez la connexion et réessayez.',
      'non-autorise': 'Accès refusé : votre rôle ne permet pas cette action.',
      COMMUNICATION_CAMPAIGN_AUDIENCE_CHANGED: 'L’audience a changé. Prévisualisez-la puis soumettez une nouvelle fois.',
      COMMUNICATION_CAMPAIGN_APPROVAL_REQUIRED: 'Une approbation Admin valide est requise.',
      COMMUNICATION_CAMPAIGN_PREVIEW_REQUIRED: 'Prévisualisez l’audience avant de soumettre la campagne.',
      COMMUNICATION_CAMPAIGN_SCHEDULE_REQUIRED: 'Renseignez une date locale et un fuseau IANA, puis enregistrez la révision.',
      COMMUNICATION_CAMPAIGN_SCHEDULE_PAST: 'La date prévue doit être dans le futur.',
      COMMUNICATION_CAMPAIGN_TIMEZONE_INVALID: 'Le fuseau horaire IANA n’est pas reconnu.',
      COMMUNICATION_CAMPAIGN_LIMITS_REQUIRED: 'Configurez les limites approuvées avant de poursuivre.',
      COMMUNICATION_CAMPAIGN_MODEL_CHANNEL_MISMATCH: 'Chaque canal doit avoir un modèle marketing versionné correspondant.',
      COMMUNICATION_CAMPAIGN_MODEL_LANGUAGES_REQUIRED: 'Le modèle doit contenir les quatre langues.',
      COMMUNICATION_CAMPAIGN_STATE_INVALID: 'Cette action ne correspond pas à l’état actuel de la campagne.',
      COMMUNICATION_CAMPAIGN_TERMINAL_STATE: 'Cette campagne est dans un état final.',
      COMMUNICATION_CAMPAIGN_INPUT_INVALID: 'Vérifiez les champs obligatoires et les limites numériques.',
      COMMUNICATION_CAMPAIGN_NOT_FOUND: 'Enregistrez d’abord une campagne avant cette action.',
      COMMUNICATION_SEGMENT_CRITERIA_INVALID: 'Les critères du segment sont incomplets ou non autorisés.',
      COMMUNICATION_SEGMENT_CRITERIA_DUPLICATE_FIELD: 'Un critère ne peut apparaître qu’une fois dans un segment.'
    };
    var code = e && e.code ? e.code : '';
    texte(zone, messages[code] || 'La demande n’a pas abouti. Vérifiez les champs et les permissions, puis réessayez.');
    if (zone) zone.hidden = false;
  }
  function masquerErreur() {
    var zone = $('[data-cm-error]');
    texte(zone, '');
    if (zone) zone.hidden = true;
  }
  function statut(message) { texte($('[data-cm-status]'), message || ''); }
  function executer(action, succes) {
    var resultat;
    masquerErreur();
    try { resultat = action(); } catch (e) { afficherErreur(e); return Promise.resolve(null); }
    return Promise.resolve(resultat).then(function (data) {
      if (data && data.disponible === false) {
        afficherErreur({ code: 'absent' });
        return null;
      }
      if (succes) succes(data);
      return data;
    }).catch(function (e) { afficherErreur(e); return null; });
  }
  function assurerPermissions() {
    if (chargementRole) return chargementRole;
    var api = apiAdmin();
    chargementRole = api && racine.GoshipAPI.permissions
      ? racine.GoshipAPI.permissions().then(function (p) {
          permissions = p && Array.isArray(p.permissions) ? p.permissions : [];
        }).catch(function () { permissions = []; })
      : Promise.resolve().then(function () { permissions = []; });
    return chargementRole;
  }
  function formaterCanaux(liste) {
    return (liste || []).map(function (c) {
      return c === 'email' ? 'E-mail' : c === 'whatsapp' ? 'WhatsApp' : c === 'push' ? 'Push' : c;
    }).join(', ');
  }
  function chargerListe() {
    var api = apiAdmin();
    if (!api || typeof api.communicationCampagnes !== 'function') {
      afficherErreur({ code: 'absent' });
      return Promise.resolve();
    }
    return executer(function () { return api.communicationCampagnes(100); }, function (res) {
      campagnes = res && Array.isArray(res.campagnes) ? res.campagnes : [];
      afficherCampagnes();
    });
  }
  function afficherCampagnes() {
    var corps = $('[data-cm-campaign-rows]');
    vider(corps);
    campagnes.forEach(function (c) {
      var ligne = document.createElement('tr');
      [c.nom || '—', statutCampagne(c.etat), c.revision ? 'v' + c.revision : '—',
        c.planifiee_pour ? dateAffichee(c.planifiee_pour) + ' · ' + (c.fuseau_planification || '') : '—',
        c.limites_configurees ? 'Configurées' : 'Non configurées', formaterCanaux(c.canaux)].forEach(function (v) {
        ligne.appendChild(creer('td', '', v));
      });
      var cellule = creer('td');
      var bouton = creer('button', 'gs-bouton gs-bouton--petit gs-bouton--contour', 'Ouvrir');
      bouton.type = 'button';
      bouton.setAttribute('data-cm-select-id', String(c.id));
      cellule.appendChild(bouton);
      ligne.appendChild(cellule);
      corps.appendChild(ligne);
    });
    if (!campagnes.length) {
      var vide = document.createElement('tr');
      var celluleVide = creer('td', '', 'Aucune campagne enregistrée.');
      celluleVide.colSpan = 7;
      vide.appendChild(celluleVide);
      corps.appendChild(vide);
    }
  }
  function chargerSegments() {
    if (!permission('communications.campaigns.manage')) return Promise.resolve();
    var api = apiAdmin();
    return executer(function () { return api.communicationCampagneSegments(); }, function (res) {
      segments = res && Array.isArray(res.segments) ? res.segments : [];
      remplirSegments();
    });
  }
  function remplirSegments() {
    var select = $('[name="segment"]');
    if (!select) return;
    var courant = select.value;
    while (select.options.length > 1) select.remove(1);
    segments.forEach(function (s) {
      var option = document.createElement('option');
      option.value = String(s.id);
      option.textContent = s.nom;
      select.appendChild(option);
    });
    if (courant) select.value = courant;
  }
  function chargerModeles(canal) {
    if (!permission('communications.campaigns.manage') || modeles[canal].length) return Promise.resolve();
    var api = apiAdmin();
    return executer(function () { return api.communicationCampagneModeles(canal); }, function (res) {
      modeles[canal] = res && Array.isArray(res.modeles) ? res.modeles : [];
      remplirModeles(canal);
    });
  }
  function remplirModeles(canal) {
    var select = $('[data-cm-model="' + canal + '"]');
    if (!select) return;
    var courant = select.value;
    while (select.options.length > 1) select.remove(1);
    modeles[canal].forEach(function (m) {
      var option = document.createElement('option');
      option.value = String(m.id);
      option.textContent = m.cle + ' · v' + m.version;
      option.setAttribute('data-version', String(m.version));
      select.appendChild(option);
    });
    if (courant) select.value = courant;
  }
  function canauxChoisis(formulaire) {
    return $$('input[name="canaux"]:checked', formulaire).map(function (n) { return n.value; });
  }
  function actualiserCanaux() {
    var form = $('[data-cm-campaign-form]');
    var choisis = canauxChoisis(form);
    ['email', 'whatsapp', 'push'].forEach(function (canal) {
      var conteneur = $('[data-cm-model-wrap="' + canal + '"]');
      if (conteneur) conteneur.hidden = choisis.indexOf(canal) < 0;
      if (choisis.indexOf(canal) >= 0) chargerModeles(canal);
    });
    afficherApercuModele();
  }
  function criteresDepuisForm(formulaire) {
    return criteresDepuisValeurs({
      mode: valeur(formulaire, 'mode'), pays: valeur(formulaire, 'pays'),
      langue_client: valeur(formulaire, 'langue_client'),
      inscription_jours: valeur(formulaire, 'inscription_jours'),
      inscription_operateur: valeur(formulaire, 'inscription_operateur'),
      a_des_colis: valeur(formulaire, 'a_des_colis'),
      a_des_prealertes: valeur(formulaire, 'a_des_prealertes'),
      activite_jours: valeur(formulaire, 'activite_jours')
    });
  }
  function chargerCriteres(criteres, formulaire) {
    if (!criteres || !Array.isArray(criteres.regles)) return;
    formulaire.elements.namedItem('mode').value = criteres.mode === 'or' ? 'or' : 'and';
    criteres.regles.forEach(function (r) {
      var cible = r.champ === 'pays' ? 'pays' : r.champ === 'langue' ? 'langue_client' :
        r.champ === 'inscrit_depuis_jours' ? 'inscription_jours' :
        r.champ === 'a_des_colis' ? 'a_des_colis' : r.champ === 'a_des_prealertes' ? 'a_des_prealertes' :
        r.champ === 'activite_colis_jours' ? 'activite_jours' : null;
      if (cible) formulaire.elements.namedItem(cible).value = String(r.valeur);
      if (r.champ === 'inscrit_depuis_jours') formulaire.elements.namedItem('inscription_operateur').value = r.operateur;
    });
  }
  function modelesDepuisForm(formulaire, canaux) {
    var resultat = [];
    for (var i = 0; i < canaux.length; i += 1) {
      var canal = canaux[i];
      var select = $('[data-cm-model="' + canal + '"]');
      var id = select ? select.value : '';
      var entree = modeles[canal].filter(function (m) { return String(m.id) === id; })[0];
      if (!entree) return null;
      resultat.push({ canal: canal, id: Number(entree.id), version: Number(entree.version) });
    }
    return resultat;
  }
  function afficherApercuModele() {
    var sortie = $('[data-cm-message-preview]');
    var form = $('[data-cm-campaign-form]');
    if (!sortie) return;
    var langue = valeur(form, 'langue');
    var canaux = canauxChoisis(form);
    var ids = {};
    canaux.forEach(function (canal) {
      var id = $('[data-cm-model="' + canal + '"]') && $('[data-cm-model="' + canal + '"]').value;
      ids[canal] = id;
    });
    var parts = apercuMessageDepuisModeles(canaux, modeles, ids, langue);
    vider(sortie);
    if (!parts.length) {
      sortie.hidden = true;
      return;
    }
    parts.forEach(function (p) {
      var bloc = creer('div', 'gs-campagnes__message');
      bloc.appendChild(creer('strong', '', (p.canal === 'email' ? 'E-mail' : p.canal === 'whatsapp' ? 'WhatsApp' : 'Push') + ' — ' + p.titre));
      bloc.appendChild(creer('p', '', p.message));
      sortie.appendChild(bloc);
    });
    sortie.hidden = false;
  }
  function chargerCampagne(id) {
    campagneActive = campagnes.filter(function (c) { return String(c.id) === String(id); })[0] || null;
    if (!campagneActive) return;
    var f = $('[data-cm-campaign-form]');
    f.elements.namedItem('id').value = String(campagneActive.id);
    f.elements.namedItem('nom').value = campagneActive.nom || '';
    f.elements.namedItem('description').value = campagneActive.description || '';
    f.elements.namedItem('objectif').value = campagneActive.objectif || '';
    f.elements.namedItem('langue').value = campagneActive.langue || '';
    $$('input[name="canaux"]', f).forEach(function (n) { n.checked = (campagneActive.canaux || []).indexOf(n.value) >= 0; });
    ['email', 'whatsapp', 'push'].forEach(function (canal) {
      var modele = (campagneActive.modeles || []).filter(function (m) { return m.canal === canal; })[0];
      if (modele) {
        chargerModeles(canal).then(function () { $('[data-cm-model="' + canal + '"]').value = String(modele.id); afficherApercuModele(); });
      } else {
        $('[data-cm-model="' + canal + '"]').value = '';
      }
    });
    f.elements.namedItem('segment').value = campagneActive.segment_id ? String(campagneActive.segment_id) : '';
    f.elements.namedItem('segment_nom').value = '';
    chargerCriteres(campagneActive.criteres_audience, f);
    f.elements.namedItem('budget_prevu').value = campagneActive.budget_prevu_usd == null ? '' : campagneActive.budget_prevu_usd;
    f.elements.namedItem('plafond').value = campagneActive.plafond_depenses_usd == null ? '' : campagneActive.plafond_depenses_usd;
    f.elements.namedItem('volume_cible').value = campagneActive.volume_cible == null ? '' : campagneActive.volume_cible;
    f.elements.namedItem('cout_estime').value = campagneActive.cout_estime_usd == null ? '' : campagneActive.cout_estime_usd;
    var quotas = campagneActive.quotas_par_canal || {};
    ['email', 'whatsapp', 'push'].forEach(function (canal) {
      f.elements.namedItem('quota_' + canal).value = quotas[canal] == null ? '' : quotas[canal];
    });
    f.elements.namedItem('planifie_local').value = campagneActive.planifie_local ? String(campagneActive.planifie_local).replace(' ', 'T').slice(0, 16) : '';
    f.elements.namedItem('fuseau').value = campagneActive.fuseau_horaire || '';
    editionModifiee = false;
    texte($('[data-cm-form-title]'), 'Révision ' + campagneActive.revision + ' · ' + statutCampagne(campagneActive.etat));
    $('[data-cm-actions]').hidden = false;
    afficherApercuModele();
    if (permission('communications.campaigns.manage')) $('[data-cm-campaign-form]').hidden = false;
  }
  function viderFormulaire() {
    campagneActive = null;
    editionModifiee = true;
    var f = $('[data-cm-campaign-form]');
    f.reset();
    f.elements.namedItem('id').value = '';
    texte($('[data-cm-form-title]'), 'Créer une campagne');
    $('[data-cm-actions]').hidden = true;
    $('[data-cm-preview-output]').hidden = true;
    vider($('[data-cm-preview-output]'));
    vider($('[data-cm-journal-output]'));
    $('[data-cm-journal-output]').hidden = true;
    actualiserCanaux();
    afficherApercuModele();
    if (permission('communications.campaigns.manage')) f.hidden = false;
  }
  function afficherApercu(res) {
    var zone = $('[data-cm-preview-output]');
    vider(zone);
    zone.appendChild(creer('h4', '', 'Prévisualisation agrégée — aucun contact n’est affiché'));
    zone.appendChild(creer('p', '', 'Clients correspondant au segment : ' + String(res.total_audience == null ? 'Non mesurable' : res.total_audience)));
    (res.canaux || []).forEach(function (c) {
      var bloc = creer('section', 'gs-campagnes__canal');
      bloc.appendChild(creer('h5', '', formaterCanaux([c.canal])));
      bloc.appendChild(creer('p', '', 'Éligibles : ' + String(c.eligibles) + ' · Exclus : ' + String(c.exclus)));
      var motifs = c.motifs_exclusion || {};
      var liste = document.createElement('ul');
      Object.keys(motifs).sort().forEach(function (motif) {
        liste.appendChild(creer('li', '', motif + ' : ' + String(motifs[motif])));
      });
      if (liste.childNodes.length) bloc.appendChild(liste);
      zone.appendChild(bloc);
    });
    var alertes = Array.isArray(res.alertes_limites) ? res.alertes_limites : [];
    if (alertes.length) {
      zone.appendChild(creer('h4', '', 'Alertes de limites'));
      alertes.forEach(function (alerte) {
        var ligne = document.createElement('p');
        if (alerte.type === 'quota_depasse') {
          ligne.appendChild(creer('strong', '', 'Quota dépassé'));
          ligne.appendChild(document.createTextNode(' — ' + formaterCanaux([alerte.canal]) +
            ' : ' + String(alerte.eligibles) + ' / ' + String(alerte.quota)));
        } else if (alerte.type === 'budget_prevu_depasse') {
          ligne.textContent = 'Coût estimé supérieur au budget prévu.';
        } else if (alerte.type === 'plafond_depasse') {
          ligne.textContent = 'Coût estimé supérieur au plafond de dépenses.';
        }
        if (ligne.textContent) zone.appendChild(ligne);
      });
    }
    zone.appendChild(creer('p', '', res.limites_configurees ? 'Limites configurées.' : 'Budget et quotas : non configurés. Aucune transmission ne peut être préparée.'));
    zone.appendChild(creer('p', '', 'Coût réel : non disponible.'));
    zone.hidden = false;
  }
  function afficherJournal(res) {
    var zone = $('[data-cm-journal-output]');
    vider(zone);
    zone.appendChild(creer('h4', '', 'Journal de la campagne'));
    (res.lignes || []).forEach(function (ligne) {
      var element = creer('p', '', dateAffichee(ligne.cree_le) + ' · ' + String(ligne.action || 'Action consignée'));
      zone.appendChild(element);
      if (ligne.motif_refus) zone.appendChild(creer('p', 'gs-campagnes__motif', 'Motif de refus : ' + ligne.motif_refus));
    });
    if (!res.lignes || !res.lignes.length) zone.appendChild(creer('p', '', 'Aucune entrée d’audit.'));
    zone.hidden = false;
  }
  function quotasDepuisForm(formulaire, canaux) {
    var q = {};
    canaux.forEach(function (canal) {
      var s = valeur(formulaire, 'quota_' + canal);
      if (s !== '') q[canal] = Number(s);
    });
    return Object.keys(q).length ? q : null;
  }
  function enregistrerCampagne(e) {
    e.preventDefault();
    var f = e.currentTarget;
    var canaux = canauxChoisis(f);
    var criteres = criteresDepuisForm(f);
    var associes = modelesDepuisForm(f, canaux);
    if (!criteres) { afficherErreur({ code: 'COMMUNICATION_SEGMENT_CRITERIA_INVALID' }); return; }
    if (!canaux.length || !associes) { afficherErreur({ code: 'COMMUNICATION_CAMPAIGN_MODEL_CHANNEL_MISMATCH' }); return; }
    var segmentId = valeur(f, 'segment');
    var data = {
      id: valeur(f, 'id') || null,
      nom: valeur(f, 'nom'), description: valeur(f, 'description'), objectif: valeur(f, 'objectif'),
      canaux: canaux, langue: valeur(f, 'langue'), segmentId: segmentId || null,
      criteres: criteres, modeles: associes,
      budgetPrevuUsd: valeur(f, 'budget_prevu'), plafondDepensesUsd: valeur(f, 'plafond'),
      volumeCible: valeur(f, 'volume_cible'), coutEstimeUsd: valeur(f, 'cout_estime'),
      quotasParCanal: quotasDepuisForm(f, canaux), planifieLocal: valeur(f, 'planifie_local') || null,
      fuseauHoraire: valeur(f, 'fuseau') || null
    };
    if (data.budgetPrevuUsd !== '' && Number(data.budgetPrevuUsd) < 0 ||
        data.plafondDepensesUsd !== '' && Number(data.plafondDepensesUsd) < 0 ||
        data.volumeCible !== '' && Number(data.volumeCible) < 1 ||
        data.coutEstimeUsd !== '' && Number(data.coutEstimeUsd) < 0) {
      afficherErreur({ code: 'COMMUNICATION_CAMPAIGN_INPUT_INVALID' }); return;
    }
    executer(function () { return apiAdmin().communicationCampagneEnregistrer(data); }, function (res) {
      editionModifiee = false;
      statut('Révision enregistrée en brouillon. Une nouvelle approbation sera requise.');
      rafraichir().then(function () { chargerCampagne(res.id); });
    });
  }
  function enregistrerSegment() {
    var f = $('[data-cm-campaign-form]');
    var criteres = criteresDepuisForm(f);
    var nom = valeur(f, 'segment_nom');
    if (!criteres || !nom) { afficherErreur({ code: 'COMMUNICATION_SEGMENT_CRITERIA_INVALID' }); return; }
    executer(function () { return apiAdmin().communicationCampagneSegmentEnregistrer({
      nom: nom, description: '', criteres: criteres
    }); }, function (res) {
      statut('Segment enregistré.');
      chargerSegments().then(function () { f.elements.namedItem('segment').value = String(res.id); });
    });
  }
  function enregistrerModele(e) {
    e.preventDefault();
    var f = e.currentTarget;
    var traductions = {};
    ['fr', 'en', 'es', 'ht'].forEach(function (langue) {
      traductions[langue] = {
        titre: valeur(f, 'titre_' + langue),
        message: String(f.elements.namedItem('message_' + langue).value || '').trim()
      };
    });
    executer(function () { return apiAdmin().communicationCampagneModeleVersion({
      cle: valeur(f, 'cle'), canal: valeur(f, 'canal'), traductions: traductions
    }); }, function (res) {
      f.reset();
      modeles[res.canal] = [];
      chargerModeles(res.canal);
      statut('Nouvelle version de modèle enregistrée : v' + String(res.version) + '.');
    });
  }
  function rafraichir() {
    return Promise.all([chargerListe(), chargerSegments()]);
  }
  function actionCampagne(nom) {
    if (!campagneActive) { afficherErreur({ code: 'COMMUNICATION_CAMPAIGN_NOT_FOUND' }); return; }
    if (editionModifiee && ['submit', 'approve', 'schedule', 'preview'].indexOf(nom) >= 0) {
      statut('Enregistrez la révision avant de prévisualiser, soumettre, approuver ou planifier.');
      return;
    }
    var api = apiAdmin();
    var id = campagneActive.id;
    var requete;
    if (nom === 'submit') requete = api.communicationCampagneSoumettre(id);
    else if (nom === 'approve') requete = api.communicationCampagneApprouver(id);
    else if (nom === 'reject') {
      var motif = window.prompt('Motif du refus (obligatoire) :');
      if (motif == null) return;
      requete = api.communicationCampagneRefuser(id, motif);
    } else if (nom === 'schedule') requete = api.communicationCampagnePlanifier(id);
    else if (nom === 'cancel') {
      if (!window.confirm('Annuler cette campagne ?')) return;
      requete = api.communicationCampagneAnnuler(id);
    } else if (nom === 'duplicate') requete = api.communicationCampagneDupliquer(id);
    else if (nom === 'journal') {
      executer(function () { return api.communicationCampagneJournal(id, 100); }, afficherJournal);
      return;
    }
    executer(function () { return requete; }, function (res) {
      statut(nom === 'schedule' ? 'Planification enregistrée. Aucun message ne sera envoyé pendant C6.' : 'Action enregistrée.');
      rafraichir().then(function () {
        if (nom === 'duplicate' && res && res.id) chargerCampagne(res.id);
        else if (campagnes.some(function (c) { return String(c.id) === String(id); })) chargerCampagne(id);
        else viderFormulaire();
      });
    });
  }
  function changementSegment(e) {
    var select = e.target;
    var segment = segments.filter(function (s) { return String(s.id) === select.value; })[0];
    if (segment) chargerCriteres(segment.criteres, $('[data-cm-campaign-form]'));
  }
  function charger() {
    if (chargement) return;
    chargement = true;
    assurerPermissions().then(function () {
      return rafraichir();
    }).then(function () {
      var formulaire = $('[data-cm-campaign-form]');
      var formulaireModele = $('[data-cm-model-form]');
      if (permission('communications.campaigns.manage')) {
        formulaire.hidden = false;
        formulaireModele.hidden = false;
      }
      chargement = false;
    }).catch(function () {
      chargement = false;
      afficherErreur({ code: 'reseau' });
    });
  }
  function init() {
    $('[data-cm-refresh]').addEventListener('click', charger);
    $('[data-cm-new]').addEventListener('click', viderFormulaire);
    $('[data-cm-campaign-form]').addEventListener('submit', enregistrerCampagne);
    $('[data-cm-model-form]').addEventListener('submit', enregistrerModele);
    $('[data-cm-save-segment]').addEventListener('click', enregistrerSegment);
    $('[data-cm-preview]').addEventListener('click', function () {
      if (!campagneActive) { afficherErreur({ code: 'COMMUNICATION_CAMPAIGN_NOT_FOUND' }); return; }
      if (editionModifiee) { statut('Enregistrez la révision avant de prévisualiser son audience.'); return; }
      executer(function () { return apiAdmin().communicationCampagneApercu(campagneActive.id); }, afficherApercu);
    });
    $$('input[name="canaux"]').forEach(function (n) { n.addEventListener('change', actualiserCanaux); });
    $('[name="langue"]').addEventListener('change', afficherApercuModele);
    ['email', 'whatsapp', 'push'].forEach(function (canal) {
      $('[data-cm-model="' + canal + '"]').addEventListener('change', afficherApercuModele);
    });
    $('[name="segment"]').addEventListener('change', changementSegment);
    $('[data-cm-campaign-form]').addEventListener('input', function (e) {
      if (e.target.name !== 'segment_nom') editionModifiee = true;
    });
    $('[data-cm-campaign-form]').addEventListener('change', function (e) {
      if (e.target.name !== 'segment') editionModifiee = true;
      if (['mode', 'pays', 'langue_client', 'inscription_jours', 'inscription_operateur',
           'a_des_colis', 'a_des_prealertes', 'activite_jours'].indexOf(e.target.name) >= 0) {
        var selectSegment = $('[name="segment"]');
        if (selectSegment.value) selectSegment.value = '';
      }
    });
    $$('[data-cm-actions] [data-cm-submit], [data-cm-actions] [data-cm-approve], [data-cm-actions] [data-cm-reject], [data-cm-actions] [data-cm-schedule], [data-cm-actions] [data-cm-cancel], [data-cm-actions] [data-cm-duplicate], [data-cm-actions] [data-cm-journal]')
      .forEach(function (b) { b.addEventListener('click', function () {
        var attribut = ['submit', 'approve', 'reject', 'schedule', 'cancel', 'duplicate', 'journal'];
        var nom = attribut.filter(function (n) { return b.hasAttribute('data-cm-' + n); })[0];
        if (nom) actionCampagne(nom);
      }); });
    $('[data-cm-campaign-rows]').addEventListener('click', function (e) {
      var b = e.target.closest && e.target.closest('[data-cm-select-id]');
      if (b) chargerCampagne(b.getAttribute('data-cm-select-id'));
    });
    var tab = document.querySelector('[data-cc-tab="campaigns"]');
    if (tab) tab.addEventListener('click', charger);
    var vue = document.querySelector('[data-vue="communications"]');
    if (vue) vue.addEventListener('goship:vue', function () { if (!panneau.hidden) charger(); });
    actualiserCanaux();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})(window);
