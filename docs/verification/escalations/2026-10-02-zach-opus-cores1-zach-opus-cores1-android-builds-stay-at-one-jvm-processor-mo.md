# Escalation: zach-opus-cores1: Android builds stay at one JVM processor; more needs a cpu_guard per-process rule change, not native-work

- id: `esc-20261002T015813Z-55158f47`
- raised: 2026-10-02T01:58:13Z
- from: zach-opus-cores1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-cores1` (branch `cc/zach-opus-cores1`)
- head: `d58d07ea66262438232a5e3c554b4e4b4ee58772`
- state: **work-complete**
- for: lead

## The question

Open a cpu_guard task so a native build's single process may exceed the 3-core per-process line up to the share admission granted it (as the release-build role already does for the nightly compiler), or accept that Gradle/Android builds keep one JVM processor?

## What was already tried

Shipped the allowance (branch cc/zach-opus-cores1). First version gave Gradle the allowance: an Android release build admitted with 4 cores ran its JVM at 6.08 cores; other agents had the host at the 80 percent line, and cpu_guard stopped the JVM after 10 s above JOB_CORES=3 (events.jsonl, pid 3022, 2026-10-02 00:21Z), failing the build. Attributed per-process sampling then showed a JVM held to ONE processor already peaks at 1.22-2.32 cores (its own JIT and GC threads), so two processors would sit on the 3-core line. Final code: every JVM keeps 1 processor, release Swift/Xcode 1 job, Cargo at most 2 jobs (rustc peak measured 1.36 cores at 2), debug Swift/Xcode get the whole allowance. The Android build the CEO saw is therefore unchanged by this branch; its fix is in the watchdog's per-process rule.

## Proceeding meanwhile

Nothing; the branch is committed and handed over.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261002T015813Z-55158f47`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261002T015813Z-55158f47 --disposition "<what you decided or did>"
