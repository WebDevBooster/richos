# Escalation: The pre-commit autocheck refuses every commit touching richos/mobile/: its synthetic range commit has no Battery-check trailer

- id: `esc-20261001T214721Z-7abdffe8`
- raised: 2026-10-01T21:47:21Z
- from: echo-opus-voicerow1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-voicerow1` (branch `cc/echo-opus-voicerow1`)
- head: `c6cde6cc94573b9c78b8c9c695e535b9b0b90c11`
- state: **proceeding**
- for: lead

## The question

Will the autocheck owner fix branch_range so the pre-commit battery question reads the real message (commit-msg already does), or do you want me to land the voice-row fix without the lab Mac change and the lab proof, which are the two files under richos/mobile/?

## What was already tried

git commit -F <message carrying 'Battery-check: NO — ...' as its last paragraph> in /Users/alex/ab/richos-wt/echo-opus-voicerow1 was refused twice: REFUSED: <sha> 'autocheck: the commit being checked' touches richos/mobile/ and has no Battery-check trailer. Cause read from the code: richos/app/scripts/autocheck/autocheck.py branch_range (around line 618-635, on main since 50a5bd1bd, 2026-10-01 19:57) writes the index as a commit-tree with the fixed message 'autocheck: the commit being checked' and hands base..that to proof-for.sh, whose battery step (proof-for.sh:223-243) runs battery-check.py over the range; battery-check.py check() reads trailers from each commit's own message, so the synthetic commit can never carry the answer. The trailer belongs to the commit-msg stage, which runs after pre-commit. Every commit touching richos/mobile/ is refused at pre-commit since that change, mine included. I did not bypass the hook, did not use --no-verify and did not point PROOF_FOR_BATTERY_CHECK elsewhere.

## Proceeding meanwhile

Fix and proofs are done and green (core 16+19 tests, src-tauri phone::rows/bridge/voice_notes 19, red on main shown, lab Mac real-listener voice proof passed with a recorded WAV). I am committing what I can without richos/mobile/ if the split compiles, and will commit the rest the moment the autocheck is fixed.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261001T214721Z-7abdffe8`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261001T214721Z-7abdffe8 --disposition "<what you decided or did>"
