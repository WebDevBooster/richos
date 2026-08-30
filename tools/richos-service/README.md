# RichOS local service — P1 (pipeline core + native host)

The native, no-network process that lives **outside** the browser. It is the surface-independent
spine of the call-transcription system architecture
(2026-08-24): one service, three capture
front-ends (extension today; Mac + Windows companions in P2/P3), **one capture→pipeline contract**,
one reliability model.

P1 delivers three things the MV3 extension structurally cannot do itself — run Whisper, write
outside Downloads, and watch the browser from outside it:

1. **Native-messaging host** — Chrome hands audio/health/caption/heartbeat/lifecycle messages to the
   local service over stdio; the host writes the contract directory **directly into the loro drop
   zone** and triggers the pipeline. Outside-the-browser watchdog + EOF finalization included.
2. **Drop-zone watcher + reconcile guard** — detects finished sessions and runs the pipeline; a
   captured session that yields no transcript is a **loud anomaly, never silent** (reuses the
   extension's `sync/reconcile.js` verbatim, plus a transcript-SLA and silent-capture guard).
3. **The transcription pipeline** — ffmpeg normalize → `whisper.cpp large-v3-turbo` per channel →
   merge + caption fold-in → loro-correction **seam** (identity pass in P1) → `transcript.md` +
   `verification.json` + idempotent ingest ledger; re-transcription on retained audio.

Everything stays local. No account, no cloud, no third-party ASR, no listening port.

---

## The frozen capture→pipeline contract (schemaVersion 2)

**This is the interface P2 (macOS companion) and P3 (Windows companion) target.** Every capture
surface writes ONE session directory into the loro drop zone in this exact shape; the pipeline
consumes only this and knows nothing about how the audio was captured.

```
wiki/raw/meetings/<sessionId>/
  session.json         written at call START (status "open"), rewritten "closed" at end
  audio-part-NN.<ext>  2-channel audio, one or more self-contained parts (Opus/WebM, Ogg, or WAV)
  health.ndjson        one JSON record per second (per-channel levels, byte growth, state)
  captions.ndjson      OPTIONAL — browser surfaces only; one line per caption revision
  transcript.md        written by the pipeline post-call (absent until then)
  verification.json    written by the pipeline (coverage, caption↔ASR agreement, dead intervals)
_ingest.jsonl          drop-zone-level ledger: one line per (sessionId, modelRun)
```

**Audio invariant (every surface MUST honor):** exactly **two channels, LEFT = me (microphone),
RIGHT = others (system/tab)**. Never a pre-mix — this gives free "me vs them" separation with no
diarization model, and lets the pipeline transcribe each channel independently. Codec is not
mandated (ffmpeg normalizes anything); sample rate ≥ 16 kHz; parts are self-contained. In-person
capture may put both voices on LEFT — the split degrades to single-channel gracefully.

**`session.json` v2 blocks** (added by `lib/contract.js#upgradeRecord`, which lifts a v1 extension
record without dropping a field):

- `capture.source` = `chrome-extension | desktop-companion-macos | desktop-companion-windows`
- `capture.method`, `capture.channels {left,right}`, `capture.captureTarget`, `capture.sampleRate`
- `ownership {ownerSurface, supersedes, processHint}` — the extension↔companion dedup handshake (P4)
- `pipeline {status, model, modelRuns[], ffmpegVersion, whisperVersion, loroCorrection{...}}` —
  written by the pipeline; `status` ∈ `pending | ready | anomaly | failed`; a `modelRuns` entry per
  transcription/re-transcription.

**Timestamps:** every artifact is keyed to **epoch ms anchored on `session.startedAt`**. Audio
segment offsets are relative to session start; `health`/`captions` lines carry an absolute `t`. No
timestamp, no merge.

---

## The pipeline (surface-independent core)

```
session dir (closed)
 1. RECONCILE GUARD   anomaly? → LOUD alarm, pipeline.status="anomaly", STOP.  (never silent)
 2. NORMALIZE         concat parts → channelsplit → me.wav / others.wav @ 16 kHz mono
      · silent-capture guard: both channels below −60 dBFS → anomaly (ASR-independent)
 3. TRANSCRIBE        whisper.cpp large-v3-turbo per channel, -oj -ojf timestamps (Metal)
      · -ojf adds per-TOKEN offsets. It is output verbosity, not a decode parameter (it sits
        outside whisperArgs() with -of), and it is required: without per-word times the deletion
        detector at 3.7 has to score coverage on segment extents, which is measurably wrong.
 3.5 HALLUCINATION GUARD  silence fabrication REMOVED; repetition loop / sliding stutter collapsed;
                      ordinal insertion DETECTED
 3.6 DIARIZATION SEAM     opt-in; default identity
 3.7 DELETION DETECTOR    speech bursts the transcript never claims, adjudicated by isolated
                      re-decode → DETECT-ONLY alarm (a deletion cannot be repaired here)
 3.8 WORD DENSITY         emitted words against the audio's physical speech budget — the class 3.7
                      scores as COVERED → DETECT-ONLY alarm (words missing, never "words wrong")
 4. MERGE             interleave by time; fold caption speaker NAMES onto far-side segments;
                      compute verification.json
 5. loro-CORRECTION   REAL corrector (P4): curated manglings + guarded fuzzy -> canonical, SAME
                      contract. Loads loro/entities.json by default; missing file => identity.
 6. EMIT              transcript.md + verification.json; pipeline.status="ready";
                      append _ingest.jsonl (idempotent); RETAIN audio for re-transcription
```

Default model **`large-v3-turbo`** per the model benchmark (2026-08-24):
~3.9 min per call-hour on the M4, ~2 GB RAM, zero hallucination at defaults.

**Never-silent reconciliation** — a captured call with no transcript is always *present* on disk and
always noticed: open session / no audio / captions-but-no-audio (reused from the extension); plus a
`closed` session past the transcript SLA with no `transcript.md`; plus a digitally-silent capture;
plus a trivial (≈empty) transcript. Every one flips `pipeline.status="anomaly"` and alarms.

---

## CLI

```
node bin/richos-service.js doctor                 # verify ffmpeg / whisper-cli / tier model resolve
node bin/richos-service.js watch [--zone dir] [--tier name]        # watcher: pipeline trigger + reconcile net
node bin/richos-service.js run <sessionId|dir> [--tier name]       # run the pipeline over one session
node bin/richos-service.js retranscribe <id> [--tier max]         # re-run on retained audio (P5 tier)
node bin/richos-service.js tiers                  # list the P5 model tiers (turbo default, max, ...)
node bin/richos-service.js reconcile [--zone dir] # report-only anomaly sweep (never transcribes)

# coordination (P4) — the shared, surface-agnostic ownership authority (§5.4)
node bin/richos-service.js claim --surface <s> --kind <browser-tab|system|process> \
     [--process-hint <h>] [--session-id <id>]   # own the call, or stand down (exit 3)? no double-capture
node bin/richos-service.js failover-scan          # browser-owned calls that went dark -> promotable
node bin/richos-service.js mark-superseded --dead <id> --by <id>   # close the failover loop

# the correction flywheel — ASK, NEVER INFER (ceo-decisions.md §7)
node bin/richos-service.js learn-term --canonical "Deepgram" --mangled "deep graham"  # explicit
node bin/richos-service.js learn-from-edits <id> [--apply]      # proposals from an edited transcript
node bin/richos-service.js correct-text --text "..."            # DICTATION reads the same vocabulary
node bin/richos-service.js dictation-review --sent "<what you sent>"   # produces ASKS; learns nothing
node bin/richos-service.js dictation-answer --from "<heard>" --to "<term>" (--confirm|--decline|--never)
node bin/richos-service.js dictation-asks                       # the inspectable suppression list
node bin/richos-service.js dictation-retention [--apply]        # what it costs, and what ages out
```

Env overrides: `RICHOS_DROP_ZONE`, `RICHOS_WHISPER_MODEL` / `RICHOS_MODEL_DIR`, `RICHOS_WHISPER_BIN`,
`RICHOS_FFMPEG_BIN`, `RICHOS_WHISPER_LANG`, `RICHOS_TRANSCRIPT_SLA_MS`, `RICHOS_ENTITIES_FILE`,
`RICHOS_DIARIZE` (P5 diarization method, default `none`), `RICHOS_DICTATION_JOURNAL`,
`RICHOS_DICTATION_TEXT_DAYS` / `_TEXT_RECORDS` / `_AUDIO_DAYS` / `_AUDIO_BYTES` (retention).

---

## Native-messaging host

```
host/native-host.js            the stdio host Chrome spawns (length-prefixed JSON)
host/com.richos.host.json       host-manifest template (name: com.richos.host)
host/install-host.sh <ext-id>  registers the manifest for every Chromium-family browser (macOS/Linux)
```

Install: `host/install-host.sh <your-unpacked-extension-id>` writes an absolute-path launcher and
drops the manifest into each `NativeMessagingHosts/` directory found. Uninstall: `--uninstall`.
Windows registry registration is a P3 packaging concern (a `.bat` launcher is provided so the
Windows path is not blocked on shared logic).

The extension client seam is `tools/richos-extension/core/native-host-client.js`: it connects to the
service and, **if the service is not running, falls back to the Downloads path unchanged** — capture
never depends on the service being installed.

---

## Testing (all run on this Mac; whisper.cpp + model already present)

```
node test/run.js         # pure logic: contract, reconcile, merge, verify, correction seam, stdio,
                         #   host handlers, ledger, parsers, hallucination guard, DELETION detector
                         #   — no ffmpeg/whisper/browser (142 tests)
node test/e2e.mjs        # REAL: build a 2-channel `say` sample → full pipeline → transcript.md;
                         #   proves caption fold-in, re-transcribe, captions-only + silent anomalies
node test/host-e2e.mjs   # REAL: speak Chrome's native-messaging protocol to the host process →
                         #   streamed audio lands byte-exact → pipeline triggered → transcript.md
node test/coordination-e2e.mjs  # REAL CLI + drop zone: extension owns a call, companion STANDS
                         #   DOWN (one session, no double); browser crash → companion PROMOTES
node test/accuracy-tier-e2e.mjs # REAL: quantized tier + turbo default + (if installed) guarded
                         #   large-v3 max tier, each end-to-end to transcript.md
node test/cross-surface-e2e.mjs # REAL: BOTH surfaces (extension + macOS companion binary) through
                         #   coordination → pipeline → corrected transcript.md; never-silent holds
                         #   identically per source; Windows case skipped-but-seamed
```

---

## P1 scope + honest deviations

- **In scope, built, proven on-Mac:** the pipeline core, the native host (over real stdio framing),
  the reconcile/anomaly model, re-transcription, the loro-correction seam (identity pass).
- **Deferred by design:** P2/P3 OS-level capture (Swift Core Audio tap / WASAPI); P4 real
  loro-correction + extension↔companion coordination; P5 `large-v3` opt-in tier + diarization.
- **Deviation flagged:** the extension→service transport SWAP (streaming the offscreen recorder's
  audio over native messaging instead of the Downloads hop) is delivered as a complete, unit-tested
  client module + host registration, but the offscreen/recorder audio-path rewire is **not** flipped
  on in P1 — it needs live-browser verification and would risk the shipping capture guarantee. The
  Downloads path + `sync/richos-sync.mjs` remain the extension's default until that wiring lands with
  its own browser E2E. The host is fully ready to receive it (proven by `test/host-e2e.mjs`).

---

## P4 update — coordination + real loro-correction (landed)

- **Real loro-correction (in scope, built, measured):** `lib/correct.js` is now the real corrector,
  not an identity pass. It loads `loro/entities.json` via `lib/entities.js` and fixes mangled
  names/jargon — curated exact manglings + conservative guarded fuzzy → canonical — at **precision
  1.0 / recall 1.0** on the planted test set with **zero** false positives on control text
  (`test/run.js`), and produces a corrected `transcript.md` end-to-end through the real
  ffmpeg+whisper pipeline (`test/e2e.mjs`). The `correct()` contract shape is unchanged (a body swap).
  The **loro-memory seam** is `lib/entities.js`: swap the file for a structured queryable loro entity
  memory there, nothing else changes.
- **Coordination (in scope, built, proven):** `lib/coordination.js` is the shared, surface-agnostic
  authority (extension consults it over native messaging via `core/native-host-client.js`; a
  companion — macOS now, Windows later — consults it via `claim`/`failover-scan` CLI). It guarantees
  **one session per call** (companion stands down while the extension owns a browser call) and
  **browser-crash failover** (a dead browser call is marked promotable on disk; a companion
  supersedes it). Proven by `test/coordination-e2e.mjs` (real CLI + drop zone, no browser/TCC).
- **Native-messaging-rewire decision — DEFERRED (unchanged from P1):** the extension→service audio
  transport swap still requires a live-browser E2E to prove safe, which cannot be run here (no live
  browser on this box). Per the no-half-baked rule it is **NOT flipped on** — the Downloads path
  remains the extension default, the host + client seam remain fully ready, and P4 adds only the
  ownership handshake on top of that seam (also fully unit-tested). Flip it on only with its browser E2E.
- **Deferred to P5 (unchanged):** `large-v3` opt-in tier + repetition guard; per-remote-speaker
  diarization; the actual per-process tap-exclusion mechanism on the companion (coordination hands
  back the `excludeProcessHint`; the companion currently defers rather than excludes — honest, stated).

---

## P5 update — accuracy & robustness tier (landed)

Full tiering + hardware guidance: the P5 model-tiering note, 2026-08-24.

- **Model tiering (`lib/config.js#MODEL_TIERS` + `resolveTier`), config-driven, select with `--tier`:**
  - `turbo` (**default**) — `large-v3-turbo`; reliable + fast everywhere on Apple Silicon.
  - `max` (**opt-in maximum accuracy**) — full `large-v3` **with the repetition-guard decode params**
    (`-mc 0` no-previous-text-conditioning + temperature fallback + entropy/logprob/no-speech
    thresholds). **Gated:** bare-default `large-v3` reproducibly looped in the benchmark — `resolveTier`
    auto-attaches the guard params to any bare large-v3 so it can **never** run through this pipeline
    unguarded.
  - `low-resource` — `small.en` for weak / non-Apple-Silicon / low-RAM hosts (clean + fast, no
    hallucination in the benchmark).
  - `quantized` — quantized turbo (`large-v3-turbo-q5_0`, ~574 MB vs 1.6 GB; build once with
    `whisper-quantize`) for low-resource Apple Silicon.
- **Hallucination guard (`lib/repetition-guard.js`, pipeline stage 3.5), model-agnostic:** the
  post-decode half of the hallucination defense, over **four measured decode-failure classes**, each
  with a fixture built from the real captured artifact (`test/fixtures/captured-hallucinations.js`,
  sha256 of every source JSON baked in). Findings are recorded in
  `session.json.pipeline.repetitionGuard` + `verification.json`.
  1. **Repetition loop** — a run of identical segments. **Collapsed** to one line, end extended so
     timing stays honest; short backchannels ("Yeah." "Yeah.") are never eaten. **Proven** on the exact
     benchmark sample: bare `large-v3` loops **x4** → decode params alone drop it to **x1** (and run
     faster) → the post-decode guard collapses any residual to **x1**; `turbo` stays **x1** unchanged.
  2. **Persistent insertion** — a fabricated ordinal marker prefixed onto many otherwise-distinct
     segments (`large-v3-turbo`, 59 of 88 segments on 11 min of noisy audio, 3/3 runs). **DETECTED,
     NOT REPAIRED**, and that is deliberate: the captured fabricated span contains a real spoken
     "Zero.", so stripping the markers would delete a word the speaker said. Detection is loud —
     a `log.alarm`, `pipeline.repetitionGuard.unrepaired`, and a plain-English `verification.warnings`
     line saying the fabricated text is **still in `transcript.md`**. Remedy is re-transcription.
  3. **Sliding-overlap stutter** — consecutive segments re-emitting the previous tail with shifted
     boundaries (`large-v3`, 1,979 reference words → 3,999, 110.86 % WER; the loop detector saw only
     6 of 353 segments). **De-overlapped**, content-preservingly: every word survives exactly once.
  4. **Silence fabrication** — text emitted over audio that carries **no speech energy at all**
     (`large-v3-turbo` at `-mc 0`, **159 of 353 segments / 60.4 % of the timeline** on a 126-minute
     per-speaker track, 143 of them the single phrase "Thank you."; podcast-corpus brief
     2026-08-29 §3.3). **It is a function of channel silence and of nothing else** — Spearman
     ρ = 1.0000 over six tracks from two conversations — so it is worst on the channel shaped like
     a real call's `me` side, **the one carrying the CEO's own words**. Classes 1–3 caught 29.5 %
     of it by accident; the guard now takes the fabricated timeline on those three host channels
     from **69.4 minutes to 11.6 minutes** (87.4 % of it on the 126-minute channel). **REMOVED**,
     and repairable where class 2 is not because a span over measured silence has no speech in it
     to lose — verified per span, not assumed: **all 189 removals on the corpus were re-decoded in
     isolation under two decoders and in 189 of 189 the removed words did not come back** (on 12 of
     them the isolated decode returned a *different* hallucination — "We'll be right back",
     "Amen" — over audio at −44.8 to −63.4 dBFS, which is evidence *for* fabrication).
     Text over silence that is *not* in the silence vocabulary is **report-only**.
     Runs FIRST, so fabricated filler cannot look like a loop to class 1. Needs the burst grid and
     is **inert without it** — `silenceProbed` in the record says which.
     **No decode parameter fixes this and that was measured, not assumed:** `-nth` is inert across
     `0.01 … 0.9` (six byte-identical decodes), and `-lpt 0.0` removes 1 of 14 for +90 % wall time.
  Precision is the contract and the thresholds are set from measurement, not taste — across the 18
  clean turbo/`q5_0` transcripts of the 2026-08-26 benchmark the guard changes **nothing**; across
  the three **guest** channels of the 2026-08-29 corpus (28,275 words containing 217 immediate
  repeats and 23 same-word triples) class 4 removes **three segments, five words**, each one
  independently adjudicated as fabrication; and `maxSilenceOverlapSec` was swept over *adjudicated*
  spans, taking **0.10 s** — one step inside the last clean value — because at 0.20 s the rule
  starts eating a genuine backchannel hum spoken at the host's own speech median. The known blind
  spots, including that one, are enumerated in the module header rather than papered over.
- **Deletion detector (`lib/deletion-guard.js`, pipeline stage 3.7), the class the guard above
  cannot see:** all four hallucination classes are the model *saying too much*, and each leaves
  evidence in the text. **Deletion leaves none** — the model emits nothing over real speech, with no
  repetition, no marker, and **no confidence signal**: measured, the tokens either side of a
  confirmed deletion carry 0.94–1.00 confidence. Any alarm built on confidence stays silent.
  - **The discriminator** (from the 2026-08-29 coverage measurement, unchanged): a physically
    detected speech burst of **≥ 1 s over which the run emitted no word at all**, where decoding
    **that burst in isolation** returns real words. The burst grid is model-free (`silencedetect`,
    the same probe the repetition veto uses, 0.68 s per 92-minute channel) but it cannot tell speech
    from noise — the loudest uncovered burst in the corpus is **laughter** — so the isolated
    re-decode adjudicates every candidate.
  - **Five conditions, all required, all measured rather than chosen:** duration ≥ 1 s · ≥ 3
    *distinct informative* words back from the isolated decode (whisper emits "Thank you." over
    proven silence, and a laugh six times over) · level within 24 dB of the **channel's** peak
    (relative, never absolute) · the decode **stable across two paddings** (the one-model
    replacement for the measurement's two-model agreement) · and the recovered words appearing
    **nowhere in the surrounding transcript** — text that is present with the wrong timestamps is
    `mistimed`, and a timing defect must never be reported as a deletion.
  - **DETECT-ONLY**, on the insertion class's precedent: a deletion cannot be repaired from here, so
    the alarm names the span (`00:58:44–00:58:45`), quotes what came back, and points at the
    retained audio. `pipeline.deletionGuard.unrepaired` + a plain-English `verification.warnings`
    line, in the **same vocabulary** as the insertion class.
  - **Cost is bounded by suspect spans, not by file length.** Only candidates are re-decoded, all of
    them in ONE `whisper-cli` invocation (model loaded once), capped by `maxProbes`. Measured on 92
    minutes: 21 candidates → **78.1 s**. `RICHOS_DELETION_GUARD=off` disables it. It changes no
    decode parameter, no tier and no `MODEL_TIERS` value.
  - **"0 deletions" and "never looked" are different answers** and the record keeps them apart:
    `probeAvailable`, `coverageUnit`, `candidates`, `probed`, `rejected` (each with its reason) and
    `unprobed` are separate fields. Blind spots — partial deletion inside a covered burst,
    substitution, speech under the burst floor, sub-second loss, a span the model also refuses in
    isolation — are enumerated in the module header.
- **Word-density instrument (`lib/substitution-guard.js`, pipeline stage 3.8), the class the
  detector above cannot see and says so in its own header:** SUBSTITUTION scores as **perfect
  coverage** — something is there, at the right second, so 3.7 never asks a question. A span where
  eight seconds of speech became four wrong words passes every coverage test there is. The only
  quantity left that needs no reference transcript is **how much text, against how much audio**.
  - **The budget is physical and it was measured, not chosen.** A speech burst of known duration can
    carry only so many words: real conversational English runs **1.87–3.68 words per second of
    detected speech** (2026-08-29 Parakeet coverage brief), the 92-minute corpus's own 8 s windows
    sit at medians of 2.88 and 2.51 w/s, and the 133 synthesized turns of the invented short-call
    corpus — whose rate is known **by construction** — run 1.34–4.40 w/s. The 1.2 w/s floor is below
    every legitimate delivery in all three.
  - **The discriminator:** a window holding **≥ 8 s of detected speech inside ≤ 30 s of wall clock**,
    carrying **at least one** emitted word but far fewer than its budget, where decoding **that
    window in isolation** returns substantially **more** words than the transcript claims, and those
    words are **not already in the transcript beside it**. The isolated re-decode is the whole
    instrument: a density deficit alone is not evidence of anything, because people pause, trail off
    and deliver a line slowly for emphasis. **A slow, emphatic delivery re-decodes to the same few
    words and is rejected by name** (`matches-audio`); a substituted span re-decodes to the sentence
    that was spoken.
  - **Six conditions, all required:** speech mass · ≥ 1 emitted word (a **wordless** window is a
    DELETION and belongs to 3.7 — one failure is never reported twice) · a deficit below **both** an
    absolute floor and 0.45× the **channel's own** median, by ≥ 4 whole words · level within 24 dB of
    the channel peak (the burst grid cannot tell a voice from a chair) · the isolated decode
    returning ≥ 1.75× and ≥ +5 words, surviving repadding · and no **echo** of those words in the
    surrounding transcript (a collapsed retake and a timestamp defect are both `echoed`, neither is
    missing speech).
  - **It cannot say the words present are WRONG, and never claims to.** Without a reference, "the
    transcript holds fewer words than the audio carries" is the whole finding — consistent with
    substitution, with partial deletion inside a covered burst, and with a paraphrasing collapse.
    All three are the same defect to the reader and have the same remedy, so the verdict noun is
    `under-transcribed` and the word "substitution" appears in no verdict.
  - **The channel-level answer a per-window comparison cannot give:** when most of a channel is
    destroyed its own median IS the failure and every window looks normal beside its neighbours
    (`q5_0` put 44.1% of one timeline inside a fabricated loop). `channelsBelowFloor` says that once,
    loudly, as a channel.
  - **DETECT-ONLY**, same precedent and same warnings vocabulary as 3.5 and 3.7.
    `RICHOS_SUBSTITUTION_GUARD=off` disables it. It changes no decode parameter, no tier and no
    `MODEL_TIERS` value. Blind spots — equal-length substitution, substitution that ADDS words,
    anything shorter than a window, speech below the burst floor, and stretches too sparse in wall
    time to form a window at all (`analyzedSpeechSec` vs `burstSeconds`, every run) — are enumerated
    in the module header.
- **Diarization seam (`lib/diarize.js`, opt-in via `--`/`RICHOS_DIARIZE`), honest scope:** default
  `none` (identity — one "Them", no wrong speaker counts). Opt-in `tinydiarize-turns` consumes
  whisper.cpp's **native** `[SPEAKER_TURN]` markers (local, no extra dependency) to split the far-side
  channel into per-turn remote speakers for **non-caption** multi-speaker calls. Caption names always
  win over turn labels. **Stable per-identity attribution** (linking non-adjacent turns to one person)
  needs speaker-embedding clustering — a heavy, harder-to-test ML dep — so it is **documented as a
  scoped local follow-up, not forced** (the seam is complete; `identityStable:false` states the honest
  limit). See the tiering doc for the recommended local approach.
- **Cross-surface E2E harness (`test/cross-surface-e2e.mjs`):** ONE harness exercising the extension
  and the real macOS companion binary through coordination → pipeline → corrected `transcript.md`,
  asserting the chain + never-silent guarantees hold identically per source; Windows plugs in via one
  producer entry (`RICHOS_WINDOWS_COMPANION`), no rework.
- **Native-messaging-rewire decision — STILL DEFERRED (unchanged):** the extension→service audio
  transport swap is untouched by P5; it still awaits its live-browser E2E.

---

## The correction flywheel — dictation, and one shared vocabulary (landed 2026-08-29)

`ceo-decisions.md` §7 decided **"ask, never infer"** on 2026-08-26, and it was unbuilt at both ends:
open-wispr kept neither text nor audio, so nothing existed for a correction to be a correction *of*,
and `entities.json` had exactly **one reader** — this pipeline — so a term the CEO taught the system
once was right in his call transcripts and wrong in everything he dictated.

**`correct-text` is the second reader.** open-wispr calls it between `whisper-cli` and the paste
(`tools/richos-hud/dictation-flywheel.patch`), and it calls `correctText()` — the exact function
`lib/pipeline.js` calls. One corrector, so a word cannot be corrected one way in a transcript and
another way in a dictation.

**`lib/dictation.js` is the ask.** It produces QUESTIONS and has no `--apply` at any setting;
`answerAsk()` is the only function in the module that changes what the system believes, and it
cannot be reached without a human answer. §7's three outcomes exactly: confirm learns; decline
learns nothing and is asked again on the very next repeat; decline-and-never is permanent and
inspectable. The gate gains a **phonetic leg**, because §7 named the shipped orthographic gate's own
blind spot — it stays silent on exactly the worst ASR failures, the ones that sound close and are
spelled far apart.

**`lib/dictation-store.js` is the retention posture**, and it is stated rather than drifted into,
reusing the techy-mode journal's shape and its exact numbers:

| tier | what | policy | measured cost |
|---|---|---|---|
| A | the text record | 14 days OR 5,000 records, whichever binds first | **284 KB / hour** of dictation |
| B | the audio | **OFF by default**; when on, 14 days OR 2 GB | 110 MB/hour — 397× — for something the flywheel never reads |

open-wispr **appends**; this service **sweeps**, hourly, from `watch`. That split is what keeps
eviction an `unlink` of a whole day file rather than a rewrite of the CEO's speech.

**Measured, not asserted** — `docs/measurements/correction-flywheel-2026-08-29/`. On an invented
6-call corpus, one correction per channel per round: name consistency **19/24 → 21 → 23 → 24/24**,
converging in three rounds, WER 3.15% → 2.31%, without touching `-mc`. Up-front prompt biasing was
measured and **rejected**: it is byte-identically inert at the pipeline's `-mc 0`, and in dictation —
where it is live — it raises exact hits while *costing* spelling consistency, because a
probabilistic nudge can invent a new variant and a deterministic replacement cannot.
