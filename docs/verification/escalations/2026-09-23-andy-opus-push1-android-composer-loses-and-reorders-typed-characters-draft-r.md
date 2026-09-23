# Escalation: Android composer loses and reorders typed characters (draft round-trips async through the core)

- id: `esc-20260923T220752Z-d44d773a`
- raised: 2026-09-23T22:07:52Z
- from: andy-opus-push1
- worktree: `/Users/alex/ab/richos-wt/andy-opus-push1` (branch `cc/andy-opus-push1`)
- head: `4edbfce13832862fbcb5bc00a3d34b814e854ca8`
- state: **proceeding**
- for: lead

## The question

Who fixes ui/composer/Composer.kt (outside my ownership)? The field needs local TextFieldValue state (or TextFieldState) as the source of truth, with the core's draft synced from it, not a String value that comes back asynchronously.

## What was already tried

On emulator-5580, debug build of main 4edbfce1, typing one character per adb input event into Message Rich: 'zulu' was sent as 'uluz', 'Killed check' as 'illed checkK', and 'Background check one' as 'aBk' (Mac timeline confirms the received text). Composer.kt:142-144 BasicTextField(value = draft, onValueChange = { onEvent(UiEvent.Draft(it)) }); AppStore.dispatch launches a coroutine, so value lags the keystroke.

## Proceeding meanwhile

Not fixing it (ui/ is not mine). Continuing push and Share to Rich proofs.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260923T220752Z-d44d773a`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260923T220752Z-d44d773a --disposition "<what you decided or did>"
