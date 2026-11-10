#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../scripts/env.sh"
cd "$(dirname "$0")"

echo ">> benchmark (baseline vs optimised)"
"$REPO_ROOT/.venv/bin/python" benchmark.py --runs "${RUNS:-5}" | tee results/benchmark_console.txt

echo ">> query results (first 25 rows of each query)"
: > results/query_results.txt
for f in sql/queries/*.sql; do
  { echo "==================== $f"; head -n 2 "$f"; $PSQL -P footer=on -f "$f" | head -n 28; echo; } >> results/query_results.txt
done
