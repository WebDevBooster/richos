# Escalation: Nightly candidate .2 cannot complete a single turn under the QA scratch home; resolve_claude_bin PATH fallback is dead code

- id: `esc-20260917T124730Z-1967c1aa`
- raised: 2026-09-17T12:47:30Z
- from: ray-opus-cand4
- worktree: `/Users/alex/ab/richos-wt/ray-opus-cand4` (branch `cc/ray-opus-cand4`)
- head: `5be303565f6d9f55acca56d2e2fb970bf0adcce5`
- state: **stopped**
- for: lead

## The question

Relaunch the candidate with RICHOS_CLAUDE_BIN=/Users/alex/.local/bin/claude so turns work while keeping the scratch home, or accept that no answer-bearing check gets tested at this SHA?

## What was already tried

Walked the first-run setup live on screen; typed turn fails with 'Provider could not start: [Errno 2] No such file or directory'; app auto-retried once, failed identically. Root-caused: engine_profile.rs:191 replaces child PATH with runtime.rs:111 '<engine>/runtime/bin:/usr/bin:/bin:/usr/sbin:/sbin'; under scratch HOME resolve_claude_bin (native.rs:1727) misses $HOME/.local/bin/claude and returns bare 'claude', unresolvable on that PATH. Confirmed no claude binary anywhere on it.

## Proceeding meanwhile

Committing the audit and 17 on-screen screenshots covering D5/D4/D6/D2 and full dark-mode contrast. Walk also halted by his Mac reaching the lock screen; app pid 51815 left alive with state intact.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T124730Z-1967c1aa`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T124730Z-1967c1aa --disposition "<what you decided or did>"
