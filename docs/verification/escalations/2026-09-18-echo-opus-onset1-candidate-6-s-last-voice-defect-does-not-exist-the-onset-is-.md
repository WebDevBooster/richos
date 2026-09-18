# Escalation: Candidate .6's last voice defect does not exist: the onset is fine, the harness was a second echo

- id: `esc-20260918T061828Z-01a1b15d`
- raised: 2026-09-18T06:18:28Z
- from: echo-opus-onset1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-onset1` (branch `cc/echo-opus-onset1`)
- head: `55ccea4918620e4434efbfe954ebea44079b9aab`
- state: **work-complete**
- for: lead

## The question

Does candidate .6's READY verdict change now that its remaining voice defect is closed as a harness artifact, and who captures a few seconds of the CEO's own voice at his Wave:3 so the near-field level in the record is his rather than a synthesizer's?

## What was already tried

Reproduced on the committed echo-path fixture (path (a) of ceo-decisions section 53) with a near-end voice superimposed on the microphone track only, canceller unconfident and asserted so. Swept the talker from -52 to -12 dBFS. First utterance START over Rich's audible answer: -36.0 dBFS. First START with Rich SILENT: -39.0 dBFS. Ray's say-through-the-speakers talk-over, as the running app measured it in audit-5: -44.7 dBFS, i.e. 5.7 dB below the crossover even in an empty room. A near-field voice sits 11-21 dB above it. Positive probe: raising the VAD absolute floor 0.005->0.1, and separately SPEECH_ONSET_FRAMES 7->120, each drives the new test RED. No gate, threshold or constant changed. 0 live playbacks; output volume read-only, 60, unchanged.

## Proceeding meanwhile

Work is complete and committed on cc/echo-opus-onset1. Two things I deliberately did NOT build and recorded instead: a log line for sounds that start NO utterance (needs widening CapMsg::Started across every match site, and the instruction was to stop), and freezing the VAD floor while the audible window is open (would recover the 3.0 dB the answer costs, but nothing measured justifies touching a shipped gate).

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T061828Z-01a1b15d`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T061828Z-01a1b15d --disposition "<what you decided or did>"
