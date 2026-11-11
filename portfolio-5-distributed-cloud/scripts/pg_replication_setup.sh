#!/usr/bin/env bash
# usage: pg_replication_setup.sh setup | stop
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
P5="$ROOT/portfolio-5-distributed-cloud"
PRIM="$ROOT/.data/pg-primary"
STBY="$ROOT/.data/pg-standby"
SRC_DB="${PGDATABASE:-university_portal}"

stop_all() {
  for d in "$PRIM" "$STBY"; do
    [ -f "$d/postmaster.pid" ] && pg_ctl -D "$d" stop -m fast >/dev/null 2>&1 || true
  done
}

if [ "${1:-setup}" = "stop" ]; then stop_all; echo "replication clusters stopped"; exit 0; fi

stop_all
rm -rf "$PRIM" "$STBY"
mkdir -p "$ROOT/.data"

echo ">> initdb primary"
initdb -D "$PRIM" --auth=trust -E UTF8 --locale=C >/dev/null
cat >> "$PRIM/postgresql.conf" <<EOF

# replication
port = 5433
listen_addresses = 'localhost'
unix_socket_directories = '/tmp'
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
wal_keep_size = 256MB
hot_standby = on
synchronous_standby_names = ''
shared_buffers = 128MB
EOF
cp "$PRIM/postgresql.conf" "$P5/config/postgresql.primary.conf"
cp "$PRIM/pg_hba.conf" "$P5/config/pg_hba.conf"
pg_ctl -D "$PRIM" -l "$PRIM/server.log" -w start >/dev/null

echo ">> load $SRC_DB into primary (pg_dump from :5432 | psql :5433)"
for r in uni_registrar uni_lecturer uni_student; do psql -X -q -h localhost -p 5433 -d postgres -c "CREATE ROLE $r NOLOGIN" ; done
createdb -h localhost -p 5433 "$SRC_DB"
pg_dump -h localhost -p 5432 "$SRC_DB" | psql -X -q -h localhost -p 5433 -d "$SRC_DB" >/dev/null
psql -X -q -h localhost -p 5433 -d "$SRC_DB" -c "ANALYZE"

echo ">> pg_basebackup -> standby (creates replication slot 'standby1', writes standby.signal)"
pg_basebackup -h localhost -p 5433 -D "$STBY" -R -X stream -C -S standby1 -c fast
cat >> "$STBY/postgresql.auto.conf" <<EOF
primary_conninfo = 'host=localhost port=5433 user=$(whoami) application_name=standby1'
port = 5434
EOF
sed "s| passfile=''[^']*''||" "$STBY/postgresql.auto.conf" > "$P5/config/postgresql.standby.auto.conf"
pg_ctl -D "$STBY" -l "$STBY/server.log" -w start >/dev/null

sleep 1
psql -X -h localhost -p 5433 -d postgres -c \
 "SELECT application_name, client_addr, state, sync_state, sent_lsn, replay_lsn FROM pg_stat_replication"
psql -X -h localhost -p 5434 -d postgres -Atc "SELECT 'standby in recovery: ' || pg_is_in_recovery()"
