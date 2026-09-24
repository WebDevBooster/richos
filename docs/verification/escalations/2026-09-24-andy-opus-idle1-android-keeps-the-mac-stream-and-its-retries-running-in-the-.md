# Escalation: Android keeps the Mac stream and its retries running in the BACKGROUND: the CEO's 'power-intensive app' warning class

- id: `esc-20260924T003215Z-b1c45a2f`
- raised: 2026-09-24T00:32:15Z
- from: andy-opus-idle1
- worktree: `/Users/alex/ab/richos-wt/andy-opus-idle1` (branch `cc/andy-opus-idle1`)
- head: `87a854210c333798db2ca10f401f9811e4c6d206`
- state: **proceeding**
- for: lead

## The question

Take this into my branch now (stop the connection owner when no activity is started, resume on start, as iOS does), or route it elsewhere? Evidence, e45d301f source: RichApplication.onCreate launches ConnectionOwner.run() in the process MainScope and nothing stops it on background (onActivityStopped is a no-op; RichApplication.kt ~lines 93-96, 124); ConnectionOwner reconnects forever with a back-off capped at 30 s (ConnectionOwner.kt backoffMs, MAX_RETRY_MS) and, when connected, holds an SSE socket whose keep-alive arrives every 15 s (HttpsMac.kt STREAM_READ_TIMEOUT_MS comment); NetworkWake fires wake() on every network change for the life of the process; the AppStore drain retries on its back-off while online. So a cached Android process with the Mac asleep reconnects every 30 s, and with the Mac awake takes a network wakeup every 15 s, in the background. iOS does not: ConnectionReducer .backgrounded -> .disconnect ('No stream in the background (build plan 3.2): APNs is for awareness, the foreground reconciles'). Push (FCM) already covers the background on Android.

## What was already tried

Read the code paths above; not changed (outside my brief). My own commits only remove wakeups.

## Proceeding meanwhile

Finishing the idle-redraw work, the pulse rest and the crash fix, with Battery-check trailers.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260924T003215Z-b1c45a2f`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260924T003215Z-b1c45a2f --disposition "<what you decided or did>"
