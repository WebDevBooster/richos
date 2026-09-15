# Escalation: Step 3 premise names the wrong cost: bash startup is 4 percent of the apparatus, python3 and git are 96

- id: `esc-20260915T100425Z-ced5afdf`
- raised: 2026-09-15T10:04:25Z
- from: zach-opus-runner3
- worktree: `/Users/alex/ab/richos-wt/zach-opus-runner3` (branch `cc/zach-opus-runner3`)
- head: `b2f1eaa811dd92b280e846d914db7dd0110c9dc1`
- state: **proceeding**
- for: lead

## The question

Step 3 done-when is 'one bash process per shell call'. Met literally and nothing else, it buys about 4 percent. Is the acceptance criterion the process count, or the per-call cost? I built for the cost and the count falls anyway.

## What was already tried

Counting shims ahead of python3 and git on PATH, replaying one real Bash payload through the registered chain, 20 iterations per primitive: bash -c 'exit 0' = 2.12 ms, python3 -c 'pass' = 14.64 ms, git rev-parse --show-toplevel = 4.23 ms. One shell call spawned 14 bash + 37 python3 + 36 git = 30 ms + 542 ms + 152 ms of subprocess work. Bash is 4.1 percent of it. Two of every three python3 forks and four of four git forks were resolve_entity_root and richos_payload_unreadable, asked twelve times about one identical payload. Separately: the brief 71 distinct registered scripts is the check-census.py figure; a direct parse of hooks.json gives 70, the difference being the one inline SessionStart hook that runs no script.

## Proceeding meanwhile

Built the dispatcher so ONE process answers those two chassis questions once and hands the answers to every rule. Same call now costs 1 bash + 13 python3 + 4 git. Distinct registered scripts 70 to 54; registration entries 76 to 61; files in scripts/hooks unchanged.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260915T100425Z-ced5afdf`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260915T100425Z-ced5afdf --disposition "<what you decided or did>"
