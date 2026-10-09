# The Codex review switch in the built app, in the test VM (2026-10-09)

**What it proves:** the row round 20.2 draws, "Let Codex review your team's work", in the built app
on a clean macOS guest with no Codex: below Technical view between two rules, the switch off and
unavailable (dashed track, hollow knob), "Reviewing now: Claude" with the ⓘ; pressing the switch
shakes it and opens the tooltip with the not-installed words; Esc puts away only the tooltip.
His words, ruling §114 (2026-10-09): *"in our app, we should give the user a toggle/switch to
manually enable that."*

**The app:** an ad-hoc signed development build of this branch, `1.2.0-dev.7712d6fab` (the guest's
Updates row reads "RichOS 1.2.0-dev.7712d6fab is up to date"), built by
`richos/app/scripts/package-app.sh` under `richos/engine/scripts/lib/native-work.py`. Engine:
nightly 47's `richos-engine-1.2.0.tar.gz`. Home: an empty folder (a first run). Never on the host's
screen (CEO ruling §65).

```
cd richos/app/scripts/testvm
TESTVM_AX_TIMEOUT=60 ./run-walk.py --wait 900 --bundle RichOS-dev-7712d6fab.zip --home <empty dir> \
  --engine <nightly 47>/richos-engine-1.2.0.tar.gz --report <out>/run.json -- \
  ./steps-walk.py --steps docs/verification/2026-10-09-codex-review-switch-walk/steps/walk.json --out <out>/steps
```

**Walk `walk-0ab0166fb55e`**, steps 0 to 32 of [`steps/walk.json`](steps/walk.json), every one exit 0
(steps-walk.py's own record of each step, its exit status and output, is kept outside the repository
with the walk's scratch):

| Step | What the app did | Picture |
|---|---|---|
| 0 | the guest has no `/Applications/ChatGPT.app`, no `~/Applications/ChatGPT.app`, no `codex` on PATH | |
| 2-16 | first run: "Not now", company "Walk Test Co" with its folder, Settings opened | |
| 18-20 | the row is in Settings below Technical view: switch off, dashed and hollow; "Reviewing now: Claude" and the ⓘ | [`02-settings-not-installed.jpg`](02-settings-not-installed.jpg) |
| 21-24 | a pointer press on the switch (1485,331): the tooltip opens with "The Codex app isn't on this Mac. Install it and sign in to ChatGPT, and this switch can be turned on." (found in the accessibility tree, step 24) | [`03-not-installed-nudge.jpg`](03-not-installed-nudge.jpg) |
| 25-27 | Esc: the tooltip goes, the Settings menu stays open | [`04-esc-put-away-only-the-tooltip.jpg`](04-esc-put-away-only-the-tooltip.jpg) |
| 28-32 | a stand-in Codex CLI put where the app looks (answers `login status` as a signed-in codex-cli does), Settings reopened | |

**Stopped at step 32 by the lead**, who needed the guest's memory for another agent's walk; the
remaining steps (the first-run off state with Codex ready, its ⓘ words in light and dark) were
never run. That state's words, behavior and contrast in both themes are proven in WebKit by
`richos/app/ui/tests/codex-reviews.js`. run-walk.py's cleanup ran: "clean: app quit, VM stopped,
clone deleted, state removed"; the guest slot was released after 187 s.

**An earlier walk, `walk-7c47c7c05568` (bundle `d2a31b72a`),** stopped at step 21: a click by title
matched both the row and its switch. Its accessibility tree also showed the ⓘ, the name and the
status line as `enabled=no` in the not-installed state, because the row put `aria-disabled` on its
name block (round 20.2's markup does the same); fixed in `25eb1bc35` (only the switch says
aria-disabled), and in this walk's tree the ⓘ is pressable.

**Privacy:** `richos/app/scripts/qa/ocr-gate.sh` over the three frames: 0 of 3 carry anything that
must not ship (its positive control found the known address first).
