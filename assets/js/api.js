/* ==========================================================================
   Goship Express — accès aux comptes clients et aux colis
   --------------------------------------------------------------------------
   Une même interface (window.GoshipAPI), trois fonctionnements :
   - « supabase » : adresse et clé Supabase renseignées dans config.js ;
                    comptes et colis sont enregistrés en ligne.
   - « demo »     : sans configuration, sur votre ordinateur (fichier ouvert
                    directement ou localhost). Les données restent dans ce
                    navigateur : de quoi essayer le site avant sa mise en ligne.
   - « off »      : sans configuration, sur un vrai nom de domaine. L'espace
                    client reste fermé (aucun compte fictif).
   ========================================================================== */
(function () {
  'use strict';

  var CFG = window.GOSHIP_CONFIG || {};
  // Bibliothèque Supabase rangée dans le site lui-même : aucun script extérieur ne
  // s'exécute dans les pages des clients (voir README, « Sécurité »).
  // Adresse calculée à partir de ce fichier, pour que /en/, /es/ et /ht/ la trouvent aussi.
  var SUPABASE_JS = (function () {
    var moi = document.currentScript;
    var base = moi && moi.src ? moi.src.replace(/[^/]*$/, '') : 'assets/js/';
    return base + 'vendor/supabase-2.116.0.js';
  })();
  // Ordinateur ou réseau local (fichier ouvert directement, localhost, Wi-Fi de la maison…)
  var LOCAL = location.protocol === 'file:' ||
    /^(localhost|127(\.\d+){3}|\[::1\]|10(\.\d+){3}|192\.168(\.\d+){2}|172\.(1[6-9]|2\d|3[01])(\.\d+){2}|[\w-]+\.local)$/.test(location.hostname);
  var MODE = CFG.supabaseUrl && CFG.supabaseKey ? 'supabase' : (LOCAL ? 'demo' : 'off');
  var LANGUE = (document.documentElement.lang || 'fr').slice(0, 2).toLowerCase();

  var STATUTS = ['recu', 'emballe', 'embarque', 'distribution', 'succursale', 'disponible', 'livre', 'incident'];
  var CHAMPS_PROFIL = ['nom_complet', 'pays', 'region', 'ville', 'adresse', 'telephone', 'langue'];
  var CHAMPS_COLIS = ['client_id', 'suivi_transporteur', 'expediteur', 'description', 'poids_lb', 'service',
                      'pays_destination', 'destination', 'statut', 'lieu', 'note', 'recu_le'];
  var CHAMPS_FACTURE = ['client_id', 'montant_usd', 'statut', 'note', 'lien_paiement', 'moyen', 'echeance_le', 'payee_le'];

  function Erreur(code, detail) {
    var e = new Error(detail || code);
    e.code = code;
    return e;
  }

  function choisir(source, champs) {
    var out = {};
    champs.forEach(function (k) { if (source[k] !== undefined) out[k] = source[k]; });
    return out;
  }

  // Adresse d'une page du site dans la langue courante (même dossier)
  function urlPage(nom) {
    return new URL(nom, location.href).href.split('#')[0];
  }

  // Longueur minimale du mot de passe. 6 est le plancher de Supabase : sa
  // console ne descend pas plus bas, et accepter moins ici ne servirait qu'à
  // laisser passer un mot de passe que le serveur refuserait ensuite.
  // À changer aussi dans les formulaires (minlength) et dans l'application
  // (application-mobile/lib/session.js).
  var MDP_MINIMUM = 6;

  // Code client : « GSE- » suivi de 4 chiffres (gse 4323 -> GSE-4323). Les codes
  // plus longs des versions précédentes restent reconnus tels quels : un ancien
  // client garde le sien. En dessous de 4 chiffres, c'est une saisie incomplète.
  function normaliserCode(code) {
    var n = String(code || '').replace(/\D/g, '');
    if (n.length < 4) return '';
    return 'GSE-' + n;
  }

  // Code tiré au hasard, jamais deux fois le même (comptes de démonstration)
  function nouveauCode(comptes) {
    var code;
    do {
      code = 'GSE-' + (1000 + Math.floor(Math.random() * 9000));
    } while (comptes.some(function (c) { return c.code === code; }));
    return code;
  }

  // Texte de recherche sûr pour les filtres (virgules et parenthèses retirées)
  function nettoyer(texte) {
    return String(texte || '').replace(/[,()*%\\:"']/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 60);
  }

  function trierHistorique(colis) {
    colis.historique = (colis.historique || colis.colis_historique || []).slice().sort(function (a, b) {
      return new Date(a.cree_le) - new Date(b.cree_le);
    });
    delete colis.colis_historique;
    return colis;
  }

  /* ======================================================================
     Supabase
     ====================================================================== */
  var promesseClient = null;

  function chargerScript(src) {
    return new Promise(function (ok, ko) {
      var s = document.createElement('script');
      s.src = src;
      s.async = true;
      s.onload = ok;
      s.onerror = function () { s.remove(); ko(Erreur('reseau')); };
      document.head.appendChild(s);
    });
  }

  function sb() {
    if (!promesseClient) {
      promesseClient = (window.supabase && window.supabase.createClient ? Promise.resolve() : chargerScript(SUPABASE_JS))
        .then(function () {
          if (!window.supabase || !window.supabase.createClient) throw Erreur('reseau');
          // flowType « implicit » : le lien reçu par e-mail fonctionne même ouvert sur
          // un autre appareil que celui qui l'a demandé (téléphone → ordinateur).
          // Les jetons qu'il dépose dans l'adresse sont effacés aussitôt (nettoyerAdresse).
          return window.supabase.createClient(String(CFG.supabaseUrl).replace(/\/+$/, ''), CFG.supabaseKey, {
            auth: { flowType: 'implicit', persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
          });
        });
      promesseClient.catch(function () { promesseClient = null; });
    }
    return promesseClient;
  }

  // Les liens reçus par e-mail (confirmation, nouveau mot de passe) déposent les
  // jetons de session dans l'adresse de la page (#access_token=…). Une fois la
  // session enregistrée, ils n'ont plus rien à y faire : on les efface de la barre
  // d'adresse et de l'historique du navigateur.
  function nettoyerAdresse() {
    if (!/(access_token|refresh_token|provider_token)=/.test(location.hash)) return;
    try { history.replaceState(null, '', location.pathname + location.search); } catch (e) {}
  }

  function erreurSupabase(e) {
    if (!e) return Erreur('inconnu');
    if (e.code && /^(identifiants|email-existe|reseau|non-autorise)$/.test(e.code)) return e;
    var code = String(e.code || ''), msg = String(e.message || '').toLowerCase(), statut = e.status;
    if (code === 'invalid_credentials' || msg.indexOf('invalid login') >= 0) return Erreur('identifiants');
    if (code === 'user_already_exists' || code === 'email_exists' || msg.indexOf('already registered') >= 0) return Erreur('email-existe');
    if (code === 'same_password' || msg.indexOf('different from the old') >= 0) return Erreur('meme-mot-de-passe');
    if (code === 'weak_password' || msg.indexOf('password should') >= 0) return Erreur('mot-de-passe-faible');
    if (code === 'email_address_invalid' || code === 'validation_failed' || msg.indexOf('invalid format') >= 0) return Erreur('email-invalide');
    if (code === 'email_not_confirmed' || msg.indexOf('not confirmed') >= 0) return Erreur('non-confirme');
    if (code === 'signup_disabled' || code === 'email_provider_disabled') return Erreur('inscriptions-fermees');
    if (statut === 429 || code.indexOf('rate_limit') >= 0) return Erreur('trop-de-tentatives');
    if (code === 'otp_expired' || code === 'session_not_found' || code === 'session_expired') return Erreur('lien-invalide');
    if (code === '42501' || code === 'PGRST301' || statut === 401 || statut === 403) return Erreur('non-autorise');
    if (e.name === 'TypeError' || msg.indexOf('failed to fetch') >= 0 || msg.indexOf('network') >= 0 ||
        msg.indexOf('load failed') >= 0) return Erreur('reseau');
    return Erreur('inconnu', e.message);
  }

  function resultat(res) {
    if (res.error) throw erreurSupabase(res.error);
    return res.data;
  }

  var supabaseAPI = {
    session: function () {
      return sb().then(function (c) { return c.auth.getSession(); }).then(function (res) {
        nettoyerAdresse();
        var s = res.data && res.data.session;
        return s ? { id: s.user.id, email: s.user.email } : null;
      });
    },

    profil: function () {
      return supabaseAPI.session().then(function (s) {
        if (!s) return null;
        return sb().then(function (c) {
          return c.from('clients').select('*').eq('id', s.id).maybeSingle();
        }).then(resultat);
      });
    },

    inscrire: function (d) {
      var client;
      return sb().then(function (c) {
        client = c;
        return c.auth.signUp({
          email: d.email,
          password: d.motDePasse,
          options: {
            data: {
              nom_complet: d.nom_complet, pays: d.pays, region: d.region, ville: d.ville,
              adresse: d.adresse, telephone: d.telephone, langue: LANGUE
            },
            emailRedirectTo: urlPage('mon-compte.html')
          }
        });
      }).then(function (res) {
        if (res.error) throw erreurSupabase(res.error);
        var u = res.data.user;
        // Adresse déjà inscrite (réponse volontairement neutre de Supabase)
        if (u && Array.isArray(u.identities) && u.identities.length === 0) throw Erreur('email-existe');
        if (!res.data.session) return { profil: null, confirmation: true };
        return client.from('clients').select('*').eq('id', u.id).maybeSingle().then(resultat).then(function (p) {
          return { profil: p, confirmation: false };
        });
      });
    },

    connecter: function (email, motDePasse) {
      return sb().then(function (c) {
        return c.auth.signInWithPassword({ email: email, password: motDePasse });
      }).then(function (res) {
        if (res.error) throw erreurSupabase(res.error);
        return supabaseAPI.profil();
      });
    },

    deconnecter: function () {
      return sb().then(function (c) { return c.auth.signOut({ scope: 'local' }); });
    },

    envoyerLienMotDePasse: function (email) {
      return sb().then(function (c) {
        return c.auth.resetPasswordForEmail(email, { redirectTo: urlPage('nouveau-mot-de-passe.html') });
      }).then(resultat).then(function () { return {}; });
    },

    // Page « Nouveau mot de passe » : vrai si le lien reçu par e-mail est valide
    attendreRecuperation: function () {
      var h = location.hash + location.search;
      if (/error_code=|error=/.test(h)) return Promise.resolve(false);
      return supabaseAPI.session().then(function (s) { return !!s; });
    },

    changerMotDePasse: function (motDePasse) {
      return sb().then(function (c) {
        return c.auth.updateUser({ password: motDePasse });
      }).then(resultat).then(function () { return true; });
    },

    modifierProfil: function (champs) {
      return supabaseAPI.session().then(function (s) {
        if (!s) throw Erreur('non-autorise');
        return sb().then(function (c) {
          return c.from('clients').update(choisir(champs, CHAMPS_PROFIL)).eq('id', s.id).select().single();
        }).then(resultat);
      });
    },

    mesColis: function () {
      return supabaseAPI.session().then(function (s) {
        if (!s) throw Erreur('non-autorise');
        return sb().then(function (c) {
          return c.from('colis')
            .select('id, numero, suivi_transporteur, expediteur, description, poids_lb, service, pays_destination, ' +
                    'destination, statut, lieu, note, recu_le, cree_le, maj_le, colis_historique(statut, lieu, note, cree_le)')
            .eq('client_id', s.id)
            .order('maj_le', { ascending: false });
        }).then(resultat).then(function (lignes) { return lignes.map(trierHistorique); });
      });
    },

    // Mises à jour en direct. options.tout : tous les colis et clients (administrateur)
    surveiller: function (rappel, options) {
      options = options || {};
      var canal = null, arrete = false;
      Promise.all([sb(), supabaseAPI.session()]).then(function (r) {
        var c = r[0], s = r[1];
        if (arrete || !s) return;
        var filtre = { event: '*', schema: 'public', table: 'colis' };
        if (!options.tout) filtre.filter = 'client_id=eq.' + s.id;
        canal = c.channel('gse-' + Math.random().toString(36).slice(2))
          .on('postgres_changes', filtre, function () { rappel('colis'); });
        if (options.tout) {
          canal.on('postgres_changes', { event: '*', schema: 'public', table: 'clients' }, function () { rappel('clients'); });
        }
        canal.subscribe(function (etat) {
          if (options.etat) options.etat(etat === 'SUBSCRIBED');
        });
      }).catch(function () { if (options.etat) options.etat(false); });
      return function () {
        arrete = true;
        if (canal) sb().then(function (c) { c.removeChannel(canal); });
      };
    },

    suivre: function (numero) {
      return sb().then(function (c) {
        return c.rpc('suivre_colis', { p_numero: String(numero || '').trim() });
      }).then(resultat).then(function (d) { return d ? trierHistorique(d) : null; });
    },

    estAdmin: function () {
      return sb().then(function (c) { return c.rpc('est_admin'); }).then(resultat).then(Boolean);
    },

    admin: {
      statistiques: function () {
        return sb().then(function (c) { return c.rpc('statistiques_admin'); }).then(resultat);
      },

      colis: function (o) {
        o = o || {};
        var parPage = o.parPage || 50, page = o.page || 0;
        return sb().then(function (c) {
          var q = c.from('colis_details').select('*', { count: 'exact' })
            .order('maj_le', { ascending: false })
            .range(page * parPage, page * parPage + parPage - 1);
          if (o.statut === 'actifs') q = q.neq('statut', 'livre');
          else if (o.statut) q = q.eq('statut', o.statut);
          if (o.clientId) q = q.eq('client_id', o.clientId);
          var t = nettoyer(o.recherche);
          if (t) {
            q = q.or(['numero', 'suivi_transporteur', 'code_client', 'nom_client', 'telephone_client', 'description', 'destination']
              .map(function (k) { return k + '.ilike."*' + t + '*"'; }).join(','));
          }
          return q;
        }).then(function (res) {
          if (res.error) throw erreurSupabase(res.error);
          return { lignes: res.data, total: res.count || 0 };
        });
      },

      historique: function (id) {
        return sb().then(function (c) {
          return c.from('colis_historique').select('statut, lieu, note, cree_le').eq('colis_id', id)
            .order('cree_le', { ascending: true });
        }).then(resultat);
      },

      chercherClient: function (code) {
        var n = normaliserCode(code);
        if (!n) return Promise.resolve(null);
        return sb().then(function (c) {
          return c.from('clients').select('id, code, nom_complet, pays, region, ville, telephone, email, langue')
            .eq('code', n).maybeSingle();
        }).then(resultat);
      },

      clients: function (o) {
        o = o || {};
        var parPage = o.parPage || 50, page = o.page || 0;
        return sb().then(function (c) {
          var q = c.from('clients').select('*', { count: 'exact' }).eq('role', 'client')
            .order('cree_le', { ascending: false })
            .range(page * parPage, page * parPage + parPage - 1);
          var t = nettoyer(o.recherche);
          if (t) {
            q = q.or(['code', 'nom_complet', 'telephone', 'email', 'ville', 'region']
              .map(function (k) { return k + '.ilike."*' + t + '*"'; }).join(','));
          }
          return q;
        }).then(function (res) {
          if (res.error) throw erreurSupabase(res.error);
          return { lignes: res.data, total: res.count || 0 };
        });
      },

      creerColis: function (d) {
        return sb().then(function (c) {
          return c.from('colis').insert(choisir(d, CHAMPS_COLIS)).select().single();
        }).then(resultat);
      },

      modifierColis: function (id, champs) {
        return sb().then(function (c) {
          return c.from('colis').update(choisir(champs, CHAMPS_COLIS)).eq('id', id).select().single();
        }).then(resultat);
      },

      changerStatut: function (ids, etape) {
        return sb().then(function (c) {
          return c.from('colis').update({ statut: etape.statut, lieu: etape.lieu || '', note: etape.note || '' })
            .in('id', ids).select('id');
        }).then(resultat).then(function (lignes) { return lignes.length; });
      },

      supprimerColis: function (id) {
        return sb().then(function (c) { return c.from('colis').delete().eq('id', id); }).then(resultat);
      },

      // Notifications : la base envoie le message au client du colis avec les
      // clés enregistrées dans Supabase ; réponse « envoye », « non-configure »…
      envoyerEmail: function (id, evenement, message) {
        return sb().then(function (c) {
          return c.rpc('envoyer_email_client', {
            p_colis: id, p_evenement: evenement, p_sujet: message.sujet, p_html: message.html, p_texte: message.texte
          });
        }).then(resultat);
      },

      envoyerWhatsApp: function (id, evenement, modele) {
        return sb().then(function (c) {
          return c.rpc('envoyer_whatsapp_client', {
            p_colis: id, p_evenement: evenement, p_modele: modele.nom, p_langue: modele.langue, p_parametres: modele.parametres
          });
        }).then(resultat);
      },

      notifications: function (id) {
        return sb().then(function (c) { return c.rpc('notifications_colis', { p_colis: id }); }).then(resultat);
      },

      /* ---- Factures ---------------------------------------------------- */

      factures: function (o) {
        o = o || {};
        var parPage = o.parPage || 50, page = o.page || 0;
        return sb().then(function (c) {
          var q = c.from('factures')
            .select('*, clients(code, nom_complet, telephone, langue), facture_lignes(id, colis_id, libelle, montant_usd)',
                    { count: 'exact' })
            .order('cree_le', { ascending: false })
            .range(page * parPage, page * parPage + parPage - 1);
          if (o.statut) q = q.eq('statut', o.statut);
          if (o.client_id) q = q.eq('client_id', o.client_id);
          return q;
        }).then(function (res) {
          if (res.error) throw erreurSupabase(res.error);
          return { lignes: res.data, total: res.count || 0 };
        });
      },

      creerFacture: function (d, lignes) {
        var facture;
        return sb().then(function (c) {
          return c.from('factures').insert(choisir(d, CHAMPS_FACTURE)).select().single();
        }).then(resultat).then(function (f) {
          facture = f;
          if (!lignes || !lignes.length) return null;
          return sb().then(function (c) {
            return c.from('facture_lignes').insert(lignes.map(function (l) {
              return { facture_id: f.id, colis_id: l.colis_id || null, libelle: l.libelle || '', montant_usd: l.montant_usd || 0 };
            }));
          }).then(resultat);
        }).then(function () { return facture; });
      },

      modifierFacture: function (id, champs) {
        return sb().then(function (c) {
          return c.from('factures').update(choisir(champs, CHAMPS_FACTURE)).eq('id', id).select().single();
        }).then(resultat);
      },

      supprimerFacture: function (id) {
        return sb().then(function (c) { return c.from('factures').delete().eq('id', id); }).then(resultat);
      },

      // Copie le logo des e-mails dans le dossier public de Supabase s'il n'y est pas encore
      preparerLogo: function (logo) {
        var publique = String(CFG.supabaseUrl).replace(/\/+$/, '') + '/storage/v1/object/public/' +
          logo.dossier + '/' + logo.fichier;
        return fetch(publique, { method: 'HEAD', cache: 'no-store' }).then(function (r) {
          if (r.ok) return 'present';
          return fetch(logo.source).then(function (image) {
            if (!image.ok) throw Erreur('inconnu', 'fichier ' + logo.source + ' introuvable');
            return image.blob();
          }).then(function (image) {
            return sb().then(function (c) {
              return c.storage.from(logo.dossier).upload(logo.fichier, image,
                { upsert: true, contentType: 'image/png', cacheControl: '604800' });
            });
          }).then(function (res) {
            if (res.error) throw Erreur('inconnu', res.error.message);
            return 'envoye';
          });
        });
      }
    }
  };

  /* ======================================================================
     Démonstration (données dans ce navigateur uniquement)
     ====================================================================== */
  var CLE_DONNEES = 'gse-demo-donnees';
  var CLE_SESSION = 'gse-demo-session';
  var CLE_RECUP = 'gse-demo-recuperation';
  var ADMIN_DEMO = { email: 'admin@goship.demo', motDePasse: 'demo1234' };
  var abonnes = [];

  // Stockage du navigateur ; s'il est bloqué (fichier ouvert directement dans Safari,
  // navigation privée…), les données restent dans la mémoire de la page.
  var memoire = {};
  var stockageBloque = false;
  function stockage(action, cle, valeur) {
    if (!stockageBloque) {
      try {
        if (action === 'lire') return localStorage.getItem(cle);
        if (action === 'ecrire') localStorage.setItem(cle, valeur);
        if (action === 'effacer') localStorage.removeItem(cle);
        return null;
      } catch (e) {
        stockageBloque = true;
      }
    }
    if (action === 'lire') return Object.prototype.hasOwnProperty.call(memoire, cle) ? memoire[cle] : null;
    if (action === 'ecrire') memoire[cle] = String(valeur);
    if (action === 'effacer') delete memoire[cle];
    return null;
  }

  function empreinte(texte) {
    // Démonstration uniquement : les vrais mots de passe sont gérés par Supabase.
    var h = 2166136261;
    var s = 'goship-demo:' + texte;
    for (var i = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i);
      h = Math.imul(h, 16777619) >>> 0;
    }
    return h.toString(16);
  }

  function identifiant() {
    return 'd' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
  }

  function maintenant() { return new Date().toISOString(); }

  function nouvellesDonnees() {
    return {
      v: 1, seqColis: 1000,
      comptes: [{
        id: 'admin-demo', email: ADMIN_DEMO.email, mdp: empreinte(ADMIN_DEMO.motDePasse), role: 'admin', code: null,
        nom_complet: 'Équipe Goship Express', pays: 'US', region: 'Florida', ville: 'Medley',
        adresse: '8140 NW 74th Ave, Unit 3', telephone: '+1 849 538-6262', langue: 'fr', cree_le: maintenant()
      }],
      colis: [],
      historique: []
    };
  }

  function lireDonnees() {
    try {
      var d = JSON.parse(stockage('lire', CLE_DONNEES));
      if (d && d.v === 1) return d;
    } catch (e) { /* données illisibles : on repart de zéro */ }
    return nouvellesDonnees();
  }

  function ecrireDonnees(d) {
    stockage('ecrire', CLE_DONNEES, JSON.stringify(d));
    prevenir('colis');
  }

  function prevenir(quoi) {
    abonnes.slice().forEach(function (a) { a(quoi); });
  }

  window.addEventListener('storage', function (e) {
    if (e.key === CLE_DONNEES) prevenir('colis');
  });

  // Délai d'un vrai serveur, pour voir les états de chargement
  function plusTard(valeur) {
    return new Promise(function (ok) { setTimeout(function () { ok(valeur); }, 180 + Math.random() * 220); });
  }
  function echec(code) {
    return new Promise(function (ok, ko) { setTimeout(function () { ko(Erreur(code)); }, 220); });
  }

  function publicProfil(compte) {
    if (!compte) return null;
    var p = {};
    Object.keys(compte).forEach(function (k) { if (k !== 'mdp') p[k] = compte[k]; });
    return p;
  }

  function compteConnecte(d) {
    var id = stockage('lire', CLE_SESSION);
    if (!id) return null;
    for (var i = 0; i < d.comptes.length; i++) if (d.comptes[i].id === id) return d.comptes[i];
    return null;
  }

  function trouverCompte(d, email) {
    email = String(email || '').trim().toLowerCase();
    for (var i = 0; i < d.comptes.length; i++) if (d.comptes[i].email === email) return d.comptes[i];
    return null;
  }

  function avecHistorique(d, c) {
    var x = JSON.parse(JSON.stringify(c));
    x.historique = d.historique.filter(function (h) { return h.colis_id === c.id; })
      .map(function (h) { return { statut: h.statut, lieu: h.lieu, note: h.note, cree_le: h.cree_le }; });
    return trierHistorique(x);
  }

  function detailsColis(d, c) {
    var x = JSON.parse(JSON.stringify(c));
    var cl = null;
    for (var i = 0; i < d.comptes.length; i++) if (d.comptes[i].id === c.client_id) cl = d.comptes[i];
    x.code_client = cl ? cl.code : null;
    x.nom_client = cl ? cl.nom_complet : null;
    x.telephone_client = cl ? cl.telephone : null;
    x.email_client = cl ? cl.email : null;
    x.ville_client = cl ? cl.ville : null;
    x.pays_client = cl ? cl.pays : null;
    x.langue_client = cl ? cl.langue : null;
    return x;
  }

  function historiser(d, c, date) {
    d.historique.push({ colis_id: c.id, statut: c.statut, lieu: c.lieu || '', note: c.note || '', cree_le: date || maintenant() });
  }

  function exigerAdmin(d) {
    var moi = compteConnecte(d);
    if (!moi || moi.role !== 'admin') throw Erreur('non-autorise');
    return moi;
  }

  function contient(valeurs, texte) {
    texte = texte.toLowerCase();
    return valeurs.some(function (v) { return v && String(v).toLowerCase().indexOf(texte) >= 0; });
  }

  function page(lignes, o) {
    var parPage = o.parPage || 50, p = o.page || 0;
    return { lignes: lignes.slice(p * parPage, p * parPage + parPage), total: lignes.length };
  }

  var demoAPI = {
    identifiantsAdmin: ADMIN_DEMO,

    session: function () {
      var moi = compteConnecte(lireDonnees());
      return plusTard(moi ? { id: moi.id, email: moi.email } : null);
    },

    profil: function () {
      return plusTard(publicProfil(compteConnecte(lireDonnees())));
    },

    inscrire: function (x) {
      var d = lireDonnees();
      var email = String(x.email || '').trim().toLowerCase();
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return echec('email-invalide');
      if (trouverCompte(d, email)) return echec('email-existe');
      if (String(x.motDePasse || '').length < MDP_MINIMUM) return echec('mot-de-passe-faible');
      var compte = {
        id: identifiant(), email: email, mdp: empreinte(x.motDePasse), role: 'client', code: nouveauCode(d.comptes),
        nom_complet: x.nom_complet, pays: x.pays, region: x.region, ville: x.ville, adresse: x.adresse,
        telephone: x.telephone, langue: LANGUE, cree_le: maintenant()
      };
      d.comptes.push(compte);
      ecrireDonnees(d);
      stockage('ecrire', CLE_SESSION, compte.id);
      return plusTard({ profil: publicProfil(compte), confirmation: false });
    },

    connecter: function (email, motDePasse) {
      var compte = trouverCompte(lireDonnees(), email);
      if (!compte || compte.mdp !== empreinte(motDePasse)) return echec('identifiants');
      stockage('ecrire', CLE_SESSION, compte.id);
      return plusTard(publicProfil(compte));
    },

    deconnecter: function () {
      stockage('effacer', CLE_SESSION);
      return plusTard(true);
    },

    // En démonstration, aucun e-mail n'est envoyé : le lien est affiché à l'écran.
    envoyerLienMotDePasse: function (email) {
      var compte = trouverCompte(lireDonnees(), email);
      if (!compte) return plusTard({});
      var jeton = Math.random().toString(36).slice(2, 12);
      stockage('ecrire', CLE_RECUP, JSON.stringify({ id: compte.id, jeton: jeton, expire: Date.now() + 3600e3 }));
      return plusTard({ lienDemo: 'nouveau-mot-de-passe.html#recuperation=' + jeton });
    },

    attendreRecuperation: function () {
      var m = /recuperation=([a-z0-9]+)/.exec(location.hash);
      var r = null;
      try { r = JSON.parse(stockage('lire', CLE_RECUP)); } catch (e) { r = null; }
      if (m && r && r.jeton === m[1] && r.expire > Date.now()) {
        stockage('ecrire', CLE_SESSION, r.id);
        stockage('effacer', CLE_RECUP);
        return plusTard(true);
      }
      return plusTard(!!compteConnecte(lireDonnees()));
    },

    changerMotDePasse: function (motDePasse) {
      var d = lireDonnees();
      var moi = compteConnecte(d);
      if (!moi) return echec('lien-invalide');
      if (String(motDePasse).length < MDP_MINIMUM) return echec('mot-de-passe-faible');
      if (moi.mdp === empreinte(motDePasse)) return echec('meme-mot-de-passe');
      moi.mdp = empreinte(motDePasse);
      ecrireDonnees(d);
      return plusTard(true);
    },

    modifierProfil: function (champs) {
      var d = lireDonnees();
      var moi = compteConnecte(d);
      if (!moi) return echec('non-autorise');
      var c = choisir(champs, CHAMPS_PROFIL);
      Object.keys(c).forEach(function (k) { moi[k] = c[k]; });
      ecrireDonnees(d);
      return plusTard(publicProfil(moi));
    },

    mesColis: function () {
      var d = lireDonnees();
      var moi = compteConnecte(d);
      if (!moi) return echec('non-autorise');
      var lignes = d.colis.filter(function (c) { return c.client_id === moi.id; })
        .sort(function (a, b) { return new Date(b.maj_le) - new Date(a.maj_le); })
        .map(function (c) { return avecHistorique(d, c); });
      return plusTard(lignes);
    },

    surveiller: function (rappel, options) {
      options = options || {};
      abonnes.push(rappel);
      if (options.etat) setTimeout(function () { options.etat(true); }, 300);
      return function () { abonnes = abonnes.filter(function (a) { return a !== rappel; }); };
    },

    suivre: function (numero) {
      var d = lireDonnees();
      var n = String(numero || '').trim().toUpperCase();
      if (n.length < 4) return plusTard(null);
      var c = d.colis.filter(function (x) { return x.numero === n || (x.suivi_transporteur && x.suivi_transporteur === n); })[0];
      if (!c) return plusTard(null);
      var x = avecHistorique(d, c);
      return plusTard({
        numero: x.numero, statut: x.statut, service: x.service, pays_destination: x.pays_destination, maj_le: x.maj_le,
        historique: x.historique.map(function (h) { return { statut: h.statut, lieu: h.lieu, cree_le: h.cree_le }; })
      });
    },

    estAdmin: function () {
      var moi = compteConnecte(lireDonnees());
      return plusTard(!!(moi && moi.role === 'admin'));
    },

    admin: {
      statistiques: function () {
        var d = lireDonnees();
        try { exigerAdmin(d); } catch (e) { return echec(e.code); }
        var statuts = {}, livres30 = 0, limite = Date.now() - 30 * 864e5;
        d.colis.forEach(function (c) {
          statuts[c.statut] = (statuts[c.statut] || 0) + 1;
          if (c.statut === 'livre' && new Date(c.maj_le).getTime() > limite) livres30 += 1;
        });
        var clients = d.comptes.filter(function (c) { return c.role === 'client'; }).length;
        return plusTard({ clients: clients, statuts: statuts, livres_30j: livres30 });
      },

      colis: function (o) {
        o = o || {};
        var d = lireDonnees();
        try { exigerAdmin(d); } catch (e) { return echec(e.code); }
        var t = nettoyer(o.recherche);
        var lignes = d.colis.map(function (c) { return detailsColis(d, c); }).filter(function (c) {
          if (o.statut === 'actifs' && c.statut === 'livre') return false;
          if (o.statut && o.statut !== 'actifs' && c.statut !== o.statut) return false;
          if (o.clientId && c.client_id !== o.clientId) return false;
          if (t && !contient([c.numero, c.suivi_transporteur, c.code_client, c.nom_client, c.telephone_client,
                              c.description, c.destination], t)) return false;
          return true;
        }).sort(function (a, b) { return new Date(b.maj_le) - new Date(a.maj_le); });
        return plusTard(page(lignes, o));
      },

      historique: function (id) {
        var d = lireDonnees();
        try { exigerAdmin(d); } catch (e) { return echec(e.code); }
        var c = d.colis.filter(function (x) { return x.id === id; })[0];
        return plusTard(c ? avecHistorique(d, c).historique : []);
      },

      chercherClient: function (code) {
        var d = lireDonnees();
        try { exigerAdmin(d); } catch (e) { return echec(e.code); }
        var n = normaliserCode(code);
        var c = d.comptes.filter(function (x) { return n && x.code === n; })[0];
        return plusTard(c ? choisir(publicProfil(c), ['id', 'code', 'nom_complet', 'pays', 'region', 'ville', 'telephone', 'email', 'langue']) : null);
      },

      clients: function (o) {
        o = o || {};
        var d = lireDonnees();
        try { exigerAdmin(d); } catch (e) { return echec(e.code); }
        var t = nettoyer(o.recherche);
        var lignes = d.comptes.filter(function (c) {
          return c.role === 'client' && (!t || contient([c.code, c.nom_complet, c.telephone, c.email, c.ville, c.region], t));
        }).sort(function (a, b) { return new Date(b.cree_le) - new Date(a.cree_le); }).map(publicProfil);
        return plusTard(page(lignes, o));
      },

      creerColis: function (x) {
        var d = lireDonnees();
        try { exigerAdmin(d); } catch (e) { return echec(e.code); }
        d.seqColis += 1;
        var c = choisir(x, CHAMPS_COLIS);
        c.id = identifiant();
        c.numero = 'GSE-' + d.seqColis + '-' + (c.pays_destination || 'HT');
        c.suivi_transporteur = String(c.suivi_transporteur || '').trim().toUpperCase();
        c.expediteur = c.expediteur || '';
        c.cree_le = c.maj_le = maintenant();
        c.recu_le = c.recu_le || c.cree_le;
        d.colis.push(c);
        historiser(d, c, c.recu_le);
        ecrireDonnees(d);
        return plusTard(detailsColis(d, c));
      },

      modifierColis: function (id, champs) {
        var d = lireDonnees();
        try { exigerAdmin(d); } catch (e) { return echec(e.code); }
        var c = d.colis.filter(function (x) { return x.id === id; })[0];
        if (!c) return echec('inconnu');
        var avant = { statut: c.statut, lieu: c.lieu, note: c.note };
        var m = choisir(champs, CHAMPS_COLIS);
        Object.keys(m).forEach(function (k) { c[k] = m[k]; });
        c.suivi_transporteur = String(c.suivi_transporteur || '').trim().toUpperCase();
        c.maj_le = maintenant();
        if (c.statut !== avant.statut || c.lieu !== avant.lieu || c.note !== avant.note) historiser(d, c);
        ecrireDonnees(d);
        return plusTard(detailsColis(d, c));
      },

      changerStatut: function (ids, etape) {
        var d = lireDonnees();
        try { exigerAdmin(d); } catch (e) { return echec(e.code); }
        var n = 0;
        d.colis.forEach(function (c) {
          if (ids.indexOf(c.id) < 0) return;
          var change = c.statut !== etape.statut || c.lieu !== (etape.lieu || '') || c.note !== (etape.note || '');
          c.statut = etape.statut;
          c.lieu = etape.lieu || '';
          c.note = etape.note || '';
          c.maj_le = maintenant();
          if (change) historiser(d, c);
          n += 1;
        });
        ecrireDonnees(d);
        return plusTard(n);
      },

      supprimerColis: function (id) {
        var d = lireDonnees();
        try { exigerAdmin(d); } catch (e) { return echec(e.code); }
        d.colis = d.colis.filter(function (c) { return c.id !== id; });
        d.historique = d.historique.filter(function (h) { return h.colis_id !== id; });
        d.notifications = (d.notifications || []).filter(function (n) { return n.colis_id !== id; });
        ecrireDonnees(d);
        return plusTard(true);
      },

      // En démonstration, rien n'est envoyé : l'e-mail est seulement noté (aperçu
      // dans le tableau de bord) et WhatsApp passe par l'envoi en un clic.
      envoyerEmail: function (id, evenement) {
        var d = lireDonnees();
        try { exigerAdmin(d); } catch (e) { return echec(e.code); }
        var c = detailsColis(d, d.colis.filter(function (x) { return x.id === id; })[0] || {});
        d.notifications = d.notifications || [];
        d.notifications.push({ colis_id: id, canal: 'email', evenement: evenement, destinataire: c.email_client || '',
                               envoye_le: maintenant(), code_http: null, erreur: null });
        ecrireDonnees(d);
        return plusTard('demo');
      },

      envoyerWhatsApp: function () {
        return plusTard('non-configure');
      },

      preparerLogo: function () {
        return plusTard('demo');
      },

      /* ---- Factures (démonstration) ------------------------------------ */

      factures: function (o) {
        o = o || {};
        var d = lireDonnees();
        try { exigerAdmin(d); } catch (e) { return echec(e.code); }
        var lignes = (d.factures || []).slice().sort(function (a, b) {
          return new Date(b.cree_le) - new Date(a.cree_le);
        });
        if (o.statut) lignes = lignes.filter(function (f) { return f.statut === o.statut; });
        if (o.client_id) lignes = lignes.filter(function (f) { return f.client_id === o.client_id; });
        lignes = lignes.map(function (f) {
          var client = (d.comptes || []).filter(function (c) { return c.id === f.client_id; })[0];
          return Object.assign({}, f, {
            clients: client ? { code: client.code, nom_complet: client.nom_complet,
                                telephone: client.telephone, langue: client.langue } : null
          });
        });
        return plusTard({ lignes: lignes, total: lignes.length });
      },

      creerFacture: function (champs, lignesFacture) {
        var d = lireDonnees();
        try { exigerAdmin(d); } catch (e) { return echec(e.code); }
        d.factures = d.factures || [];
        d.numeroFacture = (d.numeroFacture || 0) + 1;
        var f = Object.assign({
          id: 'fac-' + d.numeroFacture,
          numero: 'FAC-' + new Date().getFullYear() + '-' + String(d.numeroFacture).padStart(4, '0'),
          statut: 'a_payer', note: '', lien_paiement: '', moyen: '', echeance_le: null,
          cree_le: maintenant(), payee_le: null,
          facture_lignes: (lignesFacture || []).map(function (l, i) {
            return { id: i + 1, colis_id: l.colis_id || null, libelle: l.libelle || '', montant_usd: l.montant_usd || 0 };
          })
        }, choisir(champs, CHAMPS_FACTURE));
        d.factures.push(f);
        ecrireDonnees(d);
        return plusTard(f);
      },

      modifierFacture: function (id, champs) {
        var d = lireDonnees();
        try { exigerAdmin(d); } catch (e) { return echec(e.code); }
        var f = (d.factures || []).filter(function (x) { return x.id === id; })[0];
        if (!f) return echec('inconnu');
        Object.assign(f, choisir(champs, CHAMPS_FACTURE));
        if (f.statut === 'payee' && !f.payee_le) f.payee_le = maintenant();
        ecrireDonnees(d);
        return plusTard(f);
      },

      supprimerFacture: function (id) {
        var d = lireDonnees();
        try { exigerAdmin(d); } catch (e) { return echec(e.code); }
        d.factures = (d.factures || []).filter(function (x) { return x.id !== id; });
        ecrireDonnees(d);
        return plusTard(true);
      },

      notifications: function (id) {
        var d = lireDonnees();
        try { exigerAdmin(d); } catch (e) { return echec(e.code); }
        return plusTard((d.notifications || []).filter(function (n) { return n.colis_id === id; })
          .sort(function (a, b) { return new Date(b.envoye_le) - new Date(a.envoye_le); }));
      },

      // Clients et colis d'exemple, pour découvrir le tableau de bord
      exemples: function () {
        var d = lireDonnees();
        try { exigerAdmin(d); } catch (e) { return echec(e.code); }
        var jour = 864e5, t0 = Date.now();
        function date(joursAvant, heures) { return new Date(t0 - joursAvant * jour + (heures || 0) * 36e5).toISOString(); }
        var modeles = [
          { nom: 'Marie-Ange Dorvil', email: 'marie-ange@exemple.com', pays: 'HT', region: 'Ouest', ville: 'Pétion-Ville',
            adresse: 'Rue Grégoire #14', tel: '+509 3712 4580' },
          { nom: 'Jean-Robert Pierre', email: 'jean-robert@exemple.com', pays: 'HT', region: 'Nord', ville: 'Cap-Haïtien',
            adresse: 'Rue 15 B, Carénage', tel: '+509 4420 1187' },
          { nom: 'Carolina Méndez', email: 'carolina@exemple.com', pays: 'DO', region: 'Santiago', ville: 'Santiago de los Caballeros',
            adresse: 'Calle del Sol 58', tel: '+1 809 555 0147' }
        ];
        var ids = modeles.map(function (m) {
          var existant = trouverCompte(d, m.email);
          if (existant) return existant.id;
          var c = { id: identifiant(), email: m.email, mdp: empreinte('demo1234'), role: 'client', code: nouveauCode(d.comptes),
                    nom_complet: m.nom, pays: m.pays, region: m.region, ville: m.ville, adresse: m.adresse, telephone: m.tel,
                    langue: 'fr', cree_le: date(20) };
          d.comptes.push(c);
          return c.id;
        });
        var parcours = [
          { client: 0, desc: 'Chaussures Nike — 2 paires', exp: 'Amazon', suivi: 'TBA304918577000', poids: 4.2, service: 'aerien', etapes: [['recu', 6, 'Miami (Medley), FL'], ['emballe', 5, 'Miami (Medley), FL'], ['embarque', 4, 'Miami → Port-au-Prince'], ['distribution', 2, 'Port-au-Prince'], ['succursale', 1, 'Agence de Pétion-Ville'], ['disponible', 0, 'Agence de Pétion-Ville', 'Retrait possible du lundi au samedi, de 8 h à 18 h.']] },
          { client: 0, desc: 'Téléphone Samsung Galaxy A55', exp: 'Walmart', suivi: '9400111899223344556677', poids: 1.1, service: 'aerien', etapes: [['recu', 1, 'Miami (Medley), FL']] },
          { client: 0, desc: 'Vêtements', exp: 'SHEIN', suivi: 'GFUS01072196252801', poids: 2.6, service: 'aerien', etapes: [['recu', 16, 'Miami (Medley), FL'], ['embarque', 14, 'Miami → Port-au-Prince'], ['distribution', 12, 'Port-au-Prince'], ['succursale', 11, 'Agence de Pétion-Ville'], ['disponible', 11, 'Agence de Pétion-Ville'], ['livre', 10, 'Pétion-Ville', 'Remis en main propre.']] },
          { client: 1, desc: 'Pièces auto (amortisseurs)', exp: 'RockAuto', suivi: '1Z999AA10123456784', poids: 18, service: 'maritime', etapes: [['recu', 9, 'Miami (Medley), FL'], ['embarque', 5, 'Port de Miami → Cap-Haïtien', 'Départ du navire prévu vendredi.']] },
          { client: 1, desc: 'Ordinateur portable HP', exp: 'Amazon', suivi: 'TBA305112233000', poids: 5.4, service: 'aerien', etapes: [['recu', 3, 'Miami (Medley), FL'], ['embarque', 2, 'Miami → Cap-Haïtien'], ['incident', 1, 'Cap-Haïtien', 'Facture d\'achat demandée par la douane : envoyez-la-nous sur WhatsApp.']] },
          { client: 2, desc: 'Complément alimentaire (6 flacons)', exp: 'iHerb', suivi: 'TBA306778899000', poids: 3, service: 'aerien', etapes: [['recu', 4, 'Miami (Medley), FL'], ['embarque', 3, 'Miami → Santo Domingo'], ['distribution', 1, 'Santo Domingo']] },
          { client: 2, desc: 'Téléviseur 55 pouces', exp: 'Best Buy', suivi: '', poids: 38, service: 'maritime', etapes: [['recu', 12, 'Miami (Medley), FL'], ['embarque', 8, 'Port de Miami → Caucedo'], ['distribution', 4, 'Caucedo'], ['succursale', 0, 'Santiago de los Caballeros', 'Retrait possible dès aujourd\'hui.']] }
        ];
        parcours.forEach(function (p) {
          var client = d.comptes.filter(function (c) { return c.id === ids[p.client]; })[0];
          d.seqColis += 1;
          var c = {
            id: identifiant(), numero: 'GSE-' + d.seqColis + '-' + client.pays, client_id: client.id,
            suivi_transporteur: p.suivi, expediteur: p.exp, description: p.desc, poids_lb: p.poids, service: p.service,
            pays_destination: client.pays, destination: client.ville, statut: 'recu', lieu: '', note: ''
          };
          p.etapes.forEach(function (e) {
            c.statut = e[0];
            c.lieu = e[2];
            c.note = e[3] || '';
            c.maj_le = date(e[1], -2);
            historiser(d, c, c.maj_le);
          });
          c.cree_le = c.recu_le = date(p.etapes[0][1], -2);
          d.colis.push(c);
        });
        ecrireDonnees(d);
        return plusTard(true);
      },

      effacerDemo: function () {
        stockage('effacer', CLE_DONNEES);
        stockage('effacer', CLE_RECUP);
        stockage('effacer', CLE_SESSION);
        prevenir('colis');
        return plusTard(true);
      }
    }
  };

  /* ======================================================================
     Espace fermé (site en ligne sans configuration)
     ====================================================================== */
  function ferme() { return Promise.reject(Erreur('ferme')); }
  var offAPI = {
    session: function () { return Promise.resolve(null); },
    profil: function () { return Promise.resolve(null); },
    inscrire: ferme, connecter: ferme, deconnecter: function () { return Promise.resolve(true); },
    envoyerLienMotDePasse: ferme, attendreRecuperation: function () { return Promise.resolve(false); },
    changerMotDePasse: ferme, modifierProfil: ferme, mesColis: ferme,
    surveiller: function () { return function () {}; },
    suivre: ferme, estAdmin: function () { return Promise.resolve(false); },
    admin: {}
  };

  /* ======================================================================
     Outils d'affichage partagés (suivi de l'accueil, Mon compte, tableau de bord)
     ====================================================================== */
  var textes = null;
  var LOCALES = { fr: 'fr-FR', en: 'en-US', es: 'es-DO', ht: 'fr-FR' };
  var MOIS_HT = ['janvye', 'fevriye', 'mas', 'avril', 'me', 'jen', 'jiyè', 'out', 'septanm', 'oktòb', 'novanm', 'desanm'];
  var ETAPE = { recu: 1, emballe: 2, embarque: 3, distribution: 4, succursale: 5, disponible: 6, livre: 7 };

  // Textes de la page (balise <template data-textes>), traduits avec elle
  function texte(cle, valeurs) {
    if (!textes) {
      textes = {};
      var modele = document.querySelector('template[data-textes]');
      if (modele) {
        Array.prototype.forEach.call(modele.content.querySelectorAll('[data-t]'), function (el) {
          textes[el.getAttribute('data-t')] = el.textContent.trim();
        });
      }
    }
    var t = textes[cle] || '';
    Object.keys(valeurs || {}).forEach(function (k) { t = t.split('{' + k + '}').join(valeurs[k]); });
    return t;
  }

  function deuxChiffres(n) { return (n < 10 ? '0' : '') + n; }

  function date(iso, avecHeure) {
    var d = new Date(iso);
    if (isNaN(d.getTime())) return '';
    var heure = avecHeure ? deuxChiffres(d.getHours()) + ':' + deuxChiffres(d.getMinutes()) : '';
    if (LANGUE === 'ht') return d.getDate() + ' ' + MOIS_HT[d.getMonth()] + ' ' + d.getFullYear() + (heure ? ', ' + heure : '');
    var o = { day: 'numeric', month: 'short', year: 'numeric' };
    if (avecHeure) { o.hour = '2-digit'; o.minute = '2-digit'; }
    try { return new Intl.DateTimeFormat(LOCALES[LANGUE] || 'fr-FR', o).format(d); } catch (e) { return d.toLocaleString(); }
  }

  function nombre(n) {
    try { return new Intl.NumberFormat(LOCALES[LANGUE] || 'fr-FR', { maximumFractionDigits: 1 }).format(n); }
    catch (e) { return String(n); }
  }

  // Étape du parcours (1 à 5) ; un incident garde l'étape précédente
  function etapeDe(statut, historique) {
    if (ETAPE[statut]) return ETAPE[statut];
    var h = (historique || []).slice().reverse();
    for (var i = 0; i < h.length; i++) if (ETAPE[h[i].statut]) return ETAPE[h[i].statut];
    return 1;
  }

  function remplirEtapes(liste, statut, historique) {
    var n = etapeDe(statut, historique);
    var total = liste.children.length;
    // Sur téléphone, les libellés sont masqués : l'étape en cours s'affiche sous les points
    liste.setAttribute('data-etape', texte('etape-sur', { n: n, total: total }) + ' · ' + texte('etape-' + n));
    Array.prototype.forEach.call(liste.children, function (li, i) {
      li.classList.toggle('is-fait', i < n);
      li.classList.toggle('is-actuel', i === n - 1);
      if (i === n - 1) li.setAttribute('aria-current', 'step'); else li.removeAttribute('aria-current');
    });
    liste.classList.toggle('is-incident', statut === 'incident');
  }

  // Historique, du plus récent au plus ancien
  function remplirHistorique(liste, historique, options) {
    options = options || {};
    var libelle = options.libelle || function (s) { return texte('statut-' + s); };
    liste.textContent = '';
    (historique || []).slice().reverse().forEach(function (h) {
      var li = document.createElement('li');
      var s = document.createElement('span');
      s.className = 'gs-chrono__statut';
      s.textContent = libelle(h.statut);
      var m = document.createElement('span');
      m.className = 'gs-chrono__meta';
      m.textContent = [date(h.cree_le, true), h.lieu].filter(Boolean).join(' · ');
      li.appendChild(s);
      li.appendChild(m);
      if (options.notes && h.note) {
        var p = document.createElement('p');
        p.className = 'gs-chrono__note';
        p.textContent = h.note;
        li.appendChild(p);
      }
      liste.appendChild(li);
    });
  }

  function copier(t) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(t).catch(function () { return copierAncien(t); });
    }
    return copierAncien(t);
  }

  function copierAncien(t) {
    return new Promise(function (ok, ko) {
      var zone = document.createElement('textarea');
      zone.value = t;
      zone.setAttribute('readonly', '');
      zone.style.position = 'fixed';
      zone.style.opacity = '0';
      document.body.appendChild(zone);
      zone.select();
      var reussi = false;
      try { reussi = document.execCommand('copy'); } catch (e) { reussi = false; }
      zone.remove();
      if (reussi) ok(); else ko(new Error('copie'));
    });
  }

  var api = MODE === 'supabase' ? supabaseAPI : (MODE === 'demo' ? demoAPI : offAPI);
  api.mode = MODE;
  api.statuts = STATUTS;
  api.langue = LANGUE;
  api.normaliserCode = normaliserCode;
  api.outils = {
    texte: texte, date: date, nombre: nombre, etapeDe: etapeDe,
    remplirEtapes: remplirEtapes, remplirHistorique: remplirHistorique, copier: copier
  };
  window.GoshipAPI = api;
})();
