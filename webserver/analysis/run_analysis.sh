#!/bin/sh
set -e

LOGFILE=/logs/access.log
OUTDIR=/network-report
CSV=$OUTDIR/results.csv

echo "==> Parsing log..."
python parse_log.py "$LOGFILE" "$CSV"

echo "==> Building network report..."
python network_report.py "$CSV" "$OUTDIR/network-summary.md"

