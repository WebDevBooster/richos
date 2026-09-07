# Frozen branch publication

The candidate administrator tool can observe branches and apply a reviewed
selection inside a legacy gate with a verified later-boot cutoff. It does not
delete working directories, activate the service or reboot the host. Automatic
branch selection and scheduling remain separate work.

`branches` requires the gate ID, approved gate-plan hash and one repository alias.
Its snapshot contains the complete frozen ref and attachment inventory. A
`publish-branches` selection pins that snapshot, exact direct branch tips and
main/master integration tips. Attached, unmerged, malformed and unresolved refs
are refused. The exact selection hash is required separately from the gate hash.

The publisher prepares the ref transaction using the controlled Git shadow. It
rechecks the frozen snapshot under the gate lock, writes recovery payloads and
syncs every recovery directory before recording mutation intent. Filesystem
updates occur only while the repository remains closed. Replacement files use
exclusive temporary files outside held Git storage, so existing `.next` paths
remain untouched.

The pending mutation receipt blocks inspection readiness, gate resume and
restoration. `replay-branches` requires the same selection hash. Replay validates
all payloads and unaffected frozen inodes before further writes, verifies the
complete resulting ref snapshot and replaces the gate's inode inventory before
marking completion. Original ownership and modes are preserved for changed
files. New backup-ref directories and files receive explicit restoration
metadata. Empty existing directories remain intact.

Completed operations retain their payloads and receipt under the private gate
history before another selection starts. The next operation begins from the
effective inventory left by the previous one. Interrupted history archival is
retryable and does not alter held refs. Preparation interrupted before intent
is preserved separately before retry, after rechecking the frozen snapshot.

The root-owned installed package includes the shadow and publisher in its code
manifest. The administrator commands use the fixed Command Line Tools runtime.
These commands have not yet been exercised against a real gated repository or
an actual reboot. Disposable real-Git tests cover loose and packed refs, retained
backup refs, independent `.next` data, corrupted payloads, interrupted writes,
receipt publication and sequential operations. They are not privileged host
acceptance.
