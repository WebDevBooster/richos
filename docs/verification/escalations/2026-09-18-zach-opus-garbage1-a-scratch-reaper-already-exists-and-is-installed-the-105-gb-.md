# Escalation: A scratch reaper already exists and is installed; the 105 GB escaped through a two-glob allowlist, not through an absent mechanism

- id: `esc-20260918T070415Z-605bffc0`
- raised: 2026-09-18T07:04:15Z
- from: zach-opus-garbage1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-garbage1` (branch `cc/zach-opus-garbage1`)
- head: `0b0ae94e8278224270e1dad4bc7c1343cc59aa28`
- state: **proceeding**
- for: lead

## The question

Confirm I should FIX AND EXTEND the existing scratch-reaper (one-line root cause: SCRATCH_TMP_PATTERNS is an allowlist that does not match root-mutation.*) rather than build the brief's parallel scratch.sh/scratch-sweep.sh/second-ledger/second-launchd-job, which would duplicate a mechanism that already has four safety walls, three-valued liveness and a mutation harness while leaving the actual defect in place.

## What was already tried

Re-derived every measured claim in the brief. (1) The brief says 'Nothing covers $TMPDIR' — FALSE. scripts/scratch-reaper.sh + scripts/lib/scratch-reaper.py (39 KB) + .test.sh + .mutation.sh landed 2026-09-17 09:45 as commit c832af25, ~13h BEFORE the 22:39 root-mutation sandbox. Its launchd agent com.richos.scratch-reaper is INSTALLED (~/Library/LaunchAgents) and LOADED (launchctl list), firing at 04/10/16/22:40, and its SessionStart hook session-start-scratch.sh is registered in BOTH hooks/hooks.json:72 and .claude/settings.local.json:99. (2) ROOT CAUSE, verified: orchestration.config:645 declares SCRATCH_TMP_PATTERNS='richos-*-workspace richos-work-*' and scratch-reaper.py:583-585 scan_tmp() 'continue's past any $TMPDIR entry matching neither glob. 'root-mutation.*' matches neither, so the 105.3 GB was never a candidate. Evidence: ZERO occurrences of 'root-mutation' anywhere in ~/.claude/state/scratch-reaper.log, and the 2026-09-18T03:40 run — five hours after the sandbox was written — freed 156 KB. (3) The brief's '296 engine files call mktemp' is a double-count: its own command greps scripts, scripts/lib and scripts/hooks, and scripts already contains the other two. Unique count is 171 files / 341 occurrences. (4) Genuinely absent, confirmed: any disk-space watchdog (no df call in the engine outside a comment line), any Stop/turn-end arm, any land-time call in mega-lander/workspaces.py, and an engine launchd/ directory.

## Proceeding meanwhile

Building the correct version of the brief's intent: widen the reaper's $TMPDIR coverage from a two-glob allowlist to a deny-by-default sweep of the legacy families, add the Stop and land-time arms, harden the mutation harnesses against the self-copy, and build the CEO's addendum-1 standalone disk watchdog (its own launchd timer, osascript notifications at 50/25 GB, JSON state file) which is new work under any reading. Defeat tests with positive controls throughout.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T070415Z-605bffc0`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T070415Z-605bffc0 --disposition "<what you decided or did>"
