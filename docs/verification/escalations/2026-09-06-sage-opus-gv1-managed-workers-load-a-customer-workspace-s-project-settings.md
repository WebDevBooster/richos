# Escalation: Managed workers load a customer workspace's project settings AND its hooks

- id: `esc-20260906T090329Z-9de77679`
- raised: 2026-09-06T09:03:30Z
- from: sage-opus-gv1
- worktree: `/Users/alex/ab/richos-wt/sage-opus-gv1` (branch `sage-opus-gv1`)
- head: `831c6b5a8807f99a3ca3eaf05b2c2b2800ecabe5`
- state: **work-complete**
- for: ceo

## The question

Are a customer workspace's .claude/settings.json hooks a trusted input to a managed run, or must managed_child_args stop loading the project and local sources?

## What was already tried

Read at richos 041eee8 while designing the inner-doctrine channel. native.rs:349 managed_child_args splices --setting-sources to 'user,project,local' and drops --no-session-persistence, so a managed worker running in the customer's own workspace loads that workspace's project settings and any hooks configured there. That is the exact thing child_args' own comment at :316-317 says RichOS must not do. It IS sandboxed (sandbox enabled, failIfUnavailable true, blockReadsOutsideWorkingDirectories true), which is a real mitigation and why this is a question rather than an accusation. I did not touch it - engine and app ownership sat with other live agents and it was outside my brief.

## Proceeding meanwhile

My own deliverable is committed: docs/plans/richos-inner-doctrine-2026-09-06.md at 831c6b5 on branch sage-opus-gv1. This is recorded in section 8 of that document too; it is raised here so it does not depend on that branch being merged.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260906T090329Z-9de77679`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260906T090329Z-9de77679 --disposition "<what you decided or did>"
