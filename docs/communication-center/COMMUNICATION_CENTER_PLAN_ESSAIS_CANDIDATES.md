# Communication Center — plan d'essais des candidates (remplace les 78 essais des brouillons)

**Établi le 23/11/2026 par Claude Code, avec l'autorisation écrite de la CEO**, pour la version figée
de `COMMUNICATION_CENTER_DOSSIER_REVUE_CANDIDATES.md` (§1).

Les 78 essais de la Phase 1.3.1 (40 dans `PHASE_1_3_1_TEST_PLAN.md`, 38 dans
`PHASE_1_3_1_FINAL_TEST_PLAN.md`) visaient les brouillons 40–43, qui ne seront jamais exécutés.
Depuis la décision A, les candidates fondent la Phase 2. Ce plan dit, pour chaque essai d'origine, ce
qui le couvre aujourd'hui sur les candidates, ce qui reste à écrire, et ce qui ne peut pas être prouvé
en local.

**Ce plan ne valide rien.** Un essai qui passe prouve que le code fait ce que son auteur a prévu ; la
revue indépendante juge ce qui n'a pas été prévu.

## 1. Ce qui tourne déjà (bases jetables, sans réseau)

| Banc | Ce qu'il éprouve | Résultat au 23/11/2026 |
|---|---|---|
| `essai-communication-center.py` | Deux bases neuves : transactionnel, adaptateurs et retours, arrêt P-07, identité S-1, consentements WhatsApp, P-08, interface C5, campagnes C6, arrêt Admin C10, réglages et alertes C9, rejeu de la chaîne C11 ; essais Node Edge et interface | **528/528** |
| `essai-communication-center.py --s1-only` | Identité Edge S-1 et parcours du code WhatsApp C7.3 | **74/74** |
| `essai-communication-non-regression.py` | Accusés, suivi des e-mails et programmes, rejoués avec les candidates après leur fichier | **36/36, 49/49, 374/374** |
| Bancs officiels (`essai-*.py`, 32) | Toute la chaîne, candidates comprises, sous les règles métier existantes | 30/32 sur un Mac ; analytics (temps) et mobile (fuseau) échouent à l'identique sans les candidates |
| `essai-production.py` | Garde-fou C11, contrôle de sécurité, sauvegarde et restauration, rejeu de la chaîne | **153/153** |

Depuis C11, le banc et la non-régression tournent aussi dans la CI (`.github/workflows/essais.yml`).

**Limite commune** : un seul processus pilote les entrelacements, avec des fils Python et des pauses.
Ce n'est pas un ordonnanceur pas à pas : un entrelacement non écrit n'est pas éprouvé.

## 2. Correspondance des 38 essais finaux (F-*)

Légende : **Couvert** = un essai du banc l'éprouve (nom cité) ; **Partiel** = une partie seulement ;
**À écrire** = faisable en local, pas encore écrit ; **Hors local** = exige Supabase ou pg_net réels,
donc une autorisation distincte ; **Sans objet** = la fonction n'existe pas dans les candidates.

### Arrêt d'urgence (F-K)

| Essai | État | Ce qui le couvre ou ce qui manque |
|---|---|---|
| F-K01 — V0 exclusif attend la fin de toute porte | **Partiel** | « confirmation concurrente reste en attente sous N0 », « travailleur bloqué dans l'adaptateur local sous N0 ». Manque : plusieurs portes simultanées (§4, E-01) |
| F-K02 — Porte ouverte après la fermeture voit l'arrêt | **Couvert** | « nouvelle sortie refusée après confirmation sans appel adaptateur », « porte fermée dès la demande validée » (C10) |
| F-K03 — Aucune attente après V0a | **Couvert** | « demande d'arrêt persistée sans attendre le verrou N0 » |
| F-K04 — Ordre des verrous avec le travailleur | **Partiel** | « envoi déjà autorisé termine sans deadlock ». Manque : point L-1 (sorties puis retours dans la même transaction) (§4, E-02) |
| F-K05 — pg_net : sortie de file et délai | **Hors local** | pg_net est une doublure ; à éprouver sur une stack Supabase locale (§5) |
| F-K06 — Aucune transmission après `STOP_CONFIRMED` | **Couvert** | « nouvelle sortie refusée après confirmation… », « aucune transmission de code ne commence après la demande d'arrêt » (C7.3) |
| F-K07 — Durée de l'arrêt sous le délai d'exécution | **À écrire** | Mesurer demande, confirmation et levée sous `statement_timeout` de 8 s et 3 s (§4, E-03) |
| F-K08 — Pas de retour d'arrêt sans fermeture | **Partiel** | « fermeture durable conservée pendant les reprises avec envois en cours », « table d'arrêt toujours fermée en écriture directe » |
| F-K09 — pg_net : délai avant le transfert | **Hors local** | idem F-K05 |
| F-K10 — La demande reste écrite si le constat échoue | **Couvert** | « échec de confirmation ne supprime pas la demande validée », « demande attribuée à l'Admin et durable » |
| F-K11 — Course demande / levée | **Couvert** | « levée refusée si l'état a changé depuis l'affichage », « levée avec la version d'avant la demande refusée » (C10) |
| F-K12 — Demande sans V0, portes ouvertes | **Partiel** | « demande d'arrêt persistée sans attendre le verrou N0 » (une porte). Manque : trois portes ouvertes (§4, E-01) |

### Migrations (F-M)

| Essai | État | Ce qui le couvre ou ce qui manque |
|---|---|---|
| F-M01 — Garde des fichiers | **Couvert** | Chaque candidate, sauf la 002 (une seule fonction de lecture), refuse de s'appliquer sans ses dépendances (`…_DEPENDENCY_MISSING`, `…_UNAVAILABLE`) ; `appliquer-chaine.sh` s'arrête avant elles et les refuse en production (`essai-production.py`, section J) |
| F-M02 — Chaîne appliquée puis rejouée | **Couvert** | « candidates rejouées sans erreur » ; « C11 — rejeu de la chaîne sur une base existante » (versions les plus récentes enveloppées) ; essai de production (chaîne de 50 fichiers, deux fois) |
| F-M03 — Retour arrière | **À écrire** | Aucun script de retour arrière n'existe : la décision reste à prendre (restauration de sauvegarde, ou script de désinstallation) (§4, E-04) |

### Séparation avec le transactionnel (F-T, F-S)

L'attendu est **inversé** : les candidates modifient volontairement le moteur transactionnel. On
vérifie donc qu'il **continue de faire ce qu'il faisait**, et non qu'il n'a pas changé.

| Essai | État | Ce qui le couvre ou ce qui manque |
|---|---|---|
| F-T01 — Non-régression des notifications existantes | **Couvert** | `essai-notifications.py` 87/87 sur la chaîne complète, et la non-régression (accusés, suivi des e-mails, programmes) ; seul écart voulu : `LIMITE_DEBIT` au lieu de `HTTP_429` |
| F-T02 — Le centre ne lit aucune clé du transactionnel | **Partiel** | « supervision sans destinataire, contenu d'erreur libre ni identifiants client/colis ». Manque : inventaire des lectures de `vault.decrypted_secrets` (§4, E-05) |
| F-S01 — Inventaire des droits | **Partiel** | Contrôle de sécurité de la chaîne (aucune fonction privilégiée ouverte aux visiteurs, sauf `sante` et `suivre_colis`) ; « RPC SECURITY DEFINER à search_path explicite ». Manque : inventaire complet par rôle, figé (§4, E-05) |
| F-S03 — Empreinte des contrats | **Partiel** | « C11 — rejeu » compare le corps des fonctions intérieures au texte source. Manque : empreinte de `pg_get_functiondef` des fonctions publiques du transactionnel, comparée d'une version à l'autre (§4, E-06) |

### Retours des fournisseurs (F-W)

| Essai | État | Ce qui le couvre ou ce qui manque |
|---|---|---|
| F-W01 — Deux retours simultanés pour le même envoi | **Couvert** | « deux workers concurrents terminent sans double effet », « SKIP LOCKED ne double-traite pas une ligne réservée » |
| F-W02 — STOP entrant et code 131050 pour le même numéro | **Partiel** | « STOP traité avant la file transactionnelle », « STOP annule les confirmations ouvertes ». Manque : les deux en parallèle (§4, E-07) |
| F-W03 — Reconnaissance du STOP | **Partiel** | « consentement propre au canal, ambiguïté partagée et STOP exclus ». La liste des formulations reste une question juridique (D2, STOP) |
| F-W04 — Retour et chemins concurrents | **Partiel** | P-08 sous deux travailleurs. Manque : un retour pendant une confirmation d'arrêt (§4, E-02) |
| F-W05 — Reprise et unicité | **Couvert** | « interruption annule les effets et planifie une reprise », « événement interrompu repris une fois après correction » |
| F-W06 — Surveillance et reprise manuelle | **Couvert** | « alerte de retour en attente depuis plus de 10 min » (C9), reprise ciblée (C5) |
| F-W07 — Purge par date | **À écrire** | La purge des retours P-08 n'est pas éprouvée (décision de conservation en attente du juriste) |
| F-W08 — Échec de la réception | **Partiel** | « webhook P-08 accepté et file créée par la même RPC », « rejeu P-08 idempotent ». Manque : base qui refuse l'insertion (§4, E-08) |

### Audience et consentement (F-C)

Les candidates **n'envoient aucune campagne** (C6 prépare, planifie, ne transmet pas). Les essais qui
supposent un envoi marketing sont **sans objet jusqu'à la Phase 3**, où ils devront être réécrits pour
l'outbox unique.

| Essai | État | Ce qui le couvre ou ce qui manque |
|---|---|---|
| F-C01 — Jamais d'audience sans consentement confirmé | **Couvert** (calcul) | « consentement propre au canal, ambiguïté partagée et STOP exclus », « audience agrégée sans téléphone… » |
| F-C02 — Une inscription ne crée aucun consentement | **Couvert** | « aucun consentement marketing créé par les événements transactionnels » |
| F-C03 — Double consentement | **Couvert** | « création de demande liée au compte réel », « confirmation correcte et rejeu idempotent » |
| F-C04 — Changement de contact après consentement | **À écrire** | Changement du numéro d'un compte consentant (§4, E-09) |
| F-C05 — Fuseau inconnu | **Sans objet** | Aucun envoi planifié n'est transmis avant la Phase 3 |
| F-C06 — Numéro partagé par deux comptes | **Couvert** | « numéro partagé bloqué tant que la politique CEO est absente », « STOP retire les deux consentements du contact partagé » |
| F-C07 — Désinscription d'un nouveau client | **Couvert** | « retrait de consentement traçable » |
| F-C08 — Contact devenu commun après le gel | **Sans objet** | Suppose un envoi de campagne (Phase 3) |
| F-C09 — Règle D2 | **Couvert** (consentement) | « numéro partagé bloqué… » ; la politique `bloquer` est réglée (011) ; validation juridique en attente |
| F-C10 — Fréquence par contact | **Sans objet** | Suppose un envoi de campagne (Phase 3, N-01) |
| F-C11 — Code de confirmation | **Couvert** | « double demande réutilise la demande ouverte sans doublon », « code incorrect refusé et limite synthétique appliquée », « code expiré refusé », « indice d'unicité des codes ouverts par empreinte présent » |

### Bilan des 38

| État | Nombre |
|---|---|
| Couvert | 18 |
| Partiel | 11 |
| À écrire | 4 |
| Hors local | 2 |
| Sans objet (avant la Phase 3) | 3 |

(F-C01 et F-C09 sont comptés « couverts » pour leur volet consentement ; leur volet envoi relève de la Phase 3.)

## 3. Les 40 premiers essais (T-*)

Ils portaient sur le travailleur de campagne des brouillons (`traiter_communications`, débit global,
quotas Brevo, fuseaux, purge, migration interrompue). Rapprochement :

- **Arrêt et travailleurs (T-01 à T-03, T-01B à T-01I, T-13)** : repris par F-K ci-dessus ; T-01H
  (levée et arrêt concurrents) est couvert par C10 ; T-13 (appel direct non autorisé) par « porte
  interne non appelable par les rôles applicatifs ».
- **5xx et 429 (T-06, T-07, T-04B)** : l'attendu a changé avec la **décision K** pour le
  transactionnel : nouvel essai, couvert par les trois essais « décision K » et par « erreur
  temporaire programmée pour reprise ». L'attendu « incertain, aucun renvoi » reste celui des
  campagnes (Phase 3).
- **Webhooks retardés, rejoués ou falsifiés (T-11, T-12, T-07B, T-07C)** : couverts par P-08 (rejeu
  idempotent, transition contradictoire refusée) et par l'identité S-1 (signature ES256).
- **Permissions (T-15)** : couvert par les essais de rôles de C5, C6, C10 et par le contrôle de
  sécurité ; inventaire complet à écrire (E-05).
- **Non-régression (T-16, T-20B)** : couvert (F-T01).
- **Désinscription et coordonnées (T-17, T-18)** : désinscription couverte ; changement de
  coordonnées à écrire (E-09).
- **Débit, quotas, fuseaux, changement d'heure, purge (T-03B, T-04, T-05, T-05B, T-05C, T-06B, T-08 à
  T-10, T-19)** : sans objet avant la Phase 3, sauf T-05C (purge des confirmations jamais envoyées),
  couvert par « secret de confirmation supprimé après expiration » et « effacement du compte supprime
  le secret en attente ».
- **Migration interrompue et découpeurs (T-14, T-14B, T-14C)** : chaque fichier est appliqué dans une
  seule transaction (`appliquer-chaine.sh --single-transaction`) ; une erreur arrête la chaîne
  (`essai-production.py`, J). Découpeurs naïfs : sans objet (aucun découpage des fichiers).
- **Ordre des verrous des consentements (T-20)** : Q5 de la revue, et E-01.

## 4. Essais à écrire en local (sans autorisation supplémentaire, bases jetables)

| N° | Essai | Origine | Comment |
|---|---|---|---|
| E-01 | Trois portes ouvertes, puis une demande, puis une confirmation | F-K01, F-K12, T-20 | Trois connexions tiennent V0 partagé ; la demande aboutit, la confirmation attend puis passe à leur fin |
| E-02 | Travailleur qui lit des retours pendant une confirmation d'arrêt | F-K04, F-W04, L-1 | Entrelacement pas à pas, avec des verrous consultatifs de banc pour figer chaque étape |
| E-03 | Durée de demande, confirmation et levée sous `statement_timeout` de 8 s et 3 s | F-K07, L-5 | Sous charge de portes ouvertes ; aucun appel ne dépasse le délai de son rôle |
| E-04 | Retour arrière | F-M03 | Décision préalable : restauration de sauvegarde (déjà éprouvée par `essai-production.py`) ou script de désinstallation |
| E-05 | Inventaire figé des droits et des lectures de Vault | F-S01, F-T02, T-15 | Requête sur `pg_proc`, `pg_class` et `has_*_privilege` par rôle, comparée à une liste attendue versionnée |
| E-06 | Empreinte des contrats du transactionnel | F-S03 | `pg_get_functiondef` des fonctions publiques du transactionnel, comparé d'une version à l'autre |
| E-07 | STOP et code 131050 simultanés | F-W02 | Deux appels P-08 sur le même numéro, entrelacés |
| E-08 | Réception P-08 refusée par la base | F-W08 | Déclencheur de banc qui fait échouer l'insertion ; rien ne doit rester à moitié écrit |
| E-09 | Changement du numéro d'un compte consentant | F-C04, T-18 | Le consentement ne suit pas le nouveau numéro ; aucune demande ouverte ne survit |

**Écrits le 24/11/2026** dans `outils/essais-services/essai-communication-concurrence.py`
(sessions PostgreSQL réellement simultanées, lancé par la CI) : **E-01**, **E-03** (durées mesurées
sous charge : demande 0,006 s, confirmation en attente 3,0 s, confirmation finale 0,008 s),
**E-07** (le même STOP reçu deux fois, puis deux travailleurs), **E-09**, ainsi que la course entre
une demande d'arrêt et une levée, et les demandes de code WhatsApp simultanées (Q5). 27/27, stable
sur trois passages. Restent : E-02, E-04, E-05, E-06, E-08.

Pour E-01, E-02 et E-07, la revue dira si un ordonnanceur dédié (`isolationtester`, fourni avec les
sources de PostgreSQL) est nécessaire.

## 5. Ce qui ne peut pas être prouvé en local

- **pg_net réel** (F-K05, F-K09, H4, H4′) : moment où une requête quitte la file, délai, absence de
  nouvel essai automatique. Exige une stack Supabase locale avec pg_net, sur autorisation écrite.
- **PostgREST et délais de Supabase** (Q1, Q7) : annulation quand le client se déconnecte, délais réels
  des rôles. PostgREST 12.2.3 local permet une partie (déjà utilisé par `essai-mobile.py`).
- **Durabilité** (`synchronous_commit`, réplication, restauration chez Supabase) : question de la revue
  (Q7) et de l'hébergeur.
- **Fournisseurs** (Meta, Brevo, Expo) : formats réels des réponses et des retours. Aucun contact sans
  autorisation et comptes ouverts par la CEO.
- **Validations juridiques** (D2, STOP, conservation) : hors essais.

## 6. Ordre proposé

1. E-05 et E-06 (inventaires figés : ils protègent tout le reste contre une dérive silencieuse).
2. E-01, E-02, E-07 (concurrence ; à confirmer avec la revue).
3. E-03, E-08, E-09.
4. E-04, après la décision sur le retour arrière.
5. F-K05 et F-K09 sur stack Supabase locale, sur autorisation.
