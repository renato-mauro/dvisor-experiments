# Third-Party Notices

This repository's own code is MIT-licensed (see LICENSE) and its result
CSVs are CC BY 4.0-licensed (see DATA_LICENSE.md). Neither license extends
to the third-party components listed below, which remain under their
respective owners' terms.

## Vendored files (excluded from LICENSE)

- **`dvisor-tests-auto/runner/js/dvisor-web-lib.min.js`** — minified Dvisor
  web engine bundle, vendored as-is to drive the headless benchmark runner.
  It is not authored by this repository and is **not** covered by the MIT
  license above. It carries no license header in its distributed form;
  redistribution or reuse outside this benchmark should be confirmed with
  the Dvisor project directly.

## Runtime dependencies (fetched, not vendored)

- **`@duckdb/duckdb-wasm`** (loaded at runtime from `esm.sh` by
  `dvisor-tests-auto/runner/duck-runner.html`) — MIT License.
  https://github.com/duckdb/duckdb-wasm

## npm dependencies (`dvisor-tests-auto/package.json`)

- **playwright** `1.60.0` — Apache License 2.0.
  https://github.com/microsoft/playwright

## Python dependencies (`webserver/analysis/requirements.txt`)

- **pandas** — BSD 3-Clause License. https://github.com/pandas-dev/pandas
- **tabulate** — MIT License. https://github.com/astanin/python-tabulate

## Container base images

These are pulled at build time, not redistributed in this repository; each
remains under its own upstream license.

- `mcr.microsoft.com/playwright:v1.60.0-jammy` — Apache License 2.0
  (Microsoft) on Ubuntu 22.04 "jammy" (various OSS licenses).
- `python:3.12-slim` — Python Software Foundation License, on Debian
  (various OSS licenses).
- `alpine:3.20` — various OSS licenses (Alpine Linux).
- `nginx:alpine` — BSD 2-Clause License (nginx), on Alpine Linux.

## Benchmark data (excluded from this repository)

- **TPC-H `lineitem` data** — the Parquet files downloaded by
  `webserver/scripts/download_data.sh` (per
  `webserver/scripts/manifest.tsv`) are derived from the TPC-H benchmark
  specification published by the Transaction Processing Performance Council
  (TPC). They are not committed to this repository and are not covered by
  LICENSE or DATA_LICENSE.md. Refer to TPC's own terms of use for the TPC-H
  specification and generated data: https://www.tpc.org/tpc_documents_current_versions/current_specifications5.asp
