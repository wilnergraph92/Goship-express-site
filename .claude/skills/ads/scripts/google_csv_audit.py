#!/usr/bin/env python3
"""google_csv_audit.py: audit a Google Ads report you downloaded, and list budget moves to approve.

    python google_csv_audit.py report.csv --out folder

No login and no network. It reads the file you exported from the Google Ads website and writes a list.
Standard library only.
"""
from __future__ import annotations

import argparse
import csv
import io
import re
import sys
from datetime import date
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

NAME_COLUMNS = ["campaign", "campaign name", "ad group", "search term", "keyword", "search keyword", "ad name"]
COST_COLUMNS = ["cost", "spend", "cost (converted currency)"]
CONV_COLUMNS = ["conversions", "conv.", "all conv."]
CLICK_COLUMNS = ["clicks"]
IMPR_COLUMNS = ["impr.", "impressions"]
BUDGET_COLUMNS = ["budget", "campaign daily budget", "daily budget"]
STATUS_COLUMNS = ["campaign status", "status", "campaign state"]

RAISE_CPA_RATIO = 0.7
CUT_CPA_RATIO = 1.5
MIN_CONVERSIONS_TO_RAISE = 5
NO_RESULT_SPEND_RATIO = 2.0
RAISE_PERCENT = 20
CUT_PERCENT = 30


def say(msg: str) -> None:
    print(msg, flush=True)


def read_text(path: Path) -> str:
    raw = path.read_bytes()
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return raw.decode("utf-16", "replace")
    return raw.decode("utf-8-sig", "replace")


def to_num(value) -> float:
    text = re.sub(r"[^\d.\-]", "", str(value or "").replace(",", ""))
    try:
        return float(text)
    except ValueError:
        return 0.0


def column(header: list, names: list):
    low = [h.strip().lower() for h in header]
    for name in names:
        if name in low:
            return low.index(name)
    return None


def load(path: Path):
    """The export starts with title lines and ends with totals, so look for the real header row."""
    text = read_text(path)
    first = next((ln for ln in text.splitlines() if ln.strip()), "")
    tabbed = text.count("\t") > text.count(",") or "\t" in first
    rows = list(csv.reader(io.StringIO(text), delimiter="\t" if tabbed else ","))
    for i, row in enumerate(rows):
        if column(row, NAME_COLUMNS) is not None and column(row, COST_COLUMNS) is not None:
            return row, rows[i + 1:]
    return None, []


def main() -> int:
    ap = argparse.ArgumentParser(description="Audit a downloaded Google Ads report.")
    ap.add_argument("report")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    path = Path(a.report)
    if not path.is_file():
        say(f"I could not find {path}. Download the report from the Google Ads website and give me its path.")
        return 2
    try:
        header, rows = load(path)
    except OSError as exc:
        say(f"I could not read {path}: {exc}")
        return 2
    if not header:
        say("I could not find the columns I need in that file. Download a campaign report that shows "
            "Campaign, Cost, Conversions, Clicks and Impr., in CSV format, and try again.")
        return 2
    c_name = column(header, NAME_COLUMNS)
    c_cost = column(header, COST_COLUMNS)
    c_conv = column(header, CONV_COLUMNS)
    c_click = column(header, CLICK_COLUMNS)
    c_impr = column(header, IMPR_COLUMNS)
    c_budget = column(header, BUDGET_COLUMNS)
    c_status = column(header, STATUS_COLUMNS)

    def cell(row, idx):
        return row[idx] if idx is not None and idx < len(row) else ""

    # The report's own currency when it has that column. Never assume dollars.
    c_currency = column(header, ["currency code", "currency"])
    codes = [cell(row, c_currency).strip().upper() for row in rows if cell(row, c_currency).strip()]
    sign = "" if not codes else ("$" if codes[0] == "USD" else f"{codes[0]} ")

    items = []
    for row in rows:
        name = cell(row, c_name).strip()
        if not name or re.match(r"(?i)^total", name) or name in ("--", " --"):
            continue
        status = cell(row, c_status).strip().lower()
        # Keep "Eligible (Limited)" and "Limited by budget": those are running. Skip what is not.
        if re.search(r"paus|remov|ended|draft|suspend|not eligible|disapprov", status):
            continue
        items.append({"name": name, "cost": to_num(cell(row, c_cost)), "conv": to_num(cell(row, c_conv)),
                      "clicks": to_num(cell(row, c_click)), "impr": to_num(cell(row, c_impr)),
                      "budget": to_num(cell(row, c_budget))})
    if not items:
        say("That report has no enabled rows with spend, so there is nothing to audit.")
        return 0
    total_cost = sum(i["cost"] for i in items)
    total_conv = sum(i["conv"] for i in items)
    cpa = total_cost / total_conv if total_conv else 0
    moves = []
    for item in items:
        conv, cost, budget = item["conv"], item["cost"], item["budget"]
        own = cost / conv if conv else 0
        evidence = f"{sign}{cost:,.2f} spent, {conv:g} conversions" + (f" at {sign}{own:,.2f} each" if conv else "")
        where_from = f"{sign}{budget:,.2f} per day" if budget else "not in this report"
        if not cpa:
            continue
        if not conv and cost >= NO_RESULT_SPEND_RATIO * cpa:
            moves.append(("Pause", item["name"], where_from, f"{sign}0", f"{evidence}. Your average is {sign}{cpa:,.2f}."))
        elif conv and own >= CUT_CPA_RATIO * cpa and cost >= NO_RESULT_SPEND_RATIO * cpa:
            to = f"{sign}{budget * (100 - CUT_PERCENT) / 100:,.2f} per day" if budget else f"{CUT_PERCENT}% lower"
            moves.append((f"Lower {CUT_PERCENT}%", item["name"], where_from, to, f"{evidence}, against an average of {sign}{cpa:,.2f}."))
        elif conv >= MIN_CONVERSIONS_TO_RAISE and own <= RAISE_CPA_RATIO * cpa:
            to = f"{sign}{budget * (100 + RAISE_PERCENT) / 100:,.2f} per day" if budget else f"{RAISE_PERCENT}% higher"
            moves.append((f"Raise {RAISE_PERCENT}%", item["name"], where_from, to, f"{evidence}, against an average of {sign}{cpa:,.2f}."))
    folder = Path(a.out)
    folder.mkdir(parents=True, exist_ok=True)
    lines = [
        f"# Google Ads Budget Moves, {date.today().isoformat()}", "",
        f"From the report {path.name}. Nothing has been changed, and this tool has no connection to your account. "
        "To make a move, approve it and make the change yourself in Google Ads.", "",
        f"Spend: {sign}{total_cost:,.2f}. Conversions: {total_conv:g}." + (f" Average cost per conversion: {sign}{cpa:,.2f}." if cpa else ""), "",
        "## Budget Moves For Your Approval", "",
    ]
    if moves:
        lines += ["| # | Approve? | Move | Where | From | To | Why |", "|---|---|---|---|---|---|---|"]
        for n, m in enumerate(moves, 1):
            lines.append(f"| {n} | [ ] | " + " | ".join(str(c).replace("|", "/") for c in m) + " |")
    elif not total_conv:
        lines.append("No moves, because this report shows no conversions. Check that conversion tracking is set up in Google Ads first, since budget moves mean nothing without it.")
    else:
        lines.append("No moves. Nothing is far enough from your average to justify one.")
    lines += ["", "These come from starting rules, measured against your own average. They do not know your margins, your season or your sales cycle. Change budgets in steps and give each change about a week."]
    (folder / "google-budget-moves.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    say(f"Read {len(items)} rows. {len(moves)} budget moves. Nothing was changed. Wrote {folder / 'google-budget-moves.md'}.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # a stranger should never see a stack trace
        say(f"Something went wrong: {exc}. Tell me what you were doing and I will look.")
        sys.exit(1)
