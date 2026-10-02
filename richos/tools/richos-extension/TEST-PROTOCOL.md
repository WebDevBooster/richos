# RichOS capture verification

A passing fake-device harness does not establish that a real Zoom call records correctly.
Keep automated regression results separate from actual host and guest call evidence.
Read the repository [verification retry procedure](../../../docs/development/verification-retries.md)
before running checks. Preserve failures and retry only the unresolved unit unless source or
execution inputs invalidate other evidence.

## Automated checks

From this directory:

```sh
node tests/run.js
node tests/recorder-lifecycle.mjs
node tests/alerts.mjs
node tests/controller-recovery.mjs
node tests/zoom-lifecycle.mjs
node tests/export-archive.mjs
node tests/popup-export.mjs
node tests/live-capture.mjs
node tests/native-transport-e2e.mjs
```

The repository's `extension-*.test.sh` wrappers declare the corresponding proof inputs.

The live harness uses a disposable profile and a local HTTPS Meet-shaped fixture. It checks
worker restart, captions, durable browser checkpoints, no automatic downloads, one explicit ZIP
and decoding every exported stereo audio part. Set `CHROME_PATH` to an installed Chrome for
Testing build if the selected build cannot load the fixture. Python 3 independently checks the ZIP.

The native harness additionally requires macOS `say`, working `ffmpeg`, `ffprobe`, `whisper-cli`
and a Whisper model. Set `RICHOS_WHISPER_MODEL` explicitly when needed. The launcher preserves
that process's PATH. Chrome must be allowed to launch and read its native helper, including
external-volume access on macOS. A failed prerequisite is a failed or unrun check, never a pass.
`--leg=native` and `--leg=fallback` support isolated retries; retain both complete leg results for
full coverage. The default runs both. Native fixture speech injected into the encode graph proves
transport and processing only. It does not prove a real microphone or Zoom remote channel.

## Real Windows Zoom acceptance

Use two separate Windows console sessions with Chrome. Keep **Ask where to save each file**
enabled so an accidental download cannot hide the original defect. Each computer needs a working
microphone input and an independent audio output. In an unattended lab, render distinct spoken
fixtures through a virtual input cable and route received Zoom audio to a separate output.

Test both roles in each supported transport configuration:

| Role | Required behavior |
| --- | --- |
| Host initiating a new meeting | Numeric `/wc/<id>/start` is detected. Zoom dashboard is not a call. |
| Guest joining another person's meeting | Numeric `/wc/<id>/join` is detected, including iframe layouts. |
| Host ending for everyone | Capture closes and does not arm the dashboard. |
| Guest receiving host-ended dialog | Capture closes while the terminal dialog remains visible. It does not rearm that ended meeting. |

Grant microphone permission once. Invoke RichOS on the focused call tab using its toolbar action
or **Alt+Shift+L** to obtain Chrome's real tab-audio grant. Confirm full mode and live microphone
and tab tracks. Verify Zoom is connected to computer audio and its microphone is actually
unmuted. A keyboard action reporting success is insufficient; inspect the resulting control state.

After both participants connect, render distinct speech on each side. Then leave both inputs
quiet for more than 60 seconds. Confirm audio chunks keep growing, the audio graph and tracks
remain live and silence does not detach or reacquire an otherwise valid source. Quiet proven
input may be amber. Missing or never-proven input remains a failure requiring investigation.

At close, preserve:

- Session metadata, health logs, audio parts and deployed file hashes for both computers.
- The guest's undismissed terminal-dialog state and inactive recorder status.
- Chrome notification and pending-download state, plus native window inspection when available.
- Actual native file paths or the browser pending export followed by its explicit ZIP.
- Independent decoding of **every** audio part and both channels. Left must contain local speech
  and right must contain the other participant's speech. Verify the distinct spoken words through
  listening or independent transcription. Aggregate byte growth and `verification.ok` alone do
  not establish that both speakers were captured.

Test native saving and browser fallback on both roles. In browser fallback, no Save As dialog
may open during capture or automatic close. Explicit **Export** may open one dialog. Cancel it,
confirm the recording remains pending, retry and save. Check ZIP CRCs and exact extracted bytes.
Successful export must remain completed across a worker restart, even if diagnostic copies are kept.

## Failure and recovery coverage

Exercise these separately and report the exact coverage reached:

| Case | Expected result |
| --- | --- |
| Worker eviction | Recorder continues, existing session and counters reconcile, alerts do not flood. |
| Delayed blob conversion or IDB write | Rotation and stop wait for durable writes; every part retains its own header and session identity. |
| Native host disconnect or missing acknowledgement | Complete browser copy remains available for explicit export. |
| Refused tab grant | A valid existing tab stream stays connected. A genuinely missing remote stream is visibly incomplete. |
| Microphone or tab track ends | Report source loss and preserve the other source. Recovery releases a working source only after replacement is ready. |
| Extension or browser restart | Interrupted data is retained and flagged. Completed exports are not relabelled as new orphans. |
| Repeated failure health updates | One visible incident notification, durable dedupe across worker restart and clearing after resolution. |
| Old corrupt WebM parts | Verification rejects missing EBML headers and retains the data for diagnosis. |
| Explicit export cancellation | All stored rows remain intact and the action can be retried. |

Physical device removal, browser termination, non-English Zoom dialogs, other platforms and long
soak tests require their own actual evidence. Do not infer them from English Zoom on two PCs.
Captions depend on the platform adapter and must be reported separately from primary audio.
Transcription dependencies belong to the native service and must be installed and tested before
claiming automatic transcription on a given Windows machine.

## Report identity

Record OS, Chrome version, extension version, Git commit and deployed file hashes. Include role,
transport, start and end timestamps, device routing, actual speech/decode results, health verdict,
notifications, dialogs, export results and recovery behavior. Mark every prerequisite failure,
timeout and unrun scenario explicitly. Link original failures and reconciled successful retries.
