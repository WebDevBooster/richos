# Small installed legacy gate and reboot acceptance fixture

Status: the three-phase driver is implemented. Its installed privileged run remains pending. No production legacy gate or real reboot was executed while developing it. The installed broker/volume acceptance does not establish this separate boundary.

The smallest useful fixture is one new tiny canonical Git repository and one external linked worktree, owned by the approved local account. Both live in a fresh source namespace, with a separate private gate namespace. No existing repository, native Claude worktree, public client configuration or launchd service needs to be touched.

Use a freshly minted `legacy-acceptance-<UUID>` suffix under the installed private and active roots. Resolve the roots before building any path: on this host `/var/db` resolves to `/private/var/db`, and the planner deliberately rejects symlink path components. Use:

- `<resolved active root>/<nonce>/sources/repo` and `sources/worker` for the only Git paths.
- `<resolved active root>/<nonce>/history/transactions` and `history/ledger.jsonl` for explicit fixture history, readable by the approved owner.
- `<resolved private root>/<nonce>/legacy-gates` for the root-owned mode-0700 gate vault.
- `<resolved private root>/<nonce>/policy.json` for the root-protected fixture policy.
- `<vault>/<gate UUID>/job-scratch` for the existing job runner's private archives.

All roots must have exact recorded inode/device identities, protected ancestors, no extended ACLs and the same filesystem. Source creation and all normal Git writes run as the approved UID/GID with no supplementary groups, no templates and no global/system Git config. The fixture policy approves only this owner and this fixture repository. The owner's real account home remains in `inspection_context`; only the history paths are redirected. No real `.claude/state` file is read or changed.

## Phase 1: prepare a reviewable fixture, without gating

The protected `legacy-workspace-acceptance.py prepare --owner-uid UID` driver creates one commit, a linked `worker` branch at that commit and a small file with distinct committed, staged and working contents. Add one untracked file, one symlink, an xattr and a cache tag with unique bytes beneath it. Record the expected bytes and object IDs in a private, fsynced receipt. A completed disposable owner process supplies the fixture's recorded PID/start identity and terminal transaction; the history files remain strictly valid inputs to the normal iterator.

Generate the plan through the installed `legacy-workspace-gate.owner_report(policy, inspection_context)`. This runs repository/history inspection as the explicit unprivileged owner. Require a complete plan with no blockers and only the minted source paths. Save its exact digest and full temporary-parent downtime scope. Nothing is staged at this point.

The existing admin CLI reads the installed production policy and has no fixture-policy override. Do not add fixture aliases to that policy. The driver imports the existing libraries and passes the root-protected fixture policy explicitly, following the installed broker acceptance pattern. It must be included in the reviewed package manifest before running. Every later invocation validates the exact installed release hashes recorded at preparation; replacing that release requires a new fixture.

## Phase 2: exact fixture gate before the reboot

Start an unprivileged fixture helper with an already-open writable descriptor to the working file and an already-open directory descriptor. It is an intentionally unrecorded holder, separate from the completed recorded worker. It must only access the fresh fixture paths. Save its actual process identity for this boot; never treat the numeric PID alone as authority after reboot.

Using the approved plan hash, construct `LegacyGate(vault, inspection_context=context)` and call `stage(report, approved_sha256=plan_hash)` with normal production root checks enabled. Do not patch `_boot`, `require_root`, filesystem identities or command execution.

The driver arms the exact candidate/branch job and requires these actual checks before any reboot:

1. The source paths moved to the private gate and the same pinned inodes are held there.
2. The owner cannot newly open the held file, change its permissions or create a new file through the old directory descriptor.
3. The old writable descriptor can still write a final unique marker, which root reads from the held inode. This demonstrates why permission changes alone are not deletion authority.
4. `inspect` reports no boot cutoff, `frozen_view` refuses and a same-boot armed job remains `waiting-for-boot` without an archive, recovery-ref publication or deletion.
5. The fixed per-gate job scratch remains empty. This phase uses the actual job API directly and does not claim broker status acceptance.

Invoke `stage --acceptance-id ID --approved-plan-sha256 HASH` with the ID and plan hash printed by preparation. The driver persists the exact job selection, original kernel boot UUID, expected bytes and fixture identities before reporting readiness for reboot. No source or archive deletion occurs in this phase. The old-descriptor fixture helper remains alive until the actual reboot. Its process identity is recorded only for the original boot. An interrupted stage records matching reserved gate IDs and remains failed for explicit recovery; rerunning stage cannot reserve a second gate or invent successful permission checks.

## Phase 3: after a separately authorized real host reboot

Invoke `resume --acceptance-id ID --approved-plan-sha256 HASH` against the exact prior receipt. The driver accepts no arbitrary receipt, repository, history or gate path. First require a different valid `kern.bootsessionuuid`; never substitute a mocked boot, process absence or elapsed time. Do not signal the old numeric PID. Boot identity supplies the cutoff for all old descriptors and mappings.

Start the actual installed broker as a disposable subprocess with `--policy <fixture policy>` and a socket inside the fixture active root. Its `LegacyMaintenanceService` must discover the existing armed job from the fixture vault. Poll through the installed client as the approved owner until the service completes capture, additive object handoff, worktree/admin retirement, exact branch retirement and canonical restoration. Manual post-reboot broker launch verifies service discovery and execution after real kernel restart; it does not claim launchd boot activation has been tested.

Verify the final state directly:

- The original canonical repository is restored with its original owner/modes and expected main commit.
- The selected worker directory and only its linked Git registration are gone, and its branch has the expected recovery backup.
- The retained archive contains the exact staged index, final late-written working bytes, untracked data, symlink and xattr. Cache-tagged unique bytes were preserved.
- Recovery refs retain the staged-only blob and every captured object dependency through isolated immediate Git GC, while an unpinned control object is pruned. Resolve-undo coverage remains in the separate retirement suite; this smallest installed fixture does not seed a conflict.
- The fixture job is durably complete, repeated advancement is idempotent and owner status names no production repository.

The driver stops and waits for the disposable broker, then retains its tiny generated sources, archive and journals for review. It has no cleanup API and reports `cleanup_authorized=false`, including on success. A failed or incomplete pre-reboot run remains available for explicit fixture recovery. It must not borrow the unrelated managed-image acceptance cleanup routine. No old numeric PID is signalled after reboot.

## Actual outstanding requirements

The driver is implemented with disposable tests of preparation, immutable scope, interrupted staging, real archive/GC verification and simulated-boot routing. Those tests do not establish root revocation or real reboot authority. Packaging, installed preparation and the actual two-boot run are still pending. The installed run needs macOS root authority and an exact fixture report hash. The agent follows the existing user authorization for isolated fixture work; this document does not add a separate permission flow. A real host reboot remains a distinct user-controlled boundary. Reboot affects the whole host, so active user work must be saved or finished even though only generated repositories are gated. No real repository downtime, migration or cleanup is needed for this acceptance.

Read-only host checks found no immediate ancestor-ACL obstruction: `/`, `/private`, `/private/var` and `/private/var/db` have root-owned non-writable directory modes and no ACL entries. The kernel returns a boot UUID and the canonical `/private/var/db` path is readable. Actual privileged gate revocation and later-boot recovery are still unverified until this fixture runs.

## Invocation boundary

All commands run from the exact reviewed root-owned release, using the fixed interpreter explicitly:

```text
/Library/Developer/CommandLineTools/usr/bin/python3 -I -S -B <release>/legacy-workspace-acceptance.py prepare --owner-uid <approved UID>
/Library/Developer/CommandLineTools/usr/bin/python3 -I -S -B <release>/legacy-workspace-acceptance.py stage --acceptance-id <printed ID> --approved-plan-sha256 <printed hash>
/Library/Developer/CommandLineTools/usr/bin/python3 -I -S -B <release>/legacy-workspace-acceptance.py resume --acceptance-id <same ID> --approved-plan-sha256 <same hash>
```

Preparation does not stage a gate. The middle command verifies the exact printed fixture report hash and confines the armed job to that generated worker and branch. Reboot remains a separate user action after saving active work. The final command refuses an unchanged or malformed boot identity before starting the fixture broker.
