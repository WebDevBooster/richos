# Escalation: Android A1: CPU admission refuses every Gradle run; first core build has waited 10+ minutes

- id: `esc-20260922T203115Z-49931705`
- raised: 2026-09-22T20:31:15Z
- from: andy-opus-n1
- worktree: `/Users/alex/ab/richos-wt/andy-opus-n1` (branch `cc/andy-opus-n1`)
- head: `3232a18547d29864f7bacfb573d1c1f4f5970f8f`
- state: **proceeding**
- for: lead

## The question

May the first Gradle compile of :core run without reserve.py while the host stays at 0% idle, or should A1 keep waiting for admission?

## What was already tried

reserve.py retried every 10 s for 630 s: every sample 99.8-100% busy (top: 0.0% idle, ~55% sys; com.apple.Virtualization ~134% CPU); release.lock also held at +593 s

## Proceeding meanwhile

Writing the CLI, app entry, debug bridge, bin/randroid and the two suites; the admission loop keeps retrying and the build runs the moment it is admitted

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260922T203115Z-49931705`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260922T203115Z-49931705 --disposition "<what you decided or did>"
