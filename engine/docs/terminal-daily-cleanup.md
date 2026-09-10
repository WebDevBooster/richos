# Daily terminal workspace cleanup

Rewritten 2026-09-10 (round 10, `worktree-reclaim-round-10-2026-09-10.md`).
The authority did not change; four refusals that were never about authority
did.

The existing TaskCompleted hook verifies that a worker's committed work is
clean and real before recording completion. A task remains open when its
attribution is uncertain, tracked bytes or index differ from its commit, an
untracked file is present or a Git operation is unfinished. Ignored files do
not hold a task open. Canonical checkouts are never cleanup targets.

New sealed worker transactions use `cleanup_policy: integrated-daily`; so do
adopted transactions. Their terminal event leaves every worktree at its
original path. The scheduled terminal reconciler then, per member:

1. Requires an exact sealed terminal fact — an ingress the engine recorded
   from a platform event about that agent id (`SubagentStop`,
   `WorktreeRemove`, `TaskStop`), the reconciler's own verified
   `NativeMemberGone`, or `Adoption` on T1/T2 evidence — and rechecks
   competing path and branch reservations and the native agent's live lock.
2. Derives a fresh clean/integrated proof, even when a crash prevented the
   TaskCompleted receipt from being written: the tracked tree byte-identical
   to its commit, that commit an ancestor of `main`, the branch and
   registration exact. A native proof is also recorded before the platform
   removes its checkout when the terminal hook can still read it.
3. Decides what the tree's IGNORED files are. Those matching the committed
   disposable policy (`CAPTURE_DISPOSABLE_PATHS` — build output, dependency
   caches, bytecode) go with the tree. Every other ignored file is archived
   first into `~/.claude/state/worktree-captures/<sid>/<aid>/member-<i>/ignored-residue.tar`,
   the archive re-read and verified digest by digest, and the archive named on
   the member's journal. Nothing ignored is discarded without a verified copy;
   nothing disposable is kept on behalf of nobody. An unverifiable archive
   holds the member.
4. Holds the member if any process stands in the tree (`lsof +D` and an
   argv scan). Nothing is killed.
5. Removes only an exactly registered, unlocked linked worktree through
   `git worktree remove` without force. A platform-native checkout is removed
   by RichOS only when its OWNING SESSION IS PROVABLY GONE: every process
   identity the ownership ledger recorded for that session answers gone or
   reused, the harness registry `~/.claude/sessions/` names no running pid for
   it, and the checkout's lock (if any) names a dead pid — then the dead lock
   is released and the same proof and removal apply. A running or unknown
   session keeps deferring to the platform, whose own cleanup owns the
   checkout while it may still act.
6. Rechecks repository identity, integration and the complete worktree
   registry, then deletes the exact recorded direct branch with an old-OID
   compare-and-set. A branch still used by another checkout is retained.
7. For a native checkout the platform already removed with no receipt on
   record, deletes the branch only when its CURRENT tip is an ancestor of
   `main` and no checkout holds it — a fully merged branch with no working
   tree loses nothing — and retains an unintegrated tip with the reason.

Per-member journal phases are `prepared`, `worktree-removed`,
`branch-deleting` and `complete`. A retry checks the same proof and tolerates
only the expected already-absent worktree or reference. Recreated paths,
changed tips, unmerged commits, untracked files, live locks, running owners,
processes in the tree and unknown ownership are visible holds, each written on
the member. Pending branch work is included in cleanup status.

Historical quarantine records keep their recovery protocol and their explicit
erasure refusal (`workspace-retirement-safety.md`); this lane never touches a
quarantine. Explicit operator backlog discard is separate from daily
completion and is not inferred from age.

These are cooperative workflow checks, not an operating-system barrier against
arbitrary concurrent writers. They run as the ordinary user and require no
administrator service or recurring approval.

## Preview

`reconcile-terminal-worktrees.py --preview` prints, read-only, what the next
run would do to every pending member — `remove`, `branch-only`, `observe`
(platform-owned, session not provably gone) or `hold` — with the reason. It
writes nothing, takes no lock, unlocks nothing and archives nothing.

## Daily idle schedule, and the month question

Automatic reconciliation is a user-level launchd job
(`com.richos.worktree-reconciler`, written and verified by
`scripts/hooks/install.sh`) that fires at `RECONCILE_HOUR` local time (04:00)
and at load; launchd delivers a missed calendar event on wake. The job runs
after ten minutes without keyboard or mouse input, with a 300-second work
budget, and records the completed local date. Multiple missed days need only
one pass. **No Claude session is involved anywhere in this path.** Session
start reports status and starts nothing; session end does nothing at all.

So with no session for a month the job runs about thirty times, and a member
that becomes eligible is reclaimed by the first pass after it: worst case one
day plus the time until the machine is awake and idle, plus a day if the
budget ran out on a large backlog.

What could stop it silently — the job unloaded, its engine path gone, a
failure every night — is what `--status`'s `schedule` block and the
SessionStart banner exist for: when the store holds transactions and no pass
has completed within `RECONCILE_OVERDUE_DAYS`, the banner leads with
`RECONCILER OVERDUE`, and the spawn guard already refuses file-writing spawns
while the job is not loaded. Every run writes a timestamped start and end line
to `~/.claude/state/worktree-reconciler.log` with the counts it reclaimed.

The local target hour is configured by `RECONCILE_HOUR`; rerunning the
installer updates the ordinary-user launchd job. No administrator is required.
An explicit operator invocation without `--scheduled` remains available for
maintenance and runs the same code.
