"""
parse_log.py
------------
Parses a custom Nginx access log produced by the 'experiment' log_format.

A block starts with a 'start.html' sentinel and ends implicitly when the
next 'start.html' is found (or end of file). All HTTP 206 responses
between two sentinels belong to the previous sentinel's experiment.

Sentinel URL:
  start.html?technology=<tech>&scaleFactor=<sf>&queryId=<qid>

Usage:
  python parse_log.py <access.log> [output.csv]
"""

import re
import csv
import sys
from datetime import datetime
from pathlib import Path

TIME_FMT = "%d/%b/%Y:%H:%M:%S %z"

LOG_RE = re.compile(
    r'\S+ \[([^\]]+)\] '
    r'"(?:GET|HEAD) (\S+) \S+" '
    r'(\d+) (\d+) '
    r'bytes_range="([^"]*)" '
    r'request_time=([\d.]+)'
)

SENTINEL_RE = re.compile(
    r'start\.html[^"]*'
    r'technology=([^&\s"]+).*?'
    r'scaleFactor=([^&\s"]+).*?'
    r'queryId=([^&\s"?]+)',
    re.IGNORECASE,
)

CSV_FIELDS = [
    "technology",
    "scale_factor",
    "query_id",
    "t_first_request",
    "t_last_request",
    "duration_s",
    "n_requests",
    "total_bytes_mb",
]


def _progress(lineno: int, total: int, experiments: int) -> None:
    pct  = lineno / total * 100
    done = int(pct / 5)
    bar  = "#" * done + "-" * (20 - done)
    print(
        f"\r  [{bar}] {pct:5.1f}%  line {lineno:,}/{total:,}  "
        f"experiments so far: {experiments}",
        end="", flush=True,
    )


def flush_active(active: dict, rows: list) -> None:
    """Finalise the current block and append a row."""
    if active is None:
        return
    if active["t_first"] is None:
        return  # sentinel with zero 206 responses — skip
    dur = (active["t_last"] - active["t_first"]).total_seconds()
    mb  = active["bytes"] / 1_048_576
    rows.append({
        "technology":      active["technology"],
        "scale_factor":    active["scale_factor"],
        "query_id":        active["query_id"],
        "t_first_request": active["t_first"].isoformat(),
        "t_last_request":  active["t_last"].isoformat(),
        "duration_s":      round(dur, 3),
        "n_requests":      active["n"],
        "total_bytes_mb":  round(mb, 4),
    })


def parse(logfile: str, outfile: str) -> None:
    active   = None
    rows     = []
    warnings = []

    lines = Path(logfile).read_text().splitlines()
    total = len(lines)
    print(f"  Reading {total:,} lines from {logfile}")

    for lineno, line in enumerate(lines, 1):
        if lineno % 5_000 == 0 or lineno == total:
            _progress(lineno, total, len(rows))

        m = LOG_RE.search(line)
        if not m:
            continue

        ts_str, path, status, body_str, rng, rt_str = m.groups()
        try:
            ts = datetime.strptime(ts_str, TIME_FMT)
        except ValueError:
            warnings.append(f"line {lineno}: cannot parse timestamp '{ts_str}'")
            continue

        body = int(body_str)

        s = SENTINEL_RE.search(path)
        if s:
            tech, sf, qid = s.groups()
            flush_active(active, rows)
            active = dict(
                technology=tech,
                scale_factor=sf,
                query_id=qid,
                t_first=None,
                t_last=None,
                n=0,
                bytes=0,
            )
            continue

        if active is not None and status == "206":
            if active["t_first"] is None:
                active["t_first"] = ts
            active["t_last"]  = ts
            active["n"]      += 1
            active["bytes"]  += body

    # Flush the last open block
    flush_active(active, rows)

    print()  # newline after progress bar

    with open(outfile, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        writer.writeheader()
        writer.writerows(rows)

    print(f"  Exported {len(rows)} experiments -> {outfile}")
    for w in warnings:
        print(f"  [WARN] {w}", file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python parse_log.py <access.log> [output.csv]")
        sys.exit(1)
    logfile = sys.argv[1]
    outfile = sys.argv[2] if len(sys.argv) > 2 else "results.csv"
    parse(logfile, outfile)
