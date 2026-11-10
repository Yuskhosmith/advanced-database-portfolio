#!/usr/bin/env python3
"""EXPLAIN ANALYZE benchmark of the workload queries, before and after 01_optimisations.sql."""
import argparse
import json
import os
import statistics
import subprocess
from pathlib import Path

import psycopg

HERE = Path(__file__).resolve().parent
SQL = HERE / "sql"
QUERIES = SQL / "queries"
RESULTS = HERE / "results"

WORKLOAD = [
    ("Q01", "Student transcript (point lookup)", "q01_student_transcript.sql", None),
    ("Q02", "Course broadsheet", "q02_course_broadsheet.sql", None),
    ("Q03", "Top 3 per department (Dean's list)", "q03_top_students_per_department.sql",
     "q03_top_students_per_department_optimised.sql"),
    ("Q04", "Probation list (CSC)", "q04_probation_list.sql", None),
    ("Q05", "Pass rate per course 2025/2026", "q05_pass_rate_by_course.sql", None),
    ("Q06", "Lecturer workload (current semester)", "q06_lecturer_workload.sql", None),
    ("Q07", "Name prefix search", "q07_student_name_search.sql", None),
    ("Q08", "Pending results for a lecturer", "q08_pending_results_for_lecturer.sql", None),
    ("Q09a", "First-class list, row-by-row fn_cgpa()", "q09_first_class_rbar.sql", None),
    ("Q09b", "First-class list, set-based rewrite", "q09_first_class_setbased.sql", None),
    ("Q10", "2024 cohort registrations (correlated columns)", "q10_cohort_registrations.sql", None),
]

def strip_comments(sql: str) -> str:
    lines = [l for l in sql.splitlines() if not l.strip().startswith("--")]
    return "\n".join(lines).strip().rstrip(";")

def walk(plan, out):
    out.append(plan)
    for child in plan.get("Plans", []):
        walk(child, out)
    return out

def describe_access_paths(plan):
    """List the scan/join methods used, e.g. 'Index Only Scan using idx_x on enrollment'."""
    found = []
    for node in walk(plan, []):
        t = node["Node Type"]
        if "Scan" in t or "Join" in t or t in ("Nested Loop", "Hash", "Aggregate", "Sort", "WindowAgg", "Memoize"):
            if "Relation Name" in node:
                idx = f" using {node['Index Name']}" if "Index Name" in node else ""
                found.append(f"{t}{idx} on {node['Relation Name']}")
            elif "Join" in t or t == "Nested Loop":
                found.append(t)
    seen, uniq = set(), []
    for f in found:
        if f not in seen:
            seen.add(f)
            uniq.append(f)
    return uniq

def estimate_errors(plan):
    """Planner estimate vs actual rows for each base-table scan (per loop)."""
    rows = []
    for node in walk(plan, []):
        if "Relation Name" in node and "Actual Rows" in node:
            rows.append({
                "node": node["Node Type"],
                "relation": node["Relation Name"],
                "estimated": node["Plan Rows"],
                "actual": node["Actual Rows"],
                "loops": node["Actual Loops"],
            })
    return rows

def run_sql_file(conn, path):
    # VACUUM can't run inside a multi-statement string
    subprocess.run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", str(path)], check=True)

def measure(conn, sql, runs):
    with conn.cursor() as cur:
        explain = "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " + sql
        cur.execute(explain)  # warm-up
        exec_times, plan_times, last = [], [], None
        for _ in range(runs):
            cur.execute(explain)
            last = cur.fetchone()[0][0]
            exec_times.append(last["Execution Time"])
            plan_times.append(last["Planning Time"])
        cur.execute("EXPLAIN (ANALYZE, BUFFERS, SETTINGS) " + sql)
        text_plan = "\n".join(r[0] for r in cur.fetchall())
    root = last["Plan"]
    return {
        "median_exec_ms": round(statistics.median(exec_times), 3),
        "min_exec_ms": round(min(exec_times), 3),
        "max_exec_ms": round(max(exec_times), 3),
        "median_plan_ms": round(statistics.median(plan_times), 3),
        "rows_returned": root["Actual Rows"],
        "total_cost": root["Total Cost"],
        "shared_hit": root.get("Shared Hit Blocks", 0),
        "shared_read": root.get("Shared Read Blocks", 0),
        "access_paths": describe_access_paths(root),
        "estimates": estimate_errors(root),
        "text_plan": text_plan,
    }

def run_phase(conn, phase, runs):
    out = {}
    plan_dir = RESULTS / f"plans_{phase}"
    plan_dir.mkdir(parents=True, exist_ok=True)
    for qid, title, base_file, opt_file in WORKLOAD:
        fname = opt_file if (phase == "optimised" and opt_file) else base_file
        sql = strip_comments((QUERIES / fname).read_text())
        print(f"  {phase:9s} {qid:5s} {title} ...", flush=True)
        m = measure(conn, sql, runs)
        m.update({"title": title, "file": fname})
        (plan_dir / f"{qid}.txt").write_text(
            f"-- {qid} {title}\n-- file: sql/queries/{fname}\n-- phase: {phase}\n\n{sql};\n\n"
            f"-- EXPLAIN (ANALYZE, BUFFERS, SETTINGS)\n{m['text_plan']}\n")
        out[qid] = m
    return out

def index_report(conn):
    with conn.cursor() as cur:
        cur.execute("""
            SELECT relname AS table_name, indexrelname AS index_name,
                   pg_size_pretty(pg_relation_size(indexrelid)) AS size, idx_scan
            FROM pg_stat_user_indexes
            WHERE indexrelname IN ('idx_enrollment_offering_cover','idx_enrollment_pending',
                   'idx_offering_semester','idx_offering_lecturer','idx_student_programme',
                   'idx_student_lower_name','ux_mv_student_cgpa','idx_mv_cgpa_dept',
                   'enrollment_pkey','enrollment_student_id_offering_id_key')
            ORDER BY pg_relation_size(indexrelid) DESC""")
        return cur.fetchall()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=5)
    args = ap.parse_args()
    RESULTS.mkdir(exist_ok=True)
    dsn = f"dbname={os.environ.get('PGDATABASE', 'university_portal')} host={os.environ.get('PGHOST', 'localhost')} port={os.environ.get('PGPORT', '5432')}"

    with psycopg.connect(dsn, autocommit=True) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT version()")
            version = cur.fetchone()[0]
            cur.execute("SHOW shared_buffers")
            sb = cur.fetchone()[0]
            cur.execute("SHOW jit")
            jit = cur.fetchone()[0]
        print("Resetting to baseline physical design")
        run_sql_file(conn, SQL / "00_reset_optimisations.sql")
        baseline = run_phase(conn, "baseline", args.runs)
        print("Applying optimisations")
        run_sql_file(conn, SQL / "01_optimisations.sql")
        optimised = run_phase(conn, "optimised", args.runs)
        indexes = index_report(conn)

    strip = lambda d: {k: {kk: vv for kk, vv in v.items() if kk != "text_plan"} for k, v in d.items()}
    (RESULTS / "benchmark_results.json").write_text(json.dumps(
        {"server": version, "shared_buffers": sb, "jit": jit, "runs": args.runs,
         "baseline": strip(baseline), "optimised": strip(optimised)}, indent=2))

    md = [f"# Benchmark summary\n",
          f"- Server: `{version}`",
          f"- shared_buffers = {sb}, jit = {jit}; warm cache; median of {args.runs} runs after 1 warm-up\n",
          "| Query | Description | Baseline (ms) | Optimised (ms) | Speed-up | Buffers before → after |",
          "|---|---|---:|---:|---:|---|"]
    for qid, title, *_ in WORKLOAD:
        b, o = baseline[qid], optimised[qid]
        sp = b["median_exec_ms"] / o["median_exec_ms"] if o["median_exec_ms"] else float("inf")
        md.append(f"| {qid} | {title} | {b['median_exec_ms']:.2f} | {o['median_exec_ms']:.2f} | "
                  f"{sp:,.1f}× | {b['shared_hit'] + b['shared_read']:,} → {o['shared_hit'] + o['shared_read']:,} |")
    md.append("\n## Access paths chosen by the planner\n")
    for qid, title, *_ in WORKLOAD:
        md.append(f"**{qid} – {title}**\n")
        md.append(f"- before: {'; '.join(baseline[qid]['access_paths'])}")
        md.append(f"- after:  {'; '.join(optimised[qid]['access_paths'])}\n")
    md.append("## Planner row estimates for `student` scans (Q10, correlated columns)\n")
    md.append("| Phase | Node | Estimated rows | Actual rows |\n|---|---|---:|---:|")
    for phase, data in (("baseline", baseline), ("optimised", optimised)):
        for e in data["Q10"]["estimates"]:
            if e["relation"] == "student":
                md.append(f"| {phase} | {e['node']} | {e['estimated']:,} | {e['actual']:,} |")
    md.append("\n## Index sizes and usage after the benchmark\n")
    md.append("| Table | Index | Size | Index scans |\n|---|---|---:|---:|")
    for t, i, s, n in indexes:
        md.append(f"| {t} | {i} | {s} | {n:,} |")
    (RESULTS / "benchmark_summary.md").write_text("\n".join(md) + "\n")
    print("\n".join(md))

if __name__ == "__main__":
    main()
