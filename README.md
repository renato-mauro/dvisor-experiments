# dvisor-paper-experiments

Benchmark harness comparing **Dvisor** (progressive, multi-threaded WebAssembly
query engine) against **DuckDB-WASM** (single-threaded baseline) over TPC-H
`lineitem` data at multiple scale factors, served over a real HTTP connection
(LAN) so that request/response timing is captured, not just in-process query
time.

Two projects, one pipeline:

- **`webserver/`** — nginx server that serves the Parquet data and captures
  a detailed access log (per-request timing, byte ranges), plus a Python
  analysis step that turns that log into a network-level report.
- **`dvisor-tests-auto/`** — Playwright-driven automated runner that drives
  headless Chromium through the Dvisor and DuckDB-WASM query paths and
  records timing/row-count results.

## TL;DR

```bash
./run-experiment.sh quick
```

This single command, running entirely in Docker:

1. builds the images,
2. starts nginx and downloads any missing TPC-H Parquet files (skips files
   already present),
3. runs the automated Dvisor/DuckDB-WASM experiments in headless Chromium
   (also in Docker, LAN only — see [Scope](#scope)),
4. parses the nginx access log into a network-level report,
5. writes a combined Markdown report to `results/<tier>-<timestamp>/report.md`,
6. tears the containers back down.

Requires Docker with Compose v2. No local Node/Python/Playwright install
needed — everything runs in containers.

## Tiers

| Tier | Scale factors | Approx. data | Use case |
|---|---|---|---|
| `quick` | 1, 10 | ~5 GB | Fast smoke test |
| `medium` | 1, 10, 30, 50 | ~40 GB | Mid-size run |
| `full` | 1, 10, 30, 50, 100 | ~86 GB | Full paper run |

```bash
./run-experiment.sh quick
./run-experiment.sh medium
./run-experiment.sh full

# Extra flags are passed through to dvisor-tests-auto/run.js:
./run-experiment.sh quick --clear     # discard existing results, start fresh
./run-experiment.sh quick --dvisor    # only the Dvisor engine
./run-experiment.sh quick --duckdb    # only DuckDB-WASM
```

Each tier maps to `dvisor-tests-auto/experiment-config-<tier>.json`. Edit
those files to change queries, thread counts, or runs-per-combination.
Re-running is incremental — combinations that already have enough runs are
skipped, so interrupting and re-running is safe.

## Scope: LAN only

All configs use `"sources": ["local"]`. The underlying test harness also
supports a `"wan"` source (fetching data from a public Google Cloud Storage
bucket to measure real internet latency/throughput), but that is **not**
part of this experiment set — every run here measures the local Docker
network only.

## Output

Each run produces `results/<tier>-<timestamp>/` — Markdown only, no raw CSVs:

- `report.md` — combined report: Dvisor/DuckDB timing tables (median TTF,
  TQ, rows, throughput) plus the nginx-log-derived network capture (request
  count and bytes transferred per experiment), per scale factor and query.
- `network-summary.md` — the same network capture section, standalone.

Raw, cumulative data also lives in `dvisor-tests-auto/results/` (JSON per
engine, plus `runs.csv`/`tables.md`/`tables.tex`) and `webserver/network-report/`
(`results.csv`/`network-summary.md`) — these accumulate across runs and are
what `report.md` is built from.

## Data

The TPC-H Parquet files (~86 GB total across all scale factors) are not
committed to the repo. `run-experiment.sh` downloads only the scale factors
the chosen tier needs via `webserver/scripts/download_data.sh`, from the
URLs listed in `webserver/scripts/manifest.tsv`. Already-downloaded files
(checked by size) are skipped, so re-running a tier — or moving from
`quick` to `medium` to `full` — only fetches what's missing.

## Architecture

```
run-experiment.sh
  └─ docker compose (webserver/docker-compose.yml)
       ├─ data-init   downloads missing Parquet files (webserver/scripts)
       ├─ nginx       serves data/ on :8080, logs every request
       ├─ tests       Playwright + headless Chromium (dvisor-tests-auto),
       │               network_mode: service:nginx, so localhost:8080
       │               inside the container reaches nginx directly
       └─ analysis    parses nginx's access.log into a network-level report
```
