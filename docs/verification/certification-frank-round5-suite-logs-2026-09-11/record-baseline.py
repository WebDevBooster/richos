#!/usr/bin/env python3
"""Read-only witness of the operator's record. Prints counts and the rows that matter."""
import glob, json, os, sys, datetime
home = os.path.expanduser("~")
L = os.path.join(home, ".claude/state/worktree-ledger.jsonl")
F = os.path.join(home, ".claude/worker-events.jsonl")
T = os.path.join(home, ".claude/teams")
X = os.path.join(home, ".claude/state/worktree-transactions")
print(datetime.datetime.now(datetime.timezone.utc).isoformat())
rows = []
with open(L, "rb") as f:
    raw = f.read().split(b"\n")
print("ledger lines:", sum(1 for r in raw if r.strip()))
for r in raw:
    if not r.strip():
        continue
    try:
        rows.append(json.loads(r))
    except Exception:
        print("UNPARSABLE:", r[:80])
ev = {}
for r in rows:
    ev[r.get("event")] = ev.get(r.get("event"), 0) + 1
print("events:", ev)
print("terminated:", ev.get("terminated", 0))
print("platform-terminal-record:", sum(1 for r in rows if r.get("witness") == "platform-terminal-record"))
print("retracted:", ev.get("retracted", 0))
print("worker-events lines:", sum(1 for l in open(F, "rb") if l.strip()))
print("teams entries:", len(os.listdir(T)))
print("tx files:", len(glob.glob(os.path.join(X, "*", "*.json"))))
bak = L + ".bak-r15-retract"
print("backup exists:", os.path.exists(bak), os.path.getsize(bak) if os.path.exists(bak) else None)
print("--- retracted rows:")
for r in rows:
    if r.get("event") == "retracted":
        print(json.dumps(r, sort_keys=True))
print("--- platform-terminal-record rows:")
for r in rows:
    if r.get("witness") == "platform-terminal-record":
        print(json.dumps(r, sort_keys=True))
