# Escalation: Merge gate replay: more checks now reach a verdict, and some of those verdicts are failures the old gate never ran far enough to show

- id: `esc-20261001T002153Z-46ac290e`
- raised: 2026-10-01T00:21:53Z
- from: zach-opus-gate2
- worktree: `/Users/alex/ab/richos-wt/zach-opus-gate2` (branch `cc/zach-opus-gate2`)
- head: `d50a5186082c98ae52bc66c91718b37d3e21059c`
- state: **proceeding**
- for: lead

## The question

Before landing cc/zach-opus-gate2, decide how to treat three classes of failure the replay of the merge of 4e73fd89 exposed; under the new gate each one refuses a land that selects it. (1) Red on main itself, failing alone on main f6827880 and on the branch alike: engine scripts/lib/mutation-harness.test.sh (cases 2a, 3b), scripts/hooks/waiver-repetition.test.sh (21b), scripts/lib/global-state-witness.test.sh (d2: install-settings-parse-error.test.sh is not on its list). They need owners. (2) Failures from the gate environment: contract-integrity sections N, worktree, config, P, shim, M, MC and MT fail their intact-probe case (expected exit 0, got 2) when run through proof-run.py, even alone as its only check, and pass through ci-shard.sh directly, including with a private HOME and TMPDIR. What remains different is proof-run's private execution profile (lib/proof_evidence.py prepare_environment: python3 -s -S wrapper, LANG=C, fixture Git config, stripped environment). That is main's code, not this branch's; before this branch those sections were nearly always ended by the 900 s cap instead of running. The owner of the private profile should find which part makes the probe return 2. (3) Time: with this Mac at 84-94 percent CPU from other work, the replay reached a verdict on 30 of 57 checks inside 905 s (18 passed, 12 failed); 8 were invalid because something wrote what they read during the run, and 19 were ended at the gate cap. The incident run reached 3. The CPU admission line (CEO ruling 77) is what bounds it.

## What was already tried

Each failing unit retried alone, with and without RICHOS_MUTATION_PASSES=0, on the branch and on main. Class 1 fails everywhere. Class 2 passes alone through ci-shard.sh on main and on the branch, and fails through the branch's proof-run.py with a single check; on main the same proof-run retry was never admitted (host 94 percent mean for 800 s). merge-check-scope also failed in the replay: that one was this branch's own (a test pinned the stale SCR weight) and is fixed in 1f5ca269a.

## Proceeding meanwhile

Rules 1-3, the nightly engine run and the switch are committed with red/green tests. The full nightly engine run is executing once for its measurement and raises its own escalation for whatever fails.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261001T002153Z-46ac290e`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261001T002153Z-46ac290e --disposition "<what you decided or did>"
