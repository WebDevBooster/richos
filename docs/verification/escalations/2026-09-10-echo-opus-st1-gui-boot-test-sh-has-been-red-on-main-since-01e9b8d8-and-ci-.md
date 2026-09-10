# Escalation: gui-boot.test.sh has been RED on main since 01e9b8d8 and CI cannot see it

- id: `esc-20260910T090509Z-9f06eb32`
- raised: 2026-09-10T09:05:09Z
- from: echo-opus-st1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-st1` (branch `echo-opus-st1`)
- head: `895269795aac8238be4467b3309c97fd135576e9`
- state: **work-complete**
- for: lead

## The question

Who repairs the gui-boot harness bundle, given the fix turns on real update-lease code inside the harness?

## What was already tried

Ran it on my branch and on a git archive of pre-change 791cc73d: 3 FAILED 18 passed both times, byte-identical apart from mktemp names. Cause: gui-launch.sh:194-195 writes no Info.plist; prepare requires one at update_startup.rs:65 since 01e9b8d8, so every boot dies at main.rs:898 and B1/B2 - the half proving a healthy boot completes - are dead. packaging-ci.yml:166-167 declares that suite a host gap, so CI has never answered. Evidence: docs/verification/startup-alert-2026-09-10/ section 6.

## Proceeding meanwhile

My task is complete and committed on echo-opus-st1. Left the fixture as found rather than patch another agent's change.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260910T090509Z-9f06eb32`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260910T090509Z-9f06eb32 --disposition "<what you decided or did>"
