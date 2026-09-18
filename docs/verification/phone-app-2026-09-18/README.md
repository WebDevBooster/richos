# The phone app, verified — 2026-09-18

The RichOS phone app (`richos/app/phone`), walked end to end in two browser engines against a stub
Mac over a real TLS origin. **98 checks pass, 1 documented skip, in Chromium and WebKit.** The full
output of the run this record was written from is beside it in `desktop-verify.log`; the screenshots
are the same run's.

Reproduce it:

```
cd richos/app/phone
npm test          # 77 checks, no browser, no dependency
npm run verify    # the run this record describes
```

## What was verified, and what each check is actually about

| | |
|---|---|
| **The origin is a secure context** | Chromium is given the leaf's public-key pin, so it accepts exactly ONE certificate and still treats the origin as secure — which is what service workers, push and `getUserMedia` are gated on. WebKit has no equivalent pin; the run REPORTS what it got rather than asserting it. |
| **Six words, and no identifier** | The words on the pairing screen are derived on the phone from the certificate the Mac is actually serving, and they match the Node-side derivation exactly. No run of 16 or more hexadecimal characters appears anywhere on his screen. |
| **His message, once** | It appears the instant he sends it, before the Mac has answered; it turns to delivered when the Mac has it; and it is on screen exactly once — the optimistic bubble is replaced by the Mac's row, not added to. |
| **Rich streams** | The reply grew from 6 characters to 92 while the page watched, rather than arriving whole. |
| **Waiting, and surviving a relaunch** | With the Mac unreachable (its socket destroyed, not a convenient 503), the message says *"waiting to send — your Mac isn't reachable from here"*, survives a **real page reload**, and then reaches the Mac **exactly once**. |
| **The voice note the Mac receives** | A 1.32-second hold arrived as 42,284 bytes whose header reads `RIFF`/`WAVE`, format 1 (PCM), 1 channel, 16000 Hz, 16-bit — read off the bytes on the wire, not off what the page believed it sent. |
| **Older messages** | Scrolling to the top loaded earlier messages (13 rows became 53). No page number, no pagination control, anywhere. |
| **Contrast** | The shipped app's own contrast walker measured **151 text nodes and 1 indicator in each theme**: zero failures, zero colors that could not be proved, and **zero exemptions claimed**. |
| **No horizontal scroll** | The document was never wider than the viewport at 320, 375, 390 and 430 pixels, in dark and in light. |
| **A phone the Mac forgot** | A 403 carrying `revoked` stops the app, says so, and clears what the phone held. It is never retried. |
| **Affordances** | Every visible container that carries a state either carries the control that changes it or names where that control is. |

**The one skip, stated rather than hidden:** hold-to-record end to end does not run under WebKit,
because WebKit cannot be given a fake microphone. Chromium runs it, and **his own iPhone X answered
the same question on 2026-09-18** — 2.56 s of non-silent audio at −28.3 dBFS through an `AudioWorklet`.

**No sound was played in this room.** Chromium runs muted, with a synthesized microphone inside the
browser process; what the "hear it" check asserts is the fetch and the control's state. The standing
rule about audio on this Mac is not touched by anything here.

## The screenshots

Taken at 375 × 812 — his iPhone X — at device scale 2, in both themes and in both engines. Nothing of
his is in frame: every message in them is synthetic content the stub Mac seeded.

| file | what it shows |
|---|---|
| `webkit-pairing.png`, `chromium-pairing.png` | the six words, and the two honest answers |
| `webkit-thread-dark.png`, `webkit-thread-light.png` | the conversation, in the engine his phone runs |
| `chromium-thread-dark.png`, `chromium-thread-light.png` | the same, in the engine that can fake a microphone |
| `webkit-waiting.png`, `chromium-waiting.png` | a message waiting to send, with the reason and the control |
| `webkit-removed.png`, `chromium-removed.png` | the Mac having forgotten this phone |

## What this run does NOT establish

- **Nothing about his actual phone.** The stub Mac is not his Mac and Chromium is not Safari. The
  device questions were answered by his own probe walk on 2026-09-18 and are recorded in
  `richos-hq` under the same date.
- **Nothing about push end to end.** A real Web Push delivery needs Apple's push service and a VAPID
  key pair the Mac owns; the harness checks that the offer appears when notifications are off and
  that the service worker registers, and it does not pretend to have received a notification.
- **Nothing about the real route contract.** The stub answers `CONTRACT-STUB.md`, which is the
  phone's assumption, not Echo's file. When `phone-channel.md` lands, `lib/api.js` and `stub-mac.js`
  are what reconcile with it, and any difference is a finding rather than a surprise.
