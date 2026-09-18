# Escalation: The flow lands end to end; and the silent-Running observation the brief built on had a probe cause, not a product one

- id: `esc-20260918T130154Z-dd628570`
- raised: 2026-09-18T13:01:54Z
- from: echo-opus-worklease2
- worktree: `/Users/alex/ab/richos-wt/echo-opus-worklease2` (branch `cc/echo-opus-worklease2`)
- head: `55c7fb9dee4b77589f7174997f151411c9693311`
- state: **work-complete**
- for: lead

## The question

Nothing needs answering to land this branch. The one thing to carry forward: does anyone else's record still cite worklease1 esc-20260918T115854Z-852c5f9c point 4 as proof that production leaves a job in Running with no notice? That half was the probe reading two paths that never exist.

## What was already tried

Built both halves of the brief and ran the whole flow for real three times. Row 1: the scope ALREADY carried the obligation as binding.turn_id, so the app needed no change and the work was entirely engine-side; prepare and complete now derive it and ignore an argument naming a different one. Row 2: an ended turn is never Running. Row 3: the flow now lands - fixture 3f4b5ab to 95b7ca5, reviewer passed, Settled at t+209.657s, and every richos_work call in the session's callbacks.jsonl carries no obligation_id with zero tool failures. THE FINDING: run 2 LANDED the work and reported 'No work was started, so nothing was landed'. Cause was the probe's WorkHost state root (data instead of data/engine-state, where the app uses data_dir.join(engine-state) at src-tauri/src/main.rs:2030). Both of the host's readings hang off that root, so both answered honestly about two directories that never exist. Same defect was present on worklease1's run, which is where the silent-Running observation came from.

## Proceeding meanwhile

All four commits are on cc/echo-opus-worklease2, rebased onto 580f896a, tree clean. richos-core 1272/0, mega-lander 31/0, src-tauri cargo check finished. Record at docs/verification/2026-09-18-the-fourth-way-a-background-job-stalled.md, section 3.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T130154Z-dd628570`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T130154Z-dd628570 --disposition "<what you decided or did>"
