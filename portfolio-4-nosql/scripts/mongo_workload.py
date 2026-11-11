#!/usr/bin/env python3
"""MongoDB workload N1-N9, compared with PostgreSQL where relevant."""
import os
import secrets
import statistics
import time
from datetime import datetime, timedelta, timezone

import psycopg
from pymongo import ASCENDING, DESCENDING, MongoClient
from pymongo.errors import WriteError

PG_DSN = (f"dbname={os.environ.get('PGDATABASE', 'university_portal')} "
          f"host={os.environ.get('PGHOST', 'localhost')} port={os.environ.get('PGPORT', '5432')}")
MONGO_URI = os.environ.get("MONGO_URI", "mongodb://127.0.0.1:27117")
db = MongoClient(MONGO_URI)["ausrp"]

def banner(t):
    print("\n" + "=" * 90 + f"\n{t}\n" + "=" * 90)

def winning_plan_summary(explain):
    """Flatten the winning plan into 'STAGE <- STAGE (index)' and pull executionStats."""
    def walk(p, out):
        stage = p.get("stage", "?")
        if "indexName" in p:
            stage += f"({p['indexName']})"
        out.append(stage)
        for k in ("inputStage", "queryPlan"):
            if k in p:
                walk(p[k], out)
        for c in p.get("inputStages", []):
            walk(c, out)
        return out
    qp = explain.get("queryPlanner") or explain["stages"][0]["$cursor"]["queryPlanner"]
    es = explain.get("executionStats") or explain["stages"][0]["$cursor"]["executionStats"]
    return (" <- ".join(walk(qp["winningPlan"], [])),
            es["totalDocsExamined"], es["totalKeysExamined"], es["executionTimeMillis"], es["nReturned"])

def bench(fn, n=300):
    fn()
    times = []
    for _ in range(n):
        t = time.perf_counter()
        fn()
        times.append((time.perf_counter() - t) * 1000)
    return statistics.median(times), statistics.quantiles(times, n=100)[94]
def n1_transcript():
    banner("N1  Transcript of AU/2022/00007: one document read vs. relational join")
    doc = db.students.find_one({"_id": "AU/2022/00007"})
    print(f"{doc['_id']}  {doc['name']['first']} {doc['name']['last']}  {doc['programme']['name']}")
    print(f"semesters embedded: {len(doc['semesters'])}, courses: {sum(len(s['courses']) for s in doc['semesters'])}, "
          f"CGPA {doc['summary']['cgpa']} ({doc['summary']['class_of_degree']})")
    for s in doc["semesters"][:2]:
        print(f"  {s['session']} {s['term']:<6} GPA {s['gpa']}: " +
              ", ".join(f"{c['code']}={c['grade']}" for c in s["courses"]))
    print("  ...")
    import bson
    print(f"document size: {len(bson.encode(doc)):,} bytes (MongoDB limit 16 MB)")

    with psycopg.connect(PG_DSN) as pg:
        sql = open(os.path.join(os.path.dirname(__file__), "..", "..", "portfolio-2-query-optimisation",
                                "sql", "queries", "q01_student_transcript.sql")).read()
        pg_med, pg_p95 = bench(lambda: pg.execute(sql).fetchall())
    mg_med, mg_p95 = bench(lambda: db.students.find_one({"_id": "AU/2022/00007"}))
    print(f"\n{'engine':<44}{'median ms':>10}{'p95 ms':>9}")
    print(f"{'PostgreSQL: 6-table join (Q01), 48 rows':<44}{pg_med:>10.3f}{pg_p95:>9.3f}")
    print(f"{'MongoDB: find_one by _id, 1 document':<44}{mg_med:>10.3f}{mg_p95:>9.3f}")
    print("(client-side round trip, 300 runs each, warm cache, same machine)")

def n2_deans_list():
    banner("N2  Dean's list (top 3 active per department) - aggregation + window function")
    pipeline = [
        {"$match": {"status": "ACTIVE"}},
        {"$setWindowFields": {"partitionBy": "$department.code", "sortBy": {"summary.cgpa": -1},
                              "output": {"rank": {"$denseRank": {}}}}},
        {"$match": {"rank": {"$lte": 3}}},
        {"$project": {"_id": 1, "dept": "$department.code", "cgpa": "$summary.cgpa", "rank": 1,
                      "name": {"$concat": ["$name.first", " ", "$name.last"]}}},
        {"$sort": {"dept": 1, "rank": 1, "_id": 1}},
    ]
    rows = list(db.students.aggregate(pipeline))
    for r in rows[:9]:
        print(f"  {r['dept']}  #{r['rank']}  {r['_id']}  {r['name']:<24} {r['cgpa']}")
    print(f"  ... {len(rows)} rows")
    before = winning_plan_summary(db.command("explain", {"aggregate": "students", "pipeline": pipeline, "cursor": {}},
                                             verbosity="executionStats"))
    db.students.create_index([("status", ASCENDING), ("department.code", ASCENDING), ("summary.cgpa", DESCENDING)],
                             name="ix_status_dept_cgpa")
    after = winning_plan_summary(db.command("explain", {"aggregate": "students", "pipeline": pipeline, "cursor": {}},
                                            verbosity="executionStats"))
    for label, (plan, docs, keys, ms, n) in (("before index", before), ("after index", after)):
        print(f"  {label:<13} plan: {plan}\n  {'':<13} docsExamined={docs:,} keysExamined={keys:,} time={ms} ms")

def n3_email_lookup():
    banner("N3  Login lookup by e-mail: collection scan vs unique secondary index")
    email = db.students.find_one({"_id": "AU/2024/00003"})["email"]
    q = {"email": email}
    before = winning_plan_summary(db.students.find(q).explain())
    db.students.create_index("email", unique=True, name="ux_email")
    after = winning_plan_summary(db.students.find(q).explain())
    for label, (plan, docs, keys, ms, n) in (("before", before), ("after", after)):
        print(f"  {label:<7} {plan:<34} docsExamined={docs:>6,} keysExamined={keys} time={ms} ms")

def n4_graph():
    banner("N4  Graph model: full prerequisite chain of CSC412 ($graphLookup) vs SQL recursive CTE")
    res = list(db.courses.aggregate([
        {"$match": {"_id": "CSC412"}},
        {"$graphLookup": {"from": "courses", "startWith": "$prerequisites", "connectFromField": "prerequisites",
                          "connectToField": "_id", "as": "chain", "depthField": "depth"}},
        {"$project": {"chain": {"$sortArray": {"input": {"$map": {"input": "$chain", "in": {"code": "$$this._id",
                      "depth": "$$this.depth", "title": "$$this.title"}}}, "sortBy": {"depth": 1}}}}},
    ]))
    print("  MongoDB $graphLookup:")
    for c in res[0]["chain"]:
        print(f"    depth {c['depth']}: {c['code']}  {c['title']}")
    with psycopg.connect(PG_DSN) as pg:
        rows = pg.execute("""
            WITH RECURSIVE chain AS (
                SELECT cp.prereq_course_id AS course_id, 0 AS depth
                FROM course_prerequisite cp JOIN course c USING (course_id) WHERE c.course_code = 'CSC412'
                UNION ALL
                SELECT cp.prereq_course_id, ch.depth + 1
                FROM chain ch JOIN course_prerequisite cp ON cp.course_id = ch.course_id)
            SELECT ch.depth, c.course_code, c.title FROM chain ch JOIN course c USING (course_id) ORDER BY depth""").fetchall()
    print("  PostgreSQL WITH RECURSIVE:")
    for d, code, title in rows:
        print(f"    depth {d}: {code}  {title}")
    blocked = list(db.courses.aggregate([
        {"$match": {"_id": "CSC101"}},
        {"$graphLookup": {"from": "courses", "startWith": "$_id", "connectFromField": "_id",
                          "connectToField": "prerequisites", "as": "unlocks", "depthField": "depth"}},
        {"$project": {"unlocks": "$unlocks._id"}}]))
    print(f"  Failing CSC101 blocks (transitively): {sorted(blocked[0]['unlocks'])}")

def n5_flexible_schema():
    banner("N5  Flexible schema: polymorphic `attributes` per faculty (no NULL-filled columns)")
    for fac in ("FCI", "FNAS", "FEN", "FMS"):
        d = db.courses.find_one({"faculty": fac, "level": 300}, {"_id": 1, "attributes": 1})
        print(f"  {fac:<5} {d['_id']}: {d['attributes']}")
    n = db.courses.count_documents({"attributes.software": "MongoDB", "attributes.lab_hours": {"$gte": 2}})
    print(f"  courses that use MongoDB in a lab of >= 2 hours: {n}")
    n = db.courses.count_documents({"attributes.safety_training_required": True})
    print(f"  courses requiring laboratory safety training: {n}")

def n6_post_result():
    banner("N6  Posting a result: single-document atomic update with arrayFilters")
    doc = db.students.find_one({"status": "ACTIVE", "level": 400, "department.code": "CSC"}, {"semesters": {"$slice": -1}})
    sid = doc["_id"]
    sem = doc["semesters"][-1]
    course = sem["courses"][0]["code"]
    print(f"  student {sid}, {sem['session']} {sem['term']}, course {course}: before = {sem['courses'][0]}")
    r = db.students.update_one(
        {"_id": sid},
        {"$set": {"semesters.$[s].courses.$[c].ca": 24.0, "semesters.$[s].courses.$[c].exam": 51.0,
                  "semesters.$[s].courses.$[c].total": 75.0, "semesters.$[s].courses.$[c].grade": "A",
                  "semesters.$[s].courses.$[c].gp": 5.0, "semesters.$[s].courses.$[c].result_status": "SUBMITTED"},
         "$currentDate": {"summary.last_updated": True}},
        array_filters=[{"s.session": sem["session"], "s.term": sem["term"]}, {"c.code": course}])
    after = db.students.find_one({"_id": sid}, {"semesters": {"$slice": -1}})["semesters"][0]["courses"][0]
    print(f"  matched={r.matched_count} modified={r.modified_count}; after = {after}")
    print("  All fields of the result change together or not at all (document-level atomicity).")

def n7_validation():
    banner("N7  $jsonSchema validation: exam score 85 (> 70) is rejected by the server")
    sid = db.students.find_one({"status": "ACTIVE"}, {"_id": 1})["_id"]
    try:
        db.students.update_one({"_id": sid}, {"$set": {"semesters.0.courses.0.exam": 85.0}})
        print("  accepted (unexpected)")
    except WriteError as e:
        print(f"  WriteError code {e.code}: {e.details.get('errmsg')}")
        rule = e.details.get("errInfo", {}).get("details", {}).get("schemaRulesNotSatisfied", [])
        print(f"  first rule not satisfied: {str(rule)[:160]}...")

def n8_key_value():
    banner("N8  Key-value access pattern: portal session tokens with TTL expiry")
    token = secrets.token_hex(16)
    now = datetime.now(timezone.utc)
    db.portal_sessions.insert_one({"_id": token, "matric": "AU/2022/00007", "role": "student",
                                   "created_at": now, "expires_at": now + timedelta(minutes=30)})
    db.portal_sessions.insert_one({"_id": "expired-demo", "matric": "AU/2023/00002", "role": "student",
                                   "created_at": now - timedelta(hours=2), "expires_at": now - timedelta(hours=1)})
    print(f"  GET session:{token[:8]}... -> {db.portal_sessions.find_one({'_id': token}, {'_id': 0, 'matric': 1, 'role': 1})}")
    idx = db.portal_sessions.index_information()
    print(f"  TTL index: {[ (k, v.get('expireAfterSeconds')) for k, v in idx.items() if 'expireAfterSeconds' in v]}")
    print("  The TTL monitor (runs every 60 s) deletes 'expired-demo' automatically - no cron job needed.")

def n9_bad_fit():
    banner("N9  Where the document model is weaker: pass rate per course (cross-document analytics)")
    pipeline = [
        {"$match": {"department.code": {"$in": ["CSC", "CYB", "SEN", "IFT"]}, "semesters.session": "2025/2026"}},
        {"$unwind": "$semesters"}, {"$match": {"semesters.session": "2025/2026"}},
        {"$unwind": "$semesters.courses"},
        {"$group": {"_id": "$semesters.courses.code", "candidates": {"$sum": 1},
                    "mean": {"$avg": "$semesters.courses.total"},
                    "passed": {"$sum": {"$cond": [{"$gte": ["$semesters.courses.total", 40]}, 1, 0]}}}},
        {"$project": {"candidates": 1, "mean": {"$round": ["$mean", 1]},
                      "pass_rate": {"$round": [{"$multiply": [{"$divide": ["$passed", "$candidates"]}, 100]}, 1]}}},
        {"$sort": {"pass_rate": 1, "_id": 1}},
    ]
    t = time.perf_counter()
    rows = list(db.students.aggregate(pipeline))
    ms = (time.perf_counter() - t) * 1000
    for r in rows[:5]:
        print(f"  {r['_id']}  candidates={r['candidates']:>4}  mean={r['mean']}  pass={r['pass_rate']}%")
    print(f"  ... {len(rows)} courses in {ms:.1f} ms. Every matching student document (~10 KB each) must be")
    print("  read and unwound twice; PostgreSQL answers the same question (Q05) from a covering index.")

if __name__ == "__main__":
    print(f"MongoDB {db.client.server_info()['version']} at {MONGO_URI}")
    print(f"students={db.students.estimated_document_count():,}  courses={db.courses.estimated_document_count():,}")
    for name in ("ix_status_dept_cgpa", "ux_email"):
        if name in db.students.index_information():
            db.students.drop_index(name)
    n1_transcript()
    n2_deans_list()
    n3_email_lookup()
    n4_graph()
    n5_flexible_schema()
    n6_post_result()
    n7_validation()
    n8_key_value()
    n9_bad_fit()
    db.portal_sessions.delete_many({})
