# Walk of nightly candidate 36 (`v1.2.0-nightly.20261005.36`), 2026-10-05

**Verdict: NOT READY.** One defect blocks the thing this nightly is for. With one real Claude account,
the quota panel often has no reading at all. When that happens it hides **+ Add account**, so the
multi-account feature cannot be started. It locks **Refresh** for about 10 minutes and blames
"this version of RichOS". If the automatic pause is on, it also holds new background work. Everything
else walked passes. That covers home, first run, attachments, Settings, account connection, the
technical view, the 93% setting, the company buttons and all seven simulated two-account states.
Contrast is measured AA in both themes, with one exception: the fast card's breathing dot (D2). The
four defects are listed at the end.

## Verification mode

- Environment: the test VM, one guest per run through `run-walk.py`, a fresh clone each time, never this
  Mac's screen. Each guest showed one window, and there was no two-user test. The guest screen was
  1680x1050 and the app window 1400x864 pt. Light and dark were switched live through the guest's macOS
  appearance (the app's Theme is "follow system"). In the round-16 walk the app's own theme control in
  the Settings menu switched them.
- Artifact: the candidate's own signed bundle,
  `~/.richos-nightly/releases/v1.2.0-nightly.20261005.36/RichOS-1.2.0-nightly.20261005.36-macos-aarch64.zip`,
  with the same release folder's `richos-engine-1.2.0.tar.gz` as `--engine`.
- Identity, checked before any claim:
  - `shasum -a 256` of the zip is `0f4420d94ca0d588d1ca8808af23c82813f8a530c143b348c84cc7b4acc8541a`.
    That equals its `SHA256SUMS` line and the `files` entry in `candidate.json`.
  - `candidate.json` `source_commit` is `0d8004fca8a428b30a42485cbd3db37aa9ae34d5`. The walk workspace
    was at that commit (`git log -1`: `0d8004fca`).
  - The build commit `28e52055f` changes only `nightly-build.json`, `Cargo.toml`, `Cargo.lock` and
    `tauri.conf.json` (`git diff --stat 0d8004fca 28e52055f`).
  - The app's own Settings menu read "RichOS 1.2.0-nightly.20261005.36 is up to date." (`ax.sh find
    --value 1.2.0-nightly`, walk A step 24, and frames `settings-light`, `settings-dark`).
- Runs: six guest runs, all `execution: completed`, `scenario_exit: 0`, `cleanup_complete: true`.

| Run | VM | What | Seconds |
|---|---|---|---|
| A | `walk-e88ff86d5db6` | first run, home, attachments, Settings, account, technical view (steps `walkA.json`) | 525 |
| R16 | `walk-acb2d02f8bbb` | `round16-panel-walk.sh` against this bundle, the seven states, dark and light | 1701 |
| B | `walk-c1587e17a1b2` | company buttons, quota panel, the 93% setting, both themes (steps `walkB.json`) | 279 |
| C1 | `walk-b1a7b4818568` | the quota reading diagnosed: panel plus a first version of the usage probe | 141 |
| C2 | `walk-d639ce196539` | the same with the committed `qa/usage-shape.sh` (steps `walkC.json`) | 129 |
| D | `walk-5bfaa6500f7e` | real reading, + Add account opened and canceled, light and dark (steps `walkD.json`) | 136 |

- Toolkit used (toolkit at `8504378d9` plus this branch's commit): `testvm/run-walk.py`,
  `testvm/steps-walk.py` (step lists in `2026-10-05-nightly-36-candidate-walk/steps/`), `testvm/ax.sh`,
  `testvm/shot.sh`, `testvm/guest.sh`, `testvm/hand-file.sh` (through steps-walk), `testvm/slots.py`,
  `testvm/reserve.py`, `testvm/round16-panel-walk.sh`, `qa/contrast.py` (region, two-color, `--box`,
  `--nontext`, `--large`, `--dump`), `qa/frame.py px`, `qa/ocr-gate.sh`, `qa/redact.py` (`--box`,
  `--phones`).
- Scripts written from scratch: one, now committed as **`qa/usage-shape.sh`**. It asks a `claude` for
  its usage the way the quota reader does and prints only the shape of the answer. No helper did this.
  It has `--help`, exit 1 on an answer the reader refuses, exit 2 with a sentence when there is nothing
  to read, cases US1 to US4 in `scripts/qa.test.sh` and a row in `qa/README.md`. `qa.test.sh` ran with
  all 222 cases passing. Run C1 used a first version of the same probe, the same request with
  shape-only output. Its output is quoted below and the file was not kept.
- Frames: JPEG q80 of the 1680x1050 PNG originals. Every number below was measured on the PNG.
  `ocr-gate.sh` ran with its positive control over every source PNG of every run. It found nine hits:
  the guest's `/Users/admin/testvm/...` path on the first-run screen, and `2026-08-28`/`2026-08-30`
  dates in technical-view notes that it reads as phone-shaped. The eight frames that are committed were
  covered with `redact.py` (`--box` for the path, `--phones` for the dates). The gate then read
  "0 of 8 frame(s) carry something that must not ship". The ninth, `after-close-light`, is not committed.
  Runs C2 and D were gated afterward: 0 of 8.

## Per item

### 1. Home and the core screens, real account, both themes: PASS

Frames are under `2026-10-05-nightly-36-candidate-walk/`.

| Step (run, what I did) | What I saw | Frame | Result |
|---|---|---|---|
| A: cold start, empty home | "Where should I keep what you tell me?" with Set it up / Not now; the folder path (redacted) | `firstrun-light` | PASS |
| A: Not now, typed "Walk Test Co", Add this company | Home: "Walk Test Co / Running", the "I don't know your business yet." card, Rich's greeting | `home-light`, `home-dark` (B) | PASS |
| A: pasted a PNG as a screenshot (`handfile paste`) | Chip "image.png, PNG image · 2.1 MB" with its remove control | `attach-paste` | PASS |
| A: dragged a second PNG from the desktop onto the composer | Second chip "Screenshot board 12.png" beside the first | `attach-drag` | PASS |
| A, B: Settings (gear) | Theme, Text size, Technical view, Splash screen, Company, Company buttons..., Connected repositories, Account connection, Memory folder, Use Rich from your phone, Updates with the version line, Bust a bug! | `settings-light`, `settings-dark` | PASS |
| A: Account connection | "Your Anthropic account is connected." with Close, in both themes | `account-light`, `account-dark` | PASS |
| A: Technical view, then Cancel | Dialog "Turn on the technical view" (three scopes); Cancel leaves the switch off and the menu open | `techy-dialog-light`, `techy-canceled-light` | PASS |
| B: Technical view, Turn it on | Pill "Technical view · everywhere"; the menu gains "Claude Code quota" with its status line | `techy-on-dark`, `settings-techy-light`, `settings-techy-dark` | PASS |
| B: Company buttons... | "Company buttons on the home screen": label field "1", Show checked, the one-company note, Done | `homebuttons-light`, `homebuttons-dark` | PASS |

The attachment steps were walked in light only, as in walk 33.

### 2. The quota panel with one real account: FAIL (defect D1)

| Run | What the panel showed at first open | Frame |
|---|---|---|
| B | "No current reading". The notice reads "Claude Code returned quota data this version of RichOS could not read. Next refresh available in 8 min." Then "No reading yet." **No + Add account.** | `quota-dark`, `quota-light` |
| C1 | The same, "Next refresh available in 9 min", no + Add account (`ax.sh find --title '+ Add account'`: nothing matched) | `quota-noreading-walkC-light` |
| C2 | A reading already marked stale: "Last reading 1 min ago — stale", 4% five-hour, 15% weekly, "Weekly · Fable 0%", each tagged stale, plus the same "could not read" notice. + Add account present. | `quota-real-stale-light`, `quota-real-stale-add-open-light` |
| D | A fresh reading: "Checked 1 min ago · checks every 5 min", 4% / 15% / 0%, + Add account beside Refresh | `quota-real-light`, `quota-real-dark` |

What Claude Code answered, read from inside the guest by the same request the app sends (2.1.289, the
host's version, copied in by `claude-sync.sh`):

```
run C1 (first probe version)            run C2 (qa/usage-shape.sh, exit 1)
claude: 2.1.289 (Claude Code)           claude: 2.1.289 (Claude Code)
response id=quota-1 subtype=success     response id=quota-1 subtype=success
response id=quota-2 subtype=success     response id=quota-2 subtype=success
  payload keys: behaviors,rate_limits,    payload keys: behaviors,rate_limits,
    rate_limits_available,session,          rate_limits_available,session,
    subscription_type                       subscription_type
  rate_limits_available: true             rate_limits_available: true
  rate_limits: absent (*)                 rate_limits: null
                                          verdict: UNREADABLE: rate_limits is null
                                            (the reader calls this Malformed)
```

(*) The first probe version printed "absent" for any undefined value. The key itself is listed among
the payload keys, so the value was null, as C2's tool shows.

`quota.rs` `normalize` requires `rate_limits` to be an object, so a null becomes `ReadError::Malformed`:
"Claude Code returned quota data this version of RichOS could not read." The reader is unchanged since
nightly 35 (`git diff v1.2.0-nightly.20261003.35 0d8004fca` on `probe.rs` adds only the per-account
folder, and `normalize` is identical). So this is how the app handles an answer that Claude Code 2.1.289
gives some of the time: two of the four guests had no reading at all, one went stale within a minute,
and one read cleanly. Why Claude Code sometimes answers null is **not verified**. It was not measured
on the CEO's own install, because that would read his live data.

The rest of the one-account items:

| Item | Result | Evidence |
|---|---|---|
| The reading, when Claude Code answers | PASS | D: "Checked 1 min ago", Five-hour 4% with its bar, tick and "pause off · 93%" line, Weekly 15%, Weekly · Fable 0%, the ruler key, both themes (`quota-real-light`, `quota-real-dark`) |
| + Add account, open and Cancel | PASS when a reading exists | D: the form "Add a second Claude account" with its two name fields, Add and sign in, Cancel and "Claude Code signs in through your browser."; Cancel closes it and focus returns to + Add account (gold ring), light and dark (`quota-real-add-open-*`, `quota-real-add-canceled-*`). No second account was signed in. |
| + Add account with no reading | FAIL (D1) | B, C1: the button is not on the sheet (`quota.js:663` hides it when the state is unavailable and there are no windows) |
| The setting at 93% | PASS | B: the switch turns pause on ("Saved."); typing 90 shows "Save 90%" and "Keep 93%"; Keep 93% puts 93 back; the switch turns it off again (`quota-pause-on-*`, `quota-threshold-draft-light`, `quota-threshold-kept-light`) |
| Pause on with no reading | FAIL (part of D1) | B: the card reads "Waiting for a current reading. New background work will wait until the five-hour allowance is known. Refresh the reading or turn pause off." Refresh is locked by the cooldown. |
| Fast-usage state, one real account | Not reachable live | Usage cannot be made to climb on a real account. It is walked with the simulated accounts in item 3, states 5 and 6. |

### 3. The two-account states, simulated: PASS, with D2, D3 and D4 noted

`round16-panel-walk.sh` ran once against this signed bundle and took it unchanged (`--bundle` accepts
the zip). The walk log reached "done" with no "never appeared" line. Each state is compared with the
round-16 render committed in `docs/verification/2026-10-04-round16-panel-vm/` and with Echo's accepted
shot of the same state there.

| State | This candidate (frames `r16-N-*`) | Against round 16 | Result |
|---|---|---|---|
| 1 one account | + Add account beside Refresh, "Checked 3 min ago · checks every 5 min", 41%, the ruler key | Same as Echo's accepted shot. The copy differs from round 16's `low` render (D3). | PASS, D3 |
| 2 two accounts | Home in use 41%/28%, Work next 10%/20%, one sentence with pause/switch, "On. Nothing is waiting.", no scrollbar; Work has Remove, Home has none | Matches, apart from the declared Home-has-no-Remove | PASS |
| 3 switched sheet | Work in use 10%, Home 95% with no tag, "switch to the next account — none has room now", "In use: Work, since 6:54 AM." | Matches | PASS |
| 4 switched line | "Switched to Work — Home reached 95% of its five-hour window. Nothing stopped." while the turn runs, then "• 3 agents working on Work" | Matches Echo's accepted shot. The row sits in the status zone above the composer, as Echo declared. | PASS |
| 5 fast sheet | "every minute — usage is fast", "switch at 91% · was 93%", "switches at 97% · was 99%", the card's round-16 sentence with "3 agents reading at once" | Matches, with Echo's declared "every minute". Two defects: the dot (D2) and "fast" wrapping onto its own line (D4) | PASS, D2, D4 |
| 6 fast alert | "Usage is climbing fast: 3 agents reading at once took Work's five-hour window from 10% to 13% in 2 minutes...", then a turn with the working row | Matches | PASS |
| 7 back to normal | "Usage is back to normal. I'm checking every 5 minutes again, and the lines are back at 93% and 99%.", then a turn with the working row | Matches | PASS |

### 4. Contrast, computed (`qa/contrast.py`, its one estimator printed with each answer): PASS except D2

Normal text must reach 4.5:1 and non-text 3:1. No exemption is claimed anywhere.

| Surface (frame) | Light | Dark |
|---|---|---|
| Settings menu: title, Theme, Technical view, version line, Bust a bug! | 18.07 | 12.06 |
| Settings "Checked ... ago", "Update server:" | 6.33, 5.37 | 5.78, 5.51 |
| Company select, Company buttons... button | 15.58 | 14.78 |
| Technical view switch, off, thumb against menu (non-text) | 6.95 | 6.08 |
| Home card title/body, hint, Not now | 17.02, 6.15, 17.02 | 13.02, 6.09, 13.02 |
| Home "Start the questions" | 4.72 | 7.68 |
| Rich label, message, composer placeholder | 4.99, 14.90, 5.37 | 6.11, 14.55, 5.51 |
| Sidebar Search, company label, Set your name; breadcrumb | 5.83, 5.83, 4.99; 4.99 | 6.62, 6.62, 6.22; 6.18 |
| Company buttons dialog: title, body, label, Show, note, Done, field "1" | 18.07, 6.33, 18.07, 18.07, 6.33, 4.72, 5.98 | 12.06, 5.78, 12.06, 12.06, 5.78, 7.68, 6.51 |
| Quota, no reading: eyebrow, subtitle, "No current reading", notice, body, Automatic pause, sentence, status title/body, boundary, field "93" | 7.16, 6.33, 6.33, 15.74, 18.07, 18.07, 18.07, 18.07/6.33, 18.07, 6.33 | 4.90, 5.78, 5.78, 9.74, 12.06, 12.06, 12.06, 12.06/5.78, 12.06, 5.78 |
| "No reading yet." (large) | 6.33 | 5.78 |
| Threshold draft: Save 90%, Keep 93%, "Saved." | 4.72, 18.07, 6.65 | not shot |
| Real reading: Checked, + Add account, Resets, pause off · 93%, began, Weekly, Weekly · Fable, ruler key | 18.07, 6.65, 18.07, 6.33, 18.07, 18.07, 18.07, 18.07 | 12.06, 6.36, 12.06, 5.78, 12.06, 12.06, 12.06, 12.06 |
| Stale reading: "Last reading ... — stale", stale tag | 6.65, 6.65 | not shot |
| Add account form: title, labels, placeholders, Add and sign in, Cancel, browser note | 18.07, 6.33, 5.37, 4.72, 18.07, 6.33 | 12.06, 5.78, 5.51, 7.68, 12.06, 5.78 |
| Five-hour fill against the panel (non-text) | 3.83 | 6.36 |
| + Add account focus ring after Cancel (non-text) | not shot | 6.36 |
| Two-account sheet: in use, next, Remove, week resets, lane label, pause at 93%, switches at 99%, + Add account, radio, status title/body, sub-line | 6.00, 18.07, 6.33, 18.07, 16.46, 6.65, 6.65, 6.65, 18.07, 18.07/6.33, 6.33 | 5.44, 12.06, 5.78, 12.06, 10.48, 6.36, 6.36, 6.36, 12.06, 12.06/5.78, 5.78 |
| Fast sheet: "every minute — usage is fast", "was 93%", card title, card body | 6.65, 6.65, 18.07, 6.33 | 6.36, 6.36, 12.06, 5.78 |
| **Fast card status dot (non-text, breathing)** | 3.26 at the captured phase | **2.11, FAIL** |
| Conversation (state 4): working row, "Nothing new for ...", Rich is working, "3 working", "Working for", "reached out", Worked, the switch line, Between turns, user bubble, pill | 5.90, 5.42, 14.90, 4.99, 5.83, 4.99, 4.99, 14.90, 5.83, 5.50, 6.33 | 5.91, 7.88, 14.55, 6.11, 6.48, 6.11, 6.11, 14.55, 6.48, 5.74, 5.78 |
| Working-row dot, Rich-is-working dot (non-text) | 3.15, 5.42 | 7.68, 7.88 |

The lowest passing text is 4.72:1 (light gold buttons). The dark meter region printed 1.90:1 for the white
"now" tick where it crosses the gold fill (`--dump`). The tick runs above and below the bar on the panel
at 12.06:1, and the fill against the panel is 6.36:1, so I do not count it as a failure.

### 5. Everything else in `git log v1.2.0-nightly.20261003.35..0d8004fca -- richos/app/ui richos/app/src-tauri richos/app/crates`

There are 34 commits. Walked above: the quota panel rebuild, fill-first, the switch notice, the working
row, the fast card and the speed checks. These are walked through the panel and the round-16 states.
**Not walked live, and not counted as passed:** the hunt part 1 v3 fixes 48 to 51 (reader swap, reset
ending a hold, switch waiting on a running command, quit reaching every reader), the settings-refusal
memory fix, `nav.rs` pin/archive/rename restore and the TEST-copy push acceptance. Each is internal or
needs a staged failure, and each carries its own committed test. No phone was touched.

## Defects

**D1 (blocker): one real account often gets no quota reading, and then + Add account disappears.**
Seen in runs B and C1 (`quota-dark`, `quota-light`, `quota-noreading-walkC-light`). In C2 the reading
went stale (`quota-real-stale-light`).
- What I saw: Claude Code 2.1.289 answered `get_usage` with `rate_limits_available: true` and
  `rate_limits: null` in both probes. The panel treats that as "Claude Code returned quota data this
  version of RichOS could not read" and starts a 10-minute Refresh cooldown. With no earlier reading it
  shows "No reading yet." and hides + Add account. With pause on, it holds new background work until a
  reading arrives.
- Expected: a null answer is treated as "no reading yet, checking again soon", not as a version problem.
  + Add account stays available with one account whatever the reading. The user is not locked out of
  Refresh by an answer that says nothing.
- Why it blocks: the CEO's stated purpose for this nightly is to test the multi-account feature. On some
  launches the entry to it is simply not there.

**D2 (contrast): the fast card's dot breathes below 3:1.** `style.css:7059`
`.quota-status-dot.is-fast` runs `quota-breathe` (opacity .35 to 1). In this frame it measured 2.11:1 in
dark against the 3:1 non-text floor (`r16-5-fast-sheet-dark`, box 997,473 14x14). This is the same
pattern Echo removed from the working row (`9cbdac8ea`, HANDOFF "Declared difference"). `.quota-lane-pulse`
(`style.css:7010`) uses the same keyframes. That is a hypothesis from the code, not seen on screen in
these states. Expected: full opacity, breathing size, as `#quota-work-status` does.

**D3 (design fidelity): the one-account sheet keeps round 14's words, not round 16's `low`.** Frames
`r16-1-one-account-*` and `quota-real-light` against `1-one-account-round16-low-light.png`. Each item
gives the app's words, then round 16's:
- Subtitle: "Your Claude Code allowance, shared across apps and sessions." / "Straight from Claude Code,
  shared across every app and session on this account."
- Window label: "Five-hour five-hour pause threshold" (it reads as a stutter) / "Five-hour window the one
  the pause watches".
- Weekly label: "Weekly" / "Weekly window".
- Pause sentence: "when the five-hour window reaches 93% used, unless the reset is less than 20 minutes
  away." / "once the five-hour window passes 93% used, unless the reset is under 20 minutes away."
- Round 16's "Off — the line is only drawn, not enforced." is missing.
- Status card: "Automatic pause is off / Rich's agents can use the available allowance..." / "Off.
  Nothing is paused. / Rich's agents keep working through the limit..."
- Boundary text: different.

`quota.js` line 4 says one account deliberately keeps round 14's sheet. Echo's handoff marked state 1
"Matches". I am listing it because the brief's criterion is "matches round 16", and the window label
stutter is visible to anyone.

**D4 (layout, minor): the reading line wraps one word onto its own line.** In the fast state "Checked
under a minute ago · every minute — usage is / fast" (`r16-5-fast-sheet-*`). With a real stale reading
it is "Last reading 1 min ago — stale · checks every 5 / min" (`quota-real-stale-light`). Round 16 keeps
it on one line. Echo's accepted shot 5 has the same wrap.

Observation, not a defect: the threshold field's focus ring touches the "%" that follows it while editing
(`quota-threshold-draft-light`).

## Surfaces

Applied and checked: the Mac desktop app from its signed bundle, the first-run and returning (company
set) paths, light and dark. For the quota panel: the gear, then the menu row, opened. It was left by
Close and by Escape. The Add account form was opened by its button and left by Cancel, with focus coming
back. Pause was turned on and off again, and the threshold edited and kept. The reverse transitions were
walked: Cancel on the technical-view dialog, Keep 93% on a threshold draft, pause off after on.
Not walked: keyboard shortcuts into Settings, turning the technical view off again, and signing in a
second real account (the brief forbids it).
Not applicable: phones and mobile clients (nothing touched), battery (no `richos/mobile/**` change),
voice (no audio played), and the stable channel (this walk promotes nothing).

## Cleanup

All six runs ended with `clean: app quit, VM stopped, clone deleted, state removed` and released their
slot. `slots.py status` afterward: `guest.lock: free`, `guest-2.lock: free`. The harness's `tart list`
(`TART_HOME=~/.richos-testvm/tart`) shows only `richos-base` and the two base images, so no walk clone
remains. No app was started on this Mac. The scratch directory `/Volumes/E1TB/tmp/claude/ray-opus-walk36/`
was deleted before the report.

Verdict: NOT READY
