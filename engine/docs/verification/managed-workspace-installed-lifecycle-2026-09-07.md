# Installed broker lifecycle acceptance

On 2026-09-07 the protected package at source `cd6205c` passed all 26
installed macOS checks. All disposable storage was removed. Production
`client.json` remained absent and launchd was not started.

The original root-to-owner volume checks passed again: private backing storage,
busy-file retention, preserved working and staged bytes, refused owner-forced
unmount, verified recovery, active-image reclamation, refused dirty expiry and
successful clean expiry.

The additional checks used the actual installed broker and approved owner's
socket client against only newly created tiny repositories and private roots.
They verified server/peer identity, legacy worker inventory, idempotent creation,
worker binding and terminal acknowledgment, unused-preparation cancellation and
reclamation by the normal timer. No reconcile request drove this cleanup.
Both active images disappeared and their recovery images were retained.

The broker then exited cleanly through the same native administrator launcher
that had exposed the inherited signal-mask failure. This closes the installed
shutdown finding recorded in the [earlier failed run](managed-workspace-broker-shutdown-2026-09-07.md).

This does not establish actual Claude agent spawning, production launchd boot
activation or directory-based legacy retirement across a real reboot. Those
remain separate acceptance steps. The [structured receipt](managed-workspace-installed-lifecycle-2026-09-07.json)
records the installed release and every check.
