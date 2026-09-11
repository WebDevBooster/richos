#!/usr/bin/env python3
"""Read-only: the ownership and termination rows for the round-four/five trees."""
import json, os, sys
L = os.path.expanduser("~/.claude/state/worktree-ledger.jsonl")
names = sys.argv[1:] or ["sage-fable-cert3", "frank-fable-cert5", "sage-fable-cert5", "zach-fable-fix4", "frank-fable-cert4", "sage-fable-cert4"]
rows = []
for line in open(L, encoding="utf-8", errors="replace"):
    try:
        d = json.loads(line)
    except Exception:
        continue
    if d.get("event") == "finished":
        continue
    if d.get("teammate") in names or any(n in (d.get("worktree") or "") for n in names):
        rows.append(d)
for d in rows:
    print("%s  %-10s %-18s %-8s %-18s cls=%-7s src=%-30s repo=%s wt=%s%s" % (
        (d.get("ts") or "")[:19], d.get("event"), d.get("agent_id") or "-", (d.get("session_id") or "")[:8],
        d.get("teammate") or "-", d.get("class") or "-", d.get("source") or "-", d.get("repo") or "-",
        d.get("worktree") or "-", (" witness=" + d["witness"]) if d.get("witness") else ("" if d.get("event") != "retracted" else " retracts=" + d.get("retracts_ts", ""))))
