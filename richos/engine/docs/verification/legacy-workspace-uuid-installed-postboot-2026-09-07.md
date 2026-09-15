# Installed legacy cleanup passed across a real reboot

On 2026-09-07 the corrected protected release from source `1e3e499` completed
its actual post-reboot acceptance. The temporary Data filesystem number changed
from 16777230 to 16777233. Native UUID plus inode pins, approved plan, selected
worktree/branch scope and the exact installed release all remained unchanged.

The isolated broker automatically completed the previously armed legacy job.
It reclaimed the generated linked worktree and Git registration, retired its
selected branch with a recovery ref and restored access to the canonical fixture
repository. No real repository was gated or modified by this acceptance.

Checks verified the final write made through the descriptor opened before the
gate, separate working and staged bytes, untracked/ignored bytes, symlink and
extended attributes. Required Git recovery objects survived immediate reflog
expiry and garbage collection while an unpinned control object was removed.
Replaying the completed job made no change. The broker shut down cleanly.

All nine recorded preboot/postboot checks passed. The tiny completed fixture and
its recovery evidence are retained. The earlier numeric-only failed fixture is
also retained unchanged as historical evidence.

Production remains inactive: no live LaunchDaemon plist, public `client.json`
or production broker socket exists. Complete Claude spawn integration and
installed interrupted-creation acceptance remain distinct requirements before
production activation. A successful legacy fixture does not complete migration
of existing real worktrees or authorize repository downtime.

Preboot kernel UUID: `c6f84dc3-a79a-4506-8759-d2de887ea19a`.

Postboot kernel UUID: `008db402-7e5f-47dd-9b0e-d499611c6498`.

[Structured acceptance receipt](legacy-workspace-uuid-installed-postboot-2026-09-07.json)
records the exact unchanged selection, release and checks.
