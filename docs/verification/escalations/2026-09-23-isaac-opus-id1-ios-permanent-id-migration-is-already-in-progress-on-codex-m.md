# Escalation: iOS permanent-ID migration is already in progress on codex/mobile-ios-setup (duplicate of isaac-opus-id1 item 1)

- id: `esc-20260923T213742Z-f341d626`
- raised: 2026-09-23T21:37:42Z
- from: isaac-opus-id1
- worktree: `/Users/alex/ab/richos-wt/isaac-opus-id1` (branch `cc/isaac-opus-id1`)
- head: `4edbfce13832862fbcb5bc00a3d34b814e854ca8`
- state: **proceeding**
- for: lead

## The question

Which branch lands the iOS dev.richos.connect migration: codex/mobile-ios-setup or cc/isaac-opus-id1? (I cannot inspect the Codex worktree; the guard refuses it.)

## What was already tried

richos-hq d64526d9 docs/operations/2026-09-23-richconnect-ios-setup.md says 'source migration is being checked on codex/mobile-ios-setup'; that branch is checked out at /Volumes/E1TB/state/codex/home/worktrees/mobile-firebase-setup/richos with HEAD 4edbfce1 (no commits yet, uncommitted state unknown).

## Proceeding meanwhile

Building item 1 with the EXACT identifiers that record already gave the CEO for the Apple portal (dev.richos.connect, dev.richos.connect.share, dev.richos.connect.notification-service, group.dev.richos.connect, keychain dev.richos.connect.shared) so either branch is interchangeable; item 2 (share outbox, notification backfill) does not overlap and proceeds regardless.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260923T213742Z-f341d626`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260923T213742Z-f341d626 --disposition "<what you decided or did>"
