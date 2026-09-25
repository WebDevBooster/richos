# Escalation: Rich cannot read attached files (phone or Mac): the session blocks reads outside its working directories

- id: `esc-20260924T221114Z-fcb89e99`
- raised: 2026-09-24T22:11:14Z
- from: echo-opus-drop1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-drop1` (branch `cc/echo-opus-drop1`)
- head: `85f0469a1d0e4d80f1bff06d4416287e0389b0bf`
- state: **proceeding**
- for: lead

## The question

None needed from you unless you object: I am granting each conversation's session read access to that conversation's own attachments folder only (engine_profile.rs --add-dir), which fixes the phone path too. Object if a narrower or different grant is wanted.

## What was already tried

VM walk on 1.2.0-dev.85f0469a: the PNG paste and the PDF Finder drag both reached the composer and were committed and described; Rich replied that his setup does not let him read files where attachments are saved. engine_profile.rs sets blockReadsOutsideWorkingDirectories=true and --add-dir lists only the company repositories and the workspace state; <app data>/attachments/ is outside both, for phone files as well.

## Proceeding meanwhile

Implementing the per-conversation read grant in richos-core, with tests, then re-running the VM walk to see Rich describe both files.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260924T221114Z-fcb89e99`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260924T221114Z-fcb89e99 --disposition "<what you decided or did>"
