#!/usr/bin/env python3
"""instantly_send.py: hand an approved batch to Instantly, which then sends it on its own schedule.

    python instantly_send.py check                                  proves the key, lists sending accounts
    python instantly_send.py campaigns                              lists campaigns
    python instantly_send.py create-campaign --name NAME --sender sender.json --accounts a@sender.example,b@sender.example [--confirm]
    python instantly_send.py push <queue.json> --sender sender.json --campaign ID [--launch]
    python instantly_send.py pause --campaign ID
    python instantly_send.py suppress-sync --sender sender.json

Standard library only. The key comes from ~/.config/claude-skills/keys.env (INSTANTLY_API_KEY=...), an
Instantly API v2 key the person makes and fills in themselves. It is never printed.

How the personal email travels: the campaign this script makes has one email step whose subject is
{{lf_subject}} and whose body is {{lf_body}}. Each lead carries its own subject and body, written from
that person's own words, as custom variables. So every lead gets their own email, and Instantly sends it.

The approval is the same as the own-mailbox route, and is checked in code here: push refuses a batch
that send_queue.py has not approved with the owner's code, or that changed after approval, or that has
no opt-out line, no postal address or a dishonest subject. People on the stop list are left out, and the
stop list is copied to Instantly's block list first. After push --launch, Instantly sends on its own
schedule, up to the campaign's daily limit, and replies land in Instantly.
"""
from __future__ import annotations

import argparse
import html
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import send_queue as sq  # noqa: E402


def test_base(name: str, default: str) -> str:
    """Only the leg tests set this. It may only point at this computer, so a real key can never be sent elsewhere."""
    value = os.environ.get(name, "").rstrip("/")
    try:
        host = urllib.parse.urlsplit(value).hostname or ""
    except ValueError:
        host = ""
    return value if host in ("127.0.0.1", "localhost", "::1") else default


API = test_base("INSTANTLY_TEST_BASE", "https://api.instantly.ai/api/v2")
KEY_PAGE = "https://app.instantly.ai/app/settings/integrations"
CHUNK = 1000
SUBJECT_VAR, BODY_VAR = "lf_subject", "lf_body"


def say(msg: str) -> None:
    print(msg, flush=True)


def need_key():
    key = sq.read_keys().get("INSTANTLY_API_KEY", "")
    if not key or key.lower().startswith("your"):
        say("I need your Instantly API key and there is none yet.\n"
            f"1. In Instantly, open Settings, Integrations, API Keys: {KEY_PAGE}\n"
            "2. Create an API v2 key. Give it the scopes for accounts, campaigns, leads and block list entries, or all.\n"
            f"3. Open this file in a text editor: {sq.KEYS_FILE}\n"
            "4. Add one line: INSTANTLY_API_KEY=your-key-here\n"
            "Do not paste the key into this chat. Then run this again.")
        return None
    return key


def call(key: str, method: str, path: str, query=None, body=None):
    url = API + path + ("?" + urllib.parse.urlencode(query) if query else "")
    data = json.dumps(body).encode("utf-8") if body is not None else (b"" if method == "POST" else None)
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {key}")
    req.add_header("User-Agent", "claude-skill-lead-finder")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            text = r.read().decode("utf-8", "replace")
            return json.loads(text) if text.strip() else {}
    except urllib.error.HTTPError as exc:
        detail = ""
        try:
            detail = str(json.loads(exc.read().decode("utf-8", "replace")).get("message") or "")[:200]
        except Exception:
            pass
        if exc.code == 401:
            raise RuntimeError(f"Instantly rejected the key. Make a new API v2 key at {KEY_PAGE} and put it in {sq.KEYS_FILE}.") from None
        if exc.code == 402:
            raise RuntimeError("Instantly says this workspace has no active paid plan. The API needs one: https://instantly.ai/pricing") from None
        if exc.code == 403:
            raise RuntimeError("Instantly says the key is missing a scope for this. Edit the key and add the scope, or make one with all scopes.") from None
        if exc.code == 404:
            raise RuntimeError("Instantly cannot find that campaign. Run campaigns to see the right ID.") from None
        if exc.code == 429:
            raise RuntimeError("Instantly says too many requests. Wait a minute and run this again.") from None
        if exc.code >= 500:
            raise RuntimeError("Instantly is having a problem on its side. Try again in a few minutes.") from None
        raise RuntimeError(f"Instantly refused the request (status {exc.code}). {detail}".strip()) from None
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise RuntimeError(f"Could not reach Instantly ({getattr(exc, 'reason', exc)}). Check your connection.") from None
    except ValueError:
        raise RuntimeError("Instantly sent back something I could not read. Try again in a few minutes.") from None


def items_of(data) -> list:
    return data.get("items", []) if isinstance(data, dict) else data if isinstance(data, list) else []


# ---------------------------------------------------------------- commands

def cmd_check(a) -> int:
    key = need_key()
    if not key:
        return 3
    try:
        accts = items_of(call(key, "GET", "/accounts", {"limit": 100}))
    except RuntimeError as exc:
        say(str(exc))
        return 1
    say(f"Instantly key works. Sending accounts connected: {len(accts)}.")
    for acc in accts[:20]:
        say(f"  {acc.get('email')} (status {acc.get('status')}, warmup {acc.get('warmup_status', 'n/a')})")
    if not accts:
        say("Connect at least one mailbox in Instantly before a campaign can send. The clicks are in references/instantly.md.")
    return 0


def cmd_campaigns(a) -> int:
    key = need_key()
    if not key:
        return 3
    try:
        camps = items_of(call(key, "GET", "/campaigns", {"limit": 100}))
    except RuntimeError as exc:
        say(str(exc))
        return 1
    say(f"{len(camps)} campaigns:" if camps else "No campaigns yet. Make one with create-campaign.")
    for c in camps:
        say(f"  {c.get('id')}  {c.get('name')}  (status {c.get('status')})")
    return 0


def cmd_create(a) -> int:
    sender = sq.load_sender(a.sender)
    problems = sq.sender_problems(sender)
    accounts = [x.strip().lower() for x in (a.accounts or "").split(",") if x.strip()]
    if not accounts or not all(sq.ADDRESS_RX.fullmatch(x) for x in accounts):
        problems.append("--accounts needs the sending mailbox addresses connected in Instantly, separated by commas")
    if not re.fullmatch(r"([01]\d|2[0-3]):[0-5]\d", a.start) or not re.fullmatch(r"([01]\d|2[0-3]):[0-5]\d", a.end):
        problems.append("--from and --to are times like 09:00 and 17:00")
    try:
        cap = int(sender.get("daily_cap", sq.DEFAULT_CAP))
    except (TypeError, ValueError):
        cap = 0
    if not 1 <= cap <= sq.MAX_CAP:
        problems.append(f"daily_cap in sender.json has to be between 1 and {sq.MAX_CAP}")
    if problems:
        say("I will not make this campaign yet:")
        for p in problems:
            say(f"  - {p}")
        return 5
    days = {str(d): d in a.days for d in range(7)}
    body = {
        "name": a.name,
        "campaign_schedule": {"schedules": [{"name": "Lead Finder hours", "timing": {"from": a.start, "to": a.end},
                                             "days": days, "timezone": a.timezone}]},
        "sequences": [{"steps": [{"type": "email", "delay": 0,
                                  "variants": [{"subject": "{{" + SUBJECT_VAR + "}}", "body": "{{" + BODY_VAR + "}}"}]}]}],
        "email_list": accounts,
        "daily_limit": cap,
        "stop_on_reply": True,
        "stop_on_auto_reply": False,
        "text_only": True,
        "link_tracking": False,
        "open_tracking": False,
        "insert_unsubscribe_header": True,
    }
    say(f"Campaign: {a.name}. Sends from {', '.join(accounts)}, {a.start} to {a.end} {a.timezone}, up to {cap} a day. "
        "One email per lead, its subject and body carried by that lead. Stops for anyone who replies. No open or click tracking. "
        "It is made without starting, and sends nothing until an approved batch is pushed with --launch.")
    if not a.confirm:
        say("Not made. Show this to the person. If they say yes, run the same command with --confirm.")
        return 4
    key = need_key()
    if not key:
        return 3
    try:
        camp = call(key, "POST", "/campaigns", body=body)
    except RuntimeError as exc:
        say(str(exc))
        return 1
    say(f"Made campaign {camp.get('id')} ({camp.get('name')}). Nothing has been sent.")
    return 0


def approved_batch(path: Path, sender: dict):
    """(queue, fingerprint) for a batch the owner approved, or (None, why not). The same rules as send_queue.py send."""
    queue = sq.load_json(path, "queue")
    problems = sq.batch_problems(queue, sender)
    if problems:
        return None, "I will not hand this batch over:\n" + "\n".join(f"  - {p}" for p in problems)
    try:
        approval = json.loads(sq.approval_path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None, "This batch has not been approved, so nothing was handed over. Run send_queue.py review, show the owner, and let them approve it."
    fp = sq.fingerprint(queue, sender)
    if approval.get("fingerprint") != fp:
        return None, "This batch changed after it was approved, so nothing was handed over. Run review again and get a new approval."
    return (queue, fp), None


def html_body(text: str) -> str:
    return html.escape(str(text)).replace("\r\n", "\n").replace("\n", "<br/>")


def block_values(sender: dict) -> list:
    out = []
    for e in sorted(sq.read_suppression(sender)):
        e = e.lstrip("@")
        if e and ("@" in e or "." in e):
            out.append(e)
    return out


def sync_blocklist(key: str, sender: dict) -> int:
    values = block_values(sender)
    for start in range(0, len(values), 1000):
        call(key, "POST", "/block-lists-entries/bulk-create", body={"bl_values": values[start:start + 1000]})
    return len(values)


def cmd_push(a) -> int:
    path = Path(a.queue)
    sender = sq.load_sender(a.sender)
    got, why = approved_batch(path, sender)
    if not got:
        say(why)
        return 5
    queue, fp = got
    entries = sq.read_suppression(sender)
    keep = [m for m in queue["messages"] if not sq.is_suppressed(m["to"], entries)]
    skipped = len(queue["messages"]) - len(keep)
    key = need_key()
    if not key:
        return 3
    try:
        blocked = sync_blocklist(key, sender)
        totals = {"leads_uploaded": 0, "in_blocklist": 0, "skipped_count": 0, "invalid_email_count": 0, "duplicated_leads": 0}
        remaining = None
        for n, start in enumerate(range(0, len(keep), CHUNK)):
            leads = []
            for m in keep[start:start + CHUNK]:
                first = str(m.get("to_name") or "").split(" ")[0]
                lead = {"email": m["to"], "custom_variables": {SUBJECT_VAR: m["subject"], BODY_VAR: html_body(m["body"])}}
                if first:
                    lead["first_name"] = first
                leads.append(lead)
            res = call(key, "POST", "/leads/add", body={"campaign_id": a.campaign, "leads": leads, "skip_if_in_workspace": True,
                                                         "verify_leads_on_import": False, "idempotency_key": f"lead-finder-{fp[:32]}-{n}"})
            for k in totals:
                totals[k] += int(res.get(k) or 0)
            remaining = res.get("remaining_in_plan", remaining)
    except RuntimeError as exc:
        say(f"{exc} Anything already added stays in the campaign, and running push again does not add it twice.")
        return 1
    for m in keep:
        sq.append_log(sender, {"time": datetime.now().isoformat(timespec="seconds"), "to": m["to"].lower(), "batch": path.stem,
                               "status": "handed-to-instantly", "campaign": a.campaign})
    say(f"Handed {totals['leads_uploaded']} leads to Instantly campaign {a.campaign}. Left out {skipped} on your stop list. "
        f"Instantly skipped {totals['in_blocklist']} on its block list, {totals['skipped_count']} already in your workspace, "
        f"{totals['duplicated_leads']} already in this campaign and {totals['invalid_email_count']} with a bad address. "
        f"Copied {blocked} stop list entries to Instantly's block list." + (f" Uploads left on your plan: {remaining}." if remaining is not None else ""))
    if not a.launch:
        say("Nothing is sending yet. To start, run the same command with --launch, or press Resume on the campaign in Instantly.")
        return 0
    try:
        call(key, "POST", f"/campaigns/{a.campaign}/activate")
    except RuntimeError as exc:
        say(f"The leads are in, but the campaign did not start: {exc}")
        return 1
    say(f"Campaign {a.campaign} is running. Instantly now sends on its own schedule, up to the campaign's daily limit, and stops "
        "for anyone who replies. Replies land in Instantly's Unibox. To stop it: instantly_send.py pause --campaign " + a.campaign)
    return 0


def cmd_pause(a) -> int:
    key = need_key()
    if not key:
        return 3
    try:
        call(key, "POST", f"/campaigns/{a.campaign}/pause")
    except RuntimeError as exc:
        say(str(exc))
        return 1
    say(f"Campaign {a.campaign} is paused. Nothing more sends until it is resumed.")
    return 0


def cmd_sync(a) -> int:
    key = need_key()
    if not key:
        return 3
    try:
        n = sync_blocklist(key, sq.load_sender(a.sender))
    except RuntimeError as exc:
        say(str(exc))
        return 1
    say(f"Copied {n} stop list entries to Instantly's block list. Instantly never emails a blocked address or domain.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Hand an approved batch to Instantly.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check")
    sub.add_parser("campaigns")
    p = sub.add_parser("create-campaign")
    p.add_argument("--name", required=True)
    p.add_argument("--sender", required=True)
    p.add_argument("--accounts", required=True, help="the sending mailboxes connected in Instantly, comma separated")
    p.add_argument("--timezone", default="America/Chicago", help="one of Instantly's time zones, like America/Chicago")
    p.add_argument("--from", dest="start", default="09:00")
    p.add_argument("--to", dest="end", default="17:00")
    p.add_argument("--days", type=lambda s: {int(x) for x in s.split(",") if x.strip()}, default={1, 2, 3, 4, 5},
                   help="days to send, 0 is Sunday: 1,2,3,4,5 is Monday to Friday")
    p.add_argument("--confirm", action="store_true")
    p = sub.add_parser("push")
    p.add_argument("queue")
    p.add_argument("--sender", required=True)
    p.add_argument("--campaign", required=True)
    p.add_argument("--launch", action="store_true", help="start the campaign after the leads are in")
    p = sub.add_parser("pause")
    p.add_argument("--campaign", required=True)
    p = sub.add_parser("suppress-sync")
    p.add_argument("--sender", required=True)
    a = ap.parse_args()
    try:
        return {"check": cmd_check, "campaigns": cmd_campaigns, "create-campaign": cmd_create, "push": cmd_push,
                "pause": cmd_pause, "suppress-sync": cmd_sync}[a.cmd](a)
    except SystemExit as exc:
        if isinstance(exc.code, str):
            say(exc.code)
            return 2
        raise
    except KeyboardInterrupt:
        say("Stopped. Run push again to carry on. Nothing is added twice.")
        return 1
    except Exception as exc:  # a stranger should never see a stack trace
        say(f"Something went wrong: {exc}. Tell me what you were doing and I will look.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
