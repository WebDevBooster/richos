# Walk of nightly candidate 46 (`v1.2.0-nightly.20261008.46`), 2026-10-08

**Verdict: NOT READY.** Dictation itself works on candidate 46's own signed bundle in the test VM:
the bar walk passed all 18 of its steps, the sheet walk passed every step through granted-settings
and try-it, and nothing anywhere says "On even when RichOS is closed" or mentions Login Items. Two
new defects block it, both made by this candidate's own changes, both small to fix:

- **D17.** The new Talk-to-Rich button is his voice icon, but Rich's first greeting still says
  "You can type, or tap **◉** to talk to me", and the voice row still says "tap **◉** to end voice":
  the old circle, which is no longer on screen.
- **D19.** The setup sheet opens with keyboard focus on the new pricing link, drawn boxed in gold,
  instead of on Set it up; Return there would open the browser.

One smaller gap rides along: **D18**, the sheet never shows round 19's "Dictation is on. Try it in
the box on the right, or in any app." after turning it on.

Everything else the brief named passes: his account sentence word for word with the underlined
link, the hover text "claude.com/pricing", the click opening https://claude.com/pricing, no
Account type menu on the sign-in step, no "Setup is done." (and no "You're all set.") while the
voice and video tools still download, and every readable line measured in light and dark at AA.

| Item | Result |
|---|---|
| 1. Dictation in any app | PASS on function (bar walk 18/18, sheet walk 8/8, the note and its absent lines); D18 against round 19 |
| 2. The Talk-to-Rich button | PASS on the button in both themes and states; FAIL on D17 |
| 3. The setup sheet | PASS on the sentence, link, hover, click, sign-in step and headings; FAIL on D19 |

## What changed since candidate 45, re-derived

- **Source.** 45 was built from `c04e3f381`, 46 from `c6e6c42c4`: 126 commits that are not
  merges (`git log --oneline c04e3f381..c6e6c42c4 --no-merges | wc -l`).
- **Product change.** `git diff --stat c04e3f381 c6e6c42c4 -- richos/app/ui richos/app/src-tauri/src
  richos/app/crates` touches 149 files. The three things the brief names are all in it:
  - dictation in any app: `src-tauri/src/dictation/` (new), `dictation_app.rs`, `ui/dictation*.{js,html,css}`,
    with `DICTATION_READY` true (`153945058`);
  - the Talk-to-Rich button: `a1bacf0eb` (`ui/index.html`, `ui/style.css`);
  - the setup sheet: `47ee47308`, `0bc337a8b`, `f27fc76a0`, `0851b5273`, `d1e2ca003`, all ancestors of
    `c6e6c42c4` (`git merge-base --is-ancestor`).

## Identity, checked before any claim: PASS

- **The zip.** `shasum -a 256` of `RichOS-1.2.0-nightly.20261008.46-macos-aarch64.zip` gives
  `7ff68fd2190ff7aa3790724a59f3d19839856541a11fd0d7c0697fcb1d353b41`. Both of its lines in
  `SHA256SUMS` carry that hash: the versioned name and `RichOS-macos-aarch64.zip`.
- **The engine.** `richos-engine-1.2.0.tar.gz` gives
  `90885f4a595fa40cdf19888f0aad29e18f4b24b453c9a662cde1d020b575a136`, its `SHA256SUMS` line.
- **`candidate.json` `info`:**
  - `source_commit` `c6e6c42c443839d31a93796b0e287e3673e9add9`;
  - `run_id` `20261008T192703Z-cd5a55d6`;
  - `version` `1.2.0-nightly.20261008.46`;
  - `build_commit` `008c710eaea234b8725a0e7505709e4c63d6123a`.
- **The build commit.** Its parent is `c6e6c42c4`. `git diff --stat c6e6c42c4 008c710ea` touches
  only four files: `nightly-build.json`, `Cargo.toml`, `Cargo.lock` and `tauri.conf.json`.
- **The running app.** The identity step of each bar and sheet walk run (B, A, A2) read "built
  from `008c710eaea234b8725a0e7505709e4c63d6123a`" and passed. The step-list runs (T, S) have no
  identity step; each ran the same zip, and T2 and T3 read the version line below.
- **The Settings version line.** It reads "RichOS 1.2.0-nightly.20261008.46 is up to date."
  (runs T2 and T3, accessibility find, `value='RichOS 1.2.0-nightly.20261008.46 is up to date.'`;
  frame `t3-settings-light`).

## 1. Dictation in any app

### The bar walk, every step: PASS, 18 of 18

`dictation-bar-walk.py` with no `--steps`, so all 18 of its steps, run B (`walk-8ff4c3793d8b`),
exit 0. The walk that passed on the development bundle (`walk-b178463d14ad`) ran 14 of them; this
run adds `check-window`, `check-panel`, `frames` and `fullscreen`.

**The samples.** Nothing was played. The spoken sample was written with `say -o` ("The quarterly
numbers look better than we expected this morning.") and `afconvert` to 16 kHz mono, 3.042 s, the
same length as the development walk's. The long sample is that, then 20 s of quiet pink noise
(`ffmpeg anoisesrc`, amplitude 0.002); the silent one is 5 s of digital silence. The models are
`~/Models/Whisper/ggml-small.en.bin` (`c6138d6d58ec…`) and `ggml-large-v3-turbo-q5_0.bin`
(`394221709cd5…`). `post_key` and `key_probe` were built from this branch's `src-tauri/examples`.

| Step | What it showed |
|---|---|
| identity | "built from `008c710eaea2…`" |
| stage | Microphone and Accessibility rows only, no Input Monitoring row |
| check-window, check-panel | The window check, both types (evidence, not a gate). The panel type keeps TextEdit in front through the Fix it click and the menu; the window type does not. The build uses the panel type: its log says "the bar, the flight and the menu windows are built as the panel type", "activation prevented at the window server" |
| relaunch | the tool starts as the app's child (`--parent 2660`), takes F1 and connects |
| settle | voice ready; both models decode the sample to the exact sentence |
| frames | listening, writing and added read off three frames; the words flew to TextEdit's cursor; 67 front-app samples, all TextEdit |
| fullscreen | the bar over a full-screen TextEdit; the words landed; TextEdit stayed full screen |
| menu | the menu from the menu bar item; Faster chosen by keyboard; Escape; TextEdit in front again; the next dictation used small.en |
| nofield | Finder in front: "No text box was selected, so I copied your words. Press ⌘V to paste them." and the log says copied |
| nosound | the silent sample: "I can't hear anything. Check that your microphone is on." and nothing written |
| chromium | one dictation into Chrome's text box: the exact sentence; the clipboard put back; no modifier left held |
| accuracy-mid | Faster chosen while listening: that dictation kept More accurate, the next used Faster; every menu opened at the first press |
| window-closed | closing the window quits RichOS with dictation off (0.11 s) and on (app 0.11 s, tool 0.24 s) |
| quit-listening | quit while listening: app gone 0.16 s, tool 0.44 s, no decoder left, scratch empty |
| quit-writing | quit while writing: app 0.27 s, tool 0.37 s, scratch empty, "stopping its decoder and removing its recording" |
| menu-fresh | a fresh launch: the item pressed once, 4.24 s after its menu page was ready, and the menu opened |

**As a person sees it** (frames `b-listening`, `b-writing`, `b-added`, `b-menu`, `b-no-text-box`,
`b-no-sound`): the bar is round 19's bottom-center pill, gold microphone, level bars, time and
"Tap F1 to finish". "Writing it down…" has its spinner, "Added" its check. The menu bar menu is
round 19's state 17: Dictation On, "Tap F1 to start, and again to stop.", More accurate checked,
Faster, Dictation settings…, Turn dictation off, Open RichOS. While dictation is on the composer
says "Dictation is on: tap F1 and talk, here or in any app".

**Contrast, light** (`qa/contrast.py`, its one estimator):

| Line | Ratio |
|---|---|
| "Listening", "Added" (bar) | 17.61:1 |
| "Writing it down…" | 17.31:1 |
| the bar's time "0:01" | 6.26:1 |
| "No text box was selected…" | 15.45:1 (`--min-frac 0.002`, see Method) |
| "I can't hear anything…" | 12.48:1 (same) |
| menu bar menu: "Dictation", "Faster", "Open RichOS", the key line | 18.07:1 |
| menu bar menu: "On" (gold) | 6.65:1 |

The bar in dark is in "The Settings row, the sheet and the bar in both themes" below (run T3).

### The sheet walk, through granted-settings and try-it: PASS, 8 of 8 (second run)

`dictation-sheet-walk.py --steps identity,stage,relaunch,switch-on,mic-prompt,ax-prompt,granted-settings,try-it`.

- **First run, A (`walk-e4955735c377`): switch-on failed, a harness timeout.** The press on the
  Settings button (`ax.sh click --id set-btn`) hit `ax.sh`'s 20 s deadline ("AX deadline reached;
  owned command group terminated", 18.2 s in transport). Two guests were running, the host read
  97.7% busy, and inside a guest the app's voice calibration runs three `whisper-cli` decodes at
  once (guest load average 34.7, measured in run A2's guest). The frame at the failure
  (`a-switch-on-failed`) shows the home screen drawn and nothing broken.
- **Second run, A2 (`walk-2882d6930ecc`), the same steps alone: every step PASS, exit 0.**

| Step | What it showed |
|---|---|
| identity | "built from `008c710eaea2…`" |
| stage | no grants at all (no TCC row for com.richos.app), no `dictation.json` |
| switch-on | the sheet said "Off. Turn it on to type with your voice in Mail, Slack, your browser, anywhere." first; the switch pressed |
| mic-prompt | macOS's microphone prompt carries Iris's sentence ("So you can talk instead of typing. I listen only after you tap F1 or press the talk button."), read by OCR; Allow pressed in the prompt |
| ax-prompt | macOS's Accessibility prompt; the app logged "the microphone was allowed" |
| granted-settings | the way a person does it: the sheet's Open System Settings, the Accessibility pane, RichOS's switch (the only one off), the password, Modify Settings. The tool's key tap came 0.09 s after the switch; the sheet said On; the app's pid unchanged |
| try-it | one dictation into Try it here: "The quarterly numbers look better than we expected this morning.", the clipboard put back |

**The sheet as a person sees it** (frames `a2-sheet-off`, `a2-mic-prompt`, `a2-sheet-on`), against
round 19's `sheet-off`, `ask-mic` and `sheet-on` and more-lines' line 2:
- the layout, the order and the words are round 19's: the switch card, Your key with the F1 strip,
  What macOS asks you for, Accuracy, and on the right Try it here, While you talk with the three
  bar states, Not the same as talking to me, and the privacy line;
- under the switch, on and off: **"Works only while RichOS is open.** When you quit RichOS,
  dictation stops until you open it again." with the info mark. That is more-lines' line 2 with
  "close" made "quit" (`31f787bae`), as the brief asks;
- nothing on the sheet says "On even when RichOS is closed" and nothing mentions Login Items: the
  accessibility tree in run T3 below, and `qa/ocr-find.sh` over the ten sheet and Settings
  frames (`a2-*`, `t3-sheet-*`, `t3-settings-*`): "Login Items" 0 of 10, "even when RichOS" 0 of
  10, while the same read found "Works only while" in all 7 sheet frames, so the reader was
  reading them;
- the permission rows go from "Asked when you turn it on" to "macOS is asking you" (with its
  spinner) to "Allowed";
- On: "On. Tap F1 in any app, talk, and tap it again." on the gold card, and the cursor waits in
  Try it here, as in round 19 state 10.

**Contrast, light** (`qa/contrast.py`):

| Line | Ratio |
|---|---|
| "Off. Turn it on to type with your voice…" | 6.33:1 |
| "On. Tap F1 in any app, talk, and tap it again." | 18.07:1 |
| "Works only while RichOS is open." (bold) | 16.72:1 |
| "When you quit RichOS, dictation stops…" | 6.14:1 (off), 6.20:1 (on) |
| "Tap once to start, once more to stop…" | 6.17:1 |
| "Asked when you turn it on", the permission reasons, the Accuracy reasons | 6.33:1 |
| "Allowed" (gold) | 6.65:1 |
| "Press a different key" (gold) | 6.26:1 |
| the sheet's subtitle | 6.15:1 |
| Try it here placeholder | 5.98:1 (round 19's own figure is 5.98:1) |
| "This box is only for trying…", While you talk's text | 6.15:1, 6.17:1 |
| "SETTINGS" breadcrumb (round 19 declares it 14px, skippable) | 6.74:1 |

### The Settings row, the sheet and the bar in both themes (run T3)

`steps-walk.py` with `steps/walkT.json` (run T3, every step that may not fail passed, exit 0). The
guest's own appearance was switched between light and dark; the app follows it.

- **The Settings row** (round 19 state 5): "Dictation" over "Off" (frames `t3-settings-light`,
  `t3-settings-dark`), and after dictation was turned on, "Dictation" over "On. Tap F1 to talk"
  (`AXMenuItem title='Dictation On. Tap F1 to talk'`, frame `t3-settings-on-dark`).
- **The sheet, off and on, light and dark** (frames `t3-sheet-off-light`, `t3-sheet-off-dark`,
  `t3-sheet-on-light`, `t3-sheet-on-dark`): the accessibility tree reads "Works only while RichOS
  is open." and " When you quit RichOS, dictation stops until you open it again." on both; a find
  for "even when RichOS is closed" and one for "Login Items" each returned "nothing matched", off
  and on. The tree's whole text, off, is round 19's words and line 2; nothing else.
- **The composer** says "Dictation is on: tap F1 and talk, here or in any app" while it is on.
- **The bar in dark** (frame `t3-bar-dark`): "Listening 0:02 Tap F1 to finish" over TextEdit, and
  the menu bar item gold while it listens. After the run's first tap the guest's real (silent)
  microphone gave the tool nothing, and it ended that dictation by itself before the second tap,
  as the bar walk's `nosound` step shows in light; the no-sound line itself was not photographed
  in dark.

**Contrast, dark:**

| Line | Ratio |
|---|---|
| Settings row "Dictation" / "Off" / "On. Tap F1 to talk" | 12.06:1 / 5.78:1 / 5.78:1 |
| (light: "Dictation" / "Off") | 18.07:1 / 6.33:1 |
| "Off. Turn it on…" / "On. Tap F1 in any app…" | 5.78:1 / 12.06:1 |
| "Works only while RichOS is open." (bold) / the rest | 12.84:1 / 6.07:1 (off), 5.88:1 (on) |
| "Tap once to start…", the subtitle, While you talk's text | 6.09:1 |
| "Asked when you turn it on", the reasons | 5.78:1 |
| "Allowed" (gold) / "Press a different key" (gold) | 6.36:1 / 6.87:1 |
| Try it here placeholder | 6.51:1 (round 19: 6.51:1) |
| "SETTINGS" breadcrumb (declared 14px) | 5.29:1 (round 19: 5.29:1) |
| the composer's "Dictation is on…" | 14.55:1 |
| the bar: "Listening", "Tap F1 to finish" / its time | 13.48:1 / 6.17:1 (round 19: 13.45:1 / 6.20:1) |

**D18: the sheet never says "Dictation is on. Try it in the box on the right, or in any app."**
Round 19's state 10 (`dictation.html?state=sheet-on`, rendered for this walk) shows that line
under the card right after turning dictation on; round 19 is the approved design by the record
(`dictation-bar-walk.py`'s header: "The CEO approved round 19 on 2026-10-08"). It did not appear either way it was turned on: through the prompts and System
Settings (run A2, frame `a2-sheet-on`) or with both grants already there (run T3, frame
`t3-sheet-on-light`, 8 s after the switch). The caret did land in Try it here, which the same code
path does. By the code (hypothesis, `ui/dictation.js` lines 321 to 326 and 86): `becameReady()`
sets the line only when `works()` is already true, and `works()` now also needs the tool to hold
the key (`toolWorking()`, added for "the sheet never says On without a working tool", `6dcd14dcb`),
which it does not yet at that moment; nothing sets the line once the tool reports in. Small: the
gold card already says On. It is a line round 19 draws that the build does not show.

## 2. The Talk-to-Rich button

**The button itself: PASS. Two lines that point at it: FAIL (D17).**

Run T3 (`walk-2563b6a1becc`), `steps-walk.py` with `steps/walkT.json`: the microphone grant written
as `voice-walk.py` writes it, the app's microphone a file of 30 s of silence
(`RICHOS_VOICE_INPUT_WAV`), nothing played. The button was pressed through the accessibility
tree (`ax.sh click --id talk-toggle`); its own state was read back each time.

| State | What it looks like (frames `t3-composer-light`, `t3-composer-dark`, `t3-talk-listening-*`) | Read back |
|---|---|---|
| At rest, light | his voice icon as the button: a dark ring, a light gap, a gold disc, five dark bars | `AXToggle title='Talk to Rich' value='0'` |
| At rest, dark | a light ring, a navy gap, a gold disc, five dark bars | |
| Listening, light | the disc turns dark and the bars gold (the colors swap inside his shape) | `AXToggle title='Stop talking' value='1'` |
| Listening, dark | a light ring, a dark disc, gold bars | `title='Stop talking' value='1'` |

It reads as a voice button at a glance in both themes and both states, 46 px square, beside the
message box, as a1bacf0eb describes.

**Contrast, non-text (3:1 floor), measured on the frames with `qa/frame.py px` and `qa/contrast.py`:**

| Edge | Light | Dark |
|---|---|---|
| ring on the page, at rest | 14.90:1 (`#0C1322` on `#EAE6DD`) | 14.55:1 (`#DFE4EE` on `#0C1322`) |
| disc on the page (light) / on its gap (dark), at rest | 3.15:1 (`#9C7C34` on `#EAE6DD`) | 6.36:1 (`#C2A35C` on `#182440`) |
| bars on the disc, at rest | 4.72:1 | 7.68:1 |
| listening: disc against its gap | 18.07:1 (`#0C1322` on `#FDFCF8`) | not separate: the gap is the disc's own navy, declared in `style.css` (1.21:1, an edge that identifies nothing) |
| listening: bars on the disc | 4.72:1 | 7.68:1 |
| listening: ring on the page | 14.90:1 | 14.55:1 |

Each of these that a1bacf0eb's CSS comment also lists agrees with it (14.90 and 14.55, 6.36,
4.72 and 7.68, 18.07). The light disc against the page, 3.15:1, is not in that comment; it clears
3:1.

**D17: two sentences still point at the old button with a symbol that is no longer on screen.**
- Rich's first greeting, once voice is ready: "You can type, or tap **◉** to talk to me."
  (`ui/main.js:1688`, `GREETING_VOICE_INVITE`; frames `t3-composer-light`, `t3-composer-dark`,
  `t3-greeting-and-button`).
- While voice is on, under the composer: "headphones recommended · tap **◉** to end voice"
  (`ui/index.html:786`; frames `t3-talk-listening-light`, `t3-talk-listening-dark`).
- ◉ is the old "unassuming little circle". The button a person looks for is now his gold voice
  icon. The greeting is the first sentence a new user reads, and it teaches a symbol the screen
  does not show. a1bacf0eb changed the button (`index.html`, `style.css`) and neither sentence.
- Why it blocks: the candidate's own change made the screen contradict itself, the class that
  made candidates 40 (D12) and 41 (D13) NOT READY. The fix is two strings (or the icon drawn
  inline), and one look at both frames.


## 3. The setup sheet

**His sentence, the link, the sign-in step and the heading: PASS. The sheet opens with the link
focused instead of Set it up: FAIL (D19).**

Runs S (`walk-8774e015bfa2`) and S2 (`walk-459fde371f30`), `steps-walk.py` with
`steps/walkS.json`. To make the guest a first-run Mac in front of the setup sheet, each run, in
the guest only: moved the engine aside so the app sees none (a link left where setup installs
it); signed the guest's Claude Code out by removing its local credential file and keychain items
(`claude auth status` then read `"loggedIn": false`; nothing was revoked); in S2 also removed the
speech models so the press meets their download; then relaunched the app.

- **His account sentence, word for word.** The accessibility tree reads: "You need your own
  Anthropic account and a Max subscription there. You can sign in through your browser after
  setup; I never see your password. If you don't already have that subscription, " then the link
  "sign up there first and pick the Max/Max 20x tier", then ".". That is his sentence exactly
  (frames `s-ask-light`, `s-ask-dark`).
- **The link is underlined** (frames), and only those words are the link (`AXLink title='sign up
  there first and pick the Max/Max 20x tier'`).
- **Hovering shows "claude.com/pricing".** The link's `AXHelp`, where WebKit puts the `title` a
  hover shows, is `"help":"claude.com/pricing"` (S2, `ax.sh find --json`). The tooltip itself
  was not photographed: the guest's pointer was not moved over it.
- **Clicking it opens https://claude.com/pricing in the browser.** Pressed in both runs: Safari
  came to the front and its page was `https://claude.com/pricing` ("Plans & pricing | Claude by
  Anthropic"; frame `s-pricing-opened`). RichOS stayed as it was behind it.
- **The sign-in step has no Account type menu.** With the guest signed out, the finished sheet
  says "Connect your Anthropic account to start working with Rich." over Connect account and
  Start (frames `s-sign-in-step`, `s2-done-light`, `s2-done-dark`). A find for "Account type"
  returned "nothing matched" on the ask sheet in both runs and on the finished sheet in S2.
- **No "Setup is done." while the video tools are still downloading.** In this candidate the sheet
  is round 19's, and its headings are "There's a bit of setting up to do first.", "Setting things
  up" and "You're all set." S2 removed the models (small.en was then a 51 MB partial file) just
  before relaunching, and pressed Set it up while they downloaded again:
  - 21:10:53, 21:11:08 and 21:11:31: the heading reads "Setting things up", his download line is
    above the rows, the voice row counts ("413 MB of 1.06 GB", "545 MB", "911 MB"), and finds for
    "Setup is done" and for "all set" return nothing (frames `s2-run-1`, `s2-run-3`);
  - 21:11:31: the engine is in, so Start and the sign-in line are already there while the voice
    row still counts and the heading still says "Setting things up" (round 19's "state 2 with
    Start");
  - 21:11:52: both models complete on disk (574041195 and 487614201 bytes); 21:12:01: "You're all
    set." appears for the first time, over "Voice is ready. You can just talk to me now instead of
    typing.";
  - "Setup is done." was never on the sheet (five finds across the run, none matched).
- **The sheet in dark** (frames `s-ask-dark`, `s2-run-dark`): his line, the rows and the link all
  readable; see the ratios.

**D19: the ask sheet opens with keyboard focus on the pricing link, not on Set it up.**
- **What a person sees:** the moment the sheet appears, the link is boxed in a gold focus ring,
  drawn as two boxes because it wraps (frames `s-ask-light`, `s-ask-dark`, `s2-ask-light`; both
  runs).
- **What the app reports:** `ax.sh --focused` gives `role: AXLink`, the pricing link (S2, step 9,
  three seconds after the sheet appeared, before anything was pressed).
- **What follows for a person:** Return or Space on that sheet would open the pricing page in the
  browser rather than start the setup. Not tried here; that is what a focused link does in WebKit.
- **Why** (hypothesis from code): `ui/home.js` lines 970 to 1004 give focus to the sheet's FIRST
  visible focusable element, on the stated assumption that this is "Set it up" or "Close"
  ("those are exactly the first visible buttons in the two states"). The account sentence's new
  link (`47ee47308`) sits above the buttons, so it is now first. `openSetupSheet`'s own
  `setupGoEl.focus()` is swallowed while `#app` is inert, as that comment says.
- **Why it blocks:** the candidate's own change; the first screen a new customer sees greets them
  with a highlighted link, and the obvious key does the wrong thing.

**Contrast** (`qa/contrast.py`):

| Line | Light | Dark |
|---|---|---|
| "There's a bit of setting up to do first." (title) | 18.07:1 | 12.06:1 |
| the step lines ("The RichOS engine: the part of me…") | 18.07:1 | 12.06:1 |
| his account sentence | 6.33:1 | 5.78:1 |
| the link | 18.07:1 | 12.06:1 |
| "Set it up" (on gold) / "Not now" | 4.72:1 / 6.33:1 | 7.68:1 / 5.78:1 |
| "Setting things up", "You're all set." | 18.07:1 | 12.06:1 |
| his download line, "Voice is ready…" (Rich's lines in the sheet) | 15.74:1 | 9.74:1 |
| "Rich" over his line | 5.79:1 | 5.14:1 |
| the counter ("545 MB of 1.06 GB") / "Installing…" | 6.33:1 / 6.33:1 | 5.78:1 / 5.78:1 |
| "Installed" (gold) | 6.65:1 | 6.36:1 |
| "Connect your Anthropic account to start working with Rich." | 6.33:1 | 5.78:1 |
| "Connect account", "Start" (on gold) | 4.72:1 | 7.68:1 |

## Seen, outside the brief's three items (not judged)

- **On a first run in the guest, the app times the large speech model twice at once.** When the
  large model arrives, two identical `whisper-cli … ggml-large-v3-turbo-q5_0.bin … richos-voice-calibration/probe.wav`
  decodes start in the same second, from the app's own pid, beside the small.en one: seen in two
  guests (`walk-2882d6930ecc` pids 1497 and 1498; `walk-467b4b5e3e69` pids 1766 and 1769, then
  1832 and 1837 as the next repetition). On the guest's CPU each takes about 20 s, and the three
  together put the guest's load average at 34.7. By the code it reads as two callers of
  `stt.rs` `choose_model` reaching the same unmeasured model before either records its speed
  (hypothesis from code, `crates/richos-voice/src/stt.rs` lines 419 to 445; three reps each,
  `CALIBRATION_REJECT_REPS`). A real Mac with Metal decodes far faster, so a person there would
  not notice it, and the measured speed is kept after the first time. The same load is the likely
  reason the first sheet run's Settings press timed out; run A's guest was not measured, A2's was,
  at the same point of the same walk.
- **More accurate is slow in the guest.** On the guest's CPU, More accurate wrote 3.3 to 7.6 s of
  speech in 8.6 to 11.3 s (bar walk `frames`, `fullscreen`, `accuracy-mid`; sheet walk `try-it`),
  where the sheet promises "a second or two after you stop". The guest has no GPU, so this says
  nothing about a real Mac; it is recorded so nobody reads the guest's figures as the product's.
- **The Dictation sheet moves when its state line changes length.** The sheet is centered, so its
  top edge is at y 121 with "Off. Turn it on…" (two lines), y 127 while macOS asks, and y 123 when
  On (`qa/frame.py edges`, frames `a2-sheet-off`, `a2-mic-prompt`, `a2-sheet-on`): a 4 to 6 px jump
  of the whole sheet as you turn it on. In the Off state at this window size (1400x864) the sheet
  also shows a scroll bar on the right, as its content is a few pixels taller than the sheet. A
  Mac set to show scroll bars only while scrolling would hide it (the guest's setting was not
  read). Round 19's mockup was measured at 1440x900 with no scroll.
- **The finished setup sheet keeps the height of the running one** (S2, frames `s2-done-light`,
  `s2-done-dark`): after "You're all set." there is an empty band of about 80 px between "Connect
  your Anthropic account…" and the buttons, because the sheet holds its tallest height so the
  buttons do not move (`lockSetupHeight`). In S, where the press came after the download, there is
  no gap (`s-sign-in-step`).
- **While Start is on the sheet, the dialog has no accessible name.** `ax.sh` names the open dialog
  by its label: "There's a bit of setting up to do first.", then "Setting things up", then an empty
  name from the moment Start appears ("blocked: target=richos-tauri modal=;", S2 steps 38 to 50),
  while the heading on screen still reads "Setting things up" and then "You're all set.". VoiceOver
  was not run; a screen reader may announce an unnamed dialog there.
- **The voice row's own words.** While talking to Rich with no sound reaching the microphone, the
  row says "I can't hear anything. Check your mic isn't muted, then try again." beside a "try
  again" button whose label wraps onto two lines (frames `t3-talk-listening-*`). Each press of the
  talk button on this guest also adds the note "I'm using my faster hearing on this machine…"
  again, so two presses left it twice in the conversation. Whether either is new in this
  candidate was not checked.

## Verification mode

- **Environment.** The test VM, one fresh guest per run through `run-walk.py`, never this Mac's
  screen. At most two guests at once, one per slot. One app window per guest, no two-user test.
  Guest screen 1680x1050 at 1x; the app window 1400x864. Light and dark were switched through the
  guest's own macOS appearance; the app follows it.
- **Artifact.** The candidate's own signed zip, with the same folder's `richos-engine-1.2.0.tar.gz`
  as `--engine`. The bar and sheet walks ran with `--expect-sha 008c710ea`, the build commit.
- **Account.** The real Claude login that `run.sh` copies into each guest. Runs S and S2 removed
  that copy inside their own guest only (credential file and the guest keychain's two items); no
  token was revoked and no account file on this Mac was written.
- **Audio.** No sound was played anywhere. Every spoken sample is a file written with `say -o` and
  fed through `RICHOS_VOICE_INPUT_WAV`; the talk-button runs fed 30 s of silence.
- **Reference.** Round 19's `dictation.html` and `dictation-more-lines.html`, rendered headless in
  WebKit (`playwright-cli`, 1440x900, over a loopback server on this Mac, no window), states
  `sheet-on`, `menu` and `folder-sheet`; the renders stayed in scratch.

### Runs

Every run ended "clean: app quit, VM stopped, clone deleted, state removed." and released its slot.

| Run | VM | Walk | Result | Seconds |
|---|---|---|---|---|
| B | `walk-8ff4c3793d8b` | `dictation-bar-walk.py`, every step | **18 of 18 PASS, exit 0** | 641 |
| A | `walk-e4955735c377` | `dictation-sheet-walk.py`, through try-it | harness: `switch-on`'s Settings press hit `ax.sh`'s 20 s deadline on a loaded host | 216 |
| A2 | `walk-2882d6930ecc` | the same, alone | **8 of 8 PASS, exit 0** | 548 |
| T1 | `walk-c1bef37fb8a7` | `steps-walk.py`, `walkT.json` as first written | harness: the Settings press hit the 20 s deadline while the guest's decoders ran | 165 |
| T2 | `walk-467b4b5e3e69` | the list with a wait for the models and the decoders, `TESTVM_AX_TIMEOUT=60` | harness: a find by DOM id on a paragraph that exposes none | 336 |
| T3 | `walk-2563b6a1becc` | `walkT.json` as committed | **every step that may not fail passed, exit 0** | 475 |
| S | `walk-8774e015bfa2` | `steps-walk.py`, `walkS.json` as first written | harness: its last wait looked for the heading on a group node that carries no text; every step before it passed | 803 |
| S2 | `walk-459fde371f30` | `walkS.json` as committed | **every step that may not fail passed, exit 0** | 183 |

**A, T1, T2 and S, read from their own evidence.** None of the four failures is the app's. A and
T1 are `ax.sh` deadlines ("AX deadline reached; owned command group terminated", 18.2 s and
15.9 s spent) on the Settings press, at the point of the walk where A2's and T2's guests, which
were measured, were running two or three `whisper-cli` decodes on their four cores; A2 and T3 made the
same presses with the decoders done and passed. T2's step looked for `--id dict-copy-note`, which a
`<p>` does not expose; T3 finds the same words by value. S's last wait matched the heading's group
by id, which carries no text; S2 matches "all set" by value. The committed lists are T3's and S2's.

## Method and toolkit

The walks and tools are `richos/app/scripts/` on this branch, on top of the candidate's source
`c6e6c42c4`. The `qa/` tools are the same as at `4e142bc0e`.

**`testvm/`:**
- `run-walk.py --wait 900`, `slots.py status`;
- `dictation-bar-walk.py` (no `--steps`) and `dictation-sheet-walk.py --steps
  identity,stage,relaunch,switch-on,mic-prompt,ax-prompt,granted-settings,try-it`;
- `steps-walk.py --steps …/steps/walkT.json` and `…/steps/walkS.json`, and `--check` on both;
- `guest.sh` (read-only process listings in two guests while they ran).

**`qa/`:**
- `contrast.py` on frame regions and on color pairs read with `frame.py px`. On the two problem
  lines of the bar (`b-no-text-box`, `b-no-sound`) the default 0.5% coverage floor picked a
  near-white shade as the text, because the pill's light gradient spreads the ground over many
  shades; `--min-frac 0.002` read the ink, and both figures are printed above;
- `frame.py` (`px`, `crop`, `edges`);
- `ocr-gate.sh` with its positive control, `redact.py --phones`;
- `wait-for.sh --log`.

**Elsewhere:**
- `nightly-local.py candidate --run 20261008T192703Z-cd5a55d6`;
- `shasum`, `jq`, `git diff --stat`, `git merge-base --is-ancestor`;
- `say -o`, `afconvert` and `ffmpeg` for the samples;
- `cargo build --example post_key --example key_probe` (behind `reserve.py`), for the bar walk's
  `--post-key` and `--key-probe`;
- `playwright-cli` for the round 19 renders;
- `sips` (JPEG copies).

**Scripts written from scratch: none.** Two data files were added: `steps/walkT.json` and
`steps/walkS.json`, declared in `steps-walk-data.test.sh`'s inputs and covers rows; that suite
passes (3 ok lines).

### Frames

- **Format.** JPEG q80 copies of the 1680x1050 PNG originals (one crop, `t3-greeting-and-button`).
- **Names.** The run letter, then what the frame shows.
- **The privacy gate.** `ocr-gate.sh` ran over the 33 PNG frames these JPEGs were made from, with
  its positive control: first "1 of 33 frame(s) carry something that must not ship", a
  phone-shaped run of digits the reader made of the Dock in `t3-bar-dark`; `redact.py --phones`
  covered the Dock band (130,935 to 1165,1053) and re-read it, and the gate then read that frame
  clean: 0 of 33 in all.
- **The run evidence** (`runs/*.txt`, JSON as each tool wrote it: `run-walk.py`'s reports, the
  bar and sheet walks' `report.json`, the step lists' `steps.json`) carries this Mac's home folder
  as `~`.

## Surfaces

**Applied and checked:**
- the Mac desktop app from its signed bundle: first run (the setup sheet, signed out, engine
  missing), a returning launch (relaunches), and quitting it while dictating;
- dictation's ways in and out: the Settings row, the Dictation sheet and its switch, macOS's two
  prompts, System Settings' Accessibility switch, the F1 key, the menu bar item and its menu
  (Faster, More accurate, Escape), closing the window and quitting while listening or writing;
- the apps it types into: TextEdit (windowed and full screen), Chrome, the desktop (copied), and
  Try it here;
- the Talk-to-Rich button: at rest and listening, by its accessibility press, light and dark;
- the setup sheet: asking, running, finished, the link and the sign-in line, light and dark.

**Not applicable:**
- phones: nothing touched; battery: no `richos/mobile/**` change;
- the stable channel: nothing was published.

**Not covered:** a real F1 key on a physical keyboard (the walks post key code 122 and the top
row's event, as every dictation walk does), VoiceOver, and the no-sound line in dark.

**Test data.** Each guest was a fresh clone with its own empty home. Nothing touched this Mac's app
data.

## Cleanup

- **The runs.** All eight ended clean, each releasing its slot (table above).
- **After the last run:** `slots.py status` read "guest.lock: free" and "guest-2.lock: free";
  `~/.richos-testvm/tart/vms/` holds only `richos-base`; `~/.richos-testvm/run/` is empty.
- **This Mac.** No app was started on it. The loopback server for the round 19 renders was this
  walk's own process (pid 88160, captured at start) and was stopped by that pid; the headless
  WebKit session was closed with `playwright-cli close`.
- **Scratch.** `/Volumes/E1TB/tmp/claude/ray-opus-walk46/` is deleted after this record is
  committed.

## Defects, in one list

- **D17 (new, blocks).** Two sentences point at the talk button with "◉", the old circle: Rich's
  greeting "You can type, or tap ◉ to talk to me." (`ui/main.js:1688`) and the voice row's "tap ◉
  to end voice" (`ui/index.html:786`). The button is now his voice icon (`a1bacf0eb`).
- **D18 (new, does not block on its own).** The Dictation sheet never shows round 19's "Dictation
  is on. Try it in the box on the right, or in any app." after turning dictation on.
- **D19 (new, blocks).** The setup sheet opens with keyboard focus on the pricing link (gold focus
  boxes; Return would open the browser) instead of on Set it up: `ui/home.js`'s first-focusable
  rule now lands on the link that `47ee47308` put above the buttons.

Verdict: NOT READY
