#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../scripts/env.sh"
cd "$(dirname "$0")"

echo ">> Part A: COMMIT / ROLLBACK / SAVEPOINT (single session, psql)"
psql -X -f sql/01_commit_rollback_savepoint.sql 2>&1 | tee results/partA_commit_rollback_savepoint.txt

echo ">> Part B: concurrency experiments (multiple sessions)"
"$REPO_ROOT/.venv/bin/python" scripts/concurrency_demo.py 2>&1 | tee results/partB_concurrency_output.txt
