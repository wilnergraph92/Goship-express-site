#!/usr/bin/env python3
"""apify_run.py: pull public social posts and comments through Apify, with a price and a cap in front of every run.

    python apify_run.py actors                                   what each platform costs and what it needs
    python apify_run.py check                                    proves the token works, spends nothing
    python apify_run.py estimate --plan plan.json                the price of a whole plan, spends nothing
    python apify_run.py run --plan plan.json --out folder --confirm [--yes-size N]
    python apify_run.py run-one --actor contacts --input in.json --max-items 50 --out items.json --confirm

Standard library only. The token comes from ~/.config/claude-skills/keys.env (APIFY_TOKEN=...), which
the person fills in themselves. It is never printed and never passed on a command line.

Two tiers, chosen in setup and saved in ~/.config/claude-skills/setup-lead-finder.json:
  basic  a whole plan stops at 500 results unless the person agrees to more (--allow-larger)
  full   no fixed result limit. Over 500 results, the person types yes to the exact size and
         Claude passes that same number as --yes-size, so a yes to 2,000 cannot run 9,000.
Both tiers keep the owner's own dollar ceiling for one run (APIFY_MAX_USD, $5 when unset), and the
real lock is the monthly limit Apify itself enforces on the account.

Nothing is spent unless --confirm is on the command line. Every run carries two limits on the Apify
side: maxItems (the most results you can be charged for) and maxTotalChargeUsd (the most the run can
cost). The actor's own limit fields are pulled down to the cap too, and add-ons that cost extra are
taken out of the input, because some actors treat an empty limit as "get everything".

Every actor here reads public data with Apify's own setup. None of them asks for, or uses, a login to
anyone's social media account, and nothing here opens or drives a browser on this computer.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def test_base(name: str, default: str) -> str:
    """Only the leg tests set this. It may only point at this computer, so a real key can never be sent elsewhere."""
    value = os.environ.get(name, "").rstrip("/")
    try:
        host = urllib.parse.urlsplit(value).hostname or ""
    except ValueError:
        host = ""
    return value if host in ("127.0.0.1", "localhost", "::1") else default


API = test_base("APIFY_BASE_URL", "https://api.apify.com/v2")
KEYS_FILE = Path.home() / ".config" / "claude-skills" / "keys.env"
SIGNUP = "https://console.apify.com/sign-up"
TOKEN_PAGE = "https://console.apify.com/settings/integrations"
PLAN_PAGE = "https://apify.com/pricing"
LIMITS_PAGE = "https://console.apify.com/billing#/limits"

DEFAULT_ITEMS = 500
PAGE = 1000
# The most one plan run may cost when the owner has set no APIFY_MAX_USD line. No flag can go past it.
DEFAULT_CEILING = 5.0
# The smallest charge limit Apify accepts on one run of a pay-per-result actor.
MIN_RUN_CAP = 0.50
TERMINAL = {"SUCCEEDED", "FAILED", "ABORTED", "TIMED-OUT"}

# Prices are the Apify free plan rates, the highest published, read on 2026-11-12 from each actor's
# pricing page. Paid plans pay the same or less per result. Check the pages if this file is old.
# "urls" says where a comments step puts the post links; "per_url" is the actor's own per-link limit.
ACTORS = {
    "instagram": {
        "id": "apify~instagram-scraper", "label": "Instagram Scraper", "platform": "instagram",
        "unit": "result", "per_item": 0.0027, "start": 0.0, "free_plan": True,
        "page": "https://apify.com/apify/instagram-scraper/pricing",
        "urls": ("directUrls", "plain"), "per_url": "resultsLimit",
        "strip": [],
        "note": "Posts for a hashtag, or comments on posts. The free plan returns only the newest 15 comments per post.",
    },
    "tiktok": {
        "id": "clockworks~tiktok-scraper", "label": "TikTok Scraper", "platform": "tiktok",
        "unit": "video", "per_item": 0.0037, "start": 0.001, "free_plan": True,
        "page": "https://apify.com/clockworks/tiktok-scraper/pricing",
        "strip": ["commentsPerPost", "topLevelCommentsPerPost", "maxRepliesPerComment", "maxFollowersPerProfile",
                  "maxFollowingPerProfile", "shouldDownloadVideos", "downloadSubtitlesOptions", "aiVideoDescription",
                  "aiVideoSummary", "videoSearchSorting", "videoSearchDateFilter", "oldestPostDateUnified",
                  "newestPostDate", "mostDiggs", "leastDiggs", "proxyCountryCode"],
        "note": "Videos for a search or hashtag. Paid extras are taken out of the input.",
    },
    "tiktok-comments": {
        "id": "clockworks~tiktok-comments-scraper", "label": "TikTok Comments Scraper", "platform": "tiktok",
        "unit": "comment", "per_item": 0.00125, "start": 0.0, "free_plan": True,
        "page": "https://apify.com/clockworks/tiktok-comments-scraper/pricing",
        "urls": ("postURLs", "plain"), "per_url": "commentsPerPost",
        "strip": [],
        "note": "Comments on TikTok videos.",
    },
    "linkedin": {
        "id": "harvestapi~linkedin-post-search", "label": "LinkedIn Post Search", "platform": "linkedin",
        "unit": "post", "per_item": 0.002, "start": 0.00005, "free_plan": True,
        "page": "https://apify.com/harvestapi/linkedin-post-search/pricing",
        "strip": ["scrapeReactions", "maxReactions", "scrapeComments", "maxComments"],
        "force": {"profileScraperMode": "short"},
        "note": "Posts for a search. Made by HarvestAPI, a partner, not Apify. It uses no LinkedIn account of yours.",
    },
    "linkedin-comments": {
        "id": "harvestapi~linkedin-post-comments", "label": "LinkedIn Post Comments", "platform": "linkedin",
        "unit": "comment", "per_item": 0.002, "start": 0.0, "free_plan": True,
        "page": "https://apify.com/harvestapi/linkedin-post-comments/pricing",
        "urls": ("posts", "plain"), "per_url": "maxItems",
        "strip": [], "force": {"profileScraperMode": "short"},
        "note": "Comments on LinkedIn posts. Same maker.",
    },
    "facebook-groups": {
        "id": "apify~facebook-groups-scraper", "label": "Facebook Groups Scraper", "platform": "facebook",
        "unit": "post", "per_item": 0.005, "start": 0.001, "free_plan": True,
        "page": "https://apify.com/apify/facebook-groups-scraper/pricing",
        "strip": ["onlyPostsNewerThan"],
        "note": "Posts in public groups you name. There is no keyword search. Private groups cannot be read.",
    },
    "facebook-search": {
        "id": "scraper_one~facebook-posts-search", "label": "Facebook Posts Search", "platform": "facebook",
        "unit": "post", "per_item": 0.005, "start": 0.00005, "free_plan": True, "free_per_query": 100,
        "page": "https://apify.com/scraper_one/facebook-posts-search/pricing",
        "strip": ["maxResults", "maxItems", "maxPosts", "resultsLimit"],
        "note": "Public Facebook posts for a keyword or hashtag, one search per step. Made by Scraper One, a community developer, "
                "not Apify. On the free plan Apify gives at most 100 posts per search.",
    },
    "facebook-comments": {
        "id": "apify~facebook-comments-scraper", "label": "Facebook Comments Scraper", "platform": "facebook",
        "unit": "comment", "per_item": 0.0025, "start": 0.001, "free_plan": True,
        "page": "https://apify.com/apify/facebook-comments-scraper/pricing",
        "urls": ("startUrls", "object"), "per_url": "resultsLimit",
        "strip": ["onlyCommentsNewerThan"],
        "note": "Comments on public Facebook posts.",
    },
    "x": {
        "id": "apidojo~tweet-scraper", "label": "Tweet Scraper V2", "platform": "x",
        "unit": "post", "per_item": 0.0004, "start": 0.0, "free_plan": False, "min_per_query": 50,
        "page": "https://apify.com/apidojo/tweet-scraper/pricing",
        "strip": [],
        "note": "Posts for a search. Needs a paid Apify plan: its maker blocks free accounts from using it this way. At least 50 posts per search.",
    },
    "youtube": {
        "id": "streamers~youtube-scraper", "label": "YouTube Scraper", "platform": "youtube",
        "unit": "video", "per_item": 0.004, "start": 0.0, "free_plan": True,
        "page": "https://apify.com/streamers/youtube-scraper/pricing",
        "strip": ["aiVideoDescription", "aiVideoSummary", "oldestPostDate"],
        "force": {"maxResultsShorts": 0, "maxResultStreams": 0, "transcriptionAndSubtitle": "NONE"},
        "note": "Videos for a search. Their commenters are usually the leads, not the creators.",
    },
    "youtube-comments": {
        "id": "streamers~youtube-comments-scraper", "label": "YouTube Comments Scraper", "platform": "youtube",
        "unit": "comment", "per_item": 0.002, "start": 0.0, "free_plan": True,
        "page": "https://apify.com/streamers/youtube-comments-scraper/pricing",
        "urls": ("startUrls", "object"), "per_url": "maxComments",
        "strip": [],
        "note": "Comments on YouTube videos.",
    },
    "contacts": {
        "id": "vdrmota~contact-info-scraper", "label": "Contact Details Scraper", "platform": "web",
        "unit": "page", "per_item": 0.002, "start": 0.001, "free_plan": True,
        "page": "https://apify.com/vdrmota/contact-info-scraper/pricing",
        "strip": ["maximumLeadsEnrichmentRecords", "leadsEnrichmentDepartments", "verifyLeadsEnrichmentEmails",
                  "scrapeSocialMediaProfiles", "useBrowser"],
        "force": {"mergeContacts": True, "sameDomain": True},
        "note": "Reads websites for published emails, for the email finder. Paid extras are taken out of the input.",
    },
}

# Where each kind of result keeps the link to the post, and how many comments it has, for comment steps.
POST_URL_FIELDS = ("url", "webVideoUrl", "linkedinUrl", "postUrl", "facebookUrl")
COMMENT_COUNT_FIELDS = ("commentsCount", "commentCount", "comments_count", "replyCount", "numComments")


def say(msg: str) -> None:
    print(msg, flush=True)


def tighten_keys() -> None:
    """Only this account should read the key file. Windows has no such mode bits, and keeps a home folder private itself."""
    if os.name == "nt":
        return
    for path, mode in ((KEYS_FILE.parent, 0o700), (KEYS_FILE, 0o600)):
        try:
            path.chmod(mode)
        except OSError:
            pass


def read_keys() -> dict:
    tighten_keys()
    keys = {}
    try:
        text = KEYS_FILE.read_text(encoding="utf-8-sig")
    except OSError:
        return keys
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        value = value.strip().strip('"').strip("'")
        if value:
            keys[name.replace("export ", "").strip()] = value
    return keys


def no_token_message() -> str:
    return (
        "I need an Apify token and there is none yet.\n"
        f"1. Make a free account: {SIGNUP} (no credit card).\n"
        f"2. Copy your API token from: {TOKEN_PAGE}\n"
        f"3. Open this file in a text editor, creating it if needed: {KEYS_FILE}\n"
        "4. Add one line: APIFY_TOKEN=your-token-here\n"
        "Do not paste the token into this chat. Then run this again."
    )


def tier() -> str:
    """full or basic, from the setup progress file. Anything else counts as basic."""
    try:
        data = json.loads((KEYS_FILE.parent / "setup-lead-finder.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return "basic"
    return "full" if isinstance(data, dict) and data.get("tier") == "full" else "basic"


def size_refusal(items: int, total: float, a) -> str | None:
    """The result-count check. Basic: 500 unless --allow-larger. Full: over 500 needs --yes-size equal to the plan's size."""
    if items <= DEFAULT_ITEMS:
        return None
    if tier() == "full":
        if getattr(a, "yes_size", None) == items:
            return None
        return (f"This asks for {items:,} results, about ${total:.2f}. Over {DEFAULT_ITEMS} results, the person has to type yes to "
                f"this exact size first. Show them the estimate, and after their yes run the same command with --yes-size {items}.")
    if getattr(a, "allow_larger", False):
        return None
    return (f"This asks for {items:,} results. The default is {DEFAULT_ITEMS}. Ask the person first and show "
            "the estimate. If they say yes, add --allow-larger. The full tier has no fixed result limit.")


def spend_ceiling() -> float:
    """The owner's own limit for one plan run, from a line in the key file that they edit themselves."""
    try:
        value = float(read_keys().get("APIFY_MAX_USD", ""))
    except ValueError:
        return DEFAULT_CEILING
    return value if 0 < value < float("inf") else DEFAULT_CEILING


def ceiling_refusal(ceiling: float) -> str:
    return (f"This is over your spending ceiling of ${ceiling:.2f} for one run, so I did not start it. No setting I can pass goes past it. "
            f"Only you can raise it: open {KEYS_FILE} in a text editor and add or change one line, such as APIFY_MAX_USD=20.")


def step_cost(actor: dict, items: int) -> float:
    return items * actor["per_item"] + actor["start"]


def default_cap(est: float) -> float:
    """A little room above the estimate, rounded up to the cent, so a small overrun stops the run."""
    return max(0.05, math.ceil(est * 120) / 100)


# ---------------------------------------------------------------- the plan

def load_plan(path) -> dict:
    try:
        plan = json.loads(Path(path).read_text(encoding="utf-8-sig"))
    except OSError:
        raise SystemExit(f"I could not find the plan file: {path}")
    except ValueError as exc:
        raise SystemExit(f"The plan file {path} is not valid JSON: {exc}")
    if not isinstance(plan, dict) or not isinstance(plan.get("steps"), list) or not plan["steps"]:
        raise SystemExit("The plan needs a list of steps. Each step has an id, an actor, max_items and an input.")
    seen = set()
    for step in plan["steps"]:
        if not isinstance(step, dict):
            raise SystemExit("Each step in the plan has to be an object.")
        sid = str(step.get("id") or "")
        if not sid or not sid.replace("-", "").replace("_", "").isalnum() or sid in seen:
            raise SystemExit(f"Each step needs its own short id made of letters, numbers and dashes. This one is not: {sid!r}")
        seen.add(sid)
        if step.get("actor") not in ACTORS:
            raise SystemExit(f"Step {sid}: I do not know the actor {step.get('actor')!r}. I know: {', '.join(sorted(ACTORS))}.")
        if not isinstance(step.get("max_items"), int) or step["max_items"] < 1:
            raise SystemExit(f"Step {sid}: max_items has to be a whole number of at least 1.")
        if not isinstance(step.get("input", {}), dict):
            raise SystemExit(f"Step {sid}: input has to be one JSON object.")
        src = step.get("comments_on")
        if src is not None:
            if src not in seen or src == sid:
                raise SystemExit(f"Step {sid}: comments_on has to name an earlier step.")
            if "urls" not in ACTORS[step["actor"]]:
                raise SystemExit(f"Step {sid}: the {step['actor']} actor does not read comments from post links.")
    return plan


def plan_lines(plan: dict) -> tuple:
    lines, total, items = [], 0.0, 0
    for step in plan["steps"]:
        actor = ACTORS[step["actor"]]
        est = step_cost(actor, step["max_items"])
        total += est
        items += step["max_items"]
        on = f", on the top posts from {step['comments_on']}" if step.get("comments_on") else ""
        paid = "" if actor["free_plan"] else " NEEDS A PAID APIFY PLAN."
        if actor.get("free_per_query") and step["max_items"] > actor["free_per_query"]:
            paid += f" On the free plan Apify returns at most {actor['free_per_query']} per search."
        lines.append(f"  {step['id']}: {actor['label']}, up to {step['max_items']:,} {actor['unit']}s{on}, about ${est:.2f}.{paid}")
    return lines, total, items


def estimate_text(plan: dict, cap: float) -> list:
    lines, total, items = plan_lines(plan)
    size_rule = (f"Full tier: no fixed result limit. Over {DEFAULT_ITEMS} results needs a typed yes to the exact size."
                 if tier() == "full" else f"Basic tier: a plan stops at {DEFAULT_ITEMS} results unless you agree to more.")
    out = ["Plan, at Apify's free plan rates:"] + lines + [
        f"Total: up to {items:,} results, about ${total:.2f}.",
        size_rule,
        f"Cap: the whole plan stops at ${cap:.2f}. Each step also stops at its own item limit.",
        f"Your ceiling for one run is ${spend_ceiling():.2f}. Only you can change it, in your key file (APIFY_MAX_USD).",
        "Apify's free plan includes $5 of usage a month with no card. When it runs out, runs are blocked until the next month. "
        "On a paid plan, use past the plan's credit goes on your next invoice.",
        f"For a hard monthly limit that Apify itself enforces, set one at {LIMITS_PAGE}",
        "A result is one post or one comment, not one lead. Many results come from the same person, and many people will not fit.",
        f"Prices: each actor's pricing page, and {PLAN_PAGE}",
    ]
    return out


def fit_input(key: str, run_input: dict, items: int, urls=None) -> tuple:
    """Hold the actor's own limits to the cap, take out add-ons that cost extra, and never trust the input file."""
    actor = ACTORS[key]
    run_input = dict(run_input)
    removed = [k for k in actor.get("strip", []) if k in run_input]
    for k in removed:
        run_input.pop(k)
    run_input.update(actor.get("force", {}))

    def limit(field, sources):
        each = max(1, items // max(1, sources))
        have = run_input.get(field)
        run_input[field] = min(have, each) if isinstance(have, int) and have > 0 else each

    if urls is not None and "urls" in actor:
        field, shape = actor["urls"]
        run_input[field] = [{"url": u} for u in urls] if shape == "object" else list(urls)
        if key == "instagram":
            run_input["resultsType"] = "comments"
            run_input.pop("search", None)
    if (key == "instagram" and urls is None and run_input.get("search")
            and run_input.get("searchType", "hashtag") == "hashtag" and run_input.get("resultsType", "posts") == "posts"):
        # A hashtag search returns the hashtag itself (often the wrong one), not its posts. The tag page
        # returns the posts. Found on a real run, 2026-11-12.
        tags = [t.strip().lstrip("#") for t in str(run_input.pop("search")).split(",") if t.strip().lstrip("#")][:5]
        run_input["directUrls"] = [f"https://www.instagram.com/explore/tags/{t}/" for t in tags]
        run_input.pop("searchType", None)
        run_input.pop("searchLimit", None)
    if key == "instagram":
        sources = len(run_input.get("directUrls") or []) or (run_input.get("searchLimit") or 1)
        if run_input.get("search"):
            run_input["searchLimit"] = min(int(run_input.get("searchLimit") or 1), 5)
            sources = run_input["searchLimit"]
        limit("resultsLimit", sources)
    elif key == "tiktok":
        limit("resultsPerPage", len(run_input.get("searchQueries") or []) + len(run_input.get("hashtags") or []) + len(run_input.get("profiles") or []))
        if run_input.get("searchSection") == "/user":
            limit("maxProfilesPerQuery", len(run_input.get("searchQueries") or []))
    elif key == "linkedin":
        limit("maxPosts", len(run_input.get("searchQueries") or []))
    elif key == "facebook-groups":
        run_input["resultsLimit"] = min(run_input.get("resultsLimit"), items) if isinstance(run_input.get("resultsLimit"), int) and run_input.get("resultsLimit") > 0 else items
    elif key == "facebook-search":
        run_input["resultsCount"] = min(run_input.get("resultsCount"), items) if isinstance(run_input.get("resultsCount"), int) and run_input.get("resultsCount") > 0 else items
    elif key == "x":
        run_input["maxItems"] = min(run_input.get("maxItems"), items) if isinstance(run_input.get("maxItems"), int) and run_input.get("maxItems") > 0 else items
    elif key == "youtube":
        limit("maxResults", len(run_input.get("searchQueries") or []) + len(run_input.get("startUrls") or []))
    elif key == "contacts":
        run_input["maxRequests"] = min(run_input.get("maxRequests"), items) if isinstance(run_input.get("maxRequests"), int) and run_input.get("maxRequests") > 0 else items
        run_input["maxRequestsPerStartUrl"] = min(int(run_input.get("maxRequestsPerStartUrl") or 4), 4)
        run_input["maxDepth"] = min(int(run_input.get("maxDepth") or 1), 2)
        run_input.setdefault("proxyConfig", {"useApifyProxy": True})
    if "per_url" in actor and run_input.get(actor["urls"][0]):
        limit(actor["per_url"], len(run_input.get(actor["urls"][0]) or []))
    return run_input, removed


def is_comments(key: str, run_input: dict) -> bool:
    return key.endswith("-comments") or (key == "instagram" and run_input.get("resultsType") == "comments")


def input_problem(key: str, run_input: dict, items: int):
    actor = ACTORS[key]
    if key == "x":
        terms = len(run_input.get("searchTerms") or []) or 1
        if items // terms < actor["min_per_query"]:
            return (f"The X actor needs at least {actor['min_per_query']} posts per search. With {terms} searches, "
                    f"max_items has to be at least {terms * actor['min_per_query']}.")
    if key == "facebook-search" and not (isinstance(run_input.get("query"), str) and 0 < len(run_input["query"].strip()) <= 100):
        return "The Facebook search step needs one search in query, up to 100 characters. Use one step per search."
    if is_comments(key, run_input) and not run_input.get(actor["urls"][0]):
        return f"This step has no post links to read comments from ({actor['urls'][0]} is empty)."
    return None


def top_post_urls(items: list, n: int) -> list:
    def count(item):
        for f in COMMENT_COUNT_FIELDS:
            v = item.get(f)
            if isinstance(v, (int, float)):
                return v
        eng = item.get("engagement")
        if isinstance(eng, dict) and isinstance(eng.get("comments"), (int, float)):
            return eng["comments"]
        return 0
    urls, seen = [], set()
    for item in sorted((i for i in items if isinstance(i, dict)), key=count, reverse=True):
        url = next((item.get(f) for f in POST_URL_FIELDS if isinstance(item.get(f), str) and item.get(f).startswith("http")), None)
        if url and url not in seen and count(item) > 0:
            seen.add(url)
            urls.append(url)
        if len(urls) >= n:
            break
    return urls


# ---------------------------------------------------------------- Apify

def plain_http_error(status: int, body: str) -> str:
    low = body.lower()
    if status == 401:
        return ("Apify rejected the token. Copy it again from "
                f"{TOKEN_PAGE} into {KEYS_FILE} and run this again.")
    if status == 402 or "limit" in low and status == 403 or "insufficient" in low:
        return ("Apify says this account is out of usage credit, or the plan does not allow this run. "
                "Check the balance at https://console.apify.com/billing. Nothing else was started.")
    if status == 404:
        return ("Apify cannot find this actor. It may have been renamed. "
                "Look it up in the Apify Store and tell me the new name.")
    if status == 429:
        return "Apify says too many requests right now. Wait a minute and run this again."
    if status >= 500:
        return "Apify is having a problem on its side. Try again in a few minutes."
    detail = ""
    try:
        detail = str((json.loads(body).get("error") or {}).get("message") or "")[:300]
    except (ValueError, AttributeError):
        pass
    return (f"Apify refused the request (status {status})" + (f": {detail}" if detail else "")
            + ". Fix that part of the step's input and try again.")


class Client:
    def __init__(self, token: str):
        self.token = token

    def call(self, method: str, path: str, query: dict | None = None, body=None, timeout: int = 90):
        url = API + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        data = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", f"Bearer {self.token}")
        req.add_header("User-Agent", "claude-skill-lead-finder")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.loads(r.read().decode("utf-8", "replace"))
        except urllib.error.HTTPError as exc:
            raise RuntimeError(plain_http_error(exc.code, exc.read().decode("utf-8", "replace"))) from None
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            reason = getattr(exc, "reason", exc)
            raise RuntimeError(f"Could not reach Apify ({reason}). Check your connection and try again.") from None
        except ValueError:
            raise RuntimeError("Apify sent back something I could not read. Try again in a few minutes.") from None


def wait_for(client: Client, run: dict, minutes: float) -> dict:
    deadline = time.time() + minutes * 60
    while run.get("status") not in TERMINAL:
        left = deadline - time.time()
        if left <= 0:
            say(f"This run passed the {minutes:g} minute limit, so I am stopping it to stop the spend.")
            try:
                run = client.call("POST", f"/actor-runs/{run['id']}/abort", body={})["data"]
            except RuntimeError as exc:
                say(f"I could not stop it: {exc} Stop it by hand at https://console.apify.com/actors/runs")
            return run
        wait = int(min(30, max(1, left)))
        run = client.call("GET", f"/actor-runs/{run['id']}", {"waitForFinish": wait}, timeout=wait + 60)["data"]
        time.sleep(1)
        if run.get("status") not in TERMINAL:
            say(f"Still running ({run.get('status')}).")
    return run


def plan_id(client: Client) -> str:
    try:
        me = client.call("GET", "/users/me").get("data") or {}
    except RuntimeError:
        return ""
    return str((me.get("plan") or {}).get("id") or "")


def run_actor(client: Client, key: str, run_input: dict, items: int, cap: float, minutes: float) -> tuple:
    actor = ACTORS[key]
    # Apify refuses pay-per-result runs whose charge limit is under $0.50 (found on a real run, 2026-11-12).
    # The floor is safe: maxItems still stops the run, and the plan already checked this step's estimate fits.
    query = {"maxItems": items, "maxTotalChargeUsd": f"{max(cap, MIN_RUN_CAP):.2f}", "timeout": int(minutes * 60)}
    run = client.call("POST", f"/actors/{actor['id']}/runs", query, run_input)["data"]
    say(f"Started {actor['label']} (run {run.get('id')}). This can take a few minutes.")
    run = wait_for(client, run, minutes)
    got = []
    dataset = run.get("defaultDatasetId")
    # Read the results a page at a time, so a run of thousands does not come back as one huge answer.
    while dataset and len(got) < items:
        want = min(PAGE, items - len(got))
        page = client.call("GET", f"/datasets/{dataset}/items",
                           {"format": "json", "clean": "true", "offset": len(got), "limit": want}, timeout=180)
        if not isinstance(page, list) or not page:
            break
        got += page
        if len(page) < want:
            break
    return run, got[:items]


def step_minutes(items: int, floor: float) -> float:
    """Bigger steps get longer before they are stopped: about a minute per 50 results, up to three hours."""
    return max(floor, min(180.0, items / 50))


def charged(run: dict) -> float:
    spent = run.get("usageTotalUsd")
    return float(spent) if isinstance(spent, (int, float)) else 0.0


# ---------------------------------------------------------------- commands

def need_token():
    token = read_keys().get("APIFY_TOKEN", "")
    if not token or "your-token" in token:
        say(no_token_message())
        return None
    return token


def do_actors() -> int:
    say("What each platform costs at Apify's free plan rates, read 2026-11-12. Paid plans pay the same or less.")
    for key, a in ACTORS.items():
        plan = "free plan works" if a["free_plan"] else "needs a paid Apify plan"
        say(f"- {key}: {a['label']} ({a['id'].replace('~', '/')}), ${a['per_item'] * 1000:.2f} per 1,000 {a['unit']}s, {plan}. {a['note']}")
        say(f"  {a['page']}")
    return 0


def do_check() -> int:
    """A real read that spends nothing, to prove the token works."""
    token = need_token()
    if not token:
        return 3
    client = Client(token)
    try:
        me = client.call("GET", "/users/me").get("data") or {}
    except RuntimeError as exc:
        say(str(exc))
        return 1
    plan = (me.get("plan") or {}).get("id") or "unknown"
    say(f"Apify token works. Account: {me.get('username') or 'unnamed'}. Plan: {plan}.")
    if str(plan).upper() == "FREE":
        say("On the free plan, X (Twitter) does not work through this skill. Every other platform does.")
    try:
        limits = client.call("GET", "/users/me/limits").get("data") or {}
        used = (limits.get("current") or {}).get("monthlyUsageUsd")
        most = (limits.get("limits") or {}).get("maxMonthlyUsageUsd")
        if isinstance(used, (int, float)) and isinstance(most, (int, float)):
            say(f"Used this month: ${used:.2f} of ${most:.2f}.")
    except RuntimeError:
        pass
    return 0


def plan_cap(plan: dict, a) -> tuple:
    """(cap, refusal or None)"""
    _, total, items = plan_lines(plan)
    ceiling = spend_ceiling()
    refusal = size_refusal(items, total, a)
    if refusal:
        return 0.0, refusal
    if round(total, 6) > ceiling or (a.max_usd is not None and a.max_usd > ceiling):
        return 0.0, ceiling_refusal(ceiling)
    cap = a.max_usd if a.max_usd is not None else min(default_cap(total), ceiling)
    if round(total, 6) > cap:
        return 0.0, (f"The estimate (${total:.2f}) is above the cap (${cap:.2f}), so I did not start it. "
                     "Lower max_items or raise --max-usd after asking the person.")
    return cap, None


def do_estimate(a) -> int:
    plan = load_plan(a.plan)
    _, total, _ = plan_lines(plan)
    cap = a.max_usd if a.max_usd is not None else min(default_cap(total), spend_ceiling())
    for line in estimate_text(plan, cap):
        say(line)
    return 0


def do_run(a) -> int:
    plan = load_plan(a.plan)
    cap, refusal = plan_cap(plan, a)
    if refusal:
        say(refusal)
        for line in estimate_text(plan, default_cap(plan_lines(plan)[1])):
            say(line)
        return 4
    for line in estimate_text(plan, cap):
        say(line)
    for step in plan["steps"]:
        if not step.get("comments_on"):
            fitted, _ = fit_input(step["actor"], step.get("input", {}), step["max_items"])
            problem = input_problem(step["actor"], fitted, step["max_items"])
            if problem:
                say(f"Step {step['id']}: {problem} Nothing was started.")
                return 2
    if not a.confirm:
        say("Not started. Show this to the person. If they say yes, run the same command with --confirm.")
        return 4
    token = need_token()
    if not token:
        return 3
    client = Client(token)
    if any(not ACTORS[s["actor"]]["free_plan"] for s in plan["steps"]):
        if plan_id(client).upper() in ("FREE", ""):
            say("This plan has an X step, and X needs a paid Apify plan, which this account does not have (or I could not tell). "
                "Take the X step out, or upgrade at https://console.apify.com/billing . Nothing was started.")
            return 4

    out = Path(a.out)
    (out / "raw").mkdir(parents=True, exist_ok=True)
    manifest = {"steps": [], "cap_usd": cap}
    spent, results = 0.0, {}
    for step in plan["steps"]:
        key, sid = step["actor"], step["id"]
        actor = ACTORS[key]
        urls = None
        if step.get("comments_on"):
            urls = top_post_urls(results.get(step["comments_on"], []), int(step.get("top_posts") or 10))
            if not urls:
                say(f"Step {sid}: the step it reads from found no posts with comments, so I skipped it.")
                continue
        run_input, removed = fit_input(key, step.get("input", {}), step["max_items"], urls)
        if removed:
            say(f"Step {sid}: took out {', '.join(removed)}, because each costs extra or could lift the limit.")
        problem = input_problem(key, run_input, step["max_items"])
        if problem:
            say(f"Step {sid}: {problem} Skipped.")
            continue
        est = step_cost(actor, step["max_items"])
        left = round(cap - spent, 2)
        if est > left + 1e-9:
            say(f"Step {sid} would cost about ${est:.2f} and only ${max(left, 0):.2f} of the cap is left, so I stopped here.")
            break
        step_cap = min(left, default_cap(est))
        try:
            run, got = run_actor(client, key, run_input, step["max_items"], step_cap, step_minutes(step["max_items"], a.wait_minutes))
        except RuntimeError as exc:
            say(f"Step {sid}: {exc}")
            if "out of usage credit" in str(exc) or "rejected the token" in str(exc):
                break
            continue
        spent += charged(run) or 0.0
        results[sid] = got
        path = out / "raw" / f"{sid}.json"
        path.write_text(json.dumps(got, indent=1, ensure_ascii=False), encoding="utf-8")
        manifest["steps"].append({"id": sid, "actor": key, "platform": actor["platform"], "kind": "comments" if is_comments(key, run_input) else "posts",
                                  "file": f"raw/{sid}.json", "items": len(got), "status": run.get("status"), "run_id": run.get("id"),
                                  "charged_usd": run.get("usageTotalUsd"), "cap_usd": step_cap, "estimate_usd": round(est, 4)})
        say(f"Step {sid}: {run.get('status')}, {len(got)} {actor['unit']}s. Charged: ${charged(run):.2f}.")
    manifest["charged_usd"] = round(spent, 4)
    (out / "raw" / "manifest.json").write_text(json.dumps(manifest, indent=1), encoding="utf-8")
    say(f"Done. Charged in total: ${spent:.2f} of a ${cap:.2f} cap. Results are in {out / 'raw'}.")
    return 0 if manifest["steps"] else 1


def do_run_one(a) -> int:
    """One actor run, for the email finder's contact step."""
    actor = ACTORS[a.actor]
    if a.max_items < 1:
        say("The most items for a run has to be at least 1.")
        return 2
    est = step_cost(actor, a.max_items)
    refusal = size_refusal(a.max_items, est, a)
    if refusal:
        say(refusal)
        return 4
    ceiling = spend_ceiling()
    if round(est, 6) > ceiling or (a.max_usd is not None and a.max_usd > ceiling):
        say(ceiling_refusal(ceiling))
        return 4
    cap = a.max_usd if a.max_usd is not None else min(default_cap(est), ceiling)
    if round(est, 6) > cap:
        say(f"The estimate (${est:.2f}) is above the cap (${cap:.2f}), so I did not start it.")
        return 4
    say(f"Actor: {actor['label']} ({actor['id'].replace('~', '/')})")
    say(f"Estimate: up to {a.max_items} {actor['unit']}s = about ${est:.2f} at Apify's free plan rates. Cap: ${cap:.2f}.")
    say(f"Prices: {actor['page']}")
    if not a.confirm:
        say("Not started. Show this to the person. If they say yes, run the same command with --confirm.")
        return 4
    token = need_token()
    if not token:
        return 3
    try:
        run_input = json.loads(Path(a.input).read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as exc:
        say(f"I could not read the input file {a.input}: {exc}")
        return 2
    if not isinstance(run_input, dict):
        say(f"The input file {a.input} has to hold one JSON object.")
        return 2
    run_input, removed = fit_input(a.actor, run_input, a.max_items)
    if removed:
        say(f"Took out {', '.join(removed)}, because each costs extra or could lift the limit.")
    try:
        run, got = run_actor(Client(token), a.actor, run_input, a.max_items, cap, step_minutes(a.max_items, a.wait_minutes))
    except RuntimeError as exc:
        say(str(exc))
        return 1
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(got, indent=1, ensure_ascii=False), encoding="utf-8")
    say(f"Finished with status {run.get('status')}: {len(got)} {actor['unit']}s saved to {out}. Charged: ${charged(run):.2f}.")
    return 0 if got or run.get("status") == "SUCCEEDED" else 1


def main() -> int:
    ap = argparse.ArgumentParser(description="Run Apify actors behind an estimate and a spend cap.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check", help="prove the token works, spending nothing")
    sub.add_parser("actors", help="list each platform's actor and price")
    for name in ("estimate", "run"):
        p = sub.add_parser(name)
        p.add_argument("--plan", required=True)
        p.add_argument("--max-usd", type=float)
        if name == "run":
            p.add_argument("--out", required=True, help="the folder for raw results")
            p.add_argument("--confirm", action="store_true", help="the person said yes to the estimate")
            p.add_argument("--allow-larger", action="store_true", help="basic tier: the person said yes to more than the default")
            p.add_argument("--yes-size", type=int, help="full tier: the exact number of results the person typed yes to")
            p.add_argument("--wait-minutes", type=float, default=20)
    p = sub.add_parser("run-one")
    p.add_argument("--actor", choices=sorted(ACTORS), required=True)
    p.add_argument("--input", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--max-items", type=int, default=100)
    p.add_argument("--max-usd", type=float)
    p.add_argument("--confirm", action="store_true")
    p.add_argument("--allow-larger", action="store_true")
    p.add_argument("--yes-size", type=int)
    p.add_argument("--wait-minutes", type=float, default=20)
    a = ap.parse_args()
    try:
        if a.cmd == "check":
            return do_check()
        if a.cmd == "actors":
            return do_actors()
        if a.cmd == "estimate":
            return do_estimate(a)
        if a.cmd == "run-one":
            return do_run_one(a)
        return do_run(a)
    except SystemExit as exc:
        if isinstance(exc.code, str):
            say(exc.code)
            return 2
        raise
    except KeyboardInterrupt:
        say("Stopped. If a run had started, check https://console.apify.com/actors/runs")
        return 1
    except Exception as exc:  # a stranger should never see a stack trace
        say(f"Something went wrong: {exc}. Nothing else was started. Tell me what you were doing and I will look.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
