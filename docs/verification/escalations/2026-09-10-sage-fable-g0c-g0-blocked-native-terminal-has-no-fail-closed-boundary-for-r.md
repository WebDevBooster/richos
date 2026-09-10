# Escalation: G0 BLOCKED: native terminal has no fail-closed boundary for routine questions; which contract does the native surface get?

- id: `esc-20260910T073814Z-51b956d7`
- raised: 2026-09-10T07:38:14Z
- from: sage-fable-g0c
- worktree: `/Users/alex/ab/richos-wt/sage-fable-g0c` (branch `sage-fable-g0c`)
- head: `95f53fc315c4dbfde56c9980eb4f0d400f6d8399`
- state: **work-complete**
- for: ceo

## The question

For the native Claude Code terminal, do you accept the weaker contract 'routine questions are withheld while the integration is healthy and shown when a hook fails, times out or is disabled', with the literal 'never asks' kept only on RichOS (which renders and answers permissions itself)? Or does the native terminal stay an inspection surface, not an acceptance surface, until the host changes?

## What was already tried

Probed Claude Code 2.1.267 live in disposable pty sessions: MessageDisplay repaints the original on hook failure (23 ms), timeout (14.9 s) and when hooks are disabled; PreToolUse deny of AskUserQuestion fails open (dialog painted 33 ms after a failing hook); a settings deny removes the dialog but the model asks in prose; the permission dialog paints before its PermissionRequest hook runs (about 6 s on screen). Intake, team handoff, in-session and --bg continuation, cancellation and native exit are proven with limits. Report: docs/plans/owned-outcome/G0-FEASIBILITY.md at 95f53fc3 on sage-fable-g0c.

## Proceeding meanwhile

Nothing beyond G0 was authorized; no further implementation is being spent. The report and evidence are committed and await landing.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260910T073814Z-51b956d7`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260910T073814Z-51b956d7 --disposition "<what you decided or did>"
