# Candidate .6's follow-ups: one notice for one cause, provenance on the ledger, and a diagnostic that admits when it measured nothing

**Date:** 2026-09-17 (work carried into the small hours of 2026-09-18)
**Engineer:** Echo (`echo-opus-notices1`)
**Worktree:** `/Users/alex/ab/richos-wt/echo-opus-notices1`, branch `cc/echo-opus-notices1`
**Base:** `7c37fea65` (merge-base with `main`)
**Commits, oldest first:** `6ae4ef52`, `267138cf`, `54ae963f`
**Input:** Ray's candidate-.6 on-screen walk,
`docs/verification/2026-09-17-nightly-1.2.0-20260917.6-onscreen-audit.md` (READY, published),
defects 1, 3 and 4; and the voice pipeline's own handoff at richos `c712ccd5`.

## LIVE PLAYBACKS: 0

Nothing here made a sound. `RICHOS_VOICE_LIVE_AUDIO` was never set in this session — the
environment was checked, not assumed — and all four audible tests stayed `ignored` in every run:

```
test controller::tests::live_barge_in_actually_silences_the_real_output_device ... ignored, LIVE AUDIO: audible, ~1 s out of the speakers. RICHOS_VOICE_LIVE_AUDIO=1 to run.
test controller::tests::live_injected_audio_completes_the_whole_local_loop ... ignored, LIVE AUDIO: needs an output device AND whisper.cpp. RICHOS_VOICE_LIVE_AUDIO=1 to run.
test controller::tests::live_a_silent_channel_produces_no_turn_and_a_real_utterance_still_does ... ignored, LIVE AUDIO: needs an output device AND whisper.cpp, ~20 s. RICHOS_VOICE_LIVE_AUDIO=1 to run.
test playout::tests::live_macos_output_device_drains_the_queue ... ignored, LIVE AUDIO: opens the real output device. RICHOS_VOICE_LIVE_AUDIO=1 to run.
```

`examples/aec_live`, `aec_capture` and `aec_probe` were not run. The installed app was not
launched, `~/RichOS` and `~/.richos-signing` were not touched, and `nightly-local.py` was not
run. Every claim below is from source, from a unit test, or from Ray's committed record.

**No CEO-facing string changed.** The state registry's `s:` keys are byte-identical; only `why`
rationale prose naming a type that no longer exists was corrected. **No color, size or UI
surface changed**, so there is no new contrast ratio to compute — the four notice cards keep the
values Ray already measured and passed (body text 18.07:1 dark / light, accent bar 5.42:1
against the page, `…-20260917.6-onscreen-audit.md` §contrast). No contrast exemption is claimed
here.

---

## 1. Defect 1 — three notice cards on one silence become one

### Two premises in the brief did not survive source, and both were load-bearing

Raised as `esc-20260917T225154Z-a11992d7`; the lead has answered both.

**(a) "Never the 'heard no voice' or 'didn't catch that' cards for audio that was discarded as
Rich's own echo" describes something that already cannot happen.** Read from source:

| step | file | what it does |
|---|---|---|
| 1 | `richos-voice/src/controller.rs`, `CaptureBrain::push_residual` | on the tainted branch it pushes `CapMsg::Discarded { tainted: true }` and **drops** the `Utterance` value |
| 2 | same file, `supervise`'s `Discarded` arm | never touches `utt_tx`; only the `Utterance` arm sends |
| 3 | same file, recognizer thread | `RecognizerDesk::handle` is reachable **only** through `utt_rx` |
| 4 | same file | `HeardNoVoice` and `DidNotCatchThat` have exactly two emission sites, both inside `handle` |

So echo-discarded audio can never reach whisper and can never raise either notice. Implementing
the brief literally would have suppressed nothing.

Pinned by `echo_discarded_audio_can_never_raise_a_recognizer_notice`, which drives the real
`CaptureBrain` over 120 loud frames with Rich audible and no canceller confidence and asserts
`admitted == 0`; and by its positive control
`the_same_audio_with_rich_silent_is_admitted_and_does_reach_the_recognizer`, so the assertion
cannot pass on a brain that admits nothing at all.

**What actually produced cards 2 and 3** is the defect audit-5 filed as its own #8 — *"One
non-speech sound produced two notice cards, back to back"* — an utterance the app **admitted**
(so Rich was not audible for it) refused by the pre-whisper gate, and its successor refused by
the post-whisper filter. Ray says exactly this himself in the .6 audit: *"the double notice card
on one non-speech sound (it is cards 2 and 3 of defect 1)"*. Card 1 is the echo discard.

**(b) Ray's attribution for the OTHER half of defect 1 does not survive source either.** He
writes that observation C produced zero cards *"because all three notice latches had already
been spent in observation A"*. His own log line is `NO utterance START logged for it at all`. No
utterance means no notice path was entered and **no latch was consulted**. That half is an onset
defect, not a notice defect, and nothing in this work touches it. See §4.

### The fix: one budget, and a sentence may only be replaced by a strictly stronger one

`HalfDuplexNotice` becomes `RefusalNotices`, created once in `VoiceController::start` and handed
to **both** emitters as `Arc<Mutex<_>>` — because the two genuinely run on different threads,
which is why they had never been introduced.

```text
  authority   sentence                        scope
  3           CouldNotListenWhileSpeaking     the room and the hardware; a standing property
  2           SoundButNoWords                 a RUN of refusals; stronger than any single one
  1           HeardNoVoice, DidNotCatchThat   one refusal, pre- or post-whisper
```

- **Equal rank never replaces** what is standing. That is the double-card fix on its own.
- **Lower rank never replaces** it. That is the third card.
- **The deliberate 1 → 2 escalation still happens, exactly once** — which is why this is a
  pecking order and not a flat one-per-session budget, and why
  `a_run_of_discards_speaks_once_then_escalates_once_and_never_both_at_once` still passes
  unchanged.
- `ReplyCutOff` is **not a member and no method accepts it**. It describes the answer dying
  rather than audio being refused, it is the one notice SPOKEN as well as shown, and a budget an
  echo discard can spend must never be able to silence the line he hears with his ears.

Recovery is narrowed and that is part of the fix: `handle` used to clear the `HeardNoVoice` latch
the moment a voice was measured, *before whisper ran*. When whisper then returned `[BLANK_AUDIO]`,
the cleared latch plus `DidNotCatchThat`'s own latch gave two cards for one noise. Recovery is now
an utterance **admitted AND understood**. The session-scoped half-duplex latch is still never
cleared, for the reason in its own doc comment.

### The replay: 3 → 1

Ray's observation-A sequence, run on the real `RecognizerDesk` with the real `VoiceEvidence` gate
and the supervisor's emitter reproduced verbatim from its own arm. Both channels are counted
together — `HeardNoVoice` rides `rich://voice-error` and the other two ride
`rich://voice-notice`, and counting one channel is how this was missed once already.

| step | what happens | BEFORE (three budgets) | AFTER (one budget) |
|---|---|---|---|
| 1 | the CEO speaks, admitted, becomes a turn | 0 cards | 0 cards |
| 2 | Rich answers; a tainted discard inside the audible window | **+1** `CouldNotListenWhileSpeaking` | **+1** `CouldNotListenWhileSpeaking` |
| 3 | an admitted utterance carrying no voice (pre-whisper gate) | **+1** `HeardNoVoice` | +0 — outranked |
| 4 | an admitted utterance, whisper returns `[BLANK_AUDIO]` | **+1** `DidNotCatchThat` | +0 — outranked |
| | **total a person sees** | **3** | **1** |

`three_independent_budgets_are_what_produced_three_cards` holds the BEFORE column as a fact
rather than a claim: three separate `RefusalNotices` say all three lines, one says one. Without
it, `rays_first_spoken_answer_produces_exactly_one_notice_card` would pass equally well on an
implementation that had simply gone silent.

```
$ cargo test -p richos-voice --lib -- --exact <the seven notice tests>
running 7 tests
test controller::tests::a_second_voice_session_says_the_half_duplex_line_again ... ok
test controller::tests::the_stronger_line_still_takes_over_from_the_short_one_exactly_once ... ok
test controller::tests::three_independent_budgets_are_what_produced_three_cards ... ok
test controller::tests::echo_discarded_audio_can_never_raise_a_recognizer_notice ... ok
test controller::tests::the_same_audio_with_rich_silent_is_admitted_and_does_reach_the_recognizer ... ok
test controller::tests::a_genuine_admitted_non_speech_utterance_still_says_its_one_line ... ok
test controller::tests::rays_first_spoken_answer_produces_exactly_one_notice_card ... ok

test result: ok. 7 passed; 0 failed; 0 ignored; 0 measured; 236 filtered out; finished in 0.25s
```

The positive controls the brief asked for, by name:
`a_genuine_admitted_non_speech_utterance_still_says_its_one_line` (a real refusal still gets its
card — this is not "switch the notices off") and
`a_second_voice_session_says_the_half_duplex_line_again` (session-scoped, not once-per-install).

---

## 2. Provenance on `PromptReceived`, end to end

`Event::PromptReceived` gains `rich_audible: Option<bool>` with `#[serde(default,
skip_serializing_if = "Option::is_none")]`, and `Turn` projects it.

```text
  None         NOT RECORDED. Every typed turn, every turn written before the field existed,
               every proactive turn. NEVER read as "no".
  Some(false)  measured: Rich's audible window was CLOSED for the whole recording.
  Some(true)   measured: it was OPEN during some part of it.
```

**`Option<bool>` and not `bool`, for exactly the reason slice 3b declined an always-`None`
field.** A defaulting `bool` is worse than the gap it closes: every historical record would
deserialize to `false`, silently asserting that Rich was *provably silent* during audio nobody
measured.

**`Some(true)` is not "this is echo."** A turn reaches this field only by being ADMITTED, and the
two ways an admitted utterance can have been recorded while Rich was audible are the two escapes
in the taint rule `tainted = echo_is_in_the_recording && !barged && !confident`: a barge-in (the
CEO deliberately talking over him) and a confident canceller. Both are genuine turns. Which is
also why the flag **cannot be derived from `tainted`** — a barge-in sets `tainted` to false on
audio Rich was audible for, and that is precisely the turn a later investigation would ask about.

Written at the two points taint is, and with the frame math re-derived rather than quoted:

```text
  ECHO_LOOKBACK_FRAMES = PRE_ROLL_FRAMES + SPEECH_ONSET_FRAMES = 19 + 7 = 26 frames
  26 x 256 / 16000 = 6656 / 16000 = 0.416 s exactly
```

The wire: `CapMsg::Started { tainted, rich_audible }` → `CapMsg::Utterance(Box<AdmittedUtterance>)`
→ `RecognizerDesk::handle` → `submit: FnOnce(String, bool)` → the serialized `(String, bool)` hop
→ `VoiceController::start`'s `Arc<dyn Fn(String, bool) + Send + Sync>` →
`src-tauri/src/main.rs`'s voice closure → `Spine::submit_prompt_spoken` →
`Ledger::record_prompt_received_spoken`.

`record_prompt_received_spoken` / `submit_prompt_spoken` are **separate entry points, not extra
arguments**, so a typed turn writes `None` by construction rather than by somebody remembering to.

The two operator log lines carry it as well — `utterance START tainted=.. heard-rich=..` and
`utterance END ADMITTED — N s, heard-rich=..` — so a future walk can line the ledger's field up
against the capture path's own record of the same instant.

```
$ cargo test -p richos-core --test ledger_forward_compat_tests
test an_old_ledger_loads_with_no_provenance_claim_at_all ... ok
test a_spoken_turn_records_its_provenance_and_a_typed_turn_records_none ... ok
test result: ok. 27 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.05s
```

The forward-compat test checks its own premise before asserting anything: the committed
`v1-current.jsonl` fixture does not contain the string `rich_audible`, and it does contain at
least one `"source":"jam"` record. Every projected turn then reads `None`, never `Some(false)`.
The round-trip test proves a typed turn's line does not contain the string `rich_audible` at all,
so its bytes are what they were before the field existed. Every golden is unchanged.

### One finding worth keeping, measured while writing those tests

**A "tap to stop" pressed in SILENCE clears `barged` on the same frame.** The onset takes
`SPEECH_ONSET_FRAMES` = 7 frames to confirm, so `recording` is still false and the chain's last
arm (`!speaking && !recording`) forgets the interruption. The first version of the test asserted
an admitted utterance and got `Discarded { tainted: true }` instead. The tests now land the tap
mid-utterance, which is both the reachable shape and the realistic one. Not filed as a defect —
whether tapping the control in silence *should* pre-clear taint for the sentence that follows is
a product question, not a bug I can settle from here — but it is written beside the test that
found it.

---

## 3. Defects 3 and 4 — the diagnostic says what it measured, and a session prints both ends

Defect 3's `erle=0.0 dB, residual 0.0 dBFS` was **two separate sentinels**, both read off source:

| figure | why it was `0.0` | the flag that now says so |
|---|---|---|
| ERLE | `EchoCanceller::erle_db()` returns a hard `0.0` while `d_power_smooth <= 1e-12 \|\| e_power_smooth <= 1e-12`, and those accumulate **only** on far-end-active unfrozen blocks | `AecMetrics::erle_measured`, which **is** that condition, exposed as `erle_measured()` and called by `erle_db()` itself |
| residual | `residual_typ_rms` starts at `1.0` and stays there until the first far-active block seeds it. `20*log10(1.0)` = **0.0 dBFS — full scale** | `AecMetrics::leak_measured`, which **is** `residual_seeded` |

So `0.0 dB` meant either *"removing exactly nothing"* — a real, measured state on the CEO's rig,
−0.5 … +0.7 dB — or *"nothing has been measured"*, and the log printed the same three characters
for both.

**Why candidate .5 printed real numbers and .6 did not: the same widening that fixed the
blocker.** `speaking` became the whole `AudibleWindow` rather than the playout queue's depth, so
.6's discards happen in the eighteen synthesis gaps and in the 14.3 s past the model's end —
where no reference audio is flowing, the far end is inactive, and neither accumulator has
anything to add. The figure did not get worse; the moments being reported moved to where there
was no figure.

`AecShared::erle_db()` and `leak_dbfs()` now return `Option<f32>`, so a caller **cannot** print
a sentinel by accident, and `measured_or_not(v, unit)` is the single formatting rule.

Defect 4: the session-start line is stamped with `wall_clock_utc()`, and a `SessionLog` **Drop
guard** prints one closing line on every path out of `supervise`. A Drop guard rather than a
statement at the bottom, because `supervise` has two exits — the `while` condition, and an early
`return` on `TryRecvError::Disconnected` — and the second is the one that fires when the audio
device disappears, which is the session end most worth a line.

```
$ cargo test -p richos-voice --lib -- --exact <the six diagnostic and provenance tests>
running 6 tests
test controller::tests::the_session_span_reads_as_minutes_seconds_milliseconds ... ok
test controller::tests::an_unmeasured_canceller_says_not_measured_and_never_zero ... ok
test controller::tests::rich_becoming_audible_mid_utterance_is_recorded_even_when_taint_is_cleared ... ok
test controller::tests::an_admitted_utterance_records_whether_rich_was_audible_for_it ... ok
test controller::tests::the_provenance_travels_with_the_words_to_the_submit_callback ... ok
test controller::tests::the_cancellers_own_measured_flags_start_false_and_become_true ... ok

test result: ok. 6 passed; 0 failed; 0 ignored; 0 measured; 237 filtered out; finished in 0.23s
```

`an_unmeasured_canceller_says_not_measured_and_never_zero` carries the control that stops this
being "suppress zeros": a canceller that has **genuinely** measured 0.0 dB and a full-scale
residual still prints `0.0 dB` / `0.0 dBFS`. `the_session_span_reads_as_minutes_seconds_milliseconds`
re-derives its arithmetic rather than trusting it — 62 317 ms = 60 000 + 2 317 → `1:02.317`;
3 599 999 → `59:59.999` and 3 600 000 → `60:00.000`, so minutes do not wrap at 60.

---

## 4. NOT fixed here, and what a tomorrow-engineer should reproduce FIRST

**Ray's observation C: he genuinely talked over Rich at `21:35:01.262Z` and was told nothing.**
His log line is the whole diagnosis — `NO utterance START logged for it at all`. The endpointer
never registered an onset while Rich was mid-chunk, so nothing in the notice layer was reached.
Per the lead, this gets its own voice task with audio; it is deliberately untouched tonight.

**Reproduce this before changing anything:** with output volume at 85 and the Wave:3 in, start a
spoken turn, then speak over Rich mid-answer and confirm from the operator log that **no
`utterance START` line appears at all** for that speech. That is the observation to hold. Only
then is the question answerable, and the question is which of three gates ate the onset:

1. the **VAD**, whose adaptive noise floor has been climbing through Rich's own audible echo for
   the length of the answer — the near-end talker may simply not clear it any more;
2. the **barge-in monitor's 5.008 s consecutive debounce** (`313 × 256 ÷ 16000 = 5.008 s`,
   re-derived), which is in force for the whole answer because the canceller never reaches
   confidence on this hardware — Ray's talk-over ran `21:35:01.262` to `21:35:05`, i.e. roughly
   4 s, **under** it;
3. the **endpointer's own onset**, `SPEECH_ONSET_FRAMES` = 7 frames = `7 × 256 ÷ 16000` =
   **0.112 s** of confirmed speech.

Gates 1 and 3 decide whether an `utterance START` is ever printed; gate 2 decides only whether
Rich is cut off. Since the missing artifact is the START line, **1 and 3 are where to look and 2
is not** — which is worth saying plainly, because the debounce is the number everybody reaches
for. Measure the VAD's `last_rms` and its adapted threshold across an answer before touching
either constant.

**Also still open and untouched here:** reference-signal-gated echo suppression. The canceller is
marginal on the CEO's hardware by measurement, not by opinion — coherence caps any linear filter
at 4.3 dB full band on that path — and no primitive for the real fix exists in this crate. Every
honest fallback in this work assumes it stays that way.

---

## Suite tails

```
$ cargo test -p richos-voice
test result: ok. 239 passed; 0 failed; 4 ignored; 0 measured; 0 filtered out; finished in 21.51s
test result: ok. 17 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 2.15s
test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.57s
test result: ok. 23 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.04s
test result: ok. 14 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 1.98s
test result: ok. 4 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 13.48s
test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
```

299 passed, 0 failed, 4 ignored (all four the audible tests quoted at the top). Baseline before
this work: 286 passed.

```
$ cargo test -p richos-core
54 test binaries, all ok: 1210 passed, 0 failed, 4 ignored
```

```
$ cd app/src-tauri && cargo check
warning: `richos-tauri` (bin "richos-tauri") generated 4 warnings
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 2.55s
```

The four warnings are pre-existing dead code (`activation.rs:346`, `activation.rs:348`,
`lifecycle.rs:70`, `nav.rs:145`); none is from this change. `cargo build -p richos-voice
--examples` is clean. `cargo doc -p richos-voice --no-deps` introduces no UNRESOLVED link; the
three doc references this work adds (`[`supervise`]`, `[`CaptureBrain::push_residual`]`) do raise
"public documentation links to private item", which is the same class of warning five pre-existing
links in this crate already raise and not a broken link.

**The `app/ui` runner:** `playwright` is not installed in this worktree, so 47 of 49 suites fail
identically — including suites nothing here touches — and that is an environment gap, not a
result. Pointing `RICHOS_PLAYWRIGHT` at the main checkout's install, the two suites that matter
here both pass: `affordances.js` (which consumes `tests/lib/state-registry.js`, the one UI file
this work edits) and `dialect.js`. The registry edit changes only `why` rationale prose that
named the replaced type; no `s:` key moved.
