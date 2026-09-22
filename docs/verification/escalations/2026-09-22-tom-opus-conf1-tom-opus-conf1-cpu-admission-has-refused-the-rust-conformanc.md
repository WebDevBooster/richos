# Escalation: tom-opus-conf1: CPU admission has refused the Rust conformance verifier for 34+ minutes

- id: `esc-20260922T212514Z-9c0a7ec4`
- raised: 2026-09-22T21:25:14Z
- from: tom-opus-conf1
- worktree: `/Users/alex/ab/richos-wt/tom-opus-conf1` (branch `cc/tom-opus-conf1`)
- head: `d72331c16f5633f4182a3a097edf2f7ce2109935`
- state: **proceeding**
- for: lead

## The question

reserve.py has refused every attempt since 21:51 (CPU 99-100% busy, top itself timing out; a Gradle JVM and the VM lead). Can a concurrent build be paused so the verifier (small detached crate, ~1 min cold) and the selected make-release/make-engine-asset suites can be admitted, or should I keep waiting?

## What was already tried

108 admission attempts 15-20 s apart via richos/app/scripts/testvm/reserve.py; never bypassed

## Proceeding meanwhile

corpus, generator and README are committed and node-verified; retry loop continues; verifier crate and suite registration are written and will be committed after the Rust run

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260922T212514Z-9c0a7ec4`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260922T212514Z-9c0a7ec4 --disposition "<what you decided or did>"
