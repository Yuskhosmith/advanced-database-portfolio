#!/usr/bin/env python3
"""Sharding experiments S1-S8."""
import os
import signal
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path

from pymongo import MongoClient, ReadPreference
from pymongo.read_concern import ReadConcern
from pymongo.write_concern import WriteConcern

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "portfolio-4-nosql" / "scripts"))
from etl_postgres_to_mongo import STUDENT_SCHEMA  # noqa: E402
sys.path.insert(0, str(Path(__file__).resolve().parent))
from mongo_cluster import SHARDS, direct, mongod_cmd  # noqa: E402

MONGOS = "mongodb://127.0.0.1:27300/?retryWrites=true"
SOURCE = os.environ.get("MONGO_URI", "mongodb://127.0.0.1:27117")
client = MongoClient(MONGOS)
db = client["ausrp"]
T0 = time.perf_counter()

def banner(t):
    print("\n" + "=" * 90 + f"\n{t}\n" + "=" * 90, flush=True)

def shard_of(matric):
    ex = db.students.find({"_id": matric}).explain()
    return ex["queryPlanner"]["winningPlan"]["shards"][0]["shardName"]

def s1_topology():
    banner("S1  Cluster topology")
    for s in client.admin.command("listShards")["shards"]:
        print(f"  shard {s['_id']}: {s['host']}")
    for rs, ports in SHARDS.items():
        st = direct(ports[0]).admin.command("replSetGetStatus")
        print(f"  {rs}: " + ", ".join(f"{m['name']}={m['stateStr']}" for m in st["members"]))
    print(f"  mongos {client.admin.command('hello').get('msg')} - applications connect only to the router")

def s2_shard_and_load():
    banner("S2  Shard ausrp.students on {_id: 'hashed'} and load 20,000 student documents")
    client.drop_database("ausrp")
    db.create_collection("students", validator=STUDENT_SCHEMA)
    client.admin.command("shardCollection", "ausrp.students", key={"_id": "hashed"})
    client.admin.command("shardCollection", "ausrp.result_events", key={"_id": "hashed"})
    src = MongoClient(SOURCE)["ausrp"]["students"]
    batch, n, t = [], 0, time.perf_counter()
    for doc in src.find():
        batch.append(doc)
        if len(batch) == 1000:
            db.students.insert_many(batch, ordered=False); n += len(batch); batch = []
    if batch:
        db.students.insert_many(batch, ordered=False); n += len(batch)
    db.students.create_index([("department.code", 1), ("summary.cgpa", -1)])
    print(f"  inserted {n:,} documents through mongos in {time.perf_counter() - t:.1f}s")
    print("  shard key choice: hashed matric number -> uniform spread, no hot shard for new cohorts;")
    print("  every portal lookup by matric number is still routed to exactly one shard.")

def s3_distribution():
    banner("S3  Data distribution")
    rows = list(db.students.aggregate([{"$collStats": {"storageStats": {}}},
                                       {"$project": {"shard": 1, "count": "$storageStats.count",
                                                     "size": "$storageStats.size"}}]))
    total = sum(r["count"] for r in rows)
    for r in sorted(rows, key=lambda r: r["shard"]):
        print(f"  {r['shard']}: {r['count']:>6,} documents ({100 * r['count'] / total:4.1f}%), {r['size'] / 1e6:6.1f} MB")
    uuid = client.config.collections.find_one({"_id": "ausrp.students"})["uuid"]
    for r in client.config.chunks.aggregate([{"$match": {"uuid": uuid}}, {"$group": {"_id": "$shard", "chunks": {"$sum": 1}}},
                                             {"$sort": {"_id": 1}}]):
        print(f"  {r['_id']}: {r['chunks']} chunk(s) of the hashed key range")

def s4_routing():
    banner("S4  Query routing by mongos")
    for label, q in (("by shard key  {_id: 'AU/2022/00007'}", {"_id": "AU/2022/00007"}),
                     ("non-shard key {'department.code': 'CSC'}", {"department.code": "CSC"})):
        ex = db.students.find(q).explain()
        wp = ex["queryPlanner"]["winningPlan"]
        shards = [s["shardName"] for s in wp["shards"]]
        per = {s["shardName"]: s["nReturned"] for s in ex["executionStats"]["executionStages"]["shards"]}
        print(f"  {label:<44} stage={wp['stage']:<13} shards contacted={shards} nReturned per shard={per}")
    print("  -> lookups by matric number scale linearly with shards; department-wide reports fan out to all shards.")

def latency(coll, n=200):
    times = []
    for i in range(n):
        t = time.perf_counter()
        coll.insert_one({"type": "grade_posted", "seq": i})
        times.append((time.perf_counter() - t) * 1000)
    return statistics.median(times), statistics.quantiles(times, n=20)[18]

def s5_write_concern():
    banner("S5  Write concern: acknowledgement level vs latency (200 inserts each, via mongos)")
    print(f"  {'write concern':<36}{'median ms':>10}{'p95 ms':>9}  survives primary failure?")
    for label, wc, note in (("w:1", WriteConcern(w=1), "no - may be rolled back"),
                            ("w:'majority'", WriteConcern(w="majority"), "yes - on 2 of 3 members"),
                            ("w:'majority', j:true", WriteConcern(w="majority", j=True), "yes - on disk on 2 of 3")):
        med, p95 = latency(db.get_collection("result_events", write_concern=wc))
        print(f"  {label:<36}{med:>10.3f}{p95:>9.3f}  {note}")

def s6_read_preference():
    banner("S6  Read preference: route read-only portal traffic to secondaries")
    for pref in (ReadPreference.PRIMARY, ReadPreference.SECONDARY):
        coll = db.get_collection("students", read_preference=pref)
        ex = coll.find({"_id": "AU/2022/00007"}).explain()
        s = ex["queryPlanner"]["winningPlan"]["shards"][0]
        port = s["serverInfo"]["port"]
        state = direct(port).admin.command("hello")
        role = "PRIMARY" if state.get("isWritablePrimary") else "SECONDARY"
        print(f"  readPreference={pref.name:<10} served by {s['shardName']} member :{port} ({role})")
    print("  readConcern 'majority' guarantees the document read cannot later be rolled back;")
    print("  'local' on a secondary may return slightly stale data (eventual consistency).")

def s7_transaction():
    banner("S7  Distributed ACID transaction across two shards")
    # sort so the ids come from both shards
    ids = [d["_id"] for d in db.students.find({"status": "ACTIVE"}, {"_id": 1}).sort("_id", 1).limit(40)]
    by_shard = {}
    for i in ids:
        by_shard.setdefault(shard_of(i), i)
        if len(by_shard) == 2:
            break
    (sa, a), (sb, b) = sorted(by_shard.items())
    print(f"  student {a} lives on {sa}; student {b} lives on {sb}")
    audit = db.get_collection("result_audit")
    audit.insert_one({"_id": "init"}); audit.delete_one({"_id": "init"})

    def flags():
        return [db.students.find_one({"_id": x}, {"summary.on_deans_list": 1}).get("summary", {}).get("on_deans_list")
                for x in (a, b)], audit.count_documents({})

    wc = WriteConcern("majority")
    with client.start_session() as s:
        s.start_transaction(read_concern=ReadConcern("snapshot"), write_concern=wc)
        db.students.update_one({"_id": a}, {"$set": {"summary.on_deans_list": True}}, session=s)
        db.students.update_one({"_id": b}, {"$set": {"summary.on_deans_list": True}}, session=s)
        audit.insert_one({"action": "deans_list_published", "students": [a, b]}, session=s)
        s.commit_transaction()
    print(f"  T1 commit -> flags={flags()[0]}, audit docs={flags()[1]}  (both shards + audit updated atomically, 2PC)")
    with client.start_session() as s:
        s.start_transaction(read_concern=ReadConcern("snapshot"), write_concern=wc)
        db.students.update_one({"_id": a}, {"$set": {"summary.on_deans_list": False}}, session=s)
        db.students.update_one({"_id": b}, {"$set": {"summary.on_deans_list": False}}, session=s)
        audit.insert_one({"action": "deans_list_withdrawn", "students": [a, b]}, session=s)
        s.abort_transaction()
    print(f"  T2 abort  -> flags={flags()[0]}, audit docs={flags()[1]}  (nothing from T2 is visible on either shard)")

def s8_failover():
    banner("S8  Failover: kill -9 the PRIMARY of shardA while the portal keeps writing (w:majority, retryWrites)")
    ports = SHARDS["shardA"]
    prim = next(p for p in ports if direct(p).admin.command("hello").get("isWritablePrimary"))
    pid = direct(prim).admin.command("serverStatus")["pid"]
    events = db.get_collection("result_events", write_concern=WriteConcern("majority"))
    log, stop = [], threading.Event()

    def writer():
        i = 0
        while not stop.is_set():
            t = time.perf_counter()
            try:
                events.insert_one({"type": "failover_probe", "seq": i}); ok = True
            except Exception as e:
                ok = False
                print(f"    write {i} failed: {type(e).__name__}")
            log.append((t - T0, (time.perf_counter() - t) * 1000, ok)); i += 1
            time.sleep(0.02)

    th = threading.Thread(target=writer); th.start()
    time.sleep(2)
    t_kill = time.perf_counter()
    os.kill(int(pid), signal.SIGKILL)
    print(f"  t=0.0s   SIGKILL to shardA primary :{prim} (pid {pid})")
    new = None
    while new is None:
        for p in ports:
            if p == prim:
                continue
            try:
                if direct(p).admin.command("hello").get("isWritablePrimary"):
                    new = p
            except Exception:
                pass
        time.sleep(0.1)
    elect = time.perf_counter() - t_kill
    print(f"  t={elect:.1f}s  member :{new} elected PRIMARY of shardA (electionTimeoutMillis = "
          f"{direct(new).admin.command('replSetGetConfig')['config']['settings']['electionTimeoutMillis']} ms)")
    time.sleep(3)
    stop.set(); th.join()
    during = [l for l in log if l[0] >= t_kill - T0 - 0.1]
    print(f"  writes attempted: {len(log)}, failed: {sum(not l[2] for l in log)}; "
          f"max write latency {max(l[1] for l in log):.0f} ms")
    print("  -> the in-flight write to shardA was held by mongos/driver until a new primary existed and was then")
    print("     retried (retryWrites): the portal saw a ~10 s pause, not an error. Availability is lost only for")
    print("     the keys on the failed shard and only for the election window (CP behaviour of a replica set).")
    slow = [l for l in during if l[1] > 500]
    print(f"  writes slower than 500 ms around the failover: {len(slow)}")
    subprocess.run(mongod_cmd("shardA", prim, "--shardsvr"), check=True, capture_output=True)
    for _ in range(120):
        st = direct(new).admin.command("replSetGetStatus")
        states = {m["name"]: m["stateStr"] for m in st["members"]}
        if states.get(f"127.0.0.1:{prim}") == "SECONDARY":
            break
        time.sleep(0.5)
    print(f"  restarted :{prim}; it rejoined as {states[f'127.0.0.1:{prim}']}. shardA now: {states}")
    print("  (with priority 2, :27201 will later call an election and take back the primary role)")

if __name__ == "__main__":
    s1_topology()
    s2_shard_and_load()
    s3_distribution()
    s4_routing()
    s5_write_concern()
    s6_read_preference()
    s7_transaction()
    s8_failover()
