# Walk of nightly candidate 39 (`v1.2.0-nightly.20261006.39`), 2026-10-06

**Verdict: READY.** I walked again the five defects that walk 38 found in the Output panel (D6 to
D10). All five are fixed on this candidate. I saw each one live in the test VM with one real Claude
account, in light and in dark:

- **D6:** a file deleted outside the app reads as gone as soon as the panel reopens. Its row, its ⋯
  menu, its own view and the view's ⋯ menu all say so. Every action is off, each with the §6.7
  sentence as its reason. Copy path stays on.
- **D7:** Under the hood now opens alone. The Output panel closes, and both Output buttons read
  unpressed.
- **D8:** a background job's question is in the conversation. There is no quit card and no
  "Status unavailable" row, and the app stayed open the whole time.
- **D9:** the CSV facts line wraps with no lone "·".
- **D10:** the Output list's scroll bar is dark in dark, on a list of 30 files that reaches well
  past the window.

One minor defect remains, D11, and it does not hold the nightly. In dark, the conversation's own
scroll bar and the Under the hood scroll bar are still drawn light. This is not new: walk 38
recorded it as older than its range, and the D10 fix is scoped to the Output panel.

## Scope

The brief asked me to walk again only what changed since walk 38 (source `ed13a8c76`).
`git log --oneline ed13a8c76..d31271b9a` lists 20 commits. 9 of them are walk 38's own branch,
merged as `55982b9de`. The changes that ship in the app are:
- `echo-opus-fix38`: D6 `7ed47337d` (output-panel.js), D7 `55f65b6e6` (main.js), D9 `fb32f0332`
  (output-panel.js and style.css) and D10 `8257df873` (style.css);
- `echo-opus-d8`: D8 `7d603103a` (timeline.js).

`git diff --stat ed13a8c76 d31271b9a -- richos/app/ui richos/app/src-tauri richos/app/crates`
names only those four app files. Everything else it lists is under `ui/tests/`.

**The brief's premise, checked.** It says "everything else passed in walk 38 and has not changed".
That is true of every file except one. `output-panel.js`'s `open()` now reads the list again on
every open, and it restores focus after that redraw. Every way of opening the panel goes through
that function. This walk opened the panel with the top Output button and by closing and reopening
it, and it opened a row's own view and both menus. It did not repeat the link, "Wrote N files",
bottom-button, pull or sidebar steps (see "Not walked").

## Verification mode

- Environment: the test VM, one fresh guest per run through `run-walk.py`, never this Mac's screen.
  - One app window per guest, and no two-user test.
  - Guest screen 1680x1050 at 1x. The app window is 1400x864 at 140,77, read from the
    accessibility tree in run C.
  - The guest shows scroll bars always.
  - Light and dark were switched live through the guest's macOS appearance. The app follows the
    system on a fresh install.
- Artifact: the candidate's own signed bundle,
  `~/.richos-nightly/releases/v1.2.0-nightly.20261006.39/RichOS-1.2.0-nightly.20261006.39-macos-aarch64.zip`,
  with the same folder's `richos-engine-1.2.0.tar.gz` as `--engine`.
- One real account: the host's Claude Code 2.1.290, synced into each guest (`claude: host 2.1.290
  guest 2.1.290` in every run log).

### Identity, checked before any claim: PASS

- `shasum -a 256` of the zip gives `b1f50cdb67249483e242864bca42b6c92f8b567b55b928134f9a9b31f00dbe6d`.
  That equals its line in `SHA256SUMS` and its `files` entry in `candidate.json`.
- `candidate.json` `info` reads:
  - `source_commit` `d31271b9adc32448b59e8cc0d69e433a42777433`;
  - `run_id` `20261006T021835Z-d365a57c`;
  - `version` `1.2.0-nightly.20261006.39`;
  - `build_commit` `54652eb9072a…`.
- `nightly-local.py candidate --run 20261006T021835Z-d365a57c` printed the same source and bundle.
  The walk workspace was at `d31271b9a` when the walk began.
- **The app reports its build commit, not its source commit.** `git diff --stat d31271b9a
  54652eb90` shows that the build commit changes only `nightly-build.json`, `Cargo.toml`,
  `Cargo.lock` and `tauri.conf.json`. Every run's `identity` step was given `--expect-sha
  54652eb90`. Runs A, B and C each read `built_from: 54652eb9072a31258f3a34e85be0c3c45dafee6a` from
  the running app.
- The Settings menu read "RichOS 1.2.0-nightly.20261006.39 is up to date." in light and in dark
  (run S; `ax.sh find --value 1.2.0-nightly --contains`, one match in each theme; frames
  `s-settings-light`, `s-settings-dark`).

### Runs

Every run reported `execution: completed` and `cleanup_complete: true`. The two guest slots were
used side by side.

| Run | VM | Steps | Exit | Seconds |
|---|---|---|---|---|
| A | `walk-7224f7188f3a` | identity, first-run, connect, panel, csv, missing, scroll | 1 (scroll, see below) | 880 |
| B | `walk-5d767d06906f` | identity, first-run, connect, panel, backend-worker, overlap, job-question | 0 | 948 |
| C | `walk-8f2ff78702fc` | identity, first-run, connect, scroll | 0 | 353 |
| S | `walk-1b16aba95881` | `steps-walk.py` with `steps/walkS.json`: the Settings version line in both themes | 0 | 93 |

**What the walk itself caused:** A's `scroll` ended on `ax.sh find --title "All output"`, exit 124.
Its 30 rows made a whole-window find outlast the 35 s guest deadline. Two things were wrong in my
step: it raised the deadline too little, and the host-side `subprocess` wait stayed at 40 s whatever
deadline the step set. Both are fixed in `4fefce269`. That fix also helps `job-question`, which sets
a 150 s deadline. Run C repeated the step and it PASSED. This is not an app defect: the panel had
already opened on the list.

### Toolkit

I used `richos/app/scripts/` at the candidate source `d31271b9a`, plus this branch's two commits.
- `testvm/`: `run-walk.py --wait`, `output-walk.py`, `steps-walk.py` (`--check` on the step list,
  then the run), `ax.sh` (through the walk scripts) and `slots.py status`.
- `qa/`: `contrast.py` (regions and `--nontext` colors), `frame.py` (`px`, `edges`, `crop`),
  `ocr-gate.sh`, `redact.py --homes` and `wait-for.sh --log`.
- `nightly-local.py candidate --run`.

**Scripts written from scratch: none.** `steps/walkS.json` is a step list, which is data for
`steps-walk.py`; `e386b8120` declares it in `steps-walk-data.test.sh`, which checks it (3 ok).
I extended the toolkit with two commits on this branch:
- `16a4a48d1` `output-walk.py`:
  - a new step, `scroll` (30 files, the list must reach past the window, photographed in both themes);
  - `overlap` now fails when an Output button still reads pressed;
  - `missing` also reads the file view's ⋯ menu and its size line, and photographs the row menu,
    the view and the view's menu in both themes;
  - `csv` records where each part of the facts line sits, so a frame can show whether the line
    wrapped;
  - `job-question` photographs both themes.
- `4fefce269` `output-walk.py`: `OutputWalk.ax` waits on the host for the deadline the step raised,
  plus 30 s. `scroll` takes its photographs before it reads 30 rows.

The VM run is the only proof for `output-walk.py`: no unit test covers it. Runs A, B and C ran
the first commit, and run C also ran the second.

### Frames

- The frames are JPEG q80 copies of the 1680x1050 PNG originals. Every number below was measured
  on the PNG.
- `ocr-gate.sh` ran with its positive control over all 17 source frames. It flagged 2 frames,
  `b-overlap-light` and `b-overlap-dark`, for the guest's own home path (`/Users/admin/testvm/…`)
  in Under the hood's work receipts.
- `redact.py --homes --pad 4` covered both and re-read them as clean. The final pass read
  "0 of 17 frame(s) carry something that must not ship".
- `runs.jsonl` holds, one file per line: each run's `run-walk.py` report, its step report, and the
  observations of csv, missing, scroll, overlap, job-question and backend-worker. The operator's
  home path is replaced by `~/`.
- No email-shaped string is left in it. The one name left is in the public update-server URL that
  the Settings menu shows.

## D6, a gone file: FIXED

Run A, step `missing`, on its own row `walk-table.csv` (frames `a-missing-*`):
- The file was deleted in the guest. `test -f` read yes just before the `rm -f` and no just after.
  The panel was then closed and opened again.
- At once the head reads "2 files from this thread · 1 no longer where it was written". The row is
  dimmed and reads "No longer where it was written" in italics, with no folder line
  (`a-missing-list-light`).
- **Row ⋯ menu:** Open, Show in Finder, Save a copy… and Add to chat are disabled. Each one's
  reason (AXHelp) is exactly "This file is no longer where it was written. If it was moved, open it
  from its new place; if Rich writes it again, it will be listed here." Copy path is enabled
  (`a-missing-row-menu-light`, `a-missing-row-menu-dark`).
- **Its own view:**
  - The head reads "walk-table.csv / No longer where it was written".
  - The single Open button is disabled, with the same reason. The gold "Open in TextEdit" of walk
    38 is gone, and so is the size line: no text in the view mentions bytes.
  - Below it are the path "~/Acme/walk-table.csv", with its copy control, and the §6.7 sentence
    (`a-missing-file-view-light`, `a-missing-file-view-dark`).
  - The contradiction that walk 38 found ("Written today … · 30 bytes" beside "no longer where it
    was written") is gone.
- **The view's ⋯ menu:** Open, Show in Finder, Save a copy… and Add to chat are disabled with the
  same reason, and Copy path is enabled (`a-missing-view-menu-light`, `a-missing-view-menu-dark`).
- Stage B (press Open so that the panel learns) did not run. Stage A already passed, and the step
  says so: "A passed: the panel knew at reopen".

## D7, one right-hand pane at a time: FIXED

Run B, step `overlap`, after a real worker job had landed (frames `b-overlap-*`):
- With the Output panel open, I pressed "Open the work summary", the chip under the conversation
  ("… 5 saved work records").
- Under the hood slid in alone. "Close the output panel" was no longer in the window
  (`output_still_open: false`).
- Both Output buttons, "Output — 4 files from this thread" at y 112 and at y 878, read AXValue `0`,
  which means unpressed.
- No cut head ("OUTPU") and no second pane, in either theme.
- The slide-over still covers the right part of the bottom Output button, as any overlay covers
  what is under it. With the panel closed, that is the conversation, not a second pane.
- **Hypothesis from the code, not walked:** the next press of either Output button opens the panel.
  `paintButtons` writes `aria-pressed` from `state.open`, which is the value the toggle reads. The
  AXValue `0` seen live therefore means the toggle state is closed too.

## D8, a background job's question with the app open: FIXED

Run B, step `job-question`, with no relaunch in the run. The app pid was 1036 throughout, as
recorded at launch (frames `b-job-question-*`):
- Run B's worker job (notes.md and notes.zip) landed without asking anything, and so did its
  panel-check job. No job was blocked.
- The step then asked once, the way a back end asks. It used the app binary in `--questions-mcp`
  mode with the job's own obligation as its turn: `work-18461cb55379467ca8592a596aacc4af`,
  `recorded: true`.
- **Who asked is part of the basis.** The question came from the walk, through the job's own
  question tool. The model did not choose to ask.
- One read of the whole window (124 nodes) found:
  - one question card, "Your team · through Rich", "Which name should the walk file get?", with
    its two options and "Other answer";
  - no "last time RichOS was open" card;
  - no "Status unavailable" row.
- The sidebar's "Running" carries a 1, the waiting question. Both themes show the same.

## D9, the CSV facts line: FIXED

Run A, step `csv`. The panel is at its split width:
- The facts line wraps. Read from the accessibility tree, "2 rows" sits at 1159,489,
  "Comma-separated" at 1237,489 and "The whole sheet opens in TextEdit" at 1159,521.
- On the frames, line one reads "2 rows · Comma-separated" and ends there. Line two starts with
  "The whole sheet opens in TextEdit", flush with "2 rows", and has no dot before it
  (`a-preview-csv-light`, `a-preview-csv-dark`).
- The fix's spacing between two parts on one line looks as before.

## D10, the Output list's scroll bar in dark: FIXED

Run C, step `scroll` (frames `c-scroll-light`, `c-scroll-dark`):
- One shell command wrote `scroll-01.txt` to `scroll-30.txt`. All 30 reached the record, and the
  head reads "30 files from this thread".
- The panel lists them, and the lowest row sits at y 1869, below the window's bottom at y 941.
  34 row controls are below the window, so the list has something to scroll.
- The panel's scroll bar, measured with `frame.py px` and `frame.py edges` on the PNGs:

| Theme | Track | Thumb | Panel ground |
|---|---|---|---|
| Light | #FAFAFA | #C2C2C2 | #EAE6DD |
| Dark | #181E28 (x 1526..1538) | #5E6269 (y 221..523) | #0A101B |

In walk 38, the dark track was #FAFAFA with a #C2C2C2 thumb. In dark it is now a dark track with a
mid-gray thumb, which is macOS's own dark scroller.

**Declared exemption, WCAG 1.4.11:** the user agent sets how a scroll bar looks, and the app does
not change it. The fix only declares `color-scheme`. So the scroll bar is not held to 3:1. Its
figures, for the record (`contrast.py --nontext`): thumb on track 2.73:1 in dark and 1.71:1 in
light. These are macOS's own scroller colors.

## Readability of what changed

Measured with `qa/contrast.py`, its one estimator. Normal text must reach 4.5:1.

| Surface (frame) | Light | Dark |
|---|---|---|
| Gone row: name, "No longer where it was written" (`a-missing-row-menu-*`) | 5.83, 5.93 | 6.56, 6.56 |
| Panel head title (same) | 14.90 | 14.93 |
| Row menu: disabled item, enabled item | 6.33, 18.07 | 5.78, 12.06 |
| Gone file's view: subtitle, path, §6.7 sentence, disabled Open (`a-missing-file-view-*`) | 5.83, 5.83, 5.83, 6.15 | 6.56, 6.56, 6.56, 6.09 |
| CSV facts: "2 rows", "Comma-separated", "The whole sheet opens in TextEdit" (`a-preview-csv-*`) | 5.83, 4.99, 4.99 | 6.56, 6.18, 6.18 |

The lowest figure is 4.99:1. The disabled menu items are inactive controls under WCAG 1.4.3. They
were measured anyway, and they clear 4.5:1 too.

## Defects

**D11 (minor, not blocking, not new): in dark, the conversation's scroll bar and Under the hood's
are still drawn light.**
- Measured on the PNGs with `frame.py px`:
  - the conversation (`c-scroll-dark`, x 1132): track #FAFAFA, thumb #C2C2C2;
  - the conversation (`b-job-question-dark`, x 1532): the same;
  - Under the hood (`b-overlap-dark`, x 1512): the same.
- This is walk 38's D10 note about the conversation's track, which that walk recorded as older
  than its range. `8257df873` states that it fixes only the Output panel.
- Expected: every scroll area in the app follows the theme, as the panel now does.
- Cause (from the code): no `color-scheme` is declared outside `#outpanel` and the forced-dark
  settings cluster.
- It shows only where scroll bars always show, such as a mouse or the guest's setting. On a
  trackpad's overlay scroll bars it may never show (hypothesis).

Observations, not defects:
- A gone file keeps Preview lit in its row menu. The code does this on purpose; PRD §4.6 lists
  Preview among the disabled actions. This is unchanged from walk 38, and it is the PRD owner's
  call.
- Run B's "Produced 3 files" strip shows `notes.zip`, `notes.md` and `rev-notes-fresh.zip`. The
  third is a reviewer's scratch file, listed by the PRD's Q3 default ("list everything"). That
  question is still the CEO's to decide.

## Not walked, and why

- **Walk 38's other steps** (empty, buttons, link, actions, save-copy, attach, menus, wrote,
  theme-flash, pull, sidebar, and the worker approval):
  - the brief excludes them, and none of their code changed except `output-panel.js`'s `open()`
    (see Scope);
  - this walk opened the panel with the top button, reopened it, and used a row view and both
    menus;
  - the bottom button, a conversation link and "Wrote N files" all reach the same `open()`, and
    they were not pressed.
- **The first press of an Output button after Under the hood:** see D7. This is a hypothesis
  from the code and the live AXValue.
- **D10 in the file view and in a wide table's scroller:** `color-scheme` is inherited from
  `#outpanel`, but no view in these runs was long or wide enough to scroll.
- **A job asking its own question, unprompted:** the model did not ask in run B, so the walk asked
  through the same tool (see D8).

## Surfaces

- Applied and checked:
  - the Mac desktop app from its signed bundle, on the first-run path;
  - light and dark, for each of D6 to D10;
  - every entrance to the gone-file actions: the row's ⋯, the view's Open and the view's ⋯;
  - the way into Under the hood (the work summary chip) and the way back ("back to Rich").
- Test data: each guest was a fresh clone with its own empty home. Nothing touched this Mac's app
  data.
- Not applicable:
  - phones: nothing touched;
  - battery: no `richos/mobile/**` change;
  - voice: no audio played;
  - the stable channel: this walk promotes nothing, and nothing was published.

## Cleanup

- Runs A, B, C and S each ended with "clean: app quit, VM stopped, clone deleted, state removed"
  and released their slot.
- Afterward, `slots.py status` read `guest.lock: free` and `guest-2.lock: free`.
  `~/.richos-testvm/tart/vms/` holds only `richos-base`.
- `pgrep -l richos-tauri` on this Mac found nothing. No app was started here.
- The scratch directory `/Volumes/E1TB/tmp/claude/ray-opus-walk39/` was deleted before the report.

## Defects, in one list

- D6, D7, D8, D9 and D10 from walk 38: fixed, each seen live in both themes.
- **D11 (minor, not blocking, not new):** in dark, the conversation's scroll bar and Under the
  hood's draw light (#FAFAFA track, #C2C2C2 thumb) where scroll bars always show.

Verdict: READY
