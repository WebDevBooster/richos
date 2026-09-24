# Escalation: Android idle redraw Rich measured is the Reconnecting pulse, a designed animation; stop it after a while or keep it?

- id: `esc-20260924T001746Z-9a147770`
- raised: 2026-09-24T00:17:47Z
- from: andy-opus-idle1
- worktree: `/Users/alex/ab/richos-wt/andy-opus-idle1` (branch `cc/andy-opus-idle1`)
- head: `c4f41e7f9eb537e618cd6d1161e0253ee88d0611`
- state: **proceeding**
- for: lead

## The question

The ~30 fps / ~870% qemu Rich measured is reproduced exactly by the round-12 Reconnecting pulse (8 dp dot, alpha 0.35-1, 700 ms) which runs for as long as the Mac is unreachable: e45d301f, production core paired to an absent Mac, 31.5 fps, app 27% + composer 46% in-emulator, emulator 675% host CPU; with animations off, 0 fps. iOS has the same indefinite PulseDot (ConversationChrome.swift:94-106). The brief's premise 'nothing moving' is false: the dot was moving. Keeping it is within the brief's rule (runs only while its state is on screen). Should the dot stop pulsing and rest at full opacity after N seconds of Reconnecting (a visible change, a design call for Urban), or stay as designed?

## What was already tried

Every at-rest screen (pairing intro, empty and paired conversation, both themes, 12 more) measured 0 fps on the emulator and 0 busy frames in the JVM; the scanner's live camera is 44 fps / 837% (expected while scanning, released on close).

## Proceeding meanwhile

Fixed the real idle bugs found on the way (an unsettled too-short/ceiling voice ending left the mic dead and the store publishing 10 states/s forever), regression tests, after-measurement; the pulse is left exactly as designed.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260924T001746Z-9a147770`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260924T001746Z-9a147770 --disposition "<what you decided or did>"
