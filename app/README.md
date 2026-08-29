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
    src/entity.rs            the ENTITY scope + privacy boundary (ECS §3.2-3.4): validated
                              entity ids, the four-area registry, fail-closed repository-root
                              resolution, and the IMMUTABLE ThreadBinding (private fields,
                              crate-private constructor — obtainable only from the ledger)
    src/ledger.rs            append-only conversation + action ledger (crash-safe), now
                              entity-scoped: every thread has one immutable home entity,
                              every turn carries it, and no event from one entity can render
                              in another entity's thread; each assistant delta now persists
                              its shared-sequence position, so a turn's text RUNS (and the
                              tool calls between them) survive a restart
    src/thread.rs            topic threads as VIEWS over the one shared ledger, within an entity
    src/timeline.rs          the TYPED TIMELINE (UX §12): the TimelineItem union projected from
                              the ledger + the machinery journal, entity scope on every record,
                              and visibility as a GATE (Timeline is not Serialize; the only
                              path to a webview is view(mode), which drops what the mode may
                              not see and removes the technical detail it may not read)
    src/reprime.rs           re-prime payload + the LoroContextCompiler Tier-C seam contract
    src/cognition.rs         the swappable compute-lease trait (+ MockCognition), LeaseFactory
    src/stream.rs            live UI-facing turn events (streaming deltas + turn/proactive state)
    src/machinery.rs         the SECOND event family: every non-text ACP update, routed not
                              dropped, normalized + merged by toolCallId (rich://machinery)
    src/journal.rs           the machinery JOURNAL — separate store, per-thread, day-sharded,
                              Tier A never evicted / Tier B a rolling raw window
    src/spine.rs             queue-not-interrupt + turn-boundary rotation + crash recovery +
                              the proactive-attention seam
    src/config.rs            durable CEO preferences: company_name, the assertiveness dial
    src/worker_status.rs     the optional AI-worker drill-down (reads the engine's event logs)
    examples/acp_roundtrip.rs      headless proof of the real ACP round-trip
    examples/rotation_roundtrip.rs headless proof of rotation against the real ACP adapter
    tests/entity_binding_tests.rs 10 entity-scope tests: the cross-entity leak NEGATIVE
                              CONTROL (proven failing with the guard removed), immutability,
                              the fail-closed unbound legacy thread + its one-way explicit
                              adoption, the activation fence, and restart
    tests/spine_tests.rs     12 spine invariant tests (no live Claude needed)
    tests/rotation_tests.rs  12 rotation/crash-recovery/proactive-seam tests
    tests/action_ledger_tests.rs 15 action-ledger WRITER tests (the ledger is non-empty
                              at runtime; CEO-facing actions cross a rotation; machinery
                              stays out of every priming prompt)
    tests/machinery_tests.rs 14 machinery routing/retention tests, driven by ACP wire
                              shapes actually measured against the adapter
    tests/timeline_tests.rs  7 typed-timeline tests: the cross-entity machinery NEGATIVE
                              CONTROL (both clauses proven failing when removed — one leaks
                              a row, one leaks THROUGH the toolCallId merge), the one shared
                              per-turn sequence live and after a restart, the visibility
                              gate, and the items that are never invented
    examples/machinery_roundtrip.rs headless proof that machinery is routed AND retained
                              end to end against the real adapter (the run is kept at
                              docs/verification/machinery-roundtrip-2026-08-28.txt)
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
  acp-adapter/               hosts the claude-agent-acp adapter + probe.js (wire-shape repro)
```

`src-tauri/` is a **deliberately detached** nested workspace so the heavy webview
dependency tree never gates `cargo test -p richos-core`. richos-core is a path
dependency, so the shell always builds against the same spine.

## Machinery routing (techy mode, Phase 1 — routing + retention only)

Every non-text ACP update is now **routed**, not dropped, into a second event family
(`rich://machinery`) and retained in a separate per-thread journal at
`<app-data>/machinery/<thread_id>/<YYYY-MM-DD>.jsonl`. Contract:
`docs/plans/richos-techy-mode-2026-08-26.md`. UI contract: `app/STREAMING.md`.

**Retention is unconditional and has no setting** — that is what makes it possible to turn
the technical view on for a conversation that already happened.

Three limits, stated rather than discovered later:

1. **Retroactivity begins at the routing commit.** A thread that ran before it has no
   machinery at all, and the honest state is *"nothing was recorded for this
   conversation."* Nothing earlier is recoverable, ever.
2. **`agent_thought_chunk` produces nothing today.** Measured across five probe runs of
   `claude-agent-acp` 0.70.0, including one built solely to elicit it: zero. The adapter
   guards the update on non-empty thinking text, and recent models omit it
   (`docs/verification/acp-emission-probe-2026-08-28.md` §4.1). The route exists so there
   is no hole the day that changes; there is no thought data to render right now.
3. **Between-turn updates are still dropped.** One `available_commands_update` at session
   start and one `session_info_update` after each turn ends reach no sink, because the
   client only delivers updates while a prompt is in flight. §1.5 designs the fix; it is
   Phase 2.

Not built here, deliberately: the per-thread toggle, `techy_default`, any renderer, and any
control whatsoever. Techy mode is a window, not a cockpit.

## Build & test

```sh
# 1. The spine — fast, no native deps, no network, no Claude:
cargo test -p richos-core                       # 97/97 green

# 1b. Voice mode — pure logic + the native edges (no mic needed):
cargo test -p richos-voice                      # 121/121 green
RICHOS_VOICE_LIVE_AUDIO=1 cargo test -p richos-voice   # + the audible live tests
cargo run -p richos-voice --example device_probe       # what the audio hardware really is

# 2. The desktop shell (from app/src-tauri/):
cargo build                                     # -> target/debug/richos-tauri (Mach-O)

# 3. The LIVE ACP round-trip (needs `claude` CLI signed in; adapter under acp-adapter/):
#    installs once:  (cd acp-adapter && npm i @agentclientprotocol/claude-agent-acp)
RICHOS_ACP_BIN="$PWD/acp-adapter/node_modules/.bin/claude-agent-acp" \
  cargo run -p richos-core --example acp_roundtrip -- "$PWD/../engine" "who are you?"

# 3b. The LIVE machinery proof — the same chain, but showing that tool calls are ROUTED
#     and RETAINED: the calm view, the interleaved (turn, seq) stream, the merged rows,
#     and the journal files on disk. Leaves the journal in place and prints its path.
RICHOS_ACP_BIN="$PWD/acp-adapter/node_modules/.bin/claude-agent-acp" \
  cargo run -p richos-core --example machinery_roundtrip -- "$PWD/../engine"

# 4. The WHOLE voice loop (needs the adapter above; a WAV stands in for the mic on a
#    machine with no input device):
say -v Samantha -o /tmp/ceo.wav --data-format=LEI16@16000 "Rich, are you there?"
cargo run -p richos-voice --example voice_loop -- /tmp/ceo.wav
```

## App icon — pipeline exists, source art does not (BLOCKED)

The build warns while the icons are still placeholders and does not fail, so app
development is never blocked on artwork. Bundling and CI set
`RICHOS_REQUIRE_REAL_ICONS=1`, which turns the same check fatal — a release must
not ship a placeholder icon.

`src-tauri/icons/` currently holds four **placeholder** files (`32x32.png`, `128x128.png`,
`[email protected]`, `icon.png`) — all four are byte-identical, and all four are internally a
512x512 PNG regardless of what their filename claims. `src-tauri/build.rs` checks for this on
every build (dimension check + cross-file identity check; see its doc comment for the exact
defect it was written against) and WARNS, so compilation is never blocked on artwork. Under
`RICHOS_REQUIRE_REAL_ICONS=1` — which bundling and CI set — the same check is fatal, because
a release must not ship a placeholder. Tauri does not resize a bundle icon to fit its
declared filename: a mis-sized file ships exactly as supplied.

**What Tauri (v2.11.5 desktop app / tauri-build 2.6.3, pinned `"2"` in `Cargo.toml`)
actually requires**, per the v2 docs:
- `tauri.conf.json`'s `bundle.icon` array must list, at minimum, the set `tauri icon`
  generates: `icons/32x32.png`, `icons/128x128.png`, `[email protected]` (256x256px — the
  "@2x" of 128), `icons/icon.png` (512x512px), plus `icons/icon.icns` for macOS and
  `icons/icon.ico` for Windows
  ([App Icons](https://v2.tauri.app/develop/icons/),
  [Configuration Files](https://v2.tauri.app/develop/configuration-files/)). This repo's
  `tauri.conf.json` now lists all six.
- `icon.ico` (Windows) must contain layers for 16, 24, 32, 48, 64 and 256px
  ([Tauri v1 Icons guide](https://v1.tauri.app/v1/guides/features/icons/), format
  unchanged in v2).
- `icon.icns` (macOS) must contain the 10 named/sized layers in the Tauri repo's
  `icns.json` (`is32`/16, `ic11`/32, `il32`/32, `ic12`/64, `ic07`/128, `ic13`/256,
  `ic08`/256, `ic14`/512, `ic09`/512, `ic10`/1024 —
  [tauri-apps/tauri `helpers/icns.json`](https://github.com/tauri-apps/tauri/blob/dev/crates/tauri-cli/src/helpers/icns.json)).
  The `ic10` layer is 1024x1024px, which is why the source must be at least that large —
  anything smaller forces an upscale for that one layer.
- The `tauri icon` CLI subcommand
  ([CLI reference](https://v2.tauri.app/reference/cli/)) takes "a squared PNG or SVG file
  with transparency" (default `./app-icon.png`) and generates the whole platform set —
  desktop PNGs, `icon.icns`, `icon.ico`, plus iOS/Android sets if those targets are ever
  enabled. The Tauri v1 docs state the source concretely: **"png, 1024x1024px with
  transparency"** — i.e. exactly the resolution the `icns.json` `ic10` layer needs, with
  no upscaling.

**Generation step, once a real source image exists** (not run yet — no source art is
checked into this public repo; verified locally there is no `.svg`/`.icns`/`.ico` anywhere
under `app/`):

```sh
cargo install tauri-cli --version "^2" --locked   # once
cd app/src-tauri
cargo tauri icon /path/to/a-1024x1024-square-source.png
```

This overwrites everything under `src-tauri/icons/` with a real, correctly-sized,
non-placeholder set (including `icon.icns` and `icon.ico`), at which point
`check_icons_are_not_placeholders()` in `build.rs` passes and `cargo build` proceeds
normally — verified locally by swapping in real (correctly-sized, distinct) test renders
and confirming the same build command that fails today succeeds unchanged.

**What the CEO needs to hand over, in one line:** a single square PNG or SVG, **at least
1024x1024px**, with a **transparent background**, with no baked-in padding/rounding (macOS
and Windows both apply their own corner/shape treatment at bundle time) — that one file is
the only missing input; the config, the generation command, and the build-time guard
against shipping placeholders again are all already in place.

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

**Machinery routing + retention, landed (2026-08-28):** every non-text ACP update is now
routed into a second event family (`rich://machinery`) and retained in a separate
per-thread, day-sharded journal, on ONE per-turn `seq` shared with the assistant text so
"he said X, then ran Y, then said Z" is reconstructible. Proven headless
(`tests/machinery_tests.rs`, 14 tests, driven by wire shapes measured against the real
adapter) and live (`examples/machinery_roundtrip.rs` — one real tool-using turn, 24 journal
lines projecting to 9 rows, positions 0..=34 used exactly once across both families; the run
is kept at `docs/verification/machinery-roundtrip-2026-08-28.txt`). The emission set the
routing is built against was measured first, not assumed:
`docs/verification/acp-emission-probe-2026-08-28.md`. Honest gaps: **retroactivity starts
here and nothing earlier is recoverable**; `agent_thought_chunk` currently produces no data
at all on `claude-agent-acp` 0.70.0; between-turn updates are still unrouted (Phase 2); and
there is no toggle, no renderer and no controls — that is the rest of Phase 1 and it is
deliberately not in this work.

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
