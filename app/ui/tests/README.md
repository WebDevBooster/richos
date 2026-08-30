# `app/ui` browser acceptance harness

A home for the browser tests every UI slice was otherwise re-inventing and throwing away.
Slices 3, 5 and 7 each wrote one; only this one survived, and only because it has a
directory.

```
npm install          # once, in THIS directory — installs Playwright AND downloads WebKit
npm test             # every suite in this directory, discovered from disk
node workers.js      # one suite, while you are working on it
```

That is the whole setup, from a clean checkout, with no path into any other repository. It
was not, until 2026-08-30. **Playwright 1.61 ships no `postinstall` of its own**, so
`npm install` here used to produce the JS API and not one browser engine — and the suites ran
anyway, on this machine, because a webkit binary from an unrelated project was already sitting
in the shared `~/Library/Caches/ms-playwright`. Six consecutive runs of this directory were
launched with `RICHOS_PLAYWRIGHT` pointed into another repository's `node_modules`, and the
line above said they did not need to be. `package.json` now carries
`postinstall: playwright install webkit`, which downloads 77 MiB the first time on a machine
and takes under a second on every worktree after that, because the cache is shared.

If you would rather not have that download at all, the escape hatch is still there and is
still supported — it is now an opt-out rather than the only way in:

```
RICHOS_PLAYWRIGHT=/path/to/node_modules/playwright node run.js
```

`node_modules/` and `.shots/` are gitignored; `package-lock.json` is COMMITTED, because
`npm ci` is the only install command that refuses to resolve anything not already written
down and it does not run without one. The tests are the artifact; those PNGs are evidence for
one run.

**`shots-26/` and `shots-5b/` are the exceptions and ARE committed.** §26 names nine screenshots as
deliverables of the memory-strategy fixture, and until slice 8 this UI had no visual record
at all — the display on this machine has been locked for three slices and `screencapture`
returns a valid single-color (0,0,0) PNG. `memory-strategy.js` writes those nine, out of
WebKit's own compositor, pixel-verified. Two of the nine are deliberately not what §26 asked
for; the filenames and the suite's SCREENSHOT INVENTORY say which and why. `shots-5b/` is
the same arrangement for the correction desk: twelve states, written by `corrections.js`,
with `shots-5b/README.md` naming what each one is evidence of. `shots-5/` is the same again
for the feedback channel — nine states, written by `feedback.js`, with its own README. Both directories are
overwritten on every run and neither is byte-stable; read the suite's exit code, not a
`git diff` over a PNG.

## What is here

| File | What it proves |
|---|---|
| `workers.js` | §25 "AI workers", criterion by criterion, against the renderer in isolation. Includes the delegated-worker regression before/after and the cross-entity negative control. |
| `live-workers.js` | The LIVE half of §7, plus §6.4's disclosure. Every worker chip in it arrives through `RichTimeline.onWorkerUpserted` and never through a snapshot — the path `rich://worker-upserted` opened on 2026-08-29. Proves the live DOM and the reloaded DOM are byte-identical, that an `activity` row upgrades to a `worker_activity` row under the same id without stale fields, the cross-entity negative control on the live payload, and §6.4's two defaults with the CEO overruling both. |
| `inspector.js` | §7.2 the read-only inspector, §7.3 the background-work summary and §20's three breakpoints — through the REAL shell (`index.html` + `main.js` + `mock.js`). |
| `realbytes.js` | The join the other suites cannot make: the payload `cargo run --example timeline_payload` prints from a real ledger on disk, rendered by the real renderer. Catches field-name and shape drift between backend and UI. |
| `memory-strategy.js` | §26's sixteen-step fixture, driven end to end through the REAL SHELL by typing the prompt and pressing Enter. Injected clock (the two-hour turn runs in under a millisecond), the nine required screenshots, and the negative half: every §26 step this runtime cannot produce is asserted ABSENT. |
| `affordances.js` | THE RULE: a state the user could change must render the control that changes it. The state inventory is derived from source every run (`lib/state-strings.js`), classified in `lib/state-registry.js`, and the two sets must be EQUAL — a new user-visible string that nobody has classified fails the suite. Every ACTIONABLE state is then driven up in the real shell and its control asserted present, visible, enabled and interactive. Carries a negative control (the scrape examined 112 states, not zero) and four positive controls (a missing, a hidden, and a fake control, and an unclassified state, must each be flagged). |
| `lib/state-strings.js` | The derivation. Comment-stripping scanners for JS and Rust, HTML text nodes and human-readable attributes, `+`-concatenation folding, and four named blind spots. `node lib/state-strings.js` prints the inventory with file:line. |
| `lib/state-registry.js` | The classification, one row per state, each with its reasoning. Annotation only — the inventory above is the authority. |
| `lib/harness.js` | WebKit launch, the fixture page, pixel-verified screenshots, the four-line runner. |
| `lib/fixtures.js` | Timeline payloads in the exact shape `get_timeline` puts on the wire. |
| `steering.js` | §25 "Steering and stop", criterion by criterion, through the real shell. The `You stopped after {duration}` row from the real wire bytes, the crash that is never attributed to the CEO, a stop that reached nothing saying so, and the stop control at §20's three widths. |
| `restart-scope.js` | What happens BETWEEN threads, and what survives a restart. A working thread stays visibly active while another is selected and its timer resumes rather than restarts; drafts and scroll positions belong to one thread and never cross an entity; a turn streaming elsewhere renders nothing here, across entities and inside one; the fence is on every live handler, with the inventory derived from the shipped object and cross-checked against `timeline.js` on disk; duplicates render once; missed events recover from the snapshot; an in-flight turn survives a restart as unknown; a mid-turn crash draws the CEO's prompt once. |
| `corrections.js` | THE CORRECTION DESK (§7 "ask, never infer"), both families, through the real shell — RICH-TODOs row 5b. Confirm reaching the Rust desk and nothing written before it; the preview asserted byte-identical to the writer's own `--dry-run` output; a plain decline suppressing nothing and staying re-askable; a permanent decline landing on a visible list that lifts; an absent desk stating its reason instead of rendering an empty list, with the present-and-empty case as its positive probe; four refusals relayed verbatim to the screen rather than a console; the fourteen registered commands joined to `main.js` and `mock.js` on disk. Writes `shots-5b/`. Every check run RED once — `docs/verification/correction-desk-2026-08-30/mutation-runs.txt`. |
| `feedback.js` | THE FEEDBACK CHANNEL (`feedback.rs`), through the real shell — RICH-TODOs row 5. The rail control that never counts up at him and the absence of any trigger, asserted structurally; the question and four keys byte-identical to the Rust constants; the offer raised on 1 and 2 and on nothing else; a dismissal recorded and a closed panel recorded as nothing; the whole vocabulary on screen with ZERO free-text fields; the preview compared byte for byte against what `render_disclosure` really produces, the same terms in reverse rendering the same bytes, and the whole report visible without a nested scroller; an approval that records the terms and no prose; an approval for ALTERED text refused with its positive control beside it; four unrecognized keys refused rather than taken as dismissals; the store-would-not-open, read-refused and genuinely-empty states as three different facts; 40 answers in one column. Writes `shots-5/`. Every check run RED once — `docs/verification/feedback-channel-2026-08-30/mutation-runs.txt`. |
| `scale.js` | THE TWO PROMISED NUMBERS in §25 "Accessibility and performance" — RICH-TODOs virtualization row. 10,000 items through the real renderer in real WebKit: one new activity row costs 24ms (2ms of it JS) against a 257ms baseline, 999 of 1000 turn sections are asserted IDENTICAL BY REFERENCE, and the reused DOM is compared byte for byte against a from-scratch render. Plus the scroll frame budget with a scroll-container probe, the projection budget set BELOW the baseline it catches, the steering predicate against the brute-force scan it replaced, `turnRecord`'s order invariant across every mutation site, NO PAGINATION asserted structurally (every turn mounted, no page control), and a join to the Rust test that owns the OTHER 10,000 (the entity index, `app/src-tauri/src/main.rs`). Numbers: `docs/verification/timeline-scale-2026-08-30/`. Every check run RED once — `mutation-runs.txt` there, including the four that did not go red the first time. |
| `splash.js` | THE OPENING SCREEN and its off switch, through the real shell. The variation library asserted to be DATA — the file is stripped of its one assignment and handed to `JSON.parse`, so it cannot contain code — and the renderer asserted to hold no colour literal, so a new variation can only ever be a new entry. Every shipped entry forced and drawn in full; twelve real launches producing distinct compositions with zero immediate repeats; the palette study's chips, hexes and corner labels asserted ABSENT by element inventory; the whole curtain click-through with a centre click reaching the app beneath; the ceremony cut but the mark pinned rather than left as unlit steel; three unusable-library shapes each producing a normal launch and no half-drawn frame; a launch that never reports ready still clearing on its own ceiling; the switch found behind the gear, turned off, and still off after a relaunch, joined to `config.rs`'s durable default and the three registered commands; and the launch cost measured cold and warm, with and without, against a one-frame bar. Writes `shots-splash/`. Every check run RED once — `docs/verification/opening-screen-2026-08-30/mutation-runs.txt`. |
| `docs-claims.js` | The only suite that opens no browser. It joins the claims in `app/README.md`, `app/STREAMING.md` and this file to the tree they describe: per-file and per-crate test counts against `#[test]`, this table against the inventory `run.js` discovers, and every `rich://` name against the constants the Rust source declares. Nothing in it is typed — both sides of every join are read off disk. |

## Four rules, each one a thing an earlier slice got wrong
**This table is checked, not maintained by memory.** `docs-claims.js` fails if a suite
`run.js` runs has no row here, or a row names a suite that no longer exists. It was added
because `steering.js` had shipped one slice earlier with no row — the same drift `run.js`'s
own discovery exists to prevent, one level out in the documentation.

**1. The real renderer, never a copy.** Every page loads `../timeline.js` and `../style.css`
from disk. A test that re-implements a rule proves the test.

**2. WebKit, not Chromium.** Tauri renders through WKWebView on macOS. A green Chromium run
says nothing about what the CEO sees. `workers.js` caught a real WebKit-specific fact this
way: pressing Tab from a focused button lands on `BODY`, because macOS ships "Full Keyboard
Access" off and WebKit honours it. That is a system preference, not a renderer defect — and
it applies to every button in the app, not just the new ones.

**3. Nothing that only runs when somebody remembers.** `affordances.js` derives its own
inventory from disk on every run and refuses to report green over an empty one. The rule it
enforces is the one thing in this directory that has to outlive the pass that wrote it: a
rule with nothing enforcing it is the defect this project has found eleven times in two
days. Its part 5 is deliberately REPORT-ONLY and prints the number that made that call
(precision 70.8%, recall 54.8%, measured over all 112 states) — a check that cries wolf gets
deleted within a day, and then the CEO is worse off than before it existed.

**4. No faked screenshots.** `screencapture` on this machine has returned an all-black
1920x1080 PNG for three slices running (display locked). Every screenshot here comes out of
WebKit's own compositor, which does not depend on a display server — and every one is
decoded and pixel-counted before it counts as evidence. A shot with fewer than 8 distinct
colors across the sample grid throws; the real app measures 175. That check was documented
in `lib/harness.js` for one slice before it existed (the function measured file size, which
is exactly what a valid all-black PNG passes), and now it runs.

**4. A check that cannot fail proves nothing.** Every negative here carries a positive probe
in the same run — the same content, correctly scoped, IS on screen — because "the foreign
thread's text did not appear" passes perfectly on a page where nothing appears. Every
derived inventory is asserted non-empty before it is compared, because a green run over an
empty set is how a scanner in this repository reported CLEAN while walking nothing. And
every check in `restart-scope.js` was additionally run RED once, by breaking the thing it
guards in the shipped source: the ten runs are transcribed in
`docs/verification/restart-scope-2026-08-30/mutation-runs.txt`, with a coverage map and the
one check that has no mutation of its own named rather than left to be noticed.

Two of those runs changed the tests rather than confirming them, which is the argument for
doing it at all: deleting the fence's `threadId` clause left the scope check green (it was
probing across ENTITIES, which a different clause catches), and disabling the renderer's
supersession merge left the crash check green (the reload re-projects from a snapshot where
the superseded turn contributes nothing, so the END STATE was right either way).

## What these tests do NOT cover

They exercise the renderer and the shell. They say nothing about whether the backend emits
what the renderer reads — that is
`cargo run --example timeline_payload` in `app/src-tauri`, which prints the wire payload from
a real ledger through the real command body, and `cargo test -p richos-core`.

`docs-claims.js` is the one exception and does not use a browser at all: it reads documents
and source files. It checks that the claims are TRUE OF THE TREE, never that the behavior
they describe works — that is what everything else here, and the Rust suites, are for.

## What runs this

`.github/workflows/ui-suite-ci.yml`, on `macos-latest`, on a push that touches anything these
suites read. It runs `npm ci` and `npm test` and nothing else clever; the counting that makes
a green run mean something lives in `run.js`, so a developer typing `npm test` gets the same
gate the runner does.

**macOS, not Linux, and that is the expensive choice on purpose.** Playwright's Linux `webkit`
is the WebKitGTK port with a different graphics stack; on macOS it is a build of Apple's
WebKit, the engine family WKWebView renders through. An ubuntu runner would cost a tenth of
the minutes and would be answering a different question than rule 2 asks.

**`realbytes.js` may not run there**, and the workflow says so out loud with
`--allow-skip=realbytes.js`. It needs `cargo run --example timeline_payload` from
`app/src-tauri` — the detached workspace with the whole webview dependency tree behind it,
which `app-spine-ci.yml` also keeps off its test path on purpose, and which measures 1.3 GB
and about a quarter of an hour from cold. Allowed is not required: if the runner has cargo
and the build fits the timeout, the suite runs and the run says the allowance went unused. A
skip by any OTHER suite fails the run.

**And these suites still drive WebKit through Playwright, not the Tauri shell.** §23 Phase 6
— every acceptance state in the real shell — is not closed by any of this, and the workflow's
name and output do not claim it is.
