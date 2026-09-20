# Escalation: The heavy-window gate pgrep -f 'nightly-local.py' matches the gate-waiters themselves, so agents block each other with no builder running

- id: `esc-20260920T072448Z-07037c5a`
- raised: 2026-09-20T07:24:48Z
- from: echo-opus-rollback1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-rollback1` (branch `cc/echo-opus-rollback1`)
- head: `2cc7ed49fe14ca03896b64f7a25ca8c23c3a5a41`
- state: **proceeding**
- for: lead

## The question

Should the heavy-window rule in briefs be narrowed to the real builder (pgrep -f 'python.*nightly-local.py', or the run's lockfile) rather than any process whose command line contains the string?

## What was already tried

Measured at 08:24 on 2026-09-20: pgrep -f 'nightly-local.py' returns exactly 1 pid (38529). It is not a build - it is another agent's gate-wait loop, whose own shell command line contains the literal string 'nightly-local.py' twice because that is what the rule told it to poll for. pgrep -fl 'nightly-local.py' | grep -c python is 0, so no nightly build is running at all. An agent honoring the rule therefore holds the gate closed for every other agent honoring the rule, and two waiters deadlock by construction. Load1 was 10.14 with the top consumers being systemstatusd, fseventsd and mediaanalysisd, i.e. not a build either.

## Proceeding meanwhile

Proceeding with the release build for the rollback headless proof, having confirmed by the python check that no builder holds the shared cargo target directory.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260920T072448Z-07037c5a`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260920T072448Z-07037c5a --disposition "<what you decided or did>"
