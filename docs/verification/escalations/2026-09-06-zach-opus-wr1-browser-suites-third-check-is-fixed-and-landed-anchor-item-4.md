# Escalation: browser-suites' third check is fixed and landed; anchor item 4's second half is stale

- id: `esc-20260906T165136Z-bfa74758`
- raised: 2026-09-06T16:51:36Z
- from: zach-opus-wr1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-wr1` (branch `zach-opus-wr1`)
- head: `03dba881b5c50c15b5c559ba7b9d9acc07b8f9c7`
- state: **work-complete**
- for: lead

## The question

Can anchor line 116's second clause be struck, given the full browser-suites job is green on main at ab6423b (29 suites, 562 checks, none skipped, exit 0) and splash.js check 5 passes under the slow-runner simulation too?

## What was already tried

Ran the real job rather than reading the record. splash.js check 5 -- the third red named by esc echo-opus-ci2 2026-09-05 -- is PASS, and its detail line shows echo's own proposed fix landed: shot taken 4146ms into a curtain whose ceiling was armed for 4000ms, 'disarmed for this photograph alone'. Commit 14bb88b is on main and origin/main. Green again under RICHOS_SPLASH_LAG_MS=2000 (28 checks, exit 0), which is the knob that exists because this check was a 33-50ms margin. Also re-measured tom-opus-bs1's fourth red (esc-20260906T071535Z-5e572b94, home.js CONTRAST, 2 failures in 7): 7 standalone runs, 7 green, 34 checks each -- fixed by 53532f3, not merely quiet. Full npm test: 29 discovered, 29 ran, 0 skipped, 562 checks observed against 456 declared, exit 0.

## Proceeding meanwhile

Case 15c, the first half of the same anchor line, WAS genuinely red and is diagnosed and fixed in three commits on zach-opus-wr1. It also closes esc-20260906T012218Z-c6526676, which stopped at 'the analyzer's search path is the next step'.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260906T165136Z-bfa74758`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260906T165136Z-bfa74758 --disposition "<what you decided or did>"
