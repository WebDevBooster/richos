# Escalation: The work chip's leading read fixes a measured 3-second hole but re-calibrates contrast.js's whole floor table — 37 floors and two cannotBite calls that are not mine to make silently

- id: `esc-20260920T075635Z-0f2cba02`
- raised: 2026-09-20T07:56:35Z
- from: echo-opus-onit1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-onit1` (branch `cc/echo-opus-onit1`)
- head: `14880dcba0d2279766323dbe9b180352e3d61757`
- state: **work-complete**
- for: lead

## The question

Who re-derives ui/tests/contrast-debt.json's 37 surface floors and decides whether history-notice and first-run-unusable move into floorReference.cannotBite? That is the only thing standing between the leading read and landing.

## What was already tried

Built it, measured it both ways on one host and one tree, then split it. (1) THE HALF THAT LANDED: openThread cleared savedWork and drillItems but NOT workerCounts or assignments, and renderDrillChip reads all four - so after a switch the chip printed the PREVIOUS conversation's counts until the next 3 s tick. Fixed, committed. (2) THE HALF THAT DID NOT: an awaited pollWorkerStatus() at the point a thread becomes the open conversation. It works and the numbers are real - techy.js 97 s -> 65 s and updates.js 69 s -> 48 s, with the baselines reproducing EXACTLY at two very different host loads (97 s at load 21 and at load 11; 69 s at both), so the deltas are the change and not the host. Zero committed screenshots changed. (3) WHY IT DID NOT LAND: the chip now reaches the screen before ui/tests/contrast.js walks it, which moves 2 text nodes onto 32 of 43 surfaces, +0/+2 on 4 more, +4/+2 on technical-view, 0 on 6. The bare-shell reference goes 92 of 562 -> 94 of 564, and check 9z then reports seven surfaces whose floors the bare shell would clear: phone-rejected, permission, memory-setup, memory-no-compiler, updates-waiting, history-notice, first-run-unusable. Proven it is mine: contrast.js exits 0 without the leading read and 1 with it, same tree, back to back. contrast-debt.json's own note documents the repair procedure for a UNIFORM delta; mine is not uniform, so 37 floors want re-deriving, and history-notice (96 of 566) and first-run-unusable (96 of 566) sit within the 3-node tolerance of the new shell even after re-derivation - they would need cannotBite declarations, which is weakening someone else's negative control on my judgment at the end of a task. The diff is saved at /private/tmp/claude-501/-Users-alex-ab-femcboost/f5aeaea1-80fa-4210-b51f-720f89942a80/scratchpad/halfB.txt and the two full contrast logs are beside it.

## Proceeding meanwhile

The leak half is committed and green. Nothing else in my task depends on this.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260920T075635Z-0f2cba02`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260920T075635Z-0f2cba02 --disposition "<what you decided or did>"
