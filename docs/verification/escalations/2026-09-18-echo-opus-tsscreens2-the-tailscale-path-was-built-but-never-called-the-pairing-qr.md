# Escalation: The Tailscale path was built but never called: the pairing QR handed out mm1.local, and the key tailscale cert returns would have been refused

- id: `esc-20260918T221459Z-eb5c5a0a`
- raised: 2026-09-18T22:14:59Z
- from: echo-opus-tsscreens2
- worktree: `/Users/alex/ab/richos-wt/echo-opus-tsscreens2` (branch `cc/echo-opus-tsscreens2`)
- head: `39f84462c2cb18f6d7d97dfa170129a871a7eea5`
- state: **proceeding**
- for: lead

## The question

Does the Tailscale serving wiring I added to PhoneRuntime::start (serving_plan) land with my screens branch, or does it want its own review before it reaches main?

## What was already tried

Measured on ec678bae by grep: zero production callers of tailnet::fetch_cert or listen::tls_config_with_tailnet. PhoneRuntime::start built a home-only TLS config and minted the pairing URL from names.origin(), so the QR carried https://mm1.local:8443 whatever Tailscale was doing. Separately, tailscale cert on this Mac returns an EC PRIVATE KEY (SEC1) and certified_key wrapped every key as PKCS#8, so ring would have refused it. Both fixed and proven live: curl https://mm1.tail770f6e.ts.net:8443/ with no -k, no --cacert, no --resolve returns the phone app, and POST /api/pair over that origin returns a device_id. Record: docs/verification/tailscale-path-first-proven-run-2026-09-19.md

## Proceeding meanwhile

Continuing with the brief as written: the identity pre-screen, the clickable links with their allowlist, Urban's CSS, the registry rows and the READMEs.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T221459Z-eb5c5a0a`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T221459Z-eb5c5a0a --disposition "<what you decided or did>"
