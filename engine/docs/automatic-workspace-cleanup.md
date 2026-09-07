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
canonical Git store and verifies a readonly recovery image before deleting the
active image. New managed requests deliver their terminal commit through
`refs/richos/handoffs/managed/<UUID>/HEAD`, without creating an ordinary branch
in the source repository. The authenticated delivery query returns the exact
source, reference and commit; reconciliation also records this in the terminal
transaction. The orchestrator merges that exact commit. Existing published
branches retain their previous contract and are never silently deleted.
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
and protected administrator command are implemented and installed in an inactive
protected release. The isolated installed gate passed its owner-access and same-boot refusal checks.
The first real reboot exposed unstable numeric filesystem identities and refused
cleanup before any job action. Durable native UUID identities now cover all
persistent pins; see the [reboot finding and correction](verification/workspace-reboot-findings-2026-09-07.md).
The corrected fixture subsequently passed actual installed post-reboot
acceptance, including native device renumbering, unattended retirement and
recovery after immediate Git garbage collection. Selective capture and reclamation now have
disposable real-Git coverage, including recovery after interrupted deletion and
survival of staged/conflict blobs after reflog expiry and Git garbage collection.
Explicitly armed jobs now run automatically through the broker's separate
[maintenance worker](legacy-workspace-service.md). The [installed real-reboot acceptance](verification/legacy-workspace-uuid-installed-postboot-2026-09-07.md)
passed. Real repository migration still requires an exact reviewed scope and downtime.

## Branches

The old reaper no longer deletes ordinary branches, including with `--execute`.
Its live registry/process snapshots cannot exclude branch reuse or concurrent
checkout. It reports retained candidates as pending and cannot claim CLEAN
while those candidates remain. Existing branches use the frozen selection below.

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

- The final installed root-to-user acceptance fixture passed all 26 checks,
  including backing-image protection, forced-unmount refusal, actual owner socket
  lifecycle, unattended terminal and unused-preparation reclamation and clean
  broker shutdown. The corrected UUID package passed all 26 again; see the [current receipt](verification/managed-workspace-uuid-installed-lifecycle-2026-09-07.json).
  The isolated legacy real-reboot acceptance also passed.
- Validate the complete installed Claude spawn-to-retirement path before enabling
  the public configuration.
- Unused preparation cancellation and automatic reclamation passed through the
  installed service. Interrupted provider creation still requires separate
  installed fault-injection acceptance. The source implementation handles both. Exact session cancellation is durable, live or unknown sessions are
  retained and paginated inventory reaches later abandoned records. Verified raw
  archives preserve malformed images, including outer extended attributes.
  Requests that never reserved storage close without a disk-reclamation claim.
  Raw recovery has no automatic expiry because unique data cannot be classified.
- The legacy executor, coordinated branch publication and armed-job background
  worker have passed disposable integration tests and independent review.
  The installed UUID fixture passed across a real reboot; its
  [result and receipts](verification/legacy-workspace-uuid-installed-postboot-2026-09-07.md)
  are saved in this branch. Actual repository downtime still requires explicit
  authorization. The first failed fixture remains historical evidence.

The package's health endpoint reports listener availability, sweep progress and
owned unresolved records separately. It explicitly does not certify the complete
feature as accepted. See [broker installation](managed-workspace-broker.md) and
[volume boundary](managed-workspace-volume.md).
