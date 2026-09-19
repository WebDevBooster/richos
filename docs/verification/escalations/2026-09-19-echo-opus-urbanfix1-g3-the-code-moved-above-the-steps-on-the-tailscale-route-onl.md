# Escalation: G3: the code moved above the steps on the Tailscale route only — the home route's 1-2-3 is a real dependency

- id: `esc-20260919T071935Z-871a57cc`
- raised: 2026-09-19T07:19:35Z
- from: echo-opus-urbanfix1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-urbanfix1` (branch `cc/echo-opus-urbanfix1`)
- head: `f8bddbd2ac8e6e335965f17048516870b3ee3675`
- state: **work-complete**
- for: lead

## The question

Does Urban accept the code block staying BELOW the certificate step on the At-home route, or does he want it above on both routes with the numbering re-cut?

## What was already tried

Re-read G3 and finding 2 against his frames: 01-06 are the Anywhere path (frame 02 is 'This Mac is ready'), where the headings carry no numbers and the four phone steps are preparation. The home route's headings are '1. Point your camera at this, to install the certificate', '2. Then point it at this, to open Rich', '3. Check the six words match', and the sequence is a real dependency — the pair URL is https://<name>.local:8443 and opens only once step 1's certificate is installed and trusted. Moving the code above it would put step 2 above step 1 on the one path where the order is load-bearing. Built the fallback: one wrapper node, moved by render() per route; ui/tests/phone.js check 20 asserts order on BOTH routes in opposite directions and that the home numbering still matches its own order.

## Proceeding meanwhile

All ten gaps (G2-G6, G8, G10, G12-G14) are built, committed and green; the At-home walk was out of scope for Urban's audit anyway, so if he wants it above on both routes it is a one-line change to the anchor plus a re-cut of the three headings.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260919T071935Z-871a57cc`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260919T071935Z-871a57cc --disposition "<what you decided or did>"
