#!/usr/bin/env python3
"""build_queue.py: check each draft against the lead's own words and email, then write the drafts folder and the send queue.

    python build_queue.py --drafts drafts.json --people people.json --profiles profiles.json \\
        --emails emails.json --out-dir lead-finder-out/<name> [--batch batch-001]

Standard library only. It sends nothing and connects to nothing.

drafts.json is a list Claude writes, one per lead:
  {"id": "instagram:someone", "subject": "...", "body": "...", "uses": {"quote": "their words", "source_url": "link"}}

It refuses a draft when:
  - the lead is not in profiles.json, or has no email, or the email's confidence is low or blank
  - the quote in "uses" is not that lead's own words at that link, word for word
  - the body does not use their words: it must hold the quote, or share at least two of its key words
  - two drafts go to the same address
It writes one text file per lead in drafts/, and queue/<batch>.json for send_queue.py.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent / "profile-builder" / "scripts"))
try:
    from profiles import find_quote, flat  # noqa: E402
except ImportError:  # the profile-builder skill was not installed beside this one
    find_quote = flat = None

USABLE = {"high", "medium", "checked"}
STOP = set("""a an and are as at be been but by can could did do does for from had has have how i i'm im if in into is it
it's its just like me my no not of on or our so than that the their them then there they this to too up us was we were
what when where which who why will with would you your you're yours been being get got really very much more most some any
all one out about over also only even still""".split())


def say(msg: str) -> None:
    print(msg, flush=True)


def load(path, what):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8-sig"))
    except OSError:
        raise SystemExit(f"I could not find the {what} file: {path}")
    except ValueError as exc:
        raise SystemExit(f"The {what} file {path} is not valid JSON: {exc}")


def key_words(text: str) -> set:
    return {w for w in re.findall(r"[a-z][a-z']{3,}", flat(text)) if w not in STOP}


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:60] or "lead"


def main() -> int:
    ap = argparse.ArgumentParser(description="Check drafts against each lead's own words, then write the drafts folder and queue.")
    ap.add_argument("--drafts", required=True)
    ap.add_argument("--people", required=True)
    ap.add_argument("--profiles", required=True)
    ap.add_argument("--emails", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--batch", default="batch-001")
    a = ap.parse_args()
    if find_quote is None:
        say("I need the profile-builder skill installed beside this one. Install the whole file again.")
        return 2
    if not re.fullmatch(r"[A-Za-z0-9_-]+", a.batch):
        say("The batch name can only have letters, numbers and dashes.")
        return 2
    try:
        people = {p["id"]: p for p in load(a.people, "people") if isinstance(p, dict) and p.get("id")}
        profiles = {p["id"]: p for p in load(a.profiles, "profiles") if isinstance(p, dict) and p.get("id")}
        emails = load(a.emails, "emails")
        drafts = load(a.drafts, "drafts")
    except SystemExit as exc:
        say(str(exc.code))
        return 2
    if not isinstance(drafts, list) or not drafts:
        say("drafts.json has to be a list with at least one draft.")
        return 2
    problems, messages, files, seen = [], [], [], {}
    for i, dr in enumerate(drafts, 1):
        if not isinstance(dr, dict):
            problems.append(f"draft {i} is not an object")
            continue
        pid = dr.get("id")
        who = pid or f"draft {i}"
        if pid not in profiles or pid not in people:
            problems.append(f"{who}: not in profiles.json, so there is nothing true to write from")
            continue
        e = emails.get(pid, {}) if isinstance(emails, dict) else {}
        addr = str(e.get("email") or "").strip().lower()
        conf = str(e.get("confidence") or "")
        if not addr:
            problems.append(f"{who}: has no email. Leave them out, or reach them another way by hand")
            continue
        if conf not in USABLE:
            problems.append(f"{who}: the email {addr} is {conf or 'unrated'} confidence. Only the owner can check it and mark it checked")
            continue
        if addr in seen:
            problems.append(f"{who}: {addr} is already used for {seen[addr]}")
            continue
        seen[addr] = pid
        uses = dr.get("uses") if isinstance(dr.get("uses"), dict) else {}
        quote, link = str(uses.get("quote") or ""), str(uses.get("source_url") or "")
        ok, why = find_quote(people[pid], quote, link) if quote and link else (False, "is missing, with its source_url")
        if not ok:
            problems.append(f"{who}: the quote it says it uses \"{quote[:60]}\" {why}")
            continue
        body = str(dr.get("body") or "")
        if flat(quote) not in flat(body) and len(key_words(quote) & key_words(body)) < 2:
            problems.append(f"{who}: the email does not use their words. Quote them, or say it back closely enough to share two key words")
            continue
        if not str(dr.get("subject") or "").strip() or not body.strip():
            problems.append(f"{who}: the subject or body is empty")
            continue
        name = people[pid].get("name") or ""
        messages.append({"to": addr, "to_name": name, "subject": dr["subject"].strip(), "body": body.strip(),
                         "lead_id": pid, "uses": {"quote": quote, "source_url": link}})
        files.append((f"{slug(pid)}.txt", f"To: {(name + ' ') if name else ''}<{addr}>\nSubject: {dr['subject'].strip()}\nTheir words: \"{quote}\" ({link})\n\n{body.strip()}\n"))
    if problems:
        say(f"{len(problems)} drafts need fixing. Nothing was written:")
        for p in problems:
            say(f"  - {p}")
        return 5
    out = Path(a.out_dir)
    (out / "drafts").mkdir(parents=True, exist_ok=True)
    (out / "queue").mkdir(parents=True, exist_ok=True)
    for old in (out / "drafts").glob("*.txt"):
        old.unlink()
    for name, text in files:
        (out / "drafts" / name).write_text(text, encoding="utf-8")
    queue = out / "queue" / f"{a.batch}.json"
    queue.write_text(json.dumps({"messages": messages}, indent=1, ensure_ascii=False), encoding="utf-8")
    say(f"All {len(messages)} drafts check out. One file per lead in {out / 'drafts'}, and the queue is {queue}.")
    say("Nothing was sent. Next: the humanizer pass, then send_queue.py review.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # a stranger should never see a stack trace
        print(f"Something went wrong: {exc}. Tell me what you were doing and I will look.")
        sys.exit(1)
