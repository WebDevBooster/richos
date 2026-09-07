# Legacy workspace maintenance planning

`scripts/lib/legacy-workspace-maintenance.py` creates a read-only review artifact for an eventual offline migration of existing linked worktrees. It does not gate access, kill processes, modify Git or remove data. Every report sets `execution_ready` and `execution_authorized` to false. Legacy automatic disk reclamation is not implemented by this planner.

Supply explicit approved repository aliases in a JSON policy:

```json
{"repositories":{"example":{"path":"/absolute/canonical/checkout"}}}
```

Run with `--policy /absolute/policy.json` and repeat `--active-path /absolute/worktree` for known ongoing work. Repository policy from the managed broker has compatible repository entries. The CLI reads strict transaction and ledger history through the existing terminal branch planner. Missing or malformed history is reported as a blocker. Exit status zero means the review inventory has no reported blockers, never permission to execute maintenance.

For each approved canonical checkout, the report lists all registered linked worktrees and the shared Git directory. `gate_paths` contains every workspace that would need to be offline, including active workspaces that are not removal candidates. It records path device/inode/ownership/mode, working HEAD and branch, Git admin identity and the Git pointer contents. It checks these identities and the full registry again before completing the inventory. An unreadable workspace remains in the report while other registered paths are inspected. `inventory_complete` describes only this bounded inventory, not exclusive access or ownership certainty.

`temporary_parent_gates` records the exact parent inode/mode and all child entry names whose access would be interrupted briefly during relocation. This includes unrelated sibling repositories. The approved report must cover that wider downtime scope; a changed sibling namespace invalidates the report.

An absent linked checkout can be an explicit `orphan-registration` target when its surviving Git administration files and exact terminal history agree. The planner pins the nearest existing ancestor and the absent path suffix, including a missing parent container. It validates the admin `gitdir`, `commondir`, HEAD and branch without constructing a checkout. A readable locked registration is also eligible for review when exact terminal ownership is established. Missing or locked registrations with live, unknown or mismatched ownership remain blockers. Orphan targets stay in the logical inventory but contribute no nonexistent physical gate root; the entire canonical/common Git store still requires the gate.

`removal_candidates` is separate. It requires an exact sealed terminal transaction member with matching canonical repository, worktree, branch and captured HEAD. Terminal membership is evidence for later review, not deletion authority. Live or unknown ownership still blocks maintenance. Process checks include resumed incarnations of the same recorded session even when that incarnation was recorded on another path. Unrecorded editors, shells and writers remain possible after those checks.

The planner refuses symlink path components, malformed registration, unknown repositories, policy pointing to a linked checkout and overlaps between different approved repository identities. Native worktrees nested inside their own canonical checkout retain separate entries in `gate_paths` while `gate_roots` consolidates their physical move under the canonical ancestor. Each target records its root and relative path. A removal candidate also lists contained registered targets; selective retirement must not remove a parent while retaining a nested target. Bare repositories also require a separate design. It never silently collapses these cases into an apparently complete maintenance gate.

Object alternates, promisor packs and partial-clone configuration require separate dependency review. Symlinks or device boundaries anywhere under the object directory also produce blockers. This scan does not follow those paths because the common Git directory alone does not cover an external mutable object store. The report does not approve or recursively discover additional repositories from those files.

Safe eventual legacy reclamation requires a protected gate covering the entire canonical repository, shared objects/admin and every linked worktree before a reboot. The gate must persist across reboot. A subsequently verified different kernel boot closes old writable file descriptors, queued descriptor transfers and mappings. Starting a daemon before user login is not a substitute for establishing that gate beforehand. Capture and verification would then happen while the gate remains in place, before reopening repositories. That executor and its installation acceptance are separate work.

Existing active work must finish before any such gate can be authorized. Passing its exact path with `--active-path` records an explicit live-owner veto. This planner can be run while work continues because it performs only reads. Its snapshots must be repeated after separately authorized downtime; they are not reusable approval tokens.
