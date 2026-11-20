"""searchlib.py: small helpers shared by the search skills. Standard library only."""
from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import date
from pathlib import Path
from urllib.parse import urlsplit

KEYS_FILE = Path.home() / ".config" / "claude-skills" / "keys.env"
SPEND_FILE = KEYS_FILE.parent / "search-spend.json"

STOPWORDS = {
    "a", "an", "and", "are", "as", "at", "be", "best", "by", "can", "do", "does", "for", "from", "get", "how",
    "i", "in", "is", "it", "me", "my", "near", "of", "on", "or", "our", "the", "to", "top", "us", "we", "what",
    "when", "where", "who", "why", "with", "you", "your", "home", "page", "services", "service", "www", "html", "htm",
    "much", "should", "will", "need", "much", "cost", "costs",
}


def setup_output() -> None:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass


def die(message: str, code: int = 1) -> None:
    """Stop with one plain sentence and no stack trace."""
    print(message, flush=True)
    sys.exit(code)


def run_main(main) -> None:
    """Run a script's main so any surprise ends in a plain sentence."""
    setup_output()
    try:
        sys.exit(main() or 0)
    except KeyboardInterrupt:
        die("Stopped.")
    except SystemExit:
        raise
    except Exception as exc:  # the promise is: never a stack trace
        die(f"This step failed: {type(exc).__name__}: {exc}. Nothing was changed. Try it once more; if it fails "
            "again, tell Claude what you were doing and it can look into this step by hand.")


POSIX = os.name != "nt"  # Windows keeps these private through the user folder's own permissions


def lock_down_keys() -> None:
    """Folder 700 and file 600 on every run, where the system has such modes. Never stops a run."""
    if not POSIX:
        return
    for path, mode in ((KEYS_FILE.parent, 0o700), (KEYS_FILE, 0o600)):
        try:
            if path.exists():
                os.chmod(path, mode)
        except OSError:
            pass


def read_keys() -> dict:
    """Read ~/.config/claude-skills/keys.env. Values are never printed."""
    lock_down_keys()
    out = {}
    try:
        text = KEYS_FILE.read_text(encoding="utf-8-sig")
    except OSError:
        return out
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[7:]
        key, _, value = line.partition("=")
        value = value.strip().strip('"').strip("'")
        if value:
            out[key.strip()] = value
    return out


def save_json(path, data) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=1, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, path)


def load_json(path, what: str = "file"):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except OSError:
        die(f"I could not find the {what} at {path}. Run the step that makes it first.")
    except ValueError:
        die(f"The {what} at {path} is damaged. Run the step that makes it again.")


# ------------------------------------------------------------------ talking to services


def api_base(env_name: str, default: str) -> str:
    """A base address can be swapped only for one on this computer, which is how the tests run against stubs.
    Anything else is ignored, so a key can never be sent somewhere a page or a file suggested."""
    value = os.environ.get(env_name, "").strip().rstrip("/")
    if value:
        host = (urlsplit(value).hostname or "").lower()
        if host in ("127.0.0.1", "localhost") and urlsplit(value).scheme == "http":
            return value
    return default


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never follow a redirect with a key or token attached."""

    def redirect_request(self, *args, **kwargs):
        return None


_OPENER = urllib.request.build_opener(_NoRedirect())


class ServiceError(Exception):
    pass


def http_json(method: str, url: str, headers=None, body=None, timeout: int = 90, service: str = "the service"):
    """Returns (status, parsed JSON or None). Network trouble raises ServiceError with a plain sentence."""
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={"User-Agent": "search-skill/1.0",
                                                                         **({"Content-Type": "application/json"} if data else {}),
                                                                         **(headers or {})})
    try:
        with _OPENER.open(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", "replace")
            return resp.status, (json.loads(raw) if raw.strip() else None)
    except urllib.error.HTTPError as err:
        if 300 <= err.code < 400:
            raise ServiceError(f"{service} tried to send this request somewhere else, so I stopped and nothing was sent on") from None
        try:
            payload = json.loads(err.read().decode("utf-8", "replace") or "null")
        except Exception:
            payload = None
        return err.code, payload
    except urllib.error.URLError as err:
        raise ServiceError(f"I could not reach {service} ({err.reason}). Check the connection and try again") from None
    except (TimeoutError, OSError) as err:
        raise ServiceError(f"{service} did not answer in time ({err}). Try again in a minute") from None
    except ValueError:
        raise ServiceError(f"{service} answered with something that is not data I can read") from None


def post_form(url: str, fields: dict, timeout: int = 60, service: str = "Google"):
    data = urllib.parse.urlencode(fields).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST", headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        with _OPENER.open(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as err:
        try:
            return err.code, json.loads(err.read().decode("utf-8") or "{}")
        except Exception:
            return err.code, {}
    except urllib.error.URLError as err:
        raise ServiceError(f"I could not reach {service} ({err.reason})") from None


# ------------------------------------------------------------------ spend, kept on this computer


def month_used(vendor: str) -> float:
    try:
        book = json.loads(SPEND_FILE.read_text(encoding="utf-8"))
        return float((book.get(date.today().strftime("%Y-%m")) or {}).get(vendor, 0))
    except (OSError, ValueError, AttributeError, TypeError):
        return 0.0


def add_used(vendor: str, amount: float) -> None:
    try:
        book = json.loads(SPEND_FILE.read_text(encoding="utf-8"))
        if not isinstance(book, dict):
            book = {}
    except (OSError, ValueError):
        book = {}
    month = date.today().strftime("%Y-%m")
    row = book.setdefault(month, {})
    row[vendor] = round(float(row.get(vendor, 0)) + amount, 6)
    SPEND_FILE.parent.mkdir(parents=True, exist_ok=True)
    SPEND_FILE.write_text(json.dumps(book), encoding="utf-8")


def read_ceiling(keys: dict, name: str, default=None):
    """A monthly ceiling from a line the owner writes in the key file. No flag changes it."""
    raw = keys.get(name, "")
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError:
        return None
    return value if 0 < value < float("inf") else None


# ------------------------------------------------------------------ words and addresses


def page_key(url: str) -> str:
    """A URL reduced to host and path so http, https, www and a trailing slash all match."""
    parts = urlsplit(url if "//" in url else "//" + url)
    host = (parts.netloc or "").lower()
    if host.startswith("www."):
        host = host[4:]
    path = parts.path or "/"
    if len(path) > 1:
        path = path.rstrip("/")
    return host + path


def bare_domain(url_or_host: str) -> str:
    text = url_or_host if "//" in (url_or_host or "") else "//" + (url_or_host or "")
    host = (urlsplit(text).hostname or "").lower()
    return host[4:] if host.startswith("www.") else host


def words_of(text: str) -> set:
    """Meaningful lowercase words, with plain plurals folded, for loose topic matching."""
    found = set()
    for word in re.findall(r"[a-z0-9]+", (text or "").lower()):
        if word in STOPWORDS or len(word) < 2:
            continue
        if len(word) > 3 and word.endswith("s") and not word.endswith("ss"):
            word = word[:-1]
        found.add(word)
    return found


def page_words(page: dict) -> set:
    """The words that say what a page is about: title, headings and address."""
    heads = " ".join(h.get("text", "") for h in (page.get("headings") or [])[:12])
    path = urlsplit(page.get("url") or "").path.replace("-", " ").replace("_", " ").replace("/", " ")
    return words_of(f"{page.get('title') or ''} {heads} {path}")


def share_covered(topic_words: set, own_words: set) -> float:
    if not topic_words:
        return 1.0
    return len(topic_words & own_words) / len(topic_words)
