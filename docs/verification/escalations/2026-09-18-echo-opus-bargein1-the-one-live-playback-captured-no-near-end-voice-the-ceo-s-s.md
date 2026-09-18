# Escalation: The one live playback captured NO near-end voice — the CEO's sentence is not in the recording

- id: `esc-20260918T084515Z-0864acd4`
- raised: 2026-09-18T08:45:15Z
- from: echo-opus-bargein1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-bargein1` (branch `cc/echo-opus-bargein1`)
- head: `b76611ccc7a4f66bb4fa2957ac194ada5949b064`
- state: **proceeding**
- for: lead

## The question

Can the CEO give me one more 30-second playback while he is at the desk, cued the same way? If not, I ship the rule measured on the sanctioned superimposition path (§53 (a)) and say plainly that his own voice was never in the data.

## What was already tried

Recorded the pair at 08:42:18Z, 25.579 s, volume 60, Mac mini Speakers 48 kHz out / Wave:3 96 kHz in — devices identical to the failed test. Exit 0, one playback, no loop. Ran the shipped EchoCanceller + Vad over it: of 1443 far-active frames the VAD called 16 speech, and every substantial one sits at 1.568-1.824 s, which is 68 ms after PLAYBACK START at 1.500 s — it is the filter's convergence transient at the onset of Rich's own playback, peak residual -28.3 dBFS, near-end verdict 0 of 11. The only other speech frames are two ISOLATED single frames at 11.824 s and 18.592 s (0.016 s each). There is no 2-3 s region anywhere. He either did not speak or the relay reached him after the window. I cannot measure his sentence's duty cycle from this.

## Proceeding meanwhile

Proceeding on everything that does not need his voice: the new recording is a valuable SECOND echo-only fixture at his walk volume and it already moved the design — the playback-onset transient produces 11 CONSECUTIVE speech frames (0.176 s) at -28.3 dBFS, which the 2026-09-17 fixture (0 speech frames of 470) never showed, so it sets the hard floor for any consecutive debounce. I am scoring every candidate on both fixtures with the near-end voice superimposed on the mic track per §53 (a) using the Scene::near_end_talker harness that already exists in tests/self_voice_replay.rs.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T084515Z-0864acd4`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T084515Z-0864acd4 --disposition "<what you decided or did>"
