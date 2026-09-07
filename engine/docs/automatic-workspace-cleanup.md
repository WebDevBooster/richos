# Automatic workspace cleanup

Status: candidate implementation, service files staged on the acceptance host
but not enabled. The complete
worktree-cleanup objective is not finished. Existing active work must remain
untouched.

## Scope

Claude Code normally removes its native worktrees. RichOS must clean its external
workspaces, recover positively identified native leftovers and remove delivered
dead branches. Cleanup must reclaim disk space automatically rather than move
it into permanent archives.

## Implemented candidate

New external workspaces can use root-managed APFS sparse images containing an
independent Git clone. Working files, indexes and objects share the same
filesystem boundary; mutable alternates and partial clones are refused. The
broker authenticates operating-system UIDs and restricts creation to an explicit
repository policy. It does not run repository Git commands as root.

The existing creation helper, preparation ledger, spawn guard, seal, terminal
routing and reconciler recognize exact `managed-image` membership. A managed
workspace is identified by its manager-issued UUID, source identity, owning
session and worker. It is never presented as a linked Git worktree in the
canonical repository. Stable creation requests cannot allocate duplicate images
when the response is lost. Repeated preparation does not overwrite existing
seeded files.

Only a normal successful detach, or positively verified absence after a different
kernel boot identity, supplies a write cutoff. Busy filesystems remain intact.
Unknown, incomplete or malformed attachment inventories refuse reclamation.
The manager preserves terminal refs and both endpoints of reflog history in the
canonical Git store, publishes the worker branch without overwriting a different
tip and verifies a readonly recovery image before deleting the active image.
Slow capture and expiry run in the manager's sweep, outside Claude hook budgets.

Clean recovery images expire after the configured retention, subject to verified
canonical source identity and handoff refs. Recovery with unique working, staged,
untracked or ignored data is retained. An index lock, hidden index flags,
submodule or uncertain cleanliness also prevents expiry. Finite deletion of that
unique data has not been authorized. Committed history is preserved in Git after
recovery-image expiry.

The installed public `client.json` enables managed creation. An enabled but
unavailable broker, unreadable policy or missing integration module refuses
creation. Installation writes `client.pending.json` only. It does not enable
managed creation or start the service.

## Existing worktrees and current activity

A process scan cannot revoke writes through already-open files. Descriptors
queued through a Unix socket and writable mappings survive ordinary permission
changes. Copying an arbitrary directory into an archive does not fix that race.

Existing directory-based worktrees require the
[offline retirement executor](legacy-workspace-retirement.md). It preserves a
verified archive and Git recovery refs before reclaiming the selected worktree
and registration. No real worktrees have been passed through this executor.
The read-only legacy maintenance planner describes the complete repository gate
needed for migration. Shared Git objects mean the gate must cover the canonical Git
store and every registered checkout, including checkouts that are not removal
candidates. It cannot run while another worktree has active or unknown work.

A defensible migration gate must be established before reboot and remain closed
until post-reboot capture completes. LaunchDaemon startup order alone is not a
proof that writers have stopped. A Claude session restart is insufficient.
A candidate gate now consolidates nested native worktrees into physical root
gates, discloses temporary parent-directory protection and supports explicit
later-boot restoration after interrupted staging. Its owner-inspection boundary
and protected administrator command are implemented. It is not installed or
accepted on the privileged host. Selective capture and reclamation now have
disposable real-Git coverage, including recovery after interrupted deletion and
survival of staged/conflict blobs after reflog expiry and Git garbage collection.
Explicitly armed jobs now run automatically through the broker's separate
[maintenance worker](legacy-workspace-service.md). Installed legacy gate and
actual reboot acceptance remain required before migration.

## Branches

The existing branch-retirement helper now refuses unreadable worktree registries
and preserves a recovery ref together with exact-tip deletion in one Git ref
transaction. Focused races and symbolic-ref cases have regression coverage.

The new terminal-branch planner checks exact terminal ownership, recorded tips,
explicit main/master integration refs, merge ancestry and all registered
checkouts across repositories. It retains attached, live, unknown, unmerged,
moved or reused branches. It is read-only. An explicit frozen selection can now
use the [journaled publisher](legacy-workspace-mutation.md) under the later-boot
gate. It preserves backup refs and blocks reopening until interrupted publication
has been replayed and verified. Armed jobs automatically execute their fixed
approved branch selections. This does not grant arbitrary live-branch deletion
or discover and approve a broader selection during a retry.

## Remaining acceptance and work

- The installed root-to-user acceptance fixture passed all 17 checks, including
  backing-image protection and forced-unmount refusal. See the
  [host receipt](verification/managed-workspace-host-acceptance-2026-09-07.md).
  Actual reboot acceptance remains separate.
- Validate the complete installed Claude spawn-to-retirement path before enabling
  the public configuration.
- Run the integrated preparation recovery through the installed service. The
  source implementation now handles unused preparations and interrupted provider
  creation. Exact session cancellation is durable, live or unknown sessions are
  retained and paginated inventory reaches later abandoned records. Verified raw
  archives preserve malformed images, including outer extended attributes.
  Requests that never reserved storage close without a disk-reclamation claim.
  Raw recovery has no automatic expiry because unique data cannot be classified.
- The legacy executor, coordinated branch publication and armed-job background
  worker have passed disposable integration tests and independent review.
  Validate the installed legacy gate across a real reboot before migration.
  Actual repository downtime requires explicit authorization.

The package's health endpoint reports listener availability, sweep progress and
owned unresolved records separately. It explicitly does not certify the complete
feature as accepted. See [broker installation](managed-workspace-broker.md) and
[volume boundary](managed-workspace-volume.md).
