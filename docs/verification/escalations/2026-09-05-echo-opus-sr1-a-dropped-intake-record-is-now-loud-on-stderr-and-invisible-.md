# Escalation: A dropped intake record is now loud on stderr and invisible in the window — the surface question is open

- id: `esc-20260905T115011Z-1ab00170`
- raised: 2026-09-05T11:50:11Z
- from: echo-opus-sr1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-sr1` (branch `echo-opus-sr1`)
- head: `baec5632214d30191566a8ce97671876405a1bb1`
- state: **work-complete**
- for: lead

## The question

Should the intake log's IntakeHealth be rendered to the CEO, and if so is one extra sentence inside the EXISTING #history-notice the surface, or does 'something you typed never reached Rich' need its own placement?

## What was already tried

Fixed the silence in richos-core: classified, counted, reported, never fatal, plus the boot line beside the ledger's. Deliberately did NOT build a UI notice, per the brief's 'do not build a second notice system'. TurnControl::intake_health() is the seam ready to read.

## Proceeding meanwhile

Branch is complete and committed. Two further findings in the same file are recorded but not fixed: correction.rs:466 is the one remaining reader in the same class (a dropped record can silently revert a confirmed loro write to pending), and five readers still end their iterator at the first bad byte.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260905T115011Z-1ab00170`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260905T115011Z-1ab00170 --disposition "<what you decided or did>"
