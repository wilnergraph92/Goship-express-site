#!/usr/bin/env python3
"""apollo_match.py: look up work emails in Apollo for leads the free pass found no address for.

    python apollo_match.py check
    python apollo_match.py estimate --people people.json --profiles profiles.json --emails emails.json [--min-fit 40]
    python apollo_match.py run      --people people.json --profiles profiles.json --emails emails.json [--min-fit 40] --confirm [--max-credits N]

Standard library only. The key comes from ~/.config/claude-skills/keys.env (APOLLO_API_KEY=...), which the
person fills in themselves. It is never printed and never passed on a command line.

It uses Apollo's bulk people enrichment (up to 10 people a call), matched on what each profile holds: a
real first and last name, plus their website's domain, their company name, or their LinkedIn link. It
never asks for phone numbers (8 extra credits each) or personal emails.

Credits, from Apollo's API pricing page (checked November 2026): 1 credit for each person Apollo finds
an email or other data for, 0 when there is no match. estimate shows the most it can use. run refuses
to go past the owner's ceiling (APOLLO_MAX_CREDITS in the key file, 100 when unset) and stops early if
the credits Apollo reports would pass it.

Confidence, and why:
  high    Apollo marks the email verified and the match is high confidence
  medium  Apollo marks the email verified and the match is medium confidence
  low     the email is not verified by Apollo, or the match is low confidence. Low is never used for
          sending until the owner checks it themselves and marks it checked
  blank   no match. A blank is the right answer; no address is ever guessed
"""
from __future__ import annotations

import argparse
import json
import os
import re
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

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from find_emails import LINK_IN_BIO, SHOP_HOSTS, SOCIAL_HOSTS, base_domain, clean_email  # noqa: E402


def test_base(name: str, default: str) -> str:
    """Only the leg tests set this. It may only point at this computer, so a real key can never be sent elsewhere."""
    value = os.environ.get(name, "").rstrip("/")
    try:
        host = urllib.parse.urlsplit(value).hostname or ""
    except ValueError:
        host = ""
    return value if host in ("127.0.0.1", "localhost", "::1") else default


API = test_base("APOLLO_TEST_BASE", "https://api.apollo.io/api/v1")
KEYS_FILE = Path.home() / ".config" / "claude-skills" / "keys.env"
KEY_PAGE = "https://developer.apollo.io/#/keys"
DEFAULT_CEILING = 100
CHUNK = 10
USABLE = {"high", "medium", "checked"}


def say(msg: str) -> None:
    print(msg, flush=True)


def read_keys() -> dict:
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


def ceiling() -> int:
    try:
        value = int(read_keys().get("APOLLO_MAX_CREDITS", ""))
    except ValueError:
        return DEFAULT_CEILING
    return value if value > 0 else DEFAULT_CEILING


def need_key():
    key = read_keys().get("APOLLO_API_KEY", "")
    if not key or key.lower().startswith("your"):
        say("I need your Apollo API key and there is none yet.\n"
            f"1. In Apollo, go to Settings, Integrations, API Keys: {KEY_PAGE}\n"
            "2. Click Create new key, and give it access to People Enrichment and Bulk People Enrichment.\n"
            f"3. Open this file in a text editor: {KEYS_FILE}\n"
            "4. Add one line: APOLLO_API_KEY=your-key-here\n"
            "Do not paste the key into this chat. Then run this again.")
        return None
    return key


def call(key: str, method: str, path: str, query=None, body=None):
    url = API + path + ("?" + urllib.parse.urlencode(query) if query else "")
    req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8") if body is not None else None, method=method)
    req.add_header("x-api-key", key)
    req.add_header("Content-Type", "application/json")
    req.add_header("Cache-Control", "no-cache")
    req.add_header("User-Agent", "claude-skill-lead-finder")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode("utf-8", "replace") or "{}")
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            raise RuntimeError(f"Apollo rejected the key. Copy it again from {KEY_PAGE} into {KEYS_FILE}.") from None
        if exc.code == 403:
            raise RuntimeError("Apollo says this key cannot use people enrichment. Edit the key in Apollo and tick People Enrichment "
                               "and Bulk People Enrichment, or make it a master key. A free Apollo account also needs a work email address.") from None
        if exc.code == 422 or exc.code == 402:
            raise RuntimeError("Apollo says the account is out of credits or the plan does not allow this. Check Settings, Billing and credits.") from None
        if exc.code == 429:
            raise RuntimeError("Apollo says too many requests. Wait a minute and run this again. It keeps what it found.") from None
        if exc.code >= 500:
            raise RuntimeError("Apollo is having a problem on its side. Try again in a few minutes.") from None
        raise RuntimeError(f"Apollo refused the request (status {exc.code}).") from None
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise RuntimeError(f"Could not reach Apollo ({getattr(exc, 'reason', exc)}). Check your connection.") from None
    except ValueError:
        raise RuntimeError("Apollo sent back something I could not read. Try again in a few minutes.") from None


# ---------------------------------------------------------------- who can be looked up

NAME_RX = re.compile(r"^[^\W\d_][^\W\d_'.-]*(?:[ '.-][^\W\d_]+)*$")


def split_name(name: str):
    parts = [p for p in re.split(r"\s+", str(name or "").strip()) if p]
    if len(parts) < 2 or not all(NAME_RX.match(p) for p in parts):
        return None
    return parts[0], parts[-1]


def company_of(headline: str) -> str:
    m = re.search(r"\b(?:at|@)\s+(.{2,80})$", str(headline or ""))
    return m.group(1).strip(" .,|") if m else ""


def detail_for(person: dict):
    """(details for Apollo, None) or (None, why not)."""
    names = split_name(person.get("name"))
    if not names:
        return None, "Apollo needs a real first and last name, and this profile has a handle only"
    d = {"first_name": names[0], "last_name": names[1]}
    site = str(person.get("website") or "")
    dom = base_domain(site) if site.startswith("http") or "." in site else ""
    if dom and dom not in SOCIAL_HOSTS | LINK_IN_BIO | SHOP_HOSTS:
        d["domain"] = dom
    profile = str(person.get("profile_url") or "")
    if person.get("platform") == "linkedin" and "linkedin.com/in/" in profile:
        d["linkedin_url"] = profile.rstrip("/")
    org = company_of(person.get("headline"))
    if org:
        d["organization_name"] = org
    if not ({"domain", "linkedin_url", "organization_name"} & set(d)):
        return None, "Apollo needs a website, a company or a LinkedIn link beside the name, and this profile has none"
    return d, None


def load(path, what):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8-sig"))
    except OSError:
        if what == "emails":
            return {}
        raise SystemExit(f"I could not find the {what} file: {path}")
    except ValueError as exc:
        raise SystemExit(f"The {what} file {path} is not valid JSON: {exc}")


def candidates(a) -> tuple:
    people = {p["id"]: p for p in load(a.people, "people") if isinstance(p, dict) and p.get("id")}
    profiles = load(a.profiles, "profiles")
    emails = load(a.emails, "emails")
    if not isinstance(emails, dict):
        emails = {}
    todo, skipped = [], []
    for prof in profiles if isinstance(profiles, list) else []:
        pid = prof.get("id") if isinstance(prof, dict) else None
        if pid not in people or (prof.get("fit_score") or 0) < a.min_fit:
            continue
        if emails.get(pid, {}).get("confidence") in USABLE:
            continue
        d, why = detail_for(people[pid])
        if d:
            todo.append((pid, d))
        else:
            skipped.append((pid, why))
    return people, emails, todo, skipped


# ---------------------------------------------------------------- grading

def grade(match: dict, sent: dict):
    """(confidence, why) or None when Apollo matched nobody usable."""
    if not isinstance(match, dict):
        return None
    if sent.get("linkedin_url") and match.get("linkedin_url"):
        if match["linkedin_url"].rstrip("/").split("/")[-1].lower() != sent["linkedin_url"].rstrip("/").split("/")[-1].lower():
            return None
    elif str(match.get("last_name") or "").lower() and str(match.get("last_name")).lower() != sent["last_name"].lower():
        return None
    status = str(match.get("email_status") or "").lower()
    conf = str(match.get("match_confidence") or "").lower()
    if conf == "none":
        return None
    if status != "verified":
        return "low", f"Apollo has this address as {status or 'not verified'}, so it may be a guess from a pattern. Check it before using it"
    if conf in ("high", ""):
        return "high", "Apollo verified the address and matched the person with high confidence"
    if conf == "medium":
        return "medium", "Apollo verified the address, but matched the person with medium confidence"
    return "low", "Apollo verified the address, but the match to this person is low confidence"


# ---------------------------------------------------------------- commands

def cmd_check(a) -> int:
    key = need_key()
    if not key:
        return 3
    try:
        data = call(key, "GET", "/auth/health")
    except RuntimeError as exc:
        if "cannot use people enrichment" in str(exc):
            say("Apollo knows this key, but the key is not allowed to call the health check. That is fine if it has People Enrichment "
                "and Bulk People Enrichment ticked. The first small lookup proves it.")
            return 0
        say(str(exc))
        return 1
    if data.get("is_logged_in") is False:
        say(f"Apollo answered, but says the key is not valid. Copy it again from {KEY_PAGE}.")
        return 1
    say("Apollo key works. This check uses no credits.")
    return 0


def cmd_estimate(a) -> int:
    _, _, todo, skipped = candidates(a)
    say(f"{len(todo)} people can be looked up in Apollo. That uses at most {len(todo)} credits: 1 for each person Apollo finds, 0 when it finds nobody.")
    say(f"{len(skipped)} cannot be looked up, mostly because the profile has a handle but no real name, or no website, company or LinkedIn link.")
    say(f"Your ceiling for one lookup is {ceiling()} credits. Only you change it, in your key file (APOLLO_MAX_CREDITS).")
    say("Phone numbers and personal emails are never asked for. Credits come from your Apollo plan: https://www.apollo.io/pricing")
    return 0


def cmd_run(a) -> int:
    people, emails, todo, skipped = candidates(a)
    limit = a.max_credits if a.max_credits is not None else min(len(todo), ceiling())
    if limit > ceiling():
        say(f"That is over your ceiling of {ceiling()} credits, so I did not start. Only you can raise it: open {KEYS_FILE} and add a line such as APOLLO_MAX_CREDITS=1000.")
        return 4
    if len(todo) > limit:
        say(f"{len(todo)} people could be looked up, but the limit is {limit} credits, so I will look up the {limit} best fits.")
        order = {p.get("id"): -(p.get("fit_score") or 0) for p in load(a.profiles, "profiles") if isinstance(p, dict)}
        todo = sorted(todo, key=lambda t: order.get(t[0], 0))[:limit]
    say(f"Apollo lookup: {len(todo)} people, at most {len(todo)} credits.")
    if not a.confirm:
        say("Not started. Show this to the person. If they say yes, run the same command with --confirm.")
        return 4
    key = need_key()
    if not key:
        return 3
    used = 0.0
    counts = {"high": 0, "medium": 0, "low": 0, "none": 0}
    out = Path(a.emails)
    for start in range(0, len(todo), CHUNK):
        chunk = todo[start:start + CHUNK]
        if used + len(chunk) > limit:
            say(f"Stopping: the next call could pass the {limit} credit limit. Used so far: {used:g}.")
            break
        try:
            res = call(key, "POST", "/people/bulk_match", {"reveal_personal_emails": "false", "reveal_phone_number": "false"},
                       {"details": [d for _, d in chunk]})
        except RuntimeError as exc:
            say(f"{exc} What was found so far is saved.")
            break
        spent = res.get("credits_consumed")
        used += float(spent) if isinstance(spent, (int, float)) else len(chunk)
        matches = res.get("matches") if isinstance(res.get("matches"), list) else []
        for i, (pid, sent) in enumerate(chunk):
            match = matches[i] if i < len(matches) else None
            graded = grade(match, sent)
            addr = clean_email(str((match or {}).get("email") or "")) if graded else None
            have = emails.get(pid, {}) if isinstance(emails.get(pid), dict) else {}
            if graded and addr:
                conf, why = graded
                counts[conf] += 1
                have.update(email=addr, confidence=conf, source="Apollo", why=why,
                            apollo={"email_status": match.get("email_status"), "match_confidence": match.get("match_confidence")})
            else:
                counts["none"] += 1
                notes = list(have.get("notes") or [])
                notes.append("Apollo found no matching person with an email")
                have.setdefault("email", "")
                have.setdefault("confidence", "")
                have["notes"] = notes
            emails[pid] = have
        out.write_text(json.dumps(emails, indent=1, ensure_ascii=False), encoding="utf-8")
        if start + CHUNK < len(todo):
            time.sleep(a.pause)
    say(f"Done: {counts['high']} high, {counts['medium']} medium, {counts['low']} low, {counts['none']} no match. "
        f"Credits Apollo reported: {used:g}. Saved to {out}.")
    say("Low means Apollo has not verified it, or the match is weak. It is not used for sending until the owner checks it.")
    if skipped:
        say(f"Not looked up: {len(skipped)} people with a handle only, or no website, company or LinkedIn link.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Look up work emails in Apollo, with a credit limit.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check")
    for name in ("estimate", "run"):
        p = sub.add_parser(name)
        p.add_argument("--people", required=True)
        p.add_argument("--profiles", required=True)
        p.add_argument("--emails", required=True)
        p.add_argument("--min-fit", type=float, default=40)
        if name == "run":
            p.add_argument("--confirm", action="store_true", help="the person said yes to the credit estimate")
            p.add_argument("--max-credits", type=int)
            p.add_argument("--pause", type=float, default=3.5, help="seconds between calls; Apollo's free plan allows 20 bulk calls a minute")
    a = ap.parse_args()
    try:
        return {"check": cmd_check, "estimate": cmd_estimate, "run": cmd_run}[a.cmd](a)
    except SystemExit as exc:
        if isinstance(exc.code, str):
            say(exc.code)
            return 2
        raise
    except KeyboardInterrupt:
        say("Stopped. What was found so far is saved.")
        return 1
    except Exception as exc:  # a stranger should never see a stack trace
        say(f"Something went wrong: {exc}. Tell me what you were doing and I will look.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
