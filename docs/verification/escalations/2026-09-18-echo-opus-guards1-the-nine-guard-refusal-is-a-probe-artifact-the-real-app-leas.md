# Escalation: The nine-guard refusal is a probe artifact: the real app lease pins spawn.py to two guards, and one of the two is an operator-session guard

- id: `esc-20260918T165430Z-73020e78`
- raised: 2026-09-18T16:54:30Z
- from: echo-opus-guards1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-guards1` (branch `cc/echo-opus-guards1`)
- head: `604580455d7badd6ad73b22630402d9a96829be6`
- state: **proceeding**
- for: lead

## The question

Given the app already runs only guard-worktree-isolation + guard-brief-scope (+ guard-sealed-worktree at the real gate), should guard-brief-scope.sh come OFF the app's list as an operator-session guard, or does the CEO want a spec-scope check on a user's own repository?

## What was already tried

Measured both ways on one binary, dispatch-only probe, this Mac, worktree /Users/alex/ab/richos-wt/echo-opus-guards1 (HEAD 60458045). WITHOUT RICHOS_SPAWN_HOOK_SOURCES (what the probe does today): 'spawn: refused by 1 of 9 guard(s)', guard-owned-state.sh, over the paused CI. WITH RICHOS_SPAWN_HOOK_SOURCES=app=<plugin>/spawn-preflight.json (what EngineProfile::configure sets for every real lease, engine_profile.rs:243): prepare answers status=prepared and returns the agent payload - GREEN, no refusal. The real app therefore never met the nine guards; the probe's drive_prepare (first_reply_timing_e2e.rs:333-348) simply never sets the variable the lease always sets. The app's real guard set is three: guard-sealed-worktree.sh and guard-worktree-isolation.sh (user-work) plus guard-brief-scope.sh (operator-session, app-engine-hook.py:68-71, engine_profile.rs:230-234) - and that list is typed by hand in two places, declared nowhere.

## Proceeding meanwhile

Building the declared classification anyway - it is the right deliverable and it now has a second consumer: it becomes the SOURCE of the app's two hand-written lists instead of an inference. Also fixing the probe to set the variable the lease sets, so it stops measuring a path the app never takes.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T165430Z-73020e78`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T165430Z-73020e78 --disposition "<what you decided or did>"
