# Escalation: The home.js sweep failure is a load-dependent race, not cross-suite leakage — and the sweep is green here twice

- id: `esc-20260906T064334Z-92138c11`
- raised: 2026-09-06T06:43:34Z
- from: echo-opus-hi1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-hi1` (branch `echo-opus-hi1`)
- head: `48df8525b038bf7865cc2f9835a75dfc72bf5250`
- state: **work-complete**
- for: lead

## The question

Do you want a second, independent reproducer for this class (a lag knob on every check that arranges page state after load), or is the one on this check enough?

## What was already tried

Ran the full 25-suite sweep twice in the worktree (main cf84736 + echo-opus-hm1 merged; app/ is byte-identical to hm1's app/): both green, 25/25, 526 checks, exit 0 — the reported failure did NOT reproduce. Instrumented the page instead: home.js:1453 starts the field on its own requestIdleCallback and asks home_field_data at 358.0/349.0/348.0/352.0/347.0ms from navigation over five launches, while the suite's first turn lands at 98.0/86.0/87.0/89.0/85.0ms — mean margin 261.8ms, spent by two evaluate round trips before homeFieldSet(). With RICHOS_SPLASH_LAG_MS=400 the check fails deterministically: 'the picture is not drawn from his corpus, expected 4000, actual 7500' — the only failure in the suite, matching the sweep's '1 failed'.

## Proceeding meanwhile

Fixed and committed on echo-opus-hi1: the corpus is installed through mock.js's pre-boot __RICHOS_MOCK_PRESET__ seam with addInitScript, so the page cannot ask before the answer is there. No assertion relaxed. Sweep green after the fix (25/25, 526 checks), home.js alone green, and green at RICHOS_SPLASH_LAG_MS=400 and 2000.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260906T064334Z-92138c11`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260906T064334Z-92138c11 --disposition "<what you decided or did>"
