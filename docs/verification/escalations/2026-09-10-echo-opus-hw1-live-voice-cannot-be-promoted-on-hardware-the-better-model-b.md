# Escalation: Live voice cannot be promoted on hardware: the better model blows the record's own 1 s latency ceiling on the CEO's M4

- id: `esc-20260910T090750Z-78d61216`
- raised: 2026-09-10T09:07:50Z
- from: echo-opus-hw1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-hw1` (branch `echo-opus-hw1`)
- head: `7272ecf86463252576d7dee6df80a58ca6d227b9`
- state: **proceeding**
- for: lead

## The question

For LIVE voice only: is the record's stated ceiling (stt.rs:28, 'a second of dead air after every sentence') still the binding product promise? If yes, no Mac measured today may run q5_0 live and the live ladder can only step DOWN; if the ceiling has moved, say what it is and I will re-derive.

## What was already tried

Measured all five installed models at utterance length on the CEO's M4 at stt.rs decode_args(None) argv, /usr/bin/time -l, 8 warm reps for the two decisive rows. small.en 0.512-0.670 s (median 0.521); large-v3-turbo-q5_0 1.302-1.377 s (median 1.331) - 2.55x, and 30-38% OVER the 1.000 s ceiling. Peak RSS inverts the assumed reason: q5_0 856,899,584 B vs small.en 865,189,888 B, so the quantized turbo is CHEAPER in memory than the model kept for weak hosts; memory never discriminated. Also measured and rejected two obvious inputs: kern.memorystatus_vm_pressure_level is persistently 2 (WARN) on his own machine under normal load, and available memory swung ~100 MB between consecutive samples - either as an input would demote him at random.

## Proceeding meanwhile

Building the resolver for BOTH surfaces against measured decode speed rather than RAM. Call transcription meets the criterion fully (24 GB Mac resolves to q5_0 by asking the machine, provenance names it, constrained machine auto-demotes to the low-resource tier that exists today and is never selected). Live voice resolves DOWN only, with the promotion door left open and automatic the moment a machine measures fast enough.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260910T090750Z-78d61216`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260910T090750Z-78d61216 --disposition "<what you decided or did>"
