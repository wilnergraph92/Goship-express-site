"""snapshot.py: one dated record of where a business stands, so a later look can be compared like for like.

Used by merge.py (the before picture) and by the search-tracker skill (every after picture).
Standard library only. It reads files the other steps wrote; it calls nothing.
"""
from __future__ import annotations

import csv
import io
import json
import re
import zipfile
from datetime import datetime, timezone
from pathlib import Path


def _read(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8")) if path and Path(path).is_file() else None
    except ValueError:
        return None


def _number(text):
    text = str(text or "").replace(",", "").replace("%", "").strip()
    try:
        return float(text)
    except ValueError:
        return None


def _csv_tables(path):
    """Every CSV inside a Search Console export, whether it is the zip or one file from it."""
    p = Path(path)
    if p.suffix.lower() == ".zip":
        with zipfile.ZipFile(p) as z:
            for name in z.namelist():
                if name.lower().endswith(".csv") and z.getinfo(name).file_size < 20_000_000:
                    yield name, z.read(name).decode("utf-8-sig", "replace")
    else:
        yield p.name, p.read_text(encoding="utf-8-sig", errors="replace")


def load_gsc_ai(path) -> dict:
    """Totals and pages from the Generative AI performance report export in Search Console.

    The report counts how often links to the site were shown in AI Overviews and AI Mode. Its export
    format was not checked against a real download when this was written, so columns are found by name.
    """
    out = {"file": Path(path).name, "total_impressions": None, "days": 0, "first_day": None, "last_day": None, "pages": [],
           "note": "From Search Console's Generative AI performance report: impressions of your links inside AI Overviews and AI Mode."}
    for name, text in _csv_tables(path):
        rows = list(csv.reader(io.StringIO(text)))
        if not rows:
            continue
        head = [h.strip().lower() for h in rows[0]]
        imp = next((i for i, h in enumerate(head) if "impression" in h), None)
        if imp is None:
            continue
        date_col = next((i for i, h in enumerate(head) if h in ("date", "day") or h.startswith("date")), None)
        page_col = next((i for i, h in enumerate(head) if "page" in h or h in ("url", "top pages")), None)
        if date_col is not None:
            days = [(r[date_col], _number(r[imp])) for r in rows[1:] if len(r) > max(date_col, imp) and re.match(r"\d{4}-\d{2}-\d{2}", r[date_col])]
            if days:
                out["total_impressions"] = int(sum(v or 0 for _, v in days))
                out["days"] = len(days)
                out["first_day"], out["last_day"] = min(d for d, _ in days), max(d for d, _ in days)
        elif page_col is not None:
            out["pages"] = [{"page": r[page_col], "impressions": int(_number(r[imp]) or 0)} for r in rows[1:] if len(r) > max(page_col, imp)][:50]
    if out["total_impressions"] is None and out["pages"]:
        out["total_impressions"] = sum(p["impressions"] for p in out["pages"])
        out["note"] += " The total here is the sum of the pages table, which can differ from the chart total."
    return out


def build(answers_path=None, places_path=None, profile_path=None, gsc_ai_path=None, label="before") -> dict:
    snap = {"label": label, "taken_at": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")}
    answers = _read(answers_path)
    if answers:
        per = {}
        for row in answers.get("questions") or []:
            entry = {"own_in_local_pack": row.get("own_in_local_pack"), "organic_rank": row.get("organic_rank")}
            for engine in ("ai_overview", "ai_mode"):
                b = row.get(engine)
                if b is not None:
                    entry[engine] = {k: b.get(k) for k in ("shown", "own_cited", "own_named", "others_cited", "others_named")}
            per[row["q"]] = entry
        snap["answers"] = {k: answers.get(k) for k in ("provider", "engines", "location", "gl", "hl", "device", "domain", "name", "checked_at")}
        snap["answers"]["per_question"] = per
        snap["answers"]["summary"] = answers.get("summary")
    places = _read(places_path)
    if places:
        rows = places.get("places") or []
        you = next((r for r in rows if r.get("who") == "you" and not r.get("error")), None)
        snap["reviews"] = {"source": "Google Places", "checked_at": places.get("checked_at"),
                           "you": {k: you.get(k) for k in ("name", "rating", "reviews_total", "newest_of_shown_reviews")} if you else None,
                           "competitors": [{k: r.get(k) for k in ("name", "rating", "reviews_total", "newest_of_shown_reviews")}
                                           for r in rows if r.get("who") == "competitor" and not r.get("error")]}
    profile = _read(profile_path)
    if profile:
        snap["profile"] = {k: profile.get(k) for k in ("title", "primary_category", "additional_categories", "website", "has_hours",
                                                       "services_listed")}
        snap["profile"]["description_length"] = len(profile.get("description") or "")
        if profile.get("reviews"):
            snap["reviews_from_profile"] = {k: profile["reviews"].get(k) for k in ("total", "average", "newest")}
    if gsc_ai_path:
        snap["search_console_ai"] = load_gsc_ai(gsc_ai_path)
    return snap
