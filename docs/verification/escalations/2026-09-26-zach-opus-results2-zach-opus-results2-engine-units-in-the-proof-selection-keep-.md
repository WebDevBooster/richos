# Escalation: zach-opus-results2: engine units in the proof selection keep failing the record canary on the lead's own spawns

- id: `esc-20260926T071141Z-64b412d7`
- raised: 2026-09-26T07:11:41Z
- from: zach-opus-results2
- worktree: `/Users/alex/ab/richos-wt/zach-opus-results2` (branch `cc/zach-opus-results2`)
- head: `a23e5c2f857cc6811da7d97e9a0fc822d9c7406c`
- state: **proceeding**
- for: lead

## The question

Can you hold spawns, lands and discards for about 15 minutes while I rerun the canary-tripped engine units (contract-integrity IP, Qscope, WTI, plus any further ones), and tell me the window through my task? Otherwise, is a unit whose only failure is canary rows naming only session c11805a4's own spawns acceptable as proven?

## What was already tried

Retried each tripped unit alone: M and IL passed alone at a23e5c2f; WTI tripped again alone (rows: sage-opus-opcontract1 registered/cc-created, echo-opus-opshell1 protected-ref-landed-elsewhere). Proof-run Phase B: completeness-commits tripped on reed-sonnet-esctriage1; IP and Qscope tripped on isaac-opus-verssplit1. record-canary.sh's header names 'a real spawn during the run' as its known false-positive vector, and ci-shard hides the unit's own exit when the canary fires, so these units are unproven, not failed. I did not point CLAUDE_CONFIG_DIR at a copy: that would blind the canary to a real leak.

## Proceeding meanwhile

Finishing the rest of the selection (app suites, Gradle, iOS one at a time) and retrying each tripped engine unit alone as the machine allows.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260926T071141Z-64b412d7`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260926T071141Z-64b412d7 --disposition "<what you decided or did>"
