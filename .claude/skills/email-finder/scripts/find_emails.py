#!/usr/bin/env python3
"""find_emails.py: find a business email each lead published themselves, and say how sure it is.

    python find_emails.py run --people people.json --profiles profiles.json --out emails.json [--min-fit 0]
    python find_emails.py apify-input --emails emails.json --out contacts-input.json
    python find_emails.py merge-apify --items contacts.json --emails emails.json

Standard library only. Reading websites costs nothing. It obeys robots.txt, pauses between sites,
reads only public web sites (never a social media site, and never this computer or a private network),
and never guesses an address. A blank is the right answer when nothing is published.

Confidence:
  high    written in their own profile bio, or a named address on the website their profile links to
  medium  a general inbox (info@, hello@) or a free mail address on that website, or an address they
          wrote in one of their own posts or comments
  low     found on that website but on a different domain, so often someone else's. Not used for sending
          until the owner checks it and changes the confidence to checked.
"""
from __future__ import annotations

import argparse
import http.client
import ipaddress
import json
import os
import re
import socket
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import urllib.robotparser
from html.parser import HTMLParser
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

UA = "Mozilla/5.0 (compatible; lead-finder-skill; reads public contact pages)"
MAX_BYTES = 1_500_000
# Social sites are never read directly: they sit behind logins and their terms forbid it.
SOCIAL_HOSTS = {"facebook.com", "instagram.com", "linkedin.com", "twitter.com", "x.com", "youtube.com", "youtu.be",
                "tiktok.com", "threads.net", "pinterest.com", "fb.com", "wa.me", "whatsapp.com", "t.me", "snapchat.com"}
# Link-in-bio pages: read once for the links on them, then the owner's own site is read.
LINK_IN_BIO = {"linktr.ee", "beacons.ai", "linkin.bio", "stan.store", "bio.link", "lnk.bio", "campsite.bio",
               "taplink.cc", "hoo.be", "solo.to", "msha.ke", "carrd.co"}
SHOP_HOSTS = {"etsy.com", "amazon.com", "ebay.com", "calendly.com", "square.site", "gofundme.com", "patreon.com"}
FREE_MAIL = {"gmail.com", "yahoo.com", "hotmail.com", "outlook.com", "aol.com", "icloud.com", "proton.me",
             "protonmail.com", "live.com", "msn.com", "comcast.net", "me.com"}
JUNK_LOCAL = {"abuse", "admin", "administrator", "billing", "careers", "compliance", "dmca", "donotreply", "do-not-reply",
              "hostmaster", "hr", "jobs", "legal", "mailer-daemon", "no-reply", "noreply", "postmaster", "press", "privacy",
              "recruiting", "root", "security", "spam", "webmaster"}
GENERIC_LOCAL = {"contact", "hello", "help", "info", "inquiries", "enquiries", "mail", "office", "reception", "sales",
                 "service", "support", "team", "orders", "bookings", "booking", "studio", "shop"}
JUNK_DOMAIN_PARTS = ("sentry", "wixpress", "example.", "domain.com", "email.com", "yourdomain", "mysite", "godaddy", "schema.org")
EMAIL_RX = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,24}")
AT_RX = re.compile(r"([A-Za-z0-9._%+-]+)\s*[\[(]\s*at\s*[\])]\s*([A-Za-z0-9-]+)\s*[\[(]\s*dot\s*[\])]\s*([A-Za-z]{2,24})", re.I)
SUBPAGE_RX = re.compile(r"contact|about|team|work-with|hire|book|connect", re.I)
RANK = {"high": 0, "medium": 1, "low": 2, "": 3}


def say(msg: str) -> None:
    print(msg, flush=True)


# ---------------------------------------------------------------- fetching, guarded

ROBOTS: dict = {}


def host_of(url: str) -> str:
    host = urllib.parse.urlsplit(url).netloc.lower().split("@")[-1].split(":")[0]
    return host[4:] if host.startswith("www.") else host


def base_domain(url_or_host: str) -> str:
    host = host_of(url_or_host) if "/" in url_or_host else url_or_host.lower().removeprefix("www.")
    parts = host.split(".")
    if len(parts) >= 3 and len(parts[-1]) == 2 and parts[-2] in {"co", "com", "org", "net", "ac", "gov"}:
        return ".".join(parts[-3:])
    return ".".join(parts[-2:]) if len(parts) >= 2 else host


def _test_proxy() -> str:
    """Only the leg tests set this. It may only point at this computer, so nothing here can reach another machine."""
    value = os.environ.get("FINDER_TEST_PROXY", "")
    try:
        host = urllib.parse.urlsplit(value).hostname or ""
    except ValueError:
        host = ""
    return value if host in ("127.0.0.1", "localhost", "::1") else ""


TEST_PROXY = _test_proxy()


def address_problem(url: str):
    """A hostile page can name any address. Only public web sites get read. Returns why not, or None."""
    try:
        parts = urllib.parse.urlsplit(url)
        host, port = parts.hostname, parts.port
    except ValueError:
        return "that link is malformed"
    if parts.scheme.lower() not in ("http", "https"):
        return "only http and https links can be read"
    if not host:
        return "that link has no site in it"
    if TEST_PROXY and host.lower().endswith(".test"):
        return None
    try:
        infos = socket.getaddrinfo(host, port or 443, proto=socket.IPPROTO_TCP)
    except (OSError, UnicodeError):
        return "I could not find that site"
    for info in infos:
        try:
            ip = ipaddress.ip_address(str(info[4][0]).split("%")[0])
        except ValueError:
            return "I could not check that site's address"
        ip = getattr(ip, "ipv4_mapped", None) or ip
        if not ip.is_global or ip.is_multicast:
            return "that address is this computer or a private network, so I will not read it"
    return None


class GuardedRedirect(urllib.request.HTTPRedirectHandler):
    """Check every hop, because a public site can redirect to a private address or to a social site."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if base_domain(newurl) in SOCIAL_HOSTS:
            problem = "it is a social media site, which I do not read"
        else:
            problem = address_problem(newurl)
        if problem:
            raise urllib.error.URLError(f"it redirects somewhere I will not follow: {problem}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class RefusedAddress(OSError):
    pass


def check_peer(conn) -> None:
    ip = ipaddress.ip_address(conn.sock.getpeername()[0].split("%")[0])
    ip = getattr(ip, "ipv4_mapped", None) or ip
    if not ip.is_global or ip.is_multicast:
        conn.sock.close()
        conn.sock = None
        raise RefusedAddress("that address is this computer or a private network, so I will not read it")


class GuardedHTTP(http.client.HTTPConnection):
    def connect(self):
        super().connect()
        check_peer(self)


class GuardedHTTPS(http.client.HTTPSConnection):
    def connect(self):
        super().connect()
        check_peer(self)


class GuardHTTP(urllib.request.HTTPHandler):
    def http_open(self, req):
        return self.do_open(GuardedHTTP, req)


class GuardHTTPS(urllib.request.HTTPSHandler):
    def https_open(self, req):
        return self.do_open(GuardedHTTPS, req, context=ssl.create_default_context())


OPENER = urllib.request.build_opener(
    urllib.request.ProxyHandler({"http": TEST_PROXY, "https": TEST_PROXY}) if TEST_PROXY else urllib.request.ProxyHandler(),
    GuardedRedirect(),
    *(() if TEST_PROXY or urllib.request.getproxies() else (GuardHTTP(), GuardHTTPS())))


def robots_ok(url: str) -> bool:
    parts = urllib.parse.urlsplit(url)
    root = f"{parts.scheme}://{parts.netloc}"
    if root not in ROBOTS:
        rp = urllib.robotparser.RobotFileParser()
        try:
            req = urllib.request.Request(root + "/robots.txt", headers={"User-Agent": UA})
            with OPENER.open(req, timeout=15) as r:
                rp.parse(r.read(200_000).decode("utf-8", "replace").splitlines())
        except urllib.error.HTTPError as exc:
            rp.parse([] if exc.code < 500 and exc.code not in (401, 403) else ["User-agent: *", "Disallow: /"])
        except Exception:
            rp.parse([])
        ROBOTS[root] = rp
    try:
        return ROBOTS[root].can_fetch(UA, url)
    except Exception:
        return True


def fetch(url: str, timeout: int = 25) -> str:
    """Return page text, or raise a plain sentence."""
    if "://" not in url:
        url = "https://" + url
    if base_domain(url) in SOCIAL_HOSTS:
        raise RuntimeError("it is a social media site, which I do not read")
    problem = address_problem(url)
    if problem:
        raise RuntimeError(problem)
    if not robots_ok(url):
        raise RuntimeError("the site's robots.txt asks tools not to read this page")
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "text/html,application/xhtml+xml"})
    try:
        with OPENER.open(req, timeout=timeout) as r:
            ctype = r.headers.get("Content-Type", "")
            if ctype and "html" not in ctype and "text" not in ctype:
                raise RuntimeError(f"this link is not a web page ({ctype.split(';')[0]})")
            raw = r.read(MAX_BYTES)
            charset = r.headers.get_content_charset() or "utf-8"
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"the site answered with status {exc.code}") from None
    except (urllib.error.URLError, http.client.HTTPException, TimeoutError, OSError, ValueError) as exc:
        raise RuntimeError(f"could not reach the site ({getattr(exc, 'reason', exc)})") from None
    try:
        return raw.decode(charset, "replace")
    except LookupError:
        return raw.decode("utf-8", "replace")


class Page(HTMLParser):
    """Keeps the visible text, the links and any mailto addresses."""

    def __init__(self, url: str):
        super().__init__(convert_charrefs=True)
        self.url, self.text, self.links, self.mailtos = url, [], [], []
        self._skip = 0

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag in ("script", "style", "noscript"):
            self._skip += 1
        if tag == "a" and a.get("href"):
            href = a["href"].strip()
            if href.lower().startswith("mailto:"):
                self.mailtos.append(urllib.parse.unquote(href[7:].split("?")[0]))
            elif not href.lower().startswith(("tel:", "javascript:", "#")):
                self.links.append(urllib.parse.urljoin(self.url, href))

    def handle_endtag(self, tag):
        if tag in ("script", "style", "noscript") and self._skip:
            self._skip -= 1

    def handle_data(self, data):
        if not self._skip and data.strip():
            self.text.append(data.strip())


def read_page(url: str) -> Page:
    page = Page(url)
    page.feed(fetch(url))
    return page


# ---------------------------------------------------------------- deciding

def clean_email(raw: str):
    addr = raw.strip().strip(".,;:<>()[]").lower().split("?")[0]
    if not EMAIL_RX.fullmatch(addr):
        return None
    local, _, domain = addr.partition("@")
    if local in JUNK_LOCAL or local.startswith(("noreply", "no-reply", "donotreply")):
        return None
    if any(part in domain for part in JUNK_DOMAIN_PARTS) or re.search(r"\.(png|jpe?g|gif|webp|svg|css|js)$", addr):
        return None
    if re.fullmatch(r"[a-f0-9]{16,}", local) or local in {"name", "user", "yourname", "email", "you", "firstname.lastname", "first.last"}:
        return None
    return addr


def emails_in(text: str) -> list:
    found = [m.group(0) for m in EMAIL_RX.finditer(text or "")]
    found += [f"{a}@{b}.{c}" for a, b, c in AT_RX.findall(text or "")]
    out = []
    for f in found:
        e = clean_email(f)
        if e and e not in out:
            out.append(e)
    return out


def grade_on_site(addr: str, site: str) -> tuple:
    domain = addr.split("@")[1]
    local = addr.split("@")[0]
    if domain in FREE_MAIL:
        return "medium", "a free mail address on their website"
    if base_domain(domain) != base_domain(site):
        return "low", "on their website but on a different domain, so it may be someone else's"
    if local in GENERIC_LOCAL:
        return "medium", "a general inbox on their own website"
    return "high", "a named address on their own website"


def pick_site(person: dict, pause: float, notes: list) -> tuple:
    """(site url, Page of its home) for the website their profile links to, following one link-in-bio page."""
    site = (person.get("website") or "").strip()
    if not site:
        return "", None
    if "://" not in site:
        site = "https://" + site
    dom = base_domain(site)
    if dom in SOCIAL_HOSTS:
        notes.append("their profile links to another social site, which I do not read")
        return "", None
    if dom in SHOP_HOSTS:
        notes.append(f"their profile links to {dom}, a shared site, not their own")
        return "", None
    if dom in LINK_IN_BIO:
        try:
            hub = read_page(site)
        except RuntimeError as exc:
            notes.append(f"could not read their link-in-bio page: {exc}")
            return "", None
        own = [l for l in hub.links if base_domain(l) not in SOCIAL_HOSTS | LINK_IN_BIO | SHOP_HOSTS and l.lower().startswith("http")]
        notes.append(f"followed their link-in-bio page {site}")
        if not own:
            notes.append("their link-in-bio page has no website of their own on it")
            return "", hub
        site = own[0]
        time.sleep(pause)
    try:
        return site, read_page(site)
    except RuntimeError as exc:
        notes.append(f"could not read their website: {exc}")
        return site, None


def find_for(person: dict, pause: float) -> dict:
    notes = []
    candidates = []  # (confidence, addr, source, why)
    for addr in emails_in(person.get("bio", "")):
        candidates.append(("high", addr, person.get("profile_url") or "bio", "written in their own profile bio"))
    for m in person.get("mentions", []):
        for addr in emails_in(m.get("text", "")):
            candidates.append(("medium", addr, m.get("source_url", ""), "written in one of their own posts or comments"))
    site, home = pick_site(person, pause, notes)
    if home is not None and site and base_domain(home.url) not in LINK_IN_BIO:
        pages = [home]
        subs = []
        for link in home.links:
            if base_domain(link) == base_domain(site) and SUBPAGE_RX.search(urllib.parse.urlsplit(link).path):
                clean = link.split("#")[0]
                if clean not in subs and clean.rstrip("/") != site.rstrip("/"):
                    subs.append(clean)
        for sub in subs[:3]:
            time.sleep(pause)
            try:
                pages.append(read_page(sub))
            except RuntimeError:
                continue
        for page in pages:
            for addr in emails_in(" ".join(page.mailtos) + " " + " ".join(page.text)):
                conf, why = grade_on_site(addr, site)
                candidates.append((conf, addr, page.url, why))
    elif home is not None:
        for addr in emails_in(" ".join(home.mailtos) + " " + " ".join(home.text)):
            candidates.append(("medium", addr, home.url, "on their link-in-bio page"))
    candidates.sort(key=lambda c: RANK[c[0]])
    result = {"email": "", "confidence": "", "source": "", "why": "", "website": site, "others": [], "notes": notes}
    if candidates:
        conf, addr, src, why = candidates[0]
        result.update(email=addr, confidence=conf, source=src, why=why)
        result["others"] = sorted({c[1] for c in candidates if c[1] != addr})
    elif not notes:
        result["notes"].append("no email published in their bio, posts or a website" if not site else "no email published on their website")
    return result


# ---------------------------------------------------------------- commands

def load(path, what):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8-sig"))
    except OSError:
        raise SystemExit(f"I could not find the {what} file: {path}")
    except ValueError as exc:
        raise SystemExit(f"The {what} file {path} is not valid JSON: {exc}")


def cmd_run(a) -> int:
    people = {p["id"]: p for p in load(a.people, "people") if isinstance(p, dict) and p.get("id")}
    profiles = load(a.profiles, "profiles")
    out = Path(a.out)
    found = load(out, "emails") if out.exists() and not a.fresh else {}
    todo = [p for p in profiles if isinstance(p, dict) and p.get("id") in people and (p.get("fit_score") or 0) >= a.min_fit]
    say(f"Looking for emails for {len(todo)} people. Reading websites is free and takes a few seconds each.")
    for n, prof in enumerate(todo, 1):
        pid = prof["id"]
        if pid in found and (found[pid].get("confidence") == "checked" or (found[pid].get("source") == "Apollo" and found[pid].get("email"))):
            continue
        try:
            found[pid] = find_for(people[pid], a.pause)
        except KeyboardInterrupt:
            say("Stopped. What was found so far is saved.")
            break
        except Exception as exc:
            found[pid] = {"email": "", "confidence": "", "source": "", "why": "", "website": "", "others": [], "notes": [f"skipped: {exc}"]}
        r = found[pid]
        say(f"{n}. {pid}: " + (f"{r['email']} ({r['confidence']})" if r["email"] else "none. " + "; ".join(r["notes"])[:160]))
        out.write_text(json.dumps(found, indent=1, ensure_ascii=False), encoding="utf-8")
        time.sleep(a.pause)
    counts = {k: sum(1 for r in found.values() if r.get("confidence") == k) for k in ("high", "medium", "low")}
    blank = sum(1 for r in found.values() if not r.get("email"))
    say(f"Done: {counts['high']} high, {counts['medium']} medium, {counts['low']} low, {blank} with none. Saved to {out}.")
    say("Low means probably someone else's, and it is not used for sending until the owner checks it.")
    return 0


def cmd_apify_input(a) -> int:
    found = load(a.emails, "emails")
    sites = sorted({r["website"] for r in found.values() if r.get("website") and not r.get("email")
                    and base_domain(r["website"]) not in SOCIAL_HOSTS | SHOP_HOSTS})
    if not sites:
        say("No websites are left without an email, so there is nothing for the Apify contact step to read.")
        return 0
    body = {"startUrls": [{"url": s} for s in sites], "maxRequestsPerStartUrl": 4, "maxDepth": 1, "sameDomain": True, "mergeContacts": True}
    Path(a.out).write_text(json.dumps(body, indent=1), encoding="utf-8")
    say(f"Wrote {a.out} for {len(sites)} websites. At up to 4 pages each that is up to {len(sites) * 4} pages. Use that as --max-items.")
    return 0


def cmd_merge(a) -> int:
    found = load(a.emails, "emails")
    items = load(a.items, "Apify results")
    by_site: dict = {}
    for item in items if isinstance(items, list) else []:
        if not isinstance(item, dict):
            continue
        start = str(item.get("originalStartUrl") or item.get("startUrl") or item.get("url") or "")
        for raw in (item.get("emails") or []):
            addr = clean_email(str(raw))
            if addr and start:
                by_site.setdefault(base_domain(start), []).append(addr)
    added = 0
    for pid, r in found.items():
        if r.get("email") or not r.get("website"):
            continue
        addrs = by_site.get(base_domain(r["website"]), [])
        graded = sorted((grade_on_site(e, r["website"]) + (e,) for e in addrs), key=lambda g: RANK[g[0]])
        if graded:
            conf, why, addr = graded[0]
            r.update(email=addr, confidence=conf, source=r["website"], why=why + ", found by the Apify contact step")
            added += 1
    Path(a.emails).write_text(json.dumps(found, indent=1, ensure_ascii=False), encoding="utf-8")
    say(f"Added {added} emails from the Apify contact step. Saved to {a.emails}.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Find a published business email for each lead.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("run")
    p.add_argument("--people", required=True)
    p.add_argument("--profiles", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--min-fit", type=float, default=0)
    p.add_argument("--pause", type=float, default=1.0)
    p.add_argument("--fresh", action="store_true", help="start over instead of keeping earlier results")
    p = sub.add_parser("apify-input")
    p.add_argument("--emails", required=True)
    p.add_argument("--out", required=True)
    p = sub.add_parser("merge-apify")
    p.add_argument("--items", required=True)
    p.add_argument("--emails", required=True)
    a = ap.parse_args()
    try:
        return {"run": cmd_run, "apify-input": cmd_apify_input, "merge-apify": cmd_merge}[a.cmd](a)
    except SystemExit as exc:
        if isinstance(exc.code, str):
            say(exc.code)
            return 2
        raise
    except Exception as exc:  # a stranger should never see a stack trace
        say(f"Something went wrong: {exc}. Tell me what you were doing and I will look.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
