# La double authentification de l'équipe

Mise en place au lot 1 du contrôle qualité (16/11/2026, `outils/supabase-double-auth.sql`,
migration 36). Gratuit : c'est la double authentification de Supabase Auth (TOTP).

## Ce qui change pour l'équipe

- **Activer** : le tableau de bord affiche « Protégez votre compte » à tout compte de l'équipe
  qui ne l'a pas activée. « Activer » ouvre une fenêtre : installer Google Authenticator ou
  Microsoft Authenticator, scanner le QR code (ou taper la clé), taper le premier code. Aussi
  dans Réglages > Mon compte > « Inscrire un appareil » (un second téléphone, par exemple).
- **Se connecter** : e-mail et mot de passe, puis le code à 6 chiffres de l'application.
- **La règle est dans la base** : un compte de l'équipe qui a un appareil n'a **aucune**
  permission de l'équipe tant que la session n'a pas donné le code. Un mot de passe volé ne
  suffit plus, même en appelant la base directement.
- Les clients (site, application mobile) ne voient rien de nouveau.
- L'onglet Équipe montre, pour chacun, « Double authentification » ou « Mot de passe seul ».

## L'ordre recommandé

1. Les trois administrateurs activent la leur (et, idéalement, inscrivent un second appareil).
2. Puis gérants et employés.
3. Quand l'onglet Équipe ne montre plus de « Mot de passe seul », un administrateur, connecté
   avec son code, clique « Rendre obligatoire pour l'équipe » (onglet Équipe) et donne un motif
   (gardé au journal, `double_auth.reglage`). Un compte de l'équipe sans appareil doit alors en
   inscrire un avant d'entrer. Même bouton pour revenir en arrière (« Ne plus l'exiger »).

## Téléphone perdu ou changé

Le propriétaire du projet Supabase : Authentication > Users > le compte > section
« Multi-factor authentication » > supprimer l'appareil. La personne se reconnecte avec son mot
de passe (le tableau de bord ne demande plus de code, ou, si la double authentification est
obligatoire, lui propose d'inscrire son nouveau téléphone). Un second appareil inscrit à
l'avance évite cette étape.

## Vérifier

- `select public.ma_double_auth();` (connecté) : `code_requis`, `active`, `session`.
- Contrôle de la migration : `4 | f | f | t`.
- Supabase > Authentication > Multi-Factor : TOTP doit être activé (il l'est par défaut).
- Banc : `outils/essais-services/essai-double-auth.py` (règle, rôle par rôle),
  `essai-double-auth-navigateur.mjs` (écrans).
