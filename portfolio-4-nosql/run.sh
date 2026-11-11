#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../scripts/env.sh"
cd "$(dirname "$0")"
PY="$REPO_ROOT/.venv/bin/python"
export MONGO_URI="${MONGO_URI:-mongodb://127.0.0.1:27117}"

pgrep -f "mongo-p4" >/dev/null || scripts/mongo_standalone.sh start

echo ">> ETL PostgreSQL -> MongoDB"
"$PY" scripts/etl_postgres_to_mongo.py | tee results/etl_output.txt

echo ">> sample documents"
"$PY" - <<'PY'
import json, os
from pymongo import MongoClient
db = MongoClient(os.environ["MONGO_URI"])["ausrp"]
doc = db.students.find_one({"_id": "AU/2022/00007"})
doc["semesters"] = doc["semesters"][:2] + [{"...": f"{len(doc['semesters']) - 2} more semesters omitted"}]
json.dump(doc, open("results/sample_student_document.json", "w"), indent=2, default=str)
json.dump([db.courses.find_one({"_id": c}) for c in ("CSC301", "MCB301", "EEE301", "ACC301")],
          open("results/sample_course_documents.json", "w"), indent=2, default=str)
json.dump(db.get_collection("students").options(), open("results/students_validator.json", "w"), indent=2, default=str)
PY

echo ">> NoSQL workload"
"$PY" scripts/mongo_workload.py 2>&1 | tee results/workload_output.txt
