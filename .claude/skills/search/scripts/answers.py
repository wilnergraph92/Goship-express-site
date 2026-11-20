#!/usr/bin/env python3
"""answers.py: read what Google's AI answers say for the questions customers ask. Standard library only.

It reads Google's AI Overview and AI Mode answers through the owner's own account at one of two
services, and records for each question: did an AI answer show, which websites it cites, whether
the owner's site is cited, whether the owner's name is in the words, and which other businesses
are named or cited instead. It also keeps the map results and the related questions Google shows.

    python answers.py check    --provider serpapi|dataforseo
    python answers.py estimate --questions search-work/questions.json --provider serpapi|dataforseo [--engines overview,mode]
    python answers.py run      --questions search-work/questions.json --provider serpapi|dataforseo [--engines overview,mode]
                               --domain example.com --name "Business Name" [--alias "Other Name"] [--location "Austin,Texas,United States"]
                               [--gl us] [--hl en] [--device mobile] (--cap-usd 1 | --cap-searches 60) --confirm --out search-work/answers.json
    python answers.py run      --same-as search-work/answers.json (--cap-usd 1 | --cap-searches 60) --confirm --out search-work/answers-after.json

Nothing is spent without --confirm, a cap for this run, and room under the owner's monthly ceiling.
One run is one look, from one place, on one kind of device, at one moment. AI answers change from
search to search, so the tracker compares like with like and says so.
"""
from __future__ import annotations

import argparse
import base64
import json
import re
import sys
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from searchlib import (KEYS_FILE, ServiceError, add_used, api_base, bare_domain, die, http_json, load_json,  # noqa: E402
                       month_used, read_ceiling, read_keys, run_main, save_json)

DFS = api_base("DATAFORSEO_BASE_URL", "https://api.dataforseo.com")
SERP = api_base("SERPAPI_BASE_URL", "https://serpapi.com")
# Checked on dataforseo.com/pricing/serp, November 2026. Live mode, per question. The bill comes from DataForSEO's own count.
DFS_OVERVIEW = 0.004  # Google Organic Live $0.002, plus $0.002 for load_async_ai_overview (refunded when there is none)
DFS_MODE = 0.004  # Google AI Mode Live, per request
SERP_FREE_MONTH = 250  # SerpApi free plan, searches a month (serpapi.com/pricing)
MAX_QUESTIONS = 40
DIRECTORIES = ("yelp.", "bbb.org", "angi.com", "homeadvisor.com", "thumbtack.com", "facebook.com", "nextdoor.com", "yellowpages.com",
               "reddit.com", "youtube.com", "google.com", "wikipedia.org", "mapquest.com", "tripadvisor.", "houzz.com", "porch.com",
               "bing.com", "apple.com", "instagram.com", "linkedin.com", "quora.com", "tiktok.com", "x.com", "twitter.com")


# ------------------------------------------------------------------ questions and costs


def load_questions(path) -> list:
    data = load_json(path, "questions file")
    rows = data.get("questions") if isinstance(data, dict) else data
    out = []
    for row in rows or []:
        q = (row.get("q") if isinstance(row, dict) else str(row)) or ""
        q = " ".join(q.split())[:300]
        if q and q.lower() not in {x.lower() for x in out}:
            out.append(q)
    if not out:
        die("The questions file has no questions. Write the questions customers ask first.")
    if len(out) > MAX_QUESTIONS:
        print(f"That is {len(out)} questions. I will use the first {MAX_QUESTIONS}, which keeps the cost and the report readable.")
        out = out[:MAX_QUESTIONS]
    return out


def engines_of(text) -> list:
    chosen = [e.strip() for e in (text or "overview,mode").split(",") if e.strip()]
    bad = [e for e in chosen if e not in ("overview", "mode")]
    if bad:
        die(f"Unknown answer type {bad[0]}. Use overview (AI Overviews), mode (AI Mode), or both: overview,mode.")
    return chosen


def plan(questions, provider, engines) -> dict:
    n = len(questions)
    if provider == "dataforseo":
        usd = n * ((DFS_OVERVIEW if "overview" in engines else 0) + (DFS_MODE if "mode" in engines else 0))
        return {"questions": n, "usd": round(usd, 4), "searches": 0}
    # SerpApi counts searches. An AI Overview sometimes needs a second request, so the most is two for it.
    most = n * ((2 if "overview" in engines else 0) + (1 if "mode" in engines else 0))
    return {"questions": n, "usd": 0.0, "searches": most}


def show_plan(p, provider, engines) -> None:
    kinds = " and ".join({"overview": "AI Overviews", "mode": "AI Mode"}[e] for e in engines)
    if provider == "dataforseo":
        print(f"Reading {kinds} for {p['questions']} questions on your DataForSEO account costs at most ${p['usd']:.3f} "
              f"(${DFS_OVERVIEW} per question for AI Overviews, ${DFS_MODE} for AI Mode).")
    else:
        print(f"Reading {kinds} for {p['questions']} questions uses at most {p['searches']} SerpApi searches. "
              f"The free plan gives {SERP_FREE_MONTH} a month. Cached repeats within an hour are free.")


# ------------------------------------------------------------------ reading the two services


def dfs_auth(keys) -> dict:
    login, password = keys.get("DATAFORSEO_LOGIN"), keys.get("DATAFORSEO_PASSWORD")
    if not (login and password):
        die(f"DataForSEO is not set up. Put DATAFORSEO_LOGIN and DATAFORSEO_PASSWORD in {KEYS_FILE} in a text editor. "
            "Do not paste them into this chat. The steps are in references/dataforseo-setup.md.", 3)
    return {"Authorization": "Basic " + base64.b64encode(f"{login}:{password}".encode()).decode()}


def dfs_post(headers, route, task) -> tuple:
    status, data = http_json("POST", f"{DFS}/v3{route}", headers, [task], timeout=120, service="DataForSEO")
    if status == 401:
        die("DataForSEO refused your login. The password it wants is the API one on its API Access page, not your account password.")
    if status == 402:
        die("DataForSEO says your balance is used up. Nothing more was bought.")
    if status != 200 or not isinstance(data, dict):
        raise ServiceError(f"DataForSEO answered with status {status}")
    task_out = (data.get("tasks") or [{}])[0]
    cost = float(task_out.get("cost") or 0)
    if task_out.get("status_code") != 20000:
        raise ServiceError(f"DataForSEO could not do this one: {task_out.get('status_message')}")
    result = (task_out.get("result") or [{}])[0] or {}
    return result, cost


def refs_from(node) -> list:
    """Every cited page anywhere inside an AI answer block, in order, without repeats."""
    found, seen = [], set()

    def walk(x):
        if isinstance(x, dict):
            for ref in x.get("references") or []:
                if isinstance(ref, dict):
                    url = ref.get("url") or ref.get("link") or ""
                    key = url.split("#")[0]
                    if url and key not in seen:
                        seen.add(key)
                        found.append({"domain": bare_domain(url), "url": url[:500], "title": (ref.get("title") or ref.get("source") or "")[:200]})
            for value in x.values():
                if isinstance(value, (dict, list)):
                    walk(value)
        elif isinstance(x, list):
            for value in x:
                walk(value)

    walk(node)
    return found


def dfs_read(headers, q, engines, where) -> tuple:
    out, cost = {"errors": []}, 0.0
    if "overview" in engines:
        try:
            result, spent = dfs_post(headers, "/serp/google/organic/live/advanced",
                                     {"keyword": q, **where, "load_async_ai_overview": True})
            cost += spent
            items = result.get("items") or []
            box = next((i for i in items if i.get("type") == "ai_overview"), None)
            out["ai_overview"] = {"shown": box is not None, "text": ((box or {}).get("markdown") or "")[:4000], "sources": refs_from(box) if box else []}
            out["local_pack"] = [{"title": i.get("title") or "", "domain": bare_domain(i.get("url") or i.get("domain") or ""),
                                  "rating": (i.get("rating") or {}).get("value"), "reviews": (i.get("rating") or {}).get("votes_count")}
                                 for i in items if i.get("type") == "local_pack"][:10]
            out["more_questions"] = [e.get("title") for i in items if i.get("type") == "people_also_ask"
                                     for e in (i.get("items") or []) if e.get("title")][:10]
            out["organic"] = [bare_domain(i.get("url") or i.get("domain") or "") for i in items if i.get("type") == "organic"][:20]
        except ServiceError as err:
            out["errors"].append(f"AI Overview: {err}")
    if "mode" in engines:
        try:
            result, spent = dfs_post(headers, "/serp/google/ai_mode/live/advanced", {"keyword": q, **where})
            cost += spent
            box = next((i for i in (result.get("items") or []) if i.get("type") == "ai_overview"), None)
            out["ai_mode"] = {"shown": box is not None, "text": ((box or {}).get("markdown") or "")[:4000], "sources": refs_from(box) if box else []}
        except ServiceError as err:
            out["errors"].append(f"AI Mode: {err}")
    return out, cost


def serp_get(key, params) -> dict:
    query = urllib.parse.urlencode({**params, "api_key": key})
    try:
        status, data = http_json("GET", f"{SERP}/search.json?{query}", timeout=120, service="SerpApi")
    except ServiceError as err:
        raise ServiceError(str(err).replace(key, "[key]")) from None
    if status == 401:
        die("SerpApi refused your key. Copy the private API key from its dashboard into SERPAPI_KEY again.", 1)
    if status == 429:
        raise ServiceError("SerpApi says this month's searches are used up, or it is going too fast")
    if status != 200 or not isinstance(data, dict):
        raise ServiceError(f"SerpApi answered with status {status}: {str((data or {}).get('error', ''))[:200] if isinstance(data, dict) else ''}")
    if data.get("error") and not any(k in data for k in ("ai_overview", "text_blocks", "organic_results")):
        raise ServiceError(f"SerpApi: {str(data['error'])[:200]}")
    return data


def serp_text(block) -> str:
    if not isinstance(block, dict):
        return ""
    if block.get("reconstructed_markdown"):
        return block["reconstructed_markdown"]
    lines = []
    for tb in block.get("text_blocks") or []:
        if tb.get("snippet"):
            lines.append(tb["snippet"])
        for row in tb.get("list") or []:
            lines.append(" ".join(x for x in (row.get("title"), row.get("snippet")) if x))
    return "\n".join(lines)


def serp_read(key, q, engines, where) -> tuple:
    out, used = {"errors": []}, 0
    if "overview" in engines:
        try:
            data = serp_get(key, {"engine": "google", "q": q, **where})
            used += 1
            box = data.get("ai_overview")
            if isinstance(box, dict) and box.get("page_token") and not box.get("text_blocks"):
                box = serp_get(key, {"engine": "google_ai_overview", "page_token": box["page_token"]}).get("ai_overview")
                used += 1
            shown = isinstance(box, dict) and bool(box.get("text_blocks") or box.get("references"))
            out["ai_overview"] = {"shown": shown, "text": serp_text(box)[:4000], "sources": refs_from(box) if shown else []}
            places = (data.get("local_results") or {}).get("places") if isinstance(data.get("local_results"), dict) else data.get("local_results")
            out["local_pack"] = [{"title": p.get("title") or "", "domain": bare_domain(p.get("website") or ""),
                                  "rating": p.get("rating"), "reviews": p.get("reviews")} for p in (places or []) if isinstance(p, dict)][:10]
            out["more_questions"] = [r.get("question") for r in data.get("related_questions") or [] if r.get("question")][:10]
            out["organic"] = [bare_domain(r.get("link") or "") for r in data.get("organic_results") or []][:20]
        except ServiceError as err:
            out["errors"].append(f"AI Overview: {err}")
    if "mode" in engines:
        try:
            data = serp_get(key, {"engine": "google_ai_mode", "q": q, **{k: v for k, v in where.items() if k != "device"}})
            used += 1
            shown = bool(data.get("text_blocks") or data.get("reconstructed_markdown"))
            out["ai_mode"] = {"shown": shown, "text": serp_text(data)[:4000], "sources": refs_from(data) if shown else []}
        except ServiceError as err:
            out["errors"].append(f"AI Mode: {err}")
    return out, used


# ------------------------------------------------------------------ who is named, who is cited


def name_in(text, names) -> bool:
    low = " " + re.sub(r"[^a-z0-9&]+", " ", (text or "").lower()) + " "
    for name in names:
        clean = " " + re.sub(r"[^a-z0-9&]+", " ", name.lower()).strip() + " "
        if len(clean.strip()) >= 3 and clean in low:
            return True
    return False


def judge(block, own_domain, own_names, pack) -> None:
    """Fills in own_cited, own_named, other sites cited and other businesses named, from the answer itself."""
    if not block or block.get("shown") is not True:
        return
    sources = block.get("sources") or []
    block["own_cited"] = any(s["domain"] == own_domain or s["domain"].endswith("." + own_domain) for s in sources)
    block["own_named"] = name_in(block.get("text"), own_names)
    others = []
    for s in sources:
        d = s["domain"]
        if d and d != own_domain and not d.endswith("." + own_domain) and d not in others:
            others.append(d)
    block["others_cited"] = [d for d in others if not any(x in d for x in DIRECTORIES)][:15]
    block["directories_cited"] = [d for d in others if any(x in d for x in DIRECTORIES)][:15]
    block["others_named"] = [p["title"] for p in pack if p.get("title") and not name_in(p["title"], own_names)
                             and name_in(block.get("text"), [p["title"]])][:10]


def read_all(args, keys, questions, engines, provider) -> dict:
    own = bare_domain(args.domain)
    names = [n for n in [args.name, *(args.alias or [])] if n]
    rows, spent_usd, spent_searches = [], 0.0, 0
    if provider == "dataforseo":
        headers = dfs_auth(keys)
        where = {"language_code": args.hl, "device": args.device}
        where.update({"location_name": ",".join(p.strip() for p in args.location.split(","))} if args.location else {"location_code": 2840})
    else:
        key = keys.get("SERPAPI_KEY")
        if not key:
            die(f"SerpApi is not set up. Put SERPAPI_KEY in {KEYS_FILE} in a text editor. Do not paste it into this chat. "
                "The steps are in references/serpapi-setup.md.", 3)
        where = {"gl": args.gl, "hl": args.hl, "device": args.device}
        if args.location:
            where["location"] = ", ".join(p.strip() for p in args.location.split(","))
    for n, q in enumerate(questions, 1):
        if provider == "dataforseo":
            nxt = (DFS_OVERVIEW if "overview" in engines else 0) + (DFS_MODE if "mode" in engines else 0)
            if spent_usd + nxt > args.room + 1e-9:
                print(f"Stopped after {n - 1} questions: the next one would pass your cap or your monthly ceiling.")
                break
            row, cost = dfs_read(headers, q, engines, where)
            spent_usd += cost
            add_used("dataforseo", cost)
        else:
            nxt = (2 if "overview" in engines else 0) + (1 if "mode" in engines else 0)
            if spent_searches + nxt > args.room:
                print(f"Stopped after {n - 1} questions: the next one could pass your cap or your monthly ceiling.")
                break
            row, used = serp_read(key, q, engines, where)
            spent_searches += used
            add_used("serpapi", used)
        pack = row.get("local_pack") or []
        for engine in ("ai_overview", "ai_mode"):
            judge(row.get(engine), own, names, pack)
        row["q"] = q
        row["own_in_local_pack"] = any((p.get("domain") and p["domain"] == own) or name_in(p.get("title"), names) for p in pack) if pack else False
        org = row.get("organic") or []
        row["organic_rank"] = next((i + 1 for i, d in enumerate(org) if d == own or d.endswith("." + own)), None)
        rows.append(row)
        mark = []
        for engine, label in (("ai_overview", "AI Overview"), ("ai_mode", "AI Mode")):
            b = row.get(engine)
            if b is None:
                continue
            if b.get("shown") is not True:
                mark.append(f"{label}: none shown")
            else:
                mark.append(f"{label}: you are {'cited' if b.get('own_cited') else 'not cited'}"
                            + (f", {len(b.get('others_cited') or [])} others cited" if b.get("others_cited") else ""))
        print(f"  {n}. {q}: " + ("; ".join(mark) or "could not read") + (f" ({'; '.join(row['errors'])})" if row["errors"] else ""))
    return {"provider": provider, "engines": engines, "location": args.location or "", "gl": args.gl, "hl": args.hl, "device": args.device,
            "domain": own, "name": args.name, "aliases": args.alias or [], "questions_file": str(args.questions or ""),
            "checked_at": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
            "spent": {"usd": round(spent_usd, 4), "searches": spent_searches}, "questions": rows, "summary": summarize(rows)}


def summarize(rows) -> dict:
    out = {"questions_read": len(rows)}
    for engine in ("ai_overview", "ai_mode"):
        blocks = [r.get(engine) for r in rows if r.get(engine) is not None]
        shown = [b for b in blocks if b.get("shown") is True]
        out[engine] = {"read": len(blocks), "shown": len(shown), "own_cited": sum(1 for b in shown if b.get("own_cited")),
                       "own_named": sum(1 for b in shown if b.get("own_named")),
                       "could_not_read": sum(1 for b in blocks if b.get("shown") is None)}
    rivals = {}
    for r in rows:
        for engine in ("ai_overview", "ai_mode"):
            for d in (r.get(engine) or {}).get("others_cited") or []:
                rivals[d] = rivals.get(d, 0) + 1
    out["most_cited_instead"] = sorted(rivals.items(), key=lambda kv: -kv[1])[:10]
    return out


# ------------------------------------------------------------------ commands


def cmd_check(args) -> int:
    keys = read_keys()
    try:
        if args.provider == "dataforseo":
            status, data = http_json("GET", f"{DFS}/v3/appendix/user_data", dfs_auth(keys), service="DataForSEO")
            if status == 401:
                print("DataForSEO refused your login. The password it wants is the API one on its API Access page, not your account password.")
                return 1
            row = (((data or {}).get("tasks") or [{}])[0].get("result") or [{}])[0]
            money = row.get("money") if isinstance(row.get("money"), dict) else {}
            print("DataForSEO login works. That check was free." + (f" Balance: ${money['balance']:.2f}." if isinstance(money.get("balance"), (int, float)) else ""))
        else:
            key = keys.get("SERPAPI_KEY")
            if not key:
                print(f"Not set: SERPAPI_KEY needs to be in {KEYS_FILE}. The steps are in references/serpapi-setup.md.")
                return 3
            status, data = http_json("GET", f"{SERP}/account.json?" + urllib.parse.urlencode({"api_key": key}), service="SerpApi")
            if status != 200 or not isinstance(data, dict):
                print("SerpApi refused that key. Copy the private API key from its dashboard into SERPAPI_KEY again.")
                return 1
            print(f"SerpApi key works. Plan: {data.get('plan_name') or data.get('plan_id') or 'not given'}. "
                  f"Searches left this month: {data.get('total_searches_left', data.get('plan_searches_left', 'not given'))}. "
                  "That check read your account, not Google, so it ran no search.")
    except ServiceError as err:
        print(f"{err}.")
        return 1
    return 0


def room_for(args, keys, p) -> float:
    if args.provider == "dataforseo":
        ceiling = read_ceiling(keys, "DATAFORSEO_MAX_USD")
        if ceiling is None:
            die(f"Refused: there is no monthly ceiling. Nothing was bought. The owner opens {KEYS_FILE} in a text editor and adds a line like "
                "DATAFORSEO_MAX_USD=2, the most this computer may spend there in a calendar month. Claude does not set it.", 2)
        if args.cap_usd is None:
            die("Refused: no cap for this run. Show the owner the cost, and if they say yes, run it again with --cap-usd.", 2)
        if p["usd"] > args.cap_usd + 1e-9:
            die(f"Refused: this could cost ${p['usd']:.3f}, over your cap of ${args.cap_usd:.2f}. Nothing was bought.", 2)
        already = month_used("dataforseo")
        if already + p["usd"] > ceiling + 1e-9:
            die(f"Refused: ${already:.3f} is already spent this month and this could add ${p['usd']:.3f}, which passes your monthly ceiling of "
                f"${ceiling:.2f}. Nothing was bought. Only the owner changes DATAFORSEO_MAX_USD.", 2)
        return min(args.cap_usd, ceiling - already)
    ceiling = read_ceiling(keys, "SERPAPI_MAX_SEARCHES", default=SERP_FREE_MONTH)
    if ceiling is None:
        die("Refused: SERPAPI_MAX_SEARCHES in your key file is not a number. Nothing was searched.", 2)
    if args.cap_searches is None:
        die("Refused: no cap for this run. Show the owner how many searches it uses, and if they say yes, run it again with --cap-searches.", 2)
    already = month_used("serpapi")
    if already + min(p["searches"], args.cap_searches) > ceiling:
        die(f"Refused: {int(already)} SerpApi searches are already used this month and this could use {min(p['searches'], args.cap_searches)} more, "
            f"which passes your monthly ceiling of {int(ceiling)}. Nothing was searched.", 2)
    return min(args.cap_searches, ceiling - already)


def cmd_estimate(args) -> int:
    questions = load_questions(args.questions)
    engines = engines_of(args.engines)
    p = plan(questions, args.provider, engines)
    show_plan(p, args.provider, engines)
    keys = read_keys()
    if args.provider == "dataforseo":
        ceiling = read_ceiling(keys, "DATAFORSEO_MAX_USD")
        print(f"Monthly ceiling: ${ceiling:.2f}, with ${month_used('dataforseo'):.3f} spent so far." if ceiling else
              f"Monthly ceiling: not set. The owner adds DATAFORSEO_MAX_USD to {KEYS_FILE} before anything can be bought.")
    else:
        ceiling = read_ceiling(keys, "SERPAPI_MAX_SEARCHES", default=SERP_FREE_MONTH)
        print(f"Monthly ceiling: {int(ceiling or 0)} searches, with {int(month_used('serpapi'))} used so far on this computer.")
    print("Nothing was bought or searched.")
    return 0


def cmd_run(args) -> int:
    if args.same_as:
        before = load_json(args.same_as, "earlier answers file")
        for field in ("provider", "location", "gl", "hl", "device", "domain", "name"):
            setattr(args, field, before.get(field) if before.get(field) is not None else getattr(args, field))
        args.alias = before.get("aliases") or args.alias
        args.engines = ",".join(before.get("engines") or ["overview", "mode"])
        questions = [r["q"] for r in before.get("questions") or [] if r.get("q")]
        print(f"Using the same {len(questions)} questions, service, place and device as the run on {before.get('checked_at')}.")
    else:
        if not (args.questions and args.provider and args.domain and args.name):
            die("I need --questions, --provider, --domain and --name, or --same-as an earlier answers file.", 2)
        questions = load_questions(args.questions)
    if not questions:
        die("There are no questions to read.", 2)
    engines = engines_of(args.engines)
    keys = read_keys()
    p = plan(questions, args.provider, engines)
    show_plan(p, args.provider, engines)
    args.room = room_for(args, keys, p)
    if not args.confirm:
        print("Not started: run it again with --confirm once the owner has said yes to this cost.")
        return 4
    data = read_all(args, keys, questions, engines, args.provider)
    save_json(args.out, data)
    s = data["summary"]
    for engine, label in (("ai_overview", "AI Overviews"), ("ai_mode", "AI Mode")):
        if s[engine]["read"]:
            print(f"{label}: shown for {s[engine]['shown']} of {s[engine]['read']} questions. You are cited in {s[engine]['own_cited']} "
                  f"and named in {s[engine]['own_named']}. Could not read {s[engine]['could_not_read']}.")
    if s["most_cited_instead"]:
        print("Cited most often instead of you: " + ", ".join(f"{d} ({n})" for d, n in s["most_cited_instead"][:5]))
    spent = data["spent"]
    print((f"Spent ${spent['usd']:.4f} on your DataForSEO account, by its own count." if args.provider == "dataforseo"
           else f"Used {spent['searches']} SerpApi searches.") + f" Saved to {args.out}")
    print("This is one look from one place on one kind of device. AI answers change from search to search.")
    return 0


def main():
    ap = argparse.ArgumentParser(description="Read Google's AI answers for your customers' questions.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    one = sub.add_parser("check")
    one.add_argument("--provider", choices=["serpapi", "dataforseo"], required=True)
    two = sub.add_parser("estimate")
    two.add_argument("--questions", required=True)
    two.add_argument("--provider", choices=["serpapi", "dataforseo"], required=True)
    two.add_argument("--engines", default="overview,mode")
    three = sub.add_parser("run")
    three.add_argument("--questions")
    three.add_argument("--same-as", help="an earlier answers file: same questions, service, place and device")
    three.add_argument("--provider", choices=["serpapi", "dataforseo"])
    three.add_argument("--engines", default="overview,mode")
    three.add_argument("--domain", help="the owner's website")
    three.add_argument("--name", help="the business name as customers say it")
    three.add_argument("--alias", action="append", help="another name the business goes by; repeat for more")
    three.add_argument("--location", default="", help="City,State,Country, for local businesses")
    three.add_argument("--gl", default="us")
    three.add_argument("--hl", default="en")
    three.add_argument("--device", choices=["mobile", "desktop"], default="mobile")
    three.add_argument("--cap-usd", type=float)
    three.add_argument("--cap-searches", type=int)
    three.add_argument("--confirm", action="store_true")
    three.add_argument("--out", default="search-work/answers.json")
    args = ap.parse_args()
    return {"check": cmd_check, "estimate": cmd_estimate, "run": cmd_run}[args.cmd](args)


if __name__ == "__main__":
    run_main(main)
