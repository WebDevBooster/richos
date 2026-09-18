# Escalation: Candidate .8 walk cannot start: the Mac's screen is locked, so there is no window to walk

- id: `esc-20260918T093456Z-bc69d723`
- raised: 2026-09-18T09:34:56Z
- from: ray-opus-cand8walk
- worktree: `/Users/alex/ab/richos-wt/ray-opus-cand8walk` (branch `cc/ray-opus-cand8walk`)
- head: `426a22ce3108c5960bae31402a871217c32de872`
- state: **stopped**
- for: lead

## The question

Can the screen be unlocked (only the CEO can), or should I quit pid 39430 now and have the walk re-dispatched when he is back at the desk?

## What was already tried

pid 39430 is alive (ps, 05:25 elapsed). ioreg -n Root -d1 -a shows CGSSessionScreenIsLocked=true, locked at epoch 1789723909 = 2026-09-18T09:31:49Z, about 4 minutes after the app was launched. System Events reports 0 windows for richos-tauri AND 0 for Terminal and Finder (positive control: it is the lock, not the app). screencapture -R438,92,1024,700 fails with 'could not create image from display with rect'; a full-screen capture succeeds and is entirely black. So no click, no typed message and no screenshot of the window is possible, and nothing about the background-job flow can be observed.

## Proceeding meanwhile

Build identity already verified from disk (CFBundleVersion 1.2.0-nightly.20260918.2; build-cand8.log source b0063d98; git proves the readiness-gate fix ee59193a is an ancestor of b0063d98). I am polling for the screen to unlock and will walk the moment it does; if it is still locked I will quit the instance per CEO 54 addendum 4 and report the blocker only.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T093456Z-bc69d723`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T093456Z-bc69d723 --disposition "<what you decided or did>"
