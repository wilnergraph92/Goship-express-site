#!/usr/bin/env python3
"""crawl.py: read a website the way a polite search engine would. Standard library only.

    python crawl.py <website> --out search-work/crawl.json [--max-pages 200] [--delay 1]
                    [--focus "roof,metal"] [--max-seconds 100] [--resume]

Each run stops by itself after --max-seconds and saves its place, so it fits inside the time an
app allows one command. If it prints CRAWL NOT FINISHED, run the same command with --resume.
A session that dies loses at most the last few pages.

Reads robots.txt first and obeys it, starts from the sitemap, never goes faster than one
request per --delay seconds (or slower if the site's robots.txt asks), and stops at the page
cap. It only reads. It does not run JavaScript, so text a page builds in the browser is
invisible to it, and the output says so when a page looks that way.

For every page it records: status, title, description, headings, word count, canonical,
internal links, images missing alt text, the structured data (JSON-LD) blocks, phone links,
the site name it declares, and up to 6,000 characters of its visible text.
"""
from __future__ import annotations

import argparse
import html.parser
import http.client
import ipaddress
import json
import math
import re
import socket
import ssl
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
import zlib
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import parse_qsl, urlencode, urljoin, urlsplit, urlunsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))
from searchlib import die, run_main, save_json  # noqa: E402

BOT_TOKEN = "SearchSkillCrawler"
USER_AGENT = f"Mozilla/5.0 (compatible; {BOT_TOKEN}/1.0; a site owner's own check, run from Claude Code)"
HARD_PAGE_CAP = 1000
MIN_DELAY = 0.5
MAX_BYTES = 3_000_000
MAX_SITEMAP_FILES = 25
MAX_SITEMAP_URLS = 5000
MAX_UNZIPPED = 50_000_000  # the sitemap format's own limit, and a stop for a file built to blow up when unpacked
MAX_CRAWL_DELAY = 60  # past this, robots.txt is asking for days, or trying to hang the run
TRACKING = re.compile(r"^(utm_|gclid$|fbclid$|msclkid$|mc_|ref$)", re.I)
NOT_PAGES = re.compile(
    r"\.(jpe?g|png|gif|webp|avif|svg|ico|bmp|tiff?|pdf|docx?|xlsx?|pptx?|zip|gz|rar|7z|mp3|m4a|wav|mp4|mov|avi|webm|"
    r"css|js|mjs|map|json|xml|rss|atom|woff2?|ttf|eot|otf|csv|txt)$", re.I)


class Fetched:
    def __init__(self, url, status=0, headers=None, body=b"", error=""):
        self.url, self.status, self.headers, self.body, self.error = url, status, headers or {}, body, error

    def header(self, name):
        return self.headers.get(name.lower(), "")

    def text(self):
        match = re.search(r"charset=([\w\-]+)", self.header("content-type"), re.I)
        try:
            return self.body.decode(match.group(1) if match else "utf-8", errors="replace")
        except LookupError:
            return self.body.decode("utf-8", errors="replace")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def ip_problem(text, allow_loopback=False):
    """Why this crawler must not talk to an address, or an empty string if it may."""
    ip = ipaddress.ip_address(text.split("%", 1)[0])
    ip = getattr(ip, "ipv4_mapped", None) or ip
    if ip.is_loopback:
        return "" if allow_loopback else "that is this computer's own address"
    if ip.is_link_local:
        return "that is a link-local address, which on a cloud machine can expose its secrets"
    if ip.is_multicast or not ip.is_global:
        return "that is a private network address"
    return ""


def url_problem(url, allow_loopback=False):
    """The guard every request passes: http or https only, and no private addresses after resolving."""
    try:
        parts = urlsplit(url)
        host, port = parts.hostname, parts.port
    except ValueError:
        return "it is not a valid address"
    scheme = parts.scheme.lower()
    if scheme not in ("http", "https"):
        return "only http and https addresses are read"
    if not host or "@" in parts.netloc or "\\" in url:
        return "it does not name a plain host"
    try:
        found = socket.getaddrinfo(host, port or (443 if scheme == "https" else 80), type=socket.SOCK_STREAM)
    except (OSError, UnicodeError):
        return ""  # it does not resolve, so the request itself will fail and say so
    for row in found:
        problem = ip_problem(row[4][0], allow_loopback)
        if problem:
            return problem
    return ""


def start_allows_loopback(start):
    """A person may point this at their own site on this computer. Only then is loopback allowed."""
    try:
        found = socket.getaddrinfo(urlsplit(start).hostname, None, type=socket.SOCK_STREAM)
        return bool(found) and all(ipaddress.ip_address(row[4][0].split("%", 1)[0]).is_loopback for row in found)
    except (OSError, ValueError, UnicodeError, TypeError):
        return False


class RefusedAddress(OSError):
    pass


def check_peer(conn):
    """Resolving twice can give two answers. So check the address actually connected to, before any request is sent."""
    if not conn.check_peer:
        return
    problem = ip_problem(conn.sock.getpeername()[0], conn.allow_loopback)
    if problem:
        conn.sock.close()
        conn.sock = None
        raise RefusedAddress(problem)


class GuardedHTTP(http.client.HTTPConnection):
    def __init__(self, *args, allow_loopback=False, check_peer=True, **kwargs):
        super().__init__(*args, **kwargs)
        self.allow_loopback, self.check_peer = allow_loopback, check_peer

    def connect(self):
        super().connect()
        check_peer(self)


class GuardedHTTPS(http.client.HTTPSConnection):
    def __init__(self, *args, allow_loopback=False, check_peer=True, **kwargs):
        super().__init__(*args, **kwargs)
        self.allow_loopback, self.check_peer = allow_loopback, check_peer

    def connect(self):
        super().connect()
        check_peer(self)


class GuardHTTPHandler(urllib.request.HTTPHandler):
    def __init__(self, allow_loopback, peer):
        super().__init__()
        self.guard_args = {"allow_loopback": allow_loopback, "check_peer": peer}

    def http_open(self, req):
        return self.do_open(GuardedHTTP, req, **self.guard_args)


class GuardHTTPSHandler(urllib.request.HTTPSHandler):
    def __init__(self, allow_loopback, peer):
        self.guard_context = ssl.create_default_context()
        super().__init__(context=self.guard_context)
        self.guard_args = {"allow_loopback": allow_loopback, "check_peer": peer}

    def https_open(self, req):
        return self.do_open(GuardedHTTPS, req, context=self.guard_context, **self.guard_args)


class Client:
    """One request at a time, never faster than the delay, and never to a private address."""

    def __init__(self, delay, allow_loopback=False):
        self.delay = delay
        self.last = 0.0
        self.requests = 0
        self.allow_loopback = allow_loopback
        self.refused = []
        # Through a proxy the connected address is the proxy's, so only the check on the name applies.
        peer = not urllib.request.getproxies()
        self.opener = urllib.request.build_opener(_NoRedirect(), GuardHTTPHandler(allow_loopback, peer), GuardHTTPSHandler(allow_loopback, peer))

    def get(self, url):
        problem = url_problem(url, self.allow_loopback)
        if problem:
            return self.refuse(url, problem)
        gap = self.delay - (time.monotonic() - self.last)
        if gap > 0:
            time.sleep(gap)
        self.requests += 1
        try:
            return self._fetch(url)
        finally:
            # Count the wait from the end of this answer, so the site never sees a shorter gap.
            self.last = time.monotonic()

    def refuse(self, url, problem):
        self.refused.append(str(url)[:200])
        return Fetched(url, error=f"I refused to read it: {problem}")

    def _fetch(self, url):
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept-Encoding": "identity",
                                                    "Accept": "text/html,application/xhtml+xml,*/*;q=0.8"})
        try:
            with self.opener.open(req, timeout=25) as resp:
                headers = {k.lower(): v for k, v in resp.headers.items()}
                return Fetched(url, resp.status, headers, resp.read(MAX_BYTES))
        except urllib.error.HTTPError as err:
            headers = {k.lower(): v for k, v in (err.headers or {}).items()}
            try:
                body = err.read(MAX_BYTES)
            except Exception:
                body = b""
            return Fetched(url, err.code, headers, body)
        except urllib.error.URLError as err:
            reason = err.reason
            if isinstance(reason, RefusedAddress):
                return self.refuse(url, str(reason))
            if isinstance(reason, ssl.SSLError) and "CERTIFICATE_VERIFY_FAILED" in str(reason):
                return Fetched(url, error="certificate check failed. On a Mac this usually means Python's certificates "
                                          "are not installed: run Install Certificates.command in the Python folder")
            return Fetched(url, error=f"could not connect ({reason})")
        except Exception as err:
            return Fetched(url, error=f"could not read it ({type(err).__name__})")


# ------------------------------------------------------------------ robots.txt


class Robots:
    """The robots.txt rules that apply to this crawler: most specific group, longest match wins."""

    def __init__(self, text=""):
        self.sitemaps, self.crawl_delay = [], None
        groups, agents, in_rules = [], [], False
        for raw in (text or "").splitlines():
            line = raw.split("#", 1)[0].strip()
            if ":" not in line:
                continue
            field, _, value = line.partition(":")
            field, value = field.strip().lower(), value.strip()
            if field == "sitemap":
                self.sitemaps.append(value)
            elif field == "user-agent":
                if in_rules:
                    agents, in_rules = [], False
                if not agents:
                    groups.append({"agents": agents, "rules": [], "delay": None})
                agents.append(value.lower())
            elif groups and field in ("allow", "disallow"):
                in_rules = True
                if value:
                    groups[-1]["rules"].append((field == "allow", value))
            elif groups and field == "crawl-delay":
                in_rules = True
                try:
                    delay = float(value)
                    if math.isfinite(delay) and delay >= 0:
                        groups[-1]["delay"] = delay
                except ValueError:
                    pass
        me = BOT_TOKEN.lower()
        chosen = [g for g in groups if any(a != "*" and a in me for a in g["agents"])]
        if not chosen:
            chosen = [g for g in groups if "*" in g["agents"]]
        self.rules = [rule for g in chosen for rule in g["rules"]]
        delays = [g["delay"] for g in chosen if g["delay"] is not None]
        self.crawl_delay = max(delays) if delays else None

    @staticmethod
    def _matches(pattern, path):
        regex = re.escape(pattern).replace(r"\*", ".*")
        if regex.endswith(r"\$"):
            regex = regex[:-2] + "$"
        return re.match(regex, path) is not None

    def allowed(self, url):
        parts = urlsplit(url)
        path = (parts.path or "/") + (("?" + parts.query) if parts.query else "")
        best_len, verdict = -1, True
        for allow, pattern in self.rules:
            if self._matches(pattern, path):
                size = len(pattern)
                if size > best_len or (size == best_len and allow):
                    best_len, verdict = size, allow
        return verdict

    @property
    def blocks_everything(self):
        return not self.allowed("https://x/") and not self.allowed("https://x/some-page")


# ------------------------------------------------------------------ page reading


class PageParser(html.parser.HTMLParser):
    SKIP = {"script", "style", "noscript", "template", "svg"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.title, self.description, self.robots, self.canonical, self.generator, self.base = None, None, "", "", "", ""
        self.headings, self.links, self.images = [], [], []
        self.words, self.excerpt = 0, []
        self.scripts = 0
        self.jsonld, self.tels, self.site_name, self._ld, self._ld_buf = [], [], "", False, []
        self._skip, self._in_title, self._title_buf, self._heading, self._heading_buf = 0, False, [], 0, []

    def handle_starttag(self, tag, attrs):
        attr = {k.lower(): (v or "") for k, v in attrs}
        if tag == "script":
            self.scripts += 1
            if "ld+json" in attr.get("type", "").lower() and not self._skip:
                self._ld, self._ld_buf = True, []
        if tag in self.SKIP:
            self._skip += 1
            return
        if self._skip:
            return
        if tag == "title" and self.title is None:
            self._in_title = True
        elif tag == "meta":
            name = attr.get("name", "").lower()
            if name == "description" and self.description is None:
                self.description = attr.get("content", "").strip()
            elif name in ("robots", "googlebot"):
                self.robots = (self.robots + " " + attr.get("content", "")).strip().lower()
            elif name == "generator" and not self.generator:
                self.generator = attr.get("content", "")
            elif attr.get("property", "").lower() == "og:site_name" and not self.site_name:
                self.site_name = attr.get("content", "").strip()[:200]
        elif tag == "link":
            if "canonical" in attr.get("rel", "").lower().split() and not self.canonical:
                self.canonical = attr.get("href", "").strip()
        elif tag == "base" and attr.get("href") and not self.base:
            self.base = attr["href"]
        elif tag == "a" and attr.get("href"):
            self.links.append(attr["href"].strip())
            if attr["href"].strip().lower().startswith("tel:") and len(self.tels) < 10:
                self.tels.append(attr["href"].strip()[4:][:40])
        elif tag == "img":
            self.images.append({"src": attr.get("src") or attr.get("data-src") or "", "alt": attrs_alt(attrs)})
        elif re.fullmatch(r"h[1-6]", tag):
            self._heading, self._heading_buf = int(tag[1]), []

    def handle_startendtag(self, tag, attrs):
        # A self-closed <svg/> or <script/> opens nothing, so it must not leave the skip count raised.
        if tag in self.SKIP:
            if tag == "script":
                self.scripts += 1
            return
        self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag):
        if tag == "script" and self._ld:
            self._ld = False
            self._add_jsonld("".join(self._ld_buf))
        if tag in self.SKIP:
            self._skip = max(0, self._skip - 1)
            return
        if self._skip:
            return
        if tag == "title" and self._in_title:
            self._in_title = False
            self.title = " ".join("".join(self._title_buf).split())
        elif self._heading and re.fullmatch(r"h[1-6]", tag):
            text = " ".join("".join(self._heading_buf).split())
            if text and len(self.headings) < 80:
                self.headings.append({"level": self._heading, "text": text})
            self._heading = 0

    def handle_data(self, data):
        if self._ld:
            if sum(map(len, self._ld_buf)) < 60000:
                self._ld_buf.append(data)
            return
        if self._skip:
            return
        if self._in_title:
            self._title_buf.append(data)
            return
        if self._heading:
            self._heading_buf.append(data)
        found = re.findall(r"[^\W_]+(?:['’-][^\W_]+)*", data)
        self.words += len(found)
        if sum(map(len, self.excerpt)) < 6000 and data.strip():
            self.excerpt.append(" ".join(data.split()))


    def _add_jsonld(self, text):
        """Keep each structured data object, flattened out of @graph. A broken block is noted, not fatal."""
        try:
            data = json.loads(text.strip().strip(";"))
        except ValueError:
            self.jsonld.append({"@error": "this structured data block is not valid JSON, so Google cannot read it"})
            return
        items = data if isinstance(data, list) else [data]
        for item in items:
            if isinstance(item, dict) and isinstance(item.get("@graph"), list):
                items.extend(x for x in item["@graph"] if isinstance(x, dict))
                continue
            if isinstance(item, dict) and len(self.jsonld) < 12 and len(json.dumps(item)) < 20000:
                self.jsonld.append(item)


def attrs_alt(attrs):
    """None when the alt attribute is absent, a string (maybe empty) when it is there."""
    for key, value in attrs:
        if key.lower() == "alt":
            return value or ""
    return None


def clean_url(url):
    """Drop the fragment and tracking tags so one page is one address. A broken address gives ''."""
    try:
        parts = urlsplit(url)
        query = urlencode([(k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True) if not TRACKING.match(k)])
        return urlunsplit((parts.scheme.lower(), parts.netloc.lower(), parts.path or "/", query, ""))
    except ValueError:
        return ""


def safe_join(base, href):
    """Join a link to its page. Pages are written by strangers, so a broken link gives ''."""
    try:
        return clean_url(urljoin(base, href))
    except ValueError:
        return ""


def same_site(url, host):
    def bare(h):
        return h[4:] if h.startswith("www.") else h
    try:
        return bare(urlsplit(url).netloc.lower()) == bare(host.lower())
    except ValueError:
        return False


def parse_page(fetched):
    parser = PageParser()
    try:
        parser.feed(fetched.text())
        parser.close()
    except Exception:
        pass
    return parser


def platform_guess(home_html, generator):
    text = (generator + " " + home_html[:200000]).lower()
    for mark, name in (("wp-content", "wordpress"), ("wordpress", "wordpress"), ("wixstatic.com", "wix"),
                       ("wix.com", "wix"), ("squarespace", "squarespace"), ("cdn.shopify.com", "shopify"),
                       ("webflow", "webflow"), ("ghost", "ghost"), ("drupal", "drupal"), ("joomla", "joomla")):
        if mark in text:
            return name
    return "unknown"


# ------------------------------------------------------------------ sitemaps


def unzip_limited(body):
    """Unpack a gzipped file, and refuse one that grows past the limit."""
    unpack = zlib.decompressobj(16 + zlib.MAX_WBITS)
    out = unpack.decompress(body, MAX_UNZIPPED)
    if unpack.unconsumed_tail:
        raise ValueError("too large")
    return out


def read_sitemaps(client, start_list, host, notes):
    """Follow sitemap files, including index files and gzipped ones. Returns page URLs."""
    seen, found, queue, files_ok = set(), [], list(start_list), 0
    while queue and len(seen) < MAX_SITEMAP_FILES and len(found) < MAX_SITEMAP_URLS:
        url = queue.pop(0)
        if url in seen:
            continue
        seen.add(url)
        # A site's robots.txt can name any address. Only sitemaps on this same site are read.
        if not str(url).lower().startswith(("http://", "https://")) or not same_site(url, host):
            notes.append(f"Skipped a sitemap listed at {str(url)[:120]}, because it is not on this site.")
            continue
        resp, hops = client.get(url), 0
        while 300 <= resp.status < 400 and resp.header("location") and hops < 3:
            target = safe_join(resp.url, resp.header("location"))
            if not same_site(target, host):
                notes.append(f"Skipped a sitemap that redirects off this site, to {target[:120]}.")
                break
            resp, hops = client.get(target), hops + 1
        if resp.status != 200:
            continue
        body = resp.body
        if body[:2] == b"\x1f\x8b":
            try:
                body = unzip_limited(body)
            except (zlib.error, ValueError):
                notes.append(f"The sitemap at {url} could not be unpacked, or it is far too large.")
                continue
        try:
            root = ET.fromstring(body)
        except (ET.ParseError, ValueError):
            if url in start_list and b"<urlset" in body[:2000]:
                notes.append(f"The sitemap at {url} is damaged XML, so Google may not be able to read it either.")
            continue
        files_ok += 1
        kind = root.tag.rsplit("}", 1)[-1].lower()
        locs = [el.text.strip() for el in root.iter() if el.tag.rsplit("}", 1)[-1].lower() == "loc" and el.text]
        if kind == "sitemapindex":
            queue.extend(locs)
        else:
            found.extend(clean_url(u) for u in locs if same_site(u, host))
    return list(dict.fromkeys(found))[:MAX_SITEMAP_URLS], files_ok


# ------------------------------------------------------------------ the crawl


def normalize_start(site):
    site = site.strip()
    if not re.match(r"^https?://", site, re.I):
        site = "https://" + site
    parts = urlsplit(site)
    if not parts.netloc:
        die(f"'{site}' does not look like a website address. Paste the full address, like https://example.com.")
    return clean_url(site)


def load_robots(client, root, notes):
    """Read one host's robots.txt. Returns (rules, found). Refuses to go on if the host will not say."""
    resp, hops = client.get(root + "/robots.txt"), 0
    while 300 <= resp.status < 400 and resp.header("location") and hops < 4:
        resp, hops = client.get(safe_join(resp.url, resp.header("location"))), hops + 1
    host = urlsplit(root).netloc
    if not resp.status:
        return None, resp.error  # no answer at all, so the caller can try plain http
    if resp.status in (401, 403):
        die(f"{host} refuses to show its robots.txt (status {resp.status}), so I will not crawl it. If this is "
            "your site, ask your web host to allow it, or give me the site's folder instead.")
    if resp.status >= 500:
        die(f"{host} could not serve its robots.txt right now (status {resp.status}). The polite rule is to stop "
            "when that happens, so nothing was crawled. Try again later.")
    found = resp.status == 200
    return Robots(resp.text() if found else ""), found


def open_site(client, start, notes):
    """Find where the site really lives, obeying robots.txt before touching any page on a host."""
    tried = [start]
    if start.startswith("https://"):
        tried.append("http://" + start[8:])
    failure = ""
    for url in tried:
        parts = urlsplit(url)
        root = f"{parts.scheme}://{parts.netloc}"
        robots, found = load_robots(client, root, notes)
        if robots is None:
            failure = found
            continue
        current, hops = url, 0
        while True:
            if not robots.allowed(current):
                return None, root, robots, found
            resp = client.get(current)
            if not (300 <= resp.status < 400 and resp.header("location") and hops < 6):
                return resp, root, robots, found
            current, hops = safe_join(resp.url, resp.header("location")), hops + 1
            problem = url_problem(current, client.allow_loopback)
            if not current or problem:
                die(f"{start} redirects to {current[:120] or 'a broken address'}, and I will not follow it: {problem or 'it is not a valid address'}. "
                    "Nothing was saved. If that surprises you on your own site, ask your web host.")
            next_parts = urlsplit(current)
            next_root = f"{next_parts.scheme}://{next_parts.netloc}"
            if next_root != root:
                root = next_root
                robots, found = load_robots(client, root, notes)
                if robots is None:
                    die(f"{start} redirects to {current[:120]}, and I could not read that: {found}. Check the address and try again.")
    die(f"I could not reach {start}: {failure}. Check the address and try again.")


SAVE_EVERY = 10  # pages between saves of the crawl's place


def state_path(out):
    return Path(str(out) + ".state.json")


def crawl(site, max_pages=200, delay=1.0, focus=(), max_seconds=0, out=None, resume=False):
    start = normalize_start(site)
    client = Client(max(MIN_DELAY, delay), allow_loopback=start_allows_loopback(start))
    deadline = time.monotonic() + max_seconds if max_seconds else None
    notes = []
    saved = None
    if resume and out and state_path(out).is_file():
        try:
            saved = json.loads(state_path(out).read_text(encoding="utf-8"))
        except ValueError:
            print("The saved place was damaged, so I am starting again.", flush=True)
        if saved and saved.get("start_url") != start:
            print("The saved place is for a different site, so I am starting again.", flush=True)
            saved = None
    elif resume:
        print("There is no saved place for this crawl, so I am starting from the top.", flush=True)

    home = None
    if saved:
        # robots.txt is read fresh on every run: the site may have changed its mind.
        root = saved["root"]
        robots, robots_found = load_robots(client, root, notes)
        if robots is None:
            die(f"I could not reach {root}: {robots_found}. Your place is saved, so run this again with --resume later.")
        host, notes = saved["host"], saved["notes"]
        client.requests = saved["requests_made"]
        print(f"Picking up where I left off: {len(saved['results'])} pages already read.", flush=True)
    else:
        home, root, robots, robots_found = open_site(client, start, notes)
        host = urlsplit(root).netloc
    if robots.crawl_delay:
        if robots.crawl_delay > MAX_CRAWL_DELAY:
            die(f"{host}'s robots.txt asks for {robots.crawl_delay:g} seconds between requests. That is too slow to finish, and I will not "
                "ignore it, so I stopped here. Nothing was saved. If this is your site, lower that number in robots.txt.")
        client.delay = max(client.delay, robots.crawl_delay)
        if robots.crawl_delay > 10 and not saved:
            notes.append(f"robots.txt asks for {robots.crawl_delay:g} seconds between requests, so this was slow.")
    if not saved and home is None:
        notes.append("robots.txt tells crawlers not to read this page, so I read nothing at all.")
        return {
            "site": site, "start_url": start, "home_url": start, "host": host, "finished": True,
            "crawled_at": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
            "requests_made": client.requests, "delay_seconds": client.delay,
            "robots": {"found": robots_found, "sitemaps": robots.sitemaps, "crawl_delay": robots.crawl_delay,
                       "blocks_everything": True},
            "sitemap": {"found": False, "files_read": 0, "urls_listed": 0, "urls": []},
            "pages": [], "blocked_by_robots": [start], "broken_links": [], "capped": False, "pages_not_read": 0,
            "skipped_query_links": 0, "platform_guess": "unknown", "stopped_reason": "", "notes": notes,
        }

    if saved:
        sitemap_urls, sitemap_files = saved["sitemap_urls"], saved["sitemap_files"]
        results, blocked, queued = saved["results"], saved["blocked"], saved["queued"]
        seen, skipped_query, slow_strikes = set(saved["seen"]), [saved["skipped_query"]], saved["slow_strikes"]
        home_url, platform = saved["home_url"], saved["platform_guess"]
    else:
        candidates = list(robots.sitemaps) or [root + "/sitemap.xml", root + "/sitemap_index.xml", root + "/wp-sitemap.xml"]
        sitemap_urls, sitemap_files = read_sitemaps(client, candidates, host, notes)
        results, blocked, queued = {}, [], []
        seen, skipped_query, slow_strikes = set(), [0], 0
        home_url = clean_url(home.url)
        home_parser = parse_page(home) if home.status == 200 else None
        platform = platform_guess(home.text() if home.status == 200 else "", home_parser.generator if home_parser else "")

    def enqueue(url, listed=False):
        url = clean_url(url)
        if url in seen or not same_site(url, host) or not url.startswith(("http://", "https://")):
            return
        path = urlsplit(url).path
        if NOT_PAGES.search(path):
            return
        if urlsplit(url).query and not listed:
            skipped_query[0] += 1
            seen.add(url)
            return
        seen.add(url)
        queued.append(url)

    def save_place():
        if out:
            save_json(state_path(out), {
                "start_url": start, "root": root, "host": host, "home_url": home_url, "platform_guess": platform,
                "sitemap_urls": sitemap_urls, "sitemap_files": sitemap_files, "results": results, "blocked": blocked,
                "queued": queued, "seen": sorted(seen), "skipped_query": skipped_query[0], "slow_strikes": slow_strikes,
                "notes": notes, "requests_made": client.requests})

    if not saved:
        enqueue(home_url)
        for url in sitemap_urls:
            enqueue(url, listed=True)
    focus = [f.strip().lower() for f in focus if f.strip()]
    stopped, out_of_time = "", False
    sitemap_set = set(sitemap_urls)
    first = not saved

    while queued and len(results) < max_pages:
        if deadline and time.monotonic() >= deadline:
            out_of_time = True
            break
        index = 0
        if focus:
            for i, candidate in enumerate(queued):
                if any(term in candidate.lower() for term in focus):
                    index = i
                    break
        url = queued.pop(index)
        if not robots.allowed(url):
            blocked.append(url)
            continue
        if first and home_url == url:
            resp, chain = home, []  # the home page was already fetched while finding the site
            first = False
        else:
            resp, chain = client.get(url), []
        hops = 0
        off_site = ""
        while 300 <= resp.status < 400 and resp.header("location") and hops < 6:
            chain.append({"url": resp.url, "status": resp.status})
            target = safe_join(resp.url, resp.header("location"))
            if not same_site(target, host):
                off_site = target
                break
            if not robots.allowed(target):
                blocked.append(target)
                off_site = target
                break
            resp, hops = client.get(target), hops + 1
        if resp.status in (429, 503):
            slow_strikes += 1
            wait = resp.header("retry-after")
            wait = min(60, int(wait)) if wait.isdecimal() else 10
            if slow_strikes >= 4:
                stopped = f"The site kept asking me to slow down (status {resp.status}), so I stopped early to be polite."
                results[url] = page_record(url, resp, chain, off_site, url in sitemap_set)
                break
            if deadline and time.monotonic() + wait >= deadline:
                queued.insert(0, url)  # try this one again on the next run rather than sit out the wait here
                out_of_time = True
                break
            time.sleep(wait)
            resp = client.get(url)
        try:
            record = page_record(url, resp, chain, off_site, url in sitemap_set)
        except Exception as err:  # one hostile page must not stop the run
            record = page_record(url, Fetched(url, error=f"could not read it ({type(err).__name__})"), chain, "", url in sitemap_set)
        results[url] = record
        for link in record["internal_links"]:
            enqueue(link)
        if len(results) == 1:
            # Under a cap, the home page's own links are the pages that matter most. They go ahead
            # of the sitemap's order, which is often just alphabetical.
            ahead = [link for link in dict.fromkeys(record["internal_links"]) if link in queued]
            queued[:] = ahead + [link for link in queued if link not in set(ahead)]
        if len(results) % SAVE_EVERY == 0:
            save_place()

    if out:
        if out_of_time:
            save_place()
        elif state_path(out).is_file():
            state_path(out).unlink()

    # Who links to whom, and which links are dead.
    final_of = {}
    for url, page in results.items():
        final_of[url] = clean_url(page.get("final_url") or url)
        for hop in page["redirect_chain"]:
            final_of[clean_url(hop["url"])] = final_of[url]
    inbound = {}
    for page in results.values():
        for link in set(page["internal_links"]):
            target = final_of.get(link, link)
            inbound.setdefault(target, set()).add(page["url"])
    broken_links = []
    for url, page in results.items():
        final = final_of[url]
        page["inbound_links"] = len(inbound.get(final, set()) - {url, final})
        if page["status"] >= 400 or page["status"] == 0:
            sources = sorted(inbound.get(final, set()) | inbound.get(url, set()))
            if sources:
                broken_links.append({"target": url, "status": page["status"], "from": sources[:20]})

    pages = list(results.values())
    needs_js = [p["url"] for p in pages if p["needs_javascript"]]
    notes = [n for n in notes if "look empty without JavaScript" not in n and n != stopped]
    if needs_js:
        notes.append(f"{len(needs_js)} page(s) look empty without JavaScript. I do not run JavaScript, so I may have "
                     "missed their text. Google usually does run it, but later and less reliably.")
    if stopped:
        notes.append(stopped)
    if client.refused:
        notes.append(f"Refused to read {len(set(client.refused))} address(es) on a private network or this computer: " + ", ".join(sorted(set(client.refused))[:5]) + ".")
    return {
        "site": site,
        "start_url": start,
        "home_url": home_url,
        "host": host,
        "finished": not out_of_time,
        "crawled_at": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
        "requests_made": client.requests,
        "delay_seconds": client.delay,
        "robots": {"found": robots_found, "sitemaps": robots.sitemaps, "crawl_delay": robots.crawl_delay,
                   "blocks_everything": robots.blocks_everything},
        "sitemap": {"found": bool(sitemap_files), "files_read": sitemap_files, "urls_listed": len(sitemap_urls),
                    "urls": sitemap_urls},
        "pages": pages,
        "blocked_by_robots": sorted(set(blocked)),
        "broken_links": broken_links,
        "capped": bool(queued) and (out_of_time or len(results) >= max_pages),
        "pages_not_read": len(queued),
        "skipped_query_links": skipped_query[0],
        "platform_guess": platform,
        "stopped_reason": stopped,
        "notes": notes,
    }


def page_record(url, resp, chain, off_site, in_sitemap):
    content_type = resp.header("content-type").split(";")[0].strip().lower()
    record = {
        "url": url, "final_url": resp.url if not off_site else off_site, "status": resp.status, "error": resp.error,
        "redirect_chain": chain, "redirects_off_site": bool(off_site), "content_type": content_type,
        "in_sitemap": in_sitemap, "title": None, "description": None, "h1s": [], "headings": [], "word_count": 0,
        "canonical": "", "robots": "", "x_robots": resp.header("x-robots-tag").lower(), "noindex": False,
        "internal_links": [], "external_links": 0, "images_total": 0, "images_missing_alt": [], "images_empty_alt": 0,
        "needs_javascript": False, "excerpt": "", "inbound_links": 0,
        "jsonld": [], "tels": [], "site_name": "", "nosnippet": False,
    }
    if off_site:
        record["status"] = chain[-1]["status"] if chain else resp.status
        return record
    if resp.status != 200 or (content_type and "html" not in content_type):
        record["noindex"] = "noindex" in record["x_robots"]
        return record
    parser = parse_page(resp)
    base = (safe_join(resp.url, parser.base) or resp.url) if parser.base else resp.url
    host = urlsplit(resp.url).netloc
    internal, external = [], 0
    for href in parser.links:
        if re.match(r"^(mailto|tel|javascript|sms|data):", href, re.I) or href.startswith("#"):
            continue
        absolute = safe_join(base, href)
        if not absolute.startswith(("http://", "https://")):
            continue
        if same_site(absolute, host):
            internal.append(absolute)
        else:
            external += 1
    missing = [safe_join(base, i["src"]) or i["src"] for i in parser.images if i["alt"] is None]
    record.update({
        "title": parser.title, "description": parser.description,
        "h1s": [h["text"] for h in parser.headings if h["level"] == 1], "headings": parser.headings,
        "word_count": parser.words, "canonical": safe_join(base, parser.canonical) if parser.canonical else "",
        "robots": parser.robots, "noindex": "noindex" in (parser.robots + " " + record["x_robots"]),
        "internal_links": list(dict.fromkeys(internal)), "external_links": external,
        "images_total": len(parser.images), "images_missing_alt": missing[:50],
        "images_empty_alt": sum(1 for i in parser.images if i["alt"] == ""),
        "needs_javascript": parser.words < 50 and parser.scripts >= 3,
        "excerpt": " ".join(parser.excerpt)[:6000],
        "jsonld": parser.jsonld, "tels": parser.tels, "site_name": parser.site_name,
        "nosnippet": bool(re.search(r"nosnippet|max-snippet\s*:\s*0\b", parser.robots + " " + record["x_robots"])),
    })
    return record


def main():
    ap = argparse.ArgumentParser(description="Read a website politely and record what a search engine sees.")
    ap.add_argument("site", help="the website address")
    ap.add_argument("--out", default="search-work/crawl.json")
    ap.add_argument("--max-pages", type=int, default=200, help="page cap, default 200")
    ap.add_argument("--delay", type=float, default=1.0, help="seconds between requests, default 1, never under 0.5")
    ap.add_argument("--focus", default="", help="comma separated words: pages with these in the address are read first")
    ap.add_argument("--max-seconds", type=int, default=100, help="stop and save your place after this long, default 100; 0 means no limit")
    ap.add_argument("--resume", action="store_true", help="carry on from the place the last run saved")
    args = ap.parse_args()
    cap = args.max_pages
    if cap < 1:
        die("The page cap has to be at least 1.")
    if cap > HARD_PAGE_CAP:
        print(f"That is over the {HARD_PAGE_CAP} page limit this tool keeps to, so I will stop at {HARD_PAGE_CAP}.")
        cap = HARD_PAGE_CAP
    print(f"Reading {args.site}, up to {cap} pages, at least {max(MIN_DELAY, args.delay):g} seconds apart.", flush=True)
    data = crawl(args.site, max_pages=cap, delay=args.delay, focus=args.focus.split(",") if args.focus else (),
                 max_seconds=args.max_seconds, out=args.out, resume=args.resume)
    save_json(args.out, data)
    pages = data["pages"]
    ok = sum(1 for p in pages if p["status"] == 200)
    print(f"Read {len(pages)} pages ({ok} fine, {len(pages) - ok} with a problem) in {data['requests_made']} requests. "
          f"{len(data['blocked_by_robots'])} skipped because robots.txt asks. Sitemap: "
          f"{data['sitemap']['urls_listed'] if data['sitemap']['found'] else 'none found'}.")
    if not data["finished"]:
        print(f"CRAWL NOT FINISHED: {data['pages_not_read']} pages still waiting. Your place is saved. Run the same command again "
              "with --resume to carry on. What is read so far is saved too, so the report can use it.")
    elif data["capped"]:
        print(f"CRAWL FINISHED at the cap, with {data['pages_not_read']} pages unread. Run again with a higher --max-pages to read more.")
    else:
        print("CRAWL FINISHED.")
    for note in data["notes"]:
        print(note)
    print(f"Saved to {args.out}")
    if not any(p["status"] == 200 for p in pages):
        print("No page came back readable. The site may be refusing automated visitors. If this is your site, give me "
              "its folder, or ask your web host to allow this crawler.")
    return 0


if __name__ == "__main__":
    run_main(main)
