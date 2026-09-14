#!/usr/bin/env python3
"""stopped-ending-real-records.probe.py — READ-ONLY, AGAINST THE REAL MACHINE.

The sandbox suite (engine/scripts/workspace-stopped-ending.test.sh) simulates
ONE thing: the per-agent record the platform writes when a run is stopped. This
probe closes that loop against the records the platform actually wrote on this
machine — it reads, prints, and changes nothing.

For every subagent run this machine has a per-agent record for, it asks the
SHIPPED reader (workspaces.platform_agent_record) to find that record from the
two fields a registration carries, agent_id and session_id, and reports:

  * how many runs the platform flagged `stoppedByUser` — point 11's fourth
    ending, "or was stopped";
  * for how many of those a terminal SubagentStop was ever delivered, read
    from ~/.claude/state/worktree-ledger.jsonl, which worker-ended-handoff.sh
    appends to on every SubagentStop and on nothing else. That column is the
    reason the fix exists: a stopped run gets no such signal, so nothing in
    the hook stream can make it finished;
  * whether the reader finds each record from the id alone.

Usage:  python3 docs/verification/stopped-ending-real-records.probe.py
Exit 0 when the reader found every record it was asked for; 1 otherwise.
"""
import datetime
import glob
import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(HERE, "..", "..", "engine", "scripts", "lib", "workspaces.py")
spec = importlib.util.spec_from_file_location("ws", os.path.abspath(LIB))
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)


def when(s):
    try:
        return datetime.datetime.fromisoformat((s or "").replace("Z", "+00:00")).timestamp()
    except Exception:
        return 0.0


def last_subagent_stop():
    """agent id -> the latest SubagentStop ever recorded for it."""
    out = {}
    path = os.path.expanduser("~/.claude/state/worktree-ledger.jsonl")
    if not os.path.exists(path):
        return out
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("event") != "finished":
            continue
        t = when(d.get("ts"))
        ids = {d[k] for k in ("agent_id", "owner_agent_id") if d.get(k)}
        m = re.search(r"agent-([0-9a-f]{17})", d.get("worktree") or "")
        if m:
            ids.add(m.group(1))
        for i in ids:
            out[i] = max(out.get(i, 0.0), t)
    return out


def last_transcript_row(path):
    t = 0.0
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 200000))
            for line in f.read().decode("utf-8", "replace").splitlines():
                line = line.strip()
                if line.startswith("{"):
                    try:
                        t = max(t, when(json.loads(line).get("timestamp")))
                    except Exception:
                        pass
    except OSError:
        pass
    return t


stops = last_subagent_stop()
metas = sorted(glob.glob(os.path.join(ws._platform_projects_dir(), "*", "*", "subagents", "*.meta.json")))
flagged, found, terminal = [], 0, 0
for meta in metas:
    try:
        d = json.load(open(meta))
    except Exception:
        continue
    if not isinstance(d, dict) or not d.get("stoppedByUser"):
        continue
    aid = os.path.basename(meta)[len("agent-"): -len(".meta.json")]
    sid = os.path.basename(os.path.dirname(os.path.dirname(meta)))
    # The shipped reader, asked exactly what a registration would give it.
    got = ws.platform_agent_record({"agent_id": aid, "session_id": sid})
    ok = bool(got and got.get("stoppedByUser"))
    found += 1 if ok else 0
    tr = meta[: -len(".meta.json")] + ".jsonl"
    last = last_transcript_row(tr) if os.path.exists(tr) else 0.0
    term = bool(last and stops.get(aid, 0.0) >= last - 2.0)
    terminal += 1 if term else 0
    flagged.append((d.get("name") or aid, aid, ok, term))

for name, aid, ok, term in flagged:
    print("%-20s %-18s reader_found=%-5s terminal_SubagentStop=%s" % (name, aid, ok, term))
print()
print("per-agent records on this machine:            %d" % len(metas))
print("runs the platform flagged stoppedByUser:      %d" % len(flagged))
print("  of those, found by the shipped reader:      %d" % found)
print("  of those, with a terminal SubagentStop:     %d" % terminal)
print()
print("Point 11's fourth ending needs a signal for %d runs that the hook stream" % (len(flagged) - terminal))
print("never carried. The platform's own record carries all %d." % len(flagged))
sys.exit(0 if found == len(flagged) else 1)
