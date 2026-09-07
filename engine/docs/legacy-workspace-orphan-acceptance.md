# Installed orphan and locked-registration integration

`engine/scripts/lib/legacy-workspace-orphan.acceptance.py` is an external test controller, not an installed service or a production cleanup command. A reviewed launcher copies its exact pinned bytes into fresh root-protected staging and invokes protected Command Line Tools Python with `-I -S -B`, an explicit installed release path, the SHA-256 of that release's raw manifest and an already-approved owner UID.

The controller validates the protected interpreter, installed runtime and owner policy before creating fixtures. It does not change installed code, production policy, launchd or public client configuration. Its only selectable repositories are freshly minted tiny acceptance repositories. It accepts no existing gate or repository path.

Three independent cases exercise the unchanged installed planner, capture, recovery-ref publisher, journaled job, selective retirement and restoration implementations:

- A readable locked terminal checkout must retain its lock, staged index and original working bytes in recovery, then lose its exact registration and terminal branch.
- An absent terminal checkout must produce an explicitly admin-only archive. It must preserve the original index and dependencies without claiming that absent working files were recovered.
- A missing path recreated after gating must stop capture and retirement. Restoration must preserve those new bytes, the old registration and the terminal branch.

Positive cases run immediate Git garbage collection as the fixture owner, require an unpinned control blob to disappear and require the uniquely staged blob plus every captured object dependency to survive. Restored canonical inode, filesystem identity and permission pins are checked. Successful job replay must remain unchanged.

## Cutoff limitation

This controller reports `tests_cutoff: false` even when all integration checks pass. The separately recorded actual reboot acceptance remains the evidence for the production reboot cutoff and durable filesystem UUID behavior.

Every fixture stages under its real current boot. Before the seam, the real gate must deny frozen access and its job must remain waiting for boot. An actual unprivileged owner process must fail to open the root-protected held bytes.

For direct controller advancement only, that single in-process `LegacyGate` instance observes a synthetic later-boot UUID. The instance override is removed even when a check fails. The original journal's `gated_boot_id` remains the actual boot. No global module, kernel identity or installed file changes. This is a disclosed integration-test seam, not evidence that all earlier writable handles were revoked.

Its journals live under `<fresh-private-fixture>/controller-only-gates`, never the production or fixture service's `legacy-gates` discovery path. No broker is started for these cases. The durable fixture receipt marks `controller_only: true` and `production_service_eligible: false`; this historical test evidence must never be moved into a production gate inventory.

There is no cleanup API. Both successful and failed fixtures are retained with their receipts. The output explicitly reports `fixture_cleanup_complete: false`. A failed gate is held for diagnosis, never restored by pretending the synthetic boot was an actual reboot outside this controller.

## Evidence status

Focused disposable tests exercise the controller seam, complete tiny Git archive/retirement flows and the recreated-path refusal. They are neither administrator acceptance nor a second real reboot run. Installed execution remains a separate reviewed, pinned launcher action.
