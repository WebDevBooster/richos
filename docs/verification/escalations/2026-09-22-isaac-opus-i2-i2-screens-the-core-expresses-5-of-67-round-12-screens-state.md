# Escalation: I2 screens: the core expresses 5 of 67 round-12 screens; state, actions, fixtures and a unit-test target requested from I1

- id: `esc-20260922T204203Z-94837777`
- raised: 2026-09-22T20:42:03Z
- from: isaac-opus-i2
- worktree: `/Users/alex/ab/richos-wt/isaac-opus-i2` (branch `cc/isaac-opus-i2`)
- head: `5768bd5bcd7af23ff54a1a4b6c462182f1a1a067`
- state: **proceeding**
- for: lead

## The question

Please relay richos/mobile/native-ios/App/Features/CORE-REQUESTS.md (commit 5768bd5b on cc/isaac-opus-i2) to Isaac (I1): the AppState fields, Actions, voice-gesture machine, 63 named fixtures, a RichOSNativeTests unit-test target in project.yml, and the one-line composition seam. Also: Isaac's escalation esc-20260922T201702Z-243eff65 asks whether he builds tokens/conv-empty/UI test in App/Design, App/Features, UITests; I2 has started on all three, so he need not.

## What was already tried

Read Core at 48604d6a: AppState.screen has five cases; Reducer persists on every state change (voiceMove would write state.json per touch).

## Proceeding meanwhile

Building the design system and every screen against a Features-side ScreenModel; screens not yet expressible in AppState are reached through a Debug-only -rios-screen catalog, replaced by core fixtures as they land.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260922T204203Z-94837777`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260922T204203Z-94837777 --disposition "<what you decided or did>"
