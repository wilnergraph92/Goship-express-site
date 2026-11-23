#!/usr/bin/env python3
"""make_images.py: make ad images with your own OpenAI or Gemini key, or write the prompts to a file.

    python make_images.py --prompts prompts.json --out folder              shows the estimate, makes nothing
    python make_images.py --prompts prompts.json --out folder --confirm    makes the images
    python make_images.py --check                                          proves the key works, makes nothing

prompts.json is a list of {"name": "...", "prompt": "...", "shape": "square|portrait|landscape"}.
Keys come from ~/.config/claude-skills/keys.env (OPENAI_API_KEY or GEMINI_API_KEY), which you fill in
yourself. With no key it writes image-prompts.md to paste into any image tool, and spends nothing.
Standard library only.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

KEYS_FILE = Path.home() / ".config" / "claude-skills" / "keys.env"
def test_base(name: str, default: str) -> str:
    """Only the leg tests set this. It may only point at this computer, so a real key can never be sent elsewhere."""
    value = os.environ.get(name, "").rstrip("/")
    try:
        host = urllib.parse.urlsplit(value).hostname or ""
    except ValueError:
        host = ""
    return value if host in ("127.0.0.1", "localhost", "::1") else default


OPENAI_BASE = test_base("OPENAI_BASE_URL_TEST", "https://api.openai.com")
GEMINI_BASE = test_base("GEMINI_BASE_URL_TEST", "https://generativelanguage.googleapis.com")
DEFAULT_COUNT = 3
MAX_WITHOUT_ASKING = 10

# Read on 2026-11-04. OpenAI bills image output at $30 per million tokens, and the per image figures are
# from a calculator built on that rate. Gemini publishes its per image figure directly.
PROVIDERS = {
    "openai": {
        "key": "OPENAI_API_KEY", "model": "gpt-image-2.5-flare", "per_image": 0.053,
        "label": "OpenAI gpt-image-2.5-flare, high quality",
        "source": "https://developers.openai.com/api/docs/pricing and https://costgoat.com/pricing/openai-images",
    },
    "gemini": {
        "key": "GEMINI_API_KEY", "model": "gemini-3.1-flash-image", "per_image": 0.067,
        "label": "Gemini 3.1 Flash Image, 1K",
        "source": "https://ai.google.dev/gemini-api/docs/pricing",
    },
}
OPENAI_SIZES = {"square": "1024x1024", "portrait": "1024x1536", "landscape": "1536x1024"}
GEMINI_SHAPES = {"square": "1:1", "portrait": "4:5", "landscape": "16:9"}


def say(msg: str) -> None:
    print(msg, flush=True)


def tighten_keys() -> None:
    """Only this account should read the key file. Windows has no such mode bits, and keeps a home folder private itself."""
    if os.name == "nt":
        return
    for path, mode in ((KEYS_FILE.parent, 0o700), (KEYS_FILE, 0o600)):
        try:
            path.chmod(mode)
        except OSError:
            pass


def read_keys() -> dict:
    tighten_keys()
    keys = {}
    try:
        text = KEYS_FILE.read_text(encoding="utf-8-sig")
    except OSError:
        return keys
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        value = value.strip().strip('"').strip("'")
        if value:
            keys[name.replace("export ", "").strip()] = value
    return keys


def pick_provider(keys: dict, wanted):
    order = [wanted] if wanted else ["openai", "gemini"]
    for name in order:
        value = keys.get(PROVIDERS[name]["key"], "")
        if value and "your-key" not in value:
            return name, value
    return None, ""


def post_json(url: str, headers: dict, body: dict) -> dict:
    """Plain sentences for the common failures. The key is in a header, so it never reaches a message."""
    req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"), method="POST")
    req.add_header("Content-Type", "application/json")
    for k, v in headers.items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=240) as r:
            return json.loads(r.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            raise RuntimeError("the service rejected the key, or this account has not been verified or set up for billing") from None
        if exc.code == 402 or exc.code == 429:
            raise RuntimeError("the service says this account is out of credit or over its limit") from None
        if exc.code == 400:
            raise RuntimeError("the service refused this prompt. It may need rewording") from None
        raise RuntimeError(f"the service returned status {exc.code}") from None
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise RuntimeError(f"could not reach the service ({getattr(exc, 'reason', exc)})") from None
    except ValueError:
        raise RuntimeError("the service sent back something I could not read") from None


def key_works(name: str, key: str) -> bool:
    """List the models. It costs nothing and proves the key, though not that billing is set up."""
    if name == "openai":
        req = urllib.request.Request(f"{OPENAI_BASE}/v1/models", headers={"Authorization": f"Bearer {key}"})
    else:
        req = urllib.request.Request(f"{GEMINI_BASE}/v1beta/models", headers={"x-goog-api-key": key})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.status == 200


def do_check(wanted) -> int:
    name, key = pick_provider(read_keys(), wanted)
    if not name:
        say(f"No OpenAI or Gemini key is set in {KEYS_FILE}. That is fine: you get prompts in a file instead.")
        return 3
    try:
        key_works(name, key)
    except urllib.error.HTTPError as exc:
        say(f"{name} rejected the key (status {exc.code}). Make a new one and put it in your keys file.")
        return 1
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        say(f"Could not reach {name} ({getattr(exc, 'reason', exc)}). Check your connection and try again.")
        return 1
    say(f"The {name} key works. Making images still needs billing set up on that account, and nothing was spent just now.")
    return 0


def make_openai(item: dict, key: str, model: str) -> bytes:
    data = post_json(f"{OPENAI_BASE}/v1/images/generations", {"Authorization": f"Bearer {key}"}, {
        "model": model, "prompt": item["prompt"], "n": 1, "quality": "high",
        "size": OPENAI_SIZES.get(item.get("shape", "square"), "1024x1024")})
    try:
        return base64.b64decode(data["data"][0]["b64_json"])
    except (KeyError, IndexError, TypeError, ValueError):
        raise RuntimeError("no image came back") from None


def make_gemini(item: dict, key: str, model: str) -> bytes:
    data = post_json(f"{GEMINI_BASE}/v1beta/models/{model}:generateContent", {"x-goog-api-key": key}, {
        "contents": [{"role": "user", "parts": [{"text": item["prompt"]}]}],
        "generationConfig": {"responseModalities": ["IMAGE"],
                             "imageConfig": {"aspectRatio": GEMINI_SHAPES.get(item.get("shape", "square"), "1:1")}}})
    try:
        for part in data["candidates"][0]["content"]["parts"]:
            inline = part.get("inlineData") or part.get("inline_data")
            if inline and inline.get("data"):
                return base64.b64decode(inline["data"])
    except (KeyError, IndexError, TypeError, ValueError):
        pass
    raise RuntimeError("no image came back. The model may have declined this prompt")


def write_prompts_file(items: list, folder: Path) -> Path:
    lines = ["# Image Prompts", "", "Paste each one into any image tool. No key was found, so nothing was generated and nothing was spent.", ""]
    for item in items:
        lines += [f"## {item.get('name', 'Image')} ({item.get('shape', 'square')})", "", item["prompt"], ""]
    path = folder / "image-prompts.md"
    path.write_text("\n".join(lines), encoding="utf-8")
    return path


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", str(text).lower()).strip("-")[:50] or "image"


def main() -> int:
    ap = argparse.ArgumentParser(description="Make ad images, or write the prompts to a file.")
    ap.add_argument("--prompts")
    ap.add_argument("--out")
    ap.add_argument("--check", action="store_true", help="prove the key works, and stop")
    ap.add_argument("--provider", choices=sorted(PROVIDERS))
    ap.add_argument("--model", help="use a different model from the same provider")
    ap.add_argument("--count", type=int, help=f"how many prompts to use, default {DEFAULT_COUNT}")
    ap.add_argument("--max-usd", type=float)
    ap.add_argument("--confirm", action="store_true", help="the person said yes to the estimate")
    ap.add_argument("--allow-larger", action="store_true", help=f"the person said yes to more than {MAX_WITHOUT_ASKING}")
    a = ap.parse_args()
    if a.check:
        return do_check(a.provider)
    if not a.prompts or not a.out:
        say("Give me --prompts and --out.")
        return 2
    try:
        items = json.loads(Path(a.prompts).read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as exc:
        say(f"I could not read the prompts file: {exc}")
        return 2
    items = [i for i in (items if isinstance(items, list) else []) if isinstance(i, dict) and i.get("prompt")]
    if not items:
        say("The prompts file needs a list of items that each have a prompt.")
        return 2
    folder = Path(a.out)
    folder.mkdir(parents=True, exist_ok=True)
    name, key = pick_provider(read_keys(), a.provider)
    if not name:
        path = write_prompts_file(items, folder)
        say(f"No OpenAI or Gemini key found, so I wrote {len(items)} prompts to {path}. Nothing was spent.")
        say(f"To generate images, add OPENAI_API_KEY=... or GEMINI_API_KEY=... to {KEYS_FILE} in a text editor. "
            "Neither service has a free tier for these image models. Do not paste a key into this chat.")
        return 0
    count = min(a.count or DEFAULT_COUNT, len(items))
    provider = PROVIDERS[name]
    if count > MAX_WITHOUT_ASKING and not a.allow_larger:
        say(f"That is {count} images. Ask the person first, then add --allow-larger.")
        return 4
    est = count * provider["per_image"]
    cap = a.max_usd if a.max_usd is not None else round(est * 1.2 + 0.005, 2)
    say(f"Provider: {provider['label']}. Estimate: {count} images at about ${provider['per_image']:.3f} each = about ${est:.2f}. Estimate limit: ${cap:.2f}. This counts images at the price above, not the real charge, and larger shapes can cost more.")
    say(f"Prices: {provider['source']}")
    if est > cap:
        say("The estimate is above the estimate limit, so I did not start. Lower --count or raise --max-usd after asking the person.")
        return 4
    if not a.confirm:
        say("Not started. Show this to the person. If they say yes, run the same command with --confirm.")
        return 4
    model = a.model or provider["model"]
    make = make_openai if name == "openai" else make_gemini
    made, failed = [], []
    for item in items[:count]:
        label = item.get("name") or item["prompt"][:40]
        if len(made) * provider["per_image"] + provider["per_image"] > cap:
            say("Stopped at the estimate limit.")
            break
        try:
            data = make(item, key, model)
            path = folder / f"{len(made) + 1:02d}-{slug(label)}.png"
            path.write_bytes(data)
            made.append({"name": label, "file": str(path), "prompt": item["prompt"]})
            say(f"Made {path.name}.")
        except RuntimeError as exc:
            failed.append({"name": label, "why": str(exc)})
            say(f"Could not make {label}: {exc}.")
    (folder / "images.json").write_text(json.dumps({"provider": name, "model": model, "made": made, "failed": failed, "estimate_usd": round(len(made) * provider["per_image"], 3)}, indent=1, ensure_ascii=False), encoding="utf-8")
    say(f"Made {len(made)}, failed {len(failed)}. About ${len(made) * provider['per_image']:.2f} on your {name} account.")
    return 0 if made else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # a stranger should never see a stack trace
        say(f"Something went wrong: {exc}. Tell me what you were doing and I will look.")
        sys.exit(1)
