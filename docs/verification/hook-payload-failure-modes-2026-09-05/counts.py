#!/usr/bin/env python3
import json, os
S = os.path.dirname(os.path.abspath(__file__))
L = lambda n: json.load(open(os.path.join(S, n)))
sw2 = {r["hook"]: r for r in L("sweep2-results.json")}
sw3 = {r["hook"]: r for r in L("sweep3-results.json")}
sw6 = {r["hook"]: r for r in L("sweep6-stop.json")}
meta = [(r["event"], r["hook"]) for r in L("sweep2-results.json")]

spoke = lambda r: bool(r["out"].strip() or r["err"].strip())

silent_pre, silent_stop, lost = [], [], []
for ev, h in meta:
    if ev == "Stop":
        c = sw6[h]["cases"]
        deg = [c["empty"], c["truncated"], c["nonjson"]]
        ctrl = c["control"]
    else:
        v = sw3.get(h)
        c = v["cases"] if v else sw2[h]["cases"]
        k = "violation" if v else "control"
        deg = [c["empty"], c["truncated"], c["nonjson"]]
        ctrl = c[k]
    if all(d["rc"] == 0 and not spoke(d) for d in deg):
        (silent_pre if ev == "PreToolUse" else silent_stop).append(h)
    if (ctrl["rc"] == 2 or spoke(ctrl)) and all(d["rc"] == 0 and not spoke(d) for d in deg):
        lost.append((ev, h))

print("PreToolUse guards that exit 0 with NOTHING on either stream, all 3 degraded:", len(silent_pre))
for h in silent_pre:
    print("   ", h)
print("Stop hooks, same:", len(silent_stop))
for h in silent_stop:
    print("   ", h)
print("\nhooks where a control finding is present and every degraded run is silent:", len(lost))
for ev, h in lost:
    print("   ", ev, h)
