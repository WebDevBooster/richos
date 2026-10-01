# Escalation: zach-opus-narrow1: the brief's real no-argument native-ios-ui run needs a scratch workspace the isolation guard will not let me build

- id: `esc-20261001T192529Z-e7ccb1b3`
- raised: 2026-10-01T19:25:29Z
- from: zach-opus-narrow1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-narrow1` (branch `cc/zach-opus-narrow1`)
- head: `dd7fe7bbaca495d52fe5245b97f640a3243b388a`
- state: **proceeding**
- for: lead

## The question

The real run must be a cc/ workspace whose main already contains this branch (otherwise the branch's own edits to native-ios-ui.test.sh correctly select every case). Building one needs git commands in a scratch clone, and the worktree-isolation guard refuses them ('git operations must target its own worktree'). Shall the no-argument real run be done after the land in the next workspace, or do you want to create that scratch workspace yourself?

## What was already tried

git clone --shared of my branch into /Volumes/E1TB/tmp/claude/zach-opus-narrow1/demo/repo succeeded; the next step, git -C <clone> branch main HEAD (then git worktree add -b cc/... in the clone), was refused by the isolation guard. I did not work around it with a script.

## Proceeding meanwhile

Committed all work (7 commits on cc/zach-opus-narrow1). Running, for real, native-ios-ui.test.sh --only QuestionTests/testOtherAnswerInLightTheme from my workspace: the device is narrowed to the iPhone SE automatically, which is exactly the selection a no-argument run makes for a branch that changes that one case (proven in fixture by workspace-scope.test.sh i1/i9). Its time is what I will report against the 828 s full run.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261001T192529Z-e7ccb1b3`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261001T192529Z-e7ccb1b3 --disposition "<what you decided or did>"
