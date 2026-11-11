#!/usr/bin/env python3
"""Replication experiments R1-R7 (primary :5433, standby :5434)."""
import getpass
import statistics
import subprocess
import threading
import time
from pathlib import Path

import psycopg
from psycopg import errors

ROOT = Path(__file__).resolve().parents[2]
PRIM, STBY = ROOT / ".data" / "pg-primary", ROOT / ".data" / "pg-standby"
DB = "university_portal"

def dsn(port):
    return f"host=localhost port={port} dbname={DB}"

def conn(port, **kw):
    return psycopg.connect(dsn(port), autocommit=True, **kw)

def val(c, sql, params=None):
    return c.execute(sql, params).fetchone()[0]

def banner(t):
    print("\n" + "=" * 90 + f"\n{t}\n" + "=" * 90, flush=True)

def sh(*cmd):
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout

def replication_status(c):
    rows = c.execute("""SELECT application_name, state, sync_state, sent_lsn, replay_lsn,
                               pg_wal_lsn_diff(sent_lsn, replay_lsn) AS bytes_behind,
                               write_lag, flush_lag, replay_lag
                        FROM pg_stat_replication""").fetchall()
    for r in rows:
        print(f"  {r[0]}: state={r[1]} sync_state={r[2]} sent={r[3]} replayed={r[4]} "
              f"bytes_behind={r[5]} write_lag={r[6]} flush_lag={r[7]} replay_lag={r[8]}")
    return rows

def set_sync(primary, names):
    primary.execute(f"ALTER SYSTEM SET synchronous_standby_names = '{names}'")
    primary.execute("SELECT pg_reload_conf()")
    time.sleep(0.5)

def r1_topology(p, s):
    banner("R1  Topology")
    for name, c in (("primary :5433", p), ("standby :5434", s)):
        print(f"  {name}: in_recovery={val(c, 'SELECT pg_is_in_recovery()')}, "
              f"timeline={val(c, 'SELECT timeline_id FROM pg_control_checkpoint()')}, "
              f"enrollment rows={val(c, 'SELECT count(*) FROM enrollment'):,}")
    replication_status(p)
    for r in p.execute("SELECT slot_name, slot_type, active, restart_lsn FROM pg_replication_slots"):
        print(f"  replication slot: {r}")

def r2_lag(p, s, n=50):
    banner("R2  Replication lag: time until a committed row is visible on the standby (asynchronous)")
    p.execute("CREATE TABLE IF NOT EXISTS replication_probe (id serial PRIMARY KEY, note text, created timestamptz DEFAULT clock_timestamp())")
    time.sleep(0.5)
    lags = []
    for i in range(n):
        rid = val(p, "INSERT INTO replication_probe (note) VALUES (%s) RETURNING id", (f"probe {i}",))
        t = time.perf_counter()
        while not s.execute("SELECT 1 FROM replication_probe WHERE id = %s", (rid,)).fetchone():
            pass
        lags.append((time.perf_counter() - t) * 1000)
    print(f"  {n} probes: median {statistics.median(lags):.2f} ms, p95 {statistics.quantiles(lags, n=20)[18]:.2f} ms, "
          f"max {max(lags):.2f} ms  (eventual consistency window on the read replica)")
    t = time.perf_counter()
    upd = p.execute("UPDATE enrollment SET registered_at = registered_at WHERE status = 'REGISTERED'").rowcount
    lsn = val(p, "SELECT pg_current_wal_lsn()")
    commit_ms = (time.perf_counter() - t) * 1000
    while val(s, "SELECT pg_wal_lsn_diff(%s::pg_lsn, pg_last_wal_replay_lsn())", (lsn,)) > 0:
        time.sleep(0.005)
    print(f"  bulk UPDATE of {upd:,} rows committed in {commit_ms:.0f} ms; standby caught up "
          f"{(time.perf_counter() - t) * 1000 - commit_ms:.0f} ms later")
    replication_status(p)

def r3_read_only(s):
    banner("R3  Standby is read-only; read scaling")
    try:
        s.execute("UPDATE enrollment SET exam_score = 70 WHERE enrollment_id = 1")
    except errors.ReadOnlySqlTransaction as e:
        print(f"  write on standby rejected: [{e.sqlstate}] {e.diag.message_primary}")
    sql = (ROOT / "portfolio-2-query-optimisation" / "sql" / "queries" / "q01_student_transcript.sql").read_text()
    rows = s.execute(sql).fetchall()
    print(f"  transcript query (Q01) served by the standby: {len(rows)} rows, first: {rows[0][:4]}")
    t, n = time.perf_counter(), 0
    while time.perf_counter() - t < 2:
        s.execute(sql).fetchall(); n += 1
    print(f"  one client on the standby: {n / 2:,.0f} transcript reads/s while the primary handles writes")

def commit_latency(p, n=300):
    times = []
    for i in range(n):
        t = time.perf_counter()
        p.execute("INSERT INTO replication_probe (note) VALUES ('latency')")
        times.append((time.perf_counter() - t) * 1000)
    return statistics.median(times), statistics.quantiles(times, n=20)[18]

def r4_sync_vs_async(p):
    banner("R4  Commit latency: asynchronous vs synchronous replication (300 single-row commits each)")
    set_sync(p, "")
    a = commit_latency(p)
    set_sync(p, "FIRST 1 (standby1)")
    print("  after ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (standby1)':")
    replication_status(p)
    s_ = commit_latency(p)
    print(f"\n  {'mode':<44}{'median ms':>10}{'p95 ms':>9}  data loss if primary dies (RPO)")
    print(f"  {'asynchronous (default)':<44}{a[0]:>10.3f}{a[1]:>9.3f}  last few ms of commits")
    print(f"  {'synchronous, synchronous_commit=on':<44}{s_[0]:>10.3f}{s_[1]:>9.3f}  zero: commit waits for standby flush")

def r5_cap(p):
    banner("R5  CAP trade-off: synchronous primary + standby DOWN = commits block (consistency over availability)")
    sh("pg_ctl", "-D", str(STBY), "stop", "-m", "fast")
    print("  standby stopped")
    result = {}

    def writer():
        c = conn(5433, application_name="p5-writer")
        result["pid"] = c.info.backend_pid
        result["notices"] = []
        c.add_notice_handler(lambda d: result["notices"].append(
            f"{d.severity}: {d.message_primary} | {d.message_detail}"))
        t = time.perf_counter()
        try:
            c.execute("INSERT INTO replication_probe (note) VALUES ('during outage')")
            result["outcome"] = "committed"
        except psycopg.Error as e:
            result["outcome"] = f"error {e.sqlstate}"
        result["ms"] = (time.perf_counter() - t) * 1000
        c.close()

    th = threading.Thread(target=writer)
    th.start()
    time.sleep(3)
    r = p.execute("SELECT state, wait_event_type, wait_event FROM pg_stat_activity WHERE application_name = 'p5-writer'").fetchone()
    print(f"  after 3 s the INSERT is still waiting: state={r[0]} wait_event={r[1]}:{r[2]}")
    p.execute("SELECT pg_cancel_backend(%s)", (result["pid"],))
    th.join()
    print(f"  pg_cancel_backend -> writer returned after {result['ms']:.0f} ms ({result['outcome']})")
    for n in result["notices"]:
        print(f"  server -> client {n}")
    set_sync(p, "")
    print("  synchronous_standby_names reset to '' (async) -> writes available again; restarting standby")
    sh("pg_ctl", "-D", str(STBY), "-l", str(STBY / "server.log"), "-w", "start")
    time.sleep(1)
    replication_status(p)

def r6_failover(p, s):
    banner("R6  Failover: primary crashes (immediate shutdown), standby is promoted")
    marker = val(p, "INSERT INTO replication_probe (note) VALUES ('last write before crash') RETURNING id")
    lsn = val(p, "SELECT pg_current_wal_lsn()")
    while val(s, "SELECT pg_wal_lsn_diff(%s::pg_lsn, pg_last_wal_replay_lsn())", (lsn,)) > 0:
        time.sleep(0.005)
    p.close(); s.close()
    t0 = time.perf_counter()
    sh("pg_ctl", "-D", str(PRIM), "stop", "-m", "immediate")
    print(f"  t=0.000s  primary killed (pg_ctl stop -m immediate = simulated crash)")
    try:
        conn(5433, connect_timeout=1)
    except psycopg.OperationalError:
        print(f"  t={time.perf_counter() - t0:.3f}s  primary unreachable: connection refused")
    sh("pg_ctl", "-D", str(STBY), "promote", "-w")
    print(f"  t={time.perf_counter() - t0:.3f}s  pg_ctl promote completed")
    while True:
        try:
            c = conn(5434)
            c.execute("INSERT INTO replication_probe (note) VALUES ('first write on new primary')")
            break
        except psycopg.Error:
            time.sleep(0.01)
    rto = time.perf_counter() - t0
    print(f"  t={rto:.3f}s  new primary (:5434) accepts writes  ->  RTO = {rto:.2f} s (plus detection time in production)")
    c.execute("CHECKPOINT")
    print(f"  in_recovery={val(c, 'SELECT pg_is_in_recovery()')}, timeline={val(c, 'SELECT timeline_id FROM pg_control_checkpoint()')}"
          f" (timeline increments on promotion)")
    found = val(c, "SELECT note FROM replication_probe WHERE id = %s", (marker,))
    print(f"  last write before the crash present on new primary: {found!r}  ->  RPO = 0 for replicated commits")
    c.close()

def r7_rewind():
    banner("R7  Re-join the failed primary as a standby of the new primary (pg_rewind)")
    res = subprocess.run(["pg_rewind", "--target-pgdata", str(PRIM),
             "--source-server", f"host=localhost port=5434 user={getpass.getuser()} dbname=postgres"],
                         capture_output=True, text=True, check=True)
    for line in (res.stdout + res.stderr).splitlines():
        if line.startswith("pg_rewind:"):
            print("  " + line)
    # pg_rewind copied the new primary's config, so write our own
    newp = conn(5434)
    newp.execute("SELECT pg_create_physical_replication_slot('old_primary')")
    newp.close()
    (PRIM / "standby.signal").touch()
    (PRIM / "postgresql.auto.conf").write_text(
        "port = 5433\n"
        f"primary_conninfo = 'host=localhost port=5434 user={getpass.getuser()} application_name=old_primary'\n"
        "primary_slot_name = 'old_primary'\n")
    sh("pg_ctl", "-D", str(PRIM), "-l", str(PRIM / "server.log"), "-w", "start")
    time.sleep(1.5)
    newp = conn(5434)
    print("  pg_stat_replication on the NEW primary (:5434):")
    replication_status(newp)
    old = conn(5433)
    print(f"  old primary :5433 in_recovery={val(old, 'SELECT pg_is_in_recovery()')} -> roles have been swapped")
    old.close(); newp.close()

if __name__ == "__main__":
    p, s = conn(5433), conn(5434)
    print(f"Server: {val(p, 'SELECT version()')}")
    r1_topology(p, s)
    r2_lag(p, s)
    r3_read_only(s)
    r4_sync_vs_async(p)
    r5_cap(p)
    s = conn(5434)
    r6_failover(p, s)
    r7_rewind()
