# Centre de communication — correspondance entre brouillons 40–43 et candidates 001–009

**Rédigé le 23/11/2026 par Claude Code, en lecture seule**, pour éclairer la décision A de
`PHASE_1_3_1_DECISIONS_CEO_EN_ATTENTE.md` : sur quel code portent la revue indépendante et les
78 essais ? Je n'ai exécuté ni SQL ni essai, et aucune base n'a été utilisée. Cette table compare des
textes ; elle ne prouve aucun comportement.

Phase 1.3.1 : **NON VALIDÉE**. Phase 2 : **NON AUTORISÉE**. Brouillons 40–43 : **NON EXÉCUTABLES**.

**Version examinée** : brouillons à l'empreinte de `PHASE_1_3_1_DOSSIER_REVUE_INDEPENDANTE.md` §1 ;
candidates `outils/migrations-candidates/001` à `009` dans la copie de travail du 23/11/2026, non
commitées.

**Méthode et limites** : inventaire automatique des instructions `create` (tables, vues, fonctions,
procédures), puis lecture ciblée des passages cités. Je n'ai pas comparé ligne à ligne le corps des
fonctions qui portent le même nom. Les essais T-01 à T-40 du premier plan ne sont rapprochés que par
famille.

---

## 1. Constat principal : deux lignées au périmètre différent

| | Brouillons 40–43 | Candidates 001–009 |
|---|---|---|
| Objets nommés distincts (tables, vues, fonctions, procédures) | 139 | 113 |
| Objets de même nom dans les deux lignées | **10** | **10** |
| Objectif | Envoi **marketing** complet : campagnes, file `communication_envois`, appels Meta et Brevo par pg_net, tâche `pg_cron` propre, quotas, tarifs, fenêtres, purges | Intégration au moteur **transactionnel** existant (`notification_envois`, `traiter_notifications`), consentement WhatsApp, retours fournisseurs, interface, campagnes **sans envoi**, identité Edge |
| Moteur transactionnel existant | **Intact**, par construction (« rien ici ne touche le transactionnel » ; essais F-T01, F-T02, F-S03) | **Modifié** : 004 et 005 redéfinissent `expedier_envoi`, `lire_reponse_envoi`, `texte_notification` et `traiter_notifications`, fonctions de `outils/supabase-notifications.sql` ; 004, 006 et 009 ajoutent des colonnes à `notification_envois` |
| Envoi marketing | Oui | **Non** : 008 prépare, fait approuver et planifie, mais n'envoie rien |
| pg_net et `pg_cron` propres | Oui (43 : `net.http_post`, tâche `goship-communications`) | Non : ils réutilisent le travailleur officiel `goship-notifications`, qui appelle pg_net |
| Hiérarchie des verrous | N0 → N0a → N1 → N2 → N3 → N3b → N3c → N4 → N5, clés `goship-communication:*` | **Autre jeu de clés** : `goship-communication:interrupteurs` (N0) ; `goship:consent-account:<client>`, `goship:whatsapp:<empreinte>`, `goship:whatsapp:client:`, `goship:communication-template:`, `goship:c6:model:`. **Aucun ordre global documenté** comme celui des brouillons (40 l. 307–338) |
| Essais | 78 prévus, **0 exécuté** | Banc local, 438/438 déclarées par Codex (`COMMUNICATION_CENTER_C7_3_RAPPORT_LOCAL.md`) |

**Conséquence** : les candidates ne sont **pas** une nouvelle version des brouillons. Elles
réutilisent quelques idées (porte P-07, arrêt en deux temps, retours P-08), mais le reste est un autre
système, en partie complémentaire. Une revue ou des essais portant sur l'une des lignées ne disent rien
de l'autre.

## 2. Les 10 objets communs

| Objet | Brouillon | Candidate | Écart observé |
|---|---|---|---|
| `communication_arret` (table) | 40 | 001 | Mêmes états, mais seuls les brouillons ont une **fonction de levée** (41 `lever_arret_communications`). Dans 001, la colonne `leve_le` existe, mais aucune fonction de levée n'a été trouvée |
| `communication_verrou_interrupteurs` | 40 l. 356 | 001 | Même clé consultative N0 |
| `communication_autoriser_sortie` | 40 l. 404 | 001 | Porte appelée avant les envois marketing (brouillons) ou avant l'adaptateur transactionnel (candidate 004) |
| `communication_sortie_autorisee` | 40 l. 439 | 001 | Corps non comparé ligne à ligne |
| `communication_evenements_fournisseur` (table) | 43 l. 1319 | 001 | Brouillon : `envoi_id` sans clé étrangère (RF-02) ; corps de la candidate non comparé |
| `communication_evenements_traitement` (table) | 43 | 001 | 006 ajoute un historique et une clé étrangère vers elle (006 l. 39) |
| `communication_recevoir_evenement` | 43 l. 1487 | 006 | Brouillon : temps A, accusé seulement. Candidate : réception générique signée, appelée par l'Edge (009) |
| `communication_traiter_evenement` | 43 l. 1641 | 006 | Brouillon : temps B avec N3c et lecture préparatoire. Candidate : traitement prioritaire `SKIP LOCKED` dans une seule transaction |
| `sante_communications` | 43 l. 2300 | 002 | Supervision ; la candidate a une liste blanche et des compteurs conditionnés à l'existence des tables |
| `permissions_du_role` | 40 l. 1330 | 007 **et** 008 | Redéfinie **trois fois** dans les candidates, en comptant la modification locale de `outils/supabase.sql` (décision G) |

## 3. Correspondance par correction

| Correction | Brouillons 40–43 | Candidates 001–009 | Écart |
|---|---|---|---|
| **P-07 / RF-01**, arrêt en deux appels | 41 `arreter_communications` (N0a seul, `synchronous_commit`) puis `confirmer_arret_communications` ; le constat observe la file pg_net | 001 `communication_demander_arret` puis `communication_confirmer_arret` ; `READ COMMITTED` exigé ; pas de confirmation tant que `notification_envois` compte des états `envoi` ou `incertain` | Même principe, mais un critère de confirmation différent : file pg_net contre états de l'outbox. Pas de levée dans les candidates |
| **P-08 / RF-02**, retours fournisseurs | Temps A (accusé) et temps B (N1/N3/N3b, puis N3c `SKIP LOCKED`, puis N4) ; pas de clé étrangère vers l'envoi | 006 : réservation, effets et état dans **une seule transaction** `SKIP LOCKED`, sans bail ; reçus Expo | Constructions différentes ; Q3, Q4 et Q6 se posent différemment |
| **P-09 / RF-03**, STOP | `STOP` entier normalisé ; variantes et **boutons non vérifiés** classés « ambigus » | 006 l. 211–213 : `STOP` exact dans le **texte ou le bouton** devient `stop` | **Divergence** : la candidate accepte un bouton « STOP », que le brouillon classe comme ambigu tant que le contrat Meta n'est pas vérifié |
| **P-05 / N3b**, contact partagé | Verrou `contact:<canal>:<empreinte>` après N3 | `goship:whatsapp:<empreinte>` après `goship:consent-account:<client>` (003, 006, 009) | Idée voisine pour WhatsApp seulement ; aucun envoi marketing à sérialiser |
| **N-01**, plafond de fréquence | Par empreinte et par compte (43) | Absent : aucun envoi marketing | Non applicable aux candidates en l'état |
| **N-02**, code WhatsApp | 60 min, 5 erreurs, limites répétées (valeurs écrites) | 003 : code dans Vault ; durées et limites **sans valeur par défaut**, l'appel échoue fermé tant qu'elles ne sont pas réglées | Les candidates attendent la décision H au lieu de fixer ces valeurs |
| **D2**, numéros partagés | Exclusion prudente, codée | 003 : `politique_contact_partage` nulle (échec fermé), `bloquer` ou autre valeur réglable | Les candidates attendent la décision |
| **P-03**, attentes bornées | `lock_timeout` de 2 à 5 s dans chaque fonction | `lock_timeout` présent dans 001, 003 à 008 ; absent de 002 (lecture) et de 009 | À vérifier fonction par fonction pour 009 |
| **S-1**, identité Edge | Rôle `communication_webhook` sans connexion, sans mécanisme d'appel | 009 : JWT ES256, deux rôles membres d'`authenticator` | Seules les candidates traitent S-1 |
| Supervision | `sante_communications` (43) | 002 et 007 (`communication_c5_sante`) | Comparable |
| Purges et conservation | 40 et 43 (`executer_purge_communication`, `communication_purger_*`) | Absentes | Non couvert par les candidates |

## 4. Applicabilité des 78 essais aux candidates (par famille)

| Famille | Cible actuelle | Sur les candidates |
|---|---|---|
| F-K01 à F-K12, arrêt | Brouillons (pg_net, N0/N0a) | **À adapter** : même porte N0, mais confirmation par l'outbox ; F-K05 et F-K09 (pg_net) passent par le travailleur officiel ; la levée n'existe pas |
| F-M01 à F-M03, migrations | Brouillons | **À reformuler** : le banc C7.3 applique et rejoue les candidates ; je n'ai pas vérifié s'il éprouve un retour arrière |
| F-T01, F-T02, F-S03, séparation du transactionnel | Brouillons : le transactionnel ne doit pas changer | **Attendu inversé** : les candidates modifient volontairement quatre fonctions transactionnelles ; il faut une non-régression du transactionnel modifié |
| F-W01 à F-W08, retours | Brouillons (temps A et B) | **À adapter** à la transaction unique de 006 ; F-W03 doit trancher la divergence du bouton STOP |
| F-C01 à F-C11, audience et consentement | Brouillons (envoi de campagne) | **Partiel** : consentement WhatsApp (003) et calcul d'audience (008) ; F-C06 et F-C10 sont sans objet faute d'envoi |
| F-S01, inventaire des droits | Brouillons | Applicable, sur un autre inventaire |
| T-01 à T-40 (premier plan) | Brouillons | Non rapprochés en détail |

## 5. Ce que cela change pour la décision A

1. **Les deux lignées ne sont pas interchangeables.** Les brouillons portent l'envoi marketing ; les
   candidates portent l'intégration transactionnelle, le consentement, l'identité Edge et la
   préparation des campagnes.
2. **Si les candidates deviennent la base de la Phase 2**, il faut une revue indépendante, avec des
   questions Q1–Q7 réécrites pour leur hiérarchie de verrous, qui n'est pas documentée, et des essais
   réécrits (§4). Il faut aussi des décisions sur trois points :
   - la **modification du moteur transactionnel**, alors que le README exige que les contrats
     existants ne changent pas implicitement ;
   - le **bouton STOP** ;
   - l'**absence de levée de l'arrêt**.
3. **Si les brouillons restent la base**, les candidates ne valent pas preuve pour eux. Le volet
   transactionnel, le consentement par Vault et S-1 des candidates devraient y être reportés ou
   abandonnés.
4. **Une voie mixte** (les brouillons pour l'envoi marketing, les candidates pour le transactionnel,
   le consentement et l'Edge) exige d'abord de choisir une seule définition pour chaque objet commun
   (§2) et une **hiérarchie de verrous unique** couvrant les deux ensembles.

**Avis technique, qui n'est pas une décision** : avant toute revue payante, la CEO devrait fixer le
périmètre de la Phase 2. Ensuite, une seule hiérarchie de verrous, documentée, est la condition
préalable à toute revue Q1–Q7 utile.
