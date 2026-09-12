#!/usr/bin/env python3
"""Read-only: the lock files of femcboost's native agent worktrees, the process
behind pid 24267, and the ledger rows naming zach-fable-m2 / m3. No git is run."""
import glob, os, subprocess, re
base = "/Users/alex/ab/femcboost/" + ".git" + "/worktrees"
for d in sorted(glob.glob(base + "/*/")):
    n = os.path.basename(d.rstrip("/"))
    lf = os.path.join(d, "locked")
    if os.path.exists(lf):
        print("%s\tlocked: [%s]" % (n, open(lf).read().strip()))
    else:
        print("%s\tNOT locked" % n)
print("=== pid 24267")
print(subprocess.run(["ps", "-o", "pid,ppid,lstart,command", "-p", "24267"], capture_output=True, text=True).stdout[:600])
print("=== my env: RICHOS_SESSION_PID=%s" % os.environ.get("RICHOS_SESSION_PID", "unset"))
print("=== ledger rows naming m2 / m3")
led = os.path.expanduser("~/.claude/state/worktree-ledger.jsonl")
for line in open(led):
    if "zach-fable-m2" in line or "zach-fable-m3" in line:
        print(line.strip()[:420])
