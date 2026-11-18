# GoShip Express — Communication Center
# COMMUNICATION_CENTER_SECURITY.md — Phase 1

| | |
|---|---|
| Date | 18 November 2026 |
| Status | **Design for CEO approval.** No production change, no secret change, no provider activation. |
| Not legal advice | Sections marked ⚖️ **require written approval of legal counsel before activation**. |

---

## 1. Security objectives

1. No marketing message to anyone who has not personally, provably consented on that channel.
2. Withdrawal always wins, immediately, on every path (account toggle, link, STOP, complaint, staff).
3. No marketing message without admin approval of its exact content, audience rules, schedule and caps.
4. No spend beyond the global daily and per-campaign caps; Auth e-mails never starved.
5. During development and test mode, nobody outside the server-enforced allowlist receives anything.
6. The transactional lane, its data and the mobile API contracts are unaffected.
7. No secret in the repository, the site, the app or the Edge Function code; no key able to bypass RLS
   outside the database.
8. Every staff action is attributable, reasoned and journaled; evidence tables are immutable.

---

## 2. Exact permission matrix (requirement 8)

### 2.1 Permissions

| Permission | Admin | Gérant | Employé | Client |
|---|---|---|---|---|
| `communications.view` | ✓ | ✓ | – | – |
| `communications.create` | ✓ | ✓ | – | – |
| `communications.test` | ✓ | ✓ | – | – |
| `communications.pause` | ✓ | ✓ | – | – |
| `communications.approve` | ✓ | **–** | – | – |
| `communications.manage` | ✓ | **–** | – | – |
| `communications.consents` | ✓ | ✓ | – | – |
| Own marketing consent (no permission; `auth.uid()` = own row, role `client`) | – | – | – | ✓ |
| Transactional rules (`notification_regles`, existing `settings.manage`) | ✓ | – | – | – |
| Audit journal (existing `audit_logs.view`) | ✓ | – | – | – |

All team permissions inherit the 2FA rule (`session_double_auth_ok()`, aal2 once a factor is enrolled).
No other existing permission changes. Employé has **no** access to the Center (master plan §3).

### 2.2 Action-level matrix

| Action | Function | Required | Admin | Gérant |
|---|---|---|---|---|
| See Center, history, analytics, spend, health | `sante_communications`, lists, stats | view | ✓ | ✓ |
| Audience preview (**counts only**) | `apercu_audience_communication` | view | ✓ | ✓ |
| Create / edit campaign draft | `ecrire_campagne_communication` | create | ✓ | ✓ |
| Create / edit template draft, segment | `ecrire_modele_…`, `ecrire_segment_…` (Phase 2) | create | ✓ | ✓ |
| Submit campaign / withdraw submission | `changer_statut_campagne('soumettre'/'retirer')` | create | ✓ | ✓ |
| Schedule (set `planifiee_le` in draft) | `ecrire_campagne_communication` | create | ✓ | ✓ |
| Back to draft (before launch; clears approval) | `('remettre_en_brouillon')` | create | ✓ | ✓ |
| Cancel a draft / pending campaign | `('annuler')` | create | ✓ | ✓ |
| **Approve / reject campaign** (= authorises sending) | `('approuver'/'refuser')` | approve | ✓ | – |
| **Approve template** | `approuver_modele_…` (Phase 2) | approve | ✓ | – |
| Pause scheduled/running campaign | `('mettre_en_pause')` | pause | ✓ | ✓ |
| **Resume** paused campaign | `('reprendre')` | approve | ✓ | – |
| **Cancel** approved/running campaign | `('annuler')` | approve | ✓ | – |
| Send a test (allowlist only) | `tester_campagne_…` (Phase 2) | test | ✓ | ✓ |
| Switches, mode, limits, quotas, quiet hours, frequency, four-eyes | `regler_communications` | manage | ✓ | – |
| Verify tariffs | `verifier_tarif_communication` | manage | ✓ | – |
| Manage test allowlist | `regler_destinataire_essai` | manage | ✓ | – |
| Consent texts (write, mark counsel-approved) | `ecrire_/approuver_texte_consentement` | manage | ✓ | – |
| Record postal address (after CEO decision) | `valider_adresse_postale` | manage | ✓ | – |
| Lift a suppression (never restores consent) | `lever_suppression_communication` | manage | ✓ | – |
| Relaunch dead letters | Phase 2 | manage | ✓ | – |
| Read a customer's consent/suppression history | `consentements_client` | consents | ✓ | ✓ |
| Record a withdrawal requested by the customer | `retirer_consentement_client` | consents | ✓ | ✓ |
| **Record a grant on behalf of a customer** | — | **nobody** (DB check constraint) | – | – |
| Customer: read/set own consent | `mes_consentements_communication`, `regler_mon_consentement_communication` | own | – | – |
| Visitor: unsubscribe via link | `desinscrire_communication` (HMAC token) | token | – | – |
| Provider webhook ingestion | `communication_recevoir_evenement` (HMAC) | signature | – | – |

Server-side enforcement: every function calls `exiger_permission` (or checks `auth.uid()` ownership);
`data-permission` attributes in `admin.html` only hide. Tables have RLS enabled and **no** policy and no
grant: no direct read/write by any page.

Open choices (defaults in brackets): four-eyes for admin-created campaigns [off, journaled]; gérant
approving templates [no].

---

## 3. Threat model

| # | Threat | Vector | Control |
|---|---|---|---|
| T1 | Messaging non-consenting people | bug, segment misuse, consent assumed | Consent required at freeze **and** send; no row = no consent; consent bound to target hash; staff cannot grant |
| T2 | Messaging after withdrawal | race between freeze and send | Re-check per message; withdrawal paths write suppression + ledger; trigger on e-mail/phone change |
| T3 | Unapproved or altered content sent | edit after approval, template swap | Approval fingerprint incl. template content hashes; approved templates frozen; worker re-verifies |
| T4 | Runaway cost | loop, large segment, wrong tariff | Locked reservation before call; global + campaign caps; verified tariffs only; caps part of approval |
| T5 | Auth e-mails blocked | marketing consumes Brevo quota | Quota unknown → closed; reserve + measured usage computed per e-mail |
| T6 | Real messages during development | test against production | Mode `essai` default; allowlist enforced server-side; sandbox headers; Meta test number; all switches off; cron job inactive |
| T7 | Duplicate messages | retries, concurrent workers, replays | Unique keys; `skip locked`; no retry on unknown outcome; idempotent webhooks |
| T8 | Forged webhook / forged unsubscribe | public endpoints | Meta signature + Brevo secret at the edge; HMAC re-signature checked in SQL; replay table; 24 h age limit; unsubscribe HMAC token (no ID guessing) |
| T9 | Privilege escalation | page calls functions directly | Permission checks in every function; no direct table access; employé has nothing; 2FA |
| T10 | Template/HTML injection | staff text, customer names | Plain-text templates, DB-side HTML escaping; braces/pipes stripped from customer values; closed variable list |
| T11 | PII leakage | logs, provider errors, segment exports | Codes only (no provider text); preview = counts; inbound bodies never stored; hashes for suppression; no export feature |
| T12 | Key compromise | Edge Function, repo | Edge holds only publishable key + webhook secrets; provider keys stay in Vault; `deploy.yml` secret gate |
| T13 | WhatsApp number restriction/ban | complaints, low quality | Consent only, frequency caps, quiet hours, small first batches, STOP honoured, separate marketing number option |
| T14 | Transactional regression | shared code | No change to transactional functions; regression bench; yield rule |
| T15 | AI agents (PR #48) sending marketing | future tool exposure | `communications.*` sending functions must be excluded from any AI tool list |

---

## 4. Secrets and keys

| Secret | Where | Who reads | New? |
|---|---|---|---|
| `email_cle_api`, `email_expediteur`, `email_fournisseur`, `email_nom` | Vault | SQL adapters | existing, unchanged |
| `whatsapp_jeton`, `whatsapp_numero_id`, `whatsapp_version` | Vault | SQL adapters | existing names, still **not set** |
| `communication_expediteur`, `communication_whatsapp_numero_id` (optional dedicated sender/number) | Vault | marketing adapters | new, optional |
| `communication_cle_desinscription` (HMAC of unsubscribe tokens) | Vault | SQL | new |
| `communication_cle_webhook` (HMAC between Edge Function and SQL) | Vault **and** Edge Function secrets | SQL + Edge | new |
| `META_APP_SECRET`, `META_VERIFY_TOKEN`, `BREVO_WEBHOOK_TOKEN` | Edge Function secrets | Edge | new |
| `communication_url_un_clic` (public URL, not secret) | Vault setting | SQL | new |
| Supabase `service_role` | dashboard only | **nobody** — stays "used nowhere" | unchanged |

All set by the owner in Phase 3, never in chat, never in the repo; `docs/production/secrets.md` updated
in Phase 2 (inventory + rotation). Vault secrets don't survive a restore into a new project: recovery
procedure in `ARCHITECTURE.md` §11.

---

## 5. ⚖️ Legal and consent requirements (D-F) — for counsel review

This section lists requirements found by research; it is **not legal advice**. Every item marked ⚖️
must be confirmed in writing by counsel. The database enforces the gate: consent capture cannot open
until a text version is marked `approuve_juridique` with a reference to counsel's approval.

### 5.1 United States (federal + Florida, where GoShip operates)

| Rule | Requirement relevant to GoShip | Design |
|---|---|---|
| CAN-SPAM (commercial e-mail) | Accurate sender/headers; non-deceptive subject; identify as advertisement where applicable ⚖️; **valid physical postal address**; working opt-out honoured within 10 business days; opt-out link working ≥ 30 days | Postal address required (D-G) before production; unsubscribe link + List-Unsubscribe; immediate suppression |
| TCPA (federal) | Marketing texts/automated messages to mobiles need prior express written consent; whether WhatsApp messages fall under TCPA is unsettled ⚖️ | Treat WhatsApp marketing as requiring express written consent (checkbox + text version + timestamp) |
| Florida Telephone Solicitation Act (2023 amendment) | Consent may be given by "checking a box" or replying affirmatively; STOP must be honoured (15-day safe harbour before suit — we honour immediately); applicability to app-based messaging unclear ⚖️; calling-hour limits ⚖️ | Checkbox consent; immediate STOP; quiet hours 9:00–19:00 local (to confirm) ; frequency caps |
| Meta pause on US marketing templates | Since 01/04/2025 marketing templates are not delivered to US numbers | US marketing tariff `autorise = false` |
| Bulk-sender rules (Gmail/Yahoo) | DMARC, one-click unsubscribe, low complaint rate (mandatory > 5,000/day) | DMARC present; one-click via Edge Function |

### 5.2 Dominican Republic

| Rule | Requirement | Design |
|---|---|---|
| Ley 172-13 (personal data) | Consent must be **free, unambiguous, specific and informed**, recorded in writing or equivalent; right to demand free of charge that data not be used for advertising/commercial prospecting; access/rectification/deletion | Specific per-channel consent with stored text; free one-click withdrawal; staff can record a withdrawal request; access via consent history |
| Ley 310-14 (unsolicited commercial e-mail) — **not verified against official text** ⚖️ | Reported: prior consent, sender identification, unsubscribe processed within 2 business days | Immediate suppression satisfies; sender identification in footer |
| Good practice cited locally | Checkbox **unticked by default**, purpose stated, link to privacy policy | Implemented in UI design |
| WhatsApp +1 pause applicability to DO numbers ⚖️/technical | Unclear | DO tariff stays unverified until confirmed |

### 5.3 Haiti

No comprehensive data-protection statute in force could be confirmed (late 2026); a 2025 Penal Code
reportedly contains personal-data provisions whose entry into force is unclear ⚖️. **Design rule: apply
the strictest standard of the three markets to Haitian customers** (same consent, same withdrawal, same
evidence). Creole and French texts required.

### 5.4 Cross-market requirements implemented

- Marketing opt-in per channel, never pre-ticked, never inferred from transactional preferences.
- Consent timestamp, source, text version + text fingerprint, language, target fingerprint, actor.
- Channel-specific preferences and withdrawal; STOP keywords in 4 languages ⚖️ (list to validate:
  STOP, ARRET, ARRETER, DESABONNER, DESINSCRIRE, UNSUBSCRIBE, CANCEL, BAJA, PARAR, DETENER, KANPE,
  SISPANN, DEZABONE).
- Suppression list that survives account deletion (hash only).
- Transactional vs promotional classification by lane; no promotional content in transactional messages
  ⚖️ (existing transactional texts reviewed: none promotional).
- Data minimisation: no e-mail/phone variables in marketing; inbound bodies not stored; provider texts
  not stored; previews are counts.
- Retention ⚖️: consent ledger and suppressions kept indefinitely as proof (confirm); marketing queue
  24 months; provider events 90 days; transactional retention unchanged (180 days).

### 5.5 Wording requiring counsel approval before activation ⚖️

1. Consent texts per channel × 4 languages (`communication_textes_consentement`).
2. Privacy-policy section "Marketing communications" × 4 languages (who, what, channels, withdrawal,
   retention, providers Brevo/Meta, cross-border transfer to US providers).
3. Marketing e-mail footer (`communication_textes_pied`: reason + unsubscribe label) × 4 languages.
4. Unsubscribe confirmation page text × 4 languages.
5. STOP keyword list and any automatic STOP confirmation reply.
6. Quiet hours and frequency caps.
7. Sender identification and postal address line (D-G).
8. Advertisement labelling in subject/body, if required.

---

## 6. Risk assessment

| # | Risk | Likelihood | Impact | Mitigation | Owner |
|---|---|---|---|---|---|
| R1 | Regulatory complaint (no/invalid consent) | Low with design | High | Consent gate, counsel-approved texts, evidence ledger | CEO + counsel |
| R2 | WhatsApp marketing unreachable for US (and possibly DO) customers | High | Medium (value) | Known upfront; channel mix favours e-mail for US/DO | CEO |
| R3 | Coexistence onboarding disrupts support number | Low–Medium | High | Partner-run onboarding, off-hours, fallback dedicated number; no migration | CEO + partner |
| R4 | Brevo quota exhaustion blocks Auth | Low with reserve | High | Reserve + verified quota; optional Auth SMTP isolation | Admin |
| R5 | Cost overrun | Low | Medium | Caps (global/campaign), verified tariffs, reservations | Admin |
| R6 | Regression of transactional notifications | Low | High | No modification of transactional code; regression bench; yield rule | Dev |
| R7 | Duplicate marketing messages | Low | Medium | Unique keys, no blind retry | Dev |
| R8 | Webhook forgery / replay | Low | Medium | Signatures + HMAC + replay table + age limit | Dev |
| R9 | First Edge Function introduces new ops surface | Medium | Medium | Single function, minimal privileges, documented deploy, shared convention with PR #48 | Dev |
| R10 | Vault secrets lost on restore | Low | Medium | Documented re-entry; unsubscribe fallback page | Admin |
| R11 | Staff misuse (wrong segment, wrong content) | Medium | Medium | Gérant cannot send; admin approval; counts-only preview; journal | CEO |
| R12 | No real staging | Medium | Medium | Throwaway DB + sandboxes; staging reassessment before Phase 7 | CEO |
| R13 | Draft SQL not yet validated | Certain (by phase rule) | Low | First Phase 2 task: run drafts on throwaway DB, fix, review | Dev |
| R14 | Merge conflicts with PR #46/#48 | Medium | Low | Sequence decisions before Phase 2 privacy/permissions work | CEO |
| R15 | Inconsistent Miami/postal addresses in messages | Medium | Medium | Variables/footers blocked until D-G/D-H | CEO |

---

## 7. Security verification plan (Phase 2 benches)

- Role-by-role refusal of every function (admin, gérant, employé, client, anon), including gérant refused
  on approve/resume/manage, and aal1 refusal once a factor exists.
- Ledger immutability (update/delete refused even as table owner without disabling the trigger).
- Staff grant impossible (check constraint) ; customer grant refused without approved text.
- Fingerprint: any field or template change after submission → approval refused / launch paused.
- Allowlist: in `essai` mode, a consenting non-allowlisted customer receives nothing.
- Caps: 4 concurrent workers never exceed global/campaign caps (count and USD).
- Brevo reserve arithmetic with simulated Auth/transactional volume.
- Webhook: wrong signature, replay, stale event → refused; STOP → suppression + withdrawal.
- Unsubscribe token: tampered/guessed token → `ok:false`, no information leak.
- Anon surface: only the two expected functions; `controle-securite.sql` whitelist updated.
- Regression: `essai-notifications.py`, `essai-accuses.py`, `essai-suivi-courriels.py`,
  `essai-mobile.py`, `essai-permissions.*` unchanged and green.
