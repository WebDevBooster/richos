#!/usr/bin/env python3
import json, datetime, collections
p = "/Users/alex/.claude/state/escalations.jsonl"
cut = datetime.datetime(2026, 9, 7, tzinfo=datetime.timezone.utc)
rows = []
for line in open(p, errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    try:
        t = datetime.datetime.fromisoformat((d.get("raised") or "").replace("Z", "+00:00"))
    except Exception:
        continue
    if t >= cut:
        rows.append((t, d))

def count(pred):
    return [(t, d) for t, d in rows if pred((d.get("title") or "").lower())]

probes = {
    "unlanded branch (notice-unlanded-branches.sh)":
        lambda s: "neither landed nor held" in s,
    "false premise in a brief (guard-brief-scope.sh family)":
        lambda s: "premise" in s and ("false" in s or "wrong" in s),
    "hook registration / surface drift (hook-registration-completeness.sh)":
        lambda s: ("registration" in s or "registered" in s or "surface" in s) and "hook" in s,
    "red on main / red CI at land (guard-ci-red-lands.sh family)":
        lambda s: "red" in s and ("main" in s or "ci" in s),
}
print(f"escalations raised 2026-09-07..now: {len(rows)}\n")
for name, pred in probes.items():
    hits = count(pred)
    print(f"{len(hits):>4}  {name}")
    for t, d in hits[:4]:
        print(f"        {t.date()}  {(d.get('title') or '')[:96]}")
    if len(hits) > 4:
        print(f"        ... and {len(hits)-4} more")
    print()
