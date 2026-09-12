#!/usr/bin/env python3
"""Read-only measurements of the RUNNING engine's state (main @ dcabcbd9), for
the record extension. Nothing here writes. Every git call is read-only and runs
against a worktree of the same repository (refs are shared)."""
import collections
import json
import os
import subprocess
import sys

HOME = os.path.expanduser("~")
LEDGER = os.path.join(HOME, ".claude/state/worktree-ledger.jsonl")
EVENTS = os.path.join(HOME, ".claude/state/workspaces/events.jsonl")
RETIRE = os.path.join(HOME, ".claude/state/workspace-retirement/retirements.jsonl")
RICHOS_WT = "/Users/alex/ab/richos-wt/zach-fable-m1"
FEMC_WT = "/Users/alex/ab/femcboost/.claude/worktrees/agent-a8350de8d312d2b0d"
TODAY = "2026-09-12"


def git(repo, *a):
    r = subprocess.run(["git", "-C", repo] + list(a), capture_output=True, text=True)
    return r.returncode, r.stdout.strip()


def rows(path):
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except ValueError:
                out.append({"_unparseable": line[:80]})
    return out


print("== 1. the four fixture rows in the operator's live events.jsonl (spec store) ==")
ev = rows(EVENTS)
print("events.jsonl rows: %d" % len(ev))
for r in ev:
    if r.get("event") == "integration-recorded":
        print("  %s repo=%s exists=%s why=%r work=%s" % (
            r.get("ts"), r.get("repo"), os.path.exists(r.get("repo") or "/nonexistent"), r.get("why"), r.get("work")))
print("integration.json present: %s" % os.path.exists(os.path.join(HOME, ".claude/state/workspaces/integration.json")))

print()
print("== 2. today's ledger rows by event type (running engine's worktree-ledger.jsonl) ==")
led = rows(LEDGER)
today = [r for r in led if str(r.get("ts", "")).startswith(TODAY)]
hist = collections.Counter(r.get("event") for r in today)
print("rows today: %d" % len(today))
for k, v in sorted(hist.items(), key=lambda kv: -kv[1]):
    print("  %-14s %d" % (k, v))
print("every distinct event type in the whole ledger: %s" % sorted(set(str(r.get("event")) for r in led)))

print()
print("== 3. cc/ branches prepared today, and whether each still exists (no deletion event anywhere) ==")
prepared = [r for r in today if r.get("event") == "prepared" and str(r.get("branch", "")).startswith("cc/")]
print("prepared cc/ rows today: %d" % len(prepared))
gone = present = 0
for r in prepared:
    repo = r.get("repo")
    wt = RICHOS_WT if repo == "/Users/alex/ab/richos" else (FEMC_WT if repo == "/Users/alex/ab/femcboost" else repo)
    rc, _ = git(wt, "rev-parse", "--verify", "--quiet", "refs/heads/" + r["branch"])
    state = "present" if rc == 0 else "GONE"
    if rc == 0:
        present += 1
    else:
        gone += 1
    print("  %-28s %-28s %s" % (r.get("branch"), os.path.basename(repo or ""), state))
print("gone: %d  present: %d" % (gone, present))
del_like = [r for r in led if any(k in str(r.get("event", "")).lower() for k in ("delet", "remov", "retire", "discard", "landed", "reclaim"))]
print("ledger rows (all time) whose event type names a deletion/removal/retirement/discard/land: %d" % len(del_like))
names_gone = set(r["branch"] for r in prepared if git(RICHOS_WT if r.get("repo") == "/Users/alex/ab/richos" else FEMC_WT,
                                                       "rev-parse", "--verify", "--quiet", "refs/heads/" + r["branch"])[0] != 0)
mention = [r for r in led if any(n in json.dumps(r) for n in names_gone) and r.get("event") not in ("prepared", "registered", "finished")]
print("rows of any OTHER event type mentioning one of the gone branches: %d" % len(mention))

print()
print("== 4. today's finished rows: how many carry a branch, a teammate, distinct agent ids ==")
fin = [r for r in today if r.get("event") == "finished"]
print("finished rows today: %d" % len(fin))
print("  carrying a non-empty 'branch': %d" % sum(1 for r in fin if r.get("branch")))
print("  naming a teammate: %d" % sum(1 for r in fin if r.get("teammate")))
print("  distinct agent_id: %d" % len(set(r.get("agent_id") for r in fin)))
print("  signals: %s" % dict(collections.Counter(r.get("signal") for r in fin)))
print("  sources: %s" % dict(collections.Counter(r.get("source") for r in fin)))
reg = [r for r in today if r.get("event") == "registered"]
print("registered rows today: %d (distinct teammates %d)" % (len(reg), len(set(r.get("teammate") for r in reg))))
if reg:
    print("  a registered row: %s" % json.dumps(reg[0], sort_keys=True)[:400])
native_ids = {}
for r in reg:
    w = str(r.get("worktree", ""))
    if "/.claude/worktrees/agent-" in w:
        native_ids[w.rsplit("agent-", 1)[1]] = r.get("teammate")
fin_ids = set(r.get("agent_id") for r in fin)
matched = [t for aid, t in native_ids.items() if aid in fin_ids]
print("native workspaces registered today: %d; of those, whose agent id appears on ANY finished row: %d %s"
      % (len(native_ids), len(matched), sorted(matched)[:30]))
per_tm = collections.Counter(r.get("worktree") for r in fin)
print("  finished rows per native worktree path (top 5): %s" % per_tm.most_common(5))

print()
print("== 5. the two quarantines the removal path created ==")
rc, out = git(RICHOS_WT, "worktree", "list", "--porcelain")
q = [l for l in out.splitlines() if ".richos-retired" in l]
for l in q:
    print("  " + l)
if os.path.exists(RETIRE):
    hits = [l for l in open(RETIRE, encoding="utf-8") if "opus-c6" in l]
    print("retirements.jsonl rows naming *-opus-c6: %d" % len(hits))
    for l in hits[-4:]:
        d = json.loads(l)
        print("  %s %s %s %s %s" % (d.get("ts"), d.get("operation"), d.get("outcome"), d.get("reason_code"), d.get("path") or d.get("workspace") or ""))
for name in ("frank-opus-c6", "sage-opus-c6"):
    rc, out = git(RICHOS_WT, "rev-parse", "--verify", "--quiet", "refs/heads/cc/" + name)
    print("  branch cc/%s: %s" % (name, "present" if rc == 0 else "GONE"))
    rc2, out2 = git(FEMC_WT, "for-each-ref", "--format=%(refname:short)", "refs/heads/worktree-agent-*")
print("  femcboost worktree-agent-* branches now: %s" % (out2.split() if out2 else []))
