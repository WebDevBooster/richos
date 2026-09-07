# Explicitly armed legacy maintenance jobs

`legacy-workspace-job.py` automatically advances an approved cleanup job after
the actual kernel boot identity changes. It neither creates a gate nor reboots
the host. Arming requires an existing fully gated namespace and the exact gate
plan hash. A staging or restoring gate cannot be armed.

`arm(gate, selection, approved_selection_sha256=..., scratch_root=...)` binds one
immutable selection per gate. Candidates carry repository alias, original path,
inode identity, Git admin path and approved terminal HEAD. Branches carry
repository alias, full ref, exact old tip and explicit main/master integration
ref and tip. Each candidate must match the approved gate inventory. Fresh
snapshots may supply metadata comparison evidence but cannot broaden these
approved candidates or replace the approved branch tips.

The fixed protected scratch directory is `<gate>/job-scratch`. Arming records a
nonce that reserves per-candidate scratch names. Before copying any bytes, the
runner durably records the exact scratch inode and the frozen source manifest
hash. A lost capture response adopts an independently revalidated complete
archive. Known incomplete copies are removed automatically only while the job
remains in capture phase, after checking the original frozen sources and exact
private scratch authority. Unknown files, foreign receipts, symlinks, replaced
scratch inodes and changed original data stop the job.

`advance(gate, gate_id, scratch_root=..., trusted_git=...)` performs at most one
durable step. For each candidate it captures recovery bytes, publishes additive
object recovery refs and retires the old registration and working directory.
New jobs record their recovery-expiry policy version at arming. Before retiring
a candidate, they durably save its exact clean/retained classification and any
compact metadata proof. A retirement retry uses that saved result after the
original directory is gone. Older jobs are never reclassified retroactively.
It then publishes the exact approved branch selections, grouped by repository,
and restores access to surviving gate roots. Every primitive selection is saved
before invocation. Matching publication or retirement journals are replayed
after a lost response; missing paths or refs alone never imply completion.
Restore retries through its existing restoring/restored journal states.

A separate job lock serializes advances while primitive operations retain their
own gate locks. `status(gate, gate_id)` reads the atomic job journal without
waiting for either lock. States are `waiting-for-boot`, `pending`, `failed` and
`complete`. Status includes phase, candidate and branch-group progress and a
bounded failure reason. Failures before restoration keep the gate closed. If
restore completes but its response is lost, the next advance recognizes the
restored receipt and finishes the job. Retries keep the approved scope fixed.

`expire_completed` separately processes saved clean proofs after restoration.
It checks the selected alias, canonical path, owner and current approved
retention policy before invoking the [expiry executor](legacy-workspace-expiry.md).
It never reruns retirement or expands the candidate list. Status includes
recovery-expiry state counts and up to three bounded retention/failure details.
Completion of directory retirement and completion of recovery expiry are
reported separately.

The broker background worker and explicit admin commands supply installation,
policy and scheduling integration. This module itself does not activate a
service or arm jobs through an unprivileged socket.

An orphan registration must be selected explicitly with `kind: orphan-registration` and its exact absent-namespace identity. Ordinary selections default to `registered-linked-worktree` for compatibility. The same journaled capture, handoff and retirement phases preserve its surviving administration and object dependencies, while removing no nonexistent working directory. A newly recreated logical path stops the job before retirement. Such captures remain retained and never receive a clean-worktree expiry proof.
