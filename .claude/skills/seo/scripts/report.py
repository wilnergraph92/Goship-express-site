#!/usr/bin/env python3
"""report.py: turn a crawl and Search Console numbers into one ranked list of fixes and a report.

    python report.py --crawl seo-work/crawl.json [--gsc seo-work/gsc.json] [--gaps seo-work/gaps.json]
                     [--keywords seo-work/keywords.json] --out seo-work

Writes seo-report.html and seo-report.md to read, and findings.json for the page-writer skill.

The ranking rule, stated in the report too: anything stopping Google outright comes first, then
fixes by estimated clicks a month at stake, then fixes with no numbers by how much they hurt.
Clicks at stake = times shown a month x (click rate at the position it could reach - click
rate it gets now). It is an estimate, never a promise.
"""
from __future__ import annotations

import argparse
import html
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from seolib import (CLICK_RATE, RATE_DEEPER, RATE_PAGE_TWO, click_rate, covered, load_json, page_key, page_words,  # noqa: E402
                    run_main, save_json, short_path, target_position, words_of)

MEANT_TO_BE_HIDDEN = re.compile(r"(thank|login|log-in|sign-?in|account|cart|checkout|admin|privacy|terms|search|tag/|author/|staging|test)", re.I)
TITLE_MAX, TITLE_MIN, DESC_MAX, DESC_MIN, THIN_WORDS = 60, 15, 160, 50, 150


def is_brand(query: str, host: str) -> bool:
    q = re.sub(r"[^a-z0-9]", "", query.lower())
    label = re.sub(r"[^a-z0-9]", "", host.lower().removeprefix("www.").split(".")[0])
    if len(q) < 4 or not label:
        return False
    return label.startswith(q) or label in q


def count_of(number, word, plural=None):
    """Say '1 page' and '3 pages', never 'page(s)'."""
    return f"{number:,} {word if number == 1 else (plural or word + 's')}"


def finding(kind, title, why, how, stake=None, basis="", severity=1, page=None, blocker=False, fix=None, extra=None):
    return {"kind": kind, "title": title, "why": why, "how": how, "clicks_at_stake": None if stake is None else round(stake),
            "basis": basis, "severity": severity, "page": page, "blocker": blocker, "fix_with": fix, **(extra or {})}


def duplicates(pages, field):
    seen = {}
    for page in pages:
        value = (page.get(field) or "").strip().lower()
        if value:
            seen.setdefault(value, []).append(page["url"])
    return {value: urls for value, urls in seen.items() if len(urls) > 1}


def cluster(rows):
    """Group near-identical searches so one missing page is one fix."""
    groups = []
    for row in sorted(rows, key=lambda r: -r["stake"]):
        words = words_of(row["query"])
        for group in groups:
            union = words | group["words"]
            if union and len(words & group["words"]) / len(union) >= 0.5:
                group["rows"].append(row)
                group["words"] |= words
                break
        else:
            groups.append({"words": set(words), "rows": [row]})
    return groups


def best_guess_page(query, candidates, position=100.0):
    """Which page a search most likely lands on, when the export does not say.

    A search on Google's first two pages has some page of theirs behind it, so a looser match
    will do. Further back, a loose match is more likely to be no real page at all.
    """
    need = 0.4 if position <= 20.5 else 0.6
    words = words_of(query)
    best, best_share = None, 0.0
    for page, own_words in candidates:
        if not words:
            break
        share = len(words & own_words) / len(words)
        if share > best_share:
            best, best_share = page, share
    return best if best_share >= need else None


def build(crawl, gsc=None, gaps=None, keywords=None) -> dict:
    pages = crawl.get("pages", [])
    host = crawl.get("host", "")
    months = float((gsc or {}).get("months") or 3)
    gsc_pages = {page_key(r["page"]): r for r in (gsc or {}).get("pages", [])}
    home_key = page_key(crawl.get("home_url", ""))
    out, leave_alone = [], []
    total_clicks_mo = None
    if gsc:
        all_clicks = (gsc.get("totals") or {}).get("clicks")
        if all_clicks is None:
            all_clicks = sum(r["clicks"] for r in gsc.get("pages", [])) or sum(r["clicks"] for r in gsc.get("queries", []))
        total_clicks_mo = all_clicks / months

    def row_for(page):
        return gsc_pages.get(page_key(page["url"])) or gsc_pages.get(page_key(page.get("final_url") or page["url"]))

    # ---- things that stop Google outright
    if crawl.get("robots", {}).get("blocks_everything"):
        out.append(finding("robots_all", "Your Robots File Tells Google To Stay Out Of The Whole Site",
                           "Your robots.txt file blocks every search engine, so Google is told not to read any page.",
                           "Remove the line that says Disallow: / from robots.txt. Your web person can do this in minutes.",
                           stake=total_clicks_mo, basis="all the clicks you get now", severity=10, blocker=True))
    home = next((p for p in pages if page_key(p["url"]) == home_key), None)
    if home and home["status"] != 200:
        out.append(finding("home_down", "Your Home Page Does Not Load For Google",
                           f"Your home page answered with status {home['status'] or 'no answer'}.",
                           "Ask your web host or web person to fix this first. Nothing else matters until it loads.",
                           stake=total_clicks_mo, basis="all the clicks you get now", severity=10, blocker=True,
                           page=home["url"]))
    if home and home.get("noindex"):
        out.append(finding("home_noindex", "Your Home Page Tells Google Not To List It",
                           "Your home page has a noindex tag, which tells Google to keep it out of search results. "
                           "This often gets left on by accident after a site is built.",
                           "Remove the noindex tag. On WordPress, check Settings, then Reading, and untick the box "
                           "that discourages search engines.",
                           stake=total_clicks_mo, basis="all the clicks you get now", severity=10, blocker=True,
                           page=home["url"]))

    # ---- page by page
    ok_pages = [p for p in pages if p["status"] == 200 and not p.get("redirect_chain") and "html" in (p.get("content_type") or "html")]
    dup_titles, dup_descs = duplicates(ok_pages, "title"), duplicates(ok_pages, "description")
    no_h1, many_h1, thin, orphans, alt_pages, chains, sitemap_bad = [], [], [], [], [], [], []

    for page in pages:
        url, status, row = page["url"], page["status"], row_for(page)
        path = short_path(url)
        is_home = page_key(url) == home_key
        if page.get("redirect_chain") and len(page["redirect_chain"]) >= 2:
            chains.append(url)
        if page.get("in_sitemap") and (status != 200 or page.get("redirect_chain") or page.get("noindex")):
            sitemap_bad.append(url)
        if status >= 400 or status == 0:
            if is_home:
                continue
            sources = next((b["from"] for b in crawl.get("broken_links", []) if b["target"] == url), [])
            stake = row["clicks"] / months if row else None
            out.append(finding("broken", f"Fix The Broken Page {path}",
                               f"This address answers with status {status or 'no answer'}. "
                               + (f"{len(sources)} of your own pages link to it. " if sources else "")
                               + ("Google still sends people here, and they land on an error." if row and row["clicks"]
                                  else "Anyone who follows a link here hits a dead end."),
                               "Send the address to the closest live page with a redirect, or bring the page back.",
                               stake=stake, basis="the clicks this address gets now" if row else "",
                               severity=8 if (sources or row or page.get("in_sitemap")) else 5, page=url,
                               extra={"linked_from": sources[:10]}))
            continue
        if status != 200 or page.get("redirects_off_site"):
            continue
        if "html" not in (page.get("content_type") or "html"):
            continue
        if page.get("noindex"):
            if is_home:
                continue
            meant = bool(MEANT_TO_BE_HIDDEN.search(path))
            stake = max(row["clicks"] / months, row["impressions"] / months * click_rate(row["position"])) if row else None
            out.append(finding("noindex", f"Page {path} Tells Google Not To List It",
                               "This page has a noindex tag, so it cannot show up in search."
                               + (" It may be hidden on purpose." if meant else " It looks like a page you want found."),
                               "If you want this page found, remove the noindex tag. If it is hidden on purpose, skip this.",
                               stake=stake, basis="the clicks this page could still be getting" if row else "",
                               severity=2 if meant else 9, page=url))
            continue
        canonical = page.get("canonical")
        if canonical and page_key(canonical) != page_key(page.get("final_url") or url):
            out.append(finding("canonical", f"Page {path} Tells Google To Credit A Different Page",
                               f"Its canonical tag points to {canonical}, so Google is told to ignore this page and "
                               "list that one instead.",
                               "If this page should rank by itself, point the canonical tag at the page's own address.",
                               stake=row["clicks"] / months if row else None,
                               basis="the clicks this page gets now" if row else "", severity=7, page=url))

        title, desc = (page.get("title") or "").strip(), (page.get("description") or "").strip()
        problems, worst = [], 0
        if not title:
            problems.append("no page title")
            worst = max(worst, 7)
        elif title.lower() in dup_titles:
            others = [short_path(u) for u in dup_titles[title.lower()] if u != url]
            problems.append(f"same title as {', '.join(others[:3])}")
            worst = max(worst, 5)
        elif len(title) > TITLE_MAX:
            problems.append(f"title is {len(title)} characters, so Google will likely cut it off")
            worst = max(worst, 2)
        elif len(title) < TITLE_MIN:
            problems.append(f"title is only {len(title)} characters and says very little")
            worst = max(worst, 3)
        if not desc:
            problems.append("no description")
            worst = max(worst, 4)
        elif desc.lower() in dup_descs:
            problems.append("same description as another page")
            worst = max(worst, 3)
        elif len(desc) > DESC_MAX:
            problems.append(f"description is {len(desc)} characters, so Google will likely cut it off")
            worst = max(worst, 2)
        elif len(desc) < DESC_MIN:
            problems.append(f"description is only {len(desc)} characters")
            worst = max(worst, 2)

        position = row["position"] if row else 0
        top_three = bool(row) and row["impressions"] > 0 and position <= 3.49
        gap = 0.0
        if row and not top_three and position <= 20:
            gap = row["impressions"] / months * max(0.0, click_rate(position) - row["ctr"])
        if top_three and title:
            leave_alone.append({"page": url, "position": round(position, 1), "clicks": row["clicks"]})
            problems = []
        if gap >= 1:
            detail = (f"Google shows this page about {row['impressions'] / months:,.0f} times a month at position "
                      f"{position:.1f}, but only {row['ctr'] * 100:.1f}% of people click, where about "
                      f"{click_rate(position) * 100:.0f}% is normal for that spot.")
            if problems:
                detail += " Also: " + "; ".join(problems) + "."
            out.append(finding("listing", f"Rewrite The Title And Description On {path}", detail,
                               "Use /page-writer to draft a new title and description, then say yes or no.",
                               stake=gap, basis=f"{row['impressions'] / months:,.0f} shown a month x "
                               f"({click_rate(position) * 100:.1f}% - {row['ctr'] * 100:.1f}%)",
                               severity=max(worst, 4), page=url, fix="page-writer", extra={"current_title": title}))
        elif problems:
            both = [w for w in ("title", "description") if any(w in x for x in problems)]
            out.append(finding("basics", f"Fix The {' And '.join(w.title() for w in both)} On {path}",
                               "On this page: " + "; ".join(problems) + ".",
                               "Use /page-writer to draft it, then say yes or no.",
                               severity=worst, page=url, fix="page-writer", extra={"current_title": title}))
        if not page.get("h1s"):
            no_h1.append(url)
        elif len(page["h1s"]) > 1:
            many_h1.append(url)
        if page.get("word_count", 0) < THIN_WORDS and not page.get("needs_javascript") and not is_home \
                and not MEANT_TO_BE_HIDDEN.search(path) and not re.search(r"contact|about|gallery", path, re.I):
            thin.append(url)
        if page.get("inbound_links", 0) == 0 and not is_home:
            orphans.append(url)
        if page.get("images_missing_alt"):
            alt_pages.append((url, len(page["images_missing_alt"])))

    # ---- problems that are easier to fix as a group
    def group(kind, title, why, how, urls, severity):
        if urls:
            out.append(finding(kind, title, why, how, severity=severity, extra={"pages": urls}))

    group("no_h1", "Add A Main Heading To Pages That Have None", f"No main heading (an H1) on {count_of(len(no_h1), 'page')}. It is one "
          "of the clearest signals of what a page is about.", "Add one heading at the top of each page that says what it is.", no_h1, 4)
    group("many_h1", "Use One Main Heading Per Page", f"More than one main heading on {count_of(len(many_h1), 'page')}, which blurs what the "
          "page is about.", "Keep one H1 and make the rest smaller headings.", many_h1, 2)
    group("thin", "Add Real Content To Very Short Pages", f"Under {THIN_WORDS} words on {count_of(len(thin), 'page')}. Google rarely ranks "
          "a page that barely says anything.", "Add what a customer needs to know, or merge the page into a stronger one.", thin, 4)
    if crawl.get("capped"):
        orphans = []  # the links on the unread pages may well point here
    group("orphans", "Link To Pages Nothing Links To", f"No links from the rest of your site to {count_of(len(orphans), 'page')}, which tells Google "
          "it is unimportant.", "Add a link to each from a related page.", orphans, 3)
    group("chains", "Shorten Redirect Chains", f"Two or more redirects in a row before landing, on {count_of(len(chains), 'address', 'addresses')}.",
          "Point the first address straight at the last one.", chains, 3)
    group("sitemap_bad", "Clean Up Your Sitemap", f"Problems on {count_of(len(sitemap_bad), 'address', 'addresses')} in your sitemap: broken, redirecting, or marked "
          "not to be listed. A sitemap should only list pages you want found.", "Remove them or fix them. Most site "
          "builders and SEO plugins regenerate this file on their own.", sitemap_bad, 3)
    if alt_pages:
        count = sum(n for _, n in alt_pages)
        out.append(finding("alt", "Add Alt Text To Images", f"No alt text on {count_of(count, 'image')} across {count_of(len(alt_pages), 'page')}. Google "
                           "cannot see a picture, and neither can a customer using a screen reader.",
                           "Add a short plain description to each image.", severity=2,
                           extra={"pages": [u for u, _ in alt_pages], "counts": {u: n for u, n in alt_pages}}))
    if not crawl.get("sitemap", {}).get("found") and pages:
        out.append(finding("no_sitemap", "Add A Sitemap", "I could not find a sitemap, the list of pages that helps Google find them all.",
                           "Most site builders make one with a setting. Add it, then submit it in Search Console.", severity=4))
    blocked = crawl.get("blocked_by_robots", [])
    blocked_with_data = [u for u in blocked if page_key(u) in gsc_pages]
    for url in blocked_with_data:
        row = gsc_pages[page_key(url)]
        out.append(finding("blocked", f"Page {short_path(url)} Is Blocked But Google Keeps Trying",
                           "Your robots.txt blocks this page, yet Search Console shows it getting shown in search.",
                           "If you want it found, remove the rule from robots.txt.", stake=row["clicks"] / months,
                           basis="the clicks this page gets now", severity=8, page=url))
    rest = [u for u in blocked if u not in blocked_with_data]
    if rest and not crawl.get("robots", {}).get("blocks_everything"):
        out.append(finding("blocked_group", "Check The Pages Your Robots File Blocks",
                           f"Your robots.txt blocks {count_of(len(rest), 'address', 'addresses')}. I did not read what is there, and Google will not either.",
                           "If any of these should be found, remove its rule from robots.txt.", severity=3, extra={"pages": rest}))

    # ---- searches
    queries = (gsc or {}).get("queries", [])
    pairs = (gsc or {}).get("query_pages", [])
    exact = {}
    for pair in sorted(pairs, key=lambda r: r["impressions"]):
        exact[pair["query"]] = pair["page"]
    readable = [p for p in ok_pages if not p.get("noindex")]
    candidates = [(p, page_words(p)) for p in readable]
    by_page, missing, shown_rows = {}, [], []
    for row in queries:
        impressions = row["impressions"] / months
        position = row["position"]
        brand = is_brand(row["query"], host)
        where, where_is_exact = None, False
        if row["query"] in exact:
            where, where_is_exact = exact[row["query"]], True
        else:
            guess = best_guess_page(row["query"], candidates, position)
            where = guess["url"] if guess else None
        shown_rows.append({**row, "page": where, "page_is_exact": where_is_exact, "brand": brand})
        if brand or position <= 3.49 or row["impressions"] <= 0:
            continue
        target = target_position(position)
        stake = impressions * max(0.0, click_rate(target) - row["ctr"])
        if stake < 0.5:
            continue
        if where:
            by_page.setdefault(page_key(where), {"url": where, "exact": where_is_exact, "rows": []})["rows"].append(
                {**row, "stake": stake, "target": target})
        else:
            missing.append({**row, "stake": stake, "target": target})

    for item in by_page.values():
        rows = sorted(item["rows"], key=lambda r: -r["stake"])
        stake = sum(r["stake"] for r in rows)
        named = "; ".join(f"\"{r['query']}\" (position {r['position']:.1f}, shown {r['impressions'] / months:,.0f} times a month)" for r in rows[:5])
        lead = rows[0]
        path = short_path(item["url"])
        out.append(finding("move_up", f"Move {path} Up For {len(rows)} Search{'es' if len(rows) != 1 else ''} You Almost Win",
                           f"You show up but too low: {named}."
                           + ("" if item["exact"] else " Which page each search lands on is my best guess, since the export does not say."),
                           "Make the page answer these searches directly, add links to it from related pages, and "
                           "use /page-writer to draft the new sections.",
                           stake=stake, basis=f"for \"{lead['query']}\": {lead['impressions'] / months:,.0f} shown a month x "
                           f"({click_rate(lead['target']) * 100:.1f}% at position {lead['target']} - {lead['ctr'] * 100:.1f}% now)" + (", plus the others" if len(rows) > 1 else ""),
                           severity=5, page=item["url"], fix="page-writer", extra={"searches": [r["query"] for r in rows]}))

    new_page_words = []
    for group_ in cluster(missing):
        rows = group_["rows"]
        stake = sum(r["stake"] for r in rows)
        lead = rows[0]
        new_page_words.append(group_["words"])
        also = f" Also: {', '.join(chr(34) + r['query'] + chr(34) for r in rows[1:4])}." if len(rows) > 1 else ""
        out.append(finding("missing_page", f"Write A Page For \"{lead['query']}\"",
                           f"People search this and Google shows you about {lead['impressions'] / months:,.0f} times a month at position "
                           f"{lead['position']:.1f}, but I found no page of yours that is about it.{also}",
                           "Use /page-writer to draft the page. It stays a draft until you approve it.",
                           stake=stake, basis=f"{lead['impressions'] / months:,.0f} shown a month x "
                           f"({click_rate(lead['target']) * 100:.1f}% at position {lead['target']} - {lead['ctr'] * 100:.1f}% now)"
                           + (", plus the others" if len(rows) > 1 else ""),
                           severity=6, fix="page-writer", extra={"searches": [r["query"] for r in rows]}))

    # ---- competitors
    keywords = keywords or {}
    volumes = {k.lower(): v for k, v in (keywords.get("volumes") or {}).items() if v}
    rival_rows = []
    for topic in (gaps or {}).get("topics", []):
        words = set(topic.get("words") or words_of(topic["topic"]))
        if any(len(words & w) / max(1, len(words | w)) >= 0.5 for w in new_page_words):
            continue
        volume = None
        for name, value in volumes.items():
            name_words = words_of(name)
            if name_words and len(name_words & words) / len(name_words | words) >= 0.6:
                volume = max(volume or 0, value)
        stake = volume * click_rate(8) if volume else None
        names = ", ".join(topic["competitors"][:3])
        rival_rows.append(topic)
        out.append(finding("rival_page", f"Competitors Have A Page On \"{topic['topic']}\" And You Do Not",
                           f"{names} {'has' if topic['competitor_count'] == 1 else 'have'} a page on this. I found nothing like it on your site. This is a "
                           + ("match on words" if topic.get("read", True) else "match on words in its address, since I did not read the page")
                           + ", so check it is really something you sell.",
                           "Use /page-writer to draft your own page, in your own words, about what you really offer.",
                           stake=stake, basis=f"{volume:,} searches a month x {click_rate(8) * 100:.1f}% at position 8" if volume else "",
                           severity=5 + min(3, topic["competitor_count"]), fix="page-writer",
                           extra={"searches": [topic["topic"]], "examples": [p["url"] for p in topic.get("pages", [])[:3]],
                                  "search_match": topic.get("search_match", 0), "read": topic.get("read", True)}))

    own_queries = {r["query"].lower() for r in queries}
    rival_keyword_rows = []
    all_words = set().union(*[w for _, w in candidates]) if candidates else set()
    for row in keywords.get("rival_keywords") or []:
        if row["keyword"].lower() in own_queries:
            continue
        words = words_of(row["keyword"])
        if any(covered(words, w) for _, w in candidates):
            continue
        rival_keyword_rows.append(row)
    for row in sorted(rival_keyword_rows, key=lambda r: -(r.get("volume") or 0))[:25]:
        volume = row.get("volume") or 0
        out.append(finding("rival_search", f"{row['rival']} Ranks For \"{row['keyword']}\" And You Do Not",
                           f"Position {row.get('position')} for them, about {volume:,} searches a month, from paid keyword data on your own account.",
                           "Use /page-writer to draft a page if this is something you sell.",
                           stake=volume * click_rate(8) if volume else None,
                           basis=f"{volume:,} searches a month x {click_rate(8) * 100:.1f}% at position 8" if volume else "",
                           severity=5, fix="page-writer", extra={"searches": [row["keyword"]]}))

    # ---- one problem repeated across many pages is one fix, not two hundred
    plain = [f for f in out if f["kind"] == "basics" and f["clicks_at_stake"] is None]
    same_title = {}
    for item in plain:
        if "same title as" in item["why"] and item.get("current_title"):
            same_title.setdefault(item["current_title"].lower(), []).append(item)
    for rows in same_title.values():
        if len(rows) > 3:
            for item in rows:
                out.remove(item)
            shown = rows[0]["current_title"]
            out.append(finding("same_title", f"{len(rows)} Pages Share The Title \"{shown}\"",
                               "Google cannot tell these pages apart from their titles. If they are translations or versions of one page, this is "
                               "one pattern to fix, not many separate jobs.",
                               "Use /page-writer to draft a title for each, or fix the pattern in your site's template.",
                               severity=5, fix="page-writer", extra={"pages": [r["page"] for r in rows]}))
    small = [f for f in out if f["kind"] == "basics" and f["clicks_at_stake"] is None and f["severity"] <= 3]
    if len(small) > 5:
        for item in small:
            out.remove(item)
        out.append(finding("basics_group", f"Tidy The Titles And Descriptions On {len(small)} Pages",
                           "Small problems on each: too long, so Google will cut them off, too short, or the same description as another page.",
                           "Use /page-writer to draft these in a batch, biggest pages first.",
                           severity=3, fix="page-writer", extra={"pages": [f["page"] for f in small]}))

    # ---- rank: blockers, then clicks at stake, then how much it hurts
    # With no search numbers, a fix that matches a search customers really type beats an alphabetical tie.
    out.sort(key=lambda f: (not f["blocker"], f["clicks_at_stake"] is None, -(f["clicks_at_stake"] or 0), -f["severity"],
                            not f.get("read", True), -f.get("search_match", 0), f["title"]))
    for i, item in enumerate(out, 1):
        item["rank"] = i

    hidden_share = None
    totals = (gsc or {}).get("totals")
    if totals and totals.get("clicks"):
        listed = sum(r["clicks"] for r in queries)
        hidden_share = max(0.0, 1 - listed / totals["clicks"])
    return {"findings": out, "leave_alone": leave_alone, "searches": shown_rows, "months": months,
            "hidden_click_share": hidden_share, "rival_topics": rival_rows, "rival_keywords": rival_keyword_rows,
            "low_position_share": _low_share(queries, host), "has_gsc": bool(gsc)}


def _low_share(queries, host):
    rows = [r for r in queries if not is_brand(r["query"], host)]
    total = sum(r["impressions"] for r in rows)
    return sum(r["impressions"] for r in rows if r["position"] > 10.5) / total if total else None


def clicks_text(item):
    value = item.get("clicks_at_stake")
    if value is None:
        return "No estimate: I have no search numbers for this one"
    if value < 1:
        return "Under 1 click a month at stake (estimate)"
    return f"About {value:,} click{'s' if value != 1 else ''} a month at stake (estimate)"


# ------------------------------------------------------------------ plain answers


def why_answer(crawl, gsc, result) -> dict:
    found = result["findings"]
    host = crawl.get("host", "your site")
    reasons = []

    def stake_of(kinds):
        return sum(f["clicks_at_stake"] or 0 for f in found if f["kind"] in kinds)

    blockers = [f for f in found if f["blocker"]]
    if blockers:
        reasons.append((10 ** 9, f"Google is being told to stay away, or cannot get in. {blockers[0]['why']}"))
    broken = [f for f in found if f["kind"] in ("broken", "noindex", "canonical") and f["severity"] >= 7]
    if broken:
        pages = ", ".join(short_path(f["page"]) for f in broken[:3] if f.get("page"))
        reasons.append((stake_of(("broken", "noindex", "canonical")) or 5,
                        f"Broken or hidden from Google: {count_of(len(broken), 'page')}, including {pages}."))
    low = result.get("low_position_share")
    if low is not None and low >= 0.25:
        reasons.append((stake_of(("move_up",)) or 4,
                        f"You show up, but too low. {low * 100:.0f}% of the times Google showed you for a search other than your own "
                        "name, you were on page 2 or further back, where very few people click."))
    listing = [f for f in found if f["kind"] == "listing"]
    if listing:
        reasons.append((stake_of(("listing",)) or 3,
                        f"People see you and skip you. On {count_of(len(listing), 'page')}, far fewer people click than that spot on Google "
                        f"should earn, which usually means the title and description give no reason to. Biggest: {short_path(listing[0]['page'])}."))
    missing = [f for f in found if f["kind"] in ("missing_page", "rival_page", "rival_search")]
    if missing:
        names = ", ".join(f["searches"][0] for f in missing[:3] if f.get("searches"))
        rivals = sorted({c for t in result["rival_topics"] for c in t["competitors"]})
        tail = f" Competitors like {', '.join(rivals[:3])} do have these pages." if rivals else ""
        reasons.append((stake_of(("missing_page", "rival_page", "rival_search")) or 3,
                        f"You have no page for things customers search for, like {names}.{tail}"))
    basics = [f for f in found if f["kind"] in ("basics", "listing") and ("no page title" in f["why"] or "no description" in f["why"])]
    if basics:
        reasons.append((1, f"Missing the title or description Google uses to write your listing: {count_of(len(basics), 'page')}."))
    reasons.sort(key=lambda r: -r[0])
    if not reasons:
        small = " The fixes below are small ones." if found else ""
        if result["has_gsc"]:
            short = (f"I did not find a clear fault on {host}. The basics are in place and the searches you show up for are "
                     f"already doing about what their positions should.{small} Growth from here means new pages and more sites linking to you.")
        else:
            short = (f"I did not find a clear fault on {host}, but without Search Console I cannot see which searches you show "
                     f"up for, so I can only speak to how the site is built.{small}")
        return {"short": short, "more": []}
    return {"short": reasons[0][1], "more": [r[1] for r in reasons[1:4]]}


def could_not_see(crawl, gsc, gaps, keywords, result) -> list:
    notes = []
    if not gsc:
        notes.append("Search Console. Without it I cannot see which searches you show up for, how many people see you, or who "
                     "clicks. So there are no click numbers, and every fix below is ranked by type of problem, not by money. It is free, and it is "
                     "the biggest upgrade: give me the export and I will re-rank them.")
    else:
        cap = gsc.get("row_cap", 1000)
        if gsc.get("queries_capped"):
            notes.append(f"Every search. Search Console stopped this list at {cap:,} rows, so smaller searches past that are not here.")
        else:
            notes.append(f"Every search, strictly. Search Console hides rare searches for privacy and keeps only its top rows ({cap:,} at most on this route).")
        hidden = result.get("hidden_click_share")
        if hidden is not None:
            notes.append(f"{hidden * 100:.0f}% of your clicks came from searches Search Console does not name.")
        if not gsc.get("query_pages"):
            notes.append("Which search lands on which page. The export lists searches and pages separately, so I matched them by words. "
                         "The optional Google sign in gives the exact match.")
        if gsc.get("months_assumed"):
            notes.append("The date range. The export did not say, so I assumed 3 months. If you picked another range, tell me and I will re-run the numbers.")
    if crawl.get("capped"):
        why_stopped = "The crawl did not finish" if crawl.get("finished") is False else f"I stopped at the page cap of {len(crawl.get('pages', []))}"
        notes.append(f"{crawl.get('pages_not_read', 0):,} more pages. {why_stopped}, so I also cannot say which pages nothing links to.")
    if crawl.get("blocked_by_robots"):
        notes.append(f"{count_of(len(crawl['blocked_by_robots']), 'address', 'addresses')} your robots.txt asks crawlers to skip. I obeyed.")
    needs_js = [p for p in crawl.get("pages", []) if p.get("needs_javascript")]
    if needs_js:
        notes.append(f"{count_of(len(needs_js), 'page')} that build their text with JavaScript, which I do not run. Their word counts and headings may be wrong.")
    if crawl.get("stopped_reason"):
        notes.append(crawl["stopped_reason"])
    notes.extend(n for n in crawl.get("notes", []) if n.startswith(("Refused to read", "Skipped a sitemap")))
    if not gaps:
        notes.append("Competitors. I did not compare any this time.")
    else:
        notes.append("Every search your competitors win. I compared the pages they have against yours, which shows topics, not rankings. Nobody can see a "
                     "competitor's Search Console." + ("" if (keywords or {}).get("rival_keywords") else
                     " The optional paid keyword data gets closer, and it is still an estimate."))
    notes.append("Links from other sites, your Google Business Profile, map results, and page speed. These matter, and this report does not measure them.")
    return notes


# ------------------------------------------------------------------ writing the report


def document(crawl, gsc, gaps, keywords, result) -> list:
    answer = why_answer(crawl, gsc, result)
    found = result["findings"]
    months = result["months"]
    doc = [("h1", f"Why Google Isn't Sending You Customers: {crawl.get('host', '')}"),
           ("note", f"Read {len(crawl.get('pages', []))} pages on {crawl.get('crawled_at', '')}. "
                    + ("Search numbers cover about " + (f"{months:g} months." if months != 1 else "1 month.") if gsc else "No Search Console data.")),
           ("lead", answer["short"])]
    if answer["more"]:
        doc.append(("ul", answer["more"]))
    doc.append(("h2", "What I Could Not See"))
    doc.append(("ul", could_not_see(crawl, gsc, gaps, keywords, result)))
    doc.append(("h2", "Every Fix, Biggest Wins First"))
    if not gsc:
        doc.append(("p", "No search numbers yet, so these are ranked by type of problem, not by money."))
    else:
        doc.append(("p", "Anything stopping Google outright comes first, then by clicks at stake. Each number is an estimate on its own "
                         "and some overlap, so do not add them up."))
    for item in found:
        doc.append(("fix", item["rank"], item["title"], clicks_text(item), item["why"], item["how"], item.get("basis", ""),
                    [short_path(u) for u in item.get("pages", [])][:15]))
    if not found:
        doc.append(("p", "Nothing to fix came up."))
    if result["leave_alone"]:
        doc.append(("h2", "Leave These Alone"))
        doc.append(("p", "These pages are already in the top three for their average search. Rewriting a page that is winning can lose it, so I will not suggest it."))
        doc.append(("table", ["Page", "Average Position", "Clicks"],
                    [[short_path(r["page"]), f"{r['position']:.1f}", f"{r['clicks']:,.0f}"] for r in result["leave_alone"]]))
    if result["searches"]:
        doc.append(("h2", "Every Search You Show Up For"))
        total = len(result["searches"])
        doc.append(("p", f"All {total:,} searches Search Console gave me, most shown first."
                    + ("" if gsc.get("query_pages") else " The page is my best guess by matching words.")))
        doc.append(("table", ["Search", "Clicks", "Times Shown", "Position", "Page"],
                    [[r["query"], f"{r['clicks']:,.0f}", f"{r['impressions']:,.0f}", f"{r['position']:.1f}",
                      short_path(r["page"]) if r["page"] else "No page found"] for r in result["searches"]]))
    if gaps or result["rival_keywords"]:
        doc.append(("h2", "What Your Competitors Have That You Do Not"))
        rivals = (gaps or {}).get("rivals_read") or []
        doc.append(("p", f"I read {(gaps or {}).get('rival_pages_read', 0)} pages on {', '.join(str(r) for r in rivals) or 'no sites'}. "
                         "This shows topics they cover, not where they rank."))
        left = (gaps or {}).get("more_topics_count", 0)
        aside = (gaps or {}).get("set_aside_count", 0)
        if left or aside:
            doc.append(("p", (f"This is the top {len((gaps or {}).get('topics', []))}. {left:,} more are in gaps.json. " if left else "")
                        + (f"I set aside {aside:,} that share no words with your business." if aside else "")))
        if result["rival_topics"]:
            doc.append(("table", ["Topic", "Who Has It", "Example"],
                        [[t["topic"], ", ".join(t["competitors"]), (t.get("pages") or [{}])[0].get("url", "")] for t in result["rival_topics"]]))
        if result["rival_keywords"]:
            doc.append(("h3", "From Paid Keyword Data"))
            doc.append(("table", ["Search", "Searches A Month", "Who Ranks", "Their Position"],
                        [[r["keyword"], f"{r.get('volume') or 0:,}", r["rival"], str(r.get("position"))] for r in result["rival_keywords"][:100]]))
    doc.append(("h2", "Every Page I Read"))
    doc.append(("table", ["Page", "Status", "Title", "Description", "Words", "Links In", "Images No Alt"],
                [[short_path(p["url"]), str(p["status"] or "none"), p.get("title") or "MISSING", "yes" if p.get("description") else "MISSING",
                  str(p.get("word_count", 0)), str(p.get("inbound_links", 0)), str(len(p.get("images_missing_alt") or []))]
                 for p in crawl.get("pages", [])]))
    doc.append(("h2", "How The Estimate Works"))
    doc.append(("p", "Clicks at stake = times Google shows you in a month x (the click rate at the position you could reach - the click rate you get now). "
                     "Pages on the first page are assumed to reach position 3, pages further back to reach position 8. A page or title fix "
                     "uses the normal rate for the position it already holds. It is an estimate for putting fixes in order, not a promise of traffic."))
    rates = [[str(k), f"{v * 100:g}%"] for k, v in CLICK_RATE.items()] + [["11 to 20", f"{RATE_PAGE_TWO * 100:g}%"], ["21 and lower", f"{RATE_DEEPER * 100:g}%"]]
    doc.append(("table", ["Position On Google", "Click Rate I Assume"], rates))
    doc.append(("p", "These are round numbers set near or a little under public click studies. Real rates swing a lot by search, and AI answers at the top of the page can cut them sharply."))
    return doc


def to_markdown(doc) -> str:
    out = []

    def cell(text):
        return str(text).replace("|", "/").replace("\n", " ")
    for block in doc:
        kind = block[0]
        if kind == "h1":
            out.append(f"# {block[1]}\n")
        elif kind == "h2":
            out.append(f"\n## {block[1]}\n")
        elif kind == "h3":
            out.append(f"\n### {block[1]}\n")
        elif kind == "note":
            out.append(f"*{block[1]}*\n")
        elif kind == "lead":
            out.append(f"**{block[1]}**\n")
        elif kind == "p":
            out.append(f"{block[1]}\n")
        elif kind == "ul":
            out.extend(f"- {line}" for line in block[1])
            out.append("")
        elif kind == "fix":
            _, rank, title, clicks, why, how, basis, pages = block
            out.append(f"\n**{rank}. {title}**\n")
            out.append(f"{clicks}." + (f" Worked out as: {basis}." if basis else "") + "\n")
            out.append(f"{why}\n")
            if pages:
                out.append("Pages: " + ", ".join(pages) + "\n")
            out.append(f"Fix: {how}\n")
        elif kind == "table":
            _, heads, rows = block
            out.append("| " + " | ".join(heads) + " |")
            out.append("|" + " --- |" * len(heads))
            out.extend("| " + " | ".join(cell(c) for c in row) + " |" for row in rows)
            out.append("")
    return "\n".join(out) + "\n"


STYLE = """
:root{--paper:#fff;--ink:#1b1b1b;--soft:#5f5f5f;--line:#e4e4e0;--accent:#b4441f}
@media (prefers-color-scheme:dark){:root{--paper:#161616;--ink:#eee;--soft:#a6a6a6;--line:#333;--accent:#e8835c}}
*{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font:17px/1.55 -apple-system,"Segoe UI",Helvetica,Arial,sans-serif}
main{max-width:760px;margin:0 auto;padding:40px 18px 80px}
h1{font-size:30px;line-height:1.2;margin:0 0 8px}h2{font-size:22px;margin:44px 0 10px;padding-top:18px;border-top:1px solid var(--line)}h3{font-size:18px;margin:26px 0 8px}
.note{color:var(--soft);font-size:14px;margin:0 0 20px}.lead{font-size:21px;line-height:1.4;font-weight:600;margin:0 0 14px}
ul{padding-left:20px}li{margin:6px 0}.fix{padding:16px 0;border-bottom:1px solid var(--line)}
.fix h3{margin:0 0 4px}.clicks{color:var(--accent);font-weight:600;margin:0 0 6px}.basis{color:var(--soft);font-size:14px;font-weight:400}
.fix p{margin:4px 0}.pages{color:var(--soft);font-size:14px;overflow-wrap:anywhere}.wrap{overflow-x:auto;margin:10px 0}
table{border-collapse:collapse;width:100%;font-size:14px}th,td{text-align:left;padding:6px 10px 6px 0;border-bottom:1px solid var(--line);vertical-align:top;overflow-wrap:anywhere}th{white-space:nowrap}
"""


def to_html(doc, title) -> str:
    esc = html.escape
    out = [f"<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
           f"<title>{esc(title)}</title><style>{STYLE}</style></head><body><main>"]
    for block in doc:
        kind = block[0]
        if kind in ("h1", "h2", "h3"):
            out.append(f"<{kind}>{esc(block[1])}</{kind}>")
        elif kind == "note":
            out.append(f"<p class=\"note\">{esc(block[1])}</p>")
        elif kind == "lead":
            out.append(f"<p class=\"lead\">{esc(block[1])}</p>")
        elif kind == "p":
            out.append(f"<p>{esc(block[1])}</p>")
        elif kind == "ul":
            out.append("<ul>" + "".join(f"<li>{esc(line)}</li>" for line in block[1]) + "</ul>")
        elif kind == "fix":
            _, rank, name, clicks, why, how, basis, pages = block
            out.append(f"<div class=\"fix\"><h3>{rank}. {esc(name)}</h3><p class=\"clicks\">{esc(clicks)}"
                       + (f" <span class=\"basis\">Worked out as: {esc(basis)}.</span>" if basis else "") + f"</p><p>{esc(why)}</p>"
                       + (f"<p class=\"pages\">Pages: {esc(', '.join(pages))}</p>" if pages else "")
                       + f"<p><strong>Fix:</strong> {esc(how)}</p></div>")
        elif kind == "table":
            _, heads, rows = block
            out.append("<div class=\"wrap\"><table><thead><tr>" + "".join(f"<th>{esc(h)}</th>" for h in heads) + "</tr></thead><tbody>"
                       + "".join("<tr>" + "".join(f"<td>{esc(str(c))}</td>" for c in row) + "</tr>" for row in rows)
                       + "</tbody></table></div>")
    out.append("</main></body></html>")
    return "".join(out)


def main():
    ap = argparse.ArgumentParser(description="Write the ranked SEO report.")
    ap.add_argument("--crawl", required=True)
    ap.add_argument("--gsc")
    ap.add_argument("--gaps")
    ap.add_argument("--keywords")
    ap.add_argument("--out", default="seo-work")
    args = ap.parse_args()
    crawl = load_json(args.crawl, "crawl")
    gsc = load_json(args.gsc, "Search Console file") if args.gsc else None
    gaps = load_json(args.gaps, "competitor comparison") if args.gaps else None
    keywords = load_json(args.keywords, "keyword file") if args.keywords else None
    result = build(crawl, gsc, gaps, keywords)
    doc = document(crawl, gsc, gaps, keywords, result)
    folder = Path(args.out)
    folder.mkdir(parents=True, exist_ok=True)
    save_json(folder / "findings.json", {"host": crawl.get("host"), "platform_guess": crawl.get("platform_guess"),
                                         "home_url": crawl.get("home_url"), **result})
    (folder / "seo-report.md").write_text(to_markdown(doc), encoding="utf-8", newline="\n")
    (folder / "seo-report.html").write_text(to_html(doc, f"SEO Report: {crawl.get('host', '')}"), encoding="utf-8", newline="\n")
    answer = why_answer(crawl, gsc, result)
    print(f"Why Google isn't sending customers: {answer['short']}")
    print(f"{len(result['findings'])} fixes ranked. Top 5:")
    for item in result["findings"][:5]:
        print(f"  {item['rank']}. {item['title']}: {clicks_text(item)}")
    print(f"Report: {(folder / 'seo-report.html').resolve()}")
    return 0


if __name__ == "__main__":
    run_main(main)
