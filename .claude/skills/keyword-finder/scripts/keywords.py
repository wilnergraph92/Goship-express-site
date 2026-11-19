#!/usr/bin/env python3
"""keywords.py: sort the searches an owner could win, and optionally buy keyword data on their own key.

Free, from their own numbers:
    python keywords.py sort --gsc seo-work/gsc.json [--crawl seo-work/crawl.json] [--extra "idea one, idea two"]
                            --out seo-work/keywords.json

Paid, optional, on the owner's own DataForSEO account. Always shows the most it can cost first:
    python keywords.py check
    python keywords.py estimate --volumes-for seo-work/keywords.json [--ideas "seed one,seed two"] [--rivals rival-one.example,rival-two.example] [--limit 200]
    python keywords.py buy --volumes-for seo-work/keywords.json [--ideas ...] [--rivals ...] [--limit 200]
                           --cap-usd 1 --location 2840 --language en --out seo-work/keywords.json
"""
from __future__ import annotations

import argparse
import base64
import json
import re
import sys
import urllib.error
import urllib.request
from datetime import date
from pathlib import Path

# The sort step shares its helpers with the seo skill, which installs beside this one.
SEO_SCRIPTS = Path(__file__).resolve().parents[2] / "seo" / "scripts"
sys.path.insert(0, str(SEO_SCRIPTS))
try:
    from gsc import load_csv  # noqa: E402
    from seolib import (KEYS_FILE, click_rate, covered, die, load_json, page_words, read_keys, run_main, save_json,  # noqa: E402
                        target_position, words_of)
except ImportError:
    print("This skill needs the seo skill beside it, in the same skills folder. Install the whole file again.")
    sys.exit(1)

API_BASE = "https://api.dataforseo.com/v3"
# Checked on dataforseo.com/pricing, November 2026. The bill comes from the answer itself, and this only sizes the cap.
PRICE_VOLUME_TASK = 0.09  # Google Ads search volume, Live, per task of up to 1,000 keywords
PRICE_LABS_TASK = 0.012  # Labs endpoints, Live, per task
PRICE_LABS_ITEM = 0.00012  # Labs endpoints, per row returned
VOLUME_BATCH = 1000
BUY_WORDS = re.compile(r"\b(near me|cost|price|prices|pricing|quote|quotes|hire|company|companies|contractor|contractors|installer|installers|"
                       r"service|services|repair|replacement|emergency|buy|for sale|best|affordable|cheap|estimate|estimates|in [a-z]+)\b", re.I)
LEARN_WORDS = re.compile(r"^(how|what|why|when|where|can|does|do|is|are|should|which)\b|\b(guide|tips|ideas|examples|vs)\b", re.I)


def intent(query: str) -> str:
    if LEARN_WORDS.search(query):
        return "Researching"
    return "Ready To Buy" if BUY_WORDS.search(query) else "Unclear"


def bucket(row, has_page) -> str:
    position = row.get("position") or 0
    if not has_page and position > 10.5:
        return "No Page Yet"
    if position and position <= 3.49:
        return "Already Winning"
    if position and position <= 10.5:
        return "First Page, Could Climb"
    if position and position <= 20.5:
        return "Second Page"
    return "Far Back"


def sort_keywords(gsc, crawl=None, extra=()) -> dict:
    months = float((gsc or {}).get("months") or 3)
    pages = [p for p in (crawl or {}).get("pages", []) if p.get("status") == 200 and not p.get("noindex")]
    candidates = [page_words(p) for p in pages]
    rows = []
    for row in (gsc or {}).get("queries", []):
        words = words_of(row["query"])
        has_page = any(covered(words, c) for c in candidates) if candidates else True
        position = row.get("position") or 0
        shown = row["impressions"] / months
        stake = shown * max(0.0, click_rate(target_position(position)) - row.get("ctr", 0)) if position > 3.49 else 0.0
        rows.append({"keyword": row["query"], "group": bucket(row, has_page), "intent": intent(row["query"]),
                     "shown_a_month": round(shown), "clicks_a_month": round(row["clicks"] / months, 1),
                     "position": round(position, 1), "has_page": has_page, "clicks_at_stake": round(stake)})
    known = {r["keyword"].lower() for r in rows}
    for idea in extra:
        idea = idea.strip()
        if idea and idea.lower() not in known:
            words = words_of(idea)
            has_page = any(covered(words, c) for c in candidates) if candidates else False
            rows.append({"keyword": idea, "group": "Has A Page, Not Showing Yet" if has_page else "No Page Yet", "intent": intent(idea),
                         "shown_a_month": None, "clicks_a_month": None, "position": None, "has_page": has_page,
                         "clicks_at_stake": None, "from": "idea"})
            known.add(idea.lower())
    rows.sort(key=lambda r: (r["intent"] != "Ready To Buy", -(r["clicks_at_stake"] or 0), -(r["shown_a_month"] or 0)))
    return {"keywords": rows, "months": months, "has_search_console": bool(gsc), "volumes": {}, "rival_keywords": [], "spent_usd": 0.0}


def write_table(data, path: Path) -> None:
    lines = ["# Keyword List", "", "Biggest ready to buy chances first. Clicks at stake is an estimate from your own numbers.", "",
             "| Search | Group | Intent | Shown A Month | Position | Page? | Clicks At Stake | Searches A Month |",
             "| --- | --- | --- | --- | --- | --- | --- | --- |"]
    volumes = {k.lower(): v for k, v in (data.get("volumes") or {}).items()}
    for r in data["keywords"]:
        none = "not known"
        lines.append(f"| {r['keyword'].replace('|', '/')} | {r['group']} | {r['intent']} | {r['shown_a_month'] if r['shown_a_month'] is not None else none} | "
                     f"{r['position'] if r['position'] is not None else none} | {'yes' if r['has_page'] else 'no'} | "
                     f"{r['clicks_at_stake'] if r['clicks_at_stake'] is not None else none} | {volumes.get(r['keyword'].lower(), none)} |")
    if data.get("rival_keywords"):
        lines.extend(["", "## Searches Competitors Rank For", "", "From paid data on your own account. It is an estimate from a third party, not Google's own numbers.", "",
                      "| Search | Competitor | Their Position | Searches A Month |", "| --- | --- | --- | --- |"])
        for r in data["rival_keywords"]:
            lines.append(f"| {r['keyword'].replace('|', '/')} | {r['rival']} | {r.get('position')} | {r.get('volume') or none} |")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")


# ------------------------------------------------------------------ optional paid data


def read_ceiling(keys):
    """The most this computer may spend in a calendar month, from a line the owner writes. No flag changes it."""
    try:
        value = float(keys.get("DATAFORSEO_MAX_USD", ""))
    except ValueError:
        return None
    return value if 0 < value < float("inf") else None


def spend_file():
    return KEYS_FILE.parent / "dataforseo-spend.json"


def month_spent() -> float:
    try:
        return float(json.loads(spend_file().read_text(encoding="utf-8")).get(date.today().strftime("%Y-%m"), 0))
    except (OSError, ValueError, AttributeError, TypeError):
        return 0.0


def add_spent(cost) -> None:
    try:
        book = json.loads(spend_file().read_text(encoding="utf-8"))
        if not isinstance(book, dict):
            book = {}
    except (OSError, ValueError):
        book = {}
    month = date.today().strftime("%Y-%m")
    book[month] = round(float(book.get(month, 0)) + cost, 6)
    spend_file().parent.mkdir(parents=True, exist_ok=True)
    spend_file().write_text(json.dumps(book), encoding="utf-8")


def plan(args):
    """The most this run can cost, worked out before anything is sent."""
    keywords = []
    if args.volumes_for:
        data = load_json(args.volumes_for, "keyword file")
        keywords = [r["keyword"] for r in data.get("keywords", []) if r.get("from") == "idea" or r.get("shown_a_month") is not None]
        keywords = [k for k in keywords if len(k) <= 80 and len(k.split()) <= 10]
    ideas = [s.strip() for s in (args.ideas or "").split(",") if s.strip()][:20]
    rivals = [s.strip() for s in (args.rivals or "").split(",") if s.strip()]
    batches = (len(keywords) + VOLUME_BATCH - 1) // VOLUME_BATCH
    cost_volume = batches * PRICE_VOLUME_TASK
    cost_ideas = (PRICE_LABS_TASK + PRICE_LABS_ITEM * args.limit) if ideas else 0.0
    cost_rivals = len(rivals) * (PRICE_LABS_TASK + PRICE_LABS_ITEM * args.limit)
    return {"keywords": keywords, "ideas": ideas, "rivals": rivals, "batches": batches, "total": cost_volume + cost_ideas + cost_rivals,
            "cost_volume": cost_volume, "cost_ideas": cost_ideas, "cost_rivals": cost_rivals}


def show_plan(p, limit):
    print("The most this run can cost on your DataForSEO account:")
    if p["batches"]:
        print(f"  Search numbers for {len(p['keywords'])} searches: {p['batches']} request(s) at ${PRICE_VOLUME_TASK} = ${p['cost_volume']:.3f}")
    if p["ideas"]:
        print(f"  New ideas from {len(p['ideas'])} starting words, up to {limit} rows: ${p['cost_ideas']:.3f}")
    if p["rivals"]:
        print(f"  What {len(p['rivals'])} competitor(s) rank for, up to {limit} rows each: ${p['cost_rivals']:.3f}")
    print(f"  Total at most: ${p['total']:.3f}")


def call(login, password, route, payload):
    token = base64.b64encode(f"{login}:{password}".encode()).decode()
    req = urllib.request.Request(f"{API_BASE}{route}", data=json.dumps([payload]).encode("utf-8"), method="POST",
                                 headers={"Authorization": f"Basic {token}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        if err.code == 401:
            die("DataForSEO refused your login. Check DATAFORSEO_LOGIN and DATAFORSEO_PASSWORD. The password is the API one on their API Access page, not your account password.")
        if err.code == 402:
            die("DataForSEO says your account has no balance left. Nothing more was bought.")
        die(f"DataForSEO answered with status {err.code}. Nothing more was bought. Try again later.")
    except urllib.error.URLError as err:
        die(f"I could not reach DataForSEO ({err.reason}). Nothing more was bought.")
    task = (data.get("tasks") or [{}])[0]
    if task.get("status_code") != 20000:
        print(f"DataForSEO could not do this one: {task.get('status_message') or data.get('status_message')}. Moving on.")
        return [], float(data.get("cost") or 0)
    return task.get("result") or [], float(task.get("cost") or data.get("cost") or 0)


def check_login() -> int:
    """Prove the login works. DataForSEO does not charge for this call."""
    keys = read_keys()
    login, password = keys.get("DATAFORSEO_LOGIN"), keys.get("DATAFORSEO_PASSWORD")
    if not (login and password):
        print(f"Not set: DATAFORSEO_LOGIN and DATAFORSEO_PASSWORD need to be in {KEYS_FILE}.")
        return 1
    token = base64.b64encode(f"{login}:{password}".encode()).decode()
    req = urllib.request.Request(f"{API_BASE}/appendix/user_data", headers={"Authorization": f"Basic {token}"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        print("DataForSEO refused your login. The password it wants is the API one on the API Access page, not your account password."
              if err.code == 401 else f"DataForSEO answered with status {err.code}. Try again later.")
        return 1
    except urllib.error.URLError as err:
        print(f"I could not reach DataForSEO ({err.reason}). Check your connection and try again.")
        return 1
    task = (data.get("tasks") or [{}])[0]
    if task.get("status_code") != 20000:
        print(f"DataForSEO could not check this login: {task.get('status_message') or data.get('status_message')}.")
        return 1
    row = (task.get("result") or [{}])[0]
    money = row.get("money") if isinstance(row.get("money"), dict) else row
    balance = money.get("balance")
    print("Login works. That check was free." + (f" Balance: ${balance:.2f}." if isinstance(balance, (int, float)) else ""))
    return 0


def buy(args) -> int:
    keys = read_keys()
    login, password = keys.get("DATAFORSEO_LOGIN"), keys.get("DATAFORSEO_PASSWORD")
    if not (login and password):
        die(f"Paid keyword data is optional and not set up. The free route still works. To use it, put DATAFORSEO_LOGIN and DATAFORSEO_PASSWORD in {KEYS_FILE} in a text editor. Do not paste them into this chat.")
    p = plan(args)
    if not (p["batches"] or p["ideas"] or p["rivals"]):
        die("There is nothing to look up. Give me a keyword file, --ideas or --rivals.")
    show_plan(p, args.limit)
    ceiling = read_ceiling(keys)
    if ceiling is None:
        print(f"Refused: there is no monthly ceiling. Nothing was bought. The owner opens {KEYS_FILE} in a text editor and adds a line like "
              "DATAFORSEO_MAX_USD=2, the most this computer may spend in a calendar month. No option can go past it. Claude does not set it.")
        return 2
    already = month_spent()
    if args.cap_usd is None:
        print("Refused: no spending cap given. Show the owner this cost, and if they say yes, run it again with --cap-usd.")
        return 2
    if p["total"] > args.cap_usd + 1e-9:
        print(f"Refused: this could cost ${p['total']:.3f}, which is over your cap of ${args.cap_usd:.2f}. Nothing was bought.")
        return 2
    if already + p["total"] > ceiling + 1e-9:
        print(f"Refused: ${already:.3f} is already spent this month, and this could add ${p['total']:.3f}, which would pass your monthly ceiling of "
              f"${ceiling:.2f}. Nothing was bought. Only the owner changes DATAFORSEO_MAX_USD, in {KEYS_FILE}.")
        return 2
    try:
        data = load_json(args.volumes_for, "keyword file") if args.volumes_for else {"keywords": [], "volumes": {}, "rival_keywords": []}
    except SystemExit:
        return 1
    spent = float(data.get("spent_usd") or 0)
    run_spent = 0.0
    common = {"location_code": args.location, "language_code": args.language}
    volumes = dict(data.get("volumes") or {})

    def room(next_cost):
        if run_spent + next_cost > min(args.cap_usd, ceiling - already) + 1e-9:
            print(f"Stopped at ${run_spent:.3f}: the next step would pass your cap or your monthly ceiling.")
            return False
        return True

    def bought(cost):
        add_spent(cost)
        return cost

    for start in range(0, len(p["keywords"]), VOLUME_BATCH):
        if not room(PRICE_VOLUME_TASK):
            break
        results, cost = call(login, password, "/keywords_data/google_ads/search_volume/live",
                             {**common, "keywords": p["keywords"][start:start + VOLUME_BATCH]})
        run_spent += bought(cost)
        for row in results:
            if row.get("keyword") is not None and row.get("search_volume") is not None:
                volumes[row["keyword"]] = row["search_volume"]
    item_cost = PRICE_LABS_TASK + PRICE_LABS_ITEM * args.limit
    if p["ideas"] and room(item_cost):
        results, cost = call(login, password, "/dataforseo_labs/google/keyword_ideas/live",
                             {**common, "keywords": p["ideas"], "limit": args.limit})
        run_spent += bought(cost)
        known = {r["keyword"].lower() for r in data["keywords"]}
        for item in (results[0].get("items") or []) if results else []:
            word = item.get("keyword")
            volume = (item.get("keyword_info") or {}).get("search_volume")
            if word and volume is not None:
                volumes[word] = volume
                if word.lower() not in known:
                    known.add(word.lower())
                    data["keywords"].append({"keyword": word, "group": "New Idea", "intent": intent(word), "shown_a_month": None,
                                             "clicks_a_month": None, "position": None, "has_page": False, "clicks_at_stake": None, "from": "paid idea"})
    rival_rows = list(data.get("rival_keywords") or [])
    for rival in p["rivals"]:
        if not room(item_cost):
            break
        results, cost = call(login, password, "/dataforseo_labs/google/ranked_keywords/live",
                             {**common, "target": rival, "limit": args.limit})
        run_spent += bought(cost)
        for item in (results[0].get("items") or []) if results else []:
            info = item.get("keyword_data") or {}
            serp = ((item.get("ranked_serp_element") or {}).get("serp_item") or {})
            rival_rows.append({"rival": rival, "keyword": info.get("keyword"), "volume": (info.get("keyword_info") or {}).get("search_volume"),
                               "position": serp.get("rank_group"), "url": serp.get("url")})
    data.update(volumes=volumes, rival_keywords=[r for r in rival_rows if r.get("keyword")], spent_usd=round(spent + run_spent, 4))
    save_json(args.out, data)
    write_table(data, Path(args.out).with_suffix(".md"))
    print(f"Spent ${run_spent:.4f} on your DataForSEO account, by their own count. Saved to {args.out}")
    return 0


def main():
    ap = argparse.ArgumentParser(description="Sort the searches you could win.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    one = sub.add_parser("sort")
    one.add_argument("--gsc")
    one.add_argument("--csv", nargs="*", help="a Search Console export, if there is no gsc.json yet")
    one.add_argument("--crawl")
    one.add_argument("--extra", default="", help="comma separated ideas from Claude's own web research")
    one.add_argument("--out", default="seo-work/keywords.json")
    sub.add_parser("check")
    for name in ("estimate", "buy"):
        two = sub.add_parser(name)
        two.add_argument("--volumes-for")
        two.add_argument("--ideas", default="")
        two.add_argument("--rivals", default="")
        two.add_argument("--limit", type=int, default=200)
        if name == "buy":
            two.add_argument("--cap-usd", type=float)
            two.add_argument("--location", type=int, default=2840, help="DataForSEO location code; 2840 is the United States")
            two.add_argument("--language", default="en")
            two.add_argument("--out", default="seo-work/keywords.json")
    args = ap.parse_args()
    if args.cmd == "sort":
        gsc = load_json(args.gsc, "Search Console file") if args.gsc else (load_csv(args.csv) if args.csv else None)
        crawl = load_json(args.crawl, "crawl") if args.crawl else None
        if not gsc and not args.extra:
            print("With no Search Console data and no ideas there is nothing to sort. Give me the export, or do some web research on what the owner sells and pass it with --extra.")
            return 1
        data = sort_keywords(gsc, crawl, args.extra.split(",") if args.extra else ())
        save_json(args.out, data)
        write_table(data, Path(args.out).with_suffix(".md"))
        print(f"Sorted {len(data['keywords'])} searches. Saved to {args.out} and {Path(args.out).with_suffix('.md')}")
        for row in data["keywords"][:10]:
            print(f"  {row['keyword']}: {row['group']}, {row['intent']}, about {row['clicks_at_stake'] if row['clicks_at_stake'] is not None else '?'} clicks a month at stake")
        return 0
    if args.cmd == "check":
        return check_login()
    if args.cmd == "estimate":
        p = plan(args)
        show_plan(p, args.limit)
        ceiling = read_ceiling(read_keys())
        print(f"Monthly ceiling: ${ceiling:.2f}, with ${month_spent():.3f} spent so far." if ceiling else
              f"Monthly ceiling: not set. The owner adds DATAFORSEO_MAX_USD to {KEYS_FILE} before anything can be bought.")
        print("Nothing was bought. DataForSEO's smallest top up is $50, and new accounts get a $1 trial credit.")
        return 0
    return buy(args)


if __name__ == "__main__":
    run_main(main)
