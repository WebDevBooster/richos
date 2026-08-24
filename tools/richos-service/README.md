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
 5. loro-CORRECTION   P1: identity pass (0 corrections). P4: real corrector, SAME contract.
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
node bin/richos-service.js doctor                 # verify ffmpeg / whisper-cli / model resolve
node bin/richos-service.js watch [--zone dir]     # watcher: pipeline trigger + reconcile net
node bin/richos-service.js run <sessionId|dir>    # run the pipeline over one session
node bin/richos-service.js retranscribe <id> [--model large-v3]   # re-run on retained audio
node bin/richos-service.js reconcile [--zone dir] # report-only anomaly sweep (never transcribes)
```

Env overrides: `RICHOS_DROP_ZONE`, `RICHOS_WHISPER_MODEL` / `RICHOS_MODEL_DIR`, `RICHOS_WHISPER_BIN`,
`RICHOS_FFMPEG_BIN`, `RICHOS_WHISPER_LANG`, `RICHOS_TRANSCRIPT_SLA_MS`.

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
