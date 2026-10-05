# Escalation: Output panel S2b: the land witness is unproven on the real app because the back-end job was ended mid-review on the VM (walk-10608166d53f)

- id: `esc-20261005T151403Z-2f5c3737`
- raised: 2026-10-05T15:14:03Z
- from: echo-opus-out2b
- worktree: `/Users/alex/ab/richos-wt/echo-opus-out2b` (branch `cc/echo-opus-out2b`)
- head: `54e2a4f908e0f42444bc2e7c367180d144775021`
- state: **work-complete**
- for: lead

## The question

S2b is built, committed and fixture-proven, and its carve-out is proven on the VM, but the land half of its Done-when (both files listed once at the Acme path, nothing at the worktree path) could not be observed, because no walk reached integrate. Who takes the background-job lifecycle defect seen in walk 6 (app 93ce176f9, evidence docs/verification/2026-10-05-output-panel-s2b-vm/walk6-reports.jsonl, backend-worker-story.json inside it)? The worker committed notes.md and notes.zip (git archive ran unasked) and then its next Bash call was refused with 'This app turn is stopped or is supplying context'; the assignment was recorded failed at 15:11:57Z ('It stopped before it finished. The work ran and nothing was landed.') while the back end went on to prepare and dispatch the reviewer; the reviewer's SubagentHandback was refused repeatedly with 'RichOS desktop quota: This app work was stopped' and 'the platform had already recorded this agent as finished' (the host's five-hour usage read 51% at 15:12Z), so its verdict never reached the back end. Once that is fixed, S2b's real-app check is one rerun of the committed output-walk.py, steps identity,first-run,connect,tools,backend-worker.

## What was already tried

Three walks under run-walk.py, one slot each, every one cleaned up (walk-d20296d51c3d, walk-0c7e08bf738c, walk-10608166d53f). Walks 4 and 5 stopped at the worker-approval defect already raised as esc-20261005T150541Z-ee581ad7. Walk 6 avoided it with git archive and proved the carve-out: a command row for the worker's notes.zip under engine-state/target-worktrees with its agent id. Did not run a fourth walk: the cause is outside S2b and a rerun would repeat it.

## Proceeding meanwhile

Handing over S2b with the land witness proven by mega-lander/tests/app.test.py against real Git repositories (7 of 7) and output:: (23 of 23), and the carve-out proven on the VM; the unproven land is stated in the handoff.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261005T151403Z-2f5c3737`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261005T151403Z-2f5c3737 --disposition "<what you decided or did>"
