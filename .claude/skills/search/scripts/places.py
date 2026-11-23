#!/usr/bin/env python3
"""places.py: review numbers and profile basics for a business and its competitors, from Google's Places API.

On the owner's own Google Cloud key. Standard library only. Only reads.

    python places.py check
    python places.py lookup --business "Business Name, City, State" [--competitor "Rival Name, City, State" ...]
                            --confirm --out search-work/raw/places.json

Each lookup is one Places Text Search with the review fields, which Google bills as Text Search
Enterprise + Atmosphere: the first 1,000 a month are free, then $40 per 1,000 (checked November
2026 on developers.google.com/maps/billing-and-pricing/pricing). This script stops at the monthly
count in PLACES_MAX_CALLS, 900 if that line is missing, so it stays inside the free amount unless
the owner raises it. Google returns at most 5 reviews per place, picked by relevance, not the newest.
"""
from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from searchlib import (KEYS_FILE, ServiceError, add_used, api_base, die, http_json, month_used, read_ceiling,  # noqa: E402
                       read_keys, run_main, save_json)

BASE = api_base("PLACES_BASE_URL", "https://places.googleapis.com")
FIELDS = ",".join(f"places.{f}" for f in ("id", "displayName", "formattedAddress", "rating", "userRatingCount", "reviews", "websiteUri",
                                          "regularOpeningHours", "primaryTypeDisplayName", "nationalPhoneNumber", "googleMapsUri",
                                          "businessStatus"))
FREE_MONTH = 900  # under Google's 1,000 free a month for this billing group, so a slip never costs money
MAX_LOOKUPS = 12


def key_or_stop() -> str:
    key = read_keys().get("GOOGLE_PLACES_KEY")
    if not key:
        die(f"The Places key is not set up. Put GOOGLE_PLACES_KEY in {KEYS_FILE} in a text editor. Do not paste it into this chat. "
            "The steps are in references/places-setup.md.", 3)
    return key


def search(key, text, mask) -> tuple:
    status, data = http_json("POST", f"{BASE}/v1/places:searchText", {"X-Goog-Api-Key": key, "X-Goog-FieldMask": mask},
                             {"textQuery": text, "pageSize": 1}, service="Google Places")
    if status == 200:
        return (data or {}).get("places") or [], ""
    err = ((data or {}).get("error") or {}) if isinstance(data, dict) else {}
    message = str(err.get("message") or "")
    if status == 403 and "billing" in message.lower():
        return [], "Google says billing is not turned on for this key's project. Turn on billing in Google Cloud; the free monthly amount still applies"
    if status in (400, 403) and ("api key" in message.lower() or "not valid" in message.lower() or "disabled" in message.lower() or "not been used" in message.lower()):
        return [], "Google refused this key. Check it is the Places key and that Places API (New) is turned on for its project"
    return [], f"Google Places answered with status {status}. {message[:160]}".strip()


def cmd_check(args) -> int:
    key = key_or_stop()
    try:
        # An ids-only search is free and unlimited at Google, so this proves the key at no cost.
        rows, problem = search(key, "coffee", "places.id")
    except ServiceError as err:
        print(f"{err}.")
        return 1
    if problem:
        print(problem + ".")
        return 1
    print("The Places key works. That check was free.")
    return 0


def summarize(place) -> dict:
    reviews = place.get("reviews") or []
    dates = sorted(r.get("publishTime", "")[:10] for r in reviews if r.get("publishTime"))
    return {"name": (place.get("displayName") or {}).get("text") or "", "address": place.get("formattedAddress") or "",
            "rating": place.get("rating"), "reviews_total": place.get("userRatingCount") or 0,
            "newest_of_shown_reviews": dates[-1] if dates else None, "shown_reviews": len(reviews),
            "review_snippets": [((r.get("text") or {}).get("text") or "")[:200] for r in reviews][:5],
            "website": place.get("websiteUri") or "", "phone": place.get("nationalPhoneNumber") or "",
            "has_hours": bool(place.get("regularOpeningHours")), "category": (place.get("primaryTypeDisplayName") or {}).get("text") or "",
            "maps_link": place.get("googleMapsUri") or "", "status": place.get("businessStatus") or ""}


def cmd_lookup(args) -> int:
    key = key_or_stop()
    targets = [("you", args.business)] + [("competitor", c) for c in (args.competitor or [])]
    if len(targets) > MAX_LOOKUPS:
        die(f"That is {len(targets)} lookups. Keep it to {MAX_LOOKUPS}: you and your closest competitors.", 2)
    ceiling = read_ceiling(read_keys(), "PLACES_MAX_CALLS", default=FREE_MONTH)
    if ceiling is None:
        die("Refused: PLACES_MAX_CALLS in your key file is not a number. Nothing was looked up.", 2)
    already = month_used("places")
    print(f"This makes {len(targets)} Places lookups. {int(already)} used this month on this computer, ceiling {int(ceiling)}. "
          "Google gives 1,000 of these a month free, then charges $40 per 1,000.")
    if already + len(targets) > ceiling:
        die(f"Refused: this would pass your monthly ceiling of {int(ceiling)} lookups. Nothing was looked up. Only the owner changes PLACES_MAX_CALLS.", 2)
    if not args.confirm:
        print("Not started: run it again with --confirm once the owner has said yes.")
        return 4
    rows = []
    for who, text in targets:
        try:
            found, problem = search(key, text, FIELDS)
        except ServiceError as err:
            found, problem = [], str(err)
        add_used("places", 1)
        if problem:
            rows.append({"who": who, "searched": text, "error": problem})
            print(f"  {text}: {problem}.")
            if "refused this key" in problem or "billing" in problem:
                break
            continue
        if not found:
            rows.append({"who": who, "searched": text, "error": "Google found no place by that name. Try the exact name on the Google listing, with the town"})
            print(f"  {text}: not found.")
            continue
        row = {"who": who, "searched": text, **summarize(found[0])}
        rows.append(row)
        print(f"  {row['name']}: {row['reviews_total']} reviews, rating {row['rating']}, newest of the reviews Google shows: {row['newest_of_shown_reviews'] or 'none'}.")
    save_json(args.out, {"checked_at": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"), "places": rows,
                         "note": "Google returns at most 5 reviews per place, picked by relevance, so the newest date shown is a floor, not the true newest."})
    print(f"Saved to {args.out}")
    return 0


def main():
    ap = argparse.ArgumentParser(description="Review numbers for you and your competitors.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check")
    one = sub.add_parser("lookup")
    one.add_argument("--business", required=True, help="your business name and town, as on Google")
    one.add_argument("--competitor", action="append", help="a competitor's name and town; repeat for more")
    one.add_argument("--confirm", action="store_true")
    one.add_argument("--out", default="search-work/raw/places.json")
    args = ap.parse_args()
    return {"check": cmd_check, "lookup": cmd_lookup}[args.cmd](args)


if __name__ == "__main__":
    run_main(main)
