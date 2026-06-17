#!/usr/bin/env python3
import os
import re
from pathlib import Path
from flask import Flask, render_template, request, abort

BASE_DIR = Path(__file__).parent.parent
PROCESSED_DIR = BASE_DIR / "data" / "processed"

app = Flask(__name__)


def available_dates():
    if not PROCESSED_DIR.exists():
        return []
    return sorted(
        [d.name for d in PROCESSED_DIR.iterdir()
         if d.is_dir() and re.match(r'\d{4}-\d{2}-\d{2}', d.name)],
        reverse=True,
    )


def available_hosts(day: str) -> list[str]:
    hosts_dir = PROCESSED_DIR / day / "hosts"
    if not hosts_dir.exists():
        return []
    return sorted([h.name for h in hosts_dir.iterdir() if h.is_dir()])


def read_file(path: Path) -> str:
    if not path.exists():
        return ""
    return path.read_text(errors="replace")


def category_dir(day: str, host: str) -> Path:
    if host == "all":
        return PROCESSED_DIR / day
    return PROCESSED_DIR / day / "hosts" / host


def parse_summary(day: str, host: str) -> dict:
    src = category_dir(day, host)
    raw = read_file(src / "summary.log")
    stats = {}
    for line in raw.splitlines():
        m = re.match(r'\s*(\w+):\s+(\d+) lines\s+(?:from (\d+) source)', line)
        if m:
            stats[m.group(1).lower()] = {"lines": int(m.group(2)), "sources": int(m.group(3))}
        m2 = re.match(r'\s*(\w+):\s+(\d+) lines', line)
        if m2 and m2.group(1).lower() not in stats:
            stats[m2.group(1).lower()] = {"lines": int(m2.group(2)), "sources": 0}
    return stats


def parse_remediation_counts(day: str, host: str) -> dict:
    src = category_dir(day, host)
    raw = read_file(src / "remediation.log")
    counts = {"CRITICAL": 0, "HIGH": 0, "MEDIUM": 0, "LOW": 0, "INFO": 0, "total": 0}
    for line in raw.splitlines():
        m = re.match(r'\s*(CRITICAL|HIGH|MEDIUM|LOW|INFO)\s*:\s*(\d+)', line)
        if m:
            counts[m.group(1)] = int(m.group(2))
        m2 = re.match(r'\s*Findings:\s*(\d+)', line)
        if m2:
            counts["total"] = int(m2.group(1))
    return counts


@app.route("/")
def index():
    dates = available_dates()
    selected_date = request.args.get("date", dates[0] if dates else None)
    if selected_date and selected_date not in dates:
        abort(404)

    categories = ["errors", "warnings", "auth", "web", "app"]
    active_cat = request.args.get("cat", "summary")

    hosts = []
    selected_host = "all"
    if selected_date:
        hosts = available_hosts(selected_date)
        selected_host = request.args.get("host", "all")
        if selected_host != "all" and selected_host not in hosts:
            selected_host = "all"

    content = ""
    summary_stats = {}
    remediation_counts = {}

    if selected_date:
        src_dir = category_dir(selected_date, selected_host)
        summary_stats = parse_summary(selected_date, selected_host)
        remediation_counts = parse_remediation_counts(selected_date, selected_host)

        if active_cat == "summary":
            content = read_file(src_dir / "summary.log")
        elif active_cat == "remediation":
            content = read_file(src_dir / "remediation.log")
        elif active_cat in categories:
            content = read_file(src_dir / f"{active_cat}.log")

    return render_template(
        "index.html",
        dates=dates,
        selected_date=selected_date,
        hosts=hosts,
        selected_host=selected_host,
        categories=categories,
        active_cat=active_cat,
        content=content,
        summary_stats=summary_stats,
        remediation_counts=remediation_counts,
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5055, debug=False)
