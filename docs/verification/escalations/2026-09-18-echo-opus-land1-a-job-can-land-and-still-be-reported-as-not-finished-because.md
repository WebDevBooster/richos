# Escalation: A job can land and still be reported as not finished, because landing and closing the assignment are two engine tools

- id: `esc-20260918T071811Z-d4b34afe`
- raised: 2026-09-18T07:18:12Z
- from: echo-opus-land1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-land1` (branch `cc/echo-opus-land1`)
- head: `e35a8c3f75afd8a6730d7ddb43dfd660e9824711`
- state: **work-complete**
- for: lead

## The question

On the candidate .7 walk, is 'stopped before it finished — it landed on cc/x in project' the sentence he should hear for work that landed but whose assignment was never closed, or should the app treat a verified land with an open obligation as its own fourth ending with its own words?

## What was already tried

Built §52 as specified and verified the chain end to end. richos/engine/mega-lander/app.py:868 shows integrate returns obligation_closed:False — landing is NOT closing. The obligation is closed only by mcp__richos_work__complete (app.py:1066-1095), a separate tool, which was already on the background allow-list and which requires the frozen instruction the work scope carries (native.rs:2405). So the land-on-its-own chain is integrate THEN complete, and nothing mechanically couples them: brief_for now instructs the back end to do both, and instruction is the only thing holding them together. If a run lands and then stops, settle() reads the obligation as open with nothing on the permission desk and reports a job that did not finish -- with the land named in the same sentence, because work_status::trail reads integration.verified off the receipt. richos-core test a_land_with_an_open_assignment_is_neither_finished_nor_reported_as_unlanded pins exactly that. It is honest and it is not wrong; it will simply read to him like a failure over work that actually landed, and that is a product judgement rather than a code one.

## Proceeding meanwhile

Nothing depends on the answer. All five commits are on cc/echo-opus-land1 and the work is complete: cargo test -p richos-core 1220 passed / 0 failed / 4 ignored, cargo check in src-tauri exit 0 with only the 4 pre-existing dead-code warnings, and the UI runner all 49 suites passed with 694 checks.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T071811Z-d4b34afe`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T071811Z-d4b34afe --disposition "<what you decided or did>"
