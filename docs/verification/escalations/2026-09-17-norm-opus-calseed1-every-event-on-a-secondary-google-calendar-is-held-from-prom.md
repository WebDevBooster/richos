# Escalation: Every event on a SECONDARY Google calendar is held from promotion — its organizer is the calendar, which governance reads as external

- id: `esc-20260917T100618Z-b4de9fbe`
- raised: 2026-09-17T10:06:18Z
- from: norm-opus-calseed1
- worktree: `/Users/alex/ab/richos-wt/norm-opus-calseed1` (branch `cc/norm-opus-calseed1`)
- head: `0c00cd873f502a65721b50ab772e2c903fc3f4f5`
- state: **work-complete**
- for: lead

## The question

Is holding every secondary-calendar event as 'single untrusted item' the intended behavior of the multi-calendar widening (CEO decision 44), or should governance treat an organizer that is one of the account's OWN calendars as self?

## What was already tried

Derived, not guessed: the fixture set's expectation table is produced by running each event through the product's own toSourceItem -> resolveActors -> classifyTrust -> promotionDecision. A meeting created natively on a secondary calendar comes back with organizer.email = the calendar's id (c_xxx@group.calendar.google.com). governance.resolveOrgRelation matches on the email address alone and discards the vendor's own organizer.self flag, so the author resolves to 'external' -> immune.classifyTrust sets class 'untrusted' -> synthesis.reconcile holds it as 'single untrusted item — needs corroboration from a trusted source'. The same event on the primary calendar promotes, because the primary calendar's id IS the account address. Reproduced end to end in test/calendar-seed-acceptance.mjs --mock (fixture board-prep-shared, PASS against the prediction — the pipeline is self-consistent; the question is whether the rule is right).

## Proceeding meanwhile

Shipped as a stated expectation rather than a silent surprise: the fixture board-prep-shared exists to put this in front of a reader, and calendar-fixtures.js documents it as vendor fact 4. No product code was changed — governance and the adapters are Mark's, and this is a rule decision, not a bug fix I should take unilaterally.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T100618Z-b4de9fbe`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T100618Z-b4de9fbe --disposition "<what you decided or did>"
