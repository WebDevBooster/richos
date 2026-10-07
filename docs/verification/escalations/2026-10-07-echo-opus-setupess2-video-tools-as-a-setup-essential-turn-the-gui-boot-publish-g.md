# Escalation: Video tools as a setup essential turn the gui-boot publish gate red: its healthy fixture has no speech model

- id: `esc-20261007T105018Z-490a3823`
- raised: 2026-10-07T10:50:18Z
- from: echo-opus-setupess2
- worktree: `/Users/alex/ab/richos-wt/echo-opus-setupess2` (branch `cc/echo-opus-setupess2`)
- head: `d7c3b3006a8e05b155a806775d87d1c10b52b913`
- state: **proceeding**
- for: lead

## The question

For gui-boot's healthy fixture machine (app/scripts/lib/gui-launch.sh gui_machine), may I (A) give it real video tools: yt-dlp installed by the product's own media_tools code with placeholder bytes, plus a real pinned speech model the operator names in a new RICHOS_GUI_SPEECH_MODEL input (like RICHOS_RUNTIME_DIR), cloned into each fixture home with cp -c? That also means nightly-local.py and testvm/run-suite.sh must pass or push that file (small.en is 487,614,201 B at ~/Models/Whisper on this Mac; tiny.en, 77,704,715 B, is on no disk here yet). Or (B) leave gui-boot to a separate job and land slice 3 knowing B2 is red until then?

## What was already tried

Slice 3 is built per plan section 2 (Component::MediaTools; present means tools/yt-dlp verifies AND richos_voice::stt::readiness() is Ready). gui-boot.test.sh:391-393 holds the RESOLVED rule '^[richos] first-run setup: nothing missing.$' against gui_machine's fixture, and nightly-local.py treats a candidate with no gui-boot result as unpublishable. readiness() is Ready only with a real pinned model whose sha256 verifies, plus one calibration decode (stt.rs choose_model), so a fake model cannot satisfy it honestly. The plan's section 5 sizes do not include this. Second premise to know: the plan says 'until every component is present ... the app has no lease'. In code the lease needs only Claude Code and the engine (EngineLeaseFactory, send gate main.rs:1529), so with only the video tools missing the sheet lists them and setup_status reports complete=false, but Rich still converses. I kept that and did not add a send refusal, because refusing every conversation while a 3 MB or 487 MB download is offline would be new scope.

## Proceeding meanwhile

Proceeding on the slice itself and its VM setup walk (fresh guest: the sheet lists only the video tools, setup incomplete, Set it up installs yt-dlp and the speech model, then complete; relaunch asks nothing). I am not touching gui-boot, nightly-local.py or run-suite.sh until you answer.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261007T105018Z-490a3823`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261007T105018Z-490a3823 --disposition "<what you decided or did>"
