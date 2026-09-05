#!/usr/bin/env python3
"""Final table. PreToolUse half from sweep2/3/4; Stop half from sweep6 (the
corrected run) plus sweep4/5 traces."""
import json, os

S = os.path.dirname(os.path.abspath(__file__))
L = lambda n: json.load(open(os.path.join(S, n)))

sw2 = {r["hook"]: r for r in L("sweep2-results.json")}
sw3 = {r["hook"]: r for r in L("sweep3-results.json")}
sw6 = {r["hook"]: r for r in L("sweep6-stop.json")}
tr4 = {r["hook"]: r for r in L("sweep4-trace.json")}
tr5 = {r["hook"]: r for r in L("sweep5-stop.json")}

meta = [(r["event"], r["hook"], r["matcher"]) for r in L("sweep2-results.json")]


def spoke(r):
    return bool(r["out"].strip() or r["err"].strip())


def cell(r):
    if r["rc"] == 2:
        return "**refuses**"
    return "passes, speaks" if spoke(r) else "passes, silent"


rows = []
for event, hook, matcher in meta:
    if event == "Stop":
        src = sw6[hook]["cases"]
        ctrl = src["control"]
        deg = [src["empty"], src["truncated"], src["nonjson"]]
    else:
        v = sw3.get(hook)
        if v:
            ctrl = v["cases"]["violation"]
            deg = [v["cases"]["empty"], v["cases"]["truncated"], v["cases"]["nonjson"]]
        else:
            c = sw2[hook]["cases"]
            ctrl = c["control"]
            deg = [c["empty"], c["truncated"], c["nonjson"]]

    t = tr4.get(hook) or tr5.get(hook)
    steps = None
    if t:
        c = t["cases"]
        key = "violation"
        steps = (c[key]["steps"], c["empty"]["steps"], c["truncated"]["steps"],
                 c["nonjson"]["steps"])

    same = all(d["rc"] == ctrl["rc"] and spoke(d) == spoke(ctrl) for d in deg)
    if all(d["rc"] == 2 for d in deg):
        verdict = "FAILS CLOSED"
    elif ctrl["rc"] == 2 and all(d["rc"] == 0 for d in deg):
        verdict = "FAILS OPEN (proven)"
    elif spoke(ctrl) and not any(spoke(d) for d in deg):
        verdict = "FAILS OPEN (check lost)"
    elif same and not spoke(ctrl):
        if steps and steps[1] < steps[0] * 0.85:
            verdict = "FAILS OPEN (predicate not evaluated)"
        else:
            verdict = "INDETERMINATE"
    elif same:
        verdict = "payload-independent"
    elif steps and steps[1] < steps[0] * 0.85:
        verdict = "FAILS OPEN (predicate not evaluated)"
    else:
        verdict = "INDETERMINATE"

    rows.append((event, hook, matcher, cell(deg[0]), cell(deg[1]), cell(deg[2]),
                 verdict, cell(ctrl), steps))

print("| Event | Hook | Matcher | control | empty | truncated | non-JSON | Verdict | Trace steps |")
print("|---|---|---|---|---|---|---|---|---|")
for ev, h, m, e, t_, n, v, c, st in rows:
    print("| %s | `%s` | `%s` | %s | %s | %s | %s | **%s** | %s |" % (
        ev, h, m.replace("|", "\\|"), c, e, t_, n, v,
        "%d / %d / %d / %d" % st if st else "-"))

print()
from collections import Counter
for k, n in Counter(r[6] for r in rows).most_common():
    print("%-40s %d" % (k, n))
print()
for ev in ("PreToolUse", "Stop"):
    print(ev)
    for k, n in Counter(r[6] for r in rows if r[0] == ev).most_common():
        print("   %-38s %d" % (k, n))
