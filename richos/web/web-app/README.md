# Rich, on a phone

`richos/web/web-app/` — moved here from `richos/app/phone/` on 2026-09-18 by the CEO's own
instruction: *"we should create `/Users/alex/ab/richos/richos/web/web-app` and put the PWA in
there"*. The desktop app embeds this directory at build time (`app/src-tauri/build.rs`,
`embed_phone`), so a file added here is a file the shipped Mac app serves.

The static app the RichOS desktop app serves over HTTPS from the user's own Mac. One screen, four
verbs: **send text**, **send a voice note**, **receive Rich**, **hear Rich**.

No third-party service is in the message path at all. The phone talks to his Mac and to nothing else;
the one exception is the one Apple forces — an encrypted push notification transiting APNs, which
Apple cannot read. **No dependencies**, no build step, no framework: the files here are the files the
Mac serves.

The plan this implements is `richos-hq/docs/plans/richos-phone-client-2026-09-18.md`. The gate it
rests on was answered on the CEO's own iPhone X (iOS 16.7) on 2026-09-18: trust, install,
microphone, push with the app closed, tap-to-open — all passing, with one cost, which the section
below is about.

## The route contract

`CONTRACT-STUB.md` in this directory is **provisional**. The real contract is Echo's `phone-channel.md`,
which will sit with the other architecture notes under docs/architecture, and it did not exist yet
when this was written. Every route is behind `lib/api.js` so reconciling is an edit to one module and
its test. Anywhere the plan was silent and the phone had to choose, the stub says **CHOSEN HERE**.

## What is where

| | |
|---|---|
| `index.html`, `styles.css`, `app.js` | the screen and its wiring |
| `sw.js` | keeps the shell so the app OPENS where his Mac does not resolve; shows Rich's reply when the app is closed and writes it into storage on the way past; never caches anything under `/api/` |
| `lib/api.js` | the four routes, the API base seam, the signed challenge, and the failure classification the queue depends on |
| `lib/queue.js` | the on-phone send queue — durable before `enqueue` resolves, strictly in order, safe to retry, never retried after a final answer |
| `lib/thread.js` | the thread as a VIEW of the ledger on his Mac; the Mac's cursor is the only order |
| `lib/pcm.js`, `lib/recorder-worklet.js` | the recorder: `AudioWorklet` → 16 kHz mono WAV, no codec anywhere |
| `lib/fingerprint.js`, `lib/wordlist.js` | six words instead of a hash |
| `lib/storage.js` | one IndexedDB database: settings, queue, a cached view, and the non-extractable device key |
| `bin/make-icons.js` | the Home Screen icon, resized from the desktop app's own |

## Three decisions that are the product, not implementation detail

**The microphone prompt is part of the gesture, not a modal before it.** iOS asks for the microphone
on every launch of an installed web app — his own words after the probe: *"The only snag is that it
asks for the microphone permission on each launch."* So the first hold of the session opens the
microphone and the dialog lands under his finger. When he lifts that finger to tap Allow, the release
does **not** become a dead recording: the app says the microphone is on and asks him to hold again. A
dead recording there would be the app telling him the microphone is broken while it is working.

**The three send states are honest, and the middle one is real.** An optimistic bubble; then
*"waiting to send — your Mac isn't reachable from here"*; then delivered when the Mac has it. Under
the design this replaced, a relay held the message while the Mac slept. There is no relay, so it
waits on his phone — and a PWA cannot flush that queue in the background, which is why it goes when he
next opens the app somewhere the Mac can hear him.

**Nothing he reads is an identifier.** No message id, no device id, no cursor, no hash. His probe walk
ended with *"an ugly horizontal scroll bar ... caused by the long SHA256 which was all in one line"*,
and the rule that came out of it is not "wrap the hash" — it is do not put one in front of him. The
certificate authority is six words he can compare out loud.

## Running the checks

```
npm test                 # 77 checks, no browser, no dependencies
npm run verify           # the app in Chromium AND WebKit, against a stub Mac over real TLS
node test/desktop-verify.js --webkit     # one engine
```

`npm run verify` needs a Playwright that already exists on the machine — it is **not** a dependency
of this app. It prefers the one `app/ui/tests` installs, because that one has WebKit. If no
Playwright is found it says so and exits 0 rather than pretending to have verified anything.

The browser run ends in a dated record under `docs/verification/`, with screenshots at iPhone widths
in both themes.

## The floors this app is held to

- **WCAG AA in both themes, computed, never eyeballed.** `test/contrast.test.js` checks the palette
  pairs in Node; the browser harness walks **every text node** of the running app with the shipped
  app's own contrast walker, in dark and light. **No exemption is claimed anywhere** — every string
  on this screen is meant to be read, including the line that says a message is waiting.
- **No horizontal scroll, at any phone width, in either theme.** Measured at 320, 375, 390 and 430
  pixels. Nothing hides overflow to pass it; hiding it would only hide it from the check.
- **No pagination, ever.** Older messages load behind a scroll.
- **American English**, in every string he reads, including the name under the icon.
- **The visual language of the shipped app** — the tokens are `app/ui/style.css`'s own.
