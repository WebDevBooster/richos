# Escalation: The brief's diagnosis was wrong: the record id ALREADY carries the revision and the supersede path was already built

- id: `esc-20260917T112122Z-b62eea60`
- raised: 2026-09-17T11:21:22Z
- from: norm-opus-reingest1
- worktree: `/Users/alex/ab/richos-wt/norm-opus-reingest1` (branch `cc/norm-opus-reingest1`)
- head: `91a91ec47cf323916bced8041d6ee669a09a2fcc`
- state: **work-complete**
- for: lead

## The question

Nothing blocks the fix — but does anything else in the record repeat the brief's premise that the workspace evidence record id is derived from the event rather than its revision? That premise would have had me redesign a working id scheme.

## What was already tried

Reproduced the live failure exactly in the mocked loop (same message, same exit 2) before changing anything: promotion.js recordIdFor already digests (sourceItemId + vendorEtag), and promoteFromEvidence already passes supersedes through to the loro writer's supersedeRecord. The real defect was the PROMOTION LEDGER LOOKUP: it only ever answered for the newest promoted revision per item, so an older revision still in the (immutable, cumulative) evidence zone looked unpromoted and was offered to the writer a second time. Fixed by keying the ledger read on (sourceItemId, vendorEtag) — the ingest ledger's own key. No change to the writer's no-overwrite rule.

## Proceeding meanwhile

Landed on cc/norm-opus-reingest1: 94bf4a8f, 512a839c, 91a91ec4. npm run -s test:workspace 398 passed 0 failed; test:promotion 40 passed 0 failed. The CEO's live corpus needs no migration — every promoted revision already has a ledger line, so the next sync recognizes them and simply stops attempting the refused writes.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T112122Z-b62eea60`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T112122Z-b62eea60 --disposition "<what you decided or did>"
