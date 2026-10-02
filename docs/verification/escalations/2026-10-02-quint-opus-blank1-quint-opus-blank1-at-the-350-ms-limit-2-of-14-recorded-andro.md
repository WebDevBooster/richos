# Escalation: quint-opus-blank1: at the 350 ms limit, 2 of 14 recorded Android release cold starts still FAIL (864 ms and 350.2 ms)

- id: `esc-20261002T085217Z-16216db1`
- raised: 2026-10-02T08:52:17Z
- from: quint-opus-blank1
- worktree: `/Users/alex/ab/richos-wt/quint-opus-blank1` (branch `cc/quint-opus-blank1`)
- head: `0ba39f9c604b459f9a8392178859b3c12acf5d62`
- state: **proceeding**
- for: lead

## The question

The limit is set to 350 ms as instructed. On Andy's 14 Android release recordings the analyzer passes 12 and fails 2: release-seeded/raw/light_1.mp4 (flat stretch 863.8 ms; Andy's own timelines.txt says blank=864) and release-first-after-install/raw/light_2.mp4 (350.2 ms, 0.2 ms over). Keep 350 ms and treat those two as real failures (my default, since the limit is his number), or does he want a different number?

## What was already tried

Analyzer verdicts match Andy's independent frame timings within about 1 ms on all ten release-seeded runs (251.3/251, 288.9/289, 343.4/344, 299.7/299, 253.9/254, 228.6/228, 242.6/243, 314.5/315, 256.4/256, 863.8/864). The 228-344 ms range in the instruction leaves out light_1 at 864 ms; the first-after-install runs were not in his range at all.

## Proceeding meanwhile

Keeping BLANK_LIMIT_MS = 350 with the CEO's reason beside it, finishing tests, the Android cold-start check and the static check; the two failures are reported as they are.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261002T085217Z-16216db1`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261002T085217Z-16216db1 --disposition "<what you decided or did>"
