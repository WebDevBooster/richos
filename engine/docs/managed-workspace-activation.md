# Managed workspace activation and existing-worktree migration

The protected broker package and the Claude engine are separate installations.
Installing a protected release does not update the engine used by Claude hooks,
creation helpers or the user-level transaction reconciler. Publishing the public
configuration against an old engine is not a supported activation.

On the acceptance host, `~/.claude/richos-engine` still points to
`/Users/alex/ab/richos/engine`. That canonical checkout has not received this
candidate. The isolated canary uses a pinned copied engine and substitutes only
its protected configuration location. Passing it does not establish that the
operator's registered engine or an already running Claude session has upgraded.

## Rollout order

These are operator steps after authorization. They have not been executed by
writing this document. Keep the public `client.json` and published LaunchDaemon
absent until the prerequisites below pass.

1. Complete the reviewed acceptance and land the candidate in the canonical
   RichOS checkout. Record the landed commit and the accepted source snapshot.
   Coordinate existing sessions before changing their shared hook code. Do not
   repoint the machine-wide engine registration at a temporary worktree.
2. From the canonical engine, run `scripts/hooks/install.sh` as the normal
   operator. This refreshes hook hash sidecars and installs and verifies the
   user-level `com.richos.worktree-reconciler` job. It must exit successfully;
   a message that the pointer or reconciler was withheld for a sandbox or linked
   checkout does not satisfy production installation. Do not use
   `--force-engine-pointer` to bypass this distinction.
3. Verify what the host actually resolves. Run `scripts/locate-engine.sh` with
   fixture overrides such as `RICHOS_ENGINE_ROOT` and `CLAUDE_PLUGIN_ROOT` unset.
   Its operator registration chain and `~/.claude/richos-engine` must agree on
   the canonical engine. Run `scripts/hooks/contract-integrity-probe.sh` in each
   adopted repository, using the intended entity context, and resolve failures.
   Check the registration and content-hash results, including pointer agreement;
   the presence of freshly generated sidecars alone is not acceptance.
4. Compare the installed canonical hook, helper and library bytes with the
   accepted engine snapshot. In particular, verify managed preparation,
   `managed-image` binding/sealing, terminal routing, exact delivery and the
   reconciler are present. Compare every overlapping protected runtime module
   against the accepted root release manifest as well. A matching version label
   or existing file is insufficient. Inspect
   `launchctl print gui/501/com.richos.worktree-reconciler` on this host and
   verify its program names the canonical reconciler and its transaction stores
   are the operator's intended stores, not canary paths.
5. Restart Claude sessions whose hook, plugin or agent settings were loaded
   before rollout, after their active work is safely handed off. Confirm the
   effective loaded engine and absence of duplicate lifecycle hook registration.
   Refreshing the root daemon does not refresh Claude's settings snapshot.
6. Recheck the exact approved root policy, release manifest, pending plist and
   pending public configuration. Publish only the reviewed pending plist under
   `/Library/LaunchDaemons/` and load that exact service. Before publishing
   `client.json`, use the approved owner's client to verify kernel peer
   authentication, expected repository aliases, completed sweeps and usable
   lifecycle status. Inspect unresolved records rather than treating listener
   availability as whole-system health. The required installed privilege and
   lifecycle acceptance must already have passed for these bytes.
7. Publish the reviewed `client.pending.json` as `client.json` only after both
   the live engine and the daemon checks pass. Verify ordinary configured lookup
   in `richos`, `richos-hq` and `femcboost` resolves their exact approved aliases.
   Confirm the first authorized managed assignment uses its manager UUID and
   that actual terminal hooks, the normal broker timer and the user reconciler
   persist its exact delivery and reclaim its active image. Complete the normal
   reviewed merge of the returned commit. Record this live configuration check
   separately from the copied-engine canary.

There is currently no production activation command that enforces this entire
sequence. The installer only stages pending files and refuses already published
service artifacts. A manual copy into `LaunchDaemons` or to `client.json` bypasses
rollout ordering, so those writes must remain in the final reviewed activation
operation. An unavailable enabled broker must remain a visible failure; removing
`client.json` to silently resume unmanaged creation is not a recovery procedure.

## Existing directories and branches

Activation changes future external creation. It does not convert existing
linked worktrees, delete old branches or arm a maintenance job. Claude continues
to own normal native cleanup. A native leftover and a legacy external directory
still share mutable Git state with their canonical repository.

For each real backlog, first create a read-only inventory using the protected
legacy administrator interface and the exact operator history sources. Account
for every registered checkout, including missing and nested native paths, and
for any currently active worktree. Agree on repository downtime before staging
the reviewed complete gate. Arm only the exact approved candidate and branch
selection. A later machine boot supplies the write cutoff; restarting Claude
alone does not. The enabled broker then advances that fixed job automatically
through capture, Git object preservation, removal and restoration. Failed jobs
retain their gate and expose their phase for replay. A retry cannot broaden the
approved selection.

Ordinary existing branches are retired only through that frozen selection.
Future managed workers avoid this source-branch backlog by delivering through
UUID refs. Removing a workspace is not evidence of a completed merge.

Legacy recovery archives currently remain retained without automatic expiry.
The executor reclaims the selected active directories and registrations while
preserving a compressed recovery copy and Git recovery refs. Managed clean
images have the configured expiry policy; unique or unclassified working data,
raw failed-creation recovery and legacy archives do not yet have permission or
an implemented proof-based path for automatic archive deletion. Report those
retained bytes separately from bytes actually reclaimed.
