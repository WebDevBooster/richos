# RichOS desktop app (`app/`)

The purpose-built, CEO-facing RichOS front-end — a **Tauri** desktop app (Rust core +
web UI), local-first, single-machine, **no relay**. Built to the system architecture:

- The front-end architecture plan, 2026-08-24 (Tauri; RichOS as the ACP
  client directly; drop the Nostr relay + its ACP shim; P1 = the runtime spine).
- The session-continuity design, 2026-08-24 (the durable Rich is the APP;
  the ACP session is a swappable compute lease; the ledger is the spine's backbone).
- The RichOS front-end notes (v1 CEO-only / single-machine / no-relay; BYO-Anthropic;
  Rich-organized topic threads over one shared ledger/loro).

This scaffold delivers **front-end Phase 1.1–1.2 + the P1.4 continuity FOUNDATION**:
a working "talk to Rich" loop through the real ACP path, a crash-safe conversation +
action ledger, a multi-thread data model, and the re-prime seam.

## Why `app/` (not `tools/`)

`tools/` holds supporting utilities (the extension, the transcription service, the
dictation HUD). This is the **primary product delivery surface** — the system architecture
calls it "the RichOS DESKTOP APP," a peer of `engine/` and `loro/`, not a tool. So it
lives at the repo root as `app/`.

## Layout

```
app/
  Cargo.toml                 workspace: member = crates/richos-core ONLY (fast, native-dep-free)
  crates/richos-core/        the runtime SPINE — UI-agnostic, fully unit-tested
    src/acp.rs               ACP client (ndjson JSON-RPC to claude-agent-acp; relay dropped)
    src/ledger.rs            append-only conversation + action ledger (crash-safe)
    src/thread.rs            topic threads as VIEWS over the one shared ledger
    src/reprime.rs           re-prime payload (continuity foundation)
    src/cognition.rs         the swappable compute-lease trait (+ MockCognition)
    src/spine.rs             queue-not-interrupt + turn-boundary + re-prime seam
    examples/acp_roundtrip.rs  headless proof of the real ACP round-trip
    tests/spine_tests.rs     8 spine invariant tests (no live Claude needed)
  src-tauri/                 the Tauri shell — DETACHED nested workspace (empty [workspace])
    src/main.rs              window + Tauri command bridge to the spine
    tauri.conf.json, capabilities/, icons/
  ui/                        minimal web UI (thread list + messages + composer)
  scratch-acp/               ACP protocol probe (probe.js) — repro for the wire shape
```

`src-tauri/` is a **deliberately detached** nested workspace so the heavy webview
dependency tree never gates `cargo test -p richos-core`. richos-core is a path
dependency, so the shell always builds against the same spine.

## Build & test

```sh
# 1. The spine — fast, no native deps, no network, no Claude:
cargo test -p richos-core                       # 8/8 green

# 2. The desktop shell (from app/src-tauri/):
cargo build                                     # -> target/debug/richos-tauri (Mach-O)

# 3. The LIVE ACP round-trip (needs `claude` CLI signed in; adapter under scratch-acp/):
#    installs once:  (cd scratch-acp && npm i @agentclientprotocol/claude-agent-acp)
RICHOS_ACP_BIN="$PWD/scratch-acp/node_modules/.bin/claude-agent-acp" \
  cargo run -p richos-core --example acp_roundtrip -- "$PWD/../engine" "who are you?"
```

## Runtime config (env)

- `RICHOS_ENGINE_DIR` — the engine repo used as the ACP session `cwd` (persona + hooks).
  Defaults to the `engine/` sibling of `app/`.
- `RICHOS_ACP_BIN` — path to the `claude-agent-acp` adapter binary. Defaults to
  `node_modules/.bin/claude-agent-acp` under the launch dir, else bare name on PATH.
- `RICHOS_ACP_DEBUG` — if set, adapter stderr is echoed (developer machinery only;
  never reaches the CEO view).

## What is proven vs pending

**Proven (live, 2026-08-24):** the ACP round-trip through the full spine — CEO prompt
persisted crash-safe → re-prime identity injected → real Claude replies **as Rich** →
clean render. The Tauri shell builds into a real arm64 binary. 8/8 spine tests green.

**Foundation only / later legs:** turn-boundary rotation on a context watermark,
self-authored handoff summaries, mid-turn-crash replay wiring, the loro context
compiler (Tier C degrades to ledger-only + on-demand fetch today), voice/Jam,
proactive attention seam, streaming deltas to the UI via Tauri events, packaging
(signed/notarized bundles, bundled Node + adapter + whisper). See the feasibility notes
in the handoff.
