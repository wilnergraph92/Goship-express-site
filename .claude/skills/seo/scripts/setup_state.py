#!/usr/bin/env python3
"""setup_state.py: what is set up so far, and where to pick up. Standard library only.

    python setup_state.py status [--work seo-work]        what is there now; key values are never shown
    python setup_state.py keys-file                       make the key file if missing and say how to open it
    python setup_state.py mark <tool> <done|skipped|later> [--note "..."] [--days 3] [--work seo-work]
    python setup_state.py choose <full|short|pick> [--work seo-work]
    python setup_state.py deny-rule [--add]               show the rule that keeps Claude's file tools out of the key file; --add only after a yes

Tools: search_console, website_access, dataforseo, google_sign_in
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import sys
from datetime import date, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from seolib import KEYS_FILE, lock_down_keys, read_keys, run_main, save_json  # noqa: E402

TOOLS = {
    "search_console": "Google Search Console",
    "website_access": "Website access",
    "dataforseo": "DataForSEO",
    "google_sign_in": "Google sign in",
}
KEY_NAMES = {
    "website_access": ["WP_SITE_URL", "WP_USER", "WP_APP_PASSWORD"],
    "dataforseo": ["DATAFORSEO_LOGIN", "DATAFORSEO_PASSWORD", "DATAFORSEO_MAX_USD"],
    "google_sign_in": ["GSC_CLIENT_ID", "GSC_CLIENT_SECRET"],
}
DENY_RULES = ["Read(~/.config/claude-skills/keys.env)", "Edit(~/.config/claude-skills/keys.env)", "Read(~/.config/claude-skills/seo-approval-code.txt)"]
TEMPLATE = """# Keys for your Claude skills. Fill in only what you use, after the = sign, then save.
# Never paste these into a chat. Remove the # at the start of a line to use it.

# WordPress
# WP_SITE_URL=https://your-website.com
# WP_USER=your WordPress username
# WP_APP_PASSWORD=the application password

# DataForSEO
# DATAFORSEO_LOGIN=the email you signed up with
# DATAFORSEO_PASSWORD=the API password from the API Access page
# DATAFORSEO_MAX_USD=2

# Google sign in for Search Console
# GSC_CLIENT_ID=your client id
# GSC_CLIENT_SECRET=your client secret
"""


def state_file(work) -> Path:
    return Path(work) / "setup.json"


def read_state(work) -> dict:
    try:
        return json.loads(state_file(work).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"choice": None, "tools": {}}


def how_to_open(path: Path) -> str:
    if os.name == "nt":
        return f"Press the Windows key and R together, paste this, and press Enter:  notepad \"{path}\""
    if platform.system() == "Darwin":
        return f"Open the Terminal app, paste this, and press Return:  open -e \"{path}\""
    return f"Open this file in any text editor: {path}"


def cmd_status(args) -> int:
    work = Path(args.work)
    state = read_state(work)
    keys = read_keys()
    print(f"Python {platform.python_version()} on {platform.system()}.")
    print(f"Work folder: {work.resolve()} ({'there' if work.is_dir() else 'not made yet'}).")
    print(f"Key file: {KEYS_FILE if KEYS_FILE.is_file() else 'none yet'}.")
    print("Rule keeping Claude's file tools out of the key file: " + ("set" if deny_rules_present() else "not set") + ".")
    gsc = work / "gsc.json"
    if gsc.is_file():
        try:
            data = json.loads(gsc.read_text(encoding="utf-8"))
            print(f"Search Console data: yes, {len(data.get('queries', []))} searches and {len(data.get('pages', []))} pages, "
                  f"from {data.get('source')}.")
        except ValueError:
            print("Search Console data: the file is damaged.")
    else:
        print("Search Console data: not yet.")
    crawl = work / "crawl.json"
    if crawl.is_file():
        try:
            data = json.loads(crawl.read_text(encoding="utf-8"))
            print(f"Site read: {data.get('host')}, {len(data.get('pages', []))} pages, {data.get('crawled_at')}"
                  + ("" if data.get("finished", True) else ", not finished yet") + ".")
        except ValueError:
            print("Site read: the file is damaged.")
    else:
        print("Site read: not yet.")
    print("Google sign in saved: " + ("yes" if (KEYS_FILE.parent / "seo-search-console-token.json").is_file() else "no") + ".")
    for tool, names in KEY_NAMES.items():
        print(f"{TOOLS[tool]} keys: " + ", ".join(f"{name} {'set' if keys.get(name) else 'not set'}" for name in names) + ".")
    if state.get("choice"):
        print(f"They chose: {state['choice']}.")
    for tool, name in TOOLS.items():
        row = state.get("tools", {}).get(tool)
        if row:
            line = f"Progress, {name}: {row['state']} on {row['date']}"
            if row.get("come_back"):
                due = date.fromisoformat(row["come_back"]) <= date.today()
                line += f", come back {row['come_back']}" + (" (that day has come, so ask for the export now)" if due else "")
            if row.get("note"):
                line += f". {row['note']}"
            print(line + ".")
    return 0


def settings_file() -> Path:
    folder = os.environ.get("CLAUDE_CONFIG_DIR")
    return (Path(folder).expanduser() if folder else Path.home() / ".claude") / "settings.json"


def deny_rules_present() -> bool:
    try:
        deny = json.loads(settings_file().read_text(encoding="utf-8")).get("permissions", {}).get("deny", [])
    except (OSError, ValueError, AttributeError):
        return False
    return all(rule in deny for rule in DENY_RULES)


def cmd_deny_rule(args) -> int:
    path = settings_file()
    if not args.add:
        print(f"This would add these lines to the deny list in {path}:")
        for rule in DENY_RULES:
            print(f"  {rule}")
        print("They stop Claude's own file tools, and commands like cat, from opening your key file or your approval code. They do not stop a script that opens "
              "a file itself, and these skills' scripts need the key file. Nothing was changed. Add them only if the person says yes.")
        return 0
    try:
        data = json.loads(path.read_text(encoding="utf-8")) if path.is_file() else {}
        if not isinstance(data, dict) or not isinstance(data.get("permissions", {}), dict) or not isinstance(data.get("permissions", {}).get("deny", []), list):
            raise ValueError
    except (OSError, ValueError):
        print(f"{path} is not in a shape I can safely edit, so I changed nothing. Add these lines by hand: " + ", ".join(DENY_RULES))
        return 1
    deny = data.setdefault("permissions", {}).setdefault("deny", [])
    missing = [rule for rule in DENY_RULES if rule not in deny]
    if not missing:
        print("The rule is already there. Nothing was changed.")
        return 0
    deny.extend(missing)
    if path.is_file():
        path.with_name(path.name + ".before-seo-skill").write_bytes(path.read_bytes())
    path.parent.mkdir(parents=True, exist_ok=True)
    save_json(path, data)
    print(f"Added the rule to {path}. It applies from the next session. Your old copy is beside it, ending in .before-seo-skill.")
    return 0


def cmd_keys_file(args) -> int:
    path = KEYS_FILE
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file():
        print(f"The key file is already there: {path}")
    else:
        path.write_text(TEMPLATE, encoding="utf-8", newline="\n")
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
        print(f"Made the key file: {path}")
    lock_down_keys()
    print(how_to_open(path))
    return 0


def cmd_mark(args) -> int:
    state = read_state(args.work)
    row = {"state": args.state, "date": date.today().isoformat()}
    if args.note:
        row["note"] = args.note
    if args.days:
        row["come_back"] = (date.today() + timedelta(days=args.days)).isoformat()
    state.setdefault("tools", {})[args.tool] = row
    save_json(state_file(args.work), state)
    print(f"Saved: {TOOLS[args.tool]} is {args.state}.")
    return 0


def cmd_choose(args) -> int:
    state = read_state(args.work)
    state["choice"] = args.choice
    save_json(state_file(args.work), state)
    print(f"Saved: {args.choice}.")
    return 0


def main():
    ap = argparse.ArgumentParser(description="What is set up so far.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    one = sub.add_parser("status")
    one.add_argument("--work", default="seo-work")
    sub.add_parser("keys-file")
    three = sub.add_parser("mark")
    three.add_argument("tool", choices=sorted(TOOLS))
    three.add_argument("state", choices=["done", "skipped", "later"])
    three.add_argument("--note", default="")
    three.add_argument("--days", type=int, default=0)
    three.add_argument("--work", default="seo-work")
    four = sub.add_parser("choose")
    four.add_argument("choice", choices=["full", "short", "pick"])
    four.add_argument("--work", default="seo-work")
    five = sub.add_parser("deny-rule")
    five.add_argument("--add", action="store_true", help="add it; only after the person says yes")
    args = ap.parse_args()
    return {"status": cmd_status, "keys-file": cmd_keys_file, "mark": cmd_mark, "choose": cmd_choose, "deny-rule": cmd_deny_rule}[args.cmd](args)


if __name__ == "__main__":
    run_main(main)
