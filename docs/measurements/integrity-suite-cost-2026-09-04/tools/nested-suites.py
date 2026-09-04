#!/usr/bin/env python3
"""Rank the NESTED suites the harness invokes as single cases.

Each of these is one `emit_case` line in contract-integrity.test.sh and a whole
other test suite underneath it. The segment time of that case IS the nested
suite's cost, because no sandbox is built for it.
"""
import re
import sys
from collections import defaultdict

path = sys.argv[1]
cases = []
runs = []
for line in open(path, encoding="utf-8"):
    p = line.rstrip("\n").split("\t")
    if len(p) != 4:
        continue
    if p[0] == "case":
        cases.append((float(p[1]), p[3]))
    elif p[0] == "run":
        runs.append((float(p[1]), p[3]))

t0 = runs[0][0]
t_end = [t for t, l in runs if l == "END"]
total = (t_end[0] if t_end else cases[-1][0]) - t0

segs = []
prev = t0
for t, name in cases:
    segs.append((name, t - prev))
    prev = t

NESTED = re.compile(
    r"(mutations-all-load-bearing|suite-passes|gate-suite-passes|"
    r"reconciler-suite-passes|scope-and-safety-suite-passes)$")

rows = [(n, d) for n, d in segs if NESTED.search(n)]
rows.sort(key=lambda r: -r[1])

print("NESTED SUITES INVOKED AS A SINGLE CASE")
print("total run: %.1f s (%.1f min)" % (total, total / 60.0))
print("")
print("%-58s %9s %7s" % ("case", "seconds", "% run"))
sub = 0.0
for n, d in rows:
    sub += d
    print("%-58s %8.1f %6.1f%%" % (n[:58], d, 100.0 * d / total))
print("%-58s %8.1f %6.1f%%" % ("--- these cases together ---", sub, 100.0 * sub / total))
print("")
other = total - sub
print("%-58s %8.1f %6.1f%%" % ("everything else (all other cases + setup)", other, 100.0 * other / total))
