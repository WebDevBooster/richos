# Escalation: Codex review switch: the approved words promise Codex reviews FINISHED work, but the brief's path (the app watcher) only reviews work mid-job

- id: `esc-20261009T104422Z-d6970db4`
- raised: 2026-10-09T10:44:23Z
- from: echo-opus-codexswitch1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-codexswitch1` (branch `cc/echo-opus-codexswitch1`)
- head: `ae6c0f2839b694b5e04452ae3fc87397f5b01589`
- state: **proceeding**
- for: lead

## The question

In the app, the review that gates accepting finished work is the in-team Claude reviewer that app.py integrate requires (engine/mega-lander/app.py ~1438-1460; review_watch.py due() handover=False, AppWorld docstring 'MID-JOB ONLY'). The brief scopes the switch to the watcher's second_review.py reviews, which are mid-job only. Round 20.2's approved words say: 'Before your team's finished work is accepted, a second AI reviews it. Claude does that now. Turn this on and Codex does it instead.' Built as briefed, that sentence is not true: with the switch on, Codex reviews running work, and a Claude reviewer still accepts finished work. Which is wanted: (A) as briefed, switch picks the reviewer of the watcher's mid-job reviews only, and the words get a later fix; or (B) also route the handover (acceptance) review through second_review.py with Codex when the switch is on, which changes app.py integrate to accept a passing second_review verdict on the exact commit (engine Python, Zach's area, beyond this brief)?

## What was already tried

Read review_watch.py (AppWorld, due), app.py (prepare/integrate reviewer records), the plan's section 2.3/2.5 and the round 20.2 NOTES.md. Plan 2.5 says the app's handover keeps its existing receipt and the app watcher is mid-job only.

## Proceeding meanwhile

Building (A): the Settings switch exactly as round 20.2, the persisted setting, Codex installed/signed-in detection via Codex's own 'login status', and the watcher's per-review reviewer choice (Codex with CODEX_ISOLATION when on and available, Claude otherwise). All of it is needed under (B) too; (B) would add only the integrate change.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261009T104422Z-d6970db4`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261009T104422Z-d6970db4 --disposition "<what you decided or did>"
