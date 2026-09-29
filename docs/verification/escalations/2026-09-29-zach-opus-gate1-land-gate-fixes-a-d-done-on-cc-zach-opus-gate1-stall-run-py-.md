# Escalation: Land-gate fixes (a)-(d) done on cc/zach-opus-gate1; stall-run.py could not prove item (d), a new qa/busy-sample.py does

- id: `esc-20260929T151416Z-a70587f4`
- raised: 2026-09-29T15:14:16Z
- from: zach-opus-gate1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-gate1` (branch `cc/zach-opus-gate1`)
- head: `d80c1217468e6f67af7cacf158f808a2018ea16d`
- state: **work-complete**
- for: lead

## The question

None blocking. Record only: the brief named qa/stall-run.py as the proof tool for the testvm scenario flake, but that flake came from reserve.py's admission sample reading the whole Mac at 100.0% busy, not from the test's own clock. stall-run takes the CPU from the test process and main's old test PASSED under it (2 stalls, exit 0). The fix was proven red on main / green on the branch with a new committed helper, qa/busy-sample.py (fixes reserve.py's sample, adds no load), and green under stall-run as well.

## What was already tried

stall-run.py --run-ms 1 --stop-ms 2500 on main's test: exit 0 (not red). under-load.py cannot make the reading land on exactly 100.0% (99.6% still admits a --max-cpu 100 run).

## Proceeding meanwhile

All six commits are on cc/zach-opus-gate1 (b281d65a..d80c1217); Rich lands.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260929T151416Z-a70587f4`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260929T151416Z-a70587f4 --disposition "<what you decided or did>"
