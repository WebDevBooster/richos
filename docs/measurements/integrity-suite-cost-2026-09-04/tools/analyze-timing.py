#!/usr/bin/env python3
"""Turn a CI_TEST_TIMING log into a ranked account of where the wall clock went.

Input records are TSV: <kind> <start> <end-or-dash> <label>.
  run                START / END
  sandbox[.phase]    a make_sandbox build and its four phases
  case               the instant emit_case printed a verdict

A case's SEGMENT is the interval between the previous stamp and its own. Any
sandbox whose build ENDED inside that segment is attributed to it, and the rest
of the segment is the case body. That is the split the whole exercise turns on:
setup versus checks.
"""
import sys
from collections import defaultdict

path = sys.argv[1]
top_n = int(sys.argv[2]) if len(sys.argv) > 2 else 30

runs = []
sandboxes = []          # (start, end)
phases = defaultdict(float)
cases = []              # (t, name)

for line in open(path, encoding="utf-8"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) != 4:
        continue
    kind, a, b, label = parts
    if kind == "run":
        runs.append((float(a), label))
    elif kind == "sandbox":
        sandboxes.append((float(a), float(b)))
    elif kind.startswith("sandbox."):
        phases[kind] += float(b) - float(a)
    elif kind == "case":
        cases.append((float(a), label))

t_start = runs[0][0] if runs else (cases[0][0] if cases else 0.0)
t_end = None
for t, label in runs:
    if label == "END":
        t_end = t
if t_end is None:
    t_end = cases[-1][0] if cases else t_start
total = t_end - t_start

sandbox_total = sum(e - s for s, e in sandboxes)

# Attribute each sandbox build to the segment it finished in.
segs = []
prev = t_start
for t, name in cases:
    segs.append([prev, t, name])
    prev = t
tail = t_end - prev

sb_in_seg = defaultdict(float)
for s, e in sandboxes:
    for i, (a, b, _n) in enumerate(segs):
        if a <= e <= b:
            sb_in_seg[i] += e - s
            break

rows = []
for i, (a, b, name) in enumerate(segs):
    seg = b - a
    sb = sb_in_seg.get(i, 0.0)
    rows.append((name, seg, sb, seg - sb))

print("=" * 78)
print("WHERE THE WALL CLOCK GOES — %s" % path)
print("=" * 78)
print("total wall clock          %8.1f s  (%.1f min)" % (total, total / 60.0))
print("cases emitted             %8d" % len(cases))
print("sandboxes built           %8d" % len(sandboxes))
print("")
print("--- SETUP vs CHECKS ------------------------------------------------------")
print("make_sandbox, all builds  %8.1f s  %5.1f%% of the run" % (sandbox_total, 100.0 * sandbox_total / total if total else 0))
for k in sorted(phases, key=lambda k: -phases[k]):
    print("    %-22s%8.1f s  %5.1f%%" % (k, phases[k], 100.0 * phases[k] / total if total else 0))
body = total - sandbox_total
print("everything else           %8.1f s  %5.1f%% of the run" % (body, 100.0 * body / total if total else 0))
print("    (of which unattributed tail after the last case: %.1f s)" % tail)
print("")
print("--- THE %d MOST EXPENSIVE CASE SEGMENTS ----------------------------------" % top_n)
print("%-62s %8s %8s %8s" % ("case", "segment", "sandbox", "body"))
for name, seg, sb, bd in sorted(rows, key=lambda r: -r[1])[:top_n]:
    print("%-62s %7.1fs %7.1fs %7.1fs" % (name[:62], seg, sb, bd))
print("")
cum = 0.0
ranked = sorted(rows, key=lambda r: -r[1])
for n in (5, 10, 20, 30):
    cum = sum(r[1] for r in ranked[:n])
    print("top %2d case segments account for %7.1f s = %5.1f%% of the run" % (n, cum, 100.0 * cum / total if total else 0))
print("")
print("--- EVERY CASE, IN RUN ORDER --------------------------------------------")
print("%-62s %8s %8s %8s" % ("case", "segment", "sandbox", "body"))
for name, seg, sb, bd in rows:
    print("%-62s %7.1fs %7.1fs %7.1fs" % (name[:62], seg, sb, bd))
