#!/usr/bin/env python3
"""check_text.py: flag the things that make writing read like a machine wrote it.

    python check_text.py draft.txt
    python check_text.py --queue queue.json

Prints one line per hit with the line number and the fix to make. Exit 0 when clean, 1 when there are
hits. It catches the easy ones. Reading the draft out loud catches the rest.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# Built from code points so this file itself carries none of the characters it hunts for.
LONG_DASHES = "".join(map(chr, (0x2012, 0x2013, 0x2014, 0x2015)))
CURLY = "".join(map(chr, (0x201C, 0x201D, 0x2018, 0x2019)))

STIFF_WORDS = {
    "delve": "look at", "tapestry": "mix", "testament": "proof", "leverage": "use", "utilize": "use",
    "seamless": "easy", "seamlessly": "easily", "robust": "strong", "elevate": "improve", "empower": "help",
    "streamline": "simplify", "synergy": "say what actually happens", "holistic": "complete",
    "cutting-edge": "new", "game-changer": "say what changed", "game-changing": "say what changed",
    "revolutionize": "change", "transformative": "say what changes", "landscape": "market",
    "realm": "area", "pivotal": "important", "crucial": "important", "myriad": "many", "plethora": "many",
    "foster": "build", "navigate": "handle", "bespoke": "custom", "paramount": "most important",
    "underscore": "show", "unparalleled": "say what is better", "unlock": "get",
}
STOCK_PHRASES = [
    (r"i hope (this|you).{0,20}(finds|well)", "cut the warm-up and open on the reason you are writing"),
    (r"i wanted to reach out", "say why you are writing"),
    (r"just (checking|circling|touching) (in|back|base)", "say what you want"),
    (r"in today'?s .{0,25}(world|landscape|market|environment|age)", "cut it"),
    (r"it'?s (important|worth) (to note|noting)", "cut it and state the thing"),
    (r"at the end of the day", "cut it"),
    (r"not (just|only) .{1,50}? but (also )?", "say the one thing that matters"),
    (r"(whether you'?re|from) .{1,40}? (or|to) ", "pick the one case that fits this reader"),
    (r"take .{0,20}to the next level", "say what gets better and by how much"),
    (r"(dive|deep dive|diving) (in|into)", "say what you looked at"),
    (r"look no further", "cut it"),
    (r"i'?d love to", "ask directly"),
    (r"(thrilled|excited|delighted) to", "cut it"),
    (r"as an ai\b", "cut it"),
    (r"here'?s the (thing|kicker)", "cut it and say the thing"),
    (r"let me know if you have any questions", "ask one specific question or stop"),
]


def check(text: str) -> list:
    hits = []
    for number, line in enumerate(text.splitlines(), 1):
        low = line.lower()
        if any(c in line for c in LONG_DASHES):
            hits.append((number, "long dash", "use a period or a comma"))
        if any(c in line for c in CURLY):
            hits.append((number, "curly quote", "use a straight quote, the way people type"))
        for word, fix in STIFF_WORDS.items():
            if re.search(rf"\b{re.escape(word)}\b", low):
                hits.append((number, word, f"try: {fix}"))
        for rx, fix in STOCK_PHRASES:
            m = re.search(rx, low)
            if m:
                hits.append((number, m.group(0).strip(), fix))
        if re.match(r"\s*[*#]|\s*\*\*", line) or "**" in line:
            hits.append((number, "markdown", "emails are plain text, so remove it"))
        if len(re.findall(r"!", line)) > 1:
            hits.append((number, "several exclamation marks", "keep one at most"))
        if re.search(r"\b\w+, \w+,? and \w+\b", low) and len(line.split()) < 14:
            hits.append((number, "list of three", "machines love threes, so check it is really three things"))
    sentences = [s for s in re.split(r"(?<=[.!?])\s+", text) if s.strip()]
    lengths = [len(s.split()) for s in sentences]
    if len(lengths) >= 5 and max(lengths) - min(lengths) <= 4:
        hits.append((0, "every sentence is about the same length", "vary them, with some short ones"))
    return hits


def main() -> int:
    ap = argparse.ArgumentParser(description="Flag machine-sounding writing.")
    ap.add_argument("file", nargs="?")
    ap.add_argument("--queue", help="check every message body in an email queue file")
    a = ap.parse_args()
    items = []
    try:
        if a.queue:
            data = json.loads(Path(a.queue).read_text(encoding="utf-8-sig"))
            items = [(m.get("to", "?"), f"{m.get('subject', '')}\n{m.get('body', '')}") for m in data.get("messages", [])]
        elif a.file:
            items = [(a.file, Path(a.file).read_text(encoding="utf-8-sig"))]
        else:
            print("Give me a text file, or --queue with a queue file.")
            return 2
    except (OSError, ValueError) as exc:
        print(f"I could not read that file: {exc}")
        return 2
    total = 0
    for name, text in items:
        hits = check(text)
        total += len(hits)
        for number, what, fix in hits:
            where = f"line {number}" if number else "overall"
            print(f"{name}, {where}: {what}. {fix}.")
    print("Clean." if not total else f"{total} things to fix.")
    return 0 if not total else 1


if __name__ == "__main__":
    sys.exit(main())
