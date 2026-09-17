# Escalation: Workspace evidence cannot be read into a loro slice: 'evidence is not truth' is a tested invariant, and the promotion step that WOULD feed Rich is unbuilt

- id: `esc-20260917T012707Z-5653b4ae`
- raised: 2026-09-17T01:27:07Z
- from: echo-opus-evidence1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-evidence1` (branch `cc/echo-opus-evidence1`)
- head: `4b5abdb5e42a84a9d956e75daa5400f94bf1a5ea`
- state: **proceeding**
- for: lead

## The question

Is a second, separately-labeled retrieval channel over the evidence zone (Drive document text + mail metadata, NOT under the COMPANY MEMORY heading) an architecture change Sage should rule on, or is P2+/P5 LLM promotion the only sanctioned path for those two sources?

## What was already tried

Measured the read path end to end: engine/loro/lib/store.js:10 SOURCES = records|memory|wiki|entities; engine/loro/tests/run.js:300 asserts 'pages: evidence, inbox and mirrors are NEVER compiled (evidence is not truth)'; workspace architecture 4.4 'Governed evidence is not memory. Most items STOP at FILTER and remain evidence forever'. Separately: synthesis.js:151 says 'the CORE applies it (writes promoted candidates / feeds entities)' but core.js never does - ingestOnce returns candidates in its summary and commands.js only prints the counts (lib/workspace/commands.js:465-466). So nothing has ever written a promoted Workspace record.

## Proceeding meanwhile

Building the missing 4.4-step-4 promotion pass (calendar event skeleton + 4.5 entity feed) as a new file plus the Rust read-path provenance fix, with a three-question end-to-end proof. Drive documents and mail metadata are honestly out of reach without the ruling above.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T012707Z-5653b4ae`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T012707Z-5653b4ae --disposition "<what you decided or did>"
