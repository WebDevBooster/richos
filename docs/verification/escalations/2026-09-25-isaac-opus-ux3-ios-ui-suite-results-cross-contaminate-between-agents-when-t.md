# Escalation: iOS UI suite results cross-contaminate between agents when the simulator lease expires mid-run

- id: `esc-20260925T014934Z-0a4bf206`
- raised: 2026-09-25T01:49:35Z
- from: isaac-opus-ux3
- worktree: `/Users/alex/ab/richos-wt/isaac-opus-ux3` (branch `cc/isaac-opus-ux3`)
- head: `e38206af6a276a2e5ac01d17c69568d7b68fc680`
- state: **proceeding**
- for: lead

## The question

Should every iOS UI suite result from today be treated as unattributable until zach-opus-lease1's lease fix lands, since an expired lease lets another run take the same prepared simulator mid-run and the first run then executes the other checkout's test bundle?

## What was already tried

My full native-ios-ui run (cache run.Ixp8v1) reported a failure in testADialogHidesTheConversationFromVoiceOver, a test that exists only on cc/isaac-opus-ux2; the error paths are /Users/alex/ab/richos-wt/isaac-opus-ux2/.../AccessibilityLayoutTests.swift:97. The CPU guard logged 'Device lease ended; owned device stopped' for CC65FD04 during the run, then xcodebuild printed 'Restarting after unexpected exit' repeatedly. Earlier the same device passed from my run to isaac-opus-pwait1's (pid 38279) while my test was still running.

## Proceeding meanwhile

Reporting my own UI proof from scoped runs whose logs show only my test bundle, and marking the full native-ios-ui suite NOT green

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260925T014934Z-0a4bf206`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260925T014934Z-0a4bf206 --disposition "<what you decided or did>"
