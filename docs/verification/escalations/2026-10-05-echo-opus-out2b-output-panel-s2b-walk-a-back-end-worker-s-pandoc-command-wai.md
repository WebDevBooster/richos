# Escalation: Output panel S2b walk: a back-end worker's pandoc command waits for approval that never reaches the Approve button, so the job never lands

- id: `esc-20261005T150541Z-ee581ad7`
- raised: 2026-10-05T15:05:41Z
- from: echo-opus-out2b
- worktree: `/Users/alex/ab/richos-wt/echo-opus-out2b` (branch `cc/echo-opus-out2b`)
- head: `4075e08b0cf92743b3572fe62b9a24167e296050`
- state: **proceeding**
- for: lead

## The question

Who owns the background-approval defect: on the test VM (app 93ce176f9, walks walk-d20296d51c3d and walk-0c7e08bf738c), a back-end WORKER's Bash call to /opt/homebrew/bin/pandoc got a PreToolUse and no PostToolUse twice (refused by the native permission decision after the 300 s desk deadline), and the walk's approve_pending, which presses the button labeled 'Approve <assignment title>' (work-summary.js:226, shown only when the row has awaitingYou from work_host.rs pending_decision), found no such button in 900 s. The back end then asked a question and the job sat blocked (walk 5) or failed (walk 4). In S2's walk 3 the same Approve path worked for the back-end LEAD's own pandoc. So a worker's permission request appears not to surface on its assignment row, or is keyed to another assignment. This also makes PRD 12.2b's walk premise (a worker makes notes.pdf with pandoc in one unattended run) false today.

## What was already tried

Two walks, both under run-walk.py, each released at its end. The second walk recorded backend-worker-story.json (every tool call of the back-end session and how it ended); both workers' handbacks say the pandoc command never started; no approvals_pressed fact in either run. Read permissions.rs (a worker Bash with no standing grant goes to the desk and waits 300 s), work_host.rs pending_decision (assignment_key of the request binding against the assignment), work-summary.js (Approve button only when awaitingYou). Did not inspect the guest UI tree; that needs another VM run with an AX dump and is outside S2b.

## Proceeding meanwhile

Proceeding with S2b's real-app check on a worker command that runs unasked (git archive -o notes.zip in the worker's worktree, as the workers' git commands ran unasked in both runs): it still proves the carve-out (a command-made file under target-worktrees) and the land witness (d). The pandoc deviation is stated in the commit and the handoff.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261005T150541Z-ee581ad7`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261005T150541Z-ee581ad7 --disposition "<what you decided or did>"
