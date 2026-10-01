# Escalation: Android D3 twin: the Honor check cannot tell the fix from late success with this lab; one decision needed

- id: `esc-20261001T160057Z-0c75d056`
- raised: 2026-10-01T16:00:57Z
- from: andy-sonnet-honor1
- worktree: `/Users/alex/ab/richos-wt/andy-sonnet-honor1` (branch `cc/andy-sonnet-honor1`)
- head: `c90fb34f15ffa2baf4e51a1c6a1f689d28f3bb02`
- state: **stopped**
- for: lead

## The question

The Honor can be paired to an isolated lab (managed route) and a send held in flight across Home, but no fault ever reached the app inside the 5 s bound: a frozen lab only makes the request succeed late (read timeout is 30 s), and dropping Wi-Fi under the request left the socket hung, with no second request seen at the tunnel for 11 s in 2 of 2 instrumented tries. Choose: (a) accept unit tests (OutboxTest 23 of 23) as the proof and land 00e11935b, (b) have a lab fault injector built (the Rust phone listener answers the first send of a client id with a dropped connection, so the tunnel returns a fast 502; that is production phone-listener test config, Echo's code) and I repeat the check once, or (c) a different fault you name.

## What was already tried

Build+install of the branch (once), isolated lab behind the managed route (android-parity identity, generation 2, since disabled), 1 freeze-only try and 3 Wi-Fi-drop tries with tunnel request counters and phone socket samples; lab-ledger 5 of 5 exactly once; tools committed in c90fb34f1.

## Proceeding meanwhile

Everything is cleaned up (lab stopped by captured PID, route disabled 410, scratch deleted, Honor at Home, Wi-Fi on, app data cleared to its unpaired start). Nothing further runs until the answer.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261001T160057Z-0c75d056`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261001T160057Z-0c75d056 --disposition "<what you decided or did>"
