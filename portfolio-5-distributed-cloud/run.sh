#!/usr/bin/env bash
# KEEP_RUNNING=1 leaves the clusters up
set -euo pipefail
source "$(dirname "$0")/../scripts/env.sh"
cd "$(dirname "$0")"
PY="$REPO_ROOT/.venv/bin/python"

echo ">> A. PostgreSQL primary/standby"
scripts/pg_replication_setup.sh setup 2>&1 | tee results/pg_replication_setup.txt
"$PY" scripts/pg_replication_demo.py 2>&1 | tee results/pg_replication_output.txt

echo ">> B. MongoDB sharded cluster"
pgrep -f "mongo-p4" >/dev/null || ../portfolio-4-nosql/scripts/mongo_standalone.sh start
"$PY" scripts/mongo_cluster.py start 2>&1 | tee results/mongo_cluster_start.txt
"$PY" scripts/mongo_sharding_demo.py 2>&1 | tee results/mongo_sharding_output.txt
"$PY" scripts/mongo_cluster.py status 2>&1 | tee -a results/mongo_sharding_output.txt

if [ "${KEEP_RUNNING:-0}" != "1" ]; then
  scripts/pg_replication_setup.sh stop
  "$PY" scripts/mongo_cluster.py stop
fi
