# What the screens need from the core (I2 → I1)

**From:** stream I2 (screens), `isaac-opus-i2`. **To:** stream I1 (core), through Rich.

The first version of this file (commit `5768bd5b`) asked for the whole screen-facing state; I1
delivered it (`18d5062d` onward: the full `AppState`, 63 round-12 fixtures, the six domains, the
`-rios-appearance` launch argument, the `RichOSNativeTests` target, and the `RootView` seam at
`9f328a6b`). Every screen now renders from `AppState` alone. What is still open:

## 1. Attachments (ceo-decisions §75: photos and files in v1)

The views exist (`App/Features/Attachments/`, round-12 `attachments.html`) and read
`ScreenModel.attach`, which stays empty until the core carries attachments. The shapes they draw are in
`Attachments/AttachmentModel.swift` (`PendingItem`, `AttachPhoto`, `AttachFile`, `Reference`,
`Viewer`); proposed state and actions, to move into the core as they are:

- `AppState.attachments: { menuOpen, pending: [PendingItem], viewer: Viewer?, picker: Picker? }`, and
  on `Message`: `kind .album([AttachPhoto]) / .file(AttachFile)`, `caption`, `progress`, `reference`,
  `sharedFrom`.
- Actions: `openAttachMenu`, `closeAttachMenu`, `openPicker(.photos/.camera/.files)`,
  `picked([PendingItem])`, `removePending(id)`, `openViewer(messageID, index)`, `viewerShow(index)`,
  `closeViewer`, `jumpTo(messageID)`; refusals as cards (too large, unsupported type, camera or photos
  denied, Mac cannot receive attachments) and the ten-item toast.
- Limits from the Mac's intake (`cc/echo-opus-m1` 22e59ed8): 25 MiB per file, 10 per message, 13 types.
- The 39 `att-*`/`share-*` fixtures; the `share-*` screens are the Share Extension's (stream I3).

## 2. Small gaps (each an intent that changes nothing today)

| Intent (view) | Where | Needed |
|---|---|---|
| `sendWaitingFirst`, `discardAndPair` | `pair-blocked` dialog | the pairing-replacement choices |
| `checkForUpdates`, `checkAgain` | Settings row, update dialog | a policy re-fetch action |
| `dismissCard("mic-denied")` | `rec-mic-denied` "Not now" | a dismissal the core remembers |
| a reply's time | `conv-replying`, `conv-streaming` | `ReplyActivity` carries no time; the row shows the last message's |
| `hearReply(id)` entry point | Rich's replies | nothing says which replies can be heard (PRD: "expose reply playback whenever the Mac supports it"), so "Hear it" appears only while `playback` names that reply; a `Message.audioAvailable` (or a Mac capability) would show it at rest |
| the microphone mirror | every voice gesture | `.microphonePermission` on launch and on becoming active, and a port for `.requestMicrophone` (in progress, I3 adapter + I1 effect seam) |
