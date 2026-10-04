# Escalation: Android Hear it is fixed and committed, but the emulator check of the fixed build cannot finish: the engine stops my emulator about a minute after every boot (device lease supervisor ended)

- id: `esc-20261004T104551Z-32921599`
- raised: 2026-10-04T10:45:51Z
- from: andy-opus-hearit1
- worktree: `/Users/alex/ab/richos-wt/andy-opus-hearit1` (branch `cc/andy-opus-hearit1`)
- head: `4f4d3ec00d2466a2c530a0f9811a54c4096a445e`
- state: **work-complete**
- for: lead

## The question

Do you accept the evidence below for the Hear it handover, or should someone (Otto names the owner) first fix the emulator lease so the post-fix screenshot of Stop plus the waveform can be taken?

## What was already tried

Branch cc/andy-opus-hearit1 (worktree /Users/alex/ab/richos-wt/andy-opus-hearit1), rebased on main 29f47d5e8: f2b2ce9d8 (Hear it by has_audio or the Mac audio capability, reply-play/reply-stop in core, one signed GET /api/audio, played in memory, Stop) and 4f4d3ec00 (the reply row redraws on core reply playback). Release build on my emulator, paired to google-review.richos.dev: Hear it shown under the demo reply (screenshot), and the tap played the host audio (logcat: audio focus for dev.richos.connect, 19200 frames delivered, focus abandoned). That same check found the row did not redraw (fixed in 4f4d3ec00; HearItTest screen test red without the fix, green with it). After the rebase, four boots in a row were stopped by the engine about a minute in: CPU GUARD ALERT Device lease ended, reason device lease supervisor ended (10:39:24Z, then run-active LEASE LOST twice inside one owner process holding RICHOS_TEST_DEVICE_OWNER_PID and testdevices run-active, as randroid review-walk does, with the Mac 78 percent idle). Reading testdevices.py: hold_lease returns as soon as process_start() differs from the recorded start, and process_start returns None on a ps timeout or error, so one failed ps would end the supervisor; I did not prove that this is the cause, and I changed no engine code.

## Proceeding meanwhile

Nothing further on this task; the review host is reset and reads back unpaired, the emulator is stopped, and the physical phones were never touched.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261004T104551Z-32921599`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261004T104551Z-32921599 --disposition "<what you decided or did>"
