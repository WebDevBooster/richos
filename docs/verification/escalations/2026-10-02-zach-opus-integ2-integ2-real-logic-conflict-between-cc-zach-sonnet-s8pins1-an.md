# Escalation: integ2: real logic conflict between cc/zach-sonnet-s8pins1 and cc/zach-sonnet-hunte2 in ci-shard.sh kr_expired (local vs UTC 'today') and both S8b test blocks

- id: `esc-20261002T045334Z-94586c8a`
- raised: 2026-10-02T04:53:34Z
- from: zach-opus-integ2
- worktree: `/Users/alex/ab/richos-wt/zach-opus-integ2` (branch `cc/zach-opus-integ2`)
- head: `62494622fd08014ce87d55b7a0fde9922ad6541c`
- state: **proceeding**
- for: lead

## The question

For richos/engine/scripts/ci-shard.sh kr_expired(): may I take hunte2's validating python body (P5-77, rejects malformed expiries) but compare against the LOCAL date (datetime.date.today(), s8pins1's rule, which is exactly what the auto-merged ci-receipts.py already does: expiry_live(table[u], today) with today = local), and in ci-shard.test.sh keep BOTH S8b blocks (s8pins1's two-timezone local-calendar cases and hunte2's malformed-expiry cases, renaming hunte2's to S8c)? Or which side wins?

## What was already tried

Lines in conflict: ci-shard.sh ~393-430: s8pins1 (8ec098436/273822e7e) makes kr_expired compare `date +%Y-%m-%d` (local) instead of `date -u`; hunte2 (2ee764ee1) replaces the same function with a python validator comparing against datetime.datetime.now(timezone.utc).date(). ci-shard.test.sh ~247-290: both add a block named S8b (s8pins1: Pacific/Kiritimati and Etc/GMT+12 local yesterday/today; hunte2: tomorrow, 2999-99-99, 2026-02-30, 20991231). ci-receipts.py auto-merged to local date plus validation, so taking hunte2 as-is would leave ci-shard.sh on UTC and ci-receipts.py on local again (the S8 bug s8pins1 fixed). Per the brief I did not decide it: the hunte2 merge is aborted, not committed.

## Proceeding meanwhile

Merging branches 8-21 onto the integration branch without hunte2; hunte2 is merged last once answered (its registered-hooks-enforced.test.sh cases 5-8 plus main's 10 will be kept as the brief says).

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261002T045334Z-94586c8a`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261002T045334Z-94586c8a --disposition "<what you decided or did>"
