# Legacy directory reclamation

The candidate retirement executor removes one approved linked worktree and its
Git registration after an offline gate establishes a verified later-boot cutoff.
It preserves a verified compressed recovery archive and durable Git recovery
refs. It does not delete the canonical repository or authorize archive expiry.

The administrator flow is `capture`, `publish-recovery`, `retire`, then gate
`restore`. Each destructive selection names the exact gate and capture receipt
with its separately approved hash. Interrupted publication uses `replay-branches`;
interrupted directory reclamation uses `replay-retirement`. An explicitly armed
[maintenance job](legacy-workspace-job.md) executes these steps automatically
through the broker's background worker.

Before recording removal intent, the executor revalidates the entire archive
against frozen working and per-worktree Git metadata. It checks protected archive
authority, every required recovery ref and the transitive Git object closure.
Missing objects, unparsed index/Git state and external submodule dependencies
prevent removal. The shared Git database is retained in its canonical repository.

A durable retirement marker blocks gate restoration until removal and the
effective inode inventory are complete. Replay checks archive integrity, recovery
refs and every remaining frozen inode before further unlinking. A partially
removed registration may be excluded from the Git HEAD inventory only by its
exact journaled name. Every other registration is still checked. Completed
retirements retain their metadata history before another candidate starts.

Physical gate roots belonging solely to a retired worktree are recorded as
retired. Restoration does not recreate them or overwrite a newly created user
directory at that old path. Nested retirement removes only the selected subtree.
The canonical checkout and unrelated workspaces retain their original metadata.

Recovery remains unclassified and retained. The archive contains working files,
the index and per-worktree Git metadata, including custom PAX attributes for
original filesystem metadata. It depends on the preserved common Git objects
and is not a standalone repository. See [capture](legacy-workspace-capture.md)
and [object recovery refs](terminal-recovery-shadow.md).

Tiny real-Git tests exercise dirty working/staged bytes, missing handoff and
corrupted archive refusal, interrupted unlink and inventory updates, partial
registration replay and preservation of newly recreated user paths. This is
not installed privileged gate or actual reboot acceptance. No production
worktree has been reclaimed by this executor during development.
