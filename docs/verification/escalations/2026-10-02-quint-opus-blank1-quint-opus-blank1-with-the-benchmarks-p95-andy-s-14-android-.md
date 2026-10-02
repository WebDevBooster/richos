# Escalation: quint-opus-blank1: with the benchmarks' p95, Andy's 14 Android recordings FAIL, not pass: nearest-rank p95 of 14 launches is the slowest (863.8 ms)

- id: `esc-20261002T085838Z-029b1749`
- raised: 2026-10-02T08:58:38Z
- from: quint-opus-blank1
- worktree: `/Users/alex/ab/richos-wt/quint-opus-blank1` (branch `cc/quint-opus-blank1`)
- head: `0ba39f9c604b459f9a8392178859b3c12acf5d62`
- state: **proceeding**
- for: lead

## The question

Implemented as you stated: limit 400 ms, series FAILS when p95 of its per-launch longest blank stretch is over the limit, every launch over the limit listed with its recording. The benchmarks' p95 is perfcore.percentile, nearest rank: rank = ceil(0.95 x n). For n = 14 that is rank 14, the maximum, so the 863.8 ms launch (release-seeded/raw/light_1.mp4) IS the p95 and the series fails. Under 20 launches nearest-rank p95 always equals the slowest launch; from 20 launches on, one outlier in 20 is tolerated (rank 19 of 20). perfcore.stats itself refuses to place a p95 under 20 samples. So: keep the rule as stated (my default; the Android cold-blank series in perf.py now defaults to 20 launches so one outlier can pass), or do you want something else for series under 20?

## What was already tried

Computed on the analyzer's per-launch numbers for Andy's 14 release recordings: 13 are under 400 ms (max 350.2), one is 863.8 ms. Nearest-rank p95 = 863.8 for n=14; linear-interpolation p95 would be about 530 ms, also over 400.

## Proceeding meanwhile

Building the series judgment exactly as stated, defaulting perf.py's Android cold-blank series to 20 launches, and reporting Andy's 14 as FAIL with the outlier listed.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261002T085838Z-029b1749`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261002T085838Z-029b1749 --disposition "<what you decided or did>"
