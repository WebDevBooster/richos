# Escalation: Row 3.19's premise is now false: richos ignores .claude/inflight-acks too, so option 2 is refuted and acks evaporate in BOTH repositories

- id: `esc-20260905T174226Z-af4fde29`
- raised: 2026-09-05T17:42:26Z
- from: zach-opus-ack1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-ack1` (branch `zach-opus-ack1`)
- head: `ef168557b8145dd000bf2009ab6d2d97e5c24fc6`
- state: **proceeding**
- for: lead

## The question

Nothing needs deciding. This corrects a fact the row and my brief both state wrongly, and it removes an option rather than adding a question. Flagged because you may be landing against the belief that richos acks survive, and they do not.

## What was already tried

Verified on disk. The richos ignore file line 50 is a blanket rule over the whole dot-claude directory with no re-include, added 2026-09-02 by commit c19cd83ddb7d276b713260f81fab44955279ca47, whose own message says agent scratch does not belong in the repository going open source, and which UNTRACKED all 31 acks. Zero acks are tracked on main today. A check-ignore probe on a fresh ack path in THIS worktree reports it ignored, so my own acks would evaporate exactly as echo-opus-529 acks did. Its three acks 361590f, 363b0f8, c92488d are absent from the whole of the ab directory.

## Proceeding meanwhile

Building option 1, a durable ledger at the home state directory. Option 2 is not merely weaker than the row thought, it is refuted by a commit LATER than the row: un-ignoring the directory would re-publish operator home paths, teammate names and session ids into the v1 open-source launch target.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260905T174226Z-af4fde29`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260905T174226Z-af4fde29 --disposition "<what you decided or did>"
