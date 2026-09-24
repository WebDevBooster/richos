# Escalation: Review mock (landed c5f04574) replays the corpus and must adopt pair-v2 before cc/echo-opus-pair2 lands green

- id: `esc-20260924T023438Z-b485bb5a`
- raised: 2026-09-24T02:34:38Z
- from: echo-opus-pair2
- worktree: `/Users/alex/ab/richos-wt/echo-opus-pair2` (branch `cc/echo-opus-pair2`)
- head: `156ec2eff8131b4a4403c3202543397347981715`
- state: **work-complete**
- for: lead

## The question

Who adapts richos/mobile/review-mock to pair-v2 and the press on the Mac (Sage M3): Mark in a follow-up after this branch lands, or should Echo add it to cc/echo-opus-pair2 first?

## What was already tried

Built Sage 3.1-3.5 on the Mac, sheet, PWA and corpus; the review mock merged into main after the brief and its conformance test compares its pair answer to pairing.json, which now carries pairing_version 2, confirm_within_seconds and the pair-v2 capability. review-mock.test.sh: 159 pass, 1 fail (the recorded pairing answer's keys).

## Proceeding meanwhile

Branch is committed and handed off; the mock is untouched because advertising pair-v2 without the v2 words and the Mac-side press would be the M3 violation Sage names.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260924T023438Z-b485bb5a`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260924T023438Z-b485bb5a --disposition "<what you decided or did>"
