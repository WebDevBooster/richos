#!/usr/bin/env python3
"""Read-only: fixture rows on the operator's real record, by the shapes CI's canary named."""
import json, os, re, collections
home = os.path.expanduser("~")
L = os.path.join(home, ".claude/state/worktree-ledger.jsonl")
R = os.path.join(home, ".claude/state/workspace-retirement/retirements.jsonl")
tmp = re.compile(r"/(private/)?var/folders/|/tmp/|/T/")
rows = []
for line in open(L, encoding="utf-8", errors="replace"):
    try:
        d = json.loads(line)
    except Exception:
        continue
    rows.append(d)
def is_fixture(d):
    if d.get("event") == "finished":
        return False
    aid = d.get("agent_id") or ""
    if re.fullmatch(r"a(\d)\1{15}", aid):          # a2222222222222222-shaped
        return True
    for k in ("repo", "worktree", "cwd"):
        v = d.get(k) or ""
        if v and tmp.search(v):
            return True
    return False
fx = [d for d in rows if is_fixture(d)]
print("ledger rows (non-finished):", sum(1 for d in rows if d.get("event") != "finished"), " fixture-shaped:", len(fx))
by = collections.Counter((d.get("event"), d.get("source") or d.get("witness") or "-", d.get("teammate") or d.get("agent_id") or "-") for d in fx)
for k, n in by.most_common(20):
    print("  %5d  %s" % (n, k))
ts = sorted(d.get("ts") or "" for d in fx)
print("first:", ts[0] if ts else None, " last:", ts[-1] if ts else None)
today = [d for d in fx if (d.get("ts") or "").startswith("2026-09-11")]
print("written on 2026-09-11:", len(today))
for d in today[-6:]:
    print("   ", d.get("ts"), d.get("event"), d.get("source") or d.get("witness"), d.get("teammate") or d.get("agent_id"), (d.get("repo") or d.get("worktree") or "")[:70])
print("terminated fixture rows:", [(d.get("ts"), d.get("agent_id"), d.get("witness")) for d in fx if d.get("event") == "terminated"][:10])
print("--- retirement journal:", R, os.path.exists(R))
if os.path.exists(R):
    n = 0; f = 0
    for line in open(R, encoding="utf-8", errors="replace"):
        n += 1
        if "a2222222222222222" in line or "a3333333333333333" in line or tmp.search(line):
            f += 1
    print("retirement rows:", n, " fixture-shaped:", f)
