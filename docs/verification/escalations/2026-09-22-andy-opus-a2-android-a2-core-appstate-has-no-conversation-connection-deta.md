# Escalation: Android A2: core AppState has no conversation, connection detail, pairing, voice, notification or update state; 60 of 67 screens cannot render from AppState alone

- id: `esc-20260922T204145Z-7e81fe5e`
- raised: 2026-09-22T20:41:46Z
- from: andy-opus-a2
- worktree: `/Users/alex/ab/richos-wt/andy-opus-a2` (branch `cc/andy-opus-a2`)
- head: `dddd4bf358b16d27ab623fcf5c1233de2212a992`
- state: **proceeding**
- for: lead

## The question

Confirm A2 may render from a UI-side ScreenModel = AppState (draft, theme, online, paired, outbox, composerAction are read from it) plus typed fields core does not own yet (messages, connection line, pairing step, recordings, notification status, update notice), each to move into core's AppState when A1 adds it; and ask A1 to commit the app/ module so A2's branch builds.

## What was already tried

Read core State.kt/Action.kt at 8d93ef49: AppState has threads, selectedThreadId, draft, online, paired, theme, outbox, dueInMs, lastSend. Action has select-thread, compose, send, send-voice, network, retry, sync, discard, theme. No message history, reply stream, audio, pairing steps, forget-pairing, notification or update fields/actions. app/ exists only uncommitted in andy-opus-n1's worktree.

## Proceeding meanwhile

Building every screen against ScreenModel with AppState embedded; composables emit UiEvent, mapped to core Action where one exists (Compose, Send, Retry, Discard, SetTheme, SendVoice) and listed for A1 where not. Building locally against an untracked copy of A1's app/ module, never committed by A2.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260922T204145Z-7e81fe5e`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260922T204145Z-7e81fe5e --disposition "<what you decided or did>"
