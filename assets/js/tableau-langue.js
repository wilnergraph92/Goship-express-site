/* ==========================================================================
   Goship Express — la langue du tableau de bord (admin.html)
   Le tableau de bord s'écrit en français ; ce fichier l'affiche en anglais, en
   espagnol ou en créole. Il ne touche à aucune donnée ni à aucune règle : il
   remplace, à l'écran seulement, les textes qu'il connaît (le dictionnaire plus
   bas) et remet le français quand on le rechoisit. Les textes qu'admin.js écrit
   après coup (listes, fiches, messages) passent par le même chemin, grâce à un
   MutationObserver. Ce qu'il ne connaît pas (noms, adresses, notes, textes
   rares) reste tel quel.
   - Préférence de l'appareil : localStorage « gse-tableau-langue » (fr par défaut).
   - Le sélecteur : <select data-langue-tableau> dans la barre du haut.
   - Les factures et étiquettes imprimées gardent la langue du client (impression.js).
   Un texte ajouté au tableau de bord : sa ligne ici, avec ses trois traductions.
   ========================================================================== */
(function () {
  'use strict';

  var CLE = 'gse-tableau-langue';
  var LANGUES = ['fr', 'en', 'es', 'ht'];
  var RANG = { en: 0, es: 1, ht: 2 };
  var ATTRIBUTS = ['placeholder', 'aria-label', 'title', 'data-libelle', 'label'];
  var IGNORES = 'script, style, textarea, code, [translate="no"] option, [data-langue-tableau] option';

  // Français → [anglais, espagnol, créole]
  var D = {
    "Tableau de bord — Goship Express": ["Dashboard — Goship Express", "Panel — Goship Express", "Tablo de bò — Goship Express"],
    "Aller au contenu": ["Skip to content", "Ir al contenido", "Ale nan kontni an"],
    "Menu du tableau de bord": ["Dashboard menu", "Menú del panel", "Meni tablo de bò a"],
    "Goship Express — voir le site": ["Goship Express — view the website", "Goship Express — ver el sitio", "Goship Express — wè sit la"],
    "Réduire le menu": ["Collapse menu", "Contraer el menú", "Redui meni an"],
    "Déplier le menu": ["Expand menu", "Desplegar el menú", "Louvri meni an"],
    "Opérations": ["Operations", "Operaciones", "Operasyon"],
    "Vue générale": ["Overview", "Vista general", "Apèsi jeneral"],
    "Colis": ["Packages", "Paquetes", "Koli"],
    "Poste de scan": ["Scan station", "Puesto de escaneo", "Pòs eskanè"],
    "Scanner": ["Scanner", "Escáner", "Eskanè"],
    "Clients": ["Customers", "Clientes", "Kliyan"],
    "Finance": ["Finance", "Finanzas", "Finans"],
    "Factures": ["Invoices", "Facturas", "Fakti"],
    "Encaissements et créances": ["Collections and receivables", "Cobros y cuentas por cobrar", "Lajan ki antre ak dèt kliyan"],
    "Encaissements": ["Collections", "Cobros", "Lajan antre"],
    "Gestion": ["Management", "Gestión", "Jesyon"],
    "Analytics": ["Analytics", "Analítica", "Analiz"],
    "Équipe": ["Team", "Equipo", "Ekip"],
    "Réglages": ["Settings", "Ajustes", "Paramèt"],
    "Voir le site": ["View website", "Ver el sitio", "Wè sit la"],
    "Déconnexion": ["Log out", "Cerrar sesión", "Dekonekte"],
    "Ouvrir le menu": ["Open menu", "Abrir el menú", "Louvri meni an"],
    "Tableau de bord": ["Dashboard", "Panel", "Tablo de bò"],
    "Démo": ["Demo", "Demo", "Demo"],
    "Colis, facture, suivi, code-barres, nom, téléphone…": ["Package, invoice, tracking, barcode, name, phone…", "Paquete, factura, seguimiento, código de barras, nombre, teléfono…", "Koli, fakti, swivi, kòd ba, non, telefòn…"],
    "Recherche rapide : colis, clients, factures": ["Quick search: packages, customers, invoices", "Búsqueda rápida: paquetes, clientes, facturas", "Rechèch rapid : koli, kliyan, fakti"],
    "Chercher": ["Search", "Buscar", "Chèche"],
    "En direct": ["Live", "En directo", "An dirèk"],
    "Enregistrer un colis": ["Register a package", "Registrar un paquete", "Anrejistre yon koli"],
    "Alertes": ["Alerts", "Alertas", "Alèt"],
    "Affichage et réglages": ["Display and settings", "Pantalla y ajustes", "Afichaj ak paramèt"],
    "Apparence": ["Appearance", "Apariencia", "Aparans"],
    "Clair": ["Light", "Claro", "Klè"],
    "Sombre": ["Dark", "Oscuro", "Fonse"],
    "Système": ["System", "Sistema", "Sistèm"],
    "Personnaliser le tableau de bord": ["Customize the dashboard", "Personalizar el panel", "Pèsonalize tablo de bò a"],
    "Rétablir la disposition": ["Reset the layout", "Restablecer la disposición", "Remete dispozisyon an"],
    "Tous les réglages…": ["All settings…", "Todos los ajustes…", "Tout paramèt yo…"],
    "Mon compte": ["My account", "Mi cuenta", "Kont mwen"],
    "Connexion perdue.": ["Connection lost.", "Conexión perdida.", "Koneksyon an koupe."],
    "Certaines fonctionnalités sont indisponibles : aucune opération n'est enregistrée tant que la connexion n'est pas revenue.": ["Some features are unavailable: no operation is saved until the connection is back.", "Algunas funciones no están disponibles: no se guarda ninguna operación hasta que vuelva la conexión.", "Gen kèk fonksyon ki pa disponib : pa gen okenn operasyon ki anrejistre toutotan koneksyon an pa tounen."],
    "Mettez à jour l'application GoShip Express.": ["Update the GoShip Express app.", "Actualice la aplicación GoShip Express.", "Mete aplikasyon GoShip Express la ajou."],
    "Cette version du poste de travail est trop ancienne pour certaines fonctions du tableau de bord.": ["This version of the workstation app is too old for some dashboard features.", "Esta versión de la estación de trabajo es demasiado antigua para algunas funciones del panel.", "Vèsyon pòs travay sa a twò ansyen pou kèk fonksyon tablo de bò a."],
    "Résultats de la recherche rapide": ["Quick search results", "Resultados de la búsqueda rápida", "Rezilta rechèch rapid la"],
    "Mode démonstration.": ["Demo mode.", "Modo demostración.", "Mòd demonstrasyon."],
    "Comptes et colis sont enregistrés uniquement dans ce navigateur. Une fois Supabase configuré (voir le fichier README.md), ce tableau de bord utilise la vraie base de données.": ["Accounts and packages are saved in this browser only. Once Supabase is configured (see README.md), this dashboard uses the real database.", "Las cuentas y los paquetes se guardan solo en este navegador. Una vez configurado Supabase (ver README.md), este panel usa la base de datos real.", "Kont ak koli yo anrejistre sèlman nan navigatè sa a. Lè Supabase fin konfigire (gade README.md), tablo de bò a ap sèvi ak vrè baz done a."],
    "Ajouter des exemples": ["Add examples", "Añadir ejemplos", "Ajoute egzanp"],
    "Effacer la démo": ["Clear the demo", "Borrar la demo", "Efase demo a"],
    "Chargement…": ["Loading…", "Cargando…", "Chajman…"],
    "Tableau de bord à activer": ["Dashboard to be activated", "Panel por activar", "Tablo de bò pou aktive"],
    "Connexion administrateur": ["Administrator login", "Acceso de administrador", "Koneksyon administratè"],
    "Réservé à l'équipe Goship Express.": ["Reserved for the Goship Express team.", "Reservado al equipo de Goship Express.", "Rezève pou ekip Goship Express."],
    "Démonstration :": ["Demo:", "Demostración:", "Demonstrasyon :"],
    "ou": ["or", "o", "oswa"],
    "· mot de passe": ["· password", "· contraseña", "· modpas"],
    "E-mail": ["Email", "Correo electrónico", "Imèl"],
    "Mot de passe": ["Password", "Contraseña", "Modpas"],
    "Se connecter": ["Log in", "Iniciar sesión", "Konekte"],
    "Accès réservé": ["Restricted access", "Acceso restringido", "Aksè rezève"],
    "Le compte": ["The account", "La cuenta", "Kont"],
    "Se déconnecter": ["Log out", "Cerrar sesión", "Dekonekte"],
    "Vue d'ensemble logistique": ["Logistics overview", "Resumen logístico", "Apèsi lojistik"],
    "Miami → Haïti · République dominicaine": ["Miami → Haiti · Dominican Republic", "Miami → Haití · República Dominicana", "Miami → Ayiti · Repiblik Dominikèn"],
    "Période": ["Period", "Período", "Peryòd"],
    "Aujourd'hui": ["Today", "Hoy", "Jodi a"],
    "Aujourd’hui": ["Today", "Hoy", "Jodi a"],
    "7 derniers jours": ["Last 7 days", "Últimos 7 días", "7 dènye jou"],
    "30 derniers jours": ["Last 30 days", "Últimos 30 días", "30 dènye jou"],
    "Ce mois-ci": ["This month", "Este mes", "Mwa sa a"],
    "Mois précédent": ["Last month", "Mes anterior", "Mwa pase"],
    "Cette année": ["This year", "Este año", "Ane sa a"],
    "Personnalisée…": ["Custom…", "Personalizado…", "Pèsonalize…"],
    "Du": ["From", "Desde", "Depi"],
    "Au": ["To", "Hasta", "Rive"],
    "au": ["to", "al", "rive"],
    "Appliquer": ["Apply", "Aplicar", "Aplike"],
    "Actualiser": ["Refresh", "Actualizar", "Rafrechi"],
    "Suspendre le direct": ["Pause live updates", "Pausar el directo", "Kanpe an dirèk la"],
    "Reprendre le direct": ["Resume live updates", "Reanudar el directo", "Relanse an dirèk la"],
    "Personnaliser": ["Customize", "Personalizar", "Pèsonalize"],
    "Filtres de la vue générale": ["Overview filters", "Filtros de la vista general", "Filtè apèsi jeneral la"],
    "Filtres": ["Filters", "Filtros", "Filtè"],
    "Pays": ["Country", "País", "Peyi"],
    "Tous": ["All", "Todos", "Tout"],
    "Destination": ["Destination", "Destino", "Destinasyon"],
    "Toutes": ["All", "Todas", "Tout"],
    "Mode": ["Mode", "Modo", "Mòd"],
    "Statut": ["Status", "Estado", "Estati"],
    "Agence": ["Branch", "Agencia", "Ajans"],
    "Là où se trouve le colis : USA = au dépôt de Miami (reçu, emballé) ; Haïti, Santo Domingo = arrivé dans le pays (centre de distribution, succursale, disponible)": ["Where the package is: USA = at the Miami warehouse (received, packed); Haiti, Santo Domingo = arrived in the country (distribution center, branch, available)", "Dónde está el paquete: USA = en el almacén de Miami (recibido, embalado); Haití, Santo Domingo = llegado al país (centro de distribución, sucursal, disponible)", "Kote koli a ye : USA = nan depo Miami (resevwa, anbale) ; Ayiti, Santo Domingo = rive nan peyi a (sant distribisyon, siksisal, disponib)"],
    "Effacer les filtres": ["Clear filters", "Borrar filtros", "Efase filtè yo"],
    "Facturé sur la période": ["Invoiced in the period", "Facturado en el período", "Fakti pandan peryòd la"],
    "Colis reçus, jour par jour": ["Packages received, day by day", "Paquetes recibidos, día a día", "Koli resevwa, jou pa jou"],
    "Règlement des factures": ["Invoice payments", "Pago de facturas", "Peman fakti yo"],
    "Les dépenses ne sont pas suivies : aucune marge n'est calculée.": ["Expenses are not tracked: no margin is calculated.", "Los gastos no se registran: no se calcula ningún margen.", "Depans yo pa swiv : pa gen okenn maj ki kalkile."],
    "Destinations les plus actives": ["Most active destinations", "Destinos más activos", "Destinasyon ki pi aktif"],
    "Voir les clients": ["View customers", "Ver clientes", "Wè kliyan yo"],
    "À surveiller": ["To watch", "A vigilar", "Pou siveye"],
    "Dernière activité": ["Latest activity", "Última actividad", "Dènye aktivite"],
    "Tous les colis": ["All packages", "Todos los paquetes", "Tout koli yo"],
    "Client": ["Customer", "Cliente", "Kliyan"],
    "Événement": ["Event", "Evento", "Evènman"],
    "Lieu": ["Location", "Lugar", "Kote"],
    "Date": ["Date", "Fecha", "Dat"],
    "Aucun événement pour l'instant.": ["No events yet.", "Ningún evento por ahora.", "Pa gen evènman pou kounye a."],
    "Colis par statut": ["Packages by status", "Paquetes por estado", "Koli pa estati"],
    "maintenant": ["now", "ahora", "kounye a"],
    "Chaîne logistique": ["Supply chain", "Cadena logística", "Chèn lojistik"],
    "Performance des routes": ["Route performance", "Rendimiento de las rutas", "Pèfòmans wout yo"],
    "colis reçus sur la période": ["packages received in the period", "paquetes recibidos en el período", "koli resevwa pandan peryòd la"],
    "Route": ["Route", "Ruta", "Wout"],
    "Livrés": ["Delivered", "Entregados", "Livre"],
    "Délai moyen": ["Average time", "Plazo medio", "Tan mwayen"],
    "Facturé": ["Invoiced", "Facturado", "Fakti"],
    "Taux de livraison": ["Delivery rate", "Tasa de entrega", "To livrezon"],
    "Aucun colis reçu sur la période.": ["No packages received in the period.", "Ningún paquete recibido en el período.", "Pa gen koli ki resevwa pandan peryòd la."],
    "Villes de destination": ["Destination cities", "Ciudades de destino", "Vil destinasyon"],
    "Colis à traiter": ["Packages to handle", "Paquetes por tratar", "Koli pou trete"],
    "Liste": ["List", "Lista", "Lis"],
    "Action requise": ["Action required", "Acción requerida", "Aksyon obligatwa"],
    "Sans mouvement depuis": ["No movement for", "Sin movimiento desde hace", "San mouvman depi"],
    "Nombre de jours sans mouvement": ["Number of days without movement", "Número de días sin movimiento", "Kantite jou san mouvman"],
    "3 jours": ["3 days", "3 días", "3 jou"],
    "7 jours": ["7 days", "7 días", "7 jou"],
    "14 jours": ["14 days", "14 días", "14 jou"],
    "30 jours": ["30 days", "30 días", "30 jou"],
    "Dernier événement": ["Latest event", "Último evento", "Dènye evènman"],
    "Depuis": ["Since", "Desde", "Depi"],
    "Actions": ["Actions", "Acciones", "Aksyon"],
    "Par employé": ["By employee", "Por empleado", "Pa anplwaye"],
    "Par opération": ["By operation", "Por operación", "Pa operasyon"],
    "Opérations par jour": ["Operations per day", "Operaciones por día", "Operasyon pa jou"],
    "Une opération compte quand le scan l'a enregistrée. Une simple consultation, un scan déjà fait ou un code introuvable n'écrivent rien : les scans échoués ne sont pas enregistrés, ils ne sont donc pas comptés ici.": ["An operation counts once the scan has saved it. A simple lookup, a scan already done or a code not found write nothing: failed scans are not saved, so they are not counted here.", "Una operación cuenta cuando el escaneo la ha guardado. Una simple consulta, un escaneo ya hecho o un código no encontrado no escriben nada: los escaneos fallidos no se guardan, por eso no se cuentan aquí.", "Yon operasyon konte lè eskanè a anrejistre l. Yon senp konsiltasyon, yon eskan ki deja fèt oswa yon kòd ki pa jwenn pa ekri anyen : eskan ki echwe yo pa anrejistre, se sa ki fè yo pa konte isit la."],
    "Derniers paiements reçus": ["Latest payments received", "Últimos pagos recibidos", "Dènye peman resevwa"],
    "Reçu le": ["Received on", "Recibido el", "Resevwa le"],
    "Facture": ["Invoice", "Factura", "Fakti"],
    "Moyen": ["Method", "Medio", "Mwayen"],
    "Montant": ["Amount", "Importe", "Montan"],
    "Aucun paiement reçu pour l'instant.": ["No payments received yet.", "Ningún pago recibido por ahora.", "Pa gen peman resevwa pou kounye a."],
    "Reçus": ["Received", "Recibidos", "Resevwa"],
    "Emballés": ["Packed", "Embalados", "Anbale"],
    "Embarqués": ["Shipped", "Embarcados", "Anbake"],
    "Centre de distribution": ["Distribution center", "Centro de distribución", "Sant distribisyon"],
    "Transférés à la succursale": ["Transferred to branch", "Transferidos a la sucursal", "Transfere nan siksisal"],
    "Disponibles": ["Available", "Disponibles", "Disponib"],
    "Livrés (30 jours)": ["Delivered (30 days)", "Entregados (30 días)", "Livre (30 jou)"],
    "Clients inscrits": ["Registered customers", "Clientes inscritos", "Kliyan enskri"],
    "N° de colis, code client, nom, suivi vendeur…": ["Package no., customer code, name, seller tracking…", "N.º de paquete, código de cliente, nombre, seguimiento del vendedor…", "Nimewo koli, kòd kliyan, non, swivi machann…"],
    "Rechercher un colis": ["Search a package", "Buscar un paquete", "Chèche yon koli"],
    "Filtrer par statut": ["Filter by status", "Filtrar por estado", "Filtre pa estati"],
    "Colis en cours": ["Packages in progress", "Paquetes en curso", "Koli an kou"],
    "Filtrer par service": ["Filter by service", "Filtrar por servicio", "Filtre pa sèvis"],
    "Tous les services": ["All services", "Todos los servicios", "Tout sèvis yo"],
    "Aérien": ["Air", "Aéreo", "Avyon"],
    "Maritime": ["Sea", "Marítimo", "Bato"],
    "Terrestre": ["Ground", "Terrestre", "Tè"],
    "Aérienne": ["Air", "Aérea", "Avyon"],
    "Filtrer par pays de destination": ["Filter by destination country", "Filtrar por país de destino", "Filtre pa peyi destinasyon"],
    "Toutes les destinations": ["All destinations", "Todos los destinos", "Tout destinasyon"],
    "Haïti": ["Haiti", "Haití", "Ayiti"],
    "République dominicaine": ["Dominican Republic", "República Dominicana", "Repiblik Dominikèn"],
    "États-Unis": ["United States", "Estados Unidos", "Etazini"],
    "Santo Domingo": ["Santo Domingo", "Santo Domingo", "Santo Domingo"],
    "USA": ["USA", "EE. UU.", "USA"],
    "Reçus du": ["Received from", "Recibidos desde", "Resevwa depi"],
    "Reçus à partir du": ["Received from", "Recibidos a partir del", "Resevwa apati"],
    "Reçus jusqu'au": ["Received until", "Recibidos hasta el", "Resevwa jiska"],
    "Réinitialiser les filtres": ["Reset filters", "Restablecer filtros", "Remete filtè yo"],
    "Colis du client": ["Customer's packages", "Paquetes del cliente", "Koli kliyan an"],
    "Voir tous les colis": ["View all packages", "Ver todos los paquetes", "Wè tout koli yo"],
    "Changer le statut": ["Change status", "Cambiar el estado", "Chanje estati a"],
    "Imprimer les étiquettes": ["Print labels", "Imprimir etiquetas", "Enprime etikèt yo"],
    "Supprimer": ["Delete", "Eliminar", "Efase"],
    "Annuler la sélection": ["Clear selection", "Anular la selección", "Anile seleksyon an"],
    "Sélectionner tous les colis affichés": ["Select all displayed packages", "Seleccionar todos los paquetes mostrados", "Chwazi tout koli ki parèt yo"],
    "Contenu": ["Contents", "Contenido", "Kontni"],
    "Service": ["Service", "Servicio", "Sèvis"],
    "Mis à jour": ["Updated", "Actualizado", "Mete ajou"],
    "Code client, nom, téléphone, e-mail, ville…": ["Customer code, name, phone, email, city…", "Código de cliente, nombre, teléfono, correo, ciudad…", "Kòd kliyan, non, telefòn, imèl, vil…"],
    "Rechercher un client": ["Search a customer", "Buscar un cliente", "Chèche yon kliyan"],
    "Filtrer les clients": ["Filter customers", "Filtrar clientes", "Filtre kliyan yo"],
    "Tous les clients": ["All customers", "Todos los clientes", "Tout kliyan yo"],
    "Avec des colis en cours": ["With packages in progress", "Con paquetes en curso", "Ki gen koli an kou"],
    "Avec un solde à payer": ["With a balance due", "Con saldo pendiente", "Ki gen balans pou peye"],
    "Trier les clients": ["Sort customers", "Ordenar clientes", "Klase kliyan yo"],
    "Inscrits récemment": ["Recently registered", "Inscritos recientemente", "Enskri dènyèman"],
    "Activité récente": ["Recent activity", "Actividad reciente", "Aktivite resan"],
    "Solde le plus élevé": ["Highest balance", "Saldo más alto", "Pi gwo balans"],
    "Le plus de colis en cours": ["Most packages in progress", "Más paquetes en curso", "Plis koli an kou"],
    "Nom (A → Z)": ["Name (A → Z)", "Nombre (A → Z)", "Non (A → Z)"],
    "Identifiant": ["ID", "Identificador", "Idantifyan"],
    "Poids en cours": ["Weight in progress", "Peso en curso", "Pwa an kou"],
    "Payé": ["Paid", "Pagado", "Peye"],
    "Solde": ["Balance", "Saldo", "Balans"],
    "Scannez un colis — ou tapez son numéro": ["Scan a package — or type its number", "Escanee un paquete — o escriba su número", "Eskane yon koli — oswa tape nimewo li"],
    "GSE-1001-HT, QR de l'étiquette ou suivi du vendeur": ["GSE-1001-HT, label QR or seller tracking", "GSE-1001-HT, QR de la etiqueta o seguimiento del vendedor", "GSE-1001-HT, QR etikèt la oswa swivi machann nan"],
    "Rechercher": ["Search", "Buscar", "Chèche"],
    "Un scanner USB ou Bluetooth (mode clavier) n'a rien à installer : scannez un code pour le vérifier.": ["A USB or Bluetooth scanner (keyboard mode) needs no installation: scan a code to check it.", "Un escáner USB o Bluetooth (modo teclado) no necesita instalación: escanee un código para comprobarlo.", "Yon eskanè USB oswa Bluetooth (mòd klavye) pa bezwen enstale anyen : eskane yon kòd pou verifye l."],
    "Consulter, puis choisir l'opération": ["Look up, then choose the operation", "Consultar y luego elegir la operación", "Gade, epi chwazi operasyon an"],
    "Consulter, puis choisir l’opération": ["Look up, then choose the operation", "Consultar y luego elegir la operación", "Gade, epi chwazi operasyon an"],
    "Lieu de ce poste": ["Location of this station", "Lugar de este puesto", "Kote pòs sa a ye"],
    "Ex. Miami (Medley), FL": ["E.g. Miami (Medley), FL", "Ej. Miami (Medley), FL", "Egz. Miami (Medley), FL"],
    "Son": ["Sound", "Sonido", "Son"],
    "Chaque scan affiche le colis et les opérations permises.": ["Each scan shows the package and the allowed operations.", "Cada escaneo muestra el paquete y las operaciones permitidas.", "Chak eskan montre koli a ak operasyon ki pèmèt yo."],
    "Prêt : scannez un colis": ["Ready: scan a package", "Listo: escanee un paquete", "Pare : eskane yon koli"],
    "Colis scanné": ["Scanned package", "Paquete escaneado", "Koli eskane"],
    "Derniers scans": ["Latest scans", "Últimos escaneos", "Dènye eskan"],
    "Aucun scan pour l'instant.": ["No scans yet.", "Ningún escaneo por ahora.", "Pa gen eskan pou kounye a."],
    "3 derniers mois": ["Last 3 months", "Últimos 3 meses", "3 dènye mwa"],
    "6 derniers mois": ["Last 6 months", "Últimos 6 meses", "6 dènye mwa"],
    "12 derniers mois": ["Last 12 months", "Últimos 12 meses", "12 dènye mwa"],
    "Découpage": ["Breakdown", "Desglose", "Dekoupaj"],
    "Par jour": ["By day", "Por día", "Pa jou"],
    "Par semaine": ["By week", "Por semana", "Pa semèn"],
    "Par mois": ["By month", "Por mes", "Pa mwa"],
    "Imprimer / PDF": ["Print / PDF", "Imprimir / PDF", "Enprime / PDF"],
    "Rubriques Analytics": ["Analytics sections", "Secciones de analítica", "Seksyon analiz"],
    "Synthèse": ["Summary", "Síntesis", "Rezime"],
    "Expéditions": ["Shipments", "Envíos", "Ekspedisyon"],
    "Finances": ["Finances", "Finanzas", "Finans"],
    "Routes": ["Routes", "Rutas", "Wout"],
    "Qualité des données": ["Data quality", "Calidad de los datos", "Kalite done yo"],
    "À encaisser": ["To collect", "Por cobrar", "Pou touche"],
    "En retard": ["Overdue", "Atrasadas", "An reta"],
    "Encaissé ce mois-ci": ["Collected this month", "Cobrado este mes", "Touche mwa sa a"],
    "Filtrer les factures": ["Filter invoices", "Filtrar facturas", "Filtre fakti yo"],
    "À payer": ["Due", "Por pagar", "Pou peye"],
    "Payées en partie": ["Partly paid", "Pagadas en parte", "Peye an pati"],
    "Toutes les factures": ["All invoices", "Todas las facturas", "Tout fakti yo"],
    "Payées": ["Paid", "Pagadas", "Peye"],
    "Annulées": ["Cancelled", "Anuladas", "Anile"],
    "Contrôler": ["Check", "Controlar", "Kontwole"],
    "Nouvelle facture": ["New invoice", "Nueva factura", "Nouvo fakti"],
    "État": ["State", "Estado", "Eta"],
    "Créée le": ["Created on", "Creada el", "Kreye le"],
    "Afficher plus de factures": ["Show more invoices", "Mostrar más facturas", "Montre plis fakti"],
    "Chaque membre de l'équipe a un rôle, et chaque rôle une liste de permissions. La base de données les vérifie à chaque action : un bouton masqué ici n'est qu'un confort, jamais la protection.": ["Each team member has a role, and each role a list of permissions. The database checks them on every action: a button hidden here is only a convenience, never the protection.", "Cada miembro del equipo tiene un rol y cada rol una lista de permisos. La base de datos los verifica en cada acción: un botón oculto aquí es solo una comodidad, nunca la protección.", "Chak manm ekip la gen yon wòl, e chak wòl gen yon lis pèmisyon. Baz done a verifye yo nan chak aksyon : yon bouton ki kache isit la se yon konfò sèlman, li pa janm pwoteksyon an."],
    "E-mail du compte": ["Account email", "Correo de la cuenta", "Imèl kont lan"],
    "Rôle": ["Role", "Rol", "Wòl"],
    "Employé": ["Employee", "Empleado", "Anplwaye"],
    "Gérant": ["Manager", "Gerente", "Jeran"],
    "Administrateur": ["Administrator", "Administrador", "Administratè"],
    "Client (retire l'accès au tableau de bord)": ["Customer (removes dashboard access)", "Cliente (retira el acceso al panel)", "Kliyan (retire aksè nan tablo de bò a)"],
    "Donner ce rôle": ["Give this role", "Dar este rol", "Bay wòl sa a"],
    "Nom": ["Name", "Nombre", "Non"],
    "Ce que chaque rôle peut faire": ["What each role can do", "Lo que puede hacer cada rol", "Sa chak wòl ka fè"],
    "Fermer": ["Close", "Cerrar", "Fèmen"],
    "Identifiant GSE, nom ou e-mail": ["GSE ID, name or email", "Identificador GSE, nombre o correo", "Idantifyan GSE, non oswa imèl"],
    "Clients correspondants": ["Matching customers", "Clientes coincidentes", "Kliyan ki koresponn"],
    "Date de réception": ["Date received", "Fecha de recepción", "Dat resepsyon"],
    "Heure de réception": ["Time received", "Hora de recepción", "Lè resepsyon"],
    "Contenu du colis": ["Package contents", "Contenido del paquete", "Kontni koli a"],
    "Ex. Vêtements, chaussures…": ["E.g. Clothes, shoes…", "Ej. Ropa, zapatos…", "Egz. Rad, soulye…"],
    "Expéditeur (magasin)": ["Sender (store)", "Remitente (tienda)", "Moun ki voye (magazen)"],
    "(facultatif)": ["(optional)", "(opcional)", "(pa obligatwa)"],
    "Ex. Amazon, SHEIN, Temu…": ["E.g. Amazon, SHEIN, Temu…", "Ej. Amazon, SHEIN, Temu…", "Egz. Amazon, SHEIN, Temu…"],
    "N° de suivi du vendeur": ["Seller tracking no.", "N.º de seguimiento del vendedor", "Nimewo swivi machann nan"],
    "Ex. TBA304918577000": ["E.g. TBA304918577000", "Ej. TBA304918577000", "Egz. TBA304918577000"],
    "Poids (lb)": ["Weight (lb)", "Peso (lb)", "Pwa (lb)"],
    "Ex. 4,5": ["E.g. 4.5", "Ej. 4,5", "Egz. 4,5"],
    "Tarif (US $ / lb)": ["Rate (US $ / lb)", "Tarifa (US $ / lb)", "Tarif (US $ / lb)"],
    "Tarif de la maison : 5 $/lb. À ne changer que pour un accord particulier.": ["House rate: $5/lb. Change it only for a special agreement.", "Tarifa de la casa: 5 $/lb. Cámbiela solo para un acuerdo particular.", "Tarif kay la : 5 $/lb. Chanje l sèlman pou yon akò espesyal."],
    "Prix du colis (US $)": ["Package price (US $)", "Precio del paquete (US $)", "Pri koli a (US $)"],
    "Calculé par le système : poids × tarif.": ["Calculated by the system: weight × rate.", "Calculado por el sistema: peso × tarifa.", "Sistèm nan kalkile l : pwa × tarif."],
    "Pays de destination": ["Destination country", "País de destino", "Peyi destinasyon"],
    "Ville de livraison": ["Delivery city", "Ciudad de entrega", "Vil livrezon"],
    "Ex. Port-au-Prince": ["E.g. Port-au-Prince", "Ej. Puerto Príncipe", "Egz. Pòtoprens"],
    "Lieu de réception": ["Receiving location", "Lugar de recepción", "Kote resepsyon"],
    "Message pour le client": ["Message for the customer", "Mensaje para el cliente", "Mesaj pou kliyan an"],
    "Visible par le client dans son espace": ["Visible to the customer in their account", "Visible para el cliente en su espacio", "Kliyan an ka wè l nan espas li"],
    "Prévenir le client": ["Notify the customer", "Avisar al cliente", "Avèti kliyan an"],
    "par e-mail et WhatsApp que son colis est reçu": ["by email and WhatsApp that the package has been received", "por correo y WhatsApp de que su paquete fue recibido", "pa imèl ak WhatsApp ke koli li resevwa"],
    "Annuler": ["Cancel", "Cancelar", "Anile"],
    "Enregistrer le colis": ["Save the package", "Guardar el paquete", "Anrejistre koli a"],
    "Code client": ["Customer code", "Código de cliente", "Kòd kliyan"],
    "Colis à facturer": ["Packages to invoice", "Paquetes por facturar", "Koli pou fakti"],
    "Tout sélectionner": ["Select all", "Seleccionar todo", "Chwazi tout"],
    "Seuls les colis de ce client apparaissent : une facture ne peut pas mélanger deux clients.": ["Only this customer's packages appear: an invoice cannot mix two customers.", "Solo aparecen los paquetes de este cliente: una factura no puede mezclar dos clientes.", "Se koli kliyan sa a sèlman ki parèt : yon fakti pa ka melanje de kliyan."],
    "Total colis": ["Packages total", "Total paquetes", "Total koli"],
    "Frais de service": ["Service fee", "Cargo por servicio", "Frè sèvis"],
    "Grand total": ["Grand total", "Total general", "Gran total"],
    "Déjà payé": ["Already paid", "Ya pagado", "Deja peye"],
    "Reste à payer": ["Left to pay", "Por pagar", "Rès pou peye"],
    "Montant total (US $)": ["Total amount (US $)", "Importe total (US $)", "Montan total (US $)"],
    "Calculé à partir des colis cochés, frais de service compris.": ["Calculated from the checked packages, service fee included.", "Calculado a partir de los paquetes marcados, cargo por servicio incluido.", "Kalkile apati koli ki make yo, frè sèvis ladan l."],
    "À payer avant le": ["Due before", "A pagar antes del", "Pou peye anvan"],
    "Lien de paiement (facultatif)": ["Payment link (optional)", "Enlace de pago (opcional)", "Lyen peman (pa obligatwa)"],
    "Laissez vide : lien PayPal créé automatiquement": ["Leave empty: PayPal link created automatically", "Déjelo vacío: enlace de PayPal creado automáticamente", "Kite l vid : lyen PayPal ap kreye otomatikman"],
    "Laissé vide, un lien PayPal est créé avec le montant : le client paie par carte Visa ou Mastercard. Vous pouvez aussi coller un lien Azul.": ["Left empty, a PayPal link is created with the amount: the customer pays by Visa or Mastercard. You can also paste an Azul link.", "Si se deja vacío, se crea un enlace de PayPal con el importe: el cliente paga con tarjeta Visa o Mastercard. También puede pegar un enlace de Azul.", "Si l rete vid, yon lyen PayPal kreye ak montan an : kliyan an peye ak kat Visa oswa Mastercard. Ou ka kole yon lyen Azul tou."],
    "Note pour le client (facultatif)": ["Note for the customer (optional)", "Nota para el cliente (opcional)", "Nòt pou kliyan an (pa obligatwa)"],
    "Paiements": ["Payments", "Pagos", "Peman"],
    "Encaisser un paiement": ["Record a payment", "Cobrar un pago", "Touche yon peman"],
    "Regrouper avec d'autres factures de ce client": ["Merge with this customer's other invoices", "Agrupar con otras facturas de este cliente", "Mete ansanm ak lòt fakti kliyan sa a"],
    "Annuler cette facture": ["Cancel this invoice", "Anular esta factura", "Anile fakti sa a"],
    "Enregistrer": ["Save", "Guardar", "Anrejistre"],
    "Total de la facture": ["Invoice total", "Total de la factura", "Total fakti a"],
    "Montant reçu (US $)": ["Amount received (US $)", "Importe recibido (US $)", "Montan resevwa (US $)"],
    "Un acompte suffit : la facture reste à payer pour le reste.": ["A deposit is enough: the rest of the invoice remains due.", "Un anticipo basta: el resto de la factura queda por pagar.", "Yon avans ase : rès fakti a rete pou peye."],
    "Payé par": ["Paid by", "Pagado con", "Peye pa"],
    "Choisir…": ["Choose…", "Elegir…", "Chwazi…"],
    "Espèces": ["Cash", "Efectivo", "Kach"],
    "Virement bancaire": ["Bank transfer", "Transferencia bancaria", "Virman labank"],
    "Azul (carte)": ["Azul (card)", "Azul (tarjeta)", "Azul (kat)"],
    "Transfert d'argent (Western Union, Ria…)": ["Money transfer (Western Union, Ria…)", "Transferencia de dinero (Western Union, Ria…)", "Transfè lajan (Western Union, Ria…)"],
    "Transfert d’argent": ["Money transfer", "Transferencia de dinero", "Transfè lajan"],
    "Autre": ["Other", "Otro", "Lòt"],
    "Autre moyen": ["Other method", "Otro medio", "Lòt mwayen"],
    "Référence": ["Reference", "Referencia", "Referans"],
    "N° de reçu, de transaction…": ["Receipt no., transaction no.…", "N.º de recibo, de transacción…", "Nimewo resi, tranzaksyon…"],
    "Note interne": ["Internal note", "Nota interna", "Nòt entèn"],
    "Un paiement enregistré ne se modifie plus. En cas d'erreur, annulez-le avec son motif, puis saisissez le bon : les deux restent visibles.": ["A saved payment can no longer be edited. If there is a mistake, cancel it with a reason, then enter the right one: both stay visible.", "Un pago registrado ya no se modifica. En caso de error, anúlelo con su motivo y luego ingrese el correcto: ambos quedan visibles.", "Yon peman ki anrejistre pa ka modifye ankò. Si gen erè, anile l ak rezon an, epi antre bon an : toude rete vizib."],
    "Enregistrer le paiement": ["Save the payment", "Guardar el pago", "Anrejistre peman an"],
    "Motif": ["Reason", "Motivo", "Rezon"],
    "(obligatoire, gardé au journal)": ["(required, kept in the log)", "(obligatorio, guardado en el registro)", "(obligatwa, kenbe nan jounal la)"],
    "Retour": ["Back", "Volver", "Retou"],
    "Regrouper des factures": ["Merge invoices", "Agrupar facturas", "Mete fakti ansanm"],
    "Factures à regrouper": ["Invoices to merge", "Facturas por agrupar", "Fakti pou mete ansanm"],
    "Frais de service (une fois)": ["Service fee (once)", "Cargo por servicio (una vez)", "Frè sèvis (yon sèl fwa)"],
    "Regrouper": ["Merge", "Agrupar", "Mete ansanm"],
    "Contrôle de la facturation": ["Billing check", "Control de la facturación", "Kontwòl faktirasyon"],
    "Mettre à jour le statut": ["Update the status", "Actualizar el estado", "Mete estati a ajou"],
    "Nouveau statut": ["New status", "Nuevo estado", "Nouvo estati"],
    "Reçu": ["Received", "Recibido", "Resevwa"],
    "Emballé": ["Packed", "Embalado", "Anbale"],
    "Embarqué": ["Shipped", "Embarcado", "Anbake"],
    "Transféré à la succursale": ["Transferred to branch", "Transferido a la sucursal", "Transfere nan siksisal"],
    "Disponible": ["Available", "Disponible", "Disponib"],
    "Livré": ["Delivered", "Entregado", "Livre"],
    "Ex. Retrait possible à partir de demain 10 h": ["E.g. Pickup possible from tomorrow 10 a.m.", "Ej. Retiro posible a partir de mañana a las 10", "Egz. Ou ka vin chèche l apati demen 10 è"],
    "Motif de la correction": ["Reason for the correction", "Motivo de la corrección", "Rezon koreksyon an"],
    "(interne, obligatoire)": ["(internal, required)", "(interno, obligatorio)", "(entèn, obligatwa)"],
    "par e-mail et WhatsApp que son colis est disponible": ["by email and WhatsApp that the package is available", "por correo y WhatsApp de que su paquete está disponible", "pa imèl ak WhatsApp ke koli li disponib"],
    "Historique": ["History", "Historial", "Istorik"],
    "Messages envoyés au client": ["Messages sent to the customer", "Mensajes enviados al cliente", "Mesaj ki voye bay kliyan an"],
    "Imprimer l'étiquette d'expédition": ["Print the shipping label", "Imprimir la etiqueta de envío", "Enprime etikèt ekspedisyon an"],
    "Modifier les informations du colis": ["Edit the package details", "Modificar los datos del paquete", "Modifye enfòmasyon koli a"],
    "Supprimer ce colis": ["Delete this package", "Eliminar este paquete", "Efase koli sa a"],
    "Mettre à jour": ["Update", "Actualizar", "Mete ajou"],
    "Client prévenu": ["Customer notified", "Cliente avisado", "Kliyan an avèti"],
    "Enregistrer un autre colis": ["Register another package", "Registrar otro paquete", "Anrejistre yon lòt koli"],
    "Parcours": ["Journey", "Recorrido", "Pakou"],
    "Aperçu de l'e-mail": ["Email preview", "Vista previa del correo", "Apèsi imèl la"],
    "Aperçu de l’e-mail": ["Email preview", "Vista previa del correo", "Apèsi imèl la"],
    "Aperçu de l'e-mail envoyé au client": ["Preview of the email sent to the customer", "Vista previa del correo enviado al cliente", "Apèsi imèl ki voye bay kliyan an"],
    "Rubriques des réglages": ["Settings sections", "Secciones de ajustes", "Seksyon paramèt"],
    "Affichage": ["Display", "Pantalla", "Afichaj"],
    "Gardés sur cet appareil seulement : chaque membre de l'équipe règle le sien.": ["Kept on this device only: each team member sets their own.", "Guardados solo en este dispositivo: cada miembro del equipo ajusta el suyo.", "Kenbe sou aparèy sa a sèlman : chak manm ekip la regle pa l."],
    "Claire, sombre, ou celle du système de cet appareil.": ["Light, dark, or this device's system setting.", "Clara, oscura o la del sistema de este dispositivo.", "Klè, fonse, oswa sa sistèm aparèy sa a."],
    "Animations": ["Animations", "Animaciones", "Animasyon"],
    "Les cartes qui apparaissent au défilement, le léger relief des fonds. Coupées d'office si le système demande moins d'animations.": ["Cards that appear on scroll, the slight depth of backgrounds. Turned off automatically if the system asks for less motion.", "Las tarjetas que aparecen al desplazarse, el ligero relieve de los fondos. Desactivadas si el sistema pide menos animaciones.", "Kat ki parèt lè w ap desann, ti relyèf fon yo. Yo koupe otomatikman si sistèm nan mande mwens animasyon."],
    "Période de la vue générale": ["Overview period", "Período de la vista general", "Peryòd apèsi jeneral la"],
    "Celle qui s'affiche à l'ouverture du tableau de bord.": ["The one shown when the dashboard opens.", "La que se muestra al abrir el panel.", "Sa ki parèt lè tablo de bò a louvri."],
    "Lignes par page": ["Rows per page", "Filas por página", "Liy pa paj"],
    "Listes des colis, des clients et des colis à traiter.": ["Lists of packages, customers and packages to handle.", "Listas de paquetes, clientes y paquetes por tratar.", "Lis koli, kliyan ak koli pou trete."],
    "Colis « sans mouvement »": ["Packages \"without movement\"", "Paquetes «sin movimiento»", "Koli « san mouvman »"],
    "Aucun événement depuis ce nombre de jours : chiffre, alerte et liste à traiter.": ["No event for this number of days: figure, alert and list to handle.", "Ningún evento desde este número de días: cifra, alerta y lista por tratar.", "Pa gen evènman depi kantite jou sa a : chif, alèt ak lis pou trete."],
    "Menu latéral réduit": ["Collapsed side menu", "Menú lateral reducido", "Meni bò a redui"],
    "Les icônes seulement, pour laisser plus de place aux listes (ordinateur).": ["Icons only, to leave more room for lists (computer).", "Solo los iconos, para dejar más espacio a las listas (ordenador).", "Ikòn yo sèlman, pou kite plis plas pou lis yo (òdinatè)."],
    "Secondes dans l'horloge": ["Seconds in the clock", "Segundos en el reloj", "Segonn nan revèy la"],
    "L'heure en haut de l'écran, à la seconde près.": ["The time at the top of the screen, to the second.", "La hora arriba de la pantalla, al segundo.", "Lè a anlè ekran an, jiska segonn."],
    "Notifications du poste de travail": ["Workstation notifications", "Notificaciones de la estación de trabajo", "Notifikasyon pòs travay la"],
    "Une notification du système quand une alerte apparaît (action requise, facture en retard…) et que la fenêtre n'est pas au premier plan.": ["A system notification when an alert appears (action required, overdue invoice…) and the window is not in the foreground.", "Una notificación del sistema cuando aparece una alerta (acción requerida, factura atrasada…) y la ventana no está en primer plano.", "Yon notifikasyon sistèm lè yon alèt parèt (aksyon obligatwa, fakti an reta…) epi fenèt la pa devan."],
    "Permissions": ["Permissions", "Permisos", "Pèmisyon"],
    "Un rôle ne se change que depuis l'onglet « Équipe », par un administrateur. La base vérifie chaque permission à chaque action : un menu masqué ici n'est qu'un confort.": ["A role can only be changed from the \"Team\" tab, by an administrator. The database checks each permission on every action: a menu hidden here is only a convenience.", "Un rol solo se cambia desde la pestaña «Equipo», por un administrador. La base verifica cada permiso en cada acción: un menú oculto aquí es solo una comodidad.", "Se sèlman nan onglè « Ekip » la yon administratè ka chanje yon wòl. Baz la verifye chak pèmisyon nan chak aksyon : yon meni ki kache isit la se yon konfò sèlman."],
    "Voir ce que chaque rôle peut faire": ["See what each role can do", "Ver lo que puede hacer cada rol", "Wè sa chak wòl ka fè"],
    "Ouvrir le poste de scan": ["Open the scan station", "Abrir el puesto de escaneo", "Louvri pòs eskanè a"],
    "Données": ["Data", "Datos", "Done"],
    "Mises à jour en direct": ["Live updates", "Actualizaciones en directo", "Mizajou an dirèk"],
    "Périodes": ["Periods", "Períodos", "Peryòd"],
    "Comptées en jours de Santo Domingo": ["Counted in Santo Domingo days", "Contados en días de Santo Domingo", "Konte an jou Santo Domingo"],
    "Date et heure affichées": ["Date and time shown", "Fecha y hora mostradas", "Dat ak lè ki parèt"],
    "Celles de cet appareil": ["Those of this device", "Las de este dispositivo", "Sa aparèy sa a"],
    "Application": ["Application", "Aplicación", "Aplikasyon"],
    "Raccourcis": ["Shortcuts", "Atajos", "Rakousi"],
    "recherche rapide ·": ["quick search ·", "búsqueda rápida ·", "rechèch rapid ·"],
    "Maj": ["Shift", "Mayús", "Maj"],
    "poste de scan ·": ["scan station ·", "puesto de escaneo ·", "pòs eskanè ·"],
    "Échap": ["Esc", "Esc", "Esc"],
    "fermer": ["close", "cerrar", "fèmen"],
    "Tarif, frais de service, statuts, permissions : ces règles vivent dans la base de données et ne se changent pas depuis cet écran.": ["Rate, service fee, statuses, permissions: these rules live in the database and are not changed from this screen.", "Tarifa, cargo por servicio, estados, permisos: estas reglas viven en la base de datos y no se cambian desde esta pantalla.", "Tarif, frè sèvis, estati, pèmisyon : règ sa yo nan baz done a, yo pa chanje depi ekran sa a."],
    "Rétablir l'affichage par défaut": ["Restore the default display", "Restablecer la vista predeterminada", "Remete afichaj pa defo a"],
    "Terminé": ["Done", "Listo", "Fini"],
    "Cochez les blocs à afficher et rangez-les avec les flèches. Gardé sur cet appareil seulement.": ["Check the blocks to show and order them with the arrows. Kept on this device only.", "Marque los bloques que desea mostrar y ordénelos con las flechas. Guardado solo en este dispositivo.", "Make blòk pou afiche yo epi ranje yo ak flèch yo. Kenbe sou aparèy sa a sèlman."],
    "Langue du tableau de bord": ["Dashboard language", "Idioma del panel", "Lang tablo de bò a"],
    "Langue": ["Language", "Idioma", "Lang"],
    "E-mail ou mot de passe incorrect.": ["Incorrect email or password.", "Correo o contraseña incorrectos.", "Imèl oswa modpas la pa bon."],
    "Connexion impossible. Vérifiez la connexion Internet, puis réessayez.": ["Unable to connect. Check the Internet connection, then try again.", "No se puede conectar. Verifique la conexión a Internet y vuelva a intentarlo.", "Koneksyon enposib. Verifye koneksyon Entènèt la, epi eseye ankò."],
    "Action réservée : votre rôle ne le permet pas, ou la session a expiré (reconnectez-vous).": ["Restricted action: your role does not allow it, or the session has expired (log in again).", "Acción reservada: su rol no lo permite o la sesión ha caducado (vuelva a iniciar sesión).", "Aksyon rezève : wòl ou pa pèmèt li, oswa sesyon an ekspire (rekonekte)."],
    "Trop de tentatives. Patientez quelques minutes.": ["Too many attempts. Wait a few minutes.", "Demasiados intentos. Espere unos minutos.", "Twòp tantativ. Tann kèk minit."],
    "Ce colis n’existe plus : rechargez la liste.": ["This package no longer exists: reload the list.", "Este paquete ya no existe: recargue la lista.", "Koli sa a pa egziste ankò : rechaje lis la."],
    "Client introuvable : choisissez un client existant.": ["Customer not found: choose an existing customer.", "Cliente no encontrado: elija un cliente existente.", "Kliyan pa jwenn : chwazi yon kliyan ki egziste."],
    "Poids invalide : indiquez un nombre de livres supérieur à zéro.": ["Invalid weight: enter a number of pounds above zero.", "Peso no válido: indique un número de libras mayor que cero.", "Pwa a pa valab : mete yon kantite liv ki plis pase zewo."],
    "Décrivez le contenu du colis.": ["Describe the package contents.", "Describa el contenido del paquete.", "Dekri kontni koli a."],
    "Ce changement de statut n’est pas permis.": ["This status change is not allowed.", "Este cambio de estado no está permitido.", "Chanjman estati sa a pa pèmèt."],
    "Le colis a changé de statut entre-temps : rechargez la liste.": ["The package changed status in the meantime: reload the list.", "El paquete cambió de estado mientras tanto: recargue la lista.", "Estati koli a chanje antretan : rechaje lis la."],
    "Indiquez l’agence où le client peut retirer son colis.": ["Enter the branch where the customer can pick up the package.", "Indique la agencia donde el cliente puede retirar su paquete.", "Endike ajans kote kliyan an ka vin chèche koli li."],
    "Ce colis est déjà sur une facture.": ["This package is already on an invoice.", "Este paquete ya está en una factura.", "Koli sa a deja sou yon fakti."],
    "Données incomplètes.": ["Incomplete data.", "Datos incompletos.", "Done yo pa konplè."],
    "Cette facture n’existe plus : rechargez la liste.": ["This invoice no longer exists: reload the list.", "Esta factura ya no existe: recargue la lista.", "Fakti sa a pa egziste ankò : rechaje lis la."],
    "Ce paiement dépasse ce qui reste à payer.": ["This payment exceeds what is left to pay.", "Este pago supera lo que queda por pagar.", "Peman sa a depase sa ki rete pou peye."],
    "Indiquez le motif.": ["Enter the reason.", "Indique el motivo.", "Endike rezon an."],
    "Une erreur est survenue. Réessayez.": ["An error occurred. Try again.", "Se produjo un error. Vuelva a intentarlo.", "Yon erè rive. Eseye ankò."],
    "Renseignez votre e-mail et votre mot de passe.": ["Enter your email and password.", "Indique su correo y su contraseña.", "Mete imèl ou ak modpas ou."],
    "Connexion…": ["Logging in…", "Conectando…", "Koneksyon…"],
    "La date de fin est avant la date de début.": ["The end date is before the start date.", "La fecha de fin es anterior a la de inicio.", "Dat fen an anvan dat kòmansman an."],
    "Étiquette": ["Label", "Etiqueta", "Etikèt"],
    "Voir la facture": ["View invoice", "Ver la factura", "Wè fakti a"],
    "Ouverture…": ["Opening…", "Abriendo…", "Ap louvri…"],
    "Client supprimé": ["Deleted customer", "Cliente eliminado", "Kliyan efase"],
    "Aucun colis ne correspond à ces filtres.": ["No package matches these filters.", "Ningún paquete coincide con estos filtros.", "Pa gen koli ki koresponn ak filtè sa yo."],
    "Aucun colis en cours. Cliquez sur « Enregistrer un colis » à la réception d’un paquet à Miami.": ["No packages in progress. Click \"Register a package\" when a parcel arrives in Miami.", "Ningún paquete en curso. Haga clic en «Registrar un paquete» al recibir un paquete en Miami.", "Pa gen koli an kou. Klike sou « Anrejistre yon koli » lè yon pake rive Miami."],
    "Cette action ne peut pas être annulée.": ["This action cannot be undone.", "Esta acción no se puede deshacer.", "Aksyon sa a pa ka anile."],
    "Colis supprimé.": ["Package deleted.", "Paquete eliminado.", "Koli efase."],
    "Inscrit le": ["Registered on", "Inscrito el", "Enskri le"],
    "Non disponible": ["Not available", "No disponible", "Pa disponib"],
    "Aucun colis en cours": ["No packages in progress", "Ningún paquete en curso", "Pa gen koli an kou"],
    "Rien à payer": ["Nothing to pay", "Nada que pagar", "Anyen pou peye"],
    "factures ouvertes": ["open invoices", "facturas abiertas", "fakti ouvè"],
    "facture ouverte": ["open invoice", "factura abierta", "fakti ouvè"],
    "Ses colis": ["Their packages", "Sus paquetes", "Koli li yo"],
    "+ Colis": ["+ Package", "+ Paquete", "+ Koli"],
    "Ses factures": ["Their invoices", "Sus facturas", "Fakti li yo"],
    "Aucun client ne correspond à cette recherche.": ["No customer matches this search.", "Ningún cliente coincide con esta búsqueda.", "Pa gen kliyan ki koresponn ak rechèch sa a."],
    "Aucun client inscrit pour l’instant. Les comptes créés sur le site apparaissent ici, avec leur code GSE.": ["No registered customers yet. Accounts created on the website appear here, with their GSE code.", "Ningún cliente inscrito por ahora. Las cuentas creadas en el sitio aparecen aquí, con su código GSE.", "Pa gen kliyan enskri pou kounye a. Kont ki kreye sou sit la ap parèt isit la, ak kòd GSE yo."],
    "Payée en partie": ["Partly paid", "Pagada en parte", "Peye an pati"],
    "Payée": ["Paid", "Pagada", "Peye"],
    "Annulée": ["Cancelled", "Anulada", "Anile"],
    "factures échues": ["overdue invoices", "facturas vencidas", "fakti ki depase dat"],
    "facture échue": ["overdue invoice", "factura vencida", "fakti ki depase dat"],
    "Aucune facture échue": ["No overdue invoices", "Ninguna factura vencida", "Pa gen fakti ki depase dat"],
    "Lien de paiement prêt": ["Payment link ready", "Enlace de pago listo", "Lyen peman pare"],
    "Échue le": ["Due on", "Vencida el", "Dat limit"],
    "Avant le": ["Before", "Antes del", "Anvan"],
    "Encaisser": ["Collect", "Cobrar", "Touche"],
    "Imprimer": ["Print", "Imprimir", "Enprime"],
    "Voir": ["View", "Ver", "Wè"],
    "Détails": ["Details", "Detalles", "Detay"],
    "Aucune facture à payer. Créez-en une avec « Nouvelle facture ».": ["No invoices to pay. Create one with \"New invoice\".", "Ninguna factura por pagar. Cree una con «Nueva factura».", "Pa gen fakti pou peye. Kreye youn ak « Nouvo fakti »."],
    "Aucune facture pour ce filtre.": ["No invoices for this filter.", "Ninguna factura para este filtro.", "Pa gen fakti pou filtè sa a."],
    "Enregistrement…": ["Saving…", "Guardando…", "Ap anrejistre…"],
    "Facture mise à jour.": ["Invoice updated.", "Factura actualizada.", "Fakti a mete ajou."],
    "Paiement annulé.": ["Payment cancelled.", "Pago anulado.", "Peman an anile."],
    "Annuler la facture": ["Cancel the invoice", "Anular la factura", "Anile fakti a"],
    "Annuler le paiement": ["Cancel the payment", "Anular el pago", "Anile peman an"],
    "Erreur": ["Error", "Error", "Erè"],
    "À regarder": ["To check", "Por revisar", "Pou gade"],
    "Pour info": ["For information", "Para información", "Pou enfòmasyon"],
    "Rien d’anormal": ["Nothing unusual", "Nada anormal", "Pa gen anyen ki pa nòmal"],
    "Aucune incohérence trouvée.": ["No inconsistency found.", "No se encontró ninguna incoherencia.", "Pa jwenn okenn enkoerans."],
    "Créer un client": ["Create a customer", "Crear un cliente", "Kreye yon kliyan"],
    "Modifier un client": ["Edit a customer", "Modificar un cliente", "Modifye yon kliyan"],
    "Voir les colis": ["View packages", "Ver paquetes", "Wè koli yo"],
    "Modifier un colis": ["Edit a package", "Modificar un paquete", "Modifye yon koli"],
    "Supprimer un colis": ["Delete a package", "Eliminar un paquete", "Efase yon koli"],
    "Changer un statut": ["Change a status", "Cambiar un estado", "Chanje yon estati"],
    "Corriger une étape": ["Correct a step", "Corregir una etapa", "Korije yon etap"],
    "Historique interne": ["Internal history", "Historial interno", "Istorik entèn"],
    "Voir les factures": ["View invoices", "Ver facturas", "Wè fakti yo"],
    "Créer une facture": ["Create an invoice", "Crear una factura", "Kreye yon fakti"],
    "Modifier une facture": ["Edit an invoice", "Modificar una factura", "Modifye yon fakti"],
    "Annuler une facture": ["Cancel an invoice", "Anular una factura", "Anile yon fakti"],
    "Voir les paiements": ["View payments", "Ver pagos", "Wè peman yo"],
    "Annuler un paiement": ["Cancel a payment", "Anular un pago", "Anile yon peman"],
    "Chiffres et contrôle de la facturation": ["Billing figures and checks", "Cifras y control de la facturación", "Chif ak kontwòl faktirasyon"],
    "Voir l’équipe": ["View the team", "Ver el equipo", "Wè ekip la"],
    "Donner un rôle": ["Give a role", "Dar un rol", "Bay yon wòl"],
    "Réglages du site": ["Website settings", "Ajustes del sitio", "Paramèt sit la"],
    "Journal d’audit": ["Audit log", "Registro de auditoría", "Jounal odit"],
    "Changer le rôle": ["Change the role", "Cambiar el rol", "Chanje wòl la"],
    "Permission": ["Permission", "Permiso", "Pèmisyon"],
    "les siens": ["their own", "los suyos", "pa l yo"],
    "Aucun client ne correspond.": ["No customer matches.", "Ningún cliente coincide.", "Pa gen kliyan ki koresponn."],
    "Recherche du client…": ["Looking up the customer…", "Buscando el cliente…", "Ap chèche kliyan an…"],
    "Prix arrêté à l’enregistrement du colis.": ["Price fixed when the package was registered.", "Precio fijado al registrar el paquete.", "Pri a fikse lè koli a te anrejistre."],
    "Enregistrer les modifications": ["Save changes", "Guardar los cambios", "Anrejistre chanjman yo"],
    "Inspecté": ["Inspected", "Inspeccionado", "Enspekte"],
    "Consolidé": ["Consolidated", "Consolidado", "Konsolide"],
    "Chargé": ["Loaded", "Cargado", "Chaje"],
    "Agence où retirer le colis": ["Branch where to pick up the package", "Agencia donde retirar el paquete", "Ajans kote pou vin chèche koli a"],
    "Ex. Ciudad Juan Bosch": ["E.g. Ciudad Juan Bosch", "Ej. Ciudad Juan Bosch", "Egz. Ciudad Juan Bosch"],
    "Choisissez le nouveau statut.": ["Choose the new status.", "Elija el nuevo estado.", "Chwazi nouvo estati a."],
    "Mise à jour…": ["Updating…", "Actualizando…", "Ap mete ajou…"],
    "Colis reçu": ["Package received", "Paquete recibido", "Koli resevwa"],
    "Colis disponible": ["Package available", "Paquete disponible", "Koli disponib"],
    "Colis enregistré": ["Package registered", "Paquete registrado", "Koli anrejistre"],
    "Précédente": ["Previous", "Anterior", "Anvan"],
    "Suivante": ["Next", "Siguiente", "Apre"],
    "Étape": ["Step", "Etapa", "Etap"],
    "Ce colis n’existe plus.": ["This package no longer exists.", "Este paquete ya no existe.", "Koli sa a pa egziste ankò."],
    "Cette facture n’existe plus.": ["This invoice no longer exists.", "Esta factura ya no existe.", "Fakti sa a pa egziste ankò."],
    "Rien sur cette période.": ["Nothing in this period.", "Nada en este período.", "Anyen pandan peryòd sa a."],
    "Chargement des chiffres…": ["Loading figures…", "Cargando cifras…", "Ap chaje chif yo…"],
    "Colis reçus": ["Packages received", "Paquetes recibidos", "Koli resevwa"],
    "sur la période": ["in the period", "en el período", "pandan peryòd la"],
    "Colis livrés": ["Packages delivered", "Paquetes entregados", "Koli livre"],
    "En cours": ["In progress", "En curso", "An kou"],
    "colis au total": ["packages in total", "paquetes en total", "koli an total"],
    "Poids reçu": ["Weight received", "Peso recibido", "Pwa resevwa"],
    "Aucun colis reçu ni livré sur cette période.": ["No packages received or delivered in this period.", "Ningún paquete recibido ni entregado en este período.", "Pa gen koli ki resevwa ni livre pandan peryòd sa a."],
    "Encaissé": ["Collected", "Cobrado", "Touche"],
    "Rien de facturé ni d’encaissé sur cette période.": ["Nothing invoiced or collected in this period.", "Nada facturado ni cobrado en este período.", "Anyen pa fakti ni touche pandan peryòd sa a."],
    "aucune facture sur la période": ["no invoices in the period", "ninguna factura en el período", "pa gen fakti pandan peryòd la"],
    "du facturé déjà payé": ["of the invoiced amount already paid", "de lo facturado ya pagado", "nan sa ki fakti a deja peye"],
    "Aucune facture émise sur la période.": ["No invoices issued in the period.", "Ninguna factura emitida en el período.", "Pa gen fakti ki soti pandan peryòd la."],
    "sur ces factures": ["on these invoices", "en estas facturas", "sou fakti sa yo"],
    "Reste dû": ["Balance due", "Saldo pendiente", "Rès ki dwe"],
    "nouveaux clients": ["new customers", "nuevos clientes", "nouvo kliyan"],
    "nouveau client": ["new customer", "nuevo cliente", "nouvo kliyan"],
    "client inscrit": ["registered customer", "cliente inscrito", "kliyan enskri"],
    "clients inscrits": ["registered customers", "clientes inscritos", "kliyan enskri"],
    "Actifs sur la période": ["Active in the period", "Activos en el período", "Aktif pandan peryòd la"],
    "colis, maintenant": ["packages, now", "paquetes, ahora", "koli, kounye a"],
    "Sans mouvement": ["No movement", "Sin movimiento", "San mouvman"],
    "Clients avec solde": ["Customers with a balance", "Clientes con saldo", "Kliyan ki gen balans"],
    "Colis sans facture": ["Packages without invoice", "Paquetes sin factura", "Koli san fakti"],
    "sur aucune facture active": ["on no active invoice", "en ninguna factura activa", "sou okenn fakti aktif"],
    "aucun colis": ["no packages", "ningún paquete", "pa gen koli"],
    "Aucune ville de destination sur la période.": ["No destination city in the period.", "Ninguna ciudad de destino en el período.", "Pa gen vil destinasyon pandan peryòd la."],
    "colis sans ville": ["packages without a city", "paquetes sin ciudad", "koli san vil"],
    "les dix premières": ["the top ten", "las diez primeras", "dis premye yo"],
    "Opérations aujourd’hui": ["Operations today", "Operaciones hoy", "Operasyon jodi a"],
    "enregistrées au poste de scan": ["saved at the scan station", "registradas en el puesto de escaneo", "anrejistre nan pòs eskanè a"],
    "Sur la période": ["In the period", "En el período", "Pandan peryòd la"],
    "opérations enregistrées": ["operations saved", "operaciones registradas", "operasyon anrejistre"],
    "Dernier scan": ["Latest scan", "Último escaneo", "Dènye eskan"],
    "Aucun": ["None", "Ninguno", "Okenn"],
    "aucune opération encore": ["no operations yet", "ninguna operación todavía", "pa gen operasyon ankò"],
    "Aucune opération sur la période.": ["No operations in the period.", "Ninguna operación en el período.", "Pa gen operasyon pandan peryòd la."],
    "Choisissez une date de début et une date de fin.": ["Choose a start date and an end date.", "Elija una fecha de inicio y una de fin.", "Chwazi yon dat kòmansman ak yon dat fen."],
    "Autres villes des colis": ["Other cities from packages", "Otras ciudades de los paquetes", "Lòt vil koli yo"],
    "Villes des colis": ["Cities from packages", "Ciudades de los paquetes", "Vil koli yo"],
    "Choisir un pays": ["Choose a country", "Elija un país", "Chwazi yon peyi"],
    "En cours (tous sauf livrés)": ["In progress (all but delivered)", "En curso (todos menos entregados)", "An kou (tout sof livre)"],
    "colis correspond aux filtres": ["package matches the filters", "paquete coincide con los filtros", "koli koresponn ak filtè yo"],
    "colis correspondent aux filtres": ["packages match the filters", "paquetes coinciden con los filtros", "koli koresponn ak filtè yo"],
    "colis dans la vue": ["packages in view", "paquetes en la vista", "koli nan apèsi a"],
    "Filtres indisponibles : la base attend la mise à jour de outils/supabase-analytics.sql (SQL Editor).": ["Filters unavailable: the database is waiting for the outils/supabase-analytics.sql update (SQL Editor).", "Filtros no disponibles: la base espera la actualización de outils/supabase-analytics.sql (SQL Editor).", "Filtè yo pa disponib : baz la ap tann mizajou outils/supabase-analytics.sql (SQL Editor)."],
    "Les filtres découpent les colis : chiffres, jours, statuts, chaîne, activité, routes. Facturation, clients, poste de scan et colis à traiter restent entiers.": ["Filters slice the packages: figures, days, statuses, chain, activity, routes. Billing, customers, scan station and packages to handle stay whole.", "Los filtros dividen los paquetes: cifras, días, estados, cadena, actividad, rutas. Facturación, clientes, puesto de escaneo y paquetes por tratar quedan completos.", "Filtè yo koupe koli yo : chif, jou, estati, chèn, aktivite, wout. Faktirasyon, kliyan, pòs eskanè ak koli pou trete rete antye."],
    "Filtre « Agence » indisponible : la base attend la mise à jour de outils/supabase-analytics.sql (SQL Editor).": ["\"Branch\" filter unavailable: the database is waiting for the outils/supabase-analytics.sql update (SQL Editor).", "Filtro «Agencia» no disponible: la base espera la actualización de outils/supabase-analytics.sql (SQL Editor).", "Filtè « Ajans » pa disponib : baz la ap tann mizajou outils/supabase-analytics.sql (SQL Editor)."],
    "En pause": ["Paused", "En pausa", "An poz"],
    "Mise à jour chaque minute": ["Updated every minute", "Actualización cada minuto", "Mizajou chak minit"],
    "Mis à jour à l’instant": ["Updated just now", "Actualizado ahora mismo", "Mete ajou kounye a menm"],
    "Direct suspendu : les chiffres restent ceux affichés.": ["Live paused: the figures stay as shown.", "Directo en pausa: las cifras quedan como se muestran.", "An dirèk kanpe : chif yo rete jan yo ye a."],
    "Direct repris.": ["Live resumed.", "Directo reanudado.", "An dirèk relanse."],
    "Chiffres clés et facturé": ["Key figures and invoiced", "Cifras clave y facturado", "Chif kle ak fakti"],
    "Colis par jour et règlement des factures": ["Packages per day and invoice payments", "Paquetes por día y pago de facturas", "Koli pa jou ak peman fakti"],
    "Destinations et clients": ["Destinations and customers", "Destinos y clientes", "Destinasyon ak kliyan"],
    "Dernière activité et colis par statut": ["Latest activity and packages by status", "Última actividad y paquetes por estado", "Dènye aktivite ak koli pa estati"],
    "Routes et villes": ["Routes and cities", "Rutas y ciudades", "Wout ak vil"],
    "Monter": ["Move up", "Subir", "Monte"],
    "Descendre": ["Move down", "Bajar", "Desann"],
    "Disposition par défaut rétablie.": ["Default layout restored.", "Disposición predeterminada restablecida.", "Dispozisyon pa defo a remete."],
    "Ouvrir": ["Open", "Abrir", "Louvri"],
    "Aucun colis en « action requise ».": ["No packages in \"action required\".", "Ningún paquete en «acción requerida».", "Pa gen koli nan « aksyon obligatwa »."],
    "Recherche impossible": ["Search unavailable", "Búsqueda imposible", "Rechèch enposib"],
    "Sur aucune facture active": ["On no active invoice", "En ninguna factura activa", "Sou okenn fakti aktif"],
    "poids non renseigné": ["weight not entered", "peso no indicado", "pwa pa endike"],
    "colis en cours": ["packages in progress", "paquetes en curso", "koli an kou"],
    "rien à payer": ["nothing to pay", "nada que pagar", "anyen pou peye"],
    "Aucune alerte critique.": ["No critical alerts.", "Ninguna alerta crítica.", "Pa gen alèt kritik."],
    "Chargement des alertes…": ["Loading alerts…", "Cargando alertas…", "Ap chaje alèt yo…"],
    "Démonstration : données enregistrées dans ce navigateur seulement": ["Demo: data saved in this browser only", "Demostración: datos guardados solo en este navegador", "Demonstrasyon : done anrejistre nan navigatè sa a sèlman"],
    "Base de données en ligne (Supabase)": ["Online database (Supabase)", "Base de datos en línea (Supabase)", "Baz done sou entènèt (Supabase)"],
    "Actives": ["On", "Activas", "Aktif"],
    "Non renseigné": ["Not entered", "No indicado", "Pa endike"],
    "Activé": ["On", "Activado", "Aktive"],
    "Coupé": ["Off", "Desactivado", "Koupe"],
    "Affichage par défaut rétabli.": ["Default display restored.", "Vista predeterminada restablecida.", "Afichaj pa defo a remete."],
    "Vous n’avez pas la permission d’utiliser le poste de scan.": ["You don't have permission to use the scan station.", "No tiene permiso para usar el puesto de escaneo.", "Ou pa gen pèmisyon pou sèvi ak pòs eskanè a."],
    "Connexion rétablie : les données sont actualisées.": ["Connection restored: data is refreshed.", "Conexión restablecida: los datos se actualizan.", "Koneksyon an tounen : done yo rafrechi."],
    "Session expirée": ["Session expired", "Sesión caducada", "Sesyon an ekspire"],
    "Reconnectez-vous pour continuer.": ["Log in again to continue.", "Vuelva a iniciar sesión para continuar.", "Rekonekte pou kontinye."],
    "Routes et destinations": ["Routes and destinations", "Rutas y destinos", "Wout ak destinasyon"],
    "Aucune donnée disponible pour cette période.": ["No data available for this period.", "Ningún dato disponible para este período.", "Pa gen done disponib pou peryòd sa a."],
    "en hausse": ["up", "en alza", "ap monte"],
    "en baisse": ["down", "en baja", "ap desann"],
    "Définitions et sources": ["Definitions and sources", "Definiciones y fuentes", "Definisyon ak sous"],
    "Voir le détail, période par période": ["See the detail, period by period", "Ver el detalle, período por período", "Wè detay la, peryòd pa peryòd"],
    "Période choisie comparée à la période précédente de même longueur.": ["Chosen period compared with the previous period of the same length.", "Período elegido comparado con el período anterior de igual duración.", "Peryòd ou chwazi a konpare ak peryòd anvan an ki gen menm longè."],
    "Expédiés (embarqués)": ["Shipped", "Enviados (embarcados)", "Voye (anbake)"],
    "Rendus disponibles": ["Made available", "Puestos a disposición", "Mete disponib"],
    "Passés en action requise": ["Moved to action required", "Pasados a acción requerida", "Pase nan aksyon obligatwa"],
    "Clients inscrits (fin de période)": ["Registered customers (end of period)", "Clientes inscritos (fin del período)", "Kliyan enskri (fen peryòd la)"],
    "Nouveaux clients": ["New customers", "Nuevos clientes", "Nouvo kliyan"],
    "Argent": ["Money", "Dinero", "Lajan"],
    "Reste sur les factures de la période": ["Remaining on the period's invoices", "Pendiente en las facturas del período", "Rès sou fakti peryòd la"],
    "dû aujourd’hui": ["due today", "pendiente hoy", "dwe jodi a"],
    "Créances en fin de période": ["Receivables at end of period", "Cuentas por cobrar al final del período", "Dèt kliyan nan fen peryòd la"],
    "Tendances": ["Trends", "Tendencias", "Tandans"],
    "Opérations au scanner": ["Scanner operations", "Operaciones en el escáner", "Operasyon nan eskanè a"],
    "Colis par statut, maintenant": ["Packages by status, now", "Paquetes por estado, ahora", "Koli pa estati, kounye a"],
    "Voir le tableau": ["View the table", "Ver la tabla", "Wè tablo a"],
    "Période précédente": ["Previous period", "Período anterior", "Peryòd anvan"],
    "Pourcentage": ["Percentage", "Porcentaje", "Pousantaj"],
    "Volume": ["Volume", "Volumen", "Volim"],
    "Poids total": ["Total weight", "Peso total", "Pwa total"],
    "Poids moyen": ["Average weight", "Peso medio", "Pwa mwayen"],
    "colis pesés seulement": ["weighed packages only", "solo paquetes pesados", "koli ki peze sèlman"],
    "Prix moyen d’un colis": ["Average package price", "Precio medio de un paquete", "Pri mwayen yon koli"],
    "prix arrêté à l’enregistrement": ["price fixed at registration", "precio fijado al registrar", "pri fikse nan anrejistreman"],
    "Facture moyenne": ["Average invoice", "Factura media", "Fakti mwayen"],
    "Colis reçus et livrés": ["Packages received and delivered", "Paquetes recibidos y entregados", "Koli resevwa ak livre"],
    "par jour": ["per day", "por día", "pa jou"],
    "par semaine": ["per week", "por semana", "pa semèn"],
    "par mois": ["per month", "por mes", "pa mwa"],
    "Volume par période": ["Volume by period", "Volumen por período", "Volim pa peryòd"],
    "Poids": ["Weight", "Peso", "Pwa"],
    "Expédiés": ["Shipped", "Enviados", "Voye"],
    "Livrés, expédiés": ["Delivered, shipped", "Entregados, enviados", "Livre, voye"],
    "Prix moyen": ["Average price", "Precio medio", "Pri mwayen"],
    "Reçu → Embarqué (entrepôt de Miami)": ["Received → Shipped (Miami warehouse)", "Recibido → Embarcado (almacén de Miami)", "Resevwa → Anbake (depo Miami)"],
    "Embarqué → Disponible (acheminement)": ["Shipped → Available (transit)", "Embarcado → Disponible (tránsito)", "Anbake → Disponib (transpò)"],
    "Disponible → Livré (retrait)": ["Available → Delivered (pickup)", "Disponible → Entregado (retiro)", "Disponib → Livre (retrè)"],
    "Reçu → Livré (total)": ["Received → Delivered (total)", "Recibido → Entregado (total)", "Resevwa → Livre (total)"],
    "Temps de traitement": ["Processing time", "Tiempo de tratamiento", "Tan tretman"],
    "Aucune étape achevée pendant cette période.": ["No step completed in this period.", "Ninguna etapa completada en este período.", "Pa gen etap ki fini pandan peryòd sa a."],
    "Moyenne": ["Average", "Media", "Mwayèn"],
    "Médiane": ["Median", "Mediana", "Medyàn"],
    "Minimum": ["Minimum", "Mínimo", "Minimòm"],
    "Maximum": ["Maximum", "Máximo", "Maksimòm"],
    "Valeurs extrêmes": ["Outliers", "Valores extremos", "Valè ekstrèm"],
    "Durées négatives": ["Negative durations", "Duraciones negativas", "Dire negatif"],
    "Livraison": ["Delivery", "Entrega", "Livrezon"],
    "Livrés pendant la période": ["Delivered in the period", "Entregados en el período", "Livre pandan peryòd la"],
    "Taux de livraison de la cohorte": ["Cohort delivery rate", "Tasa de entrega de la cohorte", "To livrezon gwoup la"],
    "Même taux, période précédente": ["Same rate, previous period", "Misma tasa, período anterior", "Menm to, peryòd anvan"],
    "Délai médian Reçu → Livré": ["Median time Received → Delivered", "Plazo mediano Recibido → Entregado", "Tan medyàn Resevwa → Livre"],
    "Transitions de statut": ["Status transitions", "Transiciones de estado", "Tranzisyon estati"],
    "Transition": ["Transition", "Transición", "Tranzisyon"],
    "Nombre": ["Count", "Número", "Kantite"],
    "Durée moyenne": ["Average duration", "Duración media", "Dire mwayèn"],
    "Durée médiane": ["Median duration", "Duración mediana", "Dire medyàn"],
    "Aucun changement de statut pendant cette période.": ["No status change in this period.", "Ningún cambio de estado en este período.", "Pa gen chanjman estati pandan peryòd sa a."],
    "Colis sans progression, maintenant": ["Packages without progress, now", "Paquetes sin avance, ahora", "Koli ki pa avanse, kounye a"],
    "Moins de 24 h": ["Less than 24 h", "Menos de 24 h", "Mwens pase 24 è"],
    "72 h à 7 jours": ["72 h to 7 days", "72 h a 7 días", "72 è a 7 jou"],
    "Plus de 7 jours": ["More than 7 days", "Más de 7 días", "Plis pase 7 jou"],
    "Colis passés en action requise": ["Packages moved to action required", "Paquetes pasados a acción requerida", "Koli ki pase nan aksyon obligatwa"],
    "En action requise maintenant": ["In action required now", "En acción requerida ahora", "Nan aksyon obligatwa kounye a"],
    "Durée moyenne dans l’état": ["Average time in that state", "Duración media en el estado", "Dire mwayèn nan eta a"],
    "Clients concernés": ["Customers concerned", "Clientes afectados", "Kliyan konsène"],
    "Action requise par destination": ["Action required by destination", "Acción requerida por destino", "Aksyon obligatwa pa destinasyon"],
    "Aucun colis passé en action requise pendant cette période.": ["No package moved to action required in this period.", "Ningún paquete pasó a acción requerida en este período.", "Pa gen koli ki pase nan aksyon obligatwa pandan peryòd sa a."],
    "Notes les plus fréquentes": ["Most frequent notes", "Notas más frecuentes", "Nòt ki parèt pi souvan"],
    "Note": ["Note", "Nota", "Nòt"],
    "Fois": ["Times", "Veces", "Fwa"],
    "Aucune note.": ["No notes.", "Ninguna nota.", "Pa gen nòt."],
    "Départ d’un colis": ["Package departure", "Salida de un paquete", "Depa yon koli"],
    "Inscrits (fin de période)": ["Registered (end of period)", "Inscritos (fin del período)", "Enskri (fen peryòd la)"],
    "Nouveaux": ["New", "Nuevos", "Nouvo"],
    "Actifs": ["Active", "Activos", "Aktif"],
    "Inactifs": ["Inactive", "Inactivos", "Inaktif"],
    "Colis par client actif": ["Packages per active customer", "Paquetes por cliente activo", "Koli pa kliyan aktif"],
    "Activité des clients actifs": ["Activity of active customers", "Actividad de los clientes activos", "Aktivite kliyan aktif yo"],
    "Segments": ["Segments", "Segmentos", "Segman"],
    "Activité": ["Activity", "Actividad", "Aktivite"],
    "Petite": ["Low", "Baja", "Piti"],
    "Forte": ["High", "Alta", "Fò"],
    "Définition": ["Definition", "Definición", "Definisyon"],
    "Clients les plus actifs": ["Most active customers", "Clientes más activos", "Kliyan ki pi aktif"],
    "Par nombre de colis": ["By number of packages", "Por número de paquetes", "Pa kantite koli"],
    "Par poids": ["By weight", "Por peso", "Pa pwa"],
    "Par montant facturé": ["By amount invoiced", "Por importe facturado", "Pa montan fakti"],
    "Par montant payé": ["By amount paid", "Por importe pagado", "Pa montan peye"],
    "Par solde": ["By balance", "Por saldo", "Pa balans"],
    "Solde (maintenant)": ["Balance (now)", "Saldo (ahora)", "Balans (kounye a)"],
    "Aucun client actif pendant cette période.": ["No active customers in this period.", "Ningún cliente activo en este período.", "Pa gen kliyan aktif pandan peryòd sa a."],
    "Client actif": ["Active customer", "Cliente activo", "Kliyan aktif"],
    "Facturé et encaissé": ["Invoiced and collected", "Facturado y cobrado", "Fakti ak touche"],
    "Factures émises": ["Invoices issued", "Facturas emitidas", "Fakti ki soti"],
    "Dont transport": ["Of which transport", "De ello transporte", "Ladan l transpò"],
    "Dont frais de service": ["Of which service fees", "De ello cargos por servicio", "Ladan l frè sèvis"],
    "Dû en fin de période": ["Due at end of period", "Pendiente al final del período", "Dwe nan fen peryòd la"],
    "Créances, maintenant": ["Receivables, now", "Cuentas por cobrar, ahora", "Dèt kliyan, kounye a"],
    "À recouvrer": ["To recover", "Por recuperar", "Pou rekipere"],
    "Impayées": ["Unpaid", "Impagadas", "Pa peye"],
    "rien reçu": ["nothing received", "nada recibido", "anyen pa resevwa"],
    "Non échues": ["Not yet due", "No vencidas", "Poko rive dat"],
    "Sans échéance": ["No due date", "Sin vencimiento", "San dat limit"],
    "0 à 30 jours": ["0 to 30 days", "0 a 30 días", "0 a 30 jou"],
    "31 à 60 jours": ["31 to 60 days", "31 a 60 días", "31 a 60 jou"],
    "61 à 90 jours": ["61 to 90 days", "61 a 90 días", "61 a 90 jou"],
    "Plus de 90 jours": ["More than 90 days", "Más de 90 días", "Plis pase 90 jou"],
    "Âge des créances (depuis l’émission)": ["Age of receivables (since issue)", "Antigüedad de las cuentas por cobrar (desde la emisión)", "Laj dèt yo (depi fakti a soti)"],
    "Âge": ["Age", "Antigüedad", "Laj"],
    "Montant dû": ["Amount due", "Importe pendiente", "Montan ki dwe"],
    "Encaissé par moyen de paiement": ["Collected by payment method", "Cobrado por medio de pago", "Touche pa mwayen peman"],
    "Aucun paiement reçu pendant cette période.": ["No payments received in this period.", "Ningún pago recibido en este período.", "Pa gen peman resevwa pandan peryòd sa a."],
    "Dépenses, dettes et résultat": ["Expenses, debts and result", "Gastos, deudas y resultado", "Depans, dèt ak rezilta"],
    "Âge des créances": ["Age of receivables", "Antigüedad de las cuentas por cobrar", "Laj dèt yo"],
    "Transport facturé": ["Transport invoiced", "Transporte facturado", "Transpò fakti"],
    "Délai moyen Reçu → Livré": ["Average time Received → Delivered", "Plazo medio Recibido → Entregado", "Tan mwayen Resevwa → Livre"],
    "Aucun colis reçu pendant cette période.": ["No packages received in this period.", "Ningún paquete recibido en este período.", "Pa gen koli resevwa pandan peryòd sa a."],
    "Évolution": ["Change", "Evolución", "Evolisyon"],
    "Aucun colis sur ces deux périodes.": ["No packages in these two periods.", "Ningún paquete en estos dos períodos.", "Pa gen koli nan de peryòd sa yo."],
    "Villes les plus fréquentes": ["Most frequent cities", "Ciudades más frecuentes", "Vil ki parèt pi souvan"],
    "colis sans ville indiquée": ["packages with no city given", "paquetes sin ciudad indicada", "koli san vil endike"],
    "Ville": ["City", "Ciudad", "Vil"],
    "Aucune ville indiquée.": ["No city given.", "Ninguna ciudad indicada.", "Pa gen vil endike."],
    "Livrés, taux": ["Delivered, rate", "Entregados, tasa", "Livre, to"],
    "Opérations au poste de scan": ["Scan station operations", "Operaciones en el puesto de escaneo", "Operasyon nan pòs eskanè a"],
    "Colis scannés": ["Packages scanned", "Paquetes escaneados", "Koli eskane"],
    "Jours avec des scans": ["Days with scans", "Días con escaneos", "Jou ki gen eskan"],
    "Intervalle médian entre deux opérations": ["Median interval between two operations", "Intervalo mediano entre dos operaciones", "Entèval medyàn ant de operasyon"],
    "même compte, même jour": ["same account, same day", "misma cuenta, mismo día", "menm kont, menm jou"],
    "Opération": ["Operation", "Operación", "Operasyon"],
    "Aucune opération pendant cette période.": ["No operations in this period.", "Ninguna operación en este período.", "Pa gen operasyon pandan peryòd sa a."],
    "Par compte": ["By account", "Por cuenta", "Pa kont"],
    "Compte": ["Account", "Cuenta", "Kont"],
    "Jours": ["Days", "Días", "Jou"],
    "Par lieu": ["By location", "Por lugar", "Pa kote"],
    "Lieu du poste": ["Station location", "Lugar del puesto", "Kote pòs la"],
    "Lieu non indiqué": ["Location not given", "Lugar no indicado", "Kote pa endike"],
    "Indicateurs de qualité": ["Quality indicators", "Indicadores de calidad", "Endikatè kalite"],
    "Indicateur": ["Indicator", "Indicador", "Endikatè"],
    "Conformes": ["Compliant", "Conformes", "Konfòm"],
    "Part": ["Share", "Proporción", "Pati"],
    "Aucune donnée": ["No data", "Ningún dato", "Pa gen done"],
    "Anomalies": ["Anomalies", "Anomalías", "Anomali"],
    "Anomalie": ["Anomaly", "Anomalía", "Anomali"],
    "Facturation": ["Billing", "Facturación", "Faktirasyon"],
    "Anomalies de facturation": ["Billing anomalies", "Anomalías de facturación", "Anomali faktirasyon"],
    "Type": ["Type", "Tipo", "Tip"],
    "Gravité": ["Severity", "Gravedad", "Gravite"],
    "Aucune anomalie de facturation.": ["No billing anomalies.", "Ninguna anomalía de facturación.", "Pa gen anomali faktirasyon."],
    "Chargement des données…": ["Loading data…", "Cargando datos…", "Ap chaje done yo…"],
    "Rien à exporter : chargez d’abord une rubrique.": ["Nothing to export: load a section first.", "Nada que exportar: cargue primero una sección.", "Anyen pou ekspòte : chaje yon seksyon anvan."],
    "Rien à imprimer : chargez d’abord une rubrique.": ["Nothing to print: load a section first.", "Nada que imprimir: cargue primero una sección.", "Anyen pou enprime : chaje yon seksyon anvan."],
    "Montant du transport": ["Transport amount", "Importe del transporte", "Montan transpò a"],
    "Lieu actuel": ["Current location", "Ubicación actual", "Kote li ye kounye a"],
    "Expéditeur": ["Sender", "Remitente", "Moun ki voye"],
    "Suivi du vendeur": ["Seller tracking", "Seguimiento del vendedor", "Swivi machann nan"],
    "Voir le client": ["View customer", "Ver cliente", "Wè kliyan an"],
    "Membre de l’équipe": ["Team member", "Miembro del equipo", "Manm ekip la"],
    "Paiement reçu": ["Payment received", "Pago recibido", "Peman resevwa"],
    "Détail": ["Detail", "Detalle", "Detay"],
    "Ouvrir la fiche": ["Open the record", "Abrir la ficha", "Louvri fich la"],
    "Ouvrir la fiche du colis": ["Open the package record", "Abrir la ficha del paquete", "Louvri fich koli a"],
    "Exemples ajoutés : 3 clients et 7 colis.": ["Examples added: 3 customers and 7 packages.", "Ejemplos añadidos: 3 clientes y 7 paquetes.", "Egzanp ajoute : 3 kliyan ak 7 koli."],
    "Recherche…": ["Searching…", "Buscando…", "Ap chèche…"],
    "✓ COLIS TROUVÉ": ["✓ PACKAGE FOUND", "✓ PAQUETE ENCONTRADO", "✓ KOLI JWENN"],
    "COLIS DÉJÀ LIVRÉ": ["PACKAGE ALREADY DELIVERED", "PAQUETE YA ENTREGADO", "KOLI DEJA LIVRE"],
    "⚠ ACTION REQUISE": ["⚠ ACTION REQUIRED", "⚠ ACCIÓN REQUERIDA", "⚠ AKSYON OBLIGATWA"],
    "✕ COLIS INTROUVABLE": ["✕ PACKAGE NOT FOUND", "✕ PAQUETE NO ENCONTRADO", "✕ KOLI PA JWENN"],
    "⚠ CODE INVALIDE": ["⚠ INVALID CODE", "⚠ CÓDIGO NO VÁLIDO", "⚠ KÒD PA VALAB"],
    "⚠ ACTION NON AUTORISÉE": ["⚠ ACTION NOT ALLOWED", "⚠ ACCIÓN NO AUTORIZADA", "⚠ AKSYON PA OTORIZE"],
    "⚠ OPÉRATION IMPOSSIBLE": ["⚠ OPERATION NOT POSSIBLE", "⚠ OPERACIÓN IMPOSIBLE", "⚠ OPERASYON ENPOSIB"],
    "⚠ LE COLIS A CHANGÉ ENTRE-TEMPS": ["⚠ THE PACKAGE CHANGED IN THE MEANTIME", "⚠ EL PAQUETE CAMBIÓ MIENTRAS TANTO", "⚠ KOLI A CHANJE ANTRETAN"],
    "⚠ CONNEXION IMPOSSIBLE": ["⚠ CONNECTION FAILED", "⚠ CONEXIÓN IMPOSIBLE", "⚠ KONEKSYON ENPOSIB"],
    "⚠ BASE PAS À JOUR": ["⚠ DATABASE NOT UP TO DATE", "⚠ BASE NO ACTUALIZADA", "⚠ BAZ LA PA AJOU"],
    "⚠ ERREUR SERVEUR": ["⚠ SERVER ERROR", "⚠ ERROR DEL SERVIDOR", "⚠ ERÈ SÈVÈ"],
    "ℹ DÉJÀ FAIT": ["ℹ ALREADY DONE", "ℹ YA HECHO", "ℹ DEJA FÈT"],
    "Rien n’a été enregistré. Vérifiez la connexion, puis réessayez.": ["Nothing was saved. Check the connection, then try again.", "No se guardó nada. Verifique la conexión y vuelva a intentarlo.", "Anyen pa anrejistre. Verifye koneksyon an, epi eseye ankò."],
    "Origine": ["Origin", "Origen", "Orijin"],
    "Suivi vendeur": ["Seller tracking", "Seguimiento del vendedor", "Swivi machann"],
    "Localisation": ["Location", "Ubicación", "Kote"],
    "Prix du transport": ["Transport price", "Precio del transporte", "Pri transpò a"],
    "Colis livré : plus aucune opération. Une erreur se corrige depuis sa fiche, onglet Colis.": ["Package delivered: no more operations. A mistake is corrected from its record, Packages tab.", "Paquete entregado: ninguna operación más. Un error se corrige desde su ficha, pestaña Paquetes.", "Koli livre : pa gen operasyon ankò. Yon erè korije nan fich li, onglè Koli."],
    "Aucune opération permise pour ce colis à ce statut.": ["No operation allowed for this package at this status.", "Ninguna operación permitida para este paquete en este estado.", "Pa gen operasyon ki pèmèt pou koli sa a nan estati sa a."],
    "Raison, visible par le client (ex. adresse à vérifier)": ["Reason, visible to the customer (e.g. address to check)", "Motivo, visible para el cliente (ej. dirección por verificar)", "Rezon, kliyan an ka wè l (egz. adrès pou verifye)"],
    "Raison de l’action requise": ["Reason for the required action", "Motivo de la acción requerida", "Rezon aksyon obligatwa a"],
    "Agence où le client retire son colis": ["Branch where the customer picks up the package", "Agencia donde el cliente retira su paquete", "Ajans kote kliyan an vin chèche koli li"],
    "Confirmer": ["Confirm", "Confirmar", "Konfime"],
    "Réessayer": ["Try again", "Reintentar", "Eseye ankò"],
    "Rescanner": ["Scan again", "Volver a escanear", "Eskane ankò"],
    "✓ trouvé": ["✓ found", "✓ encontrado", "✓ jwenn"],
    "Tous les réglages": ["All settings", "Todos los ajustes", "Tout paramèt yo"],
    "Semaine": ["Week", "Semana", "Semèn"],
    "Jour": ["Day", "Día", "Jou"],
    "Mois": ["Month", "Mes", "Mwa"],
    "Total": ["Total", "Total", "Total"],
    "Colis reçus par jour": ["Packages received per day", "Paquetes recibidos por día", "Koli resevwa pa jou"],
    "jour": ["day", "día", "jou"],
    "jours": ["days", "días", "jou"],
    "colis": ["packages", "paquetes", "koli"],
    "client": ["customer", "cliente", "kliyan"],
    "clients": ["customers", "clientes", "kliyan"],
    "facture": ["invoice", "factura", "fakti"],
    "factures": ["invoices", "facturas", "fakti"],
    "résultat": ["result", "resultado", "rezilta"],
    "résultats": ["results", "resultados", "rezilta"],
    "lb": ["lb", "lb", "lb"],
    "aujourd’hui": ["today", "hoy", "jodi a"],
    "Reçu à l'entrepôt": ["Received at the warehouse", "Recibido en el almacén", "Resevwa nan depo a"],
    "Expédié": ["Shipped", "Enviado", "Voye"],
    "Arrivé au centre de distribution": ["Arrived at the distribution center", "Llegado al centro de distribución", "Rive nan sant distribisyon an"],
    "Action résolue": ["Action resolved", "Acción resuelta", "Aksyon rezoud"],
    "Correction": ["Correction", "Corrección", "Koreksyon"],
    "Étape mise à jour": ["Step updated", "Etapa actualizada", "Etap mete ajou"],
    "reçu": ["received", "recibido", "resevwa"],
    "reçus": ["received", "recibidos", "resevwa"],
    "emballé": ["packed", "embalado", "anbale"],
    "emballés": ["packed", "embalados", "anbale"],
    "embarqué": ["shipped", "embarcado", "anbake"],
    "embarqués": ["shipped", "embarcados", "anbake"],
    "centre de distribution": ["at distribution center", "en centro de distribución", "nan sant distribisyon"],
    "transféré à la succursale": ["transferred to branch", "transferido a la sucursal", "transfere nan siksisal"],
    "transférés à la succursale": ["transferred to branch", "transferidos a la sucursal", "transfere nan siksisal"],
    "disponible": ["available", "disponible", "disponib"],
    "disponibles": ["available", "disponibles", "disponib"],
    "livré": ["delivered", "entregado", "livre"],
    "livrés": ["delivered", "entregados", "livre"],
    "action requise": ["action required", "acción requerida", "aksyon obligatwa"],
    "en action requise": ["in action required", "en acción requerida", "nan aksyon obligatwa"],
    "payée en partie": ["partly paid", "pagada en parte", "peye an pati"],
    "payées en partie": ["partly paid", "pagadas en parte", "peye an pati"],
    "paiement": ["payment", "pago", "peman"],
    "paiements": ["payments", "pagos", "peman"],
    "Départ": ["Departure", "Salida", "Depa"],
    "nouveaux clients sur la période": ["new customers in the period", "nuevos clientes en el período", "nouvo kliyan pandan peryòd la"],
    "nouveau client sur la période": ["new customer in the period", "nuevo cliente en el período", "nouvo kliyan pandan peryòd la"],
    "clients ont un colis en cours": ["customers have a package in progress", "clientes tienen un paquete en curso", "kliyan gen yon koli an kou"],
    "client a un colis en cours": ["customer has a package in progress", "cliente tiene un paquete en curso", "kliyan gen yon koli an kou"],
    "Miami → Haïti / République dominicaine": ["Miami → Haiti / Dominican Republic", "Miami → Haití / República Dominicana", "Miami → Ayiti / Repiblik Dominikèn"],
    "Colis au statut « Action requise » : le client ou l’équipe doit agir. Les plus anciens d’abord ; la note dit pourquoi.": ["Packages in \"Action required\" status: the customer or the team must act. Oldest first; the note says why.", "Paquetes en estado «Acción requerida»: el cliente o el equipo debe actuar. Los más antiguos primero; la nota dice por qué.", "Koli nan estati « Aksyon obligatwa » : kliyan an oswa ekip la dwe aji. Pi ansyen yo an premye ; nòt la di poukisa."],
    "↗ nouveau": ["↗ new", "↗ nuevo", "↗ nouvo"],
    "nouveau": ["new", "nuevo", "nouvo"],
    "Facturé et encaissé ne se confondent pas : l’un est ce qui a été demandé, l’autre ce qui est entré.": ["Invoiced and collected are not the same: one is what was asked, the other what came in.", "Facturado y cobrado no se confunden: uno es lo que se pidió, el otro lo que entró.", "Fakti ak touche pa menm bagay : youn se sa ki te mande, lòt la se sa ki antre."],
    "Des faits chiffrés, sans explication : les causes ne se lisent pas dans les données.": ["Figures, without explanation: causes cannot be read in the data.", "Hechos en cifras, sin explicación: las causas no se leen en los datos.", "Fè an chif, san eksplikasyon : ou pa ka li kòz yo nan done yo."],
    "Le stock actuel, les huit statuts du système — les mêmes chiffres que la vue générale.": ["The current stock, the system's eight statuses — the same figures as the overview.", "El stock actual, los ocho estados del sistema — las mismas cifras que la vista general.", "Stòk kounye a, uit estati sistèm nan — menm chif ak apèsi jeneral la."],
    "Colis dont la réception à Miami (date saisie à l’arrivée) tombe dans la période. Source : colis.": ["Packages whose receipt in Miami (date entered on arrival) falls within the period. Source: packages.", "Paquetes cuya recepción en Miami (fecha ingresada a la llegada) cae en el período. Fuente: paquetes.", "Koli kote resepsyon Miami (dat ki antre lè li rive) tonbe nan peryòd la. Sous : koli."],
    "Expédiés, rendus disponibles, livrés, action requise": ["Shipped, made available, delivered, action required", "Enviados, puestos a disposición, entregados, acción requerida", "Voye, mete disponib, livre, aksyon obligatwa"],
    "Colis passés à ce statut pendant la période, chacun une fois, sans les étapes annulées par une correction. Source : les événements (colis_historique).": ["Packages moved to this status during the period, each once, without steps cancelled by a correction. Source: events (colis_historique).", "Paquetes pasados a este estado durante el período, cada uno una vez, sin las etapas anuladas por una corrección. Fuente: eventos (colis_historique).", "Koli ki pase nan estati sa a pandan peryòd la, chak yon fwa, san etap yon koreksyon anile. Sous : evènman yo (colis_historique)."],
    "Total des factures émises pendant la période, hors annulées ; montants arrêtés à la création (un changement de tarif ne les modifie pas).": ["Total of invoices issued in the period, excluding cancelled ones; amounts fixed at creation (a rate change does not modify them).", "Total de facturas emitidas en el período, sin las anuladas; importes fijados al crearse (un cambio de tarifa no los modifica).", "Total fakti ki soti pandan peryòd la, san sa ki anile yo ; montan fikse lè yo kreye (chanjman tarif pa modifye yo)."],
    "Paiements valides reçus pendant la période, quelle que soit la facture. Source : paiements.": ["Valid payments received during the period, whatever the invoice. Source: payments.", "Pagos válidos recibidos durante el período, sea cual sea la factura. Fuente: pagos.", "Peman valab resevwa pandan peryòd la, kèlkeswa fakti a. Sous : peman."],
    "Ce qui restait dû à la fin de la période, reconstitué à partir des factures et des paiements datés.": ["What was still due at the end of the period, rebuilt from dated invoices and payments.", "Lo que quedaba pendiente al final del período, reconstruido a partir de facturas y pagos fechados.", "Sa ki te rete dwe nan fen peryòd la, rekonstitye apati fakti ak peman ki gen dat."],
    "Même nombre de jours juste avant ; « ce mois » : le mois précédent aux mêmes dates ; « cette année » : l’année précédente aux mêmes dates.": ["Same number of days just before; \"this month\": the previous month on the same dates; \"this year\": the previous year on the same dates.", "Mismo número de días justo antes; «este mes»: el mes anterior en las mismas fechas; «este año»: el año anterior en las mismas fechas.", "Menm kantite jou jis anvan ; « mwa sa a » : mwa anvan an nan menm dat yo ; « ane sa a » : ane anvan an nan menm dat yo."],
    "Absent quand la période précédente vaut zéro : on écrit « nouveau » plutôt qu’un pourcentage infini.": ["Absent when the previous period is zero: \"new\" is written rather than an infinite percentage.", "Ausente cuando el período anterior vale cero: se escribe «nuevo» en lugar de un porcentaje infinito.", "Pa la lè peryòd anvan an vo zewo : nou ekri « nouvo » olye yon pousantaj enfini."],
    "La personne crée d'abord son compte sur le site (« Créer un compte »), puis vous lui donnez son rôle ici. Chaque changement est noté au journal : qui, quand, ancien et nouveau rôle. Vous ne pouvez pas changer votre propre rôle.": ["The person first creates their account on the website (\"Create an account\"), then you give them their role here. Each change is logged: who, when, old and new role. You cannot change your own role.", "La persona primero crea su cuenta en el sitio («Crear una cuenta») y luego usted le da su rol aquí. Cada cambio queda en el registro: quién, cuándo, rol anterior y nuevo. No puede cambiar su propio rol.", "Moun nan kreye kont li sou sit la anvan (« Kreye yon kont »), epi ou ba l wòl li isit la. Chak chanjman note nan jounal la : kiyès, kilè, ansyen ak nouvo wòl. Ou pa ka chanje pwòp wòl ou."],
    "Mode rapide": ["Fast mode", "Modo rápido", "Mòd rapid"],
    "Rapide": ["Fast", "Rápido", "Rapid"],
    "Détail du colis": ["Package details", "Detalle del paquete", "Detay koli"]
  };

  // Les dates (O.date et l'horloge) : mois et jours de la semaine
  var MOIS_COURTS = ['janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin', 'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.'];
  var MOIS = ['janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'];
  var JOURS = ['dimanche', 'lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi'];
  var JOURS_COURTS = ['dim.', 'lun.', 'mar.', 'mer.', 'jeu.', 'ven.', 'sam.'];
  var MOIS_T = {
    en: [['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'],
         ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December']],
    es: [['ene.', 'feb.', 'mar.', 'abr.', 'may.', 'jun.', 'jul.', 'ago.', 'sept.', 'oct.', 'nov.', 'dic.'],
         ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre']],
    ht: [['jan.', 'fev.', 'mas', 'avr.', 'me', 'jen', 'jiy.', 'out', 'sept.', 'okt.', 'nov.', 'des.'],
         ['janvye', 'fevriye', 'mas', 'avril', 'me', 'jen', 'jiyè', 'out', 'septanm', 'oktòb', 'novanm', 'desanm']]
  };
  var JOURS_T = {
    en: ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'],
    es: ['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado'],
    ht: ['dimanch', 'lendi', 'madi', 'mèkredi', 'jedi', 'vandredi', 'samdi']
  };
  var JOURS_COURTS_T = {
    en: ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'],
    es: ['dom.', 'lun.', 'mar.', 'mié.', 'jue.', 'vie.', 'sáb.'],
    ht: ['dim.', 'len.', 'mad.', 'mèk.', 'jed.', 'van.', 'sam.']
  };
  // Les débuts de phrase suivis d'une valeur (« Reçu le 12 sept. 2026 », « Payé 20,00 $ »…).
  // date : la suite doit être une date ou un texte connu ; nombre : commencer par un chiffre ;
  // libre : n'importe quelle suite (un nom, un lieu)
  var PREFIXES = [
    ['Inscrit le', 'date'], ['Reçu le', 'date'], ['Échue le', 'date'], ['Avant le', 'date'], ['Annulée le', 'date'],
    ['Annulé le', 'date'], ['Livré le', 'date'], ['Créée le', 'date'], ['Le', 'date'], ['Du', 'date'], ['au', 'date'],
    ['Payé', 'nombre'], ['payé', 'nombre'], ['Reste', 'nombre'], ['reste', 'nombre'], ['solde', 'nombre'], ['total', 'nombre'],
    ['max.', 'nombre'], ['avant :', 'nombre'], ['moyenne :', 'nombre'],
    ['Payée ·', 'libre'], ['Période précédente :', 'libre'], ['Dernier événement :', 'libre'], ['depuis', 'libre'],
    ['vers', 'libre'], ['par', 'libre'], ['via', 'libre']
  ];
  var PREFIXES_T = {
    'Payée ·': ['Paid ·', 'Pagada ·', 'Peye ·'], 'reste': ['left', 'resta', 'rete'], 'solde': ['balance', 'saldo', 'balans'],
    'total': ['total', 'total', 'total'], 'payé': ['paid', 'pagado', 'peye'],
    'Période précédente :': ['Previous period:', 'Período anterior:', 'Peryòd anvan :'],
    'Dernier événement :': ['Latest event:', 'Último evento:', 'Dènye evènman :'], 'depuis': ['for', 'desde hace', 'depi'],
    'Le': ['On', 'El', 'Le'], 'vers': ['to', 'hacia', 'pou'], 'par': ['by', 'por', 'pa'], 'via': ['via', 'vía', 'via'],
    'moyenne :': ['average:', 'media:', 'mwayèn :'], 'avant :': ['before:', 'antes:', 'anvan :'], 'max.': ['max.', 'máx.', 'maks.'],
    'Annulé le': ['Cancelled on', 'Anulado el', 'Anile le'], 'Annulée le': ['Cancelled on', 'Anulada el', 'Anile le'],
    'Livré le': ['Delivered on', 'Entregado el', 'Livre le']
  };
  // Des phrases à trous : $1… reprend un morceau tel quel, {1}… le reprend traduit
  var REGLES = [
    [/^Du (\S+) au (\S+) \(jours de Santo Domingo\)$/, ['From $1 to $2 (Santo Domingo days)', 'Del $1 al $2 (días de Santo Domingo)', 'Depi $1 rive $2 (jou Santo Domingo)']],
    [/^Le (\S+) \(jours de Santo Domingo\)$/, ['On $1 (Santo Domingo days)', 'El $1 (días de Santo Domingo)', 'Le $1 (jou Santo Domingo)']],
    [/^Du (\S+) au (\S+), comparé du (\S+) au (\S+)$/, ['From $1 to $2, compared with $3 to $4', 'Del $1 al $2, comparado con del $3 al $4', 'Depi $1 rive $2, konpare ak $3 rive $4']],
    [/^jours de Santo Domingo$/, ['Santo Domingo days', 'días de Santo Domingo', 'jou Santo Domingo']],
    [/^chiffres de (\S+)$/, ['figures as of $1', 'cifras de las $1', 'chif a $1']],
    [/^par rapport au (.+)$/, ['vs. $1', 'respecto al $1', 'konpare ak $1']],
    [/^(\d+) j ou plus$/, ['$1 d or more', '$1 d o más', '$1 j oswa plis']],
    [/^Rapide : (.+) à chaque scan$/, ['Fast: {1} on each scan', 'Rápido: {1} en cada escaneo', 'Rapid : {1} nan chak eskan']],
    [/^(.+) : (.+), contre aucun sur la période précédente\.$/, ['{1}: $2, versus none in the previous period.', '{1}: $2, frente a ninguno en el período anterior.', '{1} : $2, kont zewo nan peryòd anvan an.']],
    [/^(.+) : stable \((.+)\)\.$/, ['{1}: stable ($2).', '{1}: estable ($2).', '{1} : estab ($2).']],
    [/^(.+) \((\d+) lignes?\)$/, ['{1} ($2 rows)', '{1} ($2 filas)', '{1} ($2 liy)']],
    [/^(.+) — ([\d\s  .,]+ ?%)$/, ['{1} — $2', '{1} — $2', '{1} — $2']],
    [/^(.+) \(vous\)$/, ['$1 (you)', '$1 (usted)', '$1 (ou)']],
    [/^(.+) \(démonstration\)$/, ['{1} (demo)', '{1} (demo)', '{1} (demo)']],
    [/^Miami → ([^·]+)$/, ['Miami → {1}', 'Miami → {1}', 'Miami → {1}']],
    [/^(.+), (Haïti|République dominicaine|États-Unis)$/, ['$1, {2}', '$1, {2}', '$1, {2}']]
  ];
  // « 1 colis » : le singulier, là où le français ne change pas
  var SINGULIERS = { colis: ['package', 'paquete', 'koli'] };

  var langue = lire();
  var TEXTES = new WeakMap();      // nœud texte → { fr, pose }
  var ATTRS = new WeakMap();       // élément → { attribut: { fr, pose } }

  function lire() {
    try {
      var l = localStorage.getItem(CLE);
      return LANGUES.indexOf(l) >= 0 ? l : 'fr';
    } catch (e) { return 'fr'; }
  }

  function motsDate(t, l) {
    var i = RANG[l];
    // « 27 sept. 2026, 20:50 », « dimanche 27 septembre 2026 », « 27 sept. »
    var m = /^(?:(\S+) )?(\d{1,2}) (\S+)(?: (\d{4}))?(,? (?:à )?\d{1,2}[:h]\d{2})?$/i.exec(t);
    if (!m) return null;
    var jour = m[1] ? JOURS.indexOf(m[1].toLowerCase()) : -1;
    var court = m[1] && jour < 0 ? JOURS_COURTS.indexOf(m[1].toLowerCase()) : -1;
    if (m[1] && jour < 0 && court < 0) return null;
    var mc = MOIS_COURTS.indexOf(m[3].toLowerCase()), ml = MOIS.indexOf(m[3].toLowerCase());
    if (mc < 0 && ml < 0) return null;
    var mois = mc >= 0 ? MOIS_T[l][0][mc] : MOIS_T[l][1][ml];
    var heure = m[5] ? m[5].replace(/^,? (?:à )?/, '').replace('h', ':') : '';
    var nomJour = jour >= 0 ? JOURS_T[l][jour] : (court >= 0 ? JOURS_COURTS_T[l][court] : '');
    if (jour >= 0 && m[1].charAt(0) === m[1].charAt(0).toUpperCase()) nomJour = nomJour.charAt(0).toUpperCase() + nomJour.slice(1);
    var r = l === 'en'
      ? (nomJour ? nomJour + ', ' : '') + mois + ' ' + m[2] + (m[4] ? ', ' + m[4] : '')
      : (nomJour ? nomJour + ' ' : '') + m[2] + (l === 'es' && ml >= 0 ? ' de ' : ' ') + mois + (m[4] ? (l === 'es' && ml >= 0 ? ' de ' : ' ') + m[4] : '');
    return r + (heure ? ', ' + heure : '');
  }

  // Le français t, dans la langue l ; null si le texte n'est pas connu
  function traduire(t, l) {
    var i = RANG[l];
    if (D[t]) return D[t][i];
    var m, k;
    for (k = 0; k < REGLES.length; k++) {
      if ((m = REGLES[k][0].exec(t))) {
        return REGLES[k][1][i].replace(/\$(\d)/g, function (x, n) { return m[n]; })
          .replace(/\{(\d)\}/g, function (x, n) { var y = traduire(m[n], l); return y === null ? m[n] : y; });
      }
    }
    // « Haïti (5) », « Livrés (25 %) »
    if ((m = /^(.*\S) \(([\d\s  .,%]+)\)$/.exec(t))) {
      var a = traduire(m[1], l);
      return a === null ? null : a + ' (' + m[2] + ')';
    }
    // « · avant : 0 »
    if ((m = /^· (.+)$/.exec(t))) { var b = traduire(m[1], l); return b === null ? null : '· ' + b; }
    // Des morceaux séparés par « · » : chacun pour soi
    if (t.indexOf(' · ') > 0) {
      var connus = 0;
      var r = t.split(' · ').map(function (x) { var y = traduire(x, l); if (y !== null) connus++; return y === null ? x : y; });
      return connus ? r.join(' · ') : null;
    }
    var d = motsDate(t, l);
    if (d) return d;
    // « 12 colis », « 3 colis correspondent aux filtres », « 4 jours »
    if ((m = /^([\d\s  .,]+) (.+)$/.exec(t)) && D[m[2]]) {
      return m[1] + ' ' + (m[1].trim() === '1' && SINGULIERS[m[2]] ? SINGULIERS[m[2]][i] : D[m[2]][i]);
    }
    // « Reçu le 12 sept. 2026 », « Payé 20,00 $ », « par Marie »
    for (k = 0; k < PREFIXES.length; k++) {
      var p = PREFIXES[k][0], genre = PREFIXES[k][1];
      if (t.length <= p.length + 1 || t.indexOf(p + ' ') !== 0) continue;
      var reste = t.slice(p.length + 1);
      var tp = PREFIXES_T[p] ? PREFIXES_T[p][i] : (D[p] ? D[p][i] : null);
      if (tp === null) continue;
      var tr = motsDate(reste, l) || traduire(reste, l);
      if (genre === 'date' && tr === null) continue;
      if (genre === 'nombre' && !/^[-+−\d]/.test(reste)) continue;
      return tp + ' ' + (tr === null ? reste : tr);
    }
    var deuxPoints = l === 'ht' ? ' :' : ':';
    // « Facturé : 431,50 $ », « Départ : Miami (Medley), FL »
    if ((m = /^(.+?) : (.+)$/.exec(t)) && D[m[1]]) {
      var v = traduire(m[2], l);
      return D[m[1]][i] + deuxPoints + ' ' + (v === null ? m[2] : v);
    }
    // « Pays : », « Démonstration : »
    if ((m = /^(.*\S) ?:$/.exec(t)) && D[m[1]]) return D[m[1]][i] + deuxPoints;
    return null;
  }

  function ignore(n) {
    var e = n.nodeType === 1 ? n : n.parentElement;
    return !e || !!e.closest(IGNORES);
  }

  function texte(n) {
    if (ignore(n)) return;
    var info = TEXTES.get(n);
    var brut = n.data;
    if (info && brut === info.pose) {
      if (langue === 'fr' && info.pose !== info.fr) { info.pose = info.fr; n.data = info.fr; }
      else if (langue !== 'fr') {
        var t0 = poser(info.fr);
        if (t0 !== n.data) { info.pose = t0; n.data = t0; }
      }
      return;
    }
    // Un nouveau texte (écrit par la page) : en français
    info = { fr: brut, pose: brut };
    TEXTES.set(n, info);
    if (langue === 'fr') return;
    var t = poser(brut);
    if (t !== brut) { info.pose = t; n.data = t; }
  }

  // Le texte brut traduit, espaces autour gardés
  function poser(brut) {
    if (langue === 'fr') return brut;
    var coeur = brut.trim();
    if (!coeur || !/[A-Za-zÀ-ÿ]/.test(coeur)) return brut;
    var tr = traduire(coeur.replace(/\s+/g, ' '), langue);
    return tr === null ? brut : brut.replace(coeur, tr);
  }

  function attributs(e) {
    if (ignore(e)) return;
    var memo = ATTRS.get(e);
    ATTRIBUTS.forEach(function (a) {
      if (!e.hasAttribute(a)) return;
      var v = e.getAttribute(a);
      var info = memo && memo[a];
      if (!info || v !== info.pose) info = { fr: v, pose: v };
      var t = poser(info.fr);
      if (!memo) { memo = {}; ATTRS.set(e, memo); }
      memo[a] = info;
      if (t !== v) { info.pose = t; e.setAttribute(a, t); } else info.pose = v;
    });
  }

  function parcourir(racine) {
    if (racine.nodeType === 3) { texte(racine); return; }
    if (racine.nodeType !== 1 && racine.nodeType !== 9) return;
    var marche = document.createTreeWalker(racine, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
    var n = racine.nodeType === 1 ? racine : marche.nextNode();
    while (n) {
      if (n.nodeType === 3) texte(n); else attributs(n);
      n = marche.nextNode();
    }
  }

  function appliquer() {
    document.documentElement.lang = langue === 'ht' ? 'ht' : langue;
    parcourir(document.body);
    if (!appliquer.titre) appliquer.titre = document.title;
    document.title = langue === 'fr' ? appliquer.titre : (traduire(appliquer.titre, langue) || appliquer.titre);
    Array.prototype.forEach.call(document.querySelectorAll('[data-langue-tableau]'), function (s) { s.value = langue; });
  }

  function choisir(l) {
    if (LANGUES.indexOf(l) < 0) return;
    langue = l;
    try { localStorage.setItem(CLE, l); } catch (e) { /* préférence facultative */ }
    appliquer();
  }

  function demarrer() {
    appliquer();
    new MutationObserver(function (liste) {
      liste.forEach(function (m) {
        if (m.type === 'characterData') texte(m.target);
        else if (m.type === 'attributes') attributs(m.target);
        else Array.prototype.forEach.call(m.addedNodes, parcourir);
      });
    }).observe(document.body, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ATTRIBUTS });
    document.addEventListener('change', function (e) {
      if (e.target.matches && e.target.matches('[data-langue-tableau]')) choisir(e.target.value);
    });
  }

  window.GoshipLangueTableau = {
    langue: function () { return langue; },
    choisir: choisir,
    traduire: function (t) { return langue === 'fr' ? t : (traduire(t, langue) || t); }
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', demarrer); else demarrer();
})();
