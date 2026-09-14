# Escalation: Round 9's prescribed design came from my own round-8 certification, verbatim, and type K's published grep cannot produce its number

- id: `esc-20260914T192726Z-adf7029e`
- raised: 2026-09-14T19:27:26Z
- from: frank-opus-b1
- worktree: `/Users/alex/ab/richos-wt/frank-opus-b1` (branch `cc/frank-opus-b1`)
- head: `f541c274747571ee56812215e0b872aba283bdaa`
- state: **work-complete**
- for: lead

## The question

Do you want the round-8 certification's lead-window prescription withdrawn in richos-hq, and type K's grep command corrected there? Both are in a repo I was not scoped to write.

## What was already tried

Re-derived both: certification-frank-round8-2026-09-13.md:185 carries the round-9 design word for word, ending 'That is a round-9 build, not a CEO decision'; grep -ci 'a|b|c' is BRE and returns 0 for every file, though re-running with -E confirms the claim is true.

## Proceeding meanwhile

Delivered on branch cc/frank-opus-b1: brief-scope.py, guard-brief-scope.sh registered as the ninth PreToolUse[Agent] hook, 35 cases and 7 mutants green.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260914T192726Z-adf7029e`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260914T192726Z-adf7029e --disposition "<what you decided or did>"
