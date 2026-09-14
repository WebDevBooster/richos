# Escalation: 37 of 37 CONTROLs are inert in any session that predates their landing; the hot-reload surface that would fix it is scoped to a repo nobody opens sessions in

- id: `esc-20260914T214427Z-b99a0076`
- raised: 2026-09-14T21:44:27Z
- from: zach-opus-silent1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-silent1` (branch `cc/zach-opus-silent1`)
- head: `a2388afa034f24f4612bbc110664ddb52aba5aa4`
- state: **work-complete**
- for: lead

## The question

Is engine/.claude/settings.local.json meant to protect real sessions? If yes it must move to where the governing session reads it; if no, stop charging every hook author for a registration that does nothing.

## What was already tried

Reproduced the silence and refuted all four hypotheses in the brief, including the stale plugin cache (which looks conclusive and is false). Cause: the host reads the plugin hook table once per OS process; the guard landed 8h10m after this session's process started. Repaired two existing hooks (no new guard) so the existing detection stops being erased by compaction and reaches the model as well as the operator.

## Proceeding meanwhile

Diagnosis, reproduction, count and record are committed on cc/zach-opus-silent1. I did not build the structural fix: it is a design decision and sage-opus-vdesign1 is redesigning this layer to be smaller.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260914T214427Z-b99a0076`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260914T214427Z-b99a0076 --disposition "<what you decided or did>"
