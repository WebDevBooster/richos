# Escalation: reconcile-terminal-worktrees C48 is the last Linux red, and it fails ONLY inside a full ci-verify run — 2 of 2 there, 0 of 13 alone

- id: `esc-20260906T204025Z-7e25728e`
- raised: 2026-09-06T20:40:25Z
- from: zach-opus-sg1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-sg1` (branch `zach-opus-sg1`)
- head: `d19d6d7901bb8759466e2d87778679f7f878e66d`
- state: **work-complete**
- for: lead

## The question

Who takes a worktree-lifecycle state-machine defect that reproduces only inside the full suite run — me in a follow-up, or the reconciler's owner, given this is the area where a wrong fix becomes permanent?

## What was already tried

Measured on Linux (ubuntu:24.04, git 2.43.0, unprivileged uid 1001) at 381907f and again rebased on 00326dd. C48 asserts an UNSIGNED worktree lock survives repeated reconciliation with the member at state verified. It instead reaches remove_member and reports 'exclusive-access-unavailable: automatic erasure is disabled; the unregistered quarantine is retained (attempt 3, BLOCKED)', so the member was treated as UNREGISTERED. The loop passes for the own and foreign locks and fails only for unsigned, so the lock REASON is the only variable in the case. I eliminated the obvious explanations rather than assuming them away: worktree list --porcelain prints byte-identical output for an unsigned lock under 2.43.0 and 2.52.0 (a bare locked line, a zero-byte locked file on disk), so it is not a version or parsing difference. FREQUENCY: failed in BOTH full ci-verify runs (2 of 2); passed 12 of 12 in isolation with the mutation harness suppressed and 1 of 1 with it running. So it is not a flake, it is conditional on the full-run context, and I did not isolate which part of that context.

## Proceeding meanwhile

Everything else is done and committed on zach-opus-sg1. Linux went from 71 of 77 with six red suites to 77 of 79 with C48 the only remaining failing CASE: ceo-ruled, engine-status, session-evidence, workspace-retire and reconciler C16 are each fixed and verified on both hosts, and contract-integrity went green on its own once C16 stopped reddening its case 54. C48 is PRE-EXISTING — it failed in the before-run at 381907f too — so nothing I changed caused it and nothing I changed is blocked by it.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260906T204025Z-7e25728e`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260906T204025Z-7e25728e --disposition "<what you decided or did>"
