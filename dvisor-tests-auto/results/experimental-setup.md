# Experimental Setup — Dvisor Benchmark

> Context document for paper writing assistance.
> Focus: experimental framework. Results are in the accompanying data files.

---

## System Under Study

Two in-browser WebAssembly query engines are compared over TPC-H data:

**Dvisor** is a progressive, parallel query engine running entirely in the browser via WebAssembly. It partitions the input data across multiple worker threads, each scanning an independent portion of the dataset. Partial aggregation results are merged and emitted as *frames* — incremental result updates delivered to the application as data is being scanned. This allows the user to observe evolving query results before the full dataset has been processed. The primary configuration uses **4 worker threads**.

**DuckDB-WASM** is the browser-compiled version of DuckDB. It executes queries in a single-threaded, non-progressive batch model: the query runs to completion and delivers a single result frame. It serves as the baseline.

---

## On the Comparability of Thread Configurations (Dvisor 4T vs. DuckDB-WASM 1T)

**[DRAFT — needs author review/editing before inclusion in the paper]**

A natural objection to this comparison is that Dvisor runs with 4 worker threads while DuckDB-WASM runs single-threaded — on its face, an unequal footing. Before accepting this asymmetry, we investigated whether DuckDB-WASM could be reconfigured to run multi-threaded (matching Dvisor's worker count) to produce a thread-parity comparison. We found that doing so is impractical and would itself be unrepresentative of how DuckDB-WASM is actually deployed, for four concrete reasons:

1. **Cross-origin isolation is required, and rarely enabled in practice.** DuckDB-WASM's multi-threaded build depends on `SharedArrayBuffer`, which browsers only expose to pages that opt into *cross-origin isolation* via the `Cross-Origin-Opener-Policy` and `Cross-Origin-Embedder-Policy` HTTP response headers. These headers are seldom enabled on production websites because they break common third-party embeds, ad scripts, and CDN-hosted assets that don't send matching CORP/CORS headers. **In other words, single-threaded execution is DuckDB-WASM's default and realistic deployment configuration** — not a constraint the experimental design imposed to disadvantage it.

2. **The multi-threaded build cannot be loaded from a public CDN.** Even with cross-origin isolation enabled, the multi-threaded ("COI"/pthread) DuckDB-WASM bundle fails to load from jsDelivr: browsers refuse to construct a `Worker` from a cross-origin script URL, which the library's pthread pool requires (`SecurityError: Failed to construct 'Worker'`). The only workaround is to download and self-host a ~34 MB WebAssembly binary plus its worker scripts on the same origin as the page — a deployment burden that essentially no application assumes, and a significant departure from how every other measurement in this study loads engine code (via public CDN).

3. **Compile cost is incompatible with the measurement protocol.** Our methodology requires a fresh, cache-free browser context per run (Section "Measurement Protocol") to ensure independent, reproducible measurements. Under this constraint, compiling the 34 MB multi-threaded WASM module took several minutes per page load in headless Chromium — overhead orders of magnitude larger than the queries being measured, and itself a confound that would dominate any timing comparison.

4. **The multi-threaded build is incompatible with the Parquet extension.** Having forced the multi-threaded bundle to load (self-hosted, cross-origin-isolated), attempting to load the `parquet` extension — required by all three benchmark queries, since they all read Parquet files — failed with `LinkError: WebAssembly.Instance(): Import ... mismatch in shared state of memory, declared = 0, imported = 1`. This indicates that, at the time of writing, the publicly distributed multi-threaded DuckDB-WASM core and the publicly distributed Parquet extension are built against incompatible memory models and cannot be combined — independent of any choice we made.

**Suggested framing for the paper:** rather than an artificial asymmetry favoring Dvisor, the comparison reflects each engine's *natural operating mode* as actually experienced by end users — DuckDB-WASM single-threaded, as it runs in virtually all real browser deployments today, versus Dvisor in its intended parallel configuration (4 workers). Forcing thread parity would have required a non-representative, custom-built deployment (self-hosted multi-megabyte binaries, relaxed security headers, incompatible extensions) that practitioners could not reasonably replicate — which would *reduce* external validity rather than improve fairness. We therefore present the 4T-vs-1T comparison as the realistic, representative one, and state explicitly (here / in a footnote / in a "Threats to Validity" subsection — *author to decide placement*) that the difference in thread counts is a property of each system's typical real-world deployment, not a methodological shortcut.

*(Author note: consider whether to (a) keep this as an explicit justification paragraph in the main experimental setup, (b) move it to a "Threats to Validity" / "Limitations" section, or (c) condense it to a footnote with this document as backing material. The four numbered points above can be trimmed depending on space — point 1 is the most important to retain, as it is the crux of the "realistic deployment" argument.)*

---

## Dataset

Data was generated using the **TPC-H module bundled with DuckDB** (`duckdb` CLI, `CALL dbgen(...)`). The lineitem table was exported to **Parquet** for each scale factor. All files use a **row group size of 500,000 rows**, which directly determines the granularity of both Dvisor's frame emission (one frame per row group processed across all threads) and DuckDB-WASM's predicate pushdown.

Scale factors evaluated: **SF = 1, 10, 30, 50, 100**, corresponding to approximately 6 M, 60 M, 180 M, 300 M, and 600 M rows respectively.

---

## Queries

Three queries operate exclusively on the `lineitem` table (no joins), defined as simplified projections and aggregations:

| Query | Operation | Grouping |
|-------|-----------|----------|
| Q01 | Count rows | By `l_shipdate` |
| Q02 | Sum revenue and quantity | By month (date truncated) |
| Q03 | Sum discounted revenue and quantity, date-filtered | By month, `shipdate ∈ [1993-01-01, 1994-12-31]` |

**Q03 uses a dedicated Parquet file** (`lineitem-sf{N}-shipdate.parquet`) in which rows are **sorted by `l_shipdate`**. This layout enables row-group-level predicate pushdown: row groups whose min/max shipdate range falls entirely outside the query filter are skipped without scanning, significantly reducing the amount of data read. For all other queries, the standard `lineitem-sf{N}.parquet` file is used (unsorted).

---

## On the Choice of Query Types (Aggregations Only — No Raw Selections / ORDER BY)

**[DRAFT — needs author review/editing before inclusion in the paper]**

A natural question is why the benchmark contains only **grouped aggregation queries** (counts, sums, with and without filtering) and omits other common SQL patterns such as **raw row selection** (`SELECT * ... LIMIT n`) or **sorting** (`ORDER BY`). This was a deliberate scoping decision grounded in the target use case for both engines — **in-browser data visualization** — rather than an oversight or a convenience choice:

1. **Aggregation is the dominant — arguably the only — query pattern behind data visualization.** Charts, dashboards, and exploratory-analysis UIs are built almost exclusively on top of grouped aggregates: a time series is `GROUP BY date/month` + `SUM`/`COUNT`/`AVG`; a histogram is a `GROUP BY bucket` + `COUNT`; a bar chart comparing categories is a `GROUP BY category` + aggregate. Q01–Q03 are direct instances of these canonical visualization queries (a per-day count → histogram/distribution; a per-month revenue/quantity sum → time series; a filtered, date-bounded version of the same → a "zoomed" time series). Raw row selection and `ORDER BY` of un-aggregated data, by contrast, are **not** how visualizations are typically populated — a chart is never rendered by paging through millions of individual `lineitem` rows.

2. **Progressive delivery — the central property under study — is meaningful for aggregation, not for raw scans.** Dvisor's defining feature, and the reason TTF/frame-based metrics exist at all, is that **partial aggregates are statistically meaningful and incrementally refinable**: a partial `SUM`/`COUNT` over the first N row groups is already a valid (if imprecise) estimate of the final answer, and a chart can usefully redraw itself as more groups arrive. A partial result from `SELECT * LIMIT n` or a partial pass of `ORDER BY` carries no such property — the "first 10,000 unsorted rows" is not a meaningful intermediate visualization state, and a partially-sorted result is not a valid prefix of the final sorted output. Including such queries would not exercise the progressive-execution model in any meaningful way; at best they would degrade to the same batch behavior DuckDB-WASM already exhibits, adding queries that cannot differentiate the two engines on the dimension this study investigates.

3. **The three chosen queries already span the relevant variation axes for aggregation workloads.** Q01 (unfiltered count, fine grouping), Q02 (unfiltered sum, coarse grouping), and Q03 (filtered sum, coarse grouping, sorted/skippable layout) together vary: presence/absence of a `WHERE` filter, grouping granularity, aggregate function complexity (`COUNT` vs. arithmetic `SUM` expressions), and — via Q03's sorted layout — the engines' ability to exploit row-group skipping. This covers the principal sources of performance variation within the aggregation-query space that visualization workloads actually exercise, without diluting the study with patterns (raw scans, sorts) that fall outside that space.

**Suggested framing for the paper:** state explicitly, early in the query description, that the query set was scoped to **grouped aggregation queries because that is what data-visualization workloads consist of**, and that this is a deliberate alignment between the benchmark and the systems' target domain — not a limitation of coverage. If reviewers want broader SQL coverage as future work, that can be acknowledged directly: extending the comparison to selection/sorting workloads would be testing a *different* use case (e.g., tabular data browsing) than the one Dvisor and this study target, and would warrant its own benchmark design (e.g., progressive/streaming-sort semantics, which is itself an open research question).

*(Author note: if useful, this point pairs naturally with the Dataset section's description of row-group size and the Q03 discussion of the viability guard operator — both are properties that matter specifically *because* the workload is aggregation-and-filter-oriented.)*

---

## Infrastructure

### Client machine
- **Hardware:** Apple MacBook, Apple M1 chip, 8 GB RAM
- **Browser:** Chromium (headless), driven by Playwright
- **Execution:** Each experiment run uses a fresh browser context (no HTTP cache) to ensure independent network fetches

### LAN scenario (`source = local`)
- Parquet files are served by an **nginx HTTP server running inside a Docker container** on the same MacBook
- The browser accesses files via `http://localhost:8080/data/`
- Traffic is routed through Docker's internal network stack on the host machine

### WAN scenario (`source = wan`)
- Parquet files are hosted on a **university research server** (`capricorni.eic.cefet-rj.br`, CEFET-RJ)
- The browser fetches files over the public internet from the client machine
- No CDN or caching layer between client and server

---

## Measurement Protocol

- **Runs per combination:** 3 independent runs
- **Reported statistic:** median across the 3 runs
- **Metrics recorded per run:**
  - **TTF** — Time to First Frame (ms): elapsed time from query start until the first partial result is delivered. For DuckDB-WASM, TTF = TQ (no intermediate frames).
  - **TQ** — Total Query Time (ms): elapsed time until the last frame, i.e., the full result is available.
  - **Rows scanned:** total rows processed (used to compute throughput).
  - **Frames emitted:** number of progressive result updates (always 1 for DuckDB-WASM).
  - **Throughput** (MR/s): millions of rows scanned per second = rows / (TQ / 1000) / 1e6.
  - **FPS:** frames per second = frames / (TQ / 1000).

- **Timing scope:** the timer starts immediately before query submission and stops after the last frame is received. DuckDB-WASM initialization (WASM module load) is performed once before timing begins and is excluded from measurements.

---

## On the Number of Runs and Statistical Reporting (n=3, median)

**[DRAFT — needs author review/editing before inclusion in the paper]**

A natural concern is whether **3 runs per combination** is enough to support statistically meaningful conclusions, especially given that increasing this number is costly: the experimental matrix spans 60 combinations (2 engines × 2 sources × 3 queries × 5 scale factors), and the largest scale factor (SF=100, ~600M rows) alone can take minutes per run — multiplying replications multiplies total experiment wall-clock time directly, including over a WAN link whose latency is outside our control.

We chose **n=3 with the median as the reported statistic** (rather than, e.g., mean ± standard deviation over a larger sample) for the following reasons:

1. **The median is robust to the dominant noise source in this setting.** Browser-based, network-involved measurements are subject to occasional one-off outliers — a GC pause, an OS scheduling hiccup, a transient network stall — that inflate a single run without reflecting the system's typical behavior. The median of 3 runs discards exactly one such outlier (the max or the min) and reports the remaining "typical" value, which is a stronger guarantee against single-outlier distortion than a mean would provide at the same sample size.

2. **The alternative — increasing n — has a steep, asymmetric cost.** Because total experiment time scales linearly with n while the matrix already spans five orders of magnitude in data size (SF 1 → 100), doubling or tripling n would primarily inflate the cost of the *largest* (and slowest) combinations, which are also the *least* likely to be re-run if something goes wrong mid-experiment (each fresh-context run reloads/recompiles engine code from scratch, by design — see "Measurement Protocol"). A uniform increase in n is therefore a poor use of the available time budget.

3. **Small-n medians are an established practice in systems benchmarking.** Reporting median (or best-of-N) over a handful of runs is common in systems and database performance papers precisely because end-to-end, real-environment measurements are expensive and noisy in ways that make large-N statistical machinery (confidence intervals assuming normality, etc.) both costly to obtain and not necessarily more informative than a robust point estimate.

**Suggested framing for the paper:** state n=3 and median explicitly as a deliberate choice driven by (a) the cost of the experimental matrix (especially at SF=100 and over WAN), and (b) the suitability of the median as a robust point estimate for this kind of noisy, single-outlier-prone measurement — rather than presenting it as a limitation to apologize for. If reviewers push back on statistical power, a defensible secondary move (not yet performed) would be to selectively re-run only the highest-variance cells — e.g., WAN + large SF, where network jitter is most pronounced — with additional replications, rather than uniformly inflating all 180 runs to, say, 5 or 10.

*(Author note: if you do end up running additional replications for select cells, the existing `run.js --config=<file>` mechanism supports targeted re-runs without disturbing the rest of the dataset — see `experiment-config-sentinel.json` for a worked example of a minimal-impact targeted config.)*

---

## Automation

Experiments were automated using a **Playwright headless Chromium** runner (`run.js`). For each combination of (source × threads × query × SF), the runner:
1. Opens a fresh browser context (empty cache)
2. Loads a minimal HTML runner page that imports the engine library and executes the query
3. Waits for the `window.__done` signal
4. Collects `{ttf, tq, rows, frames}` from `window.__result`
5. Appends the run to `results/dvisor_results.json` / `results/duckdb_results.json`

Results are persisted after every individual run (crash-safe). The script skips combinations that already have the target number of runs, making it safe to re-run after interruptions.

---

## Experimental Matrix

| Dimension | Values |
|-----------|--------|
| Engine | Dvisor (4T), DuckDB-WASM |
| Source | LAN, WAN |
| Query | Q01, Q02, Q03 |
| Scale factor | 1, 10, 30, 50, 100 |
| Runs | 3 (median reported) |

Total combinations: 2 engines × 2 sources × 3 queries × 5 SFs = **60 combinations**, 180 individual runs.

---

## Notes for the Paper

- The LAN scenario measures **compute-bound** performance (network is negligible on loopback/Docker).
- The WAN scenario measures the **full pipeline** including real network transfer latency and throughput.
- TTF is the key differentiator of progressive engines: a low TTF means the user receives actionable partial results early, even when TQ is high.
- The row group size (500K rows) controls the frame granularity for Dvisor and the predicate pushdown granularity for both engines. This is a tuneable parameter worth discussing.
- Q03's sorted-by-shipdate layout benefits both engines via row-group-level skipping. Dvisor applies a **viability guard operator** — an algebraic operator that determines whether a row group satisfies a predicate before reading it; predicate pushdown is a specific instance of this more general mechanism. Row groups are distributed across threads in **round-robin** order, so skipping is applied uniformly regardless of thread count.
