# GOSHIP EXPRESS — COMPLETE SEO AUDIT, COMPETITOR INTELLIGENCE & SEO STRATEGY

**Audit date:** 19 November 2026
**Site audited:** https://goshipexpress.net/ (live, Hostinger) and the repository `main` at commit `fbbec64` (the version that is live)
**Scope:** audit only. No page, file, database, DNS or account was changed. No paid tool or credit was used.
**Where this file lives:** `docs/seo/` (the `docs/` folder is excluded from deployment by `.github/workflows/deploy.yml`, so this report is never published on the website).

### How to read the evidence labels

Every conclusion carries one of these labels:

| Label | Meaning |
|---|---|
| **[VF] Verified fact** | Observed directly on the live site, in the repository, or in a public primary page, during this audit. |
| **[TM] Tool measurement** | A number produced by a tool run during this audit (crawler, Chromium lab test, Google autocomplete). Method stated. |
| **[CO] Competitor observation** | Seen on a competitor's public website or in public press, on 19/11/2026. |
| **[SR] Strategic recommendation** | My professional recommendation. Not a fact. |
| **[IC] Information requiring confirmation** | The owner (or a lawyer / customs broker) must confirm before anything is built on it. |

---

## Table of contents

1. Executive summary
2. Company SEO profile
3. Technical SEO audit (Phase A)
4. Competitor comparison (Phase B)
5. Keyword research (Phase C)
6. Content gap analysis (Phase D)
7. Recommended website architecture
8. Local SEO analysis (Phase E)
9. Backlink and authority analysis (Phase F)
10. Current SEO Skill Pack assessment (Phase G)
11. Missing skills and capabilities
12. Recommended GoShip-specific SEO architecture (skill pack design brief)
13. Prioritized implementation roadmap (Phase H)
14. Data limitations and information requiring owner confirmation
15. Sources and URLs

---

## 1. Executive summary

**The technical foundation is unusually good for a company of this size. The problems are business truth, language priority and authority, not code.**

### The five things that matter most

1. **The website advertises a route the owner says GoShip does not serve.** [VF] The live site has a dedicated landing page "Shipping packages from Miami to Haiti" in four languages (`/envoi-colis-haiti`, `/en/…`, `/es/…`, `/ht/…`), lists "Florida → Haiti" as one of "three routes we know by heart" on `/nos-services`, offers "Florida → Haiti" in the quote form on `/contacts`, gives Haiti air/sea transit times (3–5 days / 2–3 weeks) in the FAQ, and describes the company on `/a-propos` as shipping "between the United States and Haiti" without mentioning the Dominican Republic at all. Your brief says **USA → Haiti: NO**. Until this is resolved, every SEO effort on Haiti terms risks attracting customers for a service you do not sell. **Priority: Critical. Owner decision required before any Haiti-related SEO work.**

2. **The Dominican Republic → Haiti route may be affected by a new Haitian rule.** [CO] Haitian press (Le Nouvelliste, Vant Bèf Info, Linieros) reports a Ministry of Economy and Finance circular dated 30 September 2026 that forbids goods from third countries (for example US online purchases) from entering Haiti overland through the Dominican Republic; only goods made in the DR may still cross by land. [VF] The site currently says, on the DR and Haiti pages: "From Santo Domingo, a regular land transport also reaches Haiti, border formalities included" and "You can also route your shipments through Santo Domingo." **[IC] This must be checked by the owner with a customs broker before any DR → Haiti landing page is created or promoted.** I did not read the circular itself, only press reports of it.

3. **The site's default language is French, but the main market speaks Spanish.** [VF] The root URLs (`/`, `/tarifs`, `/faq`…) are French; Spanish, English and Haitian Creole live in `/es/`, `/en/`, `/ht/`. The hreflang `x-default` points to the French page, `og:locale` of the root is `fr_FR`, and all URL slugs in every language are French words (`/es/envoi-colis-republique-dominicaine`). You stated French is not a priority. [SR] Spanish should become the primary language for SEO decisions, content depth and link building; French should be kept but treated as secondary. Changing URLs is optional and risky; changing `x-default` and content priority is cheap.

4. **The brand is almost invisible and collides with another company.** [TM] A web search for "Goship Express" returned no page about GoShip Express at all; results were dominated by **GoShip.com** (a US freight marketplace) and unrelated "Go Express" businesses. [CO] Direct competitors (BM Cargo, EPS, Domex, Vimenpaq, Tupaq) all have Spanish press coverage, branch pages and years of history. GoShip has no observable press, directory or review footprint. Authority, not on-page SEO, is the long-term bottleneck.

5. **Local SEO is the cheapest growth lever and is untouched.** [VF] The site never mentions Santo Domingo Este or La Caleta, publishes no street address in the DR, and its only `LocalBusiness` schema describes the Medley (Florida) address with a customer-mailbox suffix ("Apt 46780"). [TM] Google autocomplete for Dominican users shows strong local demand: "courier santo domingo este", "courier en la caleta boca chica", "courier cerca de la caleta", "courier boca chica". **[IC]** Whether GoShip has a staffed customer-facing location in the DR (and its exact address) decides whether a Google Business Profile is possible.

### What is already good (verified)

- 116 public pages, all returning HTTP 200, no broken internal links, no redirect loops. [TM]
- Every indexable page has a unique title, a meta description, one H1, a self-referencing canonical, and a full reciprocal hreflang set (en, es, fr, ht, x-default). [TM]
- Content is in the HTML itself; JavaScript is not needed for Google to read it. [VF]
- Clean URLs, HTTPS with HSTS, `http`/`www` redirect to the canonical host, a correct 404 status, private pages `noindex`. [TM]
- Zero images without an `alt` attribute across the whole site. [TM]
- Mobile: no horizontal scroll; lab Cumulative Layout Shift ≈ 0. [TM]
- **GoShip is the only DR courier website in this sample with Haitian Creole content.** [CO] That is a genuine differentiator for the Haitian community living in the DR.
- Transparent public pricing (5 $/lb air, 10 $ service fee per invoice, worked examples) is clearer than most competitors. [CO]

### What I could not measure

No Google Search Console, no Google Analytics, no backlink tool, no search-volume tool, no Google Business Profile access, and PageSpeed Insights' shared quota was exhausted. Section 14 lists exactly what is missing and what access would close each gap. **No search volume in this report is a measured number.**

---

## 2. Company SEO profile

| Item | What the site says (VF) | Matches owner brief? |
|---|---|---|
| Legal name | "Goship Express LLC" (schema), "Goship Express" (titles) | [IC] confirm the exact public name to use everywhere |
| Domain | goshipexpress.net (apex canonical; `www` 301 → apex) | — |
| Hosting | Hostinger (`server: hcdn`, `platform: hostinger`); deployed from GitHub branch `hostinger` by `deploy.yml` | — |
| Miami warehouse | 8140 NW 74th Ave, Unit 3, Medley, FL 33166 (customer address line 2 "ABX-46780"; schema says "Apt 46780") | [IC] Is this GoShip's own premises or a suite inside a third-party warehouse? (see §8) |
| DR presence | "Santo Domingo — Center and redistribution" (no street address published) | [IC] Address? Santo Domingo Este / La Caleta? |
| Haiti presence | "Port-au-Prince — Office and delivery" | [IC] Still active? |
| Phones | +1 849 538-6262 (phone + WhatsApp, a DR number), +1 809 317-6686 (DR), 786 525-2944 (shown on the customer US-address card) | ✓ (consistent across pages) |
| Email | infos@goshipexpress.net | ✓ |
| Hours | Mon–Sat 8:00–18:00 (time zone not stated) | [IC] Which time zone? Which location? |
| Routes claimed | Florida → Haiti; Florida → Santo Domingo; Santo Domingo → Haiti (`/nos-services`, `/contacts`) | ✗ Florida → Haiti contradicts brief |
| Modes | Air (5 $/lb), sea (on quote) | [IC] Sea to DR confirmed? |
| Transit times | DR: 2–4 days air, 7–12 days sea. Haiti: 3–5 days air, 2–3 weeks sea. Miami registration 24–48 h | [IC] still accurate? |
| Fees | 10 $ service fee once per invoice; free locker; 30 days free storage | ✓ (matches `CLAUDE.md` billing rules) |
| Insurance | "Basic coverage included"; optional insurance on declared value | [IC] What exactly is covered? |
| Business quotes | "Quote in under 2 business hours, rate guaranteed 30 days" | [IC] |
| Languages | French (root), English, Spanish, Haitian Creole | French not a priority per brief |
| Apps | Android app (Google Play link on site) | [IC] iOS app live? (the site mentions App Store in e-mails per `CLAUDE.md`, not found on the homepage) |
| Social | Facebook /goshipexpress, Instagram /goshipexpressllc, TikTok /@goshipexpress.net (in schema `sameAs`) | [VF] TikTok URL answers 200; Facebook/Instagram redirect to login (not verifiable) |
| Analytics | Google Analytics 4 via `assets/js/mesure.js` on public pages | Access not shared |
| Moving / removals service | Not offered on the site | Not audited, per brief |

---

## 3. Technical SEO audit (Phase A)

### 3.1 Method

- **Crawler:** a Python crawler written for this audit (`scratchpad`, not in the repo) fetched `https://goshipexpress.net/sitemap.xml` (112 URLs), then followed every internal link. 116 unique pages crawled, one request at a time with a pause. [TM]
- **Redirect/status tests:** `curl` on 18 URL variants. [TM]
- **Performance:** PageSpeed Insights API was tried and **refused (shared daily quota exhausted)**. Instead: the preinstalled Chromium (Playwright), Pixel 5 emulation, 4× CPU slowdown, ~1.6 Mbps / 150 ms network, reading the browser's own LCP/CLS/FCP. **This is a lab approximation, not Lighthouse and not real-user (CrUX) data.** [TM]
- **Source:** the repository at `fbbec64` (identical to what is live), including the generator `outils/generateur/build.py` and `outils/traduire.py`. [VF]

### 3.2 Summary scorecard

| # | Area | Status | Worst priority |
|---|---|---|---|
| 1 | Architecture & URLs | Good structure, French slugs everywhere | Medium |
| 2 | Crawlability & indexability | Good | Low |
| 3 | robots.txt & sitemap | Good; sitemap has no `lastmod` | Low |
| 4 | Status codes & redirects | Good; one 2-hop chain; `.html` duplicates answer 200 | Low |
| 5 | Canonicals | Correct on all 112 indexable pages | — |
| 6 | Duplicate content | Home and Services repeat the same blocks | Medium |
| 7 | Missing / orphan pages | No orphans; missing commercial pages (see §6) | High |
| 8 | Titles & descriptions | Present and unique; positioning favours Haiti | **Critical** (business truth) |
| 9 | H1–H3 | One H1 each; generic home H1; headings used for styling in articles | Medium |
| 10 | Images & ALT | 0 missing ALT; stock photos hotlinked from Unsplash; no width/height on 192 images | Low |
| 11 | Internal linking | Strong site-wide; articles barely link to money pages | Medium |
| 12 | Broken links | None found | — |
| 13 | Mobile usability | Good (no overflow, tap targets OK) | Low |
| 14 | Core Web Vitals (lab) | LCP ≈ 3.5–3.7 s on home, ≈ 5 s on blog under throttling | Medium |
| 15 | HTTPS & security | HTTPS + HSTS; CSP partly differs from `_headers` | Low |
| 16 | Structured data | Only `LocalBusiness` on 2 page types; nothing else | High |
| 17 | Breadcrumbs | Visual on some pages, no `BreadcrumbList` | Low |
| 18 | Open Graph | Complete, but one generic stock image for every page | Low |
| 19 | International SEO / hreflang | Technically correct; strategically mis-prioritised | High |
| 20 | JS rendering | Content in raw HTML; no dependency on JS | — |

### 3.3 Detailed findings

Each finding: **What** · **URL** · **Why it matters / SEO impact** · **Priority** · **Fix** · **Verify**.

---

#### A-01 — Route claims contradict the confirmed service list · **Critical**

- **What [VF]:** The site markets Miami/Florida → Haiti as a core service:
  - Titles: "About Goship Express, Miami → Haiti shipping company" (`/en/a-propos`), "Sobre Goship Express, envíos de Miami a Haití" (`/es/a-propos`), "Shipping packages from Miami to Haiti" (`/en/envoi-colis-haiti`), "Blog: tips for shipping packages to Haiti" (`/en/blog`), "Services: packages Miami → Haiti and Santo Domingo" (`/en/nos-services`).
  - `/es/nos-services`: H2 "Tres rutas que conocemos de memoria" with H3 "Florida → Haití".
  - `/es/contacts`: quote form option "Florida → Haití"; "Puerto Príncipe — Oficina y entrega".
  - `/es/faq`: "A Haití: 3 a 5 días por avión, 2 a 3 semanas por barco"; "¿Entregan fuera de Puerto Príncipe? Sí…".
  - `/es/a-propos`: "transporte… entre Estados Unidos y Haití" (the DR is absent); "Aircargo shipping pou Ayiti" (Creole text left untranslated on the Spanish and English pages); fleet sign "MIA → PAP".
  - Schema `LocalBusiness.description`: "between the United States, Santo Domingo and Haiti"; `areaServed: ["US","HT","DO"]`.
- **Why:** Google ranks pages for what they say. These pages will (and are designed to) attract "shipping to Haiti from Miami" searches. Visitors who cannot be served bounce or complain; reviews and trust suffer; and advertising a service you do not sell can be a consumer-protection issue.
- **SEO impact:** Wasted crawl/ranking effort on the wrong intent; dilutes the Dominican Republic positioning that is your real business.
- **Fix [SR]:** Owner decides one of:
  - (a) **Haiti from the US is not offered:** remove "Florida → Haiti" everywhere; 301-redirect `/envoi-colis-haiti` (×4 languages) to the DR → Haiti page (if that route survives A-02) or to the DR page; rewrite `/a-propos`, titles, FAQ, schema description.
  - (b) **It is offered in some form** (for example via the DR): then the brief must be corrected, and the page must describe the real path accurately (subject to A-02).
- **Verify:** `grep -ri "haïti\|haiti\|ayiti" *.html en es ht` returns only accurate statements; a re-crawl shows no title/H1 claiming Miami → Haiti; Google Search Console (once connected) shows the Haiti page dropped or redirected.

#### A-02 — DR → Haiti overland claim may conflict with a 30/09/2026 Haitian circular · **Critical (legal/content)**

- **What [VF]:** `/es/envoi-colis-republique-dominicaine`: "Desde Santo Domingo, un transporte terrestre regular llega también a Haití, trámites fronterizos incluidos." `/es/envoi-colis-haiti`: "También puede hacer pasar sus envíos por Santo Domingo…". **[CO]** Le Nouvelliste ("Haiti blocks the transit of goods from third countries via the Dominican Republic") and Vant Bèf Info report a MEF circular of 30/09/2026: third-country goods may not enter Haiti overland via the DR; DR-made goods still may. A US forwarder's guide (Interworld Freight, 03/10/2026) states the same from 2 October 2026.
- **Why:** If correct, the site promotes a path that is now prohibited for US-bought goods. Publishing SEO pages on "envíos de Santo Domingo a Haití" for those goods would be harmful.
- **Priority:** Critical — blocks the DR → Haiti content plan.
- **Fix [SR]:** Owner + customs broker confirm what GoShip can legally carry DR → Haiti (for example DR-manufactured goods, documents, personal effects?) and under which regime. Then write content only for that.
- **Verify:** Written confirmation from the broker kept in `docs/`; landing page text matches it.

#### A-03 — French is the default language; Spanish is secondary in the URL structure · **High**

- **What [VF]:** Root `/` is French (`<html lang="fr">`, `og:locale fr_FR`); `x-default` in every hreflang set and in `sitemap.xml` points to the French URL; slugs in all languages are French (`/es/adresse-miami`, `/es/tarifs`, `/es/marchandises-dangereuses`, `/es/fermer-un-compte`, `/ht/envoi-colis-republique-dominicaine`).
- **Why:** `x-default` is what Google shows users whose language matches none of your versions; French is the least useful fallback for a US/DR market. Slugs are a minor ranking signal but a visible trust/CTR signal in Spanish results ("marchandises-dangereuses" looks foreign to a Dominican user). The root language also tends to accumulate the most internal and external links.
- **Priority:** High (x-default, content priority) / Medium (slugs).
- **Fix [SR]:**
  1. Quick: set `x-default` to `/es/` (or `/en/`) pages in `build.py` / `traduire.py` and the sitemap. Owner to choose.
  2. For **new** pages, use localized slugs per language (for example `/es/casillero-en-miami`, `/en/miami-address`, `/ht/adres-miami`), with the French version kept at the root.
  3. Optional later: migrate the 5–6 key Spanish landing pages to Spanish slugs with 301 redirects (one-to-one, updated hreflang, sitemap, internal links). Do not migrate everything at once.
- **Verify:** View source of `/es/tarifs`: `x-default` updated; `curl -I` old slug → single 301 → new slug; GSC "Page indexing" shows the new URLs indexed within weeks.

#### A-04 — Structured data is minimal · **High**

- **What [TM]:** Only the home and contacts pages (×4 languages) carry JSON-LD, one `LocalBusiness` node. No `Organization`/`WebSite`, no `Service`, no `Offer`/`PriceSpecification` for the published 5 $/lb rate, no `FAQPage` on `/faq`, no `Article`/`BlogPosting` on 11 articles, no `BreadcrumbList`. [CO] Domex's `/casillero-miami` has `Service`, `Offer`, `FAQPage`, `BreadcrumbList`, `Organization`; BM Cargo's `/personal` has `Service` + `UnitPriceSpecification`; EPS articles have `Article` + `Person`.
- **Why:** Structured data helps Google understand who you are (entity, brand disambiguation from GoShip.com), what you sell, and where. FAQ rich results are now limited to government/health sites, but `FAQPage` still clarifies content; `Article` with dates/author supports E-E-A-T.
- **Also [VF]:** `LocalBusiness.address.streetAddress` contains "Apt 46780" — a customer-mailbox suffix, not a business suite (the customer address card shows "ABX-46780"). This misdescribes the business location (see §8).
- **Fix [SR]:** Add, generated by `build.py`: `Organization` (logo, `sameAs`, `contactPoint` with languages es/en/ht/fr) + `WebSite` on all pages; `Service` with `areaServed` limited to confirmed routes and `offers` with `UnitPriceSpecification` on `/tarifs` and route pages; `FAQPage` on `/faq`; `BlogPosting` (headline, datePublished, dateModified, author/publisher) on articles; `BreadcrumbList` where a visual breadcrumb exists. Fix the Medley address once A-12/§8 is confirmed. Use `PostalAddress` for the DR location once confirmed.
- **Verify:** Google Rich Results Test and Schema.org validator on each template; GSC "Enhancements" report shows no errors.

#### A-05 — Homepage H1 and title are generic and Haiti-first · **High**

- **What [VF]:** H1 on `/es/` = "Envío<br>internacional" ("International shipping" on `/en/`); our text extractor reads it as "Envíointernacional" because the words are only separated by `<br>` (Google generally treats `<br>` as a break, so this is cosmetic, not proven harmful). Title: "Goship Express — Envío de paquetes: EE. UU., Haití, Santo Domingo".
- **Why:** The home page is the strongest page. Its H1 targets no searchable phrase. "Envío internacional" is extremely competitive and not what DR customers search ([TM] autocomplete shows "envíos de miami a república dominicana", "casillero en miami", "courier santo domingo").
- **Fix [SR]:** H1 along the lines of "Envíos de Miami a República Dominicana" with a sub-line about the free Miami locker; title leading with the main Spanish keyword then brand. Keep the visual design.
- **Verify:** Re-crawl; GSC queries for the home page shift toward DR terms within 4–8 weeks.

#### A-06 — Missing commercial and local pages · **High** — see §6 and §7 (no "casillero" page in Spanish wording, no USA-wide page, no business page, no DR local page, no prohibited-items-by-country page, no customs/tax explainer for DR).

#### A-07 — Home and Services duplicate each other · **Medium**

- **What [VF]:** `/es/` and `/es/nos-services` share the same sections and headings ("De la compra en línea a la puerta del cliente", the four service H3s, "¿Cómo comprar con GoShip Express?", "Por qué elegir Goship Express" + 5 H3s). On `/es/nos-services` the H1 is repeated verbatim as the first H2.
- **Why:** Two strong pages competing for the same intent; Google picks one, often not the one you want.
- **Fix [SR]:** Make `/nos-services` the hub that links to one page per service (locker, consolidation, air, sea, business, customs); keep the home page short with links into that hub.
- **Verify:** Similarity of main text < ~40% between the two pages; GSC shows distinct queries for each.

#### A-08 — Blog articles are generic and weakly connected · **Medium**

- **What [VF]:** 11 articles × 4 languages (335–1,364 words). Topics are generic ("What is a courier service", "Logistics trends 2026", "The impact of delivery services on e-commerce"). [TM] Each article receives links only from the blog index and its own language versions (4 inlinks); in the body, the only links to commercial pages are the site-wide footer/header. Article headings use H2/H3 for list items ("Ventajas…", "Menor costo por volumen."). Articles show a date (e.g. "17 jul. 2026") but no author. Images are Unsplash stock photos.
- **Why:** Generic articles rarely rank against large publishers and give no local relevance. Weak internal links waste whatever authority they earn.
- **Fix [SR]:** Re-angle the best 3–4 articles to DR-specific questions (customs threshold, Shein/Temu/Amazon to RD, air vs sea Miami → Santo Domingo), add contextual links to `/tarifs`, `/adresse-miami`, route page; add author (a real team member) and `BlogPosting` schema; use real warehouse photos. Retire or merge the weakest ("partenaire-colis-etranger" 335 words, "pourquoi-goship-express" 366 words) into stronger pages with 301s.
- **Verify:** Each article links to ≥ 2 commercial pages in body text; GSC impressions per article.

#### A-09 — Core Web Vitals: LCP needs improvement in the lab · **Medium**

- **What [TM] (lab, throttled mobile, repeated 2×):**

| Page | FCP | LCP | CLS | Transfer | Requests |
|---|---|---|---|---|---|
| `/` (warm) | 1.04–1.11 s | 3.48–3.71 s | 0.002 | 614 KB | 27 |
| `/en/` | 1.06 s | 3.60 s | 0.001 | 612 KB | 27 |
| `/es/` | 1.74 s | 3.56 s | 0 | 613 KB | 27 |
| `/es/envoi-colis-republique-dominicaine` | 1.34 s | 1.34 s | 0 | 216 KB | 18 |
| `/es/tarifs` | 1.47 s | 1.47 s | 0 | 216 KB | 18 |
| `/es/blog` | 1.43 s | 5.06 s | 0.061 | 796 KB | 22 |

  The first cold run of `/` measured LCP 6.7 s (DNS/TLS warm-up), so treat single numbers with caution. Google's "good" LCP threshold is 2.5 s at the 75th percentile of real users.
- **Why:** Page experience is a modest ranking factor but strongly affects conversion on the slower mobile connections common in the DR and Haiti.
- **Fix [SR]:** Home: check the LCP element (likely the hero photo) is the preloaded local WebP (already partly done in commit #64) and that nothing render-blocking precedes it. Blog: replace hotlinked 900-px Unsplash images with local WebP thumbnails with `width`/`height`; 192 images site-wide have no `width` attribute (mostly SVG flags in the language menu, low risk).
- **Verify:** PageSpeed Insights with a free personal API key, or Search Console "Core Web Vitals" field report once enough traffic exists (CrUX needs volume; the site may not qualify yet).

#### A-10 — Internal-link equity is evenly spread over utility pages · **Low**

- **What [TM]:** Every page links to 31 targets site-wide, including `/connexion`, `/inscription`, `/mon-compte` (noindex), `/fermer-un-compte`, legal pages. Money pages (route pages, tarifs, Miami address) get the same weight as "close an account".
- **Fix [SR]:** Keep account links in the header, but move "close an account", privacy, terms into a compact legal footer row; add contextual body links to money pages from blog/FAQ.
- **Verify:** Re-crawl inlink counts by page type.

#### A-11 — Sitemap has no `lastmod` · **Low**

- **What [VF]:** `sitemap.xml`: 112 URLs with full hreflang alternates (good), no `<lastmod>`.
- **Fix:** Generate `lastmod` from the git commit date of each source page in `build.py`. Submit the sitemap in GSC and Bing Webmaster Tools.
- **Verify:** GSC Sitemaps report shows "Success" and discovered URLs = 112.

#### A-12 — `.html` variants answer 200, and a 2-hop redirect chain exists · **Low**

- **What [TM]:** `/tarifs.html` and `/index.html` return 200 (the canonical tag points to the clean URL, as intended by `liens_propres.py` and documented in `CLAUDE.md`). `http://www.goshipexpress.net/` → `https://www.…` → `https://goshipexpress.net/` (two hops).
- **Why:** Canonicals handle the duplicates; it is a deliberate trade-off (one less round-trip for internal links). Two hops is harmless.
- **Fix [SR]:** Optional: 301 `*.html` → clean URL at the server, and one-hop `http://www` → `https://apex`. Only if it does not conflict with the local-file browsing the project relies on.
- **Verify:** `curl -sI` shows a single 301.

#### A-13 — Open Graph image is one generic stock photo for all pages · **Low**

- **What [VF]:** Every page shares `og:image` = an Unsplash photo (1200×630). `og:locale` is set per language (`es_DO`, `ht_HT`, `en_US`, `fr_FR`) — good.
- **Why:** Most GoShip traffic is likely to come through WhatsApp/Facebook shares in the DR/Haitian communities; a branded image with the route and price ("Miami → Santo Domingo · 5 $/lb") increases click-through.
- **Fix:** One branded OG image per key page, served locally.
- **Verify:** Facebook Sharing Debugger / WhatsApp preview.

#### A-14 — Breadcrumbs are visual only · **Low**

- **What [VF]:** `/es/a-propos` and articles show "Inicio › Blog"; no `BreadcrumbList` JSON-LD. Route/tarifs pages have no breadcrumb.
- **Fix:** Add `BreadcrumbList` with A-04.

#### A-15 — Security headers differ between hosting targets · **Low (not an SEO issue, noted for completeness)**

- **What [TM]:** Live (Hostinger) sends `content-security-policy: frame-ancestors 'self'; upgrade-insecure-requests`, HSTS, `X-Frame-Options: SAMEORIGIN`, `nosniff`. The stricter CSP in the repo's `_headers` (Netlify/Cloudflare format) does not apply on Hostinger; the per-page CSP is set by `build.py` (`csp()`), per `CLAUDE.md`. No SEO impact.
- **Note [VF]:** `/assets/js/config.js` is publicly served, as every browser app must; per `CLAUDE.md` it holds the publishable Supabase key. I did not open or reproduce its contents. `/outils/*.sql` and `/.htaccess` return 403.

#### A-16 — Indexable account pages · **Low**

- **What [VF]:** `/connexion` and `/inscription` (×4) are indexable with ~1,500 words of mostly form/UI text. `/mon-compte` and `/nouveau-mot-de-passe` are `noindex` (correct); `/admin` is `noindex, nofollow` and disallowed in robots.txt (correct).
- **Fix [SR]:** Keep `/inscription` indexable (it is a conversion page for "crear cuenta casillero"); consider `noindex` on `/connexion` and `/fermer-un-compte`.

#### A-17 — Brand/entity ambiguity · **High (off-site)**

- **What [TM]:** A web search for `"Goship Express" goshipexpress` returned GoShip.com (US LTL freight marketplace), "GO! Express" (Germany), Shopify "GoShip Carrier Rates", a Thai "GoExpress" — nothing about GoShip Express. A second search with Medley/Santo Domingo/Haiti also returned nothing about the company.
- **Why:** Google must recognise GoShip Express as a distinct entity before brand searches (the easiest traffic) reliably land on goshipexpress.net.
- **Fix [SR]:** Consistent name ("GoShip Express" vs "Goship Express" — pick one), `Organization` schema with `sameAs` to every official profile, Google Business Profile (if eligible), app-store listings linking back, directory citations, press mentions (§9).
- **Verify:** Search "GoShip Express República Dominicana" shows the site and profiles on page 1; GSC brand queries grow.

#### A-18 — Untranslated text in translated pages · **Medium**

- **What [VF]:** "Aircargo shipping pou Ayiti" (Creole + English) appears on `/es/a-propos` and `/en/a-propos`.
- **Fix:** Translate or remove (and correct per A-01). Add a translation QA step (see §11).

#### Not found / passed

- Broken internal links: **0** [TM]. Orphan pages: **0** among crawled pages [TM]. Pages in sitemap but not linked: 0. Pages linked but not in sitemap: only the four `noindex` `/mon-compte` pages (correct).
- Missing titles/descriptions/H1: **0** [TM]. Duplicate titles: **0** [TM].
- Meta robots blocking indexable pages: **none** [TM]. `X-Robots-Tag`: none [TM].
- Horizontal scroll on mobile: **none**; tap targets under 24 px: 0–2 per page [TM].
- JS dependence: main content is in the server HTML; word counts 270–1,370 per page were measured on raw HTML without running JavaScript [TM].

---

## 4. Competitor comparison (Phase B)

### 4.1 Who competes, and how

Classification is mine [SR], based on the observations below. Data observed on public homepages, robots.txt and sitemaps on 19/11/2026, one request per URL [CO].

| Company | Site | Class | Why |
|---|---|---|---|
| BM Cargo | bmcargo.com | **Direct** | Miami locker → DR, branches across DR, business services |
| EPS | eps.com.do | **Direct** | Miami locker → DR since 1989 (press), franchise network |
| Domex | domex.do | **Direct** | Miami (and Madrid) locker → DR, "+70 oficinas" |
| Vimenpaq (Grupo Vimenca) | vimenpaq.do | **Direct** | US/Europe locker → DR (vimenpaq.com is a parked domain for sale) |
| Tupaq | tupaq.com.do | **Direct** | Miami locker → DR, branches in Santo Domingo |
| Aeropost | aeropost.com | **Direct / international** | Locker for 30+ Latin American & Caribbean countries |
| CPS | cps-do.com (per forum) | **Direct (unverified)** | Site did not respond to our request; cannot audit |
| Shippex | shippex.net | **Indirect** (USA → Haiti) | Medley warehouse → Haiti, Turks & Caicos |
| Global Shopaholics | globalshopaholics.com/en-ht/ | **Indirect** (USA → Haiti) | Country landing page for Haiti |
| Eurosender | eurosender.com (…/shipping-dominican-republic-haiti) | **Indirect** (DR → Haiti search results) | Broker page ranking for the DR→Haiti lane |
| Shipito | shipito.com | **International benchmark** | Global package forwarder, 13 languages |
| Planet Express | planetexpress.com | **International benchmark** | Global package forwarder, Haiti guide content |
| MyUS | myus.com | Benchmark (not audited) | Did not respond to our request |

[TM] Autocomplete also surfaced many **local** DR couriers that matter for Santo Domingo Este searches: Priority Courier, QM Courier, Sendpack, Via Courier, Extreme Paq, Hola Courier, Laar Courier, Domipack, "Courier Andrés Boca Chica". They were not audited individually; they are the real **local-pack** competitors.

### 4.2 On-page comparison (homepages)

| | GoShip | BM Cargo | EPS | Domex | Vimenpaq | Tupaq | Aeropost | Shippex |
|---|---|---|---|---|---|---|---|---|
| Platform | Static HTML (own generator) | Webflow | WordPress | Custom | Custom | Webflow | Nuxt/Vue | Custom |
| Default lang | **fr** | es | es | es | (no `lang`) | es-DO | es (title in English) | en |
| Languages (hreflang) | en, es, fr, **ht**, x-default | en, es | en, es, x-default | en, es-DO, x-default | none | en, es, x-default | none | none |
| Title (home) | "Goship Express — Envío de paquetes: EE. UU., Haití, Santo Domingo" | "BMCargo \| Logística de transporte de mercancías a nivel mundial" | "Inicio - EPS" | "Domex — Courier y distribución en República Dominicana" | "Vimenpaq - Transporte de paquetería, carga y correspondencia." | "Tupaq Courier \| Casillero en Miami y Envíos a RD" | "International Shipping with aeropost…" | "Home \| Shippex" |
| H1 count / text | 1 / "Envío internacional" | 1 / "Worldwide Logistics" (English on ES page) | **3** | 1 | 1 | 1 | 1 / "¡Bienvenido a" | 1 / "Track a package" |
| JSON-LD types | LocalBusiness | Organization, AggregateRating | Organization, WebSite, Breadcrumb | Organization, Service, Offer, SearchAction | none | Organization, PostalAddress | none | none |
| Sitemap URLs | 112 | 265 | index (10 sub-sitemaps) | 376 | 30 | 74 | 756 (blog-heavy) | none found |
| Branch / location pages | none | `/sucursales` | `/sucursales-y-agencias/` | `/sucursales` (3,317 words) | `/oficinas/sucursales/` | `/sucursales` | — | — |
| Locker page | `/es/adresse-miami` | `/personal`, `/como-comprar` | `/e-shopping/` | `/casillero-miami` | `/servicios/casillero-estados-unidos/` | `/personal` | — | — |
| Public price per lb | **Yes** (5 $/lb + examples) | Yes in schema (`UnitPriceSpecification`) | `/tarifas/` | `/tarifas` (calculator) | not seen | — | — | — |
| FAQ schema | No | Yes (`/preguntas-frecuentes`) | (custom FAQ post types) | Yes (on `/casillero-miami`) | No | No | — | — |
| Blog | 11 generic articles | `/blog`, news | `/blog/` (seasonal: Black Friday, 11.11, Halloween) | `/blog` | none | `/blog/amazon`, `/blog/shein` | ~100+ articles, per-country guides | — |
| Business offer | short block on Services | `/corporativo`, BM Logistics | `/empresas/`, fulfillment | `/empresas` | `/vimenpaq-para-negocios/` | `/empresarial` | — | — |
| Haitian Creole | **Yes (only one)** | No | No | No | No | No | No | No |

### 4.3 Competitor-by-competitor notes [CO]

**BM Cargo** (bmcargo.com)
- Architecture: flat Spanish slugs (`/sucursales`, `/personal`, `/corporativo`, `/preguntas-frecuentes`, `/como-comprar`, `/seguros-de-mercancia`, `/regulaciones`, `/devolucion-gratuita`, `/envios-colombia`, `/envios-europa`), English copies under `/en/` with the same Spanish slugs.
- SEO weakness: identical meta description on several pages (home, `/personal`, `/preguntas-frecuentes`, `/sucursales` all start "Somos una empresa de logística…"); English H1 "Worldwide Logistics" on the Spanish home.
- Strength: `FAQPage` schema with a long FAQ (2,219 words), branch page with `Place`/`PostalAddress`, `AggregateRating` on home, `Service` + `UnitPriceSpecification` on `/personal`, app page, insurance page, promotions. Press: a 2019 elDinero report quoted 196 RD$/lb and 33 branches; the site now claims 68+ offices; their own corporate page claims 5 daily departures and 24 h delivery (search summary).
- Not appropriate for GoShip: branch-network and gift-list pages that presume dozens of offices.

**EPS** (eps.com.do)
- WordPress + qTranslate (en/es, x-default), Yoast-style `Article`/`Person`/`BreadcrumbList` schema.
- Content strategy: timely shopping articles ("Black Friday 2026", "11.11", "Halloween 2026") and a comparison article "¿Qué courier me conviene en República Dominicana?" (that page has **no H1 and no meta description** — a weakness).
- Trust: 35 years (Diario Libre 2024), "first Dominican courier certified for dangerous goods" (own article), franchises, `/politicas-de-retiros-y-reclamaciones/`, `/regulaciones-y-restricciones/`, `/servicio-de-retornos/`.
- Home has **three H1s** and a generic title "Inicio - EPS".

**Domex** (domex.do)
- The strongest technical SEO in the sample: descriptive titles ("Casillero en Miami gratis para República Dominicana | Domex", "Tarifas y precio por libra | Domex"), unique descriptions, `es-DO` hreflang, `Service`/`Offer`/`FAQPage`/`BreadcrumbList` on the locker page, a 1,464-word rates page with calculator, a 3,317-word branch locator.
- Trust: OEA (Authorized Economic Operator) certification (press: El Nuevo Diario), "+70 oficinas", lockers, loyalty points ("Domipuntos"), referrals, franchises, consular service.
- Claims 24–48 h Miami → DR delivery and home delivery — faster than GoShip's published 2–4 days. [SR] GoShip should not imitate this claim unless true; compete on clarity, consolidation and languages.

**Vimenpaq** (vimenpaq.do)
- Note: `vimenpaq.com` is a parked domain for sale; the real site is `vimenpaq.do`.
- Weak technical SEO: no `lang` attribute, no hreflang, no Open Graph, no JSON-LD; mixed-case URL duplicates in its sitemap (`/servicios/casillero-internacional` and `/servicios/casillero-internacional/`, percent-encoded accents).
- Strength: brand of Grupo Vimenca (a large financial group with 130+ offices per ZoomInfo), service pages per need (`casillero-estados-unidos`, `casillero-europa`, `carga-aérea`, `para-negocios`, `productos-restringidos`).

**Tupaq** (tupaq.com.do)
- Webflow; `es-DO`; title "Tupaq Courier | Casillero en Miami y Envíos a RD" (keyword-first, clear).
- Content: `/blog/amazon`, `/blog/shein` (store-specific guides), `/articulos-restringidos`, `/politica-de-entrega`, `/sucursales` (Diario Libre: branches in Julieta, Paraíso, Evaristo Morales, Gazcue, La Castellana, Las Praderas, San Isidro — the last one is in Santo Domingo Este).
- Many campaign pages (`/promoorlando`, `/concurso`, `/encuentra-a-boxy`) indexed in the sitemap — thin pages. Not appropriate for GoShip.

**Aeropost** (aeropost.com)
- Large regional benchmark: 756-URL sitemap mostly blog in en/es (store guides: Shein, Temu, Walmart, eBay; "what is de minimis value"; "pre-alert in shipping"; customs delays).
- Weakness: no hreflang, no JSON-LD on the home page, Spanish page with English title.
- Lesson [SR]: GoShip can own the **DR-specific** versions of these guides (Aeropost writes them per country only for some markets, e.g. Costa Rica).

**Shippex** (shippex.net) — indirect, USA → Haiti
- English only, title "Home | Shippex", H1 "Track a package", no sitemap found, no schema. Medley warehouse (8435 NW 68th St per a FlashHaiti directory listing) → Haiti and Turks & Caicos. Listed in the **FlashHaiti** business directory — a citation source GoShip could use if a Haiti service is confirmed.

**Global Shopaholics** — indirect, USA → Haiti
- One landing page per country (`/en-ht/`: "Shipping to Haiti from the USA | Free US Address"), hreflang for ~300 locales (over-engineered), Elementor/WordPress. Shows that "free US address + destination" country pages rank for diaspora terms.

**Eurosender** — indirect, DR → Haiti results
- Programmatic lane pages ("Shipping services from the Dominican Republic to Haiti (2026)") with `FAQPage` + `BreadcrumbList`. Thin but well structured; it ranks because few real carriers have a page for this lane. [SR] If (and only if) A-02 is cleared, a real DR → Haiti page from an operator with a physical DR center can outrank it.

**Shipito / Planet Express** — international benchmarks
- Shipito: 13 languages with `x-default`, 1,476-URL sitemap. Planet Express: pricing page, postage calculator, location pages, "Shipping from the USA to Haiti (guide)". Lesson: calculators and destination guides earn links.

### 4.4 What competitors do that GoShip does not

| Practice | Seen at | GoShip | Realistic for GoShip? [SR] |
|---|---|---|---|
| Branch / location page(s) with address, hours, map | BM Cargo, EPS, Domex, Vimenpaq, Tupaq | No | **Yes** — one page per real location (Medley, Santo Domingo/SDE, Port-au-Prince if active) |
| `FAQPage`, `Service`, `Offer`, `BreadcrumbList` schema | Domex, BM Cargo | No | **Yes** (A-04) |
| Store-specific guides (Amazon, Shein, Temu) | Tupaq, Aeropost, EPS | Generic only | **Yes** |
| Seasonal shopping content (Black Friday, 11.11) | EPS, Aeropost | No | Yes, light |
| Restricted-items page in Spanish wording | Tupaq, Vimenpaq, BM Cargo | Yes (`/marchandises-dangereuses`, French slug) | Improve, not duplicate |
| Price calculator | Domex | No (examples table) | Yes, simple JS calculator (no new rules: it must reuse `API.tarifs`) |
| Business / corporate landing page | All direct competitors | Block on Services page | **Yes** |
| Certifications/membership shown (OEA, ASODEC, dangerous goods) | Domex, EPS | None shown | **[IC]** only if true |
| Ratings/reviews markup | BM Cargo | No | Only with real, verifiable reviews |
| Promotions / loyalty | Domex, BM Cargo | GOPOINTS exists in back-end (`docs/programmes.md`) but nothing public | Later, when the programme is live |

### 4.5 What GoShip already does better

1. **Haitian Creole** — no DR competitor offers it. [CO]
2. **Transparent, simple pricing** with worked examples and the "one service fee per invoice" rule. [VF]
3. **Clean, fast, valid technical base**: unique titles/descriptions everywhere (BM Cargo duplicates descriptions; EPS has an article with no H1; Vimenpaq has no `lang`). [CO]
4. **Pre-alerts and carrier tracking** (Phase 4 "Mes colis en route") — a real product feature competitors advertise less clearly. [VF]
5. **Consolidation with 30 days free storage** explicitly stated. [VF]

### 4.6 Competitor strategies not appropriate for GoShip [SR]

- Claiming 24 h delivery or "+70 offices" (not true for GoShip).
- Programmatic pages for hundreds of lanes (Eurosender, Global Shopaholics) — thin-content risk and GoShip serves 2–3 lanes.
- Indexing every promotion/contest page (Tupaq).
- Fake or unverifiable ratings markup.
- Pages for routes GoShip does not serve (USA → Haiti, Haiti → USA, Europe lockers).

---

## 5. Keyword research (Phase C)

### 5.1 Method and limits

- **No search volumes were measured.** No volume tool was available without payment or sign-in (Ahrefs and Similarweb connectors in this workspace require authorization; DataForSEO is paid; Google Keyword Planner needs the owner's Ads account).
- **Demand signals** come from Google Autocomplete (public `suggestqueries.google.com`), queried with the language and country of the searcher (`hl=es&gl=do`, `hl=en&gl=us`, `hl=ht&gl=ht`, `hl=fr&gl=ht`) on 19/11/2026. A suggestion means real people type that phrase often enough for Google to suggest it; its absence means low or no measurable demand. **This is a [TM] signal, not a volume.**
- "Difficulty" below is my qualitative estimate [SR] from who appears in results and how strong their pages are, not a tool score.

Legend: **AC** = appears in Google autocomplete [TM]; **—** = not suggested; **Idea** = my suggestion, untested.

### 5.2 The most important language finding

[TM] **Haitian Creole queries return no autocomplete suggestions at all** ("voye koli", "voye koli ayiti", "kago miami ayiti", "adrès miami", "voye bagay ayiti" → empty; "voye koli" even returned Serbian "voyage kolica"). French Haiti queries returned a few ("envoi colis haiti", "livraison haiti", "shein livraison haiti", "temu livraison haiti"); English Haiti queries returned many ("shipping to haiti from miami/new york/fort lauderdale…").

**Interpretation [SR]:** Haitians mostly *search* in French, English or (in the DR) Spanish, even if they *speak* Creole. Creole pages are valuable for **trust and conversion** (WhatsApp, social sharing, the Haitian community in the DR), not as a search-volume engine. The Creole strategy should be: complete, high-quality Creole for key conversion pages; do not expect Creole keyword traffic; measure in GSC before investing more.

### 5.3 Spanish (primary)

| Keyword | Intent | Signal | Est. difficulty [SR] | Relevance | Target page | Priority |
|---|---|---|---|---|---|---|
| envíos de miami a república dominicana | Commercial | AC (es-DO, es-US) | High | Core | `/es/envoi-colis-republique-dominicaine` (→ proposed `/es/envios-miami-republica-dominicana`) | P1 |
| envíos de cajas desde miami a república dominicana | Commercial | AC | Medium | Core [IC: does GoShip take boxes?] | DR route page section / proposed boxes page | P1 if confirmed |
| casillero en miami | Commercial | AC (dominated by other countries' variants) | High | Core | `/es/adresse-miami` (→ `/es/casillero-en-miami`) | P1 |
| courier con casillero en miami | Commercial | AC | Medium | Core | `/es/adresse-miami` | P1 |
| dirección en miami para compras | Commercial | AC | Medium | Core | `/es/adresse-miami` | P1 |
| como funciona un casillero en miami | Informational | AC | Medium | High | FAQ section + guide article | P2 |
| enviar paquetes a república dominicana | Commercial | AC | High | Core | DR route page | P1 |
| enviar paquetes de internet a república dominicana | Commercial | AC | Medium | Core | DR route page / locker page | P1 |
| como enviar paquetes de amazon a república dominicana | Informational→transactional | AC | Medium | High | Guide: "Comprar en Amazon y recibir en RD" | P1 |
| como comprar en amazon y enviar a república dominicana | Informational | AC | Medium | High | same guide | P1 |
| courier más barato en república dominicana | Commercial | AC | Medium | High | `/es/tarifs` (→ `/es/tarifas`) | P2 |
| precio por libra courier / couriers | Commercial | AC (+ competitor-branded: bm cargo, domex, eps, tupaq, cps, via, qm, priority, hola) | Medium | High | `/es/tarifs` + comparison-safe content ("cómo se calcula el precio por libra") | P1 |
| courier santo domingo | Local | AC | High | High | Proposed local page (SD/SDE) + GBP | P1 [IC] |
| courier santo domingo este | Local | AC (many local brands) | Medium | High | Local page SDE + GBP | P1 [IC] |
| courier la caleta / courier en la caleta boca chica / courier cerca de la caleta | Local | AC | **Low** | High | Local page La Caleta + GBP | P1 [IC] |
| courier boca chica | Local | AC | Low | Medium | Local page (if served) | P2 [IC] |
| courier en los mina | Local | AC | Low | Medium | Local page (if served) | P3 [IC] |
| cuanto cobra aduana por paquete / por un paquete de más de 200 dólares | Informational | AC | Medium | High | Guide: aduana RD y compras online | P2 [IC: rules must be checked] |
| temu república dominicana / shein república dominicana | Informational | AC (navigational for Temu) | High | Medium | Store guides | P3 |
| carga aérea miami / carga aérea marítima miami | Commercial (B2B) | AC | Medium | Medium | Business/cargo page | P2 |
| envío de cajas a república dominicana desde new york / new jersey / el bronx / philadelphia | Commercial | AC | Medium | **Only if USA-wide is confirmed** | Proposed "Desde cualquier estado de EE. UU." page | P2 [IC] |
| envíos a haití desde república dominicana | Commercial | AC | Low | **Blocked by A-02** | Proposed DR → Haiti page | Hold |
| envio de paquetes de santo domingo a haití; enviar paquetes a haití; carga a haití | Commercial | — | Low | Blocked by A-02 | — | Hold |

### 5.4 English

| Keyword | Intent | Signal | Est. difficulty | Target page | Priority |
|---|---|---|---|---|---|
| shipping from miami to dominican republic | Commercial | AC | High | `/en/` DR route page | P1 |
| shipping companies in miami to dominican republic | Commercial | AC | High | DR route page | P1 |
| shipping cargo to dominican republic from miami | Commercial (B2B) | AC | High | Business/cargo page | P2 |
| ship package / send packages to dominican republic | Commercial | AC | High | DR route page | P1 |
| ship boxes to dominican republic (near me) | Commercial/local | AC | High | [IC] boxes service | P2 |
| how much does it cost to send a package to dominican republic | Informational→commercial | AC | Medium | `/en/tarifs` | P1 |
| best way to ship package to dominican republic | Informational | AC | Medium | Guide | P2 |
| shipping to santo domingo / shipping from miami to santo domingo | Commercial | AC | High | DR route page | P1 |
| amazon shipping to santo domingo | Informational | AC | Medium | Amazon guide (en) | P2 |
| courier miami to dominican republic | Commercial | AC | Medium | DR route page | P1 |
| freight forwarder dominican republic | Commercial (B2B) | AC | High | Business page | P3 |
| does usps / dhl ship to dominican republic | Informational | AC | Medium | Guide ("USPS vs a Miami locker") | P3 |
| shipping from dominican republic to haiti | Commercial | AC | Low | **Hold (A-02)** | Hold |
| shipping to haiti from miami / from usa | Commercial | AC (en-HT) | — | **Do not target (route not served per brief)** | — |

### 5.5 Haitian Creole

| Keyword (idea) | Intent | Signal | Target page | Priority |
|---|---|---|---|---|
| voye koli Repiblik Dominikèn / voye koli Sen Domeng | Commercial | — (no autocomplete data) | `/ht/` DR route page | P2 (conversion, not volume) |
| adrès Miami gratis | Commercial | — | `/ht/adresse-miami` | P2 |
| pri pa liv | Commercial | — | `/ht/tarifs` | P3 |
| koryè Sen Domeng Ès / La Kalèt | Local | — | Creole version of local page | P3 |
| voye koli Sen Domeng pou Ayiti | Commercial | — | **Hold (A-02)** | Hold |

**Recommendation [SR]:** Write Creole pages for people, not for keywords; validate demand from GSC once connected (filter queries containing Creole words).

### 5.6 French (secondary)

| Keyword | Signal | Note |
|---|---|---|
| envoyer colis république dominicaine / … prix | AC (fr-HT) | Keep the French DR page; low priority |
| envoi colis haiti / livraison haiti | AC | Route not served from the US per brief — do not target |
| shein / temu / amazon livraison haiti | AC | Not served per brief |

### 5.7 Keywords grouped by type

- **Transactional:** crear cuenta casillero miami (idea), obtener dirección en miami (idea), cotización envío república dominicana (idea), "ship to dominican republic" (AC).
- **Commercial:** envíos de miami a república dominicana (AC), casillero en miami (AC), courier con casillero en miami (AC), shipping from miami to dominican republic (AC), precio por libra courier (AC), courier más barato en república dominicana (AC).
- **Informational:** como funciona un casillero en miami (AC), como enviar paquetes de amazon a república dominicana (AC), cuanto cobra aduana por paquete (AC), how much does it cost to send a package to dominican republic (AC), does usps ship to dominican republic (AC).
- **Local:** courier santo domingo este (AC), courier la caleta (AC), courier en la caleta boca chica (AC), courier boca chica (AC), courier santo domingo (AC), shipping to dominican republic near me (AC).
- **Long-tail:** envíos de cajas desde miami a república dominicana (AC), como comprar en amazon y enviar a república dominicana (AC), cuanto cobra aduanas por un paquete de más de 200 dólares (AC), shipping cargo to dominican republic from miami (AC).

### 5.8 Raw data

All autocomplete responses are saved in the audit scratchpad (`crawl/autocomplete.json`), not in the repository. They can be regenerated with the same seeds.

---

## 6. Content gap analysis (Phase D)

### 6.1 Missing pages (only for confirmed or plausibly confirmed services)

| Missing page | Why | Evidence | Status |
|---|---|---|---|
| **Location page: Santo Domingo / Santo Domingo Este / La Caleta** | Local searches, GBP landing page, trust | AC local terms; all 5 direct competitors have branch pages | **[IC]** address, hours, pickup allowed? |
| **Location page: Miami (Medley) warehouse** | "courier miami república dominicana", GBP if eligible | — | [IC] public visits allowed? |
| **Business shipping page** (`/es/envios-para-empresas`) | Every competitor has one; site mentions "empresas lo usan para sus abastecimientos" | CO | Confirmed in site text; [IC] details |
| **Customs & taxes for online purchases in RD** | High informational demand; trust | AC "cuanto cobra aduana…" | [IC] rules must be checked by a broker; do not invent the threshold |
| **Store guides: Amazon / Shein / Temu → RD** | AC demand; competitors rank with them | AC, CO (Tupaq, Aeropost, EPS) | OK — no new claims needed |
| **"Ship from anywhere in the USA" page** | You confirm USA → DR; queries from NY/NJ/Bronx | AC | [IC] how: customers ship to the Miami locker? box drop-offs? |
| **Price calculator** | Conversion; Domex has one | CO | Must reuse `API.tarifs` (rule in `CLAUDE.md`) |
| **Restricted items for the DR (Spanish slug)** | Existing page has French slug and generic content | VF | Improve existing page |
| **Air vs sea Miami → Santo Domingo** | Re-angle existing generic article | VF | Improve, not duplicate |
| **Reviews/testimonials page** | Trust | — | Only with real reviews [IC] |
| **DR → Haiti page** | Possibly unique (only Eurosender ranks) | CO | **Hold until A-02 is cleared** |

### 6.2 Pages to improve rather than duplicate

- `/es/envoi-colis-republique-dominicaine` — strongest asset; expand with: DR delivery zones, pickup vs home delivery, what happens at customs, FAQ block, local proof (photos of the Santo Domingo center), link to location page. Remove or rewrite the DR → Haiti paragraph (A-02).
- `/es/adresse-miami` — retitle around "casillero en Miami"; add "cómo llenar la dirección en Amazon/Shein" screenshots.
- `/es/tarifs` — add "precio por libra" phrasing, a calculator, sea-freight explanation, what "cobertura básica" covers [IC].
- `/es/faq` — remove Haiti-from-Miami answers (A-01), add `FAQPage` schema, add customs/tax and pickup questions.
- `/es/nos-services` — turn into a hub (A-07).
- `/es/a-propos` — rewrite around the real routes; add team, years in operation [IC], registration (DGA courier registry? [IC]), real photos.
- `/es/marchandises-dangereuses` — Spanish slug for new content; DR-specific restrictions [IC].
- Blog — re-angle (A-08).

### 6.3 FAQ opportunities (Spanish first)

¿Cómo funciona un casillero en Miami? · ¿Cuánto cuesta traer un paquete de Miami a Santo Domingo? · ¿Cobran por libra exacta o redondean? [IC] · ¿Qué pasa si mi compra supera 200 dólares? [IC] · ¿Puedo retirar en Santo Domingo Este / La Caleta? [IC] · ¿Hacen entrega a domicilio en Santo Domingo? [IC] · ¿Cuánto tiempo guardan mis paquetes? (30 días — VF) · ¿Puedo agrupar compras? (VF) · ¿Qué no puedo enviar? (VF, link) · ¿Cómo rastreo mi compra antes de que llegue a Miami? (VF — pre-alerts).

### 6.4 Trust and credibility content missing

- Legal identity (LLC state, DR company registration/RNC) [IC]; courier authorisation by the DR customs authority (DGA) [IC]; ASODEC membership [IC].
- Real photos (warehouse, team, vehicles) instead of stock images.
- Named people (founder/manager) on About and as article authors.
- Claims policy (lost/damaged package procedure) — competitors publish one (EPS, BM Cargo).
- Reviews from Google (after GBP), with a link to leave one.

### 6.5 Multilingual gaps

- Spanish is a translation of French, not the source (`outils/traductions/es.json` generated by `traduire.py`). [SR] Make Spanish the **source of truth** for DR pages (written by a Dominican-Spanish writer), and translate *from* Spanish.
- Creole: complete, but untranslated fragments exist (A-18); needs native-speaker review.
- English: serves the US diaspora/expat searches; keep.
- French: keep as-is; do not expand until GSC shows French demand.

---

## 7. Recommended website architecture

### 7.1 Principles [SR]

1. Only confirmed routes. Today: **Miami → DR**, **USA → DR** (via the Miami locker — [IC] mechanism). **DR → Haiti: on hold** (A-02). **USA → Haiti / Haiti → USA: none.**
2. Spanish first; English second; Creole for conversion; French kept.
3. New pages get localized slugs; existing URLs stay until a deliberate, redirected migration.
4. Every page is generated by `outils/generateur/build.py` / `traduire.py` (never hand-edit output HTML — see §10).

### 7.2 Proposed page tree (Spanish shown; each page has en/ht/fr equivalents)

```
/es/                                   Home — "Envíos de Miami a República Dominicana"
├── /es/envios-miami-republica-dominicana   (existing /es/envoi-colis-republique-dominicaine, 301 if migrated)
├── /es/envios-desde-estados-unidos         [IC] USA-wide → DR
├── /es/casillero-en-miami                  (existing /es/adresse-miami)
├── /es/tarifas                             (existing /es/tarifs) + calculator
├── /es/servicios                           hub (existing /es/nos-services)
│   ├── /es/servicios/consolidacion
│   ├── /es/servicios/carga-aerea
│   ├── /es/servicios/carga-maritima        [IC] sea to DR confirmed?
│   └── /es/envios-para-empresas
├── /es/sucursales                          locations hub [IC]
│   ├── /es/sucursales/santo-domingo-este   [IC] (or /la-caleta)
│   └── /es/sucursales/miami-medley         [IC]
├── /es/preguntas-frecuentes                (existing /es/faq)
├── /es/articulos-prohibidos                (existing /es/marchandises-dangereuses)
├── /es/guias/                              (existing /es/blog)
│   ├── /es/guias/comprar-en-amazon-y-recibir-en-republica-dominicana
│   ├── /es/guias/shein-temu-republica-dominicana
│   ├── /es/guias/aduana-compras-online-republica-dominicana   [IC]
│   ├── /es/guias/como-funciona-un-casillero-en-miami
│   └── /es/guias/aereo-o-maritimo-miami-santo-domingo
├── /es/sobre-nosotros                      (existing /es/a-propos)
└── /es/contacto                            (existing /es/contacts)
[HOLD] /es/envios-santo-domingo-haiti       only after A-02 is cleared
[REMOVE/REDIRECT] /es/envoi-colis-haiti     per A-01 decision
```

### 7.3 Page specifications (key pages)

| URL (es) | Lang | Main keyword | Intent | Objective | Recommended headings | Internal links | CTA | Type |
|---|---|---|---|---|---|---|---|---|
| `/es/` | es | envíos de miami a república dominicana | Commercial | Brand + main route | H1 "Envíos de Miami a República Dominicana"; H2 Su casillero gratis en Miami · Cómo funciona · Precio por libra · Entrega en Santo Domingo · Por qué GoShip · Rastrear | route, casillero, tarifas, sucursal, guías | Crear mi casillero gratis | Landing |
| `/es/envios-miami-republica-dominicana` | es | envíos de miami a república dominicana; enviar paquetes a república dominicana | Commercial | Rank + convert | H1 same; H2 Aéreo o marítimo · Cómo funciona · Aduana · Entrega en Santo Domingo y provincias · Precio · Preguntas | tarifas, casillero, sucursal, FAQ, guías | Crear cuenta / WhatsApp | Landing |
| `/es/casillero-en-miami` | es | casillero en miami; dirección en miami para compras; courier con casillero en miami | Commercial | Sign-ups | H1 "Casillero gratis en Miami para comprar en EE. UU."; H2 Cómo se ve su dirección · Cómo usarla en Amazon/Shein · Agrupar compras · Qué incluye · Preguntas | tarifas, guías Amazon/Shein, route | Obtener mi casillero | Service |
| `/es/tarifas` | es | precio por libra courier; cuánto cuesta enviar un paquete a república dominicana | Commercial | Price clarity | H1 "Tarifas: precio por libra de Miami a República Dominicana"; H2 Precio en breve · Calculadora · Ejemplos · Qué incluye · Marítimo con cotización | route, casillero, FAQ | Calcular / Crear cuenta | Service |
| `/es/sucursales/santo-domingo-este` [IC] | es | courier santo domingo este; courier la caleta | Local | Map pack + visits | H1 "GoShip Express en Santo Domingo Este (La Caleta)" [IC]; H2 Dirección y horario · Cómo llegar · Retiro de paquetes · Entrega a domicilio · Contacto | route, tarifas, contacto | Llamar / WhatsApp / Cómo llegar | Location |
| `/es/envios-para-empresas` | es | envíos para empresas miami república dominicana; carga aérea miami | Commercial B2B | Quotes | H1; H2 Abastecimiento desde Miami · Paletas y volumen · Cotización en 2 h [IC] · Aduana | contacto, servicios | Solicitar cotización | Service |
| `/es/guias/comprar-en-amazon-y-recibir-en-republica-dominicana` | es | como enviar paquetes de amazon a república dominicana | Informational | Top-of-funnel → sign-up | H1; H2 Paso 1 crear casillero · Paso 2 dirección en Amazon · Paso 3 pre-alerta · Paso 4 recibir en RD · Costos | casillero, tarifas, FAQ | Crear mi casillero | Blog article |
| `/es/guias/aduana-compras-online-republica-dominicana` [IC] | es | cuanto cobra aduana por paquete | Informational | Trust | H1; H2 Qué paga impuestos · Umbral [IC] · Quién se encarga · Ejemplo | tarifas, FAQ | Preguntar por WhatsApp | Blog article |
| `/es/preguntas-frecuentes` | es | preguntas frecuentes courier casillero miami | Informational | Reduce support, long-tail | H2 per theme; H3 per question | all money pages | Crear cuenta | FAQ |

English: `/en/shipping-miami-dominican-republic`, `/en/miami-address`, `/en/rates`, `/en/locations/santo-domingo-este`, `/en/business-shipping`, `/en/guides/…`. Creole: `/ht/voye-koli-repiblik-dominikèn` (ASCII slug `/ht/voye-koli-repiblik-dominiken`), `/ht/adres-miami`, `/ht/pri`. Final slugs to be decided with A-03.

---

## 8. Local SEO analysis (Phase E)

### 8.1 What exists [VF]

- One `LocalBusiness` node: Medley FL address "8140 NW 74th Ave, Unit 3, Apt 46780", phone +1-849 (a DR number), hours Mon–Sat 8–18, `areaServed` US/HT/DO.
- Contacts page names "Santo Domingo — Centro y redistribución" and "Puerto Príncipe — Oficina y entrega" **without addresses**.
- No page mentions Santo Domingo Este, La Caleta or Boca Chica.
- No Google Maps embed, no "how to get there", no GBP link, no review link.

### 8.2 Google Business Profile

- **Not verifiable from here.** Google Maps cannot be read by our tools without a browser session and Google search results did not show a GoShip profile. [IC] Owner to confirm whether a profile exists and who manages it.
- **Eligibility [SR, based on Google's published GBP guidelines]:** a profile needs a real location staffed during stated hours where customers can visit, or a service-area business that travels to customers. Virtual offices and mailboxes are not eligible.
  - **Medley:** the "Apt/ABX-46780" pattern suggests GoShip's Miami address may be a suite inside a third-party receiving warehouse. [IC] If so, **do not create a GBP for Medley**, and remove "Apt 46780" from the schema address in any case (it is the customer suffix).
  - **Santo Domingo / SDE / La Caleta:** the most valuable profile, if GoShip has staff and customers can pick up there. Category suggestion [SR]: "Courier service" (primary), "Shipping service" / "Freight forwarding service" (secondary) — check the exact Spanish category names in GBP.
  - **Port-au-Prince:** [IC] only if the office is active and consistent with the route decision (A-01).

### 8.3 NAP consistency

| Field | Site | Schema | Issue |
|---|---|---|---|
| Name | "Goship Express" | "Goship Express LLC" | Pick one display name for GBP/citations (no "LLC" in GBP name unless it is part of the real-world signage) |
| Address (US) | "8140 NW 74th Ave, Unit 3, Apt 46780" (contacts) / "Address 2 ABX-46780" (customer card) | "…Unit 3, Apt 46780" | Customer suffix used as business address [IC] |
| Address (DR) | none | none | Missing [IC] |
| Phone | +1 849 538-6262 everywhere; +1 809 317-6686 on contacts; 786 525-2944 on the customer address card | +1-849-538-6262 | Consistent; decide which number belongs to which location |
| Hours | Mon–Sat 8 a.m.–6 p.m. | same | Time zone missing (AST in DR vs ET in Miami) [IC] |

### 8.4 Local opportunities (ranked) [SR]

1. Confirm DR location → create/claim GBP → location page `/es/sucursales/…` with the same NAP, map embed, photos, hours → `LocalBusiness` (or `PostalService`/`Organization` with `department`) schema per location.
2. Apple Business Connect (Apple Maps) and Bing Places with identical NAP.
3. DR citations: Páginas Amarillas RD, ASODEC member directory [IC], Cámara de Comercio y Producción de Santo Domingo [IC], DGA courier registry listing [IC].
4. Reviews: ask every customer at pickup via WhatsApp with a direct review link; reply to all reviews (owner-approved).
5. Local content: "Courier en Santo Domingo Este: cómo retirar su paquete en La Caleta" only if true.

### 8.5 Needs owner verification

Exact DR address and whether customers can visit; GBP existence/ownership; Medley warehouse status; Port-au-Prince office status; hours per location; which phone per location; DGA courier authorisation; ASODEC membership.

---

## 9. Backlink and authority analysis (Phase F)

### 9.1 What could be measured

- **No backlink data was measured.** Ahrefs and Similarweb connectors exist in this workspace but require the owner's sign-in (and may consume plan units); no free tool gives reliable referring-domain counts. **I report no referring-domain numbers for anyone.**
- [TM] Two web searches for the brand returned zero pages mentioning GoShip Express. That suggests very few or no third-party mentions, but it is not a backlink count.

### 9.2 Competitor authority signals observed [CO]

| Competitor | Public trust/authority signals seen |
|---|---|
| BM Cargo | Press (elDinero 2019), Doral Chamber page, app, 68+ offices, AggregateRating markup |
| EPS | Diario Libre (35-year anniversary, 2024), Revista Mercado, foundation, franchises, dangerous-goods certification article |
| Domex | El Nuevo Diario (OEA certification), +70 offices, loyalty programme |
| Vimenpaq | Grupo Vimenca brand (Wikipedia page), 130+ offices (ZoomInfo) |
| Tupaq | Diario Libre launch article (2024) |
| Shippex | FlashHaiti directory listing |
| Aeropost | 40-year brand, Trustpilot (13,091 reviews on uk.trustpilot.com) |

### 9.3 Legitimate link and mention opportunities for GoShip [SR]

| Opportunity | Type | Effort | Condition |
|---|---|---|---|
| Google Play listing (exists) + App Store listing → link to site | Owned | Low | iOS [IC] |
| GBP, Apple Business Connect, Bing Places | Citations | Low | §8 eligibility |
| ASODEC membership directory | Industry | Medium | [IC] membership |
| DR Chamber of Commerce (Santo Domingo), Miami-Dade / Doral chambers | Business | Medium | Membership fee |
| Diaspora and community media (Dominican and Haitian outlets in Florida/NY; Le Nouvelliste partner content only if clearly labelled) | PR | Medium | A real story: Creole service, transparent pricing, app |
| Store guides cited by forums/expat groups (expat.com DR forum threads list couriers) | Earned | Medium | Genuine participation, no spam |
| Local partners: e-commerce sellers in Santo Domingo using GoShip for supply (site says businesses use the DR center) | Partnership | Medium | Customer consent |
| Local sponsorships (community events in Santo Domingo Este) | Local | Medium | Owner budget |
| FlashHaiti / Haitian business directories | Citation | Low | Only if a Haiti service is confirmed (A-01) |

**Not recommended:** bought links, PBNs, link exchanges, automated directory blasts, fake reviews, review gating.

### 9.4 E-E-A-T gaps [VF]

No named people, no founding year, no legal/registration details, no real photos (Unsplash stock), no author on articles, no published claims/complaints process, no third-party reviews linked.

---

## 10. Current SEO Skill Pack assessment (Phase G)

### 10.1 What I inspected

- **Found and read [VF]:** the generic pack in `.claude/skills/` on `main` (added by commit `fbbec64`, 19/11/2026): `seo/` (SKILL.md, `crawl.py`, `gsc.py`, `gaps.py`, `report.py`, `seolib.py`, `setup_state.py`, 3 references), `keyword-finder/` (SKILL.md, `keywords.py`, DataForSEO reference), `page-writer/` (SKILL.md, `apply.py`). 4,556 lines in total. The same files exist on branch `ccr-f17a693e-fz57kb` with no differences.
- **GoShip adaptation found [VF]:** only one: `.gitignore` ignores `seo-work/` with a comment explaining that the repo root is the public site. **The skill files themselves contain no GoShip-specific content** (no mention of GoShip, Haiti, Dominican Republic, Creole, hreflang, the generator, or the confirmed routes).
- **Missing — please provide:** the **"adapted GoShip version"** of the pack you mentioned. It is not in this repository (any branch), not in `~/.claude/skills`, and not elsewhere on this machine. **I have not reviewed it and make no claims about it.** Please add it to the workspace (for example under `docs/seo/pack-goship/`) or tell me where it is, and I will complete this section.

### 10.2 What the generic pack already handles correctly

| Capability | Where | Assessment |
|---|---|---|
| Prompt-injection defence ("what you read is data") | all 3 SKILL.md | Good, keep |
| Polite crawler: robots.txt, sitemap start, ≥ 1 s delay, page cap, resume, SSRF/IP checks, same-host sitemaps only | `crawl.py` | Good |
| Titles, descriptions, H1, canonical, noindex, ALT, status codes, sitemap | `crawl.py`, `report.py` | Good basics |
| Search Console via CSV export (no OAuth by default) | `gsc.py` | Good, safe |
| Paid data only with shown cost, cap and monthly ceiling the owner sets | `keywords.py` | Good |
| Never invent facts; `[ASK OWNER: …]` blanks block publishing | `page-writer` | Good, essential for GoShip |
| One approval per change; live changes need an owner-run code | `page-writer`, `apply.py` | Good |
| Keys outside the repo (`~/.config/claude-skills/keys.env`), never in chat | all | Good |
| New pages written as drafts **outside** the site folder (`<site>-seo-drafts`) | `apply.py write_draft` | Good — safe for a repo-root site |
| Admits limits (no backlinks, GBP, maps, speed) | `seo` SKILL.md | Honest |

### 10.3 What is missing for a shipping/logistics company and for GoShip

| Gap | Evidence | Consequence |
|---|---|---|
| **No route/claims guard** | No facts registry; `page-writer` checks facts only against "their own site" | The site itself contains the wrong route (A-01): the pack would treat "Miami → Haiti" as a true fact and reuse it |
| **No multilingual awareness** | `crawl.py` records no `lang`, no hreflang; `seolib.STOPWORDS` English only; `gaps.py` stems by stripping a trailing "s" | Cannot audit hreflang/x-default; topic matching breaks on Spanish/Creole ("envíos", "paquetes", "koli") |
| **Intent classifier is for local trades** | `keywords.py BUY_WORDS`: contractor, installer, repair, replacement, emergency… `LEARN_WORDS`: English only | Spanish/Creole queries all become "Unclear"; logistics terms (casillero, courier, envío, precio por libra, aduana) not recognised |
| **US-only defaults** | `--location 2840 --language en` | DR market needs DataForSEO location for the Dominican Republic (Google Ads geo ID 2214 — [IC] verify), Spanish; Haiti 2332 [IC verify] |
| **Not generator-aware** | `apply.py folder` edits the HTML file it finds | In this repo, `/es/*.html` etc. are **generated** by `outils/traduire.py` from `outils/traductions/*.json`, and root pages by `outils/generateur/build.py`. Direct edits are overwritten on the next build and bypass translations. The pack must edit the sources and rerun the generators |
| **No awareness that `main` = production** | `CLAUDE.md`: a push to `main` publishes the site | The pack says "it never commits or pushes", which is right; it should also refuse to touch `main` directly and use a branch + PR |
| No structured-data audit | — | Misses A-04 |
| No local SEO / GBP / NAP checks | Explicitly out of scope | Misses §8, the biggest lever |
| No competitor monitoring over time | `gaps.py` is one-shot | Cannot track competitor pages/rates/claims changes |
| No regulatory-claim check | — | Misses A-02 (customs/transit rules) |
| No translation-quality check | — | Misses A-18; Creole needs a human reviewer |
| No Core Web Vitals | Explicitly out of scope | Misses A-09 |
| No WordPress need | `page-writer` WordPress path, application passwords | Irrelevant for GoShip (static site) |

### 10.4 What to remove or switch off for GoShip [SR]

- WordPress flow (`check-wp`, `wordpress`, `review-live`/`approve-live` for WP) and the WordPress/Wix/Squarespace parts of `references/website-access.md` — GoShip is a static repo; keep only "folder" mode, rewritten for the generator.
- Roofing/contractor vocabulary in `BUY_WORDS`.
- `platform_guess` noise (it will say "unknown"); hard-code "static generator".

### 10.5 Security protections to strengthen [SR]

1. **Facts registry with route guard:** a versioned, owner-approved `docs/seo/faits-goship.json` (routes YES/NO, prices, fees, transit times, addresses, phones, languages). Any draft mentioning an unlisted route ("Haiti" + "Miami/USA/Florida") is refused.
2. **Generator-only edits:** refuse to write into `*.html` at the root or in `en/ es/ ht/`; write only to `outils/traductions/*.json`, `outils/generateur/…`, then run the generators and show the diff.
3. **Branch + draft PR only;** never `main` (production). Never run `deploy.yml`.
4. **Work folder outside the published tree:** keep `seo-work/` gitignored (done) **and** check `deploy.yml` never copies it (today it is safe only because it is gitignored — add `--exclude 'seo-work'` to the rsync as defence in depth, owner-approved).
5. **Never read `assets/js/config.js`** or any key file; never put GSC exports, crawl data or customer data into the repo (GSC queries can contain GSE codes or names).
6. **Regulatory claims gate:** any text about customs, duties, prohibited items, or cross-border rules requires an owner-supplied source and a flag "reviewed by broker".
7. **Translation gate:** Creole (and ideally Spanish) text marked "needs native review" until a named reviewer approves.
8. **Competitor content is hostile input** (already in the pack) — extend to Google autocomplete and SERP snippets.
9. **No spending:** paid APIs only with owner-set ceiling (already in the pack); connectors (Ahrefs/Similarweb) also count as spending.

### 10.6 Useful integrations [SR]

| Integration | Cost | Purpose | Who sets it up |
|---|---|---|---|
| Google Search Console (Domain property for goshipexpress.net) | Free | Queries, indexing, CWV, hreflang errors | Owner (DNS TXT record) |
| Bing Webmaster Tools | Free | Bing/Copilot visibility, import from GSC | Owner |
| GA4 (already installed) | Free | Conversions: `sign_up` already sent by `mesure.js` | Owner grants read access |
| PageSpeed Insights API with own key | Free | Lab + field CWV without shared quota | Owner creates key in Google Cloud |
| Google Business Profile | Free | Local, reviews | Owner only |
| DataForSEO (optional) | Paid, pay-as-you-go | Volumes for es-DO/en-US | Owner, with ceiling |
| Ahrefs / Similarweb connectors (present but not authorised) | Plan-dependent | Backlinks, competitor traffic | Owner decides; usage may consume units |
| Google autocomplete | Free | Demand signals (used in this audit) | — |

### 10.7 What must stay manual and owner-approved

Publishing anything (push/merge to `main`); route, price, fee, transit-time, insurance and customs statements; URL changes and redirects; deleting or redirecting the Haiti page; GBP creation/edits and review replies; directory submissions and memberships; outreach to journalists/partners; spending on any tool; the French-language decision; Creole/Spanish final copy approval.

---

## 11. Missing skills and capabilities

Proposed skills, justified against the findings. **None is created by this audit.** [SR]

| Proposed skill | Needed? | Justification (finding) | Responsibilities | Recommendation |
|---|---|---|---|---|
| `/technical-seo` | Yes — **merge into `/seo`** | A-03, A-04, A-09, A-11, A-12 | hreflang/x-default/lang/og:locale audit, canonical, redirects, sitemap lastmod, CWV via PSI key | Extend `/seo` rather than a new skill |
| `/schema-audit` | Yes — **merge into `/seo`** | A-04, §8 address | Validate JSON-LD per template; check NAP vs facts registry; propose `Organization`, `Service`, `Offer`, `FAQPage`, `BlogPosting`, `BreadcrumbList` | Part of `/seo` |
| `/multilingual-seo` + `/international-seo` | Yes — **one skill: `/multilingual-seo`** | A-03, A-18, §5.2 Creole finding | es/en/ht/fr parity (every page has 4 versions, same facts); slug policy; x-default; translation QA flags; Creole demand check in GSC; route consistency across languages | **New** — the most GoShip-specific need |
| `/local-seo` | Yes | §8, AC local terms | NAP consistency vs facts registry; location-page drafts; GBP checklist (owner executes); citations list; review-request templates (owner sends) | **New** |
| `/competitor-analysis` | Yes — **merge with monitoring** | §4 | Fixed competitor list; polite monthly snapshot of titles/H1/schema/sitemap size/prices/claims; diff report | **New: `/competitor-watch`** |
| `/seo-monitoring` | Yes — **merge into `/competitor-watch` + `/seo`** | §14 | Monthly GSC export comparison; indexed pages; CWV; alert on route-claim regressions | Part of the two above |
| `/seo-content-strategy` | Partly — **extend `/keyword-finder` + `/page-writer`** | §5, §6 | Keyword-to-page map per language; editorial calendar (Black Friday, 11.11, back-to-school for DR); briefs that cite the facts registry | Extend existing skills |
| `/keyword-finder` (existing) | Keep, adapt | §5 | Spanish/English/Creole intent lexicon for logistics; DR/US/HT locations; autocomplete harvesting (free) before paid data | Adapt |
| `/page-writer` (existing) | Keep, adapt | §10.3 | Generator-aware writes; facts registry gate; regulatory and translation gates; branch + PR | Adapt |

**Net proposal:** 3 existing skills adapted (`/seo`, `/keyword-finder`, `/page-writer`) + **3 new** (`/multilingual-seo`, `/local-seo`, `/competitor-watch`). Eight separate skills would overlap and multiply the places where safety rules must be kept in sync.

---

## 12. Recommended GoShip-specific SEO architecture (design brief for the future pack)

### 12.1 Shared foundation (used by every skill)

1. **`faits-goship.json` — the single source of business truth** (owner-approved, versioned in `docs/seo/`, never published):
   ```json
   {
     "routes": {"miami_rd": true, "usa_rd": true, "rd_haiti": "pending-legal", "usa_haiti": false, "haiti_usa": false},
     "prix": {"aerien_usd_lb": 5, "frais_service_usd_par_facture": 10, "maritime": "sur devis"},
     "delais": {"rd_aerien": "[ASK OWNER]", "rd_maritime": "[ASK OWNER]"},
     "lieux": [{"nom": "[ASK OWNER]", "adresse": "[ASK OWNER]", "visite_client": "[ASK OWNER]"}],
     "langues": {"es": "principale", "en": "secondaire", "ht": "conversion", "fr": "conservée"}
   }
   ```
   Prices must stay identical to `API.tarifs` in `assets/js/api.js` (a check, not a copy).
2. **Repository rules** (from `CLAUDE.md`): repo root = live site; `main` = production; generated pages; French code comments; no build step; no secrets.
3. **Safety rules** (from §10.5).

### 12.2 Skill responsibilities

| Skill | Reads | Writes | Never |
|---|---|---|---|
| `/seo` (adapted) | live site, repo, GSC export, PSI | `seo-work/` report | edits, pushes |
| `/keyword-finder` (adapted) | GSC, autocomplete, optional DataForSEO (owner ceiling) | `seo-work/keywords.json` | spends without cap |
| `/multilingual-seo` (new) | 4 language versions, `outils/traductions/*.json`, hreflang | report + translation-review list | approves its own translations |
| `/local-seo` (new) | facts registry, site NAP, schema | NAP report, GBP checklist, location-page draft | touches GBP or directories |
| `/competitor-watch` (new) | fixed competitor list (§4), ≤ 30 pages each, ≥ 2 s delay | monthly diff in `seo-work/` | logs in, scrapes private areas, copies text |
| `/page-writer` (adapted) | findings + facts registry | sources (`outils/…`) on a branch, then draft PR | `main`, generated HTML, unapproved claims |

### 12.3 Workflow

`/seo` → findings → `/keyword-finder` → keyword-to-page map → `/multilingual-seo` + `/local-seo` checks → `/page-writer` drafts (facts-gated, generator-aware) → owner approves each change → branch + draft PR → owner merges (= publish) → `/seo` re-crawl → monthly `/competitor-watch` + GSC comparison.

---

## 13. Prioritized implementation roadmap (Phase H)

Effort: S ≤ 0.5 day, M ≈ 1–3 days, L ≈ 1–2 weeks, XL > 2 weeks (developer + writer time; owner time not included).

### Quick wins (≤ 2 weeks, low risk)

| # | Task | Priority | Effort | Depends on | Benefit | Risk | Verify |
|---|---|---|---|---|---|---|---|
| Q1 | Owner decision on Haiti routes (A-01) and broker check (A-02) | Critical | S (owner) | — | Removes the biggest business/SEO risk | None | Written decision in `docs/seo/` |
| Q2 | Connect Google Search Console (Domain) + Bing Webmaster Tools; submit sitemap | Critical | S | DNS access (owner) | Real data for every later decision | None | GSC shows data after 2–3 days |
| Q3 | Fix route text, titles, FAQ, schema description per Q1 | Critical | M | Q1 | Accurate positioning | Traffic loss on Haiti terms (intended) | Re-crawl grep |
| Q4 | Remove "Apt 46780" from schema address; add `Organization` + `WebSite` schema | High | S | Q1, facts registry | Entity clarity, brand disambiguation | Low | Rich Results Test |
| Q5 | Change `x-default` from French to `/es/` (or `/en/`) | High | S | Owner choice | Better fallback for unmatched users | Low | View source + GSC International report |
| Q6 | Home H1/title Spanish keyword-first | High | S | — | Main keyword on strongest page | Low | Re-crawl; GSC queries |
| Q7 | Translate "Aircargo shipping pou Ayiti" leftovers | Medium | S | Q1 | Quality | None | grep |
| Q8 | Get a free PSI API key; measure CWV properly | Medium | S | Owner Google Cloud | Reliable performance data | None | PSI report |

### Phase 1 — Critical technical fixes (weeks 1–3)

| Task | Priority | Effort | Dependencies | Benefit | Risk | Verification |
|---|---|---|---|---|---|---|
| Q1–Q5 above | Critical/High | M | owner | — | — | — |
| `FAQPage`, `Service`+`Offer`, `BlogPosting`, `BreadcrumbList` in `build.py` | High | M | facts registry | Understanding, eligibility for rich features (limited) | Schema/content mismatch → must match visible text | Rich Results Test; GSC Enhancements |
| Sitemap `lastmod` | Low | S | — | Faster recrawl | None | GSC Sitemaps |
| Blog images local WebP + dimensions; check home LCP element | Medium | M | — | LCP | Visual regressions | PSI before/after |

### Phase 2 — Architecture and indexing (weeks 3–6)

| Task | Priority | Effort | Dependencies | Benefit | Risk | Verification |
|---|---|---|---|---|---|---|
| Redirect or rework `/envoi-colis-haiti` (×4) per Q1 | Critical | S | Q1 | Consistency | Redirect mistakes | `curl -I` one-hop 301; GSC |
| Services hub + de-duplicate home vs services | Medium | M | — | Clear intent per page | Content loss | Similarity check; GSC queries per page |
| Slug policy decision; Spanish slugs for new pages | Medium | S | owner | CTR/trust in Spanish | Mixed patterns (acceptable) | Review |
| Optional migration of 5–6 key Spanish URLs to Spanish slugs | Low–Medium | M | GSC baseline (≥ 4 weeks) | Slight CTR/relevance | Temporary ranking dip; broken hreflang if done partially | 301 map test; GSC coverage |
| Legal/utility pages: `noindex` on `/connexion`, `/fermer-un-compte` | Low | S | — | Crawl focus | None | View source |

### Phase 3 — Keyword strategy (weeks 4–6, data-dependent)

| Task | Priority | Effort | Dependencies | Benefit | Risk | Verification |
|---|---|---|---|---|---|---|
| Keyword-to-page map es/en/ht from GSC (first 4 weeks) + this audit's AC list | High | M | Q2 | Focus | Over-reliance on AC without volumes | Map reviewed by owner |
| Optional DataForSEO volumes for ~200 es-DO/en-US terms (≈ cents per request per the pack's own reference) | Medium | S | Owner budget/ceiling | Prioritise by volume | Third-party estimates | Spend log |

### Phase 4 — Landing pages and multilingual content (weeks 6–14)

| Task | Priority | Effort | Dependencies | Benefit | Risk | Verification |
|---|---|---|---|---|---|---|
| Rewrite/expand DR route page, Miami locker page, rates (+ calculator using `API.tarifs`) | High | L | Phase 3, facts | Core conversions | Wrong claims → facts gate | GSC impressions/clicks; GA4 `sign_up` |
| Business shipping page | High | M | owner details | B2B leads | Overpromising | Quote-form submissions |
| Location page(s) | High | M | §8 confirmations | Local pack | NAP mismatch | GBP insights; GSC local queries |
| Guides: Amazon→RD, Shein/Temu→RD, casillero explained, air vs sea MIA→SDQ, customs (after broker check) | Medium | L | facts, broker | Top-of-funnel | Regulatory errors | GSC per URL |
| Spanish as source language for DR pages; Creole native review | High | M (ongoing) | translator | Quality, trust | Cost | Reviewer sign-off |
| "From anywhere in the USA" page | Medium | M | [IC] mechanism | USA→DR demand (NY/NJ) | Wrong logistics promise | Owner confirmation |
| DR → Haiti page | Hold | M | A-02 cleared | Possibly low-competition lane | **Legal** | Broker letter |

### Phase 5 — Local SEO and authority (weeks 6–20)

| Task | Priority | Effort | Dependencies | Benefit | Risk | Verification |
|---|---|---|---|---|---|---|
| GBP creation/claim + photos + categories (owner) | High | S–M | eligibility | Map visibility for SDE/La Caleta | Suspension if ineligible | GBP verified |
| Apple Business Connect, Bing Places | Medium | S | GBP data | Consistency | None | Listings live |
| Review programme via WhatsApp (owner sends) | High | S + ongoing | GBP | Reputation | Policy breach if incentivised | Review count |
| Citations: Páginas Amarillas RD, ASODEC [IC], chambers [IC], app stores | Medium | M | NAP final | Entity/authority | Inconsistent NAP | Citation audit |
| PR: diaspora/community media story (Creole service, transparent pricing) | Medium | M | owner | Links + brand | Off-message | Mentions found |
| E-E-A-T: About page rewrite, real photos, named authors, claims policy | High | M | owner | Trust | — | Page live |

### Phase 6 — Competitor monitoring (from month 3)

| Task | Priority | Effort | Dependencies | Benefit | Risk | Verification |
|---|---|---|---|---|---|---|
| Monthly snapshot of 8–10 competitors (titles, H1, schema, sitemap size, public price/lb, claims) | Medium | S per month | `/competitor-watch` | Early warning | Over-crawling (keep caps) | Diff report |
| Track local-pack competitors for "courier santo domingo este" | Medium | S | GBP | Local positioning | — | Manual check |

### Phase 7 — Continuous optimisation (ongoing)

| Task | Priority | Effort | Benefit | Verification |
|---|---|---|---|---|
| Monthly GSC review: queries 4–20 position → title/description tests | High | S/month | CTR | GSC CTR change |
| Quarterly re-crawl with the adapted `/seo` (regression check incl. route-claim guard) | High | S/quarter | Quality | Report |
| Seasonal content (Black Friday, 11.11, back-to-school DR, Christmas) | Medium | S/season | Demand peaks | GSC |
| Translation parity check after every content change | High | S | Consistency | `/multilingual-seo` report |

### Long-term investments vs quick wins

- **Quick wins:** Q1–Q8, schema, x-default, home H1, sitemap lastmod, GSC/Bing.
- **Long-term:** location pages + GBP + reviews, Spanish-first content programme, authority/PR, optional URL migration, competitor watch.

---

## 14. Data limitations and information requiring owner confirmation

### 14.1 Data I could not access (and what would close the gap)

| Missing | Effect on this audit | Access needed (please authorise or provide) |
|---|---|---|
| Google Search Console | No indexing status, no real queries, no clicks, no hreflang errors | Owner adds a Domain property and grants read access, or exports Performance CSV (3 months) |
| Google Analytics 4 | No traffic, conversion or language split | Read-only access to the GA4 property used by `mesure.js` |
| Google Business Profile | Unknown if a profile exists | Owner confirms; Manager access only if desired |
| Backlink data | No referring-domain counts for anyone | Authorise the Ahrefs connector (note: may consume plan units) or accept "not measured" |
| Search volumes | All volumes absent; autocomplete only | Google Keyword Planner (owner's Ads account) or DataForSEO with a ceiling |
| Field Core Web Vitals | Lab approximation only | Free PSI API key; CrUX needs sufficient traffic |
| CPS and MyUS websites | Did not respond to our requests | — (not essential) |
| Google Maps / local pack | Not readable without a browser session | Owner screenshot of Maps results for "courier santo domingo este" from a DR phone |
| The adapted GoShip skill pack | §10 covers only the generic pack | **Please provide the file(s)** |
| The Haitian MEF circular itself | Known only through press | Owner/broker obtains the text |

### 14.2 Information requiring owner confirmation

1. **Routes:** Is any form of US → Haiti shipping offered (direct or via the DR)? Should `/envoi-colis-haiti` be removed/redirected? Is the Port-au-Prince office active?
2. **DR → Haiti:** What can legally be carried overland after the 30/09/2026 circular (DR-made goods only? documents? personal effects?) and by which regime?
3. **USA → DR mechanism:** Only via the Miami locker, or also box drop-offs/pick-ups in other states (NY, NJ…)?
4. **Sea freight to the DR:** offered? schedule? 7–12 days still accurate?
5. **Transit times:** 2–4 days air to the DR — still accurate? Exact or rounded weight billing?
6. **DR location:** exact address (Santo Domingo Este? La Caleta?), customer visits allowed, hours, time zone, phone.
7. **Medley address:** own premises or a suite in a third-party warehouse (ABX)? Can customers visit?
8. **Legal identity:** official display name (GoShip Express / Goship Express / Goship Express LLC), Florida LLC details, DR registration (RNC), DGA courier authorisation, ASODEC membership, any certification.
9. **Insurance:** what "basic coverage" covers and its limit.
10. **Business offer:** "quote in under 2 business hours, rate guaranteed 30 days" — confirmed?
11. **Customs:** who pays duties, how they are calculated, current DR threshold for online purchases (to be confirmed by a broker; not stated in this report).
12. **Languages:** confirm French stays as a secondary language at the root; who can review Creole and Dominican Spanish.
13. **Apps:** is the iOS app live (App Store URL)?
14. **Social profiles:** confirm the three `sameAs` URLs are the official, active accounts.
15. **Founding year, team names, real photos** available for E-E-A-T.

---

## 15. Sources and URLs

### GoShip Express (live, fetched 19/11/2026)

- https://goshipexpress.net/ · /es/ · /en/ · /ht/
- https://goshipexpress.net/es/envoi-colis-republique-dominicaine
- https://goshipexpress.net/es/envoi-colis-haiti
- https://goshipexpress.net/es/tarifs
- https://goshipexpress.net/es/adresse-miami
- https://goshipexpress.net/es/faq
- https://goshipexpress.net/es/contacts
- https://goshipexpress.net/es/a-propos · https://goshipexpress.net/en/a-propos
- https://goshipexpress.net/es/nos-services
- https://goshipexpress.net/es/blog · https://goshipexpress.net/es/article-maritime-vs-aerien
- https://goshipexpress.net/robots.txt · https://goshipexpress.net/sitemap.xml
- Repository: `outils/generateur/build.py` (`LOCAL_BUSINESS`, head generation), `outils/traduire.py`, `.github/workflows/deploy.yml`, `.gitignore`, `.claude/skills/*` at commit `fbbec64`.

### Competitors (fetched 19/11/2026)

- BM Cargo: https://www.bmcargo.com/ · /personal · /preguntas-frecuentes · /sucursales · https://bmcargo.com/en/corporativo · https://bmcargo.com/en/courier
- EPS: https://www.eps.com.do/ · /tarifas/ · /e-shopping/ · https://www.eps.com.do/que-courier-me-conviene-en-republica-dominicana-rapidez-confianza-y-cobertura-que-si-hacen-la-diferencia/
- Domex: https://domex.do/ · https://domex.do/casillero-miami · https://domex.do/tarifas · https://domex.do/sucursales
- Vimenpaq: https://vimenpaq.do/ · https://vimenpaq.do/servicios/casillero-estados-unidos/ · (parked) https://www.vimenpaq.com/
- Tupaq: https://www.tupaq.com.do/ · https://www.tupaq.com.do/personal
- Aeropost: https://aeropost.com/
- Shippex: https://shippex.net/ · directory: https://flashhaiti.com/business/detail/shippex-haiti-fast-secure-package-delivery-from-usa-to-haiti
- Global Shopaholics: https://globalshopaholics.com/en-ht/
- Eurosender: https://www.eurosender.com/en/gdd/shipping-dominican-republic-haiti
- Shipito: https://www.shipito.com/es/
- Planet Express: https://planetexpress.com/
- CPS (unreachable): https://www.cps-do.com/ (domain cited in https://www.expat.com/en/forum/central-america/dominican-republic/537935-can-someone-please-comment-on-all-the-various-courier-services-in-dr.html)

### Press and market context

- elDinero (2019), couriers in the DR: https://eldinero.com.do/83159/los-courier-en-republica-dominicana-luchan-en-precios-velocidad-y-servicio/
- Revista Mercado, couriers and e-commerce: https://www.revistamercado.do/negocios/el-impacto-de-los-couriers-en-el-comercio-electronico-dominicano
- Diario Libre, EPS 35 years (2024): https://diariolibre.com/revista/sociales/2024/10/12/eps-celebra-35-anos-de-innovacion-y-compromiso/2877442
- Diario Libre, couriers grow in the DR (2024): https://diariolibre.com/economia/negocios/2024/08/25/los-couriers-innovan-y-crecen-en-rd-frente-a-criticas/2826565
- Diario Libre, Tupaq launch (2024): https://diariolibre.com/revista/sociales/2024/03/15/tupaq-courier-una-innovadora-propuesta-de-envios/2644330
- El Nuevo Diario, Domex OEA certification: https://elnuevodiario.com.do/domex-expreso-obtiene-certificacion-como-operador-economico-autorizado-de-rd/
- News in America (2026), ~100 courier companies in the DR (ASODEC president): https://newsinamerica.com/pdcc/boletin/2026/empresas-couriers-aportan-mas-de-4500-empleos-en-republica-dominicana/
- Grupo Vimenca: https://en.wikipedia.org/wiki/Grupo_Vimenca

### Haiti transit rule (A-02)

- Le Nouvelliste, "Haiti blocks the transit of goods from third countries via the Dominican Republic": https://lenouvelliste.com/en/article/272553/haiti-blocks-the-transit-of-goods-from-third-countries-via-the-dominican-republic
- Le Nouvelliste, "Port sec et transbordement de marchandises à destination d'Haïti, l'État rappelle son interdiction": https://lenouvelliste.com/article/272568/port-sec-et-transbordement-de-marchandises-a-destination-dhaiti-letat-rappelle-son-interdiction
- Vant Bèf Info: https://vantbefinfo.com/haiti-interdit-le-transit-de-marchandises-de-pays-tiers-via-la-republique-dominicaine/
- Linieros: https://www.linieros.com/105184/haiti-vuelve-a-prohibir-el-ingreso-terrestre-de-mercancias-via-republica-dominicana/
- Hayti News (2025 precedent): https://www.haytinews.com/importations-via-la-rd-suspendues-lagd-durcit-les-mesures-aux-frontieres/
- Interworld Freight guide (03/10/2026): https://interwf.com/blog/shipping-to-haiti/

### Tools and methods

- Google Autocomplete endpoint: `https://suggestqueries.google.com/complete/search?client=firefox&hl=<lang>&gl=<country>&q=<query>`
- PageSpeed Insights API (attempted; quota exhausted): `https://www.googleapis.com/pagespeedonline/v5/runPagespeed`
- Chromium (Playwright) lab measurement: Pixel 5 profile, 4× CPU slowdown, ~1.6 Mbps / 150 ms.
- Raw evidence (crawl JSON, competitor JSON, autocomplete JSON, scripts) kept in the session scratchpad, **not** committed (it contains third-party page data).

---

*End of report. Nothing has been implemented. Awaiting the owner's review, the answers in §14.2, the adapted GoShip skill pack (§10.1), and explicit authorisation before any next step.*
