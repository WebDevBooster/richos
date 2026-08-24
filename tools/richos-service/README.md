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
   zone** and triggers the pipeline. Outside-the-browser watchdog + EOF finalisation included.
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
 3. TRANSCRIBE        whisper.cpp large-v3-turbo per channel, -oj timestamps (Metal)
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
```

Env overrides: `RICHOS_DROP_ZONE`, `RICHOS_WHISPER_MODEL` / `RICHOS_MODEL_DIR`, `RICHOS_WHISPER_BIN`,
`RICHOS_FFMPEG_BIN`, `RICHOS_WHISPER_LANG`, `RICHOS_TRANSCRIPT_SLA_MS`, `RICHOS_ENTITIES_FILE`,
`RICHOS_DIARIZE` (P5 diarization method, default `none`).

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
                         #   host handlers, ledger, parsers — no ffmpeg/whisper/browser
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
- **Repetition guard (`lib/repetition-guard.js`, pipeline stage 3.5), model-agnostic:** the post-decode
  half of the hallucination defence. Collapses looped/garbled spans (the reproduced large-v3 4x loop)
  to a single line, precision-guarded so short backchannels ("Yeah." "Yeah.") are never eaten. Findings
  are recorded in `session.json.pipeline.repetitionGuard` + `verification.json`. **Proven** on the exact
  benchmark sample: bare `large-v3` loops **x4** → decode params alone drop it to **x1** (and run faster)
  → the post-decode guard collapses any residual to **x1**; `turbo` stays **x1** unchanged.
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
