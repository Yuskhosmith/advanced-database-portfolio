# Portfolio 3 – Transactions and Concurrency

**Case study:** AUSRP. Two operations need strong transactional guarantees: **result entry** (scores are legal records) and **course registration** (thousands of students compete for limited seats in the first hours after registration opens).
**DBMS:** PostgreSQL 18.3 (MVCC, default isolation `READ COMMITTED`).

```bash
./portfolio-3-transactions-concurrency/run.sh   # Part A (psql) + Part B (Python, multiple sessions), ~10 s
```

| Part | How | Evidence |
|---|---|---|
| A – transaction control in one session | [sql/01_commit_rollback_savepoint.sql](sql/01_commit_rollback_savepoint.sql) run with `psql` | [results/partA_commit_rollback_savepoint.txt](results/partA_commit_rollback_savepoint.txt) |
| B – concurrency anomalies and controls | [scripts/concurrency_demo.py](scripts/concurrency_demo.py) drives 2–40 **real, separate database sessions**. Steps are interleaved deterministically, so every anomaly reproduces on every run. | [results/partB_concurrency_output.txt](results/partB_concurrency_output.txt) |
| Fix found during testing | [sql/02_fix_register_course_v2.sql](sql/02_fix_register_course_v2.sql) | scenario C3 |

---

## Part A – COMMIT, ROLLBACK, SAVEPOINT (atomicity and durability)

Scenario: the CSC401 lecturer uploads scores for five students.

| Step | What happened | Result |
|---|---|---|
| **A1 COMMIT** | `BEGIN`, then update 3 scores, then `COMMIT` (txid 108936) | All 3 rows show `xmin = 108936`. The **audit trigger** wrote 3 `grade_audit` rows **in the same transaction**, with reason `'A1 initial upload'` (passed via `SET LOCAL app.change_reason`). |
| **A2 ROLLBACK on error** | Row 4 is updated (total 70), then row 5 gets `exam_score = 75` | `ERROR: violates check constraint "enrollment_exam_score_check"`. Any further statement fails with `current transaction is aborted`. After `ROLLBACK`, row 4 is NULL again: **nothing from A2 survived**. |
| **A3 SAVEPOINT** | `SAVEPOINT row4`, valid update, `RELEASE`. Then `SAVEPOINT row5`, invalid update, `ROLLBACK TO SAVEPOINT row5`, `COMMIT` | Row 4 is kept (70.0) and row 5 is untouched. The transaction stayed usable after the partial rollback. |
| **A4 Business transaction** | "Swap course" = `fn_drop_course(CSC404)` + `fn_register_course(MTH101)`, where MTH101 is full | Inside the transaction CSC404 shows `DROPPED`. Registration fails (`Course MTH101 is full (261 / 261)`). After `ROLLBACK`, CSC404 is `REGISTERED` again with an unchanged seat count. The student never loses a seat they had. |
| **A5 Durability** | `pg_current_wal_lsn()`, `synchronous_commit = on`, `fsync = on` | A commit returns only after its WAL record is flushed to disk. Portfolio 5 extends this to a replica. |

---

## Part B – concurrency anomalies and control mechanisms

### C1 Lost update (the anomaly)
The naive application logic: *read `seats_taken` → check `< capacity` → insert enrollment → write `seats_taken = value_read + 1`*. CSC190 has capacity 2 and 1 seat taken.

```
[0.035s] T1   SELECT seats_taken -> 1/2: seat available
[0.036s] T2   SELECT seats_taken -> 1/2: seat available
[0.037s] T1   INSERT enrollment; UPDATE seats_taken = 2
[0.037s] T1   COMMIT
[0.038s] T2   INSERT enrollment; UPDATE seats_taken = 2  (overwrites T1)
[0.039s] T2   COMMIT
[0.039s] RES  CSC190: enrolled rows = 3, seats_taken counter = 2, capacity = 2  <-- OVERBOOKED / COUNTER WRONG
```
`READ COMMITTED` allows this because each statement sees the latest committed data, but nothing protects the gap between the read and the write. The `CHECK (seats_taken <= capacity)` constraint does not catch it either, because the counter itself is wrong (2) while 3 students hold seats.

### C2 Three ways to fix it

| Fix | Mechanism | Observed behaviour |
|---|---|---|
| **C2a pessimistic locking** | `SELECT … FOR UPDATE` on the offering row | T2 blocks. The observer session shows `p3-T2 is WAITING (Lock:transactionid) blocked by p3-T1` (from `pg_stat_activity` + `pg_blocking_pids()`). After T1 commits, T2 reads **2/2** and rejects the registration. |
| **C2b optimistic, REPEATABLE READ** | snapshot isolation, *first-updater-wins* | T2's `UPDATE` fails with `ERROR 40001: could not serialize access due to concurrent update`. The application retries the whole transaction, sees 2/2, and refuses. The application must implement retry. |
| **C2c atomic conditional update** | `UPDATE … SET seats_taken = seats_taken + 1 WHERE … AND seats_taken < capacity RETURNING …` | T2 waits for T1's row lock, then PostgreSQL **re-evaluates the WHERE clause on the new row version** (EvalPlanQual) and returns 0 rows, which means the course is full. There is no read-then-write gap. |

All three end in the consistent state `enrolled rows = 2, seats_taken = 2, capacity = 2`.

### C3 Write skew: a bug in my own registration function, and its fix
`fn_register_course` (Portfolio 1) locks the **offering** row and checks capacity, prerequisites and the **24-credit-unit limit per semester**. While designing these tests I realised the credit-limit rule spans **several rows** (all of the student's enrollments). Two registrations by the *same* student for *different* courses lock *different* offering rows, so they do not block each other. The student is at 20 units and submits two 4-unit courses from two browser tabs:

```
--- C3a  v1 under READ COMMITTED
[1.215s] T1   OK (not committed yet)
[1.722s] OBS  no session is waiting on a lock
[1.723s] T1   COMMIT ok
[1.723s] T2   fn_register_course OK
[1.724s] T2   COMMIT ok
[1.725s] RES  student 11 now has 28 units   <-- RULE VIOLATED (limit 24)

--- C3b  v1 under SERIALIZABLE
[2.292s] T1   COMMIT ok
[2.294s] T2   COMMIT failed 40001: could not serialize access due to read/write dependencies among transactions
[2.294s] T2      detail: Reason code: Canceled on identification as a pivot, during commit attempt.
[2.296s] RES  student 11 now has 24 units   (rule respected)

--- C3c  v2 under READ COMMITTED  (student row locked first)
[2.866s] OBS  p3-T2 is WAITING (Lock:transactionid) blocked by p3-T1 :: SELECT fn_register_course($1, $2)
[2.867s] T1   COMMIT ok
[2.879s] T2   ERROR AU003: Credit limit exceeded: 24 + 4 > 24
[2.882s] RES  student 11 now has 24 units   (rule respected)
```

* **C3a** is classic *write skew*: each transaction reads an overlapping set (the student's enrollments) and writes a disjoint row. Neither row lock nor snapshot isolation (`REPEATABLE READ`) prevents it.
* **C3b**: PostgreSQL's **Serializable Snapshot Isolation** tracks read/write dependencies (SIREAD predicate locks). It aborts the "pivot" transaction at commit, so the result is equivalent to some serial order. The cost is that clients must retry on `40001`.
* **C3c**, the fix I adopted ([v2](sql/02_fix_register_course_v2.sql)): the function first takes `SELECT … FROM student WHERE student_id = ? FOR NO KEY UPDATE`. This serialises all registrations *of one student* while registrations of different students still run in parallel. `NO KEY UPDATE` (rather than `UPDATE`) does not block ordinary FK checks on `student`. The lock order is always **student → offering**, so the new lock cannot cause deadlocks between registrations.

I chose explicit locking over running the whole portal at `SERIALIZABLE`. It is targeted, needs no retry loop in the client, and the protected invariant is documented in the code.

### C4 Isolation levels: dirty, non-repeatable and phantom reads
Reader A reads a CA score and a count of students in CSC190. Writer B updates the score and inserts a new student, then commits.

| A's isolation | Read during B's uncommitted change | Score after B commits | Count after B commits |
|---|---|---|---|
| READ COMMITTED | 10.0 (no dirty read) | **27.0, non-repeatable read** | **6, phantom row appeared** |
| REPEATABLE READ | 10.0 (no dirty read) | 10.0, repeatable | 5, no phantom |

PostgreSQL never allows dirty reads, even when `READ UNCOMMITTED` is requested. Its `REPEATABLE READ` is snapshot isolation, so it also prevents phantoms, which is stronger than the SQL standard requires.

### C5 Deadlock detection and prevention
Two grade-correction jobs update the same two results in opposite orders:
```
[3.028s] T1   UPDATE result 613391
[3.086s] T2   UPDATE result 613392
[4.407s] T1   ERROR 40P01 deadlock_detected -> this transaction was chosen as the victim
[4.407s] T1      Process 68419 waits for ShareLock on transaction 109018; blocked by process 68420.
[4.408s] T2   UPDATE result 613391
[4.712s] T2   COMMIT
```
The detector runs after `deadlock_timeout = 1s`, finds the wait-for cycle, and aborts one transaction. **Prevention:** each job first locks its rows with `SELECT … ORDER BY enrollment_id FOR UPDATE`. With the same global lock order, T2 simply waits and both jobs commit (second run in the output).

### C6 MVCC: readers do not block writers
While W's update is uncommitted, R's `SELECT` returns in 2.5 ms **without waiting**. It sees the old row version (`xmin=109023 xmax=109024 ctid=(7463,118)`), where `xmax` is W's transaction ID marking the version as being replaced. W sees its own new version at `ctid=(7463,119)`. After the commit, R sees the new tuple. Old versions are later removed by `VACUUM`.

### C7 Stress test: 40 concurrent registrations for 25 seats
40 threads with 40 connections are released together by a barrier:

| Strategy | Accepted | Refused | Enrollment rows | Counter | Capacity | Verdict |
|---|---:|---:|---:|---:|---:|---|
| naive read-check-write (READ COMMITTED) | 40 | 0 | **40** | **1** | 25 | **overbooked by 15, counter wrong** |
| `fn_register_course` v2 (FOR UPDATE) | 25 | 15 | 25 | 25 | 25 | correct |
| atomic conditional UPDATE | 25 | 15 | 25 | 25 | 25 | correct |

(Times are 54–78 ms for the whole burst. Locking costs very little at this scale.)

## Summary of mechanisms

| Problem | Mechanism used | Trade-off |
|---|---|---|
| Partial batch writes | transactions, `ROLLBACK`, `SAVEPOINT` | none (essential) |
| Lost update | `FOR UPDATE`, conditional `UPDATE`, or `REPEATABLE READ` + retry | blocking vs retries |
| Write skew over many rows | lock a common parent row, or `SERIALIZABLE` | targeted locking vs global retries |
| Non-repeatable / phantom reads in reports | `REPEATABLE READ` for multi-statement reports (e.g. a transcript PDF) | snapshot held open longer |
| Deadlocks | consistent lock ordering. The detector is the safety net | none |
| Reader/writer contention | MVCC (built in) | dead tuples need `VACUUM` |
