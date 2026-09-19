# Escalation: The 76 s engine round-trip is the UPLOAD, not the download — the download is 14.8 s, measured

- id: `esc-20260919T184412Z-cb3511cf`
- raised: 2026-09-19T18:44:12Z
- from: zach-opus-buildtime2
- worktree: `/Users/alex/ab/richos-wt/zach-opus-buildtime2` (branch `cc/zach-opus-buildtime2`)
- head: `fc3a71e1b2f5be1affaffb7d1cc0815c5ac9c894`
- state: **proceeding**
- for: lead

## The question

Item 4 of my brief asks me to stop re-downloading the 119 MB engine asset because the round-trip costs 76 s. I measured that download just now at 14.8 s (curl, http 200, 119,734,179 bytes, 8.1 MB/s). The other ~60 s of that window is the gh release upload, which sits between the two milestones and prints nothing, so the byte-offset sampler that produced the phase table could not separate them. Removing the download would save ~15 s (1.5% of a build) and would delete the only check that a customer's first run gets the pinned bytes. Do you want that trade, or do I leave the download and take the 25 s reproducibility re-build instead (same skip-when-unchanged mechanism, always run on release)?

## What was already tried

curl -sS -L -o /dev/null -w on the published asset of v1.2.0-nightly.20260919.6: http=200 size=119734179 time=14.767714s speed=8107834B/s. Read lines 2836-2860 of ~/.richos-nightly/logs/20260919T180454Z-ac11d13e.log: the releases/tag/ line and the 'fetching the PUBLISHED asset' line are ADJACENT (2842, 2843), so gh release upload of 119 MB printed nothing between them and a sampler that maps wall clock to log byte offsets charges that stall to the segment after it.

## Proceeding meanwhile

Taking the reproducibility re-build (25 s) through the same input-digest mechanism as items 1-2, leaving the published-bytes download in place. Items 1, 2 and 3 are unaffected and proceeding.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260919T184412Z-cb3511cf`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260919T184412Z-cb3511cf --disposition "<what you decided or did>"
