# Escalation: The section 7.3 release-gate sentinel can run on a CI runner, but only if a subscription token goes into a repository secret

- id: `esc-20260906T101202Z-c4b77ac2`
- raised: 2026-09-06T10:12:02Z
- from: echo-opus-q14
- worktree: `/Users/alex/ab/richos-wt/echo-opus-q14` (branch `echo-opus-q14`)
- head: `756a5b1a41905e2097a2a3cd5368945256b134e3`
- state: **work-complete**
- for: ceo

## The question

Should the section 7.3 sentinel run in CI with CLAUDE_CODE_OAUTH_TOKEN held as a repository secret, or stay on the release machine as section 7.4 assumed?

## What was already tried

Measured on claude 2.1.263, three cells with identical argv and working directory differing only in the child environment: with no credential the child answers 'Not logged in / Please run /login'; with an invalid CLAUDE_CODE_OAUTH_TOKEN it answers '401 Invalid bearer token', so the variable IS read and a token from 'claude setup-token' is a working path. No live credential was minted, so end-to-end from a real runner is unverified. Two consequences that are not the CEO's call and are already in the record: both auth failures come back as subtype=success with zero token usage, so a sentinel checking the exit path reports green having verified nothing; and the token resolves the model, so a runner's green may prove the flag under a different model than the release ships against.

## Proceeding meanwhile

Record committed on branch echo-opus-q14 at docs/verification/inner-doctrine-opens-2026-09-06/. Q1 does not overturn the recommendation - the doctrine survives auto-compaction - and Q3 is a no, so neither needed a raise.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260906T101202Z-c4b77ac2`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260906T101202Z-c4b77ac2 --disposition "<what you decided or did>"
