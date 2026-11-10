# Portfolio 2 – Query Processing and Optimisation

**Case study:** AUSRP (613,360 enrollments, 20,000 students). **DBMS:** PostgreSQL 18.3 on Apple Silicon, `shared_buffers = 128MB`.

## 1. Method

1. I wrote a **workload of 11 queries** that the portal actually runs ([sql/queries/](sql/queries/)), one file per query.
2. **Baseline:** the database as built in Portfolio 1, which has PK/UNIQUE indexes and FK indexes on small tables only ([sql/00_reset_optimisations.sql](sql/00_reset_optimisations.sql) restores this state).
3. [benchmark.py](benchmark.py) runs every query with `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`: 1 warm-up and then **5 measured runs, keeping the median**. It records execution time, buffers touched, access paths, and planner estimates against actual row counts.
4. I applied the **optimisations** in [sql/01_optimisations.sql](sql/01_optimisations.sql). Each one is motivated by a specific query. Then I ran `VACUUM ANALYZE` and measured again.
5. Full text plans for both phases are kept as evidence: [results/plans_baseline/](results/plans_baseline/) and [results/plans_optimised/](results/plans_optimised/). Query output is in [results/query_results.txt](results/query_results.txt).

```bash
./portfolio-2-query-optimisation/run.sh      # ~20 s; regenerates everything in results/
```

All timings are warm-cache timings on one laptop, so absolute values will differ on other hardware. **Buffers touched** (8 KB pages) is the hardware-independent measure of work, so I report it as well.

## 2. Workload

| ID | Query (business purpose) | SQL features |
|---|---|---|
| Q01 | Student transcript by matric number | 7-way join, range join on `grade_scale` |
| Q02 | Course broadsheet (CSC301, 2025/2026) | join by offering |
| Q03 | Dean's list: top 3 per department by CGPA | CTE, aggregation, `dense_rank()` window |
| Q04 | Probation list: CSC students with CGPA < 1.50 | `GROUP BY … HAVING` |
| Q05 | Senate report: pass rate per Computing course | `FILTER` aggregate |
| Q06 | Lecturer workload in the current semester | `LEFT JOIN`, `count(DISTINCT)`, `LIMIT` |
| Q07 | Case-insensitive surname prefix search | `lower() LIKE 'okon%'` |
| Q08 | Grade-entry screen: pending results for one lecturer | sub-query, selective predicate |
| Q09a | First-class list using `fn_cgpa()` per row | scalar UDF in `WHERE` (row-by-row) |
| Q09b | Same result, set-based rewrite | join + `GROUP BY … HAVING` |
| Q10 | Registrations of the 2024 cohort in 300 level | correlated predicates |

## 3. Optimisations applied

| # | Change | Target | Rationale |
|---|---|---|---|
| 1 | `idx_enrollment_offering_cover ON enrollment(offering_id) INCLUDE (status, total_score)` | Q02 Q05 Q06 | `offering_id` is only the **second** column of `UNIQUE(student_id, offering_id)`. `INCLUDE` makes the index **covering**, so Q05 can run as an index-only scan. |
| 2 | Partial index `idx_enrollment_pending ON enrollment(offering_id) WHERE result_status='PENDING'` | Q08 | Only 53k of 613k rows are pending, so the index is just **392 kB**. It shrinks as results are approved. |
| 3 | `idx_offering_semester`, `idx_offering_lecturer`, `idx_student_programme` | Q04–Q09 | FK columns used as join and filter keys. PostgreSQL does not index FKs automatically. |
| 4 | Expression index `ON student(lower(last_name) text_pattern_ops, lower(first_name) text_pattern_ops)` | Q07 | Makes `lower(col) LIKE 'abc%'` sargable. `text_pattern_ops` is needed for `LIKE` prefix matching under a non-C collation. |
| 5 | `CREATE STATISTICS st_student_cohort (dependencies, ndistinct) ON entry_year, current_level` | Q10 | The planner assumes columns are independent, but entry year determines level. |
| 6 | Materialized view `mv_student_cgpa` + unique index, refreshed `CONCURRENTLY` | Q03 | CGPA changes only when Senate approves a semester, which is a few times a year. Computing it on every page view is wasteful. |
| 7 | Rewrite Q09a → Q09b | Q09 | Replace a per-row function call with one set-based aggregation. |

## 4. Results

Source: [results/benchmark_summary.md](results/benchmark_summary.md) and [results/benchmark_results.json](results/benchmark_results.json).

| Query | Baseline (ms) | Optimised (ms) | Speed-up | Buffers before → after | Plan change |
|---|---:|---:|---:|---|---|
| Q01 transcript | 0.18 | 0.17 | 1.0× | 298 → 298 | none needed (see 5.1) |
| Q02 broadsheet | 8.30 | 0.67 | **12.4×** | 3,960 → 1,179 | skip scan → dedicated index |
| Q03 dean's list | 249.00 | 5.99 | **41.6×** | 8,666 → 192 | 613k-row aggregate → scan of a 20k-row MV |
| Q04 probation | 43.94 | 43.71 | 1.0× | 131,002 → 131,004 | none (see 5.5) |
| Q05 pass rate | 31.40 | 15.84 | **2.0×** | 7,686 → 854 | parallel seq scan → index-only scan, 0 heap fetches |
| Q06 workload | 89.24 | 27.60 | **3.2×** | 7,522 → 46,582 | hash join → nested loop + index |
| Q07 name search | 2.28 | 0.02 | **119.8×** | 349 → 20 | seq scan → bitmap index scan |
| Q08 pending results | 17.17 | 0.47 | **36.8×** | 8,486 → 1,090 | seq scan of 613k rows → partial index |
| Q09a row-by-row | 1,356.51 | 127.63 | 10.6× | 3,518,612 → 338,776 | UDF evaluated 20,000 → 1,728 times |
| Q09b set-based | 97.17 | 94.99 | 1.0× | 295,376 → 295,378 | — |
| Q10 cohort | 19.20 | 19.84 | 1.0× | 8,708 → 8,708 | estimate 555 → 3,333 rows (exact) |

## 5. Analysis of the execution plans

### 5.1 Q01: the "leftmost prefix" rule already helps
The transcript filters on `student.matric_no` (unique index), then reaches `enrollment` by `student_id`. `student_id` is the **leading column** of the composite `UNIQUE(student_id, offering_id)` index, so this lookup was already indexed: a bitmap index scan touches 48 rows. No new index was needed. This shows that a unique constraint is also an access path.

### 5.2 Q02: PostgreSQL 18 skip scan, and why a dedicated index still wins
The baseline plan does **not** do a sequential scan. It uses the composite unique index even though `offering_id` is its *second* column:
```
Index Scan using enrollment_student_id_offering_id_key on enrollment e  (actual time=0.006..7.292 rows=292)
  Index Cond: (offering_id = o.offering_id)
  Index Searches: 12
  Buffers: shared hit=3073
```
This is the **B-tree skip scan** introduced in PostgreSQL 18: it repeatedly re-descends the tree for each range of the leading column (`Index Searches: 12`). It works, but it reads 3,073 pages to find 292 rows. With a dedicated index the plan becomes `Index Searches: 1, shared hit=292`. That is **10× less I/O and 12× faster**. Skip scan is a useful fallback but does not replace an index that matches the predicate.

### 5.3 Q05: covering index → index-only scan
Before: `Parallel Seq Scan on enrollment` (3 workers, 560k rows read, 7,686 buffers).
After:
```
Index Only Scan using idx_enrollment_offering_cover on enrollment e  (rows=274.56 loops=192)
  Filter: ((status)::text = 'COMPLETED'::text)
  Heap Fetches: 0
```
Because `status` and `total_score` are `INCLUDE`d in the index and `VACUUM` has set the visibility map, the table heap is **never read** (`Heap Fetches: 0`). Buffers drop 9× (7,686 → 854). Execution time only halves because the baseline was already parallelised.

### 5.4 Q06: more buffers but faster
Buffers *increase* (7.5k → 46.6k) while time falls 3.2×. The new plan is a nested loop that probes small indexes many times. Each probe hits a page that is already cached, which is cheap. The old plan hashed the entire 93 MB enrollment table. "Buffers touched" counts hits and reads equally, so this is a reminder that no single metric tells the whole story.

### 5.5 Q04 / Q09b: when an index does **not** help
Both queries already use `enrollment(student_id, …)` through nested loops: about 1,700 CSC students × 36 enrollments each. The new `idx_student_programme` only replaces a 20k-row seq scan of `student`, which is cheap anyway. The real cost is about 60,000 index probes on enrollment, plus joins to offering/course/grade_scale (131k buffers). The rational fix is the **materialized view** (Q03 drops from 249 ms to 6 ms). I deliberately did not add more indexes here, because each index slows every grade-entry `UPDATE` and costs space (the covering index alone is 24 MB).

### 5.6 Q09a vs Q09b: row-by-row processing and predicate ordering
The baseline plan for Q09a shows the cost hidden inside the UDF:
```
Seq Scan on student s  (actual time=0.259..1330.489 rows=2291)
  Filter: (fn_cgpa(student_id) >= 4.5)
  Rows Removed by Filter: 17709
  Buffers: shared hit=3,475,733
```
The planner pushed the expensive filter down to the `student` scan **before** the cheap join that restricts to CSC. So `fn_cgpa()` ran for all **20,000** students, and each call executes its own 4-table join. After `idx_student_programme` exists, the plan first finds CSC students via the index (bitmap heap scan), so the function runs only for **1,728** students (10.6× faster). The set-based rewrite (Q09b) is **14× faster than the original** with no new indexes at all. Lessons:
* Avoid scalar UDFs that run queries inside `WHERE`.
* The planner cannot see the cost of a function body. Its default `COST 100` is wrong here, and `ALTER FUNCTION fn_cgpa COST 10000` would have nudged the planner to filter by department first.

### 5.7 Q10: extended statistics fix the cardinality estimate
`entry_year = 2024 AND current_level = 300` matches 3,333 students. Assuming independence, the planner estimated
`20,000 × 1/6 × 1/4 ≈ 555` rows (a 6× underestimate). After `CREATE STATISTICS … (dependencies)` the estimate becomes **3,333, which is exact**. In this query the join strategy (hash join) was already right, so the time did not change. That is an honest result: better estimates matter when they change the plan, for example by avoiding a nested loop chosen because of a "small" outer side. In this case the estimate was corrected but the plan stayed the same.

### 5.8 Cost of the optimisations
| Index / object | Size |
|---|---:|
| idx_enrollment_offering_cover | 24 MB |
| idx_enrollment_pending (partial) | 392 kB |
| mv_student_cgpa + 2 indexes | ~2 MB |
| other new indexes | < 0.5 MB |

Indexes slow down writes: each `INSERT` into enrollment now maintains 4 indexes instead of 2. Registration is a short peak (about 20,000 students × 6 courses per semester), so this is acceptable. The materialized view introduces **staleness**: a CGPA is out of date between result approval and `REFRESH MATERIALIZED VIEW CONCURRENTLY mv_student_cgpa`. That refresh is part of the Senate approval procedure, so in practice the view is never stale while results are visible to students.

## 6. Summary
* The largest gains came from **matching indexes to the predicates the workload actually uses** (Q02, Q07, Q08), from **pre-aggregation** (Q03), and from **rewriting row-by-row logic as set-based SQL** (Q09).
* Reading `EXPLAIN (ANALYZE, BUFFERS)` showed problems that timings alone hide: the PG18 skip scan, the UDF evaluation order, and a 6× cardinality misestimate.
* Not every slow query needs an index. Q04 is bounded by join volume, and the right tool there is pre-aggregation, not more indexes.
