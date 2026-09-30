# Escalation: sccache exits 254 compiling registry crates into a fresh workspace's Cargo target; every Rust check there fails

- id: `esc-20260930T212325Z-be13d59a`
- raised: 2026-09-30T21:23:25Z
- from: zach-opus-gate1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-gate1` (branch `cc/zach-opus-gate1`)
- head: `07d289da82f3ac876a0126f201ce7b99cc698c2d`
- state: **work-complete**
- for: lead

## The question

Who owns the sccache setup (RUSTC_WRAPPER=/Volumes/E1TB/tools/sccache/v0.18.0/sccache from lib/cargo-cache-env.sh)? In workspace cc/zach-opus-gate1 on 2026-09-30 around 22:10 local, every Rust build failed in 1-4 s with 'could not compile cfg-if / typenum / unicode-ident / version_check ... (exit status: 254)' and no message: twice in the commit check's Clippy fast set and once in 11 Rust checks of a replayed land. The same land with RUSTC_WRAPPER=/usr/bin/env (sccache bypassed) compiled and ran: 15 of 16 checks passed. A one-file rustc through the same sccache from a plain shell succeeded, so it is not sccache being absent.

## What was already tried

Retried the commit check once after reading its log (same failure); ran the replay with RUSTC_WRAPPER=/usr/bin/env, which works. Did not change any sccache or cargo configuration: not in this brief.

## Proceeding meanwhile

The merge-gate work is complete; the app replay's measured numbers come from the run with sccache bypassed, and the report says so. Target directory seen: /Volumes/E1TB/caches/cargo-target/workspaces/a42c7591debb99730903b010.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260930T212325Z-be13d59a`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260930T212325Z-be13d59a --disposition "<what you decided or did>"
