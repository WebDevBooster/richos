# Escalation: cc/zach-sonnet-vinputs1 carries the test iPhone's real CoreDevice UUID in richos/app/scripts/qa.test.sh (FC2 case, line 1245); the device-identifier guard refused my merge commit of it

- id: `esc-20261002T084327Z-0a7b49c2`
- raised: 2026-10-02T08:43:27Z
- from: isaac-opus-white1
- worktree: `/Users/alex/ab/richos-wt/isaac-opus-white1` (branch `cc/isaac-opus-white1`)
- head: `31dae34dd4fa789c9572150fc9a7f4cdd9e8505a`
- state: **proceeding**
- for: lead

## The question

None needed from me: when you land cc/zach-sonnet-vinputs1 (0ba39f9c6), expect the device-identifier guard to refuse the commit for qa.test.sh's `phone-ios.py approval --device <the phone's CoreDevice UUID>`. My branch cc/isaac-opus-white1 merged it with that one id replaced by a neutral UUID-shaped id (1D1D1D1D-2E2E-4F4F-8A8A-3B3B3B3B3B3B); the FC2 case finds the phone through RICHOS_IOS_DEVICE_ALIASES either way. Use the same replacement when landing vinputs1, or my merge resolves to yours.

## What was already tried

git merge cc/zach-sonnet-vinputs1 in my worktree: one covers-line conflict in native-ios-ui.test.sh (resolved as the union), then the commit was refused: DEVICE IDENTIFIER BLOCKED, richos/app/scripts/qa.test.sh. Replaced the id and committed the merge as 31dae34dd.

## Proceeding meanwhile

Continuing the launch-screen and start-time work on the merged base.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261002T084327Z-0a7b49c2`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261002T084327Z-0a7b49c2 --disposition "<what you decided or did>"
