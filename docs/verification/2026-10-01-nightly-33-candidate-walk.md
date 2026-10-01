# Walk of nightly candidate 33 (`v1.2.0-nightly.20261001.33`), 2026-10-01

**Verdict: READY.** No defect in the candidate. Two defects in the walk tools were found and fixed on
the way (below); three items rest on committed tests, not a live walk, and the record says which.

## Verification mode

- Environment: the test VM (two guest slots, `run-walk.py`), a fresh clone per run, never this Mac's screen.
  Light and dark both walked, guest macOS appearance switched live (the app's Theme is "follow system").
- Artifact walked: the candidate's own bundle,
  `~/.richos-nightly/releases/v1.2.0-nightly.20261001.33/RichOS-1.2.0-nightly.20261001.33-macos-aarch64.zip`.
- Identity before any claim: zip sha256 `88cbe0528dde376b949fb5f664bae11e86ce8124423b8d60685d15821086aaec`
  equals its `SHA256SUMS` line; `candidate.json` `source_commit` is `9f34340c88a74cadc5fe8eebd66cb3f0c43f26dc`;
  the walk workspace was at that commit; the app's own Settings panel reads "RichOS 1.2.0-nightly.20261001.33 is up to date".
  The build commit `4dd1883e8` sits on `9f34340c8` and changes only `nightly-build.json`, `Cargo.toml`,
  `Cargo.lock` and `tauri.conf.json` (`git diff --stat`).
- Windows: one guest window per run; no two-user test (not applicable to this walk).
- Toolkit commands used (toolkit at `167ce6bcc`, plus the commit below): `qa/contrast.py` (region and two-color
  forms, `--nontext`, `--dump`), `qa/frame.py px`, `qa/ocr-gate.sh`, `qa/redact.py`, `qa/wait-for.sh`,
  `testvm/run-walk.py`, `testvm/ax.sh`, `testvm/shot.sh`, `testvm/hand-file.sh`, `testvm/guest.sh`,
  `testvm/reserve.py`, `operator-probes/run-probes.py`.
- Scripts written from scratch: one, `testvm/steps-walk.py` (a runner that takes a JSON list of the existing
  `ax.sh`, `shot.sh`, `hand-file.sh` and `guest.sh` operations). No existing helper did this. It is committed with
  a test (`testvm/test/steps-walk.test.py`, registered in `run-tests.sh`) and a row in `qa/README.md`.
  The four step lists are in `2026-10-01-nightly-33-candidate-walk/steps/` as data.

## Per item

### 1. His team in the app: operator probe walk, O2 (F3 and F6) - PASS, live

`run-probes.py --only O2 --engine-rev 9f34340c --walk-binary <operator_walk built from 9f34340c>`, real
`claude` 2.1.286 turns in a fresh guest, 60 s driver run, `driver_exit 0`, `summary.json`: `O2 PASS: F3 passed, F6 passed`.

- F3 (a lead's question that repeats a settled decision is refused with the ruling): the lead answered
  `O2-F3-REFUSED`, quoting the tool: "Nothing was recorded: these words ask him something his record has already
  ruled." and the ruling it cites (section 21, the two splash screens). The ruled question reached the outbox 0 times;
  the control message ("nothing to decide here") reached it once.
- F6 (a stop given to the wrong lead is executed once): `before: ALIVE`, `after: NOT-ALIVE`, one host log line
  `stop of o2-sonnet-b ... "stop o2-sonnet-b"` (exactly one), reply in 12.3 s.
- The first run of the same command, before the walk binary was built, printed `O2 NOT-RUN: no operator_walk binary was
  handed to the guest` with `driver_exit 0`. That is the harness reporting success over a probe that never ran; the
  result above is the second run. See "Not defects of the candidate, but worth a line".

F10 (an ask made once satisfies every lead in the same run): **no live probe exists** (O2 covers F3 and F6 only).
Basis: the owning suite `engine/scripts/hooks/ceo-asks.test.sh`, run in this workspace at `9f34340c`: 54/54 cases,
and 16/16 mutants proven load-bearing, including `any-app-run` (turns C5d red), `app-run-not-witnessed` (C5c) and
`run-start-asks-again` (C5g). Verification basis: **committed test run, not a live app walk.**

### 2. Voice: a reply containing a non-breaking space speaks - committed test, not live

`cargo test -p richos-voice --lib chunk`: 17 passed, including
`an_overlong_cut_after_a_multibyte_space_does_not_split_the_space` (the committed fixture for finding 40; its commit
records red on the parent with `assertion failed: self.is_char_boundary(end)` and green on the fix). No audio was
played: the Mac's speakers cannot stand in for a person, and a live voice walk was not part of what was changed.

### 3. Completion reports: a cut-off report write no longer blocks later reports - committed test, not live

`cargo test -p richos-core --lib operator_`: 214 passed, 0 failed, including the `operator_report` module (finding 44's
`an_interrupted_append_does_not_block_the_reports_after_it`) and
`a_question_in_a_report_s_words_goes_through_the_settled_by_his_words_check` (F3's unit). Verification basis:
committed test run.

### 4. Home and the core screens - PASS, live, both themes (frames under `2026-10-01-nightly-33-candidate-walk/`, JPEG q80 of the originals)

| Step (what I did) | What I saw | Frame |
|---|---|---|
| Cold start, empty home | "Where should I keep what you tell me?" with Set it up / Not now | `firstrun-light` |
| Not now, then the company dialog, typed "Walk Test Co", Add this company | Home opens: "Walk Test Co / Running", the "I don't know your business yet." card, Rich's greeting, composer enabled | `home-light`, `home-dark` |
| Pasted a PNG as a screenshot (`hand-file.sh paste`) | Chip "image.png, PNG image, 1.8 MB" with a remove control above the composer | `attach-paste` |
| Dragged a second PNG from the Desktop onto the composer (`hand-file.sh drag`) | Second chip "Screenshot board 12.png" beside the first | `attach-drag` |
| Opened Settings (gear) | Theme, Text size, Technical view, Splash screen, Company, Home screen "Company buttons...", Connected repositories, Account connection, Memory folder, Use Rich from your phone, Updates (version and "Check for updates"), Bust a bug | `settings-light`, `settings-dark` |
| Account connection | "Your Anthropic account is connected." with Close | `account-light` |
| Technical view toggle then Cancel | Dialog "Turn on the technical view" (three scopes); Cancel puts the switch back off | `techy-canceled` |
| Technical view, "Turn it on" | Pill "Technical view, everywhere"; the "Claude Code quota 3% used" row appears in Settings | `settings-techy-light`, `settings-techy-dark` |
| Opened Claude Code quota | Panel with Open Claude Usage, Refresh, automatic pause (off, 93%), explanations; see the note on the 429 below | `quota-light`, `quota-dark` |
| Company buttons... | Dialog "Company buttons on the home screen": per-company label field, Show checkbox, Done | `homebuttons-light`, `homebuttons-dark` |

Quota display: in the walk at 06:13Z the row in Settings read "Claude Code quota, 3% used" (light and dark frames).
In the walk at 06:18Z, after about a dozen fresh guests had signed in from the same account in 25 minutes, the panel
read "No current reading ... HTTP 429: Anthropic rate-limited the check". Refresh was disabled with "Next refresh
available in 10m" (the cooldown works: a disabled control with its reason shown). I caused that rate limit with my own
walks and did not reproduce it from a single guest.

**Contrast, computed, WCAG AA (`qa/contrast.py`, one estimator, printed with each answer).** Normal text needs 4.5:1,
non-text 3:1. The numbers are measured on the original 1680x1050 PNG frames (the committed JPEGs are for looking).

| Surface | Light | Dark |
|---|---|---|
| Settings title, Theme, Text size, Technical view labels | 18.07:1 | 12.06:1 |
| Settings "Checked ... ago" status line | 6.33:1 | 5.78:1 |
| Settings "Update server:" line (14 px class) | 5.37:1 | 5.51:1 |
| Company select text | 15.58:1 | 14.78:1 |
| Home card hint ("Not now means I'll stop offering") | 6.15:1 | 6.09:1 |
| Composer placeholder | n/m (caret in region) | 5.51:1 |
| Sidebar "Search", company label, "Set your name", "Rich" label | 5.83, 5.83, 4.99, 4.99:1 | 6.62, 6.62, 6.22, 6.11:1 |
| Quota panel: eyebrow, subtitle, "No current reading", headline, footnote, pause help, off card, weekly note, close | 7.16, 6.33, 6.33, 6.33, 6.33, 6.33, 6.33, 6.33, 6.33:1 | 4.90, 5.78, 5.78, 5.78, 5.78, 5.78, 5.78, 5.78, 5.78:1 |
| Quota panel notice banner, body | 15.74, 18.07:1 | 9.74, 12.06:1 |
| Company-buttons dialog: title, label, Show, body, note, Done | 18.07, 18.07, 18.07, 6.33, 6.33, 4.72:1 | 12.06, 12.06, 12.06, 5.78, 5.78, 7.68:1 |
| Company-buttons field value "1" (tight box) | 5.98:1 | 6.51:1 |
| Quota meter fill against the panel (non-text, 3:1) | 4.06:1 | 3.79:1 |

Every measured pair clears its floor; the lowest is 4.72:1 ("Done" label, light) against 4.5:1. Two measurements are
not given as numbers: the light composer placeholder (the caret sat in the region and set the estimate), and the
company-buttons field value measured over its whole field, which printed 1.00:1 because the single character is below
the estimator's coverage floor; the tight-box figures above are the answer. No exemption is claimed anywhere.

### 5. Everything else in `git log v1.2.0-nightly.20260929.32..9f34340c -- richos/app/ui richos/app/src-tauri richos/app/crates`

Walked or covered above: the first-run, home, settings, attachment, technical-view and quota screens (they sit under
`ui/` and `src-tauri` and carry the quota-cooldown, home.js, setup and techy test changes) and the operator and report
changes. **Judged not user-visible or not reachable in the VM, and skipped:** phone push, phone stream and receipt
fixes (no phone touched, no phone path in this run); model download, voice-off microphone release and the oversized
download stop (need a model download and a live microphone; covered by their commits' own tests); work-host and quit
bounds, spine/loro provenance, native provider-turn and checkpoint changes, replace-all spelling pass, the saved-work
newest-records view, npm prefix and settings-kept-not-reset fixes (internal behaviors with their own committed tests,
not walkable without a staged failure); the test-only commits (`efecd2638`, `f6827880e`, `33cdf1bd6`,
`a9ddff19b`, `274ad70b1`, `1f46a18fa`, `5197f3c51`, `f6a3a4dc2`, `a34d4637b`). "Skipped" here means "not walked by me
live", not "passed".

## Defects

**In the candidate: none found.**

Observations (not defects, no change requested):

1. The quota panel's notice reads "Claude Code returned quota data this version of RichOS could not read" while its
   footnote says the check was rate limited (HTTP 429). I saw both only under the 429 that my own repeated sign-ins caused,
   so I cannot say whether the notice's wording fits a plain rate limit. Worth one look by the owner of `quota.js`.
2. After declining the memory folder, the home status line first shows "Saved work unavailable"; it was gone once a
   file was attached. I could not tell from the screen whether that is by design.

## Defects in the walk tools, found and fixed here (committed)

1. `testvm/frame-probe.py` (the gate inside `shot.sh`) refused every real frame from this guest:
   `frame-probe: cannot measure the frame: unsupported BMP: 32 bits, compression 3`, so `shot.sh` exited 1 and no
   screenshot could be taken. Cause: `sips` writes a 32-bit BI_BITFIELDS bitmap for a frame with an alpha channel.
   Fix and test in commit `frame-probe: read a 32-bit BI_BITFIELDS bitmap...`: the new RGBA cases were red (3 of 3),
   then green; the black-frame refusal still holds (an all-black RGBA frame measures black).
2. `testvm/ax.js` `type` failed on every fresh guest: `typefailed - guest clipboard is not text; left unchanged`. An
   empty clipboard reads back as a non-string. Fix: an empty clipboard (`clipboardInfo()` empty) is safe to overwrite
   and restore; an image or file clipboard is still refused. Verification: red on a fresh guest (walk 2, step 3), green on
   the next fresh guest (`type verified=True`, every later run). No unit test: the JXA path needs a guest.
3. Why no check caught them: neither tool had a case built from the frame or the clipboard a fresh guest actually
   produces (the frame-probe cases used RGB PNGs; `ax.js` was only tested on pure matching). The RGBA cases now exist;
   the clipboard case needs a guest and rests on the live proof above.

## Not defects of the candidate, but worth a line

`run-probes.py` exits 0 and prints a result block when a probe came back `NOT-RUN`. Anyone reading the exit code alone
would take a probe that never ran for a pass. I read `results/summary.json` instead. Suggested for the owner of the
probe runner: exit non-zero when any selected probe is `NOT-RUN`.

## Surfaces

Applied and checked: the Mac desktop app, first-run and returning (company set) paths, light and dark, the entrances to
attachments (paste and drag; menus and keyboard attach paths not walked), the entrances to the technical view (toggle,
confirm and cancel; the reverse transition after "Turn it on" - switching it off again - was not walked), Settings
reached by the gear only (keyboard shortcut not walked). Not applicable: the phone and the mobile clients (nothing
touched), battery (no `richos/mobile/**` change), the stable channel (not promoted by this walk).

## Cleanup

Each of the twelve VM runs (two probe runs, ten app walks) ended with `clean: app quit, VM stopped, clone deleted, state removed` and its slot released
(run logs in the scratch directory, then deleted). No app was left running. Scratch under
`/Volumes/E1TB/tmp/claude/ray-sonnet-walk33b/` deleted before the final report.
