# Escalation: The brief's acceptance number (6.995 s) is built from run E's TURN, and run F had already measured that turn at 7.279 s before this slice existed

- id: `esc-20260918T211227Z-3090aa18`
- raised: 2026-09-18T21:12:27Z
- from: echo-opus-primed1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-primed1` (branch `cc/echo-opus-primed1`)
- head: `006968179c379c8a6152f498bccc5fe5e54e1f3c`
- state: **work-complete**
- for: lead

## The question

Is 'send -> first words with ZERO prime in it' the right acceptance for this slice, given the turn itself is ~7.3 s on this provider today and no code in this slice touches it?

## What was already tried

Built the pre-primed front desk and measured it on the real provider (run I): the prime he waits for is 0.000 s and his thread is primed 0 times, against run F's 2.368 s and 1 time on e2c59243. send -> first words is 7.263 s, of which ALL is the turn. The brief's target was 6.995 s = run E's 5.995 s task turn + 1 s. But run E's turn and run F's turn differ by 1.284 s on the same sentence and the same path, and run F (7.279 s) and run I (7.263 s) are within 16 ms of each other on either side of every line I wrote. So the target was a total scored against a term this slice cannot move, and it was already unreachable on e2c59243. The sendlock record's own 2.3 refuses to conclude anything from run F against run E for exactly this reason. I scored the probe on the prime being gone (zero, not a threshold) and REPORT the total with run E/F beside it.

## Proceeding meanwhile

Everything else in the brief is done and committed: items 0-5 decided from measurements, the spare built, 15+2 new headless tests, each half proven red on its own, and the idle cost measured with ps rather than estimated.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T211227Z-3090aa18`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T211227Z-3090aa18 --disposition "<what you decided or did>"
