# Walk of nightly candidate 43 (`v1.2.0-nightly.20261007.43`), 2026-10-07

**Verdict: READY.** All four new things in candidate 43 pass on its own signed bundle, in the test
VM:

1. the weekly-switch handoff, in two-account mode and in single-account mode;
2. the setup essentials;
3. voice on a clean Mac;
4. the quota panel's reading age, in light and dark.

One defect turned up in the new handoff code, D15 below. It is copy in the conversation. What the
app does is right, and on the safe side. It does not block.

Only the brief's four items were walked. Everything else passed on candidate 42
(`docs/verification/2026-10-07-nightly-42-candidate-walk.md`) and was not walked again.

## Identity, checked before any claim: PASS

- **The zip.** `shasum -a 256` of `RichOS-1.2.0-nightly.20261007.43-macos-aarch64.zip` gives
  `02c19166cf2e788739fa4032e506de852492c687e9166fd66c4645e775070d17`. Both of its lines in
  `SHA256SUMS` carry that hash: the versioned name and `RichOS-macos-aarch64.zip`.
- **The engine.** `richos-engine-1.2.0.tar.gz` gives
  `39182b0a4eee348eaf7cb30c71bf0a10905dab8e63d7e531cddbbb0f580da965`, its `SHA256SUMS` line.
- **`candidate.json` `info`:**
  - `source_commit` `2198c68bb2cef2125ea198c5d51fdf16b7c74693`;
  - `run_id` `20261007T141713Z-8d53fa5b`;
  - `version` `1.2.0-nightly.20261007.43`;
  - `build_commit` `8286b3ff817f19222002f62415cfe729a9810b77`.
- **The build commit.** Its parent is `2198c68bb`. `git diff --stat 2198c68bb 8286b3ff8` touches
  only four files: `nightly-build.json`, `Cargo.toml`, `Cargo.lock` and `tauri.conf.json`.
- **The running app.** It names itself as built from `8286b3ff8`. Every walk's identity step read
  that, starting with setup run 2. The first setup run was given the source commit and refused
  itself: "identity: FAIL — the running app was built from 8286b3ff8…, not 2198c68bb…". That was
  the wrong argument, not a defect; every later run was given the build commit.
- **The Settings version line.** It reads "RichOS 1.2.0-nightly.20261007.43" (quota run 2's walk
  log, `read: RichOS 1.2.0-nightly.20261007.43`, frame `q-0-menu-version`). Setup run 2's frame
  also shows "RichOS 1.2.0-nightly.20261007.43 is up to date."

## 1. The weekly-switch handoff: PASS, both modes

The walk is `handoff-walk.sh`, with the committed fake `claude` (`fake-claude-fill-first.pl`).

**Setup, both modes:**
- The cut-off is `RICHOS_TEST_WEEKLY_CUTOFF=1:51`.
- Account 1's week starts at 50%.
- The front desk writes the job down. The back end starts one helper, which steps through the
  app's gate.
- Account 1's week is then written as 51.

| Check | Two accounts (run H2-4, `walk-0061d71c893e`) | One account (run H1-2, `walk-4312d1a46459`) |
|---|---|---|
| The order reaches the helper | `gate work-agent-1 exit 2 order` in `calls.log`, 49 s after 51 was written | the same, 52 s after |
| The switch | `claude-accounts.json`: `"inUse":"2"`, `lastSwitch` from 1 to 2, `why` weekly, `used` 51.0. The chat says "I switched the team to your **Work** account. Home had used 51% of its weekly limit … Nothing stopped. The team carried on right where it was." | no second account. After the order the continuation waited 30 s with no turn while Account 1 stayed at 51%. It went on after the fake's reset (week at 10%). |
| The helper ended | `SubagentStop` for `work-agent-1` in the back end's evidence journal | the same |
| The handoff is written and used once | `engine-state/handoffs/work-agent-1.json` has `at` and `continued_at` | the same |
| A successor continues from it | the next back-end turn ran under Account 2's folder. It opens "Helpers you started were stopped because the Claude account they ran on is being left…" and names `RichOS handoff:`, after the order | the same turn, under Account 1's own folder, after the reset |
| No work record says failed | `settled` at the order and after | `waiting-for-quota` at the order, `settled` after |
| "Handed over cleanly." **once** | an exhaustive find over the whole window: `matches 1, exhaustive true`, one `AXStaticText` | the same: `matches 1` |

- **Exit status.** Both runs exited 0, with every check `ok`.
- **The two-account frames:** `h2-2-two-accounts`, `h2-4-after-order` and `h2-5-after-handoff`.
- **The one-account frames:** `h1-4-after-order` and `h1-5-after-handoff`.

**Not exercised here: the helper's own commit.** The brief's pass says "the helper commits a
handoff". With the fake `claude` there is no model, so nothing writes a git commit. What this walk
shows instead:
- the gate refused the helper with the order (exit 2);
- the helper ended;
- the gate wrote its handoff marker;
- the successor's turn carried the continuation, which names `RichOS handoff:`.

A real helper writing the `RichOS handoff:` commit is `handoff-real-walk.py`'s job, on his real
accounts. That walk was not part of this brief and was not run.

**"Once" is new in this walk.** No walk counted it before. The fake answers every back-end turn with
the same `reply.txt`, "Handed over cleanly.", so the first helper turn and the successor's turn both
end with it. The conversation shows one card: it is already on screen at the order (`h2-4`), and it
is still one card after the successor (`h2-5`). The exhaustive count is in commit `f40d09932`.

## 2. Setup essentials: PASS

The walk is `setup-walk.py`, run S2 (`walk-c868e861bdc6`), exit 0, every step PASS. The guest
already has Claude Code and the engine, so this is an install that had finished setup before this
change.

- **identity:** built from `8286b3ff8`.
- **incomplete:**
  - the boot names one thing missing: `first-run setup: my video tools is NOT installed`;
  - it looked for yt-dlp and for both speech models and found neither;
  - no speech model was on the guest;
  - the sheet says "There's one thing I need on this Mac." with the one item, "my video tools"
    (frame `s-sheet-before`).
- **install:** "Set it up" was pressed, and setup finished in 101 s. Its own lines, in order:
  - yt-dlp nightly 2026.09.27.232945, installed;
  - `ggml-small.en.bin` "installed and verified against its pinned sha256 (487614201 bytes)";
  - `ggml-large-v3-turbo-q5_0.bin` "installed and verified against its pinned sha256 (574041195
    bytes)";
  - "setup 1/1 finished".

  The sheet then says "Setup is done." (frame `s-sheet-after`).
- **installed:**
  - `tools/yt-dlp` is the launcher RichOS writes. Its version file hashes to its own record,
    `36de87e6…`, and it answers `--version` with `2026.09.27.232945`.
  - Both models are on disk with their pinned sha256: small.en `c6138d6d…`, large-v3-turbo-q5_0
    `394221709…`.
- **relaunch:** the boot says `first-run setup: nothing missing.` No sheet comes up. The window
  opens on the home screen (frame `s-relaunch`).

One thing seen, not a defect. The yt-dlp install line comes before "setup 1/1 started" in the log,
and setup then says "already installed". yt-dlp was fetched as setup began. Even so, setup was not
complete until both models were verified, which is what the brief asks.

## 3. Voice on a clean Mac: PASS

The walk is `voice-walk.py`, run V5 (`walk-16961cddf059`), exit 0, every step PASS.

**The sample.** It was written with `say -o`, then `afconvert` to 16 kHz mono WAV. Nothing was
played. The model is a copy of `ggml-small.en.bin`; its sha256 matches the pin.

- **no-decoder:**
  - `command -v whisper-cli` is empty in a login shell and in `/bin/sh`;
  - there is no Homebrew or `/usr/local` copy.
- **runtime:**
  - the engine's `runtime/bin/whisper-cli` is `fe7b744a…`, the same as its `delivery.json` entry;
  - it says "whisper.cpp version: 1.9.1".
- **ready:** "voice: ready on this machine (ready) — whisper.cpp 1.9.1 bin:fe7b744a4b31
  model:small.en@c6138d6d58ec". The decoder is the runtime's own.
- **heard:**
  - the talk control turned into "Stop talking";
  - the ledger stored a `PromptReceived` with `source` `jam` and the text "Please add a reminder to
    call the Northwind team tomorrow morning." That is word for word what was spoken;
  - it shows as the user's message in the conversation (frame `v-heard`).

**A harness artifact in `v-heard`.** The frame also shows "I can't hear anything. Check your mic
isn't muted". That is what the app says once the stand-in WAV has run out. It is not judged here.

## 4. The quota panel's reading age: PASS, with one premise corrected

The walk is `accounts-walk.sh` with the new step 5c (`ACCOUNTS_WALK_UNTIL=age`), run Q2
(`walk-75491df2fca8`), exit 0. Every check passed, including steps 0 to 5b on the way.

**The brief's premise, corrected.** The brief says each account row "shows its figure with its
age". The code shows the age only when a row's last good reading is older than the normal check, 5
minutes (`ui/quota.js` `renderLanes`, commit `abba6a411`). A current row shows no age, by design.
Both states were walked:

- **Current** (frame `q-age-fresh-dark`): both rows show their figures; Home five-hour 20%, weekly
  86%; Work five-hour 0%, weekly 12%. Neither shows an age. The tree has no "read" node.
- **Old.** Both accounts then answered null (the fake's `{"null": true}`, as Claude Code does some
  of the time). After 5.5 minutes:
  - **dark** (frame `q-age-dark`, crop `q-age-lanes-dark-x2`): Home "five-hour 20% weekly 86%
    read **7 min** ago"; Work "five-hour 0% weekly 12% read **7 min** ago";
  - **light** (frame `q-age-light`, crop `q-age-lanes-light-x2`): the same, "read **9 min** ago"
    on both;
  - an exhaustive accessibility find of "read" gives 2 nodes in each theme, one per row;
  - the mini bars are drawn as stale;
  - the header says "Last reading 7 min ago (stale)".

**Contrast** (`qa/contrast.py`, run Q2's frames; the boxes are the text nodes' own geometry):

| Text | Light | Dark |
|---|---|---|
| "read" (Home row, in-use tint) | 6.39:1 (#585D66 on #FCFBF6) | 5.74:1 (#99A0B0 on #1A2640) |
| "read" / "ago" (Work row) | 6.35:1 (#595E67 on #FDFCF8) | 5.80:1 (#989FAF on #182440) |
| the age, bold ("7 min", "9 min") | 18.07:1 (#0C1322) | 12.06:1 (#DFE4EE) |

Every value passes AA for normal text (4.5:1). They agree with the commit's computed 6.36/5.78 and
18.07/12.06 to within the estimator.

## D15 (found here, from candidate 43's handoff code, not blocking)

**The fast-usage line can name a point the account has already passed.**

**Where.** In the conversation, as a line where Rich reached out, not in the Technical view. Seen in
both one-account runs (H1-1 and H1-2; frames `h1-4-after-order` and `h1-5-after-handoff`).

**Steps.**
1. Account 1's week is at 50%, under the test cut-off 51.
2. It reads 51% about a minute later.

**Actual:**
- "Usage is climbing fast: 1 agent took the weekly window from 50% to 51% in 1 minute. I'm
  checking every minute now and will pause them at **44%**, not 51%, so it never reaches 100%."
  Run H1-1 said 43%.
- The account is already at 51%, so "will pause them at 44%" names a point it passed before the
  sentence was written.
- Later, "Usage is back to normal. I'm checking every 5 minutes again, and the line is back at
  93%." That is the five-hour line, not the weekly one the first sentence was about.

**Expected.** When the moved point is at or below the current figure, the line says the pause (or
the switch) happens now, not at a lower percentage. The way back names the weekly point it moved
from.

**Cause, from the code:**
- The weekly point is now `base - (ceil(speed x (interval + handoff)) - 1)`, with no cap
  (`Reading::weekly_point`, `quota.rs:163`, commit `867313f0c`).
- `note_speed` (`quota.rs` about line 1228) prints "will {verb} at {act}%" without comparing `act`
  with the window's current figure.
- On the way back, the one-account branch prints the five-hour `pause_percent`.

**It is not only the test cut-off (from the code, not seen on screen).** At the real base, 99, an
account at 96% of its week climbing 1 point a minute gets a point of 89. The line would then say
"will pause them at 89%, not 99%" while the account is at 96%.

**Why it does not block:**
- What the app does is right. A point below the current figure acts on the next check: the order
  reached the helper 52 s after 51% was written, and the continuation waited as it should.
- The wrong words are in one sentence. The next thing Rich says is the switch or the pause itself.

**What this candidate changed.** Before `867313f0c` the weekly point could move at most 2 points,
to 97%, so this sentence could rarely name a passed point. `9d12dd848` fixed the "not 99%" half of
the same sentence under the cut-off, and left this half.

## Verification mode

- **Environment.** The test VM, one fresh guest per run through `run-walk.py`, never this Mac's
  screen. At most two runs at once, one per guest slot. One app window, no two-user test. Guest
  screen 1680x1050 at 1x, app window 1400x864.
- **Theme.** The app's own Theme control.
- **Artifact.** The candidate's signed zip, with the same folder's `richos-engine-1.2.0.tar.gz` as
  `--engine`.
- **Accounts.** The fake `claude`, so no real Claude account was read, signed in or switched.
- **Audio.** No sound was played. The sample was written to a file (`say -o`) and fed through the
  app's WAV stand-in for the microphone.

### Runs

Every run reported "clean: app quit, VM stopped, clone deleted, state removed." and released its
slot.

| Run | VM | Walk (at commit) | Result | Seconds |
|---|---|---|---|---|
| S1 | `walk-7c5125bea6ae` | `setup-walk.py` (2198c68bb) | identity refused: given the source commit, not the build commit | 51 |
| S2 | `walk-c868e861bdc6` | `setup-walk.py` (2198c68bb) | **every step PASS** | 201 |
| H2-1 | `walk-7de64f57aafc` | `handoff-walk.sh two` (2198c68bb) | harness: the first-run memory question blocked every step | 403 |
| H2-2 | `walk-5d6b85f83e00` | `handoff-walk.sh two` (9bb75ca01) | every check ok, exit 0 (there was no once check yet) | 277 |
| H2-3 | `walk-1d11f44dcb68` | `handoff-walk.sh two` (f40d09932) | every product check ok, once = 1; the tree capture hit the guest deadline (harness) | 301 |
| H2-4 | `walk-0061d71c893e` | `handoff-walk.sh two` (c6dc2076f) | **every check ok, once = 1, exit 0** | 283 |
| H1-1 | `walk-1e332b65d8c6` | `handoff-walk.sh single` (3d4db4690) | every check ok, exit 0 (there was no once check yet); D15 seen | 319 |
| H1-2 | `walk-4312d1a46459` | `handoff-walk.sh single` (c6dc2076f) | **every check ok, once = 1, exit 0**; D15 seen again | 332 |
| V1 | `walk-3a7bf18bcf81` | `voice-walk.py` (8817d0364) | harness: first-run, the same memory question | 75 |
| V2 | `walk-d0c19aa8a45b` | `voice-walk.py` (706668f2c) | harness: relaunch, the setup sheet over the window | 168 |
| V3 | `walk-97f1d5c0430a` | `voice-walk.py` (3d4db4690) | harness: relaunch, looked for an AXButton, the control is an AXCheckBox | 185 |
| V4 | `walk-516ebea0caad` | `voice-walk.py` (45046f843) | the same, with the tree that showed it | 202 |
| V5 | `walk-16961cddf059` | `voice-walk.py` (430b8006f) | **every step PASS** | 165 |
| Q1 | `walk-cb80366dad73` | `accounts-walk.sh` age (3d4db4690) | harness: wrong app data folder; OCR missed a lane | 1618 |
| Q2 | `walk-75491df2fca8` | `accounts-walk.sh` age (3f0c2b618) | **every check PASS, exit 0** | 1460 |

### Every harness failure, read from its own evidence

**The first run's sheets (H2-1, V1).**
- What the evidence shows:
  - a fresh guest without the video tools now gets the setup sheet first, then the memory question
    ("Where should I keep what you tell me?");
  - the walks pressed one Not now, so the memory question stayed over the window;
  - `ax.sh` said `blocked: … modal=Where should I keep what you tell me?`.
- This is the designed order (`main.js`, WHAT A FIRST RUN ASKS). The setup essentials added the
  first sheet for this guest.
- Fixed in `9bb75ca01` and `706668f2c`: Not now is pressed until the company question is up, and
  never on that question itself.

**The relaunch (V2, V3, V4).** Three causes, one after another:
- V2: declining setup leaves the video tools missing, so the relaunched app puts the setup sheet up
  again (`relaunch-missing.png`). Fixed in `3d4db4690`.
- V3: with the sheet declined, the window opened on the conversation, not the home screen.
- V4: its tree showed the only "Talk to Rich" was `#talk-toggle`, an `AXCheckBox/AXToggle`. The
  walk looked for an AXButton. `45046f843` kept the raw find and the tree; `430b8006f` accepts
  either role.

**The tree (H2-3).** The whole-window tree passed `ax.sh`'s 20 s guest deadline, with the host at
97% CPU. The exhaustive find of "Handed over cleanly." answered anyway, `matches 1`. The tree is now
evidence only (`c6dc2076f`).

**The quota walk (Q1):**
- The app data folder was found by the bare name `claude-accounts` and resolved to the guest home,
  so every record read missed and Work's null fixture went nowhere. Home's row did show "read 7 min
  ago" in both themes.
- OCR read the light row as "read 9min ago" and missed the dark one.
- Fixed in `3f0c2b618`: the folder under `com.richos.app`, and the count taken from the
  accessibility tree.

## Not walked, and why

- **Everything walk 42 passed.** Candidate 43's other merges were not in the brief's four items.
- **`handoff-real-walk.py`.** The real helper's own `RichOS handoff:` commit, on his real accounts:
  not in this brief.
- **Item 1 of walk 41.** Restarting into a downloaded update cannot be offered to a candidate until
  a later nightly is published.

## Method and toolkit

All of it is `richos/app/scripts/` on this branch, on top of the candidate's source `2198c68bb`.

**`testvm/`:**
- `run-walk.py --wait` and `slots.py status`;
- the walks:
  - `handoff-walk.sh` (two, single);
  - `setup-walk.py`;
  - `voice-walk.py` (through `adopt-walk.py`'s first run);
  - `accounts-walk.sh` with `ACCOUNTS_WALK_UNTIL=age`;
- through them: `ax.sh` (`find --json`, `tree`, `click`), `shot.sh`, `guest.sh` and `relaunch.py`.

**`qa/`:**
- `contrast.py` (regions);
- `frame.py crop --scale 2`;
- `ocr-find.sh` (the D15 sentence and the "back to normal" line in the H1 frames);
- `ocr-gate.sh` with its positive control;
- `wait-for.sh --log`.

**Elsewhere:**
- `nightly-local.py candidate --run 20261007T141713Z-8d53fa5b`;
- `say -o` and `afconvert` for the sample;
- `shasum` and `sips` (JPEG copies).

**Scripts written from scratch: none.** The walks were fixed and extended, each change its own
commit:
- `8817d0364`: accounts-walk step 5c, the lanes' age;
- `9bb75ca01`: handoff-walk and accounts-walk answer every first-run Not now;
- `706668f2c`: adopt-walk `decline_first_run_sheets`, with `test/adopt-walk.test.py`
  FirstRunSheets (9/9);
- `3d4db4690`: voice-walk declines the setup sheet after the relaunch, with
  `test/voice-walk.test.py` (11/11);
- `45046f843`: voice-walk keeps the raw find and the tree when the relaunch fails;
- `f40d09932`: handoff-walk counts "Handed over cleanly." in the whole window;
- `430b8006f`: voice-walk takes the talk toggle as the window being up (12/12);
- `c6dc2076f`: handoff-walk's tree is evidence only;
- `3f0c2b618`: accounts-walk finds the app data folder and counts ages in the tree.

### Frames

- **Format.** JPEG q80 copies of the 1680x1050 PNG originals. Every number above was measured on
  the PNG.
- **Prefixes.**
  - `s-` is setup run S2;
  - `h2-` is H2-4;
  - `h1-` is H1-2;
  - `v-` is V5;
  - `q-` is Q2.

  The two `q-age-lanes-*-x2` crops are 2x.
- **The privacy gate.** `ocr-gate.sh` ran over the 15 PNG frames these JPEGs were made from, with
  its positive control: "0 of 15 frame(s) carry something that must not ship".

## Surfaces

**Applied and checked:**
- the Mac desktop app from its signed bundle, on the first-run path and after a relaunch;
- the setup sheet;
- the conversation (the handoff, the switch and the fast-usage lines, the spoken message);
- the Technical view's Claude Code quota sheet in light and dark;
- the records behind them: `claude-accounts.json`, the handoff markers, the work records and the
  conversation ledger.

**Not applicable:**
- phones: nothing touched;
- battery: no `richos/mobile/**` change;
- the stable channel: nothing was published.

**Test data.** Each guest was a fresh clone with its own empty home. Nothing touched this Mac's app
data. No real account was read or switched.

## Cleanup

- **The runs.** All fifteen ended clean, each releasing its slot. The last was Q2: "slot released:
  guest.lock after 1460s".
- **After the last run:**
  - `slots.py status` read "guest.lock: free" and "guest-2.lock: free";
  - `~/.richos-testvm/tart/vms/` holds only `richos-base`;
  - `~/.richos-testvm/run/` is empty.
- **This Mac.** No app was started on it. `pgrep -fl richos-tauri` and `pgrep -fl 'tart run'` both
  listed nothing, with the checking command's own lines filtered out.
- **Scratch.** `/Volumes/E1TB/tmp/claude/ray-opus-walk43/` was deleted after this record was
  committed.

## Defects, in one list

- **D15 (new, from candidate 43's dynamic weekly point, not blocking).** During fast weekly use, the
  conversation says Rich "will pause them at 44%, not 51%" while the account is already at 51%. The
  way back names the five-hour 93% line instead of the weekly point.

Verdict: READY
