# Follow-up to Urban's September 6 P7 review

Urban kept the **9/10 signoff** at `9b6c74d` in
`URBAN_SIGNOFF_2026-09-06_03.00.md`. He independently closed all eleven P6
corrections and found no regressions. The remaining findings concerned the
history's hierarchy, action cues and one boundary missing from the contrast gate.
This follow-up addresses those findings in the isolated
`codex/durable-orchestration` worktree.

Urban's signoff covers the commit he reviewed. The changes below have the author's
recorded checks and do not claim another independent score.

## Corrections

| P7 finding | Change |
| --- | --- |
| 1: history opens with an orphaned status | Every task now has a labeled **Status: Checks passed**, **Status: Working** or equivalent line at weight 600. Removing a duplicate description no longer leaves an unlabeled state. |
| 2: a hidden Retry is not announced | The reading control says **Read more below (retry available)** while a retry action is below the reading area. If the reader passes it, the upward control says **Read more above (retry available)**. The cue follows the action's actual bounds and returns to ordinary reading copy when the retry disappears. |
| 3: imported steps have no hierarchy and repeat checks | Task descriptions and status lines have more weight than receipt prose. When every imported step has the same nonempty check list, it appears once above the steps as **Completion checks for every step**. Different check lists remain attached to their individual steps. Autonomous agreements stay with their tasks. |
| 4: Review decision looks like Pause and End | **Review decision** uses weight 700 inside the same action row. Its behavior and the compact layout are unchanged. |
| 5: the cut-edge rule is outside the contrast walk | The rule now belongs to an empty `span.run-reading-rule` with the indicator declaration. The shared walk measures its actual border. The declaration is on the rule alone, keeping the adjacent reading button on the 4.5:1 text floor. |
| 6: terminal assignments rely on a Rust invariant | The real Rust projection probe now checks 72 combinations of two task states and cancellation. Every terminal assignment must project no pending decision. Live decision tasks provide the positive control and must still project a question. Controller behavior is unchanged. |
| 7: the fallback sounds like software | The older-format description now says **Rich has this assignment saved, but not in a form he can show you here.** The neutral fallback and original journal bytes remain intact. |
| 8: fallback direction already resolved | Kept resolved. The real projection and its existing three compiled mutations are rerun. No raw-contract fallback was reintroduced. |

The rule uses an empty sibling span rather than putting an indicator declaration
on the footer that contains the reading button. The shared library inherits that
role for descendant text. Declaring the entire footer would repeat the exact
text-threshold mistake P6 caught on the status line.

## Verification

[Current results and commands](validation/owned-work/urban-p7-results.json) link
the logs and narrow screenshots. The panel suite still runs the existing decision,
history, command-identity, contrast and viewport checks. Its history cases now
also require the hidden action cue, the labeled status and common-check grouping
across all five sizes in both themes. Retry is reached through the reading
controls, passed with the downward control and reached again with the upward
control before clicking. The bridge must receive the expected task and assignment
identities. After retry, the action cue must disappear.

Separate checks keep differing check sets with their own steps and compare the
computed weights of status versus receipt and Review versus Pause and End.
The cut-edge test covers decisions, history and the picker in both themes. It
requires a nonempty reading surface, a visible reading control and the actual rule
in the shared walk's measured paths. Making its border match the background must
fail at 3:1. Removing the border must invalidate its measurement. Giving the
reading button ink between 3:1 and 4.5:1 must still fail at the text floor.

The Rust probe continues to emit four views through the shipping projection:
registered work, amended work, an imported plan and an independently authored
older format. All four are rendered by the browser suite. The terminal-state
invariant checks run inside the same probe, including mixed task states so one
passed task cannot hide another task's live question.

One intermediate panel run failed on a conversation Copy button outside the
assignment panel. The shared timeline reveals these controls with a 150 ms hover
opacity transition. The panel harness now moves the pointer away and waits for
those controls to settle before contrast measurement. The failed run and a
separate hover diagnostic are retained: the diagnostic observed the transition
but did not reproduce the contrast failure, so its precise cause is not claimed
as proven. The settled panel run and the independent full contrast suite pass.
No contrast threshold, debt entry or measurement floor was weakened.

The last panel sweep also caught a ResizeObserver console error caused by changing
a cue label inside its resize notification. Cue updates now run on the next
animation frame and unchanged labels are not rewritten. The original console
failure is retained with the evidence; the final run must pass the suite's
existing zero-page-error assertion. No console error is filtered out.

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

Run from the repository root. `RICHOS_PLAYWRIGHT` selects an existing Playwright
installation and `CARGO` can select Cargo for the browser's projection check.

## Limits

This changes display copy, hierarchy and cues. It does not change execution,
authorization or completion rules. The browser uses the scripted command bridge.
The full core suite, controller mutation suite and desktop integration harness
remain historical evidence and are not reported as rerun here. Native validation
compiles the desktop and exercises its shared display projection.

No new packaged-window, OS accent, Full Keyboard Access or spoken-audio signoff is
claimed. No merge, push or deployment is included.
