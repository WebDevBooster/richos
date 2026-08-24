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
  Cargo.toml                 workspace: richos-core (fast, native-dep-free) + richos-voice
  crates/richos-core/        the runtime SPINE — UI-agnostic, fully unit-tested
    src/acp.rs               ACP client (ndjson JSON-RPC to claude-agent-acp; relay dropped)
    src/ledger.rs            append-only conversation + action ledger (crash-safe)
    src/thread.rs            topic threads as VIEWS over the one shared ledger
    src/reprime.rs           re-prime payload + the LoroContextCompiler Tier-C seam contract
    src/cognition.rs         the swappable compute-lease trait (+ MockCognition), LeaseFactory
    src/stream.rs            live UI-facing turn events (streaming deltas + turn/proactive state)
    src/spine.rs             queue-not-interrupt + turn-boundary rotation + crash recovery +
                              the proactive-attention seam
    src/config.rs            durable CEO preferences: company_name, the assertiveness dial
    src/worker_status.rs     the optional AI-worker drill-down (reads the engine's event logs)
    examples/acp_roundtrip.rs      headless proof of the real ACP round-trip
    examples/rotation_roundtrip.rs headless proof of rotation against the real ACP adapter
    tests/spine_tests.rs     12 spine invariant tests (no live Claude needed)
    tests/rotation_tests.rs  12 rotation/crash-recovery/proactive-seam tests
    tests/action_ledger_tests.rs 14 action-ledger WRITER tests (the ledger is non-empty
                              at runtime; CEO-facing actions cross a rotation; machinery
                              stays out of every priming prompt)
  crates/richos-voice/       VOICE MODE — mic -> whisper -> the spine -> TTS -> speakers
    src/vad.rs               RMS VAD + THE FRAME MATH (16000 Hz, 256-sample frames = 16.000 ms)
    src/bargein.rs           313-frame (5.008 s) debounce + the EchoGate AEC seam (v1: none)
    src/endpoint.rs          utterance start/end, pre-roll ring, cough filter, 30.000 s cut
    src/noaudio.rs           post-open silent input: 188 frames (3.008 s) under -80.00 dBFS
    src/chunk.rs             streaming sentence chunker + clean output FOR THE EAR
    src/state.rs             the voice-mode state machine (mic state is never a guess)
    src/wav.rs               hand-rolled PCM16 WAV codec + rate conversion
    src/event.rs             rich://voice-state (incl. noAudio) | voice-transcript | voice-error
    src/{capture,playout}.rs cpal in/out; playout is one continuous, interruptible stream
    src/{stt,tts}.rs         local whisper.cpp (small.en) / macOS `say` behind a trait
    src/controller.rs        four threads, CaptureBrain, the half-duplex taint rule
    tests/barge_in_composition.rs  the WIRING: echo defence + real interruptions
    examples/voice_loop.rs   the reproducible end-to-end proof (audio -> Claude -> speakers)
    examples/device_probe.rs what the audio hardware on THIS machine actually reports
    examples/noaudio_live.rs live mute/unmute check on the real device (PASS 2026-08-24)
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
cargo test -p richos-core                       # 51/51 green

# 1b. Voice mode — pure logic + the native edges (no mic needed):
cargo test -p richos-voice                      # 121/121 green
RICHOS_VOICE_LIVE_AUDIO=1 cargo test -p richos-voice   # + the audible live tests
cargo run -p richos-voice --example device_probe       # what the audio hardware really is

# 2. The desktop shell (from app/src-tauri/):
cargo build                                     # -> target/debug/richos-tauri (Mach-O)

# 3. The LIVE ACP round-trip (needs `claude` CLI signed in; adapter under scratch-acp/):
#    installs once:  (cd scratch-acp && npm i @agentclientprotocol/claude-agent-acp)
RICHOS_ACP_BIN="$PWD/scratch-acp/node_modules/.bin/claude-agent-acp" \
  cargo run -p richos-core --example acp_roundtrip -- "$PWD/../engine" "who are you?"

# 4. The WHOLE voice loop (needs the adapter above; a WAV stands in for the mic on a
#    machine with no input device):
say -v Samantha -o /tmp/ceo.wav --data-format=LEI16@16000 "Rich, are you there?"
cargo run -p richos-voice --example voice_loop -- /tmp/ceo.wav
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
clean render. The Tauri shell builds into a real arm64 binary. 11/11 spine tests green.

**Streaming (2026-08-24):** Rich's reply deltas now stream **live** to the UI via Tauri
events (`rich://turn-started` → `rich://chunk`… → `rich://turn-completed`/`rich://turn-error`),
so the UI renders token-by-token and shows a calm "Rich is working" state. Each delta is
appended to the durable ledger FIRST, then emitted — the ledger stays the source of truth,
crash-safety intact. **The full event contract for the UI is in `app/STREAMING.md`** (the UI
builds against it without reading Rust). Clean output preserved: only assistant text is
ever emitted.

**P1.4 continuity, landed (2026-08-24):** turn-boundary rotation (context-watermark +
explicit triggers), self-authored handoff summaries on clean rotation, mid-turn-crash
recovery/replay (bounded to one attempt, clean-render dedup via superseded turns), and the
identity/action-ledger re-prime that structurally excludes false attribution — all wired
in `richos-core::spine` (`LeaseFactory`, `rotate_lease`, `recover_and_replay`) and proven
both headless (`cargo test -p richos-core`, `tests/rotation_tests.rs`, 12 tests) and live
against the real ACP adapter (`examples/rotation_roundtrip.rs` — a forced mid-conversation
rotation swaps the backing Claude session and the successor correctly recalls the prior
exchange purely via the re-prime payload). Company name, the assertiveness dial, and the
worker-status drill-down are also wired end-to-end (Tauri commands → `app/ui/main.js`).
Full detail + the honest gaps (loro Tier-C compiler still a seam contract, not built; no
attention-seam TRIGGER yet — only the persistence + UI-event seam) are in
the spine-seams + rotation brief, 2026-08-24.

**Voice mode (2026-08-24):** the `◉` toggle is real. Mic -> VAD -> local whisper.cpp
(`small.en`) -> the SAME `Spine::submit_prompt` typed text uses (`Source::Jam`, one thread,
one ledger) -> Rich's streamed reply -> sentence-pipelined macOS `say` -> one continuous,
interruptible cpal stream. Barge-in carries the pilot's 5.008 s debounce (313 frames), plus
an instant "tap to stop". **Proven live end to end on this Mac** — real whisper, real Claude,
real speakers — EXCEPT the microphone driver itself: this host has **no input device at all**
(three output-only devices; CoreAudio `'!obj'`). **No AEC**: the interim is the debounce, a
half-duplex taint rule, and "headphones recommended"; the `EchoGate` seam is wired and already
carrying the live reference signal. **No live partial transcript** (whisper-cli has no
partial-hypothesis stream) — a visible deviation from the UX direction §4.1 sketch. Full measurements,
gaps and packaging requirements: the voice-pipeline brief, 2026-08-24.

**Foundation only / later legs:** the loro Tier-C WIRING (the compiler itself now exists
in `loro/` with a versioned `CONTEXT-CONTRACT.md`; `LoroContextCompiler` in `reprime.rs` is
still an unwired trait seam), the attention-seam TRIGGER (timers/log-watchers that decide
WHEN to raise a proactive message — `Spine::raise_proactive` is the seam, judgment is not),
worker-status upstream signal (the reader is real; nothing emits worker activity yet), real
AEC, a live partial transcript, a warm whisper daemon, a Windows `SpeechSynth`, and
packaging (signed/notarized bundles, bundled Node + adapter + whisper + models — see the
voice brief's size table). See the feasibility notes in the handoffs.
