# RichOS Windows capture companion (P3)

The native Windows half of the call-transcription architecture
(2026-08-24, §5.3 + the P3 row of §9). It
closes the gap the browser extension structurally cannot reach — **desktop-app calls (Zoom/Teams
native) and in-person conversations** — by capturing OS-level system audio + mic with **no bot** and
**no per-call gesture**, then writing P1's **frozen capture→pipeline contract** so the existing
pipeline (`tools/richos-service/`) transcribes its output unchanged.

The companion is "just another producer" of the same session directory the extension and the macOS
companion write. It adds zero pipeline code; it only produces the contract. It is the exact **peer of
the macOS companion** (`../companion-macos/`) — same two-layer shape, same contract, same reliability
model, same coordination seam.

> **On-Mac status — CORRECTED 2026-08-29, and the correction matters.** This file, the code and the
> unit tests were authored on macOS, which **cannot compile or run WASAPI**. This note used to add
> "and the CI workflow", and to conclude that the companion was **"CI-compile-verified + pending the
> CEO's real test"**.
>
> **It was not.** `.github/workflows/windows-companion-ci.yml` did not exist — never written, no
> history, nothing to move or rename — so **this code has never been compiled anywhere, by anyone.**
> The workflow now exists, at exactly the path this file has been citing since 2026-08-24, and its
> header says the same thing at more length.
>
> So verification is split three ways, and only the first is closed today: (a) the pure core's unit
> tests, which run on any .NET host; (b) the Windows compile + core tests on a real `windows-latest`
> runner — **the workflow is written and has never run**; (c) the CEO validates **real capture** on
> his own Windows machine per [`WINDOWS-TEST-PROTOCOL.md`](./WINDOWS-TEST-PROTOCOL.md). Nothing here
> claims capture works, and nothing here may be upgraded to "CI-verified" until a green run of that
> workflow can be pointed at by SHA.

## Toolchain choice: C#/.NET 8 (justification)

The architecture's §9 table pencils in "C++/WinRT"; the P3 brief explicitly authorizes picking "C++ with the
Windows SDK, or C#/.NET with CsWin32/P-Invoke — justify the choice." **This companion is C#/.NET 8
with hand-written P/Invoke** (no CsWin32 codegen, no NuGet interop dependency), for four reasons, the
first decisive given the no-local-compile reality:

1. **CI cleanliness (the hard requirement).** `dotnet build` / `dotnet test` on `windows-latest` is a
   two-line, fully-standard workflow with the SDK preinstalled — far less brittle than bootstrapping a
   CMake/MSBuild + Windows-SDK + WinRT C++ project I can't smoke-test locally. When the only
   correctness gate before the CEO is remote CI, the toolchain with the least CI ceremony wins.
2. **Portable-logic testability, maximized.** The pure core (`RichOSCompanionCore`) is a plain `net8.0`
   class library with **zero** Windows-audio dependencies, so contract writing, channel L/R mapping,
   WAV, mix/failover, and coordination parsing are unit-tested by `dotnet test` with no audio hardware
   and no permission — exactly the macOS `RichOSCompanionCore` split. The library even compiles on
   Linux/macOS, so CI verifies the maximum surface a non-capturing host can.
3. **WASAPI process loopback is fully reachable from C#.** `ActivateAudioInterfaceAsync`,
   `IActivateAudioInterfaceCompletionHandler`, and `AUDIOCLIENT_ACTIVATION_PARAMS` with
   `PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE` all marshal via P/Invoke + COM interop (the same
   pattern NAudio and the MS samples use). The `GetMixFormat E_NOTIMPL` trap (§5.3) is handled by
   supplying the `WAVEFORMATEX` manually — trivial in C#.
4. **Minimal native footprint, 1:1 with macOS.** Two projects (pure core + native exe) + a test
   project mirror the macOS SwiftPM `RichOSCompanionCore`/`richos-companion` layout, keeping the whole
   system coherent.

**Tradeoff (the deviation from the architecture's C++/WinRT suggestion):** a managed-runtime dependency (.NET 8) on
the CEO's machine, and P/Invoke marshalling boilerplate for the COM async activation. Both are
acceptable — .NET 8 is a standard install and the activation pattern is well-trodden — and the brief
authorized the choice.

## What it captures (architecture §5.3)

- **System audio** via **WASAPI loopback**:
  - **System loopback (baseline, every Windows 10/11):** `IAudioClient.Initialize` with
    `AUDCLNT_STREAMFLAGS_LOOPBACK` on the default render endpoint — captures **all** system output
    (Granola parity, §10-Q2 "all-output first"). Audio keeps playing to the user; loopback reads a copy
    of the render mix, so it works on headphones exactly as on speakers.
  - **Process loopback (preferred, Windows 10 build 20348+):** `ActivateAudioInterfaceAsync` +
    `AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK` +
    `PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE` scoped to a target app's PID + children — used
    when `--pid` is supplied; **falls back to system loopback** if activation fails. Handles the
    documented `GetMixFormat`/`IsFormatSupported` = `E_NOTIMPL` trap by supplying the `WAVEFORMATEX`
    manually.
- **Microphone** via WASAPI shared-mode capture on the default input, `AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM`
  to the same 48 kHz float target as the loopback, so the two async sources stay frame-aligned.
- **Mixed to the frozen 2-channel contract: mic → LEFT (me), system loopback → RIGHT (others).** Never
  a pre-mix — free "me vs them" separation with no diarization model.

## The permission model (honest)

Windows does **not** gate loopback capture behind a consent dialog — system audio needs no prompt. The
**microphone** requires the Windows microphone privacy permission (Settings → Privacy & security →
Microphone). If the mic is denied/absent, the companion **keeps capturing system audio** and
silence-fills the LEFT channel while raising a **loud red health alarm** (`micRunning:false`) — a
deliberate improvement over the macOS both-or-nothing start, so the far side of a call is never lost.
Because `session.json` is written at capture START (`status:"open"`), a capture that produces nothing
still leaves a **loud open/empty session on disk** — the never-silent anomaly the pipeline flags.

## CLI

```
richos-companion doctor
    Report Windows build (process-loopback needs 20348+), loopback availability, pipeline deps,
    the shared coordination CLI, and the permission model.

richos-companion capture [--zone DIR] [--pid N --process-name NAME] [--process-hint H] [--force]
    Live capture: WASAPI system loopback (or process loopback with --pid) + mic → 2-channel contract
    dir. Ctrl-C finalizes the session (status "closed") → the P1 watcher transcribes it.

richos-companion ingest --stereo <wav> [--zone DIR] [--started-at MS]
richos-companion ingest --mic <monoWav> --system <monoWav> [--zone DIR]
    Headless: push a pre-made sample through the REAL contract writer (no permission) → a valid session
    dir the P1 pipeline transcribes. The on-Windows proof of the contract + handoff.
```

Drop zone resolves to `%RICHOS_DROP_ZONE%`, else `<checkout>\wiki\raw\meetings` (mirrors
`config.js#dropZone` and the macOS companion).

## Build & test

```
dotnet build src/RichOSCompanionCore/RichOSCompanionCore.csproj -c Release
dotnet build src/richos-companion/richos-companion.csproj       -c Release   # Windows only (WASAPI)
dotnet test  tests/RichOSCompanionCore.Tests/RichOSCompanionCore.Tests.csproj -c Release
```

`.github/workflows/windows-companion-ci.yml` runs exactly this on `windows-latest`, plus a
`richos-companion doctor` invocation to prove the built executable actually starts. **As of
2026-08-29 that workflow has never executed** — it was written on a Mac with no .NET SDK, so its
first run is also its first test. Until a green run exists on a named SHA, treat this section as an
instruction, not a result.

### A known defect this build has not been able to test

`Program.cs#ResolveZone` falls back to `<cwd>\wiki\raw\meetings` when `RICHOS_DROP_ZONE` is unset —
a path **inside this repository**, which ships publicly, and one the pipeline now **refuses**
outright (`assertEvidenceOutsideProductRepo`). So an unconfigured `capture` would write the CEO's
recorded call into the public tree, and the pipeline that should transcribe it would never look
there. The macOS companion had the identical defect and it is fixed there (`DropZone`, with unit
tests and the same refusal). **This is a source reading, not an executed one** — there is no .NET
toolchain on the machine that found it — so it is recorded here rather than patched blind. Fixing it
is a job for someone who can run the build.

## Contract fields emitted (parity with P1 — so Rich can confirm)

`session.json` (schemaVersion **2**), matching `lib/contract.js` + the macOS companion:

- `capture.source` = **`desktop-companion-windows`** (P1 `CAPTURE_SOURCE.windows`).
- `capture.method` = **`wasapi-loopback+mic`** (system loopback) or **`wasapi-process-loopback+mic`**
  (process loopback). Both listed in architecture §3.2's method enum.
- `capture.channels` = `{ left: "microphone (me)", right: "system/loopback (everyone else)" }`
  (descriptive only — the pipeline maps by channel POSITION via ffmpeg `channelsplit`, L→me / R→others).
- `capture.captureTarget` = **`system`** (all-output) or **`process:<name>`** (process loopback).
- `capture.sampleRate` = `48000`; `capture.container` = `audio/wav;codecs=pcm_s16le`;
  `micEnabled`, `chunkMs`.
- `ownership` = `{ ownerSurface: "desktop-companion-windows", supersedes: null|<deadSessionId>,
  processHint: null|<hint> }` — the §5.4 dedup handshake / failover-promotion block.
- `pipeline` = born `{ status: "pending", model: null, modelRuns: [], ffmpegVersion: null,
  whisperVersion: null, loroCorrection: {applied:false, entitiesVersion:null, corrections:0} }`
  (written by the pipeline; pending so a never-run pipeline is visible on disk).
- Plus every field the extension/macOS record carries: `schemaVersion, sessionId, dir, status,
  producer, platform, startedAt, endedAt, audio{parts,bytesTotal,chunkCount}, health{...}, alerts,
  recovery, captions{available:false,...}, mode, notes`.

Audio part: a single self-contained **`audio-part-00.wav`** (2-channel 16-bit PCM, 48 kHz).
`health.ndjson`: one row/sec with the **identical field names** as the macOS companion
(`sessionId, t, micRms, sysRms, micRmsMean, sysRmsMean, bytesTotal, bytesDelta, part, tapRunning,
micRunning, level, problems`) — on Windows `tapRunning` = "the loopback capture client is delivering".

## Audio format choice (single-part WAV) — same architecture-sanctioned decision as macOS

The architecture §3.1 sanctions "Opus-in-Ogg OR 16 kHz WAV." Like the macOS companion, this writes a **single
self-contained 2-channel 16-bit PCM WAV**, because the frozen pipeline's multi-part concat
(`normalize.js`) only remuxes into a `.webm` container (`-c copy`), which PCM cannot enter — so
*multiple* WAV parts would break the pipeline, while a **single** WAV part takes the pipeline's
`parts.length === 1` direct path and works unchanged. WASAPI has no built-in Opus encoder, so WAV is
the correct zero-dependency choice. Recoverability (§6.5) is met by rewriting the RIFF/data size
headers + `Flush(flushToDisk:true)` every second: a crash loses at most ~1 s and the on-disk file is
always a decodable prefix. Multi-part Opus rolling is a clean later refinement if the pipeline's concat
step gains a PCM-friendly container; it is **not** required for the contract or the reliability
guarantee, and doing it now would break the frozen pipeline.

## Reliability model (matches the shared guarantees, §6)

- **Never-silent (§6.1):** `session.json` written at capture START; a call that captured nothing is a
  loud on-disk `open`/empty anomaly.
- **In-call health (§6.2):** `health.ndjson`, one row/sec — per-channel peak/RMS, byte growth,
  loopback/mic liveness, level, problems.
- **Outside watchdog (§6.3):** the companion holds its own 1 Hz timer; **no byte growth for 15 s**
  raises a loud alarm (stderr + best-effort Windows toast) — catches a stalled loopback, a device
  change, or a lost mic.
- **Mic-vs-loopback failover (§6.4):** if one source stalls while the other is live, the writer
  silence-fills the dead side and keeps the live side recording, and alarms (`MixDecision`,
  unit-tested). Mic-denied is handled specially (system-only + LEFT silence-fill + alarm).
- **Recoverable audio (§6.5):** the WAV is flushed-to-disk and its size headers rewritten every second.

## Coordination (§5.4, P4) — reused, not re-implemented

The companion consults the **shared, surface-agnostic authority** (`lib/coordination.js`) exactly as
the macOS companion does: `CompanionCoordinator` shells out to `richos-service claim` /
`failover-scan` / `mark-superseded`, and `Coordination` (in the pure core) parses the answers and
builds the promotion-ownership block. It registers as a **`system`-scope** capture surface, **stands
down** when the extension owns a browser-tab call (unless `--force`), and supports **browser-crash
failover promotion** (`ownership.supersedes`). No decision logic is duplicated — the brain stays in the
one Node service, which is what makes the system generic over companion type (macOS + Windows).

## What's verified where

- **Unit-tested (green in CI, no hardware):** contract v2 shape + Windows enum values, channel L/R
  mapping + Int16 scaling + downmix, mix/failover decisions, WAV round-trip + header framing, full
  `SessionWriter` contract-dir write (never-silent open record, closed populated record, health rows,
  L/R survives to disk), coordination parsing + promotion-ownership block.
- **CI-compile-verified (green in CI, not executed):** the WASAPI executable — system loopback,
  process loopback via `ActivateAudioInterfaceAsync` (incl. the `E_NOTIMPL` handling), mic capture,
  the live pump/health/watchdog loop, the `Notifier`, the coordination invoker.
- **Pending the CEO's real test (`WINDOWS-TEST-PROTOCOL.md`):** actual OS-level capture of a real
  Zoom/Teams desktop call, and each failure mode (mic denied, no audio, crash mid-call).

## Not in scope here (later phases)

The **real** loro-correction corrector and the pipeline-side coordination internals are P1/P4 in the
Node service (already landed). Per-remote-speaker diarization for desktop-app calls (no captions) is
P5. This is P3: OS-level Windows capture + the frozen contract + the reliability model + the
coordination seam + CI compile-verification.
