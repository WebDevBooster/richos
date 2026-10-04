# Escalation: Hear it: the review host already serves the chime; Android's Hear it is shown only on has_audio and has no handler

- id: `esc-20261004T095945Z-852bbc25`
- raised: 2026-10-04T09:59:45Z
- from: isaac-opus-review2
- worktree: `/Users/alex/ab/richos-wt/isaac-opus-review2` (branch `cc/isaac-opus-review2`)
- head: `6fc15c3973a60adb9cacda3c34b3117af5663bcf`
- state: **proceeding**
- for: lead

## The question

None needed from me now. For Andy: should Android get the same Hear it fix (show it when the Mac offers audio, and handle UiEvent.HearReply by fetching GET /api/audio and playing it)? Today Android never shows Hear it against a real Mac or the review host, and if it were shown, tapping it would do nothing.

## What was already tried

Read the code. Review host: src/host.mjs:825-831 already serves the chime for every finished Rich row, test/host.test.mjs:203-205 already proves it, and host.mjs:181 advertises audio as a real Mac does (app/src-tauri/src/phone/routes.rs:642). A real Mac sends has_audio false on every row (phone/rows.rs) and synthesizes any reply on request. Android: ScreenModel.kt:381 shows Hear it only when row.hasAudio, and UiEvent.HearReply (UiEvent.kt:45, sent from Bubbles.kt:471) is handled nowhere in native-android.

## Proceeding meanwhile

iPhone fix follows the reference client's rule (web/web-app/app.js:854, has_audio OR the Mac offers audio), so the review host needs NO change and I made none: setting has_audio true there would put a dead Hear it under the demo reply on Android, on both review hosts. Android untouched, as briefed.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261004T095945Z-852bbc25`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261004T095945Z-852bbc25 --disposition "<what you decided or did>"
