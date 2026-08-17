#!/usr/bin/env bash
#
# Single-command entry point: brings up the web server, fetches the missing
# TPC-H parquet files, runs the automated Dvisor/DuckDB experiments (all
# inside Docker), parses the nginx access log, and writes a combined
# Markdown report. LAN only — no WAN runs are part of this experiment set.
#
# Usage:
#   ./run-experiment.sh <quick|medium|full> [extra run.js flags]
#
# Tiers:
#   quick   SF 1, 10             (~5GB data)   fast smoke test
#   medium  SF 1, 10, 30, 50     (~40GB data)
#   full    SF 1, 10, 30, 50, 100 (~86GB data) full paper run
#
# Examples:
#   ./run-experiment.sh quick
#   ./run-experiment.sh quick --clear
#   ./run-experiment.sh full --dvisor
set -euo pipefail

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

TIER="${1:-}"
shift || true

case "$TIER" in
  quick)  CONFIG="experiment-config-quick.json";  DATA_SCALES="sf1 sf10" ;;
  medium) CONFIG="experiment-config-medium.json"; DATA_SCALES="sf1 sf10 sf30 sf50" ;;
  full)   CONFIG="experiment-config-full.json";   DATA_SCALES="sf1 sf10 sf30 sf50 sf100" ;;
  *) usage; exit 1 ;;
esac

# Exported for the whole script: every `docker compose` invocation below must
# see the same DATA_SCALES, otherwise Compose treats the data-init service's
# config as changed and recreates + reruns it *without* the filter, which
# downloads every scale factor instead of just the ones this tier needs.
export DATA_SCALES

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$ROOT_DIR/webserver/docker-compose.yml"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_DIR="$ROOT_DIR/results/${TIER}-${STAMP}"

compose() { docker compose -f "$COMPOSE_FILE" "$@"; }

step() { echo; echo "==> [$1/5] $2"; }

SECONDS=0
echo "==> Tier: $TIER  (config=$CONFIG, scale factors: $DATA_SCALES)"

cleanup() {
  echo "==> Stopping services..."
  compose down
}
trap cleanup EXIT

# 1. Archive the previous access log so this run's network capture is clean.
step 1 "Preparing..."
LOGFILE="$ROOT_DIR/webserver/logs/access.log"
if [[ -s "$LOGFILE" ]]; then
  mv "$LOGFILE" "${LOGFILE}.${STAMP}.bak"
  echo "    Archived previous access.log -> $(basename "$LOGFILE").${STAMP}.bak"
fi

# 2. Build images, then bring up data-init (downloads only the missing SFs) + nginx.
step 2 "Building images..."
compose --profile tools build

step 2 "Starting server (downloading any missing scale factors)..."
compose up -d nginx

# 3. Run the automated experiments (Playwright, inside Docker, LAN only).
step 3 "Running experiments ($CONFIG)..."
compose --profile tools run --rm tests --config="$CONFIG" "$@"

# 4. Parse the nginx access log into a network-level report.
step 4 "Running log analysis..."
compose --profile tools run --rm analysis

# 5. Assemble the final Markdown report.
step 5 "Assembling report..."
mkdir -p "$REPORT_DIR"
{
  echo "# Experiment Report — ${TIER} (SFs: ${DATA_SCALES})"
  echo
  echo "- Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- Config: dvisor-tests-auto/${CONFIG}"
  echo "- Mode: LAN only"
  echo
  if [[ -f "$ROOT_DIR/dvisor-tests-auto/results/tables.md" ]]; then
    cat "$ROOT_DIR/dvisor-tests-auto/results/tables.md"
  fi
  echo
  if [[ -f "$ROOT_DIR/webserver/figures/network-summary.md" ]]; then
    cat "$ROOT_DIR/webserver/figures/network-summary.md"
  fi
} > "$REPORT_DIR/report.md"

cp "$ROOT_DIR/dvisor-tests-auto/results/runs.csv" "$REPORT_DIR/" 2>/dev/null || true
cp "$ROOT_DIR/webserver/figures/results.csv" "$REPORT_DIR/network-results.csv" 2>/dev/null || true

ELAPSED=$SECONDS
echo
printf "==> Done in %02d:%02d:%02d. Report: %s\n" $((ELAPSED/3600)) $((ELAPSED%3600/60)) $((ELAPSED%60)) "$REPORT_DIR/report.md"
