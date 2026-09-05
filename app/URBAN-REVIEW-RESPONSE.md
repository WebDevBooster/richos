# Response to Urban's assignment-panel review

Urban reviewed `63e93ac` on September 5, 2026 and withheld P4 approval at 4/10.
That rejection was warranted. The earlier panel exposed the controller's data
structure, hid the stop controls and offered no actionable decision. Its tests
had not measured those failures. This revision is on
`codex/durable-orchestration`, in a separate worktree. It is ready for independent
re-review, not a claim of design approval or a deployed release.

## What changed

| Findings | Correction |
| --- | --- |
| 1, 14, 15: hidden controls and misleading pause state | Pause and End sit outside history. The optional history scrolls above them. The status shows Pausing while the request is pending, then the authoritative paused state. Layout is exercised at all five reviewed window sizes. |
| 2: a decision with no mechanism | The desktop now exposes `respond_run_decision`. It supports the displayed resource allowance, exact business answers, changed instructions and End. The controls invoke it with assignment, task and question identities. |
| 3, 10, 11: selected state disguised as the whole portfolio | The status counts assignments that need the CEO, even while another is selected. Pending decisions sort first. The chooser stays present for one assignment, leads with its title and truncates with an ellipsis. Attention adds weight and a visible border. |
| 4, 13: technical failures and recovery in the wrong order | A friendly status precedes Refresh. Raw diagnostics live in optional history. Setting unreadable work aside requires confirmation and preserves its saved history. |
| 5: ambiguous targets and unconfirmed End | Duplicate titles include a creation time and distinguishing reference. End confirms the exact target before submitting its identity. |
| 6, 8, 9, 12: vocabulary | The panel uses “assignment.” “Continue assignment” replaces the slash label. Pending tasks say “Not started.” Commands, paths and retry mechanics are behind one “Show me what happened” disclosure. |
| 7: completion checks treated as fine print | Completion checks are 16px. No exemption is declared or assumed. |
| 16: the affordance inventory could not see this panel | `runs.js` is included. State-map labels are explicitly extracted even when they are too short for the prose heuristic. Real-shell fixtures assert state text and usable controls together. |
| 17, 18: misleading contrast coverage | The shared walk covers empty, running, decision, error, history, picker and scope-editor states in both themes. Each new surface must actually measure its defining node. The standalone panel suite uses the same walk. |

## The decision mechanism

The command resolves the exact assignment within the open conversation. If its
writer is active, the command requests interruption and waits for the writer's
boundary without holding Rich's conversation lock. An unresponsive writer has a
30-second timeout that reports an explicit failure.

Under the journal lock, the controller validates a fingerprint of the committed
question and contract context. A stale question, wrong task or other assignment
cannot authorize work. Repeating the exact same action after a lost response or
restart does not apply it twice. The receipt encodes its fields as JSON rather
than relying on delimiters in user-supplied text.

- **Keep going** grants only the additional attempts and time allowance displayed
  to the CEO. It cannot answer a business question. Free text cannot silently
  grant more resources through this command.
- **Business answers** preserve the exact selected or written answer. They
  release only the answered task. Other pending CEO decisions stay pending.
- **Change instructions** appends the exact correction to the existing work and
  review contracts. Earlier requirements survive except explicit conflicts. All
  existing effects are checked before more execution.
- **End** persists cancellation and never records completion.

If answering interrupts independent work in the same assignment, that work is
requeued for inspection before more execution. Its resource accounting remains
intact. A separate pending decision is not cleared. The older conversation answer
path now refuses an ambiguous answer when multiple questions are pending.

Saved panel actions produce bounded acknowledgments through Rich's existing
conversation and speech path. Canceled assignments no longer publish notices
asking the CEO to answer their old questions. The panel therefore changes the
actual controller state and keeps Rich informed of the CEO's action.

## Evidence

The committed summary is [urban-results.json](validation/owned-work/urban-results.json).
The accompanying logs are in the same directory under `urban-*.log`.

| Check | Result |
| --- | --- |
| Core suite | 740 direct tests and five doctests passed. Two child-only fixtures remain ignored at the top level. Source inventory: 742 non-doc tests. |
| Final controller checks | 42 passed, including six new panel-decision regressions. |
| Mutation checks | 20/20 mutations failed at their intended test. Compiler failures and empty test runs do not count. Four new mutations break question identity, business authority, revised criteria or interrupted-work recovery. |
| Real-shell panel suite | 18 passed. Required controls were hit-tested and the full resource question was checked for clipping in both themes at 1400×900, 1280×800, 1024×768, 760×720 and 520×680. |
| Shared contrast gate | 41 checks passed across 26 surfaces and 52 theme walks. Seven surfaces are specific to assignments. No new contrast debt or exemption. |
| Affordance gate | 71 checks passed, including real-shell assignment fixtures. |
| Documentation gate | Six passed, including source-derived test totals and event names. |
| Desktop harness | All ten phases passed. The final panel-only pass additionally asserts the writer boundary and three completed conversation acknowledgments. |

The desktop harness calls the actual Tauri command functions and real controller
against an isolated data directory with a scripted native provider. The browser
suite checks the webview command names and payloads against a scripted bridge.
These are complementary tests, not a claim that Playwright clicked through the
Tauri IPC boundary or that a live provider completed every scenario.

Reproduction from the repository root:

```sh
cargo test --manifest-path app/Cargo.toml -p richos-core
python3 app/scripts/test-managed-run-mutations.py /path/to/cargo
cargo build --manifest-path app/src-tauri/Cargo.toml
python3 app/scripts/test-owned-work-desktop.py
python3 app/scripts/test-owned-work-desktop.py --panel-only
node app/ui/tests/runs.js
node app/ui/tests/contrast.js
node app/ui/tests/affordances.js
node app/ui/tests/docs-claims.js
```

The browser suites require the documented WebKit installation. An existing
installation can be selected with `RICHOS_PLAYWRIGHT`. Native desktop checks need
macOS. They use temporary company workspaces, not production company data.

Screenshots from the real WebKit shell:
[running, dark](validation/owned-work/urban-running-dark.png),
[decision, light](validation/owned-work/urban-decision-light.png) and
[decision at 520×680](validation/owned-work/urban-decision-narrow-light.png).
Both themes are retained beside these files.

## Remaining review boundaries

P4 still requires Urban's independent re-review. The shipped Tauri window chrome,
OS accent behavior and interactive spoken presentation have not received a new
visual audit here. The custom chooser removes dependence on an unmeasured native
select popup; its open webview list is measured instead. The previous proactive
message styling difference between live and reloaded conversations remains a
separate documented issue.

The model still makes fallible judgments. Verification is not a guarantee of
sound business judgment or exactly-once external effects. The app must stay open
for work to execute. This change installs no background OS service and adopts no
Claude Code team. The resource allowance is an attempts/time bound, not a dollar
cap. Very large portfolios and unusually long generated option lists still need
production-scale usability measurements.

During this revision another process deleted the worktree container. Restoring
`63e93ac` recovered committed work but lost some in-progress Rust edits. Those
edits were reconstructed, the controller was retested and an external recovery
copy was kept. None of the vanished edits was treated as having survived.
