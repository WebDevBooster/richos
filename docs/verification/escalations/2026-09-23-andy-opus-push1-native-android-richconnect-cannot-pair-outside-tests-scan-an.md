# Escalation: Native Android RichConnect cannot pair outside tests: Scan and 'Use a pairing link' both do nothing

- id: `esc-20260923T215657Z-e6edd1d9`
- raised: 2026-09-23T21:56:57Z
- from: andy-opus-push1
- worktree: `/Users/alex/ab/richos-wt/andy-opus-push1` (branch `cc/andy-opus-push1`)
- head: `4edbfce13832862fbcb5bc00a3d34b814e854ca8`
- state: **proceeding**
- for: lead

## The question

Who builds the Android pairing entry (QR scanner platform piece needing CameraX/barcode deps in app/build.gradle.kts, and/or the PAIRING_LINK paste sheet in ui/)? Neither is in my ownership and no real device can pair without one.

## What was already tried

On emulator-5580 (API 34, debug build via with-android-firebase.py, main 4edbfce1): tapped both buttons on pair-intro, UI dump unchanged. Code: UiEvent.ScanCode has no toAction mapping; UsePairingLink -> Action.OpenSheet(Sheet.PAIRING_LINK) but no composable renders PAIRING_LINK (grep: only Settings.kt:49 and UiEvent.kt:127); manifest has no CAMERA permission; MainActivity passes no camera and no pairingSurface. UiEvent.PairWithLink exists but nothing emits it.

## Proceeding meanwhile

Pairing the emulator through a test-only debugger route (no product change), then proving push end to end and Share to Rich.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260923T215657Z-e6edd1d9`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260923T215657Z-e6edd1d9 --disposition "<what you decided or did>"
