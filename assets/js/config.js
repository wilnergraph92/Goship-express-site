/* ==========================================================================
   Goship Express — réglages du site
   ==========================================================================
   whatsapp      Numéro WhatsApp au format international, chiffres uniquement.

   formEndpoint  Adresse d'un service de formulaires (ex. Formspree :
                 'https://formspree.io/f/xxxxxxx') pour recevoir les demandes
                 de devis et les inscriptions aux conseils par e-mail.
                 Laissé vide, elles sont préparées dans WhatsApp.

   supabaseUrl   Espace client (comptes, codes GSE, suivi des colis) :
   supabaseKey   adresse du projet Supabase et sa clé publique
                 (« Publishable key » ou « anon public »), dans Supabase >
                 Project Settings > API Keys. Voir README.md, « Espace client ».
                 Tant qu'ils sont vides, l'espace client fonctionne en mode
                 démonstration sur votre ordinateur, et reste fermé en ligne.

   carteLien     Paiement des factures par carte (Visa, Mastercard).
   carteEmail    • Avec Azul (ou un autre encaisseur) : collez votre lien de
   carteDevise     paiement dans carteLien. C'est lui qui sera utilisé partout,
                   et carteEmail devient inutile.
                 • Sans lien : le tableau de bord fabrique un lien PayPal avec
                   carteEmail et le montant de la facture.
                 carteDevise est la devise de ces paiements (USD par défaut).

   appStoreLien  Adresses de l'application mobile sur les deux boutiques, une
   googlePlayLien fois publiée. Tant qu'elles sont vides, la section « Vos colis
                 dans votre poche » de l'accueil affiche « Bientôt sur » et les
                 boutons ne mènent nulle part. Dès qu'une adresse est collée
                 (elle doit commencer par https://), le bouton devient un vrai
                 lien. Pensez alors aux badges officiels : voir README, « Section
                 application mobile ».

   siteUrl       Adresse publique du site, une fois en ligne (ex.
                 'https://www.goshipexpress.com'). Le bouton « Suivre mon colis »
                 des e-mails et le lien des messages WhatsApp y mènent. Laissée
                 vide, c'est l'adresse du tableau de bord qui sert, sauf sur votre
                 ordinateur : les messages partent alors sans ce lien.
                 C'est aussi l'adresse donnée à Google (balises canonical,
                 sitemap.xml) : après l'avoir changée, relancez build.py puis
                 traduire.py.

   googleAnalytics  Identifiant de mesure Google Analytics 4 (« G-XXXXXXXXXX »,
                 dans Analytics > Admin > Flux de données). Vide : aucune
                 mesure. Rempli : les pages publiques le chargent, seulement sur
                 siteUrl (jamais en local ni sur la copie GitHub Pages), jamais
                 sur l'espace client ni le tableau de bord. Après l'avoir changé,
                 relancez build.py puis traduire.py : la politique de sécurité
                 des pages doit autoriser Google.
   ========================================================================== */
window.GOSHIP_CONFIG = {
  whatsapp: '18495386262',
  formEndpoint: '',
  supabaseUrl: 'https://gpfdyslysqjmojgzggib.supabase.co',
  supabaseKey: 'sb_publishable_zdlM4FPqlwq-145lrVeYpw_rHqB7Drt',
  carteLien: '',
  carteEmail: 'goshipexpressllc@gmail.com',
  carteDevise: 'USD',
  appStoreLien: '',
  googlePlayLien: 'https://play.google.com/store/apps/details?id=com.goshipexpress.app',
  siteUrl: 'https://goshipexpress.net',
  googleAnalytics: 'G-KLV2HSF91C'
};
