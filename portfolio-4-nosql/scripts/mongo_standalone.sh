#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DB="$ROOT/.data/mongo-p4"; PORT="${MONGO_PORT:-27117}"
case "${1:-start}" in
  start) mkdir -p "$DB"
         mongod --dbpath "$DB" --port "$PORT" --bind_ip 127.0.0.1 --fork --logpath "$DB/mongod.log" >/dev/null
         echo "mongod running on 127.0.0.1:$PORT (dbpath $DB)";;
  stop)  pkill -f "mongod --dbpath $DB" && echo "mongod stopped" || echo "mongod was not running";;
esac
