# Escalation: RICHOS_APP_SCOPE is the engine hook's gate for EVERY PreToolUse, not just the two continuity tools

- id: `esc-20260918T163856Z-18731357`
- raised: 2026-09-18T16:38:56Z
- from: echo-opus-obligation2
- worktree: `/Users/alex/ab/richos-wt/echo-opus-obligation2` (branch `cc/echo-opus-obligation2`)
- head: `9e99ded34ce21b7296fcffe82b2dbf040d5e2a78`
- state: **work-complete**
- for: lead

## The question

Should the engine hook's action gate and the continuity tools' grant stay two separate scope files, or does the engine want one file with a tool matcher on the hook?

## What was already tried

Re-derived it three ways rather than quoting the escalation that preceded it: engine_profile.rs:235 passes the continuity scope path as RICHOS_APP_SCOPE; engine_profile.rs:117-119 registers the engine hook for nine events with NO matcher key, so its PreToolUse registration covers every tool; app-engine-hook.py:50-53 raises 'This app turn is stopped or is supplying context. New actions are unavailable.' on every PreToolUse while that file's actions_allowed is not true. The escalation this slice was dispatched from (esc-20260918T141601Z-d0505a05) held that flag gated the two continuity tools. Deferring the grant on that file would have made the register itself impossible, which is the opposite of CEO §55. The app now writes a SECOND copy of the scope that only the richos_continuity server reads, and the hook's file keeps exactly the lifecycle it always had. Measured green on runs C and D.

## Proceeding meanwhile

Nothing waits on the answer. The two-file shape is landed, tested and measured on the real provider (docs/verification/first-words-obligation-2026-09-18.md). This is a record of a false premise that two escalations and one brief were built on, so the next person does not rebuild on it.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T163856Z-18731357`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T163856Z-18731357 --disposition "<what you decided or did>"
