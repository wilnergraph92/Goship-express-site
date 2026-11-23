#!/usr/bin/env python3
"""gsc.py: bring in Google Search Console data, the owner's own numbers. Standard library only.

The default route needs no setup: the owner downloads the export from the Search Console site.

    python gsc.py load <export.zip | folder | Queries.csv Pages.csv ...> --out seo-work/gsc.json [--months 3]

The optional route uses the owner's own Google Cloud login (see references/google-sign-in.md).
It adds which search goes to which page, and more rows.

    python gsc.py auth
    python gsc.py sites
    python gsc.py pull --site https://example.com/ --out seo-work/gsc.json [--days 90] [--max-rows 25000]
"""
from __future__ import annotations

import argparse
import base64
import csv
import hashlib
import http.server
import io
import json
import os
import re
import secrets
import stat
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
import zipfile
from datetime import date, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from seolib import KEYS_FILE, die, read_keys, run_main, save_json  # noqa: E402

AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = "https://oauth2.googleapis.com/token"
API_BASE = "https://www.googleapis.com/webmasters/v3"
SCOPE = "https://www.googleapis.com/auth/webmasters.readonly"
UI_ROW_CAP = 1000
API_PAGE_SIZE = 25000
API_DAILY_CAP = 50000


def token_file() -> Path:
    """The saved sign in sits beside the key file."""
    return KEYS_FILE.parent / "seo-search-console-token.json"


TESTING_TRAP = (
    "Google refused the saved sign in. The usual cause: your Google Cloud app is still in Testing status, and Google "
    "ends those sign ins 7 days after you give them. Fix it for good: in Google Cloud open Google Auth Platform, then "
    "Audience, and click Publish app. Then run the sign in again with: gsc.py auth"
)


# ------------------------------------------------------------------ the CSV route


def _number(text) -> float:
    text = str(text or "").strip().replace("%", "").replace(" ", "").replace(" ", "")
    if not text or text in ("~", "-"):
        return 0.0
    if "," in text and "." in text:
        text = text.replace(",", "")
    elif "," in text:
        # "1,204" is a thousand separator, "3,5" is a decimal comma
        text = text.replace(",", "") if re.fullmatch(r"\d{1,3}(,\d{3})+", text) else text.replace(",", ".")
    try:
        return float(text)
    except ValueError:
        return 0.0


def _read_rows(text: str):
    text = text.lstrip("﻿")
    first = text.split("\n", 1)[0]
    delimiter = ";" if first.count(";") > first.count(",") else ("\t" if "\t" in first else ",")
    return [row for row in csv.reader(io.StringIO(text), delimiter=delimiter) if any(c.strip() for c in row)]


def _columns(header):
    """Find the metric columns by name, or by position if the export is in another language."""
    lowered = [c.strip().lower() for c in header]

    def find(word):
        for i, name in enumerate(lowered):
            if word in name:
                return i
        return None
    found = {"clicks": find("click"), "impressions": find("impression"), "ctr": find("ctr"), "position": find("position")}
    if None in found.values():
        found = {"clicks": 1, "impressions": 2, "ctr": 3, "position": 4}
    return found


def _classify(name: str, rows) -> str:
    base = Path(name).stem.lower()
    head = rows[0][0].strip().lower() if rows and rows[0] else ""
    if "quer" in base or "quer" in head:
        return "queries"
    if base.startswith("page") or head in ("top pages", "page", "pages"):
        return "pages"
    if "filter" in base or head == "filter":
        return "filters"
    if base.startswith("date") or head == "date":
        return "dates"
    if base.startswith(("countr", "device", "search appearance", "chart")):
        return "other"
    if len(rows) > 1 and rows[1][0].strip().lower().startswith("http"):
        return "pages"
    if len(rows) > 1 and re.fullmatch(r"\d{4}-\d{2}-\d{2}", rows[1][0].strip()):
        return "dates"
    if len(rows) > 1 and len(rows[0]) >= 5:
        return "queries"
    return "other"


def _metric_rows(rows, label):
    if not rows:
        return []
    cols = _columns(rows[0])
    out = []
    for row in rows[1:]:
        try:
            key = row[0].strip()
            if not key:
                continue
            ctr = _number(row[cols["ctr"]]) if cols["ctr"] < len(row) else 0.0
            out.append({label: key, "clicks": _number(row[cols["clicks"]]),
                        "impressions": _number(row[cols["impressions"]]),
                        "ctr": round(ctr / 100, 5), "position": _number(row[cols["position"]])})
        except IndexError:
            continue
    return out


def _months_from_filters(rows):
    """Search Console notes the date range in Filters.csv, for example 'Last 3 months'."""
    for row in rows:
        joined = " ".join(row).lower()
        if "date" not in joined and "last" not in joined:
            continue
        match = re.search(r"(\d+)\s*month", joined)
        if match:
            return float(match.group(1)), joined
        match = re.search(r"(\d+)\s*day", joined)
        if match:
            return round(float(match.group(1)) / 30.4, 2), joined
    return None, ""


def _collect_files(paths):
    files = []
    for raw in paths:
        path = Path(raw).expanduser()
        if not path.exists():
            print(f"I could not find {path}, so I skipped it.")
        elif path.is_dir():
            for child in sorted(path.iterdir()):
                if child.suffix.lower() in (".csv", ".zip"):
                    files.extend(_collect_files([child]))
        elif path.suffix.lower() == ".zip":
            try:
                with zipfile.ZipFile(path) as bundle:
                    for name in bundle.namelist():
                        if name.lower().endswith(".csv"):
                            files.append((name, bundle.read(name).decode("utf-8-sig", errors="replace")))
            except zipfile.BadZipFile:
                print(f"{path.name} is not a working zip file, so I skipped it. Download it again from Search Console.")
        elif path.suffix.lower() == ".csv":
            files.append((path.name, path.read_text(encoding="utf-8-sig", errors="replace")))
        else:
            print(f"{path.name} is not a CSV or zip. If you chose Google Sheets or Excel in the export menu, choose "
                  "Download CSV instead.")
    return files


def load_csv(paths, months=None) -> dict:
    files = _collect_files(paths)
    parts = {}
    for name, text in files:
        rows = _read_rows(text)
        kind = _classify(name, rows)
        if kind not in parts:
            parts[kind] = rows
    if "queries" not in parts and "pages" not in parts:
        die("I found no list of searches or pages in those files. In Search Console open Performance, then Search "
            "results, click Export at the top right, choose Download CSV, and give me the zip file it downloads.")
    queries = _metric_rows(parts.get("queries"), "query")
    pages = _metric_rows(parts.get("pages"), "page")
    found_months, date_text = _months_from_filters(parts.get("filters", []))
    months_used = months or found_months or 3.0
    assumed = not months and not found_months
    daily = _metric_rows(parts.get("dates"), "date")
    totals = None
    if daily:
        totals = {"clicks": sum(r["clicks"] for r in daily), "impressions": sum(r["impressions"] for r in daily)}
    data = {
        "source": "search console export", "months": months_used, "months_assumed": assumed, "date_note": date_text,
        "queries": sorted(queries, key=lambda r: -r["impressions"]), "pages": sorted(pages, key=lambda r: -r["impressions"]),
        "query_pages": [], "totals": totals,
        "queries_capped": len(queries) >= UI_ROW_CAP, "pages_capped": len(pages) >= UI_ROW_CAP, "row_cap": UI_ROW_CAP,
    }
    return data


# ------------------------------------------------------------------ the optional Google sign in route


def _client():
    keys = read_keys()
    client_id, client_secret = keys.get("GSC_CLIENT_ID"), keys.get("GSC_CLIENT_SECRET")
    if not client_id:
        die(f"The Search Console sign in is not set up. This route is optional: the CSV export needs no setup. To use "
            f"it, follow references/google-sign-in.md and put GSC_CLIENT_ID and GSC_CLIENT_SECRET in {KEYS_FILE} "
            "in a text editor. Do not paste them into this chat.")
    return client_id, client_secret


def _post_form(url, fields):
    body = urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _save_token(token: dict) -> None:
    path = token_file()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(token), encoding="utf-8")
    try:
        os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
    except OSError:
        pass


def auth(open_browser=webbrowser.open, wait_seconds=300) -> int:
    """Sign in through the browser on this computer, read only, and keep the refresh token here."""
    client_id, client_secret = _client()
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)
    got = {}

    class Catch(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            if query.get("state", [""])[0] == state:
                got["code"] = query.get("code", [""])[0]
                got["error"] = query.get("error", [""])[0]
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"Done. You can close this tab and go back to Claude.")

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Catch)
    server.timeout = 1
    redirect = f"http://127.0.0.1:{server.server_address[1]}"
    url = AUTH_URL + "?" + urllib.parse.urlencode({
        "client_id": client_id, "redirect_uri": redirect, "response_type": "code", "scope": SCOPE,
        "access_type": "offline", "prompt": "consent", "state": state,
        "code_challenge": challenge, "code_challenge_method": "S256",
    })
    print("Opening your browser to sign in to Google. This asks for read only access to Search Console.", flush=True)
    print("If no window opens, copy this into your browser:", url, flush=True)
    opener = threading.Thread(target=open_browser, args=(url,), daemon=True)
    opener.start()
    for _ in range(wait_seconds):
        server.handle_request()
        if got:
            break
    server.server_close()
    if not got or got.get("error") or not got.get("code"):
        die("The sign in did not finish, so nothing was saved. Run gsc.py auth again. If Google says the app is "
            "blocked, add your own Google address as a test user or publish the app; see "
            "references/google-sign-in.md.")
    fields = {"client_id": client_id, "code": got["code"], "code_verifier": verifier,
              "grant_type": "authorization_code", "redirect_uri": redirect}
    if client_secret:
        fields["client_secret"] = client_secret
    token = _post_form(TOKEN_URL, fields)
    if not token.get("refresh_token"):
        die("Google did not give a lasting sign in. Run gsc.py auth again.")
    _save_token({"refresh_token": token["refresh_token"], "scope": token.get("scope", SCOPE)})
    print(f"Signed in. The sign in is saved at {token_file()}.")
    print("Reminder: if your Google Cloud app is still in Testing status, this sign in ends in 7 days. Publishing the "
          "app stops that. The setup guide shows how.")
    return 0


def _access_token() -> str:
    client_id, client_secret = _client()
    try:
        saved = json.loads(token_file().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        die("You have not signed in yet. Run: gsc.py auth")
    fields = {"client_id": client_id, "refresh_token": saved.get("refresh_token", ""), "grant_type": "refresh_token"}
    if client_secret:
        fields["client_secret"] = client_secret
    try:
        return _post_form(TOKEN_URL, fields)["access_token"]
    except urllib.error.HTTPError as err:
        if err.code in (400, 401):
            die(TESTING_TRAP)
        die(f"Google's sign in service answered with status {err.code}. Try again in a few minutes.")
    except urllib.error.URLError as err:
        die(f"I could not reach Google ({err.reason}). Check your connection and try again.")


def _api(token, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API_BASE + path, data=data, headers={"Authorization": f"Bearer {token}",
                                                                      "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        if err.code == 403:
            die("Google says this account cannot see that Search Console site, or the Search Console API is not turned "
                "on in your Google Cloud project. Run gsc.py sites to see what you can reach. The setup guide shows "
                "how to turn the API on.")
        if err.code == 401:
            die(TESTING_TRAP)
        if err.code == 429:
            die("Google says too many requests right now. Wait a few minutes and run this again.")
        die(f"Search Console answered with status {err.code}. Check the site address with gsc.py sites and try again.")
    except urllib.error.URLError as err:
        die(f"I could not reach Search Console ({err.reason}). Check your connection and try again.")


def list_sites() -> list:
    token = _access_token()
    return [s.get("siteUrl") for s in _api(token, "/sites").get("siteEntry", [])]


def _rows(token, site, dims, start, end, max_rows):
    path = f"/sites/{urllib.parse.quote(site, safe='')}/searchAnalytics/query"
    rows, offset = [], 0
    while offset < max_rows:
        size = min(API_PAGE_SIZE, max_rows - offset)
        body = {"startDate": start, "endDate": end, "dimensions": dims, "type": "web", "rowLimit": size, "startRow": offset}
        got = _api(token, path, body).get("rows", [])
        rows.extend(got)
        if len(got) < size:
            break
        offset += size
    return rows


def pull(site, days=90, max_rows=API_PAGE_SIZE) -> dict:
    max_rows = min(max_rows, API_DAILY_CAP)
    token = _access_token()
    end = date.today() - timedelta(days=3)
    start = end - timedelta(days=days - 1)
    span = (start.isoformat(), end.isoformat())

    def flat(row, *names):
        out = dict(zip(names, row.get("keys", [])))
        out.update(clicks=row.get("clicks", 0), impressions=row.get("impressions", 0),
                   ctr=round(row.get("ctr", 0), 5), position=row.get("position", 0))
        return out
    queries = [flat(r, "query") for r in _rows(token, site, ["query"], *span, max_rows)]
    pages = [flat(r, "page") for r in _rows(token, site, ["page"], *span, max_rows)]
    pairs = [flat(r, "query", "page") for r in _rows(token, site, ["query", "page"], *span, max_rows)]
    whole = _rows(token, site, [], *span, 1)
    totals = {"clicks": whole[0].get("clicks", 0), "impressions": whole[0].get("impressions", 0)} if whole else None
    return {
        "source": "search console api", "months": round(days / 30.4, 2), "months_assumed": False,
        "date_note": f"{span[0]} to {span[1]}",
        "queries": sorted(queries, key=lambda r: -r["impressions"]), "pages": sorted(pages, key=lambda r: -r["impressions"]),
        "query_pages": pairs, "totals": totals,
        "queries_capped": len(queries) >= max_rows, "pages_capped": len(pages) >= max_rows, "row_cap": max_rows,
    }


def summary(data: dict) -> str:
    return (f"{len(data['queries'])} searches and {len(data['pages'])} pages, about {data['months']:g} month(s) of data"
            + (" (I assumed 3 months because the export did not say)" if data.get("months_assumed") else "") + ".")


def main():
    ap = argparse.ArgumentParser(description="Bring in Search Console data.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    load = sub.add_parser("load")
    load.add_argument("files", nargs="+")
    load.add_argument("--out", default="seo-work/gsc.json")
    load.add_argument("--months", type=float)
    sub.add_parser("auth")
    sub.add_parser("sites")
    get = sub.add_parser("pull")
    get.add_argument("--site", required=True)
    get.add_argument("--out", default="seo-work/gsc.json")
    get.add_argument("--days", type=int, default=90)
    get.add_argument("--max-rows", type=int, default=API_PAGE_SIZE)
    args = ap.parse_args()
    if args.cmd == "load":
        data = load_csv(args.files, args.months)
    elif args.cmd == "auth":
        return auth()
    elif args.cmd == "sites":
        for site in list_sites() or ["(no sites on this Google account)"]:
            print(site)
        return 0
    else:
        data = pull(args.site, args.days, args.max_rows)
    save_json(args.out, data)
    print(f"Loaded {summary(data)} Saved to {args.out}")
    if data["queries_capped"] or data["pages_capped"]:
        print(f"Search Console stopped at {data['row_cap']:,} rows, so the smaller searches past that are not here.")
    return 0


if __name__ == "__main__":
    run_main(main)
