# GoShip Express — Centre de communication
# RAPPORT FINAL DE LA PHASE 1.3 — Corrections techniques et durcissement de la sécurité

| | |
|---|---|
| Date | 18 novembre 2026 |
| Objet | Vérifier et corriger huit risques techniques des brouillons 40 à 43, compléter le plan d'essais, revoir la sécurité |
| Périmètre autorisé | Documents et brouillons SQL de `docs/communication-center/` seulement |
| Mode | **Aucun SQL exécuté, ni en production ni sur une base de test. Aucune donnée consultée ni modifiée. Aucun fournisseur contacté. Aucun secret touché. Rien de déployé. PR #65 non fusionnée ; PR #46 et #48 ni fusionnées, ni modifiées, ni fermées.** |
| Verdict | **VALIDÉ SOUS CONDITIONS** (§13) |
| Statut | **En attente de la décision du CEO. La Phase 2 n'est PAS commencée et reste interdite sans autorisation écrite.** |

Documents de la phase :
- `PHASE_1_3_TECHNICAL_CORRECTIONS.md` : diagnostic détaillé, corrections, avant / après ;
- `PHASE_1_3_SECURITY_REVIEW.md` : contre-revue, PostgreSQL, dépendances, PR #46 et #48 ;
- `PHASE_1_3_TEST_PLAN.md` : 20 essais, tous **NON EXÉCUTÉS** ;
- le présent rapport.

---

## 1. Résumé exécutif

1. **Les huit problèmes signalés sont confirmés** par le code réel des brouillons. Deux sont plus larges que décrits :
   - **C2** : trois cycles d'interblocage, et non un seul ;
   - **C6** : l'heure de New York s'appliquait aussi à tout pays autre qu'Haïti et la République dominicaine.

   La garde **C8** protégeait avec les outils du projet, mais pas avec `psql` sans `ON_ERROR_STOP`.
2. **Quatre défauts supplémentaires** ont été trouvés et corrigés. Le plus important : un message « incertain » cessait d'être compté dans la fréquence par client et dans la limite du numéro WhatsApp.
3. **Les huit problèmes ont chacun une correction**, dans les brouillons et les documents :
   - un **arrêt d'urgence** global, avec un instant d'effet précis ;
   - **un envoi par transaction**, avec un **ordre unique des verrous** ;
   - un **quota Brevo et un débit réservés sous un verrou global** ;
   - les **5xx et 429 « incertaines »**, jamais renvoyées automatiquement ;
   - une **purge complète, table par table** ;
   - un **fuseau réel ou rien** ;
   - un **webhook fermé aux visiteurs**, avec un débit borné et une fenêtre WhatsApp calculée sur l'heure réelle ;
   - une **garde à trois couches** : chaque fichier entier n'est plus que deux instructions inertes.
4. **Aucun système gelé n'a été modifié**, et aucune correction n'a dû s'arrêter pour cette raison. Trois points de minimisation dépendent de systèmes partagés et sont **signalés sans y toucher** : la durée de conservation de pg_net, `journal_audit`, et les journaux des fournisseurs.
5. **Ce qui est prouvé** : par analyse statique (le parseur de PostgreSQL, sans base), les quatre fichiers ne contiennent plus que `DO` + `SELECT '<texte>'`, et tout leur contenu (249 instructions, dont 67 corps PL/pgSQL) est syntaxiquement lisible.

   **Ce qui ne l'est pas** : le comportement à l'exécution (verrous, procédure appelée par pg_cron, quotas). Les essais T-01 à T-20 le prouveront sur base jetable, après autorisation.
6. **Avertissement d'indépendance** : ces corrections et leur contre-revue sont du même auteur que la conception. Une revue indépendante reste recommandée (§14).

---

## 2. Fichiers examinés

| Fichier | Lecture |
|---|---|
| `brouillons-sql/40` à `43` (3 974 lignes avant la phase) | intégrale |
| `COMMUNICATION_CENTER_PHASE_0_AUDIT.md`, `_PHASE_1_RAPPORT.md`, `_PHASE_1_1_RAPPORT.md`, `_PHASE_1_2_RAPPORT.md` | rapports antérieurs, constats et statuts |
| `COMMUNICATION_CENTER_ARCHITECTURE.md`, `_SECURITY.md`, `_DATABASE.md`, `_TESTING.md` | passages concernés par les huit points |
| `outils/supabase.sql` (`clients`, `permissions_du_role` et ses droits) | ciblée |
| `outils/supabase-naissance.sql`, `outils/supabase-suivi-externe.sql` | copies de `permissions_du_role` |
| `outils/essais-services/essai-services.py`, `essai-production.py` ; `outils/production/appliquer-chaine.sh`, `epreuve-restauration.sh` | lanceurs SQL : `ON_ERROR_STOP`, `--single-transaction` |
| `docs/production/secrets.md`, `.github/workflows/deploy.yml` | politique de la clé `service_role` |
| `assets/js/lieux.js` | liste des États américains (`clients.region`) |
| Branches `pixel-meta` (PR #46) et `ccr-1b1dd194-g07lcu` (PR #48) | différences avec `main` |
| Documentation publique : pg_cron, PostgreSQL (procédures), Brevo et Resend (idempotence) | faits **rapportés**, à éprouver |

---

## 3. Diagnostic des huit problèmes

| # | Problème | Verdict | Cause dans le code de la Phase 1.2 |
|---|---|---|---|
| 1 | Arrêt d'urgence | **CONFIRMÉ** | 43 l. 533 : réglages lus une fois par passage ; l. 643 : contrôle du canal sur cette copie. `communication_reserver` ignore les interrupteurs. Le passage forme une seule transaction, et pg_net n'envoie qu'au COMMIT. |
| 2 | Interblocage worker / annulation | **CONFIRMÉ (trois cycles)** | Envoi → client → jour → campagne (43 l. 637, 640 ; `reserver` l. 183, 187), contre campagne → envois (42 l. 782, 879). Le verrou du jour est gardé d'un envoi à l'autre. Confirmation : la ligne est verrouillée avant le consentement (41 l. 192 ; 43 l. 978). |
| 3 | Quota Brevo et débit | **CONFIRMÉ** | 43 l. 632 : estimation unique, décomptée en mémoire ; l. 637 : limite par passage. Atténué par pg_cron, qui ne lance qu'un exemplaire d'une tâche à la fois (rapporté), mais la conception ne doit pas s'y fier. |
| 4 | 5xx et double envoi | **CONFIRMÉ** | 43 l. 454 : 429 et 5xx traitées comme « refus sûr », avec trois nouveaux essais. |
| 5 | Purge et minimisation | **CONFIRMÉ** | 43 l. 1201-1214 : empreinte, requête et empreinte du contenu gardées. l. 1167 : audiences presque jamais effacées. Fenêtres WhatsApp, retours et empreintes des consentements gardés sans fin. |
| 6 | Fuseaux américains | **CONFIRMÉ (plus large)** | 43 l. 115-118 : `else 'America/New_York'` pour tous les autres pays. |
| 7 | Webhook et horodatage | **CONFIRMÉ** | 43 l. 1297 : `grant … to anon`, pas de débit dans la base. l. 959-960 : fenêtre calculée sur `now()`. l. 931 : horodatage converti sans garde. |
| 8 | Garde des migrations | **CONFIRMÉ (partiel)** | Le bloc DO seul est efficace avec le SQL Editor, `ON_ERROR_STOP` et `--single-transaction` (lanceurs du projet). Sans `ON_ERROR_STOP`, les 29 à 87 instructions suivantes de chaque fichier s'exécutent (comptées par analyse statique). |

Défauts supplémentaires :

| # | Défaut | Gravité |
|---|---|---|
| X1 | Incertains non comptés (fréquence, limite WhatsApp) | Élevée |
| X2 | STOP multi-comptes sans ordre de verrous | Moyenne |
| X3 | Lecture des modèles Meta même campagnes coupées | Faible |
| X4 | Compteurs techniques sans nettoyage | Faible |

---

## 4. Corrections apportées, et pourquoi

Le détail, les références et l'avant / après de chaque point sont dans `PHASE_1_3_TECHNICAL_CORRECTIONS.md`, §2 à §9.

| # | Correction | Justification technique | Où (fonction, ligne de définition) |
|---|---|---|---|
| 1 | Réglage `arret_urgence`. Verrou N0 (partagé pour les envois, exclusif pour les écritures). `arreter_communications` (administrateur et gérant), `lever_arret_communications` (administrateur, motif). Réglages relus à chaque envoi, sous N0 puis sous N5. | L'arrêt a un instant d'effet (son COMMIT) après lequel aucune transaction ne peut valider un envoi. Il n'y a aucun cache. Les messages déjà remis à pg_net ne sont pas rappelés (file partagée : système gelé) ; ils sont comptés. | 40 l. 180, 341, 358 ; 41 l. 842, 878 ; 43 l. 797 (`communication_traiter_un`), l. 213 (`communication_reserver`) |
| 2 | Procédure `traiter_communications` : un COMMIT par envoi. Ordre unique N0 → N1 campagne → N2 client → N3 consentement → N4 envoi → N5 compteurs, appliqué au travailleur, au webhook, au STOP, aux confirmations, aux transitions et à la purge. `lock_timeout` court. Un interblocage détecté annule l'envoi en entier. | Aucun verrou ne survit d'un envoi à l'autre. Toutes les fonctions prennent la campagne avant l'envoi. Une annulation n'envoie rien, puisque pg_net n'envoie qu'au COMMIT : pas de double envoi. | 40 §3 ; 43 l. 1033 ; 41 l. 201 ; 42 l. 782 |
| 3 | Quota Brevo **recalculé** et réservé sous le verrou global N5 ; débit global par minute (`communication_debit_minute`) ; quota vérifié valable 30 jours au plus ; quota partagé avec le transactionnel par défaut. | Les réservations sont sérialisées et chacune voit les précédentes : au plus 100 réussissent sur un disponible de 100, quel que soit le nombre de travailleurs. Il n'existe pas de réservation orpheline. | 43 l. 213 ; 40 l. 737, 789 |
| 4 | 5xx → `incertain`, toujours (règle contraire refusée). 429 → `incertain`, sauf règle **prouvée** (`communication_issues_http`). Autres 4xx → `echec`. | Une 5xx ne prouve pas un refus. La référence de corrélation n'est pas une clé d'idempotence. Les clés des fournisseurs ne sont pas confirmées. | 43 l. 516 ; 40 l. 706 ; 41 l. 905 |
| 5 | Purge d'une personne complète : empreintes recueillies d'abord, retours anonymisés, fenêtres et fuseau effacés, envois en attente supprimés. Demande ouverte d'office à la suppression du compte. Audiences anonymisées à l'échéance. Catégorie « empreintes » ajoutée. | Il ne reste qu'une **preuve justifiée**, l'empreinte d'un consentement ou d'une suppression active, jusqu'à une durée que **seul le juriste** fixera (BLOQUÉE). | 40 `executer_purge_communication` ; 43 l. 1534, 1589 ; 41 l. 322 |
| 6 | `communication_fuseau(client, canal)` : fuseau déclaré, HT, DO, ou État américain à un seul fuseau enregistré avec sa preuve ; **sinon inconnu, rien ne part**. Marge de fin de fenêtre. Calcul par nom IANA. | Le pays et l'indicatif ne prouvent pas le fuseau. L'heure d'été suit les règles de la date. Aucune donnée n'est recopiée de mémoire : la table des États est vide. | 40 l. 861, 896 ; 43 l. 139 ; 42 l. 529 ; 41 l. 934, 961 |
| 7 | Webhook : plus d'`anon`, rôle `communication_webhook` (sans connexion) ; débit par minute dans la base ; format contrôlé ; fenêtre WhatsApp = `greatest(ancienne, survenu_le)`. | Il y a deux portes (rôle, signature). Un message de 10 h reçu à 18 h ouvre une fenêtre jusqu'à 10 h le lendemain. La fenêtre ne recule jamais. | 43 l. 1168, 1199, 1295, 1705, 1747 |
| 8 | Contenu enfermé dans `$brouillon_goship_non_executable$`, plus le bloc DO, plus la garde d'origine dedans. Lecture en lecture seule de session **rejetée** (risque pour la production derrière le pooler). | Le fichier entier n'est plus que deux instructions inertes, quel que soit le client (sauf un découpeur naïf : limite documentée). | en-tête des quatre fichiers ; 40 l. 34 |

---

## 5. Avant / après (vue d'ensemble)

| Domaine | Phase 1.2 | Phase 1.3 |
|---|---|---|
| Transaction du travailleur | une pour tout le lot | une par envoi (procédure) |
| Interrupteurs | lus une fois | relus à chaque envoi, sous verrou, deux fois |
| Arrêt global | aucun | `arret_urgence`, instant d'effet défini |
| Ordre des verrous | annoncé « jour → campagne → client », non tenu | N0 → N5, appliqué partout |
| Quota Brevo | estimé une fois, en mémoire | recalculé sous verrou global, réservé |
| Débit | par passage | global, par minute |
| 5xx | trois nouveaux essais automatiques | incertain, jamais renvoyé |
| 429 | trois nouveaux essais | incertain, sauf règle prouvée |
| Purge d'une personne | client et identifiant effacés seulement | inventaire complet (§6 des corrections) |
| Fuseau | HT, DO, sinon New York | déclaré, HT, DO, État prouvé, sinon rien |
| Webhook | `anon` + HMAC | rôle dédié + HMAC + débit + format |
| Fenêtre WhatsApp | heure de réception | heure réelle, sans recul |
| Garde | DO seul (29 à 87 instructions exécutables derrière) | 2 instructions inertes par fichier |
| Tables / fonctions | 22 / 80 | 27 / 93 + 1 procédure |

---

## 6. Revue de sécurité PostgreSQL (synthèse)

Le détail est dans `PHASE_1_3_SECURITY_REVIEW.md`, §2.

- **Fonctions** : 94, dont 73 `SECURITY DEFINER`. Toutes ont un `search_path` vide, sauf la procédure : PostgreSQL l'interdit à une procédure qui valide. Elle vide donc son `search_path` elle-même et n'est exécutable par personne d'autre que son propriétaire.
- **Tables** : 27, toutes avec la sécurité par ligne activée, **sans** règle de lecture, et `revoke all` pour `anon` et `authenticated`. Quatre sont immuables, hors purge approuvée.
- **Visiteurs** : 2 fonctions seulement, chacune protégée par un jeton (confirmation, désinscription).
- **Comptes connectés** : 32 fonctions. Chacune vérifie sa permission ou l'identité du compte.
- **Rôles** :
  - l'employé n'a aucun accès ;
  - le gérant peut voir, créer, faire un essai, mettre en pause, gérer les consentements et couper ;
  - l'administrateur a, en plus, l'approbation et l'administration.
- **Sept permissions** : cinq copies à aligner ensemble en Phase 2.
- **Escalade** : aucune voie trouvée. Le rôle d'un compte ne change que par l'existant. Un consentement n'est jamais créé à la place du client. La purge passe par quatre yeux.

---

## 7. Dépendances transactionnelles (synthèse)

Le détail est dans `PHASE_1_3_SECURITY_REVIEW.md`, §3.

| Contrat gelé | Usage par le Centre |
|---|---|
| `notification_envois`, `notifications`, `auth.users` | **lus** seulement (priorité, quota) |
| `messages_recents`, `mon_resume`, `expedier_envoi`, `courriel_gabarit` | **non touchés** |
| Notifications de colis, de paiement, de compte ; e-mails d'authentification | **non touchés** |
| pg_net et pg_cron (partagés) | le Centre y ajoute ses requêtes et une tâche inactive ; il ne modifie ni leur file ni leurs réglages |

---

## 8. Risques résiduels

| # | Risque | Gravité | Traitement |
|---|---|---|---|
| 1 | Comportement à l'exécution non éprouvé (verrous, procédure et pg_cron, quotas) | **Élevée tant que non éprouvé** | Essais T-01 à T-05, T-01-bis, avant toute activation |
| 2 | Messages déjà dans la file de pg_net au moment d'un arrêt | Moyenne | Comptés et signalés ; vider la file partagée serait une décision du CEO (déconseillé) |
| 3 | Authentification de la fonction Edge non choisie | Moyenne | Décision S-1 (§10) |
| 4 | Données personnelles hors du Centre (pg_net, `journal_audit`, fournisseurs) | Moyenne | Juriste et CEO |
| 5 | Réessai des fournisseurs après une erreur temporaire du webhook (STOP différé) | Moyenne | Vérification documentaire avant la Phase 3 |
| 6 | 429 fréquentes : beaucoup d'incertains à traiter à la main | Moyenne | Débit global ; règle 429 sur preuve (décision) |
| 7 | Aucun envoi aux USA tant qu'aucun fuseau n'est déclaré ni aucun État enregistré | Faible (voulu) | Décision et Phase 2c (déclaration du fuseau dans « Mon compte ») |
| 8 | Coût du calcul Brevo sous verrou global | Faible à 20 par minute | Mesure T-05 |
| 9 | Découpeur SQL naïf qui continue après erreur | Faible | Limite documentée ; T-14 |
| 10 | `service_role` garde l'exécution par défaut des fonctions internes de 40 à 42 | Faible | Retrait en Phase 2 |
| 11 | **Hérités et toujours ouverts** : C4 (identités commerciales séparées), identité légale et adresse postale (D-G, D-H), textes juridiques, durées de conservation | Bloquants pour l'activation | Décisions du CEO et du juriste |

---

## 9. Essais prévus et statut réel

| Essai | Objet | Criticité | Statut |
|---|---|---|---|
| T-01 | Arrêt d'urgence pendant un lot | BLOQUANT | **NON EXÉCUTÉ** |
| T-01-bis | Procédure appelée par pg_cron, COMMIT par envoi | BLOQUANT | **NON EXÉCUTÉ** |
| T-02 | Arrêt avec quatre travailleurs | BLOQUANT | **NON EXÉCUTÉ** |
| T-03 | Annulation pendant un verrouillage | BLOQUANT | **NON EXÉCUTÉ** |
| T-04 | Quatre travailleurs, 100 unités de quota | BLOQUANT | **NON EXÉCUTÉ** |
| T-05 | Débit global par minute | ÉLEVÉ | **NON EXÉCUTÉ** |
| T-06 | HTTP 500 après acceptation | BLOQUANT | **NON EXÉCUTÉ** |
| T-07 | HTTP 429 | ÉLEVÉ | **NON EXÉCUTÉ** |
| T-08 | Suppression d'un client, données résiduelles | BLOQUANT | **NON EXÉCUTÉ** |
| T-09 | Fuseaux américains multiples (8 villes + Floride) | BLOQUANT | **NON EXÉCUTÉ** |
| T-10 | Changement d'heure | ÉLEVÉ | **NON EXÉCUTÉ** |
| T-11 | Webhook retardé | ÉLEVÉ | **NON EXÉCUTÉ** |
| T-12 | Webhook rejoué | ÉLEVÉ | **NON EXÉCUTÉ** |
| T-13 | Appel direct non autorisé, débit | BLOQUANT | **NON EXÉCUTÉ** |
| T-14 | Exécution d'un brouillon (cinq clients) | BLOQUANT | **NON EXÉCUTÉ** |
| T-15 | Permissions et sécurité par ligne | BLOQUANT | **NON EXÉCUTÉ** |
| T-16 | Non-régression du transactionnel | BLOQUANT | **NON EXÉCUTÉ** |
| T-17 | Désinscription prioritaire | BLOQUANT | **NON EXÉCUTÉ** |
| T-18 | Changement de coordonnées | BLOQUANT | **NON EXÉCUTÉ** |
| T-19 | Purge à l'échéance | ÉLEVÉ | **NON EXÉCUTÉ** |
| T-20 | Ordre des verrous des consentements | MOYEN | **NON EXÉCUTÉ** |

**Seule vérification faite** : l'analyse statique des brouillons (parseur de PostgreSQL, sans base). Ce n'est **pas** un essai, et aucun essai n'est marqué réussi.

---

## 10. Décisions en attente du CEO

| # | Décision | Recommandation |
|---|---|---|
| 1 | **C4** (hérité) : compte e-mail commercial séparé ; numéro WhatsApp dédié ou Coexistence | Inchangée (rapport 1.2) |
| 2 | **S-1** : comment la fonction Edge appellera la base | **Un rôle de connexion dédié**, avec son mot de passe dans les secrets de la fonction Edge (moindre privilège). La clé `service_role` est aujourd'hui utilisée nulle part. |
| 3 | Le gérant peut-il déclencher l'arrêt d'urgence ? La levée reste réservée à l'administrateur | Oui : couper ne peut que protéger |
| 4 | Messages déjà dans la file de pg_net lors d'un arrêt : les laisser partir (et les compter) ou toucher à la file partagée | Les laisser, ne pas toucher au système partagé |
| 5 | Réponse 429 : rester « incertaine », ou devenir « refus temporaire » sur preuve de la documentation officielle de Brevo | Garder « incertaine » jusqu'à la preuve |
| 6 | Fuseaux : méthode (fuseau déclaré par le client en Phase 2c ; États à fuseau unique chargés avec preuve) ; accepter qu'aucun client américain ne reçoive rien d'ici là | Accepter |
| 7 | Valeurs de conception : `debit_max_minute` 20, `marge_fenetre_min` 15, `brevo_quota_validite_jours` 30, `webhook_max_minute` 600 | Les confirmer ou les changer ; ce ne sont pas des limites des fournisseurs |
| 8 | Juriste : durées de conservation, dont la nouvelle catégorie « empreintes » ; `journal_audit` ; durée de pg_net ; journaux des fournisseurs | À engager |
| 9 | Hérités : D-G (adresse postale), D-H (adresse de Miami), textes juridiques, quatre yeux à l'approbation | Inchangées |
| 10 | Ordre des PR | **#46 avant la Phase 2c** du Centre. Avec **#48** : une seule convention de fonction Edge, et le premier projet qui écrit sa migration pose les permissions des deux. |
| 11 | **Autorisation de la Phase 2**, limitée à une base jetable, et autorisation de modifier, hors de ce dossier, les copies des permissions et les bancs d'essai | Voir §14 |

---

## 11. Respect des règles de la phase

| Règle | Respectée |
|---|---|
| Aucun changement de la base de production | **Oui** |
| Aucun SQL exécuté, même sur une base de test | **Oui**. Seulement une analyse statique du texte, sans serveur. |
| Aucun déploiement ; aucune PR fusionnée | **Oui** |
| Aucun cron, travailleur ou webhook activé | **Oui** (tâche créée inactive dans le brouillon, jamais exécutée) |
| Aucune connexion à Brevo ou à Meta ; aucun envoi ; aucune dépense | **Oui** (lecture de documentation publique seulement) |
| Aucun secret ajouté ; numéro WhatsApp inchangé | **Oui** |
| Aucun système transactionnel modifié ; aucune donnée client modifiée | **Oui** |
| Fonctions marketing toujours éteintes | **Oui** : tout reste OFF / BLOQUÉ, budgets à 0 |
| Fichiers modifiés seulement dans `docs/communication-center/` | **Oui** |
| Garde jamais retirée | **Oui** : renforcée |
| Décisions validées du CEO préservées | **Oui** (deux canaux, admin et gérant seulement, approbation de l'administrateur, consentement explicite, désinscription prioritaire, séparation du transactionnel) |

---

## 12. Fichiers modifiés

**Brouillons** :
- `brouillons-sql/40-supabase-communications-fondation.sql` : 894 → 1 171 lignes ;
- `41-…-consentement.sql` : 813 → 1 047 ;
- `42-…-campagnes.sql` : 968 → 989 ;
- `43-…-envoi.sql` : 1 299 → 1 753.

**Nouveaux documents** : `PHASE_1_3_TECHNICAL_CORRECTIONS.md`, `PHASE_1_3_SECURITY_REVIEW.md`, `PHASE_1_3_TEST_PLAN.md`, `PHASE_1_3_FINAL_REPORT.md`.

**Documents annotés** (mentions « [Corrigé 1.3] ») : `COMMUNICATION_CENTER_ARCHITECTURE.md`, `_SECURITY.md`, `_DATABASE.md`, `_TESTING.md`, `_PHASE_1_2_RAPPORT.md` (errata), `README.md`.

---

## 13. Verdict

**VALIDÉ SOUS CONDITIONS.**

- **Pourquoi pas « VALIDÉ POUR PRÉPARER LA PHASE 2 »** :
  - des décisions bloquantes restent ouvertes (C4, S-1, juriste, D-G, D-H) ;
  - aucune des corrections de concurrence n'est encore éprouvée ;
  - or c'est précisément là que se trouvaient les défauts.
- **Pourquoi pas « REFUSÉ »** :
  - chacun des huit risques a une correction dont la cause est traitée, et non masquée ;
  - aucun risque critique connu n'est laissé sans parade dans la conception ;
  - tout ce qui dépend d'une preuve reste fermé : rien ne peut partir.

**Conditions** :
1. les décisions du §10 ;
2. la réussite **prouvée** des essais BLOQUANTS sur base jetable avant toute activation ;
3. une revue indépendante des corrections de la Phase 1.3.

---

## 14. Recommandation pour la suite

1. **Revue indépendante** de la Phase 1.3 (par une autre personne ou une autre session), sur le modèle de la Phase 1.1. Elle doit porter surtout sur l'ordre des verrous, la procédure et la purge.
2. Puis, **si le CEO l'autorise par écrit**, une Phase 2 **limitée à la base jetable**, dans cet ordre :
   - **T-14** : garde ;
   - **T-01-bis** : procédure et pg_cron. Si c'est refusé, appliquer le repli documenté et refaire la revue ;
   - **T-03, T-01, T-02, T-04, T-05** : concurrence ;
   - **T-06 à T-20**.
3. Aucune activation, aucun fournisseur, aucune production avant ces preuves et les décisions du §10.

**Rappel** : ce verdict n'autorise pas la Phase 2. Seul le CEO peut l'autoriser, par une instruction écrite explicite.
