# Escalation: The spine suite now REQUIRES a claude on macOS — the price of killing the signature test's silent skip

- id: `esc-20260905T155107Z-d40469f7`
- raised: 2026-09-05T15:51:08Z
- from: echo-opus-sig
- worktree: `/Users/alex/ab/richos-wt/echo-opus-sig` (branch `echo-opus-sig`)
- head: `9c967df43bcb5d5dabc31fcfac4af2594910a3e8`
- state: **work-complete**
- for: lead

## The question

Is a Mac without Claude Code getting one RED test in cargo test -p richos-core acceptable on a public repository, or should absence there report not-run instead?

## What was already tried

The richos-voice precedent (build.rs turning a run-time condition into a cfg so the test reports ignored) was measured and rejected for this crate: adding one cargo::rustc-cfg line to crates/richos-core/build.rs changed the release library bytes, librichos_core.rlib c3f2d079 -> e8b810c7 and back on removal. A machine probe there would make a crate that ships inside the signed .app compile differently depending on whether the BUILD machine had Claude Code — a real cost against docs/verification/reproducible-rust-builds-2026-09-04 and against that build.rs's own header. libtest has no run-time not-run report, so on macOS the only honest options were a hard failure or the silent ok that was the defect.

## Proceeding meanwhile

Both instances fixed and proven both ways; app/README.md 683 no longer claims 'no Claude' and app-spine-ci.yml now names the test it never performed. 966/0/6 default and 970/0/2 with RICHOS_VOICE_LIVE_AUDIO=1, unchanged from baseline.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260905T155107Z-d40469f7`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260905T155107Z-d40469f7 --disposition "<what you decided or did>"
