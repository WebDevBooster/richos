# Escalation: 200 of the 218 'could not be deleted' paths are a reaper bug, not macOS temp dirs — and 12.8 of the 13.9 GB is two campaign roots, not foreign temp

- id: `esc-20260919T124123Z-54d1bf64`
- raised: 2026-09-19T12:41:23Z
- from: zach-opus-reaper1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-reaper1` (branch `cc/zach-opus-reaper1`)
- head: `be014735131428ec7d8f6d79474a5df6d02880d5`
- state: **proceeding**
- for: lead

## The question

None needed to proceed — this is a premise correction. Confirm only that reclassifying the 12.8 GB of campaign roots OUT of 'other programs' temp' and INTO its own 'a person must remove this' line is what you want the CEO to read.

## What was already tried

Ran scratch-reaper.sh --json on this machine from the worktree at be014735 (rc=3). Read ~/.claude/state/scratch-failures.json (218 rows) and classified every one by st_mode and errno. MEASURED: 198 are unix SOCKETS failing '[Errno 102] Operation not supported on socket' (197 are srt-mux-*.sock, 10 days old, 0 bytes), 2 are FIFOs failing '[Errno 20] Not a directory', and only 18 are the macOS daemon temp directories the brief describes. apply() branches on islink/isfile/else-rmtree, so every socket and FIFO it has correctly decided to DELETE goes down the rmtree path and can never succeed — 200 permanent MASSIVE ALERT lines from one missing os.unlink branch. Separately: all 18 daemon dirs carry SF_NOUNLINK (st_flags 0x00100000) and the com.apple.rootless xattr, which is a structural pre-deletion test far better than the name/mode heuristic the brief proposes. And the skipped 13.96 GiB is NOT 4,466 foreign entries: it is 12.8 GiB of two DECLARED campaign roots past retention (richos-password-free-workspaces, richos-recovery-codex, each printing its own rm -rf) plus 1.15 GiB of genuinely foreign temp across 4,463 entries.

## Proceeding meanwhile

Implementing all five brief items plus the two corrections: apply() unlinks anything that is not a directory (200 failures become real deletions), SF_NOUNLINK/rootless paths are classified once as OS-owned and never retried (18 leave the ledger), and the alert splits four ways instead of three — ours-failed (MASSIVE ALERT), ours-a-person-removes-it (the campaign roots, with the command), other programs' temp (quiet line), undecidable (current run). Also confirmed the stale figure: the watchdog quotes undecidable=2/11.4 GB from the 12:10Z state file while the live run says undecidable=1/2,176 bytes.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260919T124123Z-54d1bf64`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260919T124123Z-54d1bf64 --disposition "<what you decided or did>"
