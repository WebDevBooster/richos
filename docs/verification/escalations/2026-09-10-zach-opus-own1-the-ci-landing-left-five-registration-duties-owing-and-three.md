# Escalation: The CI landing left FIVE registration duties owing, and three test suites are red on main because of it

- id: `esc-20260910T080736Z-3a5c8f97`
- raised: 2026-09-10T08:07:36Z
- from: zach-opus-own1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-own1` (branch `zach-opus-own1`)
- head: `85e2e1b2f63847df588b84248dac12e12fa24e69`
- state: **work-complete**
- for: lead

## The question

Who finishes the registration of guard-ci-red-lands.sh and session-start-ci-surface.sh — the five specific duties are listed below and none of them is in my scope?

## What was already tried

All five reproduced on the MAIN checkout at /Users/alex/ab/richos/engine, not inferred from my branch, and my merged branch produces byte-identical results with no failure of its own added. (1) MODE. Both files are 644 where every sibling is 755; ci-status.sh beside them is correctly 755. A registered hook that cannot execute is wired, counted, and loads nothing. (2) ACKNOWLEDGED_SCRIPTS in scripts/hooks/engine-status.test.sh does not name them: engine-status.test.sh reports 8 passed, 8 FAILED with case 1a reading want 62/62 guards, operator 60/62. (3) BR_EXPECTED in scripts/hooks/contract-integrity-probe.sh does not name them, and BR2 says so in its own words: plugin hook table registers script(s) the managed set above does not name: guard-ci-red-lands.sh session-start-ci-surface.sh. The host WILL load them and nothing in this probe knows they exist. by-reference.test.sh is 45 passed, 4 FAILED on main and 45 passed, 4 FAILED on my branch — the same four. (4) .claude/settings.local.json carries neither; a grep finds zero. (5) guard-ci-red-lands.sh is not wired to scripts/lib/unevaluated-notice.sh and carries no UNEVALUATED-PAYLOAD-EXEMPT declaration, so unevaluated-payload.test.sh case 4b names it: SILENT AND UNDECLARED — it exits 0 on an empty, truncated and non-JSON payload with nothing on either stream. Both files are outside my scope and neither has been touched. This supersedes esc-20260910T074153Z-44a674ff, which named only duties 1 and 2.

## Proceeding meanwhile

My own branch is complete: owned-state.test.sh 27/27, and the standing-ownership gate was added to all nine inventories the same derivation names, which is why its own arrival cost zero new failures anywhere.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260910T080736Z-3a5c8f97`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260910T080736Z-3a5c8f97 --disposition "<what you decided or did>"
