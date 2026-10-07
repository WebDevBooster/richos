# Walk of nightly candidate 41 (`v1.2.0-nightly.20261007.41`), 2026-10-07

**Verdict: NOT READY.** One new defect blocks it, D13. On the new Claude accounts sheet, the two
choices under "When a 5-hour limit is almost used up" both stay empty on a fresh install. One of
them says "The default." The CEO's chosen design (round 18) shows that one chosen. Everything else
the candidate changed works on screen:

- items 2 to 9 and `_02` and `_03`, each seen on the candidate itself;
- D12 from walk 40 is fixed;
- the "Using Work, switched" row fits at 1024x700.

Item 1 has no verdict on the candidate, and cannot have one yet:
- **Why the candidate cannot be offered an update.** The newest published release is nightly 39,
  and candidate 41 sorts above it.
- **What a build of the same source shows.** I walked a development build of the same source
  (`233aec562`) against the published nightly 39. It downloads the update and restarts into it by
  itself while nothing is running. It comes back with the same window, the same conversation and
  the unsent sentence.

His words, the measure of this walk: "implement the changes from my feedback there and do a new
nightly build after that." The feedback is `richos-hq/docs/ceo-input/2026-10-06_01/`, `_02/` and
`_03/`.

## Results, item by item

| His item | Verdict on the candidate | Where |
|---|---|---|
| 1 Restart into a downloaded update when nothing runs | **No verdict on the candidate.** On the dev build of the same source: relaunched by itself 14.6 s after the press, activated, came back where it was. | "Item 1" below |
| 2a "Connected folders (repositories)" in the settings menu | PASS, two lines, both themes | D |
| 2b Company pre-selected | PASS (Acme, the only company) | D |
| 2c Folder selection by a click | PASS (a click in the field opens the folder chooser; the folder chosen fills it) | D |
| 2d His popup copy, all nine rows | PASS, word for word | D |
| 3 No m-dash or n-dash in UI text | PASS on every screen the walk read | A |
| 4 "RichConnect for RichOS" and his pairing sentence | PASS | A |
| 5 No private pilot anywhere | PASS | A |
| 6 Stored output kept Forever by default | PASS | A |
| 7 Splash switch only in the general settings | PASS | A |
| 8 Choose which account drains first | PASS, his own test: Home chosen at 97%, Rich switched to Work by himself at 99% | C |
| 9 Claude accounts for everyone | Works end to end; **D13** on its sheet | C |
| `_02` The quick settings quota row is the weekly figure | PASS ("Work 12% weekly"; Work's five-hour is 0%) | C |
| `_03` "Its folder on this Mac" opens a folder chooser on a click anywhere; placeholder | PASS (left end, middle, right end) | D |
| D12 (walk 40): "MW" inside the gold circle | FIXED, both themes | D |
| "Using Work, switched" row at 1024x700 | PASS, three lines, all inside the menu, both themes | C |

In the "Where" column, A is run A2, C is run C3 and D is run D2, the three passing runs on the
candidate (see Runs).

## Identity, checked before any claim: PASS

- `shasum -a 256` of `RichOS-1.2.0-nightly.20261007.41-macos-aarch64.zip` gives
  `a597ff5f0b45a5a5f340538805f5f4db17b4214d7335ce118d6abb7ad7aa7003`. Both of its lines in
  `SHA256SUMS` carry that hash: the versioned name and `RichOS-macos-aarch64.zip`.
- `candidate.json` `info` reads:
  - `source_commit` `233aec5621ebf6ae0a65f156e6438f580a16230d`;
  - `run_id` `20261006T231216Z-36b5c4db`;
  - `version` `1.2.0-nightly.20261007.41`;
  - `build_commit` `8f7e95c720fa9f9a3f5f02ff9a2c7bc6b62554a2`.
- The build commit's parent is `233aec562`. `git diff --stat 233aec562 8f7e95c72` touches only four
  files: `nightly-build.json`, `Cargo.toml`, `Cargo.lock` and `tauri.conf.json`.
- Run D2's `identity` step read `built_from: 8f7e95c720fa9f9a3f5f02ff9a2c7bc6b62554a2` from the
  running app.
- The Settings menu reads "RichOS 1.2.0-nightly.20261007.41 is up to date." in light and in dark.
  The frames are `a-1-quick-settings`, `d-2-menu-light` and `d-2-menu-dark`.

## Verification mode

- **Environment.** The test VM, one fresh guest per run through `run-walk.py`, never this Mac's
  screen.
  - The guests ran one at a time, except that A2 and D overlapped once (see Runs).
  - Each guest had one app window. There was no two-user test.
  - The guest screen is 1680x1050 at 1x. The app window is 1400x864 at (140,77); step 11 of run C3
    resized it to 1024x700.
  - Light and dark were switched in two ways: through the guest's macOS appearance (runs D and D2),
    and through the app's own Theme control (runs C2 and C3).
- **Artifact.** The candidate's own signed zip, with the same folder's `richos-engine-1.2.0.tar.gz`
  as `--engine`.
  - Runs A, A2, C, C2, C3, D and D2 ran the candidate.
  - Runs B to B7 ran a development build. It is not the candidate (see "Item 1").
- **Accounts.**
  - Runs A, A2, C, C2 and C3 used the committed fake `claude` (`fake-claude-fill-first.pl`), so no
    real Claude account was read or switched.
  - Runs B to B7, D and D2 used the host's Claude Code 2.1.290, synced into each guest.

### Runs

Every run that started reported `execution: completed` and `cleanup_complete: true`.

| Run | VM | Bundle | Walk | Result | Seconds |
|---|---|---|---|---|---|
| A | `walk-54299f44c8c8` | candidate | `fbcopy-walk.sh` | 3 PASS, 2 FAIL, 4 UNKNOWN, all from the harness | 198 |
| A2 | `walk-c51baeb96dce` | candidate | `fbcopy-walk.sh` at `e6916cfbc` | **7 of 7 PASS**, exit 0 | 211 |
| B | `walk-535f144c4328` | dev `233aec562` | `update-relaunch-walk.py` | ready FAIL (harness) | 372 |
| B2 | `walk-fe53d4385fc2` | dev | the same walk at `6d07f2274` | ready FAIL (harness); the frame shows the update offered | 368 |
| B3 | `walk-99fb46933c29` | dev | the same walk at `20466036f` | relaunched and activated; notice FAIL (harness) | 102 |
| B4 | `walk-c389e7d4353f` | dev | the same walk at `c086defdb` | download **PASS**; after FAIL (harness) | 403 |
| B5 | `walk-ec1c6a5c0a65` | dev | the same walk at `ea76105ed` | download PASS; after FAIL (harness, frame kept) | 256 |
| B6 | `walk-95e83a839f1b` | dev | the same walk at `5f6c71cf9` | download PASS; after FAIL (harness, frame kept) | 124 |
| B7 | `walk-e19b373ac4b4` | dev | the same walk at `b255ef156` | **all 7 steps PASS**, exit 0 | 121 |
| C | none | candidate | `accounts-walk.sh` | refused admission before booting (exit 75, guest memory) | 0 |
| C2 | `walk-434edf5caf3d` | candidate | `accounts-walk.sh` at `754ae33eb` | steps 0 to 9 PASS; one step 9 check and steps 10 and 11 FAIL (harness) | 1546 |
| C3 | `walk-f032014464f1` | candidate | `accounts-walk.sh` at `6d7c6738c` | **all steps PASS**, exit 0 | 1385 |
| D | `walk-bd5c53b21c6c` | candidate | `folders-walk.py` at `23d99f300` | every click, chooser, copy and Git check PASS; placeholder OCR FAIL (harness) | 383 |
| D2 | `walk-b374990a1f42` | candidate | `folders-walk.py` at `6bb25ab3d` | **4 of 4 steps PASS**, exit 0 | 326 |

**A note on how the runs were scheduled.** My first dispatch queued A2, C and D behind B, each
waiting for a guest slot. The slot manager admitted A2 and D together on memory, and refused C
(exit 75). After the coordinator's note, every later run was started alone and only after the
previous one had released its slot: D2, C2, C3, and B2 to B7.

### Every harness failure, read from its own evidence

- **A** (`fbcopy-walk.sh` as committed):
  - Two whole-window tree reads reached `ax.sh`'s 20 s guest deadline (`guest_deadline`) while the
    dev build compiled on the host.
  - "Use Rich from your phone" was pressed through a node with no AXPress (`noaction`,
    `actions=AXShowMenu`). The row is an AXMenuItem.
  - The rail gear was looked for as an AXButton titled "Settings", which does not exist. The gear
    is the AXPopUpButton titled with the gear glyph, so the press opened nothing, and items 6 and 7
    were judged on a screen without the popover. Its frame shows the top bar's "Settings" tooltip.
  - Fixed in `e6916cfbc`; `fbcopy-walk.test.py` passes 5 of 5.
- **B and B2:** the update cue is a `<button aria-haspopup>`, which the tree shows as an
  AXPopUpButton. The walk waited for an AXButton. B2's frame `1-not-offered` shows the cue on
  screen: "RichOS 1.2.0-nightly.20261006.39 is ...". Fixed in `6d07f2274` (evidence on failure)
  and `20466036f` (the role).
- **B3:** the walk looked for the notice with the case-sensitive OCR pattern `restarting`. The app
  writes "Restarting into" on the pill and "will restart into it in a moment" in the row. With
  `[Rr]estart(ing)? into` (`c086defdb`), B3's own frames 4, 5 and 6 hit.
- **B4 and B5:** the relaunched app's first-run engine sheet ("There's one thing I need on this
  Mac") is modal over the composer, so the composer could not be read. It comes back on every
  launch in this guest, the first launch too, where first-run already answers it with Not now.
  B5's frame shows the same window, the same conversation and the sentence in the composer under
  that sheet. Fixed in `ea76105ed` (evidence) and `5f6c71cf9` (Not now).
- **B6:** two checks failed on reads, not on the app:
  - the window comparison included `ax.sh`'s timing lines, which differ on every read;
  - the conversation was looked for only as a static text, while it is the rail's selected row.

  B6's own after frame showed the same window, "Acme / Running" and the sentence in the
  composer. Fixed in `b255ef156`, and B7 passed.
- **C2:**
  - Step 9's "You chose Home" is two text nodes ("You chose " and the bold "Home"). The frame
    shows the row; the record has the `chose` row.
  - Turning Technical view on opens "Turn on the technical view" (where: everywhere, this company,
    this conversation). The walk left it open, and every later menu read failed. The frame
    `10-menu-technical` of C2 shows the dialog.
  - Fixed in `6d7c6738c`.
- **D:** OCR of the whole frame reads the placeholder as "and select folder". It drops the light
  "Click", which the frame plainly shows. Read off the field's own crop, scaled three times with
  `qa/frame.py crop --scale 3`, it reads "Click and select folder". Fixed in `6bb25ab3d`.

## Items 3 to 7 (run A2, the candidate): PASS

`fbcopy-walk.sh` verdicts, all seven PASS:
- **Item 7:** the quick settings menu has no Splash screen row (`a-1-quick-settings`).
- **Item 7:** the general settings (the rail gear) hold "Splash screen / Show it when RichOS
  starts" (`a-2-general-settings`).
- **Item 6:** on this fresh install, "Keep the stored output" has **Forever** chosen and reads
  "Nothing is ever removed. Using 1.5 KB now."
- **Items 4 and 5:** "Use Rich from your phone" offers "RichConnect for RichOS" and "Set up
  RichConnect for RichOS". It reads "First, set up this RichOS app on your Mac. Then pair your
  phone with it." No "RichOS Connect" and no pilot wording appear anywhere (`a-3-phone`).
- **Item 3:** no U+2013 or U+2014 in any accessibility tree the walk read (conversation, quick
  settings, phone popup, general settings).

Contrast (`qa/contrast.py`, normal text 4.5:1), light, frame `a-2-general-settings`:
- the retention hint: 5.37:1;
- "Splash screen": 5.37:1;
- "Show it when RichOS starts": 6.33:1.

Dark was not photographed for this popover or the phone popup. These items change words and where
a control sits, not colors. The same muted pair measures 5.78:1 in dark on the Connected folders
sheet, below.

## Item 2 and `_03`, folder fields (run D2, the candidate): PASS

`folders-walk.py` is new in this walk (`23d99f300`, `6bb25ab3d`). The committed walks type a path
into these fields through the accessibility API. That fires no click, so they pass whether the
chooser opens or not. This walk clicks with the guest's mouse (`ax.sh click --at`).

**`_03`, "Which company is this copy of Rich for?"** (frames `d-1-*`):
- **The placeholder.** The empty field reads "Click and select folder", OCR on the field's own
  crop. The old "/Users/you/Projects/northwind" is not there. Contrast 5.37:1 in light.
- **A click at the field's left end (x 658):** the folder chooser opened as a sheet, "Choose the
  company's folder". Cancel closed it, and the field stayed empty.
- **A click in the middle (x 840):** the same.
- **A click at the right end (x 1021):** the chooser opened. Go to folder (Command-Shift-G), the
  path and Open filled the field with `<guest-home>/Acme`.
- **Adding the company.** "Add this company" registered Acme with that folder in `entities.json`,
  and the first conversation was created.

**Item 2, Settings and Connected folders** (frames `d-2-*`):
- **2a.** The menu row reads "Connected folders (repositories)" on two lines. Its box is 253x50
  at (1265,428). Contrast: 18.07:1 light, 12.06:1 dark.
- **2d.** Every row of his table is on the sheet, word for word, read from the tree:
  - "Connected project folders (repositories)";
  - the description;
  - the guidance in smaller text;
  - "Company";
  - "No project folders connected yet.";
  - "Project folder location";
  - "Click and select folder" (OCR on the field's crop);
  - "Connect folder";
  - "Close".
- **The guidance's size and contrast.** It is `0.875rem`, 14 px; its capitals are 11 px tall
  against 13 px for the 16 px description. That is the smaller text he asked for, at the 14 px
  floor. Contrast in light:
  - description 6.33:1;
  - guidance 6.33:1;
  - placeholder 5.37:1;
  - empty state 18.07:1.

  In dark: description 5.78:1, guidance 5.78:1, placeholder 5.51:1.
- **2b.** Company opened pre-selected as "Acme".
- **2c.**
  - A click in the middle of "Project folder location" opened the chooser, "Choose a project
    folder".
  - `<guest-home>/Acme-docs` was chosen; it is a plain folder with one file, `brief.md`.
  - Connect folder listed it on the sheet and in `entities.json`.
  - The sheet said "Folder connected. Git was set up to track its files." In dark, that line is
    5.78:1.
  - The folder is now a Git repository whose first commit, "Initialize repository", holds
    `brief.md`.

## Item 8, his own test (run C3, the candidate): PASS

His words: "I should be able to change/switch which account drains first. Because for testing now
I should be able to switch to the account that currently has 97% weekly to see if it will
auto-switch correctly after reaching 99% weekly."

`accounts-walk.sh` step 9 (added in `754ae33eb`):
1. **The setup.** Steps 0 to 8 had left Work in use. Home had used 99% of its week, and Rich had
   switched away from it at 3:23 AM.
2. **Home at 97%.** Home's usage was set to 97% weekly. After one more turn, Home's card offered
   "Use this one now" (`c-9-chose-home`).
3. **The choice.** Pressing it put Home in use. The record says `"inUse":"1"` with a `chose` change.
   The sheet (`c-9-home-in-use`, dark) reads:
   - "Home · In use now", with a 97% weekly bar and "Almost used up";
   - "Rich now uses **Home**. Home has already used 97% of its week, so Rich will switch again when
     it reaches 99%.", with Undo;
   - in Recent changes, "You chose **Home**."
4. **The automatic switch.** Home's usage was set to 99%. Within the next turn, the record says
   `"inUse":"2"` with a second `switched` change: from Home, `why: weekly`, `used: 99.0`. The menu
   reads "Using Work, switched 3:30 AM" (`c-9-switched-again`).

The record's change list, in order: `added` Work, `switched` to Work (Home 99%), `chose` Home,
`switched` to Work (Home 99%).

## Item 9 (run C3, the candidate): works end to end, with D13

`accounts-walk.sh` steps 0 to 8, all PASS:
- **The Settings row.** "Claude accounts" reads "86% of this week used" with Technical view off.
  In gold on dark, 6.36:1.
- **Rich's suggestion.** It appears in the conversation, with "Add a second account" and
  "Not now".
- **Adding, in two steps.** Signing in as the account already in use gets its own screen with
  "Try again", and the new folder is signed out.
- **Work is ready.**
- **Home at 99%.** Rich switches and says why in three places:
  - the conversation: "I switched the team to your…", with "See your accounts";
  - the sheet's banner: "Rich switched to Work at 3:23 AM. Why: Home had used 99% of its weekly
    limit…";
  - Recent changes.
- **The Settings line.** It reads "Using Work, switched".

D13 is below.

## `_02`, the weekly figure (run C3, step 10, the candidate): PASS

- **The row.** With Technical view on, the quick settings row reads "Claude Code quota / Work 12%
  weekly" (`c-10-menu-technical`, dark).
- **Why that proves the weekly figure.** Work's fixture is 12% weekly and 0% five-hour, so the
  row shows the weekly window, labeled. In his screenshot it said "Home 6% · next Work".
- **No "· next".** Home is used up, so no account is next, and none is named.
- **Contrast.** The line is 5.78:1 in dark. Light was not photographed for this row; the same
  muted ink on the light menu ground measures 5.37:1 elsewhere in this walk.

## The "Using Work, switched" row at 1024x700 (run C3, step 11, the candidate): PASS

- **The window.** It was resized to 1024x700 at (140,77): `ax.sh --windows` read "RichOS 1024x700
  at (140,77)".
- **The row's three lines.** "Claude accounts" / "Using Work, switched" / "3:30 AM", in light and
  dark (`c-11-menu-1024-*`).
  - The AXMenuItem's box is (853,392) 275x70.
  - Its ink (`qa/frame.py extent`) spans x 863..1045 and y 401..453, inside the box with the
    chevron to its right.
  - No line is clipped, and the time keeps its AM.
- **Contrast.**

  | Line | Light | Dark |
  |---|---|---|
  | Title | 18.07:1 | 12.06:1 |
  | Gold line | 6.65:1 (#715715 on #FDFCF8) | 6.36:1 (#C2A35C on #182440) |

- **An observation, not a defect.** At 700 px the menu scrolls: its foot, the update server line
  and "Bust a bug!", sits under the fold behind a scroll bar.

## D12 from walk 40: FIXED (run D2, the candidate)

- **The setup.** The name "Mona Wells" was set in the rail footer's popover, so the initials are
  "MW", two of the widest capitals. Frames: `d-3-rail-*`, and the 8x crops
  `d-initials-light-x8` and `d-initials-dark-x8`.
- **Edges, with `qa/frame.py edges`:**
  - At the letters' middle (y 906), the circle's gold spans x 162..195, which is 34 px (walk 40:
    26 px). The ink of "MW" spans x 166..190, leaving 4 px of gold to the left and 5 px to the
    right.
  - At the letters' top (y 901), the gold spans x 162..195 and the ink ends at x 191, with gold at
    x 192..194 beyond it.
  - No stroke touches the rail's ground in either theme.
- **Contrast, ink on gold:** 4.72:1 in light (#0C1322 on #9C7C34) and 7.68:1 in dark (#0C1322 on
  #C2A35C). Walk 40 measured 1.04:1 for the part outside the circle in dark; there is no such part
  now.

## Item 1 (runs B to B7, a development build): no verdict on the candidate

**Why the candidate cannot be walked for this.**
- `update-relaunch-walk.py` needs a bundle OLDER than a published release. The relaunch is decided
  by the running, old copy.
- The newest published release is nightly 39: its `latest.json` answers 200, and nightly 40's
  answers 404. Candidate 41 sorts above it, so the candidate is never offered an update.
- The candidate's own Settings say "is up to date." while checking the published nightly channel.
- So the decision this item changes can only run on the candidate after a later nightly is
  published.

**What I walked instead, as supporting evidence only.**
- **The build.** `richos/app/scripts/package-app.sh` was run on this worktree at `233aec562`, the
  candidate's source. It made `1.2.0-dev.233aec562`, ad-hoc signed; the zip's sha256 is
  `6f2bf65fd2482b2b8262fb0cc56f6614cd76d4ec12d77478a24f2a8a71a4b012`.
- **The release it updates to.** It was walked against the published
  `v1.2.0-nightly.20261006.39/latest.json`, so the download, the signature check and the staging
  are a real signed release's.
- **It is not the candidate.** It differs from it only in the version files above. Read it as
  "the source behaves this way", never as the candidate's verdict.

**What it showed.** B7 (`walk-e19b373ac4b4`) passed all seven steps, exit 0. B4, B5 and B6 had
already shown the same download and relaunch.
- **ready.** The cue "RichOS 1.2.0-nightly.20261006.39 is available." appeared after the app's own
  first turn (`b-dev-1-available`).
- **draft.** An unsent sentence, "Half a sentence I have not sent yet", was in the composer.
- **download.** The cue was pressed, then Download update, with nothing running.
  - The row said "RichOS 1.2.0-nightly.20261006.39 is ready. Nothing is running, so RichOS will
    restart into it in a moment." (`b-dev-2-restart-notice`; frames 3, 4 and 5 of 7).
  - The log: "update ready and nothing is running: relaunching into 1.2.0-nightly.20261006.39".
  - The old process, pid 1160, ended. A new one, pid 1928, started by itself from
    `~/Applications/RichOS.app` **15.6 s after the press**; it was 14.6 s in B4.
  - Its log reads "update activated: 1.2.0-dev.233aec562 -> 1.2.0-nightly.20261006.39", and the
    installed bundle is 1.2.0-nightly.20261006.39.
- **after** (frame `b-dev-3-after-relaunch`):
  - The same window: "RichOS 1400x864 at (140,77)" before and after.
  - The same conversation: "Running", open under Acme.
  - The composer still reads "Half a sentence I have not sent yet".
  - The relaunched app is nightly 39, so the m-dash in its greeting is 39's text, not 41's.

**What is not shown here:** the other half of item 1, "restart after the work while work runs",
was not walked. No walk was written for it.

## Defects

**D13 (new in this candidate, blocking): on a fresh install, the Claude accounts sheet's
"When a 5-hour limit is almost used up" shows neither choice selected, and one of them says it is
the default.**
- **Where:** Settings, then Claude accounts, then the right-hand column, both themes. It shows as
  soon as a second account is added; the sheet only shows this section then.
- **Steps:** a fresh install; add a second account (run C3, steps 2 to 5); open the sheet.
- **Expected:** the CEO's chosen design, round 18 (`design/mockups/rounds/round-18/
  multi-account.html`, `fiveChoice: "pause"`), shows "Pause the team until it is fresh again"
  chosen, as its own line says: "The default. Never longer than 5 hours."
- **Actual** (frames `c-7-switched-light`, the crop `c-d13-radios-x3`, and `c-9-home-in-use` in
  dark):
  - Both radios are empty circles.
  - A person who is not technical cannot tell what happens when a 5-hour limit is reached.
  - The line "The default." describes a choice that is not in effect.
- **Cause, from the code:**
  - `ui/accounts.js:306` sets `choice = on ? view.atThreshold : null`, where `on` is the quota
    policy's `enabled`.
  - `Policy::default()` in `crates/richos-core/src/quota.rs:168` is `enabled: false`.
  - So on a fresh install nothing is checked, although the record's `atThreshold` is `"pause"`.
  - Pressing a choice turns the policy on first (`setFive`).
- **Why it blocks:**
  - It is on the screen built for his item 9, for exactly the person item 9 is about.
  - It departs from the design he chose.
  - The screen states something about its own setting that is not true.

**Observations, not defects:**
- **The update cue is cut short.** At 1400 px wide it reads "RichOS
  1.2.0-nightly.20261006.39 is ..." (B2's `1-not-offered`). His own `updates.png` of 2026-10-06
  shows the same, so this predates the candidate. The menu row says the whole sentence.
- **The accessibility name runs two words together.** The "Claude accounts" row's name reads "…
  Using Work, switched3:30 AM", with no space before the time, where the line wraps. A screen
  reader reads the two words run together. The visible text is right.
- **The guest's first-run engine sheet comes back on every launch.** It says "There's one thing I
  need on this Mac" and appears even after Not now, including the relaunch into an update. It was
  seen on the dev build and on nightly 39, in a guest whose engine is given by
  `RICHOS_ENGINE_DIR`. Whether it comes back on his Mac, where the engine is installed, was not
  checked.

## Not walked, and why

- **Item 1 on the candidate:** see above. A later published nightly is the first chance.
- **Item 1 while work runs** ("restart after the work"): no walk exists for it.
- **Dark mode for the item 3 to 7 popovers and the first-run company sheet:** these items change
  words and placement, not colors. The same classes were measured in dark on the Connected
  folders sheet.
- **The §109 teammates, the consult duty, the shelf and Pierce** (in this range: `fa0b4b3d4`,
  `2a96e3563`, `5fbea1ac3`, `e9f23d480`): back-end behavior the brief did not list. Their
  engineers' end-to-end walks are in their merges.

## Method and toolkit

All of it is `richos/app/scripts/` on this branch, on top of the candidate's source `233aec562`.
- `testvm/`:
  - `run-walk.py --wait`, `slots.py status` and `reserve.py`;
  - the walks `fbcopy-walk.sh`, `accounts-walk.sh`, `update-relaunch-walk.py` and the new
    `folders-walk.py`;
  - through them, `ax.sh` (`find`, `click`, `click --at`, `--windows`), `shot.sh` and `guest.sh`.
- `qa/` (the toolkit at `264aae844` plus this branch):
  - `contrast.py`, regions;
  - `frame.py`: `edges --row` and `--col`, `extent`, `crop --scale`;
  - `ocr-find.sh`;
  - `ocr-gate.sh` with its positive control;
  - `redact.py --homes --pad 4` and `--box`;
  - `wait-for.sh --file`.

**Scripts written from scratch: none.** One new walk was committed, because no walk existed for
item 2 or `_03`. It is `folders-walk.py` (`23d99f300`, `6bb25ab3d`), built on `adopt-walk.py`'s
Walk class and the toolkit. Walk fixes, each its own commit:
- `e6916cfbc` `fbcopy-walk.sh`;
- `754ae33eb` and `6d7c6738c` `accounts-walk.sh`, steps 9 to 11 and their harness fixes;
- `6d07f2274`, `20466036f`, `c086defdb`, `ea76105ed`, `5f6c71cf9` and `b255ef156`
  `update-relaunch-walk.py`.

### Frames

- **Format.** The frames are JPEG q80 copies of the 1680x1050 PNG originals. Every number above
  was measured on the PNG.
  - The prefixes name the run: `a-` is A2, `d-` is D2, `c-` is C3 and `b-dev-` is the dev build.
  - The crops are 8x (`d-initials-*`) and 3x (`c-d13-radios-x3`).
- **The privacy gate.** `ocr-gate.sh` ran with its positive control. It flagged 4 frames for the
  guest's home path (`/Users/admin/testvm/…`):
  - `d-1-folder-chosen` and `d-2-folder-chosen` (the chosen path in the field);
  - `d-2-sheet-after-light` and `d-2-sheet-after-dark` (the listed folder).
- **The redactions.**
  - `redact.py --homes --pad 4` covered each and re-read it as clean.
  - `d-1-choose-goto` shows the same path cut short ("rs/admin/…") and the Go to folder crumbs, so
    the gate's shape cannot match it. It was covered with two `--box` rectangles.
- **The final pass:** over the 35 PNG frames this folder's 35 JPEGs were made from, it read "0 of 35
  frame(s) carry something that must not ship". `ocr-gate.sh` reads PNG only and refused the
  JPEG folder as an empty set, so the pass was made on the PNG sources the JPEGs were made from.
- **`b-dev-cue-cut-short`** is B2's `1-not-offered`.
- **`runs.jsonl`** holds each run's `run-walk.py` report and its step report or verdicts, one per
  line. The guest's home is written `<guest-home>`.

## Surfaces

- **Applied and checked:**
  - the Mac desktop app from its signed bundle, on the first-run path, in light and dark where
    stated;
  - every folder field this candidate changed: the first-run company sheet and Connected folders;
  - every place the accounts work shows: the conversation, the sheet, Settings with Technical view
    off and on, and the smallest window;
  - the record files behind them: `claude-accounts.json` and `entities.json`;
  - Git in the connected folder.
- **Test data:** each guest was a fresh clone with its own empty home. Nothing touched this Mac's
  app data, and no real account was switched.
- **Not applicable:**
  - phones: nothing touched;
  - battery: no `richos/mobile/**` change;
  - voice: no audio played;
  - the stable channel: nothing was published.

## Cleanup

- **The runs.** Every run ended with "clean: app quit, VM stopped, clone deleted, state removed"
  and released its slot. The last was B7: "clean: app quit, VM stopped, clone deleted, state
  removed", then "slot released: guest.lock after 121s".
- **After the last run.** `slots.py status` read "guest.lock: free" and "guest-2.lock: free".
  `~/.richos-testvm/tart/vms/` holds only `richos-base`, and `~/.richos-testvm/run/` is empty.
- **This Mac.** No app was started on it; the dev build ran only inside the guests.
  `pgrep -fl richos-tauri` and `pgrep -fl 'tart run'` on this Mac both listed nothing. The walks
  quit each guest's app by its recorded pid (`stop.sh`), and the update walk recorded the
  relaunched pid for that purpose.
- **Scratch.** `/Volumes/E1TB/tmp/claude/ray-opus-walk41/` was deleted after this record was
  committed.

## Defects, in one list

- **D12 from walk 40:** fixed. "MW" sits inside the 34 px circle with 3 to 5 px of gold around it,
  ink on gold 4.72:1 light and 7.68:1 dark.
- **D13 (new, blocking):** the Claude accounts sheet shows neither 5-hour choice selected on a
  fresh install, while one says it is the default; the chosen design selects it.

Verdict: NOT READY
