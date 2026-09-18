# Escalation: Does the installed webview's localStorage survive a relaunch? It decides audit-8 row 5 and makes two of my own fixes inert if the answer is no

- id: `esc-20260918T111438Z-8f6a1a75`
- raised: 2026-09-18T11:14:38Z
- from: echo-opus-ui1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-ui1` (branch `cc/echo-opus-ui1`)
- head: `4fcdf19bbbd9099a842fd92ab3225900d7fc2de0`
- state: **work-complete**
- for: lead

## The question

Run the installed app, flip Opening screen off, quit, relaunch, and read localStorage for richos.splash.enabled. If it is absent, the first-paint splash decision needs the durable answer injected before scripts run (a src-tauri initialization script), and my two localStorage-backed fixes need moving to config.rs.

## What was already tried

Traced audit-8 row 5 end to end in source. set_splash_enabled persists (Ray's config.json proves it: splash_enabled false, splash_disabled_at stamped). splash_enabled returns a bare bool, so main.js's syncSplashFromBackend cannot poison the mirror. setSplashEnabled writes the mirror synchronously at the press. splash.js's enabled() reads ONLY that mirror, at parse time in the head, and main.js reconciles it from the backend at the very END of init with a comment saying so: neither call affects anything the CEO can see this launch. So the only remaining mechanism for the curtain coming back on the next two launches is that the mirror was GONE, i.e. the webview's local storage did not survive the relaunch. I cannot test that here: it needs the installed app, my brief forbids touching it, and no candidate is on screen. Also verified: the UI is byte-identical between candidate .7 (9da3c7d5) and candidate .8 (a7c875d6), empty diff over app/ui, so nothing in the renderer changed between those builds.

## Proceeding meanwhile

All nine of my rows are committed and the full 49-suite runner is green. The two fixes at risk are row 12 (illustrative counters persisted per dataset) and row 13a (Not now about the memory folder remembered) — both pass every test and both would be inert on the installed app if storage does not persist. I flagged that in the code and in the record rather than leaving it to be discovered.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T111438Z-8f6a1a75`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T111438Z-8f6a1a75 --disposition "<what you decided or did>"
