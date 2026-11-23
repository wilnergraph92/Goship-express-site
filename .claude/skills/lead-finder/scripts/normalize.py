#!/usr/bin/env python3
"""normalize.py: turn raw posts and comments from every platform into one list of people and what each one said.

    python normalize.py --raw lead-finder-out/<name>/raw --out lead-finder-out/<name>
    python normalize.py --manual pasted.json --out lead-finder-out/<name>          the no-Apify route
    python normalize.py --raw ... --manual ... --out ...                            both

Standard library only. It reads raw/manifest.json written by apify_run.py, or a list of things the
person pasted by hand. It writes mentions.jsonl (one line per post or comment) and people.json (one
entry per person, with every word they said and the link to where they said it).

It never adds words. A post with no author or no text is dropped and counted, never filled in.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

PLATFORMS = ("instagram", "tiktok", "linkedin", "facebook", "x", "youtube", "other")
URL_RX = re.compile(r"https?://[^\s<>\"')\]]+", re.I)
EMAIL_RX = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,24}")


def say(msg: str) -> None:
    print(msg, flush=True)


def s(value) -> str:
    if value is None:
        return ""
    if isinstance(value, (int, float)):
        return str(value)
    return value.strip() if isinstance(value, str) else ""


def d(value) -> dict:
    return value if isinstance(value, dict) else {}


def first(*values) -> str:
    for v in values:
        if s(v):
            return s(v)
    return ""


def link_of(value) -> str:
    """A bio link can be a string, an object with a link, or a list of either."""
    if isinstance(value, str):
        return value.strip() if value.strip().lower().startswith(("http://", "https://", "www.")) else ""
    if isinstance(value, dict):
        return first(link_of(value.get("url")), link_of(value.get("link")), link_of(value.get("href")))
    if isinstance(value, list):
        for v in value:
            got = link_of(v)
            if got:
                return got
    return ""


def clean_profile(url: str) -> str:
    """Drop tracking bits from a profile link, so the same person is one person."""
    url = s(url)
    return url.split("?")[0].rstrip("/") + "/" if url.startswith("http") else ""


def mention(platform, kind, handle, name, profile_url, text, source_url, date="", bio="", website="", headline=""):
    return {"platform": platform, "kind": kind, "handle": s(handle).lstrip("@"), "name": s(name),
            "profile_url": profile_url, "text": s(text), "source_url": s(source_url), "date": s(date),
            "bio": s(bio), "website": s(website), "headline": s(headline)}


# ---------------------------------------------------------------- one function per platform

def from_instagram(item: dict, kind: str) -> list:
    out = []
    owner = d(item.get("owner"))
    handle = first(item.get("ownerUsername"), owner.get("username"), item.get("username"))
    name = first(item.get("ownerFullName"), owner.get("full_name"), item.get("fullName"))
    profile = f"https://www.instagram.com/{handle}/" if handle else ""
    if kind == "comments":
        out.append(mention("instagram", "comment", handle, name, profile, item.get("text"),
                           first(item.get("commentUrl"), item.get("postUrl"), item.get("url")), item.get("timestamp")))
        return out
    text = first(item.get("caption"), item.get("text"))
    url = first(item.get("url"), item.get("postUrl"))
    out.append(mention("instagram", "post", handle, name, profile, text, url, item.get("timestamp"),
                       bio=item.get("biography"), website=first(item.get("externalUrl"), link_of(item.get("externalUrls")))))
    for c in item.get("latestComments") or []:
        c = d(c)
        ch = first(c.get("ownerUsername"), d(c.get("owner")).get("username"))
        out.append(mention("instagram", "comment", ch, first(d(c.get("owner")).get("full_name")),
                           f"https://www.instagram.com/{ch}/" if ch else "", c.get("text"), url, c.get("timestamp")))
    return out


def from_tiktok(item: dict, kind: str) -> list:
    if kind == "comments":
        handle = first(item.get("uniqueId"), d(item.get("user")).get("uniqueId"))
        return [mention("tiktok", "comment", handle, first(d(item.get("user")).get("nickname")),
                        f"https://www.tiktok.com/@{handle}" if handle else "", item.get("text"),
                        first(item.get("videoWebUrl"), item.get("url")), item.get("createTimeISO"))]
    author = d(item.get("authorMeta"))
    handle = first(author.get("name"), author.get("uniqueId"))
    return [mention("tiktok", "post", handle, author.get("nickName"),
                    first(author.get("profileUrl"), f"https://www.tiktok.com/@{handle}" if handle else ""),
                    item.get("text"), first(item.get("webVideoUrl"), item.get("url")), item.get("createTimeISO"),
                    bio=author.get("signature"), website=link_of(author.get("bioLink")))]


def from_linkedin(item: dict, kind: str) -> list:
    if kind == "comments":
        actor = d(item.get("actor"))
        url = clean_profile(actor.get("linkedinUrl"))
        handle = url.rstrip("/").split("/")[-1] if url else first(actor.get("id"))
        return [mention("linkedin", "comment", handle, actor.get("name"), url, first(item.get("commentary"), item.get("text")),
                        item.get("linkedinUrl"), item.get("createdAt"), headline=actor.get("position"))]
    author = d(item.get("author"))
    url = clean_profile(author.get("linkedinUrl"))
    handle = first(author.get("publicIdentifier"), author.get("universalName"), url.rstrip("/").split("/")[-1] if url else "")
    return [mention("linkedin", "post", handle, author.get("name"), url, first(item.get("content"), item.get("text")),
                    item.get("linkedinUrl"), d(item.get("postedAt")).get("date"),
                    website=link_of(author.get("website")), headline=author.get("info"))]


def real_fb_id(value: str) -> bool:
    return bool(value) and "*" not in value


def clean_fb(url: str) -> str:
    """Facebook profile links keep their id in ?id=, so that part stays; other tracking is dropped."""
    url = s(url)
    if "profile.php" in url and "id=" in url:
        pid = url.split("id=")[1].split("&")[0]
        return f"https://www.facebook.com/profile.php?id={pid}"
    return clean_profile(url)


def from_facebook(item: dict, kind: str) -> list:
    out = []
    if kind == "comments":
        pid = first(item.get("profileId"))
        url = clean_profile(item.get("profileUrl")) if "*" not in s(item.get("profileUrl")) else ""
        handle = pid if real_fb_id(pid) else (url.rstrip("/").split("/")[-1] if url else "")
        out.append(mention("facebook", "comment", handle, item.get("profileName"), url, item.get("text"),
                           first(item.get("commentUrl"), item.get("facebookUrl")), item.get("date")))
        return out
    # Group posts carry the author in "user"; keyword search posts carry it in "author", with a profile link.
    user = d(item.get("user")) or d(item.get("author"))
    uid = first(user.get("id"))
    handle = uid if real_fb_id(uid) else ""
    name = first(user.get("name")) if "*" not in s(user.get("name")) else ""
    link = s(user.get("profileUrl"))
    profile = clean_fb(link) if link and "*" not in link else (f"https://www.facebook.com/{uid}/" if handle else "")
    if not handle and profile:
        handle = profile.split("id=")[-1] if "id=" in profile else profile.rstrip("/").split("/")[-1]
    out.append(mention("facebook", "post", handle, name, profile,
                       first(item.get("text"), item.get("message"), item.get("postText")), item.get("url"),
                       first(item.get("time"), item.get("timestamp"))))
    for c in item.get("topComments") or []:
        out += from_facebook(d(c), "comments")
    return out


def from_x(item: dict, kind: str) -> list:
    author = d(item.get("author"))
    handle = first(author.get("userName"), author.get("screen_name"))
    return [mention("x", "reply" if item.get("isReply") else "post", handle, author.get("name"),
                    first(author.get("url"), f"https://x.com/{handle}" if handle else ""), item.get("text"),
                    first(item.get("url"), item.get("twitterUrl")), item.get("createdAt"),
                    bio=author.get("description"), website=x_website(author))]


def x_website(author: dict) -> str:
    """The link on an X profile sits in entities.url.urls as expanded_url, when there is one."""
    for u in d(d(author.get("entities")).get("url")).get("urls") or []:
        got = link_of(d(u).get("expanded_url"))
        if got:
            return got
    return link_of(author.get("website"))


def from_youtube(item: dict, kind: str) -> list:
    if kind == "comments":
        author = first(item.get("author"))
        handle = author.lstrip("@")
        vid = first(item.get("videoId"))
        url = first(item.get("pageUrl"), f"https://www.youtube.com/watch?v={vid}" if vid else "")
        return [mention("youtube", "comment", handle, author, f"https://www.youtube.com/{author}" if author.startswith("@") else "",
                        first(item.get("comment"), item.get("text")), url, item.get("date"))]
    words = " ".join(x for x in (s(item.get("title")), s(item.get("text"))) if x)
    channel = first(item.get("channelUrl"))
    handle = channel.rstrip("/").split("/")[-1] if channel else first(item.get("channelName"))
    return [mention("youtube", "post", handle, item.get("channelName"), clean_profile(channel), words, item.get("url"),
                    item.get("date"), bio=item.get("channelDescription"), website=link_of(item.get("channelDescriptionLinks")))]


READERS = {"instagram": from_instagram, "tiktok": from_tiktok, "linkedin": from_linkedin,
           "facebook": from_facebook, "x": from_x, "youtube": from_youtube}


def from_manual(item: dict) -> list:
    platform = s(item.get("platform")).lower() or "other"
    if platform not in PLATFORMS:
        platform = "other"
    handle = first(item.get("handle"), item.get("name"))
    return [mention(platform, s(item.get("kind")) or "post", handle, item.get("name"), s(item.get("profile_url")),
                    item.get("text"), item.get("source_url"), item.get("date"), bio=item.get("bio"), website=item.get("website"))]


# ---------------------------------------------------------------- grouping

def person_key(m: dict) -> str:
    return f"{m['platform']}:{m['handle'].lower()}"


def group(mentions: list) -> list:
    people: dict = {}
    for m in mentions:
        key = person_key(m)
        p = people.setdefault(key, {"id": key, "platform": m["platform"], "handle": m["handle"], "name": "", "profile_url": "",
                                    "bio": "", "website": "", "headline": "", "mentions": []})
        for field in ("name", "profile_url", "bio", "website", "headline"):
            if not p[field] and m[field]:
                p[field] = m[field]
        p["mentions"].append({"kind": m["kind"], "text": m["text"], "source_url": m["source_url"], "date": m["date"]})
    out = []
    for p in people.values():
        if not p["website"]:
            for url in URL_RX.findall(p["bio"]):
                p["website"] = url.rstrip(".,;")
                break
        p["mention_count"] = len(p["mentions"])
        p["words"] = sum(len(m["text"].split()) for m in p["mentions"])
        p["emails_in_own_words"] = sorted({e.lower() for e in EMAIL_RX.findall(p["bio"] + " " + " ".join(m["text"] for m in p["mentions"]))})
        out.append(p)
    out.sort(key=lambda p: (-p["words"], p["id"]))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Turn raw posts and comments into one list of people.")
    ap.add_argument("--raw", help="the raw folder with manifest.json from apify_run.py")
    ap.add_argument("--manual", help="a JSON list of posts or comments the person pasted by hand")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    if not a.raw and not a.manual:
        say("Give me --raw (from an Apify run) or --manual (posts you pasted), or both.")
        return 2
    mentions, dropped, bad_files = [], 0, []
    try:
        if a.raw:
            raw = Path(a.raw)
            try:
                manifest = json.loads((raw / "manifest.json").read_text(encoding="utf-8"))
            except (OSError, ValueError):
                say(f"I could not read {raw / 'manifest.json'}. Run apify_run.py first, or use --manual.")
                return 2
            for step in manifest.get("steps", []):
                reader = READERS.get(step.get("platform"))
                try:
                    items = json.loads((raw.parent / step["file"]).read_text(encoding="utf-8")) if reader else []
                except (OSError, ValueError, KeyError):
                    bad_files.append(step.get("file", "?"))
                    continue
                for item in items if isinstance(items, list) else []:
                    if not isinstance(item, dict) or item.get("error") or item.get("errorCode"):
                        dropped += 1
                        continue
                    try:
                        mentions += reader(item, step.get("kind", "posts"))
                    except Exception:
                        dropped += 1
        if a.manual:
            try:
                items = json.loads(Path(a.manual).read_text(encoding="utf-8-sig"))
            except (OSError, ValueError) as exc:
                say(f"I could not read {a.manual}: {exc}")
                return 2
            for item in items if isinstance(items, list) else []:
                if isinstance(item, dict):
                    mentions += from_manual(item)
    except KeyboardInterrupt:
        say("Stopped.")
        return 1
    kept, seen = [], set()
    for m in mentions:
        if not m["handle"] or not m["text"]:
            dropped += 1
            continue
        key = (person_key(m), m["text"][:200], m["source_url"])
        if key in seen:
            continue
        seen.add(key)
        kept.append(m)
    people = group(kept)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    with (out / "mentions.jsonl").open("w", encoding="utf-8") as fh:
        for m in kept:
            fh.write(json.dumps(m, ensure_ascii=False) + "\n")
    (out / "people.json").write_text(json.dumps(people, indent=1, ensure_ascii=False), encoding="utf-8")
    by = {}
    for p in people:
        by[p["platform"]] = by.get(p["platform"], 0) + 1
    say(f"{len(kept)} posts and comments from {len(people)} people: " + (", ".join(f"{k} {v}" for k, v in sorted(by.items())) or "none") + ".")
    say(f"Dropped {dropped} with no author or no words, or that the actor marked as an error.")
    if bad_files:
        say(f"Could not read: {', '.join(bad_files)}")
    say(f"Wrote {out / 'people.json'} and {out / 'mentions.jsonl'}.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # a stranger should never see a stack trace
        print(f"Something went wrong: {exc}. Tell me what you were doing and I will look.")
        sys.exit(1)
