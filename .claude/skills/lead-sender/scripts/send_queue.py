#!/usr/bin/env python3
"""send_queue.py: send a batch of emails you approved, through your own email login.

    python send_queue.py review  <queue.json> --sender sender.json
    python send_queue.py approve <queue.json> --sender sender.json --code ABCD1234
    python send_queue.py send    <queue.json> --sender sender.json [--dry-run]
    python send_queue.py status  <queue.json>
    python send_queue.py suppress <queue.json> someone@example.com [more...]
    python send_queue.py drafts  <queue.json> --sender sender.json --out drafts.md     to send by hand
    python send_queue.py check-login                                                   proves the login, sends nothing

Standard library only. The login comes from ~/.config/claude-skills/keys.env (SMTP_HOST, SMTP_PORT,
SMTP_USER, SMTP_PASSWORD), which the person fills in themselves. It is never printed.

It refuses to send when the batch is unapproved, was edited after approval, has no opt-out line,
has no postal address or has a subject line that looks dishonest. It skips anyone on the suppression
list, stops at the daily cap and pauses between sends.

The stop list and the record of sends live per mailbox under ~/.config/claude-skills/mailboxes/, so an
opt-out and the daily cap hold across every project folder.

review writes the approval code to ~/.config/claude-skills/approval-code.txt and opens it for the owner.
It never prints the code, so Claude is not handed it. This is a strong check, not a lock: the code can
be recomputed from the batch, and the script cannot tell who ran approve.
"""
from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
import random
import re
import shutil
import smtplib
import socket
import ssl
import subprocess
import sys
import time
from datetime import datetime
from email.message import EmailMessage
from email.utils import formataddr, formatdate, make_msgid
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

KEYS_FILE = Path.home() / ".config" / "claude-skills" / "keys.env"
ADDRESS_RX = re.compile(r"[A-Za-z0-9._%+'-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,24}")
DEFAULT_CAP = 25
MAX_CAP = 200
DEFAULT_PAUSE = 90
MIN_PAUSE = 20
STOP_AFTER_FAILS = 3
PLACEHOLDER_RX = re.compile(r"[{}\[\]<>]|\byour (street |postal |mailing )?address\b|\btbd\b|\bplaceholder\b|\bxxx+\b", re.I)
OPT_OUT_RX = re.compile(r"unsubscribe|opt.?out|stop|remove", re.I)
DISHONEST_SUBJECT = [
    (re.compile(r"^\s*(re|fw|fwd)\s*:", re.I), "it starts with Re or Fwd, which pretends this is an existing conversation"),
    (re.compile(r"\b(invoice|receipt|payment (due|failed|overdue)|past due|your order|refund|shipping (notice|update))\b", re.I), "it reads like a bill or an order they never made"),
    (re.compile(r"\b(account (suspended|closed|locked|deleted)|security alert|password|verify your|final notice|legal notice|action required)\b", re.I), "it reads like a warning about their account"),
    (re.compile(r"\b(you('ve| have) won|winner|free money|act now|risk.?free|100% (free|guaranteed)|guaranteed)\b", re.I), "it makes a claim spam filters and readers will not trust"),
    (re.compile(r"\burgent\b", re.I), "it claims urgency the message does not have"),
    (re.compile(r"[{}]|\[[^\]]*\]"), "it still has a template placeholder in it"),
    (re.compile(r"!{2,}"), "it has repeated exclamation marks"),
]


def say(msg: str) -> None:
    print(msg, flush=True)


def squash(text: str) -> str:
    return " ".join(str(text or "").split()).lower()


def subject_problem(subject: str):
    subject = str(subject or "")
    if not subject.strip():
        return "it is empty"
    if "\n" in subject or "\r" in subject:
        return "it has a line break in it"
    if len(subject) > 120:
        return "it is over 120 characters"
    letters = [c for c in subject if c.isalpha()]
    if len(letters) >= 6 and sum(c.isupper() for c in letters) / len(letters) > 0.7:
        return "it is mostly capital letters"
    for rx, why in DISHONEST_SUBJECT:
        if rx.search(subject):
            return why
    return None


def load_json(path, what: str):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8-sig"))
    except OSError:
        raise SystemExit(f"I could not find the {what} file: {path}")
    except ValueError as exc:
        raise SystemExit(f"The {what} file {path} is not valid JSON: {exc}")


def load_sender(path) -> dict:
    sender = load_json(path, "sender")
    return sender if isinstance(sender, dict) else {}


def sender_problems(sender: dict) -> list:
    out = []
    if not ADDRESS_RX.fullmatch(str(sender.get("from_email") or "")):
        out.append("sender.json has no valid from_email")
    if not str(sender.get("from_name") or "").strip():
        out.append("sender.json has no from_name, and the From line has to say who this is")
    address = str(sender.get("postal_address") or "").strip()
    if not address or len(address) < 10 or not re.search(r"\d", address) or not re.search(r"[A-Za-z]", address) or PLACEHOLDER_RX.search(address):
        out.append("sender.json has no real postal_address (the law asks for a valid physical address)")
    line = str(sender.get("opt_out_line") or "").strip()
    if not line or not OPT_OUT_RX.search(line):
        out.append("sender.json has no opt_out_line that tells people how to stop these emails")
    return out


def message_problems(msg: dict, sender: dict) -> list:
    who = msg.get("to") or msg.get("id") or "a message"
    out = []
    if not ADDRESS_RX.fullmatch(str(msg.get("to") or "")):
        out.append(f"{who}: the To address is not valid")
    why = subject_problem(msg.get("subject"))
    if why:
        out.append(f"{who}: the subject line is not acceptable because {why}")
    body = squash(msg.get("body"))
    if not body:
        out.append(f"{who}: the body is empty")
    line = squash(sender.get("opt_out_line"))
    if line and line not in body:
        out.append(f"{who}: the body is missing the opt-out line")
    address = squash(sender.get("postal_address"))
    if address and address not in body:
        out.append(f"{who}: the body is missing the postal address")
    if re.search(r"\{\{|\}\}|\[(first ?name|name|company|business)\]", str(msg.get("body") or ""), re.I):
        out.append(f"{who}: the body still has a template placeholder in it")
    return out


def batch_problems(queue: dict, sender: dict) -> list:
    out = sender_problems(sender)
    messages = queue.get("messages")
    if not isinstance(messages, list) or not messages:
        return out + ["this queue has no messages"]
    seen = set()
    for msg in messages:
        out += message_problems(msg, sender)
        addr = str(msg.get("to") or "").lower()
        if addr in seen:
            out.append(f"{addr}: appears twice in this batch")
        seen.add(addr)
    return out


def fingerprint(queue: dict, sender: dict) -> str:
    """Any edit to a message or to who it claims to be from changes this."""
    keep = {"messages": [{k: m.get(k) for k in ("to", "to_name", "subject", "body")} for m in queue.get("messages", [])],
            "from_email": sender.get("from_email"), "from_name": sender.get("from_name"), "reply_to": sender.get("reply_to"),
            "postal_address": sender.get("postal_address"), "opt_out_line": sender.get("opt_out_line")}
    return hashlib.sha256(json.dumps(keep, sort_keys=True, ensure_ascii=False).encode("utf-8")).hexdigest()


def approval_path(queue_path: Path) -> Path:
    return queue_path.with_name(queue_path.stem + ".approved.json")


def code_path() -> Path:
    return KEYS_FILE.parent / "approval-code.txt"


def mailbox_dir(sender: dict) -> Path:
    """One folder per sending address, so an opt-out holds whichever project folder a batch runs from."""
    slug = re.sub(r"[^a-z0-9@._-]", "_", str(sender.get("from_email") or "unknown").lower())
    folder = KEYS_FILE.parent / "mailboxes" / slug
    folder.mkdir(parents=True, exist_ok=True)
    if os.name != "nt":
        for path in (KEYS_FILE.parent, folder.parent, folder):
            try:
                path.chmod(0o700)
            except OSError:
                pass
    return folder


def suppression_path(sender: dict) -> Path:
    return mailbox_dir(sender) / "suppression.txt"


def log_path(sender: dict) -> Path:
    return mailbox_dir(sender) / "sent-log.jsonl"


def read_suppression(sender: dict) -> set:
    try:
        lines = suppression_path(sender).read_text(encoding="utf-8-sig").splitlines()
    except OSError:
        return set()
    return {ln.split("#")[0].strip().lower() for ln in lines if ln.split("#")[0].strip()}


def is_suppressed(addr: str, entries: set) -> bool:
    addr = addr.lower()
    return addr in entries or "@" + addr.split("@")[-1] in entries or addr.split("@")[-1] in entries


def read_log(sender: dict) -> list:
    try:
        lines = log_path(sender).read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    rows = []
    for line in lines:
        try:
            rows.append(json.loads(line))
        except ValueError:
            continue
    return rows


def append_log(sender: dict, row: dict) -> None:
    with log_path(sender).open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(row, ensure_ascii=False) + "\n")


def sent_today(rows: list) -> int:
    today = datetime.now().date().isoformat()
    return sum(1 for r in rows if r.get("status") == "sent" and str(r.get("time", "")).startswith(today))


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


def is_loopback(host: str) -> bool:
    if host.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def open_smtp(host: str, port: int, user: str, password: str, require_tls: bool):
    """Connect and log in. Refuses to send a password over a connection that is not encrypted."""
    context = ssl.create_default_context()
    if port == 465:
        server = smtplib.SMTP_SSL(host, port, timeout=60, context=context)
        server.ehlo()
    else:
        server = smtplib.SMTP(host, port, timeout=60)
        server.ehlo()
        if server.has_extn("starttls"):
            server.starttls(context=context)
            server.ehlo()
        elif require_tls:
            server.quit()
            raise RuntimeError(f"{host} does not offer an encrypted connection on port {port}, "
                               "so I did not send your password. Check SMTP_HOST and SMTP_PORT.")
    if user:
        server.login(user, password)
    return server


def build_message(msg: dict, sender: dict) -> EmailMessage:
    em = EmailMessage()
    em["From"] = formataddr((sender["from_name"], sender["from_email"]))
    em["To"] = formataddr((str(msg.get("to_name") or ""), msg["to"]))
    em["Subject"] = msg["subject"]
    em["Date"] = formatdate(localtime=True)
    em["Message-ID"] = make_msgid(domain=sender["from_email"].split("@")[-1])
    if sender.get("reply_to"):
        em["Reply-To"] = sender["reply_to"]
    em["List-Unsubscribe"] = f"<mailto:{sender.get('reply_to') or sender['from_email']}?subject=unsubscribe>"
    em.set_content(str(msg["body"]))
    return em


# ---------------------------------------------------------------- commands

def open_for_owner(path: Path) -> bool:
    try:
        if os.name == "nt":
            subprocess.Popen(["notepad", str(path)])
        elif sys.platform == "darwin":
            subprocess.Popen(["open", "-e", str(path)])
        else:
            return False
    except OSError:
        return False
    return True


def safe_arg(text):
    """A value for a line the owner pastes into a shell. Git Bash and PowerShell read this the same way, or it is refused."""
    if not re.fullmatch(r"[\w :/.\-()'+,@~]+", text):
        raise ValueError(f"This path has characters that are not safe in a line you paste into a shell: {text}. Move it to a plainly named folder and run this again.")
    return f'"{text}"'


def python_call() -> str:
    """Starts Python the same way in Git Bash and PowerShell, because a `!` line on Windows can land in either."""
    exe = Path(sys.executable).as_posix()
    if os.name != "nt":
        return safe_arg(exe)
    if re.fullmatch(r"[\w:/.\-()]+", exe) and os.path.lexists(exe):
        return exe
    for name in ("py", "python", "python3"):
        if shutil.which(name):
            return name
    return safe_arg(exe)


def owner_line(queue_path: Path, sender_path: Path) -> str:
    """The exact line for the owner to run. THE-CODE stays a placeholder, because only they see the code."""
    script = Path(__file__).resolve().as_posix()
    return f'{python_call()} {safe_arg(script)} approve {safe_arg(queue_path.resolve().as_posix())} --sender {safe_arg(sender_path.resolve().as_posix())} --code THE-CODE'


def cmd_review(a) -> int:
    path = Path(a.queue)
    queue, sender = load_json(path, "queue"), load_sender(a.sender)
    problems = batch_problems(queue, sender)
    say(f"Batch {path.name}: {len(queue.get('messages', []))} emails from {sender.get('from_name')} <{sender.get('from_email')}>.")
    if sender.get("reply_to"):
        say(f"Replies and unsubscribe requests go to: {sender['reply_to']}")
    if problems:
        say("This batch cannot be approved yet:")
        for p in problems:
            say(f"  - {p}")
        return 5
    entries = read_suppression(sender)
    skipped = [m["to"] for m in queue["messages"] if is_suppressed(m["to"], entries)]
    if skipped:
        say(f"{len(skipped)} on your suppression list will be skipped: {', '.join(skipped[:10])}")
    for msg in queue["messages"]:
        say("-" * 50)
        name = f"{msg['to_name']} " if msg.get("to_name") else ""
        say(f"To: {name}<{msg['to']}>\nSubject: {msg['subject']}\n\n{msg['body']}")
    say("-" * 50)
    try:
        line_for_owner = owner_line(path, Path(a.sender))
    except ValueError as err:
        say(str(err))
        return 5
    target = code_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    emails = "\n\n".join(f"To: {m.get('to_name') or ''} <{m['to']}>\nSubject: {m['subject']}\n\n{m['body']}" for m in queue["messages"])
    target.write_text(
        f"Approval code: {fingerprint(queue, sender)[:8]}\n\n"
        f"This is for {len(queue['messages'])} emails in {path.name}, from {sender.get('from_email')}.\n"
        "This code approves exactly the emails listed below. If they differ from what Claude showed you in the chat, do not approve them.\n"
        "If you are happy with them, run the line Claude gave you and put this code in place of THE-CODE.\n"
        "Any change to the batch makes this code stop working.\n\n" + emails + "\n", encoding="utf-8")
    tighten_keys()
    if os.name != "nt":
        try:
            target.chmod(0o600)
        except OSError:
            pass
    opened = False if a.no_open else open_for_owner(target)
    say("The approval code is NOT shown here. It is in a file for the owner only: " + str(target))
    say("I opened that file for them." if opened else "Ask the owner to open that file themselves. Do not open it for them.")
    say("Claude: never read, open, print or search that file, and never work the code out. Paste every email above into your message, "
        "because the owner cannot see this output. Then give the owner this line to run themselves:")
    say(owner_line(path, Path(a.sender)))
    say("A plain yes or 'send them' is not approval. Any edit to the batch changes the code.")
    return 0


def cmd_approve(a) -> int:
    path = Path(a.queue)
    queue, sender = load_json(path, "queue"), load_sender(a.sender)
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
    approval_path(path).write_text(json.dumps({
        "fingerprint": full, "count": len(queue["messages"]), "approved_at": datetime.now().isoformat(timespec="seconds"),
    }, indent=1), encoding="utf-8")
    say(f"Approved {len(queue['messages'])} emails. Saved to {approval_path(path).name}.")
    return 0


def cmd_send(a) -> int:
    path = Path(a.queue)
    queue, sender = load_json(path, "queue"), load_sender(a.sender)
    problems = batch_problems(queue, sender)
    if problems:
        say("I will not send this batch:")
        for p in problems:
            say(f"  - {p}")
        return 5
    try:
        approval = json.loads(approval_path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        say("This batch has not been approved, so nothing was sent. Run review, show the owner, then approve.")
        return 5
    if approval.get("fingerprint") != fingerprint(queue, sender):
        say("This batch changed after it was approved, so nothing was sent. Run review and get a new approval.")
        return 5

    try:
        cap = int(sender.get("daily_cap", DEFAULT_CAP))
        pause = float(sender.get("pause_seconds", DEFAULT_PAUSE))
    except (TypeError, ValueError):
        say("daily_cap and pause_seconds in sender.json have to be numbers.")
        return 2
    if cap < 1 or cap > MAX_CAP:
        say(f"The daily cap has to be between 1 and {MAX_CAP}. Sending more than that from one mailbox puts your domain at risk.")
        return 2

    keys = read_keys()
    host = keys.get("SMTP_HOST", "")
    user = keys.get("SMTP_USER", "")
    password = keys.get("SMTP_PASSWORD", "")
    try:
        port = int(keys.get("SMTP_PORT") or 587)
    except ValueError:
        say("SMTP_PORT in your keys file has to be a number, usually 587.")
        return 2
    if not a.dry_run and not (host and user and password):
        say(f"I need your email login and it is not set up yet. Open this file in a text editor: {KEYS_FILE}\n"
            "Add four lines: SMTP_HOST=..., SMTP_PORT=587, SMTP_USER=..., SMTP_PASSWORD=...\n"
            "Your email provider's help pages list these. Google accounts need an app password. "
            "Do not paste any of it into this chat.")
        return 3
    local = is_loopback(host)
    if not local and pause < MIN_PAUSE:
        say(f"The pause between sends has to be at least {MIN_PAUSE} seconds.")
        return 2

    rows = read_log(sender)
    # An address the server refused is not tried again. Retrying dead addresses hurts your domain.
    done_addresses = {str(r.get("to", "")).lower() for r in rows if r.get("status") in ("sent", "refused")}
    room = cap - sent_today(rows)
    server = None
    sent = skipped = failed = in_a_row = 0
    left = 0
    try:
        for msg in queue["messages"]:
            addr = msg["to"].lower()
            if addr in done_addresses:
                continue
            # Read fresh each time, so someone added to the list mid-run is honored.
            if is_suppressed(addr, read_suppression(sender)):
                skipped += 1
                append_log(sender, {"time": datetime.now().isoformat(timespec="seconds"), "to": addr, "batch": path.stem, "status": "suppressed"})
                continue
            if room <= 0:
                left += 1
                continue
            if a.dry_run:
                say(f"Would send to {addr}: {msg['subject']}")
                room -= 1
                sent += 1
                continue
            if server is None:
                try:
                    server = open_smtp(host, port, user, password, require_tls=not local)
                except smtplib.SMTPAuthenticationError:
                    say("Your email provider rejected the login. Check SMTP_USER and SMTP_PASSWORD in your keys "
                        "file. Google accounts need an app password. Nothing was sent.")
                    return 3
                except (OSError, smtplib.SMTPException, RuntimeError) as exc:
                    say(f"I could not connect to your email server: {exc}. Nothing else was sent.")
                    return 1
            elif pause > 0:
                wait = pause * random.uniform(1.0, 1.25)
                say(f"Pausing {wait:.0f} seconds." if wait >= 1 else f"Pausing {wait:.2f} seconds.")
                time.sleep(wait)
            try:
                server.send_message(build_message(msg, sender))
            except smtplib.SMTPRecipientsRefused as exc:
                failed += 1
                in_a_row += 1
                code = next(iter(exc.recipients.values()))[0] if exc.recipients else ""
                append_log(sender, {"time": datetime.now().isoformat(timespec="seconds"), "to": addr, "batch": path.stem, "status": "refused", "code": code})
                say(f"The server refused {addr} (code {code}).")
            except (smtplib.SMTPException, OSError, ValueError) as exc:
                failed += 1
                in_a_row += 1
                append_log(sender, {"time": datetime.now().isoformat(timespec="seconds"), "to": addr, "batch": path.stem, "status": "failed", "why": str(exc)[:200]})
                say(f"Sending to {addr} failed: {exc}")
                try:
                    if server is not None:
                        server.quit()
                except Exception:
                    pass
                server = None
            else:
                sent += 1
                in_a_row = 0
                room -= 1
                done_addresses.add(addr)
                append_log(sender, {"time": datetime.now().isoformat(timespec="seconds"), "to": addr, "batch": path.stem, "status": "sent"})
                say(f"Sent to {addr}.")
            if in_a_row >= STOP_AFTER_FAILS:
                say(f"{STOP_AFTER_FAILS} failures in a row, so I stopped. Your mailbox may be limited or blocked. Check it before trying again.")
                break
    finally:
        if server is not None:
            try:
                server.quit()
            except Exception:
                pass
    verb = "Would send" if a.dry_run else "Sent"
    say(f"{verb} {sent}. Skipped {skipped} on the suppression list. Failed {failed}.")
    if left:
        say(f"Still waiting: {left}, because the daily cap of {cap} is reached. Run this again tomorrow.")
    return 0 if failed == 0 else 1


def cmd_check_login(a) -> int:
    """Log in and log out. No email is sent."""
    keys = read_keys()
    host, user, password = keys.get("SMTP_HOST", ""), keys.get("SMTP_USER", ""), keys.get("SMTP_PASSWORD", "")
    if not (host and user and password) or "your-" in password:
        say(f"Your email login is not all there yet. Open this file in a text editor: {KEYS_FILE}\n"
            "It needs SMTP_HOST, SMTP_PORT, SMTP_USER and SMTP_PASSWORD. Do not paste any of it into this chat.")
        return 3
    try:
        port = int(keys.get("SMTP_PORT") or 587)
        server = open_smtp(host, port, user, password, require_tls=not is_loopback(host))
        server.quit()
    except smtplib.SMTPAuthenticationError:
        say("Your email provider rejected the login. Check SMTP_USER and SMTP_PASSWORD. Google accounts need an app password, not your normal password.")
        return 3
    except ValueError:
        say("SMTP_PORT in your keys file has to be a number, usually 587.")
        return 2
    except (OSError, smtplib.SMTPException, RuntimeError) as exc:
        say(f"I could not connect to your email server: {exc}. Check SMTP_HOST and SMTP_PORT. "
            "If your network or provider blocks outgoing mail, you can send the drafts by hand instead.")
        return 1
    say("Login works. No email was sent.")
    return 0


def cmd_drafts(a) -> int:
    """The short way: a file of finished emails to send by hand. Nothing connects to anything."""
    path = Path(a.queue)
    queue, sender = load_json(path, "queue"), load_sender(a.sender)
    problems = batch_problems(queue, sender)
    if problems:
        say("These drafts need fixing first:")
        for p in problems:
            say(f"  - {p}")
        return 5
    entries = read_suppression(sender)
    lines = ["# Email Drafts To Send By Hand", "",
             "Nothing here has been sent. Copy each one into your own email. Send a few a day, not all at once.", ""]
    count = skipped = 0
    for msg in queue["messages"]:
        if is_suppressed(msg["to"], entries):
            skipped += 1
            continue
        count += 1
        lines += [f"## {count}. {msg['to']}", "", f"**Subject:** {msg['subject']}", "", str(msg["body"]), ""]
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines), encoding="utf-8")
    say(f"Wrote {count} drafts to {out}. Skipped {skipped} on the suppression list. Nothing was sent.")
    return 0


def sender_beside(a, path: Path) -> dict:
    """The sender named on the command line, or the sender.json next to the queue."""
    return load_sender(a.sender if a.sender else path.parent / "sender.json")


def cmd_status(a) -> int:
    path = Path(a.queue)
    queue = load_json(path, "queue")
    sender = sender_beside(a, path)
    rows = read_log(sender)
    total = len(queue.get("messages", []))
    wanted = {str(m.get("to", "")).lower() for m in queue.get("messages", [])}
    done = {str(r.get("to", "")).lower() for r in rows if r.get("status") == "sent"} & wanted
    say(f"{len(done)} of {total} sent. {sent_today(rows)} sent today from this mailbox. Approved: {'yes' if approval_path(path).exists() else 'no'}.")
    return 0


def cmd_suppress(a) -> int:
    path = Path(a.queue)
    sender = sender_beside(a, path)
    existing = read_suppression(sender)
    added = []
    with suppression_path(sender).open("a", encoding="utf-8") as fh:
        for entry in a.entries:
            entry = entry.strip().lower()
            if entry and entry not in existing:
                fh.write(entry + "\n")
                existing.add(entry)
                added.append(entry)
    say(f"Added {len(added)}. They will never be emailed from {sender.get('from_email')} again, in any project folder.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Send an approved batch through your own email login.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check-login", help="prove the email login works, sending nothing")
    for name in ("review", "approve", "send", "drafts"):
        p = sub.add_parser(name)
        p.add_argument("queue")
        p.add_argument("--sender", required=True)
        if name == "drafts":
            p.add_argument("--out", required=True)
        if name == "review":
            p.add_argument("--no-open", action="store_true", help="do not open the code file on this screen")
        if name == "approve":
            p.add_argument("--code", required=True)
        if name == "send":
            p.add_argument("--dry-run", action="store_true")
    p = sub.add_parser("status")
    p.add_argument("queue")
    p.add_argument("--sender")
    p = sub.add_parser("suppress")
    p.add_argument("queue")
    p.add_argument("--sender")
    p.add_argument("entries", nargs="+", help="addresses, or @domain.com for a whole domain")
    a = ap.parse_args()
    try:
        return {"review": cmd_review, "approve": cmd_approve, "send": cmd_send, "status": cmd_status, "suppress": cmd_suppress, "check-login": cmd_check_login, "drafts": cmd_drafts}[a.cmd](a)
    except SystemExit as exc:
        if isinstance(exc.code, str):
            say(exc.code)
            return 2
        raise
    except KeyboardInterrupt:
        say("Stopped. Run send again to carry on. Anyone already sent to will not be emailed twice.")
        return 1
    except socket.gaierror:
        say("I could not find your email server. Check SMTP_HOST in your keys file.")
        return 1
    except Exception as exc:  # a stranger should never see a stack trace
        say(f"Something went wrong: {exc}. Tell me what you were doing and I will look.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
