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

# 1. The access log accumulates across runs, same as dvisor-tests-auto's
# results (so the network capture stays consistent with the Dvisor/DuckDB
# tables, which are also cumulative across all history, not just this run).
# Only reset it when --clear is passed, mirroring run.js's own --clear.
step 1 "Preparing..."
LOGFILE="$ROOT_DIR/webserver/logs/access.log"
CLEAR=0
for arg in "$@"; do [[ "$arg" == "--clear" ]] && CLEAR=1; done
if [[ "$CLEAR" -eq 1 && -s "$LOGFILE" ]]; then
  mv "$LOGFILE" "${LOGFILE}.${STAMP}.bak"
  echo "    --clear: archived previous access.log -> $(basename "$LOGFILE").${STAMP}.bak"
fi

# 2. Build images, then bring up data-init (downloads only the missing SFs) + nginx.
step 2 "Building images..."
compose --profile tools build

step 2 "Starting server (downloading any missing scale factors)..."
compose up -d nginx

# `run --no-deps` below is intentional: nginx is already confirmed healthy by
# this point, so we skip Compose's dependency resolution for the `tests`/
# `analysis` runs. Without --no-deps, every `run` re-walks nginx's own
# dependency chain and reruns data-init from scratch (a second full pass of
# per-file network HEAD checks against the manifest URLs) even though nginx
# is already up — harmless, but slow and easy to mistake for a redownload.
until [[ "$(compose ps -q nginx | xargs docker inspect -f '{{.State.Health.Status}}' 2>/dev/null)" == "healthy" ]]; do
  sleep 1
done

# 3. Run the automated experiments (Playwright, inside Docker, LAN only).
step 3 "Running experiments ($CONFIG)..."
RUNS_CSV="$ROOT_DIR/dvisor-tests-auto/results/runs.csv"
RUNS_BEFORE=$( [[ -f "$RUNS_CSV" ]] && wc -l < "$RUNS_CSV" || echo 0 )

compose --profile tools run --no-deps --rm tests --config="$CONFIG" "$@"

RUNS_AFTER=$( [[ -f "$RUNS_CSV" ]] && wc -l < "$RUNS_CSV" || echo 0 )
if [[ "$RUNS_AFTER" -eq "$RUNS_BEFORE" ]]; then
  echo
  echo "    NOTE: no new runs were executed — every combination in $CONFIG"
  echo "    already had enough historical runs (see 'skip' lines above)."
  echo "    report.md reflects all history to date, same as always; pass"
  echo "    --clear to force a fresh run instead of reusing history."
fi

# 4. Parse the nginx access log into a network-level report.
step 4 "Running log analysis..."
compose --profile tools run --no-deps --rm analysis

# 5. Assemble the final Markdown report.
step 5 "Assembling report..."
mkdir -p "$REPORT_DIR"
{
  echo "# Experiment Report — ${TIER} (SFs: ${DATA_SCALES})"
  echo
  echo "- Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- Config: dvisor-tests-auto/${CONFIG}"
  echo "- Mode: LAN only"
  if [[ "$RUNS_AFTER" -eq "$RUNS_BEFORE" ]]; then
    echo "- **No new runs executed** — every combination already had enough"
    echo "  historical runs. Everything below reflects all history to date,"
    echo "  not just this invocation. Pass \`--clear\` to force a fresh run."
  fi
  echo
  if [[ -f "$ROOT_DIR/dvisor-tests-auto/results/tables.md" ]]; then
    cat "$ROOT_DIR/dvisor-tests-auto/results/tables.md"
  fi
  echo
  if [[ -f "$ROOT_DIR/webserver/network-report/network-summary.md" ]]; then
    cat "$ROOT_DIR/webserver/network-report/network-summary.md"
  fi
} > "$REPORT_DIR/report.md"

# Markdown only — no raw CSVs. network-summary.md carries the per-experiment
# request count and bytes transferred (n_requests / total_bytes_mb columns),
# kept alongside report.md (which already embeds the same content) so it's
# also available standalone.
cp "$ROOT_DIR/webserver/network-report/network-summary.md" "$REPORT_DIR/" 2>/dev/null || true

ELAPSED=$SECONDS
echo
printf "==> Done in %02d:%02d:%02d. Report: %s\n" $((ELAPSED/3600)) $((ELAPSED%3600/60)) $((ELAPSED%60)) "$REPORT_DIR/report.md"
