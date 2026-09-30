# Escalation: Shared cargo cache: a checkout can run ANOTHER checkout's richos-core test binary without recompiling

- id: `esc-20260930T075357Z-cd63713e`
- raised: 2026-09-30T07:53:57Z
- from: echo-opus-assign1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-assign1` (branch `cc/echo-opus-assign1`)
- head: `27ece8fec17e69515cdda55a82d938a35685c74b`
- state: **proceeding**
- for: lead

## The question

Should the shared build cache (scripts/shared-build-cache.sh, one target dir for every checkout) be changed so a test run can never reuse a richos-core binary built from a different checkout's sources? Measured below; the owner of that script should decide the fix.

## What was already tried

Measured on 2026-09-30 while proving hunt part 1 fixes. Every checkout builds richos-core into /Volumes/E1TB/caches/cargo-target/richos-app-workspace, and Cargo gives the path package the same artifact name from every checkout (richos_core-debd0f2fb904aeff in both runs below) and judges freshness by file mtimes against dep-info paths relative to the package. Step 1: a copy of main 4d046f26 plus my new tests in /Volumes/E1TB/tmp/claude/echo-opus-assign1/redtree built at about 07:50Z (log line: Compiling richos-core v0.1.0 (/Volumes/E1TB/tmp/.../redtree/...)). Step 2: in my worktree /Users/alex/ab/richos-wt/echo-opus-assign1 (branch cc/echo-opus-assign1 at 27ece8fe, sources last edited before 07:50Z) `cargo test -p richos-core --lib` printed NO Compiling line, Finished in 0.05s, ran richos_core-debd0f2fb904aeff and reported main's failures at main's line numbers: it executed the other checkout's build. Touching my four source files forced a rebuild and the same suite then passed 160/160. So any worktree, or the main checkout at a land check, whose richos-core sources are older than another checkout's latest build can run that other build and report its result as its own proof.

## Proceeding meanwhile

My four fixes are committed and proven with a forced rebuild (touch, then the suite shows Compiling richos-core from my own path). I am finishing my report and deleting my scratch copy now.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260930T075357Z-cd63713e`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260930T075357Z-cd63713e --disposition "<what you decided or did>"
