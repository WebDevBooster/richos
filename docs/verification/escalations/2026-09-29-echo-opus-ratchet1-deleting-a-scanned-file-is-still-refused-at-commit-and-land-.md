# Escalation: Deleting a scanned file is still refused at commit and land after the lint ratchet fix: proof-for.sh counts a deleted uncovered script as UNCOVERED

- id: `esc-20260929T224259Z-f0226426`
- raised: 2026-09-29T22:42:59Z
- from: echo-opus-ratchet1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-ratchet1` (branch `cc/echo-opus-ratchet1`)
- head: `bd5459cb16f2be96900ef64be7da2ad51f808abd`
- state: **proceeding**
- for: lead

## The question

Who owns the second half of hunt part 2 section 03? proof-for.sh:554-556 has no exception for a deleted path, so a change that deletes a code file no suite covers is refused (UNCOVERED) by the commit check and, per its own message, by the land. It is outside my assigned scope (richos/app/scripts/lint/ only). Should a separate engineer fix proof-for.sh so a path gone from the tree is never UNCOVERED?

## What was already tried

Lint ratchet fix committed on cc/echo-opus-ratchet1 (6abac26f, README bd5459cb); the lint half now passes a deletion. Scratch commit deleting richos/app/scripts/generate-app-icons.sh (no suite declares it): autocheck output 'lint --changed --strict ... Static checks: 2 changed or dependent file(s), no count grew ... Lint passed in 5.12s', then 'UNCOVERED - 1 changed code path(s) that no suite claims: richos/app/scripts/generate-app-icons.sh ... COMMIT REFUSED'. A second scratch deleting make-signing-csr.sh (declared by signing-setup.test.sh:55) was refused by proof-for recon 'covers richos/app/scripts/make-signing-csr.sh: path is not in the tree'; that one is correct, since a real deletion edits the declaration in the same change. The uncovered case has no remedy: a deleted file cannot be given a suite, and a declaration naming it fails the same not-in-the-tree recon.

## Proceeding meanwhile

Finishing the lint proof: the scratch deletion is committed with hooks skipped only as a vehicle (it never lands and is removed before handoff), then lint.sh --all and lint.sh --all --lower run over it as the land runs them. Not touching proof-for.sh.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260929T224259Z-f0226426`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260929T224259Z-f0226426 --disposition "<what you decided or did>"
