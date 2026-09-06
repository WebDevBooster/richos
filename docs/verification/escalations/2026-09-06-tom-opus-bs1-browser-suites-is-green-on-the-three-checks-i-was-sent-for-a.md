# Escalation: browser-suites is green on the three checks I was sent for, and home.js is a fourth red that arrived with main at 3a661a4

- id: `esc-20260906T071535Z-5e572b94`
- raised: 2026-09-06T07:15:35Z
- from: tom-opus-bs1
- worktree: `/Users/alex/ab/richos-wt/tom-opus-bs1` (branch `tom-opus-bs1`)
- head: `8da908b765a42ecdedb5d181119a070db9d1c340`
- state: **work-complete**
- for: lead

## The question

home.js's CONTRAST BOTH THEMES check fails 2 runs in 7 on main's own code and tests/home.js is technically mine while every file it measures is echo-opus-hm1's and echo is live in them right now — do I take it, or does echo?

## What was already tried

Merged main (3a661a4) into tom-opus-bs1. Ran node home.js seven times standalone on the merged tree: exit 1 on runs 1 and 3, exit 0 on 2 and 4-7. Both failures are the same check, 'CONTRAST, BOTH THEMES: the three new things, with the CEO's own choice set to light', and both report the identical delta: expected '"Enter" under the door 8.34:1', actual '8.6:1', under the message 'the clamp is leaking'. Every other reading in the list is byte-identical across the two theme walks, and 8.34 and 8.6 both clear the 4.5:1 floor by a wide margin — so the clamp is not leaking, the check is asserting that two measurements taken over a MOVING picture agree to the second decimal. The comment two checks above says the method samples the pixel that minimizes contrast with the ink, and the pixel behind that ink is the loro nebula, which is animated. A full run.js sweep on the merged tree failed home.js on a DIFFERENT check instead - 'WITH A CORPUS ABOVE THE THRESHOLD', page.waitForFunction timeout 30000ms - which is the load-dependent race echo landed a fix for at 48df852 and which is therefore not closed. My own four files are provably not involved: my only edit to lib/harness.js that home.js can see is four comment lines.

## Proceeding meanwhile

The three checks that actually owned browser-suites are fixed and committed on tom-opus-bs1 (7a40d59, 5f5a2e6, 4799dba). Whole suite on the merged tree is green apart from home.js, and green including a four-knob slow-runner stress run on my pre-merge tree: 25 suites, 523 checks, exit 0.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260906T071535Z-5e572b94`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260906T071535Z-5e572b94 --disposition "<what you decided or did>"
