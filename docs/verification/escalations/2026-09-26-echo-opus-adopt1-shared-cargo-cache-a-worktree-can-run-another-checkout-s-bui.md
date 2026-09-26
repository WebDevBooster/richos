# Escalation: Shared Cargo cache: a worktree can run ANOTHER checkout's build of richos-core/richos-tauri (freshness is mtime-only, not per-path)

- id: `esc-20260926T113721Z-70ef679e`
- raised: 2026-09-26T11:37:21Z
- from: echo-opus-adopt1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-adopt1` (branch `cc/echo-opus-adopt1`)
- head: `e79659fefb1dd6ac35429248a6324488a72c20a9`
- state: **proceeding**
- for: lead

## The question

Should the shared build cache stop sharing the workspace-member crates (richos-core in richos/app, richos-tauri in src-tauri) across checkouts, for example a per-checkout target for members or checksum freshness, given that any agent's cargo test can currently execute a different branch's code?

## What was already tried

Measured 11:34Z in cc/echo-opus-adopt1: my mutation harness built a mutant of spine.rs in an exported copy at another path sharing /Volumes/E1TB/caches/cargo-target/richos-app-workspace; then cargo test -p richos-core --test ended_turn_tests -v in my worktree printed Fresh richos-core and ran target/debug/deps/ended_turn_tests-645200d21a9e0d6e, which FAILED with the mutant behavior while my source was unmutated. Cargo names the file relatively (the file crates/richos-core/src/spine.rs has changed): workspace members are keyed relative to the workspace root and judged fresh by mtime, so a checkout whose files are older than another checkout's build runs that build. shared-build-cache.sh lines 63-64 say members carry the manifest path in their fingerprint so each checkout keeps its own; measured false for members (true only for richos-core as an out-of-workspace path dependency of src-tauri, which rebuilt with an absolute path).

## Proceeding meanwhile

Repaired what I contaminated (touched my sources, rebuilt both artifacts from real code at about 11:37Z; mutant binaries sat in the shared cache about 11:25-11:37Z). Moving my mutation harness and my proof run to a private CARGO_TARGET_DIR. Continuing the task.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260926T113721Z-70ef679e`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260926T113721Z-70ef679e --disposition "<what you decided or did>"
