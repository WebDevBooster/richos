# Walk of nightly candidate 37 (`v1.2.0-nightly.20261005.37`), 2026-10-05

**Verdict: READY.** All four defects of the candidate-36 walk are fixed on this candidate, seen live
with one real Claude account and in the simulated two-account states, in light and dark. When Claude
Code answers with no usage figures, the panel now says so plainly, keeps **+ Add account** and an
unlocked **Ask Claude Code** / **Refresh**, and the pause card says nothing is held. When a reading
arrives, it shows. The fast dot is at full gold (6.36:1 dark, 3.83:1 light). The one-account sheet
reads round 16's words, and "Five-hour five-hour" is gone. The reading line wraps between its two
parts and never leaves one word alone.

One new defect was found, **D5**: on the five-hour ruler, the "now" label and tick run into
"began 10:20 AM" early in the window. It is cosmetic and comes and goes with the clock. It is not
part of this candidate's change. The code that places the label is unchanged since `b6e7a2cc0`, so
nightly 35 and candidate 36 had it too, and neither walk happened to land in the window where it
shows. I do not hold the multi-account nightly for it. It should be fixed in the next build. Details
are under Defects.

## Scope

The brief: re-walk only what changed since candidate 36, with one real account, in light and dark.
`git log --oneline 0d8004fca..d052d5af7 -- richos/app/ui richos/app/src-tauri richos/app/crates`
lists seven commits. Six are `echo-opus-walkfix1`'s (`2bb7359ad`, `1fb1c8cf5`, `a6d621b6a`,
`459acae33`, `6d2319c62`, `64878bb72`), merged as `3cc31f313`. The seventh, `a5f25ec59`, changes
only the test `ui/tests/memory-strategy.js`. `git diff --stat 0d8004fca d052d5af7` shows that the
app's only shipped files that changed are `quota.rs`, `quota/gate.rs`, `ui/quota.js`, `ui/style.css`
and `ui/mock.js`. The rest is tests, scripts and records. Everything else passed in walk 36
(`7e9dcf7ac`) on unchanged code, and was not walked again (see "Not walked").

## Verification mode

- Environment: the test VM, one fresh guest per run through `run-walk.py`, never this Mac's screen.
  One app window per guest, no two-user test. Guest screen 1680x1050, app window 1400x864 pt. Light
  and dark were switched live through the guest's macOS appearance (the app's Theme follows the
  system). In the round-16 walk the app's own theme control switched them.
- Artifact: the candidate's own signed bundle,
  `~/.richos-nightly/releases/v1.2.0-nightly.20261005.37/RichOS-1.2.0-nightly.20261005.37-macos-aarch64.zip`,
  with the same release folder's `richos-engine-1.2.0.tar.gz` as `--engine`.
- Identity, checked before any claim:
  - `shasum -a 256` of the zip: `eb3093e126485d430d12093d17cbbfb8873d5046615ca57dd1d406db6dc46291`.
    This equals its `SHA256SUMS` line and the `files` entry in `candidate.json`.
  - `candidate.json`: `source_commit` `d052d5af7714a4a08a7309f0d9334a658a549deb`, `run_id`
    `20261005T101725Z-05149934`. The walk workspace was at that commit (`git log -1`: `d052d5af7`).
    `3cc31f313`, `6d2319c62` and `64878bb72` are its ancestors (`git merge-base --is-ancestor`).
  - The build commit `7249fb135` changes only `nightly-build.json`, `Cargo.toml`, `Cargo.lock` and
    `tauri.conf.json` (`git diff --stat d052d5af7 7249fb135`).
  - The app's own Settings menu read "RichOS 1.2.0-nightly.20261005.37 is up to date" (`ax.sh find
    --value 1.2.0-nightly --contains`, run E1 step 10; frame `e1-settings-light`).
- Runs: four guest runs, all `execution: completed`, `scenario_exit: 0`, `cleanup_complete: true`.
  R16 and E1 ran at the same time, one in each guest slot.

| Run | VM | What | Seconds |
|---|---|---|---|
| R16 | `walk-0c6af9a4abdc` | `round16-panel-walk.sh` against this bundle: states 0 to 7, dark and light | 1732 |
| E1 | `walk-e5c68025cddd` | one real account: the panel, pause on, Refresh, + Add account, dark, the next automatic check (steps `walkE.json`) | 655 |
| E2 | `walk-a175c4d397d5` | the same steps, a fresh guest | 631 |
| E3 | `walk-bdca2ef569dc` | the same steps, a fresh guest | 600 |

- Toolkit used: `richos/app/scripts/` at the candidate source `d052d5af7`, plus this branch's
  `0b28f2708`. Commands: `testvm/run-walk.py --wait`, `testvm/steps-walk.py` (and `--check` on the
  step list), `testvm/ax.sh` (through steps-walk), `testvm/shot.sh` (through steps-walk),
  `testvm/guest.sh` (through steps-walk), `testvm/slots.py status`, `testvm/round16-panel-walk.sh`,
  `qa/usage-shape.sh` (pushed into each guest), `qa/contrast.py` (regions, `--box`, `--nontext`),
  `qa/frame.py crop`, `qa/ocr-gate.sh`, `qa/redact.py --phones` and `qa/wait-for.sh --log`.
  `nightly-local.py candidate --run` printed the opening instructions.
- Scripts written from scratch: none. One committed tool was corrected. `qa/usage-shape.sh` still
  called `rate_limits: null` "UNREADABLE ... Malformed", which was the reader's rule on candidate 36.
  Since `2bb7359ad`, `quota.rs` `normalize` returns `ReadError::NoReading` for it. The tool now prints
  `verdict: NO READING: rate_limits is null (the reader calls this NoReading: no figures this time,
  not an error)`, with the same exit 1. Its case US1, its help and its README row were updated in
  the same commit (`0b28f2708`). `qa.test.sh`: "all 222 passed". E1 and E2 ran the older wording,
  because they pushed the tool before the change. E3 ran the new one.
- Frames: JPEG q80 of the 1680x1050 PNG originals. Every number below was measured on the PNG.
  `ocr-gate.sh` ran with its positive control over every source PNG of R16, E1 and E2. It found four
  hits. Three were the `2026-08-28`/`2026-08-30` dates in technical-view notes, which it reads as
  phone-shaped (`r16` 4 dark, 4 light, 6 dark). Those three were covered with `redact.py --phones`,
  which re-scanned each output as clean. The fourth was `e1/q-pauseoff-dark`, a 17-character digit
  run, and that frame is not committed. The final set (35 frames) plus E3's 11 source frames:
  "0 of 46 frame(s) carry something that must not ship".

## D1. The quota panel with one real account: PASS

What each guest showed. Claude Code 2.1.289 is the host's version, copied in by `claude-sync.sh`.
`usage-shape.sh` asks the way the reader does, a few seconds after the panel's own check, so its
answer is a separate sample, not the app's.

| Run | At first open | `usage-shape.sh` | Then | Frames |
|---|---|---|---|---|
| E1 | A reading from 1 min ago, with the notice "Claude Code answered without its usage figures just now. The figures below are from 1 min ago and may have moved on. RichOS asks again in 5 min; Refresh asks sooner." + Add account and Refresh present. | 11:13:23 `rate_limits: null` | Pause on: "On. Nothing is waiting." Refresh: "Asking Claude Code…", then null again, "asks again in 5 min" (it was 3 min before, so the timer was counted again). At 11:21 the automatic check brought a reading: 11%, "Checked 2 min ago", notice gone. | `e1-q-first-light`, `e1-q-pauseon-light`, `e1-q-refresh-asking-light`, `e1-q-refresh-after-light`, `e1-q-pauseon-dark`, `e1-q-later-dark`, `e1-q-later-light` |
| E2 | "No reading yet." "Nothing to show yet." with "Claude Code answered without its usage figures this time ..." and "RichOS asks again in 4 min; Ask Claude Code asks now." + Add account beside Ask Claude Code. | 11:25:46 readable | Pause on: "No current reading, so nothing is held." with Refresh now (`ax.sh find --value 'nothing is held'`: 1 match). Ask Claude Code: a reading within seconds, 12%, "Checked under a minute ago", and the card turned to "On. Nothing is waiting." | `e2-q-first-light`, `e2-q-pauseon-light`, `e2-q-refresh-after-light`, `e2-q-pauseon-dark` |
| E3 | The same "No reading yet." state | 11:38:59 `NO READING: rate_limits is null`; 11:46:28 readable | Pause on: "No current reading, so nothing is held." Ask Claude Code: null again, "asks again in 5 min". At 11:46 still no reading ("asks again in 4 min", so the 11:45 automatic check was null too). + Add account still present. | `e3-q-first-light`, `e3-q-refresh-after-light`, `e3-q-later-dark` |
| R16 state 0 | The fixture answers `rate_limits: null` with pause on: "No reading yet.", + Add account, Ask Claude Code, "No current reading, so nothing is held." The walk log says "+ Add account offered with no reading", "Ask Claude Code offered" and "the card says nothing is held". | (fixture) | | `r16-0-no-reading-light`, `r16-0-no-reading-dark` |

Checks across all three real-account guests, at first open, after Refresh/Ask, and at the later check:
- "could not read": `ax.sh find --value 'could not read' --contains` matched nothing, every time.
- "Next refresh available" (the old lock): matched nothing, every time.
- + Add account: `ax.sh find --title '+ Add account'` matched at first open and at the later check in
  every guest, reading or not. It opened the form "Add a second Claude account" and Cancel closed it,
  in both themes (`e1-q-add-open-light`, `e1-q-add-open-dark`). No second account was signed in.
- Refresh / Ask Claude Code was never locked. Pressing it asked at once (`e1-q-refresh-asking-light`).
- Both cases were seen with a real account: no reading (E2, E3) and a reading arriving and showing
  (E1 at its automatic check, E2 after Ask Claude Code).

**"Background work is not held": verified only as far as the screen shows it.** With pause on and no
reading, the card says "No current reading, so nothing is held. ... Rich's agents keep working ...",
read live in E2, E3 and R16. With one real account no background agent work was running in these
guests, so I did not see an agent being let through. The admission rule itself (`Admission::NoReading`)
rests on Echo's unit test `a_null_usage_answer_is_no_reading_this_time_and_never_locks_or_holds`, which
I did not re-run.

Observed, not a defect: Claude Code's answer changes from one minute to the next. In E3 the app got
null three times in 8 minutes, while `usage-shape.sh` got a readable answer at 11:46:28, about a
minute after the app's last null.
In E2 it was the other way round. The app treats each null as "no figures this time", as designed.
Why Claude Code answers null is **not verified**. It was not measured on the CEO's own install.

## D2. The fast dot, at 3:1 in both themes: PASS

`qa/contrast.py --box 997 473 14 14 --nontext`, the same box as in walk 36, on `r16-5-fast-sheet-*`:

| | Background | Dot core | Ratio |
|---|---|---|---|
| Dark | `#182440` | `#C2A35C` | **6.36:1** PASS (walk 36: 2.11:1) |
| Light | `#FDFCF8` | `#9C7C34` | **3.83:1** PASS (walk 36: 3.26:1 at the captured phase) |

The dot's core is the full gold in both frames. One frame per theme shows one phase of the breath.
That the dot never fades is backed by the frame and by `style.css` (`@keyframes quota-breathe` now
has only `transform`). The signing lane's `.quota-lane-pulse` shares those keyframes. It appears
only while an account is signing in, which no walked state reaches, so it was **not seen live**.

## D3. One-account wording matches round 16: PASS

Compared with round 16's `low` render (`docs/verification/2026-10-04-round16-panel-vm/1-one-account-round16-low-light.png`),
on `r16-1-one-account-light`/`-dark` and the real account's `e1-q-later-dark`/`-light`:
- "Straight from Claude Code, shared across every app and session on this account."
- "Five-hour window" with "the one the pause watches". "Weekly window".
- "Pause Rich's agents once the five-hour window passes 93% used, unless the reset is under 20
  minutes away." and "Off — the line is only drawn, not enforced."
- "Off. Nothing is paused." with "Rich's agents keep working through the limit. When the five-hour
  window is spent, Claude Code turns them away until it resets — and Rich tells you."
- "A pause is not a stop. ..." and "Your conversation with Rich, and any Claude Code you run outside
  RichOS, are never paused."

"Five-hour five-hour" and "five-hour pause threshold" appear nowhere in the shot OCR of E1, E2 and E3.
As a positive control, "the one the pause watches" appears 18 times in the same text.

## D4. No single word alone on a line: PASS

- Reading line, fast state: "Checked under a minute ago ·" over "every minute — usage is fast", the
  two parts whole, in both themes (`r16-5-fast-sheet-*`). Walk 36 had "usage is / fast".
- Reading line while asking (the wider "Asking Claude Code…" button): "Checked 3 min ago ·" over
  "checks every 5 min" (`e1-q-refresh-asking-light`). It goes back to one line when the answer comes.
- `6d2319c62` on this real app: the hint is "Off — the line is only drawn," over "not enforced."
  (`e1-q-first-light`, `r16-1-*`). The no-reading card ends "RichOS asks again in" over "5 min."
  (`e3-q-refresh-after-light`, `r16-0-*`). The last two words stay together.
- `64878bb72` on this real app: the empty state's second paragraph is smaller and muted, "RichOS asks
  again in 4 min; Ask Claude Code asks now.", at 6.33:1 light and 5.78:1 dark (`e2-q-first-light`,
  `r16-0-*`).
- Not reached live: the stale line ("Last reading ... — stale"). No reading went stale in these runs.

## Two-account states (`round16-panel-walk.sh`, run once against this bundle): PASS

The walk log (`2026-10-05-nightly-37-candidate-walk/r16-walk.log`) reached "done" with no
"never appeared" line. Its new state 0 shows **+ Add account** with the null answer (above). States
1 to 7 show the same content as walk 36 and Echo's accepted shots, with D2, D3 and D4 now fixed.
- 2: Home in use 41%/28%, Work next 10%/20%, the one sentence, no scrollbar.
- 3: Work in use, Home at 95% with no tag, "switch to the next account — none has room now".
- 4: "Switched to Work — Home reached 95% of its five-hour window. Nothing stopped." and
  "3 agents working on Work".
- 5: "switch at 91% · was 93%", "switches at 97% · was 99%", and the card's round-16 sentence.
- 6: "3 agents reading at once took Work's five-hour window ...".
- 7: "Usage is back to normal. ...".

These states are unchanged since walk 36, and the frames were looked at for regressions, not
re-judged line by line.

## Contrast, computed (`qa/contrast.py`, its one estimator printed with each answer): PASS

Normal text must reach 4.5:1 and non-text 3:1. No exemption is claimed.

| Surface (frame) | Light | Dark |
|---|---|---|
| No reading: "No reading yet.", + Add account, Ask Claude Code, empty body, second paragraph (16px muted) (`r16-0-*`) | 18.07, 6.65, 18.07, 18.07, 6.33 | 12.06, 6.36, 12.06, 12.06, 5.78 |
| No reading card: head, body, Refresh now; hint "Change the number ..." (`r16-0-*`) | 18.07, 6.33, 18.07; 6.33 | 12.06, 5.78, 12.06; 5.78 |
| Null notice over a reading: head, body (`e1-q-first-light`, `e1-q-pauseon-dark`) | 15.74, 15.74 | 9.74, 9.74 |
| Reading line: "Checked 1 min ago", "checks every 5 min", + Add account, Refresh (`e1-*`) | 18.07, 6.35, 6.65, 18.07 | 12.06, 5.80, 6.36, not measured |
| One account: subtitle, "Five-hour window", "the one the pause watches", "Weekly window" (`e1-q-first-light`, `e1-q-pauseon-dark`) | 6.33, 18.07, 6.35, 18.07 | not measured, 12.06, 5.80, not measured |
| Hint "Off — the line is only drawn," / "not enforced." (`e1-q-first-light`) | 6.35 / 6.35 | not measured |
| Card "Off. Nothing is paused." head, body (`e1-q-first-light`) | 18.07, 6.33 | not measured |
| Card "On. Nothing is waiting." head, plain body line (`e1-q-pauseon-*`) | 18.07, 6.33 | 12.06, 5.78 |
| Fast sheet: "Checked under a minute ago ·", "every minute — usage is fast", card title (`r16-5-*`) | 18.07, 6.65, 18.07 | 12.06, 6.36, 12.06 |
| **Fast card dot (non-text)** (`r16-5-*`) | **3.83** | **6.36** |

"Not measured" cells use the same tokens as the measured cell beside them, and walk 36 measured
the same tokens in that theme (12.06 / 5.78–6.36 dark). The lowest text measured here is 5.78:1.

## Defects

**D5 (layout, minor, not blocking): on the five-hour ruler, "now" runs into "began 10:20 AM".**
- Seen in E1 at 11:13 (window began 10:20, so 18% of the way) in light, and at 11:21 (20%) in dark.
  The tick passes through "AM" and the "now" label sits on top of it (`e1-ruler-crop-light`,
  `e1-ruler-crop-dark`, cut from `e1-q-first-light` and `e1-q-later-dark`). At 22% (E2, 11:27) they
  only just clear each other (`e2-q-refresh-after-light`).
- Cause (hypothesis from the code): `quota.js` `ruler()` shows the label on the hero ruler whenever
  more than 11% of the window has passed ("round 16's rule: 11-86%"). In this 1400 pt window the
  ruler is about 624 px wide, and "began 10:20 AM" takes about 124 px of it, so the label overlaps
  "began" until about 20%. That is roughly 30 minutes of every five-hour window. A fixed percentage
  cannot know how wide the stamp is.
- Not a regression: the threshold is from `b6e7a2cc0` (round 16 rebuild) and unchanged since. Walk 36
  read its ruler 2 h into the window, where it does not show.
- Expected: the label never touches the stamp. Hide it, or move it, based on the measured width of
  "began …" rather than a percentage.
- Why not blocking: it does not stand in the way of the multi-account test, it appears in the
  technical view only, and it was already in the published nightly 35. It should be fixed in the
  next build.

Observations, not defects:
- While "Asking Claude Code…" is shown, the wider button pushes the reading line to two lines for a
  moment (D4's rule at work), then it goes back.
- The dotted or solid pause line reaches down to just above "resets 3:20 PM", touching the colon
  (`e1-ruler-crop-*`). The same is in walk 36's frames, which passed.

## Not walked, and why

- Everything walk 36 passed on unchanged code: home, first run, attachments, Settings menu, account
  connection, technical view dialog, company buttons, the 93% threshold draft and Keep. The diff
  since candidate 36 touches none of them (`git diff --stat 0d8004fca d052d5af7`).
- The stale reading line (D4's second example from walk 36): no reading went stale in these runs.
- `.quota-lane-pulse` live: it appears only while a second account signs in, and the brief forbids
  signing one in.
- Signing in a second real account: forbidden by the brief. The two-account states are the fixture's.
- An agent actually being let through while pause is on with no reading: no background work ran in
  the one-account guests (see D1).

## Surfaces

Applied and checked: the Mac desktop app from its signed bundle, the returning path (company set),
light and dark. The panel was reached through the gear, then Technical view, then the menu row.
Pause was turned on, then off again. Refresh and Ask Claude Code were pressed. The Add account form
was opened by its button and left by Cancel, in both themes.
Not applicable: phones and mobile clients (nothing touched), battery (no `richos/mobile/**` change),
voice (no audio played), and the stable channel (this walk promotes nothing).

## Cleanup

All four runs ended with `clean: app quit, VM stopped, clone deleted, state removed` and released
their slot. Afterward, `slots.py status` read `guest.lock: free`, `guest-2.lock: free`. The harness's
VM folder `~/.richos-testvm/tart/vms/` holds only `richos-base`, so no walk clone remains.
`pgrep -fl richos-tauri` on this Mac found nothing, because no app was ever started here. The scratch
directory `/Volumes/E1TB/tmp/claude/ray-opus-walk37/` was deleted before the report.

## Defects, in one list

- D5 (minor, not blocking, not a regression): the five-hour ruler's "now" overlaps "began …" between
  about 11% and 20% of the window.

Verdict: READY
