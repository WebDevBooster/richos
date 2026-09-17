# Escalation: Every app/ui test runs on WebKit 26.5; the product ships on the system WebKit 18.6, and that gap hid a shipped defect

- id: `esc-20260917T173018Z-af94bda3`
- raised: 2026-09-17T17:30:18Z
- from: echo-opus-selfvoice1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-selfvoice1` (branch `cc/echo-opus-selfvoice1`)
- head: `0aa33a3390e42f2af927a8fb1618751a676c223c`
- state: **work-complete**
- for: lead

## The question

Does the UI harness get a way to drive the system WebKit, or does it get a loud caveat in its output plus a rule that no CSS feature newer than the shipped engine may be load-bearing? Either is a decision I should not make alone, because it changes what a green ui/tests run is allowed to mean.

## What was already tried

Measured both: Playwright's bundled webkit reports 26.5 (browser.version()); this Mac's Safari/WKWebView is 18.6, WebKit 20621 (Info.plist). Ray's candidate-.4 defect 2 is exactly this: text-wrap: pretty is honored by 26.5 and not by 18.6, so ticker-wrap.js measured a real rendered frame, honestly, on an engine the product does not have -- green suite, two orphaned lines on his screen. Fixed by moving to text-wrap: balance and by forcing each resolvable value in the test, so it now fails on the frame the other engine would draw. That is one property. Nothing in the harness says which engine it is, so nothing else relying on a recent CSS feature is covered either.

## Proceeding meanwhile

All four jobs in my brief are done and committed on cc/echo-opus-selfvoice1. Separately and more urgently for QA scope: the echo canceller declared itself CONFIDENT while removing nothing on the CEO's own rig, on 2 of 5 runs of the shipped candidate -- which retires the half-duplex rule and cuts the barge-in debounce from 5.008s to 0.400s, measured at 3 self-interruptions per 30s. Fixed and covered by a device-free replay of a recording of his real echo path. Candidates .1 to .4 were judged with that defect in them.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T173018Z-af94bda3`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T173018Z-af94bda3 --disposition "<what you decided or did>"
