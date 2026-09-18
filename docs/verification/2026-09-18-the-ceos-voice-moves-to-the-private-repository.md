# 2026-09-18 — the recording of the CEO's voice moves to the private repository

**What changed, in one paragraph.** The barge-in fix of 2026-09-18 is pinned on three recordings of
the CEO's own rig, and one of them — `ceo-rig-2026-09-18-nearend2-mic.wav`, the microphone track of
the double-talk capture — has the CEO audibly speaking in it. `richos` is a public repository and
nothing carrying his own voice goes into one, so that single file is committed to the private
`richos-hq` repository at `fixtures/echo-path/` instead, byte-identical
(`sha256 786adf8073d0eee99b5a1d639abc5f459e2f6c1284188ab33d75ba8c1f93cfe3`, 793,132 bytes). The
other six files of that fixture family stay here. The tests that need the private track resolve it
through `$RICHOS_PRIVATE_FIXTURES` or a side-by-side `richos-hq` checkout, and report
`ignored, PRIVATE FIXTURE: …` — never `ok` — when it is absent. The false-positive test, which is
the side the CEO has ruled matters more, needs no private file and runs everywhere.

## What stayed, and why keeping it is safe — measured, not assumed

Six files stayed in this repository. The claim that none of them carries his voice is load-bearing,
so it was re-derived here rather than read off the sidecars that assert it.

### The two echo-only microphone tracks

Per-256-sample-frame RMS, in dBFS. His speech in the private track measures -18.1 dBFS pooled over
his five intervals; a near-field voice cannot hide below that for long.

| file | in tree | frames | p50 | p90 | p99 | **max** | frames > -30 dBFS |
|---|---|---|---|---|---|---|---|
| `ceo-rig-2026-09-18-nearend-mic.wav` | public | 1598 | -48.6 | -43.2 | -40.2 | **-37.4** | **0** |
| `ceo-rig-2026-09-17-mic.wav` | public | 596 | -48.9 | -42.8 | -40.3 | **-37.6** | **0** |
| `ceo-rig-2026-09-18-nearend2-mic.wav` | **private** | 1549 | -45.8 | -19.8 | -12.8 | **-10.7** | **306** |

The two public microphone tracks have **not one frame** above -30 dBFS, and their loudest single
16 ms frame sits 26.7 dB and 26.9 dB below the private track's loudest. The private recording has
306 frames above -30 dBFS. There is no near-field voice in either public track, which is the
property that made them publishable in the first place — they are the echo-only recordings the
false-positive side of this whole decision is measured on.

### `ceo-rig-2026-09-18-nearend2-reference.wav` — the other half of HIS pair

This one needed the most care, because it is the partner of the file being withheld. It is the
signal that went to the DAC rather than a microphone capture, so by construction nothing from the
room is in it — but "by construction" is an argument, not a measurement.

Both runs played the same 81-word passage, with playback leads of 1.500 s and 0.700 s. If run 2's
reference is that same synthetic passage, it must match run 1's reference at an offset of exactly
0.800 s = 12,800 samples.

```text
  alignment search over +/-2000 samples   global minimum at offset 12800 (800.0 ms)
  run2_reference minus run1_reference     residual  -37.5 dBFS
  run2_reference itself                   signal    -19.1 dBFS
```

And the decisive part — **where that residual lives**. A voice leaking into this track would spike
inside the five intervals where he actually speaks:

| his interval (s) | mic, private | reference residual | reference signal |
|---|---|---|---|
| 3.568 .. 5.472 | -17.8 | -37.6 | -18.5 |
| 6.256 .. 7.360 | -20.7 | -37.5 | -22.8 |
| 14.320 .. 15.152 | -16.8 | -35.8 | -19.2 |
| 16.384 .. 16.672 | -15.3 | -38.8 | -20.2 |
| 20.912 .. 21.664 | -19.3 | -39.5 | -19.4 |
| **all intervals pooled** | **-18.1** | **-37.5** | |
| **everywhere else** | | **-37.5** | |

The residual is **flat: a difference of -0.0 dB** between the frames where he speaks and every other
frame. It is a uniform render/resample difference between two `say` invocations, not a voice. He is
not in this file.

### The sidecars

`-nearend2-nearend.json` states of itself that *"his words are not transcribed, stored or committed
anywhere"*, and that is true of its contents: five intervals in seconds, two RMS levels, and the
derivation of both. `-nearend-session.json` and `-nearend2-session.json` carry device labels, rates,
UTC instants and the operator-reported output volume. No words.

## The three numbers the record stands on, re-derived from the WAV files

Independently recomputed from the audio, not quoted from the sidecar:

```text
  his level at the microphone         -18.1 dBFS   record says -18.1   MATCH
  echo-only level, same rig/volume    -46.7 dBFS   record says -46.7   MATCH
  he arrives above Rich's echo by      28.6 dB     record says  28.6   MATCH
  his speech total                     4.880 s     record says  4.880  MATCH
  intervals                            5           record says  five   MATCH
```

They stand. They are numbers, and numbers are not his words.

## One number that did NOT stand: the sidecar said 299 frames, and it is 305

`-nearend2-nearend.json` carried `"near_end_frames_at_16ms": 299`. Every interval it publishes is a
whole number of 256-sample frames:

```text
  3.568..5.472   1.904 s   119 frames
  6.256..7.360   1.104 s    69
  14.320..15.152 0.832 s    52
  16.384..16.672 0.288 s    18
  20.912..21.664 0.752 s    47
                          ---
                          305 frames,  305 x 256 / 16000 = 4.880 s
```

No interval boundary falls mid-frame, so both plausible conventions — `duration / 0.016` and
"frames fully contained in the interval" — give 305. 299 gives 4.784 s, which contradicts the
`near_end_total_secs: 4.880` in the same file.

**It was load-bearing on nothing:** a grep of `src/`, `tests/` and `examples/` returns the sidecar
line and nothing else, because the tests derive everything from `near_end_intervals_secs`. The
separate "205 of 1441 frames exceed the baseline maximum" figure is a different quantity (frames
above a threshold, before bridging) and is unaffected. Corrected to 305 with the arithmetic stated
in the field itself, and now pinned in
`tests/barge_in_on_the_ceos_rig.rs::every_duration_in_this_file_is_the_frame_math`, which asserts
each interval is a whole number of frames and that they sum to 305.

## How the split works

`crates/richos-voice/src/private_fixtures.rs` is the single resolver, compiled twice — the crate
compiles it, and `build.rs` pulls the same file in with `#[path]` — so the compile-time decision
and the run-time file open cannot drift apart.

1. `$RICHOS_PRIVATE_FIXTURES`, a directory. **This is the form a git worktree must use**, because a
   worktree's parent is not the directory option 2 assumes.
2. `<repo-root>/../richos-hq/fixtures/echo-path`, the side-by-side checkout layout, no configuration.

The repository root is found by walking up to the first `.git` **entry** — a directory in a clone, a
file in a worktree.

### Why the absence is `ignored` and not an early `return`

The brief asked for a skip with a printed reason. The literal implementation — `if !exists { return; }`
at the top of the test — is the exact defect this crate's `build.rs` was written to delete, and its
header says so in its first line: **"A TEST THAT DID NOT RUN MUST NOT PRINT `ok`."** Four live-audio
tests here were green lines asserting nothing until 2026-09-18 for precisely that reason. Worse,
`cargo test` suppresses a passing test's stdout, so the printed reason would not have been visible
at all without `--nocapture`.

So availability becomes a cfg in `build.rs` and the test carries
`#[cfg_attr(not(private_fixtures), ignore = "…")]`. libtest prints the reason in the **default**
output and counts it in its own `N ignored` column. `#[ignore]` suppresses the run and not the body,
so `require_ceo_mic_track()` is the test's first statement and panics with the full reason if
`--include-ignored` reaches it — the same positive-guard pattern `live_audio::require_opt_in()`
already uses here.

`examples/bargein_score.rs` resolves identically but **exits 2** rather than skipping. A test that
skips is reported and counted; a harness an operator invoked, which scored nothing, must not exit 0.

### The limitation, named

`rerun-if-env-changed` puts `RICHOS_PRIVATE_FIXTURES` in the build script's fingerprint, so setting
or unsetting it re-decides the cfg. A **file appearing** is not a variable: the deepest existing
ancestor of each candidate path is watched with `rerun-if-changed`, which covers cloning `richos-hq`
beside `richos` and creating `fixtures/echo-path` inside an existing one. It is not a proof. If a
run says `ignored` when you believe the file is there, `touch build.rs` and run it again. Erring
toward `ignored` is the safe direction — it under-claims, and a false `ok` is the thing being
prevented.

## Both runs, as evidence

```text
$ cargo test -p richos-voice --release --test barge_in_on_the_ceos_rig
  (RICHOS_PRIVATE_FIXTURES unset, no richos-hq beside this worktree)

running 3 tests
test the_ceos_own_voice_over_rich_interrupts_him_and_his_words_are_kept ... ignored,
  PRIVATE FIXTURE: ceo-rig-2026-09-18-nearend2-mic.wav is a recording of the CEO's own
  voice and is not committed to this public repository. It is in the private richos-hq
  repository at fixtures/echo-path/. Set RICHOS_PRIVATE_FIXTURES to that directory to
  run this.
test every_duration_in_this_file_is_the_frame_math ... ok
test richs_own_echo_never_interrupts_him_at_any_volume ... ok

test result: ok. 2 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out
```

```text
$ RICHOS_PRIVATE_FIXTURES=<richos-hq>/fixtures/echo-path \
    cargo test -p richos-voice --release --test barge_in_on_the_ceos_rig -- --nocapture

[fixture] the CEO's microphone track, private: …/fixtures/echo-path/ceo-rig-2026-09-18-nearend2-mic.wav
[measured] the CEO at the microphone -18.1 dBFS over 4.880 s in 5 intervals; Rich's echo
           alone on the same rig, same volume, same passage -46.7 dBFS; separation 28.6 dB
[measured] the full pipeline over his recording: Outcome { starts: 4, barge_ins: 1,
           admitted: 1, tainted_discards: 3, first_barge_frame: Some(234),
           confident_ever: false, mode_ever_consecutive: false }
[measured] first barge-in at 3.744 s; his marked speech opens at 3.568 s
[measured] barge-in 0.176 s after his marked speech opens
[control]  the same recording with a -22.0 dBFS near-field voice at 12.0 s: barge_ins: 1

test result: ok. 3 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
```

### The whole crate, both ways

`cargo test -p richos-voice --release`, per test binary. The only cell that differs between the two
columns is the one that should:

| binary | private fixture ABSENT | private fixture PRESENT |
|---|---|---|
| `unittests src/lib.rs` | 244 passed, 0 failed, 4 ignored | 244 passed, 0 failed, 4 ignored |
| `barge_in_composition` | 17 passed, 0 failed | 17 passed, 0 failed |
| **`barge_in_on_the_ceos_rig`** | **2 passed, 0 failed, 1 ignored** | **3 passed, 0 failed, 0 ignored** |
| `echo_path_replay` | 2 passed, 0 failed | 2 passed, 0 failed |
| `model_provisioning` | 23 passed, 0 failed | 23 passed, 0 failed |
| `self_voice_replay` | 18 passed, 0 failed | 18 passed, 0 failed |
| `voiced_acceptance` | 4 passed, 0 failed | 4 passed, 0 failed |

The 4 ignored in the lib binary are the pre-existing live-audio tests
(`RICHOS_VOICE_LIVE_AUDIO=1` to run); they are unrelated to this change and unchanged by it.

`cargo check` in `src-tauri`: `Finished dev profile`, 4 pre-existing dead-code warnings in
`src/nav.rs`, none introduced here.

### The harness

```text
  --pair …/ceo-rig-2026-09-18-nearend2, no private fixture
    PRIVATE FIXTURE NOT ON THIS MACHINE: ceo-rig-2026-09-18-nearend2-mic.wav
    … Looked in: …/richos-hq/fixtures/echo-path/ceo-rig-2026-09-18-nearend2-mic.wav
    EXIT CODE = 2

  --pair …/ceo-rig-2026-09-18-nearend2, RICHOS_PRIVATE_FIXTURES set
    -mic.wav is not beside the pair; resolved privately: …/fixtures/echo-path/…-nearend2-mic.wav
    === barge-in scoring: …/ceo-rig-2026-09-18-nearend2 ===
      24.784 s, 1549 frames of 256 samples (16.000 ms each), NO audio played
      near-end intervals: 5 of them, 4.880 s of near-end voice in total
    EXIT CODE = 0
```

**The frame math is arithmetic a reader can check against that output, not a further claim about
it.** The run reports `first_barge_frame: Some(234)` and, separately, `3.744 s`. Those two are
consistent iff `234 × 256 ÷ 16000 = 3.744`, which holds exactly. The latency likewise:
`3.744 − 3.568 = 0.176 s`, and `11 × 256 ÷ 16000 = 0.176 s` exactly — 11 frames, which is FEWER
than the rule's own 15-frame (0.240 s) evidence requirement. That is not a short-circuit: the
interval marker claims only frames above the echo-only baseline's maximum, so it opens about four
frames after he actually starts, and a latency measured from a deliberately-late reference point
has no meaningful floor. The ceiling is what the test asserts, and it is what the CEO complained
about.

## What this does not prove

It does not prove the public fixtures are free of every kind of personal information — it proves no
near-field **voice** is in them, which is the thing that was at issue. It proves nothing about any
other recording, any other room, or any file added to these directories later; the rule for those is
in `richos-hq/fixtures/echo-path/README.md`. And it does not change one measurement the barge-in fix
rests on: the same bytes are opened by the same tests, from a different directory.

## No audio was played

Nothing in this work played a sound. Every measurement above is offline arithmetic over committed
WAV files, per the standing limitation (`richos-hq/wiki/ceo-decisions.md` §53): the Mac's own
speakers cannot stand in for a person at the microphone, which is exactly why the recording being
protected here had to be made with the CEO himself at the desk.
