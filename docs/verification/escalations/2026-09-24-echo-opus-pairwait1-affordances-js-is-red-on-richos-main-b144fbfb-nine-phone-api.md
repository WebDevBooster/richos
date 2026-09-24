# Escalation: affordances.js is red on richos main b144fbfb: nine phone-API strings are unclassified in ui/tests/lib/state-registry.js

- id: `esc-20260924T204635Z-079632c8`
- raised: 2026-09-24T20:46:35Z
- from: echo-opus-pairwait1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-pairwait1` (branch `cc/echo-opus-pairwait1`)
- head: `72fd4356a855c02135483063ba2dc877d1cc792d`
- state: **proceeding**
- for: lead

## The question

Who classifies the nine attachment/native-push phone-API reasons (attachments.rs:396,400,403,423,426; routes.rs:781,845,850; device.rs:1376) in state-registry.js? The attachment ones render only in the native apps, so an ACTIONABLE control there is a claim about another feature's UI that I will not guess.

## What was already tried

Classified my own two new Mac sentences (72fd4356); git grep finds all nine strings at b144fbfb and my diff adds none; affordances.js then fails only on those nine (2 FAIL, 113 PASS). proof-run stops the whole selection at that first failure, so any branch touching app/ui cannot land green until they are classified.

## Proceeding meanwhile

Running the rest of my proof selection without affordances.js and finishing the handoff.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260924T204635Z-079632c8`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260924T204635Z-079632c8 --disposition "<what you decided or did>"
