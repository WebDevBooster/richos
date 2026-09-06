# Follow-up to Urban's September 6 P6 signoff

Historical response. Urban independently verified these corrections and kept the
9/10 signoff at `9b6c74d` in P7. See [the P7 follow-up](URBAN-P7-RESPONSE.md).

Urban granted **9/10 signoff** to `e276ba3` in
`URBAN_SIGNOFF_2026-09-06_02.05.md`. He independently confirmed that the decision
question and Rust display projection passed the previous review. He also found
two remaining defects that needed correction before landing: history had no
persistent overflow cue and the attention marker lowered its parent's text
contrast floor. Both findings were valid.

This follow-up remains in the isolated `codex/durable-orchestration` worktree.
Urban's signoff applies to the revision he reviewed; the changes below have the
author's recorded checks, not an invented new design score.

## Changes against the ranked gaps

| Gap | Correction |
| --- | --- |
| 1: history silently clips receipts and Retry | History now uses the same `readingPanel()` as decisions and the picker. Overflow has persistent reading controls. The browser suite exercises six receipts and an eight-step imported plan in both themes at all five reviewed sizes. It scrolls until Retry passes a hit test, clicks it and checks the assignment/task identities. Escape returns focus to the history disclosure. |
| 2: attention text fell to a 3:1 floor | The attention paragraph and picker buttons no longer carry the indicator attribute. A separate empty span carries the visible border and the 3:1 indicator declaration. The words retain their 4.5:1 text floor. The shared contrast library's thresholds are unchanged. |
| 3: ambiguous spoken scrolling label | **Read more above** replaces **Read previous**, without changing the selected assignment. |
| 4: duplicate and ambiguous dismissal | The reading surface has one dismissal named **Back to conversation**. **Review decision** in the strip opens or focuses the decision; it never commits or dismisses it. The copy **Close decision** is gone. |
| 5: promise mislabeled as a check | Autonomous assignments say **What Rich agreed to deliver**. Imported plans retain **Completion checks** for their actual named checks. |
| 6: amendment mixes two voices | The display API carries earlier requests and accepted scopes as separate fields. History labels them **Your request** and **Rich agreed** in separate paragraphs, preserving line breaks. Journal contents do not change. |
| 7: receipts look like terminal output | Receipts use ordinary paragraphs in the body face, with their line breaks preserved. Explicit command diagnostics remain in Technical details. |
| 8: cue far from the cut | **Read more below** sits immediately below the scrolling content, at its cut edge, separated by a visible rule. The upward control remains at the upper edge. No fade covers receipt text. |
| 9: unknown formats expose the raw contract | Unrecognized autonomous display envelopes use **Saved assignment** and an explicit neutral description. Checks and command recipes are omitted from that projection. Existing result bytes remain saved and receive a neutral display line. The fallback never substitutes raw prompt/check bytes for display text. Imported plans keep their supplied human descriptions and checks. |
| 10: one numbered task repeats the title | A single task uses an unnumbered section. Its description is omitted from history when it exactly matches the displayed assignment goal. Distinct descriptions remain visible. |
| 11: almost no strip headroom | Review decision shares the action row with Pause and End. The viewport test now inserts another visible status line and requires the strip to remain below 30% at every reviewed size in both themes. |

## Tests that can reject these regressions

The current counts, commands and logs are in
[urban-p6-results.json](validation/owned-work/urban-p6-results.json).

The history test asserts nonempty rendered receipts and nonzero dimensions
before checking overflow. A separate negative control hides its reading cue and
requires the same check to fail. It does not claim success over an absent body.
The shared history contrast fixture now contains a receipt and must measure both
its check text and that receipt.

For each theme and for both the status paragraph and an attention row in the
picker, the contrast test chooses ink between 3:1 and 4.5:1 against the actual
opaque background. It requires a text failure at 4.5:1. Reintroducing the old
parent marker makes that matched control pass at 3:1, proving this tests the
specific regression Urban reported. Restoring the correct markup and making
only the empty mark indistinguishable from its background must then fail the
separate 3:1 indicator check. The unchanged surface must pass first and the mark
must appear in the walk's measured paths.

The Rust probe now renders four views: newly registered work, amended work, an
imported plan and a deliberately older-format journal. The last input is authored
independently of the current registrar, so a producer/parser agreement cannot hide
the fallback defect. It checks that the original journal bytes are unchanged.
All four serialized views also pass through the shipping renderer in the browser
suite. Three independently compiled mutations restore raw descriptions, raw
receipt prefixes or the unknown-format title. Each must fail its intended
assertion; compilation failure does not count.

The full contrast run initially rejected six assignment node-count floors.
Closed history contents are now absent from the DOM until opened, so the number
of considered nodes decreased. Those six considered-node floors were updated
from the measured failure output. Their measured-text floors were retained.
The expanded history floor was raised from measurement. No color threshold or
exemption changed and no debt was added. This is a documented change in rendered
content, not a missing surface accepted as green.

## Reproduce

```sh
node app/ui/tests/runs.js
node app/ui/tests/affordances.js
node app/ui/tests/contrast.js
node app/ui/tests/docs-claims.js
cargo test --manifest-path app/Cargo.toml -p richos-core --example run_view_probe
cargo check --manifest-path app/src-tauri/Cargo.toml
python3 app/scripts/test-assignment-projection-mutations.py /path/to/cargo
```

Run from the repository root. `RICHOS_PLAYWRIGHT` can select an existing WebKit
installation and `CARGO` can select Cargo for the browser's projection check.
Logs and narrow history screenshots accompany the result file. Updated assignment
screenshots remain in `ui/tests/shots-contrast/`.

## Limits

This changes display projection and the webview, not the controller's scheduling,
authorization or completion rules. The prior full core suite, desktop integration
harness and controller mutations remain historical evidence, not newly reported
runs here. Current native validation compiles the desktop and exercises the shared
projection through its Rust probe.

Browser command dispatch uses a scripted bridge. No new packaged-window, OS accent
or spoken-audio signoff is claimed. Unknown-format details remain unavailable in
this view, explicitly stated; the fallback is not a journal migration. Arbitrary
user or model prose is not rewritten to remove technical words. No merge,
deployment or background execution service is included.
