"""
parse_log_nosentinel.py
-----------------------
Temporary variant of parse_log.py for log files that are missing the
start.html sentinel.

Experiment boundaries are inferred from parquet filename changes in the
request path:
  - Consecutive requests to the same file form one experiment block.
  - A filename change flushes the current block and starts a new one.
  - Scale factor is extracted from the filename (e.g. lineitem-sf10.parquet → sf=10).

Technology assignment:
  - Batch 1 (first pass through the set of filenames): DVISOR
  - Batch 2 (filenames start repeating from the beginning): DUCKDB

query_id is a sequential counter that resets at each technology boundary.

Usage:
  python parse_log_nosentinel.py <access.log> [output.csv]
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

PARQUET_RE = re.compile(r'/([^/?]+\.parquet)', re.IGNORECASE)
SF_RE      = re.compile(r'-sf(\d+)\.parquet',  re.IGNORECASE)

TECHNOLOGIES = ["DVISOR", "DUCKDB"]

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
    if active is None:
        return
    if active["t_first"] is None:
        return  # block had zero 206 responses — skip
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
    active          = None
    rows            = []
    warnings        = []
    completed_files = set()   # filenames fully processed in current batch
    batch_idx       = 0       # index into TECHNOLOGIES
    query_counter   = 0       # sequential within current batch

    lines = Path(logfile).read_text().splitlines()
    total = len(lines)
    print(f"  Reading {total:,} lines from {logfile}")

    for lineno, line in enumerate(lines, 1):
        if lineno % 5_000 == 0 or lineno == total:
            _progress(lineno, total, len(rows))

        m = LOG_RE.search(line)
        if not m:
            continue

        ts_str, path, status, body_str, _rng, _rt = m.groups()
        try:
            ts = datetime.strptime(ts_str, TIME_FMT)
        except ValueError:
            warnings.append(f"line {lineno}: cannot parse timestamp '{ts_str}'")
            continue

        body = int(body_str)

        pm = PARQUET_RE.search(path)
        if not pm:
            continue

        filename = pm.group(1)
        sf_match = SF_RE.search(filename)
        if not sf_match:
            continue  # parquet without sf pattern — ignore

        sf = sf_match.group(1)

        # ── Block-change detection ──────────────────────────────────────────
        if active is None or filename != active["filename"]:
            if active is not None:
                completed_files.add(active["filename"])
                flush_active(active, rows)

            # A filename reappearing means we've entered a new technology batch
            if filename in completed_files:
                batch_idx     = min(batch_idx + 1, len(TECHNOLOGIES) - 1)
                query_counter = 0
                completed_files = set()

            query_counter += 1
            active = dict(
                filename=filename,
                technology=TECHNOLOGIES[batch_idx],
                scale_factor=sf,
                query_id=str(query_counter),
                t_first=None,
                t_last=None,
                n=0,
                bytes=0,
            )

        # ── Accumulate only partial-content responses ───────────────────────
        if status == "206":
            if active["t_first"] is None:
                active["t_first"] = ts
            active["t_last"]  = ts
            active["n"]      += 1
            active["bytes"]  += body

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
        print("Usage: python parse_log_nosentinel.py <access.log> [output.csv]")
        sys.exit(1)
    logfile = sys.argv[1]
    outfile = sys.argv[2] if len(sys.argv) > 2 else "results.csv"
    parse(logfile, outfile)
