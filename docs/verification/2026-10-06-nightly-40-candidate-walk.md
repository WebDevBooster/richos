# Walk of nightly candidate 40 (`v1.2.0-nightly.20261006.40`), 2026-10-06

**Verdict: NOT READY.** One new defect blocks it, D12: the candidate's own label change makes the
rail's initials spill out of their circle. Everything else this candidate changed works.

- **The CEO's decision on temporary files holds.** He chose: "Hide temporary-folder files … the
  panel lists only files written into your projects and folders". After a real back-end job whose
  reviewer left a copy in `/private/tmp`, both Output buttons read "3 files" and the panel lists
  `notes.zip` once.
  - A project's own `.claude/agents/walk-agent.md` is listed and counted.
  - A `.claude/worktrees/` copy is hidden.
  - No file link anywhere names the reviewer's temporary file.
- **Walk 39's D11 is fixed:** in dark, the conversation's scroll bar and Under the hood's are now
  dark, as the Output panel's already was.
- **Four of the five labels raised from 11 px to 14 px are 14 px, and they clear 4.5:1 in both
  themes.** These are the rail's company label, the overview's section title, the search result
  group and the initials. The fifth, the worker inspector's label, was not reached (see "Not
  walked").
- **D12 (new, blocking):** at 14 px, two wide capitals ("MW") are as wide as the 26 px circle and
  stick out past its edge. In dark, the part outside the circle sits on the rail's ground at
  1.04:1, so a stroke of the letter disappears.

## Scope

This walk is the second half of the walk `ray-opus-walk40` started. An API error (529) ended that
run at 09:14Z. Its seven runs, A to G, are used here as evidence, and I added one run, H.

Candidate 39's source was `d31271b9a`; candidate 40's is `c2ec7bec0`.
`git log --oneline --first-parent d31271b9a..c2ec7bec0` lists four merges. Three of them ship in the
app:
- `d88f4f02b` (`echo-sonnet-polish1`):
  - `color-scheme` is now declared on `:root`, so every scroller follows the theme (walk 39 D11);
  - five labels go from `0.6875rem` to `0.875rem`: `.rail-initials`, `.nav-group-label`,
    `.entity-block-title`, `.result-group` and `.insp-label`.
- `0f3111a43` (`echo-sonnet-tmpfilter2`): the Output list, its counts and its links leave out the
  scratch set.
  - The scratch set is defined in `output.rs` `SCRATCH_PREFIXES` and `SCRATCH_DIR_NAMES`.
  - The record keeps every row. `output_file` reads the unfiltered list.
- `a7251ce5d` is walk 39's own record. `c2ec7bec0` changes only the walk's own proof selection.

`git diff --stat d31271b9a c2ec7bec0 -- richos/app/ui richos/app/src-tauri richos/app/crates` names
`style.css`, `output.rs`, `main.rs` and `output_files.rs`. Everything else it lists is under
`ui/tests/`.

## Verification mode

- Environment: the test VM, one fresh guest per run through `run-walk.py`, never this Mac's screen.
  - One app window per guest, and no two-user test.
  - Guest screen 1680x1050 at 1x. The app window is 1400x864 at 140,77.
  - The guest shows scroll bars always.
  - Light and dark were switched live through the guest's macOS appearance.
- Artifact: the candidate's own signed bundle,
  `~/.richos-nightly/releases/v1.2.0-nightly.20261006.40/RichOS-1.2.0-nightly.20261006.40-macos-aarch64.zip`,
  with the same folder's `richos-engine-1.2.0.tar.gz` as `--engine`.
- One real account: the host's Claude Code 2.1.290, synced into each guest (`claude: host 2.1.290
  guest 2.1.290` in every run log).

### Identity, checked before any claim: PASS

- `shasum -a 256` of the zip gives `ef4fa6045aa56aa80e047bf273aa338658e2c4a8627d3a205a9e5db8c2576109`.
  That equals both of its lines in `SHA256SUMS` (the versioned name and `RichOS-macos-aarch64.zip`).
- `candidate.json` `info` reads:
  - `source_commit` `c2ec7bec0b798730bc8e05172e40f81adfb3fbbb`;
  - `run_id` `20261006T071544Z-d9f2a649`;
  - `version` `1.2.0-nightly.20261006.40`;
  - `build_commit` `c489b5933f57351e9baa157ed2f4abd0e1aad312`.
- **The app reports its build commit.** The build commit's parent is `c2ec7bec0`, and
  `git diff --stat c2ec7bec0 c489b5933` changes only `nightly-build.json`, `Cargo.toml`,
  `Cargo.lock` and `tauri.conf.json`.
  - Every run's `identity` step was given `--expect-sha c489b5933`.
  - All eight runs, A to H, read `built_from: c489b5933f57351e9baa157ed2f4abd0e1aad312` from the
    running app.
- The Settings menu read "RichOS 1.2.0-nightly.20261006.40 is up to date." in light and in dark
  (run E, step `labels`; frames `e-labels-settings-light`, `e-labels-settings-dark`).

### Runs

Every run reported `execution: completed` and `cleanup_complete: true`.

| Run | VM | Steps that ran | Result | Seconds |
|---|---|---|---|---|
| A | `walk-588e50ca56b6` | identity, first-run, connect, panel, backend-worker, scratch, overlap, scroll | overlap and scroll PASS; backend-worker and scratch FAIL (walk) | 859 |
| B | `walk-84f043ae847b` | identity, first-run, connect, front-desk-worker, labels | labels FAIL (walk) | 264 |
| C | `walk-d21ba7898a56` | identity, first-run, connect, backend-worker, labels | labels FAIL (walk) | 397 |
| D | `walk-f20b6f118bcd` | identity, first-run, connect, panel, backend-worker, scratch, labels | scratch and labels FAIL (walk) | 569 |
| E | `walk-70878a11adec` | identity, first-run, connect, panel, backend-worker, scratch, labels | labels PASS; backend-worker and scratch FAIL (walk) | 1264 |
| F | `walk-c0da4ca5e27a` | identity, first-run, connect, backend-worker, scratch | scratch FAIL (walk) | 317 |
| G | `walk-cc28852ef5be` | identity, first-run, connect, backend-worker, scratch | backend-worker and scratch FAIL (check) | 475 |
| H | `walk-c35132fa747c` | identity, first-run, connect, backend-worker, scratch | all PASS, exit 0 | 473 |

Runs A to G ran `ray-opus-walk40`'s `output-walk.py` as it stood during that run. That is
`68043ec19`, with the uncommitted work that `df4a5ac41` later saved. Run H ran this branch's
`b0cd8765f`.

**Every failure in A to G, read from its log and its observations. None of them is the app's:**

- **A, backend-worker:** `ax.sh find --title Approve…` reached its guest deadline (exit 124,
  `guest_deadline`). A's scratch then failed on `cp: …/Acme/notes.zip: No such file`:
  `notes.zip` was not in the Acme folder when the step ran, and that version of the step copied
  only from there. These are walk-step setup failures.
- **B, labels:** this was the step's first version.
  - It found no `AXButton` named "No name is set": the footer is an `AXPopUpButton`.
  - It looked for the overview's title as `AXHeading`: it is a static text.
  - It needed a worker chip that the front desk never drew. B's own front-desk turn ended with
    "I won't start that one myself. I'm set up to take requests and hand them over, not to run
    the work directly". No Agent-tool callback was made, and no `direct.md` was written.

  Walk-step setup, as the brief says.
- **C, labels:** the step clicked the footer at its center and then found no "Your name" field
  (`notfound`). That is walk-step setup. E pressed the same footer by its name and reached the
  field.
- **D, scratch:** "the Output button should count 4 files, it says … 3 files". The step had
  appended its cloned rows to the record behind the app's back. Such a write announces nothing,
  so the app never recounted. That is walk-step setup: G and H write the listed file with a typed
  shell command, which the app announces, and the count is right. D's labels then failed on the
  missing worker chip.
- **E, backend-worker:** "the Acme folder does not hold both files". Its assignment is `blocked`.
  The job asked about the `panel-check.md` that the panel step had left loose in Acme ("The
  panel-check file I made in your Acme folder earlier is stopping the new notes files from going
  in"; frame `e-labels-rail-light`). The app was doing its job by asking, so this is the walk's
  step order. E's scratch failed on the same missing file as A's.
- **F, scratch:** "no notes.zip on disk at any recorded path to copy". F's own backend-worker
  passed and read `~/Acme/notes.zip` back as a zip (`PK` header), so the file was there. The
  message is the step refusing to set up its clone. The file was uncommitted while A to G ran,
  so the evidence does not say which version F ran. G and H found the source and went on, G with
  the code `df4a5ac41` saved and H with this branch's. This is not the app.
- **G, scratch, "a file link names the job's own temporary file":** this is not a defect. The
  check asked the right question but answered it by the link's words. See "Temporary files"
  below. G's backend-worker failed for the same reason: its "listed once" counted the reviewer's
  `/private/tmp/rv1/o/notes.md` as a second listed `notes.md`. The app does not list that file.

### Toolkit

I used `richos/app/scripts/` on this branch (`b0cd8765f`, on top of the candidate source).
- `testvm/`: `run-walk.py --wait`, `output-walk.py`, `slots.py status`, and `ax.sh` through the
  walk script.
- `qa/`: `frame.py` (`px`, `edges`, `extent`, `crop --scale 8`), `contrast.py` (regions, colors and
  `--nontext`), `ocr-gate.sh`, `redact.py --homes --pad 4` and `wait-for.sh --log`.

**Scripts written from scratch: none.** I fixed the walk step in one commit on this branch:
- `b0cd8765f` `output-walk.py`:
  - `scratch_links` judges a link by where it opens. It presses each link outside the panel that
    carries a scratch file's name, reads the file view's ⋯ Copy path, and fails when that path
    is in the scratch set, or when the name belongs only to a scratch file.
  - `scratch_path()` mirrors the app's scratch set once, for both `scratch` and
    `backend-worker`.
  - Both Output buttons must carry the count.
  - Two offline cases in `output-walk.test.py`; `output-walk.test.sh` passes 11 of 11.
- `ray-opus-walk40`'s `df4a5ac41`, reviewed and kept as it is:
  - the clone's source is taken from the record;
  - the `.claude/agents` file is a real write, typed to Rich;
  - `labels` presses the rail footer by its name.

  Nothing in it was wrong, though it was incomplete: it still matched links by name, which my
  commit fixes.

### Frames

- The frames are JPEG q80 copies of the 1680x1050 PNG originals. Every number below was measured
  on the PNG.
- `ocr-gate.sh` ran with its positive control. It flagged 6 frames for the guest's home path
  (`/Users/admin/testvm/…`): `a-overlap-*` (Under the hood's receipts), `e-labels-entity-*` and
  `e-labels-settings-*` (the overview's "Source root" line).
- `redact.py --homes --pad 4` covered each and re-read it as clean. The final pass over all 18
  source frames read "0 of 18 frame(s) carry something that must not ship".
- `runs.jsonl` holds, one file per line: each run's `run-walk.py` report, its step report, and the
  observations this record relies on. The operator's home is `~` and each guest's home is
  `<guest-home>`.

## Temporary files (the CEO's decision, PRD §13 Q3): PASS

**Run H, steps `backend-worker` and `scratch`** (frame `h-scratch-panel`):
- **A real job left a temporary copy.** The back-end job's reviewer, `reviewer-sonnet-c1879fff5921`,
  wrote `/private/tmp/rev-fresh.zip`, and the record holds its row.
  - The record also holds the walk's two cloned rows: `/private/tmp/rv-zip-a1/notes.zip` and
    `~/Acme/.claude/worktrees/agent-walk/notes.zip`.
  - It also holds the typed write `~/Acme/.claude/agents/walk-agent.md`. The record stays whole.
- **The count:** both Output buttons read "Output — 3 files from this thread". The three are
  `notes.md`, `notes.zip` and `walk-agent.md`.
- **The list:** the panel head reads "3 files from this thread".
  - `notes.zip` is one row: its nodes sit at y 370, 393 and 393, within one row's height, and
    the row reads "~/Acme/ by worker-sonnet-…".
  - `walk-agent.md` is listed, reading "~/Acme/.claude/agents/".
  - No node in the panel names `rv-zip-a1` or `agent-walk`.
- **The links:** no button anywhere in the window is named `rev-fresh.zip`. In walk 39, run B's
  "Produced 3 files" strip still linked a reviewer's `rev-notes-fresh.zip`; that link is gone.
- `backend-worker` lists `notes.md` and `notes.zip` once each, at the Acme path. Its new
  `recorded_not_listed` field holds `/private/tmp/rev-fresh.zip`.

**Run G** (frame `g-scratch-panel`) shows the same thing with a harder case. The reviewer left
`/private/tmp/rv1/o/notes.md`, `/private/tmp/rv1/o/notes.zip` and `/private/tmp/rv1/x.zip`.
- Both buttons read 3 files.
- `notes.zip` is one row (y 370, 393, 393), and `walk-agent.md` is listed.
- No panel node names a scratch folder.

**G's link failure is the check's, not the app's.** It caught six buttons, each by its name alone:
- four are the panel's own rows and their Open actions, "notes.md ~/Acme/ by worker-…" and
  "notes.zip ~/Acme/ by worker-…";
- two are "notes.md" and "notes.zip" at y 90, above the visible conversation: the back-end turn's
  Produced strip.

Hypothesis from code: the strip draws `forTurn()`, and every conversation link resolves through
`links.forText`. Both read `state.list.files`, the filtered list (`output-panel.js`), so a link
can only name a listed file. G's own evidence agrees: `x.zip`, whose name only a scratch file has,
has no link anywhere. The strip shows `notes.md` once and `notes.zip` once, not twice.

**So: is a link to a temporary file a defect against his decision, or a check that asked for more
than he decided?** A link that opened a temporary file would contradict his decision. The
temporary file would then be presented as something written into his projects. So the check's
question is right. Its method was wrong: a landed file and the reviewer's copy share a name.
`b0cd8765f` now presses such a link and reads where it opens. In H the reviewer's file had its own
name and no link carried it, so that press path did not run on screen. It is covered by its
offline case.

## D11, every scroll bar in dark: FIXED

Run A, steps `scroll` and `overlap` (frames `a-scroll-*`, `a-overlap-*`). Measured with
`frame.py edges --col` and `frame.py px`:

| Surface | Theme | Track | Thumb |
|---|---|---|---|
| Conversation (x 1132) | Dark | #1A212E (the speckled ground shows through) | #686D77 (y 634..779) |
| Output panel (x 1532) | Dark | #181E28 | #5E6269 |
| Under the hood (x 1512) | Dark | #1F283E (y 702..879) | #636B7D (y 166..701) |
| Conversation | Light | #FAFAFA | #C4C4C4 |
| Under the hood | Light | #FAFAFA | #C4C4C4 |

Walk 39 measured #FAFAFA tracks and #C2C2C2 thumbs on the conversation and on Under the hood in
dark. All three are now dark in dark, and light is unchanged.

**Declared exemption, WCAG 1.4.11:** a scroll bar's look is set by the user agent, and the app
only declares `color-scheme`. So it is not held to 3:1. Its figures, for the record
(`contrast.py --nontext`, thumb on track): conversation dark 3.11:1, Under the hood dark 2.75:1,
panel dark 2.73:1, light 1.67:1. These are macOS's own scroller colors.

## The 14 px labels

Run E, step `labels` (frames `e-labels-*`). E set the name "Mona Wells" (`OUTPUT_WALK_NAME`), so
the initials are "MW", two of the widest capitals. Cap height comes from `frame.py extent` on the
ink. A 14 px label's capitals are 10 to 11 px tall here; an 11 px label's would be about 8 px.
Ratios come from `contrast.py` regions, normal text, 4.5:1.

| Label (frame) | Cap height | Light | Dark |
|---|---|---|---|
| Rail initials "MW" (`e-labels-rail-*`) | 10 px | 4.64:1 inside the circle | 6.84:1 inside the circle; **1.04:1 outside it (D12)** |
| Rail company label "ACME" (`e-labels-entity-*`) | 10 px | 5.83:1 | 6.62:1 |
| Overview section title "THREADS" (`e-labels-entity-*`) | 11 px | 4.99:1 | 6.18:1 |
| Search result group "ACME" (`e-labels-search-*`) | 10 to 11 px | 5.37:1 | 5.51:1 |
| Worker inspector "Latest update" | not reached | — | — |

The name beside the initials is 5.72:1 in light and 5.27:1 in dark.

**A weakness in the walk step, not in the app:** for the search group, E's `labels` recorded the
node at y 220, which is the typed query "Acme" in the search field. The group header "ACME" is at
y 272..282, and I measured it there on the frame.

## Defects

**D12 (new in this candidate, blocking): wide initials spill out of the rail's circle, and in dark
part of a letter disappears.**
- Where: the rail's foot, once a name is set, in both themes, on every screen.
- Steps: set the name "Mona Wells" in the rail footer's popover ("Your name"), then press Return.
- Expected: the initials sit inside the gold circle with room around them, in both themes.
- Actual, measured on `e-labels-rail-light.png` with `frame.py edges --row` (crops
  `e-initials-light-x8`, `e-initials-dark-x8`):
  - at the letters' middle (y 910) the circle spans x 162..187 (26 px), and the ink of "MW"
    spans x 163..188;
  - at the letters' top (y 905 and 906) the circle's gold ends at x 186, and the W's right
    stroke is drawn at x 187..188, outside the circle;
  - in dark, those two columns are the rail's ground: #0E1421 ink on #0A0F1B, **1.04:1**. The
    M's left stroke also meets the circle's edge with no gold beside it.
- For comparison, run D's "WT" (`d-initials-*-x8`): ink x 164..185, which fits with about 1 px to
  spare. Narrow initials fit; two wide capitals do not.
- Cause (from the code): `d88f4f02b` raised `.rail-initials` from `0.6875rem` to `0.875rem`,
  with `letter-spacing: 0.04em` and weight 600. The circle stayed `26px` by `26px`.
- Why it blocks: it is the candidate's own change, and it breaks the contrast floor on a glyph of
  text meant to be read.

Observations, not defects:
- **Under the hood lies over the right side of the conversation.** The question card's right
  edge and the bottom Output button run under it (`a-overlap-*`). Walk 39's `b-overlap-*` frames
  show the same, so this is older than this range. The code names the pane an overlay.
- **The worker inspector's label is not reachable by this walk.** A worker chip is drawn only for
  a front-desk Agent-tool worker, and the front desk declines to start one (run B's turn, above).

## Not walked, and why

- **The worker inspector's "Latest update" label (`.insp-label`):** no chip to open (see above).
  It is the same one-line size change as the other four. Its 14 px is a hypothesis from the code.
- **The temporary-file filter in dark:** the change is which rows are listed, not how they are
  drawn. The panel's dark rendering is walk 39's, measured there.
- **A link whose name a landed file shares, pressed on screen:** H's reviewer named its file
  `rev-fresh.zip`, so no such link existed. G had two, judged above from the code and G's own
  evidence. A model's choice of file name cannot be forced.
- **Walk 39's other surfaces:** no app file they depend on changed in this range, apart from the
  `color-scheme` change measured above.

## Surfaces

- Applied and checked:
  - the Mac desktop app from its signed bundle, on the first-run path;
  - light and dark for the scroll bars and the labels;
  - every place a scratch file could appear: both Output buttons, the panel's list, the Produced
    strip and links anywhere in the window;
  - the record kept whole: `kept_in_record 2` and the reviewer's row present.
- Test data: each guest was a fresh clone with its own empty home. Nothing touched this Mac's app
  data.
- Not applicable:
  - phones: nothing touched;
  - battery: no `richos/mobile/**` change;
  - voice: no audio played;
  - the stable channel: this walk promotes nothing, and nothing was published.

## Cleanup

- Runs A to H each ended with "clean: app quit, VM stopped, clone deleted, state removed" and
  released their slot. H's log reads "slot released: guest.lock after 473s".
- Afterward, `slots.py status` read `guest.lock: free` and `guest-2.lock: free`.
  `~/.richos-testvm/tart/vms/` holds only `richos-base`.
- `pgrep -l richos-tauri` on this Mac lists the operator's own installed app
  (`~/Applications/RichOS.app`, started 07:48Z, before this walk). That app is not a walk
  instance, and I did not touch it. No app was started on this Mac.
- The scratch directories `/Volumes/E1TB/tmp/claude/ray-opus-walk40/` and
  `/Volumes/E1TB/tmp/claude/ray-opus-walk40b/` were deleted after this record was committed.

## Defects, in one list

- D11 from walk 39: fixed, measured live in dark on all three scroll areas.
- The temporary-file decision: holds. The count, the list, `.claude/agents` listed,
  `.claude/worktrees` hidden and no link to a reviewer's copy were each seen live in H, and again
  in G.
- **D12 (new, blocking):** wide initials ("MW") overflow the 26 px rail circle at 14 px; in dark,
  part of the W sits on the rail's ground at 1.04:1.

Verdict: NOT READY
