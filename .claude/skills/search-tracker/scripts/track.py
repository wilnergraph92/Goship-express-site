#!/usr/bin/env python3
"""track.py: take an after picture and compare it with the before picture. Standard library only.

    python track.py snapshot --answers search-work/answers-after.json [--places search-work/raw/places-after.json]
                             [--profile search-work/raw/profile-after.json] [--gsc-ai <export>] --out search-work/track/after.json
    python track.py compare  --before search-work/baseline.json --after search-work/track/after.json [--before-gsc-ai <export>]
                             --out search-work/before-after

compare writes before-after.md and before-after.html. It only reads files; it calls no service.
"""
from __future__ import annotations

import argparse
import html
import json
import sys
from pathlib import Path

SEARCH_SCRIPTS = Path(__file__).resolve().parents[2] / "search" / "scripts"
sys.path.insert(0, str(SEARCH_SCRIPTS))
try:
    import snapshot  # noqa: E402
    from searchlib import die, load_json, run_main, save_json  # noqa: E402
except ImportError:
    print("This skill needs the search skill beside it, in the same skills folder. Install the whole file again.")
    sys.exit(1)

LIKE = ("provider", "location", "device", "engines", "gl", "hl")


def word(before, after) -> str:
    if before is None and after is None:
        return "not read"
    if not (before or {}).get("shown") and not (after or {}).get("shown"):
        return "no AI answer either time"
    b, a = bool((before or {}).get("own_cited")), bool((after or {}).get("own_cited"))
    if not (after or {}).get("shown"):
        return "AI answer showed before, not now"
    if not (before or {}).get("shown"):
        return "new AI answer, you are cited" if a else "new AI answer, you are not cited"
    return {(False, True): "NOW CITED", (True, False): "NO LONGER CITED", (True, True): "still cited", (False, False): "still not cited"}[(b, a)]


def compare(before: dict, after: dict, before_gsc=None) -> dict:
    out = {"before_taken": before.get("taken_at"), "after_taken": after.get("taken_at"), "warnings": [], "questions": [], "totals": {}}
    ba, aa = before.get("answers") or {}, after.get("answers") or {}
    for key in LIKE:
        if ba and aa and ba.get(key) != aa.get(key):
            out["warnings"].append(f"The {key} differs ({ba.get(key)} before, {aa.get(key)} after), so this is not like for like.")
    bq, aq = ba.get("per_question") or {}, aa.get("per_question") or {}
    for q in list(dict.fromkeys(list(bq) + list(aq))):
        row = {"q": q}
        for engine in ("ai_overview", "ai_mode"):
            b, a = (bq.get(q) or {}).get(engine), (aq.get(q) or {}).get(engine)
            if b is None and a is None:
                continue
            row[engine] = {"result": word(b, a), "named_before": bool((b or {}).get("own_named")), "named_after": bool((a or {}).get("own_named")),
                           "others_before": (b or {}).get("others_cited") or [], "others_after": (a or {}).get("others_cited") or []}
        if q not in bq or q not in aq:
            out["warnings"].append(f"'{q}' was only read {'after' if q not in bq else 'before'}, so it has no comparison.")
        out["questions"].append(row)
    for engine in ("ai_overview", "ai_mode"):
        def count(side, field):
            return sum(1 for v in side.values() if (v.get(engine) or {}).get(field))
        if any(engine in v for v in list(bq.values()) + list(aq.values())):
            out["totals"][engine] = {f: [count(bq, f), count(aq, f)] for f in ("shown", "own_cited", "own_named")}
    rb, ra = (before.get("reviews") or {}).get("you"), (after.get("reviews") or {}).get("you")
    if rb or ra:
        out["reviews"] = {"before": rb, "after": ra}
    gb = before_gsc or before.get("search_console_ai")
    ga = after.get("search_console_ai")
    if gb or ga:
        def per_day(g):
            return round(g["total_impressions"] / g["days"], 1) if g and g.get("days") and g.get("total_impressions") is not None else None
        out["search_console_ai"] = {"before": {k: (gb or {}).get(k) for k in ("total_impressions", "days", "first_day", "last_day")},
                                    "after": {k: (ga or {}).get(k) for k in ("total_impressions", "days", "first_day", "last_day")},
                                    "per_day": [per_day(gb), per_day(ga)]}
    return out


def write(result: dict, out: Path) -> None:
    labels = {"ai_overview": "AI Overviews", "ai_mode": "AI Mode"}
    md = ["# Before And After", "", f"Before: {result['before_taken']}. After: {result['after_taken']}.", ""]
    for w in result["warnings"]:
        md.append(f"- Warning: {w}")
    md += ["", "## The Count", ""]
    for engine, t in result["totals"].items():
        md.append(f"- {labels[engine]}: AI answer shown for {t['shown'][0]} then {t['shown'][1]} questions. You cited in {t['own_cited'][0]} then "
                  f"{t['own_cited'][1]}. Your name in the words {t['own_named'][0]} then {t['own_named'][1]}.")
    if result.get("reviews"):
        rb, ra = result["reviews"]["before"] or {}, result["reviews"]["after"] or {}
        md.append(f"- Google reviews: {rb.get('reviews_total')} then {ra.get('reviews_total')}, rating {rb.get('rating')} then {ra.get('rating')}.")
    if result.get("search_console_ai"):
        s = result["search_console_ai"]
        md.append(f"- Search Console, your links shown in AI answers: {s['before']['total_impressions']} over {s['before']['days']} days, then "
                  f"{s['after']['total_impressions']} over {s['after']['days']} days ({s['per_day'][0]} then {s['per_day'][1]} a day).")
    md += ["", "## Question By Question", "", "| Question | " + " | ".join(labels[e] for e in result["totals"]) + " |",
           "| --- | " + " | ".join("---" for _ in result["totals"]) + " |"]
    for row in result["questions"]:
        md.append(f"| {row['q'].replace('|', '/')} | " + " | ".join((row.get(e) or {}).get("result", "not read") for e in result["totals"]) + " |")
    md += ["", "## How To Read This", "",
           "AI answers change from one search to the next, even an hour apart, so one question flipping is weak evidence. A shift across many "
           "questions, or a steady rise in Search Console's count, is stronger. Google also changes on its own, so a change is not proof that a fix caused it.", ""]
    out.mkdir(parents=True, exist_ok=True)
    (out / "before-after.md").write_text("\n".join(md) + "\n", encoding="utf-8", newline="\n")
    body = "".join(f"<p>{html.escape(line)}</p>" if not line.startswith(("|", "#")) else
                   (f"<h2>{html.escape(line.lstrip('# '))}</h2>" if line.startswith("#") else f"<pre>{html.escape(line)}</pre>") for line in md if line)
    (out / "before-after.html").write_text("<!doctype html><html lang='en'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,"
                                           "initial-scale=1'><title>Before And After</title><style>body{font:16px/1.5 system-ui,sans-serif;max-width:860px;"
                                           "margin:24px auto;padding:0 16px;background:#fff;color:#1d1d1f}pre{margin:0;white-space:pre-wrap}</style></head><body>"
                                           + body + "</body></html>", encoding="utf-8", newline="\n")


def main():
    ap = argparse.ArgumentParser(description="Before and after.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    one = sub.add_parser("snapshot")
    one.add_argument("--answers")
    one.add_argument("--places")
    one.add_argument("--profile")
    one.add_argument("--gsc-ai")
    one.add_argument("--label", default="after")
    one.add_argument("--out", required=True)
    two = sub.add_parser("compare")
    two.add_argument("--before", required=True)
    two.add_argument("--after", required=True)
    two.add_argument("--before-gsc-ai", help="a Generative AI report export covering the weeks before the fixes")
    two.add_argument("--out", default="search-work/before-after")
    args = ap.parse_args()
    if args.cmd == "snapshot":
        if not any((args.answers, args.places, args.profile, args.gsc_ai)):
            die("Give me at least one file to take the after picture from.", 2)
        snap = snapshot.build(args.answers, args.places, args.profile, args.gsc_ai, args.label)
        save_json(args.out, snap)
        print(f"Saved the {args.label} picture to {args.out}.")
        return 0
    before, after = load_json(args.before, "before picture"), load_json(args.after, "after picture")
    gb = snapshot.load_gsc_ai(args.before_gsc_ai) if args.before_gsc_ai else None
    result = compare(before, after, gb)
    write(result, Path(args.out))
    for engine, t in result["totals"].items():
        print(f"{engine}: cited {t['own_cited'][0]} then {t['own_cited'][1]}; named {t['own_named'][0]} then {t['own_named'][1]}; "
              f"AI answer shown {t['shown'][0]} then {t['shown'][1]}.")
    for w in result["warnings"]:
        print("Warning: " + w)
    print(f"Wrote {Path(args.out) / 'before-after.md'} and before-after.html.")
    return 0


if __name__ == "__main__":
    run_main(main)
