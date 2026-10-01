# Escalation: Merge gate: the nightly does not run engine units, so most engine checks the gate leaves NOT RUN (nightly) never run anywhere

- id: `esc-20260930T223507Z-b12f0d6a`
- raised: 2026-09-30T22:35:07Z
- from: zach-opus-gate2
- worktree: `/Users/alex/ab/richos-wt/zach-opus-gate2` (branch `cc/zach-opus-gate2`)
- head: `4e73fd89b2e0bae65fb51b884469e18b8a8caaf8`
- state: **proceeding**
- for: lead

## The question

The brief says the gate leaves mutation passes and over-cap checks to the nightly. nightly-local.py has no engine gate: it runs only workspace-spec-fourteen and the four mega-lander units (gates/workspace-mutants). So (1) the standalone unit scripts/operator-fences-mutation.test.sh, (2) any engine unit over the 600 s cap, (3) every engine unit cut at the 900 s gate cap, and (4) the mutation harnesses about 70 engine hook suites run at their own end (ceo-todos.mutation.sh and others) are never run by the nightly. I am making the nightly run (1) and (2), derived from the same rules the gate uses, so those NOT RUN (nightly) lines become true. Decision needed: should the gate also turn off the embedded hook-suite mutation passes (4)? Doing that without a nightly engine gate means they would never run automatically; today they run only when a land selects their suite. Options: A) leave embedded passes on in the gate (current, they cost part of each engine unit); B) add a nightly engine gate running every engine unit with its passes, then switch them off in the merge gate; C) switch them off in the gate and accept no automatic run.

## What was already tried

Read nightly-local.py GATE_NAMES and every gate body (release-smoke, core-tests, updater-tests, script-suites, lint-tauri, workspace-mutants, ui-suite, privacy-sweep); only workspace-mutants runs ci-shard.sh, for five named units. Grepped 70 engine *.test.sh files that invoke a *.mutation.sh harness at their end; 41 of 64 harnesses source lib/mutation-harness.sh, the rest do not.

## Proceeding meanwhile

Proceeding with rules 1-3 of the brief: standalone mutation units never enter the gate and run at the nightly; over-cap checks are NOT RUN at once and the nightly runs the engine ones; cheap checks first. Embedded hook-suite passes are left as they are (option A) until answered, and the replay report states their cost.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260930T223507Z-b12f0d6a`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260930T223507Z-b12f0d6a --disposition "<what you decided or did>"
