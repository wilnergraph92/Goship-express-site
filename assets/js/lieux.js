/* ==========================================================================
   Goship Express — régions et villes de destination
   Haïti (départements → communes), République dominicaine (provinces →
   municipalités) et les États des États-Unis. Une seule liste pour l'espace
   client (compte.js : adresse du client) et le tableau de bord (admin.js :
   filtre « Destination » de la vue générale). Aucune requête, aucune donnée.
   ========================================================================== */
(function () {
  'use strict';

  var REGIONS = {
    HT: {
      'Artibonite': ['Gonaïves', 'Saint-Marc', 'Dessalines', 'Gros-Morne', 'Ennery', "L'Estère", 'Terre-Neuve', 'Anse-Rouge',
                     'Verrettes', 'La Chapelle', "Petite-Rivière-de-l'Artibonite", 'Grande-Saline', 'Desdunes',
                     "Saint-Michel-de-l'Attalaye", 'Marmelade'],
      'Centre': ['Hinche', 'Mirebalais', 'Lascahobas', 'Belladère', 'Maïssade', 'Thomonde', 'Cerca-Carvajal',
                 "Saut-d'Eau", 'Boucan-Carré', 'Savanette', 'Cerca-la-Source', 'Thomassique'],
      "Grand'Anse": ['Jérémie', 'Abricots', 'Bonbon', 'Moron', 'Chambellan', "Anse-d'Hainault", 'Dame-Marie',
                     'Les Irois', 'Corail', 'Roseaux', 'Beaumont', 'Pestel'],
      'Nippes': ['Miragoâne', 'Petite-Rivière-de-Nippes', 'Paillant', 'Fonds-des-Nègres', 'Anse-à-Veau', 'Arnaud',
                 "L'Asile", 'Petit-Trou-de-Nippes', 'Plaisance-du-Sud', 'Baradères', 'Grand-Boucan'],
      'Nord': ['Cap-Haïtien', 'Limonade', 'Quartier-Morin', 'Acul-du-Nord', 'Plaine-du-Nord', 'Milot',
               'Grande-Rivière-du-Nord', 'Bahon', 'Borgne', 'Port-Margot', 'Limbé', 'Bas-Limbé', 'Plaisance',
               'Pilate', 'Dondon', 'Saint-Raphaël', 'Pignon', 'La Victoire', 'Ranquitte'],
      'Nord-Est': ['Fort-Liberté', 'Ouanaminthe', 'Trou-du-Nord', 'Terrier-Rouge', 'Caracol', 'Sainte-Suzanne',
                   'Ferrier', 'Perches', 'Capotille', 'Mont-Organisé', 'Vallières', 'Carice', 'Mombin-Crochu'],
      'Nord-Ouest': ['Port-de-Paix', 'Saint-Louis-du-Nord', 'Jean-Rabel', 'Môle-Saint-Nicolas', 'Bassin-Bleu',
                     'Chansolme', 'La Tortue', 'Anse-à-Foleur', 'Baie-de-Henne', 'Bombardopolis'],
      'Ouest': ['Port-au-Prince', 'Delmas', 'Pétion-Ville', 'Carrefour', 'Tabarre', 'Cité Soleil', 'Croix-des-Bouquets',
                'Kenscoff', 'Gressier', 'Léogâne', 'Petit-Goâve', 'Grand-Goâve', 'Arcahaie', 'Cabaret', 'Thomazeau',
                'Ganthier', 'Cornillon', 'Fonds-Verrettes', 'Anse-à-Galets', 'Pointe-à-Raquette'],
      'Sud': ['Les Cayes', 'Aquin', 'Cavaillon', 'Saint-Louis-du-Sud', 'Camp-Perrin', 'Maniche', 'Chantal',
              'Torbeck', 'Île-à-Vache', 'Port-Salut', 'Saint-Jean-du-Sud', 'Arniquet', 'Côteaux', 'Port-à-Piment',
              'Roche-à-Bateau', 'Chardonnières', 'Les Anglais', 'Tiburon'],
      'Sud-Est': ['Jacmel', 'Cayes-Jacmel', 'Marigot', 'La Vallée', 'Bainet', 'Côtes-de-Fer', 'Belle-Anse',
                  'Grand-Gosier', 'Thiotte', 'Anse-à-Pitres']
    },
    DO: {
      'Azua': ['Azua de Compostela', 'Padre Las Casas', 'Sabana Yegua', 'Estebanía', 'Las Charcas', 'Peralta',
               'Pueblo Viejo', 'Tábara Arriba', 'Guayabal', 'Las Yayas de Viajama'],
      'Bahoruco': ['Neiba', 'Galván', 'Tamayo', 'Villa Jaragua', 'Los Ríos'],
      'Barahona': ['Santa Cruz de Barahona', 'Cabral', 'Enriquillo', 'Paraíso', 'Vicente Noble', 'Polo',
                   'La Ciénaga', 'Fundación', 'El Peñón', 'Jaquimeyes', 'Las Salinas'],
      'Dajabón': ['Dajabón', 'Loma de Cabrera', 'Partido', 'Restauración', 'El Pino'],
      'Distrito Nacional': ['Santo Domingo de Guzmán'],
      'Duarte': ['San Francisco de Macorís', 'Arenoso', 'Castillo', 'Eugenio María de Hostos', 'Las Guáranas',
                 'Pimentel', 'Villa Riva'],
      'El Seibo': ['Santa Cruz de El Seibo', 'Miches'],
      'Elías Piña': ['Comendador', 'Bánica', 'El Llano', 'Hondo Valle', 'Juan Santiago', 'Pedro Santana'],
      'Espaillat': ['Moca', 'Cayetano Germosén', 'Gaspar Hernández', 'Jamao al Norte'],
      'Hato Mayor': ['Hato Mayor del Rey', 'El Valle', 'Sabana de la Mar'],
      'Hermanas Mirabal': ['Salcedo', 'Tenares', 'Villa Tapia'],
      'Independencia': ['Jimaní', 'Cristóbal', 'Duvergé', 'La Descubierta', 'Mella', 'Postrer Río'],
      'La Altagracia': ['Higüey', 'Punta Cana', 'San Rafael del Yuma'],
      'La Romana': ['La Romana', 'Guaymate', 'Villa Hermosa'],
      'La Vega': ['La Vega', 'Constanza', 'Jarabacoa', 'Jima Abajo'],
      'María Trinidad Sánchez': ['Nagua', 'Cabrera', 'El Factor', 'Río San Juan'],
      'Monseñor Nouel': ['Bonao', 'Maimón', 'Piedra Blanca'],
      'Monte Cristi': ['Monte Cristi', 'Castañuelas', 'Guayubín', 'Las Matas de Santa Cruz', 'Pepillo Salcedo',
                       'Villa Vásquez'],
      'Monte Plata': ['Monte Plata', 'Bayaguana', 'Peralvillo', 'Sabana Grande de Boyá', 'Yamasá'],
      'Pedernales': ['Pedernales', 'Oviedo'],
      'Peravia': ['Baní', 'Nizao'],
      'Puerto Plata': ['Puerto Plata', 'Sosúa', 'Imbert', 'Luperón', 'Altamira', 'Guananico', 'Los Hidalgos',
                       'Villa Isabela', 'Villa Montellano'],
      'Samaná': ['Santa Bárbara de Samaná', 'Las Terrenas', 'Sánchez'],
      'San Cristóbal': ['San Cristóbal', 'Bajos de Haina', 'Villa Altagracia', 'Cambita Garabitos', 'Los Cacaos',
                        'Sabana Grande de Palenque', 'San Gregorio de Nigua', 'Yaguate'],
      'San José de Ocoa': ['San José de Ocoa', 'Rancho Arriba', 'Sabana Larga'],
      'San Juan': ['San Juan de la Maguana', 'Las Matas de Farfán', 'El Cercado', 'Bohechío', 'Juan de Herrera',
                   'Vallejuelo'],
      'San Pedro de Macorís': ['San Pedro de Macorís', 'Consuelo', 'Guayacanes', 'Quisqueya', 'Ramón Santana',
                               'San José de Los Llanos'],
      'Sánchez Ramírez': ['Cotuí', 'Cevicos', 'Fantino', 'La Mata'],
      'Santiago': ['Santiago de los Caballeros', 'Tamboril', 'Licey al Medio', 'Puñal', 'Villa González',
                   'Villa Bisonó (Navarrete)', 'San José de las Matas', 'Jánico', 'Sabana Iglesia', 'Baitoa'],
      'Santiago Rodríguez': ['San Ignacio de Sabaneta', 'Monción', 'Villa Los Almácigos'],
      'Santo Domingo': ['Santo Domingo Este', 'Santo Domingo Oeste', 'Santo Domingo Norte', 'Boca Chica',
                        'Los Alcarrizos', 'Pedro Brand', 'San Antonio de Guerra'],
      'Valverde': ['Mao', 'Esperanza', 'Laguna Salada']
    }
  };
  var ETATS_US = ['Alabama', 'Alaska', 'Arizona', 'Arkansas', 'California', 'Colorado', 'Connecticut', 'Delaware',
    'District of Columbia', 'Florida', 'Georgia', 'Hawaii', 'Idaho', 'Illinois', 'Indiana', 'Iowa', 'Kansas',
    'Kentucky', 'Louisiana', 'Maine', 'Maryland', 'Massachusetts', 'Michigan', 'Minnesota', 'Mississippi',
    'Missouri', 'Montana', 'Nebraska', 'Nevada', 'New Hampshire', 'New Jersey', 'New Mexico', 'New York',
    'North Carolina', 'North Dakota', 'Ohio', 'Oklahoma', 'Oregon', 'Pennsylvania', 'Rhode Island',
    'South Carolina', 'South Dakota', 'Tennessee', 'Texas', 'Utah', 'Vermont', 'Virginia', 'Washington',
    'West Virginia', 'Wisconsin', 'Wyoming'];
  window.GoshipLieux = Object.freeze({ REGIONS: REGIONS, ETATS_US: ETATS_US });
})();
