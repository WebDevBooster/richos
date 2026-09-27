# Escalation: Operator back end: every r4 section 6 item in the brief is already built and on richos main; nothing operator-side is left for echo to build

- id: `esc-20260927T064405Z-eba2b046`
- raised: 2026-09-27T06:44:06Z
- from: echo-opus-opbuild1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-opbuild1` (branch `cc/echo-opus-opbuild1`)
- head: `ea803a1fddf14e067c34b1f300b701c0e73b7de6`
- state: **proceeding**
- for: lead

## The question

The only unbuilt echo-owned items left in r3/r4 are two PRODUCT defects r3 section 8 recorded for echo: (1) the renewal handover sentence that contradicts the CEO's section 52 (building it now), and (2) the product supervisor's reap gap (P15: 4 of 4 tool processes outlive the app's death), which changes the path every customer runs and which r3 kept a non-goal with N1 pinning native.rs. Build (2) now as a product change, or send it to Sage for a design pass first?

## What was already tried

Re-derived every r4 section 6 item against richos main ea803a1f with file:line: perTaskStopAffordance and no-priority (operator_lead.rs:70-78, mutant lead-affordance), stdin rule (operator_lead.rs:607-615, mutant lead-close-input), task status (operator_lead.rs:112-241), registry step 3a (operator_host.rs:1127-1145, operator_runtime.rs:146-150), F7 reduced (mutants host-stop-every-channel, host-no-origin), CLAUDE_CODE_ARTIFACT (operator_profile.rs:60, :257), harness P5/P6/P12'/P16/P17 (guest_probes.py:909-920, :1243, :1791-1806, :2248-2277); all recorded PASS in richos-hq docs/verification/2026-09-24-operator-probes and 2026-09-25-operator-client, built by echo-opus-opclient1 and opshell1. The engine claim hook's compact/resume idempotency (r4 2.4) is also built (operator_leads.py:283-311, test C2).

## Proceeding meanwhile

Building r3 section 8's renewal-handover fix test-first in work_host.rs, then the scoped proof run; the remaining operator items (notice surface, PRD S6, W2 on the window from an operator nightly, the switch) belong to Art, Codex, Ray and Rich per the client record section 7.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260927T064405Z-eba2b046`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260927T064405Z-eba2b046 --disposition "<what you decided or did>"
