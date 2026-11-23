/* ===========================================================================
   GoShip Express — interface opérationnelle du Communication Center.
   Les droits, filtres, aperçus et reprises sont revérifiés par les RPC serveur.
   Cette interface n'invente aucune donnée et ne relance jamais un envoi incertain.
   =========================================================================== */
(function (racine) {
  'use strict';

  var LANGUES = ['fr', 'en', 'es', 'ht'];
  var VARIABLES = ['numero', 'facture', 'montant'];
  var CANAUX = ['push', 'email', 'whatsapp', 'sms'];

  function entierSain(valeur) {
    var n;
    if (typeof valeur === 'number') n = valeur;
    else if (typeof valeur === 'string' && /^[0-9]+$/.test(valeur)) n = Number(valeur);
    else return null;
    return isFinite(n) && n >= 0 && n <= 9007199254740991 && Math.floor(n) === n ? n : null;
  }

  function dateSaine(valeur) {
    if (typeof valeur !== 'string' || !valeur) return null;
    var date = new Date(valeur);
    return isNaN(date.getTime()) ? null : date.toISOString();
  }

  function modeliserSante(sante) {
    sante = sante && typeof sante === 'object' ? sante : {};
    var evenements = sante.evenements && typeof sante.evenements === 'object' ? sante.evenements : {};
    var envois = sante.envois && typeof sante.envois === 'object' ? sante.envois : {};
    var arret = sante.arret && typeof sante.arret === 'object' ? sante.arret : {};
    var travailleur = sante.travailleur && typeof sante.travailleur === 'object' ? sante.travailleur : {};
    var execution = travailleur.derniere_execution && typeof travailleur.derniere_execution === 'object'
      ? travailleur.derniere_execution : null;
    var etatsArret = { actif: 'inactif', arret_demande: 'demande', arret_confirme: 'confirme' };
    var etatsExecution = { succeeded: 'termine', failed: 'echec', running: 'en-cours', starting: 'demarrage' };
    return {
      modeDemo: sante.mode === 'demo',
      mesures: {
        recus: entierSain(evenements.recus_conserves),
        attente: entierSain(evenements.a_traiter),
        enCours: evenements.en_cours_mesurable === true ? entierSain(evenements.en_cours) : null,
        enCoursMesurable: evenements.en_cours_mesurable === true,
        reussis: entierSain(evenements.traites_conserves),
        echec: entierSain(evenements.echec),
        echecPrioritaire: entierSain(evenements.echec_prioritaires),
        envoisDisponibles: envois.disponible === true,
        enAttente: envois.disponible === true ? entierSain(envois.en_attente) : null,
        enEnvoi: envois.disponible === true ? entierSain(envois.en_cours) : null,
        envoyes: envois.disponible === true ? entierSain(envois.envoyes) : null,
        livres: envois.disponible === true ? entierSain(envois.livres) : null,
        echecsEnvoi: envois.disponible === true ? entierSain(envois.echecs) : null,
        incertains: envois.disponible === true ? entierSain(envois.incertains) : null
      },
      arret: etatsArret[arret.etat] || 'inconnu',
      travailleur: travailleur.tables_disponibles === false ? 'indisponible'
        : travailleur.present !== true ? (travailleur.present === false ? 'non-configure' : 'indisponible')
          : travailleur.planifie_actif === true ? 'actif-planifie'
            : travailleur.planifie_actif === false ? 'inactif' : 'indisponible',
      derniereExecution: execution ? {
        statut: etatsExecution[execution.statut] || 'inconnu',
        demarreeLe: dateSaine(execution.demarree_le)
      } : null,
      derniereActivite: dateSaine(sante.activite && sante.activite.derniere_le),
      alertes: Array.isArray(sante.alertes) ? sante.alertes.filter(function (a) {
        return a && typeof a.code === 'string' && entierSain(a.compte) !== null && entierSain(a.compte) > 0;
      }) : []
    };
  }

  function validerModele(type, canaux, variables, traductions, whatsapp) {
    if (!type || !Array.isArray(canaux) || !canaux.length ||
        canaux.some(function (c, i) { return CANAUX.indexOf(c) < 0 || canaux.indexOf(c) !== i; })) return 'COMMUNICATION_TEMPLATE_INPUT_INVALID';
    if (!Array.isArray(variables) || variables.some(function (v, i) {
      return VARIABLES.indexOf(v) < 0 || variables.indexOf(v) !== i;
    })) return 'COMMUNICATION_TEMPLATE_INPUT_INVALID';
    if (!Array.isArray(traductions) || traductions.length !== 4) return 'COMMUNICATION_TEMPLATE_LANGUAGES_REQUIRED';
    var langues = traductions.map(function (t) { return t && t.langue; }).sort();
    if (langues.join(',') !== 'en,es,fr,ht') return 'COMMUNICATION_TEMPLATE_LANGUAGES_REQUIRED';
    for (var i = 0; i < traductions.length; i++) {
      var t = traductions[i];
      if (!t || !String(t.titre || '').trim() || String(t.titre).length > 300 ||
          !String(t.message || '').trim() || String(t.message).length > 3000 || /<[^>]*>/.test(t.titre + t.message)) {
        return 'COMMUNICATION_TEMPLATE_INPUT_INVALID';
      }
      var restant = String(t.titre) + String(t.message);
      VARIABLES.forEach(function (v) { restant = restant.split('{{' + v + '}}').join(''); });
      if (restant.indexOf('{{') >= 0 || restant.indexOf('}}') >= 0) return 'COMMUNICATION_TEMPLATE_VARIABLE_INVALID';
      var utilisees = VARIABLES.filter(function (v) { return (t.titre + t.message).indexOf('{{' + v + '}}') >= 0; });
      if (utilisees.join(',') !== VARIABLES.filter(function (v) { return variables.indexOf(v) >= 0; }).join(',')) {
        return 'COMMUNICATION_TEMPLATE_VARIABLES_MISMATCH';
      }
    }
    if (canaux.indexOf('whatsapp') >= 0 && !/^[a-z0-9_]{1,100}$/.test(String(whatsapp || ''))) {
      return 'COMMUNICATION_TEMPLATE_WHATSAPP_NAME_REQUIRED';
    }
    if (canaux.indexOf('whatsapp') < 0 && whatsapp) return 'COMMUNICATION_TEMPLATE_WHATSAPP_NAME_UNUSED';
    return null;
  }

  function normaliserFiltresHistorique(valeurs, page) {
    valeurs = valeurs || {};
    function date(valeur) {
      if (!valeur) return null;
      var d = new Date(valeur);
      return isNaN(d.getTime()) ? null : d.toISOString();
    }
    return {
      recherche: String(valeurs.recherche || '').trim(),
      canal: valeurs.canal || null,
      statut: valeurs.statut || null,
      type: valeurs.type || null,
      debut: date(valeurs.debut),
      fin: date(valeurs.fin),
      page: entierSain(page) || 0,
      parPage: 50
    };
  }

  racine.GoshipCommunications = {
    modeliserSante: modeliserSante,
    validerModele: validerModele,
    dateSaine: dateSaine,
    normaliserFiltresHistorique: normaliserFiltresHistorique,
    anciennete: function (valeur, maintenant) {
      var date = dateSaine(valeur);
      if (!date) return null;
      var minutes = Math.max(0, Math.floor(((maintenant == null ? Date.now() : maintenant) - Date.parse(date)) / 60000));
      var montant = minutes;
      var unite = 'minute';
      if (minutes >= 60 && minutes < 2880) { montant = Math.floor(minutes / 60); unite = 'hour'; }
      else if (minutes >= 2880) { montant = Math.floor(minutes / 1440); unite = 'day'; }
      try { return new Intl.RelativeTimeFormat(locale(), { numeric: 'auto', style: 'short' }).format(-montant, unite); }
      catch (e) { return date; }
    }
  };
  if (!racine.document || !racine.document.querySelector) return;

  var document = racine.document;
  var vue = document.querySelector('[data-vue="communications"]');
  if (!vue) return;

  var ongletActif = 'overview';
  var demandes = {};
  var permissions = [];
  var catalogueModeles = { types: [], modeles: [] };
  var historiqueCourant = { lignes: [], total: 0, page: 0 };

  function $(selecteur, cible) { return (cible || vue).querySelector(selecteur); }
  function $$(selecteur, cible) { return Array.prototype.slice.call((cible || vue).querySelectorAll(selecteur)); }
  function aPermission(nom) { return permissions.indexOf(nom) >= 0; }
  function texte(noeud, valeur) { if (noeud) noeud.textContent = valeur == null ? '' : String(valeur); }
  function vider(noeud) { if (!noeud) return; while (noeud.firstChild) noeud.removeChild(noeud.firstChild); }
  function element(nom, classe, contenu) {
    var e = document.createElement(nom);
    if (classe) e.className = classe;
    if (contenu !== undefined) e.textContent = contenu == null ? '' : String(contenu);
    return e;
  }
  function cellule(ligne, libelle, valeur) {
    var td = element('td', '', valeur == null || valeur === '' ? '—' : valeur);
    td.setAttribute('data-libelle', libelle);
    ligne.appendChild(td);
    return td;
  }
  function ligneVide(corps, colonnes, message) {
    var tr = element('tr');
    var td = element('td', '', message);
    td.colSpan = colonnes;
    tr.appendChild(td);
    corps.appendChild(tr);
  }
  function langue() {
    try {
      var l = racine.localStorage.getItem('gse-tableau-langue') || 'fr';
      return LANGUES.indexOf(l) >= 0 ? l : 'fr';
    } catch (e) { return 'fr'; }
  }
  function locale() { return { fr: 'fr-FR', en: 'en-US', es: 'es-DO', ht: 'ht' }[langue()] || 'fr-FR'; }
  function dateAffichee(valeur) {
    var d = dateSaine(valeur);
    return d ? new Date(d).toLocaleString(locale()) : '—';
  }
  function nombre(valeur) {
    var n = entierSain(valeur);
    return n === null ? 'Non mesurable' : n.toLocaleString(locale());
  }
  function afficherErreur(err, cible) {
    var code = err && err.code;
    var message = code === 'non-autorise' ? 'Accès refusé : votre rôle ne permet pas cette action.'
      : code === 'absent' ? 'Le service du Communication Center n’est pas installé dans cette base.'
        : code === 'reseau' ? 'Service indisponible. Vérifiez la connexion et réessayez.'
          : code === 'COMMUNICATION_EVENT_RETRY_NOT_SAFE' ? 'Aucune reprise sûre n’est autorisée pour cet événement.'
          : code === 'COMMUNICATION_TEMPLATE_VARIABLE_MISSING' ? 'Une variable requise manque dans cette notification réelle.'
            : code === 'COMMUNICATION_TEMPLATE_LANGUAGES_REQUIRED' ? 'Les quatre traductions sont requises.'
              : code === 'COMMUNICATION_TEMPLATE_VARIABLES_MISMATCH' ? 'Les mêmes variables doivent être présentes dans les quatre langues.'
                : code === 'COMMUNICATION_TEMPLATE_CHANNEL_INVALID' ? 'Ce canal n’est pas autorisé pour ce type de communication.'
                  : code === 'COMMUNICATION_NOTIFICATION_NOT_FOUND' ? 'La notification réelle sélectionnée est introuvable.'
                    : code === 'COMMUNICATION_NOTIFICATION_TYPE_MISMATCH' ? 'La notification réelle sélectionnée est d’un autre type.'
                    : code === 'COMMUNICATION_TEMPLATE_MARKUP_FORBIDDEN' ? 'Le modèle contient un balisage interdit.'
                      : code === 'COMMUNICATION_TEMPLATE_VARIABLE_INVALID' ? 'Le modèle contient une variable inconnue ou incomplète.'
                        : code === 'COMMUNICATION_TEMPLATE_WHATSAPP_NAME_UNUSED' ? 'Le nom du modèle WhatsApp n’est pas utilisé par le canal sélectionné.'
                          : code === 'COMMUNICATION_TEMPLATE_WHATSAPP_NAME_REQUIRED' ? 'Le nom du modèle WhatsApp est obligatoire pour ce canal.'
                            : code === 'COMMUNICATION_TEMPLATE_INPUT_INVALID' ? 'Les données du modèle sont invalides.'
                : 'Impossible de charger ou d’enregistrer ces données. Réessayez.';
    texte(cible || $('[data-cc-error]'), message);
    if (cible) cible.hidden = false;
    else $('[data-cc-error]').hidden = false;
  }
  function statutGlobal(message) {
    texte($('[data-cc-status]'), message);
  }
  function apiAdmin() { return racine.GoshipAPI && racine.GoshipAPI.admin; }

  function valeurMetric(modele, cle) {
    var m = modele.mesures;
    var valeurs = {
      events_received: m.recus, events_waiting: m.attente, events_processing: m.enCours,
      events_done: m.reussis, events_failed: m.echec,
      sends_waiting: m.enAttente, sends_sent: m.envoyes, sends_delivered: m.livres,
      sends_failed: m.echecsEnvoi, sends_uncertain: m.incertains
    };
    if (cle.indexOf('sends_') === 0 && !m.envoisDisponibles) return null;
    return valeurs[cle] == null ? null : valeurs[cle];
  }

  function afficherSante(sante) {
    var modele = modeliserSante(sante);
    var conteneur = $('[data-cc-metrics]');
    var vide = $('[data-cc-overview-empty]');
    $('[data-cc-error]').hidden = true;
    if (modele.modeDemo) {
      conteneur.hidden = true;
      vide.hidden = false;
      texte(vide, 'Mode démo : aucune donnée de communication n’est simulée.');
      statutGlobal('Aucune donnée réelle disponible en mode démo.');
      return;
    }
    var mesurable = false;
    $$('[data-cc-metric]').forEach(function (noeud) {
      var valeur = valeurMetric(modele, noeud.getAttribute('data-cc-metric'));
      texte(noeud, nombre(valeur));
      if (valeur !== null) mesurable = true;
    });
    conteneur.hidden = !mesurable;
    vide.hidden = mesurable;
    if (!mesurable) texte(vide, 'Aucune donnée mesurable n’est disponible.');

    var arrets = { inactif: 'Arrêt inactif', demande: 'Arrêt demandé', confirme: 'Arrêt confirmé', inconnu: 'État inconnu' };
    var travailleurs = { indisponible: 'État indisponible', 'non-configure': 'Non configuré', 'actif-planifie': 'Actif (planifié)', inactif: 'Inactif' };
    texte($('[data-cc-kill-switch]'), arrets[modele.arret]);
    texte($('[data-cc-worker]'), travailleurs[modele.travailleur]);
    var activite = modele.derniereActivite;
    if (!activite && modele.derniereExecution) activite = modele.derniereExecution.demarreeLe;
    texte($('[data-cc-activity]'), activite ? new Date(activite).toLocaleString(locale()) : 'Non mesurable');
    var alertes = $('[data-cc-alerts]');
    vider(alertes);
    var libellesAlertes = {
      EVENEMENTS_PRIORITAIRES_EN_ECHEC: 'Événements prioritaires en échec',
      TRANSMISSIONS_INCERTAINES: 'Transmissions incertaines à réconcilier'
    };
    modele.alertes.forEach(function (a) {
      if (!libellesAlertes[a.code]) return;
      var bloc = element('p', 'gs-communications__alert');
      var libelle = element('strong', '', libellesAlertes[a.code] + ' : ');
      bloc.appendChild(libelle);
      bloc.appendChild(document.createTextNode(nombre(a.compte)));
      alertes.appendChild(bloc);
    });
    if (!modele.alertes.length) texte(alertes, 'Aucune alerte nécessitant une intervention.');
    statutGlobal('Données actualisées.');
  }

  function changerOnglet(nom, focaliser) {
    var onglets = $$('[data-cc-tab]');
    if (!onglets.some(function (b) { return b.getAttribute('data-cc-tab') === nom && !b.hidden; })) return;
    ongletActif = nom;
    onglets.forEach(function (b) {
      var choisi = b.getAttribute('data-cc-tab') === nom;
      b.setAttribute('aria-selected', choisi ? 'true' : 'false');
      b.tabIndex = choisi ? 0 : -1;
      if (choisi && focaliser) b.focus();
    });
    $$('[data-cc-pane]').forEach(function (p) { p.hidden = p.getAttribute('data-cc-pane') !== nom; });
    chargerOnglet(nom, false);
  }

  function chargerOnglet(nom, forcer) {
    if (!forcer && demandes[nom] && demandes[nom].charge) return;
    var api = apiAdmin();
    if (!api) { afficherErreur({ code: 'absent' }); return; }
    var ticket = (demandes[nom] ? demandes[nom].ticket : 0) + 1;
    demandes[nom] = { ticket: ticket, charge: false };
    statutGlobal('Chargement…');
    if (nom === 'overview') chargerVueGenerale(api, ticket);
    else if (nom === 'history') chargerHistorique(api, ticket, false);
    else if (nom === 'templates') chargerModeles(api, ticket);
    else if (nom === 'consents') chargerConsentements(api, ticket);
    else if (nom === 'queue') chargerFile(api, ticket);
  }

  function terminer(nom, ticket, succes) {
    if (!demandes[nom] || demandes[nom].ticket !== ticket) return;
    demandes[nom].charge = !!succes;
    if (!succes) statutGlobal('Service indisponible.');
  }

  function chargerVueGenerale(api, ticket) {
    var lire = api.communicationC5Sante || api.santeCommunications;
    if (typeof lire !== 'function') { afficherErreur({ code: 'absent' }); terminer('overview', ticket, false); return; }
    lire.call(api).then(function (sante) {
      if (!demandes.overview || demandes.overview.ticket !== ticket) return;
      if (!sante || typeof sante !== 'object') throw new Error('Réponse de santé invalide.');
      afficherSante(sante);
      terminer('overview', ticket, true);
    }).catch(function (err) {
      if (demandes.overview && demandes.overview.ticket === ticket) {
        $('[data-cc-metrics]').hidden = true;
        afficherErreur(err);
        terminer('overview', ticket, false);
      }
    });
  }

  function filtresHistorique(page) {
    var form = $('[data-cc-history-form]');
    function valeur(nom) { var el = form.elements[nom]; return el ? String(el.value || '').trim() : ''; }
    return normaliserFiltresHistorique({ recherche: valeur('recherche'), canal: valeur('canal'),
      statut: valeur('statut'), type: valeur('type'), debut: valeur('debut'), fin: valeur('fin') }, page);
  }

  function chargerHistorique(api, ticket, pageChange) {
    if (typeof api.communicationHistorique !== 'function') { afficherErreur({ code: 'absent' }, $('[data-cc-history-status]')); terminer('history', ticket, false); return; }
    var filtres = filtresHistorique(pageChange ? historiqueCourant.page : 0);
    var etat = $('[data-cc-history-status]');
    texte(etat, 'Chargement…');
    api.communicationHistorique(filtres).then(function (resultat) {
      if (!demandes.history || demandes.history.ticket !== ticket) return;
      resultat = resultat && typeof resultat === 'object' ? resultat : {};
      historiqueCourant = { lignes: Array.isArray(resultat.lignes) ? resultat.lignes : [],
        total: entierSain(resultat.total) || 0, page: entierSain(resultat.page) || 0 };
      afficherHistorique(historiqueCourant);
      texte(etat, historiqueCourant.total ? 'Données actualisées.' : 'Aucune communication pour ces filtres.');
      terminer('history', ticket, true);
    }).catch(function (err) {
      if (demandes.history && demandes.history.ticket === ticket) {
        vider($('[data-cc-history-rows]')); afficherErreur(err, etat); terminer('history', ticket, false);
      }
    });
  }

  function afficherHistorique(resultat) {
    var corps = $('[data-cc-history-rows]');
    vider(corps);
    if (!resultat.lignes.length) ligneVide(corps, 8, 'Aucune donnée.');
    resultat.lignes.forEach(function (r) {
      var tr = element('tr');
      cellule(tr, 'Date', dateAffichee(r.prepare_le));
      cellule(tr, 'Canal', libelleCanal(r.canal));
      cellule(tr, 'Statut', libelleStatut(r.statut));
      cellule(tr, 'Type', libelleType(r.type));
      cellule(tr, 'Client', r.client_reference);
      cellule(tr, 'Colis / facture', [r.colis_reference, r.facture_reference].filter(Boolean).join(' · '));
      cellule(tr, 'Modèle', r.modele_version ? 'v' + r.modele_version + ' · ' + (r.modele_langue || '') : null);
      var td = cellule(tr, 'Transitions', '');
      var transitions = element('span', 'gs-communications__transitions');
      (Array.isArray(r.transitions) ? r.transitions : []).forEach(function (x) {
        transitions.appendChild(element('span', '', libelleStatut(x.statut) + ' · ' + dateAffichee(x.cree_le)));
      });
      if (!transitions.childNodes.length) transitions.appendChild(element('span', '', 'Aucun changement enregistré.'));
      td.appendChild(transitions);
      corps.appendChild(tr);
    });
    var debut = resultat.total ? resultat.page * 50 + 1 : 0;
    var fin = Math.min(resultat.total, resultat.page * 50 + resultat.lignes.length);
    texte($('[data-cc-history-page]'), debut + '–' + fin + ' sur ' + resultat.total);
    $('[data-cc-history-prev]').disabled = resultat.page <= 0;
    $('[data-cc-history-next]').disabled = fin >= resultat.total;
  }

  function libelleCanal(canal) {
    return { push: 'Push', email: 'E-mail', whatsapp: 'WhatsApp', sms: 'SMS' }[canal] || canal || '—';
  }
  function libelleSource(source) {
    return { compte_web: 'Compte Web', application: 'Application', confirmation_whatsapp: 'Confirmation WhatsApp',
      changement_contact: 'Changement de contact', whatsapp_stop: 'Arrêt WhatsApp' }[source] || source || '—';
  }
  function libelleFournisseur(fournisseur) {
    return { meta: 'Meta', brevo: 'Brevo', resend: 'Resend', expo: 'Expo' }[fournisseur] || fournisseur || '—';
  }
  function libelleEvenement(type) {
    return { inbound: 'Message entrant', complaint: 'Plainte de livraison', unsubscribe: 'Désinscription',
      soft_bounce: 'Rejet temporaire', delivered: 'Livré', failed: 'Échec', sent: 'Envoyé', read: 'Lu',
      blocked: 'Bloqué', hard_bounce: 'Rejet définitif' }[type] || type || '—';
  }
  function libelleActionConsentement(action) {
    return { demande: 'Demande', confirme: 'Confirmé', refus: 'Refus', retrait: 'Retrait', expire: 'Expiré',
      bloque: 'Bloqué', annule: 'Annulé', invalide: 'Invalidé' }[action] || action || '—';
  }
  function libelleResultat(resultat) {
    return { STOP_APPLIQUE: 'Retrait STOP appliqué', ENTRANT_SANS_ACTION_AUTOMATIQUE: 'Message entrant sans action automatique',
      RETOUR_INFORMATIF: 'Retour fournisseur informatif', CORRELATION_REQUISE: 'Rapprochement requis',
      A_REVOIR: 'À examiner', LIMITE_TENTATIVES: 'Limite de tentatives atteinte', REESSAI: 'Nouvel essai planifié',
      REPRISE_ADMIN: 'Reprise administrative demandée', TRAITE_SANS_EFFET: 'Traité sans autre effet' }[resultat] || resultat || '—';
  }

  function libelleStatut(statut) {
    var valeurs = {
      attente: 'En attente', envoi: 'En cours', envoye: 'Envoyé', livre: 'Livré',
      echec: 'En échec', annule: 'Annulé', incertain: 'Incertain', a_traiter: 'En attente',
      traite: 'Traité', reessai: 'Nouvel essai', arret_demande: 'Arrêt demandé',
      arret_confirme: 'Arrêt confirmé', actif: 'Actif'
    };
    return valeurs[statut] || statut || 'État inconnu';
  }

  function libelleType(type) {
    var t = catalogueModeles.types.filter(function (x) { return x.type === type; })[0];
    return t && t.libelles && t.libelles[langue()] ? t.libelles[langue()] : (type || '—');
  }

  function ajouterOption(select, valeur, libelle) {
    var option = element('option', '', libelle);
    option.value = valeur;
    select.appendChild(option);
    return option;
  }

  function afficherTypes() {
    var filtre = $('[data-cc-type-filter]');
    var select = $('[data-cc-template-type]');
    var typeActuel = select.value;
    while (filtre.options.length > 1) filtre.remove(1);
    vider(select);
    catalogueModeles.types.forEach(function (t) {
      var lib = t.libelles && t.libelles[langue()] || t.type;
      ajouterOption(filtre, t.type, lib);
      ajouterOption(select, t.type, lib);
    });
    if (catalogueModeles.types.some(function (t) { return t.type === typeActuel; })) select.value = typeActuel;
    if (!select.value && select.options.length) select.selectedIndex = 0;
  }

  function lignesDerniereVersion(type) {
    var lignes = catalogueModeles.modeles.filter(function (m) { return m.type === type; });
    var version = lignes.reduce(function (max, m) { return Math.max(max, entierSain(m.version) || 0); }, 0);
    return lignes.filter(function (m) { return m.version === version; });
  }

  function prechargerModele() {
    var form = $('[data-cc-template-form]');
    if (!form || !aPermission('communications.templates.manage')) return;
    var type = $('[data-cc-template-type]').value;
    var typeRegle = catalogueModeles.types.filter(function (t) { return t.type === type; })[0];
    var lignes = lignesDerniereVersion(type);
    var parLangue = {};
    lignes.forEach(function (m) { parLangue[m.langue] = m; });
    LANGUES.forEach(function (l) {
      var m = parLangue[l] || {};
      form.elements['titre_' + l].value = m.titre || '';
      form.elements['message_' + l].value = m.message || '';
    });
    var canauxCourants = lignes.length ? lignes[0].canaux || [] : [];
    $$('input[name="canaux"]', form).forEach(function (input) {
      input.disabled = !typeRegle || typeRegle.canaux_autorises.indexOf(input.value) < 0;
      input.checked = !input.disabled && canauxCourants.indexOf(input.value) >= 0;
    });
    var variables = lignes.length ? lignes[0].variables_requises || [] : [];
    $$('input[name="variables"]', form).forEach(function (input) { input.checked = variables.indexOf(input.value) >= 0; });
    form.elements.modele_whatsapp.value = lignes.length ? lignes[0].modele_whatsapp || '' : '';
    afficherChampWhatsApp();
    $('[data-cc-preview-output]').hidden = true;
  }

  function afficherChampWhatsApp() {
    var choisi = $$('input[name="canaux"]', $('[data-cc-template-form]')).some(function (i) { return i.checked && i.value === 'whatsapp'; });
    $('[data-cc-whatsapp-field]').hidden = !choisi;
    $('[data-cc-template-form]').elements.modele_whatsapp.required = choisi;
  }

  function afficherModeles() {
    var corps = $('[data-cc-template-rows]');
    vider(corps);
    if (!catalogueModeles.modeles.length) ligneVide(corps, 5, 'Aucun modèle transactionnel disponible.');
    catalogueModeles.modeles.forEach(function (m) {
      var tr = element('tr');
      cellule(tr, 'Type', libelleType(m.type));
      cellule(tr, 'Version', 'v' + m.version);
      cellule(tr, 'Langue', m.langue);
      cellule(tr, 'Canaux', (m.canaux || []).join(', '));
      cellule(tr, 'Titre', m.titre);
      corps.appendChild(tr);
    });
  }

  function remplirNotificationsApercu(lignes) {
    var select = $('[data-cc-preview-source]');
    while (select.options.length > 1) select.remove(1);
    var vus = {};
    lignes.forEach(function (r) {
      var id = entierSain(r.notification_id);
      if (!id || vus[id]) return;
      vus[id] = true;
      var option = ajouterOption(select, id, libelleType(r.type) + ' · ' + dateAffichee(r.prepare_le));
      option.setAttribute('data-type', r.type || '');
    });
  }

  function chargerModeles(api, ticket) {
    if (typeof api.communicationModeles !== 'function') { afficherErreur({ code: 'absent' }, $('[data-cc-template-status]')); terminer('templates', ticket, false); return; }
    Promise.all([
      api.communicationModeles(),
      typeof api.communicationHistorique === 'function'
        ? api.communicationHistorique({ page: 0, parPage: 100 })
        : Promise.resolve({ lignes: [] })
    ]).then(function (resultats) {
      if (!demandes.templates || demandes.templates.ticket !== ticket) return;
      var m = resultats[0] || {};
      catalogueModeles = { types: Array.isArray(m.types) ? m.types : [], modeles: Array.isArray(m.modeles) ? m.modeles : [] };
      afficherTypes(); afficherModeles();
      remplirNotificationsApercu(resultats[1] && Array.isArray(resultats[1].lignes) ? resultats[1].lignes : []);
      $('[data-cc-template-form]').hidden = !aPermission('communications.templates.manage');
      $('[data-cc-template-readonly]').hidden = aPermission('communications.templates.manage');
      prechargerModele();
      texte($('[data-cc-template-status]'), 'Données actualisées.');
      terminer('templates', ticket, true);
    }).catch(function (err) {
      if (demandes.templates && demandes.templates.ticket === ticket) {
        afficherErreur(err, $('[data-cc-template-status]')); terminer('templates', ticket, false);
      }
    });
  }

  function creerApercu() {
    var form = $('[data-cc-template-form]');
    var type = form.elements.type.value;
    var source = form.elements.notification;
    var option = source.options[source.selectedIndex];
    var lang = form.elements.langue ? form.elements.langue.value : langue();
    var titre = form.elements['titre_' + lang].value;
    var message = form.elements['message_' + lang].value;
    var resultat = validerModele(type,
      $$('input[name="canaux"]', form).filter(function (i) { return i.checked; }).map(function (i) { return i.value; }),
      $$('input[name="variables"]', form).filter(function (i) { return i.checked; }).map(function (i) { return i.value; }),
      LANGUES.map(function (l) { return { langue: l, titre: form.elements['titre_' + l].value, message: form.elements['message_' + l].value }; }),
      form.elements.modele_whatsapp.value);
    var typeRegle = catalogueModeles.types.filter(function (t) { return t.type === type; })[0];
    var canauxSelectionnes = $$('input[name="canaux"]', form).filter(function (i) { return i.checked; }).map(function (i) { return i.value; });
    if (!typeRegle || canauxSelectionnes.some(function (c) { return typeRegle.canaux_autorises.indexOf(c) < 0; })) {
      resultat = 'COMMUNICATION_TEMPLATE_CHANNEL_INVALID';
    }
    if (resultat) { afficherErreur({ code: resultat }, $('[data-cc-template-status]')); return; }
    if (!source.value || !option || option.getAttribute('data-type') !== type) {
      afficherErreur({ code: 'COMMUNICATION_NOTIFICATION_NOT_FOUND' }, $('[data-cc-template-status]')); return;
    }
    var api = apiAdmin();
    $('[data-cc-preview]').disabled = true;
    api.communicationPrevisualiser({ notification: source.value, type: type, langue: lang, titre: titre, message: message })
      .then(function (r) {
        texte($('[data-cc-preview-title]'), r && r.titre);
        texte($('[data-cc-preview-message]'), r && r.message);
        $('[data-cc-preview-output]').hidden = false;
        $('[data-cc-template-status]').hidden = true;
      }).catch(function (err) { afficherErreur(err, $('[data-cc-template-status]')); })
      .then(function () { $('[data-cc-preview]').disabled = false; });
  }

  function enregistrerNouvelleVersion(e) {
    e.preventDefault();
    var form = $('[data-cc-template-form]');
    var type = form.elements.type.value;
    var typeRegle = catalogueModeles.types.filter(function (t) { return t.type === type; })[0];
    var canaux = $$('input[name="canaux"]', form).filter(function (i) { return i.checked; }).map(function (i) { return i.value; });
    var variables = $$('input[name="variables"]', form).filter(function (i) { return i.checked; }).map(function (i) { return i.value; });
    var traductions = LANGUES.map(function (l) { return { langue: l, titre: form.elements['titre_' + l].value.trim(), message: form.elements['message_' + l].value.trim() }; });
    var erreur = validerModele(type, canaux, variables, traductions, form.elements.modele_whatsapp.value.trim());
    if (!typeRegle || canaux.some(function (c) { return typeRegle.canaux_autorises.indexOf(c) < 0; })) erreur = 'COMMUNICATION_TEMPLATE_CHANNEL_INVALID';
    if (erreur) { afficherErreur({ code: erreur }, $('[data-cc-template-status]')); return; }
    var bouton = form.querySelector('button[type="submit"]');
    bouton.disabled = true;
    apiAdmin().communicationNouvelleVersion({ type: type, canaux: canaux, variables: variables,
      modeleWhatsapp: form.elements.modele_whatsapp.value.trim() || null, traductions: traductions })
      .then(function (r) {
        texte($('[data-cc-template-status]'), 'Nouvelle version enregistrée');
        $('[data-cc-template-status]').hidden = false;
        delete demandes.templates;
        chargerOnglet('templates', true);
      }).catch(function (err) { afficherErreur(err, $('[data-cc-template-status]')); })
      .then(function () { bouton.disabled = false; });
  }

  function chargerConsentements(api, ticket) {
    var etat = $('[data-cc-consent-status]');
    if (!aPermission('communications.consents.view')) { afficherErreur({ code: 'non-autorise' }, etat); terminer('consents', ticket, false); return; }
    if (typeof api.communicationConsentements !== 'function') { afficherErreur({ code: 'absent' }, etat); terminer('consents', ticket, false); return; }
    texte(etat, 'Chargement…');
    api.communicationConsentements(200).then(function (resultat) {
      if (!demandes.consents || demandes.consents.ticket !== ticket) return;
      var lignes = resultat && Array.isArray(resultat.lignes) ? resultat.lignes : [];
      var corps = $('[data-cc-consent-rows]');
      vider(corps);
      if (!lignes.length) ligneVide(corps, 9, 'Aucun consentement enregistré.');
      lignes.forEach(function (c) {
        var tr = element('tr');
        cellule(tr, 'Client', c.client_reference);
        cellule(tr, 'Canal', libelleCanal(c.canal));
        cellule(tr, 'Statut', libelleStatut(c.etat));
        cellule(tr, 'Source', libelleSource(c.source));
        cellule(tr, 'Demandé', dateAffichee(c.demande_le));
        cellule(tr, 'Confirmé', dateAffichee(c.confirme_le));
        cellule(tr, 'Expiration', dateAffichee(c.expiration_le));
        cellule(tr, 'Retiré', dateAffichee(c.retire_le));
        var h = (Array.isArray(c.historique) ? c.historique : []).map(function (x) {
          return libelleActionConsentement(x.action) + ' · ' + libelleSource(x.source) + ' · ' + dateAffichee(x.cree_le);
        });
        var d = (Array.isArray(c.demandes) ? c.demandes : []).filter(function (x) { return x.etat === 'en_attente'; }).map(function (x) {
          return 'En attente · expiration ' + dateAffichee(x.expire_le) + ' · ' + nombre(x.tentatives) + ' tentative(s)';
        });
        cellule(tr, 'Historique', d.concat(h).join(' | ') || 'Aucun changement enregistré.');
        corps.appendChild(tr);
      });
      texte(etat, lignes.length ? 'Données actualisées.' : 'Aucune donnée.');
      terminer('consents', ticket, true);
    }).catch(function (err) {
      if (demandes.consents && demandes.consents.ticket === ticket) { afficherErreur(err, etat); terminer('consents', ticket, false); }
    });
  }

  function chargerFile(api, ticket) {
    var etat = $('[data-cc-queue-status]');
    if (typeof api.communicationFile !== 'function') { afficherErreur({ code: 'absent' }, etat); terminer('queue', ticket, false); return; }
    texte(etat, 'Chargement…');
    api.communicationFile(100).then(function (resultat) {
      if (!demandes.queue || demandes.queue.ticket !== ticket) return;
      resultat = resultat || {};
      afficherEvenements(Array.isArray(resultat.evenements) ? resultat.evenements : []);
      afficherEnvois(Array.isArray(resultat.envois) ? resultat.envois : []);
      texte(etat, 'Données actualisées.');
      terminer('queue', ticket, true);
    }).catch(function (err) {
      if (demandes.queue && demandes.queue.ticket === ticket) { afficherErreur(err, etat); terminer('queue', ticket, false); }
    });
  }

  function afficherEvenements(evenements) {
    var corps = $('[data-cc-event-rows]');
    vider(corps);
    if (!evenements.length) ligneVide(corps, 9, 'Aucun événement dans la file.');
    evenements.forEach(function (e) {
      var tr = element('tr');
      cellule(tr, 'Reçu', dateAffichee(e.recu_le));
      cellule(tr, 'Ancienneté', anciennete(e.recu_le) || 'Non mesurable');
      cellule(tr, 'Fournisseur', libelleFournisseur(e.fournisseur));
      cellule(tr, 'Type', libelleEvenement(e.type));
      cellule(tr, 'État', libelleStatut(e.etat));
      cellule(tr, 'Tentatives', nombre(e.tentatives));
      cellule(tr, 'Code', e.code);
      cellule(tr, 'Résultat', libelleResultat(e.resultat));
      var td = cellule(tr, 'Action', 'Aucune reprise sûre disponible.');
      if (e.reprise_possible === true && aPermission('communications.queue.retry')) {
        vider(td);
        var bouton = element('button', 'gs-bouton gs-bouton--petit gs-bouton--contour', 'Reprendre le STOP');
        bouton.type = 'button';
        bouton.addEventListener('click', function () { reprendreEvenement(e.id, bouton); });
        td.appendChild(bouton);
      }
      corps.appendChild(tr);
    });
  }

  function reprendreEvenement(id, bouton) {
    if (!aPermission('communications.queue.retry')) return;
    bouton.disabled = true;
    apiAdmin().communicationReprendreEvenement(id).then(function () {
      texte($('[data-cc-queue-status]'), 'Événement ajouté à la file de reprise. Le worker conserve son propre rythme.');
      delete demandes.queue;
      chargerOnglet('queue', true);
    }).catch(function (err) {
      afficherErreur(err, $('[data-cc-queue-status]'));
      bouton.disabled = false;
    });
  }

  function afficherEnvois(envois) {
    var corps = $('[data-cc-outbox-rows]');
    vider(corps);
    if (!envois.length) ligneVide(corps, 8, 'Aucune transmission dans la file.');
    envois.forEach(function (e) {
      var tr = element('tr');
      cellule(tr, 'Préparé', dateAffichee(e.prepare_le));
      cellule(tr, 'Ancienneté', anciennete(e.prepare_le) || 'Non mesurable');
      cellule(tr, 'Canal', libelleCanal(e.canal));
      cellule(tr, 'Type', libelleType(e.type));
      cellule(tr, 'Statut', libelleStatut(e.statut));
      cellule(tr, 'Tentatives', nombre(e.tentatives));
      cellule(tr, 'Code', e.code_erreur);
      cellule(tr, 'Modèle', e.modele_version ? 'v' + e.modele_version + ' · ' + (e.modele_langue || '') : null);
      corps.appendChild(tr);
    });
  }

  function init() {
    var onglets = $$('[data-cc-tab]');
    onglets.forEach(function (b, index) {
      b.addEventListener('click', function () { changerOnglet(b.getAttribute('data-cc-tab')); });
      b.addEventListener('keydown', function (e) {
        if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') return;
        e.preventDefault();
        var visibles = onglets.filter(function (x) { return !x.hidden; });
        var position = visibles.indexOf(b);
        var delta = e.key === 'ArrowRight' ? 1 : -1;
        changerOnglet(visibles[(position + delta + visibles.length) % visibles.length].getAttribute('data-cc-tab'), true);
      });
    });
    $('[data-cc-refresh]').addEventListener('click', function () { delete demandes[ongletActif]; chargerOnglet(ongletActif, true); });
    $('[data-cc-history-form]').addEventListener('submit', function (e) { e.preventDefault(); historiqueCourant.page = 0; delete demandes.history; chargerOnglet('history', true); });
    $('[data-cc-history-prev]').addEventListener('click', function () { if (historiqueCourant.page > 0) { historiqueCourant.page--; delete demandes.history; chargerOnglet('history', true); } });
    $('[data-cc-history-next]').addEventListener('click', function () {
      if ((historiqueCourant.page + 1) * 50 < historiqueCourant.total) { historiqueCourant.page++; delete demandes.history; chargerOnglet('history', true); }
    });
    $('[data-cc-template-type]').addEventListener('change', prechargerModele);
    $$('input[name="canaux"]', $('[data-cc-template-form]')).forEach(function (i) { i.addEventListener('change', afficherChampWhatsApp); });
    $('[data-cc-template-form]').addEventListener('submit', enregistrerNouvelleVersion);
    $('[data-cc-preview]').addEventListener('click', creerApercu);
    document.addEventListener('change', function (e) {
      if (e.target.matches && e.target.matches('[data-langue-tableau]')) {
        delete demandes.queue;
        chargerOnglet('queue', true);
      }
    });
    racine.addEventListener('goship:vue', function (e) { if (e.detail === 'communications') chargerOnglet(ongletActif, false); });

    var api = racine.GoshipAPI;
    if (api && typeof api.permissions === 'function') {
      api.permissions().then(function (p) { permissions = p && Array.isArray(p.permissions) ? p.permissions : []; })
        .catch(function () { permissions = []; });
    }
    chargerOnglet('overview', true);
  }

  function initialiser() {
    if (!vue.getAttribute('data-cc-initialise')) {
      vue.setAttribute('data-cc-initialise', 'oui');
      init();
    }
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initialiser);
  else initialiser();
})(window);
