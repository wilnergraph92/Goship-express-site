#!/usr/bin/env python3
"""setup_check.py: what is set up so far, without ever showing a key.

    python setup_check.py                                 what is set, not set, done or skipped
    python setup_check.py keyfile --add APIFY_TOKEN       make the key file, add an empty line, say how to open it
    python setup_check.py keyfile --add NAME --open       also open it in the computer's text editor
    python setup_check.py mark apify done                 remember progress: done or skipped
    python setup_check.py deny-rule                       show the rule that keeps Claude out of the key file
    python setup_check.py deny-rule --add                 add it to Claude Code's settings, only after a yes

Standard library only. It reads key names and whether each has a value. It never prints a value.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import sys
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

PACK = "ads"
# Each tool: a short name, what to call it, and the keys that mean it is set up. No keys means a click-only tool.
TOOLS = [
    ("apify", "Apify (pulls ads from the Ad Library)", ["APIFY_TOKEN"]),
    ("meta", "Meta read-only token (your own account audit)", ["META_ACCESS_TOKEN"]),
    ("google", "Google Ads report file (your own account audit)", []),
    ("images", "Image key (OpenAI or Gemini)", ["OPENAI_API_KEY|GEMINI_API_KEY"]),
]
KEYS_FILE = Path.home() / ".config" / "claude-skills" / "keys.env"


DENY_RULES = [
    "Read(~/.config/claude-skills/keys.env)",
    "Edit(~/.config/claude-skills/keys.env)",
    "Read(~/.config/claude-skills/approval-code.txt)",
]


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


def settings_path() -> Path:
    folder = os.environ.get("CLAUDE_CONFIG_DIR")
    return (Path(folder) if folder else Path.home() / ".claude") / "settings.json"


def cmd_deny(a) -> int:
    path = settings_path()
    if not a.add:
        say(f"This would add these lines under permissions, deny, in {path}:")
        for rule in DENY_RULES:
            say(f"  {rule}")
        say("They stop Claude reading or editing your key file with its file tools and common shell commands. "
            "They do not stop every possible script, so this is a strong check, not a lock. Nothing was changed.")
        return 0
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig")) if path.exists() else {}
    except (OSError, ValueError):
        say(f"I could not read {path} as settings, so I left it alone. Add the lines by hand, or fix that file first.")
        return 1
    if not isinstance(data, dict):
        say(f"{path} is not the shape I expected, so I left it alone.")
        return 1
    perms = data.setdefault("permissions", {})
    deny = perms.setdefault("deny", [])
    new = [r for r in DENY_RULES if r not in deny]
    deny.extend(new)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        path.with_suffix(".json.before-deny-rule").write_text(path.read_text(encoding="utf-8"), encoding="utf-8")
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    say(f"Added {len(new)} rules to {path}. Start a new session to be sure they are in force." if new else "Those rules are already there.")
    return 0


def names_with_values() -> set:
    """Only the names that have a real value. The values go no further than this function."""
    have = set()
    try:
        lines = KEYS_FILE.read_text(encoding="utf-8-sig").splitlines()
    except OSError:
        return have
    for line in lines:
        line = line.strip()
        if line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        value = value.strip().strip('"').strip("'")
        if value and not value.lower().startswith("your"):
            have.add(name.replace("export ", "").strip())
    return have


def state_path() -> Path:
    return KEYS_FILE.parent / f"setup-{PACK}.json"


def read_state() -> dict:
    try:
        data = json.loads(state_path().read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def cmd_status() -> int:
    tighten_keys()
    have = names_with_values()
    state = read_state()
    say(f"Python {platform.python_version()}. Running from: {Path.cwd()}")
    say(f"Key file: {KEYS_FILE}" if KEYS_FILE.is_file() else f"Key file: none yet. It will go at {KEYS_FILE}")
    for key, label, names in TOOLS:
        mark = state.get(key)
        if names:
            missing = [n for n in names if not set(n.split("|")) & have]
            status = "set" if not missing else "not set"
        else:
            status = "not set up"
        if mark == "skipped" and status != "set":
            status = "skipped"
        elif mark == "done":
            status = "done" if not names or status == "set" else "not set"
        say(f"{label}: {status}")
    return 0


def cmd_keyfile(a) -> int:
    target = KEYS_FILE
    target.parent.mkdir(parents=True, exist_ok=True)
    try:
        text = target.read_text(encoding="utf-8-sig") if target.exists() else ""
    except OSError as exc:
        say(f"I could not open {target}: {exc}")
        return 1
    present = {ln.split("=", 1)[0].replace("export ", "").strip() for ln in text.splitlines() if "=" in ln and not ln.lstrip().startswith("#")}
    new = [n for n in (a.add or []) if n not in present]
    if not text:
        text = ("# Put each value right after the equals sign, then save. Do not share this file or paste it into a chat.\n"
                "# APIFY_MAX_USD is the most one Apify run may cost. With no line, the limit is 5. Only you change it.\n")
    if new:
        text = text.rstrip("\n") + "\n" + "".join(f"{n}=\n" for n in new)
    target.write_text(text, encoding="utf-8", newline="\n")
    tighten_keys()
    say(f"Key file: {target}")
    say(f"Added empty lines for: {', '.join(new)}" if new else "The lines it needs are already there.")
    if os.name == "nt":
        say(f"To open it yourself: press the Windows key, type Notepad, press Enter, then File, Open, and paste this path: {target}")
    elif sys.platform == "darwin":
        say(f"To open it yourself: open Terminal and run: open -e \"{target}\"")
    else:
        say(f"To open it, use any text editor. The path is: {target}")
    if a.open:
        try:
            if os.name == "nt":
                subprocess.Popen(["notepad", str(target)])
            elif sys.platform == "darwin":
                subprocess.Popen(["open", "-e", str(target)])
            else:
                say("I cannot open a window from here, so open it yourself.")
        except OSError:
            say("I could not open it from here, so open it yourself.")
    return 0


def cmd_mark(a) -> int:
    known = [t[0] for t in TOOLS]
    if a.tool not in known:
        say(f"I only track: {', '.join(known)}.")
        return 2
    path = state_path()
    state = read_state()
    state[a.tool] = a.state
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=1), encoding="utf-8")
    say(f"Saved: {a.tool} is {a.state}.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="What is set up so far. Never shows a key.")
    sub = ap.add_subparsers(dest="cmd")
    p = sub.add_parser("keyfile")
    p.add_argument("--add", action="append")
    p.add_argument("--open", action="store_true")
    p = sub.add_parser("deny-rule")
    p.add_argument("--add", action="store_true", help="the person said yes after seeing the rule")
    p = sub.add_parser("mark")
    p.add_argument("tool")
    p.add_argument("state", choices=["done", "skipped"])
    a = ap.parse_args()
    try:
        if a.cmd == "keyfile":
            return cmd_keyfile(a)
        if a.cmd == "mark":
            return cmd_mark(a)
        if a.cmd == "deny-rule":
            return cmd_deny(a)
        return cmd_status()
    except Exception as exc:  # a stranger should never see a stack trace
        say(f"Something went wrong: {type(exc).__name__}. Tell me what you were doing and I will look.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
