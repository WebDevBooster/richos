# Managed macOS workspace volume provider

`scripts/lib/managed-workspace-volume.py` supplies the low-level volume boundary
for a privileged lifecycle broker. It is a prototype provider, not an installed
service or a replacement for Claude Code's native worktree lifecycle.

## API and ownership

Import the module and instantiate
`VolumeStore(private_root, active_mount_root, require_root=True)`. The two roots
must be separate absolute directories under root-owned ancestors that users
cannot replace. macOS aliases such as `/var` are canonicalized once before
validation and use. The private root is mode 0700. The active mount root is mode
0711 so the workspace owner can traverse a known mount path. The provider refuses
writable resolved ancestors and a non-root production caller.

`create(id, source_repo, commit, owner_uid=..., owner_gid=..., size="32g")`
reserves a canonical UUID, creates a sparse APFS image and clones a complete
independent repository into `active_mount_root/id/repo`. Capacity is a ceiling;
a sparse image allocates storage as used. The broker must authorize the source
repository, owner and full commit object ID before calling. Git runs as that
unprivileged owner through `/usr/bin/git`, with sanitized configuration and
environment, disabled hooks and only the local file transport enabled. Clone
uses `--no-local --no-hardlinks`; shallow history, alternates, promisor packs and deferred object
configuration are refused. Git fsck completes before `initialized` is recorded.
Working files, index and the private object store therefore share one filesystem.
This changes external workspaces into independent repositories; it does not
provide an automatic linked-worktree migration.

`inspect(id)` returns the durable record plus the current matching hdiutil image
attachment. `attach(id)` activates a detached image. `detach(id)` uses only the
backing device resolved from that exact image's hdiutil record, checks the
recorded device and verifies the image is absent afterwards. It never uses
`-force`. Busy or unverifiable detach retains the image and operation journal.
`attach(id, readonly=True)` requires a detached state and mounts under the
private root. The provider verifies the reported mountpoint and read-only mode.
The broker must prevent writable reactivation once retirement begins.

No provider method accepts an arbitrary device or deletes an image. Capture,
archive verification, handoff refs, expiry, quota policy and image deletion
belong to the broker. A retained or mounted image does not count as reclaimed
disk space. The broker must require `initialized` before publishing a workspace.

## Journal and interruption

Each private `id/` directory contains `image.sparsebundle`, `journal.json`, a
lock file and the private `readonly/` mountpoint. Journal version 1 records
`id`, `owner_uid`, `owner_gid`, `commit`, `image_identity` (device and inode),
`state`, `operation`, `device` and, after initialization, `initialized`.
States are `creating`, `detached`, `attached_writable` and `attached_readonly`.
Operation intent is durably written before mutation; updates use fsync and
atomic replacement. An exclusive per-image lock covers clone initialization
and each volume operation. Unexpected image replacement refuses further action.

A crash after image creation but before its identity is journaled leaves an
incomplete reservation requiring broker recovery. The provider does not guess
that an existing image belongs to an incomplete record. A pending detach may be
retried while the exact image remains attached. Once an interrupted operation's
image has disappeared, intent alone cannot prove that a successful unforced
detach occurred. The provider refuses to manufacture that receipt; broker
recovery needs a stronger boundary such as a subsequent boot before authorizing
capture or deletion.

## Trust boundary and verification

The production contract requires the root broker to control image files,
journals and mount authority. Root and other independently privileged mount
managers are trusted. Image-to-device verification and device-based detach are
separate OS operations, so they do not exclude interference by another root
actor. `require_root=False` is solely for disposable tests. It proves provider
behavior and does not create a privilege boundary.

The regular test suite checks identity substitution, invalid selectors, unknown
disappearance, failed or incomplete detach, ambiguous attachments and refusal
to run Git as root. On macOS, run
`RICHOS_VOLUME_INTEGRATION=1 bash scripts/lib/managed-workspace-volume.test.sh`
to create a disposable actual APFS image. This test verifies independent clone
state, refusal while a writable descriptor is open, while one is queued through
SCM_RIGHTS with no process FD and while a writable mmap survives its closed FD.
Each holder successfully writes before closing. It checks preservation of
distinct staged and working bytes after detach,
source-independent recovery and kernel refusal of writes on the read-only
mount. It detaches its own fixture before removing temporary storage. It does
not exercise a privileged installed broker or legacy-directory migration.
