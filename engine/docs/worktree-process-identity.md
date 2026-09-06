# Worktree process identity and recovery

The process that owns a worktree can be observed by a terminal hook and a scheduled
daemon with different locales and timezones. Human-formatted process-start strings
are not comparable across those environments. A formatting mismatch must never
become evidence that a live owner terminated.

New ledger records use a versioned token from `ps` under the C locale and UTC.
Both collection and comparison use the same environment. Historical untagged
records cannot establish PID reuse because their formatting context was never
saved. If that PID still runs, identity remains unknown and the worktree is held.
No guessed timezone offset, age threshold or different dead owner overrides that
hold. The ordinary dead-PID and canonical reuse cases remain decidable.

A resumed session may keep its session ID while changing PID. Adoption considers
every recorded process incarnation; a dead predecessor cannot hide a live
successor or overrule it based on record order.

Session lookup retains every recorded incarnation whether a path row omits its
PID or names a dead predecessor. A live successor recorded on another path of
the same session still vetoes retirement of the session-owned tree. A missing session ID does not hide a recorded process or a new ownership
registration. A named owner with no resolvable process remains unknown unless
that exact agent has an independent platform terminal record. An unrelated old
owner's terminal record never resolves the uncertainty.

Canonical tags must contain a complete valid C/UTC date and time. A malformed or
truncated tag, invalid JSON field type or unreadable process observation remains
unknown. A shared prefix alone cannot prove that a PID was reused.

The process table used by session exhaustion is also collected under C/UTC and
parsed as UTC. A recorded but ambiguous PID cannot fall through to that weaker
process-name scan. Adoption refuses when any recorded owner has unknown identity,
even if another record otherwise supplies a terminal tier.

## Containment

If adoption incorrectly claims live worktrees, keep terminal reconciliation
available. The committed engine setting ADOPTION_ENABLED="0" disables the
adoption pass while leaving already claimed terminal transactions recoverable and
the scheduled daemon available to the spawn guard. The heartbeat reports
adoption as disabled-by-config. This is explicit degraded operation, not a repair
or a declaration that ownership is healthy. Record the setting and reason, then
restore it after verifying the corrected candidate in the installed environment.

Do not unload and reload the same faulty daemon to race its timer. Do not restore
quarantines by renaming directories while their transactions still claim them.
Retained worktrees and captures require a coordinated ownership/Git recovery.

## Acceptance

The process-identity suite observes a real process from multiple locales and
zones, tests conservative treatment of legacy records and executes the scheduled
reconciler entry point repeatedly against isolated stores and a temporary Git
worktree. It then commits a worker result and merges that result into the fixture's
main branch. It verifies the adoption pass actually ran, so a disabled pass cannot
produce a false green. The full engine runner discovers its shell entry point.

That automated result is not a native Claude Agent round trip. Before declaring
the installed system accepted, observe a fresh host session create and bind an
external worker, preserve it across scheduled reconciliation, deliver its commit
and recover the resulting work state after another restart.

The Linux C48 assertion consumes the full Git worktree listing and checks the
exact quarantine's lock. An early-exiting grep under pipefail can report Git's
SIGPIPE as a missing lock even when grep found it. This is a verification defect
and is separate from the locale-dependent ownership defect.
