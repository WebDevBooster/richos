# Escalation: IN2's fix lands in inflight-notify.test.sh, which is inside zach-opus-mr2's declared file scope

- id: `esc-20260905T235915Z-f3690aa9`
- raised: 2026-09-05T23:59:15Z
- from: zach-opus-rd1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-rd1` (branch `zach-opus-rd1`)
- head: `eb70a5af06dc695f084d8bb08b171be0afc38565`
- state: **proceeding**
- for: lead

## The question

Do I apply the proven one-line fixture change to engine/scripts/hooks/inflight-notify.test.sh line 37, or does it go to zach-opus-mr2 whose scope is engine/scripts/hooks/*.mutation.sh and their .test.sh siblings?

## What was already tried

Reproduced the Linux-only IN2 failure on macOS with a four-arm controlled experiment and confirmed the workflow header's diagnosis exactly. The abspath-not-realpath mutant is only load-bearing when the sandbox path passes through a symlink: with a real sandbox path the mutant SURVIVES (green, the Linux failure), with a symlinked sandbox path it is killed at case 5j. Both unmutated controls are green on both path shapes, so the redness is the mutation and not the path. The fix is to replace inflight-notify.test.sh:37 SANDBOX=$(mktemp -d -t inflight-notify.XXXXXX) with a sandbox reached through a deliberate symlink, which makes the property load-bearing on every host instead of only where /tmp happens to be a symlink. A first attempt to reproduce via TMPDIR was INVALID and I discarded it: macOS mktemp -d -t ignores TMPDIR entirely and kept using the symlinked /var/folders, so the arm that was meant to remove the symlink never did.

## Proceeding meanwhile

Finishing the full contract-integrity.test.sh pass on this host. provision-claude-md.test.sh is already fixed and green 37/37 at commits 0b6842a and eb70a5a.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260905T235915Z-f3690aa9`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260905T235915Z-f3690aa9 --disposition "<what you decided or did>"
