# Escalation: cc/isaac-opus-echo2 is committed, but the proof selection cannot go fully green: S5 fails on main, and simulator admission keeps timing out

- id: `esc-20260925T003846Z-9e5a7517`
- raised: 2026-09-25T00:38:47Z
- from: isaac-opus-echo2
- worktree: `/Users/alex/ab/richos-wt/isaac-opus-echo2` (branch `cc/isaac-opus-echo2`)
- head: `b32b2cf867bfa6f8bd489f1d3388833b303dea8b`
- state: **work-complete**
- for: lead

## The question

Should native-ios-share S5 (preserved PWA unchanged since preserved/mobile-ios-and-pwa-2026-09-24) be re-baselined for the pairing-v2 PWA commits e2da1f28, f03d89dd and addaee46 on main, and who reruns the simulator suites once the host has headroom?

## What was already tried

Post-merge (b32b2cf8, main 48577b38), the whole selection ran as proof-run.py --keep-going --capacity 1 --working (logs /Volumes/E1TB/state/richos/proof-runs/a75a7273ecb0/20260924T221449Z-zpn_wo2x): 7 of 10 checks passed (native-ios-core 213 tests, lint, make-release, make-engine-asset, proof-for, mobile-perf, native-release-policy). native-ios-ui failed because the lease expired (esc-20260924T220236Z-52fae3ec). native-ios-share S5 lists richos/web/web-app/app.js and lib/api.js, which were changed on main by those three PWA commits; this branch has no diff under richos/web against main. native-ios-app A1 and share S7 failed with 'worker admission timed out after 60s' and 'simulator boot admission exceeded 60s' in testdevices._device_admission (60 s timeouts at testdevices.py:1047-1049) while the host sat at or above 80% CPU. Two more app retries hit the same timeouts, or 'prepared simulator is leased by another run'. Before the merge, native-ios-app (all 8, A3 included after 0ef595d9) and native-ios-share passed in proof run 20260924T212316Z-3zwcmeyq.

## Proceeding meanwhile

Handing off; no further simulator retries, to avoid adding load to a saturated host.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260925T003846Z-9e5a7517`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260925T003846Z-9e5a7517 --disposition "<what you decided or did>"
