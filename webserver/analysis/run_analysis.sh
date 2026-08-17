#!/bin/sh
set -e

LOGFILE=/logs/access.log
CSV=/figures/results.csv
FIGDIR=/figures

echo "==> Parsing log..."
python parse_log.py "$LOGFILE" "$CSV"

echo "==> Building network report..."
python network_report.py "$CSV" "$FIGDIR/network-summary.md"

