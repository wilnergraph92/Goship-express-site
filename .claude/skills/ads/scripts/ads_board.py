#!/usr/bin/env python3
"""ads_board.py: turn competitors' live Meta ads into a ranked board and a spreadsheet.

    python ads_board.py input --keyword "roof repair" --page https://www.facebook.com/somebrand --country US --max-items 100 --out input.json
    python ads_board.py build --items items.json --out folder [--today 2026-11-04]

items.json is what the Apify run saved, or a list you wrote from what you pasted out of the Ad Library:
    {"advertiser": "...", "started": "Oct 21, 2026", "copy": "...", "headline": "...", "cta": "...",
     "format": "Image", "landing_page": "https://...", "image": "https://...", "library_id": "..."}

Standard library only. Ads are ranked by how many days they have been running. A long run usually
means the ad is making money, because people stop paying for ads that lose money. That is an inference.
Meta does not publish results for these ads.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import html
import json
import re
import sys
import urllib.parse
from datetime import date, datetime, timezone
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

LONG_RUN_DAYS = 90
TESTED_DAYS = 30
INFERENCE = ("Ranked by days running. A long run likely means the ad is profitable, because people stop paying "
             "for ads that lose money. That is an inference, not a fact. Meta does not publish results for these ads.")
LIBRARY = "https://www.facebook.com/ads/library/"
FORMAT_NAMES = {"DCO": "Dynamic", "DPA": "Catalog", "MULTI_IMAGES": "Carousel", "MULTI_VIDEOS": "Carousel"}


def log(msg: str) -> None:
    print(msg, flush=True)


def to_date(value):
    """Accepts epoch seconds or an ISO date."""
    if isinstance(value, (int, float)) and value > 0:
        try:
            return datetime.fromtimestamp(value, tz=timezone.utc).date()
        except (OverflowError, OSError, ValueError):
            return None
    if isinstance(value, str) and value.strip():
        text = value.strip().replace("Started running on", "").strip()
        try:
            return datetime.fromisoformat(text.replace("Z", "+00:00")).date()
        except ValueError:
            pass
        for shape in ("%b %d, %Y", "%B %d, %Y", "%d %b %Y", "%d %B %Y", "%m/%d/%Y"):
            try:
                return datetime.strptime(text, shape).date()
            except ValueError:
                continue
        return None
    return None


def safe_url(value) -> str:
    return value if isinstance(value, str) and re.match(r"https?://", value, re.I) else ""


def first_of(rows, *keys) -> str:
    for row in rows or []:
        if isinstance(row, dict):
            for key in keys:
                if safe_url(row.get(key)):
                    return row[key]
    return ""


def has_template(text: str) -> bool:
    return bool(re.search(r"\{\{.*?\}\}", text or ""))


def format_name(raw, card_count: int) -> str:
    code = str(raw or ("CAROUSEL" if card_count > 1 else "UNKNOWN")).upper()
    return FORMAT_NAMES.get(code, code.replace("_", " ").title())


def from_hand(item: dict) -> dict:
    """Put an ad written from pasted Ad Library text into the same shape as the Apify result."""
    words = f"{item.get('advertiser')}|{item.get('copy')}|{item.get('headline')}"
    video = safe_url(item.get("video"))
    image = safe_url(item.get("image"))
    return {
        "adArchiveID": str(item.get("library_id") or "hand-" + hashlib.sha256(words.encode("utf-8")).hexdigest()[:10]),
        "pageName": item.get("advertiser"), "startDateFormatted": item.get("started"), "isActive": item.get("active", True),
        "snapshot": {"body": {"text": item.get("copy") or ""}, "title": item.get("headline") or "", "ctaText": item.get("cta") or "",
                     "displayFormat": item.get("format"), "linkUrl": item.get("landing_page"),
                     "images": [{"resizedImageUrl": image}] if image else [],
                     "videos": [{"videoHdUrl": video}] if video else []},
    }


def normalize(item: dict, today: date):
    if "advertiser" in item and "snapshot" not in item:
        item = from_hand(item)
    snap = item.get("snapshot") if isinstance(item.get("snapshot"), dict) else {}
    ad_id = str(item.get("adArchiveID") or item.get("adArchiveId") or "").strip()
    start = to_date(item.get("startDateFormatted")) or to_date(item.get("startDate"))
    if not ad_id or not start:
        return None
    active = item.get("isActive")
    cards = snap.get("cards") if isinstance(snap.get("cards"), list) else []
    card = cards[0] if cards and isinstance(cards[0], dict) else {}
    body = snap.get("body")
    copy = (body.get("text") if isinstance(body, dict) else body) or card.get("body") or ""
    images = snap.get("images") or []
    videos = snap.get("videos") or []
    # Dates can be a little in the future for a brand new ad, so never show below zero.
    days = max(0, (today - start).days)
    return {
        "id": ad_id,
        "advertiser": str(item.get("pageName") or snap.get("pageName") or "Unknown"),
        "advertiser_page": safe_url(snap.get("pageProfileUri")),
        "active": bool(active) if active is not None else True,
        "started": start.isoformat(),
        "days_running": days,
        "format": format_name(snap.get("displayFormat"), len(cards)),
        "headline": str(snap.get("title") or card.get("title") or "").strip(),
        "copy": str(copy).strip(),
        "dynamic_copy": has_template(str(copy)),
        "cta": str(snap.get("ctaText") or card.get("ctaText") or "").strip(),
        "image": first_of(images, "resizedImageUrl", "originalImageUrl") or first_of(cards, "resizedImageUrl", "originalImageUrl", "videoPreviewImageUrl") or first_of(videos, "videoPreviewImageUrl"),
        "video": first_of(videos, "videoHdUrl", "videoSdUrl") or first_of(cards, "videoHdUrl", "videoSdUrl"),
        "landing_page": safe_url(snap.get("linkUrl")) or safe_url(card.get("linkUrl")),
        "platforms": [str(p).title() for p in (item.get("publisherPlatform") or []) if p],
        "library_link": LIBRARY if ad_id.startswith("hand-") else f"{LIBRARY}?id={urllib.parse.quote(ad_id)}",
        "group": str(item.get("collationId") or ""),
        "variations": item.get("collationCount") if isinstance(item.get("collationCount"), int) else 1,
    }


def dedupe(ads: list) -> list:
    """One row per ad. Copies of the same creative, in the same group or with the same words, collapse."""
    kept: dict = {}
    for ad in sorted(ads, key=lambda a: -a["days_running"]):
        words = re.sub(r"\W+", " ", (ad["copy"] + " " + ad["headline"]).lower()).strip()
        keys = ["id:" + ad["id"]]
        if ad["group"]:
            keys.append("group:" + ad["group"])
        if words:
            keys.append(f"copy:{ad['advertiser'].lower()}|{words}")
        owner = next((kept[k] for k in keys if k in kept), None)
        if owner is None:
            ad["copies_merged"] = 0
            owner = ad
        else:
            owner["copies_merged"] += 1
            owner["variations"] = max(owner["variations"], ad["variations"])
            for field in ("image", "video", "landing_page", "cta", "headline"):
                if not owner.get(field) and ad.get(field):
                    owner[field] = ad[field]
        for k in keys:
            kept[k] = owner
    unique = {id(v): v for v in kept.values()}
    return list(unique.values())


def tier(days: int) -> str:
    if days >= LONG_RUN_DAYS:
        return "Long Running"
    if days >= TESTED_DAYS:
        return "Past Testing"
    return "New"


def rank(ads: list) -> list:
    ads.sort(key=lambda a: (-a["days_running"], -a["variations"], a["advertiser"].lower(), a["id"]))
    for n, ad in enumerate(ads, 1):
        ad["rank"] = n
        ad["tier"] = tier(ad["days_running"])
    return ads


# ---------------------------------------------------------------- output

CSV_COLUMNS = ["rank", "days_running", "tier", "advertiser", "format", "headline", "copy", "cta", "image", "video",
               "landing_page", "started", "variations", "platforms", "library_link", "id"]


def csv_safe(value) -> str:
    text = ", ".join(map(str, value)) if isinstance(value, list) else ("" if value is None else str(value))
    if text.startswith(("=", "@", "+", "-", "\t", "\r")):
        return "'" + text
    return text


def esc(value) -> str:
    return html.escape(str(value or ""), quote=True)


PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ad Board</title>
<style>
:root{--bg:#f4f4f2;--card:#fff;--ink:#17181a;--soft:#62656b;--line:#dcdcd8;--accent:#b4532a;--chip:#ececE8;--on:#17181a;--onink:#fff}
@media (prefers-color-scheme:dark){:root{--bg:#141517;--card:#1e2023;--ink:#ecedef;--soft:#a2a5ab;--line:#33363a;--accent:#e8895f;--chip:#2a2c30;--on:#ecedef;--onink:#141517}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.45 -apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
header{padding:28px 20px 12px;max-width:1320px;margin:auto}h1{margin:0 0 6px;font-size:26px;letter-spacing:-.02em}
.note{margin:0 0 16px;color:var(--soft);max-width:760px}.stats{display:flex;flex-wrap:wrap;gap:24px;margin:0 0 16px}
.stat b{display:block;font-size:24px;letter-spacing:-.02em}.stat span{color:var(--soft);font-size:13px}
.bar{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-bottom:6px}
input[type=search]{flex:1 1 220px;min-width:0;padding:9px 12px;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--ink);font:inherit}
.chip{border:1px solid var(--line);background:var(--chip);color:var(--ink);border-radius:999px;padding:6px 12px;font:inherit;font-size:13px;cursor:pointer}
.chip[aria-pressed=true]{background:var(--on);color:var(--onink);border-color:var(--on)}
main{max-width:1320px;margin:auto;padding:12px 20px 48px;display:grid;gap:16px;grid-template-columns:repeat(auto-fill,minmax(290px,1fr))}
article{background:var(--card);border:1px solid var(--line);border-radius:12px;overflow:hidden;display:flex;flex-direction:column;min-width:0}
.thumb{aspect-ratio:1/1;background:var(--chip);display:flex;align-items:center;justify-content:center;color:var(--soft);font-size:13px;position:relative}
.thumb img{width:100%;height:100%;object-fit:cover;display:block}
.fmt{position:absolute;left:10px;top:10px;background:rgba(0,0,0,.72);color:#fff;font-size:12px;padding:3px 8px;border-radius:6px}
.body{padding:14px;display:flex;flex-direction:column;gap:8px;flex:1;min-width:0}
.top{display:flex;justify-content:space-between;align-items:baseline;gap:10px}.days{font-size:22px;font-weight:650;letter-spacing:-.02em}.days small{font-size:12px;font-weight:400;color:var(--soft)}
.rank{color:var(--soft);font-size:13px}.tier{font-size:12px;color:var(--soft)}.tier.long{color:var(--accent);font-weight:600}
.who{font-weight:600;overflow-wrap:anywhere}.head{font-weight:600;overflow-wrap:anywhere}
.copy{margin:0;color:var(--ink);white-space:pre-wrap;overflow-wrap:anywhere;max-height:9.5em;overflow:auto}
.meta{margin-top:auto;padding-top:8px;display:flex;flex-wrap:wrap;gap:6px 12px;font-size:13px;color:var(--soft);border-top:1px solid var(--line)}
.cta{font-weight:600;color:var(--ink)}a{color:var(--accent);overflow-wrap:anywhere}
.empty{grid-column:1/-1;color:var(--soft);padding:40px 0;text-align:center}
@media (max-width:480px){header{padding:20px 16px 8px}main{padding:12px 16px 32px;grid-template-columns:1fr}}
</style></head><body>
<header><h1>Ad Board</h1><p class="note">__NOTE__</p>
<div class="stats">__STATS__</div>
<div class="bar"><input type="search" id="q" placeholder="Search The Copy" aria-label="Search the copy"></div>
<div class="bar" id="fmt">__FORMATS__</div><div class="bar" id="who">__ADVERTISERS__</div></header>
<main id="grid">__CARDS__<p class="empty" id="none" hidden>No Ads Match</p></main>
<script>
(function(){var q=document.getElementById('q'),cards=[].slice.call(document.querySelectorAll('article')),none=document.getElementById('none'),f='',w='';
function run(){var s=q.value.toLowerCase(),n=0;cards.forEach(function(c){var ok=(!f||c.dataset.format===f)&&(!w||c.dataset.who===w)&&(!s||c.textContent.toLowerCase().indexOf(s)>-1);c.hidden=!ok;if(ok)n++});none.hidden=n>0}
function wire(id,set){var box=document.getElementById(id);box.addEventListener('click',function(e){var b=e.target.closest('button');if(!b)return;[].forEach.call(box.children,function(x){x.setAttribute('aria-pressed',x===b)});set(b.dataset.v);run()})}
wire('fmt',function(v){f=v});wire('who',function(v){w=v});q.addEventListener('input',run);
document.querySelectorAll('.thumb img').forEach(function(i){i.addEventListener('error',function(){var t=document.createTextNode('Image Link Expired');i.replaceWith(t)})});
})();
</script></body></html>
"""


def chips(values: list, label: str) -> str:
    out = [f'<button class="chip" data-v="" aria-pressed="true">{esc(label)}</button>']
    out += [f'<button class="chip" data-v="{esc(v)}" aria-pressed="false">{esc(v)}</button>' for v in values]
    return "".join(out)


def card(ad: dict) -> str:
    image = f'<img loading="lazy" referrerpolicy="no-referrer" src="{esc(ad["image"])}" alt="">' if ad["image"] else "No Image"
    tier_class = "tier long" if ad["tier"] == "Long Running" else "tier"
    links = []
    if ad["video"]:
        links.append(f'<a href="{esc(ad["video"])}" target="_blank" rel="noopener noreferrer">Video</a>')
    if ad["image"]:
        links.append(f'<a href="{esc(ad["image"])}" target="_blank" rel="noopener noreferrer">Image</a>')
    if ad["landing_page"]:
        links.append(f'<a href="{esc(ad["landing_page"])}" target="_blank" rel="noopener noreferrer">Landing Page</a>')
    links.append(f'<a href="{esc(ad["library_link"])}" target="_blank" rel="noopener noreferrer">Ad Library</a>')
    dynamic = " (Template Copy)" if ad["dynamic_copy"] else ""
    headline = f'<div class="head">{esc(ad["headline"])}</div>' if ad["headline"] else ""
    cta = f'<span class="cta">{esc(ad["cta"])}</span>' if ad["cta"] else ""
    variations = f'<span>{ad["variations"]} Variations</span>' if ad["variations"] > 1 else ""
    return (
        f'<article data-format="{esc(ad["format"])}" data-who="{esc(ad["advertiser"])}">'
        f'<div class="thumb">{image}<span class="fmt">{esc(ad["format"])}{dynamic}</span></div>'
        f'<div class="body"><div class="top"><span class="days">{ad["days_running"]} <small>Days Running</small></span>'
        f'<span class="rank">#{ad["rank"]}</span></div><div class="{tier_class}">{esc(ad["tier"])}</div>'
        f'<div class="who">{esc(ad["advertiser"])}</div>{headline}<p class="copy">{esc(ad["copy"])}</p>'
        f'<div class="meta">{cta}{variations}{"".join(links)}</div></div></article>')


def write_board(ads: list, folder: Path) -> None:
    advertisers = sorted({a["advertiser"] for a in ads}, key=str.lower)
    formats = sorted({a["format"] for a in ads})
    long_run = sum(1 for a in ads if a["tier"] == "Long Running")
    stats = [(len(ads), "Live Ads"), (len(advertisers), "Advertisers"), (long_run, f"{LONG_RUN_DAYS}+ Days"),
             (ads[0]["days_running"] if ads else 0, "Longest Run")]
    page = (PAGE
            .replace("__NOTE__", esc(INFERENCE))
            .replace("__STATS__", "".join(f'<div class="stat"><b>{v}</b><span>{esc(k)}</span></div>' for v, k in stats))
            .replace("__FORMATS__", chips(formats, "All Formats"))
            .replace("__ADVERTISERS__", chips(advertisers, "All Advertisers"))
            .replace("__CARDS__", "".join(card(a) for a in ads)))
    (folder / "ad-board.html").write_text(page, encoding="utf-8")


def cmd_input(a) -> int:
    if not a.keyword and not a.page:
        log("Give me at least one --keyword or one --page.")
        return 2
    urls = []
    for kw in a.keyword or []:
        query = urllib.parse.urlencode({
            "active_status": "active", "ad_type": "all", "country": a.country, "q": kw,
            "search_type": "keyword_unordered", "media_type": "all"})
        urls.append({"url": f"{LIBRARY}?{query}"})
    for page in a.page or []:
        if not safe_url(page):
            log(f"Skipped {page}: a page has to be a full link starting with https://")
            continue
        urls.append({"url": page})
    if not urls:
        log("There is nothing to search.")
        return 2
    payload = {"startUrls": urls, "resultsLimit": max(1, a.max_items // len(urls)), "activeStatus": "active"}
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, indent=1, ensure_ascii=False), encoding="utf-8")
    log(f"Wrote {out}: {len(urls)} searches, up to {payload['resultsLimit']} ads each.")
    return 0


def cmd_build(a) -> int:
    try:
        data = json.loads(Path(a.items).read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as exc:
        log(f"I could not read {a.items}: {exc}")
        return 2
    try:
        today = date.fromisoformat(a.today) if a.today else date.today()
    except ValueError:
        log("--today has to look like 2026-11-04.")
        return 2
    raw = [d for d in (data if isinstance(data, list) else []) if isinstance(d, dict)]
    ads = [x for x in (normalize(d, today) for d in raw) if x]
    bad = len(raw) - len(ads)
    ended = [x for x in ads if not x["active"]]
    ads = [x for x in ads if x["active"]]
    before = len(ads)
    ads = rank(dedupe(ads))
    if not ads:
        log("No live ads in those results, so there is no board. Try other competitors or a broader keyword.")
        return 1
    folder = Path(a.out)
    folder.mkdir(parents=True, exist_ok=True)
    with (folder / "ads.csv").open("w", newline="", encoding="utf-8-sig") as fh:
        w = csv.writer(fh)
        w.writerow(CSV_COLUMNS)
        for ad in ads:
            w.writerow([csv_safe(ad.get(c)) for c in CSV_COLUMNS])
    (folder / "winners.json").write_text(json.dumps(ads, indent=1, ensure_ascii=False), encoding="utf-8")
    write_board(ads, folder)
    log(f"{len(raw)} ads came in. Set aside {len(ended)} that have ended and {bad} with no start date. "
        f"Merged {before - len(ads)} copies. {len(ads)} are on the board.")
    log(f"Longest run: {ads[0]['days_running']} days, {ads[0]['advertiser']}.")
    log(f"Wrote {folder / 'ad-board.html'}, {folder / 'ads.csv'} and {folder / 'winners.json'}.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Rank competitors' live ads by days running.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("input", help="write the input file for the ad library run")
    p.add_argument("--keyword", action="append")
    p.add_argument("--page", action="append", help="a competitor's Facebook page link")
    p.add_argument("--country", default="US")
    p.add_argument("--max-items", type=int, default=100)
    p.add_argument("--out", required=True)
    p = sub.add_parser("build", help="write the board and the spreadsheet")
    p.add_argument("--items", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--today")
    a = ap.parse_args()
    try:
        return cmd_input(a) if a.cmd == "input" else cmd_build(a)
    except Exception as exc:  # a stranger should never see a stack trace
        log(f"Something went wrong: {exc}. Tell me what you were doing and I will look.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
