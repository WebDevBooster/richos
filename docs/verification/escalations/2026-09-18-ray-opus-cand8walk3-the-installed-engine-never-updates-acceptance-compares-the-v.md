# Escalation: The installed engine never updates: acceptance compares the VERSION string, not the digest it already recorded

- id: `esc-20260918T104154Z-dc75f70b`
- raised: 2026-09-18T10:41:54Z
- from: ray-opus-cand8walk3
- worktree: `/Users/alex/ab/richos-wt/ray-opus-cand8walk3` (branch `cc/ray-opus-cand8walk3`)
- head: `ec620488cfa6251556b6fdb9a851e436054972ae`
- state: **proceeding**
- for: lead

## The question

Should engine_accepted compare INSTALLED-FROM's sha256 against the digest the binary pins, rather than comparing VERSION to VERSION?

## What was already tried

Verified three ways. (1) richos/app/crates/richos-core/src/setup.rs:244 engine_accepted accepts on 'Some(v) if v == needed' — the VERSION file string and nothing else. (2) The engine directory that broke candidate .7 and .8 is kept at scratchpad/richos-qa-cand8/engine-stale-103900: VERSION 1.2.0, INSTALLED-FROM sha256 b7a882ef4381ca294259c1a01a6af29acc3159dc0b871e8064bd7f410b71da07 from the release asset of v1.2.0-nightly.20260917.2 — YESTERDAY's nightly — and grep -c seat_of on its ecs/adapters/app.py returns 0, so it predates the background-seat feature. (3) The candidate .8 binary's own strings carry the URL of v1.2.0-nightly.20260918.2's richos-engine-1.2.0.tar.gz next to sha256 ea7f79043e7dc8f51b5f4207964ec5fa3e15ca11b44e5342a5fb4d38580db194. Two different digests, one version string, silently accepted. The app records the digest it installed and pins the digest it wants, and compares neither.

## Proceeding meanwhile

Resuming the walk on the repaired instance pid 85513 to test the job flow itself; the shipped-artifact verdict stands on the unrepaired run.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T104154Z-dc75f70b`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T104154Z-dc75f70b --disposition "<what you decided or did>"
