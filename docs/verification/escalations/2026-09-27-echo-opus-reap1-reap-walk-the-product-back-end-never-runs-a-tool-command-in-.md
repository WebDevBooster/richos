# Escalation: Reap walk: the product back end never runs a tool command in the test VM, so the Stop, Quit and crash-with-commands steps cannot be driven

- id: `esc-20260927T093052Z-85f3303f`
- raised: 2026-09-27T09:30:52Z
- from: echo-opus-reap1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-reap1` (branch `cc/echo-opus-reap1`)
- head: `39da4129d37cbd7c16967d4121aa10dbc6033455`
- state: **proceeding**
- for: lead

## The question

The reap is built and unit-proven; the VM walk needs Rich to start a background and a foreground command. In the guest, 4 background assignments on 39da4129 (Sonnet) ended failed 'No work was started' (trail.workers == 0); after approving the back end's 'running a command on your Mac' request, its claude started no process at all for 60 s (0.5 s process-table snapshots). echo-opus-adopt1 saw the same outcome on 98c3aef5 on 2026-09-26, not diagnosed. Who diagnoses the back end, and should the walk's command steps wait for that fix?

## What was already tried

Connected ~/Acme as the company repository (the front desk had registered a non-existent repositories path, home/myrichos/companies/acme); absolute paths; approved each request via the Under the hood panel; relaunched so leases carry the repository

## Proceeding meanwhile

Everything else: code, tests, mutants, proof run; VM-measured owner death (3 supervisors ended, all descendants gone), claude crash (ending: the provider exited, final state ended:true in 92 ms), idle supervisor CPU 0.15-0.19 s/min; reap-walk.py committed ready to run once the back end runs commands

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260927T093052Z-85f3303f`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260927T093052Z-85f3303f --disposition "<what you decided or did>"
