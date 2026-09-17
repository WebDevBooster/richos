# Escalation: Row 7's mandated sentence has no control behind it, and the update gate is blind to background work

- id: `esc-20260917T170146Z-dbe541b8`
- raised: 2026-09-17T17:01:46Z
- from: echo-opus-lease1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-lease1` (branch `cc/echo-opus-lease1`)
- head: `c2cb794fdf362ce6f8ede9417ae5c665eef9a33a`
- state: **work-complete**
- for: lead

## The question

Does the next slice take the permission queue (spec §5.2/§5.5/§5.7) BEFORE rows 5 and 9, given that §7.6 and §7.8 cannot be walked at all without it — and is the update gate (§6.4) a same-slice fix or a separate one?

## What was already tried

Built rows 2,3,4,6,7 and measured them; ran the full UI suite, which is what surfaced the first gap through its own affordance rule rather than through my reading.

## Proceeding meanwhile

The app-side leg is complete and committed on cc/echo-opus-lease1; the surface says 'Ready for you to approve. Ask Rich to continue it when you are ready.' — §7.8's mandated phrase plus the only path that exists today — and the verification record names both gaps in full.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T170146Z-dbe541b8`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T170146Z-dbe541b8 --disposition "<what you decided or did>"
