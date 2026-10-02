# Escalation: The test iPhone cannot verify the developer certificate (no internet to Apple): RichConnect and its UI-test runner will not open from the Home Screen

- id: `esc-20261002T130011Z-68154930`
- raised: 2026-10-02T13:00:11Z
- from: isaac-opus-white1
- worktree: `/Users/alex/ab/richos-wt/isaac-opus-white1` (branch `cc/isaac-opus-white1`)
- head: `f4e8bba8dac6970e04f5b963c40ece4fd38c8375`
- state: **proceeding**
- for: lead
- needs: **ceo-hands** (the answer needs the CEO at a device)

## The question

Can the CEO give the test iPhone SE an internet connection (Wi-Fi), then on the phone tap Cancel on the 'Unable to Verify App' alert and open Settings > General > VPN & Device Management > Apple Development: Alex Booster (5AXUV66DSK) > Verify App?

## What was already tried

Since about 12:45Z every phone-ios.py session fails before its first step: 'The application could not be launched because the Developer App Certificate is not trusted' (xcodebuild test log), intermittently at first, now in nearly every session. The phone's own screen, recorded by the one session that ran (13:58 local), shows the system alert 'Unable to Verify App. An internet connection is required to verify trust of the developer Apple Development: Alex Booster (5AXUV66DSK). This app will not be available until verified.' when the RichConnect icon is tapped. A devicectl launch of the app at 12:54Z still worked, so the install is fine; the check is iOS's online verification. Nothing on this Mac can switch the phone's Wi-Fi or tap Verify (the runner itself is what will not start). The alert may still be on the phone's screen.

## Proceeding meanwhile

The fixed launch screen is committed (f4e8bba8d) and installed on the phone (devicectl, Release, store 2bde40a39312e8d9d6f15d6b); I am finishing everything that does not need the phone (before-build results, analysis, handover). Its recorded starts, the after timing runs and the final screenshot need the phone back.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261002T130011Z-68154930`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261002T130011Z-68154930 --disposition "<what you decided or did>"
