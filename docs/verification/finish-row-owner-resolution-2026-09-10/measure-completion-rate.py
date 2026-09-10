#!/usr/bin/env python3
"""measure-completion-rate.py — what share of finish rows names its assignment.

READ-ONLY. Answers one question against the real record: of the finish rows in
~/.claude/state/worktree-ledger.jsonl, how many are complete today, and how
many WOULD be complete under prefer-the-resolvable.

A row is completable when one of its two keys names an assignment registered
under the SAME session -- the exact condition resolve_assignment() applies. The
structural pass is checked against the shipped resolver on a random sample, so
this file cannot quietly drift away from the code it is describing.

    measure-completion-rate.py [engine-root]
"""
import importlib.util
import json
import os
import random
import sys

LEDGER = os.path.expanduser("~/.claude/state/worktree-ledger.jsonl")
TXROOT = os.path.expanduser("~/.claude/state/worktree-transactions")
ENGINE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "engine")


def load(path):
    out = []
    for line in open(path, errors="replace"):
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        if isinstance(d, dict):
            out.append(d)
    return out


rows = load(LEDGER)

# (session_id, agent_id) pairs an assignment has ever been registered under.
known = set()
for r in rows:
    if r.get("event") in ("registered", "prepared"):
        aid = (r.get("agent_id") or "").strip()
        if aid:
            known.add(((r.get("session_id") or ""), aid))
if os.path.isdir(TXROOT):
    for sid in os.listdir(TXROOT):
        d = os.path.join(TXROOT, sid)
        if os.path.isdir(d):
            for f in os.listdir(d):
                if f.endswith(".json"):
                    known.add((sid, f[:-5]))


def owner_of(row):
    base = os.path.basename((row.get("worktree") or "").rstrip("/"))
    return base[len("agent-"):] if base.startswith("agent-") else ""


def completable(row):
    sid = row.get("session_id") or ""
    aid = (row.get("agent_id") or "").strip()
    own = owner_of(row)
    return (bool(aid) and (sid, aid) in known) or (bool(own) and (sid, own) in known)


def report(label, sel):
    if not sel:
        print("%-46s (none)" % label)
        return
    now = sum(1 for r in sel if (r.get("teammate") or "").strip())
    after = sum(1 for r in sel if completable(r))
    print("%-46s %6d rows | complete today %5d (%5.2f%%) | after %5d (%5.1f%%)"
          % (label, len(sel), now, 100.0 * now / len(sel), after, 100.0 * after / len(sel)))


fin = [r for r in rows if r.get("event") == "finished"]
inwt = [r for r in fin if owner_of(r)]
report("every finish row ever written", fin)
report("  written inside an agent's own worktree", inwt)
report("  written elsewhere (lead session, tests)", [r for r in fin if not owner_of(r)])
for day in sorted({(r.get("ts") or "")[:10] for r in fin})[-3:]:
    sel = [r for r in fin if (r.get("ts") or "").startswith(day)]
    report("  rows written %s" % day, sel)
    report("    ... in an agent's own worktree", [r for r in sel if owner_of(r)])

# The structural pass, checked against the shipped resolver.
spec = importlib.util.spec_from_file_location(
    "wl", os.path.join(ENGINE, "scripts", "lib", "worktree-ledger.py"))
wl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wl)
random.seed(7)
sample = random.sample(fin, min(60, len(fin)))
agree = sum(1 for r in sample
            if bool(sum(map(bool, wl.resolve_assignment(r.get("session_id") or "",
                                                        r.get("agent_id") or "",
                                                        r.get("worktree") or "")[:2])))
            == completable(r))
print("\nshipped resolver agrees with the structural pass on %d of %d sampled rows"
      % (agree, len(sample)))
