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
| `splash.js` | THE OPENING SCREEN and its off switch, through the real shell. The variation library asserted to be DATA — the file is stripped of its one assignment and handed to `JSON.parse`, so it cannot contain code — and the renderer asserted to hold no colour literal, so a new variation can only ever be a new entry. Every shipped entry forced and drawn in full; twelve real launches producing distinct compositions with zero immediate repeats; the palette study's chips, hexes and corner labels asserted ABSENT by element inventory; the whole curtain click-through with a centre click reaching the app beneath; the ceremony cut but the mark pinned rather than left as unlit steel; three unusable-library shapes each producing a normal launch and no half-drawn frame; a launch that never reports ready still clearing on its own ceiling; the switch found behind the gear, turned off, and still off after a relaunch, joined to `config.rs`'s durable default and the three registered commands; and the launch cost measured cold and warm, with and without, against a one-frame bar. Then, for the eleven MATERIAL versions RICH-TODOs row 9 added: a material layer's whole vocabulary read off `splash.js` rather than typed here, with an entry carrying a key outside it DROPPED from the pool; each entry's mat photographed as it ships and again with its material stack emptied and nothing else touched, and required to differ over a quarter of the mat AND to differ from v0's mat by as much, because a suede that renders as a flat navy rectangle is v0 with a different name; every number in the relief filter WebKit built joined back to the number in the library it came from, plus the merge order, which is the one thing in it that is not data; the settle asserted to pin the mark's relief rather than flatten it; and eleven side-by-side files, the mat as the SHIPPING renderer draws it beside the mat the study each entry NAMES draws. Writes `shots-splash/`. Every check run RED once — `docs/verification/opening-screen-2026-08-30/mutation-runs.txt` for the first thirteen, `material-reduction.txt` beside it for the five that came with the material (and for the one version, v18, that is deliberately NOT in the library). |
| `appearance.js` | THE TWO LIGHTINGS, THE TYPE KNOB AND WHOSE RAIL THIS IS — CEO rulings §14/§15 and his correction to round 10.1. Dark is the default UNDER A LIGHT OS (a build resolving `system` by default would look right on his machine and hand his ruling to a setting he never made); the choice is durable and config.rs wins any disagreement with the pre-paint mirror; the opening screen is always dark with the CEO's own preference left untouched, carries the settings button anyway, carries NO theme switch, and neither opening the menu nor pressing Bust a bug lifts its curtain — because a bug report must start from the screen the bug is on; the button is hit-tested ON TOP on six surfaces; the menu is theme -> Text size -> Techy Mode -> Bust a bug, in §15's order; ⌘+/-/0 calls preventDefault and moves the SAME persisted number the Text size row does, both directions observed, as does the Techy row against the rail's own preference; every font-size in the shipped CSS is rem off a scaled root and four sampled nodes move by exactly 1.1x together; `zoomHotkeysEnabled: false` is claimed in tauri.conf.json rather than inherited; the wordmark replaced 'My Company' and re-inks per theme; and the rail footer shows his initials and name, or — when there is no name — an EMPTY circle and 'Set your name', never an invented name and never '??'. Also the GUARD-RAIL on the splash off switch: it survived the menu rebuild, is present behind BOTH the gear and the settings button, moves as one state in both directions, and the local mirror splash.js reads on the next launch agrees with it. Writes `shots-10-1/` (six surfaces x both themes, plus the always-dark start screen). Every check run RED once — the mutations are listed at the foot of the suite. |
| `techy.js` | TECHY MODE, the renderer and the toggle (`machinery.rs`, `journal.rs`, `machinery_view.rs`) — open-items row 3.1 Phase 2. The turn's real tool calls with the merged command rather than the wire's placeholder title and the status each actually returned; `outcome not recorded` never folded into `done`; no rollup in technical mode, where three commands are three facts; the untyped vendor kind and the auto-approved permission present here and absent from the calm view; the shortcut pinning ONE conversation and the Settings switch reaching all the unpinned ones; a pin handed back to the default, which is what keeps §7.1 open; the calm view asserted BYTE-IDENTICAL across a round trip; the honest empty state for a thread from before the routing commit, and — separately, because they are different sentences — a store the OS refuses; the raw pane's three answers; no control of any kind; and no row for `agent_thought_chunk` or `fs/*`, which provably never arrive. Joined to the live Rust payload through `fixtures/machinery-payload.json`. Writes `shots-3-1/`. Every check run RED once — the mutations are listed at the foot of the suite. |
| `retention.js` | THE RAW-RETENTION WINDOW AS A SETTING (`journal.rs`'s `RawRetention`, `config.rs`'s `RetentionChoice`) — techy-mode design §7.2, open-items 1.4. §7.2 is the CEO's question and nothing in the suite answers it; what it proves is that every answer he could give now costs a click rather than a developer. The control found behind the same gear as the technical-view toggle, with three settable choices; those three joined to `RetentionChoice::parse` and to the harness's own window table, both read off disk, so a radio the backend would refuse fails here instead of silently doing nothing; the labels joined to the NUMBERS they stand in for (`RAW_RETENTION_DAYS`, `THREE_MONTHS_DAYS`), which live in a different file from the words; a tightened window announcing what it removed and which half of the record went, because `evict_raw` is an `unlink` and nothing else in the product would ever mention it; the loosened window claiming no removal and no restoration; both axes and the store's current cost in one sentence, so "keep everything" is an informed choice; no `localStorage` mirror for a setting that DELETES, with the store winning over the last click on every open; a hand-edited window reported as itself with no radio rounded on; and a refused choice leaving the surface on the store's answer. Writes `shots-7-2/`. The survival counts at four windows are Rust's half and are in `crates/richos-core/src/journal.rs`. Every check run RED once — the mutations are listed at the foot of the suite. |
| `contrast.js` | THE CONTRAST FLOOR (`CLAUDE.md` §"Contrast — WCAG AA, ALWAYS, BOTH THEMES"), computed rather than eyeballed. Seventeen driven surfaces × two themes: every visible run of text and the bounded non-text-indicator subset, resolved against the colours actually painted behind it via the browser's own paint stack, at 4.5:1 / 3:1. The arithmetic is checked against WebAIM's published values and then proven to be the SAME SOURCE running inside WebKit rather than a second copy. The exemption is machine-readable — `data-contrast-exempt="<why>"` — and a declared one passes AND IS PRINTED with its reason and the ratio it was excused at, while an empty or one-word claim fails as a mute button; check 12 prints the whole inventory so creep is a number. An unresolvable colour (gradient, blend mode, filter, backdrop-filter, transparent text) is a FAILURE TO PROVE and has its own ledger, currently one entry: the opening screen's tagline, which sits on a gradient under two blend-mode layers and cannot be proven by any DOM checker. Text behind an `aria-modal` dialog is inert and is filed obscured, and check 11 refuses to let that bucket become a hiding place by requiring every node in it to be measured on a surface where the dialog is closed. `contrast-debt.json` holds the 53 colour pairings the shell was ALREADY failing on 2026-08-30, capped so it can only shrink, plus a per-surface node floor in the spirit of run.js's `observed >= declared`. Writes `shots-contrast/`. Every check run RED once — the mutations are listed at the foot of the suite. |
| `updates.js` | THE UPDATE SURFACE (`src-tauri/src/updates.rs`, `ui/updates.js`) — RICH-TODOs row 12, which said there was no updater of any kind. What a browser CAN prove, with what it cannot said first: it cannot apply an update, and that is proven where it happens, by `app/scripts/updater-e2e.sh` building 0.1.0 and 0.1.1 and making one become the other on this machine. Here: the row lives in the UNIVERSAL settings menu and is reachable from every screen; all nine states `updates.rs` declares render a sentence, with the inventory read out of the Rust rather than typed, and an UNRECOGNIZED state reporting itself as unrecognized instead of falling back to "up to date"; "never checked" and "checked and current" are different sentences; the shipped `.invalid` endpoint reports a DECISION NOT MADE rather than a failure, and a non-default endpoint is disclosed on screen; a REFUSED SIGNATURE is not offered a retry while all six other failure kinds are; the vendor's own error text verbatim behind a disclosure; no percentage and no `aria-valuenow` without a `Content-Length`; the mark on the settings button for exactly two of the nine states, arriving with the menu shut; Install and Restart asserted on the COMMANDS ISSUED rather than on a button looking pressed; and the row surviving a `forceDark` menu rebuild. Contrast for this surface is deliberately NOT here — it is `contrast.js`'s three `updates-*` surfaces. Writes `shots-updates/`. Every check run RED once — the mutations, and the two that reddened more than their own check, are listed at the foot of the suite. |
| `setup.js` | FIRST-RUN SETUP at the surface — Option D (`crates/richos-core/src/setup.rs`, `src-tauri/src/setup_view.rs`). The launch blocker `ceo-decisions.md` §19 states in its own words: *today RichOS runs on his Mac and would not run on anyone else's*, because a customer needs Claude Code AND the engine directory and the engine ships in no payload. What this suite holds: a customer's Mac ASKS, and asks this before the memory question and before the company question — with both held-back questions proven to be asked rather than dropped; NO terminal, no path, no tilde, no shell variable and no version number anywhere on the sheet, computed from the rendered text rather than intended, and ZERO text fields, because his part is one press; the BYO-Anthropic caveat present and ABOVE the button, compared by document position, because row 3.14's second condition is that D must not be sold as zero-touch; each missing piece named AND explained, with the title agreeing with the count; a build that cannot install an engine EXPLAINING and naming the party instead of drawing a button that would certainly fail; a failure rendered verbatim with the sheet still usable and the button relabelled to say what pressing it does now; PROGRESS driven by the backend's events rather than by the return value, asserted through a MutationObserver over the whole run, because a sheet that only rendered the answer would sit silent for the minutes Anthropic's installer takes; a machine that has everything neither asked nor skipped-without-checking; the button un-pressable twice; and — structurally, over the shipped source — exactly one `run_setup` call site. Contrast for this surface is `contrast.js`'s two `setup-*` surfaces. Every check run RED once — the mutations are listed at the foot of the suite. |
| `memory.js` | FIRST-RUN PROVISIONING at the surface (`provision.rs`, `src-tauri/src/memory.rs`) — the gap the installed bundle was measurably in on 2026-09-01, when its company memory reached it only because an engineer typed a symlink by hand. A fresh install ASKS, and asks this before the company question, one dialog at a time — with the held-back question proven to be asked rather than dropped; the location is SHOWN and the string sent to `provision_memory` is compared byte for byte against the string on screen, driven from a location the surface could not have guessed so a hard-coded path fails instead of agreeing; ZERO text fields in the dialog, because his part is a choice and never a path he types; one press producing exactly one command; a refusal from the backend rendered as it stands with the control still live, because `provision`'s messages each name the thing to do; a corpus the install cannot read naming the party and drawing NO button for a thing no button could do; an install that is already set up neither interrupted nor provisioned; and — structurally, over the shipped source — exactly one `provision_memory` call site, passing the offered location, with no corpus path literal anywhere in `main.js`. Contrast for this surface is `contrast.js`'s two `memory-*` surfaces. Every check run RED once — the mutations are listed at the foot of the suite. |
| `home.js` | THE HOME SCREEN — `round-11.1/v1` "Constellation" ported into the app, the switch out of it, and the way back (CEO, 2026-09-01: it "must be shown in the app after the splash screen", with "some way for the user to switch" and "a click on the logo (in the upper left corner) brings the user back"). Through the real shell: it is the surface the app lands on, over an inert `#app`, at a z-index under the curtain and under the settings button; §15's permanent always-dark exception held as a FORCE flag with the CEO's own light-mode preference intact underneath it, and the settings menu on it carrying Bust a bug and no theme switch; the picture asserted to be the round's own numbers — 7,500 objects, 12,817 links, 4,800 sources, and v5's `nodeScale` and `clickZoom` — so a tuning pass on a signed-off design fails here; the company row proven to be the REGISTRY's six in registry order with `richos` as ONE button despite two roots, "All companies" as a pressed default rather than an absence, wrapping into rows inside a 500px cap that cannot reach either text column, ABSENT below two visible companies with the composition back at the round's own pixel, and a one-character label rendering as a 46px pill rather than a cramped lozenge; a label proven to be a MASK — every entity id unchanged through an anonymizing pass and back; the settings panel listing every company including the hidden ones, writing through to the row live, and measured in BOTH themes; the switch stopping the frame loop (frames stop and are still stopped 1.5s later) and the logo resuming it without a rebuild; and CONTRAST measured FROM THE PIXELS, because almost every line of this surface sits over a `<canvas>` that `contrast.js`'s DOM walk states it cannot read — glyph line boxes, border rings with the rounded corners excluded, indicator halos stepped past, and the element's own opacity folded into its ink. 16 elements, worst 4.23:1. Writes `shots-home/`, six of which are committed. |
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
