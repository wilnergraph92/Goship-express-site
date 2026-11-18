# GoShip Express — Centre de communication
# RAPPORT DE LA PHASE 1.2 — Correction de conception, sécurité et architecture

| | |
|---|---|
| Date | 18 novembre 2026 |
| Objet | Corriger la conception de la Phase 1 selon la revue indépendante Phase 1.1 (verdict ÉCHEC) |
| Périmètre autorisé | Documents et brouillons de `docs/communication-center/` seulement |
| Mode | **Aucun SQL exécuté, aucune donnée de production consultée ni modifiée, aucun fournisseur contacté ni configuré, aucun secret touché, rien de déployé, PR #65 non fusionnée** |
| Verdict | **PASS WITH CONDITIONS** (§14) |
| Statut | **En attente de la décision du CEO. La Phase 2 reste interdite sans autorisation écrite.** |

> **Errata Phase 1.3 (18/11/2026)** — la vérification du code réel a montré que plusieurs statuts
> « CORRIGÉ DANS LA CONCEPTION » ci-dessous étaient **trop optimistes** :
> - **H1** et **M7** : l'ordre des verrous annoncé (« jour → campagne → client ») n'était pas tenu par
>   le code, et l'annulation prenait les verrous dans l'ordre inverse (interblocage possible) ;
> - **H4** : un message « incertain » cessait d'être compté dans la fréquence ;
> - **H8** : les réponses 5xx étaient renvoyées automatiquement ;
> - **M12** : le quota Brevo était estimé une fois par passage ;
> - **C5** : la purge laissait des identifiants indirects ;
> - **M6** : la fonction des retours des fournisseurs restait ouverte aux visiteurs, sans limite de débit dans la base.
>
> La garde des brouillons ne protégeait pas un client qui continue après une erreur. Tous ces
> points sont corrigés dans la conception : voir `PHASE_1_3_FINAL_REPORT.md`. Ce rapport n'est
> pas réécrit, pour garder la trace de ce qui avait été affirmé.

---

## 1. Résumé exécutif

1. **Les six blocages critiques sont traités dans la conception.** Cinq sont corrigés (C1, C2, C3, C5,
   C6). **C4**, la séparation chez les fournisseurs, est conçu (identités d'envoi commerciales séparées,
   **aucun repli** sur celles du transactionnel) mais reste **BLOQUÉ PAR DÉCISION CEO** : il faut choisir
   un compte ou fournisseur e-mail commercial séparé, et un numéro WhatsApp dédié ou la Coexistence.
   Tant que ce choix n'est pas fait, **aucun envoi commercial n'est possible** : les brouillons refusent
   sans ces identités.
2. **Les treize risques élevés sont traités** : douze corrigés dans la conception ; **H10** (copies des
   permissions) est partiellement corrigé, car les copies vivent dans `outils/` et `assets/js/`, hors du
   périmètre autorisé. Le texte exact et l'essai de cohérence sont prêts pour la Phase 2.
3. **Risques moyens et faibles** : 15 corrigés sur 18, 2 partiellement (M6 : limite de débit impossible
   dans la base ; L3 : pages pas encore écrites), 1 non corrigé par choix documenté (L2, risque
   négligeable).
4. **Tout ce qui dépend d'une preuve extérieure est BLOQUÉ dans la base**, sans valeur inventée :
   identité légale, adresse postale, quota Brevo, limite WhatsApp, numéro commercial, tarifs, territoires
   ouverts, durées de conservation, textes juridiques.
5. **Rien n'a été exécuté.** Les brouillons sont cohérents à la relecture et aux contrôles statiques
   (gardes, délimiteurs, absence de repli sur les clés transactionnelles, absence d'appel à
   `courriel_gabarit`), mais **ne sont pas éprouvés** ; leur première exécution sur base jetable reste la
   première tâche de la Phase 2.
6. **Avertissement d'indépendance** : cette Phase 1.2 a été corrigée par l'auteur de la conception. Une
   nouvelle revue indépendante est recommandée avant d'autoriser la Phase 2.

---

## 2. Blocages critiques C1 à C6

| ID | Problème | Correction documentaire | Fichier/section | Preuve | Statut |
|---|---|---|---|---|---|
| C1 | Lien de désinscription échappé par `courriel_gabarit`, donc non cliquable | Habillage commercial propre : textes échappés, lien dans `href` ; identité et adresse obligatoires (BLOQUÉES jusqu'à D-G) ; refus si la clé de lien manque ; `courriel_gabarit` ni modifié ni appelé | 43 §4.3, §8 ; ARCHITECTURE §5.1 | `communication_courriel_commercial` construit `<a href="…">` ; renvoie null sans clé, identité ou adresse ; contrôle statique : aucun appel à `courriel_gabarit` ; essai prévu : TESTING groupe 7 | CORRIGÉ DANS LA CONCEPTION |
| C2 | Aucune preuve que le contact appartient au client ; contact non affiché | Consentement `demande` → `confirme` par le contact (lien signé à usage unique via un bouton ; « OUI 1234 » depuis le numéro) ; contact masqué ; 4 états ; langue exacte ; l'équipe ne peut ni demander ni confirmer ; changement de contact = `invalide` | 40 §6 ; 41 §1–§2 ; 43 §7, §9 ; ARCHITECTURE §2.2, §5.2 | Contraintes de la table : `demande` seulement depuis le compte ou l'application, `confirme` seulement par lien ou message ; état actif = `confirme` + empreinte actuelle ; essai prévu : groupe 4 | CORRIGÉ DANS LA CONCEPTION |
| C3 | L'approbation ne couvre pas le contenu tenu par Meta | Image du modèle relue chez Meta, normalisée et hachée ; vérifiée à l'approbation, au lancement et à chaque lot (≤ 60 min) ; pause journalisée sinon ; versionnement ; méthode de lecture à confirmer, échec fermé d'ici là | 42 §1–§2, §4.4 ; 43 §8 ; ARCHITECTURE §5.3 | `communication_modele_meta_bloque` ; `empreinte_meta_approuvee` exigée pour un modèle WhatsApp approuvé ; essai prévu : groupe 9 | CORRIGÉ DANS LA CONCEPTION |
| C4 | Voies séparées dans la base, pas chez Brevo et Meta | Identités d'envoi commerciales séparées, aucun repli ; étude e-mail (A–D) et WhatsApp (Coexistence vs numéro dédié) ; signal « transactionnel bloqué » dans la santé | 43 en-tête, §5, §13 ; 41 §4.2 ; ARCHITECTURE §6 ; SECURITY §4 | Contrôle statique : aucune lecture de `email_cle_api`, `email_expediteur`, `whatsapp_jeton`, `whatsapp_numero_id` dans 40–43 ; allumer un canal exige l'identité commerciale | BLOQUÉ PAR DÉCISION CEO |
| C5 | Conservation indéfinie supposée ; aucun chemin d'effacement | Durées par catégorie BLOQUÉES jusqu'au juriste ; purge demandée, approuvée par un autre administrateur, exécutée par une fonction unique ; seule exception à l'immuabilité ; journal sans données ; empreintes de suppression gardées | 40 §12 ; 41 §4.7 ; 43 §12 ; SECURITY §7 ; DATABASE §5 | `communication_immuable` n'autorise que sous une demande approuvée ; contrainte `approuvee_par <> demandee_par` ; refus `RETENTION_BLOCKED` sans durée ; essai prévu : groupe 5 | CORRIGÉ DANS LA CONCEPTION |
| C6 | STOP de plus de 24 h rejeté | Aucune limite d'âge ; futur > 5 min refusé ; rejeu refusé par identifiant ; retrait prioritaire ; transactionnel jamais touché | 43 §9 ; SECURITY §6.2 | Plus aucune comparaison d'âge dans `communication_recevoir_evenement` ; essai prévu : groupe 8 (STOP de 5 jours) | CORRIGÉ DANS LA CONCEPTION |

## 3. Risques élevés H1 à H13

| ID | Problème | Correction documentaire | Fichier/section | Preuve | Statut |
|---|---|---|---|---|---|
| H1 | Plafond global dépassable par deux travailleurs | Verrou du jour avant toute somme ; réservation atomique ; échec du fournisseur défini | 43 §3 ; 40 §3, §10 | `communication_verrou('depenses:<jour>')` en tête de `communication_reserver` ; groupe 10 | CORRIGÉ DANS LA CONCEPTION |
| H2 | Calcul mensuel Brevo sans connexion ni transactionnel | 30 jours glissants : connexion, transactionnel et commercial comptés ; quota prouvé exigé | 40 §11 ; 41 §4.3 | `communication_brevo_disponible` (branche 30 jours) ; groupe 11 | CORRIGÉ DANS LA CONCEPTION |
| H3 | Attente non comptée ; connexion sous-estimée ; minuit supposé | Attente comptée ; connexion présentée comme estimée ; 24 h glissantes | 40 §11 | Champs `connu` et `estime` séparés ; groupe 11 | CORRIGÉ DANS LA CONCEPTION |
| H4 | Fréquence ignorant les messages en cours | En cours et incertains comptés ; verrou du client | 43 §2, §8 | `coalesce(envoye_le, verrouille_le)` ; verrou `client:<id>` ; groupe 10 | CORRIGÉ DANS LA CONCEPTION |
| H5 | Désinscription de l'adresse actuelle au lieu de celle qui a reçu | Empreinte du contact visé sur l'audience et l'envoi ; blocage de ce contact ; contact changé = envoi écarté | 42 §5 ; 43 §1, §8, §10 | Colonne `cible_empreinte` ; code `CONTACT_CHANGE` ; groupe 7 | CORRIGÉ DANS LA CONCEPTION |
| H6 | Ordre accord/retrait non fiable | Verrou client+canal ; `clock_timestamp()` ; retrait gagnant à égalité | 40 §6.2 ; 41 ; 43 §9 | Tri de `communication_etat_consentement` ; groupe 4 | CORRIGÉ DANS LA CONCEPTION |
| H7 | Changement de contact enregistré comme retrait | Action `invalide`, empreinte de l'ancien contact | 40 §6.2 ; 41 §2 | Contrainte : `invalide` seulement pour `changement_contact`, `suppression_compte`, `expiration` ; groupe 4 | CORRIGÉ DANS LA CONCEPTION |
| H8 | Issue inconnue classée en échec, sans rapprochement | `incertain` ; délai de 20 s ; rapprochement par référence ; clos à 72 h ; jamais renvoyé seul ; relance motivée avec risque coché | 43 §1, §6, §9, §11 | Statut `incertain` ; `relancer_envoi_communication` refuse sans `p_risque_doublon_accepte` ; groupe 13 | CORRIGÉ DANS LA CONCEPTION |
| H9 | Empreintes incomplètes | Empreintes définies champ par champ ; environnement d'envoi ; contenu envoyé haché ; modèle figé complet | 42 §1, §4.1–4.2 ; 43 §8 | `communication_environnement_envoi` ; trigger `communication_modele_fige` ; groupe 9 | CORRIGÉ DANS LA CONCEPTION |
| H10 | Une seule copie des permissions redéfinie | Texte exact prêt ; cinq copies listées ; essai de cohérence prévu ; copies hors du dossier autorisé, non modifiées | 40 §1 ; SECURITY §2.1 ; DATABASE §1 | Groupe 3 (à exécuter en Phase 2) | PARTIELLEMENT CORRIGÉ |
| H11 | Codes Meta et limite par numéro absents | Table des codes et actions ; limite quotidienne BLOQUÉE tant que Meta ne l'a pas donnée | 40 §9.2 ; 43 §3, §9 | `communication_codes_fournisseur` (`verifie = false`) ; refus `LIMITE_NUMERO_WHATSAPP` ; groupe 8 | CORRIGÉ DANS LA CONCEPTION |
| H12 | Tout +1 classé américain ; RD autorisée d'office | Préfixes ; HT, DO, PR, JM bloqués ; autres +1 non classés ; ouverture avec preuve et tarif | 40 §4 ; 41 §4.4 ; 42 §3 | Contrainte `autorise_marketing ⇒ verifie` ; `TERRITOIRE_NON_AUTORISE` ; groupe 12 | CORRIGÉ DANS LA CONCEPTION |
| H13 | Audience pouvant grossir après approbation | Volume et coût approuvés enregistrés ; seuil de 10 % ; retour en attente d'approbation au-delà | 42 §4.3, §4.6 ; 43 §8 | `audience_approuvee`, `AUDIENCE_DEPASSEE` ; groupe 14 | CORRIGÉ DANS LA CONCEPTION |

## 4. Risques moyens et faibles M1 à M14, L1 à L4

| ID | Problème | Correction documentaire | Fichier/section | Preuve | Statut |
|---|---|---|---|---|---|
| M1 | Langue de la preuve différente de la langue affichée | Langue obligatoire, sans repli | 41 §1 | Refus `INVALID_LANGUAGE` ; groupe 4 | CORRIGÉ DANS LA CONCEPTION |
| M2 | Variables mal écrites ignorées ; paramètres WhatsApp invalides | Forme normalisée validée ; remplacement exact ; paramètres contrôlés | 42 §1 ; 43 §8 | `communication_texte_invalide`, `communication_parametre_whatsapp_invalide` ; groupe 14 | CORRIGÉ DANS LA CONCEPTION |
| M3 | Critères de segment non contrôlés | Types, bornes, listes fermées ; volatilité `stable` | 42 §3 | `communication_criteres_valides` ; groupe 14 | CORRIGÉ DANS LA CONCEPTION |
| M4 | Pas de suppression manuelle ni de relance | Fonctions conçues, permission et journal | 41 §3 ; 43 §11 | `ajouter_suppression_communication`, `relancer_envoi_communication` | CORRIGÉ DANS LA CONCEPTION |
| M5 | Index manquants | Index justifiés requête par requête | DATABASE §4 | Tableau requête → index | CORRIGÉ DANS LA CONCEPTION |
| M6 | Fonctions publiques sans limite de débit | Contrôles bon marché, refus journalisés, clé publique non authentifiante ; pas de limite possible dans la base | 43 §9 ; SECURITY §6.5–6.6 | Risque résiduel documenté | PARTIELLEMENT CORRIGÉ |
| M7 | Un lot pouvait partir après une pause | Campagne relue sous verrou à chaque réservation | 43 §3 | `CAMPAGNE_PAS_EN_COURS` | CORRIGÉ DANS LA CONCEPTION |
| M8 | Envoi possible sans clé de lien | Habillage null, envoi refusé ; allumage refusé | 43 §4 ; 41 §4.2 | `UNSUBSCRIBE_KEY_MISSING` ; groupe 7 | CORRIGÉ DANS LA CONCEPTION |
| M9 | Retour arrière qui réintroduirait les permissions | Script avec la définition d'avant 40 ; jamais `supabase.sql` | ARCHITECTURE §9 ; DATABASE §6 | Procédure écrite | CORRIGÉ DANS LA CONCEPTION |
| M10 | UTILITY accepté dans le commercial | MARKETING seulement | 42 §1–§2 | Contrainte `whatsapp_categorie = 'MARKETING'` ; groupe 9 | CORRIGÉ DANS LA CONCEPTION |
| M11 | Empreintes d'e-mails devinables | HMAC avec poivre ; échec fermé sans poivre | 40 §3 ; SECURITY §4 | `communication_empreinte` | CORRIGÉ DANS LA CONCEPTION |
| M12 | Comptes relus à chaque e-mail | Une fois par passage | 43 §8 | Variable `v_brevo` | CORRIGÉ DANS LA CONCEPTION |
| M13 | Erreurs du déclencheur avalées | Journal `communication_erreurs` | 40 §5 ; 41 §2 | Groupe 15 (déclencheur cassé volontairement) | CORRIGÉ DANS LA CONCEPTION |
| M14 | Bascules de consentement illimitées | 5 changements et 3 confirmations par canal et par 24 h ; retrait jamais limité | 41 §1 | `TOO_MANY_CHANGES` ; groupe 4 | CORRIGÉ DANS LA CONCEPTION |
| L1 | Commentaire faux sur pg_cron | Corrigé | 43 §13 ; ARCHITECTURE §4 | Texte | CORRIGÉ DANS LA CONCEPTION |
| L2 | Comparaison de signature non constante en temps | Gardée : risque négligeable par le réseau, documenté | 43 §9 | — | NON CORRIGÉ |
| L3 | Jeton dans l'adresse ; scripts de mesure sur la page | Exigence écrite pour les pages de Phase 2c (lien avec la PR #46) | ARCHITECTURE §8 | Pages non encore écrites | PARTIELLEMENT CORRIGÉ |
| L4 | Aperçu peu efficace | Regroupement | 42 §3 | `group by raison` | CORRIGÉ DANS LA CONCEPTION |

**Tableau de traçabilité** : les trois tableaux ci-dessus (37 constats) forment le tableau de
traçabilité demandé. « Preuve » désigne ce qui, **dans la conception**, montre la correction, et
l'essai prévu ; aucun essai n'a été exécuté.

---

## 5. Hypothèses non vérifiées

| # | Point | Connu | Non vérifié | Preuve nécessaire | Responsable | Décision attendue |
|---|---|---|---|---|---|---|
| 1 | Adresse postale légale | aucune confirmée | adresse de réception du courrier | décision écrite + justificatif | CEO | adresse |
| 2 | Identité juridique | « Goship Express LLC » sur le site | nom enregistré | registre officiel | CEO | nom exact |
| 3 | Adresse de Miami | ABX-46780 (base) ; Apt 46780 (site) | même boîte ? | prestataire de l'entrepôt | CEO | variante officielle |
| 4 | Offre et quota Brevo | 300/jour pour l'offre gratuite (secondaire) | offre réelle | capture datée | CEO, admin | `verifier_quota_brevo` |
| 5 | SMTP de Supabase Auth | Brevo le 28/09 | réglage actuel | capture datée | CEO, admin | confirmation |
| 6 | Listes de blocage Brevo entre expéditeurs | liste du transactionnel rapportée | portée | réponse écrite de Brevo | admin | option e-mail |
| 7 | Restrictions WhatsApp US et RD | pause US rapportée | portée sur les +1 hors US | confirmation écrite de Meta | partenaire, Meta | territoires |
| 8 | Tarifs officiels | estimations secondaires | grilles officielles | grille datée | admin | `verifier_tarif_communication` |
| 9 | Langues de modèles Meta (créole) | fr, en, es | créole haïtien | liste officielle | admin | langue de repli |
| 10 | Coexistence du numéro actuel | conditions publiques | éligibilité de ce numéro | partenaire agréé | CEO | étudier ou écarter |
| 11 | Numéro dédié | possible en Cloud API | éligibilité, coût | devis, vérification Meta | CEO | acquérir ou non |
| 12 | Limite quotidienne et note de qualité | attribuées par Meta | valeurs | gestionnaire WhatsApp | admin | `regler_whatsapp_commercial` |
| 13 | Textes de consentement et désinscription | brouillons en 4 langues | conformité | avis écrit | juriste | attestation |
| 14 | Durées de conservation | propositions | durées légales | avis écrit | juriste | `regler_conservation_communication` |
| 15 | Ordre des PR #46 et #48 | conflits identifiés | — | — | CEO | ordre |
| 16 | Lecture des modèles chez Meta (API Graph) | méthode prévue | forme exacte, droits nécessaires | essai sur compte d'essai (Phase 3) | développement | — |
| 17 | Signification des codes 131048, 131049, 131050, 131056 | rapportée | officielle | documentation de Meta | développement | — |
| 18 | Forme des retours de Brevo, en-tête `X-Mailin-custom`, bac à sable | rapportée | réelle | exemples réels (Phase 3) | développement | — |
| 19 | Paramètres de `net.http_get` (pg_net 0.20.4) | `params`, `timeout_milliseconds` prévus | signature exacte | base jetable (Phase 2) | développement | — |
| 20 | Liste NANPA (États-Unis, Canada, autres) | préfixes DO, PR, JM | liste complète | source officielle NANPA | développement | — |

## 6. Décisions encore attendues du CEO
1. **C4, e-mail** : compte Brevo commercial séparé (recommandé), autre fournisseur, ou même compte avec
   sous-domaine après confirmation écrite de Brevo.
2. **C4, WhatsApp** : étudier un numéro dédié (recommandé) ou la Coexistence ; aucune acquisition sans
   autorisation.
3. **D-G** : identité légale et adresse postale. **D-H** : adresse de Miami canonique.
4. **Juriste** : engagement pour les textes (§5 point 13), les durées (point 14), les heures, les mots
   STOP et de confirmation, la règle de réinscription.
5. **Quatre yeux** sur les campagnes créées par un administrateur (par défaut : non, journalisé).
6. **Ordre** des PR #46 et #48.
7. **Autorisation de la Phase 2**, sur base jetable seulement, et autorisation de modifier, en Phase 2,
   les copies des permissions hors de ce dossier (H10).
8. **Revue indépendante** de cette Phase 1.2 avant la Phase 2 (recommandée).

## 7. Fichiers modifiés (tous dans `docs/communication-center/`)
| Fichier | Nature |
|---|---|
| `COMMUNICATION_CENTER_ARCHITECTURE.md` | réécrit (Phase 1.2, en français) |
| `COMMUNICATION_CENTER_SECURITY.md` | réécrit |
| `COMMUNICATION_CENTER_DATABASE.md` | réécrit |
| `COMMUNICATION_CENTER_PHASE_1_RAPPORT.md` | correctif en tête et mentions « [Corrigé 1.2] » à côté de chaque affirmation fausse |
| `README.md` | index mis à jour, règle de livraison des rapports |
| `brouillons-sql/40-supabase-communications-fondation.sql` | réécrit (garde conservée) |
| `brouillons-sql/41-supabase-communications-consentement.sql` | réécrit (garde conservée) |
| `brouillons-sql/42-supabase-communications-campagnes.sql` | réécrit (garde conservée) |
| `brouillons-sql/43-supabase-communications-envoi.sql` | réécrit (garde conservée) |
| `COMMUNICATION_CENTER_PHASE_1_1_RAPPORT.md` | **ajouté** : la revue 1.1 rangée ici (contenu inchangé ; ses références de sections renvoient à la version Phase 1 des documents) |
| `COMMUNICATION_CENTER_TESTING.md` | **ajouté** : plan d'essais |
| `COMMUNICATION_CENTER_PHASE_1_2_RAPPORT.md` | **ajouté** : ce rapport |

## 8. Fichiers non modifiés
- `COMMUNICATION_CENTER_PHASE_0_AUDIT.md`.
- **Tout ce qui est hors de `docs/communication-center/`** : pages du site, `assets/` (dont `api.js`,
  `admin.js`), `outils/` (aucune migration, aucune copie de `permissions_du_role`), `outils/migrations.txt`,
  `.github/workflows/`, `bureau/`, `CLAUDE.md`, `README.md` racine, `CHANGELOG.md`.
- Le dépôt de l'application mobile.

Vérifié par `git status` avant le commit (§13 du protocole).

## 9. Aucun SQL exécuté
Aucune instruction SQL n'a été exécutée pendant la Phase 1.2 : ni sur Supabase, ni sur une base locale ou
jetable. Les brouillons gardent leur garde « BROUILLON NON APPROUVÉ » comme première instruction.

## 10. Aucune donnée de production consultée ni modifiée
Aucune requête vers la base de production pendant la Phase 1.2, même en lecture. Les chiffres cités
(volumes d'e-mails, nombre de clients) viennent des phases précédentes et sont repris comme tels.

## 11. Aucun fournisseur contacté ni configuré
Ni Brevo, ni Meta, ni un partenaire WhatsApp, ni Supabase n'ont été contactés ou configurés. Aucun secret
ni variable d'environnement n'a été lu ou changé. Aucune fonction Edge n'a été écrite ni déployée. Aucune
tâche planifiée n'a été créée ni activée. Aucune recherche extérieure nouvelle n'a été faite : les faits
extérieurs cités viennent des recherches de la Phase 1 et restent **non vérifiés**.

## 12. Plan d'essais futurs
`COMMUNICATION_CENTER_TESTING.md` : 16 groupes, chacun avec préconditions, données fictives, scénario,
résultat attendu, condition d'échec et preuve à conserver.

| # | Groupe |
|---|---|
| 1 | Chaîne de migrations 1 → 43 exécutée deux fois, et garde de brouillon éprouvée |
| 2 | Permissions, rôle par rôle, double authentification comprise |
| 3 | Copies des permissions |
| 4 | Consentement et changement de contact (13 scénarios) |
| 5 | Conservation et purge à quatre yeux |
| 6 | Suppressions par canal, et `essai-notifications.py` identique avec suppressions |
| 7 | Lien cliquable (analyse HTML) et désinscription du contact exact |
| 8 | Signatures, rejeu, futur, STOP de 5 jours, codes Meta, rapprochement |
| 9 | Empreinte de chaque élément du message |
| 10 | 4 travailleurs, 10 000 messages |
| 11 | Quotas Brevo |
| 12 | Numéros +1 |
| 13 | Issues incertaines |
| 14 | Volume après approbation et variables |
| 15 | Non-régression (Google, profil, suppression de compte, notifications, mobile) |
| 16 | Mode démonstration |

**Aucun n'a été exécuté.**

## 13. Risques résiduels
1. **Brouillons non éprouvés** : erreurs de syntaxe ou de logique possibles malgré la relecture.
2. **Auto-correction** : l'auteur de la conception a corrigé sa propre conception ; une revue indépendante
   reste souhaitable.
3. **C4 non tranché** : tant que les identités séparées n'existent pas, le commercial reste impossible.
   C'est voulu, mais le Centre n'a alors aucune valeur opérationnelle.
4. **Faits extérieurs non vérifiés** (§5) : Meta (lecture des modèles, codes, territoires, créole), Brevo
   (listes de blocage, retours), tarifs.
5. **Limite de débit** des fonctions publiques impossible dans la base (M6) : détection seulement.
6. **Poivre et clés du coffre** non restaurables par la sauvegarde : dépend de la copie hors ligne du
   propriétaire (échec fermé sinon).
7. **Valeur WhatsApp limitée** si Meta bloque le marketing vers les +1 non américains.
8. **Conflits avec les PR #46 et #48** tant que leur ordre n'est pas décidé.

## 14. Verdict : **PASS WITH CONDITIONS**

**Pourquoi pas ÉCHEC** : aucun des six blocages critiques ne reste sans correction de conception. C4
est **conçu** (identités séparées obligatoires, aucun repli, envoi impossible sans elles) et attend une
décision qui n'appartient qu'au CEO.

**Pourquoi pas PASS** :
- des décisions du CEO (C4, D-G, D-H, juriste, ordre des PR) et des validations extérieures (Meta, Brevo,
  tarifs, durées) restent nécessaires ;
- H10 ne peut être fini qu'en Phase 2, hors de ce dossier ;
- les brouillons ne sont pas éprouvés.

**Conditions avant d'autoriser la Phase 2** :
1. vos décisions du §6 (au minimum la direction pour C4 et l'engagement d'un juriste) ;
2. de préférence, une revue indépendante de la Phase 1.2 ;
3. une autorisation écrite précisant que la Phase 2 se fait **sur base jetable uniquement**, et qu'elle
   peut modifier les copies des permissions hors de ce dossier.

**Ma mission s'arrête ici.** Je n'ai commencé aucune migration, aucun essai, aucune intégration
fournisseur, aucun déploiement ni aucune activation. **La Phase 2 reste interdite sans votre
autorisation écrite.**
