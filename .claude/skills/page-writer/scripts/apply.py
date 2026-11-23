#!/usr/bin/env python3
"""apply.py: make an approved change on the owner's site. Standard library only.

Nothing happens to a site without a yes to that one specific change, recorded by id and bound
to the exact text. Change one word after the yes and the yes no longer counts.

A change to a live page needs more than a yes in chat. review-live writes an approval code to
~/.config/claude-skills/seo-approval-code.txt and opens it for the owner, and it never prints the code,
so Claude is not handed it. The owner runs approve-live themselves. This is a strong check, not a
lock: the script cannot tell who ran the line, and anyone who sets out to could open that file.

    python apply.py check-wp
    python apply.py check     --changes seo-work/changes.json
    python apply.py approve   --changes seo-work/changes.json --id C1 --said "yes to C1"
    python apply.py review-live  --changes seo-work/changes.json --id C1 [C2 ...] [--undo]
    python apply.py approve-live --changes seo-work/changes.json --id C1 [C2 ...] --code THE-CODE [--undo]
    python apply.py folder    --changes seo-work/changes.json --site <folder> --id C1 [C2 ...]
    python apply.py wordpress --changes seo-work/changes.json --id C1 [C2 ...]
    python apply.py paste     --changes seo-work/changes.json --out seo-work/paste-ready.md
    python apply.py undo      --changes seo-work/changes.json --id C1 --said "undo C1" [--site <folder>]

New pages are only ever drafts. There is no way to publish from here: this script never sends
any status but draft, and it never runs git. A title or description on a page that is already
live changes the live page, and so does putting one back, so both need the owner's own approval.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import html
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

KEYS_FILE = Path.home() / ".config" / "claude-skills" / "keys.env"
PLACEHOLDER = re.compile(r"\[\s*ASK OWNER", re.I)
TYPES = ("title", "description", "new_page")
NOT_LIVE = ("draft", "pending", "auto-draft")  # any other WordPress status can be seen, now or on a schedule
CODE_ROUNDS = 200_000
TEXT_SUFFIXES = {".html", ".htm", ".md", ".mdx", ".markdown", ".astro", ".njk", ".liquid", ".hbs", ".erb", ".php", ".vue", ".svelte", ".jsx", ".tsx"}
SKIP_DIRS = {".git", "node_modules", "dist", "build", "_site", ".next", ".cache", "vendor", "__pycache__", ".astro", "out"}
SEO_META_KEYS = {
    "yoast": {"title": "_yoast_wpseo_title", "description": "_yoast_wpseo_metadesc"},
    "rank math": {"title": "rank_math_title", "description": "rank_math_description"},
    "seopress": {"title": "_seopress_titles_title", "description": "_seopress_titles_desc"},
}


def out(message=""):
    print(message, flush=True)


def load(path):
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except OSError:
        out(f"I could not find the changes file at {path}. Draft the changes first.")
        sys.exit(1)
    except ValueError:
        out(f"The changes file at {path} is not valid JSON. Fix it or draft the changes again.")
        sys.exit(1)
    changes = data.get("changes") if isinstance(data, dict) else data
    if not isinstance(changes, list):
        out("The changes file has no list of changes.")
        sys.exit(1)
    return {str(c.get("id")): c for c in changes}


def state_file(changes_path, name):
    return Path(changes_path).resolve().parent / name


def read_state(changes_path, name):
    try:
        return json.loads(state_file(changes_path, name).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def write_state(changes_path, name, data):
    path = state_file(changes_path, name)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=1, ensure_ascii=False), encoding="utf-8")


def fingerprint(change):
    """Binds a yes to the exact words. Any edit after the yes changes this and voids it."""
    keep = {k: change.get(k) for k in ("id", "type", "page_url", "before", "after", "slug", "body", "body_format", "file")}
    return hashlib.sha256(json.dumps(keep, sort_keys=True, ensure_ascii=False).encode("utf-8")).hexdigest()


def problems_with(change):
    found = []
    kind = change.get("type")
    if kind not in TYPES:
        found.append(f"its type is '{kind}', and I only handle title, description and new_page")
    if not (change.get("after") or "").strip():
        found.append("it has no new text")
    text = f"{change.get('after') or ''} {change.get('body') or ''}"
    if PLACEHOLDER.search(text):
        found.append("it still has an [ASK OWNER] blank. Get the real fact from the owner first")
    if kind in ("title", "description") and not change.get("page_url"):
        found.append("it does not say which page")
    if kind == "new_page":
        if not (change.get("body") or "").strip():
            found.append("it has no page text")
        if not change.get("slug"):
            found.append("it has no address (slug)")
        elif not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", change["slug"]):
            found.append("its address (slug) should be lowercase words joined by hyphens")
        if not change.get("facts_from"):
            found.append("it does not list where its facts came from (facts_from), and I will not place a page with unsourced claims")
    return found


LIVE_REFUSAL = ("this page is live, so the change would show on the live site right away, and only the owner can approve that. "
                "A yes in chat does not count. Run review-live for this change and give them the line it prints")


def gate(change, approvals, live=None, need_live=False):
    """The refusal. Returns a reason this change may not run, or None.

    live holds what the owner approved with their code. need_live means this change touches a live
    page, and then nothing but that approval of this exact text will do.
    """
    cid = str(change.get("id"))
    problems = problems_with(change)
    if problems:
        return "; ".join(problems)
    owner = (live or {}).get(cid)
    owner_ok = bool(owner) and owner.get("sha") == fingerprint(change)
    stale_owner = "the text changed after the owner approved it, so that approval no longer counts. Show the new text and run review-live again"
    if need_live:
        if owner_ok:
            return None
        return stale_owner if owner else LIVE_REFUSAL
    if owner_ok:
        return None
    yes = approvals.get(cid)
    if owner and not yes:
        return stale_owner
    if not yes:
        return "nobody has said yes to this one"
    if yes.get("sha") != fingerprint(change):
        return "the text changed after the yes, so the yes no longer counts. Show the new text and ask again"
    return None


# ------------------------------------------------------------------ commands: check, approve


def cmd_check(args):
    changes = load(args.changes)
    approvals = read_state(args.changes, "approvals.json")
    live = read_state(args.changes, "live-approvals.json")
    for cid, change in changes.items():
        problems = problems_with(change)
        after = change.get("after") or ""
        out(f"{cid} | {change.get('type')} | {change.get('page_url') or change.get('slug') or ''}")
        out(f"   now: {change.get('before') or '(none)'}")
        out(f"   new: {after} ({len(after)} characters)")
        if change.get("type") == "title" and len(after) > 60:
            out("   note: over 60 characters, so Google will likely cut it off")
        if change.get("type") == "description" and len(after) > 160:
            out("   note: over 160 characters, so Google will likely cut it off")
        for problem in problems:
            out(f"   cannot use yet: {problem}")
        yes = approvals.get(cid)
        if (live.get(cid) or {}).get("sha") == fingerprint(change):
            out("   the owner approved this exact text for a live page")
        if yes and yes.get("sha") == fingerprint(change):
            out(f"   approved: \"{yes.get('said')}\"")
        elif yes:
            out("   the text changed after the yes, so it needs a new yes")
        else:
            out("   not approved")
    return 0


def cmd_approve(args):
    changes = load(args.changes)
    approvals = read_state(args.changes, "approvals.json")
    said = (args.said or "").strip()
    if not said:
        out("Refused: --said must hold the owner's own words saying yes to this change.")
        return 2
    code = 0
    for cid in args.id:
        change = changes.get(cid)
        if not change:
            out(f"{cid}: there is no change with that id.")
            code = 2
            continue
        problems = problems_with(change)
        if problems:
            out(f"{cid}: not approved, because {'; '.join(problems)}.")
            code = 2
            continue
        approvals[cid] = {"sha": fingerprint(change), "said": said,
                          "at": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")}
        out(f"{cid}: yes recorded for this exact text.")
    write_state(args.changes, "approvals.json", approvals)
    return code


# ------------------------------------------------------------------ the owner's own approval, for live pages


def code_path():
    return KEYS_FILE.parent / "seo-approval-code.txt"


def undo_fingerprint(cid, record):
    keep = {k: record.get(k) for k in ("kind", "id", "meta_key", "old", "title", "set", "sha")}
    return hashlib.sha256(json.dumps({"undo": cid, **keep}, sort_keys=True, ensure_ascii=False).encode("utf-8")).hexdigest()


def batch_fingerprint(items):
    return hashlib.sha256(json.dumps(sorted(items), ensure_ascii=False).encode("utf-8")).hexdigest()


def code_hash(code, salt, batch):
    """The code is bound to the fingerprints of these exact changes, so any edit voids it."""
    return hashlib.pbkdf2_hmac("sha256", code.strip().lower().encode("utf-8"), f"{salt}:{batch}".encode("utf-8"), CODE_ROUNDS).hex()


def live_items(args, changes, applied):
    """What this review covers: [(key, fingerprint), ...], the lines to show, and any reason it cannot go ahead."""
    items, lines, problems = [], [], []
    for cid in args.id:
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,40}", cid):
            problems.append("a change id may only use letters, numbers, dashes and underscores, because it goes into a line you run yourself")
            continue
        if args.undo:
            record = applied.get(cid)
            if not record or record.get("target") != "wordpress" or record.get("draft"):
                problems.append(f"{cid}: I have no record of a change to a WordPress page to put back")
                continue
            field = record.get("meta_key") or "title"
            back = record.get("old", "") if record.get("meta_key") else record.get("title", "")
            items.append((f"undo:{cid}", undo_fingerprint(cid, record)))
            lines.append(f"{cid}: put back {field} on page id {record.get('id')}\n  Now:     {record.get('set', '(what I set)')}\n  Back to: {back or '(empty)'}")
            continue
        change = changes.get(cid)
        if not change:
            problems.append(f"{cid}: there is no change with that id")
            continue
        found = problems_with(change)
        if found:
            problems.append(f"{cid}: {'; '.join(found)}")
        elif change.get("type") == "new_page":
            problems.append(f"{cid}: this is a new page, which only ever goes in as a draft, so it needs no code")
        else:
            items.append((cid, fingerprint(change)))
            lines.append(f"{cid}: {change.get('type')} on {change.get('page_url')}\n  Now: {change.get('before') or '(none)'}\n  New: {change.get('after')}")
    return items, lines, problems


def open_for_owner(path):
    try:
        if os.name == "nt":
            subprocess.Popen(["notepad", str(path)])
        elif sys.platform == "darwin":
            subprocess.Popen(["open", "-e", str(path)])
        else:
            return False
    except OSError:
        return False
    return True


def safe_arg(text):
    """A value for a line the owner pastes into a shell. Git Bash and PowerShell read this the same way, or it is refused."""
    if not re.fullmatch(r"[\w :/.\-()'+,@~]+", text):
        raise ValueError(f"This path has characters that are not safe in a line you paste into a shell: {text}. Move it to a plainly named folder and run this again.")
    return f'"{text}"'


def python_call():
    """Starts Python the same way in Git Bash and PowerShell, because a `!` line on Windows can land in either."""
    exe = Path(sys.executable).as_posix()
    if os.name != "nt":
        return safe_arg(exe)
    if re.fullmatch(r"[\w:/.\-()]+", exe) and os.path.lexists(exe):
        return exe
    for name in ("py", "python", "python3"):
        if shutil.which(name):
            return name
    return safe_arg(exe)


def owner_line(args):
    """The exact line for the owner to run. THE-CODE stays a placeholder, because only they see the code."""
    script, changes = Path(__file__).resolve().as_posix(), Path(args.changes).resolve().as_posix()
    undo = " --undo" if args.undo else ""
    return f'{python_call()} {safe_arg(script)} approve-live --changes {safe_arg(changes)} --id {" ".join(args.id)}{undo} --code THE-CODE'


def cmd_review_live(args):
    changes = load(args.changes)
    items, lines, problems = live_items(args, changes, read_state(args.changes, "applied.json"))
    if problems:
        out("This cannot be approved yet:")
        for problem in problems:
            out(f"  - {problem}")
        return 2
    try:
        line_for_owner = owner_line(args)
    except ValueError as err:
        out(str(err))
        return 2
    if not items:
        out("There is nothing to review.")
        return 2
    for line in lines:
        out("-" * 50)
        out(line)
    out("-" * 50)
    batch, code, salt = batch_fingerprint(items), secrets.token_hex(4), secrets.token_hex(16)
    pending = read_state(args.changes, "live-review.json")
    pending[batch] = {"salt": salt, "hash": code_hash(code, salt, batch)}
    write_state(args.changes, "live-review.json", pending)
    target = code_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        f"Approval code: {code}\n\n"
        f"This is for {len(items)} change(s) to a live page: {', '.join(k for k, _ in items)}.\n"
        "This code approves exactly what is listed below. If it differs from what Claude showed you in the chat, do not approve it.\n"
        "These show on your live site right away. If you are happy with them, run the line Claude gave you and put this code in place of THE-CODE.\n"
        "Any change to the text makes this code stop working.\n\n" + "\n\n".join(lines) + "\n", encoding="utf-8")
    lock_down_keys()
    if POSIX:
        try:
            os.chmod(target, 0o600)
        except OSError:
            pass
    opened = False if args.no_open else open_for_owner(target)
    out("The approval code is NOT shown here. It is in a file for the owner only: " + str(target))
    out("I opened that file for them." if opened else "Ask the owner to open that file themselves. Do not open it for them.")
    out("Claude: never read, open, print or search that file, and never try to work the code out. Paste every change above into your message, "
        "because the owner cannot see this output. Then give the owner this line to run themselves:")
    out(line_for_owner)
    out("A plain yes or 'go ahead' is not approval. Any edit to the text changes what the code covers, so it stops working.")
    return 0


def cmd_approve_live(args):
    changes = load(args.changes)
    items, _, problems = live_items(args, changes, read_state(args.changes, "applied.json"))
    if problems or not items:
        out("I will not approve this:")
        for problem in problems:
            out(f"  - {problem}")
        return 2
    batch = batch_fingerprint(items)
    pending = read_state(args.changes, "live-review.json")
    entry = pending.get(batch)
    if not entry or not hmac.compare_digest(entry.get("hash", ""), code_hash(args.code, entry.get("salt", ""), batch)):
        out("That approval code does not match these changes. Run review-live again, show the owner, and use the new code.")
        return 2
    live = read_state(args.changes, "live-approvals.json")
    at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    for key, sha in items:
        live[key] = {"sha": sha, "at": at}
    write_state(args.changes, "live-approvals.json", live)
    del pending[batch]  # a code works once
    write_state(args.changes, "live-review.json", pending)
    out(f"Approved {len(items)} change(s) to a live page, for this exact text. Claude can make them now.")
    return 0


# ------------------------------------------------------------------ the site as a folder


def _read(path):
    raw = path.read_bytes()
    text = raw.decode("utf-8-sig", errors="surrogateescape")
    return text


def _write(path, text):
    tmp = path.with_name(path.name + ".seo-tmp")
    tmp.write_bytes(text.encode("utf-8", errors="surrogateescape"))
    os.replace(tmp, path)


def _norm(text):
    return " ".join(html.unescape(text or "").split())


def find_file(site, change):
    """Which file holds this page. Returns (path, reason)."""
    site = site.resolve()
    if change.get("file"):
        path = (site / change["file"]).resolve()
        if site not in path.parents:
            return None, f"its file {change['file']} is outside the site folder"
        return (path, "") if path.is_file() else (None, f"its file {change['file']} does not exist")
    # page_url is text someone wrote, so no candidate below may land outside the site folder.
    def inside(candidate):
        return site in candidate.resolve().parents

    path_part = urllib.parse.urlsplit(change.get("page_url") or "").path.strip("/")
    roots = [Path(""), Path("public"), Path("src/pages"), Path("pages"), Path("content"), Path("src/content"), Path("docs"), Path("site")]
    names = ["index.html", "index.htm", "index.md", "index.mdx", "index.astro", "_index.md"] if not path_part else [
        f"{path_part}/index.html", f"{path_part}.html", f"{path_part}/index.htm", f"{path_part}.htm",
        f"{path_part}.md", f"{path_part}/index.md", f"{path_part}.mdx", f"{path_part}/index.mdx",
        f"{path_part}.astro", f"{path_part}/index.astro", f"{path_part}/_index.md"]
    hits, escaped = [], False
    for root in roots:
        for name in names:
            candidate = site / root / name
            if not inside(candidate):
                escaped = True
            elif candidate.is_file():
                hits.append(candidate.resolve())
    if escaped:
        return None, "its address points outside the site folder"
    if len(hits) == 1:
        return hits[0], ""
    if len(hits) > 1:
        listed = ", ".join(str(h.relative_to(site)) for h in hits[:5])
        return None, f"more than one file could be this page ({listed}). Put the right one in the change as \"file\""
    before = change.get("before")
    if before:
        scanned = 0
        for folder, dirs, files in os.walk(site):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            for name in files:
                candidate = Path(folder) / name
                if candidate.suffix.lower() not in TEXT_SUFFIXES or not inside(candidate):
                    continue
                scanned += 1
                if scanned > 5000:
                    break
                try:
                    if before in _read(candidate):
                        hits.append(candidate)
                except OSError:
                    continue
        if len(hits) == 1:
            return hits[0], ""
        if len(hits) > 1:
            return None, f"the current text appears in {len(hits)} files, so I cannot tell which is this page. Put the right one in the change as \"file\""
    return None, "I could not find a file for this page. Put the right one in the change as \"file\""


FRONT = re.compile(r"\A---\r?\n(.*?\r?\n)---[ \t]*(\r?\n|\Z)", re.S)


def _yaml_quote(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def edit_text(text, field, before, after):
    """Returns (new text, how) or (None, reason). Refuses if the page no longer says what the draft saw."""
    front = FRONT.match(text)
    if front:
        block = front.group(1)
        nl = "\r\n" if "\r\n" in block else "\n"
        line = re.search(rf"(?m)^{field}[ \t]*:[ \t]*(.*?)[ \t]*\r?$", block)
        if line:
            current = line.group(1).strip().strip("\"'")
            if before is not None and _norm(current) != _norm(before):
                return None, f"the file now says \"{current}\", not what I drafted against. Read it and draft again"
            new_block = block[:line.start()] + f"{field}: {_yaml_quote(after)}" + block[line.end():]
        else:
            if before:
                return None, f"the file has no {field} line, but the draft expected one. Read it and draft again"
            new_block = block + f"{field}: {_yaml_quote(after)}{nl}"
        return text[:front.start(1)] + new_block + text[front.end(1):], "front matter"
    if field == "title":
        match = re.search(r"<title[^>]*>(.*?)</title>", text, re.I | re.S)
        replacement = f"<title>{html.escape(after, quote=False)}</title>"
    else:
        match = None
        for tag in re.finditer(r"<meta\b[^>]*>", text, re.I | re.S):
            if re.search(r"\bname\s*=\s*[\"']?description[\"']?", tag.group(0), re.I):
                match = tag
                break
        replacement = f'<meta name="description" content="{html.escape(after, quote=True)}">'
    if match:
        if field == "title":
            current = match.group(1)
        else:
            found = re.search(r"\bcontent\s*=\s*(\"([^\"]*)\"|'([^']*)')", match.group(0), re.I | re.S)
            current = (found.group(2) if found and found.group(2) is not None else (found.group(3) if found else "")) or ""
        if before is not None and _norm(current) != _norm(before):
            return None, f"the file now says \"{_norm(current)}\", not what I drafted against. Read it and draft again"
        return text[:match.start()] + replacement + text[match.end():], "HTML tag"
    if before:
        if text.count(before) == 1:
            return text.replace(before, after), "exact text"
        return None, f"I could not find the current {field} in this file"
    head = re.search(r"</head\s*>", text, re.I)
    if head:
        return text[:head.start()] + replacement + "\n" + text[head.start():], "added to the head"
    return None, f"this file has no head section and no {field} I can change. It may be built from a template"


def write_draft(site, change):
    """A new page goes beside the site folder, not inside it, so it cannot go live by accident."""
    site = site.resolve()
    folder = site.parent / f"{site.name}-seo-drafts"
    folder.mkdir(parents=True, exist_ok=True)
    body = change["body"]
    title = change["after"]
    description = change.get("description") or ""
    if (change.get("body_format") or "html") == "markdown":
        path = folder / f"{change['slug']}.md"
        text = f"---\ntitle: {_yaml_quote(title)}\ndescription: {_yaml_quote(description)}\ndraft: true\n---\n\n{body}\n"
    else:
        path = folder / f"{change['slug']}.html"
        text = ("<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
                "<meta name=\"robots\" content=\"noindex\">\n"
                f"<title>{html.escape(title, quote=False)}</title>\n"
                f"<meta name=\"description\" content=\"{html.escape(description, quote=True)}\">\n"
                f"</head>\n<body>\n{body}\n</body>\n</html>\n")
    if path.exists():
        return None, f"a draft already exists at {path}, and I will not overwrite it"
    path.write_text(text, encoding="utf-8", newline="\n")
    return path, ""


def cmd_folder(args):
    site = Path(args.site).expanduser()
    if not site.is_dir():
        out(f"{site} is not a folder. Give me the folder that holds your site's files.")
        return 1
    changes = load(args.changes)
    approvals = read_state(args.changes, "approvals.json")
    applied = read_state(args.changes, "applied.json")
    backups = state_file(args.changes, "backups")
    code, done = 0, 0
    for cid in args.id:
        change = changes.get(cid)
        if not change:
            out(f"{cid}: there is no change with that id.")
            code = 2
            continue
        reason = gate(change, approvals)
        if reason:
            out(f"{cid}: NOT changed, because {reason}.")
            code = 2
            continue
        if cid in applied:
            out(f"{cid}: already done, so I left it.")
            continue
        try:
            if change["type"] == "new_page":
                path, why = write_draft(site, change)
                if not path:
                    out(f"{cid}: NOT changed, because {why}.")
                    code = 2
                    continue
                applied[cid] = {"target": "folder", "draft": str(path), "sha": fingerprint(change)}
                out(f"{cid}: draft written to {path}. It is outside your site folder and is marked not to be listed, so it cannot go live until you move it.")
            else:
                path, why = find_file(site, change)
                if not path:
                    out(f"{cid}: NOT changed, because {why}.")
                    code = 2
                    continue
                text = _read(path)
                new_text, how = edit_text(text, change["type"], change.get("before"), change["after"])
                if new_text is None:
                    out(f"{cid}: NOT changed, because {how}.")
                    code = 2
                    continue
                backups.mkdir(parents=True, exist_ok=True)
                backup = backups / f"{cid}-{path.name}"
                shutil.copy2(path, backup)
                _write(path, new_text)
                applied[cid] = {"target": "folder", "file": str(path), "backup": str(backup), "sha": fingerprint(change),
                                "after_sha": hashlib.sha256(new_text.encode("utf-8", "surrogateescape")).hexdigest()}
                out(f"{cid}: changed {path.relative_to(site.resolve())} ({how}). Your old copy is at {backup}.")
            done += 1
        except OSError as err:
            out(f"{cid}: NOT changed, because the file could not be written ({err}). Close anything that has it open and try again.")
            code = 1
        write_state(args.changes, "applied.json", applied)
    if done:
        out(f"Made {done} change(s) in the files on this computer. Nothing is live until you publish your site the way you normally do. I did not commit or push anything.")
    return code


# ------------------------------------------------------------------ WordPress


POSIX = os.name != "nt"  # Windows keeps these private through the user folder's own permissions


def lock_down_keys():
    """Folder 700 and file 600 on every run, where the system has such modes. Never stops a run."""
    if not POSIX:
        return
    for path, mode in ((KEYS_FILE.parent, 0o700), (KEYS_FILE, 0o600)):
        try:
            if path.exists():
                os.chmod(path, mode)
        except OSError:
            pass


def read_keys():
    lock_down_keys()
    keys = {}
    try:
        for line in KEYS_FILE.read_text(encoding="utf-8-sig").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                name, _, value = line.removeprefix("export ").partition("=")
                value = value.strip().strip('"').strip("'")
                if value:
                    keys[name.strip()] = value
    except OSError:
        pass
    return keys


class WordPressError(Exception):
    pass


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Python's default sends the password on to wherever a redirect points. Never follow one."""

    def redirect_request(self, *args, **kwargs):
        return None


class WordPress:
    def __init__(self, site, user, password):
        self.site = site.rstrip("/")
        self.auth = "Basic " + base64.b64encode(f"{user}:{password}".encode("utf-8")).decode()
        self.pretty = True
        self.writes = 0
        self.opener = urllib.request.build_opener(_NoRedirect())

    def url(self, route, query=None):
        query = dict(query or {})
        if self.pretty:
            base = f"{self.site}/wp-json{route}"
        else:
            base, query = f"{self.site}/", {"rest_route": route, **query}
        return base + ("?" + urllib.parse.urlencode(query) if query else "")

    def call(self, method, route, body=None, query=None):
        data = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request(self.url(route, query), data=data, method=method,
                                     headers={"Authorization": self.auth, "Content-Type": "application/json",
                                              "User-Agent": "page-writer-skill/1.0"})
        try:
            with self.opener.open(req, timeout=45) as resp:
                return resp.status, json.loads(resp.read().decode("utf-8") or "null")
        except urllib.error.HTTPError as err:
            if 300 <= err.code < 400:
                parts = urllib.parse.urlsplit(err.headers.get("Location") or "")
                where = f"{parts.scheme}://{parts.netloc}"[:100] if parts.netloc else "another address"
                raise WordPressError(f"your site tried to send this request to {where}, so I stopped, and your password did not go with it. "
                                     "If that is your own address, for example with www or https, put exactly that in WP_SITE_URL. If you do not "
                                     "recognize it, your site may be hacked: revoke this application password in WordPress and ask your web host") from None
            try:
                payload = json.loads(err.read().decode("utf-8"))
            except Exception:
                payload = {}
            return err.code, payload
        except urllib.error.URLError as err:
            raise WordPressError(f"I could not reach your site ({err.reason}). Check the address and your connection") from None
        except ValueError:
            raise WordPressError("your site answered with something that is not the WordPress API. A security plugin or host firewall may be in the way") from None

    def connect(self):
        status, me = self.call("GET", "/wp/v2/users/me", query={"context": "edit"})
        if status == 404 or (status == 200 and not isinstance(me, dict)):
            self.pretty = False
            status, me = self.call("GET", "/wp/v2/users/me", query={"context": "edit"})
        if status == 401:
            raise WordPressError("WordPress refused the login. Check WP_USER and WP_APP_PASSWORD. It must be an application password from your user profile, not your normal password. If they are right, your web host may be blocking the login, so ask them about the Authorization header")
        if status == 403:
            raise WordPressError("WordPress says this user is not allowed in. Use a user who can edit pages, like an Editor")
        if status == 404:
            raise WordPressError("I could not find the WordPress API on this site. It may be turned off. Use the paste-ready text instead")
        if status != 200:
            raise WordPressError(f"WordPress answered with status {status} when I signed in")
        return me

    def find(self, change):
        path = urllib.parse.urlsplit(change.get("page_url") or "").path
        slug = path.strip("/").rsplit("/", 1)[-1]
        if not slug:
            status, settings = self.call("GET", "/wp/v2/settings")
            home_id = settings.get("page_on_front") if status == 200 and isinstance(settings, dict) else 0
            if not home_id:
                raise WordPressError("I could not find your home page as a normal WordPress page, either because it is built another way or because this user cannot see the site settings. Use the paste-ready text")
            status, page = self.call("GET", f"/wp/v2/pages/{home_id}", query={"context": "edit"})
            if status == 200:
                return "pages", page
            raise WordPressError(f"I could not read your home page (status {status})")
        for kind in ("pages", "posts"):
            status, rows = self.call("GET", f"/wp/v2/{kind}", query={"slug": slug, "context": "edit", "status": "any"})
            if status == 200 and isinstance(rows, list) and rows:
                exact = [r for r in rows if urllib.parse.urlsplit(r.get("link") or "").path.rstrip("/") == path.rstrip("/")]
                if len(exact) == 1 or len(rows) == 1:
                    return kind, (exact or rows)[0]
                raise WordPressError(f"more than one page has the address {slug}")
        raise WordPressError(f"I could not find a page or post at {path}")


def seo_plugin(page):
    meta = page.get("meta") if isinstance(page.get("meta"), dict) else {}
    if "yoast_head_json" in page or "yoast_head" in page or any(k.startswith("_yoast_") for k in meta):
        return "yoast"
    if any(k.startswith("rank_math") for k in meta):
        return "rank math"
    if any(k.startswith("_seopress") for k in meta):
        return "seopress"
    return None


def _text_of(field):
    if isinstance(field, dict):
        return field.get("raw") if field.get("raw") is not None else field.get("rendered")
    return field


def wp_update(wp, change, blocked=None):
    """Change a title or description. Returns (result, message, undo info). result: done, paste or refuse.

    blocked is the reason a write may not happen. Text to paste still comes back, since that writes nothing.
    """
    kind, page = wp.find(change)
    field = change["type"]
    plugin = seo_plugin(page)
    meta = page.get("meta") if isinstance(page.get("meta"), dict) else {}
    key = SEO_META_KEYS.get(plugin, {}).get(field)
    route = f"/wp/v2/{kind}/{page['id']}"
    if plugin and key and key in meta:
        if blocked:
            return "refuse", blocked, None
        status, updated = wp.call("POST", route, body={"meta": {key: change["after"]}}, query={"context": "edit"})
        wp.writes += 1
        if status != 200:
            return "paste", f"WordPress refused the change (status {status}). Paste this into the {plugin} box on that page instead", None
        stored = (updated.get("meta") or {}).get(key) if isinstance(updated, dict) else None
        if stored != change["after"]:
            return "paste", f"WordPress said OK but did not keep it, which it does when a plugin has not opened that field. Paste this into the {plugin} box on that page instead", None
        return "done", f"set the {plugin} {field}", {"kind": kind, "id": page["id"], "meta_key": key, "old": meta.get(key, ""), "set": change["after"]}
    if plugin:
        return "paste", (f"this site uses {plugin}, and its {field} cannot be changed through the WordPress API unless a developer opens that field. "
                         f"Paste this into the {plugin} box on that page instead"), None
    if field == "description":
        return "paste", "WordPress on its own has no place for a description. An SEO plugin adds that box. Paste this there instead", None
    current = _text_of(page.get("title")) or ""
    before = _norm(change.get("before"))
    if before and _norm(current) not in before and before not in _norm(current):
        return "refuse", f"the page title is now \"{current}\", not what I drafted against. Read it and draft again", None
    if blocked:
        return "refuse", blocked, None
    new_title = change["after"]
    status, root = wp.call("GET", "/")
    name = root.get("name") if status == 200 and isinstance(root, dict) else ""
    if name:
        trimmed = re.sub(rf"\s*[|\-:]\s*{re.escape(name)}\s*$", "", new_title)
        new_title = trimmed or new_title
    status, updated = wp.call("POST", route, body={"title": new_title}, query={"context": "edit"})
    wp.writes += 1
    if status != 200:
        message = updated.get("message") if isinstance(updated, dict) else ""
        return "refuse", f"WordPress refused the change (status {status}{': ' + message if message else ''})", None
    stored = _norm(_text_of(updated.get("title")) if isinstance(updated, dict) else "")
    if stored != _norm(new_title):
        return "refuse", "WordPress answered OK but kept a different title. Check the page", None
    return "done", "set the page title. WordPress usually shows this as the heading on the page too", {"kind": kind, "id": page["id"], "title": current, "set": new_title}


def wp_create_draft(wp, change):
    status, rows = wp.call("GET", "/wp/v2/pages", query={"slug": change["slug"], "status": "any", "context": "edit"})
    if status == 200 and rows:
        return "refuse", f"a page with the address {change['slug']} already exists, and I will not overwrite it", None
    # Always a draft. This is the only status this script ever sends.
    body = {"title": change["after"], "content": change["body"], "slug": change["slug"], "status": "draft"}
    if change.get("description"):
        body["excerpt"] = change["description"]
    status, page = wp.call("POST", "/wp/v2/pages", body=body)
    wp.writes += 1
    if status not in (200, 201):
        message = page.get("message") if isinstance(page, dict) else ""
        return "refuse", f"WordPress refused the draft (status {status}{': ' + message if message else ''})", None
    if page.get("status") != "draft":
        return "refuse", f"WordPress saved the page as '{page.get('status')}' instead of a draft. Check it right away: page id {page.get('id')}", {"kind": "pages", "id": page.get("id")}
    return "done", f"created a draft page, id {page.get('id')}. It is not live. Open Pages in WordPress to read it", {"kind": "pages", "id": page.get("id"), "draft": True}


def open_wordpress():
    keys = read_keys()
    site, user, password = keys.get("WP_SITE_URL"), keys.get("WP_USER"), keys.get("WP_APP_PASSWORD")
    if not (site and user and password):
        out(f"WordPress is not set up. In WordPress open Users, then your profile, and make an Application Password. Then put WP_SITE_URL, WP_USER and WP_APP_PASSWORD in {KEYS_FILE} in a text editor. Do not paste them into this chat.")
        sys.exit(1)
    parts = urllib.parse.urlsplit(site)
    if parts.scheme != "https" and parts.hostname not in ("localhost", "127.0.0.1"):
        out(f"Refused: {site} is not https, so your password would travel in the open. Turn on https first, or use the paste-ready text.")
        sys.exit(1)
    return WordPress(site, user, password)


def cmd_wordpress(args):
    changes = load(args.changes)
    approvals = read_state(args.changes, "approvals.json")
    applied = read_state(args.changes, "applied.json")
    live = read_state(args.changes, "live-approvals.json")
    code, connected, wp, paste = 0, False, None, []
    for cid in args.id:
        change = changes.get(cid)
        if not change:
            out(f"{cid}: there is no change with that id.")
            code = 2
            continue
        # The first gate runs before any contact with the site.
        reason = gate(change, approvals, live)
        if reason:
            out(f"{cid}: NOT changed, because {reason}.")
            code = 2
            continue
        if cid in applied:
            out(f"{cid}: already done, so I left it.")
            continue
        try:
            if not connected:
                wp = open_wordpress()
                wp.connect()
                connected = True
            if change["type"] == "new_page":
                result, message, undo = wp_create_draft(wp, change)
            else:
                _, page = wp.find(change)
                is_live = page.get("status") not in NOT_LIVE
                result, message, undo = wp_update(wp, change, gate(change, approvals, live, need_live=True) if is_live else None)
        except WordPressError as err:
            out(f"{cid}: NOT changed, because {err}.")
            code = 1
            continue
        if result == "done":
            applied[cid] = {"target": "wordpress", "sha": fingerprint(change), **(undo or {})}
            write_state(args.changes, "applied.json", applied)
            out(f"{cid}: {message}.")
        elif result == "paste":
            paste.append(change)
            out(f"{cid}: NOT changed. {message}:\n   {change['after']}")
            code = max(code, 3)
        else:
            out(f"{cid}: NOT changed, because {message}.")
            code = max(code, 2)
    return code


def cmd_check_wp(args):
    """Prove the application password works. This only reads."""
    wp = open_wordpress()
    try:
        me = wp.connect()
    except WordPressError as err:
        out(f"Not working yet: {err}.")
        return 1
    status, rows = wp.call("GET", "/wp/v2/pages", query={"per_page": 1, "context": "edit"})
    if status != 200:
        out(f"The login works, but this user ({me.get('name')}) cannot edit pages (status {status}). Use a user with the Editor role.")
        return 1
    out(f"Works. Signed in to WordPress as {me.get('name')}, and this user can edit pages. Nothing was changed.")
    if "administrator" in (me.get("roles") or []):
        out("Warning: this user is an administrator, so if this password ever leaked it could change the whole site. Make a separate user with the Editor role and use its application password instead.")
    return 0


def cmd_undo(args):
    load(args.changes)
    applied = read_state(args.changes, "applied.json")
    live = read_state(args.changes, "live-approvals.json")
    if not (args.said or "").strip():
        out("Refused: --said must hold the owner's own words asking for this undo.")
        return 2
    code = 0
    for cid in args.id:
        record = applied.get(cid)
        if not record:
            out(f"{cid}: I have no record of making this change, so there is nothing to undo.")
            code = 2
            continue
        if record.get("draft") and record["target"] == "folder":
            out(f"{cid}: this was a new draft. Delete {record['draft']} if you do not want it.")
            continue
        if record["target"] == "folder":
            path, backup = Path(record["file"]), Path(record["backup"])
            current = hashlib.sha256(_read(path).encode("utf-8", "surrogateescape")).hexdigest()
            if current != record.get("after_sha"):
                out(f"{cid}: NOT undone, because {path.name} has changed since. Restoring would lose that work. Your old copy is at {backup}.")
                code = 2
                continue
            shutil.copy2(backup, path)
            del applied[cid]
            out(f"{cid}: put {path.name} back the way it was.")
            continue
        if record.get("draft"):
            out(f"{cid}: this was a new draft, page id {record.get('id')}. Move it to the trash in WordPress if you do not want it. It was never live.")
            continue
        wp = open_wordpress()
        try:
            wp.connect()
            route = f"/wp/v2/{record['kind']}/{record['id']}"
            status, page = wp.call("GET", route, query={"context": "edit"})
            if status != 200 or not isinstance(page, dict):
                out(f"{cid}: NOT undone, because I could not read that page (status {status}).")
                code = 1
                continue
            # Putting a live title back changes the live site just as much as the first change did.
            if page.get("status") not in NOT_LIVE and (live.get(f"undo:{cid}") or {}).get("sha") != undo_fingerprint(cid, record):
                out(f"{cid}: NOT undone, because this page is live, so putting it back would show right away, and only the owner can approve that. "
                    "A yes in chat does not count. Run review-live with --undo and give them the line it prints.")
                code = 2
                continue
            meta = page.get("meta") if isinstance(page.get("meta"), dict) else {}
            current = meta.get(record["meta_key"]) if record.get("meta_key") else _text_of(page.get("title"))
            if "set" in record and _norm(current) != _norm(record["set"]):
                out(f"{cid}: NOT undone, because it now says \"{current}\", so someone has changed it since. Putting it back would lose that.")
                code = 2
                continue
            if record.get("meta_key"):
                body = {"meta": {record["meta_key"]: record.get("old", "")}}
            else:
                body = {"title": record.get("title", "")}
            status, _ = wp.call("POST", route, body=body)
        except WordPressError as err:
            out(f"{cid}: NOT undone, because {err}.")
            code = 1
            continue
        if status == 200:
            del applied[cid]
            live.pop(f"undo:{cid}", None)
            live.pop(cid, None)  # doing it again is a new change to a live page, so it needs a new approval
            write_state(args.changes, "live-approvals.json", live)
            out(f"{cid}: put it back the way it was.")
        else:
            out(f"{cid}: NOT undone. WordPress answered with status {status}.")
            code = 1
    write_state(args.changes, "applied.json", applied)
    return code


# ------------------------------------------------------------------ any other platform


def cmd_paste(args):
    changes = load(args.changes)
    lines = ["# Paste-Ready Changes", "",
             "Your site's platform is not one I can edit directly, so here is every change to paste in by hand. "
             "Open the page's SEO settings in your site builder. Put new pages in as drafts first and read them before you publish.", ""]
    for cid, change in changes.items():
        kind = change.get("type")
        where = change.get("page_url") or f"new page: /{change.get('slug')}"
        lines.extend([f"## {cid}: {where}", ""])
        problems = problems_with(change)
        if problems:
            lines.extend([f"Not ready: {'; '.join(problems)}.", ""])
        if kind == "title":
            lines.extend([f"Page Title, Now: {change.get('before') or '(none)'}", "", f"Page Title, New: {change.get('after')}", ""])
        elif kind == "description":
            lines.extend([f"Description, Now: {change.get('before') or '(none)'}", "", f"Description, New: {change.get('after')}", ""])
        else:
            lines.extend([f"Page Title: {change.get('after')}", "", f"Description: {change.get('description') or ''}", "",
                          f"Address: /{change.get('slug')}", "", "Page Text:", "", change.get("body") or "", ""])
    path = Path(args.out)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="utf-8", newline="\n")
    out(f"Wrote {len(changes)} change(s) to {path}. Nothing was changed on your site.")
    return 0


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser(description="Apply approved changes to a site.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check-wp")
    for name in ("review-live", "approve-live"):
        one = sub.add_parser(name)
        one.add_argument("--changes", required=True)
        one.add_argument("--id", nargs="+", required=True)
        one.add_argument("--undo", action="store_true", help="for putting a live page back")
        if name == "review-live":
            one.add_argument("--no-open", action="store_true", help="do not open the code file on this screen")
        else:
            one.add_argument("--code", required=True)
    for name in ("check", "approve", "folder", "wordpress", "paste", "undo"):
        one = sub.add_parser(name)
        one.add_argument("--changes", required=True)
        if name in ("approve", "folder", "wordpress", "undo"):
            one.add_argument("--id", nargs="+", required=True)
        if name in ("approve", "undo"):
            one.add_argument("--said", default="")
        if name == "folder":
            one.add_argument("--site", required=True)
        if name == "undo":
            one.add_argument("--site")
        if name == "paste":
            one.add_argument("--out", default="seo-work/paste-ready.md")
    args = ap.parse_args()
    return {"check": cmd_check, "approve": cmd_approve, "folder": cmd_folder, "wordpress": cmd_wordpress,
            "paste": cmd_paste, "undo": cmd_undo, "check-wp": cmd_check_wp, "review-live": cmd_review_live,
            "approve-live": cmd_approve_live}[args.cmd](args)


if __name__ == "__main__":
    try:
        sys.exit(main() or 0)
    except KeyboardInterrupt:
        out("Stopped.")
        sys.exit(1)
    except SystemExit:
        raise
    except Exception as exc:
        out(f"This step failed: {type(exc).__name__}: {exc}. Check your site with the paste-ready text as the safe route, or tell Claude what you were doing.")
        sys.exit(1)
