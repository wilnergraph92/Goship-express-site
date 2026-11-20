#!/usr/bin/env python3
"""check_overlap.py: make sure new ad copy did not lift a competitor's words or claims.

    python check_overlap.py --mine rewrites.txt --winners winners.json [--facts my-facts.txt]

Flags any run of 5 or more words shared with a competitor's ad, and any number, percent, price or strong
claim in your copy that also appears in theirs but not in your facts file. Exit 0 when clean, 1 when not.
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

RUN = 5
CLAIM_RX = re.compile(r"\$?\d[\d,.]*\s?%?(?:\s?(?:x|k|m|stars?|years?|days?|hours?|minutes?|customers?|clients?|reviews?))?"
                      r"|\b(?:guarantee[ds]?|#\s?1|number one|best in|award.?winning|fda|clinically|certified|free)\b", re.I)


def words(text: str) -> list:
    return re.findall(r"[a-z0-9$%']+", text.lower())


def shared_runs(mine: str, theirs: str, size: int = RUN) -> list:
    a, b = words(mine), words(theirs)
    grams = {tuple(b[i:i + size]) for i in range(len(b) - size + 1)}
    out, i = [], 0
    while i <= len(a) - size:
        if tuple(a[i:i + size]) in grams:
            j = i + size
            while j < len(a) and tuple(a[j - size + 1:j + 1]) in grams:
                j += 1
            out.append(" ".join(a[i:j]))
            i = j
        else:
            i += 1
    return out


def claims(text: str) -> set:
    return {" ".join(m.group(0).lower().split()).rstrip(".,") for m in CLAIM_RX.finditer(text)}


def main() -> int:
    ap = argparse.ArgumentParser(description="Check new ad copy against competitors' copy.")
    ap.add_argument("--mine", required=True)
    ap.add_argument("--winners", required=True)
    ap.add_argument("--facts", help="a text file of things that are true about this business")
    a = ap.parse_args()
    try:
        mine = Path(a.mine).read_text(encoding="utf-8-sig")
        ads = json.loads(Path(a.winners).read_text(encoding="utf-8-sig"))
        facts = Path(a.facts).read_text(encoding="utf-8-sig") if a.facts else ""
    except (OSError, ValueError) as exc:
        print(f"I could not read one of those files: {exc}")
        return 2
    allowed = claims(facts)
    problems = []
    for ad in ads if isinstance(ads, list) else []:
        theirs = f"{ad.get('headline', '')} {ad.get('copy', '')}"
        for run in shared_runs(mine, theirs):
            problems.append(f"Copied words, from {ad.get('advertiser', 'a competitor')}: \"{run}\". Rewrite it in your own words.")
        for claim in claims(mine) & claims(theirs):
            if claim not in allowed:
                problems.append(f"Same claim as {ad.get('advertiser', 'a competitor')}: \"{claim}\". Keep it only if it is true of this business and in the facts file.")
    unique = list(dict.fromkeys(problems))
    for p in unique:
        print(p)
    print("Clean: no copied words or borrowed claims found." if not unique else f"{len(unique)} things to fix.")
    return 0 if not unique else 1


if __name__ == "__main__":
    sys.exit(main())
