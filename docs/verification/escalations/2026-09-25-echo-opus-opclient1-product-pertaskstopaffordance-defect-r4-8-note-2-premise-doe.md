# Escalation: Product perTaskStopAffordance 'defect' (r4 §8 note 2): premise does not hold; not changing native.rs without a word

- id: `esc-20260925T093304Z-c914896a`
- raised: 2026-09-25T09:33:04Z
- from: echo-opus-opclient1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-opclient1` (branch `cc/echo-opus-opclient1`)
- head: `8ef07e5b7e748088e591f549b8d86c9e836fcb30`
- state: **proceeding**
- for: lead

## The question

Should the product client declare perTaskStopAffordance at all? Measured in code: every production lease is an engine lease (start_with_engine / start_work_lease, profile Some), so settle_workers_on_stop is true and NativeCancelHandle::cancel fence-kills the child's whole group right after the interrupt (native.rs:2933, :2945) — background agents die on a product Stop with or without the field, and that is the product's documented rule ('the CEO stops -> worker withdrawn', native.rs:4271 table). The product client never sends stop_task, so declaring 'I render a per-task stop wired to stop_task' would be false, and on the two non-engine constructors (start_with_onboarding/start_with_continuity) it would leave spared agents running after a Stop. I propose: no product change; Sage's §8 note 2 recorded as not-a-defect. Say 'declare it anyway' and I will.

## What was already tried

Read native.rs initialize (:1926), cancel (:2914-2947), every cancel() caller (steering.rs:970 conversation Stop, work_host.rs:1910 assignment Stop), and the four NativeCognition constructors (:3147-3263).

## Proceeding meanwhile

Building the operator client (which does declare it, truthfully: it sends stop_task), host, claim, register and probes; the product file is untouched.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260925T093304Z-c914896a`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260925T093304Z-c914896a --disposition "<what you decided or did>"
