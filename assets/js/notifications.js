/* ==========================================================================
   Goship Express — messages envoyés aux clients
   E-mail et WhatsApp, dans la langue du client, quand son colis est reçu à
   Miami et quand il est disponible en agence. Utilisé par le tableau de bord.
   Pour modifier un texte, changez-le ici dans chaque langue.
   ========================================================================== */
(function () {
  'use strict';

  var TEXTES = {
    fr: {
      sujet: { recu: 'Colis reçu à Miami — {numero}', disponible: 'Votre colis est disponible — {numero}' },
      salutation: 'Bonjour {nom},',
      intro: {
        recu: 'Nous avons bien reçu votre colis à notre entrepôt de Miami. En voici les détails :',
        disponible: 'Votre colis est disponible dans notre agence de {agence}. Présentez votre code client pour le retirer.',
        disponibleSansAgence: 'Votre colis est disponible dans notre agence. Présentez votre code client pour le retirer.'
      },
      libelles: { code: 'Code client', numero: 'N° de colis', expediteur: 'Expéditeur', service: 'Service',
                  contenu: 'Contenu', suivi: 'Suivi vendeur', poids: 'Poids', recu: 'Reçu le' },
      services: { aerien: 'Fret aérien', maritime: 'Fret maritime', terrestre: 'Transport terrestre' },
      bouton: 'SUIVRE MON COLIS',
      pied: 'Vous recevez cet e-mail car vous avez un compte client Goship Express.',
      whatsapp: {
        recu: 'Nous avons bien reçu votre colis à notre entrepôt de Miami 📦',
        disponible: 'Votre colis est disponible dans notre agence de {agence} ✅',
        disponibleSansAgence: 'Votre colis est disponible dans notre agence ✅',
        retrait: 'Présentez votre code client pour le retirer.',
        suivi: 'Suivez-le en temps réel : {lien}'
      }
    },
    en: {
      sujet: { recu: 'Package received in Miami — {numero}', disponible: 'Your package is ready for pickup — {numero}' },
      salutation: 'Hello {nom},',
      intro: {
        recu: 'We have received your package at our Miami warehouse. Here are the details:',
        disponible: 'Your package is ready for pickup at our {agence} office. Please show your customer code when you collect it.',
        disponibleSansAgence: 'Your package is ready for pickup at our office. Please show your customer code when you collect it.'
      },
      libelles: { code: 'Customer code', numero: 'Package number', expediteur: 'Sender', service: 'Service',
                  contenu: 'Contents', suivi: 'Seller tracking', poids: 'Weight', recu: 'Received on' },
      services: { aerien: 'Air freight', maritime: 'Ocean freight', terrestre: 'Ground transport' },
      bouton: 'TRACK MY PACKAGE',
      pied: 'You are receiving this email because you have a Goship Express customer account.',
      whatsapp: {
        recu: 'We have received your package at our Miami warehouse 📦',
        disponible: 'Your package is ready for pickup at our {agence} office ✅',
        disponibleSansAgence: 'Your package is ready for pickup at our office ✅',
        retrait: 'Please show your customer code when you collect it.',
        suivi: 'Track it in real time: {lien}'
      }
    },
    es: {
      sujet: { recu: 'Paquete recibido en Miami — {numero}', disponible: 'Su paquete está disponible — {numero}' },
      salutation: 'Estimado/a {nom}:',
      intro: {
        recu: 'Le informamos que recibimos su paquete en nuestro almacén de Miami. Estos son los detalles:',
        disponible: 'Le informamos que tiene disponible en nuestra oficina de {agence} el siguiente paquete. Presente su código de cliente para retirarlo.',
        disponibleSansAgence: 'Le informamos que tiene disponible en nuestra oficina el siguiente paquete. Presente su código de cliente para retirarlo.'
      },
      libelles: { code: 'Código de cliente', numero: 'N.º de paquete', expediteur: 'Suplidor', service: 'Servicio',
                  contenu: 'Contenido', suivi: 'Tracking del suplidor', poids: 'Peso', recu: 'Recibido el' },
      services: { aerien: 'Flete aéreo', maritime: 'Flete marítimo', terrestre: 'Transporte terrestre' },
      bouton: 'RASTREAR MI PAQUETE',
      pied: 'Recibe este correo porque tiene una cuenta de cliente en Goship Express.',
      whatsapp: {
        recu: 'Recibimos su paquete en nuestro almacén de Miami 📦',
        disponible: 'Su paquete está disponible en nuestra oficina de {agence} ✅',
        disponibleSansAgence: 'Su paquete está disponible en nuestra oficina ✅',
        retrait: 'Presente su código de cliente para retirarlo.',
        suivi: 'Sígalo en tiempo real: {lien}'
      }
    },
    ht: {
      sujet: { recu: 'Nou resevwa koli ou Miami — {numero}', disponible: 'Koli ou disponib — {numero}' },
      salutation: 'Bonjou {nom},',
      intro: {
        recu: 'Nou byen resevwa koli ou nan depo nou an Miami. Men detay li yo :',
        disponible: 'Koli ou disponib nan ajans nou an {agence}. Montre kòd kliyan ou pou w vin chèche l.',
        disponibleSansAgence: 'Koli ou disponib nan ajans nou an. Montre kòd kliyan ou pou w vin chèche l.'
      },
      libelles: { code: 'Kòd kliyan', numero: 'Nimewo koli', expediteur: 'Machann', service: 'Sèvis',
                  contenu: 'Sa ki ladan l', suivi: 'Swivi machann', poids: 'Pwa', recu: 'Resevwa le' },
      services: { aerien: 'Fret pa lè', maritime: 'Fret pa lanmè', terrestre: 'Transpò pa tè' },
      bouton: 'SWIV KOLI MWEN',
      pied: 'Ou resevwa imèl sa a paske ou gen yon kont kliyan Goship Express.',
      whatsapp: {
        recu: 'Nou byen resevwa koli ou nan depo nou an Miami 📦',
        disponible: 'Koli ou disponib nan ajans nou an {agence} ✅',
        disponibleSansAgence: 'Koli ou disponib nan ajans nou an ✅',
        retrait: 'Montre kòd kliyan ou pou w vin chèche l.',
        suivi: 'Swiv li an tan reyèl : {lien}'
      }
    }
  };

  // Modèles WhatsApp à faire approuver par Meta (voir README) et leurs langues
  var MODELES = { recu: 'colis_recu', disponible: 'colis_disponible' };
  var LANGUE_MODELE = { fr: 'fr', en: 'en_US', es: 'es', ht: 'fr' };
  var LOCALES = { fr: 'fr-FR', en: 'en-US', es: 'es-DO', ht: 'fr-FR' };
  var MOIS_HT = ['janvye', 'fevriye', 'mas', 'avril', 'me', 'jen', 'jiyè', 'out', 'septanm', 'oktòb', 'novanm', 'desanm'];
  var COULEURS = { encre: '#061a3f', encre2: '#0d2b6b', accent: '#f4600d', gris: '#5b6782', fond: '#f5f7fb', trait: '#e3e8f2' };
  var PIED_ADRESSE = 'Goship Express · 8140 NW 74th Ave, Unit 3, Medley, FL 33166 · WhatsApp +1 849 538-6262';

  function remplacer(texte, valeurs) {
    return texte.replace(/\{(\w+)\}/g, function (tout, cle) { return valeurs[cle] !== undefined ? valeurs[cle] : tout; });
  }

  function echapper(texte) {
    return String(texte).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function deuxChiffres(n) { return (n < 10 ? '0' : '') + n; }

  function dateHeure(iso, langue) {
    var d = new Date(iso);
    if (isNaN(d.getTime())) return '';
    if (langue === 'ht') {
      return d.getDate() + ' ' + MOIS_HT[d.getMonth()] + ' ' + d.getFullYear() + ', ' +
        deuxChiffres(d.getHours()) + ':' + deuxChiffres(d.getMinutes());
    }
    try {
      return new Intl.DateTimeFormat(LOCALES[langue], {
        day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit'
      }).format(d);
    } catch (e) { return d.toLocaleString(); }
  }

  function poids(valeur, langue) {
    if (valeur === null || valeur === undefined || valeur === '') return '';
    var n = Number(valeur);
    if (isNaN(n)) return '';
    try { return new Intl.NumberFormat(LOCALES[langue], { maximumFractionDigits: 2 }).format(n) + ' lb'; }
    catch (e) { return n + ' lb'; }
  }

  // Numéro WhatsApp au format international (chiffres uniquement)
  function telephoneInternational(telephone, pays) {
    var t = String(telephone || '').replace(/\D/g, '');
    if (t.length === 8 && pays === 'HT') return '509' + t;
    if (t.length === 10 && (pays === 'DO' || pays === 'US')) return '1' + t;
    return t;
  }

  // Logo des e-mails : les messageries n'affichent que des images en ligne. Le
  // tableau de bord le copie donc dans un dossier public de Supabase (« site »).
  var LOGO = { dossier: 'site', fichier: 'logo-goship.png', source: 'assets/img/logo-goship.png' };

  function config() { return window.GOSHIP_CONFIG || {}; }

  // Tableau de bord ouvert sur cet ordinateur ou sur le réseau de la maison
  function surOrdinateur() {
    return location.protocol === 'file:' ||
      /^(localhost|127(\.\d+){3}|\[::1\]|10(\.\d+){3}|192\.168(\.\d+){2}|172\.(1[6-9]|2\d|3[01])(\.\d+){2}|[\w-]+\.local)$/.test(location.hostname);
  }

  // Adresse publique du site pour les liens des messages : réglage siteUrl, sinon
  // celle du tableau de bord s'il est en ligne. Vide sur l'ordinateur : un lien
  // vers « localhost » ne mènerait nulle part chez le client.
  function racinePublique() {
    var url = String(config().siteUrl || '').trim();
    if (url) return url.replace(/\/*$/, '/');
    return surOrdinateur() ? '' : new URL('.', location.href).href;
  }

  function urlLogo() {
    var supabase = String(config().supabaseUrl || '').trim().replace(/\/+$/, '');
    if (supabase) return supabase + '/storage/v1/object/public/' + LOGO.dossier + '/' + LOGO.fichier;
    return (racinePublique() || new URL('.', location.href).href) + LOGO.source;
  }

  function preparer(evenement, colis, client) {
    var langue = TEXTES[client.langue] ? client.langue : 'fr';
    var T = TEXTES[langue];
    var base = racinePublique();
    var lien = base ? base + (langue === 'fr' ? '' : langue + '/') + 'mon-compte.html' : '';
    var agence = String(colis.lieu || '').trim();
    var nom = String(client.nom_complet || '').trim() || String(client.code || '');
    var valeurs = { numero: colis.numero, nom: nom, agence: agence, lien: lien };

    var lignes = [
      ['code', client.code],
      ['numero', colis.numero],
      ['expediteur', colis.expediteur],
      ['service', T.services[colis.service] || colis.service],
      ['contenu', colis.description],
      ['suivi', colis.suivi_transporteur],
      ['poids', poids(colis.poids_lb, langue)],
      ['recu', dateHeure(colis.recu_le || colis.cree_le, langue)]
    ].filter(function (l) { return l[1] !== null && l[1] !== undefined && String(l[1]).trim() !== ''; });

    var sujet = remplacer(T.sujet[evenement], valeurs);
    var intro = evenement === 'disponible'
      ? remplacer(agence ? T.intro.disponible : T.intro.disponibleSansAgence, valeurs)
      : T.intro.recu;
    var salutation = remplacer(T.salutation, valeurs);

    // --- E-mail (mise en page en tableaux, compatible avec les messageries) ---
    var C = COULEURS;
    var rangees = lignes.map(function (l) {
      return '<tr><td style="padding:7px 14px;font-size:15px;color:' + C.gris + ';text-align:right;vertical-align:top">' +
        echapper(T.libelles[l[0]]) + '</td><td style="padding:7px 14px;font-size:15px;font-weight:bold;color:' + C.encre +
        ';text-align:left;vertical-align:top">' + echapper(l[1]) + '</td></tr>';
    }).join('');
    var html = '<!doctype html><html lang="' + langue + '"><head><meta charset="utf-8">' +
      '<meta name="viewport" content="width=device-width,initial-scale=1"><title>' + echapper(sujet) + '</title></head>' +
      '<body style="margin:0;padding:0;background:' + C.fond + '">' +
      '<div style="display:none;max-height:0;overflow:hidden;opacity:0">' + echapper(intro) + '</div>' +
      '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:' + C.fond + '"><tr>' +
      '<td align="center" style="padding:28px 12px">' +
      '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#ffffff;' +
      'border-radius:18px;font-family:Arial,Helvetica,sans-serif;color:' + C.encre + '">' +
      '<tr><td align="center" style="padding:32px 24px 26px"><img src="' + echapper(urlLogo()) +
      '" width="190" alt="Goship Express" style="display:block;width:190px;max-width:70%;height:auto;border:0;' +
      'font-family:Arial,Helvetica,sans-serif;font-size:24px;font-weight:bold;color:' + C.encre2 + '"></td></tr>' +
      '<tr><td style="padding:0 32px"><div style="height:3px;line-height:3px;font-size:0;background:' + C.encre2 + '">&nbsp;</div></td></tr>' +
      '<tr><td align="center" style="padding:34px 32px 6px">' +
      '<p style="margin:0;font-size:22px;font-weight:bold;font-style:italic;color:' + C.accent + '">' + echapper(salutation) + '</p>' +
      '<p style="margin:14px 0 0;font-size:17px;line-height:1.55;color:' + C.encre + '">' + echapper(intro) + '</p></td></tr>' +
      '<tr><td align="center" style="padding:18px 20px 6px"><table role="presentation" cellpadding="0" cellspacing="0">' +
      rangees + '</table></td></tr>' +
      (lien
        ? '<tr><td align="center" style="padding:26px 32px 36px"><a href="' + echapper(lien) + '" style="display:inline-block;' +
          'background:' + C.accent + ';color:#ffffff;text-decoration:none;font-weight:bold;font-size:16px;letter-spacing:.02em;' +
          'padding:16px 34px;border-radius:999px">' + echapper(T.bouton) + '</a></td></tr>'
        : '<tr><td style="height:30px;line-height:30px;font-size:0">&nbsp;</td></tr>') +
      '<tr><td style="padding:0 32px"><div style="height:1px;line-height:1px;font-size:0;background:' + C.trait + '">&nbsp;</div></td></tr>' +
      '<tr><td align="center" style="padding:20px 32px 28px;font-size:12.5px;line-height:1.6;color:' + C.gris + '">' +
      echapper(PIED_ADRESSE) + '<br>' + echapper(T.pied) + '</td></tr>' +
      '</table></td></tr></table></body></html>';

    var texte = [salutation, '', intro, ''].concat(lignes.map(function (l) {
      return T.libelles[l[0]] + ' : ' + l[1];
    })).concat(lien ? ['', T.bouton + ' : ' + lien] : []).concat(['', PIED_ADRESSE]).join('\n');
    if (langue === 'en' || langue === 'es') texte = texte.replace(/ : /g, ': ');

    // --- WhatsApp (envoi en un clic depuis votre WhatsApp) ---
    var W = T.whatsapp;
    var titre = evenement === 'disponible'
      ? remplacer(agence ? W.disponible : W.disponibleSansAgence, valeurs)
      : W.recu;
    var separateur = langue === 'en' || langue === 'es' ? ': ' : ' : ';
    var message = [salutation, titre, ''].concat(lignes.map(function (l) {
      return '*' + T.libelles[l[0]] + '*' + separateur + l[1];
    }));
    if (evenement === 'disponible') message.push('', W.retrait);
    message.push('');
    if (lien) message.push(remplacer(W.suivi, valeurs));
    message.push('— Goship Express');
    var whatsapp = message.join('\n');
    var numero = telephoneInternational(client.telephone, client.pays);

    // --- WhatsApp automatique (modèle approuvé par Meta) ---
    var valeur = function (v) { return String(v || '').trim() || '—'; };
    var parametres = evenement === 'disponible'
      ? [valeur(nom), valeur(colis.numero), valeur(agence || 'Goship Express'), valeur(client.code)]
      : [valeur(nom), valeur(colis.numero), valeur(client.code), valeur(colis.description),
         valeur(poids(colis.poids_lb, langue)), valeur(dateHeure(colis.recu_le || colis.cree_le, langue))];

    return {
      langue: langue,
      email: { sujet: sujet, html: html, texte: texte },
      whatsapp: whatsapp,
      lienWhatsApp: numero ? 'https://wa.me/' + numero + '?text=' + encodeURIComponent(whatsapp) : '',
      modele: { nom: MODELES[evenement], langue: LANGUE_MODELE[langue], parametres: parametres }
    };
  }

  window.GoshipNotifications = {
    evenements: ['recu', 'disponible'],
    preparer: preparer,
    telephoneInternational: telephoneInternational,
    logo: LOGO,
    urlLogo: urlLogo
  };
})();
