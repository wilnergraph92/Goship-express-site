# Communication Center — décisions prises par délégation de la CEO

## Source de la délégation

Le 23/11/2026, la CEO a écrit à Claude Code : « je vous autorise à continuer et prendre les
décisions nécessaires pour que le module de communication center de Goship express soit prêt et
entièrement opérationnel ».

## Portée retenue

`CLAUDE.md` et `AGENTS.md` demandent, pour chaque étape, une autorisation qui nomme son périmètre et
son environnement. La délégation est générale. Claude Code l'applique donc dans le cadre **le plus
restrictif compatible avec son objet**.

**Couvert par la délégation :**
- les décisions techniques et les réglages par défaut prudents ;
- le code et la documentation sur la branche de travail ;
- les essais sur des **bases locales jetables** (clusters PostgreSQL temporaires du banc), sans
  réseau et sans données réelles.

**Non couvert, chaque action exigeant une autorisation écrite qui la nomme :**
- toute action en **production** Supabase : migration, réglage, secret, Edge, `pg_cron` ;
- toute action auprès d'un **fournisseur** : Meta, Brevo, Resend, Expo ;
- tout **envoi réel** ;
- tout commit, push, merge ou déploiement ;
- l'exécution des brouillons 40–43.

**Hors de portée de tout agent :**
- la revue indépendante humaine PostgreSQL ;
- les validations juridiques ;
- les démarches de compte fournisseur (vérification d'entreprise Meta, approbation des modèles,
  domaine d'envoi). Ces démarches appartiennent à la CEO.

Ce document ne valide pas la Phase 1.3.1. Il fixe les choix qui permettent d'avancer la construction
locale.

---

## Décisions

| # | Sujet | Décision du 23/11/2026 | Raison | Réversible ? |
|---|---|---|---|---|
| A | Périmètre de la Phase 2 et objet de la revue | **Les candidates `outils/migrations-candidates/` deviennent la base de la Phase 2.** Les brouillons 40–43 deviennent une référence de conception ; ils ne seront jamais exécutés. Les fonctions qui leur manquent seront ajoutées en nouvelles candidates (010 et suivantes). La revue indépendante et le plan d'essais porteront sur les candidates. | Le cadrage du projet interdit un deuxième système d'envoi. Les brouillons créent une deuxième file (`communication_envois`) et un deuxième travailleur ; les candidates réutilisent `notification_envois` et le travailleur existant. Elles sont aussi les seules à avoir été éprouvées (`PHASE_1_3_1_CORRESPONDANCE_BROUILLONS_CANDIDATES.md`). | Oui, tant que rien n'est en production |
| A′ | Contrats transactionnels modifiés par les candidates 004 et 005 | **Acceptés**, à condition que les essais transactionnels existants (`essai-notifications.py`, `essai-accuses.py`, `essai-suivi-courriels.py`) passent sans régression avant toute intégration | Intégrer le Centre au moteur existant suppose de le modifier ; la non-régression remplace l'interdiction | Oui |
| B | S-1, identité Edge | **Option JWT ES256** de la candidate 009. Repli si l'offre Supabase n'accepte pas de clé de signature supplémentaire : rôle de connexion dédié (recommandation de la Phase 1.3). | Pas de mot de passe de base de données dans l'Edge ; moindre privilège ; option déjà éprouvée localement | Oui |
| C | Écran d'arrêt d'urgence | Demande, puis confirmation relancée automatiquement toutes les 5 s pendant 2 min au plus ; `STOP_PENDING` affiché avec sa raison. **Levée réservée à l'Admin**, avec un motif d'au moins 10 caractères et la version affichée (refus si l'état a changé). Nouvelle permission `communications.emergency_stop`, réservée à l'Admin. | Reprend la conception des brouillons (P-07, IR2-03) ; les candidates n'avaient ni levée ni accès Admin | Oui |
| D | Alertes | Alerte **immédiate** dans le tableau de bord, destinée aux Admins, pour : un retour prioritaire en échec (STOP, plainte, désinscription) ; un retour en attente depuis plus de 10 min ; `STOP_PENDING` depuis plus de 2 min ; une transmission `incertain`. Aucune alerte par e-mail ou WhatsApp tant que les fournisseurs ne sont pas validés. | Un retour prioritaire perdu peut cacher un STOP non appliqué | Oui |
| E | Les 78 essais | Ils visaient les brouillons. **Ils seront remplacés par un plan adapté aux candidates**, à exécuter sur des bases locales jetables (couvert par la délégation). | Décision A | Oui |
| F | Devis du spécialiste PostgreSQL | **Recommandé : l'envoyer** (D5 §6), sur la version figée des candidates, sous accord de confidentialité. **Action réservée à la CEO.** | Contact externe | — |
| G | `communications.view` dans la chaîne officielle | **Conservée**, et livrée avec la Phase 2 | Les candidates en dépendent ; la permission ne donne qu'un accès en lecture à la supervision | Oui |
| H1 | N-01, plafond de fréquence | Plafond par empreinte (déjà décidé), **plus** un plafond par compte, tous canaux confondus | Le plus restrictif | Oui |
| H2 | N-02, code WhatsApp | 6 chiffres, validité **60 min**, **5 erreurs** au plus (toutes les demandes ouvertes de l'empreinte sont alors annulées), limites répétées par compte et par empreinte | Valeurs analysées en D5 (risque de 1 sur 200 000) | Oui |
| H3 | D2, numéro partagé | Politique **`bloquer`** | Règle provisoire prudente ; validation juridique encore attendue | Oui |
| P-09 | Bouton « STOP » de WhatsApp | **Traité comme un retrait**, comme dans la candidate 006 | Un faux positif fait seulement perdre un destinataire ; un faux négatif ferait écrire à quelqu'un qui a refusé | Oui |
| K | **Décidée par la CEO le 23/11/2026 (« K : oui »)** — nouvel essai des notifications **transactionnelles** après une réponse 408, 425 ou 5xx, une erreur réseau, un délai dépassé ou un silence du fournisseur | Comme le moteur officiel en production : nouvel essai après 30 s puis 2 min, abandon (`ABANDON_HTTP_503`, `ABANDON_RESEAU`…) au maximum de tentatives (3 par défaut). Restent `incertain`, sans reprise automatique : une réponse 2xx sans identifiant de message (le fournisseur l'a sans doute acceptée) et les codes de confirmation WhatsApp (un second code invaliderait le premier). Le marketing n'emprunte pas encore l'outbox ; sa règle sera fixée en Phase 3. | Un « colis disponible » peut, rarement, arriver deux fois si le fournisseur avait accepté le message malgré la 5xx ; en échange, aucune notification n'est perdue pendant une panne. | Oui |
| R | Revue indépendante humaine | **Maintenue** comme condition avant la **production**. Elle ne bloque pas la construction locale. | Un agent ne peut ni lever ni remplacer le contrôle de son propre travail | — |
| J | Validations juridiques | **Maintenues** comme condition avant le **premier envoi marketing réel** | Hors de portée d'un agent | — |

## Suivi de mise en œuvre (local, bases jetables)

| Date | Décision | Réalisation | Preuve |
|---|---|---|---|
| 23/11/2026 | — | Banc de référence réexécuté par Claude Code : **438/438**. Le résultat déclaré par Codex est confirmé. | `essai-communication-center.py`, deux bases neuves |
| 23/11/2026 | C | Candidate `010-communication-arret-administration.sql` : permission `communications.emergency_stop`, RPC d'état, de demande, de confirmation et de levée | Banc : 25 essais C10 × 2 bases |
| 23/11/2026 | G | Ensemble `communications.*` aligné entre la chaîne officielle (`supabase.sql` et ses deux copies) et le miroir `api.js`. Cela corrige un défaut hérité : l'essai officiel `essai-permissions.py` échouait à 112/114. | `essai-permissions.py` : 114/114 |
| 23/11/2026 | — | **Correction de sécurité** : la transmission d'un code WhatsApp par l'Edge (009) contournait l'arrêt d'urgence ; elle passe désormais par la porte P-07 | Parcours C7.3 du banc (`--s1-only`) : 74/74 |
| 23/11/2026 | A | Hiérarchie des verrous des candidates documentée | `COMMUNICATION_CENTER_VERROUS_CANDIDATES.md` |
| 23/11/2026 | — | État après ces changements : banc complet **488/488** (dont les essais Node Edge et interface) ; `essai-programmes.py` 374/374 et `essai-suivi-externe.py` 80/80 (les copies de `permissions_du_role` sont identiques) | Bases locales jetables, sans réseau |
| 23/11/2026 | H2, H3, D | **C9** : candidate 011 (réglages décidés, sans écraser une valeur réglée) ; alertes `EVENEMENTS_EN_RETARD` et `ARRET_NON_CONFIRME` (007), traduites en 4 langues ; **correction** de la supervision (002), qui lisait une table et des statuts inexistants et ne pouvait jamais afficher de transmission en cours | Banc complet 510/510, parcours C7.3 74/74, interface Node 9/9 ; chaîne officielle : `essai-notifications` 87/87, `essai-accuses` 36/36, `essai-suivi-courriels` 49/49, `essai-permissions` 114/114 |
| 23/11/2026 | A′ | **Non-régression transactionnelle avec les candidates** (`essai-communication-non-regression.py`). Cinq régressions des candidates corrigées (004, 005) : une seule transmission par passage, soit un message par minute pour toute la plateforme ; travailleurs simultanés sur les mêmes lignes ; modèles d'anniversaire et de l'équipe ignorés (messages vides) ; langue de l'écran ignorée ; appareils Expo désinscrits conservés. Les 9 écarts restants relèvent tous de la **décision K** | 78/87 (le premier passage s'interrompait dès la section E, faute d'envois) |
| 23/11/2026 | K | **Décision K mise en œuvre** dans `lire_reponse_envoi` (005) : un résultat incertain dû à une 408, 425, 5xx, une erreur réseau ou un silence devient un échec temporaire, réessayé selon le calendrier officiel, avec les codes officiels (`HTTP_<code>`, `RESEAU`, puis `ABANDON_…`). Le classement des réponses (`communication_normaliser_reponse_canal`) ne change pas. Seul écart restant avec le moteur officiel, volontaire : une limite de débit s'appelle `LIMITE_DEBIT` (HTTP 429, Expo, WhatsApp) au lieu de `HTTP_429` ; le nouvel essai a lieu de la même façon, et aucun code ne dépend de ce nom | Banc **514/514** (dont trois essais K : silence, 503, abandon au 3e essai) ; parcours C7.3 74/74 ; non-régression **86/87** (l'écart restant est ce nom de code) |
| 23/11/2026 | A′ | **Non-régression étendue** (C10) : le harnais rejoue aussi `essai-accuses.py`, `essai-suivi-courriels.py` et `essai-programmes.py`, chacun dans son processus. Ces essais éprouvent une mise à niveau ; les candidates sont appliquées juste après le fichier concerné, jamais avant, pour ne pas changer l'état d'avant qu'ils observent, puis réappliquées après chaque fichier officiel rejoué. Le seul écart connu (`LIMITE_DEBIT`) est reconnu explicitement, limité à sa valeur exacte | notifications **87/87**, accusés **36/36**, suivi des courriels **49/49**, programmes **374/374** |

## Conditions de mise en service (rappel)

Le Centre ne pourra être déclaré **opérationnel** qu'après :
1. la construction et les essais locaux complets ;
2. la revue indépendante humaine ;
3. les validations juridiques ;
4. la configuration des fournisseurs par la CEO ;
5. une autorisation écrite de déploiement en production, qui nomme la cible, la fenêtre et le retour
   arrière.
