# Escalation: The phone's infinite-scroll backfill signs in the wrong place and the real Mac refuses it 404 — the stub hides it

- id: `esc-20260918T195221Z-3c25966d`
- raised: 2026-09-18T19:52:21Z
- from: echo-opus-pwaslice2
- worktree: `/Users/alex/ab/richos-wt/echo-opus-pwaslice2` (branch `cc/echo-opus-pwaslice2`)
- head: `691989198e3135db6f6cdb4c79872f53a532e5e9`
- state: **work-complete**
- for: lead

## The question

Which side moves: does lib/api.js backfill() put its credential in the query like the stream does, or does routes.rs events() accept the Authorization header when there is no query auth? It is one line either way, but it is a two-sided contract change and it is not slice 2.

## What was already tried

Re-derived at 48104748 while building slice 2. routes.rs:403-411 events() reads ONLY query_value(&request.query, "auth") and returns Outcome::NotFound when it is absent; grep for request.authorization inside events() (routes.rs:403-456) returns 0 occurrences, while the three header routes read it at routes.rs:210, 304, 504. lib/api.js backfill() (the only caller is app.js loadOlder) goes through request(), which puts the credential in the Authorization HEADER. So every 'load older messages' scroll on a real Mac is a flat 404. It is invisible because test/stub-mac.js:139-140 accepts req.headers.authorization OR the query auth, which is more permissive than the Mac, so api.test.js and desktop-verify are both green against a route the shipped Mac refuses.

## Proceeding meanwhile

Slice 2 is complete and green and does not touch backfill. I did not fix this: it is a separate pre-existing defect whose right fix is a design call between the two sides, and widening a reconnect slice into a two-sided contract change the day before the PWA ships is the wrong trade to make unasked.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T195221Z-3c25966d`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T195221Z-3c25966d --disposition "<what you decided or did>"
