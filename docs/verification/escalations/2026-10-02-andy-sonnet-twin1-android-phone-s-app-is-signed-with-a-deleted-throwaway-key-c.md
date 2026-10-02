# Escalation: Android phone's app is signed with a deleted throwaway key (CN=seen scratch), not the upload key: the seeded real run needs an uninstall, which is the CEO's decision

- id: `esc-20261002T101635Z-e9ab0ce9`
- raised: 2026-10-02T10:16:36Z
- from: andy-sonnet-twin1
- worktree: `/Users/alex/ab/richos-wt/andy-sonnet-twin1` (branch `cc/andy-sonnet-twin1`)
- head: `7267a85a18cf8606b21326a0a32e1c5c27afeec6`
- state: **work-complete**
- for: ceo

## The question

The RichConnect on the wired Android phone (<android-phone>) carries signer 510a6ef92a41 (CN=seen scratch, from andy-sonnet-seen1's unpaired fresh install; its keystore no longer exists), not the upload key (b71a8acfa07c). No twin or release build signed with the upload key can go over it with install -r, so the real seeded run cannot happen without one uninstall. Per the CEO the app is never uninstalled or wiped; does the CEO allow ONE uninstall of this scratch-signed, unpaired install (it holds no saved transcript), after which the upload-signed release goes on and the twin works from then on? Or should the app stay as it is and the real run wait?

## What was already tried

randroid device install (this checkout's upload-signed release): phone refused INSTALL_FAILED_UPDATE_INCOMPATIBLE, nothing changed. randroid device perf --cold 10 --warm 0: built the upload-signed twin (debuggable, dev.richos.connect 1.0.0 versionCode 1), then refused before any install with the plain sentence naming both signers; the phone is untouched. Searched for the scratch keystore: none left on disk.

## Proceeding meanwhile

Code, tests (scripted adb: mobile-perf 92 cases, mobile-device 21 cases) and the commit are done and handed over; the real seeded run is the only thing not done.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261002T101635Z-e9ab0ce9`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261002T101635Z-e9ab0ce9 --disposition "<what you decided or did>"
