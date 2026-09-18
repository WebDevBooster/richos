# Escalation: The phone app and the Mac must agree on two things Echo's contract has not said yet

- id: `esc-20260918T131212Z-f4a64e30`
- raised: 2026-09-18T13:12:13Z
- from: norm-opus-pwa1
- worktree: `/Users/alex/ab/richos-wt/norm-opus-pwa1` (branch `cc/norm-opus-pwa1`)
- head: `06b0bfbbf488345b3a13e6d12e293da27ebb4d75`
- state: **work-complete**
- for: lead

## The question

When phone-channel.md lands, does the Mac adopt the phone's six-word fingerprint derivation and its per-request signed-challenge header, or does the phone reconcile to Echo's?

## What was already tried

docs/architecture/phone-channel.md did not exist on main at e39bc835 or at f730645f, so the phone was built against CONTRACT-STUB.md written from plan sections 2.5, 2.6, 2.7, 4.2(vi) and 10.7, with every invented decision marked CHOSEN HERE in that file. All routes sit behind lib/api.js so reconciling is one module plus its test.

## Proceeding meanwhile

The app is complete and green: 77 unit checks, 108 browser checks across Chromium and WebKit, and the probe's own suite. Two couplings cannot be reconciled by the phone alone, because they are agreements: (1) the six words shown at pairing must come from the SAME 256-word list and the same first-six-bytes derivation on both screens, or the comparison he is asked to make means nothing - the list is richos/app/phone/lib/wordlist.js and the derivation is one array index; (2) the phone signs challenge, method, path and body hash on EVERY request because a session-token exchange would need a fifth route and section 2.5 says four. Either is cheap to change on the phone side and impossible to notice if the two sides just differ.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T131212Z-f4a64e30`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T131212Z-f4a64e30 --disposition "<what you decided or did>"
