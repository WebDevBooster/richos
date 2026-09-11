# Escalation: Workspace spec branch: land and install it only while no other session or agent is running

- id: `esc-20260911T120615Z-f108c222`
- raised: 2026-09-11T12:06:15Z
- from: zach-opus-spec2
- worktree: `/Users/alex/ab/richos-wt/zach-opus-spec2` (branch `cc/zach-opus-spec2`)
- head: `3816dd82312cf5d3192f9c74f87d4ee9d0e3c929`
- state: **work-complete**
- for: lead

## The question

Will you land cc/zach-opus-spec2 and run install.sh from the main checkout only when no other Claude session and no agent is running, and ask an administrator to remove the root LaunchDaemon com.richos.managed-workspace-broker?

## What was already tried

The first session on the new engine applies point 3 to everything already on disk: every cc/ and native workspace with no registration older than two minutes is finished work of an ended session; it lands on its own each one already in main and clean (a live old-engine agent's fresh workspace with no commits counts as landed and would be deleted) and holds new work until the rest are landed or discarded. install.sh unloads the nightly reconciler still loaded on this machine (probe Q7 fails until then). The broker daemon needs admin to remove; no engine client reaches it any more.

## Proceeding meanwhile

Work is complete and committed; the record is docs/verification/workspace-spec-implementation-2026-09-11.md

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260911T120615Z-f108c222`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260911T120615Z-f108c222 --disposition "<what you decided or did>"
