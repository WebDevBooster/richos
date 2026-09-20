# Escalation: The typed message is already on the reply's push path; the 1.3-6.1 s is spent BEFORE the ledger, in the desktop send path my brief puts out of scope

- id: `esc-20260920T072310Z-517cda6b`
- raised: 2026-09-20T07:23:10Z
- from: echo-opus-phonelive4
- worktree: `/Users/alex/ab/richos-wt/echo-opus-phonelive4` (branch `cc/echo-opus-phonelive4`)
- head: `7e829943360b480092caf7da09aa482641b1b572`
- state: **proceeding**
- for: lead

## The question

Do you want the keypress-to-ledger leg (Tauri IPC dispatch + the one spine mutex in send_message, main.rs:1187) opened as its own task, and by whom, given ui/main.js and first_reply.rs are echo-opus-onit1's surface?

## What was already tried

Read both push sites: Rich's reply (spine.rs:2715/2738) and the CEO's own message (spine.rs:2336, one statement after the durable write in accept_prompt) go through the SAME LiveObserver -> PhoneHub::publish -> one SSE socket. There is no poll, no batch and no second path in src-tauri/src/phone/* or web/web-app/lib/*. The Mac's window paints his bubble locally at ui/main.js:1814-1821, BEFORE Bridge.invoke('send_message') at :1824 - so Ray's Mac number (43-504 ms) is the webview's own paint and his phone number is the first moment his words are durable. The two legs Ray compared start their clocks in different places.

## Proceeding meanwhile

Committing a headless timing test that measures ledger-to-wire for BOTH legs over real TLS through the shipped listener (phone::listen), the page-side one-path assertion (bothsides.test.js, green), and the rejected-phone persistence fix.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260920T072310Z-517cda6b`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260920T072310Z-517cda6b --disposition "<what you decided or did>"
