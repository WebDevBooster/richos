# Escalation: Android D3 twin fixed (richos 00e11935b on cc/andy-opus-hidden1), but the Honor check cannot run: the Honor is not attached to this Mac

- id: `esc-20261001T141746Z-ec7d64e2`
- raised: 2026-10-01T14:17:46Z
- from: andy-opus-hidden1
- worktree: `/Users/alex/ab/richos-wt/andy-opus-hidden1` (branch `cc/andy-opus-hidden1`)
- head: `00e11935be3f0d7c9aecd0f32ff2a7cd387fba3b`
- state: **proceeding**
- for: lead

## The question

Can someone plug the Honor into this Mac by USB, unlocked, and tell andy (or the next Android agent) it is attached, so the one real-app check (send, Home, lab paused and released after Home) can run?

## What was already tried

adb devices -l lists nothing (/opt/homebrew/bin/adb 37.0.0). system_profiler SPUSBDataType shows only the iPhone on USB. adb mdns services finds nothing. No private adb server is listening on port 5039 (the wireless route recorded in richos-hq docs/verification/2026-09-24-native-acceptance-r1/README.md, Round 2, which itself needs USB first to turn wireless debugging on). Turning on wireless debugging or unlocking the phone needs a person at the phone, so I did not try anything further.

## Proceeding meanwhile

The fix is done and committed: richos 00e11935b on branch cc/andy-opus-hidden1 (worktree /Users/alex/ab/richos-wt/andy-opus-hidden1). OutboxTest.aFaultWhileHiddenGoesAgainInsideTheBound is red on main (one try, message left waiting) and green on the branch; OutboxTest 23 of 23 green. Only the Honor check is outstanding: build and install from the branch, send one message in the app, press Home, with the isolated lab (richos/mobile/dev/mac-server.mjs) held silent by qa/lab-pause.py from just before Home until about 1 s after Home, then lab-ledger.py must count the message exactly once while the app is still hidden.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261001T141746Z-ec7d64e2`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261001T141746Z-ec7d64e2 --disposition "<what you decided or did>"
