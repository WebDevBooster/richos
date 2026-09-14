# Escalation: Step 1's done-when is unreachable: 2 of the 7 typed inventories are load-bearing specs, 2 already derive, 1 is not an inventory

- id: `esc-20260914T225249Z-29fa451e`
- raised: 2026-09-14T22:52:49Z
- from: tom-opus-derive1
- worktree: `/Users/alex/ab/richos-wt/tom-opus-derive1` (branch `cc/tom-opus-derive1`)
- head: `e6b547773db4dcda3717898765b16b0eef15bf3b`
- state: **proceeding**
- for: lead

## The question

Step 1 can take positions-per-rule from 5 to 4, not to 0. BR_EXPECTED and ACKNOWLEDGED_SCRIPTS must stay typed or BR2 and engine-status case 1b become hooks.json checked against itself. Do you want the one sound subtraction (invert R_ROOTED_HOOKS) landed on its own, or should Step 1 be rewritten against the measured k=5 before any of it lands?

## What was already tried

Measured with the engine's own tool. hook-registration-completeness.sh --explain against a throwaway rooted Stop hook: 5 places owing (engine/.claude/settings.local.json, BR_EXPECTED, ACKNOWLEDGED_SCRIPTS, R_ROOTED_HOOKS, any suite via ci-affected-units A5); rootless variant: 4. unevaluated-payload.test.sh stayed GREEN with the throwaway wired (rc 0) because it already derives via registered_hook_scripts; demo.sh already derives at demo.sh:200. session-evidence.mutation.sh holds no inventory - it fails only as a downstream consumer of the probe's BR_EXPECTED. registered-hooks.sh is sourced by 9 scripts, not 6.

## Proceeding meanwhile

Landing the one subtraction that survives verification: Layer R is blind to 5 of the 57 registered hooks that resolve a root, and one of them (guard-stop-live-work.sh) has a genuinely divergent root bootstrap that the gap has been hiding.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260914T225249Z-29fa451e`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260914T225249Z-29fa451e --disposition "<what you decided or did>"
