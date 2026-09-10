# packaging-ci: from seven consecutive reds and nine days of nothing, to green on a push

**2026-09-10.** Two workflows were red and unowned. `packaging-ci` here in `richos`, and
`windows-companion-ci` in the private `richos-hq`. Neither had a cause anyone had looked at,
and the second had been red on `main` for thirteen days. This is what was measured and what
was done about it. Every command below can be re-run; every number is the output of one.

## The one-line answer for each

| workflow | the real cause | the kind of thing it was | fixed by |
|---|---|---|---|
| `richos` `packaging-ci` | the runner image ships no `cargo-tauri` (2 suites); a suite that could only pass on the operator's own machine (1 suite); a fixture that needs a compiler no public runner can hold (1 suite) | runner environment, then a defect in a TEST, then one genuinely structural gap | a pinned CLI, a fixed suite, and one declared gap the harness cannot let rot |
| `richos` `packaging-ci`, the second defect | it had not RUN in nine days: `push`/`pull_request` removed from the file **and** `disabled_manually` at the Actions API | a state nobody could see, because a workflow's state is not in git | triggers restored, setting set back to `active` |
| `richos-hq` `windows-companion-ci` | the three `.csproj` files it builds left the repository on 2026-08-28 | a gate that stayed behind when the code moved | removed; the same gate lives, green and stronger, in `richos` where the code is |

**None of the three was the product being broken.** That is worth saying plainly, because a
workflow left red long enough stops being read as information at all, and this one had a
different kind of cause in each of its four failing suites.

## packaging-ci — how it was stopped twice over

`gh run list --workflow packaging-ci.yml` (`raw/run-history.txt`) shows the last run of any
kind as `33459952385`, 2026-09-01, and the seven runs before it all red. Nine days of silence
followed, and it took two independent fixes to end because there were two independent causes:

1. **In the file.** `2ba051b7`, 2026-09-04, removed `push` and `pull_request`, leaving
   `workflow_dispatch` alone. Deliberate, argued at length in the file's own header.
2. **In the repository settings.** It was `disabled_manually` at the Actions API — the last of
   the five switched off over the 2026-09-01 billing block never switched back on after the
   repository went public and Actions became free. Every other workflow: `active`.

**The second silently voided the first one's escape hatch.** The header said `workflow_dispatch`
was kept "so the gate can be demanded on a named SHA the day the blocker clears". It could not
be — a disabled workflow refuses a dispatch too:

    $ gh workflow run packaging-ci.yml --ref main
    could not create workflow dispatch event: HTTP 422: Cannot trigger a 'workflow_dispatch'
    on a disabled workflow

Both states, and that refusal, are in `raw/workflow-states.txt`. **A workflow's state is not in
git**, so it cannot be diffed, reviewed or noticed — which is exactly how this one survived a
re-enable pass that its own README describes.

## What was actually red — run `34444955517`

The setting was set back to `active` and the gate was demanded on `main` at `8bec9050` with no
changes at all, so the baseline is the tree as it stood. **8 suites, 4 red, 2m46s.** Full
transcript: `raw/baseline-red-run-34444955517.txt`.

    === app/scripts: 4 of 8 suite(s) FAILED: gui-boot.test.sh make-release.test.sh
        package-app.test.sh updater-setup.test.sh ===

**`updater-setup.test.sh` and `package-app.test.sh` B2 — a runner-environment defect.**

    updater-setup.test.sh: could not generate a test key (is the Tauri CLI installed?)
    FAIL  B2 ... exit 3, wanted 2. Output: error: the Tauri CLI is not installed for this cargo.

The image ships Rust and no `cargo-tauri`. The job now installs it — **not** with
`cargo install tauri-cli --version '^2'`, which compiles a large crate from source on every run
for a binary upstream publishes, and lets "whatever `^2` resolves to today" decide what the gate
tests. Version pinned to **2.11.4**, the one every document here reasons about, downloaded as
the published archive and refused unless its SHA-256 matches a digest recorded in the workflow.
The architecture is read from `uname -m`, both digests are pinned, and an unrecognized machine
is refused rather than guessed at.

**`make-release.test.sh` R6-R9 — a defect in the SUITE, not in the script.**

    FAIL  R6 app with no pin refuses
           exit 2 as wanted, but the output never said 'no pin at'

The right exit code from the wrong refusal, which is the confusion `expect`'s needle exists to
catch — and it caught it. `cmd_app` runs the named-person gate first, and that gate refuses
when the operator's private deny-list is absent, which it is on every machine but one. Those
four cases had never passed anywhere else. The suite now puts the gate into a known state with
a fixture list (a `sha256:` entry — a hashed window, so it names nobody and matches nothing),
and the absent case becomes **R5a**, which asserts the gate's precedence on purpose. 10 cases
became 11.

**`gui-boot.test.sh` — the one genuinely structural gap.** Its fixture copies the loro
compiler, `bin/loro-context.mjs` and `bin/loro-write.mjs`, which are not tracked in this
repository at all. No public runner can ever hold them. The suite says so itself and exits 2 —
"a fact about THIS MACHINE, not a verdict about the code" — and `run-tests.sh` had no notion of
such a host, so it called that a failed suite.

## The gap is declared, and the declaration cannot rot

That single structural gap was the reason **all eight** suites were switched off. The release
path — the thing that is wrong for weeks before anybody finds out — went ungated for nine days
to protect the reporting of one suite.

The obvious fix, "treat exit 2 as a skip", is how a suite stops running and nobody finds out;
this repository has shipped that defect five times under a reassuring fraction. So the
allowance is conditional, and every condition points at red:

- a gap counts only if the caller **declared it by name with a reason** — a bare name is refused;
- an **undeclared** gap is refused, so a suite that newly starts saying "I cannot answer here"
  stops the build on its first run;
- a declaration whose suite **did** answer is refused, so an allowance cannot outlive its reason;
- a suite that ran and **lost** still outranks everything;
- the summary can no longer say "all N suites passed" while a gap exists.

`app/scripts/run-tests.test.sh` executes all seven of those claims against a copy of the harness
on every run. **Negative control** (`raw/run-tests-negative-control.txt`): the same seven cases
run against `run-tests.sh` as it stood before the allowance existed —

    4 FAILED, 3 passed
    H1 exit 1, wanted 2   H2 exit 1, wanted 0   H3 exit 1, wanted 2   H4 exit 0, wanted 2
    H5, H6, H7 pass against BOTH

— so the four new cases bite, and the three describing untouched behavior are proven not to have
moved.

## The green run — `34446378461`

Triggered by **`push`**, not by a dispatch, which is the half of the fix that says the workflow
genuinely runs again. Branch `zach-opus-red1`, SHA `41182815`, 6m54s. Transcript:
`raw/green-run-34446378461.txt`.

    tauri-cli 2.11.4
    9 suite(s) discovered under /Users/runner/work/richos/richos/app/scripts
      declared host gap: gui-boot.test.sh — the boot fixture copies the loro compiler ...

    === frontend-payload tests: all 8 passed ===
    === make-engine-asset tests: all 18 passed ===
    === make-release.test.sh: all 11 passed ===
    === package-app tests: all 25 passed ===
    === rebuild-survival tests: all 17 passed ===
    === run-tests tests: all 7 passed ===
    === signing-setup tests: all 28 passed ===
    === updater-setup.test.sh: all 33 passed ===

    === app/scripts: 8 of 9 suites passed — 147 checks — 1 could not run on this host: gui-boot.test.sh ===

Before: 8 suites, 4 red, 0 useful verdicts, and nothing running anyway. After: **147 checks on
the release path, on every push that touches it.**

`gui-boot.test.sh` also got 84 seconds cheaper per run and its 8 log-accounting checks now
report before it stops. It used to build `richos-tauri` cold and *then* discover the host had no
compiler — 98 s in the baseline (`06:23:20` to `06:24:58`), 14 s in the green run (`06:42:16` to
`06:42:30`), same verdict. The free question now comes first.

## The Windows workflow was a different problem entirely

`richos-hq` held one workflow and it was this one. Its last run, `33175073438` on 2026-08-28,
failed at `Restore` with three of

    MSBUILD : error MSB1009: Project file does not exist.

one per `.csproj` it names (`raw/richos-hq-orphan.txt`). Not Windows, not the toolchain:
`Setup .NET 8` succeeded and the projects simply were not there. `50946b06` — "remove app/,
engine/ and tools/ — the public repo owns the product code" — had deleted
`tools/richos-service/companion-windows/` in that very push, merged as `a8f04533` at
`13:22:06Z` with the run starting four seconds later. The run before it, 2026-08-24, was green
with `Total tests: 26, Passed: 26`.

Its trigger paths were that directory and the workflow file, so **the strip was the last event
that could ever start it**: a red cross frozen on `main` for thirteen days that no commit could
clear. It was removed, with the account left at `.github/workflows/README.md` in that
repository. Nothing was lost — `richos` carries the same gate, pinned by SHA, with a
`doctor` smoke step the deleted copy never had, and it is green here on this branch too:

| run | ref | result |
|---|---|---|
| `34446415551` | `zach-opus-red1`, dispatch | success, 81 s |
| `33901290800` | `main` | success |

## The rule each of these leaves behind

- **A workflow that has not RUN is not a passing workflow, and its state lives in two places.**
  Check both. The file's triggers are in the diff; the API state is not, so it needs a command:
  `gh api repos/<owner>/<repo>/actions/workflows --jq '.workflows[] | "\(.state)\t\(.name)"'`.
- **A workflow belongs in the repository that holds the code it compiles.** A tree that moves
  takes its gate with it in the same change.
- **`--log-failed` is a trap on both of these.** It tails out into `actions/checkout` post-job
  cleanup and a Node 20 deprecation notice on a job whose real failure is hundreds of lines
  earlier. `gh run view <id> --json jobs` gives the per-step conclusions to aim at instead. The
  transcripts here are trimmed to end at the verdict for the same reason.
