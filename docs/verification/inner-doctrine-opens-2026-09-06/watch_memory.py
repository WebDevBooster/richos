#!/usr/bin/env python3
"""Q3 watcher: sample two auto-memory stores every INTERVAL seconds and log every change.

The `-Users-alex-ab-richos` store is the QUESTION. The `-Users-alex-ab-femcboost` store is
the POSITIVE CONTROL: it is the store the outer orchestrator session actually writes to, so
a change there inside the same window proves this watcher can see a write when one happens.
Without that control a null result on the richos store would not distinguish "nothing wrote"
from "a write happened and this watcher could not see it".

Usage: watch_memory.py --minutes N --out LOG.tsv [--interval SECONDS]
"""
import argparse, hashlib, os, time

ap = argparse.ArgumentParser()
ap.add_argument("--minutes", type=float, required=True)
ap.add_argument("--interval", type=float, default=20.0)
ap.add_argument("--out", required=True)
ap.add_argument("--target", action="append", default=[], metavar="NAME=PATH",
                help="watch this path INSTEAD of the two defaults (used for the self-test)")
a = ap.parse_args()

H = os.path.expanduser("~/.claude/projects")
TARGETS = {
    "richos":    H + "/-Users-alex-ab-richos/memory",
    "femcboost": H + "/-Users-alex-ab-femcboost/memory",
}
if a.target:
    TARGETS = dict(t.split("=", 1) for t in a.target)


def snap(d):
    out = {}
    if not os.path.isdir(d):
        return {"__missing__": "1"}
    for name in sorted(os.listdir(d)):
        p = os.path.join(d, name)
        if os.path.isfile(p):
            with open(p, "rb") as fh:
                out[name] = "%d:%s" % (os.path.getsize(p),
                                       hashlib.sha256(fh.read()).hexdigest()[:12])
    return out


log = open(a.out, "a", buffering=1)


def emit(*f):
    log.write("\t".join(str(x) for x in f) + "\n")


prev = {k: snap(v) for k, v in TARGETS.items()}
for k in TARGETS:
    emit(time.strftime("%Y-%m-%dT%H:%M:%S"), k, "BASELINE", len(prev[k]), sorted(prev[k])[:5])

end = time.time() + a.minutes * 60
samples = 0
while time.time() < end:
    time.sleep(a.interval)
    samples += 1
    for k, d in TARGETS.items():
        cur = snap(d)
        if cur != prev[k]:
            added = sorted(set(cur) - set(prev[k]))
            removed = sorted(set(prev[k]) - set(cur))
            changed = sorted(n for n in set(cur) & set(prev[k]) if cur[n] != prev[k][n])
            emit(time.strftime("%Y-%m-%dT%H:%M:%S"), k, "CHANGE",
                 "added=%s" % added, "removed=%s" % removed, "changed=%s" % changed)
            prev[k] = cur

for k in TARGETS:
    emit(time.strftime("%Y-%m-%dT%H:%M:%S"), k, "FINAL", len(prev[k]), sorted(prev[k])[:5])
emit(time.strftime("%Y-%m-%dT%H:%M:%S"), "-", "SAMPLES", samples, "interval=%ss" % a.interval)
