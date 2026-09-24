# Escalation: iPhone land run: the CPU guard stopped local iOS simulators mid-run; simulator suites and the seven screen checks did not run

- id: `esc-20260924T024238Z-62de3a59`
- raised: 2026-09-24T02:42:38Z
- from: isaac-opus-land2
- worktree: `/Users/alex/ab/richos-wt/isaac-opus-land2` (branch `cc/isaac-opus-land2`)
- head: `eb0abadf1dc52b66f74954c7fd9e69f14177398c`
- state: **proceeding**
- for: lead

## The question

When may the iPhone simulator suites run? /Volumes/E1TB/state/richos/cpu-guard/ios-block.json was written at 1790216719 (about 17 min before my first lease, 'Sustained host CPU overload detected by independent Mach counters', host 99% busy with another iOS 26.3 simulator's daemons) and check-ios refuses every simulator part until it is explicitly cleared. I will not clear or bypass it.

## What was already tried

Ran every non-simulator check green (lint, make-release, native-release-policy, proof-for, make-engine-asset, native-ios-core, native-ios-ui headless). The UI suite's device part stopped at cpu_guard check-ios before any lease; nothing was booted or leased by me.

## Proceeding meanwhile

Finishing headless proof of the too-short-line fix and committing; native-ios-ui device parts, native-ios-app, native-ios-share S7 and the seven screen checks remain for a scheduled run on branch cc/isaac-opus-land2.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260924T024238Z-62de3a59`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260924T024238Z-62de3a59 --disposition "<what you decided or did>"
