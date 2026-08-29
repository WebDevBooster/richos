# RichOS Windows companion — CEO real-capture test protocol (P3)

This is the one verification step that **cannot** be done anywhere but a real Windows machine with a
real call: proving the WASAPI capture engine actually records a live desktop call into the frozen
contract, and that every failure mode behaves per the never-silent guarantee.

> **CORRECTED 2026-08-29.** This paragraph used to continue: *"Everything else (compile + portable-logic
> unit tests) is already green in CI on `windows-latest`."* **That was not true.** The workflow it
> referred to did not exist, so nothing here had ever been compiled. The workflow now exists and has
> still never run. **§0 step 4 (`dotnet build`) below is therefore the first time this code will be compiled
> at all**, on your machine — so a compile error there is a real finding to report, not a broken setup on your
> side, and it is worth doing that build before booking time with anyone for the live call in §2.

Run it on **your own Windows machine** (the one you take calls on). Expect ~20 minutes. No account, no
network egress, no cloud — everything stays local.

---

## 0. One-time setup

1. **Install .NET 8 SDK** (if not present): <https://dotnet.microsoft.com/download/dotnet/8.0> →
   "SDK x64". Verify in a terminal:
   ```
   dotnet --version        # expect 8.x
   ```
2. **Get the repo** onto the Windows machine (clone or copy the branch
   `feat/windows-companion-p3-2026-08-24`). Open **PowerShell** and `cd` into:
   ```
   cd <repo>\tools\richos-service\companion-windows
   ```
3. **(For the transcription half — optional but recommended)** install the P1 pipeline deps so the
   companion's output is transcribed end-to-end: `node` (18+), `ffmpeg`, and `whisper-cli`
   (whisper.cpp) on `PATH`. Without them, capture still works and you can verify the contract dir; the
   transcript step just won't run.

4. **Build the companion (Release):**
   ```
   dotnet build src\richos-companion\richos-companion.csproj -c Release
   ```
   The executable lands at
   `src\richos-companion\bin\Release\net8.0-windows\richos-companion.exe`. For brevity below:
   ```
   $rc = ".\src\richos-companion\bin\Release\net8.0-windows\richos-companion.exe"
   ```

5. **Environment check:**
   ```
   & $rc doctor
   ```
   Confirm: Windows build reported; "WASAPI system loopback: AVAILABLE"; process loopback AVAILABLE if
   your build ≥ 20348; the drop zone path; and (if installed) node/ffmpeg/whisper-cli found.

Pick a scratch drop zone so nothing touches the real loro tree during testing:
```
$env:RICHOS_DROP_ZONE = "$HOME\richos-test-meetings"
```

---

## 1. Headless contract proof (no call, no permission needed)

Proves the contract writer + the frozen L/R channel mapping on YOUR machine before touching live audio.

1. Make (or grab) two short mono WAVs — e.g. record yourself saying "left channel me" (`mic.wav`) and
   have any audio saying "right channel them" (`system.wav`). Any 16-bit PCM mono WAV works.
2. Run:
   ```
   & $rc ingest --mic mic.wav --system system.wav
   ```
3. **Expected:** prints `session (open) written: ...` then `session (closed) written: ...`. In
   `$env:RICHOS_DROP_ZONE\<sessionId>\` you should see `session.json`, `audio-part-00.wav`,
   `health.ndjson`.
4. Open `session.json` and confirm: `"schemaVersion": 2`, `"status": "closed"`,
   `"capture": { "source": "desktop-companion-windows", "method": "wasapi-loopback+mic", ... }`,
   `"ownership": { "ownerSurface": "desktop-companion-windows", ... }`, `"pipeline": { "status":
   "pending", ... }`.
5. **(If pipeline deps installed)** transcribe it:
   ```
   node ..\bin\richos-service.js run "$env:RICHOS_DROP_ZONE\<sessionId>"
   ```
   Confirm a `transcript.md` appears with **`Me:`** = the mic line and **`Them:`** = the system line —
   this proves LEFT=me / RIGHT=others survived end-to-end on Windows.

---

## 2. Live capture of a REAL desktop call (the core test)

1. Start a real **Zoom or Teams desktop** call (a test call with a colleague, or Zoom's "Test
   Meeting" at <https://zoom.us/test> which plays audio you can talk over). Use **headphones** for one
   run to prove loopback captures the render stream regardless of output device.
2. In PowerShell:
   ```
   & $rc capture
   ```
   - If Windows prompts for **microphone** access, allow it (or pre-allow under Settings → Privacy &
     security → Microphone).
   - Expect: `session (open) written: ...` then `capturing system audio + mic. Press Ctrl-C to stop.`
3. Talk for ~30–60 s; make sure the other side talks too (or the test-meeting audio plays).
4. Press **Ctrl-C**. Expect: `session (closed) written: ... — the P1 watcher will now transcribe it.`
5. **Verify the capture:**
   - `session.json` → `"status": "closed"`, `audio.bytesTotal` > 0, `health.recordsWritten` ≈ your
     call length in seconds.
   - Open `audio-part-00.wav` in any player/editor (e.g. Audacity): **LEFT channel = your voice**,
     **RIGHT channel = the other participant(s)**. This is the single most important check.
   - `health.ndjson` → most rows `"level":"green"`, `tapRunning:true`, `micRunning:true`,
     `bytesDelta` > 0 each second.
6. **(If pipeline deps installed)** confirm a `transcript.md` was produced (auto by the watcher, or run
   `node ..\bin\richos-service.js run "..."`) with both sides attributed.

### 2b. Process-scoped capture (build 20348+ only)

To prove process loopback scopes to just the meeting app (excludes music/notifications): find the
meeting app's PID (Task Manager → Details, e.g. `Zoom.exe`), then:
```
& $rc capture --pid <PID> --process-name Zoom --process-hint Zoom
```
Play music in another app during the call. **Expected:** the RIGHT channel contains the call audio but
**not** the music; `session.json` shows `"method": "wasapi-process-loopback+mic"` and
`"captureTarget": "process:Zoom"`. If your build is < 20348 (or activation fails), it logs a fallback
message and records `"method": "wasapi-loopback+mic"` — that is the correct, honest degrade.

---

## 3. Failure modes — the never-silent guarantee (deliberately break each)

### 3a. Microphone denied
1. Settings → Privacy & security → Microphone → turn **off** access (or deny when prompted).
2. `& $rc capture`, talk on a call ~20 s, Ctrl-C.
3. **Expected:** capture still runs (system audio recorded on RIGHT); stderr shows an **ALARM** about
   the mic not running; `health.ndjson` rows have `"micRunning": false`, `"level": "red"`, and a
   problem string about the microphone; the LEFT channel is silent. The far side of the call is **not
   lost**. Re-enable the mic afterward.

### 3b. No audio at all (silent capture)
1. `& $rc capture` but do **not** join any call and keep the machine silent (mute output, don't
   speak) for ~30 s, then Ctrl-C.
2. **Expected:** `session.json` exists (written at START) with `status` going `open`→`closed`; the
   watchdog raises the **"no audio has been written for 15s"** alarm on stderr (+ toast). The empty/
   near-silent session is present on disk — and when the pipeline runs, its reconcile guard flags it as
   an **anomaly** (`pipeline.status:"anomaly"`), never a silent drop.

### 3c. Crash mid-call (recoverable audio)
1. `& $rc capture`, talk on a call ~20 s.
2. **Kill it hard** — Task Manager → End task on `richos-companion.exe` (simulates a crash; do NOT
   press Ctrl-C).
3. **Expected:** `session.json` is still `"status":"open"` (never finalized — a loud anomaly the
   pipeline flags), BUT `audio-part-00.wav` is a **valid, playable WAV** containing the ~20 s up to the
   last 1-second flush (you lose at most ~1 s). Play it to confirm. This is the §6.5 crash-recovery
   guarantee: the audio is never lost even when the process dies.

---

## 4. What to report back

For each of §1, §2, (§2b if applicable), §3a, §3b, §3c: **pass/fail + one line**, and for §2 the
**one screenshot that matters** — the WAV open in an editor showing your voice on LEFT and the other
participant on RIGHT. If any step deviates from "Expected", paste the stderr output and the offending
`session.json` — that is exactly the signal that pinpoints a real-hardware bug the CI compile gate
can't catch.
