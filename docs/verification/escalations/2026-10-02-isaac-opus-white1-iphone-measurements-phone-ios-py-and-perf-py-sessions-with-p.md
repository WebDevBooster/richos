# Escalation: iPhone measurements: phone-ios.py and perf.py sessions with --prebuilt --stamp did not put the stamped app on the test iPhone; the phone ran an older build

- id: `esc-20261002T110901Z-6dc4643c`
- raised: 2026-10-02T11:09:01Z
- from: isaac-opus-white1
- worktree: `/Users/alex/ab/richos-wt/isaac-opus-white1` (branch `cc/isaac-opus-white1`)
- head: `a9216b6c58e99d6ef0ff6bb8a765c0c28c23fdc3`
- state: **proceeding**
- for: lead

## The question

Who owns making the iPhone tools verify the installed app before measuring (identity or refuse), and should earlier iPhone 'after' measurements by any agent today be re-checked?

## What was already tried

Evidence, 2026-10-02, test iPhone SE, store entry 31c5555e72c588a3e0979a41 (commit dc70f30e4, Release). (1) Disassembly of the stored binary: the app's init calls LaunchTiming.start, then Boot.start (writes the mark state-load-start), then LaunchScreenCache.refreshAfterUpdate (writes a preferences key, removes Library/SplashBoard). (2) After 12 phone-ios.py recording sessions and one perf.py ios --tap-launches 5 run, all naming that stamp: the app's perf-launch-timing.jsonl had the process mark but never state-load-start, the app container's Library/Preferences was empty, and Library/SplashBoard kept files dated 09:27 and 09:55. So the running app was not the stamped bytes. (3) After xcrun devicectl device install app of the same stored RichOSNative.app over the existing app (no uninstall, no prompt), one launch wrote Preferences/dev.richos.connect.plist and removed SplashBoard; later phone-ios.py sessions left the install path (BBC58DB1...) unchanged. (4) The app's install path also changed once (C6725AFD... to AB9C3E0C...) between 10:55Z and 11:01Z with no install line in perf.py's output; I could not name the installer. Neither tool reads back what is installed (perf.py's own record says an iPhone's installed bundle cannot be read back).

## Proceeding meanwhile

I installed my final build explicitly with devicectl and am re-recording the before and after starts with an explicit install of each build first, checking the app's own marks after each series; the earlier after recordings are marked invalid in my handover.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261002T110901Z-6dc4643c`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261002T110901Z-6dc4643c --disposition "<what you decided or did>"
