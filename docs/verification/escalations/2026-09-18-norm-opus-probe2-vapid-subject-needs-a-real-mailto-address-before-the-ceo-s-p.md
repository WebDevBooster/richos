# Escalation: VAPID_SUBJECT needs a real mailto: address before the CEO's push walk

- id: `esc-20260918T105634Z-85b52f90`
- raised: 2026-09-18T10:56:34Z
- from: norm-opus-probe2
- worktree: `/Users/alex/ab/richos-wt/norm-opus-probe2` (branch `cc/norm-opus-probe2`)
- head: `549d58390ad588acda6a5abe8b290a5b137b5e02`
- state: **proceeding**
- for: lead

## The question

Which mailto: address should VAPID_SUBJECT carry — the CEO's own, a role address, or shall the probe use the https origin form instead?

## What was already tried

Confirmed the sender runs unchanged from the Mac (outbound HTTPS only, no inbound). Left the default mailto:probe@richos.invalid in place, which Google's FCM accepts and Apple rejects with BadJwtToken — so check 4 would fail on his iPhone for a reason that has nothing to do with the phone. I will not invent an address: the VAPID subject travels in a JWT header to Apple, so it is a real identifier being handed to a third party.

## Proceeding meanwhile

Everything else in the brief: local CA, HTTPS server, trust step, reachability, desktop verification. The server boots with the placeholder and warns loudly at every start until the value is set, so nothing is silently wrong.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T105634Z-85b52f90`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T105634Z-85b52f90 --disposition "<what you decided or did>"
