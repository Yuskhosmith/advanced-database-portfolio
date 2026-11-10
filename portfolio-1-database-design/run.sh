#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../scripts/env.sh"
cd "$(dirname "$0")"

echo ">> (re)creating database $PGDATABASE"
dropdb --if-exists "$PGDATABASE"
createdb "$PGDATABASE"

for f in sql/01_schema.sql sql/02_reference_data.sql sql/03_generate_data.sql sql/04_logic.sql sql/05_security.sql; do
  echo ">> running $f"
  start=$(date +%s)
  $PSQL -f "$f" > /dev/null
  echo "   done in $(( $(date +%s) - start ))s"
done | tee results/build_log.txt

echo ">> verification"
$PSQL -f sql/06_verify.sql 2>&1 | tee results/verification_output.txt

echo ">> schema dump"
pg_dump --schema-only --no-owner --no-privileges "$PGDATABASE" > results/schema_dump.sql
$PSQL -c '\d+ enrollment' > results/enrollment_table_definition.txt
