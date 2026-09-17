# Escalation: Candidate .5 walk cannot run: all three of the CEO's displays are asleep and the app has no window

- id: `esc-20260917T185419Z-f1435071`
- raised: 2026-09-17T18:54:19Z
- from: ray-opus-cand5walk
- worktree: `/Users/alex/ab/richos-wt/ray-opus-cand5walk` (branch `cc/ray-opus-cand5walk`)
- head: `aadb5b7418f36e012bec61f9d15777b07b7e0613`
- state: **stopped**
- for: lead

## The question

Wake the screen (the CEO's call) and relaunch or re-front candidate .5 so the walk can run, or defer the walk to when he is at the desk — which?

## What was already tried

screencapture -x of the full screen returned 1920x1080 of uniform black; system_profiler SPDisplaysDataType reports Display Asleep: Yes on all three displays (BenQ GC2870 main, HP E243, VA2246); System Events reports 0 windows for process richos-tauri (pid 56626); the app's own boot log line 2 says 'the runtime reported no attached display' and fell back to a platform-centered 1024x700, where candidate .4's log at the same launch path said 'restored 1024x700 pt at (664,108) ... inside Monitor #30942'. Build identity verified before stopping: CFBundleShortVersionString 1.2.0-nightly.20260917.5, the new honest notice string present, the old accusatory string absent.

## Proceeding meanwhile

Nothing on screen. I have verified build identity and read the run state off disk only; no typed turn, no audio, no model turn spent, output volume untouched at 60 unmuted.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T185419Z-f1435071`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T185419Z-f1435071 --disposition "<what you decided or did>"
