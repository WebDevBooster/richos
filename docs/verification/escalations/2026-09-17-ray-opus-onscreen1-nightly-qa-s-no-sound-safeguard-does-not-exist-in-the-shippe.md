# Escalation: Nightly QA's no-sound safeguard does not exist in the shipped app

- id: `esc-20260917T075759Z-91ab378a`
- raised: 2026-09-17T07:57:59Z
- from: ray-opus-onscreen1
- worktree: `/Users/alex/ab/richos-wt/ray-opus-onscreen1` (branch `cc/ray-opus-onscreen1`)
- head: `7088a57f6faf7daf2d9eea0a6c942ba675033f16`
- state: **work-complete**
- for: lead

## The question

Before the next on-screen nightly walk with voice in scope, what guarantees this Mac stays silent? RICHOS_VOICE_LIVE_AUDIO is absent from the published binary (strings -c = 0) and gates only cargo tests; a voice turn configured out=External Headphones with tts=macOS say and the UI showed 'Rich is speaking'. I cannot prove no audio played.

## What was already tried

Re-derived the brief's premise: grepped all non-test uses in source, then strings on the published binary (count 0); checked ui/main.js for any mute/speak-aloud control (none); read output volume before and after every step (unchanged 25, muted:false, but volume is not evidence of silence).

## Proceeding meanwhile

Full on-screen walk completed and committed; items 1-4 all performed. Voice turn ran once with a WAV-injected input, never the microphone.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T075759Z-91ab378a`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T075759Z-91ab378a --disposition "<what you decided or did>"
