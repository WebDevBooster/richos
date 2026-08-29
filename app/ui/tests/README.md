# `app/ui` browser acceptance harness

A home for the browser tests every UI slice was otherwise re-inventing and throwing away.
Slices 3, 5 and 7 each wrote one; only this one survived, and only because it has a
directory.

```
npm install          # once, in THIS directory
npm test             # every suite in this directory, discovered from disk
node workers.js      # one suite, while you are working on it
```

If Playwright is already installed elsewhere on the machine, skip the install and point at
it — a browser engine per worktree is not free:

```
RICHOS_PLAYWRIGHT=/path/to/node_modules/playwright node run.js
```

`node_modules/` and `.shots/` are gitignored. The tests are the artifact; those PNGs are
evidence for one run.

**`shots-26/` is the one exception and IS committed.** §26 names nine screenshots as
deliverables of the memory-strategy fixture, and until slice 8 this UI had no visual record
at all — the display on this machine has been locked for three slices and `screencapture`
returns a valid single-colour (0,0,0) PNG. `memory-strategy.js` writes those nine, out of
WebKit's own compositor, pixel-verified. Two of the nine are deliberately not what §26 asked
for; the filenames and the suite's SCREENSHOT INVENTORY say which and why.

## What is here

| File | What it proves |
|---|---|
| `workers.js` | §25 "AI workers", criterion by criterion, against the renderer in isolation. Includes the delegated-worker regression before/after and the cross-entity negative control. |
| `live-workers.js` | The LIVE half of §7, plus §6.4's disclosure. Every worker chip in it arrives through `RichTimeline.onWorkerUpserted` and never through a snapshot — the path `rich://worker-upserted` opened on 2026-08-29. Proves the live DOM and the reloaded DOM are byte-identical, that an `activity` row upgrades to a `worker_activity` row under the same id without stale fields, the cross-entity negative control on the live payload, and §6.4's two defaults with the CEO overruling both. |
| `inspector.js` | §7.2 the read-only inspector, §7.3 the background-work summary and §20's three breakpoints — through the REAL shell (`index.html` + `main.js` + `mock.js`). |
| `realbytes.js` | The join the other suites cannot make: the payload `cargo run --example timeline_payload` prints from a real ledger on disk, rendered by the real renderer. Catches field-name and shape drift between backend and UI. |
| `memory-strategy.js` | §26's sixteen-step fixture, driven end to end through the REAL SHELL by typing the prompt and pressing Enter. Injected clock (the two-hour turn runs in under a millisecond), the nine required screenshots, and the negative half: every §26 step this runtime cannot produce is asserted ABSENT. |
| `lib/harness.js` | WebKit launch, the fixture page, pixel-verified screenshots, the four-line runner. |
| `lib/fixtures.js` | Timeline payloads in the exact shape `get_timeline` puts on the wire. |

## Three rules, each one a thing an earlier slice got wrong

**1. The real renderer, never a copy.** Every page loads `../timeline.js` and `../style.css`
from disk. A test that re-implements a rule proves the test.

**2. WebKit, not Chromium.** Tauri renders through WKWebView on macOS. A green Chromium run
says nothing about what the CEO sees. `workers.js` caught a real WebKit-specific fact this
way: pressing Tab from a focused button lands on `BODY`, because macOS ships "Full Keyboard
Access" off and WebKit honours it. That is a system preference, not a renderer defect — and
it applies to every button in the app, not just the new ones.

**3. No faked screenshots.** `screencapture` on this machine has returned an all-black
1920x1080 PNG for three slices running (display locked). Every screenshot here comes out of
WebKit's own compositor, which does not depend on a display server — and every one is
decoded and pixel-counted before it counts as evidence. A shot with fewer than 8 distinct
colours across the sample grid throws; the real app measures 175. That check was documented
in `lib/harness.js` for one slice before it existed (the function measured file size, which
is exactly what a valid all-black PNG passes), and now it runs.

## What these tests do NOT cover

They exercise the renderer and the shell. They say nothing about whether the backend emits
what the renderer reads — that is
`cargo run --example timeline_payload` in `app/src-tauri`, which prints the wire payload from
a real ledger through the real command body, and `cargo test -p richos-core`.

There is no CI runner wired to any of this yet. It runs when someone runs it.
