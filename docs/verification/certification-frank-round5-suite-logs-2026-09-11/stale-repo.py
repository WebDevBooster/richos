#!/usr/bin/env python3
"""What does the judge do when a native row's `repo` no longer exists on disk? Sandbox ledger only."""
import importlib.util, os, sys, tempfile, json
scripts = "/Users/alex/ab/richos-wt/frank-fable-cert5/engine/scripts"
spec = importlib.util.spec_from_file_location("wl", os.path.join(scripts, "lib", "worktree-ledger.py"))
wl = importlib.util.module_from_spec(spec); spec.loader.exec_module(wl)
mod = wl._liveness_module()
tmp = tempfile.mkdtemp(prefix="stale-repo.")
os.environ["RICHOS_WORKTREE_TX_DIR"] = os.path.join(tmp, "tx")
pid = os.getpid()
start = wl.pid_start(pid)
gone = os.path.join(tmp, "repo-that-was-deleted")
records = [
    {"event": "registered", "agent_id": "st001", "teammate": "mark-opus-s", "session_id": "sess-s", "session_pid": pid, "pid_start": start,
     "repo": gone, "worktree": gone + "/.claude/worktrees/agent-st001", "class": "native", "source": "detect-nonnative-worktree.sh", "ts": "1"},
    {"event": "registered", "agent_id": "st001", "teammate": "mark-opus-s", "session_id": "sess-s", "session_pid": pid, "pid_start": start,
     "repo": os.path.join(tmp, "b"), "worktree": os.path.join(tmp, "b-wt", "mark-opus-s"), "class": "hand-rolled", "source": "detect-nonnative-worktree.sh", "ts": "2"},
]
print("resolve on a NONEXISTENT entity:", mod.resolve(gone, "st001"))
reg = records[1]
print("lock entities:", wl._lock_entities(reg, records, os.path.join(tmp, "b")))
print("judge:", wl._judge_registration(reg, os.path.join(tmp, "b"), records, mod, False, None))
