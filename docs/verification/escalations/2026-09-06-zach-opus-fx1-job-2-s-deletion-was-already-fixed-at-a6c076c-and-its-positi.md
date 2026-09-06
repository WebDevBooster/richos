# Escalation: Job 2's deletion was already fixed at a6c076c, and its positive twin would re-enable erasure that a6c076c deliberately disabled

- id: `esc-20260906T043034Z-c4cf271b`
- raised: 2026-09-06T04:30:34Z
- from: zach-opus-fx1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-fx1` (branch `zach-opus-fx1`)
- head: `846e08b4e69c197571b97fdc4538c226feed72c6`
- state: **proceeding**
- for: lead

## The question

Should detect-nonnative-worktree.sh regain journal-gated automatic erasure, contradicting engine/docs/workspace-retirement-safety.md landed one commit before my base, or is classify-and-preserve the intended end state?

## What was already tried

Verified both Job 2 premises against the code rather than taking them from the brief. (1) The recursive delete is already gone: 'grep -n "rm -rf" engine/scripts/hooks/detect-nonnative-worktree.sh' at f201e90 returns nothing, exit 1. It was removed by a6c076c 'Preserve staged recovery objects and disable unsafe worktree erasure', which is an ANCESTOR of my base f201e90, and the replaced comment now reads 'a detector never authorizes directory removal'. (2) The stated harm -- a retirement quarantine erased because it is unregistered -- was never reachable by that loop either: the quarantine container is QUARANTINE_DIRNAME='.richos-retired' (workspace-retire.py:90), it is dot-prefixed, the loop globs '"$MAIN_CO/.claude/worktrees"/*/', and 'grep -n shopt|dotglob|GLOBIGNORE' on the detector returns nothing, so bash's default no-dotglob never matched it. (3) engine/docs/workspace-retirement-safety.md, added by that same commit, states as a decision: 'The managed cleanup paths preserve workspaces and refuse automatic erasure', 'Restoring automatic deletion requires an enforced access boundary, not another unchecked override flag', and 'The detector reports unknown directories and leaves their contents intact'. A retirement-journal consultation IS a policy check, not an access boundary, so completion criterion 2's 'positive twin that proves a genuinely ownerless entry is still reaped' cannot be built without reversing that decision in the one file whose comment forbids it.

## Proceeding meanwhile

Job 1 is complete and committed (both suites green, baselines recorded). For Job 2 I am building the half that does not depend on the answer and does not contradict the doctrine: tell (c) consults the retirement journal to CLASSIFY unregistered entries -- journal-explained ones named as explained, everything else preserved and reported as unestablished -- plus an explicit dot-directory and .richos-retired- skip so the quarantine's safety stops resting on bash's default globbing, with both halves tested. No deletion is restored.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260906T043034Z-c4cf271b`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260906T043034Z-c4cf271b --disposition "<what you decided or did>"
