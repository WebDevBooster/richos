#!/usr/bin/env python3
"""READ-ONLY judge of live trees at this tip: write=False on every call, no ledger path passed for writing.
usage: live-judge.py <engine-scripts-dir> <worktree-path>..."""
import importlib.util, os, sys
scripts = sys.argv[1]
spec = importlib.util.spec_from_file_location("wl", os.path.join(scripts, "lib", "worktree-ledger.py"))
wl = importlib.util.module_from_spec(spec); spec.loader.exec_module(wl)
mod = wl._liveness_module()
records = wl.read_all()
print("ledger rows:", len(records), " liveness module:", "loaded" if mod else "MISSING")
for path in sys.argv[2:]:
    print("=" * 100)
    print(path)
    regs = wl.registrations(records, worktree=path)
    joined = wl._join_prepared_rows(regs)
    for entity in ("/Users/alex/ab/richos", "/Users/alex/ab/femcboost"):
        print("-- entity", entity)
        for reg in joined:
            v, why = wl._judge_registration(reg, entity, records, mod, False, None)
            print("   reg %-10s aid=%-18s joined=%-8s -> %-13s %s" % (reg.get("event"), reg.get("agent_id") or "None",
                  reg.get("joined_from") or "-", v, why[:230]))
            if reg.get("agent_id"):
                print("      lock entities:", wl._lock_entities(reg, records, entity))
        agg = wl.judge(entity, path, [], records, mod=mod, write=False)
        print("   AGGREGATE %-13s agent_ids=%s :: %s" % (agg["verdict"], agg["agent_ids"], agg["reason"][:300]))
    for aid in sorted({(r.get("agent_id") or "") for r in joined if r.get("agent_id")}):
        for ent in ("/Users/alex/ab/femcboost", "/Users/alex/ab/richos"):
            rec = mod.resolve(ent, aid)
            print("   agent-liveness.resolve(%s, %s) -> %s :: %s" % (os.path.basename(ent), aid, rec.get("verdict"), (rec.get("reason") or "")[:160]))
        print("   standing terminations:", [(t.get("ts"), t.get("witness")) for t in wl.terminations(records, aid)])
        print("   retractions:", wl.retractions(records, aid))
        print("   platform_terminal_record:", wl.platform_terminal_record(dict(joined[0], agent_id=aid)))
