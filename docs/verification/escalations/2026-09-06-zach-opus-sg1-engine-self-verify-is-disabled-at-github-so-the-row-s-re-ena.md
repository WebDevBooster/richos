# Escalation: engine-self-verify is DISABLED at GitHub, so the row's re-enable plan cannot execute — and turning it on is a public-face decision

- id: `esc-20260906T183601Z-e77497e1`
- raised: 2026-09-06T18:36:01Z
- from: zach-opus-sg1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-sg1` (branch `zach-opus-sg1`)
- head: `29a10fa5402e6f822cd02cb8065120dfca65fa6c`
- state: **proceeding**
- for: lead

## The question

Do you want engine-self-verify (and packaging-ci) re-enabled at GitHub now that the Linux reds are fixed, given the repository is public and Actions status is visible on the front page — or is that the CEO's call?

## What was already tried

Row 3.34's brief says the workflow is workflow_dispatch-only and just needs a dispatch. It is not dispatchable at all: 'gh api repos/WebDevBooster/richos/actions/workflows/345224407 --jq .state' returns "disabled_manually" (since 2026-09-01T10:49:51Z) and 'gh workflow run engine-self-verify.yml --ref main' returns 'HTTP 422: Cannot trigger a workflow_dispatch on a disabled workflow'. The file's own written re-enable instruction — add push: and pull_request: — would ALSO not have worked, because a manually disabled workflow does not run on push either: it would have produced a file that reads as re-enabled and zero executions. packaging-ci is in the same state. I did not enable it: the last five runs are all failures and enabling a workflow on a public repo puts a visible cross on the front page, which is the exact argument the file makes for removing the triggers. Instead I ran the whole thing on Linux locally in the documented ubuntu:24.04 container and fixed what it found.

## Proceeding meanwhile

Measured BEFORE on a clean clone at 381907f: ci-verify.sh exit 1, 71/77 suites, 94m, 6 red (ceo-ruled, contract-integrity, engine-status, session-evidence, workspace-retire, reconcile-terminal-worktrees) — the row's list of five was stale in both directions. Five of the six are fixed and committed on zach-opus-sg1; the full after-run is in flight. Re-enabling is two commands (enable, then run), recorded in the workflow header.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260906T183601Z-e77497e1`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260906T183601Z-e77497e1 --disposition "<what you decided or did>"
