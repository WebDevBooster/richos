# Automatic expiry of clean legacy recovery

New armed jobs classify each captured worktree while its original bytes remain
behind the verified offline gate. Classification compares the complete working
file inventory and actual blob bytes with the captured HEAD and index. Extra,
missing, staged or dirty bytes retain the bulk archive. Hidden index flags,
submodules and unresolved Git state also prevent a clean proof.

Before retirement, the job saves the exact result from
`legacy-workspace-expiry.prepare`. A clean capture receives `clean-expiry.json`
and `compact-metadata.json` in its protected capture directory. The compact
file preserves the original manifest, all per-worktree Git administration bytes
and the worktree's Git pointer bytes. The manifest retains filesystem metadata,
symlink targets and extended attributes. Unknown or oversized metadata retains
the bulk archive. The compact writer is bounded to 64 MiB and 100,000 paths.

After the job has restored the repository, the ordinary background worker calls
the expiry executor with that exact saved proof and the repository's current
approved retention policy. It verifies the protected proof, capture receipt,
manifest and compact metadata. It checks native filesystem UUID/inode pins for
the canonical repository, Git store and recovery files. Git reference and
object-closure checks run as the approved owner, not as root.

Once the retention interval has elapsed, a journaled operation removes only the
verified `recovery.tar.gz`. A lost unlink response is replayed through
`expiry-state.json`. Compact metadata, the original receipt, manifest and Git
recovery refs remain. The archive is never reported expired merely because its
path is missing. Missing or altered metadata, moved references, unknown source
identity and revoked repository policy prevent deletion.

Admin-only orphan captures always retain their bulk archive. The absence of the original working checkout cannot prove that its working state was clean, even when the surviving index matches HEAD. Registration and branch retirement can still complete after their independent recovery checks.

Historical jobs and standalone retirements have no saved clean proof and remain
retained. New jobs save their expiry policy version at arming; retries cannot
retrofit a missing proof after the original source has been removed. Dirty or
uncertain captures retain their entire recovery archive indefinitely.

An expired clean archive is reconstructed from its pinned Git commit and retained
metadata. The compact file is not a standalone repository and depends on the
preserved canonical Git object store. Keep metadata and recovery references with
the repository's backups. Actual directory retirement, archive expiry and
retained recovery bytes are reported as separate outcomes.
