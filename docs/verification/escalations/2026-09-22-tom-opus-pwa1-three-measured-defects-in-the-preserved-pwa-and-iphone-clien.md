# Escalation: Three measured defects in the preserved PWA and iPhone client, fixes held unmerged under CEO §76

- id: `esc-20260922T224344Z-17c81eb3`
- raised: 2026-09-22T22:43:44Z
- from: tom-opus-pwa1
- worktree: `/Users/alex/ab/richos-wt/tom-opus-pwa1` (branch `cc/tom-opus-pwa1`)
- head: `3b917a4b5e749c7dc878c43fe45f3b1bac7ba7a4`
- state: **work-complete**
- for: lead

## The question

Should the preserved PWA and iPhone client get the three held fixes (follow-yank, challenge-read-twice, sent-message-blink) on branch cc/tom-opus-pwa1-held-product-fixes at 0f1f1f8a, or stay as they are with the named known-defect expectations on cc/tom-opus-pwa1?

## What was already tried

Fixed all three in the product with regression tests, then moved them to a held branch after the §76 scope note; cc/tom-opus-pwa1 is test-only and names each defect in a strict expectation that fails the day the defect is fixed.

## Proceeding meanwhile

The handoff branch makes mobile-pwa deterministic on the test side; the defects stay reported every run.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260922T224344Z-17c81eb3`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260922T224344Z-17c81eb3 --disposition "<what you decided or did>"
