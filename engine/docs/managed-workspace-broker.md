# Managed workspace broker and installation package

The broker is a root Unix socket service for external managed workspaces. It
uses the volume provider and lifecycle manager from the same protected release.
It does not replace Claude Code's native cleanup. Installation and installed-host
acceptance remain separate from these source and disposable fixture tests.

## Authority and requests

`managed-workspace-client.py` exposes `call(request, socket_path=...) -> record`.
It authenticates the server's kernel peer UID as root. Connection failure,
protocol failure or a non-root peer raises `ClientError`; there is no fallback.
The CLI reads one JSON request from stdin and writes the returned record.

The broker authenticates the client's operating-system UID through macOS
`getpeereid` or Linux `SO_PEERCRED`. It uses a fixed root-owned policy with
approved repository aliases, canonical source paths, permitted owner UIDs,
fixed GIDs, image capacities and retention periods. This authenticates users,
not individual agents sharing one UID. Session and agent identifiers are
lifecycle checks, not secrets or a separate privilege boundary.

Supported requests have exactly these fields:

- `create`: `operation`, `repository` alias, full `commit`, `session_id`,
  `agent_name` and stable `request_id`. The manager owns durable idempotency;
  retries must preserve the request ID and payload.
- `bind` and `terminal`: `operation`, manager-issued `id`, `session_id`
  and `agent_id`.
- `inspect`, `reconcile` and `delivery`: `operation` and manager-issued `id`.
  `delivery` returns the freshly verified exact source/ref/tip receipt once ready.
- `preparations`: `operation` and `after` (empty string for the first page),
  returning up to 100 owned unused or incomplete preparations and `next_cursor`.
- `cancel_preparation`: `operation`, manager-issued `id` and exact `session_id`.
  It records cancellation only for unbound preparations. Capture runs later in
  the daemon. Published workers cannot be cancelled through this operation.
- `health`: only `operation`, available to approved peer UIDs. It reports
  protocol version, server UID, permitted repository aliases, owned unresolved
  count and latest sweep timestamps. Unknown inventory remains unknown.
- `status`: only `operation`, returning at most 100 durable records for the peer
  UID, total count, unresolved count and an explicit truncation flag. It includes
  incomplete creation requests and does not require an active mount.

Every existing-ID operation checks the manager record's owner against the peer
UID. Clients cannot choose arbitrary paths, devices, owner identities, expiry
timestamps or deletion operations. Lifecycle responses include `manager_id`,
`workspace_class: managed-image` and the exact `active_root/id/repo` path.
The manager's internal sweep runs periodically regardless of new sessions.
Changed unresolved sweep summaries are logged with UUID, state and reason;
unchanged failures do not emit repeated noise. Full private records are not logged.
The client CLI accepts `status` or `health` without a stdin payload. Health
explicitly does not assess complete installed-feature acceptance.
Requests are limited to 64 KiB, responses to 1 MiB and simultaneous clients to
eight. A client timeout does not cancel a manager operation; retry creation
with the same durable request ID.

## Reviewable package

Build a package without privilege or live changes:

```sh
python3 'scripts/install-managed-workspace-broker.py' --stage '/tmp/reviewed-workspace-broker'
```

The package contains the managed-image and legacy-maintenance runtime modules,
including the isolated privileged acceptance runner, their SHA-256 manifest, an
installation script, a launchd plist and a policy example. Replace the example's
UIDs and paths with the explicitly approved host configuration. The example is
not an approved policy.

A reviewed package can later be installed by an administrator using the root-owned Apple Command Line Tools
Python (`/Library/Developer/CommandLineTools/usr/bin/python3`) with `-I -S`. The installer requires root, checks the package hashes and
uses only the dedicated `/var/db/richos-workspaces` and
`/var/db/richos-workspace-mounts` storage namespaces. It refuses to repurpose
other policy paths or change permissions on mismatched existing directories.
It writes these fixed artifacts:

- Code: `/Library/Application Support/RichOS/workspace-broker/releases/<hash>/`
- Private policy: `/Library/Application Support/RichOS/workspace-broker/policy.json`
- Pending public configuration: `/Library/Application Support/RichOS/ManagedWorkspaces/client.pending.json`
- Socket directory: `/var/db/richos-workspace-sockets/`
- Pending LaunchDaemon: `/Library/Application Support/RichOS/workspace-broker/com.richos.managed-workspace-broker.plist.pending`

The pending configuration is root-owned mode 0644 and contains version 1,
`socket`, `active_root` and `repositories: {alias: canonical_source_path}`.
Installation does not publish `client.json`, which callers use to enable
managed mode. After separate installed-service health and privilege acceptance,
an explicitly authorized activation can publish the reviewed pending file as
`client.json`. Once enabled, callers must report a broker outage rather than
silently create unmanaged workspaces. A health response alone does not establish
the installed filesystem privilege boundary.

Installation never writes into a launchd discovery directory or loads a job.
It refuses existing published service files, public configuration or a broker
socket before changing installed policy. Staging therefore cannot arrange a
next-boot activation. Activation is a separate authorized operation after review
of the exact policy and release: publish the reviewed pending plist into
`/Library/LaunchDaemons/`, load that job and enable the public configuration only
after the required acceptance. The installer does none of those operations.

The [activation and migration sequence](managed-workspace-activation.md) also
requires landing and installing the user-facing engine before enabling the
public configuration. A protected broker release alone does not upgrade Claude
hooks, helpers or running sessions.

## Root code execution and remaining acceptance

The launchd plist uses `/Library/Developer/CommandLineTools/usr/bin/python3 -I -S -B`, an absolute installed release
path and a fixed working directory. Before loading the manager, the broker
requires root ownership and non-writable resolved ancestors for its executable,
interpreter import paths, policy and all runtime files. On macOS it additionally
rejects ACL grants or unreadable ACL metadata, accepting only absent or deny-only
ACLs. It verifies every
runtime file against the root-controlled manifest. It does not import manager
or provider code from a user-editable repository.

Tests cover kernel peer identity, request authorization, foreign IDs, refused
arbitrary mutations, actual socket framing, unavailable broker behavior,
package tampering and runtime isolation checks. An installation artifact test
redirects every destination into a disposable directory and simulates privilege
checks. It does not establish real installed ownership or prove an activated
root service. Actual root-to-user volume creation, terminal cleanup, restart
recovery and measured disk reclamation still require installed-host acceptance.

The system `/usr/bin/python3` shim can select a user-owned Xcode installation.
Installation refuses that interpreter and checks its actual executable and
import paths before writing files. Apple Command Line Tools must be installed;
the installer never changes Xcode ownership or weakens runtime protection.

## Delivering managed work

New creation requests use `delivery_mode: handoff-ref-v1`. The teammate branch
exists inside the independent image. Terminal capture preserves its exact HEAD
at `refs/richos/handoffs/managed/<manager-id>/HEAD` in the approved source
repository without creating an ordinary source branch. Reusing a teammate name
in another session cannot collide with or overwrite that delivery.

After capture, terminal and reconcile responses include `delivery` with
`manager_id`, `source_repo`, `ref` and `tip`. The reconciler persists that object
in the transaction member before marking storage removed. Storage retirement is
not evidence that the work was merged. Integration obligations still require
landing the exact delivered commit.

The creation helper prints this owner-authenticated query:

```sh
python3 'scripts/lib/managed-workspace-integration.py' delivery --id '<manager-id>' --repo '/absolute/canonical/repo'
```

It refuses while capture is pending and rechecks canonical identity, object
presence and every handoff ref before returning a receipt. Verify the returned
source repository and review its exact `tip`; merge that commit into the intended
integration branch. For example, from the canonical repository, use
`git merge --ff-only '<returned-tip>'` when a fast-forward is appropriate. Follow
the normal reviewed merge procedure otherwise. Never infer the delivery from a
teammate branch name, a current checkout or an arbitrary latest commit.

Creation requests recorded before this delivery mode retain their existing
ordinary-branch publication behavior. This upgrade neither deletes those
branches nor converts their historical receipts. Existing branches require the
explicit frozen maintenance selection. UUID handoff refs remain recovery roots
after image expiry and are not automatically pruned.

Clean recovery expiry requires a complete extended-attribute inventory for the
frozen workspace, including directories, symlinks and Git metadata. Exact
attribute bytes and paths are preserved in the protected manager-owned
`extended-attributes.json` sidecar before image expiry. Its durable filesystem
identity and SHA-256 are checked again before deleting `recovery.dmg`; the
sidecar remains. No attribute-name whitelist discards metadata. Unreadable or
over-budget inventories retain the full recovery image. Inventory is bounded to
100,000 paths and 8 MiB of encoded attribute rows.

The separate `compact-metadata.json` sidecar preserves every path's metadata
and all non-object Git administration bytes, including arbitrary extra files.
Only recognized loose objects and pack/index files may omit bulk bytes, after
owner-credential `git fsck --full` verifies object storage. Unknown files under
`objects/` are preserved too. Existing verified refs and reflogs retain their
Git history; unreachable Git object garbage is not a separate retention promise.
The compact sidecar is limited to 64 MiB and 100,000 paths. Exceeding either
limit or encountering unsupported/unreadable metadata retains the full image.
Multiply-linked files or symlinks, nonzero BSD filesystem flags and extended
ACLs also retain the image. Unknown ACL reads fail closed. The compact format
does not claim to reconstruct link topology, flags or ACLs.
Its exact file identity and hash must also verify before bulk image expiry.

Cleanliness proof version 4 records both requirements. Older classifications do
not authorize expiry; those recovery images remain intact until a separate
verified reclassification is implemented.
