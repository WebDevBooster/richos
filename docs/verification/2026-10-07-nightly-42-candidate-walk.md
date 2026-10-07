# Walk of nightly candidate 42 (`v1.2.0-nightly.20261007.42`), 2026-10-07

**Verdict: READY.** D13 is fixed on the candidate itself. On a fresh install with two accounts,
the Claude accounts sheet shows "Pause the team until it is fresh again" selected, in dark and in
light. It is also true: the app's pause is on, and when the account in use passes 93% of its
5-hour window, the app says the team will pause, and Rich does not switch accounts.

Candidate 42 adds only the D13 fix (`e90283dc5` and `40ae43c21`, merged at `51b2b50c0`) to
candidate 41, which passed everything else in walk 41
(`docs/verification/2026-10-07-nightly-41-candidate-walk.md`). Nothing else was walked again.

One defect turned up that this candidate did not introduce, D14 below. It is in the Technical
view only and does not block.

## Identity, checked before any claim: PASS

- `shasum -a 256` of `RichOS-1.2.0-nightly.20261007.42-macos-aarch64.zip` gives
  `265f35fd89513dffe9278694fa1c17091edef1cdd2ffd28486308c27738b6481`. Both of its lines in
  `SHA256SUMS` carry that hash: the versioned name and `RichOS-macos-aarch64.zip`.
- `candidate.json` `info` reads:
  - `source_commit` `51b2b50c080f01888bd8eba3501c8154fad62f41`;
  - `run_id` `20261007T043520Z-1a52a4cd`;
  - `version` `1.2.0-nightly.20261007.42`;
  - `build_commit` `0c710d6b9814a34ef8ba6b456a35fbcaa06ede60`.
- The build commit's parent is `51b2b50c0`. `git diff --stat 51b2b50c0 0c710d6b9` touches only four
  files: `nightly-build.json`, `Cargo.toml`, `Cargo.lock` and `tauri.conf.json`.
- The Settings menu of the running candidate reads "RichOS 1.2.0-nightly.20261007.42 is up to
  date." (frame `e-0-menu-version`, dark). The walk read the version from the accessibility tree
  too (`read: RichOS 1.2.0-nightly.20261007.42`) in all three runs.

## D13: FIXED

His item 9 sheet, Settings, then Claude accounts. Fresh install, two accounts (Home in use, Work
added through the sheet's own two steps), and nothing pressed under "When a 5-hour limit is almost
used up". Run E3 (`walk-171528896253`), exit 0.

**Selected, in both themes** (frames `e-5b-d13-sheet-dark`, `e-5b-d13-sheet-light`, the 3x crops
`e-d13-radios-dark-x3` and `e-d13-radios-light-x3`):
- "Pause the team until it is fresh again / The default. Never longer than 5 hours." is the chosen
  radio: AXValue `1`, a filled gold dot, and the card outlined.
- "Switch to Work" is not chosen: AXValue `0`, an empty circle.
- The same reading in all three runs, E1, E2 and E3, in dark and in light.
- This matches round 18 (`fiveChoice: "pause"`), the design walk 41 measured D13 against.

**True, not only drawn:**
- **The setting the app acts on.** With Technical view on, the Claude Code quota sheet's switch
  "Automatic pause or switch at the line" is on (AXValue `1`, frame `e-5b-d13-quota-on`), with
  "pause Rich's agents" chosen and the line at 93%. Its status card reads "On. Nothing is
  waiting." On candidate 41 the fresh install started with this pause off (walk 41's cause:
  `Policy::default()` is `enabled: false`); that was read from the code, not on 41's screen.
- **Behavior.** Home's 5-hour usage was set to 95% (weekly 86%) and the sheet refreshed:
  - the card reads "Ready to pause. The five-hour allowance has reached 93%. Agents will pause when
    they finish their current step." (frame `e-5b-d13-quota-held`). The app only says this when the
    pause is on: `Admission::Held` needs `policy.enabled`, and with the pause off the card's code
    path is "Off. Nothing is paused." (from the code; the off state was not put on screen);
  - `claude-accounts.json` still says `"inUse":"1"` (Home), with no `switched` change. Pause, not
    switch, is what happened at the line.
- **Where the setting lives.** No `claude-quota-policy.json` exists in the fresh install's app data.
  The fix makes a missing file mean "pause on at 93%" (`quota.rs`, `Service::open`). So the default
  holds on every launch until the person changes it, and changing it writes the file.

**Contrast** (`qa/contrast.py`, frames of run E3):

| What | Light | Dark |
|---|---|---|
| Chosen radio, gold ring and dot (non-text, 3:1) | 3.83:1 (#9C7C34 on #FDFCF8) | 6.36:1 (#C2A35C on #182440) |
| Unchosen radio ring (non-text, 3:1) | 6.15:1 | 6.09:1 |
| "Pause the team until it is fresh again" | 18.07:1 | 12.06:1 |
| "The default. Never longer than 5 hours." | 6.33:1 | 5.78:1 |

The quota sheet's switch in dark: its knob on the gold track 7.68:1; the gold track on the sheet is
the same pair as the radio, 6.36:1.

## D14 (found here, not from this candidate, not blocking): the quota sheet can show a negative line

- **Where:** Technical view only. Settings, then Claude Code quota, the five-hour window's heading
  and the status card. Run E2 (`walk-7f24258100bf`), frame `e2-d14-line-minus-36` and its 2x crop.
- **Steps:** two readings of Home's 5-hour window close together, the second much higher. In E2 it
  went from 20% to 95% between two Refreshes of the sheet; the walk read the card before and after
  them 17 seconds apart. E3, with the same steps, did not measure the jump as fast usage, so this
  depends on when the readings land (not reproduced on demand).
- **Actual:**
  - "Five-hour window · Home in use: the one the -36% line watches";
  - the card: "Home's five-hour window went from 20% to 95% in 1 minute. The lines moved to **-36%**
    and 99% so nothing reaches 100%; they return to 93% and 99% when the speed comes back down."
  - In the same card, "The five-hour allowance has reached 93%."
- **Expected:** a line between 0% and 100%. A person cannot act on "-36%".
- **Cause, from the code:** `Reading::act_point` (`crates/richos-core/src/quota.rs:93`) is
  `threshold.min(100. - reach)`, where `reach` is the measured speed times the check interval. It
  has no floor, so a speed whose reach is more than 100 points gives a line below zero, and the
  panel prints it (`ui/quota.js`, `fiveLine`).
- **Why it does not block this candidate:**
  - It is the §108 fast-usage code, which candidate 42 did not change; the 41 to 42 diff touches
    only the default.
  - It shows only in the Technical view, and only after a jump of more than about 100 points per
    check interval (one minute when usage is fast). Run E3, the same steps at a normal pace, showed
    "the one the 93% line watches".
  - What the app does is still right: a line below the current figure pauses at once, which is the
    safe side.
- **One thing this candidate does change:** on 41 the pause was off on a fresh install, so the card
  said the five-hour line was off. With the pause now on by default, a person with Technical view
  on can reach this text without changing a setting.

## Verification mode

- **Environment.** The test VM, one fresh guest per run through `run-walk.py`, never this Mac's
  screen. One run at a time, each started after the previous one had released its slot. One app
  window, no two-user test. Guest screen 1680x1050 at 1x, app window 1400x864.
- **Theme.** Switched with the app's own Theme control.
- **Artifact.** The candidate's own signed zip, with the same folder's `richos-engine-1.2.0.tar.gz`
  as `--engine`.
- **Accounts.** The committed fake `claude` (`fake-claude-fill-first.pl`), so no real Claude
  account was read, signed in or switched.

### Runs

Every run reported `execution: completed` and `cleanup_complete: true`.

| Run | VM | Walk | Result | Seconds |
|---|---|---|---|---|
| E1 | `walk-975166023ba2` | `accounts-walk.sh` at `9970f15ff` | steps 0 to 5 PASS; D13 radios PASS in both themes; the quota sheet checks FAIL (harness) | 1394 |
| E2 | `walk-7f24258100bf` | the same walk at `e5951cba0` | everything PASS except the switch's AXValue (harness); D14 seen | 768 |
| E3 | `walk-171528896253` | the same walk at `6744aa88a` | **every step PASS**, exit 0 | 753 |

All three ran with `ACCOUNTS_WALK_UNTIL=d13` and `ACCOUNTS_WALK_VERSION=1.2.0-nightly.20261007.42`.

### Every harness failure, read from its own evidence

- **E1.** The quota row was pressed by its words without a role. The press hit no control, so the
  sheet never opened, and every later check on it failed. Frame `5b-d13-quota-on` of E1 shows the
  menu open with "Claude Code quota / Home 86% weekly · next Work" on screen. Fixed in `e5951cba0`:
  the row is pressed as an AXMenuItem, as the walk already did for "Claude accounts"; the sheet's
  Refresh is pressed as an AXButton.
- **E2.** The switch was looked for by its one-account name, "Automatically pause Rich's agents".
  With two accounts it is named "Automatic pause or switch at the line" (`ui/quota.js:392`), so the
  find matched nothing. E2's own frame shows the switch on; its card read "On. Nothing is waiting."
  and "Ready to pause". Fixed in `6744aa88a`, and E3 passed.

## Not walked, and why

- Everything walk 41 passed: candidate 42 changes only the fresh install's quota default.
- Steps 6 to 11 of `accounts-walk.sh`: walk 41's run C3 passed them on candidate 41.
  `ACCOUNTS_WALK_UNTIL=d13` ends the walk after the D13 step.
- Item 1 (restart into a downloaded update): as in walk 41, a candidate cannot be offered an update
  until a later nightly is published.
- Light theme for the quota sheet: not part of D13, and its colors did not change in this
  candidate.

## Method and toolkit

All of it is `richos/app/scripts/` on this branch, on top of the candidate's source `51b2b50c0`.
- `testvm/`:
  - `run-walk.py --wait` and `slots.py status`;
  - the walk `accounts-walk.sh`, with the new step 5b;
  - through it, `ax.sh` (`find --json`, `click --role`), `shot.sh`, `guest.sh` and `relaunch.py`.
- `qa/`:
  - `contrast.py`, regions, `--nontext`;
  - `frame.py crop --scale`;
  - `ocr-gate.sh` with its positive control;
  - `wait-for.sh --log`.
- `nightly-local.py candidate --run 20261007T043520Z-1a52a4cd` for where the candidate is.

**Scripts written from scratch: none.** No walk checked which 5-hour choice is selected or whether
the pause is in effect, so `accounts-walk.sh` gained step 5b. Each change is its own commit:
- `9970f15ff` the D13 step, `ACCOUNTS_WALK_UNTIL` and `ACCOUNTS_WALK_VERSION`;
- `e5951cba0` the quota row and Refresh presses by role;
- `6744aa88a` the switch found by both of its names.

### Frames

- **Format.** JPEG q80 copies of the 1680x1050 PNG originals; every number above was measured on the
  PNG. `e-` is run E3, `e2-` is run E2. The crops are 3x (`e-d13-radios-*`) and 2x
  (`e2-d14-line-minus-36-x2`).
- **The privacy gate.** `ocr-gate.sh` ran over the 9 PNG frames these JPEGs were made from, with its
  positive control: "0 of 9 frame(s) carry something that must not ship". No frame shows a path.
- **`runs.jsonl`** holds each run's `run-walk.py` report, its walk log, the radios' and switch's
  accessibility reads and the account record, one run per line. The guest's home is written
  `<guest-home>`.

## Surfaces

- **Applied and checked:**
  - the Mac desktop app from its signed bundle, on the first-run path;
  - the Claude accounts sheet in light and dark;
  - the Technical view's Claude Code quota sheet, where the setting is shown and acted on;
  - the record behind them: `claude-accounts.json`, and the absence of `claude-quota-policy.json`.
- **Not applicable:**
  - the one-account sheet: the 5-hour choice only appears with two or more accounts, so D13 cannot
    show there. Its "When your account fills up" text says Rich pauses the team; with the default
    now on, that text is true as well (from the code, not walked);
  - phones: nothing touched;
  - battery: no `richos/mobile/**` change;
  - voice: no audio played;
  - the stable channel: nothing was published.
- **Test data:** each guest was a fresh clone with its own empty home. Nothing touched this Mac's
  app data, and no real account was read or switched.

## Cleanup

- **The runs.** Each ended with "clean: app quit, VM stopped, clone deleted, state removed." and
  released its slot. The last was E3: the app quit by its recorded pid 1177, then "slot released:
  guest.lock after 753s".
- **After the last run.** `slots.py status` read "guest.lock: free" and "guest-2.lock: free".
  `~/.richos-testvm/tart/vms/` holds only `richos-base`, and `~/.richos-testvm/run/` is empty.
- **This Mac.** No app was started on it. `pgrep -fl richos-tauri` and `pgrep -fl 'tart run'`, with
  the lines of the checking command itself filtered out, both listed nothing.
- **Scratch.** `/Volumes/E1TB/tmp/claude/ray-opus-walk42/` was deleted after this record was
  committed.

## Defects, in one list

- **D13 from walk 41:** fixed. Pause is selected on a fresh install with two accounts, in both
  themes, and the app acts on it.
- **D14 (found here, from earlier code, not blocking):** after a very fast jump in the 5-hour
  figure, the Technical view's quota sheet names a line below zero ("-36%").

Verdict: READY
