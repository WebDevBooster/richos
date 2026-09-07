# Actual Claude canary: native cleanup conflict

The actual CLI run from `b6b7e2a8deae453f4ed201bc5bf5de16589be906` reached
one background worker, its sealed write barrier and its real SubagentStop hook.
It did not pass acceptance. The complete receipt, original hook events and
terminal transaction are in the [diagnostic JSON](claude-native-cleanup-canary-finding-2026-09-07.json).

The managed worker committed `44c208aa8a93dffdf8f405c3d9174cdffa6a7df1`.
The generated source repository received that exact commit through its managed
handoff ref and merged it. Its only ordinary branch remained `master`.
The final strict attachment inventory found no attached fixture images.

Three issues were exposed:

1. The model's first Agent call omitted its name. The guard correctly refused
   it, then admitted the corrected call with a different tool-use ID. The
   acceptance verifier incorrectly required exactly one attempted call, so it
   stopped before evaluating the remaining lifecycle checks.
2. RichOS renamed the native checkout on SubagentStop. The original checkout
   disappeared but its quarantine and locked Git registration remained. The
   reconciler retained it with `exclusive-access-unavailable`. No actual
   WorktreeRemove event was recorded. This is a production ownership conflict,
   not a passing example of Claude's automatic cleanup.
3. The fixture finish command returned when delivery became available, before
   the normal reconciler's retry interval allowed it to persist the delivery
   into the transaction. The acceptance must wait for that durable result too.

Claude documents automatic `git worktree remove` for Git-based worktrees and
WorktreeRemove as a notification without decision control.
See the [official hook reference](https://code.claude.com/docs/en/hooks#worktreeremove).
RichOS must leave newly bound platform-owned native paths available for that
cleanup and verify actual disappearance afterward. Existing quarantines still
require their separate recovery and retirement protocol.

The fixture is retained for diagnosis. Production remains inactive and this
failed attempt must not be reported as full lifecycle acceptance.
