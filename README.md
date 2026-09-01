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

**Environment note:** experiments for this paper were executed on both
Linux and macOS hosts. Since the pipeline runs entirely inside Docker
containers, results should be reproducible regardless of host OS, but this
has only been verified on those two.

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
./run-experiment.sh quick --dvisor    # only the Dvisor engine
./run-experiment.sh quick --duckdb    # only DuckDB-WASM
```

Each tier maps to `dvisor-tests-auto/experiment-config-<tier>.json`. Edit
those files to change queries, thread counts, or runs-per-combination.

Every invocation starts from zero: previous Dvisor/DuckDB results and the
nginx access log are cleared before running (`run-experiment.sh` always
passes `run.js --clear`). There is no resuming/skipping of a prior run —
each run is a clean, self-contained measurement.

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

Raw data also lives in `dvisor-tests-auto/results/` (JSON per engine, plus
`runs.csv`/`tables.md`/`tables.tex`) and `webserver/network-report/`
(`results.csv`/`network-summary.md`) — these are what `report.md` is built
from, and get wiped and regenerated fresh at the start of every run.

The raw CSVs behind the paper's own results are committed at
`dvisor-tests-auto/paperdata/` (`runs.csv` — per-run Dvisor/DuckDB-WASM
timings; `netstats.csv` — per-query network capture), so the reported
numbers can be reproduced or re-analyzed without re-running the experiments.

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

## License scope

This repository carries three separate licenses, each covering a different
part of it:

- **[LICENSE](LICENSE)** (MIT) — the original code: the experiment harness,
  orchestration scripts, configuration, and analysis code (`run-experiment.sh`,
  `dvisor-tests-auto/`, `webserver/`), excluding the items below.
- **[DATA_LICENSE.md](DATA_LICENSE.md)** (CC BY 4.0) — the result data in
  `dvisor-tests-auto/paperdata/` (`runs.csv`, `netstats.csv`) only.
- **[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)** — everything neither
  of the above covers: vendored third-party files (e.g. the Dvisor web
  engine bundle under `dvisor-tests-auto/runner/js/`), npm/Python
  dependencies, container base images, and the externally-hosted TPC-H
  benchmark data downloaded at run time.
