# Escalation: Section 07 fix: UI suites have no declared inputs, so under proof-run an unrelated edit still invalidates their pass (by design of WHOLE_CHECKOUT)

- id: `esc-20260929T223855Z-692452e3`
- raised: 2026-09-29T22:38:55Z
- from: tom-opus-tree1
- worktree: `/Users/alex/ab/richos-wt/tom-opus-tree1` (branch `cc/tom-opus-tree1`)
- head: `b45c9cf3b2a580ccb5e841bb88c06800c35e2924`
- state: **proceeding**
- for: lead

## The question

The brief says an unrelated save discards passes 'even though those checks' inputs never changed'. That is true for the 61 checks with a reviewed contract in richos/app/scripts/proof-inputs.json, but not for UI suites: none has a contract, so proof-run keys each one by the WHOLE checkout (proof_evidence.WHOLE_CHECKOUT, proof-run.py input_identity). For a UI suite every tracked file is a declared input. An honest shared read set for the UI suites is close to the whole repo (they read richos/app/ui, src-tauri, crates, richos/web/web-app via no-home-network.js and the realbytes cargo build, richos/engine/voice/models via include_str, root docs/, richos/tools). A narrower set needs a per-suite read declaration for about 55 suites (a reviewed contract each, roughly 5 min per suite plus about 150 lines of mechanism). Do you want that commissioned as a follow-up, or is 'a UI suite is invalidated and re-run on any change, but never failed and never stops other checks' the accepted end state?

## What was already tried

Read tracked-tree.js, harness.js, proof-run.py, proof_evidence.py, proof-inputs.json, the qualification file, and grepped every UI suite for reads outside ui/. Checked whether proof-for.sh's map could serve as a read set: it cannot, because it maps Rust changes to cargo tests only, while splash.js and others read main.rs.

## Proceeding meanwhile

Building what does not depend on the answer: (1) the harness write guard watches only richos/app/ui, which still catches a suite writing a tracked file, so an edit elsewhere no longer FAILS a UI suite; (2) proof-run drops the whole-checkout stop-everything and invalidation. Each check is judged by its own identity. A HEAD move still contaminates the whole run. A fresh check with no identity is still bound to the whole source. Contracted checks keep their passes and nothing else is stopped.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260929T223855Z-692452e3`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260929T223855Z-692452e3 --disposition "<what you decided or did>"
