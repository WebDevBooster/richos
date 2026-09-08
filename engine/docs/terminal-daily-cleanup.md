# Daily terminal workspace cleanup

The existing TaskCompleted hook verifies committed work is integrated into the
canonical repository's `main` before recording completion. A task remains open
when its attribution is uncertain, tracked bytes or index differ from its
commit, integration is missing or a Git operation is unfinished. Canonical
checkouts are never cleanup targets.

New sealed worker transactions use `cleanup_policy: integrated-daily`. Their
terminal event leaves external worktrees at their original paths. The existing
scheduled terminal reconciler then:

1. Requires the exact sealed native terminal fact and rechecks competing path
   and branch reservations and the native agent's live lock.
2. Derives a fresh clean/integrated proof, even when a crash prevented the
   TaskCompleted receipt from being written. A native proof is also recorded
   before Claude removes its checkout when the terminal hook can still read it.
3. Removes only a RichOS-owned, exactly registered, unlocked linked worktree
   through `git worktree remove` without force. Claude alone removes its native
   checkout; RichOS observes its path and registration disappearing.
4. Rechecks repository identity, integration and the complete worktree registry,
   then deletes the exact recorded direct branch with an old-OID compare-and-set.
   A branch still used by another checkout is retained.

Per-member journal phases are `prepared`, `worktree-removed`, `branch-deleting`
and `complete`. A retry checks the same proof and tolerates only the expected
already-absent worktree or reference. Recreated paths, changed tips and unknown
ownership are visible holds. Pending branch work is included in cleanup status.

Linked worktree proofs include untracked and ignored files. Workers must commit
meaningful files and remove disposable generated files or copied local config
before completing. The reconciler does not silently discard those bytes and
does not archive every completed checkout. Canonical ignored files remain in
place and do not grant cleanup authority.

Historical quarantine records keep their recovery protocol. Explicit operator
backlog discard is separate from daily completion and is not inferred from age.
An already-absent native checkout without a valid saved proof remains a visible
branch hold. Completion and terminal observations are separate facts.

These are cooperative workflow checks, not an operating-system barrier against
arbitrary concurrent writers. They run as the ordinary user and require no
administrator service or recurring approval.
