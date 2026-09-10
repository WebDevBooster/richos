# Escalation: agent-liveness says NOT-ALIVE for RUNNING agents: Claude Code's lock file is empty, so the pid test can never fire

- id: `esc-20260910T112940Z-07932e48`
- raised: 2026-09-10T11:29:40Z
- from: zach-opus-auto1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-auto1` (branch `zach-opus-auto1`)
- head: `a26abd3f4096ab321dd709b5bf5fc46ce77fe377`
- state: **proceeding**
- for: lead

## The question

Nothing is blocked in my task, but anything else built on agent-liveness.resolve() needs to know it is currently PERMISSIVE rather than protective - should someone own the resolver fix, or shall I carry it in this branch?

## What was already tried

Measured on this machine 2026-09-10 11:25-11:30. resolve('/Users/alex/ab/femcboost', <my own live agent id>) returns NOT-ALIVE, reason 'locked but the lock line carries no pid', while my worktree is present, registered and locked. All three currently running agents read the same. The cause is not the parser: git 2.52.0 reports a lock reason faithfully in --porcelain and --porcelain -z, both for a lock taken by git and for a lock file written directly (sandbox, both ways). The cause is the artifact - Claude Code's .git/worktrees/agent-<id>/locked files are 0 bytes right now, although at 10:55 mine contained 'claude agent agent-a42c90096292136f0 (pid 8799 start Thu Sep 10 05:39:28 2026)' and no unlock was recorded in between by a 20ms poller. This also explains the CEO's 'lock never released': _release_dead_lock refuses a lock with no pid ('locked without a pid; retained'), so an empty lock is unreclaimable forever by that route.

## Proceeding meanwhile

My reclaim does not rest on the liveness verdict. Its ground is the platform's own terminal ingress for the exact agent id plus the platform releasing its own lock, and every existing refusal still runs behind it. I am carrying the honest alternative for a lock the platform never releases in the same branch.

## CORRECTION, 2026-09-10 11:35 — the root cause above is MINE and it is wrong

**The platform did not empty those lock files. The orchestrator did, and I
had the evidence to know it and did not read it.**

The lead corrected this within minutes of the raise, and my own poller agrees
with the lead, not with me:

```
11:24:02.721  unlocked  a42c90096292136f0
11:24:02.747  unlocked  aa45acc74c2d4fcef
11:24:02.772  unlocked  af3b228967dc2b627
11:24:11.437  locked    aa45acc74c2d4fcef, a42c90096292136f0, af3b228967dc2b627
```

Finishing a land, the orchestrator unlocked every locked femcboost worktree
whose agent id had no process in the table — which is all of us, because
`pgrep` does not see a subagent — and re-locked within ten seconds.
`git worktree lock` WITHOUT `--reason` writes an EMPTY reason file, so the
platform's own `claude agent agent-... (pid 8799 start ...)` text was
destroyed by that re-lock.

**How I got it wrong is the part worth keeping.** I wrote "no unlock was
recorded in between by a 20ms poller". The poller was running and it did
record the unlock — at 11:24:02, fifteen minutes AFTER I last read its log at
about 11:10. I quoted my own reading of a live log as though it were the log,
which is a stale premise laundered into an escalation by exactly the route the
record warns about. The fix is not more care: it is that a number in a claim
gets re-read at the moment the claim is written, or it gets marked unverified.

**What stands, restated as findings rather than as a platform defect:**

1. `agent-liveness.resolve()` answered NOT-ALIVE for three RUNNING agents.
   That happened, and the cause does not change what it means: a HELD lock
   this module cannot attribute was being read as evidence of death, and
   that is the permissive direction. Whatever writes an unattributable lock —
   a hand, a tool, a future platform revision — the verdict is what decides
   whether a workspace may be destroyed. It is now INDETERMINATE, which is
   this module's own honest outcome and the one it promises never to
   collapse. Carried on this branch, with a test both ways.
2. `_release_dead_lock` refuses a lock with no pid, so a lock left in that
   state is unreclaimable by the pid route forever. Real, and a durable
   hazard rather than a momentary one. The defensive answer is carried on
   this branch too: a positive-evidence route that does not need the lock to
   name anybody, because the platform's terminal record already names the
   agent.
3. The pid in the lock is the SESSION pid (`pid_shared_with: 2` on this
   machine, three locks one pid). A verdict built on it says the session is
   alive, never that one agent is. My reclaim does not rest on it.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260910T112940Z-07932e48`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260910T112940Z-07932e48 --disposition "<what you decided or did>"
