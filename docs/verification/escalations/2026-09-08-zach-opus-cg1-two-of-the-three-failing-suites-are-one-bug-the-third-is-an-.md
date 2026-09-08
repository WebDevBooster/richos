# Escalation: Two of the three failing suites are one bug; the third is an obsolete contract and needs a ruling, not a fix

- id: `esc-20260908T161728Z-0c5b1962`
- raised: 2026-09-08T16:17:28Z
- from: zach-opus-cg1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-cg1` (branch `zach-opus-cg1`)
- head: `599170aa7edc801de181854735d58aaeaf7d964c`
- state: **proceeding**
- for: lead

## The question

task-completed-handoff.sh became a GATE on 2026-09-08 (b2603388/b3a67a3f), which deliberately deleted the old 'always exits 0, never crashes on garbage' suite for that hook. lifecycle-payload-transport.test.py still asserts that deleted contract (written 2026-09-07, green at cc599908, red the moment the gate landed). Does an UNPARSEABLE payload block a task completion (current code, exit 2) or pass through non-blocking (the transport suite's expectation, exit 0)? I will not rewrite that assertion green either way.

## What was already tried

Reproduced all three on 28f07ab5; fixed the genuine defect (the gate resolved its governing entity from the hook process's PWD, so a cwd inside the engine made it govern an unadopted repository and refuse instead of standing down) - completion-proof.test.sh and task-completed-handoff.test.sh are now 21/21, and they are the SAME test file behind two wrappers. The transport failures are unchanged by that fix, so all three are NOT one bug. I proved a candidate transport update out-of-tree (12/12) and deliberately did not commit it.

## Proceeding meanwhile

Running the full engine suite for the regression comparison against the 110/119 baseline. Separate finding the lead needs: the gate requires the worker's HEAD to already be an ancestor of refs/heads/main (completion-proof.py prove_member, and its own test test_unmerged_commit_refuses_then_actual_merge_accepts), so a teammate cannot mark a task complete until AFTER Rich merges - the reverse of this project's handoff order. femcboost's scripts/hooks/ecs-task-completed.sh calls the verifier directly with no adoption stand-down at all.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260908T161728Z-0c5b1962`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260908T161728Z-0c5b1962 --disposition "<what you decided or did>"

## Ruled, same session, by the lead

An unparseable payload produces NO advisory side effect AND does NOT block:
neither exit 2 nor a plain exit 0. A lifecycle payload is a message, the
agent-to-lead channel is roughly 50% lossy, and no load-bearing signal may
depend on it -- so an unreadable one must not be able to wedge a completion,
while garbage must still trigger no side effect. Both intents hold at once:
the refusal is written to the durable event log as `decision: "unreadable"`
and the hook exits 0. A readable payload whose delivery evidence fails still
exits 2.

The lead also ruled the ancestry-of-main requirement a real defect rather than
an obsolete assertion, and folded it into this task: a worker's completion
evidence is its commits on its OWN branch; ancestry of `refs/heads/main` is
the lander's check and the RECLAMATION gate, and it stays in
`verify_member_proof` where `daily-workspace-cleanup.py` reads it.

Delivered on this branch as three further commits; all three named suites exit
0. The femcboost ECS wrapper finding is report-only and routed separately.
