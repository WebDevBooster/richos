# Escalation: His per-thread seats are built, but nothing will ever reconcile one: reconcile_seats skips them and sits outside my footprint

- id: `esc-20260917T193917Z-db08845a`
- raised: 2026-09-17T19:39:17Z
- from: norm-opus-ceoseat1
- worktree: `/Users/alex/ab/richos-wt/norm-opus-ceoseat1` (branch `cc/norm-opus-ceoseat1`)
- head: `731bf2f557acd362bfbe258a7615ee0c939e8ca7`
- state: **work-complete**
- for: lead

## The question

Who lands the CEO-seat arm of reconcile_seats in richos/engine/mega-lander/app.py, given norm-opus-landlock2 is in that file and my brief forbade me to touch it?

## What was already tried

Built and tested the whole engine half in richos/engine/ecs: a derived seat per thread, positive identification, and release-seat that accepts one of his orphaned thread seats, refuses ceo-default by name, refuses a self-release and refuses a seat that moved since it was enumerated. Ran the lander's own app.test.py (27/27) to prove I broke nothing there.

## Proceeding meanwhile

The engine half is committed on cc/norm-opus-ceoseat1 and green; mega-lander/app.py:946 reconcile_seats still filters 'if row[audience] != worker: continue', so his thread seats are enumerated by the seats command and then skipped, and an orphan thread seat would live forever. The arm needed is about six lines: for a row that is one of his (audience ceo, person_id == 'ceo-thread:' + thread_id, never ceo-default), ask the app whether that conversation thread still exists instead of asking assignment_state, and pass expected_revision=row[revision] to release-seat.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T193917Z-db08845a`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T193917Z-db08845a --disposition "<what you decided or did>"
