# Escalation: Open item 3.3d now has both halves priced, and one of its apparent options is measured to do nothing

- id: `esc-20260910T013157Z-6bdf4aa1`
- raised: 2026-09-10T01:31:57Z
- from: echo-opus-wd1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-wd1` (branch `echo-opus-wd1`)
- head: `c55a3e1186ca38c0074ec41868a2769a495a2545`
- state: **work-complete**
- for: ceo

## The question

For the name-spelling decision on 3.3d, is 3.3% of a 92-minute timeline filled with fabricated repetition an acceptable price for taking proper-noun accuracy from 46 to 55 of 66 — or does the invariant stay at -mc 0 and names get canonicalized in loro-correction?

## What was already tried

Measured every whisper-cli flag against a known reference, plus the 92-minute real recording, on today's build. -mc 0: 0.0% fabricated, 46/66 names, 2.89% WER, 226 s. -mc 64 + carried entity prompt: 3.3% fabricated, 55/66 names, 2.73% WER (the best measured), 393 s. -mc -1: 7.8% fabricated. Also measured: --prompt under -mc 0 is BYTE-IDENTICAL to no prompt at all, so 'bias the decoder and keep the invariant' is not a third option - it is the same knob.

## Proceeding meanwhile

Nothing is blocked and nothing waits on this. The settings work is committed with -mc 0 unchanged; the only value I changed is -fa, which is pinned at the value it already had. The 3.3d decision stays the CEO's and I did not take it.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260910T013157Z-6bdf4aa1`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260910T013157Z-6bdf4aa1 --disposition "<what you decided or did>"
