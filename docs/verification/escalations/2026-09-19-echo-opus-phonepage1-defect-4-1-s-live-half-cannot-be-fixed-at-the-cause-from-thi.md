# Escalation: Defect 4.1's live half cannot be fixed at the cause from this branch: no LiveEvent carries a CEO turn, and the Mac's 'Add to Home Screen' string is in a file another teammate holds

- id: `esc-20260919T003541Z-6885f74b`
- raised: 2026-09-19T00:35:41Z
- from: echo-opus-phonepage1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-phonepage1` (branch `cc/echo-opus-phonepage1`)
- head: `ddf43e8bc298dc812aeeeadb616a1a35e51459e9`
- state: **work-complete**
- for: lead

## The question

Who lands (a) a CEO-turn variant on richos_core::live::LiveEvent plus its arm in phone/rows.rs event_from_live, and (b) the Mac-side install wording at app/ui/phone.js:580, which echo-opus-phoneflow1 holds?

## What was already tried

Built the honest fallback instead: the page merges the hello frame's rows (the actual cause of 4.1), holds a confirmed row from the Mac's send answer, and after a reply that settles with no question in front of it asks the Mac for the five rows before it on the existing signed backfill route. Re-seeded the hub cursor from the projection on that route so the live and projected orderings stop drifting. Verified the emitter CANNOT read the projection mid-turn: PhoneBridge::snapshot try_locks the spine and serves a pre-turn cache while a turn holds it (phone/bridge.rs:141-162).

## Proceeding meanwhile

All six brief items are done and committed on cc/echo-opus-phonepage1; npm test 163 pass, cargo test --bin richos-tauri 312 pass, richos-core green, desktop-verify ALL CHECKS PASSED in Chromium.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260919T003541Z-6885f74b`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260919T003541Z-6885f74b --disposition "<what you decided or did>"
