#!/usr/bin/env python3
"""merge.py: put the twelve checks together into one report, rank the fixes, and save the before picture.

    python merge.py --work search-work [--gsc-ai <Generative AI report export>] [--rebaseline]

Reads search-work/checks/<check>.json, written by the twelve checking agents, and writes:
    search-report.html   to read
    search-report.md     the same, as text
    findings.json        every fix, numbered, for the search-fixer skill
    baseline.json        the before picture the search-tracker skill compares against (kept unless --rebaseline)
Standard library only.
"""
from __future__ import annotations

import argparse
import html
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import snapshot  # noqa: E402
from searchlib import run_main, save_json  # noqa: E402

CHECKS = [
    ("ai-answers", "AI Answers For Your Questions"),
    ("named-instead", "Who Google's AI Names Instead"),
    ("reviews", "Reviews"),
    ("profile", "Google Business Profile"),
    ("service-pages", "Service Pages"),
    ("location-pages", "Location Pages"),
    ("faq-answers", "Answers To Customer Questions"),
    ("schema", "Structured Data"),
    ("citations", "Listings And Directories"),
    ("ai-access", "Can Google Read Your Site"),
    ("speed", "Page Speed"),
    ("mentions", "Brand Mentions"),
]
STATUSES = ("good", "needs work", "missing", "could not check")
FIX_TYPES = ("new_page", "faq_answer", "title", "description", "schema", "gbp_update", "review_request", "directory_fix", "site_setting", "other")
IMPACT = {"high": 0, "medium": 1, "low": 2}


def clean(text, limit=1200) -> str:
    return " ".join(str(text or "").split())[:limit]


def load_check(path: Path, cid: str, title: str) -> dict:
    if not path.is_file():
        return {"check": cid, "title": title, "status": "could not check", "summary": "This check did not run, so its file is missing.",
                "findings": [], "could_not_see": ["Everything this check covers. Run it again."], "problem": "not run"}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise ValueError
    except (OSError, ValueError):
        return {"check": cid, "title": title, "status": "could not check", "summary": "This check's file is damaged.",
                "findings": [], "could_not_see": ["Everything this check covers. Run it again."], "problem": "damaged"}
    status = data.get("status") if data.get("status") in STATUSES else "could not check"
    findings = []
    for f in data.get("findings") or []:
        if not isinstance(f, dict) or not f.get("what"):
            continue
        findings.append({"what": clean(f.get("what"), 300), "evidence": clean(f.get("evidence"), 600), "fix": clean(f.get("fix"), 600),
                         "fix_type": f.get("fix_type") if f.get("fix_type") in FIX_TYPES else "other",
                         "impact": f.get("impact") if f.get("impact") in IMPACT else "medium"})
    return {"check": cid, "title": title, "status": status, "summary": clean(data.get("summary"), 400), "findings": findings,
            "could_not_see": [clean(x, 300) for x in data.get("could_not_see") or []][:10],
            "sources": [clean(x, 300) for x in data.get("sources") or []][:15]}


def headline(answers) -> list:
    if not answers:
        return ["Google's AI answers were not read on this run, so this report covers what feeds those answers, not the answers themselves."]
    s = answers.get("summary") or {}
    lines = []
    for engine, label in (("ai_overview", "AI Overviews"), ("ai_mode", "AI Mode")):
        e = s.get(engine) or {}
        if e.get("read"):
            lines.append(f"{label}: an AI answer showed for {e['shown']} of {e['read']} customer questions. Your site is cited in {e['own_cited']} "
                         f"of those and your name appears in {e['own_named']}.")
    if s.get("most_cited_instead"):
        lines.append("Sites cited most often instead of you: " + ", ".join(f"{d} ({n})" for d, n in s["most_cited_instead"][:5]) + ".")
    lines.append(f"Read on {answers.get('checked_at')} from {answers.get('location') or answers.get('gl', '').upper() or 'the default location'} "
                 f"on {answers.get('device')}, through {answers.get('provider')}. One look; answers change from search to search.")
    return lines


def write_reports(work: Path, checks: list, ranked: list, answers) -> None:
    md = ["# How Google's AI Sees Your Business", "", f"Made {datetime.now(timezone.utc).strftime('%Y-%m-%d')}.", "", "## The Short Version", ""]
    md += [f"- {line}" for line in headline(answers)]
    md += ["", "## Fixes, Biggest First", "", "Ranked by how much each is likely to matter, then by how fast it is to do. "
           "Nothing here can promise that Google names you first. These are the things Google says its AI answers draw on.", ""]
    for f in ranked[:25]:
        md.append(f"{f['id']}. **{f['what']}** ({f['impact']} impact, {f['check_title']}). Fix: {f['fix'] or 'see the check below'}")
    md += ["", "## The Twelve Checks", ""]
    for c in checks:
        md += [f"### {c['title']}: {c['status'].title()}", "", c["summary"] or "", ""]
        for f in c["findings"]:
            md.append(f"- {f['what']}" + (f" Evidence: {f['evidence']}" if f["evidence"] else ""))
        if c["could_not_see"]:
            md.append("")
            md.append("Could not see: " + "; ".join(c["could_not_see"]))
        md.append("")
    md += ["## How We Will Know If It Worked", "",
           "The same questions are read again later, from the same place and device, and compared with today. "
           "If you have Search Console, its Generative AI report shows how often your links appeared in AI answers, before and after. "
           "Google changes on its own too, so a change is not proof that a fix caused it.", ""]
    (work / "search-report.md").write_text("\n".join(md) + "\n", encoding="utf-8", newline="\n")

    e = html.escape
    color = {"good": "#1b7f3b", "needs work": "#b26b00", "missing": "#b3261e", "could not check": "#555"}
    parts = ["<!doctype html><html lang='en'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>",
             "<title>Search Report</title><style>body{font:16px/1.5 system-ui,sans-serif;max-width:860px;margin:24px auto;padding:0 16px;color:#1d1d1f;background:#fff}"
             "h1{font-size:26px}h2{margin-top:32px}.tag{font-weight:600}li{margin:6px 0}.muted{color:#555}</style></head><body>",
             "<h1>How Google's AI Sees Your Business</h1><h2>The Short Version</h2><ul>"]
    parts += [f"<li>{e(line)}</li>" for line in headline(answers)]
    parts.append("</ul><h2>Fixes, Biggest First</h2><p class='muted'>Nothing here can promise that Google names you first. These are the things Google says its AI answers draw on.</p><ol>")
    parts += [f"<li><b>{e(f['what'])}</b> <span class='muted'>({e(f['impact'])} impact, {e(f['check_title'])})</span><br>Fix: {e(f['fix'])}</li>" for f in ranked[:25]]
    parts.append("</ol><h2>The Twelve Checks</h2>")
    for c in checks:
        parts.append(f"<h3>{e(c['title'])}: <span class='tag' style='color:{color[c['status']]}'>{e(c['status'].title())}</span></h3><p>{e(c['summary'])}</p>")
        if c["findings"]:
            parts.append("<ul>" + "".join(f"<li>{e(f['what'])}" + (f"<br><span class='muted'>{e(f['evidence'])}</span>" if f["evidence"] else "") + "</li>"
                                          for f in c["findings"]) + "</ul>")
        if c["could_not_see"]:
            parts.append(f"<p class='muted'>Could not see: {e('; '.join(c['could_not_see']))}</p>")
    parts.append("<h2>How We Will Know If It Worked</h2><p>The same questions are read again later, from the same place and device, and compared with today. "
                 "Google changes on its own too, so a change is not proof that a fix caused it.</p></body></html>")
    (work / "search-report.html").write_text("".join(parts), encoding="utf-8", newline="\n")


def main():
    ap = argparse.ArgumentParser(description="Put the twelve checks into one report.")
    ap.add_argument("--work", default="search-work")
    ap.add_argument("--gsc-ai", help="the Generative AI performance report export from Search Console")
    ap.add_argument("--rebaseline", action="store_true", help="replace the saved before picture")
    args = ap.parse_args()
    work = Path(args.work)
    checks = [load_check(work / "checks" / f"{cid}.json", cid, title) for cid, title in CHECKS]
    ranked = []
    for c in checks:
        for f in c["findings"]:
            ranked.append({**f, "check": c["check"], "check_title": c["title"]})
    ranked.sort(key=lambda f: (IMPACT[f["impact"]], FIX_TYPES.index(f["fix_type"])))
    for n, f in enumerate(ranked, 1):
        f["id"] = f"F{n}"
    answers = snapshot._read(work / "answers.json")
    write_reports(work, checks, ranked, answers)
    save_json(work / "findings.json", {"made": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"), "findings": ranked,
                                       "checks": [{k: c[k] for k in ("check", "title", "status", "summary")} for c in checks]})
    base = work / "baseline.json"
    if args.rebaseline or not base.is_file():
        snap = snapshot.build(work / "answers.json", work / "raw" / "places.json", work / "raw" / "profile.json", args.gsc_ai, "before")
        save_json(base, snap)
        print(f"Saved the before picture to {base}. The tracker compares against it.")
    else:
        print(f"Kept the before picture already at {base}. Add --rebaseline only to start the comparison over.")
    missing = [c["title"] for c in checks if c.get("problem")]
    print(f"Report: {work / 'search-report.html'} and {work / 'search-report.md'}. {len(ranked)} fixes found across 12 checks.")
    for c in checks:
        print(f"  {c['title']}: {c['status']}" + (f" ({c['problem']})" if c.get("problem") else ""))
    if missing:
        print("Did not run or damaged: " + ", ".join(missing) + ". Run those checks again before you tell the owner the report is complete.")
    return 0


if __name__ == "__main__":
    run_main(main)
