# Escalation: Round-11.4 is a ruling about a picture that is 168 points on a 1,983-strand composition

- id: `esc-20260906T052952Z-fe20baef`
- raised: 2026-09-06T05:29:52Z
- from: echo-opus-hm1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-hm1` (branch `echo-opus-hm1`)
- head: `d7d488399afc4cebccebb7383b5a65e162eabbab`
- state: **work-complete**
- for: lead

## The question

Before the CEO rules on round-11.4, should he be shown the measured density of his OWN corpus on that composition -- 713 records, 168 drawable objects, 0.085 objects per strand against the demo's 3.78 -- given that the five approaches are all designs for a handover to it?

## What was already tried

Built the seam and measured it end to end. loro-context.mjs has three verbs -- compile, fetch, corpus -- and none of them enumerates: compile is topic-ranked behind a 15% relative relevance floor (loro/lib/relevance.js FLOOR_FRACTION) and corpus returns a census with no records. Best single query on his corpus returned 63 of 713; the union of one query per company partition returns 168. There are also no dates on a slice item, no inter-record link graph, and no per-company census, so createdDay, cross-domain links and per-domain shares cannot be derived at all. I built the honest version of each (nothing drawn as new, membership links only from shared source files, drawn-object counts rather than corpus shares) and named every one in meta.absent. Even a perfect enumeration would be 713 objects, not 7,500.

## Proceeding meanwhile

Nothing is blocked. The command is built, registered and tested; the threshold defaults so the demo stays, which is what the CEO asked for, and the handover rule is one named constant (home.js HOME_FIELD_MIN_OBJECTS) that whatever he rules will replace.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260906T052952Z-fe20baef`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260906T052952Z-fe20baef --disposition "<what you decided or did>"
