# Escalation: main's new home.js temporary-line check is FLAKY under run.js (1 red in 2 identical runs)

- id: `esc-20260917T113423Z-bdc63632`
- raised: 2026-09-17T11:34:23Z
- from: echo-opus-firstrun1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-firstrun1` (branch `cc/echo-opus-firstrun1`)
- head: `2a413b963bd7d1cb5891b039ed7d0e7598cff707`
- state: **work-complete**
- for: lead

## The question

Who owns fixing the intermittent 'THE TEMPORARY LINE: the picture is the same picture before it, under it and after it' check in ui/tests/home.js — homefit1, or whoever lands 7473d203/c7ec7426?

## What was already tried

Ran the full UI suite twice on the same tree (my branch merged with main 71ccad5f, nothing of mine touching home.*). Run A: 39 planned, 39 ran, 1 suite FAILED - home.js, 36 checks, 1 failed, message 'a line was already up before this check drove one'. Run B, identical tree and command: all 39 suites passed, 624 checks, home.js 36 checks 0 failed. Standalone 'node home.js' passed twice, exit 0. home.js was 34 checks / 0 failed in all three of my pre-merge runs and became 36 checks with the merge, so the flaky check arrived with main's 7473d203 'The temporary line carries its own shadow' and c7ec7426 'Tests: the temporary line leaves nothing behind'. The failing assertion is about leftover state from a previous driver, not contrast - every contrast number on that screen passed.

## Proceeding meanwhile

All seven of my defects (D1 D2 D3 D8 D4 D6 D5) plus N4 are committed and green: richos-core 1083 passed / 0 failed, src-tauri 107 passed / 0 failed, UI 39/39 suites 624 checks on run B. I have not touched ui/tests/home.js, ui/home.js or home.css - my brief assigns those to echo-opus-homefit1.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T113423Z-bdc63632`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T113423Z-bdc63632 --disposition "<what you decided or did>"
