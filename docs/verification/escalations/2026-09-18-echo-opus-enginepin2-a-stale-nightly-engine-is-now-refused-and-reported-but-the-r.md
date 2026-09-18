# Escalation: A stale nightly engine is now refused and reported, but the refresh still needs one press — and bundling the 113.93 MiB asset is the CEO's call

- id: `esc-20260918T112724Z-fb1292f0`
- raised: 2026-09-18T11:27:24Z
- from: echo-opus-enginepin2
- worktree: `/Users/alex/ab/richos-wt/echo-opus-enginepin2` (branch `cc/echo-opus-enginepin2`)
- head: `988c6d12d2f46a223e63da965b88008608f50c0e`
- state: **work-complete**
- for: ceo

## The question

When a nightly's engine is stale, should the app refresh it automatically in the background, or is the existing setup sheet (one press, with progress) the right behavior?

## What was already tried

Identity gate landed and measured: the real stale engine (b7a882ef, from nightly.20260917.2) is now refused against candidate .8's own pin (ea7f7904, nightly.20260918.2); both digests were already on the machine and nothing compared them. Also closed Ray's second finding: a pinned build no longer silently boots the developer's ~/.claude/richos-engine.

## Proceeding meanwhile

All four commits are on cc/echo-opus-enginepin2 and the record is at docs/verification/2026-09-18-engine-pinned-by-identity.md; nothing depends on this answer.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T112724Z-fb1292f0`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T112724Z-fb1292f0 --disposition "<what you decided or did>"
