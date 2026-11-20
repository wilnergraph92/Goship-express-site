#!/usr/bin/env python3
"""apify_run.py: run one Apify actor with a price estimate and a spend cap in front of it.

    python apify_run.py estimate --actor maps --max-items 100 [--contacts]
    python apify_run.py run --actor maps --input input.json --max-items 100 --out items.json --confirm
    python apify_run.py check     proves the token works, spends nothing

Standard library only. The token comes from ~/.config/claude-skills/keys.env (APIFY_TOKEN=...), which
the person fills in themselves. It is never printed and never passed on a command line.

Nothing is spent unless --confirm is on the command line. Without it, "run" prints the estimate and
stops before any network call. Every run carries two limits on the Apify side: maxItems (the most
results you can be charged for) and maxTotalChargeUsd (the most the whole run can cost).
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

DEFAULT_ITEMS = 100
# The most one run may cost when the owner has set no APIFY_MAX_USD line. No flag can go past the ceiling.
DEFAULT_CEILING = 5.0
TERMINAL = {"SUCCEEDED", "FAILED", "ABORTED", "TIMED-OUT"}

# Prices are the Apify free plan rates, the highest published, read on 2026-11-04.
# Paid plans pay less per result. Check the pages if this file is old.
ACTORS = {
    "maps": {
        "id": "compass~crawler-google-places",
        "label": "Google Maps Scraper",
        "unit": "place",
        "per_item": 0.004,
        "start": 0.00005,
        "addons": {"contacts": ("website contact details", 0.002)},
        "page": "https://apify.com/compass/crawler-google-places/pricing",
    },
    "ads": {
        "id": "apify~facebook-ads-scraper",
        "label": "Facebook Ads Library Scraper",
        "unit": "ad",
        "per_item": 0.0058,
        "start": 0.0,
        "addons": {},
        "page": "https://apify.com/apify/facebook-ads-scraper/pricing",
    },
}


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


def spend_ceiling() -> float:
    """The owner's own limit for one run, from a line in the key file that they edit themselves."""
    try:
        value = float(read_keys().get("APIFY_MAX_USD", ""))
    except ValueError:
        return DEFAULT_CEILING
    return value if 0 < value < float("inf") else DEFAULT_CEILING


def ceiling_refusal(ceiling: float) -> str:
    return (f"This is over your spending ceiling of ${ceiling:.2f} for one run, so I did not start it. No setting I can pass goes past it. "
            f"Only you can raise it: open {KEYS_FILE} in a text editor and add or change one line, such as APIFY_MAX_USD=20.")


def estimate(actor: dict, items: int, addons: list) -> float:
    each = actor["per_item"]
    for name in addons:
        each += actor["addons"][name][1]
    return items * each + actor["start"]


def default_cap(est: float) -> float:
    """A little room above the estimate, rounded up to the cent, so a small overrun stops the run."""
    return max(0.05, math.ceil(est * 120) / 100)


def estimate_lines(key: str, items: int, addons: list, cap: float) -> list:
    actor = ACTORS[key]
    est = estimate(actor, items, addons)
    extras = "".join(f" plus {actor['addons'][a][0]}" for a in addons)
    return [
        f"Actor: {actor['label']} ({actor['id'].replace('~', '/')}){extras}",
        f"Estimate: up to {items} {actor['unit']}s = about ${est:.2f} at Apify's free plan rates.",
        f"Cap: this run stops at {items} {actor['unit']}s or ${cap:.2f}, whichever comes first.",
        f"Your ceiling for one run is ${spend_ceiling():.2f}. Only you can change it, in your key file (APIFY_MAX_USD).",
        "Apify's free plan includes $5 of usage a month with no card. When it runs out, runs are "
        "blocked until the next month. On a paid plan, use past the plan's credit goes on your next invoice.",
        f"Prices: {actor['page']} and {PLAN_PAGE}",
    ]


def fit_input(key: str, run_input: dict, items: int) -> dict:
    """Hold the actor's own limit to the cap too. Both actors treat an empty limit as get everything,
    and the Maps actor charges per event, so maxItems alone does not stop it. Never trust the input file."""
    run_input = dict(run_input)
    if key == "maps":
        terms = max(1, len(run_input.get("searchStringsArray") or []) + len(run_input.get("startUrls") or []) + len(run_input.get("placeIds") or []))
        limit = max(1, items // terms)
        have = run_input.get("maxCrawledPlacesPerSearch")
        run_input["maxCrawledPlacesPerSearch"] = min(have, limit) if isinstance(have, int) and have > 0 else limit
    elif key == "ads":
        sources = max(1, len(run_input.get("startUrls") or []))
        limit = max(1, items // sources)
        have = run_input.get("resultsLimit")
        run_input["resultsLimit"] = min(have, limit) if isinstance(have, int) and have > 0 else limit
    return run_input


def plain_http_error(status: int, body: str) -> str:
    low = body.lower()
    if status == 401:
        return ("Apify rejected the token. Copy it again from "
                f"{TOKEN_PAGE} into {KEYS_FILE} and run this again.")
    if status == 402 or "limit" in low and status == 403 or "insufficient" in low:
        return ("Apify says this account is out of usage credit, or the plan does not allow this run. "
                f"Check the balance at https://console.apify.com/billing. Nothing else was started.")
    if status == 404:
        return ("Apify cannot find this actor. It may have been renamed. "
                "Look it up in the Apify Store and tell me the new name.")
    if status == 429:
        return "Apify says too many requests right now. Wait a minute and run this again."
    if status >= 500:
        return "Apify is having a problem on its side. Try again in a few minutes."
    return f"Apify refused the request (status {status}). Check the input file and try again."


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
        req.add_header("User-Agent", "claude-skill-apify-run")
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


def do_run(a) -> int:
    key = a.actor
    actor = ACTORS[key]
    addons = a.addon or []
    if a.max_items < 1:
        say("The most items for a run has to be at least 1.")
        return 2
    if a.max_items > DEFAULT_ITEMS and not a.allow_larger:
        say(f"This asks for {a.max_items} {actor['unit']}s. The default is {DEFAULT_ITEMS}. "
            "Ask the person first and show the estimate below. If they say yes, add --allow-larger.")
        for line in estimate_lines(key, a.max_items, addons, default_cap(estimate(actor, a.max_items, addons))):
            say(line)
        return 4
    est = estimate(actor, a.max_items, addons)
    ceiling = spend_ceiling()
    if round(est, 6) > ceiling or (a.max_usd is not None and a.max_usd > ceiling):
        say(ceiling_refusal(ceiling))
        return 4
    cap = a.max_usd if a.max_usd is not None else min(default_cap(est), ceiling)
    if round(est, 6) > cap:
        say(f"The estimate (${est:.2f}) is above the cap (${cap:.2f}), so I did not start it. "
            "Lower --max-items or raise --max-usd after asking the person.")
        return 4
    for line in estimate_lines(key, a.max_items, addons, cap):
        say(line)
    if not a.confirm:
        say("Not started. Show this to the person. If they say yes, run the same command with --confirm.")
        return 4

    token = read_keys().get("APIFY_TOKEN", "")
    if not token or "your-token" in token:
        say(no_token_message())
        return 3
    try:
        run_input = json.loads(Path(a.input).read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as exc:
        say(f"I could not read the input file {a.input}: {exc}")
        return 2
    if not isinstance(run_input, dict):
        say(f"The input file {a.input} has to hold one JSON object.")
        return 2
    run_input = fit_input(key, run_input, a.max_items)

    client = Client(token)
    query = {"maxItems": a.max_items, "maxTotalChargeUsd": f"{cap:.2f}",
             "timeout": int(a.wait_minutes * 60)}
    try:
        run = client.call("POST", f"/actors/{actor['id']}/runs", query, run_input)["data"]
        say(f"Started run {run.get('id')}. This can take a few minutes.")
        run = wait_for(client, run, a.wait_minutes)
        status = run.get("status")
        items = []
        dataset = run.get("defaultDatasetId")
        if dataset:
            items = client.call("GET", f"/datasets/{dataset}/items",
                                {"format": "json", "clean": "true", "limit": a.max_items}, timeout=180)
    except RuntimeError as exc:
        say(str(exc))
        return 1
    if not isinstance(items, list):
        items = []
    items = items[: a.max_items]
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(items, indent=1, ensure_ascii=False), encoding="utf-8")
    spent = run.get("usageTotalUsd")
    receipt = {"actor": actor["id"], "run_id": run.get("id"), "status": status, "items": len(items),
               "max_items": a.max_items, "cap_usd": cap, "estimate_usd": round(est, 4),
               "charged_usd": spent, "charged_events": run.get("chargedEventCounts")}
    out.with_suffix(".run.json").write_text(json.dumps(receipt, indent=1), encoding="utf-8")
    cost = f"${spent:.2f}" if isinstance(spent, (int, float)) else "see your Apify usage page"
    say(f"Finished with status {status}: {len(items)} {actor['unit']}s saved to {out}. Charged: {cost}.")
    if status == "SUCCEEDED":
        return 0
    if items:
        say("The run did not finish cleanly, often because it reached the cap. These results are partial.")
        return 0
    say(f"The run ended with status {status} and no results. Details: "
        f"https://console.apify.com/actors/runs/{run.get('id')}")
    return 1


def do_check() -> int:
    """A real read that spends nothing, to prove the token works."""
    token = read_keys().get("APIFY_TOKEN", "")
    if not token or "your-token" in token:
        say(no_token_message())
        return 3
    client = Client(token)
    try:
        me = client.call("GET", "/users/me").get("data") or {}
    except RuntimeError as exc:
        say(str(exc))
        return 1
    plan = (me.get("plan") or {}).get("id") or "unknown"
    say(f"Apify token works. Account: {me.get('username') or 'unnamed'}. Plan: {plan}.")
    try:
        limits = client.call("GET", "/users/me/limits").get("data") or {}
        used = (limits.get("current") or {}).get("monthlyUsageUsd")
        most = (limits.get("limits") or {}).get("maxMonthlyUsageUsd")
        if isinstance(used, (int, float)) and isinstance(most, (int, float)):
            say(f"Used this month: ${used:.2f} of ${most:.2f}.")
    except RuntimeError:
        pass
    return 0


def do_estimate(a) -> int:
    actor = ACTORS[a.actor]
    addons = a.addon or []
    cap = a.max_usd if a.max_usd is not None else default_cap(estimate(actor, a.max_items, addons))
    for line in estimate_lines(a.actor, a.max_items, addons, cap):
        say(line)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Run an Apify actor behind an estimate and a spend cap.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check", help="prove the token works, spending nothing")
    for name in ("estimate", "run"):
        p = sub.add_parser(name)
        p.add_argument("--actor", choices=sorted(ACTORS), required=True)
        p.add_argument("--max-items", type=int, default=DEFAULT_ITEMS)
        p.add_argument("--max-usd", type=float)
        p.add_argument("--addon", action="append", choices=["contacts"],
                       help="paid add-on to include in the estimate")
        if name == "run":
            p.add_argument("--input", required=True, help="JSON file with the actor's input")
            p.add_argument("--out", required=True, help="where to save the results")
            p.add_argument("--confirm", action="store_true", help="the person said yes to the estimate")
            p.add_argument("--allow-larger", action="store_true", help="the person said yes to more than the default")
            p.add_argument("--wait-minutes", type=float, default=20)
    a = ap.parse_args()
    try:
        if a.cmd == "check":
            return do_check()
        return do_estimate(a) if a.cmd == "estimate" else do_run(a)
    except KeyboardInterrupt:
        say("Stopped. If a run had started, check https://console.apify.com/actors/runs")
        return 1
    except Exception as exc:  # a stranger should never see a stack trace
        say(f"Something went wrong: {exc}. Nothing else was started. Tell me what you were doing and I will look.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
