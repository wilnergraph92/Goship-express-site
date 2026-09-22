/* ==========================================================================
   Goship Express — étiquettes d'expédition et factures imprimables
   ==========================================================================
   Deux documents, construits dans la page à partir des données du colis ou de
   la facture :

     GoshipImpression.etiquette(colis)        étiquette 4 × 6 pouces, avec son
                                              code-barres et son QR code
     GoshipImpression.facture(facture, cl)    facture sur une page A4, dans la
                                              langue du client
     GoshipImpression.imprimer(noeuds, o)     envoie à l'imprimante

   L'impression se fait dans un cadre (iframe) à part, avec sa propre feuille
   de style (assets/css/impression.css). C'est ce qui permet de fixer la taille
   du papier — 4 × 6 pouces pour une étiquette, A4 pour une facture — et
   d'imprimer exactement le document, sans que le style du site ni une fenêtre
   ouverte ne s'en mêlent. La fenêtre d'impression du navigateur sert d'aperçu.

   Rien n'est assemblé par morceaux de HTML : chaque texte est posé avec
   textContent. Un nom de client contenant des chevrons reste donc du texte.

   L'étiquette est écrite en français : c'est un papier interne, imprimé à
   Miami et lu par nos transporteurs. La facture, elle, part chez le client :
   elle suit sa langue, comme les e-mails (voir assets/js/notifications.js).
   Pour modifier un texte de la facture, changez-le ici dans chaque langue.
   ========================================================================== */
(function () {
  'use strict';

  // L'adresse de l'entrepôt, telle qu'elle est écrite aux clients. Elle
  // apparaît aussi dans outils/generateur/build.py, dans
  // outils/generateur/pages/mon-compte.main.html, dans
  // application-mobile/config.js et dans outils/supabase.sql (adresse_miami) :
  // les cinq doivent rester d'accord.
  // L'émetteur de la facture : l'établissement dominicain, avec son RNC.
  // C'est lui qui facture, et non l'entrepôt de Miami — celui-ci ne reçoit que
  // les achats des clients, et reste sur l'étiquette d'expédition.
  var SANTO_DOMINGO = {
    nom: 'Goship Express LLC',
    ligne1: 'Calle 25 de Febrero, La Caleta',
    ligne2: 'Santo Domingo Este 11500',
    telephone: '809 317-6686',
    rnc: '133-79976-6'
  };

  // Les moyens de paiement imprimés sur une facture à payer. Ce sont des
  // coordonnées d'entreprise : elles ne se traduisent pas, seuls leurs
  // libellés le sont. « Cuenta Ahorro » est le terme de la banque.
  var PAIEMENTS = [
    { cle: 'banque', nom: 'Banco BHD León RD',
      lignes: [['nom', 'Wilner Delisnord'], ['compte', '39396350014'], ['typeCompte', 'Cuenta Ahorro']] },
    { cle: 'paypal', nom: 'goshipexpressllc@gmail.com', lignes: [] },
    { cle: 'transfert', nom: 'Western Union · Unitransfer · Ria',
      lignes: [['nom', 'Immacula Delisnord'], ['telephone', '809 317-6686'], ['ville', 'Santo Domingo']] }
  ];

  var MIAMI = {
    nom: 'Goship Express LLC',
    ligne1: '8140 NW 74th Ave Unit 3',
    ligne2: 'APT-46780',
    ville: 'Medley',
    etat: 'Florida',
    zip: '33166',
    pays: 'United States',
    telephone: '786 525-2944'
  };

  // Le site vit à la racine en français, et dans en/, es/ et ht/ pour les
  // autres langues : le chemin vers assets/ n'est donc pas le même partout.
  // On le déduit de l'adresse de ce fichier au lieu de l'écrire — et il faut
  // ici une adresse complète, car le document imprimé est construit dans un
  // cadre « about:blank », où un chemin relatif ne mènerait nulle part.
  var BASE = (function () {
    var script = document.currentScript;
    var url = script ? script.src : '';
    var i = url.indexOf('assets/js/impression.js');
    return i >= 0 ? url.slice(0, i) : '';
  })();

  var TEXTES = {
    fr: {
      titre: 'Facture', etablie: 'Établie le', echeance: 'À payer avant le', payeeLe: 'Payée le',
      statuts: { a_payer: 'À payer', payee: 'Payée', annulee: 'Annulée' },
      factureA: 'Facturé à', codeClient: 'Code client {code}',
      colonnes: { quantite: 'Quantité', poids: 'Poids / lbs', description: 'Description', colis: 'Colis', montant: 'Total' },
      totalColis: 'Total colis', fraisService: 'Frais de service', balance: 'Balance', grandTotal: 'Grand total',
      signature: 'Signature autorisée', pourGoship: 'Pour Goship Express',
      total: 'Total à payer', paiement: 'Paiement',
      reglee: 'Facture réglée, merci !', regleePar: 'Payée par {moyen}', regleeLe: 'Payée le {date}',
      annulee: 'Cette facture a été annulée : rien n\'est dû.',
      parCarte: 'Par carte Visa ou Mastercard, à cette adresse :',
      parCode: 'Par carte Visa ou Mastercard : scannez le code ci-contre.',
      parWhatsApp: 'Écrivez-nous sur WhatsApp pour régler cette facture.',
      scanner: 'Scannez pour payer', transport: 'Transport', transportColis: 'Transport de colis',
      moyens: { paypal: 'PayPal', banque: 'Compte bancaire', azul: 'Azul',
                moncash: 'MonCash', natcash: 'NatCash', especes: 'Espèces' },
      moyensTitres: { banque: 'Virement bancaire', paypal: 'PayPal', transfert: 'Transfert d\'argent' },
      champs: { nom: 'Nom', compte: 'N° de compte', typeCompte: 'Type de compte',
                telephone: 'Téléphone', ville: 'Ville' },
      merci: 'Merci pour votre confiance !',
      pays: { HT: 'Haïti', DO: 'République dominicaine', US: 'États-Unis' },
      pied: 'Montants en dollars des États-Unis. Document établi par Goship Express LLC.'
    },
    en: {
      titre: 'Invoice', etablie: 'Issued on', echeance: 'Due by', payeeLe: 'Paid on',
      statuts: { a_payer: 'Unpaid', payee: 'Paid', annulee: 'Cancelled' },
      factureA: 'Billed to', codeClient: 'Customer code {code}',
      colonnes: { quantite: 'Qty', poids: 'Weight / lbs', description: 'Description', colis: 'Package', montant: 'Total' },
      totalColis: 'Packages total', fraisService: 'Service fee', balance: 'Balance', grandTotal: 'Grand total',
      signature: 'Authorised signature', pourGoship: 'For Goship Express',
      total: 'Total due', paiement: 'Payment',
      reglee: 'Invoice paid — thank you!', regleePar: 'Paid by {moyen}', regleeLe: 'Paid on {date}',
      annulee: 'This invoice has been cancelled: nothing is due.',
      parCarte: 'By Visa or Mastercard, at this address:',
      parCode: 'By Visa or Mastercard: scan the code opposite.',
      parWhatsApp: 'Message us on WhatsApp to settle this invoice.',
      scanner: 'Scan to pay', transport: 'Shipping', transportColis: 'Package shipping',
      moyens: { paypal: 'PayPal', banque: 'Bank account', azul: 'Azul',
                moncash: 'MonCash', natcash: 'NatCash', especes: 'Cash' },
      moyensTitres: { banque: 'Bank transfer', paypal: 'PayPal', transfert: 'Money transfer' },
      champs: { nom: 'Name', compte: 'Account number', typeCompte: 'Account type',
                telephone: 'Phone', ville: 'City' },
      merci: 'Thank you for your trust!',
      pays: { HT: 'Haiti', DO: 'Dominican Republic', US: 'United States' },
      pied: 'Amounts in US dollars. Document issued by Goship Express LLC.'
    },
    es: {
      titre: 'Factura', etablie: 'Emitida el', echeance: 'A pagar antes del', payeeLe: 'Pagada el',
      statuts: { a_payer: 'Por pagar', payee: 'Pagada', annulee: 'Anulada' },
      factureA: 'Facturado a', codeClient: 'Código de cliente {code}',
      colonnes: { quantite: 'Cant.', poids: 'Peso / lbs', description: 'Descripción', colis: 'Paquete', montant: 'Total' },
      totalColis: 'Total paquetes', fraisService: 'Cargo por servicio', balance: 'Balance', grandTotal: 'Gran total',
      signature: 'Firma autorizada', pourGoship: 'Por Goship Express',
      total: 'Total a pagar', paiement: 'Pago',
      reglee: '¡Factura pagada, gracias!', regleePar: 'Pagada con {moyen}', regleeLe: 'Pagada el {date}',
      annulee: 'Esta factura fue anulada: no hay nada que pagar.',
      parCarte: 'Con tarjeta Visa o Mastercard, en esta dirección:',
      parCode: 'Con tarjeta Visa o Mastercard: escanee el código al lado.',
      parWhatsApp: 'Escríbanos por WhatsApp para pagar esta factura.',
      scanner: 'Escanee para pagar', transport: 'Transporte', transportColis: 'Transporte de paquetes',
      moyens: { paypal: 'PayPal', banque: 'Cuenta bancaria', azul: 'Azul',
                moncash: 'MonCash', natcash: 'NatCash', especes: 'Efectivo' },
      moyensTitres: { banque: 'Transferencia bancaria', paypal: 'PayPal', transfert: 'Transferencia de dinero' },
      champs: { nom: 'Nombre', compte: 'N.º de cuenta', typeCompte: 'Tipo de cuenta',
                telephone: 'Teléfono', ville: 'Ciudad' },
      merci: '¡Gracias por su confianza!',
      pays: { HT: 'Haití', DO: 'República Dominicana', US: 'Estados Unidos' },
      pied: 'Importes en dólares estadounidenses. Documento emitido por Goship Express LLC.'
    },
    ht: {
      titre: 'Fakti', etablie: 'Fèt le', echeance: 'Pou peye anvan', payeeLe: 'Peye le',
      statuts: { a_payer: 'Pou peye', payee: 'Peye', annulee: 'Anile' },
      factureA: 'Faktire pou', codeClient: 'Kòd kliyan {code}',
      colonnes: { quantite: 'Kantite', poids: 'Pwa / lbs', description: 'Deskripsyon', colis: 'Koli', montant: 'Total' },
      totalColis: 'Total kolis', fraisService: 'Frè sèvis', balance: 'Balans', grandTotal: 'Gran total',
      signature: 'Siyati otorize', pourGoship: 'Pou Goship Express',
      total: 'Total pou peye', paiement: 'Peman',
      reglee: 'Fakti peye, mèsi !', regleePar: 'Peye ak {moyen}', regleeLe: 'Peye le {date}',
      annulee: 'Fakti sa a anile : ou pa dwe anyen.',
      parCarte: 'Ak kat Visa oswa Mastercard, nan adrès sa a :',
      parCode: 'Ak kat Visa oswa Mastercard : eskane kòd ki akote a.',
      parWhatsApp: 'Ekri nou sou WhatsApp pou peye fakti sa a.',
      scanner: 'Eskane pou peye', transport: 'Transpò', transportColis: 'Transpò koli',
      moyens: { paypal: 'PayPal', banque: 'Kont labank', azul: 'Azul',
                moncash: 'MonCash', natcash: 'NatCash', especes: 'Kach' },
      moyensTitres: { banque: 'Vire labank', paypal: 'PayPal', transfert: 'Voye lajan' },
      champs: { nom: 'Non', compte: 'Nimewo kont', typeCompte: 'Kalite kont',
                telephone: 'Telefòn', ville: 'Vil' },
      merci: 'Mèsi pou konfyans ou !',
      pays: { HT: 'Ayiti', DO: 'Repiblik Dominikèn', US: 'Etazini' },
      pied: 'Montan yo an dola ameriken. Dokiman Goship Express LLC te fè.'
    }
  };

  // Le créole n'est pas connu des navigateurs : ses mois sont écrits à la main,
  // comme dans assets/js/api.js et assets/js/notifications.js.
  var LOCALES = { fr: 'fr-FR', en: 'en-US', es: 'es-DO', ht: 'fr-FR' };
  var MOIS_HT = ['janvye', 'fevriye', 'mas', 'avril', 'me', 'jen',
                 'jiyè', 'out', 'septanm', 'oktòb', 'novanm', 'desanm'];

  // Étiquette : document interne, en français (voir l'en-tête du fichier)
  var SERVICES = { aerien: 'Aérien', maritime: 'Maritime', terrestre: 'Terrestre' };

  /* ---- Petits outils ---------------------------------------------------- */
  function langueDe(valeur) {
    return TEXTES[valeur] ? valeur : 'fr';
  }

  function remplacer(modele, valeurs) {
    var t = String(modele || '');
    Object.keys(valeurs || {}).forEach(function (k) {
      t = t.split('{' + k + '}').join(valeurs[k]);
    });
    return t;
  }

  function el(balise, classe, texte) {
    var n = document.createElement(balise);
    if (classe) n.className = classe;
    if (texte !== undefined && texte !== null && texte !== '') n.textContent = String(texte);
    return n;
  }

  function bloc(parent, balise, classe, texte) {
    return parent.appendChild(el(balise, classe, texte));
  }

  // Le logo. « alt » n'est pas décoratif ici : si l'image manque, c'est lui
  // qui s'imprime, et le papier porte quand même le nom de l'entreprise.
  function logo(parent, fichier, classe, largeur, hauteur) {
    var img = document.createElement('img');
    img.src = BASE + 'assets/img/' + fichier;
    img.alt = 'Goship Express';
    img.width = largeur;
    img.height = hauteur;
    img.className = classe;
    return parent.appendChild(img);
  }

  // La signature manuscrite. Contrairement au logo, son absence ne doit rien
  // imprimer du tout : mieux vaut une facture sans signature qu'un mot à la
  // place d'un paraphe.
  function signature(parent, classe) {
    var img = document.createElement('img');
    img.src = BASE + 'assets/img/signature-goship.png';
    img.alt = '';
    img.setAttribute('aria-hidden', 'true');
    img.width = 1231;
    img.height = 382;
    img.className = classe;
    img.onerror = function () { if (img.parentNode) img.parentNode.removeChild(img); };
    return parent.appendChild(img);
  }

  // Les quatre montants d'une facture. Le calcul vit dans api.js : la facture
  // imprimée et l'écran doivent toujours afficher la même chose.
  function totauxDe(facture) {
    var API = window.GoshipAPI;
    return API && API.outils && API.outils.totauxFacture
      ? API.outils.totauxFacture(facture)
      : { colis: Number(facture.montant_usd) || 0, frais: 0,
          grandTotal: Number(facture.montant_usd) || 0, paye: 0,
          balance: Number(facture.montant_usd) || 0 };
  }

  function nombreLb(n) {
    var v = Number(n);
    if (!isFinite(v)) return '—';
    return (Math.round(v * 100) / 100).toString().replace('.', ',');
  }

  function date(valeur, langue) {
    if (!valeur) return '';
    var d = new Date(valeur);
    if (isNaN(d.getTime())) return '';
    if (langue === 'ht') return d.getDate() + ' ' + MOIS_HT[d.getMonth()] + ' ' + d.getFullYear();
    try {
      return new Intl.DateTimeFormat(LOCALES[langue] || 'fr-FR',
                                     { day: 'numeric', month: 'long', year: 'numeric' }).format(d);
    } catch (e) {
      return d.toLocaleDateString();
    }
  }

  function argent(n, langue) {
    var v = Number(n) || 0;
    try {
      return new Intl.NumberFormat(LOCALES[langue] || 'fr-FR',
                                   { style: 'currency', currency: 'USD' }).format(v);
    } catch (e) {
      return v.toFixed(2) + ' USD';
    }
  }

  function ligneTexte(parent, classe, morceaux) {
    var vus = {};
    var t = morceaux.filter(function (m) {
      if (m === undefined || m === null || m === '') return false;
      // Chez beaucoup de clients, la ville et la région portent le même nom :
      // l'écrire deux fois coûterait une ligne entière sur l'étiquette.
      var cle = String(m).trim().toLowerCase();
      if (vus[cle]) return false;
      vus[cle] = true;
      return true;
    }).join(' · ');
    return t ? bloc(parent, 'p', classe, t) : null;
  }

  // Les deux codes sont facultatifs : si codes.js n'est pas chargé, ou si un
  // texte lui déplaît, le document s'imprime sans eux plutôt que de ne pas
  // s'imprimer du tout.
  function dessinerCode(parent, quoi, texte, titre) {
    var C = window.GoshipCodes;
    if (!C || !texte) return null;
    try {
      return parent.appendChild(quoi === 'qr'
        ? C.qr(texte, { titre: titre, marge: 2 })
        : C.code128(texte, { titre: titre, hauteur: 28 }));
    } catch (e) {
      return null;
    }
  }

  // Adresse publique du site, pour le lien que porte le QR code
  function siteUrl() {
    var cfg = window.GOSHIP_CONFIG || {};
    var u = String(cfg.siteUrl || '').trim().replace(/\/+$/, '');
    if (u) return u;
    if (/^https?:$/.test(location.protocol)) {
      return location.origin + location.pathname.replace(/\/[^/]*$/, '');
    }
    return '';
  }

  // Ce que porte le QR code de l'étiquette : le lien de suivi si le site est en
  // ligne, sinon le numéro du colis tout court — un scanner lit alors le
  // numéro, ce qui suffit à retrouver le colis.
  function lienSuivi(numero) {
    var base = siteUrl();
    return base ? base + '/index.html?suivi=' + encodeURIComponent(numero) : numero;
  }

  /* ======================================================================
     L'étiquette d'expédition
     ======================================================================
     4 × 6 pouces : le format des imprimantes d'étiquettes, et celui qu'on
     découpe dans une feuille ordinaire.
     ====================================================================== */
  function etiquette(colis) {
    var c = colis || {};
    var numero = c.numero || '';
    var fr = TEXTES.fr;
    var page = el('article', 'et');

    // Bandeau
    var tete = bloc(page, 'header', 'et__tete');
    var marque = bloc(tete, 'div', 'et__marque');
    // Logo noir : une thermique n'imprime qu'en noir pur, et le logo en
    // couleurs y sortirait en pointillés.
    logo(marque, 'logo-goship-noir.png', 'et__logo', 420, 147);
    bloc(marque, 'span', 'et__sous', 'Miami → Haïti · Rép. dominicaine');
    bloc(tete, 'span', 'et__service', (SERVICES[c.service] || c.service || '').toUpperCase());

    // Le numéro et son code-barres
    var bande = bloc(page, 'div', 'et__bande');
    dessinerCode(bande, 'barre', numero, 'Code-barres du colis ' + numero);
    bloc(bande, 'strong', 'et__numero', numero);

    // Destinataire, avec le QR de suivi
    var dest = bloc(page, 'section', 'et__dest');
    var qui = bloc(dest, 'div', 'et__qui');
    bloc(qui, 'span', 'et__libelle', 'Destinataire');
    var personne = bloc(qui, 'strong', 'et__personne et__coupe', c.nom_client || '');
    if (c.code_client) {
      // Dans son propre élément, insécable : un code coupé en deux
      // (« GSE- » sur une ligne, « 1204 » sur la suivante) ne se lit pas.
      personne.appendChild(document.createTextNode('  '));
      bloc(personne, 'span', 'et__code', c.code_client);
    }
    if (c.adresse_client) bloc(qui, 'p', 'et__adresse et__coupe', c.adresse_client);
    ligneTexte(qui, 'et__adresse et__ligne', [c.ville_client, c.region_client]);
    ligneTexte(qui, 'et__adresse et__ligne', [fr.pays[c.pays_client] || c.pays_client]);
    if (c.telephone_client) bloc(qui, 'p', 'et__tel', c.telephone_client);

    var cote = bloc(dest, 'div', 'et__qr');
    if (dessinerCode(cote, 'qr', lienSuivi(numero), 'Suivre le colis ' + numero)) {
      bloc(cote, 'span', 'et__qr-texte', 'Scannez-moi');
    }

    // La destination en très gros : c'est ce qu'on lit en triant les sacs
    var vers = bloc(page, 'section', 'et__vers');
    bloc(vers, 'strong', 'et__pays', c.pays_destination || '');
    bloc(vers, 'span', 'et__ville', (c.destination || c.ville_client || '').toUpperCase());

    // Expéditeur
    var exp = bloc(page, 'section', 'et__exp');
    bloc(exp, 'span', 'et__libelle', 'Expéditeur');
    bloc(exp, 'p', 'et__adresse', MIAMI.nom + ' — ' + MIAMI.ligne1 + ', ' + MIAMI.ligne2);
    bloc(exp, 'p', 'et__adresse',
         MIAMI.ville + ', ' + MIAMI.etat + ' ' + MIAMI.zip + ', ' + MIAMI.pays + ' · ' + MIAMI.telephone);

    // Le contenu, en bas
    var pied = bloc(page, 'footer', 'et__pied');
    var contenu = bloc(pied, 'div', 'et__contenu');
    if (c.description) bloc(contenu, 'p', 'et__desc et__coupe', c.description);
    ligneTexte(contenu, 'et__meta', [
      c.poids_lb !== null && c.poids_lb !== undefined && c.poids_lb !== ''
        ? String(c.poids_lb).replace('.', ',') + ' lb' : '',
      c.expediteur ? 'Acheté chez ' + c.expediteur : '',
      c.recu_le ? 'Reçu le ' + date(c.recu_le, 'fr') : ''
    ]);
    if (c.suivi_transporteur) {
      bloc(contenu, 'p', 'et__meta', 'Suivi vendeur : ' + c.suivi_transporteur);
    }
    return page;
  }

  /* ======================================================================
     La facture
     ====================================================================== */
  function lignesDe(facture) {
    return facture.lignes || facture.facture_lignes || [];
  }

  // Les lignes viennent soit du tableau de bord (colis : { numero }), soit de
  // la fonction mes_factures de la base (colis : « GSE-1001-HT »).
  function numeroColis(ligne) {
    var c = ligne.colis;
    if (!c) return '';
    return typeof c === 'string' ? c : (c.numero || '');
  }

  function facture(f, client, options) {
    var fa = f || {};
    var cl = client || fa.clients || {};
    var langue = langueDe((options || {}).langue || cl.langue);
    var T = TEXTES[langue];
    var lignes = lignesDe(fa);
    var totaux = totauxDe(fa);
    var page = el('article', 'fa');
    page.lang = langue;

    // Bandeau : logo, numéro, dates
    var tete = bloc(page, 'header', 'fa__tete');
    var gauche = bloc(tete, 'div', 'fa__marque');
    logo(gauche, 'logo-goship.png', 'fa__logo', 360, 120);
    bloc(gauche, 'p', 'fa__emetteur',
         SANTO_DOMINGO.nom + '\n' + SANTO_DOMINGO.ligne1 + '\n' + SANTO_DOMINGO.ligne2 + '\n' +
         'Tél. ' + SANTO_DOMINGO.telephone + '\nRNC ' + SANTO_DOMINGO.rnc);

    var droite = bloc(tete, 'div', 'fa__titre');
    bloc(droite, 'h1', null, T.titre);
    bloc(droite, 'strong', 'fa__numero', fa.numero || '');
    var dl = bloc(droite, 'dl', 'fa__dates');
    function ligneDate(libelle, valeur) {
      if (!valeur) return;
      bloc(dl, 'dt', null, libelle);
      bloc(dl, 'dd', null, valeur);
    }
    ligneDate(T.etablie, date(fa.cree_le, langue));
    ligneDate(T.echeance, fa.statut === 'a_payer' ? date(fa.echeance_le, langue) : '');
    ligneDate(T.payeeLe, date(fa.payee_le, langue));
    var etat = bloc(droite, 'span', 'fa__etat fa__etat--' + (fa.statut || 'a_payer'),
                    T.statuts[fa.statut] || fa.statut || '');
    etat.setAttribute('role', 'status');

    // Le client
    var qui = bloc(page, 'section', 'fa__client');
    bloc(qui, 'span', 'fa__libelle', T.factureA);
    bloc(qui, 'strong', 'fa__personne', cl.nom_complet || '');
    if (cl.code) bloc(qui, 'p', 'fa__code', remplacer(T.codeClient, { code: cl.code }));
    if (cl.adresse) bloc(qui, 'p', null, cl.adresse);
    ligneTexte(qui, null, [cl.ville, cl.region, T.pays[cl.pays] || cl.pays]);
    ligneTexte(qui, null, [cl.telephone, cl.email]);

    // Le détail : une ligne par colis, quantité, poids, description et total
    var table = bloc(page, 'table', 'fa__lignes');
    var tr = bloc(bloc(table, 'thead'), 'tr');
    [['quantite', 'fa__centre'], ['poids', 'fa__centre'], ['description', null], ['montant', 'fa__droite']]
      .forEach(function (col) {
        bloc(tr, 'th', col[1], T.colonnes[col[0]]).setAttribute('scope', 'col');
      });
    var tbody = bloc(table, 'tbody');
    function ligneDetail(quantite, poids, libelle, numero, montant) {
      var r = bloc(tbody, 'tr');
      bloc(r, 'td', 'fa__centre', String(quantite || 1));
      bloc(r, 'td', 'fa__centre', poids != null && poids !== '' ? nombreLb(poids) : '—');
      var d = bloc(r, 'td');
      bloc(d, 'span', 'fa__desc', libelle);
      if (numero) bloc(d, 'span', 'fa__colis', numero);
      bloc(r, 'td', 'fa__droite', argent(montant, langue));
    }
    if (lignes.length) {
      lignes.forEach(function (l) {
        // Le poids facturé est recopié sur la ligne au moment de la facture.
        // Les factures d'avant cette recopie n'en ont pas : on prend alors
        // celui du colis, plutôt que d'imprimer un tiret.
        var poids = l.poids_lb;
        if (poids === null || poids === undefined || poids === '') {
          poids = l.colis && typeof l.colis === 'object' ? l.colis.poids_lb : null;
        }
        ligneDetail(l.quantite || 1, poids, l.libelle || T.transport, numeroColis(l), l.montant_usd);
      });
    } else {
      // Facture d'un seul montant, sans détail : la note en tient lieu
      ligneDetail(1, null, fa.note || T.transportColis, '', totaux.colis);
    }

    // Les totaux : colis, frais de service une seule fois, balance, grand total
    var recap = bloc(page, 'table', 'fa__totaux');
    var corpsRecap = bloc(recap, 'tbody');
    function ligneTotal(libelle, montant, classe) {
      var r = bloc(corpsRecap, 'tr', classe);
      var t = bloc(r, 'th', null, libelle);
      t.setAttribute('scope', 'row');
      bloc(r, 'td', 'fa__droite', argent(montant, langue));
    }
    ligneTotal(T.totalColis, totaux.colis);
    ligneTotal(T.fraisService, totaux.frais);
    ligneTotal(T.grandTotal, totaux.grandTotal, 'fa__totaux--grand');
    ligneTotal(T.balance, totaux.balance, 'fa__totaux--balance');

    // Le paiement. Le code à scanner est dessiné d'abord, car c'est lui qui
    // décide de la formulation : le lien en toutes lettres tenait quatre
    // lignes sur le papier. Il ne s'imprime donc plus que si le code n'a pas
    // pu être produit — sans quoi le client n'aurait aucun moyen de payer.
    var bas = bloc(page, 'section', 'fa__bas');
    var paiement = bloc(bas, 'div', 'fa__paiement');
    var cote = null, codeDessine = false;
    if (fa.statut === 'a_payer' && fa.lien_paiement) {
      cote = el('div', 'fa__qr');
      codeDessine = !!dessinerCode(cote, 'qr', fa.lien_paiement, T.scanner + ' — ' + (fa.numero || ''));
      if (codeDessine) bloc(cote, 'span', 'fa__qr-texte', T.scanner);
    }
    bloc(paiement, 'span', 'fa__libelle', T.paiement);
    if (fa.statut === 'payee') {
      bloc(paiement, 'p', null, T.reglee);
      ligneTexte(paiement, null, [
        T.moyens[fa.moyen] ? remplacer(T.regleePar, { moyen: T.moyens[fa.moyen] }) : '',
        fa.payee_le ? remplacer(T.regleeLe, { date: date(fa.payee_le, langue) }) : ''
      ]);
    } else if (fa.statut === 'annulee') {
      bloc(paiement, 'p', null, T.annulee);
    } else if (fa.lien_paiement) {
      bloc(paiement, 'p', null, codeDessine ? T.parCode : T.parCarte);
      if (!codeDessine) bloc(paiement, 'p', 'fa__lien', fa.lien_paiement);
    } else {
      bloc(paiement, 'p', null, T.parWhatsApp);
    }
    if (fa.note && lignes.length) bloc(paiement, 'p', 'fa__note', fa.note);

    if (codeDessine) bas.appendChild(cote);

    // Les autres moyens de paiement. Seulement sur une facture à payer : les
    // rappeler sur une facture déjà réglée n'aiderait personne.
    if (fa.statut === 'a_payer') {
      var moyens = bloc(page, 'section', 'fa__moyens');
      PAIEMENTS.forEach(function (m) {
        var carte = bloc(moyens, 'div', 'fa__moyen');
        bloc(carte, 'span', 'fa__moyen-titre', T.moyensTitres[m.cle]);
        bloc(carte, 'strong', 'fa__moyen-nom', m.nom);
        if (!m.lignes.length) return;
        var dl = bloc(carte, 'dl', 'fa__moyen-lignes');
        m.lignes.forEach(function (ligne) {
          bloc(dl, 'dt', null, T.champs[ligne[0]]);
          bloc(dl, 'dd', null, ligne[1]);
        });
      });
    }

    // Notre signature. Celle du client a été retirée : une facture n'a pas à
    // être contresignée pour être due.
    var paraphes = bloc(page, 'section', 'fa__signatures');
    var nous = bloc(paraphes, 'div', 'fa__paraphe');
    signature(nous, 'fa__signature');
    bloc(nous, 'span', 'fa__paraphe-trait');
    bloc(nous, 'span', 'fa__paraphe-titre', T.signature);
    bloc(nous, 'span', 'fa__paraphe-sous', T.pourGoship);

    bloc(page, 'footer', 'fa__pied', T.merci);
    return page;
  }

  /* ======================================================================
     L'envoi à l'imprimante
     ====================================================================== */
  // On attend la feuille de style et les images : sans cela, la fenêtre
  // d'impression s'ouvrirait sur une page encore nue.
  function attendre(doc, style) {
    var promesses = [];
    if (style && !style.sheet) {
      promesses.push(new Promise(function (ok) {
        style.addEventListener('load', ok);
        style.addEventListener('error', ok);
      }));
    }
    Array.prototype.forEach.call(doc.images || [], function (img) {
      if (img.complete) return;
      promesses.push(new Promise(function (ok) {
        img.addEventListener('load', ok);
        img.addEventListener('error', ok);
      }));
    });
    // Une image ou une feuille de style qui ne répond pas ne doit pas empêcher
    // d'imprimer : au bout de trois secondes, on imprime.
    return Promise.race([
      Promise.all(promesses),
      new Promise(function (ok) { setTimeout(ok, 3000); })
    ]);
  }

  function imprimer(noeuds, options) {
    options = options || {};
    var liste = noeuds && noeuds.length === undefined ? [noeuds] : Array.prototype.slice.call(noeuds || []);
    if (!liste.length) return Promise.resolve(false);

    var cadre = document.createElement('iframe');
    cadre.className = 'gs-cadre-impression';
    cadre.title = options.titre || 'Document à imprimer';
    cadre.setAttribute('aria-hidden', 'true');
    document.body.appendChild(cadre);

    var doc = cadre.contentDocument;
    doc.documentElement.lang = options.langue || 'fr';
    doc.head.appendChild(el('meta')).setAttribute('charset', 'utf-8');
    bloc(doc.head, 'title', null, options.titre || 'Goship Express');
    var style = doc.createElement('link');
    style.rel = 'stylesheet';
    style.href = BASE + 'assets/css/impression.css';
    doc.head.appendChild(style);
    // Le format du papier : seule une règle @page peut le fixer, et elle ne
    // peut pas dépendre d'une classe — d'où cette ligne posée ici.
    var papier = doc.createElement('style');
    papier.textContent = '@page{size:' + (options.papier || 'A4') + ';margin:' + (options.marge || '0') + '}';
    doc.head.appendChild(papier);
    liste.forEach(function (n) { doc.body.appendChild(doc.importNode(n, true)); });

    return attendre(doc, style).then(function () {
      var fenetre = cadre.contentWindow;
      var nettoyer = function () {
        if (cadre.parentNode) cadre.parentNode.removeChild(cadre);
      };
      // Safari ne déclenche pas toujours afterprint : le minuteur ferme le
      // cadre dans tous les cas.
      fenetre.addEventListener('afterprint', function () { setTimeout(nettoyer, 200); });
      setTimeout(nettoyer, 60000);
      try {
        fenetre.focus();
        fenetre.print();
      } catch (e) {
        nettoyer();
        throw e;
      }
      return true;
    });
  }

  window.GoshipImpression = {
    etiquette: etiquette,
    facture: facture,
    imprimer: imprimer,
    miami: MIAMI,
    lienSuivi: lienSuivi
  };
})();
