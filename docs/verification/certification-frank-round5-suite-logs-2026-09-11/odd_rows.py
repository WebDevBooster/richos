#!/usr/bin/env python3
import importlib.util as ilu, os, collections
ENG = "/Users/alex/ab/richos-wt/sage-fable-cert5/engine/scripts/lib"
spec = ilu.spec_from_file_location("wl", os.path.join(ENG, "worktree-ledger.py")); wl = ilu.module_from_spec(spec); spec.loader.exec_module(wl)
records = wl.read_all(os.path.expanduser("~/.claude/state/worktree-ledger.jsonl"))
by_path = collections.defaultdict(list)
for r in records:
    if r.get("event") in wl.OWNERSHIP_EVENTS:
        by_path[wl.norm_path(r.get("worktree"))].append(r)
for r in records:
    if r.get("event") != "prepared" or (r.get("agent_id") or "").strip():
        continue
    regs = by_path[wl.norm_path(r.get("worktree"))]
    joined = [j for j in wl._join_prepared_rows(regs) if j.get("joined_from") == "prepared" and j.get("ts") == r.get("ts")]
    if joined:
        continue
    cands = [x for x in regs if x.get("event") == "registered" and (x.get("agent_id") or "").strip()
             and (x.get("session_id") or "") == (r.get("session_id") or "") and (x.get("teammate") or "") == (r.get("teammate") or "")]
    if cands:
        print("PREPARED", {k: r.get(k) for k in ("teammate", "session_id", "source", "ts", "worktree")})
        for c in cands:
            print("   REGISTERED", {k: c.get(k) for k in ("teammate", "agent_id", "session_id", "source", "ts", "class", "repo")})
# and: does any joined prepared row's id differ from what detect-nonnative registered? (by construction no) -- print count of joined with >1 registered candidate ids
amb = 0
for r in records:
    if r.get("event") != "prepared" or (r.get("agent_id") or "").strip():
        continue
    regs = by_path[wl.norm_path(r.get("worktree"))]
    ids = {x.get("agent_id") for x in regs if x.get("event") == "registered" and (x.get("agent_id") or "").strip()}
    if len(ids) > 1:
        amb += 1
        print("PATH WITH >1 REGISTERED IDS", r.get("worktree"), sorted(ids), [(x.get("teammate"), (x.get("session_id") or "")[:8]) for x in regs if x.get("event") == "registered"])
print("paths with an id-less prepared row and >1 registered ids:", amb)
