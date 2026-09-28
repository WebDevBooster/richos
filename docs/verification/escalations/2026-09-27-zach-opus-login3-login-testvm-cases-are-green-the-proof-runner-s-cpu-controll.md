# Escalation: login testvm cases are green; the proof runner's CPU controller kills every calibration check on first sample (cross-interpreter monotonic clock)

- id: `esc-20260927T033138Z-5a7bc2e7`
- raised: 2026-09-27T03:31:38Z
- from: zach-opus-login3
- worktree: `/Users/alex/ab/richos-wt/zach-opus-login3` (branch `cc/zach-opus-login3`)
- head: `07531c50249f4454baa65491764c2a6aa819ecca`
- state: **proceeding**
- for: lead

## The question

After you land the cpu_guard.py fix, will you reinstall the launchd CPU-guard controller (cpu_guard.py install) so the running watch picks it up? Until then no proof run with an unknown-demand check can finish on this Mac.

## What was already tried

run-tests.sh standalone via reserve.py: 135 passed, 0 failed (login-only: 18/18). Both failed proof runs' supervision.json: resource-envelope-exceeded, samples 1, 0.61s and 1.80s after start. Controller runs /usr/bin/python3 3.9.6, whose time.monotonic() is process-relative (0.003); supervisor runs Homebrew 3.14.3 (562708, since boot), so started_monotonic > now always.

## Proceeding meanwhile

Fixing cpu_guard.py to stamp and compare CLOCK_UPTIME_RAW/CLOCK_MONOTONIC (host-wide) and run-tests.sh's TERM trap to exit instead of continuing on a deleted scratch dir; then the scoped proof, which will still hit the OLD running controller.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260927T033138Z-5a7bc2e7`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260927T033138Z-5a7bc2e7 --disposition "<what you decided or did>"
