#!/usr/bin/env python3
"""heyreach_send.py: LinkedIn messages written from each lead's own words, approved once, then sent by HeyReach.

    python heyreach_send.py check                                   proves the key, spends nothing
    python heyreach_send.py accounts                                the LinkedIn sender accounts in HeyReach
    python heyreach_send.py campaigns                               the campaigns in HeyReach
    python heyreach_send.py build   --drafts drafts-li.json --people people.json --profiles profiles.json --sender sender.json --out-dir folder
    python heyreach_send.py review  <li-queue.json> --sender sender.json
    python heyreach_send.py approve <li-queue.json> --sender sender.json --code ABCD1234
    python heyreach_send.py push    <li-queue.json> --sender sender.json --campaign ID --account ID [--start]
    python heyreach_send.py suppress https://www.linkedin.com/in/someone [more...]

Standard library only. The key comes from ~/.config/claude-skills/keys.env (HEYREACH_API_KEY=...), which
the person fills in themselves. It is never printed.

HeyReach sends from the person's own LinkedIn account, which they connect inside HeyReach themselves.
LinkedIn's rules forbid automated messaging tools, so this can get that account restricted. The person
chooses that. This script only adds approved leads to a campaign they built in HeyReach, with each
lead's message in a custom field called personal_message, and starts it after the approval.

Approval works like the email route: review writes a code to a file only the owner sees, approve needs
that code, and any edit cancels it. push refuses an unapproved or changed batch. Every message must carry
the opt-out line and postal address from sender.json, and say back that lead's own words, checked
against their real post. LinkedIn messages have no subject line, so there is no subject to check.
"""
from __future__ import annotations

import argparse
import hashlib
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
sys.path.insert(0, str(HERE.parent.parent / "profile-builder" / "scripts"))
import send_queue as sq  # noqa: E402
try:
    from profiles import find_quote, flat  # noqa: E402
    from build_queue import key_words  # noqa: E402
except ImportError:  # the profile-builder skill was not installed beside this one
    find_quote = flat = key_words = None


def test_base(name: str, default: str) -> str:
    """Only the leg tests set this. It may only point at this computer, so a real key can never be sent elsewhere."""
    value = os.environ.get(name, "").rstrip("/")
    try:
        host = urllib.parse.urlsplit(value).hostname or ""
    except ValueError:
        host = ""
    return value if host in ("127.0.0.1", "localhost", "::1") else default


API = test_base("HEYREACH_TEST_BASE", "https://api.heyreach.io/api/public")
KEY_PAGE = "https://app.heyreach.io/app/integrations/public-api/api"
FIELD = "personal_message"
MAX_CHARS = 1000
CHUNK = 100
LI_RX = re.compile(r"^https://(www\.)?linkedin\.com/in/[^/?#\s]+/?$", re.I)


def say(msg: str) -> None:
    print(msg, flush=True)


def need_key():
    key = sq.read_keys().get("HEYREACH_API_KEY", "")
    if not key or key.lower().startswith("your"):
        say("I need your HeyReach API key and there is none yet.\n"
            f"1. In HeyReach, open Integrations, HeyReach API, Get API Key: {KEY_PAGE}\n"
            "2. Click the copy icon beside the key.\n"
            f"3. Open this file in a text editor: {sq.KEYS_FILE}\n"
            "4. Add one line: HEYREACH_API_KEY=your-key-here\n"
            "Do not paste the key into this chat. Then run this again.")
        return None
    return key


def call(key: str, method: str, path: str, query=None, body=None):
    url = API + path + ("?" + urllib.parse.urlencode(query) if query else "")
    data = json.dumps(body).encode("utf-8") if body is not None else (b"" if method == "POST" else None)
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("X-API-KEY", key)
    req.add_header("Accept", "application/json")
    req.add_header("User-Agent", "claude-skill-lead-finder")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            text = r.read().decode("utf-8", "replace")
            try:
                return json.loads(text) if text.strip() else {}
            except ValueError:
                return {"text": text}
    except urllib.error.HTTPError as exc:
        detail = ""
        try:
            detail = str(json.loads(exc.read().decode("utf-8", "replace")).get("errorMessage") or "")[:200]
        except Exception:
            pass
        if exc.code == 401:
            raise RuntimeError(f"HeyReach rejected the key. Copy it again from {KEY_PAGE} into {sq.KEYS_FILE}.") from None
        if exc.code == 404:
            raise RuntimeError("HeyReach cannot find that campaign. Run campaigns to see the right ID.") from None
        if exc.code == 429:
            raise RuntimeError("HeyReach says too many requests (it allows 300 a minute). Wait a minute and run this again.") from None
        if exc.code >= 500:
            raise RuntimeError("HeyReach is having a problem on its side. Try again in a few minutes.") from None
        raise RuntimeError(f"HeyReach refused the request (status {exc.code}). {detail}".strip()) from None
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise RuntimeError(f"Could not reach HeyReach ({getattr(exc, 'reason', exc)}). Check your connection.") from None


# ---------------------------------------------------------------- the LinkedIn stop list and approval

def li_folder() -> Path:
    folder = sq.KEYS_FILE.parent / "mailboxes" / "linkedin"
    folder.mkdir(parents=True, exist_ok=True)
    return folder


def norm_li(url: str) -> str:
    return str(url or "").split("?")[0].rstrip("/").lower().replace("://linkedin.com", "://www.linkedin.com")


def read_stop() -> set:
    try:
        lines = (li_folder() / "suppression.txt").read_text(encoding="utf-8-sig").splitlines()
    except OSError:
        return set()
    return {norm_li(ln.split("#")[0].strip()) for ln in lines if ln.split("#")[0].strip()}


def sender_problems(sender: dict) -> list:
    out = []
    if not str(sender.get("from_name") or "").strip():
        out.append("sender.json has no from_name")
    address = str(sender.get("postal_address") or "").strip()
    if not address or len(address) < 10 or not re.search(r"\d", address) or not re.search(r"[A-Za-z]", address) or sq.PLACEHOLDER_RX.search(address):
        out.append("sender.json has no real postal_address")
    line = str(sender.get("opt_out_line") or "").strip()
    if not line or not sq.OPT_OUT_RX.search(line):
        out.append("sender.json has no opt_out_line that tells people how to stop these messages")
    return out


def message_problems(m: dict, sender: dict) -> list:
    who = m.get("to") or m.get("lead_id") or "a message"
    out = []
    if not LI_RX.match(str(m.get("to") or "")):
        out.append(f"{who}: the LinkedIn profile link is not valid")
    body = sq.squash(m.get("body"))
    if not body:
        out.append(f"{who}: the message is empty")
    if len(str(m.get("body") or "")) > MAX_CHARS:
        out.append(f"{who}: the message is over {MAX_CHARS} characters")
    for field, label in (("opt_out_line", "opt-out line"), ("postal_address", "postal address")):
        if sq.squash(sender.get(field)) and sq.squash(sender.get(field)) not in body:
            out.append(f"{who}: the message is missing the {label}")
    if re.search(r"\{\{|\}\}|\[(first ?name|name|company|business)\]", str(m.get("body") or ""), re.I):
        out.append(f"{who}: the message still has a template placeholder in it")
    return out


def batch_problems(queue: dict, sender: dict) -> list:
    out = sender_problems(sender)
    msgs = queue.get("messages")
    if queue.get("channel") != "linkedin" or not isinstance(msgs, list) or not msgs:
        return out + ["this is not a LinkedIn queue with messages in it"]
    seen = set()
    for m in msgs:
        out += message_problems(m, sender)
        if norm_li(m.get("to")) in seen:
            out.append(f"{m.get('to')}: appears twice in this batch")
        seen.add(norm_li(m.get("to")))
    return out


def fingerprint(queue: dict, sender: dict) -> str:
    keep = {"channel": "linkedin", "messages": [{k: m.get(k) for k in ("to", "to_name", "body")} for m in queue.get("messages", [])],
            "from_name": sender.get("from_name"), "postal_address": sender.get("postal_address"), "opt_out_line": sender.get("opt_out_line")}
    return hashlib.sha256(json.dumps(keep, sort_keys=True, ensure_ascii=False).encode("utf-8")).hexdigest()


def owner_line(queue_path: Path, sender_path: Path) -> str:
    script = Path(__file__).resolve().as_posix()
    return (f"{sq.python_call()} {sq.safe_arg(script)} approve {sq.safe_arg(queue_path.resolve().as_posix())} "
            f"--sender {sq.safe_arg(sender_path.resolve().as_posix())} --code THE-CODE")


# ---------------------------------------------------------------- commands

def cmd_check(a) -> int:
    key = need_key()
    if not key:
        return 3
    try:
        call(key, "GET", "/auth/CheckApiKey")
    except RuntimeError as exc:
        say(str(exc))
        return 1
    say("HeyReach key works. Nothing was sent.")
    return 0


def cmd_accounts(a) -> int:
    key = need_key()
    if not key:
        return 3
    try:
        data = call(key, "POST", "/li_account/GetAll", body={"offset": 0, "keyword": "", "limit": 100})
    except RuntimeError as exc:
        say(str(exc))
        return 1
    items = data.get("items") or []
    say(f"{len(items)} LinkedIn sender accounts:" if items else "No LinkedIn account is connected in HeyReach yet. The clicks are in references/heyreach.md.")
    for it in items:
        say(f"  {it.get('id')}  {it.get('firstName', '')} {it.get('lastName', '')}  active: {it.get('isActive')}  login ok: {it.get('authIsValid')}")
    return 0


def cmd_campaigns(a) -> int:
    key = need_key()
    if not key:
        return 3
    try:
        data = call(key, "POST", "/campaign/GetAll", body={"offset": 0, "keyword": "", "statuses": [], "accountIds": [], "limit": 100})
    except RuntimeError as exc:
        say(str(exc))
        return 1
    items = data.get("items") or []
    say(f"{len(items)} campaigns:" if items else "No campaigns yet. Make one in HeyReach first; the clicks are in references/heyreach.md.")
    for it in items:
        say(f"  {it.get('id')}  {it.get('name')}  (status {it.get('status')})")
    return 0


def cmd_build(a) -> int:
    if find_quote is None:
        say("I need the profile-builder skill installed beside this one. Install the whole file again.")
        return 2
    if not re.fullmatch(r"[A-Za-z0-9_-]+", a.batch):
        say("The batch name can only have letters, numbers and dashes.")
        return 2
    people = {p["id"]: p for p in sq.load_json(a.people, "people") if isinstance(p, dict) and p.get("id")}
    profiles = {p["id"]: p for p in sq.load_json(a.profiles, "profiles") if isinstance(p, dict) and p.get("id")}
    sender = sq.load_sender(a.sender)
    drafts = sq.load_json(a.drafts, "drafts")
    problems = sender_problems(sender)
    msgs, files = [], []
    for i, dr in enumerate(drafts if isinstance(drafts, list) else [], 1):
        pid = dr.get("id") if isinstance(dr, dict) else None
        who = pid or f"draft {i}"
        if pid not in profiles or pid not in people:
            problems.append(f"{who}: not in profiles.json, so there is nothing true to write from")
            continue
        p = people[pid]
        if not LI_RX.match(str(p.get("profile_url") or "")):
            problems.append(f"{who}: has no LinkedIn profile link, so HeyReach cannot reach them")
            continue
        uses = dr.get("uses") if isinstance(dr.get("uses"), dict) else {}
        quote, link = str(uses.get("quote") or ""), str(uses.get("source_url") or "")
        ok, why = find_quote(p, quote, link) if quote and link else (False, "is missing, with its source_url")
        if not ok:
            problems.append(f"{who}: the quote it says it uses \"{quote[:60]}\" {why}")
            continue
        body = str(dr.get("message") or "").strip()
        if flat(quote) not in flat(body) and len(key_words(quote) & key_words(body)) < 2:
            problems.append(f"{who}: the message does not use their words. Quote them, or say it back closely enough to share two key words")
            continue
        names = str(p.get("name") or "").split()
        m = {"to": p["profile_url"].split("?")[0], "to_name": p.get("name") or "", "first_name": names[0] if names else "",
             "last_name": names[-1] if len(names) > 1 else "", "position": p.get("headline") or "", "body": body,
             "lead_id": pid, "uses": {"quote": quote, "source_url": link}}
        problems += message_problems(m, sender)
        msgs.append(m)
        files.append((re.sub(r"[^a-z0-9]+", "-", pid.lower()).strip("-")[:60] + ".txt",
                      f"To: {m['to_name']} <{m['to']}>\nTheir words: \"{quote}\" ({link})\n\n{body}\n"))
    if not msgs and not problems:
        problems.append("drafts-li.json has no drafts in it")
    if problems:
        say(f"{len(problems)} things need fixing. Nothing was written:")
        for pr in problems:
            say(f"  - {pr}")
        return 5
    out = Path(a.out_dir)
    (out / "drafts-li").mkdir(parents=True, exist_ok=True)
    (out / "queue").mkdir(parents=True, exist_ok=True)
    for old in (out / "drafts-li").glob("*.txt"):
        old.unlink()
    for name, text in files:
        (out / "drafts-li" / name).write_text(text, encoding="utf-8")
    q = out / "queue" / f"{a.batch}.json"
    q.write_text(json.dumps({"channel": "linkedin", "messages": msgs}, indent=1, ensure_ascii=False), encoding="utf-8")
    say(f"All {len(msgs)} LinkedIn messages check out. One file per lead in {out / 'drafts-li'}, and the queue is {q}. Nothing was sent.")
    return 0


def cmd_review(a) -> int:
    path = Path(a.queue)
    queue, sender = sq.load_json(path, "queue"), sq.load_sender(a.sender)
    problems = batch_problems(queue, sender)
    if problems:
        say("This batch cannot be approved yet:")
        for p in problems:
            say(f"  - {p}")
        return 5
    stop = read_stop()
    skipped = [m["to"] for m in queue["messages"] if norm_li(m["to"]) in stop]
    if skipped:
        say(f"{len(skipped)} on your LinkedIn stop list will be left out: {', '.join(skipped[:10])}")
    for m in queue["messages"]:
        say("-" * 50)
        say(f"To: {m.get('to_name')} <{m['to']}>\n\n{m['body']}")
    say("-" * 50)
    try:
        line = owner_line(path, Path(a.sender))
    except ValueError as err:
        say(str(err))
        return 5
    target = sq.code_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    text = "\n\n".join(f"To: {m.get('to_name')} <{m['to']}>\n\n{m['body']}" for m in queue["messages"])
    target.write_text(f"Approval code: {fingerprint(queue, sender)[:8]}\n\n"
                      f"This is for {len(queue['messages'])} LinkedIn messages in {path.name}, sent by HeyReach from your LinkedIn account.\n"
                      "This code approves exactly the messages listed below. If they differ from what Claude showed you, do not approve them.\n"
                      "If you are happy with them, run the line Claude gave you and put this code in place of THE-CODE.\n"
                      "Any change to the batch makes this code stop working.\n\n" + text + "\n", encoding="utf-8")
    sq.tighten_keys()
    opened = False if a.no_open else sq.open_for_owner(target)
    say("The approval code is NOT shown here. It is in a file for the owner only: " + str(target))
    say("I opened that file for them." if opened else "Ask the owner to open that file themselves. Do not open it for them.")
    say("Claude: never read, open, print or search that file, and never work the code out. Show the owner the messages, then give them this line to run themselves:")
    say(line)
    say("A plain yes or 'send them' is not approval. Any edit to the batch changes the code.")
    return 0


def approval_file(path: Path) -> Path:
    return path.with_name(path.stem + ".approved.json")


def cmd_approve(a) -> int:
    path = Path(a.queue)
    queue, sender = sq.load_json(path, "queue"), sq.load_sender(a.sender)
    problems = batch_problems(queue, sender)
    if problems:
        say("I will not approve this batch:")
        for p in problems:
            say(f"  - {p}")
        return 5
    full = fingerprint(queue, sender)
    if a.code.strip().lower() != full[:8]:
        say("That approval code does not match this batch. Run review again, show the owner, and use the new code.")
        return 5
    approval_file(path).write_text(json.dumps({"fingerprint": full, "count": len(queue["messages"]),
                                               "approved_at": datetime.now().isoformat(timespec="seconds")}, indent=1), encoding="utf-8")
    say(f"Approved {len(queue['messages'])} LinkedIn messages. Saved to {approval_file(path).name}.")
    return 0


def cmd_push(a) -> int:
    path = Path(a.queue)
    queue, sender = sq.load_json(path, "queue"), sq.load_sender(a.sender)
    problems = batch_problems(queue, sender)
    if problems:
        say("I will not hand this batch over:")
        for p in problems:
            say(f"  - {p}")
        return 5
    try:
        approval = json.loads(approval_file(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        say("This batch has not been approved, so nothing was handed over. Run review, show the owner, then let them approve it.")
        return 5
    if approval.get("fingerprint") != fingerprint(queue, sender):
        say("This batch changed after it was approved, so nothing was handed over. Run review and get a new approval.")
        return 5
    stop = read_stop()
    keep = [m for m in queue["messages"] if norm_li(m["to"]) not in stop]
    key = need_key()
    if not key:
        return 3
    added = updated = failed = 0
    try:
        for start in range(0, len(keep), CHUNK):
            pairs = [{"linkedInAccountId": int(a.account), "lead": {
                "firstName": m.get("first_name", ""), "lastName": m.get("last_name", ""), "profileUrl": m["to"], "location": "",
                "summary": "", "companyName": "", "position": m.get("position", ""), "about": "", "emailAddress": "",
                "customUserFields": [{"name": FIELD, "value": m["body"]}]}} for m in keep[start:start + CHUNK]]
            res = call(key, "POST", "/campaign/AddLeadsToCampaignV2",
                       body={"campaignId": int(a.campaign), "accountLeadPairs": pairs, "resumeFinishedCampaign": False, "resumePausedCampaign": False})
            added += int(res.get("addedLeadsCount") or 0)
            updated += int(res.get("updatedLeadsCount") or 0)
            failed += int(res.get("failedLeadsCount") or 0)
    except RuntimeError as exc:
        say(f"{exc} Leads already added stay in the campaign.")
        return 1
    log = li_folder() / "sent-log.jsonl"
    with log.open("a", encoding="utf-8") as fh:
        for m in keep:
            fh.write(json.dumps({"time": datetime.now().isoformat(timespec="seconds"), "to": m["to"], "batch": path.stem,
                                 "status": "handed-to-heyreach", "campaign": a.campaign}) + "\n")
    say(f"Added {added} leads to HeyReach campaign {a.campaign} ({updated} updated, {failed} failed). "
        f"Left out {len(queue['messages']) - len(keep)} on your LinkedIn stop list.")
    if not a.start:
        say("Nothing is sending yet. To start, run the same command with --start, or start the campaign in HeyReach.")
        return 0
    try:
        call(key, "POST", "/campaign/StartCampaign", {"campaignId": a.campaign})
    except RuntimeError:
        try:
            call(key, "POST", "/campaign/Resume", {"campaignId": a.campaign})
        except RuntimeError as exc:
            say(f"The leads are in, but the campaign did not start: {exc} Start it in HeyReach.")
            return 1
    say(f"Campaign {a.campaign} is running. HeyReach now works through it on its own schedule, inside its daily and weekly "
        "LinkedIn limits. Replies land in HeyReach's inbox. To stop it, pause the campaign in HeyReach.")
    return 0


def cmd_suppress(a) -> int:
    have = read_stop()
    new = [norm_li(u) for u in a.urls if norm_li(u) and norm_li(u) not in have]
    with (li_folder() / "suppression.txt").open("a", encoding="utf-8") as fh:
        for u in new:
            fh.write(u + "\n")
    say(f"Added {len(new)}. They are left out of every LinkedIn batch from now on. If one is already in a running HeyReach "
        "campaign, stop them there too, from the lead's page in HeyReach.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="LinkedIn messages through HeyReach, after the owner approves the batch.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("check", "accounts", "campaigns"):
        sub.add_parser(name)
    p = sub.add_parser("build")
    for f in ("--drafts", "--people", "--profiles", "--sender", "--out-dir"):
        p.add_argument(f, required=True)
    p.add_argument("--batch", default="li-batch-001")
    for name in ("review", "approve"):
        p = sub.add_parser(name)
        p.add_argument("queue")
        p.add_argument("--sender", required=True)
        if name == "review":
            p.add_argument("--no-open", action="store_true")
        else:
            p.add_argument("--code", required=True)
    p = sub.add_parser("push")
    p.add_argument("queue")
    p.add_argument("--sender", required=True)
    p.add_argument("--campaign", required=True)
    p.add_argument("--account", required=True, help="the HeyReach id of the LinkedIn account that sends")
    p.add_argument("--start", action="store_true")
    p = sub.add_parser("suppress")
    p.add_argument("urls", nargs="+")
    a = ap.parse_args()
    try:
        return {"check": cmd_check, "accounts": cmd_accounts, "campaigns": cmd_campaigns, "build": cmd_build, "review": cmd_review,
                "approve": cmd_approve, "push": cmd_push, "suppress": cmd_suppress}[a.cmd](a)
    except SystemExit as exc:
        if isinstance(exc.code, str):
            say(exc.code)
            return 2
        raise
    except ValueError:
        say("The campaign and account ids are numbers. Run campaigns and accounts to see them.")
        return 2
    except KeyboardInterrupt:
        say("Stopped.")
        return 1
    except Exception as exc:  # a stranger should never see a stack trace
        say(f"Something went wrong: {exc}. Tell me what you were doing and I will look.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
