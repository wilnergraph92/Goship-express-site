#!/usr/bin/env python3
"""setup_state.py: what is set up so far, and where to pick up. Standard library only.

    python setup_state.py status [--work search-work]     what is there now; key values are never shown
    python setup_state.py keys-file                       make the key file if missing and say how to open it
    python setup_state.py mark <tool> <done|skipped|later> [--note "..."] [--days 3] [--work search-work]
    python setup_state.py choose <full|basic|pick> [--work search-work]
    python setup_state.py deny-rule [--add]               show the rule that keeps Claude's file tools out of the key files; --add only after a yes

Tools: serpapi, dataforseo, places, search_console, business_profile, website_access, pagespeed
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
from searchlib import KEYS_FILE, lock_down_keys, month_used, read_keys, run_main, save_json  # noqa: E402

TOOLS = {
    "serpapi": "SerpApi (reads Google's AI answers, free plan)",
    "dataforseo": "DataForSEO (reads Google's AI answers, pay as you go)",
    "places": "Google Places key (review numbers for you and competitors)",
    "search_console": "Google Search Console exports (your AI answer impressions, free)",
    "business_profile": "Google Business Profile connection (read and update your profile)",
    "website_access": "Website access (Claude makes the page fixes)",
    "pagespeed": "PageSpeed key (free, steadier speed checks)",
}
KEY_NAMES = {
    "serpapi": ["SERPAPI_KEY", "SERPAPI_MAX_SEARCHES"],
    "dataforseo": ["DATAFORSEO_LOGIN", "DATAFORSEO_PASSWORD", "DATAFORSEO_MAX_USD"],
    "places": ["GOOGLE_PLACES_KEY", "PLACES_MAX_CALLS"],
    "business_profile": ["GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET"],
    "website_access": ["WP_SITE_URL", "WP_USER", "WP_APP_PASSWORD"],
    "pagespeed": ["PAGESPEED_KEY"],
}
TOKEN_FILE = KEYS_FILE.parent / "search-google-token.json"
DENY_RULES = ["Read(~/.config/claude-skills/keys.env)", "Edit(~/.config/claude-skills/keys.env)",
              "Read(~/.config/claude-skills/search-approval-code.txt)", "Read(~/.config/claude-skills/search-google-token.json)"]
TEMPLATE = """# Keys for your Claude skills. Fill in only what you use, after the = sign, then save.
# Never paste these into a chat. Remove the # at the start of a line to use it.

# SerpApi (reads Google's AI answers). The free plan is 250 searches a month.
# SERPAPI_KEY=your SerpApi private API key
# SERPAPI_MAX_SEARCHES=250

# DataForSEO (reads Google's AI answers, pay as you go)
# DATAFORSEO_LOGIN=the email you signed up with
# DATAFORSEO_PASSWORD=the API password from the API Access page
# DATAFORSEO_MAX_USD=2

# Google Places key (review numbers). 1,000 lookups a month are free; this line keeps you under that.
# GOOGLE_PLACES_KEY=your key
# PLACES_MAX_CALLS=900

# Google sign in, for your Business Profile
# GOOGLE_CLIENT_ID=your client id
# GOOGLE_CLIENT_SECRET=your client secret

# WordPress
# WP_SITE_URL=https://your-website.com
# WP_USER=the username of the Editor user you made
# WP_APP_PASSWORD=the application password

# PageSpeed (optional, free)
# PAGESPEED_KEY=your key
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


def settings_file() -> Path:
    folder = os.environ.get("CLAUDE_CONFIG_DIR")
    return (Path(folder).expanduser() if folder else Path.home() / ".claude") / "settings.json"


def deny_rules_present() -> bool:
    try:
        deny = json.loads(settings_file().read_text(encoding="utf-8")).get("permissions", {}).get("deny", [])
    except (OSError, ValueError, AttributeError):
        return False
    return all(rule in deny for rule in DENY_RULES)


def cmd_status(args) -> int:
    work = Path(args.work)
    state = read_state(work)
    keys = read_keys()
    print(f"Python {platform.python_version()} on {platform.system()}.")
    print(f"Work folder: {work.resolve()} ({'there' if work.is_dir() else 'not made yet'}).")
    print(f"Key file: {KEYS_FILE if KEYS_FILE.is_file() else 'none yet'}.")
    print("Rule keeping Claude's file tools out of the key files: " + ("set" if deny_rules_present() else "not set") + ".")
    for tool, names in KEY_NAMES.items():
        print(f"{TOOLS[tool]}: " + ", ".join(f"{name} {'set' if keys.get(name) else 'not set'}" for name in names) + ".")
    print("Google sign in for the Business Profile saved: " + ("yes" if TOKEN_FILE.is_file() else "no") + ".")
    used = {v: month_used(v) for v in ("dataforseo", "serpapi", "places")}
    print(f"Used this month on this computer: DataForSEO ${used['dataforseo']:.3f}, SerpApi {int(used['serpapi'])} searches, "
          f"Places {int(used['places'])} lookups.")
    for name, label in (("crawl.json", "Site read"), ("questions.json", "Customer questions"), ("answers.json", "AI answers read"),
                        ("baseline.json", "Before snapshot")):
        print(f"{label}: " + ("yes" if (work / name).is_file() else "not yet") + ".")
    if state.get("choice"):
        print(f"They chose: {state['choice']}.")
    for tool, name in TOOLS.items():
        row = state.get("tools", {}).get(tool)
        if row:
            line = f"Progress, {name}: {row['state']} on {row['date']}"
            if row.get("come_back"):
                due = date.fromisoformat(row["come_back"]) <= date.today()
                line += f", come back {row['come_back']}" + (" (that day has come, so pick this up now)" if due else "")
            if row.get("note"):
                line += f". {row['note']}"
            print(line + ".")
    return 0


def cmd_deny_rule(args) -> int:
    path = settings_file()
    if not args.add:
        print(f"This would add these lines to the deny list in {path}:")
        for rule in DENY_RULES:
            print(f"  {rule}")
        print("They stop Claude's own file tools from opening your key file, your Google sign in or an approval code. They do not stop a script "
              "that opens a file itself, and these skills' scripts need the key file. Nothing was changed. Add them only if the person says yes.")
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
        path.with_name(path.name + ".before-search-skill").write_bytes(path.read_bytes())
    path.parent.mkdir(parents=True, exist_ok=True)
    save_json(path, data)
    print(f"Added the rule to {path}. It applies from the next session. Your old copy is beside it, ending in .before-search-skill.")
    return 0


def cmd_keys_file(args) -> int:
    path = KEYS_FILE
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file():
        text = path.read_text(encoding="utf-8-sig")
        missing = [line for line in TEMPLATE.splitlines() if line.startswith("# ") and "=" in line
                   and line[2:].split("=", 1)[0] not in text]
        if missing:
            with path.open("a", encoding="utf-8", newline="\n") as fh:
                fh.write("\n# Added by the Search skill\n" + "\n".join(missing) + "\n")
            print(f"The key file was already there. I added {len(missing)} empty lines this skill uses, each starting with #: {path}")
        else:
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
    one.add_argument("--work", default="search-work")
    sub.add_parser("keys-file")
    three = sub.add_parser("mark")
    three.add_argument("tool", choices=sorted(TOOLS))
    three.add_argument("state", choices=["done", "skipped", "later"])
    three.add_argument("--note", default="")
    three.add_argument("--days", type=int, default=0)
    three.add_argument("--work", default="search-work")
    four = sub.add_parser("choose")
    four.add_argument("choice", choices=["full", "basic", "pick"])
    four.add_argument("--work", default="search-work")
    five = sub.add_parser("deny-rule")
    five.add_argument("--add", action="store_true", help="add it; only after the person says yes")
    args = ap.parse_args()
    return {"status": cmd_status, "keys-file": cmd_keys_file, "mark": cmd_mark, "choose": cmd_choose, "deny-rule": cmd_deny_rule}[args.cmd](args)


if __name__ == "__main__":
    run_main(main)
