# Escalation: Candidate .8: background jobs still do not run — new refusal 6.28s after registration

- id: `esc-20260918T103641Z-1a073bd3`
- raised: 2026-09-18T10:36:41Z
- from: ray-opus-cand8walk3
- worktree: `/Users/alex/ab/richos-wt/ray-opus-cand8walk3` (branch `cc/ray-opus-cand8walk3`)
- head: `ec620488cfa6251556b6fdb9a851e436054972ae`
- state: **proceeding**
- for: lead

## The question

Is the executive-continuity seat expected to be bindable on the QA scratch home, or does the background-work path need a second engine seat that this build cannot provide?

## What was already tried

Walked the running candidate v1.2.0-nightly.20260918.2 (tag commit a7c875d6, carrying ee59193a). One job registered at 10:35:42.910Z and went state=failed at 10:35:49.190Z, 6.28s later, detail 'cognition io: Executive continuity is unavailable: the selected engine cannot hold a separate seat for background work, and binding one here would overwrite the CEO's own.' notes.txt is unchanged. Candidate .7 failed at the same point with 'The desktop engine plugin did not load' at 6.5s.

## Proceeding meanwhile

Continuing the walk: front-desk responsiveness during the failed job, window-close and quit rows, and the carried UI rows.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T103641Z-1a073bd3`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T103641Z-1a073bd3 --disposition "<what you decided or did>"
