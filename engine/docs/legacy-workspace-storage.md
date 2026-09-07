# Legacy worktree storage at backlog scale

The offline gate supports regular hardlink groups contained entirely within one
approved maintenance target. It saves every original path and inode's ownership,
mode, flags and link count in one durable snapshot before protecting any source.
This preserves the original metadata when a later path names an inode already
protected through an earlier alias. Each frozen verification counts all current
aliases and requires the count to equal the inode's live link count. External
aliases and links crossing maintenance targets refuse staging or frozen access.

On macOS only `UF_TRACKED` and `UF_HIDDEN` are supported filesystem flags. They
remain unchanged on the original inodes and are recorded in recovery manifests
and archive PAX metadata. Immutable, append-only, compressed and other flags
remain unsupported. Native no-follow ACL inspection replaces a subprocess for
every file. ACL grants, unsupported object types and mount crossings still
refuse the gate. Git filesystem-monitor sockets must be drained through Git
before maintenance; the gate does not unlink sockets to make a scan pass.

A recovery archive stores one regular payload per hardlink group and exact
archive-local hardlink entries for its other aliases. Verification checks the
already verified target rather than repeatedly seeking backward through gzip.
The manifest retains the original inode group and every path's metadata.
Interrupted deletion verifies the remaining closed link set before replay.
Native worktree cleanup ownership and the required later machine boot do not
change.

## Completed replay snapshots

Ref publication and worktree retirement need a complete original gate inventory
while an operation can still require replay. Newly created operation journals
pin that copy's size and SHA-256 before mutation. After the effective inventory
and completed operation result are verified and durable, a separate release
intent permits unlinking only that independent private snapshot. An interruption
before or after unlink replays from the same exact intent. A missing copy without
intent, changed contents or a recreated copy is refused.

The effective gate inventory, original metadata in captures, ref before/after
payloads and completion receipts stay retained. Historical journals without a
creation-time snapshot digest are not retroactively authorized. This prevents a
large backlog from retaining another complete gate inventory for every completed
ref publication and worktree retirement.

## Verification

`legacy-workspace-storage.test.sh` exercises closed and external link groups,
cross-target refusal, preserved flags, capture topology and interrupted staging
or deletion. `legacy-workspace-snapshot-release.test.sh` checks incomplete and
historical retention, changed or externally linked snapshots, directory
substitution and interrupted release. The mutation and retirement suites also
exercise full Git workflows through completed snapshot release and replay.

The separate `legacy-workspace-storage.acceptance.py` controller is for a pinned
installed runtime under actual macOS root and owner credentials. Its disposable
fixture reports `tests_cutoff: false`: its instance-local later-boot simulation
cannot establish the real reboot boundary. A production gate still needs an
actual later machine boot. Passing source tests alone does not establish an
installed run or cleanup of a real backlog.
