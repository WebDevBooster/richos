# Escalation: Both land-cost plans rest on a false premise: CI was GREEN 18 times on push and was MANUALLY DISABLED on 2026-09-01

- id: `esc-20260909T225102Z-56e7a757`
- raised: 2026-09-09T22:51:02Z
- from: frank-opus-lc2
- worktree: `/Users/alex/ab/richos-wt/frank-opus-lc2` (branch `frank-opus-lc2`)
- head: `202d46c2356f799a99d272d4b1d3a4ccca301261`
- state: **work-complete**
- for: lead

## The question

Given that push-triggered CI was green 18 times on 2026-08-29 and broke only as mutation harnesses went 0 to 40, does the plan get a cost governor on new suites/mutants before any sharding work starts?

## What was already tried

gh run list --limit 100: 86 runs, 18 green, all 2026-08-29, all push-triggered; both Sages used --limit 10 and took the truncation for the history. Daily suite-wait was <=1.2 h/day through August with CI equally absent, then 1.4 -> 21.2 h/day from 2026-08-28, the exact day the first mutation harness landed. Also verified: GitHub Free is 20 concurrent jobs account-wide shared with 6 other active workflows, and an exceeded limit DROPS webhook runs rather than queueing them, so a dropped run leaves no record for that SHA and the proposed tree-closure guard reads an older run and reports green.

## Proceeding meanwhile

Review committed at 202d46c2 on branch frank-opus-lc2 with all scripts and captured output under docs/measurements/land-cost-review-2026-09-09/. Nothing is blocked.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260909T225102Z-56e7a757`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260909T225102Z-56e7a757 --disposition "<what you decided or did>"
