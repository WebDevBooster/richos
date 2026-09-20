# Escalation: Ledger 2.4 says ours-none for release-only step coverage; that is false and I measured it

- id: `esc-20260920T062201Z-6a9c0a46`
- raised: 2026-09-20T06:22:01Z
- from: zach-opus-release2
- worktree: `/Users/alex/ab/richos-wt/zach-opus-release2` (branch `cc/zach-opus-release2`)
- head: `b4785aa0d7984024851af549c444ba21fd6f0b2c`
- state: **proceeding**
- for: lead

## The question

Item 2 premise is that release-only steps exist only in the release path. They do not. Should the slice stay as I am now building it (drift-prevention registry, early cheap gate, and the stable path which genuinely has zero coverage), or does the reduced scope change what you promised the CEO?

## What was already tried

Ran bash richos/app/scripts/nightly.test.sh on branch cc/zach-opus-release2, main b4785aa0. Output: Ran 38 tests in 44.216s, then OK. nightly.test.py:456 drives prepare, build, finish and promote against a fixture repo. build-info.json of v1.2.0-nightly.20260920.1 records that suite passing in 19s as a gate of that build.

## Proceeding meanwhile

Building what is genuinely missing and is the T3 intent: a registry so every release-only step must be exercised by the smoke, a named cheap gate that refuses before cargo and the 402s UI suite, and coverage of the new stable path. Engine-asset packaging excluded with its measurement: 112s in the same build already.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260920T062201Z-6a9c0a46`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260920T062201Z-6a9c0a46 --disposition "<what you decided or did>"
