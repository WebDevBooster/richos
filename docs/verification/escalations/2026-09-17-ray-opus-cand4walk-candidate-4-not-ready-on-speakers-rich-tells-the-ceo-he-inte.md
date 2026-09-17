# Escalation: Candidate .4 NOT READY: on speakers, Rich tells the CEO he interrupted when he said nothing

- id: `esc-20260917T155755Z-0b56aed7`
- raised: 2026-09-17T15:57:55Z
- from: ray-opus-cand4walk
- worktree: `/Users/alex/ab/richos-wt/ray-opus-cand4walk` (branch `cc/ray-opus-cand4walk`)
- head: `5e7a632e65e6dbee2c8f937a0b5eb143b4519f65`
- state: **work-complete**
- for: lead

## The question

Should the talked-over notice be suppressed while the echo canceller is unproven (or gated on headphones), before this nightly is published?

## What was already tried

Walked candidate v1.2.0-nightly.20260917.4 (5e7a632e) live on the running window. Spoken turn at volume 85: Rich answered, and while Rich was speaking and I was provably silent the app posted 'You started talking while I was still speaking... that didn't reach me and I haven't sent anything.' Control: repeated the identical spoken turn with output volume set to 0 the instant my utterance ended — turn completed normally, NO discard logged and NO notice. The trigger is Rich's own voice returning through the desk microphone, so on speakers the notice fires on every spoken answer and its statement is false.

## Proceeding meanwhile

Full audit filed at docs/verification/2026-09-17-nightly-1.2.0-20260917.4-onscreen-audit.md with the other findings; app left running on the QA scratch home.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T155755Z-0b56aed7`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T155755Z-0b56aed7 --disposition "<what you decided or did>"
