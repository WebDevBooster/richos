# Escalation: ci-red-acks.log has no way to record a correction, and it now holds a false reason that no code can ever read as false

- id: `esc-20260914T195811Z-b8f08c1a`
- raised: 2026-09-14T19:58:12Z
- from: zach-opus-runrec1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-runrec1` (branch `cc/zach-opus-runrec1`)
- head: `3abda7c1b396ac2771cf74f22c32f9504e845482`
- state: **work-complete**
- for: lead

## The question

Should the ack ledger gain an entry id + a retraction verb, or is an append-only ledger of unverifiable reasons acceptable? It is a schema change to a cross-repository state file, so it is not mine to take unilaterally.

## What was already tried

Read every writer and reader. WRITER: guard-ci-red-lands.sh only, appending TSV 'ts \t repo-slug \t workflow \t verb \t why' with no entry id (scripts/hooks/guard-ci-red-lands.sh, log_path opened 'a'). READERS: the same file, which counts rows per workflow to report how often a hatch has been used; and notice-waiver-repetition.py, which clusters reason TEXTS across ledgers for similarity. Neither ever evaluates a reason for truth. grep -niE 'retract|supersed|correct|amend|revoke' across guard-ci-red-lands.sh, notice-waiver-repetition.py and lib/ci-red.py returns nothing relevant. So: NO, there is no correction mechanism. Worse, the ledger penalizes correcting it — appending a corrective row would be counted as an ADDITIONAL waiver of engine-run-record.yml, making the habit signal falser in the other direction. The entry in question is 2026-09-14T17:18:48Z, whose stated reason is that one push to main has no CI run at all; that push (0fb68b7c) has run #101, event=push, conclusion=success.

## Proceeding meanwhile

Everything else in the task is done and committed on cc/zach-opus-runrec1. I did not edit or append to the ledger: rewriting an audit ledger is wrong, and appending would corrupt the only signal it does carry.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260914T195811Z-b8f08c1a`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260914T195811Z-b8f08c1a --disposition "<what you decided or did>"
