# Escalation: A second test in this baseline is flaky too: richos-core ledger_forward_compat_tests, same defect class as the voice one

- id: `esc-20260905T134826Z-c9d24b62`
- raised: 2026-09-05T13:48:26Z
- from: echo-opus-vc1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-vc1` (branch `echo-opus-vc1`)
- head: `51cbd51969c3deb7ce7e91105ecb282456bff285`
- state: **proceeding**
- for: lead

## The question

Do you want the same fix applied to richos-core's scratch() helper in this branch, or is that a separate task?

## What was already tried

Measured SystemTime::now() on this machine: it ticks at exactly 1000 ns, so as_nanos() carries only microsecond resolution. In a 12-thread probe, 206474 of 240000 samples took a value another thread had already taken (86.0%). richos-core tests/ledger_forward_compat_tests.rs:24 builds its scratch dir from process::id() + as_nanos() + stem, all of which can be identical across two parallel tests in the same binary, so two tests share one edited.jsonl. Observed live: a_skipped_record_is_reported_in_words_the_ceo_can_read failed at ledger_forward_compat_tests.rs:288 with skipped 0 vs 1 during a full-suite run, and passed 10/10 when that binary was run alone.

## Proceeding meanwhile

Fixing the richos-voice enumeration defect I was briefed on; not touching richos-core.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260905T134826Z-c9d24b62`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260905T134826Z-c9d24b62 --disposition "<what you decided or did>"
