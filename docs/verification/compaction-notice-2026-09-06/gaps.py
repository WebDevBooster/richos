#!/usr/bin/env python3
"""Print the arrival timeline of a timed cell, with the delta from the previous event.

Reads `<cell>.jsonl.timed.jsonl` (metadata only, written by `drive_compact.py`) and prints one
line per event. The point of interest is where a delta of tens of seconds sits, and which
frame is on each side of it.

Usage: gaps.py raw/cellT1.jsonl.timed.jsonl [...]
"""
import json, sys

for path in sys.argv[1:]:
    print("=== %s" % path)
    prev = None
    events = [json.loads(l) for l in open(path) if l.strip()]
    for e in events:
        d = e["atMs"] - prev["atMs"] if prev else 0
        label = e.get("note") or "/".join(x for x in (e.get("type"), e.get("subtype"), e.get("event")) if x)
        extra = ""
        if e.get("compact_metadata"):
            extra = "   " + json.dumps(e["compact_metadata"])
        print("%9dms  +%8dms  %-6s %-46s %6dB%s"
              % (e["atMs"], d, e["kind"], label, e.get("bytes", 0), extra))
        prev = e
    # The largest silences, and what ended each one.
    print("--- the five longest silences in this cell")
    gaps = []
    for i in range(1, len(events)):
        gaps.append((events[i]["atMs"] - events[i - 1]["atMs"], i))
    for g, i in sorted(gaps, reverse=True)[:5]:
        a, b = events[i - 1], events[i]
        name = lambda e: (e.get("note") or "/".join(x for x in (e.get("type"), e.get("subtype"), e.get("event")) if x))
        print("  %8dms of silence: %s (t=%d) -> %s (t=%d)" % (g, name(a), a["atMs"], name(b), b["atMs"]))
    print()
