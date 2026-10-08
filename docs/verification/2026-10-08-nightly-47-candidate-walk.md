# Walk of nightly candidate 47 (`v1.2.0-nightly.20261008.47`), 2026-10-08

**Verdict: READY.** Candidate 47 fixes the three items candidate 46's walk
(`docs/verification/2026-10-08-nightly-46-candidate-walk.md`) left open, each walked the way it was
found there, on the candidate's own signed bundle in the test VM:

| Item | Result |
|---|---|
| D17. The greeting and the voice row show his voice icon, not `◉` | **PASS** in light and dark; one small gap seen (D20, below, does not block) |
| D19. The setup sheet opens on Set it up; Tab still reaches the link | **PASS** in light and dark, in two guests; Return starts the setup |
| D18. "Dictation is on. Try it in the box on the right, or in any app." after turning it on | **PASS** through System Settings (sheet walk, `sheet_says_feedback: true`) and with the grants already there |

Everything else passed on 46 and was not walked again, as the brief says.

## What changed since candidate 46, re-derived

- **The brief's account of 46 holds.** The 46 record ends "Verdict: NOT READY" with D17 and D19
  marked "blocks" and D18 "does not block on its own"; it lists nothing else as failing.
- **Source.** 46 was built from `c6e6c42c4` and 47 from `7b24dbad8`. Between them,
  `git log --oneline --no-merges c6e6c42c4..7b24dbad8` lists ten commits:
  - the product changes are `3a848b75b` (D17 and D19: `ui/home.js`, `ui/main.js`, `ui/timeline.js`,
    `ui/style.css`, plus its test) and `670d97284` (D18: `ui/dictation.js`);
  - the rest are tests, the 46 walk record and its step lists, the D18 verification record,
    screenshot references (`b7b25ac53`), the sheet walk's new D18 requirement (`eb38ccb99`,
    `d95c59bea`) and two autocheck commits. None of them is app code.
- **So "47 is 46 plus these fixes" holds.**

## Identity, checked before any claim: PASS

- **The zip.** `shasum -a 256` of `RichOS-1.2.0-nightly.20261008.47-macos-aarch64.zip` gives
  `70075ada2068dd2b0685b448e818b37fca089683198e8c4e8b8cd39995935591`. Both of its lines in
  `SHA256SUMS` carry that hash: the versioned name and `RichOS-macos-aarch64.zip`.
- **The engine.** `richos-engine-1.2.0.tar.gz` gives
  `90885f4a595fa40cdf19888f0aad29e18f4b24b453c9a662cde1d020b575a136`, its `SHA256SUMS` line. That
  is the same hash as candidate 46's engine: no engine change.
- **`candidate.json` `info`:**
  - `source_commit` `7b24dbad86fc0a8a9d02eca223ecdb8a8a51b5d2`;
  - `run_id` `20261008T223227Z-c3194770`;
  - `version` `1.2.0-nightly.20261008.47`;
  - `build_commit` `13e1fcd66ce9e3783a9c22e282147331de995e8e`.
- **The build commit.** Its parent is `7b24dbad8`. `git diff --stat 7b24dbad8 13e1fcd66` touches
  only four files: `nightly-build.json`, `Cargo.lock`, `Cargo.toml` and `tauri.conf.json`.
- **The running app.** The sheet walk's identity step read "built from
  `13e1fcd66ce9e3783a9c22e282147331de995e8e`" and passed (`--expect-sha 13e1fcd66`).
- **The Settings version line.** It reads "RichOS 1.2.0-nightly.20261008.47 is up to date."
  (run T, step 32, accessibility find, `value='RichOS 1.2.0-nightly.20261008.47 is up to date.'`).
  Runs S and T ran the same zip.

## D17: his voice icon in the greeting and the voice row — PASS

Run T (`walk-6499c1648d86`), `steps-walk.py` with `steps/walkT.json`, as 46's T3: a company added,
the speech models and their first timing decodes waited out, then the greeting, the button in both
states, light and dark. The talk button ran on a file of 30 s of silence
(`RICHOS_VOICE_INPUT_WAV`, the microphone grant written the way `voice-walk.py` writes it). Nothing
was played.

**The greeting** (frames `t-composer-light`, `t-composer-dark`; enlarged in
`t-greeting-icon-light`, `t-greeting-icon-dark`):
- On screen: "I'm Rich, your chief of staff. Tell me what you're working on and I'll take it from
  there. You can type, or tap [his voice icon] to talk to me." The icon is a small copy of the
  button: a ring, a gold disc and five bars, set in the line at text height.
- In the accessibility tree: "… You can type, or tap " then " to talk to me." with nothing between
  (step 25 and the tree `t-03-composer-light.tree`).
- **No `◉` on screen.** A find for "◉" returned "nothing matched" (step 26).
- **Light and dark like the button.**
  - Light: a dark ring, a gold `#9C7C34` disc and dark bars.
  - Dark: a light ring (`#D4D8E3` at its core pixel), a gold `#C2A35C` disc and dark bars.
  - Those are the button's own two resting faces, as the 46 record measured them on the button.

**The voice row while talking** (frames `t-talk-listening-dark`, `t-talk-listening-light`; enlarged
in `t-footnote-dark`, `t-footnote-light`):
- On screen: "headphones recommended · tap [his voice icon] to end voice".
- In the accessibility tree: "headphones recommended · tap " then " to end voice" (step 44, tree
  `t-06-talk-listening-dark.tree`).
- **No `◉`.** A find for "◉" returned "nothing matched" (step 45).
- **Light and dark.** The icon follows the theme. Its ring takes the footnote's own muted color, as
  the button's ring takes its text color.
- **The button still works** (unchanged from 46): `AXToggle title='Talk to Rich' value='0'` at
  rest, `title='Stop talking' value='1'` after the press, and back again, in both themes (steps
  29, 43, 54).

**Contrast** (`qa/contrast.py`; the icon parts with `qa/frame.py edges` and the 3:1 non-text
floor):

| What | Light | Dark |
|---|---|---|
| the greeting's text, both sides of the icon | 14.90:1 | 14.55:1 |
| the voice row's text, both sides of the icon | 4.99:1 | 6.11:1 |
| greeting icon: ring on the page (core pixel) | 13.26:1 (`#181F2C` on `#EAE6DD`) | 13.01:1 (`#D4D8E3` on `#0C1322`) |
| greeting and voice row icon: disc on the page | 3.15:1 (`#9C7C34` on `#EAE6DD`) | 7.68:1 (`#C2A35C` on `#0C1322`) |
| bars on the disc | 4.72:1 | 7.68:1 |
| voice row icon: ring on the page (core pixel) | 3.77:1 (`#717477` on `#EAE6DD`) | 4.75:1 (`#7C818D` on `#0C1322`) |

The light disc on the page, 3.15:1, is the same figure the button itself has (46 record). It
clears 3:1. At about 18 px the ring is one antialiased pixel wide, so its figure is that pixel's
color, not the token.

**D20 (new, small, does not block). While voice is on, the voice row draws the icon's resting
face, and the button beside it shows its listening face.**
- The button, listening: a dark disc and gold bars.
- The row's "tap [icon] to end voice": a gold disc and dark bars.
- Frames `t-footnote-dark` and `t-footnote-light` show both side by side.
- The row only shows while voice is on, so the two never match. The shape (ring, disc, five bars)
  is the same, and there is only one such button on screen, so the sentence still points at the
  right thing. That is why it does not block. It is a polish item:
  - by the code (hypothesis), `inlineTalkIcon` clones the svg once at load;
  - the listening colors are keyed to `#talk-toggle[aria-pressed="true"]` (`ui/style.css` lines
    1633 to 1660), which the copy in the row is not inside.

**Not walked:** the third sentence `3a848b75b` changed, "The mic still won't open. … Tap ◉ when you
want to try voice again." (`ui/main.js:4537`). It needs a microphone that fails to reopen, which
the guest cannot stage. By the code it goes through the same `tl-notice-body` path that now calls
`inlineTalkIcon` (`ui/timeline.js:2277`), so it should show the icon (hypothesis, not seen).

## D19: the setup sheet opens on Set it up — PASS

Run S (`walk-06b8f257060a`), `steps-walk.py` with `steps/walkS.json`, as 46's S: the engine moved
aside in the guest so the app sees none, and the guest's Claude Code signed out (credential file
and keychain items removed in the guest only; `"loggedIn": false`). Then the app was relaunched.
The speech models were left in place, as in 46's run S.

- **Focus at open: Set it up.** Three seconds after the sheet appeared, before anything was pressed,
  `ax.sh --focused` read `role: AXButton`, `title: Set it up` (step 10).
- **In dark too.** After the guest switched to dark, still Set it up (step 16).
- **What a person sees.** Set it up wears the focus ring: a gold outer ring, then a dark ring, then
  the button (frames `s-ask-light`, `s-ask-dark`). The pricing link has no box around it.
- **A second guest agrees.** Run T's first sheet was the setup sheet in another state (engine
  present). There too, `--focused` read Set it up (T step 4).
- **Tab still reaches the link.** Tab presses (key code 48, sent to the app's pid):
  - 1: Not now;
  - 2: the page itself (`AXWebArea`, nothing on the sheet ringed, frame `s-tab-2`);
  - 3: the link, `AXLink` "sign up there first and pick the Max/Max 20x tier", drawn with its
    gold boxes (frame `s-tab-3-link`);
  - 4: Set it up again.
- **Return does the obvious thing.** After a fresh relaunch, focus was on Set it up again (step
  40). Return (key code 36) was pressed:
  - RichOS stayed the front app (`com.richos.app`, step 44); no browser opened;
  - the sheet turned to "Setting things up", with the engine "Installing…" (step 45, frame
    `s-after-return`).
- **The guest's keyboard setting.** `AppleKeyboardUIMode` is 3 (keyboard navigation on), so Tab
  moves through every control. A Mac with keyboard navigation off was not tried.

**Contrast of the focus rings** (`qa/frame.py edges`, `qa/contrast.py --nontext`):

| Ring | Light | Dark |
|---|---|---|
| Set it up: outer gold ring on the sheet | 3.83:1 (`#9C7C34` on `#FDFCF8`) | 6.36:1 (`#C2A35C` on `#182440`) |
| Set it up: dark inner ring against the gold button | 4.72:1 | 7.68:1 |
| Set it up: dark inner ring against the sheet (light) | 18.07:1 | — |
| the link, when Tab reaches it: gold box on the sheet | 3.83:1 (`#9C7C34` on `#FDFCF8`) | not photographed in 47 |

The text on the sheet was measured on 46 in both themes. `3a848b75b` does not touch the sheet's
colors or words: it does not change `index.html`, and its only `style.css` change is the new
`.talk-icon.talk-icon-inline` rule (`git show 3a848b75b`). So those figures stand.

## D18: "Dictation is on. Try it in the box on the right, or in any app." — PASS

**Through System Settings, the way a person does it.** Run A (`walk-3a4095cbacf6`),
`dictation-sheet-walk.py --steps identity,stage,relaunch,switch-on,mic-prompt,ax-prompt,granted-settings`.
Since `eb38ccb99`, granted-settings fails without the line. Every step passed, exit 0:

| Step | What it showed |
|---|---|
| identity | "built from `13e1fcd66ce9…`" |
| stage | no grants at all |
| switch-on | the sheet said Off first; the switch pressed |
| mic-prompt | Iris's sentence read by OCR in macOS's prompt; Allow pressed in the prompt |
| ax-prompt | macOS's Accessibility prompt on screen |
| granted-settings | the sheet's Open System Settings, the Accessibility pane, RichOS's switch, the password, Modify Settings. The tool's key tap came 0.09 s after the switch. `sheet_says_on: true`, **`sheet_says_feedback: true`**, `same_app_pid: true` |

**As a person sees it** (frame `a-granted-settings-sheet`):
- the gold card says "On. Tap F1 in any app, talk, and tap it again.";
- under "Works only while RichOS is open…", a gold check and "Dictation is on. Try it in the box on
  the right, or in any app.";
- the cursor waits in Try it here.

That is round 19's state 10 as the 46 record describes it.

**With the grants already there** (the other way 46 found it): run T, second half, steps 59 to 76.
- The Accessibility row was written and the app relaunched; then Settings, Dictation, the switch.
- 8 s later the tree had both "On. Tap " (step 70) and "Dictation is on. Try it in the box on the
  right, or in any app." (step 71).
- Frames `t-sheet-on-light` and `t-sheet-on-dark` show it in both themes.

**Contrast:**

| Line | Light | Dark |
|---|---|---|
| "Dictation is on. Try it in the box on the right, or in any app." | 17.02:1 | 13.02:1 |
| its check mark (gold) | 6.26:1 | 6.87:1 |
| "On. Tap F1 in any app…" (unchanged) | 18.07:1 | measured on 46 |

## Seen, outside the brief's three items (not judged)

- **Screen readers hear nothing where the icon sits.** The inline icon is a copy of the button's
  `aria-hidden` svg. So the accessibility tree reads "You can type, or tap " and " to talk to me."
  as two pieces with no name between them (and the same for "tap … to end voice"). VoiceOver was
  not run.
  - The old `◉` would have been read as a symbol name, which was not helpful either.
  - A label such as "the Talk to Rich button" on the copy would fix it (hypothesis).
- **One Tab stop on the setup sheet lands on nothing visible.** Between Not now and the link, focus
  goes to the page itself (`AXWebArea`, frame `s-tab-2`). A keyboard user presses Tab once and
  sees no ring anywhere. This is how WebKit wraps focus around a page. The D19 change does not
  cause it, and it was not compared with 46.
- **The company sheet opens with nothing focused.** In run T, "Which company is this copy of Rich
  for?" opened with focus on the page (`AXWebArea`, T step 9, frame `t-company-sheet`), not on
  "What's the company called?".
  - Not compared with 46.
  - Under both the old and the new focus rule in `home.js`, the home screen's give-way would have
    focused a control. It focused nothing, so that path did not run here and D19 did not change
    this sheet (hypothesis from code).
- **The first-run timing decodes are still doubled.** Run T's guest ran two large-model
  `whisper-cli` decodes at once (pids 1858 and 1859, step 21), as the 46 record noted. Same
  candidate code for that path.

## Verification mode

- **Environment.** The test VM, one fresh guest per run through `run-walk.py`, never this Mac's
  screen.
  - At most two guests at once, one per slot. A and S overlapped; S waited 390 s for admission.
  - One app window per guest, no two-user test.
  - Guest screen 1680x1050 at 1x; the app window 1400x864.
  - Light and dark were switched through the guest's own macOS appearance; the app follows it.
- **Artifact.** The candidate's own signed zip, with the same folder's `richos-engine-1.2.0.tar.gz`
  as `--engine`.
- **Account.** The real Claude login that `run.sh` copies into each guest. Run S removed that copy
  inside its own guest only; no token was revoked and no account file on this Mac was written.
- **Audio.** No sound was played anywhere.
  - The sheet walk's sample is a file written with `say -o` ("The quarterly numbers look better
    than we expected this morning.") and `afconvert` to 16 kHz mono, 3.042 s.
  - The talk-button run fed 30 s of silence.
- **Verification basis.** Every PASS above was seen on the running candidate in the guest: its
  accessibility tree, its frames, and the walks' own reports. The lines marked "hypothesis" are
  read from code and were not seen.

### Runs

| Run | VM | Walk | Result | Seconds |
|---|---|---|---|---|
| A0 | `walk-655aa917b638` | the sheet walk, started wrongly | harness, mine: I passed `python3` as the command, so `run-walk.py` put the VM name after it ("can't open file …/walk-655aa917b638"); scenario 0.02 s, exit 2, nothing of the app tested | 31 |
| A | `walk-3a4095cbacf6` | `dictation-sheet-walk.py`, through granted-settings | **7 of 7 PASS, exit 0** | 567 |
| S | `walk-06b8f257060a` | `steps-walk.py`, `walkS.json` | **every step that may not fail passed, exit 0** | 114 |
| T | `walk-6499c1648d86` | `steps-walk.py`, `walkT.json` | **every step that may not fail passed, exit 0** | 411 |

Each of the four ended "clean: app quit, VM stopped, clone deleted, state removed." and released its
slot. The `allow_fail` steps that failed:
- in T, the two "◉" finds (nothing matched, which is the PASS for D17) and one wait for the
  decoders that ran out before the next wait passed;
- in S, the find for "all set" just after Return (nothing matched: the setup was still running).

## Method and toolkit

The walks and tools are `richos/app/scripts/` on this branch (the candidate's source `7b24dbad8`
plus this record). The `qa/` tools are the same as at `4e142bc0e`.

**`testvm/`:**
- `run-walk.py --wait 900` with `TESTVM_AX_TIMEOUT=60`, and `slots.py status`;
- `dictation-sheet-walk.py --steps identity,stage,relaunch,switch-on,mic-prompt,ax-prompt,granted-settings`;
- `steps-walk.py --steps …/steps/walkS.json` and `…/steps/walkT.json`, and `--check` on both.

**`qa/`:**
- `contrast.py` on frame regions, and on color pairs read with `frame.py edges`;
- `frame.py` (`edges`, `crop`);
- `ocr-gate.sh` with its positive control;
- `wait-for.sh --file`.

**Elsewhere:**
- `nightly-local.py candidate --run 20261008T223227Z-c3194770`;
- `shasum`, `jq`, `git log`, `git show`, `git diff --stat`;
- `say -o` and `afconvert` for the sample; `sips` and `ditto` for the JPEG copies.

**Scripts written from scratch: none.** Two data files were added: `steps/walkS.json` and
`steps/walkT.json`. They are declared in `steps-walk-data.test.sh`'s inputs and covers rows, and
that suite passes (3 ok lines).

### Frames

- **Format.** JPEG q80 copies of the 1680x1050 PNG originals. The four `*-icon-*` and `*-footnote-*`
  frames are crops enlarged 3 to 4 times.
- **Names.** The run letter, then what the frame shows.
- **The privacy gate.** `ocr-gate.sh` ran over the 17 PNGs these JPEGs were made from. Its positive
  control found the known address first; then "0 of 17 frame(s) carry something that must not
  ship".
- **The run evidence** (`runs/*.txt`, JSON as each tool wrote it) carries this Mac's home folder as
  `~`. A search for an email address in it found none.

## Surfaces

**Applied and checked:**
- the Mac desktop app from its signed bundle, in light and dark:
  - first run (the setup sheet, engine missing, signed out);
  - a returning launch (relaunches);
- every entrance to the three fixes the brief names:
  - the greeting;
  - the voice row while talking, by the talk button's accessibility press;
  - the setup sheet's first focus, Tab and Return;
  - the Dictation sheet turned on through macOS's prompts and System Settings, and with the grants
    already there;
- a side surface of the D19 change: the first focus of the other first-run sheets (the setup sheet
  with the engine present, and the company sheet).

**Not applicable:**
- phones: nothing touched;
- battery: no `richos/mobile/**` change;
- the stable channel and publishing: nothing was published.

**Not covered:**
- VoiceOver;
- a Mac with keyboard navigation off;
- the "mic still won't open" notice (see D17);
- the link's focus box in dark on 47 (seen on 46).

**Test data.** Each guest was a fresh clone with its own empty home. Nothing touched this Mac's app
data, and no app was started on this Mac.

## Cleanup

- **The runs.** All four ended clean (table above).
- **After the last run:**
  - `slots.py status` read "guest.lock: free" and "guest-2.lock: free";
  - `~/.richos-testvm/tart/vms/` holds only `richos-base`;
  - `~/.richos-testvm/run/` is empty.
- **Scratch.** `/Volumes/E1TB/tmp/claude/ray-opus-walk47/` is deleted after this record is committed.

## Defects, in one list

- **D17: fixed.** No `◉` on screen in the greeting or the voice row; his icon in both themes.
- **D18: fixed.** The line shows after turning dictation on, both ways.
- **D19: fixed.** The setup sheet opens on Set it up; Tab reaches the link; Return starts the setup.
- **D20 (new, does not block).** While voice is on, the voice row's inline icon shows the resting
  face (gold disc, dark bars), and the button beside it shows its listening face (dark disc, gold
  bars). The shape is the same, so the sentence still points at the right button.

Verdict: READY
