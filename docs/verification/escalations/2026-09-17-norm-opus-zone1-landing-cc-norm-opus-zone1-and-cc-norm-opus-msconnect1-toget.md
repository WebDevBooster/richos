# Escalation: Landing cc/norm-opus-zone1 and cc/norm-opus-msconnect1 together silently turns promotion OFF unless one line moves

- id: `esc-20260917T023227Z-609efae2`
- raised: 2026-09-17T02:32:27Z
- from: norm-opus-zone1
- worktree: `/Users/alex/ab/richos-wt/norm-opus-zone1` (branch `cc/norm-opus-zone1`)
- head: `771cc15bc7eeda46c5067dee3b9a92b9545677f0`
- state: **work-complete**
- for: lead

## The question

At land time, change ZONE_SHAPES in promote-run.js (on cc/norm-opus-msconnect1) from the segments ceo,unfiled,evidence,workspace to ceo,evidence,unfiled,workspace — may I treat that as yours to apply during the merge, or do you want a follow-up commit from me on a fresh branch?

## What was already tried

Checked both branches directly rather than assuming. On cc/norm-opus-msconnect1, promote-run.js line 55 hardcodes the segments ceo,unfiled,evidence,workspace. My branch moved evidenceRoot's unfiled branch to ceo/evidence/unfiled in config.js. The two files never touch, so the merge will NOT report a conflict and BOTH suites pass in isolation. In the merged tree corpusFromZone matches neither shape, returns null, and by its own docblock promotion does not run - reported by name, but a sync that used to write memory stops writing it for the DEFAULT case with no RICHOS_ACTIVE_COMPANY set. I cannot fix it here: promote-run.js does not exist on my branch.

## Proceeding meanwhile

My five commits are complete and green (483bc9e5, 4dc147c4, bd9884d1, 2945303c, 771cc15b); nothing else in my footprint depends on the answer.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T023227Z-609efae2`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T023227Z-609efae2 --disposition "<what you decided or did>"
