# Escalation: Item 5 (no private pilot): the code removes the admission gate, but the live Connect Worker keeps refusing until an operator redeploys it, and its 10-host lifetime ceiling is probably already full

- id: `esc-20261006T101352Z-400f4f4b`
- raised: 2026-10-06T10:13:52Z
- from: echo-opus-fbcopy
- worktree: `/Users/alex/ab/richos-wt/echo-opus-fbcopy` (branch `cc/echo-opus-fbcopy`)
- head: `1d0808314a45618cf64699f8cdc67683caf65696`
- state: **proceeding**
- for: lead

## The question

Who redeploys the Connect Worker from this branch (it no longer has allowed_hosts admission or the ENROLLMENT_OPEN switch), and what HOST_CAPACITY should the private deployment profile carry? The code no longer clamps it at 10; the number is the operator's profile value.

## What was already tried

Removed the admission step in richos/mobile/service (lifecycle.mjs, store.mjs, connect-worker.mjs, schema.sql, cli/connect.mjs), its tests, the review-mock admission SQL, the Mac's 403 pilot message and the popup's 'Pilot setup reference'. Connect service suite 16/16 on the branch. I cannot deploy (brief: no deploy). The record says the ceiling is the pilot: richos-hq docs/operations/2026-09-22-richos-connect-managed-service.md lines 22 and 55, and cli/connect.mjs called it 'Pilot capacity must be between 1 and 10'. review-mock/README.md (2026-10-03) records the live D1 at 8 of 10 lifetime hosts with the 2 left admitted to the review hosts, so a new Mac is likely refused for capacity today. On the old Worker that refusal showed the CEO exactly the private-pilot message.

## Proceeding meanwhile

Finishing items 3, 5, 6 and 7 on cc/echo-opus-fbcopy. A full service now answers 503 capacity_reached and the Mac shows its existing 'could not be reached, try again shortly' line. The live D1 still has an allowed_hosts table; nothing reads it after the redeploy, and dropping it is an operator step.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261006T101352Z-400f4f4b`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261006T101352Z-400f4f4b --disposition "<what you decided or did>"
