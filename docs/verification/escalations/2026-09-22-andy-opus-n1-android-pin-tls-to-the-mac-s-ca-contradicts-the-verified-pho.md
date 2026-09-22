# Escalation: Android: 'pin TLS to the Mac's CA' contradicts the verified phone protocol; pinning would break both routes

- id: `esc-20260922T224247Z-4aacf6f4`
- raised: 2026-09-22T22:42:47Z
- from: andy-opus-n1
- worktree: `/Users/alex/ab/richos-wt/andy-opus-n1` (branch `cc/andy-opus-n1`)
- head: `4b377cfdc192d80104d0192aa424b447953a188f`
- state: **proceeding**
- for: lead

## The question

Build the Android Http on the platform's default trust store with no pin, as the protocol contract §1.1 says (Tailscale serves a publicly trusted chain when SNI is the tailnet name; Connect is terminated by Cloudflare) — or does Rich/the CEO want a pin anyway, knowing it would refuse both real routes?

## What was already tried

Read richos-hq docs/specs/2026-09-22-phone-protocol-contract.md §1.1: 'Use the platform's default trust store. Pin nothing. The Mac's self-signed certificate authority still exists. Only its hash is used, for the six words.' The Mac's CA leaf is served only for a non-tailnet SNI or a bare IP, which clients must not use.

## Proceeding meanwhile

Building the Keystore identity now, and the Http/EventStream on the default trust store with host-name-only connections (no IP), no pin, HTTPS only; switching to a pin is a small change if you rule for it

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260922T224247Z-4aacf6f4`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260922T224247Z-4aacf6f4 --disposition "<what you decided or did>"
