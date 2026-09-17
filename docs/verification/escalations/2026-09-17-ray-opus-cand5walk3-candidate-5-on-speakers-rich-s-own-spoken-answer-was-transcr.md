# Escalation: Candidate .5 on speakers: Rich's own spoken answer was transcribed and SENT as the CEO's prompt

- id: `esc-20260917T201206Z-85c01b05`
- raised: 2026-09-17T20:12:06Z
- from: ray-opus-cand5walk3
- worktree: `/Users/alex/ab/richos-wt/ray-opus-cand5walk3` (branch `cc/ray-opus-cand5walk3`)
- head: `5cee0cf47aab8973d6f5e6c268a5a4e46e56ed0e`
- state: **work-complete**
- for: lead

## The question

Should candidate .5 be published with a voice path that, on the CEO's own speakers, can feed Rich's own TTS back into the thread as a message from him and spend a model turn answering it — or does the capture have to stay muted for the whole of playout (not only while a chunk is playing) before this nightly goes out?

## What was already tried

Walked candidate .5 live on the running window (pid 19340, 1024x700, QA scratch home). Observation A (speakers, volume 85, I was silent through Rich's answer): the new honest notice fired on Rich's own echo — expected per the brief, and the copy is now conditional. Muted control: no discard, no notice at all, so the trigger is Rich's own voice. Then the deliberate talk-over: at 20:06:43.693Z the ledger recorded PromptReceived source=jam text='1, 2, 3, 4, 5.' — that is Rich's own counting ('One... two... three... four... five...') heard back through the Wave:3, recognized as speech, submitted as the CEO's message, and answered ('Six... seven... eight... nine... ten.'), spending a model turn. It is not my harness speech: my two say() phrases were 'Please count slowly out loud from one to twenty' (already logged at 20:06:35.672Z) and 'Excuse me Rich, you can stop counting now' (started 0.4 s before the prompt landed, and was itself discarded). The tainted-discard path caught the surrounding audio (erle -2.9 and -2.2 dB, 'cannot vouch') but did not catch this utterance.

## Proceeding meanwhile

Audit written to docs/verification/2026-09-17-nightly-1.2.0-20260917.5-onscreen-audit-2.md on branch cc/ray-opus-cand5walk3; the rest of the walk is complete and the other two fixes (#2 ticker orphan, #3 Settings bottom) verified fixed on screen.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T201206Z-85c01b05`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T201206Z-85c01b05 --disposition "<what you decided or did>"
