#!/usr/bin/env python3
"""Concurrency experiments C1-C7 using several real sessions."""
import os
import random
import threading
import time
from pathlib import Path

import psycopg
from psycopg import errors

DSN = (f"dbname={os.environ.get('PGDATABASE', 'university_portal')} "
       f"host={os.environ.get('PGHOST', 'localhost')} port={os.environ.get('PGPORT', '5432')}")
HERE = Path(__file__).resolve().parent
T0 = time.perf_counter()
PRINT_LOCK = threading.Lock()

def log(who, msg):
    with PRINT_LOCK:
        print(f"[{time.perf_counter() - T0:7.3f}s] {who:<4} {msg}", flush=True)

def banner(title):
    print("\n" + "=" * 92 + f"\n{title}\n" + "=" * 92, flush=True)

def session(name):
    """A separate database connection = a separate transaction context."""
    return psycopg.connect(DSN, autocommit=True, application_name=f"p3-{name}")

def q(conn, sql, params=None):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall() if cur.description else None

def one(conn, sql, params=None):
    rows = q(conn, sql, params)
    return rows[0] if rows else None

class Background:
    """Run a blocking step in a thread so the main thread can observe the lock wait."""

    def __init__(self, fn):
        self.result, self.error = None, None
        self.t = threading.Thread(target=self._run, args=(fn,))
        self.t.start()

    def _run(self, fn):
        try:
            self.result = fn()
        except Exception as e:
            self.error = e

    def join(self):
        self.t.join()
        return self

def show_waits(admin, label="OBS"):
    rows = q(admin, """
        SELECT a.application_name, a.state, a.wait_event_type, a.wait_event,
               (SELECT string_agg(b.application_name, ',') FROM pg_stat_activity b
                 WHERE b.pid = ANY (pg_blocking_pids(a.pid))) AS blocked_by,
               left(regexp_replace(a.query, '\\s+', ' ', 'g'), 70) AS query
        FROM pg_stat_activity a
        WHERE a.application_name LIKE 'p3-T%' AND a.wait_event_type = 'Lock'""")
    if not rows:
        log(label, "no session is waiting on a lock")
    for r in rows:
        log(label, f"{r[0]} is WAITING ({r[2]}:{r[3]}) blocked by {r[4]} :: {r[5]}")
class Fixture:
    def __init__(self, admin):
        self.admin = admin
        self.sem = one(admin, "SELECT semester_id FROM semester WHERE registration_open")[0]
        q(admin, """INSERT INTO course (course_code, title, department_id, credit_units, level, term)
                    SELECT 'CSC190', 'Concurrency Lab Elective', department_id, 2, 100, 'FIRST'
                    FROM department WHERE code = 'CSC'
                    ON CONFLICT (course_code) DO NOTHING""")
        q(admin, """INSERT INTO course_offering (course_id, semester_id, lecturer_id, capacity)
                    SELECT c.course_id, %s, (SELECT min(lecturer_id) FROM lecturer WHERE department_id = c.department_id), 25
                    FROM course c WHERE course_code = 'CSC190'
                    ON CONFLICT (course_id, semester_id) DO NOTHING""", (self.sem,))
        self.offering = one(admin, """SELECT offering_id FROM course_offering o JOIN course c USING (course_id)
                                      WHERE c.course_code = 'CSC190' AND o.semester_id = %s""", (self.sem,))[0]
        self.students = [r[0] for r in q(admin, """SELECT student_id FROM student
                          WHERE current_level = 100 AND status = 'ACTIVE' ORDER BY student_id LIMIT 60""")]

    def reset_elective(self, capacity, preregistered=0):
        q(self.admin, "DELETE FROM enrollment WHERE offering_id = %s", (self.offering,))
        q(self.admin, "UPDATE course_offering SET seats_taken = 0, capacity = %s WHERE offering_id = %s",
          (capacity, self.offering))
        for s in self.students[:preregistered]:
            q(self.admin, "SELECT fn_register_course(%s, %s)", (s, self.offering))

    def elective_state(self):
        return one(self.admin, """SELECT (SELECT count(*) FROM enrollment WHERE offering_id = o.offering_id
                                          AND status <> 'DROPPED') AS enrolled,
                                         seats_taken, capacity
                                  FROM course_offering o WHERE offering_id = %s""", (self.offering,))

    def offering_of(self, code):
        return one(self.admin, """SELECT o.offering_id FROM course_offering o JOIN course c USING (course_id)
                                  WHERE c.course_code = %s AND o.semester_id = %s""", (code, self.sem))[0]

def report_elective(fx, who="RES"):
    enrolled, seats, cap = fx.elective_state()
    flag = "  <-- OVERBOOKED / COUNTER WRONG" if (enrolled > cap or enrolled != seats) else "  (consistent)"
    log(who, f"CSC190: enrolled rows = {enrolled}, seats_taken counter = {seats}, capacity = {cap}{flag}")
def naive_read(conn, offering):
    return one(conn, "SELECT seats_taken, capacity FROM course_offering WHERE offering_id = %s", (offering,))

def naive_write(conn, student, offering, seats_read):
    q(conn, "INSERT INTO enrollment (student_id, offering_id) VALUES (%s, %s)", (student, offering))
    q(conn, "UPDATE course_offering SET seats_taken = %s WHERE offering_id = %s", (seats_read + 1, offering))

def c1_lost_update(fx):
    banner("C1  LOST UPDATE - naive read-check-write registration under READ COMMITTED\n"
           "    CSC190 has capacity 2 and 1 seat already taken; two students click 'Register' together.")
    fx.reset_elective(capacity=2, preregistered=1)
    report_elective(fx, "PRE")
    s1, s2 = fx.students[10], fx.students[11]
    t1, t2 = session("T1"), session("T2")
    q(t1, "BEGIN ISOLATION LEVEL READ COMMITTED"); log("T1", "BEGIN (READ COMMITTED)")
    q(t2, "BEGIN ISOLATION LEVEL READ COMMITTED"); log("T2", "BEGIN (READ COMMITTED)")
    seats1, cap = naive_read(t1, fx.offering); log("T1", f"SELECT seats_taken -> {seats1}/{cap}: seat available")
    seats2, cap = naive_read(t2, fx.offering); log("T2", f"SELECT seats_taken -> {seats2}/{cap}: seat available")
    naive_write(t1, s1, fx.offering, seats1); log("T1", f"INSERT enrollment; UPDATE seats_taken = {seats1 + 1}")
    q(t1, "COMMIT"); log("T1", "COMMIT")
    naive_write(t2, s2, fx.offering, seats2); log("T2", f"INSERT enrollment; UPDATE seats_taken = {seats2 + 1}  (overwrites T1)")
    q(t2, "COMMIT"); log("T2", "COMMIT")
    report_elective(fx)
    log("NOTE", "T1's increment was lost: 3 students hold 2 seats. The CHECK (seats_taken <= capacity)")
    log("NOTE", "constraint could not catch it because the counter itself is wrong.")
    t1.close(); t2.close()
def c2a_for_update(fx, admin):
    banner("C2a FIX 1 - PESSIMISTIC LOCKING with SELECT ... FOR UPDATE")
    fx.reset_elective(capacity=2, preregistered=1)
    s1, s2 = fx.students[10], fx.students[11]
    t1, t2 = session("T1"), session("T2")
    q(t1, "BEGIN"); log("T1", "BEGIN")
    q(t2, "BEGIN"); log("T2", "BEGIN")
    seats1, cap = one(t1, "SELECT seats_taken, capacity FROM course_offering WHERE offering_id=%s FOR UPDATE", (fx.offering,))
    log("T1", f"SELECT ... FOR UPDATE -> {seats1}/{cap}  (row lock acquired)")

    def t2_work():
        seats, c = one(t2, "SELECT seats_taken, capacity FROM course_offering WHERE offering_id=%s FOR UPDATE", (fx.offering,))
        log("T2", f"SELECT ... FOR UPDATE returned (after waiting) -> {seats}/{c}")
        if seats >= c:
            q(t2, "ROLLBACK"); log("T2", "course full -> ROLLBACK, student told 'no seats left'")
            return "rejected"
        naive_write(t2, s2, fx.offering, seats); q(t2, "COMMIT")
        return "registered"

    log("T2", "SELECT ... FOR UPDATE  (must wait for T1's lock)")
    bg = Background(t2_work)
    time.sleep(0.5)
    show_waits(admin)
    naive_write(t1, s1, fx.offering, seats1); log("T1", f"INSERT enrollment; UPDATE seats_taken = {seats1 + 1}")
    q(t1, "COMMIT"); log("T1", "COMMIT (lock released)")
    bg.join()
    report_elective(fx)
    t1.close(); t2.close()

def c2b_repeatable_read(fx):
    banner("C2b FIX 2 - OPTIMISTIC: REPEATABLE READ detects the conflicting update, client retries")
    fx.reset_elective(capacity=2, preregistered=1)
    s1, s2 = fx.students[10], fx.students[11]
    t1, t2 = session("T1"), session("T2")
    q(t1, "BEGIN ISOLATION LEVEL REPEATABLE READ"); log("T1", "BEGIN (REPEATABLE READ)")
    q(t2, "BEGIN ISOLATION LEVEL REPEATABLE READ"); log("T2", "BEGIN (REPEATABLE READ)")
    seats1, cap = naive_read(t1, fx.offering); log("T1", f"SELECT -> {seats1}/{cap}")
    seats2, _ = naive_read(t2, fx.offering);   log("T2", f"SELECT -> {seats2}/{cap}")
    naive_write(t1, s1, fx.offering, seats1); q(t1, "COMMIT"); log("T1", "INSERT + UPDATE seats; COMMIT")
    try:
        naive_write(t2, s2, fx.offering, seats2)
        q(t2, "COMMIT"); log("T2", "COMMIT (unexpected)")
    except errors.SerializationFailure as e:
        log("T2", f"ERROR {e.sqlstate}: {e.diag.message_primary}")
        q(t2, "ROLLBACK"); log("T2", "ROLLBACK -> application retries the whole transaction")
        q(t2, "BEGIN ISOLATION LEVEL REPEATABLE READ")
        seats2, cap = naive_read(t2, fx.offering)
        log("T2", f"retry: SELECT -> {seats2}/{cap} -> course full, registration refused")
        q(t2, "ROLLBACK")
    report_elective(fx)
    t1.close(); t2.close()

def c2c_atomic_update(fx, admin):
    banner("C2c FIX 3 - ATOMIC CONDITIONAL UPDATE (no gap between check and write)\n"
           "    UPDATE course_offering SET seats_taken = seats_taken + 1\n"
           "    WHERE offering_id = ? AND seats_taken < capacity RETURNING seats_taken")
    fx.reset_elective(capacity=2, preregistered=1)
    s1, s2 = fx.students[10], fx.students[11]
    t1, t2 = session("T1"), session("T2")
    sql = ("UPDATE course_offering SET seats_taken = seats_taken + 1 "
           "WHERE offering_id = %s AND seats_taken < capacity RETURNING seats_taken")
    q(t1, "BEGIN"); q(t2, "BEGIN")
    r1 = one(t1, sql, (fx.offering,)); log("T1", f"conditional UPDATE -> {'seat taken, now ' + str(r1[0]) if r1 else '0 rows'}")
    q(t1, "INSERT INTO enrollment (student_id, offering_id) VALUES (%s, %s)", (s1, fx.offering))

    def t2_work():
        r2 = one(t2, sql, (fx.offering,))
        log("T2", f"conditional UPDATE returned after wait -> {'seat taken' if r2 else '0 rows: WHERE re-checked on the NEW row version, course full'}")
        if r2:
            q(t2, "INSERT INTO enrollment (student_id, offering_id) VALUES (%s, %s)", (s2, fx.offering))
            q(t2, "COMMIT")
        else:
            q(t2, "ROLLBACK")

    log("T2", "conditional UPDATE (waits for T1's row lock)")
    bg = Background(t2_work)
    time.sleep(0.5)
    show_waits(admin)
    q(t1, "COMMIT"); log("T1", "COMMIT")
    bg.join()
    report_elective(fx)
    t1.close(); t2.close()
def c3_write_skew(fx, admin):
    banner("C3  WRITE SKEW - the 24-unit credit limit in fn_register_course v1\n"
           "    One student (20 units registered) submits two 4-unit courses from two browser tabs.")
    student = one(admin, """SELECT s.student_id FROM student s JOIN programme p USING (programme_id)
                            JOIN department d USING (department_id)
                            WHERE d.code = 'CSC' AND s.current_level = 100 AND s.status = 'ACTIVE'
                            ORDER BY s.student_id LIMIT 1""")[0]
    pre = [fx.offering_of("MTH105"), fx.offering_of("PHY105")]
    race = [fx.offering_of("ECO102"), fx.offering_of("ACC102")]

    def units():
        return one(admin, """SELECT coalesce(sum(c.credit_units),0) FROM enrollment e JOIN course_offering o USING (offering_id)
                             JOIN course c USING (course_id) WHERE e.student_id = %s AND o.semester_id = %s
                             AND e.status <> 'DROPPED'""", (student, fx.sem))[0]

    def cleanup():
        for off in pre + race:
            n = one(admin, "DELETE FROM enrollment WHERE student_id=%s AND offering_id=%s RETURNING 1", (student, off))
            if n:
                q(admin, "UPDATE course_offering SET seats_taken = seats_taken - 1 WHERE offering_id=%s", (off,))

    def setup():
        cleanup()
        for off in pre:
            q(admin, "SELECT fn_register_course(%s, %s)", (student, off))
        log("PRE", f"student {student} registered MTH105 + PHY105 -> {units()} units (limit 24)")

    def race_run(isolation, label):
        print(f"\n--- {label}")
        setup()
        t1, t2 = session("T1"), session("T2")
        q(t1, f"BEGIN ISOLATION LEVEL {isolation}"); q(t2, f"BEGIN ISOLATION LEVEL {isolation}")
        log("T1", f"BEGIN {isolation}; SELECT fn_register_course(student, ECO102 4u)")
        try:
            one(t1, "SELECT fn_register_course(%s, %s)", (student, race[0])); log("T1", "OK (not committed yet)")
        except psycopg.Error as e:
            log("T1", f"ERROR {e.sqlstate}: {e.diag.message_primary}")

        def t2_work():
            one(t2, "SELECT fn_register_course(%s, %s)", (student, race[1]))
            return "ok"

        log("T2", f"BEGIN {isolation}; SELECT fn_register_course(student, ACC102 4u)")
        bg = Background(t2_work)
        time.sleep(0.5)
        show_waits(admin)
        try:
            q(t1, "COMMIT"); log("T1", "COMMIT ok")
        except psycopg.Error as e:
            log("T1", f"COMMIT failed {e.sqlstate}: {e.diag.message_primary}")
        bg.join()
        if bg.error:
            log("T2", f"ERROR {bg.error.sqlstate}: {bg.error.diag.message_primary}")
            q(t2, "ROLLBACK")
        else:
            log("T2", "fn_register_course OK")
            try:
                q(t2, "COMMIT"); log("T2", "COMMIT ok")
            except psycopg.Error as e:
                log("T2", f"COMMIT failed {e.sqlstate}: {e.diag.message_primary}")
                if e.diag.message_detail:
                    log("T2", f"   detail: {e.diag.message_detail}")
        total = units()
        log("RES", f"student {student} now has {total} units"
            + ("   <-- RULE VIOLATED (limit 24)" if total > 24 else "   (rule respected)"))
        t1.close(); t2.close()

    race_run("READ COMMITTED", "C3a  v1 under READ COMMITTED: both transactions see 20 units, each adds 4")
    race_run("SERIALIZABLE", "C3b  v1 under SERIALIZABLE: SSI detects the read/write dependency cycle")
    print("\n--- C3c  install fn_register_course v2 (locks the student row first), back to READ COMMITTED")
    q(admin, (HERE.parent / "sql" / "02_fix_register_course_v2.sql").read_text())
    log("ADM", "fn_register_course v2 installed")
    race_run("READ COMMITTED", "C3c  v2 under READ COMMITTED")
    cleanup()
def c4_isolation(fx):
    banner("C4  ISOLATION LEVELS - non-repeatable read & phantom read: READ COMMITTED vs REPEATABLE READ")
    fx.reset_elective(capacity=30, preregistered=5)
    target = one(fx.admin, "SELECT min(enrollment_id) FROM enrollment WHERE offering_id=%s", (fx.offering,))[0]
    newcomer = fx.students[20]
    for level in ("READ COMMITTED", "REPEATABLE READ"):
        print(f"\n--- reader A at {level}")
        q(fx.admin, "UPDATE enrollment SET ca_score = 10 WHERE enrollment_id = %s", (target,))
        q(fx.admin, "DELETE FROM enrollment WHERE student_id=%s AND offering_id=%s", (newcomer, fx.offering))
        a, b = session("A"), session("B")
        q(a, f"BEGIN ISOLATION LEVEL {level}")
        ca1 = one(a, "SELECT ca_score FROM enrollment WHERE enrollment_id=%s", (target,))[0]
        n1 = one(a, "SELECT count(*) FROM enrollment WHERE offering_id=%s", (fx.offering,))[0]
        log("A", f"read 1: CA score = {ca1}, students in CSC190 = {n1}")
        q(b, "BEGIN")
        q(b, "UPDATE enrollment SET ca_score = 27 WHERE enrollment_id=%s", (target,))
        q(b, "INSERT INTO enrollment (student_id, offering_id) VALUES (%s, %s)", (newcomer, fx.offering))
        log("B", "UPDATE CA score to 27 and INSERT a new student (not committed)")
        ca_d = one(a, "SELECT ca_score FROM enrollment WHERE enrollment_id=%s", (target,))[0]
        log("A", f"read while B uncommitted: CA = {ca_d}  -> no dirty read")
        q(b, "COMMIT"); log("B", "COMMIT")
        ca2 = one(a, "SELECT ca_score FROM enrollment WHERE enrollment_id=%s", (target,))[0]
        n2 = one(a, "SELECT count(*) FROM enrollment WHERE offering_id=%s", (fx.offering,))[0]
        nr = "NON-REPEATABLE READ" if ca2 != ca1 else "repeatable"
        ph = "PHANTOM ROW appeared" if n2 != n1 else "no phantom"
        log("A", f"read 2: CA score = {ca2} ({nr}), students = {n2} ({ph})")
        q(a, "COMMIT")
        a.close(); b.close()
    q(fx.admin, "DELETE FROM enrollment WHERE student_id=%s AND offering_id=%s", (newcomer, fx.offering))
def c5_deadlock(fx):
    banner("C5  DEADLOCK - two grade-correction jobs touch the same two results in opposite order")
    fx.reset_elective(capacity=30, preregistered=2)
    x, y = [r[0] for r in q(fx.admin, "SELECT enrollment_id FROM enrollment WHERE offering_id=%s ORDER BY 1", (fx.offering,))]
    dl = one(fx.admin, "SHOW deadlock_timeout")[0]
    log("INFO", f"results X={x}, Y={y}; deadlock_timeout = {dl}")

    def job(name, order, ordered_locking):
        c = session(name)
        try:
            q(c, "BEGIN")
            if ordered_locking:
                q(c, "SELECT enrollment_id FROM enrollment WHERE enrollment_id = ANY(%s) ORDER BY enrollment_id FOR UPDATE",
                  ([x, y],))
                log(name, "locked X and Y in enrollment_id order")
            for i, eid in enumerate(order):
                q(c, "UPDATE enrollment SET ca_score = %s WHERE enrollment_id = %s", (15 + i, eid))
                log(name, f"UPDATE result {eid}")
                time.sleep(0.3)
            q(c, "COMMIT"); log(name, "COMMIT")
        except errors.DeadlockDetected as e:
            log(name, f"ERROR {e.sqlstate} deadlock_detected -> this transaction was chosen as the victim")
            log(name, f"   {e.diag.message_detail.splitlines()[0] if e.diag.message_detail else ''}")
            q(c, "ROLLBACK")
        finally:
            c.close()

    for ordered in (False, True):
        print("\n--- " + ("WITH consistent lock ordering (fix)" if ordered else "WITHOUT lock ordering"))
        j1 = threading.Thread(target=job, args=("T1", [x, y], ordered))
        j2 = threading.Thread(target=job, args=("T2", [y, x], ordered))
        j1.start(); time.sleep(0.05); j2.start(); j1.join(); j2.join()
def c6_mvcc(fx):
    banner("C6  MVCC - a writer does not block readers; each sees its own row version")
    fx.reset_elective(capacity=30, preregistered=1)
    eid = one(fx.admin, "SELECT enrollment_id FROM enrollment WHERE offering_id=%s", (fx.offering,))[0]
    w, r = session("W"), session("R")
    q(w, "BEGIN")
    txid = one(w, "SELECT pg_current_xact_id()")[0]
    q(w, "UPDATE enrollment SET ca_score = 29 WHERE enrollment_id=%s", (eid,))
    log("W", f"txid {txid}: UPDATE ca_score = 29 (uncommitted)")
    t = time.perf_counter()
    row = one(r, "SELECT ca_score, xmin, xmax, ctid FROM enrollment WHERE enrollment_id=%s", (eid,))
    log("R", f"SELECT returned in {1000 * (time.perf_counter() - t):.2f} ms (not blocked): "
             f"ca_score={row[0]} xmin={row[1]} xmax={row[2]} ctid={row[3]}")
    log("R", f"xmax = {row[2]} marks the version as being replaced by W's transaction")
    row = one(w, "SELECT ca_score, xmin, xmax, ctid FROM enrollment WHERE enrollment_id=%s", (eid,))
    log("W", f"W sees its own new version: ca_score={row[0]} xmin={row[1]} ctid={row[3]}")
    q(w, "COMMIT")
    row = one(r, "SELECT ca_score, xmin, xmax, ctid FROM enrollment WHERE enrollment_id=%s", (eid,))
    log("R", f"after COMMIT: ca_score={row[0]} xmin={row[1]} ctid={row[3]} (new tuple)")
    w.close(); r.close()
def c7_stress(fx):
    banner("C7  STRESS TEST - 40 students register for CSC190 (25 seats) at the same instant")
    n_threads, capacity = 40, 25
    students = fx.students[:n_threads]

    def naive(conn, sid):
        q(conn, "BEGIN")
        seats, cap = naive_read(conn, fx.offering)
        if seats >= cap:
            q(conn, "ROLLBACK"); return False
        time.sleep(random.uniform(0, 0.02))
        naive_write(conn, sid, fx.offering, seats)
        q(conn, "COMMIT"); return True

    def locked_function(conn, sid):
        try:
            q(conn, "SELECT fn_register_course(%s, %s)", (sid, fx.offering)); return True
        except psycopg.Error as e:  # AU001 = full
            if e.sqlstate != "AU001":
                raise
            return False

    def atomic(conn, sid):
        q(conn, "BEGIN")
        time.sleep(random.uniform(0, 0.02))
        r = one(conn, "UPDATE course_offering SET seats_taken = seats_taken + 1 "
                      "WHERE offering_id = %s AND seats_taken < capacity RETURNING 1", (fx.offering,))
        if not r:
            q(conn, "ROLLBACK"); return False
        q(conn, "INSERT INTO enrollment (student_id, offering_id) VALUES (%s, %s)", (sid, fx.offering))
        q(conn, "COMMIT"); return True

    rows = []
    for label, fn in (("naive read-check-write (READ COMMITTED)", naive),
                      ("fn_register_course v2 (SELECT ... FOR UPDATE)", locked_function),
                      ("atomic conditional UPDATE", atomic)):
        fx.reset_elective(capacity=capacity)
        conns = [session(f"S{i}") for i in range(n_threads)]
        barrier = threading.Barrier(n_threads)
        ok = []

        def worker(i):
            barrier.wait()
            ok.append(fn(conns[i], students[i]))

        t = time.perf_counter()
        ths = [threading.Thread(target=worker, args=(i,)) for i in range(n_threads)]
        [th.start() for th in ths]; [th.join() for th in ths]
        elapsed = (time.perf_counter() - t) * 1000
        [c.close() for c in conns]
        enrolled, seats, cap = fx.elective_state()
        rows.append((label, sum(ok), n_threads - sum(ok), enrolled, seats, cap, elapsed))

    print(f"\n{'strategy':<48}{'accepted':>9}{'refused':>9}{'rows':>6}{'counter':>9}{'cap':>5}{'ms':>8}  verdict")
    for label, acc, rej, enrolled, seats, cap, ms in rows:
        verdict = "OVERBOOKED + counter wrong" if (enrolled > cap or enrolled != seats) else "correct"
        print(f"{label:<48}{acc:>9}{rej:>9}{enrolled:>6}{seats:>9}{cap:>5}{ms:>8.0f}  {verdict}")

def main():
    random.seed(8103)
    admin = session("ADMIN")
    # start from v1
    q(admin, (HERE.parents[1] / "portfolio-1-database-design" / "sql" / "04_logic.sql").read_text())
    print(f"Server: {one(admin, 'SELECT version()')[0]}")
    print(f"Default isolation: {one(admin, 'SHOW default_transaction_isolation')[0]}")
    fx = Fixture(admin)
    c1_lost_update(fx)
    c2a_for_update(fx, admin)
    c2b_repeatable_read(fx)
    c2c_atomic_update(fx, admin)
    c3_write_skew(fx, admin)
    c4_isolation(fx)
    c5_deadlock(fx)
    c6_mvcc(fx)
    c7_stress(fx)
    fx.reset_elective(capacity=25)
    admin.close()

if __name__ == "__main__":
    main()
