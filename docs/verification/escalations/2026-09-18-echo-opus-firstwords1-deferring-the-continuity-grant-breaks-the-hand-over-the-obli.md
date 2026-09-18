# Escalation: Deferring the continuity grant breaks the hand-over: the obligation the register REQUIRES is opened by that same gated checkpoint tool

- id: `esc-20260918T141601Z-d0505a05`
- raised: 2026-09-18T14:16:01Z
- from: echo-opus-firstwords1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-firstwords1` (branch `cc/echo-opus-firstwords1`)
- head: `c9c2d6118ea2121bde52666fe9f1c65f02a8891d`
- state: **proceeding**
- for: lead

## The question

Given that the register's obligation must be an OPEN ECS item before the work lease's prepare runs, which way: (1) the register opens the obligation ITSELF when it records the assignment (app-owned id, model never names one — the exact argument mega-lander/app.py:157-161 already makes for the work lease, and it makes the deferred grant safe AND §55-clean at one tool call); or (2) keep the model naming it, defer the grant, and change the register's description plus the doctrine to 'name it, say your words, THEN open it after you have spoken' — which is a bet on model behavior whose failure is silent and lands later, on the work lease? I have implemented NEITHER, because (1) is the register's own logic, which my brief excludes, and (2) rewires the obligation contract on the strength of one instruction.

## What was already tried

Checked the chain before implementing your decision (a). mega-lander/app.py:318-321: prepare reads the ECS item named by obligation_id and raises 'dispatch requires an accepted open obligation' unless its status is accepted/active/pending/blocked. The register takes obligation_id as a MODEL argument and never verifies it (assignment_tools.rs:call), and its own description says 'Open it first'. The only tool the front desk has that can create that item is mcp__richos_continuity__checkpoint — the tool your option (a) defers: its opening verbs are priority/initiative/open_loop/commitment/decision/deadline/blocker (engine/ecs/core/ecs_core.py:57) and it is gated on the app-written actions_allowed (engine/ecs/adapters/mcp.py:25). So run B's pre-reply checkpoint WAS the model opening the obligation it then handed the register: {statements:[{fields:{id:'land-pricing-branch-staging-deploy'...}}]}. AND THE OTHER HALF IS WORSE: run A's turns called the register FIRST with no ECS write anywhere on the turn — its full trace ends at the register's answer — so both of run A's assignments carry an obligation that was never opened, and prepare would refuse them. Today a model that obeys §55 produces undispatchable work; a model that obeys the obligation contract costs him 3 s. Deferring the grant with no compensating change makes the first of those the only path.

## Proceeding meanwhile

My own slice is done and measured and I am finishing its budgets and record. I have spent the six model turns the brief allows (two runs of three: the priming turn plus two visible turns), so run C needs either more turns or a decision that costs none. The gate-truth documentation is landed either way: native.rs now carries the measurement that bookkeeping_before_the_reply does not fire under --permission-mode auto.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T141601Z-d0505a05`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T141601Z-d0505a05 --disposition "<what you decided or did>"
