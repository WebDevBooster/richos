# Escalation: Candidate .13 phone flow: 'At home only' serves the tailnet — signoff withheld at 7/10

- id: `esc-20260919T104610Z-3b54862c`
- raised: 2026-09-19T10:46:11Z
- from: urban-opus-phoneflow2
- worktree: `/Users/alex/ab/richos-wt/urban-opus-phoneflow2` (branch `cc/urban-opus-phoneflow2`)
- head: `a2cef8eeedc31cc0363c9589a9a7756ccc7f4c3c`
- state: **work-complete**
- for: lead

## The question

Does the At-home route get fixed to honor the user's answer (pass the route to phone_begin_pairing/serving_plan), or does the chooser stop offering it on a tailnet-signed-in Mac?

## What was already tried

Walked candidate .13 live on pid 68309, both themes, 1024x700. G1-G8, G10, G12-G14 all verified FIXED from my own pixels; zero contrast failures. Then chose 'At home only' and pressed 'Set my phone up': the screen that appears is the Tailscale screen with a tailnet pairing URL and 'Install Tailscale / Sign in with <his account>'. phone_begin_pairing takes no route argument (main.rs:706) and serving_plan picks the tailnet whenever its cert is available (phone/mod.rs:504,783), so the user's answer never reaches the backend.

## Proceeding meanwhile

Signoff written and withheld at docs/verification/ui-ux-signoffs/URBAN_SIGNOFF_2026-09-19_10.40.md with 24 frames; my recommendation is to pass the route through rather than remove the option.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260919T104610Z-3b54862c`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260919T104610Z-3b54862c --disposition "<what you decided or did>"
