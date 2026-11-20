#!/usr/bin/env python3
"""site_checks.py: the checks that read the owner's own site. Standard library only. Only reads.

    python site_checks.py ai-access --crawl search-work/crawl.json --out search-work/raw/ai-access.json
    python site_checks.py schema    --crawl search-work/crawl.json --out search-work/raw/schema.json
    python site_checks.py pages     --crawl search-work/crawl.json --services "drain cleaning,water heaters" [--areas "Springfield,Riverton"] --out search-work/raw/pages.json
    python site_checks.py answers   --crawl search-work/crawl.json --questions search-work/questions.json --out search-work/raw/answers-on-site.json
    python site_checks.py speed     --url https://example.com/ [--url https://example.com/services/] --out search-work/raw/speed.json
    python site_checks.py nap       --crawl search-work/crawl.json [--found search-work/raw/listings.json] --out search-work/raw/nap.json

Each command writes plain facts. The checking agents read these facts, look at the pages
themselves, and write the verdict. A script matching words is a first pass, not a judgment.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path
from urllib.parse import urljoin, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))
from searchlib import (ServiceError, api_base, die, http_json, load_json, page_words, read_keys, run_main,  # noqa: E402
                       save_json, share_covered, words_of)

PSI = api_base("PAGESPEED_BASE_URL", "https://www.googleapis.com")
# Who reads robots.txt for what. Checked November 2026 on Google's and OpenAI's crawler pages.
AGENTS = [
    ("Googlebot", "Google Search, including AI Overviews and AI Mode. Blocking it keeps you out of all of them."),
    ("Google-Extended", "Google's other AI products and training. It does not decide whether you show in Google Search or its AI answers."),
    ("OAI-SearchBot", "ChatGPT search. Blocked sites are not shown in ChatGPT search answers."),
    ("GPTBot", "OpenAI model training only. Blocking it does not hide you from ChatGPT search."),
]
BUSINESS_TYPES = re.compile(r"(business|organization|store|restaurant|service|contractor|plumber|electrician|dentist|physician|clinic|"
                            r"attorney|lawyer|legal|agency|shop|repair|salon|spa|hotel|cafe|bakery|gym|school|realestate|accounting|"
                            r"insurance|locksmith|roofing|hvac|moving|cleaning|automotive|autodealer|medical|veterinary|florist|"
                            r"homeandconstruction|generalcontractor|housepainter|professionalservice)", re.I)
PHONE = re.compile(r"(?:\+?1[\s.\-]?)?\(?\b(\d{3})\)?[\s.\-]?(\d{3})[\s.\-]?(\d{4})\b")
STREET = re.compile(r"\b\d{1,6}\s+(?:[A-Z][A-Za-z0-9.']*\s){1,5}(?:Street|St|Avenue|Ave|Road|Rd|Boulevard|Blvd|Drive|Dr|Lane|Ln|Way|"
                    r"Court|Ct|Place|Pl|Parkway|Pkwy|Highway|Hwy|Suite|Ste)\b\.?[^.\n]{0,60}")


def ok_pages(crawl) -> list:
    return [p for p in crawl.get("pages", []) if p.get("status") == 200 and "html" in (p.get("content_type") or "html")]


# ------------------------------------------------------------------ robots.txt, read per agent


def robots_groups(text):
    groups, agents, in_rules = [], [], False
    for raw in (text or "").splitlines():
        line = raw.split("#", 1)[0].strip()
        if ":" not in line:
            continue
        field, _, value = line.partition(":")
        field, value = field.strip().lower(), value.strip()
        if field == "user-agent":
            if in_rules:
                agents, in_rules = [], False
            if not agents:
                groups.append({"agents": agents, "rules": []})
            agents.append(value.lower())
        elif groups and field in ("allow", "disallow"):
            in_rules = True
            if value:
                groups[-1]["rules"].append((field == "allow", value))
    return groups


def allowed(groups, agent, url) -> tuple:
    """Most specific group for this agent, then longest match wins, as Google reads it."""
    me = agent.lower()
    chosen = [g for g in groups if me in g["agents"]]
    which = agent
    if not chosen:
        chosen = [g for g in groups if "*" in g["agents"]]
        which = "*"
    rules = [r for g in chosen for r in g["rules"]]
    parts = urlsplit(url)
    path = (parts.path or "/") + (("?" + parts.query) if parts.query else "")
    best, verdict = -1, True
    for allow, pattern in rules:
        regex = re.escape(pattern).replace(r"\*", ".*")
        if regex.endswith(r"\$"):
            regex = regex[:-2] + "$"
        if re.match(regex, path) and (len(pattern) > best or (len(pattern) == best and allow)):
            best, verdict = len(pattern), allow
    return verdict, (which if chosen else "none")


def fetch_text(url, limit=500_000) -> tuple:
    if urlsplit(url).scheme not in ("http", "https"):
        return 0, ""
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (compatible; SearchSkillCrawler/1.0; a site owner's own check)"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read(limit).decode("utf-8", "replace")
    except urllib.error.HTTPError as err:
        return err.code, ""
    except Exception:
        return 0, ""


def cmd_ai_access(args) -> int:
    crawl = load_json(args.crawl, "crawl")
    home = crawl.get("home_url") or crawl.get("start_url") or ""
    root = f"{urlsplit(home).scheme}://{urlsplit(home).netloc}/"
    status, text = fetch_text(urljoin(root, "/robots.txt"))
    groups = robots_groups(text if status == 200 else "")
    pages = ok_pages(crawl)
    sample = [home] + [p["url"] for p in sorted(pages, key=lambda p: -(p.get("inbound_links") or 0))[:8] if p["url"] != home]
    agents = []
    for agent, why in AGENTS:
        blocked = [u for u in sample if not allowed(groups, agent, u)[0]]
        agents.append({"agent": agent, "what_it_decides": why, "group_used": allowed(groups, agent, home)[1],
                       "home_allowed": home not in blocked, "blocked_sample_pages": blocked[:10]})
    facts = {
        "robots_txt": {"status": status, "found": status == 200, "lines": len(text.splitlines()) if status == 200 else 0},
        "agents": agents,
        "pages_read": len(crawl.get("pages", [])), "pages_ok": len(pages),
        "noindex_pages": [p["url"] for p in pages if p.get("noindex")][:30],
        "nosnippet_pages": [p["url"] for p in pages if p.get("nosnippet")][:30],
        "needs_javascript_pages": [p["url"] for p in pages if p.get("needs_javascript")][:30],
        "thin_pages": [p["url"] for p in pages if (p.get("word_count") or 0) < 150][:30],
        "sitemap_found": (crawl.get("sitemap") or {}).get("found", False),
        "broken_links": len(crawl.get("broken_links") or []),
        "blocked_for_our_reader": (crawl.get("blocked_by_robots") or [])[:20],
        "not_visible_here": ["Whether Google has indexed each page (Search Console, Pages report)",
                             "The Search generative AI setting in Search Console (Settings, Search generative AI), which must say Include",
                             "Blocks by a firewall or CDN that only bots see"],
    }
    save_json(args.out, facts)
    g = next(a for a in agents if a["agent"] == "Googlebot")
    print(f"robots.txt: {'found' if facts['robots_txt']['found'] else 'none (that means everything is allowed)'}. "
          f"Googlebot {'may read your home page' if g['home_allowed'] else 'is BLOCKED from your home page'}"
          + (f", blocked from {len(g['blocked_sample_pages'])} key pages" if g["blocked_sample_pages"] else "") + ".")
    print(f"Pages marked noindex: {len(facts['noindex_pages'])}. Pages that forbid snippets (so AI answers cannot quote them): "
          f"{len(facts['nosnippet_pages'])}. Pages that look built by JavaScript: {len(facts['needs_javascript_pages'])}. Saved to {args.out}")
    return 0


# ------------------------------------------------------------------ structured data


def types_of(obj) -> list:
    t = obj.get("@type")
    return [str(x) for x in (t if isinstance(t, list) else [t]) if x]


def cmd_schema(args) -> int:
    crawl = load_json(args.crawl, "crawl")
    pages = ok_pages(crawl)
    found, business, broken = [], [], []
    for p in pages:
        objs = p.get("jsonld") or []
        if any("@error" in o for o in objs):
            broken.append(p["url"])
        types = sorted({t for o in objs for t in types_of(o)})
        if types:
            found.append({"url": p["url"], "types": types})
        for o in objs:
            if any(BUSINESS_TYPES.search(t) for t in types_of(o)) or ("address" in o and "telephone" in o):
                fields = {k: bool(o.get(k)) for k in ("name", "address", "telephone", "url", "openingHoursSpecification", "geo",
                                                      "sameAs", "areaServed", "priceRange", "image")}
                fields["openingHours"] = bool(o.get("openingHours") or o.get("openingHoursSpecification"))
                phone = re.sub(r"\D", "", str(o.get("telephone") or ""))[-10:]
                shown = any(phone and phone in re.sub(r"\D", "", t)[-10:] for t in p.get("tels") or []) or (phone and phone in re.sub(r"\D", "", p.get("excerpt") or ""))
                business.append({"url": p["url"], "types": types_of(o), "name": str(o.get("name") or "")[:120], "fields": fields,
                                 "phone_matches_page": bool(shown) if phone else None})
    facts = {"pages_with_structured_data": found[:60], "business_blocks": business[:20], "broken_blocks": broken[:20],
             "pages_checked": len(pages),
             "faq_blocks": [f["url"] for f in found if "FAQPage" in f["types"]][:20],
             "notes": ["Google says structured data is not required for its AI answers and there is no special markup for them. "
                       "It still helps Google read who you are, and it must match what the page shows.",
                       "Google stopped showing FAQ rich results on May 7, 2026. FAQ markup does no harm, but it no longer earns a special result."]}
    save_json(args.out, facts)
    print(f"Structured data on {len(found)} of {len(pages)} pages. Business details block: {'yes, on ' + str(len(business)) + ' page(s)' if business else 'none found'}. "
          f"Broken blocks: {len(broken)}. Saved to {args.out}")
    return 0


# ------------------------------------------------------------------ service pages, location pages, answers on the site


def best_pages(topic, pages, limit=3) -> list:
    want = words_of(topic)
    scored = []
    for p in pages:
        head = page_words(p)
        body = words_of((p.get("excerpt") or "")[:3000])
        score = round(0.7 * share_covered(want, head) + 0.3 * share_covered(want, body), 2)
        if score > 0:
            scored.append({"url": p["url"], "title": p.get("title") or "", "score": score, "words": p.get("word_count") or 0,
                           "in_heading_or_address": share_covered(want, head) >= 0.6})
    return sorted(scored, key=lambda r: -r["score"])[:limit]


def cmd_pages(args) -> int:
    crawl = load_json(args.crawl, "crawl")
    pages = ok_pages(crawl)
    out = {"services": [], "areas": []}
    for kind, items in (("services", args.services), ("areas", args.areas)):
        for item in [s.strip() for s in (items or "").split(",") if s.strip()]:
            best = best_pages(item, pages)
            top = best[0] if best else None
            out[kind].append({"name": item, "has_own_page": bool(top and top["in_heading_or_address"] and top["words"] >= 150),
                              "best": best})
    save_json(args.out, out)
    for kind in ("services", "areas"):
        if out[kind]:
            have = sum(1 for r in out[kind] if r["has_own_page"])
            print(f"{kind.title()}: {have} of {len(out[kind])} have their own page by this first pass.")
    print(f"Saved to {args.out}. Read the best match for each yourself: a word match is a first pass, not a judgment.")
    return 0


def cmd_answers(args) -> int:
    crawl = load_json(args.crawl, "crawl")
    data = load_json(args.questions, "questions file")
    rows = data.get("questions") if isinstance(data, dict) else data
    pages = ok_pages(crawl)
    out = []
    for row in rows or []:
        q = row.get("q") if isinstance(row, dict) else str(row)
        if not q:
            continue
        want = words_of(q)
        heads = []
        for p in pages:
            for h in p.get("headings") or []:
                if want and share_covered(want, words_of(h.get("text"))) >= 0.6:
                    heads.append({"url": p["url"], "heading": h.get("text")})
        out.append({"q": q, "matching_headings": heads[:5], "best_pages": best_pages(q, pages)})
    save_json(args.out, {"questions": out})
    have = sum(1 for r in out if r["matching_headings"])
    print(f"{have} of {len(out)} questions have a heading on your site that looks like the question. Saved to {args.out}. "
          "Open the best pages and judge whether each question is really answered in plain words near the top.")
    return 0


# ------------------------------------------------------------------ speed, from Google's own PageSpeed service


def cmd_speed(args) -> int:
    key = read_keys().get("PAGESPEED_KEY")
    results = []
    for url in (args.url or [])[:5]:
        if urlsplit(url).scheme not in ("http", "https"):
            results.append({"url": url, "error": "not a web address"})
            continue
        query = {"url": url, "strategy": "mobile", "category": "performance"}
        if key:
            query["key"] = key
        try:
            status, data = http_json("GET", f"{PSI}/pagespeedonline/v5/runPagespeed?" + urllib.parse.urlencode(query), timeout=150,
                                     service="Google PageSpeed")
        except ServiceError as err:
            results.append({"url": url, "error": str(err)})
            continue
        if status != 200 or not isinstance(data, dict):
            msg = ((data or {}).get("error") or {}).get("message", "") if isinstance(data, dict) else ""
            results.append({"url": url, "error": f"PageSpeed answered with status {status}. {msg[:160]}".strip()
                            + (" Without a key Google limits how often this runs; a free key fixes that." if status == 429 else "")})
            continue
        lh = data.get("lighthouseResult") or {}
        audits = lh.get("audits") or {}
        score = ((lh.get("categories") or {}).get("performance") or {}).get("score")
        field = (data.get("loadingExperience") or {})
        results.append({"url": url, "score": round(score * 100) if isinstance(score, (int, float)) else None,
                        "largest_paint_seconds": round((audits.get("largest-contentful-paint") or {}).get("numericValue", 0) / 1000, 1) or None,
                        "layout_shift": (audits.get("cumulative-layout-shift") or {}).get("numericValue"),
                        "real_visitors": field.get("overall_category") or "not enough visits for Google to say"})
    save_json(args.out, {"strategy": "mobile", "pages": results})
    for r in results:
        print(f"{r['url']}: " + (r["error"] if r.get("error") else f"mobile score {r['score']}, main content shows in about {r['largest_paint_seconds']}s, "
                                   f"real visitors: {r['real_visitors']}"))
    print(f"Saved to {args.out}")
    return 0


# ------------------------------------------------------------------ name, address, phone


def digits(text) -> str:
    return re.sub(r"\D", "", text or "")[-10:]


def norm_name(text) -> str:
    text = re.sub(r"\b(llc|inc|co|company|corp|ltd|the)\b", " ", (text or "").lower())
    return " ".join(re.findall(r"[a-z0-9]+", text))


def cmd_nap(args) -> int:
    crawl = load_json(args.crawl, "crawl")
    pages = ok_pages(crawl)
    names, phones, addresses = {}, {}, {}
    for p in pages:
        for o in p.get("jsonld") or []:
            if o.get("name") and (BUSINESS_TYPES.search(" ".join(types_of(o))) or o.get("telephone")):
                names[str(o["name"])[:120]] = names.get(str(o["name"])[:120], 0) + 3
            if o.get("telephone"):
                phones[digits(str(o["telephone"]))] = phones.get(digits(str(o["telephone"])), 0) + 3
            addr = o.get("address")
            if isinstance(addr, dict):
                line = ", ".join(str(addr.get(k)) for k in ("streetAddress", "addressLocality", "addressRegion", "postalCode") if addr.get(k))
                if line:
                    addresses[line] = addresses.get(line, 0) + 3
        if p.get("site_name"):
            names[p["site_name"]] = names.get(p["site_name"], 0) + 2
        for t in p.get("tels") or []:
            if len(digits(t)) == 10:
                phones[digits(t)] = phones.get(digits(t), 0) + 2
        for m in PHONE.finditer(p.get("excerpt") or ""):
            phones["".join(m.groups())] = phones.get("".join(m.groups()), 0) + 1
        for m in STREET.finditer(p.get("excerpt") or ""):
            addresses[m.group(0).strip()[:120]] = addresses.get(m.group(0).strip()[:120], 0) + 1
    top = lambda d: [k for k, _ in sorted(d.items(), key=lambda kv: -kv[1]) if k][:5]  # noqa: E731
    facts = {"names_on_site": top(names), "phones_on_site": top(phones), "addresses_on_site": top(addresses)}
    if len(facts["phones_on_site"]) > 1:
        facts["note"] = "More than one phone number appears on the site. Check which one is the main line."
    if args.found:
        found = load_json(args.found, "listings file")
        listings = found.get("listings") if isinstance(found, dict) else found
        main_phone = facts["phones_on_site"][0] if facts["phones_on_site"] else ""
        main_name = norm_name(facts["names_on_site"][0]) if facts["names_on_site"] else ""
        rows = []
        for row in listings or []:
            problems = []
            if row.get("phone") and main_phone and digits(row["phone"]) != main_phone:
                problems.append(f"phone {row['phone']} does not match your site")
            if row.get("name") and main_name and norm_name(row["name"]) != main_name:
                problems.append(f"name '{row['name']}' differs from your site")
            if row.get("address") and facts["addresses_on_site"]:
                street = re.findall(r"\d+", facts["addresses_on_site"][0])[:1]
                if street and street[0] not in row["address"]:
                    problems.append(f"address '{row['address']}' does not match your site")
            if not row.get("found", True):
                problems.append("no listing found")
            rows.append({"site": row.get("site"), "url": row.get("url"), "problems": problems})
        facts["listings"] = rows
    save_json(args.out, facts)
    print(f"On your site: name {facts['names_on_site'][:1] or 'not found'}, phone {facts['phones_on_site'][:1] or 'not found'}, "
          f"address {facts['addresses_on_site'][:1] or 'not found'}.")
    if args.found:
        bad = [r for r in facts["listings"] if r["problems"]]
        print(f"Listings checked: {len(facts['listings'])}, with a mismatch or missing: {len(bad)}.")
    print(f"Saved to {args.out}")
    return 0


def main():
    ap = argparse.ArgumentParser(description="Checks that read your own site.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("ai-access", "schema", "pages", "answers", "nap"):
        one = sub.add_parser(name)
        one.add_argument("--crawl", required=True)
        one.add_argument("--out", required=True)
        if name == "pages":
            one.add_argument("--services", default="")
            one.add_argument("--areas", default="")
        if name == "answers":
            one.add_argument("--questions", required=True)
        if name == "nap":
            one.add_argument("--found", help="listings the agent found on other sites, to compare")
    sp = sub.add_parser("speed")
    sp.add_argument("--url", action="append", required=True)
    sp.add_argument("--out", required=True)
    args = ap.parse_args()
    return {"ai-access": cmd_ai_access, "schema": cmd_schema, "pages": cmd_pages, "answers": cmd_answers,
            "speed": cmd_speed, "nap": cmd_nap}[args.cmd](args)


if __name__ == "__main__":
    run_main(main)
