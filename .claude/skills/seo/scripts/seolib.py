"""seolib.py: small helpers shared by the seo scripts. Standard library only."""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

KEYS_FILE = Path.home() / ".config" / "claude-skills" / "keys.env"

# The share of people who click a result at each position on Google. Round numbers, set
# near or a little under public click studies, because AI answers at the top of the page
# have been pulling clicks down. Used only for estimates, and always labeled as one.
CLICK_RATE = {1: 0.25, 2: 0.15, 3: 0.10, 4: 0.07, 5: 0.05, 6: 0.04, 7: 0.03, 8: 0.02, 9: 0.02, 10: 0.015}
RATE_PAGE_TWO = 0.01  # positions 11 to 20
RATE_DEEPER = 0.002  # position 21 and lower

STOPWORDS = {
    "a", "an", "and", "are", "as", "at", "be", "best", "by", "can", "do", "does", "for", "from", "get", "how",
    "i", "in", "is", "it", "me", "my", "near", "of", "on", "or", "our", "the", "to", "top", "us", "we", "what",
    "when", "where", "who", "why", "with", "you", "your", "home", "page", "services", "service", "www", "html", "htm",
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


def click_rate(position: float) -> float:
    """Estimated click rate for an average position."""
    pos = max(1, int(round(float(position or 0)))) if position else 100
    if pos in CLICK_RATE:
        return CLICK_RATE[pos]
    return RATE_PAGE_TWO if pos <= 20 else RATE_DEEPER


def target_position(position: float) -> int:
    """Where the estimate assumes a page can move to: first page to 3, second page to 8."""
    return 3 if position <= 10.5 else 8


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


def short_path(url: str) -> str:
    parts = urlsplit(url)
    return (parts.path or "/") + (("?" + parts.query) if parts.query else "")


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
    """The words that say what a page is about: title, main headings and address."""
    h1s = " ".join(page.get("h1s") or [])
    path = urlsplit(page.get("url") or "").path.replace("-", " ").replace("_", " ").replace("/", " ")
    return words_of(f"{page.get('title') or ''} {h1s} {path}")


def covered(topic_words: set, own_words: set, share: float = 0.6) -> bool:
    if not topic_words:
        return True
    return len(topic_words & own_words) / len(topic_words) >= share
