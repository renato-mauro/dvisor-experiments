#!/usr/bin/env bash
# Downloads the TPC-H lineitem parquet files (+ meta.json) used by this
# experiment. Files are hosted on Dropbox (public "anyone with the link"
# shares) since they're too large to keep in the git repo (up to ~24GB
# per file, ~85GB total). URLs are listed in scripts/manifest.tsv.
#
# Usage:
#   ./scripts/download_data.sh                 # download everything
#   ./scripts/download_data.sh sf1 sf10         # only these scale factors
#   ./scripts/download_data.sh --list           # show available files
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/manifest.tsv"
DATA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/data"

if [[ "${1:-}" == "--list" ]]; then
    cut -f1 "$MANIFEST"
    exit 0
fi

FILTER=("$@")
if [[ ${#FILTER[@]} -eq 0 && -n "${DATA_SCALES:-}" ]]; then
    read -r -a FILTER <<< "$DATA_SCALES"
fi

mkdir -p "$DATA_DIR"

matches_filter() {
    local fname="$1"
    [[ ${#FILTER[@]} -eq 0 ]] && return 0
    for sf in "${FILTER[@]}"; do
        [[ "$fname" == *"-${sf}."* || "$fname" == *"-${sf}-"* ]] && return 0
    done
    return 1
}

while IFS=$'\t' read -r fname url; do
    [[ -z "$fname" ]] && continue
    matches_filter "$fname" || continue

    dest="${DATA_DIR}/${fname}"

    if [[ -f "$dest" ]]; then
        remote_size=$(curl -sIL "$url" | awk -F': ' 'tolower($1)=="content-length"{v=$2} END{print v}' | tr -d '\r')
        local_size=$(stat -f%z "$dest" 2>/dev/null || stat -c%s "$dest")
        if [[ -n "$remote_size" && "$remote_size" == "$local_size" ]]; then
            echo "skip  ${fname} (already downloaded)"
            continue
        fi
    fi

    echo "fetch ${fname}"
    curl -fL -C - --progress-bar -o "$dest" "$url"
done < "$MANIFEST"

echo "Done. Data in ${DATA_DIR}"
