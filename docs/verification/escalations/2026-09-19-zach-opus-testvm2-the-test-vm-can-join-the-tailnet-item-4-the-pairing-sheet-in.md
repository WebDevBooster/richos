# Escalation: The test VM can join the tailnet; item 4 (the pairing sheet in a VM) needs the CEO's auth key, which no agent can produce

- id: `esc-20260919T194201Z-1286b368`
- raised: 2026-09-19T19:42:01Z
- from: zach-opus-testvm2
- worktree: `/Users/alex/ab/richos-wt/zach-opus-testvm2` (branch `cc/zach-opus-testvm2`)
- head: `8b39e5d52d6c8aa379bdc307e44cbfc7568dd219`
- state: **work-complete**
- for: lead

## The question

When the key is saved at ~/.richos-testvm/tailscale.authkey, which candidate bundle should the in-VM pairing walk use — and does it want me or a QA teammate?

## What was already tried

Built and landed the whole join/logout/nodes/doctor path plus 41 tests; proved the refusal path end-to-end on live guests (43 s single, 72 s/66 s for two at once, all stopped clean). Everything except a real tailnet join is verified; a real join needs his account.

## Proceeding meanwhile

Nothing is blocked: the VM is fully usable for every non-phone proof without the key, and one command (tailnet.sh doctor <vm>) settles the join the moment the key exists.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260919T194201Z-1286b368`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260919T194201Z-1286b368 --disposition "<what you decided or did>"
