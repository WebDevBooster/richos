# RichOS desktop app (`app/`)

The purpose-built, CEO-facing RichOS front-end — a **Tauri** desktop app (Rust core +
web UI), local-first, single-machine, **no relay**. Built to the system architecture:

- The front-end architecture plan, 2026-08-24 (Tauri; RichOS drives the agent
  directly; drop the Nostr relay + its shim; P1 = the runtime spine).
- `wiki/ceo-decisions.md` **§16** (2026-08-31): **the ACP adapter is deleted.** RichOS
  drives the NATIVE `claude` binary over its stream-json stdio. **There is no npm under
  `app/` in anything that ships** — 112 resolved packages across 99 publishers went to 0.
- The session-continuity design, 2026-08-24 (the durable Rich is the APP;
  the Claude session is a swappable compute lease; the ledger is the spine's backbone).
- The RichOS front-end notes (v1 CEO-only / single-machine / no-relay; BYO-Anthropic;
  Rich-organized topic threads over one shared ledger/loro).

This scaffold delivers **front-end Phase 1.1–1.2 + the P1.4 continuity FOUNDATION**:
a working "talk to Rich" loop through the real native path, a crash-safe conversation +
action ledger, a multi-thread data model, and the re-prime seam.

## Who reads every string in here

**Non-technical CEOs, based in the US** (CEO, 2026-08-29 — "the main or at least the initial target
audience"). So **every user-facing string in `app/` is American English**: labels, status words,
empty states, error and permission copy. Not code identifiers, not CSS custom properties, not
protocol values — those stay as they are.

Verified 2026-08-29: no British spelling appears in any shipped string in `app/ui` or
`app/crates/*/src`. Every hit for *color*, *behavior*, *cancelled*, *unrecognized* and the rest is
in a comment or is the constant `STOP_REASON_CANCELLED`. The rule exists to keep it that way.

One open question, not a defect: `timeline.js:1140`, `timeline.js:1414` and `main.js:124` format
time with `toLocaleTimeString(undefined, …)`, which follows the **operator's machine locale** — so
the same build shows 12-hour time on a US Mac and 24-hour on a European one. Whether the product
declares `en-US` or keeps respecting the machine has never been decided. See
`richos-hq/wiki/ceo-decisions.md` §13; the full wording rule is §1.1/§17.5 of the Codex-inspired
conversation-UX brief.

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
    src/native.rs            the COMPUTE-LEASE client: stream-json stdio to the native
                              `claude` binary. No adapter, no Node, no npm (§16). Carries
                              the auto-approve seam (`decide_permission`), the loud
                              startup handshake, and the between-turn lane
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
    src/loro.rs              the Tier-C seam IMPLEMENTED: compile a slice, re-assert its lane —
                              and RETAIN its provenance (SliceProvenance: which record each
                              line of the injected memory came from), which is what lets a
                              later correction name a record instead of guessing one. Nothing
                              is retained for a slice that was refused
    src/correction.rs        the loro WRITE loop: propose, ASK the CEO, then write
    src/cognition.rs         the swappable compute-lease trait (+ MockCognition), LeaseFactory
    src/stream.rs            live UI-facing turn events (streaming deltas + turn/proactive state)
    src/live.rs              the THIRD event family (UX §13): seven typed live-work events,
                              four deliberately NOT emitted, and the fence + visibility gate
                              that make a payload impossible to build from a loose thread id
    src/worker_events.rs     the engine's worker-lifecycle stream, read and joined BY
                              IDENTITY to the Task call that spawned the run — session-scoped,
                              because agent_id is not unique across sessions
    src/machinery.rs         the SECOND event family: every non-text agent frame, routed not
                              dropped, normalized + merged by toolCallId (rich://machinery)
    src/journal.rs           the machinery JOURNAL — separate store, per-thread, day-sharded,
                              Tier A never evicted / Tier B a rolling raw window
    src/steering.rs          the CEO's two MID-TURN controls (UX §9.2/§9.3): an append-only
                              intake log the stop/steer commands can write to WITHOUT the
                              spine lock (which a running turn holds for its whole length),
                              plus the lease cancel seam. Not a second source of truth —
                              every record either becomes a ledger event or is refused
    src/spoken.rs            THE FLYWHEEL'S AUTOMATIC TRIGGER: what makes an utterance a
                              correction — a `not`-pivot repair frame, the shipped
                              ceo-decisions.md §7 term gate (ported), and a record anchor
                              carried as EVIDENCE not as a gate. Detects; never writes.
                              Measured: precision 1.000, recall 0.941 over 149 invented
                              utterances (docs/measurements/spoken-correction-trigger-2026-08-30/)
    src/belief.rs            THE LORO DESK'S PROPOSER: what makes an utterance a correction of
                              a recorded BELIEF, and — the load-bearing half — WHICH record it
                              corrects. Same `not`-pivot frame as spoken.rs (one extractor,
                              two gates) with a near-opposite judgement: a different VALUE
                              rather than a mishearing, and a reference resolved to exactly
                              one record or nothing filed. Detects; never writes.
                              Measured: precision 1.000, recall 0.971 over 147 invented
                              utterances (docs/measurements/loro-correction-trigger-2026-08-30/)
    src/staging.rs           where a detected correction LANDS: durable candidates
                              (append-only JSONL, fsync per record) and §7's three outcomes.
                              `confirm` is the only path to a vocabulary write, and it goes
                              through `richos-service learn-term` rather than a second
                              implementation. Held as an Arc BESIDE the spine lock, so an
                              ask raised during a turn can be answered during that turn
    src/spine.rs             queue-not-interrupt + turn-boundary rotation + crash recovery +
                              the proactive-attention seam + stop settlement at the boundary
                              + the correction trigger at submit_prompt step 1b (every CEO
                              utterance, voice or typed, with no command typed)
    src/config.rs            durable CEO preferences: company_name, the assertiveness dial
    src/worker_status.rs     the optional AI-worker drill-down (reads the engine's event logs)
    src/feedback.rs          the in-app feedback channel, LOCAL HALF ONLY: the 1/2/3/0 rating
                              prompt, its one-file store, and the VERSIONED CLOSED VOCABULARY a
                              report is assembled from — FeedbackPayload has no String field at
                              any depth, so a user's specifics are unrepresentable rather than
                              filtered. Nothing in it sends anything and there is no queue
    src/util.rs              the shared id and clock helpers, and nothing else
    examples/native_roundtrip.rs   headless proof of the real round-trip
    examples/native_failure_modes.rs THE LOUD-FAILURE PROOF (§16): five ways the compute
                              lease can fail, each shown to be named, bounded and never a
                              degraded success — including the REAL binary rejecting a flag
                              it does not know. Costs no API turns
    examples/rotation_roundtrip.rs headless proof of rotation against the real binary
    examples/live_events_roundtrip.rs both families side by side on one real turn
    examples/worker_status_demo.rs   what the drill-down reads, against real event logs
    examples/loro_reprime_demo.rs / loro_correction_demo.rs  the Tier-C read and write loops
    examples/watermark_roundtrip.rs  the rotation trigger, reading the agent's own usage
    tests/entity_binding_tests.rs 10 entity-scope tests: the cross-entity leak NEGATIVE
                              CONTROL (proven failing with the guard removed), immutability,
                              the fail-closed unbound legacy thread + its one-way explicit
                              adoption, the activation fence, and restart
    tests/entity_registry_tests.rs 5 tests that the registry is the CEO's own six companies
                              rather than four directory names, including the multi-root
                              proof (`richos` + `richos-hq` -> one entity id) and the
                              string-prefix trap beside it
    tests/spine_tests.rs     12 spine invariant tests (no live Claude needed)
    tests/rotation_tests.rs  22 rotation/crash-recovery/proactive-seam tests, including
                              the watermark's own live-vs-estimated source reporting
    tests/action_ledger_tests.rs 15 action-ledger WRITER tests (the ledger is non-empty
                              at runtime; CEO-facing actions cross a rotation; machinery
                              stays out of every priming prompt)
    tests/machinery_tests.rs 15 machinery routing/retention tests, driven by native wire
                              frames actually measured against the binary
    tests/steering_tests.rs  16 stop/steer tests (UX §9.2/§9.3). Includes the CONCURRENCY
                              proof: the spine goes behind an Arc<Mutex<..>> exactly as the
                              Tauri shell holds it, a real turn runs on one thread, and the
                              test asserts try_lock FAILS at the instant the stop is pressed
                              — so it cannot silently start passing for the wrong reason.
                              Also: a turn the CEO stopped is never crash-replayed, and a
                              stop request that outlived the process is applied at startup
    tests/native_cancel_tests.rs 3 interrupt tests against a REAL CHILD PROCESS over real
                              stdio (a POSIX-sh fake `claude` the test writes itself), in two
                              variants: compliant, and deliberately deaf to the interrupt
    tests/between_turn_tests.rs 4 tests for techy-mode §1.5 gap #1, also against a REAL
                              CHILD PROCESS: the frame the agent emits at session start and
                              after a turn's result — which used to hit no sink at all — is
                              parked, deduplicated by the last_session_meta slot (on
                              meta_identity, because the frames differ by uuid), and drained
                              with turn_id: None. The fourth pins spike caveat C3: the
                              derived context measurement cannot exist before turn two
    tests/between_turn_thread_tests.rs 6 tests for the same gap end to end: a real
                              NativeCognition's session-start frame reaching the journal and
                              the technical view, re-prime machinery that is recorded and
                              structurally cannot render, no session id on the lane's wire,
                              the honest empty lane, and the retention window covering it
    tests/feedback_no_outbound_tests.rs 8 tests asserting an ABSENCE: no transport in the
                              module's shipping code, no network-capable dependency in the
                              crate, no other module consuming the feature, and an approval
                              that lands in one file with no sibling left for anything to
                              pick up — plus three added with the SURFACE, because the first
                              four were written when the module had no caller: no transport
                              in the six Tauri commands OR anything they call (the call graph
                              is walked, seeded from `generate_handler!`), no network
                              primitive anywhere in the shipped web layer, and the positive
                              half — `feedback_record` still compares the rendered report
                              against what the webview says it showed him. Each proven to
                              FAIL when broken
    tests/launch_no_outbound_tests.rs 11 tests holding the LAUNCH RECORD to the identical
                              standard, at the CEO's direction — it is a record of his own
                              working life, so "local only, never outbound" is asserted the
                              same four ways (no transport in `launch.rs`, no network-capable
                              dependency, no other module consuming it, one file and no
                              sibling after a whole run) plus the surface: no transport in
                              the two Tauri commands or anything they call, no network
                              primitive in `splash.js`/`splash-library.js`/`main.js` (which
                              the feedback suite's web check does not name), the window
                              injection pinned to a frozen one-field verdict rather than
                              merely scanned, the local-bucketing offset proven to come from
                              the CALLER with no timezone read in Rust, and the shape handed
                              to the webview pinned field by field. Two positive controls,
                              because a scanner over an empty corpus reports clean
    tests/feedback_surface_tests.rs 3 tests that WRITE the three fixtures the browser suite
                              checks `app/ui/mock.js`'s copy of this feature against — the
                              wording and the whole vocabulary, six selections with the exact
                              block each renders, and three stored entries taken through a
                              real store round trip. Regenerate with RICHOS_WRITE_FIXTURES=1;
                              without it they compare and fail on any drift
    tests/spoken_precision.rs THE MEASUREMENT, pinned as a test rather than quoted in a
                              brief: TP 32 / FP 0 / FN 2 / TN 115 over the invented corpus,
                              plus the anchor-as-a-gate counterfactual that demoted it
    tests/belief_precision.rs THE OTHER MEASUREMENT, pinned the same way: TP 34 / FP 0 /
                              FN 1 / TN 112 over 147 invented utterances, plus the
                              topic-condition counterfactual that earns it (precision 1.000
                              -> 0.739 with the condition off, recall unmoved)
    tests/belief_trigger_tests.rs 6 tests for the loro completion criterion, driven through
                              the REAL read seam: a slice -> CliContextCompiler::interpret ->
                              SliceProvenance -> submit_prompt -> a proposal with the RIGHT
                              ref on a real desk. Plus the fixture app/ui/ renders, checked
                              against the live detector so a screenshot cannot go stale
    tests/heard_precision.rs THE THIRD MEASUREMENT, and the first that is not 1.000:
                              TP 35 / FP 1 / FN 3 / TN 117 over 156 invented heard/sent
                              pairs, precision 0.972 / recall 0.921. Carries the
                              grammar-word counterfactual that earns it (FP 1 -> 18 with the
                              condition off, recall unmoved), the `emitted`-vs-`text`
                              counterfactual, and a cross-match probe over 24,058 offers of
                              a send against a dictation it did not come from
    tests/heard_trigger_tests.rs 7 tests for the third completion criterion — a dictation
                              silently edited before sending puts a candidate on the desk
                              with nothing said, over a REAL journal on disk in the format
                              tools/richos-hud/dictation-flywheel.patch writes. Plus the
                              fixture app/ui/ renders, checked against the live detector
    tests/spoken_gate_agreement.rs the ANTI-DRIFT pair: §7's gate has two implementations
                              (this crate and tools/richos-service/lib) writing into ONE
                              vocabulary, so both assert against one generated fixture. It
                              covers the HUNK REDUCTION too since 2026-08-30 — heard.rs
                              ports capture.js's `tokenReplaceHunks`, and a divergence there
                              changes WHICH PAIR is learned rather than whether to ask
    tests/spoken_trigger_tests.rs 9 tests for the completion criterion — speaking a
                              correction records it with no command typed, ordinary
                              conversation stages nothing, internal traffic is never mined
    tests/timeline_tests.rs  12 typed-timeline tests: the cross-entity machinery NEGATIVE
                              CONTROL (both clauses proven failing when removed — one leaks
                              a row, one leaks THROUGH the toolCallId merge), the one shared
                              per-turn sequence live and after a restart, the visibility
                              gate, the items that are never invented, and the worker join
                              with its session clause
    tests/live_event_tests.rs 20 additive-family tests (§13): the four original events
                              asserted BYTE-IDENTICAL with and without the new family, the
                              wire and the reload agreeing field by field, phase honestly
                              `unknown`, the states that are never emitted, and the
                              cross-entity fence on every payload
    tests/loro_reprime_tests.rs 10 Tier-C tests: a slice that carries another company's
                              item is refused whole, and an entity with no lane reads the
                              CEO layer and nothing else
    tests/loro_lane_map_tests.rs 11 lane-map tests: the default map is the CEO's six
                              companies, a lane the corpus does not have is DROPPED rather
                              than sent (loro exits 2 on one, which would make every
                              re-prime Unavailable), the cross-entity guard still refuses
                              after a drop, and a thread reading another company's in-repo
                              record is told whose record it is
    tests/loro_gui_launch_tests.rs 15 tests for the launch nobody tests on (13 plus the two
                              subprocess children they drive): a double-click
                              carries HOME, USER and PATH and nothing else, and until
                              2026-09-01 the WRITE half of loro read three environment
                              variables it therefore never had. Two of them re-invoke the
                              test binary with env_clear() and cwd=/ so the GUI condition is
                              a real process rather than a value someone passed, and the one
                              that matters most asserts the reader and the writer resolve
                              the SAME corpus — a build where they disagreed would show him
                              a proposal about one record and write to another
    tests/worker_attribution_tests.rs 10 tests that the workers in the prompt are the
                              SERVING SESSION's, derived from the session identity and
                              never from a directory mtime (a decoy dir is present in
                              every case, so "reads nothing" cannot pass by finding nothing)
    examples/machinery_roundtrip.rs headless proof that machinery is routed AND retained
                              end to end against the real adapter (the run is kept at
                              docs/verification/machinery-roundtrip-2026-08-28.txt)
    examples/loro_install_probe.rs WHICH CORPUS DOES THIS LAUNCH RESOLVE? — both halves,
                              printed, from one resolution. Read-only. Run it under
                              `cd / && env -i HOME=$HOME USER=$USER PATH=/usr/bin:/bin:/usr/sbin:/sbin`
                              and nothing else tells you the truth
    examples/loro_gui_correction_e2e.rs the whole correction desk under that same condition
                              on a SCRATCH machine — provision, propose, confirm, and the
                              record on disk. It stops one hop short of the button, and its
                              header says exactly which hop
                              (docs/verification/loro-write-path-2026-09-01/)
  crates/richos-voice/       VOICE MODE — mic -> whisper -> the spine -> TTS -> speakers
    src/vad.rs               RMS VAD + THE FRAME MATH (16000 Hz, 256-sample frames = 16.000 ms)
    src/bargein.rs           313-frame (5.008 s) fallback debounce; 15-of-25 (0.400 s) window
                              once the canceller has EARNED it; the EchoGate seam
    src/aec.rs               ACOUSTIC ECHO CANCELLATION — 2048-tap PBFDAF (128.0 ms tail),
                              lock-free reference ring, envelope delay estimator.
                              28.0 dB ERLE on a linear path; ~5.5 dB is all ANY linear
                              canceller can reach on this host's speakers+Elgato (measured)
    src/fft.rs               512-point radix-2 FFT, hand-rolled (license: no vendored crate)
    src/endpoint.rs          utterance start/end, pre-roll ring, cough filter, 30.000 s cut
    src/noaudio.rs           post-open silent input: 188 frames (3.008 s) under -80.00 dBFS
    src/chunk.rs             streaming sentence chunker + clean output FOR THE EAR
    src/state.rs             the voice-mode state machine (mic state is never a guess)
    src/wav.rs               hand-rolled PCM16 WAV codec + rate conversion
    src/event.rs             rich://voice-state (incl. noAudio) | voice-transcript | voice-error
    src/{capture,playout}.rs cpal in/out; playout is one continuous, interruptible stream
    src/{stt,tts}.rs         local whisper.cpp (small.en) / macOS `say` behind a trait
    src/controller.rs        four threads, CaptureBrain, the half-duplex taint rule
    tests/barge_in_composition.rs  the WIRING: echo defense + real interruptions
    examples/voice_loop.rs   the reproducible end-to-end proof (audio -> Claude -> speakers)
    examples/device_probe.rs what the audio hardware on THIS machine actually reports
    examples/noaudio_live.rs live mute/unmute check on the real device (PASS 2026-08-24)
    tests/watermark_cadence_tests.rs 8 tests that recompute the rotation cadence from the
                              RAW 2026-08-28 capture on every run, both directions
  src-tauri/                 the Tauri shell — DETACHED nested workspace (empty [workspace])
    src/main.rs              window + Tauri command bridge to the spine
    src/nav.rs               durable rail VIEW state: width, pin, rename, archive (not evidence)
    src/updates.rs           THE UPDATE PATH (RICH-TODOs row 12): check, download with
                              throttled progress, VERIFY, install, relaunch; a nine-state
                              view emitted as `rich://update`; and the failure classifier
                              whose signature arm must never widen. The webview is granted
                              NO `plugin:updater|*` permission — these four commands are the
                              whole of its updater surface
    src/events.rs            the relay: one LiveObserver that puts §13's payloads on the
                              webview, and nothing that can widen them
    src/timeline_view.rs     the get_timeline command body — Timeline::view(Ceo) -> payload
    examples/timeline_payload.rs prints that payload from a real ledger (what realbytes.js
                              renders, so backend/UI field drift cannot go unnoticed)
    examples/stop_payload.rs the stop path's wire bytes, for the same reason
    examples/verify_update_signature.rs  the check a signer's exit code does not make: that
                              a produced .app.tar.gz and its .sig AGREE, under the pubkey
                              tauri.conf.json ships
    Info.plist               the macOS privacy strings (NSMicrophoneUsageDescription)
    Entitlements.plist       hardened-runtime entitlements — used ONLY by the
                              --sign developer-id path, referenced nowhere in
                              tauri.conf.json, and never yet used to sign anything
    tauri.conf.json, capabilities/, icons/
  scripts/
    package-app.sh           the packaging entrypoint: builds, signs, notarizes,
                              staples, VERIFIES, and refuses — the caller that arms
                              build.rs's icon gate
    make-signing-csr.sh      the keypair and the CSR Apple's portal asks for; the key
                              is written outside every repository and this refuses to
                              put it in one
    install-signing-cert.sh  Apple's .cer + that key -> a usable codesigning IDENTITY,
                              verified by asking `security find-identity` rather than
                              by the import exiting 0
    rebuild-survival.sh      the acceptance test that only a SECOND install can run:
                              do the microphone and accessibility grants survive?
    generate-app-icons.sh    one artwork PNG in, every artefact tauri.conf.json declares out
    lib/app_icons.py         the generator + verifier both of the above run
    updater-e2e.sh           THE ROW 12 DELIVERABLE: builds 0.1.0 and 0.1.1, serves a
                              manifest, makes the first BECOME the second on this machine,
                              then flips one byte and requires the install to REFUSE.
                              10/10 on 2026-08-31 — docs/verification/updater-e2e-2026-08-31/
    lib/updater_tar.py       the update archive, built from the SIGNED bundle (the bundler
                              makes its own from the unsigned one — see package-app.sh's
                              header) and by tarfile rather than by bsdtar, which writes
                              AppleDouble sidecars the updater would unpack into the app
    run-tests.sh             every *.test.sh here, discovered from disk, never typed
    *.test.sh                package-app, signing-setup, rebuild-survival, updater-setup
                              — 90 checks
  UPDATES.md                 how RichOS updates itself: what is proven, what is NOT proven in
                              those words, the signing key and where it may not live, the
                              manifest format, and the four hosting options — which is a CEO
                              decision and is left as one
  updater/latest.example.json  the manifest format, with a home in the repository rather
                              than only in a build directory
  ui/                        the web UI — the CEO-facing surface
    index.html               the shell: rail, header, timeline, inspector, composer
    main.js                  the WIRING — commands, the four families' listeners, the rail,
                              per-thread draft/scroll, voice, and the render loop
    timeline.js              the timeline MODEL and its DOM: the fence, the visibility gate,
                              the idempotent upsert, §6.4's two disclosure defaults
    style.css                the calm paper palette and the work grammar (§17)
    mock.js                  the dev harness — inert in the real Tauri build; the ONLY way
                              every state is reachable without a live Claude
    tests/                   the browser acceptance harness (see tests/README.md)
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

## Between threads, and across a restart (Codex-UX slices 9 and 10)

Contract: §24's last two slices — *"verify restart, multi-thread and scope behavior"* and
*"update streaming and UI contracts"*. Slices 1–8 each proved ONE thread, in isolation, for
the length of ONE turn. These two close what that leaves open, and they are two halves of
one job: the first checks the behavior, the second checks the sentences about it.

**What is verified** (`app/ui/tests/restart-scope.js`, through the real shell under WebKit):

- **A working thread stays visibly active while another is selected**, and returning to it
  RESUMES its timer rather than restarting it — measured, not asserted about: leave at 0s,
  return at 3s, still ticking, derived from the turn's own `startedAt`.
- **A draft and a scroll position belong to one thread.** The draft one is a privacy
  control rather than a convenience: an entity is a boundary, so a half-written sentence for
  one company sitting in another's composer is one Enter from being filed in the wrong
  place.
- **A turn streaming elsewhere renders nothing here** — across entities AND across two
  threads inside one entity, which is the half only the fence's `threadId` clause catches.
- **The fence is on EVERY live handler.** The inventory is read off the shipped
  `window.RichTimeline` and cross-checked against the number of `accepts()` call sites in
  `timeline.js` on disk, so an eighth handler that forgets the fence fails the check rather
  than quietly widening the surface.
- **Duplicates render once**, and **missed events recover from the durable snapshot** —
  proven by replacing the whole typed family with functions that throw the events away and
  watching the reconciliation reload put the turn back.
- **A turn still in flight when the app closed reads "outcome unknown", never finished**
  (§14: *"Never infer that a turn completed because the app was closed"*), and **a mid-turn
  crash draws the CEO's prompt exactly once** — measured across the whole recovery window,
  not just at the end, because the end state is right either way.

**One defect it found.** §15's *"preserve each thread's scroll position during thread
switching"* did not work: the position was written while the PREVIOUS thread's DOM was
still mounted, so the browser clamped it and the render's height anchor then added the
difference between the two threads' heights. A constant off-by-121px at 1200x420 against
the seeded FemcBoost thread. Fixed; the mutation that removes the fix is M4 in the
transcript below.

**Every check was run RED once**, by breaking the thing it guards in the shipped source.
The ten runs, the coverage map derived from them, and the one check with no mutation of its
own are in
[`docs/verification/restart-scope-2026-08-30/mutation-runs.txt`](../docs/verification/restart-scope-2026-08-30/mutation-runs.txt).
Two of those runs changed the tests instead of confirming them, which is the whole argument
for doing it.

**What keeps the documents true** (`app/ui/tests/docs-claims.js`). Slice 10 rewrote the
stale claims in this file, in `app/STREAMING.md` and in `app/ui/tests/README.md`; the suite
is what stops them going stale again. It joins four kinds of claim to the tree and types
nothing:

| Claim | Joined to |
|---|---|
| per-file test counts in this file | `#[test]` counted in the file named |
| the `cargo test -p <crate>` totals | the sum of those, plus doc-tests counted from the fences |
| the suite table in `ui/tests/README.md` | the inventory `run.js` discovers from disk |
| every `rich://` name in `STREAMING.md` | the `pub const … = "rich://…"` the Rust source declares |

Its first run is the demonstrated failure and nothing in it was staged:
[`docs/verification/restart-scope-2026-08-30/docs-claims-before-slice-10.txt`](../docs/verification/restart-scope-2026-08-30/docs-claims-before-slice-10.txt).
Five of six checks red — two crate totals wrong by 207 and 42 tests, four per-file counts
stale, three whole test suites documented nowhere, three browser suites missing from their
own table, and four declared `rich://` events absent from the document that calls itself
*"the whole contract the UI needs"*, `rich://proactive-message` — Rich speaking unprompted
— among them.

This is deliberately the gap `engine/scripts/publication-completeness.sh` names as beyond
its reach: *"SEMANTIC honesty. Every path in a document can resolve while the sentence
around it is false."* Every path in `app/README.md` did resolve the whole time.

## Machinery routing and the technical view (techy mode)

Every non-text agent frame is **routed**, not dropped, into a second event family
(`rich://machinery`) and retained in a separate per-thread journal at
`<app-data>/machinery/<thread_id>/<YYYY-MM-DD>.jsonl`. Contract:
`richos-hq/docs/plans/richos-techy-mode-2026-08-26.md`. UI contract: `app/STREAMING.md`.

**Retention is unconditional and has no setting** — that is what makes it possible to turn
the technical view on for a conversation that already happened.

**The technical view itself landed 2026-08-30.** `get_machinery` serves one thread's
machinery as its timeline at `ViewMode::Technical` — the same items, the same ids and the
same `(turn, slot, sequence)` order as the calm view, with the technical half of each row
kept rather than removed. `app/ui/` renders it inline, one line per tool call, with the
status each actually returned; `get_machinery_raw` fetches §2.4's raw pane on expand. The
toggle is `techy_mode` / `set_techy_mode` / `set_techy_default`: ⌘⇧T pins one conversation,
one line in Settings switches all of them. **With it off, the conversation surface is
byte-identical to what shipped** — no chip, no chevron, no hint — and `tests/techy.js`
check 11 asserts that by comparing `#messages` innerHTML across a round trip.

Five limits, stated rather than discovered later:

1. **Retroactivity begins at the routing commit.** A thread that ran before it has no
   machinery at all, and the honest state is *"No machinery was recorded for this
   conversation."* Nothing earlier is recoverable, ever. **That sentence is one of four**
   (`machinery_view.rs`): `nothing_recorded`, `not_retained` (nothing on this install),
   `unreadable` (the store is there and the OS refused it) and `recorded`. They are
   deliberately not one sentence — an unreadable store served as an empty one is the
   product lying about its own record.
2. **Readable thinking text produces nothing today, on EITHER wire.** Measured across five
   probe runs of `claude-agent-acp` 0.70.0, including one built solely to elicit it: zero
   `agent_thought_chunk` (`docs/verification/acp-emission-probe-2026-08-28.md` §4.1).
   Re-measured on the native binary 2026-08-31: **7 `thinking` blocks, every one with EMPTY
   text and a signature only** (`docs/verification/native-claude-stream-json-2026-08-31/`).
   Deleting the adapter changed nothing here, which is worth saying because it was the one
   row a reader might have hoped the move would fix. The route exists so there is no hole
   the day that changes; **no `● thinking` row is drawn**, because an always-empty
   affordance says the model is not thinking when the truth is that the agent does not say.

   Same for client-directed file IO, and there the native answer is stronger than "not
   observed": the CLI was **OBSERVED NOT TO ASK** — it wrote and edited files itself and
   asked only for permission. `MachineryKind::ClientFsCall` therefore has no producer at
   all, which `machinery.rs` states at the constructor rather than leaving to be found.
3. **Between-turn updates are still dropped.** One `available_commands_update` at session
   start and one `session_info_update` after each turn ends reach no sink, because the
   client only delivers updates while a prompt is in flight. §1.5 designs the fix.
4. **The technical view is a RELOAD path, not a live technical stream.** While a turn runs
   its rows arrive from the calm live family, which is CEO-shaped by construction, so they
   gain their technical half when the turn ends. `rich://machinery` still has no UI
   subscriber, and that is deliberate: subscribing would turn "the calm view does not
   subscribe to this event" from a structural fact into a runtime branch.
5. **No control of any kind.** No interrupt, no approve/deny, no re-run. Techy mode is a
   window, not a cockpit — `tests/techy.js` check 15 asserts the only button inside a
   technical row is its own disclosure.

**The four §7 questions are the CEO's and are left open** (`richos-hq/wiki/open-items.md`
1.4). Global default vs per-thread: both exist and both are reversible
(`set_techy_mode(enabled: null)` hands a pinned thread back). The raw-payload window:
nothing in the read path or the renderer consults it, and no sentence names a duration.
Whether customers can find it: no conversation-surface affordance while it is off. Whether
deleting a thread deletes its machinery: no delete-thread command is added, and both
primitives exist (`MachineryJournal::delete_thread`, `ConfigStore::forget_techy_thread`).

## Feedback channel — the local half (v1)

RichOS asks `How is RichOS doing this session?` with four keys — `1` Bad, `2` OK but
could be better, `3` Good, `0` Dismiss. On `1` or `2` it offers to let Rich tell the
RichOS developers, **fully anonymized and generically**, what annoyed the user and why it
happened. Before that could ever travel, the user sees exactly what would be said.

**This version has no outbound half at all.** No transport, no endpoint, and deliberately
no queue for a later version to find and flush. `tests/feedback_no_outbound_tests.rs`
asserts that seven ways rather than promising it in a comment — four over the module, and
three more over the Tauri commands, everything those commands call, and the shipped web
layer, because a claim written when the feature had no caller stops covering it the day it
gets one.

**The taxonomy is the feature, and it is a type problem rather than a filter problem.**
A filter reads free text and decides whether it is safe. `FeedbackPayload` has no `String`
field at any depth: a report is assembled from a closed, versioned vocabulary of terms
that were authored once and compiled in, so there is nowhere for the user's specifics to
sit. It is the same move as `Timeline` refusing to implement `Serialize` — the unsafe
thing does not exist, rather than being caught.

Why a filter would not have done, on the reference case this was built against: one of its
negative controls contains **no proper nouns at all** and is still disqualifying, because
it discloses what the user does for a living. It reads "generic" both to the model that
wrote it and to the human asked to approve it. Nothing that inspects prose catches that
class reliably.

What is pinned, and where:

| Claim | Held by |
|---|---|
| Free text cannot enter a payload | two `compile_fail` doctests on `FeedbackPayload`, with a positive control beside them |
| Prose is refused at the JSON boundary in every smuggling shape | `negative_control_*` tests (diagnosis field, term list, condition list, failure class, and an extra field) |
| The reference case's target payload IS expressible | `positive_control_the_reference_cases_target_payload_is_expressible` — without it the rejection tests could pass by rejecting everything |
| The rendered report matches the target byte for byte | `the_reference_case_target_payload_renders_exactly_this` |
| Everything the feature can say is a finite word set | all 60,960 expressible reports are rendered and every token checked against the vocabulary |
| A change to the vocabulary needs a version bump | `vocabulary_fingerprint()` pinned in a test |
| The user cannot be asked to consent to a report he was never shown | `ApprovedReport` has a private field; the only public constructor is `Disclosure::approve()` |
| ...and that survives the IPC boundary too | `feedback_record` re-renders the selection and refuses an approval whose text is not byte-identical to the block the webview says it showed |
| The browser harness cannot rehearse wording the product no longer says | `tests/feedback_surface_tests.rs` writes the fixtures `ui/tests/feedback.js` joins `mock.js` to |

Two limits, stated rather than discovered later:

1. **The prompt is the fallback, not the capture mechanism.** In the reference case all
   five moments of real annoyance were volunteered mid-work, unprompted; none arrived at
   session end. A prompt fired at a chosen moment would have caught none of them at the
   moment they were felt. Catching what is already being said is a larger, later piece.
2. **It appears when he opens it, and at no other time.** The rail carries a permanent
   `Feedback` control with no count on it — nothing on that surface is ever waiting on
   him. There is no timer, no end-of-session prompt and no trigger, and limit 1 above is
   the reason: a prompt fired at a moment of RichOS's choosing would have caught none of
   the five, and one that arrives during the work he is annoyed about is itself an
   unprepared task handed to him. Reachable-when-he-wants-it is the honest fallback;
   catching what is already being said is still the larger, later piece.

## Build & test

```sh
# 1. The spine — fast, no native deps, no network, no Claude:
cargo test -p richos-core                       # 635 tests + 5 doc-tests

# 1b. Voice mode — pure logic + the native edges (no mic needed):
cargo test -p richos-voice                      # 163 tests
RICHOS_VOICE_LIVE_AUDIO=1 cargo test -p richos-voice   # + the audible live tests
cargo run -p richos-voice --example device_probe       # what the audio hardware really is

# 2. The desktop shell (from app/src-tauri/):
cargo build                                     # -> target/debug/richos-tauri (Mach-O)

# 3. The LIVE round-trip. Needs Claude Code installed and signed in — and NOTHING else:
#    no npm, no Node, no adapter. $RICHOS_CLAUDE_BIN overrides the binary; by default
#    ~/.local/bin/claude is preferred over PATH.
cargo run -p richos-core --example native_roundtrip -- "$PWD/../engine" "who are you?"

# 3a. THE LAUNCH THE CEO PERFORMS, end to end. A double-clicked bundle has working
#     directory `/`, which owns no entity, so the send is refused; this runs the whole
#     sequence — refused, answered, remembered, reopened, and the same sentence landing
#     with a real lease. The four steps that need no compute are also tests.
cargo run -p richos-core --example company_choice_roundtrip -- "$PWD/../engine" richos

# 3b. The LIVE machinery proof — the same chain, but showing that tool calls are ROUTED
#     and RETAINED: the calm view, the interleaved (turn, seq) stream, the merged rows,
#     and the journal files on disk. Leaves the journal in place and prints its path.
cargo run -p richos-core --example machinery_roundtrip -- "$PWD/../engine"

# 4. The WHOLE voice loop (a WAV stands in for the mic on a machine with no input
#    device):
say -v Samantha -o /tmp/ceo.wav --data-format=LEI16@16000 "Rich, are you there?"
cargo run -p richos-voice --example voice_loop -- /tmp/ceo.wav
```

```sh
# 5. The UI, in the engine Tauri actually renders through (from app/ui/tests/):
npm install && npm test                         # every suite, discovered from disk
node restart-scope.js                           # one suite, while you are working on it
```

Contract and rules: [`app/ui/tests/README.md`](ui/tests/README.md). Two notes that belong
here rather than there:

- **The counts above are checked, not remembered.** `app/ui/tests/docs-claims.js` reads the
  `#[test]` attributes out of the tree and fails if any number in this file disagrees — per
  test file and per crate. It exists because both totals had gone stale by a wide margin
  (`97/97` against 304, `121/121` against 163) while every sentence around them stayed true,
  which is the one thing `engine/scripts/publication-completeness.sh` explicitly cannot
  catch: *"Every path in a document can resolve while the sentence around it is false."*
- **CI covers the spine and nothing else.** `.github/workflows/app-spine-ci.yml` runs
  `cargo test -p richos-core` and a release build. As its own header says, that workflow
  has never executed — so it must not be called CI-verified until a green run exists on a
  SHA somebody can name. **The browser suites have no runner at all**: they run when
  someone runs them, on a machine with a WebKit build.

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

**`app/scripts/package-app.sh` sets it** (2026-08-30). Two earlier versions of this
paragraph were wrong in opposite directions: one claimed the variable was "set by
bundling and CI" when nothing set it, and its correction then said
`.github/workflows/` contained only `engine-self-verify.yml`. There are three
workflows — `app-spine-ci.yml`, `engine-self-verify.yml`, `windows-companion-ci.yml`.
The **conclusion** that sentence was drawn to support is nonetheless still true, and
survives the correction: **no CI job builds this crate.** `app-spine-ci.yml`'s own
header excludes `app/src-tauri` by name as "a deliberately detached workspace with the
whole webview dependency tree behind it". So CI is not what arms the gate, and an
ordinary `cargo build` must stay non-fatal.

The packaging entrypoint is what arms it, and the pre-flight it runs first is
convenience rather than the guarantee. Proven by deleting the pre-flight from the
script and resizing `icons/32x32.png` to 16x16: the run still stopped at `build.rs`'s
panic and exited 4 with nothing packaged.

Verified on the committed placeholder set: 12 warnings and `Finished dev profile` in the
first mode, a hard panic in the second, and — after a real generation run — strict mode
compiling clean with zero icon warnings.

### Tooling and license

**Pillow, SPDX `MIT-CMU`** (read from the installed distribution's `License-Expression`
metadata, Pillow 12.3.0) for decode/resample/PNG/ICO, plus Apple's own
**`/usr/bin/iconutil`** for the macOS `.icns`. Both are **authoring-time only**: nothing
from either is linked into or shipped inside the signed `.app`, and the only artefacts
that ship are pixels derived from the supplied artwork. That keeps the license question
entirely clear of the signing/notarization path.

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

## Packaging — one command, one line, and it refuses

```sh
app/scripts/package-app.sh                       # ad-hoc signed; what this machine can do today
app/scripts/package-app.sh --sign developer-id   # discovers the identity; needs a certificate
RICHOS_NOTARIZE=1 app/scripts/package-app.sh --sign developer-id   # ...and notarizes and staples
app/scripts/package-app.sh --sign developer-id --dry-run           # resolve everything, build nothing
app/scripts/package-app.sh --verify-only path/to/RichOS.app [--expect-notarized]
app/scripts/package-app.sh --updater             # ...and the signed update artifacts
```

The last line is the whole report:

```
OK: RichOS.app is bundled, ad-hoc signed and verified — real icons, cdhash
fc5051ac9ca8e4713ccaec6a7e02dd3b3efb16ce, microphone usage string present; NOT
notarized, Gatekeeper rejects it, and its permission grants die on the next build
that changes a shipped byte. Path: …/release/bundle/macos/RichOS.app
```

Anything else is a refusal that names its reason. Exit codes: `0` success, `1` the
bundle failed verification, `2` refused before building, `3` a prerequisite is
missing, `4` the build itself failed, `5` the bundle is good and the update
artifacts are not.

`--updater` adds `RichOS.app.tar.gz` and its minisign `.sig`, both built from the
bundle that was just VERIFIED rather than from the builder's intermediate — the
bundler makes its own copy before anything has signed the `.app`, and that copy is
deleted on every run. It needs `TAURI_SIGNING_PRIVATE_KEY_PATH` (refused inside a
git worktree, refused world-readable) and writes `latest.json` only when
`RICHOS_UPDATE_BASE_URL` says where the archive will live. **`app/UPDATES.md` is the
whole picture**, including the end-to-end run that applied an update on this machine
and the two bad ones it refused.

### What it refuses on

- **Placeholder icons.** It exports `RICHOS_REQUIRE_REAL_ICONS=1`, which is what makes
  `build.rs`'s gate fatal, and it pre-checks the same set so the failure arrives in two
  seconds rather than after a release compile. On the committed placeholder set it
  refuses with eleven named problems and exits 2.
- **A signing configuration that cannot work.** `--sign developer-id` DISCOVERS the
  identity when the machine has exactly one "Developer ID Application"; with none, or
  with more than one, it refuses and names them, because choosing between two signing
  certificates by sort order is not a thing a script may do. `RICHOS_SIGNING_IDENTITY`
  still pins one and is still checked against `security find-identity -v -p
  codesigning`. **There is no silent downgrade to ad-hoc**, because a downgrade
  produces exactly the failure Developer ID was asked for. The path still selects
  itself never: an identity appearing on the machine does not change what a plain run
  does.
- **`RICHOS_NOTARIZE=1` without notary credentials.** Either an App Store Connect API
  key (`RICHOS_NOTARY_KEY` / `_KEY_ID` / `_ISSUER`) or `RICHOS_NOTARY_PROFILE`. **There
  is deliberately no `APPLE_PASSWORD` path** — an app-specific password in an
  environment variable is readable by every process the build spawns and lands in shell
  history; the same password goes into a keychain profile once and `RICHOS_NOTARY_PROFILE`
  reaches it. The `.p8` is also refused if it sits inside a git worktree (Apple permits
  exactly one download of it) or is readable by other users of the Mac.
- **A bundle that does not verify.** Checked on the artefact, not on the builder's exit
  code: the executable named by `CFBundleExecutable` exists, `codesign --verify --deep
  --strict` passes, the signature is the KIND that was asked for,
  `Contents/Resources/icon.icns` is byte-identical to the icon this repository
  generated, and `Contents/Info.plist` carries `NSMicrophoneUsageDescription`.
  `--verify-only` runs that same set against an existing bundle, so the two paths
  cannot drift apart.
- **A Developer ID signature whose DESIGNATED REQUIREMENT is a cdhash.** This is the
  only property the certificate is bought for: macOS stores `identifier
  "com.richos.app" and anchor apple generic and certificate leaf[subject.OU] =
  "<TEAMID>"` against every permission it grants, and every future build satisfies it.
  A signature can be a valid Developer ID signature and still carry a cdhash-shaped
  requirement — ad-hoc's failure wearing a certificate — so the requirement is read
  back and joined to the bundle identifier on disk. Under `--expect-notarized` the
  stapled ticket is validated too, because "notarized" without a ticket means the app
  must reach Apple over the network to be admitted.

### Two answers this produced, both previously unverified

`src-tauri/Info.plist`'s own comment asked "the packaging engineer (next round)" to
check two things. Both are now measured, on a real bundle:

- **Tauri's plist merge does land `NSMicrophoneUsageDescription` in
  `RichOS.app/Contents/Info.plist`.** Confirmed with `plutil -p` on the built bundle;
  it is now a permanent check rather than a one-off observation.
- **The hardened-runtime entitlement it also asks about** is
  `src-tauri/Entitlements.plist`, applied by the developer-id path as a config overlay
  only. It has never signed anything — see below.

### Ad-hoc is not what the bundler does. It is what the bundler skips.

The first bundle this script ever produced carried
`flags=0x20002(adhoc,linker-signed)`, `Sealed Resources=none`,
`Identifier=richos_tauri-6a5998b21aa29388`, and `codesign --verify` **rejected it**:
*"code has no resources but signature indicates they must be present"*. That is the
arm64 linker's automatic ad-hoc signature on the executable, with the bundle around it
unsigned — strictly worse than an ad-hoc-signed bundle, because nothing binds
`Info.plist` or the icon to it and the signed identity is a mangled crate name rather
than `com.richos.app`.

So the script signs ad-hoc deliberately, and verifying `Signature=adhoc` is not
enough — that string was true in the broken state too. It also refuses
`linker-signed`, `Sealed Resources=none`, and a signature identifier that differs from
`CFBundleIdentifier`.

### What ad-hoc costs, measured rather than repeated

After signing it prints the designated requirement macOS will store against every
permission grant:

```
cdhash H"fc5051ac9ca8e4713ccaec6a7e02dd3b3efb16ce"
```

A hash of that build and nothing else — no bundle identifier, no team, nothing a later
build can satisfy. It also prints Gatekeeper's own verdict (`spctl -a -vv` →
`rejected`) rather than inferring it.

**The common phrasing "every rebuild is a different application" is too strong, and
this is the correction.** What moves the cdhash is the produced BYTES, not the act of
rebuilding. Measured 2026-08-30: three consecutive runs over an unchanged tree — plus
one whose only edit was a `const` the optimizer removed — all produced
`fc5051ac9ca8e…`, i.e. the same application, grant intact. Changing one shipped string
literal moved it to `27a561effd404…`. It is not a tax on rebuilding; it is a tax on
every change worth shipping. That is still the whole argument for Developer ID, and it
is why the number in this paragraph is a measurement and not a warning.

### The Developer ID path is finished, and has still never signed anything

The CEO enrolled in the Apple Developer Program on **2026-08-31**, so decision 1.1 is
closed and the path is no longer inert prose waiting on a purchase
(`richos-hq/wiki/packaging-and-signing.md`). What is finished, and what is still not
true, are two different lists and both are here:

**Finished.** Identity discovery; the hardened runtime; an explicit re-sign carrying
`--timestamp`; the entitlements overlay; submission to the notary, waiting on it,
fetching Apple's own log on rejection, stapling and validating the staple; and a
designated-requirement check that is the only thing the certificate is bought for.

**Still not true, and nothing here should be read as claiming otherwise.**

- **No certificate exists.** `security find-identity -v -p codesigning` reported
  `0 valid identities found` on 2026-08-24, on 2026-08-30, and again on 2026-08-31.
  Nothing here has ever been signed with a real identity, notarized, or stapled.
  `docs/ceo/developer-id-setup-2026-08-31.md` is the two steps only the CEO can take;
  `app/scripts/make-signing-csr.sh` has already produced the CSR he uploads.
- **No bundle can be built on this tree at all.** The icon gate refuses on the
  placeholder icon set — CEO item 2.6, the artwork — so even the ad-hoc path produces
  nothing today. The developer-id verification arm is exercised instead against a
  minimal `.app` built by hand and ad-hoc signed by the real `codesign`, which fires
  all eight of its failure branches at once. See
  `docs/verification/developer-id-signing-2026-08-31/mutation-runs.txt`.
- **The rebuild-survival test has never run.** `app/scripts/rebuild-survival.sh status`
  reports exit 4 and names what it needs, rather than a pass or a fail. A build that
  has only ever been installed once has never tested the thing that breaks.
- The path still **never selects itself** — an identity appearing on the machine does
  not change what a plain run does; it only makes the run say a signed build is now
  possible.

**Two measured facts about the bundler, which is why this script does more than it
looks like it should.** `tauri-bundler` 2.9.4 (`bundle/macos/app.rs:135-148`)
notarizes on its own when it can resolve `APPLE_*` credentials and, on every credential
error but one, logs `skipping app notarization` and continues — so a typo produced an
un-notarized bundle from a run that exited 0. And `tauri-macos-sign` 2.3.4
(`keychain.rs:221-226`) never passes `--timestamp`, whose unspecified default
`codesign`'s own man page describes as "may result in some but not all code signatures
being timestamped" — and a secure timestamp is a notarization prerequisite. So this
script unsets those variables before invoking the bundler, re-signs with the full
explicit argv, and owns the notary step itself.

### Named gaps

- **Bundle identifier.** Tauri warns on every build that `com.richos.app` ends in
  `.app`, which it does not recommend. It is left as it is deliberately — the identifier
  is pinned and must never change (`packaging-and-signing.md`, "What RichOS
  specifically needs" item 3) — but it is worth deciding *before* a Developer ID
  signature makes it load-bearing for grant continuity, not after.
- **No sidecars are bundled.** `whisper.cpp` and
  `ffmpeg` are not in the `.app`; the bundle is 17 MB and assumes them on the host.
  When they land, each must be signed with the same identity and sealed in, or the
  bundle seal breaks and takes the grants with it.
- **`--bundles app` by default**, not the `"targets": "all"` in `tauri.conf.json`. The
  `.app` is the artefact that matters; DMG creation is a separate, flakier downstream
  step whose failure says nothing about whether the application is correct. Pass
  `--bundles app,dmg` for the installer.
- **macOS only.** It refuses on any other platform with the reason. No Windows bundle
  has ever been built and there is no Windows signing certificate.
- **No auto-update channel.** Not built, not wired, not claimed.
- **Launched, and talked to.** As of 2026-09-01 the bundle is installed at
  `~/Applications/RichOS.app`, opened with `/usr/bin/open` (working directory `/`, launchd's
  environment), asked which company it is for, answered, and given a sentence that came back
  as a real reply in 5,868 ms. Boot line, ledger and the verbatim exchange:
  `docs/verification/installed-app-2026-09-01/`. **Not notarized** — there are no notary
  credentials on this machine, so `spctl` rejects it and a DOWNLOADED copy would be blocked;
  a locally installed one carries no quarantine attribute and opens.

## Runtime config (env)

- `RICHOS_ENGINE_DIR` — the engine repo used as the child's `cwd` (persona + hooks).
  Defaults to the `engine/` sibling of `app/`.
- `RICHOS_CLAUDE_BIN` — path to the `claude` binary. Defaults to `~/.local/bin/claude`
  (Anthropic's own launcher, which SURVIVES auto-update — §16's free way to pin the
  undocumented `--permission-prompt-tool stdio` flag without modifying any binary), else
  the bare name on PATH.
- `RICHOS_CLAUDE_DEBUG` — if set, the child's stderr is echoed (developer machinery only;
  never reaches the CEO view).

### Company memory (loro) — off unless configured, and never inferred

Tier C of the re-prime payload, plus the correction desk. **All three are explicit; there
is no default and there cannot be one.** A default corpus root means one owner's Rich
answering out of another's memory and exiting 0 either way, which is a larger failure than
an error wearing a success code — so with these unset the app boots, says so on stderr, and
every re-prime states that company memory was NOT consulted rather than implying there is
none.

- `LORO_CORPUS` — a provisioned corpus root (`ceo/` + `companies/<id>/`), **or**
- `LORO_ROOT` — an in-repo dogfood root (a checkout with `wiki/` + `loro/`). `LORO_CORPUS`
  wins if both are set.
- `RICHOS_LORO_DIR` — the loro checkout holding `bin/loro-context.mjs` and
  `bin/loro-write.mjs`. Deliberately **not** derived from this checkout: RichOS ships no
  `loro/` directory and never will — the corpus and the vocabulary are the owner's and live
  outside a repository that gets published. When a corpus root has been resolved and this
  is unset, the root's own `loro/` directory is used if it holds both entry points — which
  is where it is by definition in the in-repo shape, and where a provisioned corpus may or
  may not have one. Unusable is an ERROR naming the root, never a silent "no corpus".
- `RICHOS_NODE_BIN` — which `node` runs the compiler. Resolved the way `RICHOS_CLAUDE_BIN`
  is: explicit first, then the first `node` on `PATH` returned as an absolute path, then
  `/opt/homebrew/bin/node` and `/usr/local/bin/node`, then the bare name. **A GUI launch's
  `PATH` is `/usr/bin:/bin:/usr/sbin:/sbin`**, which holds no Homebrew `node`, so without
  this step a resolved corpus fails once per rotation with `could not start the loro
  compiler: No such file or directory`.

#### Two per-user pointers, for a launch that has no environment

Everything above is an environment variable, and **LaunchServices gives a double-clicked
`.app` launchd's environment**, which has none of them. That is the same premise failure
`engine.rs` fixed for the engine directory, and until 2026-09-01 the corpus still had it:
the signed bundle booted `loro Tier C: no corpus configured` with the whole corpus one
symlink away (`docs/verification/installed-app-2026-09-01/`).

So after the explicit variables — which stay **exclusive**, and are never second-guessed —
resolution reads two per-user pointers, in this order, and each must LOOK like what it
claims to be:

| pointer | shape required | resolves as |
|---|---|---|
| `~/Library/Application Support/RichOS/corpus` | `ceo/` + `companies/` | `--corpus` |
| `~/Library/Application Support/RichOS/loro-root` | `wiki/` + `loro/` | `--root` |
| `~/RichOS/corpus` | `ceo/` + `companies/` | `--corpus` |

They are **two different names rather than one name with a guess about its shape**, because
loro refuses `--corpus` for a corpus that sits inside a git checkout and says so in those
words — resolving the wrong flag would be `exit 2` on every rotation, forever.

**Nothing creates either pointer.** Not the app, not the bundler, not an installer — there
is no installer. It is an operator act, exactly like the engine's own install pointer, and a
machine without one boots saying what it looked for:

```
[richos] loro Tier C: no corpus configured — re-primes carry no company memory
[richos] loro Tier C: tried .../RichOS/corpus — not present
[richos] loro Tier C: tried .../RichOS/loro-root — not present
[richos] loro Tier C: tried /Users/alex/RichOS/corpus — not present
```

And nothing here is ever derived from the executable, the working directory or the engine
directory. Inferring the corpus from the checkout the binary sits in is the one inference
`CONTEXT-CONTRACT.md` §1 names as a larger failure than an error.
- `RICHOS_LORO_LANES` — optional, `entity=lane,entity=lane`. Maps an ECS entity area onto a
  loro company partition. **It is a map, never a rule** — name equality is not a mapping,
  an entity with no lane reads the CEO layer and nothing else, and a slice carrying another
  company's item is refused whole. It defaults to each registered entity mapped to a lane
  of the same name, which is an ENUMERATION of the registry rather than a pattern: an id
  that is not registered gets no lane however much it looks like one, and a lane keyed by
  an unregistered id is refused at boot as the typo it is. Setting this wins outright,
  including setting it empty, which turns lane narrowing off.

  **Every lane is reconciled against the corpus before anything is sent.** A mapping is a
  claim that a partition exists, and loro refuses a lane it does not have — `exit 2: no
  such company partition "x" in this corpus` — which would make every re-prime
  `Unavailable`. So at boot the app asks the corpus which partitions it actually has
  (`loro-context.mjs corpus`, ~0.06 s), drops every mapping the corpus cannot satisfy, and
  names each drop on stderr. A failed probe leaves the map exactly as configured; it is
  never read as "no partitions", because those are different facts.

  **When the corpus has partitions and an entity is bound to none of them**, its compile
  widens, loro returns every lane, and the cross-entity guard refuses the slice whole —
  fail-closed and correct, and it reaches the CEO as "loro could not be consulted" every
  turn. Boot says so by name.

  **When the corpus is one repository's own record** (`layout: repo` — no partitions,
  `company: null` on every item), the lane map has nothing to narrow and the guard has
  nothing to refuse, and a thread bound to a different entity would silently receive that
  product's record under a `COMPANY MEMORY` heading. The registry names the owner from the
  corpus's own root, and every other entity's slice is prefixed with one sentence saying
  whose record it is. The owner's own slices are untouched, and an unowned root leaves the
  owner unstated rather than guessed.
- `RICHOS_NODE_BIN` — optional; the `node` used to run the two loro entry points.

See it end to end without launching the app:

```bash
cargo run -p richos-core --example loro_reprime_demo -- "what did we decide about X?"
cargo run -p richos-core --example loro_correction_demo   # provisions its own throwaway corpus
```

## What is proven vs pending

**Proven (live, 2026-08-24):** the round-trip through the full spine — CEO prompt
persisted crash-safe → re-prime identity injected → real Claude replies **as Rich** →
clean render. The Tauri shell builds into a real arm64 binary. `tests/spine_tests.rs` was
11 tests on the day this was written and is 12 now; the layout above carries the current
number, and `docs-claims.js` is what keeps it current.

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
against the real binary (`examples/rotation_roundtrip.rs` — a forced mid-conversation
rotation swaps the backing Claude session and the successor correctly recalls the prior
exchange purely via the re-prime payload). Company name, the assertiveness dial, and the
worker-status drill-down are also wired end-to-end (Tauri commands → `app/ui/main.js`).
Full detail + the honest gaps (loro Tier-C compiler still a seam contract, not built; no
attention-seam TRIGGER yet — only the persistence + UI-event seam) are in
the spine-seams + rotation brief, 2026-08-24.

**Machinery routing + retention, landed (2026-08-28):** every non-text agent frame is now
routed into a second event family (`rich://machinery`) and retained in a separate
per-thread, day-sharded journal, on ONE per-turn `seq` shared with the assistant text so
"he said X, then ran Y, then said Z" is reconstructible. Proven headless
(`tests/machinery_tests.rs`, 15 tests, driven by wire frames measured against the real
binary) and live (`examples/machinery_roundtrip.rs` — one real tool-using turn, 24 journal
lines projecting to 9 rows, positions 0..=34 used exactly once across both families; the run
is kept at `docs/verification/machinery-roundtrip-2026-08-28.txt`). The emission set the
routing is built against was measured first, not assumed:
`docs/verification/acp-emission-probe-2026-08-28.md`, and re-measured against the native
binary in `docs/verification/native-claude-stream-json-2026-08-31/` when §16 deleted the
adapter. Honest gaps: **retroactivity starts here and nothing earlier is recoverable**;
readable thinking text produces no data on either wire; between-turn updates were unrouted —
**CLOSED 2026-08-30, see below**; and there is no toggle, no renderer and no controls —
that is the rest of Phase 1 and it is deliberately not in this work.

**Between-turn traffic has somewhere to go (2026-08-30):** techy-mode §1.5's gap #1 —
*"the client delivers a frame only if `current_prompt` is `Some`; anything the agent emits
at session start or between turns hits no sink at all"* — is closed. The client keeps a
buffer and §1.5's `last_session_meta` slot (last value wins, so a byte-identical repeat is
suppressed rather than journaled once per turn forever); the spine drains it at every turn
boundary and on every technical-view open, stamping `turn_id: None` — the records attach to
the THREAD, because inventing a turn for them would be a false attribution. They render in
their own section under the conversation, never inside it, since a record with no turn has
no position in the conversation to be drawn at.

The standing order is held by an ORDERING RULE rather than by an argument about which
vendor kinds might give a rotation away: the lane is drained as honest traffic BEFORE an
internal turn starts and as `internal: true` immediately after one finishes, so a re-prime,
a handoff or a successor's residue can never render. Proven against a real child process
(`tests/between_turn_tests.rs`, 3 tests; `tests/between_turn_thread_tests.rs`, 6 tests
end to end through `NativeCognition`) and on the rendered surface (`app/ui/tests/techy.js`
checks 18-21, shots `3-1-08` and `3-1-09`).

Honest gaps that remain: the buffer is bounded at 256 items and an overflow is reported as
a marker record rather than kept; `agent_message_chunk` arriving between turns is retained
as an untyped record because there is no turn to attach text to; and the lane is a RELOAD
path like the rest of techy mode, not a live stream.

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
to name in the open-source license audit). It is bit-transparent while Rich is silent — with a
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
`SpeechSynth`, and the rest of packaging — a NOTARIZED bundle (blocked on CEO decision
1.1, no signing identity exists), the bundled Node + adapter + whisper + models (see the
voice brief's size table), and an auto-update channel. The entrypoint itself now exists
and produces a verified ad-hoc bundle: "Packaging" above. See the feasibility notes in
the handoffs.

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
