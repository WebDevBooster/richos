# Escalation: Both failing scorecard rows have a different cause than the brief states

- id: `esc-20260917T113236Z-f6343a1b`
- raised: 2026-09-17T11:32:36Z
- from: norm-opus-residue1
- worktree: `/Users/alex/ab/richos-wt/norm-opus-residue1` (branch `cc/norm-opus-residue1`)
- head: `df2063f876b370f0e68446ce3c41576acd00e091`
- state: **proceeding**
- for: lead

## The question

Nothing needs deciding to proceed — this records that the brief's two diagnoses are contradicted by the CEO's own zone, so the fixes are not the ones the brief prescribed.

## What was already tried

Read the live zone read-only. cross-calendar-dup: Google assigned ONE event id to both copies (both manifest rows carry eventId _e9pjcdr2c4qj..., one evidence item, one promoted record superseding the earlier revision) so the pipeline merged correctly and the acceptance check FAILs only because it observes the same sourceItemId twice. Mateo Silva: he is on ONE item with THREE revisions, every revision status=confirmed, no withdrawal anywhere in the zone; the product's own tallyCorroboration counts REVISIONS not ITEMS, so three re-seeds of one meeting taught his name. The withdrawal hypothesis is moot - the only withdrawn item in the zone was cancelled from its first revision.

## Proceeding meanwhile

Fixing the two REAL defects (per-item corroboration, and the cross-run identity gap the fixture could never exercise), fixing the double-counting check, with mocked proof.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T113236Z-f6343a1b`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T113236Z-f6343a1b --disposition "<what you decided or did>"
