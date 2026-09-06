# Response to Urban's September 6 assignment-panel review

Urban withheld P5 approval at **7/10**, reviewing `b45145f` in
`URBAN_SIGNOFF_2026-09-06_00.29.md`. The rejection was justified. The previous
fixture could not expose the question-height defect and the history projected
execution instructions into a customer surface. This revision addresses the
eleven listed gaps in the isolated `codex/durable-orchestration` worktree.
Independent design approval is still outstanding.

## Corrections

| Review gap | Change |
| --- | --- |
| 1, 6: hidden question and oversized strip | A pending decision has an explicit **Review decision** control. The compact strip stays below 30% of the window at all five reviewed sizes. Opening it shows a separate reading panel above the strip. The question has no height cap. Its answers follow it in the same scrolling content, so answers cannot sit pinned beneath a cut question. Persistent **Read more below** and **Read previous** controls expose overflow without relying on macOS scrollbars. The reading panel fits the actual space above the strip. |
| 2: machine contract in history | `src-tauri/src/run_view.rs` projects the CEO's request as the description and Rich's accepted scope as completion expectations. Earlier instructions are displayed separately. Verification receipts also carried the entire check contract as a prefix; that prefix is removed in the projection. Execution prompts, checks and stored receipts retain their original bytes. Imported plans retain their own descriptions and check names. |
| 3: false classifications | The two JavaScript delimiter literals and their `NOT-RENDERED` annotations are removed. The remaining `NOT-RENDERED` assignment annotations added at `b45145f` describe isolated debug-harness strings. The nine additional `NOT-RENDERED` entries recovered with Echo's work were traced to private home-screen diagnostics or splash metadata, with no renderer. Backend display text is tested through the actual Rust projection as well as the JavaScript inventory. |
| 4: incomplete source inventory | Reused Echo's manifest from Git commits `94eff69` and `58ee862`. It derives HTML references, closes over runtime references and reconciles the result against files on disk and declared roles. State, label and status maps are extracted across every derived script, including `main.js` and `timeline.js`. Contrast source and stylesheet inventories use the same manifest. The stale comment is removed. |
| 5: grammar | The ordinary case says **1 needs you**. A selected decision does not repeat “Waiting for your decision” after that count. Other selected work retains its own progress alongside the portfolio count. |
| 7: internal references | Duplicate titles use creation dates first. A reference appears only if the displayed dates also collide or are unavailable. Exact internal identities still travel in commands. |
| 8: imported argv | Commands sit behind an explicit **Technical details** disclosure within history and display as quoted command lines instead of JSON arrays. |
| 9: empty state | The explanation of assigning work through Rich is visible immediately. The empty disclosure says **Import an assignment**. |
| 10: missing screenshots | All seven assignment screenshots are committed in `ui/tests/shots-contrast/`, alongside the existing surfaces. Narrow long-question screenshots are retained with this revision's evidence. |
| 11: long picker | The picker uses the same persistent reading controls as decisions. Twenty entries are reachable without discovering an invisible scrollbar. |
| Attention indicator | The border is declared as a contrast indicator and measured by the shared walk. |

The decision surface is an explicit disclosure, not a modal that blocks the
conversation. Escape closes it and restores focus. Only one assignment reading
surface is open at a time. Pause and End remain reachable while reading a
question or editing an answer. A resource allowance still authorizes only the
specified extra attempts and time. Business options and written answers keep
their existing confirmation and exact question binding.

## What proves the fixes

The current results and exact commands are in
[urban-p5-results.json](validation/owned-work/urban-p5-results.json).
Logs named `urban-p5-*.log` are retained in the same directory.

- The real-shell suite uses Urban's long question and explanation at 1400×900,
  1280×800, 1024×768, 760×720 and 520×680 in both themes. It also uses an eightfold
  question with twelve choices. It measures strip size, reading-panel bounds,
  natural question height, answer ordering, persistent cues and stop-control hit
  tests. The same question guard rejects the old 15vh cap and a missing cue.
- `run_view_probe` uses the production registration function, planner and
  controller with a scripted host. It runs a real verification tick, then invokes
  the exact Tauri projection module. The webview suite builds this probe and
  renders its serialized initial, amended and imported assignments. No copied
  JavaScript contract fixture substitutes for that boundary. The probe checks
  that display projection does not mutate the execution snapshot and that prior
  prohibitions survive amendments.
- The projection mutation script first compiles and runs an unchanged baseline.
  It then separately restores raw task descriptions and raw receipt prefixes.
  Both compile and fail the intended assertions. A compiler error is a harness
  failure, never a successful mutation result.
- The source gate starts from a clean disposable copy. New `updates.js` prose,
  a short `home.js` state and an unwired file each fail by name. Existing
  reconciliation checks also reject missing and stale roles.
- The shared contrast gate retains its defining-node assertions and all seven
  assignment surfaces. The decision surface must measure the actual question.
  Floors were raised from measured node counts; none was lowered and no contrast
  debt or exemption was added.

The manifest is recovered code, not a new competing implementation. Applicable
classifications, source checks and six update/home fixtures were integrated.
Echo's separate update-busy production feature is absent from this branch, so its
two waiting fixtures and the behavioral check requiring that feature were not
imported. No claim is made that this revision implements or validates that
separate feature. This avoids carrying annotations about states the branch
cannot render.

## Reproduce

From the repository root, with Cargo and the repository's WebKit installation:

```sh
cargo test --manifest-path app/Cargo.toml -p richos-core
cargo test --manifest-path app/Cargo.toml -p richos-core --example run_view_probe
cargo check --manifest-path app/src-tauri/Cargo.toml
python3 app/scripts/test-assignment-projection-mutations.py /path/to/cargo
node app/ui/tests/runs.js
node app/ui/tests/affordances.js
node app/ui/tests/contrast.js
node app/ui/tests/docs-claims.js
```

`RICHOS_PLAYWRIGHT` can select an existing Playwright installation. The panel
suite uses `CARGO`, or the standard `~/.cargo/bin/cargo`, to build its projection
probe. The Rust mutation test needs the dependencies cached for offline builds.

## Boundaries

These changes do not alter controller scheduling, authorization or durable
completion semantics. This revision reruns the core suite and desktop compile
check. The previous desktop integration and twenty controller-mutation results
remain historical evidence; they are not reported as new runs here.

The browser measurements use WebKit and a scripted command bridge. This is not a
new visual signoff of the packaged Tauri window, OS accent behavior or spoken
presentation. Model wording, very large portfolios beyond twenty entries and
real provider behavior remain production-validation boundaries. User text may
itself contain technical terms; the projection removes the host's known framing,
not arbitrary words from user content. The app must remain open for work to run.
No background service, merge or deployment is included.
