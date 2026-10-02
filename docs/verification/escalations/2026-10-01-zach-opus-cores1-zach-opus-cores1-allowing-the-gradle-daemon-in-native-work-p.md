# Escalation: zach-opus-cores1: allowing the Gradle daemon in native-work.py does not make a second build warm; the engine supervisor kills it at every command end

- id: `esc-20261001T235259Z-b00d0c86`
- raised: 2026-10-01T23:52:59Z
- from: zach-opus-cores1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-cores1` (branch `cc/zach-opus-cores1`)
- head: `7c62d1d9436ed4311ee73ae5c2eb8da9f67a4159`
- state: **proceeding**
- for: lead

## The question

Keep --no-daemon (a cold JVM per native-work call, the cost measured and reported in my handoff), or open a separate task to let proc_tree's supervisor release a Gradle daemon started by a native build so it can live out its 2-minute idle timeout?

## What was already tried

Read the code path. native-work.py runs every build through worker_tokens.run_command, which runs it under proc_tree.py supervise; at the command's end finish_scope SIGTERMs every descendant it tracked (parent links, process groups and the RICHOS_PROCESS_SCOPE tag the daemon inherits). So dropping --no-daemon only starts a daemon that is killed when the same command ends: no later build ever reaches it warm. Letting it survive means an exemption in proc_tree.finish_scope, the engine-wide supervisor whose no-survivor rule keeps a worker permit covering everything its command started (and whose survivors otherwise turn the run into exit 125). That is outside native-work.py and outside this brief. The 2026-09-24 records (623fac5f, host-cpu-enforcement.md, docs/verification/host-cpu-enforcement-2026-09-24.md) do not blame the daemon for the incident; the one-core caps were the belt beside the lane and the budget.

## Proceeding meanwhile

Building the cores allowance in native-work.py (free cores below a 60 percent target, divided by admitted machine workers, floor 1), keeping --no-daemon, with its test red on main and green on the branch, and the before/after build timings. I will report the cold-start cost of a no-op Android build so the daemon trade is sized.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261001T235259Z-b00d0c86`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261001T235259Z-b00d0c86 --disposition "<what you decided or did>"
