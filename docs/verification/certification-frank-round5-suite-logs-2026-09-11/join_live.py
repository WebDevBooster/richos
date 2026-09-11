#!/usr/bin/env python3
"""The prepared-row join on the LIVE ledger, read-only: for every id-less
`prepared` row, what does _join_prepared_rows do, and why."""
import importlib.util as ilu, os, collections
ENG = "/Users/alex/ab/richos-wt/sage-fable-cert5/engine/scripts/lib"
spec = ilu.spec_from_file_location("wl", os.path.join(ENG, "worktree-ledger.py"))
wl = ilu.module_from_spec(spec); spec.loader.exec_module(wl)
records = wl.read_all(os.path.expanduser("~/.claude/state/worktree-ledger.jsonl"))

idless = [r for r in records if r.get("event") == "prepared" and not (r.get("agent_id") or "").strip()]
print("id-less prepared rows:", len(idless))
by_path = collections.defaultdict(list)
for r in records:
    if r.get("event") in wl.OWNERSHIP_EVENTS:
        by_path[wl.norm_path(r.get("worktree"))].append(r)
outcome = collections.Counter()
examples = collections.defaultdict(list)
for r in idless:
    regs = by_path[wl.norm_path(r.get("worktree"))]
    joined = [j for j in wl._join_prepared_rows(regs) if j.get("joined_from") == "prepared" and j.get("ts") == r.get("ts")]
    if joined:
        outcome["joined"] += 1
        # sanity: the id joined must be the one detect-nonnative registered for the same session+teammate
        continue
    # why not?
    if not wl.row_may_bind_by_name(r):
        outcome["not-engine-writer:" + (r.get("source") or "-")] += 1
        examples["not-engine-writer"].append((r.get("teammate"), r.get("worktree")))
        continue
    cands = [x for x in regs if x.get("event") == "registered" and (x.get("agent_id") or "").strip()
             and (x.get("session_id") or "") == (r.get("session_id") or "") and (x.get("teammate") or "") == (r.get("teammate") or "")]
    ids = {x.get("agent_id") for x in cands}
    if not cands:
        # is there a registered row for the same path with a different session or teammate?
        other = [x for x in regs if x.get("event") == "registered" and (x.get("agent_id") or "").strip()]
        key = "no-candidate(other-registered=%d)" % len(other)
        outcome[key] += 1
        if other:
            examples[key].append((r.get("teammate"), r.get("session_id","")[:8], [(x.get("teammate"), (x.get("session_id") or "")[:8], x.get("source")) for x in other][:3], r.get("worktree")))
    elif len(ids) > 1:
        outcome["ambiguous"] += 1
        examples["ambiguous"].append((r.get("teammate"), r.get("worktree"), sorted(ids)))
    else:
        outcome["unexpected"] += 1
print(outcome)
for k, v in examples.items():
    print("--", k)
    for e in v[:8]:
        print("   ", e)
# same-name, same-session, same-path pairs with TWO different agent ids anywhere?
pairs = collections.defaultdict(set)
for r in records:
    if r.get("event") == "registered" and (r.get("agent_id") or "").strip():
        pairs[(r.get("session_id"), r.get("teammate"), wl.norm_path(r.get("worktree")))].add(r["agent_id"].strip())
multi = {k: v for k, v in pairs.items() if len(v) > 1}
print("registered (session,teammate,path) keys with >1 agent id:", len(multi))
for k, v in list(multi.items())[:10]:
    print("  ", k[1], k[0][:8] if k[0] else None, k[2], sorted(v))
