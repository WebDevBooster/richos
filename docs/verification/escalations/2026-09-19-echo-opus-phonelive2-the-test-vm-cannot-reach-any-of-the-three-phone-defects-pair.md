# Escalation: The test VM cannot reach any of the three phone defects: pairing needs a Tailscale certificate the guest is deliberately signed out of

- id: `esc-20260919T191255Z-0f3d73c7`
- raised: 2026-09-19T19:12:56Z
- from: echo-opus-phonelive2
- worktree: `/Users/alex/ab/richos-wt/echo-opus-phonelive2` (branch `cc/echo-opus-phonelive2`)
- head: `eabce90d81260f52b3a8b6f8ce0181a3ddb23930`
- state: **work-complete**
- for: ceo

## The question

Will you sign Tailscale in on the test-VM guest once (ssh admin@<guest-ip> 'tailscale up', approve the node), so the guest can issue itself a certificate and the phone channel can start there? Without it no agent can ever put a live pairing code, a paired phone, or a phone-to-Mac message on a screen.

## What was already tried

Re-derived the brief's premise in the code rather than assuming it. PhoneRuntime::begin_pairing (richos/app/src-tauri/src/phone/mod.rs:858-862) returns PhoneError::TailnetNotReady unless serving_plan returns Some, and serving_plan (same file:563-580) requires BOTH a tailnet name/origin AND a certificate fetched from the tailscale CLI - there is no localhost path, no env override and no second plan, because CEO 61 removed the second route. The guest's Tailscale is installed and left signed out on purpose (richos/app/scripts/testvm/provision-guest.sh:147-153), and docs/testvm.md action 1 says signing it in needs the CEO's own account and that no agent may hold or borrow those credentials. So the brief's step 'use https://localhost:8443/#pair=<code>' has no code to use: the port never opens. Separately docs/testvm.md records there are no model turns in the guest (no claude login), so even with a code the 'bubble lands BEFORE the reply' half has no reply to be before.

## Proceeding meanwhile

All three defects are fixed, reproduced RED on the shipped tree f247c535 in the headless harness and GREEN on my branch, and committed. I am building my own bundle now and will put what IS reachable in the guest on screen: the phone sheet's new flex-column footer and the Settings row's quiet state at 1024x700 on the real binary. The live-code sheet, the paired row and the phone-to-Mac latency stay NOT RUN on screen and are named as such in my handoff.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260919T191255Z-0f3d73c7`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260919T191255Z-0f3d73c7 --disposition "<what you decided or did>"
