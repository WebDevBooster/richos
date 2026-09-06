#!/usr/bin/env python3
"""Deterministic conversation filler for the Q1 compaction cells.

The filler's only job is to grow the context until the binary's own autocompact
threshold fires. It must therefore be (a) large, (b) meaningless, and (c) free of
every sentinel token, so that a post-compaction answer can only have come from the
channel under test.

Deterministic: same --seed and --kb produce the same bytes, so a cell can be re-run.

Usage: make_filler.py --seed N --kb K --out FILE
"""
import argparse, random

WORDS = ("harbor lantern cordage tallow ballast gasket ratchet pumice thimble varnish "
         "trestle furrow kelson gudgeon spandrel quoin lintel purlin transom mullion "
         "cistern conduit flange grommet spigot bollard capstan windlass fairlead cleat").split()

ap = argparse.ArgumentParser()
ap.add_argument("--seed", type=int, required=True)
ap.add_argument("--kb", type=int, required=True)
ap.add_argument("--out", required=True)
a = ap.parse_args()

rng = random.Random(a.seed)
lines = ["Here is a batch of inventory notes. Read them and reply with the single word ok.", ""]
n = 0
target = a.kb * 1024
while n < target:
    line = "%04d: " % len(lines) + " ".join(rng.choice(WORDS) for _ in range(14))
    lines.append(line)
    n += len(line) + 1
text = "\n".join(lines) + "\n"
open(a.out, "w").write(text)
print("wrote %s: %d bytes, %d lines" % (a.out, len(text), len(lines)))
