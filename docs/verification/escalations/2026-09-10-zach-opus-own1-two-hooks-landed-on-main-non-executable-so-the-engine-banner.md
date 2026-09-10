# Escalation: Two hooks landed on main non-executable, so the engine banner now says 60/62 and two registered guards load nothing

- id: `esc-20260910T074153Z-44a674ff`
- raised: 2026-09-10T07:41:53Z
- from: zach-opus-own1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-own1` (branch `zach-opus-own1`)
- head: `84238aec4c92acaedee0bd22dec2ffd4d902aeed`
- state: **work-complete**
- for: lead

## The question

Who runs chmod +x on engine/scripts/hooks/guard-ci-red-lands.sh and engine/scripts/hooks/session-start-ci-surface.sh, and adds both to ACKNOWLEDGED_SCRIPTS in engine/scripts/hooks/engine-status.test.sh with the one line that case demands?

## What was already tried

Reproduced on the MAIN checkout, not on my branch: engine-status.test.sh at /Users/alex/ab/richos/engine reports 8 passed, 8 FAILED, with case 1a reading want 62/62 guards, operator 60/62. The two missing from the numerator are the two that landed at 19037049 with mode 644 rather than 755 — ls -l shows -rw-r--r-- for both guard-ci-red-lands.sh and session-start-ci-surface.sh while every sibling in that directory is -rwxr-xr-x, and scripts/ci-status.sh beside them is correctly 755. A registered hook that is not executable is a SHORTFALL by that banner's own definition: it is wired, so it is counted in the denominator, and it loads nothing. Case 1b separately reports both as NEWLY REGISTERED and unacknowledged, which is the same tripwire that fired for my own guard this morning and which its own text says never to silence. Both files are zach-opus-ciw3's and outside my scope, so I have changed neither. Not diagnosed further: whether the seated .claude/settings.local.json also needs them is theirs to decide — grep finds neither there today, while hooks/hooks.json carries both.

## Proceeding meanwhile

My own work is complete on zach-opus-own1: owned-state.test.sh 27/27, and after adding my guard to all nine inventories engine-status.test.sh was 16/16 immediately before this merge.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260910T074153Z-44a674ff`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260910T074153Z-44a674ff --disposition "<what you decided or did>"
