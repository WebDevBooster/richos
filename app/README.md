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
    src/loro.rs              the Tier-C seam IMPLEMENTED: compile a slice, re-assert its lane
    src/correction.rs        the loro WRITE loop: propose, ASK the CEO, then write
    src/cognition.rs         the swappable compute-lease trait (+ MockCognition), LeaseFactory
    src/stream.rs            live UI-facing turn events (streaming deltas + turn/proactive state)
    src/machinery.rs         the SECOND event family: every non-text ACP update, routed not
                              dropped, normalized + merged by toolCallId (rich://machinery)
    src/journal.rs           the machinery JOURNAL — separate store, per-thread, day-sharded,
                              Tier A never evicted / Tier B a rolling raw window
    src/steering.rs          the CEO's two MID-TURN controls (UX §9.2/§9.3): an append-only
                              intake log the stop/steer commands can write to WITHOUT the
                              spine lock (which a running turn holds for its whole length),
                              plus the lease cancel seam. Not a second source of truth —
                              every record either becomes a ledger event or is refused
    src/spine.rs             queue-not-interrupt + turn-boundary rotation + crash recovery +
                              the proactive-attention seam + stop settlement at the boundary
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
    tests/steering_tests.rs  11 stop/steer tests (UX §9.2/§9.3). Includes the CONCURRENCY
                              proof: the spine goes behind an Arc<Mutex<..>> exactly as the
                              Tauri shell holds it, a real turn runs on one thread, and the
                              test asserts try_lock FAILS at the instant the stop is pressed
                              — so it cannot silently start passing for the wrong reason.
                              Also: a turn the CEO stopped is never crash-replayed, and a
                              stop request that outlived the process is applied at startup
    tests/acp_cancel_tests.rs 3 session/cancel tests against a REAL CHILD PROCESS over real
                              stdio (a POSIX-sh fake adapter the test writes itself), in two
                              variants: compliant, and deliberately deaf to session/cancel
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
    src/bargein.rs           313-frame (5.008 s) fallback debounce; 15-of-25 (0.400 s) window
                              once the canceller has EARNED it; the EchoGate seam
    src/aec.rs               ACOUSTIC ECHO CANCELLATION — 2048-tap PBFDAF (128.0 ms tail),
                              lock-free reference ring, envelope delay estimator.
                              28.0 dB ERLE on a linear path; ~5.5 dB is all ANY linear
                              canceller can reach on this host's speakers+Elgato (measured)
    src/fft.rs               512-point radix-2 FFT, hand-rolled (licence: no vendored crate)
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
    src/nav.rs               durable rail VIEW state: width, pin, rename, archive (not evidence)
    tauri.conf.json, capabilities/, icons/
  ui/                        minimal web UI (entity/thread rail + messages + composer)
  acp-adapter/               hosts the claude-agent-acp adapter + probe.js (wire-shape repro)
```

`src-tauri/` is a **deliberately detached** nested workspace so the heavy webview
dependency tree never gates `cargo test -p richos-core`. richos-core is a path
dependency, so the shell always builds against the same spine.

## Entity and thread navigation (Codex-UX slice 4)

Contract: `richos-hq/docs/design/richos-codex-inspired-conversation-ux-2026-08-28.md` §3 and §25.

**Grouping happens in Rust, not in the renderer.** `navigation_tree` returns threads
already inside their entity's group, resolved through `Ledger::thread_binding` — the
accessor that reads the immutable durable record. An entity is a privacy boundary
(§1), so a renderer that bucketed a flat list by an `entity_id` string would be one
`if` away from a boundary violation with nothing to catch it. `app/ui/main.js` renders
the groups it is given and never re-sorts them, and the main-pane header renders from
`active_context` — the spine's binding — so a UI bug can show the wrong thread but
cannot mislabel which entity the CEO is talking to.

**A thread with no entity home is rendered, calmly, and refused.** A record written
before entity scoping replays as `ThreadEntity::Unbound`: listed under "Needs an
entity", never inside one, never activated, never read. The pane states the reason in
Rich's voice and the composer is disabled. `Ledger::adopt_unbound_thread` is the only
exit and is **not reachable from the shell** — `Spine` exposes `&Ledger`, not `&mut` —
so binding one remains a programmatic/back-office act until a core change lands.

**Rail status marks are never fabricated.** The full list, with the signal that earns
each, is `STATUS_MARKS` in `app/ui/main.js`. §3.2's *Queued* and *Waiting for CEO* are
absent because no per-thread enqueue event and no waiting signal exist in this build,
and §22 lists worker waiting state as something that must not be faked. No worker
count appears in the rail at all.

**Pin, rename and archive are shell state, not ledger events** (`src/nav.rs`). §25
requires them to work *without changing context authority*; the ledger is evidence and
has no rename/pin/archive event to append. A rename is therefore a display override
with the ledger title returned untouched beside it, and archiving changes which list a
thread appears in and nothing else about its scope.

## Machinery routing (techy mode, Phase 1 — routing + retention only)

Every non-text ACP update is now **routed**, not dropped, into a second event family
(`rich://machinery`) and retained in a separate per-thread journal at
`<app-data>/machinery/<thread_id>/<YYYY-MM-DD>.jsonl`. Contract:
`richos-hq/docs/plans/richos-techy-mode-2026-08-26.md`. UI contract: `app/STREAMING.md`.

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

## App icon — pipeline built and proven, source art does not exist (BLOCKED ON ARTWORK ONLY)

**CEO handover sheet: [`app/APP-ICON.md`](APP-ICON.md)** — what to supply, the one
command, and how he knows it worked. That file is the deliverable for open-items 3.12;
this section is the engineering detail behind it.

`src-tauri/icons/` holds four **placeholder** files (`32x32.png`, `128x128.png`,
`128x128@2x.png`, `icon.png`) — all four byte-identical, all four internally a 512x512
PNG regardless of what their filename claims. `icon.icns` and `icon.ico` do not exist at
all. So the app currently has **no icon at any size**.

### Generating the real set

```sh
app/scripts/generate-app-icons.sh /path/to/artwork.png
```

One square PNG of at least 1024x1024 with a transparent background in; every artefact
`tauri.conf.json` declares out, verified before the command exits. Source requirements
are enforced, not documented: wrong size, missing alpha, non-square, JPEG, blank and
full-bleed artwork are each rejected by name, all problems reported at once.

To re-check an existing set without regenerating:

```sh
python3 app/scripts/lib/app_icons.py verify
```

### Derived, never typed

Both the generator (`app/scripts/lib/app_icons.py`) and the build gate
(`src-tauri/build.rs`) derive the required artefact list from **`tauri.conf.json`'s own
`bundle.icon` array**. Neither contains a hand-typed list of filenames. Adding a size to
that array is picked up by both with no code change — proven by adding `icons/64x64.png`
and watching the gate warn and the generator emit it. An entry that cannot be decoded is
a hard failure, never a skip.

That rewrite fixed a real hole: the previous gate hand-typed four filenames while the
config declared six, so `icon.icns` and `icon.ico` — the only artefacts that carry the
icon on macOS and Windows — were never checked on any build.

### Warn on build, fatal on bundle

Deliberate, and load-bearing: app development must never be blocked on artwork nobody
has yet.

- `cargo check` / `cargo build` → **warnings only**, exit 0.
- `RICHOS_REQUIRE_REAL_ICONS=1` → **panics**, refuses to build.

**Nothing sets that variable yet.** Previous text here claimed it was "set by bundling
and CI"; it is not, because this repository has no bundling script and no CI job that
builds the app — `.github/workflows/` contains only `engine-self-verify.yml`. The
mechanism works and is proven in both directions, but the caller that would arm it does
not exist. **Whoever adds the packaging entrypoint must export
`RICHOS_REQUIRE_REAL_ICONS=1`**, or a bundle can still ship a placeholder icon.

Verified on the committed placeholder set: 12 warnings and `Finished dev profile` in the
first mode, a hard panic in the second, and — after a real generation run — strict mode
compiling clean with zero icon warnings.

### Tooling and licence

**Pillow, SPDX `MIT-CMU`** (read from the installed distribution's `License-Expression`
metadata, Pillow 12.3.0) for decode/resample/PNG/ICO, plus Apple's own
**`/usr/bin/iconutil`** for the macOS `.icns`. Both are **authoring-time only**: nothing
from either is linked into or shipped inside the signed `.app`, and the only artefacts
that ship are pixels derived from the supplied artwork. That keeps the licence question
entirely clear of the signing/notarisation path.

### What Tauri actually requires

(Tauri v2.11.5 desktop app / tauri-build 2.6.3, pinned `"2"` in `Cargo.toml`.)

- `tauri.conf.json`'s `bundle.icon` array is the source of truth and lists all six:
  `icons/32x32.png`, `icons/128x128.png`, `icons/128x128@2x.png` (256x256px — the "@2x"
  of 128), `icons/icon.png` (512x512px), `icons/icon.icns`, `icons/icon.ico`
  ([App Icons](https://v2.tauri.app/develop/icons/)).
- `icon.ico` (Windows) carries layers for 16, 24, 32, 48, 64 and 256px
  ([Tauri v1 Icons guide](https://v1.tauri.app/v1/guides/features/icons/), format
  unchanged in v2). Verified: `cargo tauri icon` 2.11.4 emits exactly that set.
- `icon.icns` (macOS) must cover pixel sizes **16, 32, 64, 128, 256, 512, 1024**.

  **Correction to what this section previously claimed.** It said the `.icns` "must
  contain the 10 named/sized layers" of Tauri's `helpers/icns.json`, including `is32`
  and `il32`. That describes what one generator emits, not what macOS requires. Measured
  here: `cargo tauri icon` 2.11.4 writes `is32`/`il32` (the pre-10.7 24-bit RLE variants
  with separate `s8mk`/`l8mk` masks) for 16/32px, while **Apple's own `iconutil` writes
  the ARGB `ic04`/`ic05` instead** and never emits `is32`/`il32` at all. Both cover the
  identical set of pixel sizes. So the checks require **pixel-size coverage, not a
  literal fourcc list** — requiring the fourccs would reject output from Apple's own
  tool, which would be a checker bug rather than an artwork problem.
- The 1024px `ic10` layer is why the source must be at least 1024x1024: anything smaller
  upscales for exactly the layer shown largest.

Coverage was verified against the authoritative tool rather than assumed. Installed
tauri-cli 2.11.4 and ran `cargo tauri icon` on a synthetic 1024x1024 source:

```
required ICNS sizes     : [16, 32, 64, 128, 256, 512, 1024]
cargo tauri icon 2.11.4 : [16, 32, 64, 128, 256, 512, 1024]
this pipeline (iconutil): [16, 32, 64, 128, 256, 512, 1024]
required ICO layers     : [16, 24, 32, 48, 64, 256]
cargo tauri icon 2.11.4 : [16, 24, 32, 48, 64, 256]
this pipeline (Pillow)  : [16, 24, 32, 48, 64, 256]
```

The verifier also accepts `cargo tauri icon`'s own unmodified output (exit 0), so it is
not over-fitted to this generator.

### Named degradation: off macOS

There is no `iconutil` outside macOS, so `.icns` falls back to Pillow's ICNS writer,
which emits **no 16px layer** (measured: `ic07 ic08 ic09 ic10 ic11 ic12 ic13 ic14`). The
fallback prints a warning saying exactly that and telling the caller to regenerate on
macOS before signing a release. It does not pretend to be equivalent, and the verifier
fails it — `icons/icon.icns is missing layer size(s) [16]px`.

### Fixed along the way

The `@2x` icon was literally named `[email protected]` on disk — Cloudflare
email-obfuscation mangling — and `tauri.conf.json` carried the same mangled string, so
config and file agreed with each other and nothing noticed. Every standard generator
emits `128x128@2x.png`, so the first real generation run would have written a file the
config was not looking for. Fixed in `ad017b8`; the mangled form is now rejected by the
derivation as an unsupported extension, so it cannot recur silently.

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
both headless (`cargo test -p richos-core`, `tests/rotation_tests.rs`, 22 tests) and live
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

**The rotation watermark reads the wire (2026-08-29):** the trigger that decides WHEN a
lease rotates is now the adapter's own `usage_update` `{used, size}`, consumed live off the
machinery stream in `deliver` — not from the journal, whose Tier B is evictable. Until a
lease has reported, the chars÷4 estimate remains as the FALLBACK, and `context_source()`
returns `Estimated` vs `Measured` so nothing can print a context number without being able
to say where it came from.

What it replaced was measurably wrong in both directions at once: a 200_000-token window
against `"size": 1000000` on all 50 usage events in the 2026-08-28 capture, fed by a
numerator counting prompt and reply characters only — no tool traffic at all. Live, on the
simplest possible exchange, that numerator read **602 tokens against a measured 31_310**
(`docs/verification/rotation-watermark-2026-08-29/live-run.txt`).

**The cadence change is material and goes both ways**, which is the argument for reading the
wire rather than tuning a constant. Recomputed from the raw capture on every `cargo test`
(`tests/watermark_cadence_tests.rs`): mixed traffic rotates 42 % MORE often (turn 328.2 →
189.5) and the old trigger sat 53.9 turns PAST the hard wall; low-tool traffic rotates 44 %
LESS often (turn 302.9 → 435.7); tool-heavy traffic — an orchestrator Rich's actual shape —
had the old trigger firing 5.86× too late (turn 493.0 against a wall at 84.1).

**Mid-turn is the failure this is aimed at, and the honest answer is written down rather
than implied.** A `usage_update` crossing 0.95 of the measured window DURING a turn does not
rotate: rotation mid-turn is structurally forbidden (continuity §3.1) and a mid-turn
rotation is worse than a late one. It records the crossing as an `Internal` action against
that turn and forces rotation at the next boundary under `context-critical`, ahead of any
configured ratio. **It cannot prevent a turn already in flight from hitting the wall** — if
that happens the existing crash path (positive termination signal → `interrupted` turn →
`recover_and_replay`) is what catches it, and that limit is stated in
`spine.rs::settle_context_pressure` rather than papered over. Honest gaps: the cadence
extrapolation is linear over FRESH single-turn probe sessions, so its turn counts are
ceilings not predictions (real per-turn consumption grows as tool output accumulates), and
nothing here surfaces context state to the UI — `context_source()` has no reader outside
tests yet.

**Voice mode (2026-08-24):** the `◉` toggle is real. Mic -> VAD -> local whisper.cpp
(`small.en`) -> the SAME `Spine::submit_prompt` typed text uses (`Source::Jam`, one thread,
one ledger) -> Rich's streamed reply -> sentence-pipelined macOS `say` -> one continuous,
interruptible cpal stream. **Proven live end to end on this Mac** — real whisper, real Claude,
real speakers. (An earlier note here said the host had no input device at all; an Elgato Wave:3
has since been connected and is the default input, so the device capture path is exercisable.)
**No live partial transcript** (whisper-cli has no partial-hypothesis stream) — a visible
deviation from the UX direction §4.1 sketch. Full measurements, gaps and packaging
requirements: the voice-pipeline brief, 2026-08-24.

**Echo cancellation (2026-08-29):** `crates/richos-voice/src/aec.rs` is a real 2048-tap
partitioned-block frequency-domain adaptive filter, written here rather than vendored (nothing
to name in the open-source licence audit). It is bit-transparent while Rich is silent — with a
zero reference the estimate is exactly zero, so dictation and call transcription are provably
untouched — and it costs 0.355 % of one core.

Barge-in now has two rules. The 5.008 s consecutive debounce is the DEFAULT and the fallback.
The short rule — 15 near-end frames within a sliding 0.400 s window — is reachable only when
the canceller has MEASURED its own residual echo 6 dB below the VAD's speech threshold and held
it there for 2.000 s. On a linear path that gives 28.0 dB ERLE, a **400 ms** shortest
interruption (down from 5008 ms) and zero self-interruptions.

**On this host's own hardware it does not reach that bar, and says so.** Measured by
`examples/aec_probe.rs` on the built-in speakers into the Elgato: the echo is real and dominant
(24.9 dB over the room noise) and its timing is known to the sample, but its ENVELOPE
correlates at 0.973 while its WAVEFORM correlates at only 0.174 — so magnitude-squared
coherence caps ANY linear canceller at **5.5 dB** here, WebRTC AEC3 and Apple's
VoiceProcessingIO included. Clock drift, loudspeaker overdrive and reverb longer than the
filter were each tested and eliminated. So `confident()` stays false, the 5.008 s rule and the
half-duplex taint rule stay in force on this desk, and "headphones recommended" is still the
honest note. Four reproducible rigs carry the evidence: `aec_rig` (offline), `aec_live`,
`aec_probe`, `aec_transcribe`.

**Foundation only / later legs:** the attention-seam TRIGGER (timers/log-watchers that decide
WHEN to raise a proactive message — `Spine::raise_proactive` is the seam, judgment is not),
a magnitude-domain echo DETECTOR for the barge-in decision path (the linear canceller has
landed; this is what would make barge-in work on hardware whose echo path is not linear —
prototyped and measured at 0.7 % false positives / 73.6 % detection on a real recording, but
not shipped: see `aec.rs`), a live partial transcript, a warm whisper daemon, a Windows
`SpeechSynth`, and
packaging (signed/notarized bundles, bundled Node + adapter + whisper + models — see the
voice brief's size table). See the feasibility notes in the handoffs.

**Delegated workers, live (2026-08-29):** the engine's worker-lifecycle stream now reaches
the CEO *during* the turn. `rich://worker-upserted` — §13's eleventh event, deferred while
no lifecycle signal existed — carries the same `worker_activity` row a reload projects,
built by the same two functions (`timeline::worker_activity`, the join with its session
clause, and `timeline::worker_activity_item`, the row), so the live path and the snapshot
path cannot drift. Before this the join ran only inside `get_timeline`: a delegation
appeared after a snapshot read and showed as a nameless *"Worked"* row during the turn.
The §26 fixture measured it — 0 chips live, 3 after the snapshot — and now measures the
opposite plus the agreement between the two paths.

Three honest limits, unchanged by this work and worth restating rather than rediscovering:
`waiting`, `interrupted` and `failed` have **no witness anywhere** in the hook set, so
`run_ended` crosses the wire as `WorkerState::Unknown` and renders as *Ended · outcome not
recorded* — never as a completion. There is **no poll and no timer**: the event is emitted
when machinery arrives and once more at the turn's end, so between two tool calls a chip
can be up to one tool call stale (bounded, one-directional, never a claim about a worker
that was never witnessed). And the join is **session-scoped**, because `agent_id` is not
globally unique — the clause that keeps another session's worker name and authored summary
out of this entity's thread.
