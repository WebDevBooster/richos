# Workspace retirement safety

Updated 2026-09-06 after the repeated reviews of the worktree-container deletion.

The managed cleanup paths preserve workspaces and refuse automatic erasure.
This prevents the reviewed deletion failures without relying on a process scan
or a final content check to exclude concurrent writes. Quarantines and recovery
artifacts accumulate on disk. Restoring automatic deletion requires an enforced
access boundary, not another unchecked override flag.

## What failed

The original remover accepted an unknown owner and an unregistered path, then
recursively deleted the path. The malformed caller supplied the container of
all worktrees. Later fixes still had independent unsafe cleanup routes. The
last review found that archiving an index did not preserve its staged Git
objects, a write after the sweep's coverage check could be erased and the
detector still deleted directories based only on missing registration.

The terminal reconciler also had independent force-removal and residue-deletion
paths. Its automatic erasure and recovery-artifact expiry are disabled by the
same change. Otherwise the retention guarantee would depend on which cleanup
entry point happened to run.

## Current contract

- Identity retirement and the legacy remover share one transaction. Unknown
  ownership, inconsistent identity or insufficient termination evidence refuse.
  Parent directories and sibling worktrees are not valid retirement targets.
- Both routes preserve files before renaming the exact workspace to quarantine.
  Ownership changes detected before or after the rename refuse and trigger
  rollback where applicable. Branch retirement remains a separate checked step.
- New retirement archives contain working files, worktree Git administration
  files and a Git pack covering HEAD history and every index stage, including
  merge conflicts. A separate temporary repository verifies the pack before
  retirement. Git pruning in the original repository cannot remove these copies.
- Restore builds a separate Git repository with the archived index. Split index
  files are included. A successful restore verifies the recovered object graph
  and index without requiring the original repository.
- Submodule index entries currently refuse retirement because complete submodule
  recovery is not implemented. Missing required objects also fail before rename.
- Sweep retains quarantines even after retention expires. `sweep --execute`
  returns `refused`, reason `automatic-erasure-disabled` and exit 3. Inspection
  still reports missing archives, altered identities and content divergence.
- The detector reports unknown directories and leaves their contents intact.
- The terminal reconciler captures and verifies, then retains both the quarantine
  and its Git registration. It records `exclusive-access-unavailable` as a
  blocked condition. Older unregistered quarantines also remain. Recreated
  original paths with unknown ownership remain untouched. Captures, backup refs
  and transaction records do not expire automatically, including those belonging
  to transactions already marked removed by an older version.

Terminal reconciler `--status` continues to report retained directories as pending
and exits nonzero. It does not pretend that physical cleanup completed. Its
scheduled run still records a heartbeat. The terminal capture format is separate
from the standalone retirement archive described below.

## Recover a retirement archive

Use the installed engine path in place of `<engine>`. The destination must be empty or absent. These commands do not change the original repository.

```sh
python3 '<engine>/scripts/lib/workspace-retire.py' list
python3 '<engine>/scripts/lib/workspace-retire.py' restore 'ws-IDENTITY' '/new/recovery'
```

The JSON result provides `recovery_git_dir` and `recovery_work_tree`. For example:

```sh
git --git-dir='/new/recovery/recovery.git' --work-tree='/new/recovery/workspace' status
git --git-dir='/new/recovery/recovery.git' show ':path/to/staged-file'
git --git-dir='/new/recovery/recovery.git' show ':2:path/to/conflicted-file'
git --git-dir='/new/recovery/recovery.git' show 'HEAD:path/to/committed-file'
```

The files under `workspace/` hold working-tree content, which may differ from
staged content. The extracted `.git` pointer is historical evidence; use the
returned recovery Git directory rather than that pointer.

An older archive without an object pack still extracts its files but returns
`failed` with `legacy-object-pack-missing`. It cannot promise staged recovery.
Keep the original repository and its objects if they still exist. Do not treat
an older archive as a complete backup simply because its file hashes verify.

## What would make bypass impossible

These scripts are not an OS security boundary. A process with the user's full
filesystem permissions can bypass them, overwrite its own policy or delete
archives directly. Hook hashes and advisory locks cannot remove that authority.

An enforced design needs agent processes with write access confined to their
own disposable workspace, a separately privileged workspace manager and recovery
storage agents cannot modify. The manager must revoke all writers or take a
protected filesystem snapshot before authorizing erasure. It must prevent new
writers throughout the operation and keep recoverable snapshots outside agent
authority. Native harness cleanup must participate in that boundary too.

This change does not claim that infrastructure exists. It removes automatic
erasure from the reviewed managed routes until that infrastructure can provide
the missing guarantee.

## Verification

Use disposable fixtures only. The retirement suite includes the original
container-deletion negative control and both earlier review reproductions.
`workspace-retire.safety.test.py` additionally exercises distinct staged and
working versions after original-object pruning, all conflict stages, split index
recovery, incomplete-object refusal, legacy-archive reporting and a write
injected immediately after sweep coverage succeeds.

The detector suite checks actual preserved bytes. The terminal reconciler suite
checks retained directories and Git registration, late writes, old journal
states, preserved captures and blocked status alongside its existing capture
and ownership regressions. Test counts and command results are recorded in the
implementation verification report under `richos-hq/docs/verification/`.
