# Escalation: The window fix is landed but unverified on a real screen: opening one on the CEO's three displays needs his say-so

- id: `esc-20260910T115841Z-d17139d1`
- raised: 2026-09-10T11:58:41Z
- from: echo-opus-win1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-win1` (branch `echo-opus-win1`)
- head: `a6a580d550347bd54011e2c19e727ce63c4b91cc`
- state: **work-complete**
- for: lead

## The question

When may RichOS be launched on his desk so the window can be seen opening on all three displays, including the portrait HP E243?

## What was already tried

Read the real panels with system_profiler (no GUI), derived the placement through the shipped decision function, swept every menu-bar/Dock model from (0,0) to (38,160) on all three panels, 18 unit tests, and a dry-run harness that prints the chosen geometry per display. cargo test green in app/src-tauri (97) and richos-core (537 + 40 suites).

## Proceeding meanwhile

Branch echo-opus-win1 is committed and complete at a6a580d5; nothing else in the task depends on the answer.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260910T115841Z-d17139d1`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260910T115841Z-d17139d1 --disposition "<what you decided or did>"
