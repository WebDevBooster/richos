# Escalation: iPhone walk D4 (Reconnecting with a healthy Mac) is caused on the Mac, not in native-ios: the phone listener's 4-stream cap is held by streams of killed phone processes

- id: `esc-20261001T080724Z-16649ad1`
- raised: 2026-10-01T08:07:24Z
- from: isaac-opus-conn2
- worktree: `/Users/alex/ab/richos-wt/isaac-opus-conn2` (branch `cc/isaac-opus-conn2`)
- head: `ebe60e64ef9f51a135c44d74f628ec2ff14b762e`
- state: **proceeding**
- for: lead

## The question

D4 needs a Mac-side change in app/src-tauri/src/phone (outside my iOS brief). Who takes it? Proposed fix: when the paired device opens a new event stream, end that same device's older streams and release their slots before claim_stream counts (one live stream per device; newest wins), with a Rust test that holds 4 stream bodies open for one device and proves a 5th open from that device is answered 200, not 429.

## What was already tried

Re-derived from code. app/src-tauri/src/phone/device.rs:160 MAX_STREAMS = 4, global, and claim_stream (device.rs:1456-1463) refuses the 5th. listen.rs:777-781 answers that refusal 429 with Retry-After 60 (listen.rs:738-740). The slot is released only when hyper drops the response body (listen.rs:755-768, StreamSlot Drop), i.e. only when the Connect route (Cloudflare edge, then cloudflared) tears the request down. A phone process killed by XCUITest terminate sends no close over HTTP/3, so its stream lingers while the Mac keeps writing keep-alives every 15 s (mod.rs:123, listen.rs:804-826). Walk step list 06 (richos-hq docs/verification/2026-10-01-iphone-walk/steps/06-light-gestures-fit.json) launches 4 processes in about two minutes (steps 2, 23, 53, 65) after list 05 left one running: at the step-65 launch, the third quick relaunch, the four earlier processes hold all 4 slots, which is exactly when D4 appeared. The phone then retries on its back-off (1, 2, 4, 8, 16, 30 s; LiveConnection.swift:144-181) and keeps getting 429, so Reconnecting stays; the next launch, after the orphans aged out, connected within 5 s. I checked and ruled out a phone-side stream leak: an AsyncThrowingStream dropped before or during iteration runs its onTermination, so a stop() racing the open does not orphan the URLSession task (measured with a standalone Swift probe).

## Proceeding meanwhile

Fixing D3 and D5 in native-ios (Core and App), one commit each, with deterministic tests. No D4 change on the phone: nothing the phone does can release a slot held by a process that no longer exists.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261001T080724Z-16649ad1`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261001T080724Z-16649ad1 --disposition "<what you decided or did>"
