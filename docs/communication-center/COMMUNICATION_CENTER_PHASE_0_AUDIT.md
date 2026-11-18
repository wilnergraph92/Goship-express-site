# GoShip Express — Communication Center
# PHASE 0 — Read-Only Technical Audit

| | |
|---|---|
| Date | 18 November 2026 |
| Scope | WhatsApp, e-mail, campaigns, automated messaging (master plan of 18/11/2026) |
| Mode | **Read-only.** No file, database, configuration, secret, environment variable or provider was modified. No message was sent. Nothing was deployed. |
| Status | **Awaiting CEO approval.** Phase 1 has not started. |

---

## 0. Executive summary

1. **GoShip already has a production-grade transactional messaging engine**, entirely inside PostgreSQL
   (`outils/supabase-notifications.sql` + 6 follow-up migrations): event → rule → notification → per-channel
   delivery → provider → status, with idempotency keys, `for update skip locked` workers, retries
   (30 s / 2 min / 10 min, 3 attempts), permanent-vs-temporary error classification, Vault-held keys,
   delivery confirmation for push (Expo receipts) and e-mail (Brevo events, polled). **The Communication
   Center must extend it, not duplicate it.**
2. **Five of the eight "suggested automations" in the master plan already run in production** (welcome
   e-mails, Miami address e-mail, parcel received, shipped, available, delivered). Building them again in a
   new engine would **send duplicate messages** — the most serious conflict found.
3. **Nothing marketing-related exists**: no marketing consent, no consent timestamp/source, no unsubscribe
   link, no suppression list, no STOP handling. The code explicitly reserves this:
   *"un futur envoi commercial aurait son propre consentement, jamais celui-ci"*. Consequence:
   **today the legally marketable audience is 0 of 69 customers.** Consent capture must ship (and collect)
   before any campaign can be sent.
4. **WhatsApp Cloud API is not configured in production** (no `whatsapp_jeton` / `whatsapp_numero_id` in
   Vault; all 83 WhatsApp deliveries to date are `annule / NON_CONFIGURE`). CEO decision D2 of 17/11/2026:
   "WhatsApp kept, to be configured later". WhatsApp marketing additionally **requires an inbound webhook**
   (STOP, 24-hour window, delivery/read status) → a **Supabase Edge Function**, of which there are **zero**
   today.
5. **E-mail is live on Brevo** with the domain authenticated (DKIM via Brevo CNAMEs, DMARC `p=quarantine`).
   But the same Brevo account also carries Supabase Auth mail (sign-up confirmation, password reset):
   **a campaign could exhaust the daily quota and block account e-mails** if the plan is the free tier.
6. **No staging environment exists**, and the Supabase organisation already holds its **2 free projects**
   (GoShip production + Speed Express). A safe staging strategy is proposed (§9, §13).
7. **The admin "Notifications" tab described in the docs does not exist in the code**: PR #13 was
   **closed without merge** on 26/10/2026. There is no admin UI for rules/delivery center, and **no customer
   UI to change notification channel preferences** (web or mobile), although the database functions exist.
8. Recommended architecture: **one engine, two lanes** — keep the transactional lane as is; add a
   marketing/campaign lane (consent, suppression, audience snapshot, its own queue and lower-priority
   worker) that **reuses the same provider adapters** (refactored out of `expedier_envoi`), plus **one Edge
   Function** for provider webhooks and one-click unsubscribe.

---

## 1. Existing architecture diagram

```text
     Customers (browser)       Team (browser / Electron desktop)      Customers (Expo app, Android/iOS)
            │                              │                                      │
  Static site, no build          admin.html (dashboard)                 goship-express-app (separate repo)
  GitHub Pages + Hostinger       desktop = window on admin.html         old versions stay in service:
  (goshipexpress.net)            of the live site                       RPC names/shapes are frozen
            │                              │                                      │
            └──────────────── HTTPS, publishable key + user JWT ─────────────────┘
                                           ▼
            Supabase project gpfdyslysqjmojgzggib (us-east-2, Postgres 17, FREE plan)
     ┌──────────┬──────────────────┬───────────┬──────────┬───────────────────────────────┐
     │ Auth     │ PostgREST (RLS,  │ Realtime  │ Storage  │ Edge Functions: NONE deployed │
     │ (SMTP =  │ ~200 RPC funcs)  │           │ (logo)   │                               │
     │ Brevo)   │                  │           │          │                               │
     └──────────┴────────┬─────────┴───────────┴──────────┴───────────────────────────────┘
                         ▼
     PostgreSQL = ALL business rules (39 migrations, outils/migrations.txt)
       colis · colis_historique (event engine) · factures · paiements · permissions (peut/exiger_permission)
       notifications engine:  triggers on colis_historique + evenements_facturation
                              → notifications (canal 'app') → notification_envois (push/email/whatsapp/sms)
       programmes: birthdays, Welcome, Refer, GOPOINTS (also emit notifications)
       suivi externe (17TRACK) → carrier_* notifications
       Vault: provider keys (definir_reglage / lire_reglage)
                         │ pg_cron (9 jobs) + pg_net (async HTTP)
                         ▼
     Providers: Expo Push (live) · Brevo e-mail (live) · Resend (code path, unused)
                Meta WhatsApp Cloud API (code path, NOT configured) · 17TRACK · Healthchecks.io
```

Delivery state machine (`notification_envois.statut`):
`attente → envoi → envoye → livre` · `echec` · `annule` (with reason codes `NON_CONFIGURE`, `PREFERENCE`,
`SANS_APPAREIL`, `SANS_DESTINATAIRE`, `SANS_MODELE`, `REGLE_COUPEE`).
`envoye` = accepted by the provider (not delivered); `livre` = provider-confirmed delivery.

---

## 2. Repository and module inventory

### 2.1 Repositories

| Repository | Role | Inspected |
|---|---|---|
| `wilnergraph92/Goship-express-site` | Public site, customer area, admin dashboard, all SQL migrations, CI, production tooling, desktop shell (`bureau/`) | Fully (working copy, branch `ccr-056ddc8c-m7u4p1` = `main` @ `3b80ec0`) |
| `wilnergraph92/goship-express-app` | Expo mobile app (customer area) | Read-only shallow clone outside the project (`/home/user/wilnergraph92/goship-express-app`), notification/API layer reviewed |
| Supabase `gpfdyslysqjmojgzggib` | Production database | Read-only metadata (extensions, Edge Functions, security advisors, cron job list, Vault secret **names** only, aggregate counts — no personal data read) |
| Supabase `ltbqqchtyzlyakcsxxis` | Speed Express (sister project) | Not inspected; noted only because it occupies a free-project slot |

### 2.2 Modules relevant to communication

| Module | What it does today | Reuse potential |
|---|---|---|
| `outils/supabase-notifications.sql` | Engine: rules, notifications, deliveries, worker `traiter_notifications()` (every minute, batch 50), retries, client feed, preferences RPCs, admin RPCs (`centre_notifications`, `suivi_notification`, `regles_notifications`, `modifier_regle_notification`, `tester_notification`) | **Core reuse** |
| `outils/supabase-courriel-colis.sql`, `-courriel-pied.sql`, `-courriel-reseaux.sql`, `-lieu-reception.sql` | Redefine `expedier_envoi`, the HTML template `courriel_gabarit` (logo, store buttons, social icons) | Reuse the e-mail template; **refactor provider calls out of `expedier_envoi`** |
| `outils/supabase-accuses.sql` | Expo push receipts → `livre` / `echec` (every 5 min) | Reuse as is |
| `outils/supabase-suivi-courriels.sql` | Brevo events polled per message (`GET /v3/smtp/statistics/events`) → `livre` / `echec` (5 codes) | Reuse; webhook can later replace polling |
| `outils/supabase-anniversaires.sql` | `notification_modeles` (editable templates per type × language, `{{prenom}}` etc.), birthday scheduler | Template pattern to generalise |
| `outils/supabase-campagnes.sql` | GOship APP **Welcome** and **Refer** (reward programmes, statuses brouillon/programmée/active/suspendue/terminée) | Not messaging campaigns — **naming collision** (§8) |
| `outils/supabase.sql` §7, §14 | Vault settings (`definir_reglage`, `lire_reglage`), `telephone_international`, legacy `envoyer_email_client` / `envoyer_whatsapp_client` (closed to accounts), **welcome e-mails** (`courriels_bienvenue`: welcome + Miami address), `adresse_miami()` | Reuse; legacy senders must stay closed |
| `outils/supabase-double-auth.sql` | Team permissions require TOTP (`aal2`) when a factor is enrolled | New `communications.*` permissions inherit it automatically |
| `assets/js/api.js` | `window.GoshipAPI`, dual backend (`supabase` / `demo`) | Every new `API.admin` method needs **two implementations** |
| `assets/js/admin.js`, `admin.html`, `tableau.css` | Dashboard (11 tabs, 3 menu groups), `<dialog>` rules, `data-permission` hiding | Host of the Communication Center tab |
| `assets/js/notifications.js` | Hand-built e-mail/WhatsApp texts used by the dashboard's **manual** "Envoyer depuis mon WhatsApp" (`wa.me`) link | Keep; manual sends are untracked |
| `assets/js/compte.js` | Customer area; reads notifications; **no channel-preference UI** | Consent/preferences UI goes here |
| `tableau-langue.js`, `tableau-textes.js`, `outils/traductions/tableau.txt` | Dashboard i18n (fr, en, es, ht) | Every new label: `tableau.txt` + 3 translations + `traduire.py` |
| `outils/generateur/pages/` | Source of generated pages (`admin.html`, `mon-compte.html`) | Edit here, never the generated file |
| Mobile `lib/api.js`, `lib/notifications.js`, `app/messages.jsx` | Reads `mon_resume.messages` (from `messages_recents`), registers devices, updates `clients` (column-limited), birthday preference only | Consent screen needs an app release; old versions must keep working |
| `bureau/` | Electron shell, no business logic | No change expected |

### 2.3 Test benches (all run without touching production)

`outils/essais-services/` — 50+ benches, notably `essai-notifications.py` (whole migration chain on a
throwaway Postgres, simulated providers via `net._http_response`, 10 000-delivery volume test with four
parallel workers), `essai-accuses.py`, `essai-suivi-courriels.py`, `essai-permissions.py/.js`,
`essai-programmes*.{py,js,mjs}`, `essai-production.py`. CI: `essais.yml` on every push. **This throwaway-DB
pattern is the natural staging substitute for database logic.**

---

## 3. Existing customer data structure

### 3.1 `public.clients` (one row per `auth.users`, cascade)

| Column | Notes for messaging |
|---|---|
| `id` uuid | Customer ID |
| `code` text unique | `GSE-####`; null for team accounts |
| `nom_complet` text | **Single full-name field — no separate first/last name.** "First name" is derived as the first word (`split_part`) |
| `email` text | 69/69 active customers have one |
| `telephone` text + `pays` | 64/69 have a phone; `telephone_international()` adds 509 (HT, 8 digits) or 1 (DO/US, 10 digits), otherwise digits as typed — **no E.164 validation** |
| `langue` | fr 51 · en 9 · ht 7 · es 2 |
| `pays`, `region`, `ville`, `adresse` | HT 37 · DO 18 · US 9 · empty 5 |
| `role` | client 69 · admin 2 · **gérant 0 · employé 0** |
| `cree_le`, `supprime_le`, `sexe`, `type_document` | Deleted accounts are anonymised, never removed |

Column-level grant: customers may only update `nom_complet, pays, region, ville, adresse, telephone,
langue` (`supabase.sql:535`). **Any new column on `clients` is therefore not customer-writable by default
— good for consent integrity**, but consent should live in its own append-only table anyway.

Sensitive data kept apart: `profils_naissance` (birth date), `profils_document` (ID number) — closed tables,
never in `journal_audit`.

### 3.2 Related data

`colis` (44 rows; status, `pays_destination`, `destination`, `mode`), `colis_historique` (events),
`factures`/`paiements`, `prealertes`, `appareils` (31 push tokens), `notification_preferences`
(per customer × category {colis, factures, paiements} × channel; **no row = everything on**),
`programme_preferences` (birthday opt-out).

### 3.3 Personalisation variables requested by the plan

| Plan variable | Exists? | Source / issue |
|---|---|---|
| `{prenom}` | Derived | first word of `nom_complet`; existing engine already uses `{{prenom}}` |
| `{nom}` | Partially | only `nom_complet`; no last-name field |
| `{code}` | Yes | `clients.code` |
| `{email}` | Yes | `clients.email` (should it ever be in a message body? data-minimisation question) |
| `{telephone}` | Yes | `clients.telephone` (same question) |
| `{adresse_miami}` | Yes, static | `adresse_miami()` + name + code. **Inconsistency found:** `mon-compte.html:42` shows "Apt 46780" while the address table shows "Address 2: ABX-46780"; the comment in `supabase.sql` says the address is hard-coded in **four** places (SQL, `notifications.js`, mobile `config.js`, `mon-compte.html`) |
| `{date}` | Undefined | which date (send date? Santo Domingo calendar?) must be specified |

Syntax conflict: the plan writes `{var}`; the existing engine uses `{{var}}` and **silently erases unknown
variables** (`rendre_notification`). The plan requires "never send unresolved variables" → campaign
rendering must **refuse**, not erase.

---

## 4. Existing notification architecture

### 4.1 Triggers (sources)

| Source | Events → notification types |
|---|---|
| `colis_historique` (public steps only) | `COLIS_RECU` → `shipment_received`; `EMBALLE`, `EXPEDIE`, `ARRIVE`, `TRANSFERE`, `DISPONIBLE`, `LIVRE`; `ACTION_REQUISE`/`RESOLUE` |
| `evenements_facturation` | `invoice_created`, `payment_received`, `invoice_paid` |
| Scheduler | `invoice_overdue` (daily) |
| `suivis_externes` (17TRACK) | `carrier_delivered`, `carrier_issue`, `carrier_invalid` |
| Programmes | birthdays, Welcome/Refer reward changes |
| `clients` / `auth.users` triggers | **Welcome e-mail + Miami-address e-mail** (`courriels_bienvenue`) — sent directly via pg_net, **outside** `notification_envois` |

### 4.2 Production rule state (16 rules, all active)

| Type | Channels configured |
|---|---|
| `shipment_received`, `shipment_available` | push, email, whatsapp |
| `action_required` | push, email |
| all other shipment / invoice / carrier types | push only |

Invoice e-mails were switched off by CEO decision on 19/10/2026 (`supabase-courriel-pied.sql`).

### 4.3 Delivery statistics to date (production, aggregate)

| Channel | envoye | livre | echec | annule |
|---|---|---|---|---|
| email | 118 | 37 | 0 | 0 |
| push | 35 | 15 | 4 | 242 (mostly no device) |
| whatsapp | 0 | 0 | 0 | **83 (not configured)** |

274 in-app notifications in total.

### 4.4 Guarantees already in place

- Idempotency: unique `notifications.cle`; unique `(notification_id, canal, cible)`.
- Concurrency: `for update skip locked`; tested with 4 parallel workers × 10 000 deliveries.
- Business transaction never calls a provider; engine failure never blocks the business operation.
- Throughput: `notification_moteur.lot` = 50 deliveries per pass, 1 pass/minute (≈ 3 000/hour), `haute`
  priority first.
- Retention: finished deliveries purged after **180 days** (`notifications_quotidiennes`); notifications kept.
- Privacy: a delivery stores a target type (`email`, `whatsapp`, `appareil:<id>`), never the address/number;
  provider error text truncated, no PII; "sensitive" rules show neutral text on lock screens.
- Nothing that sends is executable by any account (`creer_notification`, `traiter_notifications`,
  `expedier_envoi` revoked from `anon`/`authenticated`).

### 4.5 Gaps

- No admin UI for the delivery center / rules / test send (PR #13 closed unmerged).
- No customer UI for channel preferences (web or app), although `regler_preference_notification` exists.
- No webhook ingestion (needs an Edge Function, documented in `docs/notifications.md` §9).
- No WhatsApp inbound (replies, STOP, 24-hour window), no read receipts.
- No marketing lane, consent, suppression or unsubscribe.
- WhatsApp templates are **hard-coded** (`modele_whatsapp()` maps only 2 types; parameter arrays hard-coded
  in `expedier_envoi`); language mapping sends `ht` customers the **French** template.
- Welcome e-mails bypass the delivery table (no retry/status tracking like other e-mails).

---

## 5. Existing API integrations

| Provider | Status in production | Credentials (Vault, names only) | Notes |
|---|---|---|---|
| **Brevo** (transactional API `/v3/smtp/email`) | **Live** | `email_fournisseur`, `email_cle_api`, `email_expediteur`, `email_nom` | Sender `infos@goshipexpress.net`; outage 26–27/10 (sender not validated) led to event polling. Also Supabase **Auth SMTP** (confirmation, reset). Plan tier **not verifiable from here** |
| **Resend** | Code path only | (would reuse `email_cle_api`) | Not used; no delivery tracking implemented for it |
| **Meta WhatsApp Cloud API** | **Not configured** | `whatsapp_jeton`, `whatsapp_numero_id` **absent** | Graph `v23.0` default; 2 template names expected (`colis_recu`, `colis_disponible`), unknown whether they exist in a WABA |
| **Expo Push** | Live (Android internal) | none needed | Receipts read every 5 min; iOS needs Apple Developer account |
| **17TRACK** | Live (trial-capped) | `suivi_17track_cle` | Not communication-related |
| **Healthchecks.io** | Live | `battement_url` | Heartbeat every 30 min |
| Google Analytics 4 | Live on public pages | public ID in `config.js` | Marketing attribution input |
| Meta Pixel | **PR #46 open, not merged** | — | Relevant to campaign attribution and consent |

E-mail domain DNS (public lookup, 18/11/2026): SPF `v=spf1 include:_spf.mail.hostinger.com ~all`
(Hostinger only — acceptable because DMARC alignment is achieved through DKIM); DKIM `brevo1`/`brevo2`
CNAMEs to Brevo **present**; DMARC `p=quarantine; rua=mailto:rua@dmarc.brevo.com` **present**;
`brevo-code` verification TXT present. → **SPF/DKIM/DMARC requirement already met for Brevo.**

No Edge Functions, no API server, no other webhook endpoint exists.

---

## 6. Current permission matrix

Source of truth: `permissions_du_role()` in `supabase.sql` (copied verbatim in `supabase-naissance.sql`,
`supabase-suivi-externe.sql`, and `PERMISSIONS_DES_ROLES` in `api.js`; compared by `essai-permissions.*`).
No rule ever tests a role name.

| Permission family | admin | gérant | employé | client |
|---|---|---|---|---|
| clients view / create / edit | ✓ ✓ ✓ | ✓ ✓ ✓ | ✓ ✓ – | own view/edit |
| shipments (view…correct, delete) | all | all but delete | most | own |
| invoices / payments | all | all | view | own |
| reports view / create / edit / delete | ✓✓✓✓ | ✓✓–– | – | – |
| users.view · roles.manage · settings.manage · audit_logs.view | ✓✓✓✓ | ✓––– | – | – |
| birthdays · programs · points.adjust | all | view only | – | – |
| tracking.view / manage | ✓✓ | ✓– | ✓– | – |
| **communications.*** | **does not exist** | | | |

Notification-related today: `settings.manage` (admin) changes rules and sends a test **to own account
only**; `reports.view` (admin, gérant) reads the delivery center; employees see deliveries of a parcel.
Team permissions require a TOTP session (`aal2`) once a factor is enrolled.

Master-plan mapping (to be decided in Phase 1): new permissions such as `communications.view`,
`.create`, `.edit`, `.schedule`, `.send`, `.approve`, `.templates.manage`, `.automations.manage`,
`.settings.manage`. Each needs: the SQL matrix (3 copies), the demo copy, `essai-permissions`, RLS/RPC
checks, `data-permission` in `admin.html`, translations.

Observation: **there are currently no gérant or employé accounts in production** — the gérant scope can
only be tested on a test database.

---

## 7. Security assessment

### 7.1 Strengths to preserve
- Provider keys only in Vault, never sent to a page; the site holds only the publishable key.
- All sending functions closed to accounts; business rules in the DB; RLS on every table.
- Append-only audit log (`journal_audit`, immutable trigger), motif support.
- Deployment gate refuses publishing secrets / working files; `.htaccess` HSTS, frame-ancestors.
- 2FA for team accounts; heartbeat monitoring; daily encrypted backups with test restore.

### 7.2 Findings (from repository and Supabase security advisors, read 18/11/2026)

| # | Severity | Finding | Relevance |
|---|---|---|---|
| S1 | High (for this project) | **No consent model.** Marketing sends would currently be unlawful in several target contexts and against WhatsApp Business policy | Blocking for campaigns |
| S2 | High | Brevo shared between Auth mail and future campaigns; plan tier unknown | Campaign could block sign-ups/password resets |
| S3 | Medium | Webhooks will introduce the **first public write endpoint** outside PostgREST (Edge Function with service credentials) | Must verify Meta `X-Hub-Signature-256`, Brevo token/basic-auth, timestamps, replay; minimal privileges |
| S4 | Medium | Employé has `clients.view` → can read every customer's e-mail/phone; a segment **export** feature would widen this | Restrict segment preview/export to `communications.*` |
| S5 | Medium | Unsubscribe links must be **unguessable signed tokens** (not customer code/ID) | New public RPC/endpoint must be added to the `controle-securite.sql` whitelist |
| S6 | Medium | Template injection: staff-written HTML/text in campaigns. Existing code escapes data (`html_echappe`) but treats templates as trusted | Campaign templates should be text/limited markup, rendered and escaped by the DB |
| S7 | Low | Advisors: `pg_net` in `public` schema (known, accepted 16/11); 137 SECURITY DEFINER functions executable by `authenticated` (by design, each checks `exiger_permission`); 3 by `anon` (`suivre_colis`, `sante`, Supabase's `rls_auto_enable`, all known/whitelisted); 31 tables "RLS enabled, no policy" (intentional closed tables); **leaked-password protection disabled** (CEO decision D3: free-tier rule) | No new action for this project; keep the patterns |
| S8 | Low | `telephone_international` has no E.164 validation; wrong numbers would cost money on WhatsApp | Validate before marketing sends |

### 7.3 Compliance overview (not legal advice — counsel review recommended before any campaign)

| Market / rule | Key requirement for this project |
|---|---|
| USA — CAN-SPAM (e-mail) | Clear sender, non-deceptive subject, **valid physical postal address**, working opt-out honoured within 10 business days. ⚠ The e-mail footer **removed the Medley postal address** on 19/10/2026 — a commercial e-mail would need it back |
| USA — TCPA and **Florida FTSA** (business is in Florida; texts/automated messages) | Prior express written consent for marketing messages to mobile numbers; keep consent proof |
| Gmail/Yahoo bulk-sender rules | One-click unsubscribe (RFC 8058 `List-Unsubscribe-Post`), DMARC — mandatory above 5 000/day, best practice below |
| Dominican Republic — Ley 172-13 (personal data) | Informed, express consent for processing for marketing purposes; access/rectification/deletion rights |
| Haiti | No comprehensive data-protection statute identified during this audit — apply the strictest common standard; **verify with counsel** |
| Meta WhatsApp Business / Commerce policy | Opt-in before business-initiated messages; approved templates outside the 24-hour window; honour opt-outs; quality rating can restrict the number |
| Existing privacy policy (`confidentialite.html`) | Mentions no marketing communications; must be updated (4 languages) before collecting consent |

---

## 8. Potential conflicts with existing GoShip functionality

| # | Conflict | Impact | Recommended resolution |
|---|---|---|---|
| C1 | **Plan automations 1–6 already exist** (welcome + Miami address e-mails in `supabase.sql` §14; received/shipped/available/delivered rules) | Duplicate messages to every customer | "Automations" screen = UI over the **existing** `notification_regles` and welcome trigger; no second engine for transactional events |
| C2 | Name collisions: `campagnes_bienvenue`, cron job `goship-campagnes`, tab "Programmes", `notification_modeles` (templates) | Confusion in code, UI and reports | Use the `communication_` prefix for tables; UI label "Communications"; decide whether templates extend `notification_modeles` or a new table |
| C3 | `notifications` table **is the customer's feed** (site + app), and `messages_recents` feeds the mobile "Messages" screen whose shape is frozen | Marketing would pollute transactional history; old app versions can't distinguish | Keep campaign messages out of `notifications`, or add them with a category the feed filters — decision in Phase 1 |
| C4 | Single worker, batch 50/min, shared by all transactional channels | A campaign could delay "Colis disponible" | Separate campaign worker/job, lower priority, own rate limit, global per-provider budget |
| C5 | Brevo daily quota shared with Auth SMTP | Sign-up confirmation could fail | Verify plan; reserve quota; possibly separate marketing sub-domain/sender |
| C6 | `notification_preferences` is transactional-only by design | Must not double as marketing consent (plan rule) | Separate consent ledger; never infer marketing consent from it |
| C7 | 180-day purge of `notification_envois` | Consent/campaign evidence could be lost | Campaign records and consent ledger with their own retention policy |
| C8 | Variable syntax `{x}` vs `{{x}}`; unknown variables silently erased | Plan forbids unresolved variables | Campaign renderer refuses; keep `{{x}}` for consistency |
| C9 | Hard-coded WhatsApp templates and parameters; `ht` → French | Rigid; Creole customers get French | Template registry with per-language Meta template names and parameter mapping |
| C10 | Manual "Envoyer depuis mon WhatsApp" (`wa.me`) | Untracked, outside consent/suppression | Keep for transactional support; exclude from campaigns |
| C11 | Company WhatsApp number (+1 849 538-6262) presumably on the **WhatsApp Business App** | Registering it on Cloud API may remove it from the app unless Meta "coexistence" is used | CEO decision: coexistence, new number, or migration |
| C12 | E-mail footer without postal address; invoice e-mails switched off by CEO | Commercial e-mails need the address; the center must not silently re-enable invoice e-mails | Marketing-specific footer; transactional rules untouched |
| C13 | Docs say an admin "Notifications" tab exists; code doesn't (PR #13 closed) | Misleading baseline | Communication Center absorbs those screens (delivery center, rules, test send) |
| C14 | Dashboard conventions: demo-mode copy for every `API.admin` method, `tableau.txt` translations, generated `admin.html`, ES5 only | Underestimated effort | Budgeted in §10 |
| C15 | Mobile app: consent screen needs a store/EAS release; old versions keep working without it | Mobile users can't opt in until updated | Web opt-in first; app later; DB defaults to "no consent" |
| C16 | No-TypeScript/no-build rule vs Edge Functions (Deno/TS) | Policy exception | Isolate in a separate folder excluded from Pages (like `bureau/`), plain JS allowed in Deno |
| C17 | Open PR #48 ("Centre de Commandement IA" Phase 0) and PR #46 (Meta Pixel) | Possible overlapping scope | Reconcile before Phase 1 |
| C18 | Birthday programme explicitly excludes WhatsApp (no approved template) | Expectation that the center enables it | Becomes possible only after the template registry exists |

---

## 9. Infrastructure limitations

| Limitation | Detail |
|---|---|
| Supabase **Free plan** | No PITR, no branching, 500 MB DB; org already has 2 active free projects → **cannot create `goship-staging` for free** without pausing Speed Express or upgrading |
| No staging (go-no-go C7 "non rempli") | `preproduction.yml` and EAS `staging` profile exist but the project doesn't |
| No Edge Functions deployed; no Supabase CLI pipeline | Webhooks/one-click unsubscribe need one; requires a new deploy path (CLI in GitHub Actions or the Supabase dashboard) and secret handling in Edge env |
| pg_net is fire-and-forget; responses read next minute | Fine for queues; webhooks still needed for WhatsApp read/delivery and inbound |
| Worker cadence 1 minute | Scheduling precision ≈ 1 minute — acceptable |
| `pgmq` available but not installed | Not needed: the existing table-queue pattern is proven |
| Hosting: static GitHub Pages + Hostinger | No server-side endpoints; public endpoints must be PostgREST RPC or Edge Function |
| Monitoring | Healthchecks heartbeat covers `goship-…` cron jobs; a new campaign job is automatically covered if named `goship-…` |
| Single operator | Only 2 admin accounts, no gérant/employé — approval workflow (gérant creates, admin approves) has no real users yet |
| iOS app | Not distributed (no Apple Developer account) |

**Proposed safe staging strategy** (to confirm in Phase 1): (1) database logic on throwaway Postgres
through the existing `essais-services` harness (same as all previous phases), with simulated providers;
(2) providers in sandbox — Brevo `X-Sib-Sandbox: drop` header, Meta **test phone number** with
allow-listed test recipients; (3) a real Supabase staging project only if the CEO approves Pro
(~US$25/month) or pausing Speed Express; (4) production rollout behind feature switches that are born
**off** (as every previous programme).

---

## 10. Estimated implementation complexity

Effort in working sessions of a Claude Code-assisted developer, following the project's standards
(DB rules, demo copy, 4-language UI, test benches, docs). Indicative.

| Block | Size | Effort | Main drivers |
|---|---|---|---|
| Consent & preferences (ledger, suppression, web opt-in, privacy policy ×4, account page) | M | 3–4 | Legal wording, 4 languages, demo copy |
| Permissions `communications.*` | S | 1 | 3 SQL copies + demo + tests |
| Templates registry (e-mail + WhatsApp, 4 languages, variables, validation) | M | 2–3 | Meta template names/params per language |
| Segments + audience snapshot | M | 2–3 | Queries over clients/colis, counts before send |
| Campaign lifecycle + approval + scheduling | M | 3 | 8 states, audit log |
| Campaign queue & worker (rate limit, retries, dead letter, provider budget) | M | 2–3 | Reuse existing patterns |
| Provider adapter refactor (extract from `expedier_envoi`) | M | 2 | Must not change transactional behaviour — heavy regression testing |
| Edge Function: Meta webhook (verify, statuses, inbound, STOP) + Brevo webhook + one-click unsubscribe | L | 4–5 | New deploy path, signatures, replay protection |
| WhatsApp onboarding (WABA, number, business verification, templates approval) | — | CEO/Meta lead time: days to weeks | External |
| Dashboard Communication Center (11 views per plan) | L | 6–8 | ES5, dialogs, translations, demo mode, permissions |
| Absorb PR #13 screens (delivery center, rules, test send) + customer channel preferences | M | 2–3 | Already designed once |
| Analytics (sent/delivered/read/bounce/unsubscribe, costs) | M | 2 | "Not tracked" ≠ zero rule |
| Mobile app: consent + preferences screens | M | 2–3 + store review | Separate repo/release |
| QA, regression, docs (8 documents), deployment | M | 3–4 | |
| **Total** | | **≈ 35–45 sessions** + external lead times | |

---

## 11. Recommended architecture

**Principle: one engine, two lanes, shared adapters.**

```text
 Transactional lane (UNCHANGED)                      Marketing / campaign lane (NEW)
 colis_historique, facturation, scheduler            Campaign (draft → approval → scheduled)
        │ triggers                                          │ snapshot audience at launch
        ▼                                                   ▼
 notifications + notification_envois          communication_campagne_destinataires (frozen list)
        │ worker goship-notifications (1/min)              │ eligibility: consent ∧ ¬suppression ∧ channel ok
        │                                                   ▼
        │                                      communication_messages (queue, idempotency key
        │                                        campagne:<id>:<client>:<canal>) worker goship-communications
        └──────────────┬────────────────────────────────────┘ (lower priority, own rate limit)
                       ▼
        Shared provider adapters (refactored from expedier_envoi):
          fournisseur_email(...)   → Brevo | Resend   (provider chosen by setting)
          fournisseur_whatsapp(...) → Meta Cloud API  (template registry)
          global per-provider daily budget (protects Auth SMTP quota)
                       ▼
        Edge Function "communication-webhooks" (only public writer, signature-verified)
          Meta: statuses (sent/delivered/read/failed), inbound text → STOP → suppression, 24h window
          Brevo: delivered/bounce/complaint/unsubscribe → status + suppression
          One-click unsubscribe (RFC 8058) via signed token
```

Key design decisions to confirm in Phase 1:

1. **Transactional stays where it is.** The "Automations" view edits `notification_regles` (and exposes the
   welcome e-mails) — no duplicate engine (C1).
2. **Consent ledger** `communication_consentements`: append-only (client, channel, purpose `marketing`,
   granted/withdrawn, source, wording version, timestamp, actor). Current state is derived. Default = no
   consent. Never pre-ticked. Transactional authorisation remains `notification_preferences`.
3. **Suppression list** per channel (hard bounce, complaint, STOP, manual), checked at enqueue **and** at send.
4. **Audience snapshot** at approval/launch; recount shown before sending.
5. **Rendering in the DB**, `{{variable}}` whitelist from the real schema, **refuse** on missing value
   (or explicit per-variable fallback chosen by the author), HTML escaped.
6. **Separate queue table** for campaign messages (not `notification_envois`) so transactional tables,
   mobile contracts and the 180-day purge stay untouched; shared adapters avoid code duplication.
7. **Approval workflow**: gérant creates/edits/schedules; sending requires `communications.send`; admin
   approval (`communications.approve`) configurable — CEO decision.
8. **Kill switches**: global "campaigns enabled" setting born off; per-channel switches; per-campaign pause.
9. **Analytics** distinguishes accepted / delivered / read; unknown = "not tracked", never zero.
10. Every new public endpoint added to the `controle-securite.sql` whitelist; new cron job named
    `goship-communications` so the heartbeat covers it.

---

## 12. Cost estimates and external dependencies

Prices are **indicative public list prices known at audit time; verify on each provider's current rate
card before deciding.**

| Item | Today | Needed for the plan | Indicative monthly cost |
|---|---|---|---|
| Supabase | Free | Free works for the code; **staging project or branching needs Pro** | US$0 → US$25 (Pro) |
| Brevo | Live (tier unknown; free tier = 300 e-mails/day) | Campaigns to all customers + Auth mail headroom | US$0 → ~US$9–25 (Starter, ~5–20k e-mails/month) |
| Resend (alternative) | unused | only if Brevo is replaced | Free 3 000/month (100/day); Pro ~US$20 |
| Meta WhatsApp Cloud API | not configured | WABA + verified business + phone number + approved templates | No platform fee; **per delivered template message**: marketing ≈ US$0.025 (US) and ≈ US$0.07 (Latin America group, incl. DO; Haiti's grouping to verify); utility ≈ US$0.004–0.011, free inside the 24-hour window; service replies free |
| Example: one WhatsApp marketing campaign to today's 64 reachable customers | | | ≈ US$4–5 per send |
| Example: one marketing e-mail to 69 customers | | | within free tier |
| Phone number for WhatsApp | existing number on Business App? | coexistence or new number | US$0–~5/month for a new virtual number (if chosen) |
| Legal review (consent wording, privacy policy, 3 jurisdictions) | — | recommended | external, one-off |
| Apple Developer (for iOS consent/push) | missing | only for iOS | US$99/year (already a known pending item) |

External dependencies and lead times: Meta Business verification and template approval (days to weeks),
Brevo plan confirmation, DNS (already compliant), counsel review, mobile store/EAS release.

---

## 13. Migration risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Refactoring `expedier_envoi` breaks transactional e-mail/WhatsApp (it has been redefined by 3 later migrations: courriel-colis, lieu-reception, …) | Medium | High | Extract adapters in a new migration placed **last** in the chain; byte-for-byte payload comparison in `essai-notifications.py`; never re-run earlier files |
| Chain ordering ("re-running one requires re-running those after") | Medium | High | New files appended at the end of `migrations.txt`; replayable (`if not exists`, no deletes) |
| Permission matrix drift (3 SQL copies + demo) | Medium | Medium | `essai-permissions` updated in the same change |
| Duplicate sends at go-live (old + new automations) | Medium if C1 ignored | High | No new transactional automations; idempotency keys per campaign/client/channel |
| Accidental real sends during testing | Low | High | Global switch off; sandbox headers; Meta test number; benches use simulated `net._http_response` |
| Brevo quota exhaustion blocking Auth e-mails | Medium | High | Provider budget + plan check before first campaign |
| WhatsApp number quality rating drop / block | Medium | High | Consent only, small first batches, honour STOP immediately |
| Mobile compatibility (frozen `mon_resume`, `messages_recents`) | Low | High | Do not change shapes; campaign messages outside the feed or filtered |
| No production-like staging | High | Medium | §9 strategy; production features born off |
| Backup/restore | Low | High | Daily encrypted backup + verified restore exist; take/verify the day's backup before each migration (existing procedure) |

Rollback: site = `git revert` + redeploy (proven); DB = additive migrations (new tables/functions only) can
be disabled by switches without data loss; full restore procedure proven out of production.

---

## 14. Recommended implementation sequence

| Step | Content | Gate |
|---|---|---|
| **P0** | This audit | **CEO approval (now)** |
| **P1** | `COMMUNICATION_CENTER_ARCHITECTURE.md` + security design; decisions D-A…D-J below; migration files drafted, **not executed** | CEO approval |
| P2a | Consent foundation first: consent ledger, suppression, `communications.*` permissions, privacy policy update (4 languages), web opt-in at sign-up and in "Mon compte" (never pre-ticked) — so consents start accumulating early | CEO approval + counsel wording |
| P2b | Templates registry, segments, audience snapshot, campaign lifecycle, campaign queue/worker, provider adapter refactor (transactional regression-tested) | Tests green on throwaway DB |
| P3 | E-mail marketing via existing Brevo (sandbox), unsubscribe + one-click; Edge Function for webhooks; WhatsApp onboarding (WABA, number, templates) in parallel | CEO authorises live test to internal recipients only |
| P4 | Communication Center UI (absorbing the PR #13 screens and customer channel preferences) | |
| P5 | Automations view over existing rules; new marketing automations (inactive-customer reactivation) only for consented customers | |
| P6 | Analytics & monitoring | |
| P7 | QA (all plan items A–M), staged production rollout behind switches, first real campaign to a small consented group | CEO GO |
| Mobile | Consent/preferences screens in the app (separate repo, EAS/stores) | After P2a |

### Decisions requested from the CEO before/at Phase 1

- **D-A** Staging: Supabase Pro (~US$25/month), pause Speed Express, or throwaway-DB + sandbox strategy only.
- **D-B** WhatsApp number: Meta coexistence on the current number, a new dedicated number, or migration.
- **D-C** Brevo plan: confirm current tier and whether campaigns use a separate sender/sub-domain.
- **D-D** Approval flow: may a gérant send without admin approval?
- **D-E** Should campaign messages appear in the customer's in-app notification feed?
- **D-F** Legal: counsel review of consent wording and privacy policy (US/FL, DO, HT).
- **D-G** Postal address in marketing e-mail footer (CAN-SPAM) — which address.
- **D-H** Canonical Miami address (fix "Apt 46780" vs "ABX-46780").
- **D-I** Re-permission approach for the 69 existing customers (account banner / app prompt; no marketing
  e-mail without consent).
- **D-J** Relationship with open PRs #46 (Meta Pixel) and #48 (AI Command Center audit).

---

## Phase report (per master plan §14)

1. **Inspected:** both repositories (site fully; app API/notification layer), all 39 migrations' messaging
   parts, docs (`notifications.md`, `programmes.md`, `docs/production/*`), workflows, permissions; Supabase
   production metadata read-only (extensions, Edge Functions = none, security advisors, 9 cron jobs, Vault
   secret names, aggregate counts); public DNS records; open/closed PRs.
2. **Implemented:** nothing.
3. **Files changed:** none in either repository. This report lives in the session scratchpad. A read-only
   shallow clone of the public app repository was made outside the project folder for reading.
4. **Database changes:** none (SELECT queries on catalog/aggregate data only).
5. **Tests performed:** none needed (no change). 6. **Results:** n/a.
7. **Security implications:** none from the audit; findings in §7.
8. **Remaining blockers:** no consent model; WhatsApp not configured; no Edge Function path; no staging;
   Brevo plan unknown; legal review.
9. **Estimated next-phase cost:** Phase 1 (architecture + security design + draft migrations, not executed)
   ≈ 3–4 sessions; no external cost.
10. **Approval required to continue:** explicit written CEO approval of this Phase 0 report, and answers
    (or deferral) to decisions D-A to D-J, before Phase 1 begins.
