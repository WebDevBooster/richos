# Escalation: Settled: the app's inner Claude Code loads no CLAUDE.md — and auto-memory IS a live channel

- id: `esc-20260906T084232Z-0f0ada64`
- raised: 2026-09-06T08:42:32Z
- from: echo-opus-sn1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-sn1` (branch `echo-opus-sn1`)
- head: `fa472afcc12bc13759bc2e62200d522ab68c2526`
- state: **work-complete**
- for: lead

## The question

Which mechanism carries the onboarding instruction — add 'project' to --setting-sources (partly reverses the stated intent at native.rs:16), --append-system-prompt, the re-prime priming turn, or the auto-memory file that already reaches it unchanged?

## What was already tried

Nine driven turns against claude 2.1.263 reproducing native.rs::child_args, one flag value manipulated; record committed at docs/verification/claude-md-sentinel-2026-09-06/ on branch echo-opus-sn1 (fa472af)

## Proceeding meanwhile

Nothing — the measurement is complete and no fix was attempted, per the brief

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260906T084232Z-0f0ada64`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260906T084232Z-0f0ada64 --disposition "<what you decided or did>"
