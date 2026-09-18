# Escalation: CEO §55's acceptance (send to "On it!" in a few seconds) cannot be verified today: no time-to-first-text instrumentation exists, and the doctrine steers rather than enforces

- id: `esc-20260918T093934Z-c1ba3985`
- raised: 2026-09-18T09:39:34Z
- from: echo-opus-receipt1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-receipt1` (branch `cc/echo-opus-receipt1`)
- head: `da2213b243fca2032eeda94952ff81783f8f6616`
- state: **work-complete**
- for: lead

## The question

Who builds the send-to-first-visible-text measurement, and does it go in richos-core's stream/spine (outside my footprint) or into Ray's walk harness?

## What was already tried

Implemented §55 in full (receipt is "On it!", doctrine opens with his numbered sequence, register-first in both tool descriptions); measured the app's own share of Ray's 32.432s wait at 9.50ms median = 0.0293%, so 99.97% is model round trips; grepped richos-core, ui/ and ledger.rs for any first-text timing and found none; confirmed tests/doctrine_sentinel.rs's own doc states the doctrine is 'a preference, not an enforcement'; Ray's candidate-.8 walk (7729032e) cannot start, screen locked

## Proceeding meanwhile

All six jobs are committed on cc/echo-opus-receipt1, 1229 tests green, cargo check clean. Nothing else in the slice depends on this answer.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T093934Z-c1ba3985`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T093934Z-c1ba3985 --disposition "<what you decided or did>"
