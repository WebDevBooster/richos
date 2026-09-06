# Escalation: waiver-repetition.test.sh case 15c went red tonight and counts something the case did not write

- id: `esc-20260906T012218Z-c6526676`
- raised: 2026-09-06T01:22:18Z
- from: zach-opus-mr2
- worktree: `/Users/alex/ab/richos-wt/zach-opus-mr2` (branch `zach-opus-mr2`)
- head: `5c6e7b33d26765cc2a9ab0fdd3df7268944dbec1`
- state: **work-complete**
- for: lead

## The question

Who owns scripts/hooks/waiver-repetition.test.sh case 15c, which is now deterministically red on this machine for a reason that is not on any branch?

## What was already tried

Case 15c truncates its fixture ledger to a single entry and expects the recovery notice. The hook instead reports 'REPEATED WAIVERS ... notice-waiver-repetition.py (14x one reason, over 2 days)' -- a count that cannot come from the one line the case just wrote, so it is counting something outside its own fixture. Established rather than assumed that this branch does not cause it: my only edit to that file is a wiring block appended AFTER every case, and the failure reproduces byte-for-byte with the harness skipped via RICHOS_MUTATION_INNER=1 (26 passed, 1 failed). Also established that it is recent: the identical suite was green in four separate timed runs earlier tonight -- 2s, 44s, 35s and 34s -- and has been red in five consecutive runs since, four through the harness and one direct. The mutation harness I wired into that suite is behaving correctly: its control-sandbox gate refuses to score any kill over a red control, which is the phantom-kill protection working. Not diagnosed further and not fixed: the analyzer's search path is the next step and that file is outside my scope.

## Proceeding meanwhile

All five other deliverables are committed on zach-opus-mr2 and the other seven wired harnesses are green.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260906T012218Z-c6526676`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260906T012218Z-c6526676 --disposition "<what you decided or did>"
