# Escalation: The evidence ruling names a verb that would invert the loro license boundary; shipped verb is richos-evidence lookup

- id: `esc-20260917T032334Z-ab53828e`
- raised: 2026-09-17T03:23:34Z
- from: echo-opus-lookupwire1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-lookupwire1` (branch `cc/echo-opus-lookupwire1`)
- head: `6c47fd12d02fa0bde15577456174e1bccb236952`
- state: **work-complete**
- for: lead

## The question

Should the ruling doc's §1 table be corrected to richos-evidence lookup, or is loro-context evidence --find still wanted with the dependency inverted?

## What was already tried

Read engine/loro/bin/loro-context.mjs:2 (SPDX AGPL-3.0-only, Loro public component, imports nothing from tools/richos-service) against lib/workspace/evidence-lookup.js:98-100 (imports BOTH engine/loro/lib/{privacy,relevance}.js AND ./promotion.js). Built the door beside the module per the ruling's own $4 instruction and recorded the divergence in the commit and in docs/verification/2026-09-17-evidence-lookup-wired-end-to-end.md $6.2.

## Proceeding meanwhile

Work is complete and green: the app-side wiring ships as richos-evidence lookup, cargo test -p richos-core 1062 passed 0 failed, end-to-end run under a temp HOME passes every check including the covered-question control.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T032334Z-ab53828e`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T032334Z-ab53828e --disposition "<what you decided or did>"
