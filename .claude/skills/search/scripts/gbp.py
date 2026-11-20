#!/usr/bin/env python3
"""gbp.py: the owner's own Google Business Profile, read through Google's Business Profile APIs.

Standard library only. It signs in through the owner's own Google Cloud project, in their browser.

    python gbp.py auth                 sign in once; the sign in is kept on this computer
    python gbp.py check                lists the profiles this sign in can manage; changes nothing
    python gbp.py read --location locations/123 [--account accounts/456] --out search-work/raw/profile.json

Google lets a project use these APIs only after it approves an access request, and only for a
profile verified for 60 days or more. Until then every call comes back refused, and the skill
uses the by-hand checklist instead. Changing the profile lives in the search-fixer skill and needs
the owner's own approval of the exact change, because a profile change shows to customers.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import http.server
import json
import os
import secrets
import stat
import sys
import threading
import urllib.parse
import webbrowser
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from searchlib import KEYS_FILE, ServiceError, api_base, die, http_json, post_form, read_keys, run_main, save_json  # noqa: E402

AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = api_base("GOOGLE_TOKEN_URL", "https://oauth2.googleapis.com/token")
_TEST = api_base("GOOGLE_API_BASE_URL", "")
ACCOUNTS = _TEST or "https://mybusinessaccountmanagement.googleapis.com"
INFO = _TEST or "https://mybusinessbusinessinformation.googleapis.com"
V4 = _TEST or "https://mybusiness.googleapis.com"
SCOPE = "https://www.googleapis.com/auth/business.manage"
TOKEN_FILE = KEYS_FILE.parent / "search-google-token.json"
READ_MASK = "name,title,categories,profile,regularHours,websiteUri,phoneNumbers,storefrontAddress,serviceArea,serviceItems,metadata,openInfo"
# What the fixer may change through the API. Anything else is pasted by hand with clicks.
EDITABLE = {"profile.description": 750, "websiteUri": 2000, "regularHours": 0}
NOT_APPROVED = ("Google has not approved this Google Cloud project for the Business Profile APIs yet, or this sign in cannot manage "
                "that profile. Google approves a project through its access form, usually only for a profile verified 60 days or more. "
                "Until then, use the by-hand checklist: nothing is lost except speed. The form is in references/google-sign-in.md")


class ProfileError(Exception):
    pass


def client() -> tuple:
    keys = read_keys()
    cid, secret = keys.get("GOOGLE_CLIENT_ID"), keys.get("GOOGLE_CLIENT_SECRET")
    if not cid:
        die(f"The Google sign in is not set up. It is optional: the by-hand checklist needs no setup. To use it, follow "
            f"references/google-sign-in.md and put GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET in {KEYS_FILE} in a text editor. "
            "Do not paste them into this chat.", 3)
    return cid, secret


def save_token(token: dict) -> None:
    TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    TOKEN_FILE.write_text(json.dumps(token), encoding="utf-8")
    try:
        os.chmod(TOKEN_FILE, stat.S_IRUSR | stat.S_IWUSR)
    except OSError:
        pass


def cmd_auth(args, open_browser=webbrowser.open, wait_seconds=300) -> int:
    cid, secret = client()
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

        def log_message(self, *a):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Catch)
    server.timeout = 1
    redirect = f"http://127.0.0.1:{server.server_address[1]}"
    url = AUTH_URL + "?" + urllib.parse.urlencode({
        "client_id": cid, "redirect_uri": redirect, "response_type": "code", "scope": SCOPE, "access_type": "offline",
        "prompt": "consent", "state": state, "code_challenge": challenge, "code_challenge_method": "S256"})
    print("Opening your browser to sign in to Google. It asks to manage your Business Profile, which is what lets an approved "
          "change go through. Nothing is changed by signing in.", flush=True)
    print("If no window opens, copy this into your browser:", url, flush=True)
    threading.Thread(target=open_browser, args=(url,), daemon=True).start()
    for _ in range(wait_seconds):
        server.handle_request()
        if got:
            break
    server.server_close()
    if not got or got.get("error") or not got.get("code"):
        die("The sign in did not finish, so nothing was saved. Run gbp.py auth again. If Google says the app is blocked, add your "
            "own Google address as a test user or publish the app; see references/google-sign-in.md.")
    fields = {"client_id": cid, "code": got["code"], "code_verifier": verifier, "grant_type": "authorization_code", "redirect_uri": redirect}
    if secret:
        fields["client_secret"] = secret
    status, token = post_form(TOKEN_URL, fields)
    if status != 200 or not token.get("refresh_token"):
        die("Google did not give a lasting sign in. Run gbp.py auth again.")
    save_token({"refresh_token": token["refresh_token"], "scope": token.get("scope", SCOPE)})
    print(f"Signed in. The sign in is saved at {TOKEN_FILE}. If your Google Cloud app is still in Testing, it ends in 7 days; "
          "publishing the app stops that.")
    return 0


def access_token() -> str:
    cid, secret = client()
    try:
        saved = json.loads(TOKEN_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise ProfileError("you have not signed in yet. Run gbp.py auth") from None
    fields = {"client_id": cid, "refresh_token": saved.get("refresh_token", ""), "grant_type": "refresh_token"}
    if secret:
        fields["client_secret"] = secret
    status, data = post_form(TOKEN_URL, fields)
    if status != 200 or not data.get("access_token"):
        raise ProfileError("Google ended the sign in. If your Google Cloud app is in Testing, that happens after 7 days. Run gbp.py auth again")
    return data["access_token"]


def call(token, method, url, body=None):
    status, data = http_json(method, url, {"Authorization": f"Bearer {token}"}, body, service="Google Business Profile")
    if status in (403, 429):
        raise ProfileError(NOT_APPROVED)
    if status == 401:
        raise ProfileError("Google refused the sign in. Run gbp.py auth again")
    if status == 404:
        raise ProfileError("Google could not find that profile. Run gbp.py check to see the profiles this sign in manages")
    if status != 200:
        msg = ((data or {}).get("error") or {}).get("message", "") if isinstance(data, dict) else ""
        raise ProfileError(f"Google answered with status {status}. {msg[:200]}".strip())
    return data or {}


def list_profiles(token) -> list:
    out = []
    for acct in call(token, "GET", f"{ACCOUNTS}/v1/accounts").get("accounts", [])[:10]:
        q = urllib.parse.urlencode({"readMask": "name,title,storefrontAddress", "pageSize": 100})
        for loc in call(token, "GET", f"{INFO}/v1/{acct['name']}/locations?{q}").get("locations", []):
            addr = loc.get("storefrontAddress") or {}
            out.append({"account": acct["name"], "location": loc.get("name"), "title": loc.get("title"),
                        "town": addr.get("locality") or ""})
    return out


def read_location(token, location) -> dict:
    q = urllib.parse.urlencode({"readMask": READ_MASK})
    return call(token, "GET", f"{INFO}/v1/{location}?{q}")


def field_value(loc: dict, field: str):
    node = loc
    for part in field.split("."):
        node = (node or {}).get(part) if isinstance(node, dict) else None
    return node


def patch_location(token, location, field, value, validate_only=False) -> dict:
    """Change one field. Google is asked to check it first, then to make it."""
    if field not in EDITABLE:
        raise ProfileError(f"{field} is not one I change through the API. Give the owner the clicks instead")
    body = {}
    node = body
    parts = field.split(".")
    for part in parts[:-1]:
        node = node.setdefault(part, {})
    node[parts[-1]] = value
    q = urllib.parse.urlencode({"updateMask": field, **({"validateOnly": "true"} if validate_only else {})})
    return call(token, "PATCH", f"{INFO}/v1/{location}?{q}", body)


def reviews_summary(token, account, location) -> dict:
    loc_id = location.split("/")[-1]
    data = call(token, "GET", f"{V4}/v4/{account}/locations/{loc_id}/reviews?pageSize=50")
    dates = sorted((r.get("createTime") or "")[:10] for r in data.get("reviews", []) if r.get("createTime"))
    replied = sum(1 for r in data.get("reviews", []) if r.get("reviewReply"))
    return {"total": data.get("totalReviewCount"), "average": data.get("averageRating"), "newest": dates[-1] if dates else None,
            "last_50_dates": dates[-50:], "replied_of_last_50": replied}


def cmd_check(args) -> int:
    try:
        token = access_token()
        rows = list_profiles(token)
    except (ProfileError, ServiceError) as err:
        print(f"Not working yet: {err}.")
        return 1
    if not rows:
        print("Signed in, but this Google account manages no Business Profiles. Sign in with the account that owns the profile.")
        return 1
    print("Works. This sign in manages these profiles. Nothing was changed:")
    for r in rows:
        print(f"  {r['title']} ({r['town'] or 'no storefront address'}): --location {r['location']} --account {r['account']}")
    return 0


def cmd_read(args) -> int:
    try:
        token = access_token()
        loc = read_location(token, args.location)
        reviews = reviews_summary(token, args.account, args.location) if args.account else None
    except (ProfileError, ServiceError) as err:
        print(f"Not read: {err}.")
        return 1
    cats = loc.get("categories") or {}
    facts = {"title": loc.get("title"), "primary_category": (cats.get("primaryCategory") or {}).get("displayName"),
             "additional_categories": [c.get("displayName") for c in cats.get("additionalCategories") or []],
             "description": (loc.get("profile") or {}).get("description") or "", "website": loc.get("websiteUri") or "",
             "has_hours": bool(loc.get("regularHours")), "regularHours": loc.get("regularHours"),
             "phone": (loc.get("phoneNumbers") or {}).get("primaryPhone") or "",
             "services_listed": len(loc.get("serviceItems") or []), "service_area": bool(loc.get("serviceArea")),
             "maps_link": (loc.get("metadata") or {}).get("mapsUri") or "", "reviews": reviews}
    save_json(args.out, facts)
    print(f"{facts['title']}: category {facts['primary_category']}, {len(facts['additional_categories'])} more, description "
          f"{len(facts['description'])} of 750 characters, website {'set' if facts['website'] else 'MISSING'}, hours "
          f"{'set' if facts['has_hours'] else 'MISSING'}, {facts['services_listed']} services listed."
          + (f" Reviews: {reviews['total']}, average {reviews['average']}, newest {reviews['newest']}." if reviews else ""))
    print(f"Saved to {args.out}")
    return 0


def main():
    ap = argparse.ArgumentParser(description="Your Google Business Profile.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("auth")
    sub.add_parser("check")
    one = sub.add_parser("read")
    one.add_argument("--location", required=True)
    one.add_argument("--account", help="needed for the review numbers")
    one.add_argument("--out", default="search-work/raw/profile.json")
    args = ap.parse_args()
    return {"auth": cmd_auth, "check": cmd_check, "read": cmd_read}[args.cmd](args)


if __name__ == "__main__":
    run_main(main)
