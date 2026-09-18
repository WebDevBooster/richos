# Escalation: Row 8's double period is in richos-core, not the UI: the brief's 'UI half' does not exist

- id: `esc-20260918T085540Z-a89cf867`
- raised: 2026-09-18T08:55:40Z
- from: echo-opus-ui1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-ui1` (branch `cc/echo-opus-ui1`)
- head: `9c03b1d4a253a14b956e2e99ddd8eccc39f24cc1`
- state: **proceeding**
- for: lead

## The question

Who fixes assignment.rs:281? My brief forbids me richos-core and echo-opus-pluginbind1 owns it — row 8 ships unfixed unless it is routed there.

## What was already tried

grep of the whole app for the join: the ONLY producer is richos-core/src/assignment.rs:281 Receipt::sentence(), format!("I've taken down your assignment: {}. It's running now...", self.title) — the title already ends in a period (sanitize_title truncates to end in one, and the CEO's own title ended '...and land it.'), so the '.' in the format string is the second period. app/ui has NO join at all: grep -rn 'taken down your assignment|assignment:' app/ui/*.js returns nothing. Ray's row 8 also names a second, unrelated defect in the same card (the 'cognition protocol:' prefix) which the brief correctly assigns to pluginbind1.

## Proceeding meanwhile

Rows 3, 5, 9, 10, 11, 12, 13 — all UI, all mine, all proceeding.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T085540Z-a89cf867`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T085540Z-a89cf867 --disposition "<what you decided or did>"
