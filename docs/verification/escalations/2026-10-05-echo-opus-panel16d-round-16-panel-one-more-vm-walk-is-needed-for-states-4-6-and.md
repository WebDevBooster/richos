# Escalation: Round-16 panel: one more VM walk is needed for states 4, 6 and 7 (the brief allows only one, and it found a fixture blocker)

- id: `esc-20261005T015950Z-f4df3655`
- raised: 2026-10-05T01:59:50Z
- from: echo-opus-panel16d
- worktree: `/Users/alex/ab/richos-wt/echo-opus-panel16d` (branch `cc/echo-opus-panel16d`)
- head: `61e8305e2e30898175c187b26f6851a0400a9894`
- state: **proceeding**
- for: lead

## The question

May I run ONE more round16-panel-walk.sh on the test VM (about 35 minutes, after one debug rebuild) so shots 4, 6 and 7 show the working row and the agent count? Without it, states 1, 2, 3 and 5 are proven on the real app, and 4, 6 and 7 are not.

## What was already tried

Collected echo-opus-panel16c's walk (PID 51126, ended 01:07Z, cleanup_complete true). It showed: Home tagged used up at 95% (fixed, e679eea49); the fast card and header row differ from round 16 (fixed, 8e6b0a169 and 807394b97); no working row and a Stopped card in shots 4, 6 and 7. I rebuilt at 665d0765a and ran the brief's ONE more walk (walk-2b34a9ca8b95, 01:34Z). Shots 1, 2 and 3 match round 16, but shot 4 is again a Stopped card. The guest's relaunch log names the real cause: 'cognition protocol: The connection did not report whether company interview tools loaded.' The walk's fake claude never sends Claude Code's system/init frame, so native.rs ensure_onboarding_tools_loaded refuses every turn of the walk's company conversation. Fixed in the fixture only (61e8305e2: the fake now sends the init frame in the shape testvm/permission-provider.py already proved in the S7 walk; its test is 9 ok). No app code is involved in this blocker.

## Proceeding meanwhile

Finishing the current walk, committing every shot that matches round 16 and the HANDOFF update with each state's verdict, then cleaning up. The next walk needs only: rebuild (no app code changed since 665d0765a, so the existing bundle stands) and run-walk.py with round16-panel-walk.sh from this branch.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261005T015950Z-f4df3655`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261005T015950Z-f4df3655 --disposition "<what you decided or did>"
