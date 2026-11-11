#!/usr/bin/env python3
"""Local sharded cluster: cfgRS 27200, shardA 27201-3, shardB 27211-3, mongos 27300.

usage: mongo_cluster.py start | stop | status"""
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

from pymongo import MongoClient

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / ".data" / "mongo-shard"
CONFIG_OUT = ROOT / "portfolio-5-distributed-cloud" / "config"
HOST = "127.0.0.1"
CFG = ("cfgRS", [27200])
SHARDS = {"shardA": [27201, 27202, 27203], "shardB": [27211, 27212, 27213]}
MONGOS = 27300

def mongod_cmd(rs, port, role):
    d = BASE / f"{rs}-{port}"
    d.mkdir(parents=True, exist_ok=True)
    return ["mongod", role, "--replSet", rs, "--port", str(port), "--dbpath", str(d), "--bind_ip", HOST,
            "--fork", "--logpath", str(d / "mongod.log"), "--wiredTigerCacheSizeGB", "0.25"]

def direct(port):
    return MongoClient(f"mongodb://{HOST}:{port}/?directConnection=true", serverSelectionTimeoutMS=20000)

def wait_primary(port, timeout=60):
    t = time.time()
    while time.time() - t < timeout:
        try:
            if direct(port).admin.command("hello").get("isWritablePrimary"):
                return
        except Exception:
            pass
        time.sleep(0.5)
    raise TimeoutError(f"no primary on {port}")

def initiate(rs, ports, configsvr=False):
    cfg = {"_id": rs, "members": [{"_id": i, "host": f"{HOST}:{p}", "priority": 2 if i == 0 else 1}
                                  for i, p in enumerate(ports)]}
    if configsvr:
        cfg["configsvr"] = True
    direct(ports[0]).admin.command("replSetInitiate", cfg)
    wait_primary(ports[0])
    return cfg

def start():
    stop(quiet=True)
    shutil.rmtree(BASE, ignore_errors=True)
    BASE.mkdir(parents=True)
    configs = {}
    subprocess.run(mongod_cmd(CFG[0], CFG[1][0], "--configsvr"), check=True, capture_output=True)
    for rs, ports in SHARDS.items():
        for p in ports:
            subprocess.run(mongod_cmd(rs, p, "--shardsvr"), check=True, capture_output=True)
    configs[CFG[0]] = initiate(CFG[0], CFG[1], configsvr=True)
    for rs, ports in SHARDS.items():
        configs[rs] = initiate(rs, ports)
    subprocess.run(["mongos", "--configdb", f"{CFG[0]}/{HOST}:{CFG[1][0]}", "--port", str(MONGOS),
                    "--bind_ip", HOST, "--fork", "--logpath", str(BASE / "mongos.log")], check=True, capture_output=True)
    ms = MongoClient(f"mongodb://{HOST}:{MONGOS}")
    for rs, ports in SHARDS.items():
        ms.admin.command("addShard", f"{rs}/" + ",".join(f"{HOST}:{p}" for p in ports), name=rs)
    CONFIG_OUT.mkdir(exist_ok=True)
    (CONFIG_OUT / "mongo_replica_set_configs.json").write_text(json.dumps(configs, indent=2))
    (CONFIG_OUT / "mongo_cluster_commands.txt").write_text(
        "\n".join(" ".join(mongod_cmd(rs, p, r)).replace(str(ROOT), "<repo>")
                  for rs, ps, r in [(CFG[0], CFG[1], "--configsvr")] + [(k, v, "--shardsvr") for k, v in SHARDS.items()]
                  for p in ps)
        + f"\nmongos --configdb {CFG[0]}/{HOST}:{CFG[1][0]} --port {MONGOS} --bind_ip {HOST} --fork --logpath <repo>/.data/mongo-shard/mongos.log\n")
    print("cluster started:", ms.admin.command("listShards")["shards"])

def stop(quiet=False):
    subprocess.run(["pkill", "-f", "mongo-shard"], capture_output=True)
    for _ in range(60):
        if subprocess.run(["pgrep", "-f", "mongo-shard"], capture_output=True).returncode != 0:
            break
        time.sleep(0.5)
    if not quiet:
        print("cluster stopped")

def status():
    for rs, ports in [CFG] + list(SHARDS.items()):
        st = direct(ports[0]).admin.command("replSetGetStatus")
        print(rs, [(m["name"], m["stateStr"]) for m in st["members"]])

if __name__ == "__main__":
    {"start": start, "stop": stop, "status": status}[sys.argv[1] if len(sys.argv) > 1 else "start"]()
