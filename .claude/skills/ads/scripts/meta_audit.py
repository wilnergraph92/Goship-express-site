#!/usr/bin/env python3
"""meta_audit.py: audit your own Meta ad account and list budget moves for you to approve.

    python meta_audit.py --account act_123456 --out folder [--days 30] [--conversion lead]
    python meta_audit.py --account act_123456 --check     proves the token can read this account

READ ONLY. This script has one way to reach Meta, the graph_read function below, and it can only make
a read request. There is no code here that changes a budget, a campaign or an ad. You make any change
yourself in Ads Manager after reading the list.

The token comes from ~/.config/claude-skills/keys.env (META_ACCESS_TOKEN=...). It is never printed.
Standard library only.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import date
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

GRAPH_VERSION = "v26.0"  # newest on 2026-11-04: https://developers.facebook.com/docs/graph-api/changelog/versions/
def test_base(name: str, default: str) -> str:
    """Only the leg tests set this. It may only point at this computer, so a real key can never be sent elsewhere."""
    value = os.environ.get(name, "").rstrip("/")
    try:
        host = urllib.parse.urlsplit(value).hostname or ""
    except ValueError:
        host = ""
    return value if host in ("127.0.0.1", "localhost", "::1") else default


GRAPH = test_base("META_GRAPH_BASE", "https://graph.facebook.com")
KEYS_FILE = Path.home() / ".config" / "claude-skills" / "keys.env"
DATE_PRESETS = {7: "last_7d", 14: "last_14d", 28: "last_28d", 30: "last_30d", 90: "last_90d"}
MAX_PAGES = 25
PREFERRED_ACTIONS = ["purchase", "omni_purchase", "offsite_conversion.fb_pixel_purchase", "lead",
                     "onsite_conversion.lead_grouped", "offsite_conversion.fb_pixel_lead", "complete_registration",
                     "contact", "onsite_conversion.messaging_conversation_started_7d"]
INSIGHT_FIELDS = "campaign_id,campaign_name,adset_id,adset_name,ad_id,ad_name,spend,impressions,reach,clicks,ctr,cpc,frequency,actions,cost_per_action_type"
ADSET_FIELDS = "id,name,campaign_id,daily_budget,lifetime_budget,effective_status,optimization_goal,targeting"
AD_FIELDS = "id,name,adset_id,campaign_id,effective_status,creative{id,title,body,image_url,thumbnail_url,call_to_action_type}"

# Starting rules, not laws of nature. The owner's real numbers beat them.
RAISE_CPA_RATIO = 0.7
CUT_CPA_RATIO = 1.5
MIN_CONVERSIONS_TO_RAISE = 5
NO_RESULT_SPEND_RATIO = 2.0
HIGH_FREQUENCY = 3.0
LOW_CTR_RATIO = 0.5
RAISE_PERCENT = 20
CUT_PERCENT = 30


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


def read_token() -> str:
    return read_keys().get("META_ACCESS_TOKEN", "")


class Stop(Exception):
    pass


def plain_graph_error(status: int, raw: str) -> str:
    try:
        err = json.loads(raw).get("error", {})
    except ValueError:
        err = {}
    code = err.get("code")
    if code == 190 or status == 401:
        return ("Meta says the token is expired or not valid. Make a new one with the ads_read permission "
                f"and put it in {KEYS_FILE}.")
    if code in (10, 200, 294) or status == 403:
        return ("Meta says this token cannot read that account. It needs the ads_read permission, and the "
                "person who made it needs access to the ad account. Check the account number too.")
    if code in (4, 17, 32, 613, 80000, 80004):
        return "Meta says the account has hit its API rate limit. Wait an hour and run this again."
    if code == 100 or status == 400:
        return "Meta did not accept the request. Check that the account number looks like act_123456."
    return f"Meta returned an error (status {status}). Try again later."


def graph_read(path: str, token: str, params: dict | None = None) -> dict:
    """The only network call in this file. It makes a read request and nothing else."""
    # The token goes in a header, so it stays out of web addresses and out of any proxy's logs.
    url = f"{GRAPH}/{GRAPH_VERSION}/{path.lstrip('/')}?{urllib.parse.urlencode(params or {})}"
    req = urllib.request.Request(url, headers={"User-Agent": "claude-skill-ads-audit", "Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.loads(r.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as exc:
        raise Stop(plain_graph_error(exc.code, exc.read().decode("utf-8", "replace"))) from None
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        # The reason never contains the address, so the token stays out of the message.
        raise Stop(f"Could not reach Meta ({getattr(exc, 'reason', 'connection problem')}). Try again.") from None
    except ValueError:
        raise Stop("Meta sent back something I could not read. Try again later.") from None


def read_all(path: str, token: str, params: dict) -> list:
    """Follow the cursor, never Meta's ready-made next link, since that link can carry a token."""
    rows, query = [], dict(params)
    for _ in range(MAX_PAGES):
        page = graph_read(path, token, query)
        rows += page.get("data") or []
        paging = page.get("paging") or {}
        after = (paging.get("cursors") or {}).get("after")
        if not paging.get("next") or not after:
            return rows
        query["after"] = after
    say(f"Stopped reading after {MAX_PAGES} pages. Numbers cover what was read.")
    return rows


def num(value, default=0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def action_total(row: dict, action: str) -> float:
    return sum(num(a.get("value")) for a in row.get("actions") or [] if a.get("action_type") == action)


def choose_action(rows: list, wanted) -> str:
    if wanted:
        return wanted
    totals: dict = {}
    for row in rows:
        for a in row.get("actions") or []:
            totals[a.get("action_type")] = totals.get(a.get("action_type"), 0) + num(a.get("value"))
    for name in PREFERRED_ACTIONS:
        if totals.get(name):
            return name
    return ""


# Currencies Meta counts in whole units: https://developers.facebook.com/docs/marketing-api/currencies
WHOLE_UNIT_CURRENCIES = {"CLP", "COP", "CRC", "HUF", "ISK", "IDR", "JPY", "KRW", "PYG", "TWD", "VND"}
UNIT = 100
SIGN = "$"


def set_currency(code: str) -> None:
    """Show this account's own currency, and divide budgets by the right amount."""
    global UNIT, SIGN
    code = (code or "USD").strip().upper()
    UNIT = 1 if code in WHOLE_UNIT_CURRENCIES else 100
    SIGN = "$" if code == "USD" else f"{code} "


def money(value: float) -> str:
    return f"{value:,.2f}"


def budget_note(adset: dict) -> tuple:
    """Budgets come back in the account's smallest money unit, like cents. Yen has no smaller unit."""
    daily = num(adset.get("daily_budget")) / UNIT
    return (daily, "per day") if daily else (num(adset.get("lifetime_budget")) / UNIT, "lifetime")


def audience_summary(adset: dict) -> str:
    t = adset.get("targeting") or {}
    parts = []
    geo = t.get("geo_locations") or {}
    places = (geo.get("countries") or []) + [c.get("name", "") for c in geo.get("cities") or []] + [r.get("name", "") for r in geo.get("regions") or []]
    if places:
        parts.append(", ".join(str(p) for p in places[:4]))
    if t.get("age_min") or t.get("age_max"):
        parts.append(f"age {t.get('age_min', '?')} to {t.get('age_max', '?')}")
    interests = sum(len(group.get("interests") or []) for group in t.get("flexible_spec") or [])
    if interests:
        parts.append(f"interests: {interests}")
    if t.get("custom_audiences"):
        parts.append(f"custom audiences: {len(t['custom_audiences'])}")
    if (t.get("targeting_automation") or {}).get("advantage_audience"):
        parts.append("Advantage+ audience")
    return "; ".join(parts) or "not shown"


def audit(adset_rows: list, ad_rows: list, adsets: list, ads: list, action: str) -> dict:
    info = {a.get("id"): a for a in adsets}
    live_rows = [r for r in adset_rows if (info.get(r.get("adset_id")) or {}).get("effective_status", "ACTIVE") == "ACTIVE"]
    spend = sum(num(r.get("spend")) for r in adset_rows)
    # Judge live ad sets against live ad sets, so something already paused cannot hide a bad one.
    live_spend = sum(num(r.get("spend")) for r in live_rows)
    conversions = sum(action_total(r, action) for r in live_rows) if action else 0
    account_cpa = live_spend / conversions if conversions else 0
    clicks = sum(num(r.get("clicks")) for r in live_rows)
    impressions = sum(num(r.get("impressions")) for r in live_rows)
    account_ctr = 100 * clicks / impressions if impressions else 0
    moves, flags = [], []
    for row in live_rows:
        name = row.get("adset_name") or row.get("adset_id")
        where = f"{row.get('campaign_name', '')} / {name}"
        cost = num(row.get("spend"))
        conv = action_total(row, action) if action else 0
        cpa = cost / conv if conv else 0
        adset = info.get(row.get("adset_id")) or {}
        budget, kind = budget_note(adset)
        evidence = f"{SIGN}{money(cost)} spent, {conv:g} results" + (f" at {SIGN}{money(cpa)} each" if conv else "")
        if account_cpa and not conv and cost >= NO_RESULT_SPEND_RATIO * account_cpa:
            moves.append({"move": "Pause", "where": where, "from": f"{SIGN}{money(budget)} {kind}" if budget else "not shown", "to": f"{SIGN}0",
                          "why": f"{evidence}. Your account average is {SIGN}{money(account_cpa)} a result.", "freed": budget if kind == "per day" else 0})
        elif account_cpa and conv and cpa >= CUT_CPA_RATIO * account_cpa and cost >= NO_RESULT_SPEND_RATIO * account_cpa:
            new = budget * (100 - CUT_PERCENT) / 100
            moves.append({"move": f"Lower {CUT_PERCENT}%", "where": where, "from": f"{SIGN}{money(budget)} {kind}" if budget else "not shown",
                          "to": f"{SIGN}{money(new)} {kind}" if budget else f"{CUT_PERCENT}% lower",
                          "why": f"{evidence}, against an account average of {SIGN}{money(account_cpa)}.", "freed": budget - new if kind == "per day" else 0})
        elif account_cpa and conv >= MIN_CONVERSIONS_TO_RAISE and cpa <= RAISE_CPA_RATIO * account_cpa:
            new = budget * (100 + RAISE_PERCENT) / 100
            moves.append({"move": f"Raise {RAISE_PERCENT}%", "where": where, "from": f"{SIGN}{money(budget)} {kind}" if budget else "not shown",
                          "to": f"{SIGN}{money(new)} {kind}" if budget else f"{RAISE_PERCENT}% higher",
                          "why": f"{evidence}, against an account average of {SIGN}{money(account_cpa)}.", "freed": -(new - budget) if kind == "per day" else 0})
        frequency = num(row.get("frequency"))
        if frequency >= HIGH_FREQUENCY:
            flags.append({"area": "Audience", "where": where, "finding": f"The average person saw these ads {frequency:.1f} times. The audience may be worn out, so test a broader audience or new creative."})
    # Two live ad sets aimed at the same people bid against each other.
    groups: dict = {}
    for adset in adsets:
        if adset.get("effective_status", "ACTIVE") == "ACTIVE" and adset.get("targeting"):
            groups.setdefault(json.dumps(adset["targeting"], sort_keys=True), []).append(adset.get("name", adset.get("id")))
    for names in groups.values():
        if len(names) > 1:
            flags.append({"area": "Audience", "where": ", ".join(map(str, names)), "finding": "These ad sets have identical targeting, so they compete with each other. Consider combining them."})
    ad_info = {a.get("id"): a for a in ads}
    for row in ad_rows:
        ad = ad_info.get(row.get("ad_id")) or {}
        if ad and ad.get("effective_status", "ACTIVE") != "ACTIVE":
            continue
        ctr = num(row.get("ctr"))
        impressions_here = num(row.get("impressions"))
        if account_ctr and impressions_here >= 1000 and ctr < LOW_CTR_RATIO * account_ctr:
            flags.append({"area": "Creative", "where": row.get("ad_name") or row.get("ad_id"),
                          "finding": f"Click rate {ctr:.2f}% against an account average of {account_ctr:.2f}%. Replace this creative first. The ad-writer skill can draft new versions."})
    ctrs = [num(r.get("ctr")) for r in ad_rows if num(r.get("impressions")) >= 1000]
    return {
        "action": action, "spend": spend, "live_spend": live_spend, "conversions": conversions, "account_cpa": account_cpa,
        "account_ctr": account_ctr, "median_ad_ctr": statistics.median(ctrs) if ctrs else 0,
        "moves": moves, "flags": flags,
        "audiences": [{"ad_set": a.get("name"), "status": a.get("effective_status"), "budget": "${} {}".format(money(budget_note(a)[0]), budget_note(a)[1]), "audience": audience_summary(a)} for a in adsets],
    }


def write_report(result: dict, ads: list, folder: Path, account: str, days: int) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "meta-audit.json").write_text(json.dumps({"account": account, "days": days, **result, "ads": ads}, indent=1, ensure_ascii=False), encoding="utf-8")
    freed = sum(m.get("freed", 0) for m in result["moves"])
    lines = [
        f"# Meta Budget Moves, {date.today().isoformat()}",
        "",
        f"Account {account}, last {days} days. Nothing here has been changed, and this tool cannot change your account. "
        "To make a move, approve it and make the change yourself in Ads Manager.",
        "",
        f"Spend: {SIGN}{money(result['spend'])}, of which {SIGN}{money(result['live_spend'])} is in ad sets still running. "
        f"Results on running ad sets, counted as `{result['action'] or 'none found'}`: {result['conversions']:g}."
        + (f" Average cost per result: {SIGN}{money(result['account_cpa'])}." if result["account_cpa"] else ""),
        "",
        "## Budget Moves For Your Approval",
        "",
    ]
    if result["moves"]:
        lines += ["| # | Approve? | Move | Where | From | To | Why |", "|---|---|---|---|---|---|---|"]
        for n, m in enumerate(result["moves"], 1):
            cells = [n, "[ ]", m["move"], m["where"], m["from"], m["to"], m["why"]]
            lines.append("| " + " | ".join(str(c).replace("|", "/") for c in cells) + " |")
        lines += ["", f"Net daily change if you approve all of them: {'-' if freed > 0 else '+'}{SIGN}{money(abs(freed))} a day."]
    elif not result["action"]:
        lines.append("No moves, because I could not find a result to judge by. Tell me what counts as a result (run with --conversion) and I will run it again.")
    else:
        lines.append("No moves. Nothing is far enough from the account average to justify one.")
    lines += ["", "These come from starting rules, measured against your own account average. They do not know your margins, your season or your sales cycle. Change budgets in steps and give each change about a week.",
              "", "## Audiences And Creative", ""]
    if result["flags"]:
        lines += [f"- **{f['area']}, {f['where']}:** {f['finding']}" for f in result["flags"]]
    else:
        lines.append("Nothing stands out.")
    lines += ["", "## Who Each Ad Set Reaches", "", "| Ad Set | Status | Budget | Audience |", "|---|---|---|---|"]
    lines += ["| " + " | ".join(str(a[k]).replace("|", "/") for k in ("ad_set", "status", "budget", "audience")) + " |" for a in result["audiences"]]
    (folder / "budget-moves.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description="Read-only audit of your own Meta ad account.")
    ap.add_argument("--account", required=True, help="looks like act_123456")
    ap.add_argument("--out")
    ap.add_argument("--check", action="store_true", help="prove the token can read this account, and stop")
    ap.add_argument("--allow-broad-token", action="store_true", help="the person chose to run with a token that can change ads")
    ap.add_argument("--days", type=int, default=30, choices=sorted(DATE_PRESETS))
    ap.add_argument("--conversion", help="the action that counts as a result, like lead or purchase")
    a = ap.parse_args()
    if not a.check and not a.out:
        say("Tell me where to save the list with --out folder.")
        return 2
    account = a.account.strip()
    if re.fullmatch(r"\d+", account):
        account = "act_" + account
    if not re.fullmatch(r"act_\d+", account):
        say("That does not look like an ad account number. It looks like act_123456, and Ads Manager shows it in the address bar.")
        return 2
    token = read_token()
    if not token or "your-token" in token:
        say("I need a read-only Meta token and there is none yet.\n"
            "1. In your own Meta app (https://developers.facebook.com/apps/creation/), generate a token. The ads skill walks you through it.\n"
            "2. Give it only the ads_read permission. Do not add ads_management. This tool does not need it.\n"
            f"3. Open this file in a text editor: {KEYS_FILE}\n"
            "4. Add one line: META_ACCESS_TOKEN=your-token-here\n"
            "Do not paste the token into this chat. Then run this again.")
        return 3
    try:
        granted = [p.get("permission") for p in graph_read("me/permissions", token).get("data", []) if p.get("status") == "granted"]
        if "ads_management" in granted:
            if not a.allow_broad_token:
                say("I stopped, because this token also has ads_management, which can change your ads. This tool only reads, but a token "
                    "like that sitting in a file can do real damage if anything else reaches it. Make a new one with only ads_read. "
                    "If you decide to keep this one anyway, say so, and I can run with --allow-broad-token.")
                return 1
            say("Note: this token also has ads_management, and you chose to run with it. This tool still only reads.")
        if a.check:
            info = graph_read(account, token, {"fields": "name,currency"})
            if "ads_read" not in granted:
                say("This token does not have the ads_read permission, so the audit may not work. Make a new one with ads_read.")
                return 1
            say(f"Token works. It can read {info.get('name') or account}, in {info.get('currency') or 'an unknown currency'}. Nothing was changed.")
            return 0
        base = {"date_preset": DATE_PRESETS[a.days], "limit": 200, "fields": INSIGHT_FIELDS}
        say("Reading spend by ad set and by ad.")
        adset_rows = read_all(f"{account}/insights", token, {**base, "level": "adset"})
        if not adset_rows:
            say(f"Meta shows no spend in the last {a.days} days on this account, so there is nothing to audit.")
            return 0
        set_currency(graph_read(account, token, {"fields": "currency"}).get("currency"))
        ad_rows = read_all(f"{account}/insights", token, {**base, "level": "ad"})
        say("Reading budgets, audiences and creative.")
        adsets = read_all(f"{account}/adsets", token, {"fields": ADSET_FIELDS, "limit": 200})
        ads = read_all(f"{account}/ads", token, {"fields": AD_FIELDS, "limit": 200})
    except Stop as exc:
        say(str(exc))
        return 1
    except Exception as exc:  # a stranger should never see a stack trace
        say(f"Something went wrong reading the account ({type(exc).__name__}). Nothing was changed. Try again.")
        return 1
    result = audit(adset_rows, ad_rows, adsets, ads, choose_action(adset_rows, a.conversion))
    folder = Path(a.out)
    write_report(result, ads, folder, account, a.days)
    say(f"Done. {len(result['moves'])} budget moves and {len(result['flags'])} other findings. Nothing was changed.")
    say(f"Wrote {folder / 'budget-moves.md'} and {folder / 'meta-audit.json'}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
