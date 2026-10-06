# Walk of nightly candidate 38 (`v1.2.0-nightly.20261005.38`), 2026-10-05/06

**Verdict: NOT READY.** What the CEO asked for works on this candidate, seen live with one real
Claude account in light and dark. Both Output buttons, top and bottom, carry the thread's count and
open the panel. The panel lists every file the thread wrote, grouped by turn and newest first,
including a worker's files at their landed path. The left sidebar toggles away and back, and it
stays hidden across a relaunch. The panel pulls to a felt stop, then opens completely, and the
conversation comes back with one click. The background job with a worker gets its Approve on its
row, runs the command, passes review and lands, with no "stopped" refusal.

Two defects in the new panel are visible the way he will use it, and I hold the nightly for them:

- **D6:** a file that is gone still looks present. Its actions stay lit, and its own view contradicts
  itself, until something else makes the panel read its list again.
- **D7:** opening "Under the hood", where every Approve lives, leaves the Output panel open
  underneath. Two right-hand panes then overlap, and the Output panel's head is cut mid-word.

Three more defects (D8 to D10) are listed below. None of them holds the nightly by itself.

## Scope

The brief: walk only what changed since my READY walk of candidate 37 (source `d052d5af7`).
`git log --oneline d052d5af7..ed13a8c76 -- richos/app/ui richos/app/src-tauri richos/app/crates | wc -l`
gives 74 commits, merges included. The shipped changes are:
- the Output side panel S1 to S9: `output.rs`, `output_files.rs`, `output-panel.js`, `timeline.js`,
  `style.css`, `index.html`, `main.js`, `nav.rs`, `theme-boot.js`, `attachments.js` and `mac_attachments.rs`;
- a worker's approval on its job's row (`permissions.rs`);
- the job-stop fixes (`work_host.rs`, `machinery.rs`);
- the shell that never scrolls (`ed13a8c76`).

**The brief's premise "everything else has not changed" is not quite true.** Two quota commits are
in the range. `c04d4ff4f` places the ruler's "now" from the measured stamps, which is my walk-37
D5 fixed. `ab89c3b09` changes the quota gate's wording for a revoked grant. Neither was walked to
a verdict; see "Not walked".

## Verification mode

- Environment: the test VM, one fresh guest per run through `run-walk.py`, never this Mac's screen.
  One app window per guest, no two-user test. Guest screen 1680x1050 at 1x, app window 1400x864.
  Light and dark were switched live through the guest's macOS appearance. The app follows the system
  on a fresh install.
- Artifact: the candidate's own signed bundle,
  `~/.richos-nightly/releases/v1.2.0-nightly.20261005.38/RichOS-1.2.0-nightly.20261005.38-macos-aarch64.zip`,
  with the same folder's `richos-engine-1.2.0.tar.gz` as `--engine`.
- One real account: the host's Claude Code 2.1.289, synced into each guest by `claude-sync.sh`.

### Identity, checked before any claim: PASS

- `shasum -a 256` of the zip: `ed896022bdba091cec442d6532279926fa9563bdcf874852c98aae9f02d18404`.
  This equals its `SHA256SUMS` line and the `files` entry in `candidate.json`.
- `candidate.json` `info`: `source_commit` `ed13a8c762f7e9e6372c66ff73177ee22d59ca83`, `run_id`
  `20261005T221826Z-64af5b49`, `version` `1.2.0-nightly.20261005.38`, `build_commit` `647b6d2a0172…`.
  `nightly-local.py candidate --run 20261005T221826Z-64af5b49` printed the same source and bundle.
  The walk workspace was at `ed13a8c76` (`git rev-parse HEAD`).
- `git diff --stat ed13a8c76 647b6d2a0` shows that the build commit changes only `nightly-build.json`,
  `Cargo.toml`, `Cargo.lock` and `tauri.conf.json`.
- The running app's log line "this app: built from 647b6d2a0…" was checked in every run's identity
  step. The first attempt (B0) asked for `ed13a8c76` and was refused at this step, which is correct:
  the app names the build commit, not the source. Every later run asked for `647b6d2a0`.
- The app's Settings menu read "RichOS 1.2.0-nightly.20261005.38 is up to date." (run H,
  `ax.sh find --value 1.2.0-nightly --contains`; frame `h-settings-light`).

### Runs

Every run reports `execution: completed` and `cleanup_complete: true`. The two guest slots were used
side by side.

| Run | VM | What | Exit | Seconds |
|---|---|---|---|---|
| B0 | `walk-23f9aea5bfe3` | worker-approve, identity asked for the source SHA: refused at identity | 1 | 29 |
| A | `walk-509664f0663f` | `output-walk.py` identity, first-run, connect, tools, empty, backend-worker, panel, md-view, previews, csv, save-copy, attach, buttons, link, actions, wrote, theme-flash, pull, sidebar | 1 | 2746 |
| B | `walk-bd11b2368180` | `worker-approve-walk.py --settle 1200` | 0 | 357 |
| C | `walk-5e90860518c2` | panel, previews, csv, actions, theme-flash (A's csv, actions and theme-flash were spoiled by the walk; see below) | 1 | 1015 |
| D | `walk-5db57cfa5c69` | panel, previews, wrote, sidebar (with a relaunch) | 0 | 560 |
| E | `walk-aa69ae40e1f5` | panel, csv, missing, backend-worker, overlap | 1 | 1616 |
| F | `walk-2c935e693bbf` | panel, menus (both menus open, in both themes) | 0 | 284 |
| G | `walk-6e63fd2a3d73` | panel, csv, missing (before and after the app is told) | 1 | 759 |
| H | `walk-eaaab46f1a9c` | `steps-walk.py` with the step list in `walkH-steps.jsonl`: Settings version line, the quota panel | 0 | 107 |

**What the walk itself caused, kept apart from the app's defects:**
- A `panel`: the step waits for "1 file from this thread". I ran it after `backend-worker`, so the
  button already said 10 files. It is not an app defect. C, D, E, F and G ran it first, and it PASSED there.
- A `csv`: the Approve search outlived ax.sh's 20 s on a long conversation. The step now gives it 35 s
  and records the failures. C's `csv` PASSED.
- A `actions`: the step closed Finder's window with an Apple Event. The guest grants none, so the
  consent prompt held the call. Open, Open with and Show in Finder had already PASSED. The step no
  longer does that, and C's `actions` PASSED. Finder stayed in front for A's `wrote` frames. Its
  checks read the accessibility tree, so they stand, and D repeated them with clean frames.
- A `sidebar`: `CommandWalk.relaunch` presses the thread in the rail, which is not there while the
  sidebar is hidden. The step now comes back through the home screen's "Talk to Rich", and D's
  `sidebar` PASSED.
- E `backend-worker`: E's thread had a loose `panel-check.md` in Acme. `integrate` refused with
  "integration preserves local edits; reconcile the dirty checkout first", and Rich asked the user
  what to do with the file, a clear three-option question. That is correct behavior, and the order
  of my steps caused it. A's `backend-worker` (worker first) and B landed.

### Toolkit

Used: `richos/app/scripts/` at the candidate source `ed13a8c76` plus this branch's commits.
- `testvm/`: `run-walk.py --wait`, `output-walk.py`, `worker-approve-walk.py`, `steps-walk.py`,
  `ax.sh` (find, click, `--nth`, AppleScript), `pointer-drag.sh` (drags and `--right`), `guest.sh`
  (`--push`, `--pull`), `shot.sh`, `relaunch.py` and `slots.py status`.
- `qa/`: `timeline.py capture --wait-only` (run inside the guest), `contrast.py` (regions, `--box`,
  `--nontext`), `frame.py` (`motion`, `extent`, `crop`, `px`), `ocr-gate.sh`, `redact.py --homes`
  and `wait-for.sh --log`.
- `nightly-local.py candidate --run`.

Scripts written from scratch: none. `walkH-steps.jsonl` (one line, a JSON array) is a step list, which is data for
`steps-walk.py`. The toolkit was extended, each change committed on this branch with its proof:
- `ax.js`: a `find` also returns `help` (AXHelp, where WebKit puts a control's `title`). This is
  how a disabled action's reason was read.
- `pointer-drag.sh --right`: a real right-click. Covered by `test/pointer-drag.test.js`, and the
  testvm suite gives 165 passed, 0 failed.
- `redact.py --homes`: covers the guest's `/Users/admin/...`, the gate's home-path shape. It comes
  with the fixture `home-control.png` and cases R9 to R12. `qa.test.sh` gives all 226 passed.
- `worker-approve-walk.py --settle`: watches the job to its review and land.
- `output-walk.py`: the candidate steps `empty`, `csv`, `buttons`, `link`, `actions`, `missing`,
  `menus`, `overlap`, `wrote`, `theme-flash` and `sidebar`, plus the message-field check in `pull`.

The last change to `missing` (reading the gone file from the panel's head count) has not run on the
VM yet. G's frames show what it reads.

### Frames

The frames are JPEG q80 of the 1680x1050 PNG originals, and every number below was measured on the
PNG. `ocr-gate.sh` ran with its positive control over all 51 source frames. It flagged 11 frames for
the guest's own home path (`/Users/admin/testvm/…`) in attachment lines and work receipts.
`redact.py --homes --pad 4` covered each one and re-read it as clean. The final set read
"0 of 51 frame(s) carry something that must not ship". `runs.jsonl` holds every run's
`run-walk.py` report, its step report and each step's observations, one file per line. It has the
operator's home path replaced by `~/`, and no address-shaped string is left in it.

## 2. The Output panel

### The buttons: PASS
- With nothing written, both Output buttons are named "Output — nothing produced yet in this thread"
  (A `empty`: 2 found). The panel's head reads "Nothing produced yet", and the empty sentence is
  "Nothing in **Running** has produced a file yet. …" (`a-empty-light`, `a-empty-dark`).
- With 10 files, there are exactly two buttons, both named "Output — 10 files from this thread":
  the top one at y 112 and the bottom one at y 878. Each was pressed by its own index, and each
  opened the panel on "10 files from this thread" (A `buttons`; `a-buttons-top`, `a-buttons-bottom`).
- At the stop, the bottom button folds to its glyph and count, and the top one stays beside the
  breadcrumb (`a-pull-stop`).

### The list: PASS
- All 10 recorded files are rows (A `buttons`). They are grouped by turn and newest first: the
  attach-check turn, then the csv turn, the three preview files, panel-check, and then the worker's
  turn (`a-buttons-bottom`). Each group is headed by his words and the time.
- The worker's files `notes.md` and `notes.zip` are listed once each at `~/Acme/`, "by
  worker-sonnet-a889931f6a0e". The record holds a command row from the worktree and a land row
  at Acme for each, and the worktree copy is folded into the landed entry. Both read back in Acme:
  "Notes for the walk test." and a zip header.
- The reviewer's scratch `regen.zip` and `committed.zip` in `/private/tmp/rv_chk/` are listed too,
  "by reviewer-sonnet-…". That is the PRD's Q3 default ("list everything"), which is still the
  CEO's open question. It is not a defect.

### The links: PASS
With the panel closed, the conversation's `attach-check.md` link opened the panel on that file's own
view: "attach-check.md · 1 of 10", its heading and its text (A `link`; `a-link-opened`).

### Previews: PASS
- Markdown renders with its heading, and the facts line reads "6 words · Markdown" (`a-md-view-*`).
- PNG and PDF previews: the PDF draws its page (`a-preview-png-light`, `a-preview-pdf-dark`).
- CSV: a table "walk-table.csv, the first rows" with region/units, North 12 and South 7 (C;
  `c-preview-csv-*`). See D9 for its facts line.
- Preview | Source: Source shows the file's text "# Panel check / One written file." in a monospace
  block, and Preview brings the heading back. Both directions were seen in both themes (C;
  `c-md-source-*`, `c-md-preview-again`).

### Actions: PASS, except a gone file's (D6)
- Open, the row's own button: Preview opened a window "preview-page.png" (A; `a-actions-open`).
- Open with, the file view's ▾: it offers Open in Preview, ColorSync Utility, QuickTime Player and
  Safari, then Show in Finder and Save a copy…. ColorSync Utility opened the file
  (`a-actions-open-with`).
- Show in Finder, from the row's ⋯: a Finder window "Acme" opened with `preview-page.png` selected
  (`a-actions-show-in-finder`).
- Save a copy…, from the row's ⋯: the sheet on the app's window offered "panel-check.md". The walk
  gave it its own name, and the sheet pointed at Documents. Exactly one copy exists, in Documents,
  and its bytes are the recorded file's (A `save-copy`; `a-save-copy-sheet`, `a-save-copy-saved`).
- Copy path, from a real right-click on the row: the context menu opened at the row with Preview,
  Open, Show in Finder, Save a copy…, Copy path and Add to chat. The clipboard then held the recorded
  path exactly (C; `c-actions-right-click`).
- Copy path, from the file view's ⋯: the same path (C; `c-actions-file-view-menu`).
- Add to chat, from the row's ⋯: the chip "Remove attach-check.md" appeared. Rich's next turn lists
  the file under "Attached on this Mac (1 file, saved by RichOS)", the conversation's attachments
  folder holds a byte-identical copy, and Rich answered "heron-4127", the code word in the file
  (A `attach`; `a-attach-chip`, `a-attach-sent`).
- Disabled actions on a gone file: see **D6**. After the app has been told that the file is gone,
  every action gives the right reason; before that, none does.

### The sidebar toggle: PASS
- Its button hides the rail, which is 300 px wide. The conversation takes the room: its centered
  column moved 150 px left, half the rail (D; `d-sidebar-hidden-light`, `d-sidebar-hidden-dark`).
- ⌘⇧S, sent to the app's own pid while it was frontmost, toggled it both ways (D, A).
- Hidden, then the app was relaunched (`relaunch.py`). It came back to the home screen, and "Talk to
  Rich" led to the conversation with the sidebar still hidden ("Show the sidebar" present). Its
  button brought the sidebar back (D; `d-sidebar-relaunch-home`, `d-sidebar-after-relaunch`,
  `d-sidebar-shown-again`).

### The wide pull: PASS
These are real mouse drags (A `pull`), and the stop is computed independently: rail right edge
440 + 360 = 800.
- Dragged 50 px past the stop and let go: the divider held at 801 (`a-pull-stop`).
- Dragged 180 px past it: the panel opened completely, with the divider at 441 and "‹ Running" at
  its head (`a-pull-full`).
- The pill took the panel back to the stop at 801.
- With the sidebar hidden, dragged past the new stop: the panel took the whole window, divider at
  141. The floating message field and Send stay at hand (`a-pull-everything`).
- Close brought the whole conversation back (`a-pull-closed`).
- Sidebar back and the panel reopened: at the split width (divider 801, value 740), not open
  completely (`a-pull-reopened`).
- **The message field stays one line:** 45 px tall at the stop (186 px wide) and 45 px with the
  panel closed (414 px wide).

### Theme switch with the panel open: PASS
`timeline.py capture --wait-only` ran inside the guest on the panel's rectangle (1141,94 343x560)
while the appearance flipped. It took 181 frames at a 41.7 ms median gap (C `theme-flash`).
`frame.py motion` over every consecutive pair finds exactly one changed pair, 0071 to 0072, with
99.87% of pixels changed. No frame falls between the two themes. Every text measured in both
frames meets AA (table below; `c-theme-flash-0071-light`, `c-theme-flash-0072-dark`).

### The app frame never scrolls: PASS
I pressed every "Wrote N files" in the conversation: five in A (4, 1, 3, 1 and 1 files) and two in
D. Each opened the panel. Measured from the accessibility tree after each press: the header's
sidebar toggle moved 0 px, the message field's bottom moved 0 px, and the panel's Close sat 4 px
from the toggle's level (A, D `wrote`; `d-wrote-1`, `d-wrote-2`).

### Readability: PASS
- **14 px floor.**
  - From the code: `style.css` sets every Output panel text at 1rem (16 px) or 1.0625rem, except the
    "OUTPUT" eyebrow and the kind tile (MD, CSV), which are 0.875rem (14 px). The root font size is
    16 px at the default font scale.
  - Live: the ink height of "OUTPUT" (all capitals) is 11 px, and the kind tile "CSV" is 11 px. The
    17 px title is 13 px (`frame.py extent` on C frame 0071). That is consistent with 14 px type.
  - Nothing readable in the panel is smaller.
- **Contrast** (`qa/contrast.py`, its one estimator). Normal text must reach 4.5:1 and non-text 3:1.

| Surface (frame) | Light | Dark |
|---|---|---|
| Head: eyebrow, title, subtitle (`c-theme-flash-*`) | 5.90, 14.90, 5.83 | 6.07, 14.93, 6.56 |
| Group head: his words, time | 5.83, 5.90 | 6.56, 6.07 |
| Row: name, folder, kind tile, "by worker-…" (`a-buttons-bottom`, flash frames) | 14.90, 4.99, 5.98, 4.99 | 14.93, 6.18, 6.51, not measured |
| Output button: label, count on gold (inside the badge's fill) | 17.02, 4.72 | 13.02, 7.68 |
| File view: subtitle, "All output · 5", "1 of 5", Open on gold, Preview (on), Source (off), path, heading, body, facts (`a-md-view-*`) | 5.83, 5.83, 5.83, 4.72, 4.72, 6.15, 5.83, 14.90, 14.90, 5.83/4.99 | 6.56, 6.56, 6.56, 7.68, 7.68, 6.09, 6.56, 14.93, 14.93, 6.56/6.18 |
| Empty state: head, subtitle, sentence (`a-empty-*`) | 14.90, 5.83, 5.83 | 14.93, 6.56, 6.56 |
| CSV: header, cells, facts, "The whole sheet opens in TextEdit" (`c-preview-csv-*`) | 5.98, 17.02, 5.83/4.99, 4.99 | 6.51, 13.02, 6.56/6.18, 6.18 |
| Conversation: "Wrote 1 file", "Produced", file link | 5.83, 5.90, 14.90 | 7.68, 5.91, 14.55 |
| Row menu: title, items (`f-menu-row-*`) | 6.33, 15.74 to 18.07 | 5.78, 9.74 to 12.06 |
| File view menu: items (`f-menu-file-*`) | 15.74 to 18.07 | 9.74 to 12.06 |
| Menu focus ring, non-text (`f-menu-row-dark`) | not measured | 5.14 |

- The lowest figure measured is 4.72:1: dark text on the gold Open and count, in light.
- "Not measured" cells use the same tokens as the measured cell beside them.
- Declared exemption, WCAG 1.4.3 "inactive user interface component": the grayed items of a gone
  file's menu (`g-missing-b-row-menu`) are disabled controls and were not judged against 4.5:1.
- Method note: a region must stay inside a badge's fill. A region that took in the button's
  rounded corners read the cream background as the "text" and gave 3.60:1. The tight region
  1082,124..1106,139 reads the navy numerals on gold at 4.72:1.

## 3. A background job with a worker: PASS

Run B, `worker-approve-walk.py --settle 1200`:
- The worker's commands, and the reviewer's, asked for approval while the job was `running`.
  "Approve this" appeared on its row in Under the hood, and the walk pressed it six times, once per
  command (`b-approve`).
- The worker's `pandoc … --pdf-engine=…typst` ran: a PostToolUse with its agent id. It was raised
  after the lead's turn had ended, which is the case the fix is about.
- The job settled: "It landed on main in Acme. An independent review passed it first." and
  "Everything it produced is with your saved work." `notes.pdf` is in the Acme folder
  (`b-settled`). Neither the detail nor the notices say "stopped".
- A's git-archive worker job also settled and landed (above).

## Defects

**D6 (moderate, blocking): a file that is gone still looks present, and its actions are lit, until
something else makes the panel read its list again.** Seen in C, E and G.
- Steps (G): `walk-table.csv` was recorded. The `missing` step then ran `rm -f` on its recorded
  path in the guest; `test -f` read yes just before and no just after. The panel was closed and
  opened again.
- What the user sees:
  - The row still reads "walk-table.csv ~/Acme/", and the head still says "2 files from this thread".
  - Its ⋯ menu offers Open in TextEdit, Open with…, Show in Finder, Save a copy… and Add to chat,
    all enabled with no reason (`g-missing-1-list-stale`).
  - Its own view contradicts itself: "Written today 12:27 AM · 30 bytes", the gold "Open in
    TextEdit" lit, and below them "This file is no longer where it was written. …"
    (`g-missing-a-file-view`).
- Only when the user presses Open does the app learn (`g-missing-b-after-open`). From then on:
  - the row is dimmed and reads "No longer where it was written";
  - the head says "2 files from this thread · 1 no longer where it was written";
  - Open, Show in Finder, Save a copy… and Add to chat are disabled, each with the exact §6.7
    sentence as its reason (read as AXHelp);
  - Copy path stays on (`g-missing-b-row-menu`).
- Expected: PRD §4.6, "Every read re-stats … `exists` … never cached across calls", and §6.7 for
  the disabled actions.
- Cause (hypothesis from the code):
  - `output-panel.js` `open()` renders the list it already holds and never calls `load()`. Only a
    `rich://output` arrival, a thread switch or an action whose answer is the missing sentence
    (line 1631) reloads the list.
  - The file view's own preview answer ("missing") does not reload it either.
- Why it matters to him: the reviewers' `/private/tmp` scratch files and anything he moves in Finder
  will look present until he tries one.

**D7 (moderate, blocking): two right-hand panes at once. "Under the hood" opens over an open Output
panel instead of replacing it.** Seen in A, by accident while approving, and on purpose in E.
- Steps (E `overlap`): open the Output panel, then press the chip "… 2 saved work records" (Open the
  work summary).
- What the user sees: "Under the hood" slides in, and the Output panel stays open beneath it. Its
  head shows "OUTPU", "6 files f", "Everythi" and partial rows. Its Close is still in the tree, but
  under the slide-over (`e-overlap-light`, `e-overlap-dark`, `a-attach-sent`). With the panel
  closed, the same slide-over also covers half of the bottom Output button (`b-approve`).
- Expected: PRD §6.1, "One right-hand pane at a time: opening the Output panel closes the worker
  inspector and vice versa … the same courtesy both ways".
- Cause (hypothesis from the code): `main.js` `openSlideOver()` closes the worker inspector but not
  the Output panel. `openWorkerInspector()` does close it, and the Output panel's `onOpen` closes
  the slide-over, so only this one direction is missing.
- Why blocking: Approve lives in Under the hood. He will meet this every time he approves a job
  with the panel open.

**D8 (minor to moderate, not blocking by itself): a card says "This turn was still running the last
time RichOS was open, and I can't tell you how it ended." while RichOS was never closed.** Seen in E
(`e-overlap-light`).
- The background job had stopped at a question, and that question's turn in the conversation is
  followed by this card. E made no relaunch, and ax.sh, which addresses the app by the pid run.sh
  recorded at launch, still reached that process at E's last step.
- The card is drawn for a turn whose state is unknown (`timeline.js` `renderUnknownCard`).
- Not known whether it is new in this candidate. It sits in the job and question path that
  `work_host.rs` changed in this range.
- Expected: a turn that ended at a question is not reported as cut off by a restart.

**D9 (minor, not blocking): the CSV view's facts line ends a line with a lone "·".** At the split
width it reads "2 rows · Comma-separated ·", with "The whole sheet opens in TextEdit" on the next
line (`c-preview-csv-*`). Cause (from the code): `factsLine` puts each separator in its own span
inside a wrapping flex row, so a separator stays behind when the next part wraps. The same happens
to every kind with a "whole … opens in" part (xlsx, docx, pptx).

**D10 (minor, not blocking): in dark, the Output list's scroll track, and the conversation's, is
drawn light (#FAFAFA track, #C2C2C2 thumb)** (`a-preview-pdf-dark`, `a-md-view-dark`).
- The guest always shows scroll bars. With a trackpad's overlay scroll bars this may never show on
  his Mac, which is a hypothesis.
- No `color-scheme` is declared for these scroll areas. The only one in `style.css` is at line 6129.
- The conversation's track is not new in this range. The panel's is new with the panel.

Observations, not defects:
- Run B's "Produced 4 files" strip reads "notes.pdf notes.md notes.pdf notes.md" (`b-settled`). Two
  of those are the reviewer's copies in `/private/tmp`, listed by the Q3 default. In the panel each
  row shows its folder, but the conversation's strip shows names only, so the same name appears twice.
- A gone file keeps Preview lit (its view says where the file is not). The code does that on
  purpose (`output-panel.js` line 1478). PRD §4.6 lists Preview among the disabled actions. That is
  a difference in wording, for the PRD's owner to settle.
- After D's relaunch, the end-of-turn report cards ("I ran it in your Acme folder …") were not in
  the conversation (`d-sidebar-after-relaunch`). Nothing in this range's `timeline.js` or `main.js`
  diff touches them. It was not judged, and not compared with candidate 37.
- `integrate` refuses to land while an untracked file sits in the target folder, and Rich then asks
  a clear question (E). That is a policy, not a defect.

## Not walked, and why

- **Walk 37's D5 fix (`c04d4ff4f`, the ruler's "now")**: not seen live. In H, Claude Code answered
  without usage figures ("No reading yet."), so no ruler was drawn (`h-quota-light`). The fix
  carries its own WebKit test over every whole percent from 0 to 99 on all three rulers, which I did
  not re-run.
- **The quota gate's revoked-grant wording (`ab89c3b09`)**: no job was ended early in these runs, so
  the refusal never arose.
- The record's witness steps that the S2 and S3 VM walks proved and this candidate does not change
  in shape: `pdf`, `front-desk-worker` and `open-reveal`. The list above shows the command witness
  and the worker witness live.
- Everything walk 37 passed whose code is unchanged: home, first run, attachments by drag, the
  Settings menu (apart from the version line read above), account connection, the quota panel's
  states and the company buttons.
- The two-account quota states (round 16 fixtures): their code is unchanged apart from the ruler
  placement above.

## Surfaces

- Applied and checked: the Mac desktop app from its signed bundle, on the first-run path; the
  returning path (relaunch, home screen); and light and dark.
- Every entrance named in the brief was used:
  - Output: the top button, the bottom button, a conversation link and "Wrote N files".
  - Actions: the row's own Open, the row's ⋯, right-click, the file view's ▾ and ⋯, and the path
    line's copy.
  - Sidebar: its button and ⌘⇧S. The pull: the divider and the pill.
  - Ways out: Close, Escape from a file view or a menu, "back to Rich" and the pill.
- Test data: each guest was a fresh clone with its own empty home. Nothing touched this Mac's app
  data.
- Not applicable:
  - phones and mobile clients: nothing touched;
  - battery: no `richos/mobile/**` change;
  - voice: no audio played;
  - the stable channel: this walk promotes nothing.

## Cleanup

- Every run ended with "clean: app quit, VM stopped, clone deleted, state removed" and released its
  slot.
- Afterward, `slots.py status` read `guest.lock: free` and `guest-2.lock: free`.
  `~/.richos-testvm/tart/vms/` holds only `richos-base`.
- Apps the walk opened inside guests (Preview, ColorSync Utility, Finder windows) went with the
  clones.
- `pgrep -l richos-tauri` on this Mac: none. No app was started here.
- The scratch directory `/Volumes/E1TB/tmp/claude/ray-opus-walk38/` was deleted before the report.

## Defects, in one list

- **D6 (moderate, blocking):** a gone file looks present and its actions stay lit until an action
  answers. Its view shows "Written … · 30 bytes" and a lit Open beside "no longer where it was written".
- **D7 (moderate, blocking):** opening Under the hood leaves the Output panel open beneath it, cut
  mid-word. This breaks §6.1 in one direction.
- **D8 (minor to moderate):** "This turn was still running the last time RichOS was open" is shown
  when RichOS never closed, after a background job stopped at a question.
- **D9 (minor):** the CSV facts line ends a line with a lone "·".
- **D10 (minor):** in dark, the Output list's scroll track draws light where scroll bars always show.

Verdict: NOT READY
