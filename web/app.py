#!/usr/bin/env python3
import os
import re
from datetime import date, timedelta
from pathlib import Path
from flask import Flask, render_template, request, abort

BASE_DIR = Path(__file__).parent.parent
PROCESSED_DIR = BASE_DIR / "data" / "processed"

app = Flask(__name__)


def available_dates():
    if not PROCESSED_DIR.exists():
        return []
    dirs = sorted(
        [d.name for d in PROCESSED_DIR.iterdir() if d.is_dir() and re.match(r'\d{4}-\d{2}-\d{2}', d.name)],
        reverse=True,
    )
    return dirs


def read_category(day: str, category: str) -> str:
    path = PROCESSED_DIR / day / f"{category}.log"
    if not path.exists():
        return ""
    return path.read_text(errors="replace")


def parse_summary(day: str) -> dict:
    raw = read_category(day, "summary")
    stats = {}
    for line in raw.splitlines():
        m = re.match(r'\s*(\w+):\s+(\d+) lines\s+(?:from (\d+) source)', line)
        if m:
            stats[m.group(1).lower()] = {"lines": int(m.group(2)), "sources": int(m.group(3))}
        m2 = re.match(r'\s*(\w+):\s+(\d+) lines', line)
        if m2 and m2.group(1).lower() not in stats:
            stats[m2.group(1).lower()] = {"lines": int(m2.group(2)), "sources": 0}
    return stats


@app.route("/")
def index():
    dates = available_dates()
    selected = request.args.get("date", dates[0] if dates else None)
    if selected and selected not in dates:
        abort(404)

    categories = ["errors", "warnings", "auth", "web", "app"]
    active_cat = request.args.get("cat", "summary")

    content = ""
    summary_stats = {}

    if selected:
        summary_stats = parse_summary(selected)
        if active_cat == "summary":
            content = read_category(selected, "summary")
        elif active_cat in categories:
            content = read_category(selected, active_cat)

    return render_template(
        "index.html",
        dates=dates,
        selected=selected,
        categories=categories,
        active_cat=active_cat,
        content=content,
        summary_stats=summary_stats,
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5055, debug=False)
