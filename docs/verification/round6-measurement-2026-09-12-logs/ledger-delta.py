#!/usr/bin/env python3
"""The after-census's honest form for the ledger: every row the live ledger has
that the pre-round copy did not, attributed to the hook that wrote it. Read-only.
Usage: ledger-delta.py <before-copy> <live-ledger>"""
import collections
import json
import sys

before = open(sys.argv[1], encoding="utf-8").read().splitlines()
after = open(sys.argv[2], encoding="utf-8").read().splitlines()
print("before: %d lines   after: %d lines" % (len(before), len(after)))
if after[:len(before)] != before:
    print("NOT APPEND-ONLY: the first %d lines of the live ledger differ from the copy" % len(before))
    sys.exit(1)
added = after[len(before):]
print("appended: %d rows; the copy is a prefix of the live file (append-only)" % len(added))
src = collections.Counter()
ev = collections.Counter()
mine = 0
for line in added:
    try:
        d = json.loads(line)
    except ValueError:
        src["<unparseable>"] += 1
        continue
    src[d.get("source", "?")] += 1
    ev[d.get("event", "?")] += 1
    if "zach-fable-m1" in line:
        mine += 1
print("by source: %s" % dict(src))
print("by event:  %s" % dict(ev))
print("rows naming zach-fable-m1 (this agent's own SubagentStop hooks, written by the running engine, not by any command of this round): %d" % mine)
