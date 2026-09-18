# Escalation: The richos-core test suite leaves one temp directory per fixture: 68,141 of them in TMPDIR right now (CEO §54)

- id: `esc-20260918T142756Z-6c0f2120`
- raised: 2026-09-18T14:27:56Z
- from: echo-opus-firstwords1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-firstwords1` (branch `cc/echo-opus-firstwords1`)
- head: `333c0190721d1501ba0bb9969bdf15bf75ebe22f`
- state: **work-complete**
- for: lead

## The question

Who owns making the richos-core fixtures self-cleaning, and should the disk watchdog count ENTRIES and not only bytes? At ~6.8 KB each this is ~460 MB, so a byte threshold sized for the 105 GB incident will never see it, while 68,141 directories is the kind of garbage §54 was written about.

## What was already tried

Measured it while checking my own slice left nothing behind (CEO §54): find $TMPDIR -maxdepth 1 -name 'richos-*' | wc -l = 68141, of which 21276 have an mtime inside the last 3 hours. Grouped by prefix the top are richos-preparation- (2953), richos-skills-fixture- (2012), richos-doctrine-fixture- (1900), then ~362 copies each of two dozen corpus/entity fixtures — i.e. one directory per fixture per test run, never removed, across every session that has ever run the suite. Mean size 6.8 KB over a 500-entry sample, so ~460 MB estimated, not measured whole. I removed the 3 entries I could attribute to my own new tests (richos-priming-test-*, 'richos first reply *') and verified they are gone. I did NOT mass-delete the rest, deliberately: ray-opus-cand9walk is driving a test instance whose app state may sit under the same TMPDIR, and a 10-minute mtime window does not prove a long-running app's state root is idle. Deleting another session's live state to tidy up would be the worse defect.

## Proceeding meanwhile

My slice is committed and handed off. This is a repo-level hygiene finding about the test suite, not about anything in my branch.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T142756Z-6c0f2120`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T142756Z-6c0f2120 --disposition "<what you decided or did>"

## Already owned — read this before dispatching anything

After raising this I found `esc-20260918T070415Z-605bffc0` (zach-opus-garbage1) in this same
directory, and it names the exact root cause of my measurement: `SCRATCH_TMP_PATTERNS` in
`orchestration.config:645` is the two-glob allowlist `richos-*-workspace richos-work-*`, and
`scratch-reaper.py:583-585` skips any $TMPDIR entry matching neither. `richos-doctrine-fixture-*`
and every other richos-core test fixture match neither, so none of the 68,141 was ever a candidate.
That escalation says the fix in flight is a deny-by-default sweep of the legacy families.

**So this is not a second mechanism to build.** What it adds to that one is a measurement of how
much the allowlist is missing (68,141 entries, ~460 MB estimated from a 500-entry sample) and one
question that is not in it: whether the watchdog should count ENTRIES as well as bytes, since a
byte threshold sized for the 105 GB incident will never see this.
