# Escalation: The same false green was in check 15 too, not only check 18 — matShot is shared and its numbers were corrupted

- id: `esc-20260905T130346Z-eb626cf0`
- raised: 2026-09-05T13:03:46Z
- from: echo-opus-m18
- worktree: `/Users/alex/ab/richos-wt/echo-opus-m18` (branch `echo-opus-m18`)
- head: `93df17f8b553d5c85935927b4cd9bf2321eb9edd`
- state: **work-complete**
- for: lead

## The question

Is there a standing list of every check that photographs the curtain, or is 'grep the shutter helpers' the only way anyone finds the next one?

## What was already tried

Verified the brief's characterization from the code first: matShot's guard is byte-for-byte the DOM-presence test check 5 was green over, and the class is distant rather than unreachable because matShot never disarms the ceiling. Measured shutter 2,304-2,336ms, ceiling armed 6,000ms, margin 3,664-3,696ms (not 3,800 - that is the nominal wait, not the shutter). splash--yielding at 6,001-6,024ms, node gone 220-223ms later against 220 derived. Reproduced with RICHOS_SPLASH_SHUTTER_LAG_MS=3720: old guard GREEN, filed material-round-11-v1.png at 62,346 distinct colors against the mat's 2,951.

## Proceeding meanwhile

Fix landed as briefed - guard only, same vocabulary, no third knob, no product byte, no third noCeiling call site. Full suite 23 suites, 444 checks, 0 skipped, 0 failed.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260905T130346Z-eb626cf0`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260905T130346Z-eb626cf0 --disposition "<what you decided or did>"
