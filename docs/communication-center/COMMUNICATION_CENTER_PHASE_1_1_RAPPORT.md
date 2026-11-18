# GoShip Express — Centre de communication
# PHASE 1.1 — Revue indépendante de sécurité et d'architecture

| | |
|---|---|
| Date | 18 novembre 2026 |
| Objet | Revue stricte de la conception de la Phase 1 (PR #65, brouillon) |
| Mode | **Lecture seule.** Aucun fichier du projet modifié, aucun SQL exécuté, aucun essai lancé, PR #65 non fusionnée, production, secrets, fournisseurs et données clients non touchés, aucun message envoyé |
| Verdict | **ÉCHEC (FAIL)** — 6 blocages critiques à corriger avant la Phase 2 |
| Statut | **En attente de la décision du CEO.** La Phase 2 reste non autorisée |

**Avertissement d'indépendance.** J'ai moi-même rédigé les documents revus. Pour compenser, chaque
affirmation a été confrontée au code existant (lecture seule), et non à mes propres documents.

**Aucun résultat de ce rapport ne provient d'un essai exécuté.** Les essais nécessaires sont listés à la
section 8.

---

## 0. Résumé pour le CEO

1. **Ce qui tient** : deux voies séparées (transactionnel inchangé, commercial à part), tout naît éteint,
   approbation réservée à l'administrateur, plafonds vérifiés avant chaque envoi, preuves immuables,
   aucun changement du moteur de notifications ni de l'application mobile. **À garder.**
2. **Six blocages critiques** :
   - **C1** — le lien de désinscription des e-mails commerciaux **ne serait pas cliquable** (la fonction
     de mise en page existante l'échappe) : non-conformité à la loi américaine CAN-SPAM ;
   - **C2** — **personne ne vérifie que le client possède l'e-mail ou le numéro** pour lequel il
     consent, et l'écran ne lui montre même pas lequel ;
   - **C3** — pour WhatsApp, l'approbation ne couvre pas le texte réellement envoyé : **le modèle vit
     chez Meta** et peut y être modifié après l'approbation ;
   - **C4** — les deux voies sont séparées dans la base, **mais pas chez les fournisseurs** : une plainte
     contre un e-mail commercial peut bloquer les avis de colis chez Brevo ;
   - **C5** — conservation « pour toujours » **supposée**, et **aucun moyen prévu d'effacer** quand la loi
     l'exige ;
   - **C6** — un **STOP** arrivé avec plus de 24 h de retard serait **jeté**.
3. **Treize problèmes à risque élevé**, dont : le plafond global peut être dépassé par deux travailleurs
   en parallèle ; le calcul mensuel du quota Brevo oublie les e-mails de connexion ; la limite de
   fréquence ignore les messages en cours d'envoi ; la désinscription bloque l'adresse actuelle au lieu de
   celle qui a reçu le message ; un changement d'adresse est enregistré comme un retrait.
4. **Treize affirmations des documents de la Phase 1 sont fausses ou non prouvées** (section 5).
5. **Recommandation** : une **Phase 1.2 de corrections de conception** (documents et brouillons), puis
   une nouvelle revue — **sur votre autorisation écrite**, puisque la Phase 1.1 n'autorise aucune
   modification.

---

## 1. Ce qui a été revu, et comment

| Élément | Méthode | Effet |
|---|---|---|
| `COMMUNICATION_CENTER_ARCHITECTURE.md`, `_SECURITY.md`, `_DATABASE.md`, `_PHASE_1_RAPPORT.md` | Relecture complète | Aucun |
| Brouillons SQL 40, 41, 42, 43 | Relecture ligne à ligne, sans exécution | Aucun |
| `courriel_gabarit` (`outils/supabase-courriel-reseaux.sql`) | Lecture : traitement du pied de l'e-mail | Aucun |
| Déclencheurs existants sur `clients` (`verrou_role`, `borner_profil_client`, `journaliser_client`, `effacer_identite`, `effacer_naissance`, `courriels_bienvenue_client`, `programmes_compte_cree`) | Lecture | Aucun |
| Inscription Google (`creer_profil_client`), suppression de compte (`supprimer_mon_compte`) | Lecture | Aucun |
| Bancs comparant les copies des permissions (`essai-programmes.py` l. 228-230, `essai-suivi-externe.py` l. 74, `essai-permissions.*`) | Lecture | Aucun |
| PR #65 | Lecture de l'état et des vérifications automatiques | Aucun |

**Non fait, volontairement** : aucune requête à la base (même de lecture), aucun essai, aucune
modification de fichier du projet, aucun appel à un fournisseur.

---

## 2. Blocages critiques

| ID | Où | Problème | Conséquence |
|---|---|---|---|
| **C1** | Brouillon 43 §4.2 (`communication_appel_email`) ; ARCHITECTURE §5.1 | `courriel_gabarit` échappe le pied (`html_echappe(p_pied)`). Le brouillon y place le lien de désinscription en HTML (`<a href=…>`) : il s'afficherait en texte | Aucun e-mail commercial n'aurait de lien de désinscription utilisable : non-conformité CAN-SPAM. L'affirmation « gabarit réutilisé tel quel » est fausse |
| **C2** | 41 §1 (`mes_consentements_communication`, `regler_mon_consentement_communication`) ; ARCHITECTURE §5.6 | Le téléphone (`clients.telephone`) n'est jamais vérifié ; l'e-mail (`clients.email`) n'est pas synchronisé avec l'e-mail de connexion et peut être modifié par l'équipe (`clients.edit`) ; l'écran de consentement ne montre pas l'adresse ou le numéro concerné | Consentement ni « précis » ni « éclairé » (Loi 172-13) ; un client peut faire consentir le numéro d'un tiers (risque « mauvais numéro » TCPA et FTSA) |
| **C3** | 42 §3 (`communication_empreinte_campagne`) ; ARCHITECTURE §2.2 | Le texte d'un message WhatsApp est défini **chez Meta** ; un modèle approuvé peut y être modifié. L'empreinte ne couvre que notre copie locale | Un message différent de celui approuvé peut partir |
| **C4** | ARCHITECTURE §1, §6.1, §6.2 ; SECURITY §1 objectif 6 | Même compte et même expéditeur Brevo pour les deux voies ; même numéro WhatsApp en Coexistence. Brevo tient une liste de blocage du transactionnel alimentée par les plaintes et désinscriptions (**à vérifier dans la documentation Brevo**) ; sur WhatsApp, un blocage ou un signalement abaisse la note de qualité du numéro pour tous les messages | Une plainte commerciale peut bloquer les **avis de colis** : contraire à votre exigence 5 et au point C de la revue |
| **C5** | 40 §4.2 (registre immuable, sans chemin d'effacement) ; DATABASE §7 ; SECURITY §5.4 | Conservation indéfinie **supposée** ; le déclencheur d'immuabilité n'offre **aucune** exception contrôlée pour un effacement ou une anonymisation légalement requis | Contraire à la politique juridiquement validée demandée ; le schéma doit être corrigé **avant** la création de la table |
| **C6** | 43 §7 (`communication_recevoir_evenement`) | Le refus des événements de plus de 24 h s'applique aussi aux STOP, plaintes et désinscriptions ; Meta réessaie ses envois au-delà de 24 h | Un STOP en retard serait perdu : messages commerciaux envoyés à quelqu'un qui a dit STOP |

---

## 3. Problèmes à risque élevé

| ID | Où | Problème | Correction |
|---|---|---|---|
| H1 | 43 §3 (`communication_reserver`) | Le plafond **global** ne verrouille que les lignes de dépense déjà existantes ; deux travailleurs sur des canaux différents peuvent créer chacun leur ligne et voir un total sous le plafond : l'exigence 1 n'est pas garantie | Un seul verrou par jour (ligne témoin ou verrou de transaction) avant de faire la somme et d'augmenter |
| H2 | 40 §8 (`communication_brevo_disponible`, calcul mensuel) | Le calcul mensuel oublie les e-mails de connexion et transactionnels déjà envoyés dans le mois ; jours restants comptés en heure UTC | Compter connexion + transactionnel + commercial du mois, en jours de Santo Domingo |
| H3 | 40 §8 | Les e-mails transactionnels en attente ne sont pas comptés ; les e-mails de connexion sont comptés depuis `auth.users` (une seule date par compte : sous-estimation) ; le changement de jour de Brevo est supposé à minuit de Santo Domingo | Compter l'attente ; lire le journal d'authentification (`auth.audit_log_entries`) s'il est disponible ; 24 h glissantes tant que la règle de Brevo n'est pas confirmée |
| H4 | 43 §2 (`communication_frequence_atteinte`) | Les messages en cours d'envoi ne sont pas comptés (leur date d'envoi est vide) : deux campagnes peuvent toucher le même client dans la même minute | Compter les messages en cours ; un client à la fois dans un passage |
| H5 | 43 §8 (`desinscrire_communication`) ; 42 §4 | La désinscription bloque l'adresse **actuelle** du client, pas celle qui a reçu le message ; l'audience figée ne garde pas l'empreinte de l'adresse visée | Garder l'empreinte de l'adresse visée sur chaque destinataire et chaque envoi, et bloquer celle-là |
| H6 | 41 §1, §3 ; 43 §7 | Accords et retraits d'un même client et canal ne passent pas l'un après l'autre ; leur ordre dépend de l'heure de **début** de chaque transaction | Verrou par client et canal, heure exacte, le retrait gagne en cas d'égalité |
| H7 | 41 §3 (`communication_suivre_client`) | **Un changement d'e-mail ou de téléphone est enregistré comme un retrait** (`retire`, source `cible_changee`), et sans l'empreinte de l'ancienne adresse | Une action distincte « invalidé », qui garde l'ancienne empreinte et ne compte jamais comme un retrait |
| H8 | 43 §5, §6 | Une issue inconnue devient « échec », sans rapprochement ; les retours de Meta ignorent `biz_opaque_callback_data`, pourtant envoyé ; le délai d'attente par défaut de pg_net, court, peut rendre ces cas fréquents | Statut « incertain », délai explicite, processus de rapprochement (§6 E) |
| H9 | 42 §1 (déclencheur de modèle figé) ; 42 §3 | Le déclencheur ne fige ni la catégorie, ni la langue, ni le canal, ni l'empreinte du modèle ; le calcul de l'empreinte d'un modèle n'est défini nulle part ; l'empreinte de campagne oublie le pied, l'adresse postale, le nom et l'adresse d'expédition, `site_url`, `courriel_gabarit`, la valeur d'`adresse_miami()` | Définir les empreintes, et une empreinte du contenu réellement envoyé, vérifiée avant chaque envoi |
| H10 | 40 §1 ; DATABASE §1 | Une seule copie de la liste des permissions est redéfinie ; `essai-programmes.py` et `essai-suivi-externe.py` comparent les copies, `essai-permissions.*` compare avec `api.js` ; relancer `supabase-naissance.sql` retirerait les nouvelles permissions | Mettre à jour toutes les copies en même temps (`supabase.sql`, `-naissance`, `-suivi-externe`, `api.js`) |
| H11 | 43 §5 ; ARCHITECTURE §4 | Codes d'erreur de Meta non traités : client désabonné du marketing (131050), message retenu par Meta pour protéger l'utilisateur (131049), limites anti-spam (131048, 131056) ; limites quotidiennes de destinataires par numéro non modélisées | Associer chaque code à une action (bloquer, reporter, mettre en pause) ; plafond quotidien par numéro |
| H12 | 40 §3 (`communication_pays_numero`), §7.1 | Tout numéro +1 non dominicain est classé « États-Unis » (y compris Porto Rico, le Canada, la Jamaïque) ; la République dominicaine est **autorisée** d'office avant toute confirmation de Meta | Laisser bloqués la République dominicaine et les autres régions +1 jusqu'à la confirmation écrite de Meta |
| H13 | 42 §4 ; ARCHITECTURE §2.2 | La taille de l'audience n'est pas notée à l'approbation ; aucune pause si elle a trop grossi avant le lancement | Noter les nombres à l'approbation ; nouvelle approbation au-delà d'un seuil ou du plafond de messages |

---

## 4. Problèmes à risque moyen et faible

| ID | Où | Problème |
|---|---|---|
| M1 | 41 §1 | Langue : l'affichage retombe sur la langue du client, l'enregistrement sur le français ; la preuve peut citer un texte que le client n'a pas lu |
| M2 | 42 §1 (`communication_rendre`) | Une variable écrite avec des espaces (`{{ prenom }}`) n'est jamais remplacée : le client est écarté sans bruit ; une `adresse_miami` sur plusieurs lignes n'est pas un paramètre WhatsApp valide |
| M3 | 42 §2 (`communication_criteres_valides`) | Les valeurs des segments ne sont pas contrôlées (nombres négatifs ou non numériques, pays inconnus) ; fonction déclarée IMMUTABLE alors qu'elle lève des erreurs |
| M4 | 41 §4 ; 43 | Aucune fonction pour ajouter une suppression manuelle ni pour relancer les messages morts, pourtant décrites |
| M5 | 42, 43 ; DATABASE §6 | Index manquants : envois par campagne et par destinataire, destinataires par modèle, suppressions par client, campagnes par segment, modèles par version remplacée, événements par envoi |
| M6 | 43 §7-8 | Les deux fonctions publiques peuvent être appelées directement avec la clé publique, sans passer par la fonction Edge ; aucune limite de débit ; chaque appel déchiffre un secret : risque de saturation, pas d'élévation de privilège |
| M7 | 43 §6 | Une campagne mise en pause peut encore envoyer un lot (jusqu'à 20 messages) |
| M8 | 43 §4.1-4.2 | Sans la clé de signature des désinscriptions, le lien devient vide et l'envoi part quand même ; il doit être refusé |
| M9 | ARCHITECTURE §11 | Le retour arrière dit « remettre les permissions depuis `supabase.sql` », qui contiendra alors les nouvelles ; l'immuabilité complique le retrait |
| M10 | 42 §3 (`communication_manques`) | Des modèles de catégorie UTILITY sont acceptés dans la voie commerciale, contre les règles de Meta ; les tarifs ne sont vérifiés que pour la catégorie marketing |
| M11 | 40 §3 | Les empreintes d'e-mails se devinent aussi à partir de listes d'adresses courantes (le brouillon ne le note que pour les téléphones) |
| M12 | 40 §8 | La table des comptes est parcourue quatre fois par e-mail ; calculer une fois par passage |
| M13 | 41 §3 | Le déclencheur avale toutes ses erreurs avec un simple avertissement : un défaut passerait inaperçu ; les noter dans une table (comme `programmes_erreurs`) |
| M14 | 41 §1 | Aucune limite aux bascules répétées du consentement ; chacune ajoute une ligne permanente |
| L1 | 43 §9 (commentaire) | Faux : pg_cron 1.6 accepte des intervalles en secondes |
| L2 | 43 §7 | Comparaison de signature non constante en temps ; risque négligeable par le réseau |
| L3 | 43 §8 | Le jeton de désinscription est dans l'adresse, donc dans les journaux de l'hébergeur ; aucun script de mesure ne doit se charger sur cette page (à surveiller si la PR #46 est fusionnée) |
| L4 | 42 §2 | Calcul de l'aperçu d'audience peu efficace |

---

## 5. Affirmations fausses ou non prouvées dans les documents de la Phase 1

1. « `courriel_gabarit` réutilisé tel quel » (ARCHITECTURE §5.1) : **faux**, voir C1.
2. « L'empreinte couvre le contenu de chaque modèle » (ARCHITECTURE §2.2 ; RAPPORT PHASE 1 §0 point 3) :
   **faux pour WhatsApp**, voir C3.
3. « La fonction Edge ne détient aucune clé capable de contourner la sécurité » (ARCHITECTURE §5.7) :
   exact à la lettre, mais trompeur. La fonction qu'elle appelle s'exécute avec tous les droits et
   contourne les règles de sécurité par construction. Tout repose sur la signature.
4. « La base impose l'approbation du juriste » (SECURITY §5 ; RAPPORT PHASE 1 §0 point 5) : la base impose
   une **attestation saisie par un administrateur** ; elle ne peut pas vérifier l'avis lui-même.
5. « Transactionnel et commercial strictement séparés » (ARCHITECTURE §1) : vrai dans la base,
   **pas chez les fournisseurs** (C4).
6. « Volume d'authentification mesuré » (ARCHITECTURE §6.3) : c'est une **borne basse**, pas une mesure.
7. Le quota quotidien de Brevo se renouvelle au jour de Santo Domingo (40 §8) : **supposé**.
8. République dominicaine et Haïti dans la tranche tarifaire « Rest of Latin America » ; pause du
   marketing vers les États-Unis toujours active ; débit en Coexistence : **sources secondaires**, non
   confirmées.
9. Le créole haïtien est une langue de modèle WhatsApp acceptée (42 §1) : **non vérifié**.
10. 500 000 appels de fonction Edge par mois en offre gratuite ; règles de Gmail et Yahoo obligatoires
    au-delà de 5 000 e-mails par jour (ARCHITECTURE §10 ; SECURITY §5.1) : **de mémoire, non vérifié**.
11. DMARC réussi parce que Brevo signe au nom de goshipexpress.net : **supposé** ; seuls les
    enregistrements DNS ont été vérifiés, aucun e-mail d'essai n'a été envoyé.
12. « pg_net est loin d'être saturé » (ARCHITECTURE §4) : **non mesuré**.
13. « Conservation indéfinie » (DATABASE §7 ; SECURITY §5.4) : **hypothèse**, voir C5.

---

## 6. Réponses par domaine de la revue

### A. Consentement et identité du contact

- **Retrait volontaire et changement de contact** : aujourd'hui confondus (H7). Correction : une action
  distincte « invalidé », avec l'empreinte de l'ancienne adresse.
- **Lien au canal et à l'adresse exacts** : déjà strict. Un consentement n'est valable que si la dernière
  ligne porte l'empreinte de l'adresse actuelle (40 §4.2). **Un nouveau numéro ou un nouvel e-mail
  n'hérite donc pas du consentement.** La règle est juste, mais sans valeur tant que la possession de
  l'adresse n'est pas prouvée (C2).
- **Correction proposée : un consentement confirmé par l'adresse elle-même.**
  - WhatsApp : le consentement ne devient actif que lorsque le client envoie un message (« OUI / YES / WI
    / SÍ ») **depuis ce numéro** au numéro de GoShip. Cela prouve qu'il détient le numéro et ouvre en
    plus la fenêtre de service de 24 h.
  - E-mail : le consentement ne devient actif qu'après un clic sur un lien signé envoyé à
    `clients.email`.
  - L'écran de consentement affiche l'adresse ou le numéro masqué.
- **Conservation (à soumettre au juriste)** — proposition, pas une décision :
  - garder la preuve du consentement pendant la vie du compte, puis pendant le délai de prescription
    légal (quatre ans est le délai fédéral généralement cité pour la TCPA ; **à confirmer pour la TCPA,
    la FTSA et la Loi 172-13**), puis effacer le lien avec le client et ne garder que les empreintes ;
  - garder les empreintes de suppression aussi longtemps qu'il le faut pour respecter l'opposition ;
  - dans le schéma : une seule fonction de purge, journalisée, seule exception à l'immuabilité, lancée
    par le planificateur, avec une durée réglée et datée par un administrateur.

### B. Fonction Edge et retours des fournisseurs — le parcours complet

1. **Meta → fonction Edge.**
   - Vérification de l'abonnement : requête `GET` avec `hub.verify_token`.
   - Chaque événement : requête `POST`, signature `X-Hub-Signature-256` (HMAC avec le secret de
     l'application Meta) vérifiée sur le **corps brut**, avant toute lecture du JSON.
   - Meta ne signe pas d'horodatage : la protection contre le rejeu repose sur les identifiants
     d'événements.
2. **Brevo → fonction Edge.** Brevo ne signe pas ses envois. Jeton secret (dans l'adresse ou en
   authentification simple) et plages d'adresses IP publiées par Brevo. Plus faible : à documenter comme
   tel.
3. **Fonction Edge → PostgreSQL.**
   - La fonction Edge met chaque événement sous une forme texte stable et signe `fournisseur:texte` avec
     la clé partagée.
   - Elle appelle `communication_recevoir_evenement` avec la clé publique, comme visiteur anonyme.
   - **La clé publique désigne seulement le projet ; elle n'autorise rien.** La fonction refuse tout appel
     sans signature valide : c'est la seule porte.
4. **Dans PostgreSQL.** Vérification de la signature ; refus si la clé est absente ; rejeu bloqué par la
   paire unique (fournisseur, identifiant d'événement).
   - Les identifiants d'événements restent à définir : Meta n'en donne pas pour les statuts, il faut en
     construire un (identifiant du message, statut, horodatage).
   - **Supprimer le contrôle d'âge pour STOP, plaintes et désinscriptions** (C6), et refuser les
     événements datés dans le futur.
5. **Moindre privilège et élévation de privilège.**
   - La fonction ne change le rôle de personne. Elle **ne peut pas enregistrer d'accord** (une règle de la
     table n'accepte les accords que depuis le compte ou l'application du client). Elle ne fait que
     changer des statuts, ajouter des suppressions et enregistrer des retraits.
   - Pire cas si la clé partagée fuit : de faux statuts et des suppressions abusives, donc un déni de
     service sur le seul marketing. **Ni élévation de privilège, ni exposition de données clients.**
   - Contournement voulu des règles de sécurité dans ces fonctions (droits complets, chemin de recherche
     figé), limité à ces opérations.
6. **Limitation de débit** : seulement dans la fonction Edge, qui ne protège pas les appels directs (M6).
   Risque résiduel accepté : la falsification est impossible à calculer ; le risque est la charge.

### C. Suppression et désinscription

- **Par canal** : la liste est indexée par canal et empreinte d'adresse, les canaux restent indépendants.
  - STOP : WhatsApp seulement.
  - Lien : le canal du message.
  - Rebond et plainte : le canal de l'événement.
  - Manuelle : le canal choisi, mais la fonction n'existe pas encore (M4).
- **Le transactionnel n'est jamais supprimé dans notre base** : seules les fonctions commerciales lisent
  ces tables, et le moteur transactionnel n'est pas touché. **Chez les fournisseurs, ce n'est pas garanti**
  (C4).
- **Jetons de désinscription.**
  - Identifiant de l'envoi plus HMAC tronqué à 192 bits : impossible à deviner. Rejouer un jeton
    réapplique le même blocage sans rien changer.
  - Pas d'expiration, volontairement : la loi américaine exige que le lien fonctionne au moins 30 jours.
  - Révoquer tous les jetons = changer la clé de signature, ce qui casse aussi les anciens liens.
  - Corrections nécessaires : H5 (bloquer l'adresse qui a reçu le message), M8 (refuser d'envoyer sans la
    clé), C1 (un lien cliquable).

### D. Migrations 40 à 43

- **Opérations destructrices** : aucune sur les données ; seulement le remplacement de la liste des
  permissions et la recréation de leurs propres déclencheurs (rejouable).
- **Risque des déclencheurs** : un nouveau déclencheur sur `clients`, après mise à jour. Les déclencheurs
  existants sur cette table ont été lus (`verrou_role`, `borner_profil_client`, `journaliser_client`,
  `effacer_identite`, `effacer_naissance`) : aucun conflit.
- **Règles de sécurité des tables** : aucune faille, 14 tables fermées. Les deux fonctions publiques
  doivent être ajoutées à la liste blanche de `controle-securite.sql`, sinon le contrôle hebdomadaire de
  la production lèvera une alerte.
- **Incohérences** : permissions (H10) ; index manquants (M5).
- **Concurrence** : H1, H4, H6.
- **Rejouabilité** : correcte (`if not exists`, `on conflict do nothing`, tâche planifiée créée une seule
  fois).
- **Ordre** : après la migration 39. **La PR #48 doit passer strictement avant ou après** : les deux
  réécrivent la liste des permissions et introduisent la première fonction Edge.
- **Retour arrière** : M9.

### E. Approbation et envoi

- **Empreinte** : incomplète (C3, H9).
- **Audience figée** : figée au lancement avec une règle d'unicité, mais ni immuable, ni liée aux
  adresses visées (H5), et elle peut grossir sans nouvelle approbation (H13).
- **Concurrence et doublons** : solides grâce aux clés uniques et aux prises de lignes qui sautent celles
  déjà verrouillées ; restent H1 et H4.
- **Processus de rapprochement proposé pour les issues inconnues** :
  1. un statut **« incertain »**, distinct de « échec », visible dans le Centre et jamais compté comme un
     échec dans les statistiques ;
  2. un délai d'attente HTTP explicite (par exemple 20 secondes) ;
  3. WhatsApp : rapprocher les retours tardifs grâce à `biz_opaque_callback_data = communication:<id>` ;
  4. e-mail : ajouter un en-tête personnalisé portant l'identifiant de l'envoi, puis chercher dans les
     événements de Brevo par cet en-tête, ou par l'étiquette de campagne et le destinataire ;
  5. après 72 heures sans trace, le message reste **« incertain » pour de bon**. Il n'est **jamais
     renvoyé automatiquement**, et son coût reste réservé. Seul un administrateur peut décider un renvoi,
     avec un avertissement explicite sur le risque de doublon et un motif journalisé.

### F. Protection de Brevo

- Trois erreurs dans les calculs (H2, H3). Le principe est juste : l'e-mail commercial reste fermé tant
  qu'un quota vérifié n'a pas été saisi.
- **Rien ne suppose l'offre Brevo vérifiée.** L'offre Brevo et le réglage SMTP de Supabase Auth restent
  **non vérifiés** et sont des préalables.
- Contrôle manquant : la réserve doit être inférieure au quota.

### G. WhatsApp

- **Séparer les États-Unis de la République dominicaine.** Régler à part : les numéros américains, les
  numéros dominicains (809, 829, 849) et les autres régions +1 (Porto Rico, Canada, autres îles des
  Caraïbes). Tous restent **bloqués** jusqu'à la confirmation de Meta (H12).
- **À confirmer directement avec Meta ou le partenaire choisi :**
  1. si la pause du marketing vers les États-Unis touche aussi les numéros dominicains ;
  2. la tranche tarifaire d'Haïti et de la République dominicaine ;
  3. si le créole haïtien est une langue de modèle acceptée ;
  4. l'éligibilité du numéro de GoShip à la Coexistence (application Business, région, refus possible de
     l'import d'historique) ;
  5. la note de qualité et la limite quotidienne de destinataires attribuées au numéro ;
  6. le fonctionnement de l'option « arrêter le marketing » de Meta (erreur 131050) et des limites de
     fréquence par utilisateur (131049) ;
  7. les catégories de modèles, et si un modèle approuvé peut être modifié ;
  8. l'état de la vérification de l'entreprise.
- **Numéro actuel** : rien dans la conception ne le migre ni ne le déconnecte. C4 plaide pourtant pour un
  **numéro dédié au marketing** plutôt que pour la Coexistence.

### H. Systèmes GoShip existants (vérifiés par lecture du code seulement, aucun essai lancé)

| Système | Constat |
|---|---|
| Inscription Google | `creer_profil_client` crée le profil avec `on conflict do nothing` et ne le met jamais à jour : le nouveau déclencheur ne se déclenche pas. ✓ |
| Modification du profil | Le client ne peut changer que certaines colonnes ; le déclencheur s'exécute après la mise à jour et attrape ses propres erreurs : il ne peut pas bloquer. ✓ (M13 reste) |
| Suppression du compte | `supprimer_mon_compte` vide l'e-mail et le téléphone et pose `supprime_le` ; le déclencheur ajoute seulement des lignes de retrait : il ne peut pas bloquer. ✓ Conflit de conservation : C5 |
| Travailleurs de notifications existants | Aucun changement de code ; une lecture de plus par minute sur un index existant ; pg_net partagé. Essais de non-régression nécessaires |
| Contrats de l'application mobile | Aucune forme de réponse ne change ; `mes_permissions` rend la même chose aux clients. ✓ |
| Mode démonstration | **Pas conçu.** La copie démo des permissions (`PERMISSIONS_DES_ROLES` dans `api.js`) et une version démo de chaque nouvelle méthode du tableau de bord sont nécessaires, sinon le mode démo casse sans bruit et `essai-permissions.js` échoue |
| Double authentification | Les nouvelles permissions sont des permissions d'équipe : une session à deux facteurs (aal2) est exigée d'elle-même dès qu'un appareil est inscrit. ✓ |

---

## 7. Corrections exigées avant la Phase 2

À faire dans une révision des documents de la Phase 1 (Phase 1.2), pas dans le code :

1. **C1** : un habillage propre aux e-mails commerciaux (lien cliquable, adresse postale, texte
   commercial), sans modifier `courriel_gabarit`.
2. **C2** : consentement confirmé par l'adresse elle-même (message WhatsApp entrant depuis le numéro, lien
   de confirmation par e-mail) ; adresse masquée affichée à l'écran ; texte relu par le juriste.
3. **C3** : lire chez Meta le contenu du modèle WhatsApp, en prendre l'empreinte à l'approbation et avant
   chaque lancement ; mettre la campagne en pause en cas de différence.
4. **C4** : identités d'envoi séparées — sous-domaine ou expéditeur commercial chez Brevo, après
   vérification de sa liste de blocage ; numéro WhatsApp dédié recommandé pour le marketing. Votre
   décision est nécessaire.
5. **C5** : une politique de conservation rédigée pour le juriste, et une seule fonction de purge
   journalisée prévue dans le schéma.
6. **C6** : jamais de limite d'âge pour STOP, plaintes et désinscriptions ; refus des événements datés
   dans le futur.
7. H1 à H13, comme décrit à la section 3.
8. Corriger les affirmations fausses ou non prouvées de la section 5 (ARCHITECTURE, SECURITY, RAPPORT
   PHASE 1).
9. Concevoir le mode démonstration et les ajouts à la liste blanche de `controle-securite.sql`.

---

## 8. Essais exigés sur la base PostgreSQL jetable (aucun lancé)

1. Toute la chaîne de migrations 1 → 43, exécutée deux fois : aucun changement la seconde fois.
2. Permissions rôle par rôle (administrateur, gérant, employé, client, visiteur) pour chaque fonction, y
   compris le gérant refusé sur approuver, reprendre et les réglages, et le refus sans double
   authentification dès qu'un appareil est inscrit.
3. Les quatre copies des permissions identiques ; `essai-permissions.py` et `essai-permissions.js` verts.
4. Consentement :
   - immuable ;
   - l'équipe ne peut jamais enregistrer un accord ;
   - inactif tant qu'il n'est pas confirmé par l'adresse ;
   - **un nouvel e-mail ou un nouveau numéro n'hérite pas du consentement** ;
   - un changement d'adresse n'est pas un retrait ;
   - un accord et un retrait simultanés : le retrait gagne ;
   - la langue enregistrée est celle affichée.
5. Purge de conservation : seulement par la fonction prévue ; tout le reste est refusé.
6. Suppression : indépendante par canal. Un STOP ou une désinscription par lien **ne change rien** aux
   notifications transactionnelles ; rejouer tout `essai-notifications.py` avec des suppressions en place.
7. Désinscription : jeton altéré, jeton d'un autre envoi, rejeu, adresse changée après l'envoi (c'est
   l'adresse qui a reçu le message qui est bloquée), clé de signature absente (envoi refusé). Le HTML
   produit contient un lien `<a href>` **cliquable**.
8. Retours des fournisseurs :
   - signature fausse ;
   - rejeu ;
   - événement daté dans le futur ;
   - **un STOP vieux de 5 jours est appliqué** ;
   - codes d'erreur 131050, 131049, 131048 ;
   - rapprochement tardif par `biz_opaque_callback_data`.
9. Empreinte : modifier chaque champ et chaque élément du contenu réel (modèle WhatsApp simulé comme
   modifié chez Meta, pied, adresse postale, expéditeur) — refus ou pause à chaque fois.
10. Concurrence : 4 travailleurs en parallèle, 10 000 messages sur deux canaux et deux campagnes. Ni le
    plafond global du jour ni aucun plafond de campagne n'est dépassé (nombre et dollars) ; aucun client
    ne dépasse la limite de fréquence ; aucun doublon.
11. Brevo : calculs du jour et du mois avec des volumes simulés de connexion, de transactionnel et
    d'attente ; réserve toujours gardée ; e-mail commercial fermé tant que le quota est inconnu.
12. Classement des numéros : États-Unis, République dominicaine, Porto Rico, Canada, Jamaïque ; les
    régions non confirmées restent bloquées.
13. Issues inconnues : délai dépassé, pas de réponse, rapprochement, statut « incertain », aucun renvoi
    automatique.
14. Audience : croissance au-delà du seuil après l'approbation → pause ; variables manquantes → client
    écarté avec sa raison.
15. Non-régression des systèmes existants : `essai-mobile.py` sections K (suppression de compte),
    L (inscription Google) et M, `essai-notifications.py`, `essai-accuses.py`, `essai-suivi-courriels.py`,
    `essai-programmes.py`, `essai-suivi-externe.py`, `essai-production.py`.
16. Mode démonstration : `essai-communications.js` et l'essai dans le navigateur, avec les envois refusés.

---

## 9. Verdict final : **ÉCHEC (FAIL)**

**Ce qui tient, et doit être gardé :**
- tables, files et travailleurs séparés pour le commercial ;
- tout naît éteint, en mode essai seulement ;
- approbation réservée à l'administrateur ;
- plafonds vérifiés avant chaque envoi ;
- preuves immuables ;
- aucun changement du moteur transactionnel ni de l'application mobile.

**Ce qui échoue :**
- le lien de désinscription ne fonctionne pas (C1) ;
- un client peut consentir pour une adresse qui n'est pas la sienne (C2) ;
- l'approbation WhatsApp ne couvre pas ce que Meta envoie réellement (C3) ;
- les deux voies ne sont pas séparées chez les fournisseurs (C4) ;
- il n'existe aucun chemin de conservation ni d'effacement (C5) ;
- un STOP en retard peut être jeté (C6).

Chacun de ces points suffit à bloquer la Phase 2 telle qu'elle est conçue aujourd'hui.

**Recommandation** : une **Phase 1.2 (corrections de conception)** qui met à jour les documents et les
brouillons listés à la section 7, suivie d'une nouvelle revue. Cette révision demande elle-même votre
autorisation écrite, puisque la Phase 1.1 n'autorise aucune modification.

---

## 10. Rapport de phase (cahier des charges §14)

1. **Inspecté** : les quatre documents de la Phase 1, les quatre brouillons SQL (40 à 43),
   `courriel_gabarit`, les déclencheurs de `clients`, l'inscription Google, la suppression de compte, les
   bancs qui comparent les copies des permissions, l'état de la PR #65.
2. **Réalisé** : la revue et ce rapport, rien d'autre.
3. **Fichiers modifiés** : aucun fichier du projet. Ce rapport est rangé dans le dossier de travail de la
   session, hors du dépôt, comme celui de la Phase 0.
4. **Changements de base** : aucun ; aucune requête, même de lecture, n'a été faite pendant cette revue.
5. **Essais faits** : aucun.
6. **Résultats d'essais** : sans objet. Les vérifications automatiques de la PR #65 sont vertes, mais
   elles éprouvent le code existant, pas les brouillons.
7. **Conséquences de sécurité** : aucune, rien n'a été exécuté. Les six blocages critiques portent sur
   la conception.
8. **Blocages restants** : C1 à C6 ; décisions D-G et D-H ; offre Brevo ; choix entre Coexistence et
   numéro dédié (désormais lié à C4) ; juriste ; confirmations de Meta (section 6 G) ; ordre des PR #46
   et #48.
9. **Coût estimé de la suite** : Phase 1.2 (corrections de conception, sans exécution) ≈ 3 à 4 séances,
   sans coût extérieur ; puis une nouvelle revue ≈ 1 séance.
10. **Approbation nécessaire pour continuer** : votre autorisation écrite de lancer la **Phase 1.2**
    (modification des documents et des brouillons dans `docs/communication-center/`, sans exécution ni
    production), et vos réponses, ou un report explicite, à la décision C4 (identités d'envoi séparées,
    numéro WhatsApp dédié) et aux décisions encore ouvertes. **La Phase 2 reste non autorisée.**
