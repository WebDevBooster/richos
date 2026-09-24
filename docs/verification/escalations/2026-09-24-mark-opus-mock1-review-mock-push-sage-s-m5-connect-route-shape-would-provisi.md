# Escalation: Review mock push: Sage's M5 'connect route shape' would provision real tunnels under richos.ceo, which M2 forbids

- id: `esc-20260924T003116Z-d1e843d0`
- raised: 2026-09-24T00:31:16Z
- from: mark-opus-mock1
- worktree: `/Users/alex/ab/richos-wt/mark-opus-mock1` (branch `cc/mark-opus-mock1`)
- head: `e45d301f359a543877798fb900f6e7523d037f5d`
- state: **proceeding**
- for: lead

## The question

May the review mock register push with route 'tailnet' (push-only enrollment, no tunnel) instead of M5's 'connect' shape, accepting that the Worker's device-hash check (F5) does not apply to the mock until F5's phone-signed registration exists?

## What was already tried

Read connect/lifecycle.mjs and connect/notifications.mjs at e45d301f. A 'connect' registration needs host.desired=1 and phase='active' (notifications.mjs register), and only POST /v1/hosts reaches 'active', by calling provider.createTunnel and provider.dns, which creates a Cloudflare tunnel and a c-<id>-g<n>.richos.ceo DNS record per virtual host with no connector behind it. Push-only enrollment (POST /v1/push/hosts) sets desired=0, phase='disabled', so 'connect' registrations answer 409 pairing_changed.

## Proceeding meanwhile

Building with route 'tailnet' (exactly what the Mac sends for a non-Connect phone), own admitted host identities, no sender credentials in the mock, previews sealed as the Mac seals them. The route is one line in src/registration.mjs if the answer is different.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260924T003116Z-d1e843d0`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260924T003116Z-d1e843d0 --disposition "<what you decided or did>"
