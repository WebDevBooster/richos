# Escalation: The nightly's B2 failure was the Mac's screens being asleep, not the voice land — and an unattended nightly still cannot pass while they sleep

- id: `esc-20260917T023813Z-47fe6238`
- raised: 2026-09-17T02:38:13Z
- from: echo-opus-guiboot1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-guiboot1` (branch `cc/echo-opus-guiboot1`)
- head: `d899399b912ace505714506cdf20d029b3cc2773`
- state: **work-complete**
- for: ceo

## The question

For an unattended nightly: may it hold the screens AWAKE for its GUI-boot phase (caffeinate -u turns the CEO's displays ON — a visible side effect on his desk at 3am), or should it refuse with exit 2 until someone runs it with the screen already awake?

## What was already tried

Ran the SAME source 516975db that failed twice: all 29 passed at 02:25-02:27Z with the screens awake. pmset -g log has the displays off 01:33:47Z-02:16:29Z, which contains both failures and neither pass. available_monitors() is CGGetActiveDisplayList (tao-0.35.3 macos/monitor.rs:146) and macOS drops a SLEEPING display from the ACTIVE list, so the app reported the truth. Pre-voice control 4e34e27d also passes. Evidence: docs/verification/gui-boot-display-precondition-2026-09-17/.

## Proceeding meanwhile

Landed the honest fallback the brief asked for: the suite now measures the host first and refuses BY NAME (exit 2, with the repair) instead of failing B2 over the power state of a screen; four cases D1-D4 hold that gate to account and D4 prints this host's answer on every run. B2 itself is untouched. Branch cc/echo-opus-guiboot1, all 33 passed.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T023813Z-47fe6238`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T023813Z-47fe6238 --disposition "<what you decided or did>"
