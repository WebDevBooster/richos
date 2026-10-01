# `scripts/qa/` — the walk toolkit

The helpers a QA walk needs, committed once, so that no walk writes them again.

## The rule

**A QA brief names the tool from this directory. A walker who needs a helper that
is not here ADDS it here and commits it — never a throwaway under the scratch
directory.**

That is the whole point. Across the eight walks of 2026-09-18 to 2026-09-20,
**111 helper scripts** were written from scratch: 6, 3, 20, 7, 22, 21, 20 and 12
per run. They were the same nine or ten jobs every time, and every rewrite was a
chance to get a measurement subtly different from the last run's.

The contrast calculation alone was written **ten times across five walks**, under
five different names, with **five different rules** for picking the text color out
of a region. They do not agree: on antialiased type the rules differ by more than
a full ratio point. So walk-to-walk contrast numbers have not been comparable,
against a threshold — 4.5:1 — whose entire value is that it is the same number
every time.

## The tools

Every one takes `--help`, exits non-zero with a sentence when it cannot answer,
and never prints a number it did not measure.

| Tool | The job |
|---|---|
| `contrast.py` | WCAG ratio of two colors, or of a region of a frame. One estimator, stated in the file, printed with every answer. |
| `frame.py` | Read the frame: `px`, `crop`, `extent`, `inset`, `box`, `edges`, `motion`. `inset` is the four-sided gap measurement behind the 18/18 settings-button check. |
| `ocr-gate.sh` | The privacy gate: no frame enters the record carrying an address, a home path or a listed person's name. Refuses to report clean until a positive control proves the reader works. |
| `redact.py` | Cover an address (found by OCR, tokens joined across a line), a phone-shaped digit run (`--phones`, the same shape `ocr-gate.sh` flags) or an exact rectangle, then **re-read the output** and fail if anything survived. |
| `ocr-find.sh` | Which of these frames shows this text? Exit 0 on a hit, **1 on none**. |
| `ocr-watch.sh` | Sample a region on an interval and read it out with timestamps — a countdown, a status line, a pane being paged through. |
| `timeline.py` | `capture` an action and its frames **on one clock**; `--also-region` adds a SECOND rectangle captured around the same press, into `<outdir>/b/`, carrying the same action instant — the Mac and the phone page answered off one clock. `report` the first repaint against the frame before the action; `at` dates a frame something else chose (the one `ocr-find.sh --first` named) off that same clock; `stats` for min/median/max over samples. |
| `wait-for.sh` | Wait for a git ref to move, a log line, a file to appear or be gone (`--gone`: a workspace another agent holds), a wall-clock instant, or a new process. **Exit 1 on timeout** — a wait that gives up is a failure. |
| `phone-client.mjs` | A headless phone: the **production** mobile client (`richos/mobile/core/client.js`) paired to a real install's phone listener. `pair` prints the six words and waits for the walker's `match`/`mismatch` in a decision file; `send` times acknowledgement, first and completed reply on one clock; `state`, `forget`; `foreign` presents this phone's credential to a DIFFERENT Mac and **exits 1 if that Mac accepts it**. No simulator, no physical phone. |
| `phone-android.py` | A **physical** Android phone, driven the way a person drives it and read the way the closure matrix needs: `tap`/`wait`/`gone`/`node`/`texts` by the words on screen, `swipe` a Recents card, `type-file` one `input text` per character, `keys` through the on-screen keyboard's own keys (a key map), `field` to read the editable text back, `unlabeled` for clickable controls a screen reader would announce without a name, `shot` and a timed `burst` of frames, `idle-frames` (frames and their rhythm while untouched), and a read-only `state` of what an app leaves running (process and birth, CPU ticks, services, wake locks, live microphone, jobs, alarms, sockets, its own notifications), with `compare` for two of them and `observe` for one whole closure-matrix cell (action, settle, two readings, comparison). Refuses an unnamed or unattached serial: `native-android/bin/emu-ui.py` is the emulator-only counterpart. |
| `lab-ledger.py` | Did each message reach the **isolated** test Mac exactly once, word for word, with one reply? Reads the lab's `timeline.json`, exits 1 on a missing, duplicated or altered message, and refuses a timeline without the isolated lab's owner marker. Prints counts, never the conversation. |
| `flake-rate.sh` | How often does a command fail? `--runs N LABEL 'COMMAND' [LABEL 'COMMAND' …]` runs every label once per round, interleaved, so a before/after pair sees the same host load; counts pass, fail and (with `--admit`) not-admitted; keeps and names only the failing logs. `--nice` is CEO §78's low-priority run on a busy Mac. |
| `under-load.py` | Run ONE command on a Mac carrying a known CPU load: `--workers N` one-core workers (default cores + 2, a load average above the core count, as with three nightly gates side by side), a `reserve.py` host sample before and after, the command's own exit status. Stops only the workers it started, and each worker also leaves when its stdin pipe closes, so a killed run leaves nothing spinning. Put it behind `../testvm/reserve.py --` so a busy Mac refuses it first; keep the command short. |
| `stall-run.py` | Run ONE command whose process group is repeatedly held stopped (`--run-ms R --stop-ms S`, default 1 ms running then 2,500 ms stopped) while its children in their own groups, and the wall clock, carry on: a test process descheduled on a busy Mac, made certain rather than likely. A check that decides by wall time fails under it; one whose clocks are only hang guards passes. The proof tool of the R9 fixes (`docs/verification/2026-09-29-load-sensitive-checks-audit.md`). Signals only the group it started, never after its own child has exited, and continues the group however it ends short of SIGKILL. |
| `busy-sample.py` | Run ONE command with every `../testvm/reserve.py` admission sample in it reading a given load (`--busy PERCENT`, default 100; memory pressure normal, no swap-out), adding no load at all. A check whose verdict follows the host sample changes with `--busy`; one that does not passes under any value. The companion of `stall-run.py` (which takes the CPU from the test process) and `under-load.py` (which loads the Mac, without making the reading land where a check decides). Works on every Python process in the command's tree started without `-S`/`-I`. |
| `phone-ios.py` | A physical iPhone through its real controls. iOS 26 has no shell on the phone, so a list of steps (launch, tap, type, Home, lock, shot, accessibility audit…) runs as one XCUITest check (`rios device verify script`) and every step comes back as one line on the phone's clock, with its shots. The list is validated here before anything is built. `appearance` reads and sets the phone's own light/dark (the app follows the phone; set it back), `orientation` turns the phone and reports the app window's size. A step may act `in` iOS Settings (the app's permissions, Wi-Fi; set back what you change) or Safari (the one share-sheet source, reached with `open` on an https link); `tree` and `shot` keep that app's window. `summary DIR` reads a finished run back: each step's outcome, time and audit issues, and each shot or tree by its name. `vocabulary` exits 1 when a step this tool validates has no case in the phone runner (`PhysicalDeviceTests.perform`), before a build finds it. `syslog-rate` counts one process's entries per time bucket of a `syslog` capture (what the app did while hidden). Committed, unchanged app source is never rebuilt or re-signed: the one signed build of that tree is reused from the shared store, so a walk starts in seconds, and no tool ever uninstalls the app or its runner. Before anything is built, `run` forecasts whether the phone will ask its owner to allow UI automation (`approval` prints the same) and refuses an expected-to-ask run until `--approval-announced` says the CEO was told. Also read-only `procs`, `apps`, `lock` and `battery`. |
| `pair-words.py` | The six pairing words under **pairing v2**, both sides: `mac` derives the isolated lab Mac's words from its own files (origin, CA, the key the phone registered; refused without the lab's owner marker), `phone` reads the words the phone showed from its PHONE_STEP log, `check` **exits 1 when any word differs**. The lab's `ready.json` still prints the v1 words, so going by it gives a false mismatch. Use with `phone-ios.py pair-steps --v2-hold S`: check during the hold, stop your run on anything but exit 0. |
| `fixtures/make-fixtures.py` | Regenerate the committed fixtures, or `--check` that they still match. |
| **guest screen and shell:** `../testvm/ax.sh`, `../testvm/guest.sh` | Not in this directory, and looked for here first every time. `ax.sh <vm> tree\|find\|click` is the guest's accessibility tree with real geometry and a press by title or description; `guest.sh <vm> <command>` is one word into the guest, with `--pull`/`--push`. They live beside the VM they need (`scripts/testvm/`, documented in `docs/testvm.md`); twenty-five throwaways were written before they existed. `../testvm/steps-walk.py <vm> --steps FILE.json --out DIR` runs a JSON list of those operations (`ax`, `shot`, `tree`, `guest`, `push`, `handfile`, `until`, `wait`) as one walk inside `run-walk.py`, recording every step; a walk's clicks are data, not a new script (added with the candidate 33 walk). |

`lib/qaimg.py` and `lib/qaocr.py` are the shared halves: one PNG reader (Pillow
when it imports, a built-in decoder when it does not — the candidate .11 walk
hand-rolled one in a heredoc because Pillow was missing), one luminance, one
ratio, one tesseract lookup.

## Two things that are not negotiable

**Nothing here photographs the operator's screen.** `timeline.py capture` and
`ocr-watch.sh` refuse unless they are running as the test VM's guest user or the
caller has set `RICHOS_QA_CAPTURE=allow` deliberately. His Mac is never a test
surface; the app under test lives in the VM (`scripts/testvm/`).

**The list of people is not in this repository and never will be.** `ocr-gate.sh`
owns the SHAPE patterns — address-shaped, `/Users/<name>`-shaped, phone-shaped —
and hands the OCR text to `engine/scripts/lib/named-persons.py` for the roster,
which lives at `~/.richos-privacy/named-persons`, outside every work tree. Five
walks each inlined their own half-remembered copy of that roster into a scratch
script; committing one here would publish it, which is worse than any of them.
`ABSENT` — no list on this machine — makes the gate exit 2, because "nothing was
checked" is not "nothing to check".

## Running the tests

    bash scripts/qa.test.sh

The suite lives at `scripts/qa.test.sh`, one level up, **on purpose**:
`run-tests.sh` builds its inventory with `find -maxdepth 1`, so a suite inside
this directory would run in no build and appear in no `--only` list — exactly how
`scripts/testvm/test/run-tests.sh` became invisible, as `proof-for.sh`'s own
comment records. 53 cases, about twelve seconds, no VM, no build, no window.

Roughly half the cases drive a tool into its refusal, because that is the failure
each one was built against: a wait that timed out and returned success, a gate
whose reader was blind, a redactor that never re-read its output, an estimator
that took a stray antialiasing pixel for the ink.

## Adding a tool

One job per file. `--help` that says what it does. A non-zero exit with a
sentence when it cannot answer. A case in `scripts/qa.test.sh` that proves both
the answer and the refusal. Add the row to the table above, and add the path to
this suite's `# run-tests: inputs` line if it lands outside `scripts/qa`.
