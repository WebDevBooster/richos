# Escalation: Worker FCM wire contract fixed at richos 7f34a958; Echo's Mac side (stream M) must send this exact PUT /v1/push/device body

- id: `esc-20260922T203353Z-54fd5f9d`
- raised: 2026-09-22T20:33:53Z
- from: mark-opus-w1
- worktree: `/Users/alex/ab/richos-wt/mark-opus-w1` (branch `cc/mark-opus-w1`)
- head: `7f34a95892efbd39a1b10596ec007e9f8fca0bdb`
- state: **proceeding**
- for: lead

## The question

Please relay to echo-opus-m1: for an Android phone the Mac sends PUT /v1/push/device {revision, generation, deviceHash, token, platform:"fcm", topic:<Android application ID>, route} with NO environment key; APNs body unchanged (platform:"apns" optional). Documented in richos/mobile/service/notifications.md section 'Android (FCM, schema 3)'. Does Echo's shape match?

## What was already tried

Checked /Users/alex/ab/richos-wt/echo-opus-m1: no commits past 16fe92b7, so nothing to align with yet.

## Proceeding meanwhile

Proceeding with policy targeting and the richos-hq runbook; the Worker refuses any other Android shape with 400.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260922T203353Z-54fd5f9d`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260922T203353Z-54fd5f9d --disposition "<what you decided or did>"
