# Escalation: Round 8 item 8: RED 0 is not reachable by the engineer — the two remaining reds are reviewer cases that assert the attribution gap or simulate a backgrounded call without the platform's stamp

- id: `esc-20260913T073621Z-4d12a19f`
- raised: 2026-09-13T07:36:21Z
- from: zach-fable-m5
- worktree: `/Users/alex/ab/richos-wt/zach-fable-m5` (branch `cc/zach-fable-m5`)
- head: `fc9cfd42ed9a8da82b2a0dd0b6d07cf83331ab01`
- state: **proceeding**
- for: lead

## The question

Item 8 is built on the platform's own stamped field: a Bash call issued with run_in_background keeps its attribution window open until the agent's next observation, and the end of the run compares once more against the last snapshot. The engine's own suites are green (the fourteen 14 green 0 red; unit 61/61). The runner on the real manifest reads RED 2, and both reds are reviewer cases, not engine holes: (a) certification-sage-window-and-target case ref-after-post HOLDS only while the gap exists, and Sage's own round-8 audit §11 proposed the mechanism that closes it, so his per-case retirement makes it green; (b) certification-frank-recorded-attribution cases outside-stray / outside-side simulate a backgrounded call whose PostToolUse payload carries no run_in_background — with that ONE field in the probe's post() (a one-line diff, measured on a scratch copy that was never committed) both cases HOLD 2/2. The alternative that makes Frank's file green WITHOUT the stamp — attribute any ref that appears between two closed calls — was built and measured too: it flips Frank's own control probe (leaked-window-widens) and the engine's point-8 test, because Rich's bookmark cut between two of the agent's calls is then deleted by a discard; point 3 bought with point 8; rejected. Which does the lead want: ask Sage to retire ref-after-post and Frank to stamp or retire his two cases (my recommendation; nothing in the engine changes), or accept the point-8 loss and ship the any-point attribution?

## What was already tried

both designs built and measured; the chosen one is committed, the rejected one's logs are kept: docs/verification/round8-fixes-2026-09-13-logs/runner-item8.txt and runner-item8-ALTERNATIVE-any-point-attribution-REJECTED.txt; the stamped scratch copy of Frank's probe (one-line diff in the same directory) runs 2/2 HOLDS

## Proceeding meanwhile

items 1, 5, 6, 7 and 8 are committed on cc/zach-fable-m5; proceeding with items 4, 2 and 3 and the full mutant run; the report states the gate as RED 2 with both reds named and the one-field fact

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260913T073621Z-4d12a19f`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260913T073621Z-4d12a19f --disposition "<what you decided or did>"
