# Phone probe — desktop verification, 2026-09-18

**What this records:** everything about `richos/tools/phone-probe` that could be established without
the CEO's iPhone, and — more importantly — the things that could not, named as such.

**Author:** Norm. **Branch:** `cc/norm-opus-probe1`. **Machine:** macOS 24.6.0, Node v25.5.0,
Chromium 147.0.7727.15 (Playwright 1.59.1, resolved read-only from the femcboost checkout; it is not
a dependency of the probe).

**The probe itself is the measurement.** Nothing below answers plan §3.2's five questions — those are
answered on his phone, which is the entire point. This records that the instrument works.

---

## 1. Unit tests — 30, no dependencies, no browser

```
$ npm test          # node --test "test/*.test.js"
ℹ tests 30
ℹ pass 30
ℹ fail 0
```

### The crypto, against the RFC's own vector

RFC 8291 §5 publishes a complete worked example — receiver key, auth secret, sender key, salt, and
the exact encrypted body. `lib/webpush.js` reproduces those bytes **exactly**:

```
✔ RFC 8291 §5: the encrypted body matches the RFC byte for byte
✔ RFC 8291 §5: setting the sender private key derives the RFC's sender public key
✔ the aes128gcm header is framed per RFC 8188 §2.1
✔ a round trip decrypts back to the plaintext, and the delimiter is 0x02
✔ a payload larger than the default record size still fits its declared rs
✔ RFC 8292: the VAPID header is a verifiable ES256 JWT whose aud is the endpoint ORIGIN
✔ generated VAPID keys are the shape the browser applicationServerKey wants
✔ a malformed subscription is refused loudly, not silently mis-encrypted
```

This matters beyond the probe: plan §3.5 assumption 3 flags as `unverified:` whether `ring` can cover
the VAPID JWT, HKDF and AES-GCM on the Mac side without a new crate. A readable, RFC-exact reference
implementation is the cheapest de-risking of that available.

### The audio, against signals whose answers are arithmetic

```
✔ peak and RMS of a half-amplitude sine are the textbook values
✔ digital silence reports -inf rather than 0 dBFS
✔ a three-second tone at a normal speaking level reads non-silent
✔ three seconds of silence reads silent, not failed
✔ a signal just either side of the stated -50 dBFS threshold falls the right way
✔ a slip of the finger is "too-short", never a failure
✔ no samples at all is its own outcome, distinct from silence
✔ the anti-alias filter passes speech and stops everything above 8 kHz
✔ the WAV header is a valid 16 kHz mono 16-bit PCM header
✔ the plan's stated size — about 32 KB per second — is what this actually produces
✔ samples are clamped, so one clipped sample cannot wrap to a click
✔ a full round trip: three seconds at 48 kHz yields a 3-second 16 kHz WAV of the stated size
```

---

## 2. A defect found and fixed: the downsampler was a weak filter

The first implementation of `downsample()` was a box average over each source window, on the grounds
that a box average is a low-pass and speech into whisper does not need better. **Measured, it is not
good enough.** Response at a 48 kHz capture rate, in-band reference 0.498:

| Tone | Box average | Windowed-sinc (shipped) |
|---|---|---|
| 500 Hz | 0.4982 | 0 dB |
| 8000 Hz | 0.2887 | **−238 dB** |
| 12000 Hz | 0.1667 (**−9.5 dB**) | **−113 dB** |
| 20000 Hz | 0.1057 (−13.5 dB) | −140 dB |

At −9.5 dB, most of the sibilance from a 48 kHz phone microphone folds back into the middle of the
speech band as hiss. **The probe's own check 2 passes either way**, which is exactly why this would
have shipped unnoticed — and plan §3.3 makes this recorder the one v1 inherits, feeding whisper.

Replaced with a 127-tap Blackman windowed-sinc at 0.45 × target rate, normalized to unity gain at DC
so a quiet recording is not attenuated toward the silence threshold by its own filter. Measured at
both rates a phone actually uses:

```
capture 48000 Hz:  100 Hz  0.0 dB | 500 Hz  0.0 dB | 2 kHz  0.0 dB | 4 kHz  0.0 dB
                   7 kHz -3.0 dB | 8 kHz -238.9 dB | 9 kHz -83.4 dB | 12 kHz -113.4 dB | 20 kHz -139.8 dB
capture 44100 Hz:  100 Hz -0.0 dB | 500 Hz -0.0 dB | 2 kHz -0.0 dB | 4 kHz -0.0 dB
                   7 kHz -2.8 dB | 8 kHz  -55.3 dB | 9 kHz -80.0 dB | 12 kHz -108.0 dB | 20 kHz -149.9 dB
```

---

## 3. Contrast — WCAG AA, computed, both themes

`test/contrast.test.js` computes **25 text pairs and 17 non-text indicators in each theme**, with
alpha composited over its real backdrop, and each row names the rule in `styles.css` it comes from. A
further test re-reads `styles.css` and fails if any token value drifts from the table.

**It caught a failure on the first run**, of exactly the class the standing rule predicts:

```
light   2.22:1  (floor 3)  --on-gold on --danger  — #record.recording, 21px 600
```

`--danger` flips lightness between themes where `--gold` does not: dark `--danger` is a light red,
light `--danger` is a deep red meant to be READ as text, not painted as a fill. Dark ink on it is
unreadable. Fixed with an `--on-danger` token that flips with the theme.

Worst values after the fix, of 84 computed pairs:

| Pair | Dark | Light | Floor |
|---|---|---|---|
| `--on-gold` on `--gold` (`.step-n`, `button.primary`) | 7.68:1 | **4.72:1** | 4.5 |
| `--on-danger` on `--danger` (`#record.recording`) | 7.04:1 | 8.12:1 | 4.5 (held above its 3.0 large-text floor on purpose) |
| `--trim-text` on `--surface-raised` | **5.29:1** | 6.74:1 | 4.5 |
| `--trim-text` on `--ground` (`.build`) | 5.91:1 | 5.90:1 | 4.5 |
| `--line-control` on `--surface-sunk` (control borders) | 4.65:1 | **3.50:1** | 3.0 |
| `--gold` on `--ground` (focus ring) | 7.68:1 | **3.15:1** | 3.0 |

**One exemption, declared:** `--line` draws the hairline around a card — a divider, not an indicator
(1.43:1 / 1.48:1 dark, 1.96:1 / 1.88:1 light). It is deliberately **not** extended to
`--line-control`, which draws the edge of a button, a text area and the level meter; those owe 3:1
and are asserted above. The privacy note at the bottom of the page is **not** exempted: he is being
asked to believe it, so it clears the same 4.5:1 floor as everything else.

The palette is lifted from `richos/app/ui/style.css`, the shipped app's own token file.

---

## 4. The real page, in a real browser

`node test/desktop-verify.js` — **all checks passed.** Headless Chromium with
`--use-fake-device-for-media-stream`, which synthesizes a tone as microphone INPUT inside the browser
process. **No audio was played through this Mac's speakers at any point**, and the page's optional
"play it back" control was never clicked.

Server, without a browser:

```
PASS  an unauthorized page request gets a flat 404, not an informative error
PASS  the page loads with the code
PASS  assets load without the code, so no markup reference can be missed
PASS  the manifest declares display: standalone — without it iOS gives no push at all
PASS  start_url carries the access code, so the installed app can load itself
PASS  the manifest is served as application/manifest+json
PASS  three icons are declared, including a maskable one   (+ each fetched and confirmed a real PNG)
PASS  the page gets the VAPID public key at runtime, so no key is committed
```

In Chromium — the recorder driven by a real 2-second synthetic press on the real control:

```
recorder said: 1.94 s, peak +0.7 dBFS, RMS -16.9 dBFS, 30976 samples at 16000 Hz,
               62.0 KB WAV. Captured at 16000 Hz via AudioWorklet.

PASS  check 2 captured non-silent audio through AudioWorklet + getUserMedia
PASS  it used the AudioWorklet path, not the deprecated fallback
PASS  it produced samples at 16000 Hz, the rate the Mac recognizer wants
PASS  the recording length matches the 2-second hold                 1.94 s
PASS  the 16 kHz sample count matches the duration                   30976 for 1.94 s (expect ~31040)
PASS  the WAV is the size the plan quotes, about 32 KB per second    62 KB for 1.94 s
PASS  the hand-written WAV header declares 16 kHz mono 16-bit PCM    RIFF/WAVE format=1 ch=1 rate=16000 bits=16
PASS  the browser's own decoder accepts the file
PASS  the service worker registers at the root scope
PASS  the dark theme paints its own palette      background rgb(12, 19, 34),    text rgb(223, 228, 238)
PASS  the light theme paints its own palette     background rgb(234, 230, 221), text rgb(12, 19, 34)
PASS  no JavaScript errors after the whole run
```

Two platform facts observed, both worth keeping:

- **`getUserMedia` ignored `channelCount: 1`.** The track reported **44100 Hz, 2 channels** while the
  `AudioContext` ran at a different rate entirely. This is why the code reads `audioCtx.sampleRate`
  rather than the track's settings; taking the track's word for it would have downsampled from the
  wrong rate and produced a file of the wrong duration.
- **`decodeAudioData` resamples to the context's own rate**, so `decoded.sampleRate` is always the
  context rate and can never confirm what a file declares. The first version of this harness asserted
  on it and produced a false failure. The header bytes are now read directly, with `decodeAudioData`
  kept only as proof that the file decodes at all.

Two harness bugs of mine were found and fixed on the way: the record control sits below the fold, so
`boundingBox()` returned viewport coordinates the synthetic press could not reach (the page correctly
did nothing); and a KB/KiB unit error in my own assertion, where the plan's ~32 KB/s figure was right
and my test's divisor was wrong.

---

## 5. Push — what was established, and what was NOT

**Established: Google's production push service accepts our VAPID header and rejects a tampered one.**
A well-formed request to a nonexistent subscription is answered *after* the service validates the
Authorization header, so the two status codes discriminate exactly the thing that cannot otherwise be
tested without a device. One character of the signature was flipped and nothing else changed:

```
fcm.googleapis.com     good JWT      HTTP 410  push subscription has unsubscribed or expired.
fcm.googleapis.com     tampered JWT  HTTP 403  permission denied: invalid JWT provided
```

That validates the ES256 signing, the `aud`-is-the-origin claim, the `k=` public key and the header
format against a live service — and it exercised the 410 path the code treats as a real event.

```
updates.push.services.mozilla.com   good / tampered   HTTP 404 / 404   (does not discriminate)
web.push.apple.com                  good / tampered   HTTP 403 BadJwtToken / 403 BadJwtToken
```

### NOT established, and named

- **`unverified:` a push delivered end-to-end to a browser subscription.** Neither Playwright's
  Chromium nor real Google Chrome under automation can register with a push service on this machine:
  both fail at `pushManager.subscribe` with `AbortError: Registration failed - permission denied`, an
  automation-profile limitation rather than a defect in the sender. The encryption is instead proved
  against RFC 8291's published vector and by an independent receiver-side round trip, and the VAPID
  header is proved against FCM as above. **The first true end-to-end delivery is check 4 on his
  phone**, which is what the probe is for.
- **`unverified:` anything about Apple's acceptance of our VAPID header.** `web.push.apple.com`
  returns `BadJwtToken` for a fabricated endpoint regardless of the `sub` claim, so the
  good-versus-tampered method does not discriminate there. Varying the subject was attempted
  (`mailto:probe@richos.invalid`, a real mailto, two https forms) and Apple stopped responding after
  two requests — it throttles repeated POSTs to nonexistent endpoints. **Consequence, and it is a
  real one: set `VAPID_SUBJECT` to a real `mailto:` or the deployed `https://` origin before
  deploying.** Do not rely on the `.invalid` default.
- **`unverified:` the five checks themselves.** By design.

---

## 6. The blocker: no Railway credential on this machine

The probe is complete and cannot be hosted. Escalated as **`esc-20260918T095409Z-e7d1c0d0`**
(`--state proceeding`).

```
$ railway whoami
Unauthorized. Please run `railway login` again.        # exit 1
$ env | grep -c RAILWAY
0
```

**A false premise in the brief, corrected.** The brief said to check
`femcboost/scripts/deploy-lib.sh` for "how the existing deploys authenticate (token in the
environment, not an interactive login)". That file contains **no Railway code at all** — it is a
git-directory resolver plus cross-tree deploy guards (304 lines; `grep -i railway` matches only a
comment about calling order). The actual mechanism is the opposite, and
`scripts/deploy-avelor-staging.sh:124-147` states it plainly: a **machine-wide interactive OAuth
session** in `~/.railway/config.json`, with its own 2026-07-31 incident note recording that restoring
it *"requires a HUMAN to complete a fresh interactive `railway login` — no script can self-serve past
a revoked OAuth session."*

`deploy-railway.sh` reproduces that preflight and stops there with the two options spelled out
(`railway login --browserless`, or a dashboard project token as `RAILWAY_TOKEN` — the second needs no
browser). Verified to fail at exactly that point with exit 1 and no side effects.

---

## 7. Cleanup

Every process this verification started was stopped. The harness kills its server on any exit path
including a signal, and after the run:

```
$ pgrep -fl 'phone-probe/server.js'   ->  no probe servers remain
$ pgrep -fl 'scratchpad/.*\.js'       ->  no scratch node processes remain
```

Scratch scripts were written to the session scratchpad, never into either repository.
