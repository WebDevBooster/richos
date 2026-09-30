#!/usr/bin/env python3
"""The claim matcher in unstarted-rows.py, on its own (hunt part 5, P5-20).

A branch that writes a child row's ID with dashes (`row-3-1` for row 3.1) must
claim the child and NOT its parent; a branch that merely continues the parent's
name with words (`row-3-fix`) still claims the parent. Run directly:
    python3 scripts/lib/unstarted-rows-claim.test.py
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("unstarted_rows", os.path.join(HERE, "unstarted-rows.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

CASES = [
    # (row id, branch/directory text, claims?)
    ("3.1", "cc/worker-row-3-1", True),
    ("3", "cc/worker-row-3-1", False),          # the defect: the child's dashed ID claimed its parent
    ("3", "cc/worker-row-3_1", False),
    ("3.1", "cc/worker-row-3.1", True),
    ("3", "cc/worker-row-3.1", False),
    ("3", "cc/worker-row-3-fix", True),         # words after the ID still claim the row itself
    ("3", "cc/worker-row-3", True),
    ("3", "cc/worker-row-3-1-fix", False),
    ("1", "cc/worker-row-11", False),           # the prefix case the docstring already names
    ("11", "cc/worker-row-11", True),
]

failed = 0
for rid, hay, want in CASES:
    got = bool(mod.claim_pattern(rid).search(hay))
    status = "PASS" if got == want else "FAIL"
    if got != want:
        failed += 1
    print("  %s  row %s vs %r -> claims=%s (want %s)" % (status, rid, hay, got, want))

print("=== unstarted-rows-claim: %s ===" % ("%d FAILED" % failed if failed else "all %d passed" % len(CASES)))
sys.exit(1 if failed else 0)
