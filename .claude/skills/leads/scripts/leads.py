#!/usr/bin/env python3
"""leads.py: read a website, pull businesses from a list page, enrich, de-dupe and rank leads.

    python leads.py inspect <url>
    python leads.py directory <url> --out items.json [--pages 3] [--follow 30]
    python leads.py build --items items.json [more.json] --criteria criteria.json --out folder [--no-enrich]

Standard library only. Reading websites costs nothing. It obeys robots.txt, pauses between sites,
only keeps details the business itself published, and never guesses an email address.
"""
from __future__ import annotations

import argparse
import csv
import html
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
from datetime import date
from html.parser import HTMLParser
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

UA = "Mozilla/5.0 (compatible; lead-research-skill; reads public contact pages)"
MAX_BYTES = 1_500_000
BLOCK_TAGS = {"li", "tr", "article", "section", "dd", "address"}
HEADINGS = {"h1", "h2", "h3", "h4"}
VOID_TAGS = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}
CHROME_TAGS = {"nav", "header", "footer", "aside"}
CHROME_RX = re.compile(r"(^|[\s_-])(nav|navbar|navigation|menu|footer|header|sidebar|breadcrumbs?|widget|social|share)($|[\s_-])", re.I)
# Sites that host many businesses, so a shared address on them says nothing about identity.
SHARED_HOSTS = {
    "facebook.com", "instagram.com", "linkedin.com", "twitter.com", "x.com", "youtube.com", "tiktok.com",
    "pinterest.com", "yelp.com", "google.com", "goo.gl", "g.page", "maps.app.goo.gl", "bing.com", "apple.com",
    "linktr.ee", "wixsite.com", "wix.com", "squarespace.com", "godaddysites.com", "weebly.com", "wordpress.com",
    "shopify.com", "myshopify.com", "bbb.org", "yellowpages.com", "mapquest.com", "angi.com", "thumbtack.com",
    "doubleclick.net", "googletagmanager.com", "cloudflare.com", "w3.org", "schema.org", "gravatar.com",
}
FREE_MAIL = {"gmail.com", "yahoo.com", "hotmail.com", "outlook.com", "aol.com", "icloud.com", "proton.me",
             "protonmail.com", "live.com", "msn.com", "comcast.net"}
JUNK_LOCAL = {
    "abuse", "admin", "administrator", "billing", "careers", "compliance", "dmca", "donotreply", "do-not-reply",
    "hostmaster", "hr", "jobs", "legal", "mailer-daemon", "no-reply", "noreply", "postmaster", "press", "privacy",
    "recruiting", "root", "security", "spam", "webmaster",
}
GENERIC_LOCAL = {"contact", "hello", "help", "info", "inquiries", "mail", "office", "reception", "sales",
                 "service", "support", "team"}
JUNK_DOMAIN_PARTS = ("sentry", "wixpress", "example.", "domain.com", "email.com", "yourdomain", "mysite",
                     "godaddy", "schema.org")
EMAIL_RX = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,24}")
AT_RX = re.compile(r"([A-Za-z0-9._%+-]+)\s*[\[(]\s*at\s*[\])]\s*([A-Za-z0-9-]+)\s*[\[(]\s*dot\s*[\])]\s*([A-Za-z]{2,24})", re.I)
PHONE_RX = re.compile(r"(?<![\d.])(?:\+?1[\s.-]?)?\(?([2-9]\d{2})\)?[\s.-]?([2-9]\d{2})[\s.-]?(\d{4})(?![\d-])")
LINKEDIN_RX = re.compile(r"https?://(?:[a-z]{2,3}\.)?linkedin\.com/(?:company|in|school)/[A-Za-z0-9._%-]+", re.I)
ROLE_WORDS = r"Owner|Co-?Owner|Founder|Co-?Founder|President|CEO|Chief Executive Officer|Principal|Managing Partner|Managing Director|General Manager"
NAME_PART = r"(?:Dr\.\s+)?[A-Z][a-z'’]+(?:\s+[A-Z]\.)?(?:\s+[A-Z][a-z'’-]+){1,2}"
NAME_RXS = [
    re.compile(rf"\b({NAME_PART})\s*[,|\-:]\s*(?:the\s+)?({ROLE_WORDS})\b"),
    re.compile(rf"\b({ROLE_WORDS})\s*[,|\-:]\s*({NAME_PART})"),
    re.compile(rf"\b({NAME_PART})\s+(?:is|was)\s+(?:the\s+|our\s+)?({ROLE_WORDS})\b"),
]
NAME_STOP = {"Our", "The", "About", "Contact", "Meet", "Home", "Team", "Privacy", "Terms", "Read", "More", "Learn",
             "Family", "Business", "Company", "Services", "Call", "Email", "Copyright", "All", "Rights"}
SUBPAGE_RX = re.compile(r"contact|about|team|staff|leadership|who-we-are|our-story|people|owner", re.I)
PAGE_NEXT_RX = re.compile(r"^(next|next page|more|›|»|>)$", re.I)
SPREADSHEET_RISK = ("=", "@", "+", "-", "\t", "\r")


def log(msg: str) -> None:
    print(msg, flush=True)


# ---------------------------------------------------------------- fetching

ROBOTS: dict = {}


def host_of(url: str) -> str:
    host = urllib.parse.urlsplit(url).netloc.lower().split("@")[-1].split(":")[0]
    return host[4:] if host.startswith("www.") else host


def base_domain(url_or_host: str) -> str:
    """Last two labels, or three for names like example.co.uk. Good enough to tell sites apart."""
    host = host_of(url_or_host) if "/" in url_or_host else url_or_host.lower().removeprefix("www.")
    parts = host.split(".")
    if len(parts) >= 3 and len(parts[-1]) == 2 and parts[-2] in {"co", "com", "org", "net", "ac", "gov"}:
        return ".".join(parts[-3:])
    return ".".join(parts[-2:]) if len(parts) >= 2 else host


def _test_proxy() -> str:
    """Only the leg tests set this. It may only point at this computer, so nothing here can reach another machine."""
    value = os.environ.get("LEADS_TEST_PROXY", "")
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
    # Names under .test exist only in the leg tests, whose traffic can only go to the local stand-in above.
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
    """Check every hop, because a public site can redirect to a private address."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        problem = address_problem(newurl)
        if problem:
            raise urllib.error.URLError(f"it redirects somewhere I will not follow: {problem}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class RefusedAddress(OSError):
    pass


def check_peer(conn) -> None:
    """A name can answer differently the second time. So check the address actually connected to, before any request goes out."""
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


# Through a proxy the connected address is the proxy's, so it says nothing about the site.
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
            # A site with no robots file allows everything. One that refuses it is left alone.
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


# ---------------------------------------------------------------- reading a page

class Page(HTMLParser):
    """Keeps the text, the links and the JSON-LD blocks, and splits the page into repeating blocks."""

    def __init__(self, url: str):
        super().__init__(convert_charrefs=True)
        self.url = url
        self.title = ""
        self.description = ""
        self.headings: list = []
        self.text: list = []
        self.links: list = []
        self.jsonld: list = []
        self.blocks: list = []
        self._skip = 0
        self._cap: str | None = None
        self._buf: list = []
        self._link: dict | None = None
        self._block: dict | None = None
        self._next_url = ""
        self._stack: list = []
        self._chrome = 0

    def _new_block(self, kind: str = ""):
        if self._block and (self._block["links"] or self._block["text"]):
            self.blocks.append(self._block)
        self._block = {"links": [], "text": [], "heading": "", "kind": kind}

    def handle_starttag(self, tag, attrs):
        a = {k: (v or "") for k, v in attrs}
        if tag not in VOID_TAGS:
            # Menus, headers and footers are not listings, so remember when we are inside one.
            flag = tag in CHROME_TAGS or bool(CHROME_RX.search(a.get("class", "") + " " + a.get("id", "")))
            self._stack.append((tag, flag))
            self._chrome += flag
        if tag in ("script", "style", "noscript", "svg", "template"):
            if tag == "script" and "ld+json" in a.get("type", "").lower():
                self._cap = "jsonld"
                self._buf = []
            self._skip += 1
            return
        if tag == "title" and not self.title:
            self._cap = "title"
            self._buf = []
        elif tag in HEADINGS:
            self._cap = tag
            self._buf = []
        elif tag == "meta" and a.get("name", "").lower() == "description":
            self.description = a.get("content", "")[:400]
        elif tag == "link" and a.get("rel", "").lower() == "next" and a.get("href"):
            self._next_url = urllib.parse.urljoin(self.url, a["href"])
        elif tag == "a" and a.get("href"):
            self._link = {"href": urllib.parse.urljoin(self.url, a["href"].strip()),
                          "text": a.get("aria-label", "") if not a.get("title") else a["title"],
                          "chrome": self._chrome > 0}
        elif tag == "img" and self._link is not None and a.get("alt") and not self._link["text"]:
            # Sponsor and member pages often show only a logo, with the name in the alt text.
            self._link["text"] = a["alt"]
        cls = a.get("class", "").lower()
        if self._chrome:
            return
        if tag in BLOCK_TAGS or (tag == "div" and re.search(r"listing|result|member|business|company|provider|vendor|sponsor|partner|\bcard\b|\bitem\b", cls)):
            self._new_block(f"{tag}.{cls}")

    def handle_endtag(self, tag):
        if any(entry[0] == tag for entry in self._stack):
            while self._stack:
                name, flag = self._stack.pop()
                self._chrome -= flag
                if name == tag:
                    break
        if tag in ("script", "style", "noscript", "svg", "template"):
            self._skip = max(0, self._skip - 1)
            if self._cap == "jsonld":
                self.jsonld.append("".join(self._buf))
                self._cap = None
            return
        if tag == "title" and self._cap == "title":
            self.title = " ".join("".join(self._buf).split())
            self._cap = None
        elif tag in HEADINGS and self._cap == tag:
            head = " ".join("".join(self._buf).split())
            if head:
                self.headings.append(head)
                if self._block is not None and not self._chrome and not self._block["heading"]:
                    self._block["heading"] = head
            self._cap = None
        elif tag == "a" and self._link:
            self._link["text"] = " ".join(self._link["text"].split())
            self.links.append(self._link)
            if self._block is not None and not self._link["chrome"]:
                self._block["links"].append(self._link)
            if PAGE_NEXT_RX.match(self._link["text"]) and not self._next_url:
                self._next_url = self._link["href"]
            self._link = None

    def handle_data(self, data):
        if self._cap == "jsonld":
            self._buf.append(data)
            return
        if self._skip:
            return
        if self._cap:
            self._buf.append(data)
        if self._link is not None:
            self._link["text"] += data
        chunk = data.strip()
        if chunk:
            self.text.append(chunk)
            if self._block is not None and not self._chrome:
                self._block["text"].append(chunk)

    def finish(self):
        self._new_block()
        return self


def parse_page(url: str, body: str) -> Page:
    p = Page(url)
    try:
        p.feed(body)
    except Exception:
        pass
    return p.finish()


def walk_jsonld(raw_blocks: list):
    """Every dict found in the page's JSON-LD, however deeply nested."""
    stack = []
    for raw in raw_blocks:
        try:
            stack.append(json.loads(html.unescape(raw).strip()))
        except ValueError:
            continue
    while stack:
        node = stack.pop()
        if isinstance(node, list):
            stack.extend(node)
        elif isinstance(node, dict):
            yield node
            stack.extend(v for v in node.values() if isinstance(v, (dict, list)))


def ld_types(node: dict) -> list:
    kind = node.get("@type", "")
    return [str(k) for k in (kind if isinstance(kind, list) else [kind])]


BUSINESS_TYPES = re.compile(r"Business|Organization|Corporation|Store|Dentist|Restaurant|Physician|Attorney|Service|Contractor|Agent|Clinic|Hotel", re.I)


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
    found = [m.group(0) for m in EMAIL_RX.finditer(text)]
    found += [f"{a}@{b}.{c}" for a, b, c in AT_RX.findall(text)]
    return found


def format_phone(area: str, mid: str, end: str) -> str:
    return f"({area}) {mid}-{end}"


def phone_digits(phone: str) -> str:
    digits = re.sub(r"\D", "", phone or "")
    return digits[1:] if len(digits) == 11 and digits.startswith("1") else digits


def good_name(name: str) -> bool:
    words = re.sub(r"^Dr\.\s+", "", name).split()
    return 2 <= len(words) <= 4 and words[0] not in NAME_STOP and words[-1] not in NAME_STOP


def find_named_person(page_text: str, nodes: list):
    for node in nodes:
        for key in ("founder", "employee", "member", "author"):
            val = node.get(key)
            val = val[0] if isinstance(val, list) and val else val
            if isinstance(val, dict) and isinstance(val.get("name"), str) and good_name(val["name"]):
                return val["name"].strip(), str(val.get("jobTitle") or key.title())
    for rx in NAME_RXS:
        for m in rx.finditer(page_text):
            a, b = m.group(1), m.group(2)
            name, role = (a, b) if re.match(NAME_PART, a) and not re.fullmatch(ROLE_WORDS, a) else (b, a)
            if good_name(name):
                return name.strip(), role.strip()
    return None


def read_contact_details(p: Page) -> dict:
    """Emails, phones, LinkedIn links and a named person from one parsed page."""
    out = {"emails": [], "phones": [], "linkedins": [], "person": None}
    text = " ".join(p.text)
    nodes = list(walk_jsonld(p.jsonld))
    for link in p.links:
        href = link["href"]
        low = href.lower()
        if low.startswith("mailto:"):
            out["emails"].append(urllib.parse.unquote(href[7:]))
        elif low.startswith("tel:"):
            m = PHONE_RX.search(urllib.parse.unquote(href[4:]))
            if m:
                out["phones"].append(format_phone(*m.groups()))
        elif LINKEDIN_RX.match(href):
            out["linkedins"].append(LINKEDIN_RX.match(href).group(0))
    out["emails"] += emails_in(text)
    for node in nodes:
        if isinstance(node.get("email"), str):
            out["emails"].append(node["email"].replace("mailto:", ""))
        if isinstance(node.get("telephone"), str):
            m = PHONE_RX.search(node["telephone"])
            if m:
                out["phones"].append(format_phone(*m.groups()))
        same = node.get("sameAs")
        for link in (same if isinstance(same, list) else [same]):
            if isinstance(link, str) and LINKEDIN_RX.match(link):
                out["linkedins"].append(LINKEDIN_RX.match(link).group(0))
    for m in PHONE_RX.finditer(text):
        out["phones"].append(format_phone(*m.groups()))
    out["person"] = find_named_person(text, nodes)
    return out


def name_like(name: str) -> bool:
    """A business name, not a headline or a button."""
    name = " ".join((name or "").split())
    if not (2 < len(name) < 80) or len(name.split()) > 7:
        return False
    if re.search(r"[!?]$|\.\.\.$|\u2026$", name):
        return False
    return not re.fullmatch(r"(?i)(visit|website|home|contact|about|read more|learn more|click here|view|more|email|call|map|directions|share).*", name)


def external_link(link: dict, page_host: str) -> bool:
    href = link["href"]
    if not href.lower().startswith(("http://", "https://")):
        return False
    return base_domain(href) != base_domain(page_host) and base_domain(href) not in SHARED_HOSTS


def business_from_block(block: dict, page_host: str):
    externals = [l for l in block["links"] if external_link(l, page_host)]
    text = " ".join(block["text"])
    tels = [l["href"] for l in block["links"] if l["href"].lower().startswith("tel:")]
    mails = [l["href"][7:] for l in block["links"] if l["href"].lower().startswith("mailto:")]
    phone_match = PHONE_RX.search(" ".join(tels) or text)
    if not (externals or phone_match or mails):
        return None
    name = block["heading"]
    if not name:
        named = next((l["text"] for l in block["links"] if 2 < len(l["text"]) < 80 and not l["href"].lower().startswith(("tel:", "mailto:"))), "")
        name = named or (block["text"][0] if block["text"] else "")
    name = " ".join(name.split())
    if not name_like(name):
        return None
    item = {"name": name, "source": "directory"}
    if externals:
        item["website"] = externals[0]["href"]
    if phone_match:
        item["phone"] = format_phone(*phone_match.groups())
    emails = mails + emails_in(text)
    if emails:
        item["emails"] = emails
    linked = [l["href"] for l in block["links"] if LINKEDIN_RX.match(l["href"])]
    if linked:
        item["linkedin"] = linked[0]
    return item


def profile_cluster(p: Page, page_host: str) -> list:
    """Internal links that share a path prefix and look like names: a directory's profile pages."""
    groups: dict = {}
    for link in p.links:
        href = link["href"]
        if link.get("chrome") or not href.lower().startswith("http") or base_domain(href) != base_domain(page_host):
            continue
        path = urllib.parse.urlsplit(href).path.strip("/").split("/")
        name = link["text"]
        if len(path) < 2 or not name_like(name) or re.search(r"(?i)next|previous|page", name):
            continue
        groups.setdefault(path[0], {})[href] = name
    best = max(groups.values(), key=len, default={})
    return [{"name": n, "profile_url": h} for h, n in best.items()] if len(best) >= 5 else []


def businesses_on(p: Page) -> list:
    host = host_of(p.url)
    found = []
    for node in walk_jsonld(p.jsonld):
        if any(BUSINESS_TYPES.search(t) for t in ld_types(node)) and isinstance(node.get("name"), str):
            url = node.get("url") if isinstance(node.get("url"), str) else ""
            item = {"name": node["name"].strip(), "source": "directory"}
            if url and base_domain(url) != base_domain(host):
                item["website"] = url
            if isinstance(node.get("telephone"), str):
                item["phone"] = node["telephone"]
            if isinstance(node.get("email"), str):
                item["emails"] = [node["email"]]
            addr = node.get("address")
            if isinstance(addr, dict):
                item["city"] = str(addr.get("addressLocality") or "")
                item["state"] = str(addr.get("addressRegion") or "")
                item["address"] = " ".join(str(addr.get(k) or "") for k in ("streetAddress", "addressLocality", "addressRegion", "postalCode")).strip()
            if item.get("website") or item.get("phone") or item.get("emails"):
                found.append(item)
    from_blocks = [x for x in (business_from_block(b, host) for b in p.blocks) if x]
    found += from_blocks
    if len(from_blocks) < 3:
        # No repeating listings, for example a page of logos. Fall back to named links to other sites.
        seen = {x.get("website") for x in found}
        for link in p.links:
            if not link.get("chrome") and external_link(link, host) and name_like(link["text"]) and link["href"] not in seen:
                seen.add(link["href"])
                found.append({"name": link["text"], "source": "directory", "website": link["href"]})
    return found


# ---------------------------------------------------------------- commands: inspect, directory

def cmd_inspect(a) -> int:
    url = a.url if "://" in a.url else "https://" + a.url
    try:
        body = fetch(url)
    except RuntimeError as exc:
        log(f"I could not read {url}: {exc}. Try your built-in web fetch on it, or ask the person to describe the business.")
        return 1
    p = parse_page(url, body)
    biz = businesses_on(p)
    profiles = profile_cluster(p, host_of(url))
    externals = {base_domain(b["website"]) for b in biz if b.get("website")}
    is_list = len(profiles) >= 8 or (len(biz) >= 6 and len(externals) >= 5)
    print(json.dumps({
        "url": url, "title": p.title, "description": p.description, "headings": p.headings[:20],
        "text_excerpt": " ".join(p.text)[:4000],
        "looks_like": "directory or list page" if is_list else "a single business website",
        "businesses_found": len(biz), "profile_links_found": len(profiles),
        "sample": (biz or profiles)[:5],
    }, indent=1, ensure_ascii=False))
    return 0


def cmd_directory(a) -> int:
    url = a.url if "://" in a.url else "https://" + a.url
    found, profiles, seen = [], [], set()
    current = url
    failed = None
    for page_no in range(max(1, a.pages)):
        if not current or current in seen:
            break
        seen.add(current)
        try:
            p = parse_page(current, fetch(current))
        except RuntimeError as exc:
            failed = exc
            log(f"Could not read page {page_no + 1} ({current}): {exc}.")
            break
        here = businesses_on(p)
        found += here
        profiles += profile_cluster(p, host_of(current))
        log(f"Page {page_no + 1}: {len(here)} businesses listed directly.")
        current = p._next_url
        time.sleep(a.pause)
    uniq_profiles = {x["profile_url"]: x for x in profiles}
    follow = list(uniq_profiles.values())[: a.follow]
    if uniq_profiles and len(uniq_profiles) > len(follow):
        log(f"This list has {len(uniq_profiles)} profile pages. Reading the first {len(follow)}. Raise --follow for more.")
    for entry in follow:
        try:
            p = parse_page(entry["profile_url"], fetch(entry["profile_url"]))
        except RuntimeError as exc:
            log(f"Skipped {entry['name']}: {exc}.")
            continue
        details = read_contact_details(p)
        ext = next((l["href"] for l in p.links if external_link(l, host_of(entry["profile_url"]))), "")
        item = {"name": entry["name"], "source": "directory", "profile_url": entry["profile_url"]}
        if ext:
            item["website"] = ext
        if details["phones"]:
            item["phone"] = details["phones"][0]
        if details["emails"]:
            item["emails"] = details["emails"]
        if details["linkedins"]:
            item["linkedin"] = details["linkedins"][0]
        found.append(item)
        time.sleep(a.pause)
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(found, indent=1, ensure_ascii=False), encoding="utf-8")
    log(f"Saved {len(found)} businesses to {out}.")
    if not found:
        log("Found nothing I could use. The list may load through scripts or block tools. Open it with your "
            "built-in web fetch, write the businesses to a JSON list with name and website, and pass that to build.")
        return 1 if failed else 0
    return 0


# ---------------------------------------------------------------- normalizing and enriching

def first_str(value):
    if isinstance(value, list):
        for v in value:
            got = first_str(v)
            if got:
                return got
        return ""
    if isinstance(value, dict):
        return first_str(value.get("value") or value.get("url") or value.get("email") or "")
    return value.strip() if isinstance(value, str) else ""


def as_list(value) -> list:
    if not value:
        return []
    if isinstance(value, list):
        out = []
        for v in value:
            out += as_list(v)
        return out
    if isinstance(value, dict):
        return as_list(value.get("value") or value.get("email") or value.get("url"))
    return [str(value)]


def normalize(item: dict):
    """One record in one shape, whether it came from Google Maps, a list page, or a past run."""
    name = first_str(item.get("name") or item.get("business") or item.get("title"))
    if not name:
        return None
    if item.get("permanentlyClosed") or item.get("temporarilyClosed"):
        return None
    lead = {
        "business": name,
        "contact_name": first_str(item.get("contact_name")),
        "contact_role": first_str(item.get("contact_role")),
        "emails": as_list(item.get("emails")) + as_list(item.get("email")) + as_list(item.get("all_emails")),
        "phone": first_str(item.get("phone") or item.get("phoneUnformatted")),
        "linkedin": first_str(item.get("linkedin") or item.get("linkedIns") or item.get("linkedinProfile")),
        "website": first_str(item.get("website") or item.get("url") if item.get("source") == "directory" else item.get("website")),
        "address": first_str(item.get("address")),
        "city": first_str(item.get("city")),
        "state": first_str(item.get("state")),
        "category": first_str(item.get("category") or item.get("categoryName")),
        "categories": as_list(item.get("categories")),
        "rating": item.get("rating") if item.get("rating") is not None else item.get("totalScore"),
        "reviews": item.get("reviews") if item.get("reviews") is not None else item.get("reviewsCount"),
        "site_text": first_str(item.get("site_text")),
        "map_link": first_str(item.get("map_link") or (item.get("url") if "placeId" in item or "categoryName" in item else "")),
        "sources": as_list(item.get("sources")) or [item.get("source") or ("google maps" if "categoryName" in item or "totalScore" in item else "list")],
        "notes": as_list(item.get("notes")),
        "provenance": dict(item.get("provenance") or {}),
    }
    for person in as_list_of_dicts(item.get("leadsEnrichment")):
        if not lead["contact_name"]:
            full = person.get("fullName") or " ".join(x for x in (person.get("firstName"), person.get("lastName")) if x)
            lead["contact_name"] = (full or "").strip()
            lead["contact_role"] = str(person.get("jobTitle") or "")
        if person.get("email"):
            lead["emails"].append(person["email"])
        if not lead["linkedin"] and person.get("linkedinProfile"):
            lead["linkedin"] = person["linkedinProfile"]
    return lead


def as_list_of_dicts(value) -> list:
    return [v for v in value if isinstance(v, dict)] if isinstance(value, list) else []


def enrich(lead: dict, pause: float) -> None:
    """Read the business's own site: home, then up to three contact or about pages."""
    site = lead.get("website")
    if not site:
        return
    if base_domain(site) in SHARED_HOSTS:
        lead["notes"].append("website is a social or hosted page, so I did not read it for contacts")
        return
    pages_seen = []
    try:
        home = parse_page(site, fetch(site))
    except RuntimeError as exc:
        lead["notes"].append(f"could not read the website: {exc}")
        return
    pages = [home]
    pages_seen.append(site)
    subs = []
    for link in home.links:
        href = link["href"]
        if base_domain(href) == base_domain(site) and href.lower().startswith("http") and (SUBPAGE_RX.search(link["text"]) or SUBPAGE_RX.search(urllib.parse.urlsplit(href).path)):
            clean = href.split("#")[0]
            if clean not in subs and clean.rstrip("/") != site.rstrip("/"):
                subs.append(clean)
    for sub in subs[:3]:
        time.sleep(pause)
        try:
            pages.append(parse_page(sub, fetch(sub)))
            pages_seen.append(sub)
        except RuntimeError:
            continue
    texts = []
    for page, url in zip(pages, pages_seen):
        details = read_contact_details(page)
        texts.append(" ".join(page.text))
        for mail in details["emails"]:
            if mail.lower() not in [e.lower() for e in lead["emails"]]:
                lead["emails"].append(mail)
                lead["provenance"].setdefault("email", url)
        if details["phones"] and not lead["phone"]:
            lead["phone"] = details["phones"][0]
            lead["provenance"].setdefault("phone", url)
        if details["linkedins"] and not lead["linkedin"]:
            lead["linkedin"] = details["linkedins"][0]
            lead["provenance"].setdefault("linkedin", url)
        if details["person"] and not lead["contact_name"]:
            lead["contact_name"], lead["contact_role"] = details["person"]
            lead["provenance"].setdefault("contact_name", url)
    lead["site_text"] = " ".join(texts)[:2500]


def tidy_emails(lead: dict) -> None:
    """Drop junk, flag addresses on another domain, pick the best one to use."""
    site = base_domain(lead["website"]) if lead.get("website") else ""
    kept, off_domain = [], []
    for raw in lead["emails"]:
        addr = clean_email(raw)
        if not addr or addr in kept or addr in off_domain:
            continue
        domain = addr.split("@")[1]
        if site and domain != site and base_domain(domain) != site and domain not in FREE_MAIL:
            off_domain.append(addr)
        else:
            kept.append(addr)

    def quality(addr: str):
        local = addr.split("@")[0]
        return (local in GENERIC_LOCAL, addr.split("@")[1] in FREE_MAIL, addr)

    kept.sort(key=quality)
    lead["all_emails"] = kept + off_domain
    lead["email"] = kept[0] if kept else ""
    lead["email_note"] = ""
    if not kept and off_domain:
        lead["email_note"] = "only address found is on a different domain, probably not theirs: " + off_domain[0]
    elif kept and kept[0].split("@")[0] in GENERIC_LOCAL:
        lead["email_note"] = "general inbox"
    if lead.get("phone"):
        m = PHONE_RX.search(lead["phone"])
        if m:
            lead["phone"] = format_phone(*m.groups())


# ---------------------------------------------------------------- de-duping

def identity_keys(lead: dict) -> list:
    keys = []
    if lead.get("website"):
        dom = base_domain(lead["website"])
        if dom not in SHARED_HOSTS:
            keys.append("site:" + dom)
    digits = phone_digits(lead.get("phone") or "")
    if len(digits) == 10:
        keys.append("phone:" + digits)
    for addr in lead.get("all_emails") or []:
        keys.append("mail:" + addr)
    name = re.sub(r"[^a-z0-9]+", " ", lead["business"].lower()).strip()
    name = re.sub(r"\b(llc|inc|ltd|co|corp|company|the)\b", "", name).strip()
    name = " ".join(name.split())
    if name:
        keys.append(f"name:{name}|{(lead.get('city') or '').lower().strip()}")
    return keys


def merge(into: dict, other: dict) -> None:
    for field in ("contact_name", "contact_role", "phone", "linkedin", "website", "address", "city", "state",
                  "category", "site_text", "map_link", "rating", "reviews"):
        if not into.get(field) and other.get(field):
            into[field] = other[field]
    into["emails"] = list(dict.fromkeys(into["emails"] + other["emails"]))
    into["sources"] = list(dict.fromkeys(into["sources"] + other["sources"]))
    into["notes"] = list(dict.fromkeys(into["notes"] + other["notes"]))
    into["categories"] = list(dict.fromkeys(into["categories"] + other["categories"]))
    for key, val in other["provenance"].items():
        into["provenance"].setdefault(key, val)
    into["duplicates_merged"] = into.get("duplicates_merged", 0) + other.get("duplicates_merged", 0) + 1


def shared_contact_keys(leads: list) -> set:
    """A phone or address on three or more different businesses belongs to a directory or an
    answering service, not to any of them, so it cannot prove two listings are the same business."""
    names: dict = {}
    for lead in leads:
        keys = identity_keys(lead)
        name = next((k for k in keys if k.startswith("name:")), "")
        for key in keys:
            if key.startswith(("phone:", "mail:")):
                names.setdefault(key, set()).add(name)
    return {key for key, seen in names.items() if len(seen) >= 3}


def dedupe(leads: list) -> list:
    owner: dict = {}
    kept: list = []
    shared = shared_contact_keys(leads)
    for lead in leads:
        keys = [k for k in identity_keys(lead) if k not in shared]
        hits = [owner[k] for k in keys if k in owner]
        if hits:
            target = hits[0]
            merge(target, lead)
            # A record can join two earlier ones, so fold those together too.
            for extra in hits[1:]:
                if extra is not target:
                    merge(target, extra)
                    kept = [x for x in kept if x is not extra]
            tidy_emails(target)
            for k in identity_keys(target):
                if k not in shared:
                    owner[k] = target
        else:
            kept.append(lead)
            for k in keys:
                owner[k] = lead
    for lead in kept:
        for k in identity_keys(lead):
            owner[k] = lead
    return kept


# ---------------------------------------------------------------- ranking

def field_text(lead: dict, field: str) -> str:
    parts = []
    for name in field.split("|"):
        value = lead.get(name)
        parts.append(" ".join(map(str, value)) if isinstance(value, list) else str(value or ""))
    return " ".join(parts).lower()


def rule_hits(rule: dict, lead: dict) -> bool:
    field = rule.get("field", "")
    if "contains" in rule:
        words = rule["contains"] if isinstance(rule["contains"], list) else [rule["contains"]]
        hay = field_text(lead, field)
        return any(str(w).lower() in hay for w in words)
    if "present" in rule:
        return bool(field_text(lead, field).strip()) == bool(rule["present"])
    value = lead.get(field)
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return False
    if "min" in rule and value < rule["min"]:
        return False
    if "max" in rule and value > rule["max"]:
        return False
    return "min" in rule or "max" in rule


def check_criteria(crit: dict) -> str | None:
    if not isinstance(crit, dict) or not crit.get("signals"):
        return "The criteria file needs at least one item under signals, because every lead is ranked against them."
    for group in ("must_have", "exclude", "signals"):
        for rule in crit.get(group, []):
            if not rule.get("label") or not rule.get("field"):
                return f"Every rule in {group} needs a label and a field."
            if not any(k in rule for k in ("contains", "present", "min", "max")):
                return f"The rule '{rule['label']}' needs one of contains, present, min or max."
    for rule in crit["signals"]:
        if not isinstance(rule.get("points"), (int, float)) or rule["points"] <= 0:
            return f"The signal '{rule['label']}' needs points above zero."
    return None


def rank(leads: list, crit: dict) -> list:
    reach = crit.get("reach_points", {"email": 10, "named_person": 5, "phone": 3, "linkedin": 2})
    top = sum(r["points"] for r in crit["signals"]) + sum(reach.values())
    for lead in leads:
        hit, missed = [], []
        got = 0.0
        for rule in crit["signals"]:
            if rule_hits(rule, lead):
                got += rule["points"]
                hit.append(rule["label"])
            else:
                missed.append(rule["label"])
        ways = []
        if lead.get("email"):
            got += reach.get("email", 0)
            ways.append("email")
        if lead.get("contact_name"):
            got += reach.get("named_person", 0)
            ways.append("named person")
        if lead.get("phone"):
            got += reach.get("phone", 0)
            ways.append("phone")
        if lead.get("linkedin"):
            got += reach.get("linkedin", 0)
            ways.append("LinkedIn")
        blocked = [r["label"] for r in crit.get("exclude", []) if rule_hits(r, lead)]
        blocked += ["missing: " + r["label"] for r in crit.get("must_have", []) if not rule_hits(r, lead)]
        lead["fit"] = "no" if blocked else "yes"
        lead["score"] = 0 if blocked else round(100 * got / top) if top else 0
        bits = []
        if blocked:
            bits.append("Ruled out: " + "; ".join(blocked) + ".")
        if hit:
            bits.append("Fits: " + "; ".join(hit) + ".")
        if missed and not blocked:
            bits.append("Misses: " + "; ".join(missed) + ".")
        bits.append(("Reach by: " + ", ".join(ways) + ".") if ways else "No public way to reach them found.")
        lead["reason"] = " ".join(bits)
    leads.sort(key=lambda x: (x["fit"] != "yes", -x["score"], not x.get("email"),
                              -(x.get("reviews") or 0 if isinstance(x.get("reviews"), (int, float)) else 0),
                              x["business"].lower()))
    for n, lead in enumerate(leads, 1):
        lead["rank"] = n
    return leads


# ---------------------------------------------------------------- output

CSV_COLUMNS = ["rank", "score", "fit", "business", "contact_name", "contact_role", "email", "email_note", "phone",
               "linkedin", "website", "address", "city", "state", "category", "rating", "reviews", "reason",
               "map_link", "sources"]


def csv_safe(value) -> str:
    """A cell from a stranger's website must not run as a formula when the sheet is opened."""
    text = " ".join(map(str, value)) if isinstance(value, list) else ("" if value is None else str(value))
    if text.startswith(SPREADSHEET_RISK):
        return "'" + text
    return text


def md_cell(value) -> str:
    return (str(value) if value not in (None, "") else "").replace("|", "/").replace("\n", " ").strip()


def write_outputs(leads: list, crit: dict, folder: Path, counts: dict) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    with (folder / "leads.csv").open("w", newline="", encoding="utf-8-sig") as fh:
        w = csv.writer(fh)
        w.writerow(CSV_COLUMNS)
        for lead in leads:
            w.writerow([csv_safe(lead.get(c)) for c in CSV_COLUMNS])
    (folder / "leads.json").write_text(json.dumps(leads, indent=1, ensure_ascii=False), encoding="utf-8")
    fits = sum(1 for x in leads if x["fit"] == "yes")
    with_mail = sum(1 for x in leads if x.get("email"))
    lines = [
        f"# Ranked Leads, {date.today().isoformat()}",
        "",
        f"Ideal customer: {crit.get('ideal_customer', 'not stated')}",
        "",
        f"Records in: {counts['raw']}. Duplicates merged: {counts['merged']}. Leads left: {len(leads)}. "
        f"Fit: {fits}. With an email the business published: {with_mail}.",
        "",
        "| Rank | Score | Business | Contact | Email | Phone | LinkedIn | Why |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for lead in leads:
        who = lead.get("contact_name", "")
        if who and lead.get("contact_role"):
            who += f", {lead['contact_role']}"
        email = lead.get("email", "")
        if lead.get("email_note"):
            email = f"{email} ({lead['email_note']})" if email else lead["email_note"]
        lines.append("| " + " | ".join(md_cell(v) for v in (
            lead["rank"], lead["score"], lead["business"], who, email, lead.get("phone"),
            lead.get("linkedin"), lead["reason"])) + " |")
    (folder / "leads-ranked.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def cmd_build(a) -> int:
    try:
        crit = json.loads(Path(a.criteria).read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as exc:
        log(f"I could not read the criteria file {a.criteria}: {exc}")
        return 2
    problem = check_criteria(crit)
    if problem:
        log(problem)
        return 2
    raw = []
    for path in a.items:
        try:
            data = json.loads(Path(path).read_text(encoding="utf-8-sig"))
        except (OSError, ValueError) as exc:
            log(f"Skipped {path}: {exc}")
            continue
        if isinstance(data, dict):
            data = data.get("items") or [data]
        raw += [d for d in data if isinstance(d, dict)]
    leads = [x for x in (normalize(d) for d in raw) if x]
    closed = len(raw) - len(leads)
    if not leads:
        log("There are no usable records in those files, so there is nothing to rank.")
        return 1
    for lead in leads:
        tidy_emails(lead)
    # De-dupe first so a site is read once, then again in case reading the sites revealed more matches.
    leads = dedupe(leads)
    if not a.no_enrich:
        todo = leads[: a.max_sites]
        log(f"Reading {len(todo)} business websites for public contact details. No cost, about a minute per 20.")
        for n, lead in enumerate(todo, 1):
            enrich(lead, a.pause)
            tidy_emails(lead)
            if n % 20 == 0:
                log(f"  {n} of {len(todo)} done.")
            time.sleep(a.pause)
        if len(leads) > len(todo):
            log(f"Left {len(leads) - len(todo)} sites unread. Raise --max-sites to read them.")
    leads = dedupe(leads)
    merged = len(raw) - closed - len(leads)
    rank(leads, crit)
    folder = Path(a.out)
    write_outputs(leads, crit, folder, {"raw": len(raw) - closed, "merged": merged})
    if closed:
        log(f"Dropped {closed} closed or unnamed records.")
    fits = sum(1 for x in leads if x["fit"] == "yes")
    log(f"Done: {len(leads)} leads, {fits} fit, {merged} duplicates merged.")
    log(f"Wrote {folder / 'leads-ranked.md'}, {folder / 'leads.csv'} and {folder / 'leads.json'}.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Find, enrich, de-dupe and rank leads.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("inspect", help="read one website and say what it looks like")
    p.add_argument("url")
    p = sub.add_parser("directory", help="pull businesses from a list page")
    p.add_argument("url")
    p.add_argument("--out", required=True)
    p.add_argument("--pages", type=int, default=3)
    p.add_argument("--follow", type=int, default=30, help="most profile pages to open")
    p.add_argument("--pause", type=float, default=0.5)
    p = sub.add_parser("build", help="merge, enrich, de-dupe, rank and write the files")
    p.add_argument("--items", nargs="+", required=True)
    p.add_argument("--criteria", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--no-enrich", action="store_true")
    p.add_argument("--max-sites", type=int, default=200)
    p.add_argument("--pause", type=float, default=0.3)
    a = ap.parse_args()
    try:
        return {"inspect": cmd_inspect, "directory": cmd_directory, "build": cmd_build}[a.cmd](a)
    except KeyboardInterrupt:
        log("Stopped.")
        return 1
    except Exception as exc:  # a stranger should never see a stack trace
        log(f"Something went wrong: {exc}. Tell me what you were doing and I will look.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
