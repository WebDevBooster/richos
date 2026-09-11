#!/usr/bin/env python3
"""Live D-A re-derivation, READ-ONLY. Judges sage-fable-cert3's tree on (a) the
operator's live ledger and (b) a COPY with the retracted row removed, with both
entities, write=False, per registration and aggregate. Also the other
helper-made trees on disk under richos-wt."""
import importlib.util as ilu, json, os, sys, tempfile, shutil

ENG = "/Users/alex/ab/richos-wt/sage-fable-cert5/engine/scripts/lib"
def load(name, fn):
    spec = ilu.spec_from_file_location(name, os.path.join(ENG, fn))
    m = ilu.module_from_spec(spec); spec.loader.exec_module(m); return m
wl = load("wl", "worktree-ledger.py")
live = load("live", "agent-liveness.py")

LEDGER = os.path.expanduser("~/.claude/state/worktree-ledger.jsonl")
paths = sys.argv[1:] or ["/Users/alex/ab/richos-wt/sage-fable-cert3"]

def run(records, label):
    print("=== %s (%d rows) ===" % (label, len(records)))
    for path in paths:
        regs = wl.registrations(records, worktree=path)
        print("-- %s: %d raw registrations" % (path, len(regs)))
        for reg in wl._join_prepared_rows(regs):
            for entity in ("/Users/alex/ab/richos", "/Users/alex/ab/femcboost"):
                v, why = wl._judge_registration(reg, entity, records, live, False, None)
                print("   reg %-10s aid=%-18s joined=%-8s entity=%-9s -> %s: %s" % (
                    reg.get("event"), reg.get("agent_id"), reg.get("joined_from") or "-",
                    os.path.basename(entity), v, why[:150]))
        for entity in ("/Users/alex/ab/richos", "/Users/alex/ab/femcboost"):
            agg = wl.judge(entity, path, [], records, mod=live, write=False, ledger=None)
            print("   AGGREGATE entity=%-9s -> %s: %s" % (os.path.basename(entity), agg["verdict"], agg["reason"][:200]))
        print("   lock entities per aid:")
        for reg in wl._join_prepared_rows(regs):
            if reg.get("agent_id"):
                print("     %s -> %s" % (reg.get("agent_id"), wl._lock_entities(reg, records, "/Users/alex/ab/richos")))

records = wl.read_all(LEDGER)
run(records, "LIVE ledger, as is (retraction present)")
copy = [r for r in records if r.get("event") != "retracted"]
run(copy, "COPY with the retracted row removed (round-14 row stands again)")
copy2 = [r for r in records if not (r.get("event") in ("retracted",) or r.get("witness") == "platform-terminal-record")]
run(copy2, "COPY with both the round-14 row and its retraction removed")
