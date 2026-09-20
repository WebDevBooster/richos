# Escalation: The missing 'On it!' is not a defect: Ray's six sentences were 'reply with exactly: X', which the signed-off doctrine says must NOT get 'On it!'

- id: `esc-20260920T070243Z-88c69032`
- raised: 2026-09-20T07:02:43Z
- from: echo-opus-onit1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-onit1` (branch `cc/echo-opus-onit1`)
- head: `9998f318e6504042fcbbc5875004d834ea108e29`
- state: **proceeding**
- for: ceo

## The question

Does §55's 'On it!' cover turns the front desk answers DIRECTLY (a question it knows the answer to), or only turns it hands work over on? The doctrine currently says answer directly and say nothing else, and the code enforces that.

## What was already tried

Re-derived the audit and the code. (1) The six sends in docs/verification/2026-09-20-nightly-1.2.0-nightly.20260920.1-mac-to-phone-in-the-vm-audit.md:551,301 were 'reply with exactly: ray nine one'..'five' and 'ray nine phone six' - NOT tasks. The brief calls them 'add a line to notes.txt...'; the string notes.txt does not occur in that audit. (2) crates/richos-core/doctrine/front-desk.md lines 25-27 (QUESTION case 1) says: 'You know the answer. Answer him. Nothing is written down, nothing is handed over' - so zero 'On it!' on those six turns is the prescribed behavior, not a bug. (3) crates/richos-core/src/first_reply.rs:296 already asserts a no-tool-call answered turn has NO faults ('the best case'). (4) crates/richos-core/src/assignment_tools.rs:844 asserts the OPPOSITE of the brief: 'a question got the task reply' is a FAULT. Making every send say 'On it!' would invert a landed, tested invariant. (5) Ray himself wrote at audit line 288-290 that this is 'a design call, not mine'. (6) Brief item 2 - status band only after the first words - would leave the screen blank for the 10.5-14.5s Ray measured to first words; ui/main.js:2399-2406 records that the band exists because the first outside user called a blank wait 'a crashed application' (2026-09-06).

## Proceeding meanwhile

Fixing the part that IS a measured defect and does not depend on the answer: Ray's Defect 2 (audit line 388-396) - 'Nothing has come back yet' is the band's LAST line and held 10.8/10.5/12.7/14.5/13.0 s on five healthy turns. Dropping the absence report before the 35 s quiet threshold, per Ray's own proposal, plus the owning ui suite (ui/tests/waiting-state.js) and a richos-core test pinning the doctrine-correct contract.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260920T070243Z-88c69032`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260920T070243Z-88c69032 --disposition "<what you decided or did>"
