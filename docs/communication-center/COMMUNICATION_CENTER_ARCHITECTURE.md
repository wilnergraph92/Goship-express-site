# GoShip Express — Communication Center
# COMMUNICATION_CENTER_ARCHITECTURE.md — Phase 1 (Architecture & Security Design)

| | |
|---|---|
| Date | 18 November 2026 |
| Status | **Design for CEO approval. Nothing implemented, executed, activated or deployed.** |
| Companion documents | `COMMUNICATION_CENTER_SECURITY.md`, `COMMUNICATION_CENTER_DATABASE.md`, `brouillons-sql/40…43` (guarded drafts, never executed), `COMMUNICATION_CENTER_PHASE_0_AUDIT.md` |
| Inputs | Approved Phase 0 audit; CEO decisions D-A … D-J and additional requirements 1–10 (18/11/2026) |

---

## 1. Design principles (binding for Phases 2–7)

1. **Two lanes, never mixed.** Transactional (existing engine, unchanged) and marketing (new) have
   separate tables, queues, workers, priorities, consent models and feeds. A marketing message is never
   written to `notifications`, `notification_envois`, `mon_resume` or `messages_recents` (D-E).
2. **The existing transactional behaviour is preserved byte for byte.** No existing function, table,
   trigger, rule, cron job or API contract is modified. The only touch on an existing object is one
   *additional* `AFTER UPDATE` trigger on `clients` that can never block the write (§5.6), and the
   permission matrix gaining new entries.
3. **Everything decided in the database**, like the rest of GoShip: consent, eligibility, approval,
   spending, quotas, quiet hours. Pages only display and request; the database refuses on its own.
4. **Born off.** Every switch starts disabled, every limit starts at 0 (= blocked), the cron job is
   created inactive, mode starts at `essai` (test-allowlist only). Activation is a sequence of explicit,
   journaled admin actions, each gated by a CEO decision.
5. **Fail closed.** Unknown quota, unverified tariff, unapproved template, missing postal address,
   missing consent text, missing variable, unknown outcome of an API call → nothing is sent.
6. **Evidence is immutable.** Consent ledger, provider events, audit journal: append-only, enforced by
   triggers even against the SQL Editor.
7. **A duplicate is worse than a miss** for marketing: unknown outcomes are never retried automatically.

---

## 2. Updated architecture diagrams

### 2.1 Component view

```text
                    ┌───────────────────────── Supabase (production gpfdyslysqjmojgzggib) ─────────────────────────┐
 admin.html         │                                                                                               │
 "Communications"   │  PostgREST RPC (RLS + exiger_permission + aal2)                                               │
 tab (admin,gérant) ├──► campaign / template / segment / consent / settings functions  (communications.*)           │
                    │                                                                                               │
 mon-compte.html    │  ┌───────────── TRANSACTIONAL LANE (existing, unchanged) ─────────────┐                      │
 (+ app later)      │  │ colis_historique / evenements_facturation / scheduler              │                      │
 consent toggles ───┼─►│   → notification_regles → notifications ('app' feed, mobile)       │                      │
 (own data only)    │  │   → notification_envois → traiter_notifications()  [goship-notif…] │──┐                   │
                    │  │ welcome e-mails (courriels_bienvenue)                              │  │                   │
 desinscription     │  └────────────────────────────────────────────────────────────────────┘  │ pg_net            │
 .html (public) ────┼─► desinscrire_communication(token)  [anon, HMAC-verified]                 │                   │
                    │                                                                          ├──► Expo Push      │
                    │  ┌───────────── MARKETING LANE (new) ──────────────────────────────────┐ ├──► Brevo (e-mail) │
                    │  │ communication_reglages (switches, limits, mode, quotas)            │ │    + Supabase    │
                    │  │ communication_textes_consentement → communication_consentements    │ │      Auth SMTP   │
                    │  │ communication_suppressions · communication_destinataires_essai     │ ├──► Meta Cloud API │
                    │  │ communication_modeles · _segments · _campagnes (approval+fingerprint)│ │   (WhatsApp)     │
                    │  │ communication_destinataires (frozen audience)                      │ │                  │
                    │  │ communication_envois (queue) → traiter_communications()            │─┘                  │
                    │  │   [goship-communications, born INACTIVE, yields to transactional]  │                    │
                    │  │ communication_tarifs · communication_depenses_jour (spend ledger)  │                    │
                    │  │ communication_evenements_fournisseur (immutable) · fenêtres 24 h   │                    │
                    │  └────────────────────────────────────────────────────────────────────┘                    │
                    │            ▲ communication_recevoir_evenement(provider, raw, HMAC)  [anon, HMAC-verified]  │
                    │            │                                                                                │
                    │  Edge Function "communication-webhooks" (Phase 3, first Edge Function of the project):     │
                    │    verifies Meta X-Hub-Signature-256 / Brevo secret+IPs, re-signs, calls the RPC with the   │
                    │    PUBLISHABLE key — holds no key able to bypass RLS                                       │
                    └────────────────────────────────────────────────────────────────────────────────────────────┘
                                 ▲ webhooks                      ▲ one-click unsubscribe (RFC 8058 POST)
                          Meta (statuses, inbound, STOP)    Mailbox providers (Gmail, Yahoo…)
```

### 2.2 Campaign lifecycle (D-D)

```text
 gérant/admin: create ─► brouillon ─submit─► en_attente_approbation ─approve (ADMIN ONLY)─► programmee
                            ▲   ◄── withdraw / reject (reason) ──┘                           │ planifiee_le reached
                            └──────────── back to draft (before launch, clears approval) ────┤ + switches on
                                                                                              ▼ audience frozen
  annulee ◄─ cancel (draft/pending: creator perm; approved/running: ADMIN) ─  en_cours ──► terminee
                                                         en_pause ◄─ pause (gérant/admin) ─┘  ▲
                                                             └──── resume (ADMIN, fingerprint re-checked) ─┘
                                                         echec (launch impossible)
```

Approval binds a **SHA-256 fingerprint** of: channels, segment criteria (copied at submission),
fallback language, schedule, both spending caps, test flag, and every template's content fingerprint.
Any later change — including a new template version — invalidates it; the worker refuses to launch a
campaign whose fingerprint no longer matches (`EMPREINTE_CHANGEE` → paused).

### 2.3 Message lifecycle (marketing queue)

```text
 attente ──(eligibility re-check)──► supprime            (consent withdrawn, STOP, suppressed, off allowlist, missing variable)
    │ (quiet hours / frequency cap → postponed, stays attente)
    │ (spend/quota reservation refused → postponed to next day, or campaign paused if campaign cap)
    ▼
 traitement ──2xx──► envoye ──webhook──► livre ──webhook──► lu (WhatsApp only)
    │ 429/5xx (attempt < 3) ──► nouvel_essai ──(2 min, 10 min, 1 h)──► traitement
    │ 429/5xx (attempt = 3) ──► abandon   (dead-letter queue, visible, admin-relaunchable)
    │ 4xx / unknown outcome ──► echec     (never retried automatically)
 campaign cancelled before send ──► annule
```

### 2.4 Consent lifecycle (D-I)

```text
 (no row) = NOT consented ──customer ticks box with counsel-approved text vN──► accorde (vN, target hash, source, time)
      ▲                                                                          │
      └── retire ◄── customer unticks · unsubscribe link · WhatsApp STOP · complaint · staff on request
                     · e-mail/phone changed (target hash no longer matches) · account deleted
 Staff can NEVER record a grant. Lifting a suppression never restores consent.
```

---

## 3. CEO decisions — how the design implements them

| # | Decision | Implementation |
|---|---|---|
| D-A | Throwaway PostgreSQL + provider sandboxes, no Supabase Pro | §9 test & staging strategy; reassessment checkpoint before Phase 7 |
| D-B | Investigate Coexistence, keep current number | §6.2 assessment; no migration/disconnection anywhere in the plan |
| D-C | Verify Brevo plan, quota, Auth usage; protect Auth e-mails | §6.3; measured usage; `communication_brevo_disponible()` reserve; e-mail marketing blocked until quota is verified |
| D-D | Gérant creates/edits/schedules; admin approval mandatory | `communications.approve` admin-only; worker launches only approved + fingerprint-matching campaigns |
| D-E | Marketing separate from mobile transactional feed; API contracts preserved | Separate tables/queue; no write to `notifications`; no change to any RPC used by the app |
| D-F | Consent & privacy requirements for DR, HT, US; flag counsel wording | `SECURITY.md` §5; DB refuses consent capture until a text is marked counsel-approved with a reference |
| D-G | Postal address pending, do not invent | `adresse_postale` null → e-mail marketing cannot go to production; §7.1 lists what the CEO must confirm |
| D-H | Miami address pending; identify authoritative source; change nothing | §7.2; `{{adresse_miami}}` variable refused until `adresse_miami_validee` |
| D-I | Opt-in via customer account; default no consent | `mes_consentements_communication` / `regler_mon_consentement_communication`; no row = no consent; never pre-ticked |
| D-J | Inspect PRs #46, #48; do not merge/modify | §8 |

Additional requirements 1–10 → see the traceability table in §12.

---

## 4. Queues, priorities and scheduling

| | Transactional (existing) | Marketing (new) |
|---|---|---|
| Queue table | `notification_envois` | `communication_envois` |
| Worker | `traiter_notifications()` | `traiter_communications()` |
| Cron job | `goship-notifications` (every minute) | `goship-communications` (every minute, **created inactive**) |
| Batch | 50 / pass | `lot_par_minute` = 20 / pass (setting) |
| Priority | Always first | **Yields**: if more than `attente_transactionnel_max` (50) transactional deliveries are due, the marketing pass sends nothing |
| Retry | 30 s, 2 min, 10 min, incl. network/no-response | 2 min, 10 min, 1 h; **only** 429/5xx; unknown outcome = `echec`, no retry |
| Dead letter | `echec` with `ABANDON_…` | `abandon` status + `messages_morts` health counter |
| Dedup | unique `notifications.cle`; unique (notification, canal, cible) | unique `cle` = `campagne:<id>:<client>:<canal>`; unique (campagne, client, canal) in the frozen audience |
| Concurrency | `for update skip locked` | same, plus campaign row lock during launch and spend reservation |

**Scheduling:** a campaign carries `planifiee_le`; the worker launches due, approved campaigns one per
pass (bounded work). **Quiet hours**: 09:00–19:00 in the recipient's local time (Haïti →
America/Port-au-Prince, DO → America/Santo_Domingo, US/unknown → America/New_York), messages outside the
window are postponed, not dropped. **Frequency cap**: max 1 marketing message per customer per 24 h and
2 per 7 days across channels (settings). All values to be confirmed by counsel (FTSA/TCPA).

**pg_net capacity:** marketing adds ≤ 20 HTTP calls/minute to the shared pg_net queue, well under its
throughput; the transactional lane remains dominant and first.

---

## 5. Component design

### 5.1 Provider abstraction
Marketing has its own adapter functions — `communication_appel_email` (Brevo or Resend per the existing
`email_fournisseur` setting) and `communication_appel_whatsapp` (Meta Cloud API) — and a shared response
reader. **`expedier_envoi` is not refactored** (Phase 0 suggested it; requirement 7 overrides: the
transactional path must not change). The campaign engine only knows `canal` + `fournisseur`; switching
Brevo↔Resend is a setting; a new provider = one adapter function + tariff rows + webhook mapping.
Marketing may use its **own sender and WhatsApp number** through optional Vault settings
(`communication_expediteur`, `communication_whatsapp_numero_id`), falling back to the transactional ones.

### 5.2 Spending limits (requirement 1)
Independent and cumulative, all checked **under row lock before** each provider call
(`communication_reserver`):
1. **Global daily** — `plafond_jour_usd` and `plafond_jour_messages` across all campaigns and channels
   (Santo Domingo calendar day), ledger `communication_depenses_jour`.
2. **Per campaign** — `plafond_cout_usd` and `plafond_messages`, approved as part of the fingerprint.
3. **Brevo quota** — §6.3.
Reaching a campaign cap pauses the campaign (`PLAFOND_CAMPAGNE_*`); reaching a global cap postpones
remaining messages to the next day 09:00. Estimates use **admin-verified** tariffs only; reservations are
never refunded (estimates stay ≥ actual cost: Meta bills delivered messages only).

### 5.3 Test-recipient allowlist (requirement 3)
`communication_destinataires_essai`, admin-managed (`communications.manage`, reason, journaled). Enforced
**server-side twice**: when the audience is frozen and immediately before each send
(`communication_raison_exclusion`). In mode `essai` (default) and for every campaign flagged `essai`,
nobody outside the list can receive. A customer can only be added if they personally consented on that
channel; team accounts receive tests by virtue of their job (reason recorded).

### 5.4 Templates and personalisation
Closed variable list that exists in the schema: `{{prenom}}` (first word of `nom_complet`),
`{{nom_complet}}`, `{{code}}`, `{{adresse_miami}}` (refused until D-H). E-mail and phone are deliberately
**not** offered (data minimisation; CEO can request). Optional author fallback `{{prenom|Bonjour}}`.
Missing value without fallback → recipient excluded at freeze time (`VARIABLE_MANQUANTE`) and re-checked
at send; a rendered text containing `{{` or `}}` is never sent. Template text is plain text, HTML-escaped
by the database. WhatsApp templates record the Meta name, Meta language code, category
(MARKETING/UTILITY) and Meta approval status; an approved template is frozen (new version on edit).

### 5.5 Segmentation
Closed criteria (no SQL from pages): registered within N days, without parcels, active within N days,
inactive for N days, parcels in transit, delivered parcels, countries, languages. Consent, suppression,
valid target, allowlist and US-marketing restriction are **always** added. Preview returns **counts
only** (eligible / excluded by reason). The audience is frozen **at launch** (so late withdrawals are
honoured) and re-checked per message.

### 5.6 Consent capture (D-I, requirement 4)
Customer account page (`mon-compte.html`, later the app): per channel, an **unticked** toggle with the
exact counsel-approved text. Granting stores text version + SHA-256 of the text + language + hash of the
target address + source + timestamp. Withdrawal is always one click. A trigger on `clients` records an
automatic withdrawal when the e-mail/phone changes or the account is deleted; it swallows its own errors
(never blocks the customer's write). Mobile app: same RPCs in a later app release; installed versions are
unaffected (they never call these functions).

### 5.7 Webhooks and inbound messages
One Edge Function (`communication-webhooks`, Deno, plain JS allowed, folder outside the published site —
`supabase/functions/` is not under the Pages publishing scope; `deploy.yml` must also exclude it).
Routes: `GET /meta` (hub.challenge verification with `META_VERIFY_TOKEN`), `POST /meta` (verify
`X-Hub-Signature-256` with `META_APP_SECRET` over the raw body), `POST /brevo` (secret token in URL +
Brevo IP ranges), `POST /desinscription` (RFC 8058 one-click). It normalises each event to
`{id, type, message_id, code, survenu_le[, telephone, texte]}`, signs the raw normalised text with
`communication_cle_webhook` (also stored in Vault), and calls `communication_recevoir_evenement` with the
**publishable** key. The SQL verifies the HMAC, rejects replays (unique provider event id) and events
older than 24 h, updates statuses, and on STOP / complaint / hard bounce / provider unsubscribe writes
suppression + consent withdrawal. Inbound message **bodies are never stored** (keyword check only);
only a hashed "last inbound" time is kept for the 24-hour service window. History sync offered by
Coexistence must be **declined** (data minimisation).

Until the Edge Function exists: e-mail tracking can reuse the polling approach already proven for
transactional Brevo e-mails (separate function, separate column), WhatsApp statuses stay `envoye`
(accepted ≠ delivered, shown as such), and the unsubscribe link works through the public page + RPC.

### 5.8 Admin interface (Phase 4 outline)
New tab "Communications" in the "Gestion" group, `data-permission="communications.view"`, views per
master plan §8 (Overview, New campaign, Segments, Templates, WhatsApp, E-mail, Automations, Scheduled,
History, Analytics, Settings). "Automations" shows the **existing** `notification_regles` (transactional,
`settings.manage`, unchanged RPCs) and, separately, marketing automations. It also absorbs the screens of
closed PR #13 (delivery centre, rules, test) as read views over existing RPCs. Every label goes through
`tableau.txt` (4 languages); every `API.admin` method gets its demo implementation (read-only sample
data, sends refused); `admin.html` is edited in `outils/generateur/pages/`.

### 5.9 Monitoring
`sante_communications()` (switches, Brevo headroom today, today's spend, queue by status, dead letters,
stuck items, worker active); cron job named `goship-…` so `battement()` already reports its failures;
Phase 2 adds integrity lines to `controle-integrite.sql` (stuck > 15 min, dead letters, spend > 80 % of
cap, Brevo headroom < reserve) and the two anon RPCs to the `controle-securite.sql` whitelist.
Analytics never presents untracked data as zero: e-mail "read" = not tracked; WhatsApp "delivered/read"
= not tracked until the webhook is live.

### 5.10 Marketing automations (Phase 5)
Only marketing automations are new (e.g. inactive-customer reactivation). An automation is approved once
by an admin with its own caps and fingerprint; each run creates a campaign instance that inherits that
approval and is subject to all lane rules. Transactional automations (welcome, received, shipped,
available, delivered) **already exist** and are not rebuilt (Phase 0 conflict C1).

---

## 6. External provider assessments

### 6.1 Email — Brevo (keep) vs Resend
Brevo is already configured, domain-authenticated (DKIM via Brevo CNAMEs, DMARC `p=quarantine`, observed
18/11/2026) and tracked. **Keep Brevo** for marketing too (master plan: "use the existing provider if
suitable"); Resend stays a switchable alternative through the same adapter. Two points to verify in
Brevo's terms before activation: (a) marketing through the transactional API vs Brevo's campaign product
(the design keeps contacts in GoShip's database — no duplicate customer database at Brevo); (b) the
"Sent with Brevo" footer and limits on the free plan.

### 6.2 WhatsApp — Coexistence assessment (D-B)

| Topic | Finding (public sources, to confirm with Meta/partner) |
|---|---|
| What it is | The same number keeps working in the WhatsApp Business **app** while also connected to the **Cloud API**; app messages stay free, API messages are billed normally |
| Onboarding | Only through **Embedded Signup** run by a Meta **Tech Provider / Solution Partner** (BSP such as 360dialog, Telnyx, YCloud…), or GoShip registering itself as a Tech Provider (Meta app review + business verification; reported as hard to reverse) |
| Number requirements | WhatsApp Business app ≥ 2.24.17; number actively used in the app ≥ 7 days (GoShip's +1 849 538-6262 presumably qualifies — to confirm it is on the **Business** app, not the consumer app) |
| Operational constraints | The phone must open the app roughly every 13–14 days or the API link drops; reduced API throughput (sources say 5–20 msg/s, irrelevant at GoShip's volume); some app features don't sync (groups, labels, quick replies, catalog…); Cloud API calling unavailable |
| History sync | Optional import of past chats/contacts within 24 h of onboarding — **recommend declining** (data minimisation) |
| Risk to current operations | Low if onboarding is done by an experienced partner; the number is **not** migrated or disconnected. Mis-handled onboarding is the main risk → do it with a partner, outside business hours, with rollback = disconnect the API link (app keeps working) |

**Market reality that affects value, independent of Coexistence:** Meta has **paused delivery of
marketing templates to US numbers (+1, US area codes) since 01/04/2025** (still reported active in
November 2026). Sources disagree on whether all +1 numbers are affected; **Dominican numbers are also +1
(809/829/849)** — if Meta applies the pause by country code, WhatsApp marketing would reach only Haitian
customers (37 of 69 today). The design already encodes this (`autorise = false` for US; DO to be verified
before activation). Utility templates are unaffected.

**Recommendation:** pursue Coexistence through a **BSP/Tech Provider** (obtain 2–3 quotes; check fees,
data-processing terms, region support, history-sync opt-out). Fallback if unsuitable: a **dedicated
GoShip marketing number** on the Cloud API directly (no BSP needed), which also gives marketing its own
quality rating and keeps the support number's reputation isolated. Both options remain compatible with the
design (`communication_whatsapp_numero_id`). No action before CEO approval.

### 6.3 Brevo quota and Supabase Auth protection (D-C, requirement 2)

**Measured (production, read-only, last 60 days):** busiest day 93 e-mails (28/09, launch), typically
< 25/day; each sign-up = 3 e-mails (Auth confirmation + welcome + Miami address); 28 Auth confirmations,
1 password reset; 136 welcome e-mails; 155 engine e-mails.
**Not verifiable from this environment:** the Brevo subscription tier and quota (requires the Brevo
dashboard, or an authorised read-only `GET /v3/account` call with the stored key — not done). Public
sources: free plan = **300 e-mails/day, shared by API and SMTP relay** (i.e. Auth + transactional +
marketing); Starter ≈ US$9/month for 5,000 e-mails/month (no daily cap; verify).

**Protection, in layers:**
1. E-mail marketing is **closed** until an admin records the verified quota (`brevo_quota_jour` /
   `brevo_quota_mois`, journaled, dated).
2. Marketing may only use `quota − reserve (150/day default) − Auth e-mails today − transactional
   e-mails today − marketing already reserved` — computed before every e-mail, under lock.
3. Monthly plans: the reserve is kept for every remaining day of the month.
4. Optional structural isolation (CEO choice, §10): move **Supabase Auth SMTP** to a separate sender
   service so marketing can never touch it, or upgrade Brevo so the shared limit is no longer binding.

**Action for the CEO:** Brevo > *My plan / Usage*: note plan name, daily and monthly limits, renewal
date; Supabase > Authentication > SMTP: confirm Brevo is the SMTP host (expected, per go-no-go 28/09).

---

## 7. Address decisions prepared for the CEO

### 7.1 D-G — postal address required in marketing e-mails (pending, nothing assumed)
US CAN-SPAM requires a **valid physical postal address** of the sender in every commercial e-mail: a
street address, a USPS-registered PO Box, or a private mailbox registered with a Commercial Mail
Receiving Agency. Please confirm:
1. Exact legal sender name (the site's structured data says "Goship Express LLC" — confirm).
2. An address **where GoShip actually receives mail** (street, unit/suite, city, state, ZIP).
3. Whether the Medley warehouse address is GoShip's own premises or a **third-party facility** (the
   "ABX-46780" account format suggests a forwarder's warehouse) — if third-party, it may not be a valid
   sender address; a PO Box or CMRA mailbox is a compliant alternative.
4. Whether DR/Haiti offices should also appear (optional, trust).
Recorded via `valider_adresse_postale(adresse, motif)` by an admin after your written confirmation.

### 7.2 D-H — Miami address: sources found and canonical proposal (nothing changed)

| Variant | Where | Content |
|---|---|---|
| **A. Customer receiving address** | `adresse_miami()` in `outils/supabase.sql` (comment: "fait foi"), copy in `supabase-naissance.sql`; `mon-compte.html` address table; `index.html` table; mobile `config.js`; welcome e-mail; `build.py` ("exactement comme Goship Express l'a fourni (19/10/2026)") | `8140 NW 74th Ave Unit 3` / **`ABX-46780`** / Medley / Florida / 33166 / United States / **786 525-2944** (+ customer name and code) |
| **B. Company address on public pages** | banner and footer of every page (`build.py` constants), JSON-LD `streetAddress` | `8140 NW 74th Ave, Unit 3, **Apt 46780**`, Medley, Florida 33166; company phone +1 849 538-6262 |
| C. Legacy e-mail footer text | `assets/js/notifications.js` (`PIED_ADRESSE`, manual WhatsApp/e-mail) | `8140 NW 74th Ave, Unit 3, Medley, FL 33166` (no suite) |
| D. App agency card | mobile `config.js` | `8140 NW 74th Ave Unit 3, Medley, FL 33166` |

**Authoritative source today:** variant A as encoded in `adresse_miami()` — it is the most recent data
explicitly provided by GoShip (19/10/2026) and declared authoritative in the code. **Proposal:** two
distinct concepts, one source each: (1) *customer receiving address* = `adresse_miami()` (database),
read by site, app and e-mails; (2) *company postal/contact address* = the D-G answer, stored once and
injected by `build.py`. Decide whether "Apt 46780" (B) and "ABX-46780" (A) are the same mailbox
identifier. Nothing is changed until you decide.

---

## 8. Open PRs (D-J) — inspected, not modified

| PR | Content | Conflicts with this project | Recommendation |
|---|---|---|---|
| **#46** "Meta Pixel" (open, base `3c4c51a`, ~30 commits behind `main`) | Adds `metaPixel` to `config.js`, Pixel loading in `mesure.js` (public pages only, no auto-config, blocked on URLs with non-ad parameters, GPC/DNT respected), CSP entries in `build.py`, a new privacy-policy section generated by `build.py` in 4 languages, 92 regenerated pages | (1) **Same files** we will need for the privacy-policy marketing section (`build.py` `confidentialite_*`, `confidentialite.html` × 4) → merge conflicts; (2) predates the 16/11 CSP/fonts change (`'self'` only) → needs rebase; (3) campaign links carrying `utm_*` will load the Pixel on landing pages — acceptable but must be disclosed in the privacy policy; (4) no customer data or messaging overlap | Decide #46 **before** Phase 2's privacy-policy work; if kept, rebase it first so the marketing section is written on top. No functional dependency |
| **#48** "AI Command Center — Phase 0 audit" (open draft, document only) | Plans `ia_*` tables, an Edge Function gateway holding the Claude API key, permission `ia.commander`, a migration in the chain, the rule "no message sent to a customer by AI", approval fingerprints | (1) Both projects append migrations at the end of the chain and both edit `permissions_du_role` (3 SQL copies + `api.js`) → **sequence them**, never in parallel; (2) both introduce the **first Edge Function** → agree one convention (folder, deploy workflow, secrets doc, `deploy.yml` exclusion); (3) its "Customer Service" agent must never be given any `communications.*` sending function — compatible with its own rule; (4) the 9 helper functions it found executable by `anon` are unrelated but worth the same hygiene | Treat as a **sequencing** dependency only. If both proceed, the Communication Center migrations take numbers 40–43 and the AI ones follow (or vice versa), decided by the CEO |

---

## 9. Testing and staging strategy (D-A)

| Layer | How, without Supabase Pro |
|---|---|
| Database logic | New `outils/essais-services/essai-communications.py` on the **existing throwaway-PostgreSQL harness** (whole chain 1→43, doubles for `auth`, `vault`, `net`, `cron`): permissions per role, consent ledger immutability, fingerprint, allowlist, caps under 4 concurrent workers, Brevo reserve arithmetic, quiet hours, frequency, STOP, unsubscribe token, webhook HMAC + replay, idempotency, and **regression: the transactional engine's outputs are identical before/after** (`essai-notifications.py` unchanged and green) |
| Demo copy | `essai-communications.js` for the `api.js` demo implementation (read-only, sends refused) |
| Browser | `essai-communications-navigateur.mjs` (Playwright, demo mode, empty `config.js`, Supabase calls blocked) |
| E-mail provider | Brevo with sandbox header (`X-Sib-Sandbox: drop`) — accepted, never delivered; then live tests only to the allowlist after CEO authorisation |
| WhatsApp provider | Meta **test number** + up to 5 registered test recipients (Meta's own sandbox); production number only after Coexistence decision and CEO authorisation |
| Edge Function | Local `supabase functions serve` with recorded Meta/Brevo payloads and signature fixtures |
| Staging reassessment | Before Phase 7: decide whether a real staging project is required (Pro ~US$25/month, or pausing Speed Express to free a free-tier slot) |

---

## 10. Provider cost analysis (requirement 10) — **no paid activation proposed in this phase**

All figures are public list prices observed 18/11/2026 from secondary sources; **each must be confirmed
on the provider's official page before any purchase**. They are entered in `communication_tarifs` as
`verifie = false` and block sending until an admin verifies them.

| Item | Unit price | Today | When it would become paid |
|---|---|---|---|
| Supabase | Free; Pro US$25/month | Free | Only if a staging project/branching or PITR is decided |
| Supabase Edge Functions | Included (free tier: 500k invocations/month) | none deployed | Not expected at GoShip volume |
| Brevo | Free 300 e-mails/day; Starter ≈ US$9/month (5k e-mails/month) | Free assumed — **unverified** | When marketing + Auth + transactional approach the daily cap |
| Resend (alternative) | Free 3,000/month (100/day); Pro ≈ US$20/month | unused | Only if chosen for marketing or Auth isolation |
| Meta WhatsApp — marketing | ≈ US$0.074 per delivered message (HT, DO: "Rest of Latin America"); US ≈ 0.025 but **not delivered** (pause) | not configured | Per message, only after activation |
| Meta WhatsApp — utility | ≈ US$0.0113 (HT/DO), ≈ US$0.0034–0.004 (US); free inside the 24 h window | not configured | Not used by marketing |
| BSP / Tech Provider (Coexistence) | Varies: from markup-only to a monthly platform fee — **quote required** | — | If Coexistence chosen |
| Dedicated number (fallback) | Low monthly cost for a number able to receive verification — **quote required** | — | If Coexistence rejected |
| Legal counsel (US/FL, DR, HT) | One-off, quote required | — | Before consent capture goes live (required) |
| Apple Developer (iOS consent screen/push) | US$99/year | missing | Only for iOS |

**Scenario (illustrative, today's base):** 69 customers; suppose 50 % opt in per channel.
WhatsApp: ≈ 19 Haitian recipients reachable (+ ≈ 9 Dominican if not affected by the +1 pause) × 2
campaigns/month × US$0.074 ≈ **US$2.8–4.1/month**. E-mail: ≈ 35 × 2 = 70 e-mails/month → within free
tier. At 1,000 customers with the same assumptions: WhatsApp ≈ US$40–60/month, e-mail ≈ 1,000/month
(free tier insufficient on campaign days → Starter). The spending caps bound every scenario regardless.

---

## 11. Rollback and recovery (requirement 9)

| Situation | Action | Effect on existing operations |
|---|---|---|
| Stop all marketing immediately | `regler_communications({"campagnes_actives": false}, motif)` (admin, journaled) — the worker still reads pending responses, sends nothing | None |
| Stop one channel | `email_actif` / `whatsapp_actif` = false (queued items wait, nothing lost) | None |
| Stop one campaign | pause (gérant/admin) or cancel (admin) — unsent items → `annule` | None |
| Stop the worker | `cron.alter_job(<id>, active := false)` | None |
| Bad migration in Phase 2 | Migrations are **additive only** (new tables/functions, one non-blocking trigger, permission entries). Rollback = switches off + worker off; then a reviewed "retreat" script drops the new trigger and restores `permissions_du_role` from `supabase.sql`; tables kept (evidence) | Transactional untouched by design; verified by regression bench |
| Site/UI regression | `git revert` + republication (proven path) | Site only |
| Provider incident (Brevo/Meta) | Temporary errors → retry ≤ 3 then dead-letter; caps bound spend; transactional lane unaffected (separate queue) | None |
| Restore of the database from backup | Daily encrypted `pg_dump` includes all new tables. **Vault secrets are not restorable** into a new project: provider keys and `communication_cle_desinscription` / `communication_cle_webhook` must be re-entered; old unsubscribe links then fail → the page falls back to "log in to unsubscribe" + mailto; procedure added to `docs/production/disaster-recovery.md` in Phase 2 | Same as today for provider keys |
| Duplicate-send suspicion | Unique keys make a second send impossible for the same campaign/customer/channel; unknown outcomes are never retried | — |

---

## 12. Traceability — additional requirements 1–10

| # | Requirement | Where |
|---|---|---|
| 1 | Independent global daily and per-campaign spending limits | §5.2; `communication_reserver`, `communication_depenses_jour`, campaign caps in fingerprint |
| 2 | Protect Brevo authentication e-mail quota | §6.3; `communication_brevo_disponible` |
| 3 | Strict server-side test allowlist | §5.3; `communication_destinataires_essai`, `communication_raison_exclusion` (freeze + send) |
| 4 | Complete consent evidence and withdrawal history | §5.6; immutable `communication_consentements`, counsel-approved texts with fingerprint |
| 5 | Transactional and marketing strictly separated | §1, §4; separate tables, consent models, feeds |
| 6 | Independent queues and priorities | §4 |
| 7 | Preserve existing transactional behaviour | §1.2, §5.1 (no refactor of `expedier_envoi`), regression bench §9 |
| 8 | Exact permission matrix Admin/Gérant | `SECURITY.md` §2 |
| 9 | Rollback and recovery | §11 |
| 10 | External costs before paid activation | §10 |

---

## 13. Implementation roadmap (each step requires explicit CEO approval)

| Phase | Content | Exit criteria | Est. effort |
|---|---|---|---|
| **1** (this) | Architecture, security, database design; guarded SQL drafts | CEO approval | done |
| **2a** | Foundation + consent migrations (40, 41) on throwaway DB; permission matrix in `supabase.sql` + `api.js`; `essai-communications.py`/`.js`; regression of all existing benches | All benches green; no change in transactional outputs; migrations reviewed; **not executed in production** | 5–7 sessions |
| **2b** | Campaign + queue migrations (42, 43); worker with simulated providers; concurrency, caps, quiet hours, STOP, unsubscribe, webhook HMAC | Same | 6–8 sessions |
| **2c** | Customer consent UI (web, 4 languages) + privacy-policy section (after PR #46 decision) + `desinscription.html` | Counsel-approved wording received (D-F) | 3–4 sessions |
| **Prod-A** | Run 40–43 in production (backup verified first, `appliquer-chaine.sh`), everything OFF; consent capture opens only when texts are counsel-approved | CEO written GO | 1 session |
| **3** | Edge Function; Brevo sandbox; Meta test number; Coexistence via partner (or dedicated number) | CEO authorises live tests to allowlist only | 5–6 sessions + partner lead time |
| **4** | Communication Center UI (11 views, demo mode, translations) | Browser benches green | 7–9 sessions |
| **5** | Marketing automations (reactivation) | | 2–3 sessions |
| **6** | Analytics & monitoring (integrity checks, health) | | 2 sessions |
| **7** | QA A–M, staging reassessment, staged activation: test mode → first real campaign to a small consented group, caps at minimum | CEO GO at each stage | 3–4 sessions |

Mobile consent screen: separate repo, after 2c, EAS/store release; no impact on installed versions.

---

## 14. Decisions still needed from the CEO (to be answered before or during Phase 2)

1. **D-G** postal address (§7.1). 2. **D-H** canonical Miami address and whether Apt 46780 ≡ ABX-46780.
3. **Brevo plan** facts (§6.3) and whether to isolate Auth SMTP. 4. **Coexistence partner** quotes vs
dedicated number. 5. **Counsel** engagement for consent texts, privacy policy, quiet hours, STOP wording.
6. **Four-eyes** (`quatre_yeux`): may an admin approve a campaign they created? (default: allowed,
journaled). 7. **Template approval** by gérant? (design: gérant drafts, admin approves templates).
8. **Variables** `{{email}}` / `{{telephone}}` in marketing (design: excluded). 9. **Retention**:
marketing queue 24 months, provider events 90 days, consent ledger and suppressions kept indefinitely
(proof) — confirm with counsel. 10. **PR #46 / #48** sequencing.
