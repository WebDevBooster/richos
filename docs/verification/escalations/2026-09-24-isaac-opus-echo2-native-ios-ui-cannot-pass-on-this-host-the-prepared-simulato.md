# Escalation: native-ios-ui cannot pass on this host: the prepared-simulator lease expires (300 s idle) mid-run and the simulator is rebooted

- id: `esc-20260924T220236Z-52fae3ec`
- raised: 2026-09-24T22:02:36Z
- from: isaac-opus-echo2
- worktree: `/Users/alex/ab/richos-wt/isaac-opus-echo2` (branch `cc/isaac-opus-echo2`)
- head: `0ef595d9dc8a58abaa87bb92d60c2c5f5c38f3b5`
- state: **proceeding**
- for: lead

## The question

Who owns making the iOS UI suite renew its simulator lease during xcodebuild test (and is the 900 s maximum lifetime meant to cap a UI suite that takes 787-884 s per device under load)?

## What was already tried

Ran the whole proof selection 6 times from cc/isaac-opus-echo2. In run 6 (logs /Volumes/E1TB/state/richos/proof-runs/a75a7273ecb0/20260924T212316Z-3zwcmeyq) native-ios-ui failed 58 passed / 1 failed / 6 skipped on each device; the failure is 'Test crashed with signal term' (xcresult) in a different test on each device (testConnectionLight on SE, testComposerLight on Pro Max), and each one passed on the other device. The simulator syslog shows syslogd restarting at boot+5m23s (SE: boot 22:32:09, restart 22:37:32) and at about boot+5m on Pro Max (22:45:17 then 22:50), i.e. the simulator was shut down and rebooted by xcodebuild. testdevices.py registers the lease with idle_seconds 300 and max_seconds 900 (line 405, since 623fac5f) and nothing touches it while xcodebuild test-without-building runs (run-simulator.sh in native-ios-ui.test.sh; hold_lease never renews last_use). Proof-run history shows no native-ios-ui pass since 09-23 23:52.

## Proceeding meanwhile

Running the rest of the selection with --keep-going and reporting every other check's result; not modifying the engine lease policy (outside this brief).

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260924T220236Z-52fae3ec`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260924T220236Z-52fae3ec --disposition "<what you decided or did>"
