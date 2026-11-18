# GoShip Express — Communication Center
# COMMUNICATION_CENTER_DATABASE.md — Phase 1

| | |
|---|---|
| Date | 18 November 2026 |
| Status | **Design + guarded drafts. Nothing executed on any database (production, staging or throwaway).** |
| Drafts | `brouillons-sql/40-supabase-communications-fondation.sql`, `41-…-consentement.sql`, `42-…-campagnes.sql`, `43-…-envoi.sql` — each starts with `raise exception 'BROUILLON NON APPROUVÉ…'`, so an accidental run in the SQL Editor aborts before any statement applies |

---

## 1. Placement in the migration chain

| # | Future file (Phase 2) | Draft | Depends on |
|---|---|---|---|
| 40 | `outils/supabase-communications-fondation.sql` | `40-…` | whole chain 1–39 (`telephone_international`, `lire_reglage`, `auditer` with motif, `erreur_metier`, pgcrypto in `extensions`) |
| 41 | `outils/supabase-communications-consentement.sql` | `41-…` | 40 |
| 42 | `outils/supabase-communications-campagnes.sql` | `42-…` | 41, `adresse_miami()` |
| 43 | `outils/supabase-communications-envoi.sql` | `43-…` | 42, `courriel_gabarit` (latest: `supabase-courriel-reseaux.sql`), `html_echappe`, pg_net, pg_cron |

Numbers are provisional: if the AI Command Center (PR #48) is approved first, the CEO decides the order
(both edit `permissions_du_role`). Rules kept from the project: replayable (`if not exists`, `on conflict
do nothing`, `create or replace`), no deletion, settings already tuned by the team never reset on replay,
a control query at the end of each file (Phase 2), entry in `outils/migrations.txt`, `README.md`,
`CLAUDE.md`, `docs/production/database.md`, `controle-securite.sql`, `sonder.sh` witness function.

**Existing objects touched — complete list:**
1. `permissions_du_role(text)` — redefined with 7 new permissions; existing entries byte-identical
   (also to be updated in `supabase.sql`, which is authoritative, and `PERMISSIONS_DES_ROLES` in `api.js`).
2. `clients` — one new `AFTER UPDATE OF email, telephone, pays, supprime_le` trigger
   (`communication_suivre_client`), which catches its own errors and never blocks the update.
Nothing else: no column added to an existing table, no existing function redefined, no RLS policy
changed, no existing cron job changed.

---

## 2. Entities

| Table | Purpose | Key constraints | Access |
|---|---|---|---|
| `communication_reglages` | Single row: master switch, mode (`essai`/`production`), channel switches, global daily caps (USD, messages), Brevo quota/reserve, batch, quiet hours, frequency caps, yield threshold, four-eyes, postal address (D-G), Miami-address validation flag (D-H) | `id boolean pk check(id)`; all switches false, caps 0, mode `essai` | via functions only |
| `communication_textes_consentement` | Versioned consent texts per channel × language; counsel approval reference | pk (version, canal, langue); approved ⇒ reference + approver | functions only |
| `communication_consentements` | **Immutable** ledger of grants and withdrawals with evidence | grant ⇒ text version + text hash + target hash; grant ⇒ source ∈ {compte_web, application}; no FK to `clients` (survives account deletion); update/delete trigger-refused | functions only |
| `communication_suppressions` | Do-not-contact list by target hash (unsubscribe, STOP, hard bounce, complaint, invalid number, manual) | unique active (canal, cible_empreinte); lift needs reason | functions only |
| `communication_destinataires_essai` | Server-enforced test allowlist | pk (client, canal); reason mandatory; customer only if consented | functions only |
| `communication_tarifs` | Estimated unit cost per provider/channel/category/country; `autorise` (e.g. US marketing paused); **verified** flag | pk (fournisseur, canal, categorie, pays); seeded `verifie = false` | functions only |
| `communication_depenses_jour` | Spend ledger per day/provider/channel (messages, USD) | pk (jour, fournisseur, canal); locked during reservation | functions only |
| `communication_modeles` | E-mail / WhatsApp templates per language, versioned; Meta name, language, category, Meta status | approved ⇒ frozen (trigger); WA fields required for WA | functions only |
| `communication_segments` | Saved closed-list criteria | criteria validated by function | functions only |
| `communication_campagnes` | Campaign, status, channels, criteria copy, template map, schedule, caps, fingerprints, approval, reservations | status check (8 states); caps ≥ 0 | functions only |
| `communication_destinataires` | Audience frozen at launch (retained / excluded + reason) | unique (campagne, client, canal) | functions only |
| `communication_envois` | Marketing queue (10 statuses incl. dead letter `abandon`) | unique `cle`; partial indexes for due / processing | functions only |
| `communication_evenements_fournisseur` | **Immutable** provider events (delivery, read, bounce, complaint, inbound) — codes only | unique (fournisseur, evenement_id) = replay protection | functions only |
| `communication_fenetres_whatsapp` | Last inbound per hashed number (24 h service window) | pk cible_empreinte | functions only |

All: `enable row level security`, **no policy**, `revoke all from anon, authenticated` — the same
"closed table" pattern as `notification_envois`, `profils_document`, `suivis_externes`.

Planned in Phase 2 (not drafted yet): `communication_automatisations` (marketing automations with their
own approval fingerprint), list/detail read functions for the UI, template/segment write functions,
test-send function, dead-letter relaunch, statistics, retention purge job, Brevo polling for marketing
e-mails (if the Edge Function comes later).

---

## 3. State machines

**Campaign** `communication_campagnes.statut`: `brouillon → en_attente_approbation → programmee →
en_cours → terminee`, plus `en_pause`, `annulee`, `echec`. Single entry point
`changer_statut_campagne(campagne, action, motif)` with actions `soumettre`, `retirer`, `approuver`,
`refuser`, `remettre_en_brouillon`, `mettre_en_pause`, `reprendre`, `annuler`; the worker performs
`programmee → en_cours` (launch), `en_cours → terminee`, and pauses on `EMPREINTE_CHANGEE`,
`MODELE_INDISPONIBLE`, `PLAFOND_CAMPAGNE_*`. Every transition is journaled (`journal_audit`,
`communication.campagne_<action>`, before/after status, reason).

**Message** `communication_envois.statut`: `attente`, `traitement`, `envoye`, `livre`, `lu`, `echec`,
`nouvel_essai`, `supprime`, `annule`, `abandon` (mapping to the master plan: Pending, Processing, Sent,
Delivered, Read, Failed, Retrying, Suppressed; plus Cancelled and Dead-letter).

**Consent**: no row = not consented; latest row decides, and only if its target hash equals the hash of
the customer's current address/number.

**Template**: `brouillon → soumis → approuve → archive`; Meta status tracked separately
(`inconnu`, `approuve`, `rejete`, `en_pause`, `desactive`).

---

## 4. Function inventory

| Function | Kind | Exposed to | Permission / guard |
|---|---|---|---|
| `permissions_du_role` | matrix | (internal, existing) | — |
| `communication_jour`, `_empreinte`, `_cible`, `_pays_numero`, `_consentement_actuel`, `_supprimee`, `_est_essai`, `_brevo_disponible` | helpers | nobody | — |
| `mes_consentements_communication(langue)` | customer read | authenticated | own row, role `client` |
| `regler_mon_consentement_communication(canal, accorde, version, langue, source)` | customer write | authenticated | own row; grant needs approved text version |
| `consentements_client(client)` | staff read | authenticated | `communications.consents` |
| `retirer_consentement_client(client, canal, motif)` | staff write (withdraw only) | authenticated | `communications.consents`, reason |
| `ecrire_texte_consentement`, `approuver_texte_consentement` | admin | authenticated | `communications.manage`, counsel reference |
| `regler_communications(champs, motif)` | admin | authenticated | `communications.manage`, whitelisted fields, reason; production+email ⇒ postal address; email ⇒ verified quota |
| `valider_adresse_postale`, `verifier_tarif_communication`, `regler_destinataire_essai`, `lever_suppression_communication` | admin | authenticated | `communications.manage`, reason |
| `communication_variables_du_texte`, `_variables_permises`, `_rendre` | templates | nobody | — |
| `communication_criteres_valides`, `_segment_clients`, `_raison_exclusion` | audience | nobody | — |
| `apercu_audience_communication(criteres, canaux)` | read (counts) | authenticated | `communications.view` |
| `ecrire_campagne_communication(campagne, champs)` | draft write | authenticated | `communications.create`, draft only |
| `communication_empreinte_campagne`, `communication_manques` | approval support | nobody | — |
| `changer_statut_campagne(campagne, action, motif)` | transitions | authenticated | per action (see SECURITY §2.2) |
| `communication_fuseau`, `_prochaine_fenetre`, `_frequence_atteinte`, `_reserver` | send rules | nobody | — |
| `communication_jeton_desinscription`, `_appel_email`, `_appel_whatsapp`, `_textes_pied`, `_lire_reponse` | provider layer | nobody | — |
| `traiter_communications()` | worker | pg_cron only | job `goship-communications`, **inactive** at creation |
| `communication_est_stop` | inbound | nobody | — |
| `communication_recevoir_evenement(fournisseur, charge, signature)` | webhook ingestion | **anon** | HMAC over raw payload with Vault key; replay table; ≤ 24 h |
| `desinscrire_communication(jeton)` | unsubscribe | **anon**, authenticated | HMAC token; idempotent; returns no PII |
| `sante_communications()` | health | authenticated | `communications.view` |

The two anon functions must be added to `ouvertes_attendues` in `controle-securite.sql` (section 6).

---

## 5. Concurrency, idempotency and limits

- Queue claims: `for update skip locked` (same proven pattern as `traiter_notifications`).
- Launch: one due campaign per pass, row-locked; audience insert `on conflict do nothing`.
- Spend reservation: campaign row `for update` + all of today's spend rows `for update` → serialised
  check-and-increment; global and campaign caps can't be exceeded by parallel workers.
- Idempotency: `cle = campagne:<uuid>:<client>:<canal>` unique; provider events unique per provider id.
- Unknown outcome (network error / no response in 10 min) → `echec ISSUE_INCONNUE`, never retried.

---

## 6. Indexes

`communication_consentements (client_id, canal, cree_le desc, id desc)`;
`communication_suppressions (canal, cible_empreinte) where leve_le is null` (unique);
`communication_campagnes (planifiee_le) where statut = 'programmee'`;
`communication_envois (prochain_essai_le) where statut in ('attente','nouvel_essai')`,
`(verrouille_le) where statut = 'traitement'`, `(fournisseur, message_id)`, `(client_id, envoye_le desc)`.
Every foreign key gets an index in Phase 2 (lesson of `supabase-index-cles.sql`).

---

## 7. Retention (to confirm with counsel ⚖️)

| Data | Proposed retention |
|---|---|
| Consent ledger, consent texts | Indefinite (proof of consent/withdrawal) |
| Suppressions | Indefinite (hash only) |
| Marketing queue and frozen audiences | 24 months, then aggregated statistics only |
| Provider events | 90 days |
| WhatsApp 24 h windows | 7 days |
| Transactional tables | unchanged (existing 180-day purge of finished deliveries) |

Purge job (Phase 2) must respect the immutability triggers by deleting only through a dedicated
`security definer` function that is the sole exception, journaled — or by keeping provider events
indefinitely if counsel prefers (decision).

---

## 8. Validation plan for the drafts (first task of Phase 2)

The drafts are **unvalidated by design** (no execution in Phase 1). Known review points to settle when
they are first run on the throwaway harness:

1. Replace the `BROUILLON` guard with the standard prerequisite guard.
2. Copy `permissions_du_role` into `supabase.sql` (authoritative) and `api.js`; extend `essai-permissions`.
3. `apercu_audience_communication` aggregation (duplicate-key aggregation to simplify).
4. `traiter_communications` launch query (lateral rendering check) — measure on 10,000 synthetic clients.
5. Edge-to-SQL signature canonicalisation (raw text) — fixture tests with Meta/Brevo payloads.
6. `communication_brevo_disponible` monthly arithmetic and Auth estimate (lower bound) — property tests.
7. Grant/withdraw trigger on `clients` — prove it never blocks `supprimer_mon_compte`, profile edits,
   or Google sign-up profile creation (`essai-mobile.py` sections K, L).
8. Control query and `sonder.sh` witness per file.
