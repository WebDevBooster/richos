# Escalation: Google Play: a new personal developer account needs 12 testers for 14 days in a closed test before RichConnect can launch

- id: `esc-20260923T221733Z-052e5498`
- raised: 2026-09-23T22:17:33Z
- from: andy-opus-rel2
- worktree: `/Users/alex/ab/richos-wt/andy-opus-rel2` (branch `cc/andy-opus-rel2`)
- head: `a6bdae7476fe542750065e1f267ffebd73e886ef`
- state: **proceeding**
- for: ceo

## The question

Google Play requires personal developer accounts created after 13 November 2023 to run a closed test with at least 12 testers opted in continuously for at least 14 days, then apply for production access (review usually 7 days or less); source support.google.com/googleplay/android-developer/answer/14151465, read 2026-09-23. The CEO's Play account is a new personal registration (identity verification pending, per richos-hq docs/plans/2026-09-23-mobile-setup-decisions-and-review-access.md), so the earliest public Android launch is about 3 weeks after 12 testers are enrolled, and each tester needs something to pair with (a Mac running RichOS, or the chosen hosted review mock, which is not built). Options: (a) recruit 12 testers and start the closed test as soon as a signed bundle is uploaded; (b) register an organization developer account instead (the rule names personal accounts; an organization account needs business verification such as a D-U-N-S number, unverified here); (c) accept the delay. Which?

## What was already tried

Read Google's testing-requirement page; checked the setup record for the account type (personal, verification pending).

## Proceeding meanwhile

The signed bundle, icon and listing drafts are done so a closed test can start the day the account is verified; the drafts record this rule.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260923T221733Z-052e5498`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260923T221733Z-052e5498 --disposition "<what you decided or did>"
