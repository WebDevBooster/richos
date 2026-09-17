# Escalation: gui-boot.test.sh B0-B8 cannot run on this machine: no delivered engine runtime exists anywhere

- id: `esc-20260917T132043Z-ccfdb3c8`
- raised: 2026-09-17T13:20:43Z
- from: echo-opus-enginepin1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-enginepin1` (branch `cc/echo-opus-enginepin1`)
- head: `b32e43fd8cc03c87db5353a223388d26da23d683`
- state: **work-complete**
- for: lead

## The question

Who supplies an extracted engine with runtime/delivery.json (RICHOS_GUI_ENGINE_SOURCE) so the nightly boot gate's B half can be run at all, and should a land accept exit 2 from it in the meantime?

## What was already tried

Checked all three sources the suite accepts: richos/engine/runtime/delivery.json (absent in the worktree and on main), ~/Library/Application Support/RichOS/engine (the directory does not exist on this Mac), and ~/.claude/richos-engine (a symlink to /Users/alex/ab/richos/richos/engine, which has no runtime/). The suite takes its own declared host-gap exit 2 before it ever builds the binary, so B0-B8 have not run here. S1, A0-A8 and C1-C4 all PASS.

## Proceeding meanwhile

Landed spec point 22 with the boot-line shape held to the A-case accounting rule (regex gui-boot.test.sh:293) and the healthy-log fixture updated to what the boot now prints; A0 and A6 (33 refused declarations) confirm both. Note the B half boots an UNPINNED debug binary, where the release gate is inert by construction, so it could not have exercised this change even had it run.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T132043Z-ccfdb3c8`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T132043Z-ccfdb3c8 --disposition "<what you decided or did>"
