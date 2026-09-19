# Escalation: My mutation harness ran brew install on the CEO's Mac: 58 formulae changed, displayplacer removed, tesseract and an ffmpeg-full/whisper.cpp relink remain

- id: `esc-20260919T200721Z-123c950d`
- raised: 2026-09-19T20:07:21Z
- from: zach-opus-hostguard1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-hostguard1` (branch `cc/zach-opus-hostguard1`)
- head: `07cb236be8b02e455fdb40a3d927ecdb9659a095`
- state: **proceeding**
- for: lead

## The question

Do you want the whisper.cpp link put back to 1.9.1 and tesseract removed, or is the machine fine as it stands? I can do neither safely without your call: ffmpeg-full now depends on tesseract, and 1.9.1 is still on disk so a relink is one command.

## What was already tried

Verified attribution from brew INSTALL_RECEIPT.json timestamps rather than directory mtimes. displayplacer was absent at 19:12 and present at 20:56, so it is mine; uninstalled and verified gone. tesseract is mine too but ffmpeg-full now depends on it, so removing it would break ffmpeg-full and I stopped. The uninstall itself auto-removed unbound, libevent and mbedtls@3. brew missing reports only a pre-existing gcloud-cli/python@3.13 gap, and whisper-cli, ffmpeg, tailscale, node and tesseract all still resolve. RichOS does not use the Homebrew whisper binary at all - voice_provision.rs line 32 says no binary ever, it fetches pinned weights - so the 1.9.1 to 1.9.4 relink is not a product risk. whisper.cpp 1.9.1 is still on disk.

## Proceeding meanwhile

The guard itself is done and green: 101 suite cases, 19 of 19 mutants load-bearing. The cause is fixed at the mechanism: the harness passes each mutant rationale as a double-quoted bash argument, and one rationale contained backticks around a brew install line, which bash executed as command substitution. Every backtick is now gone from that file and a suite case Z3 asserts there are none, alongside Z1 and Z2 which assert the guard parses and that its embedded python block carries no apostrophe - three apostrophe incidents preceded it. I am continuing with the wiring and the corpus record.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260919T200721Z-123c950d`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260919T200721Z-123c950d --disposition "<what you decided or did>"
