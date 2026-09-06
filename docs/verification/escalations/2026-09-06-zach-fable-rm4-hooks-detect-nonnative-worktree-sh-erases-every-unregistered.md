# Escalation: hooks/detect-nonnative-worktree.sh erases every unregistered entry under .claude/worktrees/ — a retirement quarantine is unregistered by construction

- id: `esc-20260906T015544Z-82747bce`
- raised: 2026-09-06T01:55:44Z
- from: zach-fable-rm4
- worktree: `/Users/alex/ab/richos-wt/zach-fable-rm4` (branch `zach-fable-rm4`)
- head: `4f8b31d1af0710c109077d4f042400740775674f`
- state: **proceeding**
- for: lead

## The question

May the hook's residue tell (c) be changed to skip names matching '.richos-retired-' and dot-directories, or better, to consult the retirement journal before it deletes? It is zach-opus-mr2's file, so I have not touched it.

## What was already tried

Found by reading: tell (c) of hooks/detect-nonnative-worktree.sh recursively deletes any <main>/.claude/worktrees/*/ entry that the worktree registry does not list, on the reasoning 'Unregistered == unowned == safe to AUTO-REAP'. workspace-retire.py quarantines a native worktree by RENAMING it, which unregisters it; renamed in place beside its siblings the quarantine was erased on the next tool call, and the sweep's byte-coverage refusal (the layer that protects a late writer) never got to run. Same shape as the 2026-09-05 incident: absence of a record read as nobody's. The reaper's residue scan would also report such an entry on every run.

## Proceeding meanwhile

Branch zach-fable-rm4 moves every quarantine into <parent>/.richos-retired/, a dot-directory that neither scanner's '*/' glob enumerates; the suite's QDIR row proves the glob shape against a real sibling. That is a mitigation from my side of the boundary. The hook's own rule is still wrong and should not depend on a glob it does not know about.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260906T015544Z-82747bce`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260906T015544Z-82747bce --disposition "<what you decided or did>"
