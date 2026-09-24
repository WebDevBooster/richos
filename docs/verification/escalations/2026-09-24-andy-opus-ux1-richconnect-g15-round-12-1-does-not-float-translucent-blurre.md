# Escalation: RichConnect G15: round 12.1 does not float translucent blurred cards; Android already matches its source

- id: `esc-20260924T011921Z-8d5b6b5a`
- raised: 2026-09-24T01:19:21Z
- from: andy-opus-ux1
- worktree: `/Users/alex/ab/richos-wt/andy-opus-ux1` (branch `cc/andy-opus-ux1`)
- head: `7d8ba5e9299fd9cc3ce1cf667b02a2a5c7e0d850`
- state: **proceeding**
- for: lead

## The question

Close G15 as NOT APPLICABLE (Android already does what round 12.1's source and NOTES specify), or should Android copy the rendered mockup's overlap, where the card covers the newest messages?

## What was already tried

Read round-12.1 shared/app.css and app.js. The .card rule is opaque: background var(--surface), no backdrop-filter and no alpha (the only blur in the round is the lock-screen notification, .lnotif). The thread's bottom padding is --cb, which a ResizeObserver sets to the whole composer zone's height, cards included (app.js:175, app.css:171). That is what Android does: Thread bottomPadding = the measured zone + 20 dp. The overlap in the rendered mockup happens because the mockup sets --cb after it has already scrolled to the bottom and never scrolls again. The NOTES rule is that the conversation follows the newest message, and Android follows that rule (Thread.kt re-scrolls when bottomPadding changes). Urban's own row says parity holds and legibility is arguably better.

## Proceeding meanwhile

G15 left unchanged. Every other gap (G2 G3 G4 G5 G6 G7 G8 G12 G13 G14 G16) proceeds.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260924T011921Z-8d5b6b5a`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260924T011921Z-8d5b6b5a --disposition "<what you decided or did>"
