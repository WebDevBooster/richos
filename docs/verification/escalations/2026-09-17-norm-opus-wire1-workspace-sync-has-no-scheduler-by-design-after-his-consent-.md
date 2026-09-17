# Escalation: Workspace sync has no scheduler by design — after his consent, nothing pulls until someone runs the command

- id: `esc-20260917T005859Z-122ba5c1`
- raised: 2026-09-17T00:58:59Z
- from: norm-opus-wire1
- worktree: `/Users/alex/ab/richos-wt/norm-opus-wire1` (branch `cc/norm-opus-wire1`)
- head: `bf89351b44f7cc5eb7d5f90eaaba66aa4823f4ad`
- state: **work-complete**
- for: ceo

## The question

Should RichOS poll his Calendar/Drive/Gmail on a schedule (a background agent with its own lifecycle), or does he pull on demand for now?

## What was already tried

Built connect/status/sync --once/disconnect, all three sources registered, 219 mock-verified cases green; --daemon/--watch/--every are refused BY NAME rather than ignored, and the rewritten guide now says plainly that nothing runs on a schedule (it previously claimed RichOS 'will now poll your calendar every few minutes', which was never true).

## Proceeding meanwhile

Nothing is blocked. The source is fully usable on demand the moment he consents; a scheduler is additive and touches no code written here.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T005859Z-122ba5c1`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T005859Z-122ba5c1 --disposition "<what you decided or did>"
