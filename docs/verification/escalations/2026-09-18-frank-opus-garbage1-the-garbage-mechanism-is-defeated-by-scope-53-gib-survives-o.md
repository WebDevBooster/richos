# Escalation: The garbage mechanism is defeated by scope: 53 GiB survives on this Mac with no alert, and the allocator arm deletes live work

- id: `esc-20260918T091550Z-8d175065`
- raised: 2026-09-18T09:15:50Z
- from: frank-opus-garbage1
- worktree: `/Users/alex/ab/richos-wt/frank-opus-garbage1` (branch `cc/frank-opus-garbage1`)
- head: `4c0b1a5219346bb998caf28d278e7f35971b472d`
- state: **work-complete**
- for: lead

## The question

Do the three fixes go out as one Zach pass now (deny-by-default TMPDIR + a skipped= alert + the open-file wall on the allocator arm), or does the allocator-arm deletion defect go first on its own because addendum-4 work is creating that exact shape today?

## What was already tried

Attacked richos main e1af0f99 with 17 cases on this Mac, both launchd jobs armed. Measured today: 52,409 of 53,593 TMPDIR entries (1.90 GB) skipped by scan_tmp because it is still an allowlist; 25.77 GiB in /private/tmp outside the claude root swept by nothing (one 18.99 GiB dump); 25.42 GiB under ~/ab in no ledger; the app has 61 runtime temp_dir() sites and zero allocator calls. Sweeper says deletable=0 undecidable=0 exit 0 and both session notices print nothing. Separately PROVEN by deleting a fixture out from under live pid 76454: scan_scratch_root trusts a pid and never consults the open-file snapshot both TMPDIR arms use, and a detached richos-tauri test instance (pid 60433, ppid 1) is that shape live right now. Also: CLAUDE_CONFIG_DIR silences every failed-deletion alert; failures are absent from the reaper exit code; the drop alarm has no divisor (a 10-hour baseline printed DROPPED 30.0 GB). All fixtures were in a sandbox TMPDIR under the session scratchpad and are deleted.

## Proceeding meanwhile

Record committed at 4c0b1a52 on cc/frank-opus-garbage1: docs/verification/2026-09-18-garbage-mechanism-attacked.md — ranked table, every command and output, three fixes.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T091550Z-8d175065`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T091550Z-8d175065 --disposition "<what you decided or did>"
