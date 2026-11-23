#!/usr/bin/env python3
"""gaps.py: who outranks the owner, and what do they have a page for that the owner does not.

    python gaps.py rivals --serp seo-work/serp.json --own example.com
    python gaps.py topics --own seo-work/crawl.json --rivals seo-work/rival-*.json --out seo-work/gaps.json

serp.json is what Claude writes down from its own web searches:
    [{"query": "roof replacement cost", "results": ["https://...", "https://..."]}]

The match is by words in titles, headings and addresses, so it is a good guess, not a verdict.
Claude reads the list and drops anything that is not really a missing page.
"""
from __future__ import annotations

import argparse
import glob
import re
import sys
from collections import Counter
from pathlib import Path
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))
from seolib import covered, load_json, page_key, page_words, run_main, save_json, words_of  # noqa: E402

# Sites that rank for almost everything but are not a business anyone can copy or outbuild.
DIRECTORIES = {
    "yelp.com", "facebook.com", "instagram.com", "linkedin.com", "youtube.com", "tiktok.com", "x.com", "twitter.com",
    "pinterest.com", "reddit.com", "quora.com", "wikipedia.org", "amazon.com", "ebay.com", "yellowpages.com",
    "bbb.org", "angi.com", "angieslist.com", "homeadvisor.com", "thumbtack.com", "houzz.com", "nextdoor.com",
    "tripadvisor.com", "indeed.com", "glassdoor.com", "mapquest.com", "google.com", "bing.com", "apple.com",
}
UTILITY = re.compile(r"(privacy|terms|cookie|contact|about|login|sign-?in|sign-?up|account|cart|checkout|careers?|jobs|"
                     r"sitemap|search|thank|404|tag/|author/|category/|feed|wp-|legal|disclaimer|accessibility|press)", re.I)


def bare_host(url: str) -> str:
    host = urlsplit(url if "//" in url else "//" + url).netloc.lower()
    return host[4:] if host.startswith("www.") else host


def rivals(serp, own) -> dict:
    own = bare_host(own)
    count, directories = Counter(), Counter()
    for item in serp:
        hosts = {bare_host(u) for u in item.get("results", []) if u}
        for host in hosts:
            if not host or host == own or host.endswith("." + own):
                continue
            if host in DIRECTORIES or any(host.endswith("." + d) for d in DIRECTORIES):
                directories[host] += 1
            else:
                count[host] += 1
    return {"searches_checked": len(serp),
            "rivals": [{"domain": d, "searches": n} for d, n in count.most_common()],
            "directories_left_out": [{"domain": d, "searches": n} for d, n in directories.most_common()]}


def site_name_words(pages) -> set:
    """A site's own name sits in most of its titles and says nothing about the page. Its trade may
    sit there too, like "roof" on a roofer's site, and that word must stay. So a word only counts
    as the name if it is in most titles and also in the home page title or the site's address."""
    titled = [p for p in pages if p.get("title")]
    if len(titled) < 3:
        return set()
    tally = Counter()
    for page in titled:
        tally.update(words_of(page["title"]))
    home = next((p for p in titled if urlsplit(p["url"]).path in ("", "/")), None)
    name = words_of(home["title"]) if home else set()
    label = re.sub(r"[^a-z0-9]", "", bare_host(titled[0]["url"]).split(".")[0])
    return {w for w, n in tally.items() if n / len(titled) >= 0.5 and (w in name or w in label)}


def topic_label(page) -> str:
    text = (page.get("h1s") or [None])[0] or page.get("title") or ""
    if not text:
        slug = urlsplit(page.get("url", "")).path.strip("/").rsplit("/", 1)[-1]
        text = slug.replace("-", " ").replace("_", " ").title()
    return text.strip()[:90]


def stems(words: set) -> set:
    """Licenses and license are the same word for this purpose."""
    return {w[:-1] if len(w) > 3 and w.endswith("s") and not w.endswith("ss") else w for w in words}


COMPARISON = re.compile(r"\b(vs|versus|compare|comparison|alternatives?)\b", re.I)
FILE_LIKE = re.compile(r"\.(md|txt|xml|json|rss|atom|pdf|csv)$|/page/\d+/?$", re.I)
MAX_TOPICS = 40  # the rest stay in gaps.json, counted, so the report stays readable
BIG_SITEMAP = 50  # past this many unread addresses, most of a rival's sitemap is off topic


def shared(words: set, business: set) -> int:
    """How many of these words the business uses. Licensing and license count as the same word."""
    prefixes = {w[:5] for w in business if len(w) >= 5}
    return sum(1 for w in words if w in business or (len(w) >= 5 and w[:5] in prefixes))


def search_match(words: set, searches: list) -> float:
    """How closely a topic matches a search the owner's customers type, from 0 to 1."""
    best = 0.0
    for query in searches:
        if query:
            best = max(best, len(stems(words) & query) / len(query))
    return round(best, 2)


def topics(own, rival_sets, searches=()) -> dict:
    own_pages = [p for p in own.get("pages", []) if p.get("status") == 200]
    own_common = site_name_words(own_pages)
    own_words = [page_words(p) - own_common for p in own_pages]
    own_all = set().union(*own_words) if own_words else set()
    # With the site's name taken out, a site whose name is its trade loses the word that matters.
    # So a page also counts as covering a topic on its full words, unless the topic is a comparison,
    # which a page about one of the two things does not answer.
    own_full = [stems(page_words(p)) for p in own_pages]
    searches = [stems(words_of(q)) for q in searches]
    # What this business talks about: its own pages and the searches its customers type. A rival's
    # page that shares no word with that is usually some other line of business, so it is set aside,
    # not deleted: gaps.json keeps a list for Claude to scan.
    home = next((p for p in own_pages if urlsplit(p["url"]).path in ("", "/")), {})
    business = set().union(*own_full, *searches, stems(words_of(home.get("excerpt") or ""))) if (own_full or searches) else set()
    set_aside = []
    found = {}
    for rival in rival_sets:
        pages = [p for p in rival.get("pages", []) if p.get("status") == 200 and not p.get("noindex")]
        common = site_name_words(pages)
        fetched = {page_key(p["url"]) for p in pages}
        unread = [{"url": u} for u in rival.get("sitemap", {}).get("urls", []) if page_key(u) not in fetched]
        for page in pages + unread:
            url = page["url"]
            path = urlsplit(url).path
            if path in ("", "/") or UTILITY.search(path) or FILE_LIKE.search(path):
                continue
            words = page_words(page) - common - {bare_host(url).split(".")[0]}
            if len(words) < 2:
                continue
            if any(covered(words, w) for w in own_words) or covered(words, own_all, 1.0):
                continue
            if not COMPARISON.search(page.get("title") or path) and any(covered(stems(words), w) for w in own_full):
                continue
            # A page Claude read has a real title. An unread address is only words in a link, so on a
            # big sitemap it has to share more before it counts.
            need = 1 if page.get("title") or len(unread) <= BIG_SITEMAP else 2
            if business and shared(stems(words), business) < need:
                set_aside.append({"topic": topic_label(page), "url": url})
                continue
            key = " ".join(sorted(words))
            match = next((k for k, v in found.items() if len(words & v["words"]) / len(words | v["words"]) >= 0.6), key)
            entry = found.setdefault(match, {"words": words, "label": topic_label(page), "pages": [], "read": False})
            if page.get("title") and not entry["read"]:
                entry["label"], entry["read"] = topic_label(page), True
            entry["pages"].append({"domain": bare_host(url), "url": url, "title": page.get("title"),
                                   "word_count": page.get("word_count"), "read": bool(page.get("title"))})
    rows = []
    for entry in found.values():
        domains = sorted({p["domain"] for p in entry["pages"]})
        rows.append({"topic": entry["label"], "words": sorted(entry["words"]), "competitors": domains,
                     "competitor_count": len(domains), "pages": entry["pages"][:6], "read": entry["read"],
                     "search_match": search_match(entry["words"], searches)})
    rows.sort(key=lambda r: (-r["competitor_count"], not r["read"], -r["search_match"], -max((p.get("word_count") or 0) for p in r["pages"]), r["topic"]))
    return {"own_pages_compared": len(own_pages), "rivals_read": [r.get("host") for r in rival_sets],
            "rival_pages_read": sum(1 for r in rival_sets for p in r.get("pages", []) if p.get("status") == 200),
            "topics": rows[:MAX_TOPICS],
            "more_topics_count": max(0, len(rows) - MAX_TOPICS),
            "more_topics": [{"topic": r["topic"], "url": r["pages"][0]["url"]} for r in rows[MAX_TOPICS:MAX_TOPICS + 200]],
            "set_aside_count": len(set_aside),
            "set_aside": set_aside[:200],
            "method": "Compared the words in page titles, headings and addresses. A good guess, reviewed by Claude."}


def main():
    ap = argparse.ArgumentParser(description="Find rivals and the pages they have that the owner does not.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    one = sub.add_parser("rivals")
    one.add_argument("--serp", required=True)
    one.add_argument("--own", required=True)
    one.add_argument("--out")
    two = sub.add_parser("topics")
    two.add_argument("--own", required=True)
    two.add_argument("--rivals", nargs="+", required=True)
    two.add_argument("--serp", help="the searches you checked, so topics that match them rank first")
    two.add_argument("--out", default="seo-work/gaps.json")
    args = ap.parse_args()
    if args.cmd == "rivals":
        result = rivals(load_json(args.serp, "list of searches"), args.own)
        for row in result["rivals"][:10]:
            print(f"{row['domain']}: showed up on {row['searches']} of {result['searches_checked']} searches")
        if not result["rivals"]:
            print("No rival businesses in those results, only directories or the site itself.")
        if result["directories_left_out"]:
            print("Left out as directories:", ", ".join(d["domain"] for d in result["directories_left_out"][:8]))
        if args.out:
            save_json(args.out, result)
        return 0
    paths = []
    for pattern in args.rivals:
        paths.extend(sorted(glob.glob(pattern)) or [pattern])
    sets = []
    for path in paths:
        try:
            sets.append(load_json(path, "rival crawl"))
        except SystemExit:
            print(f"Skipped {path}: I could not read it.")
    if not sets:
        print("No rival crawl could be read, so there is nothing to compare yet.")
        return 1
    searched = []
    if args.serp and Path(args.serp).is_file():
        searched = [row.get("query", "") for row in load_json(args.serp, "list of searches")]
    result = topics(load_json(args.own, "crawl of your own site"), sets, searched)
    save_json(args.out, result)
    print(f"Found {len(result['topics']) + result['more_topics_count']} topics rivals have a page for and you may not, and set aside "
          f"{result['set_aside_count']} that look like another line of business. Saved to {args.out}")
    if result["more_topics_count"]:
        print(f"The report shows the top {len(result['topics'])}. The other {result['more_topics_count']} are listed in the file.")
    for row in result["topics"][:15]:
        print(f"  {row['topic']} ({', '.join(row['competitors'])})")
    return 0


if __name__ == "__main__":
    run_main(main)
